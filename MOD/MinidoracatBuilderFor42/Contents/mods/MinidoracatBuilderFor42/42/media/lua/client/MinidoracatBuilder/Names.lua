-- 顯示名（規格 1.8）：視窗、游標、提示框共用。字串只在快取沒有時組，畫面每幀只讀結果。
--   1. 原版移動物件翻譯：「GroupName CustomName」先去掉 "."（Translator.getMoveableDisplayName 的 replace
--      不吃 regex，名稱有點就查不到；Translator.java:681-689，bt-catalog §4.1），用 getMoveableDisplayNameOrNull。
--   2. 沒有就組「種類名 · tileset 顯示名 · 編號」；tileset 顯示名先查 IGUI_MBLD_Family_<組>，沒有就把底線換空白。
--      方格用的短名（Names.short）不帶種類（頁籤已經寫了種類；使用者 2026-10-29），分兩段「tileset 顯示名」換行「編號」：
--      方格第一行放圖塊組、第二行放編號，各自截短，編號一定看得到（照字斷行時，窄格子會把編號截掉：builder-ui-1029c ui-door）。
--   3. 多格項目接「（n 格）」。4. 都不行就用 sprite 名稱。不顯示 Tooltip_ 鍵（BC 痛點 P1）。
--   建造配方項目（ID 是 recipe: 開頭，Recipes.lua）用原版的顯示名稱，方格也一樣。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Rules"
require "MinidoracatBuilder/Recipes"

MinidoracatBuilder = MinidoracatBuilder or {}
local Names = MinidoracatBuilder.Names or {}
MinidoracatBuilder.Names = Names
local Entry, Rules, Recipes = MinidoracatBuilder.Entry, MinidoracatBuilder.Rules, MinidoracatBuilder.Recipes

-- 最近 256 項（設計稿 DD:720-726），完整名與短名共用。ponytail：滿了整張清掉，不做 LRU；捲動時看得到的不到百格，清掉只多組一輪。
local MAX = 256
local cache, shortCache, count = {}, {}, 0

function Names.kind(kind)
    return getText("IGUI_MBLD_Kind_" .. tostring(kind))
end

-- 朝向名：0＝項目本身那一面，1..4＝北東南西（Entry.face 的 d）
function Names.face(d)
    return getText("IGUI_MBLD_Face_" .. tostring(d or 0))
end

-- 圖塊組（tileset 去掉結尾 _數字）的顯示名
function Names.family(fam)
    return getTextOrNull("IGUI_MBLD_Family_" .. fam) or (fam:gsub("_", " "))
end

-- tileset 顯示名：組有譯名時「譯名 01」，沒有就「walls exterior house 01」（DD:251）
function Names.tileset(ts)
    local fam, num = ts:match("^(.-)_(%d+)$")
    local shown = fam and getTextOrNull("IGUI_MBLD_Family_" .. fam)
    if shown then return shown .. " " .. num end
    return (ts:gsub("_", " "))
end

-- 原版電燈開關的 8 張圖：4 面牆 × 2 個位置，原版譯名都叫「電燈開關」，縮圖又小，分不出來（2026-11-14 群聊回報以為只有
-- 4 個方向）。名稱接「哪面牆、靠哪一頭」（IGUI_MBLD_Switch_<n>）；位置是從貼圖量的（Tiles2x.pack，格子 128×256：
-- _0 在北牆靠東、_4 靠西；_1 西牆靠南、_5 靠北；_2 東牆靠北、_7 靠南；_3 南牆靠西、_6 靠東），圖塊屬性裡沒有，所以照圖名寫
local SWITCH = {}
for i = 0, 7 do SWITCH["lighting_indoor_01_" .. i] = i end

-- 挖地下室的三個項目：ID 借用原版的圖名（引擎的隱形地板 invisible_01_0、地圖的地下土塊 underground_01_0／1，原版 tiledef
-- 帶 solid、cutW），原本的名稱不對，照用途叫（完整名與方格短名同一個；快取只照名稱記，所以不看 kind）
local DIG_NAME = { [Entry.DIG_S] = "IGUI_MBLD_Dig_EntranceS", [Entry.DIG_E] = "IGUI_MBLD_Dig_EntranceE",
    [Entry.DIG_CELL] = "IGUI_MBLD_Dig_Cell" }

local function compose(name, kind, short)
    if DIG_NAME[name] then return getText(DIG_NAME[name]) end
    local r = Recipes.get(name)
    if r then return r.name end
    local spr = Entry.sprite(name)
    if not spr then return name end
    -- 坡道的其他片（拆除選單、一區拆除列的是被點的那片）照那一組的頭片叫，和目錄同一個名稱。舊版照地板一片一片蓋的
    -- （kind＝"floor"）照自己的編號叫：每片各拆各的，同名的話選單上分不出是哪一片
    local head = Entry.rampHead(name)
    if head and head ~= name and kind ~= "floor" then return compose(head, "ramp", short) end
    local p = spr:getProperties()
    local custom, shown = p:get("CustomName"), nil
    if custom then
        local group = p:get("GroupName")
        local raw = group and (group .. " " .. custom) or custom
        shown = Translator.getMoveableDisplayNameOrNull((raw:gsub("%.", "")))
    end
    if not shown then
        kind = kind or Rules.classify(spr)
        local ts, num = name:match("^(.*)_(%d+)$")
        if not (kind and ts) then return name end
        if short then
            shown = Names.tileset(ts) .. "\n" .. getText("IGUI_MBLD_Name_Num", num)
        else
            shown = getText("IGUI_MBLD_Name_Composed", Names.kind(kind), Names.tileset(ts), num)
        end
    end
    local sw = SWITCH[name]
    if sw then shown = shown .. (short and "\n" or getText("IGUI_MBLD_Sep")) .. getText("IGUI_MBLD_Switch_" .. sw) end
    if spr:getSpriteGrid() then
        local n = #Entry.cells(spr)
        if n > 1 then shown = getText("IGUI_MBLD_Name_Cells", shown, tostring(n)) end
    end
    local t = spr:getType()
    if Rules.typeCode(t) == "stairs" then -- 樓梯沒有朝向可選，各組只有一個方向：名稱帶往哪邊爬
        shown = shown .. getText("IGUI_MBLD_Sep") .. Names.face(Rules.westStairs(t) and 4 or 1)
    end
    local ramp = Entry.rampSet(spr) -- 坡道各方向是不同的頭片：名稱帶往哪邊爬
    if ramp then shown = shown .. getText("IGUI_MBLD_Sep") .. Names.face(ramp.d) end
    return shown
end

local function lookup(short, name, ...)
    local kind = ...
    local key = kind == "floor" and Entry.rampHead(name) and name .. "|floor" or name -- 舊坡道片另記一筆（compose）
    local t = short and shortCache or cache
    local s = t[key]
    if s then return s end
    s = compose(name, kind, short)
    if count >= MAX then
        cache, shortCache, count = {}, {}, 0
        t = short and shortCache or cache
    end
    t[key] = s
    count = count + 1
    return s
end

-- name＝項目 ID（sprite 名稱，或建造配方的 recipe:…）；kind 選填（呼叫端已經知道就傳，省一次分類）
function Names.of(name, ...)
    local kind = ...
    return lookup(false, name, kind)
end

-- 方格用的短名：有原版翻譯時同 Names.of；沒有時「tileset 顯示名」換行「編號」，不帶種類
function Names.short(name)
    return lookup(true, name)
end

-- 語言或沙盒設定換了時清掉（測試也用）
function Names.reset()
    cache, shortCache, count = {}, {}, 0
end

return Names
