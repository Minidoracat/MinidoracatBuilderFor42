-- 地上藍圖的虛影：每幀（OnPostRender）照 PlanMode 的藍圖畫半透明的圖塊與地框，不建世界物件。
-- 畫法同 Queue／Cursor：IsoSprite:RenderGhostTileColor（引擎每幀清掉，要每幀重畫）。
-- 一幀最多畫 DRAW_MAX 片：片照藍圖座標 10×10 分桶，從玩家（擺放時是滑鼠）那一桶一圈一圈往外取，近的先畫。
-- 樓層：規劃時正在規劃那層清楚、下面淡、上面不畫；在地上時畫玩家那層與下面；跟著游標時整張都畫。
-- 片的狀態照 PlanCheck.state（done 不畫、缺料黃、被擋或少了紅並加警告記號；在等旁邊先蓋好的照能蓋的畫）；選到的片青色。
-- 擺放時另畫整張的外框（片太多畫不完時也看得到範圍）
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Plan"

MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local PG = B.PlanGhost or {}
B.PlanGhost = PG
local Entry, Plan = B.Entry, B.Plan

local LOG = "[MinidoracatBuilderFor42] "
PG.DRAW_MAX = 512
local BUCKET, RINGS = 10, 6 -- 鏡頭四周 6 圈桶（約 65 格）就夠畫滿一個畫面
local MARK_MAX, ICON = 128, 18
local PLAN, SHORT, BAD, SEL, FLASH = { 0.75, 0.6, 1 }, { 1, 0.8, 0.3 }, { 0.95, 0.35, 0.35 }, { 0.4, 0.9, 1 }, { 1, 1, 0.4 }
local BAD_STATE = { blocked = true, missing = true, off = true, closed = true }
local FLASH_MS = 1000

-- plan、rev：分桶照的那張；buckets[key]＝片的陣列；parts[key]＝這種片的圖（false＝畫不出來）；
-- marks：這一幀的警告記號位置（世界座標），overlay 照它畫；box：整張佔的格子範圍（藍圖座標，rev 變了才重算）；
-- outline：這一幀擺放中的外框（世界座標 { x0, y0, x1, y1, z }，格子邊界），overlay 照它畫
local G = { buckets = {}, parts = {}, mx = {}, my = {}, mz = {}, mn = 0, ol = {} }
PG.lastDrawn = 0

local function bucketKey(bx, by) return (bx + 4096) * 8192 + (by + 4096) end

local function rebuild(plan)
    G.plan, G.rev, G.buckets, G.parts, G.box = plan, plan.rev, {}, {}, nil
    local buckets = G.buckets
    Plan.each(plan, function(p)
        local k = bucketKey(math.floor(p.x / BUCKET), math.floor(p.y / BUCKET))
        local b = buckets[k]
        if not b then
            b = {}
            buckets[k] = b
        end
        b[#b + 1] = p
    end)
end

-- 這種片（項目、朝向、車庫門寬度）佔的格子與圖：{ { dx, dy, dz, 偶數格的圖, 奇數格的圖 }, … }。
-- 柵欄這類一格一張交錯的（Entry.alternate）先把兩張都查好，每幀不再 resolve
local function computeParts(item, p)
    local id = item and item.id
    if type(id) ~= "string" then return nil end
    local cells
    if id:sub(1, 7) == "recipe:" then
        local R = B.Recipes
        local name, dx, dy
        if R and R.tile then name, dx, dy = R.tile(id, p.d) end
        local spr = name and Entry.sprite(name)
        if not spr then return nil end
        cells = { { dx or 0, dy or 0, 0, spr } }
    else
        local entry = Entry.resolve(id)
        local spr = entry and Entry.face(entry, p.d)
        if not spr then return nil end
        local set = p.w and entry.kind == "door" and Entry.doorSet(spr)
        cells = set and set.garage and Entry.groupCells(set, p.w) or Entry.cells(spr)
    end
    local out = {}
    for i, c in ipairs(cells) do
        out[i] = { c[1], c[2], c[3] or 0, Entry.alternate(c[4], 0, 0), Entry.alternate(c[4], 1, 0) }
    end
    return out
end

local function partsOf(plan, p)
    local k = (p.it * 8 + (p.d or 0)) * 128 + (p.w or 0)
    local v = G.parts[k]
    if v == nil then
        local ok, res = pcall(computeParts, plan.items[p.it], p)
        if not ok then print(LOG .. "plan ghost parts failed: " .. tostring(res)) end
        v = ok and res or false
        G.parts[k] = v
    end
    return v
end

-- 整張佔的格子範圍 { x0, y0, x1, y1 }（藍圖座標）：多格物件、車庫門照 partsOf 的格子算，畫不出圖的片算錨點
local ANCHOR = { { 0, 0 } }
local function extent(plan)
    local x0, y0, x1, y1
    Plan.each(plan, function(p)
        local parts = partsOf(plan, p) or ANCHOR
        for i = 1, #parts do
            local x, y = p.x + parts[i][1], p.y + parts[i][2]
            if not x0 then
                x0, y0, x1, y1 = x, y, x, y
            else
                x0, y0, x1, y1 = math.min(x0, x), math.min(y0, y), math.max(x1, x), math.max(y1, y)
            end
        end
    end)
    return x0 and { x0, y0, x1, y1 } or nil
end

local function mark(x, y, z)
    local n = G.mn
    if n >= MARK_MAX then return end
    n = n + 1
    G.mx[n], G.my[n], G.mz[n], G.mn = x, y, z, n
end

-- 畫一片，錨點在世界 (x, y, z)。畫不出圖的只畫地框加記號
local function drawPiece(plan, p, x, y, z, col, a, floorSpr, warn)
    local parts = partsOf(plan, p)
    local r, g, b = col[1], col[2], col[3]
    if not parts then
        floorSpr:RenderGhostTileColor(x, y, z, r, g, b, a)
        mark(x, y, z)
        return
    end
    -- 圖塊照原色畫（看得出材質）；狀態色（能蓋紫、缺料黃、被擋紅）只染地框。選到的、閃的整片染色
    local whole = col == SEL or col == FLASH
    local tr, tg, tb = 1, 1, 1
    if whole then tr, tg, tb = r, g, b end
    for i = 1, #parts do
        local c = parts[i]
        local cx, cy, cz = x + c[1], y + c[2], z + c[3]
        local spr = (cx + cy) % 2 == 0 and c[4] or c[5]
        if spr then spr:RenderGhostTileColor(cx, cy, cz, 0, 0, tr, tg, tb, a) end
        floorSpr:RenderGhostTileColor(cx, cy, cz, r, g, b, whole and a * 0.6 or a)
    end
    if warn then mark(x, y, z) end
end

-- 閃一下（藍圖面板「在哪」）：約一秒，不管樓層、隱藏與上限，先畫。一秒內連續叫的片一起閃（最多 FLASH_MAX 片），
-- 過了一秒再叫就換成新的一組
local FLASH_MAX = 256
function PG.flash(piece)
    local now = getTimestampMs()
    if not G.flashSet or now >= (G.flashUntil or 0) then G.flashSet, G.flashList = {}, {} end
    G.flashUntil = now + FLASH_MS
    if piece and not G.flashSet[piece] and #G.flashList < FLASH_MAX then
        G.flashSet[piece] = true
        G.flashList[#G.flashList + 1] = piece
    end
end

local overlay

function PG.draw()
    local PM = B.PlanMode
    local plan = PM and PM.plan()
    PG.lastDrawn = 0
    G.outline = nil
    if not plan then return end
    G.mn = 0
    local state = PM.state()
    local drag = PM.floating()
    local placing = state == "place"
    local hidden = PM.hidden() and not placing
    local ox, oy, oz
    if placing then
        if not (drag and drag.ox) then return end
        ox, oy, oz = drag.ox, drag.oy, drag.oz
    else
        ox, oy, oz = plan.ox, plan.oy, plan.oz
        if not ox then return end
    end
    if plan ~= G.plan or plan.rev ~= G.rev then rebuild(plan) end
    if placing then
        G.box = G.box or extent(plan)
        local b = G.box
        if b then
            local _, _, z0 = Plan.bounds(plan)
            local o = G.ol
            o[1], o[2], o[3], o[4], o[5] = b[1] + ox, b[2] + oy, b[3] + ox + 1, b[4] + oy + 1, oz + (z0 or 0)
            G.outline = o
        end
    end
    local pl = getSpecificPlayer(PM.playerNum or 0)
    if not pl then return end
    local floorSpr = ISBuildingObject.getFloorCursorSprite()
    local editing = state == "edit"
    local top = editing and PM.level() or math.floor(pl:getZ())
    local C = not placing and B.PlanCheck or nil
    local moving = drag and (drag.kind == "move" or drag.kind == "copy") and drag.dx ~= nil
    local drawn, max = 0, PG.DRAW_MAX

    local fl = G.flashList
    local left = fl and (G.flashUntil or 0) - getTimestampMs() or 0
    if left > 0 then
        -- 明暗照剩下的毫秒換，不拿整個時間戳取餘：引擎的 % 把商轉成 32 位元整數，時間戳除下來超過範圍，顏色會永遠不換
        local col = math.floor(left / 150) % 2 == 0 and FLASH or PLAN
        for i = 1, #fl do
            local fp = fl[i]
            drawPiece(plan, fp, fp.x + ox, fp.y + oy, fp.z + oz, col, 0.8, floorSpr, false)
        end
        drawn = #fl
    else
        G.flashSet, G.flashList = nil, nil
    end
    if hidden then
        PG.lastDrawn = drawn
        return
    end

    -- 搬、複製：跟著游標的那份先畫（PlanMode 轉過的預覽片，沒轉就是選到的片本身）
    if moving then
        local pv = drag.preview or PM.selected()
        local k = math.max(0, math.min(#pv, max - drawn))
        for i = 1, k do
            local p = pv[i]
            drawPiece(plan, p, p.x + ox + drag.dx, p.y + oy + drag.dy, p.z + oz, SEL, 0.6, floorSpr, false)
        end
        drawn = drawn + k
    end
    local cx, cy
    if placing then
        cx, cy = (drag.kx or ox) - ox, (drag.ky or oy) - oy
    else
        cx, cy = math.floor(pl:getX()) - ox, math.floor(pl:getY()) - oy
    end
    local bx0, by0 = math.floor(cx / BUCKET), math.floor(cy / BUCKET)
    local buckets = G.buckets
    for ring = 0, RINGS do
        for bx = bx0 - ring, bx0 + ring do
            for by = by0 - ring, by0 + ring do
                local b = (ring == 0 or bx == bx0 - ring or bx == bx0 + ring or by == by0 - ring or by == by0 + ring)
                    and buckets[bucketKey(bx, by)]
                if b then
                    for i = 1, #b do
                        if drawn >= max then break end
                        local p = b[i]
                        local wz = p.z + oz
                        if placing or wz <= top then
                            local st, code = nil, nil
                            if C then st, code = C.state(p) end
                            if st ~= "done" then
                                local col, a, warn = PLAN, 0.5, false
                                if editing and wz < top then a = 0.22 elseif not placing and wz < top then a = 0.35 end
                                if st == "short" then
                                    col = SHORT
                                elseif BAD_STATE[st] and code ~= "WAIT" then
                                    col, warn = BAD, true
                                end
                                if PM.isSelected(p) then
                                    col = SEL
                                    if moving then col, a = PLAN, drag.kind == "copy" and a or 0.12 end
                                end
                                drawPiece(plan, p, p.x + ox, p.y + oy, wz, col, a, floorSpr, warn)
                                drawn = drawn + 1
                            end
                        end
                    end
                end
            end
        end
        if drawn >= max then break end
    end
    PG.lastDrawn = drawn
    if (G.mn > 0 or (drag and drag.lines)) and not overlay then PG.overlay() end
end

-- ===== 警告記號與拖曳標籤（1×1 的 UI 元件，畫在世界上） =====
-- 元件要是 1×1、不收滑鼠：全螢幕的元件會讓 Cursor.mouseOverUI 一直當成滑鼠在介面上（引擎的 isMouseOver 只看範圍）

local function overRender(self)
    local PM = B.PlanMode
    if not (PM and PM.plan()) then return end
    local UI = MinidoracatUI and MinidoracatUI.v1
    if not G.colors and UI and UI.Theme then G.colors = UI.Theme.create({ variant = "dark" }).colors end
    local col = G.colors or {}
    local warn = col.warning or { r = 1, g = 0.6, b = 0.2, a = 1 }
    local pn = PM.playerNum or 0
    local font = UIFont.Small
    for i = 1, G.mn do
        local sx = isoToScreenX(pn, G.mx[i] + 0.5, G.my[i] + 0.5, G.mz[i]) - ICON / 2
        local sy = isoToScreenY(pn, G.mx[i] + 0.5, G.my[i] + 0.5, G.mz[i]) - ICON
        if not (UI and UI.Icons and UI.Icons.draw(self, "warning", sx, sy, ICON, warn, 1)) then
            self:drawText("!", sx + ICON / 2 - 2, sy, warn.r, warn.g, warn.b, 1, font)
        end
    end
    local ol = G.outline
    if ol then
        -- 四角換到螢幕，四條邊各畫兩次（y 差 1，2 px 粗）
        local x0, y0, x1, y1, z = ol[1], ol[2], ol[3], ol[4], ol[5]
        local ax, ay = isoToScreenX(pn, x0, y0, z), isoToScreenY(pn, x0, y0, z)
        local bx, by = isoToScreenX(pn, x1, y0, z), isoToScreenY(pn, x1, y0, z)
        local cx, cy = isoToScreenX(pn, x1, y1, z), isoToScreenY(pn, x1, y1, z)
        local dx, dy = isoToScreenX(pn, x0, y1, z), isoToScreenY(pn, x0, y1, z)
        local r, g, b = PLAN[1], PLAN[2], PLAN[3]
        for t = 0, 1 do
            self:drawLine2(ax, ay + t, bx, by + t, 0.9, r, g, b)
            self:drawLine2(bx, by + t, cx, cy + t, 0.9, r, g, b)
            self:drawLine2(cx, cy + t, dx, dy + t, 0.9, r, g, b)
            self:drawLine2(dx, dy + t, ax, ay + t, 0.9, r, g, b)
        end
    end
    local d = PM.floating()
    local lines = d and d.lines
    if not lines or not d.kx then return end
    local fh = getTextManager():getFontHeight(font)
    local x = isoToScreenX(pn, d.kx + 0.5, d.ky + 0.5, d.kz) + 24
    local y = isoToScreenY(pn, d.kx + 0.5, d.ky + 0.5, d.kz) + 8
    local w = 0
    for _, t in ipairs(lines) do w = math.max(w, getTextManager():MeasureStringX(font, t)) end
    local bg = col.panel or { r = 0.08, g = 0.08, b = 0.1 }
    self:drawRect(x, y, w + 12, #lines * fh + 8, 0.85, bg.r, bg.g, bg.b)
    local text, muted = col.text or { r = 1, g = 1, b = 1 }, col.textMuted or { r = 0.7, g = 0.7, b = 0.7 }
    for i, t in ipairs(lines) do
        local c = i == 1 and text or muted
        self:drawText(t, x + 6, y + 4 + (i - 1) * fh, c.r, c.g, c.b, 1, font)
    end
end

function PG.overlay()
    if overlay or not ISUIElement then return overlay end
    local cls = ISUIElement:derive("MinidoracatBuilderPlanMarks")
    cls.render = overRender
    local o = cls:new(0, 0, 1, 1)
    o:initialise()
    o.wantMouseEvents = false
    o:addToUIManager()
    o:backMost()
    overlay = o
    return o
end

-- 擺放中的外框（給檢查用；不在擺放時 nil）
function PG.outline() return G.outline end

if not PG.loaded then
    PG.loaded = true
    Events.OnPostRender.Add(function() MinidoracatBuilder.PlanGhost.draw() end)
end

return PG
