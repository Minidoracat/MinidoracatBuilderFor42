-- 放置時按旋轉鍵（R、手把 LB／RB）輪流的狀態（使用者 2026-11-16 選 rot4=edge）。只佔一條格邊的種類（Entry.EDGE 的牆、
-- 柵欄、門框、窗框、門、窗）照四條邊轉：北邊、東邊＝右邊那格 (x+1, y) 的西邊、南邊＝下面那格 (x, y+1) 的北邊、西邊。
-- 游標把錨點移 dx, dy、朝向換成那條邊用的面，請求格式不變（拖一圈本來就這樣蓋，Cursor.shape 的 ring）。
-- 另一條邊沒有面（Entry.face 的配對面找不到，例如門、窗）時只有原邊與對邊兩個。其他種類（含柱子、佔兩條邊的牆角）
-- 照 Turn.faces 的朝向，dx＝dy＝0。
require "MinidoracatBuilder/Entry"

MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local Turn = B.Turn or {}
B.Turn = Turn
local Entry = B.Entry

-- 項目有的朝向：1..4（N、E、S、W）裡 Entry.face 有回值、sprite 不重複的；一個都沒有時只有 0（項目本身）。
-- 牆、柵欄、門框、窗框這類只佔一條格邊的，另一條邊是目錄裡的另一項（Entry.face 的 d＝5，配對面）：接在最後
-- （2026-11-14 群聊回報：牆只能照挑的那一張蓋，要回視窗找另一面）。伺服器本來就收 d＝5（拖一圈在用）
function Turn.faces(entry)
    local out, seen = { n = 0 }, {}
    for d = 1, 4 do
        local spr = Entry.face(entry, d)
        local name = spr and spr:getName()
        if name and not seen[name] then
            seen[name] = true
            out.n = out.n + 1
            out[out.n] = d
        end
    end
    if out.n == 0 then
        out.n, out[1] = 1, 0
        seen[entry.name] = true
    end
    local pair = Entry.face(entry, 5)
    if pair and not seen[pair:getName()] then
        out.n = out.n + 1
        out[out.n] = 5
    end
    return out
end

-- 北、西兩條邊各用哪一面（2026-11-01 定案）：cur 優先，再照 0..5 找只佔北邊／只佔西邊的。原版北牆、西牆
-- 多半是兩個各只有一面的項目（tiledef：walls_exterior_wooden_01 4,5 是西、6,7 是北），另一條邊用 d＝5 配對面。
-- 都沒有＝nil。回 { n = d, w = d }
function Turn.sides(entry, cur)
    local out = {}
    for _, d in ipairs({ cur, 0, 1, 2, 3, 4, 5 }) do
        local spr = Entry.face(entry, d)
        if spr then
            local n, w = Entry.edges(entry.kind, spr)
            if n and not w and out.n == nil then out.n = d end
            if w and not n and out.w == nil then out.w = d end
        end
    end
    return out
end

-- 只佔一條格邊（北或西其中一條）
local function oneEdge(entry)
    if not Entry.EDGE[entry.kind] then return false end
    local n, w = Entry.edges(entry.kind, entry.spr)
    return n ~= w
end

-- 格邊種類：朝向 d 那一面的另一條邊（北↔西）用哪個朝向；不是只佔一條邊、或另一條邊沒有面回 nil
function Turn.other(entry, d)
    if not Entry.EDGE[entry.kind] then return nil end
    local spr = Entry.face(entry, d)
    if not spr then return nil end
    local n, w = Entry.edges(entry.kind, spr)
    if n == w then return nil end
    local s = Turn.sides(entry, d)
    if n then return s.w end
    return s.n
end

-- 按旋轉鍵的順序：{ n, { d, dx, dy, edge＝"N"｜"E"｜"S"｜"W"（只佔一條邊的才有） }, ... }
function Turn.states(entry)
    local out = { n = 0 }
    local function add(d, dx, dy, edge)
        out.n = out.n + 1
        out[out.n] = { d = d, dx = dx, dy = dy, edge = edge }
    end
    if oneEdge(entry) then
        local s = Turn.sides(entry, 0)
        if s.n then add(s.n, 0, 0, "N") end
        if s.w then add(s.w, 1, 0, "E") end
        if s.n then add(s.n, 0, 1, "S") end
        if s.w then add(s.w, 0, 0, "W") end
        return out
    end
    local f = Turn.faces(entry)
    for i = 1, f.n do add(f[i], 0, 0, nil) end
    return out
end

return Turn
