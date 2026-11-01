-- 建造視窗（第三階段）：目錄瀏覽、搜尋、篩選、詳情，按「建造」交給 Cursor。家族框架 MinidoracatUIFor42。
-- 單例：關掉只是隱藏（QU/Window.lua:304-328 同法），搜尋字、頁籤、分類、捲動、選取都留著（設計稿 DD:135）。
-- 版面三段（規格 1.2，門檻乘字高比例 u/16）：寬＝篩選列／分類 NavList＋方格＋詳情／狀態列；中＝方格＋詳情、
-- 分類改下拉；窄＝方格＋選取列。
-- 每幀路徑（方格 drawTile、詳情與狀態列的 render、Dock 回呼）只讀預先備好的字串、貼圖與畫圖指令，不配置。
-- 配置只發生在「有事才做」的時候：停手 120 ms 後的搜尋、換頁籤／分類、整理進度每 0.5 秒、材料摘要每秒最多一次，
-- 以及捲到新格子時補那幾格的字與貼圖（狀態列面板的 prerender，排在方格前面，同一幀方格就畫得到）。
-- 入口（檔尾）：家族 Dock（id builder、order 80）、按鍵設定一個鍵（預設不綁）、ModOptions「顯示工具列按鈕」。
if isServer() then return end

require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Sources"
require "MinidoracatBuilder/Cost"
require "MinidoracatBuilder/Index"
require "MinidoracatBuilder/Catalog"
require "MinidoracatBuilder/Names"
require "MinidoracatBuilder/Favorites"
require "MinidoracatBuilder/Sets"
require "MinidoracatBuilder/Messages"

local B = MinidoracatBuilder
local first = B.Window == nil
local W = B.Window or {}
B.Window = W
local Entry, Sources, Cost, Index = B.Entry, B.Sources, B.Cost, B.Index
local Names, Favorites, Sets, Messages = B.Names, B.Favorites, B.Sets, B.Messages

local LOG = "[MinidoracatBuilderFor42] "
W.MIN_REV = 22
W.CAPS = { "window", "controls", "sliderRow", "dropdown", "focus", "tileGrid", "virtualList", "textWrap", "navList",
    "scrollPanel" }
W.DEBOUNCE_MS = 120     -- 同框架 ItemPicker（Widgets/ItemPicker.lua:73,584-588；設計稿 DD:130）
W.BIND = "MinidoracatBuilder_Toggle"
local PAD, GAP = 8, 6
local CATALOG_MS = 500  -- 整理中每 0.5 秒才重設方格（bt-perf §9.2）
local SUMMARY_MS = 1000 -- 材料摘要每秒最多重算一次
local BUDGET_MS = 2     -- 每幀補格子、缺料檢查的時間預算
local RECENT_MAX = 30
local CACHE_MAX = 1024  -- 貼圖、截好的字：滿了整張清掉（ponytail：不做 LRU，看得到的最多約 300 格）
local DIM_MAX = 1024    -- 缺料快取：滿了整張清掉，要比一個畫面看得到的格子多很多（4K 大視窗約 300 格）
-- 一排幾格（使用者 2026-10-29：視窗裡的滑桿 2–10、預設 5，存在本機）。檔案一行一個數字。
W.PER_ROW_FILE = "MinidoracatBuilder/window.txt"
W.PER_ROW_MIN, W.PER_ROW_MAX, W.PER_ROW_DEFAULT = 2, 10, 5

-- 頁籤與種類（設計稿的九個頁籤；只列 Entry.BUILDABLE）。柱子在「牆」頁籤（使用者 2026-10-31 選新增「柱子」）
W.TABS = { "all", "floor", "wall", "doorWindow", "roof", "stairs", "furniture", "light", "decor" }
W.TAB_KINDS = {
    floor = { "floor", "floorOverlay" },
    wall = { "wall", "fence", "post", "wallOverlay" },
    doorWindow = { "door", "window", "doorFrame", "windowFrame", "windowObject", "curtain" },
    roof = { "roof" },
    stairs = { "stairs" },
    furniture = { "furniture", "container", "solid" },
    light = { "light" },
    decor = { "wallObject", "attached", "overlay" },
}
do
    local all = {}
    for i = 2, #W.TABS do
        for _, k in ipairs(W.TAB_KINDS[W.TABS[i]]) do all[#all + 1] = k end
    end
    W.TAB_KINDS.all = all
end

-- 視窗關掉再開仍保留的選擇；v（W.v）是畫面元件與快取
W.st = W.st or { query = "", tab = "all", cat = "all", source = "all", only = false, recent = { n = 0 } }
W.playerNum = W.playerNum or 0

local EMPTY = { n = 0 }

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

-- 一排幾格的設定檔：讀不到、不是 2–10 的整數就用預設 5。getFileReader／getFileWriter 的路徑相對 Zomboid/Lua，
-- 寫入時自動建資料夾（LuaManager.java:5936-5963,6727-6759；同 Favorites.lua）
local function readPerRow()
    local r = getFileReader(W.PER_ROW_FILE, false)
    if not r then return nil end
    local line = r:readLine()
    r:close()
    return tonumber(trim(line))
end

function W.loadPerRow()
    local ok, n = pcall(readPerRow)
    if ok and n and n == math.floor(n) and n >= W.PER_ROW_MIN and n <= W.PER_ROW_MAX then return n end
    return W.PER_ROW_DEFAULT
end

local function writePerRow(n)
    local w = getFileWriter(W.PER_ROW_FILE, true, false)
    w:write(tostring(n) .. "\n")
    w:close()
end

-- 滑桿的 onChange（拖動中每換一格就呼叫）：記下、存檔、立刻重排
function W.setPerRow(n)
    n = math.floor((tonumber(n) or W.PER_ROW_DEFAULT) + 0.5)
    if n == W.st.perRow then return end
    W.st.perRow = n
    if not pcall(writePerRow, n) then print(LOG .. "row size not saved to " .. W.PER_ROW_FILE) end
    if W.v then W.layout() end
end

-- 框架探測（UI AGENTS 契約 2；QU/Draw.lua:21-30）：缺一項就回 nil，不帶半套狀態
function W.ui(caps)
    if not (MinidoracatUI and MinidoracatUI.v1) then pcall(require, "MinidoracatUI/V1") end
    local UI = MinidoracatUI and MinidoracatUI.v1
    if UI == nil or UI.API_MAJOR ~= 1 or (UI.API_REVISION or 0) < W.MIN_REV then return nil end
    local have = UI.CAPABILITIES or {}
    for _, cap in ipairs(caps or W.CAPS) do
        if have[cap] ~= true then return nil end
    end
    return UI
end

-- 框架太舊或缺元件：有 Toast 就用（不論版本），沒有就只寫 log；不 error（UI AGENTS 契約 3）
local function notify(text)
    local UI = MinidoracatUI and MinidoracatUI.v1
    if UI and UI.Toast and UI.Toast.show then
        pcall(UI.Toast.show, { title = getText("IGUI_MBLD_Title"), message = text, maxLines = 8 })
        return
    end
    print(LOG .. text)
end

function W.usingPad()
    return getJoypadData ~= nil and getJoypadData(W.playerNum) ~= nil
end

-- ===== 來源與管理員關掉的 =====

-- 「a;b;c」→ 集合，只快取上一次的字串（同 Entry.lua 的 setCache）
local function setCache()
    local lastRaw, lastSet
    return function(raw)
        raw = raw or ""
        if raw ~= lastRaw then
            lastSet = {}
            for part in raw:gmatch("[^;]+") do
                local v = trim(part)
                if v ~= "" then lastSet[v] = true end
            end
            lastRaw = raw
        end
        return lastSet
    end
end
local disabledSources, disabledTilesets = setCache(), setCache()

-- tileset 的來源："vanilla"、MOD ID，或 "?"（檔號表還沒建好：整理第二段才建，Catalog.lua:115-121）
function W.sourceOf(ts)
    local file = Index.setFile[ts]
    if not file or not Sources.isModFile(file) then return "vanilla" end
    return Sources.byFile and Sources.byFile[file] or "?"
end

-- 管理員關掉的 tileset 或來源（沙盒 DisabledTilesets／DisabledSources；伺服器同一套，Entry.resolve 回 DISABLED）
function W.blocked(ts)
    local s = Entry.settings()
    if disabledTilesets(s.DisabledTilesets)[ts] then return true end
    local src = W.sourceOf(ts)
    return src ~= "vanilla" and disabledSources(s.DisabledSources)[src] == true
end

-- 圖塊組＝tileset 去掉結尾 _數字（Index.family 第二段才建，整理中先自己算）
function W.familyOf(ts)
    local fam = Index.family and Index.family[ts]
    if fam then return fam end
    return (ts:gsub("_%d+$", ""))
end

local modNames = {}
function W.modName(id)
    local name = modNames[id]
    if not name then
        local info = getModInfoByID and getModInfoByID(id)
        name = info and info:getName() or id
        modNames[id] = name
    end
    return name
end

function W.sourceLabel(src)
    if src == "vanilla" then return getText("IGUI_MBLD_Source_Vanilla") end
    if src == "?" then return getText("IGUI_MBLD_Source_Unknown") end
    return W.modName(src)
end

-- 由 key 排序（不用 table.sort：Kahlua 的實作是遞迴，深度有上限；家族規則）。由下而上的合併排序。
local function sortByKey(a)
    local n = #a
    if n < 2 then return a end
    local src, dst, width = a, {}, 1
    while width < n do
        local i = 1
        while i <= n do
            local mid, hi = math.min(i + width, n + 1), math.min(i + 2 * width, n + 1)
            local l, r, k = i, mid, i
            while l < mid and r < hi do
                if src[r].key < src[l].key then
                    dst[k] = src[r]
                    r = r + 1
                else
                    dst[k] = src[l]
                    l = l + 1
                end
                k = k + 1
            end
            while l < mid do dst[k] = src[l]; l = l + 1; k = k + 1 end
            while r < hi do dst[k] = src[r]; r = r + 1; k = k + 1 end
            i = i + 2 * width
        end
        src, dst = dst, src
        width = width * 2
    end
    if src ~= a then
        for i = 1, n do a[i] = src[i] end
    end
    return a
end
W.sortByKey = sortByKey

local function counted(label, n)
    return getText("IGUI_MBLD_Count", label, tostring(n))
end

-- ===== 篩選（純函式，離線可測）=====

local function append(out, arr)
    for i = 1, arr.n do
        out.n = out.n + 1
        out[out.n] = arr[i]
    end
end

-- 這個頁籤裡管理員沒關掉的種類（沙盒 Kind*，Entry.kindOn；伺服器同一套，Entry.resolve 回 DISABLED）
local function tabKinds(tab)
    local s, out = Entry.settings(), {}
    for _, k in ipairs(W.TAB_KINDS[tab] or W.TAB_KINDS.all) do
        if Entry.kindOn(k, s) then out[#out + 1] = k end
    end
    return out
end
W.tabKinds = tabKinds

-- 管理員關掉了幾種
function W.kindsOff()
    local s, n = Entry.settings(), 0
    for _, k in ipairs(Entry.KINDS) do
        if not Entry.kindOn(k, s) then n = n + 1 end
    end
    return n
end

-- 完整 sprite 名稱（大小寫照原樣）而且在目錄裡：回它所在的那一桶
local function exactBucket(q)
    if not q:find("_%d+$") or not Entry.sprite(q) then return nil end
    local ts = q:match("^(.*)_%d+$")
    if W.blocked(ts) then return nil end
    local s = Entry.settings()
    for kind, sets in pairs(Index.bucket or {}) do
        local b = Entry.BUILDABLE[kind] and Entry.kindOn(kind, s) and sets[ts] -- 目錄也收了車庫門，不能蓋
        if b then
            for i = 1, b.n do
                if b[i] == q then return b end
            end
        end
    end
    return nil
end

-- 完整圖塊名不在目錄時，同一件東西在目錄裡的那一項。先換成能蓋的那一張（Entry.why 的 alt：開著的門、窗的狀態圖、
-- 拉上的窗簾、疊放圖、多格的其他格、樓梯的中頂片；能蓋的就是它自己），它不在目錄時再找併成一項的其他朝向
-- （Catalog 只留編號最小的那面）。回 那一項, 它的桶
local function listedAlt(q)
    local code, _, alt = Entry.why(q)
    if code and not alt then return nil end
    local b = alt and exactBucket(alt)
    if b then return alt, b end
    local target = alt or q
    local e = Entry.resolve(target)
    for d = 1, 4 do
        local f = e and Entry.face(e, d)
        local name = f and f:getName()
        b = name and name ~= target and exactBucket(name)
        if b then return name, b end
    end
    return nil
end

-- 搜尋字命中的 tileset（命中＝整桶）與有名稱的項目。一般清單和最愛／最近使用共用，搜得到的範圍一樣。
-- 回 setHit（tileset → true）、nameHit（種類 → tileset → { n, 名稱… }，照名稱表順序）、named（名稱 → true）。
local function queryHits(ql)
    local setHit, nameHit, named = {}, {}, {}
    local keys, sets = Index.setKey, Index.setName
    for i = 1, keys.n do
        if string.find(keys[i], ql, 1, true) then setHit[sets[i]] = true end
    end
    keys = Index.nameKey
    local nk, ns, ni = Index.nameKind, Index.nameSet, Index.nameItem
    for i = 1, keys.n do
        if string.find(keys[i], ql, 1, true) then
            local byKind = nameHit[nk[i]]
            if not byKind then
                byKind = {}
                nameHit[nk[i]] = byKind
            end
            local arr = byKind[ns[i]]
            if not arr then
                arr = { n = 0 }
                byKind[ns[i]] = arr
            end
            arr.n = arr.n + 1
            arr[arr.n] = ni[i]
            named[ni[i]] = true
        end
    end
    return setHit, nameHit, named
end

-- 最愛、最近使用：幾十項，逐項解析（這個伺服器沒有、被關掉的 resolve 回 nil，就不列；DD:133）。
-- 搜尋除了一般清單的命中（來源、圖塊組、英文原名），清單短，另外逐項比顯示名與完整圖塊名。
local function filterList(st, list, ql, kinds)
    local want = {}
    for _, k in ipairs(kinds) do want[k] = true end
    local setHit, named = EMPTY, EMPTY
    if ql ~= "" then
        local _
        setHit, _, named = queryHits(ql)
    end
    local out = { n = 0 }
    for i = 1, list.n do
        local name = list[i]
        local e = Entry.resolve(name)
        if e and want[e.kind] and (st.source == "all" or W.sourceOf(e.tileset) == st.source)
            and (ql == "" or setHit[e.tileset] or named[name]
                or string.find(string.lower(Names.of(name, e.kind) .. "|" .. name), ql, 1, true)) then
            out.n = out.n + 1
            out[out.n] = name
        end
    end
    return out
end

-- 分類標籤上的數量：這個頁籤、來源下列得出來的筆數
function W.mineCount(list, kinds)
    return filterList({ source = W.st.source }, list, "", kinds).n
end

-- state＝{ query, tab, cat（"all"／"fav"／"recent"／"k:種類"／"f:圖塊組"）, source（"all"／"vanilla"／MOD ID）,
--          fav、recent（{ n, 名稱… }）}。回 names（{ n, 名稱… }）, jump（完整圖塊名命中時要選取的那一項；不在目錄時
--          改選同一件東西在目錄裡的那一項，listedAlt）。
-- 不逐項解析字串：沒有搜尋字時整桶接上；有搜尋字時只掃 Index.setKey（約 855 個，命中＝整桶）與
-- Index.nameKey（約 4 千個有名稱的項目），再照「種類 × tileset」的桶順序輸出（bt-perf §5.4）。
local function listFor(st)
    local q = trim(st.query)
    local ql = string.lower(q)
    if q ~= "" then
        local b, jump = exactBucket(q), q
        if not b and q:find("_%d+$") then jump, b = listedAlt(q) end
        if b then
            local out = { n = 0 }
            append(out, b)
            return out, jump
        end
    end
    local kinds = tabKinds(st.tab)
    local cat = st.cat or "all"
    if cat == "fav" then return filterList(st, st.fav or EMPTY, ql, kinds), nil end
    if cat == "recent" then return filterList(st, st.recent or EMPTY, ql, kinds), nil end
    local fam
    if cat:sub(1, 2) == "k:" then
        local k = cat:sub(3)
        for _, t in ipairs(kinds) do
            if t == k then kinds = { k } break end
        end
    elseif cat:sub(1, 2) == "f:" then
        fam = cat:sub(3)
    end
    local setHit, nameHit
    if ql ~= "" then setHit, nameHit = queryHits(ql) end
    local out = { n = 0 }
    local bucket, kindSets = Index.bucket or EMPTY, Index.kindSets or EMPTY
    for _, k in ipairs(kinds) do
        local sets, byTs = kindSets[k], bucket[k]
        if sets and byTs then
            local hits = nameHit and nameHit[k]
            for j = 1, sets.n do
                local ts = sets[j]
                if (not fam or W.familyOf(ts) == fam) and (st.source == "all" or W.sourceOf(ts) == st.source)
                    and not W.blocked(ts) then
                    if not setHit or setHit[ts] then
                        append(out, byTs[ts])
                    elseif hits and hits[ts] then
                        append(out, hits[ts])
                    end
                end
            end
        end
    end
    return out, nil
end

-- 上面的清單再套「換成」條件（st.replace.match：名稱 → 朝向，W.openReplace）。還在算時列空的（空狀態寫「正在找」），
-- 不先列整個目錄再跳。整套（st.set，W.openSet）時清單就是那一套
function W.filter(st)
    if st.set then return st.set.list, nil end
    local rp = st.replace
    if rp and not rp.match then return { n = 0 }, nil end
    local out, jump = listFor(st)
    local m = rp and rp.match
    if not m then return out, jump end
    local kept = { n = 0 }
    for i = 1, out.n do
        if m[out[i]] then
            kept.n = kept.n + 1
            kept[kept.n] = out[i]
        end
    end
    if jump and not m[jump] then jump = nil end
    return kept, jump
end

-- 分類（NavList 群組；中窄版攤平成下拉）：我的／種類／圖塊組。數量照目前的頁籤與來源算，不含管理員關掉的；
-- 圖塊組只列這個來源有的（列別的來源的組，點下去是空清單）
function W.categories(tab)
    local kinds = tabKinds(tab)
    local src = W.st.source
    local bucket, kindSets = Index.bucket or EMPTY, Index.kindSets or EMPTY
    local kindN, famN, famList, total = {}, {}, {}, 0
    for _, k in ipairs(kinds) do
        local sets = kindSets[k]
        if sets then
            for j = 1, sets.n do
                local ts = sets[j]
                if (src == "all" or W.sourceOf(ts) == src) and not W.blocked(ts) then
                    local n = bucket[k][ts].n
                    kindN[k] = (kindN[k] or 0) + n
                    total = total + n
                    local f = W.familyOf(ts)
                    if not famN[f] then famList[#famList + 1] = f end
                    famN[f] = (famN[f] or 0) + n
                end
            end
        end
    end
    -- 最愛、最近使用的數量＝這個頁籤、來源下列得出來的（檔裡有、這個伺服器沒有的不算）
    local mine = { { id = "fav", label = counted(getText("IGUI_MBLD_Cat_Fav"), W.mineCount(Favorites.list, kinds)), icon = "markerStar" },
        { id = "recent", label = counted(getText("IGUI_MBLD_Cat_Recent"), W.mineCount(W.st.recent, kinds)), icon = "clock" } }
    local kindItems = { { id = "all", label = counted(getText("IGUI_MBLD_Cat_All"), total) } }
    for _, k in ipairs(kinds) do
        if kindN[k] then kindItems[#kindItems + 1] = { id = "k:" .. k, label = counted(Names.kind(k), kindN[k]) } end
    end
    local famItems = {}
    for i, f in ipairs(famList) do
        local label = Names.family(f)
        famItems[i] = { id = "f:" .. f, label = counted(label, famN[f]), key = string.lower(label) }
    end
    sortByKey(famItems)
    return { { title = getText("IGUI_MBLD_Group_Mine"), items = mine },
        { title = getText("IGUI_MBLD_Group_Kinds"), items = kindItems },
        { title = getText("IGUI_MBLD_Group_Families"), items = famItems } }
end

-- 來源下拉：全部、原版、各 MOD（附圖塊數，只算這一版能蓋的）；管理員關掉的列在提示裡（設計稿 DD:274）
function W.sources()
    local counts, order, total = {}, {}, 0
    local bucket, kindSets = Index.bucket or EMPTY, Index.kindSets or EMPTY
    for _, k in ipairs(tabKinds("all")) do
        local sets = kindSets[k]
        if sets then
            for j = 1, sets.n do
                local ts = sets[j]
                if not W.blocked(ts) then
                    local src = W.sourceOf(ts)
                    if not counts[src] then order[#order + 1] = src end
                    local n = bucket[k][ts].n
                    counts[src] = (counts[src] or 0) + n
                    total = total + n
                end
            end
        end
    end
    local opts = { { id = "all", label = counted(getText("IGUI_MBLD_Source_All"), total) } }
    if counts.vanilla then opts[2] = { id = "vanilla", label = counted(W.sourceLabel("vanilla"), counts.vanilla) } end
    local mods = {}
    for _, src in ipairs(order) do
        if src ~= "vanilla" then
            local label = W.sourceLabel(src)
            mods[#mods + 1] = { id = src, label = counted(label, counts[src]), key = string.lower(label) }
        end
    end
    sortByKey(mods)
    for _, o in ipairs(mods) do opts[#opts + 1] = { id = o.id, label = o.label } end
    local off = {}
    for id in pairs(disabledSources(Entry.settings().DisabledSources)) do off[#off + 1] = { key = W.modName(id) } end
    sortByKey(off)
    local tip = getText("IGUI_MBLD_Source_Tip")
    if #off > 0 then
        local names = {}
        for i, o in ipairs(off) do names[i] = o.key end
        tip = tip .. " " .. getText("IGUI_MBLD_Source_Disabled", tostring(#off), table.concat(names, getText("IGUI_MBLD_ListSep")))
    end
    return opts, tip
end

-- ===== 快取：貼圖、截好的字、缺料 =====

local function texOf(v, name)
    local t = v.tex[name]
    if t == nil then
        local tex = getTexture(name) -- 世界圖塊的貼圖；splitIcon 裁掉透明邊，引擎自己快取（Texture.java:1193-1215）
        if tex then tex = tex:splitIcon() end
        t = tex or false
        if v.texN >= CACHE_MAX then v.tex, v.texN = {}, 0 end
        v.tex[name] = t
        v.texN = v.texN + 1
    end
    return t or nil
end

local itemTex = {}
local function itemTexOf(ft)
    local t = itemTex[ft]
    if t == nil then
        local item = getScriptManager():FindItem(ft)
        t = item and item:getNormalTexture() or false
        itemTex[ft] = t
    end
    return t or nil
end

-- 缺料、缺工具或技能不夠（硬核「需要技能」，使用者 2026-11-02）：true；項目解析不了（Check.affordable 回 total nil）也算不能蓋
-- 每幀替看得到的格子補，所以包 pcall：哪個圖塊的屬性讓成本計算丟錯，標成缺料（不能蓋）並只記一次 log，
-- 不要每幀重丟、整個狀態列停住
local shortErrLogged = false
local function isShort(S, name)
    local C = B.Check
    if not (C and C.affordable) then return false end
    local ok, missing, tools, total, skill = pcall(C.affordable, S, name)
    if not ok then
        if not shortErrLogged then
            shortErrLogged = true
            print(LOG .. "cost check failed for " .. tostring(name) .. ": " .. tostring(missing))
        end
        return true
    end
    return total == nil or missing ~= nil or tools ~= nil or skill ~= nil
end
W.isShort = isShort

local function setDim(v, name, d)
    if v.dimN >= DIM_MAX then v.dim, v.dimN = {}, 0 end
    v.dim[name] = d
    v.dimN = v.dimN + 1
end

-- s 斷成最多 max 行（框架 Text.wrap，rev 16）；斷不完時最後一行接上原文剩下的部分再 Text.fit，截掉的地方有省略號
function W.wrapMax(Text, s, w, font, max)
    local lines = Text.wrap(s, w, font)
    if #lines <= max then return lines end
    local out, pos = {}, 1
    for i = 1, max - 1 do
        out[i] = lines[i]
        local _, e = s:find(lines[i], pos, true)
        pos = (e or pos) + 1
    end
    out[max] = Text.fit(trim(s:sub(pos)), w, font)
    return out
end
local wrapMax = W.wrapMax

-- 方格名稱兩行：短名有換行（圖塊組／編號，Names.short）就各佔一行、各自截短，編號一定看得到；
-- 沒有（原版譯名）就斷成最多兩行
function W.tileLines(Text, s, w, font)
    local a, b = s:match("^(.-)\n(.*)$")
    if a then return { Text.fit(a, w, font), Text.fit(b, w, font) } end
    return wrapMax(Text, s, w, font, 2)
end

-- 方格的短名；整套（W.openSet）裡寫套裡的位置（西牆、柱子…）＋編號：種類混在一起，tileset 名都一樣。
-- 接成一行交給 tileLines 照字斷成兩行（不用換行分段）：位置字長的語言放不下時，方向字斷到第二行，被截的是後面的編號
function W.tileLabel(name)
    local set = W.st.set
    local off = set and set.at and set.at[name]
    if not off then return Names.short(name) end
    return getText("IGUI_MBLD_SetRole_" .. Sets.ROLES[off]) .. " " .. getText("IGUI_MBLD_Name_Num", name:match("_(%d+)$"))
end

-- 看得到的格子：補貼圖、斷好的短名（最多兩行）、缺料標記（有時間預算；沒做完的下一幀繼續）
local function prepareVisible(v)
    local grid = v.grid
    local items = grid:getItems()
    local n = #items
    if n == 0 then return end
    local tw = grid:tileWidth()
    if tw ~= v.textTW then v.text, v.textN, v.textTW = {}, 0, tw end
    local per, th, scroll = grid:perRow(), grid.rowHeight, grid.scrollOffset
    local firstI = math.floor(scroll / th) * per + 1
    local lastI = math.min(n, (math.floor((scroll + grid.height - 1) / th) + 1) * per)
    local t0 = getTimestampMs()
    for i = firstI, lastI do
        local name = items[i]
        texOf(v, name)
        if v.text[name] == nil then
            if v.textN >= CACHE_MAX then v.text, v.textN = {}, 0 end
            v.text[name] = W.tileLines(v.UI.Text, W.tileLabel(name), tw - 12, v.font)
            v.textN = v.textN + 1
        end
        if v.S and v.dim[name] == nil then setDim(v, name, isShort(v.S, name)) end
        if getTimestampMs() - t0 >= BUDGET_MS then return end
    end
end

-- 格子的提示框與手把焦點說明：「名稱 · 還缺材料」
function W.tipOf(v, name, short)
    if short == nil then short = v.dim[name] end
    local s = Names.of(name)
    if short == true then return s .. getText("IGUI_MBLD_Sep") .. getText("IGUI_MBLD_Tip_Short") end
    if short == false then return s .. getText("IGUI_MBLD_Sep") .. getText("IGUI_MBLD_Tip_Ok") end
    return s
end

-- ===== 換成：同一組、同一條邊、同材料與工具的款式（W.openReplace，右鍵「換成...」）=====

-- 兩份成本的材料（{ [fullType] = 數量 }）與工具（清單，當集合比）都一樣
local function sameCost(a, b)
    for ft, n in pairs(a.items) do
        if b.items[ft] ~= n then return false end
    end
    for ft in pairs(b.items) do
        if a.items[ft] == nil then return false end
    end
    if #a.tools ~= #b.tools then return false end
    local set = {}
    for _, t in ipairs(a.tools) do set[t] = true end
    for _, t in ipairs(b.tools) do
        if not set[t] then return false end
    end
    return true
end

-- 現在的價：Cost.forCells × 沙盒倍率（和詳情、伺服器同一份）；只收單格，取第一格
local function priceOf(kind, spr, mult)
    return Cost.forCells(kind, { spr }, mult)[1]
end

-- 這一項哪一面換得掉舊的那件：回朝向 0..4，或 nil。先比第 0 面的價：多數項目在這裡就淘汰，比找其他面便宜
-- （每一面要多查偏移、重算種類）；再找 Dismantle.swappable（同組、同一條邊、不是同一張、都單格）的那一面，
-- 不是第 0 面時那一面也要同價。
-- ponytail：第 0 面和舊的不同價、別的面同價的項目會漏掉（同一件各面的材質通常一樣）；要收就每一面都算價
local function replaceFace(rp, kind, name, mult)
    local spr = Entry.sprite(name)
    if not spr or not sameCost(rp.cost, priceOf(kind, spr, mult)) then return nil end
    local tileset, num = name:match("^(.*)_(%d+)$")
    local e = { spr = spr, kind = kind, tileset = tileset, num = tonumber(num) }
    local swappable = B.Dismantle.swappable
    for d = 0, 4 do
        local f = Entry.face(e, d)
        if f and (d == 0 or f ~= spr) and swappable(rp.kind, rp.spr, kind, f)
            and (d == 0 or sameCost(rp.cost, priceOf(kind, f, mult))) then
            return d
        end
    end
    return nil
end

-- 開始算：只掃同一組種類的桶（Dismantle.GROUP；沒列的＝同種類），管理員關掉的種類與圖塊組不掃。結果記在
-- st.replace.match，留到條件關掉、目錄整理完或沙盒改了（成本倍率）才重算（W.pump、W.syncSettings）
function W.startReplace(v, rp)
    local G, s = B.Dismantle.GROUP or EMPTY, Entry.settings()
    local g = G[rp.kind]
    local list, kinds = { n = 0 }, {}
    local bucket, kindSets = Index.bucket or EMPTY, Index.kindSets or EMPTY
    for _, k in ipairs(Entry.KINDS) do
        local sets, byTs = kindSets[k], bucket[k]
        if (k == rp.kind or (g and G[k] == g)) and Entry.kindOn(k, s) and sets and byTs then
            for j = 1, sets.n do
                local ts = sets[j]
                if not W.blocked(ts) then
                    local b = byTs[ts]
                    for i = 1, b.n do
                        list.n = list.n + 1
                        list[list.n] = b[i]
                        kinds[list.n] = k
                    end
                end
            end
        end
    end
    local mult = s.CostMultiplier or 1
    rp.cost = priceOf(rp.kind, rp.spr, mult)
    v.rep = { rp = rp, list = list, kinds = kinds, i = 0, match = {}, n = 0, mult = mult }
    v.repPct = 0
end

-- 每幀做一段（同「只看能蓋的」：每項要算成本、找朝向，一次做完會卡）；做完套用並回到頂端
local function runReplace(v)
    local job = v.rep
    local list, i = job.list, job.i
    local t0 = getTimestampMs()
    while i < list.n do
        i = i + 1
        -- 哪個圖塊的屬性讓成本計算丟錯就當不同材料，不要整個篩選停住（同 isShort）
        local ok, d = pcall(replaceFace, job.rp, job.kinds[i], list[i], job.mult)
        if ok and d then
            job.match[list[i]] = d
            job.n = job.n + 1
        end
        if i % 8 == 0 and getTimestampMs() - t0 >= BUDGET_MS then break end
    end
    job.i = i
    local pct = list.n > 0 and math.floor(i * 100 / list.n) or 100
    if pct ~= v.repPct then
        v.repPct = pct
        W.setStatus(v)
    end
    if i >= list.n then
        v.rep = nil
        job.rp.match, job.rp.count = job.match, job.n
        W.refilter(false)
    end
end

-- 換成條件的價寫成一行：「木板 2、釘子 4、鐵鎚」（沒有任何一項同材料時說明用）
local function priceText(cost)
    local parts = {}
    for ft, n in pairs(cost.items) do parts[#parts + 1] = getText("IGUI_MBLD_RowItem", getItemName(ft) or ft, tostring(n)) end
    for _, t in ipairs(cost.tools) do parts[#parts + 1] = getTextOrNull("IGUI_MBLD_Tool_" .. t) or t end
    if #parts == 0 then return getText("IGUI_MBLD_Detail_NoMaterials") end
    return table.concat(parts, getText("IGUI_MBLD_ListSep"))
end

-- ===== 套用篩選 =====

-- 原因碼 → 玩家看的說明（Entry.why；右鍵挑圖塊的提示也用）
function W.whyText(code, arg)
    if code == "DISABLED_KIND" then
        arg = Names.kind(arg)
    elseif code == "DISABLED_SOURCE" and arg then
        arg = W.modName(arg)
    elseif code == "ENTITY" and arg then
        -- 配方的顯示名稱（Translator.getRecipeName：沒有翻譯時回原名；LuaManager.java:8848-8853、Translator.java:691-701）
        arg = getRecipeDisplayName(arg)
    end
    return getTextOrNull("IGUI_MBLD_Why_" .. tostring(code), tostring(arg or "?")) or getText("IGUI_MBLD_Why_UNKNOWN")
end

-- 搜尋沒有結果時的標題與提示。完整圖塊名的說原因（審查 1031 HIGH：原本叫玩家試較短的字，照做也找不到）：
-- 在目錄裡卻沒出現的，是被「只看能蓋的」濾掉；能蓋卻不在目錄的，是這版遊戲沒有它的貼圖（目錄只收有貼圖的），
-- 或目錄還在整理
function W.emptyQuery(q)
    if not (q:find("_%d+$") and Entry.sprite(q)) then
        return getText("IGUI_MBLD_Empty_Query", q), getText("IGUI_MBLD_Empty_QueryHint")
    end
    if exactBucket(q) or listedAlt(q) then return getText("IGUI_MBLD_Empty_Only"), nil end
    local code, arg = Entry.why(q)
    if code == "UNKNOWN" then return getText("IGUI_MBLD_Empty_Query", q), getText("IGUI_MBLD_Empty_QueryHint") end
    if not code then
        if not (B.Catalog and B.Catalog.state == "ready") then return getText("IGUI_MBLD_Catalog_Wait"), nil end
        code = "NO_TEXTURE"
    end
    return getText("IGUI_MBLD_Why_Title", q), W.whyText(code, arg)
end

local function prepareEmpty(v)
    local grid, st = v.grid, W.st
    v.emptyTitle, v.emptyHint = nil, nil
    if #grid:getItems() > 0 then
        v.clearBtn:setVisible(false)
        return
    end
    local cs = B.Catalog and B.Catalog.state
    local q = trim(st.query)
    local title, hint
    local rp = st.replace
    if cs == "failed" then
        title = getText("IGUI_MBLD_Catalog_Failed")
    elseif rp and not rp.match then
        title = cs == "ready" and getText("IGUI_MBLD_Replace_Finding", rp.label) or getText("IGUI_MBLD_Catalog_Wait")
    elseif rp and rp.count == 0 then
        -- 沒有任何一項同材料：寫出比的是哪一份價，玩家才知道為什麼（例：舊的是鐵皮牆，木牆都不列）
        title, hint = getText("IGUI_MBLD_Replace_None", rp.label), getText("IGUI_MBLD_Replace_NoneHint", priceText(rp.cost))
    elseif q ~= "" then
        title, hint = W.emptyQuery(q)
    elseif cs ~= "ready" then
        title = getText("IGUI_MBLD_Catalog_Wait")
    elseif st.cat == "fav" then
        title = getText("IGUI_MBLD_Empty_Fav")
    elseif st.cat == "recent" then
        title = getText("IGUI_MBLD_Empty_Recent")
    elseif st.only then
        title = getText("IGUI_MBLD_Empty_Only")
    else
        title = getText("IGUI_MBLD_Empty_None")
    end
    local w = math.max(40, grid.width - 24)
    local Text = v.UI.Text
    v.emptyTitle = Text.wrap(title, w, v.font)
    v.emptyHint = hint and Text.wrap(hint, w, v.font) or nil
    v.emptyY = math.floor(grid.height * 0.25)
    local lines = #v.emptyTitle + (v.emptyHint and #v.emptyHint or 0)
    local b = v.clearBtn
    b:setVisible(q ~= "")
    b:setX(grid:getX() + math.floor((grid.width - b.width) / 2))
    b:setY(grid:getY() + v.emptyY + lines * (v.fh + 2) + 16)
end

function W.setStatus(v)
    local C = B.Catalog
    local cs = C and C.state
    if cs == "failed" then
        v.statusText = v.UI.Text.fit(getText("IGUI_MBLD_Catalog_Failed"), v.status.width, v.font)
    elseif cs ~= "ready" then
        v.statusText = getText("IGUI_MBLD_Catalog_Running", tostring(v.catPct or 0))
    elseif v.aff then
        v.statusText = getText("IGUI_MBLD_Status_Checking", tostring(v.affPct or 0))
    elseif v.rep then
        v.statusText = getText("IGUI_MBLD_Status_Replacing", tostring(v.repPct or 0))
    else
        local n, off = tostring(#v.grid:getItems()), W.kindsOff()
        v.statusText = off > 0 and getText("IGUI_MBLD_Status_CountOff", n, tostring(off)) or getText("IGUI_MBLD_Status_Count", n)
    end
end

local function applyItems(v, list, jump, keep)
    local grid = v.grid
    grid:setItems(list)
    local want = jump or v.selName
    local idx
    if want then
        for i = 1, #list do
            if list[i] == want then
                idx = i
                break
            end
        end
    end
    grid:setSelectedIndex(idx)
    if idx and (jump or not keep) then
        grid:scrollToIndex(idx)
    elseif not keep then
        grid:setScrollOffset(0)
    end
    v.selName = idx and want or nil
    v.detailDirty = true
    prepareEmpty(v)
    W.setStatus(v)
end

-- keep＝true：保留捲動位置（整理進度、材料變動的重算）；false：換了條件，回到頂端或捲到選取
function W.refilter(keep)
    local v = W.v
    if not v then return end
    local st = W.st
    st.fav = Favorites.list
    local out, jump = W.filter(st)
    if st.only and v.S then
        -- 「只看能蓋的」：逐項查材料很貴（每項要解析與算成本），分批做，做完才換方格內容
        v.aff = { list = out, i = 0, out = { n = 0 }, jump = jump, keep = keep }
        v.affPct = 0
        W.setStatus(v)
        return
    end
    v.aff = nil
    applyItems(v, out, jump, keep)
end

local function runAffordable(v)
    local job = v.aff
    local list, out, i = job.list, job.out, job.i
    local t0 = getTimestampMs()
    while i < list.n do
        i = i + 1
        local name = list[i]
        local d = v.dim[name]
        if d == nil then d = isShort(v.S, name) end
        if not d then
            out.n = out.n + 1
            out[out.n] = name
        end
        if i % 16 == 0 and getTimestampMs() - t0 >= BUDGET_MS then break end
    end
    job.i = i
    local pct = list.n > 0 and math.floor(i * 100 / list.n) or 100
    if pct ~= v.affPct then
        v.affPct = pct
        W.setStatus(v)
    end
    if i >= list.n then
        v.aff = nil
        applyItems(v, out, job.jump, job.keep)
        -- ponytail：清單很長時玩家一直走動，摘要每秒變，會一輪接一輪重查；要省就改成只在背包變動時重查
        if v.affStale then
            v.affStale = false
            W.refilter(true)
        end
    end
end

-- ===== 詳情（選取改變、材料摘要改變、版面改變時才重組畫圖指令）=====

local function add(ops, o)
    ops.n = ops.n + 1
    ops[ops.n] = o
end

local function text(ops, s, x, y, c, font)
    add(ops, { t = "text", s = s, x = x, y = y, c = c, f = font })
end

-- 一段字最多 max 行（預設兩行：名稱、來源、佔地這類短欄位放不下就截字加省略號）；回下一行的 y
local function para(v, ops, s, x, y, w, col, max)
    for _, line in ipairs(wrapMax(v.UI.Text, s, w, v.font, max or 2)) do
        text(ops, line, x, y, col, v.font)
        y = y + v.fh + 4
    end
    return y
end

-- 前面加警告圖示、整段用警告色（只能砸不退料、永久上鎖的窗：蓋之前要看得到，不截字）；回下一行的 y
local function warnLines(v, ops, s, y, w)
    local c, fh = v.colors, v.fh
    add(ops, { t = "icon", key = "warning", x = 0, y = y + math.floor((fh - 16) / 2), size = 16, c = c.warning })
    for _, line in ipairs(v.UI.Text.wrap(s, w - 20, v.font)) do
        text(ops, line, 20, y, c.warning, v.font)
        y = y + fh + 4
    end
    return y
end

local function costInfo(v, e)
    local sprites, cells = {}, Entry.cells(e.spr)
    for i, c in ipairs(cells) do sprites[i] = c[4] end
    local costs = Cost.forCells(e.kind, sprites, Entry.settings().CostMultiplier or 1)
    local total = Cost.sum(costs)
    local missing, tools
    local M = B.Materials
    if v.S and M and M.short and not v.S.cheat then missing, tools = M.short(v.S, total) end
    return total, costs, missing, tools
end

local function toolName(tag)
    return getTextOrNull("IGUI_MBLD_Tool_" .. tag) or tag
end

-- 材料一列：圖示、名稱（最多兩行）、靠右的「有／要」；缺的整列警告色、數量左邊加警告圖示。回下一行的 y
local function matRow(v, ops, y, dw, ft, label, qty, short)
    local c, fh = v.colors, v.fh
    local col = short and c.warning or c.text
    local qtyW = getTextManager():MeasureStringX(v.font, qty)
    local itex = itemTexOf(ft)
    if itex then add(ops, { t = "tex", tex = itex, x = 0, y = y + math.floor((fh - 16) / 2), w = 16, h = 16 }) end
    add(ops, { t = "textR", s = qty, x = dw, y = y, c = col, f = v.font })
    if short then add(ops, { t = "icon", key = "warning", x = dw - qtyW - 20, y = y + math.floor((fh - 16) / 2), size = 16, c = c.warning }) end
    return para(v, ops, label, 20, y, dw - 20 - qtyW - (short and 22 or 4), col)
end

-- 耗材列的圖示：照標籤收的用代表的那種桶子，其他照 fullType
local USE_ICON = { [Cost.CONCRETE] = "Base.BucketClayCement" }

-- 硬核「需要技能」打開時：回 說明, 夠不夠（Check.skill，伺服器同一個判斷）；不要求技能回 nil
local function skillInfo(e)
    local C = B.Check
    if not (C and C.skill) then return nil end
    local perk, level, have, enough = C.skill(getSpecificPlayer(W.playerNum), e.kind, e.spr)
    if not perk then return nil end
    local name = getText("IGUI_perks_" .. perk)
    if enough then return getText("IGUI_MBLD_Detail_Skill", name, tostring(level)), true end
    return getText("IGUI_MBLD_Detail_SkillShort", name, tostring(level), tostring(have)), false
end

-- 佔地（寬×深）：多格照 grid；樓梯照方向是 3×1 或 1×3（上一層的平台不算）
local function footprint(spr)
    local t = spr:getType()
    if B.Rules.typeCode(t) == "stairs" then
        if B.Rules.westStairs(t) then return 3, 1 end
        return 1, 3
    end
    local grid = spr:getSpriteGrid()
    if not grid then return 1, 1 end
    return grid:getWidth(), grid:getHeight()
end

local function faceCount(e)
    local seen = {}
    for d = 0, 4 do
        local f = Entry.face(e, d)
        if f then
            local dup = false
            for i = 1, #seen do
                if seen[i] == f then dup = true break end
            end
            if not dup then seen[#seen + 1] = f end
        end
    end
    return #seen
end

-- 寬、中版：預覽大圖（原比例＋佔地格線）、名稱、來源、佔地與朝向數、材料（圖示＋有／要）、工具、經驗、拆除方式
local function detailFull(v, ops, e, total, costs, missing, tools)
    local c, fh, s = v.colors, v.fh, v.s
    local dw = v.detail.width
    local Text, lh = v.UI.Text, fh + 4
    local boxH = math.min(math.floor(150 * s), math.floor(dw * 0.75))
    add(ops, { t = "box", x = 0, y = 0, w = dw, h = boxH, c = c.border or c.textFaint })
    local tex = texOf(v, e.name)
    if tex then add(ops, { t = "tex", tex = tex, x = 6, y = 6, w = dw - 12, h = boxH - 12 }) end
    local fw, fd = footprint(e.spr)
    local cell = math.max(6, math.floor(10 * s))
    add(ops, { t = "grid", x = dw - 6 - fw * cell, y = boxH - 6 - fd * cell, cols = fw, rows = fd, cell = cell, c = c.textMuted })
    local y = boxH + GAP
    local fhM = getTextManager():getFontHeight(UIFont.Medium)
    -- 名稱最多三行，第三行接上剩下的字截短（完整 tileset ID 是搜尋要用的字，截掉處要看得出來）
    for _, line in ipairs(wrapMax(Text, Names.of(e.name, e.kind), dw, UIFont.Medium, 3)) do
        text(ops, line, 0, y, c.text, UIFont.Medium)
        y = y + fhM + 2
    end
    y = y + 2
    -- 來源寫完整的 tileset ID（搜尋要用）：放不下就換行、不截字（詳情可以捲動）
    for _, line in ipairs(Text.wrap(getText("IGUI_MBLD_Detail_Source", W.sourceLabel(W.sourceOf(e.tileset)), e.tileset), dw, v.font)) do
        text(ops, line, 0, y, c.textMuted, v.font)
        y = y + lh
    end
    -- 完整圖塊名（審查 1031 MEDIUM：畫面上只看得到「blends street 01 #101」，玩家回報時給不出名稱；和 pzmap、TileZed 同寫法）
    for _, line in ipairs(Text.wrap(getText("IGUI_MBLD_Detail_Tile", e.name), dw, v.font)) do
        text(ops, line, 0, y, c.textMuted, v.font)
        y = y + lh
    end
    y = para(v, ops, getText("IGUI_MBLD_Detail_Size", tostring(fw), tostring(fd), tostring(faceCount(e))), 0, y, dw, c.textMuted)
    -- 原版可疊的箱子（IsStackable）同一張也能疊，高度上限照原版搬家具（Place.check 交給 canPlaceMoveableInternal）
    if e.spr:getProperties():has("IsStackable") then
        for _, line in ipairs(Text.wrap(getText("IGUI_MBLD_Detail_Stackable"), dw, v.font)) do
            text(ops, line, 0, y, c.textMuted, v.font)
            y = y + lh
        end
    end
    -- 永久上鎖的窗照樣列（使用者 2026-10-30 選），蓋之前標出來：原版建構子設成永久上鎖，開窗一開頭就跳過
    -- （IsoWindow.java:84,744）；打破窗不看這個鎖（:264-306）
    if e.kind == "window" and e.spr:getProperties():has("WindowLocked") then
        y = warnLines(v, ops, getText("IGUI_MBLD_Detail_WindowLocked"), y, dw)
    end
    -- 拆除方式放在材料前面：只能砸、不退料的照樣能蓋，不捲動就要看得到（設計稿 DD:596-606）
    local refund = Cost.refund and Cost.refund(e.kind, e.spr)
    if refund == "none" then
        y = warnLines(v, ops, getText("IGUI_MBLD_Refund_none"), y, dw)
    elseif refund then
        for _, line in ipairs(Text.wrap(getText("IGUI_MBLD_Refund_" .. refund), dw, v.font)) do
            text(ops, line, 0, y, c.textMuted, v.font)
            y = y + lh
        end
    end
    y = y + 4
    text(ops, getText("IGUI_MBLD_Detail_Materials"), 0, y, c.textMuted, v.font)
    y = y + lh
    local any = false
    for ft, need in pairs(total.items) do
        any = true
        y = matRow(v, ops, y, dw, ft, getItemName(ft) or ft,
            getText("IGUI_MBLD_HaveNeed", tostring(v.S and v.S.items[ft] or 0), tostring(need)), missing and missing[ft])
    end
    -- 硬核「原版材料」的耗材寫次數（一桶黏土漿 4 次、噴槍 10 次、焊條 20 次）
    for key, need in pairs(total.uses or EMPTY) do
        any = true
        y = matRow(v, ops, y, dw, USE_ICON[key] or key, Messages.useName(key),
            getText("IGUI_MBLD_UsesHaveNeed", tostring(v.S and v.S.uses[key] or 0), tostring(need)),
            missing and missing[B.Materials.USE .. key])
    end
    if not any then
        text(ops, getText("IGUI_MBLD_Detail_NoMaterials"), 0, y, c.text, v.font)
        y = y + lh
    end
    if #total.tools > 0 then
        y = y + 4
        text(ops, getText("IGUI_MBLD_Detail_Tools"), 0, y, c.textMuted, v.font)
        y = y + lh
        local lacking = {}
        for _, t in ipairs(tools or EMPTY) do lacking[t] = true end
        for _, t in ipairs(total.tools) do
            local col = lacking[t] and c.warning or c.text
            if lacking[t] then add(ops, { t = "icon", key = "warning", x = 0, y = y + math.floor((fh - 16) / 2), size = 16, c = c.warning }) end
            y = para(v, ops, toolName(t), 20, y, dw - 20, col)
        end
    end
    local sk, enough = skillInfo(e)
    if sk then
        y = y + 4
        if enough then y = para(v, ops, sk, 0, y, dw, c.textMuted) else y = warnLines(v, ops, sk, y, dw) end
    end
    y = y + 4
    local parts = {}
    for perk, pts in pairs(Cost.xp(costs, getSpecificPlayer(W.playerNum))) do
        local s = string.format("%.1f", pts)
        if s:sub(-2) == ".0" then s = s:sub(1, -3) end
        parts[#parts + 1] = getText("IGUI_MBLD_XpItem", getText("IGUI_perks_" .. perk), s)
    end
    local xp = #parts > 0 and getText("IGUI_MBLD_Detail_Xp", table.concat(parts, getText("IGUI_MBLD_ListSep")))
        or getText("IGUI_MBLD_Detail_NoXp")
    for _, line in ipairs(Text.wrap(xp, dw, v.font)) do
        text(ops, line, 0, y, c.textMuted, v.font)
        y = y + lh
    end
    -- 種類說明（樓梯、屋頂、燈、窗簾）放最後：預設大小的中版要捲動才看得到（使用者 2026-10-30 選詳情可以捲動），
    -- 擋得住的限制游標也會標。屋頂約一半的片不擋雨（沒有 BlockRain 也不是地板，IsoGridSquare.java:2671-2672 的
    -- hasRainBlockingTile），換一句；路燈與發光招牌（sprite 帶 streetlight）引擎只在夜裡點亮（LightingJNI.java:282-294），
    -- 本工具接發電機的補亮也照這條（Lights.lua），換一句。接水管的（sprite 帶 waterPiped：水槽、馬桶、浴缸、淋浴）
    -- 照原版搬家具沒有自來水（Place.lua 寫 canBeWaterPiped），原版「接水管」是從上一層 3×3 的裝水容器取水
    -- （IsoObject.java:2457-2508,2666-2705），停水前沒有水源也給這個選項，玩家按了以為壞掉，換一句說明
    local key = e.kind
    local p = e.spr:getProperties()
    if key == "roof" then
        if not (p:has(IsoFlagType.BlockRain) or p:has(IsoFlagType.solidfloor)) then key = "roofOpen" end
    elseif key == "light" and p:has("streetlight") then
        key = "lightStreet"
    elseif p:has(IsoFlagType.waterPiped) then
        key = "plumb"
    end
    local note = getTextOrNull("IGUI_MBLD_Note_" .. key)
    if note then
        y = y + 4
        for _, line in ipairs(Text.wrap(note, dw, v.font)) do
            text(ops, line, 0, y, c.textMuted, v.font)
            y = y + lh
        end
    end
    return y
end

-- 窄版選取列：縮圖、名稱、「1×1 · 木板 2、釘子 4」（缺的整行用警告色＋警告圖示）
local function detailRow(v, ops, e, total, missing, tools)
    local c, fh = v.colors, v.fh
    local dw, dh = v.detail.width, v.detailBox.height
    local thumb = dh - 8
    local tex = texOf(v, e.name)
    if tex then add(ops, { t = "tex", tex = tex, x = 0, y = 4, w = thumb, h = thumb }) end
    local x = thumb + GAP
    local Text = v.UI.Text
    local y = math.floor((dh - 2 * fh - 4) / 2)
    -- 只能砸、不退料的在名稱那行右邊標出來（窄版沒有完整詳情）
    local nameW = dw - x
    if Cost.refund and Cost.refund(e.kind, e.spr) == "none" then
        local s = getText("IGUI_MBLD_RefundShort_none")
        add(ops, { t = "textR", s = s, x = dw, y = y, c = c.warning, f = v.font })
        nameW = nameW - getTextManager():MeasureStringX(v.font, s) - GAP
    end
    text(ops, Text.fit(Names.of(e.name, e.kind), nameW, v.font), x, y, c.text, v.font)
    local fw, fd = footprint(e.spr)
    local parts = {}
    for ft, need in pairs(total.items) do
        parts[#parts + 1] = getText("IGUI_MBLD_RowItem", getItemName(ft) or ft, tostring(need))
    end
    for key, need in pairs(total.uses or EMPTY) do
        parts[#parts + 1] = getText("IGUI_MBLD_UseCount", Messages.useName(key), tostring(need))
    end
    for _, t in ipairs(total.tools) do parts[#parts + 1] = toolName(t) end
    local short = missing ~= nil or tools ~= nil
    local sk, enough = skillInfo(e)
    if sk and not enough then
        parts[#parts + 1] = sk
        short = true
    end
    local line = getText("IGUI_MBLD_Size", tostring(fw), tostring(fd))
    if #parts > 0 then line = line .. getText("IGUI_MBLD_Sep") .. table.concat(parts, getText("IGUI_MBLD_ListSep")) end
    if short then add(ops, { t = "icon", key = "warning", x = x, y = y + fh + 4 + math.floor((fh - 16) / 2), size = 16, c = c.warning }) end
    local tx = short and x + 20 or x
    text(ops, Text.fit(line, dw - tx, v.font), tx, y + fh + 4, short and c.warning or c.textMuted, v.font)
end

local function prepareDetail(v)
    local ops = { n = 0 }
    local name = v.selName
    local e = name and Entry.resolve(name)
    local short
    local h = v.detailBox.height -- 面板高＝內容高（至少可視高）：捲動容器照子元件下緣量捲動範圍
    if e then
        local total, costs, missing, tools = costInfo(v, e)
        local _, skillOk = skillInfo(e) -- 技能不夠也算「還缺」，和方格的缺料標示一樣（isShort）
        short = v.S ~= nil and (missing ~= nil or tools ~= nil or skillOk == false)
        if v.mode == "narrow" then
            detailRow(v, ops, e, total, missing, tools)
        else
            h = math.max(h, detailFull(v, ops, e, total, costs, missing, tools))
        end
    elseif name then
        -- 目錄裡有、現在解析不了：管理員剛關掉種類、來源或圖塊組，或規則改了（Entry.why 說是哪一個）
        -- 名稱（窄版一行）＋為什麼不能蓋，兩行；「建造」不能按的原因只寫在這裡，不能截掉
        local code, arg = Entry.why(name)
        local why = code and W.whyText(code, arg) or getText("IGUI_MBLD_Detail_Gone")
        local y = para(v, ops, Names.of(name), 0, 0, v.detail.width, v.colors.text, v.mode == "narrow" and 1 or 2)
        h = math.max(h, para(v, ops, why, 0, y, v.detail.width, v.colors.warning, math.huge)) -- 詳情會捲動，原因不截
    end
    v.detail:setHeight(h)
    -- 換了項目從頭看（拆除方式、材料在最前面）。選取有兩條路會變：方格點選（W.pump）與搜尋、篩選（applyItems
    -- 自己設 v.selName），都會走到這裡；每秒重組同一項時不動捲動位置
    if name ~= v.focusName then v.detailBox:setYScroll(0) end
    v.ops = ops
    v.focusName = name
    v.focusText = name and W.tipOf(v, name, short) or nil
    v.favBtn:setEnabled(name ~= nil)
    -- 沒給寬度建的框架按鈕 setTitle 時會照標題重算寬度（Controls.lua:260-269），排版給的寬度要設回去：
    -- 不然「移除最愛」撐寬後壓到「建造」（E2E ui-mp builder-uilang-1030en3）
    local fw = v.favBtn.width
    v.favBtn:setTitle(getText(name and Favorites.has(name) and "IGUI_MBLD_Fav_Remove" or "IGUI_MBLD_Fav_Add"))
    v.favBtn:setWidth(fw)
    v.buildBtn:setEnabled(e ~= nil)
    -- 「整套」：選著的是牆類而且湊得到兩項才能按，表的排法不同時寫「同一組」（W.setOf）。窄版只有圖示，字在提示框。
    -- 換了項目、設定或目錄（catAt：整理狀態變了、進度重整）才重算：同一組那條要排整個 tileset，這裡每秒跑
    local setKey = e and (name .. "|" .. tostring(v.digest) .. "|" .. tostring(v.catAt)) or nil
    if setKey ~= v.setKey then v.setKey, v.setInfo = setKey, setKey and W.setOf(name) or nil end
    local set = v.setInfo
    local key = set and set.button or "IGUI_MBLD_Set"
    v.setBtn:setTitle(v.mode == "narrow" and "" or getText(key))
    v.setBtn:setTooltip(getText(key .. "_Tip"))
    v.setBtn:setEnabled(set ~= nil)
    -- 管理員快捷鈕（W.layout 只在管理員的寬、中版排出來）：停用這一項的圖塊組；來源是 MOD 才能整個停用
    -- （DisabledSources 只收 MOD ID，原版的圖改用圖塊組或種類關）
    local src = e and W.sourceOf(e.tileset)
    local modSrc = src ~= nil and src ~= "vanilla" and src ~= "?"
    v.qTileset:setEnabled(e ~= nil)
    v.qSource:setEnabled(modSrc)
    v.qSource:setTooltip(src == "vanilla" and getText("IGUI_MBLD_Admin_VanillaSource") or nil)
end

-- 手把右搖桿捲詳情（使用者 2026-10-30 選）。框架只在焦點落在捲動容器裡或捲動目標上時捲（Focus.lua:1310-1323,1372），
-- 焦點在方格時不捲，這裡補上；焦點在詳情或左邊分類（navBox 裡的 NavList）時交給框架，不重複捲。門檻、速度同框架
-- （同原版 ISPanelJoypad:doRightJoystickScrolling）
local function padScroll(v)
    local F = v.UI.Focus
    if not (F and F.holdsJoypad and F.focused and getJoypadAimingAxisY and F.holdsJoypad(v.win)) then return end
    local c = F.focused()
    if c == v.detailBox or c == v.nav then return end
    local data = getJoypadData(W.playerNum)
    local axis = data and getJoypadAimingAxisY(data.id) or 0
    if axis <= 0.75 and axis >= -0.75 then return end
    local box = v.detailBox
    local room = math.max(0, (box:getScrollHeight() or 0) - box.height)
    if room <= 0 then return end
    local ms = UIManager and UIManager.getMillisSinceLastRender and UIManager.getMillisSinceLastRender() or 33.3
    local step = 20 * ms / 33.3
    local y = (box:getYScroll() or 0) - (axis > 0 and step or -step)
    box:setYScroll(math.max(-room, math.min(0, y)))
end

-- 管理員改了沙盒（種類、來源、圖塊組、成本倍率；改了 SandboxVars 會整包轉送，GameClient.java:2772-2779）：重排頁籤、
-- 來源、分類與清單。開窗時比對一次（W.open），開著時每秒比對（W.pump）
function W.syncSettings(v)
    local dg = Entry.digest()
    if v.digest == dg then return end
    if v.digest then
        -- 成本倍率可能變了：缺料標示全部重算（材料摘要沒變也要，Materials.same 管不到成本）
        v.S, v.dim, v.dimN, v.sumAt = nil, {}, 0, 0
        W.restartReplace(v) -- 成本倍率、關掉的種類或來源變了：同材料的款式重算
        W.refreshTabs(v)
        W.refreshCatalog(v)
        v.detailDirty = true
    end
    v.digest = dg
end

-- ===== 每幀：狀態列面板的 prerender（排在方格前面）=====

function W.pump(panel)
    local v = W.v
    if not v then return end
    local now = getTimestampMs()
    if v.typedAt and now - v.typedAt >= W.DEBOUNCE_MS then
        v.typedAt = nil
        W.refilter(false)
    end
    if now - (v.syncAt or 0) >= SUMMARY_MS then
        v.syncAt = now
        W.syncSettings(v)
    end
    local C = B.Catalog
    local cs = C and C.state or "ready"
    if cs ~= v.catState then
        v.catState, v.catAt = cs, now
        W.restartReplace(v) -- 整理完（或重整）才算得出全部同材料的款式
        W.refreshCatalog(v)
    elseif cs == "running" then
        local i, n = C.progress()
        local pct = (i and n and n > 0) and math.floor(i * 100 / n) or 0
        if pct ~= v.catPct then
            v.catPct = pct
            W.setStatus(v)
        end
        if now - v.catAt >= CATALOG_MS then
            v.catAt = now
            W.refreshCatalog(v)
        end
    end
    local grid = v.grid
    local idx = grid:getSelectedIndex()
    local name = idx and grid:getItems()[idx] or nil
    if name ~= v.selName then
        v.selName = name
        v.detailDirty = true
    end
    -- 材料摘要每秒重算一次（地上 3×3 的材料也算）。不靠 OnContainerUpdate：伺服器扣料、發料時客戶端不一定觸發
    -- （E2E ui-mp 1027f：蓋完以後詳情與方格還照扣料前顯示）。
    local p = getSpecificPlayer(W.playerNum)
    if p and now - v.sumAt >= SUMMARY_MS then
        local M = B.Materials
        local S = M and M.summary and M.summary(p) or nil
        v.sumAt = now
        v.detailDirty = v.detailDirty or v.selName ~= nil -- 經驗照技能等級打折，等級變了材料不一定變
        -- 大多時候沒變：沒變就留著舊的缺料標示，不清掉（清掉後要好幾幀才補回，格子會閃）
        if not (S and M.same(v.S, S)) then
            v.S = S
            v.dim, v.dimN = {}, 0
            v.detailDirty = true
            if W.st.only then
                if v.aff then v.affStale = true else W.refilter(true) end
            end
        end
    end
    if v.detailDirty then
        v.detailDirty = false
        prepareDetail(v)
    end
    v.pad = W.usingPad()
    if v.pad then padScroll(v) end
    v.padPicked = v.pad and W.st.picked or nil
    prepareVisible(v)
    if v.aff then runAffordable(v) end
    if v.rep then runReplace(v) end
end

function W.drawStatus(panel)
    local v = W.v
    if not (v and v.statusText) then return end
    local c = v.colors.textMuted
    panel:drawText(v.statusText, 0, 2, c.r, c.g, c.b, c.a or 1, v.font)
    if v.pad then
        panel:drawTextRight(v.padHint, panel.width, 2, c.r, c.g, c.b, c.a or 1, v.font)
    end
end

function W.drawDetail(panel)
    local v = W.v
    if not v then return end
    local ops, h = v.ops, panel.height
    for i = 1, ops.n do
        local o = ops[i]
        if o.y < h then
            local t, c = o.t, o.c
            if t == "text" then
                panel:drawText(o.s, o.x, o.y, c.r, c.g, c.b, c.a or 1, o.f)
            elseif t == "textR" then
                panel:drawTextRight(o.s, o.x, o.y, c.r, c.g, c.b, c.a or 1, o.f)
            elseif t == "tex" then
                panel:drawTextureScaledAspect(o.tex, o.x, o.y, o.w, o.h, 1, 1, 1, 1)
            elseif t == "icon" then
                v.UI.Icons.draw(panel, o.key, o.x, o.y, o.size, c, 1)
            elseif t == "box" then
                panel:drawRectBorder(o.x, o.y, o.w, o.h, c.a or 1, c.r, c.g, c.b)
            elseif t == "grid" then
                for r = 0, o.rows - 1 do
                    for k = 0, o.cols - 1 do
                        panel:drawRectBorder(o.x + k * o.cell, o.y + r * o.cell, o.cell + 1, o.cell + 1, c.a or 1, c.r, c.g, c.b)
                    end
                end
            end
        end
    end
end

-- 方格一格（框架 pcall 每個可見格每幀呼叫；Widgets/TileGrid.lua:184-228）：只讀 prepareVisible 備好的東西
function W.drawTile(v, el, name, x, y, w, h, state)
    local c = v.colors
    local dim = v.dim[name] == true
    local tex = v.tex[name]
    -- 缺料的格子照樣能選、能按建造，不是停用：縮圖只淡一點、名稱用次要字色（審查 1029 #6：原本 0.45 與
    -- textDisabled 量到 1.83:1、3.45:1）。缺料靠右上的警告圖示標（設計稿 DD:131）
    if tex then el:drawTextureScaledAspect(tex, x + 4, y + 4, w - 8, v.iconH, dim and 0.8 or 1, 1, 1, 1) end
    local lines = v.text[name]
    if lines then
        local col = dim and c.textMuted or c.text
        local cx, ty = x + math.floor(w / 2), y + v.iconH + 6
        for i = 1, #lines do
            el:drawTextCentre(lines[i], cx, ty, col.r, col.g, col.b, col.a or 1, v.font)
            ty = ty + v.fh + 2
        end
    end
    if dim then
        local wc = c.warning
        if not v.UI.Icons.draw(el, "warning", x + w - 18, y + 2, 16, wc, 1) then
            el:drawText("!", x + w - 10, y + 2, wc.r, wc.g, wc.b, 1, v.font)
        end
    end
    if name == v.padPicked then
        -- 手把：已選取（再按一次 A 就建造）畫 accent 雙框＋左上的勾，和焦點框分開（設計稿 DD:364-379）。
        -- 不用 warning：這個視窗的 warning 是缺料（審查 1029 #7）
        local ac = c.accent
        el:drawRectBorder(x, y, w, h, 1, ac.r, ac.g, ac.b)
        el:drawRectBorder(x + 1, y + 1, w - 2, h - 2, 1, ac.r, ac.g, ac.b)
        v.UI.Icons.draw(el, "check", x + 3, y + 3, 16, ac, 1)
    end
end

-- 方格自己的繪製後面畫空狀態（畫在父視窗會被清單的 stencil 吃掉；pitfalls.md:314-318、規格 1.2）
function W.gridRender(grid)
    local v = grid.target
    v.UI.TileGrid.render(grid)
    local lines = v.emptyTitle
    if not lines then return end
    local c = v.colors
    local cx, y = math.floor(grid.width / 2), v.emptyY
    for i = 1, #lines do
        grid:drawTextCentre(lines[i], cx, y, c.text.r, c.text.g, c.text.b, 1, v.font)
        y = y + v.fh + 2
    end
    lines = v.emptyHint
    if lines then
        local m = c.textMuted
        for i = 1, #lines do
            grid:drawTextCentre(lines[i], cx, y, m.r, m.g, m.b, 1, v.font)
            y = y + v.fh + 2
        end
    end
end

function W.focusLabel(v, name)
    if name ~= nil and name == v.focusName then return v.focusText end
    return nil
end

function W.tileTip(v, name)
    return name and W.tipOf(v, name) or nil
end

-- ===== 動作 =====

-- 管理員關掉的種類（沙盒 Kind*）：頁籤裡的種類全關就停用那個頁籤（框架 Tabs:setItemEnabled，rev 12），選著的回「全部」
function W.refreshTabs(v)
    local s = Entry.settings()
    for i = 2, #W.TABS do
        local id, on = W.TABS[i], false
        for _, k in ipairs(W.TAB_KINDS[id]) do
            if Entry.kindOn(k, s) then
                on = true
                break
            end
        end
        v.tabs:setItemEnabled(id, on)
        if not on and W.st.tab == id then
            W.st.tab = "all"
            v.tabs:setSelected("all", true)
        end
    end
end

-- 換成條件重算（開啟、目錄狀態變了、沙盒改了）：還在整理就先等，W.pump 在整理完時再叫一次
function W.restartReplace(v)
    local rp = W.st.replace
    v.rep = nil
    if not rp then return end
    rp.match, rp.count = nil, nil
    if (B.Catalog and B.Catalog.state or "ready") == "ready" then W.startReplace(v, rp) end
    W.setStatus(v)
end

-- 右鍵「換成...」（Menu.lua）：開視窗、清搜尋，頁籤切到那件的種類所在的頁籤，分類與來源回「全部」（同材料的款式
-- 不限來源），清單只列換得掉那件的同材料款式；搜尋列上方出現可關掉的條件鈕（W.clearReplace）。選一項按「建造」照常開
-- 游標，朝向先轉到換得掉的那一面（W.build）。name＝那件現在的 sprite 名稱
function W.openReplace(playerNum, name)
    local spr = Entry.sprite(name)
    local kind = spr and B.Rules.classify(spr)
    if not kind or not W.open(playerNum) then return false end
    local v, st = W.v, W.st
    st.replace = { name = name, spr = spr, kind = kind, label = Names.of(name, kind) }
    if st.set then -- 一次只開一個條件
        st.set = nil
        v.text, v.textN = {}, 0
    end
    v.search:setText("") -- 靜默，不觸發 onChange
    st.query, v.typedAt = "", nil
    -- 跨頁籤的同組（牆、柵欄在「牆」頁、門框窗框在「門窗」頁，Dismantle.GROUP）停在「全部」，不然窗框被頁籤濾掉
    local tab = "all"
    if not B.Dismantle.GROUP[kind] then
        for i = 2, #W.TABS do
            for _, k in ipairs(W.TAB_KINDS[W.TABS[i]]) do
                if k == kind and #tabKinds(W.TABS[i]) > 0 then tab = W.TABS[i] end
            end
        end
    end
    st.tab, st.cat, st.source = tab, "all", "all"
    v.tabs:setSelected(tab, true)
    v.source:setSelected("all", true)
    v.UI.Dropdown.close(v.win)
    W.refreshCats(v)
    W.restartReplace(v)
    W.layout()
    W.refilter(false)
    return true
end

-- 條件鈕的 ✕：回到一般目錄（頁籤、分類、來源照現在的）
function W.clearReplace()
    local v = W.v
    W.st.replace = nil
    if not v then return end
    v.rep = nil
    W.layout()
    W.refilter(false)
end

-- ===== 整套（設計稿 builder-hardcore-sets-1101 claim 2，使用者 2026-11-01 選 filter）=====

-- 整套與「同一組」列的種類：牆頁籤的牆類＋門窗頁籤的框。其他種類不能按「整套」
local SET_KINDS = { "wall", "post", "windowFrame", "doorFrame", "fence", "wallOverlay" }
local IS_SET_KIND = {}
for _, k in ipairs(SET_KINDS) do IS_SET_KIND[k] = true end

-- 在目錄裡（Index 那一桶有它）、沒被管理員關掉：回它的種類（Sets.of 對位置）
local function listedKind(name)
    local e = Entry.resolve(name)
    local arr = e and not W.blocked(e.tileset) and Index.bucket and Index.bucket[e.kind] and Index.bucket[e.kind][e.tileset]
    for i = 1, arr and arr.n or 0 do
        if arr[i] == name then return e.kind end
    end
    return nil
end

-- 選著的這一項的整套：{ name, list = { n, 名稱… }, at（名稱 → 套裡的位置；同一組沒有）, button（按鈕的翻譯鍵）,
-- chip（條件鈕標題） }；不是牆類、圖塊組被關、或湊不到兩項回 nil。表的排法不是原版牆的（Sets.of 回 nil）時改列
-- 同一個 tileset 的牆類，照編號排，按鈕寫「同一組」
function W.setOf(name)
    local e = Entry.resolve(name)
    if not (e and IS_SET_KIND[e.kind]) or W.blocked(e.tileset) then return nil end
    local list, at = Sets.of(name, listedKind)
    if list then
        local _, base = Sets.locate(name)
        return { name = name, list = list, at = at, button = "IGUI_MBLD_Set", chip = getText("IGUI_MBLD_Set_Chip",
            Names.tileset(e.tileset) .. getText("IGUI_MBLD_Sep") .. getText("IGUI_MBLD_Name_Num", tostring(base))) }
    end
    local rows, s = {}, Entry.settings()
    for _, k in ipairs(SET_KINDS) do
        local arr = Entry.kindOn(k, s) and Index.bucket and Index.bucket[k] and Index.bucket[k][e.tileset]
        for i = 1, arr and arr.n or 0 do rows[#rows + 1] = { key = tonumber(arr[i]:match("_(%d+)$")), name = arr[i] } end
    end
    if #rows < 2 then return nil end
    sortByKey(rows)
    list = { n = #rows }
    for i, r in ipairs(rows) do list[i] = r.name end
    return { name = name, list = list, button = "IGUI_MBLD_SetTileset",
        chip = getText("IGUI_MBLD_SetTileset_Chip", Names.tileset(e.tileset)) }
end

-- 「整套」：清單換成選著那一項的那一套（prepareDetail 算好的 v.setInfo）；頁籤、分類、來源回「全部」、清搜尋（同
-- openReplace），按條件鈕的 ✕ 回到開之前的（W.clearSet）。換頁籤、分類、來源或搜尋就離開整套、不回去（leaveSet）。
-- 一次只開一個條件：換成條件關掉
function W.openSet()
    local v, st = W.v, W.st
    local set = v and v.setInfo
    if not set then return end
    set.prev = st.set and st.set.prev or { tab = st.tab, cat = st.cat, source = st.source, query = st.query }
    st.set, st.replace, v.rep = set, nil, nil
    st.tab, st.cat, st.source, st.query, v.typedAt = "all", "all", "all", "", nil
    v.search:setText("") -- 靜默，不觸發 onChange
    v.tabs:setSelected("all", true)
    v.source:setSelected("all", true)
    v.UI.Dropdown.close(v.win)
    v.text, v.textN = {}, 0 -- 格子改寫套裡的位置
    W.refreshCats(v)
    W.layout()
    W.refilter(false)
end

-- 條件鈕的 ✕（整套）：回到開整套之前的頁籤、來源、分類與搜尋字（那個頁籤的種類全被關掉了回「全部」，refreshTabs；
-- 那個分類這個來源沒有了也回「全部」，refreshCats）
function W.clearSet()
    local v, st = W.v, W.st
    local prev = st.set and st.set.prev
    st.set = nil
    if not v then return end
    v.text, v.textN = {}, 0
    if prev then
        st.tab, st.source, st.cat, st.query = prev.tab, prev.source, prev.cat, prev.query
        v.tabs:setSelected(st.tab, true)
        W.refreshTabs(v) -- 沙盒變了自動退出時（refreshSet），原本的頁籤可能已經被關掉
        v.source:setSelected(st.source, true)
        v.search:setText(st.query) -- 靜默
        W.refreshCats(v)
    end
    W.layout()
    W.refilter(false)
end

-- 條件鈕按下：關掉開著的那個條件
function W.clearChip()
    if W.st.set then W.clearSet() else W.clearReplace() end
end

-- 玩家自己換了頁籤、分類、來源或搜尋：離開整套（不回原本的），條件鈕收起
local function leaveSet(v)
    if not W.st.set then return end
    W.st.set = nil
    v.text, v.textN = {}, 0
    W.layout()
end

-- 沙盒或目錄變了（W.refreshCatalog）：整套照原本那一項重算，被關掉的成員拿掉、重新打開的補回；湊不成了照 ✕
-- 回到開整套之前的清單
local function refreshSet(v)
    local cur = W.st.set
    if not cur then return end
    local set = W.setOf(cur.name)
    if not set then return W.clearSet() end
    set.prev = cur.prev
    W.st.set = set
    v.text, v.textN = {}, 0
    if set.chip ~= cur.chip then W.layout() end -- 整套與同一組互換（牆被關掉、又打開）：條件鈕標題跟著換
end

-- 搜尋欄填這個字（右鍵挑圖塊、吸管填完整圖塊名：清單換成它所在的那一桶並選到它，W.filter）。整套與換成條件
-- 都關掉：挑的那張不一定在套裡、也不一定換得掉那件
function W.setQuery(q)
    local v = W.v
    if not v then return end
    leaveSet(v)
    if W.st.replace then
        W.st.replace, v.rep = nil, nil
        W.layout()
    end
    v.search:setText(q) -- 靜默，不觸發 onChange
    W.st.query = q
    v.typedAt = nil
    W.refilter(false)
end

function W.refreshCats(v)
    local st = W.st
    local groups = W.categories(st.tab)
    local flat, found = {}, false
    for _, g in ipairs(groups) do
        for _, it in ipairs(g.items) do
            flat[#flat + 1] = { id = it.id, label = it.label }
            if it.id == st.cat then found = true end
        end
    end
    if not found then st.cat = "all" end
    v.nav:setGroups(groups)
    v.nav:setSelected(st.cat, true)
    v.cat:setOptions(flat)
    v.cat:setSelected(st.cat, true)
end

function W.refreshSources(v)
    local opts, tip = W.sources()
    local found = false
    for _, o in ipairs(opts) do
        if o.id == W.st.source then found = true break end
    end
    if not found then W.st.source = "all" end
    v.source:setOptions(opts)
    v.source:setSelected(W.st.source, true)
    v.source.tooltip = tip
end

function W.refreshCatalog(v)
    refreshSet(v)
    W.refreshSources(v)
    W.refreshCats(v)
    W.refilter(true)
end

function W.onTab(v, id)
    if id == W.st.tab then return end
    leaveSet(v)
    W.st.tab = id
    v.UI.Dropdown.close(v.win)
    W.refreshCats(v)
    W.refilter(false)
end

function W.setCat(id)
    local v = W.v
    if not v or id == nil or id == W.st.cat then return end
    leaveSet(v)
    W.st.cat = id
    v.nav:setSelected(id, true)
    v.cat:setSelected(id, true)
    W.refilter(false)
end

function W.setSource(id)
    if id == nil or id == W.st.source then return end
    if W.v then leaveSet(W.v) end
    W.st.source = id
    if W.v then W.refreshCats(W.v) end -- 分類的數量與圖塊組照來源算；選著的組這個來源沒有就回「全部」
    W.refilter(false)
end

function W.setOnly(checked)
    W.st.only = checked == true
    W.refilter(true)
end

function W.onQuery(text)
    W.st.query = text or ""
    if W.v then
        leaveSet(W.v)
        W.v.typedAt = getTimestampMs()
    end
end

function W.clearSearch()
    local v = W.v
    if not v then return end
    leaveSet(v)
    v.search:setText("") -- 靜默，不觸發 onChange
    W.st.query = ""
    v.typedAt = nil
    W.refilter(false)
end

function W.addRecent(name)
    local old, list = W.st.recent, { n = 1, name }
    for i = 1, old.n do
        if old[i] ~= name and list.n < RECENT_MAX then
            list.n = list.n + 1
            list[list.n] = old[i]
        end
    end
    W.st.recent = list
end

function W.toggleFavorite()
    local v = W.v
    local name = v and v.selName
    if not name then return end
    local _, saved = Favorites.toggle(name)
    if not saved then notify(getText("IGUI_MBLD_Fav_NotSaved")) end
    v.detailDirty = true
    W.refreshCats(v)
    if W.st.cat == "fav" then W.refilter(true) end
end

-- 「管理」：管理面板（Admin.lua；權限由原版沙盒封包檢查，這裡只決定看不看得到）
function W.openAdmin()
    local A = B.Admin
    if A and A.available() and A.canManage() then A.open(W.playerNum) end
end

-- 詳情的管理員快捷鈕：對所有玩家停用選著那一項的圖塊組或來源（Admin.quick 先跳確認）
function W.quickDisable(field)
    local v, A = W.v, B.Admin
    local e = v and v.selName and Entry.resolve(v.selName)
    if not (e and A and A.available() and A.canManage()) then return end
    if field == "tileset" then
        A.quick(W.playerNum, "tileset", e.tileset)
        return
    end
    local src = W.sourceOf(e.tileset)
    if src ~= "vanilla" and src ~= "?" then A.quick(W.playerNum, "source", src) end
end

-- 建造：交給 Cursor，視窗收起、直接進放置（使用者 2026-10-29：按建造後視窗應該自動關閉）；游標結束時
-- （右鍵取消、項目不能蓋）W.onCursorEnd 把視窗叫回來。手把玩家另外交還手把（原版只在沒有 UI 焦點時把按鍵交給游標，
-- JoyPadSetup.lua:323,363-366）：Window:setVisible(false) 會 Focus.releaseJoypad（Widgets/Window.lua:336-348）。
function W.build()
    local v = W.v
    local name = v and v.selName
    if not name then return end
    local C = B.Cursor
    if not (C and C.start) then
        print(LOG .. "Cursor is missing, cannot start building")
        return
    end
    W.addRecent(name)
    W.st.picked = nil
    C.onEnd = W.onCursorEnd
    v.hiddenForBuild = true
    v.win:setVisible(false)
    -- start 回 nil＝沒開游標（項目不能蓋，Cursor 已發通知），不會有 onEnd：收起的視窗要自己回來
    -- 換成條件下，朝向先轉到換得掉那件的那一面（W.startReplace 記的）
    local rp = W.st.replace
    local ok, res = pcall(C.start, W.playerNum, name, rp and rp.match and rp.match[name] or 0)
    if not ok then print(LOG .. "Cursor.start failed: " .. tostring(res)) end
    if not (ok and res) then
        W.onCursorEnd(W.playerNum)
    end
    W.refreshCats(v) -- 「最近使用」的數量
    if W.st.cat == "recent" then W.refilter(true) end
end

-- Cursor 的 deactivate 呼叫：建造時收起的視窗回來；手把玩家接回手把焦點（setVisible(true) 只接玩家 0，Window.lua:329-334；
-- 鍵盤滑鼠玩家 getJoypadData 是 nil，takeJoypad 不動作，Focus.lua:1031-1035）。放置中從 Dock 打開過視窗（W.open 清掉
-- hiddenForBuild）就不再動它。
function W.onCursorEnd(playerNum)
    local v = W.v
    if not (v and v.hiddenForBuild) then return end
    v.hiddenForBuild = false
    v.win:setVisible(true)
    v.win:bringToTop()
    local F = v.UI.Focus
    if F and F.takeJoypad and not (F.holdsJoypad and F.holdsJoypad(v.win)) then F.takeJoypad(v.win, playerNum or 0) end
end

-- 吸管（設計稿 builder-hardcore-sets-1101 claim 3，使用者 2026-11-01 選 button）：視窗收起，點世界裡一格（Menu.pickAt：
-- 一張能蓋就選到它，好幾張跳出右鍵「挑圖塊」同一份清單），選到或右鍵取消時視窗回來。手把不開（Cursor.startPick 回 nil，
-- 按鈕也不排出來）
function W.startPick()
    local v, C, M = W.v, B.Cursor, B.Menu
    if not (v and C and C.startPick and M and M.pickAt) then return end
    local pn = W.playerNum
    local lines = { getText("IGUI_MBLD_Pick_Label"), getText("IGUI_MBLD_Pick_Many"),
        getText("IGUI_MBLD_Pick_HintClick") .. getText("IGUI_MBLD_HintSep") .. getText("IGUI_MBLD_HintCancel") }
    local function back() W.onCursorEnd(pn) end
    local o
    o = C.startPick(pn, {
        preview = function(x, y, _, _, z) return { cells = { { x, y, z } }, lines = lines } end,
        release = function(x, y, _, _, z)
            back()
            M.pickAt(pn, getCell():getGridSquare(x, y, z))
        end,
        -- 右鍵、換了別的游標：視窗回來。被建造游標取代（吸管開著時從 Dock 開視窗按「建造」，Cursor.start 設 replaced）
        -- 時不叫：W.build 剛把視窗收起
        cancel = function() if not (o and o.replaced) then back() end end,
    })
    if not o then return end
    -- 開游標時舊的建造游標先收掉（它叫 W.onCursorEnd），所以開好才收視窗
    v.hiddenForBuild = true
    v.win:setVisible(false)
end

-- 方格 onPick：滑鼠點、Enter、Space、手把 A（方向鍵只移游標，不觸發；Widgets/TileGrid.lua:26-31）
function W.onPick(v, name)
    if name == nil then return end
    if W.usingPad() and W.st.picked == name then
        W.build() -- 同一格再按一次 A＝建造（設計稿 DD:371）
        return
    end
    W.st.picked = name
end

-- 手把 Y：加入／移除最愛（框架 Focus 不處理 X、Y，Focus.lua:1113）；其他鍵照框架
function W.onJoypadDown(win, button, joypadData)
    if Joypad and button == Joypad.YButton then
        W.toggleFavorite()
        return
    end
    W.v.UI.Window.onJoypadDown(win, button, joypadData)
end

-- ===== 建窗與版面 =====

-- 方格：一排 W.st.perRow 格，格寬＝方格寬扣掉框架一律預留的 12px 捲軸後平分（TileGrid.lua:58,71-77）。框架只在 new
-- 收 tileW、沒有改格寬的 API（TileGrid.lua:338-366；ARCH §3.22），所以格寬變了（拖滑桿、拉視窗）就換一個新方格：
-- 清單、選取、第一列的第一格與焦點搬過去；缺料、最愛、貼圖存在 v 上照用。拉視窗時每次 onResize 都可能換，不等大小
-- 穩定：多的只是一個元件，名稱照新格寬重新斷行本來就每次發生（prepareVisible 有時間預算），等穩定反而會先閃一下
-- 舊格寬算出的格數再跳回來。
local function gridTileW(w)
    return math.max(1, math.floor((w - 12) / W.st.perRow))
end

function W.placeGrid(v, x, y, w, h)
    local old, tw = v.grid, gridTileW(w)
    if old and tw == v.gridTW then
        if old.width ~= w or old.height ~= h then old:resize(w, h) end
        old:setX(x)
        old:setY(y)
        return
    end
    local UI, win = v.UI, v.win
    local g = UI.TileGrid.new({ x = x, y = y, width = w, height = h, tileW = tw, tileH = v.tileH, theme = v.theme,
        target = v, label = getText("IGUI_MBLD_Grid"), drawTile = W.drawTile,
        onPick = function(target, name) MinidoracatBuilder.Window.onPick(target, name) end,
        focusLabel = function(target, name) return MinidoracatBuilder.Window.focusLabel(target, name) end,
        tooltip = function(target, name) return MinidoracatBuilder.Window.tileTip(target, name) end })
    g.render = W.gridRender
    v.grid, v.gridTW = g, tw
    win:addChild(g)
    -- 清除搜尋鈕畫在方格上：方格換新的以後要再排到它後面，不然被方格蓋住、點不到
    win:removeChild(v.clearBtn)
    win:addChild(v.clearBtn)
    if not old then return end
    local F = UI.Focus
    local focused = F and F.focused and F.focused() == old
    local ring = focused and F.isKeyboardFocused and F.isKeyboardFocused(old)
    local idx = old:getSelectedIndex()
    local before = math.floor(old.scrollOffset / old.rowHeight) * old:perRow() -- 第一列第一格前面有幾格
    old:setVisible(false) -- 滑鼠停在舊方格時的提示框：owner 看不見就自己收掉（ISToolTip.lua:57-61）
    win:removeChild(old)
    g:setItems(old:getItems())
    g:setSelectedIndex(idx)
    g:setScrollOffset(math.floor(before / g:perRow()) * g.rowHeight)
    if focused then
        F.focusControl(g, ring)
        if idx then g:scrollToIndex(idx) end
    end
end

function W.layout()
    local v = W.v
    if not v then return end
    local win, s = v.win, v.s
    local ww, wh = win.width, win.height
    local mode = "narrow"
    if wh >= 420 * s then
        if ww >= 760 * s then mode = "wide" elseif ww >= 560 * s then mode = "medium" end
    end
    if mode ~= v.mode then v.UI.Dropdown.close(win) end
    v.mode = mode
    local inner = ww - 2 * PAD
    local y = win:contentTop() + GAP
    -- 條件鈕（換成 W.openReplace、整套 W.openSet，一次只開一個）：搜尋列上方一列；寬度照標題、放不下就截字
    local rp, set, chip = W.st.replace, W.st.set, v.chip
    chip:setVisible(rp ~= nil or set ~= nil)
    if rp or set then
        chip:setTitle(set and set.chip or getText("IGUI_MBLD_Replace_Chip", rp.label))
        chip:setTooltip(getText(set and "IGUI_MBLD_Set_ChipTip" or "IGUI_MBLD_Replace_ChipTip"))
        chip:fitWidth()
        if chip.width > inner then chip:setWidth(inner) end
        chip:setX(PAD)
        chip:setY(y)
        y = y + chip.height + GAP
    end
    -- 第一列：吸管（手把不排）＋搜尋＋來源（＋只看能蓋的）
    local rowH = math.max(v.search.height, v.source.height)
    local pick = not W.usingPad()
    v.pickBtn:setVisible(pick)
    local pw = pick and (v.pickBtn.width + GAP) or 0
    local ddW = math.max(math.floor(140 * s), math.min(math.floor(240 * s), math.floor(inner * 0.3)))
    local cbW = v.only.width
    local cbRow1 = mode ~= "narrow" and inner - pw - ddW - cbW - 2 * GAP >= math.floor(200 * s)
    local searchW = inner - pw - ddW - GAP - (cbRow1 and (cbW + GAP) or 0)
    if pick then
        v.pickBtn:setX(PAD)
        v.pickBtn:setY(y + math.floor((rowH - v.pickBtn.height) / 2))
    end
    v.search:setX(PAD + pw)
    v.search:setY(y)
    v.search:setWidth(searchW)
    v.source:setX(PAD + pw + searchW + GAP)
    v.source:setY(y)
    v.source:setWidth(ddW)
    if cbRow1 then
        v.only:setX(PAD + inner - cbW)
        v.only:setY(y + math.floor((rowH - v.only.height) / 2))
    end
    y = y + rowH + GAP
    -- 第二列：一排幾格（使用者 2026-10-29：搜尋列下方）；「只看能蓋的」放不進第一列、放得進這一列時排在滑桿右邊；
    -- 最右邊是「管理」：只有能改沙盒的玩家看得到（Admin.canManage），不排就不進焦點順序（隱藏的元件 Focus 跳過）
    local pr, ab, A = v.rowSlider, v.adminBtn, B.Admin
    local admin = A ~= nil and A.available() and A.canManage()
    ab:setVisible(admin)
    local abW = admin and (ab.width + GAP) or 0
    local cbRowS = not cbRow1 and inner - pr.width - GAP - abW >= cbW
    local hS = cbRowS and math.max(pr.height, v.only.height) or pr.height
    if admin then hS = math.max(hS, ab.height) end
    pr:setX(PAD)
    pr:setY(y + math.floor((hS - pr.height) / 2))
    if cbRowS then
        v.only:setX(PAD + pr.width + GAP)
        v.only:setY(y + math.floor((hS - v.only.height) / 2))
    end
    if admin then
        ab:setX(PAD + inner - ab.width)
        ab:setY(y + math.floor((hS - ab.height) / 2))
    end
    y = y + hS + GAP
    local cbPlaced = cbRow1 or cbRowS
    -- 第三列：種類頁籤（＋中窄版的分類下拉）
    v.tabs:setX(PAD)
    v.tabs:setY(y)
    local h2 = v.tabs.height
    local catW = inner - v.tabs.width - GAP
    local catRow2 = mode ~= "wide" and catW >= math.floor(140 * s)
    v.cat:setVisible(mode ~= "wide")
    if catRow2 then
        v.cat:setX(PAD + v.tabs.width + GAP)
        v.cat:setY(y)
        v.cat:setWidth(catW)
        h2 = math.max(h2, v.cat.height)
    end
    y = y + h2 + GAP
    -- 第四列：放不下的分類下拉與勾選
    local catRow3 = mode ~= "wide" and not catRow2
    if catRow3 or not cbPlaced then
        local x, h3 = PAD, 0
        if catRow3 then
            local w3 = cbPlaced and inner or (inner - cbW - GAP)
            v.cat:setX(x)
            v.cat:setY(y)
            v.cat:setWidth(w3)
            x, h3 = x + w3 + GAP, v.cat.height
        end
        if not cbPlaced then
            v.only:setX(x)
            v.only:setY(y)
            h3 = math.max(h3, v.only.height)
        end
        y = y + h3 + GAP
    end
    -- 主體與狀態列
    local statusH = v.fh + 4
    v.status:setX(PAD)
    v.status:setY(wh - PAD - statusH)
    v.status:setWidth(inner - 16) -- 右下角留給縮放把手
    v.status:setHeight(statusH)
    local bodyH = math.max(40, wh - PAD - statusH - GAP - y)
    local btnH = v.buildBtn.height
    local gx, gw, gh = PAD, inner, bodyH
    v.navBox:setVisible(mode == "wide")
    if mode == "wide" then
        local navW = math.max(math.floor(150 * s), math.min(math.floor(220 * s), math.floor(inner * 0.2)))
        v.navBox:setX(PAD)
        v.navBox:setY(y)
        v.navBox:setWidth(navW)
        v.navBox:setHeight(bodyH)
        v.nav:setWidth(v.navBox:contentWidth())
        gx, gw = PAD + navW + GAP, inner - navW - GAP
    end
    local quick = admin and mode ~= "narrow"
    v.qTileset:setVisible(quick)
    v.qSource:setVisible(quick)
    if mode ~= "narrow" then
        local dw = mode == "wide" and math.max(math.floor(220 * s), math.floor(inner * 0.28))
            or math.max(math.floor(200 * s), math.floor(inner * 0.38))
        gw = gw - dw - GAP
        local dx = PAD + inner - dw
        local by = y + bodyH - btnH
        -- 「整套」排在最愛、建造上面一列；管理員快捷鈕再上面：兩顆並排放得下（各自的標題寬）就一列，不然各占一列
        local sy = by - btnH - GAP
        v.setBtn:setX(dx)
        v.setBtn:setY(sy)
        v.setBtn:setWidth(dw)
        local qh = 0
        if quick then
            local qT, qS, half = v.qTileset, v.qSource, math.floor((dw - GAP) / 2)
            local one = v.qTW <= half and v.qSW <= half
            qh = one and (btnH + GAP) or 2 * (btnH + GAP)
            local qy = sy - qh
            qT:setX(dx)
            qT:setY(qy)
            qT:setWidth(one and half or dw)
            qS:setX(one and (dx + half + GAP) or dx)
            qS:setY(one and qy or (qy + btnH + GAP))
            qS:setWidth(one and (dw - half - GAP) or dw)
        end
        v.detailBox:setX(dx)
        v.detailBox:setY(y)
        v.detailBox:setWidth(dw)
        v.detailBox:setHeight(math.max(btnH, bodyH - 2 * (btnH + GAP) - qh))
        v.detail:setWidth(v.detailBox:contentWidth())
        -- 最愛按鈕至少放得下較長的標題（v.favW），建造按鈕拿剩下的，不小於自己的標題寬
        local bw = math.min(dw - GAP - v.buildW, math.max(math.floor((dw - GAP) / 2), v.favW))
        v.favBtn:setX(dx)
        v.favBtn:setY(by)
        v.favBtn:setWidth(bw)
        v.buildBtn:setX(dx + bw + GAP)
        v.buildBtn:setY(by)
        v.buildBtn:setWidth(dw - bw - GAP)
    else
        local rowHt = math.max(math.floor(56 * s), 2 * v.fh + 12, btnH + 8)
        gh = bodyH - rowHt - GAP
        local ry = y + gh + GAP
        local by = ry + math.floor((rowHt - btnH) / 2)
        local bx = PAD + inner - v.buildW
        v.buildBtn:setX(bx)
        v.buildBtn:setY(by)
        v.buildBtn:setWidth(v.buildW)
        v.favBtn:setX(bx - GAP - v.favW)
        v.favBtn:setY(by)
        v.favBtn:setWidth(v.favW)
        -- 「整套」在最愛左邊，只有圖示（標題在 prepareDetail 清掉）
        local sx = bx - GAP - v.favW - GAP - btnH
        v.setBtn:setX(sx)
        v.setBtn:setY(by)
        v.setBtn:setWidth(btnH)
        v.detailBox:setX(PAD)
        v.detailBox:setY(ry)
        v.detailBox:setWidth(math.max(40, sx - GAP - PAD))
        v.detailBox:setHeight(rowHt)
        v.detail:setWidth(v.detailBox:contentWidth())
    end
    -- 最小尺寸也要放得下一整排格子：多了滑桿那一列、格子多一行名稱以後，窄版在 320×縮放的最小高度只剩 68 px
    -- （E2E ui-mp `builder-ui-1029c` minSize，一格 104）。差多少就把最小高度加多少，視窗比它矮就拉高再排一次；
    -- 拉不高（框架照畫面夾住）就照現在的排，不再遞迴
    if gh < v.tileH then
        win.minHeight = math.max(win.minHeight, wh + v.tileH - gh)
        win:setHeight(win.minHeight)
        if win.height ~= wh then return W.layout() end
    end
    W.placeGrid(v, gx, y, gw, gh)
    v.detailDirty = true
    prepareEmpty(v)
    local F = v.UI.Focus
    if F and F.invalidate then F.invalidate(win) end
end

local function button(v, title, style, onClick)
    local b = v.UI.Button.new({ x = 0, y = 0, title = title, style = style, theme = v.theme, onClick = onClick })
    b:fitWidth()
    v.win:addChild(b)
    return b
end

function W.create(UI)
    local st = W.st
    local theme = UI.Theme.create({ variant = "dark" })
    local font = UIFont.Small
    local tm = getTextManager()
    local fh = tm:getFontHeight(font)
    local s = fh / 16 -- 字級比例：門檻與尺寸乘它（規格 1.2）
    local pn = W.playerNum
    -- 用該玩家的畫面範圍，不用 getCore() 全螢幕（分割畫面；LuaManager.java:3908-3934）
    local sx, sy = getPlayerScreenLeft(pn), getPlayerScreenTop(pn)
    local sw, sh = getPlayerScreenWidth(pn), getPlayerScreenHeight(pn)
    -- 靠右、不越過畫面中央：角色在畫面中央；放置時視窗收起，但放置中可以從 Dock 再打開，那時不能蓋住要蓋的地方
    -- （1080p 實機用 0.62 時視窗從中央左邊開始，虛影整個被蓋住）。寬版要 760*s，半個畫面放不下就用中版。
    local want = math.max(math.floor(760 * s), math.floor(sw * 0.47))
    local half = math.floor(sw / 2) - 20
    if want > half then want = math.max(half, math.floor(560 * s)) end
    local w = math.max(math.floor(360 * s), math.min(sw - 40, want))
    local h = math.max(math.floor(320 * s), math.min(sh - 80, math.max(math.floor(420 * s), math.floor(sh * 0.7))))
    local v = { UI = UI, theme = theme, colors = theme.colors, font = font, fh = fh, s = s,
        tex = {}, texN = 0, text = {}, textN = 0, dim = {}, dimN = 0, ops = EMPTY, sumAt = 0 }
    v.iconH = math.floor(56 * s)
    v.tileH = 4 + v.iconH + 4 + 2 * fh + 2 + 6 -- 縮圖＋兩行名稱（W.drawTile）
    st.perRow = st.perRow or W.loadPerRow() -- 第一次開窗才讀檔
    local opts = { x = math.max(sx, sx + sw - w - 20), y = sy + 60, width = w, height = h,
        title = getText("IGUI_MBLD_Title"), icon = "house", theme = theme, resizable = true,
        minWidth = math.floor(360 * s), minHeight = math.floor(320 * s),
        onResize = function() MinidoracatBuilder.Window.layout() end,
        onClose = function() MinidoracatBuilder.Window.onClosed() end }
    if UI.CAPABILITIES.opaqueWindow == true then opts.opaque = true end -- 疊在別的視窗上時看得清楚（SH/Client.lua:44-47）
    local win = UI.Window.new(opts)
    win.onEscape = function()
        win:close()
        return true
    end
    win.onJoypadDown = W.onJoypadDown
    v.win = win
    W.v = v

    -- 狀態列先加：它的 prerender 是每幀的幫浦，要排在方格前面
    local status = ISPanel:new(PAD, 0, 100, fh + 4)
    status:initialise()
    status.background = false
    status.prerender = W.pump
    status.render = W.drawStatus
    win:addChild(status)
    v.status = status

    -- 條件鈕（換成、整套；排在搜尋前面：焦點順序照畫面由上而下）：chip 樣式選中狀態＋關閉圖示，按了關掉那個條件
    v.chip = UI.Button.new({ x = PAD, y = 0, title = "", icon = "close", style = "chip", active = true, theme = theme,
        tooltip = getText("IGUI_MBLD_Replace_ChipTip"), onClick = function() MinidoracatBuilder.Window.clearChip() end })
    v.chip:setVisible(false)
    win:addChild(v.chip)
    v.search = UI.TextField.new({ x = PAD, y = 0, width = 200, text = st.query, placeholder = getText("IGUI_MBLD_Search"),
        clearButton = true, theme = theme, onChange = function(_, t) MinidoracatBuilder.Window.onQuery(t) end })
    -- 吸管（W.startPick）：搜尋欄左邊的方形圖示鈕，先加（焦點順序由左而右）；手把不排（W.layout）
    local sh = v.search.height
    v.pickBtn = UI.Button.new({ x = PAD, y = 0, width = sh, height = sh, title = "", icon = "locate", theme = theme,
        tooltip = getText("IGUI_MBLD_Pick_Tip"), onClick = function() MinidoracatBuilder.Window.startPick() end })
    win:addChild(v.pickBtn)
    win:addChild(v.search)
    v.source = UI.Dropdown.new({ x = 0, y = 0, width = 160, options = { { id = "all", label = getText("IGUI_MBLD_Source_All") } },
        selected = "all", maxRows = 12, theme = theme, target = v,
        onChange = function(_, id) MinidoracatBuilder.Window.setSource(id) end })
    win:addChild(v.source)
    v.only = UI.Checkbox.new({ x = 0, y = 0, label = getText("IGUI_MBLD_OnlyAffordable"), checked = st.only, theme = theme,
        tooltip = getText("IGUI_MBLD_OnlyAffordable_Tip"), onChange = function(_, c) MinidoracatBuilder.Window.setOnly(c) end })
    win:addChild(v.only)
    -- 一排幾格：拖動時每換一格就重排（W.setPerRow）；整列是一個焦點目標，左右鍵與手把十字鍵調整（Controls.lua:1313-1316）
    v.rowSlider = UI.SliderRow.new({ x = PAD, y = 0, width = math.floor(200 * s), label = getText("IGUI_MBLD_PerRow"),
        min = W.PER_ROW_MIN, max = W.PER_ROW_MAX, step = 1, value = st.perRow, theme = theme,
        format = function(n) return getText("IGUI_MBLD_PerRow_Value", tostring(math.floor(n + 0.5))) end,
        onChange = function(_, n) MinidoracatBuilder.Window.setPerRow(n) end })
    win:addChild(v.rowSlider)
    local tabItems = {}
    for i, id in ipairs(W.TABS) do tabItems[i] = { id = id, label = getText("IGUI_MBLD_Tab_" .. id) } end
    -- 視窗裡第一個 Tabs：手把 LB／RB 切它（Widgets/Window.lua:315-325）
    v.tabs = UI.Tabs.new({ x = PAD, y = 0, items = tabItems, selected = st.tab, theme = theme, target = v,
        onSelect = function(_, id) MinidoracatBuilder.Window.onTab(v, id) end })
    win:addChild(v.tabs)
    win.minWidth = math.max(win.minWidth, v.tabs.width + 2 * PAD) -- 頁籤不縮字，放不下會畫出框外（SH/AdminPanel.lua:311）
    v.cat = UI.Dropdown.new({ x = 0, y = 0, width = 160, options = { { id = "all", label = getText("IGUI_MBLD_Cat_All") } },
        selected = "all", maxRows = 12, theme = theme, target = v,
        onChange = function(_, id) MinidoracatBuilder.Window.setCat(id) end })
    win:addChild(v.cat)
    v.navBox = UI.ScrollPanel.new({ x = PAD, y = 0, width = 180, height = 200, theme = theme })
    win:addChild(v.navBox)
    v.nav = UI.NavList.new({ x = 0, y = 0, width = v.navBox:contentWidth(), groups = {}, theme = theme, target = v,
        onSelect = function(_, id) MinidoracatBuilder.Window.setCat(id) end })
    v.navBox:addChild(v.nav)
    v.clearBtn = button(v, getText("IGUI_MBLD_ClearSearch"), nil, function() MinidoracatBuilder.Window.clearSearch() end)
    v.clearBtn:setVisible(false)
    -- 詳情放在捲動容器裡（使用者 2026-10-30 選：預設大小畫不下燈的說明時捲動看）：面板高＝內容高（prepareDetail 設），
    -- 容器照子元件下緣量捲動範圍、裁掉可視區外（框架 ScrollPanel §3.18）。裡面沒有焦點目標，框架把容器本身當
    -- kind="scroll" 目標（方向鍵、PgUp／PgDn 捲）
    v.detailBox = UI.ScrollPanel.new({ x = 0, y = 0, width = 100, height = 100, theme = theme })
    win:addChild(v.detailBox)
    local detail = ISPanel:new(0, 0, 100, 100)
    detail:initialise()
    detail.background = false
    detail.render = W.drawDetail
    v.detailBox:addChild(detail)
    v.detail = detail
    -- 「整套」（W.openSet）：寬、中版在最愛、建造上面一列，窄版是最愛左邊的圖示鈕；標題、提示、能不能按照選著的項目
    -- （prepareDetail）。給了寬度，setTitle 不會照標題重算寬度
    v.setBtn = UI.Button.new({ x = 0, y = 0, width = 100, title = getText("IGUI_MBLD_Set"), icon = "layers", theme = theme,
        tooltip = getText("IGUI_MBLD_Set_Tip"), onClick = function() MinidoracatBuilder.Window.openSet() end })
    v.setBtn:setEnabled(false)
    win:addChild(v.setBtn)
    -- 最愛按鈕寬度照兩種標題較長的那個（窄版要固定寬）
    v.favBtn = button(v, getText("IGUI_MBLD_Fav_Remove"), nil, function() MinidoracatBuilder.Window.toggleFavorite() end)
    local favW = v.favBtn.width
    v.favBtn:setTitle(getText("IGUI_MBLD_Fav_Add"))
    v.favBtn:fitWidth()
    v.favW = math.max(favW, v.favBtn.width)
    v.buildBtn = button(v, getText("IGUI_MBLD_Build"), "primary", function() MinidoracatBuilder.Window.build() end)
    v.buildW = v.buildBtn.width
    v.padHint = getText("IGUI_MBLD_PadHint")
    -- 「管理」與詳情的管理員快捷鈕：建好先藏著，W.layout 只在管理員時排出來（Admin.lua）。快捷鈕用有框的預設樣式
    -- （審查 1101 #9：ghost 沒有框，看起來像說明文字）；不 setTitle，W.layout 給的寬度不會被重算
    v.adminBtn = UI.Button.new({ x = 0, y = 0, title = getText("IGUI_MBLD_Admin_Button"), icon = "settings", style = "ghost",
        theme = theme, tooltip = getText("IGUI_MBLD_Admin_ButtonTip"),
        onClick = function() MinidoracatBuilder.Window.openAdmin() end })
    v.adminBtn:fitWidth()
    win:addChild(v.adminBtn)
    v.qTileset = button(v, getText("IGUI_MBLD_Admin_DisableTileset"), nil,
        function() MinidoracatBuilder.Window.quickDisable("tileset") end)
    v.qSource = button(v, getText("IGUI_MBLD_Admin_DisableSource"), nil,
        function() MinidoracatBuilder.Window.quickDisable("source") end)
    v.qTW, v.qSW = v.qTileset.width, v.qSource.width

    win:addToUIManager()
    if ISLayoutManager and ISLayoutManager.RegisterWindow then -- addToUIManager 之後（QU/Window.lua:240-243）
        pcall(ISLayoutManager.RegisterWindow, "MinidoracatBuilderWindow", UI.Window, win)
    end
    -- 開窗的寬度也要放得下頁籤：minWidth 只擋玩家拉窄，算出來的寬度（或上次存的）可能更窄（1366 寬時 EN 頁籤要 750 px）
    if win.width < win.minWidth then
        local nw = math.min(sw - 40, win.minWidth)
        win:setX(math.max(sx, sx + sw - nw - 20))
        win:setWidth(nw)
    end
    W.layout()
    v.catState = B.Catalog and B.Catalog.state or "ready"
    v.catAt = getTimestampMs()
    W.restartReplace(v) -- 框架換版重建視窗時，留著的換成條件重算
    W.refreshTabs(v)
    W.refreshCatalog(v)
    return v
end

-- 建到一半出錯：收掉半成品，下次重建
local function discard()
    local v = W.v
    W.v = nil
    if v and v.win then
        pcall(function()
            v.win:setVisible(false)
            v.win:removeFromUIManager()
        end)
    end
end

function W.visible()
    return W.v ~= nil and W.v.win:getIsVisible()
end

function W.open(playerNum)
    local UI = W.ui()
    if UI == nil then
        notify(getText("IGUI_MBLD_NeedFramework"))
        return false
    end
    W.playerNum = playerNum or 0
    Favorites.ensure()
    local v = W.v
    if v == nil or v.UI ~= UI then
        discard()
        local ok, err = pcall(W.create, UI)
        if not ok then
            print(LOG .. "window build failed: " .. tostring(err))
            discard()
            return false
        end
        v = W.v
    end
    v.hiddenForBuild = false
    v.sumAt = 0 -- 下一幀就重算材料
    W.syncSettings(v)
    v.win:setVisible(true) -- 框架 Window：Focus.onFocus＋takeJoypad（Widgets/Window.lua:336-348）
    v.win:bringToTop()
    return true
end

function W.close()
    local v = W.v
    if not v then return end
    v.hiddenForBuild = false
    if v.win:getIsVisible() then v.win:close() end
end

function W.toggle(playerNum)
    if W.visible() then W.close() else W.open(playerNum) end
end

function W.onClosed()
    local v = W.v
    if v then v.UI.Dropdown.close(v.win) end -- 只關這個視窗的下拉（ARCH §3.17）
end

-- ===== 入口：Dock、按鍵、ModOptions =====

W.showDock = W.showDock ~= false

local function tick(o, id)
    local t = o:getOption(id)
    return t == nil or t:getValue() ~= false
end

function W.readOptions()
    if W.options then W.showDock = tick(W.options, "ShowDock") end
end

function W.applyOptions()
    W.readOptions()
    local UI = W.ui({ "dock" })
    if UI and UI.Dock then UI.Dock.refresh() end
end

-- Dock 回呼每幀被 pcall：只讀快取，不配置（UI ARCH §3.16）。入口圖照家族定案用彩色「遊戲物品風」（UI ARCH 第 1004 行；
-- 使用者 2026-10-29 選鎚子＋手鋸，生成紀錄在 MinidoracatUIFor42 scripts/dock/dock-icons-source.json）；讀不到圖時 Dock 改畫 iconKey
W.dockSpec = {
    id = "builder",
    order = 80,
    icon = "media/ui/MinidoracatBuilder/dock_build.png",
    iconKey = "house",
    bind = W.BIND,
    label = function() return MinidoracatBuilder.Window.dockLabel end,
    onClick = function() MinidoracatBuilder.Window.toggle(0) end,
    isAvailable = function() return MinidoracatBuilder.Window.showDock end,
}

function W.registerDock()
    W.dockLabel = getText("IGUI_MBLD_Title")
    local UI = W.ui({ "dock" })
    W.docked = UI ~= nil and UI.Dock ~= nil and UI.Dock.register(W.dockSpec) == true
    return W.docked
end

-- 預設不綁：家族主鍵盤沒有四項全過的空單鍵（FD repos.md:66；QU/Entry.lua:96-101 同法）
function W.initBinds()
    if keyBinding == nil then return end
    table.insert(keyBinding, { value = "[MinidoracatBuilder]" })
    table.insert(keyBinding, { value = W.BIND, key = (Keyboard and Keyboard.KEY_NONE) or 0 })
end

function W.onKeyPressed(key)
    if key == nil or key == 0 then return end
    if key == getCore():getKey(W.BIND) then W.toggle(0) end
end

if first then
    if PZAPI and PZAPI.ModOptions then
        local o = PZAPI.ModOptions:create("MinidoracatBuilderFor42", "UI_MinidoracatBuilder_Options")
        o:addTickBox("ShowDock", "UI_MinidoracatBuilder_ShowDock", true, "UI_MinidoracatBuilder_ShowDock_tooltip")
        o.apply = function() MinidoracatBuilder.Window.applyOptions() end
        W.options = o
        -- 框架 rev 23 備份：載入時、原版讀設定之前呼叫（UI AGENTS 契約 7；QU/Entry.lua:59-66）
        local UI = W.ui({ "modOptionsBackup" })
        if UI and UI.ModOptionsBackup then UI.ModOptionsBackup.protect(o) end
    end
    -- 框架 rev 24 更新概要：玩家更新後第一次進遊戲，右上角跳這版的重點（UI AGENTS 契約 8）。release_train.py ready 用
    -- regex 讀這段：四欄寫字面字串、一欄一行；這版寫了新概要才把 since 改成本版（家族 conventions.md「遊戲內更新概要」）
    local news = W.ui({ "whatsNew" })
    if news and news.WhatsNew then
        news.WhatsNew.register({
            modId = "MinidoracatBuilderFor42",
            since = "0.3.0",
            name = "UI_MinidoracatBuilder_Options",
            text = "IGUI_MBLD_WhatsNew",
        })
    end
    Events.OnGameBoot.Add(function() MinidoracatBuilder.Window.initBinds() end)
    Events.OnKeyPressed.Add(function(key) MinidoracatBuilder.Window.onKeyPressed(key) end)
    Events.OnGameStart.Add(function()
        MinidoracatBuilder.Window.readOptions()
        MinidoracatBuilder.Window.registerDock()
    end)
end

return W
