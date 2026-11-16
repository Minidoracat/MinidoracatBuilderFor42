-- 藍圖每一片在世界上的狀態（只在客戶端、只給畫面與照圖蓋用）：地上的藍圖向 PlanMode 要，分幀算、由近到遠。
-- 「蓋好了」只看世界上那一格有沒有同一張圖（誰蓋的、地圖原有的都算；門開著、窗破了、多格物件的其他片都認回同一張），
-- 沒有才問 Check.item（帶游標預覽同一組 opts），能不能蓋不另外判斷。配方項目看 Recipes。
-- 算完整張後只重查有變動的片：PlanCheck.touch 的格子、背包或技能變了（材料摘要每秒比一次）、沙盒設定變了、
-- 玩家換樓層或走開 MOVE 格（重查還沒載入或太遠的片）、玩家身邊 NEAR 格內格上的物件數變了（每幀輪流比一段）。
-- 會自己消失、又不改物件數的原因（PlanCheck.RECHECK：有人或車擋著、配方太暗）看不出來：身邊的片隔一段時間重查一次。
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
local MAX_BUCKET = 255
local SHORT = { NO_MATERIAL = true, NO_TOOL = true }
local FAR = { TOO_FAR = true, NOT_LOADED = true }
local OFF = { DISABLED_KIND = true, DISABLED_SOURCE = true, DISABLED_TILESET = true }

local cur -- { plan, rev, ox, oy, oz, list = { 片… }, n, rec = { [片] = 紀錄 }, q, S, sAt, digest, px, py, pz, sweep }
local canonMemo, itemMemo, memoDigest = {}, {}, nil

-- 項目、認圖、成本的快取都照沙盒摘要（種類開關、停用來源與圖塊組、成本倍率）：摘要變了全部丟掉
local function syncMemo()
    local dg = Entry.digest()
    if dg ~= memoDigest then
        canonMemo, itemMemo, PlanCheck.costMemo, memoDigest = {}, {}, {}, dg
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

-- 圖塊項目在世界上這一格（錨點）放的那一張（朝向、交替柵欄照 Check.item 同一套）與佔地；沒有那一面回 nil
local function placed(entry, d, x, y, w)
    local spr = Entry.face(entry, d)
    if not spr then return nil end
    spr = Entry.alternate(spr, x, y)
    local set = entry.kind == "door" and Entry.doorSet(spr)
    local offs = set and set.garage and Entry.groupCells(set, w or 2) or Entry.cells(spr)
    return spr, offs, set
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
        return s ~= nil and eachTile(s, function(name) return name == want end)
    end
    local entry = Entry.resolve(id)
    if not entry then return hasTile(sq, id) end -- 這裡關掉了，世界上照樣可能有
    local spr, offs, set = placed(entry, d, x, y, w)
    if not spr then return false end
    if set then -- 車庫門、雙開門：整扇的每一格都要有這一組的片（開著關著都算）
        for _, o in ipairs(offs) do
            local s = cell:getGridSquare(x + o[1], y + o[2], z + o[3])
            if not (s and eachTile(s, function(name) return set.members[name] == true end)) then return false end
        end
        return true
    end
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

-- 一片的狀態, 細節碼。算的時候的藍圖、位置（含現在的原點）、項目、朝向、疊放、寬度和現在不一樣（搬了、換了）回 nil
function PlanCheck.state(piece)
    local r = cur and cur.rec[piece]
    if not (r and r.s) then return nil end
    local M = B.PlanMode
    if not (M and M.plan and M.plan() == cur.plan) then return nil end
    local id, x, y, z, d, o, w = PlanCheck.resolve(piece)
    if id ~= r.id or x ~= r.x or y ~= r.y or z ~= r.z or d ~= r.d or o ~= r.o or w ~= r.w then return nil end
    return r.s, r.c
end

-- ===== 佇列：照距離分桶，由近到遠（不排序，家族規則） =====

local function dist(x, y, z)
    local d = math.max(math.abs(x - cur.px), math.abs(y - cur.py)) + 8 * math.abs(z - cur.pz)
    return math.min(MAX_BUCKET, math.floor(d))
end

local function push(p)
    local r = cur.rec[p]
    if r.q then return end
    r.q = true
    local q = cur.q
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

local function requeue(pred)
    for i = 1, cur.n do
        local p = cur.list[i]
        local r = cur.rec[p]
        if pred(r) then push(p) end
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
    r.sig = sigOf(sq)
    local ok, done = pcall(built, id, x, y, z, d, w, sq)
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
        S = Materials.summary(player), sAt = getTimestampMs(), digest = Entry.digest(), player = player,
        px = math.floor(player:getX()), py = math.floor(player:getY()), pz = math.floor(player:getZ()), sweep = 0 }
end

-- 藍圖換了、rev 或原點變了：重建片的清單，位置或內容變了的片（含新的）排進佇列，其他的保留結果
local function sync(plan, ox, oy, oz, player)
    if not cur or cur.plan ~= plan or cur.player ~= player then fresh(plan, ox, oy, oz, player) end
    if cur.rev == plan.rev and cur.ox == ox and cur.oy == oy and cur.oz == oz then return end
    cur.rev, cur.ox, cur.oy, cur.oz = plan.rev, ox, oy, oz
    local old, rec, list, n = cur.rec, {}, {}, 0
    cur.rec = rec
    B.Plan.each(plan, function(p)
        n = n + 1
        list[n] = p
        rec[p] = old[p] or { q = false }
    end)
    cur.list, cur.n = list, n
    for i = 1, n do
        local p = list[i]
        local r = rec[p]
        local it = plan.items[p.it]
        if r.q or not it or r.id ~= it.id or r.x ~= p.x + ox or r.y ~= p.y + oy or r.z ~= p.z + oz or r.d ~= p.d
            or r.o ~= p.o or r.w ~= p.w then
            r.q = false -- 舊佇列裡的位置作廢：照新的距離重排
            push(p)
        end
    end
end

local function changed(now, player)
    if now - cur.sAt >= PlanCheck.SUMMARY_MS then
        cur.sAt = now
        local digest = Entry.digest()
        if digest ~= cur.digest then -- 沙盒的種類、來源、倍率變了：全部重算
            cur.digest = digest
            requeue(function() return true end)
        end
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
            requeue(function(r) return r.s == "ok" or r.s == "short" or r.c == "SKILL" or r.c == "DARK" end)
        end
        cur.S = S
    end
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    if pz ~= cur.pz or math.abs(px - cur.px) + math.abs(py - cur.py) >= PlanCheck.MOVE then
        cur.px, cur.py, cur.pz = px, py, pz
        requeue(function(r) return r.s == "far" end)
    end
end

-- 身邊 NEAR 格內的片，每幀輪流比一段格上的物件數；變了就重查。RECHECK 的片到時間就重查（時鐘往回調時也查）
local function sweep(player, now)
    local n = cur.n
    if n == 0 then return end
    local cell, near = getCell(), PlanCheck.NEAR
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    for _ = 1, math.min(n, PlanCheck.SWEEP) do
        local i = cur.sweep % n + 1
        cur.sweep = i
        local p = cur.list[i]
        local r = cur.rec[p]
        if r.s and not r.q and r.s ~= "far" then
            local x, y, z = p.x + cur.ox, p.y + cur.oy, p.z + cur.oz
            if math.abs(x - px) <= near and math.abs(y - py) <= near and math.abs(z - pz) <= 1 then
                local every = r.c and PlanCheck.RECHECK[r.c]
                local dt = every and now - (r.at or 0)
                if dt and (dt < 0 or dt >= every) then
                    r.at = now
                    push(p)
                elseif sigOf(cell:getGridSquare(x, y, z)) ~= r.sig then
                    push(p)
                end
            end
        end
    end
end

-- 掛 OnTick：每幀最多 BUDGET_MS 毫秒，至少算一片
function PlanCheck.tick(player)
    local M = B.PlanMode; local plan = M and M.plan and M.plan(); if not plan then return end
    if not (player and M.origin) then return end
    local ox, oy, oz = M.origin()
    if not ox then return end
    sync(plan, ox, oy, oz, player)
    local now = getTimestampMs()
    local stop = now + PlanCheck.BUDGET_MS
    changed(now, player)
    sweep(player, now)
    repeat
        local p, r = pop()
        if not p then return end
        evaluate(player, p, r)
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

-- 世界座標這一格有變動：重查這格、上一層（屋頂、地板靠下面的牆撐）與四鄰（同一條邊的另一側）的片
local AROUND = { { 0, 0, 0 }, { 0, 0, 1 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 } }
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
