-- 快選列：放置中（本工具的建造游標或建造配方開的游標）畫面下方一條，第一排最近用的（Recent），第二排目前項目的同一套
-- （Window.setOf），點一格游標不收、換成那一項（Window.swapTo）。沒有游標時不建元件：游標開時 Hotbar.show，關時
-- Hotbar.hide 收掉整個視窗（Cursor:deactivate、Window.onCursorEnd 呼叫；漏掉時下一幀自己發現沒有游標也收）。
-- 框架 Window：一顯示就搶手把焦點（Widgets/Window.lua:331-352 的 onShown），這裡的游標要留著手把（A 蓋、B 取消），
-- 所以實例上換回原版的 setVisible／addToUIManager；手把玩家在游標上按右搖桿（Cursor:onJoypadPressButton）才把焦點交給
-- 快選列，A 換項目、B 交回游標。只服務一位玩家（最後開游標的那位）。
-- 收合：標題列按一下（沒拖動）或手把在快選列上再按右搖桿，收成只剩標題列（標題寫目前項目）；狀態記在本機檔
-- Hotbar.FILE（跨存檔、跨伺服器同一個），第一次顯示才讀。框架 Window 沒有收合介面（只有防禦性的 isCollapsed），
-- 所以這裡自己調高度、隱藏兩排。
MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local Hotbar = B.Hotbar or {}
B.Hotbar = Hotbar

local PAD, GAP = 8, 4
local LOG = "[MinidoracatBuilderFor42] "
Hotbar.COLS = 10 -- 一排看得到幾格；多的用滾輪（或焦點移動）捲
Hotbar.FILE = "MinidoracatBuilder/hotbar.txt" -- 一行 0（展開）或 1（收合）；讀不到當 0

local hb -- 顯示中的快選列：{ win, pn, UI, fh, theme, colors, tex, label, rowY, rowOn, nRecent, set, cur, title, grids, under }
local folded -- 收合中；nil＝還沒讀檔

-- getFileReader／getFileWriter 的路徑相對 Zomboid/Lua，寫入時自動建資料夾（同 Window.lua 的一排幾格設定檔）
local function readFolded()
    local r = getFileReader(Hotbar.FILE, false)
    if not r then return nil end
    local line = r:readLine()
    r:close()
    return line
end

local function writeFolded(v)
    local w = getFileWriter(Hotbar.FILE, true, false)
    w:write(v .. "\n")
    w:close()
end

-- 存收合狀態：引擎的 writer 吞掉寫入錯誤（LuaManager.java:6706-6719），所以寫完讀回比對；不一致只記 log，
-- 畫面照這次切的（只是個偏好，下次進遊戲可能回到上次存到的狀態）
local function saveFolded()
    local v = folded and "1" or "0"
    local okW = pcall(writeFolded, v)
    local okR, line = pcall(readFolded)
    if okW and okR and type(line) == "string" and line:match("^%s*(%d)%s*$") == v then return end
    print(LOG .. "hotbar state not saved to " .. Hotbar.FILE)
end

function Hotbar.collapsed()
    if folded == nil then
        local ok, line = pcall(readFolded)
        folded = ok and type(line) == "string" and line:match("^%s*1%s*$") ~= nil
    end
    return folded
end

-- 這位玩家目前在放的項目：本工具的建造游標（一區拆除、吸管不算）或建造配方開的游標（Window 開它時記 mbldId）
function Hotbar.current(pn)
    local C = B.Cursor
    local c = C and C.get(pn)
    if c then return not c.area and c.name or nil end
    local R = B.Recipes
    local r = R and R.cursor(pn)
    return r and r.mbldId or nil
end

local function texOf(name)
    local t = hb.tex[name]
    if t == nil then
        local R = B.Recipes
        local r = R and R.byId[name]
        if r then
            t = R.icon(r)
        else
            t = getTexture(name)
            if t then t = t:splitIcon() end
        end
        t = t or false
        hb.tex[name] = t
    end
    return t or nil
end

local function nameOf(name)
    local R = B.Recipes
    local r = R and R.byId[name]
    return r and r.name or (B.Names and B.Names.of(name)) or name
end

-- 格子：縮圖＋一行名稱（截好的字記著，不在每幀配置）
local function drawTile(_, el, name, x, y, w, h)
    if not hb then return end -- 這一幀在 prerender 收掉（pump）之後，格子還會畫完這一幀
    local c = hb.colors
    local tex = texOf(name)
    local iconH = h - hb.fh - 10
    if tex then el:drawTextureScaledAspect(tex, x + 3, y + 3, w - 6, iconH, 1, 1, 1, 1) end
    local s = hb.label[name]
    if s == nil then
        s = hb.UI.Text.fit(nameOf(name), w - 4, UIFont.Small)
        hb.label[name] = s
    end
    el:drawTextCentre(s, x + math.floor(w / 2), y + h - hb.fh - 4, c.text.r, c.text.g, c.text.b, 1, UIFont.Small)
end

local function pick(_, name)
    if not hb then return end
    local pn, W = hb.pn, B.Window
    if W and W.swapTo then W.swapTo(pn, name) end
    local F = hb and hb.UI.Focus
    if F and F.releaseJoypad then F.releaseJoypad(hb.win) end -- 手把：換好就交回游標
end

-- 能列的才列：解析得了的圖塊項目、這位玩家看得到的配方項目
local function usable(name)
    local R = B.Recipes
    if R and R.byId[name] then return R.get(name) ~= nil end
    local e = B.Entry.resolve(name)
    return e ~= nil and e ~= false
end

local function filtered(src)
    local out = {}
    for i = 1, src and src.n or 0 do
        if usable(src[i]) then out[#out + 1] = src[i] end
    end
    return out
end

local function select(grid, name)
    local items = grid:getItems()
    for i = 1, #items do
        if items[i] == name then
            grid:setSelectedIndex(i)
            grid:scrollToIndex(i)
            return
        end
    end
    grid:setSelectedIndex(nil)
end

local function newGrid(UI, x, y, w, h, tileW)
    local g = UI.TileGrid.new({ x = x, y = y, width = w, height = h, tileW = tileW, tileH = h, theme = hb.theme,
        label = getText("IGUI_MBLD_Hotbar_Title"), drawTile = drawTile, onPick = pick,
        tooltip = function(_, name) return nameOf(name) end })
    hb.win:addChild(g)
    return g
end

-- 排版：第一排只在最近用的有東西時排、第二排只在目前項目有同一套時排，收合時兩排都不排；一排都沒有就只剩標題列。
-- 視窗高照排數，下緣不動（第一次貼在原版快捷列上面，玩家拖過就照拖到的位置）。
-- 底層面板（under）收合時高 0 但不隱藏：每幀的檢查（pump）掛在它的 prerender，隱藏的元件不呼叫 prerender
-- （UIElement.java:1603-1624）；框架 Window 沒關 renderClippedChildren，跑出視窗外的子元件照樣呼叫（:1607）
local function layout()
    local win, fh = hb.win, hb.fh
    local top = win:contentTop()
    local fold = Hotbar.collapsed()
    local y = top + GAP
    local rows = hb.grids
    for i = 1, 2 do
        local g = rows[i]
        local on = not fold and (i == 1 and hb.nRecent > 0 or i == 2 and hb.set ~= nil)
        hb.rowOn[i] = on
        g:setVisible(on)
        if on then
            hb.rowY[i] = y - top -- 標籤畫在 under 面板上（從 contentTop 起）
            g:setY(y + fh + 2)
            y = y + fh + 2 + g.height + GAP
        end
    end
    local pn = hb.pn
    local bottom = hb.placed and win:getY() + win.height
    if not bottom then
        local bar = getPlayerHotbar and getPlayerHotbar(pn)
        bottom = (bar and bar:getIsVisible() and bar:getY() or getPlayerScreenTop(pn) + getPlayerScreenHeight(pn)) - 8
        hb.placed = true
    end
    win:setHeight(y > top + GAP and y + PAD - GAP or top)
    win:setY(math.max(getPlayerScreenTop(pn), bottom - win.height))
    hb.under:setHeight(win.height - top)
    local title = hb.titleText
    if fold then
        title = hb.UI.Text.fit(getText("IGUI_MBLD_Hotbar_Collapsed", nameOf(hb.cur)), win.width - 2 * PAD - 24, UIFont.Small)
    end
    if title ~= hb.title then
        hb.title = title
        win:setTitle(title)
    end
end

-- 收合／展開（標題列按一下、手把右搖桿）。記進 Hotbar.FILE；快選列開著就馬上重排。回收合了沒有
function Hotbar.toggle()
    folded = not Hotbar.collapsed()
    saveFolded()
    if hb then layout() end
    return folded
end

-- 兩排的內容照目前項目重排（最近用的變了、換了項目）
function Hotbar.refresh()
    if not hb then return end
    local cur = Hotbar.current(hb.pn)
    if not cur then return Hotbar.hide() end
    hb.cur = cur
    local R = B.Recent
    local recent = filtered(R and R.list())
    hb.nRecent = #recent
    hb.grids[1]:setItems(recent)
    select(hb.grids[1], cur)
    local W = B.Window
    local set = W and W.setOf and W.setOf(cur)
    hb.set = set
    if set then
        hb.grids[2]:setItems(filtered(set.list))
        select(hb.grids[2], cur)
        hb.setText = hb.UI.Text.fit(set.chip, hb.win.width - 2 * PAD, UIFont.Small)
    else
        hb.grids[2]:setItems({})
    end
    layout()
    local F = hb.UI.Focus
    if F and F.invalidate then F.invalidate(hb.win) end
end

-- 每幀（底層面板的 prerender）：游標沒了就收；項目換了就重排。只比字串，不配置
local function pump()
    if not hb then return end
    local cur = Hotbar.current(hb.pn)
    if cur ~= hb.cur then
        if cur then Hotbar.refresh() else Hotbar.hide() end
    end
end

local function drawLabels(self)
    if not hb then return end
    local c = hb.colors.textMuted
    if hb.rowOn[1] then self:drawText(hb.recentText, PAD, hb.rowY[1], c.r, c.g, c.b, 1, UIFont.Small) end
    if hb.rowOn[2] then self:drawText(hb.setText, PAD, hb.rowY[2], c.r, c.g, c.b, 1, UIFont.Small) end
end

function Hotbar.show(playerNum)
    local pn = playerNum or 0
    if hb and hb.pn ~= pn then Hotbar.hide() end
    if hb then return Hotbar.refresh() end
    local W = B.Window
    local UI = W and W.ui and W.ui({ "window", "tileGrid", "textWrap" })
    if not UI or not Hotbar.current(pn) then return end
    local fh = getTextManager():getFontHeight(UIFont.Small)
    local s = fh / 16
    local tileW = math.floor(64 * s)
    local tileH = 6 + math.floor(40 * s) + 4 + fh + 4
    local w = Hotbar.COLS * tileW + 12 + 2 * PAD
    local theme = UI.Theme.create({ variant = "dark" })
    local sx, sw = getPlayerScreenLeft(pn), getPlayerScreenWidth(pn)
    local title = getText("IGUI_MBLD_Hotbar_Title")
    local opts = { x = sx + math.floor((sw - w) / 2), y = 0, width = w, height = 100, title = title,
        icon = "clock", theme = theme, closable = false }
    if UI.CAPABILITIES.opaqueWindow == true then opts.opaque = true end
    local win = UI.Window.new(opts)
    -- 不搶手把（見檔頭）
    win.setVisible, win.addToUIManager = ISPanel.setVisible, ISPanel.addToUIManager
    win.onEscape = function(self)
        local F = UI.Focus
        if F then
            F.releaseJoypad(self)
            F.clear(self)
        end
        return true
    end
    -- 標題列按一下收合／展開：按下時記視窗在哪，放開時沒動才算（拖動照框架移動視窗，放開在視窗外不會進 onMouseUp）
    local downX, downY
    local down, up, joy = win.onMouseDown, win.onMouseUp, win.onJoypadDown
    win.onMouseDown = function(self, x, y)
        downX, downY = nil, nil
        if y < self:contentTop() then downX, downY = self:getX(), self:getY() end
        return down(self, x, y)
    end
    win.onMouseUp = function(self, x, y)
        local r = up(self, x, y)
        if downX and y < self:contentTop() and self:getX() == downX and self:getY() == downY and hb and hb.win == self then
            Hotbar.toggle()
        end
        downX, downY = nil, nil
        return r
    end
    -- 手把：焦點在快選列時再按右搖桿＝收合並把焦點交回游標；其他鍵照框架
    win.onJoypadDown = function(self, button, joypadData)
        if Joypad and button == Joypad.RStickButton then
            if not Hotbar.collapsed() then Hotbar.toggle() end
            local F = UI.Focus
            if F and F.releaseJoypad then F.releaseJoypad(self) end
            return
        end
        if joy then return joy(self, button, joypadData) end
    end
    hb = { win = win, pn = pn, UI = UI, fh = fh, theme = theme, colors = theme.colors, tex = {}, label = {}, rowY = {},
        rowOn = {}, nRecent = 0, title = title, titleText = title, recentText = getText("IGUI_MBLD_Cat_Recent") }
    -- 標題列以下：畫兩排的標題，prerender 是每幀的檢查（pump）。從 contentTop 起，不蓋住標題列（拖曳移動）
    local under = ISPanel:new(0, win:contentTop(), w, 10)
    under:initialise()
    under.background = false
    under.prerender = pump
    under.render = drawLabels
    win:addChild(under)
    hb.under = under
    hb.grids = { newGrid(UI, PAD, 0, w - 2 * PAD, tileH, tileW), newGrid(UI, PAD, 0, w - 2 * PAD, tileH, tileW) }
    win:addToUIManager()
    Hotbar.refresh()
end

function Hotbar.hide()
    local h = hb
    if not h then return end
    hb = nil
    local F = h.UI.Focus
    if F then
        if F.releaseJoypad then F.releaseJoypad(h.win) end
        if F.clear then F.clear(h.win) end
    end
    h.win:setVisible(false)
    h.win:removeFromUIManager()
end

-- 手把：把焦點交給快選列（Cursor 的右搖桿按下）；收合中先展開
function Hotbar.focus(playerNum)
    if not hb or hb.pn ~= playerNum then return end
    if Hotbar.collapsed() then Hotbar.toggle() end
    local F = hb.UI.Focus
    if F and F.takeJoypad then F.takeJoypad(hb.win, playerNum) end
end

function Hotbar.visible()
    return hb ~= nil
end

return Hotbar
