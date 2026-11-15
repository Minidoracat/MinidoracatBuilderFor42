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
    -- 照引擎：每個 IsoObject 都有 isFloor（IsoObject.java:363）；情境裡臨時做的物件沒寫的當成不是地板
    local obj = ...
    if name == "OnObjectAboutToBeRemoved" and type(obj) == "table" and obj.isFloor == nil then
        obj.isFloor = function() return false end
    end
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
    -- 貼圖與遮罩（Cursor.mirror）：o.mask(x, y) 回那一點透不透明，圖框 64×64；沒給就是沒有貼圖
    function s:getTextureForCurrentFrame()
        return o.mask and { getWidthOrig = function() return 64 end, getHeightOrig = function() return 64 end } or nil
    end
    function s:isMaskClicked(_, x, y, flip) return o.mask(flip and 64 - x or x, y) end
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
-- 動態開的系統（SGlobalObjects.registerSystem；地板帳本的分片）：HARNESS_GOS_SHARDS[名稱] 是它的 modData，留著＝存檔還在。
-- HARNESS_GOS_COUNT 有值時當成全伺服器的系統數
HARNESS_GOS_SHARDS = {}
SGlobalObjects = {}
function SGlobalObjects.registerSystem(name)
    local md = HARNESS_GOS_SHARDS[name] or {}
    HARNESS_GOS_SHARDS[name] = md
    return { getModData = function() return md end, setModDataKeys = function(_, keys) HARNESS_GOS_KEYS[name] = keys end,
        setObjectModDataKeys = function() end, setObjectSyncKeys = function() end }
end
function SGlobalObjects.getSystemCount()
    if HARNESS_GOS_COUNT then return HARNESS_GOS_COUNT end
    local n = 8
    for _ in pairs(HARNESS_GOS_SHARDS) do n = n + 1 end
    return n
end
-- 存檔資料夾裡有沒有那個檔（引擎的全域函式）：地板帳本用它找有幾片
function checkSaveFileExists(f) return HARNESS_GOS_SHARDS[f:match("^gos_(.+)%.bin$")] ~= nil end
-- 帳本存檔（Store 的分片）裡鍵 k 的值：照順序看每一片；有對照表的回對照表裡那張表
function HARNESS_LEDGER(name, k)
    for n = 1, 16 do
        local md = HARNESS_GOS_SHARDS[name .. "_" .. n]
        local v = md and md.data and md.data[k]
        if v ~= nil then
            if md.dict then return md.dict[v] end
            return v
        end
    end
    return nil
end
-- 重開服：同一個系統表再建一次（存檔＝記憶體裡現在的樣子）
function HARNESS_REOPEN(cls)
    local inst = cls.instance
    cls.instance = nil
    inst:initSystem()
end
-- 四本帳本記的筆數、大小，和存檔表裡實際的內容對不對得上（照存檔格式重算）；對照表和紀錄互相對得上。回不一致的那幾本
function HARNESS_DRIFT()
    local Store = MinidoracatBuilder.Store
    local LEDGER_FILES = { floors = "MinidoracatBuilderFloors", overlays = "MinidoracatBuilderOverlays",
        ledger = "MinidoracatBuilder", circuits = "MinidoracatBuilderCircuits" }
    local bad = {}
    for _, r in ipairs(Store.report()) do
        local n, bytes, ok = 0, 0, true
        for i = 1, 16 do
            local md = HARNESS_GOS_SHARDS[LEDGER_FILES[r.id] .. "_" .. i]
            if md and md.data then
                local used = {}
                for k, v in pairs(md.data) do
                    n = n + 1
                    if md.dict then
                        bytes = bytes + Store.size(k) + 9
                        used[v] = true
                        ok = ok and md.dict[v] ~= nil
                    else
                        bytes = bytes + Store.size(k) + Store.size(v)
                    end
                end
                for id, v in pairs(md.dict or {}) do
                    bytes = bytes + 9 + Store.size(v)
                    ok = ok and used[id] == true
                end
            end
        end
        if not (ok and n == r.n - r.left and bytes == r.bytes) then
            bad[#bad + 1] = r.id .. " n=" .. n .. "/" .. (r.n - r.left) .. " bytes=" .. bytes .. "/" .. r.bytes
        end
    end
    return table.concat(bad, "; ")
end
function sendRemoveItemFromContainer() end
function sendAddItemsToContainer() end
local function item(ft, tags)
    local it = { ft = ft, tags = tags or {} }
    function it:getFullType() return ft end
    function it:isBroken() return false end
    function it:getContainer() return self.box end
    function it:getCurrentUses() return self.uses or 0 end
    function it:hasTag(t) return self.tags[t] == true end
    -- 照引擎：沒有流體元件不是流體容器（InventoryItem.java:5122-5132）；fluid＝裝的量，0 是空的
    function it:isFluidContainer() return self.fluid ~= nil end
    function it:isEmptyOfFluid() return self.fluid == 0 end
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
check(kind({ flags = { "doorW" }, keys = { WallW = "", GarageDoor = "" } }) == "door", "車庫門的片帶門旗標與牆鍵：歸門（湊不成整組的由 Entry.resolve 擋）")
check(kind({ flags = { "doorW" }, keys = { DoubleDoor = "3" } }) == "door", "雙開門的單片：歸門（目錄只收湊得成整組的第 1 片）")
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
check(kind({ flags = { "vegitation" } }) == nil and kind({ keys = { tree = "1", IsMoveAble = "" } }) == nil,
    "不能搬、不是草的植物與帶 tree 的不列（能搬的觀賞植物、草見情境四十五）")
check(kind({ flags = { "canBeRemoved" }, keys = { MoveWithWind = "" } }) == "plant"
    and kind({ flags = { "vegitation" }, keys = { IsMoveAble = "" } }) == "plant"
    and kind({ flags = { "canBeRemoved" }, keys = { MoveWithWind = "", waterAmount = "9999" } }) == nil
    and kind({ flags = { "canBeRemoved" }, keys = { MoveWithWind = "", IsWaterCollector = "" } }) == nil
    and kind({ flags = { "vegitation" }, keys = { IsMoveAble = "", CustomItem = "Base.Tent" } }) == nil
    and kind({ flags = { "vegitation" }, keys = { IsMoveAble = "", fuelAmount = "100" } }) == nil
    and kind({ flags = { "canBeRemoved" }, keys = { MoveWithWind = "" } }, "e_newgrass_1_8") == "plant"
    and kind({ flags = { "canBeRemoved" }, keys = { MoveWithWind = "", waterAmount = "9999" } }, "e_newgrass_1_8") == nil
    and kind({ flags = { "vegitation" }, keys = { IsMoveAble = "", IsoType = "IsoRadio" } }, "vegetation_ornamental_01_0") == nil,
    "植物候選照樣過無限水、集水、專用物件那幾關：帶植物鍵也不列；名稱前綴那條路也一樣（對照：沒有這些鍵的照列植物）")
check(kind({ flags = { "vegitation" }, keys = { IsMoveAble = "" } }, "vegetation_ornamental_01_16") == "plant"
    and kind({ flags = { "vegitation" }, keys = { IsMoveAble = "" } }, "vegetation_groundcover_01_18") == nil
    and kind({ flags = { "vegitation" }, keys = { IsMoveAble = "", StackReplaceTileOffset = "-1" } }) == nil
    and kind({ flags = { "vegitation" }, keys = { IsMoveAble = "", StackReplaceTileOffset = "0" } }) == "plant",
    "vegetation_groundcover_ 不收（那組能搬的植物實際沒有貼圖）；疊放圖（StackReplaceTileOffset 不是 0）帶植物鍵也不列")
check(kind({ keys = { IsMoveAble = "" } }, "eaves_01_0") == "furniture", "e 開頭但不是 e_：照常分類")
check(kind({ flags = { "solidfloor", "water" }, keys = { waterAmount = "9999" } }) == "water"
    and kind({ flags = { "solidfloor" }, keys = { waterAmount = "9999" } }) == nil,
    "無限水的地板：帶 water 旗標的天然水面歸「水面」（情境四十七），沒有 water 旗標的照舊不列")
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
    sprite("st_01_9", 7, { type = T.stairsBW }), sprite("st_01_10", 8, { type = T.stairsMW }),
    -- 原版 fixtures_stairs_01 的排法：兩款往西（0、3）在前，兩款往北（8、11）在下一列
    sprite("sv_01_0", 9, { type = T.stairsBW }), sprite("sv_01_1", 10, { type = T.stairsMW }),
    sprite("sv_01_2", 11, { type = T.stairsTW }), sprite("sv_01_3", 12, { type = T.stairsBW }),
    sprite("sv_01_4", 13, { type = T.stairsMW }), sprite("sv_01_5", 14, { type = T.stairsTW }),
    sprite("sv_01_8", 15, { type = T.stairsBN }), sprite("sv_01_9", 16, { type = T.stairsMN }),
    sprite("sv_01_10", 17, { type = T.stairsTN }), sprite("sv_01_11", 18, { type = T.stairsBN }),
    sprite("sv_01_12", 19, { type = T.stairsMN }), sprite("sv_01_13", 20, { type = T.stairsTN }) })
local named = IsoSpriteManager.instance:getNamedMap()
local s1 = Rules.stairsSet(named, "st_01_0")
check(s1 and s1.m == "st_01_1" and s1.t == "st_01_2" and s1.dir == "W", "遞增三格成組")
local s2 = Rules.stairsSet(named, "st_01_7")
check(s2 and s2.m == "st_01_6" and s2.t == "st_01_5" and s2.dir == "N", "遞減三格成組")
check(Rules.stairsSet(named, "st_01_9") == nil, "少一格：不成組")
check(Rules.stairsSet(named, "st_01_1") == nil, "中段不當起點")
do
    local eW, eN = Entry.resolve("st_01_0"), Entry.resolve("st_01_7")
    local pW, pN = eW and Entry.face(eW, 5), eN and Entry.face(eN, 5)
    local function pairOf(n)
        local e = Entry.resolve(n)
        local p = e and Entry.face(e, 5)
        return p and p:getName()
    end
    check(pW and pW:getName() == "st_01_7" and pN and pN:getName() == "st_01_0"
        and pairOf("sv_01_0") == "sv_01_8" and pairOf("sv_01_3") == "sv_01_11" and pairOf("sv_01_8") == "sv_01_0"
        and pairOf("sv_01_11") == "sv_01_3",
        "樓梯的配對面：同一個 tileset 照編號排，第 i 組往西配第 i 組往北（3 配 11，不是最近的 8）；湊不成組的不算")
end

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
check(select(2, Entry.resolve("gd_01_0")) == "UNKNOWN", "湊不成整組的車庫門片：UNKNOWN（目錄也不收）")
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
-- 格組有空位（玩家 2026-11-13 回報吊燈錘不掉）：L 形的床 2×2 只有 3 片，引擎整組移除與原版拿起都會失敗，歸本工具拆
do
    local R, C = MinidoracatBuilder.Rules, MinidoracatBuilder.Cost
    local fullA = sprite("full_01_0", 811, { keys = { IsMoveAble = "" } })
    local fullB = sprite("full_01_1", 812, { keys = { IsMoveAble = "" } })
    fakeGrid(2, 1, { { fullA, fullB } })
    check(R.gridHoles(bedA) and R.gridHoles(bedC) and C.refund("furniture", bedA) == "builder"
        and C.refund("furniture", bedC) == "builder", "格組有空位的能搬物件：每一片的拆除方式都是本工具拆，不是照原版拿起")
    check(not R.gridHoles(fullA) and C.refund("furniture", fullA) == "pickup" and not R.gridHoles(chair[1])
        and C.refund("furniture", chair[1]) == "pickup", "格組沒有空位、或不是多格：能搬的照舊照原版拿起")
end
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
        MinidoracatBuilder.Recent.load() -- 最近用的改存 recent.txt（Recent.lua）：這裡沒有假磁碟，讀不到＝空清單
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
    local st = { n = 4, { d = 5, dx = 0, dy = 0 }, { d = 0, dx = 1, dy = 0 }, { d = 5, dx = 0, dy = 1 }, { d = 0, dx = 0, dy = 0 } }
    check(Cursor.pickState(nil, st, 0) == 4 and Cursor.pickState(nil, st, 5) == 1,
        "朝向循環：開游標時挑沒有位移的那一個（西邊，不是東邊）")
    local fake = { states = st, si = 1, setState = function(o, i) o.si = i end }
    Cursor.turn(fake, -1)
    local back = fake.si
    Cursor.turn(fake, 1)
    Cursor.turn(fake, 1)
    check(back == 4 and fake.si == 2, "朝向循環：往回從第一個轉到最後一個，往前照順序")
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
        for _, t in ipairs({ "HAMMER", "MASONS_TROWEL", "BLOW_TORCH", "WELDING_MASK", "SCREWDRIVER", "DIG_GRAVE" }) do
            want["IGUI_MBLD_Tool_" .. t] = true
        end
        for _, k in ipairs({ "stairs", "roof", "light", "curtain", "well", "plant", "plantGrass", "water" }) do
            want["IGUI_MBLD_Note_" .. k] = true
        end
        want["IGUI_MBLD_Why_OFF_DEFAULT"] = true -- 預設關的種類（水井）的說明
        want["IGUI_MBLD_Why_BAD_GRID"] = true -- 格位拼不起來的多格項目（吊燈）的說明
        for _, list in pairs(W.SUB_KINDS) do -- 左欄子種類（容器的是原版顯示名，不另翻）
            if type(list) == "table" then
                for _, s in ipairs(list) do want["IGUI_MBLD_Sub_" .. s] = true end
            end
        end
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
    local realMax = sb.MaxCellsPerDrag
    sb.MaxCellsPerDrag = 32 -- 前面的情境設成 4：8 格會分兩筆送（Queue），這裡只測一筆停下的通知
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
    local function run(count, placed, noRoom, none)
        told = nil
        local cells = {}
        for i = 1, count do cells[i] = { i, 0, 0, 0 } end
        local n = Cursor.send({ getPlayerNum = function() return 0 end }, "x_01_0", cells, nil)
        C.pending.noRoom, C.pending.noneQueued = noRoom, none
        local Q = B.Queue
        Q.onResult("accepted", { n = n })
        for i = 1, placed do Q.onResult("placed", { n = n, i = i }) end
        Q.tick()
        nowMs = nowMs + 2000
        Q.tick()
        return told
    end
    check(run(8, 3) == "IGUI_MBLD_Interrupted|IGUI_MBLD_Stopped(3,8)", "蓋了 3 格後停下：報蓋好 3／8，不報走不到")
    check(run(8, 0) == "nil|IGUI_MBLD_Refuse_WALK", "一格都沒蓋就停下：照舊用 WALK，標題留給 toast 預設")
    check(run(8, 4, 5) == "IGUI_MBLD_Interrupted|IGUI_MBLD_Refuse_NO_ROOM(5)", "第 5 格旁邊沒空位：前 4 格蓋好後報第 5 格")
    check(run(8, 1, 5) == "IGUI_MBLD_Interrupted|IGUI_MBLD_Stopped(1,8)", "還沒走到沒空位那格就停下：照實報蓋好幾格")
    check(run(4, 0, 4, true) == "nil|IGUI_MBLD_Refuse_NO_ROOM(4)",
        "一次挖好幾格水面、第 4 格沒空位所以整批沒排：報第 4 格旁邊沒有空位，不報走不過去")
    check(run(8, 8) == nil and Cursor.queued() == nil, "全部蓋好：不通知")
    C.build, Messages.toast, Cursor.get, ISTimedActionQueue, getText = realBuild, realToast, realGet, realQ, realGetText
    sb.MaxCellsPerDrag = realMax
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
        function o:getObjectIndex() return 0 end
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
        and table.concat(HARNESS_GOS_KEYS.MinidoracatBuilderFloors, ",") == "floors"
        and type(HARNESS_GOS_KEYS.MinidoracatBuilderFloors_1) == "table"
        and table.concat(HARNESS_GOS_KEYS.MinidoracatBuilderFloors_1, ",") == "v,data,dict",
        "地板帳本存檔白名單：主系統只有 floors（和分片以前一樣），分片 v、data、dict（漏了重開後地板帳本消失）")
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
        function l:hasModData() return false end
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
        function o:getObjectIndex() return self.gone and -1 or 0 end
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
        local function roomOf(list, def)
            return { def = def, getLightSwitches = function() return javaList(list) end,
                getRoomDef = function(self) return self.def end }
        end
        sq.room, sq.userRoom = roomOf({ offLamp, offSw }, "d1"), true
        HARNESS_CASCADE = { offLamp, offSw }
        fire("OnObjectAdded", sw)
        local userOk = sw.lit == true and not offLamp.on and not offSw.on
        -- 房間重建（蓋牆、拆牆讓區域重算；2026-11-14）：格子換了一個 IsoRoom，一秒內照開關的狀態補切一次、其他燈與開關還原；
        -- 房間沒換就不再切（switchLight 會讓光照整張重算）；讀格子載入的開關（Place.migrate）也登記；不在世界上的不再看
        local function tick()
            nowMs = nowMs + 1500
            fire("OnTick")
        end
        sw.lit = nil
        tick()
        local sameOk = sw.lit == nil
        sq.room = roomOf({ offLamp, offSw }, "d1")
        tick()
        local rebuiltOk = sw.lit == true and not offLamp.on and not offSw.on
        sw.lit, sq.room.def = nil, "d2" -- 房間物件沒換、定義換了一份：一樣補切
        tick()
        rebuiltOk = rebuiltOk and sw.lit == true
        local loaded = light(85, 100, swS, "mark")
        local Pl = MinidoracatBuilder.Place
        local harden, fit = Pl.harden, Pl.fitContainers
        Pl.harden, Pl.fitContainers = function() end, function() end -- 這裡只看 migrate 有沒有登記開關
        Pl.migrate(loaded)
        Pl.harden, Pl.fitContainers = harden, fit
        tick()
        local loadedOk = loaded.lit == true
        sw.lit, loaded.lit, sw.gone = nil, nil, true
        sq.room = roomOf({}, "d3")
        tick()
        check(sameOk and rebuiltOk and loadedOk and sw.lit == nil and loaded.lit == true,
            "自建房間重建：格子換了房間物件時，本工具的開關照自己的狀態補切房間燈一次（其他燈與開關還原）；房間沒換不切；"
            .. "讀格子載入的開關也補；已經不在世界上的開關不再切")
        loaded.gone = true
        tick()
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
    HARNESS_REOPEN(Ledger)
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
    local left = Ledger.circuits:stats().n
    check(left == 3 and Ledger.get(O.SW1) == nil and ask(P3, O.SW3).id == nil,
        "兩個開關都拿走：整條線路刪掉（只剩大區域、房間 10、相鄰兩間那三條），帳本也清掉（" .. left .. "）")
    check(HARNESS_DRIFT() == "", "接線、拆線、併線之後：帳本記的筆數與大小和存檔表的內容一致（" .. HARNESS_DRIFT() .. "）")
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
    check(code({ flags = { "doorW", "open" } }) == "DOOR_OPEN"
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
    check(c == "dismantleRefused" and a.code == "INTERNAL" and hung(fQ) == TL and Overlays.get(Q, TL)["Base.Plank"] == 1
        and next(here.dropped) == nil, "拿不掉那張（引擎出錯）：INTERNAL、不退料、帳本那一張記回去、整批停")
    -- 帳本滿到剩下的那幾張記不回去（另一件還在用同一個組合，拿掉一張要多一項對照表）：不拆，圖、帳本、退料都不動
    ;(function()
        local F1, fF1 = ground(46, 46)
        local F2 = ground(46, 47)
        give(Pl, pay)
        build(Pl, 2617, TL, { 46, 46, 0 })
        Overlays.put(F1, "ov_extra", {})
        Overlays.put(F2, TL, Overlays.get(F1, TL))
        Overlays.put(F2, "ov_extra", {})
        local St, realPrint = MinidoracatBuilder.Store, print
        local kB, kH, kS = St.SHARD_BYTES, St.SHARD_HARD, St.SHARD_SLACK
        St.SHARD_BYTES, St.SHARD_HARD, St.SHARD_SLACK, HARNESS_GOS_COUNT = 1, 1, 0, 100
        print = function() end
        here.dropped = {}
        local c2, a2 = unbuild(Pl, 2618, 46, 46, TL)
        print = realPrint
        St.SHARD_BYTES, St.SHARD_HARD, St.SHARD_SLACK, HARNESS_GOS_COUNT = kB, kH, kS, nil
        check(c2 == "dismantleRefused" and a2.code == "INTERNAL" and hung(fF1) == TL and Overlays.get(F1, TL)["Base.Plank"] == 1
            and Overlays.get(F1, "ov_extra") ~= nil and Overlays.get(F2, "ov_extra") ~= nil and next(here.dropped) == nil,
            "帳本滿到剩下的那幾張記不回去：不拆（INTERNAL），那張圖、那一件的帳本、別件的帳本都在、不退料")
        here.dropped = {}
        c2 = unbuild(Pl, 2619, 46, 46, TL)
        check(c2 == "dismantled" and hung(fF1) == "" and Overlays.get(F1, TL) == nil and Overlays.get(F1, "ov_extra") ~= nil
            and here.dropped["Base.Plank"] == 1, "放得下之後照常拆：只拿掉那一張、照帳本退，剩下的那一張還在")
        Overlays.forget(F1, "ov_extra")
        Overlays.forget(F2, TL)
        Overlays.forget(F2, "ov_extra")
        -- 那一件只掛一張、帳本滿、圖又拿不掉（引擎出錯）：先清掉的那一筆照樣記得回去（放回去不比拿掉之前大）
        nowMs = nowMs + 180000
        local F3, fF3 = ground(45, 47)
        give(Pl, pay)
        build(Pl, 2620, TL, { 45, 47, 0 })
        function fF3:RemoveAttachedAnim() end
        St.SHARD_BYTES, St.SHARD_HARD, St.SHARD_SLACK, HARNESS_GOS_COUNT = 1, 1, 0, 100
        print = function() end
        here.dropped = {}
        c2, a2 = unbuild(Pl, 2621, 45, 47, TL)
        print = realPrint
        St.SHARD_BYTES, St.SHARD_HARD, St.SHARD_SLACK, HARNESS_GOS_COUNT = kB, kH, kS, nil
        check(c2 == "dismantleRefused" and a2.code == "INTERNAL" and hung(fF3) == TL and Overlays.get(F3, TL) ~= nil
            and Overlays.get(F3, TL)["Base.Plank"] == 1 and next(here.dropped) == nil and HARNESS_DRIFT() == "",
            "帳本滿、那一件只掛一張、圖拿不掉：INTERNAL、不退料，帳本那一筆記回原樣")
        nowMs = nowMs + 180000 -- 這一段多送的三個請求不算進後面的限流
    end)()

    -- 地板移出世界：那一格整格清掉，不看那時還掛著哪幾張；別的物件移除時不動帳本
    local D, fD = ground(43, 45)
    give(Pl, Cost.of("floorOverlay", tl2S, 1).items)
    local okD = build(Pl, 2609, TL2, { 43, 45, 0 })
    local other = { class = "IsoObject", att = {} }
    function other:getSquare() return D end
    function other:getSprite() return debrisS end
    function other:hasModData() return false end
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
    end, getGarageDoorIndex = function() return -1 end, getDoubleDoorIndex = function() return -1 end }
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
        function x:getObjectIndex() return 0 end
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
    -- 多層格組：levels[z + 1][y + 1][x + 1] = sprite（IsoSpriteGrid 的 getSprite(x, y, z)、getLevels），原點在 (0,0,0)
    local function tallGrid(w, h, levels)
        local g = {}
        function g:getWidth() return w end
        function g:getHeight() return h end
        function g:getLevels() return #levels end
        function g:getSprite(x, y, z)
            local lv = levels[z + 1]
            return lv and lv[y + 1] and lv[y + 1][x + 1] or nil
        end
        function g:getAnchorSprite() return levels[1][1][1] end
        function g:getSpriteGridPosX() return 0 end
        function g:getSpriteGridPosY() return 0 end
        for _, lv in ipairs(levels) do for _, row in pairs(lv) do for _, s in pairs(row) do s.grid = g end end end
    end
    local tallA = sp("rp_tall_01_0", 2828, { "solid" }, { IsMoveAble = "" }) -- 兩層樓高：下片、上片
    local tallB = sp("rp_tall_01_1", 2829, { "solid" }, { IsMoveAble = "" })
    tallGrid(1, 1, { { { tallA } }, { { tallB } } })
    local badA = sp("lighting_indoor_03_0", 2830, { "solid" }, { IsMoveAble = "" }) -- 名稱在 Rules.BAD_GRID 的那一組
    local badB = sp("lighting_indoor_03_1", 2831, { "solid" }, { IsMoveAble = "" })
    tallGrid(2, 1, { { { badA, badB } } })
    local all = { wallN, wallW, frameN, wallN2, floorA, floorB, lampA, lampB, boxA, boxB, crate, chair, stA, stB, ovA, ovB, gridS,
        shelfA, shelfB, lampS1, lampS2, ovX1, ovX2, tallA, tallB, badA, badB }
    for _, s in pairs(pf) do all[#all + 1] = s end
    all[#all + 1] = sp("lighting_indoor_01_4", 2832, {}, {}, { type = T.lightswitch }) -- 原版開關的 8 張之一（名稱帶牆面與位置）
    -- 屋頂的鏡像片：0 與 5 互為左右鏡像（同一列 c↔5−c），1 左右對稱，2 的候選（5）形狀不一樣，3 沒有貼圖
    local function roofSpr(n, mask)
        return sprite("rf_01_" .. n, 2840 + n, { type = T.WestRoofT, keys = { RoofGroup = "1" }, mask = mask })
    end
    for _, s in ipairs({ roofSpr(0, function(x) return x < 32 end), roofSpr(5, function(x) return x > 32 end),
        roofSpr(1, function() return true end), roofSpr(2, function(x, y) return x < 32 and y < 32 end), roofSpr(3) }) do
        all[#all + 1] = s
    end
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
    check(pair("pf_house_01_2") == nil and pair("pf_lone_01_0") == nil
        and Entry.face(Entry.resolve("pf_house_01_0"), 6) == nil,
        "配對面：佔兩條邊的角片、找不到另一邊的都回 nil；d＝6 不存在")
    check(pair("pf_door_01_0") == "pf_door_01_1" and pair("pf_door_01_1") == "pf_door_01_0",
        "配對面：單扇門照編號 xor 1、方向相反、互配（使用者 2026-11-14：有規律的才配）")
    local wallEntry = Entry.resolve("pf_house_01_0")
    check(Entry.face(wallEntry, 5) == Entry.face(wallEntry, 5) and Entry.face(wallEntry, 0) == pf.pf_house_01_0,
        "配對面：同一項目查兩次結果一樣（快取），d＝0 照舊是自己")
    -- 游標的朝向清單接上配對面（2026-11-14）：牆按旋轉鍵換到另一條邊那一張、再按回來；找不到另一邊的照舊只有自己。
    -- 建造視窗的旋轉標記照同一份清單
    local Cur, Win = MinidoracatBuilder.Cursor, MinidoracatBuilder.Window
    local wf, lf = Cur.faces(wallEntry), Cur.faces(Entry.resolve("pf_lone_01_0"))
    check(wf.n == 2 and wf[1] == 0 and wf[2] == 5 and lf.n == 1 and lf[1] == 0,
        "朝向清單：只佔一條邊的牆多一個配對面（d＝5）；沒有另一邊的只有自己")
    -- 按旋轉鍵照四條邊轉（2026-11-16 rot4=edge）：西牆 pf_house_01_0 的北邊用配對面、東邊＝右邊那格的西邊
    local Turn = MinidoracatBuilder.Turn
    local ws, ls = Turn.states(wallEntry), Turn.states(Entry.resolve("pf_lone_01_0"))
    local function is(s, d, dx, dy, edge) return s and s.d == d and s.dx == dx and s.dy == dy and s.edge == edge end
    check(ws.n == 4 and is(ws[1], 5, 0, 0, "N") and is(ws[2], 0, 1, 0, "E") and is(ws[3], 5, 0, 1, "S") and is(ws[4], 0, 0, 0, "W"),
        "四條邊：有配對面的牆轉北、東、南、西，東邊與南邊移到隔壁那格")
    check(ls.n == 2 and is(ls[1], 0, 1, 0, "E") and is(ls[2], 0, 0, 0, "W"), "四條邊：沒有另一邊的牆只有對邊兩個")
    local cs, cf = Turn.states(Entry.resolve("pf_house_01_2")), Cur.faces(Entry.resolve("pf_house_01_2"))
    check(cs.n == cf.n and is(cs[1], cf[1], 0, 0, nil) and Turn.other(wallEntry, 0) == 5 and Turn.other(wallEntry, 5) == 0,
        "四條邊：佔兩條邊的牆角照舊用朝向清單、不移格；另一條邊的面互相找得到")
    -- 旋轉標記照游標實際輪流的 Turn.states（2026-11-16 Keys）：沒有另一邊的牆也能在對邊兩個之間轉，所以有標
    check(Win.canTurn("pf_house_01_0") == true and Win.canTurn("pf_lone_01_0") == true and Win.canTurn("gone_99_0") == false,
        "旋轉標記：放置時轉得動的才標（照 Turn.states）；不存在的不標")
    local function mir(n) return Cur.mirror(Entry.resolve("rf_01_" .. n)) end
    check(mir(0) == "rf_01_5" and mir(5) == "rf_01_0" and mir(1) == nil and mir(2) == nil and mir(3) == nil
        and Cur.mirror(wallEntry) == nil and Win.canTurn("rf_01_0") == true and Win.canTurn("rf_01_1") == false,
        "屋頂的鏡像片：候選的圖水平翻過來和自己一樣才配；左右對稱、形狀不同、沒有貼圖的不配；別的種類不配；配得到的有旋轉標記")
    local Nm = MinidoracatBuilder.Names
    Nm.reset()
    check(Nm.of("lighting_indoor_01_4"):find("IGUI_MBLD_Switch_4", 1, true)
        and Nm.short("lighting_indoor_01_4"):find("\nIGUI_MBLD_Switch_4", 1, true)
        and not Nm.of("lighting_indoor_03_0"):find("IGUI_MBLD_Switch", 1, true),
        "電燈開關的名稱：原版 8 張開關接「哪面牆、靠哪一頭」，方格的短名放在第二行；其他圖不接")
    Nm.reset()

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
            yOffsetCursor = 0, type = p:has("MoveType") and p:get("MoveType") or "Object" } -- 原版 :143
        function s:getTotalTableHeight(sq)
            for i = #sq.objects, 1, -1 do
                local o = sq.objects[i]
                local op = o:getSprite():getProperties()
                if op:has("IsTable") and tonumber(op:get("Surface")) then return o:getRenderYOffset() + tonumber(op:get("Surface")) end
            end
            return 0
        end
        function s:canPlaceMoveableInternal(_, sq)
            if self.type == "Vegitation" then -- 原版 :1892-1896：只放在圖名以 blends_natural 開頭的地面
                local f = sq:getFloor()
                return f ~= nil and f:getSprite():getName():sub(1, 14) == "blends_natural" and not sq:has("solid")
            end
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
    -- 樹籬、墓碑這類只放在天然地面：地面不對說 NOT_NATURAL；地面對但有東西擋、或沒有地板，照舊沒有原因碼
    local hedge = sp("rp_hedge_01_0", 2825, {}, { IsMoveAble = "", MoveType = "Vegitation" })
    local function ground(name) return { getSprite = function() return { getName = function() return name end } end } end
    local wood, soil = "floors_interior_tilesandwood_01_40", "blends_natural_01_22"
    local okH1 = Place.check("plant", hedge, at(101, 110, { floor = ground(soil) }), P)
    local okH2, cH2 = Place.check("plant", hedge, at(101, 111, { floor = ground(wood) }), P)
    local okH3, cH3 = Place.check("plant", hedge, at(101, 112, { flags = { solid = true }, floor = ground(soil) }), P)
    local okH4, cH4 = Place.check("plant", hedge, at(101, 113), P)
    local okH5 = Place.check("furniture", crate, at(101, 114, { floor = ground(wood) }), P)
    check(okH1 == true and okH2 == false and cH2 == "NOT_NATURAL",
        "樹籬這類（MoveType 是 Vegitation）：泥土草地放得下，鋪好的地板回 NOT_NATURAL")
    check(okH3 == false and cH3 == nil and okH4 == false and cH4 == nil and okH5 == true,
        "NOT_NATURAL 只在地面不對時說：天然地面上有東西擋、或沒有地板照舊沒有原因碼；一般家具放在地板上不受影響")
    local okH6, cH6 = Place.check("furniture", chair, at(101, 115, { flags = { solid = true }, floor = ground(wood) }), P)
    check(okH6 == false and cH6 == nil, "一般家具在鋪好的地板上被擋：照舊沒有原因碼，不說 NOT_NATURAL")
    -- 格位拼不起來的多格項目不列（玩家 2026-11-13 回報的水晶吊燈）：原點與其他片都說 BAD_GRID，不叫玩家去找原點
    check(select(2, Entry.resolve("lighting_indoor_03_0")) == "UNKNOWN" and Entry.why("lighting_indoor_03_0") == "BAD_GRID"
        and Entry.why("lighting_indoor_03_1") == "BAD_GRID" and Entry.resolve("rp_tall_01_0") ~= nil,
        "格位拼不起來的項目：解析不到（UNKNOWN），原點與其他片的原因都是 BAD_GRID；一般的兩層項目照舊列")
    -- 空位在上一層的格組（原版吊燈就是這種：下層兩片、上層只有一片的位置有圖）
    local upA = sp("rp_up_01_0", 2832, { "solid" }, { IsMoveAble = "" })
    local upB = sp("rp_up_01_1", 2833, { "solid" }, { IsMoveAble = "" })
    local upC = sp("rp_up_01_2", 2834, { "solid" }, { IsMoveAble = "" })
    tallGrid(2, 1, { { { upA, upB } }, { { upC } } })
    local GR, GC = MinidoracatBuilder.Rules, MinidoracatBuilder.Cost
    check(GR.gridHoles(upA) and GC.refund("furniture", upC) == "builder" and not GR.gridHoles(tallA)
        and GC.refund("furniture", tallA) == "pickup", "空位在上一層也算有空位，歸本工具拆；兩層都滿的照舊照原版拿起")
    -- 兩層樓高的物件：上一層沒有樓層時，預覽與伺服器回同一個原因，伺服器不在半空補格子
    local n1 = Check.item(P, "rp_tall_01_0", 0, { 104, 105, 0 }, PV)
    local n2 = Check.item(P, "rp_tall_01_0", 0, { 104, 105, 0 })
    check(n1 == "NO_UPPER" and n2 == "NO_UPPER" and squares["104,105,1"] == nil,
        "兩層樓高、上一層沒有格子：預覽與伺服器都回 NO_UPPER，伺服器不補那一格")
    local upSq = square(104, 105, 1)
    local n3 = Check.item(P, "rp_tall_01_0", 0, { 104, 105, 0 }, PV)
    obj(upSq, floorA)
    local n4 = Check.item(P, "rp_tall_01_0", 0, { 104, 105, 0 }, PV)
    check(n3 == "NO_UPPER" and n4 ~= "NO_UPPER", "上一層的格子是空的也算沒有樓層；上面有東西就照一般規則往下查")
    local n5 = Check.item(P, "rp_chair_01_0", 0, { 104, 106, 0 }, PV)
    check(n5 ~= "NO_UPPER", "只有一層的物件不查上一層")
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
    -- Quests & Achievements（選用整合）：facade 在時，只有付料的新建叫 built 一次（服主 2026-11-15）
    local qCalls = {}
    MinidoracatQuest = { v1 = { built = function(p) qCalls[#qCalls + 1] = p end } }
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
    check(#qCalls == 0, "Quest：缺料被拒、原地替換都不算建造")
    local wallCost = Cost.sum(Cost.forCells("wall", { wallN }, 1)).items
    local function fresh(p, y, paid) -- 在空格上新蓋一片牆（站近一點：MaxDistance）
        at(118, y)
        if paid then give(p, wallCost) end
        nonce = nonce + 1
        p.pos.x = 117.5
        local ok, cmd = build(p, nonce, "cs_wall_01_1", { 118, y, 0 })
        p.pos.x = 113.5
        return ok and cmd == "placed" and named(S(118, y), "cs_wall_01_1") ~= nil
    end
    check(fresh(P, 111, true) and #qCalls == 1 and qCalls[1] == P, "Quest：付料的新建叫 built(player) 一次")
    sb.CostMultiplier = 0
    check(fresh(P, 112) and #qCalls == 1, "Quest：材料倍率 0（沒扣到任何東西）照樣蓋、不算建造")
    sb.CostMultiplier = nil
    local QC = player({ id = 3299, x = 113.5, y = 113.5, here = here, cheat = true })
    check(fresh(QC, 113, true) and #qCalls == 1 and QC.inv:count("Base.Plank") == wallCost["Base.Plank"],
        "Quest：建造作弊（背包有料也不扣）不算建造")
    -- 這次拿走的東西從哪來都算（背包、地上、釘子盒、耗材任一）；都沒拿不算；放置出錯不算（審查 1115 Codex）
    local realPlan, realConsume, realBuild, realPrint = Materials.plan, Materials.consume, MinidoracatBuilder.Place.build, print
    Materials.consume = function() end
    local function shaped(over) -- 回這一次多叫了幾次 built（沒蓋成回 nil）
        local plan = { take = {}, ground = {}, boxes = {}, left = 0, uses = {} }
        for k, v in pairs(over) do plan[k] = v end
        Materials.plan = function() return plan end
        local n0 = #qCalls
        return fresh(P, 113) and #qCalls - n0 or nil
    end
    check(shaped({ take = { 1 } }) == 1 and shaped({ ground = { 1 } }) == 1 and shaped({ boxes = { 1 } }) == 1
        and shaped({ uses = { 1 } }) == 1 and shaped({}) == 0,
        "Quest：料來自背包、地上、釘子盒、耗材任一都算 1 個建造；什麼都沒拿不算")
    MinidoracatBuilder.Place.build = function() error("injected build failure") end
    Materials.plan = function() return { take = { 1 }, ground = {}, boxes = {}, left = 0, uses = {} } end
    local nFail = #qCalls
    local failed = not fresh(P, 113)
    local _, aFail = last()
    check(failed and aFail.code == "INTERNAL" and #qCalls == nFail, "Quest：放置出錯（INTERNAL）不算建造")
    MinidoracatBuilder.Place.build = realBuild
    -- built 的回傳：false＋錯誤碼印一行（帶錯誤碼）；單獨的 false（限速、還沒有帳號）與 true 不印
    local lines = {}
    print = function(s) if tostring(s):find("quest built", 1, true) then lines[#lines + 1] = s end end
    MinidoracatQuest.v1.built = function() return false, "not_ready" end
    local okCode = fresh(P, 113)
    local nCode = #lines
    MinidoracatQuest.v1.built = function() return false end
    local okLone = fresh(P, 113)
    MinidoracatQuest.v1.built = function() return true end
    local okTrue = fresh(P, 113)
    local nQuiet = #lines
    check(okCode and okLone and okTrue and nCode == 1 and nQuiet == 1 and lines[1]:find("not_ready", 1, true) ~= nil,
        "Quest 的 built 回 false＋錯誤碼：照樣蓋好、印一行帶錯誤碼；單獨的 false 與 true 不印")
    Materials.plan, Materials.consume = realPlan, realConsume
    MinidoracatQuest.v1.built = function() error("boom") end
    local okBoom = fresh(P, 114, true)
    print = realPrint
    check(okBoom and P.inv:count("Base.Plank") == 0 and #lines == 2 and lines[2]:find("boom", 1, true) ~= nil,
        "Quest 的 built 丟錯：照樣蓋好、照樣扣料，印一行帶錯誤訊息")
    MinidoracatQuest.v1.built = nil
    check(fresh(P, 115, true), "Quest 的 facade 沒有 built（舊版）：照常蓋")
    MinidoracatQuest = nil
    nowMs = nowMs + 6000 -- 上面多送的請求不佔後面的限流額度
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
    local qH = 0
    MinidoracatQuest = { v1 = { built = function() qH = qH + 1 end } }
    local okH, cmdH, aH = build(P, nonce, "cs_floor_01_1", { 114, 115, 0 })
    MinidoracatQuest = nil
    check(okH and cmdH == "placed" and aH.replaced == nil and not has(FH, OH) and named(FH, "cs_floor_01_1") ~= nil,
        "舊的一樓地板帳本對不上：照一般蓋新地板（不算替換、不卡 NOT_OURS）")
    check(qH == 1, "Quest：舊地板帳本對不上、照一般蓋的那次算 1 個建造（和 log 印 BUILD 同一個判斷）")
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
        function o:getObjectIndex() return 0 end
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
    local function lampE(id) return HARNESS_LEDGER("MinidoracatBuilder", id) end
    local posOf = MinidoracatBuilder.Store.pos

    -- 蓋燈：伺服器發編號寫進 keyId，帳本照編號記位置、蓋的圖與退料
    local saved = false
    for _, k in ipairs(HARNESS_GOS_KEYS.MinidoracatBuilder or {}) do saved = saved or k == "lamps" end
    check(saved, "帳本存檔白名單有 lamps（漏了重開後燈的帳本消失、每盞燈都拆不了）")
    local sq1 = S(144, 143)
    local L = lamp(sq1, lampA, "ours")
    local M = lamp(sq1, lampB, "ours")
    local eL, eM = lampE(L.keyId), lampE(M.keyId)
    check(L.keyId > 0 and M.keyId > 0 and L.keyId ~= M.keyId and eL ~= nil and eL.p == posOf(144, 143, 0) and eL.s == "kl_01_0"
        and eL.i["Base.ElectricWire"] == 2 and eM ~= nil and eM.s == "kl_01_1" and inst.built["144,143,0,kl_01_0"] == nil
        and inst.lamps.next > math.max(L.keyId, M.keyId),
        "蓋燈：發編號寫進 keyId，帳本照編號記位置、蓋的圖與退料（不寫 built）；同一格兩盞各一個編號")

    -- 同一格的燈：照圖名找到的是帳本沒有的那盞時不退料
    local X = lamp(sq1, lampB, "mark")
    L.spr = lampB
    X.spr, X.md.builderEntry = lampA, "kl_01_0"
    local c, a = unbuild(sq1, "kl_01_0")
    check(c == "dismantleSkipped" and a.code == "NOT_OURS" and next(here.dropped) == nil and has(sq1, X)
        and lampE(L.keyId) ~= nil, "照圖名找到同一格帳本沒有的那盞：NOT_OURS、不拆不退，L 的帳本還在")
    local X2 = lamp(sq1, lampA, "mark")
    sq1:transmitRemoveItemFromSquare(X2)
    check(lampE(L.keyId) ~= nil and lampE(M.keyId) ~= nil,
        "帳本沒有的燈移出世界：同一格別盞的帳本不動")
    L.spr, X.spr = lampA, lampB
    c = unbuild(sq1, "kl_01_0")
    check(c == "dismantled" and here.dropped["Base.ElectricWire"] == 2 and here.dropped["Base.ElectronicsScrap"] == 1
        and not has(sq1, L) and lampE(L.keyId) == nil and lampE(M.keyId) ~= nil,
        "L 照自己那筆退料，移除時只清 L 那筆（同一格的 M 還在）")
    M.spr = floorK
    local changed = Ledger.get(M)
    M.spr = lampB
    check(changed == nil and Ledger.get(M) ~= nil, "圖和蓋的時候不同就不認（拆除照現在的圖分種類），相同時照常認")
    local Y = lamp(S(146, 146), lampB)
    Y.keyId = M.keyId
    local moved = Ledger.get(Y)
    S(146, 146):transmitRemoveItemFromSquare(Y)
    check(moved == nil and lampE(M.keyId) ~= nil, "編號相同、不在帳本記的位置：不認，移出世界也不清那一筆")
    local old = lamp(sq1, lampA)
    old.keyId = M.keyId
    local reused = Ledger.get(old)
    sq1:transmitRemoveItemFromSquare(old)
    check(reused == nil and lampE(M.keyId) ~= nil,
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
    HARNESS_REOPEN(Ledger)
    local before = Ledger.legacy
    inst.built[landKey] = {}
    HARNESS_REOPEN(Ledger)
    check(before >= 4 and Ledger.legacy == before, "重開時數還沒定案的舊燈：樓梯平台不算")
    local mainSize = MinidoracatBuilder.Store.size(inst.built)
    fire("LoadChunk", sqA:getChunk())
    local a1, a2 = lampE(A1.keyId), lampE(A2.keyId)
    check(a1 ~= nil and a2 ~= nil and A1.keyId ~= A2.keyId and a1.s == "kl_01_0" and a1.p == posOf(144, 144, 0)
        and a1.i["Base.ElectricWire"] == 1 and a2.i["Base.ElectricWire"] == 3 and inst.built["144,144,0,kl_01_0"].id == nil
        and inst.built["144,144,0,kl_01_0"]["Base.ElectricWire"] == 1 and inst.built["144,144,0,kl_01_1"]["Base.ElectricWire"] == 3
        and MinidoracatBuilder.Store.size(inst.built) <= mainSize and V.keyId == -1,
        "讀到那一塊：舊紀錄照格上那盞本 MOD 的燈發編號、記進燈的帳本，退料照舊；舊紀錄原樣留到下一次開服（主系統的存檔沒有變大）；原版燈不算")
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
    check(onLanding.keyId == -1 and HARNESS_LEDGER("MinidoracatBuilder", landKey) ~= nil and inst.built[landKey] ~= nil,
        "樓梯平台的紀錄不當成舊燈搬：複製進分片，舊表那一筆留到下一次開服確認")
    fire("LoadChunk", sqA:getChunk())
    check(lampE(A1.keyId) == a1 and Ledger.legacy == before - 4 and count("LoadChunk") == 1,
        "同一塊再讀一次（還有別塊沒讀到、事件還掛著）：已定案，不再動")
    c = unbuild(sqA, "kl_01_1")
    check(c == "dismantled" and here.dropped["Base.ElectricWire"] == 3 and lampE(A2.keyId) == nil
        and inst.built["144,144,0,kl_01_1"] == nil and inst.built["144,144,0,kl_01_0"] ~= nil,
        "搬過的燈：本工具照搬過去的那筆退料；留著的舊紀錄跟著刪掉（別盞的不動）")
    inst.built["200,200,0,kl_01_0"] = nil

    -- 當機回溯：搬過的燈帶著編號存進 chunk、帳本回到搬之前，重開後照樣搬給它；同一格另有一盞帳本認不得的同款燈時兩盞都不搬
    local W = lamp(at(152, 152), lampA, "mark")
    W.keyId = 999
    local W2 = lamp(at(153, 152), lampA, "mark")
    W2.keyId = 998
    local X3 = lamp(S(153, 152), lampA, "mark")
    inst.built["152,152,0,kl_01_0"] = { ["Base.ElectricWire"] = 6 }
    inst.built["153,152,0,kl_01_0"] = { ["Base.ElectricWire"] = 8 }
    -- 同一格同一張圖另有一盞帳本認得的燈（不是從舊紀錄搬的）：不會被當成舊紀錄已經搬過
    local T1 = lamp(at(156, 152), lampA, "mark")
    Ledger.put(T1, { ["Base.ElectricWire"] = 2 })
    local T2 = lamp(S(156, 152), lampA, "mark")
    inst.built["156,152,0,kl_01_0"] = { ["Base.ElectricWire"] = 11 }
    HARNESS_REOPEN(Ledger)
    check(inst.built["144,144,0,kl_01_0"] == nil and lampE(A1.keyId) == a1 and lampE(A1.keyId).o == true,
        "下一次開服：分片讀得到從舊紀錄搬過去的那盞，舊紀錄這時才刪")
    local shadow = inst.built["156,152,0,kl_01_0"] ~= nil
    fire("LoadChunk", S(156, 152):getChunk())
    check(shadow and T2.keyId > 0 and T2.keyId ~= T1.keyId and lampE(T2.keyId).i["Base.ElectricWire"] == 11
        and lampE(T1.keyId).i["Base.ElectricWire"] == 2 and lampE(T1.keyId).o == nil,
        "同一格同一張圖另有一盞後來蓋的燈：舊紀錄不被它擋掉，讀到那一塊時照樣搬給還沒認得的那盞，退料各是各的")
    local T3 = lamp(S(156, 152), lampA, "mark")
    S(156, 152):transmitRemoveItemFromSquare(T3)
    check(inst.built["156,152,0,kl_01_0"] ~= nil and inst.built["156,152,0,kl_01_0"]["Base.ElectricWire"] == 11
        and lampE(T2.keyId) ~= nil,
        "這一場剛搬成、舊紀錄還留著（等下一次開服確認）：同一格另一盞帳本認不得的同款燈被移除，不動那一筆")
    -- 搬過的那盞旁邊之後多一盞帳本認不得的同款燈：舊紀錄已經刪了，不會再發給它（不多退）
    local A3 = lamp(S(144, 144), lampA, "mark")
    HARNESS_REOPEN(Ledger)
    fire("LoadChunk", sqA:getChunk())
    check(A3.keyId == -1 and Ledger.get(A3) == nil and lampE(A1.keyId) == a1, "搬過之後同一格多一盞帳本認不得的同款燈：不會領到那一筆")
    sqA:transmitRemoveItemFromSquare(A3)
    fire("LoadChunk", S(152, 152):getChunk())
    check(W.keyId > 0 and W.keyId ~= 999 and lampE(W.keyId).i["Base.ElectricWire"] == 6 and W2.keyId == 998
        and X3.keyId == -1 and inst.built["153,152,0,kl_01_0"] == nil,
        "舊紀錄那格的燈帶著帳本沒有的編號（當機回溯）：照樣搬過去；同一格另有一盞帳本認不得的同款燈：兩盞都不搬")

    -- 單機：帳本建好前就讀進來的塊，建好後第一個 tick 照舊鍵的位置找到就定案；那時還沒讀進來的塊讀進來再定案。
    -- 那一塊只有一筆舊鍵、它的格子已經不在（例：上一層拆掉了），塊本身讀進來了：照座標找得到那一塊，那一筆照樣定案（刪掉）
    local R = lamp(S(140, 140), lampA, "mark")
    at(171, 170) -- 第 21,21 塊讀進來了（只有這一格，沒有舊鍵）
    inst.built["140,140,0,kl_01_0"] = { ["Base.ElectricWire"] = 7 }
    inst.built["170,170,1,kl_01_0"] = { ["Base.ElectricWire"] = 2 }
    inst.built["160,160,0,kl_01_0"] = { ["Base.ElectricWire"] = 9 } -- 那一塊還沒讀進來
    HARNESS_REOPEN(Ledger)
    local ticks = count("OnTick") -- 含剛掛上的那一個 tick
    fire("OnTick")
    local onTick = R.keyId > 0 and lampE(R.keyId).i["Base.ElectricWire"] == 7 and count("OnTick") == ticks - 1
        and inst.built["170,170,1,kl_01_0"] == nil
        and inst.built["160,160,0,kl_01_0"] ~= nil and count("LoadChunk") == 1
    local F = lamp(at(160, 160), lampA, "mark")
    fire("LoadChunk", S(160, 160):getChunk())
    check(onTick and F.keyId > 0 and lampE(F.keyId).i["Base.ElectricWire"] == 9 and count("LoadChunk") == 0,
        "單機讀檔：帳本建好前讀進來的塊在建好後第一個 tick 定案、摘掉 tick 事件；還沒讀進來的塊讀進來時定案，都定案後摘掉讀塊事件")
    HARNESS_REOPEN(Ledger)
    check(count("LoadChunk") == 0 and count("OnTick") == ticks - 1, "沒有舊燈：開服不掛讀塊與 tick 事件（每塊、每格都不多花）")

    -- 定案出錯：那一塊的舊鍵留在 built、這一場不再試（讀塊事件照樣摘掉），下次開服重新分組照樣搬
    local E = lamp(at(180, 180), lampA, "mark")
    local hasMD = E.hasModData
    E.hasModData = function() error("harness: broken object") end
    inst.built["180,180,0,kl_01_0"] = { ["Base.ElectricWire"] = 4 }
    HARNESS_REOPEN(Ledger)
    fire("LoadChunk", S(180, 180):getChunk())
    local kept = inst.built["180,180,0,kl_01_0"] ~= nil and E.keyId == -1 and Ledger.legacy == 1 and count("LoadChunk") == 0
    E.hasModData = hasMD
    HARNESS_REOPEN(Ledger)
    fire("LoadChunk", S(180, 180):getChunk())
    check(kept and E.keyId > 0 and lampE(E.keyId).i["Base.ElectricWire"] == 4 and count("LoadChunk") == 0,
        "定案出錯：舊鍵留著、這一場摘掉事件，下次開服照樣搬")
    -- 主系統的檔寫成了、分片沒寫成：發過編號的舊紀錄還在，讀到那一塊時重新發編號，退料照舊
    local lostId = E.keyId
    for n = 1, 16 do
        local md = HARNESS_GOS_SHARDS["MinidoracatBuilder_" .. n]
        if md and md.data then md.data[lostId] = nil end
    end
    HARNESS_REOPEN(Ledger)
    local back = inst.built["180,180,0,kl_01_0"]
    fire("LoadChunk", S(180, 180):getChunk())
    check(back ~= nil and back["Base.ElectricWire"] == 4 and E.keyId > lostId
        and lampE(E.keyId).i["Base.ElectricWire"] == 4 and inst.built["180,180,0,kl_01_0"] == back,
        "發了編號之後只有主系統的檔寫成（分片沒寫成）：下一次開服舊紀錄照樣等、搬給那盞燈，退料沒有少")
    -- 帳本滿了記不進去：舊紀錄原樣留著，不當成已經搬過；之後放得下再搬
    local G = lamp(at(190, 190), lampA, "mark")
    inst.built["190,190,0,kl_01_0"] = { ["Base.ElectricWire"] = 5 }
    HARNESS_REOPEN(Ledger)
    local Store = MinidoracatBuilder.Store
    local keepB, keepH, realPrint = Store.SHARD_BYTES, Store.SHARD_HARD, print
    Store.SHARD_BYTES, Store.SHARD_HARD, HARNESS_GOS_COUNT = 1, 1, 100
    print = function() end
    local nextId = inst.lamps.next
    fire("LoadChunk", S(190, 190):getChunk())
    print = realPrint
    Store.SHARD_BYTES, Store.SHARD_HARD, HARNESS_GOS_COUNT = keepB, keepH, nil
    local full = inst.built["190,190,0,kl_01_0"]
    local stuck = full ~= nil and full["Base.ElectricWire"] == 5 and full.id == nil and Ledger.get(G) == nil and Ledger.legacy == 1
        and inst.lamps.next == nextId and G.keyId == -1
    HARNESS_REOPEN(Ledger)
    fire("LoadChunk", S(190, 190):getChunk())
    check(stuck and Ledger.get(G) ~= nil and Ledger.get(G)["Base.ElectricWire"] == 5,
        "帳本滿了記不進去：舊紀錄原樣留著（不算定案）、編號不用掉、燈不動，下次開服放得下時照樣搬")
    -- 還沒定案的舊燈（帳本滿了記不進去）被移除：舊紀錄跟著清
    local H = lamp(at(197, 197), lampA, "mark")
    inst.built["197,197,0,kl_01_0"] = { ["Base.ElectricWire"] = 3 }
    HARNESS_REOPEN(Ledger)
    Store.SHARD_BYTES, Store.SHARD_HARD, HARNESS_GOS_COUNT = 1, 1, 100
    print = function() end
    fire("LoadChunk", S(197, 197):getChunk())
    print = realPrint
    Store.SHARD_BYTES, Store.SHARD_HARD, HARNESS_GOS_COUNT = keepB, keepH, nil
    local H2 = lamp(S(197, 197), lampA, "mark")
    S(197, 197):transmitRemoveItemFromSquare(H2)
    local waiting = inst.built["197,197,0,kl_01_0"] ~= nil and H.keyId == -1
    S(197, 197):transmitRemoveItemFromSquare(H)
    check(waiting and inst.built["197,197,0,kl_01_0"] == nil,
        "還沒搬成的舊燈（帳本滿了記不進去）：同一格別盞認不得的燈被移除不動舊紀錄；它自己被移除才跟著清，不留給之後同一格同一張圖的燈")
    -- 還在等的舊燈所在的那一塊卸載再讀進來（物件是新的一份）：重新認是哪一盞。之後它被移除照樣清舊紀錄；
    -- 放得下了就搬，不必等到下次開服
    local sqJ, sqN = at(205, 205), at(206, 206)
    lamp(sqJ, lampA, "mark")
    lamp(sqN, lampA, "mark")
    inst.built["205,205,0,kl_01_0"] = { ["Base.ElectricWire"] = 6 }
    inst.built["206,206,0,kl_01_0"] = { ["Base.ElectricWire"] = 7 }
    HARNESS_REOPEN(Ledger)
    Store.SHARD_BYTES, Store.SHARD_HARD, HARNESS_GOS_COUNT = 1, 1, 100
    print = function() end
    fire("LoadChunk", sqJ:getChunk())
    table.remove(sqJ.objects) -- 卸載：舊的那一份不見了，沒有移除事件
    table.remove(sqN.objects)
    local J2, N2 = lamp(sqJ, lampA, "mark"), lamp(sqN, lampA, "mark")
    fire("LoadChunk", sqJ:getChunk())
    local hooked = count("LoadChunk") == 1 and Ledger.legacy == 2
    sqN:transmitRemoveItemFromSquare(N2)
    print = realPrint
    Store.SHARD_BYTES, Store.SHARD_HARD, HARNESS_GOS_COUNT = keepB, keepH, nil
    fire("LoadChunk", sqJ:getChunk())
    check(hooked and inst.built["206,206,0,kl_01_0"] == nil and J2.keyId > 0 and lampE(J2.keyId).i["Base.ElectricWire"] == 6
        and lampE(J2.keyId).o == true and inst.built["205,205,0,kl_01_0"] ~= nil and Ledger.legacy == 0
        and count("LoadChunk") == 0,
        "還在等的舊燈那一塊卸載再讀進來：重新認新的那一份（讀塊事件留著）；它被移除就清舊紀錄；放得下了、那一塊再讀進來就搬")
    sqJ:transmitRemoveItemFromSquare(J2)
    -- 退料表讀不懂的舊紀錄：重試也一樣，刪掉（那盞本工具拆不了），不留著每次開服重來
    local U = lamp(at(195, 195), lampA, "mark")
    inst.built["195,195,0,kl_01_0"] = { ["Base.ElectricWire"] = {} }
    HARNESS_REOPEN(Ledger)
    nextId = inst.lamps.next
    print = function() end
    fire("LoadChunk", S(195, 195):getChunk())
    print = realPrint
    check(inst.built["195,195,0,kl_01_0"] == nil and U.keyId == -1 and Ledger.get(U) == nil and Ledger.legacy == 0
        and inst.lamps.next == nextId, "退料表讀不懂的舊燈紀錄：刪掉、算定案，不發編號")
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
    -- 取代前一排的提示框（Recipes.lua 的 hintPanel）：只記顯示與否
    local realUIElement, realMUI, hintShown = ISUIElement, MinidoracatUI, {}
    ISUIElement = { derive = function(_, name)
        local cls = {}
        function cls:new() return setmetatable({}, { __index = cls }) end
        function cls:initialise() end
        function cls:addToUIManager() end
        function cls:setVisible(v) self.visible = v hintShown[self.pn] = v end
        function cls:getIsVisible() return self.visible == true end
        return cls
    end }
    MinidoracatUI = { v1 = { Theme = { create = function() return { colors = {} } end } } }
    -- 拖一排的假原版（下面 ISBuildIsoEntity 那段用）：虛影圖記每次畫的位置與顏色
    local ghosts, badSq, vanillaRender, tried, walkFail, rejectAdd = {}, {}, {}, {}, false, false
    local qs = {} -- 角色 → 那個角色的動作佇列（假的 ISTimedActionQueue 用）
    local function qOf(p)
        qs[p] = qs[p] or {}
        return qs[p]
    end
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
        function L:startCraftAction(act) -- 照 BuildLogic.java:214-228：設進行中，發 onStartCraft（帶動作）
            self.busy = true
            for _, l in ipairs(self.listeners) do if l[1] == "onStartCraft" then l[2](l[3], act) end end
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
    function P:isDead() return self.dead == true end
    P.inv = {} -- 背包裡有的完整類型 → true
    function P:getInventory()
        return { getAllTypeEvalRecurse = function(_, ft)
            return javaList(P.inv[ft] and { { getFullType = function() return ft end } } or {})
        end }
    end
    local seats = { [0] = P } -- 座位 → 角色（分割畫面、死了重生換角色時拖一排那段改）
    getSpecificPlayer = function(pn) return seats[pn] end
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
    -- 照原版順序：先 startCraftAction(動作)，走不到當場收尾；走得到才排進那個角色的佇列（拒收時沒排、也不收尾）
    function ISBuildIsoEntity:tryBuild(x, y, z)
        tried[#tried + 1] = { x, y, z, self.nSprite, north = self.north, who = self.character }
        -- setOnComplete／setOnCancel 記下這一刻游標上的 onActionComplete（ISBuildingObject.lua:207-208）；action＝Java 動作：
        -- 單機時間到 finished()、多人伺服器回報完成 isForceComplete()（BaseAction.java:59-68,174-176）
        local act = { Type = "ISBuildAction", character = self.character, cursor = self, onDone = self.onActionComplete }
        act.action = { isForceComplete = function() return act.forced == true end, finished = function() return act.fin == true end }
        self.buildPanelLogic:startCraftAction(act)
        if walkFail then return self:onActionComplete() end -- 走不到：原版當場收尾（ISBuildingObject.lua:283-285）
        if rejectAdd then return end -- 拖屍體、睡著：ISTimedActionQueue.add 直接回（ISTimedActionQueue.lua:157-169）
        local q = qOf(self.character)
        q[#q + 1] = act
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
    -- doing＝Java 那邊還有動作（原版動作結束後 CharacterActions 晚一點才空，實測 builder-rdprobe-1112a）；佇列照角色分開
    local doing, cleared = false, 0
    ISTimedActionQueue = {
        isPlayerDoingAction = function(p) return doing or #qOf(p) > 0 end,
        hasAction = function(a)
            for _, x in ipairs(a and qOf(a.character) or {}) do if x == a then return true end end
            return false
        end,
        getTimedActionQueue = function(p) return { queue = qOf(p) } end,
        clear = function(p) -- 照原版：清佇列時正在跑、還沒開始的建造動作都當場收尾（實測 builder-rdprobe-1112a 的 interrupt、walkCancel）
            cleared = cleared + 1
            local q = qOf(p)
            qs[p] = {}
            for _, a in ipairs(q) do if a.onDone then a.onDone(a.cursor) end end
        end }
    local Client = B.Client
    local toasts2, realToast2 = {}, B.Messages.toast
    B.Messages.toast = function(_, text, title) toasts2[#toasts2 + 1] = tostring(title) .. "|" .. text end
    local function place(x, y, name) -- 那格出現蓋好的牆
        local sq = getCell():getGridSquare(x, y, 0)
        sq.objects[#sq.objects + 1] = { getSprite = function() return { getName = function() return name end } end }
    end
    -- 那格動作結束（這個游標在佇列最前面的那個）；x 有給＝單機蓋好了（時間到、物件當場出現）。mp＝多人伺服器回報完成：
    -- forceComplete、收尾時動作還在佇列裡，物件還沒到（要另外 place）。done＝單機時間到了卻沒蓋出來（create 失敗）
    local function finish(o, x, y, mp, done)
        local q = qOf(o.character)
        local act
        for i, a in ipairs(q) do
            if a.cursor == o then
                act = a
                if not mp then table.remove(q, i) end
                break
            end
        end
        if mp then
            act.forced = true
        elseif x then
            place(x, y, "rcp_walls_01_0")
            act.fin = true
        elseif done then
            act.fin = true
        end
        doing = true
        act.onDone(o)
        fire("OnTick")
        return act
    end
    local function unqueue(act) -- 動作退出佇列
        local q = qOf(act.character)
        for i, a in ipairs(q) do if a == act then return table.remove(q, i) end end
    end
    local function rowGhosts() -- 排隊虛影（OnPostRender）畫在哪幾格
        ghosts = {}
        fire("OnPostRender")
        local at = {}
        for _, g in ipairs(ghosts) do if g.name ~= "queued" then at[#at + 1] = g.x .. "," .. g.y end end
        return table.concat(at, " ")
    end
    -- 從 (x, y) 往東拖到 ex 再放開（同一幀 render 兩次：按住拖、放開）
    local function dragRow(c, x, y, ex)
        c.square = getCell():getGridSquare(x, y, 0)
        c.isLeftDown, c.build = true, false
        c:rotateMouse(ex, y)
        c:render(x, y, 0, c.square)
        c.isLeftDown, c.build = false, true
        c:render(x, y, 0, c.square)
        c:tryBuild(x, y, 0)
        c.build = false
    end
    local function clearSq(x1, x2, y)
        for x = x1, x2 do getCell():getGridSquare(x, y, 0).objects = {} end
    end
    local wallR = byId["recipe:Base.WoodWall"]
    check(Recipes.dragMode(wallR) == "ring" and Recipes.dragMode(barrel) == nil,
        "能拖一排：圖塊同種類能拖、每面一格的配方（牆照 ring）；集雨桶（家具、兩格）不能")
    local w = Recipes.build(0, wallR.id)
    local bar = Recipes.build(0, barrel.id)
    check(w.mbldRow == true and w.blockAfterPlace == false and rawget(w, "render") ~= nil and rawget(w, "tryBuild") ~= nil
        and bar.mbldRow == nil and bar.blockAfterPlace == true and rawget(bar, "rotateMouse") == nil and rawget(bar, "tryBuild") ~= nil,
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
    Client.pending, Client.pendingUnbuild = { n = 9, player = P }, { n = 9, player = P }
    local c0 = cleared
    w:tryBuild(50, 50, 0)
    w.build = false
    check(cleared == c0 + 1 and Client.pending == nil and Client.pendingUnbuild == nil and #tried == 1
        and tried[1][1] == 50 and tried[1][4] == 2 and tried[1].north == true and w.nSprite == 2,
        "放開：清佇列、這個角色的圖塊建造與拆除請求作廢（每人一個請求），送第一格（那格的面），送完換回游標的面")
    check(rowGhosts() == "50,50 51,50 53,50", "還沒蓋好的格子畫排隊虛影（擋住的 52 不送、不畫）")
    -- MP：收尾時動作還在佇列裡（builder-rdprobe-1112a-mp 的 queue1=ISBuildAction/true），退出前不送；伺服器回報完成之外，
    -- 那格還要真的出現（審查 1112 Codex R4：動作做完不代表 create 成功）
    local realIC = isClient
    isClient = function() return true end
    local a1 = finish(w, 50, 50, true)
    doing = false
    fire("OnTick")
    check(#tried == 1, "第一格伺服器回報完成、物件還沒到、動作還在佇列裡：先不送")
    place(50, 50, "rcp_walls_01_0")
    unqueue(a1)
    doing = true
    fire("OnTick")
    check(#tried == 1, "物件到了、動作退出佇列、Java 那邊還在收：先不送")
    doing = false
    fire("OnTick")
    check(#tried == 2 and tried[2][1] == 51 and rowGhosts() == "51,50 53,50", "佇列空了：送下一格，蓋好的那格不再畫")
    -- 伺服器回報完成，那格一直沒出現（create 失敗：車開進來、材料被拿走）：等 CONFIRM_MS，到了停下、說蓋好幾格，不再送
    local t2 = #toasts2
    local a2 = finish(w, nil, nil, true)
    doing = false
    nowMs = nowMs + 4000
    fire("OnTick")
    check(#tried == 2 and #toasts2 == t2 and Recipes.row(0) ~= nil, "伺服器回報完成、物件還沒到：先等（5 秒內）")
    nowMs = nowMs + 1500
    fire("OnTick")
    check(#tried == 2 and toasts2[#toasts2] == "IGUI_MBLD_Interrupted|IGUI_MBLD_Recipe_NotBuilt(1,3)" and Recipes.row(0) == nil
        and rowGhosts() == "", "等了 5 秒還沒出現：照沒蓋出來停下、說那格沒蓋出來、蓋好 1／3 格（不多算，不說被打斷），不再送，排隊虛影收掉")
    isClient = realIC
    qs[P] = {}
    -- 單機：時間到了卻沒蓋出來（create 失敗）：不等，當場停、說蓋好幾格
    clearSq(44, 46, 55)
    dragRow(w, 44, 55, 46)
    finish(w, 44, 55)
    doing = false
    fire("OnTick")
    finish(w, nil, nil, false, true)
    fire("OnTick")
    check(#tried == 4 and toasts2[#toasts2] == "IGUI_MBLD_Interrupted|IGUI_MBLD_Recipe_NotBuilt(1,3)" and Recipes.row(0) == nil,
        "單機動作做完、那格沒出現：當場停下、說那格沒蓋出來、只算蓋好的 1 格、不送第 3 格")
    -- 打斷：動作沒做完（不是時間到、也不是伺服器回報完成）：下一個 tick 就停下整排，不再等
    clearSq(44, 46, 56)
    dragRow(w, 44, 56, 46)
    finish(w, 44, 56)
    doing = false
    fire("OnTick")
    finish(w)
    doing = false
    fire("OnTick")
    check(#tried == 6 and toasts2[#toasts2] == "IGUI_MBLD_Interrupted|IGUI_MBLD_Stopped(1,3)" and rowGhosts() == "",
        "被打斷：那格沒蓋好就停下整排、說蓋好幾格，不再送，排隊虛影收掉")
    -- 材料不夠：兩格，第一格蓋好後做不了
    clearSq(50, 51, 51)
    dragRow(w, 50, 51, 51)
    finish(w, 50, 51)
    rWall.o.can = false
    doing = false
    fire("OnTick")
    rWall.o.can = nil
    check(#tried == 7 and toasts2[#toasts2] == "IGUI_MBLD_Interrupted|IGUI_MBLD_Recipe_Blocked",
        "材料不夠做下一格：停下整排、說缺料（詳情寫缺什麼），不再送")
    -- 審查 1112 Codex：第一格蓋好後玩家插了別的動作（吃東西），之後取消它：照被打斷停下，不再送、不再扣
    clearSq(50, 52, 53)
    dragRow(w, 50, 53, 52)
    local eat = { Type = "ISEatFoodAction", character = P }
    local q = qOf(P)
    q[#q + 1] = eat
    finish(w, 50, 53)
    doing = false
    fire("OnTick")
    local stoppedEat = toasts2[#toasts2]
    qs[P] = {} -- 玩家取消吃東西
    fire("OnTick")
    nowMs = nowMs + 2000
    fire("OnTick")
    check(#tried == 8 and stoppedEat == "IGUI_MBLD_Interrupted|IGUI_MBLD_Stopped(1,3)" and Recipes.row(0) == nil,
        "第一格蓋好後佇列裡插了別的動作：照被打斷停下；那個動作被取消、佇列空了也不再接著蓋（審查 1112 Codex）")
    -- 審查 1112 Claude：舊的那格的動作沒被清掉（目前動作是 ISQueueActionsAction 時 clear 只清它加的，ISTimedActionQueue.lua:46-55），
    -- 新的一排開始後它才收尾：不能算到新的一排
    clearSq(44, 46, 60)
    clearSq(47, 49, 60)
    dragRow(w, 44, 60, 46)
    local old = qOf(P)[1]
    local realClear = ISTimedActionQueue.clear
    ISTimedActionQueue.clear = function() cleared = cleared + 1 end -- 沒清掉
    dragRow(w, 47, 60, 49)
    ISTimedActionQueue.clear = realClear
    table.remove(qOf(P), 1) -- 舊的那格做完（單機：先退出佇列再收尾）
    old.fin = true
    place(44, 60, "rcp_walls_01_0")
    old.onDone(w)
    doing = false
    fire("OnTick")
    local row3 = Recipes.row(0)
    check(row3 ~= nil and row3.cells[1][1] == 47 and row3.doneAt == nil and row3.i == 1 and tried[#tried][1] == 47
        and BL.busy == false,
        "舊的那格晚到的收尾不算到新的一排（每格送出時記自己的收尾，審查 1112 Claude）；原版收尾照樣清掉 BuildLogic 進行中的配方")
    -- 審查 1112 Claude：配方游標放下會取消前一排：放開前在游標旁寫會取消幾格（同圖塊游標的 IGUI_MBLD_Replace）
    local cnt = B.Cursor.cancels(P)
    w.canBeBuild, w.isLeftDown, w.build = true, false, false
    w:render(50, 59, 0, getCell():getGridSquare(50, 59, 0))
    local barHint
    bar.canBeBuild = true
    bar:render(50, 59, 0, getCell():getGridSquare(50, 59, 0))
    barHint = bar.mbldHint
    check(cnt == 3 and Recipes.left(0, true) == 3 and Recipes.left(0, false) == 2 and w.mbldHint == "IGUI_MBLD_Replace(3)"
        and hintShown[0] == true and barHint == "IGUI_MBLD_Replace(2)",
        "放開前寫會取消幾格：能拖的游標算整排還沒蓋的（含正在蓋的那格），不能拖的只算還沒送的；圖塊游標與拆除選單用 Cursor.cancels 同一份")
    -- 新一排的第一格因此扣料失敗（BuildLogic.performCurrentRecipe 沒有進行中的配方，BuildLogic.java:237-250）：
    -- 動作做完、那格沒出現 → 照沒蓋出來停下，不誤算（審查 1112 Claude R4）
    finish(w, nil, nil, false, true)
    doing = false
    fire("OnTick")
    check(Recipes.row(0) == nil and toasts2[#toasts2] == "nil|IGUI_MBLD_Recipe_NotBuilt(0,3)" and #getCell():getGridSquare(47, 60, 0).objects == 0,
        "舊收尾清掉進行中的配方、新的第一格沒蓋出來：停下、說那格沒蓋出來（0／3）")
    qs[P] = {}
    w:render(50, 59, 0, getCell():getGridSquare(50, 59, 0))
    check(Recipes.row(0) == nil and w.mbldHint == nil and hintShown[0] == false, "那一排沒了：提示收起")
    -- 審查 1112 Codex：原版不收建造動作（拖屍體）也不回呼：下一個 tick 就停下、清掉進行中、說一格都沒蓋
    clearSq(50, 52, 54)
    rejectAdd = true
    dragRow(w, 50, 54, 52)
    rejectAdd = false
    local busyAfterSend = BL.busy
    fire("OnTick")
    check(#tried == 11 and busyAfterSend == true and BL.busy == false and Recipes.row(0) == nil
        and toasts2[#toasts2] == "nil|IGUI_MBLD_Refuse_WALK",
        "原版不收這格的動作（拖屍體）：整排停下、清掉進行中、說一格都沒蓋，不會一直等（審查 1112 Codex）")
    -- 動作排進去了，之後被重設佇列（原版 bugged action）拿掉、沒有收尾：同樣停下
    clearSq(50, 52, 55)
    dragRow(w, 50, 55, 52)
    fire("OnTick")
    local waiting = Recipes.row(0) ~= nil
    qs[P] = {}
    fire("OnTick")
    check(waiting and Recipes.row(0) == nil and #tried == 12, "那格的動作離開佇列卻沒收尾：停下，不一直等")
    -- 排隊中再拖一排：取代前一排；被取代的那格收尾不算停下、不通知
    w.square = getCell():getGridSquare(44, 44, 0)
    w:tryBuild(44, 44, 0)
    t2 = #toasts2
    dragRow(w, 44, 44, 46)
    nowMs = nowMs + 2000
    doing = false
    fire("OnTick")
    check(#toasts2 == t2 and #tried == 14 and tried[14][1] == 44 and tried[14][2] == 44 and rowGhosts() == "44,44 45,44 46,44",
        "排隊中再拖：清掉舊的那格、送新的一排第一格；舊的那格不通知")
    -- 這個角色的圖塊項目送出建造（Client.build 設 pending、清佇列）：這一排安靜放掉
    Client.pending = { n = 10, player = P }
    finish(w)
    nowMs = nowMs + 2000
    fire("OnTick")
    check(#toasts2 == t2 and #tried == 14 and rowGhosts() == "", "圖塊項目的建造取代了這一排：不通知、不再送")
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
    qs[P] = {}
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
    doing = false
    fire("OnTick")
    -- 審查 1112 Codex：分割畫面兩位本機玩家各拖一排，互相不清對方的請求、佇列，也不因對方的請求放掉自己的那排
    local P2 = setmetatable({ levels = { Woodwork = 3 } }, { __index = P })
    function P2:getPlayerNum() return 1 end
    seats[1] = P2
    w = Recipes.build(0, wallR.id)
    getCell():setDrag(w, 0)
    local w2 = Recipes.build(1, wallR.id)
    getCell():setDrag(w2, 1)
    w.nSprite, w2.nSprite = 2, 2
    clearSq(40, 42, 57)
    clearSq(40, 42, 58)
    dragRow(w, 40, 57, 42)
    local n0 = #tried
    Client.pending, Client.pendingUnbuild = { n = 20, player = P }, { n = 21, player = P }
    local c1 = cleared
    dragRow(w2, 40, 58, 42)
    check(Client.pending and Client.pending.n == 20 and Client.pendingUnbuild and Client.pendingUnbuild.n == 21
        and cleared == c1 + 1 and #qOf(P) == 1 and #qOf(P2) == 1 and tried[n0 + 1].who == P2,
        "第二位玩家放開一排：只清自己的佇列，第一位的圖塊建造、拆除請求都還在（審查 1112 Codex）")
    Client.pending, Client.pendingUnbuild = nil, nil
    dragRow(w, 40, 57, 42) -- 第一位重新拖（剛才的 pending 屬於他，已作廢）
    Client.pending = { n = 22, player = P2 } -- 第二位的圖塊建造：放掉第二位的那排，第一位的照舊
    fire("OnTick")
    local keep1 = Recipes.row(0) ~= nil and Recipes.row(1) == nil
    finish(w, 40, 57)
    doing = false
    fire("OnTick")
    local sent1 = tried[#tried].who == P and tried[#tried][1] == 41
    Client.pending = { n = 23, player = P }
    fire("OnTick")
    check(keep1 and sent1 and Recipes.row(0) == nil,
        "第二位玩家的圖塊請求只放掉他自己的那排，第一位的照樣送下一格；第一位自己的請求才放掉他的（審查 1112 Codex）")
    Client.pending = nil
    -- 審查 1112 Codex：一排進行中角色死了、或那個座位換了角色：放掉那排，不替舊角色再送
    clearSq(40, 42, 58)
    dragRow(w2, 40, 58, 42)
    P2.dead = true
    finish(w2, 40, 58)
    doing = false
    nowMs = nowMs + 2000
    local n1 = #tried
    fire("OnTick")
    check(Recipes.row(1) == nil and #tried == n1, "一排進行中角色死了：放掉那排，不再送（死者 isPlayerDoingAction 回 false）")
    P2.dead = nil
    w2 = Recipes.build(1, wallR.id)
    w2.nSprite = 2
    clearSq(40, 42, 58)
    dragRow(w2, 40, 58, 42)
    finish(w2, 40, 58)
    local P3 = setmetatable({ levels = { Woodwork = 3 } }, { __index = P2 })
    seats[1] = P3 -- 同座位重生成新角色
    doing = false
    n1 = #tried
    fire("OnTick")
    check(Recipes.row(1) == nil and #tried == n1, "那個座位換了角色：放掉舊角色的那排，不替它再送")
    seats[1] = nil
    getCell():setDrag(nil, 1)
    getCell():setDrag(nil, 0)
    B.Messages.toast = realToast2
    ISBuildingObject, getCore, ISTimedActionQueue = realBase, realCore, realQueue

    getSpecificPlayer, getCell, SpriteConfigManager.GetObjectInfoList, getText = realSpecific, realCell, realInfos, realGetText
    ISTimedActionQueue.isPlayerDoingAction, Recipes.onEnd, clockStep, JoypadState = realDoing, realOnEnd, step0, realJoy
    ISUIElement, MinidoracatUI = realUIElement, realMUI
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

print("情境四十五：水井與手壓水泵、植物（使用者 2026-11-13 設計稿 BZkbfGWbZppo 選 well=off、plant=all）：分類、開關、價錢、放置、拆除")
;(function()
    nowMs = nowMs + 180000
    local Place, Dismantle = MinidoracatBuilder.Place, MinidoracatBuilder.Dismantle
    local keepMap, keepOrder, realInst = spriteMap, spriteOrder, instanceof
    local keepRM, keepMult = sb.RecipeMaterials, sb.CostMultiplier
    sb.RecipeMaterials, sb.CostMultiplier = nil, nil
    local function code(o, name) return select(2, Rules.classify(sprite(name or "test_01_0", 5, o))) end
    local function show(t)
        local list = {}
        for k, v in pairs(t) do list[#list + 1] = k .. "=" .. v end
        table.sort(list)
        return table.concat(list, ",")
    end
    -- 原版屬性（temp/water-grass-1113/props.py 離線讀的 tiledef）。flags＝旗標，keys＝字串鍵
    local WELL = { flags = { "solidtrans", "EntityScript" }, keys = { BlocksPlacement = "", waterAmount = "999999", waterMaxAmount = "" } }
    local PUMP = { flags = { "solidtrans" }, keys = { BlocksPlacement = "", HitByCar = "", IsLow = "", waterAmount = "999999" } }
    local GRASS = { flags = { "canBeRemoved" }, keys = { MoveWithWind = "", WindType = "1" } }               -- e_newgrass_1_8
    local WEED = { flags = { "canBeRemoved", "vegitation" }, keys = { BlocksPlacement = "", MoveWithWind = "" } } -- d_plants_1_16
    local OVERLAY = { flags = { "attachedFloor", "canBeRemoved", "vegitation" }, keys = { MoveWithWind = "" } } -- blends_grassoverlays_01
    local INDOOR = { keys = { IsMoveAble = "", BlocksPlacement = "", CustomName = "Chinese Evergreen", PickUpWeight = "150" } }
    local BED = { flags = { "attachedFloor" }, keys = { IsMoveAble = "", MoveType = "Vegitation", BlocksPlacement = "", PickUpWeight = "20" } }
    local HEDGE = { flags = { "vegitation" }, keys = { IsMoveAble = "", Bush = "", PickUpWeight = "150" } }
    local GRAVE = { keys = { IsMoveAble = "", MoveType = "Vegitation", BlocksPlacement = "", StopCar = "" } }
    local MAIL = { keys = { IsMoveAble = "", MoveType = "Vegitation", container = "postbox", BlocksPlacement = "" } }

    -- 分類
    local wells = true
    for _, n in ipairs({ "camping_01_16", "camping_01_64", "camping_01_65", "camping_01_66", "camping_01_67" }) do
        wells = wells and kind(WELL, n) == "well" and kind(PUMP, n) == "well"
    end
    check(wells, "水井與手壓水泵：原版 5 張都歸 well（井帶 EntityScript、無限水也收）")
    check(kind(PUMP, "camping_01_17") == nil and code(PUMP, "camping_01_17") == "WATER"
        and code({ flags = { "solidfloor" }, keys = { waterAmount = "9999" } }, "blends_natural_02_6") == "WATER"
        and kind(WELL, "camping_01_17") == nil,
        "其他無限水照舊不列（WATER；帶 EntityScript 的另回 ENTITY；水面 blends_natural_02 見情境四十七）")
    check(kind(GRASS, "e_newgrass_1_8") == "plant" and kind(WEED, "d_plants_1_16") == "plant"
        and kind({ flags = { "canBeRemoved" }, keys = { BlocksPlacement = "", MoveWithWind = "" } }, "d_plants_1_0") == "plant"
        and kind(OVERLAY, "blends_grassoverlays_01_0") == "plant",
        "草與野花（不能搬、canBeRemoved＋MoveWithWind）：e_ 草、d_plants、草地疊圖都歸植物")
    check(kind(INDOOR, "vegetation_indoor_01_7") == "plant" and kind(BED, "vegetation_ornamental_01_16") == "plant"
        and kind(HEDGE) == "plant"
        and kind({ flags = { "vegitation" }, keys = { IsMoveAble = "", Bush = "", MoveType = "Vegitation" } }, "f_bushes_1_96") == "plant",
        "能搬的觀賞植物：盆栽（vegetation_indoor_ 整組）、花圃（觀賞植物組的 MoveType=Vegitation）、帶 vegitation／Bush 的樹叢")
    check(kind({ flags = { "attachedFloor" }, keys = { IsMoveAble = "", BlocksPlacement = "" } }, "vegetation_ornamental_01_24") == "furniture"
        and kind({ flags = { "solidtrans" }, keys = { IsMoveAble = "" } }, "vegetation_ornamental_01_50") == "furniture"
        and kind(GRAVE, "location_community_cemetary_01_0") == "furniture" and kind(MAIL, "street_decoration_01_18") == "container",
        "觀賞植物組裡能搬卻不是植物的（火鶴、鳥浴盆）與 MoveType=Vegitation 的墓碑、郵筒：照一般屬性分")
    check(code(GRASS, "vegetation_farming_01_0") == "PREFIX" and code(WEED, "vegetation_farm_01_0") == "PREFIX"
        and code({ flags = { "vegitation" } }, "vegetation_trees_01_8") == "PREFIX"
        and code({ flags = { "vegitation", "canBeRemoved" }, keys = { IsMoveAble = "", MoveType = "Vegitation", MoveWithWind = "" } },
            "e_newgrass_1_0") == "PREFIX"
        and code({ flags = { "vegitation", "canBeCut" }, keys = { MoveWithWind = "" } }, "f_bushes_1_0") == "PREFIX"
        and code({ flags = { "vegitation", "canBeCut" }, keys = { IsMoveAble = "", Bush = "" } }, "f_bushes_1_8") == "PREFIX"
        and code({ flags = { "vegitation", "attachedFloor" } }, "vegetation_groundcover_01_0") == "PREFIX"
        and code({ keys = { RoofGroup = "1" } }, "e_roof_snow_01_3") == "PREFIX",
        "反面：農作物、晾架、樹、e_ 的能搬樹籬、會被砍的樹叢、地被、積雪圖照舊 PREFIX")
    check(code({ flags = { "canBeRemoved" }, keys = { MoveWithWind = "", IsWaterCollector = "" } }) == "COLLECTOR"
        and code({ flags = { "canBeRemoved" }, keys = { MoveWithWind = "", waterAmount = "9999" } }) == "WATER"
        and code({ flags = { "vegitation" }, keys = { IsMoveAble = "", StackReplaceTileOffset = "-1" } }) == "STACK"
        and code({ flags = { "vegitation" }, keys = { IsMoveAble = "", CustomItem = "Base.Tent" } }) == "PLANT"
        and code({ flags = { "canBeRemoved" }, keys = { MoveWithWind = "", IsWaterCollector = "" } }, "e_newgrass_1_8") == "COLLECTOR"
        and code({ flags = { "vegitation" }, keys = { IsMoveAble = "", StackReplaceTileOffset = "-1" } },
            "vegetation_ornamental_01_16") == "STACK",
        "植物候選被擋時的原因碼：集水 COLLECTOR、無限水 WATER、疊放圖 STACK、專用物件 PLANT（玩家看到的說明照它）；名稱前綴那條路相同")
    check(code({ type = T.tree }) == "TREE" and code({ flags = { "vegitation" }, keys = { tree = "1", IsMoveAble = "" } }) == "PLANT"
        and code({ flags = { "vegitation" }, keys = { IsMoveAble = "", container = "bush" } }, "vegetation_foliage_01_8") == "PLANT"
        and code({ flags = { "vegitation" }, keys = { BlocksPlacement = "" } }) == "PLANT"
        and code({ flags = { "canBeRemoved", "canBeCut" }, keys = { MoveWithWind = "" } }) == "PLANT",
        "反面：樹、帶 tree 的、有容器的樹叢、不能搬又不是草的植物、會被砍的草叢：PLANT")
    check(kind({ flags = { "attachedFloor", "canBeRemoved" }, keys = { MoveWithWind = "", WindType = "1" } }, "d_streetcracks_1_0") == "floorOverlay"
        and kind({ flags = { "WallOverlay", "canBeRemoved" }, keys = { MoveWithWind = "" } }, "f_wallvines_1_0") == "wallObject"
        and kind({ flags = { "canBeRemoved" } }, "d_generic_1_99") == nil,
        "反面：地面裂縫（attachedFloor 沒有 vegitation）照舊地面覆蓋、牆上藤蔓（WallOverlay）照舊掛牆物、沒有 MoveWithWind 的不算草")
    check(code({ flags = { "canBeRemoved", "EntityScript" }, keys = { MoveWithWind = "" } }, "e_newgrass_1_9") == "ENTITY",
        "建造配方的圖照舊只收地板與地面覆蓋：帶 EntityScript 的草回 ENTITY")
    check(Rules.isGrass("plant", sprite("g_01_0", 5, GRASS):getProperties())
        and not Rules.isGrass("plant", sprite("g_01_0", 5, INDOOR):getProperties())
        and not Rules.isGrass("furniture", sprite("g_01_0", 5, GRASS):getProperties()), "Rules.isGrass：只認不能搬的植物")

    -- 種類開關：well 預設關（缺鍵、非 true 都當關），plant 預設開
    local ki = {}
    for i, k in ipairs(Entry.KINDS) do ki[k] = i end
    check(ki.well == ki.solid + 1 and ki.plant == ki.overlay + 1 and Entry.KIND_KEY.well == "KindWell"
        and Entry.KIND_KEY.plant == "KindPlant" and Entry.BUILDABLE.well and Entry.BUILDABLE.plant,
        "種類表：well 接在 solid 後、plant 接在 overlay 後，沙盒鍵 KindWell／KindPlant")
    check(Entry.kindOn("well", {}) == false and Entry.kindOn("well", { KindWell = false }) == false
        and Entry.kindOn("well", { KindWell = "true" }) == false and Entry.kindOn("well", { KindWell = true }) == true
        and Entry.kindOn("plant", {}) == true and Entry.kindOn("plant", { KindPlant = false }) == false
        and Entry.kindOn("floor", {}) == true,
        "Entry.kindOn：水井缺鍵或不是 true 都當關；植物與其他種類缺鍵當開")
    local wellS, pumpS = sprite("camping_01_16", 4501, WELL), sprite("camping_01_64", 4502, PUMP)
    local grassS, weedS = sprite("e_newgrass_1_8", 4503, GRASS), sprite("d_plants_1_16", 4504, WEED)
    local indoorS, hedgeS = sprite("vegetation_indoor_01_7", 4505, INDOOR), sprite("hedge_t_01_0", 4506, HEDGE)
    world({ wellS, pumpS, grassS, weedS, indoorS, hedgeS })
    sb.KindWell = nil
    local d0 = Entry.digest()
    local e0, c0 = Entry.resolve("camping_01_16")
    local w0, a0 = Entry.why("camping_01_16")
    sb.KindWell = false
    local e1, c1 = Entry.resolve("camping_01_64")
    sb.KindWell = true
    local e2 = Entry.resolve("camping_01_16")
    check(e0 == nil and c0 == "DISABLED" and w0 == "DISABLED_KIND" and a0 == "well" and e1 == nil and c1 == "DISABLED"
        and e2 and e2.kind == "well" and Entry.digest() ~= d0,
        "伺服器：KindWell 缺鍵或 false 回 DISABLED（說明是水井）；true 才收，設定摘要跟著變")
    local WW, keepText = MinidoracatBuilder.Window, getTextOrNull
    getTextOrNull = function(k) return k end -- 這一段的替身對沒登記的鍵回 nil：改成回鍵名，才看得出用了哪一句
    local whyWell, whyPost = WW.whyText("DISABLED_KIND", "well"), WW.whyText("DISABLED_KIND", "post")
    getTextOrNull = keepText
    check(whyWell == "IGUI_MBLD_Why_OFF_DEFAULT" and whyPost == "IGUI_MBLD_Why_DISABLED_KIND",
        "預設關的種類（水井）的說明是「預設關閉、管理員可以打開」，不寫管理員關掉了；其他種類照舊")
    local ep = Entry.resolve("e_newgrass_1_8")
    sb.KindPlant = false
    local _, cp = Entry.resolve("vegetation_indoor_01_7")
    sb.KindPlant = nil
    check(ep and ep.kind == "plant" and cp == "DISABLED", "植物缺鍵當開；KindPlant=false 回 DISABLED")

    -- 價錢
    local gc = Cost.of("plant", grassS)
    check(show(gc.items) == "Base.GrassTuft=3" and #gc.tools == 0 and gc.uniform == true and next(Cost.xp({ gc }, player())) == nil
        and Cost.skillOf("plant", grassS) == nil,
        "草：草屑 3、不要工具、不給經驗、不要技能、本工具拆（每項退 1..3，原版移除草給 2–3）")
    check(Cost.of("plant", grassS, 0).items["Base.GrassTuft"] == 3 and Cost.of("plant", grassS, 0.5).items["Base.GrassTuft"] == 3
        and Cost.of("plant", grassS, 2).items["Base.GrassTuft"] == 6,
        "草：倍率低於 1 也照 3 收（不然蓋了用原版移除就多拿），倍率 2 照乘")
    check(show(Cost.of("plant", hedgeS).items) == show(Cost.of("furniture", hedgeS).items)
        and show(Cost.of("plant", hedgeS).items) == "Base.Nails=4,Base.Plank=4"
        and select(2, Cost.skillOf("plant", hedgeS)) == select(2, Cost.skillOf("furniture", hedgeS))
        and Cost.refund("plant", indoorS) == "pickup" and Cost.refund("plant", grassS) == "builder"
        and Cost.refund("well", wellS) == "builder" and Cost.refund("well", pumpS) == "builder",
        "能搬的植物照家具的價（搬運重量 15 公斤：木板 4 釘子 4）、照原版撿起；草、水井、手壓水泵本工具拆")
    local wc, pc = Cost.of("well", wellS), Cost.of("well", pumpS)
    local wp, wl = Cost.skillOf("well", wellS)
    local pp, pl = Cost.skillOf("well", pumpS)
    check(show(wc.items) == "Base.Bucket=1,Base.FlatStone=8,Base.Rope=1,Base.Stone2=40"
        and table.concat(wc.tools, ",") == "DIG_GRAVE,MASONS_TROWEL"
        and show(pc.items) == "Base.MetalPipe=6,Base.Screws=6,Base.SmallSheetMetal=4"
        and table.concat(pc.tools, ",") == "BLOW_TORCH,WELDING_MASK" and next(pc.uses) == nil and next(wc.uses) == nil
        and wp == "Masonry" and wl == 4 and pp == "MetalWelding" and pl == 5,
        "水井：石塊 40＋扁石 8＋繩子 1＋水桶 1、鏟子＋抹刀、硬核石工 4；手壓水泵：鐵管 6＋小鐵片 4＋螺絲 6、噴槍＋面罩、硬核金工 5")
    sb.RecipeMaterials = true
    local pu, wu = Cost.of("well", pumpS).uses, Cost.of("well", wellS).uses
    sb.RecipeMaterials = nil
    check(pu[Cost.TORCH] == 4 and pu[Cost.RODS] == 4 and wu[Cost.CONCRETE] == 4 and wu[Cost.TORCH] == nil
        and Cost.of("well", wellS, 0.5).items["Base.Stone2"] == 20 and Cost.of("well", wellS, 0.5).items["Base.Bucket"] == 1,
        "硬核「原版材料」：手壓水泵另扣噴槍 4 次、焊條 4 次，水井黏土漿或混凝土 4 次（都不寫進退料）；倍率照乘、進位")
    local wx, px = Cost.xp({ wc }, player()), Cost.xp({ pc }, player())
    check(next(wx) == nil and wc.perkOf["Base.Stone2"] == false and wc.perkOf["Base.FlatStone"] == false
        and wc.perkOf["Base.Rope"] == "Masonry" and px.MetalWelding == 32.5,
        "經驗照本工具拆除的平均拿不回件數：水井石塊、扁石不給，繩子、水桶各 1 件拿得回來，一座井 0 點；"
        .. "手壓水泵金工 (5+3+5)/2×5＝32.5")

    -- 放置、退料表、拆除
    ItemTag.DIG_GRAVE, ItemTag.DIG_PLOW = "DIG_GRAVE", "DIG_PLOW"
    local function at(x, id)
        local P = player({ id = id, x = x + 0.5, y = 481.5, here = square(x, 481, 0) })
        return P, square(x, 480, 0)
    end
    local G, gSq = at(480, 4511)
    give(G, { ["Base.GrassTuft"] = 3 })
    local okG = build(G, 1, "d_plants_1_16", { 480, 480, 0 })
    local go = gSq.objects[1]
    check(okG and go and go.mats["Base.GrassTuft"] == "3" and G.inv:count("Base.GrassTuft") == 0
        and go.set.setBlockAllTheSquare == false and go.set.setIsThumpable == false and go.set.setCanPassThrough == true,
        "蓋草（帶 BlocksPlacement 的野草）：扣草屑 3、退料表 3；不擋整格、殭屍不打、走得過去")
    sb.CostMultiplier = 0.5
    local G2, g2Sq = at(482, 4512)
    give(G2, { ["Base.GrassTuft"] = 3 })
    local okG2 = build(G2, 1, "e_newgrass_1_8", { 482, 480, 0 })
    sb.CostMultiplier = nil
    check(okG2 and g2Sq.objects[1] and G2.inv:count("Base.GrassTuft") == 0, "倍率 0.5 照樣扣 3 個草屑")
    local H, hSq = at(484, 4513)
    give(H, { ["Base.Stone2"] = 40, ["Base.FlatStone"] = 8, ["Base.Rope"] = 1, ["Base.Bucket"] = 1 })
    H.inv:add(item("Base.MasonsTrowel", { MASONS_TROWEL = true, DIG_PLOW = true }))
    sb.KindWell = nil
    local okOff, _, aOff = build(H, 1, "camping_01_16", { 484, 480, 0 })
    sb.KindWell = true
    local okT, _, aT = build(H, 2, "camping_01_16", { 484, 480, 0 })
    H.inv:add(item("Base.Shovel", { DIG_GRAVE = true, DIG_PLOW = true }))
    local bucket
    for _, v in ipairs(H.inv.items) do if v.ft == "Base.Bucket" then bucket = v end end
    bucket.fluid = 3
    local okWet, _, aWet = build(H, 3, "camping_01_16", { 484, 480, 0 })
    check(not okWet and aWet.code == "NO_MATERIAL" and aWet.need and aWet.need["Base.Bucket"] ~= nil and H.inv:count("Base.Bucket") == 1
        and hSq.objects[1] == nil,
        "裝著水的水桶不當材料（原版要空容器）：只有一個裝水的桶時回 NO_MATERIAL、缺水桶，水桶留著")
    bucket.fluid = 0
    local okW = build(H, 4, "camping_01_16", { 484, 480, 0 })
    local wo = hSq.objects[1]
    check(not okOff and aOff.code == "DISABLED" and not okT and aT.code == "NO_TOOL" and aT.tools[1] == "DIG_GRAVE",
        "反面：KindWell 沒開回 DISABLED；只帶抹刀（原版 base:digplow 也有它）回 NO_TOOL、缺鏟子")
    check(okW and wo and wo.mats["Base.Stone2"] == "40" and wo.mats["Base.Bucket"] == "1" and H.inv:count("Base.Stone2") == 0
        and wo.set.setBlockAllTheSquare == true and wo.set.setCanPassThrough == false
        and wo.set.setIsThumpable == true and wo.set.setMaxHealth == 450 and wo.set.setThumpDmg == nil,
        "帶鏟子蓋水井：扣料、退料表照付的寫；實心、整格擋住；耐久照牆（450、每下最多扣 1/8），不是實心物件通則的 50")
    instanceof = function(o, cls) return cls == "IsoThumpable" and type(o) == "table" and o.set ~= nil end
    for _, o in ipairs({ go, wo }) do
        if o then o.isDismantable = function(self) return self.set.setIsDismantable ~= false end end
    end
    check(go and Dismantle.kindOf(go) == "plant" and wo and Dismantle.kindOf(wo) == "well"
        and table.concat(Dismantle.tools("well", { remove = { wo } }), ",") == "DIG_GRAVE,MASONS_TROWEL"
        and #Dismantle.tools("plant", { remove = { go } }) == 0,
        "拆除：本工具認得蓋好的草與水井（右鍵、一區拆除同一條），拆水井要鏟子、拆草不用工具")
    check(not Dismantle.swappable("plant", grassS, "plant", weedS) and not Dismantle.swappable("well", wellS, "well", pumpS),
        "原地替換不換植物、水井（要先拆再蓋）")
    if go then Place.onAboutToBeRemoved(go) end
    check(go and next(go.mats) == nil, "草被原版「移除草」、換地板或樓梯拆掉前：移除事件清掉退料表，之後拆不到料")
    instanceof = realInst
    sb.KindWell = nil
    sb.RecipeMaterials, sb.CostMultiplier = keepRM, keepMult
    spriteMap, spriteOrder = keepMap, keepOrder
end)()

print("情境四十六：左欄子種類（使用者 2026-11-13 選 cat=three）：W.subOf、W.runSubs、W.refreshCats、W.filter")
;(function()
    local W = MinidoracatBuilder.Window
    local keepMap, keepOrder = spriteMap, spriteOrder
    local realText, realRefilter, realV, realSt = getTextOrNull, W.refilter, W.v, W.st
    local keepSrc, keepTs = sb.DisabledSources, sb.DisabledTilesets
    sb.DisabledSources, sb.DisabledTilesets = "", ""
    local LABEL = { crate = "Crate", woodcrate = "Crate", fridge = "Fridge", counter = "Counter", shelves = "Shelves",
        bin = "Bin", oven = "Oven", desk = "Desk", wardrobe = "Wardrobe", locker = "Locker" }
    getTextOrNull = function(k)
        local t = k:match("^IGUI_ContainerTitle_(.+)$")
        return t and LABEL[t] or nil
    end
    local function P(o) return sprite("sub_x_01_0", 4600, o):getProperties() end
    -- 1. W.subOf 每條分支
    check(W.subOf("light", nil) == "lamp" and W.subOf("light", P({})) == "switch"
        and W.subOf("light", P({ keys = { streetlight = "" } })) == "sign"
        and W.subOf("light", P({ keys = { lightR = "1", lightG = "1", lightB = "1" } })) == "lamp"
        and W.subOf("light", P({ keys = { IsMoveAble = "" } })) == "lamp",
        "子種類（燈）：開關（沒有 lightR、streetlight、IsMoveAble）、招牌與路燈（streetlight）、其他是燈具；沒屬性當燈具")
    check(W.subOf("furniture", nil) == "other" and W.subOf("furniture", P({ keys = { SeatMaterial = "Wood" } })) == "rest"
        and W.subOf("furniture", P({ flags = { "bed" } })) == "rest"
        and W.subOf("furniture", P({ keys = { IsTable = "", SeatMaterial = "Wood" } })) == "rest"
        and W.subOf("furniture", P({ keys = { IsTable = "" } })) == "table"
        and W.subOf("furniture", P({ keys = { IsTableTop = "" } })) == "tabletop"
        and W.subOf("furniture", P({ keys = { MoveType = "WallObject" } })) == "wallArt"
        and W.subOf("furniture", P({ keys = { MoveType = "FloorRug" } })) == "rug"
        and W.subOf("furniture", P({ keys = { IsMoveAble = "" } })) == "other",
        "子種類（家具）：床與座椅（SeatMaterial 或 bed 旗標，優先）、桌子、桌上擺設、掛畫、地毯、其他；沒屬性當其他")
    check(W.subOf("plant", nil) == "grass" and W.subOf("plant", P({ keys = { IsMoveAble = "" } })) == "ornamental"
        and W.subOf("plant", P({ flags = { "canBeRemoved" } })) == "grass",
        "子種類（植物）：能搬的是觀賞植物，其他是草與野花")
    check(W.subOf("container", nil) == "other" and W.subOf("container", P({ keys = { container = "crate" } })) == "n:Crate"
        and W.subOf("container", P({ keys = { container = "woodcrate" } })) == "n:Crate"
        and W.subOf("container", P({ keys = { container = "mystery" } })) == "other" and W.subOf("roof", P({})) == nil,
        "子種類（容器）：照原版顯示名（同名的型別同一組），沒有 IGUI_ContainerTitle_ 翻譯的歸其他；別的種類沒有子種類")
    check(W.subOf("floorOverlay", nil, "street_trafficlines_curb_white_full_3") == "marking"
        and W.subOf("floorOverlay", nil, "street_curbs_01_blend_dirt_12") == "curb"
        and W.subOf("floorOverlay", nil, "blends_natural_01_8") == "curb" and W.subOf("floorOverlay", nil, "pert_edges_01_0") == "curb"
        and W.subOf("floorOverlay", nil, "blends_streetoverlays_01_4") == "crack"
        and W.subOf("floorOverlay", nil, "d_streetcracks_1_7") == "crack" and W.subOf("floorOverlay", nil, "Fears_Tire_Marks_2") == "crack"
        and W.subOf("floorOverlay", nil, "fencing_damaged_01_9") == "other" and W.subOf("floorOverlay", nil, nil) == "other"
        and W.subOf("floorOverlay", nil, "recipe:Base.Thing") == "other",
        "子種類（地面覆蓋）：照圖塊組名分；路邊漆線算標線不算路緣、路面破損貼片算裂痕不算邊條、不分大小寫、沒有名稱歸其他")

    -- 2. W.runSubs：容器 11 個型別、10 個顯示名（Crate 兩個型別）＋沒翻譯的 mystery
    local spec = { { "crate", 3 }, { "woodcrate", 3 }, { "fridge", 5 }, { "counter", 4 }, { "shelves", 4 }, { "bin", 3 },
        { "oven", 3 }, { "desk", 2 }, { "wardrobe", 2 }, { "locker", 1 }, { "mystery", 2 } }
    local sprs, list, id = {}, { n = 0 }, 4600
    Index.reset()
    for _, t in ipairs(spec) do
        for i = 1, t[2] do
            id = id + 1
            local name = "subc_" .. t[1] .. "_01_" .. i
            sprs[#sprs + 1] = sprite(name, id, { keys = { container = t[1], IsMoveAble = "" } })
            list.n = list.n + 1
            list[list.n] = name
            Index.add("container", name, "subc_" .. t[1] .. "_01", i, 1)
        end
    end
    local g1, g2 = sprite("subg_01_1", 4690, { flags = { "canBeRemoved" } }), sprite("subg_01_2", 4691, { flags = { "canBeRemoved" } })
    local lamp, switch = sprite("subl_01_1", 4692, { keys = { lightR = "1" } }), sprite("subl_01_2", 4693, {})
    for _, s in ipairs({ g1, g2, lamp, switch }) do sprs[#sprs + 1] = s end
    world(sprs)
    for i = 1, Index.setName.n do Index.addSetKey(i, "") end
    W.st = { query = "", tab = "all", cat = "all", source = "all", recent = { n = 0 } }
    W.refilter = function() end
    local v = { nav = { setGroups = function() end, setSelected = function() end },
        cat = { setOptions = function() end, setSelected = function() end }, subs = {} }
    W.v = v
    v.subJob = { kind = "container", src = "all", list = list, i = 0, of = {} }
    W.runSubs(v)
    local cs = v.subs.container
    local ids, total = {}, 0
    for i, it in ipairs(cs and cs.items or {}) do
        ids[i] = it.id .. "=" .. it.n
        total = total + it.n
    end
    check(table.concat(ids, ",") == "n:Crate=6,n:Fridge=5,n:Counter=4,n:Shelves=4,n:Bin=3,n:Oven=3,n:Desk=2,n:Wardrobe=2,other=3"
        and #ids == W.SUB_TOP + 1,
        "容器：同名的兩個型別併成一組（Crate 3＋3），照數量取前 8 組（同數照名稱），其餘（Locker）併進其他、和沒翻譯的一起")
    check(cs and cs.of["subc_locker_01_1"] == "other" and cs.of["subc_woodcrate_01_2"] == "n:Crate" and total == list.n,
        "容器：被併掉的那組逐項改成其他；子種類合計等於種類的項目數")
    v.subJob = { kind = "plant", src = "all", list = { n = 2, "subg_01_1", "subg_01_2" }, i = 0, of = {} }
    W.runSubs(v)
    check(v.subs.plant and #v.subs.plant.items == 0 and v.subs.plant.of["subg_01_1"] == "grass",
        "整個種類只有一組（全是草）：不列子種類（items 空），每項照樣記子種類")
    v.subJob = { kind = "light", src = "all", list = { n = 2, "subl_01_1", "subl_01_2" }, i = 0, of = {} }
    W.runSubs(v)
    local li = v.subs.light and v.subs.light.items or {}
    check(#li == 2 and li[1].id == "switch" and li[2].id == "lamp", "非容器：照 W.SUB_KINDS 的順序列（開關在燈具前），不照數量")
    v.subJob = { kind = "floorOverlay", src = "all", i = 0, of = {},
        list = { n = 5, "subo_misc_01_0", "d_streetcracks_1_0", "street_trafficlines_01_0", "street_curbs_01_0", "street_curbs_01_1" } }
    W.runSubs(v)
    local oi, oids = v.subs.floorOverlay and v.subs.floorOverlay.items or {}, {}
    for i, it in ipairs(oi) do oids[i] = it.id .. "=" .. it.n end
    check(table.concat(oids, ",") == "curb=2,marking=1,crack=1,other=1",
        "地面覆蓋：圖塊名傳進 W.subOf（不在世界裡的圖也分得出來），照 W.SUB_KINDS 的順序列")

    -- 3. W.refreshCats：選著的子種類不在了回種類，種類也不在回「全部」
    W.st.cat = "s:container:n:Crate"
    W.refreshCats(v)
    local keptSub = W.st.cat
    W.st.cat = "s:container:n:Nowhere"
    W.refreshCats(v)
    local backKind = W.st.cat
    W.st.cat = "s:light:switch"
    W.refreshCats(v)
    check(keptSub == "s:container:n:Crate" and backKind == "k:container" and W.st.cat == "all",
        "左欄：子種類還在就留著；算完沒有這個子種類回 k:<種類>；種類這次沒列出（目錄沒有燈）回「全部」")

    -- 4. W.filter：選子種類只留那一組；完整圖塊名命中（jump）不濾
    local function st(o)
        local s = { query = "", tab = "all", cat = "all", source = "all", recent = { n = 0 } }
        for k, val in pairs(o) do s[k] = val end
        return s
    end
    local crate = W.filter(st({ cat = "s:container:n:Crate" }))
    local allCrate = crate.n == 6
    for i = 1, crate.n do allCrate = allCrate and cs.of[crate[i]] == "n:Crate" end
    local other = W.filter(st({ cat = "s:container:other" }))
    local whole = W.filter(st({ cat = "k:container" }))
    check(allCrate and other.n == 3 and whole.n == list.n, "選子種類：只列那一組（Crate 6、其他 3）；選種類列全部")
    local jl, jump = W.filter(st({ cat = "s:container:n:Crate", query = "subc_locker_01_1" }))
    check(jump == "subc_locker_01_1" and jl.n == 1 and jl[1] == "subc_locker_01_1",
        "完整圖塊名命中：照它那一桶列、選取它，不被選著的子種類濾掉")
    v.subs = {}
    check(W.filter(st({ cat = "s:container:n:Crate" })).n == list.n, "子種類還沒算好：先照整個種類列")

    -- 5. 照來源的快取、分幾幀算、算完重列
    v.subJob = { kind = "container", src = "all", list = list, i = 0, of = {} }
    W.runSubs(v)
    local fresh = W.filter(st({ cat = "s:container:n:Crate" })).n
    v.subs.container.src = "elsewhere" -- 當成是別的來源算的（「整套」「換成」直接改 st.source，不經 W.setSource）
    check(fresh == 6 and W.filter(st({ cat = "s:container:n:Crate" })).n == list.n,
        "子種類快取照來源：別的來源算好的不套到這個來源（當成還沒算好，先照整個種類列）")
    v.subs = {}
    v.subJob = { kind = "container", src = "all", list = list, i = 0, of = {} }
    W.st.source = "elsewhere"
    W.runSubs(v)
    check(v.subs.container == nil and v.subJob ~= nil and v.subJob.src == "elsewhere" and v.subJob.i == 0,
        "算到一半來源換了：照新來源重算，舊來源的不收尾")
    W.st.source = "all"
    local calls, early = {}, false
    W.refilter = function(keep) calls[#calls + 1] = keep == true end
    v.subs, v.subKeep = {}, true
    W.st.cat = "s:container:n:Crate"
    v.subJob = { kind = "container", src = "all", list = list, i = 0, of = {} }
    local keepStep, frames = clockStep, 0
    clockStep = 5 -- 每次看時鐘前進 5 毫秒：每 16 項就超過每幀預算，一幀只做一段
    while v.subJob and frames < 50 do
        W.runSubs(v)
        frames = frames + 1
        if v.subJob and #calls > 0 then early = true end
    end
    clockStep = keepStep
    check(frames >= 2 and not early and #calls == 1 and calls[1] == true and v.subKeep == nil
        and v.subs.container ~= nil and W.st.cat == "s:container:n:Crate",
        "分幾幀算：算完前不重列；等著的清單算完重列一次、照「沒換條件」套（留住選取）")
    calls, v.subs, v.subKeep = {}, {}, nil
    v.subJob = { kind = "container", src = "all", list = list, i = 0, of = {} }
    W.runSubs(v)
    local quiet = #calls
    calls, v.subs = {}, {}
    W.st.cat = "s:container:n:Nowhere"
    v.subJob = { kind = "container", src = "all", list = list, i = 0, of = {} }
    W.runSubs(v)
    check(quiet == 0 and #calls == 1 and calls[1] == false and W.st.cat == "k:container",
        "沒有清單在等、選取也沒變：算完不重列；選著的子種類算完不見了：回種類、照「換了條件」重列")

    -- 6. 來源檢查的另外兩個入口（左欄、等待）、真的 W.refilter 的等待分支、屬性丟錯的圖
    local function subRows()
        local n = 0
        for _, g in ipairs(W.categories("all")) do
            for _, it in ipairs(g.items or {}) do
                if tostring(it.id):sub(1, 12) == "s:container:" then n = n + 1 end
            end
        end
        return n
    end
    v.subs, v.subKeep = {}, nil
    W.st.cat = "k:container"
    v.subJob = { kind = "container", src = "all", list = list, i = 0, of = {} }
    W.runSubs(v)
    local rowsFresh = subRows()
    v.subs.container.src = "elsewhere"
    check(rowsFresh == W.SUB_TOP + 1 and subRows() == 0, "左欄：這個來源算好的子種類才列；別的來源算的不列")
    local realStatus, Cat = W.setStatus, MinidoracatBuilder.Catalog
    local keepState = Cat and Cat.state
    if Cat then Cat.state = "ready" end -- 目錄還在整理時不等子種類（照整個種類列）
    W.setStatus = function() end
    W.refilter = realRefilter
    W.st.cat = "s:container:n:Crate"
    v.subJob = nil
    W.refilter(false)
    local j1, k1 = v.subJob, v.subKeep
    W.refilter(true)
    local j2, k2 = v.subJob, v.subKeep
    W.setStatus = realStatus
    if Cat then Cat.state = keepState end
    W.refilter = function() end
    check(j1 ~= nil and j1.kind == "container" and j1.src == "all" and j1.i == 0 and k1 == false and j2 == j1 and k2 == false,
        "真的 W.refilter：別的來源算的快取不算數，開始照這個來源算；等的時候有過「換了條件」，之後照「沒換條件」來的也不蓋掉")
    local bad = { has = function() error("boom") end, get = function() error("boom") end }
    local keepLamp, keepSwitch = lamp.getProperties, switch.getProperties
    lamp.getProperties = function() return bad end
    switch.getProperties = function() error("boom") end
    local realPrint, logged = print, 0
    print = function(s)
        if tostring(s):find("sub-kind failed", 1, true) then logged = logged + 1 else realPrint(s) end
    end
    v.subs = {}
    v.subJob = { kind = "light", src = "all", list = { n = 2, "subl_01_1", "subl_01_2" }, i = 0, of = {} }
    local okRun = pcall(W.runSubs, v)
    print = realPrint
    lamp.getProperties, switch.getProperties = keepLamp, keepSwitch
    check(okRun and v.subs.light ~= nil and v.subs.light.of["subl_01_1"] == "lamp" and v.subs.light.of["subl_01_2"] == "lamp"
        and logged == 1,
        "屬性丟錯的圖（查屬性丟錯、取屬性丟錯）：歸到沒有屬性時的那一組（燈→燈具），不中斷，整輪只記一次 log")

    getTextOrNull, W.refilter, W.v, W.st = realText, realRefilter, realV, realSt
    sb.DisabledSources, sb.DisabledTilesets = keepSrc, keepTs
    Index.reset()
    spriteMap, spriteOrder = keepMap, keepOrder
end)()

print("情境四十七：水面（使用者 2026-11-13 選 pond=do、cost=shovel）：分類、開關、成本、能不能挖、挖、填平、在水上蓋地板、客戶端重畫")
;(function()
    nowMs = nowMs + 180000
    local Place, Dismantle = MinidoracatBuilder.Place, MinidoracatBuilder.Dismantle
    local keepMap, keepOrder, realInst, realServer = spriteMap, spriteOrder, instanceof, isServer
    local keepRM, keepMult, keepKW, keepSkill = sb.RecipeMaterials, sb.CostMultiplier, sb.KindWater, sb.RequireSkill
    sb.RecipeMaterials, sb.CostMultiplier, sb.RequireSkill = nil, nil, nil
    local function code(o, name) return select(2, Rules.classify(sprite(name or "test_01_0", 5, o))) end
    -- 原版屬性（temp/water-grass-1113/props.py 離線讀的 tiledef）
    local WATER = { flags = { "solidfloor", "solidtrans", "taintedWater", "water", "attachedFloor" }, keys = { waterAmount = "9999" } }
    local SHORE = { flags = { "attachedFloor", "taintedWater" }, keys = { waterAmount = "9999", FloorAttachmentN = "" } }

    -- 分類
    local four = true
    for _, n in ipairs({ 0, 5, 6, 7 }) do four = four and kind(WATER, "blends_natural_02_" .. n) == "water" end
    check(four and kind(WATER, "riverpack_01_3") == "water",
        "水面：原版 blends_natural_02_0／5／6／7 是 water；照屬性認（別的 MOD 帶 water 的地板也是）")
    check(code(SHORE, "blends_natural_02_8") == "WATER" and code(SHORE, "blends_natural_02_1") == "WATER"
        and code({ flags = { "solidtrans" }, keys = { waterAmount = "999999", BlocksPlacement = "" } }, "camping_01_17") == "WATER"
        and code({ flags = { "solidfloor" }, keys = { waterAmount = "9999" } }) == "WATER"
        and code({ flags = { "water" }, keys = { waterAmount = "9999" } }) == "WATER"
        and code({ flags = { "solidfloor", "water", "EntityScript" } }, "riverpack_01_4") == "ENTITY",
        "反面：岸邊疊圖、其他無限水、沒有 water 旗標的無限水地板、不是地板的 water 照舊 WATER；帶 EntityScript 的 ENTITY")

    -- 開關
    local ki = {}
    for i, k in ipairs(Entry.KINDS) do ki[k] = i end
    local W = MinidoracatBuilder.Window
    local inFloorTab = false
    for _, k in ipairs(W.TAB_KINDS.floor) do inFloorTab = inFloorTab or k == "water" end
    check(ki.water == ki.floorOverlay + 1 and Entry.KIND_KEY.water == "KindWater" and Entry.KIND_OFF.water == true
        and inFloorTab and MinidoracatBuilder.Cursor.DRAG.water == "fill"
        and MinidoracatBuilder.Area.ORDER.water == MinidoracatBuilder.Area.ORDER.floor,
        "種類表：water 接在 floorOverlay 後、沙盒鍵 KindWater、預設關；在地板頁籤、可拖一片、一區拆除和地板同一順位")
    check(Entry.kindOn("water", {}) == false and Entry.kindOn("water", { KindWater = false }) == false
        and Entry.kindOn("water", { KindWater = 1 }) == false and Entry.kindOn("water", { KindWater = true }) == true,
        "Entry.kindOn：KindWater 缺鍵或不是 true 都當關")
    local natS = sprite("blends_natural_01_21", 4701, { flags = { "solidfloor" } })
    local waterS = sprite("blends_natural_02_6", 4702, WATER)
    local streetS = sprite("floors_exterior_street_01_0", 4703, { flags = { "solidfloor" } })
    local grassS = sprite("e_newgrass_1_8", 4704, { flags = { "canBeRemoved" }, keys = { MoveWithWind = "" } })
    local overS = sprite("blends_grassoverlays_01_3", 4705, { flags = { "attachedFloor" } })
    local bushS = sprite("vegetation_foliage_01_0", 4706, { flags = { "vegitation" } })
    local treeS = sprite("vegetation_trees_01_8", 4707, { type = T.tree, flags = { "vegitation" } })
    local crateS = sprite("crate_t_01_0", 4708, { keys = { container = "crate" } })
    local floorS = sprite("pf_floor_01_0", 4709, { flags = { "solidfloor" } })
    world({ natS, waterS, streetS, grassS, overS, bushS, treeS, crateS, floorS })
    sb.KindWater = nil
    local e0, c0 = Entry.resolve("blends_natural_02_6")
    local w0, a0 = Entry.why("blends_natural_02_6")
    local keepText = getTextOrNull
    getTextOrNull = function(k) return k end
    local whyText = W.whyText("DISABLED_KIND", "water")
    getTextOrNull = keepText
    sb.KindWater = true
    local e1 = Entry.resolve("blends_natural_02_6")
    check(e0 == nil and c0 == "DISABLED" and w0 == "DISABLED_KIND" and a0 == "water" and whyText == "IGUI_MBLD_Why_OFF_DEFAULT"
        and e1 and e1.kind == "water",
        "伺服器：KindWater 缺鍵回 DISABLED，說明寫「預設關閉」；打開才收")

    -- 成本
    local c = Cost.of("water", waterS)
    local c0x, c10 = Cost.of("water", waterS, 0), Cost.of("water", waterS, 10)
    sb.RecipeMaterials = true
    local cr = Cost.of("water", waterS, 3)
    sb.RecipeMaterials = nil
    sb.RequireSkill = true
    local perk = Check.skill(player(), "water", waterS)
    sb.RequireSkill = nil
    check(next(c.items) == nil and table.concat(c.tools, ",") == "DIG_GRAVE" and next(c0x.items) == nil and next(c10.items) == nil
        and table.concat(c10.tools, ",") == "DIG_GRAVE" and next(cr.uses) == nil and next(Cost.xp({ c10 }, player())) == nil
        and Cost.skillOf("water", waterS) == nil and perk == nil and Cost.refund("water", waterS) == "builder",
        "水面：不收料（倍率 0、10 都一樣）、只要鏟子、沒有耗材、不給經驗、不要技能；本工具填平")

    -- 格子：490..497 × 490..497 是天然地面（BFS 找路要鄰格）；格子屬性照格上物件的聯集算
    local function mk(spr, class)
        local o = { spr = spr, md = {}, class = class }
        function o:getSprite() return self.spr end
        function o:getProperties() return self.spr:getProperties() end
        function o:getTextureName() return self.spr:getName() end
        function o:getType() return self.spr:getType() end
        function o:getModData() return self.md end
        function o:hasModData() return next(self.md) ~= nil end
        function o:transmitModData() self.sentMd = true end
        function o:getSquare() return self.sq end
        function o:isObjectNoContainerOrEmpty() return true end
        function o:getSpriteGridObjectsIncludingSelf() return javaList({ self }) end
        function o:isConnectedSpriteGridObject(x) return x == self end
        function o:isFloor() return self.spr:getProperties():has(F.solidfloor) end
        function o:getAttachedAnimSprite() return nil end
        return o
    end
    local function props(ob) return ob.getProperties and ob:getProperties() end
    local function wsq(x, y, z, objs, o)
        o = o or {}
        local sq = square(x, y, z, o)
        local rm = sq.transmitRemoveItemFromSquare
        function sq:transmitRemoveItemFromSquare(obj, safely) -- 照引擎：移除前先觸發事件（IsoGridSquare.java:5732）
            fire("OnObjectAboutToBeRemoved", obj)
            return rm(self, obj, safely)
        end
        function sq:transmitAddObjectToSquare(obj, index) -- 照引擎：加進格子並送出（IsoGridSquare.java:5920）
            obj.sq = self
            self.objects[#self.objects + 1] = obj
        end
        sq.statics, sq.cleared, sq.dropped = {}, 0, {}
        function sq:disableErosion() self.noErosion = true end
        for _, ob in ipairs(objs or {}) do
            ob.sq = sq
            sq.objects[#sq.objects + 1] = ob
        end
        function sq:has(k)
            for _, ob in ipairs(self.objects) do
                local p = props(ob)
                if p and p:has(k) then return true end
            end
            return false
        end
        function sq:getFloor()
            for _, ob in ipairs(self.objects) do
                local p = props(ob)
                if p and p:has(F.solidfloor) then return ob end
            end
            return nil
        end
        function sq:hasFloor() return self:getFloor() ~= nil end
        function sq:getStaticMovingObjects() return { isEmpty = function() return #sq.statics == 0 end } end
        function sq:getWorldObjects()
            local l = javaList(self.world)
            l.isEmpty = function() return #sq.world == 0 end
            return l
        end
        function sq:isVehicleIntersecting() return o.vehicle == true end
        function sq:clearWater() self.cleared = self.cleared + 1 end
        function sq:AddWorldInventoryItem(ft) self.dropped[ft] = (self.dropped[ft] or 0) + 1 end
        -- 照引擎（IsoGridSquare.java:4726-4795）：拆舊地板、不是樹的植被、髒水、草地疊圖（帶 canBeRemoved 的草不拆），
        -- 新地板加在最後，清自己這一格的水面幾何
        function sq:addFloor(name)
            for i = #self.objects, 1, -1 do
                local ob = self.objects[i]
                local p = props(ob)
                local n = ob.getTextureName and ob:getTextureName() or ""
                if p and (p:has(F.solidfloor) or p:has(F.noStart) or (p:has(F.vegitation) and ob:getType() ~= T.tree)
                    or p:has(F.taintedWater) or n:sub(1, 20) == "blends_grassoverlays") then
                    self:transmitRemoveItemFromSquare(ob)
                end
            end
            local f = mk(spriteMap[name] or sprite(name, 4790, { flags = { "solidfloor" } }))
            f.sq = self
            self.objects[#self.objects + 1] = f
            self:clearWater()
            return f
        end
        return sq
    end
    for x = 490, 497 do for y = 490, 497 do wsq(x, y, 0, { mk(natS) }) end end
    local function at(x, y) return squares[x .. "," .. y .. ",0"] end
    instanceof = function(o, cls) return type(o) == "table" and o.class == cls end

    -- 能不能挖：每一個原因（不碰世界，直接問 Place.check）
    local function why(sq) return select(2, Place.check("water", waterS, sq, nil)) end
    local function okAt(sq) return (Place.check("water", waterS, sq, nil)) == true end
    local upSq = wsq(491, 501, 1, { mk(natS) })
    local wetSq = wsq(492, 501, 0, { mk(waterS) })
    local streetSq = wsq(493, 501, 0, { mk(streetS) })
    local bareSq = wsq(494, 501, 0, {})
    local builtSq = wsq(495, 501, 0, { mk(natS, "IsoThumpable") })
    local busySq = wsq(496, 501, 0, { mk(natS) }, { moving = { {} } })
    local carSq = wsq(497, 501, 0, { mk(natS) }, { vehicle = true })
    local treeSq = wsq(491, 502, 0, { mk(natS), mk(treeS) })
    local crateSq = wsq(492, 502, 0, { mk(natS), mk(crateS) })
    local itemSq = wsq(493, 502, 0, { mk(natS) })
    itemSq.world = { {} }
    local bodySq = wsq(494, 502, 0, { mk(natS) })
    bodySq.statics = { {} }
    local softSq = wsq(495, 502, 0, { mk(natS), mk(grassS), mk(overS), mk(bushS) })
    check(not okAt(upSq) and why(upSq) == nil and why(wetSq) == "SAME_TILE" and why(streetSq) == "NOT_NATURAL"
        and why(bareSq) == "NOT_NATURAL" and why(builtSq) == "NOT_NATURAL" and why(busySq) == "OCCUPIED" and why(carSq) == "VEHICLE",
        "不能挖：二樓（沒有原因碼）、已經是水 SAME_TILE、鋪好的地板／沒有地板／本工具蓋的地板 NOT_NATURAL、有人 OCCUPIED、車 VEHICLE")
    check(not okAt(treeSq) and why(treeSq) == nil and not okAt(crateSq) and why(crateSq) == nil
        and not okAt(itemSq) and why(itemSq) == nil and not okAt(bodySq) and why(bodySq) == nil and okAt(softSq),
        "樹、其他物件、地上的物品、屍體擋著不挖（BLOCKED，不替玩家清）；只有草、草地疊圖、不是樹的植被的天然地面可以挖")
    local cellarSq = wsq(491, 503, -1, { mk(natS) })
    local ownBush = mk(bushS, "IsoThumpable")
    ownBush.md.builderEntry = "vegetation_foliage_01_0"
    local ownSq = wsq(492, 503, 0, { mk(natS), ownBush })
    check(not okAt(cellarSq) and why(cellarSq) == nil and not okAt(ownSq) and why(ownSq) == nil,
        "地下室不能挖；格上有本工具蓋的植物也不挖（不替玩家清，退料會跟著不見）")
    local hungFloor, bareHung = mk(natS), mk(natS)
    hungFloor.md.builderOverlays = { ["street_trafficlines_01_0"] = true }
    bareHung.md.builderOverlays = {}
    local hungSq, bareHungSq = wsq(493, 503, 0, { hungFloor }), wsq(494, 503, 0, { bareHung })
    check(not okAt(hungSq) and why(hungSq) == nil and okAt(bareHungSq),
        "地板上掛著本工具的地面覆蓋：不挖（覆蓋和退料會跟著地板不見）；覆蓋都拆掉了的照常可以挖")

    -- 伺服器挖：要鏟子、記原地板、拆掉草、不收料
    ItemTag.DIG_GRAVE = "DIG_GRAVE"
    local function digger(id, x, y)
        local p = player({ id = id, x = x + 0.5, y = y + 0.5, here = at(x, y) })
        p.inv:add(item("Base.Shovel", { DIG_GRAVE = true }))
        return p
    end
    local P = digger(4711, 492, 493)
    local tSq = at(492, 492)
    tSq.objects[#tSq.objects + 1] = mk(grassS)
    tSq.objects[#tSq.objects].sq = tSq
    sb.KindWater = nil
    local offOk, _, offA = build(P, 1, "blends_natural_02_6", { 492, 492, 0 })
    sb.KindWater = true
    local bare = player({ id = 4712, x = 493.5, y = 493.5, here = at(493, 493) })
    bare.inv:add(item("Base.MasonsTrowel", { MASONS_TROWEL = true }))
    local toolOk, _, toolA = build(bare, 1, "blends_natural_02_6", { 493, 492, 0 })
    check(not offOk and offA.code == "DISABLED" and not toolOk and toolA.code == "NO_TOOL" and toolA.tools[1] == "DIG_GRAVE"
        and at(493, 492):getFloor().spr == natS,
        "反面：KindWater 沒開回 DISABLED；沒鏟子（只有抹刀）回 NO_TOOL、地面不動")
    local digOk = build(P, 2, "blends_natural_02_6", { 492, 492, 0 })
    local w = tSq:getFloor()
    check(digOk and w and w.spr == waterS and #tSq.objects == 1 and tSq:has(F.water) and w.md.builderEntry == "blends_natural_02_6"
        and w.md.builderWater == "blends_natural_01_21" and w.sentMd == true and P.inv:count("Base.Shovel") == 1,
        "挖：草和原地板拆掉、放水面；記號記圖名與原地板並送給客戶端；鏟子留著")
    check(w and Place.dug(w) and Dismantle.kindOf(w) == "water" and Place.refundOf(w) ~= nil and next(Place.refundOf(w)) == nil
        and table.concat(Dismantle.tools("water", Dismantle.plan(w, "water")), ",") == "DIG_GRAVE"
        and not Dismantle.swappable("water", waterS, "water", waterS) and Dismantle.replaceable(tSq, "floor", floorS) == nil,
        "挖好的水面：本工具認得、填平不退料、要鏟子；不參加原地替換（蓋地板時不當替換）")
    check(tSq.noErosion == true and not Dismantle.swappable("water", waterS, "water", sprite("blends_natural_02_5", 4794, WATER)),
        "挖好的那一格關掉侵蝕（不會在水面上長出草木）；挖好的水不提供換成另一張水面")

    -- 不是本工具挖的水：拆不掉
    local river = mk(waterS)
    local forged = mk(waterS)
    forged.md.builderEntry = "blends_natural_02_7"
    check(Dismantle.kindOf(river) == nil and Dismantle.kindOf(forged) == nil and not Place.dug(river),
        "地圖原有的河、記號和圖不一樣的水：不是本工具的，拆不掉")
    local rSq = at(494, 492)
    rSq.objects = { river }
    river.sq = rSq
    sent = {}
    Server.dismantleIntent(P, { n = 9, t = { 494, 492, 0, "blends_natural_02_6" } })
    Server.dismantle(P, 9, 1)
    check(rSq:getFloor() == river and sent[#sent] and sent[#sent].cmd == "dismantleSkipped",
        "拆除請求指到地圖原有的水：跳過，水留著")
    local Floors = MinidoracatBuilder.Floors
    local wRefund = Place.refundOf(w)
    check(type(wRefund) == "table" and next(wRefund) == nil and Floors.get(w) and Floors.get(w).s == "blends_natural_02_6",
        "挖的時候在地板帳本記一筆空的退料：伺服器照帳本認這片水面")

    -- 填平：換回原地板；沒記到、記的不是天然地面的換泥土
    local function unbuild(p, n, x, y)
        sent = {}
        Server.dismantleIntent(p, { n = n, t = { x, y, 0, "blends_natural_02_6" } })
        Server.dismantle(p, n, 1)
        return sent[#sent] and sent[#sent].cmd, sent[#sent] and sent[#sent].args or {}
    end
    local nc, na = unbuild(bare, 10, 492, 492)
    check(nc == "dismantleSkipped" and na.code == "NO_TOOL" and tSq:getFloor() == w, "填平也要鏟子：沒帶回 NO_TOOL，水留著")
    local fc = unbuild(P, 11, 492, 492)
    local back = tSq:getFloor()
    check(fc == "dismantled" and back and back.spr == natS and not tSq:has(F.water) and #tSq.objects == 1
        and next(at(492, 493).dropped) == nil,
        "填平：水面移除、換回挖之前的地面，不退任何東西")
    check(Floors.get(back) == nil, "填平後地板帳本那一筆清掉")
    -- 帳本沒有紀錄的水：記號和圖一樣也不算本工具挖的，伺服器不填平
    river.md.builderEntry = "blends_natural_02_6"
    local kc, ka = unbuild(P, 19, 494, 492)
    check(Place.dug(river) and Place.refundOf(river) == nil and kc == "dismantleSkipped" and ka.code == "NOT_OURS"
        and rSq:getFloor() == river and #rSq.objects == 1,
        "帳本沒有紀錄的水（記號和圖一樣）：伺服器回 NOT_OURS，水留著")
    river.md.builderEntry = nil
    -- 帳本那一筆記的是別張水面圖：也不算
    local water7 = sprite("blends_natural_02_7", 4793, WATER)
    Floors.put(river, {})
    local other = mk(water7)
    other.md.builderEntry = "blends_natural_02_7"
    other.sq = rSq
    check(type(Place.refundOf(river)) == "table" and Place.dug(other) and Place.refundOf(other) == nil,
        "帳本記的圖和現在的圖不一樣：不算本工具挖的")
    Floors.forget(river)
    local old, odd = mk(waterS), mk(waterS)
    old.md.builderEntry = "blends_natural_02_6"
    odd.md.builderEntry, odd.md.builderWater = "blends_natural_02_6", "floors_exterior_street_01_0"
    check(Place.waterBase(old) == Place.DIRT and Place.waterBase(odd) == Place.DIRT and Place.DIRT == "blends_natural_01_64"
        and Place.waterBase(w) == "blends_natural_01_21",
        "填平換回的地面：沒記到（舊資料）或記的不是天然地面時換泥土")
    local oSq = at(495, 492)
    oSq.objects = { old }
    old.sq = oSq
    Place.fill(old)
    check(oSq:getFloor() and oSq:getFloor():getSprite():getName() == "blends_natural_01_64" and not oSq:has(F.water),
        "沒記到原地板的水面填平：換成泥土，不會留一格沒有地板")
    -- 填平時水面移不掉（引擎丟的例外 Kahlua 只記 log）：報錯，不在水面上再補一片地板
    local stuckSq = at(497, 497)
    local stuck = Place.dig(stuckSq, waterS)
    local realRemove = stuckSq.transmitRemoveItemFromSquare
    stuckSq.transmitRemoveItemFromSquare = function() return -1 end
    local okFill = pcall(Place.fill, stuck)
    stuckSq.transmitRemoveItemFromSquare = realRemove
    check(okFill == false and stuckSq:getFloor() == stuck and #stuckSq.objects == 1,
        "填平時水面移不掉：報錯，那一格維持原樣，不會多出一片地板")
    -- 水面放不上去（引擎丟的例外 Kahlua 只記 log，addFloor 回 nil；舊地板這時已經拆掉）：補回原本的地面再報錯，
    -- 沒記進撤回清單，帳本沒有紀錄
    local nSq = at(490, 497)
    local realAdd = nSq.addFloor
    local nPlaced = {}
    nSq.addFloor = function(self, name)
        if name == "blends_natural_02_6" then return nil end
        return realAdd(self, name)
    end
    local okDig = pcall(Place.dig, nSq, waterS, nPlaced)
    nSq.addFloor = realAdd
    check(okDig == false and #nPlaced == 0 and #nSq.objects == 1 and nSq:getFloor() and nSq:getFloor().spr == natS
        and Floors.get(nSq:getFloor()) == nil,
        "水面放不上去：補回原本的地面再報錯，不記撤回、不記帳本")
    -- 引擎把水面加進格子之後才丟例外（addFloor 回 nil、水面已經在格子上）：拿掉那片水、補回原本的地面再報錯
    nSq.addFloor = function(self, name)
        local f = realAdd(self, name)
        if name == "blends_natural_02_6" then return nil end
        return f
    end
    local okDigX = pcall(Place.dig, nSq, waterS, nPlaced)
    nSq.addFloor = realAdd
    check(okDigX == false and #nPlaced == 0 and #nSq.objects == 1 and nSq:getFloor() and nSq:getFloor().spr == natS
        and not nSq:has(F.water) and Floors.get(nSq:getFloor()) == nil,
        "水面加進格子後才失敗：拿掉那片水、補回原本的地面再報錯，不留沒有紀錄的水面")
    -- addFloor 本身壞了（水面和原地面都放不上去）：把拆掉的那片原地板放回去再報錯
    local keepFloor = nSq:getFloor()
    nSq.addFloor = function() return nil end
    local okDigY = pcall(Place.dig, nSq, waterS, nPlaced)
    nSq.addFloor = realAdd
    check(okDigY == false and #nPlaced == 0 and #nSq.objects == 1 and nSq:getFloor() == keepFloor,
        "水面和原地面都放不上去：拆掉的那片原地板放回去，不留一格沒有地板")
    -- 水面放上去之後才出錯：已經記進撤回清單，撤回換回原地面
    local realPut = Floors.put
    Floors.put = function() error("ledger boom") end
    local okDig3 = pcall(Place.build, "water", { { sq = nSq, spr = waterS } }, nPlaced)
    Floors.put = realPut
    local wasWater = nSq:has(F.water)
    Place.undo(nPlaced)
    check(okDig3 == false and wasWater and #nPlaced == 1 and nSq:getFloor() and nSq:getFloor().spr == natS and not nSq:has(F.water),
        "水面放上去之後才出錯：撤回清單有這一格，撤回後換回原地面")
    -- 填平時原本的地面補不上去：補泥土；兩張都補不上才報錯
    local dSq = at(491, 497)
    local dw = Place.dig(dSq, waterS, nil)
    local realAdd2 = dSq.addFloor
    dSq.addFloor = function(self, name)
        if name ~= Place.DIRT then return nil end
        return realAdd2(self, name)
    end
    Place.fill(dw)
    local dirtOk = dSq:getFloor() and dSq:getFloor():getSprite():getName() == Place.DIRT and #dSq.objects == 1
    dSq.addFloor = realAdd2
    local dw2 = Place.dig(dSq, waterS, nil)
    dSq.addFloor = function() return nil end
    local okFill2 = pcall(Place.fill, dw2)
    dSq.addFloor = realAdd2
    check(dirtOk and okFill2 == false and dSq:getFloor() == dw2 and #dSq.objects == 1 and Floors.get(dw2) ~= nil
        and Place.refundOf(dw2) ~= nil,
        "填平時原本的地面補不上去：補泥土；連泥土也補不上就把水面放回去再報錯（不留沒有地板的格子，帳本也還在）")
    -- 補地時地板加進格子後才失敗（addFloor 回 nil、還沒送給客戶端）：半套的拿掉，不當成填好了，水面放回去再報錯
    dSq.addFloor = function(self, name)
        realAdd2(self, name)
        return nil
    end
    local okFill3 = pcall(Place.fill, dw2)
    dSq.addFloor = realAdd2
    check(okFill3 == false and dSq:getFloor() == dw2 and #dSq.objects == 1 and Place.refundOf(dw2) ~= nil,
        "補地時地板加進格子後才失敗：半套的地板拿掉、水面放回去再報錯，不回報成功")
    -- 沒有記號的水面被別的途徑移除：帳本那一筆照樣清（照帳本與圖名認），之後同格同圖的水不算本工具挖的
    dw2.md = {}
    dSq:transmitRemoveItemFromSquare(dw2, false)
    local later = mk(waterS)
    later.md.builderEntry = "blends_natural_02_6"
    later.sq = dSq
    dSq.objects = { later }
    check(Floors.get(later) == nil and Place.refundOf(later) == nil, "沒有記號的水面被移除：帳本照樣清掉，同一格之後的水不繼承紀錄")
    dSq.objects = {}
    realAdd2(dSq, "blends_natural_01_21")
    -- 單機在水面旁蓋一般地板：周圍 8 格的水面幾何也重畫（多人由客戶端收到新地板時處理）
    require "MinidoracatBuilder/Pond"
    local gSq, gN = at(496, 495), at(497, 496)
    local g0 = gN.cleared
    isServer = function() return false end
    Place.dig(gSq, waterS, nil)
    isServer = realServer
    check(gN.cleared - g0 == 1, "單機挖：addFloor 之外再照客戶端那一份清 9 格")
    -- 拖一片水面：離玩家遠的先挖（玩家在北邊 y＝8.5，拖 10..12 × 10..12，從最近的那一排按下）
    local Cur = MinidoracatBuilder.Cursor
    local drag = Cur.shape(10, 10, 0, 12, 12, "fill", 64)
    local far = Cur.farFirst(drag, 11.5, 8.5)
    local rowsOk = #far == 9 and drag[1][2] == 10
    for i = 1, 9 do rowsOk = rowsOk and far[i] ~= nil and far[i][2] == (i <= 3 and 12 or i <= 6 and 11 or 10) end
    check(rowsOk and far[3][1] == 11 and far[9][1] == 11,
        "水面拖一片：最遠的那一排先挖、按下的那一排最後；同一排裡離玩家最近的那格最後")
    local back = Cur.farFirst(far, 11.5, 8.5) -- 已經排好的（遠的在前）再排一次：順序不變
    local same = #back == 9
    for i = 1, 9 do same = same and back[i] == far[i] end
    -- 接到游標上：水面拖一片照遠近排，超過上限的是離玩家最近的幾格；別的種類照按下那格起的蛇形
    local function dragOf(kind, px, py)
        local c = { canDrag = true, entry = { kind = kind }, d = 0, max = 6, sides = {},
            character = { getX = function() return px end, getY = function() return py end } }
        return Cur.anchors(c, 10, 10, 0, 12, 12)
    end
    local wl, fl = dragOf("water", 11.5, 8.5), dragOf("floor", 11.5, 8.5)
    check(same and #wl == 9 and wl[1][2] == 12 and wl[6].code == nil and wl[7].code == "OVER_MAX" and wl[7][2] == 10
        and wl[9][2] == 10 and fl[1][1] == 10 and fl[1][2] == 10 and fl[7].code == "OVER_MAX" and fl[9][2] == 12,
        "游標：水面拖一片遠的在前、超過上限的是最近的那一排；地板照舊從按下那格排起")
    -- 站在要挖的範圍裡（含邊上那一圈）：整片不送，免得四周挖完被水圍住；站在範圍外一格就照常。地板不受影響
    local inW, edgeW, inF = dragOf("water", 11.5, 11.5), dragOf("water", 12.9, 10.1), dragOf("floor", 11.5, 11.5)
    local allIn = #inW == 9 and #edgeW == 9
    for i = 1, 9 do allIn = allIn and inW[i].code == "STAND_OUTSIDE" and edgeW[i].code == "STAND_OUTSIDE" end
    check(allIn and inF[1].code == nil and dragOf("water", 13.1, 10.5)[1].code == nil
        and MinidoracatBuilder.Messages.CODES.STAND_OUTSIDE == true,
        "游標：拖一片水面時自己站在範圍裡，整片標 STAND_OUTSIDE 不送；站在範圍外照常，地板不受影響")
    local sSq, sN, pSq = at(490, 494), at(491, 495), at(490, 496)
    local c0, n0 = sSq.cleared, sN.cleared
    Place.build("floor", { { sq = sSq, spr = floorS, cost = { items = {} } } }, {})
    local c1, n1, p1 = sSq.cleared, sN.cleared, pSq.cleared
    isServer = function() return false end
    Place.build("floor", { { sq = pSq, spr = floorS, cost = { items = {} } } }, {})
    isServer = realServer
    check(c1 - c0 == 1 and n1 == n0 and pSq.cleared - p1 == 2 and sN.cleared - n1 == 1,
        "蓋一般地板：伺服器只清自己那一格；單機另外照客戶端那一份清 9 格")
    -- 別的 MOD 的水面地板帶拆解屬性：照樣由本工具填平，不交給原版拆解（一般地板帶同樣屬性的照舊走原版拆解）
    scrapDefs.WgMetal = { perk = perkObj("MetalWelding"), returnItems = { { returnItem = "Base.ScrapMetal", maxAmount = 2 } } }
    local modWater = sprite("modwater_01_0", 4791, { flags = WATER.flags, keys = { waterAmount = "9999", CanScrap = "", Material = "WgMetal" } })
    local modFloor = sprite("modwater_01_1", 4792, { flags = { "solidfloor" }, keys = { CanScrap = "", Material = "WgMetal" } })
    check(Cost.refund("water", modWater) == "builder" and Cost.refund("floor", modFloor) == "scrap",
        "帶拆解屬性的水面：拆除方式仍是本工具填平；同樣屬性的一般地板照舊是原版拆解")
    scrapDefs.WgMetal = nil

    -- 在水面上蓋地板：照「地板一律換」拆掉水面，不留水面紀錄
    local fSq = at(496, 492)
    local w2 = Place.dig(fSq, waterS)
    Place.build("floor", { { sq = fSq, spr = floorS, cost = { items = {} } } }, {})
    local anyWater = false
    for _, ob in ipairs(fSq.objects) do anyWater = anyWater or ob == w2 or Dismantle.kindOf(ob) == "water" end
    check(not anyWater and not fSq:has(F.water) and fSq.objects[1] and fSq.objects[1].name == "pf_floor_01_0",
        "水面上蓋地板：水面被拆掉、換成新地板，格上沒有水面物件或記號")

    -- 蓋到一半出錯撤回：換回原本的地面，不留沒有地板的格子
    local uSq = at(497, 492)
    local placed = {}
    Place.build("water", { { sq = uSq, spr = waterS } }, placed)
    local dug = uSq:getFloor() and uSq:getFloor().spr == waterS
    Place.undo(placed)
    check(dug and uSq:getFloor() and uSq:getFloor().spr == natS and not uSq:has(F.water), "撤回：挖好的水面換回原地面")

    -- 客戶端重畫（client/MinidoracatBuilder/Pond.lua）
    require "MinidoracatBuilder/Pond"
    local Pond = MinidoracatBuilder.Pond
    local function counts(cx, cy)
        local out = {}
        for dy = -1, 1 do for dx = -1, 1 do out[#out + 1] = at(cx + dx, cy + dy).cleared end end
        return out
    end
    local function grew(before, after, by)
        for i = 1, #before do if after[i] - before[i] ~= by then return false end end
        return true
    end
    local trap = mk(crateS)
    function trap:getSquare() error("non-floor object touched its square") end
    local nilProps = { getProperties = function() return nil end, getSquare = function() error("touched") end }
    local b0 = counts(494, 494)
    local okTrap = pcall(Pond.onObjectAdded, trap) and pcall(Pond.onObjectAdded, nilProps)
    check(okTrap and grew(b0, counts(494, 494), 0), "客戶端：不是地板的物件（含沒有屬性的地上物品）不碰任何格子")
    local wObj = mk(waterS)
    wObj.sq = at(494, 494)
    local b1 = counts(494, 494)
    fire("OnObjectAdded", wObj)
    check(grew(b1, counts(494, 494), 1), "客戶端：收到水面地板，那一格和周圍 8 格的水面幾何各清一次（事件已掛上）")
    local dry = mk(natS)
    dry.sq = at(494, 494)
    local b2 = counts(494, 494)
    Pond.onObjectAdded(dry)
    check(grew(b2, counts(494, 494), 1), "客戶端：填平後收到乾地地板，周圍 8 格的岸邊幾何也清掉重建")
    local upObj = mk(natS)
    upObj.sq = wsq(494, 494, 1, {})
    local b3 = counts(494, 494)
    Pond.onObjectAdded(upObj)
    check(grew(b3, counts(494, 494), 0) and upObj.sq.cleared == 0, "客戶端：二樓的地板不碰一樓的水面幾何")
    local b4 = counts(492, 495)
    Place.dig(at(492, 495), waterS)
    local mp = counts(492, 495)
    isServer = function() return false end
    Place.fill(at(492, 495):getFloor())
    isServer = realServer
    local sp = counts(492, 495)
    check(mp[5] - b4[5] == 1 and mp[1] == b4[1] and sp[1] - mp[1] == 1 and sp[5] - mp[5] == 2,
        "伺服器挖：只清自己那一格（引擎 addFloor），不叫客戶端的重畫；單機填平：addFloor 之外再照客戶端那一份清 9 格")
    -- 一次挖好幾格：每格都排一次走路（不靠「排隊當下已經在旁邊」的判斷），站位排除它自己和前面緊鄰的格子；只挖一格照舊
    local keepClient, keepLu, keepQ = isClient, luautils, ISTimedActionQueue
    isServer, isClient = function() return false end, function() return false end
    local q, finds, adjWalks = {}, {}, 0
    ISTimedActionQueue = { clear = function() q = {} end, add = function(a) q[#q + 1] = a end,
        isPlayerDoingAction = function() return false end }
    luautils = { walkAdj = function() adjWalks = adjWalks + 1 return true end, walkAdjWall = function() return true end }
    AdjacentFreeTileFinder = { Find = function(sq, _, skip)
        finds[#finds + 1] = { sq = sq, n = #skip, first = skip[1] }
        return at(493, 496)
    end }
    ISWalkToTimedAction = { new = function(_, _, loc) return { walk = loc } end }
    sb.KindWater = true
    nowMs = nowMs + 6000
    local dn = MinidoracatBuilder.Client.build(P, "blends_natural_02_6",
        { { 493, 492, 0, 0 }, { 493, 493, 0, 0 }, { 491, 494, 0, 0 } }, nil)
    check(dn ~= nil and #q == 6 and q[1].walk == at(493, 496) and q[2].i == 1 and q[3].walk and q[4].i == 2 and q[6].i == 3
        and adjWalks == 0 and #finds == 3 and finds[1].n == 1 and finds[1].first == at(493, 492) and finds[2].n == 2
        and finds[3].n == 1,
        "一次挖好幾格：每格各排一次走路再排動作；站位排除自己和前面緊鄰的格子，不緊鄰的不放進清單")
    nowMs = nowMs + 6000
    MinidoracatBuilder.Client.build(P, "blends_natural_02_6", { { 493, 492, 0, 0 } }, nil)
    check(adjWalks == 1 and #finds == 3 and #q == 1 and q[1].i == 1, "只挖一格：照舊走原版的走到旁邊")
    -- 後面有一格找不到站位：整批不排（只排前面幾格的話，挖完可能把最後站的地方圍住），記下是第幾格
    local calls = 0
    AdjacentFreeTileFinder.Find = function()
        calls = calls + 1
        if calls == 2 then return nil end
        return at(493, 496)
    end
    nowMs = nowMs + 6000
    MinidoracatBuilder.Client.build(P, "blends_natural_02_6",
        { { 493, 492, 0, 0 }, { 493, 493, 0, 0 }, { 491, 494, 0, 0 } }, nil)
    local pend = MinidoracatBuilder.Client.pending
    check(#q == 0 and calls == 2 and pend and pend.noRoom == 2 and pend.noneQueued == true,
        "一次挖好幾格、其中一格沒有站位：一個動作都不排，記下第 2 格沒有空位、整批沒排")
    -- 一次填平好幾格：近的先填；排隊當下四周都是水、沒有地方站的那格，走到緊鄰、前面排過的那一格（輪到時已經填成地面）；
    -- 旁邊沒有排過的格子才跳過
    local w1, w2, w3 = Place.dig(at(491, 492), waterS, nil), Place.dig(at(490, 492), waterS, nil),
        Place.dig(at(490, 490), waterS, nil)
    local function fillItem(obj, x, y)
        return { x = x, y = y, z = 0, name = "blends_natural_02_6", kind = "water", route = "builder", obj = obj }
    end
    luautils.walkAdj = function(_, sq) return sq == at(491, 492) end
    nowMs = nowMs + 6000
    MinidoracatBuilder.Client.dismantleMany(P, { fillItem(w3, 490, 490), fillItem(w2, 490, 492), fillItem(w1, 491, 492) }, nil)
    local ub = MinidoracatBuilder.Client.pendingUnbuild
    check(#q == 3 and q[1].i == 3 and q[2].walk == at(491, 492) and q[3].i == 2 and ub and ub.skipped.NO_ROOM == 1,
        "一次填平好幾格：近的先排；沒有站位的走到緊鄰、前面排過的那格再填；旁邊沒有排過的才跳過（NO_ROOM 1 格）")
    isServer, isClient, luautils, ISTimedActionQueue = realServer, keepClient, keepLu, keepQ
    AdjacentFreeTileFinder, ISWalkToTimedAction = nil, nil

    instanceof = realInst
    sb.RecipeMaterials, sb.CostMultiplier, sb.KindWater, sb.RequireSkill = keepRM, keepMult, keepKW, keepSkill
    spriteMap, spriteOrder = keepMap, keepOrder
end)()

print("情境四十八：帳本存檔（使用者 2026-11-14）：數字鍵＋對照表、舊存檔複製進分片、每一筆都讀得回來才清舊表、存檔只寫了一部分、開新的一片、放不下時不記")
;(function()
    local Floors, Store = MinidoracatBuilder.Floors, MinidoracatBuilder.Store
    local inst, NAME = Floors.instance, "MinidoracatBuilderFloors"
    local keepBytes, keepHard, keepMax, realPrint = Store.SHARD_BYTES, Store.SHARD_HARD, Store.SHARD_MAX, print
    local keepSlack = Store.SHARD_SLACK
    Store.SHARD_SLACK = 0 -- 這個情境的大小上限都照 SHARD_HARD 算；換值多出來的空間在 11f 另外驗
    local K = Store.pos
    local function fo(x, y, z)
        return { getSquare = function() return { getX = function() return x end, getY = function() return y end,
                getZ = function() return z or 0 end } end,
            getSprite = function() return { getName = function() return "floors_a_01_0" end } end }
    end
    local function P(n) return { ["Base.Plank"] = n, ["Base.Nails"] = 1 } end
    local function entry(n) return { s = "floors_a_01_0", i = P(n) } end
    local function count(t)
        local n = 0
        for _ in pairs(t or {}) do n = n + 1 end
        return n
    end
    local function deep(t)
        if type(t) ~= "table" then return t end
        local c = {}
        for k, v in pairs(t) do c[k] = deep(v) end
        return c
    end
    local function mine(name) return name:sub(1, #NAME + 1) == NAME .. "_" end
    -- 存檔：主系統與每一片各一個檔，只存白名單的鍵。回傳的是另一份，和記憶體裡的表無關
    local function save()
        local files = { main = { floors = deep(inst.floors) }, shards = {} }
        for name, md in pairs(HARNESS_GOS_SHARDS) do
            if mine(name) then files.shards[name] = { v = md.v, data = deep(md.data), dict = deep(md.dict) } end
        end
        return files
    end
    -- 照一組檔重開：main 是 nil＝主系統的檔是空的；shards 裡沒有的＝那個檔不在。別本帳本的分片不動
    local function boot(main, shards)
        local names = {}
        for name in pairs(HARNESS_GOS_SHARDS) do
            if mine(name) then names[#names + 1] = name end
        end
        for _, name in ipairs(names) do HARNESS_GOS_SHARDS[name] = nil end
        Floors.instance = nil -- 新的一場（新的 Lua 環境）
        for name, md in pairs(shards or {}) do HARNESS_GOS_SHARDS[name] = deep(md) end
        inst.floors = main and deep(main.floors) or nil
        inst:initSystem()
    end
    local function quiet(fn, ...) -- 不印 log 地跑一段
        print = function() end
        fn(...)
        print = realPrint
    end
    local function only(files, ...) -- 只留指定的那幾片的檔
        local keep = {}
        for _, n in ipairs({ ... }) do keep[NAME .. "_" .. n] = files.shards[NAME .. "_" .. n] end
        return keep
    end
    local function shard(n) return HARNESS_GOS_SHARDS[NAME .. "_" .. n] or {} end
    local function inShard(n, x, y) return (shard(n).data or {})[K(x, y, 0)] ~= nil end
    local function file(data, dict) return { v = 1, data = data, dict = dict } end
    local function plank(o) return Floors.get(o) and Floors.get(o).i["Base.Plank"] end
    local function old() -- 四筆正常的（一筆的數量是字串：舊存檔的 buildMaterials 搬來的），五筆不是帳本格式的
        return { ["10,10,0"] = entry(1), ["11,10,0"] = entry(2), ["16,10,0"] = entry(6),
            ["15,10,0"] = { s = "floors_a_01_0", i = { ["Base.Plank"] = "2" } },
            ["12,10,0"] = 5, [7] = entry(9),
            ["13,10,0"] = { s = "floors_a_01_0", i = { [1] = 1 } },
            ["14,10,0"] = { s = "floors_a_01_0", i = {}, extra = 1 },
            ["17,10,0"] = { s = "floors_a_01_0", i = { ["Base.Plank"] = true } } }
    end
    local A, B, D, N = fo(10, 10), fo(11, 10), fo(16, 10), fo(20, 10)
    local big4 = { ["Base.Plank"] = 1, ["Base.Nails"] = 1, ["Base.Screws"] = 1, ["Base.Woodglue"] = 1 }

    -- 0. 位置算成的數字鍵：每個位置、每條邊各一個，double 記得準；超出範圍不給鍵
    local seen, clash = {}, false
    for x = -2, 2 do
        for y = -2, 2 do
            for z = -1, 1 do
                for e = 0, 3 do
                    local k = K(x * 1000, y * 1000, z, e)
                    clash = clash or k == nil or seen[k] ~= nil or k ~= math.floor(k)
                    seen[k or 0] = true
                end
            end
        end
    end
    check(not clash and K(-2097152, -2097152, -32) == 0 and K(2097151, 2097151, 31, 3) == 2 ^ 52 - 1
        and K(2097152, 0, 0) == nil and K(0, -2097153, 0) == nil and K(0, 0, 32) == nil and K(0, 0, -33) == nil,
        "位置算成數字鍵：不同的位置與邊不撞，最大的鍵 2^52−1（double 記得準）；超出 ±2,097,152 格或樓層範圍回 nil")

    -- 1. 舊存檔第一次開服：正常的四筆複製進第 1 片，舊表留著；不是帳本格式的五筆跳過、不丟錯
    boot({ floors = old() })
    local st = Floors.stats()
    check(plank(A) == 1 and plank(B) == 2 and plank(D) == 6 and plank(fo(15, 10)) == "2" and count(shard(1).data) == 4
        and count(inst.floors) == 9,
        "舊存檔第一次開服：四筆複製進第 1 片、查得到（數量是字串的照原樣），舊表還留著；不是帳本格式的五筆（材料鍵是數字、多一個欄位、數量是布林…）跳過")
    check(st.n == 4 and st.shards[1].n == 4 and st.shards[1].bytes == 393 and st.bytes == 393
        and type(shard(1).data[K(10, 10, 0)]) == "number" and shard(1).v == 1,
        "一筆的估計大小照存檔格式算：數字鍵 9＋編號 9＝18；對照表一項＝編號 9＋圖名與兩種材料 78＝87，數量是字串 \"2\" 的那一項 60；4×18＋3×87＋60＝393")
    local mt = getmetatable(HARNESS_GOS_SHARDS[NAME .. "_1"])
    check(mt and rawget(mt, "getInitialStateForClient") and rawget(mt, "OnClientCommand") and rawget(mt, "OnChunkLoaded")
        and rawget(Floors, "getInitialStateForClient") and rawget(Floors, "OnClientCommand") and rawget(Floors, "OnChunkLoaded"),
        "引擎對系統表取方法只看 metatable 那張表本身：分片與主系統的三個方法都直接定義在上面（少了客戶端連線時伺服器丟錯）")
    -- 2. 舊表還在的這一場：拆掉的那一筆同時從舊表刪掉；新蓋的不進舊表
    Floors.forget(A)
    Floors.put(N, P(4))
    check(inst.floors["10,10,0"] == nil and inst.floors["20,10,0"] == nil and count(inst.floors) == 8 and plank(N) == 4,
        "舊表還在的這一場：拆掉的那一筆也從舊表刪掉（之後不會被補回來），新蓋的只進分片")
    local f1 = save()
    -- 3. 正常重開：舊表剩下的每一筆分片都讀得到，舊表清掉；拆掉的沒有回來
    boot(f1.main, f1.shards)
    check(count(inst.floors) == 5 and inst.floors["12,10,0"] == 5 and inst.floors["11,10,0"] == nil and Floors.get(A) == nil
        and plank(B) == 2 and plank(D) == 6 and plank(N) == 4 and Floors.stats().n == 4,
        "正常重開：舊表讀得懂的每一筆分片都讀得到才清；讀不懂的五筆留在主系統不丟；拆掉的那一筆沒有回來")
    local f1b = save()
    boot(f1b.main, f1b.shards)
    check(count(inst.floors) == 5 and Floors.stats().n == 4, "之後每次重開：讀不懂的五筆照樣留著，帳本不變")
    -- 4. 存檔只寫了主系統、分片沒寫成：照舊表補回還沒拆的；拆掉的不回來；舊表留到下一次
    boot(f1.main, {})
    check(plank(B) == 2 and plank(D) == 6 and Floors.get(A) == nil and Floors.get(N) == nil and count(inst.floors) == 8
        and count(shard(1).data) == 3, "存檔只寫了主系統、分片沒寫成：照舊表補回還沒拆的三筆，拆掉的不回來，舊表不清")
    local f2 = save()
    boot(f2.main, f2.shards)
    check(count(inst.floors) == 5 and plank(B) == 2 and plank(D) == 6, "補回來之後再正常重開一次：這時才清舊表")
    -- 5. 主系統的檔是空的、分片在：照分片
    boot(nil, f1.shards)
    check(plank(B) == 2 and plank(D) == 6 and plank(N) == 4 and Floors.get(A) == nil and count(inst.floors) == 0,
        "主系統的檔是空的、分片在：帳本照分片，一筆不少")
    local newer = {}
    newer[NAME .. "_1"] = file({ [K(10, 10, 0)] = 1 }, { [1] = entry(7) })
    boot({ floors = { ["10,10,0"] = entry(1), ["11,10,0"] = entry(2) } }, newer)
    check(plank(A) == 7 and plank(B) == 2 and count(inst.floors) == 2, "分片已經有的那一格以分片為準，只補分片沒有的")
    Floors.forget(B) -- 換地板的正式流程：舊的那片移出世界時先清，新的蓋好再記
    Floors.put(B, { ["Base.Plank"] = 9 })
    Floors.put(A, big4)
    local f1c = save()
    check(f1c.main.floors["11,10,0"].i["Base.Plank"] == 9 and f1c.main.floors["11,10,0"].i["Base.Nails"] == nil
        and f1c.main.floors["10,10,0"] == nil and plank(B) == 9 and Floors.get(A).i["Base.Screws"] == 1,
        "舊表還在時換地板（先清再記）：新的一筆沒有比舊檔原本那一格大，舊表那一格記新的；比較大的從舊表刪掉（主系統的存檔在搬完之前只能變小）")
    boot(f1c.main, {})
    check(plank(B) == 9 and Floors.get(A) == nil,
        "之後分片沒寫成：舊表換過的那一格照新的值補回；從舊表刪掉的那一格不會被補回舊的值")
    local nBefore = Floors.stats().n
    inst.floors = { ["30,10,0"] = entry(3) }
    inst:initSystem()
    check(Floors.stats().n == nBefore and Floors.get(fo(30, 10)) == nil and Floors.instance == inst,
        "帳本建好之後同一場再呼叫 initSystem：不重讀、不動帳本")
    boot({ floors = { ["10,10,0"] = { s = "\229\156\176\230\157\191_01_0", i = {} } } })
    check(Floors.stats().shards[1].bytes == 71,
        "圖名有不是 ASCII 的字：估計大小往大的算（這裡的 Lua 一個字 3 bytes：18＋9＋（5＋4＋（3＋11＋2×6）＋4＋5）＝71，實際 59），不會低估")
    -- 5c. 舊表裡這次放不進分片的（開不了新的一片、每一片都到硬上限）：照樣查得到、不被清掉；放得下之後再補進去
    Store.SHARD_BYTES, Store.SHARD_HARD, HARNESS_GOS_COUNT = 250, 250, 100 -- 一片放兩筆值不同的（各 18＋87）
    quiet(boot, { floors = { ["10,10,0"] = entry(1), ["11,10,0"] = entry(2), ["12,10,0"] = entry(3) } })
    local leftObj, leftKey, leftN
    for x = 10, 12 do
        if not inShard(1, x, 10) then leftObj, leftKey, leftN = fo(x, 10), x .. ",10,0", x - 9 end
    end
    check(Floors.stats().n == 2 and leftObj ~= nil and plank(leftObj) == leftN and count(inst.floors) == 3,
        "舊表有一筆放不進分片：那一筆照樣查得到（讀檔時不會被當成沒紀錄而重記成空的），舊表不清")
    quiet(Floors.put, leftObj, { ["Base.Plank"] = 9, ["Base.Nails"] = 1, ["Base.Screws"] = 1 })
    check(plank(leftObj) == leftN and inst.floors[leftKey] ~= nil, "對那一筆重記但放不下：舊表裡原本那一筆不刪")
    local f5c = save()
    Floors.forget(leftObj)
    check(Floors.get(leftObj) == nil and inst.floors[leftKey] == nil, "拆掉放不進分片的那一筆：查不到了，舊表也刪掉")
    quiet(boot, f5c.main, f5c.shards)
    check(Floors.stats().n == 2 and plank(leftObj) == leftN and count(inst.floors) == 3,
        "下一次開服還是放不下（這次沒有複製任何一筆）：舊表照樣不清，那一筆照樣查得到")
    HARNESS_GOS_COUNT = nil
    Floors.put(leftObj, { ["Base.Plank"] = 8 })
    check(plank(leftObj) == 8 and inst.floors[leftKey].i["Base.Plank"] == 8,
        "同一場之後開得了新的一片：那一筆重記成功，查到的是新的，舊表那一筆也換成新的")
    Floors.forget(leftObj)
    check(Floors.get(leftObj) == nil, "再拆掉：查不到，不會讀回放不進分片時留著的舊值")
    boot(f5c.main, f5c.shards)
    check(Floors.stats().n == 3 and plank(leftObj) == leftN and count(inst.floors) == 3 and #Floors.stats().shards == 2,
        "之後開得了新的一片：放不進去的那一筆補進分片，舊表留到下一次確認")
    local f5d = save()
    boot(f5d.main, f5d.shards)
    check(count(inst.floors) == 0 and Floors.stats().n == 3, "再重開：三筆分片都讀得到，舊表清掉")
    Store.SHARD_HARD = keepHard

    -- 6. 舊帳本要分成三片，存檔時後面兩片沒寫成：照舊表補回那幾筆，舊表不清；都寫成之後才清
    local five = {}
    for x = 10, 14 do five[x .. ",10,0"] = entry(x) end
    boot({ floors = five })
    local f3 = save()
    check(#Floors.stats().shards == 3 and Floors.stats().n == 5 and count(f3.shards) == 3, "舊帳本一片放不下：第一次開服就分成三片")
    boot(f3.main, only(f3, 1))
    local all5 = true
    for x = 10, 14 do all5 = all5 and plank(fo(x, 10)) == x end
    check(all5 and Floors.stats().n == 5 and count(inst.floors) == 5,
        "只有第 1 片寫成（分片讀得到東西，但不是全部）：後面兩片的三筆照舊表補回，舊表不清")
    local f4 = save()
    boot(f4.main, f4.shards)
    check(count(inst.floors) == 0 and Floors.stats().n == 5, "三片都寫成之後重開：舊表清掉，五筆都在")
    -- 7. 有幾片看存檔資料夾，不靠主系統：主系統的檔是空的照樣找到三片；中間那一片的檔不在，後面那一片照樣讀
    boot(nil, f3.shards)
    check(#Floors.stats().shards == 3 and Floors.stats().n == 5, "主系統的檔是空的：三片照樣都找到")
    boot(nil, only(f3, 1, 3))
    check(#Floors.stats().shards == 3 and Floors.stats().n == 3 and Floors.stats().shards[2].n == 0,
        "第 2 片的檔不在：第 1、3 片照樣讀回來")
    local dup = {}
    dup[NAME .. "_1"] = file({ [K(1, 1, 0)] = 1, [K(2, 1, 0)] = 5, [K(4, 1, 0)] = 3, [K(5, 1, 0)] = "1" },
        { [1] = entry(1), [3] = { s = 5, i = {} } })
    dup[NAME .. "_2"] = file({ [K(1, 1, 0)] = 1, [K(3, 1, 0)] = 2 }, { [1] = entry(9), [2] = entry(3) })
    quiet(boot, nil, dup)
    st = Floors.stats()
    check(plank(fo(1, 1)) == 1 and plank(fo(3, 1)) == 3 and st.n == 2 and st.shards[1].bytes == 105 and st.shards[2].bytes == 105
        and count(shard(1).data) == 1 and count(shard(1).dict) == 1 and count(shard(2).data) == 1 and shard(2).dict[1] == nil,
        "分片的檔裡編號對不到對照表的、對照表那一項不是帳本格式的、或和前面的片同一個鍵的：不收也不算大小，沒人用的對照表項目拿掉，其他筆照讀")
    boot(nil, {})
    Floors.put(fo(1, 1), P(1))
    Floors.put(fo(2, 1), P(2))
    HARNESS_GOS_SHARDS[NAME .. "_2"] = file({ [K(3, 1, 0)] = 1 }, { [1] = entry(9) }) -- 開服之後才出現的檔（例：備份被覆蓋上來）
    Floors.put(fo(3, 1), P(3))
    st = Floors.stats()
    check(plank(fo(3, 1)) == 3 and st.n == 3 and st.shards[2].n == 1 and st.shards[2].bytes == 105,
        "開新的一片時那個檔已經有同一格的紀錄：照那一筆改，筆數與大小不重複算")
    Store.SHARD_HARD, Store.SHARD_MAX = 250, 2
    boot(nil, {})
    Floors.put(fo(1, 1), P(1))
    Floors.put(fo(2, 1), P(2))
    HARNESS_GOS_SHARDS[NAME .. "_2"] = file({ [K(3, 1, 0)] = 1, [K(4, 1, 0)] = 2 }, { [1] = entry(9), [2] = entry(1) })
    quiet(Floors.put, fo(3, 1), P(5))
    st = Floors.stats()
    check(plank(fo(3, 1)) == 5 and st.n == 4 and st.shards[2].n == 2 and st.shards[2].bytes == 210 and count(shard(2).dict) == 2,
        "開新的一片時讀進同一格的紀錄、而且每一片都放不下新的一筆：照已經有的那一筆原位改（舊值沒人用了、騰出的空間算進去），不當成放不下")
    Store.SHARD_HARD, Store.SHARD_MAX = keepHard, keepMax

    -- 8. 一片放不下就開新的一片；前面的片騰出空間後新的一筆放回前面；換地板（先清再記）留在原本那一片
    boot(nil, {})
    Floors.put(fo(1, 1), P(1))
    Floors.put(fo(2, 1), P(2))
    Floors.put(fo(3, 1), P(3))
    check(#Floors.stats().shards == 2 and count(shard(1).data) == 2 and count(shard(2).data) == 1 and inShard(2, 3, 1)
        and table.concat(HARNESS_GOS_KEYS[NAME .. "_2"], ",") == "v,data,dict", "第 1 片放不下第三筆：開第 2 片（存檔白名單 v、data、dict）")
    Floors.forget(fo(1, 1))
    Floors.forget(fo(3, 1))
    Floors.put(fo(3, 1), { ["Base.Plank"] = 3 })
    st = Floors.stats()
    check(not inShard(1, 3, 1) and inShard(2, 3, 1) and plank(fo(3, 1)) == 3 and st.shards[1].bytes == 105
        and st.shards[2].bytes == 83 and st.shards[2].n == 1,
        "換地板（先清掉舊的那一筆再記新的）：第 1 片有空位，新的那一筆還是回原本的第 2 片")
    Floors.put(fo(4, 1), P(4))
    Floors.put(fo(3, 1), P(1))
    st = Floors.stats()
    check(not inShard(1, 1, 1) and inShard(1, 4, 1) and st.shards[1].bytes == 210
        and Floors.get(fo(3, 1)).i["Base.Nails"] == 1 and st.shards[2].bytes == 105 and st.shards[2].n == 1 and st.n == 3,
        "拆掉第 1 片的一筆：空間回收，別格新的一筆放回第 1 片；同一格直接重記留在第 2 片、大小跟著改")
    -- 9. 重開：兩片都讀回來
    local f5 = save()
    boot(f5.main, f5.shards)
    check(Floors.stats().n == 3 and plank(fo(4, 1)) == 4 and plank(fo(2, 1)) == 2 and plank(fo(3, 1)) == 1
        and #Floors.stats().shards == 2, "重開：兩片都讀回來，三筆都查得到")
    Floors.forget(fo(3, 1))
    check(count(shard(2).data) == 0 and count(shard(2).dict) == 0 and Floors.get(fo(3, 1)) == nil
        and Floors.stats().shards[2].bytes == 0, "重開後拆第 2 片的那一筆：那一片的存檔表與對照表也清掉")

    -- 10. 全伺服器的 GOS 系統數到上限：不開新的一片，放進最空的那一片；任何一片都不超過硬上限
    HARNESS_GOS_COUNT = 100
    quiet(function()
        Floors.put(fo(5, 1), P(5))
        Floors.put(fo(6, 1), P(6))
        Floors.put(fo(7, 1), P(7))
    end)
    st = Floors.stats()
    check(#st.shards == 2 and st.n == 5 and st.shards[1].bytes == 315 and st.shards[2].bytes == 210
        and HARNESS_GOS_SHARDS[NAME .. "_3"] == nil and plank(fo(7, 1)) == 7,
        "系統數到上限：不開第 3 片，放進最空的一片（超過一片的目標大小、還在硬上限內）")
    Store.SHARD_HARD = 330
    quiet(Floors.put, fo(8, 1), P(8))
    local said = ""
    print = function(s) said = said .. tostring(s) .. "\n" end
    Floors.put(fo(9, 1), P(9))
    print = realPrint
    st = Floors.stats()
    check(plank(fo(8, 1)) == 8 and Floors.get(fo(9, 1)) == nil and st.n == 6 and st.shards[1].bytes == 315
        and st.shards[2].bytes == 315 and said:find("not recorded: 9,1,0", 1, true) ~= nil,
        "每一片都到硬上限：這一筆不記（之後本工具拆不了）、log 留一行，其他筆不受影響")
    quiet(Floors.put, fo(8, 1), big4)
    st = Floors.stats()
    check(Floors.get(fo(8, 1)).i["Base.Screws"] == nil and plank(fo(8, 1)) == 8 and st.shards[2].bytes == 315 and st.n == 6,
        "同一格直接重記成比較大的一筆、會超過硬上限：不改，原本那一筆與大小都不變")
    Floors.forget(fo(8, 1))
    quiet(Floors.put, fo(8, 1), big4)
    st = Floors.stats()
    check(Floors.get(fo(8, 1)) == nil and st.shards[2].bytes == 210 and st.shards[1].bytes == 315 and st.n == 5,
        "換地板的新一筆比較大、放回原本那一片會超過硬上限：不硬塞回去（別的片也放不下，所以不記）")
    HARNESS_GOS_COUNT = nil
    local huge = {}
    for n = 10, 23 do huge["Base.Item" .. n] = 1 end
    quiet(Floors.put, fo(30, 1), huge)
    check(Floors.get(fo(30, 1)) == nil and HARNESS_GOS_SHARDS[NAME .. "_3"] == nil and Floors.stats().n == 5,
        "單一筆就超過硬上限：不記，也不為它開新的一片")
    local two4 = {}
    two4[NAME .. "_1"] = file({ [K(1, 1, 0)] = 1 }, { [1] = entry(1) })
    two4[NAME .. "_2"] = file({ [K(2, 1, 0)] = 1, [K(3, 1, 0)] = 2, [K(4, 1, 0)] = 2 }, { [1] = entry(1), [2] = entry(2) })
    HARNESS_GOS_COUNT = 100
    quiet(function()
        boot(nil, two4)
        Floors.forget(fo(4, 1))
        Floors.put(fo(4, 1), big4)
    end)
    HARNESS_GOS_COUNT = nil
    st = Floors.stats()
    check(inShard(1, 4, 1) and not inShard(2, 4, 1) and st.shards[1].bytes == 258 and st.shards[1].n == 2
        and st.shards[2].bytes == 210 and st.shards[2].n == 2 and st.n == 4,
        "換地板的新一筆原本那一片放不下、別的片放得下：記在別的片，兩片的筆數與大小都對")
    Store.SHARD_BYTES, Store.SHARD_HARD = keepBytes, keepHard

    -- 11. 對照表：一樣的「圖名＋退料」只存一份，沒有人用了就拿掉；數量是數字還是字串分開記
    boot(nil, {})
    Floors.put(fo(1, 1), P(1))
    Floors.put(fo(2, 1), P(1))
    Floors.put(fo(3, 1), P("1"))
    st = Floors.stats()
    check(Floors.get(fo(1, 1)) == Floors.get(fo(2, 1)) and Floors.get(fo(3, 1)) ~= Floors.get(fo(1, 1)) and plank(fo(3, 1)) == "1"
        and count(shard(1).dict) == 2 and st.shards[1].bytes == 3 * 18 + 87 + 82,
        "兩格蓋一樣的圖、退一樣的料：對照表只有一項，查到的是同一張表；數量是字串的另外一項")
    Floors.forget(fo(1, 1))
    check(count(shard(1).dict) == 2 and plank(fo(2, 1)) == 1, "還有別格在用：對照表那一項留著")
    Floors.forget(fo(2, 1))
    st = Floors.stats()
    check(count(shard(1).dict) == 1 and st.shards[1].bytes == 18 + 82 and st.n == 1, "最後一格也拆掉：對照表那一項拿掉，大小跟著減")
    local f11 = save()
    boot(f11.main, f11.shards)
    Floors.put(fo(4, 1), P("1"))
    check(Floors.get(fo(4, 1)) == Floors.get(fo(3, 1)) and count(shard(1).dict) == 1 and Floors.stats().shards[1].bytes == 2 * 18 + 82,
        "重開後記一樣的值：用讀回來的那一項，不另外加")

    -- 11b. 樓層算在鍵裡（舊存檔的鍵也一樣）；記下的是複本
    boot({ floors = { ["10,10,0"] = entry(1), ["10,10,-1"] = entry(2) } })
    Floors.put(fo(11, 10, -1), P(3))
    local mineF = P(4)
    Floors.put(fo(12, 10), mineF)
    mineF["Base.Plank"] = 9
    check(plank(fo(10, 10)) == 1 and plank(fo(10, 10, -1)) == 2 and plank(fo(11, 10, -1)) == 3 and Floors.get(fo(11, 10)) == nil
        and plank(fo(12, 10)) == 4 and Floors.stats().n == 4,
        "地下室和一樓同一個 x、y 是兩筆（舊存檔的鍵也一樣）；記下的是複本，呼叫的人之後改自己的表不影響帳本")
    -- 11c. 片數到上限：不再開新的一片
    Store.SHARD_BYTES, Store.SHARD_MAX = 250, 1
    quiet(function()
        boot(nil, {})
        Floors.put(fo(1, 1), P(1))
        Floors.put(fo(2, 1), P(2))
        Floors.put(fo(3, 1), P(3))
    end)
    check(#Floors.stats().shards == 1 and Floors.stats().n == 3 and HARNESS_GOS_SHARDS[NAME .. "_2"] == nil,
        "片數到上限：不開新的一片，放進最空的那一片（還在硬上限內）")
    -- 11d. 同一格重記成比較大的值、原本那一片放不下：搬到別片，原本那一片不留
    Store.SHARD_HARD, Store.SHARD_MAX = 250, keepMax
    quiet(function()
        boot(nil, {})
        Floors.put(fo(1, 1), P(1))
        Floors.put(fo(2, 1), P(2))
        Floors.put(fo(1, 1), big4)
    end)
    st = Floors.stats()
    check(not inShard(1, 1, 1) and inShard(2, 1, 1) and Floors.get(fo(1, 1)).i["Base.Screws"] == 1 and st.n == 2
        and st.shards[1].bytes == 105 and st.shards[1].n == 1 and st.shards[2].bytes == 153 and st.shards[2].n == 1
        and count(shard(1).dict) == 1,
        "同一格直接重記成比較大的一筆、原本那一片會超過硬上限而別片放得下：搬過去，原本那一片的紀錄與對照表項目都拿掉")
    Store.SHARD_BYTES, Store.SHARD_HARD = keepBytes, keepHard

    -- 11e. 片快滿了、開不了新的一片：值和這一片已經有的一樣的那一筆只要 18 bytes，照樣記得進去
    Store.SHARD_BYTES, Store.SHARD_HARD, HARNESS_GOS_COUNT = 250, 250, 100
    quiet(function()
        boot(nil, {})
        Floors.put(fo(1, 1), P(1))
        Floors.put(fo(2, 1), P(2))
        Floors.put(fo(3, 1), P(1))
        Floors.put(fo(4, 1), P(2))
        Floors.put(fo(5, 1), P(1))
        Floors.put(fo(6, 1), P(6))
    end)
    st = Floors.stats()
    check(plank(fo(3, 1)) == 1 and plank(fo(4, 1)) == 2 and Floors.get(fo(5, 1)) == nil and Floors.get(fo(6, 1)) == nil
        and st.n == 4 and st.shards[1].bytes == 246 and #st.shards == 1,
        "片快滿、開不了新的一片：值已經在這一片對照表裡的照樣記（只算紀錄本身 18 bytes），真的放不下的才不記")
    Floors.forget(fo(1, 1))
    Floors.put(fo(1, 1), P(2))
    check(plank(fo(1, 1)) == 2 and Floors.stats().shards[1].bytes == 246, "換地板換成這一片已經有的值：放得回原本那一片")
    -- 11f. 已經在這一片的那一筆換成比較大的值：可以多用 SHARD_SLACK，不必搬、也不會失敗
    Store.SHARD_SLACK, HARNESS_GOS_COUNT = 100, nil
    quiet(function()
        boot(nil, {})
        Floors.put(fo(1, 1), P(1))
        Floors.put(fo(2, 1), P(2))
        Floors.put(fo(1, 1), big4)
        Floors.put(fo(3, 1), P(3))
    end)
    st = Floors.stats()
    check(inShard(1, 1, 1) and Floors.get(fo(1, 1)).i["Base.Screws"] == 1 and st.shards[1].bytes == 258 and inShard(2, 3, 1),
        "同一格換成比較大的值：留在原本那一片（可以超過新紀錄的上限一點）；新的一格照舊不能超過，開下一片")
    Store.SHARD_SLACK = 0
    -- 11g. 伺服器上的 GOS 系統數已經逼近引擎上限、這本帳本一片都還沒有：不開（不把系統數推過上限），舊存檔照樣讀得到
    HARNESS_GOS_COUNT = 125
    quiet(function()
        boot({ floors = { ["10,10,0"] = entry(1) } })
        Floors.put(fo(11, 10), P(2))
    end)
    st = Floors.stats()
    check(#st.shards == 0 and HARNESS_GOS_SHARDS[NAME .. "_1"] == nil and plank(fo(10, 10)) == 1 and Floors.get(fo(11, 10)) == nil
        and count(inst.floors) == 1 and st.n == 0,
        "系統數逼近上限、還沒有任何一片：不開新系統；舊存檔那一筆照樣查得到、舊表不清，新蓋的不記")
    local function floorsN()
        for _, r in ipairs(Store.report()) do
            if r.id == "floors" then return r.n end
        end
    end
    local repLeft = floorsN()
    quiet(function()
        Floors.forget(fo(10, 10))
        Floors.put(fo(10, 10), P(5))
    end)
    local swapped = plank(fo(10, 10)) == 5 and inst.floors["10,10,0"].i["Base.Plank"] == 5 and Floors.stats().n == 0
    quiet(Floors.put, fo(10, 10), big4)
    check(repLeft == 1 and swapped and plank(fo(10, 10)) == 5 and inst.floors["10,10,0"].i["Base.Screws"] == nil
        and floorsN() == 1,
        "開不了片時換舊存檔那一格的地板：新的一筆沒有比舊檔原本的大就記在舊表、照樣查得到；比較大的不記、原本的不動；面板的筆數算進還在舊表的")
    Floors.forget(fo(10, 10))
    check(Floors.get(fo(10, 10)) == nil and count(inst.floors) == 0 and floorsN() == 0,
        "這時拆掉舊存檔的那一筆：查不到了，舊表也刪掉")
    HARNESS_GOS_COUNT = nil
    Floors.put(fo(11, 10), P(2))
    check(plank(fo(11, 10)) == 2 and #Floors.stats().shards == 1, "之後有空位：下一筆照常開第 1 片、記進去")
    Store.SHARD_BYTES, Store.SHARD_HARD = keepBytes, keepHard

    -- 11h. 舊值還有別格在用：換值騰不出對照表的空間，片滿時不能當成放得下
    Store.SHARD_BYTES, Store.SHARD_HARD, HARNESS_GOS_COUNT = 250, 250, 100
    quiet(function()
        boot(nil, {})
        Floors.put(fo(1, 1), P(1))
        Floors.put(fo(2, 1), P(1))
        Floors.put(fo(3, 1), P(2))
        Floors.put(fo(1, 1), P(7))
    end)
    st = Floors.stats()
    check(plank(fo(1, 1)) == 1 and st.shards[1].bytes == 228 and st.n == 3 and count(shard(1).dict) == 2,
        "兩格共用一個值、片快滿：把其中一格換成新的值放不下（舊值還有別格在用，騰不出空間），不換，大小不變")
    HARNESS_GOS_COUNT = nil
    Store.SHARD_BYTES, Store.SHARD_HARD = keepBytes, keepHard

    -- 12. 比較新的版本寫的檔（降版）：不讀、不改，新的紀錄記在別片
    local future = {}
    future[NAME .. "_1"] = { v = 2, data = { [K(1, 1, 0)] = 1 }, dict = { [1] = entry(1) } }
    quiet(function()
        boot(nil, future)
        Floors.put(fo(5, 1), P(5))
    end)
    st = Floors.stats()
    check(Floors.get(fo(1, 1)) == nil and plank(fo(5, 1)) == 5 and st.shards[1].frozen == true and inShard(2, 5, 1)
        and shard(1).v == 2 and shard(1).data[K(1, 1, 0)] == 1 and count(shard(1).data) == 1
        and shard(1).dict[1].i["Base.Plank"] == 1 and st.n == 1 and st.bytes == 105,
        "比較新的版本寫的那一片：不讀、存檔照原樣寫回去，新的一筆記在另一片，大小不把它算進去")

    boot(nil, {})
    local okPut
    quiet(function()
        okPut = pcall(Floors.put, fo(40, 1), { [1] = 1 })
        Floors.put(fo(41, 1), { ["Base.Plank"] = true })
    end)
    check(okPut and Floors.get(fo(40, 1)) == nil and Floors.get(fo(41, 1)) == nil and Floors.stats().n == 0,
        "退料表不是「物品型別 → 數量」的不記、不丟錯（存進去的大小才算得準）")
    Store.SHARD_SLACK = keepSlack
end)()

print("情境四十九：掛上去的圖、燈與平台、線路三本帳本也存進分片（使用者 2026-11-14）：舊存檔搬進來、搬完才清舊表、編號不重發")
;(function()
    local B = MinidoracatBuilder
    local Overlays, Ledger, Circuits, Store = B.Overlays, B.Ledger, B.Circuits, B.Store
    local K, STAIR = Store.pos, B.Entry.STAIR_FLOOR
    local realPrint, realInst = print, instanceof
    local function count(t)
        local n = 0
        for _ in pairs(t or {}) do n = n + 1 end
        return n
    end
    local function sqAt(x, y)
        return { getX = function() return x end, getY = function() return y end, getZ = function() return 0 end,
            getFloor = function() return nil end }
    end
    local function reopen(cls)
        print = function() end
        HARNESS_REOPEN(cls)
        print = realPrint
    end
    local drift = HARNESS_DRIFT
    check(drift() == "", "前面所有情境蓋、拆、接線之後：四本帳本記的筆數與大小和存檔表的內容一致，對照表沒有多的或缺的（" .. drift() .. "）")

    -- 掛上去的圖：地板那一件掛兩張、北邊那面牆掛一張；邊認不得的、退料不是表的讀不懂
    local oi, ON = Overlays.instance, "MinidoracatBuilderOverlays"
    local sq = sqAt(300, 300)
    oi.overlays = { ["300,300,0"] = { ov_a = { ["Base.Paint"] = 1 }, ov_b = {} },
        ["300,300,0,N"] = { ov_c = { ["Base.Plank"] = "2" } },
        ["300,300,0,X"] = { ov_d = {} }, ["301,300,0"] = { ov_e = 5 },
        ["370,300,0"] = { ov_a = { ["Base.Paint"] = 1 }, ov_b = {} }, ["371,300,0"] = { ov_c = {} } }
    reopen(Overlays)
    check(Overlays.get(sq, "ov_a")["Base.Paint"] == 1 and Overlays.get(sq, "ov_b") ~= nil
        and Overlays.get(sq, "ov_c", "N")["Base.Plank"] == "2" and Overlays.get(sq, "ov_c") == nil
        and Overlays.get(sq, "ov_a", "W") == nil and HARNESS_LEDGER(ON, K(300, 300, 0)) ~= nil
        and HARNESS_LEDGER(ON, K(300, 300, 0, 1)) ~= nil and count(oi.overlays) == 6
        and table.concat(HARNESS_GOS_KEYS[ON], ",") == "overlays",
        "掛上去的圖：舊存檔的地板那一件與牆那一件各搬成一筆數字鍵，照樣查得到；舊表留著，主系統白名單不變")
    -- 舊表還在的這一場改了兩件，存檔只寫成主系統、分片沒寫成：拿掉一張的那一件（沒有變大，舊表跟著換）照新的補回；
    -- 加了一張的那一件（變大，舊表那一筆刪掉）兩邊都沒有
    local p1, p2 = sqAt(370, 300), sqAt(371, 300)
    Overlays.forget(p1, "ov_a")
    Overlays.put(p2, "ov_d", { ["Base.Plank"] = 1 })
    HARNESS_GOS_SHARDS[ON .. "_1"] = nil
    reopen(Overlays)
    check(Overlays.get(p1, "ov_b") ~= nil and Overlays.get(p1, "ov_a") == nil and Overlays.get(sq, "ov_a") ~= nil
        and Overlays.get(sq, "ov_c", "N") ~= nil and Overlays.get(p2, "ov_c") == nil and Overlays.get(p2, "ov_d") == nil
        and count(oi.overlays) == 5,
        "掛圖的存檔只寫成主系統：沒動過的與拿掉一張的那一件照舊表補回（拿掉的那張沒有回來）；加過一張的那一件不在（已知限制）")
    Overlays.forget(sq, "ov_a")
    Overlays.put(sq, "ov_f", { ["Base.Plank"] = 1 }, "N")
    local atN = Overlays.at(sq, "N")
    atN.ov_c = nil
    check(Overlays.get(sq, "ov_a") == nil and Overlays.get(sq, "ov_b") ~= nil and oi.overlays["300,300,0"].ov_a == nil
        and oi.overlays["300,300,0"].ov_b ~= nil and Overlays.get(sq, "ov_f", "N")["Base.Plank"] == 1
        and Overlays.get(sq, "ov_c", "N") ~= nil and oi.overlays["300,300,0,N"] == nil and count(oi.overlays) == 4,
        "同一件拿掉一張、再掛一張：其他張照樣在（換成一張新的表，不改共用的那張）；舊表那兩件一件跟著換、一件刪掉；at 回的是複本")
    local s1, s2 = sqAt(310, 300), sqAt(311, 300)
    Overlays.put(s1, "ov_a", { ["Base.Paint"] = 1 })
    Overlays.put(s2, "ov_a", { ["Base.Paint"] = 1 })
    check(Overlays.get(s1, "ov_a") == Overlays.get(s2, "ov_a"), "兩件掛一樣的圖、退一樣的料：對照表共用一項")
    local mineO = { ["Base.Paint"] = 1 }
    Overlays.put(s1, "ov_g", mineO)
    mineO["Base.Paint"] = 9
    check(Overlays.get(s1, "ov_g")["Base.Paint"] == 1, "記下的是複本：呼叫的人之後改自己的表不影響帳本")
    Overlays.forget(s1, "ov_g")
    Overlays.forget(s1, "ov_a")
    check(Overlays.get(s1, "ov_a") == nil and HARNESS_LEDGER(ON, K(310, 300, 0)) == nil and Overlays.get(s2, "ov_a") ~= nil,
        "一件上最後一張拿掉：那一件整筆清掉，別件不受影響")
    reopen(Overlays)
    check(count(oi.overlays) == 2 and oi.overlays["300,300,0,X"] ~= nil and oi.overlays["301,300,0"] ~= nil
        and Overlays.get(sq, "ov_b") ~= nil and Overlays.get(sq, "ov_f", "N") ~= nil,
        "下一次開服：讀得懂的都在分片裡，舊表清掉；讀不懂的兩筆留在主系統")

    -- 燈、平台與線路：主系統的檔回到很久以前（下一個編號比分片裡的小）
    instanceof = function(o, cls) return type(o) == "table" and o.class == cls end
    local function lampAt(x, y, name, id)
        return { class = "IsoLightSwitch", keyId = id or -1, getKeyId = function(o) return o.keyId end,
            setKeyId = function(o, v) o.keyId = v end, getSquare = function() return sqAt(x, y) end,
            getSprite = function() return { getName = function() return name end } end }
    end
    local li, LN = Ledger.instance, "MinidoracatBuilder"
    local top, landKey = li.lamps.next, "321,300,0," .. STAIR
    li.lamps.e[top + 5] = { p = "320,300,0", s = "kl_x", i = { ["Base.ElectricWire"] = 2 } }
    li.lamps.e[top + 6] = { p = "nowhere", s = "kl_x", i = {} }
    li.built[landKey] = {}
    li.built["322,300,0,kl_old"] = { ["Base.ElectricWire"] = 1 } -- 0.3.0 以前的燈：不搬，照舊等讀到那一塊
    li.circuits.c[900] = { s = { ["320,300,0,sw_x"] = true }, l = { ["320,300,0,kl_x"] = true } }
    li.circuits.c[901] = { s = 5 }
    li.lamps.next, li.circuits.next = 1, 1
    reopen(Ledger)
    local oldLamp = lampAt(320, 300, "kl_x", top + 5)
    check(Ledger.get(oldLamp)["Base.ElectricWire"] == 2 and HARNESS_LEDGER(LN, top + 5).p == K(320, 300, 0)
        and li.lamps.e[top + 5] ~= nil and li.lamps.e[top + 6] ~= nil and HARNESS_LEDGER(LN, top + 6) == nil
        and HARNESS_LEDGER(LN, landKey) ~= nil and li.built["322,300,0,kl_old"] ~= nil
        and HARNESS_LEDGER(LN, "322,300,0,kl_old") == nil and Ledger.legacy >= 1,
        "燈與平台：舊存檔的燈搬成數字位置、平台照原鍵搬進分片，照樣認得；位置讀不懂的留在舊表；0.3.0 以前的燈不搬")
    check(HARNESS_LEDGER(LN .. "Circuits", 900) ~= nil and HARNESS_LEDGER(LN .. "Circuits", 901) == nil
        and Circuits.data().c[900] ~= nil and li.circuits.c[901] ~= nil,
        "線路：舊存檔的線路搬進自己的分片，線路功能讀得到；不是線路格式的留在舊表")
    local C9, fewer = Ledger.circuits, { s = { ["320,300,0,sw_x"] = true }, l = {} }
    C9:put(900, fewer)
    local mirrored = li.circuits.c[900] == fewer
    C9:put(900, { s = { ["320,300,0,sw_x"] = true }, l = { ["320,300,0,kl_x"] = true, ["320,300,0,kl_y"] = true } })
    check(mirrored and li.circuits.c[900] == nil and C9:get(900).l["320,300,0,kl_y"] == true,
        "舊表還在的這一場改線路：成員變少的舊表跟著換；變得比舊檔原本那一條大的從舊表刪掉")
    check(li.lamps.next == top + 6 and li.circuits.next == 901
        and table.concat(HARNESS_GOS_KEYS[LN], ",") == "built,circuits,lamps",
        "主系統記的下一個編號比分片裡已經有的小：往後跳過，不重發；主系統白名單不變")
    local fresh = lampAt(323, 300, "kl_x")
    Ledger.put(fresh, { ["Base.ElectricWire"] = 1 })
    check(fresh.keyId == top + 6 and Ledger.get(fresh)["Base.ElectricWire"] == 1 and li.lamps.e[fresh.keyId].p == "nowhere",
        "新蓋的燈：編號接在分片裡最大的後面，記在分片，不動舊表裡讀不懂的那一筆")
    local landObj = { class = "IsoObject", getSquare = function() return sqAt(321, 300) end,
        getSprite = function() return { getName = function() return STAIR end } end }
    Ledger.put(landObj, {})
    check(Ledger.get(landObj) ~= nil and li.built[landKey] == nil,
        "舊表還在的這一場重記平台：燈與平台這本的舊格式和現在不同，舊表那一筆直接刪掉、不跟著換")
    Ledger.forget(oldLamp)
    check(Ledger.get(oldLamp) == nil and li.lamps.e[top + 5] == nil, "舊表還在的這一場拆掉搬過來的燈：舊表那一筆也刪掉")
    reopen(Ledger)
    check(li.lamps.e[top + 6] ~= nil and count(li.lamps.e) == 1 and li.built[landKey] == nil
        and li.built["322,300,0,kl_old"] ~= nil and li.circuits.c[900] == nil and li.circuits.c[901] ~= nil
        and HARNESS_LEDGER(LN, landKey) ~= nil and Circuits.data().c[900] ~= nil and Ledger.get(fresh) ~= nil,
        "下一次開服：搬過的燈、平台、線路從舊表清掉，分片照樣讀得到；讀不懂的與 0.3.0 以前的燈留著")
    local rep = Store.report()
    check(#rep == 4 and rep[1].id == "floors" and rep[2].id == "overlays" and rep[3].id == "ledger" and rep[4].id == "circuits"
        and rep[4].n == Ledger.circuits:stats().n and rep[3].shards == 1 and rep[3].bytes > 0,
        "四本帳本的筆數、片數、大小照固定順序回報（管理面板）")
    -- 沒有對照表的帳本讀檔：和前面的片同一個鍵的、不是帳本格式的不收
    HARNESS_GOS_SHARDS[LN .. "_2"] = { v = 1, data = { [fresh.keyId] = { p = K(1, 1, 0), s = "kl_dup", i = {} },
        [top + 39] = { p = K(331, 300, 0), s = "kl_z", i = {}, extra = 1 },
        [top + 40] = { p = "text", s = "kl_x", i = {} }, [top + 41] = { p = K(330, 300, 0), s = "kl_y", i = {} } } }
    reopen(Ledger)
    check(HARNESS_LEDGER(LN, fresh.keyId).s == "kl_x" and count(HARNESS_GOS_SHARDS[LN .. "_2"].data) == 1
        and Ledger.get(lampAt(330, 300, "kl_y", top + 41)) ~= nil and li.lamps.next == top + 42 and drift() == "",
        "燈的分片檔裡和前面的片同一個編號的、位置不是數字的：不收；其他筆照讀，下一個編號跳過它")
    -- 同一個鍵改成比較大的值（原位改）、再清掉：大小跟著變
    local land = { class = "IsoObject", getSquare = function() return sqAt(350, 300) end,
        getSprite = function() return { getName = function() return STAIR end } end }
    Ledger.put(land, {})
    Ledger.put(land, { ["Base.Plank"] = 1 })
    local grown = Ledger.get(land) ~= nil and Ledger.get(land)["Base.Plank"] == 1 and drift() == ""
    Ledger.forget(land)
    check(grown and Ledger.get(land) == nil and drift() == "", "平台那一筆原位改大、再清掉：帳本記的大小都跟著變")
    -- 每一片都滿、開不了新的一片時換值：沒有變大的照樣換；變大的不換、原本那一筆不動
    local keepB0, keepH0, keepS0 = Store.SHARD_BYTES, Store.SHARD_HARD, Store.SHARD_SLACK
    local function full(on)
        if on then
            Store.SHARD_BYTES, Store.SHARD_HARD, Store.SHARD_SLACK, HARNESS_GOS_COUNT = 1, 1, 0, 100
            print = function() end
        else
            Store.SHARD_BYTES, Store.SHARD_HARD, Store.SHARD_SLACK, HARNESS_GOS_COUNT = keepB0, keepH0, keepS0, nil
            print = realPrint
        end
    end
    local s3, s4 = sqAt(360, 300), sqAt(361, 300)
    for _, host in ipairs({ s3, s4 }) do
        Overlays.put(host, "ov_h", {})
        Overlays.put(host, "ov_i", { ["Base.Paint"] = 2 })
    end
    Overlays.put(s1, "ov_h", {})
    Overlays.put(s1, "ov_i", { ["Base.Paint"] = 3 })
    local C = Ledger.circuits
    C:put(950, { s = { a = true }, l = {} })
    full(true)
    Overlays.forget(s1, "ov_h") -- 只有這一件用那個組合：拿掉一張之後整體變小
    local strict = Overlays.forget(s3, "ov_h", nil, true) -- 另一件還在用同一個組合：剩下的要多一項對照表，放不下
    local intact = strict == false and Overlays.get(s3, "ov_h") ~= nil and Overlays.get(s3, "ov_i")["Base.Paint"] == 2
    Overlays.forget(s3, "ov_h")
    local grew = C:put(950, { s = { a = true, b = true }, l = {} })
    local kept = C:get(950).s.b == nil
    local shrunk = C:put(950, { s = {}, l = {} })
    full(false)
    check(Overlays.get(s1, "ov_h") == nil and Overlays.get(s1, "ov_i")["Base.Paint"] == 3
        and Overlays.get(s4, "ov_h") ~= nil and Overlays.get(s4, "ov_i")["Base.Paint"] == 2 and drift() == "",
        "片滿時從一件上拿掉一張、整體沒有變大：照樣記得回去，剩下那一張的退料還在；別件不受影響")
    check(intact and Overlays.get(s3, "ov_h") == nil and Overlays.get(s3, "ov_i") == nil,
        "片滿到剩下的那幾張記不回去：拆除用的（strict）回 false、什麼都不動；圖已經不在的（回滾、換牆）整筆清掉，不留一筆已經拆掉的退料")
    check(grew == false and kept and shrunk == true and C:get(950).s.a == nil and drift() == "",
        "線路片滿時換成比較大的值：回 false、存檔裡原本那一條不動；換成比較小的照樣換")
    C:del(950)
    Overlays.forget(s1, "ov_i")
    Overlays.forget(s4, "ov_h")
    Overlays.forget(s4, "ov_i")
    -- 開不了片的伺服器：舊存檔的那一件放不進分片、只在舊表。拿掉一張：剩下的記在舊表、照樣查得到（不整件清掉）；
    -- 比舊檔原本那一件大的不記
    local d1, nOv = sqAt(380, 300), Store.report()[2].n
    oi.overlays["380,300,0"] = { ov_a = { ["Base.Paint"] = 1 }, ov_b = {}, ov_c = {} }
    full(true)
    HARNESS_REOPEN(Overlays)
    local onlyOld = Overlays.get(d1, "ov_a") ~= nil and HARNESS_LEDGER(ON, K(380, 300, 0)) == nil and Store.report()[2].n == nOv + 1
    local okStrict = Overlays.forget(d1, "ov_a", nil, true)
    Overlays.forget(d1, "ov_b")
    Overlays.put(d1, "ov_x", {})
    Overlays.put(d1, "ov_big", { ["Base.Plank"] = 1, ["Base.Nails"] = 2, ["Base.Screws"] = 3, ["Base.Paint"] = 4 })
    full(false)
    check(onlyOld and okStrict == true and Overlays.get(d1, "ov_a") == nil and Overlays.get(d1, "ov_b") == nil
        and Overlays.get(d1, "ov_c") ~= nil and Overlays.get(d1, "ov_x") ~= nil and Overlays.get(d1, "ov_big") == nil
        and oi.overlays["380,300,0"].ov_c ~= nil and oi.overlays["380,300,0"].ov_x ~= nil and oi.overlays["380,300,0"].ov_a == nil
        and Store.report()[2].n == nOv + 1,
        "開不了片時從只在舊表的那一件拿掉一張、換一張：剩下的記在舊表、照樣查得到（拆除用的 strict 也拆得了）；比舊檔原本大的不記；面板的筆數算進這一件")
    reopen(Overlays)
    check(HARNESS_LEDGER(ON, K(380, 300, 0)) ~= nil and Overlays.get(d1, "ov_c") ~= nil and Overlays.get(d1, "ov_x") ~= nil
        and Store.report()[2].n == nOv + 1 and drift() == "", "之後放得下：下一次開服照舊表現在的內容搬進分片")
    Overlays.forget(d1, "ov_c")
    Overlays.forget(d1, "ov_x")
    -- 放不進分片的舊燈：照樣認得，下一個編號也跳過它
    local keepB, keepH = Store.SHARD_BYTES, Store.SHARD_HARD
    Store.SHARD_BYTES, Store.SHARD_HARD, HARNESS_GOS_COUNT = 1, 1, 100
    li.lamps.e[top + 60] = { p = "340,300,0", s = "kl_x", i = {} }
    li.lamps.next = 1
    local land2Key, oldLand = "341,300,0," .. STAIR, {}
    local land2 = { class = "IsoObject", getSquare = function() return sqAt(341, 300) end,
        getSprite = function() return { getName = function() return STAIR end } end }
    li.built[land2Key] = oldLand
    reopen(Ledger)
    print = function() end
    Ledger.put(land2, {})
    print = realPrint
    Store.SHARD_BYTES, Store.SHARD_HARD, HARNESS_GOS_COUNT = keepB, keepH, nil
    check(Ledger.get(lampAt(340, 300, "kl_x", top + 60)) ~= nil and HARNESS_LEDGER(LN, top + 60) == nil
        and li.lamps.e[top + 60] ~= nil and li.lamps.next == top + 61,
        "放不進分片的舊燈（每一片都滿、開不了新的一片）：照樣認得、舊表留著，下一個編號照樣跳過它")
    check(li.built[land2Key] == oldLand and Ledger.get(land2) == oldLand,
        "開不了片時重記只在舊表的平台：燈與平台這本的舊格式和現在不同，不往舊表寫，原本那一筆不動")
    Ledger.forget(land2)
    reopen(Ledger)
    reopen(Ledger)
    check(HARNESS_LEDGER(LN, top + 60) ~= nil and li.lamps.e[top + 60] == nil and drift() == "",
        "之後放得下：補進分片，再下一次開服才清舊表；四本帳本的筆數與大小仍然一致")
    li.built["322,300,0,kl_old"] = nil
    instanceof = realInst
end)()

print("情境五十：管理面板的伺服器紀錄（2026-11-14）：伺服器指令 ledgers 只限速不查權限、Store.report 出錯不丟錯；面板組字與不可信的形狀")
;(function()
    local B = MinidoracatBuilder
    local Store, Admin = B.Store, B.Admin
    local keepStep, realGetText, realSpecific, realIsServer, realIsClient, realSend, realPrint =
        clockStep, getText, getSpecificPlayer, isServer, isClient, sendClientCommand, print
    clockStep = 0
    nowMs = nowMs + 60000
    -- 經 OnClientCommand 送一次：回這次送給 p 的 ledgers 參數與這次總共送出幾則
    local function asked(p)
        local n0, got = #sent, nil
        fire("OnClientCommand", "MinidoracatBuilder", "ledgers", p, {})
        for i = n0 + 1, #sent do
            if sent[i].player == p and sent[i].cmd == "ledgers" then got = sent[i].args end
        end
        return got, #sent - n0
    end
    local admin, plain = player({ id = 5001, admin = true }), player({ id = 5002, name = "plain" })
    local want, a1 = Store.report(), asked(admin)
    local same = a1 ~= nil and type(a1.list) == "table" and #a1.list == #want
    for i = 1, #want do
        local x, y = want[i], same and a1.list[i] or {}
        same = same and x.id == y.id and x.n == y.n and x.shards == y.shards and x.bytes == y.bytes
    end
    check(#want == 4 and same, "管理員：拿到四本帳本，id、筆數、檔數、大小和 Store.report() 一樣")
    local p1 = asked(plain)
    check(p1 ~= nil and #p1.list == 4,
        "沒有沙盒權限的玩家也拿得到（只有筆數與大小；合作模式主機伺服器端認不出來，所以不查權限）")
    local a2, n2 = asked(admin)
    nowMs = nowMs + 1001
    local a3 = asked(admin)
    check(a2 == nil and n2 == 0 and a3 ~= nil, "每人一秒一次：限速內第二次不回，過了一秒照回")
    nowMs = nowMs - 3600000
    local a4 = asked(admin)
    nowMs = nowMs + 3600000 + 1001
    check(a4 ~= nil, "時鐘往回調一小時：不會被限速卡住")
    -- Store.report 丟錯、不是表、沒有這個函式、整個 Store 不在：回空陣列，不往上丟
    local logs, realReport, results = {}, Store.report, {}
    print = function(s) logs[#logs + 1] = tostring(s) end
    for _, case in ipairs({ function() Store.report = function() error("boom") end end,
        function() Store.report = function() return "x" end end,
        function() Store.report = nil end,
        function() Store.report = realReport; B.Store = nil end }) do
        case()
        nowMs = nowMs + 1001
        local ok, r = pcall(asked, admin)
        results[#results + 1] = ok and r ~= nil and type(r.list) == "table" and #r.list == 0
    end
    B.Store, Store.report, print = Store, realReport, realPrint
    local failedLog = 0
    for _, s in ipairs(logs) do if s:find("ledger report failed", 1, true) then failedLog = failedLog + 1 end end
    check(results[1] and results[2] and results[3] and results[4] and failedLog == 3,
        "Store.report 丟錯、回的不是表、函式不在、Store 不在：都回空陣列不丟錯；Store 在時記一行 log")

    -- 面板組字：大小 KB／MB、跳過形狀不對的項目（getText 換成看得出鍵與參數的版本）
    getText = function(k, ...)
        local a = { ... }
        if #a == 0 then return k end
        return k .. "(" .. table.concat(a, ",") .. ")"
    end
    local function row(id, n, f, size) return "IGUI_MBLD_Admin_LedgerRow(IGUI_MBLD_Admin_Ledger_" .. id .. "," .. n .. "," .. f .. "," .. size .. ")" end
    local lines = Admin.ledgerLines({
        { id = "floors", n = 29568, shards = 1, bytes = 524288 },
        "junk", 7, { id = "nope", n = 1, shards = 1, bytes = 1 }, { id = "floors" }, { id = {}, n = 1, shards = 1, bytes = 1 },
        { id = "ledger", n = "x", shards = 1, bytes = 1 }, { id = "ledger", n = -1, shards = 1, bytes = 1 },
        { id = "ledger", n = 0 / 0, shards = 1, bytes = 1 }, { id = "circuits", n = 1, shards = 1, bytes = 1e15 },
        { id = "overlays", n = 3.0, shards = 2, bytes = 1048576 },
        { id = "ledger", n = 0, shards = 1, bytes = 1023 },
        { id = "circuits", n = 7, shards = 3, bytes = 5 * 1048576 + 104857 } })
    check(#lines == 4 and lines[1] == row("floors", 29568, 1, "512 KB") and lines[2] == row("overlays", 3, 2, "1.0 MB")
        and lines[3] == row("ledger", 0, 1, "1 KB") and lines[4] == row("circuits", 7, 3, "5.1 MB")
        and Admin.sizeText(0) == "0 KB" and Admin.sizeText(1048575) == "1024 KB",
        "每本一行：不到 1 MB 用整數 KB（進位，空的才是 0 KB）、以上一位小數 MB；缺欄位、不是數字、負數、NaN、太大、id 不認得或不是字串的都跳過")
    check(#Admin.ledgerLines(nil) == 0 and #Admin.ledgerLines("x") == 0 and #Admin.ledgerLines({ "a", 5 }) == 0,
        "list 不是表或項目不是表：空的，不丟錯")
    -- 狀態：單機當場回、兩次至少隔 3 秒；多人送指令、5 秒沒回改說沒有回報、回了空的也說沒有回報
    local cmds = {}
    getSpecificPlayer = function() return admin end
    isServer = function() return false end
    Admin.ledger.asked, Admin.ledger.rows = nil, nil
    local s0 = Admin.ledgerState(nowMs)
    local okAsk = Admin.askLedgers(0)
    local again = Admin.askLedgers(0)
    check(s0 == "none" and okAsk == true and again == false and Admin.ledgerState(nowMs) == "rows" and #Admin.ledger.rows == 4,
        "單機：面板一要就經 Client 交給 Admin、四行；3 秒內再要不送")
    isServer, isClient = realIsServer, function() return true end
    sendClientCommand = function(p, module, cmd, args) cmds[#cmds + 1] = { p = p, module = module, cmd = cmd } end
    Admin.ledger.asked, Admin.ledger.rows = nil, nil
    Admin.askLedgers(0)
    local sWait = Admin.ledgerState(nowMs)
    nowMs = nowMs + Admin.LEDGER_WAIT_MS
    local sLate = Admin.ledgerState(nowMs)
    Admin.onLedgers({ list = { { id = "nope" } } })
    local sEmpty = Admin.ledgerState(nowMs)
    Admin.onLedgers("garbage")
    check(#cmds == 1 and cmds[1].p == admin and cmds[1].module == "MinidoracatBuilder" and cmds[1].cmd == "ledgers"
        and sWait == "wait" and sLate == "none" and sEmpty == "none" and Admin.ledgerState(nowMs) == "none",
        "多人：送 ledgers 指令、等的時候讀取中、5 秒沒回改說沒有回報；回的內容認不得或不是表也說沒有回報、不丟錯")
    Admin.onLedgers({ list = { { id = "floors", n = 1, shards = 1, bytes = 1 } } })
    local sGot = Admin.ledgerState(nowMs)
    nowMs = nowMs + Admin.LEDGER_GAP_MS
    Admin.askLedgers(0)
    local sKeep = Admin.ledgerState(nowMs + 1)
    local sStale = Admin.ledgerState(nowMs + Admin.LEDGER_WAIT_MS)
    Admin.onLedgers({ list = { { id = "floors", n = 2, shards = 1, bytes = 1 } } })
    check(#cmds == 2 and sGot == "rows" and sKeep == "rows" and sStale == "none"
        and Admin.ledgerState(nowMs + Admin.LEDGER_WAIT_MS) == "rows",
        "收過一次之後再要：等的時候先畫上一次的；5 秒沒回改說沒有回報（不把上一次的當成現在的）；回了再畫")
    Admin.ledger.asked, Admin.ledger.rows = nil, nil
    getText, getSpecificPlayer, isClient, sendClientCommand, clockStep = realGetText, realSpecific, realIsClient, realSend, keepStep
end)()

print("情境五十一：柵欄門不用門框（2026-11-14 Workshop 回饋）：一般的門照舊要門框；柵欄門那條邊空著就能蓋")
;(function()
    local Place, Check = MinidoracatBuilder.Place, MinidoracatBuilder.Check
    local EW = GridSquareEdgeFacingDirection.EAST_WEST
    local function door(name, id, flags, keys) return sprite(name, id, { flags = flags, keys = keys }) end
    local gate = door("fg_gate_01_0", 9501, { "doorW" }, { CustomName = "Fence gate" })
    local hop = door("fg_hop_01_0", 9503, { "doorW", "HoppableW" }, {})      -- 沒有名稱、能翻過去
    local railing = door("fg_rail_01_0", 9505, { "doorW" }, { CustomName = "Railing Gate" })
    local plain = door("fg_door_01_0", 9507, { "doorW" }, { CustomName = "Door" })
    local lone = door("fg_lone_01_0", 9509, { "doorW" }, { CustomName = "Fence gate" }) -- 沒有 +2 的開門圖
    local old = IsoSpriteManager.instance:getNamedMap():values()._raw
    local list = {}
    for i, s in ipairs(old) do list[i] = s end
    for _, s in ipairs({ gate, hop, railing, plain, lone }) do list[#list + 1] = s end
    for i, n in ipairs({ "fg_gate_01_2", "fg_hop_01_2", "fg_rail_01_2", "fg_door_01_2" }) do
        list[#list + 1] = door(n, 9510 + i, { "doorW", "open" }, {})
    end
    world(list)
    check(Rules.gate(gate:getProperties()) and Rules.gate(hop:getProperties()) and Rules.gate(railing:getProperties())
        and not Rules.gate(plain:getProperties()), "Rules.gate：名稱帶 gate（不分大小寫）或能翻過去的門；一般的門不算")

    local empty = square(230, 230, 0)
    local framed = square(231, 230, 0, { flags = { DoorWallW = true, cutW = true } })
    local fenced = square(232, 230, 0, { flags = { HoppableW = true, collideW = true } })
    local taken = square(233, 230, 0, { doors = { [EW] = {} } })
    local full = square(234, 230, 0, { flags = { DoorWallW = true, cutW = true }, doors = { [EW] = {} } })
    check(not Place.check("door", plain, empty) and Place.check("door", plain, framed) == true and not Place.check("door", plain, full),
        "一般的門照舊：沒有門框不能放，有門框、還沒有門才能放")
    check(Place.check("door", gate, empty) == true and Place.check("door", hop, empty) == true
        and Place.check("door", railing, empty) == true and Place.check("door", gate, framed) == true,
        "柵欄門：空著的邊可蓋，放進門框也照舊可以")
    check(not Place.check("door", gate, fenced) and not Place.check("door", gate, taken) and not Place.check("door", gate, full)
        and not Place.check("door", gate, square(235, 230, 1)) and not Place.check("door", gate, square(236, 230, 0, { stairs = true }))
        and not Place.check("door", lone, empty),
        "柵欄門照一般格邊：那條邊有柵欄、有門、門框裡已有門、樓上腳下沒有地板、格上有樓梯都擋；沒有開門圖的不蓋")
    -- 沒有門框的柵欄門照樣過樓梯出入口與多格家具兩關（審查 1114 Codex）：格上沒有樓梯，只有某一條邊被原版判成出入口
    local gateN = door("fg_gaten_01_1", 9520, { "doorN" }, { CustomName = "Fence gate" })
    list[#list + 1], list[#list + 2] = gateN, door("fg_gaten_01_3", 9522, { "doorN", "open" }, {})
    world(list)
    local realStair = buildUtil.stairIsBlockingPlacement
    local function exits(blockNorth)
        buildUtil.stairIsBlockingPlacement = function(_, _, north) return north == blockNorth end
        local w, n = Place.check("door", gate, square(237, 230, 0)), Place.check("door", gateN, square(237, 230, 0))
        buildUtil.stairIsBlockingPlacement = realStair
        return w == true, n == true
    end
    local wOnN, nOnN = exits(true)
    local wOnW, nOnW = exits(false)
    check(wOnN and not nOnN and not wOnW and nOnW, "柵欄門不擋樓梯出入口：照門佔的邊查（朝北的查北邊、朝西的查西邊）")
    local function cut(px, py) -- 格上有多格家具的一片，它在整組裡的位置是 (px, py)
        local sq = square(238, 230, 0)
        local piece = sprite("fg_sofa_01_1", 9521, {})
        piece.grid = { getSpriteGridPosX = function() return px end, getSpriteGridPosY = function() return py end }
        sq.objects[1] = { getSprite = function() return piece end, getProperties = function() return piece:getProperties() end }
        return sq
    end
    check(not Place.check("door", gate, cut(1, 0)) and Place.check("door", gate, cut(0, 1)) == true
        and not Place.check("door", gateN, cut(0, 1)) and Place.check("door", gateN, cut(1, 0)) == true,
        "柵欄門不切開多格家具：朝西的擋 x > 0 的片、朝北的擋 y > 0 的片")
    -- 沒有名稱、也翻不過去的門（圖塊包的一般門常這樣）：不算柵欄門、不丟錯，照舊要門框（審查 1114 Claude）
    local bare = door("fg_bare_01_0", 9523, { "doorW" }, {})
    list[#list + 1], list[#list + 2] = bare, door("fg_bare_01_2", 9524, { "doorW", "open" }, {})
    world(list)
    check(Rules.gate(bare:getProperties()) == false and not Place.check("door", bare, empty)
        and Place.check("door", bare, framed) == true, "沒有名稱的門：不算柵欄門，沒有門框不能放、有門框能放")
    -- 蓋：沒有門框時照牆插在最後一個地板後面、家具前面（原版 door.OnCreate 找不到門框的那條路，buildRecipeCode.lua:646-658）
    local realDoor = IsoDoor
    IsoDoor = { new = function(_, sq, name, north)
        local d = { name = name, north = north, md = {} }
        function d:getModData() return self.md end
        function d:setHealth() end
        function d:setExplored() end
        function d:transmitCompleteItemToClients() end
        function d:getContainerCount() return 0 end
        function d:getSquare() return sq end
        function d:getSprite() return spriteMap[name] end
        function d:getProperties() return spriteMap[name]:getProperties() end
        function d:getType() return T.normal end
        return d
    end, getGarageDoorIndex = function() return -1 end, getDoubleDoorIndex = function() return -1 end }
    local function obj(spr) return { getProperties = function() return spr:getProperties() end,
        getType = function() return spr:getType() end, getSprite = function() return spr end } end
    local FL = obj(sprite("fg_floor_01_0", 9525, { flags = { "solidfloor" } }))
    local CH = obj(sprite("fg_chair_01_0", 9526, { keys = { IsMoveAble = "" } }))
    local orderSq = square(239, 230, 0)
    orderSq.objects = { FL, CH }
    local okBuild = pcall(Place.build, "door", { { sq = orderSq, spr = gate, cost = {} } }, {})
    IsoDoor = realDoor
    check(okBuild and orderSq.objects[1] == FL and orderSq.objects[2] and orderSq.objects[2].name == "fg_gate_01_0"
        and orderSq.objects[2].north == false and orderSq.objects[3] == CH, "蓋沒有門框的柵欄門：建 IsoDoor，插在地板後、家具前")

    local K = player({ id = 510, x = 230.5, y = 231.5, here = square(230, 231, 0) })
    local function both(name, x)
        local a = Check.item(K, name, 0, { x, 230, 0 }, { preview = true })
        local b = Check.item(K, name, 0, { x, 230, 0 })
        return a == b and (a or "ok")
    end
    check(both("fg_gate_01_0", 230) == "ok" and both("fg_gate_01_0", 232) == "BLOCKED"
        and both("fg_door_01_0", 230) == "BLOCKED" and both("fg_door_01_0", 231) == "ok",
        "Check.item：預覽與伺服器同一個結果（柵欄門空邊可蓋、有柵欄擋；一般的門要門框）")
    world(old)
end)()

-- ===== 排程與轉向（Queue、Turn）=====
print("情境（排程與轉向）：再拖一排接在後面、超過上限分批、停下全部取消、照圖蓋讓手拖、復原剛蓋的")
;(function()
    local B = MinidoracatBuilder
    local Q, C, Cur, Messages, E = B.Queue, B.Client, B.Cursor, B.Messages, B.Entry
    local real = { build = C.build, toast = Messages.toast, get = Cur.get, q = ISTimedActionQueue, max = sb.MaxCellsPerDrag,
        dm = C.dismantleMany, text = getText, cell = getCell, resolve = E.resolve, face = E.face, cells = E.cells,
        alt = E.alternate, north = E.north }
    local busy, sent, toasts, nonce, cleared = false, {}, {}, 7000, 0
    getText = function(k, ...)
        local a = { ... }
        return #a == 0 and k or k .. "(" .. table.concat(a, ",") .. ")"
    end
    Messages.toast = function(_, text) toasts[#toasts + 1] = text end
    Cur.get = function() return nil end
    ISTimedActionQueue = { isPlayerDoingAction = function() return busy end, clear = function() cleared = cleared + 1 end }
    C.build = function(p, name, cells)
        nonce = nonce + 1
        sent[#sent + 1] = { n = nonce, count = #cells, name = name, first = cells[1] }
        C.pending = { n = nonce, cells = cells, player = p }
        return nonce
    end
    local moving, esc, dragOpen = false, false, nil
    local P = { getPlayerNum = function() return 3 end, pressedMovement = function() return moving end,
        pressedCancelAction = function() return esc end }
    getCell = function()
        local c = real.cell()
        c.getDrag = function() return dragOpen end
        return c
    end
    local function cells(k, x0)
        local t = {}
        for i = 1, k do t[i] = { (x0 or 0) + i, 0, 0, 0 } end
        return t
    end
    local function placeAll()
        local s = sent[#sent]
        Q.onResult("accepted", { n = s.n })
        for i = 1, s.count do Q.onResult("placed", { n = s.n, i = i }) end
    end
    local function stall() -- 收下後動作佇列空了 1.5 秒以上＝停下
        Q.tick()
        nowMs = nowMs + 2000
        Q.tick()
    end
    sb.MaxCellsPerDrag = 32

    local _, n1 = Q.push(P, "a_01_0", cells(3))
    local _, n2 = Q.push(P, "b_01_0", cells(2, 10))
    check(n1 ~= nil and n2 == nil and #sent == 1 and Q.busy(P) == 2 and Q.left(P) == 5 and Cur.left(P) == 5,
        "排程：前一排還在蓋時再拖一排，接在後面、先不送")
    placeAll()
    busy = true
    Q.tick()
    check(#sent == 1 and Q.left(P) == 2, "排程：前一排蓋好但角色的動作還沒做完：下一排不送")
    busy = false
    Q.tick()
    check(#sent == 2 and sent[2].name == "b_01_0", "排程：動作佇列空了才送下一排")
    placeAll()
    Q.tick()
    check(Q.busy(P) == 0 and #toasts == 0 and Q.queued() == nil, "排程：兩排都蓋好：佇列清空、不通知")

    local _, n3 = Q.push(P, "a_01_0", cells(4))
    Q.push(P, "b_01_0", cells(4, 20))
    Q.onResult("accepted", { n = n3 })
    Q.onResult("placed", { n = n3, i = 1 })
    stall()
    check(Q.busy(P) == 0 and #sent == 3 and #toasts == 1 and toasts[1] == "IGUI_MBLD_Stopped(1,4)",
        "排程：前一排停下（走開、Esc）：後面排著的一起取消，只通知停下的那一排一次")

    toasts = {}
    local sum
    local _, np = Q.push(P, "a_01_0", cells(5), nil, nil, { owner = "plan", onDone = function(s) sum = s end })
    Q.onResult("accepted", { n = np })
    Q.onResult("placed", { n = np, i = 1 })
    Q.onResult("placed", { n = np, i = 2 })
    Q.onResult("refused", { n = np, code = "BLOCKED", x = 3 })
    check(sum and sum.owner == "plan" and sum.placed == 2 and sum.count == 5 and sum.stopped and sum.refused == "BLOCKED"
        and Q.busy(P) == 0 and #toasts == 0, "照圖蓋：被拒時 onDone 收到蓋好幾格與拒絕碼，不跳通知")
    sum = nil
    Q.push(P, "a_01_0", cells(3), nil, nil, { owner = "plan", onDone = function(s) sum = s end })
    local c0 = cleared
    local _, nd = Q.push(P, "b_01_0", cells(2))
    check(sum and sum.stopped and sum.placed == 0 and nd ~= nil and cleared == c0 + 1 and Q.busy(P) == 1,
        "照圖蓋：玩家手拖一排時先取消照圖蓋的（onDone 收到停下），手拖的立刻送")
    placeAll()
    Q.tick()

    local before = #sent
    Q.push(P, "a_01_0", cells(70))
    check(#sent == before + 1 and sent[#sent].count == 32 and Q.busy(P) == 3 and Q.left(P) == 70,
        "分批：上限 32 拖 70 格切成 3 筆，先送 32 格")
    placeAll()
    Q.tick()
    check(sent[#sent].count == 32 and sent[#sent].first[1] == 33, "分批：第二筆從第 33 格接著送")
    placeAll()
    Q.tick()
    check(sent[#sent].count == 6 and sent[#sent].first[1] == 65, "分批：第三筆剩 6 格")
    Q.onResult("accepted", { n = sent[#sent].n })
    Q.onResult("placed", { n = sent[#sent].n, i = 1 })
    stall()
    check(toasts[1] == "IGUI_MBLD_Stopped(65,70)", "分批：停下時照整排報蓋好幾格（65／70），不是只報最後一筆")

    -- 復原（審查 C4／K1）：40 片、上限 32：分兩筆拆（32、8），每筆都過伺服器的件數上限（真的 Server.dismantleIntent），
    -- 上一筆輪完才送下一筆
    local spr = { getName = function() return "u_01_0" end }
    E.resolve = function() return { name = "u_01_0", kind = "wall", spr = spr } end
    E.face = function() return spr end
    E.cells = function() return { { 0, 0, 0, spr } } end
    E.alternate = function(s) return s end
    E.north = function() return true end
    local P2 = player({ name = "qt_undo", cheat = true, x = 720.5, y = 700.5 })
    function P2:getPlayerNum() return 3 end
    P2.pressedMovement, P2.pressedCancelAction = P.pressedMovement, P.pressedCancelAction
    local function buildAll(name, list)
        Q.push(P2, name, list)
        for _ = 1, 10 do
            if Q.busy(P2) == 0 then break end
            placeAll()
            Q.tick()
        end
    end
    local far = {}
    for i = 1, 40 do far[i] = { 700 + i, 700, 0, 0 } end
    buildAll("u_01_0", far)
    local realDI, sizes = B.Server.dismantleIntent, {}
    B.Server.dismantleIntent = function(p, args)
        sizes[#sizes + 1] = #args.t / 4
        return realDI(p, args)
    end
    local realIsServer = isServer
    isServer = function() return false end
    C.dismantleMany = real.dm
    ISTimedActionQueue.add = function() end
    local function finishUnbuild() -- 伺服器照清單一件一件回「拆好了」
        local b = C.pendingUnbuild
        for i = 1, #b.list do
            C.onServerCommand("dismantled", { n = b.n, i = i, x = b.list[i].x, y = b.list[i].y, z = 0, refund = {} })
        end
    end
    toasts = {}
    local k40 = Q.undoLast(P2)
    local first = C.pendingUnbuild
    check(k40 == 40 and #sizes == 1 and sizes[1] == 32 and first and #first.list == 32 and first.list[1].x == 740,
        "復原：40 片、上限 32：先送後蓋的 32 件，伺服器收下（不是整筆 BAD_REQUEST）")
    finishUnbuild()
    local between = C.pendingUnbuild == nil and #sizes == 1
    Q.tick()
    local second = C.pendingUnbuild
    check(between and #sizes == 2 and sizes[2] == 8 and second and second ~= first and second.list[8].x == 701 and #toasts == 0,
        "復原：上一筆輪完、下一個 tick 才送下一筆（剩 8 件），中間不通知")
    finishUnbuild()
    check(C.pendingUnbuild == nil and #toasts == 1 and toasts[1]:find("UnbuildSummary_Many(40", 1, true) ~= nil
        and Q.last(P2) == nil, "復原：兩筆都輪完：跳一則總結（拆了 40 件），紀錄清掉")
    -- 停下（玩家走開）：沒拆到的留在紀錄裡，再按一次接著拆
    buildAll("u_01_0", { { 731, 700, 0, 0 }, { 732, 700, 0, 0 }, { 733, 700, 0, 0 } })
    toasts = {}
    Q.undoLast(P2)
    C.tickUnbuild()
    nowMs = nowMs + 2000
    C.tickUnbuild()
    local kept = Q.last(P2)
    check(kept and #kept == 3 and C.pendingUnbuild == nil and toasts[1] and toasts[1]:find("IGUI_MBLD_Undo_Again", 1, true) ~= nil,
        "復原：停下時沒拆到的留在紀錄裡（格子沒載入、看不出來的也留），通知說再按一次接著拆")
    isServer, B.Server.dismantleIntent = realIsServer, realDI

    -- 復原照原本的拆法分流（審查 C6／K2）、認得是不是當初那件（C5）：載入中的格子放假物件
    local Area, Dis = B.Area, B.Dismantle
    local realRoute, realPlan = Area.route, Dis.plan
    Area.route = function(o) return o.route, o.kind end
    Dis.plan = function(o) return { remove = { o } } end
    local sqs, objs = {}, {}
    local function fakeObj(sq, route)
        local o = { route = route, kind = "wall" }
        function o:getSprite() return spr end
        function o:getSquare() return sq end
        sq.objects[#sq.objects + 1] = o
        return o
    end
    local routes = { "builder", "scrap", "pickup", "none", "builder", "builder" }
    local six = {}
    for i = 1, 6 do
        sqs[i] = getCell():getGridSquare(40 + i, 59, 0)
        sqs[i].objects = {}
        objs[i] = fakeObj(sqs[i], routes[i])
        six[i] = { 40 + i, 59, 0, 0 }
    end
    buildAll("u_01_0", six)
    sqs[5].objects = {} -- 別人拆掉第 5 片、在同一格重蓋同一張圖
    fakeObj(sqs[5], "builder")
    sqs[6].objects = {} -- 第 6 片被拆掉了
    local got, gotDone
    C.dismantleMany = function(_, items, onDone) got, gotDone = items, onDone end
    toasts = {}
    local kr = Q.undoLast(P2)
    check(kr == 5 and got and #got == 2 and got[1].route == "scrap" and got[1].obj == objs[2] and got[2].route == "builder"
        and got[2].x == 41 and got[2].obj == objs[1] and #got[2].own == 1,
        "復原：照原本的拆法分流：本工具拆的、原版拆解的送去拆（帶物件），能搬的、只能砸的不送")
    gotDone({ done = 2, total = 2, skipped = {}, refund = {}, stopped = false, res = { [got[1]] = true, [got[2]] = true } })
    local t = toasts[1] or ""
    check(#toasts == 1 and t:find("IGUI_MBLD_Undo_Manual(1,IGUI_MBLD_Refund_pickup)", 1, true) ~= nil
        and t:find("IGUI_MBLD_Undo_Manual(1,IGUI_MBLD_Refund_none)", 1, true) ~= nil and Q.last(P2) == nil,
        "復原：不送的說要用原版哪個動作（重用拆除方式的說明）")
    local x5 = false
    for _, it in ipairs(got) do if it.x == 45 or it.x == 46 then x5 = true end end
    check(not x5 and t:find("UnbuildShort_GONE,1", 1, true) ~= nil and t:find("UnbuildSummary_Many(2", 1, true) ~= nil,
        "復原：當初那件被別人拆掉、同一格重蓋同圖的不拆（說已經不在）；單純不在的不提")
    for i = 1, 6 do sqs[i].objects = {} end
    Area.route, Dis.plan, C.dismantleMany = realRoute, realPlan, real.dm
    check(Q.undoLast(P2) == 0, "復原：沒有可復原的回 0")

    -- 下一筆由 tick 送（審查 Q4）：上限 1、200 件都當場跳過（完成回呼是同步的）也不巢狀；缺工具的都留著（Q2）
    local many = {}
    for i = 1, 200 do many[i] = { 500 + i, 900, 0, 0 } end
    buildAll("u_01_0", many)
    sb.MaxCellsPerDrag = 1
    local depth, maxDepth, calls, reply = 0, 0, 0, nil
    C.dismantleMany = function(_, items, onDone)
        calls = calls + 1
        depth = depth + 1
        if depth > maxDepth then maxDepth = depth end
        onDone(reply(items))
        depth = depth - 1
    end
    reply = function(items)
        local res = {}
        for _, it in ipairs(items) do res[it] = "NO_TOOL" end
        return { done = 0, total = #items, skipped = { NO_TOOL = #items }, refund = {}, stopped = false, res = res }
    end
    toasts = {}
    Q.undoLast(P2)
    for _ = 1, 250 do Q.tick() end
    check(calls == 200 and maxDepth == 1 and #toasts == 1 and toasts[1]:find("UnbuildShort_NO_TOOL,200", 1, true) ~= nil
        and toasts[1]:find("IGUI_MBLD_Undo_Again", 1, true) ~= nil and Q.last(P2) and #Q.last(P2) == 200,
        "復原：上限 1、200 件都當場跳過：一個 tick 送一筆、回呼不巢狀；拆不了的留在紀錄裡，說再按一次接著拆")
    -- 拆到一半整筆被拒、原因再按也一樣（審查 Q5）：沒拆到的照樣留著，但不說再按一次
    reply = function(items)
        return { done = 1, total = #items, skipped = {}, refund = {}, stopped = true, refused = "NOT_ALLOWED",
            res = { [items[1]] = true } }
    end
    toasts = {}
    Q.undoLast(P2)
    check(#Q.last(P2) == 199 and #toasts == 1 and toasts[1]:find("IGUI_MBLD_Undo_Again", 1, true) == nil,
        "復原：拆到一半被拒、原因再按也一樣（只限管理員）：沒拆到的留著，不說再按一次")
    reply = function(items)
        local res = {}
        for _, it in ipairs(items) do res[it] = true end
        return { done = #items, total = #items, skipped = {}, refund = {}, stopped = false, res = res }
    end
    Q.undoLast(P2)
    for _ = 1, 250 do Q.tick() end
    check(Q.last(P2) == nil and Q.undoLast(P2) == 0, "復原：全部拆完才清紀錄，再按回 0")
    sb.MaxCellsPerDrag = 32

    -- 掛在地板上的圖（審查 Q1）：真的掛（Place.attach）、真的拆（Server.dismantle）。缺工具時紀錄留著，補了再按拆得掉（Q2）
    local oldMap, oldOrder, realInst, realLu = spriteMap, spriteOrder, instanceof, luautils
    instanceof = function(o, cls) return type(o) == "table" and o.class ~= nil and (o.class == cls or cls == "IsoObject") end
    luautils = { walkAdj = function() return true end, walkAdjWall = function() return true end }
    local qFloor = sprite("qtfloor_01_0", 3901, { flags = { "solidfloor" } })
    local qLine = sprite("qtlines_01_0", 3902, { flags = { "FloorOverlay" } })
    local qWin = sprite("walls_qtwin_01_96", 3903, { type = T.wall, flags = { "collideW", "windowW", "cutW", "WindowW" },
        keys = { WindowW = "WindowW" } })
    world({ qFloor, qLine, qWin })
    E.resolve, E.face, E.cells, E.alternate, E.north = real.resolve, real.face, real.cells, real.alt, real.north
    local fo = {}
    local G = square(52, 57, 0, fo)
    local fl = { class = "IsoObject", att = {}, md = {} } -- 同情境二十六的假地板
    function fl:getSprite() return qFloor end
    function fl:getSquare() return G end
    function fl:getAttachedAnimSprite() return javaList(self.att) end
    function fl:addAttachedAnimSprite(s) self.att[#self.att + 1] = { getParentSprite = function() return s end } end
    function fl:RemoveAttachedAnim(i) table.remove(self.att, i + 1) end
    function fl:hasModData() return next(self.md) ~= nil end
    function fl:getModData() return self.md end
    function fl:transmitUpdatedSpriteToClients() end
    function fl:transmitModData() end
    fo.floor = fl
    local here = square(52, 58, 0)
    here.dropped = {}
    function here:AddWorldInventoryItem(ft) self.dropped[ft] = (self.dropped[ft] or 0) + 1 end
    local Pv = player({ id = 3901, name = "qt_ov", x = 52.5, y = 58.5, here = here })
    Pv.pressedMovement, Pv.pressedCancelAction = P.pressedMovement, P.pressedCancelAction
    local qHammer = item("Base.Hammer", { HAMMER = true })
    Pv.inv:add(qHammer)
    give(Pv, Cost.of("floorOverlay", qLine, 1).items)
    Q.push(Pv, "qtlines_01_0", { { 52, 57, 0, 0 } })
    local okOv = build(Pv, 3901, "qtlines_01_0", { 52, 57, 0 })
    placeAll()
    local ovRec = Q.last(Pv)
    check(okOv and #fl.att == 1 and ovRec and ovRec[1].host == fl, "復原：掛上去的圖蓋好時記下宿主（那格地板）")
    local realIsServer2 = isServer
    isServer = function() return false end
    C.dismantleMany = real.dm
    ISTimedActionQueue.add = function() end
    local function runActs() -- 伺服器照排好的動作一件一件拆（同 MinidoracatBuilderDismantleAction:complete）
        local b = C.pendingUnbuild
        for i = 1, #b.list do Server.dismantle(Pv, b.n, i) end
    end
    Pv.inv:Remove(qHammer)
    toasts = {}
    local k1 = Q.undoLast(Pv)
    runActs()
    check(k1 == 1 and #fl.att == 1 and Q.last(Pv) and #Q.last(Pv) == 1 and toasts[1]
        and toasts[1]:find("IGUI_MBLD_Undo_Again", 1, true) ~= nil,
        "復原掛著的圖：缺工具拆不了，紀錄留著、說再按一次接著拆")
    Pv.inv:add(qHammer)
    toasts = {}
    local k2 = Q.undoLast(Pv)
    runActs()
    local back = 0
    for _, n in pairs(here.dropped) do back = back + n end
    check(k2 == 1 and #fl.att == 0 and G:getFloor() == fl and back > 0 and Q.last(Pv) == nil and Q.undoLast(Pv) == 0,
        "復原掛著的圖：補了工具再按：圖拿掉、地板還在、退料，紀錄清掉、再按回 0（只退一次）")
    isServer = realIsServer2

    -- 本工具蓋的窗（審查 Q3）：真的蓋（Place.build 建 IsoWindow）、真的 Area.route：說要用原版哪個動作，不說不是本 MOD 蓋的
    local realWindow = IsoWindow
    IsoWindow = { new = function(_, sq, s, north)
        local o = { class = "IsoWindow", sq = sq, north = north }
        function o:setIsLocked() end
        function o:setExplored() end
        function o:transmitCompleteItemToClients() end
        function o:getContainerCount() return 0 end
        function o:getProperties() return s:getProperties() end
        function o:getSprite() return s end
        function o:getSquare() return sq end
        function o:hasModData() return false end
        return o
    end }
    local Wsq = square(53, 57, 0, { flags = {} })
    Q.push(Pv, "walls_qtwin_01_96", { { 53, 57, 0, 0 } })
    B.Place.build("window", { { sq = Wsq, spr = qWin, cost = { items = {} } } }, {})
    IsoWindow = realWindow
    placeAll()
    local winRec, nSent = Q.last(Pv), 0
    C.dismantleMany = function() nSent = nSent + 1 end
    toasts = {}
    local kw = Q.undoLast(Pv)
    check(winRec and winRec[1].obj ~= nil and kw == 1 and nSent == 0 and toasts[1]
        and toasts[1]:find("IGUI_MBLD_Undo_Manual(1,IGUI_MBLD_Refund_none)", 1, true) ~= nil
        and toasts[1]:find("NOT_OURS", 1, true) == nil, "復原剛蓋的窗：不送去拆，說要用原版哪個動作（不說不是建造工坊蓋的）")
    spriteMap, spriteOrder, instanceof, luautils = oldMap, oldOrder, realInst, realLu
    squares["52,57,0"], squares["52,58,0"], squares["53,57,0"] = nil, nil, nil
    C.dismantleMany = real.dm
    E.resolve = function() return { name = "u_01_0", kind = "wall", spr = spr } end
    E.face = function() return spr end
    E.cells = function() return { { 0, 0, 0, spr } } end
    E.alternate = function(s) return s end
    E.north = function() return true end

    -- 兩筆之間按 Esc（審查 C7）：上一筆最後一格蓋好、下一筆還沒送時取消動作，下一筆不送
    toasts = {}
    local b0 = #sent
    Q.push(P2, "a_01_0", cells(40, 100))
    placeAll()
    esc = true
    Q.tick()
    esc = false
    check(#sent == b0 + 1 and Q.busy(P2) == 0 and toasts[1] == "IGUI_MBLD_Stopped(32,40)",
        "批次交界：下一筆還沒送時按 Esc：不送，說停了 32／40")
    Q.push(P2, "a_01_0", cells(40, 100))
    placeAll()
    esc, dragOpen = true, {}
    Q.tick()
    esc, dragOpen = false, nil
    check(#sent == b0 + 3 and Q.busy(P2) == 1, "批次交界：游標開著時按 Esc 是收游標（同原版），下一筆照送")
    placeAll()
    moving = true
    Q.tick()
    moving = false
    Q.push(P2, "a_01_0", cells(40, 100))
    placeAll()
    moving = true
    Q.tick()
    moving = false
    check(#sent == b0 + 4 and Q.busy(P2) == 0, "批次交界：按方向鍵走開也算取消，下一筆不送")
    Q.cancel(P2)

    -- 放開前提示只算手拖的（審查 K3）、空的一組當場結束（建議）
    Q.push(P, "a_01_0", cells(3))
    Q.push(P, "b_01_0", cells(5), nil, nil, { owner = "plan" })
    check(Q.left(P, "drag") == 3 and Q.left(P, "plan") == 5 and Q.left(P) == 8,
        "排程：還沒蓋好的格數分得出手拖的與照圖蓋的")
    local emptyDone
    Q.push(P, "c_01_0", {}, nil, nil, { owner = "plan", onDone = function(s) emptyDone = s end })
    check(emptyDone and emptyDone.count == 0 and emptyDone.stopped == false and Q.busy(P) == 2,
        "排程：空的一組在佇列還在跑時也當場結束、叫 onDone，不排進去")
    Q.cancel(P)
    check(Q.busy(P) == 0, "取消：清掉排著的")

    -- 規劃模式接手放開：hook.commit 回 true 就不送
    local committed
    Cur.hook.commit = function() committed = true return true end
    local cur = setmetatable({ kx = 1, ky = 1, kz = 0, res = { { a = { 1, 1, 0, 0 } } }, lineX = 5 }, { __index = Cur })
    local before2 = #sent
    cur:tryBuild(1, 1, 0)
    check(committed and #sent == before2 and cur.lineX == nil, "hook.commit 回 true：游標不送，交給規劃模式")
    Cur.hook.commit = nil
    -- 掛鉤丟錯（審查 C8）：commit 掛了卻出錯，這次放開取消、不送真的建造，說一聲
    Cur.hook.commit = function() error("hook broke") end
    toasts = {}
    local cur3 = setmetatable({ kx = 1, ky = 1, kz = 0, res = { { a = { 1, 1, 0, 0 } } }, lineX = 5 }, { __index = Cur })
    local before3 = #sent
    cur3:tryBuild(1, 1, 0)
    check(#sent == before3 and cur3.lineX == nil and toasts[1] == "IGUI_MBLD_CommitFailed",
        "hook.commit 丟錯：這次放開取消、不送建造，通知玩家")
    Cur.hook.commit = nil
    -- 規劃掛鉤的 layer 這次拖曳出過錯（審查 Q6）：格子照 self.up 算了，放開照 commit 出錯處理，commit 不叫、不送
    local commits = 0
    Cur.hook.commit = function() commits = commits + 1 return true end
    toasts = {}
    local cur4 = setmetatable({ kx = 1, ky = 1, kz = 0, res = { { a = { 1, 1, 0, 0 } } }, lineX = 5, layerBad = true },
        { __index = Cur })
    local before4 = #sent
    cur4:tryBuild(1, 1, 0)
    check(commits == 0 and #sent == before4 and cur4.layerBad == nil and toasts[1] == "IGUI_MBLD_CommitFailed",
        "hook.layer 這次拖曳出過錯：放開取消、不交給 commit、不送建造，通知玩家")
    Cur.hook.commit = nil

    C.build, Messages.toast, Cur.get, ISTimedActionQueue, sb.MaxCellsPerDrag = real.build, real.toast, real.get, real.q, real.max
    C.dismantleMany, getText, getCell = real.dm, real.text, real.cell
    E.resolve, E.face, E.cells, E.alternate, E.north = real.resolve, real.face, real.cells, real.alt, real.north
end)()

print("情境（排程與轉向）：配方項目照圖蓋（Recipes.runCells）、規劃開著時放下記進藍圖")
;(function()
    local B = MinidoracatBuilder
    local R, Cl, Msg = B.Recipes, B.Client, B.Messages
    local real = { spec = getSpecificPlayer, cell = getCell, BL = BuildLogic, ISB = ISBuildIsoEntity, IBO = ISBuildingObject,
        TAQ = ISTimedActionQueue, ctx = ISInventoryPaneContextMenu, joy = JoypadState, toast = Msg.toast, PM = B.PlanMode,
        list = R.list, byId = R.byId, text = getText, core = getCore, pend = Cl.pending, unb = Cl.pendingUnbuild }
    getText = function(k, ...)
        local a = { ... }
        return #a == 0 and k or k .. "(" .. table.concat(a, ",") .. ")"
    end
    local toasts, queue, tried, bad, can, hammer = {}, {}, {}, {}, true, true
    Msg.toast = function(_, t) toasts[#toasts + 1] = t end
    Cl.pending, Cl.pendingUnbuild = nil, nil
    local P = {}
    function P:getPlayerNum() return 2 end
    function P:isBuildCheat() return false end
    function P:getCurrentSquare() return nil end
    function P:isDead() return false end
    function P:getInventory() return {} end
    function P:tooDarkToRead() return false end
    getSpecificPlayer = function(pn) return pn == 2 and P or nil end
    local drag = {}
    getCell = function()
        local c = real.cell()
        c.getDrag = function(_, pn) return drag[pn] end
        c.setDrag = function(_, o, pn)
            drag[pn] = o
            if o then o.player = pn end
        end
        return c
    end
    local col = { getR = function() return 1 end, getG = function() return 1 end, getB = function() return 1 end }
    getCore = function()
        local c = real.core()
        c.getGoodHighlitedColor, c.getBadHighlitedColor = function() return col end, function() return col end
        return c
    end
    local noDraw = { RenderGhostTileColor = function() end }
    JoypadState = { players = {} }
    ISInventoryPaneContextMenu = { getContainers = function() return javaList({}) end }
    BuildLogic = { new = function()
        local L = { ls = {} }
        local function emit(self, ev, a)
            for _, l in ipairs(self.ls) do if l[1] == ev then l[2](l[3], a) end end
        end
        function L:getAllBuildableRecipes() return javaList({}) end
        function L:setManualSelectInputs() end
        function L:setContainers() return false end
        function L:setRecipe(cr) self.cr = cr end
        function L:canPerformCurrentRecipe() return can end
        function L:isCraftActionInProgress() return self.busy == true end
        function L:addEventListener(ev, fn, t) self.ls[#self.ls + 1] = { ev, fn, t } end
        function L:startCraftAction(a) self.busy = true emit(self, "onStartCraft", a) end
        function L:stopCraftAction() self.busy = false emit(self, "onStopCraft") end
        function L:autoPopulateInputs() end
        function L:refresh() end
        function L:getPossibleCraftCount() return 0 end -- 一份材料都沒有：規劃開著時不看
        return L
    end }
    -- 假原版游標：isValid 看 blockBuild、擋住的格子與鎚子（haveMaterial），tryBuild 先 startCraftAction 再排進佇列
    ISBuildIsoEntity = {}
    ISBuildIsoEntity.new = function(_, p, inf, n, _, L)
        return setmetatable({ character = p, objectInfo = inf, nSprite = n, buildPanelLogic = L, spriteCache = {},
            dragNilAfterPlace = true, noNeedHammer = false, tileSprite = noDraw }, { __index = ISBuildIsoEntity })
    end
    function ISBuildIsoEntity:getSprite() end
    function ISBuildIsoEntity:getFace()
        local f = self.objectInfo:getFace(({ 1, 0, 3, 2 })[self.nSprite])
        local nm = f and f:getTileInfo(0, 0, 0):getSpriteName()
        if nm then self.spriteCache[nm] = noDraw end
        return f
    end
    function ISBuildIsoEntity:ensureSquaresExist() end
    function ISBuildIsoEntity:isValid(sq) return not self.blockBuild and not bad[sq] and (self.noNeedHammer or hammer) end
    function ISBuildIsoEntity:render() end
    function ISBuildIsoEntity:tryBuild(x, y, z)
        local act = { cursor = self, onDone = self.onActionComplete, x = x, y = y,
            spr = self:getFace():getTileInfo(0, 0, 0):getSpriteName() }
        act.action = { isForceComplete = function() return false end, finished = function() return act.fin == true end }
        tried[#tried + 1] = { x, y, z, self.nSprite }
        self.buildPanelLogic:startCraftAction(act)
        queue[#queue + 1] = act
    end
    ISBuildingObject = { onActionComplete = function(self) self.buildPanelLogic:stopCraftAction() end,
        getFloorCursorSprite = function() return noDraw end }
    ISTimedActionQueue = {
        isPlayerDoingAction = function() return #queue > 0 end,
        hasAction = function(a)
            for _, x in ipairs(queue) do if x == a then return true end end
            return false
        end,
        getTimedActionQueue = function() return { queue = queue } end,
        clear = function()
            local q = queue
            queue = {}
            for _, a in ipairs(q) do a.onDone(a.cursor) end
        end }
    -- 那格的動作結束：fin＝時間到、物件出現（蓋好），否則＝被打斷
    local function done(fin)
        local a = table.remove(queue, 1)
        if fin then
            local sq = getCell():getGridSquare(a.x, a.y, 0)
            sq.objects[#sq.objects + 1] = { getSprite = function() return { getName = function() return a.spr end } end }
            a.fin = true
        end
        a.onDone(a.cursor)
        fire("OnTick")
    end
    local function info(n, w)
        local function face(name)
            local tile = { getSpriteName = function() return name end }
            return { getWidth = function() return 1 end, getHeight = function() return 1 end, getTileInfo = function() return tile end }
        end
        local faces = { [0] = face(n), [1] = face(w) }
        return { getFace = function(_, f) return faces[f] end }
    end
    local cr = { getToolBoth = function() end, getToolRight = function() end, getToolLeft = function() end,
        canBeDoneInDark = function() return true end }
    local rWall = { id = "recipe:QT.Wall", recipe = cr, info = info("qt_rwall_01_1", "qt_rwall_01_0"), kind = "wall" }
    local rBox = { id = "recipe:QT.Box", recipe = cr, info = info("qt_rbox_01_0", "qt_rbox_01_1"), kind = "furniture" }
    local rPaint = { id = "recipe:QT.Paint", recipe = cr, cover = true, kind = "wallOverlay" }
    R.list = { n = 3, rWall, rBox, rPaint }
    R.byId = { [rWall.id] = rWall, [rBox.id] = rBox, [rPaint.id] = rPaint }

    local _, cU = R.runCells(P, "recipe:QT.Nope", { { 41, 41, 0, 2 } })
    local _, cC = R.runCells(P, rPaint.id, { { 41, 41, 0, 2 } })
    can = false
    local okS, cS = R.runCells(P, rWall.id, { { 41, 41, 0, 2 } })
    can = true
    check(cU == "UNKNOWN" and cC == "COVER" and okS == nil and cS == "SHORT" and #tried == 0,
        "照圖蓋：沒有這個配方、牆面油漆、材料不夠都當場回碼，不送")
    local sum
    local function keep(s) sum = s end
    local ok1 = R.runCells(P, rWall.id, { { 41, 41, 0, 2 }, { 42, 41, 0, 2 }, { 43, 41, 0, 1 } }, keep)
    check(ok1 == true and #tried == 1 and tried[1][4] == 2 and R.row(2) ~= nil and drag[2] == nil,
        "照圖蓋：送第一格（那格的面），不開游標")
    done(true)
    check(#tried == 2 and tried[2][1] == 42 and sum == nil, "照圖蓋：那格蓋好、佇列空了才送下一格")
    done(true)
    done(true)
    check(sum and sum.count == 3 and sum.placed == 3 and sum.stopped == false and sum.why == nil and tried[3][4] == 1
        and #toasts == 0 and R.row(2) == nil, "照圖蓋：三格都蓋好，onDone 收到 3／3，不跳通知")
    sum = nil
    R.runCells(P, rWall.id, { { 44, 41, 0, 2 }, { 45, 41, 0, 2 } }, keep)
    done(false)
    check(sum and sum.stopped and sum.placed == 0 and sum.why == nil and #tried == 4 and #toasts == 0,
        "照圖蓋：被打斷回 stopped，不通知、不再送")
    sum = nil
    R.runCells(P, rWall.id, { { 46, 41, 0, 2 }, { 47, 41, 0, 2 } }, keep)
    Cl.pending = { n = 1, player = P }
    done(true)
    Cl.pending = nil
    check(sum and sum.stopped and #tried == 5 and #toasts == 0, "照圖蓋：玩家手拖圖塊（換了建造請求）時停下，回 stopped")
    sum = nil
    R.runCells(P, rWall.id, { { 48, 41, 0, 2 }, { 49, 41, 0, 2 } }, keep)
    R.stopCells(P)
    done(true)
    check(sum and sum.stopped and #tried == 6 and R.row(2) == nil and #toasts == 0,
        "照圖蓋：stopCells 後還沒送的不送，onDone 收到 stopped、不通知")
    sum = nil
    bad[getCell():getGridSquare(51, 41, 0)] = true
    R.runCells(P, rWall.id, { { 50, 41, 0, 2 }, { 51, 41, 0, 2 }, { 52, 41, 0, 2 } }, keep)
    done(true)
    check(sum and sum.placed == 1 and sum.stopped and sum.why == "missing" and #tried == 7 and R.row(2) == nil,
        "照圖蓋：送前驗地形，擋住的那格不送、停下回 missing（被擋的是第 placed＋1 格），後面不再送")
    sum = nil
    local okB = R.runCells(P, rWall.id, { { 51, 41, 0, 2 }, { 52, 41, 0, 2 } }, keep)
    check(okB == true and sum and sum.placed == 0 and sum.why == "missing" and #tried == 7,
        "照圖蓋：第一格就被擋：當場收尾回 missing，不送")
    local fs = R.faces(rWall.id)
    check(R.tile(rWall.id, 2) == "qt_rwall_01_1" and R.tile(rWall.id, 1) == "qt_rwall_01_0" and R.tile(rWall.id, 3) == nil
        and R.tile(rPaint.id, 1) == nil and R.faceOf(rWall.id, "qt_rwall_01_0") == 1 and R.faceOf(rWall.id, "qt_x") == nil
        and fs.n == 2 and fs[1] == 1 and fs[2] == 2 and R.faces(rPaint.id) == nil,
        "配方的面：第 d 面的圖、圖是哪一面、有哪些面；牆面油漆都沒有")
    -- 左上那格空著的面（原版曬架、木炭窯）：取第一格有圖的，並回它離錨點幾格
    local rackFace = { getWidth = function() return 2 end, getHeight = function() return 2 end,
        getTileInfo = function(_, x, y)
            local name = (y == 0 and x == 1) and "qt_rack_01_1" or y == 1 and "qt_rack_01_" .. (2 + x) or nil
            return { getSpriteName = function() return name end }
        end }
    local rRack = { id = "recipe:QT.Rack", recipe = cr, kind = "furniture",
        info = { getFace = function(_, f) return f == 0 and rackFace or nil end } }
    R.byId[rRack.id] = rRack
    local tn, tx, ty = R.tile(rRack.id, 2)
    local fd, fx, fy = R.faceOf(rRack.id, "qt_rack_01_1")
    check(tn == "qt_rack_01_1" and tx == 1 and ty == 0 and fd == 2 and fx == 1 and fy == 0
        and R.faceOf(rRack.id, "qt_rack_01_2") == nil and R.tile(rRack.id, 1) == nil,
        "配方的面：左上那格空著時取第一格有圖的、回它離錨點幾格；同一面的其他格不算")
    R.byId[rRack.id] = nil

    -- 規劃開著：材料不夠、沒鎚子也不擋，放下（一格、拖一排、不能拖的）交給 PlanMode.addCells，不送原版建造
    local added, on = {}, true
    B.PlanMode = { planning = function() return on end,
        addCells = function(pn, id, cells) added[#added + 1] = { pn = pn, id = id, cells = cells } return true end }
    can, hammer = false, false
    local c = R.build(2, rWall.id)
    check(c and c.blockBuild == false and c.noNeedHammer == true, "規劃開著：材料不夠、沒有鎚子，游標照樣能放")
    local n0 = #tried
    c:tryBuild(41, 42, 0)
    local s43 = getCell():getGridSquare(41, 43, 0)
    c.square, c.isLeftDown = s43, true
    c:rotateMouse(43, 43)
    c:render(41, 43, 0, s43)
    c.isLeftDown = false
    c:tryBuild(41, 43, 0)
    local box = R.build(2, rBox.id)
    box:tryBuild(44, 44, 0)
    local a1, a2, a3 = added[1], added[2], added[3]
    check(#tried == n0 and a1 and a1.pn == 2 and a1.id == rWall.id and a1.cells[1][1] == 41 and a1.cells[1][4] == 1
        and a2 and #a2.cells == 3 and a2.cells[3][1] == 43 and a3 and a3.id == rBox.id and a3.cells[1][2] == 44,
        "規劃開著：放一格、拖一排、不能拖的配方都記進藍圖（世界座標＋面），不呼叫原版 tryBuild")
    local nt = #toasts
    check(R.build(2, rPaint.id) == nil and #toasts == nt + 1 and toasts[#toasts] == "IGUI_MBLD_Recipe_NoPlan",
        "規劃開著：牆面油漆不開游標，說不能記進藍圖")
    on = false
    c.lineX = nil
    c:render(41, 45, 0, getCell():getGridSquare(41, 45, 0))
    check(c.blockBuild == true and c.noNeedHammer == false, "關掉規劃：材料不夠照舊擋、鎚子照舊要")
    can, hammer = true, true
    c:render(41, 45, 0, getCell():getGridSquare(41, 45, 0))
    getCell():setDrag(c, 2)
    c:tryBuild(41, 45, 0)
    check(#tried == n0 + 1 and #added == 3 and R.row(2) ~= nil, "關掉規劃：放下照舊送原版建造，不記進藍圖")
    done(false)
    check(R.row(2) == nil and toasts[#toasts] == "IGUI_MBLD_Refuse_WALK", "關掉規劃：手放的一排被打斷照舊通知")

    drag[2] = nil
    getSpecificPlayer, getCell, BuildLogic, ISBuildIsoEntity, ISBuildingObject = real.spec, real.cell, real.BL, real.ISB, real.IBO
    ISTimedActionQueue, ISInventoryPaneContextMenu, JoypadState, Msg.toast = real.TAQ, real.ctx, real.joy, real.toast
    B.PlanMode, R.list, R.byId, getText, getCore = real.PM, real.list, real.byId, real.text, real.core
    Cl.pending, Cl.pendingUnbuild = real.pend, real.unb
end)()

-- ===== 車庫門與雙開門 =====
print("情境（車庫門與雙開門）：整組一個項目、拖一排定寬度、整組全蓋或不蓋、整組拆整組退、門窗配對面")
;(function()
    local Place, Ledger, Dismantle = MinidoracatBuilder.Place, MinidoracatBuilder.Ledger, MinidoracatBuilder.Dismantle
    local real = { inst = instanceof, door = IsoDoor, gd = buildUtil.getGarageDoorObjects, dd = buildUtil.getDoubleDoorObjects,
        max = sb.MaxCellsPerDrag, dist = sb.MaxDistance, roll = HARNESS_ROLL }
    instanceof = function(o, cls) return type(o) == "table" and o.class == cls end
    sb.MaxCellsPerDrag, sb.MaxDistance = 6, 8
    -- 圖塊：車庫門 hgd_01（西向 0–2、北向 3–5，開著 +8，值 4–6）；雙開門 hdd_01（西向第 1–4 片 8、9、0、1，北向 2、3、10、11；
    -- 開著照 IsoDoor 的偏移表），照原版 tiledef 的排法（Entry.doorSet）
    local added = {}
    local function add(name, id, dir, key, v)
        local s = sprite(name, id, { flags = { dir }, keys = { [key] = tostring(v) } })
        spriteMap[name], added[#added + 1] = s, name
        spriteOrder[#spriteOrder + 1] = s
        return s
    end
    for i = 0, 2 do
        add("hgd_01_" .. i, 9100 + i, "doorW", "GarageDoor", i + 1)
        add("hgd_01_" .. (i + 3), 9103 + i, "doorN", "GarageDoor", i + 1)
        add("hgd_01_" .. (i + 8), 9108 + i, "doorW", "GarageDoor", i + 4)
        add("hgd_01_" .. (i + 11), 9111 + i, "doorN", "GarageDoor", i + 4)
    end
    for _, t in ipairs({ { 8, "doorW", 1 }, { 9, "doorW", 2 }, { 0, "doorW", 3 }, { 1, "doorW", 4 }, { 12, "doorW", 5 },
        { 13, "doorW", 6 }, { 5, "doorW", 7 }, { 4, "doorW", 8 }, { 2, "doorN", 1 }, { 3, "doorN", 2 }, { 10, "doorN", 3 },
        { 11, "doorN", 4 }, { 7, "doorN", 5 }, { 6, "doorN", 6 }, { 14, "doorN", 7 }, { 15, "doorN", 8 } }) do
        add("hdd_01_" .. t[1], 9120 + t[1], t[2], "DoubleDoor", t[3])
    end
    add("hbad_01_0", 9140, "doorN", "GarageDoor", 1) -- 湊不成整組的頭片（沒有中、尾）
    -- 假 IsoDoor：照引擎認整組（IsoDoor.java:2756-2843,3035-3161），格子上只放門
    local function doorAt(x, y, z, north)
        local sq = squares[x .. "," .. y .. "," .. z]
        for _, o in ipairs(sq and sq.objects or {}) do if o.class == "IsoDoor" and o.north == north then return o end end
        return nil
    end
    local function val(o, key) return tonumber(o.spr:getProperties():get(key)) end
    IsoDoor = { new = function(_, sq, name, north)
        local d = { class = "IsoDoor", spr = spriteMap[name], north = north, md = {}, hp = 500, sq = sq }
        function d:getSprite() return self.spr end
        function d:getProperties() return self.spr:getProperties() end
        function d:getTextureName() return self.spr:getName() end
        function d:getType() return T.normal end
        function d:getSquare() return self.sq end
        function d:getModData() return self.md end
        function d:hasModData() return next(self.md) ~= nil end
        function d:setHealth(v) self.hp = v end
        function d:getHealth() return self.hp end
        function d:getMaxHealth() return 500 end
        function d:setExplored() end
        function d:transmitCompleteItemToClients() end
        function d:getContainerCount() return 0 end
        function d:isNorth() return self.north end
        function d:isOpen() return self.open == true end
        function d:isFloor() return false end
        function d:isBarricaded() return false end
        function d:isObjectNoContainerOrEmpty() return true end
        function d:getObjectIndex() return 0 end
        function d:getAttachedAnimSprite() return nil end
        return d
    end }
    function IsoDoor.getGarageDoorIndex(o)
        local v = o.spr and o.spr:getProperties():has("GarageDoor") and val(o, "GarageDoor")
        if not v then return -1 end
        return v > 3 and v - 3 or v
    end
    function IsoDoor.getDoubleDoorIndex(o)
        local v = o.spr and o.spr:getProperties():has("DoubleDoor") and val(o, "DoubleDoor")
        if not v then return -1 end
        return v > 4 and v - 4 or v
    end
    -- getGarageDoorPrev（s＝−1）／Next（s＝1）：北向沿 x、西向沿 −y 找相鄰格同方向的門（IsoDoor.java:3064-3144）
    local function step(o, s, cmp)
        local i = IsoDoor.getGarageDoorIndex(o)
        if i == -1 or i == (s < 0 and 1 or 3) then return nil end
        local sq = o.sq
        local n = doorAt(sq:getX() + (o.north and s or 0), sq:getY() - (o.north and 0 or s), sq:getZ(), o.north)
        if n and IsoDoor.getGarageDoorIndex(n) ~= -1 and cmp(IsoDoor.getGarageDoorIndex(n), i) then return n end
        return nil
    end
    function IsoDoor.getGarageDoorPrev(o) return step(o, -1, function(a, b) return a <= b end) end
    function IsoDoor.getGarageDoorNext(o) return step(o, 1, function(a, b) return a >= b end) end
    function IsoDoor.getGarageDoorFirst(o)
        if IsoDoor.getGarageDoorIndex(o) == 1 then return o end
        local p = IsoDoor.getGarageDoorPrev(o)
        while p do
            if IsoDoor.getGarageDoorIndex(p) == 1 then return p end
            p = IsoDoor.getGarageDoorPrev(p)
        end
        return o
    end
    -- 照 IsoDoor.java:2785-2843：以 o 的方向、開關與片號推第 1 片那格，再加第 i 片的偏移（偏移表 :141-148）
    local DD = { N = { [false] = { { 0, 1, 2, 3 }, { 0, 0, 0, 0 } }, [true] = { { 0, 0, 3, 3 }, { 0, 1, 1, 0 } } },
        W = { [false] = { { 0, 0, 0, 0 }, { 0, -1, -2, -3 } }, [true] = { { 0, 1, 1, 0 }, { 0, 0, -3, -3 } } } }
    function IsoDoor.getDoubleDoorObject(o, i)
        local j = IsoDoor.getDoubleDoorIndex(o)
        if j == -1 then return nil end
        local t, sq = DD[o.north and "N" or "W"][o.open == true], o.sq
        local x, y = sq:getX() - t[1][j] + t[1][i], sq:getY() - t[2][j] + t[2][i]
        local found = doorAt(x, y, sq:getZ(), o.north)
        return found and IsoDoor.getDoubleDoorIndex(found) == i and found or nil
    end
    -- 原版 ISBuildUtil.lua:543-570 照抄
    buildUtil.getDoubleDoorObjects = function(object)
        local objects = {}
        for i = 1, 4 do
            local dd = IsoDoor.getDoubleDoorObject(object, i)
            if dd then table.insert(objects, dd) end
        end
        return objects
    end
    buildUtil.getGarageDoorObjects = function(object)
        local objects = {}
        if IsoDoor.getGarageDoorIndex(object) ~= -1 then
            table.insert(objects, object)
            local prev = IsoDoor.getGarageDoorPrev(object)
            while prev do table.insert(objects, prev); prev = IsoDoor.getGarageDoorPrev(prev) end
            local nxt = IsoDoor.getGarageDoorNext(object)
            while nxt do table.insert(objects, nxt); nxt = IsoDoor.getGarageDoorNext(nxt) end
        end
        return objects
    end
    -- 格子：移除時照引擎先觸發 OnObjectAboutToBeRemoved；退料掉在格上
    local function engineSq(x, y, o)
        local sq = square(x, y, 0, o)
        local orig = sq.transmitRemoveItemFromSquare
        sq.dropped = {}
        function sq:transmitRemoveItemFromSquare(obj, safely)
            fire("OnObjectAboutToBeRemoved", obj)
            return orig(self, obj, safely)
        end
        function sq:AddWorldInventoryItem(ft) self.dropped[ft] = (self.dropped[ft] or 0) + 1 end
        return sq
    end
    for x = 300, 312 do for y = 300, 312 do engineSq(x, y) end end
    local function at(x, y) return squares[x .. "," .. y .. ",0"] end
    local function doorsAt(list)
        local out = {}
        for k, c in ipairs(list) do
            local d = doorAt(c[1], c[2], 0, c[3])
            out[k] = d and d.spr:getName() or "-"
        end
        return table.concat(out, " ")
    end
    local function stock(p)
        return p.inv:count("Base.Plank") .. "/" .. p.inv:count("Base.Nails") .. "/" .. p.inv:count("Base.Hinge") .. "/"
            .. p.inv:count("Base.Doorknob")
    end
    local function builder(id, x, y)
        local p = player({ id = id, x = x, y = y, woodwork = 10, here = at(math.floor(x), math.floor(y)) })
        p.inv:add(item("Base.Hammer", { HAMMER = true }))
        for _, ft in ipairs({ "Base.Plank", "Base.Nails", "Base.Hinge", "Base.Doorknob" }) do
            for _ = 1, 80 do p.inv:add(item(ft)) end
        end
        return p
    end
    local function intentCode(p, n, e, c, w)
        sent = {}
        Server.intent(p, { n = n, e = e, c = c, v = Entry.digest(), w = w })
        return sent[1] and sent[1].cmd == "refused" and sent[1].args.code or nil
    end
    local function build(p, n, e, c, w)
        local code = intentCode(p, n, e, c, w)
        if code then return false, code end
        sent = {}
        local ok = Server.complete(p, n, 1)
        return ok, sent[1] and sent[1].args.code
    end
    local P = builder(9101, 303.5, 303.5)

    -- 目錄：只有湊得成整組的頭片、第 1 片
    check(Entry.resolve("hgd_01_3") and Entry.resolve("hgd_01_0") and Entry.resolve("hdd_01_2") and Entry.resolve("hdd_01_8")
        and not Entry.resolve("hgd_01_4") and not Entry.resolve("hdd_01_3") and not Entry.resolve("hgd_01_11")
        and not Entry.resolve("hbad_01_0"), "目錄：車庫門頭片、雙開門第 1 片各一項；其他片、開著的、湊不成整組的不收")
    check(Entry.why("hgd_01_4") == "PART" and select(3, Entry.why("hgd_01_4")) == "hgd_01_3"
        and select(3, Entry.why("hdd_01_15")) == "hdd_01_2" and Entry.why("hbad_01_0") == "DOOR_SET",
        "原因：其他片（含開著的）說 PART、指回第一片；湊不成整組的說 DOOR_SET")
    -- 配對面：車庫門 ±3、雙開門 ±6
    local function face5(name) local s = Entry.face(Entry.resolve(name), 5) return s and s:getName() end
    check(face5("hgd_01_3") == "hgd_01_0" and face5("hgd_01_0") == "hgd_01_3" and face5("hdd_01_2") == "hdd_01_8"
        and face5("hdd_01_8") == "hdd_01_2", "配對面：車庫門頭片 ±3、雙開門第 1 片 ±6，方向相反")

    -- 車庫門片順序：北向沿 +x（頭、中…、尾），西向沿 −y
    local function roles(e, w)
        local out = {}
        for k, o in ipairs(Entry.groupCells(Entry.doorSet(Entry.sprite(e)), w)) do
            out[k] = o[1] .. "," .. o[2] .. ":" .. o[4]:getName()
        end
        return table.concat(out, " ")
    end
    check(roles("hgd_01_3", 2) == "0,0:hgd_01_3 1,0:hgd_01_5"
        and roles("hgd_01_3", 5) == "0,0:hgd_01_3 1,0:hgd_01_4 2,0:hgd_01_4 3,0:hgd_01_4 4,0:hgd_01_5"
        and roles("hgd_01_0", 3) == "0,0:hgd_01_0 0,-1:hgd_01_1 0,-2:hgd_01_2"
        and roles("hdd_01_8", 9) == "0,0:hdd_01_8 0,-1:hdd_01_9 0,-2:hdd_01_0 0,-3:hdd_01_1",
        "片順序：車庫門 2 格頭尾、5 格頭＋中×3＋尾；西向沿 −y；雙開門固定四片")

    -- 蓋 5 格北向車庫門：整組放好、扣料一次、帳本整組一筆
    local before = stock(P)
    local okG = build(P, 1, "hgd_01_3", { 301, 302, 0, 0 }, 5)
    local row = { { 301, 302, true }, { 302, 302, true }, { 303, 302, true }, { 304, 302, true }, { 305, 302, true } }
    local head = doorAt(301, 302, 0, true)
    check(okG == true and doorsAt(row) == "hgd_01_3 hgd_01_4 hgd_01_4 hgd_01_4 hgd_01_5" and stock(P) ~= before
        and head.md.builderEntry == "hgd_01_3", "車庫門 5 格：頭、中×3、尾照順序蓋好，扣料")
    local rec = Ledger.getDoor(head)
    check(rec and rec["Base.Plank"] == 20 and Place.refundOf(doorAt(303, 302, 0, true)) == rec,
        "帳本：整組一筆記在頭片（5 片的料加總），哪一片查都回同一筆")
    local g = Place.doorGroup(doorAt(304, 302, 0, true))
    check(g and g.e == "hgd_01_3" and g.x == 301 and g.y == 302 and g.w == 5 and g.garage and g.north
        and Entry.doorItem("hgd_01_12") == "hgd_01_3" and Entry.doorItem("hdd_01_14") == "hdd_01_2"
        and Entry.doorItem("hdd_01_8") == "hdd_01_8" and Entry.doorItem("hbad_01_0") == nil,
        "擷取：任一片認回項目 ID、錨點（頭片那格）與寬度；開著的片也認得")
    -- 預覽與伺服器同一份
    local function preview(e, a) return (Check.item(P, e, a[4], a, { preview = true, walk = true })) end
    check(preview("hgd_01_0", { 308, 306, 0, 0, 3 }) == nil and preview("hgd_01_0", { 308, 306, 0, 0, 99 }) == "BAD_REQUEST"
        and preview("hgd_01_0", { 308, 306, 0, 0 }) == "BAD_REQUEST", "預覽：合法寬度可蓋；超過上限、沒帶寬度 BAD_REQUEST（同伺服器）")

    -- 中間一格被擋：整組不蓋、不扣料
    engineSq(304, 309, { doors = { [GridSquareEdgeFacingDirection.NORTH_SOUTH] = {} } })
    before = stock(P)
    local pv = preview("hgd_01_3", { 302, 309, 0, 0, 4 })
    local okB, codeB = build(P, 2, "hgd_01_3", { 302, 309, 0, 0 }, 4)
    check(okB == false and codeB == pv and pv ~= nil and stock(P) == before
        and doorsAt({ { 302, 309, true }, { 303, 309, true }, { 305, 309, true } }) == "- - -",
        "中間一格被擋：整組不蓋、沒扣料；預覽同一個原因碼（" .. tostring(codeB) .. "）")

    -- 游標：拖的那一軸定寬度與頭片位置，夾在 2..一次上限
    local Cur = MinidoracatBuilder.Cursor
    local function ga(e, ax, ay, ex, ey)
        local a = Cur.garageAnchor({ spr = Entry.sprite(e), d = 0, perBatch = 6 }, ax, ay, 0, ex, ey)
        return a[1] .. "," .. a[2] .. " w=" .. a[5]
    end
    check(ga("hgd_01_3", 305, 302, 305, 302) == "305,302 w=2" and ga("hgd_01_3", 305, 302, 301, 309) == "301,302 w=5"
        and ga("hgd_01_3", 301, 302, 320, 302) == "301,302 w=6" and ga("hgd_01_0", 302, 305, 302, 307) == "302,307 w=3"
        and ga("hgd_01_0", 302, 305, 302, 303) == "302,305 w=3",
        "游標：北向往左拖頭片移到最左、西向往南拖頭片在最南；不拖 2 格；超過一次上限夾住")
    -- 偽造請求
    check(intentCode(P, 3, "hgd_01_3", { 301, 305, 0, 0 }, 7) == "BAD_REQUEST"
        and intentCode(P, 4, "hgd_01_3", { 301, 305, 0, 0 }, 1) == "BAD_REQUEST"
        and intentCode(P, 5, "hgd_01_3", { 301, 305, 0, 0 }, 2.5) == "BAD_REQUEST"
        and intentCode(P, 6, "hgd_01_3", { 301, 305, 0, 0 }) == "BAD_REQUEST"
        and intentCode(P, 7, "hgd_01_3", { 301, 305, 0, 0, 301, 306, 0, 0 }, 2) == "BAD_REQUEST"
        and intentCode(P, 8, "hdd_01_2", { 301, 305, 0, 0 }, 3) == "BAD_REQUEST"
        and intentCode(P, 9, "hgd_01_4", { 301, 305, 0, 0 }, 3) == "UNKNOWN",
        "偽造：超過上限、少於 2、不是整數、沒帶寬度、兩個錨點、不是車庫門帶寬度都 BAD_REQUEST；直接送中段片 UNKNOWN")
    sb.MaxCellsPerDrag = 1
    check(intentCode(P, 10, "hgd_01_3", { 301, 305, 0, 0 }, 2) == nil, "上限設成 1：車庫門照樣能蓋最短的 2 格")
    sb.MaxCellsPerDrag = 6
    -- 審查 C3：拆除工具照現在的圖對回那一組，不看 modData 的記號（客戶端改得到）
    local forged = sprite("hzz_01_0", 9150, { flags = { "doorN" }, keys = { Material = "Electric", CanScrap = "" } })
    spriteMap.hzz_01_0, added[#added + 1] = forged, "hzz_01_0"
    local headPlan = Dismantle.plan(head, "door")
    local honest = table.concat(Dismantle.tools("door", headPlan), ",")
    for _, c in ipairs(row) do doorAt(c[1], c[2], 0, true).md.builderEntry = "hzz_01_0" end
    check(honest == "HAMMER" and table.concat(Dismantle.tools("door", Dismantle.plan(head, "door")), ",") == honest,
        "拆除工具：把各片記號改成別的圖，要的工具照舊（照現在的圖對回整組）")
    for _, c in ipairs(row) do doorAt(c[1], c[2], 0, true).md.builderEntry = nil end
    head.md.builderEntry = "hgd_01_3"

    -- 拆任何一片：整組拆、退一次（每項 1..v）
    HARNESS_ROLL = "max"
    local here = P:getCurrentSquare()
    here.dropped = {}
    sent = {}
    Server.dismantleIntent(P, { n = 11, t = { 303, 302, 0, "hgd_01_4" } })
    local accepted = sent[#sent] and sent[#sent].cmd
    sent = {}
    local okD = Server.dismantle(P, 11, 1)
    check(accepted == "dismantleAccepted" and okD == true and doorsAt(row) == "- - - - -" and here.dropped["Base.Plank"] == 20
        and Ledger.getDoor(head) == nil, "拆中間一片：整組 5 片都拆、照帳本退一次（最多全退）、帳本清掉")
    -- 審查 C1：尾端那格沒載入（引擎找下一片回 null）時整組不拆、不退、帳本不動；載入後照常拆
    build(P, 21, "hgd_01_3", { 305, 300, 0, 0 }, 5)
    local wide = { { 305, 300, true }, { 306, 300, true }, { 307, 300, true }, { 308, 300, true }, { 309, 300, true } }
    local whead = doorAt(305, 300, 0, true)
    local tailSq = squares["309,300,0"]
    squares["309,300,0"] = nil
    here.dropped = {}
    sent = {}
    Server.dismantleIntent(P, { n = 22, t = { 306, 300, 0, "hgd_01_4" } })
    sent = {}
    Server.dismantle(P, 22, 1)
    local skip = sent[#sent]
    squares["309,300,0"] = tailSq
    check(skip and skip.cmd == "dismantleSkipped" and skip.args.code == "NOT_LOADED" and next(here.dropped) == nil
        and doorsAt(wide) == "hgd_01_3 hgd_01_4 hgd_01_4 hgd_01_4 hgd_01_5" and Ledger.getDoor(whead) ~= nil,
        "車庫門尾端沒載入：整組不拆、不退料、帳本留著（NOT_LOADED）")
    local mid = doorAt(307, 300, 0, true)
    at(307, 300).removeHere(mid) -- 格子載入、少了中間一片（不經移除事件）
    check(Dismantle.plan(whead, "door").incomplete == "NOT_OURS", "車庫門中間少了一片：整組不拆（NOT_OURS）")
    at(307, 300).objects[#at(307, 300).objects + 1] = mid
    sent = {}
    Server.dismantleIntent(P, { n = 23, t = { 306, 300, 0, "hgd_01_4" } })
    sent = {}
    check(Server.dismantle(P, 23, 1) == true and doorsAt(wide) == "- - - - -" and here.dropped["Base.Plank"] == 20,
        "整組都載入後照常拆、退一次")

    -- 雙開門：點一下四片齊放；拆一片整組拆
    local okDD = build(P, 12, "hdd_01_2", { 301, 307, 0, 0 })
    local quad = { { 301, 307, true }, { 302, 307, true }, { 303, 307, true }, { 304, 307, true } }
    check(okDD == true and doorsAt(quad) == "hdd_01_2 hdd_01_3 hdd_01_10 hdd_01_11"
        and Ledger.getDoor(doorAt(301, 307, 0, true))["Base.Plank"] == 8 and Ledger.getDoor(doorAt(301, 307, 0, true))["Base.Hinge"] == 8
        and Ledger.getDoor(doorAt(301, 307, 0, true))["Base.Doorknob"] == 4,
        "雙開門：一個錨點四片齊放，帳本整組一筆（木板、釘子每片半扇；鉸鏈 2、門把 1 每片照整扇，打壞時每片都會掉）")
    before = stock(P)
    local okDB, codeDB = build(P, 13, "hdd_01_2", { 302, 309, 0, 0 }) -- 第 3 片在被擋的那格
    check(okDB == false and codeDB ~= nil and stock(P) == before
        and doorsAt({ { 302, 309, true }, { 303, 309, true }, { 305, 309, true } }) == "- - -", "雙開門缺一格：整組不蓋、沒扣料")
    -- 第 2、3 片開關時引擎移除再重建（IsoDoor.java:2650-2754）：不清帳本
    local d2 = doorAt(302, 307, 0, true)
    at(302, 307):transmitRemoveItemFromSquare(d2)
    local d1 = doorAt(301, 307, 0, true)
    check(Ledger.getDoor(d1) ~= nil, "雙開門第 2 片被移除（開關）：帳本留著")
    check(Dismantle.plan(d1, "door").incomplete == "NOT_OURS", "雙開門少了一片：不給本工具拆（避免逐片拆後再退一次）")
    at(302, 307).objects[#at(302, 307).objects + 1] = d2
    local q4 = squares["304,307,0"]
    squares["304,307,0"] = nil
    local unloaded = Dismantle.plan(d1, "door").incomplete
    squares["304,307,0"] = q4
    check(unloaded == "NOT_LOADED", "雙開門有片的格子沒載入：整組不拆（NOT_LOADED）")
    -- 審查 C2：門每片至少收打壞會掉的五金（IsoDoor.destroy：門把 1、鉸鏈 0–2；三個材質都沒寫再掉木板 1–2）
    local function price(name, keys, m)
        local s = sprite(name, 9160, { flags = { "doorN" }, keys = keys })
        local it = Cost.of("door", s, m or 1).items
        return (it["Base.Plank"] or 0) .. "/" .. (it["Base.Nails"] or 0) .. "/" .. (it["Base.Hinge"] or 0) .. "/"
            .. (it["Base.Doorknob"] or 0)
    end
    local SCRAP, BARE, HALF, GARAGE = { Material = "Wood", CanScrap = "" }, {}, { DoubleDoor = "1" }, { GarageDoor = "1" }
    local scrapped = Cost.of("door", sprite("hs_01_0", 9160, { flags = { "doorN" }, keys = SCRAP }), 1).items
    check(scrapped["Base.Hinge"] == 2 and scrapped["Base.Doorknob"] == 1 and price("hs_01_1", HALF) == "2/2/2/1"
        and price("hs_01_2", GARAGE) == "4/4/2/1",
        "門的價錢（木板/釘子/鉸鏈/門把）：照拆解價的也收鉸鏈 2、門把 1；雙開門沒材質的每片 2/2/2/1；車庫門照基本價")
    -- 審查 D2：下限在乘完倍率之後，倍率低於 1 也不比打壞掉的少；倍率 2 不因下限多收
    check(price("hs_01_1", BARE, 0.5) == "2/2/2/1" and price("hs_01_1", BARE, 0) == "2/0/2/1"
        and price("hs_01_1", HALF, 0.5) == "2/1/2/1" and price("hs_01_1", HALF, 0) == "2/0/2/1"
        and price("hs_01_1", SCRAP, 0) == price("hs_01_1", SCRAP, 1) and price("hs_01_1", BARE, 2) == "8/8/4/2"
        and price("hs_01_1", HALF, 2) == "4/4/2/1" and price("hs_01_1", GARAGE, 0) == "0/0/0/0",
        "倍率 0.5／0：單扇木門 2/2/2/1、2/0/2/1，雙開門每片 2/1/2/1、2/0/2/1，有材質的照倍率 1；倍率 2 單扇 8/8/4/2、雙開門每片 4/4/2/1；車庫門照倍率")
    here.dropped = {}
    sent = {}
    Server.dismantleIntent(P, { n = 14, t = { 304, 307, 0, "hdd_01_11" } })
    sent = {}
    check(Server.dismantle(P, 14, 1) == true and doorsAt(quad) == "- - - -" and here.dropped["Base.Plank"] == 8
        and Ledger.getDoor(d1) == nil, "雙開門拆第 4 片：四片都拆、退一次、帳本清掉")

    -- 沙盒關掉門：車庫門、雙開門一起擋
    sb.KindDoor = false
    check(intentCode(P, 15, "hgd_01_3", { 301, 311, 0, 0 }, 2) ~= nil and intentCode(P, 16, "hdd_01_2", { 301, 311, 0, 0 }) ~= nil
        and Entry.why("hgd_01_3") == "DISABLED_KIND", "沙盒關掉門：車庫門、雙開門都被拒（DISABLED_KIND）")
    sb.KindDoor = nil

    -- 審查 D1：拆除工具每片照它自己那片關著的圖，只算真的在的片（中段是別的材質時，寬 2 不要中段的工具）
    scrapDefs.HDoorMetal = { perk = scrapDefs.Wood.perk, tools = { "Base.BlowTorch" },
        returnItems = { { returnItem = "Base.MetalBar", maxAmount = 1 } } }
    local function addK(name, id, keys)
        local s = sprite(name, id, { flags = { "doorN" }, keys = keys })
        spriteMap[name], added[#added + 1] = s, name
        spriteOrder[#spriteOrder + 1] = s
    end
    addK("hgm_01_3", 9171, { GarageDoor = "1" })
    addK("hgm_01_4", 9172, { GarageDoor = "2", Material = "HDoorMetal", CanScrap = "" })
    addK("hgm_01_5", 9173, { GarageDoor = "3" })
    addK("hgm_01_11", 9174, { GarageDoor = "4" })
    addK("hgm_01_12", 9175, { GarageDoor = "5" })
    addK("hgm_01_13", 9176, { GarageDoor = "6" })
    local function toolsOf(names)
        local rm = {}
        for i, n in ipairs(names) do rm[i] = { getSprite = function() return spriteMap[n] end } end
        local t = Dismantle.tools("door", { remove = rm })
        table.sort(t)
        return table.concat(t, ",")
    end
    local w3 = toolsOf({ "hgm_01_3", "hgm_01_4", "hgm_01_5" })
    check(Entry.doorSet(spriteMap.hgm_01_3) ~= nil and toolsOf({ "hgm_01_3", "hgm_01_5" }) == "HAMMER"
        and w3:find("BLOW_TORCH", 1, true) ~= nil and toolsOf({ "hgm_01_11", "hgm_01_12", "hgm_01_13" }) == w3,
        "拆除工具：寬 2 不要中段的工具、寬 3 要（" .. w3 .. "）；開著時和關著時一樣")
    scrapDefs.HDoorMetal = nil

    -- 審查 D3：雙開門北向開著、西向關著、西向開著三種擺法（偏移表另外三列）：完整、第 3 片那格沒載入、少了第 3 片
    local function quadCase(north, open, x0, y0, names)
        local t = DD[north and "N" or "W"][open]
        local placed = {}
        for i = 1, 4 do
            local sq = at(x0 + t[1][i], y0 + t[2][i])
            local d = IsoDoor.new(nil, sq, names[i], north)
            d.open = open
            sq.objects[#sq.objects + 1] = d
            placed[i] = d
        end
        placed[1].md.builderEntry = "hdd_01_2"
        local full = Dismantle.plan(placed[1], "door")
        local k3 = (x0 + t[1][3]) .. "," .. (y0 + t[2][3]) .. ",0"
        local sq3 = squares[k3]
        squares[k3] = nil
        local unl = Dismantle.plan(placed[1], "door").incomplete
        squares[k3] = sq3
        sq3.removeHere(placed[3])
        local gap = Dismantle.plan(placed[1], "door").incomplete
        for i = 1, 4 do placed[i].sq.removeHere(placed[i]) end
        return #full.remove .. "/" .. tostring(full.incomplete) .. "/" .. tostring(unl) .. "/" .. tostring(gap)
    end
    local nOpen = quadCase(true, true, 306, 310, { "hdd_01_7", "hdd_01_6", "hdd_01_14", "hdd_01_15" })
    local wClosed = quadCase(false, false, 311, 306, { "hdd_01_8", "hdd_01_9", "hdd_01_0", "hdd_01_1" })
    local wOpen = quadCase(false, true, 310, 309, { "hdd_01_12", "hdd_01_13", "hdd_01_5", "hdd_01_4" })
    check(nOpen == "4/nil/NOT_LOADED/NOT_OURS" and wClosed == nOpen and wOpen == nOpen,
        "雙開門北向開著、西向關著、西向開著：完整 4 片可拆；第 3 片那格沒載入 NOT_LOADED；少了第 3 片 NOT_OURS（"
            .. nOpen .. " " .. wClosed .. " " .. wOpen .. "）")

    instanceof, IsoDoor, buildUtil.getGarageDoorObjects, buildUtil.getDoubleDoorObjects = real.inst, real.door, real.gd, real.dd
    sb.MaxCellsPerDrag, sb.MaxDistance, HARNESS_ROLL = real.max, real.dist, real.roll
    local gone = {}
    for _, name in ipairs(added) do spriteMap[name], gone[name] = nil, true end
    for i = #spriteOrder, 1, -1 do if gone[spriteOrder[i].name] then table.remove(spriteOrder, i) end end
end)()

-- ===== 子種類 =====
print("情境（子種類）：牆、地板、門、窗照圖塊組名分子種類；屋頂不分（其他占 57%）")
;(function()
    local W = MinidoracatBuilder.Window
    local function all(kind, cases)
        local bad = {}
        for name, want in pairs(cases) do
            local got = W.subOf(kind, nil, name)
            if got ~= want then bad[#bad + 1] = name .. "→" .. tostring(got) end
        end
        return #bad == 0, table.concat(bad, ", ")
    end
    local ok, why = all("wall", {
        walls_exterior_roofs_30_05_12 = "gable", Spoon_Pack1_Roofs_01_1 = "gable", -- 大小寫不分
        walls_interior_house_01_5 = "interiorWall", pert_walls_wallpaper_2_3 = "interiorWall",
        walls_logs_3 = "woodWall", location_barn_01_7 = "woodWall", walls_exterior_wooden_01_2 = "woodWall",
        walls_exterior_house_02_4 = "exteriorWall",
        location_restaurant_bar_01_3 = "commercial", industry_tk_01_2 = "commercial", walls_garage_01_2 = "commercial",
        pert_walls_01_0 = "other", fencing_01_5 = "other", ["recipe:Base.Thing"] = "other",
    })
    check(ok, "子種類（牆）：山牆（組名有 roof）先比；穀倉、木造外牆歸木牆不歸商用或外牆；認不出的歸其他 " .. why)
    ok, why = all("floor", {
        roofs_01_22 = "flatRoof", pineville_roofs_09_3 = "flatRoof",
        floors_interior_carpet_01_3 = "indoorFloor", floor_carpet_motif_2 = "indoorFloor",
        floors_exterior_tilesandstone_01_9 = "outdoorFloor", blends_natural_01_8 = "outdoorFloor",
        ramps_01_0 = "other", industry_01_4 = "other", location_restaurant_bar_01_3 = "other",
    })
    check(ok, "子種類（地板）：平屋頂、室內、戶外；坡道與店面的地板歸其他（同一組在牆是商用，快取照種類分開）" .. why)
    ok, why = all("door", {
        fixtures_doors_fences_01_2 = "gate", pert_gates_01_1 = "gate",
        fixtures_doors_01_3 = "plainDoor", d_doors_02_5 = "plainDoor",
        location_shop_gas2go_01_1 = "commercial", industry_railroad_ddd_01_0 = "commercial",
        fixtures_bathroom_01_4 = "other", pert_Christmas_01_2 = "other",
    })
    check(ok, "子種類（門）：柵門先比（組名也有 door）、一般門、商用與工業，其他 " .. why)
    ok, why = all("window", {
        fixtures_windows_wood_3 = "woodFrame", fixtures_windows_metal_3 = "metalFrame", fixtures_windows_white_3 = "whiteFrame",
        fixtures_windows_church_1 = "church", location_community_church_small_01_2 = "church",
        walls_commercial_02_5 = "commercial", location_shop_greenes_01_4 = "commercial",
        fixtures_windows_01_8 = "other", fixtures_windows_ddd_01_3 = "other",
    })
    check(ok, "子種類（窗）：木框、金屬框、白框、教堂（教堂的店面窗也算）、商用與工業，其他 " .. why)
    check(W.SUB_KINDS.roof == nil and W.subOf("roof", nil, "roofs_30_01_3") == nil and W.subOf("roof", nil, "roofs_burnt_01_1") == nil,
        "屋頂不分子種類（照名稱分，其他超過一半）")
    local labels = true
    for _, k in ipairs({ "wall", "floor", "door", "window" }) do
        local list = W.SUB_KINDS[k]
        labels = labels and type(list) == "table" and list[#list] == "other"
    end
    check(labels, "牆、地板、門、窗的子種類都以其他收尾（翻譯 key 由「每個 W.SUB_KINDS 都有 CH、EN」那項檢查）")

    -- runSubs：只看名稱，不查圖；照 W.SUB_KINDS 的順序列，合計等於種類的項目數
    local Entry = MinidoracatBuilder.Entry
    local realSprite, realRefilter, realV, realSt = Entry.sprite, W.refilter, W.v, W.st
    local looked = 0
    Entry.sprite = function(...) looked = looked + 1 return realSprite(...) end
    W.st = { query = "", tab = "all", cat = "all", source = "all", recent = { n = 0 } }
    W.refilter = function() end
    local v = { nav = { setGroups = function() end, setSelected = function() end },
        cat = { setOptions = function() end, setSelected = function() end }, subs = {} }
    W.v = v
    local names = { n = 7, "walls_exterior_roofs_01_3", "walls_exterior_roofs_01_4", "walls_interior_house_01_1",
        "walls_logs_2", "location_shop_mall_01_0", "pert_walls_01_9", "walls_exterior_house_01_0" }
    v.subJob = { kind = "wall", src = "all", list = names, i = 0, of = {} }
    local okRun = pcall(W.runSubs, v)
    Entry.sprite = realSprite
    local ids, total = {}, 0
    for i, it in ipairs(v.subs.wall and v.subs.wall.items or {}) do
        ids[i] = it.id .. "=" .. it.n
        total = total + it.n
    end
    check(okRun and looked == 0 and table.concat(ids, ",") == "woodWall=1,exteriorWall=1,interiorWall=1,commercial=1,gable=2,other=1"
        and total == names.n, "牆的子種類：不查圖、照 W.SUB_KINDS 的順序列、合計等於項目數 " .. table.concat(ids, ","))
    W.refilter, W.v, W.st = realRefilter, realV, realSt
end)()

-- ===== 訊息與接線、選單、管理面板 =====
;(function()
    print("訊息與接線、選單、管理面板（介面審查 1116）")
    local B = MinidoracatBuilder
    require "MinidoracatBuilder/Messages"
    require "MinidoracatBuilder/Wiring"
    require "MinidoracatBuilder/Menu"
    require "MinidoracatBuilder/Admin"
    local Messages, Wiring, Menu, Admin = B.Messages, B.Wiring, B.Menu, B.Admin
    local function json(lang)
        local f = assert(io.open(MEDIA .. "/shared/Translate/" .. lang .. "/IG_UI.json", "rb"))
        local t = {}
        for k, v in f:read("*a"):gmatch('"(IGUI_MBLD_[%w_]+)"%s*:%s*"(.-)",?%s*\n') do t[k] = v end
        f:close()
        return t
    end
    local CH, EN = json("CH"), json("EN")

    -- 第 1 條：11 句錯誤訊息都補了下一步（繁中、英文）
    local NEXT = {
        Refuse_SAME_TILE = { "換一格", "Pick another tile" },
        Refuse_STACK_FULL = { "拆掉上面那件", "dismantle the top piece" },
        Recipe_NotBuilt = { "再拖一次", "drag again" },
        WireRefuse_INTERNAL = { "再試一次", "Try again" },
        WireRefuse_FULL = { "先拔掉一盞", "Unwire a light first" },
        WireRefuse_OUT_OF_RANGE = { "把燈蓋近一點", "Build the light closer" },
        WireRefuse_STATE = { "下車後再試", "Get out of the vehicle" },
        WireRefuse_NOT_SWITCH = { "蓋一個電燈開關", "Build a light switch" },
        Wire_Unloaded = { "走近之後再切一次", "Move closer and switch again" },
        Admin_Error = { "再試一次", "Try again" },
        Admin_LedgersNoReply = { "關掉面板再開一次", "Close the panel and open it again" },
    }
    local lacking = {}
    for k, want in pairs(NEXT) do
        local ch, en = CH["IGUI_MBLD_" .. k], EN["IGUI_MBLD_" .. k]
        if not (ch and ch:find(want[1], 1, true)) then lacking[#lacking + 1] = "CH:" .. k end
        if not (en and en:find(want[2], 1, true)) then lacking[#lacking + 1] = "EN:" .. k end
    end
    check(#lacking == 0, "11 句錯誤訊息都寫了下一步能做什麼（繁中、英文）" .. table.concat(lacking, " "))
    local newKeys = {}
    for _, k in ipairs({ "ReasonCountOne", "Wire_ClearConfirm", "Wire_ClearText", "Menu_NoDismantle", "Menu_NoBuild",
        "Menu_NoUse" }) do
        if not (CH["IGUI_MBLD_" .. k] and EN["IGUI_MBLD_" .. k]) then newKeys[#newKeys + 1] = k end
    end
    check(#newKeys == 0, "這次新增的鍵 EN、CH 都有 " .. table.concat(newKeys, " "))

    -- 第 10 條：英文數量是 1 時不寫成複數
    local realGetText = getText
    getText = function(k, ...)
        local a = { ... }
        return #a == 0 and k or k .. "(" .. table.concat(a, ",") .. ")"
    end
    local one = Messages.reasons({ SAME_TILE = 1, OCCUPIED = 2 })
    check(one[1] == "IGUI_MBLD_ReasonCount(2,IGUI_MBLD_Refuse_OCCUPIED)"
        and one[2] == "IGUI_MBLD_ReasonCountOne(1,IGUI_MBLD_Refuse_SAME_TILE)"
        and EN.IGUI_MBLD_ReasonCountOne == "1 tile: %2" and not EN.IGUI_MBLD_Source_Disabled:find("%1 sources", 1, true)
        and EN.IGUI_MBLD_Source_Disabled:find("%1", 1, true) and EN.IGUI_MBLD_Source_Disabled:find("%2", 1, true),
        "英文單數：1 格用 ReasonCountOne（「1 tile」）；停用來源的數量改成標籤形式，不會出現「1 sources」")

    -- 第 2 條：「全部拔掉」先確認、寫出盞數；確認前不送
    local realUI, realJoy, realClient, realSCC = MinidoracatUI, JoypadState, isClient, sendClientCommand
    local realCell, realInst, realSpecific, realCore = getCell, instanceof, getSpecificPlayer, getCore
    local realCM, realWOCM, realJoyData = ISContextMenu, ISWorldObjectContextMenu, getJoypadData
    JoypadState = { players = {} }
    local shown, closed
    MinidoracatUI = { v1 = { CAPABILITIES = { dialog = true }, Dialog = {
        show = function(o) shown = o return o end,
        close = function(d, ok)
            closed = true
            d.onResult(ok)
        end } } }
    local sent, sentQ = {}, nil
    isClient = function() return true end
    sendClientCommand = function(_, _, _, a)
        sent[#sent + 1] = a.op or "query"
        sentQ = a.q
    end
    local m = { player = {}, pn = 0, sw = { x = 1, y = 2, z = 0, e = "sw_0" }, nL = 3, marked = {}, cand = {}, pick = {} }
    Wiring.mode = m
    local d = Wiring.confirmClear()
    check(d ~= nil and #sent == 0 and shown.danger == true and shown.modal == false and shown.anchor == "mouse"
        and shown.title == "IGUI_MBLD_Wire_ClearConfirm(3)" and shown.confirmText == "IGUI_MBLD_Wire_Clear",
        "全部拔掉：先跳危險樣式、不擋操作、開在游標旁的確認框，標題寫出 3 盞；確認前不送拔線請求")
    check(Wiring.confirmClear() == nil and #sent == 0, "確認框開著時再按一次：不開第二個、不送")
    shown.onResult(false)
    check(#sent == 0 and m.confirm == nil, "按取消：不送")
    Wiring.confirmClear()
    shown.onResult(true)
    check(#sent == 1 and sent[1] == "clear", "按確認：送一次 clear")
    m.busy = nil
    Wiring.confirmClear()
    Wiring.close()
    check(closed and #sent == 1 and Wiring.mode == nil, "確認框開著時離開接線模式：框跟著關、不送")
    local m2 = { player = {}, pn = 0, sw = m.sw, nL = 2, marked = {}, cand = {}, pick = {} }
    Wiring.mode = m2
    Wiring.confirmClear()
    Wiring.mode = nil
    shown.onResult(true)
    check(#sent == 1, "接線模式已經換掉才按確認：不送（不會拔到別條線路）")

    -- 第 3 條：世界上的標記每種都有圖示（同一格兩個時往右排開；找不到物件的不畫）
    local function lsw(name, lit)
        local props = { has = function(_, k) return lit and (k == "lightR" or k == "IsMoveAble") end }
        return { getSprite = function() return { getName = function() return name end, getProperties = function() return props end } end,
            setHighlighted = function() end, setHighlightColor = function() end, setOutlineHighlight = function() end,
            setOutlineHighlightCol = function() end, hasModData = function() return false end }
    end
    local objs = { ["1,2,0"] = { lsw("sw_0") }, ["3,2,0"] = { lsw("la_0"), lsw("lb_0") }, ["4,2,0"] = { lsw("lc_0", true) } }
    local function sqAt(x, y, z)
        local l = objs[x .. "," .. y .. "," .. z]
        return l and { getObjects = function() return { size = function() return #l end, get = function(_, i) return l[i + 1] end } end,
            getX = function() return x end, getY = function() return y end, getZ = function() return z end }
    end
    getCell = function() return { getGridSquare = function(_, x, y, z) return sqAt(x, y, z) end } end
    instanceof = function(_, c) return c == "IsoLightSwitch" end
    local m3 = { player = {}, pn = 0, sw = m.sw, marked = {}, cand = {}, pick = {} }
    Wiring.mode = m3
    Wiring.apply(m3, { id = 1, s = { m.sw }, l = { { x = 3, y = 2, z = 0, e = "la_0" } }, cand = {
        { x = 3, y = 2, z = 0, e = "la_0", k = "l", c = 1 }, { x = 3, y = 2, z = 0, e = "lb_0", k = "l" },
        { x = 4, y = 2, z = 0, e = "lc_0", k = "l", c = 9 }, { x = 9, y = 9, z = 0, e = "gone_0", k = "l" } } })
    local ic = m3.icons or { n = 0 }
    local kinds = {}
    for i = 1, ic.n do kinds[#kinds + 1] = ic[i].k .. "@" .. ic[i].x .. "+" .. ic[i].dx end
    check(table.concat(kinds, " ") == "this@1+0 wired@3+0 free@3+20 other@4+0",
        "接線標記：這個開關、已接、可接、別條線路各一個圖示；同一格兩個往右排開，沒載入的不畫（" .. table.concat(kinds, " ") .. "）")
    Wiring.mode = nil

    -- 第 4 條：右鍵選單不能選的列，標籤後面加狀態字
    local function fakeMenu()
        local mn = { options = {} }
        function mn:addOption(name, target, fn, p1, p2)
            local o = { name = name, target = target, onSelect = fn, param1 = p1, param2 = p2 }
            self.options[#self.options + 1] = o
            return o
        end
        function mn:addSubMenu(o, s) o.subOption = s end
        function mn:calcWidth() return 100 end
        function mn:setWidth(w) self.width = w end
        return mn
    end
    ISContextMenu = { getNew = function() return fakeMenu() end }
    ISWorldObjectContextMenu = { addToolTip = function() return {} end, setTest = function() end, onToggleLight = function() end }
    getSpecificPlayer = function() return { getVehicle = function() return nil end } end
    local color = { getR = function() return 1 end, getG = function() return 0 end, getB = function() return 0 end }
    getCore = function() return { getGoodHighlitedColor = function() return color end,
        getBadHighlitedColor = function() return color end } end
    getJoypadData = function() return nil end
    local realTargets, realTiles, realCheck = Menu.targets, Menu.tiles, B.Dismantle.check
    local realOf, realRepl, realCancels = B.Names.of, B.Dismantle.replaceableOld, B.Cursor.cancels
    Menu.targets = function()
        return { { obj = {}, kind = "wall", name = "ok_0" }, { obj = {}, kind = "fence", name = "bad_0" } },
            { { obj = {}, kind = "furniture", name = "chair_0", route = "pickup" } }
    end
    Menu.tiles = function() return {} end
    B.Dismantle.check = function(_, kind) if kind == "fence" then return "NOT_EMPTY" end return nil end
    B.Names.of = function(n) return n end
    B.Dismantle.replaceableOld = function() return false end
    B.Cursor.cancels = function() return 0 end
    local ctx = fakeMenu()
    local okFill, errFill = pcall(Menu.fill, 0, ctx, {}, false)
    local sub = ctx.options[1] and ctx.options[1].subOption
    local so = sub and sub.options or {}
    check(okFill and #so == 3 and so[1].name == "ok_0" and not so[1].notAvailable
        and so[2].name == "IGUI_MBLD_Menu_NoDismantle(bad_0)" and so[2].notAvailable
        and so[3].name == "IGUI_MBLD_Menu_NoDismantle(chair_0)" and so[3].notAvailable,
        "拆除選單：能拆的照舊，不能拆與不歸本工具拆的標籤後面加「（不能拆）」（" .. tostring(errFill) .. "）")
    Menu.targets, Menu.tiles, B.Dismantle.check = realTargets, realTiles, realCheck
    B.Names.of, B.Dismantle.replaceableOld, B.Cursor.cancels = realOf, realRepl, realCancels
    -- 燈的「線路」子選單：回覆前拔線、打開接線模式標「（不能選）」，接著開關後拿掉
    local lampObjs = { { getSquare = function() return sqAt(4, 2, 0) end } }
    objs["4,2,0"][1].getSquare = lampObjs[1].getSquare
    local function lampSub()
        local c = fakeMenu()
        Wiring.fill(0, c, lampObjs, false)
        return c.options[1] and c.options[1].subOption
    end
    local ls = lampSub()
    local before = ls and ls.options[2].name == "IGUI_MBLD_Menu_NoUse(IGUI_MBLD_Menu_Unplug)"
        and ls.options[3].name == "IGUI_MBLD_Menu_NoUse(IGUI_MBLD_Menu_OpenWiring)"
    Wiring.onServerCommand("circuit", { q = sentQ, s = {}, l = {} })
    local notWired = ls and ls.options[2].name == "IGUI_MBLD_Menu_NoUse(IGUI_MBLD_Menu_Unplug)" and ls.options[2].notAvailable
    ls = lampSub()
    Wiring.onServerCommand("circuit", { q = sentQ, s = { m.sw }, l = {} })
    check(before and notWired and ls.options[2].name == "IGUI_MBLD_Menu_Unplug" and ls.options[2].notAvailable == false
        and ls.options[3].name == "IGUI_MBLD_Menu_OpenWiring",
        "燈的線路子選單：回覆前與沒接線時標「（不能選）」，接著開關後拿掉")

    MinidoracatUI, JoypadState, isClient, sendClientCommand = realUI, realJoy, realClient, realSCC
    getCell, instanceof, getSpecificPlayer, getCore = realCell, realInst, realSpecific, realCore
    ISContextMenu, ISWorldObjectContextMenu, getJoypadData = realCM, realWOCM, realJoyData
    getText = realGetText

    -- 第 6 條：管理面板關掉再開，草稿留著（reload(true)）；「還原」仍是丟掉草稿的地方
    local W = B.Window
    local realWui, realCan, realAsk, realWin = W.ui, Admin.canManage, Admin.askLedgers, Admin.win
    local fakeUI = {}
    W.ui = function() return fakeUI end
    Admin.canManage = function() return true end
    Admin.askLedgers = function() end
    local kept = "none"
    Admin.win = { UI = fakeUI, playerNum = 0, reload = function(_, keep) kept = keep end, setStatus = function() end,
        win = { getIsVisible = function() return false end, setVisible = function() end, bringToTop = function() end } }
    local opened = Admin.open(0)
    W.ui, Admin.canManage, Admin.askLedgers, Admin.win = realWui, realCan, realAsk, realWin
    local f = assert(io.open(MEDIA .. "/client/MinidoracatBuilder/Admin.lua", "rb"))
    local src = f:read("*a")
    f:close()
    check(opened == true and kept == true and src:find("onClick = function(t) t:reload() end", 1, true) ~= nil,
        "管理面板關掉再開：重讀時保留沒套用的草稿；「還原」鈕照舊丟掉草稿")
end)()

-- ===== 藍圖資料（Plan、PlanFile、PlanStore）=====
;(function()
    print("藍圖資料：Plan（片、上限、搬、轉、撤銷）、PlanFile（檔案、分享碼、存檔）、PlanStore")
    require "MinidoracatBuilder/Plan"
    require "MinidoracatBuilder/PlanFile"
    require "MinidoracatBuilder/PlanStore"
    local B = MinidoracatBuilder
    local Plan, PF, PS = B.Plan, B.PlanFile, B.PlanStore

    -- Plan.lua 不呼叫引擎：列出所有「名稱(」的全域呼叫，只准檔裡宣告的與 Lua 標準函式
    local function engineCalls(src)
        src = src:gsub("%-%-[^\n]*", ""):gsub('"[^"\n]*"', '""')
        local known = { select = 1, tostring = 1, pairs = 1, ipairs = 1, type = 1, error = 1, pcall = 1, ["function"] = 1,
            ["if"] = 1, ["while"] = 1, ["and"] = 1, ["or"] = 1, ["not"] = 1, ["return"] = 1, ["elseif"] = 1, ["in"] = 1 }
        for name in src:gmatch("local%s+function%s+([%a_][%w_]*)") do known[name] = 1 end
        for params in src:gmatch("function[^(\n]*%(([^)]*)%)") do
            for name in params:gmatch("[%a_][%w_]*") do known[name] = 1 end
        end
        local bad = {}
        for pre, name in src:gmatch("([^%w_%.:])([%a_][%w_]*)%s*%(") do
            if not known[name] then bad[#bad + 1] = name end
        end
        return bad
    end
    local fh = io.open(MEDIA .. "/client/MinidoracatBuilder/Plan.lua", "r")
    local planSrc = fh:read("a")
    fh:close()
    local calls = engineCalls(planSrc)
    check(#calls == 0, "Plan.lua 沒有任何引擎全域函式呼叫（" .. table.concat(calls, ",") .. "）")
    check(#engineCalls(planSrc .. "\nlocal x = getCore()\n") == 1, "植入：加一個 getCore() 會被抓到")

    -- 片的簽名（相對包圍盒的角），排序後比對兩張藍圖一不一樣
    local function sig(plan)
        local x0, y0, z0 = Plan.bounds(plan)
        local out = {}
        Plan.each(plan, function(p)
            out[#out + 1] = (p.x - x0) .. "," .. (p.y - y0) .. "," .. (p.z - z0) .. "," .. p.d .. "," .. p.o .. ","
                .. plan.items[p.it].id .. "," .. tostring(p.w)
        end)
        table.sort(out)
        return table.concat(out, "|")
    end

    do -- 加片、重複、上限
        local pl = Plan.new("  我的\t小屋  ")
        check(pl.name == "我的 小屋", "名稱：Tab 換空白、去頭尾空白")
        check(Plan.nameLen(Plan.cleanName(string.rep("字", 50))) == 40 and Plan.nameLen("ab字") == 3, "名稱超過 40 字截掉、中文一字算一字")
        local a = Plan.item(pl, "walls_01_4")
        check(Plan.item(pl, "walls_01_4", nil) == a and pl.nItems == 1, "同一個項目 ID 只有一個編號")
        local p1 = Plan.add(pl, 0, 0, 0, 1, 0, a)
        local _, why = Plan.add(pl, 0, 0, 0, 1, 0, a)
        check(p1 and why == "DUP", "同格、同項目、同朝向、同疊放：DUP")
        check(Plan.add(pl, 0, 0, 0, 1, 1, a) and Plan.add(pl, 0, 0, 0, 2, 0, a) and #Plan.at(pl, 0, 0, 0) == 3
            and #Plan.at(pl, 5, 5, 0) == 0 and pl.items[a].n == 3, "疊放或朝向不同不算重複；Plan.at 回那一格的片")
        check(Plan.add(pl, 63, 0, 0, 0, 0, a) ~= nil and select(2, Plan.add(pl, 64, 0, 0, 0, 0, a)) == "TOO_WIDE"
            and select(2, Plan.add(pl, -1, 0, 0, 0, 0, a)) == "TOO_WIDE" and select(2, Plan.add(pl, 0, 64, 0, 0, 0, a)) == "TOO_WIDE",
            "每邊 64 格：第 65 格 TOO_WIDE（兩個方向、往負的也算）")
        check(Plan.add(pl, 0, 0, 3, 0, 0, a) ~= nil and select(2, Plan.add(pl, 0, 0, 4, 0, 0, a)) == "TOO_HIGH"
            and select(2, Plan.add(pl, 0, 0, -1, 0, 0, a)) == "TOO_HIGH", "4 層：第 5 層 TOO_HIGH")
        local full = Plan.new("full")
        local f = Plan.item(full, "floor_01_0")
        for y = 0, 63 do for x = 0, 63 do Plan.add(full, x, y, 0, 0, 0, f) end end
        local more = Plan.item(full, "floor_01_1")
        check(full.n == 4096 and select(2, Plan.add(full, 0, 0, 0, 0, 0, more)) == "FULL", "4,096 片後再加：FULL")
        check(#Plan.at(full, 40, 40, 0) == 1 and Plan.at(full, 40, 40, 0)[1].x == 40, "滿的藍圖照格子查得到")
        local cp, cwhy = Plan.copy(full, { Plan.at(full, 0, 0, 0)[1] }, 0, 0, 1)
        check(cp == nil and cwhy == "FULL" and full.n == 4096, "滿了再複製：整個不做、回 FULL")
    end

    do -- 搬、複製、轉向
        local pl = Plan.new("move")
        local a = Plan.item(pl, "walls_01_4")
        local p1, p2, p3 = Plan.add(pl, 0, 0, 0, 1, 0, a), Plan.add(pl, 1, 0, 0, 1, 0, a), Plan.add(pl, 2, 0, 0, 1, 0, a)
        local rev = pl.rev
        check(Plan.move(pl, { p1, p2 }, 0, 5, 0) == true and p1.y == 5 and p2.y == 5 and #Plan.at(pl, 0, 0, 0) == 0
            and Plan.at(pl, 0, 5, 0)[1] == p1 and pl.rev > rev, "搬兩片：位置與格子索引一起變、rev 加一")
        rev = pl.rev
        local ok, why = Plan.move(pl, { p1 }, 70, 0, 0)
        check(ok == nil and why == "TOO_WIDE" and p1.x == 0 and Plan.at(pl, 0, 5, 0)[1] == p1 and pl.rev == rev,
            "搬出每邊 64 格：整個不做、位置不變、rev 不變")
        ok, why = Plan.move(pl, { p1 }, 0, 0, 4)
        check(ok == nil and why == "TOO_HIGH" and p1.z == 0, "搬出 4 層：TOO_HIGH")
        check(Plan.move(pl, { p1, p2, p3 }, 1000, 0, 0) == true and p3.x == 1002, "整張一起搬多遠都可以")
        Plan.move(pl, { p1, p2, p3 }, -1000, 0, 0)
        local cp = Plan.copy(pl, { p1, p2, p3 }, 0, 1, 0)
        check(cp and #cp == 3 and pl.n == 6 and #Plan.at(pl, 2, 1, 0) == 1, "複製三片到下一格")
        check(#Plan.copy(pl, { p1 }, 0, 0, 0) == 0 and pl.n == 6, "複製到原地：一模一样的略過")
        -- 搬到和別片完全一樣的位置：合成一片
        local n0 = pl.n
        Plan.move(pl, { p3 }, 0, 1, 0)
        check(pl.n == n0 - 1 and #Plan.at(pl, 2, 1, 0) == 1, "搬到一模一樣的片上：合成一片")

        local r = Plan.new("rot")
        local w, chair = Plan.item(r, "walls_01_4"), Plan.item(r, "chair")
        local q1, q2, q3 = Plan.add(r, 0, 0, 0, 1, 0, w), Plan.add(r, 2, 0, 0, 4, 0, w), Plan.add(r, 0, 1, 0, 2, 0, chair)
        local function turn(p, item)
            if item.id == "chair" then return nil end
            return p.d % 4 + 1, p.d == 4 and 1 or 0, 0
        end
        local stuck = Plan.rotate(r, { q1, q2, q3 }, turn)
        check(stuck == 1 and q1.x == 1 and q1.y == 0 and q1.d == 2 and q2.x == 2 and q2.y == 2 and q2.d == 1
            and q3.x == 0 and q3.y == 0 and q3.d == 2, "轉 90 度：位置繞包圍盒轉、朝向照 turnPiece、回 nil 的片朝向不換並計數")
        check(Plan.undo(r) and q1.x == 0 and q1.d == 1 and q2.x == 2 and q2.y == 0 and q2.d == 4 and q3.y == 1,
            "撤銷轉向：全部回原位")
    end

    do -- 撤銷、重做：50 步、只記差異、begin／commit
        local pl = Plan.new("undo")
        local a = Plan.item(pl, "floor_01_0")
        for i = 0, 59 do Plan.add(pl, i % 60 % 64, math.floor(i / 60), 0, 0, 0, a) end
        check(#pl._undo == 50, "60 步只留最近 50 步")
        local n = 0
        while Plan.undo(pl) do n = n + 1 end
        check(n == 50 and pl.n == 10, "撤銷 50 次、第 51 次回 false")
        n = 0
        while Plan.redo(pl) do n = n + 1 end
        check(n == 50 and pl.n == 60, "重做 50 次回到 60 片")
        local list = {}
        Plan.each(pl, function(p) if #list < 2 then list[#list + 1] = p end end)
        Plan.move(pl, list, 0, 1, 0)
        local step = pl._undo[#pl._undo]
        check(#step == 2 and step[1].k == 0 and step[1].a[2] == 0 and step[1].b[2] == 1, "一步只記動到的 2 片（改前、改後）")
        local rev = pl.rev
        Plan.begin(pl)
        for i = 0, 4 do Plan.add(pl, i, 5, 0, 0, 0, a) end
        check(Plan.undo(pl) == false, "拖到一半不能撤銷")
        Plan.commit(pl)
        check(pl.n == 65 and pl.rev > rev, "begin／commit 之間加了 5 片")
        Plan.undo(pl)
        check(pl.n == 60 and #Plan.at(pl, 0, 5, 0) == 0, "一次撤銷拿掉整次拖曳的 5 片")
        Plan.add(pl, 9, 9, 0, 0, 0, a)
        check(Plan.redo(pl) == false, "撤銷後做了新的修改：重做清空")
        local cnt = Plan.remove(pl, { Plan.at(pl, 9, 9, 0)[1] })
        check(cnt == 1 and Plan.undo(pl) and #Plan.at(pl, 9, 9, 0) == 1 and pl.items[a].n == 61, "拿掉再撤銷：片與項目片數回來")

        local rp = Plan.new("replace")
        local x, y = Plan.item(rp, "walls_a_1"), Plan.item(rp, "walls_b_1")
        Plan.add(rp, 0, 0, 0, 1, 0, x)
        Plan.add(rp, 1, 0, 0, 1, 0, x)
        Plan.add(rp, 1, 0, 0, 1, 0, y)
        local changed = Plan.replace(rp, x, "walls_b_1", { mod = "M" })
        check(changed == 2 and rp.n == 2 and rp.items[x].n == 0 and rp.items[y].n == 2, "全部換成：改指新項目，換完重複的合成一片")
        local z = select(1, Plan.replace(rp, y, "walls_c_1", { mod = "M", modName = "Mod C" }))
        check(z == 2 and rp.items[rp.nItems].id == "walls_c_1" and rp.items[rp.nItems].modName == "Mod C", "換成新的項目 ID：新增項目並帶來源")
        Plan.undo(rp)
        Plan.undo(rp)
        check(rp.n == 3 and rp.items[x].n == 2 and rp.items[y].n == 1, "撤銷兩次換成：回到原本三片")
    end

    -- 測試用的藍圖：帶空白的圖塊名、中文名稱、配方項目、疊放、兩層、負的相對座標、一排與一列
    local function sample()
        local pl = Plan.new("海邊 小屋")
        local w = Plan.item(pl, "edit_ddd_RUS_Forest Survival_01_64",
            { mod = "FSMod", modName = "Forest Survival", workshop = "123456", version = "1.2" })
        local rc = Plan.item(pl, "recipe:Base.RainCollector_Tarp")
        local f = Plan.item(pl, "floors_01_40")
        for x = -2, 7 do Plan.add(pl, x, 0, 0, 0, 0, f) end
        for y = 1, 5 do Plan.add(pl, -2, y, 0, 4, 0, w) end
        Plan.add(pl, 3, 3, 1, 0, 1, rc)
        Plan.add(pl, 3, 3, 1, 0, 0, rc)
        pl.ox, pl.oy, pl.oz = 100, 200, 0
        return pl
    end

    do -- 檔案來回
        local pl = sample()
        local text = PF.encode(pl)
        local back, why, ln = PF.decode(text)
        check(back ~= nil, "藍圖檔讀回（" .. tostring(why) .. " 第 " .. tostring(ln) .. " 行）")
        if back then
            check(PF.encode(back) == text and sig(back) == sig(pl) and back.name == "海邊 小屋" and back.n == 17,
                "存了再讀：內容與再存的文字完全一樣（帶空白的圖塊名、中文名稱、配方項目）")
            local fs = back.items[back._byId["edit_ddd_RUS_Forest Survival_01_64"]]
            check(fs.mod == "FSMod" and fs.modName == "Forest Survival" and fs.workshop == "123456" and fs.version == "1.2"
                and back.items[back._byId["floors_01_40"]].mod == nil, "項目的 MOD 來源讀回；原版的寫 - 讀回 nil")
            check(back.ox == 98 and back.oy == 200 and back.oz == 0 and Plan.bounds(back) == 0, "位置寫成包圍盒角的世界座標、片從 0 起算")
            check(#back._undo == 0 and back.rev == 0 and Plan.undo(back) == false, "讀回的藍圖沒有撤銷紀錄")
        end
        local empty = PF.decode(PF.encode(Plan.new("")))
        check(empty ~= nil and empty.n == 0, "空的藍圖也能存了再讀")
    end

    do -- 壞檔：每一種都整張拒收、回原因碼與行號、不丟 Lua 錯誤
        local good = table.concat({ "MBLDPLAN\t1", "name\tgood", "size\t2\t2\t1", "count\t3",
            "i\t1\t2\t-\t-\t-\t-\twalls_01_4", "i\t2\t1\t-\t-\t-\t-\trecipe:Base.RainCollector_Tarp",
            "p\t0\t0\t0\t1\t0\t1", "p\t1\t0\t0\t1\t0\t1", "p\t0\t1\t0\t0\t0\t2", "END" }, "\n") .. "\n"
        check(PF.decode(good) ~= nil, "範本檔讀得進來")
        local function with(n, line)
            local lines = {}
            for l in good:gmatch("[^\n]+") do lines[#lines + 1] = l end
            lines[n] = line
            local out = {}
            for i = 1, 10 do if lines[i] then out[#out + 1] = lines[i] end end
            return table.concat(out, "\n") .. "\n"
        end
        local function bad(text, code, line, label)
            local ok, plan, c, l = pcall(PF.decode, text)
            check(ok and plan == nil and c == code and l == line,
                "壞檔拒收：" .. label .. "（" .. tostring(c) .. "，第 " .. tostring(l) .. " 行）")
        end
        bad(with(10, false), "NO_END", 10, "缺 END")
        bad(good:gsub("\nEND\n$", "\n"):sub(1, -20), "FORMAT", 8, "寫到一半斷掉（最後一行只剩半行）")
        bad(with(1, "MBLDPLAN\t2"), "VERSION", 1, "版本不認得")
        bad(with(7, "p\t0\t0\t0\t1\t0"), "FORMAT", 7, "片行欄位少一個")
        bad(with(5, "i\t1\t2\t-\t-\t-\twalls_01_4"), "FORMAT", 5, "項目行欄位少一個")
        bad(with(8, "p\t2\t0\t0\t1\t0\t1"), "RANGE", 8, "座標超出 size")
        bad(with(3, "size\t65\t2\t1"), "RANGE", 3, "寬超過 64")
        bad(with(3, "size\t2\t2\t5"), "RANGE", 3, "超過 4 層")
        bad(with(9, "p\t0\t1\t1\t0\t0\t2"), "RANGE", 9, "層超出 size")
        bad(with(7, "p\t0\t0\t0\t6\t0\t1"), "RANGE", 7, "朝向超出 0..5")
        bad(with(4, "count\t4"), "COUNT", 10, "count 比片多")
        bad(with(4, "count\t2"), "COUNT", 9, "片比 count 多")
        bad(with(5, "i\t1\t3\t-\t-\t-\t-\twalls_01_4"), "COUNT", 5, "項目行的片數不符")
        bad(with(9, "p\t0\t1\t0\t0\t0\t3"), "ITEM", 9, "項目編號不存在")
        bad(with(6, "i\t3\t1\t-\t-\t-\t-\tx_1"), "ITEM", 6, "項目編號跳號")
        bad(with(6, "i\t2\t1\t-\t-\t-\t-\twalls_01_4"), "ITEM", 6, "同一個項目 ID 寫兩次")
        bad(with(4, "count\t4097"), "FULL", 4, "超過 4,096 片")
        bad(with(2, "name\t" .. string.rep("字", 41)), "NAME", 2, "名稱超過 40 字")
        bad(with(8, "p\t0\t0\t0\t1\t0\t1"), "DUP", 8, "重複的片")
        bad(with(7, "p\t0\tx\t0\t1\t0\t1"), "FORMAT", 7, "座標不是整數")
        bad(with(7, "hello"), "FORMAT", 7, "看不懂的行")
        bad(with(5, "i\t1\t2\t-\tabc\t-\t-\twalls_01_4"), "FORMAT", 5, "工作坊編號不是數字")
        check(PF.decode(good .. "x\n" .. string.rep("y", 5000) .. "\n") ~= nil, "END 之後不讀（審查 C11）")
        bad(with(7, "p\t0\t0\t0\t1\t0\t1\t" .. string.rep("9", 700)), "TOO_BIG", 7, "一行超過上限（審查 C11）")
        bad("MBLDPLAN\tdeleted\nEND\n", "DELETED", 1, "已刪除的檔")
        bad("", "NO_END", 1, "空字串")
        bad("PK\3\4\0\0garbage", "FORMAT", 1, "不是藍圖檔")
        bad(nil, "FORMAT", 0, "不是字串")
        local manyLines = { "MBLDPLAN\t1", "name\tbig", "size\t64\t64\t2", "count\t4096", "i\t1\t4097\t-\t-\t-\t-\tf_1" }
        check(select(2, PF.decode(table.concat(manyLines, "\n"))) == "RANGE", "壞檔拒收：項目片數超過 4,096")
        local junkOk = true
        for i = 1, 200 do
            local s = {}
            for k = 1, (i * 7) % 90 do s[k] = string.char((i * 31 + k * 17) % 256) end
            if not pcall(PF.decode, "MBLDPLAN\t1\n" .. table.concat(s)) then junkOk = false end
        end
        check(junkOk, "亂碼不會讓 decode 丟 Lua 錯誤")
    end

    do -- 分享碼
        local pl = sample()
        local code = PF.share(pl, true)
        check(code:match("^[A-Za-z0-9:%-/()%.%+=,;]+$") ~= nil, "分享碼只用英數與 :-/().+=,; （剪貼簿、聊天室貼得過去）")
        local back, why, at = PF.unshare(code)
        check(back ~= nil and sig(back) == sig(pl) and back.name == pl.name and back.ox == 98 and back.oy == 200,
            "分享碼來回一致、帶位置（" .. tostring(why) .. " " .. tostring(at) .. "）")
        check(back and back.items[back._byId["edit_ddd_RUS_Forest Survival_01_64"]].workshop == "123456", "分享碼帶項目的來源 MOD")
        local noPos = PF.unshare(PF.share(pl, false))
        check(noPos and noPos.ox == nil and sig(noPos) == sig(pl), "不帶位置的分享碼")
        check(PF.share(pl) == PF.share(pl, false), "省略 withPos＝不帶位置")
        check(code:find("0,0,10", 1, true) and code:find("0,1,-5", 1, true), "連續的一排與一列各寫成一段")
        local full = Plan.new("full")
        local f = Plan.item(full, "floor_01_0")
        for y = 0, 63 do for x = 0, 63 do Plan.add(full, x, y, 0, 0, 0, f) end end
        local big = PF.share(full, false)
        local fb = PF.unshare(big)
        check(#big < 1000 and fb and fb.n == 4096, "4,096 片的地板分享碼壓到 1,000 字以內並能還原（" .. #big .. " 字）")
        check(PF.unshare("  " .. code .. "\n") ~= nil, "前後多的空白、換行照收")
        local function rechk(s) -- 改內容後重算檢查碼（模擬故意改的人）
            local body = s:match("^(.*;)K%d+$")
            local h = 0
            for i = 1, #body do h = (h * 31 + body:byte(i)) % 9999991 end
            return body .. "K" .. h
        end
        local function rejects(s, want, label)
            local ok, p, c = pcall(PF.unshare, s)
            check(ok and p == nil and c == want, "壞分享碼拒收：" .. label .. "（" .. tostring(c) .. "）")
        end
        rejects(code:gsub("C17", "C18", 1), "CHECKSUM", "改了一個字")
        rejects(code:sub(1, #code - 20), "NO_END", "被截斷")
        rejects(rechk(code:gsub("C17", "C18", 1)), "COUNT", "改了片數並重算檢查碼")
        rejects(rechk(code:gsub(";0,0,10;", ";0,0,70;", 1)), "RANGE", "一排超出 64 格")
        rejects(rechk(code:gsub(";G(%d+),", ";G9,", 1)), "ITEM", "項目編號不存在")
        rejects(rechk(code:gsub("^MBLD1", "MBLD2")), "VERSION", "版本不認得")
        rejects(rechk(code:gsub(";N[^;]*", ";N<x>", 1)), "FORMAT", "名稱有不認得的字元")
        rejects(rechk(code:gsub(";N[^;]*", ";N" .. string.rep("A", 41), 1)), "NAME", "名稱超過 40 字")
        rejects(rechk(code:gsub(";0,0,10;", ";0,0,10;0,0,10;", 1)), "DUP", "同一排寫兩次")
        rejects("hello", "FORMAT", "不是分享碼")
        rejects(nil, "FORMAT", "不是字串")
    end

    do -- 車庫門的寬度 w：片、檔案、分享碼
        local pl = Plan.new("garage")
        local g, f = Plan.item(pl, "garage_01_0"), Plan.item(pl, "floors_01_40")
        local d1 = Plan.add(pl, 0, 0, 0, 1, 0, g, 5)
        check(d1 and d1.w == 5 and select(2, Plan.add(pl, 0, 0, 0, 1, 0, g, 7)) == "DUP", "車庫門帶寬度；同格同門不同寬度也算重複")
        local badW = true
        for _, w in ipairs({ 0, 1, 65, 2.5, "3", -4 }) do
            local p, why = Plan.add(pl, 9, 9, 0, 1, 0, g, w)
            if p or why ~= "RANGE" then badW = false end
        end
        check(badW and #Plan.at(pl, 9, 9, 0) == 0, "不合格的寬度（0、1、65、2.5、字串、負數）：RANGE")
        local d2, d3 = Plan.add(pl, 1, 0, 0, 1, 0, g, 5), Plan.add(pl, 2, 0, 0, 1, 0, g, 3)
        for x = 0, 3 do Plan.add(pl, x, 1, 0, 0, 0, f) end
        check(Plan.add(pl, 5, 5, 0, 0, 0, f, nil).w == nil and Plan.at(pl, 0, 1, 0)[1].w == nil, "沒給寬度的片是 nil")
        Plan.remove(pl, { Plan.at(pl, 5, 5, 0)[1] })
        local cp = Plan.copy(pl, { d1 }, 0, 3, 0)
        Plan.move(pl, { d2 }, 0, 4, 0)
        check(cp[1].w == 5 and d2.w == 5 and d2.y == 4, "複製、搬：寬度跟著")
        Plan.rotate(pl, { d1, d3 }, function(p) return p.d % 4 + 1, 0, 0 end)
        check(d1.w == 5 and d3.w == 3, "轉向：寬度不變")
        Plan.undo(pl)
        Plan.undo(pl)
        Plan.undo(pl)
        check(d1.w == 5 and d2.w == 5 and d2.y == 0 and #Plan.at(pl, 0, 3, 0) == 0, "撤銷：寬度不變、片回原位")
        local rp = Plan.new("rp")
        local a = Plan.item(rp, "garage_01_0")
        local rd = Plan.add(rp, 0, 0, 0, 1, 0, a, 6)
        Plan.replace(rp, a, "garage_02_0")
        check(rd.w == 6 and rp.items[rd.it].id == "garage_02_0", "全部換成：寬度保留")

        local text = PF.encode(pl)
        local fieldsOk, doors, floors = true, 0, 0
        for line in text:gmatch("[^\n]+") do
            if line:sub(1, 2) == "p\t" then
                local tabs, it = select(2, line:gsub("\t", "")), line:match("^p\t%d+\t%d+\t%d+\t%d+\t%d+\t(%d+)")
                if it == "1" then doors = doors + 1 elseif it == "2" then floors = floors + 1 end
                if (it == "1" and tabs ~= 7) or (it == "2" and tabs ~= 6) then fieldsOk = false end
            end
        end
        check(fieldsOk and doors == 3 and floors == 4 and text:find("\np\t0\t0\t0\t1\t0\t1\t5\n", 1, true) ~= nil,
            "存檔：車庫門的 p 行多第 7 欄寬度，其他片不多欄")
        local back = PF.decode(text)
        check(back and sig(back) == sig(pl) and PF.encode(back) == text, "帶寬度的藍圖存了再讀：寬度相同")
        local code = PF.share(pl, false)
        check(code:find(";G1,1,0,0,5;", 1, true) ~= nil and code:find(";G1,1,0,0,3;", 1, true) ~= nil, "分享碼：寬度寫在組頭，不同寬度分組")
        local sb = PF.unshare(code)
        check(sb and sig(sb) == sig(pl), "帶寬度的分享碼來回：寬度相同")

        local one = Plan.new("one")
        Plan.add(one, 0, 0, 0, 1, 0, Plan.item(one, "garage_01_0"), 5)
        local good = PF.encode(one)
        local function badFile(wtxt, want)
            local ok, p, c, l = pcall(PF.decode, (good:gsub("(p\t[^\n]*)\t5\n", "%1\t" .. wtxt .. "\n")))
            check(ok and p == nil and c == want and l == 6, "壞檔拒收：寬度 " .. wtxt .. "（" .. tostring(c) .. "，第 " .. tostring(l) .. " 行）")
        end
        badFile("0", "RANGE")
        badFile("65", "RANGE")
        badFile("x", "FORMAT")
        local sc = PF.share(one, false)
        local function rechk(s)
            local body = s:match("^(.*;)K%d+$")
            local h = 0
            for i = 1, #body do h = (h * 31 + body:byte(i)) % 9999991 end
            return body .. "K" .. h
        end
        local function badCode(wtxt, want)
            local ok, p, c = pcall(PF.unshare, rechk((sc:gsub(";G1,1,0,0,5;", ";G1,1,0,0," .. wtxt .. ";", 1))))
            check(ok and p == nil and c == want, "壞分享碼拒收：寬度 " .. wtxt .. "（" .. tostring(c) .. "）")
        end
        badCode("0", "RANGE")
        badCode("65", "RANGE")
        badCode("x", "FORMAT")
    end

    do -- 分享碼的 =uXXXX 代理對要成對（審查 residual）：模擬 Kahlua 的 string.char 收得下 > 255 的字碼
        local pl = sample()
        local code = PF.share(pl)
        local function withName(n)
            local body = code:gsub("^MBLD1;N[^;]*;", "MBLD1;N" .. n .. ";", 1):match("^(.*;)K%d+$")
            local h = 0
            for i = 1, #body do h = (h * 31 + body:byte(i)) % 9999991 end
            return body .. "K" .. h
        end
        local realChar = string.char
        string.char = function(...)
            local out = {}
            for i, c in ipairs({ ... }) do out[i] = c > 255 and "?" or realChar(c) end
            return table.concat(out)
        end
        local okLone, p1, c1 = pcall(PF.unshare, withName("ab=uD800"))
        local okLow, p2, c2 = pcall(PF.unshare, withName("ab=uDC00cd"))
        local okPair, p3 = pcall(PF.unshare, withName("ab=uD83D=uDE00"))
        string.char = realChar
        check(okLone and p1 == nil and c1 == "FORMAT" and okLow and p2 == nil and c2 == "FORMAT",
            "分享碼帶單獨的代理對：拒收、回格式不對（" .. tostring(c1) .. "／" .. tostring(c2) .. "）")
        check(okPair and p3 ~= nil and p3.name == "ab??", "成對的代理對（emoji）照收")
    end

    -- 假磁碟：照引擎語意（getFileReader 打不開回 nil、寫入失敗不丟錯；listFiles 只列檔名）
    local realReader, realWriter, realList = getFileReader, getFileWriter, listFilesInZomboidLuaDirectory
    local realWorld, realCore, realInfo, realByFile = getWorld, getCore, getModInfoByID, Sources.byFile
    -- 寫入照 FileWriter：非附加一開檔就清空，寫多少進多少。crash＝{ at＝第幾次開檔 或 match＝路徑結尾, keep＝那次只寫進
    -- 幾個位元組 }：那次之後程式等於當掉，再也寫不進任何東西（測試把 crash 設回 nil＝重開遊戲）。
    -- 讀取照 InputStreamReader：檔尾殘缺的 UTF-8 字解成 U+FFFD
    local disk, dropWrites, crash = {}, false, nil
    local readerOpens, readLines = 0, 0
    getFileWriter = function(p, _, append)
        local idle = { write = function() end, close = function() end }
        if crash then
            crash.n = crash.n + 1
            if crash.dead then return idle end
        end
        if not append then disk[p] = "" end
        local cut = crash and (crash.n == crash.at or (crash.match ~= nil and p:sub(-#crash.match) == crash.match))
            and crash.keep
        return { write = function(_, s)
            if dropWrites or (crash and crash.dead) then return end
            if cut then
                s = s:sub(1, cut)
                crash.dead = true
            end
            disk[p] = (disk[p] or "") .. s
        end, close = function() end }
    end
    local function decodeTail(s)
        local k = #s
        while k > 1 and #s - k < 3 and s:byte(k) >= 128 and s:byte(k) < 192 do k = k - 1 end
        local c = s:byte(k)
        if not c then return s end
        local need = (c >= 240 and 4) or (c >= 224 and 3) or (c >= 192 and 2) or 1
        if need > 1 and #s - k + 1 < need then return s:sub(1, k - 1) .. "\239\191\189" end
        return s
    end
    getFileReader = function(p)
        if disk[p] == nil then return nil end
        readerOpens = readerOpens + 1
        local lines, i = {}, 0
        for l in decodeTail(disk[p]):gmatch("[^\n]+") do lines[#lines + 1] = l end
        return { readLine = function() i = i + 1; readLines = readLines + 1; return lines[i] end, close = function() end }
    end
    listFilesInZomboidLuaDirectory = function(dir)
        local names = {}
        for p in pairs(disk) do
            local name = p:sub(#dir + 2)
            if p:sub(1, #dir + 1) == dir .. "/" and not name:find("/", 1, true) then names[#names + 1] = name end
        end
        table.sort(names)
        return javaList(names)
    end
    local function has(list, x)
        for _, v in ipairs(list) do if v == x then return true end end
        return false
    end

    do -- 存檔、讀回比對、刪除、改名、複製
        local pl = sample()
        check(PF.fileName("我的小屋 Big House!") == "bighouse.txt" and PF.fileName("我的小屋") == "plan.txt", "檔名只留英數、轉小寫；沒有英數用 plan")
        check(PF.save(pl, "bighouse.txt") == true and pl.file == "bighouse.txt"
            and disk["MinidoracatBuilder/plans/bighouse.txt"] == PF.encode(pl)
            and disk["MinidoracatBuilder/plans/bighouse.cfg"] == PF.encode(pl), "存檔：寫進 plans 資料夾（另有 .cfg 備份）、記住檔名")
        disk["MinidoracatBuilder/plans/notes.md"] = "x"
        disk["MinidoracatBuilder/plans/a b.txt"] = "x"
        disk["MinidoracatBuilder/plans/House (1).TXT"] = "x"
        local listed, skipped = PF.list()
        check(#listed == 1 and listed[1] == "bighouse.txt", "列清單只列英數檔名的 .txt（備份檔不列）")
        check(skipped == 2, "列清單回略過的 .txt 檔數（審查 K2：a b.txt、House (1).TXT；.md、.cfg 不算）")
        disk["MinidoracatBuilder/plans/a b.txt"], disk["MinidoracatBuilder/plans/House (1).TXT"] = nil, nil
        local h = PF.head("bighouse.txt")
        check(h and h.name == "海邊 小屋" and h.n == 17 and h.w == 10 and h.h == 6 and h.levels == 2 and #h.items == 3
            and h.items[1].modName == "Forest Survival" and h.items[1].n == 5, "讀檔頭：名稱、大小、片數、各項目與來源")
        local back = PF.load("bighouse.txt")
        check(back and back.file == "bighouse.txt" and sig(back) == sig(pl), "讀整份")
        check(PF.fileName("Big House") == "bighouse2.txt", "撞名加編號")
        dropWrites = true
        local ok, why = PF.save(pl, "other.txt")
        dropWrites = false
        check(ok == nil and why == "WRITE" and disk["MinidoracatBuilder/plans/other.txt"] == nil, "寫入沒進檔（引擎不丟錯）：讀回比對，回 WRITE")
        disk["MinidoracatBuilder/plans/cut.txt"] = PF.encode(pl):gsub("END\n$", "")
        check(select(2, PF.load("cut.txt")) == "NO_END", "沒有 END 的檔不用")
        check(select(2, PF.load("../x.txt")) == "FILE" and select(2, PF.save(pl, "a b.txt")) == "FILE"
            and select(2, PF.load("none.txt")) == "NO_FILE", "檔名不合格、檔案不存在：拒絕")
        check(PF.remove("bighouse.txt") == true and not has(PF.list(), "bighouse.txt")
            and select(2, PF.load("bighouse.txt")) == "DELETED" and PF.head("bighouse.txt") == nil,
            "刪除：列清單看不到、讀不到")
        check(PF.fileName("Big House") == "bighouse.txt", "刪掉的檔名可以再用")
        PF.save(pl, "bighouse.txt")
        local nf = PF.rename("bighouse.txt", "Small Hut")
        local list = PF.list()
        check(nf == "smallhut.txt" and has(list, "smallhut.txt") and not has(list, "bighouse.txt")
            and PF.load("smallhut.txt").name == "Small Hut", "改名：寫新檔、舊檔標成刪除")
        check(PF.rename("smallhut.txt", "small hut") == "smallhut.txt" and PF.load("smallhut.txt").name == "small hut",
            "改名後檔名一樣：直接改寫同一個檔")
        local dup = PF.duplicate("smallhut.txt")
        check(dup == "smallhut2.txt" and has(PF.list(), "smallhut.txt") and PF.load(dup).name == "small hut", "複製一份：新檔名、同名稱")
        check(PF.duplicate("smallhut.txt", "Copy") == "copy.txt", "複製時給新名稱")
    end

    do -- 存檔寫到一半斷掉（審查 C1）：任何時間點都留得住完整的一版；刪除不會從備份復活
        local P = "MinidoracatBuilder/plans/"
        local old, new = sample(), sample()
        old.name, new.name = "old one", "new one"
        local function after(at, keep, act)
            disk[P .. "crash.txt"], disk[P .. "crash.cfg"] = nil, nil
            PF.save(old, "crash.txt")
            crash = { at = at, keep = keep, n = 0 }
            act()
            crash = nil
            local p, why = PF.load("crash.txt")
            return p and p.name or why
        end
        local half = math.floor(#PF.encode(new) / 2)
        check(after(1, 0, function() PF.save(new, "crash.txt") end) == "old one"
            and after(1, half, function() PF.save(new, "crash.txt") end) == "old one",
            "寫備份檔時斷掉（一開檔就清空、只寫進一半）：讀回上一版")
        check(after(2, 0, function() PF.save(new, "crash.txt") end) == "new one" and has(PF.list(), "crash.txt")
            and after(2, half, function() PF.save(new, "crash.txt") end) == "new one",
            "寫正式檔時斷掉（一開檔就清空、只寫進一半）：從備份讀回新版、列清單照列")
        check(disk[P .. "crash.txt"] == PF.encode(new), "從備份讀回後把正式檔修好")
        check(after(2, 0, function() PF.remove("crash.txt") end) == "DELETED" and not has(PF.list(), "crash.txt")
            and after(2, 6, function() PF.remove("crash.txt") end) == "DELETED",
            "刪除寫到一半斷掉：照樣是刪除，不從備份復活")
        PF.save(old, "crash.txt")
        disk[P .. "crash.txt"] = "MBLDPLAN\t1\nname\tsomething else\n"
        check(select(2, PF.load("crash.txt")) == "NO_END" and disk[P .. "crash.txt"] == "MBLDPLAN\t1\nname\tsomething else\n",
            "正式檔被換成別的壞檔（不是備份的開頭）：照樣回錯、不拿備份蓋掉")
        disk[P .. "crash.txt"], disk[P .. "crash.cfg"] = nil, nil
    end

    do -- 審查第 2 輪 PD1–PD3：連續兩次存檔失敗、斷在中文字中間、沒有備份的壞檔
        local P = "MinidoracatBuilder/plans/"
        local v1, v2, v3 = sample(), sample(), sample()
        v1.name, v2.name, v3.name = "v one", "v two", "v three"
        local function fresh()
            disk[P .. "twice.txt"], disk[P .. "twice.cfg"] = nil, nil
            PF.save(v1, "twice.txt")
            crash = { at = 2, keep = 40, n = 0 }
            PF.save(v2, "twice.txt") -- 備份寫好、正式檔斷在一半，而且沒有重讀
        end
        local function name()
            local p, why = PF.load("twice.txt")
            return p and p.name or why
        end
        fresh()
        crash = { match = ".cfg", keep = 10, n = 0 }
        PF.save(v3, "twice.txt")
        crash = nil
        check(name() == "v two", "連續兩次存檔失敗（先斷正式檔、再斷備份）：仍讀得回完整的一版（PD1）")
        check(PF.save(v3, "twice.txt") == true and disk[P .. "twice.txt"] == PF.encode(v3)
            and disk[P .. "twice.cfg"] == PF.encode(v3), "下一次存檔成功：正式檔與備份一致")
        fresh()
        crash = { match = ".txt", keep = 5, n = 0 }
        local okR, whyR = PF.save(v3, "twice.txt")
        crash = nil
        check(okR == nil and whyR == "WRITE" and disk[P .. "twice.cfg"] == PF.encode(v2) and name() == "v two",
            "先修正式檔時又斷掉：回 WRITE、備份不動，讀得回完整的一版（PD1）")
        disk[P .. "twice.txt"], disk[P .. "twice.cfg"] = nil, nil

        local zh, zh2 = sample(), sample()
        zh.name, zh2.name = "中文舊", "中文新的名稱"
        PF.save(zh, "zh.txt")
        local text = PF.encode(zh2)
        local at = text:find("name\t", 1, true) + 5 + 3 -- 「文」的第 1 個位元組
        crash = { at = 2, keep = at, n = 0 }
        PF.save(zh2, "zh.txt")
        crash = nil
        local back = PF.load("zh.txt")
        check(back and back.name == "中文新的名稱" and disk[P .. "zh.txt"] == text,
            "正式檔斷在中文字中間（尾端讀成替代字元）：從備份讀回、修好正式檔（PD2）")
        local other = "MBLDPLAN\t1\nname\t別的" .. ("中"):sub(1, 1)
        disk[P .. "zh.txt"] = other
        check(select(2, PF.load("zh.txt")) == "NO_END" and disk[P .. "zh.txt"] == other,
            "尾端是替代字元、但內容不是備份的開頭：照樣回錯、不修（PD2）")
        disk[P .. "zh.txt"], disk[P .. "zh.cfg"] = nil, nil

        disk[P .. "junk.txt"] = "MBLDPLAN\t1\nhello\n" .. string.rep("x\n", 5000)
        readLines = 0
        check(select(2, PF.load("junk.txt")) == "FORMAT" and readLines <= 3,
            "沒有備份的壞檔：回錯、不把整份讀完（讀了 " .. readLines .. " 行，PD3）")
        disk[P .. "junk.txt"] = nil
    end

    do -- 讀檔有上限、END 之後不讀（審查 C11）；存得進去就讀得回來（審查 residual）
        local P = "MinidoracatBuilder/plans/"
        local pl = sample()
        local text = PF.encode(pl)
        local n = select(2, text:gsub("\n", "\n"))
        disk[P .. "tail.txt"] = text .. string.rep("x\n", 20000)
        readLines = 0
        check(PF.load("tail.txt") ~= nil and readLines <= n + 1, "END 後面接兩萬行：照讀、只讀到 END（讀了 " .. readLines .. " 行）")
        disk[P .. "tail.txt"] = text:gsub("\nEND\n$", "\n" .. string.rep("p\t0\t0\t0\t0\t0\t1\n", 9000) .. "END\n")
        readLines = 0
        local okBig, whyBig = PF.load("tail.txt")
        check(okBig == nil and whyBig ~= nil and readLines <= 8401, "超過行數上限的檔：拒收、最多讀 8,400 行（" .. tostring(whyBig) .. "）")
        disk[P .. "tail.txt"] = nil
        local long = Plan.new("long")
        Plan.add(long, 0, 0, 0, 0, 0, Plan.item(long, string.rep("w", 150)))
        check(select(2, PF.save(long, "long.txt")) == "TOO_BIG" and disk[P .. "long.txt"] == nil,
            "項目 ID 超過欄位上限：不存（存了會讀不回來）")
        local wide = Plan.new("wide")
        Plan.add(wide, 0, 0, 0, 0, 0, Plan.item(wide, "walls_01_4",
            { mod = string.rep("m", 200), modName = string.rep("n", 200), version = string.rep("v", 200), workshop = "123" }))
        local wb = PF.save(wide, "wide.txt") and PF.load("wide.txt")
        check(wb and #wb.items[1].mod == 128 and #wb.items[1].modName == 128, "MOD 資訊很長：截短後存，讀得回來")
    end

    do -- 檔名沒有上限（審查 C13）：純中文名稱的第 1,000、1,001 張照樣分得到檔名，而且不用逐一開檔
        local P = "MinidoracatBuilder/plans/"
        local tiny = Plan.new("中文藍圖")
        Plan.add(tiny, 0, 0, 0, 0, 0, Plan.item(tiny, "walls_01_4"))
        local body = PF.encode(tiny)
        for i = 1, 999 do disk[P .. "plan" .. (i > 1 and i or "") .. ".txt"] = body end
        readerOpens = 0
        local f1000 = PF.fileName("中文藍圖")
        local opens = readerOpens
        local ok1000 = f1000 and PF.save(tiny, f1000)
        local f1001 = PF.fileName("中文藍圖")
        local ok1001 = f1001 and PF.save(tiny, f1001)
        check(f1000 == "plan1000.txt" and ok1000 == true and f1001 == "plan1001.txt" and ok1001 == true and opens <= 1,
            "第 1,000、1,001 張純中文名稱的藍圖：plan1000.txt、plan1001.txt（取名時開了 " .. opens .. " 個檔）")
        for p in pairs(disk) do
            if p:sub(1, #P + 4) == P .. "plan" then disk[p] = nil end
        end
    end

    do -- 圖塊的來源 MOD
        local oldMap, oldOrder = spriteMap, spriteOrder
        world({ sprite("fs_tiles_01_3", MOD_ID_BASE + 3), sprite("walls_01_4", 10) })
        Sources.byFile = { [7001] = "FSMod" }
        getModInfoByID = function(id)
            if id ~= "FSMod" then return nil end
            return { getName = function() return "Forest Survival" end, getWorkshopID = function() return "123456" end,
                getModVersion = function() return "" end }
        end
        local s = PF.source("fs_tiles_01_3")
        check(s and s.mod == "FSMod" and s.modName == "Forest Survival" and s.workshop == "123456" and s.version == nil,
            "圖塊屬於哪個 MOD：ID、名稱、工作坊編號（版本空的回 nil）")
        check(PF.source("walls_01_4") == nil and PF.source("recipe:Base.RainCollector_Tarp") == nil and PF.source("none_01_1") == nil,
            "原版的圖、配方項目、沒有的圖：nil")
        spriteMap, spriteOrder = oldMap, oldOrder
    end

    do -- PlanStore
        local worldName, mode = "16-11-2026_10-00-00", "Sandbox"
        getWorld = function() return { getWorld = function() return worldName end } end
        getCore = function() return { getGameMode = function() return { toString = function() return mode end } end } end
        local sp = PS.worldId()
        worldName = "16-11-2026_10-00-01"
        local sp2 = PS.worldId()
        worldName, mode = "1.2.3.4_16261_abc", "Multiplayer"
        local mp = PS.worldId()
        worldName = "a_b"
        local u1 = PS.worldId()
        worldName = "a-b"
        local u2 = PS.worldId()
        check(sp:match("^[A-Za-z0-9_%-]+$") and mp:match("^[A-Za-z0-9_%-]+$") and sp ~= sp2 and sp ~= mp and u1 ~= u2,
            "worldId 只含英數與 - _，不同存檔、伺服器分得開（" .. sp .. "）")
        worldName, mode = "我的世界", "Sandbox"
        check(PS.worldId():match("^[A-Za-z0-9_%-]+$") ~= nil, "中文存檔名也只含英數與 - _")
        worldName = ".."
        check(not PS.worldId():find("..", 1, true), "存檔名是 .. 也不會變成路徑的 ..")
        worldName = string.rep("長", 30) .. "a"
        local long1 = PS.worldId()
        worldName = string.rep("長", 30) .. "b"
        local long2 = PS.worldId()
        check(#long1 <= 100 and long1:match("^[A-Za-z0-9_%-]+$") and long1 ~= long2, "很長的存檔名截到 100 字以內、接雜湊仍分得開")
        worldName = "我的世界"
        check(next(PS.load()) == nil, "沒有存過：空表")
        local st = { file = "smallhut.txt", ox = 98, oy = 200, oz = 0, hidden = true,
            boxes = { { x = 1, y = 2, z = 0, index = 3 } }, seen = { ["edit_ddd_RUS_Forest Survival_01_64"] = "MISSING" } }
        check(PS.save(st) == true, "存地上的藍圖")
        local got = PS.load()
        check(got.file == "smallhut.txt" and got.ox == 98 and got.oy == 200 and got.oz == 0 and got.hidden == true
            and got.boxes[1].index == 3 and got.seen["edit_ddd_RUS_Forest Survival_01_64"] == "MISSING", "讀回地上的藍圖")
        worldName = "other"
        check(next(PS.load()) == nil, "別的存檔看不到")
        worldName = "我的世界"
        local p = "MinidoracatBuilder/worlds/" .. PS.worldId() .. ".txt"
        local saved = disk[p]
        local st2 = { file = "other.txt", ox = 5, oy = 6, oz = 0, boxes = {}, seen = {} }
        crash = { at = 2, keep = 10, n = 0 }
        PS.save(st2)
        crash = nil
        check(PS.load().file == "other.txt", "地上藍圖的紀錄寫到一半斷掉：從備份讀回新的（審查 C1）")
        crash = { at = 1, keep = 0, n = 0 }
        PS.save(st)
        crash = nil
        check(PS.load().file == "other.txt", "寫備份時斷掉：讀回上一版")
        disk[p] = saved:gsub("END\n$", "")
        disk[p:sub(1, -5) .. ".cfg"] = disk[p]
        check(next(PS.load()) == nil, "正式檔與備份都沒有 END：當成沒有")
        dropWrites = true
        check(PS.save(st) == nil, "寫入沒進檔：讀回比對，回 nil")
        dropWrites = false
    end

    getFileReader, getFileWriter, listFilesInZomboidLuaDirectory = realReader, realWriter, realList
    getWorld, getCore, getModInfoByID, Sources.byFile = realWorld, realCore, realInfo, realByFile
end)()

-- ===== 放置中的按鍵、快選列、最近用的 =====
;(function()
    print("放置中的按鍵、快選列、最近用的（recent.txt、拆掉剛蓋的、吸管鍵、疊放鍵、換項目鍵、快選列跟著游標、右鍵取消）")
    local B = MinidoracatBuilder
    local W, R, H, C, Q, P = B.Window, B.Recent, B.Hotbar, B.Cursor, B.Queue, B.Place
    local real = { reader = getFileReader, writer = getFileWriter, cell = getCell, specific = getSpecificPlayer,
        ui = MinidoracatUI, panel = ISPanel, toast = B.Messages.toast, last = Q.last, undo = Q.undoLast,
        och = ISObjectClickHandler, current = H.current, get = C.get, setOf = W.setOf, swapTo = W.swapTo,
        pickSwap = W.pickSwap, v = W.v, tm = getTextManager, font = UIFont, top = getPlayerScreenTop,
        left = getPlayerScreenLeft, sw = getPlayerScreenWidth, sh = getPlayerScreenHeight, max = P.maxPerSquare,
        overlap = W.st.overlap, onEnd = C.onEnd }
    W.v = nil -- 這段不建視窗（syncEntry、refreshCats 只在視窗開著時動）

    -- 假磁碟：照引擎語意，打不開回 nil；寫入照覆寫／附加
    local disk
    getFileWriter = function(_, _, append)
        local buf = append and (disk or "") or ""
        return { write = function(_, s) buf = buf .. s end, close = function() disk = buf end }
    end
    getFileReader = function()
        if disk == nil then return nil end
        local lines, i = {}, 0
        for l in disk:gmatch("[^\n]+") do lines[#lines + 1] = l end
        return { readLine = function() i = i + 1 return lines[i] end, close = function() end }
    end
    disk = "a_1\nb_2\n#end\n"
    R.load()
    local l = R.list()
    check(l.n == 2 and l[1] == "a_1" and l[2] == "b_2", "最近用的：讀完整的 recent.txt，照檔案順序（新的在前）")
    R.add("b_2")
    check(disk == "b_2\na_1\n#end\n" and R.list()[1] == "b_2", "最近用的：用過的搬到最前面、馬上寫檔")
    for i = 1, 35 do R.add("x_" .. i) end
    l = R.list()
    check(l.n == 30 and l[1] == "x_35" and l[30] == "x_6", "最近用的：最多 30 項，舊的丟掉")
    disk = "a_1\nb_2\n" -- 寫到一半當掉：沒有結尾記號
    R.load()
    local f = W.filter({ query = "", tab = "all", cat = "recent", source = "all", recent = R.list() })
    check(R.list().n == 0 and f.n == 0, "壞掉的 recent.txt：當空清單，「最近使用」分類照常列（空的）")
    W.addRecent("c_3")
    check(W.st.recent.n == 1 and W.st.recent[1] == "c_3" and disk == "c_3\n#end\n", "壞檔之後照常記，整份重寫成完整的檔")
    getFileReader = function() error("boom") end
    check(pcall(R.load) and R.list().n == 0, "讀檔丟錯：不往外丟、當空清單")
    disk = nil
    getFileReader = function() return nil end
    R.load()
    check(R.list().n == 0, "沒有 recent.txt：空清單")

    -- 拆掉剛蓋的：沒有就說一聲、不送拆除請求
    local toasts, undos = {}, 0
    B.Messages.toast = function(_, text) toasts[#toasts + 1] = text end
    local PL = { getPlayerNum = function() return 0 end }
    getSpecificPlayer = function() return PL end
    Q.last = function() return nil end
    Q.undoLast = function() undos = undos + 1 return 3 end
    check(W.undoLast(0) == 0 and undos == 0 and toasts[#toasts] == "IGUI_MBLD_Undo_None",
        "拆掉剛蓋的：沒有剛蓋的就說一聲，不送拆除請求")
    Q.last = function() return { n = 1 } end
    check(W.undoLast(0) == 3 and undos == 1, "拆掉剛蓋的：有就照 Queue.undoLast 拆最後一批")

    -- 換項目鍵：照最近用的往下一個，到底從頭；不重排清單
    disk = "a_1\nb_2\nc_3\n#end\n"
    getFileReader = function()
        local lines, i = {}, 0
        for ln in disk:gmatch("[^\n]+") do lines[#lines + 1] = ln end
        return { readLine = function() i = i + 1 return lines[i] end, close = function() end }
    end
    R.load()
    local cur, went = "b_2", {}
    H.current = function() return cur end
    W.swapTo = function(_, name) went[#went + 1] = name return {} end
    W.nextRecent(0)
    cur = "c_3"
    W.nextRecent(0)
    check(went[1] == "c_3" and went[2] == "a_1" and R.list()[1] == "a_1", "換項目鍵：往下一項、到底從頭，清單順序不動")
    cur = nil
    W.nextRecent(0)
    check(#went == 2, "換項目鍵：沒在放置就不動")
    W.swapTo = real.swapTo

    -- 疊放鍵：能疊的種類才切，標籤下一幀重算，視窗的疊放跟著
    local cursor = { entry = { kind = "furniture" }, character = PL, kgen = 3 }
    C.get = function() return cursor end
    P.maxPerSquare = function() return 4 end
    W.toggleCursorOverlap(0)
    check(cursor.overlap == true and cursor.kgen == nil and W.st.overlap == true, "疊放鍵：打開、標籤重算、視窗的疊放跟著開")
    W.toggleCursorOverlap(0)
    check(cursor.overlap == nil and W.st.overlap == false, "疊放鍵：再按關掉")
    cursor.entry.kind = "wall"
    W.toggleCursorOverlap(0)
    check(cursor.overlap == nil and toasts[#toasts] == "IGUI_MBLD_Overlap_TipKind", "疊放鍵：不能疊的種類不切、說原因")
    P.maxPerSquare = real.max

    -- 吸管鍵：按著不蓋；點到的物件等放開左鍵才換（按著就換，新游標放開會蓋下去）
    local picked
    W.pickSwap = function(_, obj) picked = obj end
    local pc = { colors = { text = {}, textMuted = {} }, layout = function() end, player = 0, isLeftDown = true, pickObj = "door" }
    check(C.pickValid(pc) == false and picked == nil and pc.picking == true, "吸管鍵：按著不蓋；左鍵還按著不換")
    pc.isLeftDown = false
    check(C.pickValid(pc) == false and picked == "door" and pc.pickObj == nil, "吸管鍵：放開左鍵才換成點到的那件")
    W.pickSwap = real.pickSwap

    -- 右鍵：放置中清掉原版按下時記的物件（原版就不開右鍵選單）、關游標；沒在放置不動原版
    local dragSet
    getCell = function()
        return { getDrag = function() return nil end, setDrag = function(_, o, pn) dragSet = { o = o, pn = pn } end }
    end
    ISObjectClickHandler = { rdownObject = "obj" }
    C.get = function() return nil end
    C.onRightMouseUp()
    check(ISObjectClickHandler.rdownObject == "obj" and dragSet == nil, "右鍵：沒在放置時不動原版")
    C.get = function() return cursor end
    C.onRightMouseUp()
    check(ISObjectClickHandler.rdownObject == nil and dragSet and dragSet.o == nil and dragSet.pn == 0,
        "右鍵：放置中清掉原版按下時記的物件（不跳右鍵選單）、關游標")

    -- 快選列：有游標才建；游標關了（deactivate 或下一幀發現沒有）就收
    local made, under = 0, nil
    local function el(o)
        o.children = {}
        o.visible = true
        function o.addChild(self, c) self.children[#self.children + 1] = c end
        function o.setVisible(self, v) self.visible = v end
        function o.setY(self, y) self.y = y end
        function o.getY(self) return self.y or 0 end
        function o.setHeight(self, h) self.height = h end
        function o.initialise() end
        function o.addToUIManager(self) self.added = true end
        function o.removeFromUIManager(self) self.added = false end
        return o
    end
    ISPanel = { new = function(_, x, y, w, h)
        under = el({ x = x, y = y, width = w, height = h })
        return under
    end }
    ISPanel.setVisible = function(self, v) self.visible = v end
    ISPanel.addToUIManager = function(self) self.added = true end
    MinidoracatUI = { v1 = { API_MAJOR = 1, API_REVISION = 30,
        CAPABILITIES = { window = true, tileGrid = true, textWrap = true },
        Theme = { create = function() return { colors = { text = { r = 1, g = 1, b = 1 }, textMuted = { r = 1, g = 1, b = 1 } } } end },
        Text = { fit = function(s) return s end },
        Window = { new = function(opts)
            made = made + 1
            local w = el({ width = opts.width, height = opts.height })
            function w.contentTop() return 24 end
            return w
        end },
        TileGrid = { new = function(opts)
            local g = el({ height = opts.height, items = {} })
            function g.setItems(self, items) self.items = items end
            function g.getItems(self) return self.items end
            function g.setSelectedIndex(self, i) self.sel = i end
            function g.scrollToIndex() end
            return g
        end } } }
    UIFont = UIFont or { Small = 0, Medium = 1 }
    getTextManager = function() return { getFontHeight = function() return 16 end } end
    getPlayerScreenTop, getPlayerScreenLeft = function() return 0 end, function() return 0 end
    getPlayerScreenWidth, getPlayerScreenHeight = function() return 1920 end, function() return 1080 end
    W.setOf = function() return { list = { n = 1, "a_1" }, chip = "set" } end
    cur = nil
    H.show(0)
    check(not H.visible() and made == 0, "快選列：沒有游標時不建元件")
    cur = "a_1"
    H.show(0)
    check(H.visible() and made == 1 and under and under.prerender ~= nil, "快選列：放置中開（一個視窗）")
    cur = nil
    under.prerender(under)
    check(not H.visible(), "快選列：游標關了，下一幀自己收掉")
    cur = "a_1"
    H.show(0)
    H.show(0)
    check(H.visible() and made == 2, "快選列：開著時再開只換內容，不多建")
    C.onEnd = nil
    C.deactivate({ hideUI = function() end, player = 0 })
    check(not H.visible(), "快選列：游標結束（deactivate，不是換成另一個本工具游標）就收")

    getFileReader, getFileWriter, getCell, getSpecificPlayer = real.reader, real.writer, real.cell, real.specific
    MinidoracatUI, ISPanel, B.Messages.toast, Q.last, Q.undoLast = real.ui, real.panel, real.toast, real.last, real.undo
    ISObjectClickHandler, H.current, C.get, W.setOf, W.v = real.och, real.current, real.get, real.setOf, real.v
    getTextManager, UIFont, getPlayerScreenTop, getPlayerScreenLeft = real.tm, real.font, real.top, real.left
    getPlayerScreenWidth, getPlayerScreenHeight, W.st.overlap, C.onEnd = real.sw, real.sh, real.overlap, real.onEnd
    R.load()
end)()

-- ===== 藍圖：檢查與擷取（PlanCheck、Capture）=====
;(function()
    print("藍圖：檢查與擷取（PlanCheck 每片狀態、分幀、由近到遠；Capture 讀現成房子、存檔）")
    local B = MinidoracatBuilder
    require "MinidoracatBuilder/Plan"
    require "MinidoracatBuilder/PlanFile"
    require "MinidoracatBuilder/Messages"
    require "MinidoracatBuilder/PlanCheck"
    require "MinidoracatBuilder/Capture"
    local Plan, PF, PC, Cap = B.Plan, B.PlanFile, B.PlanCheck, B.Capture
    local real = { PM = B.PlanMode, specific = getSpecificPlayer, inst = instanceof, step = clockStep, ui = MinidoracatUI,
        reader = getFileReader, writer = getFileWriter, list = listFilesInZomboidLuaDirectory, tilesets = sb.DisabledTilesets,
        maxDrag = sb.MaxCellsPerDrag, recipes = B.Recipes }
    clockStep = 0
    B.Recipes = { get = function() return nil end, all = function() end, bySprite = {} } -- 沒有配方：不觸發掃描
    -- 本段自己的圖（名稱不和別段重複）
    world({ sprite("pcw_01_0", 1301, { flags = { "WallN" }, keys = { WallN = "" } }),
        sprite("pcf_01_0", 1302, { flags = { "solidfloor" } }),
        sprite("pcd_01_0", 1303, { flags = { "doorN" } }),
        sprite("pcd_01_2", 1304, { flags = { "doorN", "open" } }),
        sprite("pct_01_0", 1305, { type = T.tree }),
        sprite("pcx_01_0", 1306, { flags = { "WallN" }, keys = { WallN = "" } }),
        sprite("blends_natural_01_0", 1307, { flags = { "solidfloor" } }),
        sprite("blends_natural_01_8", 1308, { flags = { "FloorOverlay" } }),
        sprite("pcs_01_0", 1309, { flags = { "solidtrans" } }) })
    sb.DisabledTilesets = "pcx_01"
    local function obj(name, o)
        o = o or {}
        o.name = name
        function o:getSprite() return Entry.sprite(self.name) end
        function o:getAttachedAnimSprite() return nil end -- 引擎：沒有附加圖時是 null
        function o:getOverlaySprite() return nil end
        function o:getProperties() return self:getSprite():getProperties() end
        function o:hasModData() return false end
        function o:getModData() return {} end
        return o
    end
    -- 一塊 8×8（200..207）讀進來，每格重建（不沿用別段留下的格子）；(204,204) 是別人的安全屋。(240,200) 那塊沒讀進來
    for i = 0, 63 do
        local x, y = 200 + i % 8, 200 + math.floor(i / 8)
        square(x, y, 0, x == 204 and y == 204 and { owner = "someone" } or nil)
        squares[(240 + i % 8) .. "," .. y .. ",0"] = nil
    end
    local K = player({ id = 90, x = 205.5, y = 205.5, here = squares["205,205,0"] })
    getSpecificPlayer = function() return K end
    local pl = Plan.new("check")
    local function put(id, x, y, z)
        return Plan.add(pl, x, y, z, 0, 0, Plan.item(pl, id))
    end
    local pDone = put("pcw_01_0", 1, 1, 0)
    squares["201,201,0"].objects[1] = obj("pcw_01_0") -- 誰蓋的都算：沒有 modData
    local pDoor = put("pcd_01_0", 2, 1, 0)
    squares["202,201,0"].objects[1] = obj("pcd_01_2") -- 門開著
    local pShort = put("pcw_01_0", 3, 3, 0)
    local pBlock = put("pcw_01_0", 4, 4, 0)
    local pMiss = put("gone_01_0", 5, 1, 0)
    local pRecipe = put("recipe:Base.NoSuchThing", 5, 2, 0)
    local pOff = put("pcx_01_0", 6, 1, 0)
    local pTree = put("pct_01_0", 6, 2, 0)
    local pFar = put("pcw_01_0", 40, 0, 0)
    local ox, oy = 200, 200
    B.PlanMode = { plan = function() return pl end, origin = function() return ox, oy, 0 end, playerNum = 0 }
    PC.reset()
    local t0 = getTimestampMs()
    PC.tick(K)
    local function st(p) return (PC.state(p)) end
    local c = PC.counts()
    check(st(pDone) == "done" and st(pDoor) == "done" and st(pShort) == "short" and select(2, PC.state(pBlock)) == "SAFEHOUSE"
        and st(pBlock) == "blocked" and st(pMiss) == "missing" and st(pRecipe) == "missing" and st(pOff) == "off"
        and st(pTree) == "closed" and select(2, PC.state(pFar)) == "NOT_LOADED" and st(pFar) == "far",
        "PlanCheck：每種狀態各一（蓋好、開著的門算蓋好、缺料、被擋、沒有、關掉、不開放、沒載入）")
    check(c.n == 9 and c.done == 2 and c.short == 1 and c.blocked == 1 and c.missing == 2 and c.off == 1 and c.closed == 1
        and c.far == 1 and c.pending == 0 and c.byCode.SAFEHOUSE == 1 and c.byCode.TREE == 1 and c.byCode.DONE == nil,
        "PlanCheck.counts：各狀態片數與細節碼")
    check(PC.item("pcx_01_0") == "off" and select(2, PC.item("pcx_01_0")) == "DISABLED_TILESET"
        and PC.item("pct_01_0") == "closed" and PC.item("gone_01_0") == "missing" and PC.item("pcw_01_0") == "ok",
        "PlanCheck.item：ok／missing／off／closed")
    sb.DisabledTilesets = ""
    local reopened = PC.item("pcx_01_0")
    sb.DisabledTilesets = "pcx_01"
    check(reopened == "ok" and PC.item("pcx_01_0") == "off", "PlanCheck.item：沙盒改了（打開、再關掉圖塊組）立刻照新的回，不卡快取")
    -- 材料合計：沒蓋好的牆（缺料、被擋、沒載入的都算）× 每片的成本
    local _, _, info = Check.item(K, "pcw_01_0", 0, { 203, 203, 0, 0 }, { preview = true })
    local m = PC.materials(K)
    local plank = info.total.items["Base.Plank"]
    check(plank and plank > 0 and m.need["Base.Plank"] == 3 * plank and m.have["Base.Plank"] == 0
        and m.tools[1] and m.tools[1].tag == "HAMMER" and m.tools[1].has == false, "PlanCheck.materials：沒蓋好的 3 片牆合計、現有、工具")
    -- 補齊材料：每秒重拿一次摘要，不同就重查缺料的片
    K.inv:add(item("Base.Hammer", { HAMMER = true }))
    for ft, n in pairs(info.total.items) do for _ = 1, n do K.inv:add(item(ft)) end end
    PC.tick(K)
    local sameSecond = st(pShort)
    clockStep = PC.SUMMARY_MS
    getTimestampMs()
    clockStep = 0
    PC.tick(K)
    check(sameSecond == "short" and st(pShort) == "ok", "材料夠了：下一次比摘要時缺料的片變成能蓋（同一秒內不重算）")
    -- 搬了位置：算的結果不再算數（植入：原點動了還回舊狀態就抓得到）
    ox = 201
    check(PC.state(pDone) == nil and PC.counts().pending == 9, "原點變了：沒重算前 state 回 nil、counts 算 pending")
    ox = 200
    PC.tick(K)
    -- 看世界不看紀錄：拿掉那面牆後 touch，變成沒蓋好；放回去不 touch，靠身邊輪流比也認回來
    local wall = table.remove(squares["201,201,0"].objects, 1)
    PC.touch(201, 201, 0)
    PC.tick(K)
    local gone = st(pDone)
    squares["201,201,0"].objects[1] = wall
    PC.tick(K)
    check(gone == "ok" and st(pDone) == "done", "牆拆掉：touch 後不算蓋好；放回去：身邊的片比物件數就認回來")
    -- 有人站著的那格：人走了物件數沒變，隔 RECHECK_MS 重查（植入：不重查就一直 OCCUPIED，照圖蓋永遠挑不到那片）
    local pSeat = put("pcs_01_0", 6, 6, 0)
    squares["206,206,0"].moving[1] = {}
    PC.tick(K)
    PC.tick(K)
    local occS, occC = PC.state(pSeat)
    squares["206,206,0"].moving[1] = nil
    PC.tick(K)
    local soon = select(2, PC.state(pSeat))
    clockStep = PC.RECHECK_MS
    getTimestampMs()
    clockStep = 0
    PC.tick(K)
    check(occS == "blocked" and occC == "OCCUPIED" and soon == "OCCUPIED" and select(2, PC.state(pSeat)) ~= "OCCUPIED",
        "有人站著的格標 OCCUPIED；人走了隔 RECHECK_MS 重查，不再是 OCCUPIED（同一段時間內不重算）")
    Plan.remove(pl, { pSeat })
    -- 車庫門太寬：照這裡的上限標成蓋不了
    sb.MaxCellsPerDrag = 4
    local wide = Plan.add(pl, 7, 7, 0, 0, 0, Plan.item(pl, "pcw_01_0"), 9)
    PC.tick(K)
    check(wide and select(2, PC.state(wide)) == "DOOR_WIDE" and st(wide) == "blocked", "比上限寬的車庫門：blocked、DOOR_WIDE")
    Plan.remove(pl, { wide })
    -- 配方片：照 Recipes.tile 那一面的圖認蓋好；換了面（植入：另一面也算就抓得到）不算
    local noRecipes = B.Recipes
    B.Recipes = { get = function(id) return id == "recipe:Base.PcWall" and { id = id } or nil end, all = function() end,
        bySprite = {}, tile = function(_, d)
            if d == 3 then return "pcw_01_0", 1, 0 end -- 左上那格空著的面：圖在錨點東邊一格
            if d == 4 then return "pcw_01_0", 40, 40 end
            return d == 1 and "pcw_01_0" or "pcx_01_0"
        end,
        state = function() return true, true end, dark = function() return false end }
    local rIt = Plan.item(pl, "recipe:Base.PcWall")
    local rDone, rTurned = Plan.add(pl, 1, 1, 0, 1, 0, rIt), Plan.add(pl, 1, 1, 0, 2, 0, rIt)
    PC.tick(K)
    check(st(rDone) == "done" and st(rTurned) == "ok", "配方片：那一面的圖在就算蓋好；換了面不算（照 Recipes.tile）")
    local rOff, rFar = Plan.add(pl, 0, 1, 0, 3, 0, rIt), Plan.add(pl, 1, 1, 0, 4, 0, rIt)
    PC.tick(K)
    check(st(rOff) == "done" and st(rFar) ~= "done", "配方片：左上那格空著的面照有圖的那格認蓋好（錨點格沒有圖也算；那格沒有就不算）")
    Plan.remove(pl, { rOff, rFar })
    Plan.remove(pl, { rDone, rTurned })
    B.Recipes = noRecipes
    -- 沒有地上的藍圖：tick 第一行就離開（不看時鐘）
    B.PlanMode = { plan = function() return nil end }
    clockStep = 1
    local a1 = getTimestampMs()
    PC.tick(K)
    PC.onTick()
    local a2 = getTimestampMs()
    B.PlanMode = { plan = function() return pl end, origin = function() return ox, oy, 0 end, playerNum = 0 }
    PC.tick(K)
    local a3 = getTimestampMs()
    check(a2 - a1 == 1 and a3 - a2 > 1, "沒有藍圖時 tick 什麼都不做；有藍圖時才看時鐘")
    -- 時間預算：4,096 片一幀掃不完，由近到遠。放在沒人用的 (800..863)：只有 800..807 那一塊讀進來
    for i = 0, 4095 do squares[(800 + i % 64) .. "," .. (800 + math.floor(i / 64)) .. ",0"] = nil end
    for i = 0, 63 do square(800 + i % 8, 800 + math.floor(i / 8), 0) end
    ox, oy, K.pos.x, K.pos.y = 800, 800, 805.5, 805.5
    local big = Plan.new("big")
    local fl = Plan.item(big, "pcf_01_0")
    for i = 0, 4095 do Plan.add(big, i % 64, math.floor(i / 64), 0, 0, 0, fl) end
    B.PlanMode.plan = function() return big end
    PC.reset()
    PC.tick(K) -- 每看一次時鐘過 1 毫秒：一幀只算得了一兩片
    local c1 = PC.counts()
    local near, farP = Plan.at(big, 5, 5, 0)[1], Plan.at(big, 63, 63, 0)[1]
    local nearDone, farDone = PC.state(near) ~= nil, PC.state(farP) ~= nil
    clockStep = 0
    PC.tick(K)
    local c2 = PC.counts()
    check(big.n == 4096 and c1.pending >= 4090 and c1.pending < 4096 and nearDone and not farDone,
        "4,096 片：一幀只算預算內的幾片，先算玩家腳下的（" .. c1.pending .. " 片待算）")
    check(c2.pending == 0 and c2.far == 4096 - 64 and c2.ok + c2.short + c2.blocked == 64 and c2.byCode.INTERNAL == nil,
        "預算用不完時一幀算完；沒讀進來的塊算太遠；沒有算到出錯的片")

    -- ===== Capture =====
    local toasts = {}
    MinidoracatUI = { v1 = { Toast = { show = function(o) toasts[#toasts + 1] = o.message end } } }
    instanceof = function(o, cls) return cls == "IsoWorldInventoryObject" and o.worldItem == true end
    -- 208..215 × 200..207：牆、開著的門、樹、天然草地、地上物品（圖也是牆，不能收）；上一層一塊地板；框外 (216,200) 的牆
    square(209, 201, 0).objects[1] = obj("pcw_01_0")
    square(210, 201, 0).objects[1] = obj("pcd_01_2")
    local grass = obj("blends_natural_01_0")
    function grass:getAttachedAnimSprite() -- 草地邊緣的漸層圖是附著在地面上的
        return javaList({ { getName = function() return "blends_natural_01_8" end } })
    end
    square(211, 202, 0).objects[1] = grass
    square(212, 202, 0).objects[1] = obj("pct_01_0")
    square(213, 203, 0).objects[1] = obj("pcw_01_0", { worldItem = true })
    square(209, 202, 1).objects[1] = obj("pcf_01_0")
    square(216, 200, 0).objects[1] = obj("pcw_01_0")
    local tooWide = { Cap.scan(208, 200, 208 + 64, 207, 0) }
    check(tooWide[1] == nil and tooWide[2] == "TOO_WIDE" and Cap.scan(208, 200, 208 + 63, 207, 0) ~= nil, "擷取：每邊最多 64 格")
    local job = Cap.scan(215, 207, 208, 200, 0)
    clockStep = 1
    local first = Cap.step(job)
    clockStep = 0
    local finished = Cap.step(job)
    check(first == false and finished == true, "擷取分幀：時間到就停，下一幀接著掃")
    local out = Cap.build(job, "cap")
    local ids = {}
    Plan.each(out.plan, function(p) ids[#ids + 1] = out.plan.items[p.it].id .. "@" .. p.x .. "," .. p.y .. "," .. p.z end)
    local list = "," .. table.concat(ids, ",") .. ","
    check(out.plan.n == 3 and list:find(",pcw_01_0@1,1,0,", 1, true) and list:find(",pcd_01_0@2,1,0,", 1, true)
        and list:find(",pcf_01_0@1,2,1,", 1, true) and out.kinds == 3,
        "擷取：牆、門（開著的記成關著）、上一層的地板；原點是框的西北角 " .. list)
    check(not list:find("pcd_01_2", 1, true) and not list:find("@5,3,0", 1, true) and not list:find("@8,0,0", 1, true),
        "擷取不收：開著的門圖、地上物品、框外的牆")
    local groups = {}
    for _, g in ipairs(Cap.groups(out.skip)) do groups[g.group] = g.n end
    check(out.skipped == 3 and groups.Terrain == 2 and groups.Plant == 1 and out.over == 0 and out.wide == 0,
        "不收的分組：天然地面連它邊緣的漸層圖 2、樹 1")
    -- 存檔、讀回片數相同（假磁碟）
    local disk = {}
    getFileWriter = function(p)
        local buf = ""
        return { write = function(_, s) buf = buf .. s end, close = function() disk[p] = buf end }
    end
    getFileReader = function(p)
        if disk[p] == nil then return nil end
        local lines, i = {}, 0
        for l in disk[p]:gmatch("[^\n]+") do lines[#lines + 1] = l end
        return { readLine = function() i = i + 1; return lines[i] end, close = function() end }
    end
    listFilesInZomboidLuaDirectory = function() return javaList({}) end
    local okSave, file = Cap.save(out.plan, "  ", "Cap House")
    local back = okSave and PF.load(file)
    check(okSave == true and file == "caphouse.txt" and out.plan.name == "Cap House" and back and back.n == 3
        and back.nItems == 3, "存成藍圖：空白名稱用預設名稱，讀回片數、種類相同")
    -- 一片都沒收到：只說一聲、不開框
    local empty = Cap.scan(300, 300, 301, 301, 0)
    Cap.step(empty)
    check(Cap.show(0, Cap.build(empty, "x"), 2, 2, "x") == false and toasts[#toasts] == "IGUI_MBLD_Cap_Empty",
        "空範圍：通知、不開結果框")
    -- 分幀掃或組裝出錯：跳通知（植入：只印 log 就抓得到）
    for _, stage in ipairs({ "step", "build" }) do
        local realFn, realStep, n0 = Cap[stage], Cap.step, #toasts
        Cap[stage] = function() error("injected " .. stage) end
        if stage == "build" then Cap.step = function() return true end end
        Cap.release(0, 300, 300, 301, 301, 0)
        local before = count("OnTick")
        handlers.OnTick[#handlers.OnTick]()
        Cap[stage], Cap.step = realFn, realStep
        check(#toasts == n0 + 1 and toasts[#toasts] == "IGUI_MBLD_Cap_Fail" and count("OnTick") == before - 1,
            "擷取的" .. stage .. "出錯：跳 Cap_Fail 通知、摘掉 tick")
    end
    -- 除錯重新載入 PlanCheck：不再多掛一個 OnTick（植入：每次載入都 Add 就抓得到）
    local ticks0 = count("OnTick")
    loadfile(MEDIA .. "/client/MinidoracatBuilder/PlanCheck.lua")()
    check(count("OnTick") == ticks0 and B.PlanCheck == PC, "PlanCheck 重新載入：OnTick 不重複註冊")

    B.PlanMode, getSpecificPlayer, instanceof, clockStep, MinidoracatUI = real.PM, real.specific, real.inst, real.step, real.ui
    B.Recipes = real.recipes
    getFileReader, getFileWriter, listFilesInZomboidLuaDirectory = real.reader, real.writer, real.list
    sb.DisabledTilesets, sb.MaxCellsPerDrag = real.tilesets, real.maxDrag
    PC.reset()
end)()

-- ===== 藍圖：規劃與擺放（PlanMode、PlanGhost）=====
;(function()
    print("藍圖：規劃與擺放（游標放開記進藍圖、上限、上一步、選取與擦、擺放與轉向、重新載入、虛影上限）")
    local B = MinidoracatBuilder
    require "MinidoracatBuilder/Plan"
    require "MinidoracatBuilder/PlanFile"
    require "MinidoracatBuilder/PlanStore"
    require "MinidoracatBuilder/Cursor"
    require "MinidoracatBuilder/Client"
    local Plan, PF, PS, Cur, Msg = B.Plan, B.PlanFile, B.PlanStore, B.Cursor, B.Messages
    local real = { spec = getSpecificPlayer, cell = getCell, text = getText, core = getCore, world = getWorld,
        reader = getFileReader, writer = getFileWriter, list = listFilesInZomboidLuaDirectory, joy = JoypadState,
        IBO = ISBuildingObject, toast = Msg.toast, PC = B.PlanCheck, build = B.Client.build, kb = Keyboard, kid = KeybindId,
        binding = keyBinding, ui = MinidoracatUI, um = UIManager, recipes = B.Recipes, el = ISUIElement,
        map = spriteMap, order = spriteOrder, hook = {}, runner = MinidoracatBuilder.Runner }
    for k, v in pairs(Cur.hook) do real.hook[k] = v end
    getText = function(k, ...)
        local a = { ... }
        return #a == 0 and k or k .. "(" .. table.concat(a, ",") .. ")"
    end
    local toasts, sent, specCalls = {}, 0, 0
    Msg.toast = function(_, t) toasts[#toasts + 1] = t end
    B.Client.build = function() sent = sent + 1 return sent end
    -- 配方片查不到面：轉向時算轉不了（不碰別段的假配方資料）；沒有配方游標
    MinidoracatBuilder.Recipes = { faces = function() return nil end, cursor = function() return nil end }
    MinidoracatUI, ISUIElement = nil, nil -- 沒有框架：工具列不出、換張要確認時只通知
    JoypadState = { players = {} }
    UIManager = { getUI = function() return javaList({}) end }
    local P = player({ x = 50.5, y = 50.5, z = 0 })
    getSpecificPlayer = function(pn)
        specCalls = specCalls + 1
        return pn == 0 and P or nil
    end
    -- 照引擎：setDrag 換掉（或清掉）舊的拖曳物件時呼叫它的 deactivate
    local drags = {}
    getCell = function()
        local c = real.cell()
        c.getDrag = function(_, pn) return drags[pn] end
        c.setDrag = function(_, o, pn)
            local old = drags[pn]
            drags[pn] = o
            if old and old ~= o and old.deactivate then old:deactivate() end
        end
        return c
    end
    local binds = { RotateBuilding = 19, MinidoracatBuilder_PlanUndo = 44, MinidoracatBuilder_PlanRedo = 21,
        MinidoracatBuilder_PlanDelete = 211, MinidoracatBuilder_LayerUp = 201 }
    KeybindId = { ROTATE_BUILDING = "RotateBuilding" }
    getCore = function()
        return { isKey = function(_, id, key) return binds[id] == key end, getScreenWidth = function() return 1920 end,
            getGameMode = function() return { toString = function() return "Sandbox" end } end }
    end
    getWorld = function() return { getWorld = function() return "pm_world" end } end
    -- 假磁碟照引擎：getFileWriter 一開檔就清空（LuaManager.java:6687，FileWriter 非附加）、寫多少進多少；
    -- 讀照 BufferedReader：空行讀成 ""。failWrite：每個檔都寫不進（開檔照樣清空）。
    -- fail＝{ pat＝路徑樣式, skip＝先放過幾次開檔 }：只有那些檔寫不進。crash＝{ after＝路徑樣式 }：那個檔寫完就當掉，
    -- 之後什麼都寫不進、也不再開檔（測試把 crash 設回 nil＝重開遊戲）。locked[路徑]：打不開（在資料夾裡、讀不到）
    local disk, failWrite, fail, crash, locked = {}, false, nil, nil, {}
    getFileWriter = function(p, _, append)
        if crash and crash.dead then return { write = function() end, close = function() end } end
        local drop = failWrite
        if fail and p:find(fail.pat) then
            if (fail.skip or 0) > 0 then fail.skip = fail.skip - 1 else drop = true end
        end
        if not append then disk[p] = "" end
        return { write = function(_, s) if not drop then disk[p] = (disk[p] or "") .. s end end,
            close = function() if crash and crash.after and p:find(crash.after) then crash.dead = true end end }
    end
    getFileReader = function(p)
        if disk[p] == nil or locked[p] then return nil end
        local lines, i, pos, text = {}, 0, 1, disk[p]
        while pos <= #text do
            local e = text:find("\n", pos, true) or (#text + 1)
            lines[#lines + 1] = text:sub(pos, e - 1)
            pos = e + 1
        end
        return { readLine = function() i = i + 1; return lines[i] end, close = function() end }
    end
    listFilesInZomboidLuaDirectory = function(dir)
        local names = {}
        for p in pairs(disk) do
            local name = p:sub(#dir + 2)
            if p:sub(1, #dir + 1) == dir .. "/" and not name:find("/", 1, true) then names[#names + 1] = name end
        end
        table.sort(names)
        return javaList(names)
    end
    -- 虛影：每張圖記畫了幾次、畫在哪
    local ghostN, ghostAt = 0, {}
    local function ghostly(s)
        s.RenderGhostTileColor = function(_, x, y, z)
            ghostN = ghostN + 1
            ghostAt[x .. "," .. y .. "," .. z] = true
        end
        return s
    end
    local floorCursor = { RenderGhostTileColor = function() end }
    ISBuildingObject = { init = function() end, onJoypadPressButton = function() end,
        getFloorCursorSprite = function() return floorCursor end }
    ISBuildingObject.derive = function(self, name) return setmetatable({ Type = name }, { __index = self }) end
    local function sp(name, id, flags)
        local keys = {}
        for _, f in ipairs(flags) do if f:match("^[A-Z]") then keys[f] = "" end end
        return ghostly(sprite(name, id, { flags = flags, keys = keys }))
    end
    -- 四面椅子（0..3＝朝南、東、北、西）：引擎替每一面寫其他面的偏移，自己那面不寫
    local chairDirs, chairs = { "S", "E", "N", "W" }, {}
    for i = 0, 3 do
        local keys = { IsMoveAble = "", GroupName = "Pm", CustomName = "Chair", Facing = chairDirs[i + 1] }
        for j = 0, 3 do if j ~= i then keys[chairDirs[j + 1] .. "offset"] = tostring(j - i) end end
        chairs[i + 1] = ghostly(sprite("pm_chair_01_" .. i, 3110 + i, { keys = keys }))
    end
    world({ sp("pm_wall_01_0", 3101, { "WallW" }), sp("pm_wall_01_1", 3102, { "WallN" }), sp("pm_lone_01_0", 3103, { "WallW" }),
        sp("pm_floor_01_0", 3104, { "solidfloor" }), chairs[1], chairs[2], chairs[3], chairs[4] })
    local fakeCheck, resets = nil, 0
    B.PlanCheck = { reset = function() resets = resets + 1 end, state = function(p) return fakeCheck and fakeCheck(p) end }

    require "MinidoracatBuilder/PlanMode"
    require "MinidoracatBuilder/PlanGhost"
    local PM, PG = B.PlanMode, B.PlanGhost
    local function at(plan, x, y, z) return Plan.at(plan, x, y, z)[1] end
    local function sq(x, y, z) return { getX = function() return x end, getY = function() return y end, getZ = function() return z end } end

    -- 沒有藍圖：虛影第一行就離開（不問玩家、不畫）
    PG.draw()
    check(PM.state() == "none" and specCalls == 0 and ghostN == 0 and PG.lastDrawn == 0, "沒有藍圖：虛影不問玩家、不畫")

    -- 打開規劃：腳下建一張空的，掛上游標掛鉤
    check(PM.toggle(0) == true and PM.planning() and PM.state() == "edit" and Cur.hook.commit ~= nil and PM.level() == 0,
        "打開規劃：狀態 edit、游標掛鉤掛上、樓層是玩家那層")
    local ox, oy, oz = PM.origin()
    check(ox == 50 and oy == 50 and oz == 0, "空藍圖的原點在玩家腳下")
    local plan = PM.plan()
    local colors = { text = "T", warning = "W", textMuted = "M" }
    local function cursor(res, name)
        return setmetatable({ kx = 1, ky = 1, kz = 0, res = res, name = name or "pm_wall_01_1", character = P, colors = colors,
            lineX = 5, hint = "HINT" }, { __index = Cur })
    end
    local cur = cursor({ { a = { 52, 50, 0, 0 } }, { a = { 53, 50, 0, 0 }, code = "NO_MATERIAL" },
        { a = { 54, 50, 0, nil }, code = "NO_FACE" }, { a = { 55, 50, 0, 5 }, code = "BLOCKED" }, { a = { 56, 50, 0, 0, 3 } } })
    local lbl = Cur.hook.label(cur, { "L1", "T", "L2", "T", "HINT", "M" })
    check(lbl[3] == "IGUI_MBLD_PlanAdd(4)" and lbl[5] == "L2" and lbl[#lbl - 1] == "IGUI_MBLD_PlanHint" and lbl[#lbl] == "M"
        and Cur.hook.valid(cur) == true, "規劃中的標籤：插一行「放開會記 4 片」（沒有那一面的不算），按鍵說明換成規劃的")
    local commit = Cur.hook.commit
    cur:tryBuild(1, 1, 0)
    check(sent == 0 and plan.n == 4 and cur.lineX == nil, "規劃中放開：不送伺服器，缺料、被擋的照記，沒有那一面的不記")
    check(at(plan, 2, 0, 0).d == 0 and at(plan, 5, 0, 0).d == 5 and at(plan, 4, 0, 0) == nil and at(plan, 6, 0, 0).w == 3
        and plan.items[at(plan, 2, 0, 0).it].id == "pm_wall_01_1", "記進藍圖的片：相對原點、朝向、車庫門寬度照游標")
    cursor({ { a = { 52, 51, 0, 0 } }, { a = { 53, 51, 0, 0 } } }):tryBuild(1, 1, 0)
    check(plan.n == 6 and PM.undo() and plan.n == 4 and PM.undo() and plan.n == 0 and PM.redo() and plan.n == 4,
        "上一步：一次放開整步拿掉（兩次放開兩步），下一步拿回來")
    check(PM.redo() and plan.n == 6 and not PM.redo(), "下一步到底回 false")

    -- 上限：超出的那次放開不記、標籤寫原因
    local wide = cursor({ { a = { 50 + 70, 50, 0, 0 } } })
    local wl = Cur.hook.label(wide, { "L1", "T", "HINT", "M" })
    check(Cur.hook.valid(wide) == false and wl[3] == "IGUI_MBLD_PlanTooWide" and wl[4] == "W", "超出每邊 64 格：標籤寫原因、不可放")
    local before = #toasts
    wide:tryBuild(1, 1, 0)
    check(plan.n == 6 and sent == 0 and toasts[before + 1] == "IGUI_MBLD_PlanTooWide", "超出每邊 64 格：放開不記、跳原因")
    local high = cursor({ { a = { 52, 50, 4, 0 } } })
    Cur.hook.label(high, { "L1", "T" })
    check(Cur.hook.valid(high) == false and high.planWhy == "TOO_HIGH", "超出 4 層：TOO_HIGH")
    local full = Plan.new("full")
    local fi = Plan.item(full, "pm_floor_01_0")
    for y = 0, 63 do for x = 0, 63 do Plan.add(full, x, y, 0, 0, 0, fi) end end
    full.ox, full.oy, full.oz = 0, 0, 0
    check(PM.overflow(full, { { 5, 5, 0, 0 } }, "pm_floor_01_0", 0) == nil
        and PM.overflow(full, { { 5, 5, 0, 1 } }, "pm_floor_01_0", 0) == "FULL",
        "4,096 片：重複的片不算數，多一片新的 FULL")
    -- 朝向只有一種寫法：椅子自己那張圖朝南，游標轉一圈回到南（d＝3）和剛開的 0 是同一片
    local cf = Plan.new("cf")
    for y = 0, 63 do for x = 0, 63 do if x + y > 0 then Plan.add(cf, x, y, 0, 0, 0, Plan.item(cf, "pm_floor_01_0")) end end end
    Plan.add(cf, 0, 0, 0, 0, 0, Plan.item(cf, "pm_chair_01_0"))
    cf.ox, cf.oy, cf.oz = 0, 0, 0
    check(cf.n == 4096 and PM.overflow(cf, { { 0, 0, 0, 3 } }, "pm_chair_01_0", 0) == nil
        and PM.overflow(cf, { { 0, 0, 0, 4 } }, "pm_chair_01_0", 0) == "FULL",
        "朝向同一種寫法：轉一圈回到自己那張圖（d＝3）和 0 算同一片；別的朝向是新的一片")

    -- 配方游標交來的格子
    check(PM.addCells(0, "recipe:Base.Tarp", { { 51, 51, 0, 2 } }) == true and at(plan, 1, 1, 0).d == 2
        and plan.items[at(plan, 1, 1, 0).it].id == "recipe:Base.Tarp" and plan.n == 7, "配方的格子記進藍圖（面編號照收）")

    -- 樓層：hook.layer 回規劃層和玩家那層的差，夾在藍圖 4 層的範圍內
    PM.setLevel(2)
    check(Cur.hook.layer(cur) == 2, "換到 3 樓規劃：游標往上 2 層")
    PM.setLevel(9)
    check(PM.level() == 3, "樓層夾在藍圖能到的 4 層內（全部片在 1 樓：最多到 4 樓）")
    PM.onKeyPressed(44)
    check(plan.n == 6, "Ctrl+Z（假綁定 44）：上一步")
    PM.onKeyPressed(21)
    check(plan.n == 7, "Ctrl+Y：下一步")
    PM.setLevel(0)

    -- 選取、擦：只算規劃那一層
    check(PM.selectRect(52, 50, 53, 51) == 4 and #PM.selected() == 4 and PM.isSelected(at(plan, 2, 0, 0)), "框選 2×2：選到 4 片")
    PM.setLevel(1)
    check(PM.selectRect(52, 50, 53, 51) == 0 and PM.selectRect(52, 50, 53, 51, true) == 4, "別層框不到；按住 Shift 全部樓層")
    PM.setLevel(0)
    check(PM.eraseRect(55, 50, 56, 50) == 2 and plan.n == 5 and #PM.selected() == 0, "擦：拿掉框到的片、清掉選取")
    PM.selectRect(52, 51, 53, 51)
    PM.onKeyPressed(211)
    check(plan.n == 3 and at(plan, 2, 1, 0) == nil, "Delete：刪掉選到的 2 片")

    -- 關掉規劃：存檔、記進這個存檔的地上藍圖，掛鉤拿掉
    check(PM.toggle(0) == true and PM.state() == "fixed" and Cur.hook.commit == nil, "關掉規劃：狀態 fixed、掛鉤拿掉")
    check(commit(cur) == false, "植入：規劃關掉後還留著的掛鉤也不收（回 false，游標照常送）")
    local file = "MinidoracatBuilder/plans/" .. plan.file
    local st = PS.load()
    check(disk[file] ~= nil and st.file == plan.file and st.ox == 51 and st.oy == 50 and st.oz == 0,
        "存檔：藍圖檔寫進磁碟；位置記包圍盒的角（51, 50, 0）")

    -- 重新載入（模組重跑＝遊戲重開）：讀回原處
    local function reload()
        loadfile(MEDIA .. "/client/MinidoracatBuilder/PlanMode.lua")()
        PM = B.PlanMode
    end
    reload()
    check(PM.plan() == nil and PM.restore() == true and PM.state() == "fixed", "重新載入：讀回地上的藍圖")
    plan = PM.plan()
    ox, oy, oz = PM.origin()
    local w1 = at(plan, 52 - ox, 50 - oy, 0)
    check(ox == 51 and oy == 50 and w1 and w1.d == 0 and plan.items[w1.it].id == "pm_wall_01_1"
        and at(plan, 51 - ox, 51 - oy, 0) ~= nil, "重新載入：每片在世界上的位置不變")
    -- 這張藍圖在磁碟上的每個檔（正式檔與存檔時另寫的副本）一起換掉；回原本的內容
    local function swapFiles(path, text)
        local stem, old = (path:gsub("%.txt$", "")), {}
        for k, v in pairs(disk) do if k:sub(1, #stem + 1) == stem .. "." then old[k] = v end end
        for k in pairs(old) do disk[k] = text end
        return old
    end
    local function putBack(old) for k, v in pairs(old) do disk[k] = v end end
    local good = swapFiles(file, "壞掉的內容\n")
    reload()
    before = #toasts
    local fine, res = pcall(PM.restore)
    check(fine and res == false and PM.plan() == nil and toasts[before + 1] == "IGUI_MBLD_PlanLost" and PS.load().file == nil,
        "壞檔：不丟錯、通知一次、地上的藍圖記錄清掉")
    putBack(good)
    PS.save(st)
    reload()
    check(PM.restore() == true, "檔案修好、記錄寫回：照常讀回（對照組）")
    plan = PM.plan()

    -- 搬：跟著游標、取消回原位置；放回原位置
    check(PM.pickUp(0) == true and PM.state() == "place" and PM.origin() == nil and drags[0] ~= nil, "搬：整張跟著游標，原點暫時沒有")
    local o = drags[0]
    o:isValid(sq(80, 80, 0))
    o:rotateKey(19)
    check(PM.drag(0) == o and PM.drag(1) == nil, "搬：拖曳物件查得到（只有拿著的那位玩家）")
    MinidoracatBuilder.Cursor.onRightMouseUp() -- 右鍵：不是建造游標也要取消（關掉拖曳物件 → deactivate）
    check(drags[0] == nil and PM.drag(0) == nil, "右鍵：藍圖的搬／擺放也取消")
    ox, oy = PM.origin()
    check(PM.state() == "fixed" and ox == 51 and oy == 50 and at(plan, 52 - 51, 0, 0) and at(plan, 1, 0, 0).d == 0,
        "搬到一半取消：轉過的撤回，回原位置")
    PM.pickUp(0)
    check(PM.home() ~= nil and PM.placeHome() == true and select(1, PM.origin()) == 51 and PM.state() == "fixed", "放回原位置")

    -- 審查 1116 第 1 輪 C5：包圍盒的角變了以後按「存檔」或「隱藏」再重進，每片還在原處（藍圖檔與位置一起存）
    local function worldSig()
        local out, ox2, oy2, oz2 = {}, PM.origin()
        Plan.each(PM.plan(), function(p) out[#out + 1] = (p.x + ox2) .. "," .. (p.y + oy2) .. "," .. (p.z + oz2) .. "," .. p.d end)
        table.sort(out)
        return table.concat(out, "|")
    end
    local function quit() -- 沒按完成就離開遊戲：拿掉舊模組掛的游標掛鉤，重新載入再讀回
        for _, k in ipairs({ "valid", "commit", "label", "tint", "layer" }) do Cur.hook[k] = nil end
        reload()
        return PM.restore()
    end
    local paused
    B.Runner = { pause = function(r) paused = r end }
    PM.toggle(0)
    check(paused == "EDIT" and PM.planning(), "C8：進入規劃前先暫停照圖蓋（原因 EDIT）")
    PM.eraseRect(51, 51, 51, 51)
    local want = worldSig()
    check(PM.save() == true and quit() == true and worldSig() == want, "C5：角變了以後按存檔，重進每片仍在原處")
    -- 第 2 輪 PM6：按隱藏只改記錄的 hidden，不重寫藍圖檔
    PM.toggle(0)
    PM.eraseRect(52, 50, 52, 50)
    want = worldSig()
    local planPath = "MinidoracatBuilder/plans/" .. PM.plan().file
    local fileBefore = disk[planPath]
    PM.setHidden(true)
    check(disk[planPath] == fileBefore and PS.load().hidden == true, "PM6：按隱藏只改記錄，不重寫藍圖檔")
    check(PM.save() == true and quit() == true and worldSig() == want and PM.hidden() == true,
        "C5：角變了以後存檔，重進每片仍在原處、照樣隱藏")
    PM.setHidden(false)

    -- 第 2 輪 PM5：藍圖檔一時打不開（在資料夾裡、讀不到）保留記錄、下次再讀；正式檔與備份都不在資料夾裡才當成刪掉
    plan = PM.plan()
    local pfile = "MinidoracatBuilder/plans/" .. plan.file
    local pback = (pfile:gsub("%.txt$", ".cfg"))
    locked[pfile], locked[pback] = true, true
    before = #toasts
    check(quit() == false and toasts[before + 1] == "IGUI_MBLD_PlanUnread" and PS.load().file == plan.file,
        "打不開的藍圖檔：記錄留著、說下次再讀")
    PM.toggle(0)
    check(PM.stopEdit() == true and PM.state() == "none" and PS.load().file == plan.file,
        "PM5：保留記錄時開規劃又關掉（空白的丟掉），記錄還在")
    locked[pfile], locked[pback] = nil, nil
    local oldName = plan.file
    local moved = PF.rename(oldName, "Kept")
    check(moved ~= nil and PM.retarget(oldName, moved, "Kept") == true and PS.load().file == moved,
        "PM5：保留記錄、地上沒有藍圖時藍圖庫改名，記錄跟著指向新檔名")
    check(quit() == true and PM.plan().file == moved, "檔案打得開了：下次照常讀回（改名後的檔）")
    plan = PM.plan()
    local stKeep = PS.load()
    local gone = swapFiles("MinidoracatBuilder/plans/" .. plan.file, nil)
    before = #toasts
    check(quit() == false and toasts[before + 1] == "IGUI_MBLD_PlanLost" and PS.load().file == nil
        and quit() == false and #toasts == before + 1, "PM5：正式檔與備份都不在資料夾裡＝刪掉了：清記錄、只說一次")
    putBack(gone)
    PS.save(stKeep)
    check(quit() == true, "檔案與記錄放回：照常讀回（對照組）")
    plan = PM.plan()

    -- C2：存檔失敗時不離開規劃、不收起
    PM.toggle(0)
    PM.addCells(0, "recipe:Base.Tarp", { { 54, 50, 0, 2 } })
    failWrite = true
    before = #toasts
    local ok2, why2 = PM.stopEdit()
    check(ok2 == false and why2 ~= nil and PM.planning() and Cur.hook.commit ~= nil and toasts[before + 1] == "IGUI_MBLD_PlanSaveFail",
        "C2：完成時存檔失敗：留在規劃、掛鉤還在、通知")
    check(PM.clear() == false and PM.plan() == plan and plan.n == 2 and PM.planning(), "C2：收起時存檔失敗：藍圖留著、什麼都不動")
    failWrite = false

    -- C10：搬、複製中按旋轉只轉預覽；取消時原片不動，複製放下時只轉新的那份，算一步
    local function wallAt(x, y)
        local wx, wy = PM.origin()
        for _, p in ipairs(Plan.at(plan, x - wx, y - wy, 0)) do if plan.items[p.it].id == "pm_wall_01_1" then return p end end
        return nil
    end
    check(select(2, PM.blank(0)) == "BUSY" and PM.planning() and PM.plan() == plan, "blank：規劃中也回 BUSY、不動")
    local n0 = plan.n
    PM.selectRect(53, 50, 54, 50)
    PM.moveSel(true)
    o = drags[0]
    o:isValid(sq(60, 50, 0))
    o:rotateKey(19)
    getCell():setDrag(nil, 0)
    check(plan.n == n0 and wallAt(53, 50) and wallAt(53, 50).d == 0, "C10：複製中轉了再取消：原片沒轉、沒多片")
    PM.moveSel(true)
    o = drags[0]
    o:isValid(sq(60, 50, 0))
    o:rotateKey(19)
    o:tryBuild(60, 50, 0)
    local copyWall = wallAt(61, 50)
    check(plan.n == n0 + 2 and wallAt(53, 50) and wallAt(53, 50).d == 0 and copyWall and copyWall.d == 5 and PM.isSelected(copyWall),
        "C10：複製轉 90 度放下：原片不動，新的那份轉了（北牆→右邊那格的西牆）")
    check(PM.undo() and plan.n == n0 and wallAt(53, 50).d == 0, "C10：複製加旋轉算一步，上一步一次拿掉")
    -- 第 2 輪 PM4：照預覽的最終位置一次放下（中間位置不去重）
    local function wallD(x, y, d)
        local wx, wy = PM.origin()
        for _, p in ipairs(Plan.at(plan, x - wx, y - wy, 0)) do
            if plan.items[p.it].id == "pm_wall_01_1" and p.d == d then return p end
        end
        return nil
    end
    PM.addCells(0, "pm_wall_01_1", { { 63, 50, 0, 0 } })
    PM.selectRect(53, 50, 53, 50)
    PM.moveSel(false)
    o = drags[0]
    o:isValid(sq(63, 50, 0))
    o:rotateKey(19)
    o:tryBuild(63, 50, 0)
    check(plan.n == n0 + 1 and wallD(63, 50, 0) and wallD(64, 50, 5) and not wallD(53, 50, 0),
        "PM4：搬 10 格再轉，中間位置疊到沒選的同款牆：兩片都在，搬的那片在預覽的位置")
    check(PM.undo() and plan.n == n0 + 1 and wallD(53, 50, 0) and wallD(63, 50, 0) and not wallD(64, 50, 5),
        "PM4：搬加轉，上一步一次回到原樣")
    PM.selectRect(53, 50, 53, 50)
    PM.moveSel(true)
    o = drags[0]
    o:isValid(sq(53, 50, 0))
    o:rotateKey(19)
    o:tryBuild(53, 50, 0)
    check(plan.n == n0 + 2 and wallD(53, 50, 0) and wallD(54, 50, 5), "PM4：原地轉 90 度複製：新的那片照預覽加上，不漏片")
    PM.undo()
    PM.undo()
    check(plan.n == n0, "上一步拿掉複製與加的牆")
    check(PM.stopEdit() == true and PM.state() == "fixed", "對照：寫得進去就照常結束規劃")

    -- C3／K1：藍圖庫改名、刪除後地上那張跟著改；刪掉後存檔另取檔名，不蓋掉舊檔名
    local f0 = plan.file
    check(PM.retarget("nope.txt", "x.txt", "X") == false and plan.file == f0, "retarget：不是地上那張就不動")
    check(PM.retarget(f0, "cabin.txt", "Cabin") == true and plan.file == "cabin.txt" and plan.name == "Cabin"
        and PS.load().file == "cabin.txt", "retarget：改名後地上那張與記錄都換成新檔名")
    check(PM.retarget("cabin.txt", nil) == true and plan.file == nil and PS.load().file == nil, "retarget：刪除後解除連結、記錄清掉")
    disk["MinidoracatBuilder/plans/cabin.txt"] = "NEWPLAN\n" -- 這個檔名已經給了別張
    check(PM.save() == true and disk["MinidoracatBuilder/plans/cabin.txt"] == "NEWPLAN\n" and plan.file ~= nil
        and plan.file ~= "cabin.txt" and PS.load().file == plan.file, "刪除後按存檔：另取檔名，舊檔名那張沒被蓋掉")

    -- 同一個檔的另一份（重新匯入或讀回、換過圖）擺到地上：取代地上那張、位置不動，之後存的是新內容
    local again = PF.load(plan.file)
    local ax0, ay0 = Plan.bounds(again)
    Plan.add(again, ax0, ay0, 0, 0, 0, Plan.item(again, "pm_floor_01_0"))
    local function wallIn(pl2, x, y)
        local gx, gy = PM.origin()
        for _, p in ipairs(Plan.at(pl2, x - gx, y - gy, 0)) do if pl2.items[p.it].id == "pm_wall_01_1" then return p end end
        return nil
    end
    check(PM.place(again, 0) == true and PM.plan() == again and PM.state() == "place" and PM.placeHome() == true
        and wallIn(again, 53, 50) ~= nil, "同一個檔的新一份擺到地上：取代地上那張，放回原位置時每片位置不變")
    check(PM.save() == true and PF.load(again.file).n == plan.n + 1, "之後存檔寫的是新的那份（多一片地板），不是地上的舊內容")
    plan = again

    -- 地上已經有一張，沒有框架時不換、說一聲
    before = #toasts
    check(PM.place(Plan.new("別張"), 0) == false and PM.plan() == plan and toasts[before + 1] == "IGUI_MBLD_NeedFramework",
        "地上已經有藍圖、沒有框架：不換、通知")
    check(PM.clear() == true and PM.state() == "none" and PS.load().file == nil, "收起：地上沒有藍圖、記錄清掉")
    check(PM.blank(0) == true and PM.planning() and PM.plan().n == 0 and PM.plan() ~= plan, "blank：沒有藍圖時建一張空白的並開始規劃")
    check(PM.stopEdit() == true and PM.state() == "none", "空白的沒畫就結束：直接丟掉")

    -- ===== 審查第 2 輪：改名（PM3）、兩段式存檔（PM2）、搬之前先存（PM1）、同一個檔的另一份（PM8） =====
    local two = Plan.new("Two")
    local tf = Plan.item(two, "pm_floor_01_0")
    Plan.add(two, 0, 0, 0, 0, 0, tf)
    Plan.add(two, 1, 0, 0, 0, 0, tf)
    local function settleAt(pl, x)
        PM.place(pl, 0)
        drags[0]:isValid(sq(x, 50, 0))
        drags[0]:tryBuild(x, 50, 0)
    end
    settleAt(two, 100)
    local function xs() -- 地上那張每片的世界 x
        local out, gx = {}, PM.origin()
        Plan.each(PM.plan(), function(p) out[#out + 1] = p.x + gx end)
        table.sort(out)
        return table.concat(out, ",")
    end
    check(xs() == "100,101" and PS.load().file == two.file, "第 2 輪：兩片定在 100、101，記錄指著這張")
    local function editLeft() -- 規劃中刪掉左片：包圍盒的角從 100 變 101
        PM.toggle(0)
        PM.eraseRect(100, 50, 100, 50)
    end
    editLeft()
    local f1 = two.file
    local f2 = PF.rename(f1, "Twin")
    check(f2 ~= nil and PM.retarget(f1, f2, "Twin") == true and quit() == true and xs() == "100,101",
        "PM3：規劃中刪掉左片、沒完成就改名，重進兩片仍在 100、101（照磁碟上那份）")

    editLeft()
    fail = { pat = "worlds/" }
    local ok3 = PM.save()
    fail = nil
    check(ok3 == nil and quit() == true and xs() == "100,101", "PM2：只有 worlds 寫不進：重進是舊的那一版（100、101），不是混的")
    editLeft()
    fail = { pat = "plans/" }
    ok3 = PM.save()
    fail = nil
    check(ok3 == nil and PS.load().px == 100 and quit() == true and xs() == "100,101",
        "PM2：只有藍圖檔寫不進：記錄已是新的角，讀回照藍圖檔的 pos 認出上一版，仍在 100、101")
    editLeft()
    crash = { after = "worlds/.*%.txt$" }
    PM.save()
    crash = nil
    local sig = (quit() == true) and xs() or "-"
    check(sig == "100,101" or sig == "101", "PM2：記錄寫好、藍圖檔還沒寫就當掉：重進是完整的一版（" .. sig .. "）")
    editLeft()
    check(PM.save() == true and quit() == true and xs() == "101", "對照：兩邊都寫得進去，重進是新的那一版（只剩 101）")
    PM.pickUp(0)
    fail = { pat = "worlds/" }
    local okC, whyC = PM.clear()
    fail = nil
    drags[0] = nil -- 離開遊戲：跟著游標的那個不會被取消
    check(okC == false and whyC == "STORE" and PM.plan() ~= nil and quit() == true and xs() == "101",
        "PM2：收起時 worlds 寫不進：回 false、藍圖還在，重進仍在原處")

    local realUi, shown = B.Window.ui, 0
    B.Window.ui = function(need) -- 只給確認框；工具列照沒有框架時不出（不在這裡測）
        if not (need and need[1] == "dialog") then return nil end
        return { Dialog = { show = function(d) shown = shown + 1; d.onResult(true) end },
            Theme = { create = function() return {} end } }
    end
    PM.toggle(0)
    PM.addCells(0, "pm_floor_01_0", { { 102, 50, 0, 0 } })
    local cur2 = PM.plan()
    local other = Plan.new("Other")
    Plan.add(other, 0, 0, 0, 0, 0, Plan.item(other, "pm_floor_01_0"))
    check(PM.pickUp(0) == true and PM.state() == "place" and PM.place(other, 0) == true and shown == 1 and PM.plan() == other
        and PF.load(cur2.file).n == 2, "PM1：規劃中改了按「搬」再換一張：搬之前已存，換掉後檔裡有改動")
    getCell():setDrag(nil, 0)
    settleAt(PF.load(cur2.file), 101)
    PM.toggle(0)
    PM.addCells(0, "pm_floor_01_0", { { 103, 50, 0, 0 } })
    failWrite = true
    local okP, whyP = PM.pickUp(0)
    failWrite = false
    check(okP == false and whyP ~= nil and PM.planning() and PM.plan().n == 3, "PM1：搬之前存不了：留在規劃、改動還在記憶體")
    PM.stopEdit()

    local file2 = PM.plan().file
    local newer = PF.load(file2)
    local nx0, ny0 = Plan.bounds(newer)
    Plan.add(newer, nx0, ny0, 0, 0, 0, Plan.item(newer, "pm_wall_01_1"))
    PF.save(newer, file2) -- 藍圖庫「存進藍圖庫」寫到同一個檔
    check(PM.adopt ~= nil and PM.adopt(newer) == true and PM.plan() == newer and PM.state() == "fixed"
        and xs() == "101,101,102,103", "PM8：定住時 adopt：換成新的這份、位置不動、不拿起來")
    check(PM.save() == true and PF.load(file2).n == 4 and quit() == true and xs() == "101,101,102,103",
        "PM8：adopt 之後存檔，檔案內容是新的那一份")
    newer = PM.plan()
    PM.toggle(0)
    local okA, whyA = PM.adopt(PF.load(file2))
    check(okA == false and whyA == "EDITING" and PM.plan() == newer, "PM8：規劃中 adopt：不換、回 EDITING")
    PM.addCells(0, "pm_floor_01_0", { { 104, 50, 0, 0 } })
    local dup = PF.load(file2)
    shown = 0
    check(PM.place(dup, 0) == true and shown == 1 and PM.plan() == dup and dup.file == nil and PM.state() == "place"
        and PF.load(file2).n == 5, "PM8：規劃中擺同一個檔的另一份：先問、存檔收起地上那張（改動有存），新的這份當成另一張")
    getCell():setDrag(nil, 0)
    B.Window.ui = realUi

    -- 從藍圖庫擺：轉 90 度（北牆換成右邊那格的西牆；沒有另一面的照原朝向），點一下定位
    local np = Plan.new("小屋")
    local fl, wn, lone = Plan.item(np, "pm_floor_01_0"), Plan.item(np, "pm_wall_01_1"), Plan.item(np, "pm_lone_01_0")
    Plan.add(np, 0, 0, 0, 0, 0, fl)
    Plan.add(np, 1, 0, 0, 0, 0, fl)
    Plan.add(np, 0, 0, 0, 0, 0, wn)
    Plan.add(np, 2, 0, 0, 0, 0, lone)
    check(PM.place(np, 0) == true and PM.state() == "place" and PM.home() == nil, "擺放：沒有原位置的不給「放回原位置」")
    o = drags[0]
    o:isValid(sq(70, 70, 0))
    check(o.ox == 69 and o.oy == 70 and o.oz == 0, "跟著游標：藍圖中心對準滑鼠那格")
    before = #toasts
    o:rotateKey(19)
    check(toasts[before + 1] == "IGUI_MBLD_PlanStuck(1)", "轉 90 度：沒有另一面的牆朝向不變、說一聲")
    o:tryBuild(70, 70, 0)
    ox, oy, oz = PM.origin()
    local fA, fB = at(np, 0, 0, 0), at(np, 0, 1, 0)
    local wall = nil
    for _, p in ipairs(Plan.at(np, 1, 0, 0)) do if np.items[p.it].id == "pm_wall_01_1" then wall = p end end
    check(PM.state() == "fixed" and ox == 70 and oy == 69 and oz == 0, "點一下定位：原點照轉過的包圍盒對準滑鼠")
    check(fA and fB and wall and wall.d == 5 and at(np, 0, 2, 0) and at(np, 0, 2, 0).d == 0,
        "轉 90 度：橫的兩格地板變直的，左格北邊的牆到右邊那格的西邊（配對面 d＝5）")
    check(disk["MinidoracatBuilder/plans/" .. tostring(np.file)] ~= nil and PS.load().file == np.file, "定位後存檔並記進地上藍圖")
    check(PM.turnPiece({ d = 5 }, { id = "pm_wall_01_1" }) == 0 and select(2, PM.turnPiece({ d = 5 }, { id = "pm_wall_01_1" })) == 0
        and select(2, PM.turnPiece({ d = 0 }, { id = "pm_wall_01_1" })) == 1, "轉向：西牆轉北牆不移格；北牆轉東邊移到右邊那格")
    local cd = { PM.turnPiece({ d = 0 }, { id = "pm_chair_01_0" }) }
    local c2 = PM.turnPiece({ d = cd[1] }, { id = "pm_chair_01_0" })
    local c3 = PM.turnPiece({ d = c2 }, { id = "pm_chair_01_0" })
    local c4 = PM.turnPiece({ d = c3 }, { id = "pm_chair_01_0" })
    check(cd[1] == 4 and c2 == 1 and c3 == 2 and c4 == 0, "轉向：四面家具南→西→北→東，轉四次回到 0（和原來一模一樣）")
    B.Recipes = { faces = function() return { n = 2, 1, 3 } end }
    check(PM.turnPiece({ d = 1 }, { id = "recipe:x" }) == 3 and PM.turnPiece({ d = 3 }, { id = "recipe:x" }) == 1
        and PM.turnPiece({ d = 2 }, { id = "recipe:x" }) == nil, "配方片照 Recipes.faces 循環；沒有的面回 nil")
    B.Recipes = { faces = function() return nil end }

    -- 虛影：一幀最多 512 片、近的先；完成的不畫；隱藏時只畫閃的
    PM.clear()
    local big = Plan.new("大")
    local bf = Plan.item(big, "pm_floor_01_0")
    for y = 0, 63 do for x = 0, 63 do Plan.add(big, x, y, 0, 0, 0, bf) end end
    PM.place(big, 0)
    drags[0]:isValid(sq(50, 50, 0))
    drags[0]:tryBuild(50, 50, 0)
    ghostN, ghostAt = 0, {}
    PG.draw()
    check(PG.lastDrawn == 512 and ghostN == 512 and ghostAt["50,50,0"], "4,096 片：一幀只畫 512 片，玩家腳下那片有畫")
    PG.DRAW_MAX = 10
    PG.draw()
    check(PG.lastDrawn == 10, "植入：上限改 10 就只畫 10 片（上限確實在管）")
    PG.DRAW_MAX = 512
    fakeCheck = function(p) return p.x + big.ox == 50 and p.y + big.oy == 50 and "done" or nil end
    ghostN, ghostAt = 0, {}
    PG.draw()
    check(not ghostAt["50,50,0"] and ghostAt["51,50,0"] and PG.lastDrawn == 512, "蓋好的片（done）不畫，換下一片補上")
    fakeCheck = nil
    PM.setHidden(true)
    ghostN = 0
    PG.draw()
    check(ghostN == 0 and PS.load().hidden == true, "隱藏：不畫，記進存檔")
    PG.flash(at(big, 0, 0, 0))
    PG.flash(at(big, 1, 0, 0))
    PG.draw()
    check(ghostN == 2 and PG.lastDrawn == 2, "隱藏時「在哪」照閃：一秒內叫的片一起閃")
    PM.setHidden(false)

    -- 按鍵登記：接在本工具那一節後面，上一步、下一步帶 Ctrl
    keyBinding, Keyboard = {}, { KEY_Z = 44, KEY_Y = 21, KEY_DELETE = 211 }
    PM.initBinds()
    check(#keyBinding == 4 and keyBinding[1].value == PM.BIND_UNDO and keyBinding[1].ctrl == true and keyBinding[2].key == 21
        and keyBinding[3].key == 211 and keyBinding[4].key == 0, "按鍵：上一步 Ctrl+Z、下一步 Ctrl+Y、刪除 Delete、隱藏預設不綁")

    PM.clear()
    PM.playerNum = 0
    for k in pairs(Cur.hook) do Cur.hook[k] = nil end
    for k, v in pairs(real.hook) do Cur.hook[k] = v end
    getSpecificPlayer, getCell, getText, getCore, getWorld = real.spec, real.cell, real.text, real.core, real.world
    getFileReader, getFileWriter, listFilesInZomboidLuaDirectory = real.reader, real.writer, real.list
    JoypadState, ISBuildingObject, Msg.toast, B.PlanCheck, B.Client.build = real.joy, real.IBO, real.toast, real.PC, real.build
    Keyboard, KeybindId, keyBinding, MinidoracatUI, UIManager = real.kb, real.kid, real.binding, real.ui, real.um
    ISUIElement, spriteMap, spriteOrder, B.Recipes, B.Runner = real.el, real.map, real.order, real.recipes, real.runner
end)()

-- ===== 藍圖：面板與藍圖庫 =====
;(function()
    print("藍圖：面板與藍圖庫（匯入四種狀態、換項目、刪除確認、改名、三種排序、分幀檔頭、告知只一次、沙盒關照圖蓋）")
    local B = MinidoracatBuilder
    require "MinidoracatBuilder/Plan"
    require "MinidoracatBuilder/PlanFile"
    require "MinidoracatBuilder/PlanStore"
    require "MinidoracatBuilder/PlanLibrary"
    require "MinidoracatBuilder/PlanPanel"
    local Plan, PF, L, P = B.Plan, B.PlanFile, B.PlanLibrary, B.PlanPanel
    local real = { reader = getFileReader, writer = getFileWriter, list = listFilesInZomboidLuaDirectory, ui = MinidoracatUI,
        panel = ISPanel, tm = getTextManager, font = UIFont, joy = JoypadState, kb = Keyboard, item = getItemName,
        top = getPlayerScreenTop, left = getPlayerScreenLeft, sw = getPlayerScreenWidth, sh = getPlayerScreenHeight,
        world = getWorld, core = getCore, wui = B.Window and B.Window.ui, PM = B.PlanMode, PC = B.PlanCheck, R = B.Runner,
        PG = B.PlanGhost, cap = B.Capture, toast = B.Messages.toast, head = PF.head,
        auto = SandboxVars.MinidoracatBuilder.AllowAutoBuild, step = clockStep, ontick = handlers.OnTick }
    clockStep = 0
    handlers.OnTick = {}
    getWorld = function() return { getWorld = function() return "PlanUI" end } end
    getCore = function() return { getGameMode = function() return { toString = function() return "Sandbox" end } end } end
    getItemName = function(ft) return ft end
    Keyboard = { KEY_LEFT = 203, KEY_RIGHT = 205, KEY_UP = 200, KEY_DOWN = 208, KEY_RETURN = 28 }
    JoypadState = { players = {} }

    -- 假磁碟（同藍圖資料那段）
    local disk = {}
    getFileWriter = function(p, _, append)
        local buf = append and (disk[p] or "") or ""
        return { write = function(_, s) buf = buf .. s end, close = function() disk[p] = buf end }
    end
    getFileReader = function(p)
        if disk[p] == nil then return nil end
        local lines, i = {}, 0
        for l in disk[p]:gmatch("[^\n]+") do lines[#lines + 1] = l end
        return { readLine = function() i = i + 1; return lines[i] end, close = function() end }
    end
    listFilesInZomboidLuaDirectory = function(dir)
        local names = {}
        for p in pairs(disk) do
            local name = p:sub(#dir + 2)
            if p:sub(1, #dir + 1) == dir .. "/" and not name:find("/", 1, true) then names[#names + 1] = name end
        end
        table.sort(names)
        return javaList(names)
    end
    local function wipePlans()
        for p in pairs(disk) do
            if p:sub(1, 25) == "MinidoracatBuilder/plans/" then disk[p] = nil end
        end
    end
    local function has(list, x)
        for _, v in ipairs(list) do if v == x then return true end end
        return false
    end

    -- 假框架：只記狀態，不畫
    local noop = function() end
    local E = { initialise = noop, addToUIManager = noop, removeFromUIManager = noop, bringToTop = noop, setYScroll = noop,
        drawText = noop, drawTextRight = noop, drawRect = noop, drawRectBorder = noop }
    function E.addChild(s, c) s.children[#s.children + 1] = c end
    function E.clearChildren(s) s.children = {} end
    function E.setX(s, v) s.x = v end
    function E.setY(s, v) s.y = v end
    function E.setWidth(s, v) s.width = v end
    function E.setHeight(s, v) s.height = v end
    function E.getIsVisible(s) return s.visible end
    function E.setVisible(s, v) s.visible = v end
    function E.close(s)
        s.visible = false
        if s.onClose then s.onClose(s) end
    end
    function E.setEnabled(s, v) s.enabled = v end
    function E.setTitle(s, t) s.title = t end
    function E.getText(s) return s.text end
    function E.setText(s, t) s.text = t end
    function E.contentWidth(s) return s.width - 12 end
    function E.contentTop() return 24 end
    function E.setItems(s, items) s.items = items end
    function E.setSelectedIndex(s, i) s.sel = i end
    function E.getSelected(s) return s.selected end
    function E.setSelected(s, id) s.selected = id end
    local function el(o)
        o.x, o.y, o.width, o.height = o.x or 0, o.y or 0, o.width or 60, o.height or 20
        o.children, o.visible, o.enabled = {}, true, true
        return setmetatable(o, { __index = E })
    end
    local dialogs = {}
    local col = { r = 1, g = 1, b = 1 }
    local UI = { CAPABILITIES = { dialog = true },
        Theme = { create = function() return { colors = { text = col, textMuted = col, warning = col, success = col } } end },
        Text = { fit = function(s) return s end, wrap = function(s) return { s } end },
        Window = { new = function(o) return el({ width = o.width, height = o.height, title = o.title, onClose = o.onClose }) end },
        Button = { new = function(o) return el({ title = o.title, style = o.style, target = o.target, onClick = o.onClick }) end },
        TextField = { new = function(o) return el({ width = o.width, text = o.text or "", onChange = o.onChange, field = true }) end },
        Dropdown = { new = function(o)
            return el({ x = o.x, y = o.y, width = o.width, options = o.options, selected = o.selected, onChange = o.onChange })
        end, close = noop },
        ScrollPanel = { new = function(o) return el({ x = o.x, y = o.y, width = o.width, height = o.height }) end },
        Table = { new = function(o)
            return el({ x = o.x, y = o.y, width = o.width, height = o.height, items = {}, onSelect = o.onSelect })
        end },
        Tabs = { new = function(o) return el({ width = 100, selected = o.selected, onSelect = o.onSelect }) end },
        Dialog = { show = function(o)
            dialogs[#dialogs + 1] = o
            return o
        end } }
    MinidoracatUI = { v1 = UI }
    if B.Window then B.Window.ui = function() return UI end end
    ISPanel = { new = function(_, x, y, w, h) return el({ x = x, y = y, width = w, height = h }) end }
    UIFont = UIFont or { Small = 0, Medium = 1 }
    getTextManager = function()
        return { getFontHeight = function() return 16 end, MeasureStringX = function(_, _, s) return #s * 7 end }
    end
    getPlayerScreenTop, getPlayerScreenLeft = function() return 0 end, function() return 0 end
    getPlayerScreenWidth, getPlayerScreenHeight = function() return 1280 end, function() return 720 end

    -- 假的藍圖模組
    local states, pieceState = {}, {}
    B.PlanCheck = { item = function(id) return states[id] or "ok", nil, nil end,
        state = function(p)
            local s = pieceState[p]
            if s then return s[1], s[2] end
            return "ok"
        end,
        counts = function() return { n = 0, done = 0 } end,
        materials = function()
            return { need = { ["Base.Plank"] = 4, ["Base.Nails"] = 2 }, have = { ["Base.Plank"] = 1, ["Base.Nails"] = 5 },
                tools = { { tag = "Hammer", has = false } }, recipes = {} }
        end }
    local ground, placed, clearFail, blanked = nil, 0, false, 0
    B.PlanMode = { plan = function() return ground end,
        place = function(p)
            ground, placed = p, placed + 1
            return true
        end,
        clear = function()
            if clearFail then return false, "WRITE" end
            ground = nil
            return true
        end,
        -- 照介面：地上那張是 oldFile 才改；newFile 是 nil＝刪掉了
        retarget = function(old, nf, name)
            if not ground or old == nil or ground.file ~= old then return false end
            ground.file = nf
            if nf and name then ground.name = name end
            return true
        end,
        blank = function()
            if ground then return false, "BUSY" end
            ground, blanked = Plan.new("Blank"), blanked + 1
            return true
        end,
        -- 照介面：地上那張是同一個檔的另一份、定住的才換；規劃中回 EDITING
        adopt = function(p)
            if not ground or ground == p or p.file == nil or ground.file ~= p.file then return false end
            if B.PlanMode.state and B.PlanMode.state() == "edit" then return false, "EDITING" end
            ground = p
            return true
        end,
        changed = noop, origin = function() return 100, 100, 0 end,
        level = function() return 0 end, toggle = noop, pickUp = noop, save = function() return true end }
    local started = 0
    B.Runner = { state = function() return "idle" end,
        start = function()
            started = started + 1
            return nil, "NOTHING"
        end,
        pause = noop, reason = function() return nil end, progress = function() return { done = 0, total = 0 } end,
        changed = noop, boxes = function() return {} end, summary = function() return nil end, removeBox = noop,
        codeText = function(c) return "code:" .. c end }
    local flashed = 0
    B.PlanGhost = { flash = function() flashed = flashed + 1 end }
    B.Capture = nil
    local toasts = {}
    B.Messages.toast = function(_, text) toasts[#toasts + 1] = text end
    L.v, L.st, L.imp, L.pick, P.v, P.hooked = nil, nil, nil, nil, nil, nil

    -- 一張四種狀態都有的藍圖：能蓋 3 片、缺圖 2 片（Mod X）、關掉 1 片、不開放 4 片
    local function sample(name)
        local pl = Plan.new(name)
        local a = Plan.item(pl, "okay_01_0")
        local b = Plan.item(pl, "gone_01_0", { mod = "ModX", modName = "Mod X", workshop = "123", version = "1.0" })
        local c = Plan.item(pl, "off_01_0")
        local d = Plan.item(pl, "shut_01_0")
        for i = 0, 2 do Plan.add(pl, i, 0, 0, 0, 0, a) end
        for i = 0, 1 do Plan.add(pl, i, 1, 0, 0, 0, b) end
        Plan.add(pl, 0, 2, 0, 0, 0, c)
        for i = 0, 3 do Plan.add(pl, i, 3, 0, 0, 0, d) end
        return pl, a, b, c, d
    end
    local BAD = { gone_01_0 = "missing", off_01_0 = "off", shut_01_0 = "closed" }
    local function setStates(t)
        states = {}
        for k, v in pairs(t) do states[k] = v end
        L.resetStates()
    end
    setStates(BAD)

    do -- 壞的分享碼、壞檔：一句原因、不當掉
        local plan, err = L.parseCode("MBLD1;junk")
        check(plan == nil and type(err) == "string" and err:find("IGUI_MBLD_PlanErr_", 1, true) == 1, "壞的分享碼：回一句原因、不當掉")
        check(L.errText("CHECKSUM", 3) == "IGUI_MBLD_PlanErr_CHECKSUMIGUI_MBLD_PlanErr_At"
            and L.errText("CHECKSUM", 0) == "IGUI_MBLD_PlanErr_CHECKSUM" and L.errText("WHAT", 0) == "IGUI_MBLD_PlanErr_Other",
            "原因碼：認得的用自己的句子、有位置才加位置；不認得的歸其他")
        local good = PF.share((sample("Share")), false)
        check(L.parseCode(good) ~= nil and L.parseCode(good).n == 10, "反面：好的分享碼讀得回來")
        disk["MinidoracatBuilder/plans/bad.txt"] = "junk\n"
        local p2, e2 = L.loadFile("bad.txt")
        local p3, e3 = L.loadFile("none.txt")
        check(p2 == nil and e2 ~= nil and p3 == nil and e3 == "IGUI_MBLD_PlanErr_NO_FILE", "壞檔、沒有的檔：回原因")
        check(L.import(0) and L.imp ~= nil, "匯入框：打得開")
        local imp = L.imp
        imp:setCode("junk")
        imp:check()
        check(imp.plan == nil and imp.err ~= nil and imp.storeBtn.enabled == false, "匯入框：壞的碼寫出原因、不能存")
        imp:setCode(good)
        imp:check()
        check(imp.plan ~= nil and imp.err == nil and imp.storeBtn.enabled == true and #imp.box.children > 0,
            "反面：好的碼列出結果、可以存")
        L.closeImport()
        disk["MinidoracatBuilder/plans/bad.txt"] = nil
    end

    do -- 匯入結果：四種狀態的片數
        local pl = sample("Four")
        local s = L.summary(pl.items)
        check(s.n == 10 and s.ok == 3 and s.missing == 2 and s.off == 1 and s.closed == 4, "四種狀態：能蓋 3、缺 2、關掉 1、不開放 4")
        check(#s.mods == 1 and s.mods[1].workshop == "123" and s.mods[1].n == 2, "缺的照 MOD 分組：名稱、工作坊 ID、片數")
        local ws = false
        for _, ln in ipairs(L.describe(s, true)) do if ln.ws == "123" then ws = true end end
        check(ws, "沒啟用的 MOD 那行附工作坊 ID（給「開工作坊頁」）")
        setStates({ off_01_0 = "off", shut_01_0 = "closed" })
        local s2 = L.summary(pl.items)
        check(s2.missing == 0 and s2.ok == 5 and #s2.mods == 0, "反面：MOD 回來後缺的變能蓋")
        setStates(BAD)
    end

    do -- 把缺的換成這裡有的
        local pl, _, b, _, d = sample("Swap")
        local n = L.swap(pl, b, "fresh_01_0")
        local s = L.summary(pl.items)
        check(n == 2 and s.missing == 0 and s.ok == 5 and s.n == 10, "換掉缺的一款：2 片改成能蓋，總數不變")
        states.shut2_01_0 = "closed"
        local n2, err = L.swap(pl, d, "shut2_01_0")
        check(n2 == nil and err == "IGUI_MBLD_Imp_SwapBad" and pl.items[d].n == 4, "反面：換成這裡也不能蓋的：不換、說原因")
        check(L.guessKind("walls_exterior_01_0") == "wall" and L.guessKind("fixtures_doors_01_0") == "door"
            and L.guessKind("x_01_0") == "furniture", "換項目：照圖塊名猜種類")
        setStates(BAD)
    end

    do -- 刪除要確認
        wipePlans()
        local pl = sample("Gone")
        local file = L.store(pl)
        dialogs = {}
        local done
        local d = L.askRemove(file, pl.name, pl.n, 0, function(ok) done = ok end)
        check(file == "gone.txt" and d ~= nil and d.danger == true and has(PF.list(), file), "刪除：先跳危險確認框，還沒刪")
        d.onResult(false)
        check(has(PF.list(), file) and done == nil, "反面：按取消不刪")
        L.askRemove(file, pl.name, pl.n, 0, function(ok) done = ok end)
        dialogs[#dialogs].onResult(true)
        check(not has(PF.list(), file) and done == true, "按確認才刪")
    end

    local USED = "MinidoracatBuilder/plans-used.txt"
    local function three()
        wipePlans()
        local function mk(name, n)
            local pl = Plan.new(name)
            local it = Plan.item(pl, "okay_01_0")
            for i = 1, n do Plan.add(pl, i, 0, 0, 0, 0, it) end
            PF.save(pl, PF.fileName(name))
        end
        mk("Bravo", 1)
        mk("Alpha", 3)
        mk("Charlie", 2)
        disk[USED] = "alpha.txt\t100\ncharlie.txt\t300\n#end\n"
    end
    local function order(sort)
        L.st.sort = sort
        local t = {}
        for i, e in ipairs(L.view()) do t[i] = e.file end
        return table.concat(t, ",")
    end

    do -- 三種排序、搜尋
        three()
        check(L.open(0) and L.visible(), "藍圖庫：打得開")
        while L.pending() > 0 do L.pump(1000) end
        check(order("used") == "charlie.txt,alpha.txt,bravo.txt", "排序：最近用過（沒用過的排後面）")
        check(order("name") == "alpha.txt,bravo.txt,charlie.txt", "排序：名稱")
        check(order("pieces") == "alpha.txt,charlie.txt,bravo.txt", "排序：片數多的在前")
        L.st.query = "char"
        check(order("name") == "charlie.txt", "搜尋：名稱不分大小寫")
        L.st.query = ""
        disk[USED] = "alpha.txt\t100\ncharlie.txt\t300\n"
        check(L.loadUsed() == true and order("used") == "charlie.txt,alpha.txt,bravo.txt" and L.markUsed("bravo.txt", nil) == true
            and disk[USED]:find("#end\n$") ~= nil and disk[USED]:find("alpha.txt\t100\n", 1, true) ~= nil
            and disk[USED]:find("charlie.txt\t300\n", 1, true) ~= nil, "少了 #end 的紀錄：收讀得出來的行，下次寫入補齊")
        local rd = getFileReader
        getFileReader = function() return nil end
        local before = disk[USED]
        check(L.loadUsed() == false and L.markUsed("alpha.txt", nil) == false and disk[USED] == before,
            "反面：讀不到紀錄檔時不載入也不覆寫")
        getFileReader = rd
        L.loadUsed()
        local list = {}
        for i = 1, 2000 do list[i] = 2001 - i end
        L.sort(list, function(a, b) return a < b end)
        local sorted = true
        for i = 1, 2000 do if list[i] ~= i then sorted = false end end
        check(sorted, "合併排序：2,000 筆倒序排對（不遞迴）")
    end

    do -- 改名更新清單、用過的時間跟著搬
        three()
        L.open(0)
        while L.pending() > 0 do L.pump(1000) end
        L.markUsed("bravo.txt", nil)
        local nf = L.rename("bravo.txt", "Delta")
        L.v:reload(nf)
        while L.pending() > 0 do L.pump(1000) end
        L.v:refreshRows()
        local shown = false
        for _, row in ipairs(L.v.list.items) do
            if row.e.file == "delta.txt" and row.cells[1] == "Delta" then shown = true end
        end
        check(nf == "delta.txt" and shown and L.st.byFile["bravo.txt"] == nil and L.v.selected == L.st.byFile["delta.txt"],
            "改名：清單換成新名稱與檔名、選著它")
        check(L.usedAt("delta.txt") ~= nil and L.usedAt("bravo.txt") == nil, "改名：上次用的時間搬到新檔名")
        dialogs = {}
        L.v:act("delete")
        dialogs[#dialogs].onResult(true)
        check(L.st.byFile["delta.txt"] == nil and #L.v.list.items == 2 and L.usedAt("delta.txt") == nil, "清單上刪除：確認後清單少一列")
    end

    do -- 1,000 個檔：打開時不讀檔頭，之後每幀最多 HEAD_MAX 個
        wipePlans()
        local text = PF.encode((sample("Many")))
        for i = 1, 1000 do disk["MinidoracatBuilder/plans/m" .. i .. ".txt"] = text end
        local heads = 0
        PF.head = function(f)
            heads = heads + 1
            return real.head(f)
        end
        L.open(0)
        check(heads == 0 and #L.st.files == 1000 and #L.v.list.items == 1000, "1,000 個檔：打開時只列檔名、不讀檔頭")
        L.v:pump()
        check(heads > 0 and heads <= L.HEAD_MAX, "一幀最多讀 " .. L.HEAD_MAX .. " 個檔頭（讀了 " .. heads .. "）")
        local frames = 1
        while L.pending() > 0 and frames < 100 do
            L.v:pump()
            frames = frames + 1
        end
        check(heads == 1000 and frames == 40 and L.v.list.items[1].cells[3] == "10" and L.v.list.items[1].cells[4] == "7",
            "補完 1,000 個檔頭（40 幀），列出片數與這裡不能蓋的片數")
        PF.head = real.head
        L.close()
    end

    do -- MOD 更新或下架的告知：多了不能蓋的才通知，同樣的只通知一次
        local pl = sample("Ground")
        ground = pl
        setStates({})
        toasts = {}
        check(L.notices() == false and #toasts == 0, "告知：都能蓋時不通知")
        states.gone_01_0 = "missing"
        check(L.notices() == true and #toasts == 1, "告知：變成不能蓋時通知一則")
        check(L.notices() == false and #toasts == 1, "反面：狀態沒再變，下次進遊戲不再通知")
        states.off_01_0 = "off"
        check(L.notices() == true and #toasts == 2, "告知：又多一種不能蓋的，再通知")
        states.shut_01_0 = "closed"
        L.baseline(pl)
        check(L.notices() == false and #toasts == 2, "擺上時記基準：匯入時就缺的不再通知")
        ground = nil
        L.startNotices()
        for _ = 1, 3 do fire("OnTick") end
        local waiting = count("OnTick")
        ground = pl
        states.okay_01_0 = "missing"
        fire("OnTick")
        check(waiting == 1 and #toasts == 3 and count("OnTick") == 0, "進遊戲：等到地上的藍圖才檢查一次，然後摘掉自己")
        L.startNotices()
        ground = nil
        for _ = 1, L.WAIT_TICKS + 1 do fire("OnTick") end
        check(count("OnTick") == 0 and #toasts == 3, "反面：一直沒有藍圖，等滿就放棄、不通知")
    end

    do -- 面板：分組、閃、平面圖、手把、照圖蓋按鈕
        local pl, a, b, _, d = sample("Panel")
        ground = nil
        check(P.open(0) and L.visible() and not P.visible(), "面板：地上沒有藍圖時改開藍圖庫")
        L.close()
        ground = pl
        setStates(BAD)
        Plan.each(pl, function(p)
            local id = pl.items[p.it].id
            if id == "shut_01_0" then pieceState[p] = { "closed", "DISABLED_TILESET" }
            elseif id == "gone_01_0" then pieceState[p] = { "missing", "UNKNOWN" }
            elseif id == "off_01_0" then pieceState[p] = { "off", "DISABLED_KIND" }
            elseif p.x == 0 then pieceState[p] = { "short", "NO_MATERIAL" }
            elseif p.x == 1 then pieceState[p] = { "done" } end
        end)
        local mat = P.materials(nil)
        local groups = P.groups(mat)
        check(#groups == 4 and groups[1].code == "closed" and groups[1].n == 4 and groups[2].code == "missing"
            and mat.short["Base.Plank"] == 3 and mat.short["Base.Nails"] == nil and mat.missTools[1] == "Hammer",
            "蓋不了的片照原因分組（片多的在前）；缺料只算缺的")
        check(P.flash(groups[1].pieces) == 4 and flashed == 4, "點一組：那幾片都閃")
        local g = P.grid(pl, 0)
        check(#g.fine == 30 and g.counts.blocked == 7 and g.counts.short == 1 and g.counts.done == 1 and g.counts.ok == 1,
            "平面圖：一格一塊，圖例每種狀態有片數")
        SandboxVars.MinidoracatBuilder.AllowAutoBuild = false
        check(P.open(0) and P.visible() and P.v.goBtn.enabled == false and P.statusLines()[2][1] == "IGUI_MBLD_Plan_AutoOff",
            "沙盒關照圖蓋：按鈕停用、寫出原因")
        SandboxVars.MinidoracatBuilder.AllowAutoBuild = nil
        P.v:refresh()
        check(P.v.goBtn.enabled == true, "反面：沙盒沒關時能按")
        check(P.onGo(0) == "IGUI_MBLD_Plan_Start_NOTHING" and started == 1, "照圖蓋開不了：原因碼寫成句子")
        B.PlanMode.state = function() return "edit" end
        P.v:refresh()
        check(P.v.goBtn.enabled == false and P.statusLines()[2][1] == "IGUI_MBLD_Run_EDIT" and P.onGo(0) == "IGUI_MBLD_Run_EDIT"
            and started == 1, "規劃中：照圖蓋停用、寫出原因，硬按也不開始")
        B.PlanMode.state = function() return "fixed" end
        P.v:refresh()
        check(P.v.goBtn.enabled == true, "反面：規劃完成後又能按")
        B.PlanMode.state = nil
        local v = P.v
        v:show("map")
        v:refreshMap()
        local cv = v.canvas
        cv.render(cv)
        v.cx, v.cy = 0, 0
        check(cv.onFocusKey(cv, Keyboard.KEY_LEFT) == false and cv.onFocusKey(cv, Keyboard.KEY_RIGHT) == true and v.cx == 1,
            "手把：方向鍵移格子，到邊才讓焦點離開")
        flashed = 0
        cv.forceClick(cv)
        check(flashed == #Plan.at(pl, 1, 0, 0) and flashed > 0, "手把 A：閃游標那格的片")
        v.coarse, v.drawMs, v.frames = false, 0, 0
        for _ = 1, P.SAMPLE do cv.render(cv) end
        check(v.coarse == false, "反面：畫得快時不改粗格")
        clockStep = 2
        for _ = 1, P.SAMPLE do cv.render(cv) end
        clockStep = 0
        check(v.coarse == true, "平面圖：32 幀平均超過 1 毫秒改成 2×2 一塊")
        P.close()
        pieceState = {}
    end

    do -- 審查：改名、刪除時地上那張跟著改（不寫回舊檔名、不蓋掉重用檔名的新藍圖）
        three()
        ground = PF.load("alpha.txt")
        local nf = L.rename("alpha.txt", "Echo")
        check(nf == "echo.txt" and ground.file == "echo.txt" and ground.name == "Echo", "改名：地上那張的檔名與名稱跟著改")
        L.rename("bravo.txt", "Foxtrot")
        check(ground.file == "echo.txt", "反面：改別張不動地上那張")
        check(L.remove("echo.txt") == true and ground.file == nil, "刪除：地上那張不再連到這個檔")
        local fresh = Plan.new("Echo")
        Plan.add(fresh, 0, 0, 0, 0, 0, Plan.item(fresh, "okay_01_0"))
        local file = L.store(fresh)
        local text = disk["MinidoracatBuilder/plans/echo.txt"]
        local gf = ground.file or PF.fileName(ground.name) -- 之後存地上那張（PlanMode 的取檔名規則）
        PF.save(ground, gf)
        check(file == "echo.txt" and gf ~= file and disk["MinidoracatBuilder/plans/echo.txt"] == text,
            "刪除後重用同一個檔名：之後存地上那張不會蓋掉新藍圖")
        ground = nil
    end

    do -- 審查：收起失敗就停（換一張、面板收起、面板完成）
        local a, b = sample("Keep"), sample("Next")
        ground, placed, clearFail = a, 0, true
        L.open(0)
        dialogs = {}
        L.placePlan(b, 0)
        dialogs[#dialogs].onResult(true)
        check(ground == a and placed == 0 and L.visible(), "換一張：地上那張存不了就不換、藍圖庫留著")
        clearFail = false
        L.placePlan(b, 0)
        dialogs[#dialogs].onResult(true)
        check(ground == b and placed == 1, "反面：存得了就換")
        clearFail = true
        P.open(0)
        P.v:act("clear")
        dialogs[#dialogs].onResult(true)
        check(ground == b and P.visible(), "面板收起：存不了時地上那張與面板都留著")
        clearFail = false
        B.PlanMode.toggle = function() return false, "WRITE" end
        P.v:act("edit")
        check(P.visible(), "面板完成：存不了時面板留著")
        B.PlanMode.toggle = noop
        P.v:act("clear")
        dialogs[#dialogs].onResult(true)
        check(ground == nil and not P.visible(), "反面：存得了就收起、關面板")
    end

    do -- 審查：新的空白藍圖（沒有、定住、規劃中三種）
        ground, blanked, clearFail = nil, 0, false
        dialogs = {}
        L.open(0)
        local btn
        for _, c in ipairs(L.v.win.children) do if c.title == "IGUI_MBLD_Lib_New" then btn = c end end
        btn.onClick(L.v)
        check(blanked == 1 and #dialogs == 0 and ground ~= nil and not L.visible(), "空白藍圖：地上沒有時直接開、不問")
        local fixed = sample("Fixed")
        for _, mode in ipairs({ "fixed", "edit" }) do
            ground, blanked = fixed, 0
            L.newBlank(0)
            dialogs[#dialogs].onResult(false)
            check(ground == fixed and blanked == 0, "反面（" .. mode .. "）：按取消不動地上那張")
            clearFail = true
            L.open(0)
            L.newBlank(0)
            dialogs[#dialogs].onResult(true)
            check(ground == fixed and blanked == 0 and L.visible(), "空白藍圖（" .. mode .. "）：收不起來就不開新的、藍圖庫留著")
            clearFail = false
            L.newBlank(0)
            dialogs[#dialogs].onResult(true)
            check(ground ~= fixed and ground ~= nil and blanked == 1, "空白藍圖（" .. mode .. "）：先收起再開新的")
        end
        ground = nil
    end

    do -- 審查：匯入框沒有可輸入的文字框，只能按鈕貼上；超長的不收、也沒有任何路徑送進剪貼簿
        local realClip = Clipboard
        local clip, sent = "", {}
        Clipboard = { getClipboard = function() return clip end, setClipboard = function(s) sent[#sent + 1] = #s end }
        L.import(0)
        local imp = L.imp
        local field, pasteBtn = false, nil
        for _, c in ipairs(imp.win.children) do
            if c.field then field = true end
            if c.title == "IGUI_MBLD_Imp_Paste" then pasteBtn = c end
        end
        check(not field and pasteBtn ~= nil and pasteBtn.y < imp.fileDD.y and imp.status.y == pasteBtn.y
            and imp.status.y + imp.status.height <= imp.fileDD.y, "匯入框：沒有原生文字框；貼上鈕在檔案清單上面，狀態行不蓋到下一列")
        check(imp.code == nil and imp.status.lines[1].s:find("IGUI_MBLD_Imp_CodeHint", 1, true) == 1, "還沒貼：狀態行說先複製再按貼上")
        clip = string.rep("A", PF.SHARE_MAX + 1)
        imp:paste()
        check(imp.code == nil and imp.err == "IGUI_MBLD_Imp_TooLong", "太長的剪貼簿不收，改請用檔案")
        clip = string.rep("A", 50000) .. "\195\169"
        imp:paste()
        check(imp.code == nil and imp.err == "IGUI_MBLD_Imp_TooLong", "有非 ASCII 字、轉 UTF-8 可能超過上限：不收")
        clip = PF.share((sample("Paste")), false)
        imp:paste()
        check(imp.code == clip and imp.plan ~= nil and imp.status.lines[1].s:find("IGUI_MBLD_Imp_CodeRead", 1, true) == 1,
            "反面：正常的分享碼貼得進來，狀態行寫已讀到")
        clip = PF.share((sample("Again")), false)
        imp:paste()
        check(imp.code == clip and imp.plan.name == "Again", "再按一次貼上：換成新的")
        imp.fileDD.selected = nil
        imp.fileDD.onChange(imp)
        check(imp.code == nil and imp.status.lines[1].s:find("IGUI_MBLD_Imp_CodeHint", 1, true) == 1, "選資料夾裡的檔：清掉已讀到的分享碼")
        check(L.copy(string.rep("A", PF.SHARE_MAX + 1)) == false, "反面：超長的分享碼也不寫進剪貼簿")
        local over = false
        for _, n in ipairs(sent) do if n > PF.SHARE_MAX then over = true end end
        check(not over, "整個匯入流程沒有任何超過上限的文字送進剪貼簿")
        L.closeImport()
        Clipboard = realClip
    end

    do -- 審查：檔名不合規則沒列出的檔要說；匯入結果列數有上限
        three()
        local list = PF.list
        PF.list = function() return list(), 3 end
        L.open(0)
        local drawn = {}
        L.v:headerRender({ drawText = function(_, s) drawn[#drawn + 1] = s end, drawTextRight = noop })
        check(L.st.skipped == 3 and drawn[1]:find("IGUI_MBLD_Lib_Skipped", 1, true) ~= nil, "藍圖庫：寫出幾個檔沒列出")
        L.import(0)
        local withSkip = #L.imp.box.children
        L.closeImport()
        PF.list = list
        L.import(0)
        check(withSkip == #L.imp.box.children + 1, "匯入框：沒列出的檔多一行說明")
        local pl = Plan.new("Huge")
        local st = {}
        for i = 1, 50 do
            local id = "miss" .. i .. "_01_0"
            st[id] = "missing"
            Plan.add(pl, i, 0, 0, 0, 0, Plan.item(pl, id, i <= 40 and { mod = "M" .. i } or nil))
        end
        setStates(st)
        local mods, more = 0, 0
        for _, ln in ipairs(L.describe(L.summary(pl.items), true)) do
            if ln[1] == "IGUI_MBLD_Imp_ModOff" then mods = mods + 1 end
            if ln[1] == "IGUI_MBLD_Imp_More" then more = more + 1 end
        end
        check(mods == L.LIST_MAX and more == 1, "匯入結果：MOD 行最多 " .. L.LIST_MAX .. " 行，其餘一行帶過")
        local imp = L.imp
        imp.plan = pl
        imp:render()
        local swaps = 0
        for _, c in ipairs(imp.box.children) do if c.title == "IGUI_MBLD_Imp_Swap" then swaps = swaps + 1 end end
        check(swaps == L.LIST_MAX, "匯入結果：換項目最多 " .. L.LIST_MAX .. " 列（共 50 種）")
        L.closeImport()
        L.close()
        setStates(BAD)
    end

    do -- 取不到檔名時說真正的原因（列不出資料夾＝READ）
        local fileName = PF.fileName
        PF.fileName = function() return nil, "READ" end
        local f, err = L.store(Plan.new("NoDir"))
        PF.fileName = fileName
        check(f == nil and err == "IGUI_MBLD_PlanErr_READ", "存進藍圖庫：取不到檔名時說列不出資料夾，不說檔名不合規則")
        local f2 = L.store(sample("HasDir"))
        check(f2 == "hasdir.txt", "反面：取得到檔名照常存")
    end

    do -- 審查第 2 輪：存進藍圖庫寫到地上那張的檔（定住＝地上換成這份；規劃中＝另存新的一張）
        three()
        ground = PF.load("alpha.txt")
        local imp1 = L.loadFile("alpha.txt")
        Plan.add(imp1, 9, 9, 0, 0, 0, Plan.item(imp1, "fresh_01_0"))
        local f1, new1 = L.store(imp1)
        PF.save(ground, ground.file) -- 之後地上那張存檔（收起、完成）
        check(f1 == "alpha.txt" and not new1 and ground == imp1 and PF.load("alpha.txt").n == imp1.n,
            "定住時存進藍圖庫：地上那張換成這份，之後存檔是換過的內容")
        ground = PF.load("bravo.txt")
        local mine = ground
        B.PlanMode.state = function() return "edit" end
        local before = disk["MinidoracatBuilder/plans/bravo.txt"]
        local imp2 = L.loadFile("bravo.txt")
        Plan.add(imp2, 9, 9, 0, 0, 0, Plan.item(imp2, "fresh_01_0"))
        toasts = {}
        L.import(0)
        L.imp.plan = imp2
        L.imp:finish("store")
        local copy = PF.load("bravo2.txt")
        check(ground == mine and ground.file == "bravo.txt" and disk["MinidoracatBuilder/plans/bravo.txt"] == before
            and toasts[1] and toasts[1]:find("IGUI_MBLD_Imp_StoredNew", 1, true) == 1 and copy and copy.n == imp2.n,
            "規劃中存進藍圖庫：另存成新的一張（bravo2.txt）並通知，原檔與地上那張都沒動")
        B.PlanMode.state = nil
        ground = nil
    end

    do -- 審查第 2 輪：面板存檔失敗只讓 PlanMode 說一次；跟著游標時不能存；拿不起來時面板留著
        local pl = sample("PanelSave")
        ground = pl
        P.open(0)
        local save = B.PlanMode.save
        B.PlanMode.save = function() return nil, "STORE" end
        toasts = {}
        P.v:act("save")
        check(#toasts == 0, "面板存檔失敗：不再說一次、不露出原因碼")
        B.PlanMode.save = save
        P.v:act("save")
        check(#toasts == 1 and toasts[1] == "IGUI_MBLD_Plan_Saved", "反面：存好說已存檔")
        B.PlanMode.state = function() return "place" end
        P.v:refresh()
        check(P.v.saveBtn.enabled == false, "跟著游標時：存檔鈕停用")
        B.PlanMode.state = function() return "fixed" end
        P.v:refresh()
        check(P.v.saveBtn.enabled == true, "反面：定住時能存")
        B.PlanMode.state = nil
        B.PlanMode.pickUp = function() return false, "WRITE" end
        P.v:act("move")
        check(P.visible(), "搬：拿不起來（存不了檔）時面板留著")
        B.PlanMode.pickUp = function() return true end
        P.v:act("move")
        check(not P.visible(), "反面：拿起來了就關面板")
        B.PlanMode.pickUp = noop
        ground = nil
    end

    getFileReader, getFileWriter, listFilesInZomboidLuaDirectory = real.reader, real.writer, real.list
    MinidoracatUI, ISPanel, getTextManager, UIFont, JoypadState, Keyboard = real.ui, real.panel, real.tm, real.font, real.joy, real.kb
    getPlayerScreenTop, getPlayerScreenLeft, getPlayerScreenWidth, getPlayerScreenHeight = real.top, real.left, real.sw, real.sh
    getWorld, getCore, getItemName = real.world, real.core, real.item
    if B.Window then B.Window.ui = real.wui end
    B.PlanMode, B.PlanCheck, B.Runner, B.PlanGhost, B.Capture = real.PM, real.PC, real.R, real.PG, real.cap
    B.Messages.toast, PF.head, clockStep, handlers.OnTick = real.toast, real.head, real.step, real.ontick
    SandboxVars.MinidoracatBuilder.AllowAutoBuild = real.auto
    L.v, L.st, L.imp, L.pick, P.v, P.hooked = nil, nil, nil, nil, nil, nil
end)()

-- ===== 藍圖：照圖蓋與材料箱 =====
;(function()
    print("藍圖：照圖蓋與材料箱（Runner 六段順序、一批上限、跳過與總結、暫停、材料箱；選單）")
    local B = MinidoracatBuilder
    require "MinidoracatBuilder/Plan"
    require "MinidoracatBuilder/Queue"
    require "MinidoracatBuilder/PlanStore"
    require "MinidoracatBuilder/Messages"
    require "MinidoracatBuilder/Runner"
    require "MinidoracatBuilder/Menu"
    local Plan, R, Q, PS, Menu = B.Plan, B.Runner, B.Queue, B.PlanStore, B.Menu
    local real = { PM = B.PlanMode, PC = B.PlanCheck, rec = B.Recipes, push = Q.push, cancel = Q.cancel, busy = Q.busy,
        item = Check.item, summary = Materials.summary, resolve = Entry.resolve, face = Entry.face, cells = Entry.cells,
        doorSet = Entry.doorSet, group = Entry.groupCells, alt = Entry.alternate, load = PS.load, save = PS.save,
        step = clockStep, q = ISTimedActionQueue, lu = luautils, xfer = ISInventoryTransferAction, ui = MinidoracatUI,
        core = Core, kb = Keyboard, specific = getSpecificPlayer, auto = sb.AllowAutoBuild, max = sb.MaxCellsPerDrag }
    clockStep = 0
    sb.MaxCellsPerDrag, sb.AllowAutoBuild = 3, nil -- 缺鍵當開
    Core = { getTileScale = function() return 1 end }
    Keyboard = { KEY_ESCAPE = 1 }
    B.Recipes = nil
    local toasts = {}
    MinidoracatUI = { v1 = { Toast = { show = function(o) toasts[#toasts + 1] = o.message end } } }

    -- 本段自己的項目：每種一個代表（車庫門帶寬度，一扇一次）
    local ENT = {}
    for _, k in ipairs({ "floor", "wall", "stairs", "door", "roof", "furniture" }) do ENT["rn_" .. k] = { kind = k, spr = "rn_" .. k } end
    ENT.rn_garage = { kind = "door", spr = "rn_garage", garage = true }
    Entry.resolve = function(id) return ENT[id] end
    Entry.face = function(e) return e.spr end
    Entry.cells = function(spr) return { { 0, 0, 0, spr } } end
    Entry.doorSet = function(spr) return ENT[spr] and ENT[spr].garage and { garage = true } or nil end
    Entry.groupCells = function(_, w)
        local o = {}
        for i = 1, w do o[i] = { i - 1, 0, 0, "rn_garage" } end
        return o
    end
    Entry.alternate = function(s) return s end
    -- Check.item：CODE["x,y,z"]＝{ code, extra, need, pay }；沒列的能蓋。pay＝原地替換的差額（成本表照 Check 只帶 items、uses）
    local CODE = {}
    Check.item = function(_, id, _, a)
        local c = CODE[a[1] .. "," .. a[2] .. "," .. a[3]]
        local info = { entry = ENT[id], cells = { { x = a[1], y = a[2], z = a[3] } },
            total = { items = c and c.need or {}, uses = {}, tools = {} } }
        if c and c.pay then info.replace, info.pay = { had = {} }, c.pay end
        if c then return c.code, c.extra, info end
        return nil, nil, info
    end
    local zero = function() return 0 end
    Materials.summary = function()
        return { items = setmetatable({}, { __index = zero }), uses = setmetatable({}, { __index = zero }), tools = {}, levels = {} }
    end
    -- 假的 PlanMode、PlanCheck：狀態照 S 表
    local OX, OY = 100, 100
    local S, at, touched, cleared, clearOk, shift, editing = {}, {}, 0, 0, true, 0, false
    local pl
    B.PlanCheck = {
        resolve = function(p) local it = pl.items[p.it]; return it and it.id, p.x + OX, p.y + OY, p.z, p.d, p.o, p.w end,
        state = function(p) return S[p] end,
        touch = function() touched = touched + 1 end,
        counts = function()
            local n, d = 0, 0
            Plan.each(pl, function(p) n = n + 1; if S[p] == "done" then d = d + 1 end end)
            return { n = n, done = d }
        end,
        materials = function() return { need = { ["Base.Plank"] = 4 }, have = { ["Base.Plank"] = 1 }, tools = {} } end,
    }
    local PM = { plan = function() return pl end, origin = function() return OX + shift, OY, 0 end,
        state = function() return editing and "edit" or "fixed" end,
        clear = function() cleared = cleared + 1; return clearOk end }
    -- 假的 Queue：記下每次送的；cancel 照 Queue 同步叫 onDone（stopped）
    local pushes, busy = {}, 0
    Q.push = function(_, id, anchors, parts, overlap, opts)
        pushes[#pushes + 1] = { id = id, anchors = anchors, parts = parts, overlap = overlap, opts = opts }
        return #pushes
    end
    Q.cancel = function()
        local j = pushes[#pushes]
        if j and not j.done then
            j.done = true
            j.opts.onDone({ count = #j.anchors, placed = 0, stopped = true })
        end
    end
    Q.busy = function() return busy end
    local function finish(sum)
        local j = pushes[#pushes]
        j.done = true
        sum.count = sum.count or #j.anchors
        j.opts.onDone(sum)
    end
    local function buildAll() -- 最後一批全部蓋好：那幾片變成 done
        local j = pushes[#pushes]
        for _, a in ipairs(j.anchors) do S[at[a[1] .. "," .. a[2] .. "," .. a[3]]] = "done" end
        finish({ placed = #j.anchors, stopped = false })
    end
    -- 假玩家與動作佇列
    local K = player({ id = 77, x = OX + 0.5, y = OY + 0.5 })
    K.chase, K.moving, K.vehicle = 0, false, nil
    function K:isAsleep() return false end
    function K:getVehicle() return self.vehicle end
    function K:getStats() local me = self; return { getNumChasingZombies = function() return me.chase end } end
    function K:isAttackStarted() return false end
    function K:isAiming() return false end
    function K:isJustMoved() return self.moving end
    function K:getMaxWeight() return 3 end
    function K.inv:getCapacityWeight() return K.load or 0 end
    function K.inv:getCountTypeRecurse(ft) return self:count(ft) end
    getSpecificPlayer = function() return K end
    local doing, actions, walks, clears = false, {}, {}, 0
    ISTimedActionQueue = { isPlayerDoingAction = function() return doing end,
        clear = function() clears = clears + 1; actions = {} end,
        hasAction = function(a)
            for _, x in ipairs(actions) do if x == a then return true end end
            return false
        end,
        add = function(a) actions[#actions + 1] = a end }
    luautils = { walkToContainer = function(c) walks[#walks + 1] = c; return true end }
    ISInventoryTransferAction = { new = function(_, _, it, src, dst) return { item = it, src = src, dst = dst } end }
    local store = { boxes = {} }
    PS.load = function() return store end
    PS.save = function(s) store = s; return true end

    local function run(n)
        for _ = 1, n or 1 do
            nowMs = nowMs + 100
            R.tick()
        end
    end
    local function drive() -- 每送一批就整批蓋好，直到停下
        for _ = 1, 200 do
            run(1)
            local j = pushes[#pushes]
            if j and not j.done then buildAll() end
            local s = R.state()
            if s == "done" or s == "paused" then return end
        end
    end
    local function newPlan()
        pl, S, at, CODE, pushes, busy = Plan.new("run"), {}, {}, {}, {}, 0
        R.stop()
    end
    local function put(id, x, y, z, w)
        local p = Plan.add(pl, x, y, z, 0, 0, Plan.item(pl, id), w)
        at[(x + OX) .. "," .. (y + OY) .. "," .. z] = p
        S[p] = "ok"
        return p
    end
    -- 一串批次的（段, 層）有沒有倒退
    local function ordered(list)
        for i = 2, #list do
            local a, b = list[i - 1], list[i]
            local sa, sb2 = R.SEGMENT[ENT[a.id].kind], R.SEGMENT[ENT[b.id].kind]
            if sb2 < sa or (sb2 == sa and b.anchors[1][3] < a.anchors[1][3]) then return false end
        end
        return true
    end

    -- 每個種類都有段（植入：拿掉一種就抓得到）
    local function uncovered()
        local n = 0
        for _, k in ipairs(Entry.KINDS) do if not R.SEGMENT[k] then n = n + 1 end end
        return n
    end
    local keep = R.SEGMENT.light
    R.SEGMENT.light = nil
    local planted = uncovered()
    R.SEGMENT.light = keep
    check(uncovered() == 0 and planted == 1 and R.SEGMENT.floor == 1 and R.SEGMENT.roof == 5 and R.SEGMENT.furniture == 6,
        "Runner.SEGMENT：每個種類都有段，少一種會被抓到")

    -- 沒有藍圖、沙盒關掉
    newPlan()
    B.PlanMode = nil
    local s1, c1 = R.start(K)
    B.PlanMode = PM
    put("rn_floor", 0, 2, 0)
    sb.AllowAutoBuild = false
    local s2, c2 = R.start(K)
    sb.AllowAutoBuild = true
    local s3 = R.start(K)
    local s4, c4 = R.start(K)
    check(s1 == nil and c1 == "NO_PLAN" and s2 == nil and c2 == "OFF" and #pushes == 0 and s3 == true and s4 == nil and c4 == "BUSY",
        "start：沒有藍圖 NO_PLAN、沙盒關掉 OFF 且不送；開著能開始，再按回 BUSY")

    -- 六段順序、一批上限、車庫門一扇一次、缺料跳過並列進總結
    newPlan()
    put("rn_roof", 0, 0, 1)
    put("rn_furniture", 1, 0, 0)
    put("rn_door", 2, 0, 0)
    put("rn_stairs", 3, 0, 0)
    for x = 0, 4 do put("rn_wall", x, 1, 0) end
    put("rn_floor", 0, 2, 0)
    put("rn_floor", 1, 2, 0)
    put("rn_floor", 0, 3, 1)
    put("rn_garage", 5, 5, 0, 2)
    put("rn_garage", 8, 5, 0, 2)
    local shortWall = put("rn_wall", 6, 1, 0)
    S[shortWall] = "short"
    toasts = {}
    check(R.start(K) == true, "照圖蓋開始")
    drive()
    local ids, maxN, garageOk = {}, 0, true
    for i, j in ipairs(pushes) do
        ids[i] = j.id .. "@" .. #j.anchors
        if #j.anchors > maxN then maxN = #j.anchors end
        if j.id == "rn_garage" and (#j.anchors ~= 1 or j.anchors[1][5] ~= 2 or #j.parts[1] ~= 2) then garageOk = false end
        if j.opts.owner ~= "plan" then garageOk = false end
    end
    local seq = table.concat(ids, ",")
    check(seq == "rn_floor@2,rn_floor@1,rn_wall@3,rn_wall@2,rn_stairs@1,rn_door@1,rn_garage@1,rn_garage@1,rn_roof@1,rn_furniture@1",
        "六段順序：地板（先低層）→ 牆 → 樓梯 → 門與車庫門（近的先）→ 屋頂 → 家具：" .. seq)
    check(ordered(pushes) and maxN == 3 and garageOk, "一批不超過一次最多幾格（3）；車庫門一批一扇、帶寬度與整扇虛影；owner＝plan")
    local swapped = { pushes[3], pushes[1] }
    check(not ordered(swapped), "反面：牆排在地板前面會被順序檢查抓到")
    local sum = R.summary()
    check(R.state() == "done" and (R.reason()) == "LEFT" and sum.left == 1 and sum.short.n == 1
        and sum.short.need["Base.Plank"] == 3 and cleared == 0 and touched > 0,
        "缺料的片跳過；這一輪結束 LEFT，總結列 1 片缺料、還差 3 塊木板；沒全蓋好不收藍圖")
    check(toasts[#toasts] and toasts[#toasts]:find("IGUI_MBLD_Run_LEFT", 1, true)
        and toasts[#toasts]:find("IGUI_MBLD_Run_Short", 1, true), "結束時跳一則總結通知")
    -- 補齊後再按：只蓋剩下那片，全部蓋好就收起藍圖
    S[shortWall] = "ok"
    local before = #pushes
    R.start(K)
    drive()
    check(#pushes == before + 1 and (R.reason()) == "DONE" and cleared == 1, "再按照圖蓋：只送剩下的 1 片；全蓋好 DONE、收起藍圖")

    -- 手動拖曳取消照圖蓋的批次 → 暫停 MANUAL；沒有玩家的請求時（走不過去）跳過那一片接著蓋
    newPlan()
    put("rn_floor", 0, 2, 0)
    put("rn_floor", 1, 2, 0)
    R.start(K)
    run(1)
    busy = 1
    Q.cancel()
    run(1)
    check(#pushes == 1 and R.state() == "paused" and (R.reason()) == "MANUAL", "手拖時（Queue 取消照圖蓋那一批、排著玩家的）：暫停 MANUAL")
    busy = 0
    R.start(K)
    run(1)
    Q.cancel()
    run(2)
    check(R.state() ~= "paused" and #pushes == 3 and #pushes[3].anchors == 1, "反面：沒有玩家的請求（走不過去）不算手動，跳過那一片接著蓋")

    -- 伺服器拒絕整批：暫停且不再送；只拒一片：跳過那片繼續
    newPlan()
    put("rn_floor", 0, 2, 0)
    put("rn_floor", 1, 2, 0)
    R.start(K)
    run(1)
    finish({ placed = 0, refused = "NOT_ALLOWED", extra = { i = 0 }, stopped = true })
    local n0 = #pushes
    run(5)
    local code, text = R.reason()
    check(R.state() == "paused" and code == "REFUSED" and text and text:find("IGUI_MBLD_Run_REFUSED", 1, true) and #pushes == n0,
        "整批被拒（i＝0）：暫停 REFUSED、不再送")
    R.start(K)
    run(1)
    finish({ placed = 0, refused = "BLOCKED", extra = { i = 1 }, stopped = true })
    run(1)
    check(R.state() ~= "paused" and #pushes == n0 + 2 and #pushes[#pushes].anchors == 1, "只拒一片（i＞0）：那片跳過，其他接著送")

    -- 玩家站在要放家具的那一格（PlanCheck 判成 OCCUPIED）：先走到旁邊再蓋，不回報「這格有人」
    do
        local realState, realAF, realWalk, realHere = B.PlanCheck.state, AdjacentFreeTileFinder, ISWalkToTimedAction, K.getCurrentSquare
        local DET, movers, finds = {}, 1, 0
        B.PlanCheck.state = function(p) return S[p], DET[p] end
        K.getCurrentSquare = function(k)
            return { getX = function() return math.floor(k:getX()) end, getY = function() return math.floor(k:getY()) end,
                getZ = function() return 0 end,
                getMovingObjects = function() return { size = function() return movers end } end }
        end
        AdjacentFreeTileFinder = { Find = function() finds = finds + 1; return { side = true } end }
        ISWalkToTimedAction = { new = function(_, _, sq) return { walkTo = sq } end }

        newPlan()
        local chair = put("rn_furniture", 0, 0, 0) -- 世界 (100,100,0)＝K 站的那一格
        S[chair], DET[chair] = "blocked", "OCCUPIED"
        actions, movers = {}, 2
        local sA, cA = R.start(K)
        movers = 1
        local sB = R.start(K)
        run(1)
        local walked, stA, nA = #actions == 1 and actions[1].walkTo ~= nil, R.state(), #pushes
        doing = true
        run(3)
        doing = false
        S[chair], DET[chair] = "ok", nil -- 走開了：PlanCheck 重查後可蓋
        local t0 = touched
        drive()
        check(sA == nil and cA == "NOTHING", "反面：腳下那格還有別人，不讓位（沒有能蓋的）")
        check(sB == true and walked and stA == "build" and nA == 0 and finds == 1,
            "只剩腳下那一片：照圖蓋先排走路讓位（對外算在蓋），不回「沒有能蓋的」")
        check(touched > t0 and #pushes == 1 and pushes[1].id == "rn_furniture" and R.state() == "done" and (R.reason()) == "DONE",
            "走開後請 PlanCheck 重查，接著把那一片蓋好")

        newPlan()
        local sofa = put("rn_furniture", 0, 0, 0)
        S[sofa], DET[sofa] = "blocked", "OCCUPIED"
        actions, finds = {}, 0
        R.start(K)
        drive() -- 走開後還是 OCCUPIED（別人站上去）：不再讓
        local sum = R.summary()
        check(finds == 1 and #pushes == 0 and R.state() == "done" and (R.reason()) == "LEFT" and sum and sum.blocked.OCCUPIED == 1,
            "一片只讓一次：走開後還是有人就列進沒蓋的")

        B.PlanCheck.state, AdjacentFreeTileFinder, ISWalkToTimedAction, K.getCurrentSquare = realState, realAF, realWalk, realHere
    end

    -- 暫停條件：殭屍在追、自己走、Esc；藍圖收起就停止
    newPlan()
    put("rn_floor", 0, 2, 0)
    R.start(K)
    K.chase = 1
    run(1)
    local zombie = R.reason()
    K.chase = 0
    R.start(K)
    K.moving, doing = true, true
    run(3)
    local walkingAction = R.state()
    doing = false
    run(2)
    local moved = R.reason()
    K.moving = false
    R.start(K)
    for _, f in ipairs(handlers.OnKeyPressed or {}) do pcall(f, 1) end -- 別的模組的按鍵處理在假環境可能出錯：各自包 pcall
    local esc = R.reason()
    check(zombie == "ZOMBIE" and walkingAction ~= "paused" and moved == "MOVED" and esc == "ESC",
        "殭屍在追 → ZOMBIE；佇列走路不算自己走；佇列空著還在動 → MOVED；Esc → ESC")
    R.stop()
    R.start(K)
    B.PlanMode = { plan = function() return Plan.new("other") end, origin = PM.origin }
    run(1)
    B.PlanMode = PM
    check(R.state() == "done" and (R.reason()) == "PLAN_GONE", "地上的藍圖換掉：停止 PLAN_GONE")

    -- 材料箱：點名、只拿點名的、拿這一批缺的；選單只在有藍圖時列
    local function crate(sq, items)
        local c, obj = { items = items }, {}
        function c:getParent() return obj end
        function c:getItems() return javaList(self.items) end
        function c:getType() return "crate" end
        function c:getCustomName() return nil end
        function c:getDisplayType() return "crate" end
        function obj:getSquare() return sq end
        function obj:getContainerCount() return 1 end
        function obj:getContainerByIndex(i) return i == 0 and c or nil end
        sq.objects[#sq.objects + 1] = obj
        return c, obj
    end
    local function planks(n, ft)
        local out = {}
        for k = 1, n do
            out[k] = item(ft or "Base.Plank")
            out[k].getUnequippedWeight = function() return 1 end
        end
        return out
    end
    local boxA, objA = crate(square(130, 100, 0), planks(3))
    local boxB = crate(square(131, 100, 0), planks(5))
    newPlan()
    store = { boxes = {} }
    local menuOff = #Menu.planBoxes({ objA })
    B.PlanMode = PM
    put("rn_wall", 20, 0, 0)
    local i1, i2 = R.addBox(boxA), R.addBox(boxA)
    local listed = Menu.planBoxes({ objA })
    check(i1 == 1 and i2 == 1 and #store.boxes == 1 and R.boxOf(boxA) == 1 and R.boxOf(boxB) == nil
        and #listed == 1 and listed[1].i == 1 and listed[1].title == "crate",
        "點名材料箱：同一個不重複記；選單列出已點名的那個")
    B.PlanMode = nil
    check(#Menu.planBoxes({ objA }) == 0, "反面：地上沒有藍圖時選單不列材料箱")
    B.PlanMode = PM
    local wallAt = (20 + OX) .. "," .. OY .. ",0"
    S[at[wallAt]] = "short"
    CODE[wallAt] = { code = "NO_MATERIAL", extra = { need = { ["Base.Plank"] = 2 } }, need = { ["Base.Plank"] = 2 } }
    actions, walks = {}, {}
    check(R.start(K) == true, "缺料但有材料箱：照圖蓋開始")
    run(1)
    local took = #actions == 2 and actions[1].item.ft == "Base.Plank" and actions[1].src == boxA and actions[2].src == boxA
    check(R.state() == "fetch" and walks[1] == boxA and #walks == 1 and took, "缺料：走去點名的箱子，只拿這一批缺的 2 塊（沒點名的箱子不碰）")
    for _, a in ipairs(actions) do K.inv:add(a.item) end
    CODE[wallAt] = nil
    run(6)
    check(#pushes == 1 and pushes[1].id == "rn_wall", "拿到料後接著送那一批")
    -- 箱子不見、在沒載入的地方：跳過、列進總結，不會出錯
    newPlan()
    store = { boxes = { { x = 132, y = 100, z = 0, index = 0 }, { x = 999, y = 999, z = 0, index = 0 } } }
    square(132, 100, 0)
    put("rn_wall", 21, 0, 0)
    local w2 = (21 + OX) .. "," .. OY .. ",0"
    S[at[w2]] = "short"
    CODE[w2] = { code = "NO_MATERIAL", extra = { need = { ["Base.Plank"] = 2 } }, need = { ["Base.Plank"] = 2 } }
    walks = {}
    R.start(K)
    local okRun = pcall(run, 30)
    local s5 = R.summary()
    check(okRun and #walks == 0 and R.state() == "done" and s5.boxes[1] == "GONE" and s5.boxes[2] == "FAR" and s5.short.n == 1,
        "材料箱不見、沒載入：不走過去、不出錯，總結列出兩個箱子的原因")

    -- 配方片：交給 Recipes.runCells（段照配方的 kind）
    newPlan()
    store = { boxes = {} }
    local rc = {}
    B.Recipes = { get = function() return { kind = "wall", name = "W" } end, stopCells = function() end,
        runCells = function(_, id, cells, onDone) rc[#rc + 1] = { id = id, cells = cells, onDone = onDone }; return true end }
    local rp = put("recipe:Base.X", 2, 2, 0)
    put("rn_floor", 0, 2, 0)
    R.start(K)
    drive() -- 先送地板（第 1 段），再送配方牆（第 2 段）
    run(1)
    local recOk = #pushes == 1 and pushes[1].id == "rn_floor" and #rc == 1 and #rc[1].cells == 1 and rc[1].cells[1][1] == 102
    S[rp] = "done"
    rc[1].onDone({ count = 1, placed = 1, stopped = false })
    run(30)
    check(recOk and (R.reason()) == "DONE", "配方片：照 kind 排進牆那一段，交給 Recipes.runCells；蓋好後完成")

    -- 全蓋好但收起失敗（PlanMode.clear 存檔失敗回 false，藍圖留在地上）：說藍圖還在；收成了只說完成
    newPlan()
    B.Recipes = nil
    put("rn_floor", 0, 2, 0)
    clearOk, toasts = false, {}
    R.start(K)
    drive()
    local keepMsg = toasts[#toasts]
    clearOk = true
    newPlan()
    put("rn_floor", 0, 2, 0)
    toasts = {}
    R.start(K)
    drive()
    local doneMsg = toasts[#toasts]
    check(keepMsg and keepMsg:find("IGUI_MBLD_Run_DONE_KEEP", 1, true) and doneMsg
        and doneMsg:find("IGUI_MBLD_Run_DONE", 1, true) and not doneMsg:find("KEEP", 1, true),
        "全蓋好：PlanMode.clear 回 false 時說藍圖還在地上；反面：收成了只說完成")

    -- 批次送出後藍圖改了：結果不套到片上，那幾格重查、暫停 EDIT、不再送
    newPlan()
    put("rn_floor", 0, 2, 0)
    put("rn_floor", 1, 2, 0)
    R.start(K)
    run(1)
    local t8 = touched
    put("rn_wall", 5, 5, 0) -- 加片＝rev 加一（搬、轉、刪、換項目同樣加 rev）
    buildAll()
    local n8 = #pushes
    run(3)
    check(n8 == 1 and R.state() == "paused" and (R.reason()) == "EDIT" and #pushes == n8 and touched >= t8 + 2,
        "批次送出後藍圖改了：不套結果、那幾格重查、暫停 EDIT 不再送")
    -- 整張搬了（原點換了）、進入規劃：送出前就暫停
    newPlan()
    put("rn_floor", 0, 2, 0)
    R.start(K)
    shift = 1
    run(1)
    shift = 0
    local movedPlan = R.reason()
    R.start(K)
    editing = true
    run(1)
    editing = false
    local editCode, editText = R.reason()
    check(movedPlan == "EDIT" and editCode == "EDIT" and #pushes == 0 and editText:find("IGUI_MBLD_Run_EDIT", 1, true),
        "原點換了、進入規劃：照圖蓋送出前暫停 EDIT")

    -- 原地替換缺差額：用 Check.item 算好的差額去拿（真的 Materials.short 收到沒有 tools 的成本表會出錯）
    local boxC = crate(square(133, 100, 0), planks(4))
    newPlan()
    store = { boxes = {} }
    R.addBox(boxC)
    put("rn_wall", 22, 0, 0)
    local w3 = (22 + OX) .. "," .. OY .. ",0"
    S[at[w3]] = "short"
    CODE[w3] = { code = "NO_MATERIAL", extra = { need = { ["Base.Plank"] = 1 } }, need = { ["Base.Plank"] = 3 },
        pay = { ["Base.Plank"] = 1 } }
    actions, walks = {}, {}
    R.start(K)
    local okC6 = pcall(run, 1)
    check(okC6 and R.state() == "fetch" and walks[1] == boxC and #actions == 1, "原地替換缺差額：不出錯，去箱子只拿差的 1 塊")
    R.stop()

    -- 箱子在但沒有要的、負重放不下：跳過這個箱子，總結說原因，不出錯
    local boxE = crate(square(134, 100, 0), planks(2, "Base.Log"))
    local boxH = crate(square(135, 100, 0), planks(2))
    newPlan()
    store = { boxes = {} }
    R.addBox(boxE)
    R.addBox(boxH)
    put("rn_wall", 23, 0, 0)
    local w4 = (23 + OX) .. "," .. OY .. ",0"
    S[at[w4]] = "short"
    CODE[w4] = { code = "NO_MATERIAL", extra = { need = { ["Base.Plank"] = 2 } }, need = { ["Base.Plank"] = 2 } }
    K.load, walks, toasts = 3, {}, {}
    R.start(K)
    local okC7 = pcall(run, 30)
    K.load = 0
    local s7 = R.summary()
    check(okC7 and #walks == 0 and R.state() == "done" and s7.boxes[1] == "EMPTY" and s7.boxes[2] == "HEAVY"
        and toasts[#toasts] and toasts[#toasts]:find("IGUI_MBLD_Run_Box", 1, true), -- 假 getText 不帶參數：只看得到材料箱那一行
        "箱子沒有要的 EMPTY、負重放不下 HEAVY：不走過去、不出錯，總結列出")

    -- 拿料途中玩家自己動手：暫停 MANUAL、不再送；玩家的建造已換掉拿料動作時不清佇列
    local boxM = crate(square(136, 100, 0), planks(4))
    newPlan()
    store = { boxes = {} }
    R.addBox(boxM)
    put("rn_wall", 24, 0, 0)
    local w5 = (24 + OX) .. "," .. OY .. ",0"
    S[at[w5]] = "short"
    CODE[w5] = { code = "NO_MATERIAL", extra = { need = { ["Base.Plank"] = 2 } }, need = { ["Base.Plank"] = 2 } }
    actions, clears = {}, 0
    R.start(K)
    run(1)
    local fetching = R.state() == "fetch"
    actions, busy = {}, 1 -- 手動建造：Client.build 清掉佇列、排上玩家的請求
    run(10)
    local manualCode, manualClears = (R.reason()), clears
    busy = 0
    R.start(K) -- 反面：拿料動作還在佇列時暫停要清掉
    run(1)
    local queued = #actions
    R.pause("ESC")
    check(fetching and manualCode == "MANUAL" and #pushes == 0 and manualClears == 0 and queued > 0 and clears == 1,
        "拿料途中自己動手：暫停 MANUAL 不再送、不清玩家的動作；反面：拿料動作還在時暫停會清")

    -- 手動的還在跑時按照圖蓋：不開始，回 BUSY
    newPlan()
    put("rn_floor", 0, 2, 0)
    busy = 1
    local b1, b2 = R.start(K)
    busy = 0
    local b3 = R.start(K)
    check(b1 == nil and b2 == "BUSY" and #pushes == 0 and b3 == true,
        "手動的還在跑時按照圖蓋：回 BUSY 不開始；反面：沒有手動的就開始")
    R.stop()

    -- 真的配方入口（單放、牆面油漆）：排玩家的動作之前照圖蓋就暫停 MANUAL；照圖蓋自己送的配方（runCells）不算手動
    do
        local RC = real.rec
        local keep = { list = RC.list, isb = ISBuildIsoEntity, paint = ISPaintCursor, bl = BuildLogic, cell = getCell,
            joy = JoypadState, menu = ISInventoryPaneContextMenu, wct = WallCoveringType }
        local nTick0 = #handlers.OnTick
        local tried = {}
        local face = { getWidth = function() return 1 end, getHeight = function() return 1 end,
            getTileInfo = function() return { getSpriteName = function() return "rn_stair_0" end } end }
        local REC = { getToolBoth = function() end, getToolRight = function() end, getToolLeft = function() end }
        local STAIR, PAINT = "recipe:Base.RnStair", "recipe:Base.RnPaint"
        RC.list = RC.list or { n = 0 }
        RC.byId[STAIR] = { id = STAIR, kind = "stairs", name = "S", info = { getFace = function() return face end }, recipe = REC }
        RC.byId[PAINT] = { id = PAINT, kind = "wallOverlay", name = "P", cover = true, recipe = REC }
        WallCoveringType = { WALLPAPER = {}, PAINT_THUMP = { toString = function() return "paintThump" end } }
        local LFN = { canPerformCurrentRecipe = function() return true end, isCraftActionInProgress = function() return false end,
            getWallCoveringParams = function() return { actionType = WallCoveringType.PAINT_THUMP } end }
        BuildLogic = { new = function() return setmetatable({}, { __index = function(_, k) return LFN[k] or function() end end }) end }
        ISInventoryPaneContextMenu = { getContainers = function() return {} end }
        JoypadState = { players = {} }
        local drag = {}
        getCell = function()
            local c = keep.cell()
            c.getDrag = function(_, pn) return drag[pn] end
            c.setDrag = function(_, o, pn)
                drag[pn] = o
                if o then o.player = pn end
            end
            return c
        end
        -- 原版建造游標：tryBuild 記下送的是誰、那一刻照圖蓋的狀態（玩家的動作排進去時要已經暫停）
        ISBuildIsoEntity = {}
        ISBuildIsoEntity.new = function(_, p, info, n, _, logic)
            return setmetatable({ character = p, objectInfo = info, nSprite = n, buildPanelLogic = logic, spriteCache = {} },
                { __index = ISBuildIsoEntity })
        end
        function ISBuildIsoEntity:getSprite() end
        function ISBuildIsoEntity:getFace() return face end
        function ISBuildIsoEntity:ensureSquaresExist() end
        function ISBuildIsoEntity:isValid() return true end
        function ISBuildIsoEntity:tryBuild(x) tried[#tried + 1] = { x = x, run = self.mbldRun == true, state = R.state() } end
        ISPaintCursor = { new = function(_, p)
            return { character = p, tryBuild = function() tried[#tried + 1] = { paint = true, state = R.state() } end }
        end }
        B.Recipes = RC
        square(102, 102, 0)

        -- 照圖蓋送配方樓梯（真的 runCells）在蓋，玩家手動單放一座：照圖蓋先暫停、它那排收掉，再排玩家的
        newPlan()
        store = { boxes = {} }
        local sp = Plan.add(pl, 2, 2, 0, 1, 0, Plan.item(pl, STAIR))
        S[sp] = "ok"
        R.start(K)
        run(3)
        local ownRun = #tried == 1 and tried[1].run and tried[1].state == "build" and R.state() == "build" and RC.row(0) ~= nil
        local cur = RC.build(0, STAIR)
        cur:tryBuild(50, 50, 0)
        local last = tried[#tried]
        check(ownRun and (R.reason()) == "MANUAL" and #tried == 2 and last.x == 50 and not last.run and last.state == "paused"
            and RC.row(0) == nil,
            "照圖蓋自己送的配方不算手動；手動單放配方：排玩家的動作之前就暫停 MANUAL、照圖蓋那排收掉")

        -- 拿料途中手動刷油漆：先暫停（清掉還排著的拿料動作），再排玩家的；之後不再自己接著蓋
        local boxP = crate(square(137, 100, 0), planks(4))
        newPlan()
        store = { boxes = {} }
        R.addBox(boxP)
        put("rn_wall", 26, 0, 0)
        local w6 = (26 + OX) .. "," .. OY .. ",0"
        S[at[w6]] = "short"
        CODE[w6] = { code = "NO_MATERIAL", extra = { need = { ["Base.Plank"] = 2 } }, need = { ["Base.Plank"] = 2 } }
        actions, clears = {}, 0
        R.start(K)
        run(1)
        local fetchingP = R.state() == "fetch"
        local paint = RC.build(0, PAINT)
        paint:tryBuild(60, 60, 0)
        local lastP = tried[#tried]
        run(10)
        check(fetchingP and lastP.paint and lastP.state == "paused" and (R.reason()) == "MANUAL" and clears == 1 and #pushes == 0,
            "拿料途中手動刷油漆：先暫停並清掉拿料動作，再排玩家的；之後不再送")

        -- 反面：分割畫面的另一位玩家動手不暫停這位的照圖蓋
        newPlan()
        put("rn_floor", 0, 2, 0)
        R.start(K)
        R.manual(player({ id = 78 }))
        local other = R.state()
        R.manual(K)
        check(other ~= "paused" and (R.reason()) == "MANUAL", "另一位玩家動手不算；同一位玩家動手才暫停")

        -- 收尾：游標放掉、讓 Recipes 的追蹤（OnTick）自己收掉
        drag = {}
        for i = #handlers.OnTick, nTick0 + 1, -1 do pcall(handlers.OnTick[i]) end
        RC.byId[STAIR], RC.byId[PAINT] = nil, nil
        RC.list, ISBuildIsoEntity, ISPaintCursor, BuildLogic, getCell = keep.list, keep.isb, keep.paint, keep.bl, keep.cell
        JoypadState, ISInventoryPaneContextMenu, WallCoveringType = keep.joy, keep.menu, keep.wct
        B.Recipes = nil
    end

    -- 除錯重新載入 Runner.lua：不重複掛事件
    local nTick, nKey = #handlers.OnTick, #handlers.OnKeyPressed
    loadfile(MEDIA .. "/client/MinidoracatBuilder/Runner.lua")()
    check(#handlers.OnTick == nTick and #handlers.OnKeyPressed == nKey and B.Runner == R,
        "重新載入 Runner.lua 不重複掛 OnTick、OnKeyPressed")

    B.PlanMode, B.PlanCheck, B.Recipes = real.PM, real.PC, real.rec
    Q.push, Q.cancel, Q.busy = real.push, real.cancel, real.busy
    Check.item, Materials.summary = real.item, real.summary
    Entry.resolve, Entry.face, Entry.cells, Entry.doorSet, Entry.groupCells, Entry.alternate =
        real.resolve, real.face, real.cells, real.doorSet, real.group, real.alt
    PS.load, PS.save = real.load, real.save
    clockStep, ISTimedActionQueue, luautils, ISInventoryTransferAction = real.step, real.q, real.lu, real.xfer
    MinidoracatUI, Core, Keyboard, getSpecificPlayer = real.ui, real.core, real.kb, real.specific
    sb.AllowAutoBuild, sb.MaxCellsPerDrag = real.auto, real.max
end)()

print()
if failures > 0 then
    print(failures .. " 項失敗")
    os.exit(1)
end
print("全部通過")
