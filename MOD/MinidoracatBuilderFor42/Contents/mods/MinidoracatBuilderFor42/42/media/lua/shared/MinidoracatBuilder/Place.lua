-- 放置：補格子、每格能不能放、依種類建立物件並同步。出處 bt-authority §2、§4.2。
-- 兩端共用：伺服器（單機在本機）放置；客戶端只用 Place.check 給游標預覽（Check.item 的 preview 不補格子，只查已有的格子）。
-- 通則：建好物件、設完屬性，才 AddSpecialObject（引擎自己更新室內判定與碰撞），再 transmit 一次。
-- 客戶端收到 AddItemToMap 不會去重，送兩次就變兩個（IsoObject.java:4430-4471）。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Cost"

local Entry, Rules, Cost = MinidoracatBuilder.Entry, MinidoracatBuilder.Rules, MinidoracatBuilder.Cost
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

-- 同一張圖不重複放（buildRecipeCode.lua:345-353）
local function hasSprite(sq, name)
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local spr = objects:get(i):getSprite()
        if spr and spr:getName() == name then return true end
    end
    return false
end

-- 農作物上不蓋地板（同處，農作物有 Lua 行為）
local function hasCrop(sq)
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local spr = objects:get(i):getSprite()
        local s = spr and spr:getName()
        if s and s:sub(1, 18) == "vegetation_farming" then return true end
    end
    return false
end

-- 格子有這個屬性（旗標或字串鍵）。skip＝要被原地替換掉的那件（Check.item 的 info.replace）：格子的屬性是各物件屬性的
-- 聯集（IsoGridSquare.RecalcProperties，IsoGridSquare.java:7250-7264），所以有 skip 時逐件看、跳過它
local function has(sq, k, skip)
    if not sq:has(k) then return false end
    if not skip then return true end
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        if o ~= skip then
            local p = o:getProperties()
            if p and p:has(k) then return true end
        end
    end
    return false
end

-- obj 的附加圖（地圖的地面、牆面疊圖，本 MOD 掛的地面覆蓋）裡最後一張叫 name 的位置（0 起算），沒有回 nil
local function attachedAt(obj, name)
    local list = obj and obj:getAttachedAnimSprite()
    for i = (list and list:size() or 0) - 1, 0, -1 do
        local spr = list:get(i):getParentSprite()
        if spr and spr:getName() == name then return i end
    end
    return nil
end
Place.attachedAt = attachedAt

-- 一個物件存檔與同步只帶前 255 張附加圖（IsoObject.java:1359、4630-4635；張數只用 1 byte），再多就會消失
local MAX_ATTACHED = 255
local function attachedCount(obj)
    local list = obj and obj:getAttachedAnimSprite()
    return list and list:size() or 0
end

-- 這條格邊已經有東西：牆、牆角、門框、窗框、柵欄、門、窗，以及其他擋這條邊的物件
-- （原版 isObjectSpriteBlockingWallPlacement 看 collideN/W，ISBuildIsoEntity.lua:150-166）。skip 見 has
local function edgeTaken(sq, north, skip)
    if north then
        return has(sq, F.WallN, skip) or has(sq, F.WallNTrans, skip) or has(sq, F.WallNW, skip) or has(sq, F.collideN, skip)
            or has(sq, F.DoorWallN, skip) or has(sq, "DoorWallNTrans", skip) or has(sq, F.WindowN, skip)
            or has(sq, F.HoppableN, skip) or has(sq, F.TallHoppableN, skip) or sq:getDoor(NS) ~= nil or sq:getWindow(NS) ~= nil
    end
    return has(sq, F.WallW, skip) or has(sq, F.WallWTrans, skip) or has(sq, F.WallNW, skip) or has(sq, F.collideW, skip)
        or has(sq, F.DoorWallW, skip) or has(sq, "DoorWallWTrans", skip) or has(sq, F.WindowW, skip)
        or has(sq, F.HoppableW, skip) or has(sq, F.TallHoppableW, skip) or sq:getDoor(EW) ~= nil or sq:getWindow(EW) ~= nil
end

local function doorFrameAt(sq, north)
    if north then return sq:has(F.DoorWallN) or sq:has("DoorWallNTrans") end
    return sq:has(F.DoorWallW) or sq:has("DoorWallWTrans")
end

-- 牆不能把既有的多格家具切開（ISBuildIsoEntity.lua:388-399）：北邊的牆擋 grid y > 0 的片，西邊擋 x > 0
local function splitsGrid(sq, n, w, skip)
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        local spr = o ~= skip and o:getSprite()
        local grid = spr and spr:getSpriteGrid()
        if grid and ((n and grid:getSpriteGridPosY(spr) > 0) or (w and grid:getSpriteGridPosX(spr) > 0)) then
            return true
        end
    end
    return false
end

-- IsoDoor 會把同一張表 +2 號當開門的圖（IsoDoor.java:856-868；開著的那張 Rules 不列）；那一號不存在時引擎會建一個空 sprite
local function doorPairExists(spr)
    local tileset, num = spr:getName():match("^(.*)_(%d+)$")
    return tileset ~= nil and Entry.sprite(tileset .. "_" .. (tonumber(num) + 2)) ~= nil
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
    if sq:isVehicleIntersecting() then return false, "VEHICLE" end
    if z >= getMaximumWorldLevel() or sq:HasStairs() then return false end
    if sq:hasModData() and sq:getModData()["ConnectedToStairs" .. tostring(not west)] then return false end
    local above = getCell():getGridSquare(x, y, z + 1)
    if above and above:getFloor() then return false end
    if role == "top" and above and above:getWall(not west) then return false end
    if not floorUnder(sq) or vegetation(sq) or sq:has(F.water) or sq:has(F.taintedWater) then return false end
    if sq:isSolid() or sq:isSolidTrans() or (sq:has("BlocksPlacement") and not sq:has(F.canBeRemoved)) then return false end
    if not sq:getMovingObjects():isEmpty() then return false, "OCCUPIED" end
    return not buildUtil.stairIsBlockingPlacement(sq, true)
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

-- 原版疊箱子的高度上限（ISMoveableSpriteProps.lua:1772-1776）：可疊的桌類放在桌類上，總高加上自己的 Surface 不超過 96
local STACK_MAX = 96

-- 能不能在 sq 放 spr（種類 kind）。成功回 true 與桌面高度（放在桌上、疊上去的物件要墊高，原版搬家具算的）；
-- 失敗回 false 與原因碼（游標分原因說；nil＝其他，Check.item 回 BLOCKED）：
--   SAME_TILE：同一格已經有同一張圖（不是可疊的）。VEHICLE：車子壓著。OCCUPIED：會擋路的東西那格有人、殭屍或動物。
--   STACK_FULL：可疊的箱子疊到原版的高度上限。
-- player 只給原版搬家具的判斷讀玩家所在格（窗上物件）；擺放技能與工具不查（placeTool 已清掉）。
-- role：多格項目裡這一格的角色（Entry.cells 第 5 欄；目前只有樓梯有）。planned：見 Place.roofAt。
-- replacing：要被原地替換掉的那件（Check.item 的 info.replace.obj）：它佔的格邊、它的實心與擋放置都不算擋；
-- 同一張圖照樣擋（同一張不算替換）。原版搬家具的判斷（IsMoveAble）不能叫它跳過，照舊看整格。
function Place.check(kind, spr, sq, player, role, planned, replacing)
    if kind == "stairs" then return stairsOk(spr, sq, role) end
    if sq:isVehicleIntersecting() then return false, "VEHICLE" end
    local p = spr:getProperties()
    -- 可疊的（IsStackable：軍用箱、紙箱這類）同一張也能疊，高度交給下面原版搬家具的判斷
    if not p:has("IsStackable") and hasSprite(sq, spr:getName()) then return false, "SAME_TILE" end
    if kind == "floor" and hasCrop(sq) then return false end
    if Rules.onFloor(kind, spr) then
        -- 掛在地板上（Place.attach）：要有地板、地板上還沒有同一張（地圖原有的也算）、附加圖還沒滿；不蓋在高草、樹上
        local floor = sq:getFloor()
        if floor and attachedAt(floor, spr:getName()) then return false, "SAME_TILE" end
        return floor ~= nil and attachedCount(floor) < MAX_ATTACHED and not vegetation(sq)
    end
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
        if not n and not w then return not has(sq, F.WallSE, replacing) end -- 柱子
        return not ((n and edgeTaken(sq, true, replacing)) or (w and edgeTaken(sq, false, replacing))
            or splitsGrid(sq, n, w, replacing))
    end
    -- 會擋路的東西：格上有人、殭屍或動物，或會擋到樓梯時不放（原版 isFree(true)、stairIsBlockingPlacement）
    if p:has(F.solid) or p:has(F.solidtrans) then
        if not sq:getMovingObjects():isEmpty() then return false, "OCCUPIED" end
        if buildUtil.stairIsBlockingPlacement(sq, true) then return false end
    end
    if p:has("IsMoveAble") then
        -- 原版搬家具放下的判斷（地板、桌面、掛牆要有牆、窗上物件要有窗框、地毯不疊、箱子疊多高…），伺服器能跑（bt-authority §4.2）。
        -- 成功時回的不一定是 true（掛牆時回那面牆），照真假看。
        local props = ISMoveableSpriteProps.new(spr)
        -- 不要求原版的擺放技能與工具（設計稿：工具照 Cost）：placeTool 是 nil 時 hasRequiredSkill／hasTool 都放行（:1956-1961）
        props.placeTool = nil
        if not props:canPlaceMoveableInternal(player, sq, nil) then
            -- 疊到頂：照原版疊箱子那一支的條件重算一次，只差高度
            if props.isStackable and props.isTable and props.surface and sq:has("IsTable") and not sq:has("IsTableTop")
                and not sq:has("IsHigh") and props:getTotalTableHeight(sq) + props.surface > STACK_MAX then
                return false, "STACK_FULL"
            end
            return false
        end
        return true, (props.isTableTop or props.isTable) and props.yOffsetCursor or 0
    end
    if not floorUnder(sq) or vegetation(sq) then return false end
    -- 實心或擋放置的東西（含不能搬的實心容器）不疊在已經實心、已經擋放置的格子上
    if kind == "solid" or kind == "container" or p:has(F.solid) or p:has(F.solidtrans) then
        local solid = replacing and (has(sq, F.solid, replacing) or has(sq, F.solidtrans, replacing))
            or (not replacing and (sq:isSolid() or sq:isSolidTrans()))
        return not solid and not (has(sq, "BlocksPlacement", replacing) and not sq:has(F.canBeRemoved))
    end
    return true
end

-- ---------------------------------------------------------------- 建立
local function finish(sq, obj, index)
    sq:AddSpecialObject(obj, index or -1) -- 會呼叫 addToWorld，照 sprite 的 container 屬性建容器（IsoObject.java:4502-4504）
    obj:setExplored(true) -- 所以排在這之後：蓋出來的容器不生戰利品（ISBuildIsoEntity.lua:736-737）
    Place.fitContainers(obj) -- 容器也是 addToWorld 建的；容量跟著下一行送給玩家
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

-- 一樓以下（含地下室）的地板：buildMaterials 留空，也不給原版搬動工具拆（isDismantable＝false）；本工具會拆的退料記在
-- 伺服器的地板帳本（Floors）。見 builder-dev placement.md「一樓地板的退料」
local function groundFloor(obj, sq)
    if sq:getZ() > 0 then return false end
    if obj:isFloor() then return true end
    local spr = obj:getSprite()
    return spr ~= nil and spr:getProperties():has(F.solidfloor)
end
Place.groundFloor = groundFloor

-- 這一格除了 obj 之外還有 IsoThumpable 的地板（照建的時候設的 isFloor）
local function otherFloor(sq, obj)
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        if o ~= obj and instanceof(o, "IsoThumpable") and o:isFloor() then return true end
    end
    return false
end

-- 拆了退什麼（Server.dismantle 讀，只在伺服器）：一樓以下的地板照地板帳本，現在的圖和蓋的時候一樣、這一格只有
-- 它一片地板才退；其他照 buildMaterials。單機讀檔時帳本建好之前讀進來、還沒搬的舊地板照 buildMaterials
-- （Place.migrate）。都沒有回 nil。
function Place.refundOf(obj)
    local sq = obj:getSquare()
    if not (sq and sq:getZ() <= 0 and obj:isFloor()) then return obj:getBuildMaterials() end
    local Floors = MinidoracatBuilder.Floors
    local e = Floors and Floors.get(obj)
    if e then
        local spr = obj:getSprite()
        return spr and e.s == spr:getName() and not otherFloor(sq, obj) and e.i or nil
    end
    if isServer() or not obj:hasBuildMaterials() then return nil end -- 專用伺服器讀格子前就建好帳本，都搬過了
    return obj:getBuildMaterials()
end

local function wipe(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    for i = 1, #keys do t[keys[i]] = nil end
end

-- 退料寫在伺服器建立的 Java 欄位 buildMaterials（原版拆解讀它），一樓以下的地板改記在地板帳本（groundFloor）；
-- 退多少不看 modData
-- 門框照原版不給打（entity 門框腳本都是 isThumpable = false）：thumpable 的 IsoThumpable 會被 getSpecialWall 當成牆，
-- 門開著也走不過去（IsoGridSquare.java:3804-3818）
-- 樓梯照 Wood_Stairs 剛好 6 級、沒有建造加成時的血量：health 150＋最高相關技能等級 6 × skillBaseHealth 50
-- （stairs/entity_carpentry_stairs.txt；ISBuildIsoEntity.lua:657-668，等級越高原版越耐打）
local HEALTH = { wall = 450, windowFrame = 450, fence = 300, stairs = 450, post = 450 }
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
-- 照種類與圖塊算耐久與 thumpDmg（hp 是 nil＝照原版不打：門框、地板、不擋路的東西；dmg 是 nil＝不改預設）
local function isSolid(kind, p) return not Entry.EDGE[kind] and (p:has(F.solid) or p:has(F.solidtrans)) end
local function durability(kind, p)
    if isSolid(kind, p) then return solidHealth(p) end
    return HEALTH[kind], nil
end
-- 沙盒「殭屍打不壞」（ZombieProof，使用者 2026-11-01 選「不打，也不找路穿過」）：IsoThumpable 不給打，原生尋路把它當一般的牆
-- （getThumpableFor 看 isThumpable，IsoThumpable.java:1093-1126；nativeCode/SquareUpdateTask.java:334-381），玩家武器也打不到
-- （:1148-1157,1564），大錘不看它（ISDestroyCursor.lua:293-361）。爬行殭屍對低柵欄不看 isThumpable（:1111-1117），所以 thumpDmg
-- 也調到最大：每下只扣「圍著打的殭屍數 ÷ thumpDmg」（:1029-1041）。PROOF_DMG 減 0..3 同時是「照選項改過」的記號（引擎欄位、
-- 隨存檔，不靠 modData），減的數記改之前的樣子：1＝原本可打，2＝原本 thumpDmg 是 1（不然是預設 8）。關掉時照它還原，
-- 不重新分類（Rules 改版、圖塊換成損壞圖時分類會變）
local PROOF_DMG = 2147483647
local function proofDmg(thump, dmg) return PROOF_DMG - (thump and 1 or 0) - (dmg == 1 and 2 or 0) end
-- 沙盒「殭屍敲不破門」（ZombieProofDoors，使用者 2026-11-01 要求和上面分開）：門沒有不給打的旗標（IsoDoor.java:1246-1260），
-- 只能把耐久調高；maxHealth 沒有 setter（:2401,2639），關掉時夾回 maxHealth（建構子照圖塊設的，:807-821）
local DOOR_HP = 1000000000
local function proof(key) return Entry.settings()[key] == true end
local function thumpable(c, kind, north)
    local sq, spr = c.sq, c.spr
    local p = spr:getProperties()
    local obj = IsoThumpable.new(getCell(), sq, spr:getName(), north, {})
    local solid = isSolid(kind, p)
    -- 柱子照原版補的轉角柱（ISBuildUtil.lua:89-93）：轉角、不可穿過（IsoThumpable 預設 false，IsoThumpable.java:107）。
    --   不設轉角的話 north＝false 的柱子會被當成這一格的西牆，殭屍走過西邊那條線時把它當目標打（IsoGridSquare.java:3816
    --   getSpecialWall、:4027 testCollideSpecialObjects、IsoZombie.java:3681）。可穿過的話原生尋路找格邊能不能打時，
    --   遇到它就回「不能打」，連同一格的牆也遮掉（nativeCode/SquareUpdateTask.java:356-381 遇到第一個 IsoThumpable 就回）。
    --   斜走會被擋，和原版一樣（IsoThumpable.java:896-915）。擋格邊的圖 Rules 不列（BLOCKS_EDGE），柱子都不擋格邊
    local corner = kind == "post"
    -- 其餘屬性照原版 entity 建造推（ISBuildIsoEntity:setInfo，ISBuildIsoEntity.lua:611-628）
    obj:setCanPassThrough(not corner and not (p:has(F.solid) or p:has(F.solidtrans) or p:has(F.WallN)
        or p:has(F.WallNTrans) or p:has(F.WallW) or p:has(F.WallWTrans) or p:has(F.WallNW)))
    obj:setBlockAllTheSquare(solid or p:has("BlocksPlacement"))
    obj:setIsHoppable(kind == "fence")
    obj:setIsDoorFrame(kind == "doorFrame")
    obj:setCorner(corner)
    obj:setCanBarricade(kind == "windowFrame")
    obj:setIsFloor(kind == "floor")
    local hp, dmg = durability(kind, p)
    if proof("ZombieProof") then
        obj:setThumpDmg(proofDmg(hp ~= nil, dmg))
        obj:setIsThumpable(false)
    else
        if dmg then obj:setThumpDmg(dmg) end
        obj:setIsThumpable(hp ~= nil) -- 門框、地板、不擋路的東西照原版不打
    end
    obj:setIsDismantable(not groundFloor(obj, sq))
    hp = hp or 200
    obj:setMaxHealth(hp)
    -- 原地替換照舊件剩下的耐久比例（c.wear，Server.complete 給）：換一款不能順便修好被打壞的
    obj:setHealth(c.wear and math.max(1, math.floor(hp * c.wear)) or hp)
    if c.yoff and c.yoff ~= 0 then obj:setRenderYOffset(c.yoff) end -- 放在桌上（ISMoveableSpriteProps.lua:2468-2479）
    if not groundFloor(obj, sq) then
        local mats = obj:getBuildMaterials()
        for ft, v in pairs(refundable(c.cost)) do mats[ft] = tostring(v) end
    end
    obj:getModData().builderEntry = spr:getName()
    -- 名稱一定要有：爬窗框時引擎拿 IsoThumpable 的名稱比 "Barbed Fence"（ClimbThroughWindowState.java:582），null 就
    -- NullPointerException、每幀一次、角色卡在窗框前（E2E builder-batch-1101rg2）。原版建造一律 setName（ISBuildUtil.lua:371）；
    -- 這裡用圖名（不是顯示名稱：物件名稱會存檔並同步）
    obj:setName(spr:getName())
    -- 水槽這類接水管的：照原版搬家具，放好要重新接水管才有水（ISMoveableSpriteProps.lua:2491-2494；IsoObject.java:2632-2636）
    if p:has(F.waterPiped) then obj:getModData().canBeWaterPiped = true end
    return obj
end

-- 地板：照原版 floor.OnCreate（buildRecipeCode.lua:364-418），差別是先拆舊的再放新的（同一格先刪後加，索引才對得上，
-- bt-authority §2.1-4），地毯留著、新地板插在地毯前面。舊物件只拆這一格的那片：多格的一組照原版整組拆
-- 會動到沒驗證過的格子（IsoGridSquare.java:5942-5965）。IsoThumpable 的地板照建的時候設的 isFloor 拆，不看現在的圖：
-- 地板帳本一格只記一筆（Floors）。
function Place.clearFloor(sq)
    local objects, rug = sq:getObjects(), nil
    for i = objects:size() - 1, 0, -1 do
        local o = objects:get(i)
        local p = o:getProperties()
        local tex = o:getTextureName() or ""
        if instanceof(o, "IsoThumpable") and o:isFloor() then
            sq:transmitRemoveItemFromSquare(o, false)
        elseif tex:find("floors_rugs", 1, true) then
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
-- 有電才亮（客戶端每片自己判斷）；沒有 lightR 的是開關，原版只控制地圖房間的燈（IsoLightSwitch.java:73-99），線路上的燈由
-- 伺服器 Circuits 切（放好後 Server.complete 呼叫 Circuits.placed 自動接線）。
-- 能不能換燈泡由建構子照 IsMoveAble 設。擋路的照原版設 movedThumpable，殭屍打得壞（:2501-2504）；沙盒「殭屍打不壞」打開時不設。
-- IsoLightSwitch 沒有 buildMaterials：拆了退什麼記在伺服器帳本（server/MinidoracatBuilder/Ledger.lua）。
local function newLight(c)
    local sq, spr = c.sq, c.spr
    local p = spr:getProperties()
    local obj = IsoLightSwitch.new(getCell(), sq, spr, sq:getRoomID())
    obj:addLightSourceFromSprite()
    -- 燈蓋好就開（同原版搬燈，ISMoveableSpriteProps.lua:2329）。格子有房間時，開關（沒有 lightR）沿用建構子照房間設的狀態
    -- （IsoLightSwitch.java:89-95）：強制開的話房間燈關著時開關顯示開、房間暗，第一次按看起來沒反應。有房間的是地圖房屋，
    -- 單機的自建房屋也是（客戶端與伺服器同一份世界）；MP 伺服器上自建房屋沒有房間（IsoRegions.java:212-214），照樣開
    if p:has("lightR") or not sq:getRoom() then obj:setActivated(true) end
    if c.yoff and c.yoff ~= 0 then obj:setRenderYOffset(c.yoff) end
    if (p:has(F.solid) or p:has(F.solidtrans)) and not proof("ZombieProof") then obj:setMovedThumpable(true) end
    obj:getModData().builderEntry = spr:getName()
    return obj
end

-- ---------------------------------------------------------------- 掛在地板上的地面覆蓋（Rules.onFloor）
-- 圖掛在那格地板的附加圖上（地圖讀檔同一種，CellLoader.java:256-264），不建物件。transmitUpdatedSpriteToClients 把整串
-- 附加圖送給客戶端（IsoObject.java:4614-4645；客戶端照 sprite id 重掛、重畫那格，GameClient.java:1122-1162），跟著地板存檔。
-- 地板 modData 的 builderOverlays（{ [圖名] = true }）只決定右鍵選單列不列；拆了退什麼只看伺服器的覆蓋帳本
-- （server/MinidoracatBuilder/Overlays.lua）。地板物件被移除（換地板、拆地板）時圖跟著舊地板走（地圖的標線也是），
-- 帳本照 Place.onAboutToBeRemoved 整格清掉。不觸發移除事件的原版動作不清：鏟地只拿掉附加圖；火燒對一般地板只拿掉
-- 附加圖、IsoThumpable 地板直接換成新物件。見 builder-dev placement.md「掛在地板上的地面覆蓋」。
local LOG = "[MinidoracatBuilderFor42] "
local function at(sq) return sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ() end

local function mark(floor, name, on)
    local md = floor:getModData()
    local own = type(md.builderOverlays) == "table" and md.builderOverlays or {}
    own[name] = on or nil
    local any = false
    for _ in pairs(own) do
        any = true
        break
    end
    md.builderOverlays = any and own or nil
end

-- 在 sq 的地板掛上 spr，寫記號、同步、記帳本（items＝拆了退什麼）。拆回用的紀錄（Place.undo；attached 欄位分辨紀錄與
-- 物件）在掛上之前就記進 placed（給了的話），後面幾步出錯時照樣拆得回；也當回傳值。附加圖滿了丟錯（Place.check 已擋）。
function Place.attach(sq, spr, items, placed)
    local floor, name = sq:getFloor(), spr:getName()
    if attachedCount(floor) >= MAX_ATTACHED then error("floor overlays full at " .. at(sq)) end
    local rec = { attached = true, floor = floor, name = name }
    if placed then placed[#placed + 1] = rec end
    floor:addAttachedAnimSprite(spr)
    mark(floor, name, true)
    floor:transmitUpdatedSpriteToClients()
    floor:transmitModData()
    local Overlays = MinidoracatBuilder.Overlays
    if Overlays then Overlays.put(sq, name, items) end
    return rec
end

-- 拿掉 floor 上最後一張叫 name 的附加圖與記號並同步，回有沒有拿掉。引擎丟的例外 Kahlua 只記 log、不往上丟
-- （MethodCaller.java:34-43），所以照張數確認真的少了一張。帳本由呼叫端清（拆除要先讀退料再拿掉）
function Place.detach(floor, name)
    local i = attachedAt(floor, name)
    if not i then return false end
    local n = attachedCount(floor)
    floor:RemoveAttachedAnim(i)
    if attachedCount(floor) ~= n - 1 then return false end
    mark(floor, name, false)
    floor:transmitUpdatedSpriteToClients()
    floor:transmitModData()
    return true
end

-- 0.2.0 以前蓋的地面覆蓋是獨立的 IsoThumpable：改掛到那格的地板，退料照它的 buildMaterials 記進覆蓋帳本（只在伺服器、
-- 帳本建好之後；排隊見 Place.migrate）。當下逐項再確認：還在目前載入的那一格、記號和圖一樣、現在的圖仍會掛在地板上、
-- 物件是舊版蓋地面覆蓋時的樣子（伺服器建的時候設的欄位：不是地板、殭屍不打、可穿過，Place 的 thumpable）、
-- 那格有地板而且地板上沒有同一張、附加圖還沒滿；不符合的照舊留著。先掛圖再移除舊物件：移除失敗就拿掉剛掛的那張。
-- 回有沒有改
function Place.relink(obj)
    local sq, spr = obj:getSquare(), obj:getSprite()
    if not (sq and spr and obj:hasModData() and obj:getModData().builderEntry == spr:getName()) then return false end
    if getCell():getGridSquare(sq:getX(), sq:getY(), sq:getZ()) ~= sq or not sq:getObjects():contains(obj) then
        return false
    end
    if not Rules.onFloor(Rules.classify(spr), spr) or obj:isFloor() or obj:isThumpable() or not obj:isCanPassThrough() then
        return false
    end
    local floor, name = sq:getFloor(), spr:getName()
    if not floor or attachedAt(floor, name) or attachedCount(floor) >= MAX_ATTACHED then return false end
    local items, parts = {}, {}
    for ft, v in pairs(obj:getBuildMaterials()) do
        local n = math.floor(tonumber(v) or 0)
        if n >= 1 then
            items[ft] = n
            parts[#parts + 1] = ft .. "x" .. n
        end
    end
    Place.attach(sq, spr, items)
    sq:transmitRemoveItemFromSquare(obj, false)
    if sq:getObjects():contains(obj) then
        Place.detach(floor, name)
        local Overlays = MinidoracatBuilder.Overlays
        if Overlays then Overlays.forget(sq, name) end
        error("not removed at " .. at(sq))
    end
    print(LOG .. "RELINK overlay e=" .. name .. " at=" .. at(sq) .. " refund=" .. table.concat(parts, ","))
    return true
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
            obj:getModData().builderEntry = spr:getName() -- 讀檔時認得出來（Place.harden）；拆除不認門（Dismantle.mine）
            if proof("ZombieProofDoors") then obj:setHealth(DOOR_HP) end
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
        elseif Rules.onFloor(kind, spr) then
            Place.attach(sq, spr, refundable(c.cost), placed)
        else
            obj = thumpable(c, kind, north)
            -- 屋頂不擋整格；AddSpecialObject 不會重算下面幾層「有屋頂」（客戶端收到 AddItemToMap 才算，
            -- AddItemToMapPacket.java:69），伺服器自己算，存檔才對（bt-newkinds §5.2）
            if kind == "roof" then obj:setBlockAllTheSquare(false) end
            placed[#placed + 1] = obj
            if kind == "floor" then placeFloor(sq, obj) else finish(sq, obj) end
            if kind == "roof" then getCell():checkHaveRoof(sq:getX(), sq:getY()) end
            local Floors = MinidoracatBuilder.Floors
            if Floors and kind == "floor" and sq:getZ() <= 0 and Cost.refund(kind, spr) == "builder" then
                Floors.put(obj, refundable(c.cost))
            end
        end
    end
end

-- 拆回這次已放的（放到一半出錯時）。多格的一組缺片時伺服器整組不拆（IsoObjectUtils.java:119-155），所以逐片拆。
-- 不在格子上的物件 transmitRemoveItemFromSquare 直接回 -1。掛在地板上的（Place.attach 的紀錄）拿掉那張、清帳本。
function Place.undo(placed)
    for i = #placed, 1, -1 do
        local obj = placed[i]
        if type(obj) == "table" and obj.attached == true then
            Place.detach(obj.floor, obj.name)
            local Overlays, sq = MinidoracatBuilder.Overlays, obj.floor:getSquare()
            if Overlays and sq then Overlays.forget(sq, obj.name) end
        else
            local sq = obj:getSquare()
            if sq then sq:transmitRemoveItemFromSquare(obj, false) end
        end
    end
end

-- 原版 Actions.build 的收尾（ActionManager.lua:29-31），不經過它就要自己做
function Place.settle(cells)
    for _, c in ipairs(cells) do
        c.sq:RecalcAllWithNeighbours(true)
        buildUtil.setHaveConstruction(c.sq, true)
    end
end

-- 移出世界前：
--   地板：掛在上面的地面覆蓋跟著消失，那一格的覆蓋帳本整格清掉（只在伺服器，Overlays.dropFloor）。
--   IsoThumpable：一樓以下的地板清掉這一格的地板帳本（不管是不是本 MOD 蓋的）；本 MOD 蓋的清掉退料表：
--     原版拆解、打壞都先讀退料表再移除（ISMoveableSpriteProps.lua:4323-4357、ISBuildingObject.lua:51-69），已經移除的
--     物件不該再退料。
function Place.onAboutToBeRemoved(obj)
    local Overlays = MinidoracatBuilder.Overlays
    if Overlays and instanceof(obj, "IsoObject") then Overlays.dropFloor(obj) end
    if not instanceof(obj, "IsoThumpable") then return end
    local Floors, sq = MinidoracatBuilder.Floors, obj:getSquare()
    if Floors and sq and sq:getZ() <= 0 and obj:isFloor() then Floors.forget(obj) end
    if obj:hasModData() and obj:getModData().builderEntry then wipe(obj:getBuildMaterials()) end
end
Events.OnObjectAboutToBeRemoved.Add(function(obj) MinidoracatBuilder.Place.onAboutToBeRemoved(obj) end)

-- 讀檔時修舊版蓋的（每格載入一次，兩端都跑，重複跑結果一樣）：
--   一樓以下的地板：不給原版搬動工具拆（兩端）；只在伺服器、帳本建好時清掉 buildMaterials，本工具會拆的、圖和蓋的時候
--     一樣的先記進地板帳本（沒付料的記空表：照樣能拆、不退）。
--     ponytail: 帳本還沒建好就不搬、buildMaterials 留著（單機讀檔先 IsoWorld.init 讀格子、之後才建 GOS，
--     GameLoadingState.java:305,313；專用伺服器先建 GOS 再收連線，GameServer.java:816）。下次載入那格時再搬；要當場補再加排隊。
--   牆角柱（WallSE）：當時歸在牆，放成可穿過、不是轉角，原生尋路會連同一格的牆一起當成打不了（thumpable 的柱子說明）。
--     現在歸柱子或不列（BLOCKS_EDGE 這類）的照原版轉角柱改；現在歸柵欄這類的不動。
--   地面覆蓋（0.2.0 以前是獨立物件，Rules.onFloor）：只在伺服器排隊，帳本建好之後的下一個 tick 改掛到地板
--     （Place.relink）。讀檔回呼裡不移除物件：這時正在列這一格的物件，單機的帳本也還沒建（同上）。
--   本 MOD 蓋的（含門、燈）：「殭屍打不壞」「殭屍敲不破門」「容器容量倍率」照目前的沙盒值重設（Place.harden、
--     Place.fitContainers）。LoadGridsquare 早於註冊原生尋路（IsoChunk.java:3835,3865），尋路吃得到改過的值。兩端各自照
--     載入時的沙盒值算、不另外同步：多人中途改了選項，伺服器還載入著的那一帶照舊，送給客戶端的是記憶體裡的物件
--     （PlayerDownloadServer.java:230-234），客戶端重新載入時卻照新值算，兩端不一致到伺服器也重新載入那一帶為止（重開服，或附近
--     沒人、伺服器卸載那一格後再載入，ServerMap.java:540-563）。
--     改了選項後要重新載入才套用（使用者 2026-11-01 選）。
local relinkQueue, relinking = {}, false
local function relinkTick()
    local Overlays = MinidoracatBuilder.Overlays
    if not (Overlays and Overlays.instance) then return end
    local list = relinkQueue
    relinkQueue, relinking = {}, false
    Events.OnTick.Remove(relinkTick)
    for _, obj in ipairs(list) do
        local ok, err = pcall(Place.relink, obj)
        if not ok then print(LOG .. "overlay relink failed: " .. tostring(err)) end
    end
end

-- 改之前可不可打：isThumpable() 在同一條邊有木板時一律回 true（IsoThumpable.java:1677-1679；isBarricaded 只比方向，
-- :1615-1622），門框旁的門釘了木板也算，沒有讀原本欄位的方法。有木板時改照種類算（和建造時的 thumpable 同一份
-- durability），分類不到的當作不打：記成可打的話，關掉時門框這類會變成殭屍要打的牆（getSpecialWall，IsoGridSquare.java:3809,3816）
local function wasThumpable(obj)
    if not obj:isBarricaded() then return obj:isThumpable() end
    local spr = obj:getSprite()
    local kind = spr and Rules.classify(spr)
    return kind ~= nil and durability(kind, spr:getProperties()) ~= nil
end

-- 讀檔時照目前的沙盒值重設「殭屍打不壞」「殭屍敲不破門」（建造時已照當下的值設好）。只改和設定不一致的：兩個選項都關、
-- 沒改過的物件什麼都不動
function Place.harden(obj)
    if instanceof(obj, "IsoThumpable") then
        local on = proof("ZombieProof")
        if on == (obj:getThumpDmg() >= PROOF_DMG - 3) then return end
        if on then
            obj:setThumpDmg(proofDmg(wasThumpable(obj), obj:getThumpDmg()))
            obj:setIsThumpable(false)
        else
            local k = PROOF_DMG - obj:getThumpDmg()
            obj:setIsThumpable(k % 2 == 1)
            obj:setThumpDmg(k >= 2 and 1 or 8) -- 8＝IsoThumpable 的預設（IsoThumpable.java:101）
        end
    elseif instanceof(obj, "IsoLightSwitch") then
        local p = obj:getSprite() and obj:getSprite():getProperties()
        if not p then return end
        local want = (p:has(F.solid) or p:has(F.solidtrans)) and not proof("ZombieProof")
        if obj:isMovedThumpable() ~= want then obj:setMovedThumpable(want) end
    elseif instanceof(obj, "IsoDoor") then
        if proof("ZombieProofDoors") then
            if obj:getHealth() ~= DOOR_HP then obj:setHealth(DOOR_HP) end
        elseif obj:getHealth() > obj:getMaxHealth() then
            obj:setHealth(obj:getMaxHealth())
        end
    end
end

-- 沙盒「容器容量倍率」（ContainerCapacityMultiplier）：圖塊寫的容量 × 倍率（四捨五入），最多 100：世界容器的 getCapacity 夾在
-- 100（ItemContainer.java:168），伺服器搬東西照它檢查（TransactionManager.java:269-275,294-300），設更大也放不進去。原本的容量
-- 照引擎建容器的算法（IsoObject.java:5283-5302；沒寫時一般 50、冷凍庫 15，ItemContainer.java:91）；認不出來的不動，本來就 ≥100 的
-- 算出來也是 100，和 getCapacity 一樣，不動。容量隨存檔（ItemContainer.java:2439,2458）。建造時在送給玩家之前設，讀檔時兩端照目前的值重設
function Place.fitContainers(obj)
    local n = obj:getContainerCount()
    if n == 0 then return end
    local spr = obj:getSprite()
    local p = spr and spr:getProperties()
    if not p then return end
    -- 倍率照百分之一取整、再用整數算四捨五入：二進位存不準的倍率直接乘，會在 .5 邊界少一格（50×1.15、15×4.1；滑桿一格 0.1 也會碰到）
    local m = math.floor((tonumber(Entry.settings().ContainerCapacityMultiplier) or 1) * 100 + 0.5)
    for i = 0, n - 1 do
        local c = obj:getContainerByIndex(i)
        local base
        if c and i == 0 and p:has(F.container) then
            base = tonumber(p:get("ContainerCapacity")) or 50
        elseif c and c:getType() == "freezer" then
            base = tonumber(p:get("FreezerCapacity")) or 15
        end
        if base then
            local want = math.min(100, math.floor((base * m + 50) / 100))
            if c:getCapacity() ~= want then c:setCapacity(want) end
        end
    end
end

function Place.migrate(obj)
    if not (obj:hasModData() and obj:getModData().builderEntry) then return end
    Place.harden(obj)
    Place.fitContainers(obj)
    if not instanceof(obj, "IsoThumpable") then return end
    local md = obj:getModData()
    if obj:getName() == nil then obj:setName(md.builderEntry) end -- 0.3.0 以前蓋的沒有名稱（見 thumpable 的 setName）
    local sq = obj:getSquare()
    if not sq then return end
    local spr = obj:getSprite()
    if groundFloor(obj, sq) then
        if obj:isDismantable() then obj:setIsDismantable(false) end
        local Floors = MinidoracatBuilder.Floors
        if not (Floors and Floors.instance) then return end
        if obj:isFloor() and spr and spr:getName() == md.builderEntry and not Floors.get(obj)
            and Cost.refund("floor", spr) == "builder" then
            Floors.put(obj, obj:getBuildMaterials())
        end
        if obj:hasBuildMaterials() then wipe(obj:getBuildMaterials()) end
    elseif spr and not isClient() and spr:getProperties():has(F.FloorOverlay) and spr:getName() == md.builderEntry
        and Rules.onFloor(Rules.classify(spr), spr) then
        relinkQueue[#relinkQueue + 1] = obj
        if not relinking then
            relinking = true
            Events.OnTick.Add(relinkTick)
        end
    elseif spr and not obj:isCorner() and spr:getProperties():has(F.WallSE) then
        local kind = Rules.classify(spr)
        if kind == nil or kind == "post" then
            obj:setCorner(true)
            obj:setCanPassThrough(false)
        end
    end
end
-- 特殊物件（IsoThumpable 都是）讀檔時另外列一份（IsoGridSquare.java:3247-3250），一般格子沒有
Events.LoadGridsquare.Add(function(sq)
    local list = sq:getSpecialObjects()
    for i = 0, list:size() - 1 do MinidoracatBuilder.Place.migrate(list:get(i)) end
end)

return Place
