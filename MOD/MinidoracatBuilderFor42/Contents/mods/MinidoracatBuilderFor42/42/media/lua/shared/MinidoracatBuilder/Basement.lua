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

Basement.ROOM = "mdcbuilderbasement" -- 房間名：認「是不是本 MOD 的房間」時用（登錄、能不能挖、客戶端補切房間燈）
Basement.MAX = 400                   -- 一塊最多幾格（＝Circuits.ROOM_MAX）
-- 外邊土牆的圖：判斷「是不是土牆」一律查這張表。原版的土牆圖沒有屬性，牆屬性來自本 MOD 的圖塊補丁檔
-- media/mdcbuilder_basement.patch.tiles（scripts/gen_basement_tiles.py 寫出，和 Basement Building 的那三格相同）
Basement.DIRT = { W = "underground_01_8", N = "underground_01_9", NW = "underground_01_10" }
-- 外凸轉角的牆角柱（圖塊補丁給它原版轉角柱 walls_exterior_house_02_99 的 WallSE；不擋路、不擋視線、不隔開房間）
Basement.POST = "underground_01_11"
Basement.AREA = 256                  -- 同步用的大區邊長
-- 地下室的 x、y 只收 0 ≤ 值 < LIMIT：格子鍵（Place.key）每軸 5 位數，再大就和別格撞鍵
Basement.LIMIT = 100000
local Z = -1
local BIG = 1e15
local DIRS = { { 0, -1 }, { -1, 0 }, { 1, 0 }, { 0, 1 } }
local EDGE = { N = { 0, -1 }, W = { -1, 0 } }
local OTHER = { N = "W", W = "N" }

-- cells[鍵]＝連通塊編號；blocks[編號]＝{ n＝格數, tiles＝{ [鍵]＝{ x, y } }, box＝{ x0, y0, x1, y1 } 包圍盒（含邊），
-- room＝{ [鍵]＝房號 }（同一個房號＝同一間；號碼不必連續）, rooms＝用過的最大房號, todo＝有還沒登錄的格子或要重建的棟
-- （客戶端 registerNear 只看它、不走格子）；客戶端另有 v＝套用過的伺服器修訂號（block、快照）, wait＝開始等 block 的時間,
-- fresh＝{ [鍵]＝true } 收到 dug 之後還沒等到 block 或快照的格子, stale＝在最近一份快照的範圍外（之後的 dug、block 收不到，
-- 手上的可能是舊的）}
-- bof[鍵]＝這一場這格登錄進的那一棟 { cx, cy＝metaID 的角, lx, ly＝它外框左上角所在的地圖格（256 格一格，引擎照這一格找
-- 同一棟）, tiles＝{ [鍵]＝{ x, y } } }，nil＝還沒登錄；redo[棟]＝下一次登錄要整棟重建。棟跟著格子走，不跟著塊：兩塊併起來
-- 兩邊的棟都留著。swTiles[鍵]＝專用伺服器上裝了牆上開關的格子（不放進引擎房間，Basement.setSwitchTile）
-- Basement.saved＝伺服器與單機的帳本記的房號（BasementLedger 設：get(x, y)＝房號或 nil、put(x, y, 房號)＝記成了沒）；客戶端是 nil
local cells, blocks, bof, redo, swTiles, lastId = {}, {}, {}, {}, {}, 0
local anyCell = false -- 這一份加過格子沒有（Basement.any）：沒有地下室的存檔不讀格子、不排登錄

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
    if not anyCell then return false end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    return z == Z and (has(x, y, z) or has(x, y - 1, z) or has(x - 1, y, z))
end

-- 兩塊併成一塊：小的那塊重標成大的。兩邊登錄過的棟都留著（bof 照格子記）；修訂號取大的、開始等的時間取早的
local function merge(a, b)
    if blocks[a].n < blocks[b].n then a, b = b, a end
    local A, B = blocks[a], blocks[b]
    for k, t in pairs(B.tiles) do
        A.tiles[k], cells[k], A.room[k] = t, a, B.room[k] + A.rooms
    end
    A.n, A.rooms, A.todo = A.n + B.n, A.rooms + B.rooms, A.todo or B.todo
    local p, q = A.box, B.box
    p[1], p[2], p[3], p[4] = math.min(p[1], q[1]), math.min(p[2], q[2]), math.max(p[3], q[3]), math.max(p[4], q[4])
    if B.v and not (A.v and A.v >= B.v) then A.v = B.v end
    if B.wait and not (A.wait and A.wait <= B.wait) then A.wait = B.wait end
    if B.fresh then
        A.fresh = A.fresh or {}
        for k in pairs(B.fresh) do A.fresh[k] = true end
    end
    blocks[b] = nil
    return a
end

-- tiles＝{ { x, y }, ... }（z 固定 -1）：加進集合、併連通塊；回真的新增的那幾格。範圍外的（inRange）不收。
-- 新格取第一個相鄰已挖格的房號，不改既有格子的房號：中間的牆拆了之後要不要併成一間，等伺服器照牆重算（split）。
-- 加了新格的塊不算範圍外（客戶端只加已同步範圍內的格子：dug、block、快照）
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
            cells[k], b.n, b.tiles[k], b.room[k], b.todo, b.stale = id, b.n + 1, xy, r or 1, true, nil
            anyCell = true
            local box = b.box
            box[1], box[2], box[3], box[4] = math.min(box[1], x), math.min(box[2], y), math.max(box[3], x), math.max(box[4], y)
            added[#added + 1] = xy
        end
    end
    return added
end

-- 加過格子沒有（之後全拿掉也算加過）：Client.askEveryMinute 沒有就不排登錄
function Basement.any() return anyCell end

-- 大區 (ax, ay) 與周圍一圈（3×3 個大區）的範圍：x0 ≤ x < x1、y0 ≤ y < y1
local function range(ax, ay)
    local A = Basement.AREA
    return (ax - 1) * A, (ay - 1) * A, (ax + 2) * A, (ay + 2) * A
end

-- 客戶端收到 basements：大區 (ax, ay) 周圍 3×3 範圍內的格子整份換成 tiles（範圍外的不動、tiles 裡範圍外的不收）；還在等
-- block 的格子（fresh，比這份快照新的 dug）留著，範圍內的塊不再等（這一次登錄含它們）。包圍盒碰不到範圍的塊記成範圍外
-- （stale）：之後收不到它的 dug、block，走回去時手上的可能是舊的，等涵蓋它的快照到了才登錄（Basement.registerNear）。
-- 有格子被拿掉時連通塊整份重算（房號照舊分）；拿掉的格子從它登錄進的那一棟移除、不再算登錄過（之後又挖回來要重新登錄），
-- 那一棟下一次登錄整棟重建；角那一格被拿掉的棟維持原狀（重建會換角，引擎找不到舊的那一棟，拿掉的格子在引擎裡留到下一次
-- 進場）。回真的新增的那幾格
function Basement.reset(tiles, ax, ay)
    local x0, y0, x1, y1 = range(ax, ay)
    local keep, inside = {}, {}
    for _, t in ipairs(tiles) do
        if t[1] >= x0 and t[1] < x1 and t[2] >= y0 and t[2] < y1 then
            keep[key(t[1], t[2])] = true
            inside[#inside + 1] = t
        end
    end
    local rest, gone = {}, {}
    for k, id in pairs(cells) do
        local b = blocks[id]
        local t = b.tiles[k]
        if keep[k] or (b.fresh and b.fresh[k]) or t[1] < x0 or t[1] >= x1 or t[2] < y0 or t[2] >= y1 then
            rest[#rest + 1] = t
        else
            gone[#gone + 1] = k
        end
    end
    if #gone > 0 then
        -- 舊的塊與房號（重算後照它分間）：只在要重算時才走一次，沒有格子被拿掉的快照（大多數）不配
        local was = {}
        for k, id in pairs(cells) do was[k] = id .. ":" .. blocks[id].room[k] end
        for _, k in ipairs(gone) do
            local r = bof[k]
            if r then r.tiles[k], bof[k], redo[r] = nil, nil, true end
        end
        cells, blocks = {}, {}
        Basement.add(rest)
        local frozen = {}
        for r in pairs(redo) do
            if not cells[key(r.cx, r.cy)] then frozen[#frozen + 1] = r end
        end
        for _, r in ipairs(frozen) do redo[r] = nil end
        for _, b in pairs(blocks) do
            local map, n = {}, 0
            for k in pairs(b.tiles) do
                local w = was[k]
                if not map[w] then n, map[w] = n + 1, n + 1 end
                b.room[k] = map[w]
            end
            b.rooms = n
        end
    end
    for _, b in pairs(blocks) do
        local box = b.box
        if box[1] < x1 and box[3] >= x0 and box[2] < y1 and box[4] >= y0 then
            b.fresh, b.wait, b.stale = nil, nil, nil
        else
            b.stale = true
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
-- Basement.bdOn（每次檢查都掃一遍 MOD 清單太浪費；測試改清單時清成 nil）
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
-- 矩形，左上角「x 不大於、y 小於」目前的角才換（BuildingDef.java:319-348），一棟裡沒有「x ≤ cx 而且 y < cy」的格子（那些另起
-- 一棟），角不變 metaID 就不變。沒給角時第一個矩形的左上角是最北那一列最西的格子，後面的矩形沒有更北的。
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

-- 格點 (x, y)（格子 (x, y) 的西北角）是外凸轉角：西北那格沒挖、其他三格挖了。兩面土牆都在格點收尾，中間的縫由
-- 格子 (x, y) 的牆角柱補上（引擎把 WallSE 畫在所在那格的西北角，IsoGridSquare.java:1729-1731）。其他轉角都有一面牆蓋過格點
function Basement.isCorner(x, y)
    return has(x, y, Z) and has(x - 1, y, Z) and has(x, y - 1, Z) and not has(x - 1, y - 1, Z)
end

-- 本 MOD 放的牆角柱：圖是 Basement.POST、不是 IsoThumpable，所在格點周圍四格有一格在集合裡
function Basement.isPost(o)
    local spr = o:getSprite()
    local sq = spr and spr:getName() == Basement.POST and not instanceof(o, "IsoThumpable") and o:getSquare()
    if not sq or sq:getZ() ~= Z then return false end
    local x, y = sq:getX(), sq:getY()
    return has(x, y, Z) or has(x - 1, y, Z) or has(x, y - 1, Z) or has(x - 1, y - 1, Z)
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

-- 這格北、西兩條邊照外邊補或拆土牆，西北角照外凸轉角補或拆牆角柱。held＝當成已經有實牆的那條邊（clearDirt：玩家的牆剛蓋上）。
-- 實牆＝土牆以外帶 WallN／WallW／WallNW 的物件（引擎護著不讓人穿過的那幾種）。兩條邊都要土牆時放西北角那一張。
-- 牆角柱只放在兩條邊上都沒有東西的格子：牆、門框、窗都會蓋住格點，而且引擎分房時帶 WallSE 的格子不算西邊隔開
-- （IsoRegions.java:336），柱留著會讓玩家在這格西邊蓋的牆不隔開房間
local function fix(sq, held)
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local objects, dirt, posts, wallN, wallW, edged = sq:getObjects(), {}, {}, held == "N", held == "W", false
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        local kind = dirtOf(o)
        if kind then
            dirt[#dirt + 1] = { o, kind }
        elseif Basement.isPost(o) then
            posts[#posts + 1] = o
        else
            local p = o:getProperties()
            if p and p:has(F.WallNW) then wallN, wallW = true, true end
            if p and p:has(F.WallN) then wallN = true end
            if p and p:has(F.WallW) then wallW = true end
            edged = edged or (p and (p:has(F.cutN) or p:has(F.cutW) or p:has(F.WallSE))) or false
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
    local post = not (wallN or wallW or edged) and Basement.isCorner(x, y)
    for i, o in ipairs(posts) do
        if not (post and i == 1) then
            sq:transmitRemoveItemFromSquare(o)
            changed = true
        end
    end
    if post and #posts == 0 then
        local obj = IsoObject.new(getCell(), sq, Basement.POST)
        sq:AddTileObject(obj)
        obj:transmitCompleteItemToClients()
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

-- 排到下一個 tick 跑 fixEdges（移除事件裡還在拆的物件這時已經不在）；沒有待辦時不掛 OnTick。
-- fix 拆土牆、柱時經 Place.onAboutToBeRemoved 又 touch：hooked 還是 true、不重掛，留到下一個 tick 跑完才摘
-- （引擎走訪 OnTick 時，處理器在自己裡面先摘再掛，排在它後面的那一個這個 tick 會被跳過，Event.java:45-47）
local pending, hooked = {}, false
local function flush()
    local list = pending
    pending = {}
    for _, p in pairs(list) do Basement.fixEdges(p[1], p[2], p[3]) end
    for _ in pairs(pending) do return end -- Kahlua 沒有全域 next
    Events.OnTick.Remove(flush)
    hooked = false
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
-- 伺服器的 chunk 不放進 chunkMap（CellLoader.java:423、IsoCell.java:4005、IsoChunkMap.java:407-410，走 ServerMap），
-- 已載入的格子照那段自己掛。setRoomID：不設 getRoom 回 null；接著 setRoom：Lua 的數字是 double，房間 ID 超過 2^53 時低位會丟，
-- setRoomID 可能拿到別的房間（IsoGridSquare.java:9414-9420），用房間物件蓋掉；RecalcProperties：setRoomID 拿掉了室外旗標。
-- 房間燈、重畫不做（伺服器不算光照、不畫，BuildingRoomsEditor.java:385-397）；尋路不看房間，新挖的格子能不能走由鋪地板、
-- 放牆時引擎自己通知。
-- 這一棟的開關格（sw＝{ { x, y }, ... }）已載入又掛著房間就摘掉（矩形裡留著的開關格：角、換地圖格，上面照樣掛，在這裡摘；
-- chunk 重新讀進時照 metaGrid 掛回的也在下一次登錄摘）：setRoomID(-1) 之後 getRoom 回 null（IsoGridSquare.java:9220-9222），
-- 開關切換時不送房間燈（IsoLightSwitch.java:519-535）；舊建物被換掉後沒重掛的格子還指著 def 已清成 null 的
-- 舊房間（BREBuilding.java:230-242、IsoRoom.java:672-674），切開關會丟 NPE（IsoLightSwitch.java:520），所以不能省
local function hang(cell, def, rects, sw)
    local room, id = def:getIsoRoom(), def:getID()
    if not room then return end
    for _, r in ipairs(rects) do
        for x = r[1], r[1] + r[3] - 1 do
            for y = r[2], r[2] + r[4] - 1 do
                local sq = cell:getGridSquare(x, y, Z)
                if sq then
                    sq:setRoomID(id)
                    sq:setRoom(room)
                    sq:RecalcProperties()
                end
            end
        end
    end
    for _, t in ipairs(sw) do
        local sq = cell:getGridSquare(t[1], t[2], Z)
        if sq and sq:getRoom() then sq:setRoomID(-1) end
    end
end

-- 一批建物一次 applyChanges（成本是整張地圖的檢查與重算，BuildingRoomsEditor.java:216-267,269-325，和這批幾棟關係很小）。
-- plans＝{ rooms, ... }，每棟一組房間、每間一組矩形（rooms[1][1] 是 metaID 的角；一棟叫多次 createRoom，BREBuilding.java:50-58）；
-- sws[i]＝第 i 棟的開關格（伺服器 hang 摘掉）。
-- 回 ok：ok[i]＝第 i 棟登錄好了（套用後角那一格是新的本 MOD 名稱房間、每一間的第一格都查得到本 MOD 名稱的房間；引擎沒建出來、
-- 角上是別的房間、原地重登錄時舊的那間還在都不算。查的是 metaGrid，矩形裡的格子都查得到，不看格子有沒有掛房間）。
-- 客戶端與單機有一棟登錄好了就呼叫 Basement.onApplied（新登錄的房間燈是暗的，BRERoom.java:9-15，由它照開關補）
local function apply(plans, sws)
    local ok = {}
    if not (BuildingRoomsEditor and BuildingRoomsEditor.getInstance) then
        print(LOG .. "BuildingRoomsEditor is missing; the game update may have changed it")
        return ok
    end
    BuildingRoomsEditor.Reset()
    local editor = BuildingRoomsEditor.getInstance()
    editor:setCurrentBuilding(nil)
    -- 只用 createBuilding／createRoom／addRectangle：init() 會把 32×32 內的建物都拿出來編輯，非 userDefined 的記成移除
    -- （BuildingRoomsEditor.java:81-93,220-229）。不呼叫 canAddRoomRectangle：它對相鄰的別棟回 false（:107-161），另起的棟
    -- 一定貼著別棟；改看 isValid
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
                if server then hang(cell, d, rects, sws[i]) end
            end
        else
            print(LOG .. "no RoomDef after register at " .. c[1] .. "," .. c[2])
        end
    end
    if not server and Basement.onApplied then
        local any = false
        for _ in pairs(ok) do any = true break end
        if any then
            local fine, e = pcall(Basement.onApplied)
            if not fine then print(LOG .. "onApplied failed: " .. tostring(e)) end
        end
    end
    return ok
end

-- 引擎找「同一棟」只在新建物外框左上角所在的地圖格裡照 metaID 找（BREBuilding.getLotHeader：BuildingDef.x／256、y／256，
-- BuildingRoomsEditor.java:233-248）：併進一棟的格子讓外框左上角換到西邊或北邊那一格時，舊的那棟找不到、留在引擎裡和新的疊在一起
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

-- 包圍盒離 ps 任一位 N 格內的塊：{ [編號]＝true }。玩家座標先取進陣列：內圈是（塊 × 玩家），不在那裡叫 Java
local function nearIds(ps, N)
    local xs, ys, n = {}, {}, 0
    for _, p in ipairs(ps) do
        n = n + 1
        xs[n], ys[n] = p:getX(), p:getY()
    end
    local near = {}
    for id, b in pairs(blocks) do
        local box = b.box
        local x1, y1, x2, y2 = box[1] - N, box[2] - N, box[3] + N, box[4] + N
        for i = 1, n do
            local x, y = xs[i], ys[i]
            if x >= x1 and x <= x2 and y >= y1 and y <= y2 then
                near[id] = true
                break
            end
        end
    end
    return near
end

-- 格子照房號分組：{ { { x, y }, ... }, ... }（每間一組，房間順序不定；不同塊的同一個房號是不同間）
function Basement.byRoom(tiles)
    local at, out = {}, {}
    for _, t in ipairs(tiles) do
        local k = key(t[1], t[2])
        local id = cells[k]
        local r = id .. ":" .. blocks[id].room[k]
        local list = at[r]
        if not list then
            list = {}
            at[r], out[#out + 1] = list, list
        end
        list[#list + 1] = t
    end
    return out
end

-- 客戶端與單機的一棟（ts＝它的格子，含角 (cx, cy)）：照房號分組、各自切矩形，含角的那間排第一（引擎依序走每間的矩形取角，
-- BuildingDef.java:319-348）。回 { rects, ... }
local function roomsOf(ts, cx, cy)
    local out = { false }
    for _, list in ipairs(Basement.byRoom(ts)) do
        local rects = Basement.rects(list, cx, cy)
        if rects[1][1] == cx and rects[1][2] == cy then out[1] = rects else out[#out + 1] = rects end
    end
    return out
end

-- 格上有牆上開關（IsoLightSwitch、圖過 Rules.switchProps）
local function wallSwitchOn(sq)
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        local spr = instanceof(o, "IsoLightSwitch") and o:getSprite()
        if spr and MinidoracatBuilder.Rules.switchProps(spr:getProperties()) then return true end
    end
    return false
end

-- 專用伺服器的一棟 r（ts＝它的格子）：一間，矩形＝格子扣掉開關格。兩個例外照舊留在矩形裡：角那格是開關格（換角引擎就找不到
-- 舊的那一棟）、扣掉開關格會讓外框左上角換到別的地圖格（同理）。已載入、格上已經沒有牆上開關的開關格不再算。
-- 回 { rects }、這一棟的開關格（hang 摘房間）。shortcut: 換地圖格時開關格全部留著，只在外框剛好在地圖格邊上時發生
local function serverRoom(ts, r, cell)
    local keep, sw, x0, y0 = {}, {}, BIG, BIG
    for _, t in ipairs(ts) do
        local k = key(t[1], t[2])
        if swTiles[k] then
            local sq = cell:getGridSquare(t[1], t[2], Z)
            if sq and not wallSwitchOn(sq) then swTiles[k] = nil end
        end
        if swTiles[k] then
            sw[#sw + 1] = t
        else
            keep[#keep + 1] = t
            x0, y0 = math.min(x0, t[1]), math.min(y0, t[2])
        end
    end
    local moved = lotOf(x0) ~= r.lx or lotOf(y0) ~= r.ly
    for _, t in ipairs(sw) do
        if moved or (t[1] == r.cx and t[2] == r.cy) then keep[#keep + 1] = t end
    end
    return { Basement.rects(keep, r.cx, r.cy) }, sw
end

-- ts 照 (y, x) 由小到大逐一 fn(t)。不排序（Kahlua 的 table.sort 會溢位）：照 Basement.rects 逐列掃 x 的範圍。
-- shortcut: 格子散得很開時多走空格；呼叫端一次只給一塊的格子
local function inOrder(ts, fn)
    local at, rows, y0, y1 = {}, {}, BIG, -BIG
    for _, t in ipairs(ts) do
        local x, y = t[1], t[2]
        at[key(x, y)] = t
        local r = rows[y]
        if r then
            r[1], r[2] = math.min(r[1], x), math.max(r[2], x)
        else
            rows[y] = { x, x }
        end
        y0, y1 = math.min(y0, y), math.max(y1, y)
    end
    for y = y0, y1 do
        local r = rows[y]
        for x = r and r[1] or 1, r and r[2] or 0 do
            local t = at[key(x, y)]
            if t then fn(t) end
        end
    end
end

-- (x, y) 併進棟 r 不會換掉它的 metaID 或地圖格：不在角的西北方（x ≤ cx 而且 y < cy，calculateMetaID 會換角）、不在它地圖格的
-- 西邊或北邊
local function canJoin(r, x, y)
    return not (x <= r.cx and y < r.cy) and lotOf(x) >= r.lx and lotOf(y) >= r.ly
end

-- 棟 r 還能重建、收格子：角那格還在集合裡（角被拿掉的棟維持原狀）
local function alive(r) return cells[key(r.cx, r.cy)] ~= nil end

-- 集合裡還沒登錄的格子 list 與標成要重建的棟（redo）一次登錄。新格子照北、西、東、南看四鄰已登錄的棟，第一個收得下的
-- （canJoin）就併進去，再從併進的格子往四鄰擴（四鄰含這一批剛併的格子，同樣照北、西、東、南找第一個收的棟）；擴不到的
-- 照 (y, x) 取第一格自己起一棟（角＝它自己）再往外擴，直到每格都處理過。
-- 有變的棟整棟重登錄（角不變：同地圖格、同 metaID，引擎換掉舊的，BuildingRoomsEditor.java:233-248）。每一棟登錄好了才記下
-- 它的格子（apply 的 ok）。
-- 專用伺服器一棟一間、扣掉開關格（serverRoom）；開關格不當新一棟的角，只會被擴進去，哪裡都併不進去的開關格不登錄。
-- 客戶端與單機照房號分間（roomsOf）。
-- 客戶端照身邊觸發：有塊的包圍盒離任一位本機玩家 NEAR 格內才登錄（觸發距離）。chunkMap 最寬 19 個 chunk＝152 格、
-- 半寬 76 格（IsoChunkMap.java:60,112-120），其餘留給下一次檢查（Client.askEveryMinute）之前走過去的距離；登錄晚於 chunk
-- 載入時 applyChanges 會替本機已載入的格子補上房間（BuildingRoomsEditor.java:369-411,413-436）。觸發時遠處合格的塊一起
-- 登錄（搭便車，Basement.registerNear），同一次 applyChanges；沒有身邊的塊要登錄時遠的留著不登錄。
-- 伺服器（與單機）全部登錄：它的 chunk 載入時靠 metaGrid 裡已經有房間。選用的第二個參數 only＝{ [編號]＝true }：只登錄
-- 這幾塊的格子與棟（Basement.registerNear 已經挑過）
Basement.NEAR = 128
local function register(list, ...)
    local only = ...
    local server, client, near = isServer(), isClient(), nil
    local function close(id) -- 客戶端：塊 id 在身邊（用到才算，沒有要登錄的就不走玩家）
        if only then return only[id] == true end
        if not client then return true end
        near = near or nearIds(players(), Basement.NEAR)
        return near[id] == true
    end
    local by, order, seen = {}, {}, {}
    for _, t in ipairs(list) do
        local k = key(t[1], t[2])
        local id = cells[k]
        if id and not bof[k] and not seen[k] and close(id) then
            seen[k] = true
            if not by[id] then
                by[id] = {}
                order[#order + 1] = id
            end
            local ts = by[id]
            ts[#ts + 1] = t
        end
    end
    -- pend[鍵]＝這一批併進的棟；grown[棟]＝它這一批新加的格子；touched＝這一批要登錄的棟（照先後）
    local pend, grown, touched = {}, {}, {}
    local function take(r, t)
        pend[key(t[1], t[2])] = r
        local g = grown[r]
        if not g then
            g = {}
            grown[r], touched[#touched + 1] = g, r
        end
        g[#g + 1] = t
    end
    local function join(t, batch)
        for _, d in ipairs(DIRS) do
            local nk = key(t[1] + d[1], t[2] + d[2])
            local r = bof[nk] or (batch and pend[nk])
            if r and alive(r) and canJoin(r, t[1], t[2]) then
                take(r, t)
                return true
            end
        end
        return false
    end
    for _, id in ipairs(order) do
        local rest, todo = {}, {}
        local function spread(queue)
            local i = 1
            while queue[i] do
                local q = queue[i]
                i = i + 1
                for _, d in ipairs(DIRS) do
                    local nk = key(q[1] + d[1], q[2] + d[2])
                    local u = todo[nk]
                    if u and join(u, true) then
                        todo[nk] = nil
                        queue[#queue + 1] = u
                    end
                end
            end
        end
        local joined = {}
        for _, t in ipairs(by[id]) do
            if join(t, false) then
                joined[#joined + 1] = t
            else
                rest[#rest + 1] = t
                todo[key(t[1], t[2])] = t
            end
        end
        spread(joined)
        inOrder(rest, function(t)
            local k = key(t[1], t[2])
            if todo[k] and not (server and swTiles[k]) then
                todo[k] = nil
                take({ cx = t[1], cy = t[2], lx = lotOf(t[1]), ly = lotOf(t[2]), tiles = {} }, t)
                spread({ t })
            end
        end)
    end
    for r in pairs(redo) do
        if not grown[r] and alive(r) and close(cells[key(r.cx, r.cy)]) then
            grown[r], touched[#touched + 1] = {}, r
        end
    end
    if #touched == 0 then return true end
    local plans, sws, cell = {}, {}, server and getCell()
    for i, r in ipairs(touched) do
        local ts = {}
        for _, t in pairs(r.tiles) do ts[#ts + 1] = t end
        for _, t in ipairs(grown[r]) do ts[#ts + 1] = t end
        if server then
            plans[i], sws[i] = serverRoom(ts, r, cell)
        else
            plans[i], sws[i] = roomsOf(ts, r.cx, r.cy), {}
        end
    end
    local ok, all = apply(plans, sws), true
    for i, r in ipairs(touched) do
        if ok[i] then
            redo[r] = nil
            for _, t in ipairs(grown[r]) do
                local k = key(t[1], t[2])
                r.tiles[k], bof[k] = t, r
            end
        else
            all = false
        end
    end
    return all
end

-- 集合裡還沒登錄的格子與要重建的棟全部登錄（伺服器與單機開服載入帳本當下；客戶端用 registerNear），一次
-- applyChanges。沒有要登錄的就不叫引擎。回成不成功
function Basement.registerAll()
    local list = {}
    for k, id in pairs(cells) do
        if not bof[k] then list[#list + 1] = blocks[id].tiles[k] end
    end
    return register(list)
end

-- 新增的格子（Basement.add 回的）當下登錄進引擎；挖掘中的新格子走 growLater，它到時候也是呼叫這裡。選用的第二個參數同
-- register 的 only（只登錄這幾塊，別的塊排著的重建照舊等）
function Basement.grow(tiles, ...)
    return register(tiles, ...)
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

-- 換掉塊 id 的房號。回分法有沒有變。客戶端與單機分法變了，這一塊裡登錄過的每一棟下一次登錄照新的分法重建；專用伺服器一棟
-- 一間，不重建（哪一格屬於哪一間只看 Basement.roomOf）
local function renumber(id, room, n)
    local b = blocks[id]
    if samePart(b.room, room, b.tiles) then return false end
    b.room, b.rooms = room, n
    if not isServer() then
        b.todo = true
        for k in pairs(b.tiles) do
            local r = bof[k]
            if r and alive(r) then redo[r] = true end
        end
    end
    return true
end

-- 塊 id 照帳本記的房號分房（Basement.saved）：房號一樣又連在一起的格子算一間，沒記的格子當 0 號（只有一間的塊不記，整塊都是
-- 0 號＝一間）。回 { [鍵]＝房號 }、房間數
local function fromSaved(id)
    local tiles, get = blocks[id].tiles, Basement.saved and Basement.saved.get
    local label, room, n = {}, {}, 0
    for k, t in pairs(tiles) do label[k] = get and get(t[1], t[2]) or 0 end
    for k0, t0 in pairs(tiles) do
        if not room[k0] then
            n = n + 1
            room[k0] = n
            local stack = { t0 }
            while #stack > 0 do
                local t = stack[#stack]
                stack[#stack] = nil
                for _, d in ipairs(DIRS) do
                    local nk = key(t[1] + d[1], t[2] + d[2])
                    if tiles[nk] and not room[nk] and label[nk] == label[k0] then
                        room[nk] = n
                        stack[#stack + 1] = tiles[nk]
                    end
                end
            end
        end
    end
    return room, n
end

-- 塊 id 現在的分房記進帳本（Basement.saved）：和帳本記的是同一種分法就不寫，不同才把號碼不一樣的格子換掉（只有一間的塊
-- 和沒記一樣，不寫）。寫不進去（帳本滿了）只記 log、帳本照舊：下一次開服那幾格照舊的號碼分，巡查照牆分好再推一次
local function save(id)
    local S, b = Basement.saved, blocks[id]
    if not (S and b) then return end
    local old = {}
    for k, t in pairs(b.tiles) do old[k] = S.get(t[1], t[2]) or 0 end
    if samePart(old, b.room, b.tiles) then return end
    local failed = 0
    for k, t in pairs(b.tiles) do
        if old[k] ~= b.room[k] and not S.put(t[1], t[2], b.room[k]) then failed = failed + 1 end
    end
    if failed > 0 then print(LOG .. "rooms not saved for " .. failed .. " tiles") end
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

-- 伺服器與單機：塊 ids（{ [編號]＝true，或已經算好的 { 房號, 房間數 }（Basement.resplit），或 false＝這次試過分不了、
-- 不再算）重算分房，list（新挖的格子）
-- 與要重建的棟一次登錄；專用伺服器上這一批有新格子或分法變了的塊推給附近的玩家（BasementLedger.sendBlock，內容是集合與
-- 分房，登錄失敗也推），分房記進帳本（save）。專用伺服器只隔間、沒挖新格時不叫引擎（一棟一間，renumber 不重建）。選用的
-- 第三個參數 only（flushBlock）：只登錄這幾塊，別的塊排著的重建留給延後批次。回登錄成不成功
local function refresh(ids, list, ...)
    local only = ...
    local push = {}
    for id, v in pairs(ids) do
        local room, n
        if v == true then room, n = Basement.split(id) elseif v then room, n = v[1], v[2] end
        if room and renumber(id, room, n) then push[id] = true end
    end
    for _, t in ipairs(list) do push[cells[key(t[1], t[2])]] = true end
    local done = Basement.grow(list, only)
    for id in pairs(push) do save(id) end
    local L = isServer() and MinidoracatBuilder.BasementLedger
    for id in pairs(L and push or {}) do
        local all = {}
        for _, t in pairs(blocks[id].tiles) do all[#all + 1] = t end
        L.sendBlock(Basement.byRoom(all))
    end
    return done
end

-- 開服載入帳本當下（BasementLedger.start，登錄之前）：每塊試一次分房。沒載入的塊（專用伺服器這時沒有 chunk）照帳本記的房號
-- 分（fromSaved）：快照一開始就是上一次照牆分的那樣，巡查載入後算出同一種分法就不推 block，客戶端不會整棟再登錄一次
function Basement.splitAll()
    for id in pairs(blocks) do
        local room, n = Basement.split(id)
        if not room then room, n = fromSaved(id) end
        renumber(id, room, n)
        save(id)
    end
end

-- 伺服器與單機（BasementLedger.commit）挖好的新格子延後一起登錄：每次登錄整塊重建一次房間，一次拖曳每挖好一格
-- 就登錄一次會越挖越慢（實機拖 32 格每次最多 177 ms）。集合、帳本、土牆照舊當下就做（呼叫端），這裡只排登錄：最後一批
-- 加進來之後 GROW_QUIET 毫秒內沒有新的（挖一格 5 秒，Entry.duration），或第一批已經排了 GROW_MAX 毫秒（長的拖曳中途也
-- 登錄），才把排著、還在集合裡又還沒登錄的格子一次登錄，同一批也重算新格與 Basement.dirty 標過的塊的分房
-- （牆蓋到一半還沒圍起來時分法沒變，不重登錄）；按那一塊裡的開關或燈時那一塊先登錄（Basement.growNow）。出錯只記 log，
-- 沒登錄的格子下一次開服補上。客戶端不排：等伺服器那一批的 block（Basement.await、Basement.registerNear）
Basement.GROW_QUIET, Basement.GROW_MAX = 10000, 60000
local due, stale, dueFirst, dueLast, dueHooked = {}, {}, 0, 0, false
local function flushGrow()
    local t = getTimestampMs()
    if t - dueLast < Basement.GROW_QUIET and t - dueFirst < Basement.GROW_MAX then return end
    Events.OnTick.Remove(flushGrow)
    dueHooked = false
    local list, ids = {}, {}
    for k, v in pairs(due) do
        if cells[k] and not bof[k] then list[#list + 1] = v end
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
    for _, t in ipairs(tiles) do
        local k = key(t[1], t[2])
        due[k], stale[k] = t, true
    end
    later()
end

-- 客戶端收到 dug：新格子（Basement.add 回的）記成等 block（伺服器延後批次登錄完推來）；塊開始等的時間已經有就不動
function Basement.await(tiles)
    local now = getTimestampMs()
    for _, t in ipairs(tiles) do
        local k = key(t[1], t[2])
        local b = blocks[cells[k]]
        b.fresh = b.fresh or {}
        b.fresh[k], b.wait = true, b.wait or now
    end
end

-- 客戶端：身邊（NEAR 格內）有還沒登錄的格子或要重建的棟（todo）、而且沒在等 block 或等超過 WAIT_MS（伺服器一批最晚
-- GROW_MAX 毫秒，再留 30 秒）的塊，加上 ids（{ [編號]＝true }，不管等不等；可以是 nil）時，連同遠處同樣合格的塊一次
-- 登錄（同一次 applyChanges；玩家常在別處叫出新的一棟，順手把遠的也登錄，走回去時不必再叫一次引擎）。只走塊、不走格子；
-- 沒有身邊要登錄的塊不叫引擎。等超過的塊登錄後不再等（之後的 dug 從頭等）。在最近一份快照範圍外的塊（stale）不登錄：
-- 玩家走回去時每分鐘的檢查會先要那一區的快照，先登錄手上舊的、快照帶來離開期間的變動再登錄一次，同一刻就叫兩次引擎；
-- 快照到了它就在範圍內，連同變動一次登錄。遠處的塊另外要包圍盒經過的地圖格都有 metaCell（metaReady），搭便車登錄失敗過
-- 的塊（hitch＝false）之後只在身邊時登錄。回成不成功
Basement.WAIT_MS = Basement.GROW_MAX + 30000
-- 包圍盒經過的地圖格都有 metaCell：地圖沒有資料的荒野格要等那一格有 chunk 載入過才建（IsoMetaGrid.getCellData 回 null），
-- 在那之前登錄的棟引擎收不下
local function metaReady(grid, box)
    for lx = lotOf(box[1]), lotOf(box[3]) do
        for ly = lotOf(box[2]), lotOf(box[4]) do
            if grid:getCellData(lx, ly) == nil then return false end
        end
    end
    return true
end
function Basement.registerNear(ids)
    local now, pick, far, hitch, list, near, any = getTimestampMs(), {}, {}, {}, {}, nil, false
    for id, b in pairs(blocks) do
        if b.todo and not b.stale and ((ids and ids[id]) or not b.wait or now - b.wait > Basement.WAIT_MS) then
            near = near or nearIds(players(), Basement.NEAR)
            if near[id] then
                pick[id], any = true, true
            elseif b.hitch ~= false then
                far[#far + 1] = id
            end
        end
    end
    if not any then return true end
    -- shortcut: 搭便車的塊數沒有上限，一份快照超過約 50 座或量到單次超過 250 ms 時加上限
    local grid = #far > 0 and getWorld():getMetaGrid()
    for _, id in ipairs(far) do
        if metaReady(grid, blocks[id].box) then pick[id], hitch[id] = true, true end
    end
    for id in pairs(pick) do
        for k, t in pairs(blocks[id].tiles) do
            if not bof[k] then list[#list + 1] = t end
        end
    end
    local ok = register(list, pick)
    for id in pairs(pick) do
        local b = blocks[id]
        if ok then
            b.todo = nil
        elseif hitch[id] then
            b.hitch = false
        end
        if b.wait and now - b.wait > Basement.WAIT_MS then b.wait = nil end
    end
    return ok
end

-- 專用伺服器：(x, y) 裝上（on）或拆掉了牆上開關。裝上：記成開關格，格子掛著房間就當下摘掉（setRoomID(-1)，開關建構子才不會
-- 把它收進房間，IsoLightSwitch.java:90-99；切換時不送房間燈，:519-535）。有增減時登錄過的那一棟排進延後批次重登錄（拆掉的
-- 那格回到房間）；拆掉時還沒登錄的那格照新格子排。客戶端與單機不做事
function Basement.setSwitchTile(x, y, on)
    if not isServer() then return end
    local k = key(x, y)
    if not cells[k] then return end
    if on then
        local cell = getCell()
        local sq = cell and cell:getGridSquare(x, y, Z)
        if sq and sq:getRoom() then sq:setRoomID(-1) end
    end
    if (swTiles[k] == true) == (on == true) then return end
    swTiles[k] = on and true or nil
    local r = bof[k]
    if r then
        redo[r] = true
    elseif on then
        return
    else
        due[k] = blocks[cells[k]].tiles[k]
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

-- 塊 id 在延後批次裡排著的新格子與要重算分房的格子當下做（同一個呼叫裡），只登錄這一塊（別的塊排著的照舊等）。
-- part＝Basement.resplit 算好的 { 房號, 房間數 }，或 false＝它試過分不了（兩種都不再算一次；nil＝要算）；force＝沒有
-- 排著的也做（分法變了）。回 nil＝沒有要做的，否則回登錄成不成功
local function flushBlock(id, part, force)
    local list, dk, sk = {}, {}, {}
    for k, v in pairs(due) do
        if cells[k] == id then
            dk[#dk + 1] = k
            if not bof[k] then list[#list + 1] = v end
        end
    end
    for k in pairs(stale) do
        if cells[k] == id then sk[#sk + 1] = k end
    end
    if #dk + #sk == 0 and not force then return nil end
    for _, k in ipairs(dk) do due[k] = nil end
    for _, k in ipairs(sk) do stale[k] = nil end
    local ok, done = pcall(refresh, { [id] = part == nil or part }, list, { [id] = true })
    if not (ok and done) then print(LOG .. "grow failed: " .. tostring(done)) end
    return ok and done == true
end

-- 伺服器與單機：(x, y, z) 所在那一塊排著的當下做（flushBlock）。按地下室裡的開關或燈時用（Circuits.press）：有市電時開關要
-- 自己或四周 3×3 有一格在房間裡才算有電（IsoLightSwitch.java:415-466 canSwitchLight、isBuildingSquare），還沒登錄的那一塊
-- 沒有房間，按了不會動。這一塊沒有排著的不做事、回 false
function Basement.growNow(x, y, z)
    if isClient() or z ~= Z then return false end
    local id = cells[key(x, y)]
    return id ~= nil and flushBlock(id, nil, false) == true
end

-- 伺服器與單機：自動接線、按沒接燈的牆上開關前（Circuits.autoWire、lampPlaced、press）照現在的牆確認 (x, y, z) 所在那一塊的
-- 分房。原版與別的 MOD 蓋的牆沒有事件、本工具蓋的牆要停手 GROW_QUIET 才分、巡查每 10 遊戲分鐘一次：照舊的分法接線會接到
-- 牆另一邊、寫進線路帳本，之後分好了也不會拔。分法變了當下換（那一塊排著的一起做）；沒變不做事，排著的照舊等延後批次
-- （每裝一個牆上開關就提前登錄的話，專用伺服器每裝一個就重登錄那一棟一次，實機 56–73 ms）。花一次 split。
-- 選用的第四個參數 flush＝true（Circuits.press）：分法沒變、分不了時也把那一塊排著的當下做（同 growNow，不另外再算一次）。
-- 回 false＝那一塊有格子沒載入、分不了，呼叫端不照舊的分法接線；不是本 MOD 地下室的格子回 true
function Basement.resplit(x, y, z, ...)
    local flush = ...
    if isClient() or z ~= Z then return true end
    local id = cells[key(x, y)]
    if not id then return true end
    local room, n = Basement.split(id)
    local changed = room ~= nil and not samePart(blocks[id].room, room, blocks[id].tiles)
    if changed or flush then flushBlock(id, room and { room, n } or false, changed) end
    return room ~= nil
end

-- 伺服器與單機，每 10 遊戲分鐘（BasementLedger 掛 EveryTenMinutes，GameTime.java:617-631；一天 90 分鐘的預設下每 37.5 秒）：
-- 每位玩家 PATROL 格內的塊重算分房。原版木工、別的 MOD 蓋牆在伺服器沒有事件（OnObjectAdded 只在
-- AddItemToMapPacket.processClient 觸發，AddItemToMapPacket.java:59,94），要等到下一次巡查才分。沒有地下室時不做事
Basement.PATROL = 16
function Basement.patrol()
    if isClient() then return end
    local any = false
    for _ in pairs(blocks) do any = true break end
    if not any then return end
    local ok, done = pcall(refresh, nearIds(players(), Basement.PATROL), {})
    if not (ok and done) then print(LOG .. "patrol failed: " .. tostring(done)) end
end

-- 客戶端：伺服器分好的一塊房間（{ { { x, y }, ... }, ... }，每間一組格子；不在集合裡的格子不收）與修訂號 v。格子照本機的塊
-- 分開套用（同步範圍會把一塊裁成幾個本機塊）：本機塊沒記過修訂號、或 v 比它記的大，才換房號、記下 v（較舊與重複的略過）。
-- 分法有變時那一塊登錄過的每一棟標成要重建。訊息裡的格子不再等 block：那一塊等的格子都到了就不再等，還有沒到的從現在起
-- 再等。回換過房號的本機塊 { [編號]＝true }（呼叫端交給 registerNear）
function Basement.setRooms(rooms, v)
    local at, out, now = {}, {}, getTimestampMs()
    for i, list in ipairs(rooms) do
        for _, t in ipairs(list) do
            local k = key(t[1], t[2])
            local id = cells[k]
            if id then
                at[id] = at[id] or {}
                at[id][k] = i
            end
        end
    end
    for id, got in pairs(at) do
        local b = blocks[id]
        if not (b.v and b.v >= v) then
            local room = {}
            for k, r in pairs(b.room) do room[k] = r end
            for k, i in pairs(got) do room[k] = b.rooms + i end
            renumber(id, room, b.rooms + #rooms)
            b.v, out[id] = v, true
        end
        if b.fresh then
            for k in pairs(got) do b.fresh[k] = nil end
            local left = false
            for _ in pairs(b.fresh) do left = true break end
            if left then b.wait = now else b.fresh, b.wait = nil, nil end
        end
    end
    return out
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

-- (x, y) 那一座（已挖的塊或 planned 裡排在前面的格子連成的）有幾格；都不是回 nil。游標標籤寫挖完後的格數
function Basement.sizeAt(planned, x, y)
    local _, n = group(planned and planned.dig, x, y)
    return n
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

-- 「挖這一格」c 挖下去之後那一塊有幾格：c 加上四鄰各群（已挖的塊、預覽時排在前面連得上的格子）不重複的格數。
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
-- 同一套；also＝這一批已經算挖開、還沒進集合的格鍵（Place.key）。選用的第五個參數 checked＝true：外來房間呼叫端查過了
-- （Basement.pre），不再查
function Basement.opens(player, c, preview, also, ...)
    local checked = ...
    if not checked and foreignRoomNear(getWorld():getMetaGrid(), c.x, c.y) then return "DIG_ROOM", at(c) end
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
    -- 挖開 c 會拆掉東南那格的牆角柱（c 是那個外凸轉角缺的那格）：柱上的疊圖同樣會跟著消失
    local psq = Basement.isCorner(c.x + 1, c.y + 1) and cell:getGridSquare(c.x + 1, c.y + 1, c.z)
    local objects = psq and psq:getObjects()
    for i = 0, (objects and objects:size() or 0) - 1 do
        local o = objects:get(i)
        local list = Basement.isPost(o) and o:getAttachedAnimSprite()
        if list and list:size() > 0 then return "DIG_HUNG", pos(psq) end
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
    -- entry：放的是入口（不是挖一格），拒絕訊息照它說該放哪一層
    if anchor[3] ~= (entrance and 0 or Z) then
        return "DIG_LEVEL", { x = anchor[1], y = anchor[2], z = anchor[3], entry = entrance }
    end
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
    -- 加開入口：樓梯底端前面那格也要已經挖開（同一塊），不然下了樓梯面對土牆
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
        local code, extra = Basement.opens(player, c, preview, nil, true) -- 外來房間上面查過了
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
-- 掛著本工具地面覆蓋的地板（拆了覆蓋和它的退料跟著不見，同水面 waterOk）；地毯是能搬的家具，也不收
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
