-- 掛上去的地面覆蓋與牆面疊圖的帳本（只在伺服器）：本 MOD 掛上去的圖（Place.attach）不是物件，沒有 buildMaterials，
-- 「是不是本 MOD 掛的、拆了退什麼」只認這裡。照掛在哪一件分：地板 overlays["x,y,z"]、牆 overlays["x,y,z,邊"]（邊＝N／W／SE，
-- Rules.onWall），值是 { [圖名] = 退料表 }（同一件上不掛兩張同名的，Place.check）。那一件移出世界時清掉（drop）。
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

-- edge＝nil 是地板（0.2.1 起的鍵，不改），其他是那條邊的牆
local function pos(sq, edge)
    local k = sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ()
    return edge and k .. "," .. edge or k
end

-- 記下 sq 掛上的 name 拆了退什麼（items；沒付料的是空表）。帳本還沒建（不該發生）時只記 log：之後這張本工具拆不了。
function Overlays.put(sq, name, items, edge)
    local inst = Overlays.instance
    if not inst then
        print("[MinidoracatBuilderFor42] overlay ledger not ready; not recorded: " .. pos(sq, edge) .. "," .. name)
        return
    end
    local copy = {}
    for ft, n in pairs(items) do copy[ft] = n end
    local k = pos(sq, edge)
    local here = inst.overlays[k] or {}
    here[name] = copy
    inst.overlays[k] = here
end

-- sq 上本 MOD 掛的 name 拆了退什麼；沒有那一筆回 nil
function Overlays.get(sq, name, edge)
    local inst = Overlays.instance
    local here = inst and inst.overlays[pos(sq, edge)]
    return here and here[name] or nil
end

-- sq 那一件（地板或那條邊的牆）帳本的複本（{ [圖名] = 退料表 }）；沒有回 nil。原地換一樓地板、換牆前先記下來，
-- 換好再照它掛回去（Server.complete）
function Overlays.at(sq, edge)
    local inst = Overlays.instance
    local here = inst and inst.overlays[pos(sq, edge)]
    if not here then return nil end
    local copy = {}
    for name, items in pairs(here) do copy[name] = items end
    return copy
end

function Overlays.forget(sq, name, edge)
    local inst = Overlays.instance
    local k = inst and pos(sq, edge)
    local here = k and inst.overlays[k]
    if not here then return end
    here[name] = nil
    for _ in pairs(here) do return end
    inst.overlays[k] = nil
end

-- 物件移出世界前（Place.onAboutToBeRemoved，任何物件都會來）：它是那格的地板或那條邊的牆（Place.wallAt，伺服器自己找的
-- 宿主）時，掛在它上面的圖跟著消失，那一件的帳本整份清掉，不看那時還掛著哪幾張（圖可能先被別的路拿掉）。不是宿主的
-- 物件身上就算掛著同名的圖也不清：附加圖不能當帳本依據（審查 1112）。
-- 原地換牆時新牆插在舊牆前面，移除舊牆不清，Server.complete 照換之前記下的掛回新牆、覆寫那幾筆。
function Overlays.drop(obj)
    local inst, sq = Overlays.instance, obj:getSquare()
    if not (inst and sq) then return end
    local k = pos(sq, nil)
    if inst.overlays[k] and sq:getFloor() == obj then inst.overlays[k] = nil end
    local Place = MinidoracatBuilder.Place
    for _, edge in ipairs(Place.EDGES) do
        local ke = k .. "," .. edge
        if inst.overlays[ke] and Place.wallAt(sq, edge) == obj then inst.overlays[ke] = nil end
    end
end

return Overlays
