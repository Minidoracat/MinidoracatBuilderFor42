-- 目錄索引：整場遊戲留在記憶體，不存硬碟（bt-perf §4、§8）。
-- byKind[種類] = { n = 數量, 名稱1, 名稱2, … }：只存 sprite 名稱字串（Java 端同一個物件，不另佔空間），
-- 不存每項一張表（3.5 萬項：名稱陣列約 2 MB，每項一張表約 12 MB）。陣列自己記 n：Kahlua 的 #t 是二分搜尋。
MinidoracatBuilder = MinidoracatBuilder or {}
local Index = MinidoracatBuilder.Index or {}
MinidoracatBuilder.Index = Index

function Index.reset()
    Index.byKind = {}
    Index.sets = {}      -- tileset → 項目數
    Index.setFile = {}   -- tileset → tiledef 檔號（來源用 Sources 對到 MOD）
    Index.setName = { n = 0 } -- 出現過的 tileset，依第一次出現的順序
    Index.items = 0
    Index.groups = {}    -- 整理期間用：多面、多格家具的群組鍵 → { kind, slot, num, raw }；完成後丟掉
    Index.groupList = { n = 0 }
    -- 搜尋鍵（第二段）：nameKey[i] 對 nameItem[i]；setKey[i] 對 setName[i]
    Index.nameKey, Index.nameItem = { n = 0 }, { n = 0 }
    Index.setKey = { n = 0 }
end
Index.reset()

-- 加一個項目。key＝「tileset|GroupName|CustomName」（沒有 CustomName 時 nil＝自己一項）。
-- 同一群組（各面、各格）只留一項：取編號最小的那張當代表，兩端與每次整理都相同。
function Index.add(kind, name, tileset, num, file, key, raw)
    local g = key and Index.groups[key]
    if g then
        if num < g.num then
            Index.byKind[g.kind][g.slot] = name
            g.num = num
        end
        return
    end
    local arr = Index.byKind[kind]
    if not arr then
        arr = { n = 0 }
        Index.byKind[kind] = arr
    end
    arr.n = arr.n + 1
    arr[arr.n] = name
    Index.items = Index.items + 1
    local count = Index.sets[tileset]
    Index.sets[tileset] = (count or 0) + 1
    if not count then
        Index.setFile[tileset] = file
        local sn = Index.setName
        sn.n = sn.n + 1
        sn[sn.n] = tileset
    end
    if key then
        g = { kind = kind, slot = arr.n, num = num, raw = raw }
        Index.groups[key] = g
        local gl = Index.groupList
        gl.n = gl.n + 1
        gl[gl.n] = g
    end
end

-- 第二段：有名稱項目的搜尋鍵＝小寫「顯示名|原名」。顯示名用原版移動物件翻譯，
-- 先自己去掉 "."（Translator.getMoveableDisplayName 的 replace 不吃 regex，名稱有點就查不到；bt-catalog §4.1）
function Index.addNameKey(g)
    local shown = Translator.getMoveableDisplayNameOrNull((g.raw:gsub("%.", "")))
    local keys, items = Index.nameKey, Index.nameItem
    keys.n = keys.n + 1
    keys[keys.n] = string.lower((shown or "") .. "|" .. g.raw)
    items.n = keys.n
    items[items.n] = Index.byKind[g.kind][g.slot]
end

-- 第 i 個 tileset 的搜尋鍵＝小寫「顯示名|原名|來源 MOD 名」；命中 tileset＝該 tileset 的全部項目
function Index.addSetKey(i, modName)
    local tileset = Index.setName[i]
    local shown = getTextOrNull("IGUI_MinidoracatBuilder_Tileset_" .. tileset) or (tileset:gsub("_", " "))
    Index.setKey[i] = string.lower(shown .. "|" .. tileset .. "|" .. (modName or ""))
    Index.setKey.n = i
end

-- 整理完：丟掉只在整理期間用的群組表
function Index.finish()
    Index.groups = nil
    Index.groupList = nil
end

return Index
