-- 項目：客戶端送來的「項目 ID＋朝向」→ 這次要放的 sprite、種類、佔地。兩端共用：客戶端預覽，伺服器重算後才算數。
-- 項目 ID＝sprite 名稱，多格項目用該面 grid 的原點（bt-catalog §8.1）。伺服器不建目錄，收到請求才重算這一項（§8.2）。
require "MinidoracatBuilder/Rules"
require "MinidoracatBuilder/Sources"

MinidoracatBuilder = MinidoracatBuilder or {}
local Entry = MinidoracatBuilder.Entry or {}
MinidoracatBuilder.Entry = Entry
local Rules, Sources = MinidoracatBuilder.Rules, MinidoracatBuilder.Sources

-- 規則版本：伺服器怎麼判斷種類、成本、可放置有變就加一。客戶端版本不同時請求會被拒（STALE），提示重開視窗。
Entry.VERSION = 6
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

-- 樓梯頂端平台的地板（原版 buildRecipeCode.lua:252-255）
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
        s.DisabledSources or "", s.DisabledTilesets or "", table.concat(bits) }, "|")
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

-- 朝向 d：0＝項目本身那一面；1..4＝N、E、S、W。引擎替同組的每個成員寫「其他面的原點 − 自己」的 Noffset 等，
-- 自己那一面不寫（IsoWorld.java:1283-1325），所以自己的 Facing 就是自己。查不到那一面回 nil。
local DIRS = { "N", "E", "S", "W" }
function Entry.face(entry, d)
    if d == 0 then return entry.spr end
    local dir = DIRS[d]
    if not dir then return nil end
    local p = entry.spr:getProperties()
    local off = tonumber(p:get(dir .. "offset"))
    local spr
    if off then
        spr = Entry.sprite(entry.tileset .. "_" .. (entry.num + off))
    elseif p:get("Facing") == dir then
        spr = entry.spr
    end
    if not spr or Rules.classify(spr) ~= entry.kind then return nil end -- 另一面也要是同一種類（排除條件一起重算）
    -- 樓梯的另一面是另一組，也要湊得成三格（Entry.resolve 只驗項目自己那組）
    if entry.kind == "stairs" and spr ~= entry.spr
        and not Rules.stairsSet(IsoSpriteManager.instance:getNamedMap(), spr:getName()) then return nil end
    return spr
end

-- 佔地：{ { dx, dy, dz, sprite[, 角色] }, ... }，相對原點那一格。單格就是自己。
-- 原點＝grid 第一層第一個非空成員（IsoSpriteGrid.java:23-31），不一定在 (0,0)。
-- 樓梯（項目＝底片）：原點是頂片，接著中片、底片，最後是上一層的平台（角色 top／mid／bottom／platform）。
-- 往西爬的（W 型）沿 +x 排、平台在 x−1；往北爬的（N 型）沿 +y 排、平台在 y−1（buildRecipeCode.lua:190-200,257-283）。
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
-- 透明牆角與透明門框只有字串鍵、沒有同名旗標（IsoWorld.java:932-965），字串鍵用 has(String) 查。
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
