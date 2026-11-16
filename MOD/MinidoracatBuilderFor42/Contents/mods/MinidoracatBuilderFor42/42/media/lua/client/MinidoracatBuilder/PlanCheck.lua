-- 藍圖每一片在世界上的狀態（只在客戶端、只給畫面與照圖蓋用）：地上的藍圖向 PlanMode 要，分幀算、由近到遠。
-- 「蓋好了」只看世界上有沒有同一張圖（誰蓋的、地圖原有的都算；門開著、窗破了、多格物件的其他片都認回同一張）：
-- 一般項目看錨點那一格，車庫門、雙開門、坡道看整組每一格（坡道的平台格有任何地板就算）；
-- 沒有才問 Check.item（帶游標預覽同一組 opts），能不能蓋不另外判斷。配方項目看 Recipes。
-- 算完整張後只重查有變動的片：PlanCheck.touch 的格子、背包或技能變了（材料摘要每秒比一次）、沙盒設定變了、
-- 玩家換樓層或走開 MOVE 格（重查還沒載入或太遠的片）、玩家身邊 NEAR 格內格上的物件數變了（每幀輪流比一段）。
-- 會自己消失、又不改物件數的原因（PlanCheck.RECHECK：有人或車擋著、配方太暗）看不出來：身邊的片隔一段時間重查一次。
-- 放不下（BLOCKED）的片也隔 STALE_MS 重查：撐它的東西可能蓋在別格、藍圖外，那一格的物件數比不到。
-- 蓋好的多格組（車庫門、雙開門、坡道）也隔 STALE_MS 重查整組：物件數只比錨點那格，其他格被拆看不出來。
-- 放不下、但旁邊還有會蓋的片的，細節碼報 WAIT（等旁邊先蓋好，見 waiting），狀態照舊是 blocked。
-- 沒有地上的藍圖時 OnTick 第一行就離開。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Check"
require "MinidoracatBuilder/Cost"
require "MinidoracatBuilder/Materials"

local B = MinidoracatBuilder
local PlanCheck = B.PlanCheck or {}
B.PlanCheck = PlanCheck
local Entry, Check, Cost, Materials = B.Entry, B.Check, B.Cost, B.Materials

local LOG = "[MinidoracatBuilderFor42] "
PlanCheck.BUDGET_MS = 2     -- 每幀最多花幾毫秒
PlanCheck.SUMMARY_MS = 1000 -- 材料摘要、沙盒設定多久比一次（同游標的 SUMMARY_MS）
PlanCheck.MOVE = 8          -- 玩家走開幾格（或換樓層）就重查還沒載入、太遠的片
PlanCheck.NEAR = 12         -- 身邊幾格內的片輪流比格上的物件數
PlanCheck.SWEEP = 128       -- 每幀輪流比幾片
-- 這些細節碼的片隔多久（毫秒）重查一次。太暗要重算配方，隔久一點
PlanCheck.RECHECK = { OCCUPIED = 500, VEHICLE = 500, DARK = 5000 }
-- ponytail：身邊放不下的片每 STALE_MS 整片重算一次；量到拖慢再改成只比旁邊幾格的物件數
PlanCheck.STALE_MS = 5000
local MAX_BUCKET = 255
local SHORT = { NO_MATERIAL = true, NO_TOOL = true }
local FAR = { TOO_FAR = true, NOT_LOADED = true }
local OFF = { DISABLED_KIND = true, DISABLED_SOURCE = true, DISABLED_TILESET = true }
-- 一片會靠到的格子：同一格、上下一層、四鄰（屋頂與上層地板靠下面的牆或旁邊的地板撐，門窗裝在那格的門框窗框上，
-- 窗簾要上面有屋頂）。touch 照它重查，waiting 照它找在等誰
local AROUND = { { 0, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 } }
PlanCheck.WAIT_MS = 100 -- 「在等旁邊」的名單最多多久重算一次

-- { plan, rev, ox, oy, oz, list = { 片… }, n, rec = { [片] = 紀錄 }, q, S, sAt, digest, px, py, pz, sweep,
--   ver＝片的狀態變過幾次, wait, wVer, wAt＝waiting 的名單與算的時候, rq＝還沒排完的重排請求（見 requeue） }
local cur
local canonMemo, itemMemo, cellsMemo, memoDigest = {}, {}, {}, nil

-- 項目、認圖、佔地、成本的快取都照沙盒摘要（種類開關、停用來源與圖塊組、成本倍率）：摘要變了全部丟掉
local function syncMemo()
    local dg = Entry.digest()
    if dg ~= memoDigest then
        canonMemo, itemMemo, cellsMemo, PlanCheck.costMemo, memoDigest = {}, {}, {}, {}, dg
    end
end

local function recipesOf()
    return B.Recipes
end

local function isRecipe(id)
    return type(id) == "string" and id:sub(1, 7) == "recipe:"
end

-- ===== 一種項目在這裡 =====

-- "ok"｜"missing"｜"off"｜"closed", 細節碼, 參數（Entry.why 的 arg：關掉的種類、MOD、圖塊組）。照沙盒摘要快取
function PlanCheck.item(id)
    syncMemo()
    local m = itemMemo[id]
    if m then return m[1], m[2], m[3] end
    local st, code, arg
    if isRecipe(id) then
        local R = recipesOf()
        local r = R and R.get and R.get(id)
        if r then st = "ok" else st, code = "missing", "UNKNOWN" end
    elseif Entry.resolve(id) then
        st = "ok"
    elseif not Entry.sprite(id) then
        st, code = "missing", "UNKNOWN"
    else
        code, arg = Entry.why(id)
        st = OFF[code] and "off" or "closed"
    end
    itemMemo[id] = { st, code, arg }
    return st, code, arg
end

-- ===== 世界上的圖認回項目 =====

-- 圖名 → 能蓋的那一張（能蓋的就是自己；開著的門、窗的狀態圖、拉上的窗簾、疊放圖、樓梯中片頂片、多格的其他片照
-- Entry.why 的 alt）；認不回 false
local function canon(name)
    local c = canonMemo[name]
    if c == nil then
        if Entry.resolve(name) then
            c = name
        else
            local _, _, alt = Entry.why(name)
            c = alt or false
        end
        canonMemo[name] = c
    end
    return c
end

-- 格上每一張圖（物件、掛在上面的疊圖、overlay；同 Menu 挑圖塊的收法），地上物品不算。fn(name) 回 true 就停並回 true
local function eachTile(sq, fn)
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        if not instanceof(o, "IsoWorldInventoryObject") then
            local spr = o:getSprite()
            local name = spr and spr:getName()
            if name and fn(name) then return true end
            -- 沒有這兩個方法的物件當沒有疊圖（IsoObject 都有；只在 OnTick 被別的模組帶來的物件上保險）
            local att = o.getAttachedAnimSprite and o:getAttachedAnimSprite()
            for j = 0, att and att:size() - 1 or -1 do
                local a = att:get(j)
                local an = a and a:getName()
                if an and fn(an) then return true end
            end
            local ov = o.getOverlaySprite and o:getOverlaySprite()
            local on = ov and ov:getName()
            if on and fn(on) then return true end
        end
    end
    return false
end
PlanCheck.eachTile = eachTile

local function hasTile(sq, want)
    return sq ~= nil and eachTile(sq, function(name) return name == want or canon(name) == want end)
end

-- 格上物件數＋掛著的疊圖數：身邊的片比這個值決定要不要重查（ponytail：原地換成別款、件數不變認不出來，要等 touch）
local function sigOf(sq)
    if not sq then return -1 end
    local objects, n = sq:getObjects(), 0
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        local att = o.getAttachedAnimSprite and o:getAttachedAnimSprite()
        n = n + 1 + (att and att:size() or 0)
    end
    return n
end

-- 一張圖的佔地（Entry.cells），照圖名記住：坡道一組 20 多格，每算一片都要
local function cellsOf(spr)
    local name = spr:getName()
    local c = cellsMemo[name]
    if not c then
        c = Entry.cells(spr)
        cellsMemo[name] = c
    end
    return c
end

-- 圖塊項目在世界上這一格（錨點）放的那一張（朝向、交替柵欄照 Check.item 同一套）與佔地；沒有那一面回 nil
local function placed(entry, d, x, y, w)
    local spr = Entry.face(entry, d)
    if not spr then return nil end
    spr = Entry.alternate(spr, x, y)
    local set = entry.kind == "door" and Entry.doorSet(spr)
    local offs = set and set.garage and Entry.groupCells(set, w or 2) or cellsOf(spr)
    return spr, offs, set
end

-- 坡道整組在不在：每一格斜面都要有那一片；平台格有任何地板就算（同 Place 放坡道：已有地板不另補）。
-- 格子不在（沒載入、上一層沒有格子）不算。照順序看，缺一格就停
local rampWant
local function isRampWant(name) return name == rampWant end
local function rampBuilt(cell, offs, x, y, z)
    for i = 1, #offs do
        local o = offs[i]
        local s = cell:getGridSquare(x + o[1], y + o[2], z + o[3])
        if not s then return false end
        if o[5] == "platform" then
            if not s:has(IsoFlagType.solidfloor) then return false end
        else
            rampWant = o[4]:getName()
            if not eachTile(s, isRampWant) then return false end
        end
    end
    return true
end

-- 這一片蓋好了沒（看世界，不看紀錄）
local function built(id, x, y, z, d, w, sq)
    local cell = getCell()
    if isRecipe(id) then
        -- 照這一面第一格有圖的（Recipes.tile，可能不在錨點那格）：換了面的配方片不算蓋好
        local R = recipesOf()
        if not (R and R.tile) then return false end
        local want, dx, dy = R.tile(id, d)
        if want == nil then return false end
        dx, dy = dx or 0, dy or 0
        local s = (dx == 0 and dy == 0) and sq or cell:getGridSquare(x + dx, y + dy, z)
        return s ~= nil and eachTile(s, function(name) return name == want end), dx, dy
    end
    local entry = Entry.resolve(id)
    local spr, offs, set
    if entry then
        spr, offs, set = placed(entry, d, x, y, w)
        if not spr then return false end
    else -- 這裡關掉了，世界上照樣可能有：坡道照樣看整組，其他看錨點那格
        spr = Entry.sprite(id)
        if not (spr and Entry.rampSet(spr)) then return hasTile(sq, id) end
        offs = cellsOf(spr)
    end
    if set then -- 車庫門、雙開門：整扇的每一格都要有這一組的片（開著關著都算）
        for _, o in ipairs(offs) do
            local s = cell:getGridSquare(x + o[1], y + o[2], z + o[3])
            if not (s and eachTile(s, function(name) return set.members[name] == true end)) then return false end
        end
        return true, 0, 0, #offs > 1
    end
    -- 坡道一片代表整組：頭片在、中段或平台不在的殘組不算蓋好
    if Entry.rampSet(spr) then return rampBuilt(cell, offs, x, y, z), 0, 0, true end
    return hasTile(sq, spr:getName())
end

-- ===== 片 =====

-- 這一片的 項目 ID, 世界座標 x, y, z, 朝向 d, 疊放 o, 車庫門寬度 w。沒有地上的藍圖或還沒定位時座標是 nil
function PlanCheck.resolve(piece)
    local M = B.PlanMode
    local plan = M and M.plan and M.plan()
    local it = plan and plan.items[piece.it]
    local id = it and it.id
    local ox, oy, oz
    if M and M.origin then ox, oy, oz = M.origin() end
    if not ox then return id, nil, nil, nil, piece.d, piece.o, piece.w end
    return id, piece.x + ox, piece.y + oy, piece.z + oz, piece.d, piece.o, piece.w
end

-- ===== 等旁邊的片 =====

-- 還會蓋的片：還沒算、能蓋、缺料、太遠，或擋著的原因自己會消失（RECHECK）
local function live(r)
    local s = r.s
    return s == nil or s == "ok" or s == "short" or s == "far" or (s == "blocked" and PlanCheck.RECHECK[r.c] ~= nil)
end

-- 放不下（BLOCKED：Place.check 沒說更細的原因）的片裡，在等旁邊的那些：{ [片] = true }。屋頂等牆、門等門框這類，
-- 開工前就說「換一格或先清空」會讓人以為擺錯地方。從挨著會蓋的片的開始，一圈一圈往外標（屋頂也靠旁邊的屋頂撐）；
-- 旁邊都蓋好了、或都蓋不了還放不下的不算（兩片互相挨著、各自被擋住的不會互相等）。
-- 片的狀態有變才重算，最多 WAIT_MS 一次。以格子（Plan.at 回的那張清單）為單位，每格的清單最多各掃兩次：
-- 同一格疊很多片時不會變成片數的平方
local function waiting()
    if cur.wait and cur.wVer == cur.ver then return cur.wait end
    local now = getTimestampMs()
    if cur.wait and now >= cur.wAt and now - cur.wAt < PlanCheck.WAIT_MS then return cur.wait end
    cur.wVer, cur.wAt = cur.ver, now
    local rec, at, plan = cur.rec, B.Plan.at, cur.plan
    local wait, alive, swept, todo, n = {}, {}, {}, {}, 0
    -- 這一格有沒有還會蓋的片（放不下的片自己不算 live，不必排除自己）
    local function hasLive(list)
        local v = alive[list]
        if v == nil then
            v = false
            for j = 1, #list do
                local r = rec[list[j]]
                if r and live(r) then
                    v = true
                    break
                end
            end
            alive[list] = v
        end
        return v
    end
    for i = 1, cur.n do
        local p = cur.list[i]
        local r = rec[p]
        if r.s == "blocked" and r.c == "BLOCKED" then
            for k = 1, #AROUND do
                local a = AROUND[k]
                if hasLive(at(plan, p.x + a[1], p.y + a[2], p.z + a[3])) then
                    wait[p] = true
                    n = n + 1
                    todo[n] = p
                    break
                end
            end
        end
    end
    local i = 1
    while i <= n do
        local p = todo[i]
        for k = 1, #AROUND do
            local a = AROUND[k]
            local list = at(plan, p.x + a[1], p.y + a[2], p.z + a[3])
            if not swept[list] then -- 掃過一次，這格放不下的片就都在名單裡了
                swept[list] = true
                for j = 1, #list do
                    local q = list[j]
                    local r = rec[q]
                    if r and r.s == "blocked" and r.c == "BLOCKED" and not wait[q] then
                        wait[q] = true
                        n = n + 1
                        todo[n] = q
                    end
                end
            end
        end
        i = i + 1
    end
    cur.wait = wait
    return wait
end

-- 一片的狀態, 細節碼。算的時候的藍圖、位置（含現在的原點）、項目、朝向、疊放、寬度和現在不一樣（搬了、換了）回 nil
function PlanCheck.state(piece)
    local r = cur and cur.rec[piece]
    if not (r and r.s) then return nil end
    local M = B.PlanMode
    if not (M and M.plan and M.plan() == cur.plan) then return nil end
    local id, x, y, z, d, o, w = PlanCheck.resolve(piece)
    if id ~= r.id or x ~= r.x or y ~= r.y or z ~= r.z or d ~= r.d or o ~= r.o or w ~= r.w then return nil end
    if r.c == "BLOCKED" and waiting()[piece] then return r.s, "WAIT" end
    return r.s, r.c
end

-- ===== 佇列：照距離分桶，由近到遠（不排序，家族規則） =====

local function dist(x, y, z)
    local d = math.max(math.abs(x - cur.px), math.abs(y - cur.py)) + 8 * math.abs(z - cur.pz)
    return math.min(MAX_BUCKET, math.floor(d))
end

-- r.q＝排在哪一個佇列（cur.q），false＝沒排。佇列整個重建（sync）時舊的記號自動作廢，不必逐片清
local function push(p)
    local r = cur.rec[p]
    local q = cur.q
    if r.q == q then return end
    r.q = q
    local k = dist(p.x + cur.ox, p.y + cur.oy, p.z + cur.oz)
    local b = q.b[k]
    if not b then
        b = { i = 1, n = 0 }
        q.b[k] = b
    end
    b.n = b.n + 1
    b[b.n] = p
    if k < q.lo then q.lo = k end
end

local function pop()
    local q = cur.q
    while q.lo <= MAX_BUCKET do
        local b = q.b[q.lo]
        if b and b.i <= b.n then
            local p = b[b.i]
            b[b.i] = nil
            b.i = b.i + 1
            local r = cur.rec[p]
            if r then -- 從藍圖拿掉的片：紀錄已經丟了，略過
                r.q = false
                return p, r
            end
        else
            q.b[q.lo] = nil
            q.lo = q.lo + 1
        end
    end
    return nil
end

-- 重排與同步都不一次把整張排進佇列（材料一變，4,096 片一次全排要 8–15 ms，E2ERun9 big1～big3；放下藍圖同樣），
-- 改成掃描、分幀排：先照 Plan.at 一圈一圈看玩家身邊 RING 圈內的格子，再照清單順序看全部；每看 DRAIN 片（格）
-- 看一次時鐘，每幀至少看一段。身邊先排：佇列由近到遠算，照圖蓋要挑的近片最先算出來（照清單順序先排的話，
-- 先算出能蓋的是清單前段的遠片，E2EPerf11 bigRun）。每片記看過哪一張掃描（重排 r.rq、同步 r.ss），
-- 清單重建、玩家走開而從頭看時，看過的片不重排。
-- 重排 rq＝{ i＝下一個清單索引, ring＝下一圈（nil＝身邊看完了）, all, mat, far }：新請求併進旗標、從頭看。
-- 同步 ss＝{ i, ring }：藍圖改過（rev、原點）之後，新的、搬了、換了的片要排（原點變了時全部都是，重建前的舊佇列不必另外看）
local DRAIN = 256
local RING = 12
local function requeue(kind)
    local old = cur.rq
    local rq = { i = 1, ring = 0, all = old and old.all, mat = old and old.mat, far = old and old.far }
    rq[kind] = true
    cur.rq = rq
end

-- 重排的判斷式同原本三種：沙盒變了全部、材料變了 ok／short／SKILL／DARK、走開了 far
local function wantRq(r, _, rq)
    local s = r.s
    return rq.all or (rq.far and s == "far") or (rq.mat and (s == "ok" or s == "short" or r.c == "SKILL" or r.c == "DARK"))
end

local function wantSync(r, p)
    local it = cur.plan.items[p.it]
    return not it or r.id ~= it.id or r.x ~= p.x + cur.ox or r.y ~= p.y + cur.oy or r.z ~= p.z + cur.oz or r.d ~= p.d
        or r.o ~= p.o or r.w ~= p.w
end

local function visit(scan, key, want, p)
    local r = cur.rec[p]
    if r and r[key] ~= scan then
        r[key] = scan
        if want(r, p, scan) then push(p) end
    end
end

local function cellScan(scan, key, want, x, y, z)
    local list = B.Plan.at(cur.plan, x, y, z)
    for j = 1, #list do visit(scan, key, want, list[j]) end
end

-- 身邊第 k 圈：佇列距離剛好 k 的格子（同一層 max(|dx|,|dy|)＝k；上下一層多 8，只看到 RING-8 圈）。回看了幾格
local function ringScan(scan, key, want, k)
    local cx, cy, cz = cur.px - cur.ox, cur.py - cur.oy, cur.pz - cur.oz
    local zl = k <= RING - 8 and 1 or 0
    for z = cz - zl, cz + zl do
        if k == 0 then
            cellScan(scan, key, want, cx, cy, z)
        else
            for x = cx - k, cx + k do
                cellScan(scan, key, want, x, cy - k, z)
                cellScan(scan, key, want, x, cy + k, z)
            end
            for y = cy - k + 1, cy + k - 1 do
                cellScan(scan, key, want, cx - k, y, z)
                cellScan(scan, key, want, cx + k, y, z)
            end
        end
    end
    return (k == 0 and 1 or 8 * k) * (2 * zl + 1)
end

-- 照一張掃描排片，看到時間到 stop 就停。回 true＝整張看完了
local function step(scan, key, want, stop)
    local seen = 0
    while scan.ring do
        seen = seen + ringScan(scan, key, want, scan.ring)
        scan.ring = scan.ring < RING and scan.ring + 1 or nil
        if seen >= DRAIN then
            if getTimestampMs() >= stop then return false end
            seen = 0
        end
    end
    local list, rec, n, i = cur.list, cur.rec, cur.n, scan.i
    while i <= n do
        local last = math.min(n, i + DRAIN - 1)
        for j = i, last do -- 同 visit（清單上的片都有紀錄），少叫一層
            local p = list[j]
            local r = rec[p]
            if r[key] ~= scan then
                r[key] = scan
                if want(r, p, scan) then push(p) end
            end
        end
        i = last + 1
        if getTimestampMs() >= stop then break end
    end
    scan.i = i
    return i > n
end

-- 一幀看一張：同步先（清單剛換，重排要照新清單看）
local function drain(stop)
    if cur.ss then
        if step(cur.ss, "ss", wantSync, stop) then cur.ss = nil end
    elseif cur.rq then
        if step(cur.rq, "rq", wantRq, stop) then cur.rq = nil end
    end
end

-- ===== 算一片 =====

local function judge(player, r, sq)
    local id, x, y, z, d = r.id, r.x, r.y, r.z, r.d
    local ist, icode = PlanCheck.item(id)
    if ist ~= "ok" then return ist, icode end
    if isRecipe(id) then
        local R = recipesOf()
        cur.recipes = true -- 這張圖有配方片：changed 開始每秒 Recipes.refresh
        local rec = R.get(id)
        if rec.cover then return "blocked", "COVER" end -- 牆面油漆、壁紙、灰泥：照圖蓋不了，要自己用原版游標
        if not Check.inReach(player, x, y, z) then return "far", "TOO_FAR" end
        local pn = player:getPlayerNum()
        local valid, can = R.state(pn, rec)
        if not valid then return "blocked", "SKILL" end
        if R.dark and R.dark(pn, rec) then return "blocked", "DARK" end
        if not can then return "short", "NO_MATERIAL" end
        return "ok", nil
    end
    -- 車庫門比這裡一次能蓋的寬（伺服器 Server.intent 照 max(2, MaxCellsPerDrag) 擋，回 BAD_REQUEST）：說清楚是太寬
    if r.w and r.w > math.max(2, Check.setting("MaxCellsPerDrag", 32)) then return "blocked", "DOOR_WIDE" end
    local a = { x, y, z, d, r.w }
    local code = Check.item(player, id, d, a, { preview = true, walk = true, summary = cur.S, overlap = r.o == 1 })
    if code == nil then return "ok", nil end
    if SHORT[code] then return "short", code end
    if FAR[code] then return "far", code end
    return "blocked", code
end

local function evaluate(player, p, r)
    syncMemo()
    local id, x, y, z, d, o, w = PlanCheck.resolve(p)
    r.id, r.x, r.y, r.z, r.d, r.o, r.w = id, x, y, z, d, o, w
    if not (id and x) then
        r.s, r.c = nil, nil
        return
    end
    local cell = getCell()
    -- 照引擎：只照 x、y 找已讀進來的塊（IsoCell.java:333-357）；上面的樓層常常沒有格子，不能拿格子判斷
    if not cell:getChunkForGridSquare(x, y, z) then
        r.s, r.c, r.sig = "far", "NOT_LOADED", nil
        return
    end
    local sq = cell:getGridSquare(x, y, z)
    local ok, done, dx, dy, group = pcall(built, id, x, y, z, d, w, sq)
    -- 物件數看 built 查圖的那一格（配方片第一格有圖的可能不在錨點）：那一件被拆掉時 sweep 才看得出來
    r.wx, r.wy = ok and dx or 0, ok and dy or 0
    r.sig = sigOf((r.wx == 0 and r.wy == 0) and sq or cell:getGridSquare(x + r.wx, y + r.wy, z))
    r.group = (ok and done and group) or nil -- 蓋好的多格組：sweep 隔 STALE_MS 重查整組
    if ok and done then
        r.s, r.c = "done", nil
        return
    end
    local fine, s, c = pcall(judge, player, r, sq)
    if not fine then
        print(LOG .. "plan check failed e=" .. tostring(id) .. ": " .. tostring(s))
        s, c = "blocked", "INTERNAL"
    end
    r.s, r.c = s, c
end

-- ===== 跟上藍圖、玩家與世界 =====

local function fresh(plan, ox, oy, oz, player)
    cur = { plan = plan, rev = -1, ox = ox, oy = oy, oz = oz, list = {}, n = 0, rec = {}, q = { b = {}, lo = MAX_BUCKET + 1 },
        S = Materials.summary(player), sAt = getTimestampMs(), digest = Entry.digest(), player = player, ver = 0,
        px = math.floor(player:getX()), py = math.floor(player:getY()), pz = math.floor(player:getZ()), sweep = 0 }
end

-- 藍圖換了、rev 或原點變了：重建片的清單（保留算過的結果）；位置或內容變了的片（含新的）交給同步掃描分幀排
local function sync(plan, ox, oy, oz, player)
    if not cur or cur.plan ~= plan or cur.player ~= player then fresh(plan, ox, oy, oz, player) end
    if cur.rev == plan.rev and cur.ox == ox and cur.oy == oy and cur.oz == oz then return end
    local moved = cur.ox ~= ox or cur.oy ~= oy or cur.oz ~= oz
    cur.rev, cur.ox, cur.oy, cur.oz = plan.rev, ox, oy, oz
    local old, rec, list, n = cur.rec, {}, {}, 0
    cur.rec = rec
    B.Plan.each(plan, function(p)
        n = n + 1
        list[n] = p
        rec[p] = old[p] or { q = false }
    end)
    cur.list, cur.n = list, n
    if cur.rq then cur.rq.i, cur.rq.ring = 1, 0 end -- 清單換了，索引作廢：從頭走（看過的片照 r.rq 略過）
    cur.ver = cur.ver + 1 -- 片多了、少了或搬了：旁邊是誰要重看
    -- 原點變了：佇列照新的距離整個重建，還在排的片由同步掃描重排（舊的桶留著的話，同一片會被取出兩次）。
    -- 只有 rev 變時佇列留著：排著的片記號（r.q）就是這個佇列，掃描再排是空動作；拿掉的片 pop 時略過
    if moved then cur.q = { b = {}, lo = MAX_BUCKET + 1 } end
    cur.ss = { i = 1, ring = 0 }
end

-- 材料摘要（與配方片讀的原版快取）比一次：變了就重排
local function compareMaterials(player)
    local S = Materials.summary(player)
    -- 配方片缺不缺讀原版的快取，容器裡的東西變了要 Recipes.refresh 才重算（第三個值是變過幾次）。建造視窗開著時它每秒
    -- 呼叫，關著時沒人呼叫：拿到的工具、材料會一直判成缺，所以判過配方片的圖在這裡補
    local gen = cur.rGen
    if cur.recipes then
        local _, _, n = recipesOf().refresh(player:getPlayerNum())
        gen = n
    end
    if gen ~= cur.rGen or not Materials.same(cur.S, S) then
        cur.rGen = gen
        requeue("mat")
    end
    cur.S = S
end

local function changed(now, player)
    if now - cur.sAt >= PlanCheck.SUMMARY_MS then
        cur.sAt = now
        local digest = Entry.digest()
        if digest ~= cur.digest then -- 沙盒的種類、來源、倍率變了：全部重算
            cur.digest = digest
            requeue("all")
        end
        compareMaterials(player)
    end
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    if pz ~= cur.pz or math.abs(px - cur.px) + math.abs(py - cur.py) >= PlanCheck.MOVE then
        cur.px, cur.py, cur.pz = px, py, pz
        requeue("far")
        if cur.ss then cur.ss.ring = 0 end -- 身邊換了：同步掃描也先看新的身邊
    end
end

-- 身邊 NEAR 格內的片，每幀輪流比一段格上的物件數；變了就重查。RECHECK 的片、放不下的片、蓋好的多格組到時間就重查
-- （時鐘往回調時也查）。每幀都跑：表與欄位在迴圈外先取，間隔只在物件數沒變、有細節碼或是蓋好的多格組時才算
local function sweep(player, now)
    local n = cur.n
    if n == 0 then return end
    local cell, near, recheck, stale, abs = getCell(), PlanCheck.NEAR, PlanCheck.RECHECK, PlanCheck.STALE_MS, math.abs
    local list, rec, ox, oy, oz, i, q = cur.list, cur.rec, cur.ox, cur.oy, cur.oz, cur.sweep, cur.q
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    for _ = 1, math.min(n, PlanCheck.SWEEP) do
        i = i % n + 1
        local p = list[i]
        local r = rec[p]
        local s = r.s
        if s and r.q ~= q and s ~= "far" then
            local x, y, z = p.x + ox, p.y + oy, p.z + oz
            if abs(x - px) <= near and abs(y - py) <= near and abs(z - pz) <= 1 then
                local sx, sy = x + (r.wx or 0), y + (r.wy or 0)
                local c = r.c
                if sigOf(cell:getGridSquare(sx, sy, z)) ~= r.sig then
                    -- 連靠這一格撐的片一起重查：牆不是照圖蓋蓋的（手拖、別人、原版建造）時沒有人叫 touch。
                    -- 先比物件數再看到不到期：兩件事同時發生時也要連旁邊一起查
                    push(p)
                    PlanCheck.touch(sx, sy, z)
                elseif c or r.group then
                    local every = c and (recheck[c] or (c == "BLOCKED" and stale)) or stale
                    local at = r.at or now -- 上次算這一片的時間（tick 記的）
                    if every and (now < at or now - at >= every) then push(p) end
                end
            end
        end
    end
    cur.sweep = i
end

-- 掛 OnTick：每幀最多 BUDGET_MS 毫秒（重建清單也算在裡面），至少算一片、掃描至少看一段
function PlanCheck.tick(player)
    local M = B.PlanMode; local plan = M and M.plan and M.plan(); if not plan then return end
    if not (player and M.origin) then return end
    local ox, oy, oz = M.origin()
    if not ox then return end
    local now = getTimestampMs()
    local stop = now + PlanCheck.BUDGET_MS
    sync(plan, ox, oy, oz, player)
    changed(now, player)
    sweep(player, now)
    drain(stop)
    repeat
        local p, r = pop()
        if not p then return end
        local s, c = r.s, r.c
        evaluate(player, p, r)
        r.at = now -- sweep 隔一段時間重查的片從這裡起算：剛算完的不馬上再算一次
        if cur.rq then r.rq = cur.rq end -- 請求之後才算的片已經是新的：重排掃到時不再排
        if r.s ~= s or r.c ~= c then cur.ver = cur.ver + 1 end
    until getTimestampMs() >= stop
end

function PlanCheck.onTick()
    local M = B.PlanMode; if not (M and M.plan and M.plan()) then return end
    PlanCheck.tick(getSpecificPlayer(tonumber(M.playerNum) or 0))
end

-- 藍圖換了、搬了、轉了：全部重算（rev 與原點變了 tick 自己也會看到；這裡連記住的結果一起丟）
function PlanCheck.reset()
    cur = nil
    memoDigest = nil
end

-- 還有片在重排或待算。只給 Runner 用：重排中的片 state 照樣回舊狀態（虛影不閃），挑不到片時要分得出是真的沒有、
-- 還是還沒重算完。地上的藍圖不是算的那一張時回 false
function PlanCheck.busy()
    local M = B.PlanMode
    if not (cur and M and M.plan and M.plan() == cur.plan) then return false end
    if cur.rq or cur.ss then return true end
    local q = cur.q
    for k = q.lo, MAX_BUCKET do
        local b = q.b[k]
        if b and b.i <= b.n then return true end
    end
    return false
end

-- 掃描中（重排、同步還沒看完）時，世界座標這一格的片挑不挑得：比它近的片（佇列距離）都已排進佇列、算完了。
-- 照圖蓋在掃描中只挑這種片：身邊的片還沒重算時，不先挑走已經算出能蓋的遠片。沒在掃描時回 true
function PlanCheck.settled(x, y, z)
    local M = B.PlanMode
    if not (cur and (cur.rq or cur.ss) and M and M.plan and M.plan() == cur.plan) then return true end
    local k = dist(x, y, z)
    local ss, rq = cur.ss, cur.rq
    return k <= cur.q.lo and not (ss and k > (ss.ring or RING + 1)) and not (rq and k > (rq.ring or RING + 1))
end

-- 照圖蓋按下時：材料摘要先比一次（不等每秒一次的比對），剛拿到的料馬上排重排，Runner.start 看 busy() 就知道要等
function PlanCheck.refresh(player)
    local M = B.PlanMode
    if not (cur and player and cur.player == player and M and M.plan and M.plan() == cur.plan) then return end
    compareMaterials(player)
end

-- 世界座標這一格有變動：重查這格、上下一層與四鄰（AROUND）的片
function PlanCheck.touch(x, y, z)
    if not cur then return end
    for _, a in ipairs(AROUND) do
        local list = B.Plan.at(cur.plan, x + a[1] - cur.ox, y + a[2] - cur.oy, z + a[3] - cur.oz)
        for j = 1, #list do
            if cur.rec[list[j]] then push(list[j]) end
        end
    end
end

-- { n, done, ok, short, blocked, missing, off, closed, far, pending, byCode }
function PlanCheck.counts()
    local out = { n = 0, done = 0, ok = 0, short = 0, blocked = 0, missing = 0, off = 0, closed = 0, far = 0, pending = 0,
        byCode = {} }
    local M = B.PlanMode
    local plan = M and M.plan and M.plan()
    -- 換了藍圖、或改過還沒同步（下一幀 tick 才重建清單）：全部算待算
    if not (cur and plan == cur.plan and plan.rev == cur.rev) then
        out.n = plan and plan.n or 0
        out.pending = out.n
        return out
    end
    for i = 1, cur.n do
        local p = cur.list[i]
        local s, c = PlanCheck.state(p)
        out.n = out.n + 1
        if s then out[s] = out[s] + 1 else out.pending = out.pending + 1 end
        if c then out.byCode[c] = (out.byCode[c] or 0) + 1 end
    end
    return out
end

-- ===== 材料合計 =====

PlanCheck.costMemo = {}
-- 一片的成本（Cost.forCells＋Cost.sum，同 Check.item 算 info.total 的那一套），照放下的圖名與寬度記住
local function costOf(id, d, x, y, w)
    local entry = Entry.resolve(id)
    if not entry then return nil end
    local spr, offs = placed(entry, d, x, y, w)
    if not spr then return nil end
    local key = spr:getName() .. "|" .. tostring(w)
    local c = PlanCheck.costMemo[key]
    if not c then
        local sprites = {}
        for j, o in ipairs(offs) do sprites[j] = o[4] end
        c = Cost.sum(Cost.forCells(entry.kind, sprites, Check.setting("CostMultiplier", 1)))
        PlanCheck.costMemo[key] = c
    end
    return c
end

-- 還沒蓋好的片（狀態不是 done；這裡蓋不了的項目不算）合計：
-- { need＝{ [fullType 或 use:鍵]＝數量 }, have＝{ 同鍵：現有 }, tools＝{ { tag, has }… }, cheat,
--   recipes＝{ { id, n＝片數, items＝{ { name, need, have, ok }… }, tools＝{ … } }… }（配方的材料照 Recipes.needs，名稱是顯示名） }
function PlanCheck.materials(player)
    local out = { need = {}, have = {}, tools = {}, recipes = {}, cheat = false }
    local M = B.PlanMode
    local plan = M and M.plan and M.plan()
    if not (plan and player) then return out end
    syncMemo()
    local ox, oy = 0, 0
    if M.origin then
        local a, b = M.origin()
        if a then ox, oy = a, b end
    end
    local all, toolSeen, recipeN = {}, {}, {}
    local list = {}
    B.Plan.each(plan, function(p)
        local it = plan.items[p.it]
        if it and PlanCheck.state(p) ~= "done" and PlanCheck.item(it.id) == "ok" then
            if isRecipe(it.id) then
                recipeN[it.id] = (recipeN[it.id] or 0) + 1
            else
                local c = costOf(it.id, p.d, p.x + ox, p.y + oy, p.w)
                if c then list[#list + 1] = c end
            end
        end
    end)
    all = Cost.sum(list)
    local S = Materials.summary(player)
    out.cheat = S.cheat
    for ft, n in pairs(all.items) do
        out.need[ft] = n
        out.have[ft] = S.items[ft]
    end
    for key, n in pairs(all.uses or {}) do
        out.need[Materials.USE .. key] = n
        out.have[Materials.USE .. key] = S.uses[key]
    end
    for _, t in ipairs(all.tools) do
        if not toolSeen[t] then
            toolSeen[t] = true
            out.tools[#out.tools + 1] = { tag = t, has = S.tools[t] == true }
        end
    end
    local R = recipesOf()
    if R and R.get and R.needs then
        local pn = player:getPlayerNum()
        for id, n in pairs(recipeN) do
            local r = R.get(id)
            local ok, needs = pcall(R.needs, pn, r)
            if ok and needs then
                local items = {}
                for i, row in ipairs(needs.items) do
                    items[i] = { name = row.name, need = row.need * n, have = row.have, ok = S.cheat or row.have >= row.need * n }
                end
                out.recipes[#out.recipes + 1] = { id = id, n = n, items = items, tools = needs.tools }
            end
        end
    end
    return out
end

-- 除錯重新載入 Lua 時不再掛一次（同 PlanMode）；包一層才會叫到重新載入後的函式
if not PlanCheck.loaded then
    PlanCheck.loaded = true
    Events.OnTick.Add(function() MinidoracatBuilder.PlanCheck.onTick() end)
end

return PlanCheck
