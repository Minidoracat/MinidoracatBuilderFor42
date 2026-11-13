-- 一樓以下地板的退料帳本（只在伺服器）：本 MOD 蓋的一樓以下地板不寫 buildMaterials（Place.groundFloor），本工具拆的時候
-- 照這裡退（Place.refundOf）。本工具挖的水面也記在這裡（Place.dig，退料是空表）：填平時照這一筆認是不是本工具挖的。
-- 鍵是位置 "x,y,z"：同一格只有一片本 MOD 的地板（放地板前 Place.clearFloor 先拆掉舊的）。
-- 值記蓋的圖名與退料表，現在的圖和蓋的圖一樣才退。和燈、平台的帳本（Ledger）分開，各自存檔
-- （跟世界一起存檔、一起回溯）；不建全域物件、不送客戶端。
--
-- 分片：一個 GOS 系統的存檔共用 10 MiB 的緩衝區，超過時檔案先被截斷才丟錯（SGlobalObjectSystem.java:273-298）。
-- 帳本所以分成好幾個系統 MinidoracatBuilderFloors_1、_2…（存檔 gos_MinidoracatBuilderFloors_<n>.bin）：新的一筆放進第一片
-- 還有空間的，都滿了才開新的一片；一筆寫進哪一片就留在那一片（專用伺服器存檔前沒有 Lua 事件，不能在存檔前搬）。
-- 有幾片看存檔資料夾裡有哪些檔，不另外記。記憶體裡照舊是一張表（R.all），查一筆不用知道它在哪一片。
-- 分片以前的存檔：整本帳本在主系統 MinidoracatBuilderFloors 的 floors。開服時舊表裡分片還沒有的每一筆都複製進分片，
-- 舊表留著；之後拆掉或重蓋的那一筆同時從舊表刪掉。哪一次開服舊表的每一筆都在分片裡讀得到，才清掉舊表。
-- 各個存檔不是同時寫的。舊表還在的期間：分片沒寫成，下一次開服照舊表補回還沒拆的；主系統沒寫成而分片寫成，
-- 那之後才拆掉的會回來（留成沒人用的紀錄）。舊表清掉之後和分片以前一樣：哪個檔沒寫成，就回到它上一次存的樣子。
if isClient() then return end
require "Map/SGlobalObjectSystem"

MinidoracatBuilder = MinidoracatBuilder or {}
local NAME = "MinidoracatBuilderFloors"
local LOG = "[MinidoracatBuilderFor42] "
local Floors = SGlobalObjectSystem:derive(NAME)
MinidoracatBuilder.Floors = Floors

Floors.SHARD_BYTES = 6 * 1024 * 1024 -- 一片估到這麼大就換下一片：估計值不含表頭，留四成給引擎的 10 MiB
Floors.SHARD_HARD = 9 * 1024 * 1024  -- 任何一片都不超過這裡；放不下就不記（寧可那一片地板拆不了，不要整片帳本被截斷）
Floors.SHARD_MAX = 16
-- 全伺服器的 GOS 系統數送給客戶端時只有 1 byte、客戶端當有號數讀（CGlobalObjects.java:105）：超過 127 所有 MOD 的
-- 客戶端 GOS 都會壞。到這個數就不再開新的一片，留空間給別的 MOD
Floors.SYSTEM_BUDGET = 100

-- 記憶體裡的帳本：all＝鍵 → 那一筆，where＝鍵 → 第幾片，shards[n]＝{ data（那一片存檔的表）, bytes, n }。
-- old＝還沒清掉的舊表（沒有就是 nil）；left＝舊表裡這次放不進分片的（照樣查得到）；
-- gone／goneAt＝剛清掉的鍵與它原本那一片
local R = { all = {}, where = {}, shards = {}, n = 0 }

function Floors:new()
    return SGlobalObjectSystem.new(self, NAME)
end

-- 存檔裡的一筆只有圖名 s 與退料表 i（物品型別 → 數量；從舊存檔的 buildMaterials 搬來的數量是字串）。
-- 多的、型別不對的都不收，大小才算得準
local function valid(k, e)
    if type(k) ~= "string" or type(e) ~= "table" or type(e.s) ~= "string" or type(e.i) ~= "table" then return false end
    for f in pairs(e) do
        if f ~= "s" and f ~= "i" then return false end
    end
    for ft, n in pairs(e.i) do
        if type(ft) ~= "string" or (type(n) ~= "number" and type(n) ~= "string") then return false end
    end
    return true
end

-- 字串存檔是 UTF-8、# 算的是字元數：不是 ASCII 的字元每個最多 3 bytes
local function len(s)
    return #s + 2 * select(2, s:gsub("[^\1-\127]", ""))
end

-- 一筆在存檔裡佔幾 bytes（KahluaTableImpl.java:212-250：鍵與值各 1 byte 型別；字串是 2 bytes 長度加內容；數字 8 bytes；
-- 表是 4 bytes 筆數）
local function size(k, e)
    local n = len(k) + len(e.s) + 24
    for ft, v in pairs(e.i) do
        n = n + len(ft) + (type(v) == "string" and 6 + len(v) or 12)
    end
    return n
end

-- 分片系統：只存 "data"，不持有全域物件。GOS 會對系統表呼叫這幾個（SGlobalObjectSystem.java:96-162）
local Shard = {}
Shard.__index = Shard
function Shard:getInitialStateForClient() return nil end
function Shard:OnClientCommand() end
function Shard:isValidIsoObject() return false end
function Shard:OnChunkLoaded() end

-- 開第 n 片（存檔已經有的話在這裡讀進來）並併進記憶體的帳本。不合格式的、和前面的片同一個鍵的（不該發生）不收
local function open(n)
    local system = SGlobalObjects.registerSystem(NAME .. "_" .. n)
    system:setModDataKeys({ "data" })
    system:setObjectModDataKeys({})
    system:setObjectSyncKeys({})
    local md = system:getModData()
    setmetatable(md, Shard)
    if type(md.data) ~= "table" then md.data = {} end
    local sh = { data = md.data, bytes = 0, n = 0 }
    R.shards[n] = sh
    local bad
    for k, e in pairs(sh.data) do
        if valid(k, e) and R.all[k] == nil then
            R.all[k], R.where[k] = e, n
            sh.bytes, sh.n = sh.bytes + size(k, e), sh.n + 1
            R.n = R.n + 1
        else
            bad = bad or {}
            bad[#bad + 1] = k
        end
    end
    for _, k in ipairs(bad or {}) do sh.data[k] = nil end
    if bad then print(LOG .. "floor ledger: shard " .. n .. " ignored " .. #bad .. " unreadable or duplicate entries") end
    return sh
end

-- 鍵 k 新的一筆（sz bytes）放第幾片；都放不下回 nil
local function pick(k, sz)
    -- 換地板是先清掉舊的那一筆再記新的：原本那一片放得下，新的就回那一片（同一格的紀錄盡量不換存檔）；
    -- 放不下才照下面的選
    if R.gone == k and R.shards[R.goneAt].bytes + sz <= Floors.SHARD_HARD then return R.goneAt end
    local goal, best = math.min(Floors.SHARD_BYTES, Floors.SHARD_HARD), 1
    for n = 1, #R.shards do
        local b = R.shards[n].bytes
        if b + sz <= goal then return n end
        if b < R.shards[best].bytes then best = n end
    end
    if sz <= goal then
        if #R.shards < Floors.SHARD_MAX and SGlobalObjects.getSystemCount() < Floors.SYSTEM_BUDGET then
            open(#R.shards + 1)
            print(LOG .. "floor ledger: opened shard " .. #R.shards)
            return pick(k, sz) -- 新的一片通常是空的；存檔資料夾裡剛好有同名的檔時照它現在的大小重選
        end
        if not R.full then -- 一場只記一次
            R.full = true
            print(LOG .. "floor ledger: cannot open another shard (" .. #R.shards .. " shards, "
                .. SGlobalObjects.getSystemCount() .. " systems)")
        end
    end
    if R.shards[best].bytes + sz <= Floors.SHARD_HARD then return best end
    return nil
end

-- 寫進分片的唯一入口（呼叫的人先 valid）：記憶體的帳本和所屬的那一片一起改（同一個表）。已經有的鍵留在原本那一片。
-- 放不下回 false，帳本不變
local function place(k, e)
    local sz = size(k, e)
    local n = R.where[k] or pick(k, sz)
    local at = R.where[k] -- pick 開新的一片時可能把同一個鍵讀進來：照已經有的那一筆改
    if at then
        local sh = R.shards[at]
        local b = sh.bytes - size(k, R.all[k]) + sz
        if b > Floors.SHARD_HARD then return false end
        sh.bytes = b
        sh.data[k], R.all[k] = e, e
        return true
    end
    if not n then return false end
    local sh = R.shards[n]
    sh.bytes, sh.n = sh.bytes + sz, sh.n + 1
    sh.data[k], R.all[k], R.where[k] = e, e, n
    R.n = R.n + 1
    return true
end

function Floors:initSystem()
    -- 同一個系統表只建一次（原版在 OnSGlobalObjectSystemInit 建系統）。再呼叫不重讀：還沒存檔的片不在存檔資料夾裡
    if Floors.instance == self then return end
    SGlobalObjectSystem.initSystem(self)
    -- 存檔只存白名單裡的鍵：漏設＝這一場正常、重開後帳本消失
    self.system:setModDataKeys({ "floors" })
    self.system:setObjectModDataKeys({})
    self.system:setObjectSyncKeys({})
    R = { all = {}, where = {}, shards = {}, n = 0 }
    -- 有幾片看存檔資料夾：不靠另一個存檔記的數字，哪個檔壞了都不影響找到其他片
    local last = 1
    for n = 2, Floors.SHARD_MAX do
        if checkSaveFileExists("gos_" .. NAME .. "_" .. n .. ".bin") then last = n end
    end
    for n = 1, last do open(n) end
    local old = self.floors
    if type(old) ~= "table" then
        old = {}
        self.floors = old
    end
    local good, copied, left, bad, nbad = 0, 0, 0, nil, 0
    for k, e in pairs(old) do
        if not valid(k, e) then
            bad = bad or {}
            bad[k] = e
            nbad = nbad + 1
        else
            good = good + 1
            if R.all[k] == nil then
                if place(k, e) then
                    copied = copied + 1
                else
                    left = left + 1
                    R.left = R.left or {}
                    R.left[k] = e
                end
            end
        end
    end
    if copied > 0 or left > 0 then
        R.old = old -- 這次才複製（或補回）的還沒存檔：舊表留到下一次開服再確認
        print(LOG .. "floor ledger: copied " .. copied .. " entries from the old single file into shards ("
            .. left .. " left, " .. nbad .. " bad)")
    elseif good > 0 or nbad > 0 then
        -- 舊表讀得懂的每一筆分片都讀得到：不用留了。讀不懂的留在主系統（不丟：格式判斷有錯時還救得回來）
        self.floors = bad or {}
        if good > 0 then
            print(LOG .. "floor ledger: old single-file copy dropped (all " .. good .. " entries found in shards)")
        end
    end
    if nbad > 0 then print(LOG .. "floor ledger: " .. nbad .. " unreadable entries kept in the old single file") end
    local bytes = 0
    for n = 1, #R.shards do bytes = bytes + R.shards[n].bytes end
    print(LOG .. "floor ledger: " .. R.n .. " entries in " .. #R.shards .. " shard(s), about " .. math.floor(bytes / 1024) .. " KiB")
    Floors.instance = self
end

-- GOS 會對系統表呼叫這幾個（SGlobalObjectSystem.java:96-162）；本系統不持有全域物件、不收客戶端指令
function Floors:getInitialStateForClient() return nil end
function Floors:isValidIsoObject() return false end
function Floors:newLuaObject() error("MinidoracatBuilder floors own no global objects") end
function Floors:OnChunkLoaded() end
function Floors:OnClientCommand() end

SGlobalObjectSystem.RegisterSystemClass(Floors)

local function key(obj)
    local sq = obj:getSquare()
    return sq and (sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ()) or nil
end

-- 記下這片地板蓋的圖與退料（items＝拆了退什麼，沒付料的是空表）。帳本還沒建（不該發生）、退料表不是「物品型別 → 數量」
-- 或每一片都滿了時只記 log：之後這片本工具拆不了。
function Floors.put(obj, items)
    local inst, k, spr = Floors.instance, key(obj), obj:getSprite()
    local name = spr and spr:getName()
    if not (inst and k and name) then
        print(LOG .. "floor ledger not ready; not recorded: " .. tostring(k))
        return
    end
    local e = { s = name, i = {} }
    for ft, n in pairs(items) do e.i[ft] = n end
    if not valid(k, e) then
        print(LOG .. "floor ledger: unreadable refund; not recorded: " .. k)
    elseif not place(k, e) then
        print(LOG .. "floor ledger full; not recorded: " .. k)
    elseif R.old then -- 記成了才刪舊表那一筆（left 裡的那一份之後查不到：get 先看分片）
        R.old[k] = nil
    end
end

-- 這一格的那筆：{ s = 蓋的圖名, i = 退料表 }，沒有回 nil
function Floors.get(obj)
    local k = Floors.instance and key(obj)
    return k and (R.all[k] or R.left and R.left[k]) or nil
end

-- 移出世界前清掉（Place.onAboutToBeRemoved）。沒有那一筆（絕大多數被移除的物件）查兩次表就返回
function Floors.forget(obj)
    local k = Floors.instance and key(obj)
    if not k then return end
    if R.old then
        R.old[k] = nil
        if R.left then R.left[k] = nil end
    end
    local n = R.where[k]
    if not n then return end
    local sh = R.shards[n]
    sh.bytes, sh.n = sh.bytes - size(k, R.all[k]), sh.n - 1
    sh.data[k], R.all[k], R.where[k] = nil, nil, nil
    R.n = R.n - 1
    R.gone, R.goneAt = k, n
end

-- 帳本現在的樣子（離線測試與實機驗證用）：筆數、每一片的筆數與估計 bytes
function Floors.stats()
    local out = { n = R.n, shards = {} }
    for n = 1, #R.shards do out.shards[n] = { n = R.shards[n].n, bytes = R.shards[n].bytes } end
    return out
end

return Floors
