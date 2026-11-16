-- 屋頂助手：認整套屋頂片（Roof.family、Roof.gableFamily），照形狀排出整個屋頂的規劃片（Roof.layout）。不碰介面
-- （RoofPanel.lua）。只在客戶端：辨識要比貼圖外形，伺服器沒有貼圖；排出來的片照一般規劃片一片片付料蓋。
-- 認整套＝「編號模板位置＋外形」：原版的屋頂片照官方建築編輯器的固定模板排，MOD 會整個平移或自己排，所以先照模板位置
-- 找候選、每片都要存在而且種類對，再比外形（只看屬性、只看編號、只比外形都不行；離線量測 roofproto-20261116）。
-- 排法照建築編輯器的規則自己寫（30 度：所有片放在同一層、每 6 格升一層、屋脊與四角錐頂只有奇數跨距的片、山牆是牆片；
-- 45 度：每 3 格升一層，只有朝南、朝東的坡面有片，朝北、朝西那半邊補天花板片，跨距中間超過 3 格的鋪平頂片在上一層）。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Rules"

MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local Roof = B.Roof or {}
B.Roof = Roof
local Entry, Rules = B.Entry, B.Rules

local STEP = 8        -- 外形每 8 px 取一點（同 Cursor.mirror 的 maskDiff，不翻轉）
local MAX_NUM = 1023  -- 一個圖塊組掃到第幾號

-- 模板：片種 → 相對基準的編號。每列 { 片種字首, 起點, 1＝編號 1..n 往後排／-1＝倒著排（n 在起點）, n }；n＝0：片種就是字首、一片
local function rows(list)
    local t = {}
    for _, r in ipairs(list) do
        local key, at, dir, n = r[1], r[2], r[3], r[4] or 6
        if n == 0 then t[key] = at end
        for k = 1, n do t[key .. k] = dir > 0 and at + k - 1 or at + n - k end
    end
    return t
end

-- 每一族：ref＝原版樣板組（基準 0）、tol＝外形容許差（512 點裡不同的點；離線量的同片種跨款式最大差與不同片種最小差之間）、
-- rise＝幾格升一層、maxSpan＝雙斜與四坡的跨距上限、off＝片種位移、core＝認整套要全部對上的片、shapes＝做得出的形狀、
-- key＝排法用的角色 → 片種字首、gable＝山牆（牆的圖塊組，本 MOD 目錄是「牆 › 山牆與斜牆」）的模板。
-- 30 度：11 款原版模板全部相同（90 片）。山牆 38 款相同（36 片），原版非燒毀款的外形完全一樣（差 0），不同片種最近只差 6 點
-- （Fall 與 Peak），所以容許取 3；燒毀款（walls_exterior_roofs_30_burnt_01 差到 49）認不出（temp/impl-100/p2/gable_tol.py）
Roof.FAM = {
    ["30"] = {
        ref = "roofs_30_01", tol = 16, rise = 6, maxSpan = 11, kind = "roof",
        off = rows({ { "S", 0, 1 }, { "E", 8, -1 }, { "W", 16, 1 }, { "N", 24, -1 },
            { "INW", 32, 1 }, { "ISW", 40, -1 }, { "ISE", 48, 1 }, { "INE", 56, -1 },
            { "OSE", 64, 1 }, { "ONE", 72, -1 }, { "OSW", 80, 1 }, { "ONW", 88, -1 },
            { "PNS", 96, 1 }, { "PWE", 104, -1 }, { "Q", 112, 1 } }),
        shapes = { { id = "gable", dirs = { "EW", "NS" } }, { id = "hip", dirs = {} },
            { id = "shed", dirs = { "N", "E", "S", "W" } } },
        -- 平頂：30 度的組沒有平頂片（建築編輯器的 roof_tops 沒有 roofs_30_*），所以沒有 flat
        key = { face = { N = "N", E = "E", S = "S", W = "W" }, corner = { NW = "ONW", NE = "ONE", SW = "OSW", SE = "OSE" },
            ridge = { NS = "PNS", WE = "PWE" }, quad = "Q" },
        gable = { ref = "walls_exterior_roofs_30_01", tol = 3, kind = "wall",
            off = rows({ { "RiseE", 0, 1 }, { "FallE", 8, -1 }, { "RiseS", 16, 1 }, { "FallS", 24, -1 },
                { "PeakE", 32, 1 }, { "PeakS", 40, 1 } }) },
    },
    -- 45 度：核心 20 片，原版 17 套模板相同、基準 0 或 32；+22 是平頂片（TOP1，不算核心）。建築編輯器只畫朝南、朝東的坡面
    -- （PeakWE／PeakNS 只畫南、東半邊，北、西沒有片）；那半邊照 CONTRACT 閘門 A1 補天花板片（FILL）擋雨、算室內。
    -- 跨距的一半超過 3 格（離屋簷 3 格以上）鋪平頂片在上一層（建築編輯器 depth Three 的平頂放在上一層的地板層，
    -- r43_buildingfloor.cpp:884-891），所以 45 度沒有跨距上限。
    -- 半格片：RS2／RE2（OnePt5S／E）＝+15／+14；RS3／RE3（TwoPt5）在 +71／+70 或 +47／+46，沒有的款照建築編輯器用 +15／+14
    -- 往西北移一格（BuildingTiles offset -1 -1）；OP2／OP3（OuterOnePt5／TwoPt5，四坡奇數短邊的屋脊頭與錐頂）在
    -- +65／+66 或 +41／+42，只有部分款有（set.half）。這幾片在辨識時找（set.pieces），不在模板裡。
    -- 山牆 44 款，模板 18 片（walls_exterior_roofs_05 那列的位移），原版非燒毀款同片種最大差 4（location_shop_bargNclothes_01），
    -- 不同片種最近差 10（PeakS 與 RiseS），容許取 4；燒毀款與 walls_logs 認不出（temp/impl-100/p2/gable45_tol.py）。
    -- 跨距 7 以上的山牆中段（建築編輯器的 CapGap，是別的牆圖塊組的整面牆）不放
    ["45"] = {
        ref = "roofs_01", tol = 20, rise = 3, kind = "roof",
        off = rows({ { "S", 0, 1, 3 }, { "E", 3, -1, 3 }, { "O", 8, 1, 3 }, { "I", 11, 1, 3 }, { "RE2", 14, 1, 0 },
            { "RS2", 15, 1, 0 }, { "TOP1", 22, 1, 0 }, { "SW", 24, 1, 3 }, { "NE", 27, -1, 3 } }),
        key = { face = { S = "S", E = "E" }, corner = { SE = "O", SW = "SW", NE = "NE" }, ridge = { NS = "RS", WE = "RE" },
            quad = "OP", triSE = "OP", flat = "TOP", half = { RS = true, RE = true, OP = true } },
        gable = { ref = "walls_exterior_roofs_01", tol = 4, kind = "wall",
            off = rows({ { "RiseE", 0, 1, 3 }, { "FallE", 8, 1, 3 }, { "RiseS", 11, -1, 3 }, { "FallS", 3, -1, 3 },
                { "PeakE1", 15, 1, 0 }, { "PeakE2", 14, 1, 0 }, { "PeakE3", 16, 1, 0 },
                { "PeakS1", 7, 1, 0 }, { "PeakS2", 6, 1, 0 }, { "PeakS3", 17, 1, 0 } }) },
    },
}
Roof.FAMILIES = { "30", "45" }
Roof.FILL = "ceilings_01_0" -- 45 度沒有片的那半邊、半格片底下補的天花板（地圖房子屋頂層每格都疊這張；實測補了才算室內）

-- 每族的核心片（照編號排，比對時先失敗的先跳出）；45 度的平頂片不算核心
for _, spec in pairs(Roof.FAM) do
    for _, g in ipairs({ spec, spec.gable or false }) do
        if g then
            local core, span, n = {}, 0, 0
            for k, o in pairs(g.off) do
                if k ~= "TOP1" then -- 逐筆插入排序（家族規則：不用 table.sort）
                    local i = n
                    while i >= 1 and g.off[core[i]] > o do
                        core[i + 1] = core[i]
                        i = i - 1
                    end
                    core[i + 1] = k
                    n = n + 1
                end
                span = math.max(span, o)
            end
            g.core, g.span = core, span
        end
    end
end

-- ---------------------------------------------------------------- 辨識

local samples = {} -- "樣板組_編號" → 樣板取樣，false＝拿不到
local cache, gableCache = {}, {} -- 圖塊組 → { 套, … }（認不出是空表）

-- 每 STEP px 取一點。ref 是 nil：回取樣（含寬高）；有 ref：邊取邊比，圖框不同或不同的點超過 tol 回 nil，對上回 true
local function sample(spr, ref, tol)
    local tex = spr:getTextureForCurrentFrame(IsoDirections.N)
    if not tex then return nil end
    local w, h = tex:getWidthOrig(), tex:getHeightOrig()
    if ref and (w ~= ref.w or h ~= ref.h) then return nil end
    local out, n, bad = nil, 0, 0
    if not ref then out = { w = w, h = h } end
    for y = STEP / 2, h - 1, STEP do
        for x = STEP / 2, w - 1, STEP do
            n = n + 1
            local v = spr:isMaskClicked(IsoDirections.N, x, y, false)
            if out then
                out[n] = v
            elseif v ~= ref[n] then
                bad = bad + 1
                if bad > tol then return nil end
            end
        end
    end
    return out or true
end

local function refSample(name)
    local s = samples[name]
    if s == nil then
        local spr = Entry.sprite(name)
        s = spr and sample(spr, nil, 0) or false
        samples[name] = s
    end
    return s or nil
end

-- 一個圖塊組照一份模板（spec＝Roof.FAM[族] 或它的 gable）找整套：回基準編號的陣列
local function scan(ts, spec)
    for _, k in ipairs(spec.core) do
        if not refSample(spec.ref .. "_" .. spec.off[k]) then return {} end -- 原版樣板拿不到：不認
    end
    local kinds = {} -- 編號 → 這張圖是不是要的種類（同一張會被好幾個基準問到）
    local function isKind(n)
        local v = kinds[n]
        if v == nil then
            local spr = Entry.sprite(ts .. "_" .. n)
            v = spr ~= nil and Rules.classify(spr) == spec.kind
            kinds[n] = v
        end
        return v
    end
    local out = {}
    for b = 0, MAX_NUM - spec.span do
        local ok = true
        for _, k in ipairs(spec.core) do
            if not isKind(b + spec.off[k]) then
                ok = false
                break
            end
        end
        if ok then
            for _, k in ipairs(spec.core) do
                local spr = Entry.sprite(ts .. "_" .. (b + spec.off[k]))
                if not sample(spr, refSample(spec.ref .. "_" .. spec.off[k]), spec.tol) then
                    ok = false
                    break
                end
            end
        end
        if ok then out[#out + 1] = b end
    end
    return out
end

-- 45 度在模板外的半格片（見 Roof.FAM["45"] 的說明）：照候選位置比外形，回 set.pieces（片種 → { 編號, dx, dy }）與 half
local function extras(ts, b)
    local spec = Roof.FAM["45"]
    local function find(refNum, rels)
        local ref = refSample(spec.ref .. "_" .. refNum)
        for _, r in ipairs(rels) do
            local spr = ref and Entry.sprite(ts .. "_" .. (b + r))
            if spr and Rules.classify(spr) == "roof" and sample(spr, ref, spec.tol) then return { r, 0, 0 } end
        end
        return nil
    end
    local p = { RS3 = find(71, { 71, 47 }) or { 15, -1, -1 }, RE3 = find(70, { 70, 46 }) or { 14, -1, -1 },
        OP2 = find(65, { 65, 41 }), OP3 = find(66, { 66, 42 }) }
    return p, p.OP2 ~= nil and p.OP3 ~= nil
end

-- 這張屋頂圖所屬的圖塊組認不認得出整套：回 { fam＝"30"｜"45", ts, base, half, top, pieces } 或 nil。half＝有沒有
-- 四坡奇數短邊要的半格轉角片（30 度沒有這種片、也用不到），top＝有沒有平頂片，pieces＝45 度模板外的半格片。
-- 一組可能有好幾套（roofs_01 有 @0、@32）：先給模板範圍包住這張的那套，不然第一套。照圖塊組快取，第一次約 0.1 秒（推測）
function Roof.family(name)
    local ts, num = tostring(name):match("^(.*)_(%d+)$")
    if not ts then return nil end
    local sets = cache[ts]
    if sets == nil then
        Rules.ensure()
        sets = {}
        for _, fam in ipairs(Roof.FAMILIES) do
            for _, b in ipairs(scan(ts, Roof.FAM[fam])) do
                local s = { fam = fam, ts = ts, base = b, half = false, top = false }
                if fam == "45" then
                    s.pieces, s.half = extras(ts, b)
                    s.top = Entry.sprite(ts .. "_" .. (b + Roof.FAM["45"].off.TOP1)) ~= nil
                end
                sets[#sets + 1] = s
            end
        end
        cache[ts] = sets
    end
    num = tonumber(num)
    for _, s in ipairs(sets) do
        if num >= s.base and num <= s.base + Roof.FAM[s.fam].span then return s end
    end
    return sets[1]
end

-- 山牆：牆的圖塊組（ts＝圖塊組名，例 walls_exterior_roofs_30_01）認不認得出一整套山牆片。回 { fam, ts, base } 或 nil
function Roof.gableFamily(ts)
    local hit = gableCache[ts]
    if hit == nil then
        Rules.ensure()
        hit = false
        for _, fam in ipairs(Roof.FAMILIES) do
            local g = Roof.FAM[fam].gable
            local bases = g and scan(ts, g) or {}
            if bases[1] then
                hit = { fam = fam, ts = ts, base = bases[1] }
                break
            end
        end
        gableCache[ts] = hit
    end
    return hit or nil
end

-- 45 度沒有片的那半邊要補的天花板：FILL 不成立（圖塊組被沙盒關掉、目錄不收）改鋪這一款的平頂片；都不成立回 nil
local function fillName(set)
    if Entry.resolve(Roof.FILL) then return Roof.FILL end
    local top = set.top and set.ts .. "_" .. (set.base + Roof.FAM["45"].off.TOP1)
    return top and Entry.resolve(top) and top or nil
end

-- 這一套做得出的形狀與方向：{ { id, dirs = { … } }, … }（唯讀）。雙斜的方向是屋脊走向（EW／NS），單斜的是坡面朝哪邊（低的那邊）。
-- 45 度：單斜只有朝南、朝東（另兩面沒有片）；補不了天花板時只剩平頂；沒有平頂片不給平頂
local SHAPES45 = { { id = "gable", dirs = { "EW", "NS" } }, { id = "hip", dirs = {} }, { id = "shed", dirs = { "S", "E" } } }
local FLAT = { id = "flat", dirs = {} }
function Roof.shapes(set)
    local spec = set and Roof.FAM[set.fam]
    if not spec then return {} end
    if spec.shapes then return spec.shapes end
    local out = {}
    if fillName(set) then
        for _, s in ipairs(SHAPES45) do out[#out + 1] = s end
    end
    if set.top then out[#out + 1] = FLAT end
    return out
end

-- ---------------------------------------------------------------- 排法

-- 每種形狀哪幾邊是屋簷（坡面往那邊低下去）。四坡沒有方向；平頂沒有屋簷
local EAVES = {
    gable = { EW = { N = true, S = true }, NS = { W = true, E = true } },
    hip = { [""] = { N = true, E = true, S = true, W = true } },
    shed = { N = { N = true }, E = { E = true }, S = { S = true }, W = { W = true } },
    flat = { [""] = {} },
}
local SIDES = { "N", "E", "S", "W" }

-- 一格的角色：離最近的屋簷 m 格；最近的屋簷只有一邊＝那面的斜面，兩邊相鄰＝外角，兩邊相對＝屋脊
-- （30 度：南北兩坡夾的是 Peak30NS 那列、東西兩坡夾的是 Peak30WE 那列，同建築編輯器 Peak30WE／Peak30NS 屋頂用的片；
-- 45 度：屋脊是半格片 OnePt5／TwoPt5），三邊＝四坡奇數短邊的屋脊頭（照屋脊；45 度含南、東兩面的照錐頂），四邊＝錐頂
-- （30 度四角錐頂；45 度建築編輯器 CornerOuterSE 半格深度左上那格的 OuterPt5 系列）。
-- 回 片種字首, m；字首是 nil＝這格沒有片（45 度朝北、朝西的坡面與西北角）
local function role(spec, eaves, d)
    local m, faces = nil, {}
    for _, f in ipairs(SIDES) do
        if eaves[f] then
            if m == nil or d[f] < m then
                m, faces = d[f], { f }
            elseif d[f] == m then
                faces[#faces + 1] = f
            end
        end
    end
    local key = spec.key
    if m == nil then return key.flat, 0 end
    local n = #faces
    if n == 1 then return key.face[faces[1]], m end
    local has = {}
    for _, f in ipairs(faces) do has[f] = true end
    if n == 4 or (n == 3 and key.triSE and has.S and has.E) then return key.quad, m end
    if has.N and has.S then return key.ridge.NS, m end
    if has.W and has.E then return key.ridge.WE, m end
    return key.corner[(has.N and "N" or "S") .. (has.W and "W" or "E")], m
end

-- 山牆片：西、東兩邊（E 系列牆片，牆在格子西邊）看南北屋簷，北、南兩邊（S 系列，牆在格子北邊）看東西屋簷。
-- 離北邊（或西邊）近＝Fall／Rise（建築編輯器：西側山牆北端 FallE1、南端 RiseE1；北側山牆西端 RiseS1、東端 FallS1），一樣近＝屋脊
local function capRole(side, eaves, d)
    local a, b, near, far, peak
    if side == "W" or side == "E" then
        a, b, near, far, peak = "N", "S", "FallE", "RiseE", "PeakE"
    else
        a, b, near, far, peak = "W", "E", "RiseS", "FallS", "PeakS"
    end
    local da, db = eaves[a] and d[a], eaves[b] and d[b]
    if da and db and da == db then return peak, da end
    if da and (not db or da < db) then return near, da end
    return far, db
end

local function maxLevels()
    local Plan = B.Plan
    return Plan and Plan.MAX_LEVELS or 4
end

-- 排出整個屋頂：set＝Roof.family 的回傳、shape＝Roof.shapes 的 id、dir＝它的方向之一（沒有方向的傳 nil）、
-- x1..y2＝範圍（含兩端，世界座標）、z＝屋頂那一層、gable＝Roof.gableFamily 的回傳或 nil（不放山牆）。
-- 回 groups, warn：groups＝{ { id＝圖名, cells＝{ { x, y, z, 0 }, … } }, … }（照第一次出現的順序；同一格可以有屋頂片和
-- 天花板各一片：藍圖只擋同一項目同一格（Plan.lua same），屋頂的判斷不看地板（Place.roofAt）），warn＝{ HALF＝補了天花板 }
-- 或 nil；或 nil, 碼：TOO_SMALL 任一邊不到 2 格、TOO_WIDE 雙斜或四坡跨距超過上限（30 度 11 格；45 度沒有平頂片的款 6 格）、
-- ODD_SPAN 45 度四坡奇數短邊 3、5 格而這一款沒有半格轉角片、TOO_HIGH 升超過藍圖的層數、
-- DISABLED 要用的圖有一張 Entry.resolve 不成立（圖塊組、來源或種類被沙盒關掉；一片都不產生）
function Roof.layout(set, shape, dir, x1, y1, x2, y2, z, gable)
    local spec = Roof.FAM[set.fam]
    local key = spec.key
    local eaves = EAVES[shape] and EAVES[shape][dir or ""]
    if not eaves then error("Roof.layout: no shape " .. tostring(shape) .. "/" .. tostring(dir)) end
    x1, x2 = math.min(x1, x2), math.max(x1, x2)
    y1, y2 = math.min(y1, y2), math.max(y1, y2)
    local w, h = x2 - x1 + 1, y2 - y1 + 1
    if w < 2 or h < 2 then return nil, "TOO_SMALL" end
    local span
    if eaves.N and eaves.S then span = h end
    if eaves.W and eaves.E then span = math.min(span or w, w) end
    -- 兩面以上屋簷、離屋簷 rise 格以上：45 度鋪平頂片在上一層（30 度的跨距上限讓這種格子不會出現）
    local multi = span ~= nil
    if span and spec.maxSpan and span > spec.maxSpan then return nil, "TOO_WIDE" end
    if span and span > 2 * spec.rise and not set.top then return nil, "TOO_WIDE" end -- 45 度沒有平頂片的款
    if shape == "hip" and key.half and not set.half and span % 2 == 1 and span < 2 * spec.rise then
        return nil, "ODD_SPAN" -- 四坡奇數短邊的屋脊頭要半格轉角片，這一款沒有
    end
    local fill = key.half and fillName(set)

    local order, byName, top, warn = {}, {}, 0, nil
    local function add(name, x, y, lv)
        local g = byName[name]
        if not g then
            g = { id = name, cells = {} }
            byName[name] = g
            order[#order + 1] = g
        end
        top = math.max(top, lv)
        g.cells[#g.cells + 1] = { x, y, z + lv, 0 }
    end
    -- 片種 k（字首＋序號）放在 (x, y) 往上 lv 層；pieces 是辨識時找到的模板外片（可帶格子位移）
    local function put(ts, base, off, pieces, k, x, y, lv)
        local p = pieces and pieces[k]
        local o = p and p[1] or off[k]
        if not o then error("Roof.layout: no piece " .. k .. " in " .. set.fam) end
        add(ts .. "_" .. (base + o), x + (p and p[2] or 0), y + (p and p[3] or 0), lv)
    end
    local function putFill(x, y)
        if not fill then error("Roof.layout: no fill for " .. set.ts) end
        add(fill, x, y, 0)
        warn = { HALF = true }
    end
    local d = {}
    for y = y1, y2 do
        for x = x1, x2 do
            d.N, d.S, d.W, d.E = y - y1, y2 - y, x - x1, x2 - x
            local kk, m = role(spec, eaves, d)
            if multi and m >= spec.rise then
                put(set.ts, set.base, spec.off, nil, key.flat .. "1", x, y, 1)
            elseif kk == nil then
                putFill(x, y)
            else
                put(set.ts, set.base, spec.off, set.pieces, kk .. (m % spec.rise + 1), x, y, math.floor(m / spec.rise))
                if key.half and key.half[kk] then putFill(x, y) end -- 半格片沒有 BlockRain
            end
        end
    end
    -- 山牆：只在垂直屋簷的兩邊（雙斜的兩端、單斜的兩側；高的那面和四坡不放，同建築編輯器的預設）。
    -- 45 度跨距 7 以上的中段（離屋簷 3 格以上）不放：建築編輯器在那裡放別的牆圖塊組的整面牆（CapGap）
    if gable and gable.fam ~= set.fam then error("Roof.layout: gable family " .. gable.fam .. " on " .. set.fam) end
    local gs = gable and spec.gable
    if gs and not ((eaves.N or eaves.S) and (eaves.W or eaves.E)) then
        local sides = (eaves.N or eaves.S) and { "W", "E" } or { "N", "S" }
        for _, side in ipairs(sides) do
            local along = side == "W" or side == "E"
            for i = along and y1 or x1, along and y2 or x2 do
                local x = side == "W" and x1 or side == "E" and x2 + 1 or i
                local y = side == "N" and y1 or side == "S" and y2 + 1 or i
                d.N, d.S, d.W, d.E = y - y1, y2 - y, x - x1, x2 - x
                local kk, m = capRole(side, eaves, d)
                if not (multi and m >= spec.rise) then
                    put(gable.ts, gable.base, gs.off, nil, kk .. (m % spec.rise + 1), x, y, math.floor(m / spec.rise))
                end
            end
        end
    end
    if top + 1 > maxLevels() then return nil, "TOO_HIGH" end
    for _, g in ipairs(order) do
        if not Entry.resolve(g.id) then return nil, "DISABLED" end
    end
    return order, warn
end

return Roof
