-- 一樓以下地板的退料帳本（只在伺服器）：本 MOD 蓋的一樓以下地板不寫 buildMaterials（Place.groundFloor），本工具拆的時候
-- 照這裡退（Place.refundOf）。本工具挖的水面也記在這裡（Place.dig，退料是空表）：填平時照這一筆認是不是本工具挖的。
-- 一格一筆：同一格只有一片本 MOD 的地板（放地板前 Place.clearFloor 先拆掉舊的）。值記蓋的圖名與退料表
-- { s = 圖名, i = { [物品型別] = 數量 } }，現在的圖和蓋的圖一樣才退。
-- 存檔在 Store（gos_MinidoracatBuilderFloors_<n>.bin，跟世界一起存檔、一起回溯）：鍵是位置算成的數字（Store.pos），
-- 值存對照表的編號。主系統 MinidoracatBuilderFloors 只留分片以前的存檔（floors["x,y,z"]，Store.adopt 搬完就清）。
if isClient() then return end
require "Map/SGlobalObjectSystem"
require "MinidoracatBuilder/Store"

MinidoracatBuilder = MinidoracatBuilder or {}
local NAME = "MinidoracatBuilderFloors"
local LOG = "[MinidoracatBuilderFor42] "
local Store = MinidoracatBuilder.Store
local Floors = SGlobalObjectSystem:derive(NAME)
MinidoracatBuilder.Floors = Floors

local S -- 這一場的帳本（initSystem 開）

function Floors:new()
    return SGlobalObjectSystem.new(self, NAME)
end

-- 一筆只有圖名 s 與退料表 i。多的、型別不對的都不收，大小才算得準
local function valid(e)
    if type(e) ~= "table" or type(e.s) ~= "string" or not Store.isRefund(e.i) then return false end
    for f in pairs(e) do
        if f ~= "s" and f ~= "i" then return false end
    end
    return true
end

local function sig(e) return e.s .. "\4" .. Store.itemsSig(e.i) end

-- 分片以前的鍵 "x,y,z"
local function fromOld(k, e)
    if type(k) ~= "string" then return nil end
    local x, y, z = k:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
    if not x then return nil end
    return Store.pos(tonumber(x), tonumber(y), tonumber(z)), e
end

function Floors:initSystem()
    -- 同一個系統表只建一次（原版在 OnSGlobalObjectSystemInit 建系統）。再呼叫不重讀：還沒存檔的片不在存檔資料夾裡
    if Floors.instance == self then return end
    SGlobalObjectSystem.initSystem(self)
    -- 存檔只存白名單裡的鍵：漏設＝這一場正常、重開後帳本消失
    self.system:setModDataKeys({ "floors" })
    self.system:setObjectModDataKeys({})
    self.system:setObjectSyncKeys({})
    S = Store.open(NAME, { id = "floors", label = "floor", valid = valid, sig = sig })
    if type(self.floors) ~= "table" then self.floors = {} end
    S:adopt(self.floors, fromOld)
    S:summary()
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
    return sq and Store.pos(sq:getX(), sq:getY(), sq:getZ()) or nil
end

local function at(obj)
    local sq = obj:getSquare()
    return sq and (sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ()) or "?"
end

-- 記下這片地板蓋的圖與退料（items＝拆了退什麼，沒付料的是空表）。帳本還沒建（不該發生）、退料表不是「物品型別 → 數量」
-- 或每一片都滿了時只記 log：之後這片本工具拆不了。
function Floors.put(obj, items)
    local k, spr = Floors.instance and key(obj), obj:getSprite()
    local name = spr and spr:getName()
    if not (k and name) then
        print(LOG .. "floor ledger not ready; not recorded: " .. at(obj))
        return
    end
    local e = { s = name, i = {} }
    for ft, n in pairs(items) do e.i[ft] = n end
    if not valid(e) then
        print(LOG .. "floor ledger: unreadable refund; not recorded: " .. at(obj))
    elseif not S:put(k, e) then
        print(LOG .. "floor ledger full; not recorded: " .. at(obj))
    end
end

-- 這一格的那筆：{ s = 蓋的圖名, i = 退料表 }，沒有回 nil。回的表很多格共用，不能改
function Floors.get(obj)
    local k = Floors.instance and key(obj)
    return k and S:get(k) or nil
end

-- 移出世界前清掉（Place.onAboutToBeRemoved）
function Floors.forget(obj)
    local k = Floors.instance and key(obj)
    if k then S:del(k) end
end

-- 帳本現在的樣子（離線測試與實機驗證用）：筆數、每一片的筆數與估計 bytes
function Floors.stats()
    return S:stats()
end

return Floors
