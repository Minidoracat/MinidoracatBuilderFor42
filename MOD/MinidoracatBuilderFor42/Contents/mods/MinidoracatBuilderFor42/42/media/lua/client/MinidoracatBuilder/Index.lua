-- 目錄索引：整場遊戲留在記憶體，不存硬碟（bt-perf §4、§8）。
-- bucket[種類][tileset] = { n = 數量, 名稱1, 名稱2, … }：只存 sprite 名稱字串（Java 端同一個物件，不另佔空間），
-- 不存每項一張表（3.5 萬項：名稱陣列約 2 MB，每項一張表約 12 MB）。陣列自己記 n：Kahlua 的 #t 是二分搜尋。
-- 整理期間桶另有 k（圖塊編號，排序用），排完就丟掉。
-- 按「種類 × tileset」分桶：介面的頁籤（種類）與分類（圖塊組）直接取桶，不必每次掃全部。
MinidoracatBuilder = MinidoracatBuilder or {}
local Index = MinidoracatBuilder.Index or {}
MinidoracatBuilder.Index = Index

function Index.reset()
    Index.bucket = {}    -- 種類 → tileset → { n, 名稱… }
    Index.kindSets = {}  -- 種類 → { n, tileset… }（這個種類裡第一次出現的順序）
    Index.kindCount = {} -- 種類 → 項目數
    Index.sets = {}      -- tileset → 項目數
    Index.setFile = {}   -- tileset → tiledef 檔號（來源用 Sources 對到 MOD）
    Index.setName = { n = 0 } -- 出現過的 tileset，依第一次出現的順序
    Index.family = {}    -- tileset → 圖塊組（去掉結尾 _數字；第二段建）
    Index.items = 0
    Index.groups = {}    -- 整理期間用：群組鍵 → { kind, tileset, arr, slot, num, raw }（有名稱的項目都有，建搜尋鍵用）；完成後丟掉
    Index.groupList = { n = 0 }
    -- 搜尋鍵（第二段）：nameKey[i] 對 nameItem[i]（名稱）、nameKind[i]、nameSet[i]；setKey[i] 對 setName[i]
    Index.nameKey, Index.nameItem = { n = 0 }, { n = 0 }
    Index.nameKind, Index.nameSet = { n = 0 }, { n = 0 }
    Index.setKey = { n = 0 }
end
Index.reset()

-- 加一個項目。key＝群組鍵（Catalog.scanSprite 建）：同一件的各面共用一個鍵、只留一項，取編號最小的那張當代表，
-- 整理順序不影響結果；共用名稱的不同物件各用自己的鍵；沒有 CustomName 時 nil。num＝圖塊編號，記在桶的 k（排序用，排完丟掉）。
-- 每次整理約跑 5.7 萬次：只做表操作，不呼叫 Java（AGENTS.md 踩坑「目錄整理的成本幾乎只看 Java 呼叫次數」）。
function Index.add(kind, name, tileset, num, file, key, raw)
    local g = key and Index.groups[key]
    if g then
        if num < g.num then
            g.arr[g.slot] = name
            g.num = num
            if g.arr.k then g.arr.k[g.slot] = num end
        end
        return
    end
    local sets = Index.bucket[kind]
    if not sets then
        sets = {}
        Index.bucket[kind] = sets
        Index.kindSets[kind] = { n = 0 }
        Index.kindCount[kind] = 0
    end
    local arr = sets[tileset]
    if not arr then
        arr = { n = 0, k = {} }
        sets[tileset] = arr
        local ks = Index.kindSets[kind]
        ks.n = ks.n + 1
        ks[ks.n] = tileset
    end
    arr.n = arr.n + 1
    arr[arr.n] = name
    arr.k[arr.n] = num
    Index.kindCount[kind] = Index.kindCount[kind] + 1
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
        g = { kind = kind, tileset = tileset, arr = arr, slot = arr.n, num = num, raw = raw }
        Index.groups[key] = g
        local gl = Index.groupList
        gl.n = gl.n + 1
        gl[gl.n] = g
    end
end

-- 一個種類的全部名稱攤平成新陣列 { n, 名稱… }（tileset 照第一次出現的順序）。E2E、測試用，不在每幀呼叫。
function Index.names(kind)
    local out, n = { n = 0 }, 0
    local sets, order = Index.bucket[kind], Index.kindSets[kind]
    for i = 1, order and order.n or 0 do
        local arr = sets[order[i]]
        for j = 1, arr.n do
            n = n + 1
            out[n] = arr[j]
        end
    end
    out.n = n
    return out
end

-- 第二段：有名稱項目的搜尋鍵＝小寫「顯示名|原名」。顯示名用原版移動物件翻譯，
-- 先自己去掉 "."（Translator.getMoveableDisplayName 的 replace 不吃 regex，名稱有點就查不到；bt-catalog §4.1）
function Index.addNameKey(g)
    local shown = Translator.getMoveableDisplayNameOrNull((g.raw:gsub("%.", "")))
    local keys = Index.nameKey
    local i = keys.n + 1
    keys.n = i
    keys[i] = string.lower((shown or "") .. "|" .. g.raw)
    local items, kinds, sets = Index.nameItem, Index.nameKind, Index.nameSet
    items.n, kinds.n, sets.n = i, i, i
    items[i] = g.arr[g.slot]
    kinds[i] = g.kind
    sets[i] = g.tileset
end

-- 第 i 個 tileset 的搜尋鍵＝小寫「顯示名|原名|來源 MOD 名」；命中 tileset＝該 tileset 的全部項目。
-- 順便記它的圖塊組（例：furniture_seating_indoor_01 → furniture_seating_indoor）。顯示名和 Names.tileset 同一個鍵
-- （IGUI_MBLD_Family_<組>），搜得到的就是畫面上看到的名字。
function Index.addSetKey(i, modName)
    local tileset = Index.setName[i]
    local fam = tileset:match("^(.-)_%d+$") or tileset
    Index.family[tileset] = fam
    local shown = getTextOrNull("IGUI_MBLD_Family_" .. fam) or (tileset:gsub("_", " "))
    Index.setKey[i] = string.lower(shown .. "|" .. tileset .. "|" .. (modName or ""))
    Index.setKey.n = i
end

-- 一個桶照圖塊編號排：第一段照 namedMap 的雜湊順序加入（Catalog.start），同組的 #5、#0、#21 混在一起。
-- 計數排序：照 Index.add 記的編號（arr.k）放進位置表、再依編號收回，O(項目數＋編號範圍)，不比字串、不跑 match。
-- 同一個 tileset 的編號不重複（名稱就是 tileset_編號）；萬一重複，照加入順序排在同編號後面，不掉項目。
-- 排完丟掉 k：桶只留名稱。要在 addNameKey 之後才排：它照群組記的位置（g.slot）取名稱。
function Index.sortBucket(arr)
    local n, k = arr.n, arr.k
    arr.k = nil
    if n < 2 or not k then return end
    local lo, hi = k[1], k[1]
    for i = 2, n do
        local v = k[i]
        if v < lo then lo = v elseif v > hi then hi = v end
    end
    -- ponytail: 編號範圍超過 4096 的桶不排（tiledef 一張圖頂多上千格，碰不到；碰到時要排再改用合併排序）
    if hi - lo > 4096 then return end
    local at, more = {}, nil
    for i = 1, n do
        local off = k[i] - lo
        if at[off] == nil then
            at[off] = arr[i]
        else
            more = more or {}
            local m = more[off]
            if not m then
                m = { n = 0 }
                more[off] = m
            end
            m.n = m.n + 1
            m[m.n] = arr[i]
        end
    end
    local j = 0
    for off = 0, hi - lo do
        local name = at[off]
        if name then
            j = j + 1
            arr[j] = name
            local m = more and more[off]
            if m then
                for x = 1, m.n do
                    j = j + 1
                    arr[j] = m[x]
                end
            end
        end
    end
end

-- 這個 tileset 在每個種類的桶都照編號排（第二段建 tileset 搜尋鍵時順便做）
function Index.sortSet(tileset)
    for _, sets in pairs(Index.bucket) do
        local arr = sets[tileset]
        if arr then Index.sortBucket(arr) end
    end
end

-- 整理完：丟掉只在整理期間用的群組表
function Index.finish()
    Index.groups = nil
    Index.groupList = nil
end

return Index
