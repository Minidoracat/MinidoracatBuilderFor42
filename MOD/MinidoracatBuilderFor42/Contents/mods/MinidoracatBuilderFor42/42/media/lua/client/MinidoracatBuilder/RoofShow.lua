-- 建造時顯示同層屋頂（ModOptions「ShowRoofs」，預設關）：拿著本工具的游標（建造、一區、框選、規劃、配方、接線）時，
-- 玩家那一層不屬建築的屋頂片不再被淡到 0.05（淡出只認 WestRoofB/M/T，FBORenderCell.java:2196-2199）。
-- 游標的 beforeWorldRender（FBORenderCell.java:279 → 4747-4775，早於 RenderTiles :286 裡算透明度）把附近屋頂 sprite 的型別換成
-- 引擎沒用到的替身（IsoObjectType.java:17-18,32 只有定義），同一段世界繪製最後的 DoBuilding（:315 → IsoCell.java:2611
-- OnDoTileBuilding2）換回；換著的是 RenderTiles 與其後的 renderlast、砍樹記號（:286-314）。這個檔在 client 資料夾，比註冊原版
-- DoTileBuilding 的 server 資料夾先載入（LuaManager.java:1246-1250、GameLoadingState.java:149），所以換回早於原版補建游標格子
-- （ISBuildingObject.lua:110-112）與游標 render；比這個檔更早註冊的其他 MOD 的 OnDoTileBuilding2 回呼會讀到替身（只在開著選項的
-- 這台、那一幀）。OnPostRender、OnTickEvenPaused 是保底。
-- 不能整段游標期間都換著：那時第一次踩上某棟房屋屋頂，屋頂修補找不到屋頂、不補地板，卻把房間記成已補過並存檔
-- （IsoRoofFixer.java:86-104,297-300）。
MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local RS = B.RoofShow or {}
B.RoofShow = RS

local T = IsoObjectType
local SWAP = { [T.WestRoofB] = T.UNUSED9, [T.WestRoofM] = T.UNUSED10, [T.WestRoofT] = T.UNUSED24 }
-- 玩家同層半徑（格）、最多記幾種 sprite、重掃間隔（ms）
local R, MAX, EVERY = 20, 256, 500

-- per[pn]：該玩家看過的屋頂 sprite list[i] 與原型別 orig[i]（sprite 整個圖塊共用，換一次整片地圖同名的都換）、
-- 這次世界更新以來換過沒有 used、換著時在哪幾層 zs（收起後要重畫）
local per = {}
local cur -- 現在換著的那份 per[pn]
local block, hooked = false, false

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
                    local o = t and SWAP[t] and t -- 換著的只在一幀繪製裡、cur 先設好，掃描時不會有自己留下的替身
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
-- 每載入一格叫一次，所以第一次換型別才掛；之後不拿掉：算好的 chunk 何時交付主執行緒（暫停、大量載入）沒有上限
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
        s = { list = {}, orig = {}, seen = {}, n = 0, at = 0, used = false }
        per[pn] = s
    end
    local now = getTimestampMs()
    -- 站著不動也定時重掃：附近新蓋的屋頂、收起再拿游標、選項關了再開都會收進來
    if math.abs(now - s.at) >= EVERY then
        s.at = now
        scan(s, x, y, z)
    end
    s.used = true
    s.zs = s.zs or {}
    s.zs[z] = true
    if not hooked then
        hooked = true
        Events.LoadGridsquare.Add(loaded)
    end
    cur = s
    for i = 1, s.n do s.list[i]:setTileType(SWAP[s.orig[i]]) end
end

-- chunk 層重畫時屋簷以不透明烤進快取（FBORenderCell.java:1257-1290；透明度 <1 的才每幀重算，:2936），收起游標後沒人再標髒。
-- sprite 全圖共用，換著時視野內哪一塊重畫都可能烤到，所以標那位玩家 chunk map 裡的每一塊
local function flush(pn, s)
    local cm = getCell():getChunkMap(pn)
    if cm then
        local w = math.floor(cm:getWidthInTiles() / 8)
        for i = 0, w - 1 do
            for j = 0, w - 1 do
                local ch = cm:getChunk(i, j)
                if ch then
                    for z in pairs(s.zs) do ch:invalidateRenderChunkLevel(z, FBORenderChunk.DIRTY_REDRAW) end
                end
            end
        end
    end
    s.zs = nil
end

local function tick()
    RS.restore()
    block = false
    for pn, s in pairs(per) do
        if s.used then
            s.used = false
        elseif s.zs then
            flush(pn, s)
        end
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
