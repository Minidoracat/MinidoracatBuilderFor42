-- 接線（第六階段，設計稿「燈與開關」）：右鍵選單的線路項目、接線模式（游標＋家族框架面板），送 circuit／wire 給伺服器、
-- 收 circuit 回覆（server/MinidoracatBuilder/Circuits.lua）。線路只在伺服器，這裡每次都問、不存；選單用 modData 的
-- builderEntry 判斷要不要列（只給畫面看，伺服器照帳本重查）。
require "MinidoracatBuilder/Check"
require "MinidoracatBuilder/Messages"
require "MinidoracatBuilder/Names"
require "MinidoracatBuilder/Window"
require "MinidoracatBuilder/Cursor"

MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local Wiring = B.Wiring or {}
B.Wiring = Wiring
local Messages, Names, CC = B.Messages, B.Names, B.Check.CIRCUIT

local LOG = "[MinidoracatBuilderFor42] "
local MODULE = "MinidoracatBuilder"
local KEEP = 32 -- Wiring.results 只留最近幾筆
local BUSY_MS = 5000 -- 送出後這麼久沒回覆就不再等（伺服器每個指令都回，這是保險）
local PAD, GAP, SW = 8, 6, 10
-- 接線模式的外框顏色（設計稿）：這個開關綠、已接黃、可接白、別條線路灰
local COLOR = { this = { 0, 1, 0 }, wired = { 1, 0.85, 0.4 }, free = { 0.95, 0.95, 0.95 }, other = { 0.55, 0.55, 0.55 } }
-- 開關本身（回覆沒有 side；side＝"t" 是點的目標、"l" 是線路上的燈）回這些碼時接線模式關掉
local FATAL = { GONE = true, NOT_LOADED = true, NOT_SWITCH = true, TOO_FAR = true, OFF = true, NOT_ALLOWED = true, STATE = true }
-- 放燈沒自動接上的原因 → 翻譯鍵（伺服器 Circuits.lampPlaced）
local MISS = { MULTI = "IGUI_MBLD_Wire_Miss_MULTI", FULL = "IGUI_MBLD_Wire_Miss_FULL",
    OUT_OF_RANGE = "IGUI_MBLD_Wire_Miss_OUT_OF_RANGE", DENIED = "IGUI_MBLD_Wire_Miss_DENIED" }

Wiring.results = {} -- 伺服器的 circuit 回覆，新的在後（E2E 讀）
Wiring.mode = nil   -- 目前的接線模式：{ player, pn, sw = { x, y, z, e }, id, nS, nL, cand, byPos, pick, busy, busyAt, cursor, win }
                    -- pick：格子 → 下一次點要選的那一個的鍵（keyOf）
local lastQ = getTimestampMs() % 1000000
local waiting = {}  -- 請求編號 → 收到回覆時呼叫

local function keyOf(c) return c.x .. "," .. c.y .. "," .. c.z .. "," .. c.e end
local function posOf(x, y, z) return x .. "," .. y .. "," .. z end
local function title() return getText("IGUI_MBLD_Wire_Title") end

-- 送出後 BUSY_MS 內算還在等（時鐘往回跳時不算，pitfalls「getTimestampMs 會往回跳」）
local function busy(m)
    if not m.busy then return false end
    local t = getTimestampMs()
    return t >= m.busyAt and t - m.busyAt < BUSY_MS
end

-- 送 circuit／wire。單機直接交給伺服器程式（同一個 Lua 狀態，回呼在這裡面就跑完）。回請求編號
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

-- 接線結果常會接上「另有 N 盞…」兩句，英文 4 行放不下（builder-input-1029c）：最多 8 行
local function tell(player, text) Messages.toast(player, text, title(), 8) end

local function refused(player, code)
    if code == "PERM_DENIED" then return end -- Safehouse 拒絕時自己推了通知（同 Cursor 的 tell）
    tell(player, Wiring.refusal(code))
end

-- 放燈沒自動接上（房間裡有本工具的開關時才回）：原因＋手動接的方法
local function missText(why)
    local key = MISS[why]
    if not key then return nil end
    local reason = why == "FULL" and getText(key, tostring(CC.MAX_L)) or why == "OUT_OF_RANGE" and getText(key, tostring(CC.RANGE))
        or getText(key)
    return getText("IGUI_MBLD_Wire_LampMiss", reason)
end

-- 自動接線（放開關、按「接同一房間」、放燈）的結果
local function wiredText(r)
    local text
    if r.auto == "lamp" then
        if r.miss then return missText(r.miss) end
        text = getText("IGUI_MBLD_Wire_LampJoined")
    elseif r.jx then
        text = getText("IGUI_MBLD_Wire_AutoJoined", tostring(r.jx), tostring(r.jy), tostring(#(r.l or {})))
    elseif (r.n or 0) > 0 then
        text = getText("IGUI_MBLD_Wire_Auto", tostring(r.n))
    elseif #(r.l or {}) > 0 then
        text = getText("IGUI_MBLD_Wire_AutoNoNew", tostring(#r.l))
    elseif r.later then
        text = getText("IGUI_MBLD_Wire_AutoNone")
    else
        text = getText("IGUI_MBLD_Wire_AutoNoneManual")
    end
    if (r.taken or 0) > 0 then text = text .. " " .. getText("IGUI_MBLD_Wire_Taken", tostring(r.taken)) end
    if (r.skipped or 0) > 0 then text = text .. " " .. getText("IGUI_MBLD_Wire_Skipped", tostring(r.skipped)) end
    return text
end

-- 回覆的 who（操作的人的 onlineID）→ 本機的那位玩家；找不到用玩家 0（分割畫面）
local function localPlayer(who)
    if who ~= nil then
        for i = 0, 3 do
            local p = getSpecificPlayer(i)
            if p and p:getOnlineID() == who then return p end
        end
    end
    return getSpecificPlayer(0)
end

-- circuit：{ q, who, code, side, id, s = { { x, y, z, e } }, l, cand = { { x, y, z, e, k, c } }, auto, n, taken, skipped,
-- later, jx, jy, moved, op, note }。player：單機時伺服器程式直接傳操作的人
function Wiring.onServerCommand(cmd, args, player)
    if cmd ~= "circuit" then return end
    local list = Wiring.results
    list[#list + 1] = args
    if #list > KEEP then table.remove(list, 1) end
    player = player or localPlayer(args.who)
    if args.note == "UNLOADED" then return tell(player, getText("IGUI_MBLD_Wire_Unloaded", tostring(args.n))) end
    if args.auto then
        if args.code then return refused(player, args.code) end
        local text = wiredText(args)
        if text then tell(player, text) end
        return
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

-- 伺服器回的這條線路與附近可接的 → 狀態、外框。一格可能有好幾個（byPos 存清單，pick 記下一次要選的那一個的鍵）
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
        local p = posOf(c.x, c.y, c.z)
        local list = m.byPos[p] or {}
        list[#list + 1] = c
        m.byPos[p] = list
    end
    remark(m)
end

-- 那一格現在選的燈或開關（不含這個開關自己）、第幾個、共幾個
function Wiring.at(x, y, z)
    local m = Wiring.mode
    local p = posOf(x, y, z)
    local list = m and m.byPos and m.byPos[p]
    if not list then return nil end
    local want, i = m.pick[p], 1
    for j, c in ipairs(list) do
        if keyOf(c) == want then
            i = j
            break
        end
    end
    return list[i], i, #list
end

-- 送一個接線指令（op＝add／remove／join／room／clear，c＝點到的那一個）。回覆前不收下一個。onDone：成功（apply 之後），
-- 或被拒而接線模式還開著時呼叫（限流不算）。busy 在送出前設：單機的回覆在 send 裡面就到了，回呼清掉 busy 之後
-- 不能再被 send 的回傳值蓋回去
function Wiring.op(op, c, onDone)
    local m = Wiring.mode
    if not m or busy(m) then return nil end
    local args = { op = op, x = m.sw.x, y = m.sw.y, z = m.sw.z, e = m.sw.e, cand = true }
    if c then args.tx, args.ty, args.tz, args.te = c.x, c.y, c.z, c.e end
    m.busy, m.busyAt = true, getTimestampMs()
    return Wiring.send(m.player, "wire", args, function(r)
        if Wiring.mode ~= m then return end
        m.busy = nil
        if r.code then
            refused(m.player, r.code)
            if FATAL[r.code] and not r.side then return Wiring.close() end
            if onDone and r.code ~= "RATE_LIMITED" then onDone() end
            return
        end
        Wiring.apply(m, r)
        if onDone then onDone() end
        if op == "room" then
            tell(m.player, wiredText(r))
        elseif r.moved and op == "add" then
            tell(m.player, getText("IGUI_MBLD_Wire_Moved"))
        end
    end)
end

-- 點一格：現在選的那個。開關＝接成雙切（已在這條線路就拿掉）；燈＝加入或移除。這一格有好幾個時，回覆後下一次點換
-- 下一個：記物件的鍵（apply 會重排清單，記第幾個會指回剛操作的那一個）。被拒也換（不然每次都拒的那一個會擋住同一格
-- 其他的），限流不換
function Wiring.click(x, y, z)
    local m = Wiring.mode
    local c, _, n = Wiring.at(x, y, z)
    if not c then return nil end
    local p, ck = posOf(x, y, z), keyOf(c)
    local function advance()
        if n < 2 or Wiring.mode ~= m then return end
        local list = m.byPos[p] or {}
        m.pick[p] = nil
        for j, o in ipairs(list) do
            if keyOf(o) == ck then
                m.pick[p] = keyOf(list[j % #list + 1])
                break
            end
        end
    end
    return Wiring.op(c.k == "s" and "join" or c.status == "wired" and "remove" or "add", c, advance)
end

-- 向伺服器要這條線路與附近可接的（打開時）
function Wiring.refresh(m)
    m.busy, m.busyAt = true, getTimestampMs()
    return Wiring.send(m.player, "circuit", { x = m.sw.x, y = m.sw.y, z = m.sw.z, e = m.sw.e, cand = true }, function(r)
        if Wiring.mode ~= m then return end
        m.busy = nil
        if r.code then
            refused(m.player, r.code)
            return Wiring.close()
        end
        Wiring.apply(m, r)
    end)
end

-- 游標停的那一格的說明：「加入：名稱（1／2）」。已在這條線路上的（燈或開關）＝移除
function Wiring.hoverText(c, i, n)
    local key = (c.status == "wired" and "IGUI_MBLD_Wire_PadRemove") or (c.k == "s" and "IGUI_MBLD_Wire_PadJoin")
        or "IGUI_MBLD_Wire_PadAdd"
    local s = getText(key, Names.of(c.e, "light"))
    if n > 1 then s = s .. " " .. getText("IGUI_MBLD_Wire_PickOf", tostring(i), tostring(n)) end
    return s
end

-- 面板那一行：原文（手把提示用）換了才重截成面板寬
local function setHover(m, s)
    if s == m.hoverRaw then return end
    m.hoverRaw = s
    m.hoverText = s and m.fit and m.fit(s, m.textW, m.font) or s
end

-- ---------------------------------------------------------------- 接線模式：游標
-- 原版 ISBuildingObject 的子類別（同 Cursor.lua）：引擎照常呼叫 isValid → render → 放開左鍵／手把 A 時 tryBuild。
-- 只用來選格子；右鍵、手把 B 照原版取消。點到物件時原版的開燈、開門由 onObjectLeftMouseButtonDown 擋（下方）。

local WireCursor, Class = {}, nil

function WireCursor:getSprite() return self.mode.sw.e end
function WireCursor:rotateKey() end
function WireCursor:rotateMouse() end

-- 點燈接線時不讓原版順便開關燈（原版只在拖曳物件有這個方法時才擋，ISObjectClickHandler.lua:341-344；點號呼叫，
-- 第一個參數是被點的物件，不是游標）。builder-input-1029c／d：沒有這個方法時，點一下燈就被切一次
function WireCursor.onObjectLeftMouseButtonDown()
    return true
end

function WireCursor:isValid(square)
    local m = self.mode
    if not self.joypad and B.Cursor.mouseOverUI(nil) then
        self.hover = nil
        setHover(m, nil)
        return false
    end
    local c, i, n = Wiring.at(square:getX(), square:getY(), square:getZ())
    self.hover = c
    setHover(m, c and Wiring.hoverText(c, i, n) or nil)
    return c ~= nil and not busy(m)
end

-- 地上照好／壞色畫一格；停在可以點的格子時，把現在選的那一個用它自己的圖再畫一次（一格好幾個時看得出選的是哪個）
function WireCursor:render(x, y, z)
    local good, bad = getCore():getGoodHighlitedColor(), getCore():getBadHighlitedColor()
    local c = self.hover and good or bad
    self:getFloorCursorSprite():RenderGhostTileColor(x, y, z, c:getR(), c:getG(), c:getB(), 0.8)
    local h = self.hover
    if h then
        local named = IsoSpriteManager.instance:getNamedMap()
        local spr = named:containsKey(h.e) and named:get(h.e)
        if spr then spr:RenderGhostTileColor(h.x, h.y, h.z, 0, 0, 1, 1, 1, 0.6) end
    end
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

function WireCursor:getAPrompt() return self.mode.hoverRaw end
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

local LINES = 8 -- 線路、上限、圖例兩列、說明三列、游標停的那一個

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
    if m.hoverText then panel:drawText(m.hoverText, 0, y, c.r, c.g, c.b, c.a or 1, f) end
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
    m.hint = { getText("IGUI_MBLD_Wire_Hint1"), getText("IGUI_MBLD_Wire_Hint3"), getText("IGUI_MBLD_Wire_Hint2") }
    local w = tm:MeasureStringX(font, getText("IGUI_MBLD_Wire_Circuit", "4", "16"))
    w = math.max(w, tm:MeasureStringX(font, m.limit))
    m.legendW = 0
    for _, it in ipairs(m.legend) do m.legendW = math.max(m.legendW, SW + 4 + tm:MeasureStringX(font, it.s) + 12) end
    w = math.max(w, m.legendW * 2)
    for _, s in ipairs(m.hint) do w = math.max(w, tm:MeasureStringX(font, s)) end
    m.fit, m.textW = UI.Text and UI.Text.fit, w -- 游標停的那一行截成面板寬（名稱長短不一）
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
    local text = ISPanel:new(PAD, top, w, fh * LINES + 8)
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
    local m = { player = player, pn = playerNum, sw = sw, marked = {}, cand = {}, pick = {} }
    Wiring.mode = m
    local ok, err = pcall(buildPanel, m, UI)
    if not ok then
        print(LOG .. "wiring panel failed: " .. tostring(err))
        Wiring.close()
        return false
    end
    m.cursor = newCursor(m)
    getCell():setDrag(m.cursor, playerNum)
    Wiring.refresh(m)
    return Wiring.mode == m
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

-- 本工具的開關、或接得上的燈（本工具蓋的、能搬的）；招牌不算開關（Rules.switchProps）
local function kindOf(o)
    if not instanceof(o, "IsoLightSwitch") then return nil end
    local lit, p = lightR(o)
    if not p then return nil end
    if not lit then return ours(o) and B.Rules.switchProps(p) and "s" or nil end
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
-- 打開接線模式（開第一個開關的）。原版選單關掉後選項表會收回重用（ISContextMenu.lua:849-856 清空、:1088-1092 收回、
-- :1199-1215 子選單也重用）：送出前在三個選項上都記請求編號，回覆到時三個的編號都對、而且都還在子選單裡才改
local function lampMenu(context, playerNum, player, o, label)
    local opt = context:addOption(label)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(opt, sub)
    local info = sub:addOption(getText("IGUI_MBLD_Wire_Loading"))
    local st = {}
    local unplug = sub:addOption(getText("IGUI_MBLD_Menu_Unplug"), playerNum, Wiring.unplug, o)
    local open = sub:addOption(getText("IGUI_MBLD_Menu_OpenWiring"), playerNum, Wiring.openFromLamp, st)
    info.notAvailable, unplug.notAvailable, open.notAvailable = true, true, true
    local q = lastQ % 2000000000 + 1
    local mine = { info, unplug, open }
    for _, it in ipairs(mine) do it.mbldQ = q end
    local function current()
        local inSub = {}
        for _, it in ipairs(sub.options or {}) do inSub[it] = true end
        for _, it in ipairs(mine) do
            if it.mbldQ ~= q or not inSub[it] then return false end
        end
        return true
    end
    Wiring.send(player, "circuit", at(o), function(r)
        if not current() then return end
        if r.code == "RATE_LIMITED" then
            info.name = getText("IGUI_MBLD_Menu_Retry")
        elseif r.code then
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
-- ISWorldObjectContextMenu.lua:1226-1236）。選了照原版走過去、排 ISToggleLightAction，伺服器照線路或原版處理。
-- 同一格有好幾個時，選項名稱後面加物件名稱分得出來
local function toggleMenu(context, worldobjects, playerNum, o, named)
    local sq = o:getSquare()
    if (sq:getRoom() ~= nil or o:getCanBeModified()) and o:canSwitchLight() then return end
    local label = getText(o:isActivated() and "ContextMenu_Turn_Off" or "ContextMenu_Turn_On")
    if named then label = getText("IGUI_MBLD_Menu_Named", label, Names.of(o:getSprite():getName(), "light")) end
    context:addOption(label, worldobjects, ISWorldObjectContextMenu.onToggleLight, o, playerNum)
end

function Wiring.fill(playerNum, context, worldobjects, test)
    local player = getSpecificPlayer(playerNum)
    if not player or player:getVehicle() then return end
    -- 管理員關掉了：伺服器只拒接線，不列接線與線路；開燈／關燈照列（按開關不看這個設定）
    local wiring = B.Check.setting("Enabled", true) ~= false
    local found, done = {}, {}
    for _, w in ipairs(worldobjects) do
        local sq = w:getSquare()
        if sq and not done[sq] then
            done[sq] = true
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do
                local o = objs:get(i)
                local k = kindOf(o)
                if k and (wiring or ours(o)) then found[#found + 1] = { o = o, k = k } end
            end
        end
    end
    if #found == 0 then return end
    if test then return ISWorldObjectContextMenu.setTest() end -- 手把：有選項就回報（ISWorldObjectContextMenu.lua:122-125）
    local many = #found > 1
    for _, f in ipairs(found) do
        local name = many and Names.of(f.o:getSprite():getName(), "light") or nil
        if wiring and f.k == "s" then
            local label = getText("IGUI_MBLD_Menu_Wire")
            if name then label = getText("IGUI_MBLD_Menu_Named", label, name) end
            context:addOption(label, playerNum, Wiring.openFromMenu, f.o)
        elseif wiring then
            local label = getText("IGUI_MBLD_Menu_Circuit")
            if name then label = getText("IGUI_MBLD_Menu_Named", label, name) end
            lampMenu(context, playerNum, player, f.o, label)
        end
        if ours(f.o) then toggleMenu(context, worldobjects, playerNum, f.o, many) end
    end
end

Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, worldobjects, test)
    return MinidoracatBuilder.Wiring.fill(playerNum, context, worldobjects, test)
end)

return Wiring
