-- 建造時顯示同層屋頂（ModOptions「ShowRoofs」，預設關）：拿著本工具的游標（建造、一區、框選、規劃、配方）時，
-- 玩家那一層不屬建築的屋頂片不再被淡到 0.05（淡出只認 WestRoofB/M/T，FBORenderCell.java:2196-2199）。
-- 游標的 beforeWorldRender（FBORenderCell.java:279 → 4747-4775，早於 RenderTiles :286 裡算透明度）把附近屋頂 sprite 的型別換成
-- 引擎沒用到的替身（IsoObjectType.java:17-18,32 只有定義），同一段世界繪製裡的 DoBuilding（:315 → IsoCell.java:2611 OnDoTileBuilding2）換回：
-- 這個檔在 client 資料夾，比註冊原版 DoTileBuilding 的 server 資料夾先載入（LuaManager.java:1246-1250、GameLoadingState.java:149），
-- 所以換回早於原版補建游標格子（ISBuildingObject.lua:110-112）與任何游標 render。OnPostRender、OnTickEvenPaused 是保底。
-- 不能整段游標期間都換著：那時第一次踩上某棟房屋屋頂，屋頂修補找不到屋頂、不補地板，卻把房間記成已補過並存檔
-- （IsoRoofFixer.java:86-104,297-300）。
MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local RS = B.RoofShow or {}
B.RoofShow = RS

local T = IsoObjectType
local SWAP = { [T.WestRoofB] = T.UNUSED9, [T.WestRoofM] = T.UNUSED10, [T.WestRoofT] = T.UNUSED24 }
local BACK = { [T.UNUSED9] = T.WestRoofB, [T.UNUSED10] = T.WestRoofM, [T.UNUSED24] = T.WestRoofT }
-- 玩家同層半徑（格）、最多記幾種 sprite、重掃間隔（ms）、收起後重畫幾圈 chunk（蓋住 R）、最後一次換型別後還檢查載入格子多久（ms）
local R, MAX, EVERY, D, HOT = 20, 256, 500, 3, 10000

-- per[pn]：該玩家看過的屋頂 sprite list[i] 與原型別 orig[i]（sprite 整個圖塊共用，換一次整片地圖同名的都換）
local per = {}
local cur -- 現在換著的那份 per[pn]
local block, used, hot, last = false, false, false, 0
local dirty = {} -- 換著時畫過的 chunk 層

function RS.restore()
    local s = cur
    if not s then return end
    for i = 1, s.n do s.list[i]:setTileType(s.orig[i]) end
    cur = nil
end

local function on()
    local o = B.Window and B.Window.options
    local t = o and o:getOption("ShowRoofs")
    return t ~= nil and t:getValue() == true
end

local function scan(s, x, y, z)
    if s.n >= MAX then s.list, s.orig, s.seen, s.n = {}, {}, {}, 0 end
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
                    if o and not s.seen[spr] and s.n < MAX then
                        s.n = s.n + 1
                        s.list[s.n], s.orig[s.n], s.seen[spr] = spr, o, true
                    end
                end
            end
        end
    end
end

-- 載入 chunk 時串流執行緒算格子型別（IsoChunk.java:2398-2467，WorldStreamer.java:480），可能正好在換著的那段；
-- 主執行緒在尋路收進這個 chunk 前發 LoadGridsquare（IsoChunk.java:3834 早於 :3864），這時已換回，重算一次。
-- 每載入一格叫一次，只在最後一次換型別後 HOT 毫秒內掛著
local function loaded(sq)
    if sq:has(T.UNUSED9) or sq:has(T.UNUSED10) or sq:has(T.UNUSED24) then sq:RecalcProperties() end
end

function RS.before(pn)
    RS.restore() -- 上一段繪製沒走到 DoBuilding（游標指在地圖外）或分割畫面的另一位玩家
    if block or not on() then return end
    local p = getSpecificPlayer(pn)
    if not p then return end
    local x, y, z = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
    local s = per[pn]
    if not s then
        s = { list = {}, orig = {}, seen = {}, n = 0, at = 0 }
        per[pn] = s
    end
    local now = getTimestampMs()
    -- 站著不動也定時重掃：附近新蓋的屋頂、收起再拿游標、選項關了再開都會收進來
    if math.abs(now - s.at) >= EVERY then
        s.at = now
        scan(s, x, y, z)
    end
    local cx, cy = math.floor(x / 8), math.floor(y / 8)
    if cx ~= s.cx or cy ~= s.cy or z ~= s.cz then
        s.cx, s.cy, s.cz = cx, cy, z
        for i = cx - D, cx + D do
            for j = cy - D, cy + D do dirty[i .. "," .. j .. "," .. z] = { i, j, z } end
        end
    end
    if not hot then Events.LoadGridsquare.Add(loaded) end
    used, hot, last = true, true, now
    cur = s
    for i = 1, s.n do s.list[i]:setTileType(SWAP[s.orig[i]]) end
end

-- chunk 層重畫時屋簷以不透明烤進快取（FBORenderCell.java:1257-1290；透明度 <1 的才每幀重算，:2936），收起游標後沒人再標髒
local function flush()
    local cell = getCell()
    for _, c in pairs(dirty) do
        local ch = cell:getChunk(c[1], c[2])
        if ch then ch:invalidateRenderChunkLevel(c[3], FBORenderChunk.DIRTY_REDRAW) end
    end
    dirty = {}
    for _, s in pairs(per) do s.cx = nil end
end

local function tick()
    RS.restore()
    block = false
    if used then
        used = false
        return
    end
    if not hot then return end
    if not table.isempty(dirty) then flush() end
    if math.abs(getTimestampMs() - last) >= HOT then
        hot = false
        Events.LoadGridsquare.Remove(loaded)
    end
end

-- 存檔畫縮圖也呼叫游標的 beforeWorldRender，卻不發 OnPostRender（GameWindow.java:1034-1037）：存檔起到下一次世界更新前不換
local function saving()
    RS.restore()
    block = true
end

-- 建造游標類別在第一次用到時才從這張表複製（Cursor.lua 的 base），所以掛在這裡就好；規劃與配方的游標各自掛
local C = B.Cursor or {}
B.Cursor = C
function C.beforeWorldRender(self) RS.before(self.player) end

Events.OnDoTileBuilding2.Add(RS.restore)
Events.OnDoTileBuilding3.Add(RS.restore)
Events.OnPostRender.Add(RS.restore)
Events.OnTickEvenPaused.Add(tick)
Events.OnSave.Add(saving)

return RS
