-- 右鍵「拆除（建造工坊）」（設計稿「拆」）：本 MOD 蓋的、本工具能拆的東西（Dismantle.kindOf）寫名稱列出，停上去亮出要拆的
-- 每一片。選了送一件的拆除清單（Client.dismantleMany），伺服器收下才走過去、排動作。這裡的判斷只給選單看：不能拆的照樣
-- 列出、變灰並寫原因（距離不查，選了會先走過去；建造作弊不走）；能不能拆、退什麼料由伺服器重查（Server.dismantle）。本 MOD 蓋的、
-- 不歸本工具拆的（能搬、原版拆解、只能砸、窗簾）也列，變灰並寫該用原版哪個動作（審查 1101 #5）。
-- 右鍵「拆除一區...（建造工坊）」（Area.start，只用滑鼠）與「換成...（建造工坊）」（Window.openReplace）：設計稿 claim 3、4。
-- 右鍵「挑圖塊（建造工坊）」（使用者 2026-10-31 定案）：點到的格子上每一張圖，選了就打開建造視窗、用完整圖塊名搜尋，
-- 選到那一項；不能蓋的照樣列出、變紅並寫原因（Entry.why）。
require "MinidoracatBuilder/Dismantle"
require "MinidoracatBuilder/Names"
require "MinidoracatBuilder/Messages"
require "MinidoracatBuilder/Client"
require "MinidoracatBuilder/Area"

local Dismantle, Names = MinidoracatBuilder.Dismantle, MinidoracatBuilder.Names
local Messages, Client = MinidoracatBuilder.Messages, MinidoracatBuilder.Client
local Entry, Area = MinidoracatBuilder.Entry, MinidoracatBuilder.Area
local Menu = MinidoracatBuilder.Menu or {}
MinidoracatBuilder.Menu = Menu

-- 點到的格子上、以及正上方那格的屋頂（在上一層的屋頂從底下點不到：從屋裡點地板就拆得到頭上那片），本 MOD 蓋的東西，
-- 含點到的格子地板上本 MOD 掛的地面覆蓋（Dismantle.overlays）。同一件（多格、樓梯三片）只列一次（Area.scan）。
-- 回 targets, others：targets＝本工具拆的 { obj 或 overlay, kind, plan, name＝sprite 名稱, route = "builder" }；
-- others＝不歸本工具拆的（點到的格子上，route＝pickup／scrap／none／sheet，見 Area.route）
function Menu.targets(worldobjects)
    local found, seen, done = {}, {}, {}
    for _, w in ipairs(worldobjects) do
        local sq = w:getSquare()
        if sq and not done[sq] then
            done[sq] = true
            Area.scan(sq, seen, found, false)
            Area.scan(getCell():getGridSquare(sq:getX(), sq:getY(), sq:getZ() + 1), seen, found, true)
        end
    end
    local out, others = {}, {}
    for _, t in ipairs(found) do
        if t.route == "builder" then out[#out + 1] = t else others[#others + 1] = t end
    end
    return out, others
end

function Menu.onPick(player, t)
    Client.dismantleMany(player, { Area.item(t) })
end

-- 停上去亮出那件的每一片、離開熄（原版 ISDisassembleMenu.createMenu 的 onHighlight 寫法；ISContextMenu.lua:236-240 呼叫）。
-- 地面覆蓋沒有自己的物件，亮它掛著的那塊地板
local function onHighlight(_, menu, on, list, color)
    for _, o in ipairs(list) do
        if on then
            o:setHighlightColor(menu.player, color)
            o:setOutlineHighlightCol(menu.player, color)
        end
        o:setHighlighted(menu.player, on, false)
        o:setOutlineHighlight(menu.player, on)
    end
end

local function highlight(opt, t, color)
    local list = t.overlay and { t.overlay.floor } or (t.plan and t.plan.remove) or { t.obj }
    opt.onHighlightParams = { list, color }
    opt.onHighlight = onHighlight
end

local function tip(opt, text)
    local t = ISWorldObjectContextMenu.addToolTip()
    t.description = text
    opt.toolTip = t
end

-- 這個玩家正在拆、還沒輪到的件數（Client.pendingUnbuild.left，C6；輪完清成 nil）：新的拆除會取消它們（每人一個請求），
-- 選項先說（審查 #8）
local function unbuildLeft(player)
    local b = Client.pendingUnbuild
    if not (b and b.player == player) then return 0 end
    return b.left or 0
end

-- cancels＝接在說明後面的「會取消正在拆的 N 件」（沒有時是空字串）
local function addOne(context, label, player, t, cancels)
    local opt = context:addOption(label, player, Menu.onPick, t)
    highlight(opt, t, getCore():getBadHighlitedColor())
    local code, extra = Dismantle.check(player, t.kind, t.plan, true)
    if code then
        opt.notAvailable = true
        tip(opt, Messages.unbuildRefusal(code, extra))
    else
        tip(opt, getText("IGUI_MBLD_Unbuild_RefundTip") .. cancels)
    end
    return opt
end

-- 本 MOD 蓋的、不歸本工具拆的：變灰，說明寫該用原版哪個動作（重用詳情的拆除方式 IGUI_MBLD_Refund_<route>）
local function addOther(context, label, t)
    local opt = context:addOption(label)
    opt.notAvailable = true
    highlight(opt, t, getCore():getBadHighlitedColor())
    tip(opt, getText("IGUI_MBLD_Refund_" .. t.route))
    return opt
end

-- 能原地換掉的那件（設計稿 claim 4；和 Dismantle.replaceable 同一份條件）
local function swappable(t)
    return t.obj ~= nil and Dismantle.replaceableOld(t.kind, t.obj, t.plan)
end

-- 「換成...」：打開建造視窗，只列和那件同一組、同材料的款式（Window.openReplace，C9）
function Menu.replace(playerNum, name)
    local W = MinidoracatBuilder.Window
    if W and W.openReplace then W.openReplace(playerNum, name) end
end

-- 點到的格子上每一張圖：物件本身、掛在它上面的疊圖（地圖的地面與牆面疊圖讀地圖時掛到地板或牆上，
-- CellLoader.java:201-264；IsoObject.getAttachedAnimSprite :1824、IsoSpriteInstance.getName :86）、overlaySprite
-- （IsoObject.getOverlaySprite :4904）。只收「名稱_編號」的 tiledef 圖，同一張只列一次，不設上限（比畫面高時原版選單會捲動，
-- ISContextMenu.lua:603-607）。回 { 名稱, ... }
function Menu.tiles(worldobjects)
    local out, seen, done = {}, {}, {}
    local function add(name)
        if name and not seen[name] and name:find("_%d+$") then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    for _, w in ipairs(worldobjects) do
        local sq = w:getSquare()
        if sq and not done[sq] then
            done[sq] = true
            local objects = sq:getObjects()
            for i = 0, objects:size() - 1 do
                local o = objects:get(i)
                local spr = o:getSprite()
                add(spr and spr:getName())
                local att = o:getAttachedAnimSprite()
                for j = 0, att and att:size() - 1 or -1 do
                    local a = att:get(j)
                    add(a and a:getName())
                end
                local ov = o:getOverlaySprite()
                add(ov and ov:getName())
            end
        end
    end
    return out
end

-- 選了一張：打開建造視窗，搜尋欄填完整圖塊名（W.setQuery：清單換成它所在的那一桶並選到它；不在目錄時改選同一件
-- 東西能蓋的那一項，或說明原因）
function Menu.pickTile(playerNum, name)
    local W = MinidoracatBuilder.Window
    if W and W.open(playerNum) then W.setQuery(name) end
end

-- 子選單一列：能蓋的「種類：名稱」；同一件東西有能蓋的那一項時（開著的門、多格的其他格…）照樣能選，寫那一項的種類；
-- 其他不能蓋的變紅、停上去寫原因（紅字是原版「不能選」的顏色，ISContextMenu.lua:441-443）
local function addPick(sub, playerNum, name)
    local e = Entry.resolve(name)
    local code, arg, alt
    if not e then
        code, arg, alt = Entry.why(name)
        e = alt and Entry.resolve(alt)
    end
    local label = e and getText("IGUI_MBLD_Menu_Named", Names.kind(e.kind), name) or name
    local opt = sub:addOption(label, playerNum, Menu.pickTile, name)
    if code and not alt then
        opt.notAvailable = true
        local tip = ISWorldObjectContextMenu.addToolTip()
        tip.description = MinidoracatBuilder.Window.whyText(code, arg)
        opt.toolTip = tip
    end
end

-- 拆除：一件直接列「拆除（建造工坊）：名稱」，好幾件時展開成子選單、每件寫名稱（不歸本工具拆的排在後面、變灰）。
-- 有本 MOD 蓋的東西時另加「拆除一區...」（手把不開：長方形游標只用滑鼠，C7）與能原地換的「換成...」。挑圖塊：一律子選單
function Menu.fill(playerNum, context, worldobjects, test)
    local player = getSpecificPlayer(playerNum)
    if not player or player:getVehicle() then return end
    local targets, others = Menu.targets(worldobjects)
    local tiles = MinidoracatBuilder.Window and Menu.tiles(worldobjects) or {}
    local n = #targets + #others
    if n == 0 and #tiles == 0 then return end
    if test then return ISWorldObjectContextMenu.setTest() end -- 手把：有選項就回報（ISWorldObjectContextMenu.lua:122-125）
    local left = unbuildLeft(player)
    local cancel = left > 0 and getText("IGUI_MBLD_Menu_CancelsUnbuild", tostring(left)) or nil
    local cancels = cancel and (" <LINE> " .. cancel) or ""
    local label = getText("IGUI_MBLD_Menu_Dismantle")
    local into = context
    if n > 1 then
        into = ISContextMenu:getNew(context)
        context:addSubMenu(context:addOption(label), into)
    end
    local function named(t)
        local name = Names.of(t.name, t.kind)
        return n > 1 and name or getText("IGUI_MBLD_Menu_Named", label, name)
    end
    for _, t in ipairs(targets) do addOne(into, named(t), player, t, cancels) end
    for _, t in ipairs(others) do addOther(into, named(t), t) end
    local Cursor = MinidoracatBuilder.Cursor
    if n > 0 and getJoypadData(playerNum) == nil and Cursor and Cursor.startArea then
        local opt = context:addOption(getText("IGUI_MBLD_Menu_Area"), playerNum, Area.start)
        if cancel then tip(opt, cancel) end
    end
    local swaps = {}
    for _, t in ipairs(targets) do
        if swappable(t) then swaps[#swaps + 1] = t end
    end
    if #swaps > 0 then
        local good, rlabel = getCore():getGoodHighlitedColor(), getText("IGUI_MBLD_Menu_Replace")
        local sub = context
        if #swaps > 1 then
            sub = ISContextMenu:getNew(context)
            context:addSubMenu(context:addOption(rlabel), sub)
        end
        for _, t in ipairs(swaps) do
            highlight(sub:addOption(#swaps > 1 and Names.of(t.name, t.kind) or rlabel, playerNum, Menu.replace, t.name), t, good)
        end
    end
    if #tiles > 0 then
        local sub = ISContextMenu:getNew(context)
        context:addSubMenu(context:addOption(getText("IGUI_MBLD_Menu_Pick")), sub)
        for _, name in ipairs(tiles) do addPick(sub, playerNum, name) end
    end
end

Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, worldobjects, test)
    return MinidoracatBuilder.Menu.fill(playerNum, context, worldobjects, test)
end)

return Menu
