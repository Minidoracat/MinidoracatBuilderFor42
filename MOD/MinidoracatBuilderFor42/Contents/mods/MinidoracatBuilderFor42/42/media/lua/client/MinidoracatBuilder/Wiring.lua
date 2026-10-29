-- 接線（第六階段，設計稿「燈與開關」）：右鍵選單的線路項目、接線模式（游標＋家族框架面板），送 circuit／wire 給伺服器、
-- 收 circuit 回覆（server/MinidoracatBuilder/Circuits.lua）。線路只在伺服器，這裡每次都問、不存；選單用 modData 的
-- builderEntry 判斷要不要列（只給畫面看，伺服器照帳本重查）。
require "MinidoracatBuilder/Check"
require "MinidoracatBuilder/Messages"
require "MinidoracatBuilder/Window"
require "MinidoracatBuilder/Cursor"

MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local Wiring = B.Wiring or {}
B.Wiring = Wiring
local Messages, CC = B.Messages, B.Check.CIRCUIT

local LOG = "[MinidoracatBuilderFor42] "
local MODULE = "MinidoracatBuilder"
local KEEP = 32 -- Wiring.results 只留最近幾筆
local BUSY_MS = 5000 -- 送出後這麼久沒回覆就不再等（伺服器每個指令都回，這是保險）
local PAD, GAP, SW = 8, 6, 10
-- 接線模式的外框顏色（設計稿）：這個開關綠、已接黃、可接白、別條線路灰
local COLOR = { this = { 0, 1, 0 }, wired = { 1, 0.85, 0.4 }, free = { 0.95, 0.95, 0.95 }, other = { 0.55, 0.55, 0.55 } }
-- 回這些碼時接線模式關掉（開關不在、太遠、不能用了）
local FATAL = { GONE = true, NOT_LOADED = true, NOT_SWITCH = true, TOO_FAR = true, OFF = true, NOT_ALLOWED = true, STATE = true }

Wiring.results = {} -- 伺服器的 circuit 回覆，新的在後（E2E 讀）
Wiring.mode = nil   -- 目前的接線模式：{ player, pn, sw = { x, y, z, e }, id, s, l, cand, byPos, busy, cursor, win }
local lastQ = getTimestampMs() % 1000000
local waiting = {}  -- 請求編號 → 收到回覆時呼叫

local function keyOf(c) return c.x .. "," .. c.y .. "," .. c.z .. "," .. c.e end
local function title() return getText("IGUI_MBLD_Wire_Title") end

-- 送 circuit／wire。單機直接交給伺服器程式（同一個 Lua 狀態）。回請求編號
function Wiring.send(player, cmd, args, onReply)
    lastQ = lastQ % 2000000000 + 1
    local q = lastQ
    args.q = q
    waiting[q - KEEP] = nil
    waiting[q] = onReply
    if isClient() then
        sendClientCommand(player, MODULE, cmd, args)
    elseif B.Circuits then
        B.Circuits.command(player, cmd, args)
    end
    return q
end

local function at(o)
    local sq = o:getSquare()
    return { x = sq:getX(), y = sq:getY(), z = sq:getZ(), e = o:getSprite():getName() }
end

-- 客戶端那一格上 sprite 名稱是 e 的 IsoLightSwitch
local function objAt(c)
    local sq = getCell():getGridSquare(c.x, c.y, c.z)
    local objs = sq and sq:getObjects()
    for i = 0, (objs and objs:size() or 0) - 1 do
        local o = objs:get(i)
        if instanceof(o, "IsoLightSwitch") and o:getSprite() and o:getSprite():getName() == c.e then return o end
    end
    return nil
end

local CODES = { OFF = true, NOT_ALLOWED = true, STATE = true, BAD_REQUEST = true, RATE_LIMITED = true, NOT_LOADED = true,
    GONE = true, NOT_SWITCH = true, NOT_WIRABLE = true, TOO_FAR = true, SAFEHOUSE = true, FULL = true, OUT_OF_RANGE = true,
    NOT_ENCLOSED = true, NOT_WIRED = true, INTERNAL = true }

-- 接線的拒絕碼 → 一句話（翻譯鍵 IGUI_MBLD_WireRefuse_<碼>）
function Wiring.refusal(code)
    if not CODES[code] then return getText("IGUI_MBLD_WireRefuse_Other", tostring(code)) end
    local key = "IGUI_MBLD_WireRefuse_" .. code
    if code == "TOO_FAR" then return getText(key, tostring(CC.RANGE)) end
    if code == "FULL" then return getText(key, tostring(CC.MAX_S), tostring(CC.MAX_L)) end
    if code == "OUT_OF_RANGE" then return getText(key, tostring(CC.RANGE), tostring(CC.LEVELS)) end
    return getText(key)
end

local function tell(player, text) Messages.toast(player, text, title()) end

local function refused(player, code)
    if code == "PERM_DENIED" then return end -- Safehouse 拒絕時自己推了通知（同 Cursor 的 tell）
    tell(player, Wiring.refusal(code))
end

-- 自動接線（放開關、按「接同一房間」）的結果
local function wiredText(r)
    local text
    if r.auto == "lamp" then
        text = getText("IGUI_MBLD_Wire_LampJoined")
    elseif r.jx then
        text = getText("IGUI_MBLD_Wire_AutoJoined", tostring(r.jx), tostring(r.jy), tostring(#(r.l or {})))
    elseif (r.n or 0) > 0 then
        text = getText("IGUI_MBLD_Wire_Auto", tostring(r.n))
    else
        text = getText("IGUI_MBLD_Wire_AutoNone")
    end
    if (r.taken or 0) > 0 then text = text .. " " .. getText("IGUI_MBLD_Wire_Taken", tostring(r.taken)) end
    return text
end

-- circuit：{ q, code, id, s = { { x, y, z, e } }, l, cand = { { x, y, z, e, k, c } }, auto, n, taken, jx, jy, moved, op, note }
function Wiring.onServerCommand(cmd, args)
    if cmd ~= "circuit" then return end
    local list = Wiring.results
    list[#list + 1] = args
    if #list > KEEP then table.remove(list, 1) end
    local player = getSpecificPlayer(0)
    if args.note == "UNLOADED" then return tell(player, getText("IGUI_MBLD_Wire_Unloaded", tostring(args.n))) end
    if args.auto then
        if args.code then return refused(player, args.code) end
        return tell(player, wiredText(args))
    end
    local h = args.q and waiting[args.q]
    if h then
        waiting[args.q] = nil
        h(args)
    end
end

Events.OnServerCommand.Add(function(module, command, args)
    if module == MODULE and command == "circuit" then MinidoracatBuilder.Wiring.onServerCommand(command, args or {}) end
end)

-- ---------------------------------------------------------------- 接線模式：外框

local function unmark(m)
    for _, o in ipairs(m.marked or {}) do
        o:setHighlighted(m.pn, false, false)
        o:setOutlineHighlight(m.pn, false)
    end
    m.marked = {}
end

local function mark(m, o, rgb)
    o:setHighlighted(m.pn, true, false)
    o:setHighlightColor(m.pn, rgb[1], rgb[2], rgb[3], 1)
    o:setOutlineHighlight(m.pn, true)
    o:setOutlineHighlightCol(m.pn, rgb[1], rgb[2], rgb[3], 1)
    m.marked[#m.marked + 1] = o
end

local function remark(m)
    unmark(m)
    local sw = objAt(m.sw)
    if sw then mark(m, sw, COLOR.this) end
    for _, c in ipairs(m.cand or {}) do
        local o = objAt(c)
        if o then mark(m, o, COLOR[c.status]) end
    end
end

-- 伺服器回的這條線路與附近可接的 → 狀態、外框
function Wiring.apply(m, r)
    m.id = r.id
    local inS, inL = {}, {}
    for _, c in ipairs(r.s or {}) do inS[keyOf(c)] = true end
    for _, c in ipairs(r.l or {}) do inL[keyOf(c)] = true end
    m.nS, m.nL = math.max(1, #(r.s or {})), #(r.l or {})
    if r.cand then m.cand = r.cand end
    m.byPos = {}
    for _, c in ipairs(m.cand or {}) do
        local k = keyOf(c)
        if (c.k == "l" and inL[k]) or (c.k == "s" and inS[k]) then
            c.status = "wired"
        elseif c.c == nil then
            c.status = "free"
        else
            c.status = "other"
        end
        m.byPos[c.x .. "," .. c.y .. "," .. c.z] = c
    end
    remark(m)
end

-- 那一格可以點的燈或開關（不含這個開關自己）
function Wiring.at(x, y, z)
    local m = Wiring.mode
    return m and m.byPos and m.byPos[x .. "," .. y .. "," .. z] or nil
end

-- 送一個接線指令（op＝add／remove／join／room／clear，c＝點到的那一個）。回覆前不收下一個
function Wiring.op(op, c)
    local m = Wiring.mode
    if not m or (m.busy and getTimestampMs() - m.busyAt < BUSY_MS) then return nil end
    local args = { op = op, x = m.sw.x, y = m.sw.y, z = m.sw.z, e = m.sw.e, cand = true }
    if c then args.tx, args.ty, args.tz, args.te = c.x, c.y, c.z, c.e end
    m.busyAt = getTimestampMs()
    m.busy = Wiring.send(m.player, "wire", args, function(r)
        if Wiring.mode ~= m then return end
        m.busy = nil
        if r.code then
            refused(m.player, r.code)
            if FATAL[r.code] then Wiring.close() end
            return
        end
        Wiring.apply(m, r)
        if op == "room" then
            tell(m.player, wiredText(r))
        elseif r.moved and op == "add" then
            tell(m.player, getText("IGUI_MBLD_Wire_Moved"))
        end
    end)
    return m.busy
end

-- 點一格：開關＝接成雙切（已在這條線路就拿掉）；燈＝加入或移除
function Wiring.click(x, y, z)
    local c = Wiring.at(x, y, z)
    if not c then return nil end
    if c.k == "s" then return Wiring.op("join", c) end
    return Wiring.op(c.status == "wired" and "remove" or "add", c)
end

-- ---------------------------------------------------------------- 接線模式：游標
-- 原版 ISBuildingObject 的子類別（同 Cursor.lua）：引擎照常呼叫 isValid → render → 放開左鍵／手把 A 時 tryBuild。
-- 只用來選格子與擋掉原版的點擊（拖曳物件在時原版不開燈、不開門）；右鍵、手把 B 照原版取消。

local WireCursor, Class = {}, nil

function WireCursor:getSprite() return self.mode.sw.e end
function WireCursor:rotateKey() end
function WireCursor:rotateMouse() end

function WireCursor:isValid(square)
    local m = self.mode
    if not self.joypad and B.Cursor.mouseOverUI(nil) then
        self.hover = nil
        return false
    end
    self.hover = Wiring.at(square:getX(), square:getY(), square:getZ())
    return self.hover ~= nil and not (m.busy and getTimestampMs() - m.busyAt < BUSY_MS)
end

function WireCursor:render(x, y, z)
    local good, bad = getCore():getGoodHighlitedColor(), getCore():getBadHighlitedColor()
    local c = self.hover and good or bad
    self:getFloorCursorSprite():RenderGhostTileColor(x, y, z, c:getR(), c:getG(), c:getB(), 0.8)
end

function WireCursor:tryBuild(x, y, z) Wiring.click(x, y, z) end

function WireCursor:deactivate()
    local m = Wiring.mode
    if m and m.cursor == self then Wiring.close() end
end

-- 手把：A 加入或移除（引擎的建造鍵）、X 接同一房間、Y 回角色位置、B 離開（原版）；LB／RB 不轉向
function WireCursor:onJoypadPressButton(joypadIndex, joypadData, button)
    if button == Joypad.XButton then
        Wiring.op("room")
        return
    end
    if button == Joypad.BButton or button == Joypad.YButton then
        ISBuildingObject.onJoypadPressButton(self, joypadIndex, joypadData, button)
    end
end

function WireCursor:getAPrompt()
    if not self.hover then return nil end
    if self.hover.k == "s" then return getText("IGUI_MBLD_Wire_PadJoin") end
    return getText(self.hover.status == "wired" and "IGUI_MBLD_Wire_PadRemove" or "IGUI_MBLD_Wire_PadAdd")
end
function WireCursor:getXPrompt() return getText("IGUI_MBLD_Wire_Room") end
function WireCursor:getLBPrompt() return nil end
function WireCursor:getRBPrompt() return nil end

local function newCursor(m)
    if not Class then
        Class = ISBuildingObject:derive("MinidoracatBuilderWireCursor")
        for k, v in pairs(WireCursor) do Class[k] = v end
    end
    local o = setmetatable({}, Class)
    Class.__index = Class
    o:init()
    o.character, o.player, o.mode = m.player, m.pn, m
    o.dragNilAfterPlace = false
    o.isYButtonResetCursor = true
    o.joypad = JoypadState.players[m.pn + 1] ~= nil
    return o
end

-- ---------------------------------------------------------------- 接線模式：面板（家族框架 Window）

local function drawPanel(panel)
    local m = Wiring.mode
    if not m then return end
    local c, mu, f, fh = m.colors.text, m.colors.textMuted, m.font, m.fh
    local y = 0
    local line1 = m.nS and getText("IGUI_MBLD_Wire_Circuit", tostring(m.nS), tostring(m.nL)) or getText("IGUI_MBLD_Wire_Loading")
    panel:drawText(line1, 0, y, c.r, c.g, c.b, c.a or 1, f)
    y = y + fh
    panel:drawText(m.limit, 0, y, mu.r, mu.g, mu.b, mu.a or 1, f)
    y = y + fh + 4
    for row = 0, 1 do
        local x = 0
        for i = 1, 2 do
            local it = m.legend[row * 2 + i]
            local rgb = COLOR[it.k]
            panel:drawRect(x, y + math.floor((fh - SW) / 2), SW, SW, 1, rgb[1], rgb[2], rgb[3])
            panel:drawText(it.s, x + SW + 4, y, c.r, c.g, c.b, c.a or 1, f)
            x = x + m.legendW
        end
        y = y + fh
    end
    y = y + 4
    for _, s in ipairs(m.hint) do
        panel:drawText(s, 0, y, mu.r, mu.g, mu.b, mu.a or 1, f)
        y = y + fh
    end
end

local function buildPanel(m, UI)
    local theme = UI.Theme.create({ variant = "dark" })
    local font = UIFont.Small
    local tm = getTextManager()
    local fh = tm:getFontHeight(font)
    m.colors, m.font, m.fh = theme.colors, font, fh
    m.limit = getText("IGUI_MBLD_Wire_Limit", tostring(CC.MAX_S), tostring(CC.MAX_L))
    m.legend = { { k = "this", s = getText("IGUI_MBLD_Wire_LegendThis") }, { k = "wired", s = getText("IGUI_MBLD_Wire_LegendWired") },
        { k = "free", s = getText("IGUI_MBLD_Wire_LegendFree") }, { k = "other", s = getText("IGUI_MBLD_Wire_LegendOther") } }
    m.hint = { getText("IGUI_MBLD_Wire_Hint1"), getText("IGUI_MBLD_Wire_Hint2") }
    local w = tm:MeasureStringX(font, getText("IGUI_MBLD_Wire_Circuit", "4", "16"))
    w = math.max(w, tm:MeasureStringX(font, m.limit))
    m.legendW = 0
    for _, it in ipairs(m.legend) do m.legendW = math.max(m.legendW, SW + 4 + tm:MeasureStringX(font, it.s) + 12) end
    w = math.max(w, m.legendW * 2)
    for _, s in ipairs(m.hint) do w = math.max(w, tm:MeasureStringX(font, s)) end
    local pn = m.pn
    local opts = { x = getPlayerScreenLeft(pn) + 20, y = getPlayerScreenTop(pn) + 80, width = w + PAD * 2, height = 100,
        title = title(), icon = "plug", theme = theme,
        onClose = function() MinidoracatBuilder.Wiring.close() end }
    if UI.CAPABILITIES.opaqueWindow == true then opts.opaque = true end
    local win = UI.Window.new(opts)
    win.onEscape = function()
        win:close()
        return true
    end
    local top = win:contentTop() + GAP
    local text = ISPanel:new(PAD, top, w, fh * 6 + 8)
    text:initialise()
    text.background = false
    text.render = drawPanel
    win:addChild(text)
    local function button(label, style, fn)
        local b = UI.Button.new({ x = 0, y = 0, title = label, style = style, theme = theme, onClick = fn })
        b:fitWidth()
        win:addChild(b)
        return b
    end
    local room = button(getText("IGUI_MBLD_Wire_Room"), nil, function() MinidoracatBuilder.Wiring.op("room") end)
    local clear = button(getText("IGUI_MBLD_Wire_Clear"), nil, function() MinidoracatBuilder.Wiring.op("clear") end)
    local done = button(getText("IGUI_MBLD_Wire_Done"), "primary", function() MinidoracatBuilder.Wiring.close() end)
    local by = top + text.height + GAP
    room:setX(PAD)
    clear:setX(PAD + room.width + GAP)
    local total = PAD + room.width + GAP + clear.width + GAP + done.width + PAD
    if total > win.width then win:setWidth(total) end
    done:setX(win.width - PAD - done.width)
    for _, b in ipairs({ room, clear, done }) do b:setY(by) end
    win:setHeight(by + done.height + PAD)
    win:addToUIManager()
    if JoypadState.players[pn + 1] then setJoypadFocus(pn, nil) end -- 手把留給游標（框架顯示視窗時會接手手把）
    m.win = win
end

-- 開接線模式：sw＝{ x, y, z, e }（本工具的開關）。先向伺服器要這條線路與附近可接的，回來才有外框
function Wiring.open(playerNum, sw)
    local player = getSpecificPlayer(playerNum)
    if not player then return false end
    local UI = B.Window.ui({ "window", "controls" })
    if not UI then
        Messages.toast(player, getText("IGUI_MBLD_NeedFramework"), title())
        return false
    end
    Wiring.close()
    local m = { player = player, pn = playerNum, sw = sw, marked = {}, cand = {} }
    Wiring.mode = m
    local ok, err = pcall(buildPanel, m, UI)
    if not ok then
        print(LOG .. "wiring panel failed: " .. tostring(err))
        Wiring.close()
        return false
    end
    m.cursor = newCursor(m)
    getCell():setDrag(m.cursor, playerNum)
    m.busyAt = getTimestampMs()
    m.busy = Wiring.send(player, "circuit", { x = sw.x, y = sw.y, z = sw.z, e = sw.e, cand = true }, function(r)
        if Wiring.mode ~= m then return end
        m.busy = nil
        if r.code then
            refused(player, r.code)
            return Wiring.close()
        end
        Wiring.apply(m, r)
    end)
    return true
end

function Wiring.close()
    local m = Wiring.mode
    if not m then return end
    Wiring.mode = nil
    unmark(m)
    if m.win then
        m.win:setVisible(false)
        m.win:removeFromUIManager()
    end
    if m.cursor and getCell():getDrag(m.pn) == m.cursor then getCell():setDrag(nil, m.pn) end
end

-- ---------------------------------------------------------------- 右鍵選單

local function ours(o) return o:hasModData() and o:getModData().builderEntry ~= nil end

local function lightR(o)
    local p = o:getSprite() and o:getSprite():getProperties()
    return p ~= nil and p:has("lightR"), p
end

-- 本工具的開關、或接得上的燈（本工具蓋的、能搬的）
local function kindOf(o)
    if not instanceof(o, "IsoLightSwitch") then return nil end
    local lit, p = lightR(o)
    if not p then return nil end
    if not lit then return ours(o) and "s" or nil end
    if ours(o) or p:has("IsMoveAble") then return "l" end
    return nil
end

local function highlight(_, menu, on, list)
    for _, c in ipairs(list or {}) do
        local o = objAt(c)
        if o then
            o:setHighlighted(menu.player, on, false)
            o:setHighlightColor(menu.player, COLOR.this[1], COLOR.this[2], COLOR.this[3], 1)
            o:setOutlineHighlight(menu.player, on)
            o:setOutlineHighlightCol(menu.player, COLOR.this[1], COLOR.this[2], COLOR.this[3], 1)
        end
    end
end

function Wiring.openFromMenu(playerNum, o) return Wiring.open(playerNum, at(o)) end

function Wiring.openFromLamp(playerNum, st)
    if st.sw then Wiring.open(playerNum, st.sw) end
end

-- 拔線：伺服器回了才說結果
function Wiring.unplug(playerNum, o)
    local player = getSpecificPlayer(playerNum)
    local args = at(o)
    args.op = "unplug"
    return Wiring.send(player, "wire", args, function(r)
        if r.code then return refused(player, r.code) end
        tell(player, getText("IGUI_MBLD_Wire_Unplugged"))
    end)
end

-- 燈：「線路（建造工坊）」子選單。先列出來（變灰），伺服器回了再填：由幾個開關控制（游標移上去時那些開關亮綠框）、拔線、
-- 打開接線模式（開第一個開關的）
local function lampMenu(context, playerNum, player, o)
    local opt = context:addOption(getText("IGUI_MBLD_Menu_Circuit"))
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(opt, sub)
    local info = sub:addOption(getText("IGUI_MBLD_Wire_Loading"))
    local st = {}
    local unplug = sub:addOption(getText("IGUI_MBLD_Menu_Unplug"), playerNum, Wiring.unplug, o)
    local open = sub:addOption(getText("IGUI_MBLD_Menu_OpenWiring"), playerNum, Wiring.openFromLamp, st)
    info.notAvailable, unplug.notAvailable, open.notAvailable = true, true, true
    Wiring.send(player, "circuit", at(o), function(r)
        if r.code then
            info.name = Wiring.refusal(r.code)
        elseif #(r.s or {}) == 0 then
            info.name = getText("IGUI_MBLD_Menu_NotWired")
        else
            info.name = getText("IGUI_MBLD_Menu_ControlledBy", tostring(#r.s))
            info.notAvailable = false
            info.onHighlight, info.onHighlightParams = highlight, { r.s }
            unplug.notAvailable, open.notAvailable = false, false
            st.sw = r.s[1]
        end
        sub:setWidth(sub:calcWidth())
    end)
end

-- 原版沒列「開燈／關燈」時補上（沒有房間又不能改裝、或客戶端算沒電，ISWorldObjectContextMenuLogic.java:367-369、
-- ISWorldObjectContextMenu.lua:1226-1236）。選了照原版走過去、排 ISToggleLightAction，伺服器照線路或原版處理
local function toggleMenu(context, worldobjects, playerNum, o)
    local sq = o:getSquare()
    if (sq:getRoom() ~= nil or o:getCanBeModified()) and o:canSwitchLight() then return end
    context:addOption(getText(o:isActivated() and "ContextMenu_Turn_Off" or "ContextMenu_Turn_On"), worldobjects,
        ISWorldObjectContextMenu.onToggleLight, o, playerNum)
end

function Wiring.fill(playerNum, context, worldobjects, test)
    local player = getSpecificPlayer(playerNum)
    if not player or player:getVehicle() then return end
    local found, done = {}, {}
    for _, w in ipairs(worldobjects) do
        local sq = w:getSquare()
        if sq and not done[sq] then
            done[sq] = true
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do
                local o = objs:get(i)
                local k = kindOf(o)
                if k then found[#found + 1] = { o = o, k = k } end
            end
        end
    end
    if #found == 0 then return end
    if test then return ISWorldObjectContextMenu.setTest() end -- 手把：有選項就回報（ISWorldObjectContextMenu.lua:122-125）
    for _, f in ipairs(found) do
        if f.k == "s" then
            context:addOption(getText("IGUI_MBLD_Menu_Wire"), playerNum, Wiring.openFromMenu, f.o)
        else
            lampMenu(context, playerNum, player, f.o)
        end
        if ours(f.o) then toggleMenu(context, worldobjects, playerNum, f.o) end
    end
end

Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, worldobjects, test)
    return MinidoracatBuilder.Wiring.fill(playerNum, context, worldobjects, test)
end)

return Wiring
