-- 水面的畫面（使用者 2026-11-13 選 pond=do）。伺服器與單機的 addFloor 最後會清那一格的水面幾何（IsoGridSquare.java:4793）；
-- 多人的客戶端收到新地板（AddItemToMap）只重算屬性、不清水面幾何（AddItemToMapPacket.java:60-103），水面地板的圖又交給
-- 水面著色器畫（IsoWaterGeometry.java:136-153），舊的「沒有水」幾何留著時那格畫成黑色菱形；拆回乾地時，周圍格子的岸邊
-- 混合幾何也還照著原本的水畫。原型（temp/pond-proto-1113）量到：收到新地板時清那一格與周圍 8 格的幾何，3 秒內畫對、岸邊自然；
-- 只清自己那一格沒用。所以一樓每加一片地板（水面或乾地）就清 9 格，下一次畫時引擎照現在的地形重建（IsoGridSquare.getWater）。
-- 清完由引擎在事件之後失效那一塊的繪圖快取（AddItemToMapPacket.java:94-99 先觸發事件、再 invalidateRenderChunkLevel）。
-- 效能：這個事件每加一個物件都跑。不是地板的物件只花 2 次引擎呼叫（取屬性、查 solidfloor）就返回；地板再 2 次（取格子、
-- 查樓層），一樓的地板再 2 次座標、9 次取格子、最多 9 次清幾何。不掛每 tick、不掛讀格子，不記任何清單。
-- 單機引擎不會對 addFloor 觸發這個事件：Place.dig／Place.fill 與蓋一般地板（placeFloor）放好後直接呼叫 Pond.onObjectAdded
-- （同一個 Lua）。
MinidoracatBuilder = MinidoracatBuilder or {}
local Pond = MinidoracatBuilder.Pond or {}
MinidoracatBuilder.Pond = Pond

local SOLIDFLOOR = IsoFlagType.solidfloor

function Pond.onObjectAdded(obj)
    local p = obj:getProperties()
    if not (p and p:has(SOLIDFLOOR)) then return end
    local sq = obj:getSquare()
    if not sq or sq:getZ() ~= 0 then return end -- 水面只在一樓
    local cell, x, y = getCell(), sq:getX(), sq:getY()
    for dy = -1, 1 do
        for dx = -1, 1 do
            local s = cell:getGridSquare(x + dx, y + dy, 0)
            if s then s:clearWater() end
        end
    end
end

Events.OnObjectAdded.Add(function(obj) MinidoracatBuilder.Pond.onObjectAdded(obj) end)

return Pond
