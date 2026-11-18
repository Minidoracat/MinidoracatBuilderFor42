-- 藍圖的資料模型：一張藍圖＝一些「片」（相對原點的格子、朝向、疊放、項目編號）。只在客戶端、只是 Lua 表，
-- 不呼叫任何引擎函式（smoke harness 直接測）。存檔、分享碼在 PlanFile.lua，地上那張的位置在 PlanStore.lua。
-- 上限（使用者 2026-11-16 定案）：4,096 片、每邊 64 格、4 層、名稱 40 字；為了虛影的效能，不是為了空間。
-- 撤銷／重做最多 50 步，每步只記這一步動到的片（加、拿掉、改了哪些欄位），不存整張的副本。
-- Kahlua 少傳的參數不保證是 nil（pz-family-docs pitfalls.md「少傳的參數」）：選填的參數用 ... 收，呼叫者省略也安全。
MinidoracatBuilder = MinidoracatBuilder or {}
local Plan = MinidoracatBuilder.Plan or {}
MinidoracatBuilder.Plan = Plan

Plan.MAX_PIECES, Plan.MAX_SIDE, Plan.MAX_LEVELS, Plan.MAX_NAME = 4096, 64, 4, 40
Plan.MAX_UNDO = 50

-- 格子的數字鍵：x、y 在 ±2^20、z 在 ±256 以內時不撞（最大約 2^51，double 表示得精確）
local OFF, SPAN = 1048576, 2097152
local function cellKey(x, y, z)
    return (x + OFF) + (y + OFF) * SPAN + (z + 256) * SPAN * SPAN
end
local function inRange(x, y, z)
    return x > -OFF and x < OFF and y > -OFF and y < OFF and z > -256 and z < 256
end

local EMPTY = {} -- Plan.at 沒有片時回這張（唯讀，呼叫者不要改）

local function opt(...)
    if select("#", ...) > 0 then return (...) end
    return nil
end

-- 名稱的字數：Kahlua 的字串是 UTF-16（string.byte 回字碼），標準 Lua 是 UTF-8 位元組；
-- 不算 128–191 兩邊都對（UTF-8 的後續位元組）。shortcut: Kahlua 裡 U+0080–U+00BF（©、° 這類）不算字，名稱可能多幾個這種字。
function Plan.nameLen(s)
    local n = 0
    for i = 1, #s do
        local b = s:byte(i)
        if b < 128 or b > 191 then n = n + 1 end
    end
    return n
end

-- Kahlua 的字串是 UTF-16：截到 n 個字，結尾不留半個代理對（落單的一半存檔會變成 ?、分享碼解不回來）。
-- 標準 Lua 的位元組到不了這個範圍。
function Plan.cut(s, n)
    s = s:sub(1, n)
    local len = #s
    if len > 0 then
        local b = s:byte(len)
        if b >= 55296 and b <= 56319 then s = s:sub(1, len - 1) end -- D800..DBFF
    end
    return s
end

-- 顯示名稱：控制字元（含 Tab、換行，檔案用它們分欄）換成空白、去頭尾空白、超過 40 字截掉（截完結尾的空白也去掉，
-- 再套一次才會一樣）
function Plan.cleanName(s)
    s = tostring(s or ""):gsub("%c", " "):match("^%s*(.-)%s*$")
    local n, keep = 0, #s
    for i = 1, #s do
        local b = s:byte(i)
        if b < 128 or b > 191 then
            n = n + 1
            if n > Plan.MAX_NAME then
                keep = i - 1
                break
            end
        end
    end
    return (Plan.cut(s, keep):gsub("%s+$", "")) -- cut：文字框自己截在代理對中間時也去掉那一半
end

function Plan.new(name)
    return {
        name = Plan.cleanName(name), items = {}, nItems = 0, pieces = {}, n = 0, rev = 0,
        _top = 0, _byId = {}, _cells = {}, _kinds = {}, _xs = {}, _ys = {}, _zs = {}, _dirty = false,
        _undo = {}, _redo = {}, _depth = 0, _step = nil,
    }
end

-- 取得（或新增）項目編號。src＝{ mod, modName, workshop, version }（PlanFile.source 回的），可省略
function Plan.item(plan, id, ...)
    local it = plan._byId[id]
    if it then return it end
    local src = opt(...) or EMPTY
    it = plan.nItems + 1
    plan.nItems = it
    plan.items[it] = { id = id, mod = src.mod, modName = src.modName, workshop = src.workshop,
        version = src.version, n = 0 }
    plan._byId[id] = it
    return it
end

-- ===== 內部：放上、拿下一片（維護格子索引、座標計數、項目片數；不記撤銷） =====

local function inc(t, v) t[v] = (t[v] or 0) + 1 end
local function dec(t, v)
    local c = t[v] - 1
    t[v] = c > 0 and c or nil
end

-- 同一格裡「項目、朝向、疊放」各有幾片（plan._kinds[格子鍵][kind]）：same() 先查這張，沒有就不必逐片掃。
-- 別人給的碼或檔可以把 4,096 個不同項目疊在同一格，逐片掃是 840 萬次比對（實機解碼 1.2 秒）
local function kind(it, d, o)
    return (it * 16 + d) * 2 + o
end

local function place(plan, p)
    local i = plan._top + 1
    plan._top = i
    plan.pieces[i] = p
    p._i = i
    local k = cellKey(p.x, p.y, p.z)
    local list = plan._cells[k]
    if not list then
        list = {}
        plan._cells[k] = list
    end
    list[#list + 1] = p
    local kinds = plan._kinds[k]
    if not kinds then
        kinds = {}
        plan._kinds[k] = kinds
    end
    inc(kinds, kind(p.it, p.d, p.o))
    inc(plan._xs, p.x); inc(plan._ys, p.y); inc(plan._zs, p.z)
    plan.items[p.it].n = plan.items[p.it].n + 1
    plan.n = plan.n + 1
    -- 包圍盒：放上只會變大，直接更新；拿下時標髒，Plan.bounds 再從計數表重算
    if plan.n == 1 then
        plan._x0, plan._x1, plan._y0, plan._y1, plan._z0, plan._z1 = p.x, p.x, p.y, p.y, p.z, p.z
        plan._dirty = false
    elseif not plan._dirty then
        if p.x < plan._x0 then plan._x0 = p.x elseif p.x > plan._x1 then plan._x1 = p.x end
        if p.y < plan._y0 then plan._y0 = p.y elseif p.y > plan._y1 then plan._y1 = p.y end
        if p.z < plan._z0 then plan._z0 = p.z elseif p.z > plan._z1 then plan._z1 = p.z end
    end
end

local function unplace(plan, p)
    plan.pieces[p._i] = nil
    p._i = nil
    local k = cellKey(p.x, p.y, p.z)
    local list = plan._cells[k]
    for j = 1, #list do
        if list[j] == p then
            table.remove(list, j)
            break
        end
    end
    dec(plan._kinds[k], kind(p.it, p.d, p.o))
    if #list == 0 then plan._cells[k], plan._kinds[k] = nil, nil end
    dec(plan._xs, p.x); dec(plan._ys, p.y); dec(plan._zs, p.z)
    plan.items[p.it].n = plan.items[p.it].n - 1
    plan.n = plan.n - 1
    plan._dirty = true
end

local function live(plan, p)
    return p._i ~= nil and plan.pieces[p._i] == p
end

-- 同一格、同一項目、同一朝向、同樣疊放的另一片（except 那片不算）
local function same(plan, x, y, z, d, o, it, except)
    local k = cellKey(x, y, z)
    local list = plan._cells[k]
    if not list or not plan._kinds[k][kind(it, d, o)] then return nil end
    for j = 1, #list do
        local q = list[j]
        if q ~= except and q.it == it and q.d == d and q.o == o then return q end
    end
    return nil
end

local function span(t)
    local lo, hi
    for v in pairs(t) do
        if not lo or v < lo then lo = v end
        if not hi or v > hi then hi = v end
    end
    return lo, hi
end

-- minX, minY, minZ, maxX, maxY, maxZ（相對原點）；沒有片回 nil
function Plan.bounds(plan)
    if plan.n == 0 then return nil end
    if plan._dirty then
        plan._x0, plan._x1 = span(plan._xs)
        plan._y0, plan._y1 = span(plan._ys)
        plan._z0, plan._z1 = span(plan._zs)
        plan._dirty = false
    end
    return plan._x0, plan._y0, plan._z0, plan._x1, plan._y1, plan._z1
end

local function fits(plan)
    if plan.n > Plan.MAX_PIECES then return false, "FULL" end
    if plan.n == 0 then return true end
    local x0, y0, z0, x1, y1, z1 = Plan.bounds(plan)
    if x1 - x0 >= Plan.MAX_SIDE or y1 - y0 >= Plan.MAX_SIDE then return false, "TOO_WIDE" end
    if z1 - z0 >= Plan.MAX_LEVELS then return false, "TOO_HIGH" end
    return true
end

-- ===== 撤銷紀錄：一步＝一串 { p, k }，k＝1 加、-1 拿掉、0 改欄位（帶改前 a 與改後 b） =====

local function open(plan)
    plan._depth = plan._depth + 1
    if not plan._step then plan._step = {} end
end

-- 拿掉多出來的空格（片拿掉後陣列留洞）：洞比片多時重排；只在一步結束時做，走訪中不會變
local function compact(plan)
    if plan._top <= 2 * plan.n + 256 then return end
    local out, n = {}, 0
    for i = 1, plan._top do
        local p = plan.pieces[i]
        if p then
            n = n + 1
            out[n] = p
            p._i = n
        end
    end
    plan.pieces, plan._top = out, n
end

local function close(plan)
    if plan._depth == 0 then return end
    plan._depth = plan._depth - 1
    if plan._depth > 0 then return end
    local step = plan._step
    plan._step = nil
    compact(plan)
    if #step == 0 then return end
    local undo = plan._undo
    undo[#undo + 1] = step
    if #undo > Plan.MAX_UNDO then table.remove(undo, 1) end
    plan._redo = {}
end

local function record(plan, r)
    local step = plan._step
    step[#step + 1] = r
end

local function addPiece(plan, p)
    place(plan, p)
    record(plan, { p = p, k = 1 })
end

local function dropPiece(plan, p)
    unplace(plan, p)
    record(plan, { p = p, k = -1 })
end

local function setFields(plan, p, f)
    unplace(plan, p)
    p.x, p.y, p.z, p.d, p.it = f[1], f[2], f[3], f[4], f[5]
    place(plan, p)
end

local function modify(plan, p, x, y, z, d, it)
    local a = { p.x, p.y, p.z, p.d, p.it }
    local b = { x, y, z, d, it }
    setFields(plan, p, b)
    record(plan, { p = p, k = 0, a = a, b = b })
end

-- 退回這一步裡 from 之後的紀錄（整個不做的操作用）
local function rollback(plan, from)
    local step = plan._step
    for i = #step, from, -1 do
        local r = step[i]
        if r.k == 1 then unplace(plan, r.p)
        elseif r.k == -1 then place(plan, r.p)
        else setFields(plan, r.p, r.a) end
        step[i] = nil
    end
end

-- 這幾片裡還在藍圖上的（去掉重複）
local function alive(plan, pieces)
    local out, seen = {}, {}
    for _, p in ipairs(pieces) do
        if not seen[p] and live(plan, p) then
            seen[p] = true
            out[#out + 1] = p
        end
    end
    return out
end

-- 搬或轉之後和別片完全一樣的：拿掉搬過來的這片
local function dedupe(plan, list)
    for _, p in ipairs(list) do
        if live(plan, p) and same(plan, p.x, p.y, p.z, p.d, p.o, p.it, p) then dropPiece(plan, p) end
    end
end

local function changed(plan, from)
    if #plan._step >= from then plan.rev = plan.rev + 1 end
end

-- ===== 對外的操作 =====

function Plan.begin(plan)
    open(plan)
end

function Plan.commit(plan)
    close(plan)
end

-- 讀檔、匯入後呼叫：清掉撤銷紀錄（建出來的那些片不算一步）
function Plan.forget(plan)
    plan._undo, plan._redo = {}, {}
    if plan._step then plan._step = {} end
end

-- 車庫門的寬度：整數 2..64；其他片沒有（nil）
function Plan.widthOk(w)
    return w == nil or (type(w) == "number" and w == math.floor(w) and w >= 2 and w <= Plan.MAX_SIDE)
end

-- w＝車庫門的寬度（選填，可省略）。重複的判斷不看 w；片的格子只算錨點那一格
function Plan.add(plan, x, y, z, d, o, it, ...)
    local w = opt(...)
    if not plan.items[it] then return nil, "ITEM" end
    if not Plan.widthOk(w) then return nil, "RANGE" end
    if plan.n >= Plan.MAX_PIECES then return nil, "FULL" end
    if not inRange(x, y, 0) then return nil, "TOO_WIDE" end
    if not inRange(0, 0, z) then return nil, "TOO_HIGH" end
    if same(plan, x, y, z, d, o, it, nil) then return nil, "DUP" end
    if plan.n > 0 then
        local x0, y0, z0, x1, y1, z1 = Plan.bounds(plan)
        if math.max(x1, x) - math.min(x0, x) >= Plan.MAX_SIDE or math.max(y1, y) - math.min(y0, y) >= Plan.MAX_SIDE then
            return nil, "TOO_WIDE"
        end
        if math.max(z1, z) - math.min(z0, z) >= Plan.MAX_LEVELS then return nil, "TOO_HIGH" end
    end
    local p = { x = x, y = y, z = z, d = d, o = o, it = it, w = w }
    open(plan)
    addPiece(plan, p)
    close(plan)
    plan.rev = plan.rev + 1
    return p
end

-- 回拿掉幾片
function Plan.remove(plan, pieces)
    local list = alive(plan, pieces)
    if #list == 0 then return 0 end
    open(plan)
    for _, p in ipairs(list) do dropPiece(plan, p) end
    close(plan)
    plan.rev = plan.rev + 1
    return #list
end

-- 這幾片一次放到各自的最終位置 to[i]＝{ x, y, z, d }（照 pieces 的順序）。copy＝原片不動、在那裡加一份新的
-- （那裡已經有一模一樣的就略過）；不然搬過去，全部到位後和別片一樣的才拿掉：中間位置不去重，
-- 先搬再轉時中間位置剛好疊到沒選的同款片，那片也不會被吃掉。
-- 回 true（copy 回新片的陣列）；超出每邊 64、4 層（或格子鍵的範圍）回 nil, 原因（整個不做）
local function relocate(plan, pieces, to, copy)
    local list, dest, seen, n = {}, {}, {}, 0
    for i, p in ipairs(pieces) do
        if not seen[p] and live(plan, p) then
            seen[p] = true
            local t = to[i]
            if not inRange(t[1], t[2], 0) then return nil, "TOO_WIDE" end
            if not inRange(0, 0, t[3]) then return nil, "TOO_HIGH" end
            n = n + 1
            list[n], dest[n] = p, t
        end
    end
    open(plan)
    local from = #plan._step + 1
    local out = {}
    for i, p in ipairs(list) do
        local t = dest[i]
        if not copy then
            modify(plan, p, t[1], t[2], t[3], t[4], p.it)
        elseif not same(plan, t[1], t[2], t[3], t[4], p.o, p.it, nil) then
            local q = { x = t[1], y = t[2], z = t[3], d = t[4], o = p.o, it = p.it, w = p.w }
            addPiece(plan, q)
            out[#out + 1] = q
        end
    end
    local ok, why = fits(plan)
    if not ok then
        rollback(plan, from)
        close(plan)
        return nil, why
    end
    if not copy then dedupe(plan, list) end
    changed(plan, from)
    close(plan)
    if copy then return out end
    return true
end

local function shiftedTo(pieces, dx, dy, dz)
    local to = {}
    for i, p in ipairs(pieces) do to[i] = { p.x + dx, p.y + dy, p.z + dz, p.d } end
    return to
end

-- 回 true；超出上限回 nil, 原因
function Plan.move(plan, pieces, dx, dy, dz)
    if dx == 0 and dy == 0 and dz == 0 then return true end
    return relocate(plan, pieces, shiftedTo(pieces, dx, dy, dz), false)
end

-- 搬到各自的最終位置（搬加轉一次做完，見 relocate）。回 true；超出上限回 nil, 原因
function Plan.moveTo(plan, pieces, to)
    return relocate(plan, pieces, to, false)
end

-- 這幾片繞自己的包圍盒順時針轉 90 度（北→東→南→西：(x, y) → (minX + maxY − y, minY + x − minX)）後在哪，不改藍圖；
-- list 可以是藍圖外的片（搬、複製的預覽）。turnPiece(piece, item) 回 新 d, 位移修正 dx, dy（格邊的片換邊時用）；
-- 回 nil＝朝向不換，位置照樣跟著轉。回 { { x, y, z, d }… }（照 list 的順序）, 朝向沒換的片數
function Plan.turned(plan, list, turnPiece)
    if #list == 0 then return {}, 0 end
    local x0, y0, x1, y1 = list[1].x, list[1].y, list[1].x, list[1].y
    for _, p in ipairs(list) do
        x0, x1 = math.min(x0, p.x), math.max(x1, p.x)
        y0, y1 = math.min(y0, p.y), math.max(y1, p.y)
    end
    local to, stuck = {}, 0
    for i, p in ipairs(list) do
        local d, ddx, ddy = turnPiece(p, plan.items[p.it])
        if d == nil then
            stuck = stuck + 1
            d, ddx, ddy = p.d, 0, 0
        end
        to[i] = { x0 + (y1 - p.y) + (ddx or 0), y0 + (p.x - x0) + (ddy or 0), p.z, d }
    end
    return to, stuck
end

-- 轉 90 度（Plan.turned）。回朝向沒換的片數；超出上限回 nil, 原因（整個不做）
function Plan.rotate(plan, pieces, turnPiece)
    local list = alive(plan, pieces)
    if #list == 0 then return 0 end
    local to, stuck = Plan.turned(plan, list, turnPiece)
    local ok, why = relocate(plan, list, to, false)
    if not ok then return nil, why end
    return stuck
end

-- 複製一份到位移處；目的地已經有一模一樣的片就略過。回新片的陣列；超出上限回 nil, 原因（整個不做）
function Plan.copy(plan, pieces, dx, dy, dz)
    return relocate(plan, pieces, shiftedTo(pieces, dx, dy, dz), true)
end

-- 複製到各自的最終位置（複製加轉一次做完）。回新片的陣列；超出上限回 nil, 原因
function Plan.copyTo(plan, pieces, to)
    return relocate(plan, pieces, to, true)
end

-- 「全部換成…」：項目編號 it 的片改指到項目 id（src 同 Plan.item，可省略）。換完和別片重複的拿掉。回換了幾片
function Plan.replace(plan, it, id, ...)
    local to = Plan.item(plan, id, opt(...))
    if to == it then return 0 end
    local list = {}
    Plan.each(plan, function(p) if p.it == it then list[#list + 1] = p end end)
    if #list == 0 then return 0 end
    open(plan)
    for _, p in ipairs(list) do
        if same(plan, p.x, p.y, p.z, p.d, p.o, to, p) then dropPiece(plan, p)
        else modify(plan, p, p.x, p.y, p.z, p.d, to) end
    end
    close(plan)
    plan.rev = plan.rev + 1
    return #list
end

function Plan.each(plan, fn)
    local pieces = plan.pieces
    for i = 1, plan._top do
        local p = pieces[i]
        if p then fn(p) end
    end
end

-- 這一格的片（陣列，唯讀；沒有片回同一張空表）
function Plan.at(plan, x, y, z)
    return plan._cells[cellKey(x, y, z)] or EMPTY
end

local function apply(plan, step, forward)
    local first, last, dir = 1, #step, 1
    if not forward then first, last, dir = #step, 1, -1 end
    for i = first, last, dir do
        local r = step[i]
        local k = forward and r.k or -r.k
        if k == 1 then place(plan, r.p)
        elseif k == -1 then unplace(plan, r.p)
        else setFields(plan, r.p, forward and r.b or r.a) end
    end
    plan.rev = plan.rev + 1
end

-- 拖到一半（begin 還沒 commit）時不准撤銷，回 false
function Plan.undo(plan)
    local undo = plan._undo
    if plan._depth > 0 or #undo == 0 then return false end
    local step = table.remove(undo)
    apply(plan, step, false)
    plan._redo[#plan._redo + 1] = step
    compact(plan)
    return true
end

function Plan.redo(plan)
    local redo = plan._redo
    if plan._depth > 0 or #redo == 0 then return false end
    local step = table.remove(redo)
    apply(plan, step, true)
    plan._undo[#plan._undo + 1] = step
    compact(plan)
    return true
end

return Plan
