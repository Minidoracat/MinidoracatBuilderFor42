--[[
煙霧測試骨架：用假的 PZ 全域載入**真正的** MOD Lua，跑行為情境並斷言結果。

    lua scripts/smoke_harness.lua        （repo 根目錄執行；標準 Lua 5.x 即可）

為什麼需要（兩類 luac -p 抓不到的錯誤，皆為正式服實際事故）：
- 改函式簽章漏改呼叫點：語法完全合法，要等該路徑真的執行才炸
  （實例：hotspotKey 兩參數改三參數，刪除成功後的 log 聚合路徑必崩）
- 邏輯回歸：安全把關（範圍／阻隔／保護規則）被改壞時，「執行到並斷言」是唯一防線

限制（必須誠實面對）：這是標準 Lua，不是遊戲的 Kahlua。
- 標準 Lua 有 next/xpcall，Kahlua 沒有——本 harness **測不出**誤用，
  那由 scripts/verify_mod.py 的靜態掃描負責（發版前兩者都要跑）
- Kahlua 專屬行為（table.sort 遞迴深度、Java instance field 不暴露、rawget 呼叫形式、
  每個 table 都是 LinkedHashMap 的記憶體成本）只能靠反編譯查證與實機測試

寫情境的原則：
- 情境要「執行到會炸的路徑」——刪除後的收尾、跨 tick 的第二輪、聚合輸出，都是重災區
- 安全邊界要有**反面**斷言（範圍外／被阻隔／受保護的對象必須存活），不是只測 happy path
- 新防線寫完先「植入違規證明它會抓」再信任它——測不出來的測試等於沒有測試
]]

-- 家族佈局固定，直接填死最省事；scaffold 時由模板替換佔位符
local MEDIA = "MOD/MinidoracatBuilderFor42/Contents/mods/MinidoracatBuilderFor42/42/media/lua"

-- ===== 假的 PZ 全域（依 MOD 實際用到的 API 增補）=====
-- 時鐘：每次呼叫前進 clockStep 毫秒，用來測分批的時間預算
local nowMs, clockStep = 5000000, 0
function getTimestampMs()
    local t = nowMs
    nowMs = nowMs + clockStep
    return t
end
function isClient() return false end
function isServer() return true end
function getText(key) return key end
function getTextOrNull() return nil end

local handlers = {}
Events = setmetatable({}, {
    __index = function(t, name)
        handlers[name] = handlers[name] or {}
        local ev = {
            Add = function(fn) table.insert(handlers[name], fn) end,
            Remove = function(fn)
                for i, f in ipairs(handlers[name]) do
                    if f == fn then table.remove(handlers[name], i) return end
                end
            end,
        }
        rawset(t, name, ev)
        return ev
    end,
})
local function fire(name, ...)
    local list = {}
    for i, f in ipairs(handlers[name] or {}) do list[i] = f end -- 照遊戲：觸發中移除不影響這一輪
    for _, f in ipairs(list) do f(...) end
end
local function count(name) return #(handlers[name] or {}) end

-- java 風格清單（size()/get(i)，0-based）——PZ 回傳的容器幾乎都是這個形狀
local function javaList(items)
    return {
        size = function() return #items end,
        get = function(_, i) return items[i + 1] end,
        _raw = items,
    }
end

-- 列舉值：每個名稱一張唯一的表（引擎是 Java enum，比較用 ==）
local function enum()
    return setmetatable({}, { __index = function(t, k) local v = { name = k }; rawset(t, k, v); return v end })
end
IsoObjectType, IsoFlagType = enum(), enum()
local T, F = IsoObjectType, IsoFlagType

-- 假 sprite：flags＝IsoFlagType 名稱清單，keys＝字串屬性
local function sprite(name, id, o)
    o = o or {}
    local flags, keys = {}, o.keys or {}
    for _, f in ipairs(o.flags or {}) do flags[f] = true end
    local props = {
        has = function(_, k)
            if type(k) == "table" then return flags[k.name] == true end
            return keys[k] ~= nil
        end,
        get = function(_, k) return keys[k] end,
    }
    local s = { name = name, id = id }
    function s:getName() return name end
    function s:getID() return id end
    function s:getType() return o.type or T.normal end
    function s:hasNoTextures() return o.noTex == true end
    function s:getSpriteGrid() return self.grid end
    function s:getProperties()
        if o.boom then error("boom") end
        return props
    end
    return s
end

local spriteMap, spriteOrder = {}, {}
local function world(list)
    spriteMap, spriteOrder = {}, {}
    for _, s in ipairs(list) do
        spriteMap[s.name] = s
        spriteOrder[#spriteOrder + 1] = s
    end
end
IsoSpriteManager = { instance = { getNamedMap = function()
    return {
        get = function(_, k) return spriteMap[k] end,
        containsKey = function(_, k) return spriteMap[k] ~= nil end,
        values = function() return javaList(spriteOrder) end,
    }
end } }
ArrayList = { new = function(list) return list end }

-- 假 MOD 清單與 mod.info
local modInfos = {}
function getActivatedMods()
    local ids = {}
    for _, m in ipairs(modInfos) do ids[#ids + 1] = m.id end
    return javaList(ids)
end
local readerOpened = {}
function getModInfoByID(id)
    for _, m in ipairs(modInfos) do
        if m.id == id then
            return {
                getName = function() return m.name end,
                getTileDefs = function() return javaList(m.tiledefs and { 1 } or {}) end,
            }
        end
    end
end
function getModFileReader(id, file)
    readerOpened[id] = true
    for _, m in ipairs(modInfos) do
        if m.id == id and file == "mod.info" then
            local i = 0
            return {
                readLine = function() i = i + 1; return m.lines[i] end,
                close = function() end,
            }
        end
    end
end
Translator = { getMoveableDisplayNameOrNull = function(raw)
    if raw == "Furniture Red Chair" then return "Red Chair CH" end
    return nil
end }

-- 第二階段（建造請求）用到的全域
Perks = { Woodwork = "Woodwork" }
GridSquareEdgeFacingDirection = { NORTH_SOUTH = { name = "NS" }, EAST_WEST = { name = "EW" } }
SandboxVars = { MinidoracatBuilder = {} }
function getWorld() return { isValidSquare = function(_, x, y, z) return z >= -32 and z <= 31 end } end
-- 格子一律不存在、也建不出來：通過身分檢查的動作會走到 NOT_LOADED 並推 refused，和 NO_INTENT（不推）分得開
function getCell() return { getGridSquare = function() return nil end, createNewGridSquare = function() return nil end } end
local regionPokes = 0
IsoRegions = { setPreviousFlags = function() end, squareChanged = function() regionPokes = regionPokes + 1 end }
Capability = { UseBuildCheat = "UseBuildCheat", CanGoInsideSafehouses = "CanGoInsideSafehouses" }
function checkPermissions(player, cap) return player.admin == true end
local sent = {}
function sendServerCommand(player, module, cmd, args) sent[#sent + 1] = { player = player, cmd = cmd, args = args } end
local scrapDefs = {}
ISMoveableDefinitions = { getInstance = function()
    return { getScrapDefinition = function(mat) return scrapDefs[mat] end }
end }
-- 假玩家：onlineID、木工等級、是否管理員、是否死亡
local function player(o)
    o = o or {}
    local p = { admin = o.admin }
    function p:getOnlineID() return o.id or 1 end
    function p:getPlayerNum() return 0 end
    function p:getUsername() return o.name or "tester" end
    function p:isDead() return o.dead == true end
    function p:getVehicle() return nil end
    function p:getPerkLevel() return o.woodwork or 0 end
    function p:isTimedActionInstant() return o.instant == true end
    return p
end

-- ===== 載入受測程式碼 =====
local loaded = {}
function require(name)
    if loaded[name] then return true end
    loaded[name] = true
    for _, dir in ipairs({ "shared", "server", "client" }) do
        local chunk = loadfile(MEDIA .. "/" .. dir .. "/" .. name .. ".lua")
        if chunk then chunk() return true end
    end
    error("require 找不到: " .. name)
end

require "MinidoracatBuilder/Rules"
require "MinidoracatBuilder/Sources"
require "MinidoracatBuilder/Catalog"
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Cost"
require "MinidoracatBuilder/Server"
local Rules, Sources = MinidoracatBuilder.Rules, MinidoracatBuilder.Sources
local Index, Catalog = MinidoracatBuilder.Index, MinidoracatBuilder.Catalog
local Entry, Cost, Server = MinidoracatBuilder.Entry, MinidoracatBuilder.Cost, MinidoracatBuilder.Server

-- ===== 測試工具 =====
local failures = 0
local function check(ok, label)
    if ok then print("  PASS  " .. label)
    else failures = failures + 1; print("  FAIL  " .. label) end
end

local MOD_ID_BASE = 1048576 + (7001 - 2) * 262144 -- tiledef 檔號 7001 的第一格

-- ===== 情境 =====
print("情境一：分類順序（兩個規則同時成立時，誰先）")
local function kind(o, name) return Rules.classify(sprite(name or "test_01_0", 5, o)) end
check(kind({ flags = { "windowW" }, keys = { WindowW = "" } }) == "window", "窗也帶 WindowW：歸窗、不歸窗框")
check(kind({ keys = { WindowW = "" } }) == "windowFrame", "只有 WindowW：窗框")
check(kind({ flags = { "HoppableW" }, keys = { WallWTrans = "" } }) == "fence", "低柵欄帶牆鍵：歸柵欄")
check(kind({ flags = { "doorW" }, keys = { WallW = "", GarageDoor = "" } }) == "garage", "車庫門帶門旗標與牆鍵：歸車庫門")
check(kind({ keys = { container = "", LightRadius = "5", lightR = "1" } }) == "container", "冰箱帶燈：歸容器")
check(kind({ keys = { LightRadius = "5" } }) == nil, "有 LightRadius、沒有 lightR 的不會亮：不列")
check(kind({ type = T.lightswitch }) == "light", "沒有 lightR 的牆面開關：歸燈")
check(kind({ keys = { lightR = "1" }, flags = { "solid" } }) == "solid", "只帶 lightR 的石頭：不算燈")
check(kind({ keys = { RoofGroup = "1" }, flags = { "attachedN" } }) == "roof", "屋簷帶附著旗標：歸屋頂")
check(kind({ type = T.curtainS, keys = { MoveType = "WindowObject", IsMoveAble = "" } }) == "curtain", "窗簾")
check(kind({ type = T.curtainS, keys = { IsMoveAble = "" } }) == "furniture", "窗簾型別但不是窗上物件（床單）：不歸窗簾")
check(kind({ keys = { IsMoveAble = "" } }) == "furniture", "可搬：家具")
check(kind({ flags = { "solidfloor" }, keys = { RoofGroup = "1" } }) == "floor", "平屋頂地板：歸地板")
check(kind({ type = T.stairsBW }) == "stairs", "樓梯型別")
print("情境二：排除（反面斷言）")
check(kind({ flags = { "EntityScript" }, keys = { IsMoveAble = "" } }) == nil, "entity 圖塊不列")
check(kind({ keys = { RoofGroup = "1" } }, "e_roof_snow_01_3") == nil, "e_ 積雪屋頂疊圖不列")
check(kind({ keys = { IsMoveAble = "" } }, "lighting_indoor_01_on_3") == nil, "開燈疊圖 _on_N 不列")
check(kind({ keys = { IsMoveAble = "" } }, "crafted_04_120") == nil, "有載入 Lua 的原版圖塊不列（屠宰鉤）")
check(kind({ keys = { IsMoveAble = "" } }, "constructedobjects_01_8") == nil, "陷阱圖塊不列")
check(kind({ keys = { IsMoveAble = "", fuelAmount = "100" } }) == nil, "加油機不列")
check(kind({ keys = { IsMoveAble = "", IsoType = "IsoRadio" } }) == nil, "專用類別不列")
check(kind({ flags = { "vegitation" }, keys = { IsMoveAble = "" } }) == nil, "植物不列")
check(kind({ keys = { IsMoveAble = "" } }, "eaves_01_0") == "furniture", "e 開頭但不是 e_：照常分類")
check(kind({}) == nil, "沒有任何分類屬性：不列")

print("情境三：樓梯湊組")
world({ sprite("st_01_0", 1, { type = T.stairsBW }), sprite("st_01_1", 2, { type = T.stairsMW }),
    sprite("st_01_2", 3, { type = T.stairsTW }), sprite("st_01_5", 4, { type = T.stairsTN }),
    sprite("st_01_6", 5, { type = T.stairsMN }), sprite("st_01_7", 6, { type = T.stairsBN }),
    sprite("st_01_9", 7, { type = T.stairsBW }), sprite("st_01_10", 8, { type = T.stairsMW }) })
local named = IsoSpriteManager.instance:getNamedMap()
local s1 = Rules.stairsSet(named, "st_01_0")
check(s1 and s1.m == "st_01_1" and s1.t == "st_01_2" and s1.dir == "W", "遞增三格成組")
local s2 = Rules.stairsSet(named, "st_01_7")
check(s2 and s2.m == "st_01_6" and s2.t == "st_01_5" and s2.dir == "N", "遞減三格成組")
check(Rules.stairsSet(named, "st_01_9") == nil, "少一格：不成組")
check(Rules.stairsSet(named, "st_01_1") == nil, "中段不當起點")

print("情境四：來源表（檔號 → MOD）")
check(Sources.fileOf(0) == 1 and Sources.fileOf(1048575) == 1, "id < 1048576 是檔號 1")
check(Sources.fileOf(MOD_ID_BASE) == 7001 and Sources.fileOf(MOD_ID_BASE + 262143) == 7001, "MOD 檔號反算（含檔尾）")
modInfos = {
    { id = "A", name = "Mod A", tiledefs = true, lines = { "name=A", "tiledef=a_tiles 401" } },
    { id = "NoTiles", name = "No Tiles", lines = { "tiledef=x 999" } },
    { id = "B", name = "Mod B", tiledefs = true, lines = { "  tiledef=pinevilletiles 3763  " } },
    { id = "C", name = "Mod C", tiledefs = true, lines = { "tiledef=pinevilletiles 3763", "tiledef=c2 7001" } },
}
readerOpened = {}
local byFile = Sources.build()
check(byFile[401] == "A" and byFile[3763] == "B" and byFile[7001] == "C", "讀 tiledef 行；同檔號先載入的贏")
check(byFile[999] == nil and not readerOpened.NoTiles, "沒有 tiledef 的 MOD 不讀 mod.info")
check(Sources.describe(byFile) == "401=A 3763=B 7001=C", "依檔號排序印出")

print("情境五：目錄整理（過濾、群組、多格、樓梯、搜尋鍵）")
local function grid(anchor) return { getAnchorSprite = function() return anchor end } end
local chairA = sprite("furniture_01_4", 104, { keys = { IsMoveAble = "", GroupName = "Furniture", CustomName = "Red Chair" } })
local chairB = sprite("furniture_01_2", 102, { keys = { IsMoveAble = "", GroupName = "Furniture", CustomName = "Red Chair" } })
local bedA = sprite("beds_01_0", 200, { keys = { IsMoveAble = "", GroupName = "Big", CustomName = "Bed" } })
local bedB = sprite("beds_01_1", 201, { keys = { IsMoveAble = "", GroupName = "Big", CustomName = "Bed" } })
bedA.grid, bedB.grid = grid(bedA), grid(bedA)
local list = {
    sprite("", -1), sprite("ui_icon", 20000000, { keys = { IsMoveAble = "" } }),
    sprite("walls_01_0", 300, { keys = { WallN = "" }, noTex = true }),
    sprite("walls_01_1", 301, { keys = { WallN = "" } }),
    chairA, chairB, bedA, bedB,
    sprite("st_01_0", 1, { type = T.stairsBW }), sprite("st_01_1", 2, { type = T.stairsMW }),
    sprite("st_01_2", 3, { type = T.stairsTW }),
    sprite("tk_01_3", MOD_ID_BASE + 3, { flags = { "solidfloor" } }),
}
for i = 1, 2000 do list[#list + 1] = sprite("filler_01_" .. i, 1000 + i, { flags = { "solidfloor" } }) end
world(list)
modInfos = { { id = "UMCTP", name = "Unofficial Mappers Community Tile Pack", tiledefs = true, lines = { "tiledef=t 7001" } } }
clockStep = 0
Catalog.start()
check(count("OnTickEvenPaused") == 1, "start 只掛一個 tick 事件")
for _ = 1, 50 do fire("OnTickEvenPaused") end
check(Catalog.state == "ready", "整理完成")
check(count("OnTickEvenPaused") == 0, "做完自己摘掉 tick 事件")
local wall, furn, floor = Index.byKind.wall, Index.byKind.furniture, Index.byKind.floor
check(wall and wall.n == 1 and wall[1] == "walls_01_1", "沒有貼圖、id −1、非 tile 都濾掉")
check(furn and furn.n == 2, "兩面椅子算一項、兩格床只收原點")
local hasChairB, hasBedB = false, false
for i = 1, furn.n do
    if furn[i] == "furniture_01_2" then hasChairB = true end
    if furn[i] == "beds_01_1" then hasBedB = true end
end
check(hasChairB, "群組代表取編號最小的那張（furniture_01_2）")
check(not hasBedB, "多格的非原點不列")
check(Index.byKind.stairs and Index.byKind.stairs.n == 1 and Index.byKind.stairs[1] == "st_01_0", "樓梯只收 B 片")
check(floor and floor.n == 2001, "地板 2001 項")
check(Index.items == 2005, "總項目數（牆 1＋家具 2＋樓梯 1＋地板 2001）")
check(Index.nameKey.n == 2, "有名稱的項目建兩個搜尋鍵")
local keyed = {}
for i = 1, Index.nameKey.n do keyed[Index.nameItem[i]] = Index.nameKey[i] end
check(keyed["furniture_01_2"] == "red chair ch|furniture red chair", "名稱鍵＝小寫「翻譯|原名」並指向群組代表")
local setKey
for i = 1, Index.setName.n do if Index.setName[i] == "tk_01" then setKey = Index.setKey[i] end end
check(setKey == "tk 01|tk_01|unofficial mappers community tile pack", "tileset 鍵帶來源 MOD 名")
check(Index.setKey.n == Index.setName.n, "每個 tileset 都有搜尋鍵")
check(Index.groups == nil, "群組暫存表已丟掉")

print("情境六：時間預算、每 tick 上限、時鐘往回調")
local function pass(step)
    Catalog.state = "idle"
    clockStep = step
    Catalog.start()
    fire("OnTickEvenPaused")
    local done = Catalog.progress()
    for _ = 1, 200 do fire("OnTickEvenPaused") end
    return done
end
-- 每次讀時鐘前進 1 ms：step 一次、迴圈開頭一次，每 32 格看一次；第 64 格（第二次檢查）滿 2 ms
check(pass(1) == 64, "2 ms 預算：每 tick 64 格就停")
check(Catalog.state == "ready", "照預算分多個 tick 仍會做完")
local many = {}
for i = 1, 10000 do many[i] = sprite("filler_02_" .. i, 5000 + i, { flags = { "solidfloor" } }) end
world(many)
check(pass(0) == 4096, "時鐘不動：每 tick 最多 4096 格")
world(list)
check(pass(-1) == 32, "時鐘往回調：第一次檢查就停")

print("情境七：出錯就停（不每 tick 重丟）")
world({ sprite("walls_01_1", 301, { boom = true }) })
Catalog.state = "idle"
clockStep = 0
Catalog.start()
fire("OnTickEvenPaused")
check(Catalog.state == "failed", "分類丟錯：狀態 failed")
check(count("OnTickEvenPaused") == 0, "出錯後 tick 事件已摘掉")

print("情境八：項目解析（伺服器重算這一項）")
-- 假 grid：cells[y][x] = sprite；原點＝第一個非空成員（IsoSpriteGrid.getAnchorSprite）
local function fakeGrid(w, h, cells)
    local g = {}
    function g:getWidth() return w end
    function g:getHeight() return h end
    function g:getLevels() return 1 end
    function g:getSprite(x, y, z) return z == 0 and cells[y + 1] and cells[y + 1][x + 1] or nil end
    function g:getAnchorSprite()
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local s = g:getSprite(x, y, 0)
                if s then return s end
            end
        end
    end
    function g:getSpriteGridPosX(s)
        for y = 0, h - 1 do for x = 0, w - 1 do if g:getSprite(x, y, 0) == s then return x end end end
    end
    function g:getSpriteGridPosY(s)
        for y = 0, h - 1 do for x = 0, w - 1 do if g:getSprite(x, y, 0) == s then return y end end end
    end
    for _, row in pairs(cells) do for _, s in pairs(row) do s.grid = g end end
    return g
end
local wallN = sprite("walls_test_01_4", 5000, { flags = { "WallN" }, keys = { WallN = "" } })
local modFloor = sprite("tk_01_9", MOD_ID_BASE + 9, { flags = { "solidfloor" } })
local stairsB = sprite("st_01_0", 1, { type = T.stairsBW })
local tree = sprite("tree_01_0", 2, { type = T.tree })
local chair = {}
for i, f in ipairs({ "E", "N", "S", "W" }) do
    local keys = { IsMoveAble = "", Facing = f, GroupName = "G", CustomName = "Chair" }
    for j, g in ipairs({ "E", "N", "S", "W" }) do
        if g ~= f then keys[g .. "offset"] = tostring(j - i) end -- 引擎替其他面寫的偏移
    end
    chair[i] = sprite("chair_01_" .. (i - 1), 600 + i, { keys = keys })
end
local oddFace = sprite("odd_01_0", 700, { keys = { IsMoveAble = "", Noffset = "1" } })
local oddTree = sprite("odd_01_1", 701, { type = T.tree })
local bedA = sprite("bed_01_1", 801, { keys = { IsMoveAble = "" } })
local bedB = sprite("bed_01_2", 802, { keys = { IsMoveAble = "" } })
local bedC = sprite("bed_01_3", 803, { keys = { IsMoveAble = "" } })
fakeGrid(2, 2, { { nil, bedA }, { bedB, bedC } })
world({ wallN, modFloor, stairsB, tree, chair[1], chair[2], chair[3], chair[4], oddFace, oddTree, bedA, bedB, bedC })
Sources.byFile = { [7001] = "UMCTP" }
local sb = SandboxVars.MinidoracatBuilder
local e1 = Entry.resolve("walls_test_01_4")
check(e1 and e1.kind == "wall" and e1.tileset == "walls_test_01" and e1.num == 4, "牆：種類與 tileset 由伺服器重算")
check(select(2, Entry.resolve("nope_01_0")) == "UNKNOWN", "不存在的圖塊：UNKNOWN（不新增空 sprite）")
check(select(2, Entry.resolve("tree_01_0")) == "UNKNOWN", "排除的圖塊（樹）：UNKNOWN")
check(select(2, Entry.resolve("st_01_0")) == "UNSUPPORTED", "樓梯第四階段才做：UNSUPPORTED")
check(select(2, Entry.resolve("bed_01_2")) == "UNKNOWN", "多格的非原點：UNKNOWN")
check(Entry.resolve("bed_01_1") ~= nil, "多格原點可以")
check(Entry.resolve("tk_01_9").mod == "UMCTP", "MOD 圖塊帶來源")
sb.DisabledSources = " Foo ; UMCTP "
check(select(2, Entry.resolve("tk_01_9")) == "DISABLED", "關掉的來源：DISABLED（分號分隔、去空白）")
sb.DisabledSources = "Foo"
check(Entry.resolve("tk_01_9") ~= nil, "改設定後重切清單")
sb.DisabledTilesets = "walls_test_01"
check(select(2, Entry.resolve("walls_test_01_4")) == "DISABLED", "關掉的 tileset：DISABLED")
sb.DisabledTilesets = ""

print("情境九：朝向與佔地")
local ce = Entry.resolve("chair_01_0")
check(Entry.face(ce, 0) == chair[1], "d=0：項目本身那一面")
check(Entry.face(ce, 1) == chair[2], "d=1（N）：照 Noffset 換到北面")
check(Entry.face(ce, 2) == chair[1], "d=2（E）：自己就是東面（引擎不替自己那面寫偏移）")
check(Entry.face(ce, 4) == chair[4], "d=4（W）")
check(Entry.face(ce, 5) == nil, "朝向超出範圍：nil")
check(Entry.face(Entry.resolve("walls_test_01_4"), 1) == nil, "沒有其他面的圖塊：只有 d=0")
check(Entry.face(Entry.resolve("odd_01_0"), 1) == nil, "偏移指到別的種類（樹）：nil")
local cells = Entry.cells(bedA)
check(#cells == 3 and cells[1][1] == 0 and cells[1][2] == 0, "多格：原點不在 (0,0) 時以原點為準")
check(cells[2][1] == -1 and cells[2][2] == 1 and cells[2][4] == bedB, "多格：其他成員的相對位置")
check(#Entry.cells(wallN) == 1, "單格：只有自己")
local nN, nW = Entry.edges("wall", wallN)
check(nN and not nW and Entry.north("wall", wallN), "北牆佔北邊、north=true")
local corner = sprite("walls_test_01_2", 5002, { flags = { "WallNW" } })
local cN, cW = Entry.edges("wall", corner)
check(cN and cW, "牆角兩條邊都佔")
check(Entry.north("furniture", chair[3]) and not Entry.north("furniture", chair[1]), "家具照 Facing：S 算北、E 不算")

print("情境十：成本")
local function cost(kind, o, mult) return Cost.of(kind, sprite("c_01_0", 900, o), mult) end
local c = cost("wall", { flags = { "WallN" } })
check(c.items["Base.Plank"] == 4 and c.items["Base.Nails"] == 6 and c.tools[1] == "HAMMER", "木牆：框＋牆一級的木板 4、釘子 6、要鐵鎚")
c = cost("wall", { keys = { MaterialType = "Brick" } })
check(c.items["Base.ClayBrick"] == 4 and c.items["Base.Plank"] == nil and c.tools[1] == "MASONS_TROWEL", "磚牆：黏土磚 4、抹刀")
c = cost("wall", { keys = { MaterialType = "Metal_Large" } })
check(c.items["Base.MetalBar"] == 3 and c.items["Base.SmallSheetMetal"] == 3 and #c.tools == 2, "金屬牆：鐵條＋金屬片、噴燈與面罩")
c = cost("floor", { keys = { MaterialType = "Gravel" } })
check(c.items["Base.Gravelbag"] == 1 and #c.tools == 0, "碎石地板：一袋碎石、不用工具")
c = cost("door", { keys = { MaterialType = "Brick" } })
check(c.items["Base.Hinge"] == 2 and c.tools[1] == "HAMMER", "磚造門沒有對應配方：照木門")
scrapDefs.Wood = { returnItemsStatic = { { returnItem = "Base.Plank", maxAmount = 2 } } }
scrapDefs.Electric = { returnItems = { { returnItem = "Base.ElectronicsScrap", maxAmount = 1 },
    { returnItem = "Base.ElectricWire", maxAmount = 3 } } }
scrapDefs.Fabric = { returnItems = {} }
local scrapKeys = { Material = "Wood", Material2 = "Electric", Material3 = "Undefined" }
c = cost("furniture", { keys = scrapKeys })
check(c.items["Base.Plank"] == 2 and c.items["Base.ElectronicsScrap"] == 1 and c.items["Base.ElectricWire"] == 3
    and c.items["Base.Nails"] == nil, "有拆解材質：照拆解產出上限，不用基本價")
scrapKeys.CanScrap, scrapKeys.ScrapSize = "", "Large"
c = cost("furniture", { keys = scrapKeys })
check(c.items["Base.Plank"] == 4 and c.items["Base.ElectricWire"] == 6, "可拆、Large：加倍")
scrapKeys.ScrapSize = "Small"
c = cost("furniture", { keys = scrapKeys })
check(c.items["Base.Plank"] == 1 and c.items["Base.ElectronicsScrap"] == 1 and c.items["Base.ElectricWire"] == 1,
    "可拆、Small：減半、至少 1、1.5 照原版只算 1")
c = cost("furniture", { keys = { Material = "Fabric" } })
check(c.items["Base.Plank"] == 4, "拆解材質沒有產出：照種類基本價")
c = cost("wall", { flags = { "WallN" } }, 0.3)
check(c.items["Base.Plank"] == 2 and c.items["Base.Nails"] == 2, "倍率 0.3：無條件進位（1.2→2、1.8→2）")
c = cost("wall", { flags = { "WallN" } }, 0)
check(next(c.items) == nil and c.tools[1] == "HAMMER", "倍率 0：免材料、工具照樣要")
local s = Cost.sum({ cost("wall", {}), cost("wall", { keys = { MaterialType = "Brick" } }) })
check(s.items["Base.Plank"] == 4 and s.items["Base.ClayBrick"] == 4 and #s.tools == 2, "多格加總：材料相加、工具聯集")

print("情境十一：建造請求（身分、限流、型別、單一待辦）")
clockStep = 0
sb.MaxCellsPerDrag = 2
local P = player({ id = 7 })
local function intent(p, o)
    local args = { n = o.n or 5, e = o.e or "walls_test_01_4", d = o.d or 0, c = o.c or { 10, 20, 0 },
        v = o.v or Entry.digest() }
    sent = {}
    Server.intent(p, args)
    return sent[1] and sent[1].args.code
end
check(intent(P, {}) == nil and Server.intents[7] and Server.intents[7].c[1][2] == 20, "合法請求：存下、不回覆")
check(regionPokes == 0, "那一帶沒有地板格：不喚醒區域系統（只記時間）")
check(intent(P, { v = "r0:1" }) == "STALE", "設定摘要不同：STALE")
check(intent(P, { c = {} }) == "BAD_REQUEST", "沒有座標：BAD_REQUEST")
check(intent(P, { c = { 1, 2, 0, 3, 4, 0, 5, 6, 0 } }) == "BAD_REQUEST", "超過每次上限：BAD_REQUEST")
check(intent(P, { c = { 1.5, 2, 0 } }) == "BAD_REQUEST", "座標不是整數：BAD_REQUEST")
check(intent(P, { c = { 1, 2, 40 } }) == "BAD_REQUEST", "樓層超出範圍：BAD_REQUEST")
check(intent(P, { e = "tree_01_0" }) == "UNKNOWN", "排除的項目：UNKNOWN")
check(intent(P, { d = 1 }) == "BAD_FACE", "不存在的朝向：BAD_FACE")
check(intent(P, { n = 6 }) == nil and Server.intents[7].n == 6, "新請求取代舊的（每人只留一個）")
-- NO_INTENT 不推任何訊息；通過身分檢查的會一路走到 NOT_LOADED 並推 refused
local function noIntent(p, n, i)
    sent = {}
    return Server.complete(p, n, i) == false and #sent == 0
end
check(noIntent(P, 5, 1), "舊 nonce 的動作：拒絕、不推給 character")
check(noIntent(player({ id = 7 }), 6, 1), "同一個 onlineID、不同玩家物件（重連或偽造）：拒絕")
check(noIntent(P, 6, 2), "請求裡沒有第 2 項：拒絕")
local A = player({ id = 8 })
intent(A, { n = 100 })
check(noIntent(P, 100, 1), "character 被改成別人：那人的請求裡沒有這個 nonce，拒絕")
sent = {}
check(Server.complete(P, 6, 1) == false and sent[1] and sent[1].args.code == "NOT_LOADED",
    "身分對了才往下驗（這裡格子建不出來：NOT_LOADED）")
check(Server.duration(P, 6, 1) == 200, "施工時間：木工 0 的牆 200 tick（剛喚醒的 3 秒＝150 tick 以內）")
check(Server.duration(player({ id = 7, instant = true }), 6, 1) == 1, "別的玩家物件問不到請求：1 tick 後被拒")
check(Server.duration(P, 99, 1) == 1, "找不到請求：1 tick")
sb.WhoCanUse = 2
check(intent(P, { n = 7 }) == "NOT_ALLOWED", "只限管理員：一般玩家 NOT_ALLOWED")
check(intent(player({ id = 9, admin = true }), { n = 7 }) == nil, "只限管理員：管理員可以")
sb.WhoCanUse, sb.Enabled = 1, false
check(intent(P, { n = 8 }) == "OFF", "總開關關掉：OFF")
sb.Enabled = nil
check(intent(player({ id = 10, dead = true }), {}) == "STATE", "死掉的玩家：STATE")
local R = player({ id = 11 })
local refusedCount = 0
for k = 1, 25 do
    if intent(R, { n = 1000 + k, v = "bad" }) then refusedCount = refusedCount + 1 end
end
check(refusedCount == 20, "限流：5 秒內第 21 個起不處理、不回覆")

print()
if failures > 0 then
    print(failures .. " 項失敗")
    os.exit(1)
end
print("全部通過")
