-- 伺服器帳本（設計稿「伺服器帳本」）：本 MOD 蓋的燈、開關與家電，以及樓梯頂端補的平台地板。燈與家電沒有 buildMaterials，
-- 平台是一般 IsoObject（和原版樓梯補的長得一樣），所以「是不是本 MOD 蓋的、拆了退什麼」只認這裡（只在伺服器）。不建全域
-- 物件、不送客戶端。存檔在 Store（跟世界一起存檔、一起回溯）：
-- 燈、開關（IsoLightSwitch）與家電（壁爐這類，Place.keyed）：gos_MinidoracatBuilder_<n>.bin，[編號] = { p = 位置
--   （Store.pos）, s = 蓋的圖名, i = { [fullType] = 退料數 } }。蓋的時候把編號寫進物件的 keyId（IsoObject 的欄位，任何類別
--   都跟著存檔），認物件看編號、位置與蓋的圖，不看 modData（見知識庫 placement.md「燈的帳本照編號認」）。
-- 樓梯平台：同一本，["x,y,z,sprite"] = {}（只記是本 MOD 補的，不退料）。
-- 線路：gos_MinidoracatBuilderCircuits_<n>.bin（Ledger.circuits；格式與讀寫在 Circuits.lua，成員的鍵照 Ledger.key）。
-- 主系統 MinidoracatBuilder（gos_MinidoracatBuilder.bin）只留：下一個編號（lamps.next、circuits.next）、分片以前的存檔
--   （lamps.e、built 的平台、circuits.c，Store.adopt 搬完就清），以及 0.3.0 以前的燈（built["x,y,z,sprite"] = 退料表；
--   0.4.0 起發編號），升版後讀到那一塊時發編號或刪掉（檔尾）。發了編號的那一筆先換成 { id = 編號, i = 退料表 } 留著：
--   主系統和分片不是同一個檔，下一次開服分片讀得到那個編號才刪。
if isClient() then return end
require "Map/SGlobalObjectSystem"
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Place"
require "MinidoracatBuilder/Store"

MinidoracatBuilder = MinidoracatBuilder or {}
local NAME = "MinidoracatBuilder"
local Store = MinidoracatBuilder.Store
local Ledger = SGlobalObjectSystem:derive("MinidoracatBuilderLedger")
MinidoracatBuilder.Ledger = Ledger

local L -- 這一場的燈、家電與平台（initSystem 開）

local LOG = "[MinidoracatBuilderFor42] "
local LANDING = "," .. MinidoracatBuilder.Entry.STAIR_FLOOR

local function isLanding(k) return k:sub(-#LANDING) == LANDING end

local CHUNK = 8 -- IsoChunk 一邊幾格（IsoChunk.java:3762,3800）
local function chunkOf(x, y) return math.floor(x / CHUNK) * 100000 + math.floor(y / CHUNK) end
local byChunk = {} -- 還沒定案的 0.3.0 舊燈鍵，照所在的 chunk 分（檔尾）
local watchLegacy -- 檔尾：還有舊鍵時才掛讀 chunk 的事件

local function parseKey(k)
    local x, y, z, name = string.match(k, "^(%-?%d+),(%-?%d+),(%-?%d+),(.+)$")
    if not x then return nil end
    return tonumber(x), tonumber(y), tonumber(z), name
end

function Ledger:new()
    return SGlobalObjectSystem.new(self, NAME)
end

-- 數字鍵是燈與家電的編號，字串鍵是平台
local function valid(v, k)
    if type(k) ~= "number" then return Store.isRefund(v) end
    if type(v) ~= "table" or type(v.p) ~= "number" or type(v.s) ~= "string" or not Store.isRefund(v.i) then return false end
    for f in pairs(v) do
        if f ~= "p" and f ~= "s" and f ~= "i" then return false end
    end
    return true
end

local function isSet(t)
    if type(t) ~= "table" then return false end
    for k, v in pairs(t) do
        if type(k) ~= "string" or v ~= true then return false end
    end
    return true
end

-- 一條線路：{ s = { [開關的鍵] = true }, l = { [燈的鍵] = true } }
local function validCircuit(c, id)
    return type(id) == "number" and type(c) == "table" and isSet(c.s) and isSet(c.l)
end

-- 分片以前的燈：位置是 "x,y,z"
local function fromOldLamp(id, e)
    if type(id) ~= "number" or type(e) ~= "table" or type(e.p) ~= "string" then return nil end
    local x, y, z = e.p:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
    if not x then return nil end
    return id, { p = Store.pos(tonumber(x), tonumber(y), tonumber(z)), s = e.s, i = e.i }
end

-- built 裡的平台搬進分片；其他的（0.3.0 以前的燈）留在 built，照檔尾定案
local function fromOldBuilt(k, items)
    if type(k) == "string" and isLanding(k) then return k, items end
    return false
end

local function same(id, c) return id, c end

-- 編號不重發：主系統的存檔沒寫成（回到上一次存的）而分片寫成時，記著的下一個編號比分片裡已經有的小
local function after(S, counter)
    S:each(function(k)
        if type(k) == "number" and k >= counter.next then counter.next = k + 1 end
    end)
end

function Ledger:initSystem()
    -- 同一個系統表只建一次；再呼叫不重讀（還沒存檔的片不在存檔資料夾裡）
    if Ledger.instance == self then return end
    SGlobalObjectSystem.initSystem(self)
    -- 存檔只存白名單裡的鍵：漏設＝這一場正常、重開後帳本消失
    self.system:setModDataKeys({ "built", "circuits", "lamps" })
    self.system:setObjectModDataKeys({})
    self.system:setObjectSyncKeys({})
    if type(self.built) ~= "table" then self.built = {} end
    if type(self.lamps) ~= "table" then self.lamps = {} end
    if type(self.lamps.e) ~= "table" then self.lamps.e = {} end
    if type(self.lamps.next) ~= "number" then self.lamps.next = 1 end
    if type(self.circuits) ~= "table" then self.circuits = {} end
    if type(self.circuits.c) ~= "table" then self.circuits.c = {} end
    if type(self.circuits.next) ~= "number" then self.circuits.next = 1 end
    L = Store.open(NAME, { id = "ledger", label = "light", valid = valid })
    L:adopt(self.lamps.e, fromOldLamp)
    L:adopt(self.built, fromOldBuilt)
    after(L, self.lamps)
    L:summary()
    local C = Store.open(NAME .. "Circuits", { id = "circuits", label = "circuit", valid = validCircuit, mirror = true })
    C:adopt(self.circuits.c, same)
    after(C, self.circuits)
    C:summary()
    Ledger.circuits = C
    -- 存檔已在 new 時讀回（原版 SGlobalObjectSystem.lua:13-16）：0.3.0 以前的燈照所在的 chunk 分好，讀到那一塊時定案（檔尾）。
    -- 上一場已經發了編號的那幾筆在 built 裡原樣留著（不加東西：主系統的存檔在搬完之前只能變小）：分片裡有同一個位置、
    -- 同一張圖的燈就是它，這時才刪；沒有（分片那次沒寫成）就重新等。有舊鍵才掃一次分片
    byChunk = {}
    local n, done, seen = 0, {}, nil
    for k in pairs(self.built) do
        local x, y, z, name = parseKey(k)
        if x and not isLanding(k) then
            if not seen then
                seen = {}
                L:each(function(id, e)
                    if type(id) == "number" then seen[e.p .. "," .. e.s] = true end
                end)
            end
            local p = Store.pos(x, y, z)
            if p and seen[p .. "," .. name] then
                done[#done + 1] = k
            else
                local ck = chunkOf(x, y)
                local t = byChunk[ck] or {}
                t[#t + 1] = k
                byChunk[ck] = t
                n = n + 1
            end
        end
    end
    for _, k in ipairs(done) do self.built[k] = nil end
    Ledger.legacy = n
    Ledger.instance = self
    if n > 0 then print(LOG .. "LEDGER legacy lights waiting: " .. n) end
    watchLegacy(n > 0)
end

-- GOS 會對系統表呼叫這幾個（SGlobalObjectSystem.java:111-162）；本系統不持有全域物件、不收客戶端指令
function Ledger:getInitialStateForClient() return nil end
function Ledger:isValidIsoObject() return false end
function Ledger:newLuaObject() error("MinidoracatBuilder ledger owns no global objects") end
function Ledger:OnChunkLoaded() end
function Ledger:OnClientCommand() end

SGlobalObjectSystem.RegisterSystemClass(Ledger)

-- "x,y,z,圖名"：平台在 built 的鍵、線路成員的鍵（Circuits）。燈的退料不用它
function Ledger.key(obj)
    local sq, spr = obj:getSquare(), obj:getSprite()
    if not (sq and spr and spr:getName()) then return nil end
    return sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ() .. "," .. spr:getName()
end

local function pos(sq) return Store.pos(sq:getX(), sq:getY(), sq:getZ()) end

-- 這盞燈的那一筆與編號：物件的 keyId 有那一筆，而且位置、現在的圖都和那一筆記的一樣；否則 nil。
-- 圖和蓋的時候不同就不認：拆除照現在的圖分種類（同一樓地板的帳本）。比位置與圖也分得開重發的編號：當機回溯時帳本回到
-- 上次存檔、物件的 keyId 跟著 chunk 存檔，之後發的編號可能和留在世界裡的燈相同。
local function lampOf(obj)
    local id, sq, spr = obj:getKeyId(), obj:getSquare(), obj:getSprite()
    local e = id > 0 and sq and spr and L:get(id)
    if e and e.p == pos(sq) and e.s == spr:getName() then return e, id end
    return nil
end

-- 發一個新編號給燈或家電，寫進帳本與物件（items 照抄），回編號。記不進去時編號不用掉、物件不動、記 log，之後這件本工具
-- 拆不了：回 nil＝每一片都滿了（之後放得下還能記），回 false＝這一筆讀不懂（退料表不對、位置超出範圍）
local function issue(inst, obj, sq, items)
    local id = inst.lamps.next
    local e = { p = pos(sq), s = obj:getSprite():getName(), i = items }
    local ok = valid(e, id)
    if ok and L:put(id, e) then
        inst.lamps.next = id + 1
        obj:setKeyId(id)
        return id
    end
    print(LOG .. "light ledger " .. (ok and "full" or "unreadable refund") .. "; not recorded: " .. tostring(Ledger.key(obj)))
    return ok and nil
end

-- 記下本 MOD 蓋好的燈、家電或補的平台（items＝拆了退什麼）。帳本還沒建（不該發生）時只記 log：之後這件拆不了（大錘照樣能砸），
-- 平台拆樓梯時留著。
function Ledger.put(obj, items)
    local inst, k = Ledger.instance, Ledger.key(obj)
    if not (inst and k) then
        print(LOG .. "ledger not ready; not recorded: " .. tostring(k))
        return
    end
    local copy = {}
    for ft, n in pairs(items) do copy[ft] = n end
    if MinidoracatBuilder.Place.keyed(obj) then
        issue(inst, obj, obj:getSquare(), copy)
    elseif not (valid(copy, k) and L:put(k, copy)) then
        print(LOG .. "light ledger full or unreadable refund; not recorded: " .. k)
    end
end

-- 拆了退什麼；不是本 MOD 蓋的回 nil
function Ledger.get(obj)
    if not Ledger.instance then return nil end
    if MinidoracatBuilder.Place.keyed(obj) then
        local e = lampOf(obj)
        return e and e.i or nil
    end
    local k = Ledger.key(obj)
    return k and L:get(k) or nil
end

-- 移出世界前清掉（拿起、砸、拆、多格整組拆都會觸發，RemoveItemFromSquarePacket.java:151、IsoGridSquare.java:5732）。
-- 燈與家電只清自己那一筆（認法同 Ledger.get）
function Ledger.forget(obj)
    if not Ledger.instance then return end
    if MinidoracatBuilder.Place.keyed(obj) then
        local e, id = lampOf(obj)
        if e then L:del(id) end
        return
    end
    local k = Ledger.key(obj)
    if k then L:del(k) end
end

local STAIR_FLOOR = MinidoracatBuilder.Entry.STAIR_FLOOR
Events.OnObjectAboutToBeRemoved.Add(function(obj)
    if MinidoracatBuilder.Place.keyed(obj) then return MinidoracatBuilder.Ledger.forget(obj) end
    local spr = obj:getSprite()
    if spr and spr:getName() == STAIR_FLOOR and not instanceof(obj, "IsoThumpable") then MinidoracatBuilder.Ledger.forget(obj) end
end)

-- ---------------------------------------------------------------- 0.3.0 以前的燈（0.4.0 起發編號）
-- built 照「位置＋圖名」記。升版後每個 chunk 第一次讀進來時，那一塊的舊鍵全部定案：那一格帳本還認不得（keyId -1，或當機回溯後
-- 帳本沒有那一筆）、圖名相同的本 MOD 燈剛好一盞，就發編號、記進燈的帳本；沒有或有兩盞以上（分不出是哪一盞）就刪掉
-- 那一筆，那盞本工具拆不了（大錘照樣能砸）。記號只用來挑要搬哪一盞，退料照 built。
-- 發了編號的那一筆不當場刪（主系統和分片不是同一個檔）、也不改：原樣留到下一次開服，分片讀得到那盞才刪（initSystem）；
-- 這一場拆掉那盞時跟著刪（Store.track）。帳本滿了記不進去的那一筆一樣留著，下次開服再試。
-- 一塊讀完觸發一次 LoadChunk（IsoChunk.java:3968），物件在那之前就從存檔讀進來（IsoChunk.java:2324,3799-3837），所以用
-- getObjects 找整塊的燈。只在還有舊鍵時掛 LoadChunk：舊鍵所在的塊沒人去就一直掛著，但每塊只取一格、查一次表；
-- 全部定案（或出錯、留到下次開服）就摘掉。不掛逐格的 LoadGridsquare：那是每讀一格都跑一次。
local function candidate(inst, o, name)
    if not (instanceof(o, "IsoLightSwitch") and o:hasModData() and o:getModData().builderEntry) then return false end
    local spr = o:getSprite()
    return spr ~= nil and spr:getName() == name and lampOf(o) == nil
end

local function settle(inst, chunk, keys)
    for _, k in ipairs(keys) do
        local items = inst.built[k]
        if items then
            local x, y, z, name = parseKey(k)
            local sq = chunk:getGridSquare(x % CHUNK, y % CHUNK, z)
            local objs = sq and sq:getObjects()
            local found, n = nil, 0
            for i = 0, (objs and objs:size() or 0) - 1 do
                local o = objs:get(i)
                if candidate(inst, o, name) then found, n = o, n + 1 end
            end
            local id = n == 1 and issue(inst, found, sq, items)
            if id then
                L:track(id, inst.built, k)
                print(LOG .. "LEDGER adopt light id=" .. id .. " key=" .. k)
            elseif id == nil then -- 帳本滿了：留著，下次開服再試
                print(LOG .. "LEDGER legacy light kept for the next start: " .. k)
            else -- 沒有或有兩盞以上，或那一筆讀不懂（重試也一樣）
                inst.built[k] = nil
                print(LOG .. "LEDGER legacy light dropped (" .. n .. " lights): " .. k)
            end
            if id ~= nil then Ledger.legacy = Ledger.legacy - 1 end
        else
            Ledger.legacy = Ledger.legacy - 1
        end
    end
end

-- 出錯時那一塊剩下的舊鍵留在 built，下次開服重新分組再試
local function settleChunk(inst, ck, chunk)
    local keys = byChunk[ck]
    if not (keys and chunk) then return end
    byChunk[ck] = nil
    local ok, err = pcall(settle, inst, chunk, keys)
    if not ok then print(LOG .. "light ledger adopt failed: " .. tostring(err)) end
    -- 還有塊沒讀到。不用 pairs 判空：Kahlua 的 pairs 先把整張表的鍵複製一份（KahluaTableImpl.java:154-156）
    if not table.isempty(byChunk) then return end
    watchLegacy(false)
    print(LOG .. "LEDGER legacy lights done, unsettled=" .. Ledger.legacy)
end

-- 這一塊的任一格（定位用）：原點那格幾乎都有，沒有時逐格找
local function anySquare(chunk)
    local sq = chunk:getGridSquare(0, 0, 0)
    if sq then return sq end
    for z = chunk:getMinLevel(), chunk:getMaxLevel() do
        for i = 0, CHUNK * CHUNK - 1 do
            sq = chunk:getGridSquare(i % CHUNK, math.floor(i / CHUNK), z)
            if sq then return sq end
        end
    end
    return nil
end

local function onLoadChunk(chunk)
    local sq = anySquare(chunk)
    local ck = sq and chunkOf(sq:getX(), sq:getY())
    if ck and byChunk[ck] then settleChunk(Ledger.instance, ck, chunk) end
end

-- 帳本建好之前就讀進來的塊（單機讀檔先讀格子、後建帳本，GameLoadingState.java:307,316）：建好後的第一個 tick 照舊鍵的位置找，
-- 那一塊在就定案，不在的等它讀進來。專用伺服器先建帳本再讀格子，這時一塊都還沒有。
local function settleLoaded()
    Events.OnTick.Remove(settleLoaded)
    local inst, cell, found = Ledger.instance, getCell(), {}
    for ck, keys in pairs(byChunk) do
        local x, y, z = parseKey(keys[1])
        found[ck] = cell:getChunkForGridSquare(x, y, z)
    end
    for ck, chunk in pairs(found) do settleChunk(inst, ck, chunk) end
end

watchLegacy = function(on)
    Events.LoadChunk.Remove(onLoadChunk)
    Events.OnTick.Remove(settleLoaded)
    if on then
        Events.LoadChunk.Add(onLoadChunk)
        Events.OnTick.Add(settleLoaded)
    end
end

return Ledger
