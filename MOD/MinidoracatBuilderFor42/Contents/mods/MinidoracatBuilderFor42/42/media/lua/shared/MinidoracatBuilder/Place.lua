-- 放置：補格子、每格能不能放、依種類建立物件並同步。出處 bt-authority §2、§4.2。
-- 兩端共用：伺服器（單機在本機）放置；客戶端只用 Place.check 給游標預覽（Check.item 的 preview 不補格子，只查已有的格子）。
-- 通則：建好物件、設完屬性，才 AddSpecialObject（引擎自己更新室內判定與碰撞），再 transmit 一次。
-- 客戶端收到 AddItemToMap 不會去重，送兩次就變兩個（IsoObject.java:4419-4460）。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Cost"

local Entry, Rules, Cost = MinidoracatBuilder.Entry, MinidoracatBuilder.Rules, MinidoracatBuilder.Cost
local Place = MinidoracatBuilder.Place or {}
MinidoracatBuilder.Place = Place

local F, T = IsoFlagType, IsoObjectType
local NO_TILE_ID = 20000000 -- 非 tiledef sprite 的預設 id（IsoSprite.java:129-130）
local NS, EW = GridSquareEdgeFacingDirection.NORTH_SOUTH, GridSquareEdgeFacingDirection.EAST_WEST

-- 格子不存在時補建（原版 ISBuildIsoEntity.lua:526-538）；chunk 沒載入時建不出來（IsoCell.java:4336-4361）
function Place.square(x, y, z)
    local cell = getCell()
    local sq = cell:getGridSquare(x, y, z)
    if not sq and getWorld():isValidSquare(x, y, z) then sq = cell:createNewGridSquare(x, y, z, true) end
    if sq then sq:EnsureSurroundNotNull() end
    return sq
end

-- 同一張圖不重複放（buildRecipeCode.lua:351-359）
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
-- 聯集（IsoGridSquare.RecalcProperties，IsoGridSquare.java:7250-7264），所以有 skip 時逐件看、跳過它。
-- dirt＝也不算的物件清單（地下室 MOD 的外邊土牆，見 basement）
local function has(sq, k, skip, dirt)
    if not sq:has(k) then return false end
    if not skip and not dirt then return true end
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        local out = o == skip
        for j = 1, dirt and #dirt or 0 do out = out or o == dirt[j] end
        if not out then
            local p = o:getProperties()
            if p and p:has(k) then return true end
        end
    end
    return false
end

-- obj 的附加圖（地圖的地面、牆面疊圖，本 MOD 掛的地面覆蓋與牆面疊圖）裡最後一張叫 name 的位置（0 起算），沒有回 nil
local function attachedAt(obj, name)
    local list = obj and obj:getAttachedAnimSprite()
    for i = (list and list:size() or 0) - 1, 0, -1 do
        local spr = list:get(i):getParentSprite()
        if spr and spr:getName() == name then return i end
    end
    return nil
end
Place.attachedAt = attachedAt

-- 一個物件存檔與同步只帶前 255 張附加圖（IsoObject.java:1376、4630-4635；張數只用 1 byte），再多就會消失
local MAX_ATTACHED = 255
local function attachedCount(obj)
    local list = obj and obj:getAttachedAnimSprite()
    return list and list:size() or 0
end

-- 牆面疊圖的宿主只認佔住那條邊的東西（和下面 edgeTaken 同一組鍵）：getWall 只看 cutN／cutW，會找到只帶 cutN 的裝飾片
-- （wallOverlay 種類）或那條邊沒牆時獨立放的牆面疊圖本身。那條邊之後還能蓋牆，新牆插在地板後、它前面，宿主就換人，掛在它
-- 身上的圖再也找不到（審查 1112 Codex、Claude）。這類照同一條件往後找，找不到就照舊建獨立物件
local EDGE_KEYS = {
    N = { F.WallN, F.WallNTrans, F.WallNW, F.collideN, F.DoorWallN, "DoorWallNTrans", F.WindowN, F.HoppableN, F.TallHoppableN },
    W = { F.WallW, F.WallWTrans, F.WallNW, F.collideW, F.DoorWallW, "DoorWallWTrans", F.WindowW, F.HoppableW, F.TallHoppableW },
}
local function holdsEdge(p, edge)
    if p:has(F.WallOverlay) then return false end
    if edge == "SE" then return p:has(F.WallSE) end
    for _, k in ipairs(EDGE_KEYS[edge]) do
        if p:has(k) then return true end
    end
    return false
end
local function realWall(sq, o, edge)
    if not o then return nil end
    local p = o:getProperties()
    if p and holdsEdge(p, edge) then return o end
    local objects, cut = sq:getObjects(), edge == "N" and F.cutN or F.cutW
    for i = 0, objects:size() - 1 do
        local x = objects:get(i)
        local q = x:getProperties()
        if q and holdsEdge(q, edge) and (edge == "SE" or (q:has(cut) and not q:has(F.WallSE))) then return x end
    end
    return nil
end

-- 牆面疊圖（Rules.onWall）掛在哪一件上，照地圖讀檔（CellLoader.java:201-251）：SE 是牆角柱（getWallSE）；N／W 是那條邊的
-- 牆（getWall：帶 cutN／cutW、不是牆角柱的第一件，門框、窗框也算，IsoGridSquare.java:4590-4599；再過 realWall）。getWall
-- 本身是 nil 時才查那條邊的窗（要帶同方向的 WindowN／W），再沒有是同方向的車庫門（:4623-4636），和地圖一樣；getWall 找到
-- 的被 realWall 拒掉時不往窗、車庫門找。都沒有回 nil：照舊建獨立物件（地圖同一條退路）
function Place.wallAt(sq, edge)
    if edge == "SE" then return realWall(sq, sq:getWallSE(), edge) end
    local north = edge == "N"
    local w = sq:getWall(north)
    if w then return realWall(sq, w, edge) end
    local o = sq:getWindow(north and NS or EW)
    local p = o and o:getProperties()
    if o and not (p and p:has(north and F.WindowN or F.WindowW)) then o = nil end
    return o or sq:getGarageDoor(north)
end
Place.EDGES = { "N", "W", "SE" }

-- spr（種類 kind；省略時照 Rules.classify）掛上去的那一件與邊：地面覆蓋（Rules.onFloor）掛在那格的地板、邊是 nil；
-- 牆面疊圖（Rules.onWall）掛在 Place.wallAt。不掛的種類、或那一件不在時回 nil（牆面疊圖仍回邊）
function Place.host(sq, spr, kind)
    kind = kind or Rules.classify(spr)
    if Rules.onFloor(kind, spr) then return sq:getFloor(), nil end
    local edge = Rules.onWall(kind, spr)
    if edge then return Place.wallAt(sq, edge), edge end
    return nil, nil
end

-- 這條格邊已經有東西：牆、牆角、門框、窗框、柵欄、門、窗，以及其他擋這條邊的物件
-- （原版 isObjectSpriteBlockingWallPlacement 看 collideN/W，ISBuildIsoEntity.lua:159-175）。skip、dirt 見 has
local function edgeTaken(sq, north, skip, dirt)
    if north then
        return has(sq, F.WallN, skip, dirt) or has(sq, F.WallNTrans, skip, dirt) or has(sq, F.WallNW, skip, dirt)
            or has(sq, F.collideN, skip, dirt) or has(sq, F.DoorWallN, skip, dirt) or has(sq, "DoorWallNTrans", skip, dirt)
            or has(sq, F.WindowN, skip, dirt) or has(sq, F.HoppableN, skip, dirt) or has(sq, F.TallHoppableN, skip, dirt)
            or sq:getDoor(NS) ~= nil or sq:getWindow(NS) ~= nil
    end
    return has(sq, F.WallW, skip, dirt) or has(sq, F.WallWTrans, skip, dirt) or has(sq, F.WallNW, skip, dirt)
        or has(sq, F.collideW, skip, dirt) or has(sq, F.DoorWallW, skip, dirt) or has(sq, "DoorWallWTrans", skip, dirt)
        or has(sq, F.WindowW, skip, dirt) or has(sq, F.HoppableW, skip, dirt) or has(sq, F.TallHoppableW, skip, dirt)
        or sq:getDoor(EW) ~= nil or sq:getWindow(EW) ~= nil
end

-- Basement Building（Workshop 3806513504，Mod ID aparosa_BasementDig）：地下室外邊（它記的地下室範圍和沒有房間的格子之間）
-- 的土牆是最底層，別的牆可以蓋在上面；蓋好它拆掉那條邊的土牆，上層牆拆了它下一個 tick 補回（aparosa_BD_DirtLayer.lua:1-18、
-- 138-151、196-221）。它只包原版新式建造（:309-397），本工具自己建物件不經過那裡，所以照它的同一份判斷：外邊土牆不算擋，
-- 外邊不准蓋開口、框、和土牆同一張圖的牆（它的使用者裁定，:131-135、243-266），被擋的回 BLOCKED（不另立原因碼）。
-- 範圍紀錄兩端都有（伺服器存 Global ModData，客戶端進場後要一份、改了伺服器推，aparosa_BD_Sync.lua:1-16），預覽同一份判斷。
-- 只在 z < 0、它載入、用到的函式都在時才查；出錯也當沒裝它：土牆照舊擋（BLOCKED），不丟錯。不覆寫它的函式。
-- 判斷丟過錯的那份（broken）之後一律照沒裝它：pcall 接住的錯照樣進引擎的錯誤計數（pitfalls.md Kahlua 段），拖一排時不要
-- 每格再丟一次（審查 1107 Grok）。同一個 Lua state 內不再試，重進存檔或重開服才重試（它重載時沿用同一張表）
local BD_FNS = { "isOuterEdge", "isDirtOnOuterEdge", "isOpeningOnOuterEdge", "isFrameOnDirt", "isDirtLookOnOuterEdge", "clearDirt" }
local broken
local function dirtLayer(sq)
    if sq:getZ() >= 0 then return nil end
    local D = aparosa_BD_DirtLayer
    if type(D) ~= "table" or D == broken then return nil end
    for i = 1, #BD_FNS do
        if type(D[BD_FNS[i]]) ~= "function" then return nil end
    end
    return D
end

-- 這條邊（k＝"N"／"W"）是它的外邊時，這格上它的外邊土牆；不是外邊或沒有回 nil
local function outerDirt(D, sq, k)
    if not D.isOuterEdge(sq:getX(), sq:getY(), sq:getZ(), k) then return nil end
    local list, objects = {}, sq:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        if D.isDirtOnOuterEdge(o) then list[#list + 1] = o end
    end
    return list[1] and list or nil
end

local function basementCheck(D, sq, name, n, w)
    if D.isOpeningOnOuterEdge(sq, name) or D.isFrameOnDirt(sq, name) or D.isDirtLookOnOuterEdge(sq, name) then return true end
    return false, n and outerDirt(D, sq, "N"), w and outerDirt(D, sq, "W")
end

-- 它只認實牆的格邊（aparosa_BD_DirtLayer.lua:46-63 edgesOf 的 WallN／WallW／WallNW；門框、窗框它另擋），透明門框、透明牆角
-- 這類只有字串鍵的它不認：蓋上去它拆了土牆也不補回，所以這幾種的土牆照舊擋（審查 1107 Claude）
local function bdEdges(spr, n, w)
    local p = spr:getProperties()
    local nw = p:has(F.WallNW)
    return n and (nw or p:has(F.WallN)), w and (nw or p:has(F.WallW))
end

-- 回 refused（照它的規則外邊不准蓋）, 北邊、西邊不算擋的土牆；沒裝它、不在地下或出錯回 nil（照沒裝它）。
-- n、w 是 Entry.edges 的格邊；照它認得的再篩（bdEdges），地上不多查
local function basement(sq, spr, n, w)
    local D = dirtLayer(sq)
    if not D then return nil end
    n, w = bdEdges(spr, n, w)
    local ok, refused, dn, dw = pcall(basementCheck, D, sq, spr:getName(), n, w)
    if not ok then
        broken = D
        print("[MinidoracatBuilderFor42] Basement Building check failed, treated as not installed: " .. tostring(refused))
        return nil
    end
    return refused, dn, dw
end

local function doorFrameAt(sq, north)
    if north then return sq:has(F.DoorWallN) or sq:has("DoorWallNTrans") end
    return sq:has(F.DoorWallW) or sq:has("DoorWallWTrans")
end

-- 牆不能把既有的多格家具切開（ISBuildIsoEntity.lua:397-408）：北邊的牆擋 grid y > 0 的片，西邊擋 x > 0
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

-- IsoDoor 會把同一張表 +2 號當開門的圖（IsoDoor.java:677-689；開著的那張 Rules 不列）；那一號不存在時引擎會建一個空 sprite
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

-- 樓梯一片（照原版 BuildRecipeCode.stairs.OnIsValid，buildRecipeCode.lua:169-218）。role＝top／mid／bottom／platform
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

-- 屋頂（原版沒有放屋頂的路徑，bt-newkinds §5.3）：正下方不是樓梯（同原版地板的 HasStairsBelow；一樓也查地下室的樓梯）。
-- 一樓（z＝0）不查支撐：原版地圖的屋簷、貼牆的邊緣裝飾、帳篷與碉堡頂都放在一樓（離線讀 Muldraugh 的 lotpack，z＝0 的
-- 屋頂類 74,231 片；使用者 2026-11-09 選全部屋頂類都放行）。地下室不放。二樓起要有東西撐著：正下方那格有牆，或這格、四鄰有地板或屋頂
-- （四鄰有地板＝connectedWithFloor，不含斜坡）。照座標查、不要這格存在：客戶端預覽時上一層的格子常常還沒建（Check.item 照樣呼叫）。
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
    if z < 0 then return false end
    local cell = getCell()
    local below = cell:getGridSquare(x, y, z - 1)
    if below and below:HasStairs() then return false end -- 一樓也查：地下室的樓梯口上面不蓋（審查 1109 Claude）
    if z == 0 then return true end
    if below and (below:getWall(true) or below:getWall(false) or below:getWallSE()) then return true end
    if planned and (planned[Place.key(x - 1, y, z)] or planned[Place.key(x + 1, y, z)]
        or planned[Place.key(x, y - 1, z)] or planned[Place.key(x, y + 1, z)]) then
        return true
    end
    return supports(cell:getGridSquare(x, y, z)) or supports(cell:getGridSquare(x - 1, y, z))
        or supports(cell:getGridSquare(x + 1, y, z)) or supports(cell:getGridSquare(x, y - 1, z))
        or supports(cell:getGridSquare(x, y + 1, z))
end

-- 地板：照原版 BuildRecipeCode.floor.OnIsValid（buildRecipeCode.lua:344-370）：正下方不是樓梯（HasStairsBelow），而且
-- connectedWithFloor（IsoGridSquare.java:3452-3490：一樓一律可以；旁邊同一層有地板，或斜坡頂接到這格）。二樓以上另外：
-- 正下方那格有牆也撐得住，同屋頂（使用者 2026-11-09 選：站在下面往上鋪，不必先蓋樓梯）。照座標查、不要這格存在
-- （預覽時上一層的格子常常還沒建）；planned 同屋頂（同一排前面判定可蓋的地板格）
local SIDES = { { -1, 0, "E" }, { 1, 0, "W" }, { 0, -1, "S" }, { 0, 1, "N" } } -- 鄰格與斜坡朝向（同 connectedWithFloor）
function Place.floorAt(x, y, z, planned)
    local cell = getCell()
    local below = cell:getGridSquare(x, y, z - 1)
    if below and below:HasStairs() then return false end
    if z == 0 then return true end
    if z > 0 and below and (below:getWall(true) or below:getWall(false) or below:getWallSE()) then return true end
    for _, d in ipairs(SIDES) do
        local nx, ny = x + d[1], y + d[2]
        local n = cell:getGridSquare(nx, ny, z)
        if (n and n:has(F.solidfloor)) or (planned and planned[Place.key(nx, ny, z)]) then return true end
        local b = cell:getGridSquare(nx, ny, z - 1)
        if b and b:getSlopedSurfaceHeight(IsoDirections[d[3]]) == 1 then return true end
    end
    return false
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

-- 原版疊箱子的高度上限（ISMoveableSpriteProps.lua:1772-1776）：可疊的桌類放在桌類上，總高加上自己的 Surface 不超過 96。
-- 建造視窗的詳情照它算能疊幾層
Place.STACK_MAX = 96
local STACK_MAX = Place.STACK_MAX

-- 疊放模式（使用者 2026-11-12 選 overlap、每格 3 件）：玩家在建造視窗打開「疊放」時，格上已經有實心或擋放置的東西也放。
-- 圖塊包有很多預先畫好高度、要和別張疊在同一格的圖（櫃台上的爐面、畫成三層的箱子、架子上的衣服），屬性分不出哪些
-- 是一組，所以交給玩家決定；只給這三種（其他種類本來就各有同格規則）。兩端共用，伺服器照沙盒重算。
Place.OVERLAP = { furniture = true, container = true, solid = true }

-- 沙盒「同一格最多幾件」（MaxPerSquare）；1＝不能疊放
function Place.maxPerSquare()
    return math.max(1, math.floor(tonumber(Entry.settings().MaxPerSquare) or 3))
end

-- 這一格會擋路的東西與容器有幾件：實心、擋放置或有容器的物件（地板不算；牆、門窗、掛件沒有這些屬性）。
-- 疊放的上限（沙盒 MaxPerSquare）照它數：同一格的容器數量與殭屍要打的件數跟著上限走，預設 3 和原版疊三個箱子一樣
function Place.occupants(sq)
    local n, objects = 0, sq:getObjects()
    for i = 0, objects:size() - 1 do
        local s = objects:get(i):getSprite()
        local p = s and s:getProperties()
        if p and not p:has(F.solidfloor) and (p:has(F.solid) or p:has(F.solidtrans) or p:has("BlocksPlacement")
            or p:has(F.container)) then
            n = n + 1
        end
    end
    return n
end

-- 疊放模式下，放不下的這一格能不能照疊放放：回 true，或 false 與原因碼（OCCUPIED、SAME_TILE、SQUARE_FULL；沒有碼＝
-- 這一項或這一格不給疊）。不放寬的：格上有人、殭屍或動物，會擋到樓梯（Place.check 只替實心的新物件查這兩項，
-- 這裡不管新物件實不實心都查）；沒有地板、高草與樹、樓梯、水；桌上物件（IsTableTop）與掛牆、掛窗的（MoveType）
-- 照原版各自那一支；兩張桌面同格：引擎讀檔時把後一張墊到前一張上面（IsoGridSquare.FixStackableObjects），預先畫好
-- 高度的圖會再高一截，所以照原版疊箱子的規則，不走疊放。同一張圖也不疊（可疊的箱子在 Place.check 開頭不擋同一張，
-- 這裡補上：兩件畫在同一個位置，看起來只有一件）
local function overlapOk(kind, spr, sq)
    local max, p = Place.maxPerSquare(), spr:getProperties()
    if not Place.OVERLAP[kind] or max <= 1 or p:has("IsTableTop") then return false end
    local mt = p:get("MoveType")
    if mt and mt ~= "Object" then return false end
    if not sq:getMovingObjects():isEmpty() then return false, "OCCUPIED" end
    if sq:getFloor() == nil or vegetation(sq) or sq:HasStairs() or sq:has(F.water) or sq:has(F.taintedWater)
        or buildUtil.stairIsBlockingPlacement(sq, true, nil) then -- 第三個參數明寫 nil＝兩個方向都查（Kahlua 少傳不保證 nil）
        return false
    end
    if p:has("IsTable") and sq:has("IsTable") then return false end -- 落回原版疊箱子的原因碼（STACK_FULL、NOT_SURFACE）
    if hasSprite(sq, spr:getName()) then return false, "SAME_TILE" end
    if Place.occupants(sq) >= max then return false, "SQUARE_FULL" end
    return true
end

-- 能不能在 sq 放 spr（種類 kind）。成功回 true 與桌面高度（放在桌上、疊上去的物件要墊高，原版搬家具算的）；
-- 失敗回 false 與原因碼（游標分原因說；nil＝其他，Check.item 回 BLOCKED）：
--   SAME_TILE：同一格已經有同一張圖（不是可疊的）。VEHICLE：車子壓著。OCCUPIED：會擋路的東西那格有人、殭屍或動物。
--   STACK_FULL：可疊的箱子疊到原版的高度上限。NOT_SURFACE：可疊的箱子放在可疊、卻不是桌面的箱子上。
--   SQUARE_FULL：疊放模式下這一格已經到沙盒的上限。
-- player 只給原版搬家具的判斷讀玩家所在格（窗上物件）；擺放技能與工具不查（placeTool 已清掉）。
-- role：多格項目裡這一格的角色（Entry.cells 第 5 欄；目前只有樓梯有）。planned：見 Place.roofAt。
-- replacing：要被原地替換掉的那件（Check.item 的 info.replace.obj）：它佔的格邊、它的實心與擋放置都不算擋；
-- 同一張圖照樣擋（同一張不算替換）。原版搬家具的判斷（IsMoveAble）不能叫它跳過，照舊看整格。
-- overlap：疊放模式（見 overlapOk）。照原本的規則放得下就照原本的（桌上、疊箱子的高度照舊），放不下才照疊放，
-- 這時第三個回傳值是 true（游標寫「疊放」、伺服器 log 記 over）；和 replacing 不會同時有（Check.item 疊放時不找替換）。
function Place.check(kind, spr, sq, player, role, planned, replacing, overlap)
    if kind == "stairs" then return stairsOk(spr, sq, role) end
    if sq:isVehicleIntersecting() then return false, "VEHICLE" end
    overlap = overlap == true -- Kahlua 少傳的參數不保證是 nil（家族 pitfalls）：只認明確的 true
    local p = spr:getProperties()
    -- 可疊的（IsStackable：軍用箱、紙箱這類）同一張也能疊，高度交給下面原版搬家具的判斷
    if not p:has("IsStackable") and hasSprite(sq, spr:getName()) then return false, "SAME_TILE" end
    if kind == "floor" and hasCrop(sq) then return false end
    local host, edge = Place.host(sq, spr, kind)
    if host or Rules.onFloor(kind, spr) then
        -- 掛上去（Place.attach）：那一件上還沒有同一張（地圖原有的也算）、附加圖還沒滿。地面覆蓋要有地板、不蓋在高草、
        -- 樹上；牆面疊圖那條邊沒有牆時不走這裡，往下照獨立物件判斷
        if host and attachedAt(host, spr:getName()) then return false, "SAME_TILE" end
        return host ~= nil and attachedCount(host) < MAX_ATTACHED and (edge ~= nil or not vegetation(sq))
    end
    if kind == "floor" then return Place.floorAt(sq:getX(), sq:getY(), sq:getZ(), planned) end
    if kind == "roof" then return Place.roofAt(sq:getX(), sq:getY(), sq:getZ(), planned) end
    if kind == "curtain" then return curtainOk(spr, sq) end
    if Entry.EDGE[kind] then
        if sq:HasStairs() then return false end
        local n, w = Entry.edges(kind, spr)
        local refused, dirtN, dirtW = basement(sq, spr, n, w)
        if refused then return false end
        if kind == "door" then
            -- 門要放進同方向、還沒有門的門框（原版 isValidPerSquare：有門框、沒有門），開門的圖也要在
            return doorPairExists(spr) and ((n and doorFrameAt(sq, true) and sq:getDoor(NS) == nil)
                or (w and doorFrameAt(sq, false) and sq:getDoor(EW) == nil))
        end
        -- 一般的窗要放進同方向、還沒有窗的窗框。牆型窗（Rules.framedWindow：窗和窗框同一張，地圖也不另放窗框）照下面
        -- 一般格邊判斷：那條邊已經有窗框（地圖的或本工具蓋的）、牆、窗時 edgeTaken 擋下，不疊兩層框（BLOCKED）
        if kind == "window" and not Rules.framedWindow(spr:getType()) then
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
        return not ((n and edgeTaken(sq, true, replacing, dirtN)) or (w and edgeTaken(sq, false, replacing, dirtW))
            or splitsGrid(sq, n, w, replacing))
    end
    -- 會擋路的東西：格上有人、殭屍或動物，或會擋到樓梯時不放（原版 isFree(true)、stairIsBlockingPlacement）
    if p:has(F.solid) or p:has(F.solidtrans) then
        if not sq:getMovingObjects():isEmpty() then return false, "OCCUPIED" end
        if buildUtil.stairIsBlockingPlacement(sq, true, nil) then return false end
    end
    if p:has("IsMoveAble") then
        -- 原版搬家具放下的判斷（地板、桌面、掛牆要有牆、窗上物件要有窗框、地毯不疊、箱子疊多高…），伺服器能跑（bt-authority §4.2）。
        -- 成功時回的不一定是 true（掛牆時回那面牆），照真假看。
        local props = ISMoveableSpriteProps.new(spr)
        -- 不要求原版的擺放技能與工具（設計稿：工具照 Cost）：placeTool 是 nil 時 hasRequiredSkill／hasTool 都放行（:1956-1961）
        props.placeTool = nil
        if not props:canPlaceMoveableInternal(player, sq, nil) then
            -- 疊放模式：格上有東西而放不下的，照疊放放（畫好高度的圖不墊高）。樓梯頂照原版不放（:1779）
            if overlap and not props:isSquareAtTopOfStairs(sq) then
                local fits, why = overlapOk(kind, spr, sq)
                if fits then return true, 0, true end
                if why then return false, why end
            end
            -- 疊到頂：照原版疊箱子那一支的條件重算一次，只差高度
            if props.isStackable and props.isTable and props.surface and sq:has("IsTable") and not sq:has("IsTableTop")
                and not sq:has("IsHigh") and props:getTotalTableHeight(sq) + props.surface > STACK_MAX then
                return false, "STACK_FULL"
            end
            -- 下面那件可疊卻不是桌面（例：UMCTP 畫好高度的半箱 industry_ddd_02_32）：說下面那件撐不住東西，不叫玩家清空。
            -- 只在原版疊放那一支本來走得到時才這樣說：自己可疊、是桌面、有 Surface，有地板、不在樓梯頂
            -- （ISMoveableSpriteProps.lua:1743-1745,1772,1779）；自己不是桌面的（半箱本身）放在哪都疊不上，照舊沒有原因碼。
            -- 原地替換（replacing）時也不說：擋住的可能是要換掉的那件
            if props.isStackable and props.isTable and props.surface and not replacing and sq:getFloor()
                and not props:isSquareAtTopOfStairs(sq) and sq:has("IsStackable") and not sq:has("IsTable") then
                return false, "NOT_SURFACE"
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
        if not solid and not (has(sq, "BlocksPlacement", replacing) and not sq:has(F.canBeRemoved)) then return true end
        if not overlap then return false end
        local fits, why = overlapOk(kind, spr, sq)
        return fits, fits and 0 or why, fits
    end
    return true
end

-- ---------------------------------------------------------------- 建立
local function finish(sq, obj, index)
    sq:AddSpecialObject(obj, index or -1) -- 會呼叫 addToWorld，照 sprite 的 container 屬性建容器（IsoObject.java:4491-4493）
    obj:setExplored(true) -- 所以排在這之後：蓋出來的容器不生戰利品（ISBuildIsoEntity.lua:745-746）
    Place.fitContainers(obj) -- 容器也是 addToWorld 建的；容量跟著下一行送給玩家
    obj:transmitCompleteItemToClients()
end

-- 拆了退什麼＝付的扣掉 fee（電器費、能撿起的地磚的材質料，拆了不退，Cost.of）
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

-- 拆了退什麼（Server.dismantle 與伺服器的原地替換讀，只在伺服器）：燈、家電（Place.keyed）照伺服器帳本；一樓以下的地板照
-- 地板帳本，現在的圖和蓋的時候一樣、這一格只有它一片地板才退；其他照 buildMaterials。單機讀檔時帳本建好之前讀進來、
-- 還沒搬的舊地板照 buildMaterials（Place.migrate）。都沒有回 nil。
function Place.refundOf(obj)
    if Place.keyed(obj) then
        local Ledger, Dismantle = MinidoracatBuilder.Ledger, MinidoracatBuilder.Dismantle
        local mats = Ledger and Ledger.get(obj)
        if mats and Dismantle then mats = Dismantle.lightRefund(obj, mats) end
        return mats
    end
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
-- 門開著也走不過去（IsoGridSquare.java:3789-3803）
-- 樓梯照 Wood_Stairs 剛好 6 級、沒有建造加成時的血量：health 150＋最高相關技能等級 6 × skillBaseHealth 50
-- （stairs/entity_carpentry_stairs.txt；ISBuildIsoEntity.lua:666-677，等級越高原版越耐打）
local HEALTH = { wall = 450, windowFrame = 450, fence = 300, stairs = 450, post = 450 }
-- 會擋路（solid／solidtrans）的非格邊物件照原版搬家具放下，都打得壞，而且整格擋住（不然會被 getSpecialWall 當成格邊的牆）：
--   一般的：原版做成 IsoThumpable，一隻殭屍就能打（thumpDmg 1，IsoThumpable.java:1044-1056），血量＝搬運重量（沒寫當 50）
--   × 材質倍率（ISMoveableSpriteProps.lua:148,322-325,2379-2388；ISMoveableDefinitions.lua:688-690）。
--   地毯、掛牆物、放在桌上的：原版做成一般物件再設 movedThumpable（ISMoveableSpriteProps.lua:2330,2501-2504），血量 100、
--   每下扣「圍著打的殭屍數 ÷ 8」、最多 1，不足 1 的累積（IsoObject.java:207,5736-5748）；IsoThumpable 的 thumpDmg 預設就是 8
--   （IsoThumpable.java:106,1042-1056 同一算法）。這裡做成 IsoThumpable，和原版那種一般物件差在：受沙盒「殭屍破壞
--   建築」控制（IsoThumpable.java:1009）、玩家揮武器打得到（CombatManager.java:278-284）。
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
-- （getThumpableFor 看 isThumpable，IsoThumpable.java:1108-1141；nativeCode/SquareUpdateTask.java:334-381），玩家武器也打不到
-- （:1148-1157,1564），大錘不看它（ISDestroyCursor.lua:293-361）。爬行殭屍對低柵欄不看 isThumpable（:1111-1117），所以 thumpDmg
-- 也調到最大：每下只扣「圍著打的殭屍數 ÷ thumpDmg」（:1029-1041）。PROOF_DMG 減 0..3 同時是「照選項改過」的記號（引擎欄位、
-- 隨存檔，不靠 modData），減的數記改之前的樣子：1＝原本可打，2＝原本 thumpDmg 是 1（不然是預設 8）。關掉時照它還原，
-- 不重新分類（Rules 改版、圖塊換成損壞圖時分類會變）
local PROOF_DMG = 2147483647
local function proofDmg(thump, dmg) return PROOF_DMG - (thump and 1 or 0) - (dmg == 1 and 2 or 0) end
-- 沙盒「殭屍敲不破門」（ZombieProofDoors，使用者 2026-11-01 要求和上面分開）：門沒有不給打的旗標（IsoDoor.java:1042-1056），
-- 只能把耐久調高；maxHealth 沒有 setter（:2401,2639），關掉時夾回 maxHealth（建構子照圖塊設的，:807-821）
local DOOR_HP = 1000000000
local function proof(key) return Entry.settings()[key] == true end
local function thumpable(c, kind, north)
    local sq, spr = c.sq, c.spr
    local p = spr:getProperties()
    local obj = IsoThumpable.new(getCell(), sq, spr:getName(), north, {})
    local solid = isSolid(kind, p)
    -- 柱子照原版補的轉角柱（ISBuildUtil.lua:89-93）：轉角、不可穿過（IsoThumpable 預設 false，IsoThumpable.java:112）。
    --   不設轉角的話 north＝false 的柱子會被當成這一格的西牆，殭屍走過西邊那條線時把它當目標打（IsoGridSquare.java:3801
    --   getSpecialWall、:4027 testCollideSpecialObjects、IsoZombie.java:3665）。可穿過的話原生尋路找格邊能不能打時，
    --   遇到它就回「不能打」，連同一格的牆也遮掉（nativeCode/SquareUpdateTask.java:356-381 遇到第一個 IsoThumpable 就回）。
    --   斜走會被擋，和原版一樣（IsoThumpable.java:911-930）。擋格邊的圖 Rules 不列（BLOCKS_EDGE），柱子都不擋格邊
    local corner = kind == "post"
    -- 其餘屬性照原版 entity 建造推（ISBuildIsoEntity:setInfo，ISBuildIsoEntity.lua:620-637）
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
    -- 水槽這類接水管的：照原版搬家具，放好要重新接水管才有水（ISMoveableSpriteProps.lua:2491-2494；IsoObject.java:2653-2657）
    if p:has(F.waterPiped) then obj:getModData().canBeWaterPiped = true end
    return obj
end

-- 地毯：原版建地板照名稱認（buildRecipeCode.lua:248,387），搬動照 MoveType 認（ISMoveableSpriteProps.lua:1884）。圖塊包的
-- 地毯沒有那個名稱、有的還帶 solidfloor（Rules.kindOf），兩種都認。Server.complete 換地板時掛回的地毯也照這份
function Place.isRug(name, p)
    return (name or ""):find("floors_rugs", 1, true) ~= nil or (p ~= nil and p:get("MoveType") == "FloorRug")
end
local function isRug(o, p) return Place.isRug(o:getTextureName(), p) end

-- 地板：照原版 floor.OnCreate（buildRecipeCode.lua:372-437），差別是先拆舊的再放新的（同一格先刪後加，索引才對得上，
-- bt-authority §2.1-4），地毯留著、新地板插在地毯前面；沒有地毯時插回舊地板原本的位置（原版加在最後：同一格已有家具時
-- 地板排到家具後面，之後蓋的牆照「插在最後一個地板後面」也跟著排到家具後面，見 edgeIndex）。舊物件只拆這一格的那片：
-- 多格的一組照原版整組拆會動到沒驗證過的格子（IsoGridSquare.java:5933-5956）。IsoThumpable 的地板照建的時候設的
-- isFloor 拆，不看現在的圖：地板帳本一格只記一筆（Floors）。回新地板該插的位置，或 nil（加在最後）
function Place.clearFloor(sq)
    local objects, rug, at = sq:getObjects(), nil, nil
    for i = objects:size() - 1, 0, -1 do
        local o = objects:get(i)
        local p = o:getProperties()
        local tex = o:getTextureName() or ""
        local floor = instanceof(o, "IsoThumpable") and o:isFloor()
        local remove = floor
        if not floor and isRug(o, p) then
            rug = o
        elseif not floor then
            remove = p and (p:has(F.canBeRemoved) or p:has(F.solidfloor) or p:has(F.noStart) or p:has(F.taintedWater)
                or (p:has(F.vegitation) and o:getType() ~= T.tree)) or tex:find("blends_grassoverlays", 1, true)
        end
        if remove then
            sq:transmitRemoveItemFromSquare(o, false)
            -- 由後往前拆：拆到地板記它的位置；之後拆掉它前面的東西，位置跟著往前一格
            if floor or (p and p:has(F.solidfloor)) then
                at = i
            elseif at then
                at = at - 1
            end
        end
    end
    return rug and objects:indexOf(rug) or at
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

-- 牆、柵欄、門框、窗框插在最後一個 solidfloor 物件後面；門插在同方向的門框後面，沒有門框照牆。照 42.22 原版建好後重插
-- （buildRecipeCode.lua:625-674 的 fenceOrWall／door／doorFrame／windowFrame OnCreate；42.22 更新說明「Fixed certain walls
-- visually overlapping objects when built behind them」），格上物件的順序和原版蓋的一樣。實機同一格先放櫃子再蓋北牆，
-- 牆排在櫃子前後畫面沒有差別（E2E pz42222-sp 的 wallOrder，42.22.2），所以這只是和原版一致，不是看得到的修正。
-- 柱子照原版補的轉角柱加在最後（ISBuildUtil.lua:96，原版沒有重插）。AddSpecialObject 接著照
-- placeWallAndDoorCheck 讓門排在牆後、牆排在門前（IsoGridSquare.java:5799-5811,5884-5918），42.21 與 42.22 相同。
-- 客戶端照伺服器那份的位置插（AddItemToMap 帶 getObjectIndex，IsoObject.loadFromRemoteBuffer）
local REINSERT = { wall = true, fence = true, doorFrame = true, windowFrame = true }
local function edgeIndex(sq, kind, north)
    local objects = sq:getObjects()
    if kind == "door" then
        local frame = north and T.doorFrN or T.doorFrW
        for i = objects:size() - 1, 0, -1 do
            if objects:get(i):getType() == frame then return i + 1 end
        end
    end
    for i = objects:size() - 1, 0, -1 do
        local p = objects:get(i):getProperties()
        if p and p:has(F.solidfloor) then return i + 1 end
    end
    return -1
end

local function placeWindow(sq, obj, north, window)
    local index = -1
    local objects = sq:getObjects()
    -- 窗、面向 S／E 的窗簾插在窗框（和窗）後面（ISMoveableSpriteProps.lua:2141-2170,2196-2210）；牆型窗沒有窗框，
    -- 和牆一樣插在最後一個地板後面（地圖照讀檔順序，CellLoader.java:128-137）
    for i = 0, objects:size() - 1 do
        local p = objects:get(i):getProperties()
        if p and p:has(north and F.WindowN or F.WindowW) then index = i + 1 end
    end
    if index < 0 and window then index = edgeIndex(sq, "wall", north) end
    finish(sq, obj, index)
end

-- 樓梯：照原版 BuildRecipeCode.stairs.OnCreate（buildRecipeCode.lua:225-342）。三片都是 IsoThumpable，buildMaterials 都寫
-- 整組的（Cost.forCells 收在頂片那一格；原版拆哪一片都照那片退）；照原版清掉這格的草（地毯留著）。頂端上一層補平台
-- 地板（addFloor 自己會同步，IsoGridSquare.java:4726-4776），記 ConnectedToStairs（同向的樓梯不能再蓋在平台上），
-- 平台與頂片正上方那格重算。補地板前先照一般地板只拆這一格的舊東西：addFloor 自己拆用預設的 safelyRemove，
-- 伺服器上多格的一組會整組拆（IsoGridSquare.java:4731-4750,5930-5957），動到沒驗證過的格子。
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
                    and not isRug(o, op) then
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
-- 有電才亮（客戶端每片自己判斷）；沒有 lightR 的是開關，原版只控制地圖房間的燈（IsoLightSwitch.java:74-100），線路上的燈由
-- 伺服器 Circuits 切（放好後 Server.complete 呼叫 Circuits.placed 自動接線）。
-- 能不能換燈泡由建構子照 IsMoveAble 設。擋路的照原版設 movedThumpable，殭屍打得壞（:2501-2504）；沙盒「殭屍打不壞」打開時不設。
-- IsoLightSwitch 沒有 buildMaterials：拆了退什麼記在伺服器帳本（server/MinidoracatBuilder/Ledger.lua）。
local function newLight(c)
    local sq, spr = c.sq, c.spr
    local p = spr:getProperties()
    local obj = IsoLightSwitch.new(getCell(), sq, spr, sq:getRoomID())
    obj:addLightSourceFromSprite()
    -- 燈蓋好就開（同原版搬燈，ISMoveableSpriteProps.lua:2329）。格子有房間時，開關（沒有 lightR）沿用建構子照房間設的狀態
    -- （IsoLightSwitch.java:90-96）：強制開的話房間燈關著時開關顯示開、房間暗，第一次按看起來沒反應。有房間的是地圖房屋，
    -- 單機的自建房屋也是（客戶端與伺服器同一份世界）；MP 伺服器上自建房屋沒有房間（IsoRegions.java:212-214），照樣開
    if p:has("lightR") or not sq:getRoom() then obj:setActivated(true) end
    if c.yoff and c.yoff ~= 0 then obj:setRenderYOffset(c.yoff) end
    if (p:has(F.solid) or p:has(F.solidtrans)) and not proof("ZombieProof") then obj:setMovedThumpable(true) end
    obj:getModData().builderEntry = spr:getName()
    return obj
end

-- 家電（壁爐、爐子、烤肉架、洗衣機、烘衣機）：照地圖讀檔，依容器型別建原版類別（CellLoader.java:68-70,139-168,318-328；
-- 那裡 camping_01_04..06 的 campfire 例外，目錄沒有這三張）。建成 IsoThumpable 的話原版認不得：生火選單只開給
-- isFireInteractionObject（IsoFireplace、IsoBarbecue，IsoObject.java:6779-6781），爐子、洗衣機的功能也在各自的類別裡。
-- 擋路的（solid／solidtrans）照原版搬家具放爐子、烤肉架、洗衣機、烘衣機設 movedThumpable（ISMoveableSpriteProps.lua:2246-2263,
-- 2311-2313），殭屍打得壞，同 0.6.1 蓋成 IsoThumpable 時（審查 1109 Claude）；沙盒「殭屍打不壞」打開時不設，讀檔時 Place.harden
-- 照當下的值改（同燈）。目錄的壁爐靠牆、不擋整格（collideN／W），原版搬家具也不設，照舊不打。沒有 buildMaterials：拆了退什麼記在伺服器帳本（同燈）。
-- 0.6.1 以前蓋成 IsoThumpable 的照舊，拆掉重蓋才是新的（使用者 2026-11-09 裁定）。
local APPLIANCE = {
    fireplace = "IsoFireplace", woodstove = "IsoFireplace", brazier = "IsoFireplace", campfire = "IsoFireplace",
    barbecue = "IsoBarbecue", barbecuepropane = "IsoBarbecue",
    stove = "IsoStove", toaster = "IsoStove", coffeemaker = "IsoStove", microwave = "IsoStove",
    clothingdryer = "IsoClothingDryer", clothingwasher = "IsoClothingWasher",
}
-- 這張圖照地圖會建成哪個家電類別（類別名稱），不是家電回 nil
function Place.applianceOf(spr)
    return APPLIANCE[spr:getProperties():get("container") or ""]
end

-- 沒有 buildMaterials 的本 MOD 物件（燈與開關、家電）：退料記在伺服器帳本，物件帶帳本編號（Ledger）。照 APPLIANCE 組，
-- 加家電類別時兩邊不會漏一邊
local KEYED = { "IsoLightSwitch" }
do
    local seen = {}
    for _, cls in pairs(APPLIANCE) do
        if not seen[cls] then
            seen[cls] = true
            KEYED[#KEYED + 1] = cls
        end
    end
end
function Place.keyed(obj)
    for i = 1, #KEYED do
        if instanceof(obj, KEYED[i]) then return true end
    end
    return false
end

-- 容器照地圖讀檔那樣在建好後補（CellLoader.java:341-342）：壁爐只在圖寫了 ContainerCapacity 時自己建（IsoFireplace.java:61-67），
-- 壁爐、洗衣機、烘衣機的 addToWorld 不呼叫上一層，AddSpecialObject 不會替它們建（IsoClothingWasher.java:52-55）。已有容器時不重建
local function newAppliance(c, cls)
    local obj = _G[cls].new(getCell(), c.sq, c.spr)
    obj:createContainersFromSpriteProperties()
    if c.yoff and c.yoff ~= 0 then obj:setRenderYOffset(c.yoff) end -- 放在桌上的微波爐、咖啡機
    local p = c.spr:getProperties()
    if (p:has(F.solid) or p:has(F.solidtrans)) and not proof("ZombieProof") then obj:setMovedThumpable(true) end
    obj:getModData().builderEntry = c.spr:getName()
    return obj
end

-- ---------------------------------------------------------------- 掛上去的地面覆蓋與牆面疊圖（Rules.onFloor、Rules.onWall）
-- 圖掛在那一件（Place.host：地板，或那條邊的牆）的附加圖上（地圖讀檔同一種，CellLoader.java:201-264），不建物件。
-- transmitUpdatedSpriteToClients 把整串附加圖送給客戶端（IsoObject.java:4603-4634；客戶端照 sprite id 重掛、重畫那格，
-- GameClient.java:1044-1084），跟著那一件存檔。那一件 modData 的 builderOverlays（{ [圖名] = true }）只決定右鍵選單列不列；
-- 拆了退什麼只看伺服器的覆蓋帳本（server/MinidoracatBuilder/Overlays.lua）。那一件被移除（換地板、拆牆、打壞）時圖跟著
-- 它走（地圖的也是），它是那格的地板或 Place.wallAt 那一件時帳本跟著清（Overlays.drop；原地換牆由 Server.complete 掛回新牆）。
-- 不觸發移除事件的原版動作不清：鏟地、清除塗鴉與污垢只拿掉附加圖；火燒對一般物件只拿掉附加圖、IsoThumpable 直接換成新物件。
-- 見 builder-dev placement.md「掛上去的地面覆蓋與牆面疊圖」。
local LOG = "[MinidoracatBuilderFor42] "
local function at(sq) return sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ() end

local function mark(host, name, on)
    local md = host:getModData()
    local own = type(md.builderOverlays) == "table" and md.builderOverlays or {}
    own[name] = on or nil
    local any = false
    for _ in pairs(own) do
        any = true
        break
    end
    md.builderOverlays = any and own or nil
end

-- 把 spr 掛到 sq 上它該掛的那一件（Place.host），寫記號、同步、記帳本（items＝拆了退什麼）。拆回用的紀錄（Place.undo；
-- attached 欄位分辨紀錄與物件）在掛上之前就記進 placed（給了的話），後面幾步出錯時照樣拆得回；也當回傳值。
-- 沒有那一件、附加圖滿了丟錯（Place.check 已擋）。
function Place.attach(sq, spr, items, placed)
    local host, edge = Place.host(sq, spr, nil) -- 後面的參數明寫：Kahlua 少傳的參數不保證是 nil
    if not host then error("nothing to hang on at " .. at(sq)) end
    if attachedCount(host) >= MAX_ATTACHED then error("overlays full at " .. at(sq)) end
    local name = spr:getName()
    local rec = { attached = true, host = host, name = name, edge = edge }
    if placed then placed[#placed + 1] = rec end
    host:addAttachedAnimSprite(spr)
    mark(host, name, true)
    host:transmitUpdatedSpriteToClients()
    host:transmitModData()
    local Overlays = MinidoracatBuilder.Overlays
    if Overlays then Overlays.put(sq, name, items, edge) end
    return rec
end

-- 拿掉 host 上最後一張叫 name 的附加圖與記號並同步，回有沒有拿掉。引擎丟的例外 Kahlua 只記 log、不往上丟
-- （MethodCaller.java:34-43），所以照張數確認真的少了一張。帳本由呼叫端清（拆除要先讀退料再拿掉）
function Place.detach(host, name)
    local i = attachedAt(host, name)
    if not i then return false end
    local n = attachedCount(host)
    host:RemoveAttachedAnim(i)
    if attachedCount(host) ~= n - 1 then return false end
    mark(host, name, false)
    host:transmitUpdatedSpriteToClients()
    host:transmitModData()
    return true
end

-- 舊版蓋的地面覆蓋（0.2.0 以前）與牆面疊圖（42.22.2-0.8.0 以前）是獨立的 IsoThumpable：改掛到 Place.host，退料照它的
-- buildMaterials 記進覆蓋帳本（只在伺服器、帳本建好之後；排隊見 Place.migrate）。當下逐項再確認：還在目前載入的那一格、
-- 記號和圖一樣、現在的圖仍會掛上去、物件是舊版蓋時的樣子（伺服器建的時候設的欄位：不是地板、殭屍不打、可穿過，
-- Place 的 thumpable）、那一件在（牆面疊圖那條邊沒有牆就留著）而且上面沒有同一張、附加圖還沒滿；不符合的照舊留著。
-- 先掛圖再移除舊物件：移除失敗就拿掉剛掛的那張。回有沒有改
function Place.relink(obj)
    local sq, spr = obj:getSquare(), obj:getSprite()
    if not (sq and spr and obj:hasModData() and obj:getModData().builderEntry == spr:getName()) then return false end
    if getCell():getGridSquare(sq:getX(), sq:getY(), sq:getZ()) ~= sq or not sq:getObjects():contains(obj) then
        return false
    end
    if obj:isFloor() or obj:isThumpable() or not obj:isCanPassThrough() then return false end
    local host, edge = Place.host(sq, spr, nil)
    local name = spr:getName()
    if not host or attachedAt(host, name) or attachedCount(host) >= MAX_ATTACHED then return false end
    local items, parts = {}, {}
    for ft, v in pairs(obj:getBuildMaterials()) do
        local n = math.floor(tonumber(v) or 0)
        if n >= 1 then
            items[ft] = n
            parts[#parts + 1] = ft .. "x" .. n
        end
    end
    Place.attach(sq, spr, items, nil)
    sq:transmitRemoveItemFromSquare(obj, false)
    if sq:getObjects():contains(obj) then
        Place.detach(host, name)
        local Overlays = MinidoracatBuilder.Overlays
        if Overlays then Overlays.forget(sq, name, edge) end
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
            finish(sq, obj, edgeIndex(sq, kind, north))
        elseif kind == "window" then
            obj = IsoWindow.new(getCell(), sq, spr, north)
            obj:setIsLocked(false)
            placed[#placed + 1] = obj
            placeWindow(sq, obj, north, true)
        elseif kind == "light" then
            obj = newLight(c)
            placed[#placed + 1] = obj
            finish(sq, obj)
            if MinidoracatBuilder.Ledger then MinidoracatBuilder.Ledger.put(obj, refundable(c.cost)) end
        elseif kind == "container" and Place.applianceOf(spr) then
            obj = newAppliance(c, Place.applianceOf(spr))
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
        elseif Rules.onFloor(kind, spr) or Place.host(sq, spr, kind) then -- 牆面疊圖那條邊沒有牆時往下照舊建物件
            Place.attach(sq, spr, refundable(c.cost), placed)
        else
            obj = thumpable(c, kind, north)
            -- 屋頂不擋整格；AddSpecialObject 不會重算下面幾層「有屋頂」（客戶端收到 AddItemToMap 才算，
            -- AddItemToMapPacket.java:69），伺服器自己算，存檔才對（bt-newkinds §5.2）
            if kind == "roof" then obj:setBlockAllTheSquare(false) end
            placed[#placed + 1] = obj
            if kind == "floor" then
                placeFloor(sq, obj)
            else
                finish(sq, obj, REINSERT[kind] and edgeIndex(sq, kind, north) or nil)
            end
            if kind == "roof" then getCell():checkHaveRoof(sq:getX(), sq:getY()) end
            local Floors = MinidoracatBuilder.Floors
            if Floors and kind == "floor" and sq:getZ() <= 0 and Cost.refund(kind, spr) == "builder" then
                Floors.put(obj, refundable(c.cost))
            end
        end
    end
end

-- 拆回這次已放的（放到一半出錯時）。多格的一組缺片時伺服器整組不拆（IsoObjectUtils.java:119-155），所以逐片拆。
-- 不在格子上的物件 transmitRemoveItemFromSquare 直接回 -1。掛上去的（Place.attach 的紀錄）拿掉那張、清帳本。
function Place.undo(placed)
    for i = #placed, 1, -1 do
        local obj = placed[i]
        if type(obj) == "table" and obj.attached == true then
            Place.detach(obj.host, obj.name)
            local Overlays, sq = MinidoracatBuilder.Overlays, obj.host:getSquare()
            if Overlays and sq then Overlays.forget(sq, obj.name, obj.edge) end
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

local function clearDirtAt(D, c, n, w)
    local x, y, z = c.sq:getX(), c.sq:getY(), c.sq:getZ()
    if n and D.isOuterEdge(x, y, z, "N") then D.clearDirt(c.sq, "N") end
    if w and D.isOuterEdge(x, y, z, "W") then D.clearDirt(c.sq, "W") end
end

-- 蓋好之後（Server.complete 在扣料前另包一層 pcall，丟錯和 Place.build 走同一段撤回）：照地下室 MOD 包原版 setInfo 那段（aparosa_BD_DirtLayer.lua:354-364），
-- 這次蓋的格邊是它的外邊就拆掉那條邊的土牆（Place.check 只在外邊放行實牆）。之後本工具的牆被移除（拆除、蓋到一半出錯的
-- Place.undo、原地替換拆舊的）時，它在移除事件記下、下一個 tick 那條邊沒有牆才補回土牆（:196-221），本工具不必管。
-- 出錯丟回 Server.complete：照蓋到一半出錯撤回（Place.undo、不扣料、INTERNAL），拆了一半的土牆由它照上一句補回（審查 1107 Codex）。
-- 這裡出錯不設 broken：只有伺服器跑得到這裡，設了客戶端不知道，兩端判斷就不一樣（審查 1107 Claude 第 2 輪）；INTERNAL 會清掉
-- 客戶端排在後面的動作，不會每格再丟
function Place.clearDirt(kind, cells)
    if not Entry.EDGE[kind] then return end
    for _, c in ipairs(cells) do
        local D = dirtLayer(c.sq)
        if D then
            local n, w = bdEdges(c.spr, Entry.edges(kind, c.spr))
            clearDirtAt(D, c, n, w)
        end
    end
end

-- 移出世界前：
--   掛著圖的那一件（地板、牆）：圖跟著消失，覆蓋帳本清掉那一件的（只在伺服器，Overlays.drop）。
--   IsoThumpable：一樓以下的地板清掉這一格的地板帳本（不管是不是本 MOD 蓋的）；本 MOD 蓋的清掉退料表：
--     原版拆解、打壞都先讀退料表再移除（ISMoveableSpriteProps.lua:4323-4357、ISBuildingObject.lua:51-69），已經移除的
--     物件不該再退料。
function Place.onAboutToBeRemoved(obj)
    local Overlays = MinidoracatBuilder.Overlays
    if Overlays and instanceof(obj, "IsoObject") then Overlays.drop(obj) end
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
--     GameLoadingState.java:307,316；專用伺服器先建 GOS 再收連線，GameServer.java:827）。下次載入那格時再搬；要當場補再加排隊。
--   牆角柱（WallSE）：當時歸在牆，放成可穿過、不是轉角，原生尋路會連同一格的牆一起當成打不了（thumpable 的柱子說明）。
--     現在歸柱子或不列（BLOCKS_EDGE 這類）的照原版轉角柱改；現在歸柵欄這類的不動。
--   地面覆蓋（0.2.0 以前）與牆面疊圖（42.22.2-0.8.0 以前）是獨立物件（Rules.onFloor、Rules.onWall）：只在伺服器排隊，
--     帳本建好之後的下一個 tick 改掛（Place.relink；牆面疊圖那條邊沒有牆的照舊留著，之後那條邊有牆、再讀檔時才掛）。
--     讀檔回呼裡不移除物件：這時正在列這一格的物件，單機的帳本也還沒建（同上）。
--   本 MOD 蓋的（含門、燈）：「殭屍打不壞」「殭屍敲不破門」「容器容量倍率」照目前的沙盒值重設（Place.harden、
--     Place.fitContainers）。LoadGridsquare 早於註冊原生尋路（IsoChunk.java:3834,3864），尋路吃得到改過的值。兩端各自照
--     載入時的沙盒值算、不另外同步：多人中途改了選項，伺服器還載入著的那一帶照舊，送給客戶端的是記憶體裡的物件
--     （PlayerDownloadServer.java:230-234），客戶端重新載入時卻照新值算，兩端不一致到伺服器也重新載入那一帶為止（重開服，或附近
--     沒人、伺服器卸載那一格後再載入，ServerMap.java:563-586）。
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

-- 這張圖現在會掛上去（地面覆蓋或牆面疊圖）。先看旗標：讀檔時每個本 MOD 的 IsoThumpable 都問，多數不必分類
local function hangs(spr)
    local p = spr:getProperties()
    if not (p:has(F.FloorOverlay) or p:has(F.WallOverlay)) then return false end
    local kind = Rules.classify(spr)
    return Rules.onFloor(kind, spr) or Rules.onWall(kind, spr) ~= nil
end

-- 改之前可不可打：isThumpable() 在同一條邊有木板時一律回 true（IsoThumpable.java:1693-1695；isBarricaded 只比方向，
-- :1615-1622），門框旁的門釘了木板也算，沒有讀原本欄位的方法。有木板時改照種類算（和建造時的 thumpable 同一份
-- durability），分類不到的當作不打：記成可打的話，關掉時門框這類會變成殭屍要打的牆（getSpecialWall，IsoGridSquare.java:3794,3801）
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
            obj:setThumpDmg(k >= 2 and 1 or 8) -- 8＝IsoThumpable 的預設（IsoThumpable.java:106）
        end
    elseif Place.keyed(obj) then -- 燈、家電（擋路的打得壞，見 newLight、newAppliance）
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
-- 100（ItemContainer.java:170），伺服器搬東西照它檢查（TransactionManager.java:247-253,272-278），設更大也放不進去。原本的容量
-- 照引擎建容器的算法（IsoObject.java:5272-5291；沒寫時一般 50、冷凍庫 15，ItemContainer.java:93）；認不出來的不動，本來就 ≥100 的
-- 算出來也是 100，和 getCapacity 一樣，不動。容量隨存檔（ItemContainer.java:2487,2506）。建造時在送給玩家之前設，讀檔時兩端照目前的值重設
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
    elseif spr and not isClient() and spr:getName() == md.builderEntry and hangs(spr) then
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
-- 特殊物件（IsoThumpable 都是）讀檔時另外列一份（IsoGridSquare.java:3232-3235），一般格子沒有
Events.LoadGridsquare.Add(function(sq)
    local list = sq:getSpecialObjects()
    for i = 0, list:size() - 1 do MinidoracatBuilder.Place.migrate(list:get(i)) end
end)

return Place
