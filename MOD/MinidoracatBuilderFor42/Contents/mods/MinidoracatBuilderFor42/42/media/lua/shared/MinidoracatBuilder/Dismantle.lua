-- 拆除（第五階段，設計稿「拆」）：本 MOD 蓋的、Cost.refund 是 "builder" 的東西（不能搬、原版不照材質拆的 IsoThumpable、
-- 燈、家電、掛上去的地面覆蓋與牆面疊圖）用本工具拆，每項退 1..v（v＝伺服器寫的退料表：照 Place.refundOf，燈與家電記在
-- 伺服器帳本 Ledger；掛上去的圖記在覆蓋帳本 Overlays）。
-- 兩端共用、只讀世界：客戶端右鍵選單用 preview 判斷，伺服器 Server.dismantle 照同一份重查後才拆。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Cost"
require "MinidoracatBuilder/Materials"
require "MinidoracatBuilder/Check"
require "MinidoracatBuilder/Place"

MinidoracatBuilder = MinidoracatBuilder or {}
local Dismantle = MinidoracatBuilder.Dismantle or {}
MinidoracatBuilder.Dismantle = Dismantle
local Rules, Entry, Cost = MinidoracatBuilder.Rules, MinidoracatBuilder.Entry, MinidoracatBuilder.Cost
local Materials, Check, Place = MinidoracatBuilder.Materials, MinidoracatBuilder.Check, MinidoracatBuilder.Place
local NS, EW = GridSquareEdgeFacingDirection.NORTH_SOUTH, GridSquareEdgeFacingDirection.EAST_WEST

-- 本 MOD 蓋的片：Place 建的 IsoThumpable，或沒有 buildMaterials 的燈、家電（Place.keyed）、本工具挖的水面（Place.dug：一般
-- IsoObject 的地板，圖還是挖的那張）、坡道片（Place.ramp：一般 IsoObject，記號是頭片名），modData 的 builderEntry 有值；
-- 車庫門、雙開門（IsoDoor）看整組第一片的記號（Place.ourDoor）。
-- 退多少不看這個記號，只看伺服器寫的退料表（Place.refundOf、帳本）。地板另外要圖和蓋的時候一樣（Place.onAboutToBeRemoved
-- 清退料表時不比圖）。第二個回傳值：是不是蓋成地板的（isFloor 只有地板設，
-- Place.thumpable）。先看 modData：地圖物件多半沒有，一區拆除整區掃時省掉類別判斷
local function mine(o)
    if instanceof(o, "IsoDoor") then return Place.ourDoor(o) end
    if not o:hasModData() then return false end
    local e = o:getModData().builderEntry
    if not e then return false end
    local thump = instanceof(o, "IsoThumpable")
    if not (thump or Place.keyed(o) or Place.dug(o) or Place.ramp(o)) then return false end
    if thump and o:isFloor() then
        local spr = o:getSprite()
        return spr ~= nil and spr:getName() == e, true
    end
    return true
end
Dismantle.ours = mine

-- 圖的種類與拆除方式（Rules.classify、Cost.refund；種類是 nil 時兩個都 nil）。兩個都只看圖，memo（選填，一次掃描用的空表）
-- 照 sprite 名稱記住，一區拆除的預覽整區幾千件同一張圖只算一次。
function Dismantle.classOf(spr, ...)
    local memo = ...
    local name = memo and spr:getName()
    local m = memo and memo[name]
    if not m then
        local kind = Rules.classify(spr)
        m = { kind or false, kind and Cost.refund(kind, spr) or false }
        if memo then memo[name] = m end
    end
    return m[1] or nil, m[2] or nil
end

-- 本 MOD 蓋的、本工具能拆的物件回種類，否則 nil。只看 modData 與 sprite。本 MOD 蓋的 IsoThumpable 都 isDismantable，
-- 一樓以下的地板例外（Place.groundFloor，不給原版搬動工具拆），所以它們不看這一項；伺服器另外照帳本認（Place.refundOf）。
-- 挖地下室入口的樓梯片照樓梯拆：圖帶 EntityScript，Rules.classify 不列（Entry.digStair）。memo 見 Dismantle.classOf。
function Dismantle.kindOf(obj, ...)
    local memo = ...
    local ours, floor = mine(obj)
    if not ours then return nil end
    if instanceof(obj, "IsoThumpable") and not obj:isDismantable() then
        local sq = obj:getSquare()
        if not (sq and Place.groundFloor(obj, sq)) then return nil end
    end
    local spr = obj:getSprite()
    if not spr then return nil end
    local kind, refund = Dismantle.classOf(spr, memo)
    if not kind and Entry.digStair(spr:getName()) and obj:isStairsObject() then
        kind, refund = "stairs", Cost.refund("stairs", spr)
    end
    -- 蓋成地板的照地板拆：0.5.0 以前帶 solidfloor 的圖塊包地毯被當地板蓋，現在歸家具或地面覆蓋（Rules.kindOf）；
    -- 照現在的種類拆，地面覆蓋那條路找的是地板上掛的圖，地板帳本也退不到
    if floor and kind ~= "floor" then kind, refund = "floor", Cost.refund("floor", spr) end
    if refund ~= "builder" then return nil end
    return kind
end

-- 伺服器拆除用（Server.unbuildOne、Server.dismantleDuration）：格上 sprite 名稱是 name、本工具拆得到的那件與種類（會疊的
-- 箱子能搬，本工具不拆，所以同一張圖只會有一件拆得掉）。坡道片照圖與位置認（Place.rampOrigin），不看記號：記號客戶端
-- 改得到，這組是不是本 MOD 蓋的由伺服器照帳本認（Place.refundOf，查不到回 NOT_OURS）；其他照 Dismantle.kindOf
function Dismantle.find(sq, name)
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        local spr = o:getSprite()
        if spr and spr:getName() == name then
            if Place.rampOrigin(o) then return o, "ramp" end
            local kind = Dismantle.kindOf(o)
            if kind then return o, kind end
        end
    end
    return nil, nil
end

-- 掛上去的地面覆蓋與牆面疊圖（Rules.onFloor、Rules.onWall、Place.attach）：name 是會掛上去的圖、sq 上它該掛的那一件
-- （Place.host）掛著它，回 { sq, host, name, spr, kind, edge }，否則 nil。不看記號：伺服器拆不拆、退多少只看覆蓋帳本
-- （Server.dismantle），沒有那一筆回 NOT_OURS。
function Dismantle.hung(sq, name)
    local spr = Entry.sprite(name)
    if not spr then return nil end
    local kind = Rules.classify(spr)
    local host, edge = Place.host(sq, spr, kind)
    if not (host and Place.attachedAt(host, name)) then return nil end
    return { sq = sq, host = host, name = name, spr = spr, kind = kind, edge = edge }
end

-- 右鍵選單用：同上，而且那一件的記號（Place.attach 寫的 builderOverlays）寫著是本 MOD 掛的。記號只決定列不列
function Dismantle.overlay(sq, name)
    local t = Dismantle.hung(sq, name)
    local own = t and t.host:hasModData() and t.host:getModData().builderOverlays
    if type(own) ~= "table" or not own[name] then return nil end
    return t
end

-- sq 上本 MOD 掛的每一張（右鍵選單、一區拆除），照名稱排（一格只有幾張，逐張插入；不用 table.sort，家族規則）。
-- 記號在哪一件上都收（地板、各邊的牆：格上每一件都看），同名只列一次
function Dismantle.overlays(sq)
    local out, seen, objects = {}, {}, sq:getObjects()
    local function collect(o)
        local own = o and o:hasModData() and o:getModData().builderOverlays
        for name in pairs(type(own) == "table" and own or {}) do
            local t = type(name) == "string" and not seen[name] and Dismantle.overlay(sq, name)
            if t then
                seen[name] = true
                local j = #out + 1
                while j > 1 and out[j - 1].name > name do
                    out[j] = out[j - 1]
                    j = j - 1
                end
                out[j] = t
            end
        end
    end
    collect(sq:getFloor())
    for i = 0, objects:size() - 1 do collect(objects:get(i)) end
    return out
end

-- 拆一張掛上去的：沒有物件要移除，格子照那一格（Dismantle.check、Dismantle.tools）
function Dismantle.overlayPlan(t)
    return { remove = {}, refund = {}, overlay = t, foreign = false }
end

-- 往 N、E、S、W 上坡的一步
local STEPS = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }

-- 有沒有坡道最上面那片（Entry.rampTop）通到 (x, y, z + 1) 這格：那片在這格往下坡方向一格、下一層。skipX, skipY＝要拆的
-- 那一組自己最上面那片的位置（不算；沒有就傳 nil, nil）。地圖原有的坡道也算
local function rampInto(cell, x, y, z, skipX, skipY)
    for _, d in ipairs(STEPS) do
        local tx, ty = x - d[1], y - d[2]
        local sq = not (tx == skipX and ty == skipY) and cell:getGridSquare(tx, ty, z)
        local objects = sq and sq:hasSlopedSurface() and sq:getObjects() -- 沒有斜面的格子（幾乎全部）不必逐件看
        for i = 0, (objects and objects:size() or 0) - 1 do
            local s = objects:get(i):getSprite()
            local dx, dy
            if s then dx, dy = Entry.rampTop(s) end -- Kahlua 的 a and f() 只留一個回傳值
            if dx == d[1] and dy == d[2] then return true end
        end
    end
    return false
end

-- 有沒有樓梯頂片通到 (x, y, z + 1) 這格（同原版 countAdjacentStairs：W 型頂片在平台東邊、N 型在南邊）
local function stairInto(cell, x, y, z)
    local e, s = cell:getGridSquare(x + 1, y, z), cell:getGridSquare(x, y + 1, z)
    return (e and e:has(IsoObjectType.stairsTW)) or (s and s:has(IsoObjectType.stairsTN)) or false
end

-- 本 MOD 會補的平台：樓梯的 Entry.STAIR_FLOOR 或任一組坡道的平台圖（Entry.isRampDeck），一般地板物件。共用一格的平台只由
-- 先蓋的那組補（後蓋的看到有地板就不補，Place.build），所以樓梯、坡道收平台都認這幾種圖；是不是本 MOD 補的照舊由伺服器
-- 帳本認（Server.dismantle 的 keepLanding）
local function deckOf(o)
    local spr = o:getSprite()
    local name = spr and spr:getName()
    if not (name == Entry.STAIR_FLOOR or (name and Entry.isRampDeck(name) and o:isFloor())) then return false end
    return not (o:isStairsObject() or instanceof(o, "IsoThumpable"))
end

-- 這一組樓梯的平台：頂片往上爬那一側、上一層那格本 MOD 會補的平台（deckOf；Entry.cells 的 platform）。照位置找，
-- 不照原版 buildUtil.getStairObjects 收：原版旁邊八格有別的地板就不收（ISBuildUtil.lua:523-537，原版分不出平台是不是
-- 跟著樓梯補的），本 MOD 補的記在伺服器帳本，拆不拆由伺服器決定（Server.dismantle 的 keepLanding）。另一組往別的方向爬的
-- 樓梯（同原版 countAdjacentStairs）或坡道（rampInto）也通到這格時不收，等最後一組拆掉時才拆。
local function landingOf(top, west)
    local cell, x, y, z = getCell(), top:getX(), top:getY(), top:getZ()
    local lx, ly, other
    if west then
        lx, ly = x - 1, y
        other = cell:getGridSquare(lx, ly + 1, z)
        if other and other:has(IsoObjectType.stairsTN) then return nil end
    else
        lx, ly = x, y - 1
        other = cell:getGridSquare(lx + 1, ly, z)
        if other and other:has(IsoObjectType.stairsTW) then return nil end
    end
    if rampInto(cell, lx, ly, z, nil, nil) then return nil end
    local sq = cell:getGridSquare(lx, ly, z + 1)
    local objects = sq and sq:getObjects()
    for i = 0, (objects and objects:size() or 0) - 1 do
        local o = objects:get(i)
        if deckOf(o) then return o end
    end
    return nil
end

-- 這一組坡道的平台：坡頂往前 Entry.RAMP_DECK 格、上一層那格本 MOD 會補的平台（deckOf；Entry.cells 的 platform）。照位置找，
-- 本 MOD 補的記在伺服器帳本，拆不拆由伺服器決定（Server.dismantle 的 keepLanding）。別的坡道或樓梯也通到這格時不收
-- （同 landingOf），等最後一組拆掉時才拆
local function rampDecks(x, y, z, set)
    local cell, out = getCell(), {}
    local topX, topY = x + (set.n - 1) * set.dx, y + (set.n - 1) * set.dy
    for k = 0, Entry.RAMP_DECK - 1 do
        local px, py = x + (set.n + k) * set.dx, y + (set.n + k) * set.dy
        local sq = not (stairInto(cell, px, py, z) or rampInto(cell, px, py, z, topX, topY))
            and cell:getGridSquare(px, py, z + 1)
        local objects = sq and sq:getObjects()
        for i = 0, (objects and objects:size() or 0) - 1 do
            local o = objects:get(i)
            if deckOf(o) then
                out[#out + 1] = o
                break
            end
        end
    end
    return out[1] and out or nil
end

-- 坡道：照頭片那格推整組各格（Place.rampOrigin），逐格找這一組那一片（同位置、同圖的一般物件），找到的都收進 remove，
-- 不看記號（客戶端改得到；這組是不是本 MOD 蓋的由伺服器照帳本認，Server.unbuildOne）。回 incomplete, partial, 平台：
-- 有一格沒載入 incomplete＝NOT_LOADED（不能拆一半）；都載入但有片不見了 partial＝true（殘組：拆剩下的片、不退料；原版
-- 大錘不保證砸得掉一般物件的坡道片，不給拆會留下清不掉的斜面）
local function rampParts(obj, remove)
    local x, y, z, set = Place.rampOrigin(obj)
    if not set then return "NOT_OURS", false, nil end
    local cell, unloaded, partial = getCell(), false, false
    for i = 1, set.n do
        local sq = cell:getGridSquare(x + (i - 1) * set.dx, y + (i - 1) * set.dy, z)
        local name, found = set.parts[i]:getName(), nil
        local objects = sq and sq:getObjects()
        for j = 0, (objects and objects:size() or 0) - 1 do
            local o = objects:get(j)
            local spr = o:getSprite()
            if spr and spr:getName() == name and not instanceof(o, "IsoThumpable") then
                found = o
                break
            end
        end
        if not sq then
            unloaded = true
        elseif found then
            remove[#remove + 1] = found
        else
            partial = true
        end
    end
    return unloaded and "NOT_LOADED" or nil, partial, rampDecks(x, y, z, set)
end

-- 雙開門第 1–4 片離第 1 片的格數 { x 偏移, y 偏移 }，[北向][開著]（IsoDoor.java:141-148，引擎是 private，照抄）
local DOUBLE_POS = {
    [true] = { [false] = { { 0, 1, 2, 3 }, { 0, 0, 0, 0 } }, [true] = { { 0, 0, 3, 3 }, { 0, 1, 1, 0 } } },
    [false] = { [false] = { { 0, 0, 0, 0 }, { 0, -1, -2, -3 } }, [true] = { { 0, 1, 1, 0 }, { 0, 0, -3, -3 } } },
}

-- 整組門收到的片（buildUtil.getGarageDoorObjects／getDoubleDoorObjects）不是完整一組時回拒絕碼，完整回 nil。
-- 引擎找相鄰片時那一格沒載入就回 null（IsoDoor.java:2814-2816,3076-3078,3117-3119），收到的只是載入中的那幾片：
-- 缺的片那一格沒載入回 NOT_LOADED，有載入（真的少了片）回 NOT_OURS。車庫門完整＝頭片（值 1）與尾片（值 3）都在
-- （中間缺片時從 obj 走不到另一頭）；雙開門完整＝四片都在。頭片（第 1 片）那一格沒載入時認不出這一組
-- （Place.doorAnchor 回 nil），走不到這裡，伺服器回 GONE、不動世界與帳本
local function doorGap(obj, list, garage)
    local cell = getCell()
    if garage then
        local head, tail = false, false
        for _, o in ipairs(list) do
            local i = IsoDoor.getGarageDoorIndex(o)
            head, tail = head or i == 1, tail or i == 3
        end
        if head and tail then return nil end
        for _, o in ipairs(list) do
            local i, sq, n = IsoDoor.getGarageDoorIndex(o), o:getSquare(), o:isNorth() and 1 or 0
            for _, s in ipairs({ -1, 1 }) do -- 照 getGarageDoorPrev（−1）／Next（+1）找的那一格
                local cut = (s < 0 and i ~= 1 and not IsoDoor.getGarageDoorPrev(o)) or (s > 0 and i ~= 3 and not IsoDoor.getGarageDoorNext(o))
                if cut and not cell:getGridSquare(sq:getX() + s * n, sq:getY() - s * (1 - n), sq:getZ()) then return "NOT_LOADED" end
            end
        end
        return "NOT_OURS"
    end
    if #list >= 4 then return nil end
    -- 雙開門：缺的那幾片照 getDoubleDoorObject 找的格子（IsoDoor.java:2811-2816）
    local have, sq = {}, obj:getSquare()
    for _, o in ipairs(list) do have[IsoDoor.getDoubleDoorIndex(o)] = true end
    local pos, j = DOUBLE_POS[obj:isNorth()][obj:isOpen()], IsoDoor.getDoubleDoorIndex(obj)
    for i = 1, 4 do
        local x, y = sq:getX() - pos[1][j] + pos[1][i], sq:getY() - pos[2][j] + pos[2][i]
        if not have[i] and not cell:getGridSquare(x, y, sq:getZ()) then return "NOT_LOADED" end
    end
    return "NOT_OURS"
end

-- 拆一件要移除哪些物件、照哪些物件的退料表退。回 { remove = { 物件 }, refund = { 物件 }, landing = { 平台 } 或 nil,
-- foreign = true（同一組裡有不是本 MOD 蓋的片）, incomplete = 拒絕碼（整組門不完整、坡道有格沒載入）, partial = true
-- （坡道殘組：refund 照樣要查得到帳本，但不退料）}。同一組的片照「本 MOD 蓋的」收，不照各片自己的種類（建造時整組用
-- 原點的種類，Place.build）；同一組有不是本 MOD 蓋的片就整組不拆（foreign）：
--   樓梯：原版 buildUtil.getStairObjects 收三片（ISDismantleAction.lua:76-80），只照被點的那片退一次（三片的退料表都寫
--     整組，Place.build），所以同方向的三片要一起拆。getStairObjects 也收同一格別方向的樓梯片，那些不算這一組。
--     平台照 landingOf 找。
--   坡道：整組各片照位置與圖名收（rampParts），退料照頭片那格那一筆帳本退一次（Place.refundOf，點哪一片都一樣；沒有
--     那一筆伺服器回 NOT_OURS、一片不拆）；平台照 rampDecks 找。殘組（partial）照拆剩下的片、一律不退料；某片被別的
--     方式移走時那一筆已作廢成空表（Place.onAboutToBeRemoved），完整的一組退過一次後那一筆也沒了，所以不會多拿材料。
--   多格：同一組的每一片（getSpriteGridObjectsIncludingSelf，ISDestroyCursor.lua:217），每片照自己的退料表退。引擎只看
--     sprite grid 相同、不看是不是同一個原點（IsoObject.java:5410-5444），另用 isConnectedSpriteGridObject 對原點。
--   其他：自己。
function Dismantle.plan(obj, kind)
    local remove, refund, landing, foreign, incomplete, partial = {}, {}, nil, false, nil, nil
    if kind == "stairs" then
        local west, top = Rules.westStairs(obj:getSprite():getType()), nil
        for _, o in ipairs(buildUtil.getStairObjects(obj, true)) do
            local spr = o:getSprite()
            if o:isStairsObject() and spr and Rules.westStairs(spr:getType()) == west then
                if mine(o) then remove[#remove + 1] = o else foreign = true end
                local t = spr:getType()
                if t == IsoObjectType.stairsTW or t == IsoObjectType.stairsTN then top = o:getSquare() end
            end
        end
        local l = top and landingOf(top, west)
        if l then landing = { l } end
        refund[1] = obj
    elseif kind == "ramp" then
        incomplete, partial, landing = rampParts(obj, remove)
        refund[1] = obj
    elseif kind == "door" then
        -- 車庫門、雙開門（單扇門 kindOf 不認）：整組拆（原版大錘也整組砸，ISDestroyStuffAction.lua:269-296），退料照第一片
        -- 那一筆帳本退一次（Place.refundOf）。不完整的一組不拆（doorGap）：一部分沒載入時只拆得到載入的那幾片、卻退整組；
        -- 雙開門少了片（帶拆解材質的圖原版能逐片拆，ISMoveableSpriteProps.lua:3851-3939；第 2、3 片被拆不清帳本，見
        -- Place.onAboutToBeRemoved）那片會退兩次
        local garage = IsoDoor.getGarageDoorIndex(obj) ~= -1
        local list = garage and buildUtil.getGarageDoorObjects(obj) or buildUtil.getDoubleDoorObjects(obj)
        incomplete = doorGap(obj, list, garage)
        for _, o in ipairs(list) do
            if mine(o) then remove[#remove + 1] = o else foreign = true end
        end
        refund[1] = Place.doorAnchor(obj)
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
    return { remove = remove, refund = refund, landing = landing, foreign = foreign, incomplete = incomplete,
        partial = partial or nil }
end

-- 拆這一件要的工具：和蓋的時候一樣（Cost.of 的 tools，多格取聯集；使用者 2026-10-28 選）。整組門每一片照現在的圖對回
-- 它自己那一片關著的圖（Entry.doorSet 的 closed；開著的圖沒有拆解材質，照它算工具會不一樣），只算真的在的片（兩格寬的
-- 車庫門沒有中段）。不看 modData（客戶端改得到）
function Dismantle.tools(kind, plan)
    local list = {}
    for _, o in ipairs(plan.remove) do
        local spr = o:getSprite()
        local first = kind == "door" and Entry.doorItem(spr:getName())
        local set = first and Entry.doorSet(Entry.sprite(first))
        list[#list + 1] = Cost.of(kind, set and set.closed[spr:getName()] or spr, 1)
    end
    if plan.overlay then list[#list + 1] = Cost.of(kind, plan.overlay.spr, 1) end
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
-- （IsoGridSquare.java:3619-3629,3651-3665；Place.check 同一種寫法）。
local function attached(kind, o, sq, spr)
    if o:isBarricaded() then return true end
    local n, w = Entry.edges(kind, spr)
    if kind == "doorFrame" then return (n and sq:getDoor(NS) ~= nil) or (w and sq:getDoor(EW) ~= nil) or false end
    return (n and sq:getWindow(NS) ~= nil) or (w and sq:getWindow(EW) ~= nil) or false
end

-- 原版拆解擋的那兩項（NOT_EMPTY、ATTACHED）：回 code, extra 或 nil。原地替換（Check.item）也照這兩項擋舊的那件
function Dismantle.blocked(kind, plan)
    for _, o in ipairs(plan.remove) do
        local sq = o:getSquare()
        local at = { x = sq:getX(), y = sq:getY(), z = sq:getZ() }
        local spr = o:getSprite()
        local p = spr:getProperties()
        if not o:isObjectNoContainerOrEmpty() or (p:has("IsTable") and sq:has("IsTableTop")) then return "NOT_EMPTY", at end
        if (kind == "doorFrame" or kind == "windowFrame") and attached(kind, o, sq, spr) then return "ATTACHED", at end
        -- 牆飾、門框牆當全高窗的框（Place.check 的 tallFrame），牆頂橫條當滑門的框：拆了窗、門會懸空
        if Place.framesWindow(o, sq) or Place.framesDoor(o, sq) then return "ATTACHED", at end
    end
    return nil
end

-- 缺的工具（Dismantle.tools 對背包，Materials.missingTools）。memo（選填，一次 collect 用的空表）：照「種類＋各片圖名」
-- 記住結果。工具只看圖，同一次預覽背包不變；沒帶工具時整區每件都查到這裡，不必每件重算一次
local function missingTools(player, kind, plan, memo)
    if not memo then return Materials.missingTools(player, Dismantle.tools(kind, plan)) end
    local parts = { kind }
    for i, o in ipairs(plan.remove) do parts[i + 1] = o:getSprite():getName() end
    if plan.overlay then parts[#parts + 1] = plan.overlay.name end
    local key = table.concat(parts, "|")
    local m = memo[key]
    if m == nil then
        m = Materials.missingTools(player, Dismantle.tools(kind, plan)) or false
        memo[key] = m
    end
    return m or nil
end

-- 能不能拆，回 code, extra 或 nil。順序：
--   整組門不完整（plan.incomplete：有片沒載入 NOT_LOADED、少了片 NOT_OURS）；同一組有不是本 MOD 蓋的片（plan.foreign）：NOT_OURS。
--   距離：和蓋一樣（Check.near：MaxDistance、上下差一層、同一層要走得到；在格邊上動手的從哪一側都能拆；建造作弊不查）。
--     preview（右鍵選單）不查：選了會先走過去（建造作弊不走、原地拆）；伺服器完成時照上一行查。
--   安全屋：每一片的格子都要有 BUILD 權限（原版大錘也是），不看 WhereCanBuild。
--   原版拆解擋的（canScrapObjectInternal，ISMoveableSpriteProps.lua:3905-3939）：
--     容器要空（isObjectNoContainerOrEmpty；伺服器的移除不倒出內容，IsoObject.java:4534-4542）、桌子上有桌上物件：
--     NOT_EMPTY（集水的不列，Rules 的 COLLECTOR，所以不查有沒有水）。門框裝著門、窗框裝著窗、框上釘著木板：ATTACHED。
--     二樓以上、樓梯頂端接著的地板：STAIRS_TOP。
--   二樓以上的地板：格上有別的東西（牆、家具、地上物品）不拆，不然會懸空。
--   工具：和蓋的時候一樣；建造作弊不查（Server.complete 同一條）。toolMemo 見 missingTools（伺服器不傳，照舊每件查）。
function Dismantle.check(player, kind, plan, ...)
    local preview, toolMemo = ...
    local cells = {}
    for i, o in ipairs(plan.remove) do
        local sq = o:getSquare()
        cells[i] = { x = sq:getX(), y = sq:getY(), z = sq:getZ(), sq = sq }
    end
    if plan.overlay then
        local sq = plan.overlay.sq
        cells[1] = { x = sq:getX(), y = sq:getY(), z = sq:getZ(), sq = sq }
    end
    if #cells == 0 then return "GONE", nil end
    if plan.incomplete then return plan.incomplete, { x = cells[1].x, y = cells[1].y, z = cells[1].z } end
    if plan.foreign then return "NOT_OURS", { x = cells[1].x, y = cells[1].y, z = cells[1].z } end
    if not preview then
        local spr = plan.overlay and plan.overlay.spr or plan.remove[1]:getSprite()
        local code, extra = Check.near(player, cells, Entry.edgeNorth(kind, spr) ~= nil, false)
        if code then return code, extra end
    end
    for _, c in ipairs(cells) do
        local code = Check.safehouse(player, c, preview, "dismantle")
        if code then return code, { x = c.x, y = c.y, z = c.z } end
    end
    local code, at = Dismantle.blocked(kind, plan)
    if code then return code, at end
    if kind == "floor" then
        for _, c in ipairs(cells) do
            if c.z > 0 then
                local at2 = { x = c.x, y = c.y, z = c.z }
                if stairsTop(c) then return "STAIRS_TOP", at2 end
                if c.sq:getObjects():size() > 1 then return "FLOOR_IN_USE", at2 end
            end
        end
    end
    if not Materials.cheat(player) then
        local missing = missingTools(player, kind, plan, toolMemo)
        if missing then return "NO_TOOL", { tools = missing } end
    end
    return nil
end

-- ---------------------------------------------------------------- 原地替換（設計稿）
-- 在本工具蓋的東西上蓋同一組的另一款＝換掉舊的。同一組：牆、柵欄、門框、窗框互換（不必先拆牆就能開窗），其他照種類。
Dismantle.GROUP = { wall = "edge", fence = "edge", doorFrame = "edge", windowFrame = "edge" }
-- 不換的種類：燈、樓梯（多片、帳本）；地面覆蓋、牆面疊圖、疊圖會疊加（蓋新的是多一張，不是換）；門、窗、窗簾不是
-- 本工具拆的（Cost.refund 的 none／sheet）；水井與手壓水泵、植物、水面（使用者 2026-11-13 新增）不換，要先拆（水面是填平）再蓋。
-- 在水面上蓋地板照「地板一律換」：Place.clearFloor 拆掉水面（不是替換，不退料），水面的記號跟著物件消失
Dismantle.NO_REPLACE = { light = true, stairs = true, ramp = true, floorOverlay = true, wallOverlay = true, overlay = true,
    door = true, window = true, curtain = true, well = true, plant = true, water = true }

-- 舊的那件會不會佔住新的要放的位置（佔住才換；不佔的照舊同格共存，Check.item 另用 Place.check 確認）：格邊的同組、
-- 地板（一格一片）、實心或擋放置的、帶 WallSE 的柱子（Place.check 的柱子只看它）。屋頂不換：同格的舊屋頂算支撐，新的
-- 一定放得下（Place.roofAt）。右鍵「換成...」與建造視窗的換成清單也照這條，不列換不了的
local function exclusive(kind, spr)
    if Dismantle.GROUP[kind] or kind == "floor" then return true end
    local p = spr:getProperties()
    return p:has(IsoFlagType.solid) or p:has(IsoFlagType.solidtrans) or p:has("BlocksPlacement")
        or (kind == "post" and p:has(IsoFlagType.WallSE)) or false
end

-- 舊的（oldKind、oldSpr）能不能換成新的（kind、spr）：同一組、都能換、舊的佔住位置（exclusive）、佔同一條邊（Entry.edges
-- 一樣）、不是同一張圖、兩張都是單格。只看圖，不碰世界（建造視窗「換成...」列同款也用）
function Dismantle.swappable(oldKind, oldSpr, kind, spr)
    if Dismantle.NO_REPLACE[oldKind] or Dismantle.NO_REPLACE[kind] then return false end
    if (Dismantle.GROUP[oldKind] or oldKind) ~= (Dismantle.GROUP[kind] or kind) then return false end
    if oldSpr:getName() == spr:getName() or oldSpr:getSpriteGrid() or spr:getSpriteGrid() then return false end
    if not exclusive(oldKind, oldSpr) then return false end
    local n1, w1 = Entry.edges(oldKind, oldSpr)
    local n2, w2 = Entry.edges(kind, spr)
    return n1 == n2 and w1 == w2
end

-- 舊的這一件本身能不能被原地換掉（右鍵「換成...」與 replaceable 共用一份）：種類能換、會佔住位置（exclusive）、
-- 單格，拆的時候只動它一片（多格、樓梯平台、整組有別人蓋的片都不換）
function Dismantle.replaceableOld(kind, obj, plan)
    local spr = obj:getSprite()
    return not Dismantle.NO_REPLACE[kind] and exclusive(kind, spr) and not spr:getSpriteGrid()
        and #plan.remove == 1 and not plan.landing and not plan.foreign
end

-- sq 上能被 spr（種類 kind）原地換掉的那件：本工具拆得掉（kindOf）、swappable、replaceableOld。回 obj, oldKind 或 nil
function Dismantle.replaceable(sq, kind, spr)
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        local oldKind = Dismantle.kindOf(o)
        if oldKind and Dismantle.swappable(oldKind, o:getSprite(), kind, spr)
            and Dismantle.replaceableOld(oldKind, o, Dismantle.plan(o, oldKind)) then
            return o, oldKind
        end
    end
    return nil
end

-- 燈拆了退什麼：退料表（伺服器帳本或估的價）有燈泡、燈上卻已經沒有（IsoLightSwitch.hasLightBulb，IsoLightSwitch.java:225-227）
-- 時不退燈泡。本工具拆的燈都不能搬，原版拿不下、不會燒掉（:76-79,683,733），這條防的是別的 MOD 改掉燈泡欄位。
-- 0.5.0 以前蓋的不能搬的燈帳本本來就沒有燈泡。伺服器 Server.dismantle
-- 與預覽 estimateRefund 共用
function Dismantle.lightRefund(obj, mats)
    if not (mats and mats[Cost.BULB] and instanceof(obj, "IsoLightSwitch")) or obj:hasLightBulb() then return mats end
    local out = {}
    for ft, n in pairs(mats) do
        if ft ~= Cost.BULB then out[ft] = n end
    end
    return out
end

-- 客戶端預覽用的舊退料（伺服器照 Place.refundOf 算，見 Check.item）：拿得到退料表（buildMaterials）就用；拿不到
-- （一樓地板記在伺服器帳本、燈、家電）照現在的價（Cost.forCells × 沙盒倍率）扣電器費估。回 had, estimated（true＝估的）
function Dismantle.estimateRefund(obj, kind)
    if instanceof(obj, "IsoThumpable") and obj:hasBuildMaterials() then return obj:getBuildMaterials(), false end
    local cost = Cost.forCells(kind, { obj:getSprite() }, Check.setting("CostMultiplier", 1))[1]
    local had, fee = {}, cost.fee or {}
    for ft, n in pairs(cost.items) do
        local v = n - (fee[ft] or 0)
        if v > 0 then had[ft] = v end
    end
    return Dismantle.lightRefund(obj, had), true
end

return Dismantle
