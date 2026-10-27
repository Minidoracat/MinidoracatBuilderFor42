-- 顯示名（規格 1.8）：視窗、游標、提示框共用。字串只在快取沒有時組，畫面每幀只讀結果。
--   1. 原版移動物件翻譯：「GroupName CustomName」先去掉 "."（Translator.getMoveableDisplayName 的 replace
--      不吃 regex，名稱有點就查不到；Translator.java:681-689，bt-catalog §4.1），用 getMoveableDisplayNameOrNull。
--   2. 沒有就組「種類名 · tileset 顯示名 · 編號」；tileset 顯示名先查 IGUI_MBLD_Family_<組>，沒有就把底線換空白。
--   3. 多格項目接「（n 格）」。4. 都不行就用 sprite 名稱。不顯示 Tooltip_ 鍵（BC 痛點 P1）。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Rules"

MinidoracatBuilder = MinidoracatBuilder or {}
local Names = MinidoracatBuilder.Names or {}
MinidoracatBuilder.Names = Names
local Entry, Rules = MinidoracatBuilder.Entry, MinidoracatBuilder.Rules

-- 最近 256 項（設計稿 DD:720-726）。ponytail：滿了整張清掉，不做 LRU；捲動時看得到的不到百格，清掉只多組一輪。
local MAX = 256
local cache, count = {}, 0

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

local function compose(name, kind)
    local spr = Entry.sprite(name)
    if not spr then return name end
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
        shown = getText("IGUI_MBLD_Name_Composed", Names.kind(kind), Names.tileset(ts), num)
    end
    if spr:getSpriteGrid() then
        local n = #Entry.cells(spr)
        if n > 1 then shown = getText("IGUI_MBLD_Name_Cells", shown, tostring(n)) end
    end
    return shown
end

-- name＝項目 ID（sprite 名稱）；kind 選填（呼叫端已經知道就傳，省一次分類）
function Names.of(name, kind)
    local s = cache[name]
    if s then return s end
    s = compose(name, kind)
    if count >= MAX then
        cache, count = {}, 0
    end
    cache[name] = s
    count = count + 1
    return s
end

-- 語言或沙盒設定換了時清掉（測試也用）
function Names.reset()
    cache, count = {}, 0
end

return Names
