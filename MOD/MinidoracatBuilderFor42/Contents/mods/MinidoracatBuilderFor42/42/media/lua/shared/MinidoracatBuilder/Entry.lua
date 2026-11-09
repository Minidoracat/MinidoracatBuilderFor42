-- 項目：客戶端送來的「項目 ID＋朝向」→ 這次要放的 sprite、種類、佔地。兩端共用：客戶端預覽，伺服器重算後才算數。
-- 項目 ID＝sprite 名稱，多格項目用該面 grid 的原點（bt-catalog §8.1）。伺服器不建目錄，收到請求才重算這一項（§8.2）。
require "MinidoracatBuilder/Rules"
require "MinidoracatBuilder/Sources"

MinidoracatBuilder = MinidoracatBuilder or {}
local Entry = MinidoracatBuilder.Entry or {}
MinidoracatBuilder.Entry = Entry
local Rules, Sources = MinidoracatBuilder.Rules, MinidoracatBuilder.Sources

-- 規則版本：伺服器怎麼判斷種類、成本、可放置有變就加一。客戶端版本不同時請求會被拒（STALE），提示重開視窗。
Entry.VERSION = 11
local NO_TILE_ID = 20000000 -- 非 tiledef sprite 的預設 id（IsoSprite.java:129-130）
local MAX_NAME = 128

-- 能蓋的種類，照建造視窗的頁籤排（沙盒「能蓋的種類」頁與管理面板同一個順序）。車庫門、雙開門第二版
-- （設計稿 Rules.classify 的註記）。
Entry.KINDS = { "floor", "floorOverlay", "wall", "fence", "post", "wallOverlay", "door", "window", "doorFrame",
    "windowFrame", "windowObject", "curtain", "roof", "stairs", "furniture", "container", "solid", "light", "wallObject",
    "attached", "overlay" }
Entry.BUILDABLE = {}
-- 種類開關（沙盒每種一個勾選框，使用者 2026-10-31 選）：鍵＝Kind＋種類 ID 字首大寫，例 KindFloorOverlay。鍵名上線後不能改
Entry.KIND_KEY = {}
for _, k in ipairs(Entry.KINDS) do
    Entry.BUILDABLE[k] = true
    Entry.KIND_KEY[k] = "Kind" .. k:sub(1, 1):upper() .. k:sub(2)
end

-- 樓梯頂端平台的地板（原版 buildRecipeCode.lua:258-261）
Entry.STAIR_FLOOR = "carpentry_02_57"

-- 佔一條格邊的種類：要對齊牆線、檢查那條邊空著。柱子不佔邊（NORTH／WEST 是空的；擋邊的圖 Rules 不列），
-- 走 Place.check 的柱子分支
Entry.EDGE = { wall = true, windowFrame = true, doorFrame = true, fence = true, door = true, window = true, post = true }

-- 沙盒值（SandboxVars.MinidoracatBuilder）；離線測試沒有 SandboxVars 時用空表，各欄位由呼叫端給預設
function Entry.settings()
    return SandboxVars and SandboxVars.MinidoracatBuilder or {}
end

-- 這個種類開著（沙盒沒有這個鍵時當開著）。s＝Entry.settings()，呼叫端已經拿到的就傳
function Entry.kindOn(kind, s)
    local key = Entry.KIND_KEY[kind]
    return key == nil or (s or Entry.settings())[key] ~= false
end

-- 「a;b;c」→ 集合。只快取上一次的字串：管理員改了才重切。
local function setCache()
    local lastRaw, lastSet
    return function(raw)
        raw = raw or ""
        if raw ~= lastRaw then
            lastSet = {}
            for part in raw:gmatch("[^;]+") do
                local v = part:match("^%s*(.-)%s*$")
                if v ~= "" then lastSet[v] = true end
            end
            lastRaw = raw
        end
        return lastSet
    end
end
local disabledSources, disabledTilesets = setCache(), setCache()

-- 規則版本＋會改變判斷的設定。兩端都從 SandboxVars 算（客戶端連線時伺服器整包推送，之後改了也即時轉送），
-- 不必另外傳。只用來給玩家看得懂的錯誤，不是安全機制：伺服器照樣每格重算。
-- 字串沒變就回上次的（建造視窗每秒比一次；停用清單可能很長，Kahlua 逐字算雜湊不便宜）
local lastRaw, lastDigest
function Entry.digest()
    local s = Entry.settings()
    local bits = {}
    for i, k in ipairs(Entry.KINDS) do bits[i] = Entry.kindOn(k, s) and "1" or "0" end
    local raw = table.concat({ tostring(s.CostMultiplier or 1), tostring(s.WhereCanBuild or 1),
        s.DisabledSources or "", s.DisabledTilesets or "", table.concat(bits),
        tostring(s.RequireSkill == true), tostring(s.RecipeMaterials == true) }, "|")
    if raw ~= lastRaw then
        local h = 5381
        for i = 1, #raw do h = (h * 33 + raw:byte(i)) % 2147483647 end
        lastRaw, lastDigest = raw, "r" .. Entry.VERSION .. ":" .. h
    end
    return lastDigest
end

-- 查 sprite 一律 containsKey＋get：全域 getSprite 查不到時會往 namedMap 加一個空 sprite（IsoSpriteManager.java:47-49,77-82）
function Entry.sprite(name)
    if type(name) ~= "string" or #name > MAX_NAME then return nil end
    local named = IsoSpriteManager.instance:getNamedMap()
    if not named:containsKey(name) then return nil end
    return named:get(name)
end

-- 回 entry＝{ name, spr, kind, tileset, num, mod }，或 nil＋原因碼（UNKNOWN／UNSUPPORTED／DISABLED）
function Entry.resolve(name)
    local spr = Entry.sprite(name)
    if not spr then return nil, "UNKNOWN" end
    Rules.ensure()
    local id = spr:getID()
    if id < 0 or id == NO_TILE_ID then return nil, "UNKNOWN" end
    local kind = Rules.classify(spr)
    if not kind then return nil, "UNKNOWN" end
    if not Entry.BUILDABLE[kind] then return nil, "UNSUPPORTED" end
    -- 樓梯只收湊得成三格的底片（目錄同一條規則，Catalog.scanSprite）
    if kind == "stairs" and not Rules.stairsSet(IsoSpriteManager.instance:getNamedMap(), name) then
        return nil, "UNKNOWN"
    end
    local grid = spr:getSpriteGrid()
    if grid and grid:getAnchorSprite() ~= spr then return nil, "UNKNOWN" end -- 多格只收原點
    local tileset, num = name:match("^(.*)_(%d+)$")
    if not tileset then return nil, "UNKNOWN" end
    local file = Sources.fileOf(id)
    local mod = Sources.isModFile(file) and Sources.map()[file] or nil
    local s = Entry.settings()
    if (mod and disabledSources(s.DisabledSources)[mod]) or disabledTilesets(s.DisabledTilesets)[tileset]
        or not Entry.kindOn(kind, s) then
        return nil, "DISABLED"
    end
    return { name = name, spr = spr, kind = kind, tileset = tileset, num = tonumber(num), mod = mod }
end

-- 同一個 tileset 編號差 d 的名稱
local function offset(name, d)
    local tileset, num = name:match("^(.*)_(%d+)$")
    return tileset and (tileset .. "_" .. (tonumber(num) + d)) or nil
end

-- 原版兩張一組、交替排的柵欄：BrokenFences.lua 註解寫「2-tile」的五族（BentFences.lua 的 stage 也照 ABAB 排），
-- 北向、西向各一對 { A, B }。圖塊包的柵欄不猜。鐵絲網兩族（24/25、26/27、56/57、58/59）不換：每對有一張
-- （fencing_01_25/26/57/58）是原版建造配方的圖（Rules 回 ENTITY），使用者 2026-10-31 定配方的圖只收地板與地面覆蓋
local ALTERNATE = {}
for _, n in ipairs({ 8, 10, 32, 34, 64, 66 }) do
    local pair = { "fencing_01_" .. n, "fencing_01_" .. (n + 1) }
    ALTERNATE[pair[1]], ALTERNATE[pair[2]] = pair, pair
end

-- 格 (x, y) 實際放的圖：名單裡的柵欄照 (x+y) 奇偶放 A（偶）或 B（奇），另一張查不到或自己不能蓋時照原圖；其他圖照原圖。
-- 兩端共用（Check.item 給伺服器與預覽、游標虛影），所以扣料、退料表、builderEntry 都是放下的那張。單格放也照座標：
-- 同一格永遠同一張，伺服器不必知道是不是拖的
function Entry.alternate(spr, x, y)
    local pair = spr and ALTERNATE[spr:getName()] -- 游標沒有那一面的格子（NO_FACE）傳 nil：照回 nil（只畫地框）
    if not pair then return spr end
    local alt = Entry.sprite(pair[(x + y) % 2 + 1])
    if not alt or alt == spr then return spr end
    -- 另一張也要自己能蓋（同 Entry.face）：別的 MOD 用 addLuaSprites 排除、或配方佔走它時照 resolve 擋（審查 1107 Codex）
    local other = Entry.resolve(alt:getName())
    return other and other.kind == "fence" and alt or spr
end

-- 樓梯中片、頂片所屬那一組的底片（Rules.stairsSet 的 B 片在 ±1、±2）
local function stairsBottom(name)
    local named = IsoSpriteManager.instance:getNamedMap()
    for _, d in ipairs({ -2, -1, 1, 2 }) do
        local b = offset(name, d)
        local set = b and named:containsKey(b) and Rules.stairsSet(named, b)
        if set and (set.m == name or set.t == name) then return b end
    end
    return nil
end

-- 這個名稱為什麼不能蓋、該改找哪一張（建造視窗搜完整圖塊名、右鍵挑圖塊用）。回 code, arg, alt：
--   code＝原因碼（IGUI_MBLD_Why_<碼>；nil＝能蓋）：UNKNOWN 沒有這張圖、Rules.kindOf 的碼、UNSUPPORTED 車庫門、
--     PART 多格的其他格、STAIRS_SET 湊不成三格的樓梯片、DISABLED_KIND／DISABLED_SOURCE／DISABLED_TILESET 管理員關掉的
--   arg＝說明裡的名稱：建造配方（EntityScriptName）、種類 ID、MOD ID 或 tileset
--   alt＝同一件東西能蓋的那一張（開著的門、窗的狀態圖、拉上的窗簾、疊放圖、多格的原點、樓梯的底片），能蓋才給。
--     那張也不能蓋時改給它能蓋的那張，不然 code／arg 改說它的原因（只往下查一層；nested 是內部用的）
function Entry.why(name, nested)
    local entry, res = Entry.resolve(name)
    if entry then return nil end
    local spr = Entry.sprite(name)
    if not spr or spr:getID() < 0 or spr:getID() == NO_TILE_ID then return "UNKNOWN" end
    local p = spr:getProperties()
    local kind, code = Rules.classify(spr)
    local arg, alt
    if code == "ENTITY" then
        arg = p:get("EntityScriptName")
    elseif code == "WINDOW_STATE" then
        alt = Rules.windowOf(name)
    elseif code == "DOOR_OPEN" then
        alt = offset(name, -2)
    elseif code == "CURTAIN_CLOSED" then
        alt = offset(name, 4)
    elseif code == "STACK" then
        alt = offset(name, tonumber(p:get("StackReplaceTileOffset")) or 0)
    elseif res == "DISABLED" then -- resolve 最後才查開關：走到這裡的種類、樓梯組、原點都沒問題
        local s = Entry.settings()
        local tileset = name:match("^(.*)_%d+$")
        if not Entry.kindOn(kind, s) then
            code, arg = "DISABLED_KIND", kind
        elseif disabledTilesets(s.DisabledTilesets)[tileset] then
            code, arg = "DISABLED_TILESET", tileset
        else
            code, arg = "DISABLED_SOURCE", Sources.map()[Sources.fileOf(spr:getID())]
        end
    elseif res == "UNSUPPORTED" then
        code = "UNSUPPORTED"
    elseif kind == "stairs" then
        code, alt = "STAIRS_SET", stairsBottom(name)
    elseif kind then
        local grid = spr:getSpriteGrid()
        local anchor = grid and grid:getAnchorSprite()
        if anchor and anchor ~= spr then code, alt = "PART", anchor:getName() end
    end
    if alt and not Entry.resolve(alt) then
        -- 叫玩家去找的那張也不能蓋（管理員關掉了、打不破的窗…）：照著做也找不到，改說它的原因
        local c2, a2, alt2
        if not nested then c2, a2, alt2 = Entry.why(alt, true) end
        if alt2 then
            alt = alt2
        else
            if c2 and c2 ~= "UNKNOWN" then code, arg = c2, a2 end
            alt = nil
        end
    end
    return code or "UNKNOWN", arg, alt
end

-- 配對面（d＝5，矩形建造沿四邊圍一圈用）：原版北牆、西牆是不同項目（目錄不併）。只對佔一條格邊的種類（門、窗不算），
-- 項目只佔北或西其中一條時，在同一個 tileset 找只佔另一條、同種類的圖，照順序：
--   1. 編號 xor 1（原版牆多是偶數西、奇數北）；2. xor 1 和自己同一條邊時是兩張一組（4W 5W 6N 7N），改看 ±2；
--   3. 編號 ±1、±2、±3（先 + 後 −）第一張。都沒有回 nil。
-- 離線量過原版 4,045 張單邊非門窗的格邊圖：1. 956、2. 726、3. 811、找不到 1,552（2026-11-01）。
-- 圖塊表在一個 session 裡不變，照項目名稱快取（false＝找不到）
local pairCache = {}
local function opposite(entry)
    local kind = entry.kind
    if not Entry.EDGE[kind] or kind == "door" or kind == "window" then return nil end
    local n, w = Entry.edges(kind, entry.spr)
    if n == w then return nil end
    local function only(num) -- 這個編號的圖只佔另一條邊、同種類
        local spr = Entry.sprite(entry.tileset .. "_" .. num)
        if not spr or Rules.classify(spr) ~= kind then return nil, nil end
        local n2, w2 = Entry.edges(kind, spr)
        if n2 == w2 then return nil, nil end
        return n2 == w and spr or nil, n2 == n
    end
    local num = entry.num
    local x = num % 2 == 0 and num + 1 or num - 1
    local spr, same = only(x)
    if spr then return spr end
    if same then
        spr = only(num % 4 < 2 and num + 2 or num - 2)
        if spr then return spr end
    end
    for _, d in ipairs({ 1, -1, 2, -2, 3, -3 }) do
        spr = num + d >= 0 and only(num + d)
        if spr then return spr end
    end
    return nil
end

-- 引擎沒連起來的同名家具（Entry.face 的後備）。引擎只替能搬、有 GroupName、同組最多 4 張且每面一張的圖寫朝向偏移
-- （IsoWorld.java:1076-1113,1316-1338），其他同名的圖原版搬家具也轉不了。這裡把 SIBLING 種類裡同一 tileset、同種類、
-- 同 GroupName＋CustomName、單格、沒有引擎偏移的圖配起來：每張都有 Facing、每個朝向剛好一張才配。同名好幾款照編號配
-- 會配錯（2026-11-03 稽核 1031c：這樣配得到的 187 張全部看圖）；NO_PAIR 是看圖確認的同名不同物，鍵＝
-- tileset|GroupName|CustomName。第一次碰到一個 tileset 時從 _0 往上掃到第一個沒有的編號（引擎照 nTiles 連號建，
-- IsoWorld.java:712-728），結果照 tileset 快取：sibCache[tileset][名稱]＝{ N = 圖, … }，不配的不記。
local SIBLING = { furniture = true, container = true, solid = true, light = true, wallObject = true, attached = true,
    overlay = true }
local NO_PAIR = { ["AuthenticZ_Store||Wall Piece"] = true, ["DylansRandomFurniture02||Safe"] = true,
    ["Ekron01||Cartoon Poster"] = true }
local ENGINE_OFFSETS = { "Noffset", "Eoffset", "Soffset", "Woffset" }
local sibCache = {}

-- 能參加配對的圖回名稱鍵「GroupName|CustomName」：單格、沒有引擎偏移、有名稱；否則 nil
local function siblingKey(spr, p)
    if spr:getSpriteGrid() or p:has("SpriteGridPos") then return nil end
    for i = 1, 4 do
        if p:has(ENGINE_OFFSETS[i]) then return nil end
    end
    local group, custom = p:get("GroupName") or "", p:get("CustomName") or ""
    if group == "" and custom == "" then return nil end
    return group .. "|" .. custom
end

local function scanSiblings(tileset)
    local named, byKey, i = IsoSpriteManager.instance:getNamedMap(), {}, 0
    local name = tileset .. "_0"
    while named:containsKey(name) do
        local spr = named:get(name)
        local key = siblingKey(spr, spr:getProperties())
        if key then
            local list = byKey[key]
            if not list then
                list = {}
                byKey[key] = list
            end
            list[#list + 1] = spr
        end
        i = i + 1
        name = tileset .. "_" .. i
    end
    local out = {}
    for key, list in pairs(byKey) do
        if #list >= 2 and not NO_PAIR[tileset .. "|" .. key] then
            local kinds, sets = {}, {} -- 種類 → { n, N = 圖, … }；有一張沒有 Facing 或朝向重複時 false
            for j, spr in ipairs(list) do
                local kind = Rules.classify(spr)
                if kind and SIBLING[kind] and sets[kind] ~= false then
                    kinds[j] = kind
                    local set = sets[kind] or { n = 0 }
                    local f = spr:getProperties():get("Facing")
                    if (f == "N" or f == "E" or f == "S" or f == "W") and not set[f] then
                        set[f], set.n = spr, set.n + 1
                        sets[kind] = set
                    else
                        sets[kind] = false
                    end
                end
            end
            for j, spr in ipairs(list) do
                local set = kinds[j] and sets[kinds[j]]
                if set and set.n >= 2 then out[spr:getName()] = set end
            end
        end
    end
    return out
end

-- 朝向 dir（"N" 等）的同名圖；項目不在配得起來的一組時 nil
local function siblingFace(entry, dir, p)
    if not SIBLING[entry.kind] or not siblingKey(entry.spr, p) then return nil end
    local t = sibCache[entry.tileset]
    if not t then
        t = scanSiblings(entry.tileset)
        sibCache[entry.tileset] = t
    end
    local set = t[entry.name]
    return set and set[dir] or nil
end

-- 朝向 d：0＝項目本身那一面；1..4＝N、E、S、W；5＝配對面（上面）。引擎替同組的每個成員寫「其他面的原點 − 自己」的
-- Noffset 等，自己那一面不寫（IsoWorld.java:1295-1337），所以自己的 Facing 就是自己；引擎沒連起來的同名家具照
-- siblingFace 配。查不到那一面回 nil。
local DIRS = { "N", "E", "S", "W" }
function Entry.face(entry, d)
    if d == 0 then return entry.spr end
    local spr
    if d == 5 then
        local c = pairCache[entry.name]
        if c == nil then
            c = opposite(entry) or false
            pairCache[entry.name] = c
        end
        spr = c or nil
    else
        local dir = DIRS[d]
        if not dir then return nil end
        local p = entry.spr:getProperties()
        local off = tonumber(p:get(dir .. "offset"))
        if off then
            spr = Entry.sprite(entry.tileset .. "_" .. (entry.num + off))
        elseif p:get("Facing") == dir then
            spr = entry.spr
        else
            spr = siblingFace(entry, dir, p)
        end
    end
    if not spr then return nil end
    if spr == entry.spr then return spr end
    -- 另一面也要自己能蓋、同一種類：來源、圖塊組、種類開關照 Entry.resolve 重算（同一個 tileset 的圖可能來自不同
    -- tiledef 檔，那個來源被停用時要擋，審查 1103 Codex；配對面也一樣，Claude 第 2 輪）。開關執行中會變，所以不快取
    -- 這一步。樓梯的另一面是另一組，resolve 也驗它湊得成三格
    local other = Entry.resolve(spr:getName())
    if not other or other.kind ~= entry.kind then return nil end
    return spr
end

-- 佔地：{ { dx, dy, dz, sprite[, 角色] }, ... }，相對原點那一格。單格就是自己。
-- 原點＝grid 第一層第一個非空成員（IsoSpriteGrid.java:23-31），不一定在 (0,0)。
-- 樓梯（項目＝底片）：原點是頂片，接著中片、底片，最後是上一層的平台（角色 top／mid／bottom／platform）。
-- 往西爬的（W 型）沿 +x 排、平台在 x−1；往北爬的（N 型）沿 +y 排、平台在 y−1（buildRecipeCode.lua:196-206,263-289）。
function Entry.cells(spr)
    if Rules.typeCode(spr:getType()) == "stairs" then
        local named = IsoSpriteManager.instance:getNamedMap()
        local set = Rules.stairsSet(named, spr:getName())
        if set then
            local dx, dy = 1, 0
            if set.dir == "N" then dx, dy = 0, 1 end
            return { { 0, 0, 0, named:get(set.t), "top" }, { dx, dy, 0, named:get(set.m), "mid" },
                { 2 * dx, 2 * dy, 0, spr, "bottom" }, { -dx, -dy, 1, named:get(Entry.STAIR_FLOOR) or spr, "platform" } }
        end
    end
    local grid = spr:getSpriteGrid()
    if not grid then return { { 0, 0, 0, spr } } end
    local anchor = grid:getAnchorSprite()
    local ax, ay = grid:getSpriteGridPosX(anchor), grid:getSpriteGridPosY(anchor)
    local out = {}
    for z = 0, grid:getLevels() - 1 do
        for y = 0, grid:getHeight() - 1 do
            for x = 0, grid:getWidth() - 1 do
                local s = grid:getSprite(x, y, z)
                if s then out[#out + 1] = { x - ax, y - ay, z, s } end
            end
        end
    end
    return out
end

-- 佔格邊的種類放在哪條邊：回 n（北邊）、w（西邊）。牆角（WallNW）兩條都佔，柱子兩條都不佔。
-- 透明牆角與透明門框只有字串鍵、沒有同名旗標（IsoWorld.java:944-977），字串鍵用 has(String) 查。
local F = IsoFlagType
local NORTH = { wall = { F.WallN, F.WallNTrans, F.WallNW, "WallNWTrans" }, windowFrame = { F.WindowN },
    doorFrame = { F.DoorWallN, "DoorWallNTrans" }, fence = { F.HoppableN, F.TallHoppableN }, door = { F.doorN },
    window = { F.windowN }, post = {} }
local WEST = { wall = { F.WallW, F.WallWTrans, F.WallNW, "WallNWTrans" }, windowFrame = { F.WindowW },
    doorFrame = { F.DoorWallW, "DoorWallWTrans" }, fence = { F.HoppableW, F.TallHoppableW }, door = { F.doorW },
    window = { F.windowW }, post = {} }
local function anyFlag(p, list)
    for i = 1, #list do
        if p:has(list[i]) then return true end
    end
    return false
end
function Entry.edges(kind, spr)
    local p = spr:getProperties()
    if not Entry.EDGE[kind] then return false, false end
    return anyFlag(p, NORTH[kind]), anyFlag(p, WEST[kind])
end

-- IsoThumpable／IsoDoor／IsoWindow 建構子的 north：佔北邊的是 true；其他種類照 Facing（N、S 算北）
function Entry.north(kind, spr)
    if Entry.EDGE[kind] then
        local n = Entry.edges(kind, spr)
        return n
    end
    local f = spr:getProperties():get("Facing")
    return f == "N" or f == "S"
end

-- 一格的施工時間（timed action 的 tick，伺服器每 tick 20 ms）。照原版建造：200 − 木工等級 × 5（BuildAction.java:84-99）。
-- 樓梯一個動作蓋整組
local TIME = { floor = 120, wall = 200, windowFrame = 200, doorFrame = 200, fence = 150, door = 150, window = 100,
    stairs = 200, roof = 120, post = 200 }
function Entry.duration(kind, player)
    local level = player and player:getPerkLevel(Perks.Woodwork) or 0
    return math.max(20, (TIME[kind] or 100) - level * 5)
end

return Entry
