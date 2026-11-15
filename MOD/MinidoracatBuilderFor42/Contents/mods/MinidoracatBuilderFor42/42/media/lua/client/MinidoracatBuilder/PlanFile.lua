-- 藍圖檔與分享碼。前半是純文字轉換（encode／decode／share／unshare，不碰引擎）；後半是存在
-- Zomboid/Lua/MinidoracatBuilder/plans/ 的檔案（列資料夾、讀、存、刪、改名、複製）與圖塊的來源 MOD。
--
-- 檔案格式（欄位用 Tab 分隔，圖塊名可能帶空白；i 行全在 p 行前面；沒有 END＝不完整，不用；END 之後不讀）：
--   MBLDPLAN 1 / name 顯示名稱 / size 寬 深 層數 / count 片數 / pos x y z（選填）/
--   i 編號 片數 MOD-ID 工作坊編號 MOD版本 MOD名稱 項目ID（沒有的寫 -）/ p x y z 朝向 疊放 項目編號 [寬度] / END
-- 寬度只有車庫門有（2..64，一扇門＝一片），其他片不寫這一欄；沒有這一欄的舊檔照讀。
-- 片的座標相對包圍盒的角（0 起算），pos 是那個角在世界上的位置。
-- 別人給的檔與分享碼一律當不可信：逐行檢查型別、範圍、項目編號、片數；任何一行不對整張拒收，回原因碼與行號，
-- 不丟 Lua 錯誤（Kahlua 被 pcall 接住的錯誤照樣進引擎的錯誤清單，pz-family-docs pitfalls.md）。
-- 原因碼：FORMAT 格式不對、VERSION 版本不認得、NO_END 不完整、NAME 名稱、RANGE 座標或數值超出、COUNT 片數不符、
-- ITEM 項目編號、FULL 超過 4,096 片、DUP 重複的片、TOO_BIG 內容太大、CHECKSUM 分享碼被改過、DELETED 已刪除的檔。
require "MinidoracatBuilder/Plan"
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Sources"

MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local PlanFile = B.PlanFile or {}
B.PlanFile = PlanFile
local Plan = B.Plan

PlanFile.DIR = "MinidoracatBuilder/plans"
local MAGIC = "MBLDPLAN"
local TOMB = MAGIC .. "\tdeleted" -- 刪除＝整檔改寫成這一行加 END（Lua 沒有刪檔函式，見 PlanFile.remove）
-- 讀檔與分享碼共用的上限（bounded）。存檔時先確認寫出來的內容在上限內（readable），存得進去就讀得回來。
-- 每行：i 行最長 2+4+4+20+4×128+7 個 Tab＝549 字 < MAX_LINE；總字數：4,096 個 i 行＋4,096 個 p 行（約 25 字）約 2.35 M。
local MAX_LINES = 8400 -- 檔頭 5 行＋項目、片各 4,096 行＋END；地上藍圖的紀錄（PlanStore，最多約 8,300 行）共用
local MAX_TEXT = 2400000
local MAX_LINE = 600
local MAX_FIELD = 128 -- 同 Entry 的圖塊名上限
local MAX_SHARE = 400000

local function opt(...)
    if select("#", ...) > 0 then return (...) end
    return nil
end

local function split(s, sep)
    local out, n, pos = {}, 0, 1
    while true do
        local e = s:find(sep, pos, true)
        n = n + 1
        out[n] = s:sub(pos, (e or (#s + 1)) - 1)
        if not e then return out, n end
        pos = e + 1
    end
end

-- 整數欄：不是整數回 nil, "FORMAT"；超出 lo..hi 回 nil, "RANGE"。[0-9] 不用 %d：Kahlua 的 %d 也收別種文字的數字
local function num(s, lo, hi)
    if type(s) ~= "string" or #s > 9 or not s:match("^%-?[0-9]+$") then return nil, "FORMAT" end
    local v = tonumber(s)
    if v < lo or v > hi then return nil, "RANGE" end
    return v
end

local function clean(s)
    return (tostring(s):gsub("%c", " "))
end

-- 寫進檔案的選填欄：沒有寫 -；控制字元換空白、太長截掉
local function dash(v)
    if v == nil or v == "" then return "-" end
    return clean(v):sub(1, MAX_FIELD)
end

local function undash(s)
    if s == "-" or s == "" then return nil end
    return s
end

local function workshopOk(s)
    return s == "-" or (#s <= 20 and s:match("^[0-9]+$") ~= nil)
end

-- 包圍盒的角與大小；沒有片時都是 0
local function frame(plan)
    local x0, y0, z0, x1, y1, z1 = Plan.bounds(plan)
    if not x0 then return 0, 0, 0, 0, 0, 0 end
    return x0, y0, z0, x1 - x0 + 1, y1 - y0 + 1, z1 - z0 + 1
end

-- 有片的項目重新編號（片數 0 的不寫）：回 舊編號 → 新編號, 新編號 → 項目
local function renumber(plan)
    local map, list = {}, {}
    for it = 1, plan.nItems do
        local item = plan.items[it]
        if item.n > 0 then
            list[#list + 1] = item
            map[it] = #list
        end
    end
    return map, list
end

function PlanFile.encode(plan)
    local out = {}
    local function put(s) out[#out + 1] = s end
    local x0, y0, z0, w, h, lv = frame(plan)
    put(MAGIC .. "\t1")
    put("name\t" .. Plan.cleanName(plan.name))
    put("size\t" .. w .. "\t" .. h .. "\t" .. lv)
    put("count\t" .. plan.n)
    if plan.ox and plan.n > 0 then
        put("pos\t" .. (plan.ox + x0) .. "\t" .. (plan.oy + y0) .. "\t" .. (plan.oz + z0))
    end
    local map, list = renumber(plan)
    for k, item in ipairs(list) do
        local ws = item.workshop and tostring(item.workshop) or "-"
        if not workshopOk(ws) then ws = "-" end
        put("i\t" .. k .. "\t" .. item.n .. "\t" .. dash(item.mod) .. "\t" .. ws .. "\t" .. dash(item.version)
            .. "\t" .. dash(item.modName) .. "\t" .. clean(item.id))
    end
    Plan.each(plan, function(p)
        put("p\t" .. (p.x - x0) .. "\t" .. (p.y - y0) .. "\t" .. (p.z - z0) .. "\t" .. p.d .. "\t" .. p.o .. "\t" .. map[p.it]
            .. (p.w and ("\t" .. p.w) or ""))
    end)
    put("END")
    return table.concat(out, "\n") .. "\n"
end

-- 逐行讀進來檢查。nextLine() 回下一行（沒有了回 nil；超過 bounded 的上限回 false）。
-- headOnly：讀到第一個 p 行（或 END）就停，回檔頭。讀到 END 就停，後面不讀
local function parse(nextLine, headOnly)
    local ln, line, f, n, over = 0, nil, nil, 0, false
    local function row()
        ln = ln + 1
        line = nextLine()
        if line == false then over, line = true, nil end
        if line == nil then
            f, n = nil, 0
        else
            f, n = split(line, "\t")
        end
        return line ~= nil
    end
    local function stop()
        return nil, over and "TOO_BIG" or "NO_END", ln
    end
    local why
    if not row() then return stop() end
    if f[1] ~= MAGIC or n ~= 2 then return nil, "FORMAT", ln end
    if line == TOMB then return nil, "DELETED", ln end
    if f[2] ~= "1" then return nil, "VERSION", ln end

    if not row() then return stop() end
    if f[1] ~= "name" or n ~= 2 then return nil, "FORMAT", ln end
    local name = f[2]
    if name ~= Plan.cleanName(name) then return nil, "NAME", ln end

    if not row() then return stop() end
    if f[1] ~= "size" or n ~= 4 then return nil, "FORMAT", ln end
    local w, h, lv
    w, why = num(f[2], 0, Plan.MAX_SIDE)
    if not w then return nil, why, ln end
    h, why = num(f[3], 0, Plan.MAX_SIDE)
    if not h then return nil, why, ln end
    lv, why = num(f[4], 0, Plan.MAX_LEVELS)
    if not lv then return nil, why, ln end
    local sizeLine = ln

    if not row() then return stop() end
    if f[1] ~= "count" or n ~= 2 then return nil, "FORMAT", ln end
    local count
    count, why = num(f[2], 0, 999999999)
    if not count then return nil, why, ln end
    if count > Plan.MAX_PIECES then return nil, "FULL", ln end
    if count > 0 and (w < 1 or h < 1 or lv < 1) then return nil, "RANGE", sizeLine end

    if not row() then return stop() end
    local pos
    if f[1] == "pos" then
        if n ~= 4 then return nil, "FORMAT", ln end
        local x, y, z
        x, why = num(f[2], -10000000, 10000000)
        if not x then return nil, why, ln end
        y, why = num(f[3], -10000000, 10000000)
        if not y then return nil, why, ln end
        z, why = num(f[4], -32, 31)
        if not z then return nil, why, ln end
        pos = { x, y, z }
        if not row() then return stop() end
    end

    local items, ids, itemLine = {}, {}, {}
    while f[1] == "i" do
        if n ~= 8 then return nil, "FORMAT", ln end
        local idx, cnt
        idx, why = num(f[2], 1, Plan.MAX_PIECES)
        if not idx then return nil, why == "RANGE" and "ITEM" or why, ln end
        if idx ~= #items + 1 then return nil, "ITEM", ln end
        cnt, why = num(f[3], 1, Plan.MAX_PIECES)
        if not cnt then return nil, why, ln end
        local id = f[8]
        if id == "" or #id > MAX_FIELD or #f[4] > MAX_FIELD or #f[6] > MAX_FIELD or #f[7] > MAX_FIELD
            or not workshopOk(f[5]) then
            return nil, "FORMAT", ln
        end
        if ids[id] then return nil, "ITEM", ln end
        ids[id] = true
        items[idx] = { id = id, n = cnt, mod = undash(f[4]), workshop = undash(f[5]), version = undash(f[6]),
            modName = undash(f[7]) }
        itemLine[idx] = ln
        if not row() then return stop() end
    end

    if headOnly then
        if f[1] ~= "p" and f[1] ~= "END" then return nil, "FORMAT", ln end
        return { name = name, w = w, h = h, levels = lv, n = count, items = items, pos = pos }
    end

    local plan = Plan.new(name)
    Plan.begin(plan)
    for _, item in ipairs(items) do Plan.item(plan, item.id, item) end
    local seen, pc = {}, 0
    while f[1] == "p" do
        if n ~= 7 and n ~= 8 then return nil, "FORMAT", ln end
        local x, y, z, d, o, it, pw
        x, why = num(f[2], 0, w - 1)
        if not x then return nil, why, ln end
        y, why = num(f[3], 0, h - 1)
        if not y then return nil, why, ln end
        z, why = num(f[4], 0, lv - 1)
        if not z then return nil, why, ln end
        d, why = num(f[5], 0, 5)
        if not d then return nil, why, ln end
        o, why = num(f[6], 0, 1)
        if not o then return nil, why, ln end
        it, why = num(f[7], 1, #items)
        if not it then return nil, why == "RANGE" and "ITEM" or why, ln end
        if n == 8 then
            pw, why = num(f[8], 2, Plan.MAX_SIDE)
            if not pw then return nil, why, ln end
        end
        pc = pc + 1
        if pc > count then return nil, "COUNT", ln end
        local ok
        ok, why = Plan.add(plan, x, y, z, d, o, it, pw)
        if not ok then return nil, why, ln end
        seen[it] = (seen[it] or 0) + 1
        if not row() then return stop() end
    end
    if line ~= "END" then return nil, "FORMAT", ln end
    if pc ~= count then return nil, "COUNT", ln end
    for idx, item in ipairs(items) do
        if seen[idx] ~= item.n then return nil, "COUNT", itemLine[idx] end
    end
    Plan.commit(plan)
    Plan.forget(plan)
    plan.rev = 0
    if pos then plan.ox, plan.oy, plan.oz = pos[1], pos[2], pos[3] end
    return plan
end

local function textLines(text)
    local pos, len = 1, #text
    return function()
        if pos > len then return nil end
        local e = text:find("\n", pos, true)
        local line
        if e then
            line, pos = text:sub(pos, e - 1), e + 1
        else
            line, pos = text:sub(pos), len + 1
        end
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        return line
    end
end

local function arrayLines(lines)
    local i = 0
    return function()
        i = i + 1
        return lines[i]
    end
end

-- 套上讀檔上限：超過行數、總字數或單行長度時回 false，之後一直回 false
local function bounded(nextLine)
    local lines, size, over = 0, 0, false
    return function()
        if over then return false end
        local line = nextLine()
        if line == nil then return nil end
        lines, size = lines + 1, size + #line + 1
        if lines > MAX_LINES or size > MAX_TEXT or #line > MAX_LINE then
            over = true
            return false
        end
        return line
    end
end

-- 回 plan，或 nil, 原因碼, 第幾行
function PlanFile.decode(text)
    if type(text) ~= "string" then return nil, "FORMAT", 0 end
    if #text > MAX_TEXT then return nil, "TOO_BIG", 0 end
    return parse(bounded(textLines(text)), false)
end

-- ===== 分享碼 =====
-- 一行、只用英數與 : - / ( ) . + = , ; 這些字元（剪貼簿、聊天室、Discord 都不會吃掉或改成格式）。
-- Lua 讀剪貼簿（Clipboard.getClipboard）拿到的是遊戲視窗上次取得焦點時的內容（Clipboard.java:32-49、Display.java:227-236）：
-- 在別的視窗複製、再切回遊戲讀得到；遊戲視窗一直在前景時讀到的是舊的。寫剪貼簿超過約 64 KB 會讓 render 執行緒當掉、
-- pcall 擋不住（LWJGL 的 MemoryStack，2026-11-16 實機 97,746 bytes 當掉、60,000 沒事）：超過 SHARE_MAX 的分享碼改傳檔。
PlanFile.SHARE_MAX = 60000
-- MBLD1;N名稱;C片數;[P x,y,z;]I項目ID,MOD-ID,工作坊編號,版本,MOD名稱;…;G項目,朝向,疊放,層[,寬度];x,y[,長度];…;K檢查碼
-- 每一組（同項目、朝向、疊放、層、寬度）的片寫成一段一段：長度正數＝往 +x 連續、負數＝往 +y 連續。
-- 寬度（車庫門）寫在組頭，同寬的幾扇照樣能併成一段；還原時每一片都帶這個寬度。
-- 字串欄位：英數與 : - / ( ) 照寫，_ 寫成 .，空白寫成 +，其他寫成 =XX（字碼 < 256）或 =uXXXX（Kahlua 的 UTF-16 字）。
-- 檢查碼蓋住 K 之前的全部內容，改過一個字就拒收。
local HEX = "0123456789ABCDEF"
local function hex(c, digits)
    local s = ""
    for _ = 1, digits do
        local r = c % 16
        s = HEX:sub(r + 1, r + 1) .. s
        c = (c - r) / 16
    end
    return s
end

local function esc(s)
    s = tostring(s or "")
    local out = {}
    for i = 1, #s do
        local c = s:byte(i)
        if (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
            or c == 58 or c == 45 or c == 47 or c == 40 or c == 41 then
            out[i] = s:sub(i, i)
        elseif c == 95 then
            out[i] = "."
        elseif c == 32 then
            out[i] = "+"
        elseif c < 256 then
            out[i] = "=" .. hex(c, 2)
        else
            out[i] = "=u" .. hex(c, 4)
        end
    end
    return table.concat(out)
end

-- 還原；有不認得的字元回 nil。=uXXXX 的代理對要成對：單獨一半在存檔時會被換成 ?，讀回比對不合
local function unesc(s)
    local out, i, len = {}, 1, #s
    local function code(at, digits)
        local h = s:sub(at, at + digits - 1)
        if #h ~= digits or not h:match("^[0-9A-F]+$") then return nil end
        return tonumber(h, 16)
    end
    while i <= len do
        local ch = s:sub(i, i)
        if ch == "." then
            out[#out + 1] = "_"
            i = i + 1
        elseif ch == "+" then
            out[#out + 1] = " "
            i = i + 1
        elseif ch == "=" then
            local digits = s:sub(i + 1, i + 1) == "u" and 4 or 2
            local start = i + (digits == 4 and 2 or 1)
            local c = code(start, digits)
            if not c then return nil end
            i = start + digits
            local ok, text
            if c >= 55296 and c <= 57343 then -- D800..DFFF
                local lo = c <= 56319 and s:sub(i, i + 1) == "=u" and code(i + 2, 4)
                if not lo or lo < 56320 or lo > 57343 then return nil end
                ok, text = pcall(string.char, c, lo)
                i = i + 6
            else
                ok, text = pcall(string.char, c) -- 標準 Lua 收不了 > 255；Kahlua 是 UTF-16 字
            end
            if not ok then return nil end
            out[#out + 1] = text
        elseif ch:match("^[A-Za-z0-9:%-/()]$") then
            out[#out + 1] = ch
            i = i + 1
        else
            return nil
        end
    end
    return table.concat(out)
end

local function checksum(s)
    local h = 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 9999991 end
    return h
end

-- 一組片（同項目、朝向、疊放、層）寫成一段一段：從每片往左、往上找到那一排的頭，取比較長的方向
local function runs(cells, put)
    local set, used = {}, {}
    for _, c in ipairs(cells) do set[c[2] * 64 + c[1]] = true end
    local function free(x, y) return x >= 0 and y >= 0 and x < 64 and y < 64 and set[y * 64 + x] and not used[y * 64 + x] end
    for _, c in ipairs(cells) do
        local x, y = c[1], c[2]
        if not used[y * 64 + x] then
            local sx, sy = x, y
            while free(sx - 1, y) do sx = sx - 1 end
            while free(x, sy - 1) do sy = sy - 1 end
            local lx, ly = 0, 0
            while free(sx + lx, y) do lx = lx + 1 end
            while free(x, sy + ly) do ly = ly + 1 end
            if lx >= ly then
                for k = 0, lx - 1 do used[y * 64 + sx + k] = true end
                put(lx == 1 and (sx .. "," .. y) or (sx .. "," .. y .. "," .. lx))
            else
                for k = 0, ly - 1 do used[(sy + k) * 64 + x] = true end
                put(x .. "," .. sy .. "," .. (-ly))
            end
        end
    end
end

-- withPos：要不要帶地上的位置（可省略＝不帶）
function PlanFile.share(plan, ...)
    local withPos = opt(...)
    local out = {}
    local function put(s) out[#out + 1] = s end
    local x0, y0, z0 = frame(plan)
    put("MBLD1")
    put("N" .. esc(Plan.cleanName(plan.name)))
    put("C" .. plan.n)
    if withPos and plan.ox and plan.n > 0 then
        put("P" .. (plan.ox + x0) .. "," .. (plan.oy + y0) .. "," .. (plan.oz + z0))
    end
    local map, list = renumber(plan)
    for _, item in ipairs(list) do
        local ws = item.workshop and tostring(item.workshop) or ""
        if not ws:match("^[0-9]*$") or #ws > 20 then ws = "" end
        put("I" .. esc(item.id) .. "," .. esc(item.mod) .. "," .. ws .. "," .. esc(item.version) .. "," .. esc(item.modName))
    end
    local groups, order = {}, {}
    Plan.each(plan, function(p)
        local it, z = map[p.it], p.z - z0
        local key = (((it * 6 + p.d) * 2 + p.o) * 4 + z) * 65 + (p.w or 0)
        local g = groups[key]
        if not g then
            g = { head = "G" .. it .. "," .. p.d .. "," .. p.o .. "," .. z .. (p.w and ("," .. p.w) or ""), cells = {} }
            groups[key] = g
            order[#order + 1] = g
        end
        g.cells[#g.cells + 1] = { p.x - x0, p.y - y0 }
    end)
    for _, g in ipairs(order) do
        put(g.head)
        runs(g.cells, put)
    end
    local body = table.concat(out, ";") .. ";"
    return body .. "K" .. checksum(body)
end

-- 回 plan，或 nil, 原因碼, 第幾段（分號分開的第幾段，1 起算；0＝整段）
function PlanFile.unshare(code)
    if type(code) ~= "string" then return nil, "FORMAT", 0 end
    code = code:gsub("%s", "") -- 貼上時前後多的空白、換行
    if #code > MAX_SHARE then return nil, "TOO_BIG", 0 end
    local recs, nr = split(code, ";")
    if recs[1]:sub(1, 4) ~= "MBLD" then return nil, "FORMAT", 1 end
    if recs[1] ~= "MBLD1" then return nil, "VERSION", 1 end
    local last = recs[nr]
    if nr < 4 or last:sub(1, 1) ~= "K" then return nil, "NO_END", nr end
    local sum = num(last:sub(2), 0, 9999990)
    if sum ~= checksum(code:sub(1, #code - #last)) then return nil, "CHECKSUM", nr end

    local name = recs[2]:sub(1, 1) == "N" and unesc(recs[2]:sub(2))
    if not name then return nil, "FORMAT", 2 end
    if recs[3]:sub(1, 1) ~= "C" then return nil, "FORMAT", 3 end
    local count, why = num(recs[3]:sub(2), 0, 999999999)
    if not count then return nil, why, 3 end
    if count > Plan.MAX_PIECES then return nil, "FULL", 3 end

    -- 轉成檔案的各行再交給同一個 parse 檢查；recOf[行]＝來自第幾段
    local lines, recOf = {}, {}
    local function put(s, r)
        lines[#lines + 1] = s
        recOf[#lines] = r
    end
    local r = 4
    local pos
    if recs[r]:sub(1, 1) == "P" then
        local f, n = split(recs[r]:sub(2), ",")
        if n ~= 3 then return nil, "FORMAT", r end
        pos = { f = f, r = r }
        r = r + 1
    end
    local items = {}
    while r < nr and recs[r]:sub(1, 1) == "I" do
        local f, n = split(recs[r]:sub(2), ",")
        if n ~= 5 or #items >= Plan.MAX_PIECES then return nil, "FORMAT", r end
        local id, mod, ver, modName = unesc(f[1]), unesc(f[2]), unesc(f[4]), unesc(f[5])
        if not id or not mod or not ver or not modName or not f[3]:match("^[0-9]*$") then return nil, "FORMAT", r end
        items[#items + 1] = { id = id, mod = mod, ws = f[3], ver = ver, modName = modName, r = r, n = 0 }
        r = r + 1
    end
    local pieces, g = {}, nil
    local mx, my, mz = 0, 0, 0
    while r < nr do
        local rec = recs[r]
        local f, n = split(rec:sub(rec:sub(1, 1) == "G" and 2 or 1), ",")
        if rec:sub(1, 1) == "G" then
            if n ~= 4 and n ~= 5 then return nil, "FORMAT", r end
            local it, d, o, z
            it, why = num(f[1], 1, #items)
            if not it then return nil, why == "RANGE" and "ITEM" or why, r end
            d, why = num(f[2], 0, 5)
            if not d then return nil, why, r end
            o, why = num(f[3], 0, 1)
            if not o then return nil, why, r end
            z, why = num(f[4], 0, Plan.MAX_LEVELS - 1)
            if not z then return nil, why, r end
            g = { it = it, d = d, o = o, z = z, w = f[5] } -- 寬度原樣轉成 p 行，由 parse 檢查範圍
            if z > mz then mz = z end
        else
            if not g or n < 2 or n > 3 then return nil, "FORMAT", r end
            local x, y, len = num(f[1], 0, Plan.MAX_SIDE - 1), num(f[2], 0, Plan.MAX_SIDE - 1), 1
            if not x or not y then return nil, "RANGE", r end
            if n == 3 then
                len, why = num(f[3], -Plan.MAX_SIDE, Plan.MAX_SIDE)
                if not len then return nil, why, r end
                if len >= -1 and len <= 1 then return nil, "RANGE", r end
            end
            local dx, dy = 1, 0
            if len < 0 then dx, dy, len = 0, 1, -len end
            if x + dx * (len - 1) >= Plan.MAX_SIDE or y + dy * (len - 1) >= Plan.MAX_SIDE then return nil, "RANGE", r end
            if #pieces + len > Plan.MAX_PIECES then return nil, "FULL", r end
            for k = 0, len - 1 do
                local px, py = x + dx * k, y + dy * k
                pieces[#pieces + 1] = { px, py, g, r }
                if px > mx then mx = px end
                if py > my then my = py end
            end
            items[g.it].n = items[g.it].n + 1 * len
        end
        r = r + 1
    end

    put(MAGIC .. "\t1", 1)
    put("name\t" .. name, 2)
    if #pieces > 0 then put("size\t" .. (mx + 1) .. "\t" .. (my + 1) .. "\t" .. (mz + 1), 3)
    else put("size\t0\t0\t0", 3) end
    put("count\t" .. count, 3)
    if pos then put("pos\t" .. pos.f[1] .. "\t" .. pos.f[2] .. "\t" .. pos.f[3], pos.r) end
    for k, it in ipairs(items) do
        local ws = it.ws == "" and "-" or it.ws
        put("i\t" .. k .. "\t" .. it.n .. "\t" .. dash(it.mod) .. "\t" .. ws .. "\t" .. dash(it.ver) .. "\t"
            .. dash(it.modName) .. "\t" .. it.id, it.r)
    end
    for _, p in ipairs(pieces) do
        local pg = p[3]
        put("p\t" .. p[1] .. "\t" .. p[2] .. "\t" .. pg.z .. "\t" .. pg.d .. "\t" .. pg.o .. "\t" .. pg.it
            .. (pg.w and ("\t" .. pg.w) or ""), p[4])
    end
    put("END", 3)
    local plan, code2, ln = parse(bounded(arrayLines(lines)), false)
    if not plan then return nil, code2, recOf[ln] or 0 end
    return plan
end

-- ===== 檔案（引擎函式只在下面） =====
-- getFileReader／getFileWriter 的路徑相對 Zomboid/Lua，寫入時自動建資料夾；getFileWriter 只收 ini/cfg/txt/log/json
-- 副檔名、路徑不能有 ..（LuaManager.java:1037,5907-5937,6684-6719,8479-8485）。
-- 引擎會吞掉讀寫錯誤（Favorites.lua 開頭）：讀要看到 END 才算完整，寫完要讀回比對。
-- 刪檔、改名：LuaManager 開給 Lua 的刪除只有存檔、資料庫、沙盒預設各自的資料夾（deleteSave、deleteDatabase、
-- deleteSandboxPreset，:4603-4636,5893-5905），改名只有存檔（renameSavefile，:8112-8139），都碰不到 Zomboid/Lua；
-- Kahlua 的 os 也沒有 remove、rename，沒有 io（2026-11-16 實機）。
-- 所以「刪除」＝把檔案改寫成 TOMB（列清單時略過、檔名可以再用），「改名」＝寫新檔再把舊檔標成刪除。
-- getFileWriter 一開檔就把舊內容清掉（FileWriter 非附加，LuaManager.java:6684-6719），又不能改名，所以每次存檔
-- 先完整寫進同名的 .cfg 備份檔、讀回確認，再寫正式檔（writeSafe）：任何時間點斷掉，兩份裡至少一份是完整的。
-- 列資料夾只列檔案（LuaManager.java:6030-6041），裡面還有備份檔與別的檔，所以只收英數檔名的 .txt。
-- 檔名只用英數＋.txt（使用者 2026-11-16 定案；顯示名稱寫在檔裡）。

local function path(file)
    return PlanFile.DIR .. "/" .. file
end

local function backupOf(p)
    return p:sub(1, -5) .. ".cfg"
end

local function validFile(file)
    return type(file) == "string" and #file <= 40 and file:match("^[A-Za-z0-9]+%.txt$") ~= nil
end

local function openReader(p)
    local ok, r = pcall(getFileReader, p, false)
    if ok then return r end
    return nil
end

-- 第一行；沒有檔回 nil，空檔回 ""
local function firstLine(p)
    local r = openReader(p)
    if not r then return nil end
    local line = r:readLine()
    r:close()
    return line or ""
end

-- 整檔的各行（有上限）；沒有檔、超過上限回 nil
local function readLines(p)
    local r = openReader(p)
    if not r then return nil end
    local src, lines = bounded(function() return r:readLine() end), {}
    local line = src()
    while line do
        lines[#lines + 1] = line
        line = src()
    end
    r:close()
    if line == false then return nil end
    return lines
end

local function writeText(p, text)
    local w = getFileWriter(p, true, false)
    if not w then return false end
    w:write(text)
    w:close()
    return true
end

-- 寫完讀回比對
local function rawWrite(p, text)
    local ok, wrote = pcall(writeText, p, text)
    local okRead, lines = pcall(readLines, p)
    return ok and wrote and okRead and lines ~= nil and table.concat(lines, "\n") .. "\n" == text
end

-- a 的內容是 b 的開頭（最後一行可以只有半行）
local function prefixOf(a, b)
    local n = #a
    if n > #b then return false end
    for i = 1, n - 1 do
        if a[i] ~= b[i] then return false end
    end
    return n == 0 or b[n]:sub(1, #a[n]) == a[n]
end

-- 存檔（p 相對 Zomboid/Lua，副檔名 .txt）：先寫備份檔、讀回確認，再寫正式檔。回 true，或 nil, "WRITE"
function PlanFile.writeSafe(p, text)
    if not rawWrite(backupOf(p), text) then return nil, "WRITE" end
    if not rawWrite(p, text) then return nil, "WRITE" end
    return true
end

-- 讀 writeSafe 存的檔。use(nextLine) 回 結果，或 nil, 原因碼, 行號（nextLine 超過上限回 false）。
-- 正式檔讀不出來、而且內容是備份檔的開頭（寫正式檔時斷掉）才改用備份檔，並把正式檔修回來；
-- 別人換進來的壞檔不是備份檔的開頭，照樣回它的錯。刪除標記照樣是刪除，不從備份復活。
function PlanFile.readSafe(p, use)
    local r = openReader(p)
    if not r then return nil, "NO_FILE" end
    local got = {}
    local src = bounded(function()
        local line = r:readLine()
        if line then got[#got + 1] = line end
        return line
    end)
    local ok, a, b, c = pcall(use, src)
    local okRest, last = true, nil
    if not (ok and a) then
        okRest, last = pcall(function()
            local line = src()
            while line do line = src() end
            return line
        end)
    end
    pcall(function() r:close() end)
    if ok and a then return a, b, c end
    if not ok then a, b, c = nil, "READ", nil end
    if b == "DELETED" or not okRest or last == false then return a, b, c end
    local okBack, back = pcall(readLines, backupOf(p))
    if not okBack or not back or not prefixOf(got, back) then return a, b, c end
    local ok2, a2, b2, c2 = pcall(use, bounded(arrayLines(back)))
    if not ok2 or not (a2 or b2 == "DELETED") then return a, b, c end
    rawWrite(p, table.concat(back, "\n") .. "\n") -- 修不回來也沒關係，下次照樣從備份讀
    return a2, b2, c2
end

-- 有內容而且不是刪除標記。正式檔是空的（寫正式檔時一開檔就斷掉）看備份檔
local function alive(file)
    local line = firstLine(path(file))
    if line == "" then line = firstLine(backupOf(path(file))) end
    return line ~= nil and line ~= "" and line ~= TOMB
end

-- 藍圖資料夾裡的藍圖檔名（不含已刪除的），和略過的 .txt 檔數（檔名不合規則）。每個檔讀第一行判斷有沒有刪掉
function PlanFile.list()
    local out, skipped = {}, 0
    local ok, files = pcall(listFilesInZomboidLuaDirectory, PlanFile.DIR)
    if not ok or not files then return out, skipped end
    for i = 0, files:size() - 1 do
        local f = files:get(i)
        if validFile(f) then
            local okA, live = pcall(alive, f)
            if okA and live then out[#out + 1] = f end
        elseif type(f) == "string" and f:lower():sub(-4) == ".txt" then
            skipped = skipped + 1
        end
    end
    return out, skipped
end

local function readWith(file, headOnly)
    if not validFile(file) then return nil, "FILE" end
    local a, b = PlanFile.readSafe(path(file), function(src) return parse(src, headOnly) end)
    return a, b
end

-- 只讀到片行之前：{ name, w, h, levels, n, items＝{ { id, n, mod, modName, workshop, version }… }, pos＝{ x, y, z } 或 nil }
function PlanFile.head(file)
    return readWith(file, true)
end

function PlanFile.load(file)
    local plan, why = readWith(file, false)
    if not plan then return nil, why end
    plan.file = file
    return plan
end

-- 讀得回來嗎：行數、字數、行長在上限內，項目 ID 不超過欄位上限（MOD 資訊的欄位存檔時已經截短）
local function readable(text)
    local src = bounded(textLines(text))
    local line = src()
    while line do
        if line:sub(1, 2) == "i\t" and #line:match("[^\t]*$") > MAX_FIELD then return false end
        line = src()
    end
    return line == nil
end

function PlanFile.save(plan, file)
    if not validFile(file) then return nil, "FILE" end
    local text = PlanFile.encode(plan)
    if not readable(text) then return nil, "TOO_BIG" end
    local ok, why = PlanFile.writeSafe(path(file), text)
    if not ok then return nil, why end
    plan.file = file
    return true
end

function PlanFile.remove(file)
    if not validFile(file) then return nil, "FILE" end
    return PlanFile.writeSafe(path(file), TOMB .. "\nEND\n")
end

-- 顯示名稱 → 檔名：只留英數、轉小寫、最多 24 字；撞名加 2、3…。資料夾有 N 個檔時前 N+1 個編號一定有空的，
-- 所以沒有上限，也不用一個一個開檔：只有不加編號的那個檔名會開來看是不是已刪除（可以再用）。
-- keep＝這個檔名就算有檔也能用。回 檔名，或 nil, "READ"（列不出資料夾）
local function pickName(name, keep)
    local stem = tostring(name or ""):gsub("[^A-Za-z0-9]", ""):lower():sub(1, 24)
    if stem == "" then stem = "plan" end
    local ok, files = pcall(listFilesInZomboidLuaDirectory, PlanFile.DIR)
    if not ok or not files then return nil, "READ" end
    local used, n = {}, files:size()
    for i = 0, n - 1 do used[tostring(files:get(i)):lower()] = true end -- Windows 的檔名不分大小寫
    for i = 1, n + 1 do
        local f = stem .. (i > 1 and i or "") .. ".txt"
        if f == keep or not used[f] then return f end
        if i == 1 then
            local okA, live = pcall(alive, f)
            if okA and not live then return f end
        end
    end
    return nil, "READ"
end

-- 回 檔名，或 nil, 原因
function PlanFile.fileName(name)
    return pickName(name, nil)
end

-- 改顯示名稱，檔名跟著改。回 新檔名；舊檔沒標成刪除時多回 "OLD_LEFT"（新檔已存好）；失敗回 nil, 原因
function PlanFile.rename(file, newName)
    local plan, why = PlanFile.load(file)
    if not plan then return nil, why end
    plan.name = Plan.cleanName(newName)
    local target
    target, why = pickName(plan.name, file)
    if not target then return nil, why end
    local ok
    ok, why = PlanFile.save(plan, target)
    if not ok then return nil, why end
    if target ~= file and not PlanFile.remove(file) then return target, "OLD_LEFT" end
    return target
end

-- 複製一份；newName 可省略（＝同一個顯示名稱）。回 新檔名，或 nil, 原因
function PlanFile.duplicate(file, ...)
    local newName = opt(...)
    local plan, why = PlanFile.load(file)
    if not plan then return nil, why end
    if newName ~= nil then plan.name = Plan.cleanName(newName) end
    local target
    target, why = pickName(plan.name, nil)
    if not target then return nil, why end
    local ok
    ok, why = PlanFile.save(plan, target)
    if not ok then return nil, why end
    return target
end

-- 圖塊來自哪個 MOD：{ mod, modName, workshop, version }；原版的圖、配方項目、查不到的回 nil。
-- 圖塊 → tiledef 檔號 → MOD ID 用 Sources（Entry.resolve 判斷來源被關掉也用這一套）；名稱、工作坊編號、版本讀
-- ChooseGameInfo.Mod 的 getName／getWorkshopID／getModVersion（ChooseGameInfo.java:555,753,701；getModInfoByID，
-- LuaManager.java:5379-5388）。回的表同一個 MOD 共用，唯讀。
local sourceOf = {}
function PlanFile.source(name)
    if type(name) ~= "string" or name:sub(1, 7) == "recipe:" then return nil end
    local spr = B.Entry.sprite(name)
    if not spr then return nil end
    local Sources = B.Sources
    local file = Sources.fileOf(spr:getID())
    if not Sources.isModFile(file) then return nil end
    local mod = Sources.map()[file]
    if not mod then return nil end
    local src = sourceOf[mod]
    if not src then
        local info = getModInfoByID(mod)
        local function text(v) if v ~= nil and v ~= "" then return tostring(v) end end
        src = { mod = mod, modName = info and text(info:getName()), workshop = info and text(info:getWorkshopID()),
            version = info and text(info:getModVersion()) }
        sourceOf[mod] = src
    end
    return src
end

return PlanFile
