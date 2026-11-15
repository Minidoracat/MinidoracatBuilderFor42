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
local st = { state = "idle", skip = {}, placed = {}, bad = {} }
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
    if st.state == "fetch" then ISTimedActionQueue.clear(p) end
    st.fetch = nil
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

-- "idle"｜"pick"｜"build"｜"fetch"｜"paused"｜"done"（內部的 check 對外算 build）
function Runner.state() return st.state == "check" and "build" or st.state end

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
    return container, obj
end

-- 能當材料的：同 Materials 的 usable（裝著東西的袋子、裝著液體的容器不算）
local function usable(item)
    if instanceof(item, "InventoryContainer") then return item:getInventory():getItems():isEmpty() end
    return not item:isFluidContainer() or item:isEmptyOfFluid()
end

-- 從一個箱子挑這一批缺的（need＝{ [fullType]＝數量 }），照負重上限挑到不超重為止。釘子不夠時拿釘子盒。回 物品陣列
local function choose(player, container, need)
    local inv = player:getInventory()
    local room = player:getMaxWeight() - inv:getCapacityWeight()
    local left, out = {}, {}
    for ft, n in pairs(need) do left[ft] = n end
    local items = container:getItems()
    local boxes = {}
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        local ft = it:getFullType()
        if (left[ft] or 0) > 0 and usable(it) then
            local w = it:getUnequippedWeight()
            if w <= room then
                out[#out + 1], room, left[ft] = it, room - w, left[ft] - 1
            end
        elseif ft == NAILS_BOX and usable(it) then
            boxes[#boxes + 1] = it
        end
    end
    for _, it in ipairs(boxes) do
        if (left[NAILS] or 0) <= 0 then break end
        local w = it:getUnequippedWeight()
        if w <= room then out[#out + 1], room, left[NAILS] = it, room - w, left[NAILS] - PER_BOX end
    end
    return out
end

local function boxKey(b) return b.x .. "," .. b.y .. "," .. b.z .. "," .. b.index end

-- 找一個有這一批缺的、能拿的點名箱子，走過去並排搬運動作。回 true＝開始拿了
local function startFetch(player, need)
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
    local inv = player:getInventory()
    for _, o in ipairs(order) do
        local container, why = openBox(player, o.b)
        local picks = container and choose(player, container, need) or {}
        if container and #picks > 0 then
            if not luautils.walkToContainer(container, player:getPlayerNum()) then
                why = "NO_ROOM"
            else
                local before = {}
                for _, it in ipairs(picks) do
                    local ft = it:getFullType()
                    before[ft] = inv:getCountTypeRecurse(ft)
                    ISTimedActionQueue.add(ISInventoryTransferAction:new(player, it, container, inv))
                end
                st.fetch = { box = o.b, i = o.i, before = before }
                return true
            end
        end
        if why then
            st.bad[boxKey(o.b)] = why
            st.badIndex = st.badIndex or {}
            st.badIndex[o.i] = why
        end
    end
    return false
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

-- 有變動的片：PlanCheck 重查那一格與上一層、四鄰（上層地板與屋頂靠它們撐，PlanCheck.touch）
local function touch(x, y, z)
    local PC = planCheck()
    if PC and PC.touch then PC.touch(x, y, z) end
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
        if st.skip[p] or st.placed[p] then return end
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
-- 回 可蓋的 { c, info }…、缺料合計（只算缺的物品；耗材與工具不拿）
local function evaluate(player, b)
    local S = Materials.summary(player)
    local work = {}
    for k, v in pairs(S) do work[k] = v end
    work.items = setmetatable({}, { __index = S.items })
    work.uses = setmetatable({}, { __index = S.uses })
    local ok, need, short, planned = {}, {}, {}, {}
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
        elseif code == "NO_MATERIAL" and cost and not (extra and extra.tools and extra.tools[1]) then
            local miss = Materials.short(work, cost)
            for ft, n in pairs(miss or {}) do
                if ft:sub(1, #Materials.USE) ~= Materials.USE then need[ft] = (need[ft] or 0) + n end
            end
            Materials.take(work, cost)
            short[#short + 1] = { c = c, code = code, extra = extra }
        else
            short[#short + 1] = { c = c, code = code, extra = extra, hard = true }
        end
    end
    local any = false
    for _ in pairs(need) do any = true break end -- Kahlua 沒有全域 next
    return ok, any and need or nil, short
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
    local placed = sum.placed or 0
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
    if not (R and R.runCells) then
        for _, c in ipairs(b.list) do skip(c.p, "RECIPE") end
        return
    end
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
    local ok, need, short = evaluate(player, b)
    if need and not b.fetched and startFetch(player, need) then
        st.state = "fetch"
        return
    end
    -- 剛拿過料的這一批：缺料的片先留著（下一次挑批再去拿；拿不到東西的箱子會被跳過，所以不會一直來回）
    for _, s in ipairs(short) do
        if s.hard or not b.fetched then skip(s.c.p, s.code, s.extra) end
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
    if not b then
        local s = buildSummary()
        summary, summaryAt = s, t
        if s.left == 0 then
            halt("done", "DONE")
            local PM = B.PlanMode
            if PM and PM.clear then pcall(PM.clear) end -- 全部蓋好，藍圖自己收起（藍圖檔留著）
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

-- ---------------------------------------------------------------- 開始

-- 照圖蓋；回 true，或 nil, 原因碼：OFF（沙盒關掉）、NO_PLAN（地上沒有定位好的藍圖）、NOTHING（沒有能蓋的）、BUSY（正在蓋）
function Runner.start(player)
    if Entry.settings().AllowAutoBuild == false then return nil, "OFF" end
    if active() then return nil, "BUSY" end
    local PM, PC = B.PlanMode, planCheck()
    local plan = PM and PM.plan and PM.plan()
    if not plan or not (PM.origin and PM.origin()) or not (PC and PC.state and PC.resolve) then return nil, "NO_PLAN" end
    if not player or player:isDead() then return nil, "NO_PLAN" end
    if st.plan ~= plan then segCache = {} end
    st.player, st.plan = player, plan
    st.skip, st.placed, st.bad, st.badIndex, st.fetch, st.batch, st.checkFor = {}, {}, {}, nil, nil, nil, nil
    st.reason, st.detail, st.extra, st.nextPick, st.waitFrom, st.fetchedFor, st.moved = nil, nil, nil, nil, nil, nil, 0
    st.lastDone, st.idleAt = nil, nil
    local boxes, any = #Runner.boxes() > 0, false
    B.Plan.each(plan, function(p)
        if any then return end
        local s = PC.state(p)
        if s == nil or s == "ok" or (s == "short" and boxes) then any = true end
    end)
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
    -- 單機的遊戲速度 0＝暫停（原版右鍵選單同一個判斷，ISMenuContextWorld.lua:37）
    local speed = UIManager and UIManager.getSpeedControls and UIManager.getSpeedControls()
    if speed and speed:getCurrentGameSpeed() == 0 then return Runner.pause("GAME_PAUSED") or true end
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

-- 停下的那一批是誰停的：玩家的請求排上了（手拖、拆除、配方拖一排）＝玩家動手；佇列空著還在動＝玩家自己走開
-- （原版一動就清佇列，Queue 的這一批跟著停，比 watch 連兩幀的判斷早一幀）；都不是＝走不過去，跳過那一片
local function judgeStop(p)
    local C, R = B.Client, B.Recipes
    local pn = p:getPlayerNum()
    local unbuild = C and C.pendingUnbuild
    if Queue.busy(p) > 0 or (unbuild and unbuild.player == p) or (R and R.row and R.row(pn)) then
        return halt("paused", "MANUAL")
    end
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
        fetchDone(p)
        st.state = "pick"
        return
    end
    if s == "pick" then pick(p, st.plan) end
end
Events.OnTick.Add(Runner.tick)

-- Esc＝暫停（多人遊戲不會停下時間，原版也不清佇列）
Events.OnKeyPressed.Add(function(key)
    if not active() then return end
    if Keyboard and key == Keyboard.KEY_ESCAPE then Runner.pause("ESC") end
end)

return Runner
