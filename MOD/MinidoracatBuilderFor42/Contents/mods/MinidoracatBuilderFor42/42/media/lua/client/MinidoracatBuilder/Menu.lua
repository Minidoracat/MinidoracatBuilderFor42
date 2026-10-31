-- 右鍵「拆除（建造工坊）」（設計稿「拆」）：本 MOD 蓋的、本工具能拆的東西才出現（Dismantle.kindOf）。選了先送拆除請求，
-- 伺服器收下才走過去、排動作（Client.dismantle）。這裡的判斷只給選單看：不能拆的照樣列出、變灰並寫原因（距離不查，
-- 選了會先走過去）；能不能拆、退什麼料由伺服器重查（Server.dismantle）。
-- 右鍵「挑圖塊（建造工坊）」（使用者 2026-10-31 定案）：點到的格子上每一張圖，選了就打開建造視窗、用完整圖塊名搜尋，
-- 選到那一項；不能蓋的照樣列出、變紅並寫原因（Entry.why）。
require "MinidoracatBuilder/Dismantle"
require "MinidoracatBuilder/Names"
require "MinidoracatBuilder/Messages"
require "MinidoracatBuilder/Client"

local Dismantle, Names = MinidoracatBuilder.Dismantle, MinidoracatBuilder.Names
local Messages, Client = MinidoracatBuilder.Messages, MinidoracatBuilder.Client
local Entry = MinidoracatBuilder.Entry
local Menu = MinidoracatBuilder.Menu or {}
MinidoracatBuilder.Menu = Menu

-- 點到的格子上、以及正上方那格的屋頂（在上一層的屋頂從底下點不到：從屋裡點地板就拆得到頭上那片），本 MOD 蓋的、
-- 本工具能拆的東西。同一件（多格、樓梯三片）只列一次。回 { { obj, kind, plan }, ... }
function Menu.targets(worldobjects)
    local out, seen, done = {}, {}, {}
    local function scan(sq, onlyRoof)
        if not sq then return end
        local objects = sq:getObjects()
        for i = 0, objects:size() - 1 do
            local o = objects:get(i)
            if not seen[o] then
                local kind = Dismantle.kindOf(o)
                if kind and (not onlyRoof or kind == "roof") then
                    local plan = Dismantle.plan(o, kind)
                    for _, p in ipairs(plan.remove) do seen[p] = true end
                    out[#out + 1] = { obj = o, kind = kind, plan = plan }
                end
            end
        end
    end
    for _, w in ipairs(worldobjects) do
        local sq = w:getSquare()
        if sq and not done[sq] then
            done[sq] = true
            scan(sq, false)
            scan(getCell():getGridSquare(sq:getX(), sq:getY(), sq:getZ() + 1), true)
        end
    end
    return out
end

function Menu.onPick(player, t)
    local own = {}
    for _, o in ipairs(t.plan.remove) do own[#own + 1] = o:getSquare() end
    Client.dismantle(player, t.obj, t.kind, own)
end

local function addOne(context, label, player, t)
    local opt = context:addOption(label, player, Menu.onPick, t)
    local code, extra = Dismantle.check(player, t.kind, t.plan, true)
    if code then
        opt.notAvailable = true
        local tip = ISWorldObjectContextMenu.addToolTip()
        tip.description = Messages.unbuildRefusal(code, extra)
        opt.toolTip = tip
    end
    return opt
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

-- 拆除：一件直接列「拆除（建造工坊）」，好幾件時展開成子選單、每件寫名稱。挑圖塊：一律子選單
function Menu.fill(playerNum, context, worldobjects, test)
    local player = getSpecificPlayer(playerNum)
    if not player or player:getVehicle() then return end
    local targets = Menu.targets(worldobjects)
    local tiles = MinidoracatBuilder.Window and Menu.tiles(worldobjects) or {}
    if #targets == 0 and #tiles == 0 then return end
    if test then return ISWorldObjectContextMenu.setTest() end -- 手把：有選項就回報（ISWorldObjectContextMenu.lua:122-125）
    local label = getText("IGUI_MBLD_Menu_Dismantle")
    if #targets == 1 then
        addOne(context, label, player, targets[1])
    elseif #targets > 1 then
        local sub = ISContextMenu:getNew(context)
        context:addSubMenu(context:addOption(label), sub)
        for _, t in ipairs(targets) do
            addOne(sub, Names.of(t.obj:getSprite():getName(), t.kind), player, t)
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
