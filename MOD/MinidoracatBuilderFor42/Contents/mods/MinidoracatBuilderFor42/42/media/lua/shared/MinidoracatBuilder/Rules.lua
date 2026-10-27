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
local invincible = F.makeWindowInvincible

-- IsoObjectType → 分類代碼；其餘型別（normal、wall、isMoveAbleObject…）查不到＝nil
local TYPE = {}
for _, k in ipairs({ "stairsTW", "stairsMW", "stairsBW", "stairsTN", "stairsMN", "stairsBN" }) do TYPE[T[k]] = "stairs" end
for _, k in ipairs({ "curtainN", "curtainS", "curtainW", "curtainE" }) do TYPE[T[k]] = "curtain" end
for _, k in ipairs({ "WestRoofB", "WestRoofM", "WestRoofT" }) do TYPE[T[k]] = "roof" end
TYPE[T.tree] = "tree"
TYPE[T.lightswitch] = "light"
-- 往西爬的樓梯片（W 型：沿 +x 排、平台在 x−1；原版叫 north，ISBuildIsoEntity.lua:18-20）
local WEST_STAIRS = { [T.stairsTW] = true, [T.stairsMW] = true, [T.stairsBW] = true }
function Rules.westStairs(t)
    return WEST_STAIRS[t] == true
end

-- 依名稱不列的圖塊（kindOf 第一行查，一次表查詢）：
-- 1. 原版每次載入 chunk 都會跑 Lua 改寫的圖塊（MapObjects.OnLoadWithSprite，server/Map/MapObjects/*.lua）。
--    玩家放的同名物件下次載入會被改掉，所以不列。只收 OnLoad：OnNew 只處理地圖原本的物件。
--    設計稿不包 MapObjects 的原版函式，改用清單；其他 MOD 可以 Rules.addLuaSprites 補。
-- 2. 其他 MOD 照 sprite 名稱給功能的圖塊：MapObjects 的登記表是 Java 私有欄位（MapObjects.java:23-24），
--    名稱比對寫在各 MOD 自己的 Lua 裡，查不到，只能列清單。MOD 自己的 tileset 一律不列；原版圖塊只在有啟用那個 MOD
--    時不列（BY_MOD；沒裝時只是原版裝飾）。2026-10-27 用 audit_mods.py 掃正式服 147 個 MOD 找到的見下方。
-- 3. 引擎內部用的圖塊。
local UNLISTED = {}
local function unlist(names)
    for i = 1, #names do UNLISTED[names[i]] = true end
end
Rules.addLuaSprites = unlist
local function addRange(tileset, from, to)
    for i = from, to do UNLISTED[tileset .. "_" .. i] = true end
end
unlist({ "crafted_04_120", "camping_01_4", "camping_01_5", "camping_01_6",
    "vegetation_farming_01_13", "vegetation_farming_01_14" })
addRange("location_farm_accesories_01", 4, 7)      -- MOFeedingTrough.lua:131-158
addRange("location_farm_accesories_01", 14, 29)
addRange("location_farm_accesories_01", 32, 35)
addRange("constructedobjects_01", 2, 13)           -- server/Traps/TrapDefinition.lua（MOTrap.lua:131-135）
addRange("constructedobjects_01", 16, 19)
-- PSR（正式服有裝）與 Immersive Solar Arrays 共用的太陽能 tileset（兩者都是 40 格）：面板接上電池組就照面板數發電，
-- 認的只是 sprite 名稱（PSR shared/PSR/WorldUtilities.lua 的 PSRTypes、PowerBankObject_Server.lua 的 checkPanels）
addRange("solarmod_tileset_01", 0, 39)
-- 引擎內部：屋頂修補放的隱形地板（IsoRoofFixer.java:23,242）、地底方塊（IsoGridSquare.java:4834-4844）
unlist({ "invisible_01_0", "underground_01_0", "underground_01_1" })
-- 照原版圖塊名稱給功能的 MOD（Workshop 路徑 content/108600/<ID>）：{ tileset, 起, 迄, ... }
local BY_MOD = {
    -- 丙烷補充站：右鍵就能補丙烷，第一次用時照沙盒給初始量（3786849936 ArcadiaRefillablePropane_Shared.lua:55-194、
    -- ArcadiaRefillablePropane_Server.lua:83-121）
    ArcadiaRefillablePropaneTanks_B42 = { "location_shop_fossoil_01", 80, 111, "location_shop_gas2go_01", 64, 95 },
    -- ATM：2 格內就開通交易（3801482125 ECCore.lua:91-127）
    MinidoracatEconomyFor42 = { "location_business_bank_01", 64, 67 },
    -- 電梯門與呼叫鈕：每層一片、有電就能在樓層間傳送（3780306632 ELV_Core.lua:32-46,70-79）
    Elevators = { "fixtures_escalators_01", 48, 51, "fixtures_escalators_01", 56, 57 },
    -- 液壓機（綠、藍各兩幀）：接電就有機器面板（3780027195 Registry.lua:262-285、HydraulicPress.lua:105）
    Machinery = { "industry_03", 48, 63 },
}
function Rules.unlistModSprites()
    local mods = getActivatedMods()
    for i = 0, mods:size() - 1 do
        local list = BY_MOD[mods:get(i)]
        if list then
            for k = 1, #list, 3 do addRange(list[k], list[k + 1], list[k + 2]) end
        end
    end
end
Rules.unlistModSprites()

function Rules.unlistedByName(name)
    return UNLISTED[name] == true
end

-- 窗開著、破了、拆了玻璃的三種狀態圖不列。引擎建 IsoWindow 時把關著那張的屬性與型別整份加到這三張
-- （IsoWindow.java:99-121），所以它們像不像窗，要看這次開服載入過哪些窗：同一份 MOD 兩次開服，目錄差 8 項、
-- 20 張在窗與附著物之間換（E2E ui-mp 1027f／g），客戶端與伺服器也可能不同。圖塊定義剛載入、還沒載入任何
-- chunk 時（OnLoadedTileDefinitions，IsoWorld.java:1977-1978，chunk 在 :2188 才載）照關著那張的偏移記下來。
-- 「關著那張」逐步確認：有窗旗標、有偏移，而且指到它的都已確定是狀態圖（一開始＝沒被任何一張指到）；
-- 確認後它的偏移目標記成狀態圖，那些目標自己的偏移就不再算。被引擎改過的狀態圖、作者把關著那張的屬性
-- 複製過去的狀態圖，都帶著關著那張的旗標與偏移，這樣算才不會讓它們的偏移影響下一扇窗（不誤記、不漏記），
-- chunk 載入後才補記也得到同一份。本機 312 個 tiledef 檔（原版＋Workshop＋Zomboid/mods，2026-10-27 離線讀）：
-- 照這個算 33,065 張狀態圖，沒有互相指到、確認不完的窗；原版 276 張窗都是一開始就確認。
local STATE_KEYS = { "OpenTileOffset", "SmashedTileOffset", "GlassRemovedOffset" }
-- 集合放在 Rules 表上：只重載這個檔案（不是整個 Lua 重設）時沿用圖塊剛載入時記的那份
local WINDOW_STATE = Rules.windowStateSet or {}
Rules.windowStateSet = WINDOW_STATE
-- Rules.windowStates：記了幾張；nil＝還沒記
function Rules.recordWindowStates(sprites, late)
    local t0 = getTimestampMs()
    local wins, targets, idx, indeg, wn = {}, {}, {}, {}, 0
    for i = 0, sprites:size() - 1 do
        local spr = sprites:get(i)
        local p = spr:getProperties()
        if p:has(windowN) or p:has(windowW) then
            local name = spr:getName()
            local tileset, num
            if name then tileset, num = name:match("^(.*)_(%d+)$") end
            if tileset then
                local list
                for k = 1, 3 do
                    local off = tonumber(p:get(STATE_KEYS[k]))
                    if off and off ~= 0 then
                        local target = tileset .. "_" .. (tonumber(num) + off)
                        indeg[target] = (indeg[target] or 0) + 1
                        list = list or {}
                        list[#list + 1] = target
                    end
                end
                if list then
                    wn = wn + 1
                    wins[wn], targets[wn], idx[name] = name, list, wn
                end
            end
        end
    end
    local stack, sn, gone, n = {}, 0, {}, 0 -- gone[j]：已確認是關著那張，或已確定是狀態圖
    for j = 1, wn do
        if not indeg[wins[j]] then
            sn = sn + 1
            stack[sn] = j
        end
    end
    local closed = 0
    while sn > 0 do
        local j = stack[sn]
        stack[sn], sn = nil, sn - 1
        if not gone[j] then
            gone[j] = true
            closed = closed + 1
            local list = targets[j]
            for k = 1, #list do
                local t = list[k]
                if not WINDOW_STATE[t] then
                    WINDOW_STATE[t] = true
                    n = n + 1
                end
                local s = idx[t]
                if s and not gone[s] then -- 狀態圖：它的偏移不算，指到的窗少一個來源
                    gone[s] = true
                    local sl = targets[s]
                    for m = 1, #sl do
                        local u = sl[m]
                        indeg[u] = indeg[u] - 1
                        local uj = idx[u]
                        if indeg[u] == 0 and uj and not gone[uj] then
                            sn = sn + 1
                            stack[sn] = uj
                        end
                    end
                end
            end
        end
    end
    Rules.windowStates = (Rules.windowStates or 0) + n
    print("[MinidoracatBuilderFor42] window state sprites: " .. n .. " from " .. closed .. " closed of " .. wn
        .. " windows, " .. sprites:size() .. " sprites in " .. (getTimestampMs() - t0) .. " ms" .. (late and " (late)" or ""))
end

-- 圖塊定義（重新）載入：屬性是新的、還沒被改過，照這份重記
function Rules.onTileDefinitions(manager)
    WINDOW_STATE = {}
    Rules.windowStateSet = WINDOW_STATE
    Rules.windowStates = nil
    Rules.recordWindowStates(ArrayList.new(manager:getNamedMap():values()))
end
Events.OnLoadedTileDefinitions.Add(function(manager) MinidoracatBuilder.Rules.onTileDefinitions(manager) end)

-- 沒趕上 OnLoadedTileDefinitions（整個 Lua 在世界載入後才重設）時，第一次分類前照現在的屬性補記
function Rules.ensureWindowStates()
    if Rules.windowStates == nil then
        Rules.recordWindowStates(ArrayList.new(IsoSpriteManager.instance:getNamedMap():values()), true)
    end
end

function Rules.isWindowState(name)
    return WINDOW_STATE[name] == true
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
    if p:has(cutN) or p:has(cutW) then -- 牆鍵已在前面判斷過
        return not p:has(invincible) and "wallOverlay" or nil
    end
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

-- 無限水（waterAmount ≥ 9999）不列（使用者 2026-10-27 決定）：引擎只看這個值，不看停水與房間
-- （IsoObject.java:2618-2623），放一格就有永遠用不完的水。離線讀 314 個 tiledef 檔（187 萬格）有 535 格，
-- 只出現在樓梯、地板與非結構類，沒有門窗、門框、窗框、柵欄、牆，所以只在這三處查，每個牆、窗框省一次 Java 呼叫。
local function infiniteWater(p)
    local w = p:get("waterAmount")
    return w ~= nil and (tonumber(w) or 0) >= 9999
end

-- 回傳種類字串；nil＝不列（排除或不屬於任何種類）
-- name＝sprite 名稱、p＝getProperties()、t＝getType()；呼叫端已經拿到的就直接傳，不再取一次。
function Rules.kindOf(name, p, t)
    if not name or UNLISTED[name] or WINDOW_STATE[name] or excludedName(name) then return nil end
    if p:has(EntityScript) then return nil end -- 原版或 MOD 的 entity：走原版建造
    local tc = TYPE[t]
    if tc == "tree" then return nil end
    if tc == "stairs" then -- 目錄只收湊得成三格的（Rules.stairsSet）
        if infiniteWater(p) then return nil end
        -- 能搬或能拆成零件的樓梯片，原版拆解照一般搬動只拆那一片（ISMoveableSpriteProps.lua:41-44），不整組拆，
        -- 和三片都寫整組退料表的做法不合（Place.placeStairs）
        if p:has("CanScrap") or p:has("IsMoveAble") then return nil end
        return "stairs"
    end
    if p:has("GarageDoor") then return "garage" end
    if p:has(doorN) or p:has(doorW) then
        -- 雙開門要四片一組、開門圖在 +4（IsoDoor.java:789-796），單片放會開錯圖、MP 不同步；之後和車庫門一起做
        if p:has("DoubleDoor") then return nil end
        return "door"
    end
    -- 打不破的窗不列：窗自己帶 makeWindowInvincible，或同一格同方向帶 cutN/W 的物件帶它，窗就打不破、爬不過，
    -- 殭屍也不開（IsoWindow.java:1150-1172,436,1111-1135,1314）。原版 tiledef 帶它的 10 張（8 扇窗、2 片商場鐵捲門）
    -- 都搬不動，玩家拿不到。2026-10-27 傾印的目錄（正式服 13 個 tiledef MOD）也只有這 10 張，所以只在窗、窗框、牆、
    -- 牆面疊圖查，不每格多一次 Java 呼叫。
    if p:has(windowN) or p:has(windowW) then -- 窗一定也帶 WindowN/W，所以先判斷
        return not p:has(invincible) and "window" or nil
    end
    if p:has("WindowN") or p:has("WindowW") then return not p:has(invincible) and "windowFrame" or nil end
    if p:has("DoorWallN") or p:has("DoorWallW") or p:has("DoorWallNTrans") or p:has("DoorWallWTrans") then
        return "doorFrame"
    end
    if p:has(HoppableN) or p:has(HoppableW) or p:has(TallHoppableN) or p:has(TallHoppableW) then
        return "fence" -- 先於牆：低柵欄也帶牆鍵
    end
    if p:has("WallN") or p:has("WallW") or p:has("WallNW") or p:has("WallNTrans") or p:has("WallWTrans")
        or p:has("WallNWTrans") or p:has(WallSE) then
        return not p:has(invincible) and "wall" or nil
    end
    if p:has(solidfloor) then -- 平屋頂地板也在這
        if infiniteWater(p) then return nil end
        return "floor"
    end
    local mt = p:get("MoveType")
    if plantOrObject(p, mt) or infiniteWater(p) then return nil end
    if p:has("container") then return "container" end -- 冰箱帶燈，容器優先
    if tc == "light" or p:has("LightRadius") then
        -- 不是開關、又沒有 lightR 的不會亮（IsoLightSwitch 只依 lightR 建光源）。有 lightR 就要三色都有：
        -- 建構子三色都照字串轉數字，缺一個就丟錯（IsoLightSwitch.java:76-83；原版 lighting_indoor_03_5 只有 lightR）
        if tc ~= "light" and not p:has("lightR") then return nil end
        if p:has("lightR") and not (p:has("lightG") and p:has("lightB")) then return nil end
        return "light"
    end
    -- 窗簾只列打開的那張：IsoCurtain 把給的那張當開著、編號 −4 當關著（IsoCurtain.java:91-96）。床單、帳篷布不列
    if tc == "curtain" and mt == "WindowObject" then return not p:has("IsClosedState") and "curtain" or nil end
    if p:has("IsMoveAble") then return "furniture" end -- 可搬的遮雨棚也在這
    if tc == "roof" or p:has("RoofGroup") then return "roof" end -- 屋簷也算
    return decor(p, mt)
end

function Rules.classify(spr)
    return Rules.kindOf(spr:getName(), spr:getProperties(), spr:getType())
end

-- 樓梯一個項目＝同一 tileset 連號三格（B、M、T 同方向，遞增或遞減；bt-newkinds §2.1）。中片、頂片也要照 kindOf
-- 是樓梯：實體腳本、無限水、能搬或能拆成零件、不列清單只寫在某一片時整組不收（目錄只分類底片）。
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
        if m and tp and m:getType() == mt and tp:getType() == tt
            and Rules.classify(m) == "stairs" and Rules.classify(tp) == "stairs" then
            return { b = bName, m = m:getName(), t = tp:getName(), dir = north and "N" or "W" }
        end
    end
    return nil
end

return Rules
