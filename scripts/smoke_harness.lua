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
Perks = { Woodwork = "Woodwork", FromString = function(s) return "perk:" .. s end }
local xpLog = {} -- addXp 的呼叫：{ p, perk, n }
function addXp(p, perk, n) xpLog[#xpLog + 1] = { p = p, perk = perk, n = n } end
GridSquareEdgeFacingDirection = { NORTH_SOUTH = { name = "NS" }, EAST_WEST = { name = "EW" } }
SandboxVars = { MinidoracatBuilder = {} }
function getWorld() return { isValidSquare = function(_, x, y, z) return z >= -32 and z <= 31 end } end
-- 假格子：squares 裡有的才存在；(40..60, 40..60, 0) 是空地，第一次查時自動建一格（BFS 找路要鄰格），holes 除外。
-- createNewGridSquare 一律建不出來但記次數（驗「先驗距離才補格子」）。
-- 沒有的格子：通過身分檢查的動作會走到 NOT_LOADED 並推 refused，和 NO_INTENT（不推）分得開
local squares, holes, created, failAdd = {}, {}, 0, false
local square
function getCell()
    return {
        getGridSquare = function(_, x, y, z)
            local k = x .. "," .. y .. "," .. z
            if squares[k] then return squares[k] end
            if z == 0 and x >= 40 and x <= 60 and y >= 40 and y <= 60 and not holes[k] then return square(x, y, z) end
            return nil
        end,
        createNewGridSquare = function() created = created + 1 return nil end,
        checkHaveRoof = function() end,
    }
end
DesignationZoneAnimal = { addNewRoof = function() end }
-- o.flags＝格子上的旗標／字串鍵（名稱 → true）；o.owner＝安全屋主人；o.moving＝格上的人；o.floor；o.noReach＝走不到
square = function(x, y, z, o)
    o = o or {}
    local sq = { objects = {}, world = {}, moving = o.moving or {}, owner = o.owner, noReach = o.noReach }
    local flags = o.flags or {}
    function sq:getX() return x end
    function sq:getY() return y end
    function sq:getZ() return z end
    function sq:EnsureSurroundNotNull() end
    function sq:isVehicleIntersecting() return false end
    function sq:getObjects() return javaList(self.objects) end
    function sq:HasStairs() return false end
    function sq:HasStairsBelow() return false end
    function sq:has(k)
        if type(k) == "table" then return flags[k.name] == true end
        return flags[k] == true
    end
    function sq:getDoor() return nil end
    function sq:getWindow() return nil end
    function sq:getFloor() return o.floor end
    function sq:hasFloor() return o.floor ~= nil end
    function sq:isSomethingTo() return false end
    function sq:getMovingObjects() return { isEmpty = function() return #sq.moving == 0 end } end
    function sq:isSolid() return o.solid == true end
    function sq:isSolidTrans() return false end
    function sq:AddSpecialObject(obj) -- failAdd：加進去之後才出錯（驗拆回）
        self.objects[#self.objects + 1] = obj
        if failAdd then error("injected failure after AddSpecialObject") end
    end
    local function removeHere(obj)
        for _, list in ipairs({ sq.objects, sq.world }) do
            for k, v in ipairs(list) do
                if v == obj then table.remove(list, k) return k - 1 end
            end
        end
        return -1
    end
    -- 照引擎：預設（safelyRemove 不是 false）時多格物件整組拆（IsoGridSquare.java:5942-5965）
    function sq:transmitRemoveItemFromSquare(obj, safely)
        if safely ~= false and obj.group then
            for _, m in ipairs(obj.group) do m.sq.removeHere(m.o) end
            return 0
        end
        return removeHere(obj)
    end
    sq.removeHere = removeHere
    function sq:connectedWithFloor() return true end
    function sq:RecalcProperties() end
    function sq:getCell() return getCell() end
    function sq:clearWater() end
    function sq:disableErosion() end
    function sq:RecalcAllWithNeighbours() end
    function sq:getWorldObjects() return javaList(self.world) end
    function sq:canReachTo(other) return not other.noReach end
    squares[x .. "," .. y .. "," .. z] = sq
    return sq
end
SafeHouse = {
    isSafeHouse = function(sq, name) if sq.owner and sq.owner ~= name then return {} end return nil end,
    getSafeHouse = function(sq) return sq.owner and {} or nil end,
    isSafehouseAllowLoot = function(sq, p) return not (sq.owner and sq.owner ~= p:getUsername()) end,
}
buildUtil = { setHaveConstruction = function() end, stairIsBlockingPlacement = function() return false end }
-- 舊的多格物件（例：跨兩格的植物）：group＝{ { sq, o }, ... }，可被換地板拆掉
local function oldPiece(sq, group)
    local o = { group = group }
    function o:getProperties()
        return { has = function(_, k) return type(k) == "table" and k.name == "canBeRemoved" end }
    end
    function o:getTextureName() return "vegetation_test_01_0" end
    function o:getType() return IsoObjectType.normal end
    function o:getSprite() return nil end
    sq.objects[#sq.objects + 1] = o
    group[#group + 1] = { sq = sq, o = o }
    return o
end
IsoThumpable = { new = function(_, sq, name, north)
    local o = { name = name, north = north, mats = {}, md = {} }
    for _, s in ipairs({ "setCanPassThrough", "setBlockAllTheSquare", "setIsHoppable", "setIsDoorFrame",
        "setCanBarricade", "setIsFloor", "setIsThumpable", "setIsDismantable", "setMaxHealth", "setHealth",
        "setRenderYOffset", "setExplored", "transmitCompleteItemToClients" }) do
        o[s] = function() end
    end
    function o:getBuildMaterials() return self.mats end
    function o:getModData() return self.md end
    function o:getSquare() return sq end
    return o
end }
-- 假物品與背包（getSomeTypeEvalRecurse／getFirstTagEvalRecurse 照原版：最多 n 個、過 predicate）
ItemTag = { HAMMER = "HAMMER", MASONS_TROWEL = "MASONS_TROWEL", BLOW_TORCH = "BLOW_TORCH", WELDING_MASK = "WELDING_MASK" }
function instanceof() return false end
function sendRemoveItemFromContainer() end
function sendAddItemsToContainer() end
local function item(ft, tags)
    local it = { ft = ft, tags = tags or {} }
    function it:getFullType() return ft end
    function it:isBroken() return false end
    function it:getContainer() return self.box end
    return it
end
local function inventory()
    local inv = { items = {} }
    function inv:add(it) self.items[#self.items + 1] = it; it.box = self; return it end
    function inv:Remove(it)
        for k, v in ipairs(self.items) do
            if v == it then table.remove(self.items, k); it.box = nil; return end
        end
    end
    function inv:count(ft)
        local n = 0
        for _, v in ipairs(self.items) do if v.ft == ft then n = n + 1 end end
        return n
    end
    function inv:getFirstTagEvalRecurse(tag, pred)
        for _, v in ipairs(self.items) do if v.tags[tag] and pred(v) then return v end end
        return nil
    end
    function inv:getSomeTypeEvalRecurse(ft, pred, n)
        local out = {}
        for _, v in ipairs(self.items) do
            if #out >= n then break end
            if v.ft == ft and pred(v) then out[#out + 1] = v end
        end
        return javaList(out)
    end
    function inv:getCountTypeEvalRecurse(ft, pred)
        return self:getSomeTypeEvalRecurse(ft, pred, math.huge):size()
    end
    function inv:AddItems(ft, n)
        local out = {}
        for k = 1, n do out[k] = self:add(item(ft)) end
        return javaList(out)
    end
    return inv
end
local regionPokes = 0
IsoRegions = { setPreviousFlags = function() end, squareChanged = function() regionPokes = regionPokes + 1 end }
Capability = { UseBuildCheat = "UseBuildCheat", CanGoInsideSafehouses = "CanGoInsideSafehouses" }
function checkPermissions(player, cap) return player.admin == true end
local sent = {}
-- 只記送給玩家的（四個參數）；三個參數的是廣播（例：換地板後的 erosion），不記
function sendServerCommand(player, module, cmd, args)
    if args == nil then return end
    sent[#sent + 1] = { player = player, cmd = cmd, args = args }
end
local scrapDefs = {}
ISMoveableDefinitions = { getInstance = function()
    return { getScrapDefinition = function(mat) return scrapDefs[mat] end }
end }
-- 假玩家：onlineID、木工等級、是否管理員、是否死亡、位置（pos 可改）、背包、建造作弊、所在格
local function player(o)
    o = o or {}
    local p = { admin = o.admin, inv = inventory(), pos = { x = o.x or 10.5, y = o.y or 20.5, z = o.z or 0 } }
    function p:getOnlineID() return o.id or 1 end
    function p:getPlayerNum() return 0 end
    function p:getUsername() return o.name or "tester" end
    function p:isDead() return o.dead == true end
    function p:getVehicle() return nil end
    function p:getPerkLevel() return o.woodwork or 0 end
    function p:isTimedActionInstant() return o.instant == true end
    function p:getX() return self.pos.x end
    function p:getY() return self.pos.y end
    function p:getZ() return self.pos.z end
    function p:isBuildCheat() return o.cheat == true end
    function p:getInventory() return self.inv end
    function p:removeFromHands() end
    function p:getCurrentSquare() return o.here end
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
require "MinidoracatBuilder/Check"
local Rules, Sources = MinidoracatBuilder.Rules, MinidoracatBuilder.Sources
local Index, Catalog = MinidoracatBuilder.Index, MinidoracatBuilder.Catalog
local Entry, Cost, Server = MinidoracatBuilder.Entry, MinidoracatBuilder.Cost, MinidoracatBuilder.Server
local Check, Materials = MinidoracatBuilder.Check, MinidoracatBuilder.Materials

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
check(kind({ flags = { "doorW" }, keys = { DoubleDoor = "3" } }) == nil, "雙開門的單片：不列（要四片一組）")
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
check(kind({ flags = { "solidfloor", "water" }, keys = { waterAmount = "9999" } }) == nil, "無限水的地板（天然水面 9999）不列")
check(kind({ keys = { IsMoveAble = "", BlocksPlacement = "", waterAmount = "999999" } }) == nil, "無限水的井（能搬）不列")
check(kind({ flags = { "attachedFloor" }, keys = { waterAmount = "9999" } }) == nil, "無限水的岸邊疊圖不列")
check(kind({ type = T.stairsBN, keys = { waterAmount = "99999" } }) == nil, "無限水的樓梯不列")
check(kind({ flags = { "solidfloor" }, keys = { waterAmount = "9998" } }) == "floor"
    and kind({ keys = { IsMoveAble = "", waterAmount = "20" } }) == "furniture", "waterAmount 低於 9999（雨水桶等）：照常列")
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
    -- 椅子兩面中間夾著床（另一個 tileset）：群組代表換到後面那張時，要寫回椅子自己的桶
    chairA, bedA, bedB, chairB,
    sprite("st_01_0", 1, { type = T.stairsBW }), sprite("st_01_1", 2, { type = T.stairsMW }),
    sprite("st_01_2", 3, { type = T.stairsTW }),
    sprite("tk_01_3", MOD_ID_BASE + 3, { flags = { "solidfloor" } }),
    sprite("fancy_tiles_7", 400, { flags = { "solidfloor" } }), -- tileset 本身沒有結尾編號
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
local wall, furn, floor = Index.names("wall"), Index.names("furniture"), Index.names("floor")
check(wall.n == 1 and wall[1] == "walls_01_1", "沒有貼圖、id −1、非 tile 都濾掉")
check(furn.n == 2, "兩面椅子算一項、兩格床只收原點")
local hasChairB, hasBedB = false, false
for i = 1, furn.n do
    if furn[i] == "furniture_01_2" then hasChairB = true end
    if furn[i] == "beds_01_1" then hasBedB = true end
end
check(hasChairB, "群組代表取編號最小的那張（furniture_01_2）")
check(not hasBedB, "多格的非原點不列")
local stairs = Index.names("stairs")
check(stairs.n == 1 and stairs[1] == "st_01_0", "樓梯只收 B 片")
check(floor.n == 2002, "地板 2002 項")
check(Index.items == 2006, "總項目數（牆 1＋家具 2＋樓梯 1＋地板 2002）")
local fb = Index.bucket.furniture
check(fb.furniture_01.n == 1 and fb.furniture_01[1] == "furniture_01_2" and fb.beds_01.n == 1
    and fb.beds_01[1] == "beds_01_0", "分桶：群組代表換到後面那張時寫回自己的 tileset 桶，不蓋到別的桶")
local fs = Index.kindSets.floor
check(fs.n == 3 and fs[1] == "tk_01" and fs[2] == "fancy_tiles" and fs[3] == "filler_01"
    and floor[1] == "tk_01_3" and floor[2] == "fancy_tiles_7" and floor[3] == "filler_01_1",
    "種類裡的 tileset 照第一次出現的順序；Index.names 照這個順序攤平")
check(Index.kindCount.wall == 1 and Index.kindCount.furniture == 2 and Index.kindCount.stairs == 1
    and Index.kindCount.floor == 2002, "每個種類的項目數（群組只算一項）")
wall[1] = "changed"
check(Index.names("wall")[1] == "walls_01_1" and Index.names("nope").n == 0, "Index.names 回新陣列；沒有的種類回空陣列")
check(Index.family.filler_01 == "filler" and Index.family.tk_01 == "tk" and Index.family.fancy_tiles == "fancy_tiles"
    and Index.family.furniture_01 == "furniture", "圖塊組＝tileset 去掉結尾 _數字；沒有編號的照原樣")
local kindOf, setOf = {}, {}
for i = 1, Index.nameKey.n do kindOf[Index.nameItem[i]], setOf[Index.nameItem[i]] = Index.nameKind[i], Index.nameSet[i] end
check(kindOf.furniture_01_2 == "furniture" and setOf.furniture_01_2 == "furniture_01" and setOf.beds_01_0 == "beds_01"
    and Index.nameKind.n == Index.nameKey.n and Index.nameSet.n == Index.nameKey.n,
    "名稱鍵的每一項都記種類與 tileset（和 nameItem 同一項）")
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
local tdf = sprite("walls_test_01_9", 5009, { keys = { DoorWallNTrans = "" } })
local tN, tW = Entry.edges("doorFrame", tdf)
check(tN and not tW and Entry.north("doorFrame", tdf), "透明門框：只有字串鍵也認得是北邊")
local tnw = sprite("walls_test_01_10", 5010, { keys = { WallNWTrans = "" } })
local twN, twW = Entry.edges("wall", tnw)
check(twN and twW, "透明牆角：兩條邊都佔")

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
-- 原版的 perk 是 Java Perk 物件、toString 才是技能 ID（PerkFactory.java:320-322）；用物件假冒，少了 tostring 會被抓到
local function perkObj(id) return setmetatable({}, { __tostring = function() return id end }) end
scrapDefs.Wood = { perk = perkObj("Woodwork"), returnItemsStatic = { { returnItem = "Base.Plank", maxAmount = 2 } } }
scrapDefs.Electric = { perk = perkObj("Electricity"), returnItems = { { returnItem = "Base.ElectronicsScrap", maxAmount = 1 },
    { returnItem = "Base.ElectricWire", maxAmount = 3 } } }
scrapDefs.Fabric = { perk = perkObj("Woodwork"), returnItems = {} }
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
c = cost("furniture", { keys = { Material = "Wood" } }, 0.5)
check(c.items["Base.Plank"] == 2, "有拆解材質：倍率低於 1 仍照 1 收（拆掉不會比付的多）")
c = cost("wall", { flags = { "WallN" } }, 0.5)
check(c.items["Base.Plank"] == 2 and c.items["Base.Nails"] == 3, "沒有拆解材質：照倍率")
local fa = sprite("fa_01_0", 910, { keys = { Material = "Wood" } })
local fb = sprite("fa_01_1", 911, { keys = { Material = "Electric" } })
local fc = Cost.forCells("furniture", { fa, fb }, 1)
check(fc[1].items["Base.Plank"] == 2 and fc[1].items["Base.ElectricWire"] == 3 and fc[2].items["Base.Plank"] == 2
    and fc[2].items["Base.ElectronicsScrap"] == 1, "多格各片材質不同：每格都收各格的最大值")
fc[1].items["Base.Plank"] = 99
local t1 = Cost.of("wall", wallN).tools
t1[#t1 + 1] = "X"
check(fc[2].items["Base.Plank"] == 2 and #Cost.of("wall", wallN).tools == 1, "各格成本與工具清單互不共用")
-- 這格給經驗的技能，排序後用逗號接起來；不給是 ""
local function perks(c)
    local t = {}
    for k in pairs(Cost.xp({ c })) do t[#t + 1] = k end
    table.sort(t)
    return table.concat(t, ",")
end
check(perks(cost("wall", { flags = { "WallN" } })) == "Woodwork" and perks(cost("wall", { keys = { MaterialType = "Brick" } })) == "Masonry"
    and perks(cost("wall", { keys = { MaterialType = "Metal_Large" } })) == "MetalWelding"
    and perks(cost("door", { keys = { MaterialType = "Brick" } })) == "Woodwork"
    and perks(cost("floor", { keys = { MaterialType = "Gravel" } })) == "",
    "沒有拆解材質的經驗照工具那套材質：木工、砌磚、焊接；照木頭收的磚造門給木工；碎石地板不給")
local xp = Cost.xp({ cost("wall", { flags = { "WallN" } }), cost("floor", {}), cost("floor", { keys = { MaterialType = "Brick" } }),
    cost("floor", { keys = { MaterialType = "Gravel" } }) })
check(xp.Woodwork == 60 and xp.Masonry == 20,
    "經驗：每付一件材料 5 點、同技能跨格累加（木牆 10 件＋木地板 2 件＝60、磚地板 4 件＝20），碎石地板沒有")
check(next(Cost.xp({ cost("wall", { flags = { "WallN" } }, 0) })) == nil, "倍率 0：沒付材料、沒有經驗")
check(perks(cost("furniture", { keys = { Material = "Wood" } })) == "" and perks(cost("floor", { keys = { Material = "Wood" } })) == "",
    "不能搬、沒有 CanScrap、第一個材質有產出：原版照退料表退 1..v 件、可能全拿回，不給經驗")
check(perks(cost("furniture", { keys = { Material = "Wood", IsMoveAble = "" } })) == "Woodwork"
    and perks(cost("furniture", { keys = { Material = "Wood", CanScrap = "" } })) == "Woodwork"
    and perks(cost("door", { keys = { Material = "Wood" } })) == "Woodwork"
    and perks(cost("furniture", { keys = { Material = "Fabric", Material2 = "Wood" } })) == "Woodwork",
    "能搬、CanScrap（照機率退）、門、第一個材質沒有產出（拆不了）：照常給經驗")
scrapDefs.Sandbag = { perk = perkObj("Woodwork"), returnItemsStatic = { { returnItem = "Base.Sandbag", maxAmount = 3 } } }
scrapDefs.Curtain = { perk = perkObj("MAX"),
    returnItemsStatic = { { returnItem = "Base.Sheet", maxAmount = 1, chancePerRoll = 10000 } } }
-- 下面三個是假的材質：技能是 MAX 但不會全退的、和 Wood 產出同一種材料但技能不同的（原版沒有這種定義）
scrapDefs.FakeMax = { perk = perkObj("MAX"), returnItems = { { returnItem = "Base.Sheet", maxAmount = 1 } } }
scrapDefs.FakeMaxPlank = { perk = perkObj("MAX"), returnItems = { { returnItem = "Base.Plank", maxAmount = 1 } } }
scrapDefs.FakePlankElec = { perk = perkObj("Electricity"), returnItems = { { returnItem = "Base.Plank", maxAmount = 1 } } }
check(perks(cost("solid", { keys = { Material = "Sandbag", CanScrap = "" } })) == "", "沙包牆：拆掉固定退 3 個，不給經驗")
check(perks(cost("furniture", { keys = { Material = "Curtain", CanScrap = "" } })) == "",
    "每輪機率 ≥ 100 的產出（窗簾）：技能夠就全退，不給經驗")
c = cost("furniture", { keys = { IsMoveAble = "", Material = "Wood", MaterialType = "Metal_Large" } })
check(perks(c) == "Woodwork" and c.tools[1] == "BLOW_TORCH",
    "有拆解材質的經驗照拆解技能（退料機率看它），不照 MaterialType；工具仍照 MaterialType")
local ew = Cost.xp({ cost("furniture", { keys = { IsMoveAble = "", Material = "Electric", Material2 = "Wood" } }) })
check(ew.Electricity == 20 and ew.Woodwork == 10,
    "各材料給產出它的那個 Material 的技能（原版各 Material 照自己的技能擲退料）：電子零件＋電線 4 件給電工、木板 2 件給木工")
local fx = Cost.xp({ cost("furniture", { keys = { IsMoveAble = "", Material = "FakeMax", Material2 = "Wood" } }) })
check(fx.Woodwork == 10 and fx.MAX == nil, "技能是 Perks.MAX（原版拆了不給經驗）的材料不給，同一格其他材料照給")
check(perks(cost("furniture", { keys = { IsMoveAble = "", Material = "Wood", Material2 = "FakePlankElec" } })) == "",
    "同一種材料兩個 Material 的技能不同：這種材料不給")
check(perks(cost("furniture", { keys = { IsMoveAble = "", Material = "FakeMaxPlank", Material2 = "Wood" } })) == ""
    and next(Cost.xp(Cost.forCells("furniture",
        { sprite("fm_04_0", 916, { keys = { IsMoveAble = "", Material = "FakeMaxPlank" } }),
          sprite("fm_04_1", 917, { keys = { IsMoveAble = "", Material = "Wood" } }) }, 1))) == nil,
    "同一種材料先記成不給（MAX）、後面的 Material 或另一片有技能：仍然不給（那一份照 MAX 的定義退）")
local ma = sprite("fm_01_0", 912, { keys = { IsMoveAble = "", Material = "Wood" } })
local mb = sprite("fm_01_1", 913, { keys = { IsMoveAble = "", Material = "Electric", MaterialType = "Metal_Large" } })
local fm = Cost.xp(Cost.forCells("furniture", { ma, mb }, 1))
check(fm.Woodwork == 20 and fm.Electricity == 40,
    "多格各片材質不同、同一種材料技能一致：每格照收到的最大值給（木板 2 給木工、電子零件＋電線 4 給電工，兩格）")
local mc = sprite("fm_02_1", 915, { keys = { IsMoveAble = "", Material = "FakePlankElec" } })
check(next(Cost.xp(Cost.forCells("furniture", { ma, mc }, 1))) == nil,
    "多格同一種材料在各片的技能不同（點自己技能高的那片拆，整組照它的機率退）：這種材料不給")
local mixed = Cost.forCells("furniture", { sprite("fm_02_0", 914, { keys = { CanScrap = "", Material = "Curtain" } }), ma }, 1)
check(next(Cost.xp(mixed)) == nil, "多格有一片拆掉一定全退：點那片拆整組都退，整組不給經驗")

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
check(intent(P, {}) == nil and sent[1] and sent[1].cmd == "accepted" and Server.intents[7]
    and Server.intents[7].c[1][2] == 20, "合法請求：存下、回 accepted")
check(regionPokes == 0, "那一帶沒有地板格：不喚醒區域系統（也不記，下次再試）")
check(intent(P, { v = "r0:1" }) == "STALE", "設定摘要不同：STALE")
check(intent(P, { c = {} }) == "BAD_REQUEST", "沒有座標：BAD_REQUEST")
check(intent(P, { c = { 10, 20, 0, 11, 20, 0, 12, 20, 0 } }) == "BAD_REQUEST", "超過每次上限：BAD_REQUEST")
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
check(noIntent(P, 5, 1), "舊 nonce 的動作：拒絕、不回覆")
check(noIntent(player({ id = 7 }), 6, 1), "同一個 onlineID、不同玩家物件（例如重連）：拒絕")
check(noIntent(P, 6, 2), "請求裡沒有第 2 項：拒絕")
local A = player({ id = 8 })
intent(A, { n = 100 })
check(noIntent(P, 100, 1), "nonce 屬於別人的請求：拒絕")
sent = {}
check(Server.complete(P, 6, 1) == false and sent[1] and sent[1].args.code == "NOT_LOADED",
    "身分對了才往下驗（這裡格子建不出來：NOT_LOADED）")
check(Server.duration(P, 6, 1) == 200, "施工時間：木工 0 的牆 200 tick（那一帶沒喚醒，不加等待）")
check(Server.duration(player({ id = 7, instant = true }), 6, 1) == 1, "別的玩家物件問不到請求：1 tick 後被拒")
check(Server.duration(P, 99, 1) == 1, "找不到請求：1 tick")
check(intent(P, { n = 9, c = { 200, 20, 0 } }) == "TOO_FAR", "錨點離玩家超過 100 格：TOO_FAR")
check(intent(P, { n = 10, c = { 60, 20, 0 } }) == nil and Server.intents[7].n == 10,
    "點遠處（50 格）再走過去：收下（和每次項數無關）")
intent(P, { n = 6 })
check(Server.intents[7] == nil or Server.intents[7].n ~= 9, "被拒的請求不取代舊的")
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

print("情境十二：放置（假格子、假背包）：放好才扣料、擋下時世界與背包都不動")
sb.MaxCellsPerDrag = 4
local solidS = sprite("solid_01_0", 950, { flags = { "solid" } })
local crateS = sprite("crate_01_0", 951, { keys = { container = "crate" } })
world({ wallN, solidS, crateS })
local hammer = item("Base.Hammer", { HAMMER = true })
local function give(p, spec)
    for ft, n in pairs(spec) do for _ = 1, n do p.inv:add(item(ft)) end end
end
local function build(p, n, e, at)
    sent = {}
    Server.intent(p, { n = n, e = e or "walls_test_01_4", d = 0, c = at or { 50, 50, 0 }, v = Entry.digest() })
    if sent[1] and sent[1].cmd == "refused" then return false, sent[1].cmd, sent[1].args end
    sent = {}
    local ok = Server.complete(p, n, 1)
    return ok, sent[1] and sent[1].cmd, sent[1] and sent[1].args or {}
end
local wallSq = square(50, 50, 0)
local Q = player({ id = 20, x = 50.5, y = 51.5 })
Q.inv:add(hammer)
give(Q, { ["Base.Plank"] = 4, ["Base.Nails"] = 5 })
local ok, cmd, a = build(Q, 1)
check(not ok and a.code == "NO_MATERIAL" and a.need["Base.Nails"] == 1 and #wallSq.objects == 0
    and Q.inv:count("Base.Plank") == 4, "少一根釘子：NO_MATERIAL、報缺 1、格子沒有新物件、背包不動")
give(Q, { ["Base.Nails"] = 1 })
Q.inv:Remove(hammer)
ok, cmd, a = build(Q, 2)
check(not ok and a.code == "NO_TOOL" and a.tools[1] == "HAMMER" and #wallSq.objects == 0, "沒有鐵鎚：NO_TOOL")
Q.inv:add(hammer)
sent = {}
holes["52,52,0"], holes["49,52,0"] = true, true
Server.intent(Q, { n = 3, e = "walls_test_01_4", d = 0, c = { 52, 52, 0 }, v = Entry.digest() })
Q.pos.x = 57.5
local before = created
sent = {}
check(Server.complete(Q, 3, 1) == false and sent[1].args.code == "TOO_FAR" and created == before,
    "請求後走遠了：TOO_FAR，而且沒有先補格子")
Q.pos.x = 50.5
local shSq = square(51, 50, 0, { owner = "someone" })
ok, cmd, a = build(Q, 4, nil, { 51, 50, 0 })
check(not ok and a.code == "SAFEHOUSE" and #shSq.objects == 0 and Q.inv:count("Base.Plank") == 4,
    "別人的安全屋：SAFEHOUSE、不放、不扣")
local deniedAt = {}
MinidoracatSafehouse = { v1 = { API_MAJOR = 1, CAPABILITIES = { denies = true }, BITS = { BUILD = 4, USE = 1 },
    denies = function(_, x, y, _, bit, opts)
        deniedAt[#deniedAt + 1] = { bit = bit, label = opts and opts.label }
        return x == 51 and y == 49
    end } }
local permSq = square(51, 49, 0)
ok, cmd, a = build(Q, 41, nil, { 51, 49, 0 })
check(not ok and a.code == "PERM_DENIED" and #permSq.objects == 0 and Q.inv:count("Base.Plank") == 4
    and deniedAt[1].bit == 4 and deniedAt[1].label == "MinidoracatBuilder:build",
    "Safehouse MOD 的細分權限不准建造：PERM_DENIED、問的是 BUILD 位元、不放、不扣")
MinidoracatSafehouse.v1.API_MAJOR = 2
deniedAt = {}
local Q2 = player({ id = 30, x = 50.5, y = 51.5 })
Q2.inv:add(item("Base.Hammer", { HAMMER = true }))
ok, cmd, a = build(Q2, 42, nil, { 51, 49, 0 })
check(not ok and a.code == "NO_MATERIAL" and #deniedAt == 0, "Safehouse API 大版本不是 1：不呼叫 denies，照常往下判斷")
MinidoracatSafehouse = nil
xpLog = {}
ok, cmd = build(Q, 5)
local w = wallSq.objects[1]
check(ok and cmd == "placed" and w and w.mats["Base.Plank"] == "4" and w.mats["Base.Nails"] == "6",
    "材料齊：放好、退料照這一格的成本寫進 buildMaterials")
check(Q.inv:count("Base.Plank") == 0 and Q.inv:count("Base.Nails") == 0 and Q.inv:count("Base.Hammer") == 1,
    "放好才扣料：材料扣光、鐵鎚留著")
check(#xpLog == 1 and xpLog[1].p == Q and xpLog[1].perk == "perk:Woodwork" and xpLog[1].n == 50,
    "放好扣料後給經驗：木工 50（10 件材料）")
xpLog = {}
sent = {}
check(Server.complete(Q, 5, 1) == false and #sent == 0 and #wallSq.objects == 1, "同一項重送：不再放、不回覆")
local errSq = square(50, 51, 0)
give(Q, { ["Base.Plank"] = 4, ["Base.Nails"] = 6 })
failAdd = true
ok, cmd, a = build(Q, 6, nil, { 50, 51, 0 })
failAdd = false
check(not ok and a.code == "INTERNAL" and #errSq.objects == 0 and Q.inv:count("Base.Plank") == 4 and #xpLog == 0,
    "加進格子後才出錯：INTERNAL、拆回、不扣料、不給經驗")
local cheatSq = square(49, 50, 0)
local C = player({ id = 21, x = 49.5, y = 51.5, cheat = true })
check(build(C, 7, nil, { 49, 50, 0 }) and #cheatSq.objects == 1 and #xpLog == 0, "開建造作弊：背包空的也放，不給經驗")
Q.inv = inventory()
Q.inv:add(hammer)
give(Q, { ["Base.Plank"] = 4, ["Base.NailsBox"] = 1 })
square(51, 51, 0)
ok = build(Q, 8, nil, { 51, 51, 0 })
check(ok and Q.inv:count("Base.NailsBox") == 0 and Q.inv:count("Base.Nails") == 94,
    "只有釘子盒：拆一盒、用 6 根、剩 94 根放回背包")
local here, behind, open = square(52, 54, 0), square(53, 54, 0, { noReach = true }), square(51, 54, 0)
square(52, 53, 0)
local function drop(sq, ft, n)
    for _ = 1, n do
        local wo = { it = item(ft) }
        function wo:getItem() return self.it end
        function wo:getSquare() return sq end
        sq.world[#sq.world + 1] = wo
    end
end
local G = player({ id = 22, x = 52.5, y = 54.5, here = here })
G.inv:add(item("Base.Hammer", { HAMMER = true }))
give(G, { ["Base.Plank"] = 4 })
drop(behind, "Base.Nails", 6)
ok, cmd, a = build(G, 9, nil, { 52, 53, 0 })
check(not ok and a.code == "NO_MATERIAL" and #behind.world == 6, "釘子在牆後的地上：走不到不拿")
drop(open, "Base.Nails", 9)
ok = build(G, 10, nil, { 52, 53, 0 })
check(ok and #open.world == 3 and #behind.world == 6, "釘子在走得到的地上：只拿缺的 6 根")
square(48, 52, 0, { moving = { {} } })
ok, cmd, a = build(Q, 11, "solid_01_0", { 48, 52, 0 })
check(not ok and a.code == "BLOCKED", "會擋路的東西：格上有人時 BLOCKED")
square(47, 51, 0, { solid = true })
ok, cmd, a = build(Q, 19, "crate_01_0", { 47, 51, 0 })
check(not ok and a.code == "BLOCKED", "不能搬的實心容器：不疊在已經實心的格子上")
local sinkS = sprite("sink_test_01_0", 952, { flags = { "solid", "waterPiped" } })
world({ wallN, solidS, crateS, sinkS })
local sinkSq = square(60, 60, 0)
local S = player({ id = 31, x = 60.5, y = 61.5, here = square(60, 61, 0) })
S.inv:add(item("Base.Hammer", { HAMMER = true }))
give(S, { ["Base.Plank"] = 9, ["Base.Nails"] = 9 })
ok = build(S, 32, "sink_test_01_0", { 60, 60, 0 })
check(ok and sinkSq.objects[1] and sinkSq.objects[1].md.canBeWaterPiped == true and w.md.canBeWaterPiped == nil,
    "接水管的物件：照原版標成要重新接水管，放好不會直接有水")
square(48, 53, 0, { noReach = true })
ok, cmd, a = build(Q, 12, "solid_01_0", { 48, 53, 0 })
check(not ok and a.code == "UNREACHABLE", "走不到那一格（隔著牆、透明牆或關著的門）：UNREACHABLE")
ok, cmd, a = build(Q, 13, nil, { 49, 52, 0 })
check(a.code == "NOT_LOADED", "格邊種類（牆）不查走不走得到：照常往下驗")
local floorS = sprite("floor_01_0", 960, { flags = { "solidfloor" } })
world({ wallN, solidS, crateS, floorS })
local fA, fB = square(45, 45, 0), square(45, 44, 0, { owner = "someone" })
local grp = {}
oldPiece(fA, grp)
oldPiece(fB, grp)
give(Q, { ["Base.Plank"] = 1 })
Q.pos.x, Q.pos.y = 45.5, 46.5
ok = build(Q, 18, "floor_01_0", { 45, 45, 0 })
Q.pos.x, Q.pos.y = 50.5, 51.5
check(ok and #fA.objects == 1 and fA.objects[1].name == "floor_01_0" and #fB.objects == 1,
    "換地板只拆這一格的那片：跨到別人安全屋的另一片留著")
square(96, 96, 0, { floor = {} })
local I = player({ id = 23, x = 96.5, y = 97.5, instant = true })
before = regionPokes
sent = {}
Server.intent(I, { n = 14, e = "walls_test_01_4", d = 0, c = { 96, 96, 0, 97, 96, 0 }, v = Entry.digest() })
check(regionPokes == before + 1, "那一帶有地板：喚醒區域系統一次")
check(Server.duration(I, 14, 1) == 150, "即時動作的第一項也等滿喚醒的 3 秒（150 tick）")
check(Server.duration(I, 14, 2) == 1, "第二項排在第一項之後：不再等")
Server.intent(I, { n = 15, e = "walls_test_01_4", d = 0, c = { 96, 96, 0 }, v = Entry.digest() })
check(regionPokes == before + 1, "同一帶第二次請求：不再喚醒")
local X = player({ id = 24, x = 96.5, y = 97.5 })
Server.intent(X, { n = 16, e = "walls_test_01_4", d = 0, c = { 96, 96, 0 }, v = Entry.digest() })
nowMs = nowMs + 61000
Server.intent(I, { n = 17, e = "walls_test_01_4", d = 0, c = { 96, 96, 0 }, v = Entry.digest() })
check(Server.intents[24] == nil and Server.intents[23].n == 17, "過期的請求：下一次有人送請求時清掉（不留住玩家物件）")

print("情境十三：客戶端收到拒絕（單機靠這裡停下後面的動作）")
loaded["TimedActions/ISBaseTimedAction"] = true
ISBaseTimedAction = {
    derive = function(self, name) return setmetatable({ Type = name }, { __index = self }) end,
    new = function(self, character) return setmetatable({ character = character }, { __index = self }) end,
}
local cleared, added = {}, 0
ISTimedActionQueue = { clear = function(p) cleared[#cleared + 1] = p end, add = function() added = added + 1 end }
require "MinidoracatBuilder/Client"
local Client = MinidoracatBuilder.Client
Client.pending = { n = 42, player = "PA" }
Client.onServerCommand("refused", { n = 41, i = 1, code = "BLOCKED" })
check(#cleared == 0, "舊請求的拒絕：不清目前的佇列")
Client.onServerCommand("refused", { n = 42, i = 2, code = "BLOCKED" })
check(cleared[1] == "PA", "目前這筆被拒：清掉那位玩家的佇列")
local realIsServer = isServer
isServer = function() return false end
sb.Enabled = false
local nn, why = Client.build(player({ id = 30 }), "walls_test_01_4", 0, { { 10, 20, 0 } })
sb.Enabled = nil
isServer = realIsServer
check(nn == nil and why == "OFF" and added == 0, "單機請求當場被拒：回原因碼、不排動作")
isServer = function() return false end
local nn2 = Client.build(player({ id = 31 }), "walls_test_01_4", 0, { { 10, 20, 0 }, { 11, 20, 0 } })
isServer = realIsServer
check(nn2 ~= nil and added == 2, "單機請求收下：伺服器當場回 accepted，排兩項動作")
local realIsClient = isClient
isClient = function() return true end
function sendClientCommand() end
added = 0
local nn3 = Client.build(player({ id = 32 }), "walls_test_01_4", 0, { { 10, 20, 0 } })
check(nn3 ~= nil and added == 0, "MP：送出請求時還不排動作（動作不能比請求先到）")
Client.onServerCommand("accepted", { n = nn3 })
check(added == 1, "MP：收到 accepted 才排動作")
Client.onServerCommand("accepted", { n = nn3 })
check(added == 1, "重複的 accepted 不重排")
isClient = realIsClient
isServer = function() return false end
Client.pending = { n = 777, player = "PB" }
cleared = {}
Server.complete(player({ id = 33 }), 777, 1)
isServer = realIsServer
check(cleared[1] == "PB", "單機：沒有請求的動作（例：放太久過期）回 NO_INTENT、清掉後面的動作")

print("情境十四：材料摘要（Materials.summary／short／take）和 plan 對同一個玩家狀態判斷相同")
do
    local function same(a, b) -- 兩個 { fullType = 數量 } 或 nil
        if a == nil or b == nil then return a == b end
        for k, v in pairs(a) do if b[k] ~= v then return false end end
        for k, v in pairs(b) do if a[k] ~= v then return false end end
        return true
    end
    local function names(a) return a and table.concat(a, ",") or "" end
    -- plan 成功若且唯若 short 回 nil, nil；缺的數量與工具也一樣。另回 short 的結果給後面斷言
    local function agree(p, cost)
        local plan, m1, t1 = Materials.plan(p, cost)
        local m2, t2 = Materials.short(Materials.summary(p), cost)
        return (plan ~= nil) == (m2 == nil and t2 == nil) and same(m1, m2) and names(t1) == names(t2), m2, t2
    end
    local W = { items = { ["Base.Plank"] = 4, ["Base.Nails"] = 6 }, tools = { "HAMMER" } }
    local M1 = player({ id = 50 })
    M1.inv:add(item("Base.Hammer", { HAMMER = true }))
    give(M1, { ["Base.Plank"] = 4, ["Base.Nails"] = 6 })
    local ok1, m = agree(M1, W)
    local ok2, m7 = agree(M1, { items = { ["Base.Plank"] = 4, ["Base.Nails"] = 7 }, tools = { "HAMMER" } })
    check(ok1 and m == nil and ok2 and m7 and m7["Base.Nails"] == 1 and m7["Base.Plank"] == nil,
        "只有背包：剛好夠時都通過；多要一根時都報缺 1 根")
    local mHere = square(42, 42, 0)
    local mBehind, mOpen = square(43, 42, 0, { noReach = true }), square(41, 42, 0)
    local mOwned = square(42, 41, 0, { owner = "someone" })
    drop(mOpen, "Base.Nails", 4)
    drop(mBehind, "Base.Nails", 9)
    drop(mOwned, "Base.Nails", 9)
    local M2 = player({ id = 51, x = 42.5, y = 42.5, here = mHere })
    M2.inv:add(item("Base.Hammer", { HAMMER = true }))
    give(M2, { ["Base.Plank"] = 4 })
    local okG, mG = agree(M2, W)
    check(okG and mG and mG["Base.Nails"] == 2 and Materials.summary(M2).items["Base.Nails"] == 4,
        "地上：只算走得到、不在別人安全屋的（隔牆 9 根、別人安全屋 9 根都不算），兩邊都缺 2 根")
    drop(mOpen, "Base.Nails", 2)
    local okG2, mG2 = agree(M2, W)
    check(okG2 and mG2 == nil, "地上補到 6 根：兩邊都通過")
    local M3 = player({ id = 52 })
    give(M3, { ["Base.NailsBox"] = 1, ["Base.Nails"] = 30 })
    local N150 = { items = { ["Base.Nails"] = 150 }, tools = {} }
    local okB, mB = agree(M3, N150)
    check(okB and mB and mB["Base.Nails"] == 20 and Materials.summary(M3).items["Base.Nails"] == 130,
        "釘子盒：每盒算 100 根（30＋100），要 150 時兩邊都缺 20")
    give(M3, { ["Base.NailsBox"] = 1 })
    local okB2, mB2 = agree(M3, N150)
    check(okB2 and mB2 == nil, "多一盒：兩邊都通過")
    local M4 = player({ id = 53 })
    give(M4, { ["Base.Plank"] = 9, ["Base.Nails"] = 9 })
    M4.inv:add(item("Base.WeldingMask", { WELDING_MASK = true }))
    local okT, mT, tT = agree(M4, W)
    local okM, _, tM = agree(M4, { items = {}, tools = { "BLOW_TORCH", "WELDING_MASK", "NOPE" } })
    check(okT and mT == nil and names(tT) == "HAMMER" and okM and names(tM) == "BLOW_TORCH,NOPE",
        "缺工具：兩邊都報同一串（照 cost.tools 順序；這個版本沒有的標籤當沒帶）")
    local S = Materials.summary(M1)
    local first = Materials.short(S, W)
    Materials.take(S, W)
    local second = Materials.short(S, W)
    check(first == nil and second and second["Base.Plank"] == 4 and second["Base.Nails"] == 6,
        "拖曳逐格累計：第一格扣掉後，第二格缺一整份")
    Materials.take(S, W)
    check(S.items["Base.Plank"] == 0 and M1.inv:count("Base.Plank") == 4, "不夠的扣到 0、不變負數；摘要只是估算，背包不動")
end

print("情境十五：Check.item 預覽與伺服器同一份判斷；預覽不補格子、不寫東西")
do
    world({ wallN, solidS, crateS, floorS })
    local kHere = square(56, 44, 0)
    local K = player({ id = 60, x = 56.5, y = 44.5, here = kHere })
    square(57, 44, 0, { moving = { {} } })   -- 格上有人：實心的東西 BLOCKED
    square(55, 44, 0, { noReach = true })    -- 走不到
    square(56, 43, 0, { owner = "someone" }) -- 別人的安全屋
    local PV = { preview = true }
    local cases = {
        { "nope_01_0", 0, { 56, 45, 0 }, "UNKNOWN" },
        { "walls_test_01_4", 1, { 56, 45, 0 }, "BAD_FACE" },
        { "walls_test_01_4", 0, { 56, 49, 0 }, "TOO_FAR", 49 },
        { "solid_01_0", 0, { 55, 44, 0 }, "UNREACHABLE", 44 },
        { "walls_test_01_4", 0, { 56, 43, 0 }, "SAFEHOUSE", 43 },
        { "solid_01_0", 0, { 57, 44, 0 }, "BLOCKED", 44 },
        { "walls_test_01_4", 0, { 56, 45, 0 }, nil },
    }
    for _, c in ipairs(cases) do
        local cP, eP = Check.item(K, c[1], c[2], c[3], PV)
        local cS, eS = Check.item(K, c[1], c[2], c[3])
        check(cP == c[4] and cS == c[4] and (eP and eP.y) == c[5] and (eS and eS.y) == c[5],
            "預覽與伺服器同一個拒絕碼與座標：" .. tostring(c[4]) .. "（" .. c[1] .. "）")
    end
    local _, _, okInfo = Check.item(K, "walls_test_01_4", 0, { 56, 45, 0 }, PV)
    check(okInfo.entry.kind == "wall" and okInfo.cells[1].sq ~= nil and okInfo.costs[1].items["Base.Plank"] == 4
        and okInfo.total.items["Base.Nails"] == 6 and okInfo.total.tools[1] == "HAMMER", "通過時 info 帶格子、各格成本與加總")
    holes["58,46,0"], holes["57,46,0"] = true, true
    local before = created
    local cMiss, _, iMiss = Check.item(K, "walls_test_01_4", 0, { 58, 46, 0 }, PV)
    check(cMiss == nil and created == before and iMiss.cells[1].sq == nil and iMiss.total.items["Base.Plank"] == 4,
        "預覽：格子不存在時不補格子、略過要格子的檢查（交給伺服器），成本照算")
    local cSrv, eSrv = Check.item(K, "walls_test_01_4", 0, { 58, 46, 0 })
    check(cSrv == "NOT_LOADED" and eSrv.x == 58 and created == before + 1, "伺服器：照舊補格子，建不出來 NOT_LOADED")
    check(Check.item(K, "solid_01_0", 0, { 57, 46, 0 }, PV) == nil and created == before + 1,
        "預覽：最近那一格不存在時不判斷走不走得到")
    local WK = { preview = true, walk = true }
    check(Check.item(K, "walls_test_01_4", 0, { 56, 49, 0 }, WK) == nil and Check.item(K, "solid_01_0", 0, { 55, 44, 0 }, WK) == nil,
        "游標預覽（walk）：會先走過去，不看 MaxDistance、不查走不走得到")
    check(Check.item(K, "walls_test_01_4", 0, { 56, 146, 0 }, WK) == "TOO_FAR"
        and Check.item(K, "walls_test_01_4", 0, { 56, 45, 2 }, WK) == "TOO_FAR",
        "游標預覽（walk）：照請求的規則，超過 100 格或差兩層仍是 TOO_FAR")
    check(Check.item(K, "walls_test_01_4", 0, { 56, 49, 0 }, { walk = true }) == "TOO_FAR",
        "walk 沒配 preview：照伺服器規則（不能用來放寬伺服器判斷）")
    local opts = {}
    MinidoracatSafehouse = { v1 = { API_MAJOR = 1, CAPABILITIES = { denies = true }, BITS = { BUILD = 4 },
        denies = function(_, x, y, _, _, o)
            opts[#opts + 1] = o
            return x == 56 and y == 46
        end } }
    local cDP = Check.item(K, "walls_test_01_4", 0, { 56, 46, 0 }, PV)
    local cDS = Check.item(K, "walls_test_01_4", 0, { 56, 46, 0 })
    MinidoracatSafehouse = nil
    check(cDP == "PERM_DENIED" and cDS == "PERM_DENIED" and opts[1].preview == true and opts[2].preview ~= true
        and opts[2].label == "MinidoracatBuilder:build", "Safehouse 細分權限：預覽帶 preview（不寫稽核、不推通知），伺服器照常")
    local K2 = player({ id = 61, x = 56.5, y = 44.5, here = kHere })
    K2.inv:add(item("Base.Hammer", { HAMMER = true }))
    give(K2, { ["Base.Plank"] = 4, ["Base.Nails"] = 5 })
    local cN, eN = Check.item(K2, "walls_test_01_4", 0, { 56, 45, 0 }, { preview = true, summary = Materials.summary(K2) })
    check(cN == "NO_MATERIAL" and eN.need["Base.Nails"] == 1 and eN.need["Base.Plank"] == nil,
        "預覽帶摘要：缺料回 NO_MATERIAL 與缺的數量（和伺服器 plan 同一份）")
    check(Check.item(K2, "walls_test_01_4", 0, { 56, 45, 0 }, PV) == nil
        and Check.item(K2, "walls_test_01_4", 0, { 56, 45, 0 }) == nil,
        "沒給摘要的預覽與伺服器模式都不查材料（伺服器在 Server.complete 自己 plan）")
    local K3 = player({ id = 62, x = 56.5, y = 44.5, here = kHere })
    give(K3, { ["Base.Plank"] = 4, ["Base.Nails"] = 6 })
    local cT, eT = Check.item(K3, "walls_test_01_4", 0, { 56, 45, 0 }, { preview = true, summary = Materials.summary(K3) })
    check(cT == "NO_TOOL" and eT.tools[1] == "HAMMER" and eT.need == nil, "預覽帶摘要：料夠、缺工具回 NO_TOOL")
    local K4 = player({ id = 63, x = 56.5, y = 44.5, here = kHere, cheat = true })
    local S4 = Materials.summary(K4)
    check(Check.item(K4, "walls_test_01_4", 0, { 56, 45, 0 }, { preview = true, summary = S4 }) == nil,
        "建造作弊：預覽不查材料（伺服器也不扣）")
    local S2 = Materials.summary(K2)
    local aM, aT, aTotal = Check.affordable(S2, "walls_test_01_4")
    check(aM and aM["Base.Nails"] == 1 and aT == nil and aTotal.items["Base.Plank"] == 4, "affordable：缺 1 根釘子")
    local zM, zT, zTotal = Check.affordable(S2, "walls_test_01_4", 0)
    check(zM == nil and zT == nil and next(zTotal.items) == nil, "affordable 倍率 0：免材料，鐵鎚有帶就夠")
    local nM, nT, nTotal = Check.affordable(S2, "nope_01_0")
    local cM, cTl, cTotal = Check.affordable(S4, "walls_test_01_4")
    check(nM == nil and nT == nil and nTotal == nil and cM == nil and cTl == nil and cTotal.items["Base.Plank"] == 4,
        "affordable：解析不了的項目 total 是 nil（不是夠料）；建造作弊都夠、照樣回成本")
end

print("情境十六：拆除方式（Cost.refund）")
do
    local function refund(kind, keys) return Cost.refund(kind, sprite("rf_01_0", 990, { keys = keys })) end
    check(refund("furniture", { IsMoveAble = "", CanScrap = "", Material = "Wood" }) == "pickup"
        and refund("door", { IsMoveAble = "" }) == "pickup", "能搬：拿起來（也能拆的照樣是拿起來）")
    check(refund("furniture", { CanScrap = "", Material = "Wood" }) == "scrap"
        and refund("door", { CanScrap = "", Material = "Wood" }) == "scrap", "CanScrap 且材質有產出：照材質拆（門也一樣）")
    check(refund("furniture", { CanScrap = "", Material = "Fabric" }) == "none", "CanScrap 但材質沒有產出：拆了沒東西")
    check(refund("wall", { Material = "Wood" }) == "materials" and refund("furniture", { Material = "Wood" }) == "materials"
        and refund("wall", { CanScrap = "", Material = "Undefined", Material2 = "Wood" }) == "none",
        "IsoThumpable 不能搬、不能照材質拆：第一個材質有拆解定義才照 buildMaterials 退（Undefined 不算）")
    check(refund("wall", {}) == "none" and refund("wall", { Material = "Fabric", Material2 = "Wood" }) == "none",
        "IsoThumpable 第一個材質沒有拆解產出（第二個有也一樣）：只能砸")
    check(refund("door", { Material = "Wood" }) == "none" and refund("window", { Material = "Wood" }) == "none",
        "門窗不是 IsoThumpable、不能搬、不能拆：只能砸，不退料")
end

print("情境十七：目錄視窗（篩選、分類、來源、完整圖塊名、最愛、名稱）")
do
    local realIsServer, realGetText = isServer, getText
    isServer = function() return false end
    function getItemName(ft) return ft end
    require "MinidoracatBuilder/Names"
    require "MinidoracatBuilder/Favorites"
    require "MinidoracatBuilder/Window"
    isServer = realIsServer
    local W, Names, Fav = MinidoracatBuilder.Window, MinidoracatBuilder.Names, MinidoracatBuilder.Favorites
    -- 帶參數的 getText 把參數接在後面，名稱組合與數量才看得出來
    getText = function(k, ...)
        local a = { ... }
        if #a == 0 then return k end
        return k .. "(" .. table.concat(a, ",") .. ")"
    end
    local mod = MOD_ID_BASE -- 檔號 7001＝UMCTP
    local fl0 = sprite("floors_interior_01_0", 10, { flags = { "solidfloor" } })
    local fl1 = sprite("floors_interior_01_1", 11, { flags = { "solidfloor" } })
    local chair = sprite("furniture_seat_01_0", 20, { keys = { IsMoveAble = "", GroupName = "Furniture", CustomName = "Red Chair" } })
    local stool = sprite("furniture_seat_01_1", 21, { keys = { IsMoveAble = "" } })
    local modBox = sprite("umctp_boxes_01_0", mod + 5, { keys = { IsMoveAble = "" } })
    local offWall = sprite("walls_off_01_0", 30, { flags = { "WallN" }, keys = { WallN = "" } })
    local crate = sprite("aaa_crates_01_0", 40, { keys = { IsMoveAble = "" } })
    world({ fl0, fl1, chair, stool, modBox, offWall, crate })
    Sources.byFile = { [7001] = "UMCTP" }
    Index.reset()
    Index.add("floor", "floors_interior_01_0", "floors_interior_01", 0, 1)
    Index.add("floor", "floors_interior_01_1", "floors_interior_01", 1, 1)
    Index.add("furniture", "furniture_seat_01_0", "furniture_seat_01", 0, 1, "furniture_seat_01|Furniture|Red Chair",
        "Furniture Red Chair")
    Index.add("furniture", "furniture_seat_01_1", "furniture_seat_01", 1, 1)
    Index.add("furniture", "umctp_boxes_01_0", "umctp_boxes_01", 0, 7001)
    Index.add("wall", "walls_off_01_0", "walls_off_01", 0, 1)
    Index.add("furniture", "aaa_crates_01_0", "aaa_crates_01", 0, 1) -- 最後才加、顯示名排最前：驗排序
    Index.addNameKey(Index.groupList[1])
    for i = 1, Index.setName.n do
        Index.addSetKey(i, Index.setName[i] == "umctp_boxes_01" and "UMCTP Mod" or "")
    end
    sb.DisabledSources, sb.DisabledTilesets = "", "walls_off_01"
    local function st(o)
        local s = { query = "", tab = "all", cat = "all", source = "all", recent = { n = 0 } }
        for k, v in pairs(o or {}) do s[k] = v end
        return s
    end
    local function has(list, name)
        for i = 1, list.n do if list[i] == name then return true end end
        return false
    end
    local all = W.filter(st())
    check(all.n == 6 and not has(all, "walls_off_01_0"), "全部頁、沒有搜尋字：6 項，管理員關掉的 tileset 不列")
    local q = W.filter(st({ query = "red chair" }))
    check(q.n == 1 and q[1] == "furniture_seat_01_0", "搜尋名稱：只列名稱命中的那一項，不列整個 tileset")
    local m = W.filter(st({ query = "UMCTP mod" }))
    check(m.n == 1 and m[1] == "umctp_boxes_01_0", "搜尋來源 MOD 名：列出那個 tileset 的整桶")
    local f = W.filter(st({ tab = "floor" }))
    check(f.n == 2 and has(f, "floors_interior_01_1") and not has(f, "furniture_seat_01_0"), "地板頁：只列地板")
    local kv = W.filter(st({ cat = "k:furniture", source = "vanilla" }))
    check(kv.n == 3 and not has(kv, "umctp_boxes_01_0"), "種類分類＋原版來源：只列原版的家具")
    local km = W.filter(st({ source = "UMCTP" }))
    check(km.n == 1 and km[1] == "umctp_boxes_01_0", "來源選 MOD：只列那個 MOD 的")
    local fam = W.filter(st({ cat = "f:furniture_seat" }))
    check(fam.n == 2 and has(fam, "furniture_seat_01_1"), "圖塊組分類：tileset 去掉結尾編號後相同的都列")
    local ex, jump = W.filter(st({ tab = "wall", query = "  floors_interior_01_1 " }))
    check(jump == "floors_interior_01_1" and ex.n == 2, "完整圖塊名（前後空白去掉）：不管頁籤，回它所在的整桶並選取它")
    local exOff, jumpOff = W.filter(st({ query = "walls_off_01_0" }))
    check(jumpOff == nil and exOff.n == 0, "完整圖塊名但 tileset 被管理員關掉：不跳、不列")
    check(W.filter(st({ query = "zzz" })).n == 0, "沒有命中：空清單")
    local favs = { n = 3, "furniture_seat_01_1", "gone_01_0", "floors_interior_01_0" }
    local fv = W.filter(st({ tab = "furniture", cat = "fav", fav = favs }))
    check(fv.n == 1 and fv[1] == "furniture_seat_01_1", "最愛：這個伺服器沒有的略過，照頁籤篩")
    do
        local favSrc = W.filter(st({ cat = "fav", query = "UMCTP mod", fav = { n = 2, "furniture_seat_01_0", "umctp_boxes_01_0" } }))
        check(favSrc.n == 1 and favSrc[1] == "umctp_boxes_01_0", "最愛＋搜尋來源 MOD 名：和一般清單搜得到的一樣")
        W.st.recent = { n = 0 }
        W.addRecent("a_1")
        W.addRecent("b_2")
        W.addRecent("c_3")
        W.addRecent("a_1")
        local r = W.st.recent
        check(r.n == 3 and r[1] == "a_1" and r[2] == "c_3" and r[3] == "b_2", "最近使用：新的在前，舊的照順序留著，不重複")
        -- 假磁碟，照引擎語意：打不開回 nil、讀到一半出錯 readLine 回 nil（和讀完一樣）、寫入失敗不丟錯
        local realReader, realWriter = getFileReader, getFileWriter
        local disk, failOpen, failMid, dropWrites
        getFileWriter = function(_, _, append)
            local buf = append and (disk or "") or ""
            return { write = function(_, s) buf = buf .. s end,
                close = function() if not dropWrites then disk = buf end end }
        end
        getFileReader = function()
            if failOpen or disk == nil then return nil end
            local lines, i = {}, 0
            for l in disk:gmatch("[^\n]+") do lines[#lines + 1] = l end
            return { readLine = function()
                i = i + 1
                if failMid and i > 1 then return nil end
                return lines[i]
            end, close = function() end }
        end
        local function reset(content)
            disk, failOpen, failMid, dropWrites = content, false, false, false
            Fav.list, Fav.set = { n = 0 }, {}
        end
        reset("a_1\nb_2\n#end\n")
        failMid = true
        Fav.load()
        local _, saved = Fav.toggle("x_1")
        check(saved == false and disk == "a_1\nb_2\n#end\n", "最愛檔讀到一半出錯：不寫檔（不拿殘缺的清單蓋掉），回報沒存到")
        reset("a_1\n#end\n")
        failOpen = true
        Fav.load()
        _, saved = Fav.toggle("x_1")
        check(saved == false and disk == "a_1\n#end\n", "最愛檔在卻打不開：不寫檔，回報沒存到")
        reset(nil)
        Fav.load()
        _, saved = Fav.toggle("x_1")
        check(saved == true and disk == "x_1\n#end\n", "最愛檔不存在：當空清單，加入後寫檔")
        reset("a_1\n#end\n")
        Fav.load()
        check(Fav.list.n == 1 and Fav.list[1] == "a_1", "最愛檔讀完整：載入檔裡的最愛")
        dropWrites = true
        _, saved = Fav.toggle("x_1")
        check(saved == false, "寫入沒有真的進檔（引擎不丟錯）：讀回比對，回報沒存到")
        getFileReader, getFileWriter = realReader, realWriter
        Fav.list, Fav.set = { n = 0 }, {}
    end
    local groups = W.categories("all")
    local famIds = {}
    for i, it in ipairs(groups[3].items) do famIds[i] = it.id end
    check(table.concat(famIds, ",") == "f:aaa_crates,f:floors_interior,f:furniture_seat,f:umctp_boxes",
        "分類的圖塊組：照顯示名排序（不是加入順序），管理員關掉的不列")
    local opts = W.sources()
    check(#opts == 3 and opts[1].id == "all" and opts[2].id == "vanilla" and opts[3].id == "UMCTP",
        "來源下拉：全部、原版、各 MOD")
    local list = Fav.parse(" a_1 \r\n\nb_2\na_1\n")
    check(list.n == 2 and list[1] == "a_1" and list[2] == "b_2" and Fav.serialize(list) == "a_1\nb_2\n#end\n"
        and Fav.serialize({ n = 0 }) == "#end\n" and Fav.parse("#end\n").n == 0,
        "最愛檔：去空白、空行、重複；寫回一行一個，最後一行 #end（讀的時候略過）")
    Names.reset()
    check(Names.of("furniture_seat_01_0") == "Red Chair CH", "名稱：有原版移動物件翻譯就用")
    local composed = Names.of("furniture_seat_01_1")
    check(composed:find("IGUI_MBLD_Name_Composed", 1, true) and composed:find("IGUI_MBLD_Kind_furniture", 1, true)
        and composed:find("furniture seat 01", 1, true) and composed:find(",1)", 1, true),
        "名稱：沒有翻譯就組「種類 · 圖塊組 · 編號」")
    check(Names.of("gone_01_0") == "gone_01_0", "名稱：不存在的圖塊回 sprite 名稱本身")
    sb.DisabledTilesets = ""
    getText = realGetText
    Names.reset()
end

print("情境十八：建造游標（拖一排、朝向循環、逐格累計扣料）")
do
    require "MinidoracatBuilder/Cursor"
    local Cursor = MinidoracatBuilder.Cursor
    local l1 = Cursor.line(10, 10, 0, 14, 11, 32)
    check(#l1 == 5 and l1[5][1] == 14 and l1[5][2] == 10, "拖一排：取位移大的那一軸（x），5 格")
    local l2 = Cursor.line(10, 10, 0, 9, 3, 32)
    check(#l2 == 8 and l2[8][1] == 10 and l2[8][2] == 3, "拖一排：往 y 負方向 8 格")
    check(#Cursor.line(10, 10, 0, 10, 10, 32) == 1, "起點終點同一格：1 格")
    local l3 = Cursor.line(10, 10, 0, 100, 10, 32)
    check(#l3 == 32 and l3[32][1] == 41, "超過上限：只到第 32 格")
    local l4 = Cursor.line(10, 10, 0, 0, 10, 4)
    check(#l4 == 4 and l4[4][1] == 7, "上限 4、往 x 負方向")
    local faces = { n = 3, 1, 2, 4 }
    check(Cursor.nextFace(faces, 4, 1) == 1 and Cursor.nextFace(faces, 1, -1) == 4 and Cursor.nextFace(faces, 2, 1) == 4
        and Cursor.nextFace(faces, 3, 1) == 1 and Cursor.nextFace({ n = 1, 0 }, 0, 1) == 0,
        "朝向循環：只在有的朝向之間轉，不在清單的回第一個")
    local realItem = Check.item
    Check.item = function(_, _, _, a, opts)
        if a[1] == 2 then return "BLOCKED", { x = 2 } end
        local have = opts.summary.items["Base.Plank"]
        if have < 2 then return "NO_MATERIAL", { need = { ["Base.Plank"] = 2 - have } } end
        return nil, nil, { total = { items = { ["Base.Plank"] = 2 }, tools = {} } }
    end
    local S = { cheat = false, tools = {}, items = setmetatable({}, { __index = function(t, k)
        local v = k == "Base.Plank" and 5 or 0
        rawset(t, k, v)
        return v
    end }) }
    local anchors = {}
    for x = 0, 4 do anchors[#anchors + 1] = { x, 0, 0 } end
    local res, ok, short = Cursor.preview(nil, "x_01_0", 0, anchors, S)
    check(ok == 2 and short == 2 and res[1].code == nil and res[2].code == nil and res[3].code == "BLOCKED"
        and res[4].code == "NO_MATERIAL" and res[5].code == "NO_MATERIAL",
        "一排逐格累計：木板 5、每格 2，前兩格可蓋，被擋的不扣，後兩格缺料")
    check(S.items["Base.Plank"] == 5, "累計只扣在副本，原摘要不動")
    Check.item = realItem
end

print("情境十九：拒絕碼的玩家訊息")
do
    local Messages = MinidoracatBuilder.Messages
    local realGetText = getText
    getText = function(k, ...)
        local a = { ... }
        if #a == 0 then return k end
        return k .. "(" .. table.concat(a, ",") .. ")"
    end
    local allKeyed = true
    -- 介面用到的鍵在 EN、CH 都要有：Lua 裡寫死的鍵（Family_ 用 getTextOrNull，可以沒有），加上拼出來的
    -- 拒絕碼、種類、頁籤、拆除方式、朝向、工具。getText 換掉了，只能讀 json 檔本身
    do
        local W = MinidoracatBuilder.Window
        local want = {}
        for _, file in ipairs({ "Window", "Cursor", "Names", "Messages", "Favorites" }) do
            local f = assert(io.open(MEDIA .. "/client/MinidoracatBuilder/" .. file .. ".lua", "rb"))
            for k in f:read("*a"):gmatch('"(IGUI_MBLD_[%w_]+)"') do
                if k:sub(-1) ~= "_" and k:sub(1, 17) ~= "IGUI_MBLD_Family_" then want[k] = true end
            end
            f:close()
        end
        for code in pairs(Messages.CODES) do want["IGUI_MBLD_Refuse_" .. code] = true end
        for _, kinds in pairs(W.TAB_KINDS) do
            for _, k in ipairs(kinds) do want["IGUI_MBLD_Kind_" .. k] = true end
        end
        for _, t in ipairs(W.TABS) do want["IGUI_MBLD_Tab_" .. t] = true end
        for _, r in ipairs({ "pickup", "scrap", "materials", "none" }) do want["IGUI_MBLD_Refund_" .. r] = true end
        for d = 0, 4 do want["IGUI_MBLD_Face_" .. d] = true end
        for _, t in ipairs({ "HAMMER", "MASONS_TROWEL", "BLOW_TORCH", "WELDING_MASK" }) do want["IGUI_MBLD_Tool_" .. t] = true end
        local missing = {}
        for _, lang in ipairs({ "EN", "CH" }) do
            local f = assert(io.open(MEDIA .. "/shared/Translate/" .. lang .. "/IG_UI.json", "rb"))
            local have = {}
            for k in f:read("*a"):gmatch('"(IGUI_MBLD_[%w_]+)"%s*:') do have[k] = true end
            f:close()
            for k in pairs(want) do
                if not have[k] then missing[#missing + 1] = lang .. ":" .. k end
            end
        end
        check(#missing == 0, "介面用到的翻譯鍵 EN、CH 都有 " .. table.concat(missing, " "))
    end
    for _, code in ipairs({ "OFF", "NOT_ALLOWED", "STATE", "STALE", "RATE_LIMITED", "BAD_REQUEST", "NO_INTENT", "UNKNOWN",
        "UNSUPPORTED", "DISABLED", "BAD_FACE", "TOO_FAR", "UNREACHABLE", "NOT_LOADED", "SAFEHOUSE", "PERM_DENIED",
        "OUTSIDE_SAFEHOUSE", "BLOCKED", "NO_MATERIAL", "NO_TOOL", "INTERNAL", "WALK" }) do
        if not Messages.CODES[code] then allKeyed = false end
    end
    check(allKeyed, "伺服器的拒絕碼與走不到都在訊息表裡")
    local nm = Messages.refusal("NO_MATERIAL", { need = { ["Base.Plank"] = 2 }, tools = { "HAMMER" } })
    check(nm:find("Base.Plank", 1, true) and nm:find("HAMMER", 1, true), "缺料：材料與缺的工具都列出")
    check(Messages.refusal("WHAT", {}):find("IGUI_MBLD_Refuse_Other(WHAT)", 1, true), "不認得的碼：通用訊息附上碼")
    getText = realGetText
end

print()
if failures > 0 then
    print(failures .. " 項失敗")
    os.exit(1)
end
print("全部通過")
