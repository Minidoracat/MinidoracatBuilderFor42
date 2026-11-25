-- 地下室（本 MOD 挖的，z 固定 -1）：格子集合與連通塊、外邊土牆、向引擎登錄房間、挖掘的判斷。兩端共用：伺服器（單機在本機）
-- 從帳本（server/MinidoracatBuilder/BasementLedger.lua）載入，客戶端從同步來的範圍建。一塊連通的地下＝一棟建物；牆隔開的區域
-- 各算一個房間（伺服器與單機照牆算，Basement.split；客戶端收伺服器分好的，Basement.setRooms）。
-- 外邊土牆的 isOuterEdge、isDirtOnOuterEdge、clearDirt 和 Basement Building 的 aparosa_BD_DirtLayer 同名、同語意（Place 拆土牆
-- 的共用程式兩層都叫），Place 的 dirtLayer 照位置選用哪一層（Basement.near 的格邊歸本 MOD）；能不能蓋本 MOD 的層用 refuses。
-- 外邊只看集合（一格在、一格不在），不看另一格有沒有房間；外來房間由 Basement.pre 的 DIG_ROOM 擋在 1 格外。
-- 不 require Place 以外的東西：Check 在呼叫時才取（Check 載入時本檔可能還沒載入）。
require "MinidoracatBuilder/Place"

MinidoracatBuilder = MinidoracatBuilder or {}
local Basement = MinidoracatBuilder.Basement or {}
MinidoracatBuilder.Basement = Basement
local Place = MinidoracatBuilder.Place
local F, T = IsoFlagType, IsoObjectType
local LOG = "[MinidoracatBuilderFor42] basement "

Basement.ROOM = "mdcbuilderbasement" -- 房間名：只在 Basement.pre 認「是不是本 MOD 的房間」時用
Basement.MAX = 400                   -- 一塊最多幾格（＝Circuits.ROOM_MAX）
-- 外邊土牆的圖：判斷「是不是土牆」一律查這張表。原版的土牆圖沒有屬性，牆屬性來自本 MOD 的圖塊補丁檔
-- media/mdcbuilder_basement.patch.tiles（scripts/gen_basement_tiles.py 寫出，和 Basement Building 的那三格相同）
Basement.DIRT = { W = "underground_01_8", N = "underground_01_9", NW = "underground_01_10" }
Basement.AREA = 256                  -- 同步用的大區邊長
-- 地下室的 x、y 只收 0 ≤ 值 < LIMIT：格子鍵（Place.key）每軸 5 位數，再大就和別格撞鍵（審查 round1 F12）
Basement.LIMIT = 100000
local Z = -1
local BIG = 1e15
local DIRS = { { 0, -1 }, { -1, 0 }, { 1, 0 }, { 0, 1 } }
local EDGE = { N = { 0, -1 }, W = { -1, 0 } }
local OTHER = { N = "W", W = "N" }

-- cells[鍵]＝連通塊編號；blocks[編號]＝{ n＝格數, tiles＝{ [鍵]＝{ x, y } }, box＝{ x0, y0, x1, y1 } 包圍盒（含邊），
-- room＝{ [鍵]＝房號 }（同一個房號＝同一間；號碼不必連續）, rooms＝用過的最大房號 }
-- main[編號]＝這一場登錄過的主建物 { cx, cy＝metaID 的角, lx, ly＝它外框左上角所在的地圖格（256 格一格，引擎照這一格找
-- 同一棟）, tiles＝{ [鍵]＝{ x, y } } }；regd[鍵]＝這一格已登錄進某一棟
local cells, blocks, main, regd, lastId = {}, {}, {}, {}, 0

local function inRange(x, y)
    return x >= 0 and y >= 0 and x < Basement.LIMIT and y < Basement.LIMIT
end
Basement.inRange = inRange

local function key(x, y) return Place.key(x, y, Z) end
local function has(x, y, z) return z == Z and cells[key(x, y)] ~= nil end
Basement.has = has

function Basement.blockOf(x, y, z)
    local id = z == Z and cells[key(x, y)]
    if not id then return nil end
    return id, blocks[id].n
end

-- 這格的北、西兩條邊歸本 MOD 管：這格或它的北、西鄰格在集合裡
function Basement.near(sq)
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    return z == Z and (has(x, y, z) or has(x, y - 1, z) or has(x - 1, y, z))
end

-- 兩塊併成一塊：小的那塊重標成大的；主建物照大的那塊（它沒有才接小的那塊的）。小的那塊的建物留在引擎裡到下一次開服
local function merge(a, b)
    if blocks[a].n < blocks[b].n then a, b = b, a end
    local A, B = blocks[a], blocks[b]
    for k, t in pairs(B.tiles) do
        A.tiles[k], cells[k], A.room[k] = t, a, B.room[k] + A.rooms
    end
    A.n, A.rooms = A.n + B.n, A.rooms + B.rooms
    local p, q = A.box, B.box
    p[1], p[2], p[3], p[4] = math.min(p[1], q[1]), math.min(p[2], q[2]), math.max(p[3], q[3]), math.max(p[4], q[4])
    main[a] = main[a] or main[b]
    blocks[b], main[b] = nil, nil
    return a
end

-- tiles＝{ { x, y }, ... }（z 固定 -1）：加進集合、併連通塊；回真的新增的那幾格。範圍外的（inRange）不收。
-- 新格取第一個相鄰已挖格的房號，不改既有格子的房號：中間的牆拆了之後要不要併成一間，等伺服器照牆重算（split）
function Basement.add(tiles)
    local added = {}
    for _, t in ipairs(tiles) do
        local x, y = t[1], t[2]
        local k = inRange(x, y) and key(x, y)
        if k and not cells[k] then
            local id
            for _, d in ipairs(DIRS) do
                local o = cells[key(x + d[1], y + d[2])]
                if o and o ~= id then id = id and merge(id, o) or o end
            end
            if not id then
                lastId = lastId + 1
                id = lastId
                blocks[id] = { n = 0, tiles = {}, box = { x, y, x, y }, room = {}, rooms = 1 }
            end
            local b, xy, r = blocks[id], { x, y }, nil
            for _, d in ipairs(DIRS) do
                local o = key(x + d[1], y + d[2])
                r = r or (cells[o] == id and b.room[o])
            end
            cells[k], b.n, b.tiles[k], b.room[k] = id, b.n + 1, xy, r or 1
            local box = b.box
            box[1], box[2], box[3], box[4] = math.min(box[1], x), math.min(box[2], y), math.max(box[3], x), math.max(box[4], y)
            added[#added + 1] = xy
        end
    end
    return added
end

-- 大區 (ax, ay) 與周圍一圈（3×3 個大區）的範圍：x0 ≤ x < x1、y0 ≤ y < y1
local function range(ax, ay)
    local A = Basement.AREA
    return (ax - 1) * A, (ay - 1) * A, (ax + 2) * A, (ay + 2) * A
end

-- 客戶端收到 basements：大區 (ax, ay) 周圍 3×3 範圍內的格子整份換成 tiles（範圍外的不動、tiles 裡範圍外的不收）。
-- 有格子被拿掉時連通塊整份重算（主建物照它的角那一格接回去；房號照舊分；拿掉的格子在引擎裡的建物留到下一次進場），
-- 拿掉的格子不再算登錄過（regd）：之後又挖回來要重新登錄（審查 round1 F18）。回真的新增的那幾格
function Basement.reset(tiles, ax, ay)
    local x0, y0, x1, y1 = range(ax, ay)
    local keep, inside = {}, {}
    for _, t in ipairs(tiles) do
        if t[1] >= x0 and t[1] < x1 and t[2] >= y0 and t[2] < y1 then
            keep[key(t[1], t[2])] = true
            inside[#inside + 1] = t
        end
    end
    local rest, gone, was = {}, false, {}
    for k, id in pairs(cells) do
        local b = blocks[id]
        local t = b.tiles[k]
        if keep[k] or t[1] < x0 or t[1] >= x1 or t[2] < y0 or t[2] >= y1 then
            rest[#rest + 1], was[k] = t, id .. ":" .. b.room[k]
        else
            gone, regd[k] = true, nil
        end
    end
    if gone then
        local old = main
        cells, blocks, main = {}, {}, {}
        Basement.add(rest)
        for _, b in pairs(blocks) do
            local map, n = {}, 0
            for k in pairs(b.tiles) do
                local w = was[k]
                if not map[w] then n, map[w] = n + 1, n + 1 end
                b.room[k] = map[w]
            end
            b.rooms = n
        end
        -- 主建物接回時 tiles 只留還在同一塊的格子（建新表）：舊表帶著拿掉的格子，下一次登錄主建物會把它們又登錄進去
        for _, m in pairs(old) do
            local id = cells[key(m.cx, m.cy)]
            if id and not main[id] then
                local tiles = {}
                for k, t in pairs(m.tiles) do
                    if cells[k] == id then tiles[k] = t end
                end
                m.tiles, main[id] = tiles, m
            end
        end
    end
    return Basement.add(inside)
end

-- 大區 (ax, ay) 周圍 3×3 範圍內的格子，照連通塊分：{ { { x, y }, ... }, ... }。包圍盒碰不到範圍的塊不逐格看
function Basement.area(ax, ay)
    local x0, y0, x1, y1 = range(ax, ay)
    local out = {}
    for _, b in pairs(blocks) do
        local box = b.box
        if box[1] < x1 and box[3] >= x0 and box[2] < y1 and box[4] >= y0 then
            local list = {}
            for _, t in pairs(b.tiles) do
                if t[1] >= x0 and t[1] < x1 and t[2] >= y0 and t[2] < y1 then list[#list + 1] = t end
            end
            if #list > 0 then out[#out + 1] = list end
        end
    end
    return out
end

-- 啟用的 MOD 清單裡有 Basement Building（同 Rules.unlistModSprites 的讀法）。清單換了引擎會重載 Lua，第一次查完就記在
-- Basement.bdOn（每次檢查都掃一遍 MOD 清單太浪費，審查 round1 F16；測試改清單時清成 nil）
function Basement.bd()
    if Basement.bdOn == nil then
        local on, mods = false, getActivatedMods()
        for i = 0, mods:size() - 1 do
            if mods:get(i) == "aparosa_BasementDig" then on = true end
        end
        Basement.bdOn = on
    end
    return Basement.bdOn
end

-- 圖塊補丁檔生效了：三張土牆圖都帶它那條邊的牆旗標。沒生效（mod.info 的檔號和別的 MOD 重複時引擎跳過後載入的那個，
-- ZomboidFileSystem.java:1000-1002）土牆擋不住人，Entry.kindOn 把挖掘當成種類關掉；已經挖好的照常登錄成室內。
-- 圖塊定義還沒載入（主選單）回 false、不記結果。nil＝還沒查
local WALL_FLAG = { W = F.WallW, N = F.WallN, NW = F.WallNW }
function Basement.checkPatch()
    local named = IsoSpriteManager.instance:getNamedMap()
    if not named:containsKey(Basement.DIRT.W) then return false end
    local ok = true
    for k, name in pairs(Basement.DIRT) do
        local spr = named:containsKey(name) and named:get(name)
        if not (spr and spr:getProperties():has(WALL_FLAG[k])) then ok = false end
    end
    if not ok and Basement.patchOk ~= false then
        print(LOG .. "digging is off: the dirt wall tiles have no wall properties because the tile patch "
            .. "mdcbuilder_basement.patch (tiledef 5886) did not load; another mod may use tiledef file number 5886")
    end
    Basement.patchOk = ok
    return ok
end

function Basement.patched()
    if Basement.patchOk == nil then return Basement.checkPatch() end
    return Basement.patchOk
end
Events.OnLoadedTileDefinitions.Add(function() MinidoracatBuilder.Basement.checkPatch() end)

-- 格子 → 不重疊的矩形 { { x, y, w, h }, ... }：每列切成連續段，由北往南把上一列同一段（同樣的 x0、x1）接下去，矩形數不超過
-- 段數，整塊是矩形時只有 1 個。矩形要少：引擎查一格屬於哪個房間是逐一掃矩形（IsoMetaChunk.java:282-299），每個矩形還建一盞
-- 房間燈（IsoRoom.java:532-534）。給了角 (cx, cy)：角那一列跨過 cx 的段在 cx 左邊切開，左上角是角的矩形排第一——引擎依序走
-- 矩形，左上角「x 不大於、y 小於」目前的角才換（BuildingDef.java:319-348），主建物沒有「x ≤ cx 而且 y < cy」的格子（那些另外
-- 登錄），角不變 metaID 就不變。沒給角時第一個矩形的左上角是最北那一列最西的格子，後面的矩形沒有更北的。
-- 不排序（Kahlua 的 table.sort 會溢位）：每列照 x 的範圍掃。shortcut: 格子散得很開時多走空格；一塊最多 Basement.MAX 格、跨度在幾百格內
function Basement.rects(tiles, ...)
    local cx, cy = ...
    local set, rows, y0, y1 = {}, {}, BIG, -BIG
    for _, t in ipairs(tiles) do
        local x, y = t[1], t[2]
        set[key(x, y)] = true
        local r = rows[y]
        if r then
            if x < r[1] then r[1] = x end
            if x > r[2] then r[2] = x end
        else
            rows[y] = { x, x }
        end
        if y < y0 then y0 = y end
        if y > y1 then y1 = y end
    end
    local open, out = {}, {} -- open["x0,x1"]＝底在上一列、還能往下接的矩形
    for y = y0, y1 do
        local r, now = rows[y], {}
        local x, xe = r and r[1] or 1, r and r[2] or 0
        while x <= xe do
            if set[key(x, y)] then
                local x1 = x
                while set[key(x1 + 1, y)] and not (y == cy and x1 + 1 == cx) do x1 = x1 + 1 end
                local k = x .. "," .. x1
                local rect = open[k]
                if rect then
                    rect[4] = rect[4] + 1
                else
                    rect = { x, y, x1 - x + 1, 1 }
                    out[#out + 1] = rect
                end
                now[k], x = rect, x1 + 1
            else
                x = x + 1
            end
        end
        open = now
    end
    for i = 2, cx and #out or 0 do
        if out[i][1] == cx and out[i][2] == cy then
            out[1], out[i] = out[i], out[1]
            break
        end
    end
    return out
end

-- ---------------------------------------------------------------- 外邊土牆層
local function dirtKind(name)
    for k, v in pairs(Basement.DIRT) do
        if v == name then return k end
    end
    return nil
end

local function covers(kind, k) return kind == k or kind == "NW" end

-- 這格的這條邊貼著集合（邊的兩側有一格在）
local function mine(x, y, k)
    local d = EDGE[k]
    return has(x, y, Z) or has(x + d[1], y + d[2], Z)
end

-- 本 MOD 放的土牆：圖在 Basement.DIRT、不是 IsoThumpable（同一張圖的 IsoThumpable 是玩家蓋的牆），而且佔的邊有一條貼著集合。
-- Basement Building 的土牆是同一組圖：邊不貼著本 MOD 格子的是它的，照實牆算（fix 不會拆掉它）。回 "N"／"W"／"NW" 或 nil
local function dirtOf(o)
    local spr = o:getSprite()
    local k = spr and dirtKind(spr:getName())
    local sq = k and not instanceof(o, "IsoThumpable") and o:getSquare()
    if not sq or sq:getZ() ~= Z then return nil end
    local x, y = sq:getX(), sq:getY()
    if (covers(k, "N") and mine(x, y, "N")) or (covers(k, "W") and mine(x, y, "W")) then return k end
    return nil
end

function Basement.isOuterEdge(x, y, z, k)
    local d = EDGE[k]
    if z ~= Z or not d then return false end
    return has(x, y, z) ~= has(x + d[1], y + d[2], z)
end
local isOuter = Basement.isOuterEdge

local function sqOuter(sq, k) return isOuter(sq:getX(), sq:getY(), sq:getZ(), k) end

function Basement.isDirtOnOuterEdge(obj)
    local kind = dirtOf(obj)
    local sq = kind and obj:getSquare()
    if not sq then return false end
    return (covers(kind, "N") and sqOuter(sq, "N")) or (covers(kind, "W") and sqOuter(sq, "W"))
end

-- 外邊上不准蓋的（回 true）：引擎只護著帶 WallN／WallW／WallNW 的物件不被拆（z < 0、自己那格或鄰格沒有地板時，
-- IsoCell.java:4599-4617），所以外邊上只准蓋引擎會護著、角色又穿不過的東西。圖佔的邊（n、w＝Entry.edges 的原始格邊）是外邊時：
-- 那條邊沒有實牆旗標（門框、窗框、柵欄、透明牆、門）、有實牆旗標但同一條邊也穿得過（窗、門框、柵欄）、或和土牆同一張圖，都擋
local SOLID = { N = F.WallN, W = F.WallW }
local PASS = { N = { F.WindowN, F.DoorWallN, F.HoppableN, F.TallHoppableN },
    W = { F.WindowW, F.DoorWallW, F.HoppableW, F.TallHoppableW } }
local function refusesEdge(sq, p, dirt, k)
    if not sqOuter(sq, k) then return false end
    if dirt or not (p:has(SOLID[k]) or p:has(F.WallNW)) then return true end
    for _, f in ipairs(PASS[k]) do
        if p:has(f) then return true end
    end
    return false
end
function Basement.refuses(sq, spr, n, w)
    local p, dirt = spr:getProperties(), dirtKind(spr:getName()) ~= nil
    return (n == true and refusesEdge(sq, p, dirt, "N")) or (w == true and refusesEdge(sq, p, dirt, "W"))
end

-- 附加圖貼在牆的哪一面（Rules.onWall 同一組旗標）；認不出的回 nil，當成兩面都有
local function faceOf(spr)
    local p = spr:getProperties()
    if p:has(F.attachedW) then return "W" end
    if p:has(F.attachedN) then return "N" end
    return nil
end

-- 土牆 o 要換成 want 那一片（例：西北角那張只剩一面是外邊）：還留著的那一面上的附加圖（本工具的牆面疊圖）記進 hung，
-- 換好後掛到新片。o 移除時覆蓋帳本整件清掉（Overlays.drop），所以先記下那幾筆
local function carry(o, want, hung)
    local list = o:getAttachedAnimSprite()
    if not list or list:size() == 0 then return end
    local Overlays, sq = MinidoracatBuilder.Overlays, o:getSquare()
    if Overlays and not hung.ledger then hung.ledger = { N = Overlays.at(sq, "N"), W = Overlays.at(sq, "W") } end
    local own = o:hasModData() and o:getModData().builderOverlays
    for i = 0, list:size() - 1 do
        local spr = list:get(i):getParentSprite()
        local f = spr and faceOf(spr)
        if spr and (not f or covers(want, f)) then
            hung[#hung + 1] = spr
            if type(own) == "table" and own[spr:getName()] then
                hung.marks = hung.marks or {}
                hung.marks[spr:getName()] = true
            end
        end
    end
end

local function putDirt(sq, kind, hung)
    local obj = IsoObject.new(getCell(), sq, Basement.DIRT[kind])
    sq:AddTileObject(obj)
    obj:transmitCompleteItemToClients()
    if #hung == 0 then return end
    for _, spr in ipairs(hung) do obj:addAttachedAnimSprite(spr) end
    if hung.marks then obj:getModData().builderOverlays = hung.marks end
    obj:transmitUpdatedSpriteToClients()
    obj:transmitModData()
    for e, here in pairs(hung.ledger or {}) do
        for name, items in pairs(here) do
            if covers(kind, e) and hung.marks and hung.marks[name] then MinidoracatBuilder.Overlays.put(sq, name, items, e) end
        end
    end
end

-- 這格北、西兩條邊照外邊補或拆土牆。held＝當成已經有實牆的那條邊（clearDirt：玩家的牆剛蓋上）。
-- 實牆＝土牆以外帶 WallN／WallW／WallNW 的物件（引擎護著不讓人穿過的那幾種）。兩條邊都要土牆時放西北角那一張
local function fix(sq, held)
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local objects, dirt, wallN, wallW = sq:getObjects(), {}, held == "N", held == "W"
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        local kind = dirtOf(o)
        if kind then
            dirt[#dirt + 1] = { o, kind }
        else
            local p = o:getProperties()
            if p and p:has(F.WallNW) then wallN, wallW = true, true end
            if p and p:has(F.WallN) then wallN = true end
            if p and p:has(F.WallW) then wallW = true end
        end
    end
    local needN = not wallN and isOuter(x, y, z, "N")
    local needW = not wallW and isOuter(x, y, z, "W")
    local want = (needN and needW and "NW") or (needN and "N") or (needW and "W") or nil
    local kept, changed, hung = false, false, {}
    for _, d in ipairs(dirt) do
        if d[2] == want and not kept then
            kept = true
        else
            if want then carry(d[1], want, hung) end
            sq:transmitRemoveItemFromSquare(d[1])
            changed = true
        end
    end
    if want and not kept then
        putDirt(sq, want, hung)
        changed = true
    end
    if changed then sq:RecalcAllWithNeighbours(true) end
end

-- 拆這條邊的土牆（玩家的牆蓋上去之後，Place.clearDirt 呼叫）；西北角那張拆掉後，另一條邊還是外邊又沒有實牆就補單邊的
function Basement.clearDirt(sq, k)
    fix(sq, k)
end

-- 只在伺服器與單機：這格北、西兩條邊，是外邊又沒有實牆 → 補土牆；不是外邊 → 拆掉土牆。可重複呼叫。
-- 要補時格子不存在就補建（外邊在已挖那格的東、南鄰格時，那格的格子常常還沒有）
function Basement.fixEdges(x, y, z)
    local sq = getCell():getGridSquare(x, y, z)
    if not sq then
        if not (isOuter(x, y, z, "N") or isOuter(x, y, z, "W")) then return end
        sq = Place.square(x, y, z)
        if not sq then return end
    end
    fix(sq, nil)
end

-- 排到下一個 tick 跑 fixEdges（移除事件裡還在拆的物件這時已經不在）；沒有待辦時不掛 OnTick
local pending, hooked = {}, false
local function flush()
    Events.OnTick.Remove(flush)
    hooked = false
    local list = pending
    pending = {}
    for _, p in pairs(list) do Basement.fixEdges(p[1], p[2], p[3]) end
end
function Basement.touch(x, y, z)
    if isClient() then return end
    pending[Place.key(x, y, z)] = { x, y, z }
    if not hooked then
        hooked = true
        Events.OnTick.Add(flush)
    end
end

-- ---------------------------------------------------------------- 向引擎登錄
-- 這間不補殭屍。引擎只在 spawnCount == -1 時算要補幾隻（VirtualZombieManager.java:666-673），房間是 emptyoutside 時算成 0
-- （:765-772）；新建的房間 doneSpawn 就是 true（BRERoom.java:11-15），chunk 載入時照 spawnCount 補（IsoChunk.java:4181-4193）。
-- spawnCount 是沒有 setter 的 instance 欄位（RoomDef.java:27），Lua 碰不到（LuaJavaClassExposer.java:299-311 只開放 static
-- 欄位），所以暫時改名成 emptyoutside、讓引擎算一次記成 0、再改回來。回成不成功
local function keepEmpty(vzm, def)
    def:setName("emptyoutside")
    local ok = pcall(function() vzm:addIndoorZombiesToChunk(nil, def:getIsoRoom()) end)
    def:setName(Basement.ROOM)
    return ok
end

-- 專用伺服器沒有本機玩家：applyChanges 補格子房間的那段只走本機玩家的 chunkMap（BuildingRoomsEditor.java:369-411,413-436），
-- 已載入的格子照那段自己掛。setRoomID：不設 getRoom 回 null；接著 setRoom：Lua 的數字是 double，房間 ID 超過 2^53 時低位會丟，
-- setRoomID 可能拿到別的房間（IsoGridSquare.java:9414-9420），用房間物件蓋掉；開關加進房間：按一個連動整間
-- （IsoLightSwitch.java:518-524）；RecalcProperties：setRoomID 拿掉了室外旗標。房間燈、重畫不做（伺服器不算光照、不畫，
-- BuildingRoomsEditor.java:385-397）；尋路不看房間，新挖的格子能不能走由鋪地板、放牆時引擎自己通知
local function hang(cell, def, rects)
    local room, id = def:getIsoRoom(), def:getID()
    if not room then return end
    local switches = room:getLightSwitches()
    for _, r in ipairs(rects) do
        for x = r[1], r[1] + r[3] - 1 do
            for y = r[2], r[2] + r[4] - 1 do
                local sq = cell:getGridSquare(x, y, Z)
                if sq then
                    sq:setRoomID(id)
                    sq:setRoom(room)
                    local objects = sq:getObjects()
                    for i = 0, objects:size() - 1 do
                        local o = objects:get(i)
                        if instanceof(o, "IsoLightSwitch") and not switches:contains(o) then switches:add(o) end
                    end
                    sq:RecalcProperties()
                end
            end
        end
    end
end

-- 重新登錄的房間是新的 RoomDef，房間燈是關的（BRERoom 新建的 RoomDef 沒設 lightsActive，房間燈照它建，
-- BuildingRoomsEditor.java:383-384），開關卻還開著；伺服器上那個 chunk 重載時開關又照房間設回關（IsoLightSwitch.java:92-97）。
-- 有開著的開關就照它把整間切開（switchLight 連動整間的開關，IsoLightSwitch.java:518-524），其他開關的狀態照原值還原
local function relight(room)
    local list = room and room:getLightSwitches()
    if not list then return end
    local on, was = nil, {}
    for i = 0, list:size() - 1 do
        local o = list:get(i)
        was[i + 1] = o:isActivated()
        if was[i + 1] and not on then on = o end
    end
    if not on then return end
    on:switchLight(true)
    for i = 0, list:size() - 1 do
        local o = list:get(i)
        if o:isActivated() ~= was[i + 1] then o:setActivated(was[i + 1]) end
    end
end

-- 一批建物一次 applyChanges（成本是整張地圖的檢查與重算，BuildingRoomsEditor.java:216-267,269-325，和這批幾棟關係很小）。
-- plans＝{ rooms, ... }，每棟一組房間、每間一組矩形（rooms[1][1] 是 metaID 的角；一棟叫多次 createRoom，BREBuilding.java:50-58）。
-- 回 ok：ok[i]＝第 i 棟登錄好了（套用後角那一格是新的本 MOD 名稱房間、每一間的第一格都查得到本 MOD 名稱的房間；引擎沒建出來、
-- 角上是別的房間、原地重登錄時舊的那間還在都不算）
local function apply(plans)
    local ok = {}
    if not (BuildingRoomsEditor and BuildingRoomsEditor.getInstance) then
        print(LOG .. "BuildingRoomsEditor is missing; the game update may have changed it")
        return ok
    end
    BuildingRoomsEditor.Reset()
    local editor = BuildingRoomsEditor.getInstance()
    editor:setCurrentBuilding(nil)
    -- 只用 createBuilding／createRoom／addRectangle：init() 會把 32×32 內的建物都拿出來編輯，非 userDefined 的記成移除
    -- （BuildingRoomsEditor.java:81-93,220-229）。不呼叫 canAddRoomRectangle：它對相鄰的別棟回 false（:107-161），另外登錄的
    -- 那幾格一定貼著主建物；改看 isValid
    local done = {}
    for i, rooms in ipairs(plans) do
        local building = editor:createBuilding()
        for _, rects in ipairs(rooms) do
            local room = building:createRoom(Z)
            room:setName(Basement.ROOM)
            for _, r in ipairs(rects) do room:addRectangle(r[1], r[2], r[3], r[4]) end
        end
        if building:isValid() then
            done[#done + 1] = i
        else
            editor:removeBuilding(building)
            print(LOG .. "invalid building skipped at " .. rooms[1][1][1] .. "," .. rooms[1][1][2])
        end
    end
    if #done == 0 then return ok end
    -- 先處理見到的房間的佇列：它逐一讀 room.def（IsoCell.java:4167-4171），替換建物時舊房間的 def 被設成 null
    -- （BREBuilding.java:232-245 → IsoRoom.java:672-674），還留在佇列裡就丟 NPE
    local cell = getCell()
    local spotted, err = pcall(function() cell:ProcessSpottedRooms() end)
    if not spotted then print(LOG .. "ProcessSpottedRooms failed: " .. tostring(err)) end
    -- 套用前角上的房間：套用後還是同一個＝引擎沒換（RoomDef、BuildingDef 都沒有覆寫 equals，Kahlua 的 == 比的是同一個物件）
    local grid, server, old = getWorld():getMetaGrid(), isServer(), {}
    for _, i in ipairs(done) do
        local c = plans[i][1][1]
        old[i] = grid:getRoomAt(c[1], c[2], Z) or false
    end
    editor:applyChanges(false)
    local vzm = not isClient() and VirtualZombieManager and VirtualZombieManager.instance or nil
    for _, i in ipairs(done) do
        local c = plans[i][1][1]
        local def = grid:getRoomAt(c[1], c[2], Z)
        local b = def and def ~= old[i] and def:getName() == Basement.ROOM and def:getBuilding()
        local defs = {}
        for j, rects in ipairs(plans[i]) do -- 每一間的第一格都在這棟新建物裡（別棟留下的舊房間不算）
            local d = b and grid:getRoomAt(rects[1][1], rects[1][2], Z)
            if not (d and d:getBuilding() == b) then b = nil end
            defs[j] = d
        end
        if b then
            ok[i] = true
            b:setUserDefined(false) -- 漏了多人客戶端會退回主選單（實機紀錄）
            b:setAllExplored(true)
            for j, rects in ipairs(plans[i]) do
                local d = defs[j]
                if vzm and not keepEmpty(vzm, d) then print(LOG .. "keepEmpty failed at " .. rects[1][1] .. "," .. rects[1][2]) end
                if server then hang(cell, d, rects) end
                relight(d:getIsoRoom())
            end
        else
            print(LOG .. "no RoomDef after register at " .. c[1] .. "," .. c[2])
        end
    end
    return ok
end

-- 引擎找「同一棟」只在新建物外框左上角所在的地圖格裡照 metaID 找（BREBuilding.getLotHeader：BuildingDef.x／256、y／256，
-- BuildingRoomsEditor.java:233-248）：併進主建物的格子讓外框左上角換到西邊或北邊那一格時，舊的那棟找不到、留在引擎裡和新的疊在一起
local LOT = 256
local function lotOf(v) return math.floor(v / LOT) end

-- 這一端的玩家：伺服器是連線玩家，單機與客戶端是本機（分割畫面）玩家
local function players()
    local ps = {}
    if isServer() then
        local list = getOnlinePlayers()
        for i = 0, list:size() - 1 do ps[#ps + 1] = list:get(i) end
    else
        for n = 0, getNumActivePlayers() - 1 do
            local p = getSpecificPlayer(n)
            if p then ps[#ps + 1] = p end
        end
    end
    return ps
end

-- 包圍盒離 ps 任一位 N 格內的塊：{ [編號]＝true }
local function nearIds(ps, N)
    local near = {}
    for id, b in pairs(blocks) do
        local box = b.box
        for _, p in ipairs(ps) do
            local x, y = p:getX(), p:getY()
            if x >= box[1] - N and x <= box[3] + N and y >= box[2] - N and y <= box[4] + N then
                near[id] = true
                break
            end
        end
    end
    return near
end

-- 格子照房號分組：{ { { x, y }, ... }, ... }（每間一組，房間順序不定）
function Basement.byRoom(tiles)
    local at, out = {}, {}
    for _, t in ipairs(tiles) do
        local k = key(t[1], t[2])
        local r = blocks[cells[k]].room[k]
        local list = at[r]
        if not list then
            list = {}
            at[r], out[#out + 1] = list, list
        end
        list[#list + 1] = t
    end
    return out
end

-- 一棟的房間（ts＝它的格子）：照房號分組、各自切矩形，含角的那間排第一（引擎依序走每間的矩形取角，BuildingDef.java:319-348）。
-- 沒給角時角取最北那一列最西的格子（＝Basement.rects 不給角時第一個矩形的左上角）。回 { rects, ... }、角 x、y
local function roomsOf(ts, ...)
    local cx, cy = ...
    if not cx then
        cx, cy = BIG, BIG
        for _, t in ipairs(ts) do
            if t[2] < cy or (t[2] == cy and t[1] < cx) then cx, cy = t[1], t[2] end
        end
    end
    local out = { false }
    for _, list in ipairs(Basement.byRoom(ts)) do
        local rects = Basement.rects(list, cx, cy)
        if rects[1][1] == cx and rects[1][2] == cy then out[1] = rects else out[#out + 1] = rects end
    end
    return out, cx, cy
end

-- 集合裡還沒登錄的格子 list 照塊登錄：塊還沒有主建物 → 這些格子登錄成主建物；有 → 會換掉主建物 metaID 或地圖格的
-- （角的西北方：x ≤ cx 而且 y < cy，calculateMetaID 會換角；在主建物地圖格的西邊或北邊，審查 round1 F3）登錄成 1 格的 annex，
-- 其他併進主建物重登錄（同地圖格、同 metaID，引擎換掉舊的）。主建物照房號分房，annex 不分。每一棟登錄好了才記下它的格子
-- （apply 的 ok）。
-- 客戶端只登錄身邊的塊：包圍盒離任一位本機玩家 NEAR 格內。chunkMap 最寬 19 個 chunk＝152 格、半寬 76 格
-- （IsoChunkMap.java:60,112-120），其餘留給下一次檢查（Client.askEveryMinute）之前走過去的距離；登錄晚於 chunk 載入時
-- applyChanges 會替本機已載入的格子補上房間（BuildingRoomsEditor.java:369-411,413-436）。遠的塊留著不登錄。
-- 伺服器（與單機）全部登錄：它的 chunk 載入時靠 metaGrid 裡已經有房間
Basement.NEAR = 128
local function register(list)
    local by, order, seen = {}, {}, {}
    local near = isClient() and nearIds(players(), Basement.NEAR) or nil
    for _, t in ipairs(list) do
        local k = key(t[1], t[2])
        local id = cells[k]
        if id and not regd[k] and not seen[k] and (not near or near[id]) then
            seen[k] = true
            if not by[id] then
                by[id] = {}
                order[#order + 1] = id
            end
            local ts = by[id]
            ts[#ts + 1] = t
        end
    end
    -- plans[i]＝第 i 棟的房間；keys[i]＝它登錄的新格子；after[i]＝{ 塊編號, 新的主建物 }（annex 沒有）
    local plans, keys, after = {}, {}, {}
    local function plan(rooms, ks, a)
        local i = #plans + 1
        plans[i], keys[i], after[i] = rooms, ks, a
    end
    for _, id in ipairs(order) do
        local ts, m = by[id], main[id]
        if not m then
            local rooms, cx, cy = roomsOf(ts)
            local tiles, ks, x0, y0 = {}, {}, BIG, BIG
            for _, t in ipairs(ts) do
                local k = key(t[1], t[2])
                tiles[k], ks[#ks + 1] = t, k
                x0, y0 = math.min(x0, t[1]), math.min(y0, t[2])
            end
            plan(rooms, ks, { id, { cx = cx, cy = cy, lx = lotOf(x0), ly = lotOf(y0), tiles = tiles } })
        else
            local tiles, ks
            for _, t in ipairs(ts) do
                local k = key(t[1], t[2])
                if (t[1] <= m.cx and t[2] < m.cy) or lotOf(t[1]) < m.lx or lotOf(t[2]) < m.ly then
                    print(LOG .. "separate building at " .. t[1] .. "," .. t[2])
                    plan({ { { t[1], t[2], 1, 1 } } }, { k }, nil)
                else
                    if not tiles then
                        tiles, ks = {}, {}
                        for k2, v in pairs(m.tiles) do tiles[k2] = v end
                    end
                    tiles[k], ks[#ks + 1] = t, k
                end
            end
            if tiles then
                local list = {}
                for _, v in pairs(tiles) do list[#list + 1] = v end
                local m2 = { cx = m.cx, cy = m.cy, lx = m.lx, ly = m.ly, tiles = tiles }
                plan(roomsOf(list, m.cx, m.cy), ks, { id, m2 })
            end
        end
    end
    if #plans == 0 then return true end
    local ok, all = apply(plans), true
    for i = 1, #plans do
        if ok[i] then
            if after[i] then main[after[i][1]] = after[i][2] end
            for _, k in ipairs(keys[i]) do regd[k] = true end
        else
            all = false
        end
    end
    return all
end

-- 集合裡還沒登錄的格子全部登錄（開服載入帳本當下；客戶端收到 basements 後與每遊戲分鐘，只登錄身邊的塊），一次
-- applyChanges。沒有要登錄的就不叫引擎。回成不成功
function Basement.registerAll()
    local list = {}
    for k, id in pairs(cells) do
        if not regd[k] then list[#list + 1] = blocks[id].tiles[k] end
    end
    return register(list)
end

-- 新增的格子（Basement.add 回的）當下登錄進引擎；挖掘中的新格子走 growLater，它到時候也是呼叫這裡
function Basement.grow(tiles)
    return register(tiles)
end

-- 兩份房號（[鍵]＝房號）在 tiles 上分出的房間是否相同（號碼可以不同，一對一對得上就是同一種分法）
local function samePart(a, c, tiles)
    local f, g = {}, {}
    for k in pairs(tiles) do
        local x, y = a[k], c[k]
        if f[x] == nil and g[y] == nil then
            f[x], g[y] = y, x
        elseif f[x] ~= y or g[y] ~= x then
            return false
        end
    end
    return true
end

-- 換掉塊 id 的房號；分法有變時主建物的格子標成未登錄（下一次登錄整棟照新的分法重建）。回分法有沒有變
local function renumber(id, room, n)
    local b = blocks[id]
    if samePart(b.room, room, b.tiles) then return false end
    b.room, b.rooms = room, n
    local m = main[id]
    if m then
        for k in pairs(m.tiles) do regd[k] = nil end
    end
    return true
end

-- 照牆把塊 id 分成房間：兩格之間的邊照 Place.flagsOf（IsoRegions.calculateSquareFlags 同一份條件）算隔開，往北、往西看自己的
-- 位元，往南、往東看鄰格的。門框、窗算隔開（門開著也算），和地面上的房子一樣。回 { [鍵]＝房號 }、房間數；有一格的格子不在
-- （那裡沒載入）回 nil
function Basement.split(id)
    local tiles, cell, fl = blocks[id].tiles, getCell(), {}
    local function flags(x, y)
        local k = key(x, y)
        local f = fl[k]
        if f == nil then
            local sq = cell:getGridSquare(x, y, Z)
            f = sq and Place.flagsOf(sq) or false
            fl[k] = f
        end
        return f
    end
    local room, n = {}, 0
    for k0, t0 in pairs(tiles) do
        if not room[k0] then
            n = n + 1
            room[k0] = n
            local stack = { t0 }
            while #stack > 0 do
                local t = stack[#stack]
                stack[#stack] = nil
                local x, y = t[1], t[2]
                local f = flags(x, y)
                if not f then return nil end
                for i, d in ipairs(DIRS) do -- DIRS：北、西、東、南
                    local nk = key(x + d[1], y + d[2])
                    if tiles[nk] and not room[nk] then
                        local open
                        if i == 1 then
                            open = f % 2 == 0
                        elseif i == 2 then
                            open = math.floor(f / 2) % 2 == 0
                        else
                            local g = flags(x + d[1], y + d[2])
                            if not g then return nil end
                            open = (i == 3 and math.floor(g / 2) or g) % 2 == 0
                        end
                        if open then
                            room[nk] = n
                            stack[#stack + 1] = tiles[nk]
                        end
                    end
                end
            end
        end
    end
    return room, n
end

-- 伺服器與單機：塊 ids（{ [編號]＝true }）重算分房，分法變了的主建物連同 list（新挖的格子）一次登錄，再推給附近的玩家
-- （BasementLedger.sendBlock）。回登錄成不成功
local function refresh(ids, list)
    local changed = {}
    for id in pairs(ids) do
        local room, n = Basement.split(id)
        if room and renumber(id, room, n) then
            changed[#changed + 1] = id
            for k, t in pairs(blocks[id].tiles) do
                if not regd[k] then list[#list + 1] = t end
            end
        end
    end
    if #list == 0 then return true end
    local done = Basement.grow(list)
    local L = MinidoracatBuilder.BasementLedger
    for _, id in ipairs(changed) do
        local all = {}
        for _, t in pairs(blocks[id].tiles) do all[#all + 1] = t end
        if L then L.sendBlock(Basement.byRoom(all)) end
    end
    return done
end

-- 開服載入帳本當下（BasementLedger.initSystem，登錄之前）：每塊試一次分房。專用伺服器這時沒有 chunk，先整塊一間，等巡查
function Basement.splitAll()
    for id in pairs(blocks) do
        local room, n = Basement.split(id)
        if room then renumber(id, room, n) end
    end
end

-- 挖好的新格子延後一起登錄（伺服器 BasementLedger.commit、客戶端收到 dug）：每次登錄整塊重建一次房間，一次拖曳每挖好一格
-- 就登錄一次會越挖越慢（實機拖 32 格每次最多 177 ms）。集合、帳本、土牆照舊當下就做（呼叫端），這裡只排登錄：最後一批
-- 加進來之後 GROW_QUIET 毫秒內沒有新的（挖一格 5 秒，Entry.duration），或第一批已經排了 GROW_MAX 毫秒（長的拖曳中途也
-- 登錄），才把排著、還在集合裡又還沒登錄的格子一次登錄。伺服器與單機同一批也重算新格與 Basement.dirty 標過的塊的分房
-- （牆蓋到一半還沒圍起來時分法沒變，不重登錄）。出錯只記 log，沒登錄的格子下一次 registerAll（開服、客戶端收到 basements）補上
Basement.GROW_QUIET, Basement.GROW_MAX = 10000, 60000
local due, stale, dueFirst, dueLast, dueHooked = {}, {}, 0, 0, false
local function flushGrow()
    local t = getTimestampMs()
    if t - dueLast < Basement.GROW_QUIET and t - dueFirst < Basement.GROW_MAX then return end
    Events.OnTick.Remove(flushGrow)
    dueHooked = false
    local list, ids = {}, {}
    for k, v in pairs(due) do
        if cells[k] and not regd[k] then list[#list + 1] = v end
    end
    for k in pairs(stale) do
        if cells[k] then ids[cells[k]] = true end
    end
    due, stale = {}, {}
    local ok, done = pcall(refresh, ids, list)
    if not (ok and done) then print(LOG .. "grow failed: " .. tostring(done)) end
end
local function later()
    dueLast = getTimestampMs()
    if not dueHooked then
        dueHooked, dueFirst = true, dueLast
        Events.OnTick.Add(flushGrow)
    end
end
function Basement.growLater(tiles)
    if #tiles == 0 then return end
    local server = not isClient()
    for _, t in ipairs(tiles) do
        local k = key(t[1], t[2])
        due[k] = t
        if server then stale[k] = true end
    end
    later()
end

-- 伺服器與單機：(x, y, z) 那格或它北、西兩條邊上的東西變了（Place.repush、Place.onAboutToBeRemoved），它所在的塊排進
-- 延後批次重算分房
function Basement.dirty(x, y, z)
    if isClient() or z ~= Z then return end
    local hit = false
    for _, k in ipairs({ key(x, y), key(x, y - 1), key(x - 1, y) }) do
        if cells[k] then stale[k], hit = true, true end
    end
    if hit then later() end
end

-- 伺服器與單機，每遊戲分鐘（BasementLedger 掛 EveryOneMinute）：每位玩家 PATROL 格內的塊重算分房。原版木工、別的 MOD 蓋牆
-- 在伺服器沒有事件（OnObjectAdded 只在 AddItemToMapPacket.processClient 觸發，AddItemToMapPacket.java:59,94）。
-- 沒有地下室時不做事
Basement.PATROL = 16
function Basement.patrol()
    if isClient() then return end
    local any = false
    for _ in pairs(blocks) do any = true break end
    if not any then return end
    local ok, done = pcall(refresh, nearIds(players(), Basement.PATROL), {})
    if not (ok and done) then print(LOG .. "patrol failed: " .. tostring(done)) end
end

-- 客戶端：伺服器分好的房間（{ { { x, y }, ... }, ... }，每間一組格子）換掉那一塊的房號；不在同一塊的格子不收（照舊）。
-- 分法有變時主建物標成未登錄，之後照 NEAR 登錄（呼叫端 registerAll）。回塊編號，或 nil（第一格不在集合裡）
function Basement.setRooms(rooms)
    local first = rooms[1] and rooms[1][1]
    local id = first and cells[key(first[1], first[2])]
    if not id then return nil end
    local b = blocks[id]
    local room, n = {}, b.rooms + #rooms
    for k, r in pairs(b.room) do room[k] = r end
    for i, list in ipairs(rooms) do
        for _, t in ipairs(list) do
            local k = key(t[1], t[2])
            if cells[k] == id then room[k] = b.rooms + i end
        end
    end
    renumber(id, room, n)
    return id
end

-- 這格所在的塊、房號（同一塊而且同一個房號才是同一間）、塊的格數；不在集合裡回 nil
function Basement.roomOf(x, y, z)
    local k = z == Z and key(x, y)
    local id = k and cells[k]
    if not id then return nil end
    local b = blocks[id]
    return id, b.room[k], b.n
end

-- 本機每位玩家的畫面高度範圍重算。預防：引擎只在 chunk 載入與玩家換層時重算高度範圍（IsoChunkMap.java:957,233,945），
-- 挖開新的一層之後自己叫一次，樓梯與開關才畫得出來
function Basement.recalcZ()
    local cell = getCell()
    if not cell then return end
    for n = 0, getNumActivePlayers() - 1 do
        local p = getSpecificPlayer(n)
        local cm = p and cell:getChunkMap(p:getPlayerNum())
        if cm then cm:calculateZExtentsForChunkMap() end
    end
end

-- ---------------------------------------------------------------- 判斷（兩端同一份）
local UNDER = { top = true, mid = true, bottom = true, dig = true }
local STAIR = { top = true, mid = true, bottom = true }

local function at(c) return { x = c.x, y = c.y, z = c.z } end

-- 外來房間（地圖的地下室、Basement Building 的、別的 MOD 的）在 (x, y) 周圍 3×3 內。getRoomAt 在 chunk 沒載入時也查得到（Basements.java:103-128）
local function foreignRoomNear(grid, x, y)
    for dx = -1, 1 do
        for dy = -1, 1 do
            local def = grid:getRoomAt(x + dx, y + dy, Z)
            if def and not has(x + dx, y + dy, Z) and def:getName() ~= Basement.ROOM then return true end
        end
    end
    return false
end

-- 拖曳預覽的併查集（planned.dig = { parent, size }）：節點是排在前面、可以挖的格子（格鍵，z=-1 的鍵都是負數）和已挖的塊（塊編號，
-- 正整數，第一次碰到時加進去、大小＝塊的格數）；size[根]＝那一群連起來有幾格。Basement.plan 每接受一格併一次，digSize 只看
-- 四鄰的根，一次拖曳的成本和格數成正比
local function root(uf, a)
    local p = uf.parent
    while p[a] ~= a do
        p[a] = p[p[a]]
        a = p[a]
    end
    return a
end

-- (x, y) 那一群的根與格數：已挖的照它的塊（併查集裡有就取根），排在前面的照併查集；都不是回 nil
local function group(uf, x, y)
    local k = key(x, y)
    local id = cells[k]
    local node = id or (uf and uf.parent[k] and k)
    if not node then return nil end
    if uf and uf.parent[node] then
        local r = root(uf, node)
        return r, uf.size[r]
    end
    return id, blocks[id].n
end

-- 預覽接受了一格挖掘（Cursor.preview）：記成排在前面（planned[鍵]），z=-1 的格子併進併查集，和四鄰的已挖塊、排在前面的格子連起來
function Basement.plan(planned, x, y, z)
    planned[Place.key(x, y, z)] = true
    local k = key(x, y)
    if z ~= Z or cells[k] then return end
    local uf = planned.dig
    if not uf then
        uf = { parent = {}, size = {} }
        planned.dig = uf
    end
    if uf.parent[k] then return end
    uf.parent[k], uf.size[k] = k, 1
    for _, d in ipairs(DIRS) do
        local x2, y2 = x + d[1], y + d[2]
        local id = cells[key(x2, y2)]
        if id and not uf.parent[id] then uf.parent[id], uf.size[id] = id, blocks[id].n end
        local o = id or (uf.parent[key(x2, y2)] and key(x2, y2))
        if o then
            local a, b = root(uf, k), root(uf, o)
            if a ~= b then
                if uf.size[a] < uf.size[b] then a, b = b, a end
                uf.parent[b], uf.size[a] = a, uf.size[a] + uf.size[b]
            end
        end
    end
end

-- 「挖這一格」c 挖下去之後那一塊有幾格：c 加上四鄰各群（已挖的塊、預覽時排在前面連得上的格子，審查 round1 F15）不重複的格數。
-- near＝c 的四鄰有已挖的或排在前面的。c 本身在集合裡（帳本有、地板沒有，重挖）時它的塊已經算了它，也算 near
local function digSize(c, planned)
    local uf = planned and planned.dig
    local size, near, seen = 1, false, {}
    if has(c.x, c.y, Z) then
        local r, n = group(uf, c.x, c.y)
        seen[r], size, near = true, n, true
    end
    for _, d in ipairs(DIRS) do
        local r, n = group(uf, c.x + d[1], c.y + d[2])
        if r then
            near = true
            if not seen[r] then seen[r], size = true, size + n end
        end
    end
    return size, near
end

-- 這格已經挖開：在集合裡，而且格子在、有地板。帳本有、地板沒有的（當機時帳本存了、chunk 沒存）照沒挖過，准它重挖
local function dug(x, y)
    if not has(x, y, Z) then return false end
    local sq = getCell():getGridSquare(x, y, Z)
    return sq ~= nil and sq:getFloor() ~= nil
end

-- 挖開 c 會打開它和已挖鄰格之間那條邊：hsq 的 k 邊，osq＝邊的北或西側那格。邊上有東西回那一格：土牆上的附加圖
-- （本工具的牆面疊圖掛在土牆上，土牆拆了跟著消失、不退料），或掛在這條邊上的物件（畫、開關這類帶 attached 旗標的，
-- 牆拆了會懸空；那條邊上有玩家自己的實牆時不拆、不懸空，不算）。不替玩家搬，請他先拿下來
local BACK = { N = F.attachedS, W = F.attachedE }
local function hungAt(hsq, osq, k)
    local objects = hsq and hsq:getObjects()
    local wall, hung = false, nil
    for i = 0, (objects and objects:size() or 0) - 1 do
        local o = objects:get(i)
        local kind = dirtOf(o)
        if kind then
            local list = covers(kind, k) and o:getAttachedAnimSprite()
            for j = 0, (list and list:size() or 0) - 1 do
                local spr = list:get(j):getParentSprite()
                local f = spr and faceOf(spr)
                if not f or f == k then return hsq end
            end
        else
            local p = o:getProperties()
            if p then
                wall = wall or p:has(SOLID[k]) or p:has(F.WallNW)
                if p:has(k == "N" and F.attachedN or F.attachedW) then hung = hsq end
            end
        end
    end
    if wall then return nil end
    if hung then return hung end
    objects = osq and osq:getObjects()
    for i = 0, (objects and objects:size() or 0) - 1 do
        local p = objects:get(i):getProperties()
        if p and p:has(BACK[k]) then return osq end
    end
    return nil
end

-- 入口出口那條邊（sq 的 k 邊）擋路：牆、窗框、柵欄這類佔住那條邊的。門框與門走得過，不算
local EXIT = { N = { F.WallN, F.WallNW, F.WallNTrans, F.WindowN, F.HoppableN, F.TallHoppableN, F.collideN },
    W = { F.WallW, F.WallNW, F.WallWTrans, F.WindowW, F.HoppableW, F.TallHoppableW, F.collideW } }
local DOORWAY = { N = F.DoorWallN, W = F.DoorWallW }
local function exitBlocked(sq, k)
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        local p = o:getProperties()
        local door = instanceof(o, "IsoDoor") or (instanceof(o, "IsoThumpable") and o:isDoor())
        if p and not door and not p:has(DOORWAY[k]) then
            for _, f in ipairs(EXIT[k]) do
                if p:has(f) then return true end
            end
        end
    end
    return false
end

local function pos(sq) return { x = sq:getX(), y = sq:getY(), z = sq:getZ() } end

-- 挖開 c 會不會打通不該通的地方：周圍有外來房間、已挖的鄰格沒有權限（不然在安全屋外緊貼邊界挖一格，兩格之間的土牆
-- 消失就打通進去了）、打開的那條邊上有掛件。回 code, extra 或 nil。直接挖（pre）和收編帳本缺的格子（BasementLedger）
-- 同一套；also＝這一批已經算挖開、還沒進集合的格鍵（Place.key）
function Basement.opens(player, c, preview, also)
    if foreignRoomNear(getWorld():getMetaGrid(), c.x, c.y) then return "DIG_ROOM", at(c) end
    local Check, cell = MinidoracatBuilder.Check, getCell()
    for _, d in ipairs(DIRS) do
        local nx, ny = c.x + d[1], c.y + d[2]
        if has(nx, ny, c.z) or (also and also[Place.key(nx, ny, c.z)]) then
            local nsq = cell:getGridSquare(nx, ny, c.z)
            local code = Check.safehouse(player, { x = nx, y = ny, z = c.z, sq = nsq }, preview, "dismantle")
            if code then return code, { x = nx, y = ny, z = c.z } end
            -- 這條邊在 c 的北、西（鄰格在北、西）時土牆在 c 那格，否則在鄰格
            local csq, south = cell:getGridSquare(c.x, c.y, c.z), d[1] + d[2] > 0
            local hung = hungAt(south and nsq or csq, south and csq or nsq, d[1] ~= 0 and "W" or "N")
            if hung then return "DIG_HUNG", pos(hung) end
        end
    end
    return nil
end

-- Check.item 補格子之前跑（只讀座標與已經存在的格子）：回 code, extra, skip（skip＝加開入口，Check.item 把角色 dig 的
-- 6 格拿掉）。順序就是回報的優先序
function Basement.pre(player, entry, cells, anchor, planned, preview)
    if Basement.bd() then return "DIG_BD" end
    local entrance = false
    for _, c in ipairs(cells) do
        if not inRange(c.x, c.y) then return "BLOCKED", at(c) end
        if STAIR[c.role] then entrance = true end
    end
    if anchor[3] ~= (entrance and 0 or Z) then return "DIG_LEVEL", { x = anchor[1], y = anchor[2], z = anchor[3] } end
    -- 入口：樓梯三格已經在集合裡幾格（3 而且同一塊＝加開）
    local stairs, inSet, blk, same, top, bottom = 0, 0, nil, true, nil, nil
    for _, c in ipairs(cells) do
        if STAIR[c.role] then
            stairs = stairs + 1
            if c.role == "top" then top = c elseif c.role == "bottom" then bottom = c end
            local id = Basement.blockOf(c.x, c.y, c.z)
            if id then
                inSet = inSet + 1
                if blk and blk ~= id then same = false end
                blk = blk or id
            end
        end
    end
    local skip = entrance and inSet == stairs and same
    -- 加開入口：樓梯底端前面那格也要已經挖開（同一塊），不然下了樓梯面對土牆（審查 round1 F6）
    if skip and top and bottom then
        local east = bottom.x ~= top.x -- 樓梯只往南或往東下
        local fx, fy = bottom.x + (east and 1 or 0), bottom.y + (east and 0 or 1)
        -- 那格真的挖開了（格子在、有地板），樓梯底到它那條邊（它的北邊或西邊）走得過
        local fsq = dug(fx, fy) and getCell():getGridSquare(fx, fy, Z)
        if Basement.blockOf(fx, fy, Z) ~= blk or not fsq or exitBlocked(fsq, east and "W" or "N") then
            return "DIG_ENTRY", { x = fx, y = fy, z = Z }
        end
    end
    local grid = getWorld():getMetaGrid()
    for _, c in ipairs(cells) do
        if UNDER[c.role] and not (skip and c.role == "dig") and foreignRoomNear(grid, c.x, c.y) then
            return "DIG_ROOM", at(c)
        end
    end
    local dig = {} -- 這次要挖的格子
    if not entrance then
        local c = cells[1]
        if dug(c.x, c.y) then return "DIG_DONE", at(c) end
        local size, near = digSize(c, planned)
        if not near then return "DIG_EDGE", at(c) end
        if size > Basement.MAX then return "DIG_FULL", { max = Basement.MAX, x = c.x, y = c.y, z = c.z } end
        dig[1] = c
    elseif not skip then
        if inSet > 0 then return "DIG_ENTRY", { x = anchor[1], y = anchor[2], z = anchor[3] } end
        -- 新開：9 格都不在集合、四鄰也都不在（要連通請用「挖這一格」，那條路會查權限）
        for _, c in ipairs(cells) do
            if UNDER[c.role] then
                if has(c.x, c.y, c.z) then return "DIG_ROOM", at(c) end
                for _, d in ipairs(DIRS) do
                    if has(c.x + d[1], c.y + d[2], c.z) then return "DIG_ROOM", at(c) end
                end
                dig[#dig + 1] = c
            end
        end
    end
    for _, c in ipairs(dig) do
        local code, extra = Basement.opens(player, c, preview, nil)
        if code then return code, extra end
    end
    local cell = getCell()
    local plat
    for _, c in ipairs(cells) do
        if c.role == "platform" then plat = c end
        if c.role == "platform" or c.role == "hole" then
            local sq = cell:getGridSquare(c.x, c.y, c.z)
            if sq then
                local ok, code = Basement.checkCell(sq, c.role, c.spr)
                if not ok then return code, at(c), skip end
            end
        end
    end
    -- 入口的出口（同 Place.lua stairsOk 一般樓梯的兩條）：平台不是樓梯、也不是別組同向樓梯的平台（placeStairs 記的
    -- ConnectedToStairs）；樓梯頂正上方那個洞朝平台的那條邊走得過，不然上了樓梯面對牆。平台在頂片西邊＝往西爬
    if top and plat then
        local west = plat.x ~= top.x
        local psq, hsq = cell:getGridSquare(plat.x, plat.y, plat.z), cell:getGridSquare(top.x, top.y, 0)
        if psq and (psq:HasStairs() or (psq:hasModData() and psq:getModData()["ConnectedToStairs" .. tostring(not west)])) then
            return "BLOCKED", at(plat), skip
        end
        if hsq and exitBlocked(hsq, west and "W" or "N") then return "BLOCKED", pos(hsq), skip end
    end
    return nil, nil, skip
end

-- 洞那格上可以跟著拆或留著的：地板（不是水面）、草與可移除的植物、格邊的牆與牆上的掛件。開洞會拆的那幾種（openHole）
-- 另外不收：多格的一組（引擎整組拆，連沒驗過的格子，IsoGridSquare.java:5929-5960、IsoObjectUtils.isObjectMultiSquare）、
-- 掛著本工具地面覆蓋的地板（拆了覆蓋和它的退料跟著不見，同水面 waterOk）；地毯是能搬的家具，也不收（審查 round1 F2、F5）
local function holeOk(o)
    local p = o:getProperties()
    if not p then return false end
    local tex = o:getTextureName()
    if Place.isRug(tex, p) then return false end
    if p:has(F.solidfloor) then
        if p:has(F.water) or p:has(F.taintedWater) then return false end
    elseif not (p:has(F.canBeRemoved) or (p:has(F.vegitation) and o:getType() ~= T.tree)
        or (tex and tex:find("blends_grassoverlays", 1, true))) then
        return p:has(F.WallN) or p:has(F.WallW) or p:has(F.WallNW) or p:has(F.WallSE) or p:has(F.attachedN)
            or p:has(F.attachedW)
    end
    -- 引擎整組拆的條件（同 IsoObjectUtils.isObjectMultiSquare，那個類別沒開放給 Lua）：雙開門、車庫門、SpriteConfig 多格、sprite grid
    if IsoDoor.getDoubleDoorIndex(o) ~= -1 or IsoDoor.getGarageDoorIndex(o) ~= -1 then return false end
    local cfg = o:getSpriteConfig()
    if cfg and cfg:isValidMultiSquare() then return false end
    local spr = o:getSprite()
    if spr and spr:getSpriteGrid() then return false end
    local hung = o:hasModData() and o:getModData().builderOverlays
    if type(hung) == "table" then
        for _ in pairs(hung) do return false end
    end
    return true
end

-- Place.check 的 dig 分支：回 true，或 false 與原因碼
function Basement.checkCell(sq, role, spr)
    if role == "dig" then return true end -- 已經有地板也過（帳本缺的格子挖了就重新記）
    if role == "platform" then
        if not sq:getFloor() or sq:isSolid() or sq:isSolidTrans() then return false, "BLOCKED" end
        return true
    end
    if role == "hole" then
        if sq:isVehicleIntersecting() or not sq:getMovingObjects():isEmpty() then return false, "OCCUPIED" end
        if sq:HasStairs() or sq:getWorldObjects():size() > 0 or not sq:getStaticMovingObjects():isEmpty() then
            return false, "DIG_CLEAR"
        end
        local objects = sq:getObjects()
        for i = 0, objects:size() - 1 do
            if not holeOk(objects:get(i)) then return false, "DIG_CLEAR" end
        end
        return true
    end
    if STAIR[role] then
        if sq:HasStairs() or sq:isSolid() or sq:isSolidTrans() then return false, "BLOCKED" end
        if not sq:getMovingObjects():isEmpty() then return false, "OCCUPIED" end
        return true
    end
    return false, "BLOCKED"
end

return Basement
