-- 拆除（第五階段，設計稿「拆」）：本 MOD 蓋的、Cost.refund 是 "builder" 的東西（不能搬、原版不照材質拆的 IsoThumpable
-- 與燈）用本工具拆，每項退 1..v（v＝伺服器寫的退料表：IsoThumpable 的 buildMaterials；燈記在伺服器帳本 Ledger）。
-- 兩端共用、只讀世界：客戶端右鍵選單用 preview 判斷，伺服器 Server.dismantle 照同一份重查後才拆。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Cost"
require "MinidoracatBuilder/Materials"
require "MinidoracatBuilder/Check"

MinidoracatBuilder = MinidoracatBuilder or {}
local Dismantle = MinidoracatBuilder.Dismantle or {}
MinidoracatBuilder.Dismantle = Dismantle
local Rules, Entry, Cost = MinidoracatBuilder.Rules, MinidoracatBuilder.Entry, MinidoracatBuilder.Cost
local Materials, Check = MinidoracatBuilder.Materials, MinidoracatBuilder.Check
local NS, EW = GridSquareEdgeFacingDirection.NORTH_SOUTH, GridSquareEdgeFacingDirection.EAST_WEST

-- 本 MOD 蓋的片：Place 建的 IsoThumpable 或 IsoLightSwitch，modData 的 builderEntry 有值（和 Place.onAboutToBeRemoved
-- 同一個判斷：移除前清退料表的就是這些）。退多少不看這個記號，只看伺服器寫的退料表（buildMaterials、帳本）。
local function mine(o)
    return (instanceof(o, "IsoThumpable") or instanceof(o, "IsoLightSwitch")) and o:hasModData()
        and o:getModData().builderEntry and true or false
end

-- 本 MOD 蓋的、本工具能拆的物件回種類，否則 nil。只看 modData 與 sprite。
function Dismantle.kindOf(obj)
    if not mine(obj) or (instanceof(obj, "IsoThumpable") and not obj:isDismantable()) then return nil end
    local spr = obj:getSprite()
    local kind = spr and Rules.classify(spr)
    if not kind or Cost.refund(kind, spr) ~= "builder" then return nil end
    return kind
end

-- 格上 sprite 名稱是 name、本 MOD 蓋的那件（同一格不放同一張圖，Place 的 hasSprite）
function Dismantle.find(sq, name)
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        local spr = o:getSprite()
        if spr and spr:getName() == name and Dismantle.kindOf(o) then return o end
    end
    return nil
end

-- 拆一件要移除哪些物件、照哪些物件的退料表退。回 { remove = { 物件 }, refund = { 物件 }, landing = 平台或 nil,
-- foreign = true（同一組裡有不是本 MOD 蓋的片）}。同一組的片照「本 MOD 蓋的」收，不照各片自己的種類（建造時整組
-- 用原點的種類，Place.build）；同一組有不是本 MOD 蓋的片就整組不拆（foreign）：
--   樓梯：原版 buildUtil.getStairObjects 收三片（ISDismantleAction.lua:69-73），只照被點的那片退一次（三片的退料表都寫
--     整組，Place.build），所以同方向的三片要一起拆。getStairObjects 也收同一格別方向的樓梯片與它們的平台
--     （ISBuildUtil.lua:395-404,523-536），那些不算這一組。平台＝這一組頂片往上爬那一側、上一層那格的 Entry.STAIR_FLOOR
--     一般物件（Entry.cells 的 platform），原版只在旁邊沒有別的地板、沒有別的樓梯時收；拆不拆由伺服器決定
--     （Server.dismantle：只拆本 MOD 補的）。
--   多格：同一組的每一片（getSpriteGridObjectsIncludingSelf，ISDestroyCursor.lua:217），每片照自己的退料表退。引擎只看
--     sprite grid 相同、不看是不是同一個原點（IsoObject.java:5421-5455），另用 isConnectedSpriteGridObject 對原點。
--   其他：自己。
function Dismantle.plan(obj, kind)
    local remove, refund, landing, foreign = {}, {}, nil, false
    if kind == "stairs" then
        local west, top = Rules.westStairs(obj:getSprite():getType()), nil
        local list = buildUtil.getStairObjects(obj)
        for _, o in ipairs(list) do
            local spr = o:getSprite()
            if o:isStairsObject() and spr and Rules.westStairs(spr:getType()) == west then
                if mine(o) then remove[#remove + 1] = o else foreign = true end
                local t = spr:getType()
                if t == IsoObjectType.stairsTW or t == IsoObjectType.stairsTN then top = o:getSquare() end
            end
        end
        if top then
            local lx, ly, lz = top:getX() - (west and 1 or 0), top:getY() - (west and 0 or 1), top:getZ() + 1
            for _, o in ipairs(list) do
                local spr, s = o:getSprite(), o:getSquare()
                if not o:isStairsObject() and not instanceof(o, "IsoThumpable") and spr and spr:getName() == Entry.STAIR_FLOOR
                    and s and s:getX() == lx and s:getY() == ly and s:getZ() == lz then
                    landing = o
                end
            end
        end
        refund[1] = obj
    else
        local list = obj:getSpriteGridObjectsIncludingSelf(ArrayList.new())
        for i = 0, list:size() - 1 do
            local o = list:get(i)
            if o == obj or obj:isConnectedSpriteGridObject(o) then
                if mine(o) then
                    remove[#remove + 1] = o
                    refund[#refund + 1] = o
                else
                    foreign = true
                end
            end
        end
    end
    return { remove = remove, refund = refund, landing = landing, foreign = foreign }
end

-- 拆這一件要的工具：和蓋的時候一樣（Cost.of 的 tools，多格取聯集；使用者 2026-10-28 選）
function Dismantle.tools(kind, plan)
    local list = {}
    for i, o in ipairs(plan.remove) do list[i] = Cost.of(kind, o:getSprite(), 1) end
    return Cost.sum(list).tools
end

-- 這一格是不是樓梯頂端接著的地板（原版 isFloorAtTopOfStairs，ISMoveableSpriteProps.lua:3941-3961）
local function stairsTop(c)
    local cell = getCell()
    local e, s = cell:getGridSquare(c.x + 1, c.y, c.z - 1), cell:getGridSquare(c.x, c.y + 1, c.z - 1)
    return (e and e:has(IsoObjectType.stairsTW)) or (s and s:has(IsoObjectType.stairsTN)) or false
end

-- 門框、窗框那條邊上還裝著門、窗（原版 canScrapObjectInternal，ISMoveableSpriteProps.lua:3920-3925），或框上釘著木板
-- （窗框能封，Place.thumpable 的 setCanBarricade；拆了木板會懸空）。getDoor／getWindow 只收邊方向列舉，沒有 boolean 版
-- （IsoGridSquare.java:3634-3644,3666-3680；Place.check 同一種寫法）。
local function attached(kind, o, sq, spr)
    if o:isBarricaded() then return true end
    local n, w = Entry.edges(kind, spr)
    if kind == "doorFrame" then return (n and sq:getDoor(NS) ~= nil) or (w and sq:getDoor(EW) ~= nil) or false end
    return (n and sq:getWindow(NS) ~= nil) or (w and sq:getWindow(EW) ~= nil) or false
end

-- 能不能拆，回 code, extra 或 nil。順序：
--   同一組有不是本 MOD 蓋的片（plan.foreign）：NOT_OURS。
--   距離：和蓋一樣（MaxDistance、上下差一層、同一層要走得到；格邊種類從哪一側都能拆）。preview（右鍵選單）不查：
--     選了會先走過去，伺服器完成時照樣查。
--   安全屋：每一片的格子都要有 BUILD 權限（原版大錘也是），不看 WhereCanBuild。
--   原版拆解擋的（canScrapObjectInternal，ISMoveableSpriteProps.lua:3905-3939）：
--     容器要空（isObjectNoContainerOrEmpty；伺服器的移除不倒出內容，IsoObject.java:4545-4553）、桌子上有桌上物件、
--     集水的（IsWaterCollector）裡面有水：NOT_EMPTY。門框裝著門、窗框裝著窗、框上釘著木板：ATTACHED。
--     二樓以上、樓梯頂端接著的地板：STAIRS_TOP。
--   二樓以上的地板：格上有別的東西（牆、家具、地上物品）不拆，不然會懸空。
--   工具：和蓋的時候一樣；建造作弊不查（Server.complete 同一條）。
function Dismantle.check(player, kind, plan, preview)
    local cells = {}
    for i, o in ipairs(plan.remove) do
        local sq = o:getSquare()
        cells[i] = { x = sq:getX(), y = sq:getY(), z = sq:getZ(), sq = sq }
    end
    if #cells == 0 then return "GONE", nil end
    if plan.foreign then return "NOT_OURS", { x = cells[1].x, y = cells[1].y, z = cells[1].z } end
    if not preview then
        local code, extra = Check.near(player, cells, Entry.EDGE[kind], false)
        if code then return code, extra end
    end
    for _, c in ipairs(cells) do
        local code = Check.safehouse(player, c, preview, "dismantle")
        if code then return code, { x = c.x, y = c.y, z = c.z } end
    end
    for i, o in ipairs(plan.remove) do
        local c = cells[i]
        local at = { x = c.x, y = c.y, z = c.z }
        local spr = o:getSprite()
        local p = spr:getProperties()
        if not o:isObjectNoContainerOrEmpty() or (p:has("IsTable") and c.sq:has("IsTableTop"))
            or (p:has("IsWaterCollector") and o:hasFluid()) then
            return "NOT_EMPTY", at
        end
        if (kind == "doorFrame" or kind == "windowFrame") and attached(kind, o, c.sq, spr) then return "ATTACHED", at end
        if kind == "floor" and c.z > 0 then
            if stairsTop(c) then return "STAIRS_TOP", at end
            if c.sq:getObjects():size() > 1 then return "FLOOR_IN_USE", at end
        end
    end
    if not player:isBuildCheat() then
        local missing = Materials.missingTools(player, Dismantle.tools(kind, plan))
        if missing then return "NO_TOOL", { tools = missing } end
    end
    return nil
end

return Dismantle
