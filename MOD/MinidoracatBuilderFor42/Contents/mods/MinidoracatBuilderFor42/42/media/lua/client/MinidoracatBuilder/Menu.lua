-- 右鍵「拆除（建造工坊）」（設計稿「拆」）：本 MOD 蓋的、本工具能拆的東西才出現（Dismantle.kindOf）。選了先送拆除請求，
-- 伺服器收下才走過去、排動作（Client.dismantle）。這裡的判斷只給選單看：不能拆的照樣列出、變灰並寫原因（距離不查，
-- 選了會先走過去）；能不能拆、退什麼料由伺服器重查（Server.dismantle）。
require "MinidoracatBuilder/Dismantle"
require "MinidoracatBuilder/Names"
require "MinidoracatBuilder/Messages"
require "MinidoracatBuilder/Client"

local Dismantle, Names = MinidoracatBuilder.Dismantle, MinidoracatBuilder.Names
local Messages, Client = MinidoracatBuilder.Messages, MinidoracatBuilder.Client
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

-- 一件直接列「拆除（建造工坊）」，好幾件時展開成子選單、每件寫名稱
function Menu.fill(playerNum, context, worldobjects, test)
    local player = getSpecificPlayer(playerNum)
    if not player or player:getVehicle() then return end
    local targets = Menu.targets(worldobjects)
    if #targets == 0 then return end
    if test then return ISWorldObjectContextMenu.setTest() end -- 手把：有選項就回報（ISWorldObjectContextMenu.lua:122-125）
    local label = getText("IGUI_MBLD_Menu_Dismantle")
    if #targets == 1 then
        addOne(context, label, player, targets[1])
        return
    end
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(context:addOption(label), sub)
    for _, t in ipairs(targets) do
        addOne(sub, Names.of(t.obj:getSprite():getName(), t.kind), player, t)
    end
end

Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, worldobjects, test)
    return MinidoracatBuilder.Menu.fill(playerNum, context, worldobjects, test)
end)

return Menu
