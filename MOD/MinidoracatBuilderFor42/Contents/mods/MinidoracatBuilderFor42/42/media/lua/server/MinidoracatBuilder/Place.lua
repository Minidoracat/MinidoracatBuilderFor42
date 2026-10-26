-- 放置（伺服器；單機在本機跑）：補格子、每格能不能放、依種類建立物件並同步。出處 bt-authority §2、§4.2。
-- 通則：建好物件、設完屬性，才 AddSpecialObject（引擎自己更新室內判定與碰撞），再 transmit 一次。
-- 客戶端收到 AddItemToMap 不會去重，送兩次就變兩個（IsoObject.java:4430-4471）。
if isClient() then return end
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

-- 這條格邊已經有東西（牆、牆角、門框、窗框、柵欄、門、窗）
local function edgeTaken(sq, north)
    if north then
        return sq:has(F.WallN) or sq:has(F.WallNTrans) or sq:has(F.WallNW) or sq:has(F.DoorWallN) or sq:has(F.WindowN)
            or sq:has(F.HoppableN) or sq:has(F.TallHoppableN) or sq:getDoor(NS) ~= nil or sq:getWindow(NS) ~= nil
    end
    return sq:has(F.WallW) or sq:has(F.WallWTrans) or sq:has(F.WallNW) or sq:has(F.DoorWallW) or sq:has(F.WindowW)
        or sq:has(F.HoppableW) or sq:has(F.TallHoppableW) or sq:getDoor(EW) ~= nil or sq:getWindow(EW) ~= nil
end

local function floorUnder(sq)
    return sq:getZ() == 0 or sq:getFloor() ~= nil
end

local function vegetation(sq)
    return sq:has(F.canBeCut) or sq:has("tree")
end

-- 能不能在 sq 放 spr（種類 kind）。player 只給原版移動物件的判斷用（它順便查擺放技能與工具，照原版搬家具）。
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
            -- 門要放進同方向、還沒有門的門框（原版 isValidPerSquare：有門框、沒有門）
            return (n and sq:has(F.DoorWallN) and sq:getDoor(NS) == nil)
                or (w and sq:has(F.DoorWallW) and sq:getDoor(EW) == nil)
        end
        if kind == "window" then
            return (n and sq:has(F.WindowN) and sq:getWindow(NS) == nil)
                or (w and sq:has(F.WindowW) and sq:getWindow(EW) == nil)
        end
        if not floorUnder(sq) and not sq:hasFloor(n) then return false end -- 樓上的牆要踩在地板上（ISWoodenWall:isValid）
        if not n and not w then return not sq:has(F.WallSE) end           -- 柱子
        return not ((n and edgeTaken(sq, true)) or (w and edgeTaken(sq, false)))
    end
    if p:has("IsMoveAble") then
        -- 原版搬家具放下的判斷（地板、桌面、掛牆要有牆、窗上物件要有窗框、地毯不疊…），伺服器能跑（bt-authority §4.2）
        return ISMoveableSpriteProps.new(spr):canPlaceMoveableInternal(player, sq, nil) == true
    end
    if not floorUnder(sq) or vegetation(sq) then return false end
    if kind == "solid" then return not (sq:has("BlocksPlacement") and not sq:has(F.canBeRemoved)) end
    return true
end

-- ---------------------------------------------------------------- 建立
local function finish(sq, obj, index)
    sq:AddSpecialObject(obj, index or -1)
    obj:setExplored(true) -- 蓋出來的容器不生戰利品（ISBuildIsoEntity.lua:736-737）
    obj:transmitCompleteItemToClients()
end

-- 建造者紀錄與退料：modData 客戶端改得到（ObjectModDataPacket），所以退料只寫 Java 欄位 buildMaterials（原版拆解讀它）
local HEALTH = { wall = 450, windowFrame = 450, doorFrame = 450, fence = 300 }
local function thumpable(sq, spr, kind, north, cost)
    local p = spr:getProperties()
    local obj = IsoThumpable.new(getCell(), sq, spr:getName(), north, {})
    -- 屬性照原版 entity 建造推（ISBuildIsoEntity:setInfo，ISBuildIsoEntity.lua:611-628）
    obj:setCanPassThrough(not (p:has(F.solid) or p:has(F.solidtrans) or p:has(F.WallN) or p:has(F.WallNTrans)
        or p:has(F.WallW) or p:has(F.WallWTrans) or p:has(F.WallNW)))
    obj:setBlockAllTheSquare(p:has("BlocksPlacement"))
    obj:setIsHoppable(kind == "fence")
    obj:setIsDoorFrame(kind == "doorFrame")
    obj:setCanBarricade(kind == "windowFrame")
    obj:setIsFloor(kind == "floor")
    obj:setIsThumpable(HEALTH[kind] ~= nil) -- 殭屍只打牆、框、柵欄；家具照原版不打
    obj:setIsDismantable(true)
    local hp = HEALTH[kind] or 200
    obj:setMaxHealth(hp)
    obj:setHealth(hp)
    local mats = obj:getBuildMaterials()
    for ft, n in pairs(cost.items) do mats[ft] = tostring(n) end
    obj:getModData().builderEntry = spr:getName() -- 只給畫面顯示，不拿來授權或計價
    return obj
end

-- 地板：照原版 floor.OnCreate（buildRecipeCode.lua:364-418），差別是先拆舊的再放新的（同一格先刪後加，索引才對得上，
-- bt-authority §2.1-4），地毯留著、新地板插在地毯前面。
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
            sq:transmitRemoveItemFromSquare(o)
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

-- IsoDoor 會把同一張表 +2 號當開門的圖（開著的那張則 −2，IsoDoor.java:856-868）；那一號不存在時引擎會建一個空 sprite
local function doorPairExists(spr)
    local tileset, num = spr:getName():match("^(.*)_(%d+)$")
    local d = spr:getProperties():has(F.open) and -2 or 2
    return tileset ~= nil and Entry.sprite(tileset .. "_" .. (tonumber(num) + d)) ~= nil
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

-- 依序放好 cells 的每一格（{ sq, spr, cost }），放好的物件記進 placed（失敗時拆回用）。丟錯由呼叫端 pcall 接。
function Place.build(kind, cells, placed)
    for _, c in ipairs(cells) do
        local sq, spr = c.sq, c.spr
        local north = Entry.north(kind, spr)
        local obj
        if kind == "door" then
            if not doorPairExists(spr) then error("door sprite has no open/closed pair: " .. spr:getName()) end
            obj = IsoDoor.new(getCell(), sq, spr:getName(), north)
            finish(sq, obj)
        elseif kind == "window" then
            obj = IsoWindow.new(getCell(), sq, spr, north)
            obj:setIsLocked(false)
            placeWindow(sq, obj, north)
        else
            obj = thumpable(sq, spr, kind, north, c.cost)
            if kind == "floor" then placeFloor(sq, obj) else finish(sq, obj) end
        end
        placed[#placed + 1] = obj
    end
end

-- 拆回這次已放的物件（放到一半出錯時）。多格的一組缺片時伺服器整組不拆（IsoObjectUtils.java:119-155），所以逐片拆。
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
