-- 一樓以下地板的退料帳本（只在伺服器）：本 MOD 蓋的一樓以下地板不寫 buildMaterials（Place.groundFloor），本工具拆的時候
-- 照這裡退（Place.refundOf）。鍵是位置 "x,y,z"：同一格只有一片本 MOD 的地板（放地板前 Place.clearFloor 先拆掉舊的）。
-- 值記蓋的圖名與退料表，現在的圖和蓋的圖一樣才退。和燈、平台的帳本（Ledger）分開，各自一個存檔
-- （gos_MinidoracatBuilderFloors.bin，跟世界一起存檔、一起回溯）；不建全域物件、不送客戶端。
-- ponytail：一筆約 80 bytes，單一 GOS 系統存檔上限 10 MiB（pz-family-docs pitfalls）約十二萬片；真的逼近時照
-- VehicleManager 改分片。
if isClient() then return end
require "Map/SGlobalObjectSystem"

MinidoracatBuilder = MinidoracatBuilder or {}
local Floors = SGlobalObjectSystem:derive("MinidoracatBuilderFloors")
MinidoracatBuilder.Floors = Floors

function Floors:new()
    return SGlobalObjectSystem.new(self, "MinidoracatBuilderFloors")
end

function Floors:initSystem()
    SGlobalObjectSystem.initSystem(self)
    -- 存檔只存白名單裡的鍵：漏設＝這一場正常、重開後帳本消失
    self.system:setModDataKeys({ "floors" })
    self.system:setObjectModDataKeys({})
    self.system:setObjectSyncKeys({})
    if type(self.floors) ~= "table" then self.floors = {} end
    Floors.instance = self
end

-- GOS 會對系統表呼叫這幾個（SGlobalObjectSystem.java:111-162）；本系統不持有全域物件、不收客戶端指令
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

-- 記下這片地板蓋的圖與退料（items＝拆了退什麼，沒付料的是空表）。帳本還沒建（不該發生）時只記 log：之後這片本工具拆不了。
function Floors.put(obj, items)
    local inst, k, spr = Floors.instance, key(obj), obj:getSprite()
    local name = spr and spr:getName()
    if not (inst and k and name) then
        print("[MinidoracatBuilderFor42] floor ledger not ready; not recorded: " .. tostring(k))
        return
    end
    local copy = {}
    for ft, n in pairs(items) do copy[ft] = n end
    inst.floors[k] = { s = name, i = copy }
end

-- 這一格的那筆：{ s = 蓋的圖名, i = 退料表 }，沒有回 nil
function Floors.get(obj)
    local inst, k = Floors.instance, key(obj)
    return inst and k and inst.floors[k] or nil
end

-- 移出世界前清掉（Place.onAboutToBeRemoved）
function Floors.forget(obj)
    local inst, k = Floors.instance, key(obj)
    if inst and k then inst.floors[k] = nil end
end

return Floors
