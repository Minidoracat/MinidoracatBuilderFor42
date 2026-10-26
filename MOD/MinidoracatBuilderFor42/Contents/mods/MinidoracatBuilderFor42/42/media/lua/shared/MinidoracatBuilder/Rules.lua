-- 圖塊分類規則：客戶端目錄與伺服器重算共用這一份。
-- 只看 tile 屬性與型別，不看貼圖（專用伺服器的 sprite 沒有貼圖，hasNoTextures() 一律 true）。
-- 順序照設計稿 Rules.classify（bt-catalog §3.2、§6；bt-newkinds §1.1）：排除先跑，第一條成立的規則決定種類。
-- 目錄每個有貼圖的 sprite 都會跑一次（約 5.7 萬次），所以盡量少呼叫 Java：
--   型別查表一次（不逐一比較：兩個不同的 Java 物件比 == 要查兩次 metatable，KahluaThread.java:545-560）、
--   列舉值與 MoveType 各取一次。
MinidoracatBuilder = MinidoracatBuilder or {}
local Rules = MinidoracatBuilder.Rules or {}
MinidoracatBuilder.Rules = Rules

local T, F = IsoObjectType, IsoFlagType
local EntityScript, vegitation, canBeCut = F.EntityScript, F.vegitation, F.canBeCut
local doorN, doorW, windowN, windowW = F.doorN, F.doorW, F.windowN, F.windowW
local HoppableN, HoppableW, TallHoppableN, TallHoppableW = F.HoppableN, F.HoppableW, F.TallHoppableN, F.TallHoppableW
local WallSE, solidfloor, WallOverlay, FloorOverlay = F.WallSE, F.solidfloor, F.WallOverlay, F.FloorOverlay
local attachedFloor, cutN, cutW, solid, solidtrans = F.attachedFloor, F.cutN, F.cutW, F.solid, F.solidtrans
local attachedN, attachedS, attachedE, attachedW = F.attachedN, F.attachedS, F.attachedE, F.attachedW
local attachedNW, attachedSE, attachedCeiling = F.attachedNW, F.attachedSE, F.attachedCeiling

-- IsoObjectType → 分類代碼；其餘型別（normal、wall、isMoveAbleObject…）查不到＝nil
local TYPE = {}
for _, k in ipairs({ "stairsTW", "stairsMW", "stairsBW", "stairsTN", "stairsMN", "stairsBN" }) do TYPE[T[k]] = "stairs" end
for _, k in ipairs({ "curtainN", "curtainS", "curtainW", "curtainE" }) do TYPE[T[k]] = "curtain" end
for _, k in ipairs({ "WestRoofB", "WestRoofM", "WestRoofT" }) do TYPE[T[k]] = "roof" end
TYPE[T.tree] = "tree"
TYPE[T.lightswitch] = "light"

-- 原版每次載入 chunk 都會跑 Lua 改寫的圖塊（MapObjects.OnLoadWithSprite，server/Map/MapObjects/*.lua）。
-- 玩家放的同名物件下次載入會被改掉，所以不列。只收 OnLoad：OnNew 只處理地圖原本的物件。
-- 設計稿不包 MapObjects 的原版函式，改用清單；其他 MOD 可以 Rules.addLuaSprites 補。
local LUA_SPRITES = {}
function Rules.addLuaSprites(names)
    for i = 1, #names do LUA_SPRITES[names[i]] = true end
end
local function addRange(tileset, from, to)
    for i = from, to do LUA_SPRITES[tileset .. "_" .. i] = true end
end
Rules.addLuaSprites({ "crafted_04_120", "camping_01_4", "camping_01_5", "camping_01_6",
    "vegetation_farming_01_13", "vegetation_farming_01_14" })
addRange("location_farm_accesories_01", 4, 7)      -- MOFeedingTrough.lua:131-158
addRange("location_farm_accesories_01", 14, 29)
addRange("location_farm_accesories_01", 32, 35)
addRange("constructedobjects_01", 2, 13)           -- server/Traps/TrapDefinition.lua（MOTrap.lua:131-135）
addRange("constructedobjects_01", 16, 19)

function Rules.hasLuaBehaviour(name)
    return LUA_SPRITES[name] == true
end

-- 型別代碼："stairs"／"curtain"／"roof"／"tree"／"light"／nil
function Rules.typeCode(t)
    return TYPE[t]
end

-- 名稱前綴排除：侵蝕疊圖 e_（積雪屋頂）、植物 vegetation_、樹叢 f_bushes、巨樹 jumbo_（bt-catalog §6.3）。
-- 先看第一個字元再比字串：避免多數名稱建子字串。
local function excludedName(name)
    local c = name:byte(1)
    if c == 101 then -- e
        if name:byte(2) == 95 then return true end
    elseif c == 118 then -- v
        if name:sub(1, 11) == "vegetation_" then return true end
    elseif c == 102 then -- f
        if name:sub(1, 8) == "f_bushes" then return true end
    elseif c == 106 then -- j
        if name:sub(1, 6) == "jumbo_" then return true end
    end
    return name:find("_on_", 1, true) ~= nil and name:find("_on_%d+$") ~= nil -- 開燈時疊上去的圖
end

-- 前面的種類都不符時：掛牆物、窗上物件、地面覆蓋、牆面疊圖、附著物、實心物件、疊圖；都不符就不列
local function decor(p, mt)
    if mt == "WallObject" or p:has(WallOverlay) then return "wallObject" end
    if mt == "WindowObject" then return "windowObject" end
    if mt == "FloorRug" or p:has(FloorOverlay) or p:has(attachedFloor) then return "floorOverlay" end
    if p:has(cutN) or p:has(cutW) then return "wallOverlay" end -- 牆鍵已在前面判斷過
    if p:has(attachedN) or p:has(attachedS) or p:has(attachedE) or p:has(attachedW)
        or p:has(attachedNW) or p:has(attachedSE) or p:has(attachedCeiling) then
        return "attached"
    end
    if p:has("BlocksPlacement") or p:has(solid) or p:has(solidtrans) then return "solid" end
    if p:has("TileOverlay") then return "overlay" end
    return nil
end

-- 植物，以及加油機、專用類別、發電機、物品 entity、家電。結構類種類（樓梯到地板）不帶這些鍵，所以只在結構類之後才查，
-- 每個牆、窗框、地板省 12 次 Java 呼叫。正式服 147 個 MOD（離線讀 tiledef）與 E2E 載的 18 個 tiledef 組合
-- （遊戲內和逐一照設計稿順序判斷的版本逐格比對）都沒有同時帶結構鍵與這些鍵的圖塊，結果不變。
local function plantOrObject(p, mt)
    return mt == "Vegitation" or p:has("tree") or p:has(vegitation) or p:has(canBeCut) or p:has("Bush")
        or p:has("fuelAmount") or p:has("IsoType") or p:has("GeneratorSound") or p:has("CustomItem")
        or p:has("TV") or p:has("Microwave") or p:has("signal")
end

-- 回傳種類字串；nil＝不列（排除或不屬於任何種類）
-- name＝sprite 名稱、p＝getProperties()、t＝getType()；呼叫端已經拿到的就直接傳，不再取一次。
function Rules.kindOf(name, p, t)
    if not name or LUA_SPRITES[name] or excludedName(name) then return nil end
    if p:has(EntityScript) then return nil end -- 原版或 MOD 的 entity：走原版建造
    local tc = TYPE[t]
    if tc == "tree" then return nil end
    if tc == "stairs" then return "stairs" end -- 目錄只收湊得成三格的（Rules.stairsSet）
    if p:has("GarageDoor") then return "garage" end
    if p:has(doorN) or p:has(doorW) then
        -- 雙開門要四片一組、開門圖在 +4（IsoDoor.java:789-796），單片放會開錯圖、MP 不同步；之後和車庫門一起做
        if p:has("DoubleDoor") then return nil end
        return "door"
    end
    if p:has(windowN) or p:has(windowW) then return "window" end -- 窗一定也帶 WindowN/W，所以先判斷
    if p:has("WindowN") or p:has("WindowW") then return "windowFrame" end
    if p:has("DoorWallN") or p:has("DoorWallW") or p:has("DoorWallNTrans") or p:has("DoorWallWTrans") then
        return "doorFrame"
    end
    if p:has(HoppableN) or p:has(HoppableW) or p:has(TallHoppableN) or p:has(TallHoppableW) then
        return "fence" -- 先於牆：低柵欄也帶牆鍵
    end
    if p:has("WallN") or p:has("WallW") or p:has("WallNW") or p:has("WallNTrans") or p:has("WallWTrans")
        or p:has("WallNWTrans") or p:has(WallSE) then
        return "wall"
    end
    if p:has(solidfloor) then return "floor" end -- 平屋頂地板也在這
    local mt = p:get("MoveType")
    if plantOrObject(p, mt) then return nil end
    if p:has("container") then return "container" end -- 冰箱帶燈，容器優先
    if tc == "light" or p:has("LightRadius") then
        -- 不是開關、又沒有 lightR 的不會亮（IsoLightSwitch 只依 lightR 建光源）
        if tc ~= "light" and not p:has("lightR") then return nil end
        return "light"
    end
    if tc == "curtain" and mt == "WindowObject" then return "curtain" end -- 床單、帳篷布不列
    if p:has("IsMoveAble") then return "furniture" end -- 可搬的遮雨棚也在這
    if tc == "roof" or p:has("RoofGroup") then return "roof" end -- 屋簷也算
    return decor(p, mt)
end

function Rules.classify(spr)
    return Rules.kindOf(spr:getName(), spr:getProperties(), spr:getType())
end

-- 樓梯一個項目＝同一 tileset 連號三格（B、M、T 同方向，遞增或遞減；bt-newkinds §2.1）。
-- named＝getNamedMap()；只用 get，不用全域 getSprite（查不到會新增空 sprite）。湊不成組回 nil。
function Rules.stairsSet(named, bName)
    local spr = named:get(bName)
    if not spr then return nil end
    local bt = spr:getType()
    if bt ~= T.stairsBN and bt ~= T.stairsBW then return nil end
    local north = bt == T.stairsBN
    local base, n = bName:match("^(.*)_(%d+)$")
    n = tonumber(n)
    if not n then return nil end
    local mt = north and T.stairsMN or T.stairsMW
    local tt = north and T.stairsTN or T.stairsTW
    for _, d in ipairs({ 1, -1 }) do
        local m = named:get(base .. "_" .. (n + d))
        local tp = named:get(base .. "_" .. (n + 2 * d))
        if m and tp and m:getType() == mt and tp:getType() == tt then
            return { b = bName, m = m:getName(), t = tp:getName(), dir = north and "N" or "W" }
        end
    end
    return nil
end

return Rules
