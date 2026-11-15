-- 藍圖面板：地上那張藍圖的「材料」與「平面圖」兩頁，加照圖蓋／暫停、搬、規劃、存檔、藍圖庫、收起。
-- 材料頁：還沒蓋的片要多少、身上有多少、缺多少（PlanCheck.materials），這裡蓋不了的片照原因分組（點一組讓那幾片閃一下），
-- 照圖蓋的狀態、上一輪的總結與停下的原因，點名的材料箱（可移除）。
-- 平面圖頁只看不改：一格一塊顏色（那格最差的狀態），圖例寫出每種狀態幾片（不只靠顏色）；點一格（手把移游標按 A）閃那格的片。
-- 重畫：PlanMode.changed、Runner.changed 標「要更新」，開著時另外每秒更新一次；字原地換，片組或材料箱的結構變了才重建。
-- 地上沒有藍圖時打開＝打開藍圖庫。別的藍圖模組一律晚綁定。
require "MinidoracatBuilder/Plan"
require "MinidoracatBuilder/Messages"
require "MinidoracatBuilder/PlanLibrary"

MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local P = B.PlanPanel or {}
B.PlanPanel = P
local Plan, Messages, L = B.Plan, B.Messages, B.PlanLibrary

local LOG = "[MinidoracatBuilderFor42] "
P.GRID_MAX = 4096 -- 平面圖每幀最多畫幾塊
P.FLASH_MAX = 256 -- 點一組最多閃幾片
P.SAMPLE, P.SLOW_MS = 32, 1 -- 每 32 幀算一次平均繪製時間，超過 1 毫秒改成 2×2 格一塊
P.START_CODES = { OFF = true, NO_PLAN = true, NOTHING = true, BUSY = true }
local PAD, GAP = 8, 6
local ACTIVE = { pick = true, build = true, fetch = true }

-- 平面圖的狀態等級：一格取最差的（數字大的）
local RANK = { done = 1, ok = 2, far = 3, short = 4, blocked = 5, missing = 5, off = 5, closed = 5 }
P.LEGEND = { "done", "ok", "pending", "short", "blocked" }
local RANK_NAME = { "done", "ok", "pending", "short", "blocked" }
local COLORS = {
    done = { r = 0.23, g = 0.29, b = 0.36 }, ok = { r = 0.18, g = 0.35, b = 0.18 }, pending = { r = 0.33, g = 0.33, b = 0.33 },
    short = { r = 0.48, g = 0.33, b = 0.11 }, blocked = { r = 0.48, g = 0.17, b = 0.15 },
}

-- ---------------------------------------------------------------- 給畫面的資料（harness 直接測）

local function planOf()
    local PM = B.PlanMode
    return PM and PM.plan and PM.plan() or nil
end

-- 照圖蓋能不能按：回 能, 不能時的原因句
function P.autoText()
    local Entry = B.Entry
    if Entry and Entry.settings and Entry.settings().AllowAutoBuild == false then return false, getText("IGUI_MBLD_Plan_AutoOff") end
    -- 規劃中 Runner 開始了下一幀也會自己暫停（PlanMode 與照圖蓋互斥）
    local PM = B.PlanMode
    if PM and PM.state and PM.state() == "edit" then return false, getText("IGUI_MBLD_Run_EDIT") end
    return true, nil
end

function P.startText(code)
    if P.START_CODES[code] then return getText("IGUI_MBLD_Plan_Start_" .. code) end
    return getText("IGUI_MBLD_Refuse_Other", tostring(code))
end

-- 照圖蓋／暫停／繼續。回 nil 或沒開始的原因句
function P.onGo(pn)
    local R = B.Runner
    if not (R and R.start) then return getText("IGUI_MBLD_Lib_NoPlanMode") end
    if ACTIVE[R.state()] then
        R.pause()
        return nil
    end
    local on, why = P.autoText()
    if not on then return why end
    local ok, code = R.start(getSpecificPlayer(pn))
    if ok then return nil end
    return P.startText(code)
end

local function itemLabel(key)
    local USE = B.Materials and B.Materials.USE
    if USE and key:sub(1, #USE) == USE then return Messages.useName(key:sub(#USE + 1)) end
    return getItemName(key) or key
end

-- 材料表的列：{ { 名稱, 需要, 有, 缺 }… }（缺的在前，再照名稱），工具 { { 名稱, 有沒有 }… }，配方 { { id, n, items } }，缺的合計
function P.materials(player)
    local PC = B.PlanCheck
    local m = PC and PC.materials and PC.materials(player) or { need = {}, have = {}, tools = {}, recipes = {} }
    local rows, short = {}, {}
    for key, n in pairs(m.need or {}) do
        local have = (m.have or {})[key] or 0
        local miss = math.max(0, n - have)
        if miss > 0 then short[key] = miss end
        rows[#rows + 1] = { itemLabel(key), n, have, miss }
    end
    L.sort(rows, function(a, b)
        if (a[4] > 0) ~= (b[4] > 0) then return a[4] > 0 end
        return a[1] < b[1]
    end)
    local tools, missTools = {}, {}
    for i, t in ipairs(m.tools or {}) do
        tools[i] = { Messages.tools({ t.tag }), t.has == true }
        if not t.has then missTools[#missTools + 1] = t.tag end
    end
    return { rows = rows, tools = tools, recipes = m.recipes or {}, cheat = m.cheat == true, short = short, missTools = missTools }
end

-- 這裡蓋不了的片照原因分組：{ { code, n, pieces＝{ 最多 FLASH_MAX 片 }, text }… }，片多的在前
function P.groups(mat)
    local plan, PC = planOf(), B.PlanCheck
    if not (plan and PC and PC.state) then return {} end
    local by, out = {}, {}
    Plan.each(plan, function(p)
        local s, detail = PC.state(p)
        if s == nil or s == "done" or s == "ok" or s == "far" then return end
        local code
        if s == "short" then
            code = detail == "NO_TOOL" and "NO_TOOL" or "NO_MATERIAL"
        elseif s == "blocked" then
            code = detail or "BLOCKED"
        else
            code = s -- missing／off／closed：項目在這裡的狀態，細節碼是 Entry.why 的
        end
        local g = by[code]
        if not g then
            g = { code = code, n = 0, pieces = {} }
            by[code] = g
            out[#out + 1] = g
        end
        g.n = g.n + 1
        if #g.pieces < P.FLASH_MAX then g.pieces[#g.pieces + 1] = p end
    end)
    local R = B.Runner
    for _, g in ipairs(out) do
        local c = g.code
        if c == "missing" or c == "off" or c == "closed" then
            g.text = getText("IGUI_MBLD_Plan_Grp_" .. c)
        elseif c == "NO_MATERIAL" or c == "NO_TOOL" then
            g.text = Messages.refusal(c, { need = mat and mat.short or {}, tools = mat and mat.missTools or {} })
        elseif R and R.codeText then
            g.text = R.codeText(c, nil)
        else
            g.text = Messages.refusal(c, nil)
        end
    end
    L.sort(out, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.code < b.code
    end)
    return out
end

function P.flash(pieces)
    local G = B.PlanGhost
    if not (G and G.flash) then return 0 end
    local n = math.min(#pieces, P.FLASH_MAX)
    for i = 1, n do G.flash(pieces[i]) end
    return n
end

-- 狀態行：進度、照圖蓋在做什麼、停下的原因
function P.statusLines()
    local R, out = B.Runner, {}
    local c = B.PlanCheck and B.PlanCheck.counts and B.PlanCheck.counts()
    local done, total = c and c.done or 0, c and c.n or 0
    local state = R and R.state and R.state() or "idle"
    local line = getText("IGUI_MBLD_Plan_Progress", tostring(done), tostring(total)) .. "  " .. getText("IGUI_MBLD_Plan_Run_" .. state)
    local pr = R and R.progress and R.progress()
    if ACTIVE[state] and pr and pr.name then line = line .. "  " .. getText("IGUI_MBLD_Plan_Now", pr.name) end
    out[1] = { line, "text" }
    local on, why = P.autoText()
    if not on then
        out[#out + 1] = { why, "warning" }
    elseif P.note then
        out[#out + 1] = { P.note, "warning" }
    elseif R and R.reason then
        local _, text = R.reason()
        if text then out[#out + 1] = { text, "textMuted" } end
    end
    if (state == "paused" or state == "done") and R and R.summary then
        local s = R.summary()
        if s and s.left > 0 then
            out[#out + 1] = { getText("IGUI_MBLD_Plan_Left", tostring(s.left), tostring(s.short.n), tostring(s.skill.n)), "textMuted" }
        end
    end
    return out
end

-- 平面圖一層：{ x0, y0, w, h, z, fine＝{ 平攤 x, y, 等級… }, coarse＝同上（2×2 一塊）, counts＝{ 名稱＝片數 } }
function P.grid(plan, z)
    local PC = B.PlanCheck
    local x0, y0, _, x1, y1 = Plan.bounds(plan)
    local g = { z = z, x0 = x0 or 0, y0 = y0 or 0, w = x0 and (x1 - x0 + 1) or 1, h = y0 and (y1 - y0 + 1) or 1,
        fine = {}, coarse = {}, counts = { done = 0, ok = 0, pending = 0, short = 0, blocked = 0 } }
    if not x0 then return g end
    local cell, half = {}, {}
    Plan.each(plan, function(p)
        if p.z ~= z then return end
        local s = PC and PC.state and PC.state(p) or nil
        local r = s and RANK[s] or 3
        local name = RANK_NAME[r]
        g.counts[name] = g.counts[name] + 1
        local fx, fy = p.x - g.x0, p.y - g.y0
        local k = fy * g.w + fx
        if (cell[k] or 0) < r then cell[k] = r end
        local hk = math.floor(fy / 2) * g.w + math.floor(fx / 2)
        if (half[hk] or 0) < r then half[hk] = r end
    end)
    local f, c = g.fine, g.coarse
    for k, r in pairs(cell) do
        f[#f + 1] = k % g.w
        f[#f + 1] = math.floor(k / g.w)
        f[#f + 1] = r
    end
    for k, r in pairs(half) do
        c[#c + 1] = (k % g.w) * 2
        c[#c + 1] = math.floor(k / g.w) * 2
        c[#c + 1] = r
    end
    return g
end

-- ---------------------------------------------------------------- 視窗

local Panel = {}
Panel.__index = Panel

local function newPane(parent, x, y, w, h)
    local pane = ISPanel:new(x, y, w, h)
    pane:initialise()
    pane.background = false
    parent:addChild(pane)
    return pane
end

-- 平面圖畫布：自繪，手把可聚焦（_focusKind＝button；方向鍵移游標，到邊才讓焦點離開；A＝閃那格）
local Map = {}

function Map.render(el)
    local self = el.owner
    local g = self.grid
    if not g then return end
    local t0 = getTimestampMs()
    local legendH = self.fh * 2
    local W, H = el.width, el.height - legendH
    local cs = math.max(1, math.floor(math.min(W / g.w, H / g.h)))
    local ox, oy = math.floor((W - cs * g.w) / 2), math.floor((H - cs * g.h) / 2)
    self.cs, self.ox, self.oy = cs, ox, oy
    local list, step = g.fine, 1
    if self.coarse then list, step = g.coarse, 2 end
    local n = math.min(#list / 3, P.GRID_MAX)
    local size = cs * step - (cs * step >= 4 and 1 or 0)
    for i = 0, n - 1 do
        local x, y, r = list[i * 3 + 1], list[i * 3 + 2], list[i * 3 + 3]
        local col = COLORS[RANK_NAME[r]]
        local px, py = ox + x * cs, oy + y * cs
        el:drawRect(px, py, size, size, 1, col.r, col.g, col.b)
        if r >= 4 and size >= 6 then -- 蓋不了／缺料的格加記號：不只靠顏色
            local m = math.floor(size / 3)
            el:drawRect(px + m, py + m, size - 2 * m, size - 2 * m, 1, 0.95, 0.85, 0.6)
        end
    end
    -- 玩家的位置
    local pl = getSpecificPlayer(self.pn)
    local PM = B.PlanMode
    local wx, wy, wz = nil, nil, nil
    if PM and PM.origin then wx, wy, wz = PM.origin() end
    if pl and wx and math.floor(pl:getZ()) - wz == g.z then
        local px = ox + (math.floor(pl:getX()) - wx - g.x0) * cs
        local py = oy + (math.floor(pl:getY()) - wy - g.y0) * cs
        if px >= 0 and py >= 0 and px < W and py < H then
            el:drawRectBorder(px - 1, py - 1, cs + 2, cs + 2, 1, 1, 1, 1)
        end
    end
    -- 圖例：色塊＋名稱＋片數
    local c, f = self.colors, self.font
    local lx, ly = 0, H + 4
    for _, name in ipairs(P.LEGEND) do
        local label = getText("IGUI_MBLD_Plan_Legend_" .. name, tostring(g.counts[name]))
        local lw = self.fh + 4 + getTextManager():MeasureStringX(f, label) + 12
        if lx > 0 and lx + lw > W then lx, ly = 0, ly + self.fh end
        local col = COLORS[name]
        el:drawRect(lx, ly + 2, self.fh - 4, self.fh - 4, 1, col.r, col.g, col.b)
        el:drawText(label, lx + self.fh, ly, c.text.r, c.text.g, c.text.b, 1, f)
        lx = lx + lw
    end
    -- 量繪製時間：太慢就改粗格（只往粗的方向切，換層、換藍圖也不切回來）
    self.drawMs = self.drawMs + (getTimestampMs() - t0)
    self.frames = self.frames + 1
    if self.frames >= P.SAMPLE then
        if self.drawMs / self.frames > P.SLOW_MS then self.coarse = true end
        self.drawMs, self.frames = 0, 0
    end
end

local function cellAt(self, x, y)
    local g, cs = self.grid, self.cs
    if not (g and cs) then return nil end
    local gx, gy = math.floor((x - self.ox) / cs), math.floor((y - self.oy) / cs)
    if gx < 0 or gy < 0 or gx >= g.w or gy >= g.h then return nil end
    return gx, gy
end

-- 一格的片（藍圖座標）閃一下；回幾片
function Panel:flashCell(gx, gy)
    local plan, g = planOf(), self.grid
    if not (plan and g) then return 0 end
    self.cx, self.cy = gx, gy
    return P.flash(Plan.at(plan, gx + g.x0, gy + g.y0, g.z))
end

function Map.onMouseDown(el, x, y)
    local self = el.owner
    local gx, gy = cellAt(self, x, y)
    if gx then self:flashCell(gx, gy) end
    return true
end

function Map.forceClick(el)
    local self = el.owner
    self:flashCell(self.cx or 0, self.cy or 0)
end

function Map.onFocusKey(el, key)
    local self, g = el.owner, el.owner.grid
    if not g then return false end
    local cx, cy = self.cx or 0, self.cy or 0
    if key == Keyboard.KEY_LEFT then cx = cx - 1
    elseif key == Keyboard.KEY_RIGHT then cx = cx + 1
    elseif key == Keyboard.KEY_UP then cy = cy - 1
    elseif key == Keyboard.KEY_DOWN then cy = cy + 1
    else return false end
    if cx < 0 or cy < 0 or cx >= g.w or cy >= g.h then return false end -- 到邊：讓焦點移到別的控制項
    self.cx, self.cy = cx, cy
    return true
end

function Map.focusRect(el)
    local self = el.owner
    local cs = self.cs or 1
    return self.ox + (self.cx or 0) * cs - 1, self.oy + (self.cy or 0) * cs - 1, cs + 2, cs + 2
end

function Map.focusLabel(el)
    local self = el.owner
    local plan, g = planOf(), self.grid
    if not (plan and g) then return nil end
    local n = #Plan.at(plan, (self.cx or 0) + g.x0, (self.cy or 0) + g.y0, g.z)
    return getText("IGUI_MBLD_Plan_Cell", tostring((self.cx or 0) + 1), tostring((self.cy or 0) + 1), tostring(n))
end

function Panel.new(UI, pn)
    local theme = UI.Theme.create({ variant = "dark" })
    local font = UIFont.Small
    local fh = getTextManager():getFontHeight(font)
    local s = fh / 16
    local self = setmetatable({ UI = UI, theme = theme, colors = theme.colors, font = font, fh = fh, pn = pn, page = "mat",
        drawMs = 0, frames = 0, coarse = false, at = 0, gridAt = 0, dirty = true }, Panel)
    P.v = self
    local items = { { id = "mat", label = getText("IGUI_MBLD_Plan_Tab_mat") }, { id = "map", label = getText("IGUI_MBLD_Plan_Tab_map") } }
    -- 視窗裡第一個 Tabs：手把 LB／RB 切它
    self.tabs = UI.Tabs.new({ x = PAD, y = 0, items = items, selected = "mat", theme = theme, target = self,
        onSelect = function(t, id) t:show(id) end })
    local sx, sy = getPlayerScreenLeft(pn), getPlayerScreenTop(pn)
    local sw, sh = getPlayerScreenWidth(pn), getPlayerScreenHeight(pn)
    local w, h = math.min(sw - 20, math.floor(520 * s)), math.min(sh - 40, math.floor(600 * s))
    local plan = planOf()
    local win = UI.Window.new({ x = sx + math.floor((sw - w) / 2), y = sy + math.floor((sh - h) / 2), width = w, height = h,
        title = getText("IGUI_MBLD_Plan_Title", plan and plan.name or ""), icon = "folder", theme = theme, opaque = true,
        onClose = function(wnd) UI.Dropdown.close(wnd) end })
    win.onEscape = function()
        win:close()
        return true
    end
    self.win = win
    local innerW = w - 2 * PAD
    local top = win:contentTop() + GAP
    self.tabs:setY(top)
    win:addChild(self.tabs)
    -- 按鈕列（最下面）
    local function button(key, style, fn)
        local b = UI.Button.new({ x = 0, y = 0, title = getText(key), style = style, theme = theme, target = self, onClick = fn })
        win:addChild(b)
        return b
    end
    self.goBtn = button("IGUI_MBLD_Plan_Go", "primary", function(t) t:act("go") end)
    local moveBtn = button("IGUI_MBLD_Plan_Move", nil, function(t) t:act("move") end)
    local editBtn = button("IGUI_MBLD_Plan_Edit", nil, function(t) t:act("edit") end)
    self.saveBtn = button("IGUI_MBLD_Plan_Save", nil, function(t) t:act("save") end)
    local btns = { self.goBtn, moveBtn, editBtn, self.saveBtn,
        button("IGUI_MBLD_Lib_Title", nil, function(t) t:act("library") end),
        button("IGUI_MBLD_Plan_Clear", "danger", function(t) t:act("clear") end) }
    -- 「暫停」「繼續」比「照圖蓋」長時按鈕寬度照最長的那個，換字不擠
    for _, k in ipairs({ "IGUI_MBLD_Plan_Pause", "IGUI_MBLD_Plan_Resume" }) do
        local bw = getTextManager():MeasureStringX(font, getText(k)) + 24
        if bw > self.goBtn.width then self.goBtn:setWidth(bw) end
    end
    local by = h - PAD - L.flowHeight(btns, innerW)
    L.flow(btns, PAD, by, innerW)
    -- 狀態（三行）
    self.status = L.textPanel(win, PAD, by - GAP - fh * 3, innerW, theme, font)
    local pageY = top + self.tabs.height + GAP
    local pageH = math.max(fh * 4, self.status.y - GAP - pageY)
    -- 材料頁
    self.matBox = UI.ScrollPanel.new({ x = PAD, y = pageY, width = innerW, height = pageH, theme = theme })
    win:addChild(self.matBox)
    -- 平面圖頁：上一層／下一層＋畫布
    self.mapPane = newPane(win, PAD, pageY, innerW, pageH)
    self.upBtn = UI.Button.new({ x = 0, y = 0, title = getText("IGUI_MBLD_Plan_Up"), theme = theme, target = self,
        onClick = function(t) t:level(1) end })
    self.downBtn = UI.Button.new({ x = 0, y = 0, title = getText("IGUI_MBLD_Plan_Down"), theme = theme, target = self,
        onClick = function(t) t:level(-1) end })
    self.mapPane:addChild(self.downBtn)
    self.mapPane:addChild(self.upBtn)
    self.upBtn:setX(self.downBtn.width + GAP)
    self.levelText = L.textPanel(self.mapPane, self.upBtn.x + self.upBtn.width + GAP * 2, 4, innerW / 2, theme, font)
    local cy = self.downBtn.height + GAP
    local canvas = newPane(self.mapPane, 0, cy, innerW, pageH - cy)
    canvas.owner = self
    canvas.render, canvas.onMouseDown = Map.render, Map.onMouseDown
    canvas.forceClick, canvas.onFocusKey, canvas.focusRect, canvas.focusLabel = Map.forceClick, Map.onFocusKey, Map.focusRect,
        Map.focusLabel
    canvas._focusKind = "button"
    self.canvas = canvas
    -- 開著時的更新（不開不跑）
    local tick = newPane(win, 0, 0, 1, 1)
    tick.prerender = function() self:pump() end
    win:addToUIManager()
    self:show("mat")
    return self
end

function Panel:show(id)
    self.page = id
    self.tabs:setSelected(id, true)
    self.matBox:setVisible(id == "mat")
    self.mapPane:setVisible(id == "map")
    self.dirty, self.gridAt = true, 0
end

function Panel:level(d)
    local plan = planOf()
    if not plan then return end
    local _, _, z0, _, _, z1 = Plan.bounds(plan)
    local z = (self.z or 0) + d
    if z0 and z >= z0 and z <= z1 then
        self.z = z
        self.gridAt = 0
    end
end

function Panel:pump()
    local t = getTimestampMs()
    if self.dirty or t - self.at >= 1000 then
        self.at, self.dirty = t, false
        self:refresh()
    end
    if self.page == "map" and t - self.gridAt >= 500 then
        self.gridAt = t
        self:refreshMap()
    end
end

function Panel:refreshMap()
    local plan = planOf()
    if not plan then return end
    local _, _, z0, _, _, z1 = Plan.bounds(plan)
    z0, z1 = z0 or 0, z1 or 0
    if self.z == nil or self.z < z0 or self.z > z1 then
        local PM = B.PlanMode
        -- PlanMode.level 是世界 z，片的 z 相對原點：減掉原點那層（擺放中沒有原點就從最低層看）
        local lv = PM and PM.level and PM.level()
        local oz = nil
        if PM and PM.origin then oz = select(3, PM.origin()) end
        if lv and oz then lv = lv - oz else lv = nil end
        self.z = (lv and lv >= z0 and lv <= z1) and lv or z0
    end
    self.grid = P.grid(plan, self.z)
    self.upBtn:setEnabled(self.z < z1)
    self.downBtn:setEnabled(self.z > z0)
    L.setLines(self.levelText, { { getText("IGUI_MBLD_Plan_Level", tostring(self.z - z0 + 1), tostring(z1 - z0 + 1)), "text" } })
end

-- 材料頁的結構簽名：片組與材料箱、材料的種數變了才重建控制項，其他只換字
local function signature(mat, groups, boxes)
    local parts = { #mat.rows, #mat.tools, #mat.recipes, #boxes }
    for _, g in ipairs(groups) do parts[#parts + 1] = g.code end
    return table.concat(parts, ",")
end

function Panel:refresh()
    local plan = planOf()
    if not plan then return P.close() end
    local on = P.autoText()
    local R = B.Runner
    local state = R and R.state and R.state() or "idle"
    self.goBtn:setTitle(getText(ACTIVE[state] and "IGUI_MBLD_Plan_Pause" or state == "paused" and "IGUI_MBLD_Plan_Resume"
        or "IGUI_MBLD_Plan_Go"))
    self.goBtn:setEnabled(on)
    local PM = B.PlanMode
    self.saveBtn:setEnabled(not (PM and PM.state and PM.state() == "place")) -- 跟著游標時位置還沒定，PlanMode.save 回 PLACING
    self.win:setTitle(getText("IGUI_MBLD_Plan_Title", plan.name or ""))
    local lines = P.statusLines()
    while #lines > 3 do table.remove(lines) end
    L.setLines(self.status, lines)
    if self.page ~= "mat" then return end
    local mat = P.materials(getSpecificPlayer(self.pn))
    local groups = P.groups(mat)
    local boxes = R and R.boxes and R.boxes() or {}
    local sig = signature(mat, groups, boxes)
    if sig ~= self.sig then
        self.sig = sig
        self:buildMat(mat, groups, boxes)
    end
    self:fillMat(mat, groups, boxes)
end

-- 材料表：名稱靠左（截字），需要／有／缺靠右
local function drawTable(el)
    local c, f, fh = el.colors, el.font, el.fh
    local UI = MinidoracatUI and MinidoracatUI.v1
    for i, r in ipairs(el.rows) do
        local y = (i - 1) * fh
        local col = c[r.tok or "text"] or c.text
        local name = UI and UI.Text and UI.Text.fit and UI.Text.fit(r[1], el.nameW, f) or r[1]
        el:drawText(name, 0, y, col.r, col.g, col.b, 1, f)
        for k = 2, 4 do
            if r[k] then el:drawTextRight(tostring(r[k]), el.colX[k], y, col.r, col.g, col.b, 1, f) end
        end
    end
end

function Panel:buildMat(mat, groups, boxes)
    local UI, theme, box = self.UI, self.theme, self.matBox
    box:clearChildren()
    local cw = box:contentWidth()
    self.matRows = {}
    local function add(el) self.matRows[#self.matRows + 1] = el end
    self.matHead = L.textPanel(box, 0, 0, cw, theme, self.font)
    add(self.matHead)
    local tbl = newPane(box, 0, 0, cw, 1)
    local tm = getTextManager()
    local numW = tm:MeasureStringX(self.font, "00000") + 12
    for _, k in ipairs({ "IGUI_MBLD_Plan_ColNeed", "IGUI_MBLD_Plan_ColHave", "IGUI_MBLD_Plan_ColShort" }) do
        numW = math.max(numW, tm:MeasureStringX(self.font, getText(k)) + 12)
    end
    tbl.colors, tbl.font, tbl.fh, tbl.rows = self.colors, self.font, self.fh, {}
    tbl.colX = { 0, cw - 4 - numW * 2, cw - 4 - numW, cw - 4 }
    tbl.nameW = cw - 8 - numW * 3
    tbl.render = drawTable
    self.matTable = tbl
    add(tbl)
    self.matTail = L.textPanel(box, 0, 0, cw, theme, self.font)
    add(self.matTail)
    self.groupRows = {}
    for i, g in ipairs(groups) do
        local t = L.textPanel(box, 0, 0, cw, theme, self.font)
        local code = g.code
        local b = UI.Button.new({ x = 0, y = 0, title = getText("IGUI_MBLD_Plan_Where"), theme = theme, target = self,
            onClick = function(t2) t2:flashGroup(code) end })
        box:addChild(b)
        self.groupRows[i] = t
        add(t)
        add(b)
    end
    self.boxHead = L.textPanel(box, 0, 0, cw, theme, self.font)
    add(self.boxHead)
    self.boxRows = {}
    for i = 1, #boxes do
        local t = L.textPanel(box, 0, 0, cw, theme, self.font)
        local b = UI.Button.new({ x = 0, y = 0, title = getText("IGUI_MBLD_Plan_BoxRemove"), style = "danger", theme = theme,
            target = self, onClick = function(t2) t2:removeBox(i) end })
        box:addChild(b)
        self.boxRows[i] = t
        add(t)
        add(b)
    end
end

function Panel:fillMat(mat, groups, boxes)
    local head = {}
    if mat.cheat then head[#head + 1] = { getText("IGUI_MBLD_Plan_Cheat"), "textMuted" } end
    if #mat.rows == 0 and #mat.recipes == 0 then head[#head + 1] = { getText("IGUI_MBLD_Plan_NoMaterials"), "textMuted" } end
    L.setLines(self.matHead, head)
    local rows = {}
    if #mat.rows > 0 then
        rows[1] = { getText("IGUI_MBLD_Plan_ColItem"), getText("IGUI_MBLD_Plan_ColNeed"), getText("IGUI_MBLD_Plan_ColHave"),
            getText("IGUI_MBLD_Plan_ColShort"), tok = "textMuted" }
    end
    for _, r in ipairs(mat.rows) do
        rows[#rows + 1] = { r[1], r[2], r[3], r[4] > 0 and r[4] or "-", tok = r[4] > 0 and "warning" or "text" }
    end
    for _, t in ipairs(mat.tools) do
        rows[#rows + 1] = { getText("IGUI_MBLD_Plan_Tool", t[1]), nil, nil, t[2] and "-" or getText("IGUI_MBLD_Plan_ToolMissing"),
            tok = t[2] and "text" or "warning" }
    end
    for _, rc in ipairs(mat.recipes) do
        rows[#rows + 1] = { getText("IGUI_MBLD_Plan_Recipe", L.itemName(rc.id), tostring(rc.n)), tok = "textMuted" }
        for _, it in ipairs(rc.items or {}) do
            local miss = math.max(0, (it.need or 0) - (it.have or 0))
            rows[#rows + 1] = { "  " .. tostring(it.name), it.need, it.have, miss > 0 and miss or "-",
                tok = it.ok == false and "warning" or "text" }
        end
    end
    self.matTable.rows = rows
    self.matTable:setHeight(math.max(1, #rows * self.fh))
    L.setLines(self.matTail, { { #groups > 0 and getText("IGUI_MBLD_Plan_Groups") or getText("IGUI_MBLD_Plan_NoGroups"),
        #groups > 0 and "text" or "textMuted" } })
    self.groups = groups
    for i, g in ipairs(groups) do
        if self.groupRows[i] then
            L.setLines(self.groupRows[i], { { getText("IGUI_MBLD_Plan_Group", tostring(g.n), g.text), "warning" } })
        end
    end
    L.setLines(self.boxHead, { { #boxes > 0 and getText("IGUI_MBLD_Plan_Boxes", tostring(#boxes)) or getText("IGUI_MBLD_Plan_NoBoxes"),
        "textMuted" } })
    for i, b in ipairs(boxes) do
        if self.boxRows[i] then
            L.setLines(self.boxRows[i], { { getText("IGUI_MBLD_Plan_Box", tostring(i), tostring(b.x), tostring(b.y), tostring(b.z)), "text" } })
        end
    end
    -- 由上往下排（字的行數會變）
    local y = 0
    for _, el in ipairs(self.matRows) do
        el:setY(y)
        y = y + el.height + (el.lines == nil and el.rows == nil and GAP or 2)
    end
end

function Panel:flashGroup(code)
    for _, g in ipairs(self.groups or {}) do
        if g.code == code then return P.flash(g.pieces) end
    end
    return 0
end

function Panel:removeBox(i)
    local R = B.Runner
    if R and R.removeBox then R.removeBox(i) end
    self.dirty = true
end

function Panel:act(what)
    local PM, pn = B.PlanMode, self.pn
    if what == "go" then
        P.note = P.onGo(pn)
        self.dirty = true
        return
    end
    if what == "library" then
        P.close()
        return L.open(pn)
    end
    if not PM then return L.tell(getText("IGUI_MBLD_Lib_NoPlanMode")) end
    if what == "move" and PM.pickUp then
        if PM.pickUp(pn) then P.close() end -- 拿不起來（存不了檔）時面板留著
    elseif what == "edit" and PM.toggle then
        -- 規劃中再按＝完成（stopEdit 先存檔）：存不了時 PlanMode 留在規劃，面板也留著
        if PM.toggle(pn) ~= false then P.close() end
    elseif what == "save" and PM.save then
        -- 失敗的通知 PlanMode 自己跳過（PlanSaveFail），這裡只說成功
        if PM.save() then L.tell(getText("IGUI_MBLD_Plan_Saved")) end
    elseif what == "clear" and PM.clear then
        local plan = planOf()
        L.confirm(pn, { title = getText("IGUI_MBLD_Plan_ClearTitle", plan and plan.name or ""), text = getText("IGUI_MBLD_Plan_ClearText"),
            ok = getText("IGUI_MBLD_Plan_Clear"), danger = true,
            onYes = function()
                if PM.clear() then P.close() end -- 存不了時地上那張照留，面板也留著
            end })
    end
end

-- ---------------------------------------------------------------- 開關

local function onChanged()
    local v = P.v
    if v then v.dirty, v.gridAt = true, 0 end
end

local function hook()
    if P.hooked then return end
    local PM, R = B.PlanMode, B.Runner
    if PM and PM.changed then PM.changed(onChanged) end
    if R and R.changed then R.changed(onChanged) end
    P.hooked = (PM and PM.changed) ~= nil
end

-- 地上沒有藍圖時改開藍圖庫
function P.open(...)
    local pn = select("#", ...) > 0 and (...) or 0
    if not planOf() then return L.open(pn) end
    local UI = L.ui()
    if not UI then
        L.tell(getText("IGUI_MBLD_NeedFramework"))
        return false
    end
    hook()
    local v = P.v
    if v and (v.UI ~= UI or v.pn ~= pn) then
        P.discard()
        v = nil
    end
    if not v then
        local ok, err = pcall(Panel.new, UI, pn)
        if not ok then
            print(LOG .. "plan panel build failed: " .. tostring(err))
            P.discard()
            L.tell(getText("IGUI_MBLD_Lib_BuildFailed"))
            return false
        end
        v = P.v
    end
    P.note = nil
    v.sig, v.dirty, v.gridAt, v.z = nil, true, 0, nil
    v.win:setVisible(true)
    v.win:bringToTop()
    v:refresh()
    return true
end

function P.discard()
    local v = P.v
    P.v = nil
    if v and v.win then
        pcall(function()
            v.win:setVisible(false)
            v.win:removeFromUIManager()
        end)
    end
end

function P.close()
    local v = P.v
    if v and v.win:getIsVisible() then v.win:close() end
end

function P.visible()
    return P.v ~= nil and P.v.win:getIsVisible()
end

return P
