-- 放置：補格子、每格能不能放、依種類建立物件並同步。出處 bt-authority §2、§4.2。
-- 兩端共用：伺服器（單機在本機）放置；客戶端只用 Place.check 給游標預覽（Check.item 的 preview 不補格子，只查已有的格子）。
-- 通則：建好物件、設完屬性，才 AddSpecialObject（引擎自己更新室內判定與碰撞），再 transmit 一次。
-- 客戶端收到 AddItemToMap 不會去重，送兩次就變兩個（IsoObject.java:4430-4471）。
require "MinidoracatBuilder/Entry"

local Entry = MinidoracatBuilder.Entry
local Place = MinidoracatBuilder.Place or {}
MinidoracatBuilder.Place = Place

local F, T = IsoFlagType, IsoObjectType
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

-- 能不能在 sq 放 spr（種類 kind）。回 ok 與桌面高度（放在桌上的物件要墊高，原版搬家具算的）。
-- player 只給原版搬家具的判斷讀玩家所在格（窗上物件）；擺放技能與工具不查（placeTool 已清掉）。
function Place.check(kind, spr, sq, player)
    if sq:isVehicleIntersecting() or hasSprite(sq, spr:getName(), kind == "floor") then return false end
    local p = spr:getProperties()
    if kind == "floor" then
        -- 原版 BuildRecipeCode.floor.OnIsValid（buildRecipeCode.lua:338-361）
        return not sq:HasStairsBelow() and sq:connectedWithFloor()
    end
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

-- 退料只寫在伺服器建立的 Java 欄位 buildMaterials（原版拆解讀它）；modData 只放顯示用的資料
-- 門框照原版不給打（entity 門框腳本都是 isThumpable = false）：thumpable 的 IsoThumpable 會被 getSpecialWall 當成牆，
-- 門開著也走不過去（IsoGridSquare.java:3804-3818）
local HEALTH = { wall = 450, windowFrame = 450, fence = 300 }
-- 會擋路的家具、容器、實心物件照原版搬家具放下（ISMoveableSpriteProps.lua:2330,2379-2388）：殭屍打得壞，一隻就能打
-- （thumpDmg 1，IsoThumpable.java:1029-1041），而且整格擋住，不然會被 getSpecialWall 當成格邊的牆（IsoGridSquare.java:3804-3818）。
-- 原版特地讓放下的擋路物件都打得壞（ISMoveableSpriteProps.lua:2501-2504）。地毯、掛牆物、放在桌上的照原版不打。
local function blocking(p)
    if not (p:has(F.solid) or p:has(F.solidtrans)) or p:has("IsTableTop") then return false end
    local mt = p:get("MoveType")
    return mt ~= "FloorRug" and mt ~= "WallObject"
end
-- 血量照原版：搬運重量（沒寫當 50）× 材質倍率（ISMoveableSpriteProps.lua:148,322-325；ISMoveableDefinitions.lua:688-690）
local function furnitureHealth(p)
    local mat = p:get("Material")
    local m = mat and ISMoveableDefinitions:getInstance().getHealthDefinition(mat) or 1
    return (tonumber(p:get("PickUpWeight")) or 50) * m
end
local function thumpable(c, kind, north)
    local sq, spr = c.sq, c.spr
    local p = spr:getProperties()
    local obj = IsoThumpable.new(getCell(), sq, spr:getName(), north, {})
    local furniture = not Entry.EDGE[kind] and blocking(p)
    -- 屬性照原版 entity 建造推（ISBuildIsoEntity:setInfo，ISBuildIsoEntity.lua:611-628）
    obj:setCanPassThrough(not (p:has(F.solid) or p:has(F.solidtrans) or p:has(F.WallN) or p:has(F.WallNTrans)
        or p:has(F.WallW) or p:has(F.WallWTrans) or p:has(F.WallNW)))
    obj:setBlockAllTheSquare(furniture or p:has("BlocksPlacement"))
    obj:setIsHoppable(kind == "fence")
    obj:setIsDoorFrame(kind == "doorFrame")
    obj:setCanBarricade(kind == "windowFrame")
    obj:setIsFloor(kind == "floor")
    local hp = HEALTH[kind]
    if furniture then
        hp = furnitureHealth(p)
        obj:setThumpDmg(1)
        obj:setBreakSound(IsoThumpable.GetBreakFurnitureSound(spr:getName()))
    end
    obj:setIsThumpable(hp ~= nil) -- 門框、地板、不擋路的家具照原版不打
    obj:setIsDismantable(true)
    hp = hp or 200
    obj:setMaxHealth(hp)
    obj:setHealth(hp)
    if c.yoff and c.yoff ~= 0 then obj:setRenderYOffset(c.yoff) end -- 放在桌上（ISMoveableSpriteProps.lua:2468-2479）
    local mats, fee = obj:getBuildMaterials(), c.cost.fee or {}
    for ft, n in pairs(c.cost.items) do
        local v = n - (fee[ft] or 0) -- 電器費拆了不退（Cost.of）
        if v > 0 then mats[ft] = tostring(v) end
    end
    obj:getModData().builderEntry = spr:getName()
    -- 水槽這類接水管的：照原版搬家具，放好要重新接水管才有水（ISMoveableSpriteProps.lua:2491-2494；IsoObject.java:2632-2636）
    if p:has(F.waterPiped) then obj:getModData().canBeWaterPiped = true end
    return obj
end

-- 地板：照原版 floor.OnCreate（buildRecipeCode.lua:364-418），差別是先拆舊的再放新的（同一格先刪後加，索引才對得上，
-- bt-authority §2.1-4），地毯留著、新地板插在地毯前面。舊物件只拆這一格的那片：多格的一組照原版整組拆
-- 會動到沒驗證過的格子（IsoGridSquare.java:5942-5965）。
local function removeForFloor(sq)
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
    local index = removeForFloor(sq)
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
    for i = 0, objects:size() - 1 do -- 窗插在窗框後面（ISMoveableSpriteProps.lua:2141-2170）
        local p = objects:get(i):getProperties()
        if p and p:has(north and F.WindowN or F.WindowW) then index = i + 1 end
    end
    finish(sq, obj, index)
end

-- 依序放好 cells 的每一格（{ sq, spr, cost, yoff }）。物件一建好就記進 placed（之後出錯時拆回用；還沒加進格子的
-- 拆回時會略過）。丟錯由呼叫端 pcall 接。
function Place.build(kind, cells, placed)
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
        else
            obj = thumpable(c, kind, north)
            placed[#placed + 1] = obj
            if kind == "floor" then placeFloor(sq, obj) else finish(sq, obj) end
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

return Place
