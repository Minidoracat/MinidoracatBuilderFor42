-- 地下室（本 MOD 挖的，z 固定 -1；設計：temp/feedback-1124/basement/plan.md §1.2、§2.1）：格子集合與連通塊、外邊土牆、
-- 向引擎登錄房間、挖掘的判斷。兩端共用：伺服器（單機在本機）從帳本（server/MinidoracatBuilder/BasementLedger.lua）載入，
-- 客戶端從同步來的範圍建。一塊連通的地下＝一棟建物、一個房間。
-- 外邊土牆那 6 支和 Basement Building（Workshop 3806513504）的 aparosa_BD_DirtLayer 同名、同語意，Place 的 dirtLayer 照
-- 位置選用哪一層（Basement.near 的格邊歸本 MOD）。差別：外邊只看集合（一格在、一格不在），不看另一格有沒有房間；外來房間
-- 由 Basement.pre 的 DIG_ROOM 擋在 1 格外。
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
-- 外邊土牆的圖：判斷「是不是土牆」一律查這張表（使用者可能換成 underground_01_8／9／10，只改這裡）
Basement.DIRT = { W = "walls_exterior_house_02_96", N = "walls_exterior_house_02_97", NW = "walls_exterior_house_02_98" }
Basement.AREA = 256                  -- 同步用的大區邊長
local Z = -1
local BIG = 1e15
local DIRS = { { 0, -1 }, { -1, 0 }, { 1, 0 }, { 0, 1 } }
local EDGE = { N = { 0, -1 }, W = { -1, 0 } }
local OTHER = { N = "W", W = "N" }

-- cells[鍵]＝連通塊編號；blocks[編號]＝{ n＝格數, tiles＝{ [鍵]＝{ x, y } } }
-- main[編號]＝這一場登錄過的主建物 { cx, cy＝metaID 的角, tiles＝{ [鍵]＝{ x, y } } }；regd[鍵]＝這一格已登錄進某一棟
local cells, blocks, main, regd, lastId = {}, {}, {}, {}, 0

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
        A.tiles[k], cells[k] = t, a
    end
    A.n = A.n + B.n
    main[a] = main[a] or main[b]
    blocks[b], main[b] = nil, nil
    return a
end

-- tiles＝{ { x, y }, ... }（z 固定 -1）：加進集合、併連通塊；回真的新增的那幾格
function Basement.add(tiles)
    local added = {}
    for _, t in ipairs(tiles) do
        local x, y = t[1], t[2]
        local k = key(x, y)
        if not cells[k] then
            local id
            for _, d in ipairs(DIRS) do
                local o = cells[key(x + d[1], y + d[2])]
                if o and o ~= id then id = id and merge(id, o) or o end
            end
            if not id then
                lastId = lastId + 1
                id = lastId
                blocks[id] = { n = 0, tiles = {} }
            end
            local b, xy = blocks[id], { x, y }
            cells[k], b.n, b.tiles[k] = id, b.n + 1, xy
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
-- 有格子被拿掉時連通塊整份重算（主建物照它的角那一格接回去；拿掉的格子在引擎裡的建物留到下一次進場）。回真的新增的那幾格
function Basement.reset(tiles, ax, ay)
    local x0, y0, x1, y1 = range(ax, ay)
    local keep, inside = {}, {}
    for _, t in ipairs(tiles) do
        if t[1] >= x0 and t[1] < x1 and t[2] >= y0 and t[2] < y1 then
            keep[key(t[1], t[2])] = true
            inside[#inside + 1] = t
        end
    end
    local rest, gone = {}, false
    for k, id in pairs(cells) do
        local t = blocks[id].tiles[k]
        if keep[k] or t[1] < x0 or t[1] >= x1 or t[2] < y0 or t[2] >= y1 then
            rest[#rest + 1] = t
        else
            gone = true
        end
    end
    if gone then
        local old = main
        cells, blocks, main = {}, {}, {}
        Basement.add(rest)
        for _, m in pairs(old) do
            local id = cells[key(m.cx, m.cy)]
            if id and not main[id] then main[id] = m end
        end
    end
    return Basement.add(inside)
end

-- 大區 (ax, ay) 周圍 3×3 範圍內的格子，照連通塊分：{ { { x, y }, ... }, ... }。
-- shortcut: 每次走過整個集合（帳本 5 秒限一次、伺服器上幾萬格以內），慢了再照大區建索引
function Basement.area(ax, ay)
    local x0, y0, x1, y1 = range(ax, ay)
    local by, out = {}, {}
    for k, id in pairs(cells) do
        local t = blocks[id].tiles[k]
        if t[1] >= x0 and t[1] < x1 and t[2] >= y0 and t[2] < y1 then
            local list = by[id]
            if not list then
                list = {}
                by[id], out[#out + 1] = list, list
            end
            list[#list + 1] = t
        end
    end
    return out
end

-- 啟用的 MOD 清單裡有 Basement Building（同 Rules.unlistModSprites 的讀法）
function Basement.bd()
    local mods = getActivatedMods()
    for i = 0, mods:size() - 1 do
        if mods:get(i) == "aparosa_BasementDig" then return true end
    end
    return false
end

-- 格子 → 不重疊的矩形 { { x, y, w, h }, ... }，照 BD aparosa_BD_Rooms.mergeTiles：由北往南、由西往東，先往東延伸、
-- 再整條往南延伸。第一個矩形是最北那一列最西的格子＝calculateMetaID 取的角（BuildingDef.java:319-348）。
-- 不排序（Kahlua 的 table.sort 會溢位）：照列走 y 的範圍。shortcut: 走 y 與每列 x 的整個範圍，格子散得很開時多走空格，
-- 一塊最多 Basement.MAX 格、跨度也在幾百格內
function Basement.rects(tiles)
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
    local used, out = {}, {}
    local function free(x, y)
        local k = key(x, y)
        return set[k] and not used[k]
    end
    for y = y0, y1 do
        local r = rows[y]
        for x = r and r[1] or 1, r and r[2] or 0 do
            if free(x, y) then
                local w, h = 1, 1
                while free(x + w, y) do w = w + 1 end
                local grow = true
                while grow do
                    for dx = 0, w - 1 do
                        if not free(x + dx, y + h) then grow = false break end
                    end
                    if grow then h = h + 1 end
                end
                for dx = 0, w - 1 do
                    for dy = 0, h - 1 do used[key(x + dx, y + dy)] = true end
                end
                out[#out + 1] = { x, y, w, h }
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------- 外邊土牆層（aparosa_BD_DirtLayer 同名的 6 支）
local function dirtKind(name)
    for k, v in pairs(Basement.DIRT) do
        if v == name then return k end
    end
    return nil
end

local function propsOf(name)
    local named = IsoSpriteManager.instance:getNamedMap()
    local spr = name and named:containsKey(name) and named:get(name)
    return spr and spr:getProperties() or nil
end

-- 本 MOD 放的土牆：圖在 Basement.DIRT、不是 IsoThumpable（同一張圖的 IsoThumpable 是玩家蓋的牆）。回 "N"／"W"／"NW" 或 nil
local function dirtOf(o)
    local spr = o:getSprite()
    local k = spr and dirtKind(spr:getName())
    if k and not instanceof(o, "IsoThumpable") then return k end
    return nil
end

local function covers(kind, k) return kind == k or kind == "NW" end

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

-- 外邊不准蓋的開口（BD OPENING_FLAGS：窗、門框、柵欄、透明牆、門）
local OPEN = { N = { F.WindowN, F.DoorWallN, F.HoppableN, F.TallHoppableN, F.WallNTrans, F.doorN },
    W = { F.WindowW, F.DoorWallW, F.HoppableW, F.TallHoppableW, F.WallWTrans, F.doorW } }
function Basement.isOpeningOnOuterEdge(sq, name)
    local p = propsOf(name)
    if not p then return false end
    for k, list in pairs(OPEN) do
        for _, f in ipairs(list) do
            if p:has(f) and sqOuter(sq, k) then return true end
        end
    end
    return false
end

local function dirtOn(sq, k)
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local kind = dirtOf(objects:get(i))
        if kind and covers(kind, k) then return true end
    end
    return false
end

-- 牆框（只有透明牆、沒有實牆）蓋在外邊的土牆上
function Basement.isFrameOnDirt(sq, name)
    local p = propsOf(name)
    if not p or p:has(F.WallNW) then return false end
    for _, k in ipairs({ "N", "W" }) do
        local trans, solid = k == "N" and F.WallNTrans or F.WallWTrans, k == "N" and F.WallN or F.WallW
        if p:has(trans) and not p:has(solid) and sqOuter(sq, k) and dirtOn(sq, k) then return true end
    end
    return false
end

-- 要蓋的圖和土牆同一張，而且它佔的邊有一條是外邊
function Basement.isDirtLookOnOuterEdge(sq, name)
    local kind = dirtKind(name)
    return kind ~= nil and ((covers(kind, "N") and sqOuter(sq, "N")) or (covers(kind, "W") and sqOuter(sq, "W")))
end

local function putDirt(sq, kind)
    local obj = IsoObject.new(getCell(), sq, Basement.DIRT[kind])
    sq:AddTileObject(obj)
    obj:transmitCompleteItemToClients()
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
    local kept, changed = false, false
    for _, d in ipairs(dirt) do
        if d[2] == want and not kept then
            kept = true
        else
            sq:transmitRemoveItemFromSquare(d[1])
            changed = true
        end
    end
    if want and not kept then
        putDirt(sq, want)
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
-- 一批建物一次 applyChanges。plans＝{ rects, ... }，每棟一組矩形（rects[1] 是 metaID 的角）。步驟與順序照 BD
-- aparosa_BD_Rooms.lua 的 registerRecordsBatch、applyEditor、noRefill、refreshServerSquares（各步原因見它的註解）。
-- 回這次登錄了幾棟
local function apply(plans)
    if not (BuildingRoomsEditor and BuildingRoomsEditor.getInstance) then
        print(LOG .. "BuildingRoomsEditor is missing; the game update may have changed it")
        return 0
    end
    BuildingRoomsEditor.Reset()
    local editor = BuildingRoomsEditor.getInstance()
    editor:setCurrentBuilding(nil)
    -- 不呼叫 canAddRoomRectangle：它對相鄰的別棟回 false（BuildingRoomsEditor.java:107-161），annex 一定貼著主建物
    local done = {}
    for _, rects in ipairs(plans) do
        local building = editor:createBuilding()
        local room = building:createRoom(Z)
        room:setName(Basement.ROOM)
        for _, r in ipairs(rects) do room:addRectangle(r[1], r[2], r[3], r[4]) end
        if building:isValid() then
            done[#done + 1] = rects
        else
            editor:removeBuilding(building)
            print(LOG .. "invalid building skipped at " .. tostring(rects[1] and rects[1][1]) .. ","
                .. tostring(rects[1] and rects[1][2]))
        end
    end
    if #done == 0 then return 0 end
    -- 先清掉見到的房間的待辦：applyChanges 拆舊建物後它會在引擎裡 NPE（BD applyEditor 的註解）
    local cell = getCell()
    pcall(function() cell:ProcessSpottedRooms() end)
    editor:applyChanges(false)
    local grid, server = getWorld():getMetaGrid(), isServer()
    local vzm = not isClient() and VirtualZombieManager and VirtualZombieManager.instance or nil
    for _, rects in ipairs(done) do
        local def = grid:getRoomAt(rects[1][1], rects[1][2], Z)
        local b = def and def:getBuilding()
        if b then
            b:setUserDefined(false) -- 漏了客戶端會退回主選單（bdprobe-1124a）
            b:setAllExplored(true)
            if vzm then
                -- 這間的殭屍數定成 0：chunk 載入時不再補室內殭屍（BRERoom 把 doneSpawn 設 true，VirtualZombieManager.java:666-674,765-772）
                def:setName("emptyoutside")
                local ok = pcall(function() vzm:addIndoorZombiesToChunk(nil, def:getIsoRoom()) end)
                def:setName(Basement.ROOM)
                if not ok then print(LOG .. "noRefill failed at " .. rects[1][1] .. "," .. rects[1][2]) end
            end
            if server then
                -- 專用伺服器：applyChanges 只補本機玩家 chunkMap 的格子（BuildingRoomsEditor.java:413-436），已載入的自己掛。
                -- setRoomID 的 long 從 Lua 進去會失準，後面一定接 setRoom
                local room, id = def:getIsoRoom(), def:getID()
                for _, r in ipairs(rects) do
                    for x = r[1], r[1] + r[3] - 1 do
                        for y = r[2], r[2] + r[4] - 1 do
                            local sq = room and cell:getGridSquare(x, y, Z)
                            if sq then
                                sq:setRoomID(id)
                                sq:setRoom(room)
                                local switches, objects = room:getLightSwitches(), sq:getObjects()
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
        else
            print(LOG .. "no RoomDef after register at " .. rects[1][1] .. "," .. rects[1][2])
        end
    end
    return #done
end

-- 主建物的矩形：角那一格單獨放第一個，metaID 不變（BD liveRects）
local function mainRects(m)
    local rest = {}
    for _, t in pairs(m.tiles) do
        if not (t[1] == m.cx and t[2] == m.cy) then rest[#rest + 1] = t end
    end
    local out = { { m.cx, m.cy, 1, 1 } }
    for _, r in ipairs(Basement.rects(rest)) do out[#out + 1] = r end
    return out
end

-- 集合裡還沒登錄的格子 list 照塊登錄：塊還沒有主建物 → 這些格子登錄成主建物；有 → 角的西北方（x ≤ cx 而且 y < cy，
-- calculateMetaID 會換角）的登錄成 1 格的 annex，其他併進主建物重登錄（同 metaID，引擎換掉舊的）。成功才記下
local function register(list)
    local by, order, seen = {}, {}, {}
    for _, t in ipairs(list) do
        local k = key(t[1], t[2])
        local id = cells[k]
        if id and not regd[k] and not seen[k] then
            seen[k] = true
            if not by[id] then
                by[id] = {}
                order[#order + 1] = id
            end
            local ts = by[id]
            ts[#ts + 1] = t
        end
    end
    local plans, after = {}, {}
    for _, id in ipairs(order) do
        local ts, m = by[id], main[id]
        if not m then
            local rects = Basement.rects(ts)
            local tiles = {}
            for _, t in ipairs(ts) do tiles[key(t[1], t[2])] = t end
            plans[#plans + 1] = rects
            after[#after + 1] = { id, { cx = rects[1][1], cy = rects[1][2], tiles = tiles } }
        else
            local tiles
            for _, t in ipairs(ts) do
                if t[1] <= m.cx and t[2] < m.cy then
                    print(LOG .. "annex building at " .. t[1] .. "," .. t[2])
                    plans[#plans + 1] = { { t[1], t[2], 1, 1 } }
                else
                    if not tiles then
                        tiles = {}
                        for k, v in pairs(m.tiles) do tiles[k] = v end
                    end
                    tiles[key(t[1], t[2])] = t
                end
            end
            if tiles then
                local m2 = { cx = m.cx, cy = m.cy, tiles = tiles }
                plans[#plans + 1] = mainRects(m2)
                after[#after + 1] = { id, m2 }
            end
        end
    end
    if #plans == 0 then return true end
    if apply(plans) < #plans then return false end
    for _, a in ipairs(after) do main[a[1]] = a[2] end
    for k in pairs(seen) do regd[k] = true end
    return true
end

-- 集合裡還沒登錄的格子全部登錄（開服 60 tick 後、客戶端收到 basements 後），一次 applyChanges。回成不成功
function Basement.registerAll()
    local list = {}
    for k, id in pairs(cells) do
        if not regd[k] then list[#list + 1] = blocks[id].tiles[k] end
    end
    return register(list)
end

-- 新增的格子（Basement.add 回的）登錄進引擎
function Basement.grow(tiles)
    return register(tiles)
end

-- 本機每位玩家的畫面高度範圍重算：遊戲中途多出地下一層時引擎不重算，樓梯與開關畫不出來（BD aparosa_BD_ZExtent.lua）
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

-- 外來房間（地圖的地下室、BD 的、別的 MOD 的）在 (x, y) 周圍 3×3 內。getRoomAt 在 chunk 沒載入時也查得到（Basements.java:103-128）
local function foreignRoomNear(grid, x, y)
    for dx = -1, 1 do
        for dy = -1, 1 do
            local def = grid:getRoomAt(x + dx, y + dy, Z)
            if def and not has(x + dx, y + dy, Z) and def:getName() ~= Basement.ROOM then return true end
        end
    end
    return false
end

-- Check.item 補格子之前跑（只讀座標與已經存在的格子）：回 code, extra, skip（skip＝加開入口，Check.item 把角色 dig 的
-- 6 格拿掉）。順序就是回報的優先序（plan.md §2.1）
function Basement.pre(player, entry, cells, anchor, planned, preview)
    if Basement.bd() then return "DIG_BD" end
    local entrance = false
    for _, c in ipairs(cells) do
        if STAIR[c.role] then entrance = true end
    end
    if anchor[3] ~= (entrance and 0 or Z) then return "DIG_LEVEL", { x = anchor[1], y = anchor[2], z = anchor[3] } end
    -- 入口：樓梯三格已經在集合裡幾格（3 而且同一塊＝加開）
    local stairs, inSet, blk, same = 0, 0, nil, true
    for _, c in ipairs(cells) do
        if STAIR[c.role] then
            stairs = stairs + 1
            local id = Basement.blockOf(c.x, c.y, c.z)
            if id then
                inSet = inSet + 1
                if blk and blk ~= id then same = false end
                blk = blk or id
            end
        end
    end
    local skip = entrance and inSet == stairs and same
    local grid = getWorld():getMetaGrid()
    for _, c in ipairs(cells) do
        if UNDER[c.role] and not (skip and c.role == "dig") and foreignRoomNear(grid, c.x, c.y) then
            return "DIG_ROOM", at(c)
        end
    end
    local dig = {} -- 這次要挖的格子
    if not entrance then
        local c = cells[1]
        if has(c.x, c.y, c.z) then return "BLOCKED", at(c) end
        local near, size, counted = false, 1, {}
        for _, d in ipairs(DIRS) do
            local nx, ny = c.x + d[1], c.y + d[2]
            local id, n = Basement.blockOf(nx, ny, c.z)
            if id or (planned and planned[Place.key(nx, ny, c.z)]) then near = true end
            if id and not counted[id] then
                counted[id] = true
                size = size + n
            end
        end
        if not near then return "DIG_EDGE", at(c) end
        if size > Basement.MAX then return "DIG_FULL", { max = Basement.MAX, x = c.x, y = c.y, z = c.z } end
        dig[1] = c
    elseif not skip then
        if inSet > 0 then return "BLOCKED", { x = anchor[1], y = anchor[2], z = anchor[3] } end
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
    -- 要挖的格子旁邊已挖的格子也要有權限：不然在安全屋外緊貼邊界挖一格，兩格之間的土牆消失就打通進去了
    local Check, cell = MinidoracatBuilder.Check, getCell()
    for _, c in ipairs(dig) do
        for _, d in ipairs(DIRS) do
            local nx, ny = c.x + d[1], c.y + d[2]
            if has(nx, ny, c.z) then
                local code = Check.safehouse(player, { x = nx, y = ny, z = c.z, sq = cell:getGridSquare(nx, ny, c.z) },
                    preview, "dismantle")
                if code then return code, { x = nx, y = ny, z = c.z } end
            end
        end
    end
    for _, c in ipairs(cells) do
        if c.role == "platform" or c.role == "hole" then
            local sq = cell:getGridSquare(c.x, c.y, c.z)
            if sq then
                local ok, code = Basement.checkCell(sq, c.role, c.spr)
                if not ok then return code, at(c), skip end
            end
        end
    end
    return nil, nil, skip
end

-- 洞那格上可以跟著拆或留著的：地板（不是水面）、草與可移除的植物、格邊的牆與牆上的掛件
local function holeOk(o)
    local p = o:getProperties()
    if not p then return false end
    if p:has(F.solidfloor) then return not (p:has(F.water) or p:has(F.taintedWater)) end
    if p:has(F.canBeRemoved) or (p:has(F.vegitation) and o:getType() ~= T.tree) then return true end
    local tex = o:getTextureName()
    if tex and tex:find("blends_grassoverlays", 1, true) then return true end
    return p:has(F.WallN) or p:has(F.WallW) or p:has(F.WallNW) or p:has(F.WallSE) or p:has(F.attachedN)
        or p:has(F.attachedW)
end

-- Place.check 的 dig 分支：回 true，或 false 與原因碼
function Basement.checkCell(sq, role, spr)
    if role == "dig" then return true end -- 已經有地板也過（帳本缺的格子挖了就重新記，plan.md §1.2）
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
