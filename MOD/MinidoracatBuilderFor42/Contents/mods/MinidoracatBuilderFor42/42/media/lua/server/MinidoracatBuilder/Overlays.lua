-- 掛在地板上的地面覆蓋的帳本（只在伺服器）：本 MOD 掛上去的圖（Place.attach）不是物件，沒有 buildMaterials，
-- 「是不是本 MOD 掛的、拆了退什麼」只認這裡。照格子分：overlays["x,y,z"] = { [圖名] = 退料表 }（同一格的地板不掛兩張
-- 同名的，Place.check）。地板物件移出世界時整格清掉（dropFloor），不看那時還掛著哪幾張。
-- 和燈、平台的帳本（Ledger）、一樓地板的帳本（Floors）分開，各自一個存檔（gos_MinidoracatBuilderOverlays.bin，跟世界一起
-- 存檔、一起回溯）；不建全域物件、不送客戶端。
-- ponytail：一筆約 90 bytes，單一 GOS 系統存檔上限 10 MiB（pz-family-docs pitfalls）約十萬張；真的逼近時照
-- VehicleManager 改分片。
if isClient() then return end
require "Map/SGlobalObjectSystem"

MinidoracatBuilder = MinidoracatBuilder or {}
local Overlays = SGlobalObjectSystem:derive("MinidoracatBuilderOverlays")
MinidoracatBuilder.Overlays = Overlays

function Overlays:new()
    return SGlobalObjectSystem.new(self, "MinidoracatBuilderOverlays")
end

function Overlays:initSystem()
    SGlobalObjectSystem.initSystem(self)
    -- 存檔只存白名單裡的鍵：漏設＝這一場正常、重開後帳本消失
    self.system:setModDataKeys({ "overlays" })
    self.system:setObjectModDataKeys({})
    self.system:setObjectSyncKeys({})
    if type(self.overlays) ~= "table" then self.overlays = {} end
    Overlays.instance = self
end

-- GOS 會對系統表呼叫這幾個（SGlobalObjectSystem.java:111-162）；本系統不持有全域物件、不收客戶端指令
function Overlays:getInitialStateForClient() return nil end
function Overlays:isValidIsoObject() return false end
function Overlays:newLuaObject() error("MinidoracatBuilder overlays own no global objects") end
function Overlays:OnChunkLoaded() end
function Overlays:OnClientCommand() end

SGlobalObjectSystem.RegisterSystemClass(Overlays)

local function pos(sq)
    return sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ()
end

-- 記下 sq 掛上的 name 拆了退什麼（items；沒付料的是空表）。帳本還沒建（不該發生）時只記 log：之後這張本工具拆不了。
function Overlays.put(sq, name, items)
    local inst = Overlays.instance
    if not inst then
        print("[MinidoracatBuilderFor42] overlay ledger not ready; not recorded: " .. pos(sq) .. "," .. name)
        return
    end
    local copy = {}
    for ft, n in pairs(items) do copy[ft] = n end
    local k = pos(sq)
    local here = inst.overlays[k] or {}
    here[name] = copy
    inst.overlays[k] = here
end

-- sq 上本 MOD 掛的 name 拆了退什麼；沒有那一筆回 nil
function Overlays.get(sq, name)
    local inst = Overlays.instance
    local here = inst and inst.overlays[pos(sq)]
    return here and here[name] or nil
end

-- sq 這一格帳本的複本（{ [圖名] = 退料表 }）；沒有回 nil。原地換一樓地板前先記下來，換好再照它掛回去（Server.complete）
function Overlays.at(sq)
    local inst = Overlays.instance
    local here = inst and inst.overlays[pos(sq)]
    if not here then return nil end
    local copy = {}
    for name, items in pairs(here) do copy[name] = items end
    return copy
end

function Overlays.forget(sq, name)
    local inst = Overlays.instance
    local k = inst and pos(sq)
    local here = k and inst.overlays[k]
    if not here then return end
    here[name] = nil
    for _ in pairs(here) do return end
    inst.overlays[k] = nil
end

-- 地板物件移出世界前（Place.onAboutToBeRemoved）：掛在它上面的圖跟著消失，那一格整格清掉。只看那格的地板，別的物件
-- 移除不算（地面覆蓋只掛在地板上）。
function Overlays.dropFloor(obj)
    local inst, sq = Overlays.instance, obj:getSquare()
    if inst and sq and sq:getFloor() == obj then inst.overlays[pos(sq)] = nil end
end

return Overlays
