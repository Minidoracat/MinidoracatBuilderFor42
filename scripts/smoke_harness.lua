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
function getRecipeDisplayName(name) return "R:" .. name end -- 標出有翻成配方顯示名稱
-- 遊戲版本（Cursor.padBuild 看）：預設 42.22，情境十八換成 42.21。全域：主函式的 local 已經到 200 個上限
GAME_MINOR = 22
function getCore()
    return { getGameVersion = function()
        return { getMajor = function() return 42 end, getMinor = function() return GAME_MINOR end }
    end }
end

function table.isempty(t) return next(t) == nil end -- Kahlua TableLib 有（TableLib.java:76-78），標準 Lua 沒有
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
        indexOf = function(_, x)
            for i, v in ipairs(items) do if v == x then return i - 1 end end
            return -1
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
-- 假 SpriteConfigManager：建造配方的轉角柱（Rules.recordCorners 讀 getScript():getCornerSprite()）。
-- 名稱放 SpriteConfigManager.corners（主程式的 local 已到 200 上限）
SpriteConfigManager = { corners = {}, GetObjectInfoList = function()
    local infos = {}
    for i, name in ipairs(SpriteConfigManager.corners) do
        infos[i] = { getScript = function() return { getCornerSprite = function() return name end } end }
    end
    infos[#infos + 1] = { getScript = function() return nil end } -- 沒有 SpriteConfig 腳本的
    return javaList(infos)
end }
-- 預設沒有本機玩家：建造配方項目（Recipes.lua）要有玩家才掃，配方的情境自己換成假玩家與假配方
function getSpecificPlayer() return nil end

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
IsoDirections = { N = { name = "N" }, S = { name = "S" }, E = { name = "E" }, W = { name = "W" } }
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
        -- 照引擎：只照 x、y 找已讀進來的塊，不看那一格在不在、不看 z（IsoCell.java:333-357）；這一塊 z=0 有任一格就算讀進來
        getChunkForGridSquare = function(_, x, y)
            local x0, y0 = math.floor(x / 8) * 8, math.floor(y / 8) * 8
            for i = 0, 63 do
                local sq = squares[(x0 + i % 8) .. "," .. (y0 + math.floor(i / 8)) .. ",0"]
                if sq then return sq:getChunk() end
            end
            return nil
        end,
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
    function sq:getWallSE() return o.wallSE end
    function sq:getGarageDoor(north) if north then return o.garageN end return o.garageW end
    function sq:hasModData() return sq.md ~= nil end
    function sq:getModData() sq.md = sq.md or {}; return sq.md end
    function sq:getRoomID() return -1 end
    function sq:getRoom() return nil end -- 伺服器上自建房屋沒有房間（IsoRegions.java:212-214）；線路情境另設
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
    function sq:getSlopedSurfaceHeight() return 0 end -- 照引擎：不是斜坡回 0（IsoGridSquare.java:10288-10292）
    function sq:RecalcProperties() end
    function sq:getCell() return getCell() end
    function sq:clearWater() end
    function sq:disableErosion() end
    function sq:RecalcAllWithNeighbours() end
    function sq:getWorldObjects() return javaList(self.world) end
    function sq:getSpecialObjects() return javaList(self.objects) end
    -- 照引擎：一塊 8×8，getGridSquare 收這一塊裡的座標（IsoChunk.java:3157-3160）；格子沒建過回 nil
    function sq:getChunk()
        local x0, y0 = math.floor(x / 8) * 8, math.floor(y / 8) * 8
        return {
            getGridSquare = function(_, lx, ly, lz) return squares[(x0 + lx) .. "," .. (y0 + ly) .. "," .. lz] end,
            getMinLevel = function() return 0 end,
            getMaxLevel = function() return 0 end,
        }
    end
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
        return { has = function(_, k) return type(k) == "table" and k.name == (flag or "canBeRemoved") end,
            get = function() return nil end }
    end
    function o:getTextureName() return "vegetation_test_01_0" end
    function o:getType() return IsoObjectType.normal end
    function o:getSprite() return nil end
    function o:hasModData() return false end
    sq.objects[#sq.objects + 1] = o
    group[#group + 1] = { sq = sq, o = o }
    return o
end
IsoThumpable = { new = function(_, sq, name, north)
    local o = { name = name, north = north, mats = {}, md = {}, set = {} }
    for _, s in ipairs({ "setCanPassThrough", "setBlockAllTheSquare", "setIsHoppable", "setIsDoorFrame",
        "setCanBarricade", "setIsFloor", "setIsThumpable", "setIsDismantable", "setMaxHealth", "setHealth",
        "setThumpDmg", "setRenderYOffset", "setExplored", "transmitCompleteItemToClients", "setIsStairs", "setCorner", "setName" }) do
        o[s] = function(self, v) self.set[s] = v end -- 記最後一次設的值
    end
    function o:getSprite() return spriteMap[name] end
    function o:getProperties() local s = spriteMap[name] return s and s:getProperties() end
    function o:getBuildMaterials() return self.mats end
    function o:getModData() return self.md end
    function o:hasModData() return next(self.md) ~= nil end -- 照引擎：表不是空的才 true
    function o:isFloor() return self.set.setIsFloor == true end
    function o:getSquare() return sq end
    -- 容器（boxes）、thumpDmg 預設 8：Place.fitContainers／Place.harden 用
    function o:getContainerCount() return #(self.boxes or {}) end
    function o:getContainerByIndex(i) return (self.boxes or {})[i + 1] end
    function o:getThumpDmg() return self.set.setThumpDmg or 8 end
    function o:getName() return self.set.setName end
    return o
end }
-- 假物品與背包（getSomeTypeEvalRecurse／getFirstTagEvalRecurse 照原版：最多 n 個、過 predicate）。耗材：it.uses＝剩幾次
ItemTag = { HAMMER = "HAMMER", MASONS_TROWEL = "MASONS_TROWEL", BLOW_TORCH = "BLOW_TORCH", WELDING_MASK = "WELDING_MASK",
    SCREWDRIVER = "SCREWDRIVER", CONCRETE = "CONCRETE" }
function instanceof() return false end
-- 拆除退料的亂數：ZombRand(n) 回 0..n−1；HARNESS_ROLL＝"max"（全退）／"min"（只退 1）切換（拆除情境用）。
-- 主程式的區域變數快到 200 個上限，這幾個用全域
HARNESS_ROLL = "max"
function ZombRand(n) if HARNESS_ROLL == "min" then return 0 end return n - 1 end
function ZombRandFloat(a) return a end
-- 假 GOS（原版 server/Map/SGlobalObjectSystem.lua 用到的部分）：系統的 modData 就是系統表本身；存檔只存 setModDataKeys
-- 白名單裡的鍵（HARNESS_GOS_KEYS 記下來給情境驗）。require 跑完那個檔案才建 instance（原版在 OnSGlobalObjectSystemInit，所有 Lua 載完之後）。
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
-- 照引擎：系統等檔案載入完才建（原版 RegisterSystemClass 掛 OnSGlobalObjectSystemInit），不在登記當下；require 跑完檔案後建
HARNESS_PENDING_SYSTEMS = {} -- 全域：主程式區塊的 local 已到 200 個上限
function SGlobalObjectSystem.RegisterSystemClass(cls) table.insert(HARNESS_PENDING_SYSTEMS, cls) end
function sendRemoveItemFromContainer() end
function sendAddItemsToContainer() end
local function item(ft, tags)
    local it = { ft = ft, tags = tags or {} }
    function it:getFullType() return ft end
    function it:isBroken() return false end
    function it:getContainer() return self.box end
    function it:getCurrentUses() return self.uses or 0 end
    function it:hasTag(t) return self.tags[t] == true end
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
    function inv:getAllTypeRecurse(ft) -- 只收完整型別（Materials 的耗材鍵都是 fullType）
        local out = {}
        for _, v in ipairs(self.items) do if v.ft == ft then out[#out + 1] = v end end
        return javaList(out)
    end
    function inv:getAllTagRecurse(tag)
        local out = {}
        for _, v in ipairs(self.items) do if v.tags[tag] then out[#out + 1] = v end end
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
        if chunk then
            chunk()
            while #HARNESS_PENDING_SYSTEMS > 0 do table.remove(HARNESS_PENDING_SYSTEMS, 1):new() end
            return true
        end
    end
    error("require 找不到: " .. name)
end

-- 原版開關燈動作（Circuits 載入時包它的 complete）：原版的 complete 記次數、回 "orig"
HARNESS_TOGGLES = 0
ISToggleLightAction = { complete = function() HARNESS_TOGGLES = HARNESS_TOGGLES + 1 return "orig" end }

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
check(kind({ flags = { "doorW", "open" } }) == nil, "開著的門（關著那張 +2，引擎補了門旗標與 open）：不列")
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
        and kind({ flags = { "cutW", "makeWindowInvincible" } }) == nil,
        "讓窗打不破的旗標（窗、窗框、牆面疊圖帶 makeWindowInvincible）：不列")
    check(kind({ flags = { "cutW", "makeWindowInvincible" }, keys = { WallW = "" } }) == "wall",
        "牆帶 makeWindowInvincible（商場鐵捲門）：照牆列，旗標只影響窗（使用者 2026-11-03 選列）")
    check(kind({ keys = { container = "crate", StackReplaceTileOffset = "-1" } }) == nil
        and kind({ flags = { "solidtrans" }, keys = { StackReplaceTileOffset = "-2" } }) == nil
        and kind({ keys = { container = "crate", StackReplaceTileOffset = "0" } }) == "container"
        and kind({ flags = { "solidtrans" } }) == "solid",
        "疊放圖（StackReplaceTileOffset 不是 0，讀檔時引擎換圖）：容器、實心物件都不列；0 或沒有照常列")
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
-- 兩面椅子：引擎替合法的同名組每一面寫其他面原點的偏移，自己那面不寫（IsoWorld.java:1283-1326）
local chairA = sprite("furniture_01_4", 104, { keys = { IsMoveAble = "", GroupName = "Furniture", CustomName = "Red Chair",
    Facing = "E", Soffset = "-2" } })
local chairB = sprite("furniture_01_2", 102, { keys = { IsMoveAble = "", GroupName = "Furniture", CustomName = "Red Chair",
    Facing = "S", Eoffset = "2" } })
local bedA = sprite("beds_01_0", 200, { keys = { IsMoveAble = "", GroupName = "Big", CustomName = "Bed" } })
local bedB = sprite("beds_01_1", 201, { keys = { IsMoveAble = "", GroupName = "Big", CustomName = "Bed" } })
bedA.grid, bedB.grid = grid(bedA), grid(bedA)
local list = {
    sprite("", -1), sprite("ui_icon", 20000000, { keys = { IsMoveAble = "" } }),
    sprite("walls_01_0", 300, { keys = { WallN = "" }, noTex = true }),
    sprite("walls_01_1", 301, { keys = { WallN = "" } }),
    -- 椅子兩面中間夾著床（另一個 tileset）：群組代表換到後面那張時，要寫回椅子自己的桶
    chairA, bedA, bedB, chairB,
    -- 共用名稱的不同物件（沒有偏移；原版 trash_01 的 Trash 同一個朝向有好幾張）：各列一項
    sprite("trash_01_1", 111, { keys = { IsMoveAble = "", CustomName = "Trash", Facing = "E" } }),
    sprite("trash_01_0", 110, { keys = { IsMoveAble = "", CustomName = "Trash", Facing = "E" } }),
    -- 同一件的兩面種類不同（一面有容器）：照種類分成兩項
    sprite("desk_01_1", 121, { keys = { IsMoveAble = "", GroupName = "Office", CustomName = "Desk", Facing = "E",
        Soffset = "-1" } }),
    sprite("desk_01_0", 120, { keys = { IsMoveAble = "", GroupName = "Office", CustomName = "Desk", Facing = "S",
        Eoffset = "1", container = "desk" } }),
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
check(furn.n == 5, "兩面椅子算一項、兩格床只收原點；同名的不同物件、同一件不同種類的面各一項")
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
check(Index.items == 2010, "總項目數（牆 1＋家具 5＋容器 1＋樓梯 1＋地板 2002）")
local fb = Index.bucket.furniture
check(fb.furniture_01.n == 1 and fb.furniture_01[1] == "furniture_01_2" and fb.beds_01.n == 1
    and fb.beds_01[1] == "beds_01_0", "分桶：群組代表換到後面那張時寫回自己的 tileset 桶，不蓋到別的桶")
local fs = Index.kindSets.floor
check(fs.n == 3 and fs[1] == "tk_01" and fs[2] == "fancy_tiles" and fs[3] == "filler_01"
    and floor[1] == "tk_01_3" and floor[2] == "fancy_tiles_7" and floor[3] == "filler_01_1",
    "種類裡的 tileset 照第一次出現的順序；Index.names 照這個順序攤平")
check(Index.kindCount.wall == 1 and Index.kindCount.furniture == 5 and Index.kindCount.container == 1
    and Index.kindCount.stairs == 1 and Index.kindCount.floor == 2002, "每個種類的項目數（同一件的各面只算一項）")
wall[1] = "changed"
check(Index.names("wall")[1] == "walls_01_1" and Index.names("nope").n == 0, "Index.names 回新陣列；沒有的種類回空陣列")
check(Index.family.filler_01 == "filler" and Index.family.tk_01 == "tk" and Index.family.fancy_tiles == "fancy_tiles"
    and Index.family.furniture_01 == "furniture", "圖塊組＝tileset 去掉結尾 _數字；沒有編號的照原樣")
local kindOf, setOf = {}, {}
for i = 1, Index.nameKey.n do kindOf[Index.nameItem[i]], setOf[Index.nameItem[i]] = Index.nameKind[i], Index.nameSet[i] end
check(kindOf.furniture_01_2 == "furniture" and setOf.furniture_01_2 == "furniture_01" and setOf.beds_01_0 == "beds_01"
    and Index.nameKind.n == Index.nameKey.n and Index.nameSet.n == Index.nameKey.n,
    "名稱鍵的每一項都記種類與 tileset（和 nameItem 同一項）")
check(Index.nameKey.n == 6, "有名稱的項目都建搜尋鍵（椅子一組、床、兩個垃圾、桌子兩種）")
local keyed = {}
for i = 1, Index.nameKey.n do keyed[Index.nameItem[i]] = Index.nameKey[i] end
check(keyed["furniture_01_2"] == "red chair ch|furniture red chair", "名稱鍵＝小寫「翻譯|原名」並指向群組代表")
do
    local trash = 0
    for i = 1, furn.n do if furn[i]:find("^trash_01_") then trash = trash + 1 end end
    check(trash == 2 and keyed.trash_01_0 == "|trash" and keyed.trash_01_1 == "|trash",
        "同名但沒有朝向偏移（不是同一件）：各列一項、各有搜尋鍵")
    local c = Index.names("container")
    check(c.n == 1 and c[1] == "desk_01_0" and kindOf.desk_01_0 == "container" and kindOf.desk_01_1 == "furniture",
        "同一件的面種類不同：照種類分開，各自列在自己的種類")
    local bad = {}
    for k, sets in pairs(Index.bucket) do
        for _, arr in pairs(sets) do
            for j = 1, arr.n do
                if Rules.classify(spriteMap[arr[j]]) ~= k then bad[#bad + 1] = arr[j] .. ":" .. k end
            end
        end
    end
    check(#bad == 0, "每項列在的種類＝重算的種類（Entry.resolve 同一套）" .. table.concat(bad, ","))
end
local setKey
for i = 1, Index.setName.n do if Index.setName[i] == "tk_01" then setKey = Index.setKey[i] end end
check(setKey == "tk 01|tk_01|unofficial mappers community tile pack", "tileset 鍵帶來源 MOD 名")
check(Index.setKey.n == Index.setName.n, "每個 tileset 都有搜尋鍵")
check(Index.groups == nil, "群組暫存表已丟掉")
do -- namedMap 的順序每次開遊戲都不同：反過來整理一次，每項的種類與代表都要一樣
    local function snap()
        local out = {}
        for k, sets in pairs(Index.bucket) do
            for _, arr in pairs(sets) do
                for j = 1, arr.n do out[#out + 1] = k .. ":" .. arr[j] end
            end
        end
        table.sort(out)
        return table.concat(out, ",")
    end
    local before, rev = snap(), {}
    for i = #list, 1, -1 do rev[#rev + 1] = list[i] end
    world(rev)
    Catalog.state = "idle"
    Catalog.start()
    for _ = 1, 50 do fire("OnTickEvenPaused") end
    check(Catalog.state == "ready" and snap() == before, "整理順序反過來：每項的種類與代表都一樣")
end

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
-- 引擎沒連起來的同名家具（Entry.face 的 siblingFace；2026-11-03 Workshop 回報轉不了）。包在函式裡：主程式的 local 接近上限
;(function()
    local keepMap, keepOrder = spriteMap, spriteOrder
    local list = {}
    for i, k in ipairs({
        { CustomName = "Desk", Facing = "S" }, { CustomName = "Desk", Facing = "E" }, { CustomName = "Desk", Facing = "N" },
        { CustomName = "Shelf", Facing = "S" }, { CustomName = "Shelf", Facing = "S" }, { CustomName = "Shelf", Facing = "E" },
        { CustomName = "Lamp" }, { CustomName = "Lamp", Facing = "E" }, { CustomName = "Lamp", Facing = "S" },
        { CustomName = "Desk", Facing = "W", Noffset = "-7" }, -- 9：引擎連過的（有偏移）
        { CustomName = "Desk", Facing = "W" },                  -- 10：多格的一格
    }) do
        k.IsMoveAble = ""
        list[i] = sprite("sib_01_" .. (i - 1), 9100 + i, { keys = k })
    end
    list[11].grid = {}
    list[12] = sprite("sib_01_11", 9112, { flags = { "WallW" }, keys = { WallW = "", CustomName = "Desk", Facing = "W" } }) -- 同名的牆
    list[13] = sprite("Ekron01_0", 9120, { keys = { IsMoveAble = "", CustomName = "Cartoon Poster", Facing = "S" } })
    list[14] = sprite("Ekron01_1", 9121, { keys = { IsMoveAble = "", CustomName = "Cartoon Poster", Facing = "E" } })
    -- 同一個 tileset 跨兩個 tiledef 檔：東面那張來自 MOD 檔 7001（UMCTP）
    list[15] = sprite("sib_02_0", 9130, { keys = { IsMoveAble = "", CustomName = "Cabinet", Facing = "S" } })
    list[16] = sprite("sib_02_1", MOD_ID_BASE + 7, { keys = { IsMoveAble = "", CustomName = "Cabinet", Facing = "E" } })
    -- 牆的配對面（d＝5）也一樣：北牆那張來自 MOD 檔 7001
    list[17] = sprite("sib_03_0", 9140, { flags = { "WallW" }, keys = { WallW = "" } })
    list[18] = sprite("sib_03_1", MOD_ID_BASE + 8, { flags = { "WallN" }, keys = { WallN = "" } })
    world(list)
    local function face(name, d)
        local f = Entry.face(Entry.resolve(name), d)
        return f and f:getName() or nil
    end
    check(face("sib_01_0", 2) == "sib_01_1" and face("sib_01_0", 1) == "sib_01_2" and face("sib_01_0", 3) == "sib_01_0"
        and face("sib_01_1", 3) == "sib_01_0" and face("sib_01_2", 2) == "sib_01_1",
        "同名家具（引擎沒寫偏移）：同 tileset、同種類、同名、每個朝向一張的配起來，每一張都轉得到其他面")
    check(face("sib_01_0", 4) == nil, "同名家具：引擎連過的、多格的、別的種類的同名圖不算進這一組（西面沒有）")
    check(face("sib_01_5", 3) == nil and face("sib_01_7", 3) == nil and face("Ekron01_0", 2) == nil,
        "同名家具不配：同一個朝向有兩張、有一張沒寫朝向、看圖確認的同名不同物（NO_PAIR）")
    check(face("sib_01_9", 1) == "sib_01_2" and face("sib_01_9", 2) == nil, "引擎連過的項目照偏移，不另外配同名圖")
    local sbs = SandboxVars.MinidoracatBuilder
    local keepSrc, east, pair = sbs.DisabledSources, face("sib_02_0", 2), face("sib_03_0", 5)
    sbs.DisabledSources = "UMCTP"
    local eastOff, pairOff = face("sib_02_0", 2), face("sib_03_0", 5)
    sbs.DisabledSources = keepSrc
    check(east == "sib_02_1" and eastOff == nil and pair == "sib_03_1" and pairOff == nil,
        "另一面（同名配對、牆的配對面）來自停用的來源（同一個 tileset 跨 tiledef 檔）：那一面不給轉，伺服器照樣回 BAD_FACE")
    spriteMap, spriteOrder = keepMap, keepOrder
end)()

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
    local args = { n = o.n or 5, e = o.e or "walls_test_01_4", c = o.c or { 10, 20, 0, o.d or 0 },
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
check(intent(P, { c = { 10, 20, 0, 0, 11, 20, 0, 0, 12, 20, 0, 0 } }) == "BAD_REQUEST", "超過每次上限：BAD_REQUEST")
check(intent(P, { c = { 1.5, 2, 0, 0 } }) == "BAD_REQUEST", "座標不是整數：BAD_REQUEST")
check(intent(P, { c = { 1, 2, 40, 0 } }) == "BAD_REQUEST", "樓層超出範圍：BAD_REQUEST")
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
check(intent(P, { n = 9, c = { 200, 20, 0, 0 } }) == "TOO_FAR", "錨點離玩家超過 100 格：TOO_FAR")
check(intent(P, { n = 10, c = { 60, 20, 0, 0 } }) == nil and Server.intents[7].n == 10,
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
    local c = at or { 50, 50, 0 }
    Server.intent(p, { n = n, e = e or "walls_test_01_4", c = { c[1], c[2], c[3], c[4] or 0 }, v = Entry.digest() })
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
Server.intent(Q, { n = 3, e = "walls_test_01_4", c = { 52, 52, 0, 0 }, v = Entry.digest() })
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
check(not ok and a.code == "OCCUPIED", "會擋路的東西：格上有人時 OCCUPIED")
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
        sprite("rug_test_01_0", 957, { flags = { "solid" }, keys = { MoveType = "FloorRug", Material = "Wood", PickUpWeight = "40" } }),
        sprite("post_test_01_0", 959, { flags = { "WallSE" } }) })
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
    -- 柱子（WallSE；使用者 2026-10-31 拆成新種類）：照原版補的轉角柱，轉角＋不可穿過（不然殭屍把它當這一格的西牆打；
    -- 可穿過的話原生尋路會把同一格的牆也當成打不了）
    local po = put(39, 74, "post_test_01_0")
    check(po and po.set.setCorner == true and po.set.setMaxHealth == 450 and po.set.setCanPassThrough == false
        and w.set.setCorner == false, "柱子：轉角、不可穿過、450 血（照原版 addCorner）；牆不是轉角")
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
check((function() -- 主程式的 local 已到 200 上限：新的檢查包在函式裡
    local fo = fA.objects[1]
    local e = MinidoracatBuilder.Floors.get(fo)
    return e ~= nil and e.s == "floor_01_0" and e.i["Base.Plank"] ~= nil and next(fo.mats) == nil
        and fo.md.builderRefund == nil and fo.set.setIsDismantable == false
end)(), "一樓的地板：退料記在地板帳本（連同蓋的圖），buildMaterials 留空、modData 不放，不給原版搬動工具拆")
square(96, 96, 0, { floor = {} })
local I = player({ id = 23, x = 96.5, y = 97.5, instant = true })
before = regionPokes
sent = {}
Server.intent(I, { n = 14, e = "walls_test_01_4", c = { 96, 96, 0, 0, 97, 96, 0, 0 }, v = Entry.digest() })
check(regionPokes == before + 1, "那一帶有地板：喚醒區域系統一次")
check(Server.duration(I, 14, 1) == 150, "即時動作的第一項也等滿喚醒的 3 秒（150 tick）")
check(Server.duration(I, 14, 2) == 1, "第二項排在第一項之後：不再等")
Server.intent(I, { n = 15, e = "walls_test_01_4", c = { 96, 96, 0, 0 }, v = Entry.digest() })
check(regionPokes == before + 1, "同一帶第二次請求：不再喚醒")
local X = player({ id = 24, x = 96.5, y = 97.5 })
Server.intent(X, { n = 16, e = "walls_test_01_4", c = { 96, 96, 0, 0 }, v = Entry.digest() })
nowMs = nowMs + 181000
Server.intent(I, { n = 17, e = "walls_test_01_4", c = { 96, 96, 0, 0 }, v = Entry.digest() })
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
local nn, why = Client.build(player({ id = 30 }), "walls_test_01_4", { { 10, 20, 0, 0 } })
sb.Enabled = nil
isServer = realIsServer
check(nn == nil and why == "OFF" and added == 0, "單機請求當場被拒：回原因碼、不排動作")
isServer = function() return false end
local nn2 = Client.build(player({ id = 31 }), "walls_test_01_4", { { 10, 20, 0, 0 }, { 11, 20, 0, 0 } })
isServer = realIsServer
check(nn2 ~= nil and added == 2, "單機請求收下：伺服器當場回 accepted，排兩項動作")
local realIsClient = isClient
isClient = function() return true end
function sendClientCommand() end
added = 0
local nn3 = Client.build(player({ id = 32 }), "walls_test_01_4", { { 10, 20, 0, 0 } })
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
    square(57, 44, 0, { moving = { {} } })   -- 格上有人：實心的東西 OCCUPIED
    square(55, 44, 0, { noReach = true })    -- 走不到
    square(56, 43, 0, { owner = "someone" }) -- 別人的安全屋
    local PV = { preview = true }
    local cases = {
        { "nope_01_0", 0, { 56, 45, 0 }, "UNKNOWN" },
        { "walls_test_01_4", 1, { 56, 45, 0 }, "BAD_FACE" },
        { "walls_test_01_4", 0, { 56, 49, 0 }, "TOO_FAR", 49 },
        { "solid_01_0", 0, { 55, 44, 0 }, "UNREACHABLE", 44 },
        { "walls_test_01_4", 0, { 56, 43, 0 }, "SAFEHOUSE", 43 },
        { "solid_01_0", 0, { 57, 44, 0 }, "OCCUPIED", 44 },
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
    -- 選了來源：種類的數量與圖塊組照那個來源算（之前照全部來源算，選 MOD 後點到別的來源的組是空清單）。
    -- 包在函式裡：主程式的 local 已經接近 Lua 的 200 個上限
    local function sourceCats()
        local function cats(src)
            W.st.source = src
            local g = W.categories("all")
            local kinds, fams = {}, {}
            for _, it in ipairs(g[2].items) do kinds[it.id] = it.label end
            for i, it in ipairs(g[3].items) do fams[i] = it.id end
            return kinds, table.concat(fams, ",")
        end
        local umKinds, umFams = cats("UMCTP")
        check(umKinds.all == "IGUI_MBLD_Count(IGUI_MBLD_Cat_All,1)"
            and umKinds["k:furniture"] == "IGUI_MBLD_Count(IGUI_MBLD_Kind_furniture,1)" and umKinds["k:floor"] == nil
            and umFams == "f:umctp_boxes",
            "來源選 MOD：種類只算那個 MOD 的、沒有的種類不列，圖塊組只列它的")
        local vaKinds, vaFams = cats("vanilla")
        check(vaKinds.all == "IGUI_MBLD_Count(IGUI_MBLD_Cat_All,5)"
            and vaKinds["k:furniture"] == "IGUI_MBLD_Count(IGUI_MBLD_Kind_furniture,3)"
            and vaKinds["k:floor"] == "IGUI_MBLD_Count(IGUI_MBLD_Kind_floor,2)"
            and vaFams == "f:aaa_crates,f:floors_interior,f:furniture_seat",
            "來源選原版：MOD 的項目不算進數量，MOD 的圖塊組不列")
        -- 選著的圖塊組在新來源沒有：分類回「全部」（refreshCats 找不到就重設；W.setSource 換來源時呼叫）
        local fakeV = { nav = { setGroups = function() end, setSelected = function() end },
            cat = { setOptions = function() end, setSelected = function() end } }
        W.st.source, W.st.cat = "all", "f:furniture_seat"
        W.refreshCats(fakeV)
        local kept = W.st.cat
        W.st.source = "UMCTP"
        W.refreshCats(fakeV)
        check(kept == "f:furniture_seat" and W.st.cat == "all", "換到沒有這個圖塊組的來源：分類回「全部」，不留空清單")
        W.st.source, W.st.cat = "all", "all"
    end
    sourceCats()
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
    -- 包在函式裡：主程式的 local 已經接近 Lua 的 200 個上限
    local function gridNames()
        check(Names.short("furniture_seat_01_0") == Names.of("furniture_seat_01_0"), "短名：有原版翻譯時和完整名一樣")
        local s = Names.short("furniture_seat_01_1")
        check(s:find("furniture seat 01\nIGUI_MBLD_Name_Num", 1, true) and not s:find("IGUI_MBLD_Kind_", 1, true),
            "短名：沒有翻譯時是「圖塊組」換行「編號」，不帶種類")
        -- 一個字一行的假 Text：斷不完時最後一行接上原文剩下的部分再截短
        local T = { wrap = function(str)
            local out = {}
            for w in str:gmatch("%S+") do out[#out + 1] = w end
            return out
        end, fit = function(str, w) return #str <= w and str or str:sub(1, w - 3) .. "..." end }
        local two = W.wrapMax(T, "misc ddd 01 16", 8, nil, 2)
        local one = W.wrapMax(T, "misc ddd", 8, nil, 2)
        check(#two == 2 and two[1] == "misc" and two[2] == "ddd 0..." and #one == 2 and one[2] == "ddd",
            "最多兩行：放得下照斷，放不下第二行接上剩下的字、截掉處有省略號")
        local tl = W.tileLines(T, "fixtures bathroom 01\n#64", 8, nil)
        check(#tl == 2 and tl[1] == "fixtu..." and tl[2] == "#64", "方格名稱：圖塊組太長只截第一行，編號照樣在第二行")
        local de = W.wrapMax(T, "Dunkelgrauer Teppich", 8, nil, 2)
        check(#de == 2 and de[1] == "Dunke..." and de[2] == "Teppich",
            "最多兩行：比行寬長的單字截短加省略號，不在字中間斷（DE「Dunkelgraue／r Teppich」）")
        local realReader = getFileReader
        local function perRow(content)
            getFileReader = function()
                if content == nil then return nil end
                return { readLine = function() return content end, close = function() end }
            end
            return W.loadPerRow()
        end
        check(perRow("7") == 7 and perRow(" 3 ") == 3 and perRow(nil) == 5 and perRow("11") == 5 and perRow("1") == 5
            and perRow("4.5") == 5 and perRow("abc") == 5, "一排幾格：讀檔裡的 2–10 整數，讀不到或不合法用 5")
        getFileReader = realReader
    end
    gridNames()
    -- 挑圖塊之後換頁籤、分類、來源（2026-11-03 Workshop 回報清單卡在挑的那一桶），與雙擊建造。
    -- 假的視窗只放這幾支用到的欄位；包在函式裡：主程式的 local 接近上限
    ;(function()
        local noop, searchText = function() end, nil
        local grid = { items = { n = 0 }, width = 300, height = 300 }
        function grid:setItems(l) self.items = l end
        function grid:getItems() return self.items end
        function grid:setSelectedIndex(i) self.sel = i end
        function grid:getSelectedIndex() return self.sel end
        function grid:scrollToIndex(i) self.scrolled = i end
        function grid:setScrollOffset(o) self.offset = o end
        local v = { grid = grid, dim = {}, fh = 10, status = { width = 100 },
            search = { setText = function(_, t) searchText = t end },
            UI = { Dropdown = { close = noop }, Text = { wrap = function(s) return { s } end, fit = function(s) return s end } },
            nav = { setGroups = noop, setSelected = noop }, cat = { setOptions = noop, setSelected = noop },
            clearBtn = { setVisible = noop, setX = noop, setY = noop, width = 10 } }
        local function idx(name)
            for i = 1, grid.items.n do if grid.items[i] == name then return i end end
        end
        W.v = v
        W.setQuery("floors_interior_01_1")
        local jumped = v.selName == "floors_interior_01_1" and grid.items.n == 2
        -- 玩家點了同一桶的另一格（W.pump 照方格的選取更新 selName）；之後的重算（keep）不跳回挑的那張、不捲動
        grid.sel, v.selName, grid.scrolled = idx("floors_interior_01_0"), "floors_interior_01_0", nil
        W.refilter(true)
        check(jumped and v.selName == "floors_interior_01_0" and grid.sel == idx("floors_interior_01_0") and grid.scrolled == nil,
            "挑圖塊後點同一桶的別格：重算時留住玩家選的、不捲動，不跳回挑的那張")
        W.onTab(v, "furniture")
        check(W.st.query == "" and searchText == "" and grid.items.n == 4 and not has(grid.items, "floors_interior_01_0"),
            "挑圖塊後換頁籤：清掉完整圖塊名，清單照新頁籤列（之前停在挑的那一桶）")
        W.onTab(v, "all")
        W.setQuery("floors_interior_01_1")
        W.setCat("k:furniture")
        local catOk = W.st.query == "" and grid.items.n == 4
        W.setCat("all")
        W.setQuery("floors_interior_01_1")
        W.setSource("UMCTP")
        check(catOk and W.st.query == "" and grid.items.n == 1 and grid.items[1] == "umctp_boxes_01_0",
            "挑圖塊後換分類、換來源：一樣清掉完整圖塊名，照新條件列")
        W.setSource("all")
        W.setQuery("red chair")
        W.onTab(v, "furniture")
        check(W.st.query == "red chair" and grid.items.n == 1, "一般搜尋字（不是完整圖塊名）換頁籤照樣留著")
        -- 「只看能蓋的」：挑圖塊那一批（keep＝false）還沒做完，就被每秒的重算（keep）換掉時，仍照換了條件套；
        -- 不然 applyItems 留住舊的選取，挑的那張選不到（2026-11-03 審查 Claude lane）
        W.st.only, v.S = true, {}
        W.setQuery("floors_interior_01_1")
        W.refilter(true)
        local affKeep = v.aff and v.aff.keep
        W.st.only, v.S, v.aff = false, nil, nil
        check(affKeep == false, "只看能蓋的：挑圖塊那一批沒做完就被重算換掉，仍照換了條件套")
        -- 材料篩選（使用者 2026-11-12 選 dropdown）：沒開「只看能蓋的」也分批；做完只留成本用到那種材料的。
        -- 這個假世界的成本全是木板：把第一項的分類快取成金屬（分類本身在情境四十三驗）
        W.st.query = ""
        W.onTab(v, "all")
        local totalN, seeded = grid.items.n, grid.items[1]
        v.mat = { [seeded] = { metal = true } }
        W.setMaterial("wood")
        local job = v.aff
        while v.aff do W.runAffordable(v) end
        local woodN, allWood = grid.items.n, not has(grid.items, seeded)
        for i = 1, woodN do allWood = allWood and W.materialsOf(grid.items[i]).wood == true end
        W.setMaterial("metal")
        while v.aff do W.runAffordable(v) end
        local metalOk = grid.items.n == 1 and grid.items[1] == seeded
        W.setMaterial("all")
        check(job ~= nil and job.mat == "wood" and job.only == false and woodN == totalN - 1 and allWood
            and metalOk and v.aff == nil and grid.items.n == totalN,
            "材料篩選：選木板只列成本有木板的、選金屬只列那一項；改回全部不分批、整份列回來")
        -- 空狀態照實際流程（審查 1112 Codex 兩輪）：材料那關一項都沒過說材料，兩個篩選都開也一樣；材料有過、
        -- 被「只看能蓋的」濾掉的照舊說只看能蓋的。完整圖塊名的搜尋同一套。缺料用快取假裝每一項都缺
        function grid:getX() return 0 end
        function grid:getY() return 0 end
        local function drain() while v.aff do W.runAffordable(v) end return v.emptyTitle and v.emptyTitle[1] end
        local Cat = MinidoracatBuilder.Catalog
        local cs0 = Cat.state
        Cat.state = "ready" -- 前面的情境把目錄留在失敗狀態，空狀態會先寫那一句
        v.mat = {}
        W.setMaterial("glass")
        local eMat, flagMat = drain(), v.matEmpty
        W.setQuery("floors_interior_01_1")
        local eqMat = drain()
        W.st.only, v.S = true, {}
        v.dim = setmetatable({}, { __index = function() return true end })
        W.refilter(false)
        local eqBoth = drain()
        W.setMaterial("wood")
        local eqOnly, flagOnly = drain(), v.matEmpty
        W.st.query = ""
        W.onTab(v, "all")
        local eOnly = drain()
        -- 同一桶材料混雜（審查 1112 Claude 第 2 輪）：要找的那張沒用到金屬、同桶另一張有（被缺料濾掉）→ 說材料；
        -- 要找的那張自己有金屬 → 說只看能蓋的
        v.mat = { floors_interior_01_0 = { metal = true }, floors_interior_01_1 = { wood = true } }
        W.setMaterial("metal")
        W.setQuery("floors_interior_01_1")
        local mixMat, mixFlag = drain(), v.matEmpty
        W.setQuery("floors_interior_01_0")
        local mixOnly = drain()
        W.st.only, v.S, v.dim = false, nil, {}
        -- 一般搜尋字的結果全被材料濾掉：提示說材料；最愛被材料濾空說材料，最愛本來就空照舊
        v.mat = {}
        W.setMaterial("glass")
        W.setQuery("red chair")
        drain()
        local hintMat = v.emptyHint and v.emptyHint[1]
        W.st.query = ""
        local Fav = MinidoracatBuilder.Favorites
        local fav0 = Fav.list
        Fav.list = { n = 1, seeded }
        W.setCat("fav")
        local favMat = drain()
        Fav.list = { n = 0 }
        W.refilter(false)
        local favNone = drain()
        Fav.list = fav0
        W.setCat("all")
        W.setMaterial("all")
        Cat.state = cs0
        check(mixMat == "IGUI_MBLD_Empty_Material" and mixFlag == false and mixOnly == "IGUI_MBLD_Empty_Only"
            and hintMat == "IGUI_MBLD_Empty_Material" and favMat == "IGUI_MBLD_Empty_Material"
            and favNone == "IGUI_MBLD_Empty_Fav",
            "空狀態：同一桶材料混雜時照要找的那一項說；一般搜尋被材料濾空提示說材料；最愛被材料濾空說材料、本來就空照舊")
        check(eMat == "IGUI_MBLD_Empty_Material" and flagMat == true and eqMat == "IGUI_MBLD_Empty_Material"
            and eqBoth == "IGUI_MBLD_Empty_Material" and eqOnly == "IGUI_MBLD_Empty_Only" and flagOnly == false
            and eOnly == "IGUI_MBLD_Empty_Only" and v.matEmpty == false and grid.items.n == totalN,
            "空狀態：被材料濾空說材料（兩個篩選都開、搜完整圖塊名也一樣）；材料有過、缺料濾掉的說只看能蓋的")
        W.setQuery("floors_interior_01_1")
        -- 雙擊：同一格 DOUBLE_MS（500 ms）內兩次＝按「建造」。pump 每幀把方格的選取同步到 selName（這裡手動同步）
        local builds, realBuild, keepStep = 0, W.build, clockStep
        W.build, clockStep = function() builds = builds + 1 end, 0
        local A, B = "furniture_seat_01_0", "furniture_seat_01_1"
        local function click(name, synced)
            W.onPick(v, name)
            if synced ~= false then v.selName = name end
        end
        W.resetPick(v)
        click(A)
        nowMs = nowMs + 400
        click(A)
        local fast = builds
        W.resetPick(v)
        click(A)
        nowMs = nowMs + 600
        click(A)
        nowMs = nowMs + 100
        click(B)
        local slowOrOther = builds
        -- 選著 A 時快點兩下 B，第二下時 pump 還沒把 selName 換成 B：只當選取，不蓋 A（審查 1103 Codex）
        W.resetPick(v)
        v.selName = A
        click(B, false)
        nowMs = nowMs + 100
        click(B, false)
        local unsynced = builds
        -- 點了 A、換了條件（W.refilter(false)），再點 A：只是選取
        W.resetPick(v)
        click(A)
        W.refilter(false)
        v.selName = A
        nowMs = nowMs + 100
        click(A)
        local afterChange = builds
        -- 時鐘往回調：差值是負的，不算雙擊（家族 pitfalls「X 毫秒內」；審查 1103 Claude 第 2 輪）
        W.resetPick(v)
        click(A)
        nowMs = nowMs - 5000
        click(A)
        nowMs = nowMs + 5100
        local rollback = builds
        -- 點了 A、關了又開視窗（W.open），再點 A：只是選取
        local realUi, realSync = W.ui, W.syncSettings
        W.ui, W.syncSettings = function() return v.UI end, noop
        v.win = { setVisible = noop, bringToTop = noop }
        W.resetPick(v)
        click(A)
        W.open(0)
        nowMs = nowMs + 100
        click(A)
        local afterOpen = builds
        W.ui, W.syncSettings, v.win = realUi, realSync, nil
        -- 指派了手把：手把同一格再按 A 不限時間；滑鼠點（左鍵按著）照 0.5 秒算（審查 1103 Grok 第 2 輪）
        local realPad, realMouse, mouseDown = W.usingPad, isMouseButtonDown, false
        W.usingPad, isMouseButtonDown = function() return true end, function() return mouseDown end
        W.resetPick(v)
        click(A)
        nowMs = nowMs + 3000
        click(A)
        local padAgain = builds
        mouseDown = true
        W.resetPick(v)
        click(A)
        nowMs = nowMs + 3000
        click(A)
        local mouseLate = builds
        W.usingPad, isMouseButtonDown = realPad, realMouse
        W.build, clockStep = realBuild, keepStep
        check(fast == 1 and slowOrOther == 1, "同一格 0.5 秒內點兩次＝建造；隔超過 0.5 秒或換了一格只是選取")
        check(unsynced == 1 and afterChange == 1, "雙擊：第二下時選取還沒同步、或兩下之間換了條件，只是選取（不蓋上一個選的）")
        check(rollback == 1 and afterOpen == 1, "雙擊：時鐘往回調、或兩下之間關了又開視窗，只是選取")
        check(padAgain == 2 and mouseLate == 2, "雙擊：指派了手把時，手把同一格再按 A 不限時間；滑鼠點同一格照 0.5 秒算")
        W.v, W.st.picked = nil, nil
        W.st.query, W.st.tab, W.st.cat, W.st.source = "", "all", "all", "all"
    end)()
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
    -- 手把 A（42.22.2）：原版 DoTileBuilding 對手把玩家不讀建造鍵（ISBuildingObject.lua:114-126），A 只送到游標的
    -- onJoypadPressButton，原版基底又不處理 A：本工具的游標照手把現在那一格重算、記成 square，再設建造旗標
    local realJoypad, realBase = Joypad, ISBuildingObject
    local baseCalls = 0
    Joypad = { AButton = 1, BButton = 2, XButton = 3, YButton = 4, LBumper = 5, RBumper = 6 }
    ISBuildingObject = { onJoypadPressButton = function() baseCalls = baseCalls + 1 end }
    local function padCursor(valid, o)
        o.entry = { kind = "wall" }
        o.isValid = function(self, sq) self.asked = sq return valid end
        return setmetatable(o, { __index = Cursor })
    end
    local oldSq, newSq = getCell():getGridSquare(58, 41, 0), getCell():getGridSquare(59, 41, 0)
    local pad = padCursor(true, { square = oldSq, canBeBuild = false, xJoypad = 59, yJoypad = 41, zJoypad = 0 })
    pad:onJoypadPressButton(0, {}, Joypad.AButton)
    -- 方向鍵連跳和 A 同一次輪詢：square／canBeBuild 還是剛離開的那格（可蓋），手把已經到下一格（不可蓋）
    local moved = padCursor(false, { square = oldSq, canBeBuild = true, xJoypad = 59, yJoypad = 41, zJoypad = 0 })
    moved:onJoypadPressButton(0, {}, Joypad.AButton)
    local gone = padCursor(true, { square = oldSq, canBeBuild = true, xJoypad = 59, yJoypad = 41, zJoypad = 5 })
    gone:onJoypadPressButton(0, {}, Joypad.AButton)
    check(pad.build == true and pad.canBeBuild == true and pad.square == newSq and pad.asked == newSq and baseCalls == 0,
        "手把 A：照手把那一格重算，可蓋就記成要蓋的格子、設建造旗標（下一幀蓋）；A 不交給原版基底")
    check(moved.build == false and moved.canBeBuild == false and moved.square == newSq and not gone.build
        and gone.asked == nil, "手把 A：游標剛移走時不照上一格蓋（審查 1110 Grok）；那一格還沒建出來不蓋")
    pad:onJoypadPressButton(0, {}, Joypad.BButton)
    check(baseCalls == 1, "手把 B：照舊交給原版（取消游標）")
    -- 42.21：原版 DoTileBuilding 還會替手把讀建造鍵、放開 A 時自己蓋，這裡不設旗標也不重算（不然蓋兩次）
    GAME_MINOR = 21
    local old = padCursor(true, { square = oldSq, canBeBuild = false, xJoypad = 59, yJoypad = 41, zJoypad = 0 })
    old:onJoypadPressButton(0, {}, Joypad.AButton)
    GAME_MINOR = 22
    check(not old.build and old.square == oldSq and old.asked == nil and baseCalls == 1,
        "42.21 的手把 A：不設建造旗標，交給原版讀建造鍵")
    Joypad, ISBuildingObject = realJoypad, realBase
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
        for _, file in ipairs({ "Window", "Cursor", "Names", "Messages", "Favorites", "Wiring" }) do
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
        for code in pairs(Messages.UNBUILD_CODES) do
            want["IGUI_MBLD_UnbuildRefuse_" .. code], want["IGUI_MBLD_UnbuildShort_" .. code] = true, true
        end
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
        "OUTSIDE_SAFEHOUSE", "BLOCKED", "NO_MATERIAL", "NO_TOOL", "INTERNAL", "WALK", "NO_ROOM" }) do
        if not Messages.CODES[code] then allKeyed = false end
    end
    check(allKeyed, "伺服器的拒絕碼與走不到都在訊息表裡")
    local nm = Messages.refusal("NO_MATERIAL", { need = { ["Base.Plank"] = 2 }, tools = { "HAMMER" } })
    check(nm:find("Base.Plank", 1, true) and nm:find("HAMMER", 1, true), "缺料：材料與缺的工具都列出")
    check(Messages.refusal("WHAT", {}):find("IGUI_MBLD_Refuse_Other(WHAT)", 1, true), "不認得的碼：通用訊息附上碼")
    getText = realGetText
end

print("情境十九之二：送出後停下的通知（被打斷不說走不到，旁邊沒空位另說）")
local function stopNotices()
    local B = MinidoracatBuilder
    local Cursor, Messages, C = B.Cursor, B.Messages, B.Client
    local realBuild, realToast, realGet, realQ, realGetText = C.build, Messages.toast, Cursor.get, ISTimedActionQueue, getText
    getText = function(k, ...)
        local a = { ... }
        return #a == 0 and k or k .. "(" .. table.concat(a, ",") .. ")"
    end
    local told, nonce = nil, 900
    Messages.toast = function(_, text, title) told = tostring(title) .. "|" .. text end
    Cursor.get = function() return nil end
    ISTimedActionQueue = { isPlayerDoingAction = function() return false end }
    C.build = function(p, _, cells)
        nonce = nonce + 1
        C.pending = { n = nonce, cells = cells, player = p }
        return nonce
    end
    local function run(count, placed, noRoom)
        told = nil
        local cells = {}
        for i = 1, count do cells[i] = { i, 0, 0, 0 } end
        local n = Cursor.send({ getPlayerNum = function() return 0 end }, "x_01_0", cells, nil)
        C.pending.noRoom = noRoom
        Cursor.onResult("accepted", { n = n })
        for i = 1, placed do Cursor.onResult("placed", { n = n, i = i }) end
        Cursor.tick()
        nowMs = nowMs + 2000
        Cursor.tick()
        return told
    end
    check(run(8, 3) == "IGUI_MBLD_Interrupted|IGUI_MBLD_Stopped(3,8)", "蓋了 3 格後停下：報蓋好 3／8，不報走不到")
    check(run(8, 0) == "nil|IGUI_MBLD_Refuse_WALK", "一格都沒蓋就停下：照舊用 WALK，標題留給 toast 預設")
    check(run(8, 4, 5) == "IGUI_MBLD_Interrupted|IGUI_MBLD_Refuse_NO_ROOM(5)", "第 5 格旁邊沒空位：前 4 格蓋好後報第 5 格")
    check(run(8, 1, 5) == "IGUI_MBLD_Interrupted|IGUI_MBLD_Stopped(1,8)", "還沒走到沒空位那格就停下：照實報蓋好幾格")
    check(run(8, 8) == nil and Cursor.queued() == nil, "全部蓋好：不通知")
    C.build, Messages.toast, Cursor.get, ISTimedActionQueue, getText = realBuild, realToast, realGet, realQ, realGetText
end
stopNotices()

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
    local fireplace = sprite("fire_01_0", 2178, { flags = { "solid" }, keys = { container = "fireplace" } })
    local fireplace2 = sprite("fire_01_1", 2180, { flags = { "solid" }, keys = { container = "fireplace" } })
    local floorUp = sprite("fup_01_0", 2179, { flags = { "solidfloor" } })
    local list = { stW[1], stW[2], stW[3], stN[1], stN[2], stN[3], landing, lamp, switch, roof, eave, stE[1], stE[2], stE[3],
        stM[1], stM[2], stM[3], stS[1], stS[2], stS[3], stI[1], stI[2], stI[3], fireplace, fireplace2, floorUp,
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
    Server.intent(FP, { n = 1, e = "stf_01_0", c = { 41, 49, 0, 1 }, v = Entry.digest() })
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
        local o = { spr = spr, room = room, md = {}, lights = 0, keyId = -1 }
        function o:getKeyId() return self.keyId end
        function o:setKeyId(v) self.keyId = v end
        function o:addLightSourceFromSprite() if spr:getProperties():has("lightR") then self.lights = self.lights + 1 end end
        function o:setActivated(v) self.on = v end
        function o:setRenderYOffset(v) self.yoff = v end
        function o:setMovedThumpable(v) self.moved = v end
        function o:getModData() return self.md end
        function o:setExplored() end
        function o:transmitCompleteItemToClients() self.sent = true end
        function o:getSquare() return sq end
        function o:getSprite() return spr end
        function o:getContainerCount() return 0 end
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
    -- 地圖房屋裡的開關沿用建構子照房間設的狀態、不強制開（伺服器上自建房屋沒有房間，照樣開）
    local roomSq = squares["50,59,0"] or square(50, 59, 0)
    local noRoom = roomSq.getRoom
    function roomSq:getRoom() return {} end
    give(SW, { ["Base.ElectronicsScrap"] = 1, ["Base.ElectricWire"] = 1 })
    check(build(SW, 3, "switch_01_0", { 50, 59, 0 }) and made[3] and made[3].on == nil and made[2].on == true,
        "地圖房屋裡的開關不強制開（沿用房間狀態）；不在房間裡的開關照樣開")
    roomSq.getRoom = noRoom
    ISMoveableSpriteProps = nil

    -- 家電：容器型別是壁爐的照地圖建成 IsoFireplace（原版的生火選單只認它），不是 IsoThumpable；退料記在帳本、發編號，
    -- 本工具拆得到（退料照帳本），移出世界時帳本清掉。mock 照圖沒寫 ContainerCapacity 的壁爐：建構子與 addToWorld 都不建容器
    -- （IsoFireplace.java:61-67,436-441），要照地圖讀檔補建（審查 1109 Codex）
    local fires = {}
    IsoFireplace = { new = function(_, sq, spr)
        local o = { class = "IsoFireplace", spr = spr, md = {}, keyId = -1 }
        function o:getKeyId() return self.keyId end
        function o:setKeyId(v) self.keyId = v end
        function o:setRenderYOffset(v) self.yoff = v end
        function o:getModData() return self.md end
        function o:hasModData() return true end
        function o:setExplored() end
        function o:transmitCompleteItemToClients() self.sent = true end
        function o:getSquare() return sq end
        function o:getSprite() return spr end
        function o:getSpriteGridObjectsIncludingSelf() return javaList({ self }) end
        function o:isConnectedSpriteGridObject(x) return x == self end
        function o:isObjectNoContainerOrEmpty() return true end
        function o:setMovedThumpable(v) self.moved = v end
        function o:getContainerCount() return self.container and 1 or 0 end
        function o:getContainer() return self.container end
        function o:getContainerByIndex(i) return i == 0 and self.container or nil end
        function o:createContainersFromSpriteProperties()
            self.container = self.container or { type = spr:getProperties():get("container"), cap = 50,
                getType = function(s) return s.type end, getCapacity = function(s) return s.cap end,
                setCapacity = function(s, v) s.cap = v end }
        end
        fires[#fires + 1] = o
        return o
    end }
    local realInst = instanceof
    instanceof = function(o, cls) return type(o) == "table" and o.class == cls end
    local FP = who(2112, 51.5, 60.5)
    give(FP, { ["Base.Plank"] = 20, ["Base.Nails"] = 20 })
    local fok, _, fa = build(FP, 1, "fire_01_0", { 50, 60, 0 })
    local F1 = fires[1]
    local fmats = F1 and MinidoracatBuilder.Ledger.get(F1)
    check(fok and F1 and F1.sent and F1.md.builderEntry == "fire_01_0" and F1.keyId > 0 and fmats ~= nil
        and squares["50,60,0"].objects[1] == F1 and MinidoracatBuilder.Place.refundOf(F1) == fmats
        and MinidoracatBuilder.Dismantle.kindOf(F1) == "container" and F1:getContainer() ~= nil
        and F1:getContainer().type == "fireplace" and F1.moved == true,
        "壁爐：照地圖建成 IsoFireplace（不是 IsoThumpable）、有壁爐容器、記進帳本發編號；退料照帳本，本工具拆得到；"
            .. "擋路的圖殭屍打得壞（" .. tostring(fa and fa.code) .. "）")
    fire("OnObjectAboutToBeRemoved", F1)
    check(MinidoracatBuilder.Ledger.get(F1) == nil, "壁爐移出世界：帳本那一筆清掉")
    -- 家電原地替換：舊的已付料照帳本算（不是 buildMaterials），同價不用補；新的另發編號，舊的移出世界時那筆清掉
    -- （審查 1109 Codex 的驗證缺口）。這一格的移除照引擎先觸發 OnObjectAboutToBeRemoved；蓋好後格子照引擎變實心
    -- （AddSpecialObject 重算格子屬性），新的那件才算被舊的擋住、走替換
    local repOpt = {}
    local repSq = square(51, 61, 0, repOpt)
    local realRm = repSq.transmitRemoveItemFromSquare
    function repSq:transmitRemoveItemFromSquare(obj, safely)
        fire("OnObjectAboutToBeRemoved", obj)
        return realRm(self, obj, safely)
    end
    local nFires = #fires
    build(FP, 2, "fire_01_0", { 51, 61, 0 })
    local FA = fires[nFires + 1]
    repOpt.solid = true
    local planks, nails = FP.inv:count("Base.Plank"), FP.inv:count("Base.Nails")
    local rok, rcmd, ra = build(FP, 3, "fire_01_1", { 51, 61, 0 })
    local FB = fires[nFires + 2]
    check(rok and rcmd == "placed" and ra.replaced == true and FA ~= nil and FB ~= nil and FB.keyId > 0
        and FB.keyId ~= FA.keyId and MinidoracatBuilder.Ledger.get(FA) == nil and MinidoracatBuilder.Ledger.get(FB) ~= nil
        and FP.inv:count("Base.Plank") == planks and FP.inv:count("Base.Nails") == nails
        and repSq.objects[#repSq.objects] == FB,
        "壁爐原地換成另一款：舊的照帳本算已付料（同價不用補）、新的另發編號，舊的那筆清掉（" .. tostring(ra.code) .. "）")
    repSq.transmitRemoveItemFromSquare = realRm
    instanceof = realInst
    IsoFireplace = nil

    -- 窗簾：掛在窗框上；面向 E 的窗框在本格西邊，面向 W 的在東邊那格
    local function framed(x, y, extra, owner)
        local flags = { WindowW = true }
        for k, v in pairs(extra or {}) do flags[k] = v end
        local sq = square(x, y, 0, { flags = flags, owner = owner })
        local props = { has = function(_, k) return (type(k) == "table" and k.name or k) == "WindowW" end,
            get = function() return nil end }
        sq.objects[1] = { getProperties = function() return props end, getSprite = function() return nil end,
            hasModData = function() return false end, getSprite = function() return nil end }
        return sq
    end
    local cq = framed(53, 57)
    local other = { getProperties = function() return { has = function() return false end, get = function() return nil end } end,
        getSprite = function() return nil end, hasModData = function() return false end }
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
        function o:hasModData() return next(self.md) ~= nil end
        function o:setExplored() end
        function o:transmitCompleteItemToClients() end
        function o:getSquare() return sq end
        function o:getSprite() return spriteMap[name] end
        function o:getContainerCount() return 0 end
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
        getType = function() return T.curtainW end, getSprite = function() return nil end, isCurtain = true,
        hasModData = function() return false end, getSprite = function() return nil end }
    local realInstanceof = instanceof
    instanceof = function(o, cls) return cls == "IsoCurtain" and o.isCurtain == true end
    check(free == nil and cur("cur_01_4", 55, 59) == "BLOCKED", "同一面掛著床單窗簾：擋下（原版搬家具同規則）")
    instanceof = realInstanceof

    -- 屋頂：一樓不查支撐；二樓起要有東西撐著（正下方有牆、四鄰有地板或屋頂）；殭屍不打、不擋整格、重算有沒有屋頂
    square(56, 57, 0, { wallW = {} })
    square(56, 57, 1)
    square(57, 57, 1)
    square(58, 58, 1)
    square(59, 57, 0, { stairs = true, wallW = {} })
    square(59, 57, 1)
    square(59, 58, 0, { wallN = {} })
    local RP = who(2106, 57.5, 57.5)
    local PV = { preview = true }
    check(Check.item(RP, "roof_01_0", 0, { 58, 58, 1 }) == "BLOCKED" and Check.item(RP, "roof_01_0", 0, { 59, 57, 1 }) == "BLOCKED",
        "屋頂擋下：二樓沒有東西撐著、正下方是樓梯")
    square(60, 60, -1, { stairs = true })
    check(Check.item(RP, "roof_01_0", 0, { 56, 58, 0 }, PV) == nil and Check.item(RP, "roof_01_0", 0, { 56, 58, 0 }) == nil
        and MinidoracatBuilder.Place.roofAt(56, 58, 0) and MinidoracatBuilder.Place.roofAt(56, 58, -1) == false
        and MinidoracatBuilder.Place.roofAt(60, 60, 0) == false,
        "一樓的屋頂片不查支撐（屋簷、貼牆的邊緣裝飾在地圖上放在一樓）：預覽與伺服器都放行；地下室不放，地下室樓梯口上面也不放")
    check(Check.item(RP, "roof_01_0", 0, { 58, 59, 1 }, PV) == "BLOCKED" and Check.item(RP, "roof_01_0", 0, { 59, 58, 1 }, PV) == nil
        and squares["58,59,1"] == nil and squares["59,58,1"] == nil,
        "預覽：上一層的格子還沒建也照座標查撐不撐得住（不補格子）")
    -- 地板往上一層（使用者 2026-11-09 選）：正下方有牆撐得住；旁邊同一層有地板、同一排前面判定可蓋的地板（planned）也算；
    -- 什麼都沒有、正下方是樓梯的擋下；一樓一律可以。預覽照座標（格子還沒建、不補）；伺服器補了格子照同一份
    local Place = MinidoracatBuilder.Place
    square(300, 300, 0, { wallN = {} })
    square(302, 302, 1, { flags = { solidfloor = true } })
    square(304, 300, 0, { stairs = true, wallW = {} })
    check(Place.floorAt(300, 300, 1) and Place.floorAt(303, 302, 1) and Place.floorAt(306, 306, 1, { [Place.key(307, 306, 1)] = true })
        and not Place.floorAt(306, 306, 1) and not Place.floorAt(304, 300, 1) and Place.floorAt(306, 306, 0),
        "上一層的地板：正下方有牆、旁邊有地板、同一排前面的格子都撐得住；沒東西撐、正下方是樓梯擋下；一樓一律可以")
    -- 斜坡頂接到這格也算（同原版 connectedWithFloor，IsoGridSquare.java:3485-3505：西邊下一層的斜坡朝東高 1）；
    -- 地下室（z＜0）牆不算，照原版要旁邊的地板（審查 1109 Grok：寫進玩家文字）
    local slope = square(309, 310, 0)
    function slope:getSlopedSurfaceHeight(dir) return dir == IsoDirections.E and 1 or 0 end
    square(312, 310, -2, { wallN = {} })
    check(Place.floorAt(310, 310, 1) and not Place.floorAt(312, 310, -1),
        "上一層的地板：西邊下一層的斜坡頂接到這格也撐得住；地下室正下方的牆不算（照原版）")
    square(57, 55, 0, { wallW = {} })
    check(Check.item(RP, "fup_01_0", 0, { 57, 55, 1 }, PV) == nil and Check.item(RP, "fup_01_0", 0, { 55, 55, 1 }, PV) == "BLOCKED"
        and squares["57,55,1"] == nil and squares["55,55,1"] == nil,
        "地板往上一層：預覽照座標查，格子還沒建也查得出撐不撐得住（不補格子）")
    square(57, 55, 1)
    square(55, 55, 1)
    check(Check.item(RP, "fup_01_0", 0, { 57, 55, 1 }) == nil and Check.item(RP, "fup_01_0", 0, { 55, 55, 1 }) == "BLOCKED",
        "伺服器（格子已補）照同一份：正下方有牆的放行、沒東西撐的擋下")
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
        local o = { class = class or "IsoThumpable", mats = mats or {}, md = { builderEntry = spr:getName() }, keyId = -1,
            floor = spr:getProperties():has(IsoFlagType.solidfloor) } -- isFloor 是建的時候設的欄位，換圖不變
        function o:getSprite() return spr end
        function o:getSquare() return sq end
        function o:hasModData() return true end
        function o:getModData() return self.md end
        function o:isDismantable() return self.dism ~= false end
        function o:setIsDismantable(v) self.dism = v end
        function o:getBuildMaterials() return self.mats end
        function o:isFloor() return self.floor end
        function o:hasBuildMaterials() return next(self.mats) ~= nil end
        function o:isCorner() return self.corner == true end
        function o:setCorner(v) self.corner = v end
        function o:setCanPassThrough(v) self.pass = v end
        function o:isObjectNoContainerOrEmpty() return not self.full end
        function o:getSpriteGridObjectsIncludingSelf() return javaList(self.cands or self.group or { self }) end
        function o:isConnectedSpriteGridObject(x) return x == self or (self.group ~= nil and self.group == x.group) end
        function o:isStairsObject() return Rules.typeCode(spr:getType()) == "stairs" end
        function o:hasFluid() return self.fluid == true end
        function o:isBarricaded() return self.barricaded == true end
        function o:getProperties() return spr:getProperties() end
        function o:getTextureName() return spr:getName() end
        function o:getType() return spr:getType() end
        function o:getThumpDmg() return self.dmg or 8 end
        function o:getContainerCount() return 0 end
        function o:getName() return self.name end
        function o:setName(v) self.name = v end
        function o:getKeyId() return self.keyId end
        function o:setKeyId(v) self.keyId = v end
        function o:getAttachedAnimSprite() return nil end -- 引擎：沒有附加圖時是 null
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
        Server.dismantleIntent(p, { n = n, t = { x, y, z, e } })
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
    check(Server.dismantle(O, 1, 1) == false and has(at(72, 71, 0), W) and #sent == 0,
        "別的玩家拿同一個 nonce：沒有請求，不拆、MP 不回覆")
    HARNESS_ROLL = "max"
    check(Server.dismantle(P, 1, 1) == true and not has(at(72, 71, 0), W) and here.dropped["Base.Plank"] == 4
        and here.dropped["Base.Nails"] == 6 and next(W.mats) == nil and (lastSent()) == "dismantled",
        "拆牆：移除、照退料表退到玩家腳下（最多全部）；移除前退料表已清空（先讀再移除）")
    sent = {}
    check(Server.dismantle(P, 1, 1) == false and here.dropped["Base.Plank"] == 4,
        "同一筆請求再送一次：不再拆、不再退")
    HARNESS_ROLL = "min"
    here.dropped = {}
    local W2 = ours(at(72, 72, 0), wallS, { ["Base.Plank"] = "4", ["Base.Nails"] = "6" })
    unbuild(P, 2, 72, 72, 0, "dw_01_0")
    check(Server.dismantle(P, 2, 1) and here.dropped["Base.Plank"] == 1 and here.dropped["Base.Nails"] == 1 and not has(at(72, 72, 0), W2),
        "每項至少退 1 件")
    HARNESS_ROLL = "max"

    -- 拒絕：不在範圍內的照樣留著
    local far = hammerer(2203, 76.5, 76.5, at(76, 76, 0))
    local W3 = ours(at(72, 73, 0), wallS, { ["Base.Plank"] = "4" })
    unbuild(far, 3, 72, 73, 0, "dw_01_0")
    Server.dismantle(far, 3, 1)
    local c, a = lastSent()
    check(c == "dismantleSkipped" and a.code == "TOO_FAR" and has(at(72, 73, 0), W3), "太遠：TOO_FAR、不拆")
    check(Dismantle.check(far, "wall", Dismantle.plan(W3, "wall"), true) == nil, "右鍵選單預覽不查距離（選了會先走過去）")
    local bare = player({ id = 2204, x = 71.5, y = 73.5, here = here })
    unbuild(bare, 4, 72, 73, 0, "dw_01_0")
    Server.dismantle(bare, 4, 1)
    c, a = lastSent()
    check(c == "dismantleSkipped" and a.code == "NO_TOOL" and a.tools[1] == "HAMMER" and has(at(72, 73, 0), W3),
        "沒帶工具（和蓋的時候一樣）：NO_TOOL、列出缺的工具")
    local cheat = player({ id = 2205, x = 71.5, y = 73.5, here = here, cheat = true })
    check(Dismantle.check(cheat, "wall", Dismantle.plan(W3, "wall")) == nil, "建造作弊：不查工具")
    local owned = engineSq(70, 75, 0, { owner = "someone" })
    local W4 = ours(owned, wallS, { ["Base.Plank"] = "4" })
    local SP = hammerer(2206, 70.5, 74.5, at(70, 74, 0))
    unbuild(SP, 5, 70, 75, 0, "dw_01_0")
    Server.dismantle(SP, 5, 1)
    c, a = lastSent()
    check(c == "dismantleSkipped" and a.code == "SAFEHOUSE" and has(owned, W4), "別人的安全屋：SAFEHOUSE、不拆")
    local B = ours(at(73, 71, 0), boxS, { ["Base.Plank"] = "2" })
    B.full = true
    unbuild(P, 6, 73, 71, 0, "db_01_0")
    Server.dismantle(P, 6, 1)
    c, a = lastSent()
    check(c == "dismantleSkipped" and a.code == "NOT_EMPTY" and has(at(73, 71, 0), B), "容器裡還有東西：NOT_EMPTY、不拆（不讓內容物消失）")
    local ch = ours(at(73, 72, 0), chairS, { ["Base.Plank"] = "2" })
    unbuild(P, 7, 73, 72, 0, "dc_01_0")
    Server.dismantle(P, 7, 1)
    c, a = lastSent()
    check(Dismantle.kindOf(ch) == nil and c == "dismantleSkipped" and a.code == "GONE" and has(at(73, 72, 0), ch),
        "能搬的（照原版拿起）不歸本工具拆：找不到可拆的那件（GONE）")

    -- 燈只認帳本：帳本沒記的不拆；帳本裡的照帳本退，移出世界時帳本清掉
    check(type(HARNESS_GOS_KEYS.MinidoracatBuilder) == "table" and HARNESS_GOS_KEYS.MinidoracatBuilder[1] == "built",
        "帳本存檔白名單有 built（漏了重開後帳本消失）")
    check(type(HARNESS_GOS_KEYS.MinidoracatBuilderFloors) == "table"
        and HARNESS_GOS_KEYS.MinidoracatBuilderFloors[1] == "floors", "地板帳本存檔白名單有 floors（漏了重開後地板帳本消失）")
    local fake = ours(at(74, 71, 0), switchS, nil, "IsoLightSwitch")
    local LP = hammerer(2209, 73.5, 71.5, at(73, 71, 0))
    LP.inv:add(item("Base.Screwdriver", { SCREWDRIVER = true }))
    unbuild(LP, 8, 74, 71, 0, "dl_01_0")
    Server.dismantle(LP, 8, 1)
    c, a = lastSent()
    check(c == "dismantleSkipped" and a.code == "NOT_OURS" and has(at(74, 71, 0), fake),
        "燈的 modData 有 builderEntry、帳本沒記：NOT_OURS、不拆不退")
    local L = ours(at(74, 72, 0), switchS, nil, "IsoLightSwitch")
    Ledger.put(L, { ["Base.ElectronicsScrap"] = 1, ["Base.ElectricWire"] = 1 })
    unbuild(LP, 9, 74, 72, 0, "dl_01_0")
    check(Server.dismantle(LP, 9, 1) and at(73, 71, 0).dropped["Base.ElectricWire"] == 1 and not has(at(74, 72, 0), L)
        and Ledger.get(L) == nil, "帳本裡的燈：照帳本退、移除時帳本清掉")

    -- 樓梯：三片加本 MOD 補的平台（帳本有記）一起拆，只照被點的那片退一次；清掉平台格的 ConnectedToStairs
    local function landingAt(sq)
        local l = {}
        function l:getSprite() return landS end
        function l:getSquare() return sq end
        function l:isStairsObject() return false end
        function l:getAttachedAnimSprite() return self.hung end -- 掛在平台上的圖（本工具的地面覆蓋，Place.attach）
        sq.objects[#sq.objects + 1] = l
        return l
    end
    -- 照引擎：本 MOD 傳 skipFloor=true，原版就只回樓梯片（ISBuildUtil.lua:525）；mock 也只回樓梯片
    local function stairsOnly(list)
        return function(_, skipFloor)
            if skipFloor ~= true then error("getStairObjects without skipFloor would add vanilla's landing") end
            return list
        end
    end
    local plat = engineSq(73, 73, 1)
    plat:getModData().ConnectedToStairsfalse = true
    local T0 = ours(at(74, 73, 0), stS[3], { ["Base.Plank"] = "13", ["Base.Nails"] = "8" })
    local M0 = ours(at(75, 73, 0), stS[2], { ["Base.Plank"] = "13", ["Base.Nails"] = "8" })
    local B0 = ours(at(76, 73, 0), stS[1], { ["Base.Plank"] = "13", ["Base.Nails"] = "8" })
    local landing = landingAt(plat)
    Ledger.put(landing, {})
    local realStairs = buildUtil.getStairObjects
    -- 平台旁邊有別的地板時，原版 getStairObjects 只收三片、不收平台（ISBuildUtil.lua:523-537；2026-11-08 Discord 回報
    -- 拆樓梯後平台留著）：平台照位置找，照樣一起拆
    engineSq(72, 72, 1, { floor = {} })
    buildUtil.getStairObjects = stairsOnly({ T0, M0, B0 })
    local SP2 = hammerer(2207, 75.5, 72.5, at(75, 72, 0))
    unbuild(SP2, 10, 75, 73, 0, "ds_01_1")
    check(Server.dismantle(SP2, 10, 1) and not has(at(74, 73, 0), T0) and not has(at(75, 73, 0), M0)
        and not has(at(76, 73, 0), B0) and not has(plat, landing) and plat.md.ConnectedToStairsfalse == nil
        and at(75, 72, 0).dropped["Base.Plank"] == 13 and at(75, 72, 0).dropped["Base.Nails"] == 8 and Ledger.get(landing) == nil,
        "樓梯：點中片，三片與平台一起拆（平台旁邊有別的地板、原版不收平台也一樣）、只退一組、平台格的 ConnectedToStairs 清掉、帳本的平台清掉")

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
    buildUtil.getStairObjects = stairsOnly({ T1, M1, B1 })
    unbuild(SP3, 14, 74, 76, 0, "ds_01_2")
    Server.dismantle(SP3, 14, 1)
    c, a = lastSent()
    check(c == "dismantleSkipped" and a.code == "NOT_OURS" and has(at(74, 76, 0), T1) and has(at(75, 76, 0), M1)
        and has(at(76, 76, 0), B1) and next(at(75, 75, 0).dropped) == nil, "樓梯有一片的記號是 false：整組不拆、不退")
    M1.md.builderEntry = "ds_01_1"
    unbuild(SP3, 15, 74, 76, 0, "ds_01_2")
    check(Server.dismantle(SP3, 15, 1) and not has(at(75, 76, 0), M1) and has(plat1, land1) and Ledger.get(land1) ~= nil,
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
    buildUtil.getStairObjects = stairsOnly({ T2, M2, NM, B2 })
    unbuild(SP3, 16, 74, 77, 0, "ds_01_2")
    check(Server.dismantle(SP3, 16, 1) and not has(at(74, 77, 0), T2) and not has(at(75, 77, 0), M2)
        and not has(at(76, 77, 0), B2) and has(at(75, 77, 0), NM) and has(plat2, land2)
        and has(platN, landN) and Ledger.get(landN) ~= nil,
        "別方向的樓梯片不算這一組（不拆），那組的平台也不動；這一組的平台不在帳本（原本就有的地板）：留著")
    -- 平台在別人的安全屋
    local plat3 = engineSq(73, 76, 1, { owner = "someone" })
    local T3 = ours(at(74, 76, 0), stS[3], { ["Base.Plank"] = "13" })
    local M3 = ours(at(75, 76, 0), stS[2], { ["Base.Plank"] = "13" })
    local B3 = ours(at(76, 76, 0), stS[1], { ["Base.Plank"] = "13" })
    local land3 = landingAt(plat3)
    Ledger.put(land3, {})
    buildUtil.getStairObjects = stairsOnly({ T3, M3, B3 })
    unbuild(SP3, 17, 74, 76, 0, "ds_01_2")
    check(Server.dismantle(SP3, 17, 1) and not has(at(75, 76, 0), M3) and has(plat3, land3), "平台在別人的安全屋：拆樓梯、平台留著")
    -- 平台也是另一組往北爬的樓梯的平台（那組的頂片在平台南邊）：拆這一組、平台留著（另一組還要走），帳本照舊
    local plat5 = engineSq(73, 75, 1)
    local T5 = ours(at(74, 75, 0), stS[3], { ["Base.Plank"] = "13" })
    local M5 = ours(at(75, 75, 0), stS[2], { ["Base.Plank"] = "13" })
    local B5 = ours(at(76, 75, 0), stS[1], { ["Base.Plank"] = "13" })
    local land5 = landingAt(plat5)
    Ledger.put(land5, {})
    local southTop = engineSq(73, 76, 0, { flags = { stairsTN = true } })
    buildUtil.getStairObjects = stairsOnly({ T5, M5, B5 })
    check(Dismantle.plan(T5, "stairs").landing == nil, "平台也通到另一組（往北爬的頂片在平台南邊）：這一組的 plan 不帶平台")
    unbuild(SP3, 23, 74, 75, 0, "ds_01_2")
    check(Server.dismantle(SP3, 23, 1) and not has(at(74, 75, 0), T5) and has(plat5, land5) and Ledger.get(land5) ~= nil,
        "平台也通到另一組：拆這一組、平台與帳本留著")
    check(southTop:has(IsoObjectType.stairsTN), "夾具：另一組頂片的旗標查得到")
    -- 往北爬的（N 型：三片沿 +y、平台在頂片北邊上一層），另一組往西爬的頂片在平台東邊；平台上掛著地面覆蓋
    do
        local stN = { sprite("dsn_01_0", 2216, { type = T.stairsBN }), sprite("dsn_01_2", 2217, { type = T.stairsMN }),
            sprite("dsn_01_3", 2218, { type = T.stairsTN }) }
        for x = 78, 84 do engineSq(x, 75, 0) end -- 站位那一排（伺服器找路要鄰格）
        local NP = hammerer(2219, 81.5, 75.5, at(81, 75, 0))
        local function setN(x, n)
            local plat = engineSq(x, 71, 1)
            local set = { top = ours(engineSq(x, 72, 0), stN[3], { ["Base.Plank"] = "13" }),
                mid = ours(engineSq(x, 73, 0), stN[2], { ["Base.Plank"] = "13" }),
                bottom = ours(engineSq(x, 74, 0), stN[1], { ["Base.Plank"] = "13" }), plat = plat, land = landingAt(plat) }
            Ledger.put(set.land, {})
            buildUtil.getStairObjects = stairsOnly({ set.top, set.mid, set.bottom })
            unbuild(NP, n, x, 74, 0, "dsn_01_0")
            return set
        end
        engineSq(78, 71, 1, { floor = {} }) -- 平台西邊那格的地板（原版 getStairObjects 這時不收平台）
        local N1 = setN(79, 31)
        N1.plat:getModData().ConnectedToStairstrue = true
        check(Server.dismantle(NP, 31, 1) and not has(at(79, 72, 0), N1.top) and not has(at(79, 74, 0), N1.bottom)
            and not has(N1.plat, N1.land) and Ledger.get(N1.land) == nil and N1.plat.md.ConnectedToStairstrue == nil,
            "往北爬的：平台在頂片北邊上一層，旁邊有地板也一起拆、帳本清掉、平台格的 ConnectedToStairstrue 清掉")
        local westTop = engineSq(82, 71, 0, { flags = { stairsTW = true } })
        local N2 = setN(81, 32)
        check(Dismantle.plan(N2.top, "stairs").landing == nil and westTop:has(IsoObjectType.stairsTW),
            "往北爬的：平台也通到往西爬的那組（頂片在平台東邊）時 plan 不帶平台")
        check(Server.dismantle(NP, 32, 1) and not has(at(81, 72, 0), N2.top) and has(N2.plat, N2.land)
            and Ledger.get(N2.land) ~= nil, "往北爬的：平台也通到另一組，拆這一組、平台與帳本留著")
        local N3 = setN(83, 33)
        N3.land.hung = javaList({ {} })
        check(Server.dismantle(NP, 33, 1) and not has(at(83, 72, 0), N3.top) and has(N3.plat, N3.land)
            and Ledger.get(N3.land) ~= nil, "平台上掛著地面覆蓋：拆樓梯、平台與覆蓋留著（拆了覆蓋會跟著消失、不退料）")
        -- 掛過又拆掉的覆蓋：引擎留下空清單、不設回 nil（IsoObject.java:3317-3329），照常拆
        local N4 = setN(80, 34)
        N4.land.hung = javaList({})
        check(Server.dismantle(NP, 34, 1) and not has(at(80, 72, 0), N4.top) and not has(N4.plat, N4.land)
            and Ledger.get(N4.land) == nil, "平台上的覆蓋拆掉了（附加圖清單是空的）：平台照常一起拆")
    end
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
    check(Server.dismantle(GP, 11, 1) and not has(at(71, 75, 0), GA) and not has(at(72, 75, 0), GB) and has(at(72, 75, 0), GX)
        and at(71, 74, 0).dropped["Base.Plank"] == 4, "多格：同一組整組拆、每片照自己的退料表退（2＋2）；原點不同的別組那片不拆")
    -- 同一組有一片沒有記號：整組不拆、不退
    local GC = ours(at(73, 74, 0), boxS, { ["Base.Plank"] = "2" })
    local GD = ours(at(74, 74, 0), boxS, { ["Base.Plank"] = "2" })
    GD.md.builderEntry = nil
    local g2 = { GC, GD }
    GC.group, GD.group, GC.cands = g2, g2, { GC, GD }
    unbuild(GP, 22, 73, 74, 0, "db_01_0")
    Server.dismantle(GP, 22, 1)
    c, a = lastSent()
    check(c == "dismantleSkipped" and a.code == "NOT_OURS" and has(at(73, 74, 0), GC) and has(at(74, 74, 0), GD)
        and at(71, 74, 0).dropped["Base.Plank"] == 4, "多格：同一組有一片沒有本 MOD 的記號：整組不拆、不退")

    -- 原版拆解擋的：門框裝著門、窗框釘著木板、樓梯頂端接著的地板；移除沒生效不退料
    local WP = hammerer(2211, 75.5, 70.5, at(75, 70, 0))
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
    Server.dismantle(WP, 19, 1)
    c, a = lastSent()
    check(c == "dismantleRefused" and a.code == "INTERNAL" and has(stuck, WS) and next(at(75, 70, 0).dropped) == nil,
        "移除沒生效：INTERNAL、不退料、整批停（dismantleRefused，可能只拆了一部分）")
    sb.WhereCanBuild = 2
    local WW = ours(at(74, 71, 0), wallS, { ["Base.Plank"] = "4" })
    unbuild(WP, 20, 74, 71, 0, "dw_01_0")
    check(Server.dismantle(WP, 20, 1) and not has(at(74, 71, 0), WW), "只能在安全屋內蓋（WhereCanBuild=2）：拆除不看，安全屋外照樣能拆")
    sb.WhereCanBuild = nil
    local WE = ours(at(77, 70, 0), wallS, { ["Base.Plank"] = "4" })
    unbuild(WP, 21, 77, 70, 0, "dw_01_0")
    nowMs = nowMs + 180000 * 32 + 1000 -- 期限照一區最多幾件（MaxCellsPerDrag 預設 32）×每件 180 秒
    check(Server.dismantle(WP, 21, 1) == false and has(at(77, 70, 0), WE), "請求過期（走太久，期限照一區最多件數給）：不拆")

    -- 地板：一樓拆了換泥土；二樓以上格上還有東西不拆
    local F0 = ours(at(73, 75, 0), floorS, {})
    F0.dism = false
    MinidoracatBuilder.Floors.put(F0, { ["Base.Plank"] = 1 })
    unbuild(GP, 12, 73, 75, 0, "df_01_0")
    local dirt
    if Server.dismantle(GP, 12, 1) then
        for _, o in ipairs(at(73, 75, 0).objects) do if o.name == "blends_natural_01_64" then dirt = o end end
    end
    check(dirt and not has(at(73, 75, 0), F0), "一樓的地板拆了換泥土（照原版）")
    local up = engineSq(72, 76, 1)
    local F1 = ours(up, floorS, { ["Base.Plank"] = "1" })
    ours(up, wallS, {})
    unbuild(GP, 13, 72, 76, 1, "df_01_0")
    Server.dismantle(GP, 13, 1)
    c, a = lastSent()
    check(c == "dismantleSkipped" and a.code == "FLOOR_IN_USE" and has(up, F1), "二樓的地板上還有牆：FLOOR_IN_USE、不拆")

    -- 一樓的地板退料在伺服器的地板帳本：本工具照它退，不看 modData；圖和蓋的時候不同的地板不退
    local FP = hammerer(2230, 75.5, 76.5, at(75, 76, 0))
    FP.inv:add(item("Base.Screwdriver", { SCREWDRIVER = true }))
    check((function()
        local Floors = MinidoracatBuilder.Floors
        local G = ours(at(74, 75, 0), floorS, {})
        G.dism = false
        Floors.put(G, { ["Base.Plank"] = 3 })
        G.md.builderRefund = { ["Base.Axe"] = "99" } -- modData 裡的退料表不採信
        local drop = at(75, 76, 0)
        drop.dropped = {}
        unbuild(FP, 22, 74, 75, 0, "df_01_0")
        return Server.dismantle(FP, 22, 1) and not has(at(74, 75, 0), G) and drop.dropped["Base.Plank"] == 3
            and drop.dropped["Base.Axe"] == nil and Floors.get(G) == nil
    end)(), "一樓的地板（不給原版搬動工具拆）：照地板帳本退、不看 modData、移除時帳本清掉")
    check((function()
        local Floors = MinidoracatBuilder.Floors
        local otherS = sprite("dfo_01_9", 2215, { flags = { "solidfloor" } })
        local V = ours(at(75, 75, 0), floorS, {})
        V.dism = false
        Floors.put(V, { ["Base.Plank"] = 3 })
        function V:getSprite() return otherS end
        local drop = at(75, 76, 0)
        drop.dropped = {}
        unbuild(FP, 23, 75, 75, 0, "dfo_01_9")
        Server.dismantle(FP, 23, 1)
        local c1, a1 = lastSent()
        unbuild(FP, 24, 75, 75, 0, "df_01_0")
        Server.dismantle(FP, 24, 1)
        local c2, a2 = lastSent()
        V.md.builderEntry = "dfo_01_9"
        unbuild(FP, 25, 75, 75, 0, "dfo_01_9")
        Server.dismantle(FP, 25, 1)
        local c3, a3 = lastSent()
        return c1 == "dismantleSkipped" and a1.code == "GONE" and c2 == "dismantleSkipped" and a2.code == "GONE"
            and c3 == "dismantleSkipped" and a3.code == "NOT_OURS" and next(drop.dropped) == nil and Floors.get(V) ~= nil
    end)(), "地板的圖和蓋的時候不同就不退")
    check((function()
        local Floors, Place = MinidoracatBuilder.Floors, MinidoracatBuilder.Place
        local sq = at(76, 75, 0)
        local V = ours(sq, floorS, {})
        V.dism = false
        Floors.put(V, { ["Base.Plank"] = 3 })
        local L = ours(sq, switchS, nil, "IsoLightSwitch")
        Ledger.put(L, { ["Base.ElectricWire"] = 1 })
        local W = ours(sq, wallS, { ["Base.Plank"] = "4" })
        local drop = at(75, 76, 0)
        drop.dropped = {}
        function V:getSprite() return switchS end
        V.md.builderEntry = "dl_01_0"
        unbuild(FP, 26, 76, 75, 0, "dl_01_0")
        Server.dismantle(FP, 26, 1)
        local c1, a1 = lastSent()
        function V:getSprite() return floorS end
        V.md.builderEntry = nil
        function L:getSprite() return floorS end
        L.md.builderEntry = "df_01_0"
        unbuild(FP, 27, 76, 75, 0, "df_01_0")
        Server.dismantle(FP, 27, 1)
        local c2, a2 = lastSent()
        function W:getSprite() return floorS end
        local own = Place.refundOf(W) == W.mats and W.mats["Base.Plank"] == "4"
        sq:transmitRemoveItemFromSquare(L)
        sq:transmitRemoveItemFromSquare(W)
        return c1 == "dismantleSkipped" and a1.code == "NOT_OURS" and c2 == "dismantleSkipped" and a2.code == "NOT_OURS"
            and own and next(drop.dropped) == nil and has(sq, V) and Floors.get(V) ~= nil
            and Floors.get(V).i["Base.Plank"] == 3
    end)(), "同一格不同物件的退料紀錄互不影響")
    check((function()
        local Floors, Place = MinidoracatBuilder.Floors, MinidoracatBuilder.Place
        local sq = at(77, 74, 0)
        local A = ours(sq, floorS, {})
        Floors.put(A, { ["Base.Plank"] = 2 })
        function A:getSprite() return wallS end
        function A:getProperties() return wallS:getProperties() end
        function A:getTextureName() return wallS:getName() end
        Place.clearFloor(sq)
        return not has(sq, A) and Floors.get(A) == nil
    end)(), "放地板前清掉這一格本 MOD 的舊地板：照建的時候的地板欄位，不看現在的圖")
    check((function()
        local Floors, Place = MinidoracatBuilder.Floors, MinidoracatBuilder.Place
        local sq = at(77, 73, 0)
        local A = ours(sq, floorS, {})
        A.dism = false
        Floors.put(A, { ["Base.Plank"] = 2 })
        function A:getSprite() return wallS end
        function A:getProperties() return wallS:getProperties() end
        function A:getTextureName() return wallS:getName() end
        local B = ours(sq, floorS, {})
        local second = Place.refundOf(B)
        A.md.builderEntry = nil
        sq:transmitRemoveItemFromSquare(A)
        return second == nil and Floors.get(B) == nil
    end)(), "一格有兩片地板時不退；地板移掉時一律清掉這一格的地板帳本")

    -- 讀檔搬移（Place.migrate，LoadGridsquare）：0.1.1 以前一樓地板的退料在 buildMaterials、牆角柱可穿過又不是轉角
    check((function()
        local Place, Floors = MinidoracatBuilder.Place, MinidoracatBuilder.Floors
        local postS = sprite("dp_01_0", 2216, { flags = { "WallSE" } })
        local edgeS = sprite("dp_01_1", 2217, { flags = { "WallSE", "collideN" } }) -- 現在不列（BLOCKS_EDGE）的牆角柱
        local fenceS = sprite("dp_01_2", 2218, { flags = { "WallSE", "HoppableN", "collideN" } }) -- 現在歸柵欄
        local pickS = sprite("dfm_01_0", 2219, { flags = { "solidfloor" }, keys = { IsMoveAble = "" } })
        local sq = engineSq(70, 77, 0)
        local OF = ours(sq, floorS, { ["Base.Plank"] = "2" })
        local OP = ours(sq, postS, {})
        OP.corner, OP.pass = false, true
        local OE = ours(sq, edgeS, {})
        OE.corner, OE.pass = false, true
        local OC = ours(sq, fenceS, { ["Base.Plank"] = "2" })
        local OW = ours(sq, wallS, { ["Base.Plank"] = "4" })
        local NO = ours(sq, floorS, { ["Base.Plank"] = "5" })
        NO.md.builderEntry = nil -- 不是本 MOD 蓋的
        local UP = ours(engineSq(70, 77, 1), floorS, { ["Base.Plank"] = "1" })
        local OZ = ours(engineSq(72, 77, 0), floorS, {}) -- 沒付料（建造作弊、材料倍率 0）
        local OK = ours(engineSq(73, 77, 0), pickS, { ["Base.Plank"] = "1" }) -- 能搬的地板：本工具不拆
        fire("LoadGridsquare", sq)
        fire("LoadGridsquare", sq) -- 重複跑結果一樣
        for _, o in ipairs({ UP, OZ, OK, OZ }) do Place.migrate(o) end
        local r, z = Floors.get(OF), Floors.get(OZ)
        return r and r.s == "df_01_0" and r.i["Base.Plank"] == "2" and next(OF.mats) == nil and OF.dism == false
            and OP.corner == true and OP.pass == false and OE.corner == true and OE.pass == false
            and OC.corner ~= true and OC.pass == nil and OW.corner ~= true and OW.mats["Base.Plank"] == "4"
            and NO.mats["Base.Plank"] == "5" and NO.dism == nil and UP.mats["Base.Plank"] == "1" and UP.dism == nil
            and z and next(z.i) == nil and Dismantle.kindOf(OZ) == "floor" and next(Place.refundOf(OZ)) == nil
            and Floors.get(OK) == nil and next(OK.mats) == nil and OK.dism == false
            and OW.name == "dw_01_0" and NO.name == nil
    end)(), "讀檔：一樓地板的退料搬進地板帳本（沒付料的記空表）、不給原版搬動工具拆，牆角柱改成轉角＋不可穿過；"
        .. "現在歸柵欄的、牆、別人的、二樓的地板不動，能搬的地板不記帳")
    check((function()
        local Place, Floors = MinidoracatBuilder.Place, MinidoracatBuilder.Floors
        local OL = ours(engineSq(71, 77, 0), floorS, { ["Base.Plank"] = "2" })
        local inst = Floors.instance
        Floors.instance = nil -- 帳本還沒建好（單機讀檔的第一批格子）
        Place.migrate(OL)
        Floors.instance = inst
        local onServer = Place.refundOf(OL)
        local realS = isServer
        isServer = function() return false end
        local kept = OL.mats["Base.Plank"] == "2" and Place.refundOf(OL) == OL.mats
        isServer = realS
        Place.migrate(OL)
        local r = Floors.get(OL)
        return onServer == nil and kept and r and r.i["Base.Plank"] == "2" and next(OL.mats) == nil
    end)(), "讀檔時帳本還沒建好：退料留在 buildMaterials（單機照它退，專用伺服器不照），下次載入才搬進帳本")

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

    -- 一區拆除預覽的快取與防抖（temp/area-perf：40×40 大基地拖曳時幀時間 29 ms、移動時 100 ms）
    require "MinidoracatBuilder/Area"
    local Area, Cursor, Rules, Materials = MinidoracatBuilder.Area, MinidoracatBuilder.Cursor, MinidoracatBuilder.Rules,
        MinidoracatBuilder.Materials
    local function withBox(o, items) -- 容器（stamp 讀 getContainer）；非容器也要有 getContainer
        o.cont = items and { list = items } or nil
        function o:getContainer()
            local c = self.cont
            return c and { getItems = function() return javaList(c.list) end } or nil
        end
        return o
    end
    for x = 90, 93 do engineSq(x, 90, 0) end
    local AW = {}
    for i = 1, 4 do AW[i] = withBox(ours(at(89 + i, 90, 0), wallS, { ["Base.Plank"] = "4" })) end
    local AB = withBox(ours(engineSq(94, 90, 0), boxS, { ["Base.Plank"] = "2" }), { "Base.Nails" })
    AB.full = true
    local AP = player({ id = 2290, x = 92.5, y = 91.5, here = at(92, 90, 0) })
    function AP.inv:getItems() return javaList(self.items) end
    local function codes(list)
        local out = {}
        for i, t in ipairs(list) do out[i] = t.kind .. ":" .. tostring(t.code) end
        return table.concat(out, ",")
    end
    -- 種類照圖名記住：同一張圖整區只分類一次，結果和不記一樣
    local realClassify, nClassify = Rules.classify, 0
    Rules.classify = function(spr) nClassify = nClassify + 1 return realClassify(spr) end
    local list = Area.collect(90, 90, 94, 90, 0, AP)
    local memoN = nClassify
    nClassify = 0
    local same = true
    for _, t in ipairs(list) do
        if t.obj and Area.route(t.obj) ~= t.route then same = false end
    end
    Rules.classify = realClassify
    check(#list == 5 and memoN == 2 and nClassify == 5 and same,
        "一區拆除 collect：同一張圖只分類一次（牆 4 件＋容器＝2 次；不記時 5 次），結果和不記一樣（" .. memoN .. "／" .. nClassify .. "）")
    -- 缺的工具：同一次 collect 照圖名記住，工具進背包後下一次重算
    local realMissing, nMissing = Materials.missingTools, 0
    Materials.missingTools = function(...) nMissing = nMissing + 1 return realMissing(...) end
    local bare = codes(Area.collect(90, 90, 94, 90, 0, AP))
    local missN = nMissing
    local function toolsFresh(collect)
        local hammer = AP.inv:add(item("Base.Hammer", { HAMMER = true }))
        local after = codes(collect())
        AP.inv:Remove(hammer)
        return after == "container:NOT_EMPTY,wall:nil,wall:nil,wall:nil,wall:nil"
    end
    check(bare == "container:NOT_EMPTY,wall:NO_TOOL,wall:NO_TOOL,wall:NO_TOOL,wall:NO_TOOL" and missN == 1
        and toolsFresh(function() return Area.collect(90, 90, 94, 90, 0, AP) end),
        "沒帶鐵鎚：4 面牆都 NO_TOOL、缺的工具只算一次（" .. missN .. "）；帶了之後下一次 collect 重算、都能拆（" .. bare .. "）")
    local realCheck, shared = Dismantle.check, {} -- 植入違規：缺工具的結果跨 collect 沿用
    Dismantle.check = function(p, k, pl, pv) return realCheck(p, k, pl, pv, shared) end
    Area.collect(90, 90, 94, 90, 0, AP)
    local planted = toolsFresh(function() return Area.collect(90, 90, 94, 90, 0, AP) end)
    Dismantle.check = realCheck
    Materials.missingTools = realMissing
    check(planted == false, "植入違規（缺工具跨 collect 沿用）：帶了鐵鎚仍是 NO_TOOL，上一條抓得到")
    -- 預覽照世界戳記重算：範圍、世界都沒變回同一份；多一件、容器放東西、背包變了都重算。超過上限的帶 over
    AP.inv:add(item("Base.Hammer", { HAMMER = true }))
    local realMax = sb.MaxCellsPerDrag
    sb.MaxCellsPerDrag = 2
    local realCollect, nCollect = Area.collect, 0
    Area.collect = function(...) nCollect = nCollect + 1 return realCollect(...) end
    local function previewTracks(stamp)
        local realStamp = Area.stamp
        if stamp then Area.stamp = stamp end
        nCollect = 0
        local p1 = Area.preview(AP, 90, 90, 94, 90, 0)
        local p2 = Area.preview(AP, 90, 90, 94, 90, 0)
        local W5 = withBox(ours(engineSq(91, 91, 0), wallS, {}))
        local p3 = Area.preview(AP, 90, 90, 94, 91, 0)
        local p4 = Area.preview(AP, 90, 90, 94, 91, 0)
        at(91, 91, 0).removeHere(W5) -- 別人拆掉了
        local p5 = Area.preview(AP, 90, 90, 94, 91, 0)
        AB.cont.list[#AB.cont.list + 1] = "Base.Nails"
        local p6 = Area.preview(AP, 90, 90, 94, 91, 0)
        local hammer = AP.inv.items[#AP.inv.items]
        AP.inv:Remove(hammer)
        local p7 = Area.preview(AP, 90, 90, 94, 91, 0)
        AP.inv:add(hammer)
        Area.stamp = realStamp
        return p1 == p2 and p3 == p4 and p4 ~= p5 and p5 ~= p6 and p6 ~= p7 and nCollect == 5, p1
    end
    local tracks, p1 = previewTracks()
    local over, sendN, marked = 0, 0, 0
    for _, c in ipairs(p1.cells) do
        if not c.bad then sendN = sendN + 1 elseif c.over then over = over + 1 else marked = marked + 1 end
    end
    check(tracks, "預覽：範圍、世界都沒變回同一份不重算；牆被拆、容器放東西、背包變了都重算（collect " .. nCollect .. " 次）")
    check(sendN == 2 and over == 2 and marked == 1,
        "預覽：上限 2 時兩格要拆、超過上限的兩格 over（不畫三角）、不空的容器照舊標（" .. sendN .. "／" .. over .. "／" .. marked .. "）")
    check(previewTracks(function() return "same" end) == false, "植入違規（世界戳記不變）：拆掉、放東西都不重算，上一條抓得到")
    Area.collect = realCollect
    sb.MaxCellsPerDrag = realMax
    -- 游標：範圍變了只畫外框、停住 200 ms 才問預覽、不動時每秒問一次；吸管（沒有 outline）馬上問；三角最多 128 個
    local realCore = getCore
    local color = { getR = function() return 1 end, getG = function() return 0 end, getB = function() return 0 end }
    getCore = function() return { getGoodHighlitedColor = function() return color end,
        getBadHighlitedColor = function() return color end } end
    local function debounced(clock)
        local asked = 0
        local c = setmetatable({ character = { getZ = function() return 0 end }, colors = {}, lineX = 13, lineY = 12,
            area = { preview = function() asked = asked + 1 return { cells = {}, lines = { "p" } } end,
                outline = function() return { cells = {}, lines = { "o" } } end } }, { __index = Cursor })
        local sq = { getX = function() return 10 end, getY = function() return 10 end, getZ = function() return 0 end }
        local t0, seen = nowMs, {}
        local function at2(ms) nowMs = clock and t0 or t0 + ms c:areaValid(sq) seen[#seen + 1] = asked end
        at2(0); at2(100)
        c.lineX = 14
        at2(150); at2(300); at2(360); at2(800); at2(1400)
        nowMs = t0 + 1400
        return table.concat(seen, ","), c.src and c.src[1]
    end
    local seq, label = debounced(false)
    check(seq == "0,0,0,0,1,1,2" and label == "p", "游標：拖曳中只畫外框、範圍停住 200 ms 才算一次，不動時每秒再問一次（" .. seq .. "）")
    check(debounced(true) == "0,0,0,0,0,0,0", "植入違規（時鐘不走、永遠不停住）：上一條抓得到")
    local pick = setmetatable({ character = { getZ = function() return 0 end }, colors = {}, one = true,
        area = { preview = function() return { cells = { { 10, 10, 0, false } }, lines = {} } end } }, { __index = Cursor })
    pick:areaValid({ getX = function() return 10 end, getY = function() return 10 end, getZ = function() return 0 end })
    local cells = {}
    for i = 1, 200 do cells[i] = { x = 100 + i, y = 0, z = 0, bad = true } end
    for i = 201, 260 do cells[i] = { x = 100 + i, y = 0, z = 0, bad = true, over = true } end
    local shown = setmetatable({ colors = {} }, { __index = Cursor })
    shown:areaShow({ cells = cells, lines = {} }, 101, 0, 360, 0, 0)
    local m = 0
    for i = 1, shown.g.n do if shown.g.m[i] ~= 0 then m = m + 1 end end
    local overMarked = false
    for i = 1, shown.g.n do if shown.g.x[i] > 300 and shown.g.m[i] ~= 0 then overMarked = true end end
    getCore = realCore
    check(pick.g and pick.g.n >= 1 and pick.src ~= nil and m == 128 and not overMarked,
        "吸管沒有外框階段、馬上預覽；三角最多 128 個、超過上限的格子不畫三角（" .. m .. "）")
    instanceof = realInst
end
dismantleScenario()

print("情境二十二：第六階段線路（自動接線、按開關切整條、接線指令、權限與範圍、帳本清理、單機接線模式）")
local function circuitScenario()
    nowMs = nowMs + 180000
    local Circuits, Ledger = MinidoracatBuilder.Circuits, MinidoracatBuilder.Ledger
    local realInst, realRegions = instanceof, IsoRegions.getIsoWorldRegion
    instanceof = function(o, cls) return type(o) == "table" and o.class == cls end
    -- 區域：rooms["x,y,z"] = 編號；7、8、10～14＝封閉的小房間，9＝封閉但很大（超過 ROOM_MAX），其他是室外的一大片。
    -- roofLow[編號]＝屋頂不到一半（客戶端不建房間）
    local rooms, roofLow = {}, {}
    IsoRegions.getIsoWorldRegion = function(x, y, z)
        local id = rooms[x .. "," .. y .. "," .. z] or 1
        local size = (id == 1 and 5000) or (id == 9 and 600) or 9
        return { getID = function() return id end, isEnclosed = function() return id ~= 1 end,
            getSquareSize = function() return size end, getRoofCnt = function() return roofLow[id] and 0 or size end }
    end
    -- sq.room＝地圖房屋的房間（userRoom＝true 時是客戶端替自建房屋建的）
    for x = 80, 130 do for y = 100, 110 do
        local sq = square(x, y, 0)
        local orig = sq.transmitRemoveItemFromSquare
        function sq:transmitRemoveItemFromSquare(obj, safely)
            fire("OnObjectAboutToBeRemoved", obj)
            return orig(self, obj, safely)
        end
        function sq:getRoom() return self.room end
        function sq:isUserDefinedRoom() return self.userRoom == true end
    end end
    local function room(id, x1, x2, y1, y2)
        for x = x1, x2 do for y = y1, y2 do rooms[x .. "," .. y .. ",0"] = id end end
    end
    room(7, 100, 102, 100, 102)
    room(8, 110, 112, 100, 102)
    room(9, 80, 99, 105, 110)
    room(10, 125, 127, 100, 102)
    room(11, 125, 127, 106, 108)
    room(12, 120, 122, 106, 108)
    room(13, 100, 101, 105, 106)
    room(14, 102, 103, 105, 106)
    local function at(x, y, z) return squares[x .. "," .. y .. "," .. (z or 0)] end
    local LAMP_KEYS = { lightR = "200", lightG = "180", lightB = "150" }
    local lampS = sprite("cl_01_0", 2301, { type = T.lightswitch, keys = LAMP_KEYS })
    local lampS2 = sprite("cl_01_1", 2302, { type = T.lightswitch, keys = LAMP_KEYS })
    local movS = sprite("cm_01_0", 2303, { type = T.lightswitch,
        keys = { lightR = "200", lightG = "180", lightB = "150", IsMoveAble = "" } })
    local swS = sprite("cs_01_0", 2304, { type = T.lightswitch })
    -- 客戶端自建房間的連動（單機只有一份世界）：HARNESS_CASCADE＝房間裡的物件，開關 switchLight 時全部改成同一個狀態
    HARNESS_CASCADE = nil
    -- IsoLightSwitch：ours＝本 MOD 蓋的（modData 記號＋帳本），mark＝只有 modData 記號、帳本沒記
    local function light(x, y, spr, how)
        local sq = at(x, y)
        local o = { class = "IsoLightSwitch", md = {}, on = true, synced = 0, sq = sq, keyId = -1,
            isLit = spr:getProperties():has("lightR") }
        function o:getSprite() return spr end
        function o:getSquare() return sq end
        function o:hasModData() return true end
        function o:getModData() return self.md end
        function o:getKeyId() return self.keyId end
        function o:setKeyId(v) self.keyId = v end
        function o:isActivated() return self.on end
        function o:setActivated(v) self.on = v end
        function o:hasLightBulb() return self.bulb ~= false end
        function o:switchLight(v)
            self.lit = v
            if HARNESS_CASCADE and not self.isLit then
                for _, c in ipairs(HARNESS_CASCADE) do c.on = v end
            end
        end
        function o:syncIsoObject(_, v)
            if self.boom then error("boom in sync") end
            self.synced = self.synced + 1
            self.sent = v
        end
        function o:getSpriteGridObjectsIncludingSelf() return javaList(self.group or { self }) end
        function o:isConnectedSpriteGridObject(x2) return self.group ~= nil and x2.group == self.group end
        function o:setHighlighted() end
        function o:setHighlightColor() end
        function o:setOutlineHighlight() end
        function o:setOutlineHighlightCol() end
        function o:getCanBeModified() return false end
        function o:canSwitchLight() return false end
        if how == "ours" or how == "mark" then o.md.builderEntry = spr:getName() end
        if how == "ours" then Ledger.put(o, {}) end
        sq.objects[#sq.objects + 1] = o
        return o
    end
    local function last() return sent[#sent] and sent[#sent].args or {} end
    local function act(p, o) return ISToggleLightAction.complete({ character = p, object = o }) end
    local q = 0
    local function cmd(p, c, args)
        nowMs = nowMs + 300
        q = q + 1
        args.q = q
        sent = {}
        Circuits.command(p, c, args)
        return last()
    end
    local function pos(o) return o.sq:getX(), o.sq:getY(), o.sq:getZ() end
    local function wire(p, op, sw, t, extra)
        local x, y, z = pos(sw)
        local a = { op = op, x = x, y = y, z = z, e = sw:getSprite():getName() }
        if t then a.tx, a.ty, a.tz = pos(t); a.te = t:getSprite():getName() end
        for k, v in pairs(extra or {}) do a[k] = v end
        return cmd(p, "wire", a)
    end
    local function ask(p, o, cand)
        local x, y, z = pos(o)
        return cmd(p, "circuit", { x = x, y = y, z = z, e = o:getSprite():getName(), cand = cand })
    end
    local function nL(r) return #(r.l or {}) end
    local function nS(r) return #(r.s or {}) end
    local function wired(r, o)
        local x, y = pos(o)
        for _, c in ipairs(r.l or {}) do if c.x == x and c.y == y and c.e == o:getSprite():getName() then return true end end
        return false
    end
    local O = {} -- 物件（主程式的區域變數有上限）
    local P = player({ id = 2301, x = 101.5, y = 101.5 })

    check(type(HARNESS_GOS_KEYS.MinidoracatBuilder) == "table" and HARNESS_GOS_KEYS.MinidoracatBuilder[2] == "circuits",
        "帳本存檔白名單有 circuits（漏了重開後線路消失）")

    -- 房間 8：開關先放、房間裡沒有燈：不建線路（按的時候照原版），提示之後放的燈會自動接；放燈時接上
    O.SW3 = light(110, 101, swS, "ours")
    sent = {}
    Circuits.placed(P, { O.SW3 })
    local r = last()
    HARNESS_TOGGLES = 0
    check(r.auto == "switch" and r.n == 0 and r.later == true and r.id == nil and act(P, O.SW3) == "orig"
        and HARNESS_TOGGLES == 1, "房間裡沒有燈的開關：不建線路、按了照原版，提示之後放的燈會自動接")
    O.L8 = light(111, 100, lampS, "ours")
    sent = {}
    Circuits.placed(P, { O.L8 })
    check(last().auto == "lamp" and nL(last()) == 1 and nS(last()) == 1, "房間裡只有一個開關：放燈時建線路接上")
    -- 招牌（引擎也建成 IsoLightSwitch：lightswitch 型別、沒有 lightR）不是開關：帶 streetlight 的招牌、能搬的菜單板放進有線路的
    -- 房間都不接線、不回覆
    for i, keys in ipairs({ { streetlight = "" }, { IsMoveAble = "" } }) do
        local sign = light(112, 102, sprite("cn_01_" .. i, 2304 + i, { type = T.lightswitch, keys = keys }), "ours")
        sent = {}
        Circuits.placed(P, { sign })
        local replies = #sent
        r = ask(P, O.SW3)
        check(replies == 0 and nS(r) == 1 and nL(r) == 1, "招牌（沒有 lightR、帶 " .. next(keys) .. "）不算開關：放進有線路的房間不接線（"
            .. replies .. " 則回覆）")
    end
    -- 客戶端收到伺服器新放的物件（OnObjectAdded，Client.lua 的 onAdded）照 load 補：自建房間的開關補 switchLight、房間裡其他
    -- 物件的 activated 同一幀還原；地圖房屋不補；不能改裝的燈照 sprite 補顏色
    do
        local sq = at(85, 100)
        local sw = light(85, 100, swS, "mark")
        local offLamp, offSw = light(85, 100, lampS, "mark"), light(85, 100, swS, "mark")
        offLamp.on, offSw.on = false, false
        sq.room, sq.userRoom = { getLightSwitches = function() return javaList({ offLamp, offSw }) end }, true
        HARNESS_CASCADE = { offLamp, offSw }
        fire("OnObjectAdded", sw)
        local userOk = sw.lit == true and not offLamp.on and not offSw.on
        sw.lit, sq.userRoom = nil, false
        fire("OnObjectAdded", sw)
        local mapOk = sw.lit == nil
        HARNESS_CASCADE = nil
        local lamp = light(85, 100, lampS, "mark")
        function lamp:setPrimaryR(v) self.r = v end
        function lamp:setPrimaryG(v) self.g = v end
        function lamp:setPrimaryB(v) self.b = v end
        fire("OnObjectAdded", lamp)
        sq.room, sq.objects = nil, {}
        check(userOk and mapOk and lamp.r == 200 / 255 and lamp.g == 180 / 255 and lamp.b == 150 / 255,
            "客戶端收到新放的物件：自建房間的開關補切房間燈、房裡其他燈與開關的狀態還原；地圖房屋不補；不能改裝的燈補 sprite 顏色")
    end

    -- 房間 10：兩個都沒有燈的開關配成一條沒有燈的線路（狀態對齊；按的時候照原版）
    local P10 = player({ id = 2310, x = 126.5, y = 101.5 })
    O.SWP1 = light(125, 101, swS, "ours")
    sent = {}
    Circuits.placed(P10, { O.SWP1 })
    O.SWP1.on = false
    O.SWP2 = light(127, 101, swS, "ours")
    sent = {}
    Circuits.placed(P10, { O.SWP2 })
    r = last()
    HARNESS_TOGGLES = 0
    check(r.auto == "switch" and r.jx == 125 and r.id ~= nil and nS(r) == 2 and nL(r) == 0 and r.later == true
        and O.SWP2.on == false and act(P10, O.SWP2) == "orig" and HARNESS_TOGGLES == 1,
        "同一間兩個開關都沒有燈：配成一條沒有燈的線路、狀態對齊，按了照原版")
    -- 房間 11：配不成（另一個開關在別人的安全屋）→ 兩組開關，later＝false；之後放的燈不自動接，告訴放的人原因
    local P11 = player({ id = 2311, x = 126.5, y = 107.5 })
    O.SWQ1 = light(125, 107, swS, "ours")
    Circuits.placed(P11, { O.SWQ1 })
    at(125, 107).owner = "someone"
    O.SWQ2 = light(127, 107, swS, "ours")
    sent = {}
    Circuits.placed(P11, { O.SWQ2 })
    r = last()
    at(125, 107).owner = nil
    check(r.auto == "switch" and r.id == nil and r.later == false and ask(P11, O.SWQ1).id == nil,
        "另一個開關沒有權限、配不成：不建線路，later=false（不承諾之後放的燈會自動接）")
    O.LQ = light(126, 108, lampS, "ours")
    sent = {}
    Circuits.placed(P11, { O.LQ })
    check(last().auto == "lamp" and last().miss == "MULTI" and ask(P11, O.LQ).id == nil,
        "房間裡有兩組開關時放燈：不接，回原因 MULTI 給放的人")
    -- 房間 12：能放燈、但不能改房間裡唯一的開關：不接、開關仍然沒有線路
    local P12 = player({ id = 2312, x = 121.5, y = 107.5 })
    O.SWR = light(121, 107, swS, "ours")
    Circuits.placed(P12, { O.SWR })
    at(121, 107).owner = "someone"
    O.LR = light(120, 106, lampS, "ours")
    sent = {}
    Circuits.placed(P12, { O.LR })
    r = last()
    at(121, 107).owner = nil
    check(r.auto == "lamp" and r.miss == "DENIED" and ask(P12, O.SWR).id == nil and ask(P12, O.LR).id == nil,
        "放燈時房間唯一的開關在別人的安全屋：不接、不建線路，回原因 DENIED")

    -- 房間 7：兩盞本 MOD 蓋的燈（一盞兩片，共用同一組）、一盞能搬的原版燈、一盞地圖燈、一盞只有 modData 記號的燈
    O.L1 = light(100, 100, lampS, "ours")
    O.L2a, O.L2b = light(101, 100, lampS, "ours"), light(102, 100, lampS2, "ours")
    local g = { O.L2a, O.L2b }
    O.L2a.group, O.L2b.group = g, g
    O.MV = light(100, 102, movS)
    O.MAP = light(102, 102, lampS)
    O.FAKE = light(101, 102, lampS2, "mark")
    O.OUT = light(105, 101, lampS, "ours") -- 室外，不同區域
    O.SW1 = light(100, 101, swS, "ours")
    sent = {}
    Circuits.placed(P, { O.SW1 })
    r = last()
    check(r.auto == "switch" and r.n == 4 and nL(r) == 4 and nS(r) == 1 and r.who == 2301,
        "放開關：同一個封閉房間裡本 MOD 的燈（兩片那盞整組）與能搬的燈自動接上，共 4 片；回覆帶操作的人（" .. tostring(r.n) .. "）")
    local id1 = r.id

    -- 按開關：走原版 ISToggleLightAction，伺服器切整條線路；地圖燈、只有記號的燈、室外那盞不動，不呼叫原版
    HARNESS_TOGGLES = 0
    check(act(P, O.SW1) == true and not O.SW1.on and not O.L1.on and not O.L2a.on and not O.L2b.on and not O.MV.on
        and O.L1.synced == 1 and O.L2b.synced == 1 and O.L1.lit == false and O.MAP.on and O.FAKE.on and O.OUT.on
        and HARNESS_TOGGLES == 0, "按開關：開關與線路上每片燈都關、各同步一次；不在線路上的不動，不呼叫原版")
    check(O.MAP.synced == 1 and O.MAP.sent == 1 and O.FAKE.synced == 1 and O.OUT.synced == 0,
        "同一間不在線路上的燈照伺服器狀態再同步一次（客戶端的自建房間會跟著開關切，builder-circuits-1029b），室外的不送")
    check(act(P, O.SW1) == false and not O.L1.on, "0.5 秒內再按：冷卻，不切")
    local t0 = nowMs
    nowMs = t0 - 10000
    check(act(P, O.SW1) == true and O.L1.on and O.SW1.on, "時鐘往回跳：不當成冷卻中，照樣切（pitfalls getTimestampMs）")
    nowMs = t0 + 600
    local FAR = player({ id = 2302, x = 104.5, y = 101.5 })
    check(act(FAR, O.SW1) == false and O.L1.on, "離開關超過 2 格：不切")
    MinidoracatSafehouse = { v1 = { API_MAJOR = 1, CAPABILITIES = { denies = true }, BITS = { BUILD = 4, USE = 1 },
        denies = function(_, _, _, _, bit) return bit == 1 end } }
    check(act(P, O.SW1) == false and O.L1.on, "Safehouse 不給 USE：不切")
    MinidoracatSafehouse = nil
    Circuits.PRESS_REACH = 100 -- 植入違規：不查距離
    local planted = act(FAR, O.SW1) == true
    Circuits.PRESS_REACH = 2
    nowMs = nowMs + 600
    check(planted, "植入違規（不查距離）時，遠處的人按得動：上面「超過 2 格」那條會抓到")
    check(act(P, O.MAP) == "orig" and act(P, O.FAKE) == "orig" and HARNESS_TOGGLES == 2,
        "地圖燈與只有 modData 記號的燈：照原版（不看 modData）")
    local OUT_ON = O.OUT.on
    check(act(FAR, O.OUT) == true and O.OUT.on ~= OUT_ON and O.OUT.synced == 1 and HARNESS_TOGGLES == 2,
        "本 MOD 蓋的燈不在線路上、不在房屋裡：伺服器切它自己（原版切不了）")

    -- 第二個開關在同一間：接成雙切，狀態對齊；按它也切整條
    O.SW2 = light(102, 101, swS, "ours")
    sent = {}
    Circuits.placed(P, { O.SW2 })
    r = last()
    check(r.auto == "switch" and r.jx == 100 and r.jy == 101 and nS(r) == 2 and nL(r) == 4 and r.id == id1
        and O.SW1.on == false and O.SW2.on == false and O.SW2.synced == 1,
        "同一間放第二個開關：併進原本的線路（雙切），狀態對齊線路上原有的開關（關）")
    nowMs = nowMs + 600
    check(act(P, O.SW2) == true and O.L1.on and O.SW1.on and O.SW2.on, "按第二個開關：整條線路一起切（雙切，第一次按就動）")
    O.L3 = light(101, 101, lampS, "ours")
    sent = {}
    Circuits.placed(P, { O.L3 })
    check(last().auto == "lamp" and nL(last()) == 5, "放燈：房間裡的開關都在同一條線路，自動接上")

    -- 房間外放的開關：NOT_ENCLOSED、不建線路；之後封好，按「接同一房間」併進房間的線路（雙切）
    O.SWN = light(103, 101, swS, "ours")
    sent = {}
    Circuits.placed(P, { O.SWN })
    check(last().code == "NOT_ENCLOSED" and ask(P, O.SWN).id == nil and act(P, O.SWN) == "orig",
        "室外放開關：NOT_ENCLOSED，沒有線路、按了照原版")
    rooms["103,101,0"] = 7
    r = wire(P, "room", O.SWN)
    check(r.code == nil and r.jx == 100 and nS(r) == 3 and r.id == id1, "封好後按「接同一房間」：併進房間裡的線路（雙切）")
    r = wire(P, "join", O.SW1, O.SWN)
    rooms["103,101,0"] = nil
    check(r.code == nil and nS(r) == 2, "接線模式再點已接的開關：從線路拿掉")

    -- 接線指令：手動加室外那盞、限流、範圍、權限、上限
    r = wire(P, "add", O.SW1, O.OUT)
    check(r.code == nil and nL(r) == 6 and r.op == "add", "接線模式加燈：室外那盞接上")
    sent = {}
    Circuits.command(P, "wire", { q = 99, op = "remove", x = 100, y = 101, z = 0, e = "cs_01_0", tx = 105, ty = 101, tz = 0,
        te = "cl_01_0" })
    check(last().code == "RATE_LIMITED", "0.25 秒內第二個接線指令：RATE_LIMITED")
    sent = {}
    Circuits.command(P, "circuit", { q = 100, x = 100, y = 100, z = 0, e = "cl_01_0" })
    Circuits.command(P, "circuit", { q = 101, x = 101, y = 100, z = 0, e = "cl_01_0" })
    check(#sent == 2 and sent[1].args.code == nil and sent[2].args.code == nil,
        "同一刻查兩盞燈（右鍵一格有兩盞）：只查不改的額度另算，兩個都回")
    nowMs = nowMs + 1100
    sent = {}
    for i = 1, 9 do Circuits.command(P, "circuit", { q = 200 + i, x = 100, y = 100, z = 0, e = "cl_01_0" }) end
    check(#sent == 9 and sent[8].args.code == nil and sent[9].args.code == "RATE_LIMITED",
        "只查不改：同一秒第 9 個 RATE_LIMITED（每秒最多 8 個）")
    check(wire(P, "add", O.SW1, O.MAP).code == "NOT_WIRABLE" and wire(P, "add", O.SW1, O.FAKE).code == "NOT_WIRABLE",
        "地圖燈、只有 modData 記號的燈：NOT_WIRABLE")
    local realGet = Ledger.get
    Ledger.get = function(o) return o.md.builderEntry and {} or nil end -- 植入違規：照 modData 認
    planted = wire(P, "add", O.SW1, O.FAKE).code == nil
    wire(P, "remove", O.SW1, O.FAKE)
    Ledger.get = realGet
    check(planted and nL(ask(P, O.SW1)) == 6, "植入違規（照 modData 認燈）時，只有記號的燈接得上：上面那條會抓到")
    O.SWF = light(104, 104, swS, "ours")
    O.SH = light(103, 108, lampS, "ours")
    local c1 = wire(P, "add", O.SWF, O.MAP).code
    at(103, 108).owner = "someone"
    local c2 = wire(P, "add", O.SWF, O.SH).code
    at(103, 108).owner = nil
    HARNESS_TOGGLES = 0
    check(c1 == "NOT_WIRABLE" and c2 == "SAFEHOUSE" and ask(P, O.SWF).id == nil and act(P, O.SWF) == "orig"
        and HARNESS_TOGGLES == 1, "被拒的接線（不能接、沒權限）不留下空線路：開關沒有線路，按了照原版")
    local PN = player({ id = 2305, x = 86.5, y = 101.5 })
    O.LT = light(116, 101, lampS, "ours")
    r = wire(PN, "add", O.SW1, O.LT)
    check(r.code == "TOO_FAR" and r.side == "t", "開關在範圍內、目標的燈離人太遠：TOO_FAR（side=t）")
    O.SWJ = light(121, 104, swS, "ours")
    local PJ = player({ id = 2308, x = 112.5, y = 104.5 })
    check(wire(PJ, "join", O.SWF, O.SWJ).code == "OUT_OF_RANGE" and ask(PJ, O.SWF).id == nil,
        "兩個開關相隔 17 格、都沒有燈：OUT_OF_RANGE，不建線路")
    O.FAR2 = light(117, 101, lampS, "ours")
    check(wire(P, "add", O.SW1, O.FAR2).code == "OUT_OF_RANGE", "離開關超過 16 格的燈：OUT_OF_RANGE")
    at(103, 108).owner = "someone"
    check(wire(P, "add", O.SW1, O.SH).code == "SAFEHOUSE" and nL(ask(P, O.SW1)) == 6, "燈在別人的安全屋：SAFEHOUSE，沒接上")
    at(103, 108).owner = nil
    local FARP = player({ id = 2303, x = 120.5, y = 101.5 })
    check(wire(FARP, "add", O.SW1, O.L1).code == "TOO_FAR", "接線的人離開關超過 16 格：TOO_FAR")
    O.OWNED_SW = light(104, 108, swS, "ours")
    at(104, 108).owner = "someone"
    check(wire(P, "clear", O.OWNED_SW).code == "SAFEHOUSE", "開關在別人的安全屋：SAFEHOUSE")
    at(104, 108).owner = nil
    sb.Enabled = false
    check(wire(P, "add", O.SW1, O.L1).code == "OFF", "管理員關掉建造工坊：OFF")
    sb.Enabled = nil
    Circuits.MAX_L = 6
    O.L4 = light(103, 103, lampS, "ours")
    check(wire(P, "add", O.SW1, O.L4).code == "FULL", "線路滿了：FULL")
    Circuits.MAX_L = 16

    -- 多格燈：整組一起拔、一起加；其中一片沒有權限就整組不動
    r = cmd(P, "wire", { op = "unplug", x = 102, y = 100, z = 0, e = "cl_01_1" })
    check(r.code == nil and nS(ask(P, O.L2a)) == 0 and nL(ask(P, O.SW1)) == 4, "拔兩片燈的其中一片：整組拔掉")
    at(102, 100).owner = "someone"
    r = wire(P, "add", O.SW1, O.L2a)
    check(r.code == "SAFEHOUSE" and nS(ask(P, O.L2a)) == 0 and nS(ask(P, O.L2b)) == 0, "其中一片在別人的安全屋：整組加不進去")
    at(102, 100).owner = nil
    r = wire(P, "add", O.SW1, O.L2a)
    check(r.code == nil and nL(r) == 6 and wired(r, O.L2b), "點兩片燈的其中一片：整組加入")
    at(102, 100).owner = "someone"
    check(cmd(P, "wire", { op = "unplug", x = 101, y = 100, z = 0, e = "cl_01_0" }).code == "SAFEHOUSE"
        and wire(P, "remove", O.SW1, O.L2a).code == "SAFEHOUSE" and nS(ask(P, O.L2b)) == 2,
        "其中一片在別人的安全屋：拔線、移除都整組不動")
    at(102, 100).owner = nil
    at(100, 102).owner = "someone"
    r = wire(P, "clear", O.SW1)
    check(r.code == "SAFEHOUSE" and r.side == "l" and nL(ask(P, O.SW1)) == 6,
        "全部拔掉時有一盞在別人的安全屋：整筆不做（side=l，接線模式不關）")
    at(100, 102).owner = nil

    -- 房間 8 那條：搶燈、併線（對方成員要權限）、拔線
    r = wire(P, "add", O.SW1, O.L8)
    local P3 = player({ id = 2306, x = 110.5, y = 101.5 })
    HARNESS_TOGGLES = 0
    check(r.code == nil and r.moved == true and nL(r) == 7 and nL(ask(P, O.SW3)) == 0 and act(P3, O.SW3) == "orig",
        "別條線路的燈：點了移過來（moved）；原線路沒有燈了，那個開關按了照原版")
    at(110, 101).owner = "someone"
    r = wire(P, "join", O.SW1, O.SW3)
    check(r.code == "SAFEHOUSE" and nS(ask(P, O.SW1)) == 2, "併線時對方的開關在別人的安全屋：整筆不做")
    at(110, 101).owner = nil
    O.SW3.on = not O.SW1.on
    r = wire(P, "join", O.SW1, O.SW3, { cand = true })
    check(r.code == nil and nS(r) == 3 and r.cand and #r.cand > 0 and O.SW3.on == O.SW1.on,
        "點另一個開關：併成一條（3 個開關），狀態對齊；附近可接的一起回")
    local sawFree, sawSw = false, false
    for _, c in ipairs(r.cand) do
        if c.e == "cl_01_0" and c.x == 103 and c.y == 103 then sawFree = c.c == nil and c.k == "l" end
        if c.e == "cs_01_0" and c.x == 110 then sawSw = c.k == "s" and c.c == r.id end
    end
    check(sawFree and sawSw, "可接清單：沒接的燈 c=nil、線路上的開關 k=s 而且是這條")
    r = wire(P, "join", O.SW1, O.SW3)
    check(r.code == nil and nS(r) == 2, "再點同一個開關：從線路拿掉")
    r = cmd(P, "wire", { op = "unplug", x = 111, y = 100, z = 0, e = "cl_01_0" })
    check(r.code == nil and nL(r) == 6 and nL(ask(P, O.SW1)) == 6, "右鍵燈拔線：從線路拿掉")
    check(cmd(P, "wire", { op = "unplug", x = 111, y = 100, z = 0, e = "cl_01_0" }).code == "NOT_WIRED", "沒接線的燈拔線：NOT_WIRED")
    r = ask(P, O.L1)
    check(r.code == nil and nS(r) == 2 and r.cand == nil, "查燈：回控制它的開關（2 個），不回可接清單")

    -- 可接清單：線路成員一定在；其餘由近到遠，收滿就停
    Circuits.MAX_CAND = 1
    r = ask(P, O.SW1, true)
    local members = 0
    for _, c in ipairs(r.cand or {}) do if c.c == id1 then members = members + 1 end end
    check(members == 7, "可接清單上限比成員少：線路上的 1 個開關、6 片燈照樣都在（" .. members .. "）")
    r = ask(P, O.SWF, true)
    check(#(r.cand or {}) == 1 and r.cand[1].x == 103 and r.cand[1].y == 103, "沒有線路的開關：清單收最近的那一盞就停")
    Circuits.MAX_CAND = 64

    -- 相鄰兩間（13、14）各有一個線路上的開關、一盞沒接的燈：兩間都補同步（別間的邊界格不能擋住下一間）
    local PA = player({ id = 2313, x = 101.5, y = 104.5 })
    O.SA, O.SBB = light(101, 105, swS, "ours"), light(102, 105, swS, "ours")
    O.L13, O.LA, O.LB14 = light(100, 105, lampS, "ours"), light(100, 106, lampS), light(103, 106, lampS)
    check(wire(PA, "add", O.SA, O.L13).code == nil and wire(PA, "join", O.SA, O.SBB).code == nil, "相鄰兩間：接成一條")
    nowMs = nowMs + 600
    check(act(PA, O.SA) == true and O.LA.synced == 1 and O.LB14.synced == 1, "相鄰兩間：兩間沒接的燈都照伺服器狀態再同步")
    -- 開關那格在地圖房屋裡：照原版整間連動，不還原；屋頂不到一半的區域：客戶端不建房間，不走
    at(101, 105).room = {}
    roofLow[14] = true
    nowMs = nowMs + 600
    check(act(PA, O.SA) == true and O.LA.synced == 1 and O.LB14.synced == 1, "地圖房屋裡的開關、屋頂不到一半的區域：不補同步")
    at(101, 105).userRoom = true
    roofLow[14] = nil
    nowMs = nowMs + 600
    check(act(PA, O.SA) == true and O.LA.synced == 2 and O.LB14.synced == 2, "客戶端替自建房屋建的房間：照樣補同步")
    at(101, 105).room, at(101, 105).userRoom = nil, nil
    Circuits.SYNC_MAX = 1
    nowMs = nowMs + 600
    check(act(PA, O.SA) == true and O.LA.synced == 2, "走到 SYNC_MAX 就停（記 log）")
    Circuits.SYNC_MAX = 4096

    -- 帳本清理：移除事件、找不到的物件在按的時候剔除、重開服（換成讀回來的表）、開關都沒了整條刪掉
    at(105, 101):transmitRemoveItemFromSquare(O.OUT)
    check(nL(ask(P, O.SW1)) == 5, "燈移出世界：從線路移除")
    for k, o in ipairs(at(100, 102).objects) do if o == O.MV then table.remove(at(100, 102).objects, k) end end
    nowMs = nowMs + 600
    act(P, O.SW1)
    check(nL(ask(P, O.SW1)) == 4, "格子載入了卻找不到的燈：按開關時剔除")
    local d = Ledger.instance.circuits
    local copy = { next = d.next, c = {} }
    for cid, c in pairs(d.c) do
        copy.c[cid] = { s = {}, l = {} }
        for k in pairs(c.s) do copy.c[cid].s[k] = true end
        for k in pairs(c.l) do copy.c[cid].l[k] = true end
    end
    Ledger.instance.circuits = copy
    nowMs = nowMs + 600
    local before = O.L1.on
    check(act(P, O.SW1) == true and O.L1.on ~= before, "帳本換成讀回來的那份：反查表重建，按開關照樣切")

    -- 大的封閉區域（超過 ROOM_MAX）：客戶端整間連動，補同步要涵蓋 16 格外的燈；單機（世界只有一份）還原別的物件
    O.SWB, O.LB, O.LF = light(81, 105, swS, "ours"), light(82, 105, lampS, "ours"), light(99, 110, lampS, "ours")
    O.SWX = light(85, 105, swS, "ours")
    local PB = player({ id = 2307, x = 81.5, y = 106.5 })
    check(wire(PB, "add", O.SWB, O.LB).code == nil, "大區域：手動接線")
    at(82, 105).owner = "someone"
    r = wire(PB, "join", O.SWB, O.SWB)
    at(82, 105).owner = nil
    local r2 = ask(PB, O.SWB)
    check(r.code == "BAD_REQUEST" and nS(r2) == 1 and nL(r2) == 1 and wired(r2, O.LB),
        "線路最後一個開關自己接自己：BAD_REQUEST，帳本不變（安全屋裡的燈仍在線路上）")
    HARNESS_CASCADE = { O.SWB, O.LB, O.LF, O.SWX }
    nowMs = nowMs + 600
    check(act(PB, O.SWB) == true and not O.LB.on and O.LF.on and O.SWX.on and O.LF.synced == 1 and O.SWX.synced == 0,
        "開關切整間房時：線路外的燈（18 格外、區域超過上限）照原狀還原並同步，別的開關還原狀態")
    HARNESS_CASCADE = nil
    O.SWB.bulb = false
    nowMs = nowMs + 600
    local on1 = act(PB, O.SWB) == true and O.LB.on
    nowMs = nowMs + 600
    check(on1 and act(PB, O.SWB) == true and not O.LB.on, "開關沒有燈泡：照樣能開也能關")
    O.LB.boom = true
    HARNESS_TOGGLES = 0
    nowMs = nowMs + 600
    check(act(PB, O.SWB) == false and HARNESS_TOGGLES == 0, "切到一半出錯：不再照原版切一次")
    O.LB.boom = nil

    -- 單機的接線模式（Wiring.lua）：回覆在送出時就到，busy 不能卡住；一格兩個候選時點一次換下一個
    require "MinidoracatBuilder/Wiring"
    local Wiring = MinidoracatBuilder.Wiring
    local realIsServer = isServer
    isServer = function() return false end
    HaloTextHelper = HaloTextHelper or { addBadText = function() end }
    O.LP1, O.LP2 = light(83, 106, lampS, "ours"), light(83, 106, lampS2, "ours")
    local m = { player = PB, pn = 0, sw = { x = 81, y = 105, z = 0, e = "cs_01_0" }, marked = {}, cand = {}, pick = {} }
    Wiring.mode = m
    nowMs = nowMs + 300
    local q1 = Wiring.refresh(m)
    nowMs = nowMs + 300
    local c1, i1, n1 = Wiring.at(83, 106, 0)
    local q2 = Wiring.click(83, 106, 0)
    local c2, i2 = Wiring.at(83, 106, 0)
    check(q1 and q2 and not m.busy and m.nL == 2 and n1 == 2 and i1 == 1 and i2 == 2 and c1.e ~= c2.e,
        "單機：打開之後馬上點得動（busy 不卡）；一格兩盞時點完換下一盞")
    nowMs = nowMs + 300
    Wiring.click(83, 106, 0)
    check(m.nL == 3, "再點同一格：加入第二盞")
    nowMs = nowMs + 300
    Wiring.click(83, 106, 0)
    nowMs = nowMs + 300
    Wiring.click(83, 106, 0)
    check(m.nL == 1, "兩盞都已接：同一格連點兩次，兩盞都拔掉（清單重排後不會指回剛拔的那盞）")
    nowMs = nowMs + 300
    Wiring.click(83, 106, 0)
    nowMs = nowMs + 300
    Wiring.click(83, 106, 0)
    m.busy, m.busyAt = true, nowMs + 100000 -- 時鐘往回跳
    nowMs = nowMs + 300
    check(Wiring.op("clear") ~= nil and m.nL == 0, "時鐘往回跳時不當成還在等回覆")
    -- 游標給的那一個（照圖指到的格子可能不是滑鼠下那格，WireCursor:tryBuild 傳 hover）：點的是它，不是那一格現在輪到的那盞
    local cur = Wiring.at(83, 106, 0)
    local other
    for _, c in ipairs(m.cand) do if c.x == 83 and c.y == 106 and c.e ~= cur.e then other = c end end
    nowMs = nowMs + 300
    Wiring.click(83, 106, 0, other)
    local wiredE
    for _, c in ipairs(m.cand) do if c.x == 83 and c.y == 106 and c.status == "wired" then wiredE = c.e end end
    check(other ~= nil and m.nL == 1 and wiredE == other.e, "照圖選到的燈：點的是它，不是那一格輪到的那盞")
    nowMs = nowMs + 300
    Wiring.op("clear")
    -- 滑鼠照圖指到同一格重疊的兩盞（Wiring.atMouse）：選那一格現在輪到的那盞，點完換下一盞，不會一直點同一盞（審查 1109
    -- Codex）。畫面換算的 API 換成固定值：兩盞的圖都蓋住滑鼠那一點，其他候選都不中
    local sMX, sMY, sIX, sIY, sCore, sCoreT = getMouseX, getMouseY, isoToScreenX, isoToScreenY, getCore, Core
    getMouseX, getMouseY = function() return 400 end, function() return 300 end
    isoToScreenX, isoToScreenY = function() return 390 end, function() return 290 end
    getCore = function() return { getZoom = function() return 1 end } end
    Core = { getTileScale = function() return 1 end }
    for _, c in ipairs(m.cand) do
        for _, o in ipairs(at(c.x, c.y).objects) do
            if o.getSprite and o:getSprite() and o:getSprite():getName() == c.e then
                o.getOffsetX, o.getOffsetY = function() return 32 end, function() return 96 end
                o.getRenderYOffset, o.getTargetAlpha = function() return 0 end, function() return 1 end
                o.isMaskClicked = function(s) return s == O.LP1 or s == O.LP2 end
            end
        end
    end
    nowMs = nowMs + 300
    local h1, hi1, hn1 = Wiring.atMouse(0)
    local hq = h1 and Wiring.click(h1.x, h1.y, h1.z, h1)
    local h2, hi2 = Wiring.atMouse(0)
    -- 只有一盞的圖蓋住滑鼠那一點：選它，不管那一格現在輪到哪一盞（輪到的是 h2）（審查 1109 Grok）
    for _, o in ipairs(at(83, 106).objects) do
        if o == O.LP1 or o == O.LP2 then
            local hitMe = o:getSprite():getName() == h1.e
            o.isMaskClicked = function() return hitMe end
        end
    end
    local h3, hi3, hn3 = Wiring.atMouse(0)
    -- 同一格三盞、只有第一、三盞的圖蓋住滑鼠那一點：輪到第二盞時選第三盞（從輪到的往後找命中的），輪到第三盞選它，
    -- 輪到第一盞（點完第三盞 advance 繞回）選第一盞（審查 1109 Codex 第 2 輪：以前一律回第一個命中的，點不到第三盞）
    local tri = {}
    do
        local savedMode, tsq, list = Wiring.mode, square(410, 410, 0), {}
        for i = 1, 3 do
            local spr = sprite("tri_01_" .. i, 2190 + i, {})
            local o = { class = "IsoLightSwitch" }
            function o:getSprite() return spr end
            function o:getOffsetX() return 32 end
            function o:getOffsetY() return 96 end
            function o:getRenderYOffset() return 0 end
            function o:getTargetAlpha() return 1 end
            function o:isMaskClicked() return i ~= 2 end
            tsq.objects[i] = o
            list[i] = { x = 410, y = 410, z = 0, e = "tri_01_" .. i, k = "l", status = "free" }
        end
        Wiring.mode = { cand = list, byPos = { ["410,410,0"] = list }, pick = {} }
        local tn = {}
        for i = 1, 3 do
            Wiring.mode.pick["410,410,0"] = "410,410,0,tri_01_" .. i
            local c, _, n = Wiring.atMouse(0)
            tri[i], tn[i] = c and c.e, n
        end
        tri.n = tn[1] == 2 and tn[2] == 2 and tn[3] == 2
        tri.below = Wiring.atMouse(0, 1) == nil -- 游標在樓上：下一層的燈被這層地板蓋住，不算
        Wiring.mode = savedMode
    end
    getMouseX, getMouseY, isoToScreenX, isoToScreenY, getCore, Core = sMX, sMY, sIX, sIY, sCore, sCoreT
    check(hq ~= nil and h2 ~= nil and hn1 == 2 and h1.x == 83 and h1.y == 106 and h1.e ~= h2.e and hi1 ~= hi2,
        "滑鼠照圖指到同一格重疊的兩盞：點完換下一盞（照輪替，不會一直點同一盞）")
    check(h3 ~= nil and h3.e == h1.e and hi3 == 1 and hn3 == 1,
        "滑鼠只指著同一格其中一盞的圖：選那一盞，不管那一格輪到哪一盞；只疊一個不提示「再點一次換下一個」")
    check(tri[1] == "tri_01_1" and tri[2] == "tri_01_3" and tri[3] == "tri_01_3" and tri.n and tri.below,
        "同一格三盞只有兩盞的圖蓋住滑鼠：輪到沒蓋住的那盞時選下一個蓋住的，共幾個照蓋住的算；游標在樓上時下一層的不算")
    nowMs = nowMs + 300
    Wiring.op("clear")
    -- 同一格排前面的那盞被拒（被別人拿走：GONE、side＝t）：接線模式留著，下一次點換到另一盞，不卡在被拒的那盞
    local cA = Wiring.at(83, 106, 0)
    local lpSq, gone = at(83, 106), nil
    for k, o in ipairs(lpSq.objects) do
        if (o == O.LP1 or o == O.LP2) and o:getSprite():getName() == cA.e then
            gone = table.remove(lpSq.objects, k)
            break
        end
    end
    nowMs = nowMs + 300
    Wiring.click(83, 106, 0)
    local cB = Wiring.at(83, 106, 0)
    check(gone ~= nil and Wiring.mode == m and cB ~= nil and cB.e ~= cA.e,
        "同一格的燈被拒（GONE）：接線模式留著，下一次點換到另一盞")
    lpSq.objects[#lpSq.objects + 1] = gone
    -- 自動接線的通知選對句子（getText 替身只回鍵名）
    local realToast, toldW = MinidoracatBuilder.Messages.toast, nil
    MinidoracatBuilder.Messages.toast = function(_, text) toldW = text end
    local function notice(args)
        toldW = nil
        Wiring.onServerCommand("circuit", args, PB)
        return toldW
    end
    check(notice({ auto = "lamp", miss = "FULL" }) == "IGUI_MBLD_Wire_LampMiss"
        and notice({ auto = "lamp", id = 1 }) == "IGUI_MBLD_Wire_LampJoined"
        and notice({ auto = "switch", n = 0, l = { { x = 1, y = 1, z = 0, e = "a" } } }) == "IGUI_MBLD_Wire_AutoNoNew"
        and notice({ auto = "switch", n = 0, l = {}, later = true }) == "IGUI_MBLD_Wire_AutoNone"
        and notice({ auto = "switch", n = 0, l = {} }) == "IGUI_MBLD_Wire_AutoNoneManual",
        "自動接線的通知：沒接上寫原因、線路已有燈寫現況、只有一組開關時才說之後會試著自動接")
    MinidoracatBuilder.Messages.toast = realToast
    check(Wiring.hoverText({ k = "s", status = "wired", e = "cs_01_0" }, 1, 1) == "IGUI_MBLD_Wire_PadRemove"
        and Wiring.hoverText({ k = "s", status = "free", e = "cs_01_0" }, 1, 1) == "IGUI_MBLD_Wire_PadJoin",
        "游標說明：已在線路上的開關寫「移除」，別的開關寫「接成雙切」")
    -- 開關不見了（GONE，開關本身的錯）：點一格好幾個的格子時接線模式關掉，不丟錯
    local swSq = at(81, 105)
    for k, o in ipairs(swSq.objects) do if o == O.SWB then table.remove(swSq.objects, k) end end
    nowMs = nowMs + 300
    local okClick, errClick = pcall(Wiring.click, 83, 106, 0)
    check(okClick and Wiring.mode == nil, "點的時候開關不見了：接線模式關掉、不丟錯（" .. tostring(errClick) .. "）")
    swSq.objects[#swSq.objects + 1] = O.SWB

    -- 右鍵選單（照原版選項池：關掉時選項收回、重開時從後面取）：晚到的回覆不改到被重用的選項
    local function fakeMenu()
        local mn = { options = {}, numOptions = 1, optionPool = {} }
        function mn:addOption(name, target, fn, p1, p2)
            local o = table.remove(self.optionPool) or {}
            for k in pairs(o) do o[k] = nil end
            o.id, o.name, o.target, o.onSelect, o.param1, o.param2 = self.numOptions, name, target, fn, p1, p2
            self.options[self.numOptions] = o
            self.numOptions = self.numOptions + 1
            return o
        end
        function mn:addSubMenu(o, s) o.subOption = s end
        function mn:clear()
            for _, o in ipairs(self.options) do self.optionPool[#self.optionPool + 1] = o end
            for k in pairs(self.options) do self.options[k] = nil end
            self.numOptions = 1
        end
        function mn:calcWidth() return 100 end
        function mn:setWidth(w) self.width = w end
        return mn
    end
    local realCM, realWOCM, realSpecific = ISContextMenu, ISWorldObjectContextMenu, getSpecificPlayer
    local realClient, realSCC = isClient, sendClientCommand
    ISContextMenu = { getNew = function() return fakeMenu() end }
    ISWorldObjectContextMenu = { onToggleLight = function() end, setTest = function() end }
    getSpecificPlayer = function() return PB end
    local sentQ
    isClient = function() return true end
    sendClientCommand = function(_, _, _, a) sentQ = a.q end
    local lampObjs = { { getSquare = function() return at(82, 105) end } }
    local ctx = fakeMenu()
    Wiring.fill(0, ctx, lampObjs, false)
    local sub = ctx.options[1] and ctx.options[1].subOption
    local reply = { q = sentQ, who = 2307, s = { { x = 81, y = 105, z = 0, e = "cs_01_0" } }, l = {} }
    sub:clear()
    local reused = sub:addOption("X")
    Wiring.onServerCommand("circuit", reply)
    check(sub and #sub.options == 1 and reused.name == "X" and reused.notAvailable == nil and sub.width == nil,
        "選單關掉、子選單被重用成較少選項後才到的回覆：新選單完全不變")
    ctx = fakeMenu()
    Wiring.fill(0, ctx, lampObjs, false)
    sub = ctx.options[1].subOption
    reply.q = sentQ
    Wiring.onServerCommand("circuit", reply)
    check(sub.options[1].name == "IGUI_MBLD_Menu_ControlledBy" and sub.options[2].notAvailable == false,
        "選單還開著時到的回覆：照常填上")
    sb.Enabled = false
    ctx = fakeMenu()
    Wiring.fill(0, ctx, lampObjs, false)
    sb.Enabled = nil
    check(#ctx.options == 1 and ctx.options[1].name:find("^ContextMenu_Turn_") ~= nil,
        "管理員關掉建造工坊：不列線路，開燈／關燈照列")
    ISContextMenu, ISWorldObjectContextMenu, getSpecificPlayer = realCM, realWOCM, realSpecific
    isClient, sendClientCommand = realClient, realSCC
    Wiring.mode = nil
    isServer = realIsServer

    at(100, 101):transmitRemoveItemFromSquare(O.SW1)
    at(102, 101):transmitRemoveItemFromSquare(O.SW2)
    local left = 0
    for _ in pairs(Ledger.instance.circuits.c) do left = left + 1 end
    check(left == 3 and Ledger.get(O.SW1) == nil and ask(P3, O.SW3).id == nil,
        "兩個開關都拿走：整條線路刪掉（只剩大區域、房間 10、相鄰兩間那三條），帳本也清掉（" .. left .. "）")
    instanceof, IsoRegions.getIsoWorldRegion = realInst, realRegions
end
circuitScenario()

print("情境二十三：本工具蓋的帶燈非燈物件（Lights.sync）只切自己照 sprite 建的光源")
local function lightsScenario()
    local realCell, realInst, realIGS = getCell, instanceof, IsoGridSquare
    local recalc = 0
    IsoGridSquare = { setRecalcLightTime = function() recalc = recalc + 1 end }
    instanceof = function(o, cls) return o.class == cls end
    local function light(r, g, b, rad, hydro)
        return { r = r, g = g, b = b, rad = rad, hydro = hydro, on = true,
            getX = function() return 1 end, getY = function() return 1 end, getZ = function() return 0 end,
            getR = function(s) return s.r end, getG = function(s) return s.g end, getB = function(s) return s.b end,
            getRadius = function(s) return s.rad end, isHydroPowered = function(s) return s.hydro end,
            getSwitches = function(s) return javaList({ s.sw }) end,
            isActive = function(s) return s.on end, setActive = function(s, v) s.on = v end }
    end
    local function obj(class, keys, ours, own)
        local p = { get = function(_, k) return keys[k] end, has = function(_, k) return keys[k] ~= nil end }
        return { class = class, powered = false, md = { builderEntry = ours and "x" or nil },
            getLightSource = function() return own end, hasModData = function() return true end,
            getModData = function(s) return s.md end, getProperties = function() return p end,
            checkObjectPowered = function(s) return s.powered end }
    end
    local red = { lightR = "255", lightG = "0", lightB = "0", LightRadius = "4" }
    local mine, sw, vanilla, fuel = light(1, 0, 0, 4), light(1, 0, 0, 4, true), light(1, 0, 0, 4), light(1, 0, 0, 4)
    local other = light(0, 1, 0, 4)
    local T = obj("IsoThumpable", red, true, fuel)
    local objs = { obj("IsoObject", red, false, vanilla), T, obj("IsoThumpable", red, false) }
    local lamps = { sw, vanilla, fuel, other, mine }
    getCell = function() return {
        getLamppostPositions = function() return javaList(lamps) end,
        getGridSquare = function() return { getObjects = function() return javaList(objs) end } end } end
    require "MinidoracatBuilder/Lights"
    local Lights = MinidoracatBuilder.Lights
    check(Lights.sync() == 1 and not mine.on and sw.on and vanilla.on and fuel.on and other.on and recalc == 1,
        "沒電：只關本工具物件照 sprite 建的那盞；開關的燈、別的物件的燈、燃料燈、顏色不同的都不動")
    T.powered = true
    check(Lights.sync() == 1 and mine.on and recalc == 2, "有電：打開")
    check(Lights.sync() == 0 and recalc == 2, "狀態沒變：不設、不重算光照")
    getCell, instanceof, IsoGridSquare = realCell, realInst, realIGS
end
lightsScenario()

print("情境二十四：本工具蓋的路燈（streetlight）沒市電時，客戶端補一盞光源、掛亮燈圖")
local function streetScenario()
    local realCell, realInst, realIGS, realGT = getCell, instanceof, IsoGridSquare, getGameTime
    IsoGridSquare = { setRecalcLightTime = function() end }
    instanceof = function(o, cls) return o.class == cls end
    local night = 1
    getGameTime = function() return { getNight = function() return night end } end
    local lamps = {}
    local function light(r, g, b, rad, hydro, sw)
        return { r = r, g = g, b = b, rad = rad, hydro = hydro, sw = sw, on = true,
            getX = function() return 5 end, getY = function() return 6 end, getZ = function() return 0 end,
            getR = function(s) return s.r end, getG = function(s) return s.g end, getB = function(s) return s.b end,
            getRadius = function(s) return s.rad end, isHydroPowered = function(s) return s.hydro end,
            getSwitches = function(s) return javaList({ s.sw }) end,
            isActive = function(s) return s.on end, setActive = function(s, v) s.on = v end }
    end
    local ON = sprite("lamp_01_on_3", 91)
    local BASE = sprite("lamp_01_3", 90, { flags = { "HasLightOnSprite" }, keys = { streetlight = "", lightR = "255" } })
    world({ BASE, ON })
    local function lampSw(ours)
        local o = { class = "IsoLightSwitch", act = true, grid = false, can = true, att = {},
            md = { builderEntry = ours and "lamp_01_3" or nil } }
        function o:hasModData() return true end
        function o:getModData() return self.md end
        function o:getProperties() return BASE:getProperties() end
        function o:getSprite() return BASE end
        function o:isActivated() return self.act end
        function o:hasGridPower() return self.grid end
        function o:canSwitchLight() return self.can end
        function o:isAttachedAnimSprite(s)
            for _, a in ipairs(self.att) do if a.spr == s then return true end end
            return false
        end
        function o:addAttachedAnimSprite(s)
            self.att[#self.att + 1] = { spr = s, getParentSprite = function(a) return a.spr end }
        end
        function o:getAttachedAnimSprite() return javaList(self.att) end
        function o:RemoveAttachedAnim(i) table.remove(self.att, i + 1) end
        return o
    end
    getCell = function() return {
        getLamppostPositions = function() return javaList(lamps) end,
        addLamppost = function(_, x, y, z, r, g, b, rad)
            local l = light(r, g, b, rad, false)
            l.at = x .. "," .. y .. "," .. z
            lamps[#lamps + 1] = l
            return l
        end,
        removeLamppost = function(_, l)
            for i, v in ipairs(lamps) do if v == l then table.remove(lamps, i) return end end
        end,
        getGridSquare = function() return { getObjects = function() return javaList({}) end } end } end
    local S, V = lampSw(true), lampSw(false)
    local own = light(1, 0.3, 0.1, 16, true, S)
    lamps = { own, light(1, 0.3, 0.1, 16, true, V) }
    local Lights = MinidoracatBuilder.Lights
    local function extra()
        for _, l in ipairs(lamps) do if not l.hydro then return l end end
    end
    local function lit() return extra() ~= nil and #S.att == 1 and S.att[1].spr == ON end
    local function dark() return extra() == nil and #S.att == 0 end
    check(Lights.sync() == 1 and #lamps == 3 and lit() and #V.att == 0, "夜裡、沒市電、開著、有發電機電：補一盞、掛亮燈圖；地圖的路燈不動")
    local x = extra()
    check(x.r == 1 and x.g == 0.3 and x.b == 0.1 and x.rad == 16 and x.at == "5,6,0", "補的光源和燈自己的同色、同半徑、同一格")
    check(Lights.sync() == 0 and extra() == x and #S.att == 1, "狀態沒變：不重建、不重掛")
    S.act = false
    fire("OnTick")
    check(dark(), "按掉：下一個 tick 就收，不等遊戲分鐘")
    S.act = true
    fire("OnTick")
    check(lit(), "按開：下一個 tick 就補")
    night = 0.3
    check(Lights.sync() == 1 and dark(), "白天：收（照原版只在夜裡亮）")
    night = 1
    S.grid = true
    check(Lights.sync() == 0 and dark(), "有市電：交給引擎，不補")
    S.grid, S.can = false, false
    check(Lights.sync() == 0 and dark(), "沒有電（canSwitchLight false）：不補")
    S.can = true
    Lights.sync()
    own.r = 0.5
    check(Lights.sync() == 1 and extra() ~= x and extra().r == 0.5 and #lamps == 3, "燈換了顏色：補的那盞照新顏色重建")
    instanceof = function() return false end -- 帳本、線路、放置的移除處理不是這裡要驗的
    fire("OnObjectAboutToBeRemoved", S)
    instanceof = function(o, cls) return o.class == cls end
    check(extra() == nil, "燈被移除：當下收掉補的光源")
    Lights.sync()
    table.remove(lamps, 1)
    check(Lights.sync() == 1 and extra() == nil, "燈的光源不在清單上（卸載）：收掉補的光源")
    getCell, instanceof, IsoGridSquare, getGameTime = realCell, realInst, realIGS, realGT
end
streetScenario()

print("情境二十五：2026-10-31 玩家回饋（柱子、配方的地板、不列的原因、種類開關、同組照編號排、管理面板合併）")
do
    local realIsServer, realPanel = isServer, ISPanel
    isServer = function() return false end
    ISPanel = ISPanel or { derive = function(self) return setmetatable({}, { __index = self }) end } -- 只驗合併，不建面板
    require "MinidoracatBuilder/Admin"
    isServer, ISPanel = realIsServer, realPanel
    local W, Admin = MinidoracatBuilder.Window, MinidoracatBuilder.Admin
    local realGetText, realGetTextOrNull = getText, getTextOrNull
    local function keyed(k, ...)
        local a = { ... }
        if #a == 0 then return k end
        return k .. "(" .. table.concat(a, ",") .. ")"
    end
    getText, getTextOrNull = keyed, keyed
    local function code(o, name) return select(2, Rules.classify(sprite(name or "test_01_0", 5, o))) end
    -- 柱子：WallSE、沒有牆鍵只有撞車或單邊碰撞、配方的轉角柱；已經列出的不換種類
    check(kind({ flags = { "WallSE" } }) == "post" and kind({ flags = { "WallSE" }, keys = { WallN = "" } }) == "wall",
        "WallSE：柱子；同時帶牆鍵的照舊是牆")
    check(kind({ keys = { HitByCar = "", CanScrap = "" } }) == "post", "沒有牆鍵、只有撞車（柵欄柱、收尾柱）：柱子")
    check(code({ flags = { "collideN" } }) == "BLOCKS_EDGE" and code({ flags = { "collideW" } }) == "BLOCKS_EDGE"
        and code({ flags = { "collideN", "collideW" } }) == "BLOCKS_EDGE" and code({ flags = { "collideN" }, keys = { HitByCar = "" } }) == "BLOCKS_EDGE"
        and code({ flags = { "WallSE", "collideW" } }) == "BLOCKS_EDGE",
        "擋一條格邊卻不是牆的（欄杆收尾；使用者 2026-10-31 選不收）：不列，原因 BLOCKS_EDGE；柱子都不擋格邊")
    check(kind({ flags = { "solid" }, keys = { HitByCar = "" } }) == "solid"
        and kind({ flags = { "HoppableN" }, keys = { HitByCar = "" } }) == "fence", "原本就列出的不換種類：帶撞車的實心物件、柵欄照舊")
    SpriteConfigManager.corners = { "corner_01_60" }
    Rules.recordCorners()
    check(kind({ keys = { CanScrap = "" } }, "corner_01_60") == "post" and kind({ keys = { CanScrap = "" } }, "corner_01_61") == nil
        and Rules.corners == 1, "建造配方指定的轉角柱：柱子；其他沒有屬性的照樣不列")
    SpriteConfigManager.corners = {}
    Rules.recordCorners()
    -- 建造配方的圖（EntityScript）：只收地板與地面覆蓋（使用者 2026-10-31 選）
    check(kind({ flags = { "solidfloor", "EntityScript" } }) == "floor" and kind({ flags = { "FloorOverlay", "EntityScript" } }) == "floorOverlay",
        "配方的地板與地面覆蓋：列")
    check(kind({ flags = { "WallN", "EntityScript" }, keys = { WallN = "" } }) == nil
        and code({ flags = { "WallN", "EntityScript" }, keys = { WallN = "" } }) == "ENTITY", "配方的牆：不列，原因 ENTITY")
    -- 不列的原因碼（每個 nil 都帶原因，建造視窗才說得出為什麼）
    check(code({ flags = { "doorW", "open" } }) == "DOOR_OPEN" and code({ flags = { "doorW" }, keys = { DoubleDoor = "3" } }) == "DOUBLE_DOOR"
        and code({}) == "NO_KIND" and code({ keys = { IsMoveAble = "" } }, "crafted_04_120") == "LUA"
        and code({ keys = { RoofGroup = "1" } }, "e_roof_snow_01_3") == "PREFIX" and code({ type = T.tree }) == "TREE"
        and code({ flags = { "vegitation" } }) == "PLANT" and code({ flags = { "solidfloor" }, keys = { waterAmount = "9999" } }) == "WATER"
        and code({ keys = { container = "crate", StackReplaceTileOffset = "-1" } }) == "STACK"
        and code({ type = T.stairsBW, keys = { CanScrap = "" } }) == "STAIRS_PART" and code({ keys = { LightRadius = "5" } }) == "LIGHT"
        and code({ type = T.curtainS, keys = { MoveType = "WindowObject", IsClosedState = "" } }) == "CURTAIN_CLOSED"
        and code({ flags = { "WallSE", "makeWindowInvincible" } }) == "INVINCIBLE", "不列的圖都帶原因碼")
    check(code({ keys = { IsMoveAble = "", IsWaterCollector = "", CustomName = "Rain Collector Barrel" } }) == "COLLECTOR"
        and code({ flags = { "solidtrans" }, keys = { IsWaterCollector = "" } }) == "COLLECTOR"
        and code({ flags = { "WallN" }, keys = { WallN = "", IsWaterCollector = "" } }) ~= "COLLECTOR",
        "集雨桶、金屬桶這類集水的不列（蓋成 IsoThumpable 裝不了水），原因 COLLECTOR；結構類照舊先判斷")
    -- Entry.why：原因與改選的那一張
    local closed = sprite("door_x_01_0", 60, { flags = { "doorN" } })
    local open = sprite("door_x_01_2", 61, { flags = { "doorN", "open" } })
    local wallE = sprite("wall_x_01_0", 62, { flags = { "WallN", "EntityScript" }, keys = { WallN = "", EntityScriptName = "Base.WoodWall" } })
    local post = sprite("fence_x_01_29", 63, { keys = { HitByCar = "" } })
    local p3 = sprite("fence_x_01_3", 64, { keys = { HitByCar = "" } })
    local p13 = sprite("fence_x_01_13", 65, { keys = { HitByCar = "" } })
    -- 另一面的門：目錄只收編號最小的北面（0），西面關著的是 4、開著的是 6
    world({ closed, open, wallE, post, p3, p13,
        sprite("door_z_01_0", 66, { flags = { "doorN" }, keys = { Facing = "N", Woffset = "4" } }),
        sprite("door_z_01_4", 67, { flags = { "doorW" }, keys = { Facing = "W", Noffset = "-4" } }),
        sprite("door_z_01_6", 68, { flags = { "doorW", "open" }, keys = { Facing = "W", Noffset = "-4" } }) })
    local c1, _, alt1 = Entry.why("door_x_01_2")
    local c2, a2 = Entry.why("wall_x_01_0")
    check(c1 == "DOOR_OPEN" and alt1 == "door_x_01_0" and c2 == "ENTITY" and a2 == "Base.WoodWall"
        and Entry.why("nope_01_0") == "UNKNOWN" and Entry.why("door_x_01_0") == nil,
        "Entry.why：開著的門改選關著那張（−2）、配方的牆說是哪個配方、沒有這張圖 UNKNOWN、能蓋的沒有原因")
    check(W.whyText("ENTITY", a2) == "IGUI_MBLD_Why_ENTITY(R:Base.WoodWall)", "配方的原因寫配方的顯示名稱，不寫腳本 ID")
    -- 種類開關：伺服器回 DISABLED、說明是哪個種類、算進設定摘要
    local d0 = Entry.digest()
    sb.KindPost = false
    local pe, pc = Entry.resolve("fence_x_01_29")
    local c3, a3 = Entry.why("fence_x_01_29")
    check(pe == nil and pc == "DISABLED" and c3 == "DISABLED_KIND" and a3 == "post" and Entry.digest() ~= d0,
        "關掉柱子：伺服器回 DISABLED、說明是柱子、設定摘要跟著變（舊視窗的請求回 STALE）")
    check((function()
        Index.reset()
        -- 同一件的兩面：先加 #9 當代表，再來 #2 換成代表（位置不變、編號跟著換）
        Index.add("furniture", "sofa_x_01_9", "sofa_x_01", 9, 1, "sofa_x_01|furniture|Sofa", "Sofa")
        Index.add("furniture", "sofa_x_01_5", "sofa_x_01", 5, 1)
        Index.add("furniture", "sofa_x_01_2", "sofa_x_01", 2, 1, "sofa_x_01|furniture|Sofa", "Sofa")
        -- 不該發生的重複編號（補零的名稱）：不掉項目
        Index.add("wall", "dup_x_01_7", "dup_x_01", 7, 1)
        Index.add("wall", "dup_x_01_07", "dup_x_01", 7, 1)
        Index.add("wall", "dup_x_01_1", "dup_x_01", 1, 1)
        for i = 1, Index.setName.n do Index.sortSet(Index.setName[i]) end
        local s, d = Index.bucket.furniture.sofa_x_01, Index.bucket.wall.dup_x_01
        return s.n == 2 and s[1] == "sofa_x_01_2" and s[2] == "sofa_x_01_5" and s.k == nil
            and d.n == 3 and d[1] == "dup_x_01_1" and d[2] == "dup_x_01_7" and d[3] == "dup_x_01_07"
    end)(), "排序：同一件換成編號較小的那面時照新編號排；重複的編號不掉項目、照加入順序；排完桶只留名稱")
    -- 建造視窗：同組照編號排、完整名稱搜關掉的種類不列並說明、開著的門改選關著那扇、頁籤種類與狀態列
    Index.reset()
    Index.add("door", "door_x_01_0", "door_x_01", 0, 1)
    Index.add("door", "door_z_01_0", "door_z_01", 0, 1)
    for _, n in ipairs({ 29, 3, 13 }) do Index.add("post", "fence_x_01_" .. n, "fence_x_01", n, 1) end
    for i = 1, Index.setName.n do
        Index.addSetKey(i, "")
        Index.sortSet(Index.setName[i])
    end
    local b = Index.bucket.post.fence_x_01
    check(b[1] == "fence_x_01_3" and b[2] == "fence_x_01_13" and b[3] == "fence_x_01_29", "同一組照編號排（3、13、29，不照字串）")
    sb.DisabledTilesets = ""
    local function st(q) return { query = q, tab = "all", cat = "all", source = "all", recent = { n = 0 } } end
    local hidden = W.filter(st("fence_x_01_29"))
    local title, hint = W.emptyQuery("fence_x_01_29")
    local wallTab = table.concat(W.tabKinds("wall"), ",")
    check(hidden.n == 0 and title:find("IGUI_MBLD_Why_Title", 1, true) and hint:find("IGUI_MBLD_Why_DISABLED_KIND", 1, true)
        and W.kindsOff() == 1 and wallTab == "wall,fence,wallOverlay",
        "關掉的種類：完整名稱也搜不到、空白狀態說明是哪個種類、頁籤不含它、狀態列算得出關了幾種")
    sb.KindPost = nil
    local r, jump = W.filter(st("door_x_01_2"))
    check(r.n == 1 and r[1] == "door_x_01_0" and jump == "door_x_01_0", "搜開著的門：清單換成關著那扇所在的桶並選到它")
    check((function()
        local r2, jump2 = W.filter(st("door_z_01_6"))
        return r2.n == 1 and r2[1] == "door_z_01_0" and jump2 == "door_z_01_0"
    end)(), "搜另一面開著的門：先換成關著那扇（−2），它不在目錄就找目錄收的那一面")
    sb.KindDoor = false
    check((function() -- 主程式的 local 已到 200 上限：新的檢查包在函式裡
        local c4, a4, alt4 = Entry.why("door_x_01_2")
        return c4 == "DISABLED_KIND" and a4 == "door" and alt4 == nil
    end)(), "開著的門、關著那扇的種類被關了：說是哪個種類被關，不叫玩家去找蓋不了的那張")
    sb.KindDoor = nil
    -- 管理面板：合併只動這次改的 id，照字母排、分號接
    check(Admin.merge("b;a; c ", { d = true, a = false }) == "b;c;d" and Admin.merge("", { x = false }) == "",
        "管理面板合併：沒改到的留著、打開的拿掉、關掉的加進去，排序後分號接")
    -- 管理面板套用：權限和原版封包同一個判斷、先驗完才動手、多人等伺服器的值回來（逾時算失敗）
    ;(function()
        local real = { isClient, isCoopHost, haveAccess, getSandboxOptions, SandboxOptions }
        clockStep = 0 -- 逾時只靠下面手動往前撥
        local allowed, sent, liveSets, lua = false, {}, {}, 0
        -- 伺服器現在的整份設定：原版、別的 MOD、本 MOD 沒改到的值都要原樣送回去（封包是整份快照）
        local liveVals = { ["Base.Zombies"] = 4, ["OtherMod.Opt"] = "x", ["MinidoracatBuilder.KindPost"] = true,
            ["MinidoracatBuilder.DisabledTilesets"] = "keep_01" }
        sb.DisabledTilesets = "keep_01"
        local live = { vals = liveVals }
        function live:getOptionByName(n) return liveVals[n] ~= nil or nil end
        function live:set(n, v) liveSets[#liveSets + 1] = n; liveVals[n] = v; sb[n:sub(20)] = v end
        function live:toLua() lua = lua + 1 end
        getSandboxOptions = function() return live end
        SandboxOptions = { new = function()
            local c = { vals = {} }
            function c:copyValuesFrom(o) for k, v in pairs(o.vals) do self.vals[k] = v end end
            function c:set(n, v) self.vals[n] = v end
            function c:sendToServer()
                local snap, n = {}, 0
                for k, v in pairs(self.vals) do snap[k] = v; n = n + 1 end
                snap.n = n
                sent[#sent + 1] = snap
            end
            return c
        end }
        isCoopHost = function() return false end
        haveAccess = function(cap) return allowed and cap == "SandboxOptions" end
        isClient = function() return true end
        local okA, errA = Admin.apply({ kinds = { post = false } })
        check(Admin.canManage() == false and okA == false and errA == "NO_PERMISSION" and #sent == 0,
            "多人、連線沒有沙盒權限：不能管理、不送封包（送了會被伺服器記反作弊）")
        isCoopHost = function() return true end
        check(Admin.canManage() == true, "合作模式的主機：照原版封包放行")
        isCoopHost = function() return false end
        allowed = true
        local done, ticks = {}, count("OnTick")
        local ok1 = Admin.apply({ kinds = { post = false } }, function(v) done[#done + 1] = v end)
        local poll = handlers.OnTick[#handlers.OnTick]
        local ok2, e2 = Admin.apply({ kinds = { post = true } })
        local s1 = sent[1] or {}
        check(ok1 == true and #sent == 1 and s1.n == 4 and s1["MinidoracatBuilder.KindPost"] == false and s1["Base.Zombies"] == 4
            and s1["OtherMod.Opt"] == "x" and s1["MinidoracatBuilder.DisabledTilesets"] == "keep_01" and ok2 == false and e2 == "BUSY",
            "有權限：送整份設定、只改這次的選項（原版、別的 MOD、沒改到的照舊）；等待中再套用回 BUSY")
        poll()
        check(#done == 0 and Admin.pending ~= nil, "伺服器的值還沒回來：繼續等")
        sb.KindPost = false
        poll()
        check(done[1] == true and Admin.pending == nil and count("OnTick") == ticks, "伺服器的值回來：成功、摘掉 tick 事件")
        liveVals["OtherMod.Opt"] = "y" -- 套用前收到別人改的值：照收到的送
        Admin.apply({ tilesets = { foo_01 = true } }, function(v) done[#done + 1] = v end)
        local s2 = sent[2] or {}
        check(s2["OtherMod.Opt"] == "y" and s2["MinidoracatBuilder.DisabledTilesets"] == "foo_01;keep_01"
            and s2["MinidoracatBuilder.KindPost"] == true, "套用當下才複製：帶上剛收到的別人的值，圖塊組照現在的字串合併")
        nowMs = nowMs + Admin.TIMEOUT_MS + 1
        handlers.OnTick[#handlers.OnTick]()
        check(done[2] == false and Admin.pending == nil and count("OnTick") == ticks, "超過 10 秒沒回來：失敗、摘掉 tick 事件")
        isClient = function() return false end
        local okU, eU, kU = Admin.apply({ kinds = { post = true }, rules = { NoSuch = 1 } })
        check(okU == false and eU == "UNKNOWN_OPTION" and kU == "NoSuch" and #liveSets == 0,
            "單機遇到不存在的選項：回 UNKNOWN_OPTION，一個都沒改（set 會丟例外，不能改到一半）")
        local okS = Admin.apply({ kinds = { post = true } })
        check(okS == true and #liveSets == 1 and lua == 1 and sb.KindPost == true and Admin.pending == nil,
            "單機：直接改好、更新 SandboxVars")
        isClient, isCoopHost, haveAccess, getSandboxOptions, SandboxOptions = real[1], real[2], real[3], real[4], real[5]
        sb.KindPost, sb.DisabledTilesets = nil, ""
    end)()
    getText, getTextOrNull = realGetText, realGetTextOrNull
end

print("情境二十六：地面覆蓋照地圖掛在地板上（2026-10-31 交通標線斷斷續續）：蓋、重複、拆、帳本、地板移除、讀檔改掛")
;(function()
    nowMs = nowMs + 180000
    local Place, Dismantle, Overlays = MinidoracatBuilder.Place, MinidoracatBuilder.Dismantle, MinidoracatBuilder.Overlays
    local Menu = MinidoracatBuilder.Menu
    local realInst = instanceof
    instanceof = function(o, cls) return type(o) == "table" and o.class ~= nil and (o.class == cls or cls == "IsoObject") end
    scrapDefs.OvMetal = { perk = perkObj("MetalWelding"), returnItems = { { returnItem = "Base.ScrapMetal", maxAmount = 2 } } }
    local floorS = sprite("ov_floor_01_0", 2606, { flags = { "solidfloor" } })
    local tlS = sprite("ov_lines_01_10", 2601, { flags = { "FloorOverlay" } })
    local tl2S = sprite("ov_lines_01_11", 2607, { flags = { "FloorOverlay" } })
    local debrisS = sprite("ov_debris_01_0", 2602, { flags = { "attachedFloor" } })
    local scrapS = sprite("ov_scrap_01_0", 2603, { flags = { "FloorOverlay", "attachedFloor" },
        keys = { CanScrap = "", Material = "OvMetal" } })
    local looseS = sprite("ov_scrap_01_1", 2604, { flags = { "attachedFloor" }, keys = { CanScrap = "", Material = "OvMetal" } })
    local gridS = sprite("ov_grid_01_0", 2605, { flags = { "FloorOverlay" } })
    gridS.grid = { getAnchorSprite = function() return gridS end }
    world({ floorS, tlS, tl2S, debrisS, scrapS, looseS, gridS })
    local TL, TL2 = "ov_lines_01_10", "ov_lines_01_11"
    check(Rules.onFloor("floorOverlay", tlS) and not Rules.onFloor("floorOverlay", debrisS)
        and not Rules.onFloor("floorOverlay", gridS) and not Rules.onFloor("solid", tlS)
        and Rules.classify(tlS) == "floorOverlay" and Rules.classify(debrisS) == "floorOverlay",
        "照地圖：帶 FloorOverlay 的單格地面覆蓋掛在地板上；只有 attachedFloor 的、多格的照舊建物件")
    check(Cost.refund("floorOverlay", scrapS) == "builder" and Cost.refund("floorOverlay", looseS) == "scrap",
        "掛在地板上的歸本工具拆（原版拆解點不到），帶 CanScrap 也一樣；獨立物件照舊原版拆")

    -- 地板：附加圖、modData、兩種同步各送幾次。格子移除物件時照引擎先觸發 OnObjectAboutToBeRemoved
    local function floorOf(sq)
        local f = { class = "IsoObject", att = {}, md = {}, sprites = 0, mds = 0 }
        function f:getSprite() return floorS end
        function f:getSquare() return sq end
        function f:getAttachedAnimSprite() return javaList(self.att) end
        function f:addAttachedAnimSprite(spr) self.att[#self.att + 1] = { getParentSprite = function() return spr end } end
        function f:RemoveAttachedAnim(i) table.remove(self.att, i + 1) end
        function f:hasModData() return next(self.md) ~= nil end
        function f:getModData() return self.md end
        function f:transmitUpdatedSpriteToClients() self.sprites = self.sprites + 1 end
        function f:transmitModData() self.mds = self.mds + 1 end
        return f
    end
    local function hung(f)
        local out = {}
        for i, a in ipairs(f.att) do out[i] = a:getParentSprite():getName() end
        return table.concat(out, ",")
    end
    local function ground(x, y, noFloor)
        local o = {}
        local sq = square(x, y, 0, o)
        if not noFloor then o.floor = floorOf(sq) end
        sq.dropped = {}
        function sq:AddWorldInventoryItem(ft) self.dropped[ft] = (self.dropped[ft] or 0) + 1 end
        local orig = sq.transmitRemoveItemFromSquare
        function sq:transmitRemoveItemFromSquare(obj, safely)
            fire("OnObjectAboutToBeRemoved", obj)
            return orig(self, obj, safely)
        end
        return sq, o.floor
    end
    local function lastSent() return sent[#sent] and sent[#sent].cmd, sent[#sent] and sent[#sent].args or {} end
    local function unbuild(p, n, x, y, e)
        sent = {}
        Server.dismantleIntent(p, { n = n, t = { x, y, 0, e } })
        sent = {}
        Server.dismantle(p, n, 1)
        return lastSent()
    end
    local here = ground(44, 46)
    local Pl = player({ id = 2601, x = 44.5, y = 45.5, here = here })
    Pl.inv:add(item("Base.Hammer", { HAMMER = true }))
    local pay = Cost.of("floorOverlay", tlS, 1).items
    give(Pl, pay)

    local A, fA = ground(44, 44)
    local ok, cmd = build(Pl, 2601, TL, { 44, 44, 0 })
    local rec = Overlays.get(A, TL)
    local same = rec ~= nil
    for ft, n in pairs(pay) do if not rec or rec[ft] ~= n then same = false end end
    check(ok and cmd == "placed" and #A.objects == 0 and hung(fA) == TL and fA.md.builderOverlays[TL] == true
        and fA.sprites == 1 and fA.mds == 1 and same,
        "蓋交通標線：掛在那格地板上、不建物件，附加圖與記號都送給客戶端，退料（＝付的料）記在覆蓋帳本")
    give(Pl, pay)
    local ok2, _, a2 = build(Pl, 2602, TL, { 44, 44, 0 })
    check(not ok2 and a2.code == "SAME_TILE" and hung(fA) == TL, "同一格已經掛著同一張：SAME_TILE，不疊兩張")
    local B, fB = ground(45, 44)
    fB:addAttachedAnimSprite(tlS) -- 地圖原有的
    local ok3, _, a3 = build(Pl, 2603, TL, { 45, 44, 0 })
    check(not ok3 and a3.code == "SAME_TILE" and hung(fB) == TL, "地圖原本就掛著同一張：SAME_TILE")
    local N = ground(46, 44, true)
    local ok4, _, a4 = build(Pl, 2604, TL, { 46, 44, 0 })
    check(not ok4 and a4.code == "BLOCKED" and #N.objects == 0, "沒有地板的格子：BLOCKED（沒地方掛），也不建物件")

    -- 右鍵選單只列有記號的；伺服器只認帳本
    local tg = Menu.targets({ { getSquare = function() return A end } })
    check(#tg == 1 and tg[1].kind == "floorOverlay" and tg[1].overlay ~= nil and tg[1].name == TL
        and #Menu.targets({ { getSquare = function() return B end } }) == 0,
        "右鍵選單：列出本 MOD 掛的那張；地圖原有的（沒有記號）不列")
    fB.md.builderOverlays = { [TL] = true } -- 記號在、覆蓋帳本沒有那一筆
    local c, a = unbuild(Pl, 2605, 45, 44, TL)
    check(c == "dismantleSkipped" and a.code == "NOT_OURS" and hung(fB) == TL,
        "地圖原有的、地板上有記號但覆蓋帳本沒有：NOT_OURS、不拿掉")
    local bare = player({ id = 2602, x = 44.5, y = 45.5, here = here })
    c, a = unbuild(bare, 2606, 44, 44, TL)
    check(c == "dismantleSkipped" and a.code == "NO_TOOL" and hung(fA) == TL, "沒帶工具（和蓋的時候一樣）：NO_TOOL、不拿掉")
    HARNESS_ROLL = "max"
    c = unbuild(Pl, 2607, 44, 44, TL)
    local back = true
    for ft, n in pairs(pay) do if here.dropped[ft] ~= n then back = false end end
    check(c == "dismantled" and hung(fA) == "" and fA.md.builderOverlays == nil and Overlays.get(A, TL) == nil and back
        and fA.sprites == 2 and fA.mds == 2, "拆：拿掉附加圖與記號並同步、清帳本、照帳本退（最多全部）")
    c, a = unbuild(Pl, 2608, 44, 44, TL)
    check(c == "dismantleSkipped" and a.code == "GONE", "拆過的再拆一次：GONE、不再退")
    -- 記號只決定選單列不列：記號被清掉、附加圖與帳本都在，伺服器照樣拆
    local W, fW = ground(45, 45)
    give(Pl, pay)
    build(Pl, 2610, TL, { 45, 45, 0 })
    fW.md.builderOverlays = nil
    here.dropped = {}
    c = unbuild(Pl, 2611, 45, 45, TL)
    check(c == "dismantled" and hung(fW) == "" and Overlays.get(W, TL) == nil and here.dropped["Base.Plank"] == 1,
        "記號被清掉、附加圖與帳本都在：伺服器照樣拆、照帳本退")
    local Q, fQ = ground(45, 46)
    give(Pl, pay)
    build(Pl, 2615, TL, { 45, 46, 0 })
    function fQ:RemoveAttachedAnim() end -- 引擎丟的例外 Kahlua 只記 log：圖沒拿掉
    here.dropped = {}
    c, a = unbuild(Pl, 2616, 45, 46, TL)
    check(c == "dismantleRefused" and a.code == "INTERNAL" and hung(fQ) == TL and Overlays.get(Q, TL) ~= nil
        and next(here.dropped) == nil, "拿不掉那張（引擎出錯）：INTERNAL、不退料、帳本留著、整批停")

    -- 地板移出世界：那一格整格清掉，不看那時還掛著哪幾張；別的物件移除時不動帳本
    local D, fD = ground(43, 45)
    give(Pl, Cost.of("floorOverlay", tl2S, 1).items)
    local okD = build(Pl, 2609, TL2, { 43, 45, 0 })
    local other = { class = "IsoObject", att = {} }
    function other:getSquare() return D end
    function other:getSprite() return debrisS end
    function other:getAttachedAnimSprite() return javaList({ { getParentSprite = function() return tl2S end } }) end
    fire("OnObjectAboutToBeRemoved", other)
    local kept = okD and Overlays.get(D, TL2) ~= nil
    fD.att = {} -- 原版鏟地這類只拿掉附加圖、不移除地板：帳本留著
    local still = Overlays.get(D, TL2) ~= nil
    fire("OnObjectAboutToBeRemoved", fD)
    check(kept and still and Overlays.get(D, TL2) == nil,
        "地板移除時那一格整格清掉（附加圖先被拿掉也一樣）；別的物件移除時不動")
    local Cf, fCf = ground(43, 46)
    give(Pl, pay)
    build(Pl, 2614, TL, { 43, 46, 0 })
    local had = Overlays.get(Cf, TL) ~= nil
    function fCf:getProperties() return floorS:getProperties() end
    function fCf:getTextureName() return floorS:getName() end
    function fCf:getType() return T.normal end
    Cf.objects[#Cf.objects + 1] = fCf
    Place.clearFloor(Cf)
    check(had and #Cf.objects == 0 and Overlays.get(Cf, TL) == nil, "本工具換地板（先拆舊地板）：那一格的覆蓋帳本跟著清")
    local U, fU = ground(47, 46)
    Place.undo({ Place.attach(U, tlS, { ["Base.Plank"] = 1 }) })
    check(hung(fU) == "" and fU.md.builderOverlays == nil and Overlays.get(U, TL) == nil, "放到一半出錯拆回：拿掉那張、清記號與帳本")
    local E, fE = ground(42, 45)
    function fE:transmitModData() error("injected failure after addAttachedAnimSprite") end
    local placedE = {}
    local okE = pcall(Place.attach, E, tlS, { ["Base.Plank"] = 1 }, placedE)
    function fE:transmitModData() self.mds = self.mds + 1 end
    Place.undo(placedE)
    check(not okE and #placedE == 1 and hung(fE) == "" and fE.md.builderOverlays == nil and Overlays.get(E, TL) == nil,
        "掛上之後才出錯：紀錄在掛之前就記進 placed，拆回拿得掉")
    -- 附加圖存檔、同步只帶 255 張：滿了不掛（地圖原有的也算）
    local Fu, fFu = ground(46, 45)
    local fill = sprite("ov_fill_01_0", 2608, { flags = { "FloorOverlay" } })
    for _ = 1, 255 do fFu:addAttachedAnimSprite(fill) end
    give(Pl, pay)
    local okF, _, aF = build(Pl, 2612, TL, { 46, 45, 0 })
    table.remove(fFu.att)
    local okG = build(Pl, 2613, TL, { 46, 45, 0 })
    check(not okF and aF.code == "BLOCKED" and okG and #fFu.att == 255 and Overlays.get(Fu, TL) ~= nil,
        "地板已有 255 張附加圖：BLOCKED、不扣料；少一張就掛得上")
    local placedFu = {}
    local okA = pcall(Place.attach, Fu, tl2S, { ["Base.Plank"] = 1 }, placedFu)
    check(not okA and #placedFu == 0 and #fFu.att == 255 and Overlays.get(Fu, TL2) == nil,
        "直接掛到已有 255 張的地板：丟錯，什麼都沒動（沒記紀錄、沒掛、沒記帳本）")

    -- 讀檔改掛：0.2.0 以前的獨立物件，帳本建好後的下一個 tick 改掛到地板，退料照 buildMaterials
    local function legacy(sq, spr, entry)
        local o = { class = "IsoThumpable", spr = spr, mats = { ["Base.Plank"] = "2", ["Base.Nails"] = "1" },
            md = { builderEntry = entry } }
        function o:getSprite() return self.spr end
        function o:getSquare() return sq end
        function o:hasModData() return true end
        function o:getModData() return self.md end
        function o:getBuildMaterials() return self.mats end
        function o:isFloor() return self.floor == true end
        function o:hasBuildMaterials() return next(self.mats) ~= nil end
        function o:isCorner() return false end
        -- 舊版地面覆蓋建的時候伺服器設的欄位（Place 的 thumpable）：不是地板、殭屍不打、可穿過；三項各自翻
        function o:isThumpable() return self.thump == true end
        function o:isCanPassThrough() return self.pass ~= false end
        function o:getThumpDmg() return 8 end
        function o:getContainerCount() return 0 end
        function o:getName() return self.name end
        function o:setName(v) self.name = v end
        sq.objects[#sq.objects + 1] = o
        return o
    end
    local L, fL = ground(41, 41)
    local LN = ground(42, 41, true)
    local LD, fLD = ground(43, 41)
    fLD:addAttachedAnimSprite(tlS)
    local LT = ground(41, 42)
    legacy(L, tlS, TL)
    local noFloor = legacy(LN, tlS, TL)
    local dup = legacy(LD, tlS, TL)
    local mismatch = legacy(LT, tlS, "something_else_01_0")
    local LW = ground(42, 42)
    local wallLike = legacy(LW, tlS, TL)
    wallLike.thump = true -- 圖和記號都改成標線、殭屍打得到的牆
    local LF, fLF = ground(44, 41)
    local floorLike = legacy(LF, tlS, TL)
    floorLike.floor = true -- 只有「是地板」不像（一樓的地板讀檔時走地板那條，不會排隊；二樓以上才會，下面直接呼叫）
    local LP, fLP = ground(44, 42)
    local noPass = legacy(LP, tlS, TL)
    noPass.pass = false -- 只有「不能穿過」不像
    local LG, fLG = ground(44, 43)
    local moved = legacy(LG, tlS, TL)
    local LS = ground(43, 42)
    local swapped = legacy(LS, tlS, TL)
    local LR, fLR = ground(43, 43)
    local stuck = legacy(LR, tlS, TL)
    function LR:transmitRemoveItemFromSquare() return -1 end -- 移除失敗：物件還在
    local ticks = count("OnTick")
    local inst = Overlays.instance
    Overlays.instance = nil -- 單機：讀格子時帳本還沒建
    for _, sq in ipairs({ L, LN, LD, LT, LW, LS, LR, LP, LG }) do fire("LoadGridsquare", sq) end
    swapped.spr, swapped.md.builderEntry = debrisS, debrisS:getName() -- 排隊之後才換成不掛的圖
    ground(44, 43) -- 排隊之後那一格換成另一份（卸載重載）：排著的是舊的那份
    fire("OnTick")
    local waited = #L.objects == 1 and count("OnTick") == ticks + 1
    Overlays.instance = inst
    fire("OnTick")
    local r = Overlays.get(L, TL)
    check(waited and #L.objects == 0 and hung(fL) == TL and fL.md.builderOverlays[TL] == true and r
        and r["Base.Plank"] == 2 and r["Base.Nails"] == 1 and count("OnTick") == ticks,
        "讀檔改掛：帳本建好前先排著；建好後的下一個 tick 拿掉舊物件、掛到地板，退料照 buildMaterials，摘掉 tick 事件")
    check(LN.objects[1] == noFloor and LD.objects[1] == dup and hung(fLD) == TL and LT.objects[1] == mismatch
        and Overlays.get(LD, TL) == nil and Overlays.get(LT, TL) == nil,
        "不改掛：沒有地板、地板上已經有同一張、記號和圖不一樣的照舊留著，不記帳本")
    local okFL, didFL = pcall(Place.relink, floorLike)
    check(LW.objects[1] == wallLike and okFL and didFL == false and LF.objects[1] == floorLike and LP.objects[1] == noPass
        and hung(fLF) == "" and hung(fLP) == "" and Overlays.get(LW, TL) == nil and Overlays.get(LF, TL) == nil
        and Overlays.get(LP, TL) == nil and LS.objects[1] == swapped and Overlays.get(LS, debrisS:getName()) == nil,
        "不改掛：建的時候的欄位有一項不像舊版地面覆蓋（殭屍打得到、是地板、不能穿過）、排隊之後換成不掛的圖，照舊留著")
    check(LG.objects[1] == moved and hung(fLG) == "" and Overlays.get(LG, TL) == nil,
        "不改掛：排隊之後那一格已換成另一份（卸載重載），舊的那份照舊")
    check(LR.objects[1] == stuck and hung(fLR) == "" and fLR.md.builderOverlays == nil and Overlays.get(LR, TL) == nil,
        "改掛時舊物件移不掉：拿掉剛掛的那張、清記號與帳本，舊物件留著")
    local LX, fLX = ground(45, 41)
    for _ = 1, 255 do fLX:addAttachedAnimSprite(fill) end
    local full = legacy(LX, tlS, TL)
    local okX, didX = pcall(Place.relink, full)
    check(okX and didX == false and LX.objects[1] == full and #fLX.att == 255 and Overlays.get(LX, TL) == nil,
        "地板已有 255 張附加圖：不改掛（不丟錯），舊物件留著")

    -- 安全屋與建造作弊（其他種類走同一條路，這裡補覆蓋的）
    local SH, fSH = ground(43, 44)
    SH.owner = "someone"
    give(Pl, pay)
    local okSH, _, aSH = build(Pl, 2615, TL, { 43, 44, 0 })
    check(not okSH and aSH.code == "SAFEHOUSE" and hung(fSH) == "" and Overlays.get(SH, TL) == nil,
        "別人的安全屋：SAFEHOUSE、不掛、不記帳本")
    local SD, fSD = ground(42, 44)
    local okSD = build(Pl, 2616, TL, { 42, 44, 0 })
    SD.owner = "someone"
    local cSD, aSD = unbuild(Pl, 2617, 42, 44, TL)
    SD.owner = nil
    check(okSD and cSD == "dismantleSkipped" and aSD.code == "SAFEHOUSE" and hung(fSD) == TL and Overlays.get(SD, TL) ~= nil,
        "拆別人安全屋裡的：SAFEHOUSE、不拿掉、帳本留著")
    local CP = player({ id = 2603, x = 44.5, y = 45.5, here = here, cheat = true })
    local CC, fCC = ground(42, 46)
    local okC = build(CP, 2618, TL, { 42, 46, 0 })
    local recC = Overlays.get(CC, TL)
    here.dropped = {}
    local cC = unbuild(CP, 2619, 42, 46, TL)
    check(okC and recC ~= nil and next(recC) == nil and cC == "dismantled" and hung(fCC) == "" and next(here.dropped) == nil,
        "建造作弊：照掛、帳本是空表；拆得掉、什麼都不退")
    instanceof = realInst
    scrapDefs.OvMetal = nil
end)()

print("情境二十六之二：牆上疊圖照地圖掛在牆上（使用者 2026-11-12 選 trim=attach；B 站 3t47k 斜條紋）：掛、沒牆照舊、同名、拆、牆移除、換牆掛回、讀檔改掛")
;(function()
    nowMs = nowMs + 180000
    local Place, Overlays, Menu = MinidoracatBuilder.Place, MinidoracatBuilder.Overlays, MinidoracatBuilder.Menu
    local realInst, realNew = instanceof, IsoThumpable.new
    instanceof = function(o, cls) return type(o) == "table" and o.class ~= nil and (o.class == cls or cls == "IsoObject") end
    local wallS = sprite("wo_wall_01_1", 2701, { flags = { "WallN", "cutN" }, keys = { WallN = "" } })
    local wall2S = sprite("wo_wall_01_2", 2702, { flags = { "WallN", "cutN" }, keys = { WallN = "" } })
    local wallWS = sprite("wo_wall_01_0", 2703, { flags = { "WallW", "cutW" }, keys = { WallW = "" } })
    local trimN = sprite("wo_trim_01_14", 2704, { flags = { "WallOverlay", "attachedN" } })
    local trimW = sprite("wo_trim_01_13", 2705, { flags = { "WallOverlay", "attachedW" } })
    local trimSE = sprite("wo_trim_01_20", 2706, { flags = { "WallOverlay", "attachedSE", "attachedN" } })
    local signS = sprite("wo_sign_01_0", 2707, { flags = { "WallOverlay", "attachedN" },
        keys = { IsMoveAble = "", MoveType = "WallObject" } })
    local gridT = sprite("wo_trim_01_30", 2708, { flags = { "WallOverlay", "attachedN" } })
    gridT.grid = { getAnchorSprite = function() return gridT end }
    world({ wallS, wall2S, wallWS, trimN, trimW, trimSE, signS, gridT })
    local TN, TW = "wo_trim_01_14", "wo_trim_01_13"
    check(Rules.classify(trimN) == "wallObject" and Rules.onWall("wallObject", trimN) == "N"
        and Rules.onWall("wallObject", trimW) == "W" and Rules.onWall("wallObject", trimSE) == "SE"
        and Rules.onWall("wallObject", signS) == nil and Rules.onWall("wallObject", gridT) == nil and Rules.onWall("attached", trimN) == nil,
        "照地圖（CellLoader）：帶 WallOverlay 的單格掛牆物照 attachedSE → W → N 掛；能搬的、多格的、別的種類不掛")
    check(Cost.refund("wallObject", trimN) == "builder" and Cost.refund("wallObject", signS) == "pickup",
        "掛在牆上的歸本工具拆（原版拆解點不到）；能搬的照舊原版撿起")

    -- 牆：附加圖、modData、兩種同步各送幾次。ours＝本工具蓋的（替換用）
    local function wallOf(sq, spr, ours)
        local w = { class = ours and "IsoThumpable" or "IsoObject", spr = spr, att = {}, md = {}, sprites = 0, mds = 0,
            mats = { ["Base.Plank"] = "3" } }
        if ours then w.md.builderEntry = spr:getName() end
        function w:getSprite() return self.spr end
        function w:getProperties() return self.spr:getProperties() end
        function w:getSquare() return sq end
        function w:getAttachedAnimSprite() return javaList(self.att) end
        function w:addAttachedAnimSprite(s) self.att[#self.att + 1] = { getParentSprite = function() return s end } end
        function w:RemoveAttachedAnim(i) table.remove(self.att, i + 1) end
        function w:hasModData() return next(self.md) ~= nil end
        function w:getModData() return self.md end
        function w:transmitUpdatedSpriteToClients() self.sprites = self.sprites + 1 end
        function w:transmitModData() self.mds = self.mds + 1 end
        function w:isFloor() return false end
        function w:isDismantable() return true end
        function w:getBuildMaterials() return self.mats end
        function w:hasBuildMaterials() return next(self.mats) ~= nil end
        function w:getSpriteGridObjectsIncludingSelf() return javaList({ self }) end
        function w:isConnectedSpriteGridObject(y) return y == self end
        function w:isObjectNoContainerOrEmpty() return true end
        function w:isBarricaded() return false end
        function w:getMaxHealth() return 450 end
        function w:getHealth() return 450 end
        function w:getContainer() return nil end
        sq.objects[#sq.objects + 1] = w
        return w
    end
    local function hung(w)
        local out = {}
        for i, a in ipairs(w.att) do out[i] = a:getParentSprite():getName() end
        return table.concat(out, ",")
    end
    -- 格子：getWall／getWallSE 照引擎掃格上物件（IsoGridSquare.java:4590-4610）；移除物件前照引擎觸發 OnObjectAboutToBeRemoved
    local function edgeSq(x, y, flags)
        local sq = square(x, y, 0, { flags = flags })
        sq.dropped = {}
        function sq:AddWorldInventoryItem(ft) self.dropped[ft] = (self.dropped[ft] or 0) + 1 end
        local function find(k, notSE)
            for _, o in ipairs(sq.objects) do
                local p = o.getProperties and o:getProperties()
                if p and p:has(k) and not (notSE and p:has(F.WallSE)) then return o end
            end
            return nil
        end
        function sq:getWall(north) return find(north and F.cutN or F.cutW, true) end
        function sq:getWallSE() return find(F.WallSE) end
        local orig = sq.transmitRemoveItemFromSquare
        function sq:transmitRemoveItemFromSquare(obj, safely)
            fire("OnObjectAboutToBeRemoved", obj)
            return orig(self, obj, safely)
        end
        return sq
    end
    local function unbuild(p, n, x, y, e)
        sent = {}
        Server.dismantleIntent(p, { n = n, t = { x, y, 0, e } })
        sent = {}
        Server.dismantle(p, n, 1)
        return sent[#sent] and sent[#sent].cmd, sent[#sent] and sent[#sent].args or {}
    end
    local here = edgeSq(45, 49)
    local Pl = player({ id = 2701, x = 45.5, y = 49.5, here = here })
    Pl.inv:add(item("Base.Hammer", { HAMMER = true }))
    local pay = Cost.of("wallObject", trimN, 1).items
    local function samePay(rec)
        if not rec then return false end
        for ft, n in pairs(pay) do if rec[ft] ~= n then return false end end
        return true
    end

    -- 地圖原有的北牆：掛上去，格子不多物件，帳本記在那條邊
    local A = edgeSq(45, 48)
    local wA = wallOf(A, wallS)
    give(Pl, pay)
    local ok, cmd = build(Pl, 2701, TN, { 45, 48, 0 })
    check(ok and cmd == "placed" and #A.objects == 1 and hung(wA) == TN and wA.md.builderOverlays[TN] == true
        and wA.sprites == 1 and wA.mds == 1 and samePay(Overlays.get(A, TN, "N")) and Overlays.get(A, TN) == nil,
        "蓋在地圖原有的北牆：掛在牆上（附加圖 +1）、格子不多物件，附加圖與記號送給客戶端，帳本記在那條邊（不是地板的鍵）")
    give(Pl, pay)
    local ok2, _, a2 = build(Pl, 2702, TN, { 45, 48, 0 })
    check(not ok2 and a2.code == "SAME_TILE" and hung(wA) == TN and #A.objects == 1, "同一面牆已經掛著同一張：SAME_TILE")
    local B = edgeSq(46, 48)
    local wB = wallOf(B, wallS)
    wB:addAttachedAnimSprite(trimN) -- 地圖原有的
    local ok3, _, a3 = build(Pl, 2703, TN, { 46, 48, 0 })
    check(not ok3 and a3.code == "SAME_TILE" and hung(wB) == TN, "地圖原本就掛著同一張：SAME_TILE")
    -- 那條邊沒有牆：照舊建獨立物件（地圖同一條退路）；只有西牆時北邊的圖也照舊
    local C = edgeSq(44, 48)
    local okC = build(Pl, 2704, TN, { 44, 48, 0 })
    local Cw = edgeSq(44, 49)
    local wCw = wallOf(Cw, wallWS)
    give(Pl, pay)
    local okCw = build(Pl, 2705, TN, { 44, 49, 0 })
    check(okC and #C.objects == 1 and C.objects[1].name == TN and C.objects[1].set ~= nil and Overlays.get(C, TN, "N") == nil
        and okCw and #Cw.objects == 2 and hung(wCw) == "" and Overlays.get(Cw, TN, "N") == nil,
        "那條邊沒有牆（或只有另一條邊的牆）：照舊建成獨立物件，不記覆蓋帳本")
    local D = edgeSq(46, 49)
    local wD = wallOf(D, wallWS)
    give(Pl, Cost.of("wallObject", trimW, 1).items)
    local okD = build(Pl, 2706, TW, { 46, 49, 0 })
    check(okD and hung(wD) == TW and #D.objects == 1 and Overlays.get(D, TW, "W") ~= nil, "西邊的圖掛在西牆，帳本記在 W")

    -- 右鍵選單、拆除照帳本退、牆留著
    local tg = Menu.targets({ { getSquare = function() return A end } })
    check(#tg == 1 and tg[1].kind == "wallObject" and tg[1].overlay and tg[1].overlay.host == wA and tg[1].name == TN
        and #Menu.targets({ { getSquare = function() return B end } }) == 0,
        "右鍵選單：列出本 MOD 掛在牆上的那張（種類照掛牆物）；地圖原有的不列")
    function Pl.inv:getItems() return javaList(self.items) end
    local Area = MinidoracatBuilder.Area
    local st1 = Area.stamp(45, 48, 45, 48, 0, Pl)
    wA:addAttachedAnimSprite(trimW)
    local st2 = Area.stamp(45, 48, 45, 48, 0, Pl)
    table.remove(wA.att)
    check(st1 ~= st2 and Area.stamp(45, 48, 45, 48, 0, Pl) == st1,
        "一區拆除的預覽戳記算進牆上的附加圖：物件數不變、牆上多一張也會重算")
    wB.md.builderOverlays = { [TN] = true } -- 記號在、帳本沒有
    local cB, aB = unbuild(Pl, 2707, 46, 48, TN)
    check(cB == "dismantleSkipped" and aB.code == "NOT_OURS" and hung(wB) == TN, "記號在、覆蓋帳本沒有：NOT_OURS、不拿掉")
    HARNESS_ROLL = "max"
    here.dropped = {}
    local cA = unbuild(Pl, 2708, 45, 48, TN)
    local back = true
    for ft, n in pairs(pay) do if here.dropped[ft] ~= n then back = false end end
    check(cA == "dismantled" and hung(wA) == "" and wA.md.builderOverlays == nil and Overlays.get(A, TN, "N") == nil and back
        and A.objects[1] == wA and #A.objects == 1, "拆：拿掉牆上那張與記號、清帳本、照帳本退（最多全部），牆還在")
    local cA2, aA2 = unbuild(Pl, 2709, 45, 48, TN)
    check(cA2 == "dismantleSkipped" and aA2.code == "GONE", "拆過的再拆一次：GONE、不再退")

    -- 牆移出世界（打壞、大錘、本工具拆牆）：圖跟著消失，那條邊的帳本清掉，之後同名圖再出現也領不到
    local E = edgeSq(43, 48)
    local wE = wallOf(E, wallS)
    local junk = wallOf(E, sprite("wo_junk_01_0", 2709, {})) -- 同格別的物件（沒有附加圖）
    local fl = { getSquare = function() return E end, getAttachedAnimSprite = function() return nil end,
        hasModData = function() return false end, getSprite = function() return nil end }
    function E:getFloor() return fl end
    give(Pl, pay)
    local okE = build(Pl, 2710, TN, { 43, 48, 0 })
    E:transmitRemoveItemFromSquare(junk)
    local kept = Overlays.get(E, TN, "N") ~= nil
    fire("OnObjectAboutToBeRemoved", fl)
    local keptF = Overlays.get(E, TN, "N") ~= nil
    E:transmitRemoveItemFromSquare(wE)
    local gone = Overlays.get(E, TN, "N") == nil
    local wE2 = wallOf(E, wallS) -- 同一條邊又有牆、掛著同名的圖（同名圖再出現）：沒有帳本
    wE2:addAttachedAnimSprite(trimN)
    wE2.md.builderOverlays = { [TN] = true }
    here.dropped = {}
    local cE, aE = unbuild(Pl, 2711, 43, 48, TN)
    check(okE and kept and keptF and gone and cE == "dismantleSkipped" and aE.code == "NOT_OURS" and next(here.dropped) == nil,
        "牆移除：那條邊的帳本清掉（別的物件移除不動）；同名的圖再掛回去也領不到退料（NOT_OURS）")
    local E2 = edgeSq(43, 49)
    local wE3 = wallOf(E2, wallS)
    give(Pl, pay)
    build(Pl, 2715, TN, { 43, 49, 0 })
    local realDrop = Overlays.drop
    Overlays.drop = function() end -- 植入違規：牆移除時不清帳本（只認地板的舊版）
    E2:transmitRemoveItemFromSquare(wE3)
    Overlays.drop = realDrop
    check(Overlays.get(E2, TN, "N") ~= nil, "植入違規：移除牆時不清帳本會留下殘帳（上一條測得到）")
    Overlays.forget(E2, TN, "N")

    local function attNew(...) -- 新牆要能掛附加圖
        local o = realNew(...)
        o.att = {}
        function o:getAttachedAnimSprite() return javaList(self.att) end
        function o:addAttachedAnimSprite(s) self.att[#self.att + 1] = { getParentSprite = function() return s end } end
        function o:RemoveAttachedAnim(i) table.remove(self.att, i + 1) end
        function o:transmitUpdatedSpriteToClients() end
        function o:transmitModData() end
        return o
    end
    -- 原地換牆（本工具蓋的牆換另一款）：舊牆上本工具掛的圖照帳本掛回新牆。格上先有地板：新牆照原版插在地板後面、舊牆前面，
    -- 舊牆移除時它已經不是宿主（帳本不清），Server.complete 照換之前記下的掛回新牆
    local H = edgeSq(45, 50, { WallN = true })
    local fH = wallOf(H, sprite("wo_floor_01_0", 2716, { flags = { "solidfloor" } }))
    local OW = wallOf(H, wallS, true)
    give(Pl, pay)
    local okH = build(Pl, 2712, TN, { 45, 50, 0 })
    local recH = Overlays.get(H, TN, "N")
    IsoThumpable.new = attNew
    local total = Cost.sum(Cost.forCells("wall", { wall2S }, 1))
    give(Pl, (Check.net(total.items, OW.mats)))
    local okR, cmdR, aR = build(Pl, 2713, "wo_wall_01_2", { 45, 50, 0 })
    IsoThumpable.new = realNew
    local NW
    for _, o in ipairs(H.objects) do if o.name == "wo_wall_01_2" then NW = o end end
    local recR = Overlays.get(H, TN, "N")
    check(okH and recH and okR and cmdR == "placed" and aR.replaced == true and NW and hung(NW) == TN
        and NW.md.builderOverlays and NW.md.builderOverlays[TN] == true and recR and samePay(recR)
        and #H.objects == 2 and H.objects[1] == fH and H.objects[2] == NW,
        "原地換牆：舊牆上本工具掛的圖照帳本掛回新牆（同一筆退料），舊牆移除")
    -- 不是宿主的物件身上掛著同名的圖：移除它不動真正宿主那一筆
    local J = edgeSq(46, 50)
    local hJ = wallOf(J, wall2S) -- getWall 先找到這件：宿主
    hJ:addAttachedAnimSprite(trimN)
    local oJ = wallOf(J, wallS)
    oJ:addAttachedAnimSprite(trimN)
    Overlays.put(J, TN, { ["Base.Plank"] = 1 }, "N")
    J:transmitRemoveItemFromSquare(oJ)
    check(Overlays.get(J, TN, "N") ~= nil and hung(hJ) == TN, "不是宿主的物件掛著同名的圖：移除它不動宿主那一筆帳本")
    Overlays.forget(J, TN, "N")
    -- 獨立放的帶 cutN 疊圖（那條邊沒牆時建的物件）不算牆：之後蓋了真的牆，宿主是真的牆；只有它時照舊建獨立物件
    local cutS = sprite("wo_cut_01_40", 2717, { flags = { "WallOverlay", "attachedN", "cutN" } })
    local K = edgeSq(47, 50)
    local cK = wallOf(K, cutS)
    local alone = Place.wallAt(K, "N")
    give(Pl, pay)
    local okK = build(Pl, 2716, TN, { 47, 50, 0 })
    local wK = wallOf(K, wallS)
    check(alone == nil and okK and hung(cK) == "" and #K.objects == 3 and Place.wallAt(K, "N") == wK,
        "獨立放的帶 cutN 疊圖不當宿主：只有它時照舊建獨立物件；後面有真的牆時宿主是真的牆")
    -- 只帶 cutN 的裝飾片（wallOverlay 種類，不佔那條邊）也不當宿主：之後那條邊還能蓋牆，會插在它前面
    local D2 = edgeSq(43, 47)
    wallOf(D2, sprite("wo_deco_01_0", 2718, { flags = { "cutN" } }))
    local decoOnly = Place.wallAt(D2, "N")
    local wD2 = wallOf(D2, wallS)
    check(decoOnly == nil and Place.wallAt(D2, "N") == wD2, "只帶 cutN 的裝飾片不當宿主；同一條邊有真的牆時宿主是牆")
    local Dw = edgeSq(43, 51)
    wallOf(Dw, sprite("wo_deco_01_1", 2725, { flags = { "cutN" } }))
    local dwWin = wallOf(Dw, sprite("wo_win_01_1", 2726, { flags = { "WindowN" }, keys = { WindowN = "" } }))
    function Dw:getWindow(dir) if dir == GridSquareEdgeFacingDirection.NORTH_SOUTH then return dwWin end return nil end
    check(Place.wallAt(Dw, "N") == nil, "getWall 找到的裝飾片被拒掉時不往窗、車庫門找（地圖只在 getWall 是 nil 時才查窗）")
    -- 牆角柱（SE）與只有窗的那條邊（地圖的退路：沒有牆時掛在同方向的窗上）
    local SEq = edgeSq(44, 47)
    local post = wallOf(SEq, sprite("wo_post_01_0", 2719, { flags = { "WallSE" } }))
    give(Pl, pay)
    local okSE = build(Pl, 2717, "wo_trim_01_20", { 44, 47, 0 })
    local Wq = edgeSq(45, 47)
    local win = wallOf(Wq, sprite("wo_win_01_0", 2720, { flags = { "WindowN" }, keys = { WindowN = "" } }))
    function Wq:getWindow(dir) if dir == GridSquareEdgeFacingDirection.NORTH_SOUTH then return win end return nil end
    give(Pl, pay)
    local okWin = build(Pl, 2718, TN, { 45, 47, 0 })
    check(okSE and hung(post) == "wo_trim_01_20" and Overlays.get(SEq, "wo_trim_01_20", "SE") ~= nil and #SEq.objects == 1
        and okWin and hung(win) == TN and Overlays.get(Wq, TN, "N") ~= nil and #Wq.objects == 1,
        "attachedSE 掛在牆角柱、帳本記在 SE；那條邊只有窗時掛在窗上（地圖同一條退路）")
    -- 換牆失敗（新牆加進格子後出錯）：收回新牆時那條邊的帳本整份清掉，舊牆上的圖還在，照記下的補回；不扣不退
    local H2 = edgeSq(46, 47, { WallN = true })
    wallOf(H2, sprite("wo_floor_01_1", 2721, { flags = { "solidfloor" } }))
    local OW2 = wallOf(H2, wallS, true)
    give(Pl, pay)
    build(Pl, 2719, TN, { 46, 47, 0 })
    give(Pl, (Check.net(Cost.sum(Cost.forCells("wall", { wall2S }, 1)).items, OW2.mats)))
    here.dropped = {}
    local held = #Pl.inv.items
    failAdd = true
    local okF2, _, aF2 = build(Pl, 2720, "wo_wall_01_2", { 46, 47, 0 })
    failAdd = false
    check(not okF2 and aF2.code == "INTERNAL" and hung(OW2) == TN and samePay(Overlays.get(H2, TN, "N")) and #H2.objects == 2
        and next(here.dropped) == nil and #Pl.inv.items == held, "換牆失敗：舊牆與牆上的圖都在、帳本照舊，背包不扣、地上不退")
    -- 殘帳（圖已被原版清除塗鴉這類拿掉、帳本還在）不跟著換牆：換好之後新牆上沒有、帳本清掉
    local H3 = edgeSq(47, 47, { WallN = true })
    wallOf(H3, sprite("wo_floor_01_2", 2722, { flags = { "solidfloor" } }))
    local OW3 = wallOf(H3, wallS, true)
    Overlays.put(H3, TN, pay, "N")
    give(Pl, (Check.net(Cost.sum(Cost.forCells("wall", { wall2S }, 1)).items, OW3.mats)))
    IsoThumpable.new = attNew
    local okR3 = build(Pl, 2721, "wo_wall_01_2", { 47, 47, 0 })
    IsoThumpable.new = realNew
    local NW3 = H3.objects[2]
    check(okR3 and NW3 and NW3.name == "wo_wall_01_2" and hung(NW3) == "" and Overlays.get(H3, TN, "N") == nil,
        "換牆時圖已經不在舊牆上的殘帳：不掛回新牆，帳本清掉")
    -- 牆換成沒有 cutN 的柵欄（同一組、能原地換）：那條邊沒有宿主，牆上的圖掛不回去：整份退、帳本清掉
    nowMs = nowMs + 60000 -- 避開收請求的頻率限制
    local fenceS = sprite("wo_fence_01_1", 2723, { flags = { "HoppableN" }, keys = { HoppableN = "" } })
    world({ wallS, wall2S, wallWS, trimN, trimW, trimSE, signS, gridT, fenceS })
    local H4 = edgeSq(46, 51, { WallN = true })
    wallOf(H4, sprite("wo_floor_01_3", 2724, { flags = { "solidfloor" } }))
    local OW4 = wallOf(H4, wallS, true)
    give(Pl, pay)
    local okT4 = build(Pl, 2722, TN, { 46, 51, 0 })
    give(Pl, (Check.net(Cost.sum(Cost.forCells("fence", { fenceS }, 1)).items, OW4.mats)))
    here.dropped = {}
    local okF4, cmdF4, aF4 = build(Pl, 2723, "wo_fence_01_1", { 46, 51, 0 })
    local whole4 = true
    for ft, n in pairs(pay) do if (here.dropped[ft] or 0) < n then whole4 = false end end
    check(okT4 and #H4.objects == 2 and H4.objects[1] ~= OW4 and okF4 and cmdF4 == "placed" and aF4.replaced == true and H4.objects[2]
        and H4.objects[2].name == "wo_fence_01_1" and Place.wallAt(H4, "N") == nil and Overlays.get(H4, TN, "N") == nil
        and whole4, "牆換成沒有 cutN 的柵欄：牆上的圖掛不回去，整份退（不擲 1..v）、那條邊的帳本清掉")
    -- 牆換成帶牆邊的高柵欄（原版 fencing_01_8 這組：TallHoppableN＋WallN，引擎因此設 cutN；目錄歸柵欄、和牆同一組）：
    -- 那條邊照樣有宿主，圖掛回新柵欄、帳本那一筆留著，地上只有換牆的差額，不退疊圖的料
    nowMs = nowMs + 60000 -- 避開收請求的頻率限制
    local tallS = sprite("wo_fence_01_8", 2727, { flags = { "TallHoppableN", "WallN", "cutN" },
        keys = { TallHoppableN = "", WallN = "" } })
    world({ wallS, wall2S, wallWS, trimN, trimW, trimSE, signS, gridT, fenceS, tallS })
    local H5 = edgeSq(47, 51, { WallN = true })
    wallOf(H5, sprite("wo_floor_01_4", 2728, { flags = { "solidfloor" } }))
    local OW5 = wallOf(H5, wallS, true)
    give(Pl, pay)
    local okT5 = build(Pl, 2724, TN, { 47, 51, 0 })
    local pay5, back5 = Check.net(Cost.sum(Cost.forCells("fence", { tallS }, 1)).items, OW5.mats)
    give(Pl, pay5)
    here.dropped = {}
    IsoThumpable.new = attNew
    local okF5, cmdF5, aF5 = build(Pl, 2725, "wo_fence_01_8", { 47, 51, 0 })
    IsoThumpable.new = realNew
    local NF5 = H5.objects[2]
    local onlyBack = true
    for ft, n in pairs(here.dropped) do if n ~= (back5[ft] or 0) then onlyBack = false end end
    for ft, n in pairs(back5) do if here.dropped[ft] ~= n then onlyBack = false end end
    check(Rules.classify(tallS) == "fence" and okT5 and okF5 and cmdF5 == "placed" and aF5.replaced == true and #H5.objects == 2
        and NF5 and NF5.name == "wo_fence_01_8" and Place.wallAt(H5, "N") == NF5 and hung(NF5) == TN
        and samePay(Overlays.get(H5, TN, "N")) and onlyBack,
        "牆換成帶牆邊的高柵欄（WallN＋TallHoppableN）：圖掛回新柵欄、帳本那一筆留著，地上只有換牆的差額、不退疊圖的料")

    -- 讀檔改掛：42.22.2-0.8.0 以前蓋的獨立牆上疊圖，帳本建好後的下一個 tick 掛到那條邊的牆；沒有牆的照舊
    local function legacy(sq, spr)
        local o = { class = "IsoThumpable", spr = spr, mats = { ["Base.Plank"] = "2", ["Base.Nails"] = "1" },
            md = { builderEntry = spr:getName() } }
        function o:getSprite() return self.spr end
        function o:getSquare() return sq end
        function o:hasModData() return true end
        function o:getModData() return self.md end
        function o:getBuildMaterials() return self.mats end
        function o:isFloor() return false end
        function o:hasBuildMaterials() return next(self.mats) ~= nil end
        function o:isCorner() return false end
        function o:isThumpable() return false end
        function o:isCanPassThrough() return true end
        function o:getThumpDmg() return 8 end
        function o:getContainerCount() return 0 end
        function o:getName() return self.name end
        function o:setName(v) self.name = v end
        function o:getAttachedAnimSprite() return nil end -- 引擎：沒有附加圖時是 null
        sq.objects[#sq.objects + 1] = o
        return o
    end
    local L = edgeSq(43, 50)
    local wL = wallOf(L, wallS)
    local old = legacy(L, trimN)
    local LN = edgeSq(44, 50)
    local alone = legacy(LN, trimN)
    fire("LoadGridsquare", L)
    fire("LoadGridsquare", LN)
    fire("OnTick")
    local r = Overlays.get(L, TN, "N")
    check(hung(wL) == TN and wL.md.builderOverlays[TN] == true and #L.objects == 1 and L.objects[1] == wL and r
        and r["Base.Plank"] == 2 and r["Base.Nails"] == 1 and LN.objects[1] == alone and Overlays.get(LN, TN, "N") == nil
        and old ~= nil, "讀檔改掛：舊的獨立牆上疊圖掛到北牆、拿掉舊物件，退料照 buildMaterials；那條邊沒有牆的照舊留著")
    local LR = edgeSq(45, 51)
    local wLR = wallOf(LR, wallS)
    local stuck = legacy(LR, trimN)
    local baseLR = LR.transmitRemoveItemFromSquare
    function LR:transmitRemoveItemFromSquare(o, safely)
        if o == stuck then return -1 end -- 移除失敗：物件還在
        return baseLR(self, o, safely)
    end
    fire("LoadGridsquare", LR)
    fire("OnTick")
    check(LR.objects[2] == stuck and hung(wLR) == "" and wLR.md.builderOverlays == nil and Overlays.get(LR, TN, "N") == nil,
        "讀檔改掛時舊物件移不掉：拿掉剛掛到牆上的那張、清記號與那條邊的帳本，舊物件留著")

    -- 安全屋照舊（時間往後撥：前面送了很多請求，避開收請求的頻率限制）
    nowMs = nowMs + 60000
    local SH = edgeSq(47, 48)
    SH.owner = "someone"
    local wSH = wallOf(SH, wallS)
    give(Pl, pay)
    local okSH, _, aSH = build(Pl, 2730, TN, { 47, 48, 0 })
    check(not okSH and aSH.code == "SAFEHOUSE" and hung(wSH) == "" and Overlays.get(SH, TN, "N") == nil,
        "別人的安全屋：SAFEHOUSE、不掛、不記帳本")
    instanceof = realInst
end)()

print("情境二十七：沙盒「殭屍打不壞」「殭屍敲不破門」「容器容量倍率」（2026-11-01 B 站許願）：建造與讀檔照目前的值，關掉還原，都關時不動")
;(function()
    nowMs = nowMs + 180000
    local Place = MinidoracatBuilder.Place
    local realInst = instanceof
    instanceof = function(o, cls) return type(o) == "table" and o.class == cls end
    local PROOF, DOOR = 2147483647, 1000000000
    for x = 90, 97 do for y = 90, 97 do square(x, y, 0) end end
    square(96, 96, 1) -- 讀檔情境的物件放二樓：不走一樓地板帳本那條
    -- 引擎的容器（世界容器 getCapacity 夾在 100，ItemContainer.java:168）
    local function box(t, cap)
        local c = { t = t, cap = cap }
        function c:getType() return self.t end
        function c:getCapacity() return math.min(self.cap, 100) end
        function c:setCapacity(v) self.cap = v end
        return c
    end
    -- 照引擎 addToWorld 建容器（IsoObject.java:5283-5302）：container 旗標 → 主容器、Freezer → 冷凍庫；
    -- 送給玩家時記下當下的容量（驗「先設容量才送」）
    local function engineSq(x, y)
        local sq = squares[x .. "," .. y .. ",0"]
        local orig = sq.AddSpecialObject
        function sq:AddSpecialObject(obj, index)
            orig(self, obj, index)
            local p = obj:getSprite():getProperties()
            obj.boxes = {}
            if p:has(F.container) then obj.boxes[1] = box(p:get("container"), tonumber(p:get("ContainerCapacity")) or 50) end
            if p:has("Freezer") then obj.boxes[#obj.boxes + 1] = box("freezer", tonumber(p:get("FreezerCapacity")) or 15) end
            function obj:transmitCompleteItemToClients()
                self.sentCaps = {}
                for i, b in ipairs(self.boxes) do self.sentCaps[i] = b.cap end
            end
        end
        return sq
    end
    local wallS = sprite("zp_wall_01_0", 2701, { flags = { "WallN" }, keys = { WallN = "" } })
    local sinkS = sprite("zp_sink_01_0", 2702, { flags = { "solid" } })
    local fenceS = sprite("zp_fence_01_0", 2703, { flags = { "HoppableW" } })
    local crateS = sprite("zp_crate_01_0", 2704, { flags = { "container", "solid" },
        keys = { container = "crate", ContainerCapacity = "50" } })
    local fridgeS = sprite("zp_fridge_01_0", 2705, { flags = { "container", "solid" },
        keys = { container = "fridge", ContainerCapacity = "40", Freezer = "", FreezerCapacity = "15" } })
    local bigS = sprite("zp_big_01_0", 2706, { flags = { "container", "solid" }, keys = { container = "crate", ContainerCapacity = "120" } })
    local doorS = sprite("zp_door_01_0", 2707)
    local floorS = sprite("zp_floor_01_0", 2708, { flags = { "solidfloor" } })
    local lampS = sprite("zp_lamp_01_0", 2709, { flags = { "solid" } })
    local dimS = sprite("zp_lamp_01_1", 2710)
    local otherS = sprite("zp_other_01_0", 2711, { flags = { "solid" }, keys = { container = "crate" } }) -- 有容器但沒有 container 旗標
    -- 0.1.0／0.1.1 當成牆蓋、現在不列的牆角片（WallSE＋collideN：BLOCKS_EDGE）：還原不能靠重新分類
    local edgeS = sprite("zp_edge_01_0", 2712, { flags = { "WallSE", "collideN" } })
    local frameS = sprite("zp_frame_01_0", 2713, { flags = { "DoorWallW" }, keys = { DoorWallW = "" } })
    local postS = sprite("zp_post_01_0", 2714, { flags = { "WallSE" } })
    world({ wallS, sinkS, fenceS, crateS, fridgeS, bigS, doorS, floorS, lampS, dimS, otherS, edgeS, frameS, postS })
    check(Rules.classify(wallS) == "wall" and Rules.classify(fenceS) == "fence" and Rules.classify(floorS) == "floor"
        and Rules.classify(edgeS) == nil and Rules.classify(frameS) == "doorFrame" and Rules.classify(postS) == "post",
        "測試圖塊的種類：牆、柵欄、地板、門框、柱子，牆角片不列")
    local P = player({ id = 2701, x = 93.5, y = 93.5, here = squares["93,93,0"], cheat = true })
    local function put(n, name, x, y)
        local ok = build(P, n, name, { x, y, 0 })
        return ok and squares[x .. "," .. y .. ",0"].objects[1] or nil
    end

    -- 建造：打開時牆、會擋路的家具、柵欄都不給打，thumpDmg 調到最大（爬行殭屍照樣打低柵欄）；耐久照舊
    sb.ZombieProof = true
    local W, S, Fe = put(1, "zp_wall_01_0", 91, 91), put(2, "zp_sink_01_0", 92, 95), put(3, "zp_fence_01_0", 95, 91)
    -- 記號＝PROOF 減「原本可打 1＋原本 thumpDmg 是 1 再加 2」：牆、柵欄 PROOF−1，家具 PROOF−3
    check(W and W.set.setIsThumpable == false and W.set.setThumpDmg == PROOF - 1 and W.set.setMaxHealth == 450
        and S and S.set.setIsThumpable == false and S.set.setThumpDmg == PROOF - 3 and S.set.setMaxHealth == 50
        and Fe and Fe.set.setIsThumpable == false and Fe.set.setThumpDmg == PROOF - 1 and Fe.set.setMaxHealth == 300,
        "殭屍打不壞（建造）：牆、會擋路的家具、柵欄不給打、thumpDmg 最大（記下原本的樣子）；耐久照舊（450、50、300）")
    sb.ZombieProof = nil
    local W2, S2 = put(4, "zp_wall_01_0", 92, 91), put(5, "zp_sink_01_0", 94, 95)
    check(W2 and W2.set.setIsThumpable == true and W2.set.setThumpDmg == nil
        and S2 and S2.set.setIsThumpable == true and S2.set.setThumpDmg == 1,
        "關掉後新蓋的照原版：牆打得壞、thumpDmg 不改；家具一隻殭屍就能打（thumpDmg 1）")

    -- 門：記號一律寫；「殭屍敲不破門」打開時耐久 10 億，關著不改
    local doors = {}
    IsoDoor = { new = function(_, sq, name, north)
        local d = { class = "IsoDoor", name = name, north = north, md = {}, hp = 500, max = 500 }
        function d:getModData() return self.md end
        function d:hasModData() return next(self.md) ~= nil end
        function d:setHealth(v) self.hp = v end
        function d:getHealth() return self.hp end
        function d:getMaxHealth() return self.max end
        function d:setExplored() end
        function d:transmitCompleteItemToClients() self.sentHp = self.hp end
        function d:getContainerCount() return 0 end
        function d:getSquare() return sq end
        function d:getSprite() return spriteMap[name] end
        doors[#doors + 1] = d
        return d
    end }
    sb.ZombieProofDoors = true
    Place.build("door", { { sq = squares["96,91,0"], spr = doorS, cost = {} } }, {})
    sb.ZombieProofDoors = nil
    Place.build("door", { { sq = squares["96,92,0"], spr = doorS, cost = {} } }, {})
    local D1, D2 = doors[1], doors[2]
    check(D1 and D1.md.builderEntry == "zp_door_01_0" and D1.sentHp == DOOR
        and D2 and D2.md.builderEntry == "zp_door_01_0" and D2.sentHp == 500,
        "門（建造）：一律寫記號；打開時送出前耐久就是 10 億，關著照圖塊的 500")

    -- 容器（建造）：容量 × 倍率（四捨五入），冷凍庫照 FreezerCapacity；本來就 ≥100 的不動；送給玩家之前就設好
    sb.ContainerCapacityMultiplier = 2
    engineSq(91, 94)
    engineSq(91, 95)
    local C = put(6, "zp_crate_01_0", 91, 94)
    local B = put(7, "zp_big_01_0", 91, 95)
    sb.ContainerCapacityMultiplier = 1.5
    engineSq(93, 95)
    local R = put(8, "zp_fridge_01_0", 93, 95)
    check(C and C.sentCaps and C.sentCaps[1] == 100 and C.boxes[1].cap == 100
        and B and B.sentCaps and B.sentCaps[1] == 120
        and R and R.sentCaps and R.sentCaps[1] == 60 and R.sentCaps[2] == 23,
        "容器（建造）：倍率 2 時 50 → 100、送出前就設好；120 的不動；倍率 1.5 時冰箱 40 → 60、冷凍庫 15 → 23（四捨五入）")
    sb.ContainerCapacityMultiplier = nil

    -- 讀檔（Place.migrate，兩端都跑）
    local up = squares["96,96,1"]
    local function loaded(class, spr, o)
        o = o or {}
        local x = { class = class, spr = spr, md = {}, thump = o.thump, dmg = o.dmg or 8, moved = o.moved, hp = o.hp,
            max = o.max or 500, boxes = o.boxes or {} }
        if o.entry ~= false then x.md.builderEntry = spr:getName() end
        function x:getSprite() return self.spr end
        function x:hasModData() return next(self.md) ~= nil end
        function x:getModData() return self.md end
        function x:getSquare() return up end
        function x:getThumpDmg() return self.dmg end
        function x:setThumpDmg(v) self.dmg = v end
        function x:isThumpable() return self.barricaded == true or self.thump == true end -- 引擎：有木板一律 true
        function x:isBarricaded() return self.barricaded == true end
        function x:setIsThumpable(v) self.thump = v end
        function x:setCorner(v) self.corner = v end
        function x:setCanPassThrough(v) self.pass = v end
        function x:isMovedThumpable() return self.moved == true end
        function x:setMovedThumpable(v) self.moved = v end
        function x:getHealth() return self.hp end
        function x:setHealth(v) self.hp = v end
        function x:getMaxHealth() return self.max end
        function x:getContainerCount() return #self.boxes end
        function x:getContainerByIndex(i) return self.boxes[i + 1] end
        function x:isFloor() return false end
        function x:isCorner() return false end
        function x:getName() return self.name end
        function x:setName(v) self.name = v end
        return x
    end
    local function load(list) for _, o in ipairs(list) do Place.migrate(o) end end
    local lw = loaded("IsoThumpable", wallS, { thump = true })
    local odd = loaded("IsoThumpable", wallS, { thump = false }) -- 舊版或別處改過的：選項都關時不重算
    local ls = loaded("IsoThumpable", sinkS, { thump = true, dmg = 1 })
    local lf = loaded("IsoThumpable", floorS, { thump = false })
    local nw = loaded("IsoThumpable", wallS, { thump = true, entry = false }) -- 不是本 MOD 蓋的
    local le = loaded("IsoThumpable", edgeS, { thump = true }) -- 現在分類是 nil
    local lamp = loaded("IsoLightSwitch", lampS, { moved = true })
    local dim = loaded("IsoLightSwitch", dimS, { moved = false })
    local stove = loaded("IsoStove", sinkS, { moved = true }) -- 家電：擋路的同燈（審查 1109 Claude）
    local all = { lw, odd, ls, lf, nw, le, lamp, dim, stove }
    load(all)
    check(lw.thump == true and lw.dmg == 8 and odd.thump == false and odd.dmg == 8 and ls.thump == true and ls.dmg == 1
        and le.thump == true and le.dmg == 8 and lamp.moved == true and dim.moved == false,
        "讀檔、選項都關：什麼都不動（沒改過的不照現在的規則重算）")
    sb.ZombieProof = true
    load(all)
    load(all) -- 重複跑結果一樣
    check(lw.thump == false and lw.dmg == PROOF - 1 and odd.thump == false and odd.dmg == PROOF and ls.thump == false
        and ls.dmg == PROOF - 3 and lf.thump == false and lf.dmg == PROOF and le.thump == false and le.dmg == PROOF - 1
        and nw.thump == true and nw.dmg == 8 and lamp.moved == false and dim.moved == false and stove.moved == false,
        "讀檔、打開：本 MOD 蓋的都不給打、記下原本的樣子（擋路的燈、家電不設 movedThumpable）；不是本 MOD 蓋的不動")
    sb.ZombieProof = nil
    load(all)
    check(lw.thump == true and lw.dmg == 8 and odd.thump == false and odd.dmg == 8 and ls.thump == true and ls.dmg == 1
        and lf.thump == false and lf.dmg == 8 and le.thump == true and le.dmg == 8 and nw.thump == true
        and lamp.moved == true and dim.moved == false and stove.moved == true,
        "讀檔、關掉：照記號還原成打開前的樣子（牆 thumpDmg 8、家具 1、地板與原本不打的照舊不打、現在分類不到的牆角片照樣打得壞、"
            .. "擋路的燈、家電打得壞、不擋路的燈照舊）")
    -- 同一條邊有木板時 isThumpable() 一律回 true（IsoThumpable.java:1677-1679），門框旁的門釘了木板也算：記號照種類算
    local lfr = loaded("IsoThumpable", frameS, { thump = false })
    local lpo = loaded("IsoThumpable", postS, { thump = true })
    lfr.barricaded, lpo.barricaded = true, true
    sb.ZombieProof = true
    load({ lfr, lpo })
    local barDmg = { lfr.dmg, lpo.dmg }
    sb.ZombieProof = nil
    load({ lfr, lpo })
    check(barDmg[1] == PROOF and barDmg[2] == PROOF - 1 and lfr.thump == false and lpo.thump == true,
        "讀檔、旁邊的門窗釘了木板：門框記成原本不打、柱子記成原本可打；關掉後門框照舊不打、柱子打得壞")

    local ld = loaded("IsoDoor", doorS, { hp = 500 })
    local hurt = loaded("IsoDoor", doorS, { hp = 300 })
    local nd = loaded("IsoDoor", doorS, { hp = 500, entry = false }) -- 有這個選項之前蓋的門：沒有記號
    sb.ZombieProofDoors = true
    load({ ld, hurt, nd })
    local onHp = { ld.hp, hurt.hp, nd.hp }
    sb.ZombieProofDoors = nil
    hurt.hp = 300
    load({ ld, hurt, nd })
    check(onHp[1] == DOOR and onHp[2] == DOOR and onHp[3] == 500 and ld.hp == 500 and hurt.hp == 300 and nd.hp == 500,
        "讀檔、門：打開時耐久 10 億、認不出來的門不動；關掉時夾回原本的上限，本來就不到上限的不動")

    local lc = loaded("IsoThumpable", crateS, { thump = true, boxes = { box("crate", 50) } })
    local lr = loaded("IsoThumpable", fridgeS, { thump = true, boxes = { box("fridge", 40), box("freezer", 15) } })
    local lb = loaded("IsoThumpable", bigS, { thump = true, boxes = { box("crate", 120) } })
    local lo = loaded("IsoThumpable", otherS, { thump = true, boxes = { box("crate", 30) } })
    local nc = loaded("IsoThumpable", crateS, { thump = true, boxes = { box("crate", 50) }, entry = false })
    local cs = { lc, lr, lb, lo, nc }
    sb.ContainerCapacityMultiplier = 2
    load(cs)
    local at2 = { lc.boxes[1].cap, lr.boxes[1].cap, lr.boxes[2].cap, lb.boxes[1].cap, lo.boxes[1].cap, nc.boxes[1].cap }
    sb.ContainerCapacityMultiplier = 10
    load(cs)
    local at10 = lc.boxes[1].cap
    sb.ContainerCapacityMultiplier = nil
    load(cs)
    check(at2[1] == 100 and at2[2] == 80 and at2[3] == 30 and at2[4] == 120 and at2[5] == 30 and at2[6] == 50
        and at10 == 100 and lc.boxes[1].cap == 50 and lr.boxes[1].cap == 40 and lr.boxes[2].cap == 15,
        "讀檔、容器：倍率 2 照算（≥100、認不出來的、不是本 MOD 蓋的不動），倍率 10 最多 100，改回 1 還原")
    -- 二進位存不準的倍率：50×1.15＝57.5、冷凍庫 15×4.1＝61.5（滑桿一格 0.1 也會碰到），直接乘會少一格（57、61）
    sb.ContainerCapacityMultiplier = 1.15
    load({ lc })
    local at115 = lc.boxes[1].cap
    sb.ContainerCapacityMultiplier = 4.1
    load({ lr })
    local at41 = { lr.boxes[1].cap, lr.boxes[2].cap }
    sb.ContainerCapacityMultiplier = nil
    load({ lc, lr })
    check(at115 == 58 and at41[1] == 100 and at41[2] == 62 and lc.boxes[1].cap == 50 and lr.boxes[2].cap == 15,
        "讀檔、容器：.5 邊界照四捨五入進位（50×1.15＝58、冷凍庫 15×4.1＝62）")

    -- 插入位置（42.22.2 原版 fenceOrWall／door OnCreate，buildRecipeCode.lua:625-658）：格上已有地板與家具時，牆插在
    -- 最後一個地板後面（和原版蓋的順序一樣），門插在同方向門框後面
    local function obj(spr) return { getProperties = function() return spr:getProperties() end,
        getType = function() return spr:getType() end, getSprite = function() return spr end,
        getTextureName = function() return spr:getName() end } end
    local chairS = sprite("zp_chair_01_0", 2715, { keys = { IsMoveAble = "" } })
    local frameTyped = sprite("zp_frame_01_1", 2716, { type = T.doorFrW, flags = { "DoorWallW" }, keys = { DoorWallW = "" } })
    local orderSq = squares["97,97,0"]
    local F0, CH = obj(floorS), obj(chairS)
    orderSq.objects = { F0, CH }
    Place.build("wall", { { sq = orderSq, spr = wallS, cost = { items = {} } } }, {})
    local wallAt = orderSq.objects[2] and orderSq.objects[2]:getSprite():getName()
    local FR = obj(frameTyped)
    local doorSq = squares["97,96,0"]
    doorSq.objects = { obj(floorS), FR, obj(chairS) }
    Place.build("door", { { sq = doorSq, spr = doorS, cost = {} } }, {})
    local doorAt = doorSq.objects[3] and doorSq.objects[3].name
    check(wallAt == "zp_wall_01_0" and orderSq.objects[1] == F0 and orderSq.objects[3] == CH
        and doorSq.objects[2] == FR and doorAt == "zp_door_01_0",
        "牆插在地板後、家具前；門插在同方向門框後（照 42.22 原版的順序）")
    -- 換地板（沒有地毯）：新地板插回舊地板的位置，不加在最後。加在最後的話地板排到家具後面，之後蓋的柵欄照「最後一個
    -- 地板後面」也跟著排到家具後面（審查 1110 Claude）
    local swapSq = squares["96,97,0"]
    local oldF, CH2, swapped = obj(floorS), obj(chairS), {}
    swapSq.objects = { oldF, CH2 }
    Place.build("floor", { { sq = swapSq, spr = floorS, cost = { items = {} } } }, swapped)
    local newF = swapped[1]
    local floorFirst = newF ~= nil and newF ~= oldF and swapSq.objects[1] == newF and swapSq.objects[2] == CH2
        and #swapSq.objects == 2
    if newF then newF.getProperties = function() return floorS:getProperties() end end
    Place.build("fence", { { sq = swapSq, spr = fenceS, cost = { items = {} } } }, {})
    check(floorFirst and swapSq.objects[2] and swapSq.objects[2].name == "zp_fence_01_0" and swapSq.objects[3] == CH2,
        "換地板：新地板插回舊地板的位置（家具前面）；之後蓋的柵欄插在它後面、家具前面")
    -- 舊地板前面還有會被拆的東西（草疊圖）：拆掉它以後地板的位置往前一格
    local grassS = sprite("zp_grass_01_0", 2717, { flags = { "canBeRemoved" } })
    local grassSq = squares["95,97,0"]
    local CH3, swapped2 = obj(chairS), {}
    grassSq.objects = { obj(grassS), obj(floorS), CH3 }
    Place.build("floor", { { sq = grassSq, spr = floorS, cost = { items = {} } } }, swapped2)
    check(swapped2[1] ~= nil and grassSq.objects[1] == swapped2[1] and grassSq.objects[2] == CH3 and #grassSq.objects == 2,
        "換地板：舊地板前面的草一起拆掉時，新地板照樣排在家具前面（審查 1110 第 2 輪 Claude）")
    instanceof = realInst
    IsoDoor = nil
end)()

print("情境二十八：疊放、放不下的原因碼、原地替換、配對面（2026-11-01 設計稿 FYiNFUQ-Qcq6）")
;(function()
    nowMs = nowMs + 180000
    local Place, Dismantle = MinidoracatBuilder.Place, MinidoracatBuilder.Dismantle
    local realInst, realProps = instanceof, ISMoveableSpriteProps
    instanceof = function(o, cls) return type(o) == "table" and o.class == cls end
    -- 圖塊：flags＝旗標（Entry.edges、格子屬性），keys＝字串鍵（Rules 有些照字串查）
    local function sp(name, id, flags, keys, o)
        o = o or {}
        o.flags, o.keys = flags, keys or {}
        for _, f in ipairs(flags or {}) do if o.keys[f] == nil and f:match("^[A-Z]") then o.keys[f] = "" end end
        return sprite(name, id, o)
    end
    local wallN = sp("rp_wall_01_1", 2801, { "WallN" })
    local wallW = sp("rp_wall_01_0", 2802, { "WallW" })
    local frameN = sp("rp_frame_01_1", 2803, { "WindowN" })
    local wallN2 = sp("rp_wall_02_1", 2804, { "WallN" })
    local floorA = sp("rp_floor_01_0", 2805, { "solidfloor" })
    local floorB = sp("rp_floor_01_1", 2806, { "solidfloor" })
    local lampA = sp("rp_lamp_01_0", 2807, {}, {}, { type = T.lightswitch })
    local lampB = sp("rp_lamp_01_1", 2808, {}, {}, { type = T.lightswitch })
    local boxA = sp("rp_box_01_0", 2809, { "solid" }, { container = "crate" })
    local boxB = sp("rp_box_01_1", 2810, { "solid" }, { container = "crate" })
    local crate = sp("rp_crate_01_0", 2811, { "solid" }, { IsMoveAble = "", IsStackable = "", IsTable = "", Surface = "32" })
    local chair = sp("rp_chair_01_0", 2812, { "solid" }, { IsMoveAble = "" })
    local stA = sp("rp_stairs_01_0", 2813, {}, {}, { type = T.stairsBW })
    local stB = sp("rp_stairs_02_0", 2814, {}, {}, { type = T.stairsBW })
    local ovA = sp("rp_ovl_01_0", 2815, {}, { TileOverlay = "" })
    local ovB = sp("rp_ovl_01_1", 2816, {}, { TileOverlay = "" })
    local gridS = sp("rp_box_01_2", 2817, { "solid" }, { container = "crate" })
    gridS.grid = {}
    -- 配對面（d＝5）：原版的幾種排法（Main 離線讀 tiledef）
    local pf = {}
    local function edgeSet(prefix, kindFlags, list)
        for num, side in pairs(list) do
            local name = prefix .. "_" .. num
            pf[name] = sp(name, 2900 + #spriteOrder + num, { kindFlags[side] })
        end
    end
    edgeSet("pf_house_01", { N = "WallN", W = "WallW" }, { [0] = "W", [1] = "N", [4] = "W", [5] = "N" })
    edgeSet("pf_wood_01", { N = "WallN", W = "WallW" }, { [4] = "W", [5] = "W", [6] = "N", [7] = "N" })
    edgeSet("pf_fence_01", { N = "HoppableN", W = "HoppableW" },
        { [1] = "N", [2] = "W", [8] = "N", [9] = "N", [10] = "W", [11] = "W" })
    edgeSet("pf_mall_01", { N = "WallN", W = "WallW" }, { [56] = "N", [57] = "W" })
    edgeSet("pf_lone_01", { N = "WallN", W = "WallW" }, { [0] = "W" })
    pf.pf_house_01_2 = sp("pf_house_01_2", 2990, { "WallNW" })
    pf.pf_door_01_0 = sp("pf_door_01_0", 2991, { "doorN" })
    pf.pf_door_01_1 = sp("pf_door_01_1", 2992, { "doorW" })
    pf.pf_door_01_2 = sp("pf_door_01_2", 2993, { "doorN" }) -- 開門的圖（+2）
    local shelfA = sp("rp_shelf_01_0", 2818, {}, { container = "shelves" }) -- 不實心的容器：同格放得下兩個
    local shelfB = sp("rp_shelf_01_1", 2819, {}, { container = "shelves" })
    -- 植入違規用：會佔住位置（實心／擋放置）的燈與覆蓋，不換名單拿掉時才會被當成可換
    local lampS1 = sp("rp_lamp_02_0", 2820, { "solid" }, {}, { type = T.lightswitch })
    local lampS2 = sp("rp_lamp_02_1", 2821, { "solid" }, {}, { type = T.lightswitch })
    local ovX1 = sp("rp_ovl_02_0", 2822, {}, { TileOverlay = "", BlocksPlacement = "" })
    local ovX2 = sp("rp_ovl_02_1", 2823, {}, { TileOverlay = "", BlocksPlacement = "" })
    local all = { wallN, wallW, frameN, wallN2, floorA, floorB, lampA, lampB, boxA, boxB, crate, chair, stA, stB, ovA, ovB, gridS,
        shelfA, shelfB, lampS1, lampS2, ovX1, ovX2 }
    for _, s in pairs(pf) do all[#all + 1] = s end
    world(all)

    -- 配對面
    local function pair(name)
        local e = Entry.resolve(name)
        local s = e and Entry.face(e, 5)
        return s and s:getName() or nil
    end
    check(pair("pf_house_01_0") == "pf_house_01_1" and pair("pf_house_01_1") == "pf_house_01_0"
        and pair("pf_house_01_4") == "pf_house_01_5" and pair("pf_mall_01_56") == "pf_mall_01_57"
        and pair("pf_mall_01_57") == "pf_mall_01_56", "配對面：編號 xor 1 那張只佔另一條邊（偶數西、奇數北；56N 57W 也成立）")
    check(pair("pf_wood_01_4") == "pf_wood_01_6" and pair("pf_wood_01_5") == "pf_wood_01_7" and pair("pf_wood_01_7") == "pf_wood_01_5"
        and pair("pf_fence_01_8") == "pf_fence_01_10" and pair("pf_fence_01_11") == "pf_fence_01_9",
        "配對面：兩張一組（4W 5W 6N 7N、8N 9N 10W 11W）改看 ±2")
    check(pair("pf_fence_01_1") == "pf_fence_01_2" and pair("pf_fence_01_2") == "pf_fence_01_1",
        "配對面：xor 1 那張不存在時就近找（1N 2W）")
    check(pair("pf_house_01_2") == nil and pair("pf_door_01_0") == nil and pair("pf_lone_01_0") == nil
        and Entry.face(Entry.resolve("pf_house_01_0"), 6) == nil,
        "配對面：佔兩條邊的角片、門、找不到另一邊的都回 nil；d＝6 不存在")
    local wallEntry = Entry.resolve("pf_house_01_0")
    check(Entry.face(wallEntry, 5) == Entry.face(wallEntry, 5) and Entry.face(wallEntry, 0) == pf.pf_house_01_0,
        "配對面：同一項目查兩次結果一樣（快取），d＝0 照舊是自己")

    -- 格子與物件
    for x = 100, 107 do for y = 100, 107 do square(x, y, 0) end end
    local P = player({ id = 2801, x = 103.5, y = 103.5, here = squares["103,103,0"] })
    local PV = { preview = true }
    local function at(x, y, o) -- 重建一格（格子屬性照 o.flags，引擎是各物件屬性的聯集）
        squares[x .. "," .. y .. ",0"] = nil
        return square(x, y, 0, o)
    end
    local function obj(sq, spr, o)
        o = o or {}
        local x = { class = o.class or "IsoThumpable", mats = o.mats or { ["Base.Plank"] = "4" }, md = {}, yoff = o.yoff or 0,
            floor = spr:getProperties():has(F.solidfloor) }
        if o.ours ~= false then x.md.builderEntry = spr:getName() end
        function x:getSprite() return spr end
        function x:getProperties() return spr:getProperties() end
        function x:getSquare() return sq end
        function x:hasModData() return true end
        function x:getModData() return self.md end
        function x:isDismantable() return true end
        function x:getBuildMaterials() return self.mats end
        function x:hasBuildMaterials() return next(self.mats) ~= nil end
        function x:isFloor() return self.floor end
        function x:getRenderYOffset() return self.yoff end
        function x:getSpriteGridObjectsIncludingSelf() return javaList(self.cands or { self }) end
        function x:isConnectedSpriteGridObject(y) return y == self or (self.cands ~= nil) end
        function x:isObjectNoContainerOrEmpty() return not self.full end
        function x:hasFluid() return false end
        function x:isBarricaded() return self.barricaded == true end
        function x:isStairsObject() return false end
        sq.objects[#sq.objects + 1] = x
        return x
    end

    -- 疊放：照原版搬家具疊箱子那一支（ISMoveableSpriteProps.lua:1772-1777）
    ISMoveableSpriteProps = { new = function(spr)
        local p = spr:getProperties()
        local s = { isStackable = p:has("IsStackable"), isTable = p:has("IsTable"), surface = tonumber(p:get("Surface")) or 0,
            yOffsetCursor = 0 }
        function s:getTotalTableHeight(sq)
            for i = #sq.objects, 1, -1 do
                local o = sq.objects[i]
                local op = o:getSprite():getProperties()
                if op:has("IsTable") and tonumber(op:get("Surface")) then return o:getRenderYOffset() + tonumber(op:get("Surface")) end
            end
            return 0
        end
        function s:canPlaceMoveableInternal(_, sq)
            if not sq:has("IsTable") then return not sq:has("solid") end -- 原版 isFreeTile：格上有實心的東西就放不下
            if self.isStackable and self.isTable and self.surface and not sq:has("IsTableTop") and not sq:has("IsHigh") then
                local h = self:getTotalTableHeight(sq)
                self.yOffsetCursor = h
                return h + self.surface <= 96
            end
            return false
        end
        function s:isSquareAtTopOfStairs() return false end
        return s
    end }
    local s1 = at(101, 101)
    local ok1, y1 = Place.check("furniture", crate, s1, P)
    local s2 = at(101, 102, { flags = { IsTable = true, solid = true } })
    obj(s2, crate, { yoff = 0 })
    local ok2, y2 = Place.check("furniture", crate, s2, P)
    obj(s2, crate, { yoff = 32 })
    local ok3, y3 = Place.check("furniture", crate, s2, P)
    obj(s2, crate, { yoff = 64 })
    local ok4, c4 = Place.check("furniture", crate, s2, P)
    check(ok1 == true and y1 == 0 and ok2 == true and y2 == 32 and ok3 == true and y3 == 64 and ok4 == false and c4 == "STACK_FULL",
        "疊放：同一張可疊的箱子不被「同一格同一張圖」擋，疊在第 2、3 層（墊高 32、64）；總高超過 96 回 STACK_FULL")
    local s3 = at(101, 103, { flags = { solid = true } })
    obj(s3, chair)
    local ok5, c5 = Place.check("furniture", chair, s3, P)
    local cc5 = Check.item(P, "rp_chair_01_0", 0, { 101, 103, 0 }, PV)
    check(ok5 == false and c5 == "SAME_TILE" and cc5 == "SAME_TILE",
        "不可疊的同一張：SAME_TILE（Check.item 照傳碼，不再只有 BLOCKED）")
    local s4 = at(101, 104)
    s4.moving = { {} }
    local ok6, c6 = Place.check("furniture", crate, s4, P)
    local s5 = at(101, 105)
    function s5:isVehicleIntersecting() return true end
    local ok7, c7 = Place.check("furniture", crate, s5, P)
    local s5b = at(101, 106)
    s5b.moving = { {} }
    local ok7b = Place.check("floor", floorA, s5b, P) -- 不擋路的照舊不看格上有沒有人
    check(ok6 == false and c6 == "OCCUPIED" and ok7 == false and c7 == "VEHICLE" and ok7b == true,
        "擋路的東西那格有人：OCCUPIED；車子壓著：VEHICLE；地板不看人")
    -- 疊在可疊、卻不是桌面的箱子上（UMCTP 畫好高度的半箱 industry_ddd_02_32）：說下面那件撐不住，不叫玩家清空。
    -- 只在原版疊放那一支走得到時說（自己是可疊的桌類、有地板）；半箱自己疊上去、沒有地板都照舊沒有原因碼
    local half = sp("rp_half_01_0", 2824, { "solid" }, { IsMoveAble = "", IsStackable = "" })
    local s6 = at(101, 107, { flags = { IsStackable = true, solid = true }, floor = {} })
    obj(s6, half)
    local ok8, c8 = Place.check("furniture", crate, s6, P)
    local _, c8b = Place.check("furniture", half, s6, P)
    local s6b = at(101, 108, { flags = { IsStackable = true, solid = true } })
    obj(s6b, half)
    local _, c8c = Place.check("furniture", crate, s6b, P)
    local s7 = at(101, 100, { flags = { solid = true }, floor = {} })
    obj(s7, chair)
    local ok9, c9 = Place.check("furniture", crate, s7, P)
    check(ok8 == false and c8 == "NOT_SURFACE" and ok9 == false and c9 == nil,
        "疊放：下面那件可疊卻不是桌面（UMCTP 的半箱）回 NOT_SURFACE；下面不是可疊的箱子照舊沒有原因碼（BLOCKED）")
    check(c8b == nil and c8c == nil, "疊放：半箱自己（不是桌類）疊上去、或那格沒有地板，不說 NOT_SURFACE")
    ISMoveableSpriteProps = realProps

    -- 原地替換
    local function wallSq(x, y, flags) return at(x, y, { flags = flags or { WallN = true } }) end
    local r1 = wallSq(103, 101)
    local oldW = obj(r1, wallN, { mats = { ["Base.Plank"] = "10", ["Base.Nails"] = "1" } })
    local cF, _, iF = Check.item(P, "rp_frame_01_1", 0, { 103, 101, 0 }, PV)
    local cS, _, iS = Check.item(P, "rp_frame_01_1", 0, { 103, 101, 0 })
    local tp = iF.total and iF.total.items or {}
    check(cF == nil and iF.replace and iF.replace.obj == oldW and iF.replace.kind == "wall" and #iF.replace.plan.remove == 1
        and iF.replace.had == oldW.mats and iF.replace.estimated == false
        and iF.back["Base.Plank"] == 10 - tp["Base.Plank"] and iF.pay["Base.Nails"] == tp["Base.Nails"] - 1,
        "牆換成窗框（預覽）：舊的那件不算擋、info.replace 帶舊物件與退料表，pay／back 是差額")
    check(cS == nil and iS.replace and iS.replace.had == oldW.mats and iS.replace.estimated == nil,
        "牆換成窗框（伺服器）：退料照 Place.refundOf")
    local r2 = at(103, 102, { flags = { WindowN = true } })
    local oldFr = obj(r2, frameN)
    local cW, _, iW = Check.item(P, "rp_wall_02_1", 0, { 103, 102, 0 }, PV)
    check(cW == nil and iW.replace and iW.replace.obj == oldFr, "窗框換回牆也成立（同一組 edge）")
    oldFr.barricaded = true
    check(Check.item(P, "rp_wall_02_1", 0, { 103, 102, 0 }, PV) == "ATTACHED", "舊的窗框釘著木板：ATTACHED（不換）")
    local r3 = wallSq(103, 103)
    obj(r3, wallN)
    check(Dismantle.replaceable(r3, "wall", wallN) == nil and Check.item(P, "rp_wall_01_1", 0, { 103, 103, 0 }, PV) == "SAME_TILE",
        "同一張圖不算替換：SAME_TILE")
    local cD, _, iD = Check.item(P, "rp_wall_01_0", 0, { 103, 103, 0 }, PV)
    check(cD == nil and iD.replace == nil, "不同邊（北牆上蓋西牆）：不是替換，照一般蓋")
    local r4 = wallSq(103, 104)
    obj(r4, wallN, { ours = false })
    check(Dismantle.replaceable(r4, "wall", wallN2) == nil and Check.item(P, "rp_wall_02_1", 0, { 103, 104, 0 }, PV) == "BLOCKED",
        "不是本 MOD 蓋的：不換，那條邊照舊被擋（BLOCKED）")
    local r5 = wallSq(103, 105)
    local estW = obj(r5, wallN, { mats = {} })
    local _, _, iE = Check.item(P, "rp_wall_02_1", 0, { 103, 105, 0 }, PV)
    check(iE.replace and iE.replace.obj == estW and iE.replace.estimated == true
        and iE.replace.had["Base.Plank"] == Cost.of("wall", wallN, 1).items["Base.Plank"],
        "預覽拿不到退料表（一樓地板記在伺服器）：照現在的價估，標成估計")
    local r6 = at(104, 101, { flags = { solid = true }, solid = true }) -- isSolid() 與 has(solid) 都成立（舊的那件是實心的）
    local oldB = obj(r6, boxA)
    local cB, _, iB = Check.item(P, "rp_box_01_1", 0, { 104, 101, 0 }, PV)
    oldB.full = true
    check(cB == nil and iB.replace and iB.replace.obj == oldB and Check.item(P, "rp_box_01_1", 0, { 104, 101, 0 }, PV) == "NOT_EMPTY",
        "容器換容器：舊的實心不算擋；舊的裡面有東西時 NOT_EMPTY")
    oldB.full = nil
    oldB.cands = { oldB, obj(at(104, 106), boxA) }
    check(Dismantle.replaceable(r6, "container", boxB) == nil, "多格（拆的時候會動到兩片）：不換")
    check(Dismantle.swappable("container", boxA, "container", gridS) == false
        and Dismantle.swappable("container", gridS, "container", boxB) == false, "新的或舊的是多格圖：不換")
    local r9 = at(102, 105)
    local shelf = obj(r9, shelfA)
    local cSh, _, iSh = Check.item(P, "rp_shelf_01_1", 0, { 102, 105, 0 }, PV)
    check(Dismantle.replaceable(r9, "container", shelfB) == nil and Dismantle.swappable("container", shelfA, "container", shelfB) == false
        and Dismantle.replaceableOld("container", shelf, Dismantle.plan(shelf, "container")) == false
        and cSh == nil and iSh.replace == nil,
        "同種類但舊的不佔位置（不實心、同格放得下）：照舊共存，不當成替換，「換成...」也不列")
    local r7 = at(104, 102)
    local oldF = obj(r7, floorA)
    local cFl, _, iFl = Check.item(P, "rp_floor_01_1", 0, { 104, 102, 0 }, PV)
    check(cFl == nil and iFl.replace and iFl.replace.obj == oldF, "地板換地板：替換")
    local r8 = at(104, 103)
    local lamp = obj(r8, lampS1, { class = "IsoLightSwitch" })
    check(Dismantle.kindOf(lamp) == "light" and Dismantle.replaceable(r8, "light", lampS2) == nil, "燈（會佔位置的也一樣）：不換")
    Dismantle.NO_REPLACE.light = nil -- 植入違規：燈拿掉不換的名單，要抓得到
    local planted = Dismantle.replaceable(r8, "light", lampS2)
    Dismantle.NO_REPLACE.light = true
    check(planted == lamp, "植入違規：燈不在不換名單時會被當成替換（上一條測得到）")
    check(Dismantle.swappable("stairs", stA, "stairs", stB) == false and Dismantle.swappable("overlay", ovA, "overlay", ovB) == false
        and Dismantle.swappable("floorOverlay", ovA, "floorOverlay", ovB) == false
        and Dismantle.swappable("wall", wallN, "fence", sp("rp_fence_01_1", 2818, { "HoppableN" })) == true
        and Dismantle.swappable("wall", wallN, "container", boxB) == false,
        "樓梯、疊圖、地面覆蓋不換；牆和柵欄同一組；不同組不換")
    Dismantle.NO_REPLACE.floorOverlay = nil
    local plantedOv = Dismantle.swappable("floorOverlay", ovX1, "floorOverlay", ovX2)
    Dismantle.NO_REPLACE.floorOverlay = true
    check(plantedOv == true, "植入違規：地面覆蓋不在不換名單時會被當成可換（上一條測得到）")

    -- 差額
    local pay, back = Check.net({ ["Base.Plank"] = 4, ["Base.Nails"] = 6 }, { ["Base.Plank"] = "6", ["Base.Nails"] = "2", ["Base.Screws"] = "1" })
    local pay2, back2 = Check.net({ ["Base.Plank"] = 4 }, { ["Base.Plank"] = "4" })
    check(pay["Base.Nails"] == 4 and pay["Base.Plank"] == nil and back["Base.Plank"] == 2 and back["Base.Screws"] == 1
        and back["Base.Nails"] == nil and next(pay2) == nil and next(back2) == nil,
        "Check.net：新的多的要補、舊的多的會退（退料表的值是字串）；材料相同兩邊都空")

    -- 訊息：原因各一行（件數多的在前）、拆除總結的三種寫法（getText 替身把參數接在鍵後面）
    local Messages = MinidoracatBuilder.Messages
    local realGetText = getText
    getText = function(k, ...)
        local a = { ... }
        return #a == 0 and k or k .. "(" .. table.concat(a, ",") .. ")"
    end
    local rows = Messages.reasons({ NOT_EMPTY = 1, ATTACHED = 3, GONE = 1 }, true)
    local brow = Messages.reasons({ OVER_MAX = { n = 2, extra = { max = 32 } }, SAME_TILE = 5 })
    check(#rows == 3 and rows[1] == "IGUI_MBLD_ShortCount(IGUI_MBLD_UnbuildShort_ATTACHED,3)"
        and rows[2]:find("GONE", 1, true) and rows[3]:find("NOT_EMPTY", 1, true)
        and brow[1] == "IGUI_MBLD_ReasonCount(5,IGUI_MBLD_Refuse_SAME_TILE)"
        and brow[2] == "IGUI_MBLD_ReasonCount(2,IGUI_MBLD_Refuse_OVER_MAX(32))"
        and Messages.unbuildShort("SCRAP") == "IGUI_MBLD_UnbuildShort_SCRAP"
        and Messages.unbuildShort("WHAT") == "IGUI_MBLD_UnbuildShort_Other(WHAT)",
        "原因各一行：件數多的在前、同數照碼名；建造帶格數與附帶欄位（OVER_MAX 的上限）；不認得的碼附上碼")
    local t1, h1 = Messages.unbuildSummary({ done = 1, total = 1, skipped = {}, refund = { ["Base.Plank"] = 3 } }, "牆")
    local t0 = Messages.unbuildSummary({ done = 0, total = 1, skipped = { NOT_EMPTY = 1 }, refund = {} }, "箱子")
    local tm, hm = Messages.unbuildSummary({ done = 5, total = 7, skipped = { ATTACHED = 2 }, refund = { ["Base.Plank"] = 4 } })
    local ts, hs = Messages.unbuildSummary({ done = 2, total = 7, skipped = {}, refund = {}, stopped = true })
    check(t1 == "IGUI_MBLD_UnbuildSummary_One(牆,IGUI_MBLD_ItemCount(Base.Plank,3))" and h1 == "IGUI_MBLD_UnbuildDone"
        and t0 == "IGUI_MBLD_UnbuildRefuse_NOT_EMPTY"
        and tm:find("IGUI_MBLD_UnbuildSummary_Many(5,", 1, true) and tm:find("IGUI_MBLD_UnbuildSummary_Kept(2,", 1, true)
        and hm == "IGUI_MBLD_UnbuildDone"
        and ts == "IGUI_MBLD_UnbuildSummary_Stopped(2,7,IGUI_MBLD_RefundNothing)" and hs == "IGUI_MBLD_UnbuildStopped",
        "拆除總結：一件寫名稱與退料、一件拆不了寫原因、多件寫留著幾件與原因、停下寫 N／M 與沒有退料")
    getText = realGetText
    instanceof = realInst
end)()

print("情境三十二：建造請求每格帶朝向、拆除清單（跳過不中斷、整批停）、原地替換的補差與回復（2026-11-01 契約 C4–C6）")
;(function()
    nowMs = nowMs + 180000
    local Client, Floors = MinidoracatBuilder.Client, MinidoracatBuilder.Floors
    local realInst, realIsServer, realIsClient, realSend = instanceof, isServer, isClient, sendClientCommand
    local realQ, realLu, realToast = ISTimedActionQueue, luautils, MinidoracatBuilder.Messages.toast
    instanceof = function(o, cls) return type(o) == "table" and o.class == cls end
    local function sp(name, id, flags, keys)
        keys = keys or {}
        for _, f in ipairs(flags) do if keys[f] == nil and f:match("^[A-Z]") then keys[f] = "" end end
        return sprite(name, id, { flags = flags, keys = keys })
    end
    local wallW, wallN = sp("cs_wall_01_0", 3201, { "WallW" }), sp("cs_wall_01_1", 3202, { "WallN" })
    local wallN2, lone = sp("cs_wall_02_1", 3203, { "WallN" }), sp("cs_lone_01_0", 3204, { "WallW" })
    local boxS = sp("cs_box_01_0", 3205, { "solid" }, { container = "crate" })
    local floorA, floorB = sp("cs_floor_01_0", 3206, { "solidfloor" }), sp("cs_floor_01_1", 3207, { "solidfloor" })
    world({ wallW, wallN, wallN2, lone, boxS, floorA, floorB })
    -- 格子：移除時照引擎先觸發 OnObjectAboutToBeRemoved；退料掉在這裡時記件數
    local function at(x, y, o)
        local sq = square(x, y, 0, o)
        sq.dropped = {}
        local orig = sq.transmitRemoveItemFromSquare
        function sq:transmitRemoveItemFromSquare(obj, safely)
            fire("OnObjectAboutToBeRemoved", obj)
            return orig(self, obj, safely)
        end
        function sq:AddWorldInventoryItem(ft) self.dropped[ft] = (self.dropped[ft] or 0) + 1 end
        return sq
    end
    for x = 110, 117 do for y = 110, 117 do at(x, y) end end
    local function S(x, y) return squares[x .. "," .. y .. ",0"] end
    local function obj(sq, spr, mats, o)
        o = o or {}
        local x = { class = "IsoThumpable", mats = mats or { ["Base.Plank"] = "4" }, md = { builderEntry = spr:getName() },
            floor = spr:getProperties():has(F.solidfloor), full = o.full }
        function x:getSprite() return spr end
        function x:getProperties() return spr:getProperties() end
        function x:getSquare() return sq end
        function x:hasModData() return true end
        function x:getModData() return self.md end
        function x:isDismantable() return true end
        function x:getBuildMaterials() return self.mats end
        function x:hasBuildMaterials() return next(self.mats) ~= nil end
        function x:isFloor() return self.floor end
        function x:getRenderYOffset() return 0 end
        function x:getTextureName() return spr:getName() end
        function x:getSpriteGridObjectsIncludingSelf() return javaList({ self }) end
        function x:isConnectedSpriteGridObject(y) return y == self end
        function x:isObjectNoContainerOrEmpty() return not self.full end
        function x:hasFluid() return false end
        function x:isBarricaded() return false end
        function x:isStairsObject() return false end
        function x:getHealth() return self.hp or 450 end
        function x:getMaxHealth() return 450 end
        sq.objects[#sq.objects + 1] = x
        return x
    end
    local function has(sq, o) for _, v in ipairs(sq.objects) do if v == o then return true end end return false end
    local function named(sq, name) for _, v in ipairs(sq.objects) do if v.name == name then return v end end return nil end
    local here = S(113, 113)
    local P = player({ id = 3201, x = 113.5, y = 113.5, here = here })
    P.inv:add(item("Base.Hammer", { HAMMER = true }))
    local nonce = 3200
    local function last() return sent[#sent] and sent[#sent].cmd, sent[#sent] and sent[#sent].args or {} end

    -- C4：建造請求每格帶朝向（步幅 4），沒有頂層 d
    sb.MaxCellsPerDrag = 3
    local function intent(c, e)
        nonce = nonce + 1
        sent = {}
        Server.intent(P, { n = nonce, e = e or "cs_wall_01_0", c = c, v = Entry.digest() })
        return last()
    end
    local c1 = intent({ 111, 111, 0, 0, 112, 111, 0, 5 })
    local it = Server.intents[3201]
    check(c1 == "accepted" and it and it.c[1][4] == 0 and it.c[2][4] == 5 and it.d == nil,
        "建造請求：每格 { x, y, z, d }（d＝5 配對面也收），請求不再有頂層朝向")
    local _, a6 = intent({ 111, 111, 0, 6 })
    local _, a3 = intent({ 111, 111, 0, 112, 111, 0 })
    local _, a1 = intent({ 111, 111, 0 })
    local _, aMax = intent({ 111, 111, 0, 0, 112, 111, 0, 0, 113, 111, 0, 0, 114, 111, 0, 0 })
    local _, aF = intent({ 111, 111, 0, 0, 112, 111, 0, 5 }, "cs_lone_01_0")
    check(a6.code == "BAD_REQUEST" and a3.code == "BAD_REQUEST" and a1.code == "BAD_REQUEST" and aMax.code == "BAD_REQUEST"
        and aF.code == "BAD_FACE" and aF.x == 112 and Server.intents[3201].n == nonce - 5,
        "壞格式：d＝6、步幅 3（第 4 欄是下一格的 x）、少 d、超過 MaxCellsPerDrag 都 BAD_REQUEST；第 2 格沒有配對面 BAD_FACE（帶那格座標）；被拒的不取代舊請求")
    nowMs = nowMs + 6000 -- 限流
    local got
    isClient = function() return true end
    sendClientCommand = function(_, _, cmd, args) got = { cmd = cmd, args = args } end
    ISTimedActionQueue = { clear = function() end, add = function() end, isPlayerDoingAction = function() return false end }
    local nb, why = Client.build(P, "cs_lone_01_0", { { 111, 111, 0, 0 }, { 112, 111, 0, 5 } })
    local ng = Client.build(P, "cs_wall_01_0", { { 111, 111, 0, 0 }, { 112, 111, 0, 5 } })
    isClient = realIsClient
    check(nb == nil and why == "BAD_FACE" and ng and got.cmd == "intent" and got.args.d == nil and #got.args.c == 8
        and got.args.c[4] == 0 and got.args.c[8] == 5 and Client.pending.cells[2][4] == 5,
        "Client.build：某格的朝向不存在當場回 BAD_FACE；送出的請求每格攤平 x, y, z, d")
    Client.pending = nil

    -- C6：拆除清單
    local function unbuild(t)
        nonce = nonce + 1
        sent = {}
        Server.dismantleIntent(P, { n = nonce, t = t })
        local c, a = last()
        return c, a, nonce
    end
    local bad = {}
    bad[1] = select(2, unbuild({ 112, 112, 0, "a", 113, 112, 0, "b", 114, 112, 0, "c", 115, 112, 0, "d" })).code
    bad[2] = select(2, unbuild({ 112, 112, 0, 7 })).code
    bad[3] = select(2, unbuild({ 112.5, 112, 0, "a" })).code
    bad[4] = select(2, unbuild("112,112,0,a")).code
    bad[5] = select(2, unbuild({})).code
    bad[6] = select(2, unbuild({ 112, 112, 0 })).code
    bad[7] = select(2, unbuild({ 112, 112, 0, "cs_wall_01_1\nUNBUILD user=admin" })).code
    check(bad[1] == "BAD_REQUEST" and bad[2] == "BAD_REQUEST" and bad[3] == "BAD_REQUEST" and bad[4] == "BAD_REQUEST"
        and bad[5] == "BAD_REQUEST" and bad[6] == "BAD_REQUEST" and bad[7] == "BAD_REQUEST" and Server.unbuilds[3201] == nil,
        "拆除清單：超過 MaxCellsPerDrag、名稱不是字串、座標不是整數、不是表、空的、少名稱、名稱帶控制字元（會寫進 log）都 BAD_REQUEST，不留請求")
    nowMs = nowMs + 6000
    HARNESS_ROLL = "max"
    local W1 = obj(S(112, 112), wallN, { ["Base.Plank"] = "4" })
    local B = obj(S(113, 112), boxS, { ["Base.Plank"] = "2" }, { full = true })
    local W2 = obj(S(114, 112), wallN, { ["Base.Nails"] = "3" })
    local cA, _, n1 = unbuild({ 112, 112, 0, "cs_wall_01_1", 113, 112, 0, "cs_box_01_0", 114, 112, 0, "cs_wall_01_1" })
    local u = Server.unbuilds[3201]
    check(cA == "dismantleAccepted" and u and #u.list == 3 and u.list[2][4] == "cs_box_01_0" and u.left == 3,
        "拆除清單收下：照順序存成 { x, y, z, 名稱 }")
    local dur = Server.dismantleDuration(P, n1, 1)
    sent = {}
    local r1 = Server.dismantle(P, n1, 1)
    local k1, b1 = last()
    local r2 = Server.dismantle(P, n1, 2)
    local k2, b2 = last()
    local r3 = Server.dismantle(P, n1, 3)
    local k3, b3 = last()
    check(dur == Entry.duration("wall", P) and r1 == true and k1 == "dismantled" and b1.i == 1 and b1.refund["Base.Plank"] == 4
        and r2 == true and k2 == "dismantleSkipped" and b2.i == 2 and b2.code == "NOT_EMPTY" and b2.x == 113 and has(S(113, 112), B)
        and r3 == true and k3 == "dismantled" and b3.i == 3 and b3.refund["Base.Nails"] == 3 and not has(S(114, 112), W2)
        and not has(S(112, 112), W1) and here.dropped["Base.Plank"] == 4 and here.dropped["Base.Nails"] == 3
        and Server.unbuilds[3201] == nil,
        "中間那件裡面有東西：送 dismantleSkipped、回 true（佇列照走），下一件照拆；拆好的帶退料；輪完請求清掉")
    sent = {}
    check(Server.dismantle(P, n1, 2) == false and #sent == 0 and Server.dismantleDuration(P, n1, 3) == 1,
        "輪過的那件再送一次：沒有請求（MP 不回覆）、施工時間 1")
    nowMs = nowMs + 6000
    local W3 = obj(S(112, 113), wallN)
    local W4 = obj(S(114, 113), wallN)
    local _, _, n2 = unbuild({ 112, 113, 0, "cs_wall_01_1", 114, 113, 0, "cs_wall_01_1" })
    sb.Enabled = false
    sent = {}
    local rOff = Server.dismantle(P, n2, 1)
    local kOff, bOff = last()
    sb.Enabled = nil
    sent = {}
    check(rOff == false and kOff == "dismantleRefused" and bOff.code == "OFF" and bOff.i == 1 and Server.unbuilds[3201] == nil
        and Server.dismantle(P, n2, 2) == false and #sent == 0 and has(S(112, 113), W3) and has(S(114, 113), W4),
        "總開關關掉：dismantleRefused、回 false（整批停）、請求清掉，後面那件也不拆")
    S(112, 113).objects, S(114, 113).objects = {}, {}
    -- 期限照一區最多件數：過了單件的 180 秒（中間夾著伺服器看不到的原版拆解）還在期限內，照樣拆
    nowMs = nowMs + 6000
    local W5 = obj(S(111, 112), wallN)
    local _, _, n5 = unbuild({ 111, 112, 0, "cs_wall_01_1" })
    nowMs = nowMs + 180000 * 2
    check(Server.dismantle(P, n5, 1) == true and not has(S(111, 112), W5),
        "一區拆除的期限照件數給：超過單件的 180 秒、還在期限內照樣拆")
    -- 移除出錯（INTERNAL）：整批停，後面那件不拆、請求清掉
    nowMs = nowMs + 6000
    local XS = S(111, 113)
    local baseX = XS.transmitRemoveItemFromSquare
    local W6 = obj(XS, wallN)
    function XS:transmitRemoveItemFromSquare(o, safely)
        if o == W6 then return -1 end -- 引擎沒移掉（錯誤被 Kahlua 吞掉）
        return baseX(self, o, safely)
    end
    local W7 = obj(S(111, 114), wallN)
    local _, _, n6 = unbuild({ 111, 113, 0, "cs_wall_01_1", 111, 114, 0, "cs_wall_01_1" })
    sent = {}
    local r6 = Server.dismantle(P, n6, 1)
    local k6, b6 = last()
    check(r6 == false and k6 == "dismantleRefused" and b6.code == "INTERNAL" and Server.unbuilds[3201] == nil
        and Server.dismantle(P, n6, 2) == false and has(XS, W6) and has(S(111, 114), W7),
        "兩件的清單第一件移除出錯（INTERNAL）：整批停、請求清掉，第二件不拆")
    XS.transmitRemoveItemFromSquare = baseX
    XS.objects, S(111, 114).objects = {}, {}

    -- C5：原地替換（牆換牆：舊的 木板 10、釘子 1）
    nowMs = nowMs + 6000
    local total = Cost.sum(Cost.forCells("wall", { wallN2 }, 1))
    local had = { ["Base.Plank"] = "10", ["Base.Nails"] = "1" }
    local pay, back = Check.net(total.items, had)
    -- 格子照引擎重算的屬性帶 WallN（那條邊被舊牆佔著：不帶 replacing 的 Place.check 放不下＝替換）
    at(115, 113, { flags = { WallN = true } })
    at(116, 113, { flags = { WallN = true } })
    local OW = obj(S(115, 113), wallN, { ["Base.Plank"] = "10", ["Base.Nails"] = "1" })
    OW.hp = 225 -- 被打掉一半
    nonce = nonce + 1
    local okP, _, aP = build(P, nonce, "cs_wall_02_1", { 115, 113, 0 })
    check(not okP and aP.code == "NO_MATERIAL" and next(pay) ~= nil and aP.need["Base.Plank"] == pay["Base.Plank"]
        and aP.need["Base.Nails"] == pay["Base.Nails"] and has(S(115, 113), OW),
        "替換缺料：只要差額（pay），不是新的整份；舊的留著")
    give(P, pay)
    xpLog = {}
    here.dropped = {}
    nonce = nonce + 1
    local okR, cmdR, aR = build(P, nonce, "cs_wall_02_1", { 115, 113, 0 })
    local left = 0
    for ft in pairs(pay) do left = left + P.inv:count(ft) end
    local backOk = next(back) ~= nil
    for ft, v in pairs(back) do if here.dropped[ft] ~= v then backOk = false end end
    local c0 = Cost.forCells("wall", { wallN2 }, 1)[1]
    local want = Cost.xp({ { items = pay, perkOf = c0.perkOf, chanceOf = c0.chanceOf, fee = {}, uniform = c0.uniform } }, P)
    local gotXp, full = {}, Cost.xp({ c0 }, P)
    for _, x in ipairs(xpLog) do gotXp[x.perk] = (gotXp[x.perk] or 0) + x.n end
    local xpOk = true
    for perk, v in pairs(want) do if gotXp["perk:" .. perk] ~= v then xpOk = false end end
    for perk in pairs(gotXp) do if not want[perk:gsub("^perk:", "")] then xpOk = false end end
    check(okR and cmdR == "placed" and aR.replaced == true and not has(S(115, 113), OW) and named(S(115, 113), "cs_wall_02_1")
        and left == 0 and backOk,
        "替換：先蓋新的再拆舊的、回 placed { replaced }；只扣差額、多的照拆除退（最多全部）掉在腳下")
    check(xpOk and (full.Woodwork or 0) >= (want.Woodwork or 0), "替換的經驗只照補的料（pay）給")
    local NW = named(S(115, 113), "cs_wall_02_1")
    check(NW and NW.set.setName == "cs_wall_02_1", "本工具蓋的 IsoThumpable 一律有名稱（圖名）：爬窗框時引擎拿名稱比對，null 會 NPE")
    check(NW and NW.set.setMaxHealth and NW.set.setHealth == math.floor(NW.set.setMaxHealth / 2),
        "替換照舊件剩下的耐久比例（舊的剩一半，新的也一半）：換一款不能順便修好")
    -- 移除舊的失敗：收回新的、舊的留著、不扣不退
    local FS = S(116, 113)
    local base = FS.transmitRemoveItemFromSquare
    local OX
    function FS:transmitRemoveItemFromSquare(o, safely)
        if o == OX then return -1 end -- 引擎沒移掉（錯誤被 Kahlua 吞掉）
        return base(self, o, safely)
    end
    OX = obj(FS, wallN, { ["Base.Plank"] = "10", ["Base.Nails"] = "1" })
    give(P, pay)
    xpLog = {}
    here.dropped = {}
    nonce = nonce + 1
    local okX, _, aX = build(P, nonce, "cs_wall_02_1", { 116, 113, 0 })
    local kept = true
    for ft, v in pairs(pay) do if P.inv:count(ft) ~= v then kept = false end end
    check(not okX and aX.code == "INTERNAL" and has(FS, OX) and #FS.objects == 1 and kept and next(here.dropped) == nil
        and #xpLog == 0, "替換時舊的移不掉：INTERNAL、新的收回、舊的留著、不扣料不退料不給經驗")
    P.inv = inventory()
    P.inv:add(item("Base.Hammer", { HAMMER = true }))
    -- 地板：蓋新的時舊片已被 Place.clearFloor 拆掉，之後出錯 → 收回新的、照原圖與原退料蓋回舊的（地板帳本照舊）
    local FF = S(115, 115)
    local add, failOnce = FF.AddSpecialObject, true
    function FF:AddSpecialObject(o, idx)
        add(self, o, idx)
        if failOnce then
            failOnce = false
            error("injected failure after AddSpecialObject")
        end
    end
    local OF = obj(FF, floorA, {})
    Floors.put(OF, { ["Base.Plank"] = 3 })
    local fTotal = Cost.sum(Cost.forCells("floor", { floorB }, 1))
    local fPay = Check.net(fTotal.items, { ["Base.Plank"] = 3 })
    give(P, fPay)
    nonce = nonce + 1
    local okF, _, aF2 = build(P, nonce, "cs_floor_01_1", { 115, 115, 0 })
    local back1 = named(FF, "cs_floor_01_0")
    local fe = back1 and Floors.get(back1)
    check(not okF and aF2.code == "INTERNAL" and not has(FF, OF) and back1 ~= nil and named(FF, "cs_floor_01_1") == nil
        and fe ~= nil and fe.i["Base.Plank"] == 3,
        "替換地板時出錯：舊片已被拆掉的照原圖、原退料蓋回，新的收回，地板帳本照舊")
    -- 蓋回也出錯：收回蓋到一半的，舊的退料表整份退給玩家（材料不跟著舊的一起不見），不扣新的料
    local FG = S(115, 114)
    local addG = FG.AddSpecialObject
    function FG:AddSpecialObject(o, idx)
        addG(self, o, idx)
        error("injected failure after AddSpecialObject")
    end
    local OG = obj(FG, floorA, {})
    Floors.put(OG, { ["Base.Plank"] = 3 })
    P.inv = inventory()
    P.inv:add(item("Base.Hammer", { HAMMER = true }))
    give(P, fPay)
    here.dropped = {}
    nonce = nonce + 1
    local okG, _, aG = build(P, nonce, "cs_floor_01_1", { 115, 114, 0 })
    local paidG = true
    for ft, v in pairs(fPay) do if P.inv:count(ft) ~= v then paidG = false end end
    check(not okG and aG.code == "INTERNAL" and #FG.objects == 0 and here.dropped["Base.Plank"] == 3 and paidG,
        "替換地板時新的、舊的都蓋不上：格子清空，舊的退料表整份退（木板 3），新的料不扣")
    -- 舊的一樓地板查不到帳本：照改版前蓋新地板（拆掉舊片、不退料、付全價），不卡 NOT_OURS
    local FH = S(114, 115)
    local OH = obj(FH, floorA, {})
    give(P, fTotal.items)
    nonce = nonce + 1
    local okH, cmdH, aH = build(P, nonce, "cs_floor_01_1", { 114, 115, 0 })
    check(okH and cmdH == "placed" and aH.replaced == nil and not has(FH, OH) and named(FH, "cs_floor_01_1") ~= nil,
        "舊的一樓地板帳本對不上：照一般蓋新地板（不算替換、不卡 NOT_OURS）")
    -- 換地板時舊地板上本工具掛的地面覆蓋：換好照帳本掛回去；掛不回去（這裡圖不存在）就整份退，帳本不留半筆
    local FJ = S(112, 112)
    FJ.objects = {}
    local OJ = obj(FJ, floorA, {})
    Floors.put(OJ, { ["Base.Plank"] = 3 })
    MinidoracatBuilder.Overlays.put(FJ, "cs_gone_01_0", { ["Base.Nails"] = 2 })
    give(P, fPay)
    here.dropped = {}
    nonce = nonce + 1
    local okJ, cmdJ, aJ = build(P, nonce, "cs_floor_01_1", { 112, 112, 0 })
    check(okJ and cmdJ == "placed" and aJ.replaced == true and here.dropped["Base.Nails"] == 2
        and MinidoracatBuilder.Overlays.get(FJ, "cs_gone_01_0") == nil,
        "換地板：舊地板上本工具的地面覆蓋掛不回去時整份退（釘子 2），帳本不留")
    -- 舊地板不是本工具的（不算替換）：上面本工具掛的地毯（MoveType=FloorRug 或名稱 floors_rugs）換好照帳本掛回新地板；
    -- 標線這類照舊跟著舊地板消失、不退（審查 1107 Codex：Constown 不能搬的地毯改歸地面覆蓋後，換地圖地板會連地毯和帳本一起
    -- 拆掉）。帳本有、圖已經不在的（鏟地、火燒）不掛回（審查 1107 Claude 第 2 輪）
    local rugS = sp("cs_rug_01_0", 3208, { "solidfloor", "FloorOverlay" }, { MoveType = "FloorRug" })
    local lineS = sp("cs_line_01_0", 3209, { "FloorOverlay" })
    local nameRugS = sp("floors_rugs_test_01_0", 3212, { "FloorOverlay" }) -- 名稱是原版地毯、沒有 MoveType
    local goneS = sp("cs_rug_01_1", 3213, { "solidfloor", "FloorOverlay" }, { MoveType = "FloorRug" }) -- 燒掉了，帳本還在
    world({ wallW, wallN, wallN2, lone, boxS, floorA, floorB, rugS, lineS, nameRugS, goneS })
    local FK = S(116, 116)
    function FK:getFloor() for _, v in ipairs(self.objects) do if v:isFloor() then return v end end return nil end
    local OK = obj(FK, floorA, {})
    OK.class, OK.md = "IsoObject", {}
    OK.att = { { getParentSprite = function() return rugS end }, { getParentSprite = function() return lineS end },
        { getParentSprite = function() return nameRugS end } }
    function OK:getAttachedAnimSprite() return javaList(self.att) end
    MinidoracatBuilder.Overlays.put(FK, "cs_rug_01_0", { ["Base.Nails"] = 1 })
    MinidoracatBuilder.Overlays.put(FK, "cs_line_01_0", { ["Base.Plank"] = 1 })
    MinidoracatBuilder.Overlays.put(FK, "floors_rugs_test_01_0", { ["Base.Nails"] = 1 })
    MinidoracatBuilder.Overlays.put(FK, "cs_rug_01_1", { ["Base.Nails"] = 1 })
    local realNew = IsoThumpable.new
    local function attNew(...) -- 新地板要能掛附加圖
        local o = realNew(...)
        o.att = {}
        function o:getAttachedAnimSprite() return javaList(self.att) end
        function o:addAttachedAnimSprite(s) self.att[#self.att + 1] = { getParentSprite = function() return s end } end
        function o:RemoveAttachedAnim(i) table.remove(self.att, i + 1) end
        function o:transmitUpdatedSpriteToClients() end
        function o:transmitModData() end
        return o
    end
    IsoThumpable.new = attNew
    local px, py = P.pos.x, P.pos.y
    P.pos.x, P.pos.y = 116.5, 116.5
    give(P, fTotal.items)
    here.dropped = {}
    nonce = nonce + 1
    local okK, cmdK, aK = build(P, nonce, "cs_floor_01_1", { 116, 116, 0 })
    IsoThumpable.new = realNew
    P.pos.x, P.pos.y = px, py
    local newK, hungK = named(FK, "cs_floor_01_1"), {}
    for _, a in ipairs(newK and newK.att or {}) do hungK[#hungK + 1] = a:getParentSprite():getName() end
    table.sort(hungK)
    local OV = MinidoracatBuilder.Overlays
    check(okK and cmdK == "placed" and aK.replaced == nil and not has(FK, OK)
        and table.concat(hungK, ",") == "cs_rug_01_0,floors_rugs_test_01_0" and OV.get(FK, "cs_rug_01_0") ~= nil
        and OV.get(FK, "floors_rugs_test_01_0") ~= nil and OV.get(FK, "cs_line_01_0") == nil and OV.get(FK, "cs_rug_01_1") == nil
        and next(here.dropped) == nil,
        "換地圖地板（不算替換）：本工具掛的地毯（MoveType 或名稱）照帳本掛回新地板；標線照舊跟著消失、不退；圖已不在的殘帳不掛回（"
        .. table.concat(hungK, ",") .. "）")
    -- 多格的地板每格各自記下、各自掛回（審查 1107 Codex 第 2 輪：只記第一格時，第二格的地毯和帳本跟著舊地板消失）
    local mf0, mf1 = sp("cs_mfloor_01_0", 3210, { "solidfloor" }), sp("cs_mfloor_01_1", 3211, { "solidfloor" })
    fakeGrid(2, 1, { { mf0, mf1 } })
    world({ wallW, wallN, wallN2, lone, boxS, floorA, floorB, rugS, lineS, mf0, mf1 })
    local M = { S(116, 117), S(117, 117) }
    for _, q in ipairs(M) do
        function q:getFloor() for _, v in ipairs(self.objects) do if v:isFloor() then return v end end return nil end
        local o = obj(q, floorA, {})
        o.class, o.md, o.att = "IsoObject", {}, { { getParentSprite = function() return rugS end } }
        function o:getAttachedAnimSprite() return javaList(self.att) end
        MinidoracatBuilder.Overlays.put(q, "cs_rug_01_0", { ["Base.Nails"] = 1 })
    end
    IsoThumpable.new = attNew
    P.pos.x, P.pos.y = 116.5, 117.5
    give(P, Cost.sum(Cost.forCells("floor", { mf0, mf1 }, 1)).items)
    nonce = nonce + 1
    local okM = build(P, nonce, "cs_mfloor_01_0", { 116, 117, 0 })
    IsoThumpable.new = realNew
    P.pos.x, P.pos.y = px, py
    local hungM = {}
    for j, name in ipairs({ "cs_mfloor_01_0", "cs_mfloor_01_1" }) do
        local f = named(M[j], name)
        hungM[j] = f and f.att[1] and f.att[1]:getParentSprite():getName() or "-"
        if not MinidoracatBuilder.Overlays.get(M[j], "cs_rug_01_0") then hungM[j] = hungM[j] .. "!ledger" end
    end
    check(okM and table.concat(hungM, ",") == "cs_rug_01_0,cs_rug_01_0",
        "兩格的地板蓋在地圖地板上：每格的地毯各自掛回、帳本都在（" .. table.concat(hungM, ",") .. "）")
    P.inv = inventory()
    P.inv:add(item("Base.Hammer", { HAMMER = true }))

    -- C6 客戶端：Client.dismantleMany（單機：伺服器當場回覆，動作 complete 直接進 Server.dismantle）
    nowMs = nowMs + 6000
    isServer = function() return false end
    local queued, busy, told = {}, false, {}
    ISTimedActionQueue = { clear = function() queued = {} end, add = function(a) queued[#queued + 1] = a end,
        isPlayerDoingAction = function() return busy end }
    luautils = { walkAdjWall = function() return true end, walkAdj = function() return true end }
    MinidoracatBuilder.Messages.toast = function(_, text, title) told[#told + 1] = { text = text, title = title } end
    local function item3(x, y, name, kind) return { x = x, y = y, z = 0, name = name, kind = kind or "wall", north = true,
        own = {}, route = "builder" } end
    local D1, DB, D2 = obj(S(112, 114), wallN), obj(S(113, 114), boxS, nil, { full = true }), obj(S(114, 114), wallN)
    local gone = { getSquare = function() return nil end }
    local summary
    local nm = Client.dismantleMany(P, { item3(112, 114, "cs_wall_01_1"),
        { x = 115, y = 114, z = 0, name = "cs_x_01_0", route = "scrap", obj = gone },
        item3(113, 114, "cs_box_01_0", "container"), item3(114, 114, "cs_wall_01_1") }, function(s) summary = s end)
    local b = Client.pendingUnbuild
    check(b and b.n == nm and #b.list == 3 and #queued == 3 and queued[1].i == 1 and queued[2].i == 2 and queued[3].i == 3
        and b.skipped.GONE == 1 and b.left == 3,
        "dismantleMany：本工具拆的照順序送一張清單、收下後照順序排（第 i 件）；原版拆解那件已經不在：當場記成跳過")
    for _, a in ipairs(queued) do a:complete() end
    check(summary and summary.done == 2 and summary.total == 4 and summary.skipped.NOT_EMPTY == 1 and summary.skipped.GONE == 1
        and summary.refund["Base.Plank"] == 8 and summary.stopped == false and Client.pendingUnbuild == nil
        and not has(S(112, 114), D1) and has(S(113, 114), DB) and not has(S(114, 114), D2),
        "dismantleMany：中間那件跳過後照拆下一件；全部輪完呼叫 onDone（拆好件數、跳過的原因×數、退料合計、沒停下）")
    -- 停下：做完第一件後佇列空了（玩家走開），過 IDLE 就算停下
    local E1, E2 = obj(S(112, 115), wallN), obj(S(113, 115), wallN)
    summary = nil
    Client.dismantleMany(P, { item3(112, 115, "cs_wall_01_1"), item3(113, 115, "cs_wall_01_1") }, function(s) summary = s end)
    queued[1]:complete()
    queued = {}
    Client.tickUnbuild()
    nowMs = nowMs + 2000
    Client.tickUnbuild()
    check(summary and summary.done == 1 and summary.total == 2 and summary.stopped == true and has(S(113, 115), E2)
        and not has(S(112, 115), E1), "dismantleMany：佇列空了還沒輪完＝停下（onDone 的 stopped、拆好幾件）")
    -- 整批被拒（總開關關掉）：清佇列、說原因、onDone 帶 refused
    nowMs = nowMs + 6000
    summary, told = nil, {}
    Client.dismantleMany(P, { item3(113, 115, "cs_wall_01_1") }, function(s) summary = s end)
    sb.Enabled = false
    queued[1]:complete()
    sb.Enabled = nil
    check(summary and summary.refused == "OFF" and summary.stopped == true and #queued == 0 and #told == 1
        and told[1].text == "IGUI_MBLD_UnbuildRefuse_OFF" and has(S(113, 115), E2),
        "dismantleMany：整批被拒（OFF）清掉佇列、通知原因、onDone 帶 refused")
    -- 拆到一半才被拒（第二件移除出錯 INTERNAL）：說原因之外照停下跳總結（拆了幾件、退了什麼）
    nowMs = nowMs + 6000
    told = {}
    local XS2 = S(111, 113)
    local baseX2 = XS2.transmitRemoveItemFromSquare
    local G1, G2 = obj(S(111, 114), wallN), obj(XS2, wallN)
    function XS2:transmitRemoveItemFromSquare(o, safely)
        if o == G2 then return -1 end
        return baseX2(self, o, safely)
    end
    Client.dismantleMany(P, { item3(111, 114, "cs_wall_01_1"), item3(111, 113, "cs_wall_01_1") })
    queued[1]:complete()
    if queued[2] then queued[2]:complete() end
    XS2.transmitRemoveItemFromSquare = baseX2
    check(#told == 2 and told[1].text == "IGUI_MBLD_UnbuildRefuse_INTERNAL" and told[2].title == "IGUI_MBLD_UnbuildStopped"
        and not has(S(111, 114), G1) and has(XS2, G2),
        "dismantleMany：拆到一半才被拒（INTERNAL）：先說原因，再照停下跳總結（不吞掉已拆的件數與退料）")
    XS2.objects = {}
    -- 右鍵拆一件（沒給 onDone）：Client 自己跳拆除完成的通知
    nowMs = nowMs + 6000
    told = {}
    Client.dismantle(P, E2, "wall", {})
    queued[1]:complete()
    check(#told == 1 and told[1].title == "IGUI_MBLD_UnbuildDone" and not has(S(113, 115), E2) and Client.pendingUnbuild == nil,
        "Client.dismantle＝一件的清單；沒給 onDone 時自己跳「拆除完成」")
    isServer, sendClientCommand, ISTimedActionQueue, luautils = realIsServer, realSend, realQ, realLu
    MinidoracatBuilder.Messages.toast = realToast
    instanceof = realInst
    sb.MaxCellsPerDrag = nil
end)()

print("情境三十三：建造作弊（2026-11-01 B 站：debug 開建造作弊還是要材料）：單機也認原版 ISBuildMenu.cheat，多人只認 isBuildCheat")
;(function()
    local Dismantle = MinidoracatBuilder.Dismantle
    local realS, realC, realMenu = isServer, isClient, ISBuildMenu
    -- 單機：原版 debug 選單「Build Cheat」與管理面板的按鈕只設 ISBuildMenu.cheat（ISGeneralCheats.lua:16、ISAdminPanelUI.lua:255）
    ISBuildMenu = { cheat = true }
    isServer, isClient = function() return false end, function() return false end
    -- 用情境三十二的目錄（cs_wall_01_1：木板 4、鐵鎚）
    local sq = square(120, 120, 0)
    local P = player({ id = 3301, x = 120.5, y = 121.5 })
    xpLog = {}
    check(Materials.summary(P).cheat == true, "單機開原版建造作弊：材料摘要算作弊（視窗、游標不標缺料）")
    check(build(P, 3301, "cs_wall_01_1", { 120, 120, 0 }) and #sq.objects == 1 and #xpLog == 0
        and next(sq.objects[1]:getBuildMaterials()) == nil, "單機開原版建造作弊：背包空的、沒鐵鎚也蓋，不給經驗、不寫退料表")
    local built = sq.objects[1]
    if built then built.isObjectNoContainerOrEmpty = function() return true end end
    check(built ~= nil and Dismantle.check(P, "wall", { remove = { built } }, true) == nil,
        "單機開原版建造作弊：拆除不查工具（背包沒鐵鎚）")
    -- 多人：客戶端的 Lua 全域不算，兩端都只認 isBuildCheat（伺服器上要 UseBuildCheat 能力才開得了）
    isServer = realS
    local sq2 = square(122, 120, 0)
    local M = player({ id = 3302, x = 122.5, y = 121.5 })
    local ok, _, a = build(M, 3302, "cs_wall_01_1", { 122, 120, 0 })
    check(not ok and a.code == "NO_MATERIAL" and #sq2.objects == 0, "多人伺服器：ISBuildMenu.cheat 不算，沒開 isBuildCheat 照樣要材料")
    isServer, isClient = function() return false end, function() return true end
    check(Materials.summary(M).cheat == false, "多人客戶端：預覽也只認 isBuildCheat（和伺服器一致）")
    isServer, isClient, ISBuildMenu = realS, realC, realMenu
end)()

print("情境三十四：建造作弊照原版不走過去、不限距離（使用者 2026-11-02 選）：MaxDistance、走得到、收請求的範圍都不查，客戶端不排走路")
;(function()
    local Dismantle = MinidoracatBuilder.Dismantle
    local realS, realC, realMenu, realQ, realLu = isServer, isClient, ISBuildMenu, ISTimedActionQueue, luautils
    -- 多人伺服器：只認 isBuildCheat（伺服器上要 UseBuildCheat 能力才開得了），原版的 Lua 全域不算
    isServer, isClient = function() return true end, function() return false end
    ISBuildMenu = { cheat = true }
    local wallSq, wayOff = square(140, 130, 0), square(300, 130, 0)
    local A = player({ id = 3401, x = 130.5, y = 130.5, cheat = true })
    local N = player({ id = 3402, x = 130.5, y = 130.5 })
    local ok, _, a = build(N, 3401, "cs_wall_01_1", { 140, 130, 0 })
    check(not ok and a.code == "TOO_FAR" and #wallSq.objects == 0, "沒開作弊：10 格外的牆 TOO_FAR（伺服器上 ISBuildMenu.cheat 不算）")
    ok, _, a = build(N, 3402, "cs_wall_01_1", { 300, 130, 0 })
    check(not ok and a.code == "TOO_FAR" and #wayOff.objects == 0, "沒開作弊：170 格外收請求時就 TOO_FAR（INTENT_REACH）")
    check(build(A, 3403, "cs_wall_01_1", { 140, 130, 0 }) and #wallSq.objects == 1, "建造作弊：10 格外照樣蓋（不查 MaxDistance）")
    check(build(A, 3404, "cs_wall_01_1", { 300, 130, 0 }) and #wayOff.objects == 1,
        "建造作弊：170 格外照收請求、照樣蓋（不查 INTENT_REACH）")
    local fl = square(152, 150, 0) -- 玩家站的那格不存在：從玩家走不到
    A.pos.x, A.pos.y, N.pos.x, N.pos.y = 150.5, 150.5, 150.5, 150.5
    ok, _, a = build(N, 3405, "cs_floor_01_1", { 152, 150, 0 })
    check(not ok and a.code == "UNREACHABLE" and #fl.objects == 0, "沒開作弊：2 格內但走不到的地板 UNREACHABLE")
    check(build(A, 3406, "cs_floor_01_1", { 152, 150, 0 }) and #fl.objects == 1, "建造作弊：走不到的地板照樣蓋（不查走得到）")
    -- 安全屋照查：作弊只略過距離與走得到（有 UseBuildCheat、沒有 CanGoInsideSafehouses 的人照樣擋）
    local owned = square(170, 150, 0, { owner = "someone" })
    ok, _, a = build(A, 3407, "cs_wall_01_1", { 170, 150, 0 })
    check(not ok and a.code == "SAFEHOUSE" and #owned.objects == 0, "建造作弊：20 格外別人的安全屋照樣 SAFEHOUSE")
    -- 拆：伺服器完成時的距離同樣不查，收拆除請求也不限範圍；安全屋照查
    local instReal = instanceof
    instanceof = function(o, cls) return type(o) == "table" and o.class == cls end
    local function ours(sq) -- 本工具蓋的牆（同情境三十二的 obj，作弊蓋的不退料）
        local spr = spriteMap["cs_wall_01_1"]
        local x = { class = "IsoThumpable", md = { builderEntry = spr:getName() } }
        function x:getSprite() return spr end
        function x:getProperties() return spr:getProperties() end
        function x:getSquare() return sq end
        function x:hasModData() return true end
        function x:getModData() return self.md end
        function x:isDismantable() return true end
        function x:getBuildMaterials() return {} end
        function x:hasBuildMaterials() return false end
        function x:isFloor() return false end
        function x:getRenderYOffset() return 0 end
        function x:getTextureName() return spr:getName() end
        function x:getSpriteGridObjectsIncludingSelf() return javaList({ self }) end
        function x:isConnectedSpriteGridObject(y) return y == self end
        function x:isObjectNoContainerOrEmpty() return true end
        function x:hasFluid() return false end
        function x:isBarricaded() return false end
        function x:isStairsObject() return false end
        function x:getHealth() return 450 end
        function x:getMaxHealth() return 450 end
        sq.objects[#sq.objects + 1] = x
        return x
    end
    local function has(sq, o) for _, v in ipairs(sq.objects) do if v == o then return true end end return false end
    local function unbuild(p, n, t)
        sent = {}
        Server.dismantleIntent(p, { n = n, t = t })
        local c = sent[1] and sent[1].cmd
        if c ~= "dismantleAccepted" then return c, sent[1] and sent[1].args or {} end
        sent = {}
        Server.dismantle(p, n, 1)
        return sent[1] and sent[1].cmd, sent[1] and sent[1].args or {}
    end
    local d10, d150 = ours(square(160, 151, 0)), ours(square(300, 151, 0))
    local dOwned = ours(square(171, 150, 0, { owner = "someone" }))
    local cmd
    cmd, a = unbuild(N, 3408, { 160, 151, 0, "cs_wall_01_1" })
    check(cmd == "dismantleSkipped" and a.code == "TOO_FAR" and has(d10:getSquare(), d10),
        "拆：沒開作弊 10 格外照收請求，做完動作時 TOO_FAR、牆還在")
    cmd, a = unbuild(N, 3409, { 300, 151, 0, "cs_wall_01_1" })
    check(cmd == "dismantleRefused" and a.code == "TOO_FAR", "拆除請求：沒開作弊 150 格外 TOO_FAR")
    cmd = unbuild(A, 3410, { 160, 151, 0, "cs_wall_01_1" })
    check(cmd == "dismantled" and not has(d10:getSquare(), d10), "拆：建造作弊 10 格外照拆（不查 MaxDistance）")
    cmd = unbuild(A, 3411, { 300, 151, 0, "cs_wall_01_1" })
    check(cmd == "dismantled" and not has(d150:getSquare(), d150), "拆：建造作弊 150 格外照收請求、照拆（不查 INTENT_REACH）")
    cmd, a = unbuild(A, 3412, { 171, 150, 0, "cs_wall_01_1" })
    check(cmd == "dismantleSkipped" and a.code == "SAFEHOUSE" and has(dOwned:getSquare(), dOwned),
        "拆：建造作弊 20 格外別人的安全屋照樣 SAFEHOUSE、牆還在")
    -- Safehouse MOD 的細分權限照查（作弊只略過距離）
    local asked = {}
    MinidoracatSafehouse = { v1 = { API_MAJOR = 1, CAPABILITIES = { denies = true }, BITS = { BUILD = 4, USE = 1 },
        denies = function(_, x, y, _, bit, opts)
            asked[#asked + 1] = { bit = bit, label = opts and opts.label }
            return x == 175 and y == 150
        end } }
    local permSq = square(175, 150, 0)
    ok, _, a = build(A, 3413, "cs_wall_01_1", { 175, 150, 0 })
    check(not ok and a.code == "PERM_DENIED" and #permSq.objects == 0 and asked[1] and asked[1].bit == 4
        and asked[1].label == "MinidoracatBuilder:build", "建造作弊：Safehouse MOD 不准建造的地方照樣 PERM_DENIED（25 格外）")
    local dPerm = ours(permSq)
    asked = {}
    cmd, a = unbuild(A, 3414, { 175, 150, 0, "cs_wall_01_1" })
    check(cmd == "dismantleSkipped" and a.code == "PERM_DENIED" and has(permSq, dPerm) and asked[1]
        and asked[1].label == "MinidoracatBuilder:dismantle", "拆：建造作弊在 Safehouse MOD 不准的地方照樣 PERM_DENIED、牆還在")
    MinidoracatSafehouse = nil
    instanceof = instReal
    Server.unbuilds = {}
    -- 游標預覽（walk）：作弊不限收請求的範圍，和伺服器一致
    square(301, 140, 0)
    check(Check.item(A, "cs_wall_01_1", 0, { 301, 140, 0 }, { preview = true, walk = true }) == nil
        and Check.item(N, "cs_wall_01_1", 0, { 301, 140, 0 }, { preview = true, walk = true }) == "TOO_FAR",
        "游標預覽：建造作弊 150 格外可蓋，沒開作弊 TOO_FAR")

    -- 客戶端（單機開原版建造作弊）：Client.build／Client.dismantle 不排走路，動作原地做
    isServer, isClient = function() return false end, function() return false end
    local queued, walks = {}, 0
    ISTimedActionQueue = { clear = function() queued = {} end, add = function(x) queued[#queued + 1] = x end,
        isPlayerDoingAction = function() return false end }
    local function walked() walks = walks + 1 return true end
    luautils = { walkAdjWall = walked, walkAdj = walked }
    local far2, near2 = square(160, 130, 0), square(131, 130, 0)
    local P = player({ id = 3409, x = 130.5, y = 130.5 })
    MinidoracatBuilder.Client.build(P, "cs_wall_01_1", { { 160, 130, 0, 0 } })
    check(walks == 0 and #queued == 1 and queued[1].i == 1, "單機建造作弊：Client.build 不排走路，原地排動作")
    if queued[1] then queued[1]:complete() end
    local w2 = far2.objects[1]
    check(w2 ~= nil, "單機建造作弊：原地做完動作，30 格外的牆就蓋好")
    if w2 then -- 拆完的結果由伺服器那段（Dismantle.check 不查距離）驗；這裡只驗不排走路
        nowMs = nowMs + 6000
        MinidoracatBuilder.Client.dismantle(P, w2, "wall", {})
        check(walks == 0 and #queued == 1, "單機建造作弊：本工具拆的不排走路")
    end
    ISBuildMenu.cheat = false
    nowMs = nowMs + 6000
    MinidoracatBuilder.Client.build(P, "cs_wall_01_1", { { 131, 130, 0, 0 } })
    check(walks == 1 and #queued == 1 and #near2.objects == 0, "作弊關：照舊先走過去再排動作")
    if w2 then
        nowMs = nowMs + 6000
        MinidoracatBuilder.Client.dismantle(P, w2, "wall", {})
        check(walks == 2 and #queued == 1, "作弊關：本工具拆的照舊先走過去")
    end
    MinidoracatBuilder.Client.pending, MinidoracatBuilder.Client.pendingUnbuild = nil, nil
    isServer, isClient, ISBuildMenu, ISTimedActionQueue, luautils = realS, realC, realMenu, realQ, realLu
end)()

print("情境三十五：硬核（需要技能、原版材料）、同一套的材質繼承、整套（2026-11-01 設計稿 builder-hardcore-sets-1101）")
;(function()
    nowMs = nowMs + 180000
    local Sets, Messages = MinidoracatBuilder.Sets, MinidoracatBuilder.Messages
    local USE, CONCRETE, TORCH, RODS = Materials.USE, Cost.CONCRETE, Cost.TORCH, Cost.RODS
    local function sp(name, id, flags, keys)
        keys = keys or {}
        for _, f in ipairs(flags) do if keys[f] == nil and f:match("^[A-Z]") then keys[f] = "" end end
        return sprite(name, id, { flags = flags, keys = keys })
    end
    -- 原版排法的牆套：左半套（0–3、8–11）是磚牆，柱子 3、門框 10 沒有 MaterialType；右半套（4–7、12–15）是金屬牆
    local bW = sp("hc_brick_01_0", 3401, { "WallW" }, { MaterialType = "Brick" })
    local bN = sp("hc_brick_01_1", 3402, { "WallN" }, { MaterialType = "Brick" })
    local bPost, bDoor = sp("hc_brick_01_3", 3403, { "WallSE" }), sp("hc_brick_01_10", 3404, { "DoorWallW" })
    local mW = sp("hc_brick_01_4", 3405, { "WallW" }, { MaterialType = "Metal" })
    local mPost = sp("hc_brick_01_7", 3406, { "WallSE" })
    local pW, pPost = sp("hc_plain_01_0", 3407, { "WallW" }), sp("hc_plain_01_3", 3408, { "WallSE" })
    local stoneN = sp("hc_stone_01_1", 3409, { "WallN" }, { MaterialType = "Stone" })
    local f1 = sp("hc_furn_01_0", 3410, { "solid" }, { PickUpWeight = "15" })
    local f2 = sp("hc_furn_01_1", 3411, { "solid" }, { PickUpWeight = "40" })
    local f3 = sp("hc_furn_01_2", 3412, { "solid" }, { PickUpWeight = "100" })
    local fM = sp("hc_furn_01_3", 3413, { "solid" }, { MaterialType = "Metal", PickUpWeight = "15" })
    local doorB = sp("hc_door_01_0", 3414, { "doorW" }, { MaterialType = "Brick" })
    local stairsM = sp("hc_stairs_01_0", 3415, {}, { MaterialType = "Metal" })
    world({ bW, bN, bPost, bDoor, mW, mPost, pW, pPost, stoneN, f1, f2, f3, fM, doorB, stairsM })

    local ts, base, off = Sets.locate("hc_brick_01_13")
    check(ts == "hc_brick_01" and base == 4 and off == 9 and select(2, Sets.locate("x_27")) == 16
        and select(3, Sets.locate("x_27")) == 11, "Sets.locate：一列 8 格、兩列一組、左右各一套（13 是右半套的窗框北、27 是門框北）")
    check(Sets.wallMaterial("hc_brick_01_3") == "Brick" and Sets.wallMaterial("hc_brick_01_15") == "Metal"
        and Sets.wallMaterial("hc_plain_01_3") == nil, "同一套的牆的材質：左半套磚、右半套金屬，牆沒有材質的回 nil")
    local post, door, mpost, ppost = Cost.of("post", bPost, 1), Cost.of("doorFrame", bDoor, 1), Cost.of("post", mPost, 1),
        Cost.of("post", pPost, 1)
    check(post.items["Base.ClayBrick"] == 4 and post.items["Base.Plank"] == nil and post.tools[1] == "MASONS_TROWEL"
        and door.items["Base.ClayBrick"] == 4 and mpost.items["Base.MetalBar"] == 3 and ppost.items["Base.Plank"] == 4,
        "沒有材質的柱子、門框照同一套的牆收（磚、金屬，兩種模式都照）；牆也沒有材質的照木頭")

    local function sk(kind, spr) local p, l = Cost.skillOf(kind, spr) return tostring(p) .. tostring(l) end
    check(sk("wall", pW) == "Woodwork2" and sk("post", bPost) == "Masonry2" and sk("doorFrame", bDoor) == "Masonry2"
        and sk("door", doorB) == "Woodwork3" and sk("stairs", stairsM) == "MetalWelding5" and sk("fence", mW) == "MetalWelding3",
        "技能照原版配方：木牆木工 2、磚柱子與磚門框石工 2（繼承）、磚門沒有配方照木門 3、金屬樓梯金工 5、金屬柵欄 3")
    check(sk("furniture", f1) == "Woodwork1" and sk("container", f2) == "Woodwork3" and sk("solid", f3) == "Woodwork5"
        and sk("furniture", fM) == "MetalWelding3" and sk("light", f1) == "nilnil" and sk("wallObject", f1) == "nilnil",
        "家具、容器、實心照搬運重量 1、3、5 級，金屬的金工 3；燈、掛牆物不要求")

    local sb = SandboxVars.MinidoracatBuilder
    sb.RecipeMaterials = true
    local stone, brick, metal = Cost.of("wall", stoneN, 1), Cost.of("wall", bN, 1), Cost.of("wall", mW, 1)
    local half, free, wood = Cost.of("wall", mW, 0.5), Cost.of("wall", mW, 0), Cost.of("wall", pW, 1)
    check(stone.items["Base.StoneBlock"] == 6 and stone.items["Base.ClayBrick"] == nil and stone.uses[CONCRETE] == 2
        and brick.items["Base.ClayBrick"] == 4 and brick.uses[CONCRETE] == 2 and Cost.of("post", bPost, 1).uses[CONCRETE] == 2,
        "原版材料：石牆收石磚 6、磚牆收紅磚 4，都另收黏土漿或混凝土 2 次；繼承成磚的柱子也收")
    check(metal.uses[TORCH] == 5 and metal.uses[RODS] == 6 and half.uses[TORCH] == 3 and half.uses[RODS] == 3
        and next(free.uses) == nil and next(wood.uses) == nil,
        "金屬牆噴槍 5 次、焊條 6 次，照倍率無條件進位（0.5 → 3、3），倍率 0 不收；木牆沒有耗材")
    local scrapM = sp("hc_mscrap_01_0", 3416, { "WallN" }, { MaterialType = "Metal", CanScrap = "", Material = "MetalBars" })
    local sHalf, sFree = Cost.of("wall", scrapM, 0.5), Cost.of("wall", scrapM, 0)
    check(sHalf.scrap and sHalf.items["Base.MetalBar"] == 2 and sHalf.uses[TORCH] == 3 and sHalf.uses[RODS] == 3
        and sFree.items["Base.MetalBar"] == 2 and next(sFree.uses) == nil,
        "有拆解材質的金屬牆：材料最低照 1 收（退料不多於付的），耗材照原本的倍率（0.5 → 3、3，倍率 0 不收）")
    local sum = Cost.sum({ metal, brick })
    check(sum.uses[TORCH] == 5 and sum.uses[CONCRETE] == 2, "Cost.sum 加總耗材")
    sb.RecipeMaterials = nil
    local stoneOff = Cost.of("wall", stoneN, 1)
    check(stoneOff.items["Base.ClayBrick"] == 4 and stoneOff.items["Base.StoneBlock"] == nil and next(stoneOff.uses) == nil,
        "原版材料關著：石牆照舊收紅磚、沒有耗材")

    -- 耗材：照標籤或型別數次數，背包先、地上後；plan 與摘要判斷相同；用掉照 buildUtil.useDrainable
    local realUse = buildUtil.useDrainable
    buildUtil.useDrainable = function(it, n)
        local k = math.min(n, it.uses)
        it.uses = it.uses - k
        return k
    end
    local P = player({ id = 3401 })
    local b1 = P.inv:add(item("Base.BucketClayCement", { CONCRETE = true }))
    local b2 = P.inv:add(item("Base.BucketConcreteFull", { CONCRETE = true }))
    b1.uses, b2.uses = 1, 4
    local need6 = { items = {}, tools = {}, uses = { [CONCRETE] = 6 } }
    local S = Materials.summary(P)
    local m6 = Materials.short(S, need6)
    local plan6, pm6 = Materials.plan(P, need6)
    check(S.uses[CONCRETE] == 5 and m6 and m6[USE .. CONCRETE] == 1 and plan6 == nil and pm6[USE .. CONCRETE] == 1,
        "耗材照標籤數次數（黏土漿 1＋混凝土 4）；要 6 次時摘要與 plan 都報缺 1 次（鍵是 use:耗材鍵）")
    local plan3 = Materials.plan(P, { items = {}, tools = {}, uses = { [CONCRETE] = 3 } })
    Materials.consume(P, plan3)
    check(plan3 and #plan3.uses == 2 and b1.uses == 0 and b2.uses == 2, "要 3 次：第一桶用 1 次、第二桶用 2 次")
    local here = square(140, 140, 0)
    drop(here, "Base.WeldingRods", 1)
    here.world[#here.world].it.uses = 7
    local P2 = player({ id = 3402, x = 140.5, y = 140.5, here = here })
    local r2 = P2.inv:add(item("Base.WeldingRods"))
    r2.uses = 2
    local S2 = Materials.summary(P2)
    local plan2 = Materials.plan(P2, { items = {}, tools = {}, uses = { [RODS] = 5 } })
    check(S2.uses[RODS] == 9 and plan2 and plan2.uses[1].item == r2 and plan2.uses[1].n == 2 and plan2.uses[2].n == 3,
        "焊條照型別數：背包 2＋身邊地上 7；要 5 次時先用背包的 2 次、再用地上的 3 次")
    check(Messages.refusal("SKILL", { perk = "Masonry", level = 2, have = 1 }) == "IGUI_MBLD_Refuse_SKILL"
        and Messages.items({ [USE .. CONCRETE] = 2 }) == "IGUI_MBLD_UseCount", "SKILL 有自己的訊息；缺的耗材寫次數（UseCount）")

    -- 伺服器與預覽：需要技能、原版材料
    sb.RequireSkill = true
    for x = 130, 134 do square(x, 130, 0) end
    local L = player({ id = 3403, x = 130.5, y = 131.5, perks = { ["perk:Masonry"] = 1 } })
    L.inv:add(item("Base.MasonsTrowel", { MASONS_TROWEL = true }))
    give(L, { ["Base.ClayBrick"] = 4 })
    local ok, _, a = build(L, 3403, "hc_brick_01_1", { 130, 130, 0 })
    check(not ok and a.code == "SKILL" and a.perk == "Masonry" and a.level == 2 and a.have == 1
        and #squares["130,130,0"].objects == 0 and L.inv:count("Base.ClayBrick") == 4,
        "需要技能：石工 1 蓋磚牆被擋（SKILL 帶技能、要幾級、現在幾級），不放、不扣")
    check(Check.item(L, "hc_brick_01_1", 0, { 130, 130, 0 }, { preview = true, summary = Materials.summary(L) }) == "SKILL",
        "預覽同一個判斷：SKILL")
    local C = player({ id = 3404, x = 131.5, y = 131.5, cheat = true })
    check(build(C, 3404, "hc_brick_01_1", { 131, 130, 0 }) and #squares["131,130,0"].objects == 1, "開建造作弊：不看技能")
    -- 目錄變暗、「只看能蓋的」（Check.affordable）也看技能（使用者 2026-11-02）；等級變了，摘要比對要看得出來
    local lvOpts = { id = 3408, x = 133.5, y = 131.5, perks = { ["perk:Masonry"] = 1 } }
    local LV = player(lvOpts)
    LV.inv:add(item("Base.MasonsTrowel", { MASONS_TROWEL = true }))
    give(LV, { ["Base.ClayBrick"] = 4 })
    local SL = Materials.summary(LV)
    local am, at, atotal, ask = Check.affordable(SL, "hc_brick_01_1")
    sb.RequireSkill = nil
    local _, _, _, askOff = Check.affordable(Materials.summary(LV), "hc_brick_01_1")
    sb.RequireSkill = true
    lvOpts.perks["perk:Masonry"] = 2
    local SL2 = Materials.summary(LV)
    local _, _, _, ask2 = Check.affordable(SL2, "hc_brick_01_1")
    local _, _, _, askC = Check.affordable(Materials.summary(C), "hc_brick_01_1")
    check(am == nil and at == nil and atotal and ask and ask.perk == "Masonry" and ask.level == 2 and ask.have == 1
        and askOff == nil and ask2 == nil and askC == nil,
        "affordable 也看技能：料和工具都夠、石工 1 仍回技能不夠（要 2、有 1）；選項關著、升到 2、建造作弊都沒有")
    check(not Materials.same(SL, SL2) and Materials.same(SL2, Materials.summary(LV)),
        "技能等級變了摘要比對就不一樣（缺料標示要重算）；沒變照樣一樣")
    sb.RecipeMaterials = true
    local L2 = player({ id = 3405, x = 132.5, y = 131.5, perks = { ["perk:Masonry"] = 2 } })
    L2.inv:add(item("Base.MasonsTrowel", { MASONS_TROWEL = true }))
    give(L2, { ["Base.ClayBrick"] = 4 })
    ok, _, a = build(L2, 3405, "hc_brick_01_1", { 132, 130, 0 })
    check(not ok and a.code == "NO_MATERIAL" and a.need[USE .. CONCRETE] == 2 and a.need["Base.ClayBrick"] == nil,
        "石工 2 過了技能；原版材料缺黏土漿或混凝土：NO_MATERIAL 報缺 2 次")
    local bk = L2.inv:add(item("Base.BucketClayCement", { CONCRETE = true }))
    bk.uses = 4
    xpLog = {}
    ok = build(L2, 3406, "hc_brick_01_1", { 132, 130, 0 })
    local w = squares["132,130,0"].objects[1]
    check(ok and bk.uses == 2 and L2.inv:count("Base.ClayBrick") == 0 and w and w.mats["Base.ClayBrick"] == "4"
        and w.mats[CONCRETE] == nil and w.mats[USE .. CONCRETE] == nil, "放好才扣：紅磚 4、黏土漿 2 次；退料表只寫紅磚（耗材不退）")
    check(#xpLog == 1 and xpLog[1].perk == "perk:Masonry", "經驗只照紅磚給石工，耗材不給")
    -- 游標拖兩格：耗材只夠一格，第二格缺料；摘要本身不被扣
    local L3 = player({ id = 3407, x = 133.5, y = 131.5, perks = { ["perk:Masonry"] = 2 } })
    L3.inv:add(item("Base.MasonsTrowel", { MASONS_TROWEL = true }))
    give(L3, { ["Base.ClayBrick"] = 8 })
    local bk3 = L3.inv:add(item("Base.BucketClayCement", { CONCRETE = true }))
    bk3.uses = 2
    require "MinidoracatBuilder/Cursor"
    local S3 = Materials.summary(L3)
    local res, okN, shortN = MinidoracatBuilder.Cursor.preview(L3, "hc_brick_01_1", 0, { { 133, 130, 0, 0 }, { 134, 130, 0, 0 } }, S3)
    check(okN == 1 and shortN == 1 and res[2].code == "NO_MATERIAL" and res[2].extra.need[USE .. CONCRETE] == 2
        and S3.uses[CONCRETE] == 2, "游標逐格扣耗材：第一格用掉 2 次，第二格缺 2 次；摘要本身不動")
    -- 原地替換的游標標籤：耗材不在舊的退料表裡、照整份付，材料不用補時也要寫在要補的那行（不寫「材料相同」）
    local function swapLabel(uses)
        local info = { replace = {}, pay = {}, back = {}, total = { uses = uses } }
        return setmetatable({ swapN = 1, S = {}, res = { { info = info } } }, { __index = MinidoracatBuilder.Cursor }):swapText()
    end
    check(swapLabel({ [CONCRETE] = 2 }) == "IGUI_MBLD_SwapPay" and swapLabel({}) == "IGUI_MBLD_SwapSame",
        "原地換同材料：材料不用補、耗材照付時標籤寫要補；耗材也沒有才寫「材料相同」")
    sb.RequireSkill, sb.RecipeMaterials = nil, nil
    buildUtil.useDrainable = realUse

    local kinds = { hc_brick_01_0 = "wall", hc_brick_01_1 = "wall", hc_brick_01_3 = "post", hc_brick_01_10 = "doorFrame" }
    local list, at = Sets.of("hc_brick_01_10", function(n) return kinds[n] end)
    check(list and list.n == 4 and list[1] == "hc_brick_01_0" and list[3] == "hc_brick_01_3" and list[4] == "hc_brick_01_10"
        and at.hc_brick_01_3 == 3 and at.hc_brick_01_10 == 10, "整套：同一套照位置排（牆西、牆北、柱子、門框），記下每張的位置")
    check(Sets.of("hc_brick_01_3", function(n) return ({ hc_brick_01_3 = "post", hc_brick_01_10 = "doorFrame" })[n] end) == nil,
        "只有柱子和門框、沒有牆：不算一套（視窗改列同一組）")
    local fences = { f_01_0 = "post", f_01_1 = "wall", f_01_8 = "fence", f_01_9 = "fence", f_01_10 = "fence", f_01_11 = "fence" }
    local walls8 = { g_01_0 = "wall", g_01_1 = "wall", g_01_8 = "fence" }
    check(Sets.of("f_01_8", function(n) return fences[n] end) == nil and Sets.of("g_01_0", function(n) return walls8[n] end) == nil,
        "位置的種類不合（柵欄表 0 是柱子、8–11 是柵欄；牆後面的 8 是柵欄）：不是原版牆的排法，不算一套")
end)()

print("情境三十六：燈的帳本照伺服器發的編號認（2026-11-02）：同一格的燈各認各的、移除只清自己那筆、線路照帳本認、0.3.0 以前的燈讀到那一塊時定案")
;(function()
    nowMs = nowMs + 180000
    local Ledger, Circuits = MinidoracatBuilder.Ledger, MinidoracatBuilder.Circuits
    local realInst = instanceof
    instanceof = function(o, cls) return type(o) == "table" and o.class == cls end
    local inst = Ledger.instance
    local LAMP_KEYS = { lightR = "200", lightG = "180", lightB = "150" }
    local lampA = sprite("kl_01_0", 3601, { type = T.lightswitch, keys = LAMP_KEYS })
    local lampB = sprite("kl_01_1", 3602, { type = T.lightswitch, keys = LAMP_KEYS })
    local swS = sprite("ks_01_0", 3603, { type = T.lightswitch })
    local floorK = sprite("kf_01_0", 3604, { flags = { "solidfloor" } })
    -- 一塊 140..147 的空地：移除時照引擎先觸發 OnObjectAboutToBeRemoved，退料掉在這裡時記件數
    local function at(x, y)
        local sq = square(x, y, 0)
        sq.dropped = {}
        local orig = sq.transmitRemoveItemFromSquare
        function sq:transmitRemoveItemFromSquare(obj, safely)
            fire("OnObjectAboutToBeRemoved", obj)
            return orig(self, obj, safely)
        end
        function sq:AddWorldInventoryItem(ft) self.dropped[ft] = (self.dropped[ft] or 0) + 1 end
        return sq
    end
    for x = 140, 147 do for y = 140, 147 do at(x, y) end end
    local function S(x, y) return squares[x .. "," .. y .. ",0"] end
    local function has(sq, o) for _, v in ipairs(sq.objects) do if v == o then return true end end return false end
    -- 燈（IsoLightSwitch）：how＝"ours" 本工具蓋的（帳本發編號）、"mark" 有本 MOD 記號但帳本沒有、nil 原版的
    local function lamp(sq, spr, how)
        local o = { class = "IsoLightSwitch", md = {}, keyId = -1, spr = spr }
        if how then o.md.builderEntry = spr:getName() end
        function o:getSprite() return self.spr end
        function o:getSquare() return sq end
        function o:hasModData() return next(self.md) ~= nil end
        function o:getModData() return self.md end
        function o:getKeyId() return self.keyId end
        function o:setKeyId(v) self.keyId = v end
        function o:getProperties() return self.spr:getProperties() end
        function o:getTextureName() return self.spr:getName() end
        function o:getType() return self.spr:getType() end
        function o:isObjectNoContainerOrEmpty() return true end
        function o:getSpriteGridObjectsIncludingSelf() return javaList({ self }) end
        function o:isConnectedSpriteGridObject(x) return x == self end
        function o:isStairsObject() return false end
        function o:hasFluid() return false end
        function o:isBarricaded() return false end
        function o:getContainerCount() return 0 end
        function o:isMovedThumpable() return self.moved == true end
        function o:setMovedThumpable(v) self.moved = v end
        sq.objects[#sq.objects + 1] = o
        if how == "ours" then Ledger.put(o, { ["Base.ElectricWire"] = 2, ["Base.ElectronicsScrap"] = 1 }) end
        return o
    end
    local here = S(143, 143)
    local P = player({ id = 3601, x = 143.5, y = 143.5, here = here })
    P.inv:add(item("Base.Hammer", { HAMMER = true }))
    P.inv:add(item("Base.Screwdriver", { SCREWDRIVER = true }))
    local nonce = 3600
    local function unbuild(sq, name)
        nonce = nonce + 1
        sent = {}
        here.dropped = {}
        Server.dismantleIntent(P, { n = nonce, t = { sq:getX(), sq:getY(), 0, name } })
        Server.dismantle(P, nonce, 1)
        return sent[#sent] and sent[#sent].cmd, sent[#sent] and sent[#sent].args or {}
    end
    HARNESS_ROLL = "max"

    -- 蓋燈：伺服器發編號寫進 keyId，帳本照編號記位置、蓋的圖與退料
    local saved = false
    for _, k in ipairs(HARNESS_GOS_KEYS.MinidoracatBuilder or {}) do saved = saved or k == "lamps" end
    check(saved, "帳本存檔白名單有 lamps（漏了重開後燈的帳本消失、每盞燈都拆不了）")
    local sq1 = S(144, 143)
    local L = lamp(sq1, lampA, "ours")
    local M = lamp(sq1, lampB, "ours")
    local eL, eM = inst.lamps.e[L.keyId], inst.lamps.e[M.keyId]
    check(L.keyId > 0 and M.keyId > 0 and L.keyId ~= M.keyId and eL ~= nil and eL.p == "144,143,0" and eL.s == "kl_01_0"
        and eL.i["Base.ElectricWire"] == 2 and eM ~= nil and eM.s == "kl_01_1" and inst.built["144,143,0,kl_01_0"] == nil
        and inst.lamps.next > math.max(L.keyId, M.keyId),
        "蓋燈：發編號寫進 keyId，帳本照編號記位置、蓋的圖與退料（不寫 built）；同一格兩盞各一個編號")

    -- 同一格的燈：照圖名找到的是帳本沒有的那盞時不退料
    local X = lamp(sq1, lampB, "mark")
    L.spr = lampB
    X.spr, X.md.builderEntry = lampA, "kl_01_0"
    local c, a = unbuild(sq1, "kl_01_0")
    check(c == "dismantleSkipped" and a.code == "NOT_OURS" and next(here.dropped) == nil and has(sq1, X)
        and inst.lamps.e[L.keyId] ~= nil, "照圖名找到同一格帳本沒有的那盞：NOT_OURS、不拆不退，L 的帳本還在")
    local X2 = lamp(sq1, lampA, "mark")
    sq1:transmitRemoveItemFromSquare(X2)
    check(inst.lamps.e[L.keyId] ~= nil and inst.lamps.e[M.keyId] ~= nil,
        "帳本沒有的燈移出世界：同一格別盞的帳本不動")
    L.spr, X.spr = lampA, lampB
    c = unbuild(sq1, "kl_01_0")
    check(c == "dismantled" and here.dropped["Base.ElectricWire"] == 2 and here.dropped["Base.ElectronicsScrap"] == 1
        and not has(sq1, L) and inst.lamps.e[L.keyId] == nil and inst.lamps.e[M.keyId] ~= nil,
        "L 照自己那筆退料，移除時只清 L 那筆（同一格的 M 還在）")
    M.spr = floorK
    local changed = Ledger.get(M)
    M.spr = lampB
    check(changed == nil and Ledger.get(M) ~= nil, "圖和蓋的時候不同就不認（拆除照現在的圖分種類），相同時照常認")
    local Y = lamp(S(146, 146), lampB)
    Y.keyId = M.keyId
    local moved = Ledger.get(Y)
    S(146, 146):transmitRemoveItemFromSquare(Y)
    check(moved == nil and inst.lamps.e[M.keyId] ~= nil, "編號相同、不在帳本記的位置：不認，移出世界也不清那一筆")
    local old = lamp(sq1, lampA)
    old.keyId = M.keyId
    local reused = Ledger.get(old)
    sq1:transmitRemoveItemFromSquare(old)
    check(reused == nil and inst.lamps.e[M.keyId] ~= nil,
        "同一格留著同編號、圖不同的燈（當機回溯後編號重發）：不認，移出世界也不清那一筆")
    local SW, SM = lamp(S(140, 146), swS, "ours"), lamp(S(141, 146), swS, "mark")
    local LM = lamp(S(142, 146), lampA, "mark")
    check(Circuits.isSwitch(SW) and not Circuits.isSwitch(SM) and Circuits.isLamp(M) and not Circuits.isLamp(LM),
        "線路：帳本有的開關與燈才算本 MOD 的")

    -- 0.3.0 以前的燈：built 照「位置＋圖名」記，升版後讀到那一塊（8×8，LoadChunk 每塊一次）時整塊定案
    local sqA, sqQ = S(144, 144), S(142, 144)
    local V = lamp(sqA, lampA)
    local A1, A2 = lamp(sqA, lampA, "mark"), lamp(sqA, lampB, "mark")
    local Q1, Q2 = lamp(sqQ, lampA, "mark"), lamp(sqQ, lampA, "mark")
    local landKey = "147,140,0," .. Entry.STAIR_FLOOR
    local onLanding = lamp(S(147, 140), sprite(Entry.STAIR_FLOOR, 3605, { flags = { "solidfloor" } }), "mark")
    inst.built["144,144,0,kl_01_0"] = { ["Base.ElectricWire"] = 1 }
    inst.built["144,144,0,kl_01_1"] = { ["Base.ElectricWire"] = 3 }
    inst.built["145,145,0,kl_01_0"] = { ["Base.ElectricWire"] = 4 } -- 燈已不在
    inst.built["142,144,0,kl_01_0"] = { ["Base.ElectricWire"] = 5 }
    inst.built["200,200,0,kl_01_0"] = { ["Base.ElectricWire"] = 1 } -- 這一段都不讀那一塊：讀塊事件一直掛著（同正式服）
    inst:initSystem()
    local before = Ledger.legacy
    inst.built[landKey] = {}
    inst:initSystem()
    check(before >= 4 and Ledger.legacy == before, "重開時數還沒定案的舊燈：樓梯平台不算")
    fire("LoadChunk", sqA:getChunk())
    local a1, a2 = inst.lamps.e[A1.keyId], inst.lamps.e[A2.keyId]
    check(a1 ~= nil and a2 ~= nil and A1.keyId ~= A2.keyId and a1.s == "kl_01_0" and a1.p == "144,144,0"
        and a1.i["Base.ElectricWire"] == 1 and a2.i["Base.ElectricWire"] == 3 and inst.built["144,144,0,kl_01_0"] == nil
        and inst.built["144,144,0,kl_01_1"] == nil and V.keyId == -1,
        "讀到那一塊：舊紀錄照格上那盞本 MOD 的燈搬成編號，退料照舊、舊紀錄刪掉；原版燈不算")
    check(inst.built["145,145,0,kl_01_0"] == nil and Ledger.legacy == before - 3,
        "同一塊裡燈已不在的舊鍵一起刪掉")
    local forged = lamp(S(145, 145), lampA, "mark")
    fire("LoadChunk", S(145, 145):getChunk())
    check(forged.keyId == -1 and Ledger.get(forged) == nil, "定案後那一格的燈不再搬")
    fire("LoadChunk", sqQ:getChunk()) -- 那一塊的原點那格不存在：照其他格定位
    local neither = Q1.keyId == -1 and Q2.keyId == -1
    sqQ:transmitRemoveItemFromSquare(Q2)
    fire("LoadChunk", sqQ:getChunk())
    check(neither and Q1.keyId == -1 and inst.built["142,144,0,kl_01_0"] == nil and Ledger.get(Q1) == nil
        and Ledger.legacy == before - 4,
        "同一格兩盞同款的舊燈：分不出是哪一盞，舊紀錄刪掉（本工具拆不了）；砸掉一盞再讀也不搬")
    fire("LoadChunk", S(147, 140):getChunk())
    check(onLanding.keyId == -1 and inst.built[landKey] ~= nil, "樓梯平台的紀錄不搬")
    fire("LoadChunk", sqA:getChunk())
    check(inst.lamps.e[A1.keyId] == a1 and Ledger.legacy == before - 4 and count("LoadChunk") == 1,
        "同一塊再讀一次（還有別塊沒讀到、事件還掛著）：已定案，不再動")
    c = unbuild(sqA, "kl_01_1")
    check(c == "dismantled" and here.dropped["Base.ElectricWire"] == 3 and inst.lamps.e[A2.keyId] == nil,
        "搬過的燈：本工具照搬過去的那筆退料")
    inst.built["200,200,0,kl_01_0"] = nil

    -- 當機回溯：搬過的燈帶著編號存進 chunk、帳本回到搬之前，重開後照樣搬給它；同一格另有一盞帳本認不得的同款燈時兩盞都不搬
    local W = lamp(at(152, 152), lampA, "mark")
    W.keyId = 999
    local W2 = lamp(at(153, 152), lampA, "mark")
    W2.keyId = 998
    local X3 = lamp(S(153, 152), lampA, "mark")
    inst.built["152,152,0,kl_01_0"] = { ["Base.ElectricWire"] = 6 }
    inst.built["153,152,0,kl_01_0"] = { ["Base.ElectricWire"] = 8 }
    inst:initSystem()
    fire("LoadChunk", S(152, 152):getChunk())
    check(W.keyId > 0 and W.keyId ~= 999 and inst.lamps.e[W.keyId].i["Base.ElectricWire"] == 6 and W2.keyId == 998
        and X3.keyId == -1 and inst.built["153,152,0,kl_01_0"] == nil,
        "舊紀錄那格的燈帶著帳本沒有的編號（當機回溯）：照樣搬過去；同一格另有一盞帳本認不得的同款燈：兩盞都不搬")

    -- 單機：帳本建好前就讀進來的塊，建好後第一個 tick 照舊鍵的位置找到就定案；那時還沒讀進來的塊讀進來再定案。
    -- 那一塊只有一筆舊鍵、它的格子已經不在（例：上一層拆掉了），塊本身讀進來了：照座標找得到那一塊，那一筆照樣定案（刪掉）
    local R = lamp(S(140, 140), lampA, "mark")
    at(171, 170) -- 第 21,21 塊讀進來了（只有這一格，沒有舊鍵）
    inst.built["140,140,0,kl_01_0"] = { ["Base.ElectricWire"] = 7 }
    inst.built["170,170,1,kl_01_0"] = { ["Base.ElectricWire"] = 2 }
    inst.built["160,160,0,kl_01_0"] = { ["Base.ElectricWire"] = 9 } -- 那一塊還沒讀進來
    inst:initSystem()
    local ticks = count("OnTick") -- 含剛掛上的那一個 tick
    fire("OnTick")
    local onTick = R.keyId > 0 and inst.lamps.e[R.keyId].i["Base.ElectricWire"] == 7 and count("OnTick") == ticks - 1
        and inst.built["170,170,1,kl_01_0"] == nil
        and inst.built["160,160,0,kl_01_0"] ~= nil and count("LoadChunk") == 1
    local F = lamp(at(160, 160), lampA, "mark")
    fire("LoadChunk", S(160, 160):getChunk())
    check(onTick and F.keyId > 0 and inst.lamps.e[F.keyId].i["Base.ElectricWire"] == 9 and count("LoadChunk") == 0,
        "單機讀檔：帳本建好前讀進來的塊在建好後第一個 tick 定案、摘掉 tick 事件；還沒讀進來的塊讀進來時定案，都定案後摘掉讀塊事件")
    inst:initSystem()
    check(count("LoadChunk") == 0 and count("OnTick") == ticks - 1, "沒有舊燈：開服不掛讀塊與 tick 事件（每塊、每格都不多花）")

    -- 定案出錯：那一塊的舊鍵留在 built、這一場不再試（讀塊事件照樣摘掉），下次開服重新分組照樣搬
    local E = lamp(at(180, 180), lampA, "mark")
    local hasMD = E.hasModData
    E.hasModData = function() error("harness: broken object") end
    inst.built["180,180,0,kl_01_0"] = { ["Base.ElectricWire"] = 4 }
    inst:initSystem()
    fire("LoadChunk", S(180, 180):getChunk())
    local kept = inst.built["180,180,0,kl_01_0"] ~= nil and E.keyId == -1 and Ledger.legacy == 1 and count("LoadChunk") == 0
    E.hasModData = hasMD
    inst:initSystem()
    fire("LoadChunk", S(180, 180):getChunk())
    check(kept and E.keyId > 0 and inst.lamps.e[E.keyId].i["Base.ElectricWire"] == 4 and count("LoadChunk") == 0,
        "定案出錯：舊鍵留著、這一場摘掉事件，下次開服照樣搬")
    instanceof = realInst
end)()

print("情境三十七：2026-11-07 Workshop 回饋：帶 solidfloor 的圖塊包地毯不當地板、放地板時留著；行軍床與擔架床照列")
;(function()
    local Place = MinidoracatBuilder.Place
    local rugMove = { flags = { "solidfloor" }, keys = { MoveType = "FloorRug", IsMoveAble = "" } }
    local rugOver = { flags = { "solidfloor", "FloorOverlay" }, keys = { MoveType = "FloorRug" } }
    check(kind(rugMove) == "furniture" and kind(rugOver) == "floorOverlay" and kind({ flags = { "solidfloor" } }) == "floor"
        and kind({ flags = { "solidfloor" }, keys = { MoveType = "FloorTile", IsMoveAble = "" } }) == "floor",
        "帶 solidfloor 的地毯（UMCTP、Constown）：能搬的歸家具、不能搬的歸地面覆蓋；其他地板照舊")
    local g1, g2 = sprite("rugpack_04_0", 9108, rugOver), sprite("rugpack_04_1", 9109, rugOver)
    fakeGrid(2, 1, { { g1, g2 } })
    check(kind({ flags = { "solidfloor" }, keys = { MoveType = "FloorRug" } }) == "floor" and Rules.classify(g1) == "floor"
        and Rules.classify(g2) == "floor",
        "掛不上地板的實心地毯（沒有 FloorOverlay、多格）：照 0.5.0 當地板，免得建成物件又記不了退料（審查 1107 Claude）")
    local function code(o) return select(2, Rules.classify(sprite("test_01_0", 5, o))) end
    local bed = { flags = { "bed", "solidtrans" }, keys = { IsMoveAble = "", BedType = "averageBed" } }
    local function with(item) bed.keys.CustomItem = item return kind(bed) end
    check(with("Base.Mov_Cot") == "furniture" and with("Base.Mov_Gurney") == "furniture" and with("Mov_Gurney") == "furniture",
        "行軍床、擔架床（撿起來是床的專用物品）：家具")
    check(with("Base.Mattress") == nil and code({ keys = { CustomItem = "Base.Tent", IsMoveAble = "" } }) == "PLANT"
        and code({ keys = { CustomItem = "", IsMoveAble = "" } }) == "PLANT", "其他帶 CustomItem 的照舊不列（PLANT）")

    -- 放地板：拆掉舊地板，地毯照原版名稱（floors_rugs）或 MoveType=FloorRug 認、留著，新地板插在地毯前面
    local function piece(sq, spr)
        local o = {}
        function o:getProperties() return spr:getProperties() end
        function o:getTextureName() return spr:getName() end
        function o:getType() return spr:getType() end
        function o:getSprite() return spr end
        sq.objects[#sq.objects + 1] = o
        return o
    end
    local function has(sq, o) for _, v in ipairs(sq.objects) do if v == o then return true end end return false end
    local floorS = sprite("rugtest_floor_01_0", 9101, { flags = { "solidfloor" } })
    local sq = square(190, 190, 0)
    local old = piece(sq, floorS)
    local packRug = piece(sq, sprite("rugpack_01_37", 9102, rugMove))
    local idx = Place.clearFloor(sq)
    check(not has(sq, old) and has(sq, packRug) and idx == 0, "放地板：圖塊包的地毯（帶 solidfloor）留著，新地板插在它前面")
    local sq2 = square(191, 190, 0)
    local old2 = piece(sq2, floorS)
    local vanillaRug = piece(sq2, sprite("floors_rugs_01_86", 9103, {}))
    check(Place.clearFloor(sq2) == 0 and not has(sq2, old2) and has(sq2, vanillaRug), "放地板：原版名稱 floors_rugs 的地毯照舊留著")

    -- 0.5.0 以前被當地板蓋的地毯（IsoThumpable、isFloor）：照地板拆。不能搬的（Constown，現在歸地面覆蓋）走本工具拆、
    -- 照地板帳本退；能搬的（UMCTP，現在歸家具）和 0.5.0 一樣歸原版拿起來（pickup）
    local Dismantle = MinidoracatBuilder.Dismantle
    local realInst = instanceof
    instanceof = function(o, cls) return o.class == cls end
    local function oldFloor(spr)
        local o = { class = "IsoThumpable", md = { builderEntry = spr:getName() } }
        function o:hasModData() return true end
        function o:getModData() return self.md end
        function o:isFloor() return true end
        function o:isDismantable() return true end
        function o:getSprite() return spr end
        function o:getSquare() return sq end
        return o
    end
    local overS = sprite("rugpack_02_64", 9104, rugOver)
    local moveS = sprite("rugpack_01_38", 9105, rugMove)
    local kOver, kMove = Dismantle.kindOf(oldFloor(overS)), Dismantle.kindOf(oldFloor(moveS))
    local _, routeMove = Dismantle.classOf(moveS)
    instanceof = realInst
    check(kOver == "floor" and kMove == nil and routeMove == "pickup",
        "0.5.0 蓋成地板的地毯：不能搬的照地板走本工具拆（不當地面覆蓋），能搬的照舊歸原版拿起來")
end)()

print("情境三十八：2026-11-07 Workshop 回饋：牆型窗（窗和窗框同一張）不用先有窗框、不疊兩層框；一般窗照舊要窗框")
;(function()
    local Place, Dismantle = MinidoracatBuilder.Place, MinidoracatBuilder.Dismantle
    local EW = GridSquareEdgeFacingDirection.EAST_WEST
    -- 照原版 walls_commercial_01_96：型別 wall、帶窗旗標 windowW 也帶窗框旗標 WindowW
    local framed = sprite("walls_fbwin_01_96", 9201, { type = T.wall,
        flags = { "collideW", "windowW", "transparentW", "cutW", "canPathW", "WindowW" },
        keys = { WindowLocked = "", WindowW = "WindowW" } })
    local framed2 = sprite("walls_fbwin_01_98", 9202, { type = T.wall, flags = { "collideW", "windowW", "cutW", "WindowW" },
        keys = { WindowW = "WindowW" } })
    local plain = sprite("fbwin_plain_01_0", 9203, { type = T.MAX, flags = { "windowW", "cutW", "WindowW" } }) -- 一般的窗
    local frameS = sprite("walls_fbwin_01_8", 9204, { flags = { "WindowW", "cutW", "collideW" }, keys = { WindowW = "" } })
    local wallS = sprite("walls_fbwin_01_0", 9205, { flags = { "WallW", "cutW", "collideW" }, keys = { WallW = "" } })
    check(kind({ type = T.wall, flags = { "windowW", "WindowW" }, keys = { WindowW = "" } }) == "window"
        and Rules.framedWindow(framed:getType()) and not Rules.framedWindow(plain:getType()), "牆型窗歸窗；只有型別 wall 的算牆型窗")

    local empty = square(210, 210, 0)
    local frameO = { flags = { WindowW = true, cutW = true, collideW = true } }
    local withFrame = square(211, 210, 0, frameO)
    check(Place.check("window", framed, empty) == true, "牆型窗：沒有窗框的邊可蓋")
    check(not Place.check("window", framed, withFrame), "牆型窗：那條邊已經有窗框（地圖的或本工具蓋的）時擋下，不疊兩層框")
    check(not Place.check("window", plain, empty) and Place.check("window", plain, withFrame),
        "一般的窗照舊：沒有窗框不能放，有窗框、還沒有窗才能放")
    check(not Place.check("window", framed, square(212, 210, 0, { flags = { WallW = true } }))
        and not Place.check("window", framed, square(213, 210, 1)) and not Place.check("window", framed, square(214, 210, 0, { stairs = true })),
        "牆型窗照一般格邊：那條邊有牆、樓上腳下沒有地板、格上有樓梯都擋")

    -- 蓋：照舊建 IsoWindow（north 照佔的邊）；沒有窗框，照牆插在最後一個地板後面（格上沒有地板就加在最後）
    local made = {}
    local realWindow = IsoWindow
    IsoWindow = { new = function(_, sq, spr, north)
        local o = { spr = spr, sq = sq, north = north, set = {} }
        function o:setIsLocked(v) self.set.locked = v end
        function o:setExplored() end
        function o:transmitCompleteItemToClients() end
        function o:getContainerCount() return 0 end
        function o:getProperties() return spr:getProperties() end
        function o:getSprite() return spr end
        made[#made + 1] = o
        return o
    end }
    local placed = {}
    local fresh = square(215, 210, 0, { flags = {} })
    fresh.objects[1] = { getProperties = function() return wallS:getProperties() end } -- 同格別的東西（北邊的牆之類）
    Place.build("window", { { sq = fresh, spr = framed, cost = { items = {} } } }, placed)
    local floorS = sprite("floors_fbwin_01_0", 9206, { flags = { "solidfloor" } })
    local FL = { getProperties = function() return floorS:getProperties() end }
    local CHR = { getProperties = function() return wallS:getProperties() end }
    local onFloor = square(217, 210, 0, { flags = {} })
    onFloor.objects = { FL, CHR }
    Place.build("window", { { sq = onFloor, spr = framed, cost = { items = {} } } }, {})
    IsoWindow = realWindow
    local win = made[1]
    check(#made == 2 and win.north == false and win.spr == framed and win.set.locked == false and placed[1] == win
        and fresh.objects[2] == win, "蓋牆型窗：建 IsoWindow（西邊 north＝false）、不另建窗框；格上沒有地板時加在最後")
    check(onFloor.objects[1] == FL and onFloor.objects[2] == made[2] and onFloor.objects[3] == CHR,
        "蓋牆型窗：格上有地板和別的東西時照牆插在地板後面、不排到最後（審查 1110）")

    -- 蓋好之後引擎的格子屬性是各物件的聯集，getWindow 回這扇窗（IsoGridSquare.java:7250-7264、3634-3680）
    local builtO = { flags = { WindowW = true, windowW = true, cutW = true, collideW = true }, windows = { [EW] = win } }
    local built = square(216, 210, 0, builtO)
    built.objects[1] = win
    check(not Place.check("wall", wallS, built) and not Place.check("windowFrame", frameS, built)
        and not Place.check("window", framed2, built) and not Place.check("window", plain, built),
        "牆型窗蓋好後，同一條邊再蓋牆、窗框、另一款牆型窗、一般窗都擋下")

    -- 原地替換照現有裁定：窗不在可換的組（NO_REPLACE），不能拿牆型窗換掉本工具蓋的牆或窗框，也不能把它換成別的
    check(not Dismantle.swappable("wall", wallS, "window", framed) and not Dismantle.swappable("windowFrame", frameS, "window", framed)
        and not Dismantle.swappable("window", framed, "wall", wallS), "原地替換：牆型窗和牆、窗框不互換（窗照舊不換）")

    -- 兩端同一份判斷：Check.item 預覽與伺服器回同一個碼
    local old = IsoSpriteManager.instance:getNamedMap():values()._raw
    local list = {}
    for i, s in ipairs(old) do list[i] = s end
    for _, s in ipairs({ framed, plain }) do list[#list + 1] = s end
    world(list)
    local K = player({ id = 380, x = 210.5, y = 211.5, here = square(210, 211, 0) })
    local function both(name, x)
        local a = Check.item(K, name, 0, { x, 210, 0 }, { preview = true })
        local b = Check.item(K, name, 0, { x, 210, 0 })
        return a == b and (a or "ok")
    end
    check(both("walls_fbwin_01_96", 210) == "ok" and both("walls_fbwin_01_96", 211) == "BLOCKED"
        and both("fbwin_plain_01_0", 210) == "BLOCKED" and both("fbwin_plain_01_0", 211) == "ok",
        "Check.item：預覽與伺服器同一個結果（牆型窗空邊可蓋、有窗框擋；一般窗反過來）")
    world(old)
end)()

print("情境四十：2026-11-07 Workshop 回饋：拖一排原版兩張一組的柵欄照 ABAB 交替（伺服器、預覽、游標虛影同一張）")
;(function()
    nowMs = nowMs + 180000
    local realMax = sb.MaxCellsPerDrag
    sb.MaxCellsPerDrag = 8
    local function fence(name, id, dir, entity)
        local flags = { "TallHoppable" .. dir, "collide" .. dir, "cut" .. dir, "Wall" .. dir }
        if entity then flags[#flags + 1] = "EntityScript" end
        return sprite(name, id, { flags = flags, keys = { ["Wall" .. dir] = "", CanScrap = "", Material = "Wood",
            HitByCar = "", EntityScriptName = entity and "MetalSmallWireFence" or nil } })
    end
    local f8, f9 = fence("fencing_01_8", 4001, "N"), fence("fencing_01_9", 4002, "N")
    local f10, f11 = fence("fencing_01_10", 4003, "W"), fence("fencing_01_11", 4004, "W")
    local f24, f25 = fence("fencing_01_24", 4005, "N"), fence("fencing_01_25", 4006, "N", true)
    local f32 = fence("fencing_01_32", 4007, "N")         -- 同一對的 fencing_01_33 不在圖塊表
    local f16 = fence("fencing_01_16", 4008, "W")         -- 原版柵欄但不是「2-tile」那五族
    local pack = fence("packfence_01_8", 4009, "N")       -- 圖塊包的同號柵欄：不猜
    local f64, f65 = fence("fencing_01_64", 4010, "N"), fence("fencing_01_65", 4011, "N", true) -- 65 被配方佔走
    local f34, f35 = fence("fencing_01_34", 4012, "W"), fence("fencing_01_35", 4013, "W")       -- 35 被排除
    -- 2026-11-12 加的 8 對：48／49 帶牆的屬性（目錄歸在牆）；53 是那組的立柱，沒有任何種類屬性
    local function hiwall(name, id)
        return sprite(name, id, { flags = { "collideN", "cutN", "WallN" }, keys = { WallN = "", CanScrap = "", Material = "MetalBars" } })
    end
    local f48, f49 = hiwall("fencing_01_48", 4020), hiwall("fencing_01_49", 4021)
    local f53 = sprite("fencing_01_53", 4022, { flags = {}, keys = { CanScrap = "", Material = "MetalBars" } })
    local p53 = sprite("packfence_01_53", 4023, { flags = {}, keys = { CanScrap = "", Material = "MetalBars" } })
    world({ f8, f9, f10, f11, f24, f25, f32, f16, pack, f64, f65, f34, f35, f48, f49, f53, p53 })
    check(Rules.classify(f48) == "wall", "假圖塊：48 帶牆的屬性，種類是牆")
    check(Rules.classify(f53) == "post" and Rules.classify(p53) == nil,
        "fencing_01_53 沒有種類屬性，照名稱列成柱子；圖塊包的同號圖不猜")
    check(Rules.classify(f8) == "fence" and Rules.classify(f10) == "fence" and Rules.classify(f25) == nil,
        "假圖塊：8、10 是柵欄；25 是建造配方的圖（ENTITY，目錄不列）")
    local function alt(name, x, y)
        local ok, s = pcall(Entry.alternate, Entry.sprite(name), x, y)
        return ok and s and s:getName() or nil
    end
    check(alt("fencing_01_8", 210, 210) == "fencing_01_8" and alt("fencing_01_8", 211, 210) == "fencing_01_9"
        and alt("fencing_01_9", 212, 210) == "fencing_01_8" and alt("fencing_01_9", 211, 212) == "fencing_01_9",
        "北向一排：(x+y) 偶數放 A（8）、奇數放 B（9）；挑 A 或 B 都照座標")
    check(alt("fencing_01_10", 210, 211) == "fencing_01_11" and alt("fencing_01_11", 210, 212) == "fencing_01_10",
        "西向一排：同一條規則（10／11）")
    check(alt("fencing_01_48", 210, 210) == "fencing_01_48" and alt("fencing_01_48", 211, 210) == "fencing_01_49"
        and alt("fencing_01_49", 210, 212) == "fencing_01_48", "牆種類的一對（48／49）也照座標交替（使用者 2026-11-12）")
    check(alt("fencing_01_24", 211, 210) == "fencing_01_24" and alt("fencing_01_25", 210, 210) == "fencing_01_25",
        "鐵絲網不換：另一張（25）是原版建造配方的圖，配方的圖只收地板與地面覆蓋（使用者 2026-10-31）")
    check(alt("fencing_01_32", 211, 210) == "fencing_01_32", "另一張（33）不在圖塊表：照原圖")
    check(alt("fencing_01_16", 211, 210) == "fencing_01_16" and alt("packfence_01_8", 211, 210) == "packfence_01_8",
        "不在名單的柵欄（原版其他柵欄、圖塊包的同號圖）不換")
    Rules.addLuaSprites({ "fencing_01_35" })
    check(alt("fencing_01_64", 211, 210) == "fencing_01_64" and alt("fencing_01_34", 211, 210) == "fencing_01_34",
        "另一張自己不能蓋（別的 MOD 的配方佔走、addLuaSprites 排除）：照原圖，交替不繞過排除（審查 1107 Codex）")
    local code, arg, a25 = Entry.why("fencing_01_25")
    check(code == "ENTITY" and arg == "MetalSmallWireFence" and a25 == nil, "挑到建造配方的那張（25）：說明照舊，不給另一張")

    -- 伺服器：一個請求拖四格，北向一排、西向一排；放下的圖、builderEntry、退料表照每格自己的那張
    for x = 208, 216 do for y = 208, 216 do square(x, y, 0) end end
    local P = player({ id = 4001, x = 212.5, y = 213.5 })
    P.inv:add(item("Base.Hammer", { HAMMER = true }))
    give(P, { ["Base.Plank"] = 60, ["Base.Nails"] = 60 })
    local function row(n, e, cells)
        local flat = {}
        for _, c in ipairs(cells) do for k = 1, 3 do flat[#flat + 1] = c[k] end flat[#flat + 1] = 0 end
        sent = {}
        Server.intent(P, { n = n, e = e, c = flat, v = Entry.digest() })
        local names = {}
        for i, c in ipairs(cells) do
            P.pos.x, P.pos.y = c[1] + 0.5, c[2] + 0.5 -- 角色先走到那一格（Client.build 照樣先走過去）
            Server.complete(P, n, i)
            local o = squares[c[1] .. "," .. c[2] .. ",0"].objects[1]
            names[i] = o and o:getSprite() and o:getSprite():getName() or "-"
            if o and o:getModData().builderEntry ~= names[i] then names[i] = names[i] .. "!md" end
        end
        return table.concat(names, ",")
    end
    local north = { { 210, 210, 0 }, { 211, 210, 0 }, { 212, 210, 0 }, { 213, 210, 0 } }
    local west = { { 215, 210, 0 }, { 215, 211, 0 }, { 215, 212, 0 }, { 215, 213, 0 } }
    local nNames = row(4001, "fencing_01_8", north)
    local wNames = row(4002, "fencing_01_11", west)
    check(nNames == "fencing_01_8,fencing_01_9,fencing_01_8,fencing_01_9",
        "伺服器拖北向一排：8、9、8、9，builderEntry 是放下的那張（" .. nNames .. "）")
    check(wNames == "fencing_01_11,fencing_01_10,fencing_01_11,fencing_01_10",
        "伺服器拖西向一排（挑 B 片 11 也一樣照座標）：11、10、11、10（" .. wNames .. "）")
    local oA, oB = squares["210,210,0"].objects[1], squares["211,210,0"].objects[1]
    local same = oA ~= nil and oB ~= nil and next(oA.mats) ~= nil
    for ft, v in pairs(oA and oA.mats or {}) do same = same and oB.mats[ft] == v end
    for ft in pairs(oB and oB.mats or {}) do same = same and oA ~= nil and oA.mats[ft] ~= nil end
    check(same, "A、B 兩格的退料表一樣（屬性相同，成本相同）")
    local pNames = row(4003, "fencing_01_32", { { 210, 212, 0 }, { 211, 212, 0 } })
    check(pNames == "fencing_01_32,fencing_01_32", "另一張不在圖塊表：整排照原圖（" .. pNames .. "）")
    local wire = row(4005, "fencing_01_24", { { 210, 216, 0 }, { 211, 216, 0 } })
    check(wire == "fencing_01_24,fencing_01_24", "伺服器拖鐵絲網：整排照舊同一張（" .. wire .. "）")

    -- 預覽（Cursor.preview → Check.item）與游標虛影、排隊虛影：和伺服器同一張
    require "MinidoracatBuilder/Cursor"
    local Cursor = MinidoracatBuilder.Cursor
    local chain = { { 210, 214, 0, 0 }, { 211, 214, 0, 0 }, { 212, 214, 0, 0 } }
    local res = Cursor.preview(P, "fencing_01_8", 0, chain, nil)
    local pv = {}
    for i, r in ipairs(res) do pv[i] = (r.code or "") .. (r.cells and r.cells[1].spr:getName() or "-") end
    local sv = row(4004, "fencing_01_8", chain)
    check(table.concat(pv, ",") == "fencing_01_8,fencing_01_9,fencing_01_8" and sv == table.concat(pv, ","),
        "同三格：預覽每格都能蓋、和伺服器放下的同一張（8、9、8）：預覽 " .. table.concat(pv, ",") .. "／伺服器 " .. sv)
    local realCore, realCoreT = getCore, Core
    local color = { getR = function() return 1 end, getG = function() return 1 end, getB = function() return 1 end }
    getCore = function() return { getGoodHighlitedColor = function() return color end,
        getBadHighlitedColor = function() return color end } end
    Core = { getTileScale = function() return 1 end }
    local e8 = Entry.resolve("fencing_01_8")
    local cur = setmetatable({ character = P, name = e8.name, entry = e8, d = 0, canDrag = true, max = 32, offsBy = {},
        colors = { warning = color }, texts = function() end }, { __index = Cursor })
    cur.sides = Cursor.sides(e8, 0)
    local function ghosts()
        local out = {}
        for i = 1, cur.g.n do out[i] = cur.g.x[i] .. "," .. cur.g.y[i] .. "=" .. cur.g.spr[i]:getName():match("_(%d+)$") end
        return table.concat(out, " ")
    end
    cur:refresh(210, 215, 0, 213, 215)
    local line = ghosts()
    check(line == "210,215=9 211,215=8 212,215=9 213,215=8", "游標虛影拖一排北向：照座標交替（" .. line .. "）")
    cur:refresh(209, 209, 0, 210, 210)
    local ring = ghosts()
    check(ring == "209,209=8 210,209=9 211,209=10 211,210=11 210,211=9 209,211=8 209,210=11 209,209=10",
        "拉長方形圍一圈：北、南邊 8／9，西、東邊（配對面 10）10／11，各照自己的座標（" .. ring .. "）")
    cur.sides = { n = 0 } -- 西、東兩邊沒有那一面（NO_FACE）：游標那幾格只畫地框（審查 1107 Claude：交替那行收到 nil 丟錯）
    local okNF = pcall(cur.refresh, cur, 209, 209, 0, 210, 210)
    local drawn = 0
    for i = 1, cur.g.n do if cur.g.spr[i] ~= nil then drawn = drawn + 1 end end
    cur.sides = Cursor.sides(e8, 0)
    check(okNF and drawn == 4, "圍一圈時西、東邊沒有那一面（NO_FACE）：不丟錯，只畫北、南邊 4 格的虛影（" .. drawn .. "）")
    cur:refresh(210, 215, 0, 213, 215)
    local realSend, parts = Cursor.send, nil
    Cursor.send = function(_, _, _, p) parts = p end
    cur.kx, cur.ky, cur.kz = 210, 215, 0
    cur:tryBuild(210, 215, 0)
    Cursor.send, getCore, Core = realSend, realCore, realCoreT
    local q = {}
    for i, ps in ipairs(parts or {}) do q[i] = ps[1][4]:getName():match("_(%d+)$") end
    check(table.concat(q, ",") == "9,8,9,8", "送出後的排隊虛影也照座標交替：" .. table.concat(q, ","))
    -- 換層鍵：預設 PgUp／PgDn 時提示照翻譯原文；改了鍵換成實際鍵名，沒綁寫「-」；游標照綁的鍵換層
    local realCore2, realKeyName, realKb, realKid = getCore, getKeyName, Keyboard, KeybindId
    KeybindId = KeybindId or {}
    local binds = { MinidoracatBuilder_LayerUp = 201, MinidoracatBuilder_LayerDown = 209 }
    local alts = {} -- 替代鍵：getKey 只回主鍵，isKey 兩個都認（Core.java:2405-2416）
    Keyboard = { KEY_PRIOR = 201, KEY_NEXT = 209 }
    getKeyName = function(k) return "K" .. k end
    getCore = function() return { getKey = function(_, name) return binds[name] or 0 end,
        isKey = function(_, name, k) return type(name) == "string" and (binds[name] == k or alts[name] == k) end } end
    check(Cursor.keyText("PgUp a PgDn") == "PgUp a PgDn", "換層鍵是預設：提示不動")
    binds.MinidoracatBuilder_LayerUp, binds.MinidoracatBuilder_LayerDown = 19, 0
    check(Cursor.keyText("PgUp a PgDn") == "K19 a -", "改了鍵：提示寫實際鍵名，沒綁寫「-」")
    local lc = setmetatable({ entry = { kind = "roof" }, up = false }, { __index = Cursor })
    lc:rotateKey(201)
    local stay = lc.up
    lc:rotateKey(19)
    check(stay == false and lc.up == true, "游標照綁的鍵換層：舊的 PgUp 不再有用，新鍵換到上一層")
    alts.MinidoracatBuilder_LayerDown = 33
    lc:rotateKey(33)
    check(lc.up == false, "替代鍵也換層（照 isKey 比，不是只比 getKey 的主鍵）")
    getCore, getKeyName, Keyboard, KeybindId = realCore2, realKeyName, realKb, realKid
    sb.MaxCellsPerDrag = realMax
end)()

print("情境四十一：2026-11-07 Workshop 回饋：五個 tileset 的價錢、不能搬的燈收燈泡（燈泡還在才退）、牆型窗＝窗框＋窗")
;(function()
    nowMs = nowMs + 180000
    local Dismantle, Ledger = MinidoracatBuilder.Dismantle, MinidoracatBuilder.Ledger
    local PANEL, PLANK, NAILS, BAR = "Base.GlassPanel", "Base.Plank", "Base.Nails", "Base.MetalBar"
    local BULB, PIPE, ES, EW = "Base.LightBulb", "Base.MetalPipe", "Base.ElectronicsScrap", "Base.ElectricWire"
    local function spr(name, o) return sprite(name, 4100, o) end
    local function c(kind, name, o, mult) return Cost.of(kind, spr(name, o), mult) end
    local function only(items, want) -- items 剛好是 want
        for ft, n in pairs(items) do if want[ft] ~= n then return false end end
        for ft, n in pairs(want) do if items[ft] ~= n then return false end end
        return true
    end
    local function tools(cost) return table.concat(cost.tools, "+") end
    local function skill(kind, name, o) local p, lv = Cost.skillOf(kind, spr(name, o)) return tostring(p) .. tostring(lv) end
    local WALLW = { flags = { "WallW" }, keys = { WallW = "" } }

    -- 玻璃屋頂（照圖名列）：木板換玻璃板，釘子、鐵鎚、技能照舊；同一個 tileset 別的屋頂照舊
    local roof = c("roof", "roofs_30_04_7", { type = T.WestRoofB })
    check(only(roof.items, { [PANEL] = 1, [NAILS] = 2 }) and tools(roof) == "HAMMER"
        and skill("roof", "roofs_30_04_7", {}) == "Woodwork2", "玻璃屋頂（roofs_30_04 整套）：玻璃板 1＋釘子 2、鐵鎚、木工 2")
    check(only(c("roof", "roofs_02_38", { flags = { "isEave" } }).items, { [PANEL] = 1, [NAILS] = 1 })
        and only(c("floor", "roofs_02_54", { flags = { "solidfloor" } }).items, { [PANEL] = 1, [NAILS] = 1 })
        and only(c("roof", "roofs_shallow_01_119", {}).items, { [PANEL] = 1, [NAILS] = 2 }),
        "roofs_02 RoofGroup=4 的屋簷、透明平面片，roofs_shallow_01_96..119：照屋簷、地板價把木板換玻璃板")
    check(only(c("roof", "roofs_02_31", {}).items, { [PLANK] = 1, [NAILS] = 2 })
        and only(c("roof", "roofs_shallow_01_95", {}).items, { [PLANK] = 1, [NAILS] = 2 }), "名單外的屋頂照舊收木板")

    -- 路燈：光桿照金屬；不能搬的路燈另收鐵管 2、燈泡 1，都不給經驗；能搬的照舊
    local pole = c("solid", "lighting_outdoor_01_4", {})
    check(only(pole.items, { ["Base.SmallSheetMetal"] = 2 }) and tools(pole) == "BLOW_TORCH+WELDING_MASK"
        and skill("solid", "lighting_outdoor_01_4", {}) == "MetalWelding3", "光桿：照金屬（小鐵板 2、噴槍＋面罩、焊接 3）")
    local LIT = { type = T.lightswitch, keys = { lightR = "200", lightG = "200", lightB = "150" } }
    local street = c("light", "lighting_outdoor_01_0", LIT)
    check(only(street.items, { [ES] = 1, [EW] = 1, [BULB] = 1, [PIPE] = 2 }) and tools(street) == "SCREWDRIVER"
        and street.uniform and next(Cost.xp({ street }, nil)) == nil,
        "不能搬的路燈：電子零件 1＋電線 1＋燈泡 1＋鐵管 2、螺絲起子；鐵管、燈泡不給經驗")
    check(only(c("light", "lighting_outdoor_tk_01_12", LIT).items, { [ES] = 1, [EW] = 1, [BULB] = 1, [PIPE] = 2 }),
        "UMCTP 的 lighting_outdoor_tk_01 一樣收鐵管")
    check(only(c("light", "lighting_outdoor_01_0", LIT, 0).items, { [BULB] = 1 }), "倍率 0：燈泡照 1 收，鐵管照倍率免")
    local sign = c("light", "signs_one-off_01_3", LIT)
    check(only(sign.items, { [ES] = 1, [EW] = 1, [BULB] = 1 }) and sign.perkOf[BULB] == false,
        "不能搬的招牌燈：也收燈泡 1、不給經驗，不收鐵管")
    local MOVE = { type = T.lightswitch, keys = { lightR = "200", lightG = "200", lightB = "150", IsMoveAble = "" } }
    check(only(c("light", "lighting_outdoor_01_24", MOVE).items, { [ES] = 1, [EW] = 1, [BULB] = 1 }),
        "能搬的燈照舊（燈泡 1，路燈 tileset 的也不收鐵管）")

    -- 商場：玻璃欄杆、磚、門框改對；柱 _27 照牆價不動
    world({ spr("location_shop_mall_01_18", { flags = { "WallWTrans" }, keys = { WallWTrans = "", MaterialType = "Metal_Light" } }),
        spr("location_shop_mall_01_0", { flags = { "WallW" }, keys = { WallW = "", MaterialType = "Cinderblock" } }) })
    local rail = c("fence", "location_shop_mall_01_58", {})
    check(only(rail.items, { [PANEL] = 1, [BAR] = 1 }) and tools(rail) == "BLOW_TORCH+WELDING_MASK"
        and only(c("fence", "location_shop_mall_01_26", { keys = { MaterialType = "Glass" } }).items, { [PANEL] = 1, [BAR] = 1 })
        and skill("fence", "location_shop_mall_01_58", {}) == "MetalWelding3",
        "商場玻璃欄杆（有沒有寫 MaterialType=Glass 都一樣）：玻璃板 1＋鐵條 1、噴槍＋面罩、焊接 3")
    local low, planter = c("fence", "location_shop_mall_01_56", {}), c("solid", "location_shop_mall_01_28", {})
    check(only(low.items, { ["Base.ClayBrick"] = 2 }) and only(planter.items, { ["Base.ClayBrick"] = 2 })
        and tools(low) == "MASONS_TROWEL", "商場磚矮牆、花台：紅磚 2、抹刀")
    local frame = c("doorFrame", "location_shop_mall_01_16", { keys = { DoorWallW = "" } })
    check(only(frame.items, { ["Base.ClayBrick"] = 4 }) and tools(frame) == "MASONS_TROWEL",
        "商場白牆門框 16：不再照同一套繼承算到鐵柵牆 18 的金屬，照牆 0–2 的煤渣磚收紅磚 4")
    check(only(c("post", "location_shop_mall_01_27", { keys = { MaterialType = "Glass" } }).items, { [PLANK] = 4, [NAILS] = 6 }),
        "商場玻璃柱 _27：照牆價不動（木板 4＋釘子 6）")

    -- 店面玻璃牆（原版寫 MaterialType=Glass）：金屬牆框＋玻璃板 4；硬核耗材照牆框
    local GW = { flags = { "WallW" }, keys = { WallW = "", MaterialType = "Glass" } }
    local gw = c("wall", "walls_commercial_01_18", GW)
    sb.RecipeMaterials = true
    local gwHard = c("wall", "walls_commercial_01_18", GW)
    sb.RecipeMaterials = nil
    check(only(gw.items, { [PANEL] = 4, [BAR] = 3 }) and tools(gw) == "BLOW_TORCH+WELDING_MASK"
        and skill("wall", "walls_commercial_01_18", GW) == "MetalWelding3"
        and only(gwHard.uses, { [Cost.TORCH] = 1, [Cost.RODS] = 2 }),
        "店面玻璃牆：玻璃板 4＋鐵條 3、噴槍＋面罩、焊接 3；原版材料打開時噴槍 1、焊條 2（MetalWallFrame）")

    -- 圓木山牆：圓木 4、鐵鎚、照原版 LogWall 不要技能；窗框照拆解價不動（這裡沒有拆解定義，照同一套的木窗框）
    local log = c("wall", "walls_logs_16", WALLW)
    check(only(log.items, { ["Base.Log"] = 4 }) and tools(log) == "HAMMER" and Cost.skillOf("wall", spr("walls_logs_16", WALLW)) == nil
        and only(c("wall", "walls_logs_73", WALLW).items, { ["Base.Log"] = 4 }), "圓木山牆 16–33、56–73：圓木 4、鐵鎚、不要技能")
    check(only(c("wall", "walls_logs_74", WALLW).items, { [PLANK] = 4, [NAILS] = 6 }), "名單外的照舊")

    -- 鐵欄杆：鐵條 2、噴槍＋面罩、焊接 3；柱 _39 照牆價不動；拆除工具跟著換（和蓋的時候一樣）
    local iron = c("fence", "fixtures_railings_01_16", {})
    check(only(iron.items, { [BAR] = 2 }) and tools(iron) == "BLOW_TORCH+WELDING_MASK"
        and skill("fence", "fixtures_railings_01_38", {}) == "MetalWelding3", "全金屬欄杆：鐵條 2、噴槍＋面罩、焊接 3")
    check(only(c("post", "fixtures_railings_01_39", {}).items, { [PLANK] = 4, [NAILS] = 6 })
        and only(c("fence", "fixtures_railings_01_18", {}).items, { [PLANK] = 2, [NAILS] = 2 }),
        "欄杆柱 _39 照牆價不動；名單外的木欄杆照舊")
    local ironObj = { getSprite = function() return spr("fixtures_railings_01_16", {}) end }
    check(table.concat(Dismantle.tools("fence", { remove = { ironObj } }), "+") == "BLOW_TORCH+WELDING_MASK",
        "拆除工具和蓋的時候一樣：已經蓋好的鐵欄杆拆除也要噴槍＋面罩")

    -- 牆型窗（tiledef 寫 wall 型別）：同一族的窗框＋窗，技能取較高；一般的窗照舊
    local FW = { type = T.wall, flags = { "windowW" }, keys = { WindowW = "", MaterialType = "Glass" } }
    local fw = c("window", "walls_commercial_01_96", FW)
    check(only(fw.items, { [PANEL] = 4, [PLANK] = 6, [NAILS] = 10 }) and tools(fw) == "HAMMER"
        and skill("window", "walls_commercial_01_96", FW) == "Woodwork5",
        "牆型窗：木窗框（木板 4＋釘子 6）＋木窗（玻璃板 4＋木板 2＋釘子 4）、鐵鎚、木工 5")
    check(only(c("window", "fixtures_windows_01_40", { flags = { "windowW" }, keys = { MaterialType = "Glass" } }).items,
        { [PANEL] = 4, [PLANK] = 2, [NAILS] = 4 }), "一般的窗（型別不是 wall）照舊只收窗")

    -- 拆燈：帳本有燈泡、燈泡還在才退；0.5.0 以前的帳本沒有燈泡不退；預覽估的一樣
    local realInst = instanceof
    instanceof = function(o, cls) return type(o) == "table" and o.class == cls end
    for x = 200, 203 do
        local sq = square(x, 200, 0)
        sq.dropped = {}
        local orig = sq.transmitRemoveItemFromSquare
        function sq:transmitRemoveItemFromSquare(obj, safely)
            fire("OnObjectAboutToBeRemoved", obj)
            return orig(self, obj, safely)
        end
        function sq:AddWorldInventoryItem(ft) self.dropped[ft] = (self.dropped[ft] or 0) + 1 end
    end
    local here = squares["200,200,0"]
    local streetS = sprite("lighting_outdoor_01_0", 4101, LIT)
    local function lamp(x, mats)
        local sq = squares[x .. ",200,0"]
        local o = { class = "IsoLightSwitch", md = { builderEntry = streetS:getName() }, keyId = -1 }
        function o:getSprite() return streetS end
        function o:getSquare() return sq end
        function o:hasModData() return true end
        function o:getModData() return self.md end
        function o:getKeyId() return self.keyId end
        function o:setKeyId(v) self.keyId = v end
        function o:getProperties() return streetS:getProperties() end
        function o:getTextureName() return streetS:getName() end
        function o:getType() return streetS:getType() end
        function o:isObjectNoContainerOrEmpty() return true end
        function o:getSpriteGridObjectsIncludingSelf() return javaList({ self }) end
        function o:isConnectedSpriteGridObject(x2) return x2 == self end
        function o:isStairsObject() return false end
        function o:hasFluid() return false end
        function o:isBarricaded() return false end
        function o:getContainerCount() return 0 end
        function o:hasLightBulb() return self.bulb ~= false end
        sq.objects[#sq.objects + 1] = o
        Ledger.put(o, mats)
        return o
    end
    local P = player({ id = 4101, x = 200.5, y = 200.5, here = here })
    P.inv:add(item("Base.Screwdriver", { SCREWDRIVER = true }))
    local nonce = 4100
    local function unbuild(o)
        nonce = nonce + 1
        sent, here.dropped = {}, {}
        Server.dismantleIntent(P, { n = nonce, t = { o:getSquare():getX(), 200, 0, streetS:getName() } })
        Server.dismantle(P, nonce, 1)
        return sent[#sent] and sent[#sent].cmd
    end
    HARNESS_ROLL = "max"
    local NEW = { [ES] = 1, [EW] = 1, [BULB] = 1, [PIPE] = 2 }
    local A = lamp(201, NEW)
    local estA = Dismantle.estimateRefund(A, "light")
    check(unbuild(A) == "dismantled" and here.dropped[BULB] == 1 and here.dropped[PIPE] == 2 and estA[BULB] == 1,
        "拆不能搬的燈、燈泡還在：退燈泡（預覽估的也有）")
    local B = lamp(202, NEW)
    B.bulb = false
    local estB = Dismantle.estimateRefund(B, "light")
    check(unbuild(B) == "dismantled" and here.dropped[BULB] == nil and here.dropped[PIPE] == 2 and estB[BULB] == nil
        and estB[PIPE] == 2 and Ledger.get(B) == nil, "燈泡不在了（被拿走、燒掉）：其他照退，不退燈泡；預覽估的一樣")
    local C0 = lamp(203, { [ES] = 1, [EW] = 1 })
    check(unbuild(C0) == "dismantled" and here.dropped[BULB] == nil and here.dropped[EW] == 1,
        "0.5.0 以前蓋的燈（帳本沒有燈泡）：燈泡還在也不退")
    instanceof = realInst
end)()

print("情境三十九：地下室 MOD（Basement Building）外邊土牆：可蓋實牆、開口／框／同圖被擋、蓋好拆土牆；沒裝或出錯照舊 BLOCKED")
;(function()
    nowMs = nowMs + 180000
    local Place = MinidoracatBuilder.Place
    local realS, realC = isServer, isClient
    isServer, isClient = function() return true end, function() return false end
    local function sp(name, id, flags)
        local keys = {}
        for _, f in ipairs(flags) do if f:match("^[A-Z]") then keys[f] = "" end end
        return sprite(name, id, { flags = flags, keys = keys })
    end
    local wallN, wallW = sp("bd_wall_01_1", 3901, { "WallN" }), sp("bd_wall_01_0", 3902, { "WallW" })
    local frameN = sp("bd_frame_01_1", 3903, { "WindowN" }) -- 窗框（開口）
    local transN = sp("bd_wframe_01_1", 3904, { "WallNTrans" }) -- 牆框（只有透明牆鍵）
    local dirtN, dirtW = sp("underground_01_9", 3905, { "WallN" }), sp("underground_01_8", 3906, { "WallW" })
    local woodN = sp("bd_wood_01_25", 3907, { "WallN" }) -- 它挖的地下室外邊的木牆（不是土牆）
    local tdoorN = sp("bd_tdoor_01_1", 3908, { "DoorWallNTrans" }) -- 透明門框（只有字串鍵，它的 edgesOf 不認）
    world({ wallN, wallW, frameN, transN, dirtN, dirtW, woodN, tdoorN })
    -- 假的它（aparosa_BD_DirtLayer 1.6.9 的 6 支，照原檔的判斷縮寫）：outer＝外邊（"x,y,z,N|W"）
    local outer, calls, cleared = {}, 0, {}
    local DIRT = { underground_01_9 = "N", underground_01_8 = "W" }
    local function isOuter(x, y, z, k)
        calls = calls + 1
        return outer[x .. "," .. y .. "," .. z .. "," .. k] == true
    end
    local function sqOuter(sq, k) return isOuter(sq:getX(), sq:getY(), sq:getZ(), k) end
    local function flagged(name, list)
        local p = spriteMap[name]:getProperties()
        for _, k in ipairs({ "N", "W" }) do
            for _, f in ipairs(list[k]) do
                if p:has(F[f]) then return k end
            end
        end
        return nil
    end
    local OPEN = { N = { "WindowN", "DoorWallN", "HoppableN", "TallHoppableN", "WallNTrans", "doorN" },
        W = { "WindowW", "DoorWallW", "HoppableW", "TallHoppableW", "WallWTrans", "doorW" } }
    local function dirtOn(sq, k)
        for _, o in ipairs(sq.objects) do
            local s = o.getSprite and o:getSprite()
            if s and DIRT[s:getName()] == k then return true end
        end
        return false
    end
    local BD = {
        isOuterEdge = isOuter,
        isDirtOnOuterEdge = function(o)
            local k = DIRT[o:getSprite():getName()]
            return k ~= nil and sqOuter(o:getSquare(), k)
        end,
        isOpeningOnOuterEdge = function(sq, name)
            local k = flagged(name, OPEN)
            return k ~= nil and sqOuter(sq, k)
        end,
        isFrameOnDirt = function(sq, name)
            local k = flagged(name, { N = { "WallNTrans" }, W = { "WallWTrans" } })
            return k ~= nil and not flagged(name, { N = { "WallN" }, W = { "WallW" } }) and sqOuter(sq, k) and dirtOn(sq, k)
        end,
        isDirtLookOnOuterEdge = function(sq, name) return DIRT[name] ~= nil and sqOuter(sq, DIRT[name]) end,
        clearDirt = function(sq, k)
            cleared[#cleared + 1] = sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ() .. "," .. k
            for i = #sq.objects, 1, -1 do
                local s = sq.objects[i].getSprite and sq.objects[i]:getSprite()
                if s and DIRT[s:getName()] == k then table.remove(sq.objects, i) end
            end
        end,
    }
    local function piece(sq, spr)
        local o = {}
        function o:getSprite() return spr end
        function o:getProperties() return spr:getProperties() end
        function o:getSquare() return sq end
        function o:hasModData() return false end
        sq.objects[#sq.objects + 1] = o
        return o
    end
    -- z＝−1 的一格：有地板、邊上一件 spr（格子屬性照它）；k 給了就是外邊
    local function cell(x, y, spr, k)
        local f = {}
        if spr then for _, n in ipairs({ "WallN", "WallW" }) do if spr:getProperties():has(F[n]) then f[n] = true end end end
        local sq = square(x, y, -1, { floor = {}, flags = f })
        if spr then piece(sq, spr) end
        if k then outer[x .. "," .. y .. ",-1," .. k] = true end
        return sq
    end
    local function has(sq, name)
        for _, o in ipairs(sq.objects) do
            local s = o.getSprite and o:getSprite()
            if s and s:getName() == name then return true end
        end
        return false
    end
    local P = player({ id = 3901, x = 393.5, y = 391.5, z = -1, cheat = true })
    local function fits(kind, spr, sq)
        local ok, fine = pcall(Place.check, kind, spr, sq, P)
        return ok and fine == true, ok
    end

    aparosa_BD_DirtLayer = BD
    local sqN, sqW = cell(390, 390, dirtN, "N"), cell(391, 390, dirtW, "W")
    check(fits("wall", wallN, sqN) and fits("wall", wallW, sqW), "有它：外邊土牆那條邊（北、西）可蓋實牆")
    local sqE = cell(392, 390, nil, "N") -- 外邊、土牆已經拆了（上面蓋過別的又拆掉前）
    check(not fits("windowFrame", frameN, sqN) and not fits("wall", transN, sqN) and not fits("wall", dirtN, sqE)
        and fits("wall", wallN, sqE), "有它：外邊不准蓋窗框（開口）、牆框、和土牆同一張圖的牆；同一條邊的實牆照樣蓋")
    check(not fits("wall", wallN, cell(393, 390, dirtN)), "有它：不是外邊的土牆照舊擋")
    check(not fits("wall", wallN, cell(394, 390, woodN, "N")), "有它：外邊上它的木牆（不是土牆）照舊擋")
    check(not fits("doorFrame", tdoorN, cell(399, 390, dirtN, "N")),
        "有它：外邊的透明門框（它的 edgesOf 不認、蓋了它不補回土牆）：土牆照舊擋（審查 1107 Claude）")
    local before = calls
    fits("wall", wallN, square(396, 390, 0))
    check(calls == before, "z ≥ 0 不問它（地上不多花）")

    local ok, cmd, a = build(P, 3901, "bd_wall_01_1", { 390, 390, -1 })
    check(ok and cmd == "placed" and cleared[1] == "390,390,-1,N" and #cleared == 1 and has(sqN, "bd_wall_01_1")
        and not has(sqN, "underground_01_9"), "蓋好之後照它的規則拆那條邊的土牆（clearDirt(sq, \"N\")），本工具的牆在")
    local sqF = cell(398, 390, dirtN, "N")
    ok, cmd, a = build(P, 3902, "bd_frame_01_1", { 398, 390, -1 })
    check(not ok and a.code == "BLOCKED" and #cleared == 1 and has(sqF, "underground_01_9") and not has(sqF, "bd_frame_01_1"),
        "伺服器：外邊的窗框回 BLOCKED、土牆留著")
    local sqW2 = cell(395, 390, dirtW, "W")
    failAdd = true
    ok, cmd, a = build(P, 3903, "bd_wall_01_0", { 395, 390, -1 })
    failAdd = false
    check(not ok and a.code == "INTERNAL" and #cleared == 1 and has(sqW2, "underground_01_8") and not has(sqW2, "bd_wall_01_0"),
        "蓋到一半出錯：拆回本工具的牆（Place.undo），不拆土牆")
    BD.clearDirt = function() error("renamed inside") end
    local P2 = player({ id = 3910, x = 395.5, y = 391.5, z = -1 }) -- 沒開作弊：真的要扣料（審查 1107 Codex 第 2 輪）
    P2.inv:add(item("Base.Hammer", { HAMMER = true }))
    give(P2, { ["Base.Plank"] = 4, ["Base.Nails"] = 6 })
    xpLog = {}
    ok, cmd, a = build(P2, 3904, "bd_wall_01_0", { 395, 390, -1 })
    check(not ok and a.code == "INTERNAL" and not has(sqW2, "bd_wall_01_0") and has(sqW2, "underground_01_8")
        and P2.inv:count("Base.Plank") == 4 and P2.inv:count("Base.Nails") == 6 and #xpLog == 0,
        "clearDirt 丟錯：和蓋到一半出錯一樣撤回本工具的牆、回 INTERNAL，不扣料、不給經驗，土牆留著（審查 1107 Codex）")
    BD.clearDirt = function() end
    check(fits("wall", wallW, sqW2),
        "clearDirt 丟錯不停用它：只有伺服器跑得到那裡，停用了兩端就判斷不一樣（審查 1107 Claude 第 2 輪）")

    local sqN2 = cell(397, 390, dirtN, "N")
    aparosa_BD_DirtLayer = nil
    local fine, noErr = fits("wall", wallN, sqN2)
    ok, cmd, a = build(P, 3905, "bd_wall_01_1", { 397, 390, -1 })
    check(not fine and noErr and not ok and a.code == "BLOCKED", "沒裝它：外邊土牆照舊擋，伺服器回 BLOCKED")
    aparosa_BD_DirtLayer = BD
    BD.clearDirt = nil
    fine, noErr = fits("wall", wallN, sqN2)
    check(not fine and noErr, "它的函式不在（改名）：照沒裝它，照舊擋")
    BD.clearDirt = function() end
    local boom = 0
    BD.isOuterEdge = function() boom = boom + 1 error("boom") end
    fine, noErr = fits("wall", wallN, sqN2)
    local before2 = calls
    local again = fits("wall", wallW, sqW2)
    check(not fine and noErr and not again and boom == 1 and calls == before2,
        "它的判斷丟錯：照沒裝它，照舊擋、不丟出去；同一份之後別格也不再呼叫它（只丟一次，審查 1107 Grok）")
    aparosa_BD_DirtLayer = nil
    isServer, isClient = realS, realC
end)()

print("情境四十二：建造配方項目（2026-11-09 設計稿 4dy0caYOlmPY 選 all／mix／kinds／tile）：清單與篩法、頁籤、搜尋、最愛、整套、開原版游標")
;(function()
    local B = MinidoracatBuilder
    local W, Recipes, Names = B.Window, B.Recipes, B.Names
    local realSpecific, realCell, realInfos, realGetText = getSpecificPlayer, getCell, SpriteConfigManager.GetObjectInfoList, getText
    local realJoy = JoypadState
    JoypadState = { players = {} } -- 沒有手把玩家（Recipes.build 看它決定拖不拖）
    -- 拖一排的假原版（下面 ISBuildIsoEntity 那段用）：虛影圖記每次畫的位置與顏色
    local ghosts, badSq, vanillaRender, tried, walkFail = {}, {}, {}, {}, false
    local function ghostSprite(name)
        return { name = name, RenderGhostTileColor = function(_, x, y, z, a, b, c, d, e, f, g)
            ghosts[#ghosts + 1] = { name = name, x = x, y = y, args = { a, b, c, d, e, f, g } }
        end }
    end
    local realDoing, realOnEnd = ISTimedActionQueue.isPlayerDoingAction, Recipes.onEnd
    getText = function(k, ...)
        local a = { ... }
        if #a == 0 then return k end
        return k .. "(" .. table.concat(a, ",") .. ")"
    end
    local ES = { "EntityScript" }
    world({ sprite("rcp_walls_01_0", 4201, { flags = ES, keys = { WallN = "" } }),
        sprite("rcp_walls_01_4", 4202, { flags = ES, keys = { WallN = "" } }),
        sprite("rcp_walls_01_8", 4203, { flags = ES, keys = { WindowN = "" } }),
        sprite("rcp_walls_01_16", 4204, { flags = { "WallN" }, keys = { WallN = "" } }), -- 本工具目錄的牆，同一個 tileset
        sprite("rcp_barrel_01_0", 4205, { flags = ES, keys = { IsWaterCollector = "" } }),
        sprite("rcp_barrel_01_1", 4206, { flags = ES, keys = { IsWaterCollector = "" } }),
        sprite("rcp_floor_01_0", 4207, { flags = { "EntityScript", "solidfloor" } }),
        sprite("rcp_metal_01_0", 4208, { flags = ES, keys = { WallN = "" } }),
        sprite("neat_bench_01_0", 4209, { flags = ES, keys = { IsMoveAble = "" } }),
        sprite("rcp_chair_01_0", 4210, { keys = { IsMoveAble = "" } }),
        sprite("rcp_coffee_01_0", 4211, { flags = ES }) }) -- 有功能、沒有建造配方的 entity（原版咖啡機這類）
    Index.reset()
    Index.add("wall", "rcp_walls_01_16", "rcp_walls_01", 16, 1)
    Index.add("furniture", "rcp_chair_01_0", "rcp_chair_01", 0, 1)
    for i = 1, Index.setName.n do Index.addSetKey(i, "") end
    sb.DisabledSources, sb.DisabledTilesets = "", ""
    W.playerNum = 0

    ResourceType = { Item = { name = "Item" } }
    local function input(name, need, keep, ok)
        local it = {}
        function it:getDisplayName() return name end
        function it:getFullName() return "Base." .. name end
        function it:getNormalTexture() return "tex:" .. name end
        local inp = { need = need, ok = ok, item = it }
        function inp:getResourceType() return ResourceType.Item end
        function inp:getPossibleInputItems() return javaList({ it }) end
        function inp:getIntAmount() return need end
        function inp:isKeep() return keep end
        return inp
    end
    local function recipe(full, o)
        local cr = { o = o }
        function cr:getScriptObjectFullType() return full end
        function cr:getName() return (full:match("%.(.*)$")) end
        function cr:getTranslationName() return o.label end
        function cr:getCategory() return o.cat end
        function cr:getModID() return o.mod or "pz-vanilla" end
        function cr:needToBeLearn() return o.learn == true end
        function cr:getOnAddToMenu() return o.onAdd end
        function cr:canBeDoneInDark() return o.inDark == true end
        function cr:getIconTexture() return "icon:" .. full end
        function cr:getInputs() return javaList(o.inputs or {}) end
        function cr:getRequiredSkillCount() return #(o.skills or {}) end
        function cr:getRequiredSkill(i)
            local s = o.skills[i + 1]
            return { getPerk = function() return s[1] end, getLevel = function() return s[2] end }
        end
        function cr:getToolRight() return o.right end
        function cr:getToolLeft() return nil end
        function cr:getToolBoth() return nil end
        return cr
    end
    local hammer = input("Hammer", 1, true, true)
    local rWall = recipe("Base.WoodWall", { label = "Wood Wall", cat = "Carpentry", skills = { { "Woodwork", 2 } },
        inputs = { input("Plank", 4, false, true), hammer }, right = hammer })
    local rFrame = recipe("Base.WoodFrame", { label = "Window Frame", cat = "Carpentry", onAdd = "tierOk" })
    local rBarrel = recipe("Base.RainCollector_Tarp", { label = "Rain Collector (Tarp)", cat = "Outdoors", can = false,
        inputs = { input("Tarp", 1, false, false) } })
    local rFloor = recipe("Base.WoodFloor", { label = "Wood Floor", cat = "Carpentry" })
    local rLearn = recipe("Base.MetalWall", { label = "Metal Wall", cat = "Welding", learn = true })
    local rTier = recipe("Base.WoodWallLvl2", { label = "Wood Wall Lvl2", cat = "Carpentry", onAdd = "tierNo" })
    local rPaint = recipe("Base.PaintWall", { label = "Paint Wall", cat = "Wall Coverings" })
    local rOdd = recipe("Base.Mystery", { label = "Mystery", cat = "Miscellaneous" })
    local rMod = recipe("Neat.Bench", { label = "Neat Bench", cat = "Furniture", mod = "Neat_Building" })
    -- 面 0（北）、1（西）：左上那格的圖照 names 的順序（只有一張就同一張）
    local function info(cr, names, w, h)
        local function face(f)
            local tile = { getSpriteName = function() return names[f + 1] or names[1] end }
            return { getWidth = function() return w end, getHeight = function() return h end, getTileInfo = function() return tile end }
        end
        local faces = { [0] = face(0), [1] = face(1) }
        local script = { getAllTileNames = function() return javaList(names) end, getCornerSprite = function() return nil end }
        return { getScript = function() return script end, getRecipe = function() return { getCraftRecipe = function() return cr end } end,
            getFace = function(_, f) return faces[f] end }
    end
    local infos = { info(rWall, { "rcp_walls_01_0" }, 1, 1), info(rFrame, { "rcp_walls_01_8" }, 1, 1),
        info(rBarrel, { "rcp_barrel_01_0", "rcp_barrel_01_1" }, 2, 1), info(rFloor, { "rcp_floor_01_0" }, 1, 1),
        info(rLearn, { "rcp_metal_01_0" }, 1, 1), info(rTier, { "rcp_walls_01_4" }, 1, 1), info(rMod, { "neat_bench_01_0" }, 1, 1) }
    SpriteConfigManager.GetObjectInfoList = function() return javaList(infos) end
    local all = { rWall, rFrame, rBarrel, rFloor, rLearn, rTier, rPaint, rOdd, rMod }
    local invVer = 1 -- 容器裡的東西每變一次加一；每個 logic 記自己看過的版本（setContainers 回有沒有變）
    BuildLogic = { new = function(player)
        local L = { player = player, listeners = {} }
        function L:getAllBuildableRecipes() self.scanned = true return javaList(all) end
        function L:setManualSelectInputs(b) self.manual = b end
        function L:setContainers() -- 東西變了：原版清掉配方快取（BaseCraftingLogic.java:617）
            local changed = self.ver ~= invVer
            self.ver = invVer
            if changed then self.cache = nil end
            return changed
        end
        function L:setRecipes() self.cache = nil end -- :578
        function L:setRecipe(cr) self.cr, self.filled = cr, invVer end -- 原版 setRecipe 會 autoPopulateInputs
        function L:getRecipe() return self.cr end
        function L:getWallCoveringParams()
            if not self.scanned then error("NPE: getAllBuildableRecipes first") end -- BuildLogic.java:90-97
            if self.cr == rPaint then return { actionType = WallCoveringType.PAINT_THUMP, paintType = "PaintBlue" } end
            return nil
        end
        -- 照原版快取：canPerform 先查技能、學過與太暗（CraftRecipeData.canPerform，:753-754），之後容器變了或 setRecipes 才重算
        local function lit(L, cr) return cr:canBeDoneInDark() or not L.player:tooDarkToRead() end
        function L:getCachedRecipeInfo(cr)
            self.cache = self.cache or {}
            local c = self.cache[cr]
            if not c then
                local valid = CraftRecipeManager.isValidRecipeForCharacter(cr, self.player)
                local can = valid and cr.o.can ~= false and lit(self, cr)
                c = { isValid = function() return valid end, isCanPerform = function() return can end }
                self.cache[cr] = c
            end
            return c
        end
        function L:canPerformCurrentRecipe() return self.cr.o.can ~= false and lit(self, self.cr) end
        function L:addEventListener(ev, fn, target) self.listeners[#self.listeners + 1] = { ev, fn, target } end
        function L:stopCraftAction() -- 照 BuildLogic.java:246-250：先清掉進行中，再通知
            self.busy = false
            for _, l in ipairs(self.listeners) do if l[1] == "onStopCraft" then l[2](l[3]) end end
        end
        function L:isCraftActionInProgress() return self.busy == true end
        function L:getPossibleCraftCount() return self.poss or 100 end -- 材料夠做幾次（BaseCraftingLogic.java:1183-1196）
        function L:autoPopulateInputs() self.populated, self.filled = (self.populated or 0) + 1, invVer end
        function L:refresh() self.refreshed = (self.refreshed or 0) + 1 end
        function L:isInputSatisfied(inp) return inp.ok end
        -- 選進去的件數：setContainers 只留還在的、不補新的；setRecipe／autoPopulateInputs 才照現在的容器填
        function L:getInputCount(inp) return (inp.ok and self.filled == invVer) and inp.need or 0 end
        function L:getSatisfiedInputItems(inp) return javaList(inp.ok and { inp.item } or {}) end
        return L
    end }
    local P = { cheat = false, levels = { Woodwork = 1 } }
    function P:getPlayerNum() return 0 end
    function P:isBuildCheat() return self.cheat end
    function P:getPerkLevel(perk) return self.levels[perk] or 0 end
    function P:isRecipeKnown(cr) return not cr.o.learn or cr.o.learned == true end -- (recipe, true)：不看沙盒
    function P:tooDarkToRead() return self.dark == true end
    function P:getCurrentSquare() return nil end
    P.inv = {} -- 背包裡有的完整類型 → true
    function P:getInventory()
        return { getAllTypeEvalRecurse = function(_, ft)
            return javaList(P.inv[ft] and { { getFullType = function() return ft end } } or {})
        end }
    end
    getSpecificPlayer = function(pn) return pn == 0 and P or nil end
    PerkFactory = { getPerkName = function(perk) return "perk:" .. tostring(perk) end }
    local seeNotLearnt = false -- 沙盒「檢視未知配方」：hasPlayerLearnedRecipe 看它，isValidRecipeForCharacter 不看
    CraftRecipeManager = { hasPlayerLearnedRecipe = function(cr) return cr.o.learned == true or seeNotLearnt end,
        isValidRecipeForCharacter = function(cr, p) -- 先技能、再學過（不看沙盒；CraftRecipeManager.java:335-358）
            for _, s in ipairs(cr.o.skills or {}) do if p:getPerkLevel(s[1]) < s[2] then return false end end
            return p:isRecipeKnown(cr, true)
        end }
    local onAdd = { tierOk = true, tierNo = false }
    callLuaBool = function(f, t) return t.player == P and t.recipe ~= nil and onAdd[f] end
    ISInventoryPaneContextMenu = { getContainers = function() return javaList({}) end }
    WallCoveringType = { WALLPAPER = { name = "WALLPAPER" }, PAINT_THUMP = { toString = function() return "paintThump" end } }
    local drag = {}
    getCell = function()
        local c = realCell()
        c.getDrag = function(_, pn) return drag[pn] end
        -- 照引擎：換掉時先叫舊游標身上的 deactivate，再換、替新的記 player（IsoCell.java:2558-2573）
        c.setDrag = function(_, o, pn)
            local old = drag[pn]
            if old == o then return end
            if old and old.deactivate then old.deactivate(old) end
            drag[pn] = o
            if o then o.player = pn end
        end
        return c
    end
    -- 類別方法：本 MOD 掛在實例上的手把處理，A 以外要交回這裡（遊戲裡實例照 metatable 拿到類別的那支）
    ISBuildIsoEntity = { onJoypadPressButton = function(self, _, _, button) self.classPressed = button end }
    ISBuildIsoEntity.new = function(_, player, objectInfo, n, containers, logic)
        return setmetatable({ character = player, objectInfo = objectInfo, nSprite = n, containers = containers,
            buildPanelLogic = logic, dragNilAfterPlace = true, blockAfterPlace = false, spriteCache = {},
            tileSprite = ghostSprite("floor") }, { __index = ISBuildIsoEntity })
    end
    -- 拖一排用到的原版方法（ISBuildIsoEntity.lua、ISBuildingObject.lua 同名）：getSprite 設 north、getFace 照 nSprite 換面
    -- 並補 spriteCache、isValid 看 blockBuild 與 badSq、render 與 tryBuild 只記下來
    function ISBuildIsoEntity:getSprite() self.north = self.nSprite == 2 return nil end
    function ISBuildIsoEntity:getFace()
        local f = self.objectInfo:getFace(({ 1, 0, 3, 2 })[self.nSprite])
        local name = f and f:getTileInfo(0, 0, 0):getSpriteName()
        if name and not self.spriteCache[name] then self.spriteCache[name] = ghostSprite(name) end
        return f
    end
    function ISBuildIsoEntity:ensureSquaresExist() end
    function ISBuildIsoEntity:isValid(sq) return not self.blockBuild and not badSq[sq] end
    function ISBuildIsoEntity:render(x, y) vanillaRender[#vanillaRender + 1] = x .. "," .. y end
    function ISBuildIsoEntity:tryBuild(x, y, z)
        tried[#tried + 1] = { x, y, z, self.nSprite, north = self.north }
        if walkFail then self:onActionComplete() end -- 走不到：原版當場收尾（ISBuildingObject.lua:283-285）
    end
    ISPaintCursor = { new = function(_, player, action, args) return { character = player, action = action, args = args } end }
    ISTimedActionQueue.isPlayerDoingAction = function() return false end
    Recipes.list = nil
    Names.reset()

    local A = Recipes.all()
    local byId = Recipes.byId
    local barrel = byId["recipe:Base.RainCollector_Tarp"]
    check(A.n == 7 and barrel and barrel.kind == "furniture" and barrel.source == "vanilla" and not barrel.cover
        and Recipes.bySprite["rcp_barrel_01_1"] == barrel,
        "掃描：ID 是 recipe:＋配方全名；集雨桶分不出種類放家具；配方的每一張圖都對得到它")
    check(byId["recipe:Base.WoodWall"].kind == "wall" and byId["recipe:Base.WoodWall"].family == "rcp_walls"
        and byId["recipe:Base.WoodFrame"].kind == "windowFrame",
        "配方照主圖的屬性分種類（Rules.recipeKind），不跑「配方的圖不收」那一關")
    check(byId["recipe:Base.PaintWall"].cover and byId["recipe:Base.PaintWall"].kind == "wallOverlay"
        and byId["recipe:Neat.Bench"].source == "Neat_Building",
        "牆面油漆（沒有圖塊設定、有牆面參數）放牆面疊圖；MOD 的配方來源記那個 MOD")
    check(byId["recipe:Base.WoodFloor"] == nil and byId["recipe:Base.Mystery"] == nil,
        "反面：主圖本工具目錄已經列了的地板配方不另列（使用者選 tile）；沒有圖塊設定又不是牆面的不列")

    local shown = Recipes.shown(0)
    check(shown.list.n == 5 and not shown.set["recipe:Base.MetalWall"] and not shown.set["recipe:Base.WoodWallLvl2"]
        and shown.set["recipe:Base.WoodFrame"], "照原版篩：沒學過的、OnAddToMenu 回 false 的不列，回 true 的列")
    sb.KindWallOverlay = false
    check(not Recipes.shown(0).set["recipe:Base.PaintWall"], "管理員關掉的種類，配方也不列（使用者選 kinds）")
    sb.KindWallOverlay = nil
    Recipes.refresh(0) -- 建好視窗用的 logic
    local sig = Recipes.shown(0).sig
    rLearn.o.learned = true
    invVer = invVer + 1
    local moved, sig2 = Recipes.refresh(0)
    check(moved == true and sig2 ~= sig and Recipes.shown(0).set["recipe:Base.MetalWall"] and Recipes.refresh(0) == false,
        "Recipes.refresh：容器裡的東西變了回 true、沒變回 false；學會了就列出來、sig 跟著變")
    rLearn.o.learned = nil
    Recipes.refresh(0)

    local function st(o)
        local s = { query = "", tab = "all", cat = "all", source = "all", recent = { n = 0 } }
        for k, v in pairs(o or {}) do s[k] = v end
        return s
    end
    local L = W.filter(st())
    check(L.n == 7 and L[1] == "rcp_walls_01_16" and L[2] == "rcp_chair_01_0" and L[3] == "recipe:Neat.Bench"
        and L[7] == "recipe:Base.WoodWall", "全部頁：圖塊在前，配方接在後面、照顯示名（使用者 2026-11-12）")
    local fu = W.filter(st({ tab = "furniture" }))
    check(fu.n == 3 and fu[1] == "rcp_chair_01_0" and fu[2] == "recipe:Neat.Bench" and fu[3] == "recipe:Base.RainCollector_Tarp",
        "家具頁：集雨桶、MOD 的長椅（配方）和椅子（圖塊）")
    local wa = W.filter(st({ tab = "wall" }))
    check(wa.n == 3 and wa[1] == "rcp_walls_01_16" and wa[2] == "recipe:Base.PaintWall" and wa[3] == "recipe:Base.WoodWall",
        "牆頁：牆與牆面油漆的配方，窗框配方不在牆頁")
    local rc = W.filter(st({ tab = "furniture", cat = "r:Outdoors" }))
    check(rc.n == 1 and rc[1] == "recipe:Base.RainCollector_Tarp", "原版分類（r:Outdoors）：只列那個分類的配方")
    local nm = W.filter(st({ source = "Neat_Building" }))
    local va = W.filter(st({ tab = "furniture", source = "vanilla" }))
    check(nm.n == 1 and nm[1] == "recipe:Neat.Bench" and va.n == 2 and va[2] == "recipe:Base.RainCollector_Tarp",
        "來源：配方照定義它的 MOD；原版配方算原版")
    local q1, q2, q3 = W.filter(st({ query = "rain" })), W.filter(st({ query = "outdoors" })), W.filter(st({ query = "neat_b" }))
    check(q1.n == 1 and q2.n == 1 and q2[1] == q1[1] and q3.n == 1 and q3[1] == "recipe:Neat.Bench",
        "搜尋比顯示名、原版分類、來源")
    local ex, jump = W.filter(st({ tab = "wall", query = "rcp_barrel_01_1" }))
    check(jump == "recipe:Base.RainCollector_Tarp" and ex.n == 1, "完整圖塊名是配方的圖：選到那個配方項目（吸管、右鍵挑圖塊）")
    local hid, jumpHid = W.filter(st({ query = "rcp_metal_01_0" }))
    check(jumpHid == nil and hid.n == 0, "反面：看不到的配方（沒學過）的圖不跳")
    -- 空結果：看得到的配方的圖被「只看能蓋的」濾掉時說是那個勾選（審查 1109 Codex、Claude）；沒有建造配方的設施不叫人
    -- 去學配方（審查 1109 Claude）
    local realTON = getTextOrNull
    getTextOrNull = function(k, ...) if k:find("^IGUI_MBLD_Why_") then return getText(k, ...) end return nil end
    local t1 = W.emptyQuery("rcp_barrel_01_1")
    local _, h2 = W.emptyQuery("rcp_metal_01_0")
    local _, h3 = W.emptyQuery("rcp_coffee_01_0")
    getTextOrNull = realTON
    check(t1 == "IGUI_MBLD_Empty_Only" and h2 == "IGUI_MBLD_Why_ENTITY(?)" and h3 == "IGUI_MBLD_Why_ENTITY_NONE(?)",
        "空結果：看得到的配方的圖是被「只看能蓋的」濾掉；看不到的配方說原因；沒有建造配方的設施另一句")
    local fv = W.filter(st({ cat = "fav", fav = { n = 3, "recipe:Base.RainCollector_Tarp", "recipe:Base.MetalWall", "rcp_chair_01_0" } }))
    check(fv.n == 2 and fv[1] == "recipe:Base.RainCollector_Tarp" and fv[2] == "rcp_chair_01_0",
        "最愛：配方 ID 照看得到的列，看不到的略過（留在檔裡）")

    W.st.source = "all"
    local recG, kindsG
    for _, g in ipairs(W.categories("furniture")) do
        if g.title == "IGUI_MBLD_Group_Recipes" then recG = g end
        if g.title == "IGUI_MBLD_Group_Kinds" then kindsG = g end
    end
    local ids = {}
    for _, it in ipairs(recG and recG.items or {}) do ids[it.id] = it.label end
    check(recG and ids["r:Outdoors"] == "IGUI_MBLD_Count(IGUI_MBLD_Cat_Recipe(Outdoors),1)" and ids["r:Furniture"]
        and kindsG.items[1].label == "IGUI_MBLD_Count(IGUI_MBLD_Cat_All,3)",
        "分類：多一組原版分類（配方：戶外），全部的數量算進配方")
    local hasNeat = false
    for _, o in ipairs((W.sources())) do if o.id == "Neat_Building" then hasNeat = true end end
    check(hasNeat, "來源下拉：只有配方的 MOD 也列出")
    check(Names.of("recipe:Base.RainCollector_Tarp") == "Rain Collector (Tarp)" and Names.short("recipe:Neat.Bench") == "Neat Bench",
        "名稱：配方項目用原版的顯示名稱")

    local set = W.setOf("recipe:Base.WoodWall")
    check(set and set.list.n == 3 and set.list[1] == "rcp_walls_01_16" and set.list[2] == "recipe:Base.WoodFrame"
        and set.list[3] == "recipe:Base.WoodWall" and set.button == "IGUI_MBLD_SetTileset",
        "整套（同一組）：照主圖的 tileset 列同一組的圖塊和配方，圖塊在前")
    local setT = W.setOf("rcp_walls_01_16")
    check(setT and setT.list.n == 3 and setT.list[3] == "recipe:Base.WoodWall", "選圖塊的同一組也列同 tileset 的配方")
    check(W.setOf("recipe:Base.RainCollector_Tarp") == nil, "反面：不是牆類的配方沒有整套")

    local wall = byId["recipe:Base.WoodWall"]
    local valid, can = Recipes.state(0, wall)
    check(W.isShort(nil, wall.id) and not valid and not can, "能不能蓋：技能不夠算還缺（原版快取的 canPerform 也先查技能）")
    local need = Recipes.needs(0, wall)
    check(need.items[1].name == "Plank" and need.items[1].need == 4 and need.items[1].ok and need.tools[1].name == "Hammer"
        and need.skills[1].name == "perk:Woodwork" and need.skills[1].level == 2 and not need.skills[1].ok,
        "詳情：材料、用完還在的工具、技能（夠不夠照原版）")
    local tarp = rBarrel.o.inputs[1]
    local before = Recipes.needs(0, barrel).items[1].have
    tarp.ok = true
    invVer = invVer + 1
    Recipes.refresh(0)
    local after = Recipes.needs(0, barrel).items[1].have
    tarp.ok = false
    invVer = invVer + 1
    Recipes.refresh(0)
    check(before == 0 and after == 1,
        "詳情選著同一個配方時拿到材料：換容器後照原版重填，「有」的數量跟著變（審查 1109 Codex）")
    local metal = byId["recipe:Base.MetalWall"]
    check(Recipes.needs(0, metal).learned == false and Recipes.needs(0, wall).learned == true
        and W.tipOf({ dim = {} }, metal.id, true):find("IGUI_MBLD_Recipe_NotLearned", 1, true) ~= nil,
        "沒學會的配方：詳情與提示寫沒學會，不寫缺材料（審查 1109 Grok）")
    W.isShort(nil, wall.id) -- 原版快取記下升級前的判斷（前面換容器時清過）
    P.levels.Woodwork = 2
    local stale = W.isShort(nil, wall.id)
    local moved = Recipes.refresh(0)
    check(stale and moved == true and not W.isShort(nil, wall.id) and W.isShort(nil, barrel.id),
        "升級後（容器沒變）：Recipes.refresh 看到技能變了就清原版快取、回有變（視窗清缺料標示），不缺；集雨桶照樣缺")
    -- 「檢視未知配方」開著、沒學會的照列；只學會、背包與技能都沒變：原版快取的 canPerform 也查學過（審查 1109 第 2 輪 Codex）
    seeNotLearnt = true
    Recipes.refresh(0)
    local listedL, shortL = Recipes.shown(0).set[metal.id] ~= nil, W.isShort(nil, metal.id)
    rLearn.o.learned = true
    local movedL = Recipes.refresh(0)
    local _, canL = Recipes.state(0, metal)
    check(listedL and shortL and movedL == true and canL and not W.isShort(nil, metal.id),
        "學會配方（容器、技能沒變）：Recipes.refresh 清原版快取、回有變；不再標缺")
    rLearn.o.learned, seeNotLearnt = nil, false
    Recipes.refresh(0)
    -- 太暗：原版 canPerform 也先查（沒有 CanBeDoneInDark 標籤的配方），容器、技能都沒變也要清快取（審查 1109 第 2 輪 Claude）
    local litBefore = not W.isShort(nil, wall.id)
    P.dark = true
    local movedD = Recipes.refresh(0)
    check(litBefore and movedD == true and W.isShort(nil, wall.id) and Recipes.needs(0, wall).dark == true
        and W.tipOf({ dim = {} }, wall.id, true):find("IGUI_MBLD_Recipe_TooDark", 1, true) ~= nil,
        "變暗（容器、技能沒變）：Recipes.refresh 清原版快取、回有變；標缺，詳情與提示寫太暗")
    P.dark = false
    local movedLit = Recipes.refresh(0)
    check(movedLit == true and not W.isShort(nil, wall.id) and Recipes.needs(0, wall).dark == false,
        "亮回來：清快取、不缺，詳情不寫太暗")
    P.cheat = true
    check(not W.isShort(nil, barrel.id) and Recipes.needs(0, barrel).items[1].ok, "建造作弊（isBuildCheat）都算夠")
    P.cheat = false

    local ended
    Recipes.onEnd = function(pn) ended = pn end
    local ticks, step0 = count("OnTick"), clockStep
    clockStep = 0
    local o = Recipes.build(0, barrel.id)
    local BL = o and o.buildPanelLogic
    check(o and drag[0] == o and o.dragNilAfterPlace == false and o.blockAfterPlace == true and o.blockBuild == true
        and o.mbldRecipe and BL.cr == rBarrel and BL.manual == false and o.firstItem == nil
        and count("OnTick") == ticks + 1, "開原版游標：帶自己的 logic，材料不夠游標擋住；放完留著、跑完才再放")
    rBarrel.o.can = true
    invVer = invVer + 1
    fire("OnTick")
    local early = o.blockBuild
    nowMs = nowMs + 1000
    fire("OnTick")
    check(early == true and o.blockBuild == false and BL.populated == 1,
        "站著不動拿到材料：一秒內換容器、重填材料、游標解除（同原版背包一變就重建游標）")
    BL.busy = true
    nowMs = nowMs + 1000
    fire("OnTick")
    check(o.blockBuild == true, "放下後動作還在跑：游標擋住（同原版）")
    BL:stopCraftAction()
    check(o.blockBuild == false and BL.refreshed == 1, "動作跑完（onStopCraft）：用掉的材料換成還在的、重算擋不擋")
    P.inv["Base.Hammer"] = true
    local o2 = Recipes.build(0, "recipe:Base.WoodWall")
    check(o2 and o2.firstItem == "Base.Hammer" and o2.secondItem == nil and o2.equipBothHandItem == nil,
        "要拿在手上的工具照原版視窗：背包裡有的那件")
    check(o2 and drag[0] == o2 and o.replaced and ended == nil, "換成本 MOD 另一個游標：舊的不算結束，視窗不回來")
    -- 手把 A（42.22.2）：原版 DoTileBuilding 不替手把讀建造鍵、原版配方游標也不處理 A；本 MOD 開的實例自己設建造旗標
    local realJoypad = Joypad
    Joypad = { AButton = 1, BButton = 2 }
    local padSq = getCell():getGridSquare(58, 41, 0)
    o2.xJoypad, o2.yJoypad, o2.zJoypad = 58, 41, 0
    o2.isValid = function(_, sq) return sq == padSq end
    o2:onJoypadPressButton(0, {}, Joypad.AButton)
    local aBuild, aClass = o2.build, o2.classPressed
    o2:onJoypadPressButton(0, {}, Joypad.BButton)
    -- 油漆、壁紙游標：換了格，上一格選的第幾個物件要設回 1；沒換格照舊
    o2.objectIndex, o2.currentSquare = 2, getCell():getGridSquare(57, 41, 0)
    o2:onJoypadPressButton(0, {}, Joypad.AButton)
    local movedIdx, movedSq = o2.objectIndex, o2.currentSquare
    o2.objectIndex = 2
    o2:onJoypadPressButton(0, {}, Joypad.AButton)
    local stayIdx = o2.objectIndex
    o2.objectIndex, o2.currentSquare = nil, nil
    Joypad = realJoypad
    check(aBuild == true and aClass == nil and o2.classPressed == 2 and rawget(o2, "onJoypadPressButton") ~= nil
        and rawget(o2, "onJoypadPressButton") ~= ISBuildIsoEntity.onJoypadPressButton,
        "配方游標的手把 A：設建造旗標（下一幀照它蓋）、不交回原版；B 照原版處理；只掛在這個實例上")
    check(movedIdx == 1 and movedSq == padSq and stayIdx == 2,
        "油漆、壁紙游標的手把 A：換了格，選第幾個物件設回 1；同一格照舊（審查 1110 第 2 輪 Codex）")
    getCell():setDrag(nil, 0)
    check(ended == 0, "游標清掉（右鍵、手把 B）：視窗回來")
    fire("OnTick")
    check(count("OnTick") == ticks, "游標不在、動作也不在跑：不再追容器")
    rPaint.o.can = false
    local toasts, realToast = {}, B.Messages.toast
    B.Messages.toast = function(_, text) toasts[#toasts + 1] = text end
    local blockedPaint = Recipes.build(0, "recipe:Base.PaintWall")
    rPaint.o.can = nil
    P.dark = true
    local darkPaint = Recipes.build(0, "recipe:Base.PaintWall")
    P.dark = false
    B.Messages.toast = realToast
    check(blockedPaint == nil and darkPaint == nil and drag[0] == nil and toasts[1] == "IGUI_MBLD_Recipe_Blocked"
        and toasts[2] == "IGUI_MBLD_Recipe_TooDark",
        "反面：牆面油漆的技能、工具或材料不夠，或太暗：照原版建造鈕不開游標；通知寫缺什麼或太暗（審查 1109 Codex、第 2 輪 Claude）")
    local paint = Recipes.build(0, "recipe:Base.PaintWall")
    check(paint and paint.action == "paintThump" and paint.args.paintType == "PaintBlue" and paint.mbldRecipe and drag[0] == paint,
        "牆面油漆開原版的油漆游標")
    getCell():setDrag(nil, 0)

    -- 拖一排（使用者 2026-11-12：配方項目也能拖一排）：牆配方的游標掛上拖一排；按住拖畫整排（上限、擋住的格子、
    -- 材料夠做幾次），放開後一格接一格送原版 tryBuild；那格蓋好、佇列空了才送下一格；沒蓋好、材料不夠就停下並說
    local realBase, realCore, realQueue = ISBuildingObject, getCore, ISTimedActionQueue
    ISBuildingObject = { onActionComplete = function(self) self.buildPanelLogic:stopCraftAction() end,
        getFloorCursorSprite = function() return ghostSprite("queued") end }
    local function color(r, g, b) return { getR = function() return r end, getG = function() return g end, getB = function() return b end } end
    getCore = function()
        local c = realCore()
        c.getGoodHighlitedColor = function() return color(0, 1, 0) end
        c.getBadHighlitedColor = function() return color(1, 0, 0) end
        return c
    end
    local doing, cleared, current = false, 0, nil
    ISTimedActionQueue = { isPlayerDoingAction = function() return doing end,
        clear = function() -- 照原版：清佇列時正在跑的建造動作當場收尾（實測 builder-rdprobe-1112a 的 interrupt）
            cleared = cleared + 1
            local c = current
            current = nil
            if c then c:onActionComplete() end
        end }
    local Client = B.Client
    local toasts2, realToast2 = {}, B.Messages.toast
    B.Messages.toast = function(_, text, title) toasts2[#toasts2 + 1] = tostring(title) .. "|" .. text end
    local function place(x, y, name) -- 那格出現蓋好的牆
        local sq = getCell():getGridSquare(x, y, 0)
        sq.objects[#sq.objects + 1] = { getSprite = function() return { getName = function() return name end } end }
    end
    local function finish(o, x, y) -- 那格動作結束；x 有給＝蓋好了
        if x then place(x, y, "rcp_walls_01_0") end
        doing = true
        current = nil
        o:onActionComplete()
        fire("OnTick")
    end
    local function rowGhosts() -- 排隊虛影（OnPostRender）畫在哪幾格
        ghosts = {}
        fire("OnPostRender")
        local at = {}
        for _, g in ipairs(ghosts) do if g.name ~= "queued" then at[#at + 1] = g.x .. "," .. g.y end end
        return table.concat(at, " ")
    end
    local wallR = byId["recipe:Base.WoodWall"]
    check(Recipes.dragMode(wallR) == "ring" and Recipes.dragMode(barrel) == nil,
        "能拖一排：圖塊同種類能拖、每面一格的配方（牆照 ring）；集雨桶（家具、兩格）不能")
    local w = Recipes.build(0, wallR.id)
    local bar = Recipes.build(0, barrel.id)
    check(w.mbldRow == true and w.blockAfterPlace == false and rawget(w, "render") ~= nil and rawget(w, "tryBuild") ~= nil
        and bar.mbldRow == nil and bar.blockAfterPlace == true and rawget(bar, "render") == nil and rawget(bar, "tryBuild") ~= nil,
        "牆配方的游標掛上拖一排（只在實例上）、放下後不擋；集雨桶照原版一次一個、動作跑完才再放")
    getCell():setDrag(w, 0)
    BL = w.buildPanelLogic
    BL.poss = 3
    w.nSprite = 2
    local s50 = getCell():getGridSquare(50, 50, 0)
    badSq[getCell():getGridSquare(52, 50, 0)] = true
    w.square, w.isLeftDown = s50, true
    w:rotateMouse(54, 50)
    ghosts = {}
    w:render(50, 50, 0, s50)
    local okN, badN = 0, 0
    for _, g in ipairs(ghosts) do
        if g.name == "rcp_walls_01_0" then
            if g.args[5] == 1 then okN = okN + 1 else badN = badN + 1 end
        end
    end
    check(#vanillaRender == 0 and okN == 3 and badN == 2 and w.canBeBuild == true,
        "按住拖：整排 5 格，擋住的那格不扣一份，材料夠 3 次就 3 格白、其餘紅；至少一格可蓋就能放")
    w.mbldMax = 2
    w:rotateMouse(53, 50)
    ghosts = {}
    w:render(50, 50, 0, s50)
    okN = 0
    for _, g in ipairs(ghosts) do if g.name == "rcp_walls_01_0" and g.args[5] == 1 then okN = okN + 1 end end
    check(okN == 2, "每排上限（MaxCellsPerDrag）之後的格子畫紅、不送")
    w.mbldMax = 10
    nowMs = nowMs + 600 -- 預覽半秒重算一次（上限只在開游標時定，這裡是假的才要等）
    w.isLeftDown, w.build = false, true
    w:rotateMouse(53, 50) -- 放開那一幀 DoTileBuilding 不呼叫 rotateMouse；這行只是讓預覽和放開前最後一幀相同
    w:render(50, 50, 0, s50)
    Client.pending, Client.pendingUnbuild = { n = 9 }, { n = 9 }
    local c0 = cleared
    w:tryBuild(50, 50, 0)
    w.build = false
    current = w
    check(cleared == c0 + 1 and Client.pending == nil and Client.pendingUnbuild == nil and #tried == 1
        and tried[1][1] == 50 and tried[1][4] == 2 and tried[1].north == true and w.nSprite == 2,
        "放開：清佇列、圖塊的建造與拆除請求作廢（每人一個請求），送第一格（那格的面），送完換回游標的面")
    check(rowGhosts() == "50,50 51,50 53,50", "還沒蓋好的格子畫排隊虛影（擋住的 52 不送、不畫）")
    finish(w, 50, 50)
    check(#tried == 1, "第一格蓋好，但佇列還沒空（原版動作還在佇列裡）：先不送")
    doing = false
    fire("OnTick")
    current = w
    check(#tried == 2 and tried[2][1] == 51 and rowGhosts() == "51,50 53,50", "佇列空了：送下一格，蓋好的那格不再畫")
    -- 打斷：那格沒蓋好，等一下還是沒有就停下整排
    finish(w)
    doing = false
    local t2 = #toasts2
    fire("OnTick")
    check(#toasts2 == t2, "動作剛結束、那格還沒出現：先等（MP 的物件可能晚到）")
    nowMs = nowMs + 2000
    fire("OnTick")
    check(#tried == 2 and toasts2[#toasts2] == "IGUI_MBLD_Interrupted|IGUI_MBLD_Stopped(1,3)" and rowGhosts() == "",
        "被打斷：那格沒出現就停下整排、說蓋好幾格，不再送，排隊虛影收掉")
    -- 材料不夠：兩格，第一格蓋好後做不了
    getCell():getGridSquare(50, 51, 0).objects, getCell():getGridSquare(51, 51, 0).objects = {}, {}
    w.isLeftDown, w.build = true, false
    w.square = getCell():getGridSquare(50, 51, 0)
    w:rotateMouse(51, 51)
    w:render(50, 51, 0, w.square)
    w.isLeftDown, w.build = false, true
    w:render(50, 51, 0, w.square)
    w:tryBuild(50, 51, 0)
    w.build = false
    finish(w, 50, 51)
    rWall.o.can = false
    doing = false
    fire("OnTick")
    rWall.o.can = nil
    check(#tried == 3 and toasts2[#toasts2] == "IGUI_MBLD_Interrupted|IGUI_MBLD_Recipe_Blocked",
        "材料不夠做下一格：停下整排、說缺料（詳情寫缺什麼），不再送")
    -- 排隊中再拖一排：取代前一排；被取代的那格收尾不算停下、不通知
    w.square = getCell():getGridSquare(44, 44, 0)
    w:tryBuild(44, 44, 0)
    current = w
    t2 = #toasts2
    w.isLeftDown = true
    w:rotateMouse(46, 44)
    w:render(44, 44, 0, w.square)
    w.isLeftDown, w.build = false, true
    w:render(44, 44, 0, w.square)
    w:tryBuild(44, 44, 0)
    w.build = false
    nowMs = nowMs + 2000
    doing = false
    fire("OnTick")
    check(#toasts2 == t2 and #tried == 5 and tried[5][1] == 44 and tried[5][2] == 44 and rowGhosts() == "44,44 45,44 46,44",
        "排隊中再拖：清掉舊的那格、送新的一排第一格；舊的那格不通知")
    -- 圖塊項目送出建造（Client.build 設 pending、清佇列）：這一排安靜放掉
    Client.pending = { n = 10 }
    finish(w)
    nowMs = nowMs + 2000
    fire("OnTick")
    check(#toasts2 == t2 and #tried == 5 and rowGhosts() == "", "圖塊項目的建造取代了這一排：不通知、不再送")
    Client.pending = nil
    -- 走不到：原版當場收尾，什麼都沒蓋就說走不到
    walkFail = true
    w:tryBuild(55, 55, 0)
    walkFail = false
    doing = false
    nowMs = nowMs + 2000
    fire("OnTick")
    check(toasts2[#toasts2] == "nil|IGUI_MBLD_Refuse_WALK", "一格都沒蓋就停下：照圖塊項目說被打斷或走不過去")
    -- 游標身上沒有指回自己的表：原版 tryBuild 用 copyTable 深拷游標（不防循環，ISBuildingObject.lua:200）
    w:tryBuild(56, 56, 0)
    local seen, cyc = {}, false
    local JAVA = { buildPanelLogic = true, character = true, objectInfo = true, containers = true } -- 遊戲裡是 Java 物件，深拷不進去
    local function walk(t, depth)
        for k, v in pairs(t) do
            if v == w then cyc = true end
            if type(v) == "table" and not seen[v] and depth < 8 and not (depth == 0 and JAVA[k]) then
                seen[v] = true
                walk(v, depth + 1)
            end
        end
    end
    walk(w, 0)
    check(not cyc, "拖一排的狀態不放在游標上：深拷游標不會繞回自己")
    bar:tryBuild(57, 57, 0)
    nowMs = nowMs + 2000
    doing = false
    t2 = #toasts2
    w:onActionComplete()
    fire("OnTick")
    check(#toasts2 == t2 and rowGhosts() == "", "不能拖的配方游標放下：舊的一排剩下的不再送")
    -- 游標關了、拖的一排還在蓋：那格做完照樣換容器、refresh（下一格照用掉以後的材料判斷）
    getCell():setDrag(w, 0)
    getCell():getGridSquare(44, 46, 0).objects = {}
    w:tryBuild(44, 46, 0)
    getCell():setDrag(nil, 0)
    local ref0 = BL.refreshed or 0
    finish(w, 44, 46)
    check((BL.refreshed or 0) == ref0 + 1, "游標關了但一排還在蓋：那格做完照樣 refresh")
    getCell():setDrag(nil, 0)
    B.Messages.toast = realToast2
    ISBuildingObject, getCore, ISTimedActionQueue = realBase, realCore, realQueue

    getSpecificPlayer, getCell, SpriteConfigManager.GetObjectInfoList, getText = realSpecific, realCell, realInfos, realGetText
    ISTimedActionQueue.isPlayerDoingAction, Recipes.onEnd, clockStep, JoypadState = realDoing, realOnEnd, step0, realJoy
    Recipes.list = nil
    Names.reset()
end)()

print("情境四十三：疊放模式（使用者 2026-11-12 選 overlap、每格 3 件）：開著才放寬、上限、桌面同格、不找替換、伺服器重算")
;(function()
    nowMs = nowMs + 180000
    local B = MinidoracatBuilder
    local Place, Messages = B.Place, B.Messages
    local realInst, realProps, sb = instanceof, ISMoveableSpriteProps, SandboxVars.MinidoracatBuilder
    instanceof = function(o, cls) return type(o) == "table" and o.class == cls end
    -- 圖塊記下自己的旗標與字串鍵（spec）：obj() 放到格子上時併進格子屬性（引擎的格子屬性是各物件屬性的聯集）
    local function sp(name, id, flags, keys)
        local s = sprite(name, id, { flags = flags, keys = keys or {} })
        s.spec = { flags = flags, keys = keys or {} }
        return s
    end
    -- 照 2026-11-12 回報的三組圖的實際屬性（目錄傾印）：不能搬的爐面（畫在櫃台高度）、櫃台、畫好三種高度的可搬儲物櫃、
    -- UMCTP 的半箱（_32 不是桌面，_33／_34 是）。實心的家具與容器幾乎都帶 BlocksPlacement：原版搬家具靠它擋
    local BP = "BlocksPlacement"
    local cooktop = sp("ov_stove_01_10", 4301, { "solidtrans" }, { container = "stove", IsSurfaceOffset = "", Surface = "34" })
    local counter = sp("ov_counter_01_1", 4302, { "solidtrans" }, { container = "counter", [BP] = "", IsTable = "", Surface = "36" })
    local lockA = sp("ov_locker_01_4", 4303, { "solidtrans" }, { IsMoveAble = "", [BP] = "", IsLow = "", container = "locker" })
    local lockB = sp("ov_locker_01_5", 4304, { "solidtrans" }, { IsMoveAble = "", [BP] = "", IsLow = "", container = "locker" })
    local lockC = sp("ov_locker_01_6", 4305, { "solidtrans" }, { IsMoveAble = "", [BP] = "", IsLow = "", container = "locker" })
    local lockD = sp("ov_locker_01_7", 4306, { "solidtrans" }, { IsMoveAble = "", [BP] = "", IsLow = "", container = "locker" })
    local half2 = sp("ov_half_01_33", 4307, { "solidtrans" },
        { IsMoveAble = "", [BP] = "", IsStackable = "", IsTable = "", Surface = "45", container = "crate" })
    local half3 = sp("ov_half_01_34", 4308, { "solidtrans" },
        { IsMoveAble = "", [BP] = "", IsStackable = "", IsTable = "", Surface = "67", container = "crate" })
    local onTop = sp("ov_top_01_0", 4309, { "solid" }, { container = "microwave", IsTableTop = "" })
    local hung = sp("ov_hung_01_0", 4310, { "solid" }, { IsMoveAble = "", MoveType = "WallObject" })
    local lampS = sp("ov_lamp_01_0", 4311, { "solid" }, {}) -- 種類不在 Place.OVERLAP（這裡直接帶 light 進 Place.check）
    local boxA = sp("ov_box_01_0", 4312, { "solid" }, { container = "crate" })
    local boxB = sp("ov_box_01_1", 4313, { "solid" }, { container = "crate" })
    local shoe = sp("ov_shoe_01_19", 4319, {}, { container = "shelves", [BP] = "" }) -- 擋放置、不實心、不能搬（Perts 的鞋架）
    local wallA = sp("ov_wall_01_1", 4314, { "WallN" }, { WallN = "" })
    local wallB = sp("ov_wall_02_1", 4315, { "WallN" }, { WallN = "" })
    local brick = sp("ov_brick_01_1", 4316, { "WallN" }, { WallN = "", MaterialType = "Brick" })
    local lampE = sprite("ov_lamp_02_0", 4317, { type = T.lightswitch })
    world({ cooktop, counter, lockA, lockB, lockC, lockD, half2, half3, onTop, hung, lampS, boxA, boxB, wallA, wallB, brick, lampE })
    for x = 170, 177 do for y = 170, 177 do square(x, y, 0) end end
    local P = player({ id = 4301, x = 173.5, y = 173.5, here = squares["173,173,0"], cheat = true })
    -- 重建一格：flags＝額外的格子屬性（水這類）；物件的屬性由 obj() 併進來；有地板；實心照屬性
    local function at(x, y, flags, o)
        o = o or {}
        squares[x .. "," .. y .. ",0"] = nil
        o.flags = flags or {}
        if o.floor == nil then o.floor = {} end
        if o.floor == false then o.floor = nil end
        local sq = square(x, y, 0, o)
        sq.flagsRef = o.flags
        function sq:isSolid() return o.flags.solid == true end
        function sq:isSolidTrans() return o.flags.solidtrans == true end
        return sq
    end
    local function obj(sq, spr, yoff)
        local x = { class = "IsoThumpable", md = { builderEntry = spr:getName() }, mats = { ["Base.Plank"] = "4" } }
        function x:getSprite() return spr end
        function x:getProperties() return spr:getProperties() end
        function x:getSquare() return sq end
        function x:hasModData() return true end
        function x:getModData() return self.md end
        function x:isDismantable() return true end
        function x:getBuildMaterials() return self.mats end
        function x:hasBuildMaterials() return true end
        function x:isFloor() return false end
        function x:getRenderYOffset() return yoff or 0 end
        function x:getSpriteGridObjectsIncludingSelf() return javaList({ self }) end
        function x:isConnectedSpriteGridObject(y) return y == self end
        function x:isObjectNoContainerOrEmpty() return true end
        function x:hasFluid() return false end
        function x:isBarricaded() return false end
        function x:isStairsObject() return false end
        sq.objects[#sq.objects + 1] = x
        for _, f in ipairs(spr.spec.flags or {}) do sq.flagsRef[f] = true end
        for k in pairs(spr.spec.keys) do sq.flagsRef[k] = true end
        return x
    end
    -- 原版搬家具放下的判斷（Object 那一支，ISMoveableSpriteProps.lua:1074-1082,1747-1779）：要有地板；格上沒有擋放置的
    -- 東西就放（isFreeTile 不看實心旗標）；可疊的桌類放在桌面上照總高（最上面那張桌面的墊高＋Surface）
    ISMoveableSpriteProps = { new = function(spr)
        local p = spr:getProperties()
        local s = { isStackable = p:has("IsStackable"), isTable = p:has("IsTable"), surface = tonumber(p:get("Surface")),
            yOffsetCursor = 0 }
        function s:getTotalTableHeight(sq)
            for i = #sq.objects, 1, -1 do
                local o = sq.objects[i]
                local op = o:getSprite():getProperties()
                if op:has("IsTable") and tonumber(op:get("Surface")) then return o:getRenderYOffset() + tonumber(op:get("Surface")) end
            end
            return 0
        end
        function s:canPlaceMoveableInternal(_, sq)
            if not sq:getFloor() then return false end
            if not (sq:has(BP) and not sq:has("canBeRemoved")) then return true end
            if self.isStackable and self.isTable and self.surface and sq:has("IsTable") and not sq:has("IsTableTop")
                and not sq:has("IsHigh") then
                self.yOffsetCursor = self:getTotalTableHeight(sq)
                return self.yOffsetCursor + self.surface <= 96
            end
            return false
        end
        function s:isSquareAtTopOfStairs(sq) return sq.topOfStairs == true end
        return s
    end }
    local function try(kind, spr, sq, overlap) return Place.check(kind, spr, sq, P, nil, nil, nil, overlap) end

    -- 櫃台上的爐面（不能搬）
    local s1 = at(171, 171)
    obj(s1, counter)
    local off1, offC = try("container", cooktop, s1)
    local on1, y1, over1 = try("container", cooktop, s1, true)
    check(off1 == false and offC == nil and on1 == true and y1 == 0 and over1 == true and Place.occupants(s1) == 1,
        "櫃台上的爐面：關著照舊放不下（沒有原因碼）；開著放得下、不墊高、標成疊放")
    local e1, _, eo = try("container", cooktop, at(171, 170))
    check(e1 == true and eo == nil and select(3, try("container", cooktop, at(171, 170), true)) == nil,
        "空格：開不開疊放都照原本的規則放，不標成疊放")
    -- 可搬的儲物櫃疊三件，第四件到上限
    local s2 = at(171, 172)
    obj(s2, lockA)
    local offL = try("container", lockB, s2)
    local on2, _, over2 = try("container", lockB, s2, true)
    obj(s2, lockB)
    local on3 = try("container", lockC, s2, true)
    obj(s2, lockC)
    local on4, c4 = try("container", lockD, s2, true)
    check(offL == false and on2 == true and over2 == true and on3 == true and on4 == false and c4 == "SQUARE_FULL",
        "可搬的儲物櫃：關著放不下；開著疊到第 3 件，第 4 件回 SQUARE_FULL（預設上限 3）")
    sb.MaxPerSquare = 5
    local five = try("container", lockD, s2, true)
    sb.MaxPerSquare = 1
    local s2b = at(172, 172)
    obj(s2b, lockA)
    local one, oneC = try("container", lockB, s2b, true)
    sb.MaxPerSquare = nil
    check(five == true and one == false and oneC == nil, "沙盒上限：5 時第 4 件放得下；1＝關閉，開著也照舊放不下")
    -- 兩張桌面同格不走疊放（引擎讀檔會把後一張墊高）：照原版疊箱子的高度
    local s3 = at(171, 173)
    obj(s3, half2)
    local t3, c3 = try("furniture", half3, s3, true)
    local lowOk, lowY, lowOver = try("furniture", half2, at(170, 173), true) -- 空格：照原本的規則
    local s3b = at(172, 173)
    obj(s3b, counter)
    local counter2 = sp("ov_counter_01_2", 4320, { "solidtrans" }, { container = "counter", [BP] = "", IsTable = "", Surface = "36" })
    local t3b, c3b = try("container", counter2, s3b, true)
    check(t3 == false and c3 == "STACK_FULL", "桌面疊桌面（UMCTP 的半箱 45＋67）：開著疊放也照原版高度上限，回 STACK_FULL")
    check(t3b == false and c3b == nil and lowOk == true and lowY == 0 and lowOver == nil,
        "不能搬的桌面放在已經有桌面的格子：開著也不放；空格照原本的規則、不標成疊放")
    -- 原版疊箱子（軍用箱：可疊的桌面，Surface 32）在高度內：開著疊放也照原版墊高，不算疊放、不受每格件數管
    local crate = sp("ov_crate_01_0", 4322, { "solid" }, { IsMoveAble = "", [BP] = "", IsStackable = "", IsTable = "", Surface = "32", container = "crate" })
    local sCr = at(170, 174)
    obj(sCr, crate)
    local cr2, cr2y, cr2over = try("furniture", crate, sCr, true)
    obj(sCr, crate, 32)
    obj(sCr, lockA) -- 第三件（不是箱子）：件數到 3 了，箱子照原版規則還是疊得上第三層
    local cr3, cr3y, cr3over = try("furniture", crate, sCr, true)
    check(cr2 == true and cr2y == 32 and cr2over == nil and cr3 == true and cr3y == 64 and cr3over == nil,
        "原版疊箱子：開著疊放時照舊墊高 32、64，不標成疊放（照原本的規則放得下就照原本的）")
    -- 可疊卻不是桌面的半箱（UMCTP 的 _32）：桌面那張（_33）開著疊得上去（兩層）；同一張圖不疊（會畫在同一個位置）
    local half1 = sp("ov_half_01_32", 4318, { "solidtrans" }, { IsMoveAble = "", [BP] = "", IsStackable = "", container = "crate" })
    local s3c = at(173, 175)
    obj(s3c, half1)
    local h2, _, h2over = try("furniture", half2, s3c, true)
    local h1, h1c = try("furniture", half1, s3c, true)
    local h1off, h1offC = try("furniture", half1, s3c)
    check(h2 == true and h2over == true and h1 == false and h1c == "SAME_TILE" and h1off == false and h1offC == nil,
        "半箱：不是桌面的那張上面，開著疊得上桌面那張；同一張圖開著回 SAME_TILE，關著照舊沒有原因碼")
    -- 不放寬的格子與項目
    local sNo = at(171, 174, nil, { floor = false })
    obj(sNo, boxA)
    local sSt = at(171, 175, nil, { stairs = true })
    obj(sSt, boxA)
    local sWa = at(171, 176, { water = true })
    obj(sWa, boxA)
    local sTw = at(170, 177, { taintedWater = true }) -- 污水是另一個旗標（審查 1112 Grok）
    obj(sTw, boxA)
    local sTop = at(172, 174)
    obj(sTop, lockA)
    sTop.topOfStairs = true
    check(try("container", cooktop, sNo, true) == false and try("container", cooktop, sSt, true) == false
        and try("container", cooktop, sWa, true) == false and try("container", cooktop, sTw, true) == false
        and try("container", lockB, sTop, true) == false,
        "開著也不放：沒有地板、樓梯格、水與污水、樓梯頂（可搬的）")
    local s4 = at(172, 175)
    obj(s4, counter)
    check(try("container", onTop, s4, true) == false and try("furniture", hung, s4, true) == false
        and try("light", lampS, s4, true) == false,
        "開著也不放：桌上物件（IsTableTop）、掛牆的（MoveType）、不在 Place.OVERLAP 的種類")
    local _, same = try("container", counter, s4, true)
    local s5 = at(172, 176)
    obj(s5, boxA)
    s5.moving = { {} }
    local _, occ = try("container", cooktop, s5, true)
    local s6 = at(172, 177)
    obj(s6, boxA)
    function s6:isVehicleIntersecting() return true end
    local _, veh = try("container", cooktop, s6, true)
    check(same == "SAME_TILE" and occ == "OCCUPIED" and veh == "VEHICLE", "開著照樣先擋：同一張圖、格上有人、車子壓著")
    -- 擋放置、不實心、不能搬的容器（Perts 的鞋架）：Place.check 前面的「有人」「擋樓梯」只替實心的新物件查，
    -- 疊放自己再查一次（審查 1112 Codex）
    local shoe2 = sp("ov_shoe_01_20", 4321, {}, { container = "shelves", [BP] = "" })
    local s6b = at(170, 176)
    obj(s6b, shoe)
    local shOff = try("container", shoe2, s6b)
    local shOn = try("container", shoe2, s6b, true)
    s6b.moving = { {} }
    local shOcc, shOccC = try("container", shoe2, s6b, true)
    s6b.moving = {}
    local realStair = buildUtil.stairIsBlockingPlacement
    buildUtil.stairIsBlockingPlacement = function(sq) return sq == s6b end
    local shStair = try("container", shoe2, s6b, true)
    buildUtil.stairIsBlockingPlacement = realStair
    check(shOff == false and shOn == true and shOcc == false and shOccC == "OCCUPIED" and shStair == false,
        "不實心的容器疊放：關著被擋、開著可以；格上有人回 OCCUPIED、會擋到樓梯不放")
    local realOv = Place.OVERLAP.container
    Place.OVERLAP.container = nil -- 植入違規：容器拿出名單，上面「櫃台上的爐面」要放不下
    local planted = try("container", cooktop, s1, true)
    Place.OVERLAP.container = realOv
    check(planted == false, "植入違規：種類不在 Place.OVERLAP 時開著也放不下（放行靠這張名單）")

    -- Check.item：開著不找原地替換；不能疊的種類照舊替換
    local s7 = at(173, 171)
    local oldBox = obj(s7, boxA)
    local cR, _, iR = Check.item(P, "ov_box_01_1", 0, { 173, 171, 0 }, { preview = true })
    local cO, _, iO = Check.item(P, "ov_box_01_1", 0, { 173, 171, 0 }, { preview = true, overlap = true })
    check(cR == nil and iR.replace and iR.replace.obj == oldBox and iR.cells[1].over == nil
        and cO == nil and iO.replace == nil and iO.cells[1].over == true,
        "自己蓋的箱子上蓋另一款：關著是原地替換；開著是疊上去（不找替換、那一格標成疊放）")
    local s8 = at(173, 172, { WallN = true })
    local oldWall = obj(s8, wallA)
    local cW, _, iW = Check.item(P, "ov_wall_02_1", 0, { 173, 172, 0 }, { preview = true, overlap = true })
    check(cW == nil and iW.replace and iW.replace.obj == oldWall, "牆不在疊放的種類：開著照舊原地替換")

    -- 伺服器：請求帶 o 才照疊放重算；上限照伺服器的沙盒
    local function send(n, e, c, o)
        sent = {}
        Server.intent(P, { n = n, e = e, c = { c[1], c[2], 0, 0 }, v = Entry.digest(), o = o })
        if sent[1] and sent[1].cmd == "refused" then return false, sent[1].args end
        local it = nil
        for _, v in pairs(Server.intents) do if v.n == n then it = v end end
        sent = {}
        local ok = Server.complete(P, n, 1)
        return ok, sent[1] and sent[1].args or {}, it
    end
    local s9 = at(173, 173, { solidtrans = true })
    obj(s9, lockA)
    local okN, aN, itN = send(4301, "ov_locker_01_5", { 173, 173 })
    local okJ, _, itJ = send(4302, "ov_locker_01_5", { 173, 173 }, 1) -- 不是 true 的值不算
    check(not okN and aN.code == "BLOCKED" and itN.o == nil and not okJ and itJ.o == nil and #s9.objects == 1,
        "伺服器：請求沒帶 o（或不是 true）照原本的規則拒絕，格子不動")
    local okY, _, itY = send(4303, "ov_locker_01_5", { 173, 173 }, true)
    check(okY and itY.o == true and #s9.objects == 2, "伺服器：請求帶 o＝true，疊上第 2 件")
    local okY3 = send(4304, "ov_locker_01_6", { 173, 173 }, true)
    local okY4, aY4 = send(4305, "ov_locker_01_7", { 173, 173 }, true)
    check(okY3 and not okY4 and aY4.code == "SQUARE_FULL" and #s9.objects == 3,
        "伺服器：第 3 件放得下，第 4 件回 SQUARE_FULL")
    sb.MaxPerSquare = 1
    local s10 = at(173, 174, { solidtrans = true })
    obj(s10, lockA)
    local okOff, aOff = send(4306, "ov_locker_01_5", { 173, 174 }, true)
    sb.MaxPerSquare = nil
    check(not okOff and aOff.code == "BLOCKED" and #s10.objects == 1, "伺服器：沙盒設成 1 時，客戶端硬帶 o 也照舊拒絕")

    -- 客戶端：請求帶旗標、拒絕訊息帶上限
    local realS, realC, realSend, realGetText = isServer, isClient, sendClientCommand, getText
    local args
    isServer, isClient = function() return false end, function() return true end
    sendClientCommand = function(_, _, _, a) args = a end
    B.Client.build(P, "ov_locker_01_5", { { 173, 174, 0, 0 } }, true)
    local withO = args and args.o
    B.Client.build(P, "ov_locker_01_5", { { 173, 174, 0, 0 } })
    local withoutO = args and args.o
    isServer, isClient, sendClientCommand = realS, realC, realSend
    getText = function(k, ...)
        local a = { ... }
        return #a == 0 and k or k .. "(" .. table.concat(a, ",") .. ")"
    end
    local msg = Messages.refusal("SQUARE_FULL", { x = 1, y = 2, z = 0 })
    getText = realGetText
    check(withO == true and withoutO == nil and msg == "IGUI_MBLD_Refuse_SQUARE_FULL(3)",
        "客戶端：Client.build 第四個參數才帶 o；SQUARE_FULL 的訊息寫沙盒上限")
    local res, okCells = B.Cursor.preview(P, "ov_locker_01_5", 0, { { 173, 174, 0, 0 } }, nil, true)
    local resOff = B.Cursor.preview(P, "ov_locker_01_5", 0, { { 173, 174, 0, 0 } }, nil)
    check(okCells == 1 and res[1].code == nil and res[1].cells[1].over == true and resOff[1].code == "BLOCKED",
        "游標預覽：帶疊放時那一格可蓋並標成疊放，不帶時照舊 BLOCKED")

    -- 材料篩選的分類（建造視窗的下拉）
    local W = B.Window
    local mWall, mBrick, mLamp = W.materialsOf("ov_wall_01_1"), W.materialsOf("ov_brick_01_1"), W.materialsOf("ov_lamp_02_0")
    check(mWall.wood == true and mWall.other == nil and mBrick.masonry == true and mBrick.wood == nil
        and mLamp.other == true and mLamp.wood == nil and W.materialsOf("ov_lamp_02_0") == mLamp
        and W.materialsOf("ov_none_01_0") == nil,
        "材料分類：木牆歸木板、磚牆歸磚石、燈（電子零件）歸其他；同一種分類共用一張表；不存在的項目回 nil")
    ISMoveableSpriteProps, instanceof = realProps, realInst
end)()

print("情境四十四：能撿起的地磚、地毯照材質另外收料（使用者 2026-11-12 選 tiles=mat）：木底板寫進退料、材質料記在 fee")
;(function()
    nowMs = nowMs + 180000
    local keepBrick = scrapDefs.Brick
    scrapDefs.Brick = { perk = perkObj("Masonry"), tools = { "Base.Hammer" },
        returnItemsStatic = { { returnItem = "Base.ClayBrick", maxAmount = 1, chancePerRoll = 80 } } }
    local TILE = { IsMoveAble = "", MoveType = "FloorTile" }
    local function tileKeys(mat)
        local k = { Material = mat }
        for a, b in pairs(TILE) do k[a] = b end
        return k
    end
    local function tc(mat, mult) return cost("floor", { flags = { "solidfloor" }, keys = tileKeys(mat) }, mult) end
    local function show(t) -- 排序後的「物品=數量」，比對用
        local list = {}
        for k, v in pairs(t) do list[#list + 1] = k .. "=" .. v end
        table.sort(list)
        return table.concat(list, ",")
    end
    local carpet, brick, wood, bare = tc("Fabric"), tc("Brick"), tc("Wood"), tc(nil)
    check(show(carpet.items) == "Base.Nails=1,Base.Plank=1,Base.Sheet=1" and show(carpet.fee) == "Base.Sheet=1"
        and table.concat(carpet.tools, ",") == "HAMMER" and carpet.scrap == false,
        "地毯、布面地板：木底板 1＋1、床單 1（記在 fee）、鐵鎚；不照拆解價")
    check(show(brick.items) == "Base.ClayTile=4,Base.Nails=1,Base.Plank=1" and show(brick.fee) == "Base.ClayTile=4"
        and table.concat(brick.tools, ",") == "HAMMER,MASONS_TROWEL",
        "磚材質磁磚：木底板 1＋1、黏土瓦 4（fee）、鐵鎚＋抹刀；不再照拆解價收黏土磚")
    check(show(wood.items) == "Base.Nails=2,Base.Plank=2" and show(wood.fee) == "Base.Nails=1,Base.Plank=1"
        and show(bare.items) == show(wood.items) and show(bare.fee) == show(wood.fee) and bare.tools[1] == "HAMMER",
        "木地磚、沒寫 Material：木板 2、釘子 2，其中 1＋1 是材質料（fee）")
    local c0, cH, b0, bH, wH = tc("Fabric", 0), tc("Fabric", 0.5), tc("Brick", 0), tc("Brick", 0.5), tc("Wood", 0.5)
    check(show(c0.items) == "Base.Nails=1,Base.Plank=1" and next(c0.fee) == nil
        and show(cH.items) == "Base.Nails=1,Base.Plank=1,Base.Sheet=1" and show(b0.items) == "Base.Nails=1,Base.Plank=1"
        and bH.items["Base.ClayTile"] == 2 and bH.fee["Base.ClayTile"] == 2
        and show(wH.items) == "Base.Nails=2,Base.Plank=2" and show(wH.fee) == "Base.Nails=1,Base.Plank=1",
        "倍率 0、0.5：木底板最低照 1 收；材質料照倍率（0 不收、0.5 進位）")
    local c2 = tc("Fabric", 2)
    check(show(c2.items) == "Base.Nails=2,Base.Plank=2,Base.Sheet=2" and show(c2.fee) == "Base.Sheet=2", "倍率 2：兩部分都照乘")
    local xc, xb, x0 = Cost.xp({ carpet }, player()), Cost.xp({ brick }, player()), Cost.xp({ c0 }, player())
    local xw, x2, xh = Cost.xp({ wood }, player()), Cost.xp({ c2 }, player()), Cost.xp({ carpet }, player({ movCheat = true }))
    local xw2, xb2 = Cost.xp({ tc("Wood", 2) }, player()), Cost.xp({ tc("Brick", 2) }, player())
    check(xc.Woodwork == 5 and xc.Masonry == nil and xb.Woodwork == nil and xb.Masonry == 20 and xw.Woodwork == 10
        and xh.Woodwork == 5 and carpet.uniform == false,
        "經驗只給材質料（fee）、照件數全給：地毯床單木工 5、磁磚黏土瓦石工 20、木地磚多收的木板釘子木工 10；"
        .. "木底板不給（搬運作弊也一樣只給 fee）；不是本工具拆的（uniform false）")
    check(x2.Woodwork == 10 and xw2.Woodwork == 20 and xb2.Woodwork == nil and xb2.Masonry == 40,
        "倍率 2：木底板 2 件仍不給，只有 fee 加倍（地毯木工 10、木地磚 20、磁磚石工 40）")
    check(next(x0) == nil and next(Cost.xp({ b0 }, player())) == nil, "倍率 0：只付木底板，沒有經驗")
    check(show(cost("floor", { flags = { "solidfloor" } }).items) == "Base.Nails=1,Base.Plank=1"
        and next(cost("floor", { flags = { "solidfloor" } }).fee) == nil
        and next(cost("floor", { flags = { "solidfloor" }, keys = { MoveType = "FloorTile", Material = "Fabric" } }).fee) == nil
        and next(cost("floor", { flags = { "solidfloor" }, keys = { MoveType = "FloorRug", IsMoveAble = "", Material = "Fabric" } }).fee) == nil
        and next(cost("furniture", { keys = tileKeys("Fabric") }).fee) == nil
        and cost("floor", { flags = { "solidfloor" }, keys = { Material = "Brick", CanScrap = "" } }).items["Base.ClayBrick"] == 1,
        "反面：一般地板、不能搬的、MoveType 不是 FloorTile 的、不是地板種類的價錢照舊（沒有 fee）")
    -- 二樓蓋地毯：buildMaterials 只寫木底板；建造作弊照舊不收、不寫
    local carpetS = sprite("ftile_01_0", 4401, { flags = { "solidfloor" }, keys = tileKeys("Fabric") })
    world({ carpetS })
    square(400, 400, 0, { wallN = {} })
    square(402, 400, 0, { wallN = {} })
    local up, upC = square(400, 400, 1), square(402, 400, 1)
    local P = player({ id = 4401, x = 400.5, y = 401.5 })
    P.inv:add(item("Base.Hammer", { HAMMER = true }))
    give(P, { ["Base.Plank"] = 1, ["Base.Nails"] = 1, ["Base.Sheet"] = 1 })
    local ok = build(P, 1, "ftile_01_0", { 400, 400, 1 })
    local o = up.objects[1]
    check(ok and o and show(o.mats) == "Base.Nails=1,Base.Plank=1" and P.inv:count("Base.Sheet") == 0
        and P.inv:count("Base.Plank") == 0,
        "二樓的地毯：扣木底板＋床單，buildMaterials 只有木底板（床單不寫）")
    local C = player({ id = 4402, x = 402.5, y = 401.5, cheat = true })
    check(build(C, 1, "ftile_01_0", { 402, 400, 1 }) and upC.objects[1] and next(upC.objects[1].mats) == nil,
        "建造作弊：背包空的也蓋，不寫退料表")
    scrapDefs.Brick = keepBrick
end)()

print()
if failures > 0 then
    print(failures .. " 項失敗")
    os.exit(1)
end
print("全部通過")
