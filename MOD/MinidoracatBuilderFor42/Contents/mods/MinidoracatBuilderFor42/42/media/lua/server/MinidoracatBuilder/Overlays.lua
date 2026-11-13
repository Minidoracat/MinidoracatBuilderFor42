-- 掛上去的地面覆蓋與牆面疊圖的帳本（只在伺服器）：本 MOD 掛上去的圖（Place.attach）不是物件，沒有 buildMaterials，
-- 「是不是本 MOD 掛的、拆了退什麼」只認這裡。照掛在哪一件分：那一格的地板，或那一格某條邊的牆（邊＝N／W／SE，
-- Rules.onWall）；值是 { [圖名] = 退料表 }（同一件上不掛兩張同名的，Place.check）。那一件移出世界時清掉（drop）。
-- 和燈、平台的帳本（Ledger）、一樓地板的帳本（Floors）分開。存檔在 Store（gos_MinidoracatBuilderOverlays_<n>.bin，
-- 跟世界一起存檔、一起回溯）：鍵是位置與邊算成的數字（Store.pos），值存對照表的編號，所以改一件掛的圖是換一張新的表，
-- 不改原本那張。主系統 MinidoracatBuilderOverlays 只留分片以前的存檔（overlays["x,y,z"]、["x,y,z,邊"]，Store.adopt
-- 搬完就清）。
if isClient() then return end
require "Map/SGlobalObjectSystem"
require "MinidoracatBuilder/Store"

MinidoracatBuilder = MinidoracatBuilder or {}
local NAME = "MinidoracatBuilderOverlays"
local LOG = "[MinidoracatBuilderFor42] "
local Store = MinidoracatBuilder.Store
local Overlays = SGlobalObjectSystem:derive(NAME)
MinidoracatBuilder.Overlays = Overlays

local S -- 這一場的帳本（initSystem 開）
local EDGE = { N = 1, W = 2, SE = 3 } -- Store.pos 的 edge；0＝地板
local EDGES = { "N", "W", "SE" }

function Overlays:new()
    return SGlobalObjectSystem.new(self, NAME)
end

local function valid(here)
    if type(here) ~= "table" then return false end
    for name, items in pairs(here) do
        if type(name) ~= "string" or not Store.isRefund(items) then return false end
    end
    return true
end

local function sig(here)
    local names, n = Store.sorted(here)
    local s = ""
    for j = 1, n do s = s .. names[j] .. "\4" .. Store.itemsSig(here[names[j]]) .. "\5" end
    return s
end

-- 分片以前的鍵 "x,y,z"（地板，0.2.1 起）與 "x,y,z,邊"（牆）
local function fromOld(k, here)
    if type(k) ~= "string" then return nil end
    local x, y, z, edge = k:match("^(%-?%d+),(%-?%d+),(%-?%d+),?(%a*)$")
    local e = x and (edge == "" and 0 or EDGE[edge])
    if not e then return nil end
    return Store.pos(tonumber(x), tonumber(y), tonumber(z), e), here
end

function Overlays:initSystem()
    -- 同一個系統表只建一次；再呼叫不重讀（還沒存檔的片不在存檔資料夾裡）
    if Overlays.instance == self then return end
    SGlobalObjectSystem.initSystem(self)
    -- 存檔只存白名單裡的鍵：漏設＝這一場正常、重開後帳本消失
    self.system:setModDataKeys({ "overlays" })
    self.system:setObjectModDataKeys({})
    self.system:setObjectSyncKeys({})
    S = Store.open(NAME, { id = "overlays", label = "overlay", valid = valid, sig = sig, mirror = true })
    if type(self.overlays) ~= "table" then self.overlays = {} end
    S:adopt(self.overlays, fromOld)
    S:summary()
    Overlays.instance = self
end

-- GOS 會對系統表呼叫這幾個（SGlobalObjectSystem.java:111-162）；本系統不持有全域物件、不收客戶端指令
function Overlays:getInitialStateForClient() return nil end
function Overlays:isValidIsoObject() return false end
function Overlays:newLuaObject() error("MinidoracatBuilder overlays own no global objects") end
function Overlays:OnChunkLoaded() end
function Overlays:OnClientCommand() end

SGlobalObjectSystem.RegisterSystemClass(Overlays)

-- edge＝nil 是地板，其他是那條邊的牆。帳本還沒建、邊認不得或位置超出範圍回 nil
local function pos(sq, edge)
    local e = 0
    if edge then
        e = EDGE[edge]
        if not e then return nil end
    end
    return Overlays.instance and Store.pos(sq:getX(), sq:getY(), sq:getZ(), e) or nil
end

local function at(sq, edge, name)
    return sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ() .. (edge and "," .. edge or "") .. "," .. name
end

-- 記下 sq 掛上的 name 拆了退什麼（items；沒付料的是空表）。帳本還沒建（不該發生）、退料表不是「物品型別 → 數量」或
-- 每一片都滿了時只記 log：之後這張本工具拆不了。
function Overlays.put(sq, name, items, edge)
    local k = pos(sq, edge)
    if not k then
        print(LOG .. "overlay ledger not ready or position out of range; not recorded: " .. at(sq, edge, name))
        return
    end
    local copy = {}
    for ft, n in pairs(items) do copy[ft] = n end
    local here = { [name] = copy }
    for other, mats in pairs(S:get(k) or {}) do
        if other ~= name then here[other] = mats end
    end
    if not valid(here) then
        print(LOG .. "overlay ledger: unreadable refund; not recorded: " .. at(sq, edge, name))
    elseif not S:put(k, here) then
        print(LOG .. "overlay ledger full; not recorded: " .. at(sq, edge, name))
    end
end

-- sq 上本 MOD 掛的 name 拆了退什麼；沒有那一筆回 nil。回的表很多筆共用，不能改
function Overlays.get(sq, name, edge)
    local k = pos(sq, edge)
    local here = k and S:get(k)
    return here and here[name] or nil
end

-- sq 那一件（地板或那條邊的牆）帳本的複本（{ [圖名] = 退料表 }）；沒有回 nil。原地換一樓地板、換牆前先記下來，
-- 換好再照它掛回去（Server.complete）
function Overlays.at(sq, edge)
    local k = pos(sq, edge)
    local here = k and S:get(k)
    if not here then return nil end
    local copy = {}
    for name, items in pairs(here) do copy[name] = items end
    return copy
end

function Overlays.forget(sq, name, edge)
    local k = pos(sq, edge)
    local here = k and S:get(k)
    if not (here and here[name]) then return end
    local rest, any = {}, false
    for other, mats in pairs(here) do
        if other ~= name then rest[other], any = mats, true end
    end
    -- 剩下的記不回去（那一片滿到連一張新的對照表都放不下）就整件清掉：寧可剩下的拆不了，不留一筆已經拆掉的退料
    if any and S:put(k, rest) then return end
    if any then print(LOG .. "overlay ledger full; dropped: " .. at(sq, edge, name)) end
    S:del(k)
end

-- 物件移出世界前（Place.onAboutToBeRemoved，任何物件都會來）：它是那格的地板或那條邊的牆（Place.wallAt，伺服器自己找的
-- 宿主）時，掛在它上面的圖跟著消失，那一件的帳本整份清掉，不看那時還掛著哪幾張（圖可能先被別的路拿掉）。不是宿主的
-- 物件身上就算掛著同名的圖也不清：附加圖不能當帳本依據（審查 1112）。
-- 原地換牆時新牆插在舊牆前面，移除舊牆不清，Server.complete 照換之前記下的掛回新牆、覆寫那幾筆。
function Overlays.drop(obj)
    local sq = obj:getSquare()
    local k = sq and pos(sq, nil)
    if not k then return end
    if S:get(k) and sq:getFloor() == obj then S:del(k) end
    local Place = MinidoracatBuilder.Place
    for e = 1, 3 do
        if S:get(k + e) and Place.wallAt(sq, EDGES[e]) == obj then S:del(k + e) end
    end
end

return Overlays
