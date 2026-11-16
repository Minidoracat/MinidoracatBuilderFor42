-- 屋頂助手面板：選形狀、方向、山牆、樓層，按「拖出範圍」拖一個長方形，Roof.layout 排出的片整批加進藍圖
-- （PlanMode.addMany：一步，復原一次整個收回）。建造視窗詳情的「屋頂助手」鈕只認 RoofPanel.available／open。
-- 拖範圍用 Cursor.startArea（一區拆除、框選同一個長方形游標）：拖的是地面上房子的範圍，屋頂排在規劃樓層的正上方。
-- 手把沒有長方形游標（startArea 回 nil，使用者 2026-11-01 裁定手把不做長方形）：拖出範圍鈕停用並說明。
-- 框架缺或太舊時只跳通知（UI AGENTS 契約 3：不 error）。PlanMode、Window、Index、Names 都晚綁定。
require "MinidoracatBuilder/Roof"
require "MinidoracatBuilder/Messages"

MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local RP = B.RoofPanel or {}
B.RoofPanel = RP
local Roof, Messages = B.Roof, B.Messages

local LOG = "[MinidoracatBuilderFor42] "
local PAD, GAP = 8, 6
RP.CAPS = { "window", "controls", "dropdown" }
-- 這次的選擇（關掉再開照舊）：pn、set（Roof.family）、shape、dir、gableTs（山牆圖塊組，"" 是不放）、gable（Roof.gableFamily）
RP.st = { gableTs = "" }
-- PlanMode.addMany 的失敗碼 → 屋頂自己的句子（addMany 失敗時不跳通知）。TOO_HIGH 和 Roof.layout 的同一句（兩種都是超過藍圖層數）
local ADD_WHY = { FULL = "IGUI_MBLD_Roof_Err_FULL", TOO_WIDE = "IGUI_MBLD_Roof_Err_PLAN_WIDE",
    TOO_HIGH = "IGUI_MBLD_Roof_Err_TOO_HIGH", OFF = "IGUI_MBLD_Roof_Err_OFF" }

local function title() return getText("IGUI_MBLD_Roof_Title") end

-- 認得出整套、而且規劃模式有整批加片的入口（PlanMode.addMany）才給
function RP.available(name)
    local PM = B.PlanMode
    if not (PM and PM.addMany) then return false end
    local set = Roof.family(name)
    return set ~= nil and #Roof.shapes(set) > 0
end

-- 形狀與方向夾回這一套做得出的；回形狀定義
function RP.fix()
    local st = RP.st
    local list, def = Roof.shapes(st.set), nil
    for _, s in ipairs(list) do
        if s.id == st.shape then def = s end
    end
    def = def or list[1]
    st.shape = def and def.id
    local dirs = def and def.dirs or {}
    local ok = false
    for _, d in ipairs(dirs) do
        if d == st.dir then ok = true end
    end
    if not ok then st.dir = dirs[1] end
    return def
end

-- 選山牆組：認不出或坡度不同（族不同）回 false，選擇退回不放
function RP.pickGable(ts)
    local st = RP.st
    local g = ts ~= "" and Roof.gableFamily(ts) or nil
    if g and st.set and g.fam == st.set.fam then
        st.gable, st.gableTs = g, ts
        return true
    end
    st.gable, st.gableTs = nil, ""
    return ts == ""
end

local memo = {}
local function layout(x1, y1, x2, y2, z)
    local st = RP.st
    return Roof.layout(st.set, st.shape, st.dir, x1, y1, x2, y2, z, st.gable)
end

-- 長方形游標的預覽（Cursor.startArea 的 cb.preview）：屋頂片的格子（灰框，排在規劃樓層）與兩行字。範圍、樓層、選擇沒變
-- 回同一份（游標每秒再問一次，拿到同一份就不重排）
function RP.preview(x1, y1, x2, y2)
    local st, PM = RP.st, B.PlanMode
    local z = PM and PM.level and PM.level()
    if not (st.set and z) then return { cells = {}, lines = {} } end
    local key = table.concat({ st.set.ts, tostring(st.set.base), tostring(x1), tostring(y1), tostring(x2), tostring(y2),
        tostring(z), tostring(st.shape), tostring(st.dir), st.gableTs }, ",")
    if memo.key == key then return memo.res end
    local groups, code = layout(x1, y1, x2, y2, z)
    local warn = groups and code
    local cells, seen, n = {}, {}, 0
    local text
    if groups then
        for _, g in ipairs(groups) do
            for _, c in ipairs(g.cells) do
                n = n + 1
                local k = c[1] .. "," .. c[2] .. "," .. c[3]
                if not seen[k] then
                    seen[k] = true
                    cells[#cells + 1] = { x = c[1], y = c[2], z = c[3], bad = true, over = true }
                end
            end
        end
        text = getText("IGUI_MBLD_Roof_Preview", getText("IGUI_MBLD_Sub_slope" .. st.set.fam),
            getText("IGUI_MBLD_Roof_Shape_" .. st.shape), tostring(math.abs(x2 - x1) + 1), tostring(math.abs(y2 - y1) + 1),
            tostring(n))
    else
        text = getText("IGUI_MBLD_Roof_Err_" .. code)
    end
    local lines = { text }
    if warn and warn.HALF then lines[#lines + 1] = getText("IGUI_MBLD_Roof_Warn_HALF") end
    lines[#lines + 1] = getText("IGUI_MBLD_Area_HintRelease") .. getText("IGUI_MBLD_HintSep") .. getText("IGUI_MBLD_HintCancel")
    local res = { cells = cells, lines = lines }
    memo.key, memo.res = key, res
    return res
end

-- 放開：排出來的片整批加進藍圖（一步）；排不出或加不進去用通知說原因
function RP.release(x1, y1, x2, y2)
    local st, PM = RP.st, B.PlanMode
    local player = getSpecificPlayer(st.pn or 0)
    if not (st.set and PM and PM.addMany) then return false end
    if not PM.planning() then
        if not PM.toggle(st.pn) then
            Messages.toast(player, getText(ADD_WHY.OFF), title())
            return false
        end
        if player then PM.setLevel(math.floor(player:getZ()) + 1) end
    end
    local groups, code = layout(x1, y1, x2, y2, PM.level())
    if not groups then
        Messages.toast(player, getText("IGUI_MBLD_Roof_Err_" .. code), title())
        return false
    end
    local n, why = PM.addMany(st.pn, groups)
    if not n then
        Messages.toast(player, getText(ADD_WHY[why] or ADD_WHY.OFF), title())
        return false
    end
    return true
end

-- 拖出範圍：長方形游標每邊最多藍圖的上限；手把回 nil
function RP.drag(pn)
    local Cursor, Plan = B.Cursor, B.Plan
    local o = Cursor and Cursor.startArea and Cursor.startArea(pn, {
        side = Plan and Plan.MAX_SIDE or 64,
        preview = function(x1, y1, x2, y2) return RP.preview(x1, y1, x2, y2) end,
        release = function(x1, y1, x2, y2) RP.release(x1, y1, x2, y2) end,
        cancel = function() end,
    })
    if not o then Messages.toast(getSpecificPlayer(pn), getText("IGUI_MBLD_Roof_Drag_Pad"), title()) end
    return o
end

-- ---------------------------------------------------------------- 面板

local Panel = {}
Panel.__index = Panel

local function dirLabel(shape, d)
    return getText(shape == "gable" and "IGUI_MBLD_Roof_Axis_" .. d or "IGUI_MBLD_Roof_Dir_" .. d)
end

-- 山牆下拉：「不放」＋目錄裡子種類「山牆與斜牆」的牆圖塊組（Window.subOf 照組名分）；選了才辨識那一組
local function gableOptions()
    local opts = { { id = "", label = getText("IGUI_MBLD_Roof_Gable_None") } }
    local Index, W, Names = B.Index, B.Window, B.Names
    local order = Index and Index.kindSets and Index.kindSets.wall
    for i = 1, order and order.n or 0 do
        local ts = order[i]
        if W and W.subOf and W.subOf("wall", nil, ts .. "_0") == "gable" then
            opts[#opts + 1] = { id = ts, label = Names and Names.tileset(ts) or ts }
        end
    end
    return opts
end

local function wrap(UI, text, w, font)
    return UI.Text and UI.Text.wrap and UI.Text.wrap(text, w, font) or { text }
end

function Panel.new(UI, pn)
    local st = RP.st
    local theme = UI.Theme.create({ variant = "dark" })
    local font = UIFont.Small
    local tm = getTextManager()
    local fh = tm:getFontHeight(font)
    local s = fh / 16
    local self = setmetatable({ UI = UI, pn = pn, theme = theme, font = font, fh = fh, rows = {} }, Panel)
    local sx, sy = getPlayerScreenLeft(pn), getPlayerScreenTop(pn)
    local sw, sh = getPlayerScreenWidth(pn), getPlayerScreenHeight(pn)
    local w = math.min(sw - 20, math.floor(360 * s))
    local win = UI.Window.new({ x = 0, y = 0, width = w, height = 100, title = title(), theme = theme, opaque = true,
        onClose = function(wnd)
            UI.Dropdown.close(wnd)
            if RP.panel == self then RP.panel = nil end
        end })
    win.onEscape = function()
        win:close()
        return true
    end
    self.win = win
    -- 底層畫字（標籤、樓層、說明），先加：畫在控制項底下
    local body = ISPanel:new(0, 0, w, 100)
    body:initialise()
    body.background = false
    body.render = function() self:draw() end
    win:addChild(body)
    self.body = body

    local labW = 0
    for _, k in ipairs({ "IGUI_MBLD_Roof_Shape", "IGUI_MBLD_Roof_Dir", "IGUI_MBLD_Roof_Gable" }) do
        labW = math.max(labW, tm:MeasureStringX(font, getText(k)))
    end
    local cx, cw = PAD + labW + GAP, w - 2 * PAD - labW - GAP
    local y = win:contentTop() + GAP
    local function row(key, ctl)
        self.rows[#self.rows + 1] = { s = getText(key), y = y + math.floor((ctl.height - fh) / 2) }
        win:addChild(ctl)
        y = y + ctl.height + GAP
    end
    local shapeOpts = {}
    for _, d in ipairs(Roof.shapes(st.set)) do
        shapeOpts[#shapeOpts + 1] = { id = d.id, label = getText("IGUI_MBLD_Roof_Shape_" .. d.id) }
    end
    self.shapeDD = UI.Dropdown.new({ x = cx, y = y, width = cw, options = shapeOpts, selected = st.shape, theme = theme,
        target = self, onChange = function(t, id)
            RP.st.shape = id
            t:syncDirs()
        end })
    row("IGUI_MBLD_Roof_Shape", self.shapeDD)
    self.dirDD = UI.Dropdown.new({ x = cx, y = y, width = cw, options = {}, placeholder = "-", theme = theme, target = self,
        onChange = function(_, id) RP.st.dir = id end })
    row("IGUI_MBLD_Roof_Dir", self.dirDD)
    self.gableDD = UI.Dropdown.new({ x = cx, y = y, width = cw, options = gableOptions(), selected = st.gableTs,
        theme = theme, target = self, onChange = function(t, id)
            t.gableBad = not RP.pickGable(id)
            if t.gableBad then t.gableDD:setSelected("", true) end
        end })
    row("IGUI_MBLD_Roof_Gable", self.gableDD)

    -- 樓層：屋頂排在規劃樓層（PlanMode.level），上一層、下一層鈕直接改規劃的樓層
    local function step(n)
        local PM = B.PlanMode
        if PM and PM.level and PM.level() then PM.setLevel(PM.level() + n) end
    end
    local down = UI.Button.new({ x = 0, y = y, title = "-", theme = theme, font = font, onClick = function() step(-1) end })
    local up = UI.Button.new({ x = 0, y = y, title = "+", theme = theme, font = font, onClick = function() step(1) end })
    up:setX(w - PAD - up.width)
    down:setX(up:getX() - GAP - down.width)
    win:addChild(down)
    win:addChild(up)
    self.levelY = y + math.floor((up.height - fh) / 2)
    y = y + up.height + GAP

    -- 說明（屋頂排法、斜屋頂只擋雨）與山牆認不出的那句（位置先留著，不重排）
    local innerW = w - 2 * PAD
    self.hint = wrap(UI, getText("IGUI_MBLD_Roof_Hint"), innerW, font)
    self.hintY = y
    y = y + #self.hint * fh + GAP
    self.bad = wrap(UI, getText("IGUI_MBLD_Roof_Gable_Bad"), innerW, font)
    self.badY = y
    y = y + #self.bad * fh + GAP
    -- 45 度雙斜、單斜沒放山牆：側面看得到空心（建築編輯器的 45 度房子都配山牆）
    self.h45 = wrap(UI, getText("IGUI_MBLD_Roof_Hint45"), innerW, font)
    self.h45Y = y
    y = y + #self.h45 * fh + GAP

    local drag = UI.Button.new({ x = PAD, y = y, width = innerW, title = getText("IGUI_MBLD_Roof_Drag"), style = "primary",
        theme = theme, font = font, onClick = function() RP.drag(pn) end })
    if JoypadState.players[pn + 1] then
        drag:setEnabled(false)
        drag:setTooltip(getText("IGUI_MBLD_Roof_Drag_Pad"))
    end
    win:addChild(drag)
    y = y + drag.height + PAD
    local h = math.min(sh - 40, y)
    win:setHeight(h)
    body:setHeight(h)
    win:setX(sx + math.floor((sw - w) / 2))
    win:setY(sy + math.floor((sh - h) / 2))
    self:syncDirs()
    win:addToUIManager()
    return self
end

-- 方向下拉照目前的形狀換選項；沒有方向的（四坡、平頂）停用
function Panel:syncDirs()
    local def = RP.fix()
    local st, opts = RP.st, {}
    for _, d in ipairs(def and def.dirs or {}) do opts[#opts + 1] = { id = d, label = dirLabel(st.shape, d) } end
    self.dirDD:setOptions(opts)
    self.dirDD:setSelected(st.dir, true)
    self.dirDD:setEnabled(#opts > 0)
end

-- 每幀：只畫備好的字；樓層字只在樓層變了才重組
function Panel:draw()
    local c, font, b = self.theme.colors, self.font, self.body
    for i = 1, #self.rows do
        local r = self.rows[i]
        b:drawText(r.s, PAD, r.y, c.text.r, c.text.g, c.text.b, 1, font)
    end
    local PM = B.PlanMode
    local z = PM and PM.level and PM.level()
    if z ~= self.z then
        self.z = z
        self.levelText = z and getText("IGUI_MBLD_Roof_Level", tostring(z + 1)) or ""
    end
    b:drawText(self.levelText, PAD, self.levelY, c.text.r, c.text.g, c.text.b, 1, font)
    for i = 1, #self.hint do
        b:drawText(self.hint[i], PAD, self.hintY + (i - 1) * self.fh, c.textMuted.r, c.textMuted.g, c.textMuted.b, 1, font)
    end
    local wc = c.warning
    if self.gableBad then
        for i = 1, #self.bad do
            b:drawText(self.bad[i], PAD, self.badY + (i - 1) * self.fh, wc.r, wc.g, wc.b, 1, font)
        end
    end
    local st = RP.st
    if st.set and st.set.fam == "45" and st.gableTs == "" and (st.shape == "gable" or st.shape == "shed") then
        for i = 1, #self.h45 do
            b:drawText(self.h45[i], PAD, self.h45Y + (i - 1) * self.fh, wc.r, wc.g, wc.b, 1, font)
        end
    end
end

-- 開面板（同時只開一個，新的取代舊的）：認不出整套、沒有 addMany、沒有框架回 false。規劃沒開就先開，
-- 規劃樓層設成玩家那層加 1（屋頂預設蓋在上一層，同建造游標的 LAYERED）
function RP.open(playerNum, name)
    local PM, W = B.PlanMode, B.Window
    local player = getSpecificPlayer(playerNum)
    if not (player and PM and PM.addMany) then return false end
    local set = Roof.family(name)
    if not (set and #Roof.shapes(set) > 0) then return false end
    local UI = W and W.ui and W.ui(RP.CAPS)
    if UI == nil then
        Messages.toast(player, getText("IGUI_MBLD_NeedFramework"), getText("IGUI_MBLD_Title"))
        return false
    end
    if not PM.planning() and not PM.toggle(playerNum) then
        Messages.toast(player, getText(ADD_WHY.OFF), title())
        return false
    end
    PM.setLevel(math.floor(player:getZ()) + 1)
    local st = RP.st
    st.pn, st.set = playerNum, set
    if st.gable and st.gable.fam ~= set.fam then st.gable, st.gableTs = nil, "" end
    RP.fix()
    if RP.panel then RP.panel.win:close() end
    local ok, p = pcall(Panel.new, UI, playerNum)
    if not ok then
        print(LOG .. "roof panel build failed: " .. tostring(p))
        return false
    end
    RP.panel = p
    p.win:setVisible(true)
    p.win:bringToTop()
    return true
end

return RP
