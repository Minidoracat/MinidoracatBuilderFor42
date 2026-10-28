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
        contains = function(_, x)
            for _, v in ipairs(items) do if v == x then return true end end
            return false
        end,
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
function getMaximumWorldLevel() return 31 end
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
        checkHaveRoof = function() HARNESS_ROOF = (HARNESS_ROOF or 0) + 1 end, -- 全域：記呼叫次數（屋頂情境驗）
    }
end
DesignationZoneAnimal = { addNewRoof = function() end }
-- o.flags＝格子上的旗標／字串鍵（名稱 → true）；o.owner＝安全屋主人；o.moving＝格上的人；o.floor；o.noReach＝走不到；
-- o.stairs＝格上有樓梯；o.wallN／o.wallW＝那條邊的牆（getWall 回它）
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
    function sq:HasStairs() return o.stairs == true end
    function sq:HasStairsBelow() return false end
    function sq:has(k)
        if type(k) == "table" then return flags[k.name] == true end
        return flags[k] == true
    end
    -- 照引擎：只有邊方向列舉的版本（IsoGridSquare.java:3634-3680），傳 boolean 會丟錯
    local function edgeArg(dir)
        if dir ~= GridSquareEdgeFacingDirection.NORTH_SOUTH and dir ~= GridSquareEdgeFacingDirection.EAST_WEST then
            error("getDoor/getWindow take GridSquareEdgeFacingDirection, got " .. tostring(dir))
        end
    end
    function sq:getDoor(dir) edgeArg(dir) return (o.doors or {})[dir] end
    function sq:getWindow(dir) edgeArg(dir) return (o.windows or {})[dir] end
    function sq:getFloor() return o.floor end
    function sq:hasFloor() return o.floor ~= nil end
    function sq:isSomethingTo() return false end
    function sq:getMovingObjects() return { isEmpty = function() return #sq.moving == 0 end } end
    function sq:isSolid() return o.solid == true end
    function sq:isSolidTrans() return false end
    function sq:AddSpecialObject(obj, index) -- failAdd：加進去之後才出錯（驗拆回）；index 照引擎插在那個位置
        if index and index >= 0 and index < #self.objects then
            table.insert(self.objects, index + 1, obj)
        else
            self.objects[#self.objects + 1] = obj
        end
        if failAdd then error("injected failure after AddSpecialObject") end
    end
    function sq:getWall(north) if north then return o.wallN end return o.wallW end
    function sq:getWallSE() return nil end
    function sq:hasModData() return sq.md ~= nil end
    function sq:getModData() sq.md = sq.md or {}; return sq.md end
    function sq:getRoomID() return -1 end
    function sq:addFloor(name) -- 照引擎：先拆格上的地板、植物這類（預設 safelyRemove：多格的整組拆，IsoGridSquare.java:4746-4763），
        for i = #sq.objects, 1, -1 do -- 再加地板物件、格子帶 solidfloor
            local old = sq.objects[i]
            local p = old.getProperties and old:getProperties()
            if p and (p:has(IsoFlagType.vegitation) or p:has(IsoFlagType.solidfloor) or p:has(IsoFlagType.noStart)
                or p:has(IsoFlagType.taintedWater)) then
                sq:transmitRemoveItemFromSquare(old)
            end
        end
        local f = { name = name }
        function f:getSquare() return sq end
        function f:getSprite() return { getName = function() return name end } end
        flags.solidfloor = true
        sq.objects[#sq.objects + 1] = f
        return f
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
-- 舊的多格物件（例：跨兩格的植物）：group＝{ { sq, o }, ... }，可被換地板拆掉；flag＝它帶的旗標（預設 canBeRemoved）
local function oldPiece(sq, group, flag)
    local o = { group = group }
    function o:getProperties()
        return { has = function(_, k) return type(k) == "table" and k.name == (flag or "canBeRemoved") end }
    end
    function o:getTextureName() return "vegetation_test_01_0" end
    function o:getType() return IsoObjectType.normal end
    function o:getSprite() return nil end
    sq.objects[#sq.objects + 1] = o
    group[#group + 1] = { sq = sq, o = o }
    return o
end
IsoThumpable = { new = function(_, sq, name, north)
    local o = { name = name, north = north, mats = {}, md = {}, set = {} }
    for _, s in ipairs({ "setCanPassThrough", "setBlockAllTheSquare", "setIsHoppable", "setIsDoorFrame",
        "setCanBarricade", "setIsFloor", "setIsThumpable", "setIsDismantable", "setMaxHealth", "setHealth",
        "setThumpDmg", "setRenderYOffset", "setExplored", "transmitCompleteItemToClients", "setIsStairs" }) do
        o[s] = function(self, v) self.set[s] = v end -- 記最後一次設的值
    end
    function o:getSprite() return spriteMap[name] end
    function o:getBuildMaterials() return self.mats end
    function o:getModData() return self.md end
    function o:getSquare() return sq end
    return o
end }
-- 假物品與背包（getSomeTypeEvalRecurse／getFirstTagEvalRecurse 照原版：最多 n 個、過 predicate）
ItemTag = { HAMMER = "HAMMER", MASONS_TROWEL = "MASONS_TROWEL", BLOW_TORCH = "BLOW_TORCH", WELDING_MASK = "WELDING_MASK",
    SCREWDRIVER = "SCREWDRIVER" }
function instanceof() return false end
-- 拆除退料的亂數：ZombRand(n) 回 0..n−1；HARNESS_ROLL＝"max"（全退）／"min"（只退 1）切換（拆除情境用）。
-- 主程式的區域變數快到 200 個上限，這幾個用全域
HARNESS_ROLL = "max"
function ZombRand(n) if HARNESS_ROLL == "min" then return 0 end return n - 1 end
function ZombRandFloat(a) return a end
-- 假 GOS（原版 server/Map/SGlobalObjectSystem.lua 用到的部分）：系統的 modData 就是系統表本身；存檔只存 setModDataKeys
-- 白名單裡的鍵（HARNESS_GOS_KEYS 記下來給情境驗）。RegisterSystemClass 當場建 instance（原版在 OnSGlobalObjectSystemInit）。
HARNESS_GOS_KEYS = {}
SGlobalObjectSystem = {}
SGlobalObjectSystem.__index = SGlobalObjectSystem
function SGlobalObjectSystem:derive(t)
    local cls = setmetatable({ Type = t }, { __index = self })
    cls.__index = cls
    return cls
end
function SGlobalObjectSystem.new(cls, name)
    local o = setmetatable({}, cls)
    o.system = { setModDataKeys = function(_, keys) HARNESS_GOS_KEYS[name] = keys end,
        setObjectModDataKeys = function() end, setObjectSyncKeys = function() end }
    o:initSystem()
    return o
end
function SGlobalObjectSystem:initSystem() end
function SGlobalObjectSystem.RegisterSystemClass(cls) cls:new() end
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
    function inv:getFirstTypeEvalRecurse(ty, pred) -- 型別沒有「.」時只比「.」後面（ItemContainer.java:1197-1200）
        for _, v in ipairs(self.items) do
            local t = ty:find(".", 1, true) and v.ft or v.ft:match("[^.]+$")
            if t == ty and pred(v) then return v end
        end
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
    return { getScrapDefinition = function(mat) return scrapDefs[mat] end,
        -- 原版材質血量倍率（ISMoveableDefinitions.lua:688-690）
        getHealthDefinition = function(mat) return ({ Wood = 1.5, Brick = 2.25, Steel = 3 })[mat] end }
end }
-- 假玩家：onlineID、木工等級（perks＝{ ["perk:技能"] = 等級 } 可個別指定）、是否管理員、是否死亡、位置（pos 可改）、背包、
-- 建造作弊、搬運作弊、所在格
local function player(o)
    o = o or {}
    local p = { admin = o.admin, inv = inventory(), pos = { x = o.x or 10.5, y = o.y or 20.5, z = o.z or 0 } }
    function p:getOnlineID() return o.id or 1 end
    function p:getPlayerNum() return 0 end
    function p:getUsername() return o.name or "tester" end
    function p:isDead() return o.dead == true end
    function p:getVehicle() return nil end
    function p:getPerkLevel(perk) return o.perks and o.perks[perk] or o.woodwork or 0 end
    function p:isMovablesCheat() return o.movCheat == true end
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
local loaded = { ["Map/SGlobalObjectSystem"] = true } -- 原版檔，上面有假的
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
check(kind({ type = T.curtainS, keys = { MoveType = "WindowObject", IsMoveAble = "", IsClosedState = "" } }) == nil,
    "關著的窗簾：不列（項目是打開那張，關著的是它的 −4 號）")
check(kind({ type = T.lightswitch, keys = { lightR = "200", LightRadius = "5" } }) == nil
    and kind({ keys = { lightR = "200", lightG = "200", LightRadius = "5" } }) == nil
    and kind({ keys = { lightR = "200", lightG = "200", lightB = "1", LightRadius = "5" } }) == "light",
    "有 lightR 但缺 lightG 或 lightB：不列（IsoLightSwitch 建構子三色都要，缺一個就丟錯）；三色都有照列")
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
do -- 主程式區域變數上限 200
    check(kind({ flags = { "windowW", "makeWindowInvincible" }, keys = { WindowW = "" } }) == nil
        and kind({ flags = { "makeWindowInvincible" }, keys = { WindowW = "" } }) == nil
        and kind({ flags = { "cutW", "makeWindowInvincible" }, keys = { WallW = "" } }) == nil
        and kind({ flags = { "cutW", "makeWindowInvincible" } }) == nil,
        "讓窗打不破的旗標（窗、窗框、牆、牆面疊圖帶 makeWindowInvincible）：不列")
    check(kind({ flags = { "solidfloor", "attachedFloor" } }, "invisible_01_0") == nil
        and kind({ flags = { "cutW", "solid" } }, "underground_01_1") == nil, "引擎內部用的隱形地板、地底方塊：不列")
    check(kind({ keys = { IsMoveAble = "" } }, "solarmod_tileset_01_9") == nil
        and kind({ keys = { container = "SolarBox" } }, "solarmod_tileset_01_36") == nil,
        "太陽能 MOD 靠名稱給功能的圖塊（面板、電池組）：不列")
    local tank = { flags = { "solid" } }
    local before = kind(tank, "location_shop_fossoil_01_80") == "solid" and kind(tank, "location_business_bank_01_64") == "solid"
    modInfos[#modInfos + 1] = { id = "ArcadiaRefillablePropaneTanks_B42", name = "Arcadia" }
    Rules.unlistModSprites()
    table.remove(modInfos)
    check(before and kind(tank, "location_shop_fossoil_01_80") == nil and kind(tank, "location_shop_gas2go_01_95") == nil
        and kind(tank, "location_business_bank_01_64") == "solid",
        "照原版圖塊名稱給功能的 MOD：沒裝時照常列；裝了丙烷 MOD 才不列它的補充站，沒裝的 Economy 的 ATM 照常列")
end
print("情境二之一：窗的狀態圖（開、破、拆玻璃）不列，不看這次載入過哪些窗")
do -- 主程式區域變數上限 200
local WIN0 = { flags = { "windowN" }, keys = { WindowN = "", OpenTileOffset = "2", SmashedTileOffset = "4", GlassRemovedOffset = "6" } }
world({ sprite("win_01_0", 1, WIN0), sprite("win_01_8", 2, { flags = { "windowN" }, keys = { WindowN = "" } }),
    sprite("win_01_4", 3, { flags = { "attachedN" } }), sprite("nameless", 4, { flags = { "windowW" }, keys = { OpenTileOffset = "2" } }) })
fire("OnLoadedTileDefinitions", IsoSpriteManager.instance)
check(Rules.windowStates == 3, "關著的窗三個偏移記成三張狀態圖；沒有偏移、名稱沒有編號的不記（" .. tostring(Rules.windowStates) .. "）")
check(kind({ flags = { "attachedN" } }, "win_01_4") == nil, "狀態圖還沒被引擎改過（原本是附著物）：不列")
check(kind(WIN0, "win_01_2") == nil, "狀態圖被引擎改過（帶窗旗標與關著那張的偏移）：也不列")
check(kind(WIN0, "win_01_0") == "window" and kind({ flags = { "windowN" }, keys = { WindowN = "" } }, "win_01_8") == "window",
    "關著的窗照列，偏移指不到的下一扇窗也照列")
-- 補記（整個 Lua 在世界載入後才重設，集合是空的）：兩扇窗 win_02_0、win_02_8 都帶 2／4／6，兩扇都載入過，
-- 所以 win_02_2、win_02_10 已被引擎改過、帶著關著那張的旗標與偏移；win_02_2＋6＝8 是下一扇真的窗
local W2 = { "win_02_0", "win_02_2", "win_02_8", "win_02_10" }
world({ sprite(W2[1], 1, WIN0), sprite(W2[2], 5, WIN0), sprite(W2[3], 2, WIN0), sprite(W2[4], 6, WIN0) })
for k in pairs(Rules.windowStateSet) do Rules.windowStateSet[k] = nil end
Rules.windowStates = nil
local stateEntry, stateCode = Entry.resolve("win_02_10")
check(Rules.windowStates == 6 and stateEntry == nil and stateCode == "UNKNOWN",
    "沒趕上事件時第一次 Entry.resolve 先補記，兩扇窗各三張；伺服器入口對下一扇窗被改過的狀態圖回 UNKNOWN（"
    .. tostring(Rules.windowStates) .. "、" .. tostring(stateCode) .. "）")
local w0, w8, s2 = Entry.resolve("win_02_0"), Entry.resolve("win_02_8"), Entry.resolve("win_02_2")
check(w0 and w0.kind == "window" and w8 and w8.kind == "window" and s2 == nil,
    "補記時被改過的狀態圖不當關著那張：它的偏移指到的下一扇窗照列，自己不列")
end

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
world({ wallN, modFloor, stairsB, tree, chair[1], chair[2], chair[3], chair[4], oddFace, oddTree, bedA, bedB, bedC,
    sprite("gd_01_0", 3, { flags = { "doorW" }, keys = { GarageDoor = "" } }) })
Sources.byFile = { [7001] = "UMCTP" }
local sb = SandboxVars.MinidoracatBuilder
local e1 = Entry.resolve("walls_test_01_4")
check(e1 and e1.kind == "wall" and e1.tileset == "walls_test_01" and e1.num == 4, "牆：種類與 tileset 由伺服器重算")
check(select(2, Entry.resolve("nope_01_0")) == "UNKNOWN", "不存在的圖塊：UNKNOWN（不新增空 sprite）")
check(select(2, Entry.resolve("tree_01_0")) == "UNKNOWN", "排除的圖塊（樹）：UNKNOWN")
check(select(2, Entry.resolve("st_01_0")) == "UNKNOWN", "湊不成三格的樓梯底片：UNKNOWN（目錄也不收）")
check(select(2, Entry.resolve("gd_01_0")) == "UNSUPPORTED", "車庫門第二版才做：UNSUPPORTED")
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
scrapDefs.Wood = { perk = perkObj("Woodwork"), tools = { "Base.Hammer", "Base.HammerStone" }, tools2 = { "Base.Saw" },
    returnItemsStatic = { { returnItem = "Base.Plank", maxAmount = 2 } } }
scrapDefs.Electric = { perk = perkObj("Electricity"), tools = { "Base.Screwdriver" },
    returnItems = { { returnItem = "Base.ElectronicsScrap", maxAmount = 1 }, { returnItem = "Base.ElectricWire", maxAmount = 3 } } }
scrapDefs.Fabric = { perk = perkObj("Woodwork"), returnItems = {} }
local scrapKeys = { Material = "Wood", Material2 = "Electric", Material3 = "Undefined" }
c = cost("furniture", { keys = scrapKeys })
check(c.items["Base.Plank"] == 2 and c.items["Base.ElectronicsScrap"] == 2 and c.items["Base.ElectricWire"] == 3
    and c.items["Base.Nails"] == nil, "有拆解材質：照拆解產出上限，不用基本價；電器另收 1 個電子零件（1＋1）")
scrapKeys.CanScrap, scrapKeys.ScrapSize = "", "Large"
c = cost("furniture", { keys = scrapKeys })
check(c.items["Base.Plank"] == 4 and c.items["Base.ElectricWire"] == 6, "可拆、Large：加倍")
scrapKeys.ScrapSize = "Small"
c = cost("furniture", { keys = scrapKeys })
check(c.items["Base.Plank"] == 1 and c.items["Base.ElectronicsScrap"] == 2 and c.items["Base.ElectricWire"] == 1,
    "可拆、Small：減半、至少 1、1.5 照原版只算 1；電器費照收")
c = cost("furniture", { keys = { Material = "Fabric" } })
check(c.items["Base.Plank"] == 2 and c.items["Base.Nails"] == 2, "拆解材質沒有產出：照種類基本價（沒寫重量當 5 公斤：2＋2）")
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
    and fc[2].items["Base.ElectronicsScrap"] == 2, "多格各片材質不同：每格都收各格的最大值")
fc[1].items["Base.Plank"] = 99
local t1 = Cost.of("wall", wallN).tools
t1[#t1 + 1] = "X"
check(fc[2].items["Base.Plank"] == 2 and #Cost.of("wall", wallN).tools == 1, "各格成本與工具清單互不共用")
-- 這格給經驗的技能（蓋的人技能都 0 級），排序後用逗號接起來；不給是 ""
local function perks(c)
    local t = {}
    for k in pairs(Cost.xp({ c }, player())) do t[#t + 1] = k end
    table.sort(t)
    return table.concat(t, ",")
end
check(perks(cost("wall", { flags = { "WallN" } })) == "Woodwork" and perks(cost("wall", { keys = { MaterialType = "Brick" } })) == "Masonry"
    and perks(cost("wall", { keys = { MaterialType = "Metal_Large" } })) == "MetalWelding"
    and perks(cost("door", { keys = { MaterialType = "Brick" } })) == "Woodwork"
    and perks(cost("floor", { keys = { MaterialType = "Gravel" } })) == "",
    "沒有拆解材質的經驗照工具那套材質：木工、砌磚、焊接；照木頭收的磚造門給木工；碎石地板不給")
local xp = Cost.xp({ cost("wall", { flags = { "WallN" } }), cost("floor", {}), cost("floor", { keys = { MaterialType = "Brick" } }),
    cost("floor", { keys = { MaterialType = "Gravel" } }) }, player({ woodwork = 9 }))
check(xp.Woodwork == 20 and xp.Masonry == 7.5,
    "經驗（本工具拆除每項退 1..v）：照平均拿不回的 (v−1)/2 件、每件 5 點（木牆 4 木板＋6 釘子＝20、木地板各 1 件＝0、"
    .. "磚地板 4 片＝7.5），碎石地板沒有；不看技能等級")
check(next(Cost.xp({ cost("wall", { flags = { "WallN" } }, 0) }, player())) == nil, "倍率 0：沒付材料、沒有經驗")
local bw = Cost.xp({ cost("furniture", { keys = { Material = "Wood" } }), cost("floor", { keys = { Material = "Wood" } }) }, player())
check(bw.Woodwork == 5 and perks(cost("floor", {})) == "",
    "不能搬、沒有 CanScrap、第一個材質有產出（本工具與原版搬動工具都照退料表退 1..v）：技能照材質、照平均拿不回的給"
    .. "（木板 2 片各 2.5）；付 1 件的一定全退，不給")
check(perks(cost("furniture", { keys = { Material = "Wood", IsMoveAble = "" } })) == "Woodwork"
    and perks(cost("furniture", { keys = { Material = "Wood", CanScrap = "" } })) == "Woodwork"
    and perks(cost("door", { keys = { Material = "Wood" } })) == "Woodwork"
    and perks(cost("furniture", { keys = { Material = "Fabric", Material2 = "Wood" } })) == "Woodwork",
    "能搬、CanScrap（照機率退）、門（只能砸）、第一個材質沒有產出（本工具拆）：照常給經驗")
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
check(perks(c) == "Woodwork" and #c.tools == 1 and c.tools[1] == "HAMMER",
    "有拆解材質的經驗與工具照第一個拆解材質（拆木頭用鐵鎚），不照 MaterialType（金屬是噴槍）")
local ew = Cost.xp({ cost("furniture", { keys = { IsMoveAble = "", Material = "Electric", Material2 = "Wood" } }) }, player())
check(ew.Electricity == 23 and ew.Woodwork == 9,
    "各材料給產出它的那個 Material 的技能、×(100−10)%：電子零件 1＋電線 3 給電工 18、電器費 1 件不打折 5、木板 2 給木工 9")
local fx = Cost.xp({ cost("furniture", { keys = { IsMoveAble = "", Material = "FakeMax", Material2 = "Wood" } }) }, player())
check(fx.Woodwork == 9 and fx.MAX == nil, "技能是 Perks.MAX（原版拆了不給經驗）的材料不給，同一格其他材料照給")
check(perks(cost("furniture", { keys = { IsMoveAble = "", Material = "Wood", Material2 = "FakePlankElec" } })) == "Electricity",
    "同一種材料兩個 Material 的技能不同：這種材料不給（只剩電器費給電工）")
check(perks(cost("furniture", { keys = { IsMoveAble = "", Material = "FakeMaxPlank", Material2 = "Wood" } })) == ""
    and next(Cost.xp(Cost.forCells("furniture",
        { sprite("fm_04_0", 916, { keys = { IsMoveAble = "", Material = "FakeMaxPlank" } }),
          sprite("fm_04_1", 917, { keys = { IsMoveAble = "", Material = "Wood" } }) }, 1), player())) == nil,
    "同一種材料先記成不給（MAX）、後面的 Material 或另一片有技能：仍然不給（那一份照 MAX 的定義退）")
local ma = sprite("fm_01_0", 912, { keys = { IsMoveAble = "", Material = "Wood" } })
local mb = sprite("fm_01_1", 913, { keys = { IsMoveAble = "", Material = "Electric", MaterialType = "Metal_Large" } })
local fm = Cost.xp(Cost.forCells("furniture", { ma, mb }, 1), player())
check(fm.Woodwork == 18 and fm.Electricity == 46,
    "多格各片材質不同、同一種材料技能一致：每格照收到的最大值給（木板 2 給木工 9、電工 18＋電器費 5，兩格）")
local mc = sprite("fm_02_1", 915, { keys = { IsMoveAble = "", Material = "FakePlankElec" } })
local mx = Cost.xp(Cost.forCells("furniture", { ma, mc }, 1), player())
check(mx.Woodwork == nil and mx.Electricity == 10,
    "多格同一種材料在各片的技能不同（點自己技能高的那片拆，整組照它的機率退）：這種材料不給；電器費拆了不退，全給")
local mixed = Cost.forCells("furniture", { sprite("fm_02_0", 914, { keys = { CanScrap = "", Material = "Curtain" } }), ma }, 1)
check(next(Cost.xp(mixed, player())) == nil, "多格有一片拆掉一定全退：點那片拆整組都退，整組不給經驗")
do
    -- 沒有拆解材質的家具、容器照搬運重量（PickUpWeight／10 公斤）分三級；牆這類照種類，不看重量
    local function wt(kind, w)
        local c = cost(kind, { keys = { PickUpWeight = w } })
        return (c.items["Base.Plank"] or 0) .. "+" .. (c.items["Base.Nails"] or 0)
    end
    check(wt("furniture", "15") == "1+1" and wt("furniture", "20") == "1+1" and wt("container", "40") == "2+2"
        and wt("furniture", "50") == "2+2" and wt("furniture", "51") == "4+4" and wt("container", "120") == "4+4"
        and wt("furniture", nil) == "2+2" and wt("solid", "15") == "2+2",
        "家具、容器照重量：≤2 公斤 1＋1、≤5 公斤 2＋2、其餘 4＋4、沒寫當 5 公斤；solid 不看重量")
    -- 工具照第一個拆解材質的原版主工具；噴槍加面罩；認不得的工具、沒有拆解材質照 MaterialType
    scrapDefs.MetalBars = { perk = perkObj("MetalWelding"), tools = { "Base.BlowTorch" }, tools2 = { "Base.WeldingMask" },
        returnItems = { { returnItem = "Base.MetalBar", maxAmount = 2 } } }
    scrapDefs.Sandbag.tools = {}
    scrapDefs.ModTool = { perk = perkObj("Woodwork"), tools = { "Mod.Spanner" },
        returnItems = { { returnItem = "Base.Plank", maxAmount = 1 } } }
    local function tools(kind, keys) return table.concat(cost(kind, { keys = keys }).tools, ",") end
    check(tools("furniture", { IsMoveAble = "", Material = "Electric", MaterialType = "Wood" }) == "SCREWDRIVER"
        and tools("furniture", { IsMoveAble = "", Material = "MetalBars" }) == "BLOW_TORCH,WELDING_MASK"
        and tools("furniture", { IsMoveAble = "", Material = "Wood", Material2 = "Electric" }) == "HAMMER"
        and tools("solid", { CanScrap = "", Material = "Sandbag" }) == ""
        and tools("furniture", { IsMoveAble = "", Material = "ModTool", MaterialType = "Metal_Large" }) == "BLOW_TORCH,WELDING_MASK"
        and tools("furniture", { IsMoveAble = "", Material = "NoSuchMat", Material2 = "Electric", MaterialType = "Brick" })
            == "MASONS_TROWEL",
        "工具照第一個拆解材質：電器螺絲起子、金屬噴槍＋面罩、木頭鐵鎚、沙包不用；認不得的工具、第一個材質沒有定義照 MaterialType")
    -- 經驗 ×(100 − 退料率)%，退料率＝10＋等級×10＋baseChance，夾在 0..100
    scrapDefs.Electric.baseChance = 10
    local elec = cost("furniture", { keys = { IsMoveAble = "", Material = "Electric" } })
    local function ex(o) return Cost.xp({ elec }, o and player(o)).Electricity end
    check(ex({}) == 21 and ex({ perks = { ["perk:Electricity"] = 3 } }) == 15
        and ex({ perks = { ["perk:Electricity"] = 8 } }) == 5 and ex({ woodwork = 9 }) == 5
        and ex({ movCheat = true }) == 5 and ex(nil) == 5,
        "照機率退料的經驗 ×(100−退料率)%：電工 0 級 80%、3 級 50%、8 級全退不給；搬運作弊、不知道誰蓋的當全退；電器費 1 件照給 5")
    scrapDefs.Neg = { perk = perkObj("Woodwork"), baseChance = -50, returnItems = { { returnItem = "Base.Sheet", maxAmount = 1 } } }
    check(Cost.xp({ cost("furniture", { keys = { IsMoveAble = "", Material = "Neg" } }) }, player()).Woodwork == 5,
        "退料率低於 0 當 0：照付的件數全給")
    scrapDefs.Electric.baseChance = nil
    -- 電器費：任一材質的拆解技能是電工就收 1 個電子零件，照倍率、不寫進退料；不是電器的沒有
    local f2 = Cost.of("furniture", sprite("c_01_0", 900, { keys = { IsMoveAble = "", Material = "Electric" } }), 2)
    local nf = cost("furniture", { keys = { IsMoveAble = "", Material = "Wood" } })
    check(f2.items["Base.ElectronicsScrap"] == 4 and f2.fee["Base.ElectronicsScrap"] == 2
        and nf.items["Base.ElectronicsScrap"] == nil and next(nf.fee) == nil
        and cost("furniture", { keys = { IsMoveAble = "", Material = "Wood", Material2 = "Electric" } }).fee["Base.ElectronicsScrap"] == 1,
        "電器費：倍率 2 時 (1+1)×2＝4、其中 2 個不退；不是電器的不收；第二個材質是電器也收")
    local fe = Cost.forCells("furniture", { sprite("fe_01_0", 918, { keys = { IsMoveAble = "", Material = "Electric" } }),
        sprite("fe_01_1", 919, { keys = { IsMoveAble = "", Material = "Wood" } }) }, 1)
    check(fe[2].items["Base.ElectronicsScrap"] == 2 and fe[2].fee["Base.ElectronicsScrap"] == 1,
        "多格只有一片是電器：每格照最大值收，電器費也照收（原版拆多格每一片各給一次經驗）")
    scrapDefs.EmptyElec = { perk = perkObj("Electricity"), tools = { "Base.Screwdriver" }, returnItems = {} }
    local ee = cost("furniture", { keys = { Material = "EmptyElec", PickUpWeight = "15" } }, 2)
    check(ee.items["Base.Plank"] == 2 and ee.items["Base.ElectronicsScrap"] == 2 and ee.fee["Base.ElectronicsScrap"] == 2
        and Cost.xp({ ee }, player()).Electricity == 10,
        "電工拆解定義沒有產出（MOD 可能這樣登記）：照基本價收，電器費照收（倍率 2 收 2 個、不退、經驗全給），不出錯")
    check(next(cost("furniture", { keys = { Material = "EmptyElec" } }, 0).fee) == nil, "倍率 0：照基本價的電器費也免")
end

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
check(#xpLog == 1 and xpLog[1].p == Q and xpLog[1].perk == "perk:Woodwork" and xpLog[1].n == 20,
    "放好扣料後給經驗：木工 20（木板 4、釘子 6，本工具拆時平均拿不回 1.5＋2.5 件）")
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
check(build(C, 7, nil, { 49, 50, 0 }) and #cheatSq.objects == 1 and #xpLog == 0
    and next(cheatSq.objects[1]:getBuildMaterials()) == nil, "開建造作弊：背包空的也放，不給經驗、不寫退料表（拆了不退）")
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
do
    -- 電器（第一個材質 Electric、不能搬、沒有 CanScrap）：照退料表退，退料表不含電器費；工具照拆 Electric 的螺絲起子
    local elecS = sprite("elec_test_01_0", 953, { flags = { "solid" }, keys = { Material = "Electric" } })
    world({ wallN, solidS, crateS, sinkS, elecS })
    local eSq = square(62, 60, 0)
    local E = player({ id = 33, x = 62.5, y = 61.5, here = square(62, 61, 0) })
    E.inv:add(item("Base.Hammer", { HAMMER = true }))
    give(E, { ["Base.ElectronicsScrap"] = 2, ["Base.ElectricWire"] = 3 })
    local eok, _, ea = build(E, 34, "elec_test_01_0", { 62, 60, 0 })
    check(not eok and ea.code == "NO_TOOL" and ea.tools[1] == "SCREWDRIVER", "拆電器要螺絲起子：只帶鐵鎚 NO_TOOL")
    E.inv:add(item("Base.Screwdriver", { SCREWDRIVER = true }))
    eok = build(E, 35, "elec_test_01_0", { 62, 60, 0 })
    local o = eSq.objects[1]
    check(eok and o and o.mats["Base.ElectronicsScrap"] == "1" and o.mats["Base.ElectricWire"] == "3"
        and E.inv:count("Base.ElectronicsScrap") == 0,
        "電器：收 2 個電子零件（拆解 1＋電器費 1），退料表只寫 1 個（電器費拆了不退）")
end
do
    -- 會擋路（solid／solidtrans）的非格邊物件照原版搬家具放下：都打得壞、整格擋住。一般的一隻殭屍就能打、
    -- 血量＝搬運重量（沒寫 50）× 材質倍率；地毯、掛牆物、放在桌上的照原版 movedThumpable：血量 100、thumpDmg 不改（8）
    local sink = sinkSq.objects[1]
    check(sink.set.setIsThumpable == true and sink.set.setMaxHealth == 50 and sink.set.setHealth == 50
        and sink.set.setThumpDmg == 1 and sink.set.setBlockAllTheSquare == true,
        "會擋路的物件：殭屍打得壞，血量 50（沒寫搬運重量、沒有材質倍率）、一隻就能打、整格擋住")
    check(w.set.setIsThumpable == true and w.set.setMaxHealth == 450 and w.set.setThumpDmg == nil
        and w.set.setBlockAllTheSquare == false, "牆照舊：450 血、打的門檻不變、不整格擋")
    world({ wallN, solidS, crateS, sinkS, sprite("fence_test_01_0", 958, { flags = { "HoppableW", "solid" } }),
        sprite("wood_test_01_0", 954, { flags = { "solidtrans" }, keys = { Material = "Wood", PickUpWeight = "40" } }),
        sprite("top_test_01_0", 955, { flags = { "solid" }, keys = { IsTableTop = "" } }),
        sprite("shelf_test_01_0", 956, { flags = { "solid" }, keys = { MoveType = "WallObject", container = "shelves" } }),
        sprite("rug_test_01_0", 957, { flags = { "solid" }, keys = { MoveType = "FloorRug", Material = "Wood", PickUpWeight = "40" } }) })
    local function put(id, x, name)
        local P = player({ id = id, x = x + 0.5, y = 61.5, here = square(x, 61, 0) })
        P.inv:add(item("Base.Hammer", { HAMMER = true }))
        give(P, { ["Base.Plank"] = 9, ["Base.Nails"] = 9 })
        local sq = square(x, 60, 0)
        return build(P, id, name, { x, 60, 0 }) and sq.objects[1] or nil
    end
    local wo = put(34, 64, "wood_test_01_0")
    check(wo and wo.set.setIsThumpable == true and wo.set.setMaxHealth == 60 and wo.set.setThumpDmg == 1,
        "木頭材質、搬運重量 40：血量 40 × 1.5 = 60、一隻就能打")
    for _, t in ipairs({ { 35, 66, "top_test_01_0", "放在桌上的（IsTableTop）" }, { 36, 68, "shelf_test_01_0", "掛牆的容器" },
        { 37, 70, "rug_test_01_0", "地毯（木頭、搬運重量 40）" } }) do
        local o = put(t[1], t[2], t[3])
        check(o and o.set.setIsThumpable == true and o.set.setMaxHealth == 100 and o.set.setThumpDmg == nil
            and o.set.setBlockAllTheSquare == true, t[4] .. "帶 solid：照原版打得壞，血量 100、thumpDmg 維持預設 8、整格擋住")
    end
    local fo = put(38, 72, "fence_test_01_0")
    check(fo and fo.set.setIsThumpable == true and fo.set.setMaxHealth == 300 and fo.set.setThumpDmg == nil
        and fo.set.setBlockAllTheSquare == false, "帶 solid 的柵欄（格邊種類）：照固定 300 血，不套家具、不整格擋")
end
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
nowMs = nowMs + 181000
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
    M4.inv:add(item("Base.BlowTorch")) -- 原版的噴槍沒有標籤
    local okBT, _, tBT = agree(M4, { items = {}, tools = { "BLOW_TORCH", "WELDING_MASK" } })
    check(okBT and tBT == nil, "噴槍沒有標籤（42.21 的 item BlowTorch 沒有 Tags）：照型別找到，兩邊都不缺")
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
    world({ wallN, sprite("walls_test_01_5", 5005, { flags = { "WallW" }, keys = { WallW = "" } }), solidS, crateS, floorS })
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
    do -- 區域變數包起來：主程式最多 200 個
        local realStair = buildUtil.stairIsBlockingPlacement
        local function edgeCodes(blockNorth) -- 只擋 (56,45) 的某一條邊；回北牆、西牆的結果
            buildUtil.stairIsBlockingPlacement = function(sq, _, north)
                return north == blockNorth and sq:getX() == 56 and sq:getY() == 45
            end
            return Check.item(K, "walls_test_01_4", 0, { 56, 45, 0 }, PV), Check.item(K, "walls_test_01_5", 0, { 56, 45, 0 }, PV)
        end
        local nOnN, wOnN = edgeCodes(true)
        local nOnW, wOnW = edgeCodes(false)
        buildUtil.stairIsBlockingPlacement = realStair
        check(nOnN == "BLOCKED" and wOnN == nil and nOnW == nil and wOnW == "BLOCKED",
            "牆擋到樓梯（底片前面、頂片出口那條邊）：擋下；照牆佔的邊查（北牆 north＝true、西牆 north＝false，照原版木牆）")
    end
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
    check(refund("furniture", { CanScrap = "", Material = "Fabric" }) == "builder",
        "CanScrap 但材質沒有產出（原版拆了沒東西）：本工具拆、照退料表退")
    check(refund("wall", { Material = "Wood" }) == "builder" and refund("furniture", { Material = "Wood" }) == "builder"
        and refund("wall", { CanScrap = "", Material = "Undefined", Material2 = "Wood" }) == "builder"
        and refund("wall", {}) == "builder" and refund("light", {}) == "builder" and refund("stairs", {}) == "builder",
        "不能搬、原版不照材質拆的 IsoThumpable 與燈：本工具拆，每項退 1..v（第一個材質 Undefined 不算能照材質拆）")
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
        for _, r in ipairs({ "pickup", "scrap", "builder", "sheet", "none" }) do want["IGUI_MBLD_Refund_" .. r] = true end
        for code in pairs(Messages.UNBUILD_CODES) do want["IGUI_MBLD_UnbuildRefuse_" .. code] = true end
        want["IGUI_MBLD_Menu_Dismantle"], want["IGUI_MBLD_NotRemoved"] = true, true
        for d = 0, 4 do want["IGUI_MBLD_Face_" .. d] = true end
        for _, t in ipairs({ "HAMMER", "MASONS_TROWEL", "BLOW_TORCH", "WELDING_MASK", "SCREWDRIVER" }) do
            want["IGUI_MBLD_Tool_" .. t] = true
        end
        for _, k in ipairs({ "stairs", "roof", "light", "curtain" }) do want["IGUI_MBLD_Note_" .. k] = true end
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

print("情境二十：第四階段新種類（樓梯、燈、窗簾、屋頂）")
-- 包成函式：區域變數多，放在主區塊的 do…end 會超過主程式 200 個的上限
local function newKinds()
    nowMs = nowMs + 180000 -- 前面的請求、限流都過期
    local BP = { BlocksPlacement = "" }
    local stW = { sprite("stw_01_0", 2101, { type = T.stairsBW, keys = BP }), sprite("stw_01_1", 2102, { type = T.stairsMW, keys = BP }),
        sprite("stw_01_2", 2103, { type = T.stairsTW, keys = BP }) }
    local stN = { sprite("stn_01_2", 2104, { type = T.stairsBN }), sprite("stn_01_1", 2105, { type = T.stairsMN }),
        sprite("stn_01_0", 2106, { type = T.stairsTN }) }
    local landing = sprite("carpentry_02_57", 2107, { flags = { "solidfloor" } })
    local lamp = sprite("lamp_01_0", 2110, { type = T.lightswitch, flags = { "solidtrans" },
        keys = { IsMoveAble = "", lightR = "200", lightG = "180", lightB = "150", LightRadius = "6" } })
    local switch = sprite("switch_01_0", 2111, { type = T.lightswitch })
    local CUR = { MoveType = "WindowObject", IsMoveAble = "", CurtainSound = "Long" }
    local function curtain(name, id, facing, closed)
        local keys = { Facing = facing }
        for k, v in pairs(CUR) do keys[k] = v end
        if closed then keys.IsClosedState = "" end
        return sprite(name, id, { type = T.curtainW, keys = keys })
    end
    local roof = sprite("roof_01_0", 2130, { type = T.WestRoofB, keys = { RoofGroup = "1" } })
    local eave = sprite("roof_01_1", 2131, { type = T.WestRoofT, flags = { "isEave" }, keys = { RoofGroup = "1" } })
    local stE = { sprite("ste_01_0", 2142, { type = T.stairsBW }), sprite("ste_01_1", 2143, { type = T.stairsMW, flags = { "EntityScript" } }),
        sprite("ste_01_2", 2144, { type = T.stairsTW }) }
    local stM = { sprite("stm_01_0", 2145, { type = T.stairsBW }), sprite("stm_01_1", 2146, { type = T.stairsMW, keys = { Material = "Wood" } }),
        sprite("stm_01_2", 2147, { type = T.stairsTW }) }
    -- 另一面（Noffset 指到的另一組 N 型）：stg 三片都合法，stf 的中片是實體
    local function faced(base, id, midFlags)
        return { sprite(base .. "_0", id, { type = T.stairsBW, keys = { Noffset = "5" } }), sprite(base .. "_1", id + 1, { type = T.stairsMW }),
            sprite(base .. "_2", id + 2, { type = T.stairsTW }), sprite(base .. "_3", id + 3, { type = T.stairsTN }),
            sprite(base .. "_4", id + 4, { type = T.stairsMN, flags = midFlags }), sprite(base .. "_5", id + 5, { type = T.stairsBN }) }
    end
    local stF, stG = faced("stf_01", 2160, { "EntityScript" }), faced("stg_01", 2166)
    -- 頂片能拆成零件、底片能搬：原版只拆那一片
    local stS = { sprite("sts_01_0", 2172, { type = T.stairsBW }), sprite("sts_01_1", 2173, { type = T.stairsMW }),
        sprite("sts_01_2", 2174, { type = T.stairsTW, keys = { CanScrap = "" } }) }
    local stI = { sprite("sti_01_0", 2175, { type = T.stairsBW, keys = { IsMoveAble = "" } }), sprite("sti_01_1", 2176, { type = T.stairsMW }),
        sprite("sti_01_2", 2177, { type = T.stairsTW }) }
    local list = { stW[1], stW[2], stW[3], stN[1], stN[2], stN[3], landing, lamp, switch, roof, eave, stE[1], stE[2], stE[3],
        stM[1], stM[2], stM[3], stS[1], stS[2], stS[3], stI[1], stI[2], stI[3],
        curtain("cur_01_0", 2120, "E", true), curtain("cur_01_4", 2121, "E"), curtain("cur_01_1", 2122, "W", true),
        curtain("cur_01_5", 2123, "W"), curtain("cur2_01_0", 2124, "E", true), curtain("cur2_01_4", 2125, "E"),
        curtain("curx_01_4", 2126, "E"), curtain("cur_01_2", 2127, "N", true), curtain("cur_01_6", 2128, "N") }
    for i = 1, 6 do
        list[#list + 1] = stF[i]
        list[#list + 1] = stG[i]
    end
    world(list)
    local function who(id, x, y)
        local p = player({ id = id, x = x, y = y })
        p.inv:add(item("Base.Hammer", { HAMMER = true }))
        return p
    end
    local function at(sq, name) -- 格上第一個叫 name 的物件
        for _, o in ipairs(sq.objects) do if o.name == name or (o.spr and o.spr.name == name) then return o end end
    end

    -- 樓梯：項目＝底片，原點＝頂片；W 型沿 +x、平台在 x−1、上一層
    check(select(2, Entry.resolve("stw_01_1")) == "UNKNOWN" and Entry.resolve("stw_01_0").kind == "stairs",
        "樓梯只收湊得成三格的底片：中片當項目 UNKNOWN")
    check(select(2, Entry.resolve("ste_01_0")) == "UNKNOWN", "樓梯中片是實體（走原版建造）：整組不收")
    check(select(2, Entry.resolve("sts_01_0")) == "UNKNOWN" and select(2, Entry.resolve("sti_01_0")) == "UNKNOWN",
        "樓梯片能拆成零件（頂片 CanScrap）或能搬（底片 IsMoveAble）：原版只拆那一片，整組不收")
    local FP = who(2160, 41.5, 49.5)
    local fe = Entry.resolve("stf_01_0")
    sent = {}
    Server.intent(FP, { n = 1, e = "stf_01_0", d = 1, c = { 41, 49, 0 }, v = Entry.digest() })
    check(fe and Entry.face(fe, 1) == nil and Entry.face(Entry.resolve("stg_01_0"), 1) == stG[6]
        and Check.item(FP, "stf_01_0", 1, { 41, 49, 0 }) == "BAD_FACE"
        and sent[1] and sent[1].cmd == "refused" and sent[1].args.code == "BAD_FACE",
        "樓梯另一面的那組中片是實體：那一面不能選（預覽、伺服器都 BAD_FACE），三片都合法的那一面照常可選")
    local mixed = Cost.forCells("stairs", { stM[3], stM[2], stM[1], landing }, 1)
    check(mixed[1].uniform == true and mixed[1].back == false and Cost.xp(mixed, player()).Woodwork == 47.5,
        "樓梯只有中片有拆解材質（不能搬、不 CanScrap）：三片都本工具拆、整組退一次 1..v，木板 13、釘子 8 平均拿不回 6＋3.5 件")
    local cw, cn = Entry.cells(stW[1]), Entry.cells(stN[1])
    check(#cw == 4 and cw[1][4] == stW[3] and cw[1][5] == "top" and cw[2][1] == 1 and cw[3][1] == 2 and cw[3][4] == stW[1]
        and cw[4][1] == -1 and cw[4][3] == 1 and cw[4][4] == landing and cw[4][5] == "platform"
        and cn[2][2] == 1 and cn[3][2] == 2 and cn[4][2] == -1 and cn[4][3] == 1,
        "樓梯佔地：頂片在原點、中片、底片沿爬的反方向排，平台在頂片前一格的上一層（N 型沿 +y）")
    local sc = Cost.forCells("stairs", { stW[3], stW[2], stW[1], landing }, 1)
    local st = Cost.sum(sc)
    check(sc[1].items["Base.Plank"] == 13 and sc[1].items["Base.Nails"] == 8 and next(sc[2].items) == nil
        and next(sc[4].items) == nil and st.items["Base.Plank"] == 13 and st.tools[1] == "HAMMER",
        "樓梯整組照 Wood_Stairs 收一次（木板 13、釘子 8），收在頂片那一格")
    local ms = Cost.of("stairs", sprite("ms_01_0", 2140, { type = T.stairsBW, keys = { MaterialType = "Metal_Solid" } }))
    local ws = Cost.of("stairs", sprite("ws_01_0", 2141, { type = T.stairsBW, keys = { Material = "Wood" } }))
    check(ms.items["Base.MetalBar"] == 4 and ms.items["Base.SmallSheetMetal"] == 6 and #ms.tools == 2
        and ws.items["Base.Plank"] == 13 and ws.uniform == true and Cost.xp({ ws }, player()).Woodwork == 47.5,
        "金屬樓梯照 Metal_Stairs；有拆解材質的不照拆解產出收，照退料表退 1..v 給經驗")
    for _, q in ipairs({ { 40, 57, 1 }, { 41, 57, 1 }, { 40, 58, 1 }, { 40, 59, 1 }, { 40, 56, 1 }, { 40, 55, 1 } }) do
        square(q[1], q[2], q[3])
    end
    square(40, 60, 1, { solid = true })
    local SP = who(2101, 44.5, 57.5)
    give(SP, { ["Base.Plank"] = 13, ["Base.Nails"] = 8 })
    xpLog = {}
    local sok = build(SP, 1, "stw_01_0", { 41, 57, 0 })
    local T0, M0, B0 = at(squares["41,57,0"], "stw_01_2"), at(squares["42,57,0"], "stw_01_1"), at(squares["43,57,0"], "stw_01_0")
    local plat = squares["40,57,1"]
    check(sok and T0 and M0 and B0 and T0.set.setIsStairs == true and B0.set.setIsStairs == true and T0.north == true
        and T0.mats["Base.Plank"] == "13" and M0.mats["Base.Nails"] == "8" and B0.mats["Base.Plank"] == "13"
        and T0.set.setMaxHealth == 450 and T0.set.setIsThumpable == true and T0.set.setBlockAllTheSquare == true
        and T0.set.setCanPassThrough == true,
        "樓梯三片：IsoThumpable、標成樓梯、450 血、照原版整格擋（BlocksPlacement）、走得過，三片都寫整組的退料")
    check(at(plat, "carpentry_02_57") and plat.md and plat.md.ConnectedToStairsfalse == true
        and SP.inv:count("Base.Plank") == 0 and #xpLog == 1 and xpLog[1].n == 47.5
        and MinidoracatBuilder.Ledger.get(at(plat, "carpentry_02_57")) ~= nil,
        "平台：上一層補原版平台地板（記進帳本：拆樓梯時只拆本 MOD 補的）、記 ConnectedToStairs（同向樓梯不能再蓋在這），整組扣一次料、木工 47.5")
    -- 原版拆一片會整組移除：每片移除前觸發 OnObjectAboutToBeRemoved，本 MOD 的片清掉退料表，別人的照舊
    do
        local realInst = instanceof
        instanceof = function(o, c) return c == "IsoThumpable" and o.mats ~= nil end
        local other = IsoThumpable.new(nil, squares["44,57,0"], "stw_01_0", true, {})
        other.mats["Base.Plank"] = "2"
        for _, o in ipairs({ T0, M0, B0, other }) do
            function o:hasModData() return next(self.md) ~= nil end
            fire("OnObjectAboutToBeRemoved", o)
        end
        instanceof = realInst
        check(next(T0.mats) == nil and next(M0.mats) == nil and next(B0.mats) == nil and other.mats["Base.Plank"] == "2",
            "本 MOD 蓋的物件移出世界前清掉退料表（拆解、打壞都先讀再移除）；不是本 MOD 蓋的不動")
    end
    -- 平台格上有跨到別格的植物（多格）：只拆平台這一片，另一片（沒驗證過的格子）留著
    local pq, pn = square(40, 53, 1), square(39, 53, 1)
    local grp = {}
    local mine, theirs = oldPiece(pq, grp, "vegitation"), oldPiece(pn, grp, "vegitation")
    local SP2 = who(2108, 44.5, 53.5)
    give(SP2, { ["Base.Plank"] = 13, ["Base.Nails"] = 8 })
    local pok = build(SP2, 1, "stw_01_0", { 41, 53, 0 })
    local function has(sq, o)
        for _, v in ipairs(sq.objects) do if v == o then return true end end
        return false
    end
    check(pok and at(pq, "carpentry_02_57") and not has(pq, mine) and has(pn, theirs),
        "補平台地板：平台格的舊植物只拆這一片，跨到旁邊那格的另一片不動")
    -- N 型（往北爬）：頂片在原點、中片底片沿 +y，平台在頂片北邊一格的二樓，記 ConnectedToStairstrue；三片 north＝false
    local npl = square(47, 40, 1)
    local SN = who(2109, 48.5, 42.5)
    give(SN, { ["Base.Plank"] = 13, ["Base.Nails"] = 8 })
    local nok = build(SN, 1, "stn_01_2", { 47, 41, 0 })
    local TN, BN = at(squares["47,41,0"], "stn_01_0"), at(squares["47,43,0"], "stn_01_2")
    check(nok and TN and at(squares["47,42,0"], "stn_01_1") and BN and TN.north == false and TN.mats["Base.Plank"] == "13"
        and at(npl, "carpentry_02_57") and npl.md and npl.md.ConnectedToStairstrue == true,
        "N 型樓梯：三片沿 +y、north＝false，平台在北邊一格的二樓、記 ConnectedToStairstrue")
    check(Check.item(who(2110, 46.5, 45.5), "stw_01_0", 0, { 50, 45, 0 }) == "TOO_FAR",
        "樓梯的距離只看三片：離平台近（3 格）、離頂片 4 格，太遠")
    local cs = square(42, 55, 0)
    cs:getModData().ConnectedToStairsfalse = true
    square(42, 56, 0, { flags = { water = true } })
    square(42, 58, 1, { floor = {} })
    square(41, 59, 1, { wallW = {} })
    local function stairsCode(y)
        local code, extra = Check.item(who(2102, 44.5, y + 0.5), "stw_01_0", 0, { 41, y, 0 })
        return code, extra and extra.x, extra and extra.z
    end
    local c1, x1 = stairsCode(58)
    local c2, x2 = stairsCode(59)
    local c3, x3, z3 = stairsCode(60)
    local c4, x4 = stairsCode(56)
    local c5, x5 = stairsCode(55)
    check(c1 == "BLOCKED" and x1 == 42 and c2 == "BLOCKED" and x2 == 41 and c3 == "BLOCKED" and x3 == 40 and z3 == 1
        and c4 == "BLOCKED" and x4 == 42 and c5 == "BLOCKED" and x5 == 42,
        "樓梯擋下：片的正上方有地板、頂片上一層朝平台那邊有牆、平台實心、片在水上、片在同向樓梯的平台上")

    -- 燈：IsoLightSwitch；可搬又帶 lightR 的另收燈泡（拿得下來），燈泡不給經驗
    local made = {}
    IsoLightSwitch = { new = function(_, sq, spr, room)
        local o = { spr = spr, room = room, md = {}, lights = 0 }
        function o:addLightSourceFromSprite() if spr:getProperties():has("lightR") then self.lights = self.lights + 1 end end
        function o:setActivated(v) self.on = v end
        function o:setRenderYOffset(v) self.yoff = v end
        function o:setMovedThumpable(v) self.moved = v end
        function o:getModData() return self.md end
        function o:setExplored() end
        function o:transmitCompleteItemToClients() self.sent = true end
        function o:getSquare() return sq end
        function o:getSprite() return spr end
        made[#made + 1] = o
        return o
    end }
    ISMoveableSpriteProps = { new = function() return { canPlaceMoveableInternal = function() return true end } end }
    local lc = Cost.of("light", lamp, 0)
    check(lc.items["Base.LightBulb"] == 1 and lc.items["Base.ElectronicsScrap"] == nil and lc.tools[1] == "SCREWDRIVER",
        "可搬的燈：燈泡倍率 0 也收 1 個（拿得下來），其他基本價照倍率免")
    local LP = player({ id = 2103, x = 51.5, y = 57.5 })
    LP.inv:add(item("Base.Screwdriver", { SCREWDRIVER = true }))
    give(LP, { ["Base.ElectronicsScrap"] = 1, ["Base.ElectricWire"] = 1 })
    local lok, _, la = build(LP, 1, "lamp_01_0", { 50, 57, 0 })
    check(not lok and la.code == "NO_MATERIAL" and la.need["Base.LightBulb"] == 1 and #made == 0, "缺燈泡：NO_MATERIAL、不放")
    give(LP, { ["Base.LightBulb"] = 1 })
    xpLog = {}
    lok = build(LP, 2, "lamp_01_0", { 50, 57, 0 })
    local L = made[1]
    check(lok and L and L.lights == 1 and L.on == true and L.moved == true and L.sent and L.md.builderEntry == "lamp_01_0"
        and squares["50,57,0"].objects[1] == L and LP.inv:count("Base.LightBulb") == 0
        and #xpLog == 1 and xpLog[1].perk == "perk:Electricity" and xpLog[1].n == 10,
        "燈：建 IsoLightSwitch、照 sprite 掛光源、開著、擋路的殭屍打得壞；電工 10（燈泡不算）")
    local SW = player({ id = 2104, x = 51.5, y = 58.5 })
    SW.inv:add(item("Base.Screwdriver", { SCREWDRIVER = true }))
    give(SW, { ["Base.ElectronicsScrap"] = 1, ["Base.ElectricWire"] = 1 })
    xpLog = {}
    check(build(SW, 1, "switch_01_0", { 50, 58, 0 }) and made[2] and made[2].lights == 0 and made[2].moved == nil
        and #xpLog == 0 and MinidoracatBuilder.Ledger.get(made[2])["Base.ElectricWire"] == 1,
        "牆面開關（沒有 lightR、不能搬）：照樣是 IsoLightSwitch、不掛光源、不收燈泡；記進帳本，本工具拆時各 1 件一定全退，不給經驗")
    ISMoveableSpriteProps = nil

    -- 窗簾：掛在窗框上；面向 E 的窗框在本格西邊，面向 W 的在東邊那格
    local function framed(x, y, extra, owner)
        local flags = { WindowW = true }
        for k, v in pairs(extra or {}) do flags[k] = v end
        local sq = square(x, y, 0, { flags = flags, owner = owner })
        local props = { has = function(_, k) return (type(k) == "table" and k.name or k) == "WindowW" end,
            get = function() return nil end }
        sq.objects[1] = { getProperties = function() return props end, getSprite = function() return nil end }
        return sq
    end
    local cq = framed(53, 57)
    local other = { getProperties = function() return { has = function() return false end, get = function() return nil end } end,
        getSprite = function() return nil end }
    cq.objects[2] = other
    framed(53, 58, { exterior = true })
    square(53, 59, 0)
    local CP = player({ id = 2105, x = 54.5, y = 57.5 })
    local function cur(name, x, y) return (Check.item(CP, name, 0, { x, y, 0 })) end
    check(cur("cur_01_4", 53, 57) == nil and cur("cur_01_5", 52, 57) == nil,
        "窗簾：面向 E 掛在本格的窗框、面向 W 掛在東邊那格的窗框")
    check(cur("cur_01_4", 53, 58) == "BLOCKED" and cur("cur_01_4", 53, 59) == "BLOCKED" and cur("curx_01_4", 53, 57) == "BLOCKED"
        and cur("cur_01_5", 53, 57) == "BLOCKED",
        "窗簾擋下：室外（沒有房間、沒有屋頂）、沒有窗框、關著那張（−4 號）不存在、窗框在另一邊")
    framed(57, 57, nil, "e2e_other")
    check(cur("cur_01_5", 56, 57) == "SAFEHOUSE", "面向 W 的窗簾：東邊窗框那格是別人的安全屋，擋下（窗簾那格不是）")
    square(54, 55, 0)
    square(54, 56, 0, { owner = "e2e_other" })
    check(cur("cur_01_6", 54, 55) == "SAFEHOUSE", "面向 N 的窗簾：南邊窗框那格是別人的安全屋，擋下（窗簾那格不是）")
    IsoCurtain = { new = function(_, sq, name, north)
        local o = { name = name, north = north, md = {} }
        function o:getModData() return self.md end
        function o:setExplored() end
        function o:transmitCompleteItemToClients() end
        function o:getSquare() return sq end
        function o:getSprite() return spriteMap[name] end
        function o:getProperties() return spriteMap[name]:getProperties() end
        function o:getType() return spriteMap[name]:getType() end
        return o
    end }
    check(Cost.of("curtain", spriteMap["cur_01_4"], 0).items["Base.Sheet"] == 2
        and Cost.of("curtain", sprite("cs_01_4", 2150, { type = T.curtainW, keys = { MoveType = "WindowObject" } }), 0).items["Base.Sheet"] == 1
        and #Cost.of("curtain", spriteMap["cur_01_4"]).tools == 0,
        "窗簾：長窗簾 2 張床單、其他 1 張，倍率 0 也照收（移除窗簾退 1 張）；不要工具")
    give(CP, { ["Base.Sheet"] = 2 })
    xpLog = {}
    local cok = build(CP, 1, "cur_01_4", { 53, 57, 0 })
    local co = cq.objects[2]
    check(cok and co and co.name == "cur_01_4" and co.north == false and cq.objects[3] == other and co.md.builderEntry == "cur_01_4"
        and CP.inv:count("Base.Sheet") == 0 and #xpLog == 0,
        "窗簾：IsoCurtain（面向 E 不是 north）、插在窗框後面、扣 2 張床單、不給經驗")
    check(cur("cur2_01_4", 53, 57) == "BLOCKED", "同一面已經有窗上物件：擋下")
    local sheet = framed(55, 59)
    local free = cur("cur_01_4", 55, 59)
    sheet.objects[2] = { getProperties = function() return { has = function() return false end, get = function() return nil end } end,
        getType = function() return T.curtainW end, getSprite = function() return nil end, isCurtain = true }
    local realInstanceof = instanceof
    instanceof = function(o, cls) return cls == "IsoCurtain" and o.isCurtain == true end
    check(free == nil and cur("cur_01_4", 55, 59) == "BLOCKED", "同一面掛著床單窗簾：擋下（原版搬家具同規則）")
    instanceof = realInstanceof

    -- 屋頂：二樓起、要有東西撐著（正下方有牆、四鄰有地板或屋頂）；殭屍不打、不擋整格、重算有沒有屋頂
    square(56, 57, 0, { wallW = {} })
    square(56, 57, 1)
    square(57, 57, 1)
    square(58, 58, 1)
    square(59, 57, 0, { stairs = true, wallW = {} })
    square(59, 57, 1)
    square(59, 58, 0, { wallN = {} })
    local RP = who(2106, 57.5, 57.5)
    local PV = { preview = true }
    check(Check.item(RP, "roof_01_0", 0, { 58, 58, 1 }) == "BLOCKED" and Check.item(RP, "roof_01_0", 0, { 56, 58, 0 }) == "BLOCKED"
        and Check.item(RP, "roof_01_0", 0, { 59, 57, 1 }) == "BLOCKED",
        "屋頂擋下：沒有東西撐著、蓋在一樓、正下方是樓梯")
    check(Check.item(RP, "roof_01_0", 0, { 58, 59, 1 }, PV) == "BLOCKED" and Check.item(RP, "roof_01_0", 0, { 59, 58, 1 }, PV) == nil
        and squares["58,59,1"] == nil and squares["59,58,1"] == nil,
        "預覽：上一層的格子還沒建也照座標查撐不撐得住（不補格子）")
    check(Cost.of("roof", eave).items["Base.Nails"] == 1 and Cost.of("roof", roof).items["Base.Nails"] == 2,
        "屋頂木板 1、釘子 2；屋簷釘子 1")
    give(RP, { ["Base.Plank"] = 2, ["Base.Nails"] = 4 })
    HARNESS_ROOF = 0
    local rok = build(RP, 1, "roof_01_0", { 56, 57, 1 })
    local R1 = squares["56,57,1"].objects[1]
    check(rok and R1 and R1.name == "roof_01_0" and R1.set.setIsThumpable == false and R1.set.setBlockAllTheSquare == false
        and R1.set.setCanPassThrough == true and R1.mats["Base.Nails"] == "2" and HARNESS_ROOF == 1,
        "屋頂：IsoThumpable、殭屍不打、不擋整格、寫退料，伺服器重算下面幾層有沒有屋頂")
    check(build(RP, 2, "roof_01_0", { 57, 57, 1 }) and squares["57,57,1"].objects[1],
        "旁邊已經有屋頂：撐得住（照常蓋）")
    -- 一排屋頂：只有第一格正下方有牆，後面的格子靠前一格（還沒蓋）撐著；從沒支撐的那頭拖，只有靠牆那格可蓋
    square(56, 60, 0, { wallW = {} })
    local row = { { 56, 60, 1 }, { 57, 60, 1 }, { 58, 60, 1 } }
    local _, okF = MinidoracatBuilder.Cursor.preview(RP, "roof_01_0", 0, row, nil)
    local resB, okB = MinidoracatBuilder.Cursor.preview(RP, "roof_01_0", 0, { row[3], row[2], row[1] }, nil)
    check(okF == 3 and okB == 1 and resB[1].code == "BLOCKED" and resB[2].code == "BLOCKED" and resB[3].code == nil,
        "一排屋頂：前面可蓋的格子撐得住後面的（從有牆那頭拖整排可蓋，反過來只有靠牆那格）")
end
newKinds()

print("情境二十一：第五階段拆除與帳本（本工具拆、退 1..v、帳本、身分、拒絕條件）")
local function dismantleScenario()
    nowMs = nowMs + 180000
    local Dismantle, Ledger = MinidoracatBuilder.Dismantle, MinidoracatBuilder.Ledger
    local realInst = instanceof
    instanceof = function(o, cls) return type(o) == "table" and o.class == cls end
    -- 一塊 70..77 × 70..77 的空地（BFS 找路要鄰格），移除時照引擎先觸發 OnObjectAboutToBeRemoved
    local function engineSq(x, y, z, o)
        local sq = square(x, y, z, o)
        local orig = sq.transmitRemoveItemFromSquare
        sq.dropped = {}
        function sq:transmitRemoveItemFromSquare(obj, safely)
            fire("OnObjectAboutToBeRemoved", obj)
            return orig(self, obj, safely)
        end
        function sq:AddWorldInventoryItem(ft) self.dropped[ft] = (self.dropped[ft] or 0) + 1 end
        return sq
    end
    for x = 70, 77 do for y = 70, 77 do engineSq(x, y, 0) end end
    local function at(x, y, z) return squares[x .. "," .. y .. "," .. z] end
    -- 本 MOD 蓋的物件（modData 有 builderEntry）；mats＝退料表（字串，照 Java 欄位）。多格：group＝同一組（同一個原點），
    -- cands＝引擎 getSpriteGridObjectsIncludingSelf 收到的（同一張 sprite grid、不看原點，可能混到別組）
    local function ours(sq, spr, mats, class)
        local o = { class = class or "IsoThumpable", mats = mats or {}, md = { builderEntry = spr:getName() } }
        function o:getSprite() return spr end
        function o:getSquare() return sq end
        function o:hasModData() return true end
        function o:getModData() return self.md end
        function o:isDismantable() return true end
        function o:getBuildMaterials() return self.mats end
        function o:isObjectNoContainerOrEmpty() return not self.full end
        function o:getSpriteGridObjectsIncludingSelf() return javaList(self.cands or self.group or { self }) end
        function o:isConnectedSpriteGridObject(x) return x == self or (self.group ~= nil and self.group == x.group) end
        function o:isStairsObject() return Rules.typeCode(spr:getType()) == "stairs" end
        function o:hasFluid() return self.fluid == true end
        function o:isBarricaded() return self.barricaded == true end
        function o:getProperties() return spr:getProperties() end
        function o:getTextureName() return spr:getName() end
        function o:getType() return spr:getType() end
        sq.objects[#sq.objects + 1] = o
        return o
    end
    local function has(sq, o) for _, v in ipairs(sq.objects) do if v == o then return true end end return false end
    local function hammerer(id, x, y, here, extra)
        extra = extra or {}
        extra.id, extra.x, extra.y, extra.here = id, x, y, here
        local p = player(extra)
        p.inv:add(item("Base.Hammer", { HAMMER = true }))
        return p
    end
    local function lastSent() return sent[#sent] and sent[#sent].cmd, sent[#sent] and sent[#sent].args or {} end
    local function unbuild(p, n, x, y, z, e)
        sent = {}
        Server.dismantleIntent(p, { n = n, x = x, y = y, z = z, e = e })
        return lastSent()
    end
    local wallS = sprite("dw_01_0", 2201, { keys = { WallN = "" } })
    local floorS = sprite("df_01_0", 2202, { flags = { "solidfloor" } })
    local boxS = sprite("db_01_0", 2203, { keys = { container = "" } })
    local chairS = sprite("dc_01_0", 2204, { keys = { IsMoveAble = "" } })
    local switchS = sprite("dl_01_0", 2205, { type = T.lightswitch })
    local stS = { sprite("ds_01_0", 2206, { type = T.stairsBW }), sprite("ds_01_1", 2207, { type = T.stairsMW }),
        sprite("ds_01_2", 2208, { type = T.stairsTW }) }
    local landS = sprite(Entry.STAIR_FLOOR, 2209, { flags = { "solidfloor" } })
    local roofS = sprite("dr_01_0", 2210, { type = T.WestRoofB, keys = { RoofGroup = "1" } })
    local here = at(71, 71, 0)
    local P = hammerer(2201, 71.5, 71.5, here)

    -- 牆：身分照請求、退料先讀再移除、每項 1..v、同一筆不拆兩次
    local W = ours(at(72, 71, 0), wallS, { ["Base.Plank"] = "4", ["Base.Nails"] = "6" })
    check(Dismantle.kindOf(W) == "wall" and (unbuild(P, 1, 72, 71, 0, "dw_01_0")) == "dismantleAccepted",
        "本 MOD 蓋的牆：認得出來，拆除請求收下")
    local O = hammerer(2202, 71.5, 72.5, here)
    sent = {}
    check(Server.dismantle(O, 1) == false and has(at(72, 71, 0), W) and #sent == 0,
        "別的玩家拿同一個 nonce：沒有請求，不拆、MP 不回覆")
    HARNESS_ROLL = "max"
    check(Server.dismantle(P, 1) == true and not has(at(72, 71, 0), W) and here.dropped["Base.Plank"] == 4
        and here.dropped["Base.Nails"] == 6 and next(W.mats) == nil and (lastSent()) == "dismantled",
        "拆牆：移除、照退料表退到玩家腳下（最多全部）；移除前退料表已清空（先讀再移除）")
    sent = {}
    check(Server.dismantle(P, 1) == false and here.dropped["Base.Plank"] == 4,
        "同一筆請求再送一次：不再拆、不再退")
    HARNESS_ROLL = "min"
    here.dropped = {}
    local W2 = ours(at(72, 72, 0), wallS, { ["Base.Plank"] = "4", ["Base.Nails"] = "6" })
    unbuild(P, 2, 72, 72, 0, "dw_01_0")
    check(Server.dismantle(P, 2) and here.dropped["Base.Plank"] == 1 and here.dropped["Base.Nails"] == 1 and not has(at(72, 72, 0), W2),
        "每項至少退 1 件")
    HARNESS_ROLL = "max"

    -- 拒絕：不在範圍內的照樣留著
    local far = hammerer(2203, 76.5, 76.5, at(76, 76, 0))
    local W3 = ours(at(72, 73, 0), wallS, { ["Base.Plank"] = "4" })
    unbuild(far, 3, 72, 73, 0, "dw_01_0")
    Server.dismantle(far, 3)
    local c, a = lastSent()
    check(c == "dismantleRefused" and a.code == "TOO_FAR" and has(at(72, 73, 0), W3), "太遠：TOO_FAR、不拆")
    check(Dismantle.check(far, "wall", Dismantle.plan(W3, "wall"), true) == nil, "右鍵選單預覽不查距離（選了會先走過去）")
    local bare = player({ id = 2204, x = 71.5, y = 73.5, here = here })
    unbuild(bare, 4, 72, 73, 0, "dw_01_0")
    Server.dismantle(bare, 4)
    c, a = lastSent()
    check(c == "dismantleRefused" and a.code == "NO_TOOL" and a.tools[1] == "HAMMER" and has(at(72, 73, 0), W3),
        "沒帶工具（和蓋的時候一樣）：NO_TOOL、列出缺的工具")
    local cheat = player({ id = 2205, x = 71.5, y = 73.5, here = here, cheat = true })
    check(Dismantle.check(cheat, "wall", Dismantle.plan(W3, "wall")) == nil, "建造作弊：不查工具")
    local owned = engineSq(70, 75, 0, { owner = "someone" })
    local W4 = ours(owned, wallS, { ["Base.Plank"] = "4" })
    local SP = hammerer(2206, 70.5, 74.5, at(70, 74, 0))
    unbuild(SP, 5, 70, 75, 0, "dw_01_0")
    Server.dismantle(SP, 5)
    c, a = lastSent()
    check(c == "dismantleRefused" and a.code == "SAFEHOUSE" and has(owned, W4), "別人的安全屋：SAFEHOUSE、不拆")
    local B = ours(at(73, 71, 0), boxS, { ["Base.Plank"] = "2" })
    B.full = true
    unbuild(P, 6, 73, 71, 0, "db_01_0")
    Server.dismantle(P, 6)
    c, a = lastSent()
    check(c == "dismantleRefused" and a.code == "NOT_EMPTY" and has(at(73, 71, 0), B), "容器裡還有東西：NOT_EMPTY、不拆（不讓內容物消失）")
    local ch = ours(at(73, 72, 0), chairS, { ["Base.Plank"] = "2" })
    unbuild(P, 7, 73, 72, 0, "dc_01_0")
    Server.dismantle(P, 7)
    c, a = lastSent()
    check(Dismantle.kindOf(ch) == nil and c == "dismantleRefused" and a.code == "GONE" and has(at(73, 72, 0), ch),
        "能搬的（照原版拿起）不歸本工具拆：找不到可拆的那件（GONE）")

    -- 燈只認帳本：帳本沒記的不拆；帳本裡的照帳本退，移出世界時帳本清掉
    check(type(HARNESS_GOS_KEYS.MinidoracatBuilder) == "table" and HARNESS_GOS_KEYS.MinidoracatBuilder[1] == "built",
        "帳本存檔白名單有 built（漏了重開後帳本消失）")
    local fake = ours(at(74, 71, 0), switchS, nil, "IsoLightSwitch")
    local LP = hammerer(2209, 73.5, 71.5, at(73, 71, 0))
    LP.inv:add(item("Base.Screwdriver", { SCREWDRIVER = true }))
    unbuild(LP, 8, 74, 71, 0, "dl_01_0")
    Server.dismantle(LP, 8)
    c, a = lastSent()
    check(c == "dismantleRefused" and a.code == "NOT_OURS" and has(at(74, 71, 0), fake),
        "燈的 modData 有 builderEntry、帳本沒記：NOT_OURS、不拆不退")
    local L = ours(at(74, 72, 0), switchS, nil, "IsoLightSwitch")
    Ledger.put(L, { ["Base.ElectronicsScrap"] = 1, ["Base.ElectricWire"] = 1 })
    unbuild(LP, 9, 74, 72, 0, "dl_01_0")
    check(Server.dismantle(LP, 9) and at(73, 71, 0).dropped["Base.ElectricWire"] == 1 and not has(at(74, 72, 0), L)
        and Ledger.get(L) == nil, "帳本裡的燈：照帳本退、移除時帳本清掉")

    -- 樓梯：三片加本 MOD 補的平台（帳本有記）一起拆，只照被點的那片退一次；清掉平台格的 ConnectedToStairs
    local function landingAt(sq)
        local l = {}
        function l:getSprite() return landS end
        function l:getSquare() return sq end
        function l:isStairsObject() return false end
        sq.objects[#sq.objects + 1] = l
        return l
    end
    local plat = engineSq(73, 73, 1)
    plat:getModData().ConnectedToStairsfalse = true
    local T0 = ours(at(74, 73, 0), stS[3], { ["Base.Plank"] = "13", ["Base.Nails"] = "8" })
    local M0 = ours(at(75, 73, 0), stS[2], { ["Base.Plank"] = "13", ["Base.Nails"] = "8" })
    local B0 = ours(at(76, 73, 0), stS[1], { ["Base.Plank"] = "13", ["Base.Nails"] = "8" })
    local landing = landingAt(plat)
    Ledger.put(landing, {})
    local realStairs = buildUtil.getStairObjects
    buildUtil.getStairObjects = function() return { T0, M0, B0, landing } end -- 原版收三片＋旁邊沒地板的平台
    local SP2 = hammerer(2207, 75.5, 72.5, at(75, 72, 0))
    unbuild(SP2, 10, 75, 73, 0, "ds_01_1")
    check(Server.dismantle(SP2, 10) and not has(at(74, 73, 0), T0) and not has(at(75, 73, 0), M0)
        and not has(at(76, 73, 0), B0) and not has(plat, landing) and plat.md.ConnectedToStairsfalse == nil
        and at(75, 72, 0).dropped["Base.Plank"] == 13 and at(75, 72, 0).dropped["Base.Nails"] == 8 and Ledger.get(landing) == nil,
        "樓梯：點中片，三片與平台一起拆、只退一組、平台格的 ConnectedToStairs 清掉、帳本的平台清掉")

    -- 樓梯有一片沒有記號：整組不拆、不退（三片要一起拆、只退一組）
    local SP3 = hammerer(2210, 75.5, 75.5, at(75, 75, 0))
    local plat1 = engineSq(73, 76, 1)
    local T1 = ours(at(74, 76, 0), stS[3], { ["Base.Plank"] = "13" })
    local M1 = ours(at(75, 76, 0), stS[2], { ["Base.Plank"] = "13" })
    local B1 = ours(at(76, 76, 0), stS[1], { ["Base.Plank"] = "13" })
    local land1 = landingAt(plat1)
    Ledger.put(land1, {})
    ours(plat1, wallS, {}) -- 平台上蓋了牆
    M1.md.builderEntry = false -- 記號要有值（和 Place.onAboutToBeRemoved 同一個判斷），false 不算
    buildUtil.getStairObjects = function() return { T1, M1, B1, land1 } end
    unbuild(SP3, 14, 74, 76, 0, "ds_01_2")
    Server.dismantle(SP3, 14)
    c, a = lastSent()
    check(c == "dismantleRefused" and a.code == "NOT_OURS" and has(at(74, 76, 0), T1) and has(at(75, 76, 0), M1)
        and has(at(76, 76, 0), B1) and next(at(75, 75, 0).dropped) == nil, "樓梯有一片的記號是 false：整組不拆、不退")
    M1.md.builderEntry = "ds_01_1"
    unbuild(SP3, 15, 74, 76, 0, "ds_01_2")
    check(Server.dismantle(SP3, 15) and not has(at(75, 76, 0), M1) and has(plat1, land1) and Ledger.get(land1) ~= nil,
        "平台上還有別的東西（牆）：拆樓梯、平台留著")
    -- 別方向的樓梯片不算這一組；平台不在帳本（蓋樓梯時那格原本就有地板）
    local plat2 = engineSq(73, 77, 1)
    local T2 = ours(at(74, 77, 0), stS[3], { ["Base.Plank"] = "13" })
    local M2 = ours(at(75, 77, 0), stS[2], { ["Base.Plank"] = "13" })
    local B2 = ours(at(76, 77, 0), stS[1], { ["Base.Plank"] = "13" })
    local NM = ours(at(75, 77, 0), sprite("dsn_01_1", 2211, { type = T.stairsMN }), { ["Base.Plank"] = "13" })
    local land2 = landingAt(plat2)
    local platN = engineSq(75, 76, 1) -- 別方向那組的平台（也是本 MOD 補的），不是這一組的
    local landN = landingAt(platN)
    Ledger.put(landN, {})
    buildUtil.getStairObjects = function() return { T2, M2, NM, B2, land2, landN } end
    unbuild(SP3, 16, 74, 77, 0, "ds_01_2")
    check(Server.dismantle(SP3, 16) and not has(at(74, 77, 0), T2) and not has(at(75, 77, 0), M2)
        and not has(at(76, 77, 0), B2) and has(at(75, 77, 0), NM) and has(plat2, land2)
        and has(platN, landN) and Ledger.get(landN) ~= nil,
        "別方向的樓梯片與它的平台不算這一組（不拆）；這一組的平台不在帳本（原本就有的地板）：留著")
    -- 平台在別人的安全屋
    local plat3 = engineSq(73, 76, 1, { owner = "someone" })
    local T3 = ours(at(74, 76, 0), stS[3], { ["Base.Plank"] = "13" })
    local M3 = ours(at(75, 76, 0), stS[2], { ["Base.Plank"] = "13" })
    local B3 = ours(at(76, 76, 0), stS[1], { ["Base.Plank"] = "13" })
    local land3 = landingAt(plat3)
    Ledger.put(land3, {})
    buildUtil.getStairObjects = function() return { T3, M3, B3, land3 } end
    unbuild(SP3, 17, 74, 76, 0, "ds_01_2")
    check(Server.dismantle(SP3, 17) and not has(at(75, 76, 0), M3) and has(plat3, land3), "平台在別人的安全屋：拆樓梯、平台留著")
    buildUtil.getStairObjects = realStairs

    -- 多格：同一組（同一個原點）整組拆、每片照自己的退料表退；引擎一起收到的別組那片（同一張 grid、原點不同）不拆
    local GA = ours(at(71, 75, 0), boxS, { ["Base.Plank"] = "2" })
    local GB = ours(at(72, 75, 0), boxS, { ["Base.Plank"] = "2" })
    local GX = ours(at(72, 75, 0), boxS, { ["Base.Plank"] = "2" })
    local g = { GA, GB }
    GA.group, GB.group, GX.group = g, g, { GX }
    GA.cands = { GA, GB, GX }
    local GP = hammerer(2208, 71.5, 74.5, at(71, 74, 0))
    unbuild(GP, 11, 71, 75, 0, "db_01_0")
    check(Server.dismantle(GP, 11) and not has(at(71, 75, 0), GA) and not has(at(72, 75, 0), GB) and has(at(72, 75, 0), GX)
        and at(71, 74, 0).dropped["Base.Plank"] == 4, "多格：同一組整組拆、每片照自己的退料表退（2＋2）；原點不同的別組那片不拆")
    -- 同一組有一片沒有記號：整組不拆、不退
    local GC = ours(at(73, 74, 0), boxS, { ["Base.Plank"] = "2" })
    local GD = ours(at(74, 74, 0), boxS, { ["Base.Plank"] = "2" })
    GD.md.builderEntry = nil
    local g2 = { GC, GD }
    GC.group, GD.group, GC.cands = g2, g2, { GC, GD }
    unbuild(GP, 22, 73, 74, 0, "db_01_0")
    Server.dismantle(GP, 22)
    c, a = lastSent()
    check(c == "dismantleRefused" and a.code == "NOT_OURS" and has(at(73, 74, 0), GC) and has(at(74, 74, 0), GD)
        and at(71, 74, 0).dropped["Base.Plank"] == 4, "多格：同一組有一片沒有本 MOD 的記號：整組不拆、不退")

    -- 原版拆解擋的：集水的裡面有水、門框裝著門、窗框釘著木板、樓梯頂端接著的地板；移除沒生效不退料
    local WP = hammerer(2211, 75.5, 70.5, at(75, 70, 0))
    local WC = ours(at(77, 72, 0), sprite("dwc_01_0", 2212, { keys = { container = "", IsWaterCollector = "" } }),
        { ["Base.Plank"] = "2" })
    WC.fluid = true
    unbuild(WP, 18, 77, 72, 0, "dwc_01_0")
    Server.dismantle(WP, 18)
    c, a = lastSent()
    check(c == "dismantleRefused" and a.code == "NOT_EMPTY" and has(at(77, 72, 0), WC), "集水的裡面有水：NOT_EMPTY、不拆")
    local DF = ours(at(74, 72, 0), sprite("ddf_01_0", 2213, { flags = { "DoorWallN" }, keys = { DoorWallN = "" } }),
        { ["Base.Plank"] = "4" })
    at(74, 72, 0).getDoor = function(_, dir)
        assert(dir == GridSquareEdgeFacingDirection.NORTH_SOUTH or dir == GridSquareEdgeFacingDirection.EAST_WEST,
            "getDoor takes GridSquareEdgeFacingDirection")
        return dir == GridSquareEdgeFacingDirection.NORTH_SOUTH and {} or nil
    end
    local WF = ours(at(74, 70, 0), sprite("dwf_01_0", 2214, { flags = { "WindowN" }, keys = { WindowN = "" } }),
        { ["Base.Plank"] = "4" })
    WF.barricaded = true
    engineSq(77, 71, 0, { flags = { stairsTW = true } }) -- 往西爬的樓梯頂片：在二樓那格東邊的下一層
    local UF = ours(engineSq(76, 71, 1), floorS, { ["Base.Plank"] = "1" })
    local codes = {}
    for i, t in ipairs({ { DF, "doorFrame" }, { WF, "windowFrame" }, { UF, "floor" } }) do
        codes[i] = tostring((Dismantle.check(WP, t[2], Dismantle.plan(t[1], t[2]))))
    end
    check(codes[1] == "ATTACHED" and codes[2] == "ATTACHED" and codes[3] == "STAIRS_TOP",
        "門框裝著門、窗框釘著木板：ATTACHED；樓梯頂端接著的二樓地板：STAIRS_TOP（" .. table.concat(codes, ",") .. "）")
    -- 窗框裝著窗（getWindow 照邊方向查）：ATTACHED；空的窗框照常能拆（preview：不看距離）
    local wfS = sprite("dwf_01_0", 2214, { flags = { "WindowN" }, keys = { WindowN = "" } })
    local WW = ours(engineSq(75, 69, 0, { windows = { [GridSquareEdgeFacingDirection.NORTH_SOUTH] = {} } }), wfS,
        { ["Base.Plank"] = "4" })
    local WB = ours(engineSq(76, 69, 0), wfS, { ["Base.Plank"] = "4" })
    local cw = tostring((Dismantle.check(WP, "windowFrame", Dismantle.plan(WW, "windowFrame"), true)))
    local cb = tostring((Dismantle.check(WP, "windowFrame", Dismantle.plan(WB, "windowFrame"), true)))
    check(cw == "ATTACHED" and cb == "nil", "窗框裝著窗：ATTACHED；空的窗框能拆（" .. cw .. "," .. cb .. "）")
    local stuck = engineSq(76, 72, 0)
    function stuck:transmitRemoveItemFromSquare() return -1 end -- 引擎沒移掉（錯誤被 Kahlua 吞掉，pcall 看不到）
    local WS = ours(stuck, wallS, { ["Base.Plank"] = "4" })
    unbuild(WP, 19, 76, 72, 0, "dw_01_0")
    Server.dismantle(WP, 19)
    c, a = lastSent()
    check(c == "dismantleRefused" and a.code == "INTERNAL" and has(stuck, WS) and next(at(75, 70, 0).dropped) == nil,
        "移除沒生效：INTERNAL、不退料")
    sb.WhereCanBuild = 2
    local WW = ours(at(74, 71, 0), wallS, { ["Base.Plank"] = "4" })
    unbuild(WP, 20, 74, 71, 0, "dw_01_0")
    check(Server.dismantle(WP, 20) and not has(at(74, 71, 0), WW), "只能在安全屋內蓋（WhereCanBuild=2）：拆除不看，安全屋外照樣能拆")
    sb.WhereCanBuild = nil
    local WE = ours(at(77, 70, 0), wallS, { ["Base.Plank"] = "4" })
    unbuild(WP, 21, 77, 70, 0, "dw_01_0")
    nowMs = nowMs + 181000
    check(Server.dismantle(WP, 21) == false and has(at(77, 70, 0), WE), "請求過期（走太久）：不拆")

    -- 地板：一樓拆了換泥土；二樓以上格上還有東西不拆
    local F0 = ours(at(73, 75, 0), floorS, { ["Base.Plank"] = "1" })
    unbuild(GP, 12, 73, 75, 0, "df_01_0")
    local dirt
    if Server.dismantle(GP, 12) then
        for _, o in ipairs(at(73, 75, 0).objects) do if o.name == "blends_natural_01_64" then dirt = o end end
    end
    check(dirt and not has(at(73, 75, 0), F0), "一樓的地板拆了換泥土（照原版）")
    local up = engineSq(72, 76, 1)
    local F1 = ours(up, floorS, { ["Base.Plank"] = "1" })
    ours(up, wallS, {})
    unbuild(GP, 13, 72, 76, 1, "df_01_0")
    Server.dismantle(GP, 13)
    c, a = lastSent()
    check(c == "dismantleRefused" and a.code == "FLOOR_IN_USE" and has(up, F1), "二樓的地板上還有牆：FLOOR_IN_USE、不拆")

    -- 右鍵選單：點地板也列出正上方那格的屋頂；樓梯三片只列一次
    local Menu = (function() require "MinidoracatBuilder/Menu" return MinidoracatBuilder.Menu end)()
    local roofSq = engineSq(76, 70, 1)
    local R = ours(roofSq, roofS, { ["Base.Plank"] = "1" })
    local floorObj = { getSquare = function() return at(76, 70, 0) end }
    local tg = Menu.targets({ floorObj })
    local S1 = ours(at(74, 74, 0), stS[3], {})
    local S2 = ours(at(75, 74, 0), stS[2], {})
    buildUtil.getStairObjects = function() return { S1, S2 } end
    local ts = Menu.targets({ { getSquare = function() return at(74, 74, 0) end },
        { getSquare = function() return at(75, 74, 0) end } })
    buildUtil.getStairObjects = realStairs
    check(#tg == 1 and tg[1].obj == R and tg[1].kind == "roof" and #ts == 1,
        "右鍵選單：點地板列出正上方的屋頂（從底下點不到）；樓梯兩片只列一項")
    instanceof = realInst
end
dismantleScenario()

print()
if failures > 0 then
    print(failures .. " 項失敗")
    os.exit(1)
end
print("全部通過")
