-- 圖塊分類規則：客戶端目錄與伺服器重算共用這一份。
-- 只看 tile 屬性與型別，不看貼圖（專用伺服器的 sprite 沒有貼圖，hasNoTextures() 一律 true）。
-- 順序照設計稿 Rules.classify（bt-catalog §3.2、§6；bt-newkinds §1.1）：排除先跑，第一條成立的規則決定種類。
MinidoracatBuilder = MinidoracatBuilder or {}
local Rules = MinidoracatBuilder.Rules or {}
MinidoracatBuilder.Rules = Rules

local T, F = IsoObjectType, IsoFlagType

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

function Rules.isStairs(t)
    return t == T.stairsTW or t == T.stairsMW or t == T.stairsBW
        or t == T.stairsTN or t == T.stairsMN or t == T.stairsBN
end

function Rules.isCurtain(t)
    return t == T.curtainN or t == T.curtainS or t == T.curtainW or t == T.curtainE
end

function Rules.isRoof(t)
    return t == T.WestRoofB or t == T.WestRoofM or t == T.WestRoofT
end

-- 名稱前綴排除：侵蝕疊圖 e_（積雪屋頂）、植物 vegetation_、樹叢 f_bushes、巨樹 jumbo_（bt-catalog §6.3）。
-- 先看第一個字元再比字串：每個 sprite 都會跑，避免多數名稱建子字串。
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
function Rules.decor(p)
    local mt = p:get("MoveType")
    if mt == "WallObject" or p:has(F.WallOverlay) then return "wallObject" end
    if mt == "WindowObject" then return "windowObject" end
    if mt == "FloorRug" or p:has(F.FloorOverlay) or p:has(F.attachedFloor) then return "floorOverlay" end
    if p:has(F.cutN) or p:has(F.cutW) then return "wallOverlay" end -- 牆鍵已在前面判斷過
    if p:has(F.attachedN) or p:has(F.attachedS) or p:has(F.attachedE) or p:has(F.attachedW)
        or p:has(F.attachedNW) or p:has(F.attachedSE) or p:has(F.attachedCeiling) then
        return "attached"
    end
    if p:has("BlocksPlacement") or p:has(F.solid) or p:has(F.solidtrans) then return "solid" end
    if p:has("TileOverlay") then return "overlay" end
    return nil
end

-- 回傳種類字串；nil＝不列（排除或不屬於任何種類）
function Rules.classify(spr)
    local name = spr:getName()
    if not name or excludedName(name) then return nil end
    local p, t = spr:getProperties(), spr:getType()
    if p:has(F.EntityScript) then return nil end -- 原版或 MOD 的 entity：走原版建造
    if LUA_SPRITES[name] then return nil end
    if p:has("fuelAmount") or p:has("IsoType") or p:has("GeneratorSound") or p:has("CustomItem")
        or p:has("TV") or p:has("Microwave") or p:has("signal") then
        return nil -- 加油機、專用類別、發電機、物品 entity、家電
    end
    if t == T.tree or p:has("tree") or p:has(F.vegitation) or p:has(F.canBeCut) or p:has("Bush")
        or p:get("MoveType") == "Vegitation" then
        return nil
    end
    if Rules.isStairs(t) then return "stairs" end -- 目錄只收湊得成三格的（Rules.stairsSet）
    if p:has("GarageDoor") then return "garage" end
    if p:has(F.doorN) or p:has(F.doorW) then return "door" end
    if p:has(F.windowN) or p:has(F.windowW) then return "window" end -- 窗一定也帶 WindowN/W，所以先判斷
    if p:has("WindowN") or p:has("WindowW") then return "windowFrame" end
    if p:has("DoorWallN") or p:has("DoorWallW") or p:has("DoorWallNTrans") or p:has("DoorWallWTrans") then
        return "doorFrame"
    end
    if p:has(F.HoppableN) or p:has(F.HoppableW) or p:has(F.TallHoppableN) or p:has(F.TallHoppableW) then
        return "fence" -- 先於牆：低柵欄也帶牆鍵
    end
    if p:has("WallN") or p:has("WallW") or p:has("WallNW") or p:has("WallNTrans") or p:has("WallWTrans")
        or p:has("WallNWTrans") or p:has(F.WallSE) then
        return "wall"
    end
    if p:has(F.solidfloor) then return "floor" end -- 平屋頂地板也在這
    if p:has("container") then return "container" end -- 冰箱帶燈，容器優先
    if t == T.lightswitch or p:has("LightRadius") then
        -- 不是開關、又沒有 lightR 的不會亮（IsoLightSwitch 只依 lightR 建光源）
        if t ~= T.lightswitch and not p:has("lightR") then return nil end
        return "light"
    end
    if Rules.isCurtain(t) and p:get("MoveType") == "WindowObject" then return "curtain" end -- 床單、帳篷布不列
    if p:has("IsMoveAble") then return "furniture" end -- 可搬的遮雨棚也在這
    if Rules.isRoof(t) or p:has("RoofGroup") then return "roof" end -- 屋簷也算
    return Rules.decor(p)
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
