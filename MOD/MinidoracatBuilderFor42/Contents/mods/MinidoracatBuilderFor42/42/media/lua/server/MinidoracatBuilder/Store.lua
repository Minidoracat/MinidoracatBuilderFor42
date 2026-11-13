-- 伺服器帳本的存檔（只在伺服器）：地板、掛上去的圖、燈與家電、線路四本帳本共用。不建全域物件、不送客戶端。
-- 一個 GOS 系統的存檔共用 10 MiB 的緩衝區，超過時檔案先被截斷才丟錯（SGlobalObjectSystem.java:273-298）。一本帳本所以
-- 存成好幾個系統 <名稱>_1、_2…（存檔 gos_<名稱>_<n>.bin），每個系統的 modData 是 { v = 格式版本, data = { [鍵] = 值 },
-- dict }：
--   新的一筆放進第一片還有空間的，都滿了才開新的一片；有幾片看存檔資料夾裡有哪些檔，不另外記。
--   一筆寫進哪一片就留在那一片（專用伺服器存檔前沒有 Lua 事件，不能在存檔前搬）；改大了原本那一片放不下才換片。
--   記憶體裡不另外存一份：查一筆就是照順序問每一片（通常只有一兩片）。
-- 值會重複的帳本（地板、掛上去的圖：幾萬筆只有幾百種「圖名＋退料」）開的時候給 sig：每一片各有一張對照表 dict
--   （編號 → 值），data 只存編號，一筆是「數字鍵＋編號」18 bytes。對照表和用到它的紀錄在同一個檔裡，一個檔壞了不影響
--   別片。get 拿到的是對照表裡那張表，很多筆共用：只能讀，不能改。
-- 沒給 sig 的帳本 data 直接存值。兩種都一樣：記進去的表之後不能原地改，要改就換一張新的表再 put（大小是照記的時候算的）。
-- 分片以前的存檔整本在各自主系統的一張表：adopt 每次開服把分片還沒有的複製進來，舊表留著；之後 put、del 的那一筆在舊表
--   跟著換或刪（settle）。哪一次開服舊表的每一筆分片都讀得到，才清掉舊表。
-- 各個存檔不是同時寫的。舊表還在的期間：分片沒寫成，下一次開服照舊表補回還沒刪的；主系統沒寫成而分片寫成，
--   那之後才刪掉的會回來（留成沒人用的紀錄）。舊表清掉之後和分片以前一樣：哪個檔沒寫成，就回到它上一次存的樣子。
if isClient() then return end

MinidoracatBuilder = MinidoracatBuilder or {}
local Store = {}
Store.__index = Store
MinidoracatBuilder.Store = Store

local LOG = "[MinidoracatBuilderFor42] "
Store.VERSION = 1
Store.SHARD_BYTES = 6 * 1024 * 1024 -- 一片估到這麼大就換下一片：估計值不含表頭，留四成給引擎的 10 MiB
Store.SHARD_HARD = 9 * 1024 * 1024  -- 新的鍵放進去不超過這裡；放不下就不記（寧可那一筆拆不了，不要整片帳本被截斷）
-- 已經在這一片的那一筆換值（掛圖少一張、線路加一個成員），或剛從這一片拿掉的那個鍵放回來，可以再多用這麼多：
-- 片剛好滿的時候，換值與記回原樣不會失敗
Store.SHARD_SLACK = 256 * 1024
Store.SHARD_MAX = 16
-- 全伺服器的 GOS 系統數送給客戶端時只有 1 byte、客戶端當有號數讀（CGlobalObjects.java:105）：超過 127 所有 MOD 的
-- 客戶端 GOS 都會壞。到 SYSTEM_BUDGET 就不再替一本帳本開第二片以後的片，留空間給別的 MOD；
-- 到 SYSTEM_MAX 連第一片都不開（那一本這一場不記新的，分片以前的存檔照樣讀得到）
Store.SYSTEM_BUDGET = 100
Store.SYSTEM_MAX = 120
Store.ORDER = { "floors", "overlays", "ledger", "circuits" } -- report 的順序
local byId = {}

-- 位置（edge＝0 那一格、1..3 那一格某條邊的牆）→ 一個數字鍵：x、y 各 22 bits（±2,097,152 格）、z 6 bits、edge 2 bits，
-- 共 52 bits，double 記得準。超出範圍回 nil（那一筆不記）
local HALF, SPAN = 2097152, 4194304
function Store.pos(x, y, z, edge)
    if x < -HALF or x >= HALF or y < -HALF or y >= HALF or z < -32 or z > 31 then return nil end
    return (((x + HALF) * SPAN + (y + HALF)) * 64 + (z + 32)) * 4 + (edge or 0)
end

-- 字串存檔是 UTF-8、# 算的是字元數：不是 ASCII 的字元每個最多 3 bytes
local function len(s)
    return #s + 2 * select(2, s:gsub("[^\1-\127]", ""))
end

-- 一個值在存檔裡佔幾 bytes（KahluaTableImpl.java:212-250：鍵與值各 1 byte 型別；字串是 2 bytes 長度加內容；數字 8 bytes；
-- 布林 1 byte；表是 4 bytes 筆數加每一筆的鍵與值）。存不了的型別回 nil
local function vsize(v)
    local t = type(v)
    if t == "number" then return 9 end
    if t == "string" then return 3 + len(v) end
    if t == "boolean" then return 2 end
    if t ~= "table" then return nil end
    local n = 5
    for k, x in pairs(v) do
        local a, b = type(k) ~= "table" and type(k) ~= "boolean" and vsize(k), vsize(x)
        if not (a and b) then return nil end
        n = n + a + b
    end
    return n
end
Store.size = vsize

local function isKey(k) return type(k) == "number" or type(k) == "string" end

-- 表的鍵照大小排好（Kahlua 不用 table.sort；退料表只有幾項）
local function sorted(t)
    local keys, n = {}, 0
    for k in pairs(t) do
        n = n + 1
        local j = n
        while j > 1 and keys[j - 1] > k do
            keys[j] = keys[j - 1]
            j = j - 1
        end
        keys[j] = k
    end
    return keys, n
end
Store.sorted = sorted

-- 退料表是不是「物品型別 → 數量」（從舊存檔的 buildMaterials 搬來的數量是字串）
function Store.isRefund(items)
    if type(items) ~= "table" then return false end
    for ft, n in pairs(items) do
        if type(ft) ~= "string" or (type(n) ~= "number" and type(n) ~= "string") then return false end
    end
    return true
end

-- 退料表的簽名：內容一樣的表簽名一樣。數量是數字還是字串分開算
function Store.itemsSig(items)
    local keys, n = sorted(items)
    local s = ""
    for j = 1, n do
        local q = items[keys[j]]
        s = s .. keys[j] .. (type(q) == "string" and "\2" or "\1") .. tostring(q) .. "\3"
    end
    return s
end

-- 分片系統：GOS 會對系統表呼叫這幾個（SGlobalObjectSystem.java:96-162）。直接定義在當 metatable 的表上：引擎用 rawget
-- 找，找不到只會再看 metatable 那張表本身（KahluaTableImpl.java:100）
local Shard = {}
Shard.__index = Shard
function Shard:getInitialStateForClient() return nil end
function Shard:OnClientCommand() end
function Shard:isValidIsoObject() return false end
function Shard:OnChunkLoaded() end

-- 鍵 k 在哪一片：那一片, 那一片存的值（有 sig 的是編號）, 第幾片
local function locate(S, k)
    local shards = S.shards
    for i = 1, S.m do
        local v = shards[i].data[k]
        if v ~= nil then return shards[i], v, i end
    end
    return nil
end

-- 第 i 片以前的片有沒有鍵 k
local function before(S, k, i)
    for j = 1, i - 1 do
        if S.shards[j].data[k] ~= nil then return true end
    end
    return false
end

-- 開第 i 片（存檔已經有的話在這裡讀進來）。不合格式的、和前面的片同一個鍵的（不該發生）不收，也從那一片的存檔表拿掉：
-- 留著的話查得到、大小也算不準
local function openShard(S, i)
    local system = SGlobalObjects.registerSystem(S.name .. "_" .. i)
    system:setModDataKeys({ "v", "data", "dict" })
    system:setObjectModDataKeys({})
    system:setObjectSyncKeys({})
    local md = system:getModData()
    setmetatable(md, Shard)
    local sh = { data = {}, dict = {}, bytes = 0, n = 0 }
    S.shards[i], S.m = sh, i
    if type(md.v) == "number" and md.v > Store.VERSION then
        -- 比較新的版本寫的檔：不讀也不寫（存檔時照讀進來的樣子寫回去），這一片當成滿的
        sh.frozen, sh.bytes = true, Store.SHARD_HARD
        print(LOG .. S.label .. " ledger: shard " .. i .. " was written by a newer version (format " .. md.v
            .. "); left untouched")
        return
    end
    md.v = Store.VERSION
    if type(md.data) ~= "table" then md.data = {} end
    sh.data = md.data
    local bad, nbad = {}, 0
    if S.sig then
        if type(md.dict) ~= "table" then md.dict = {} end
        sh.dict, sh.ids, sh.refs, sh.next = md.dict, {}, {}, 1
        local ok = {}
        for id, v in pairs(sh.dict) do
            if type(id) == "number" and S.valid(v) then ok[id] = true end
        end
        for k, id in pairs(sh.data) do
            if ok[id] and isKey(k) and not before(S, k, i) then
                sh.refs[id] = (sh.refs[id] or 0) + 1
                sh.bytes, sh.n = sh.bytes + vsize(k) + 9, sh.n + 1
            else
                nbad = nbad + 1
                bad[nbad] = k
            end
        end
        local unused = {}
        for id, v in pairs(sh.dict) do
            if sh.refs[id] then
                sh.bytes = sh.bytes + 9 + vsize(v)
                local sg = S.sig(v)
                if not sh.ids[sg] then sh.ids[sg] = id end
                if id >= sh.next then sh.next = id + 1 end
            else
                unused[#unused + 1] = id
            end
        end
        for _, id in ipairs(unused) do sh.dict[id] = nil end
    else
        for k, v in pairs(sh.data) do
            if isKey(k) and S.valid(v, k) and not before(S, k, i) then
                sh.bytes, sh.n = sh.bytes + vsize(k) + vsize(v), sh.n + 1
            else
                nbad = nbad + 1
                bad[nbad] = k
            end
        end
    end
    for j = 1, nbad do sh.data[bad[j]] = nil end
    S.n = S.n + sh.n
    if nbad > 0 then
        print(LOG .. S.label .. " ledger: shard " .. i .. " dropped " .. nbad
            .. " unreadable or duplicate entries (removed from the save file)")
    end
end

-- 值 v（簽名 sg、放進對照表要 dsz bytes）在這一片的編號；這一片還沒有就加進對照表
local function ref(sh, v, sg, dsz)
    local id = sh.ids[sg]
    if id then
        sh.refs[id] = sh.refs[id] + 1
        return id
    end
    id = sh.next
    sh.next = id + 1
    sh.dict[id], sh.ids[sg], sh.refs[id] = v, id, 1
    sh.bytes = sh.bytes + dsz
    return id
end

-- 少一筆用編號 id：沒有人用了就從對照表拿掉
local function unref(S, sh, id)
    local n = sh.refs[id] - 1
    if n > 0 then
        sh.refs[id] = n
        return
    end
    local v = sh.dict[id]
    local sg = S.sig(v)
    if sh.ids[sg] == id then sh.ids[sg] = nil end
    sh.dict[id], sh.refs[id] = nil, nil
    sh.bytes = sh.bytes - 9 - vsize(v)
end

local function drop(S, sh, k, cur)
    sh.data[k] = nil
    sh.n, S.n = sh.n - 1, S.n - 1
    if S.sig then
        sh.bytes = sh.bytes - vsize(k) - 9
        unref(S, sh, cur)
    else
        sh.bytes = sh.bytes - vsize(k) - vsize(cur)
    end
end

-- 新的一筆放進這一片要多用幾 bytes：這一片的對照表已經有同一個值就只有紀錄本身
local function need(sh, esz, sg, dsz)
    if sg and sh.ids and sh.ids[sg] then return esz end
    return esz + dsz
end

-- 鍵 k 新的一筆放第幾片（esz＝紀錄本身、sg＝值的簽名、dsz＝值放進對照表要的大小；沒有對照表的帳本 sg 是 nil、dsz 是 0）；
-- 都放不下回 nil。第二個回傳值 true＝這次開了新的一片
local function pick(S, k, esz, sg, dsz)
    -- 換掉一筆是先 del 再 put：原本那一片放得下，新的就回那一片（同一個鍵的紀錄盡量不換存檔）；放不下才照下面的選。
    -- 和原位換值同一個規則：放回去不比拿掉之前大的一律可以（拆到一半要記回原樣時一定記得回去），變大的可以用到餘裕
    if S.gone == k then
        local sh = S.shards[S.goneAt]
        local after = sh.bytes + need(sh, esz, sg, dsz)
        if after <= S.goneWas or after <= Store.SHARD_HARD + Store.SHARD_SLACK then return S.goneAt end
    end
    local goal, best, bestAfter = math.min(Store.SHARD_BYTES, Store.SHARD_HARD), nil, nil
    for i = 1, S.m do
        local after = S.shards[i].bytes + need(S.shards[i], esz, sg, dsz)
        if after <= goal then return i end
        if not best or after < bestAfter then best, bestAfter = i, after end
    end
    if esz + dsz <= goal then
        local systems = SGlobalObjects.getSystemCount()
        if S.m < Store.SHARD_MAX and systems < (S.m == 0 and Store.SYSTEM_MAX or Store.SYSTEM_BUDGET) then
            openShard(S, S.m + 1)
            print(LOG .. S.label .. " ledger: opened shard " .. S.m)
            -- 新的一片通常是空的；存檔資料夾裡剛好有同名的檔時照它現在的大小重選
            return pick(S, k, esz, sg, dsz), true
        end
        if not S.full then -- 一場只記一次
            S.full = true
            print(LOG .. S.label .. " ledger: cannot open another shard (" .. S.m .. " shards, " .. systems .. " systems)")
        end
    end
    if best and bestAfter <= Store.SHARD_HARD then return best end
    return nil
end

-- 寫進分片的唯一入口（呼叫的人先 valid）。已經有的鍵留在原本那一片，放不下才換片。都放不下回 false，帳本不變
local function place(S, k, v)
    local sg = S.sig and S.sig(v)
    local esz = vsize(k) + (sg and 9 or vsize(v))
    local dsz = sg and 9 + vsize(v) or 0
    local sh, cur = locate(S, k)
    if sh then
        local old = vsize(k) + (sg and 9 or vsize(cur))
        local extra = sg and not sh.ids[sg] and dsz or 0
        -- 舊值只剩這一筆在用、新值是另一張：換完之後舊值會從對照表拿掉
        local freed = sg and sh.ids[sg] ~= cur and sh.refs[cur] == 1 and 9 + vsize(sh.dict[cur]) or 0
        local after = sh.bytes - old + esz + extra - freed
        -- 換完沒有變大的一律可以（不管這一片現在多滿）；變大的不超過硬上限加換值的餘裕
        if after <= sh.bytes or after <= Store.SHARD_HARD + Store.SHARD_SLACK then
            sh.bytes = sh.bytes - old + esz
            if sg then
                sh.data[k] = ref(sh, v, sg, dsz) -- 先加新的再放掉舊的：同一個值不會先被拿掉
                unref(S, sh, cur)
            else
                sh.data[k] = v
            end
            return true
        end
    end
    local to, opened = pick(S, k, esz, sg, dsz)
    -- 剛開的那一片的存檔裡剛好有這個鍵（開服之後才出現的檔）：照已經有的那一筆改
    if opened and not sh and locate(S, k) then return place(S, k, v) end
    if not to then return false end
    if sh then drop(S, sh, k, cur) end
    local t = S.shards[to]
    t.bytes, t.n, S.n = t.bytes + esz, t.n + 1, S.n + 1
    t.data[k] = sg and ref(t, v, sg, dsz) or v
    return true
end

-- 鍵 k 在舊表的那一格：回 舊表, 舊鍵, 那一格在舊檔原本佔多大（第一次問的時候量，之後照這個數）。沒有回 nil
local function slot(S, k)
    local t = S.oldT and S.oldT[k]
    if not t then return nil end
    local ok = S.oldK[k]
    local cap = S.oldSz[k] or vsize(t[ok]) or 0
    S.oldSz[k] = cap
    return t, ok, cap
end

-- 舊表還在的那一場：鍵 k 在舊表的那一格跟著處理。v＝剛記成的新值（del 時是 nil）。這本帳本新舊格式一樣（mirror）、而且新值
-- 沒有比那一格在舊檔原本的大：舊表也記新值（先 del 再 put 的換地板也算），分片的檔整個沒寫成（不在）時下一次開服照舊表
-- 補回的是新的那一筆。分片的檔留著上一次存的內容時照分片（adopt 不比內容：哪一邊比較新分不出來），那一筆回到上一次存的
-- 樣子。其他情形從舊表刪掉：舊表所在的主系統存檔在搬完之前只能變小，不能被撐過引擎的上限
local function settle(S, k, v)
    local t, ok, cap = slot(S, k)
    if t then
        if v ~= nil and S.mirror and vsize(v) <= cap then t[ok] = v else t[ok] = nil end
    end
    if S.left and S.left[k] ~= nil then S.left[k], S.nleft = nil, S.nleft - 1 end
end

-- 鍵 k 在舊表 old 還留著一份（鍵是 oldKey）：之後 put、del 這一筆時跟著處理（settle）
function Store:track(k, old, oldKey)
    self.oldT, self.oldK, self.oldSz = self.oldT or {}, self.oldK or {}, self.oldSz or {}
    self.oldT[k], self.oldK[k] = old, oldKey
end

-- 開一本帳本（存檔 gos_<name>_<n>.bin）。opts：id（report 用）、label（log 用）、valid(值, 鍵)＝這一筆收不收、
-- sig(值)＝值的簽名（給了就用對照表；這時 valid 只看值）、mirror＝分片以前的存檔裡值的格式和現在一樣（settle）
function Store.open(name, opts)
    local S = setmetatable({ name = name, id = opts.id, label = opts.label, valid = opts.valid, sig = opts.sig,
        mirror = opts.mirror, shards = {}, m = 0, n = 0, left = {}, nleft = 0 }, Store) -- left＝放不進分片、還在舊表的
    -- 有幾片看存檔資料夾：不靠另一個存檔記的數字，哪個檔壞了都不影響找到其他片
    local last = 0
    for i = 1, Store.SHARD_MAX do
        if checkSaveFileExists("gos_" .. name .. "_" .. i .. ".bin") then last = i end
    end
    -- 一片都還沒有（新世界，或第一次用分片的版本）：先不開，第一筆要記的時候才開（pick）。用不到的帳本不佔 GOS 系統
    for i = 1, last do openShard(S, i) end
    byId[opts.id] = S
    return S
end

-- 鍵 k 的值；沒有回 nil。有 sig 的帳本回的是共用的表，不能改
function Store:get(k)
    local sh, v = locate(self, k)
    if not sh then return self.left[k] end
    if self.sig then return sh.dict[v] end
    return v
end

-- 記下（或換掉）鍵 k 的值（呼叫的人先確認 valid；v 之後不能再改）。記不進去回 false，帳本不變。
-- 分片放不下、而這個鍵這一場在舊表有一格（開不了片的伺服器：系統數到上限）：新值沒有比那一格原本的大就記在舊表，
-- 照樣查得到（left），下一次開服再搬
function Store:put(k, v)
    if place(self, k, v) then
        settle(self, k, v)
        return true
    end
    local t, ok, cap = slot(self, k)
    if not (t and self.mirror) or vsize(v) > cap or locate(self, k) then return false end
    t[ok] = v
    if self.left[k] == nil then self.nleft = self.nleft + 1 end
    self.left[k] = v
    return true
end

-- 沒有那一筆（絕大多數的呼叫）查完每一片就返回
function Store:del(k)
    settle(self, k)
    local sh, cur, at = locate(self, k)
    if not sh then return end
    local was = sh.bytes
    drop(self, sh, k, cur)
    self.gone, self.goneAt, self.goneWas = k, at, was
end

-- 每一筆呼叫 fn(鍵, 值)（開服時整理用；fn 裡不改這本帳本）
function Store:each(fn)
    for i = 1, self.m do
        local sh = self.shards[i]
        for k, v in pairs(sh.data) do
            if self.sig then fn(k, sh.dict[v]) else fn(k, v) end
        end
    end
    for k, v in pairs(self.left or {}) do fn(k, v) end
end

-- 分片以前的存檔 old（主系統的一張表）：conv(舊鍵, 舊值) 回新鍵, 新值；回 false＝不是這本帳本的（留著不動），回 nil 或
-- 新值不合格式＝讀不懂（留在舊表不丟：格式判斷有錯時還救得回來）。分片還沒有的複製進來；放不進分片的記在 left，
-- 照樣查得到。這次有複製或放不下的：舊表留著，下一次開服再確認；都沒有：舊表裡讀得懂的清掉。
function Store:adopt(old, conv)
    local ks, k2s, n, copied, left, nbad = {}, {}, 0, 0, 0, 0
    for k, e in pairs(old) do
        local k2, v = conv(k, e)
        if k2 == nil or (k2 ~= false and not self.valid(v, k2)) then
            nbad = nbad + 1
        elseif k2 ~= false then
            n = n + 1
            ks[n], k2s[n] = k, k2
            if not locate(self, k2) then
                if place(self, k2, v) then
                    copied = copied + 1
                else
                    left = left + 1
                    self.left[k2], self.nleft = v, self.nleft + 1
                end
            end
        end
    end
    local head = LOG .. self.label .. " ledger: "
    if copied > 0 or left > 0 then
        for j = 1, n do self:track(k2s[j], old, ks[j]) end
        print(head .. "copied " .. copied .. " entries from the old single file into shards (" .. left .. " left, "
            .. nbad .. " bad)")
    else
        for j = 1, n do old[ks[j]] = nil end
        if n > 0 then print(head .. "old single-file copy dropped (all " .. n .. " entries found in shards)") end
    end
    if nbad > 0 then print(head .. nbad .. " unreadable entries kept in the old single file") end
end

-- 帳本現在的樣子：筆數、估計 bytes、每一片的筆數與估計 bytes
function Store:stats()
    local out = { n = self.n, bytes = 0, shards = {} }
    for i = 1, self.m do
        local sh = self.shards[i]
        out.shards[i] = { n = sh.n, bytes = sh.bytes, frozen = sh.frozen }
        if not sh.frozen then out.bytes = out.bytes + sh.bytes end
    end
    return out
end

function Store:summary()
    local st = self:stats()
    print(LOG .. self.label .. " ledger: " .. st.n .. " entries in " .. self.m .. " shard(s), about "
        .. math.floor(st.bytes / 1024) .. " KiB")
end

-- 每本帳本一列 { id, n = 筆數, shards = 幾片, bytes = 估計大小 }（管理面板）
function Store.report()
    local out = {}
    for _, id in ipairs(Store.ORDER) do
        local S = byId[id]
        if S then
            local st = S:stats()
            -- 筆數含還在舊表、放不進分片的（left 筆，照樣查得到）；檔數與大小只算分片
            out[#out + 1] = { id = id, n = st.n + S.nleft, left = S.nleft, shards = S.m, bytes = st.bytes }
        end
    end
    return out
end

return Store
