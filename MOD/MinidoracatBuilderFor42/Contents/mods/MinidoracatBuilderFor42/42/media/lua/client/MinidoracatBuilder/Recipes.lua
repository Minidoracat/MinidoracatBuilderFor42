-- 建造配方項目（使用者 2026-11-09 在設計稿 https://share.onorca.dev/a/4dy0caYOlmPY 選 all、mix、kinds、tile）：建造工坊也列
-- 原版與 MOD 的建造配方，和圖塊放在同一個頁籤、分類與整套裡；選了開原版自己的游標，材料、技能、時間與拆除都照原版
-- （本 MOD 不加網路指令，放下以後全是原版建造的路）。
-- 清單和原版建造視窗同一份（BuildLogic:getAllBuildableRecipes，ISBuildPanel.lua:39-44），篩法也同原版：沒學過的
-- （BaseCraftingLogic.java:162-176）、OnAddToMenu 回 false 的（ISTiledIconPanel.lua:193-197）不列；另外不列管理員關掉的種類。
-- 項目 ID＝"recipe:"＋配方全名（例 recipe:Base.RainCollector_Tarp）；圖塊項目照舊是 sprite 名稱。
-- 主圖本工具目錄已經列了的（配方的地板）不另列配方版（使用者同日選 tile）。
require "MinidoracatBuilder/Rules"
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Messages"

MinidoracatBuilder = MinidoracatBuilder or {}
local Recipes = MinidoracatBuilder.Recipes or {}
MinidoracatBuilder.Recipes = Recipes
local Rules, Entry, Messages = MinidoracatBuilder.Rules, MinidoracatBuilder.Entry, MinidoracatBuilder.Messages

local LOG = "[MinidoracatBuilderFor42] "
Recipes.PREFIX = "recipe:"

-- Recipes.onEnd(playerNum)：Window 設定；本 MOD 開的配方游標離開時（右鍵、手把 B、換了別的游標）呼叫，換成本工具另一個
-- 游標時不呼叫（同 Cursor.onEnd）
Recipes.list = nil    -- { n, 項目… }：全部配方項目，第一次用到才掃，整場遊戲留著
Recipes.byId = {}     -- 項目 ID → 項目
Recipes.bySprite = {} -- 配方的每一張圖 → 項目（吸管、右鍵挑圖塊、搜完整圖塊名）
Recipes.gen = 0       -- 掃過幾次（Window 照它重排）

-- 每個 Java 容器清單都照原版建造視窗拿（背包、袋子、旁邊的容器與地上；ISBuildPanel.lua:214-221）。介面還沒建好時回 nil
local function containersOf(player)
    local ok, c = pcall(ISInventoryPaneContextMenu.getContainers, player)
    return ok and c or nil
end

-- 新的 BuildLogic：先跑一次 getAllBuildableRecipes，getWallCoveringParams 要查它填的表（BuildLogic.java:90-97,153-174，
-- 沒跑會 NPE）。原版視窗切過「手動選材料」的玩家，新 logic 會照那個模式、不自己填材料（BuildLogic.java:41-56）；
-- 本 MOD 沒有手動選的介面，一律自動
local function newLogic(player)
    local L = BuildLogic.new(player, nil, nil)
    L:getAllBuildableRecipes()
    L:setManualSelectInputs(false)
    return L
end

local function upperFirst(s)
    return s:sub(1, 1):upper() .. s:sub(2)
end

-- 原版建造視窗的分頁名（ISWidgetRecipeCategories.lua:100）；沒有譯名照原字
function Recipes.categoryLabel(cat)
    return getTextOrNull("IGUI_CraftingCategories_" .. upperFirst(cat)) or cat
end

local function sourceName(src)
    if src == "vanilla" then return getText("IGUI_MBLD_Source_Vanilla") end
    local info = getModInfoByID and getModInfoByID(src)
    return info and info:getName() or src
end

-- 放在哪個種類的頁籤：牆面油漆、壁紙、灰泥沒有主圖，放牆面疊圖；其他照主圖的屬性（Rules.recipeKind）。車庫門本工具
-- 不蓋（Entry.BUILDABLE 沒有），照門列；分不出種類的（集雨桶、鍛造爐這類）放家具
local function kindOf(spr, cover)
    if cover then return "wallOverlay" end
    local kind = spr and Rules.recipeKind(spr)
    if kind == "garage" then return "door" end
    return kind and Entry.BUILDABLE[kind] and kind or "furniture"
end

-- 一個配方 → 項目，或 nil（不列）。info＝它的圖塊設定（SpriteConfigManager.ObjectInfo），牆面油漆這類沒有
local function rowOf(L, cr, info, bySprite)
    local names, main, cover
    if info then
        names = info:getScript():getAllTileNames()
        main = names:size() > 0 and names:get(0) or nil
    else
        -- 沒有圖塊設定：牆面油漆、壁紙、灰泥開原版的油漆和壁紙游標（ISBuildPanel.lua:341-350）；都不是的原版視窗也開不了
        L:setRecipe(cr)
        cover = L:getWallCoveringParams() ~= nil
        if not cover then return nil end
    end
    local spr = main and Entry.sprite(main)
    if spr and Rules.classify(spr) then return nil end -- 本工具目錄已經列了這張圖：配方的地板照舊只列圖塊
    local src = cr:getModID()
    src = (src == nil or src == "pz-vanilla") and "vanilla" or src
    local name, cat = cr:getTranslationName() or cr:getName(), cr:getCategory()
    local ts = main and main:match("^(.*)_%d+$") or nil
    -- tileset、圖塊組照主圖（整套、分類用；圖塊組同 Index.addSetKey 的算法）
    local r = { id = Recipes.PREFIX .. cr:getScriptObjectFullType(), recipe = cr, info = info, cover = cover == true,
        sprite = main, tileset = ts, family = ts and (ts:match("^(.-)_%d+$") or ts) or nil, kind = kindOf(spr, cover),
        category = cat, source = src, name = name, learn = cr:needToBeLearn(), onAdd = cr:getOnAddToMenu() }
    -- 搜尋鍵（小寫）：顯示名｜原名｜原版分類｜來源
    r.key = string.lower(name .. "|" .. cr:getName() .. "|" .. Recipes.categoryLabel(cat) .. "|" .. sourceName(src))
    for j = 0, names and names:size() - 1 or -1 do bySprite[names:get(j)] = r end
    return r
end

-- 掃一次全部建造配方。player 只給 BuildLogic 建構子用（讀它的 modData）
function Recipes.scan(player)
    Rules.ensure()
    local L = newLogic(player)
    -- 配方 → 圖塊設定：照原版視窗取的同一個元件（ObjectInfo.getRecipe 和 getAllBuildableRecipes 都取第一個 CraftRecipe 元件）
    local infos, infoOf = SpriteConfigManager.GetObjectInfoList(), {}
    for i = 0, infos:size() - 1 do
        local info = infos:get(i)
        local c = info:getRecipe()
        local cr = c and c:getCraftRecipe()
        if cr then infoOf[cr] = info end
    end
    local list, byId, bySprite = { n = 0 }, {}, {}
    local all = L:getAllBuildableRecipes()
    for i = 0, all:size() - 1 do
        local cr = all:get(i)
        -- 哪個 MOD 的配方資料讓這裡丟錯就跳過那一個，不讓整份清單出不來
        local ok, r = pcall(rowOf, L, cr, infoOf[cr], bySprite)
        if not ok then
            print(LOG .. "recipe skipped: " .. tostring(r))
        elseif r and not byId[r.id] then
            list.n = list.n + 1
            list[list.n] = r
            byId[r.id] = r
        end
    end
    if Recipes.sorter then Recipes.sorter(list) end -- Window 給的合併排序（照 key，就是顯示名）
    Recipes.list, Recipes.byId, Recipes.bySprite = list, byId, bySprite
    Recipes.gen = Recipes.gen + 1
    print(LOG .. "recipes: " .. list.n .. " listed of " .. all:size() .. " buildable")
end

-- 全部配方項目；還沒掃就先掃（要有玩家：分割畫面時第一個在的）
function Recipes.all()
    if not Recipes.list then
        for pn = 0, 3 do
            local player = getSpecificPlayer(pn)
            if player then
                Recipes.scan(player)
                return Recipes.list
            end
        end
        return { n = 0 }
    end
    return Recipes.list
end

-- 配方項目；不是 recipe: 開頭的（圖塊項目）回 nil、不觸發掃描
function Recipes.get(id)
    if type(id) ~= "string" or id:find(Recipes.PREFIX, 1, true) ~= 1 then return nil end
    Recipes.all()
    return Recipes.byId[id]
end

-- 這位玩家看得到：同原版建造視窗（沒學過的、OnAddToMenu 回 false 的不列；技能等級分階的牆、地板就靠它），再套種類開關
local function visible(player, r, s)
    local cr = r.recipe
    if r.learn and not CraftRecipeManager.hasPlayerLearnedRecipe(cr, player) then return false end
    if r.onAdd and not callLuaBool(r.onAdd, { player = player, recipe = cr }) then return false end
    return Entry.kindOn(r.kind, s)
end

local EMPTY = { list = { n = 0 }, set = {}, sig = "" }
local shownBy = {} -- playerNum → { player, digest, gen, list, set, sig }

local function compute(player)
    local all, s = Recipes.all(), Entry.settings()
    local list, set, h, v = { n = 0 }, {}, 0, 0
    for i = 1, all.n do
        local r = all[i]
        local ok, yes = pcall(visible, player, r, s)
        if ok and yes then
            list.n = list.n + 1
            list[list.n] = r
            set[r.id] = r
            h = (h * 31 + i) % 2147483647
            -- 技能與學過夠不夠：升級、學會時會變，Recipes.refresh 比它決定要不要清原版的快取
            local okV, valid = pcall(CraftRecipeManager.isValidRecipeForCharacter, r.recipe, player, nil, nil)
            if okV and valid then v = (v * 31 + i) % 2147483647 end
        end
    end
    return { player = player, digest = Entry.digest(), gen = Recipes.gen, list = list, set = set, sig = list.n .. ":" .. h,
        valid = v }
end

-- 這位玩家看得到的配方項目：{ list = { n, 項目… }（照 Recipes.list 的順序）, set（ID → 項目）, sig（清單有沒有變） }。
-- 沙盒、玩家或掃描換了才重算；學會新配方、升級換階由 Recipes.refresh 每秒重算
function Recipes.shown(pn)
    local player = getSpecificPlayer(pn)
    if not player then return EMPTY end
    local c = shownBy[pn]
    if not c or c.player ~= player or c.gen ~= Recipes.gen or c.digest ~= Entry.digest() then
        c = compute(player)
        shownBy[pn] = c
    end
    return c
end

-- 這張圖屬於這位玩家看得到的配方：回那個項目
function Recipes.forSprite(pn, name)
    Recipes.all()
    local r = Recipes.bySprite[name]
    return r and Recipes.shown(pn).set[r.id] or nil
end

-- ===== 能不能蓋與詳情（視窗用）=====

-- 視窗用的 BuildLogic（每位玩家一個；不交給游標：詳情換配方時會 setRecipe，交給游標就會蓋錯）
local probes = {} -- playerNum → { player, L }
local function probeOf(pn, player)
    local p = probes[pn]
    if not p or p.player ~= player then
        p = { player = player, L = newLogic(player) }
        probes[pn] = p
        local c = containersOf(player)
        if c then p.L:setContainers(c) end
    end
    return p.L
end

-- 視窗每秒呼叫：換容器、重算看得到的清單。容器裡的東西變了，原版只留還選著、還在的那幾件（BaseCraftingLogic.java:
-- 587-624），新拿到的要 autoPopulateInputs 才填進去（同 sync；不然詳情選著同一個配方時「有」的數量停在舊的）。
-- 原版快取的 canPerform 也先查技能、學過與太暗（CraftRecipeData.canPerform），快取卻只在容器變了才重算：看得到的配方裡有哪個
-- 「技能、學過夠不夠」變了（升級、學會），或太暗與否變了（開燈、拿起手電筒），就 setRecipes 清快取（:574-578；probe 的
-- 完整清單本來就空，只清快取），也回有變，視窗才會清掉方格的缺料標示（W.pump）。回 缺料要不要重算, 清單的 sig
function Recipes.refresh(pn)
    local player = getSpecificPlayer(pn)
    if not player then return false, "" end
    local c = containersOf(player)
    local L = probeOf(pn, player)
    local changed = c ~= nil and L:setContainers(c) == true
    if changed then L:autoPopulateInputs() end
    local s = compute(player)
    shownBy[pn] = s
    local p = probes[pn]
    local key = s.valid .. (player:tooDarkToRead() and "d" or "")
    if p.valid ~= key then
        if p.valid ~= nil then L:setRecipes(ArrayList.new()) end
        p.valid, changed = key, true
    end
    return changed, s.sig
end

-- 能不能蓋，同原版建造視窗的清單（ISRecipeScrollingListBox.lua:38-49）：回 技能與學過夠不夠, 材料與工具夠不夠。
-- 建造作弊照原版只認 isBuildCheat。第二個值讀原版的快取：容器變了、或 Recipes.refresh 看到技能、學過或太暗變了才重算
function Recipes.state(pn, r)
    local player = getSpecificPlayer(pn)
    if not player then return false, false end
    if player:isBuildCheat() then return true, true end
    local valid = CraftRecipeManager.isValidRecipeForCharacter(r.recipe, player, nil, nil)
    local info = probeOf(pn, player):getCachedRecipeInfo(r.recipe) -- 原版的物件池：當下讀完，不留著
    return valid, info:isCanPerform()
end

-- 學會了沒：不看沙盒「檢視未知配方」（它只管列不列；isValidRecipeForCharacter 也不看），同原版合成視窗標「沒學會」的判斷
-- （isRecipeKnown(recipe, true)，IsoGameCharacter.java:11858-11865）。沒學會的配方開著那個選項時照列，方格標缺、詳情寫原因
function Recipes.learned(pn, r)
    local player = getSpecificPlayer(pn)
    return not r.learn or player == nil or player:isRecipeKnown(r.recipe, true)
end

-- 太暗做不了：原版 canPerform 在太暗、配方又沒有 CanBeDoneInDark 標籤時不給做（CraftRecipeData.java:753-754；原版建造
-- 配方只有營火有），原版視窗的標題列寫「太暗」（ISWidgetTitleHeader.lua:196-199）。手上或身上有亮著的燈就不算暗
function Recipes.dark(pn, r)
    local player = getSpecificPlayer(pn)
    return player ~= nil and not r.recipe:canBeDoneInDark() and player:tooDarkToRead()
end

-- 詳情要畫的材料、工具（用完還在的）、技能。和原版建造視窗的材料欄同一套（ISWidgetInput.lua:177-207,483-545）：夠不夠照
-- isInputSatisfied、數量照 getInputCount／getIntAmount、名稱照已經找到的那件，沒有就照能用的第一種。只列物品：原版建造配方
-- 沒有液體、能量的輸入。回 { items = { 列… }, tools = { 列… }, skills = { 列… }, learned（Recipes.learned）, dark（Recipes.dark） }
function Recipes.needs(pn, r)
    local player = getSpecificPlayer(pn)
    local out = { items = {}, tools = {}, skills = {}, learned = true, dark = false }
    if not player then return out end
    local L, cr = probeOf(pn, player), r.recipe
    if L:getRecipe() ~= cr then L:setRecipe(cr) end
    local cheat = player:isBuildCheat()
    out.learned = cheat or Recipes.learned(pn, r)
    out.dark = not cheat and Recipes.dark(pn, r)
    local inputs = cr:getInputs()
    for i = 0, inputs:size() - 1 do
        local inp = inputs:get(i)
        if inp:getResourceType() == ResourceType.Item then
            local items = L:getSatisfiedInputItems(inp)
            if items:size() == 0 then items = inp:getPossibleInputItems() end
            local it = items:size() > 0 and items:get(0) or nil
            local into = inp:isKeep() and out.tools or out.items
            into[#into + 1] = { name = it and it:getDisplayName() or "?", tex = it and it:getNormalTexture() or nil,
                need = inp:getIntAmount(), have = L:getInputCount(inp), ok = cheat or L:isInputSatisfied(inp) }
        end
    end
    for i = 0, cr:getRequiredSkillCount() - 1 do
        local rs = cr:getRequiredSkill(i)
        local have = player:getPerkLevel(rs:getPerk())
        out.skills[#out.skills + 1] = { name = PerkFactory.getPerkName(rs:getPerk()), level = rs:getLevel(), have = have,
            ok = cheat or have >= rs:getLevel() }
    end
    return out
end

-- 縮圖：原版建造視窗同一張（CraftRecipe:getIconTexture，ISRecipeScrollingListBox.lua:196），沒有就用主圖
function Recipes.icon(r)
    local t = r.recipe:getIconTexture()
    if t == nil and r.sprite then
        t = getTexture(r.sprite)
        if t then t = t:splitIcon() end
    end
    return t
end

-- 佔地（寬, 深）與朝向數：第一個有的朝向（面 0..3＝北、西、南、東，SpriteConfigManager.java:50-63）；沒有圖塊設定的 1×1
function Recipes.size(r)
    local info, w, h, faces = r.info, 1, 1, 0
    for f = 0, 3 do
        local face = info and info:getFace(f)
        if face then
            if faces == 0 then w, h = face:getWidth(), face:getHeight() end
            faces = faces + 1
        end
    end
    return w, h, math.max(1, faces)
end

-- ===== 建造：開原版的游標 =====

local live = {} -- { { pn, cursor, L, player, sq, at }, … }：游標還在，或放完動作還在跑，或拖的一排還沒蓋完

-- 擋不擋放：同原版視窗建游標時（ISBuildPanel.lua:329-336）：材料、工具、技能或學過不夠、太暗，或動作還在跑。
-- row＝能拖一排的游標：動作在跑也不擋，再放一次取代還沒蓋的（同圖塊項目；Recipes.build）
local function blocked(L, player, row)
    return (not row and L:isCraftActionInProgress()) or not (L:canPerformCurrentRecipe() or player:isBuildCheat())
end

-- 換容器：東西有變時同原版視窗重填材料（ISBuildPanel.lua:214-221；setContainers 只留還在的那幾件，
-- BaseCraftingLogic.java:587-624）。o＝游標還在時重算擋不擋（原版 onUpdateContainers → createBuildIsoEntity，
-- ISBuildPanel.lua:301-308）
local function sync(o, L, player)
    local c = containersOf(player)
    if c and L:setContainers(c) then L:autoPopulateInputs() end
    if o then o.blockBuild = blocked(L, player, o.mbldRow) end
end

-- 走過去的路上換容器：單機的 create 照 logic 記的容器扣料，離起點旁的箱子超過 2.5 格就整個扣料失敗、什麼都不蓋
-- （BaseCraftingLogic.java:767-790）。原版視窗同法，玩家換格子就換（ISBuildPanel.lua:185-221）；站著不動時每秒一次，
-- 接得到拿起、放下的東西（原版靠背包頁 refreshBackpacks 標 drawDirty，ISInventoryPage.lua:1537-1539）。
-- 游標不在、動作也不在跑、也沒有拖的一排要接著蓋就不追（isPlayerDoingAction 是保險：走不到、佇列清掉時原版也會經
-- onActionComplete 清掉進行中，ISBuildingObject.lua:285-290、ISBuildAction.lua:192-197）
local advance -- 拖一排的下一格（下面「拖一排」那段）
local rows = {} -- playerNum → 拖的一排還沒蓋完的：{ cursor, r, cells, i, placed, parts, action, doneAt, ok, checked }
local function follow()
    local keep, t = {}, getTimestampMs()
    for _, a in ipairs(live) do
        local held = getCell():getDrag(a.pn) == a.cursor
        local row = rows[a.pn]
        local mine = row ~= nil and row.cursor == a.cursor
        -- 那個座位換了角色（死了重生、分割畫面換人）或角色死了：不再追，它拖的一排放掉，不替舊角色再送動作
        -- （死者 isPlayerDoingAction 回 false，ISTimedActionQueue.lua:269-275，不擋的話會被當成佇列空了）
        if getSpecificPlayer(a.pn) ~= a.player or a.player:isDead() then
            if mine then rows[a.pn] = nil end
        elseif held or mine or (a.L:isCraftActionInProgress() and ISTimedActionQueue.isPlayerDoingAction(a.player)) then
            keep[#keep + 1] = a
            local sq = a.player:getCurrentSquare()
            if (sq and sq ~= a.sq) or t < a.at or t - a.at >= 1000 then
                a.sq, a.at = sq or a.sq, t
                sync(held and a.cursor or nil, a.L, a.player)
            end
            if mine then advance(a.pn, row, t) end
        end
    end
    live = keep
    if #keep == 0 then Events.OnTick.Remove(follow) end
end

-- 動作跑完（蓋好、被打斷、被伺服器拒絕：ISBuildingObject.lua:291-303 → BuildLogic.stopCraftAction）：換容器、用掉的
-- 材料換成還在的、重算擋不擋，同原版視窗重建游標（ISBuildPanel.lua:310-336,414-422）。o＝游標（addEventListener 的 target）。
-- 游標關了但它拖的一排還在蓋時照做：下一格要照用掉以後的材料判斷（refresh 會 autoPopulateInputs，BaseCraftingLogic.java:630-645）
local function onStopCraft(o)
    local row = rows[o.player]
    if getCell():getDrag(o.player) ~= o and not (row and row.cursor == o) then return end
    local L, player = o.buildPanelLogic, o.character
    local c = containersOf(player)
    if c and L:setContainers(c) then L:autoPopulateInputs() end
    L:refresh()
    o.blockBuild = blocked(L, player, o.mbldRow)
end

-- 動作開始前要拿在手上的工具，同原版視窗（ISBuildPanel.lua:223-244,323-326）：背包裡第一件能用的完整類型，沒有回 nil
local function toolOf(input, inv)
    if not input then return nil end
    local types = input:getPossibleInputItems()
    for i = 0, types:size() - 1 do
        local found = inv:getAllTypeEvalRecurse(types:get(i):getFullName(), ISBuildIsoEntity.predicateMaterial)
        if found:size() > 0 then return found:get(0):getFullType() end
    end
    return nil
end

-- 引擎換掉或清掉游標時呼叫：IsoCell.setDrag 用 rawget 拿游標身上的 deactivate（IsoCell.java:2558-2567）。只放在本 MOD
-- 開的這個游標上，不改原版類別
local function deactivate(self)
    Recipes.hideHint(self.player)
    if self.replaced or not Recipes.onEnd then return end
    local ok, err = pcall(Recipes.onEnd, self.player)
    if not ok then print(LOG .. "onEnd failed: " .. tostring(err)) end
end

-- 這位玩家目前的配方游標（本 MOD 開的；別的 MOD 或原版視窗開的回 nil）
function Recipes.cursor(pn)
    local d = getCell():getDrag(pn)
    if d and d.mbldRecipe then return d end
    return nil
end

-- 手把 A（42.22.2）：原版 DoTileBuilding 對手把玩家不讀建造鍵（ISBuildingObject.lua:114-126），A 只送到拖曳物件的
-- onJoypadPressButton（JoyPadSetup.lua:363-366）；ISBuildIsoEntity 沒有自己的，ISPaintCursor／ISPaperCursor 把 A 交回
-- 不處理 A 的基底（:627-653），所以原版建造選單用手把也蓋不下去。照本工具的游標處理（Cursor.padBuild：照手把那格重算
-- 再設建造旗標，下一幀 DoTileBuilding 呼叫 tryBuild）；只掛在本 MOD 開的實例上（同 deactivate，不改原版類別），其他鍵
-- 照該類別原本的處理
local function joypadPress(self, joypadIndex, joypadData, button)
    if button ~= Joypad.AButton then return self.mbldPress(self, joypadIndex, joypadData, button) end
    -- 油漆、壁紙游標選的是格上第幾個物件（objectIndex），只在 render 換格時設回 1（ISPaintCursor.lua:101-104、
    -- ISPaperCursor.lua:94-97）；A 比 render 早，換了格先照它設回去，不然拿上一格的第幾個去新格找物件
    local sq = self.objectIndex and self.xJoypad and self.zJoypad
        and getCell():getGridSquare(self.xJoypad, self.yJoypad, self.zJoypad)
    if sq and sq ~= self.currentSquare then self.objectIndex, self.currentSquare = 1, sq end
    return MinidoracatBuilder.Cursor.padBuild(self)
end

-- ===== 取代前一排的提示（使用者 2026-10-29：排隊中再拖一排照舊取代前一排，放開前提示會取消前一排剩下的 N 格；ui.md 裁定）=====
-- 原版游標沒有本工具的標籤框，配方游標另外在滑鼠右下（手把：游標那格）畫一行同一句（IGUI_MBLD_Replace）。框只顯示、
-- 不收滑鼠（同 Cursor 的標籤框），放在滑鼠右下 (32, 10)，不會蓋在滑鼠底下（Cursor.mouseOverUI 才不會把它當成介面）
local hints, HintPanel, hintColors = {}, nil, nil
local function noClick() return false end

local function hintRender(self)
    local o = getCell():getDrag(self.pn)
    local text = o and o.mbldRecipe and o.mbldHint
    if not text then return self:setVisible(false) end
    local mx, my
    if JoypadState.players[self.pn + 1] then
        if not (o.xJoypad and o.zJoypad) then return end
        mx, my = isoToScreenX(self.pn, o.xJoypad, o.yJoypad, o.zJoypad), isoToScreenY(self.pn, o.xJoypad, o.yJoypad, o.zJoypad)
    else
        mx, my = getMouseX(), getMouseY()
    end
    local tm, font = getTextManager(), UIFont.Small
    local w, h = tm:MeasureStringX(font, text) + 12, tm:getFontHeight(font) + 8
    local x, y = mx + 32, my + 10
    if x + w > getPlayerScreenLeft(self.pn) + getPlayerScreenWidth(self.pn) then x = mx - 16 - w end
    if y + h > getPlayerScreenTop(self.pn) + getPlayerScreenHeight(self.pn) then y = my - 10 - h end
    self:setX(x)
    self:setY(y)
    self:setWidth(w)
    self:setHeight(h)
    local UI, c = MinidoracatUI.v1, hintColors
    UI.Skin.fill(self, 0, 0, w, h, c.surface, nil, 1)
    UI.Skin.border(self, 0, 0, w, h, c.border, nil, 1)
    self:drawText(text, 6, 4, c.warning.r, c.warning.g, c.warning.b, 1, font)
end

local function hintPanel(pn)
    local h = hints[pn]
    if h then return h end
    if not HintPanel then
        HintPanel = ISUIElement:derive("MinidoracatBuilderRecipeHint")
        HintPanel.render, HintPanel.onRightMouseDown, HintPanel.onRightMouseUp = hintRender, noClick, noClick
        hintColors = MinidoracatUI.v1.Theme.create({ variant = "dark" }).colors -- 同 Cursor 的標籤框（框架深色色票）
    end
    h = HintPanel:new(0, 0, 1, 1)
    h.wantMouseEvents, h.pn = false, pn
    h:initialise()
    h:addToUIManager()
    h:setVisible(false)
    hints[pn] = h
    return h
end

local function hideHint(pn)
    local h = hints[pn]
    if h and h:getIsVisible() then h:setVisible(false) end
end
Recipes.hideHint = hideHint -- 游標的 deactivate 用（它寫在這段前面）

-- 每幀（游標的 render 之後）：放下去會取消幾格。能拖的游標放下會清佇列（startRow）：拖的一排還沒蓋的、圖塊項目排隊中的
-- 都算；不能拖的照原版排在後面，只取消拖的一排還沒送的。字只在格數變了才換
local function updateHint(o)
    local pn = o.player
    local n = 0
    if o.canBeBuild and not o.blockBuild then
        local C = MinidoracatBuilder.Cursor
        n = o.mbldRow and C and C.cancels(o.character) or Recipes.left(pn, false)
    end
    if n ~= o.mbldHintN then
        o.mbldHintN = n
        o.mbldHint = n > 0 and getText(n == 1 and "IGUI_MBLD_ReplaceOne" or "IGUI_MBLD_Replace", tostring(n)) or nil
    end
    if o.mbldHint then
        local h = hintPanel(pn)
        if not h:getIsVisible() then h:setVisible(true) end
    else
        hideHint(pn)
    end
end

-- 不能拖的配方游標：原版的畫法，再更新提示
local function singleRender(self, x, y, z, square)
    ISBuildIsoEntity.render(self, x, y, z, square)
    updateHint(self)
end

-- ===== 拖一排（使用者 2026-11-12：配方項目也能拖一排；先在 9950X3D 實測，單機與專用伺服器都可行）=====
-- 圖塊同種類能拖的（Cursor.DRAG）而且每一面都只佔一格的配方，游標實例換上 rotateMouse、render、tryBuild 與
-- onActionComplete（只掛在本 MOD 開的實例上，不改原版類別）：按住拖記下拉到哪裡，整排照 Cursor.anchors 排（一排、
-- 長方形、每排上限、沒有那一面都同圖塊項目），每格照原版 isValid 與材料夠做幾次（getPossibleCraftCount）畫白或紅；
-- 放開後一格接一格送原版 tryBuild，每一格都是完整的原版建造動作（材料、技能、工具與伺服器驗證照原版，本 MOD 不送指令）。
-- 原版每格動作結束（蓋好、打斷、走路途中取消、被伺服器拒絕）都呼叫同一支收尾（setOnComplete／setOnCancel 那一刻游標上的
-- onActionComplete，ISBuildingObject.lua:207-208、ISBuildAction.lua:156-241），收尾不帶參數；送每格前把游標的 onActionComplete
-- 換成記著「哪一排第幾格」的那一支，別的動作晚到的收尾就對不上這一格。蓋好沒照動作本身的結果判斷：單機在 perform 裡收尾，
-- 那時 Java 動作 finished() 為真（時間到了，BaseAction.java:174-176）；多人的客戶端只在伺服器回報完成時 forceComplete
-- （ISBuildAction.lua:116-121,176-182；waitForFinished，不會自己 perform），isForceComplete() 為真；打斷、走不到、被拒兩者都是假。
-- 那格出現那一面的圖只當輔助（物件封包晚到不影響判斷）。蓋好就等那格的動作退出佇列（多人那一刻它還在佇列裡）、
-- 佇列空了、換容器重填材料、還做得了才送下一格，沒蓋好就整排停下。
-- 每格的建造動作照 onStartCraft 記下（原版 tryBuild 先 startCraftAction(buildAction) 再排進佇列，ISBuildingObject.lua:205-209,266；
-- 成功也不回傳值），用 ISTimedActionQueue.hasAction 追：原版拒收（拖屍體、睡著，ISTimedActionQueue.lua:157-169）不回呼、
-- 佇列被重設也不回呼，看到它不在佇列又沒收尾就停下。那格做完後佇列裡有別的動作（玩家插了吃東西這類），照被打斷停下，
-- 不等它跑完或被取消再接著蓋。
-- 一排的狀態放在 rows／views，不放在游標上：原版 tryBuild 用 copyTable 深拷游標交給動作（ISBuildingObject.lua:200），
-- 深拷不防循環，也會整份跟著送。手把不拖（同圖塊項目，使用者 10-29 裁定）。
local views = {} -- playerNum → 拖曳中的預覽：{ cursor, ax, ay, az, ex, ey, d, at, list, ok }
-- nSprite（1..4＝西、北、東、南，ISBuildingObject.lua:486-516）→ 圖塊設定的面（0..3＝北、西、南、東，ISBuildIsoEntity.lua:784-818）
local FACE_OF = { 1, 0, 3, 2 }

-- 那一面左上那格的圖名（只拖每面一格的配方）
local function tileOf(info, d)
    local face = info:getFace(FACE_OF[d])
    local t = face and face:getTileInfo(0, 0, 0)
    return t and t:getSpriteName()
end

-- 這個配方怎麼拖（Cursor.DRAG 的 fill／ring／edge），不能拖回 nil：種類不在 DRAG，或有一面不只一格（多格的那幾格要一起
-- 驗、一起蓋，一格一格接著送會互相擋）
function Recipes.dragMode(r)
    local mode = r.info and MinidoracatBuilder.Cursor.DRAG[r.kind]
    if not mode then return nil end
    for i = 0, 3 do
        local f = r.info:getFace(i)
        if f and (f:getWidth() ~= 1 or f:getHeight() ~= 1) then return nil end
    end
    return mode
end

-- 換到第 d 面：getSprite 設 north／west（isValidPerSquare 看它），getFace 換面、補 spriteCache
local function face(o, d)
    o.nSprite = d
    o:getSprite()
    o:getFace()
end

-- 拖曳中的整排：照 Cursor.anchors 排，每格換到自己的面跑原版 isValid；可蓋的照順序扣做得了的次數，扣完的畫紅。
-- 按下那格、拉到哪格、朝向沒變時半秒重算一次（材料、別人蓋了東西）
local function preview(o, ax, ay, az, ex, ey)
    local v, t = views[o.player], getTimestampMs()
    if v and v.cursor == o and v.ax == ax and v.ay == ay and v.az == az and v.ex == ex and v.ey == ey and v.d == o.nSprite
        and t >= v.at and t - v.at < 500 then
        return v
    end
    local d = o.nSprite
    local list = MinidoracatBuilder.Cursor.anchors({ canDrag = true, entry = { kind = o.mbldKind }, sides = o.mbldSides,
        d = d, max = o.mbldMax }, ax, ay, az, ex, ey)
    local left = o.character:isBuildCheat() and math.huge or o.buildPanelLogic:getPossibleCraftCount(false)
    local ok = 0
    for _, a in ipairs(list) do
        if a[4] then
            face(o, a[4])
            a.spr = tileOf(o.objectInfo, a[4])
            if not a.code and left > 0 then
                o:ensureSquaresExist(a[1], a[2], a[3])
                local sq = getCell():getGridSquare(a[1], a[2], a[3])
                a.ok = sq ~= nil and o:isValid(sq)
                if a.ok then ok, left = ok + 1, left - 1 end
            end
        end
    end
    face(o, d)
    v = { cursor = o, ax = ax, ay = ay, az = az, ex = ex, ey = ey, d = d, at = t, list = list, ok = ok }
    views[o.player] = v
    return v
end

-- 按住左鍵時每幀呼叫（ISBuildingObject.lua:119），x, y 是滑鼠那格：記下拉到哪裡，不照原版往拖的方向轉
local function rowMouse(self, x, y)
    if self.square then self.lineX, self.lineY = x, y end
end

-- 沒在拖照原版畫一格；拖曳中畫整排（顏色同原版：ISBuildIsoEntity.lua:46-68,109-111），至少一格可蓋就算可蓋
-- （DoTileBuilding 在 render 之後才看 canBeBuild，ISBuildingObject.lua:148-174）
local function rowRender(self, x, y, z, square)
    local held = self.isLeftDown or self.build
    if not held then self.lineX, self.lineY = nil, nil end
    if not (held and self.lineX and (self.lineX ~= x or self.lineY ~= y)) then
        ISBuildIsoEntity.render(self, x, y, z, square)
        return updateHint(self)
    end
    local v = preview(self, x, y, z, self.lineX, self.lineY)
    local good, bad, floor = getCore():getGoodHighlitedColor(), getCore():getBadHighlitedColor(), self.tileSprite
    for _, a in ipairs(v.list) do
        local spr, c = a.spr and self.spriteCache[a.spr], a.ok and good or bad
        if spr and a.ok then
            spr:RenderGhostTileColor(a[1], a[2], a[3], 0, 0, 1, 1, 1, 0.6)
        elseif spr then
            spr:RenderGhostTileColor(a[1], a[2], a[3], 0, 0, 0.65, 0.2, 0.2, 0.6)
        end
        floor:RenderGhostTileColor(a[1], a[2], a[3], c:getR(), c:getG(), c:getB(), 0.8)
    end
    self.canBeBuild = v.ok > 0
    updateHint(self)
end

-- 那個 Java 動作是不是做完了（單機時間到 perform、多人伺服器回報完成）；還沒開始、拿不到都算沒有
local function performed(a)
    local j = a and a.action
    if not j then return false end
    local fine, done = pcall(function() return j:isForceComplete() or j:finished() end)
    return fine and done == true
end

-- 一格動作的收尾（原版先收尾再通知，ISBuildingObject.lua:291-303）：還是這一排的這一格才記下結果
local function cellDone(self, row, i)
    ISBuildingObject.onActionComplete(self)
    if rows[self.player] == row and row.i == i and not row.doneAt then
        row.doneAt, row.ok = getTimestampMs(), performed(row.action)
    end
end

-- 送第 i＋1 格：換到那格的面再交給原版 tryBuild（它深拷游標，那格的面跟著動作走），送完換回游標原本的面。
-- 走不到時原版當場呼叫 onActionComplete（ISBuildingObject.lua:283-285）。sending＝正在送的那一排，onStartCraft 把動作記到它身上
local sending
local function send(row)
    row.i, row.action, row.doneAt, row.ok, row.checked = row.i + 1, nil, nil, nil, nil
    local o, c, i = row.cursor, row.cells[row.i], row.i
    local d = o.nSprite
    face(o, c[4])
    o.onActionComplete = function(self) return cellDone(self, row, i) end
    sending = row
    ISBuildIsoEntity.tryBuild(o, c[1], c[2], c[3])
    sending = nil
    face(o, d)
end

-- 原版 tryBuild 開始一格時 BuildLogic 發的 onStartCraft（BuildLogic.java:214-228）：記下這格的建造動作
local function onStartCraft(o, action)
    if sending and sending.cursor == o then sending.action = action end
end

-- 這個請求（Client.pending／pendingUnbuild）是不是這個角色的：分割畫面時別的玩家的請求不能動（審查 1112 Codex）
local function ownedBy(req, player)
    return req ~= nil and req.player == player
end

-- 開始一排：每人只留一個請求（同 Client.build）：這個角色還沒輪完的圖塊建造、拆除請求作廢，清掉角色的動作佇列（正在蓋的
-- 那格當場收尾，實測），舊的一排換成這一排。cells＝{ { x, y, z, d, spr }, … }
local function startRow(o, cells)
    local pn, Client, player = o.player, MinidoracatBuilder.Client, o.character
    if ownedBy(Client.pending, player) then Client.pending = nil end
    if ownedBy(Client.pendingUnbuild, player) then Client.pendingUnbuild = nil end
    ISTimedActionQueue.clear(player)
    local parts = {}
    for i, c in ipairs(cells) do
        local spr = c.spr and o.spriteCache[c.spr]
        if spr then parts[i] = { { c[1], c[2], c[3], spr, 0 } } end
    end
    local row = { cursor = o, r = Recipes.byId[o.mbldR], cells = cells, i = 0, placed = 0, parts = parts }
    rows[pn] = row
    send(row)
end

-- 放開左鍵或手把 A，而且可蓋（ISBuildingObject.lua:171-174）：拖曳中送整排可蓋的格子，不然送按下那一格
local function rowBuild(self, x, y, z)
    local v, cells = views[self.player], {}
    if self.lineX and v and v.cursor == self and v.ax == x and v.ay == y and v.ex == self.lineX and v.ey == self.lineY then
        for _, a in ipairs(v.list) do
            if a.ok then cells[#cells + 1] = a end
        end
    else
        cells[1] = { x, y, z, self.nSprite, spr = tileOf(self.objectInfo, self.nSprite) }
    end
    self.lineX, self.lineY, views[self.player] = nil, nil, nil
    if cells[1] then startRow(self, cells) end
end

-- 不能拖的配方游標放下時：舊的一排剩下的格子不再接著送（它正在蓋的那格照原版跑完）
local function single(self, x, y, z)
    rows[self.player] = nil
    return ISBuildIsoEntity.tryBuild(self, x, y, z)
end

-- 那格有沒有這一面的圖（蓋好了）
local function builtAt(c)
    local sq = getCell():getGridSquare(c[1], c[2], c[3])
    local list = sq and sq:getObjects()
    for i = 0, (list and list:size() or 0) - 1 do
        local spr = list:get(i):getSprite()
        if spr and spr:getName() == c.spr then return true end
    end
    return false
end

-- 停下整排並說原因：沒料、沒工具、技能不夠或太暗（還沒送的格子）；被打斷、走不到、被拒、原版不收這個動作（那一格沒蓋好）。
-- 原因客戶端分不出來，照圖塊項目的說法（Cursor.tick）。原版不收動作時沒有收尾，這裡替它清掉進行中（同原版收尾，
-- ISBuildingObject.lua:291-295）
local function stop(pn, row, short)
    rows[pn] = nil
    local L = row.cursor.buildPanelLogic
    if not row.doneAt and L:isCraftActionInProgress() then L:stopCraftAction() end
    local player, n = row.cursor.character, #row.cells
    local title = row.placed > 0 and getText("IGUI_MBLD_Interrupted") or nil
    if short then
        Messages.toast(player, getText(Recipes.dark(pn, row.r) and "IGUI_MBLD_Recipe_TooDark" or "IGUI_MBLD_Recipe_Blocked"), title)
    elseif row.placed > 0 then
        Messages.toast(player, getText("IGUI_MBLD_Stopped", tostring(row.placed), tostring(n)), title)
    else
        Messages.toast(player, Messages.refusal("WALK"))
    end
end

-- 每 tick（follow）：那格動作結束後看蓋好沒，蓋好且還有下一格就等那格的動作退出佇列、佇列空了、換容器重填材料，
-- 做得了才送
advance = function(pn, row, t)
    local Client, o = MinidoracatBuilder.Client, row.cursor
    local player = o.character
    -- 這個角色的圖塊建造或拆除取代了這一排（它們清了佇列）；別的玩家的不算
    if ownedBy(Client.pending, player) or ownedBy(Client.pendingUnbuild, player) then
        rows[pn] = nil
        return
    end
    if not row.doneAt then
        -- 原版沒收這格的動作，或它離開佇列卻沒收尾：整排停下，不然一直等
        if not (row.action and ISTimedActionQueue.hasAction(row.action)) then return stop(pn, row, false) end
        return
    end
    if not row.checked then
        if not (row.ok or builtAt(row.cells[row.i])) then return stop(pn, row, false) end
        row.checked, row.placed, row.parts[row.i] = true, row.placed + 1, nil
    end
    if row.i >= #row.cells then
        rows[pn] = nil
        return
    end
    if ISTimedActionQueue.hasAction(row.action) then return end -- 那格的動作還沒退出佇列（MP 常晚一點）
    -- 那格做完後佇列裡有別的動作：玩家自己插了事情做，照被打斷停下（不等它跑完或被取消後再接著蓋）
    if #ISTimedActionQueue.getTimedActionQueue(player).queue > 0 then return stop(pn, row, false) end
    local L = o.buildPanelLogic
    if ISTimedActionQueue.isPlayerDoingAction(player) then return end
    sync(nil, L, player)
    if blocked(L, player, true) then return stop(pn, row, true) end
    send(row)
end

local function drawRows()
    for _, row in pairs(rows) do MinidoracatBuilder.Cursor.drawParts(row.parts) end
end
Events.OnPostRender.Add(drawRows)

-- 這位玩家拖的一排還沒蓋完的：{ cells, i, placed, parts, … }，沒有回 nil（E2E 讀，同 Cursor.queued）
function Recipes.row(pn)
    return rows[pn]
end

-- 這位玩家拖的那一排會被取消幾格：all＝清佇列的請求（再拖一排、圖塊建造、拆除；正在蓋的那格也停），否則只算還沒送的
-- （不能拖的配方游標放下時，正在蓋的那格照原版跑完）
function Recipes.left(pn, all)
    local row = rows[pn]
    if not row then return 0 end
    return #row.cells - (all and row.placed or row.i)
end


-- 開原版的游標，同原版建造視窗（ISBuildPanel.lua:310-356）：帶自己的 BuildLogic，材料、工具、技能或學過不夠時游標擋住
-- （客戶端的游標本身只擋地形；伺服器 create 再驗一次、不夠就不蓋，ISBuildIsoEntity.lua:543-563）；放完游標留著。
-- 不能拖的照原版動作跑完才再放得下；能拖一排的（Recipes.dragMode）再放一次取代還沒蓋的（同圖塊項目）。
-- 牆面油漆、壁紙、灰泥開原版的油漆和壁紙游標。回游標，或 nil（沒開）
function Recipes.build(pn, id)
    local player = getSpecificPlayer(pn)
    local r = player and Recipes.get(id)
    if not r then return nil end
    local L = newLogic(player)
    local containers = containersOf(player) or ArrayList.new()
    L:setContainers(containers)
    L:setRecipe(r.recipe)
    local o
    if r.info then
        o = ISBuildIsoEntity:new(player, r.info, 1, containers, L)
        local mode = not JoypadState.players[pn + 1] and Recipes.dragMode(r)
        o.dragNilAfterPlace, o.blockAfterPlace = false, not mode
        local inv, cr = player:getInventory(), r.recipe
        o.equipBothHandItem = toolOf(cr:getToolBoth(), inv)
        o.firstItem = toolOf(cr:getToolRight(), inv)
        o.secondItem = toolOf(cr:getToolLeft(), inv)
        if mode then
            o.mbldRow, o.mbldKind, o.mbldR = true, r.kind, r.id
            o.mbldMax = math.max(1, math.floor(tonumber(Entry.settings().MaxCellsPerDrag) or 32))
            -- 圍一圈：北、南兩邊用北面（nSprite 2），西、東兩邊用西面（1）；沒有那一面的邊照圖塊項目標 NO_FACE
            o.mbldSides = { n = r.info:getFace(0) and 2 or nil, w = r.info:getFace(1) and 1 or nil }
            o.rotateMouse, o.render, o.tryBuild = rowMouse, rowRender, rowBuild
        else
            o.render, o.tryBuild = singleRender, single
        end
        o.blockBuild = blocked(L, player, o.mbldRow)
        L:addEventListener("onStopCraft", onStopCraft, o)
        if mode then L:addEventListener("onStartCraft", onStartCraft, o) end
        if #live == 0 then Events.OnTick.Add(follow) end
        live[#live + 1] = { pn = pn, cursor = o, L = L, player = player, sq = player:getCurrentSquare(), at = getTimestampMs() }
    else
        -- 牆面油漆、壁紙、灰泥：照原版視窗的建造鈕擋（ISWidgetBuildControl.lua:165-171），不夠就不開，發通知（審查 1109 Codex）；
        -- 太暗時原版也擋，通知寫太暗（審查 1109 第 2 輪 Claude）
        if blocked(L, player) then
            Messages.toast(player, getText(Recipes.dark(pn, r) and "IGUI_MBLD_Recipe_TooDark" or "IGUI_MBLD_Recipe_Blocked"))
            return nil
        end
        local p = L:getWallCoveringParams()
        if not p then return nil end
        if p.actionType == WallCoveringType.WALLPAPER then
            o = ISPaperCursor:new(player, p.wallpaperType, WallPaper["wall"][p.wallpaperType])
        else
            o = ISPaintCursor:new(player, p.actionType:toString(), p)
        end
    end
    o.mbldRecipe = true
    o.deactivate = deactivate
    o.mbldPress, o.onJoypadPressButton = o.onJoypadPressButton, joypadPress
    -- 換掉本工具的舊游標不算結束：W.build 剛把視窗收起
    local C = MinidoracatBuilder.Cursor
    local old = Recipes.cursor(pn) or (C and C.get and C.get(pn))
    if old then old.replaced = true end
    getCell():setDrag(o, pn)
    return o
end

return Recipes
