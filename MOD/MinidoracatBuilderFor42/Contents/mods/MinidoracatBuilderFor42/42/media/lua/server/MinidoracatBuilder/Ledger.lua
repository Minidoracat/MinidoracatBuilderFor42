-- 伺服器帳本（設計稿「伺服器帳本」）：本 MOD 蓋的燈與開關，以及樓梯頂端補的平台地板。燈沒有 buildMaterials，平台是一般
-- IsoObject（和原版樓梯補的長得一樣），所以「是不是本 MOD 蓋的、拆了退什麼」只認這裡（只在伺服器）。存在 GOS 系統
-- 自己的 modData（gos_MinidoracatBuilder.bin，跟世界一起存檔、一起回溯）；不建全域物件、不送客戶端。
-- 寫法照家族 VehicleManager 的帳本分片（MinidoracatVehicleManager_OwnershipSystem.lua:231-253）。
-- built[鍵] = { [fullType] = 退料數 }（平台是空表：不退料，只記是本 MOD 補的），鍵＝"x,y,z,sprite"（同一格不放同一張圖，
-- Place 的 hasSprite）。circuits＝第六階段的線路（格式與讀寫在 Circuits.lua）。
-- ponytail：一筆約 100 bytes，單一 GOS 系統存檔上限 10 MiB（pz-family-docs pitfalls）約十萬盞；真的逼近時改分片。
if isClient() then return end
require "Map/SGlobalObjectSystem"
require "MinidoracatBuilder/Entry"

MinidoracatBuilder = MinidoracatBuilder or {}
local Ledger = SGlobalObjectSystem:derive("MinidoracatBuilderLedger")
MinidoracatBuilder.Ledger = Ledger

local LOG = "[MinidoracatBuilderFor42] "

function Ledger:new()
    return SGlobalObjectSystem.new(self, "MinidoracatBuilder")
end

function Ledger:initSystem()
    SGlobalObjectSystem.initSystem(self)
    -- 存檔只存白名單裡的鍵：漏設＝這一場正常、重開後帳本消失
    self.system:setModDataKeys({ "built", "circuits" })
    self.system:setObjectModDataKeys({})
    self.system:setObjectSyncKeys({})
    if type(self.built) ~= "table" then self.built = {} end
    Ledger.instance = self
end

-- GOS 會對系統表呼叫這幾個（SGlobalObjectSystem.java:111-162）；本系統不持有全域物件、不收客戶端指令
function Ledger:getInitialStateForClient() return nil end
function Ledger:isValidIsoObject() return false end
function Ledger:newLuaObject() error("MinidoracatBuilder ledger owns no global objects") end
function Ledger:OnChunkLoaded() end
function Ledger:OnClientCommand() end

SGlobalObjectSystem.RegisterSystemClass(Ledger)

function Ledger.key(obj)
    local sq, spr = obj:getSquare(), obj:getSprite()
    if not (sq and spr and spr:getName()) then return nil end
    return sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ() .. "," .. spr:getName()
end

-- 記下本 MOD 蓋好的燈或補的平台（items＝拆了退什麼）。帳本還沒建（不該發生）時只記 log：之後這盞燈拆不了（大錘照樣能砸），
-- 平台拆樓梯時留著。
function Ledger.put(obj, items)
    local inst, k = Ledger.instance, Ledger.key(obj)
    if not (inst and k) then
        print(LOG .. "ledger not ready; light not recorded: " .. tostring(k))
        return
    end
    local copy = {}
    for ft, n in pairs(items) do copy[ft] = n end
    inst.built[k] = copy
end

function Ledger.get(obj)
    local inst, k = Ledger.instance, Ledger.key(obj)
    return inst and k and inst.built[k] or nil
end

-- 移出世界前清掉（拿起、砸、拆、多格整組拆都會觸發，RemoveItemFromSquarePacket.java:151、IsoGridSquare.java:5745）
function Ledger.forget(obj)
    local inst, k = Ledger.instance, Ledger.key(obj)
    if inst and k then inst.built[k] = nil end
end

local STAIR_FLOOR = MinidoracatBuilder.Entry.STAIR_FLOOR
Events.OnObjectAboutToBeRemoved.Add(function(obj)
    if instanceof(obj, "IsoLightSwitch") then return MinidoracatBuilder.Ledger.forget(obj) end
    local spr = obj:getSprite()
    if spr and spr:getName() == STAIR_FLOOR and not instanceof(obj, "IsoThumpable") then MinidoracatBuilder.Ledger.forget(obj) end
end)

return Ledger
