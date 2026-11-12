-- 成本（設計稿「材料」，已定）：有原版拆解材質的照拆解產出推算，取每一輪都中的上限，所以不低於拆掉或拿起來
-- 再拆換到的；沒有的照種類給基本價（比照原版同類建造配方），再依 MaterialType 換材料。兩端共用：客戶端顯示，伺服器扣料。
-- 一格的成本＝{ items = { [fullType] = 數量 }, tools = { ItemTag 欄位名, ... }, perkOf = { [fullType] = 技能名或 false },
-- chanceOf = { [fullType] = 原版拆解定義的 baseChance（照機率退料的材料才有） }, fee = { [fullType] = 拆了不退的數量 }, back,
-- scrap（true＝照原版拆解產出收；false＝照種類基本價）, uses = { [耗材鍵] = 次數 }（硬核「原版材料」，見 USES） }；
-- 多格每格各算一次。
require "MinidoracatBuilder/Rules"
require "MinidoracatBuilder/Sets"

MinidoracatBuilder = MinidoracatBuilder or {}
local Cost = MinidoracatBuilder.Cost or {}
MinidoracatBuilder.Cost = Cost

local PLANK, NAILS = "Base.Plank", "Base.Nails"
-- 木頭（預設）。出處：media/scripts/generated/entities/walls/*.txt、furniture/entity_wood_windowglass.txt
local WOOD = {
    floor = { [PLANK] = 1, [NAILS] = 1 },                                   -- WoodFloorLvl1
    wall = { [PLANK] = 4, [NAILS] = 6 },                                    -- WoodenWallFrame＋WoodenWallLvl1
    post = { [PLANK] = 4, [NAILS] = 6 },                                    -- 柱子原本算牆（使用者 2026-10-31 拆成新種類），價錢照舊
    windowFrame = { [PLANK] = 4, [NAILS] = 6 },                             -- WoodenWallFrame＋WoodenWindowFrameLvl1
    doorFrame = { [PLANK] = 4, [NAILS] = 4 },                               -- WoodDoorFrameLvl1
    fence = { [PLANK] = 2, [NAILS] = 2 },                                   -- WoodFenceLvl1
    door = { [PLANK] = 4, [NAILS] = 4, ["Base.Hinge"] = 2, ["Base.Doorknob"] = 1 }, -- WoodenDoorLvl1
    window = { ["Base.GlassPanel"] = 4, [PLANK] = 2, [NAILS] = 4 },         -- Wooden_Windows
    solid = { [PLANK] = 2, [NAILS] = 2 },
    stairs = { [PLANK] = 13, [NAILS] = 8 },                                 -- Wood_Stairs（整組，stairs/entity_carpentry_stairs.txt）
    roof = { [PLANK] = 1, [NAILS] = 2 },                                    -- 原版沒有屋頂配方：比照木地板，斜面多一根釘子
}
-- 照木頭收的家具、容器（沒有拆解材質，MaterialType 不是金屬；磚石沒有家具配方也照木頭）照原版搬運重量
-- （PickUpWeight／10 公斤，沒寫當 5 公斤，ISMoveableSpriteProps.lua:148-149）分三級（使用者 2026-10-27 選）：
-- ≤2 公斤 1＋1、≤5 公斤 2＋2、其餘 4＋4。杯子、書這類小東西不跟衣櫃同價。金屬家具、容器照 METAL 不分級（使用者 2026-10-27 確認）。
local BY_WEIGHT = { { [PLANK] = 1, [NAILS] = 1 }, { [PLANK] = 2, [NAILS] = 2 }, { [PLANK] = 4, [NAILS] = 4 } }
local function weightTier(p)
    local kg = (tonumber(p:get("PickUpWeight")) or 50) / 10
    if kg <= 2 then return 1 end
    if kg <= 5 then return 2 end
    return 3
end
local SMALL = { [PLANK] = 1, [NAILS] = 1 } -- 掛牆物、窗上物件、地面覆蓋、牆面疊圖、附著物、疊圖
local EAVE = { [PLANK] = 1, [NAILS] = 1 }  -- 屋簷：isEave 是旗標（IsoFlagType.java:109），字串鍵查不到
-- 燈：原版沒有建造配方。沒有拆解材質的收電子零件與電線各 1、要螺絲起子、給電工經驗
local LIGHT_BASE = { ["Base.ElectronicsScrap"] = 1, ["Base.ElectricWire"] = 1 }
-- 帶 lightR 的燈都裝著燈泡（IsoLightSwitch 的燈泡欄位預設 Base.LightBulb，IsoLightSwitch.java:53）：每片另收 1 個，不給經驗。
-- 能搬的原版拿得下來（canBeModified，:76-79）；不能搬的拿不下、也不會燒掉（:683），拆除時燈泡還在才退（Dismantle.lightRefund）
local BULB = "Base.LightBulb"
Cost.BULB = BULB
-- 不能搬的金屬路燈（整個 tileset：原版 lighting_outdoor_01、UMCTP 的 lighting_outdoor_tk_01）另收鐵管 2，不給經驗（不是電工的
-- 材料）。原版沒有路燈配方，數量比照鐵管柵欄門（收 3–5 根，entities/walls/entity_metal_polefencegate*.txt）
local STREET_LIGHT = { lighting_outdoor_01 = true, lighting_outdoor_tk_01 = true }
local PIPE = "Base.MetalPipe"
-- 窗簾：床單 1 張，長窗簾（CurtainSound=Long）2 張；不要工具、不給經驗。任何 IsoCurtain 都能用原版「移除窗簾」
-- 拿回 1 張床單（IsoCurtain.removeSheet；ISWorldObjectContextMenu.lua:2234-2271），所以倍率低於 1 也照 1 收
local CURTAIN, LONG_CURTAIN = { ["Base.Sheet"] = 1 }, { ["Base.Sheet"] = 2 }
-- 磚石：BrickWall／BrickFloor 等。原版另收的黏土漿、混凝土是照次數用的桶子，硬核「原版材料」打開時才收（Cost.USES）
local MASONRY = {
    floor = { ["Base.ClayTile"] = 4 },
    wall = { ["Base.ClayBrick"] = 4 }, windowFrame = { ["Base.ClayBrick"] = 4 }, doorFrame = { ["Base.ClayBrick"] = 4 },
    fence = { ["Base.ClayBrick"] = 2 }, solid = { ["Base.ClayBrick"] = 2 }, post = { ["Base.ClayBrick"] = 4 },
}
-- 金屬：MetalWallFrame＋MetalWallLvl1 等。焊條、噴槍燃料照次數用，硬核「原版材料」打開時才收（Cost.USES）
local METAL = {
    floor = { ["Base.SmallSheetMetal"] = 1 },
    wall = { ["Base.MetalBar"] = 3, ["Base.SmallSheetMetal"] = 3 },
    post = { ["Base.MetalBar"] = 3, ["Base.SmallSheetMetal"] = 3 },
    windowFrame = { ["Base.MetalBar"] = 3, ["Base.SmallSheetMetal"] = 3 },
    doorFrame = { ["Base.MetalBar"] = 4 }, fence = { ["Base.MetalBar"] = 2 },
    door = { ["Base.SmallSheetMetal"] = 3, ["Base.Hinge"] = 2, ["Base.Doorknob"] = 1 },
    furniture = { ["Base.SmallSheetMetal"] = 2 }, container = { ["Base.SmallSheetMetal"] = 2 },
    solid = { ["Base.SmallSheetMetal"] = 2 },
    stairs = { ["Base.MetalBar"] = 4, ["Base.SmallSheetMetal"] = 6 },     -- Metal_Stairs（stairs/entity_welding_stairs.txt）
}
-- 圓木：原版 LogWall（entities/walls/entity_logwall.txt）圓木 4＋布條或繩子 4（幾種任選一，扣料只認單一物品，不收）、
-- 不用工具、不要技能。工具照原版拆圓木（Material=Log）的鐵鎚：拆除工具和蓋的時候一樣
local LOG = { wall = { ["Base.Log"] = 4 } }
-- 土、碎石、沙地板（DirtFloor／GravelFloor／SandFloor，不用工具）
local GROUND = { Dirt = "Base.Dirtbag", Grass = "Base.Dirtbag", Gravel = "Base.Gravelbag", Sand = "Base.Sandbag" }
local TOOLS = { wood = { "HAMMER" }, masonry = { "MASONS_TROWEL" }, metal = { "BLOW_TORCH", "WELDING_MASK" }, ground = {},
    electric = { "SCREWDRIVER" }, cloth = {}, log = { "HAMMER" } }
local MASONRY_TYPES = { Brick = true, Stone = true, Cinderblock = true, Concrete = true, Ceramic = true }
-- 照拆解價收的：工具照原版拆第一個 Material 要的主工具（原版 hasScrapTool 只看 self.material，
-- ISMoveableSpriteProps.lua:3986-4015；定義 ISMoveableDefinitions.lua:388-541）。噴槍另要焊接面罩（原版第二組工具）；
-- 拆木頭第二組的鋸子、拆門第二組的螺絲起子照使用者 2026-10-27 的選擇不加。沒有定義、主工具不在這張表
-- （MOD 自訂的工具）時照 MaterialType 那套；定義的主工具是空的（沙包、窗簾）原版不用工具，這裡也不用。
local SCRAP_TOOL = { ["Base.Hammer"] = { "HAMMER" }, ["Base.Screwdriver"] = { "SCREWDRIVER" },
    ["Base.BlowTorch"] = { "BLOW_TORCH", "WELDING_MASK" } }
local function scrapTools(def)
    local list = def and def.tools
    if not list then return nil end
    if #list == 0 then return {} end
    for _, ft in ipairs(list) do -- 原版把工具展開成同標籤的所有物品（parseItemTypes，ISMoveableDefinitions.lua:31-44）
        if SCRAP_TOOL[ft] then return SCRAP_TOOL[ft] end
    end
    return nil
end
-- 電器（任一 Material 的拆解技能是電工）另收 1 個電子零件，拆了不退；多格的每一格各收（使用者 2026-10-27 選並確認；
-- 原因見 AGENTS.md 踩坑錄）。
local ESCRAP = "Base.ElectronicsScrap"
-- 經驗（使用者 2026-10-27 決定：不要求技能，照材質給；技能選 B）：每付一件材料 5 點，給「拆掉時決定這件退不退」的
-- 技能。有拆解材質的，原版每個 Material 照自己拆解定義的技能擲退料機率（ISMoveableSpriteProps.lua:3318-3324、
-- getChanceByDef :3834-3838），所以每種材料給產出它的那個 Material 的技能（例：Electric 電工、Brick 砌磚、
-- Stone 力量、金屬類焊接，其餘木工；Perks.MAX 原版拆了不給，這裡也不給）。不照 MaterialType：不然木工高的人能用
-- 「材質是木頭、MaterialType 是金屬」的東西便宜練焊接。同一種材料兩個 Material 的技能不同時不給。
-- 沒有拆解材質的照工具那套材質；土、碎石、沙地板照原版不給（entity_floor_dirt／gravel／sand 沒有 xpAward）。
-- 5 點和原版一級木地板一樣（WoodFloorLvl1：1 木板＋1 釘子給 Woodwork 10，
-- scripts/generated/entities/walls/entity_wood_floorlvl1.txt）。照付的件數算：倍率改了經驗跟著改，沒付材料
-- （建造作弊；倍率 0 時不照拆解價收的）就沒有。拆掉可能把付的料全拿回的不給（back），不然蓋了拆、拆了蓋，
-- 不花料就能一直練。照機率退料的再乘上「拆掉時這件退不回來的機率」（使用者 2026-10-27 選）：原版退料率＝10＋技能等級×10
-- ＋baseChance（getChanceByDef，ISMoveableSpriteProps.lua:3834-3849）。等級看蓋的人蓋的當下（Cost.xp 的 player）。
-- 本工具拆除的（Cost.refund 的 "builder"）每項退 1..v 件、不看技能，經驗照平均拿不回的 (v − 1) / 2 件給（uniform，
-- 使用者 2026-10-28 選；付 1 件的一定全退，不給）。電器費那幾件拆了不退，不打折。
local PERK = { wood = "Woodwork", masonry = "Masonry", metal = "MetalWelding", electric = "Electricity", log = "Woodwork" }
local XP_PER_ITEM = 5

-- 硬核「需要技能」（沙盒 RequireSkill，使用者 2026-11-01 選兩個開關）：照原版 42.21 同類配方的技能等級
-- （scripts/generated/entities/walls、stairs；Wooden_Windows 木工 5、Wood_Stairs 木工 6、Metal_Stairs 焊接 5、
-- BrickFenceLvl2 石工 5）。屋頂沒有配方，照木牆；圓木牆照原版 LogWall 不要求。種類照「實際照哪一套收」：沒有對應配方、
-- 改照木頭收的照木頭。
local SKILL = {
    wood = { floor = 1, wall = 2, post = 2, windowFrame = 2, doorFrame = 2, fence = 3, door = 3, window = 5, stairs = 6,
        roof = 2 },
    masonry = { wall = 2, post = 2, windowFrame = 2, doorFrame = 2, fence = 5 },
    metal = { wall = 3, post = 3, windowFrame = 3, doorFrame = 3, door = 3, fence = 3, stairs = 5 },
}
-- 家具、容器、實心物件原版沒有對應配方：照搬運重量三級（同 BY_WEIGHT）要 1、3、5 級，金屬的一律焊接 3（原版家具配方木工 1–7）。
-- 其他種類（掛牆物、疊圖、窗簾、燈、地面覆蓋）不要求
local WEIGHED = { furniture = true, container = true, solid = true }
local SKILL_BY_WEIGHT = { 1, 3, 5 }
-- 硬核「原版材料」（沙盒 RecipeMaterials）：原版配方裡照次數用的耗材，扣次數、不寫進退料表（拆了不退）、不給經驗。
-- 鍵：tag:base:concrete＝帶 base:concrete 標籤的桶子（黏土漿、混凝土，鐵桶木桶都算，一桶 4 次）；
-- 噴槍 10 次、焊條 20 次（scripts/generated/items/drainable.txt 的 UseDelta）。
Cost.CONCRETE, Cost.TORCH, Cost.RODS = "tag:base:concrete", "Base.BlowTorch", "Base.WeldingRods"
local CONCRETE, TORCH, RODS = Cost.CONCRETE, Cost.TORCH, Cost.RODS
local USES = {
    masonry = { wall = { [CONCRETE] = 2 }, post = { [CONCRETE] = 2 }, windowFrame = { [CONCRETE] = 2 },
        doorFrame = { [CONCRETE] = 2 }, fence = { [CONCRETE] = 1 }, floor = { [CONCRETE] = 1 } },
    metal = { -- 牆＝MetalWallFrame（噴槍 1、焊條 2）＋MetalWallLvl1（噴槍 4、焊條 4）
        wall = { [TORCH] = 5, [RODS] = 6 }, post = { [TORCH] = 5, [RODS] = 6 }, windowFrame = { [TORCH] = 5, [RODS] = 2 },
        doorFrame = { [TORCH] = 4, [RODS] = 4 }, door = { [TORCH] = 4, [RODS] = 4 }, fence = { [TORCH] = 2, [RODS] = 2 },
        floor = { [TORCH] = 1, [RODS] = 1 }, stairs = { [TORCH] = 4, [RODS] = 4 } },
}
-- 石牆（MaterialType=Stone）在「原版材料」打開時照原版 StoneWall 收石磚，不收紅磚
local STONE = { wall = { ["Base.StoneBlock"] = 6 }, post = { ["Base.StoneBlock"] = 6 },
    windowFrame = { ["Base.StoneBlock"] = 5 }, doorFrame = { ["Base.StoneBlock"] = 4 } }
-- 玻璃（MaterialType=Glass，原版沒有配方）：只換木價裡沒有玻璃的種類。窗（Wooden_Windows）本來就收玻璃板 4，所以玻璃的窗、
-- 牆型窗照木窗框＋木窗；柱子照舊（商場玻璃柱 location_shop_mall_01_27）。as＝工具、技能、耗材照哪一族：
--   roof／floor：玻璃屋頂（透光）與它的平面片，木屋頂把木板換成玻璃板，釘子、鐵鎚照舊；屋簷照屋簷價換
--   fence：商場玻璃欄杆，玻璃板 1＋鐵條 1，照金屬欄杆
--   wall：店面、手扶梯的玻璃牆，原版金屬牆框 MetalWallFrame（鐵條 3、噴槍 1、焊條 2，walls/entity_metal_wallframe.txt）
--     裝玻璃板 4（同一扇木窗）
local GLASS_PANEL = "Base.GlassPanel"
local GLASS = {
    roof = { items = { [GLASS_PANEL] = 1, [NAILS] = 2 }, as = "wood" },
    floor = { items = { [GLASS_PANEL] = 1, [NAILS] = 1 }, as = "wood" },
    fence = { items = { [GLASS_PANEL] = 1, ["Base.MetalBar"] = 1 }, as = "metal" },
    wall = { items = { [GLASS_PANEL] = 4, ["Base.MetalBar"] = 3 }, as = "metal", uses = { [TORCH] = 1, [RODS] = 2 } },
}
local GLASS_EAVE = { [GLASS_PANEL] = 1, [NAILS] = 1 }
-- 補 MaterialType（Workshop 2026-11-05 Thiefman256）：原版 tiledef 大多沒寫 MaterialType，下面這些的屬性裡也沒有能分辨
-- 玻璃、圓木、金屬的欄位，伺服器又沒有貼圖，只能照圖名列。key＝圖名或整個 tileset；family 開頭先查，優先於圖塊屬性與
-- 同一套繼承。拆除工具照 Cost.of 跟著換（Dismantle.tools）
local MATERIAL = { roofs_30_04 = "Glass" } -- 整套玻璃屋頂
local function setMaterial(mt, tileset, list)
    for _, r in ipairs(list) do
        local a, b = r, r
        if type(r) == "table" then a, b = r[1], r[2] end
        for i = a, b do MATERIAL[tileset .. "_" .. i] = mt end
    end
end
setMaterial("Glass", "roofs_02", { { 32, 47 }, { 50, 61 }, 78, 79 }) -- RoofGroup=4，含帶 transparentFloor 的平面片 54、55
setMaterial("Glass", "roofs_shallow_01", { { 96, 119 } })
setMaterial("Metal", "lighting_outdoor_01", { 4, 16, 17, 52, 55 }) -- 沒有燈頭的光桿
setMaterial("Glass", "location_shop_mall_01", { 26, { 58, 61 }, 88, 89, 92, 104, 107, 108 }) -- 玻璃欄杆
setMaterial("Brick", "location_shop_mall_01", { { 28, 31 }, 56, 57 }) -- 磚花台、磚矮牆
-- 白牆門框：這張表不是一列 8 格的排法，同一套繼承（Sets.wallMaterial）會算到鐵柵牆 18 的 Metal_Light；照同一張表的牆 0–2
setMaterial("Cinderblock", "location_shop_mall_01", { 16, 17 })
setMaterial("Log", "walls_logs", { { 16, 33 }, { 56, 73 } }) -- 圓木屋、立木屋的山牆（窗框、門框照拆解價，不動）
setMaterial("Metal", "fixtures_railings_01", { 16, 17, 19, 20, 22, 23, 38 }) -- 鐵欄杆（39 是柱子，照牆價不動）
local EMPTY = {}
-- 能撿起的地磚、地毯（地板、能搬、MoveType=FloorTile；使用者 2026-11-12 選 tiles=mat）：原版撿起時那一格留下木底板
-- （ISMoveableSpriteProps.lua:1465-1477），所以分兩部分收：木底板（木地板價，照一般地板寫進退料，倍率低於 1 也照 1 收）
-- ＋照第一個 Material 的材質料（記在 fee：不寫進退料，經驗照件數全給，倍率照乘）。布面 Fabric 床單 1；磚 Brick
-- 黏土瓦 4（同磚石地板）、另要抹刀；木頭、沒寫 Material 與其他材質再一份木板釘子。不照拆解價收；技能、硬核耗材照舊看 family
local TILE_FEE = { Fabric = { ["Base.Sheet"] = 1 }, Brick = MASONRY.floor }
local TILE_OTHER = { [PLANK] = 1, [NAILS] = 1 }
local TILE_TOOLS = { Brick = { "HAMMER", "MASONS_TROWEL" } }
local TILE_PERK = { Brick = "Masonry" }
local function floorTile(kind, p)
    return kind == "floor" and p:has("IsMoveAble") and p:get("MoveType") == "FloorTile"
end

local function recipeOn()
    local s = SandboxVars and SandboxVars.MinidoracatBuilder
    return s ~= nil and s.RecipeMaterials == true
end

-- 記這種材料的經驗給哪個技能（false＝不給）；已經記了別的技能時改成不給
local function mark(perkOf, ft, pid)
    local cur = perkOf[ft]
    if cur == nil then
        perkOf[ft] = pid
    elseif cur ~= pid then
        perkOf[ft] = false
    end
end

-- MaterialType（撞擊與腳步聲用的材質，iso/enums/MaterialType.java）→ wood／masonry／metal／ground／log；回 族, MaterialType。
-- 先查補表 MATERIAL。同一套的柱子、窗框、門框沒有 MaterialType 時照同一套牆的（Sets.wallMaterial；使用者 2026-11-01 選
-- 兩種模式都照：原版 46 套磚牆、金屬牆的 174 件原本照木頭收）。玻璃照 GLASS 那一種的 as，GLASS 沒有的種類照木頭
local INHERIT = { post = true, windowFrame = true, doorFrame = true }
local function family(kind, spr)
    local name = spr:getName()
    local tileset = name and name:match("^(.*)_%d+$")
    local mt = name and MATERIAL[name] or tileset and MATERIAL[tileset] or spr:getProperties():get("MaterialType")
    if not mt and INHERIT[kind] then mt = MinidoracatBuilder.Sets.wallMaterial(name) end
    if not mt then return "wood", nil end
    if mt == "Glass" and GLASS[kind] then return GLASS[kind].as, mt end
    if mt == "Log" and LOG[kind] then return "log", mt end
    if mt:sub(1, 5) == "Metal" then return "metal", mt end
    if MASONRY_TYPES[mt] then return "masonry", mt end
    if kind == "floor" and GROUND[mt] then return "ground", mt end
    return "wood", mt
end

-- 照種類的基本價：回 base, 實際照哪一族收（這個材質沒有對應的配方時照木頭，例：磚造家具）
local function basePrice(kind, p, fam, mt)
    if kind == "light" then return LIGHT_BASE, "electric" end
    if kind == "curtain" then return p:get("CurtainSound") == "Long" and LONG_CURTAIN or CURTAIN, "cloth" end
    local glass = mt == "Glass" and GLASS[kind]
    if glass then return kind == "roof" and p:has(IsoFlagType.isEave) and GLASS_EAVE or glass.items, fam end
    local base
    if fam == "ground" then
        base = { [GROUND[mt]] = 1 }
    elseif fam == "metal" then
        base = METAL[kind]
    elseif fam == "masonry" then
        base = (mt == "Stone" and recipeOn() and STONE[kind]) or MASONRY[kind]
    elseif fam == "log" then
        base = LOG[kind]
    end
    if base then return base, fam end
    if kind == "furniture" or kind == "container" then return BY_WEIGHT[weightTier(p)], "wood" end
    if kind == "roof" and p:has(IsoFlagType.isEave) then return EAVE, "wood" end
    return WOOD[kind] or SMALL, "wood"
end

-- 硬核「需要技能」：回 技能 ID, 等級；不要求的種類回 nil。照基本價那一族（拆解價的也照它：同一件要的技能不看怎麼收料）。
-- 牆型窗取窗框、窗兩者較高
function Cost.skillOf(kind, spr)
    local p = spr:getProperties()
    local _, fam = basePrice(kind, p, family(kind, spr))
    local lv = SKILL[fam] and SKILL[fam][kind]
    if lv and kind == "window" and MinidoracatBuilder.Rules.framedWindow(spr:getType()) then
        lv = math.max(lv, SKILL[fam].windowFrame or 0)
    end
    if lv then return PERK[fam], lv end
    if not WEIGHED[kind] then return nil end
    if fam == "metal" then return PERK.metal, 3 end
    return PERK[fam], SKILL_BY_WEIGHT[weightTier(p)]
end

-- 原版拆解產出的上限（ISMoveableSpriteProps:getScrapItemsList、addScrapItemToList，shared/Moveables）：
-- 每個 Material 取 returnItemsStatic（有的話）否則 returnItems；每項 maxAmount 輪，可拆（CanScrap）時 Small 減半
-- （至少 1）、Large 加倍；沙包固定 3。原版每輪有機率，這裡取每輪都中，所以不低於拆掉換到的。
-- 每種材料的技能記進 perkOf、baseChance 記進 chanceOf（同一種材料多個定義取大的：退得多、給得少）。
-- 回 any（有產出）, back（拆掉可能把付的料全拿回：一定會退的產出，沙包固定 3 個（:3368-3378），每輪機率 ≥ 100 的
-- （窗簾）技能夠就每輪都中）, 第一個 Material 的定義, elec（有電工的拆解定義）。
-- 本工具拆除的種類（不能搬、不照材質拆）照退料表退 1..v 件，不看這裡的 back（Cost.of 的 builder）。
local NOT_BUILDER = { door = true, window = true, curtain = true }
local function scrapInto(kind, p, out, perkOf, chanceOf)
    local defs = ISMoveableDefinitions and ISMoveableDefinitions:getInstance()
    if not defs then return false, false end
    local size = p:has("CanScrap") and (p:get("ScrapSize") or "Medium") or nil
    local any, back, first, elec = false, false, nil, false
    for i, key in ipairs({ "Material", "Material2", "Material3" }) do
        local mat = p:get(key)
        local def = mat and mat ~= "Undefined" and defs.getScrapDefinition(mat)
        if def then
            if i == 1 then first = def end
            -- Perk 的 toString 是技能 ID（PerkFactory.java:320-322；原版 ISPerkLog.lua:14 同寫法）
            local pid = def.perk and tostring(def.perk) or false
            if pid == "MAX" then pid = false end
            if pid == "Electricity" then elec = true end
            local base = def.baseChance or 0
            local list = def.returnItemsStatic
            if not list or #list < 1 then list = def.returnItems end
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
                    if chanceOf and (chanceOf[r.returnItem] or -1000) < base then chanceOf[r.returnItem] = base end
                    any = true
                    if r.returnItem == "Base.Sandbag" or (r.chancePerRoll or 0) >= 100 then back = true end
                end
            end
        end
    end
    return any, back, first, elec
end

local function copyInto(src, out)
    for k, v in pairs(src) do out[k] = v end
end

-- 硬核耗材表（玻璃牆照 GLASS 自己的）
local function usesOf(fam, kind, mt)
    local glass = mt == "Glass" and GLASS[kind]
    return glass and glass.uses or USES[fam] and USES[fam][kind] or EMPTY
end

-- 一格的成本。multiplier＝沙盒 CostMultiplier（0＝免材料，工具照樣要）。數量、耗材次數都無條件進位。
function Cost.of(kind, spr, multiplier)
    local p = spr:getProperties()
    local fam, mt = family(kind, spr)
    local items, perkOf, chanceOf = {}, {}, {}
    local m = multiplier or 1
    local scrapped, back, first, elec = scrapInto(kind, p, items, perkOf, chanceOf)
    -- 本工具拆除的（Cost.refund 的 "builder"）照退料表退 1..v 件、經驗照 uniform 給（Cost.xp）
    local builder = Cost.refund(kind, spr) == "builder"
    if builder then back = false end
    local tile = floorTile(kind, p)
    if kind == "stairs" or tile then
        -- 樓梯整組照原版配方收（Cost.forCells 收在頂片那一格）；能撿起的地磚照 TILE_FEE
        items, perkOf, chanceOf, scrapped, elec = {}, {}, {}, false, false
    end
    local toolSet, framed, extra, extraPerk
    if tile then
        if m < 1 then m = 1 end -- 木底板拆得回來，最低照 1 收
        back = false
        copyInto(WOOD.floor, items)
        -- 經驗：木底板撿起再拆可能整份退回，一律不給——記成一定全退（Cost.xp 照 chanceOf 打折，退料率夾到 100%）；
        -- 材質料（fee）照件數全給。木地磚的材質料也是木板釘子，同一種物品只有 fee 那幾件給
        for ft in pairs(items) do
            perkOf[ft] = PERK.wood
            chanceOf[ft] = 100
        end
        local mat = p:get("Material")
        extra, toolSet, extraPerk = TILE_FEE[mat] or TILE_OTHER, TILE_TOOLS[mat] or TOOLS.wood, TILE_PERK[mat] or PERK.wood
    elseif scrapped then
        -- 有拆解材質的圖塊：能搬或 CanScrap 的，原版拆解照圖塊材質重查（ISMoveableSpriteProps.lua:3690-3720,3318-3330）；
        -- 不能搬、沒有 CanScrap 的（builder）照退料表退 1..v 件。兩種都不會退得比這裡收的多。
        -- 倍率低於 1 時拆掉拿到的會比付的多，所以這類最低照拆解上限收。
        if m < 1 then m = 1 end
        toolSet = scrapTools(first)
    else
        local base
        base, fam = basePrice(kind, p, fam, mt)
        if kind == "curtain" and m < 1 then m = 1 end
        copyInto(base, items)
        -- 牆型窗（窗和窗框畫在同一張，Rules.framedWindow）：同一族的窗框＋窗
        framed = kind == "window" and MinidoracatBuilder.Rules.framedWindow(spr:getType())
        if framed then
            for ft, n in pairs((basePrice("windowFrame", p, fam, mt))) do items[ft] = (items[ft] or 0) + n end
        end
        for ft in pairs(items) do perkOf[ft] = PERK[fam] or false end
        if kind == "light" and not p:has("IsMoveAble") and STREET_LIGHT[(spr:getName() or ""):match("^(.*)_%d+$") or ""] then
            items[PIPE] = 2
            perkOf[PIPE] = false
        end
    end
    -- 電器費（照拆解價或基本價都收）：照倍率算進 items，另記在 fee，Place 不寫進 buildMaterials（拆了不退）
    if elec then
        items[ESCRAP] = (items[ESCRAP] or 0) + 1
        mark(perkOf, ESCRAP, "Electricity")
    end
    local out = {}
    for ft, n in pairs(items) do
        local v = math.ceil(n * m - 1e-9)
        if v > 0 then out[ft] = v end
    end
    if kind == "light" and p:has("lightR") then -- 燈泡：倍率低於 1 也照 1 收（能搬的拿得下來，不能搬的拆了退）
        out[BULB] = (out[BULB] or 0) + math.max(1, math.ceil(m - 1e-9))
        perkOf[BULB] = false
    end
    local fee = {}
    if elec then
        local f = (out[ESCRAP] or 0) - math.ceil((items[ESCRAP] - 1) * m - 1e-9)
        if f > 0 then fee[ESCRAP] = f end
    end
    for ft, n in pairs(extra or EMPTY) do -- 地磚的材質料：照原本的倍率
        local v = math.ceil(n * (multiplier or 1) - 1e-9)
        if v > 0 then
            out[ft] = (out[ft] or 0) + v
            fee[ft] = v
            mark(perkOf, ft, extraPerk)
        end
    end
    -- 耗材不退料，照原本的倍率（上面「最低照 1 收」只為了退料不多於付的）
    local uses = {}
    if recipeOn() then
        local raw = {}
        copyInto(usesOf(fam, kind, mt), raw)
        if framed then
            for key, n in pairs(usesOf(fam, "windowFrame", mt)) do raw[key] = (raw[key] or 0) + n end
        end
        for key, n in pairs(raw) do
            local v = math.ceil(n * (multiplier or 1) - 1e-9)
            if v > 0 then uses[key] = v end
        end
    end
    local tools = {}
    for i, t in ipairs(toolSet or TOOLS[fam]) do tools[i] = t end
    if back then perkOf = {} end
    return { items = out, tools = tools, perkOf = perkOf, chanceOf = chanceOf, fee = fee, back = back, scrap = scrapped,
        uniform = builder, uses = uses }
end

-- 把多格的成本加總（扣料與顯示用）；tools 取聯集
function Cost.sum(list)
    local items, tools, seen, uses = {}, {}, {}, {}
    for _, c in ipairs(list) do
        for ft, n in pairs(c.items) do items[ft] = (items[ft] or 0) + n end
        for key, n in pairs(c.uses or EMPTY) do uses[key] = (uses[key] or 0) + n end
        for _, t in ipairs(c.tools) do
            if not seen[t] then
                seen[t] = true
                tools[#tools + 1] = t
            end
        end
    end
    return { items = items, tools = tools, uses = uses }
end

-- 一個項目各格的成本（sprites＝各格 sprite，依 Entry.cells 的順序）。原版拆多格物件時每一片都照被點的那片材質給
-- （ISMoveableSpriteProps.lua:3481-3495），各片材質不一定相同（原版有 4 組，例：病床椅），所以多格的每一格都收
-- 各格的最大值，拆哪一片都不會比付的多。同理，有一片是 back，點那片拆就整組都可能全拿回，整組不給經驗；
-- 同一種材料在各片的技能不同時，退料機率看點的那片，拿自己高的技能拆就能便宜練另一個，這種材料也不給。
-- 每片都是本工具拆除的（uniform）才照 1..v 給：本工具拆一組時每片照自己的退料表退（Server.dismantle）。
-- 樓梯例外：整組照配方收一次，放在第一格（頂片）；其他格（中片、底片、平台）不收，三片的 buildMaterials 都寫整組
-- （Place.build），拆哪一片都照那片的 buildMaterials 退一次、整組移除。能蓋的樓梯三片都不能搬、沒有 CanScrap
-- （Rules.classify、Rules.stairsSet），所以三片的拆除方式都和頂片一樣。
function Cost.forCells(kind, sprites, multiplier)
    local each = {}
    if kind == "stairs" then
        local c = Cost.of(kind, sprites[1], multiplier)
        each[1] = c
        for i = 2, #sprites do
            each[i] = { items = {}, tools = c.tools, perkOf = c.perkOf, chanceOf = {}, fee = {}, back = c.back,
                uniform = c.uniform, uses = {} }
        end
        return each
    end
    for i, spr in ipairs(sprites) do each[i] = Cost.of(kind, spr, multiplier) end
    if #each < 2 then return each end
    local top, perkOf, chanceOf, fee, back, uniform = {}, {}, {}, {}, false, true
    for _, c in ipairs(each) do
        back = back or c.back
        uniform = uniform and c.uniform
        for ft, n in pairs(c.items) do
            if n > (top[ft] or 0) then top[ft] = n end
            mark(perkOf, ft, c.perkOf[ft] or false)
        end
        for ft, b in pairs(c.chanceOf) do
            if (chanceOf[ft] or -1000) < b then chanceOf[ft] = b end
        end
        for ft, n in pairs(c.fee) do
            if n > (fee[ft] or 0) then fee[ft] = n end
        end
    end
    if back then perkOf = {} end
    local tools = Cost.sum(each).tools
    for i = 1, #each do
        local items = {}
        for ft, n in pairs(top) do items[ft] = n end
        each[i] = { items = items, tools = tools, perkOf = perkOf, chanceOf = chanceOf, fee = fee, back = back,
            uniform = uniform, uses = each[i].uses } -- 耗材不退，每格照自己的收
    end
    return each
end

-- 拆掉時一件退得回來的機率（%）：原版 getChanceByDef（ISMoveableSpriteProps.lua:3834-3849）。不知道誰蓋的當全退
local function returnChance(player, pid, base)
    if not player or (ISMoveableDefinitions and ISMoveableDefinitions.cheat) or player:isMovablesCheat() then return 100 end
    local c = 10 + player:getPerkLevel(Perks.FromString(pid)) * 10 + base
    if c < 0 then return 0 end
    if c > 100 then return 100 end
    return c
end

-- 這次付的材料換成經驗：{ [技能名] = 點數 }（costs＝各格成本，player＝蓋的人）。照機率退料的材料乘上
-- （100 − 退料率）%，點數可能有小數；全退的（技能夠高）那種材料不給。本工具拆除的（uniform）每項退 1..r 件
-- （r＝付的扣掉電器費），平均拿不回 (r − 1) / 2 件。電器費（fee）拆了不退，照件數全給。
function Cost.xp(costs, player)
    local out = {}
    for _, c in ipairs(costs) do
        for ft, n in pairs(c.items) do
            local pid = c.perkOf[ft]
            if pid and n > 0 then
                local pts = n * XP_PER_ITEM
                local base = c.chanceOf and c.chanceOf[ft]
                local f = c.fee and c.fee[ft] or 0
                if c.uniform then
                    local r = n - f
                    pts = (f + (r > 1 and (r - 1) / 2 or 0)) * XP_PER_ITEM
                elseif base then
                    pts = ((n - f) * (100 - returnChance(player, pid, base)) / 100 + f) * XP_PER_ITEM
                end
                if pts > 0 then out[pid] = (out[pid] or 0) + pts end
            end
        end
    end
    return out
end

-- 蓋好之後拆掉退什麼（介面的「拆除方式」）。原版拆解怎麼分流（ISMoveableSpriteProps.fromObject，:33-47）：
--   "pickup"：能搬（IsMoveAble），拿起來帶走。
--   "scrap"：CanScrap 且 Material 有定義（:104-123）、有拆解產出：照圖塊材質重查產出（getScrapItemsList，:3304-3348）。
--   "builder"：其他不能搬的 IsoThumpable 與燈：本工具拆除（Server.dismantle），每項退 1..v（v＝退料表）。第一個
--     Material 有拆解定義的，原版搬動工具也能拆（ISThumpableSpriteProps，:4320-4340），同樣 1..v；一樓以下的地板不給它拆
--     （Place.thumpable 的 isDismantable）。掛上去的地面覆蓋與牆上疊圖（Rules.onFloor、Rules.onWall）不是物件，原版拆解點
--     不到，帶 CanScrap 的也歸本工具拆（牆上疊圖那條邊沒有牆、建成獨立物件時也一樣，拆除方式只看圖）。
--   "sheet"：不能搬的窗簾。任何 IsoCurtain 都能用原版「移除窗簾」拿回 1 張床單（IsoCurtain.removeSheet）。
--   "none"：其他門、窗（不是 IsoThumpable，Place.build 用 IsoDoor／IsoWindow）只能砸，不退料。
-- 只看這一片的 sprite 屬性與拆解定義，不碰世界。
function Cost.refund(kind, spr)
    local p = spr:getProperties()
    if p:has("IsMoveAble") then return "pickup" end
    if kind == "curtain" then return "sheet" end
    local R = MinidoracatBuilder.Rules
    if R.onFloor(kind, spr) or R.onWall(kind, spr) then return "builder" end
    local mat = p:get("Material")
    if p:has("CanScrap") and mat and mat ~= "Undefined" and scrapInto(kind, p, {}, {}) then return "scrap" end
    if NOT_BUILDER[kind] then return "none" end
    return "builder"
end

return Cost
