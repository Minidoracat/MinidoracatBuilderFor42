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
    return Plan.cut(clean(v), MAX_FIELD)
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
        if id == "" or #id > MAX_FIELD or clean(id) ~= id -- 控制字元存檔時會換成空白，兩個 ID 會變成同一個
            or #f[4] > MAX_FIELD or #f[6] > MAX_FIELD or #f[7] > MAX_FIELD
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
-- 一行、只用英數與 - / ( ) . + = , ; 這些字元：不用 Markdown 的記號，也不寫冒號（:名稱: 在聊天軟體會被換成表情）。
-- 沒有實際貼到各家聊天軟體驗過；被改過的碼檢查碼對不上，整張拒收，不會收到錯的藍圖。
-- Lua 讀剪貼簿（Clipboard.getClipboard）拿到的是遊戲視窗上次取得焦點時的內容（Clipboard.java:32-49、Display.java:227-236）：
-- 在別的視窗複製、再切回遊戲讀得到；遊戲視窗一直在前景時讀到的是舊的。寫剪貼簿超過約 64 KB 會讓 render 執行緒當掉、
-- pcall 擋不住（LWJGL 的 MemoryStack，2026-11-16 實機 97,746 bytes 當掉、60,000 沒事）：超過 SHARE_MAX 的分享碼改傳檔。
PlanFile.SHARE_MAX = 60000
-- MBLD2;N名稱;C片數;[Px,y,z;]〔S…;〕T…;…;G…;…;K檢查碼（段的順序固定：S／T 全在 G 前面，G 之後只能是 G 或 K）
--   S MOD-ID,工作坊編號,版本,MOD名稱：後面的 T 段都來自這個 MOD；第一個 S 之前的 T 段是原版的。
--   T 前綴[,數字…]：每個數字是一個項目，ID＝前綴_數字（數字照原樣，前面的 0 也留著）；沒有數字時 ID＝前綴本身（配方）。
--     項目編號照出現的順序，不寫出來。
--   G 一個項目的片，照項目編號一段一個、不寫編號。裡面一到多組，逗號分開；一組＝1 個字的（朝向×2＋疊放）×4＋層，
--     後面接格子：xy＝一格、=xy寬高＝長方形（寬與高各減 1）、-xy寬＝帶寬度的一片（車庫門，寬減 1）。
--   G 段裡的數值都是一個字：0-9 A-Z a-z + /＝0..63（所以邊長上限 64、層數上限 4 寫死在格式裡）。
-- 發布後玩家手上的分享碼要一直收得下：要改格式就換 MBLD3，MBLD2 的解碼留著。
-- 字串欄位：英數與 - / ( ) 照寫，_ 寫成 .，空白寫成 +，其他（含冒號＝=3A）寫成 =XX（字碼 < 256）或 =uXXXX（Kahlua 的 UTF-16 字）。
--   照寫的冒號不收（發布後解碼只能放寬、不能收緊）；英數與 - / ( ) 寫成 =XX 照收，以後編碼可以多跳脫幾種字。
--   S 的 MOD-ID、版本、MOD 名稱與 T 的前綴還原後最多 128 字、不能有控制字元，不合的整張拒收
--   （這些字串很多項目共用，先擋才不會一段長字串被接成幾千份）。編碼時 MOD 資訊照存檔的截法截到 128 字。
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
            or c == 45 or c == 47 or c == 40 or c == 41 then
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
        elseif ch:match("^[A-Za-z0-9%-/()]$") then
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

local A64 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+/"
local D64 = {}
for i = 1, 64 do D64[A64:byte(i)] = i - 1 end
local function c64(v) return A64:sub(v + 1, v + 1) end

-- 一組片的格子寫成單格與長方形。cells＝格子的 y×64＋x，由小到大；set[格子]＝true。
-- 照順序拿還沒寫的第一格當左上角，取從它開始面積最大的長方形（面積一樣取比較寬的）；
-- 3 格以上寫成 =xy寬高（5 字），1、2 格一格一格寫（2 字一格）
local function rects(cells, set)
    local out, used = {}, {}
    for _, k in ipairs(cells) do
        if not used[k] then
            local x, y = k % 64, math.floor(k / 64)
            local bw, bh, best, hmax, w = 1, 1, 0, 64, 0
            while x + w < 64 and set[k + w] and not used[k + w] do
                local h = 1
                while h < hmax and y + h < 64 and set[k + w + h * 64] and not used[k + w + h * 64] do h = h + 1 end
                hmax = h
                w = w + 1
                if w * hmax >= best then best, bw, bh = w * hmax, w, hmax end
            end
            for dy = 0, bh - 1 do
                for dx = 0, bw - 1 do
                    used[k + dy * 64 + dx] = true
                    if best < 3 then out[#out + 1] = c64(x + dx) .. c64(y + dy) end
                end
            end
            if best >= 3 then out[#out + 1] = "=" .. c64(x) .. c64(y) .. c64(bw - 1) .. c64(bh - 1) end
        end
    end
    return table.concat(out)
end

-- withPos：要不要帶地上的位置（可省略＝不帶）。同一張藍圖每次編出同一串：項目照藍圖裡的順序分組，片照格子的順序
function PlanFile.share(plan, ...)
    local withPos = opt(...)
    local out = {}
    local function put(s) out[#out + 1] = s end
    local x0, y0, z0 = frame(plan)
    put("MBLD2")
    put("N" .. esc(Plan.cleanName(plan.name)))
    put("C" .. plan.n)
    if withPos and plan.ox and plan.n > 0 then
        put("P" .. (plan.ox + x0) .. "," .. (plan.oy + y0) .. "," .. (plan.oz + z0))
    end
    -- 項目：同一個來源的排在一起，同一個前綴的寫成一個 T 段；都照第一次出現的順序，原版的排最前面
    local function field(v) -- 和存檔的 dash 同一種截法：編得出來的碼一定解得回去
        return v == nil and "" or esc(Plan.cut(clean(v), MAX_FIELD))
    end
    local map, list = renumber(plan)
    local srcs, order = {}, {}
    for k, item in ipairs(list) do
        local ws = item.workshop and tostring(item.workshop) or ""
        if not ws:match("^[0-9]*$") or #ws > 20 then ws = "" end
        local key = field(item.mod) .. "," .. ws .. "," .. field(item.version) .. "," .. field(item.modName)
        local src = srcs[key]
        if not src then
            src = { key = key, tiles = {}, byPre = {} }
            srcs[key] = src
            order[#order + 1] = src
        end
        local id = clean(item.id) -- 和存檔一樣：控制字元換空白（解碼不收控制字元）
        local pre, digits = id:match("^(.*)_([0-9]+)$")
        local t = pre and src.byPre[pre]
        if not t then
            t = { head = "T" .. esc(pre or id), nums = {}, its = {} }
            src.tiles[#src.tiles + 1] = t
            if pre then src.byPre[pre] = t end
        end
        if pre then t.nums[#t.nums + 1] = digits end
        t.its[#t.its + 1] = k
    end
    local newOf, n = {}, 0 -- renumber 的編號 → 分享碼裡的編號
    local function tiles(src)
        for _, t in ipairs(src.tiles) do
            put(#t.nums > 0 and (t.head .. "," .. table.concat(t.nums, ",")) or t.head)
            for _, k in ipairs(t.its) do
                n = n + 1
                newOf[k] = n
            end
        end
    end
    local vanilla = srcs[",,,"]
    if vanilla then tiles(vanilla) end
    for _, src in ipairs(order) do
        if src ~= vanilla then
            put("S" .. src.key)
            tiles(src)
        end
    end
    -- 片：先照格子（y×64＋x）分桶，再由小到大分進各項目的各組，每組的格子自然是排好的（不用 table.sort）
    local bucket = {}
    Plan.each(plan, function(p)
        local k = (p.y - y0) * 64 + p.x - x0
        local b = bucket[k]
        if not b then
            b = {}
            bucket[k] = b
        end
        b[#b + 1] = p
    end)
    local groups = {}
    for it = 1, n do groups[it] = {} end
    for k = 0, 4095 do
        local b = bucket[k]
        if b then
            for _, p in ipairs(b) do
                local gi = groups[newOf[map[p.it]]]
                local h = (p.d * 2 + p.o) * 4 + p.z - z0
                local g = gi[h]
                if not g then
                    g = { cells = {}, set = {}, wide = {} }
                    gi[h] = g
                end
                if p.w then
                    g.wide[#g.wide + 1] = "-" .. c64(p.x - x0) .. c64(p.y - y0) .. c64(p.w - 1)
                else
                    g.cells[#g.cells + 1] = k
                    g.set[k] = true
                end
            end
        end
    end
    for it = 1, n do
        local parts = {}
        for h = 0, 47 do
            local g = groups[it][h]
            if g then parts[#parts + 1] = c64(h) .. rects(g.cells, g.set) .. table.concat(g.wide) end
        end
        put("G" .. table.concat(parts, ","))
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
    if recs[1] ~= "MBLD2" then return nil, "VERSION", 1 end
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
    local mod, ws, ver, modName = "", "", "", ""
    while r < nr do
        local tag = recs[r]:sub(1, 1)
        if tag ~= "S" and tag ~= "T" then break end
        local f, n = split(recs[r]:sub(2), ",")
        if tag == "S" then
            if n ~= 4 or #f[2] > 20 or not f[2]:match("^[0-9]*$") then return nil, "FORMAT", r end
            mod, ws, ver, modName = unesc(f[1]), f[2], unesc(f[3]), unesc(f[4])
            if not mod or not ver or not modName or #mod > MAX_FIELD or #ver > MAX_FIELD or #modName > MAX_FIELD
                or clean(mod) ~= mod or clean(ver) ~= ver or clean(modName) ~= modName then
                return nil, "FORMAT", r
            end
        else
            local pre = unesc(f[1])
            if not pre or #pre > MAX_FIELD then return nil, "FORMAT", r end -- 先擋長度：下面每個數字都接一次前綴
            for k = n > 1 and 2 or 1, n do -- 只有前綴（n＝1）時跑一次
                local id = pre
                if n > 1 then
                    if not f[k]:match("^[0-9]+$") then return nil, "FORMAT", r end
                    id = pre .. "_" .. f[k]
                end
                if #items >= Plan.MAX_PIECES then return nil, "ITEM", r end
                items[#items + 1] = { id = id, mod = mod, ws = ws, ver = ver, modName = modName, r = r, n = 0 }
            end
        end
        r = r + 1
    end
    local pieces, it = {}, 0
    local mx, my, mz = 0, 0, 0
    while r < nr do
        local rec = recs[r]
        if rec:sub(1, 1) ~= "G" then return nil, "FORMAT", r end
        it = it + 1
        if it > #items then return nil, "ITEM", r end
        local gs, ng = split(rec:sub(2), ",")
        for gi = 1, ng do
            local s = gs[gi]
            local len = #s
            if len < 3 then return nil, "FORMAT", r end -- 至少 1 個字的組頭加一格
            local h = D64[s:byte(1)]
            if not h then return nil, "FORMAT", r end -- 48 以上拆出來的朝向超出 0..5，parse 回 RANGE
            local z = h % 4
            local g = { it = it, d = math.floor(h / 8), o = math.floor(h / 4) % 2, z = z }
            if z > mz then mz = z end
            local i = 2
            while i <= len do
                local c, need = s:sub(i, i), 2
                if c == "=" then need, i = 4, i + 1 elseif c == "-" then need, i = 3, i + 1 end
                if i + need - 1 > len then return nil, "FORMAT", r end -- 先看長度：不靠 string.byte 超出範圍時回什麼
                local x, y, a, b = D64[s:byte(i)], D64[s:byte(i + 1)], 0, 0
                if need > 2 then a = D64[s:byte(i + 2)] end
                if need > 3 then b = D64[s:byte(i + 3)] end
                if not (x and y and a and b) then return nil, "FORMAT", r end
                i = i + need
                local w, hh, pw = 1, 1, nil
                if need == 4 then w, hh = a + 1, b + 1 elseif need == 3 then pw = a + 1 end -- 寬度的範圍由 parse 檢查
                if x + w > Plan.MAX_SIDE or y + hh > Plan.MAX_SIDE then return nil, "RANGE", r end
                if #pieces + w * hh > Plan.MAX_PIECES then return nil, "FULL", r end -- 展開之前先擋
                for dy = 0, hh - 1 do
                    for dx = 0, w - 1 do pieces[#pieces + 1] = { x + dx, y + dy, g, r, pw } end
                end
                if x + w - 1 > mx then mx = x + w - 1 end
                if y + hh - 1 > my then my = y + hh - 1 end
                items[it].n = items[it].n + w * hh
            end
        end
        r = r + 1
    end
    if it < #items then return nil, "ITEM", items[it + 1].r end -- 有項目沒有片

    put(MAGIC .. "\t1", 1)
    put("name\t" .. name, 2)
    if #pieces > 0 then put("size\t" .. (mx + 1) .. "\t" .. (my + 1) .. "\t" .. (mz + 1), 3)
    else put("size\t0\t0\t0", 3) end
    put("count\t" .. count, 3)
    if pos then put("pos\t" .. pos.f[1] .. "\t" .. pos.f[2] .. "\t" .. pos.f[3], pos.r) end
    for k, item in ipairs(items) do
        local wsText = item.ws == "" and "-" or item.ws
        put("i\t" .. k .. "\t" .. item.n .. "\t" .. dash(item.mod) .. "\t" .. wsText .. "\t" .. dash(item.ver) .. "\t"
            .. dash(item.modName) .. "\t" .. item.id, item.r)
    end
    for _, p in ipairs(pieces) do
        local pg = p[3]
        put("p\t" .. p[1] .. "\t" .. p[2] .. "\t" .. pg.z .. "\t" .. pg.d .. "\t" .. pg.o .. "\t" .. pg.it
            .. (p[5] and ("\t" .. p[5]) or ""), p[4])
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
-- 列資料夾只列檔案（LuaManager.java:6030-6041），裡面還有備份檔與別的檔，所以只收合檔名規則的 .txt（validFile）。
-- 檔名照藍圖名稱取（pickName；使用者 2026-11-18：藍圖叫「測試房子」檔名卻是 plan.txt，資料夾裡分不出哪個檔是哪張）。
-- 引擎不限制檔名用什麼字（getFileWriter／getFileReader 只擋 .. 與副檔名，直接交給 java.io.File、內容用 UTF-8，
-- LuaManager.java:5910,6687-6719）；這台電腦的檔案系統存不存得住非英數檔名每次遊戲測一次（unicodeOk），
-- 存不住就退回 2026-11-16 的舊規則（只留英數、轉小寫）。舊的英數檔名照讀照寫，不自動改名。

local function path(file)
    return PlanFile.DIR .. "/" .. file
end

local function backupOf(p)
    return p:sub(1, -5) .. ".cfg"
end

local LOG = "[MinidoracatBuilderFor42] "
-- Kahlua 的字串是 UTF-16（一個單位一個字，string.byte 回字碼），標準 Lua 是 UTF-8 位元組；跳脫寫的 U+FFFD
-- 在 Kahlua 是 1 個字（見下面 REPLACEMENT）。只有標準 Lua（harness）走 UTF-8 解碼那條。
local WIDE = #"\239\191\189" == 1

-- 字碼 c 在檔名裡：回 "keep"、"space"（換成一個空白），或 nil（去掉）。
-- ASCII 只留英數、空白、- _ ( )；其他 ASCII（控制字元、. 與 \ / : * ? " < > |）去掉。非 ASCII 照留，但去掉
-- U+0080–009F、U+200B–200F、U+2028–202E、U+2060–206F、U+FEFF、U+FFF9 以上（含 U+FFFD）與代理對 U+D800–DFFF
-- （Kahlua 的表情符號是兩個代理單位，兩半都去掉；標準 Lua 解出來 > U+FFFF 也去掉）；U+00A0、U+3000 當空白。
local function nameChar(c)
    if c < 128 then
        if c == 32 then return "space" end
        if (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
            or c == 45 or c == 95 or c == 40 or c == 41 then return "keep" end
        return nil
    end
    if c == 160 or c == 12288 then return "space" end
    if c <= 159 or (c >= 8203 and c <= 8207) or (c >= 8232 and c <= 8238) or (c >= 8288 and c <= 8303)
        or c == 65279 or (c >= 55296 and c <= 57343) or c >= 65529 then return nil end
    return "keep"
end

-- 第 i 個位置的字：回 字碼（壞的 UTF-8 回 -1）, 佔幾個單位
local function charAt(s, i)
    local c = s:byte(i)
    if WIDE or c < 128 then return c, 1 end -- Kahlua：一個單位就是一個字（128–255 是 U+0080–00FF）
    local n = (c >= 240 and c < 248 and 4) or (c >= 224 and c < 240 and 3) or (c >= 192 and c < 224 and 2) or 1
    if n == 1 then return -1, 1 end
    local cp = c - (n == 4 and 240 or n == 3 and 224 or 192)
    for k = 1, n - 1 do
        local b = s:byte(i + k)
        if not b or b < 128 or b > 191 then return -1, 1 end
        cp = cp * 64 + b - 128
    end
    if cp < 128 then return -1, n end -- 過長編碼
    return cp, n
end

-- 照檔名規則清字串：回 清好的字串, 字數。空白併成一個、去頭尾；max＝最多幾個字（可省略＝不截）
local function cleanStem(s, max)
    local out, n, i, len, gap = {}, 0, 1, #s, false
    while i <= len do
        local c, w = charAt(s, i)
        local kind = c >= 0 and nameChar(c) or nil
        if kind == "space" then
            gap = n > 0
        elseif kind == "keep" then
            local add = gap and 2 or 1
            if max and n + add > max then break end
            out[#out + 1] = (gap and " " or "") .. s:sub(i, i + w - 1)
            n, gap = n + add, false
        end
        i = i + w
    end
    return table.concat(out), n
end

-- 主檔名最多幾個字：名稱的上限，加撞名的編號與保留名稱的 _
local STEM_MAX = Plan.MAX_NAME + 8

-- Windows 的保留裝置名，不分大小寫；上標的 1、2、3 也算（微軟「Naming Files, Paths, and Namespaces」）
local RESERVED = { CON = true, PRN = true, AUX = true, NUL = true }
for i = 0, 9 do RESERVED["COM" .. i], RESERVED["LPT" .. i] = true, true end
for _, d in ipairs({ "\194\185", "\194\178", "\194\179" }) do RESERVED["COM" .. d], RESERVED["LPT" .. d] = true, true end

-- 合規則的藍圖檔名：清過一次不變（擋路徑字元、. 、控制字元、頭尾或連續空白、U+FFFD…）、主檔名不是空的、
-- 字數在上限內（Kahlua 算字、標準 Lua 算解出來的字，40 個中文字都過）。舊的英數檔名也合。
-- 保留裝置名不收：Windows 上 con.txt 開到的是裝置不是檔（世界記錄、最近用過的清單是本機檔，可能被改過）
local function validFile(file)
    if type(file) ~= "string" or #file > STEM_MAX * 3 + 4 or file:sub(-4) ~= ".txt" then return false end
    local stem = file:sub(1, -5)
    local clean, n = cleanStem(stem, nil)
    return stem ~= "" and clean == stem and n <= STEM_MAX and not RESERVED[stem:upper()]
end
PlanFile.validFile = validFile

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

-- 正式檔斷在多位元組字的中間時，引擎的 reader 把殘缺的位元組解成 U+FFFD（InputStreamReader，LuaManager.java:5926-5928）。
-- 用跳脫寫：Kahlua 的 lexer 把跳脫存成位元組、整個字串再照 UTF-8 解（LexState.java:194-200,245-247,433-452），
-- 所以 Kahlua 是 1 個字、標準 Lua 是 3 個位元組，都是 U+FFFD；直接寫這個字會被 lexer 截成 1 個位元組。
local REPLACEMENT = "\239\191\189"

-- a 的內容是 b 的開頭（最後一行可以只有半行，尾端的替代字元不算）
local function prefixOf(a, b)
    local n = #a
    if n > #b then return false end
    for i = 1, n - 1 do
        if a[i] ~= b[i] then return false end
    end
    if n == 0 then return true end
    local last = a[n]
    while #last > 0 and last:sub(-#REPLACEMENT) == REPLACEMENT do last = last:sub(1, -#REPLACEMENT - 1) end
    return b[n]:sub(1, #last) == last
end

-- 正式檔是上次寫到一半的（內容是備份的開頭、但不是整份）：回備份的各行；其他情況回 nil
local function torn(p)
    local okB, back = pcall(readLines, backupOf(p))
    if not okB or not back then return nil end
    local okM, lines = pcall(readLines, p)
    if not okM or not lines or not prefixOf(lines, back) then return nil end
    if #lines == #back and lines[#lines] == back[#back] then return nil end
    return back
end

-- 存檔（p 相對 Zomboid/Lua，副檔名 .txt）：先寫備份檔、讀回確認，再寫正式檔。回 true，或 nil, "WRITE"。
-- 正式檔是上次寫到一半的，備份就是唯一完整的一份：先用備份修回正式檔，修不回來就不動備份
function PlanFile.writeSafe(p, text)
    local back = torn(p)
    if back and not rawWrite(p, table.concat(back, "\n") .. "\n") then return nil, "WRITE" end
    if not rawWrite(backupOf(p), text) then return nil, "WRITE" end
    if not rawWrite(p, text) then return nil, "WRITE" end
    return true
end

-- 讀 writeSafe 存的檔。use(nextLine) 回 結果，或 nil, 原因碼, 行號（nextLine 超過上限回 false）。
-- 正式檔讀不出來、而且內容是備份檔的開頭（寫正式檔時斷掉）才改用備份檔，並把正式檔修回來；
-- 別人換進來的壞檔不是備份檔的開頭，照樣回它的錯；沒有備份檔時也不把壞檔讀完。刪除標記照樣是刪除，不從備份復活。
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
    local function close() pcall(function() r:close() end) end
    if ok and a then
        close()
        return a, b, c
    end
    if not ok then a, b, c = nil, "READ", nil end
    local okB, backHead = pcall(firstLine, backupOf(p))
    if b == "DELETED" or not okB or backHead == nil then
        close()
        return a, b, c
    end
    local okRest, last = pcall(function()
        local line = src()
        while line do line = src() end
        return line
    end)
    close()
    if not okRest or last == false then return a, b, c end
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

-- 確定是刪掉的：讀得到刪除標記（正式檔是空的看備份檔）。打不開、空的都不算：不知道是什麼就不重用那個檔名，
-- 不然一時讀不到的藍圖會被另存、改名寫進去，原檔與備份都蓋掉
local function tombed(file)
    local line = firstLine(path(file))
    if line == "" then line = firstLine(backupOf(path(file))) end
    return line == TOMB
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

-- 這個藍圖檔（正式檔或 .cfg 備份）還在資料夾裡嗎：讀不到（NO_FILE）時分辨「被刪掉了」和「一時打不開」。
-- 列不出資料夾時回 true（分不出來就當還在）
function PlanFile.exists(file)
    if not validFile(file) then return false end
    local ok, files = pcall(listFilesInZomboidLuaDirectory, PlanFile.DIR)
    if not ok or not files then return true end
    local a, b = file:lower(), backupOf(file):lower()
    for i = 0, files:size() - 1 do
        local f = tostring(files:get(i)):lower() -- Windows 的檔名不分大小寫
        if f == a or f == b then return true end
    end
    return false
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

-- 這台電腦存不存得住非英數檔名：在 MinidoracatBuilder/ 寫一個混中文、韓文音節、帶重音拉丁字母的小檔，內容讀得回來、
-- 資料夾清單回來的名稱和寫的一模一樣才算（舊 macOS 磁碟會把韓文、é 拆開存，清單名稱和寫的不同，
-- 照新規則取名會讓兩張不同的藍圖寫進同一個檔；編碼不是 UTF-8 的檔案系統會把字換成 ?）。
-- PlanFile.unicodeNames：nil＝這次遊戲還沒測（第一次要取非英數檔名時才測），之後是 true／false 到遊戲結束
local PROBE_DIR = "MinidoracatBuilder"
local PROBE_FILE = "names-\230\184\172\232\169\166\237\149\156\234\184\128\195\169.txt" -- names-測試한글é.txt
local PROBE_LINE = "MBLDNAMES\t" .. PROBE_FILE
local function unicodeOk()
    if PlanFile.unicodeNames ~= nil then return PlanFile.unicodeNames end
    local p, why = PROBE_DIR .. "/" .. PROBE_FILE, "ok"
    local okW, wrote = pcall(writeText, p, PROBE_LINE .. "\n")
    local okR, line = pcall(firstLine, p)
    if not (okW and wrote) then
        why = "write failed"
    elseif not okR or line ~= PROBE_LINE then
        why = "read back differs"
    else
        why = "name not listed as written"
        local okL, files = pcall(listFilesInZomboidLuaDirectory, PROBE_DIR)
        if okL and files then
            for i = 0, files:size() - 1 do
                if tostring(files:get(i)) == PROBE_FILE then why = "ok" end
            end
        end
    end
    PlanFile.unicodeNames = why == "ok"
    print(LOG .. "plan file names: unicode=" .. tostring(PlanFile.unicodeNames) .. " " .. why)
    return PlanFile.unicodeNames
end

local function ascii(s)
    for i = 1, #s do
        if s:byte(i) > 127 then return false end
    end
    return true
end

local function opens(p)
    local r = openReader(p)
    if r then pcall(function() r:close() end) end
    return r ~= nil
end

-- 顯示名稱 → 檔名：照 cleanStem 清、最多 Plan.MAX_NAME 字、保留大小寫，清完是空的用 plan；Windows 保留名稱後面加 _。
-- 這台電腦存不住非英數檔名時（unicodeOk）退回舊規則：只留英數、轉小寫、最多 24 字。
-- 撞名加 2、3…（照小寫比：Windows 的檔名不分大小寫）。資料夾有 N 個檔時前 N+1 個編號一定有空的，所以沒有上限。
-- 清單裡沒有的候選還要開不起來才用：會改寫檔名的檔案系統清單回來的名稱和寫的不同，只看清單會寫進別張的檔。
-- 不加編號的那個檔名讀得到刪除標記時直接重用（tombed；打不開、空的不重用），回資料夾裡原本的檔名（大小寫可能和算出來的不同，Windows 上是同一個檔）。keep＝這個檔名（不分大小寫）就算有檔也能用：
-- 只差大小寫時回 keep 本身，不然 Windows 上新舊檔名是同一個檔，改名把舊檔標成刪除就刪掉了新檔。
-- 回 檔名，或 nil, "READ"（列不出資料夾）
local function pickName(name, keep)
    local stem = cleanStem(tostring(name or ""), Plan.MAX_NAME)
    if not ascii(stem) then unicodeOk() end
    if PlanFile.unicodeNames == false then stem = tostring(name or ""):gsub("[^A-Za-z0-9]", ""):lower():sub(1, 24) end
    if stem == "" then stem = "plan" end
    local ok, files = pcall(listFilesInZomboidLuaDirectory, PlanFile.DIR)
    if not ok or not files then return nil, "READ" end
    local used, n = {}, files:size()
    for i = 0, n - 1 do
        local have = tostring(files:get(i))
        used[have:lower()] = have
    end
    local low = keep and keep:lower()
    for i = 1, n + 1 do
        local base = stem .. (i > 1 and i or "")
        if RESERVED[base:upper()] then base = base .. "_" end
        local f = base .. ".txt"
        if f:lower() == low then return keep end
        if not used[f:lower()] and not opens(path(f)) then return f end
        if i == 1 then
            local have = used[f:lower()] or f -- 分大小寫的檔案系統上 f 可能不存在，要看的是資料夾裡那個
            local okA, gone = pcall(tombed, have)
            if okA and gone then return have end
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
