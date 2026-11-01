-- 一區拆除（設計稿 claim 3，使用者 2026-11-01 選「本工具拆的＋原版拆解的」）：右鍵「拆除一區...（建造工坊）」→
-- 拖長方形（Cursor.startArea，只用滑鼠）→ 放開跳確認面板（照頁籤分種類勾選）→ 一張清單送出（Client.dismantleMany）→
-- 輪完或停下跳總結通知。範圍是玩家那一層，另收正上方那層的屋頂（從屋裡框地板拆得到頭上那片，同 Menu.targets）。
-- 這裡的判斷只給畫面用：能不能拆、退什麼料由伺服器照清單一件一件重查（Server.dismantle）；原版拆解照原版動作自己查。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Rules"
require "MinidoracatBuilder/Cost"
require "MinidoracatBuilder/Dismantle"
require "MinidoracatBuilder/Names"
require "MinidoracatBuilder/Messages"
require "MinidoracatBuilder/Client"

local B = MinidoracatBuilder
local Area = B.Area or {}
B.Area = Area
local Entry, Rules, Cost, Dismantle = B.Entry, B.Rules, B.Cost, B.Dismantle
local Names, Messages, Client = B.Names, B.Messages, B.Client

local LOG = "[MinidoracatBuilderFor42] "
local PAD, GAP = 8, 6
local PREVIEW_MS = 500 -- 同一個範圍的預覽多久重算一次（世界變了也看得到；游標每幀都問）

-- 拆的順序（設計稿 3.4）：先拆掛在上面的，再拆家具、牆，最後拆屋頂、地板；同一順位由上層往下。
-- 二樓地板上有東西時不給拆（FLOOR_IN_USE），照這個順序拆到它時上面已經空了。表外的種類算 2
local ORDER = {
    floorOverlay = 1, wallOverlay = 1, wallObject = 1, windowObject = 1, attached = 1, overlay = 1,
    furniture = 2, container = 2, solid = 2, light = 2,
    wall = 3, fence = 3, post = 3, doorFrame = 3, windowFrame = 3,
    stairs = 4, roof = 5, floor = 6,
}
Area.ORDER = ORDER

-- 本 MOD 蓋的這件怎麼拆（照 Cost.refund）：回 route, kind 或 nil（地圖原有的、原版蓋的不碰）。
--   builder＝本工具拆（Dismantle.kindOf）；scrap＝原版拆解；pickup＝能搬，要原版撿起；none＝只能大錘砸；sheet＝原版移除窗簾。
-- 門、窗簾是 IsoDoor／IsoCurtain（Place.build），不是 Dismantle.ours 認的物件，照 builderEntry 記號認：只拿來列在選單與
-- 面板上（說明該用原版哪個動作），不拆，記號被改了也沒關係
function Area.route(obj)
    local kind = Dismantle.kindOf(obj)
    if kind then return "builder", kind end
    if not (Dismantle.ours(obj) or ((instanceof(obj, "IsoDoor") or instanceof(obj, "IsoCurtain"))
        and obj:hasModData() and obj:getModData().builderEntry)) then
        return nil
    end
    local spr = obj:getSprite()
    local k = spr and Rules.classify(spr)
    if not k then return nil end
    return Cost.refund(k, spr), k
end

-- sq 上本 MOD 蓋的每一件 → out：{ obj 或 overlay, kind, route, name＝sprite 名稱, plan（builder 才有） }。
-- 同一件（多格、樓梯三片）只收一次（seen）。roof＝true：正上方那層，只收本工具拆的屋頂
function Area.scan(sq, seen, out, roof)
    if not sq then return end
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        if not seen[o] then
            local route, kind = Area.route(o)
            if route and (not roof or (route == "builder" and kind == "roof")) then
                local t = { obj = o, kind = kind, route = route, name = o:getSprite():getName() }
                if route == "builder" then
                    t.plan = Dismantle.plan(o, kind)
                    for _, p in ipairs(t.plan.remove) do seen[p] = true end
                else
                    local grid = o:getSpriteGridObjectsIncludingSelf(ArrayList.new())
                    for j = 0, grid:size() - 1 do seen[grid:get(j)] = true end
                end
                seen[o] = true
                out[#out + 1] = t
            end
        end
    end
    if roof then return end
    for _, ov in ipairs(Dismantle.overlays(sq)) do
        out[#out + 1] = { overlay = ov, kind = "floorOverlay", route = "builder", plan = Dismantle.overlayPlan(ov),
            name = ov.name }
    end
end

-- 原版拆解現在能不能拆（同 ISDisassembleMenu.createMenu／disassemble：多格的要整組在，canScrapObject 照原版工具、
-- 容器、門窗、樓梯頂查）。回 nil 或碼：NOT_EMPTY（容器不空）、NO_TOOL（缺原版拆解的工具）、SCRAP（其他原因）
local function scrapCode(player, o)
    local props = ISMoveableSpriteProps.fromObject(o)
    if not props then return "SCRAP" end
    if props.isMultiSprite and not props:getSpriteGridInfo(o:getSquare(), true) then return "SCRAP" end
    local res = props:canScrapObject(player)
    if res.canScrap then return nil end
    if res.containerFull then return "NOT_EMPTY" end
    if res.haveTool == false or res.haveTool2 == false then return "NO_TOOL" end
    return "SCRAP"
end

-- 種類 → 建造視窗的頁籤（W.TAB_KINDS，不含「全部」）。視窗沒載入（離線測試）時一律「全部」
local tabOfKind
local function tabOf(kind)
    local W = B.Window
    if not (W and W.TAB_KINDS) then return "all" end
    if not tabOfKind then
        tabOfKind = {}
        for i = 2, #W.TABS do
            for _, k in ipairs(W.TAB_KINDS[W.TABS[i]]) do tabOfKind[k] = W.TABS[i] end
        end
    end
    return tabOfKind[kind] or "all"
end

-- 這件會送出去拆（本工具拆或原版拆解、預覽沒擋）
local function sendable(t)
    return not t.code and (t.route == "builder" or t.route == "scrap")
end
Area.sendable = sendable

-- 範圍內（玩家那一層，含正上方那層的屋頂）本 MOD 蓋的每一件，照 ORDER 與 z 由上往下排（同一順位照掃到的順序；
-- 照順位、層分桶再接起來，不用 table.sort，家族規則）。每件另有 x, y, z（那件所在的格子）、tab、code／extra（預覽就知道
-- 拆不了的：builder 照 Dismantle.check 的 preview，scrap 照原版 canScrapObject）。
-- limit：照順序查到這麼多件能送的就停，後面的不查（反正一次只送前 limit 件；游標拖曳時每秒重算，大範圍不必每件都查）
function Area.collect(x1, y1, x2, y2, z, player, limit)
    if x1 > x2 then x1, x2 = x2, x1 end
    if y1 > y2 then y1, y2 = y2, y1 end
    local cell, seen, found = getCell(), {}, {}
    for x = x1, x2 do
        for y = y1, y2 do
            Area.scan(cell:getGridSquare(x, y, z), seen, found, false)
            Area.scan(cell:getGridSquare(x, y, z + 1), seen, found, true)
        end
    end
    local buckets = {} -- [順位 * 2 + (上一層 0／這一層 1)] = 件
    for _, t in ipairs(found) do
        local sq = t.overlay and t.overlay.sq or t.obj:getSquare()
        t.x, t.y, t.z = sq:getX(), sq:getY(), sq:getZ()
        t.tab = tabOf(t.kind)
        local b = (ORDER[t.kind] or 2) * 2 + (t.z > z and 0 or 1)
        local bucket = buckets[b]
        if not bucket then
            bucket = {}
            buckets[b] = bucket
        end
        bucket[#bucket + 1] = t
    end
    local list, ok = {}, 0
    for b = 2, 13 do
        for _, t in ipairs(buckets[b] or {}) do
            if not limit or ok < limit then
                if t.route == "builder" then
                    t.code, t.extra = Dismantle.check(player, t.kind, t.plan, true)
                elseif t.route == "scrap" then
                    t.code = scrapCode(player, t.obj)
                end
                if sendable(t) then ok = ok + 1 end
            end
            list[#list + 1] = t
        end
    end
    return list
end

-- 確認面板的數字。on＝{ [頁籤] = 勾著 }。回 { tabs＝每個頁籤勾了幾件, all＝每個頁籤能拆幾件（不看勾選）,
-- n＝勾了幾件, skip＝{ [碼] = 件數 }（預覽就擋下的）, scrap＝能拆的件裡幾件照原版拆解, pickup, smash（只能大錘砸、
-- 原版移除窗簾） }。退多少要拆了才知道（一樓地板、燈的退料只在伺服器帳本），面板不估，拆完的通知才寫實際退了什麼
function Area.summary(list, on)
    local s = { tabs = {}, all = {}, n = 0, skip = {}, scrap = 0, pickup = 0, smash = 0 }
    for _, t in ipairs(list) do
        if t.code then
            s.skip[t.code] = (s.skip[t.code] or 0) + 1
        elseif sendable(t) then
            s.all[t.tab] = (s.all[t.tab] or 0) + 1
            if t.route == "scrap" then s.scrap = s.scrap + 1 end
            if on[t.tab] then
                s.tabs[t.tab] = (s.tabs[t.tab] or 0) + 1
                s.n = s.n + 1
            end
        elseif t.route == "pickup" then
            s.pickup = s.pickup + 1
        else
            s.smash = s.smash + 1
        end
    end
    return s
end

local function maxItems()
    return math.max(1, math.floor(tonumber(Entry.settings().MaxCellsPerDrag) or 32))
end

-- 送給 Client.dismantleMany 的一件（C6）。t＝Area.scan／Menu.targets 的一項
function Area.item(t)
    local sq = t.overlay and t.overlay.sq or t.obj:getSquare()
    local own = {}
    for i, o in ipairs(t.plan and t.plan.remove or {}) do own[i] = o:getSquare() end
    return { x = sq:getX(), y = sq:getY(), z = sq:getZ(), name = t.name, kind = t.kind,
        north = t.obj and Entry.north(t.kind, t.obj:getSprite()) or nil, own = own, route = t.route, obj = t.obj }
end

-- ---------------------------------------------------------------- 游標預覽

-- 一件佔的格子：本工具拆的照 plan.remove 每一片，地面覆蓋那一格，其他那件所在的格子
local function eachCell(t, fn)
    if t.plan and #t.plan.remove > 0 then
        for _, o in ipairs(t.plan.remove) do
            local sq = o:getSquare()
            if sq then fn(sq:getX(), sq:getY(), sq:getZ()) end
        end
    else
        fn(t.x, t.y, t.z)
    end
end

local cache = { key = nil, at = 0, out = nil }

-- Cursor.startArea 的 preview：要拆的格子（bad＝false，游標畫紅）與只有拆不了、不拆的東西的格子（bad＝true），標籤三行
function Area.preview(player, x1, y1, x2, y2, z)
    local key = x1 .. "," .. y1 .. "," .. x2 .. "," .. y2 .. "," .. z
    local now = getTimestampMs()
    if cache.key == key and now - cache.at < PREVIEW_MS then return cache.out end
    local max = maxItems()
    local list = Area.collect(x1, y1, x2, y2, z, player, max)
    local cells, at, go = {}, {}, 0
    for _, t in ipairs(list) do
        local send = sendable(t) and go < max
        if send then go = go + 1 end
        eachCell(t, function(x, y, cz)
            local k = x .. "," .. y .. "," .. cz
            local c = at[k]
            if not c then
                c = { x = x, y = y, z = cz, bad = not send }
                at[k] = c
                cells[#cells + 1] = c
            elseif send then
                c.bad = false
            end
        end)
    end
    local sep = getText("IGUI_MBLD_HintSep")
    local out = { cells = cells, lines = {
        getText("IGUI_MBLD_Area_Label", tostring(math.abs(x2 - x1) + 1), tostring(math.abs(y2 - y1) + 1)),
        getText("IGUI_MBLD_Area_Count", tostring(go), tostring(#list - go)),
        getText("IGUI_MBLD_Area_HintRelease") .. sep .. getText("IGUI_MBLD_HintCancel"),
    } }
    cache.key, cache.at, cache.out = key, now, out
    return out
end

-- 右鍵「拆除一區...（建造工坊）」：開長方形游標（Cursor.startArea，C7），放開跳確認面板
function Area.start(playerNum)
    local Cursor = B.Cursor
    local player = getSpecificPlayer(playerNum)
    if not (Cursor and Cursor.startArea and player) then return end
    cache.key = nil
    Cursor.startArea(playerNum, {
        preview = function(x1, y1, x2, y2, z) return Area.preview(player, x1, y1, x2, y2, z) end,
        release = function(x1, y1, x2, y2, z)
            cache.key = nil
            Area.confirm(playerNum, Area.collect(x1, y1, x2, y2, z, player),
                math.abs(x2 - x1) + 1, math.abs(y2 - y1) + 1)
        end,
        cancel = function() cache.key = nil end,
    })
end

-- ---------------------------------------------------------------- 送出與總結

-- 照清單順序取勾著的、能送的，最多 MaxCellsPerDrag 件
function Area.pick(list, on, max)
    local items = {}
    for _, t in ipairs(list) do
        if #items >= max then break end
        if sendable(t) and on[t.tab] then items[#items + 1] = Area.item(t) end
    end
    return items
end

-- 送出並在輪完或停下時跳總結。kept＝面板上就擋下的（照碼數件數），併進通知的「留著 K 件：原因 數」
function Area.send(player, items, kept)
    local one = #items == 1 and Names.of(items[1].name, items[1].kind) or nil
    Client.dismantleMany(player, items, function(summary)
        -- 一件都還沒拆就整批被拒：Client 已經跳了拒絕原因；拆到一半才被拒照停下跳總結（拆了幾件、退了什麼）
        if summary.refused and (summary.done or 0) == 0 then return end
        -- 只拆一件、被安全屋擋（PERM_DENIED）：Safehouse 自己推了通知（同 Client 的 tell）
        if summary.total == 1 and not summary.stopped and summary.done == 0 and (summary.skipped or {}).PERM_DENIED then return end
        local s = summary
        if (summary.total or 0) > 1 or summary.stopped then
            local skipped = {}
            for code, n in pairs(kept or {}) do skipped[code] = n end
            for code, n in pairs(summary.skipped or {}) do skipped[code] = (skipped[code] or 0) + n end
            s = { done = summary.done, total = summary.total, refund = summary.refund, stopped = summary.stopped,
                skipped = skipped }
        end
        local text, title = Messages.unbuildSummary(s, one)
        if summary.stopped then text = text .. " " .. getText("IGUI_MBLD_Area_Again") end
        Messages.toast(player, text, title)
    end)
end

-- ---------------------------------------------------------------- 確認面板（框架 Window＋勾選框，同管理面板寫法）

local Panel = {}
Panel.__index = Panel

function Panel:refresh()
    local s = Area.summary(self.list, self.on)
    local send = math.min(s.n, self.max)
    self.over = s.n > self.max
    self.goBtn:setTitle(getText("IGUI_MBLD_Area_Go", tostring(send)))
    self.goBtn:setEnabled(send > 0)
end

function Panel:go()
    local items = Area.pick(self.list, self.on, self.max)
    if #items == 0 then return end
    self.win:close()
    Area.send(getSpecificPlayer(self.playerNum), items, self.skip)
end

local function discard(p)
    if Area.panel == p then Area.panel = nil end
    if p and p.win then
        pcall(function()
            p.win:setVisible(false)
            p.win:removeFromUIManager()
        end)
    end
end

function Panel.new(UI, playerNum, list, cw, ch)
    local theme = UI.Theme.create({ variant = "dark" })
    local c = theme.colors
    local font = UIFont.Small
    local tm = getTextManager()
    local fh = tm:getFontHeight(font)
    local s = fh / 16 -- 字級比例（同 Window.lua 的 W.create）
    local self = setmetatable({ UI = UI, playerNum = playerNum, list = list, on = {}, max = maxItems(), over = false },
        Panel)
    local W = B.Window
    for _, tab in ipairs(W.TABS) do self.on[tab] = true end
    local sum = Area.summary(list, self.on)
    self.skip = sum.skip
    -- 用該玩家的畫面範圍（分割畫面；同 Admin.lua）
    local sx, sy = getPlayerScreenLeft(playerNum), getPlayerScreenTop(playerNum)
    local sw, sh = getPlayerScreenWidth(playerNum), getPlayerScreenHeight(playerNum)
    local w = math.min(sw - 40, math.floor(380 * s))
    local innerW = w - 2 * PAD
    -- 內文與勾選框的位置（相對內文面板頂端）；字只在這裡組，render 只畫
    local rows, boxes, y = {}, {}, 0
    local function para(text, color, flag)
        local lines = UI.Text.wrap(text, innerW, font) -- 框架快取，只讀
        for i = 1, #lines do
            rows[#rows + 1] = { s = lines[i], y = y, c = color, over = flag }
            y = y + fh
        end
    end
    para(getText("IGUI_MBLD_Area_Intro", tostring(cw), tostring(ch), tostring(#list)), c.textMuted)
    y = y + GAP
    local listed = 0
    for i = 2, #W.TABS do
        local tab = W.TABS[i]
        local n = sum.all[tab]
        if n then
            local box = UI.Checkbox.new({ x = PAD, y = y, width = innerW, theme = theme, font = font, checked = true,
                label = getText("IGUI_MBLD_Count", getText("IGUI_MBLD_Tab_" .. tab), tostring(n)), target = self,
                onChange = function(p, checked)
                    p.on[tab] = checked == true
                    p:refresh()
                end })
            boxes[#boxes + 1] = box
            y = y + box.height
            listed = listed + n
        end
    end
    y = y + GAP
    local nSkip = 0
    for _, n in pairs(sum.skip) do nSkip = nSkip + n end
    if nSkip > 0 then para(getText("IGUI_MBLD_Area_Skipped", tostring(nSkip), Messages.skipped(sum.skip)), c.warning) end
    if sum.scrap > 0 then para(getText("IGUI_MBLD_Area_Scrap", tostring(sum.scrap)), c.textMuted) end
    if sum.pickup > 0 then para(getText("IGUI_MBLD_Area_Pickup", tostring(sum.pickup)), c.textMuted) end
    if sum.smash > 0 then para(getText("IGUI_MBLD_Area_Smash", tostring(sum.smash)), c.textMuted) end
    if listed > 0 then para(getText("IGUI_MBLD_Unbuild_RefundTip"), c.textMuted) end
    if listed > self.max then para(getText("IGUI_MBLD_Area_Over", tostring(self.max)), c.warning, true) end
    -- 按鈕寬照最長的標題（全勾、取到上限時）定死：setTitle 不重算明示的寬度（ui.md 已知坑）
    local btnH = fh + 10
    local goTitle = getText("IGUI_MBLD_Area_Go", tostring(math.min(listed, self.max)))
    local goW = tm:MeasureStringX(font, goTitle) + 20
    -- 先建視窗才知道標題列高：內文從 contentTop 起，高度建好再設
    local win = UI.Window.new({ x = 0, y = 0, width = w, height = 100, title = getText("IGUI_MBLD_Area_Title"),
        theme = theme, opaque = true, onClose = function() discard(self) end })
    win.onEscape = function()
        win:close()
        return true
    end
    self.win = win
    Area.panel = self -- 建到一半出錯時 Area.confirm 收得到
    local top = win:contentTop() + GAP
    local h = math.min(sh - 40, top + y + GAP + btnH + PAD)
    win:setHeight(h)
    win:setX(sx + math.floor((sw - w) / 2))
    win:setY(sy + math.floor((sh - h) / 2))
    local body = ISPanel:new(0, top, w, y) -- 先加：畫在勾選框底下
    body:initialise()
    body.background = false
    body.render = function(el)
        for i = 1, #rows do
            local r = rows[i]
            if not r.over or self.over then
                el:drawText(r.s, PAD, r.y, r.c.r, r.c.g, r.c.b, r.c.a or 1, font)
            end
        end
    end
    win:addChild(body)
    for _, box in ipairs(boxes) do
        box:setY(top + box:getY())
        win:addChild(box)
    end
    local by = h - PAD - btnH
    self.goBtn = UI.Button.new({ x = w - PAD - goW, y = by, width = goW, height = btnH, title = goTitle, style = "danger",
        theme = theme, font = font, target = self, onClick = function(p) p:go() end })
    local cancel = UI.Button.new({ x = 0, y = by, height = btnH, title = getText("UI_Cancel"), theme = theme, font = font,
        onClick = function() win:close() end })
    cancel:setX(self.goBtn:getX() - GAP - cancel.width)
    win:addChild(cancel)
    win:addChild(self.goBtn)
    self:refresh()
    win:addToUIManager()
    return self
end

-- 放開長方形後：範圍裡沒有本 MOD 蓋的東西就只說一聲；有就開確認面板（同時只開一個，新的取代舊的）。
-- cw、ch＝長方形的格數。框架缺或太舊時只跳通知（UI AGENTS 契約 3：不 error）
function Area.confirm(playerNum, list, cw, ch)
    local player = getSpecificPlayer(playerNum)
    if #list == 0 then
        Messages.toast(player, getText("IGUI_MBLD_Area_Empty"), getText("IGUI_MBLD_Title"))
        return false
    end
    local W = B.Window
    local UI = W and W.ui({ "window", "controls", "textWrap" })
    if UI == nil then
        Messages.toast(player, getText("IGUI_MBLD_NeedFramework"), getText("IGUI_MBLD_Title"))
        return false
    end
    if Area.panel then Area.panel.win:close() end
    local ok, p = pcall(Panel.new, UI, playerNum, list, cw, ch)
    if not ok then
        print(LOG .. "area dismantle panel build failed: " .. tostring(p))
        Messages.toast(player, Messages.unbuildRefusal("INTERNAL"), getText("IGUI_MBLD_Title"))
        discard(Area.panel)
        return false
    end
    Area.panel = p
    p.win:setVisible(true) -- 框架 Window：Focus.onFocus＋takeJoypad（Widgets/Window.lua:336-348）
    p.win:bringToTop()
    return true
end

return Area
