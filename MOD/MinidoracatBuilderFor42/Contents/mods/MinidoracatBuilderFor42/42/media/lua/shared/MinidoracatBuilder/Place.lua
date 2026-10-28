-- 放置：補格子、每格能不能放、依種類建立物件並同步。出處 bt-authority §2、§4.2。
-- 兩端共用：伺服器（單機在本機）放置；客戶端只用 Place.check 給游標預覽（Check.item 的 preview 不補格子，只查已有的格子）。
-- 通則：建好物件、設完屬性，才 AddSpecialObject（引擎自己更新室內判定與碰撞），再 transmit 一次。
-- 客戶端收到 AddItemToMap 不會去重，送兩次就變兩個（IsoObject.java:4430-4471）。
require "MinidoracatBuilder/Entry"

local Entry, Rules = MinidoracatBuilder.Entry, MinidoracatBuilder.Rules
local Place = MinidoracatBuilder.Place or {}
MinidoracatBuilder.Place = Place

local F, T = IsoFlagType, IsoObjectType
local NO_TILE_ID = 20000000 -- 非 tiledef sprite 的預設 id（IsoSprite.java:129-130）
local NS, EW = GridSquareEdgeFacingDirection.NORTH_SOUTH, GridSquareEdgeFacingDirection.EAST_WEST

-- 格子不存在時補建（原版 ISBuildIsoEntity.lua:517-529）；chunk 沒載入時建不出來（IsoCell.java:4337-4362）
function Place.square(x, y, z)
    local cell = getCell()
    local sq = cell:getGridSquare(x, y, z)
    if not sq and getWorld():isValidSquare(x, y, z) then sq = cell:createNewGridSquare(x, y, z, true) end
    if sq then sq:EnsureSurroundNotNull() end
    return sq
end

-- 同一張圖不重複放（buildRecipeCode.lua:345-353）；農作物上不蓋地板（同處，農作物有 Lua 行為）
local function hasSprite(sq, name, farming)
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local spr = objects:get(i):getSprite()
        local s = spr and spr:getName()
        if s == name or (farming and s and s:sub(1, 18) == "vegetation_farming") then return true end
    end
    return false
end

-- 這條格邊已經有東西：牆、牆角、門框、窗框、柵欄、門、窗，以及其他擋這條邊的物件
-- （原版 isObjectSpriteBlockingWallPlacement 看 collideN/W，ISBuildIsoEntity.lua:150-166）
local function edgeTaken(sq, north)
    if north then
        return sq:has(F.WallN) or sq:has(F.WallNTrans) or sq:has(F.WallNW) or sq:has(F.collideN)
            or sq:has(F.DoorWallN) or sq:has("DoorWallNTrans") or sq:has(F.WindowN) or sq:has(F.HoppableN)
            or sq:has(F.TallHoppableN) or sq:getDoor(NS) ~= nil or sq:getWindow(NS) ~= nil
    end
    return sq:has(F.WallW) or sq:has(F.WallWTrans) or sq:has(F.WallNW) or sq:has(F.collideW)
        or sq:has(F.DoorWallW) or sq:has("DoorWallWTrans") or sq:has(F.WindowW) or sq:has(F.HoppableW)
        or sq:has(F.TallHoppableW) or sq:getDoor(EW) ~= nil or sq:getWindow(EW) ~= nil
end

local function doorFrameAt(sq, north)
    if north then return sq:has(F.DoorWallN) or sq:has("DoorWallNTrans") end
    return sq:has(F.DoorWallW) or sq:has("DoorWallWTrans")
end

-- 牆不能把既有的多格家具切開（ISBuildIsoEntity.lua:388-399）：北邊的牆擋 grid y > 0 的片，西邊擋 x > 0
local function splitsGrid(sq, n, w)
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local spr = objects:get(i):getSprite()
        local grid = spr and spr:getSpriteGrid()
        if grid and ((n and grid:getSpriteGridPosY(spr) > 0) or (w and grid:getSpriteGridPosX(spr) > 0)) then
            return true
        end
    end
    return false
end

-- IsoDoor 會把同一張表 +2 號當開門的圖（開著的那張則 −2，IsoDoor.java:856-868）；那一號不存在時引擎會建一個空 sprite
local function doorPairExists(spr)
    local tileset, num = spr:getName():match("^(.*)_(%d+)$")
    local d = spr:getProperties():has(F.open) and -2 or 2
    return tileset ~= nil and Entry.sprite(tileset .. "_" .. (tonumber(num) + d)) ~= nil
end

local function floorUnder(sq)
    return sq:getZ() == 0 or sq:getFloor() ~= nil
end

local function vegetation(sq)
    return sq:has(F.canBeCut) or sq:has("tree")
end

-- 樓梯一片（照原版 BuildRecipeCode.stairs.OnIsValid，buildRecipeCode.lua:163-212）。role＝top／mid／bottom／platform
-- （Entry.cells）。west＝往西爬的那種，原版叫 north（ISBuildIsoEntity.lua:18-20）。
-- 不在最高層、不是別組同向樓梯的頂端平台、正上方沒有地板（頭會撞到）；頂片上一層朝平台那邊沒有牆；平台不實心。
-- 比原版嚴：三片都要踩在地板上（z=0 的地面也算），不放在水上（原版底片不能，中、頂片會補地板），不補懸空的柱子。
-- 跟其他擋路的東西一樣不放在高草、樹、實心或擋放置的東西上，格上沒有人，也不擋到別的樓梯。
local function stairsOk(spr, sq, role)
    if role == "platform" then return not (sq:isSolid() or sq:isSolidTrans()) end
    local west = Rules.westStairs(spr:getType())
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    if z >= getMaximumWorldLevel() or sq:isVehicleIntersecting() or sq:HasStairs() then return false end
    if sq:hasModData() and sq:getModData()["ConnectedToStairs" .. tostring(not west)] then return false end
    local above = getCell():getGridSquare(x, y, z + 1)
    if above and above:getFloor() then return false end
    if role == "top" and above and above:getWall(not west) then return false end
    if not floorUnder(sq) or vegetation(sq) or sq:has(F.water) or sq:has(F.taintedWater) then return false end
    if sq:isSolid() or sq:isSolidTrans() or (sq:has("BlocksPlacement") and not sq:has(F.canBeRemoved)) then return false end
    return sq:getMovingObjects():isEmpty() and not buildUtil.stairIsBlockingPlacement(sq, true)
end

-- 屋頂（原版沒有放屋頂的路徑，bt-newkinds §5.3）：從二樓起，正下方不是樓梯（同原版地板的 HasStairsBelow）；
-- 要有東西撐著：正下方那格有牆，或這格、四鄰有地板或屋頂（四鄰有地板＝connectedWithFloor，不含斜坡）。
-- 照座標查、不要這格存在：客戶端預覽時上一層的格子常常還沒建（Check.item 照樣呼叫）。
-- planned（只有客戶端預覽一排時給）：同一排前面判定可蓋的屋頂格（鍵＝Place.key），當成撐得住的鄰格。伺服器一項
-- 一個動作照順序蓋，輪到後面那格時前一格已經在世界上，不必傳。
local function supports(sq)
    if not sq then return false end
    if sq:has(F.solidfloor) then return true end
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local s = objects:get(i):getSprite()
        if s and (Rules.typeCode(s:getType()) == "roof" or s:getProperties():has("RoofGroup")) then return true end
    end
    return false
end
function Place.key(x, y, z) return (z * 100000 + x) * 100000 + y end
function Place.roofAt(x, y, z, planned)
    if z < 1 then return false end
    local cell = getCell()
    local below = cell:getGridSquare(x, y, z - 1)
    if below and below:HasStairs() then return false end
    if below and (below:getWall(true) or below:getWall(false) or below:getWallSE()) then return true end
    if planned and (planned[Place.key(x - 1, y, z)] or planned[Place.key(x + 1, y, z)]
        or planned[Place.key(x, y - 1, z)] or planned[Place.key(x, y + 1, z)]) then
        return true
    end
    return supports(cell:getGridSquare(x, y, z)) or supports(cell:getGridSquare(x - 1, y, z))
        or supports(cell:getGridSquare(x + 1, y, z)) or supports(cell:getGridSquare(x, y - 1, z))
        or supports(cell:getGridSquare(x, y + 1, z))
end

-- 窗簾（原版搬動放窗上物件，ISMoveableSpriteProps.lua:1896-1937；找窗框 getWallForFacing :2651-2691）：
-- 面向 S、E 的掛在這格的窗框上，面向 N、W 的掛在南邊、東邊那格的窗框上。這格不能是室外：exterior＝沒有房間而且
-- 沒有屋頂（IsoGridSquare.java:7306-7317），所以自建屋要先有屋頂或上一層地板。同一面不能已經有窗上物件，也不能有
-- 擋同一面的床單窗簾。關著的那張（編號 −4）要在：不在時建構子會建空 sprite，存檔記它的 id（IsoCurtain.java:91-96）。
-- 原版還要求玩家不站在室外；這裡不查，伺服器另查走得到。
local CLASH = { S = T.curtainN, N = T.curtainS, E = T.curtainW, W = T.curtainE }
local function curtainOk(spr, sq)
    local facing = spr:getProperties():get("Facing")
    local clash = facing and CLASH[facing]
    if not clash or sq:has(F.exterior) then return false end
    local ns = facing == "N" or facing == "S"
    local frame = sq
    if facing == "N" then
        frame = getCell():getGridSquare(sq:getX(), sq:getY() + 1, sq:getZ())
    elseif facing == "W" then
        frame = getCell():getGridSquare(sq:getX() + 1, sq:getY(), sq:getZ())
    end
    if not (frame and frame:has(ns and F.WindowN or F.WindowW)) then return false end
    local tileset, num = spr:getName():match("^(.*)_(%d+)$")
    local closed = tileset and Entry.sprite(tileset .. "_" .. (tonumber(num) - 4))
    if not closed or closed:getID() < 0 or closed:getID() == NO_TILE_ID then return false end
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        local op = o:getProperties()
        if op and op:get("MoveType") == "WindowObject" and op:get("Facing") == facing then return false end
        if instanceof(o, "IsoCurtain") and o:getType() == clash then return false end
    end
    return true
end

-- 能不能在 sq 放 spr（種類 kind）。回 ok 與桌面高度（放在桌上的物件要墊高，原版搬家具算的）。
-- player 只給原版搬家具的判斷讀玩家所在格（窗上物件）；擺放技能與工具不查（placeTool 已清掉）。
-- role：多格項目裡這一格的角色（Entry.cells 第 5 欄；目前只有樓梯有）。planned：見 Place.roofAt。
function Place.check(kind, spr, sq, player, role, planned)
    if kind == "stairs" then return stairsOk(spr, sq, role) end
    if sq:isVehicleIntersecting() or hasSprite(sq, spr:getName(), kind == "floor") then return false end
    local p = spr:getProperties()
    if kind == "floor" then
        -- 原版 BuildRecipeCode.floor.OnIsValid（buildRecipeCode.lua:338-361）
        return not sq:HasStairsBelow() and sq:connectedWithFloor()
    end
    if kind == "roof" then return Place.roofAt(sq:getX(), sq:getY(), sq:getZ(), planned) end
    if kind == "curtain" then return curtainOk(spr, sq) end
    if Entry.EDGE[kind] then
        if sq:HasStairs() then return false end
        local n, w = Entry.edges(kind, spr)
        if kind == "door" then
            -- 門要放進同方向、還沒有門的門框（原版 isValidPerSquare：有門框、沒有門），開門的圖也要在
            return doorPairExists(spr) and ((n and doorFrameAt(sq, true) and sq:getDoor(NS) == nil)
                or (w and doorFrameAt(sq, false) and sq:getDoor(EW) == nil))
        end
        if kind == "window" then
            return (n and sq:has(F.WindowN) and sq:getWindow(NS) == nil)
                or (w and sq:has(F.WindowW) and sq:getWindow(EW) == nil)
        end
        -- 不擋樓梯：底片前面、頂片上一層出口那條邊不能蓋（原版木牆、門框都查，ISWoodenWall.lua:129、
        -- ISWoodenDoorFrame.lua:46、ISBuildUtil.lua:438-480）
        if (n and buildUtil.stairIsBlockingPlacement(sq, true, true))
            or (w and buildUtil.stairIsBlockingPlacement(sq, true, false)) then
            return false
        end
        if not floorUnder(sq) and not sq:hasFloor(n) then return false end -- 樓上的牆要踩在地板上（ISWoodenWall:isValid）
        if not n and not w then return not sq:has(F.WallSE) end           -- 柱子
        return not ((n and edgeTaken(sq, true)) or (w and edgeTaken(sq, false)) or splitsGrid(sq, n, w))
    end
    -- 會擋路的東西：格上有人、殭屍或動物，或會擋到樓梯時不放（原版 isFree(true)、stairIsBlockingPlacement）
    if (p:has(F.solid) or p:has(F.solidtrans))
        and (not sq:getMovingObjects():isEmpty() or buildUtil.stairIsBlockingPlacement(sq, true)) then
        return false
    end
    if p:has("IsMoveAble") then
        -- 原版搬家具放下的判斷（地板、桌面、掛牆要有牆、窗上物件要有窗框、地毯不疊…），伺服器能跑（bt-authority §4.2）。
        -- 成功時回的不一定是 true（掛牆時回那面牆），照真假看。
        local props = ISMoveableSpriteProps.new(spr)
        -- 不要求原版的擺放技能與工具（設計稿：工具照 Cost）：placeTool 是 nil 時 hasRequiredSkill／hasTool 都放行（:1956-1961）
        props.placeTool = nil
        if not props:canPlaceMoveableInternal(player, sq, nil) then return false end
        return true, (props.isTableTop or props.isTable) and props.yOffsetCursor or 0
    end
    if not floorUnder(sq) or vegetation(sq) then return false end
    -- 實心或擋放置的東西（含不能搬的實心容器）不疊在已經實心、已經擋放置的格子上
    if kind == "solid" or kind == "container" or p:has(F.solid) or p:has(F.solidtrans) then
        return not (sq:isSolid() or sq:isSolidTrans()) and not (sq:has("BlocksPlacement") and not sq:has(F.canBeRemoved))
    end
    return true
end

-- ---------------------------------------------------------------- 建立
local function finish(sq, obj, index)
    sq:AddSpecialObject(obj, index or -1) -- 會呼叫 addToWorld，照 sprite 的 container 屬性建容器（IsoObject.java:4502-4504）
    obj:setExplored(true) -- 所以排在這之後：蓋出來的容器不生戰利品（ISBuildIsoEntity.lua:736-737）
    obj:transmitCompleteItemToClients()
end

-- 拆了退什麼＝付的扣掉電器費（電器費拆了不退，Cost.of）
local function refundable(cost)
    local out, fee = {}, cost.fee or {}
    for ft, n in pairs(cost.items) do
        local v = n - (fee[ft] or 0)
        if v > 0 then out[ft] = v end
    end
    return out
end

-- 退料只寫在伺服器建立的 Java 欄位 buildMaterials（原版拆解讀它）；modData 只放顯示用的資料
-- 門框照原版不給打（entity 門框腳本都是 isThumpable = false）：thumpable 的 IsoThumpable 會被 getSpecialWall 當成牆，
-- 門開著也走不過去（IsoGridSquare.java:3804-3818）
-- 樓梯照 Wood_Stairs 剛好 6 級、沒有建造加成時的血量：health 150＋最高相關技能等級 6 × skillBaseHealth 50
-- （stairs/entity_carpentry_stairs.txt；ISBuildIsoEntity.lua:657-668，等級越高原版越耐打）
local HEALTH = { wall = 450, windowFrame = 450, fence = 300, stairs = 450 }
-- 會擋路（solid／solidtrans）的非格邊物件照原版搬家具放下，都打得壞，而且整格擋住（不然會被 getSpecialWall 當成格邊的牆）：
--   一般的：原版做成 IsoThumpable，一隻殭屍就能打（thumpDmg 1，IsoThumpable.java:1029-1041），血量＝搬運重量（沒寫當 50）
--   × 材質倍率（ISMoveableSpriteProps.lua:148,322-325,2379-2388；ISMoveableDefinitions.lua:688-690）。
--   地毯、掛牆物、放在桌上的：原版做成一般物件再設 movedThumpable（ISMoveableSpriteProps.lua:2330,2501-2504），血量 100、
--   每下扣「圍著打的殭屍數 ÷ 8」、最多 1，不足 1 的累積（IsoObject.java:205,5747-5759）；IsoThumpable 的 thumpDmg 預設就是 8
--   （IsoThumpable.java:101,1027-1041 同一算法）。這裡做成 IsoThumpable，和原版那種一般物件差在：受沙盒「殭屍破壞
--   建築」控制（IsoThumpable.java:994）、玩家揮武器打得到（CombatManager.java:277-283）。
-- 回傳血量與 thumpDmg（nil＝不改預設）
local function solidHealth(p)
    local mt = p:get("MoveType")
    if mt == "FloorRug" or mt == "WallObject" or p:has("IsTableTop") then return 100, nil end
    local mat = p:get("Material")
    local m = mat and ISMoveableDefinitions:getInstance().getHealthDefinition(mat) or 1
    return (tonumber(p:get("PickUpWeight")) or 50) * m, 1
end
local function thumpable(c, kind, north)
    local sq, spr = c.sq, c.spr
    local p = spr:getProperties()
    local obj = IsoThumpable.new(getCell(), sq, spr:getName(), north, {})
    local solid = not Entry.EDGE[kind] and (p:has(F.solid) or p:has(F.solidtrans))
    -- 屬性照原版 entity 建造推（ISBuildIsoEntity:setInfo，ISBuildIsoEntity.lua:611-628）
    obj:setCanPassThrough(not (p:has(F.solid) or p:has(F.solidtrans) or p:has(F.WallN) or p:has(F.WallNTrans)
        or p:has(F.WallW) or p:has(F.WallWTrans) or p:has(F.WallNW)))
    obj:setBlockAllTheSquare(solid or p:has("BlocksPlacement"))
    obj:setIsHoppable(kind == "fence")
    obj:setIsDoorFrame(kind == "doorFrame")
    obj:setCanBarricade(kind == "windowFrame")
    obj:setIsFloor(kind == "floor")
    local hp, dmg = HEALTH[kind], nil
    if solid then hp, dmg = solidHealth(p) end
    if dmg then obj:setThumpDmg(dmg) end
    obj:setIsThumpable(hp ~= nil) -- 門框、地板、不擋路的東西照原版不打
    obj:setIsDismantable(true)
    hp = hp or 200
    obj:setMaxHealth(hp)
    obj:setHealth(hp)
    if c.yoff and c.yoff ~= 0 then obj:setRenderYOffset(c.yoff) end -- 放在桌上（ISMoveableSpriteProps.lua:2468-2479）
    local mats = obj:getBuildMaterials()
    for ft, v in pairs(refundable(c.cost)) do mats[ft] = tostring(v) end
    obj:getModData().builderEntry = spr:getName()
    -- 水槽這類接水管的：照原版搬家具，放好要重新接水管才有水（ISMoveableSpriteProps.lua:2491-2494；IsoObject.java:2632-2636）
    if p:has(F.waterPiped) then obj:getModData().canBeWaterPiped = true end
    return obj
end

-- 地板：照原版 floor.OnCreate（buildRecipeCode.lua:364-418），差別是先拆舊的再放新的（同一格先刪後加，索引才對得上，
-- bt-authority §2.1-4），地毯留著、新地板插在地毯前面。舊物件只拆這一格的那片：多格的一組照原版整組拆
-- 會動到沒驗證過的格子（IsoGridSquare.java:5942-5965）。
function Place.clearFloor(sq)
    local objects, rug = sq:getObjects(), nil
    for i = objects:size() - 1, 0, -1 do
        local o = objects:get(i)
        local p = o:getProperties()
        local tex = o:getTextureName() or ""
        if tex:find("floors_rugs", 1, true) then
            rug = o
        elseif p and (p:has(F.canBeRemoved) or p:has(F.solidfloor) or p:has(F.noStart) or p:has(F.taintedWater)
            or (p:has(F.vegitation) and o:getType() ~= T.tree)) or tex:find("blends_grassoverlays", 1, true) then
            sq:transmitRemoveItemFromSquare(o, false)
        end
    end
    return rug and objects:indexOf(rug) or nil
end

local function placeFloor(sq, obj)
    local index = Place.clearFloor(sq)
    finish(sq, obj, index)
    sq:EnsureSurroundNotNull()
    sq:RecalcProperties()
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    DesignationZoneAnimal.addNewRoof(x, y, z)
    sq:getCell():checkHaveRoof(x, y)
    for zz = z - 1, 0, -1 do -- 下面幾層補格子並重算
        local below = getCell():getGridSquare(x, y, zz)
        if not below then
            below = IsoGridSquare.getNew(getCell(), nil, x, y, zz)
            getCell():ConnectNewSquare(below, false)
        end
        below:EnsureSurroundNotNull()
        below:RecalcAllWithNeighbours(true)
    end
    sq:clearWater()
    sq:disableErosion()
    if isServer() then sendServerCommand("erosion", "disableForSquare", { x = x, y = y, z = z }) end
end

local function placeWindow(sq, obj, north)
    local index = -1
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do -- 窗、面向 S／E 的窗簾插在窗框（和窗）後面（ISMoveableSpriteProps.lua:2141-2170,2196-2210）
        local p = objects:get(i):getProperties()
        if p and p:has(north and F.WindowN or F.WindowW) then index = i + 1 end
    end
    finish(sq, obj, index)
end

-- 樓梯：照原版 BuildRecipeCode.stairs.OnCreate（buildRecipeCode.lua:219-336）。三片都是 IsoThumpable，buildMaterials 都寫
-- 整組的（Cost.forCells 收在頂片那一格；原版拆哪一片都照那片退）；照原版清掉這格的草（地毯留著）。頂端上一層補平台
-- 地板（addFloor 自己會同步，IsoGridSquare.java:4741-4789），記 ConnectedToStairs（同向的樓梯不能再蓋在平台上），
-- 平台與頂片正上方那格重算。補地板前先照一般地板只拆這一格的舊東西：addFloor 自己拆用預設的 safelyRemove，
-- 伺服器上多格的一組會整組拆（IsoGridSquare.java:4746-4763,5939-5966），動到沒驗證過的格子。
local function placeStairs(cells, placed)
    local set, west, top, landing = cells[1].cost, false, nil, nil
    for _, c in ipairs(cells) do
        if c.role == "platform" then
            landing = c
        else
            west = Rules.westStairs(c.spr:getType())
            local objects = c.sq:getObjects()
            for i = objects:size() - 1, 0, -1 do
                local o = objects:get(i)
                local op = o:getProperties()
                if op and (op:has(F.canBeRemoved) or (op:has(F.vegitation) and o:getType() ~= T.tree))
                    and not (o:getTextureName() or ""):find("floors_rugs", 1, true) then
                    c.sq:transmitRemoveItemFromSquare(o, false)
                end
            end
            local obj = thumpable({ sq = c.sq, spr = c.spr, cost = set }, "stairs", west)
            obj:setIsStairs(true)
            placed[#placed + 1] = obj
            finish(c.sq, obj)
            if c.role == "top" then top = c end
        end
    end
    local sq = landing.sq
    if not sq:has(F.solidfloor) then
        Place.clearFloor(sq)
        local floor = sq:addFloor(Entry.STAIR_FLOOR)
        placed[#placed + 1] = floor
        -- 拆樓梯時只拆本 MOD 補的平台（Server.dismantle）：一般 IsoObject、和原版補的同一張圖，只能記在伺服器帳本
        if MinidoracatBuilder.Ledger then MinidoracatBuilder.Ledger.put(floor, {}) end
    end
    sq:getModData()["ConnectedToStairs" .. tostring(not west)] = true
    sq:RecalcAllWithNeighbours(true)
    local above = Place.square(top.x, top.y, top.z + 1)
    if above then above:RecalcAllWithNeighbours(true) end
end

-- 燈：照原版搬動放燈（ISMoveableSpriteProps.lua:2325-2329）一律建 IsoLightSwitch，多格的每片一個。有 lightR 的自己發光、
-- 有電才亮（客戶端每片自己判斷）；沒有 lightR 的是開關，只控制地圖房間的燈（IsoLightSwitch.java:73-99）。
-- 能不能換燈泡由建構子照 IsMoveAble 設。擋路的照原版設 movedThumpable，殭屍打得壞（:2501-2504）。
-- IsoLightSwitch 沒有 buildMaterials：拆了退什麼記在伺服器帳本（server/MinidoracatBuilder/Ledger.lua）。
local function newLight(c)
    local sq, spr = c.sq, c.spr
    local p = spr:getProperties()
    local obj = IsoLightSwitch.new(getCell(), sq, spr, sq:getRoomID())
    obj:addLightSourceFromSprite()
    obj:setActivated(true)
    if c.yoff and c.yoff ~= 0 then obj:setRenderYOffset(c.yoff) end
    if p:has(F.solid) or p:has(F.solidtrans) then obj:setMovedThumpable(true) end
    obj:getModData().builderEntry = spr:getName()
    return obj
end

-- 依序放好 cells 的每一格（{ sq, spr, cost, yoff, role }）。物件一建好就記進 placed（之後出錯時拆回用；還沒加進格子的
-- 拆回時會略過）。丟錯由呼叫端 pcall 接。
function Place.build(kind, cells, placed)
    if kind == "stairs" then return placeStairs(cells, placed) end
    for _, c in ipairs(cells) do
        local sq, spr = c.sq, c.spr
        local north = Entry.north(kind, spr)
        local obj
        if kind == "door" then
            obj = IsoDoor.new(getCell(), sq, spr:getName(), north)
            placed[#placed + 1] = obj
            finish(sq, obj)
        elseif kind == "window" then
            obj = IsoWindow.new(getCell(), sq, spr, north)
            obj:setIsLocked(false)
            placed[#placed + 1] = obj
            placeWindow(sq, obj, north)
        elseif kind == "light" then
            obj = newLight(c)
            placed[#placed + 1] = obj
            finish(sq, obj)
            if MinidoracatBuilder.Ledger then MinidoracatBuilder.Ledger.put(obj, refundable(c.cost)) end
        elseif kind == "curtain" then
            -- 照原版搬動放窗上物件（ISMoveableSpriteProps.lua:2195-2210）：north＝面向 N 或 S
            local facing = spr:getProperties():get("Facing")
            obj = IsoCurtain.new(getCell(), sq, spr:getName(), north)
            obj:getModData().builderEntry = spr:getName()
            placed[#placed + 1] = obj
            if facing == "S" or facing == "E" then placeWindow(sq, obj, north) else finish(sq, obj) end
        else
            obj = thumpable(c, kind, north)
            -- 屋頂不擋整格；AddSpecialObject 不會重算下面幾層「有屋頂」（客戶端收到 AddItemToMap 才算，
            -- AddItemToMapPacket.java:69），伺服器自己算，存檔才對（bt-newkinds §5.2）
            if kind == "roof" then obj:setBlockAllTheSquare(false) end
            placed[#placed + 1] = obj
            if kind == "floor" then placeFloor(sq, obj) else finish(sq, obj) end
            if kind == "roof" then getCell():checkHaveRoof(sq:getX(), sq:getY()) end
        end
    end
end

-- 拆回這次已放的物件（放到一半出錯時）。多格的一組缺片時伺服器整組不拆（IsoObjectUtils.java:119-155），所以逐片拆。
-- 不在格子上的物件 transmitRemoveItemFromSquare 直接回 -1。
function Place.undo(placed)
    for i = #placed, 1, -1 do
        local obj = placed[i]
        local sq = obj:getSquare()
        if sq then sq:transmitRemoveItemFromSquare(obj, false) end
    end
end

-- 原版 Actions.build 的收尾（ActionManager.lua:29-31），不經過它就要自己做
function Place.settle(cells)
    for _, c in ipairs(cells) do
        c.sq:RecalcAllWithNeighbours(true)
        buildUtil.setHaveConstruction(c.sq, true)
    end
end

-- 本 MOD 蓋的 IsoThumpable 移出世界前清掉退料表：原版拆解、打壞都先讀退料表再移除（ISMoveableSpriteProps.lua:4323-4357、
-- ISBuildingObject.lua:51-69），已經移除的物件不該再退料。
function Place.onAboutToBeRemoved(obj)
    if not (instanceof(obj, "IsoThumpable") and obj:hasModData() and obj:getModData().builderEntry) then return end
    local mats, keys = obj:getBuildMaterials(), {}
    for k in pairs(mats) do keys[#keys + 1] = k end
    for i = 1, #keys do mats[keys[i]] = nil end
end
Events.OnObjectAboutToBeRemoved.Add(function(obj) MinidoracatBuilder.Place.onAboutToBeRemoved(obj) end)

return Place
