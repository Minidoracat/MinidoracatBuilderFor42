-- 項目：客戶端送來的「項目 ID＋朝向」→ 這次要放的 sprite、種類、佔地。兩端共用：客戶端預覽，伺服器重算後才算數。
-- 項目 ID＝sprite 名稱，多格項目用該面 grid 的原點（bt-catalog §8.1）。伺服器不建目錄，收到請求才重算這一項（§8.2）。
require "MinidoracatBuilder/Rules"
require "MinidoracatBuilder/Sources"

MinidoracatBuilder = MinidoracatBuilder or {}
local Entry = MinidoracatBuilder.Entry or {}
MinidoracatBuilder.Entry = Entry
local Rules, Sources = MinidoracatBuilder.Rules, MinidoracatBuilder.Sources

-- 規則版本：伺服器怎麼判斷種類、成本、可放置有變就加一。客戶端版本不同時請求會被拒（STALE），提示重開視窗。
Entry.VERSION = 25
local NO_TILE_ID = 20000000 -- 非 tiledef sprite 的預設 id（IsoSprite.java:129-130）
local MAX_NAME = 128

-- 能蓋的種類，照建造視窗的頁籤排（沙盒「能蓋的種類」頁與管理面板同一個順序）。車庫門、雙開門歸門（Entry.doorSet）。
-- 水井與手壓水泵、植物、水面（使用者 2026-11-13 選新增）；坡道（1.0.0）；挖地下室（使用者 2026-11-25）
Entry.KINDS = { "floor", "floorOverlay", "water", "wall", "fence", "post", "wallOverlay", "door", "window", "doorFrame",
    "windowFrame", "windowObject", "curtain", "roof", "stairs", "ramp", "dig", "furniture", "container", "solid", "well",
    "light", "wallObject", "attached", "overlay", "plant" }
Entry.BUILDABLE = {}
-- 種類開關（沙盒每種一個勾選框，使用者 2026-10-31 選）：鍵＝Kind＋種類 ID 字首大寫，例 KindFloorOverlay。鍵名上線後不能改
Entry.KIND_KEY = {}
for _, k in ipairs(Entry.KINDS) do
    Entry.BUILDABLE[k] = true
    Entry.KIND_KEY[k] = "Kind" .. k:sub(1, 1):upper() .. k:sub(2)
end

-- 樓梯頂端平台的地板（原版 buildRecipeCode.lua:258-261）
Entry.STAIR_FLOOR = "carpentry_02_57"

-- 挖地下室的三個項目 ID（使用者 2026-11-25 先照建議用原版引擎內部圖名；蓋出來的不是這張圖，佔地見 Entry.cells）。
-- 項目 ID 只在這裡定義，別處一律用這三個常數：入口（樓梯往南下、往東下，互為配對面）、挖這一格
Entry.DIG_S, Entry.DIG_E, Entry.DIG_CELL = "underground_01_0", "underground_01_1", "invisible_01_0"
Rules.DIG[Entry.DIG_S], Rules.DIG[Entry.DIG_E], Rules.DIG[Entry.DIG_CELL] = true, true, true
-- 入口的木樓梯（頂、中、底片；原版木樓梯建造配方的圖，entity_carpentry_stairs.txt:21,28-30）：往南下是 N 型、往東下是 W 型
local DIG_STAIRS = { [Entry.DIG_S] = { "carpentry_02_98", "carpentry_02_97", "carpentry_02_96" },
    [Entry.DIG_E] = { "carpentry_02_90", "carpentry_02_89", "carpentry_02_88" } }
-- 入口樓梯的片（拆除認種類，Dismantle.kindOf）。這六張是原版木樓梯建造配方的圖（entity_carpentry_stairs.txt），引擎替它們
-- 加 EntityScript（SpriteConfigManager.java:134-140），Rules.classify 回 ENTITY、不列進目錄
local DIG_STAIR_PART = {}
for _, list in pairs(DIG_STAIRS) do
    for _, n in ipairs(list) do DIG_STAIR_PART[n] = true end
end
function Entry.digStair(name) return DIG_STAIR_PART[name] == true end

-- 佔一條格邊的種類：要對齊牆線、檢查那條邊空著。柱子不佔邊（NORTH／WEST 是空的；擋邊的圖 Rules 不列），
-- 走 Place.check 的柱子分支
Entry.EDGE = { wall = true, windowFrame = true, doorFrame = true, fence = true, door = true, window = true, post = true }

-- 沙盒值（SandboxVars.MinidoracatBuilder）；離線測試沒有 SandboxVars 時用空表，各欄位由呼叫端給預設
function Entry.settings()
    return SandboxVars and SandboxVars.MinidoracatBuilder or {}
end

-- 預設關的種類：沙盒沒有這個鍵、或值不是 true 都當關（使用者 2026-11-13 選預設關：水井與手壓水泵蓋一格就有永遠用不完的
-- 乾淨水；水面會改地形、擋路。挖地下室 2026-11-25 先照建議預設關：改地形、新的多人路徑）。中途加入本版、伺服器的沙盒檔
-- 還沒有這個鍵時也是關
Entry.KIND_OFF = { well = true, water = true, dig = true }

-- 沙盒把這個種類開著（沙盒沒有這個鍵時當開著，KIND_OFF 的當關）。管理面板畫開關用這支：顯示的是沙盒值
function Entry.kindSet(kind, s)
    local key = Entry.KIND_KEY[kind]
    if key == nil then return true end
    local v = (s or Entry.settings())[key]
    if Entry.KIND_OFF[kind] then return v == true end
    return v ~= false
end

-- 這個種類能蓋。s＝Entry.settings()，呼叫端已經拿到的就傳。挖地下室另要土牆的圖塊補丁生效（Basement.patched）：
-- 沒生效時兩端都照沙盒關掉處理，走同一條拒絕路徑與訊息
function Entry.kindOn(kind, ...)
    local s = ...
    return Entry.kindSet(kind, s) and (kind ~= "dig" or MinidoracatBuilder.Basement.patched())
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

-- 回 entry＝{ name, spr, kind, tileset, num, mod }，或 nil＋原因碼（UNKNOWN／UNSUPPORTED／DISABLED；挖掘開著、土牆圖塊補丁
-- 沒生效時 DIG_PATCH，Basement.patched：說真正的原因，不說「管理員關掉了」）
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
    -- 坡道只收湊得成整組的頭片（目錄同一條規則，Catalog.scanSprite）
    if kind == "ramp" and not Entry.rampSet(spr) then return nil, "UNKNOWN" end
    local grid = spr:getSpriteGrid()
    if grid and grid:getAnchorSprite() ~= spr then return nil, "UNKNOWN" end -- 多格只收原點
    -- 車庫門、雙開門只收湊得成整組的頭片、第 1 片（目錄同一條規則，Catalog.scanSprite）
    if kind == "door" and Rules.grouped(spr:getProperties()) and not Entry.doorSet(spr) then return nil, "UNKNOWN" end
    if Rules.BAD_GRID[name] then return nil, "UNKNOWN" end -- 格位拼不起來的不列（目錄同一條規則，Catalog.scanSprite）
    local tileset, num = name:match("^(.*)_(%d+)$")
    if not tileset then return nil, "UNKNOWN" end
    local file = Sources.fileOf(id)
    local mod = Sources.isModFile(file) and Sources.map()[file] or nil
    local s = Entry.settings()
    if (mod and disabledSources(s.DisabledSources)[mod]) or disabledTilesets(s.DisabledTilesets)[tileset]
        or not Entry.kindSet(kind, s) then
        return nil, "DISABLED"
    end
    if kind == "dig" and not MinidoracatBuilder.Basement.patched() then return nil, "DIG_PATCH" end
    return { name = name, spr = spr, kind = kind, tileset = tileset, num = tonumber(num), mod = mod }
end

-- 同一個 tileset 編號差 d 的名稱
local function offset(name, d)
    local tileset, num = name:match("^(.*)_(%d+)$")
    return tileset and (tileset .. "_" .. (tonumber(num) + d)) or nil
end

-- 車庫門、雙開門一組各片（關著的圖）和第一片的編號差，照放的順序：車庫門頭、中、尾（引擎照相鄰格的值 1–3 認同一組，
-- IsoDoor.getGarageDoorPrev／Next，IsoDoor.java:3064-3144）；雙開門第 1–4 片（原版 ISDoubleDoor:new 的圖號，ISDoubleDoor.lua）。
-- 開著的圖：車庫門 +8（IsoDoor 建構子，IsoDoor.java:690-700）、雙開門照 DoubleDoorNorth／WestSpriteOffset（:139-140）。
-- 離線量原版 tiledef（2026-11-16）：車庫門 14 組、雙開門 7 組，南北兩向各一套，全部照這張表排
local GARAGE_OFF, GARAGE_OPEN = { 0, 1, 2 }, { 8, 8, 8 }
local DOUBLE_N, DOUBLE_N_OPEN = { 0, 1, 8, 9 }, { 5, 3, 4, 4 }
local DOUBLE_W, DOUBLE_W_OPEN = { 0, 1, -8, -7 }, { 4, 4, 5, 3 }
local function doorGroup(spr)
    local p = spr:getProperties()
    local key = (p:has("GarageDoor") and "GarageDoor") or (p:has("DoubleDoor") and "DoubleDoor") or nil
    if not key or tonumber(p:get(key)) ~= 1 then return nil end
    local north = p:has(IsoFlagType.doorN)
    if north == p:has(IsoFlagType.doorW) then return nil end
    local garage = key == "GarageDoor"
    local offs = garage and GARAGE_OFF or north and DOUBLE_N or DOUBLE_W
    local opens = garage and GARAGE_OPEN or north and DOUBLE_N_OPEN or DOUBLE_W_OPEN
    local name, parts, members, closed = spr:getName(), {}, {}, {}
    Rules.ensure()
    for i, d in ipairs(offs) do
        local part = offset(name, d)
        local s = part and Entry.sprite(part)
        local q = s and s:getProperties()
        if not (q and tonumber(q:get(key)) == i and q:has(IsoFlagType.doorN) == north and q:has(IsoFlagType.doorW) ~= north
            and Rules.classify(s) == "door") then
            return nil
        end
        local open = offset(part, opens[i])
        local o = open and Entry.sprite(open)
        if not (o and tonumber(o:getProperties():get(key)) == i + #offs) then return nil end -- 開著的值：車庫門 4–6、雙開門 5–8
        parts[i] = s
        members[part], members[open] = true, true
        closed[part], closed[open] = s, s
    end
    return { garage = garage, north = north, parts = parts, members = members, closed = closed }
end

-- spr 是車庫門頭片（GarageDoor＝1）或雙開門第 1 片（DoubleDoor＝1），而且整組各片與各片開著的圖都在、值與方向都對時回
-- { garage = 是不是車庫門, north, parts = { 關著的各片 }, members = { [各片關著、開著的圖名] = true },
-- closed = { [各片關著、開著的圖名] = 那一片關著的圖 } }，否則 nil。
-- 圖塊表一個 session 不變，照名稱快取
local doorSets = {}
function Entry.doorSet(spr)
    local name = spr:getName()
    local c = doorSets[name]
    if c == nil then
        c = doorGroup(spr) or false
        doorSets[name] = c
    end
    return c or nil
end

-- 一組放成一排的佔地（同 Entry.cells 的格式）：車庫門 w 格（頭、中段重複、尾）；雙開門 4 格（w 不看）。往哪排照引擎：
-- 北向沿 +x；西向沿 −y（車庫門 getGarageDoorNext、雙開門 DoubleDoorWestClosedYOffset，IsoDoor.java:3105-3144,145-148）
function Entry.groupCells(set, w)
    local dx, dy = set.north and 1 or 0, set.north and 0 or -1
    local n = set.garage and w or 4
    local out = {}
    for i = 1, n do
        local k = i
        if set.garage then k = (i == 1 and 1) or (i == n and 3) or 2 end
        out[i] = { dx * (i - 1), dy * (i - 1), 0, set.parts[k] }
    end
    return out
end

-- 車庫門、雙開門的其他片（含開著的）所屬那一組的第一片名稱；找不到 nil。其他片的編號在第一片 −8..+13 以內（雙開門西向
-- 第 3 片關著是 −8、北向第 4 片開著是 +13）
local function doorFirst(name)
    for d = -16, 16 do
        local a = d ~= 0 and offset(name, d)
        local s = a and Entry.sprite(a)
        local set = s and Rules.grouped(s:getProperties()) and Entry.doorSet(s)
        if set and set.members[name] then return a end
    end
    return nil
end

-- 車庫門、雙開門任一片的圖名（關著、開著都可）→ 那一組的項目 ID（第一片關著的圖名）；不成組回 nil
function Entry.doorItem(name)
    local s = Entry.sprite(name)
    if s and Rules.grouped(s:getProperties()) and Entry.doorSet(s) then return name end
    return doorFirst(name)
end

-- 車庫門、雙開門任一片的圖名（關著、開著都可）→ 那一片關著的圖名（同一組、同一個位置的片才相同）；不成組回 nil
function Entry.doorPart(name)
    local head = Entry.doorItem(name)
    local s = head and Entry.sprite(head)
    local set = s and Entry.doorSet(s)
    local c = set and set.closed[name]
    return c and c:getName() or nil
end

-- 原版兩張一組、交替排的柵欄與圍牆，北向、西向各一對 { A, B }：BrokenFences.lua 註解寫「2-tile」的五族（8–11、32–35、64–67；
-- BentFences.lua 的 stage 也照 ABAB 排），加上原版地圖上交替排的 8 對（48–51 帶刺高圍欄、80–83、88–91、112–115；
-- 使用者 2026-11-12 選，離線掃 Muldraugh 相鄰兩件 97% 以上交替）。圖塊包的柵欄不猜。鐵絲網兩族（24/25、26/27、56/57、
-- 58/59）不換：每對有一張（fencing_01_25/26/57/58）是原版建造配方的圖（Rules 回 ENTITY），使用者 2026-10-31 定配方的圖
-- 只收地板與地面覆蓋
local ALTERNATE = {}
for _, n in ipairs({ 8, 10, 32, 34, 64, 66, 48, 50, 80, 82, 88, 90, 112, 114 }) do
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
    -- 另一張也要自己能蓋（同 Entry.face）：別的 MOD 用 addLuaSprites 排除、或配方佔走它時照 resolve 擋（審查 1107 Codex）。
    -- 48–51、88–91 帶牆的屬性，目錄歸在牆；兩張要同一個種類（Check.item 換圖後照原本那張的種類蓋，審查 1112 Claude）
    local other, mine = Entry.resolve(alt:getName()), Entry.resolve(spr:getName())
    return other and mine and other.kind == mine.kind and (other.kind == "fence" or other.kind == "wall") and alt or spr
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
--   code＝原因碼（IGUI_MBLD_Why_<碼>；nil＝能蓋）：UNKNOWN 沒有這張圖、Rules.kindOf 的碼、UNSUPPORTED 不能蓋的種類、
--     PART 多格的其他格（車庫門、雙開門、坡道的其他片也是）、STAIRS_SET 湊不成三格的樓梯片、DOOR_SET 湊不成整組的車庫門、
--     雙開門、RAMP_SET 湊不成整組的坡道片、DISABLED_KIND／DISABLED_SOURCE／DISABLED_TILESET 管理員關掉的、
--     DIG_PATCH 土牆圖塊補丁沒生效
--   arg＝說明裡的名稱：建造配方（EntityScriptName）、種類 ID、MOD ID 或 tileset
--   alt＝同一件東西能蓋的那一張（開著的門、窗的狀態圖、拉上的窗簾、疊放圖、多格的原點、樓梯的底片、車庫門頭片與雙開門
--     第 1 片、坡道的頭片），能蓋才給。
--     那張也不能蓋時改給它能蓋的那張，不然 code／arg 改說它的原因（只往下查一層；nested 是內部用的）
function Entry.why(name, ...)
    local nested = ...
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
    elseif res == "DIG_PATCH" then
        code = "DIG_PATCH"
    elseif res == "DISABLED" then -- resolve 最後才查開關：走到這裡的種類、樓梯組、原點都沒問題
        local s = Entry.settings()
        local tileset = name:match("^(.*)_%d+$")
        if not Entry.kindSet(kind, s) then
            code, arg = "DISABLED_KIND", kind
        elseif disabledTilesets(s.DisabledTilesets)[tileset] then
            code, arg = "DISABLED_TILESET", tileset
        else
            code, arg = "DISABLED_SOURCE", Sources.map()[Sources.fileOf(spr:getID())]
        end
    elseif res == "UNSUPPORTED" then
        code = "UNSUPPORTED"
    elseif kind == "door" and Rules.grouped(p) then
        alt = doorFirst(name)
        code = alt and "PART" or "DOOR_SET"
    elseif kind == "stairs" then
        code, alt = "STAIRS_SET", stairsBottom(name)
    elseif kind == "ramp" then
        alt = Entry.rampHead(name)
        if alt == name then alt = nil end -- 頭片自己湊得成整組卻解析不了：只剩管理員關掉，上面已經處理
        code = alt and "PART" or "RAMP_SET"
    elseif kind then
        local grid = spr:getSpriteGrid()
        local anchor = grid and grid:getAnchorSprite()
        if anchor and anchor ~= spr then
            code, alt = "PART", anchor:getName()
        elseif Rules.BAD_GRID[name] then
            code = "BAD_GRID"
        end
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

-- 配對面（d＝5，矩形建造沿四邊圍一圈用）：原版北牆、西牆是不同項目（目錄不併）。只對佔一條格邊的種類（門、窗另見 doorOpposite），
-- 項目只佔北或西其中一條時，在同一個 tileset 找只佔另一條、同種類的圖，照順序：
--   1. 編號 xor 1（原版牆多是偶數西、奇數北）；2. xor 1 和自己同一條邊時是兩張一組（4W 5W 6N 7N），改看 ±2；
--   3. 編號 ±1、±2、±3（先 + 後 −）第一張。都沒有回 nil。
-- 離線量過原版 4,045 張單邊非門窗的格邊圖：1. 956、2. 726、3. 811、找不到 1,552（2026-11-01）。
-- 圖塊表在一個 session 裡不變，照項目名稱快取（false＝找不到）
-- 樓梯（2026-11-14 群聊：「寫了朝西就只能朝西」）：引擎只有往北、往西兩種。同一個 tileset 裡湊得成組的底片照編號排，
-- 第 i 組往西的配第 i 組往北的；兩邊組數不同就不配。原版都對得上（fixtures_stairs_01：西 0、3、16、19、32、48、64，
-- 北 8、11、24、27、40、56、72；crafted_02：北 96、西 106）。「找編號最近、方向不同的」會把 3 配到 8、48 配到 56
-- （E2E builder-fb1114-new2）。一個 tileset 掃一次（編號有空號，掃到 STAIR_SCAN）
local STAIR_SCAN = 1023
local stairPairs = {}
local function stairsOpposite(entry)
    local t = stairPairs[entry.tileset]
    if not t then
        t = {}
        stairPairs[entry.tileset] = t
        local named, lists = IsoSpriteManager.instance:getNamedMap(), { W = {}, N = {} }
        for i = 0, STAIR_SCAN do
            local name = entry.tileset .. "_" .. i
            local set = named:containsKey(name) and Rules.stairsSet(named, name)
            if set then
                local l = lists[set.dir]
                l[#l + 1] = name
            end
        end
        if #lists.W == #lists.N then
            for i = 1, #lists.W do
                t[lists.W[i]], t[lists.N[i]] = lists.N[i], lists.W[i]
            end
        end
    end
    return t[entry.name] and Entry.sprite(t[entry.name]) or nil
end
-- 門、窗的配對面（使用者 2026-11-14：有可靠規律的才配，沒有就不配）。
--   車庫門頭片、雙開門第 1 片：編號 ±3（車庫門）、±6（雙開門）那張也湊得成同一種整組、方向相反。
--   單扇門、窗：編號 xor 1、方向相反；xor 1 和自己同方向時，對齊的四張是兩兩一組（WWNN）改看 ±2。兩張要互配（對方照同一條找回
--     自己）、GroupName＋CustomName 相同。
-- 離線量原版 tiledef（2026-11-16）：車庫門、雙開門 28 組第一片全部配上；單扇門 129 張配上 128；窗 276 張配上 238（名稱不同
-- 2 張、不互配 8 張、找不到 28 張，這些不配）
local function doorEdge(tileset, kind, num) -- 這個編號是同種類、單一格邊的門或窗時回 sprite, 是否佔北邊
    local spr = num >= 0 and Entry.sprite(tileset .. "_" .. num)
    if not spr or Rules.classify(spr) ~= kind or Rules.grouped(spr:getProperties()) then return nil, nil end
    local n, w = Entry.edges(kind, spr)
    if n == w then return nil, nil end
    return spr, n
end
local function doorPartner(tileset, kind, num)
    local _, north = doorEdge(tileset, kind, num)
    if north == nil then return nil, nil end
    local x = num % 2 == 0 and num + 1 or num - 1
    local spr, n2 = doorEdge(tileset, kind, x)
    if spr and n2 == north then
        x = num % 4 < 2 and num + 2 or num - 2
        spr, n2 = doorEdge(tileset, kind, x)
    end
    if spr and n2 ~= north then return x, spr end
    return nil, nil
end
local function doorOpposite(entry)
    local set = entry.kind == "door" and Rules.grouped(entry.spr:getProperties()) and Entry.doorSet(entry.spr)
    if set then
        local step = set.garage and 3 or 6
        for _, d in ipairs({ step, -step }) do
            local s = entry.num + d >= 0 and Entry.sprite(entry.tileset .. "_" .. (entry.num + d))
            local o = s and Rules.grouped(s:getProperties()) and Entry.doorSet(s)
            if o and o.garage == set.garage and o.north ~= set.north then return s end
        end
        return nil
    end
    local x, spr = doorPartner(entry.tileset, entry.kind, entry.num)
    if not spr or doorPartner(entry.tileset, entry.kind, x) ~= entry.num then return nil end
    local a, b = entry.spr:getProperties(), spr:getProperties()
    if a:get("GroupName") ~= b:get("GroupName") or a:get("CustomName") ~= b:get("CustomName") then return nil end
    return spr
end
local pairCache = {}
local function opposite(entry)
    local kind = entry.kind
    if kind == "stairs" then return stairsOpposite(entry) end
    if kind == "dig" then -- 兩個入口互為配對面；挖這一格沒有
        local o = entry.name == Entry.DIG_S and Entry.DIG_E or entry.name == Entry.DIG_E and Entry.DIG_S
        return o and Entry.sprite(o) or nil
    end
    if kind == "door" or kind == "window" then return doorOpposite(entry) end
    if not Entry.EDGE[kind] then return nil end
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
    overlay = true, plant = true }
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

-- ---------------------------------------------------------------- 坡道
-- 一組＝同一個 tileset 連號的 n 片：頭片沒有 SlopedSurfaceHeightMin（引擎當 0），後一片的 Min＝前一片的 Max、方向相同，
-- 最後一片的 Max＝100（原版 ramps_01：北 0–19、南 24–43、西 48–67、東 72–91，每片升 5，離線 dump 全部 .tiles）。
-- 片 i（0 起）在頭片格＋i×上坡方向；上坡方向就是 SlopedSurfaceDirection（引擎算高度時那一邊是 Max，
-- IsoGridSquare.java:10248-10257）。方向字串引擎用 IsoDirections.fromString（去頭尾空白、轉大寫再 valueOf，
-- PropertyContainer.java:270-271、IsoDirections.java:32-34）讀，這裡同一種寫法，只收 N／E／S／W。
-- 坡頂往前 RAMP_DECK 格、上一層補平台：坡頂沒有接上一層地板只走得到 z＝0.98（見 builder-dev placement.md「坡道」）
Entry.RAMP_DECK = 1
local RAMP_DIR = { N = { 0, -1, 1 }, E = { 1, 0, 2 }, S = { 0, 1, 3 }, W = { -1, 0, 4 } } -- dx, dy, Entry.face 的 d
local function slope(spr)
    local p = spr:getProperties()
    local raw = p:get("SlopedSurfaceDirection")
    if raw == nil then return nil end
    local dir = tostring(raw):match("^%s*(.-)%s*$"):upper()
    if not RAMP_DIR[dir] then return nil end
    return dir, tonumber(p:get("SlopedSurfaceHeightMin")) or 0, tonumber(p:get("SlopedSurfaceHeightMax")) or 0
end

-- 圖塊組裡平台用的圖：第一張沒有斜面屬性的地板（原版 ramps_01_23）。這個 tileset 沒有坡道片回 nil，有坡道片卻沒有平片回 false。
-- 圖塊表一個 session 不變，照 tileset 快取（掃到 STAIR_SCAN）
local rampDecks = {}
local function deckOf(tileset)
    local c = rampDecks[tileset]
    if c == nil then
        local named, any, deck = IsoSpriteManager.instance:getNamedMap(), false, false
        Rules.ensure()
        for i = 0, STAIR_SCAN do
            local name = tileset .. "_" .. i
            if named:containsKey(name) then
                local s = named:get(name)
                local p = s:getProperties()
                if p:has("SlopedSurfaceDirection") then
                    any = true
                elseif not deck and p:has(IsoFlagType.solidfloor) and Rules.classify(s) == "floor" then
                    deck = name
                end
            end
        end
        c = any and { deck } or { nil }
        rampDecks[tileset] = c
    end
    return c[1]
end

-- name 是某一組坡道的平台圖（Ledger 清平台的帳本用；Entry.STAIR_FLOOR 另外認）
function Entry.isRampDeck(name)
    local tileset = type(name) == "string" and name:match("^(.*)_%d+$")
    return tileset ~= nil and deckOf(tileset) == name
end

-- 坡道最上面那片（Max＝100）回上坡方向 dx, dy，否則 nil：它往前一格、上一層就是平台（Place 的 rampOk、Dismantle 找平台）
function Entry.rampTop(spr)
    local dir, _, max = slope(spr)
    if not dir or max ~= 100 then return nil end
    return RAMP_DIR[dir][1], RAMP_DIR[dir][2]
end

-- 能搬或能拆解（IsMoveAble、CanScrap）的片不成組：原版會逐片拆、照圖塊材質退料，整組只收一次料（同樓梯的 STAIRS_PART）
local function scrappable(s)
    local p = s:getProperties()
    return p:has("CanScrap") or p:has("IsMoveAble")
end

local function rampChain(spr)
    local dir, min, max = slope(spr)
    if not dir or min ~= 0 or max <= 0 or scrappable(spr) then return nil end
    local name = spr:getName()
    local tileset, num = name:match("^(.*)_(%d+)$")
    if not tileset then return nil end
    num = tonumber(num)
    Rules.ensure()
    local parts = { spr }
    while max < 100 do
        local s = Entry.sprite(tileset .. "_" .. (num + #parts))
        if not s or #parts >= 100 then return nil end
        local d2, lo, hi = slope(s)
        if d2 ~= dir or lo ~= max or hi <= lo or Rules.classify(s) ~= "ramp" or scrappable(s) then return nil end
        parts[#parts + 1] = s
        max = hi
    end
    if max ~= 100 then return nil end
    local m = RAMP_DIR[dir]
    return { dir = dir, dx = m[1], dy = m[2], d = m[3], n = #parts, parts = parts,
        deck = deckOf(tileset) or Entry.STAIR_FLOOR }
end

-- spr 是湊得成整組的頭片時回 { dir（"N" 等）, dx, dy（上坡方向）, d（Entry.face 的 1..4）, n, parts＝{ 各片 sprite },
-- deck＝平台的圖名（同組的平片；沒有就 Entry.STAIR_FLOOR，外觀是推測，ramp-sp 截圖確認） }，否則 nil。照名稱快取
local rampSets = {}
function Entry.rampSet(spr)
    local name = spr and spr:getName()
    if not name then return nil end
    local c = rampSets[name]
    if c == nil then
        c = rampChain(spr) or false
        rampSets[name] = c
    end
    return c or nil
end

-- 坡道任一片的圖名 → 那一組的頭片名（往前連號找，頭片回自己）；不在湊得成整組的一組裡回 nil。照名稱快取
local rampHeads = {}
function Entry.rampHead(name)
    local c = rampHeads[name]
    if c ~= nil then return c or nil end
    c = false
    local spr = Entry.sprite(name)
    local tileset, num
    if type(name) == "string" then tileset, num = name:match("^(.*)_(%d+)$") end
    local dir, lo
    if spr then dir, lo = slope(spr) end
    if dir and tileset then
        num = tonumber(num)
        local cur = num
        while lo ~= 0 and num - cur < 100 do
            local s = Entry.sprite(tileset .. "_" .. (cur - 1))
            if not s then break end
            local d2, lo2, hi2 = slope(s)
            if d2 ~= dir or hi2 ~= lo then break end
            cur, lo = cur - 1, lo2
        end
        local head = lo == 0 and tileset .. "_" .. cur
        local set = head and Entry.rampSet(Entry.sprite(head))
        if set and set.parts[num - cur + 1] == spr then c = head end
    end
    rampHeads[name] = c
    return c or nil
end

-- 同一個 tileset 各方向的頭片（照編號排），第 k 組朝北的配第 k 組朝東…：一個 tileset 有好幾款時同一款轉向。照 tileset 快取
local rampFaces = {}
local function rampFace(entry, dir)
    local t = rampFaces[entry.tileset]
    if not t then
        t = { N = {}, E = {}, S = {}, W = {} }
        local named = IsoSpriteManager.instance:getNamedMap()
        for i = 0, STAIR_SCAN do
            local name = entry.tileset .. "_" .. i
            local set = named:containsKey(name) and Entry.rampSet(named:get(name))
            if set then
                local l = t[set.dir]
                l[#l + 1] = name
            end
        end
        rampFaces[entry.tileset] = t
    end
    local set = Entry.rampSet(entry.spr)
    local mine = set and t[set.dir]
    for k = 1, mine and #mine or 0 do
        if mine[k] == entry.name then
            local other = t[dir][k]
            return other and Entry.sprite(other) or nil
        end
    end
    return nil
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
        if entry.kind == "ramp" then
            spr = rampFace(entry, dir)
        elseif off then
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
-- 車庫門頭片照最短的 2 格（Entry.groupCells；拖一排的寬度由 Check.item 照請求另算），雙開門 4 格。
-- 坡道（項目＝頭片）：原點是頭片，沿上坡方向一片一格，最後是坡頂往前、上一層的平台（角色 platform，Entry.RAMP_DECK 格）。
-- 挖地下室：挖這一格＝自己一格（角色 dig）。入口的原點＝頂片正上方（z＝0），d＝下樓方向（往南 0,1、往東 1,0）：
-- 地下一層沿 d 排頂、中、底片（top／mid／bottom），原點往 −d 一格是落腳處（platform，已有地板），樓梯正上方三格開洞
-- （hole），樓梯底再往前兩格、左右各一格挖成 2×3 的室（dig）。樓梯三格也算挖好的，所以新開的入口記 9 格
local STAIR_ROLES = { "top", "mid", "bottom" }
function Entry.cells(spr)
    local name = spr:getName()
    if Rules.DIG[name] then
        local named = IsoSpriteManager.instance:getNamedMap()
        local dirt = named:get(MinidoracatBuilder.Place.DIRT) or spr
        local stairs = DIG_STAIRS[name]
        if not stairs then return { { 0, 0, 0, dirt, "dig" } } end
        local dx, dy = 0, 1
        if name == Entry.DIG_E then dx, dy = 1, 0 end
        local px, py = dy, dx
        local hole = named:get(Entry.DIG_CELL) or spr
        local out = {}
        for i = 0, 2 do out[i + 1] = { i * dx, i * dy, -1, named:get(stairs[i + 1]) or spr, STAIR_ROLES[i + 1] } end
        out[4] = { -dx, -dy, 0, named:get(Entry.STAIR_FLOOR) or spr, "platform" }
        for i = 0, 2 do out[#out + 1] = { i * dx, i * dy, 0, hole, "hole" } end
        for a = 3, 4 do
            for b = -1, 1 do out[#out + 1] = { a * dx + b * px, a * dy + b * py, -1, dirt, "dig" } end
        end
        return out
    end
    if Rules.grouped(spr:getProperties()) then
        local set = Entry.doorSet(spr)
        if set then return Entry.groupCells(set, 2) end
    end
    local ramp = Entry.rampSet(spr)
    if ramp then
        local out = {}
        for i = 1, ramp.n do out[i] = { (i - 1) * ramp.dx, (i - 1) * ramp.dy, 0, ramp.parts[i] } end
        local deck = Entry.sprite(ramp.deck) or spr
        for k = 0, Entry.RAMP_DECK - 1 do
            out[#out + 1] = { (ramp.n + k) * ramp.dx, (ramp.n + k) * ramp.dy, 1, deck, "platform" }
        end
        return out
    end
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
-- 樓梯一個動作蓋整組；坡道一組 20 片，一個動作的時間照樓梯的兩倍。挖地下室不看技能：挖一格 5 秒、入口 30 秒
-- （第三個參數＝項目 ID，只有 dig 要傳；用 ... 接，其他種類的呼叫端不必補 nil）
local TIME = { floor = 120, wall = 200, windowFrame = 200, doorFrame = 200, fence = 150, door = 150, window = 100,
    stairs = 200, ramp = 400, roof = 120, post = 200 }
function Entry.duration(kind, player, ...)
    local name = ...
    if kind == "dig" then return name and DIG_STAIRS[name] and 1500 or 250 end
    local level = player and player:getPerkLevel(Perks.Woodwork) or 0
    return math.max(20, (TIME[kind] or 100) - level * 5)
end

return Entry
