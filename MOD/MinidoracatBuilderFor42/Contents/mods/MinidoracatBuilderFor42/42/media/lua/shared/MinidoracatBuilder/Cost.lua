-- 成本（設計稿「材料」，已定）：有原版拆解材質的照拆解產出推算，取每一輪都中的上限，所以不低於拆掉或拿起來
-- 再拆換到的；沒有的照種類給基本價（比照原版同類建造配方），再依 MaterialType 換材料。兩端共用：客戶端顯示，伺服器扣料。
-- 一格的成本＝{ items = { [fullType] = 數量 }, tools = { ItemTag 欄位名, ... }, perkOf = { [fullType] = 技能名或 false }, back,
-- scrap（true＝照原版拆解產出收；false＝照種類基本價） }；多格每格各算一次。
MinidoracatBuilder = MinidoracatBuilder or {}
local Cost = MinidoracatBuilder.Cost or {}
MinidoracatBuilder.Cost = Cost

local PLANK, NAILS = "Base.Plank", "Base.Nails"
-- 木頭（預設）。出處：media/scripts/generated/entities/walls/*.txt、furniture/entity_wood_windowglass.txt
local WOOD = {
    floor = { [PLANK] = 1, [NAILS] = 1 },                                   -- WoodFloorLvl1
    wall = { [PLANK] = 4, [NAILS] = 6 },                                    -- WoodenWallFrame＋WoodenWallLvl1
    windowFrame = { [PLANK] = 4, [NAILS] = 6 },                             -- WoodenWallFrame＋WoodenWindowFrameLvl1
    doorFrame = { [PLANK] = 4, [NAILS] = 4 },                               -- WoodDoorFrameLvl1
    fence = { [PLANK] = 2, [NAILS] = 2 },                                   -- WoodFenceLvl1
    door = { [PLANK] = 4, [NAILS] = 4, ["Base.Hinge"] = 2, ["Base.Doorknob"] = 1 }, -- WoodenDoorLvl1
    window = { ["Base.GlassPanel"] = 4, [PLANK] = 2, [NAILS] = 4 },         -- Wooden_Windows
    furniture = { [PLANK] = 4, [NAILS] = 4 },
    container = { [PLANK] = 4, [NAILS] = 4 },
    solid = { [PLANK] = 2, [NAILS] = 2 },
}
local SMALL = { [PLANK] = 1, [NAILS] = 1 } -- 掛牆物、窗上物件、地面覆蓋、牆面疊圖、附著物、疊圖
-- 磚石：BrickWall／BrickFloor 等（混凝土是液體容器，ponytail：不收，要收時改用 use: 扣容量）
local MASONRY = {
    floor = { ["Base.ClayTile"] = 4 },
    wall = { ["Base.ClayBrick"] = 4 }, windowFrame = { ["Base.ClayBrick"] = 4 }, doorFrame = { ["Base.ClayBrick"] = 4 },
    fence = { ["Base.ClayBrick"] = 2 }, solid = { ["Base.ClayBrick"] = 2 },
}
-- 金屬：MetalWallFrame＋MetalWallLvl1 等（焊條、噴燈燃料是可耗用的，ponytail：只要求帶著噴燈與面罩）
local METAL = {
    floor = { ["Base.SmallSheetMetal"] = 1 },
    wall = { ["Base.MetalBar"] = 3, ["Base.SmallSheetMetal"] = 3 },
    windowFrame = { ["Base.MetalBar"] = 3, ["Base.SmallSheetMetal"] = 3 },
    doorFrame = { ["Base.MetalBar"] = 4 }, fence = { ["Base.MetalBar"] = 2 },
    door = { ["Base.SmallSheetMetal"] = 3, ["Base.Hinge"] = 2, ["Base.Doorknob"] = 1 },
    furniture = { ["Base.SmallSheetMetal"] = 2 }, container = { ["Base.SmallSheetMetal"] = 2 },
    solid = { ["Base.SmallSheetMetal"] = 2 },
}
-- 土、碎石、沙地板（DirtFloor／GravelFloor／SandFloor，不用工具）
local GROUND = { Dirt = "Base.Dirtbag", Grass = "Base.Dirtbag", Gravel = "Base.Gravelbag", Sand = "Base.Sandbag" }
local TOOLS = { wood = { "HAMMER" }, masonry = { "MASONS_TROWEL" }, metal = { "BLOW_TORCH", "WELDING_MASK" }, ground = {} }
local MASONRY_TYPES = { Brick = true, Stone = true, Cinderblock = true, Concrete = true, Ceramic = true }
-- 經驗（使用者 2026-10-27 決定：不要求技能，照材質給；技能選 B）：每付一件材料 5 點，給「拆掉時決定這件退不退」的
-- 技能。有拆解材質的，原版每個 Material 照自己拆解定義的技能擲退料機率（ISMoveableSpriteProps.lua:3318-3324、
-- getChanceByDef :3834-3838），所以每種材料給產出它的那個 Material 的技能（例：Electric 電工、Brick 砌磚、
-- Stone 力量、金屬類焊接，其餘木工；Perks.MAX 原版拆了不給，這裡也不給）。不照 MaterialType：不然木工高的人能用
-- 「材質是木頭、MaterialType 是金屬」的東西便宜練焊接。同一種材料兩個 Material 的技能不同時不給。
-- 沒有拆解材質的照工具那套材質；土、碎石、沙地板照原版不給（entity_floor_dirt／gravel／sand 沒有 xpAward）。
-- 5 點和原版一級木地板一樣（WoodFloorLvl1：1 木板＋1 釘子給 Woodwork 10，
-- scripts/generated/entities/walls/entity_wood_floorlvl1.txt）。照付的件數算：倍率改了經驗跟著改，沒付材料
-- （建造作弊；倍率 0 時不照拆解價收的）就沒有。拆掉可能把付的料全拿回的不給（back），不然蓋了拆、拆了蓋，
-- 不花料就能一直練。
local PERK = { wood = "Woodwork", masonry = "Masonry", metal = "MetalWelding" }
local XP_PER_ITEM = 5

-- 記這種材料的經驗給哪個技能（false＝不給）；已經記了別的技能時改成不給
local function mark(perkOf, ft, pid)
    local cur = perkOf[ft]
    if cur == nil then
        perkOf[ft] = pid
    elseif cur ~= pid then
        perkOf[ft] = false
    end
end

-- MaterialType（撞擊與腳步聲用的材質，iso/enums/MaterialType.java）→ wood／masonry／metal／ground
local function family(kind, p)
    local mt = p:get("MaterialType")
    if not mt then return "wood" end
    if mt:sub(1, 5) == "Metal" then return "metal" end
    if MASONRY_TYPES[mt] then return "masonry" end
    if kind == "floor" and GROUND[mt] then return "ground" end
    return "wood"
end

-- 原版拆解產出的上限（ISMoveableSpriteProps:getScrapItemsList、addScrapItemToList，shared/Moveables）：
-- 每個 Material 取 returnItemsStatic（有的話）否則 returnItems；每項 maxAmount 輪，可拆（CanScrap）時 Small 減半
-- （至少 1）、Large 加倍；沙包固定 3。原版每輪有機率，這裡取每輪都中，所以不低於拆掉換到的。
-- 每種材料的技能記進 perkOf。回 any（有產出）, back（拆掉可能把付的料全拿回）。
-- back 有兩種：
-- ① 沒有 CanScrap、不能搬、第一個 Material 有產出的 IsoThumpable：原版改走 ISThumpableSpriteProps，照 buildMaterials
--    每項退 1..v 件（v＝付的數量，1 件的一定全退；ISMoveableSpriteProps.lua:41-44,104-122,4232,4323-4340）。
--    門窗不是 IsoThumpable，不走這條。
-- ② 一定會退的產出：沙包固定 3 個（:3368-3378），每輪機率 ≥ 100 的（窗簾）技能夠就每輪都中。
local NOT_THUMPABLE = { door = true, window = true }
local function scrapInto(kind, p, out, perkOf)
    local defs = ISMoveableDefinitions and ISMoveableDefinitions:getInstance()
    if not defs then return false, false end
    local size = p:has("CanScrap") and (p:get("ScrapSize") or "Medium") or nil
    local any, back = false, false
    for i, key in ipairs({ "Material", "Material2", "Material3" }) do
        local mat = p:get(key)
        local def = mat and mat ~= "Undefined" and defs.getScrapDefinition(mat)
        if def then
            -- Perk 的 toString 是技能 ID（PerkFactory.java:320-322；原版 ISPerkLog.lua:14 同寫法）
            local pid = def.perk and tostring(def.perk) or false
            if pid == "MAX" then pid = false end
            local list = def.returnItemsStatic
            if not list or #list < 1 then list = def.returnItems end
            if i == 1 and list and #list > 0 and not size and not NOT_THUMPABLE[kind] and not p:has("IsMoveAble") then
                back = true
            end
            for _, r in ipairs(list or {}) do
                local n = r.maxAmount or 0
                if size == "Small" then
                    n = n / 2 >= 1 and n / 2 or 1
                elseif size == "Large" then
                    n = n * 2
                end
                n = math.floor(n) -- 原版 for i = 1, 1.5 只跑一輪
                if r.returnItem == "Base.Sandbag" then n = 3 end
                if n > 0 then
                    out[r.returnItem] = (out[r.returnItem] or 0) + n
                    mark(perkOf, r.returnItem, pid)
                    any = true
                    if r.returnItem == "Base.Sandbag" or (r.chancePerRoll or 0) >= 100 then back = true end
                end
            end
        end
    end
    return any, back
end

local function copyInto(src, out)
    for k, v in pairs(src) do out[k] = v end
end

-- 一格的成本。multiplier＝沙盒 CostMultiplier（0＝免材料，工具照樣要）。數量無條件進位。
function Cost.of(kind, spr, multiplier)
    local p = spr:getProperties()
    local fam = family(kind, p)
    local items, perkOf = {}, {}
    local m = multiplier or 1
    local scrapped, back = scrapInto(kind, p, items, perkOf)
    if scrapped then
        -- 有拆解材質的圖塊：能搬或 CanScrap 的，原版拆解照圖塊材質重查（ISMoveableSpriteProps.lua:3690-3720,3318-3330）；
        -- back ① 那類照 buildMaterials 退 1..v 件。兩種都不會退得比這裡收的多。
        -- 倍率低於 1 時拆掉拿到的會比付的多，所以這類最低照拆解上限收。
        if m < 1 then m = 1 end
    else
        local base
        if fam == "ground" then
            base = { [GROUND[p:get("MaterialType")]] = 1 }
        elseif fam == "metal" then
            base = METAL[kind]
        elseif fam == "masonry" then
            base = MASONRY[kind]
        end
        if not base then -- 這個材質沒有對應的配方（例：磚造家具）：照木頭
            fam = "wood"
            base = WOOD[kind] or SMALL
        end
        copyInto(base, items)
        for ft in pairs(base) do perkOf[ft] = PERK[fam] or false end
    end
    local out = {}
    for ft, n in pairs(items) do
        local v = math.ceil(n * m - 1e-9)
        if v > 0 then out[ft] = v end
    end
    local tools = {}
    for i, t in ipairs(TOOLS[fam]) do tools[i] = t end
    if back then perkOf = {} end
    return { items = out, tools = tools, perkOf = perkOf, back = back, scrap = scrapped }
end

-- 把多格的成本加總（扣料與顯示用）；tools 取聯集
function Cost.sum(list)
    local items, tools, seen = {}, {}, {}
    for _, c in ipairs(list) do
        for ft, n in pairs(c.items) do items[ft] = (items[ft] or 0) + n end
        for _, t in ipairs(c.tools) do
            if not seen[t] then
                seen[t] = true
                tools[#tools + 1] = t
            end
        end
    end
    return { items = items, tools = tools }
end

-- 一個項目各格的成本（sprites＝各格 sprite，依 Entry.cells 的順序）。原版拆多格物件時每一片都照被點的那片材質給
-- （ISMoveableSpriteProps.lua:3481-3495），各片材質不一定相同（原版有 4 組，例：病床椅），所以多格的每一格都收
-- 各格的最大值，拆哪一片都不會比付的多。同理，有一片是 back，點那片拆就整組都可能全拿回，整組不給經驗；
-- 同一種材料在各片的技能不同時，退料機率看點的那片，拿自己高的技能拆就能便宜練另一個，這種材料也不給。
function Cost.forCells(kind, sprites, multiplier)
    local each = {}
    for i, spr in ipairs(sprites) do each[i] = Cost.of(kind, spr, multiplier) end
    if #each < 2 then return each end
    local top, perkOf, back = {}, {}, false
    for _, c in ipairs(each) do
        back = back or c.back
        for ft, n in pairs(c.items) do
            if n > (top[ft] or 0) then top[ft] = n end
            mark(perkOf, ft, c.perkOf[ft] or false)
        end
    end
    if back then perkOf = {} end
    local tools = Cost.sum(each).tools
    for i = 1, #each do
        local items = {}
        for ft, n in pairs(top) do items[ft] = n end
        each[i] = { items = items, tools = tools, perkOf = perkOf, back = back }
    end
    return each
end

-- 這次付的材料換成經驗：{ [技能名] = 點數 }（costs＝各格成本）
function Cost.xp(costs)
    local out = {}
    for _, c in ipairs(costs) do
        for ft, n in pairs(c.items) do
            local pid = c.perkOf[ft]
            if pid and n > 0 then out[pid] = (out[pid] or 0) + n * XP_PER_ITEM end
        end
    end
    return out
end

-- 蓋好之後拆掉退什麼（介面的「拆除方式」）。原版拆解怎麼分流（ISMoveableSpriteProps.fromObject，:33-47）：
--   "pickup"：能搬（IsMoveAble），拿起來帶走。
--   "scrap"：CanScrap 且 Material 有定義（:104-123）、有拆解產出：照圖塊材質重查產出（getScrapItemsList，:3304-3348）。
--   "materials"：第二階段放的 IsoThumpable（門、窗以外）不能搬、不能照材質拆，第一個 Material 有拆解定義時改走
--     ISThumpableSpriteProps，照 buildMaterials 每項退 1..v（:4232 isScrapDefinitionValid、:4320-4340、canScrapObject :4369-4378；
--     判斷照 ISMoveableDefinitions.lua:172-180）。
--   "none"：其他（例：沒有拆解產出的門、窗，它們不是 IsoThumpable，Place.build 用 IsoDoor／IsoWindow）只能砸，不退料。
-- 只看 sprite 屬性與拆解定義，不碰世界；伺服器沒有 ISMoveableDefinitions 時當 "none"。
function Cost.refund(kind, spr)
    local p = spr:getProperties()
    if p:has("IsMoveAble") then return "pickup" end
    local mat = p:get("Material")
    if p:has("CanScrap") and mat and mat ~= "Undefined" then
        return scrapInto(kind, p, {}, {}) and "scrap" or "none"
    end
    if NOT_THUMPABLE[kind] then return "none" end
    local defs = ISMoveableDefinitions and ISMoveableDefinitions:getInstance()
    local def = defs and mat and defs.getScrapDefinition(mat)
    if def and ((def.returnItems and #def.returnItems > 0) or (def.returnItemsStatic and #def.returnItemsStatic > 0)) then
        return "materials"
    end
    return "none"
end

return Cost
