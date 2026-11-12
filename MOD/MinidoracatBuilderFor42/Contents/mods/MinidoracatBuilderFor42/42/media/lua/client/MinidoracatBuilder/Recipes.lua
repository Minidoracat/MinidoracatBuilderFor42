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

local live = {} -- { { pn, cursor, L, player, sq, at }, … }：游標還在，或放完動作還在跑

-- 擋不擋放：同原版視窗建游標時（ISBuildPanel.lua:329-336）：材料、工具、技能或學過不夠、太暗，或動作還在跑
local function blocked(L, player)
    return L:isCraftActionInProgress() or not (L:canPerformCurrentRecipe() or player:isBuildCheat())
end

-- 換容器：東西有變時同原版視窗重填材料（ISBuildPanel.lua:214-221；setContainers 只留還在的那幾件，
-- BaseCraftingLogic.java:587-624）。o＝游標還在時重算擋不擋（原版 onUpdateContainers → createBuildIsoEntity，
-- ISBuildPanel.lua:301-308）
local function sync(o, L, player)
    local c = containersOf(player)
    if c and L:setContainers(c) then L:autoPopulateInputs() end
    if o then o.blockBuild = blocked(L, player) end
end

-- 走過去的路上換容器：單機的 create 照 logic 記的容器扣料，離起點旁的箱子超過 2.5 格就整個扣料失敗、什麼都不蓋
-- （BaseCraftingLogic.java:767-790）。原版視窗同法，玩家換格子就換（ISBuildPanel.lua:185-221）；站著不動時每秒一次，
-- 接得到拿起、放下的東西（原版靠背包頁 refreshBackpacks 標 drawDirty，ISInventoryPage.lua:1537-1539）。
-- 游標不在、動作也不在跑就不追（isPlayerDoingAction 是保險：走不到、佇列清掉時原版也會經 onActionComplete 清掉進行中，
-- ISBuildingObject.lua:285-290、ISBuildAction.lua:192-197）
local function follow()
    local keep, t = {}, getTimestampMs()
    for _, a in ipairs(live) do
        local held = getCell():getDrag(a.pn) == a.cursor
        if held or (a.L:isCraftActionInProgress() and ISTimedActionQueue.isPlayerDoingAction(a.player)) then
            keep[#keep + 1] = a
            local sq = a.player:getCurrentSquare()
            if (sq and sq ~= a.sq) or t < a.at or t - a.at >= 1000 then
                a.sq, a.at = sq or a.sq, t
                sync(held and a.cursor or nil, a.L, a.player)
            end
        end
    end
    live = keep
    if #keep == 0 then Events.OnTick.Remove(follow) end
end

-- 動作跑完（蓋好、被打斷、被伺服器拒絕：ISBuildingObject.lua:291-303 → BuildLogic.stopCraftAction）：換容器、用掉的
-- 材料換成還在的、重算擋不擋，同原版視窗重建游標（ISBuildPanel.lua:310-336,414-422）。o＝游標（addEventListener 的 target）
local function onStopCraft(o)
    if getCell():getDrag(o.player) ~= o then return end
    local L, player = o.buildPanelLogic, o.character
    local c = containersOf(player)
    if c and L:setContainers(c) then L:autoPopulateInputs() end
    L:refresh()
    o.blockBuild = blocked(L, player)
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

-- 圖塊的同種類能拖一排、配方項目不能的種類：提示與通知寫明（地板、屋頂的配方不在內：不讓它們把這一次通知用掉）
Recipes.NO_DRAG = { wall = true, fence = true, post = true }

-- 開原版的游標，同原版建造視窗（ISBuildPanel.lua:310-356）：帶自己的 BuildLogic，材料、工具、技能或學過不夠時游標擋住
-- （客戶端的游標本身只擋地形；伺服器 create 再驗一次、不夠就不蓋，ISBuildIsoEntity.lua:543-563）；放完游標留著，動作跑完
-- 才再放得下。牆面油漆、壁紙、灰泥開原版的油漆和壁紙游標。回游標，或 nil（沒開）
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
        o.dragNilAfterPlace, o.blockAfterPlace = false, true
        local inv, cr = player:getInventory(), r.recipe
        o.equipBothHandItem = toolOf(cr:getToolBoth(), inv)
        o.firstItem = toolOf(cr:getToolRight(), inv)
        o.secondItem = toolOf(cr:getToolLeft(), inv)
        o.blockBuild = blocked(L, player)
        L:addEventListener("onStopCraft", onStopCraft, o)
        if #live == 0 then Events.OnTick.Add(follow) end
        -- 牆、柵欄、柱子的配方不能拖一排（原版游標）：每次進遊戲第一次開這類游標時說一次，並指到能拖的圖塊項目
        if not Recipes.toldNoDrag and Recipes.NO_DRAG[r.kind] then
            Recipes.toldNoDrag = true
            Messages.toast(player, getText("IGUI_MBLD_Recipe_NoDragToast"), r.name)
        end
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
