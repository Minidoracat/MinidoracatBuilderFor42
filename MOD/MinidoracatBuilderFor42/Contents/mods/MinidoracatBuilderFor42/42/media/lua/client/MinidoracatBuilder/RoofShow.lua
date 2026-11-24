-- 建造時顯示同層屋頂（ModOptions「ShowRoofs」，預設關）：拿著本工具的游標（建造、一區、框選、規劃、配方）時，
-- 玩家那一層不屬建築的屋頂片不再被淡到 0.05（淡出只認 WestRoofB/M/T，FBORenderCell.java:2196-2199）。
-- 游標的 beforeWorldRender（FBORenderCell.java:279 → 4747-4775，早於 RenderTiles :320 裡算透明度的 :1290）把附近屋頂 sprite 的型別換成
-- 引擎沒用到的替身（IsoObjectType.java:17-18,32 只有定義），世界畫完的 OnPostRender（IngameState.java:1197-1200）換回；
-- OnTickEvenPaused 在世界更新之前（IngameState.java:1346 早於 :1535）再換回一次當保底。遊戲邏輯都在這一段外面，讀到原型別。
-- 不能整段游標期間都換著：那時第一次踩上某棟房屋屋頂，屋頂修補找不到屋頂、不補地板，卻把房間記成已補過並存檔
-- （IsoRoofFixer.java:86-104,297-300）。游標自己的 render 在這一段裡，所以 Rules 的 TYPE 把替身也記成屋頂。
MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local RS = B.RoofShow or {}
B.RoofShow = RS

local T = IsoObjectType
local SWAP = { [T.WestRoofB] = T.UNUSED9, [T.WestRoofM] = T.UNUSED10, [T.WestRoofT] = T.UNUSED24 }
local BACK = { [T.UNUSED9] = T.WestRoofB, [T.UNUSED10] = T.WestRoofM, [T.UNUSED24] = T.WestRoofT }
local R, MAX, EVERY = 20, 256, 500 -- 玩家同層半徑（格）、最多記幾種 sprite、重掃間隔（ms）

-- list[i]／orig[i]：看過的屋頂 sprite 與原型別（sprite 是整個圖塊共用的，換一次整片地圖同名的都換）
local list, orig, seen, n = {}, {}, {}, 0
local swapped, at, sx, sy, sz = false, 0, nil, nil, nil

function RS.restore()
    if not swapped then return end
    swapped = false
    for i = 1, n do list[i]:setTileType(orig[i]) end
end

local function on()
    local o = B.Window and B.Window.options
    local t = o and o:getOption("ShowRoofs")
    return t ~= nil and t:getValue() == true
end

local function scan(x, y, z)
    if n >= MAX then list, orig, seen, n = {}, {}, {}, 0 end
    local cell = getCell()
    for i = x - R, x + R do
        for j = y - R, y + R do
            local sq = cell:getGridSquare(i, j, z)
            if sq and sq:HasSlopedRoof() then
                local objs = sq:getObjects()
                for k = 0, objs:size() - 1 do
                    local spr = objs:get(k):getSprite()
                    local t = spr and spr:getType()
                    local o = t and (SWAP[t] and t or BACK[t]) -- 替身：上次沒換回（出錯中斷、重載 Lua）的，記原型別
                    if o and not seen[spr] and n < MAX then
                        n = n + 1
                        list[n], orig[n], seen[spr] = spr, o, true
                    end
                end
            end
        end
    end
end

function RS.before(pn)
    if swapped or not on() then return end
    local p = getSpecificPlayer(pn)
    if not p then return end
    local x, y, z = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
    local now = getTimestampMs()
    if (x ~= sx or y ~= sy or z ~= sz) and math.abs(now - at) >= EVERY then
        at, sx, sy, sz = now, x, y, z
        scan(x, y, z)
    end
    swapped = true
    for i = 1, n do list[i]:setTileType(SWAP[orig[i]]) end
end

-- 建造游標類別在第一次用到時才從這張表複製（Cursor.lua 的 base），所以掛在這裡就好；規劃與配方的游標各自掛
local C = B.Cursor or {}
B.Cursor = C
function C.beforeWorldRender(self) RS.before(self.player) end

Events.OnPostRender.Add(RS.restore)
Events.OnTickEvenPaused.Add(RS.restore)

return RS
