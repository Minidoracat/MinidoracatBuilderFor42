-- 伺服器帳本（設計稿「伺服器帳本」）：本 MOD 蓋的燈、開關與家電，以及樓梯頂端補的平台地板。燈與家電沒有 buildMaterials，
-- 平台是一般 IsoObject（和原版樓梯補的長得一樣），所以「是不是本 MOD 蓋的、拆了退什麼」只認這裡（只在伺服器）。存在 GOS 系統
-- 自己的 modData（gos_MinidoracatBuilder.bin，跟世界一起存檔、一起回溯）；不建全域物件、不送客戶端。
-- 寫法照家族 VehicleManager 的帳本分片（MinidoracatVehicleManager_OwnershipSystem.lua:231-253）。
-- lamps＝燈、開關（IsoLightSwitch）與家電（壁爐這類，Place.keyed）：{ next = 下一個編號, e = { [編號] = { p = "x,y,z",
--   s = 蓋的圖名, i = { [fullType] = 退料數 } } } }。蓋的時候把編號寫進物件的 keyId（IsoObject 的欄位，任何類別都跟著存檔），
--   認物件看編號、位置與蓋的圖，不看 modData（見知識庫 placement.md「燈的帳本照編號認」）。
-- built＝樓梯平台：built["x,y,z,sprite"] = {}（只記是本 MOD 補的，不退料）。0.3.0 以前的燈也記在這裡（鍵同上、值是退料表；
--   0.4.0 起發編號），升版後讀到那一塊時搬進 lamps 或刪掉（檔尾）。
-- circuits＝第六階段的線路（格式與讀寫在 Circuits.lua；成員的鍵照 Ledger.key）。
-- ponytail：一筆約 100 bytes，單一 GOS 系統存檔上限 10 MiB（pz-family-docs pitfalls）約十萬盞；真的逼近時改分片。
if isClient() then return end
require "Map/SGlobalObjectSystem"
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Place"

MinidoracatBuilder = MinidoracatBuilder or {}
local Ledger = SGlobalObjectSystem:derive("MinidoracatBuilderLedger")
MinidoracatBuilder.Ledger = Ledger

local LOG = "[MinidoracatBuilderFor42] "
local LANDING = "," .. MinidoracatBuilder.Entry.STAIR_FLOOR

local function isLanding(k) return k:sub(-#LANDING) == LANDING end

local CHUNK = 8 -- IsoChunk 一邊幾格（IsoChunk.java:3763,3801）
local function chunkOf(x, y) return math.floor(x / CHUNK) * 100000 + math.floor(y / CHUNK) end
local byChunk = {} -- 還沒定案的 0.3.0 舊燈鍵，照所在的 chunk 分（檔尾）
local watchLegacy -- 檔尾：還有舊鍵時才掛讀 chunk 的事件

local function parseKey(k)
    local x, y, z, name = string.match(k, "^(%-?%d+),(%-?%d+),(%-?%d+),(.+)$")
    if not x then return nil end
    return tonumber(x), tonumber(y), tonumber(z), name
end

function Ledger:new()
    return SGlobalObjectSystem.new(self, "MinidoracatBuilder")
end

function Ledger:initSystem()
    SGlobalObjectSystem.initSystem(self)
    -- 存檔只存白名單裡的鍵：漏設＝這一場正常、重開後帳本消失
    self.system:setModDataKeys({ "built", "circuits", "lamps" })
    self.system:setObjectModDataKeys({})
    self.system:setObjectSyncKeys({})
    if type(self.built) ~= "table" then self.built = {} end
    if type(self.lamps) ~= "table" then self.lamps = { next = 1, e = {} } end
    -- 存檔已在 new 時讀回（原版 SGlobalObjectSystem.lua:13-16）：0.3.0 以前的燈照所在的 chunk 分好，讀到那一塊時定案（檔尾）
    byChunk = {}
    local n = 0
    for k in pairs(self.built) do
        local x, y = parseKey(k)
        if x and not isLanding(k) then
            local ck = chunkOf(x, y)
            local t = byChunk[ck] or {}
            t[#t + 1] = k
            byChunk[ck] = t
            n = n + 1
        end
    end
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

local function pos(sq) return sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ() end

-- 這盞燈在 lamps 的那一筆與編號：物件的 keyId 有那一筆，而且位置、現在的圖都和那一筆記的一樣；否則 nil。
-- 圖和蓋的時候不同就不認：拆除照現在的圖分種類（同一樓地板的帳本）。比位置與圖也分得開重發的編號：當機回溯時帳本回到
-- 上次存檔、物件的 keyId 跟著 chunk 存檔，之後發的編號可能和留在世界裡的燈相同。
local function lampOf(inst, obj)
    local id, sq, spr = obj:getKeyId(), obj:getSquare(), obj:getSprite()
    local e = id > 0 and sq and spr and inst.lamps.e[id]
    if e and e.p == pos(sq) and e.s == spr:getName() then return e, id end
    return nil
end

-- 發一個新編號給燈或家電，寫進物件與帳本（items 照抄）
local function issue(inst, obj, sq, items)
    local id = inst.lamps.next
    inst.lamps.next = id + 1
    obj:setKeyId(id)
    inst.lamps.e[id] = { p = pos(sq), s = obj:getSprite():getName(), i = items }
    return id
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
    else
        inst.built[k] = copy
    end
end

-- 拆了退什麼；不是本 MOD 蓋的回 nil
function Ledger.get(obj)
    local inst = Ledger.instance
    if not inst then return nil end
    if MinidoracatBuilder.Place.keyed(obj) then
        local e = lampOf(inst, obj)
        return e and e.i or nil
    end
    local k = Ledger.key(obj)
    return k and inst.built[k] or nil
end

-- 移出世界前清掉（拿起、砸、拆、多格整組拆都會觸發，RemoveItemFromSquarePacket.java:151、IsoGridSquare.java:5745）。
-- 燈與家電只清自己那一筆（認法同 Ledger.get）
function Ledger.forget(obj)
    local inst = Ledger.instance
    if not inst then return end
    if MinidoracatBuilder.Place.keyed(obj) then
        local e, id = lampOf(inst, obj)
        if e then inst.lamps.e[id] = nil end
        return
    end
    local k = Ledger.key(obj)
    if k then inst.built[k] = nil end
end

local STAIR_FLOOR = MinidoracatBuilder.Entry.STAIR_FLOOR
Events.OnObjectAboutToBeRemoved.Add(function(obj)
    if MinidoracatBuilder.Place.keyed(obj) then return MinidoracatBuilder.Ledger.forget(obj) end
    local spr = obj:getSprite()
    if spr and spr:getName() == STAIR_FLOOR and not instanceof(obj, "IsoThumpable") then MinidoracatBuilder.Ledger.forget(obj) end
end)

-- ---------------------------------------------------------------- 0.3.0 以前的燈（0.4.0 起發編號）
-- built 照「位置＋圖名」記。升版後每個 chunk 第一次讀進來時，那一塊的舊鍵全部定案：那一格帳本還認不得（keyId -1，或當機回溯後
-- 帳本沒有那一筆）、圖名相同的本 MOD 燈剛好一盞，就發編號、把那一筆搬進 lamps；沒有或有兩盞以上（分不出是哪一盞）就刪掉
-- 那一筆，那盞本工具拆不了（大錘照樣能砸）。記號只用來挑要搬哪一盞，退料照 built。
-- 一塊讀完觸發一次 LoadChunk（IsoChunk.java:3969），物件在那之前就從存檔讀進來（IsoChunk.java:2325,3800-3838），所以用
-- getObjects 找整塊的燈。只在還有舊鍵時掛 LoadChunk：舊鍵所在的塊沒人去就一直掛著，但每塊只取一格、查一次表；
-- 全部定案（或出錯、留到下次開服）就摘掉。不掛逐格的 LoadGridsquare：那是每讀一格都跑一次。
local function candidate(inst, o, name)
    if not (instanceof(o, "IsoLightSwitch") and o:hasModData() and o:getModData().builderEntry) then return false end
    local spr = o:getSprite()
    return spr ~= nil and spr:getName() == name and lampOf(inst, o) == nil
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
            inst.built[k] = nil
            if id then
                print(LOG .. "LEDGER adopt light id=" .. id .. " key=" .. k)
            else
                print(LOG .. "LEDGER legacy light dropped (" .. n .. " lights): " .. k)
            end
        end
        Ledger.legacy = Ledger.legacy - 1
    end
end

-- 出錯時那一塊剩下的舊鍵留在 built，下次開服重新分組再試
local function settleChunk(inst, ck, chunk)
    local keys = byChunk[ck]
    if not (keys and chunk) then return end
    byChunk[ck] = nil
    local ok, err = pcall(settle, inst, chunk, keys)
    if not ok then print(LOG .. "light ledger adopt failed: " .. tostring(err)) end
    -- 還有塊沒讀到。不用 pairs 判空：Kahlua 的 pairs 先把整張表的鍵複製一份（KahluaTableImpl.java:152-154）
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

-- 帳本建好之前就讀進來的塊（單機讀檔先讀格子、後建帳本，GameLoadingState.java:305,313）：建好後的第一個 tick 照舊鍵的位置找，
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
