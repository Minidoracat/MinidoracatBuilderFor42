-- 照圖蓋：照地上的藍圖一批一批送現有的建造請求（Queue.push，owner＝"plan"），伺服器照樣每片檢查、扣料、記帳，不新增指令。
-- 一批＝同一個項目、同一層、離玩家最近的幾格（最多沙盒「一次最多幾格」）；順序固定六段（SEGMENT），同一段先低層、再近的。
-- 每次挑批都重看各片狀態（PlanCheck.state），所以前面蓋好之後才撐得住的片（上層地板、屋頂）下一批就挑得到。
-- 能不能蓋只問 Check.item（帶 preview），缺料、被擋、走不到的跳過，一輪結束後 summary 一次列出；再按一次照圖蓋從剩下的接著蓋。
-- 材料箱：玩家點名的容器（存 PlanStore 的 boxes）。背包缺料時走到箱子旁邊，用原版搬運動作拿這一批缺的，拿到不超重為止。
-- 一切只在客戶端，不寫 modData；沒有在蓋時 OnTick 第一行就離開。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Check"
require "MinidoracatBuilder/Materials"
require "MinidoracatBuilder/Messages"
require "MinidoracatBuilder/Names"
require "MinidoracatBuilder/Queue"
require "MinidoracatBuilder/PlanStore"
require "MinidoracatBuilder/Plan"

MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local Runner = B.Runner or {}
B.Runner = Runner
local Entry, Check, Materials, Messages, Names, Queue = B.Entry, B.Check, B.Materials, B.Messages, B.Names, B.Queue

local LOG = "[MinidoracatBuilderFor42] "
local WAIT_MS = 3000   -- 挑批時還有片沒算出狀態（PlanCheck 分幀算）最多等多久
local RETRY_MS = 250   -- 等狀態時多久再挑一次
local SETTLE_MS = 300  -- 拿料的動作佇列空了這麼久才看拿到沒有
local SETTLE_END_MS = 2000 -- 一批蓋完後 PlanCheck 分幀重查四鄰與上一層：這段時間內挑不到不算蓋完，等重查完再挑
local RECIPE = "recipe:"
local NAILS, NAILS_BOX, PER_BOX = "Base.Nails", "Base.NailsBox", 100 -- 同 Materials：釘子盒一盒算 100 根

-- 六段順序：地板與地面覆蓋 → 牆、柱、門框、窗框、柵欄 → 樓梯 → 門、窗、窗簾 → 屋頂 → 家具、容器、燈、掛牆物與其他。
-- 鍵＝Rules 的種類（Entry.KINDS）；車庫門、雙開門歸 door，配方項目照 Recipes 的 kind。harness 檢查每個種類都有段。
Runner.SEGMENT = {
    floor = 1, floorOverlay = 1, water = 1,
    wall = 2, fence = 2, post = 2, doorFrame = 2, windowFrame = 2,
    stairs = 3,
    door = 4, window = 4, curtain = 4, windowObject = 4,
    roof = 5,
    furniture = 6, container = 6, solid = 6, well = 6, light = 6, wallObject = 6, wallOverlay = 6, attached = 6,
    overlay = 6, plant = 6,
}
local LAST_SEGMENT = 6

-- 這些拒絕碼是請求本身（或這位玩家）不行，不是那一片的事：照「伺服器拒絕整批」暫停
local WHOLE = { OFF = true, NOT_ALLOWED = true, STALE = true, RATE_LIMITED = true, NO_INTENT = true, BAD_REQUEST = true,
    STATE = true, INTERNAL = true }

-- st.state："idle"｜"pick"｜"build"｜"fetch"｜"check"（一批停下，下一幀看是誰停的）｜"paused"｜"done"
-- st.later＝材料箱有料但背不動而先放著的片：這一輪有片蓋好（背包輕了）才重新挑
local st = { state = "idle", skip = {}, placed = {}, bad = {}, stepped = {}, later = {} }
local listeners = {}
local summary, summaryAt

local function notify()
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn)
        if not ok then print(LOG .. "runner listener failed: " .. tostring(err)) end
    end
end

local function active()
    local s = st.state
    return s == "pick" or s == "build" or s == "fetch" or s == "check"
end

local function planCheck() return B.PlanCheck end

-- 這片的 項目 ID, x, y, z, d, 疊放, w（車庫門寬度）
local function resolve(p)
    local PC = planCheck()
    if not (PC and PC.resolve) then return nil end
    local id, x, y, z, d, o, w = PC.resolve(p)
    return id, x, y, z, d, o, w or p.w
end

local function kindOf(id)
    if type(id) ~= "string" then return nil end
    if id:sub(1, #RECIPE) == RECIPE then
        local R = B.Recipes
        local r = R and R.get and R.get(id)
        return r and r.kind or "furniture"
    end
    local e = Entry.resolve(id)
    return e and e.kind or nil
end

-- 項目 → 段（查過的記著；換藍圖時清掉）
local segCache = {}
local function segmentOf(id)
    local s = segCache[id]
    if s == nil then
        local k = kindOf(id)
        s = k and Runner.SEGMENT[k] or LAST_SEGMENT
        segCache[id] = s
    end
    return s
end

local function itemName(id)
    if not id then return nil end
    if id:sub(1, #RECIPE) == RECIPE then
        local R = B.Recipes
        local r = R and R.get and R.get(id)
        return r and r.name or id
    end
    return Names.of(id, kindOf(id))
end

-- ---------------------------------------------------------------- 原因

-- 給玩家看的一句。detail＝伺服器拒絕整批時的拒絕碼與附帶欄位
local function reasonText(code, detail, extra)
    if code == "REFUSED" then return getText("IGUI_MBLD_Run_REFUSED", Messages.refusal(detail, extra)) end
    if code == "LEFT" then return getText("IGUI_MBLD_Run_LEFT", tostring(summary and summary.left or 0)) end
    if code == "DONE" and detail == "KEEP" then return getText("IGUI_MBLD_Run_DONE_KEEP") end
    return getText("IGUI_MBLD_Run_" .. code)
end

-- 跳過的片的原因：拒絕碼照 Messages；本檔與 PlanCheck 自己的碼（DARK、COVER、DOOR_WIDE 用 PlanCheck 那幾句）另有一句
function Runner.codeText(code, extra)
    if Messages.CODES[code] then return Messages.refusal(code, extra) end
    code = tostring(code)
    return getTextOrNull("IGUI_MBLD_RunSkip_" .. code) or getTextOrNull("IGUI_MBLD_Refuse_" .. code)
        or getText("IGUI_MBLD_Refuse_Other", code)
end

-- ---------------------------------------------------------------- 總結

-- 沒蓋的片：{ left, short＝{ n, need＝{ [fullType]＝還差幾個 }, tools＝{ 缺的工具標籤 } }, blocked＝{ [碼]＝片數 },
-- skill＝{ n, perks＝{ [技能]＝要幾級 } }, boxes＝{ [第幾個材料箱]＝跳過的原因 } }
local function buildSummary()
    local PM, PC = B.PlanMode, planCheck()
    local plan = PM and PM.plan and PM.plan()
    local out = { left = 0, short = { n = 0, need = {}, tools = {} }, blocked = {}, skill = { n = 0, perks = {} }, boxes = {} }
    for i, why in pairs(st.badIndex or {}) do out.boxes[i] = why end
    if not (plan and PC and PC.state) then return out end
    local P = B.Plan
    P.each(plan, function(p)
        local state, detail = PC.state(p)
        if state == "done" or st.placed[p] then return end
        out.left = out.left + 1
        local sk = st.skip[p]
        local code = sk and sk.code
        if not code then
            if state == "short" then code = detail or "NO_MATERIAL"
            elseif state == "ok" or state == nil then code = nil
            elseif state == "blocked" and detail then code = detail
            else code = string.upper(state) end -- MISSING、OFF、CLOSED、FAR
        end
        if code == "NO_MATERIAL" or code == "NO_TOOL" then
            out.short.n = out.short.n + 1
        elseif code == "SKILL" then
            out.skill.n = out.skill.n + 1
            local e = sk and sk.extra
            if e and e.perk then out.skill.perks[e.perk] = math.max(out.skill.perks[e.perk] or 0, tonumber(e.level) or 0) end
        elseif code then
            out.blocked[code] = (out.blocked[code] or 0) + 1
        end
    end)
    -- 缺多少照整張的合計（PlanCheck.materials，和面板同一套）
    local m = PC.materials and st.player and PC.materials(st.player)
    if m then
        for ft, n in pairs(m.need or {}) do
            local have = (m.have or {})[ft] or 0
            if n > have then out.short.need[ft] = n - have end
        end
        for _, t in ipairs(m.tools or {}) do
            if not t.has then out.short.tools[#out.short.tools + 1] = t.tag end
        end
    end
    return out
end

function Runner.summary()
    local t = getTimestampMs()
    if summary and (not active() or (summaryAt and t >= summaryAt and t - summaryAt < 1000)) then return summary end
    summary, summaryAt = buildSummary(), t
    return summary
end

local function summaryLines(s)
    local lines = {}
    if s.short.n > 0 then
        local what = Messages.missing(s.short.need, s.short.tools)
        lines[#lines + 1] = getText("IGUI_MBLD_Run_Short", tostring(s.short.n), what)
    end
    if s.skill.n > 0 then lines[#lines + 1] = getText("IGUI_MBLD_Run_Skill", tostring(s.skill.n)) end
    -- 件數多的在前（逐筆插入，不用 table.sort）
    local rows = {}
    for code, n in pairs(s.blocked) do
        local i = #rows + 1
        while i > 1 and (rows[i - 1].n < n or (rows[i - 1].n == n and rows[i - 1].code > code)) do
            rows[i] = rows[i - 1]
            i = i - 1
        end
        rows[i] = { code = code, n = n }
    end
    for _, r in ipairs(rows) do
        lines[#lines + 1] = getText("IGUI_MBLD_Run_Count", tostring(r.n), Runner.codeText(r.code))
    end
    for i, why in pairs(s.boxes) do
        lines[#lines + 1] = getText("IGUI_MBLD_Run_Box", tostring(i), getText("IGUI_MBLD_RunBox_" .. why))
    end
    return lines
end

-- ---------------------------------------------------------------- 狀態切換

local function cancelOurs()
    local p = st.player
    if not p then return end
    st.batch = nil -- 先清掉：Queue.cancel 會同步叫 onDone，那時不再當成這一批停下
    -- 拿料的動作還在佇列才清：玩家自己動手時本 MOD 的建造、拆除、配方已經清掉它們、換成玩家的動作（Client.build 等）
    local f = st.fetch
    st.fetch = nil
    for _, a in ipairs(f and f.actions or {}) do
        if ISTimedActionQueue.hasAction(a) then
            ISTimedActionQueue.clear(p)
            break
        end
    end
    Queue.cancel(p, "plan")
    local R = B.Recipes
    if R and R.stopCells then
        local ok, err = pcall(R.stopCells, p)
        if not ok then print(LOG .. "runner stopCells failed: " .. tostring(err)) end
    end
end

local function halt(state, code, detail, extra, quiet)
    if not active() and st.state ~= "paused" then return end
    cancelOurs()
    st.state, st.reason, st.detail, st.extra = state, code, detail, extra
    summary, summaryAt = buildSummary(), getTimestampMs()
    if not quiet and st.player then
        local lines = { reasonText(code, detail, extra) }
        if code == "LEFT" then
            for _, l in ipairs(summaryLines(summary)) do lines[#lines + 1] = l end
        end
        local c = B.PlanCheck and B.PlanCheck.counts and B.PlanCheck.counts()
        local title = getText("IGUI_MBLD_Run_Title")
        if c and c.n then title = getText("IGUI_MBLD_Run_Progress", tostring(c.done or 0), tostring(c.n)) end
        -- 通知只照寬度斷行，不認換行或 <LINE>（UI 框架 Toast 的 wrapText）：幾段用空白接
        Messages.toast(st.player, table.concat(lines, " "), title, 12)
    end
    notify()
end

-- 暫停（蓋好的保留）。reason 省略＝玩家按了暫停。參數用 ... 接：Kahlua 少傳的參數不保證是 nil（家族 pitfalls）
function Runner.pause(...)
    if not active() then return end
    local reason, detail, extra = ...
    halt("paused", reason or "PAUSE", detail, extra, reason == nil)
end

function Runner.stop(...)
    local reason = ...
    if not active() and st.state ~= "paused" then return end
    halt("done", reason or "STOP", nil, nil, reason == nil)
end

-- 玩家用本 MOD 的入口自己動手（配方單放、拖一排、牆面油漆）：入口在排玩家的動作之前叫，照圖蓋暫停 MANUAL。
-- 照圖蓋自己送的配方走 Recipes.runCells，不經過這些入口；分割畫面的另一位玩家動手不算
function Runner.manual(player)
    if active() and player == st.player then halt("paused", "MANUAL") end
end

-- "idle"｜"pick"｜"build"｜"fetch"｜"paused"｜"done"（內部的 check、讓位走開的那幾步對外算 build）
function Runner.state() return (st.state == "check" or (st.state == "fetch" and st.asideFor ~= nil)) and "build" or st.state end

-- 暫停或結束的原因：碼, 給玩家看的一句；沒有回 nil
function Runner.reason()
    if not st.reason or active() then return nil end
    return st.reason, reasonText(st.reason, st.detail, st.extra)
end

function Runner.progress()
    local c = B.PlanCheck and B.PlanCheck.counts and B.PlanCheck.counts()
    return { done = c and c.done or 0, total = c and c.n or 0, name = st.batch and itemName(st.batch.id) or nil }
end

function Runner.changed(fn)
    listeners[#listeners + 1] = fn
end

-- ---------------------------------------------------------------- 材料箱

-- 一格上第 index 個容器（照物件順序、再照物件裡的容器順序數，從 0 起）。
-- shortcut：同一格的容器增減後編號會移到別的容器；同一格疊兩個以上容器時才會碰到，要更穩時改記容器種類比對
local function containerAt(sq, index)
    local objs = sq:getObjects()
    local k = 0
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        for ci = 0, o:getContainerCount() - 1 do
            if k == index then return o:getContainerByIndex(ci), o end
            k = k + 1
        end
    end
    return nil
end

local function indexOf(container)
    local obj = container and container:getParent()
    local sq = obj and obj:getSquare()
    if not sq then return nil end
    local objs = sq:getObjects()
    local k = 0
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        for ci = 0, o:getContainerCount() - 1 do
            if o:getContainerByIndex(ci) == container then return sq:getX(), sq:getY(), sq:getZ(), k end
            k = k + 1
        end
    end
    return nil
end

-- PlanStore 的整份狀態（讀檔錯誤當沒有）
local function loadStore()
    local ok, state = pcall(B.PlanStore.load)
    if ok and type(state) == "table" then return state end
    return {}
end

-- 點名的材料箱：{ { x, y, z, index }… }（每次從 PlanStore 讀，PlanMode 改寫同一個檔也不會錯過）
function Runner.boxes()
    return loadStore().boxes or {}
end

-- 這個容器是第幾個點名的材料箱，沒有回 nil
function Runner.boxOf(container)
    local x, y, z, k = indexOf(container)
    if not x then return nil end
    for i, b in ipairs(Runner.boxes()) do
        if b.x == x and b.y == y and b.z == z and b.index == k then return i end
    end
    return nil
end

-- 點名一個容器；回它是第幾個，或 nil, 原因碼（不是世界上的容器、寫檔失敗）
function Runner.addBox(container)
    local x, y, z, k = indexOf(container)
    if not x then return nil, "NOT_BOX" end
    local state = loadStore()
    state.boxes = state.boxes or {}
    for i, b in ipairs(state.boxes) do
        if b.x == x and b.y == y and b.z == z and b.index == k then return i end
    end
    state.boxes[#state.boxes + 1] = { x = x, y = y, z = z, index = k }
    local ok, why = B.PlanStore.save(state)
    if not ok then return nil, why end
    notify()
    return #state.boxes
end

function Runner.removeBox(i)
    local state = loadStore()
    local boxes = state.boxes or {}
    if type(i) ~= "number" or not boxes[i] then return false end
    table.remove(boxes, i)
    state.boxes = boxes
    local ok = B.PlanStore.save(state)
    notify()
    return ok == true
end

-- 照原版的拿取規則（ISInventoryPage.lua:1685 別人的安全屋不列、:1744 上鎖的 IsoThumpable 不能開）；
-- 其他（容器不收、拿不走、負重）在原版搬運動作的 isValid 再擋（ISInventoryTransferAction.lua:11-126）
local function openBox(player, b)
    local sq = getCell():getGridSquare(b.x, b.y, b.z)
    if not sq then return nil, "FAR" end
    local container, obj = containerAt(sq, b.index)
    if not container then return nil, "GONE" end
    if isClient() and SafeHouse and SafeHouse.isSafehouseAllowLoot and not SafeHouse.isSafehouseAllowLoot(sq, player) then
        return nil, "SAFEHOUSE"
    end
    if instanceof(obj, "IsoThumpable") and obj:isLockedToCharacter(player) then return nil, "LOCKED" end
    return container
end

-- 能當材料的：同 Materials 的 usable（裝著東西的袋子、裝著液體的容器不算）
local function usable(item)
    if instanceof(item, "InventoryContainer") then return item:getInventory():getItems():isEmpty() end
    return not item:isFluidContainer() or item:isEmptyOfFluid()
end

-- 這一批要的種類各最多幾件（sets＝{ { [fullType]＝數量 }… }，一片一組）；要釘子時另算幾盒釘子盒
local function wanted(sets)
    local want = {}
    for _, set in ipairs(sets) do
        for ft, n in pairs(set) do want[ft] = (want[ft] or 0) + n end
    end
    if want[NAILS] then want[NAILS_BOX] = (want[NAILS_BOX] or 0) + math.ceil(want[NAILS] / PER_BOX) end
    return want
end

-- 一個箱子裡這一批要的東西：{ it, ft, c＝這個箱子 }…，每種最多記要的件數，無關的東西不進表
local function scan(c, want)
    local found, n = {}, {}
    local items = c.container:getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        local ft = it:getFullType()
        if want[ft] and (n[ft] or 0) < want[ft] and usable(it) then
            n[ft] = (n[ft] or 0) + 1
            found[#found + 1] = { it = it, ft = ft, c = c }
        end
    end
    return found
end

-- 從能開的點名箱子（cands，近的在前）挑這一批缺的，一片一組、照蓋的順序。
-- 一組要的東西在這些箱子裡湊得齊、整組背得動才挑：照箱子裡的順序拿到滿的話只會拿到排前面那一種（負重剩 6 拿兩片
-- 木板就滿），一片都配不齊。重量照真的那幾件算（另一個箱子只有釘子盒時算整盒）。
-- 箱子只掃一遍記在 c.found：前面的箱子走不到、重新挑時不重掃。回 挑到的 { it, ft, c }…、有沒有背不動的組
local function choose(player, cands, sets, want)
    local stock, at = {}, {} -- at＝各種類挑到第幾個
    for _, c in ipairs(cands) do
        c.found = c.found or scan(c, want)
        for _, e in ipairs(c.found) do
            local q = stock[e.ft]
            if not q then
                q = {}
                stock[e.ft], at[e.ft] = q, 1
            end
            if #q < want[e.ft] then q[#q + 1] = e end
        end
    end
    local room = player:getMaxWeight() - player:getInventory():getCapacityWeight()
    local out, heavy, spare = {}, false, 0 -- spare＝已挑的釘子盒還能抵幾根釘子
    for _, set in ipairs(sets) do
        local got, w, to, left, full = {}, 0, {}, spare, true
        for ft, n in pairs(set) do
            if ft ~= NAILS then
                local q, k = stock[ft], at[ft]
                while n > 0 and q and q[k] do
                    got[#got + 1], w, k, n = q[k], w + q[k].it:getUnequippedWeight(), k + 1, n - 1
                end
                to[ft] = k
                if n > 0 then full = false end
            end
        end
        -- 釘子放最後：先用已挑的釘子盒剩的，再挑散的，再挑整盒（這一組自己也要整盒時不挑同一盒）
        local n = set[NAILS] or 0
        if n > 0 then
            local t = math.min(n, left)
            n, left = n - t, left - t
            local q, k = stock[NAILS], at[NAILS]
            while n > 0 and q and q[k] do
                got[#got + 1], w, k, n = q[k], w + q[k].it:getUnequippedWeight(), k + 1, n - 1
            end
            to[NAILS] = k
            q, k = stock[NAILS_BOX], to[NAILS_BOX] or at[NAILS_BOX]
            while n > 0 and q and q[k] do
                t = math.min(n, PER_BOX)
                got[#got + 1], w, k, n, left = q[k], w + q[k].it:getUnequippedWeight(), k + 1, n - t, left + PER_BOX - t
            end
            to[NAILS_BOX] = k
            if n > 0 then full = false end
        end
        if full and w > room then
            heavy = true
        elseif full then
            for _, g in ipairs(got) do out[#out + 1] = g end
            for ft, k in pairs(to) do at[ft] = k end
            room, spare = room - w, left
        end
    end
    return out, heavy
end

local function boxKey(b) return b.x .. "," .. b.y .. "," .. b.z .. "," .. b.index end

-- 箱子這一趟不能用：why 列進總結。hard＝這一輪都不再試（不見、鎖住、走不到）；沒有要的、背不動只是這一批的事
local function boxFailed(o, why, hard)
    if hard then st.bad[boxKey(o.b)] = why end
    st.badIndex = st.badIndex or {}
    st.badIndex[o.i] = why
end

-- 這一批缺的去點名的箱子拿：能開的箱子一起看，這一趟去拿得到東西的裡面最近的那個，走過去並排搬運動作。
-- 回 true＝開始拿了；沒開始時再回是不是因為背不動
local function startFetch(player, sets)
    local boxes = Runner.boxes()
    local px, py = player:getX(), player:getY()
    local order = {}
    for i, b in ipairs(boxes) do
        if not st.bad[boxKey(b)] then
            local d = (b.x + 0.5 - px) ^ 2 + (b.y + 0.5 - py) ^ 2
            local k = #order + 1
            while k > 1 and order[k - 1].d > d do
                order[k] = order[k - 1]
                k = k - 1
            end
            order[k] = { b = b, i = i, d = d }
        end
    end
    local cands = {}
    for _, o in ipairs(order) do
        local container, why = openBox(player, o.b)
        if container then
            cands[#cands + 1] = { container = container, o = o }
        else
            boxFailed(o, why, true)
        end
    end
    local inv, want = player:getInventory(), wanted(sets)
    while cands[1] do
        local picks, heavy = choose(player, cands, sets, want)
        if not picks[1] then
            -- 各箱子的原因是這一批的概括：有要的東西但背不動＝HEAVY，其餘＝EMPTY
            for _, c in ipairs(cands) do boxFailed(c.o, heavy and c.found[1] and "HEAVY" or "EMPTY", false) end
            return false, heavy
        end
        local c = picks[1].c
        for _, g in ipairs(picks) do
            if g.c.o.d < c.o.d then c = g.c end
        end
        if luautils.walkToContainer(c.container, player:getPlayerNum()) then
            local before, actions = {}, {}
            for _, g in ipairs(picks) do
                if g.c == c then
                    before[g.ft] = inv:getCountTypeRecurse(g.ft)
                    actions[#actions + 1] = ISInventoryTransferAction:new(player, g.it, c.container, inv)
                    ISTimedActionQueue.add(actions[#actions])
                end
            end
            st.fetch = { box = c.o.b, i = c.o.i, before = before, actions = actions }
            if st.badIndex then st.badIndex[c.o.i] = nil end
            return true, false
        end
        boxFailed(c.o, "NO_ROOM", true)
        for k, x in ipairs(cands) do
            if x == c then
                table.remove(cands, k)
                break
            end
        end
    end
    return false, false
end

-- 拿料的動作做完：一件都沒拿到（上鎖、安全屋、被別人拿走…原版動作的 isValid 擋下）就跳過這個箱子
local function fetchDone(player)
    local f = st.fetch
    st.fetch = nil
    if not f then return end
    local inv, got = player:getInventory(), false
    for ft, n in pairs(f.before) do
        if inv:getCountTypeRecurse(ft) > n then got = true end
    end
    if not got then
        st.bad[boxKey(f.box)] = "FAILED"
        st.badIndex = st.badIndex or {}
        st.badIndex[f.i] = "FAILED"
    end
end

-- ---------------------------------------------------------------- 挑批

local function skip(p, code, extra)
    st.skip[p] = { code = code, extra = extra }
end

-- 有變動的片：PlanCheck 重查那一格與上下一層、四鄰（上層地板與屋頂靠它們撐，PlanCheck.touch）
local function touch(x, y, z)
    local PC = planCheck()
    if PC and PC.touch then PC.touch(x, y, z) end
end

-- 這一輪開始後藍圖改過（片的增刪、搬、轉、換項目都會加 rev；原點換了＝整張搬了）：送出的批次結果不能再對到片上
local function planChanged()
    local PM = B.PlanMode
    local ox, oy, oz
    if PM and PM.origin then ox, oy, oz = PM.origin() end
    return st.plan.rev ~= st.rev or ox ~= st.ox or oy ~= st.oy or oz ~= st.oz
end

local function perBatch()
    return math.max(1, math.floor(tonumber(Entry.settings().MaxCellsPerDrag) or 32))
end

-- 整張找下一批：可蓋（或缺料而有材料箱）的片裡段最前、層最低、離玩家最近的那片，再收同項目、同層、同疊放值最近的幾片。
-- 回 batch，"wait"（還有片沒算出狀態），或 nil（沒有能蓋的）
local function pickBatch(player, plan)
    local PC = planCheck()
    local boxes = #Runner.boxes() > 0
    local px, py = player:getX(), player:getY()
    local best, bk1, bk2, bk3, pendingSeg
    local cand = {}
    B.Plan.each(plan, function(p)
        -- 蓋好的片在 PlanCheck 重查之前狀態還是 ok：記著不再送（疊放的項目再送一次會蓋第二個）
        if st.skip[p] or st.placed[p] or st.later[p] then return end
        local state = PC.state(p)
        if state == nil then
            local id = resolve(p)
            local s = id and segmentOf(id)
            if s and (not pendingSeg or s < pendingSeg) then pendingSeg = s end
            return
        end
        if not (state == "ok" or (state == "short" and boxes)) then return end
        local id, x, y, z, d, o, w = resolve(p)
        if not id then return end
        local c = { p = p, id = id, x = x, y = y, z = z, d = d, o = o, w = w, seg = segmentOf(id),
            dist = (x + 0.5 - px) ^ 2 + (y + 0.5 - py) ^ 2 }
        cand[#cand + 1] = c
        if not best or c.seg < bk1 or (c.seg == bk1 and (c.z < bk2 or (c.z == bk2 and c.dist < bk3))) then
            best, bk1, bk2, bk3 = c, c.seg, c.z, c.dist
        end
    end)
    if pendingSeg and (not best or pendingSeg < bk1) then
        local t = getTimestampMs()
        st.waitFrom = st.waitFrom or t
        if t < st.waitFrom then st.waitFrom = t end
        if t - st.waitFrom < WAIT_MS then return "wait" end
    end
    st.waitFrom = nil
    if not best then return nil end
    local garage = false
    if best.id:sub(1, #RECIPE) ~= RECIPE then
        local e = Entry.resolve(best.id)
        local set = e and e.kind == "door" and Entry.doorSet(e.spr)
        garage = set and set.garage or false
        if garage and not best.w then
            skip(best.p, "GARAGE_WIDTH")
            return "again"
        end
    end
    -- 同項目、同層、同疊放值最近的幾片（逐筆插入，最多 max 片）。車庫門一扇一次（伺服器只收一個錨點，Doors 的回報）
    local max = garage and 1 or perBatch()
    local list = {}
    for _, c in ipairs(cand) do
        if c.id == best.id and c.z == best.z and c.o == best.o then
            local k = #list + 1
            if k <= max or c.dist < list[max].dist then
                if k > max then k = max end
                while k > 1 and list[k - 1].dist > c.dist do
                    list[k] = list[k - 1]
                    k = k - 1
                end
                list[k] = c
            end
        end
    end
    return { id = best.id, z = best.z, overlap = best.o == 1 or best.o == true, garage = garage, list = list }
end

-- 這一批逐片問 Check.item（同游標預覽：可蓋的照順序扣掉材料，屋頂、地板能靠前面可蓋的撐）。
-- 回 可蓋的 { c, info }…、缺料的片各缺什麼（一片一組，只算缺的物品；耗材與工具不拿）
local function evaluate(player, b)
    local S = Materials.summary(player)
    local work = {}
    for k, v in pairs(S) do work[k] = v end
    work.items = setmetatable({}, { __index = S.items })
    work.uses = setmetatable({}, { __index = S.uses })
    local ok, sets, short, planned = {}, {}, {}, {}
    for _, c in ipairs(b.list) do
        local a = { c.x, c.y, c.z, c.d, c.w }
        local fine, code, extra, info = pcall(Check.item, player, b.id, c.d, a,
            { preview = true, walk = true, summary = work, planned = planned, overlap = b.overlap or nil })
        if not fine then
            print(LOG .. "runner check failed e=" .. tostring(b.id) .. ": " .. tostring(code))
            code, extra, info = "INTERNAL", nil, nil
        end
        local cost = info and (info.replace and { items = info.pay or {}, uses = info.total and info.total.uses } or info.total)
        if code == nil then
            if cost then Materials.take(work, cost) end
            ok[#ok + 1] = { c = c, a = a, info = info }
            if info and info.entry and (info.entry.kind == "roof" or info.entry.kind == "floor") and info.cells then
                for _, cell in ipairs(info.cells) do planned[B.Place.key(cell.x, cell.y, cell.z)] = true end
            end
        elseif code == "NO_MATERIAL" and cost and extra and extra.need and not (extra.tools and extra.tools[1]) then
            -- Check.item 照同一份 work 算好的差額（原地替換已扣掉舊的退料）
            local set, any = {}, false
            for ft, n in pairs(extra.need) do
                if ft:sub(1, #Materials.USE) ~= Materials.USE then set[ft], any = n, true end
            end
            if any then sets[#sets + 1] = set end
            Materials.take(work, cost)
            short[#short + 1] = { c = c, code = code, extra = extra }
        else
            short[#short + 1] = { c = c, code = code, extra = extra, hard = true }
        end
    end
    return ok, sets[1] and sets or nil, short
end

-- 玩家腳下那一格上還沒蓋、只被玩家自己擋住的片：PlanCheck 判成 OCCUPIED 的，或這一輪挑批時才發現而跳過的。
-- 那一格還有別人、殭屍或動物就不算。回 那片, 它佔的格子（IsoGridSquare）；沒有回 nil
local function standingOn(player, plan)
    local here, PC = player:getCurrentSquare(), planCheck()
    if not here or here:getMovingObjects():size() ~= 1 then return nil end
    local hx, hy, hz = here:getX(), here:getY(), here:getZ()
    local found, own
    B.Plan.each(plan, function(p)
        if found or st.stepped[p] or st.placed[p] then return end
        local sk = st.skip[p]
        if sk then
            if sk.code ~= "OCCUPIED" then return end
        else
            local state, detail = PC.state(p)
            if state ~= "blocked" or detail ~= "OCCUPIED" then return end
        end
        local id, x, y, z, d = resolve(p)
        local entry = id and id:sub(1, #RECIPE) ~= RECIPE and Entry.resolve(id)
        local spr = entry and Entry.face(entry, d)
        if not spr then return end
        local list, hit = {}, false
        for _, o in ipairs(Entry.cells(spr)) do
            local cx, cy, cz = x + o[1], y + o[2], z + o[3]
            if cx == hx and cy == hy and cz == hz then hit = true end
            local sq = getCell():getGridSquare(cx, cy, cz)
            if sq then list[#list + 1] = sq end
        end
        if hit then found, own = p, list end
    end)
    return found, own
end

-- 照圖蓋自己把人帶到要放東西的那一格上（例如蓋屋頂時站在房裡，接著要在腳下放家具）：走到旁邊再蓋，不回報
-- 「這格有人」。一片只讓一次。回 true＝排了走路（走完由 Runner.tick 請 PlanCheck 重查那一片）
local function stepAside(player, plan)
    local p, own = standingOn(player, plan)
    if not p then return false end
    st.stepped[p] = true
    local to = AdjacentFreeTileFinder.Find(player:getCurrentSquare(), player, own)
    if not to then return false end
    st.skip[p], st.asideFor = nil, p
    ISTimedActionQueue.add(ISWalkToTimedAction:new(player, to))
    return true
end

-- 一批的虛影（同游標放開時 tryBuild 組的 parts）：各格 { x, y, z, sprite, yoff }
local function partsOf(id, list)
    local entry = Entry.resolve(id)
    local parts, scale = {}, Core.getTileScale()
    for i, r in ipairs(list) do
        local a = r.a
        local spr = entry and Entry.face(entry, a[4])
        local set = spr and a[5] and Entry.doorSet(spr)
        local offs = set and Entry.groupCells(set, a[5]) or (spr and Entry.cells(spr)) or {}
        local ps = {}
        for j, o in ipairs(offs) do
            local cell = r.info and r.info.cells and r.info.cells[j]
            local x, y = a[1] + o[1], a[2] + o[2]
            ps[j] = { x, y, a[3] + o[3], Entry.alternate(o[4], x, y), (cell and cell.yoff or 0) * scale }
        end
        parts[i] = ps
    end
    return parts
end

-- 一批結束（Queue 的 onDone，或配方的 runCells 的 onDone）。sum＝{ count, placed, refused, extra, stopped, noRoom }
local function batchDone(b, sum)
    if st.batch ~= b then return end -- 暫停或停止時已經清掉
    st.batch, st.lastDone = nil, getTimestampMs()
    if planChanged() then
        -- 送出後藍圖改了：這些座標上的片可能換了，結果不套到片上；那幾格請 PlanCheck 重查，整張照新的藍圖重新挑
        for _, c in ipairs(b.sent) do touch(c.x, c.y, c.z) end
        return halt("paused", "EDIT")
    end
    local placed = sum.placed or 0
    if placed > 0 then st.later = {} end
    for i, c in ipairs(b.sent) do
        if i > placed then break end
        st.placed[c.p] = true
        touch(c.x, c.y, c.z)
    end
    if sum.refused then
        local i = sum.extra and tonumber(sum.extra.i) or 0
        if WHOLE[sum.refused] or i <= 0 or not b.sent[i] then
            return halt("paused", "REFUSED", sum.refused, sum.extra)
        end
        skip(b.sent[i].p, sum.refused, sum.extra) -- 那一片不行（被擋、缺料、技能…），其他照挑
        touch(b.sent[i].x, b.sent[i].y, b.sent[i].z)
        st.state = "pick"
        return
    end
    if sum.noRoom and b.sent[sum.noRoom] then
        skip(b.sent[sum.noRoom].p, "NO_ROOM")
        st.state = "pick"
        return
    end
    if sum.why == "short" then -- 配方：材料、工具、技能不夠或太暗
        for i = placed + 1, #b.sent do skip(b.sent[i].p, "RECIPE_SHORT") end
        st.state = "pick"
        return
    end
    if sum.why == "missing" and b.sent[placed + 1] then
        skip(b.sent[placed + 1].p, "BLOCKED")
        st.state = "pick"
        return
    end
    if sum.stopped then
        -- 停下了：可能是玩家自己動手（手拖、拆除、配方拖一排會取消照圖蓋的，onDone 同步叫），也可能走不過去。
        -- 下一幀再看（那時玩家的請求已經排上）
        st.state, st.checkFor = "check", b.sent[placed + 1]
        return
    end
    st.state = "pick"
end

local function sendRecipe(player, b)
    local R = B.Recipes
    local cells = {}
    b.sent = b.list
    for i, c in ipairs(b.list) do cells[i] = { c.x, c.y, c.z, c.d } end
    st.batch, st.state = b, "build"
    local fine, ok, code = pcall(R.runCells, player, b.id, cells, function(sum) batchDone(b, sum or {}) end)
    if not fine then
        print(LOG .. "runner runCells failed: " .. tostring(ok))
        ok, code = nil, "INTERNAL"
    end
    if ok then return end
    if st.batch == b then st.batch, st.state = nil, "pick" end
    local why = code == "COVER" and "COVER" or code == "SHORT" and "RECIPE_SHORT" or code == "UNKNOWN" and "MISSING"
        or tostring(code)
    for _, c in ipairs(b.list) do skip(c.p, why) end
end

local function sendTiles(player, b)
    local ok, sets, short = evaluate(player, b)
    local heavy = false
    if sets and not b.fetched then
        local started
        started, heavy = startFetch(player, sets)
        if started then
            st.state = "fetch"
            return
        end
    end
    -- 剛拿過料的這一批：缺料的片先留著（下一次挑批再去拿；拿不到東西時那幾片會跳過，所以不會一直來回）。
    -- 背不動的不算跳過，先放著（st.later）
    for _, s in ipairs(short) do
        if s.hard or not (b.fetched or heavy) then
            skip(s.c.p, s.code, s.extra)
        elseif heavy then
            st.later[s.c.p] = true
        end
    end
    if #ok == 0 then return end
    local anchors, sent = {}, {}
    for i, r in ipairs(ok) do anchors[i], sent[i] = r.a, r.c end
    b.sent = sent
    st.batch, st.state = b, "build"
    local gid, code = Queue.push(player, b.id, anchors, partsOf(b.id, ok), b.overlap, {
        owner = "plan", onDone = function(sum) batchDone(b, sum) end })
    if gid then return end
    -- 當場送不出去（單機的請求當場被拒時 onDone 已經處理過）
    if st.batch == b then
        st.batch = nil
        if WHOLE[code] or code == nil then return halt("paused", "REFUSED", code or "INTERNAL") end
        for _, c in ipairs(sent) do skip(c.p, code) end
        st.state = "pick"
    end
end

local function pick(player, plan)
    local t = getTimestampMs()
    -- 等狀態時隔一下再挑；時鐘往回調時不等（家族 pitfalls）
    if st.nextPick and t < st.nextPick and st.nextPick - t <= RETRY_MS then return end
    st.nextPick = nil
    local b = pickBatch(player, plan)
    if b == "wait" then
        st.nextPick = t + RETRY_MS
        return
    end
    if b == "again" then return end
    if not b and st.lastDone and t >= st.lastDone and t - st.lastDone < SETTLE_END_MS then
        st.nextPick = t + RETRY_MS
        return
    end
    if not b and stepAside(player, plan) then
        st.state = "fetch" -- 等走完再挑（同拿料的等法；沒有在拿料，fetchDone 不做事）
        return
    end
    if not b then
        local s = buildSummary()
        summary, summaryAt = s, t
        if s.left == 0 then
            -- 全部蓋好，藍圖自己收起（藍圖檔留著）；存檔失敗時 PlanMode 不收，留在地上要玩家自己收
            local PM = B.PlanMode
            local fine, cleared = true, true
            if PM and PM.clear then fine, cleared = pcall(PM.clear) end
            if not fine then print(LOG .. "runner clear failed: " .. tostring(cleared)) end
            halt("done", "DONE", (not fine or cleared == false) and "KEEP" or nil)
        else
            halt("done", "LEFT")
        end
        return
    end
    b.fetched = st.fetchedFor == b.id .. "@" .. b.z
    st.fetchedFor = nil
    if b.id:sub(1, #RECIPE) == RECIPE then return sendRecipe(player, b) end
    sendTiles(player, b)
    if st.state == "fetch" then st.fetchedFor = b.id .. "@" .. b.z end
end

-- 玩家自己動手的請求排著：本 MOD 的建造（手拖、單放）、拆除、配方拖一排。照圖蓋自己的批次只在 build 狀態排著，
-- 所以沒在跑、pick、fetch 時 Queue 裡有東西就是玩家的（不經過這三者的入口改叫 Runner.manual）
local function handBusy(p)
    local C, R = B.Client, B.Recipes
    local unbuild = C and C.pendingUnbuild
    if Queue.busy(p) > 0 or (unbuild and unbuild.player == p) then return true end
    return (R and R.row and R.row(p:getPlayerNum())) ~= nil
end

-- ---------------------------------------------------------------- 開始

-- 照圖蓋；回 true，或 nil, 原因碼：OFF（沙盒關掉）、NO_PLAN（地上沒有定位好的藍圖）、NOTHING（沒有能蓋的）、
-- BUSY（正在蓋，或玩家自己動手的還沒跑完）
function Runner.start(player)
    if Entry.settings().AllowAutoBuild == false then return nil, "OFF" end
    if active() then return nil, "BUSY" end
    local PM, PC = B.PlanMode, planCheck()
    local plan = PM and PM.plan and PM.plan()
    if not plan or not (PM.origin and PM.origin()) or not (PC and PC.state and PC.resolve) then return nil, "NO_PLAN" end
    if not player or player:isDead() then return nil, "NO_PLAN" end
    if handBusy(player) then return nil, "BUSY" end
    if st.plan ~= plan then segCache = {} end
    st.player, st.plan, st.rev = player, plan, plan.rev
    st.ox, st.oy, st.oz = PM.origin()
    st.skip, st.placed, st.bad, st.badIndex, st.fetch, st.batch, st.checkFor = {}, {}, {}, nil, nil, nil, nil
    st.later = {}
    st.reason, st.detail, st.extra, st.nextPick, st.waitFrom, st.fetchedFor, st.moved = nil, nil, nil, nil, nil, nil, 0
    st.lastDone, st.idleAt, st.stepped, st.asideFor = nil, nil, {}, nil
    local boxes, any = #Runner.boxes() > 0, false
    B.Plan.each(plan, function(p)
        if any then return end
        local s = PC.state(p)
        if s == nil or s == "ok" or (s == "short" and boxes) then any = true end
    end)
    if not any and standingOn(player, plan) then any = true end -- 只剩腳下那一片：走開就能蓋
    if not any then
        summary, summaryAt = buildSummary(), getTimestampMs()
        return nil, "NOTHING"
    end
    st.state = "pick"
    summary = nil
    notify()
    return true
end

-- ---------------------------------------------------------------- 每幀

-- 暫停與停止的條件（計畫第 2 節的表）。回 true＝已經停了
local function watch(p)
    if p:isDead() then return Runner.stop("DEAD") or true end
    if p:getVehicle() then return Runner.stop("VEHICLE") or true end
    if p:isAsleep() then return Runner.stop("SLEEP") or true end
    if Entry.settings().AllowAutoBuild == false then return Runner.stop("OFF") or true end
    local PM = B.PlanMode
    if not (PM and PM.plan and PM.plan() == st.plan and PM.origin and PM.origin()) then
        return Runner.stop("PLAN_GONE") or true
    end
    -- 規劃中或藍圖改過：照圖蓋暫停（PlanMode 進規劃前也會叫 pause("EDIT")；這裡是防線）
    if (PM.state and PM.state() == "edit") or planChanged() then return Runner.pause("EDIT") or true end
    -- 有殭屍以這位玩家為目標（IsoZombie.java:3044 每幀累計、IsoPlayer.java:5711 存成上一幀的數，Stats.java:135）
    local stats = p:getStats()
    if stats and stats:getNumChasingZombies() > 0 then return Runner.pause("ZOMBIE") or true end
    if p:isAttackStarted() or p:isAiming() then return Runner.pause("ATTACK") or true end
    -- 玩家自己走：照圖蓋的走路都是佇列裡的動作；佇列空著還在走＝方向鍵或搖桿（玩家一動，原版就清掉佇列：
    -- IsoPlayer.java:2645-2667 的 StopAllActionQueueWalking）。動作剛結束的那一幀可能還帶著移動，連兩幀才算
    if p:isJustMoved() and not ISTimedActionQueue.isPlayerDoingAction(p) then
        st.moved = (st.moved or 0) + 1
        if st.moved >= 2 then return Runner.pause("MOVED") or true end
    else
        st.moved = 0
    end
    return false
end

-- 停下的那一批是誰停的：玩家的請求排上了＝玩家動手；佇列空著還在動＝玩家自己走開
-- （原版一動就清佇列，Queue 的這一批跟著停，比 watch 連兩幀的判斷早一幀）；都不是＝走不過去，跳過那一片
local function judgeStop(p)
    if handBusy(p) then return halt("paused", "MANUAL") end
    if p:isJustMoved() and not ISTimedActionQueue.isPlayerDoingAction(p) then return halt("paused", "MOVED") end
    if st.checkFor then skip(st.checkFor.p, "WALK") end
    st.checkFor, st.state = nil, "pick"
end

function Runner.tick()
    if not active() then return end
    local p = st.player
    if not p then return end
    if watch(p) then return end
    local s = st.state
    if s == "check" then return judgeStop(p) end
    if (s == "fetch" or s == "pick") and handBusy(p) then return halt("paused", "MANUAL") end
    if s == "fetch" then
        local t = getTimestampMs()
        if ISTimedActionQueue.isPlayerDoingAction(p) then
            st.idleAt = nil
            return
        end
        st.idleAt = st.idleAt or t
        if t < st.idleAt then st.idleAt = t end
        if t - st.idleAt < SETTLE_MS then return end
        st.idleAt = nil
        if st.asideFor then -- 讓位走完：那一片請 PlanCheck 重查，等它查完再挑（同一批蓋完後的等法）
            local _, x, y, z = resolve(st.asideFor)
            if x then touch(x, y, z) end
            st.asideFor, st.lastDone = nil, t
        end
        fetchDone(p)
        st.state = "pick"
        return
    end
    if s == "pick" then pick(p, st.plan) end
end

-- 遊戲暫停時引擎不送 OnTick（GameWindow.java:354-367 只送 OnTickEvenPaused），所以暫停在這裡看：
-- 正在蓋、或暫停中按了照圖蓋，都停成 GAME_PAUSED
function Runner.tickPaused()
    if active() and isGamePaused() then Runner.pause("GAME_PAUSED") end
end

-- Esc＝暫停（多人遊戲不會停下時間，原版也不清佇列）
function Runner.onKey(key)
    if not active() then return end
    if Keyboard and key == Keyboard.KEY_ESCAPE then Runner.pause("ESC") end
end

-- 除錯重新載入 Lua 時不重複掛（同 PlanMode）；掛的是轉呼叫，重新載入後跑新的函式
if not Runner.loaded then
    Runner.loaded = true
    Events.OnTick.Add(function() MinidoracatBuilder.Runner.tick() end)
    Events.OnKeyPressed.Add(function(key) MinidoracatBuilder.Runner.onKey(key) end)
    Events.OnTickEvenPaused.Add(function() MinidoracatBuilder.Runner.tickPaused() end)
end

return Runner
