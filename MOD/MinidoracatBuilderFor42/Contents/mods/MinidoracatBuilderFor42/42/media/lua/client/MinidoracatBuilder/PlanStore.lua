-- 每個存檔、每個伺服器各記各的「地上的藍圖」：哪個檔、擺在哪、隱藏沒有、點名的材料箱、上次各項目的狀態。
-- 存本機檔 Zomboid/Lua/MinidoracatBuilder/worlds/<worldId>.txt，不用 modData（多人的玩家 modData 會送到伺服器）。
-- 讀寫照 Favorites.lua：引擎會吞掉讀寫錯誤，讀要看到 END，寫完讀回比對；存檔先寫備份（PlanFile.writeSafe）。
-- 檔案（欄位用 Tab）：MBLDWORLD 1 / file 檔名 / name 名稱代號 / rename 名稱代號 / pos x y z / prev x y z / hidden 0|1 /
-- box x y z 編號 / seen 狀態 項目ID / END
-- prev＝寫這份之前的原點：先寫這裡、再寫藍圖檔，中間斷掉時藍圖檔還是舊的那版，讀回時照它的 pos 認出要用哪個原點
-- name＝那張藍圖的顯示名稱（PlanStore.nameKey）：檔名被別張重用時認得出不是同一張、檔被改名時照名稱找回。沒有這行的舊檔照讀
-- rename＝藍圖庫正在改成的名稱（PlanMode.renaming 寫、改好清掉）：改名寫完藍圖檔、還沒改記錄就斷掉時，讀回兩個名稱都認
require "MinidoracatBuilder/PlanFile"

MinidoracatBuilder = MinidoracatBuilder or {}
local PlanStore = MinidoracatBuilder.PlanStore or {}
MinidoracatBuilder.PlanStore = PlanStore
local PlanFile = MinidoracatBuilder.PlanFile

PlanStore.DIR = "MinidoracatBuilder/worlds"
local MAGIC = "MBLDWORLD\t1"
local MAX_BOXES, MAX_SEEN = 100, 8192
local LOG = "[MinidoracatBuilderFor42] "

local HEX = "0123456789ABCDEF"
-- 英數照寫，其他字元寫成 _XX（字碼 < 256）或 _uXXXX（Kahlua 的 UTF-16 字），不同的名字不會變成同一個代號
local function esc(s)
    local out = {}
    for i = 1, #s do
        local c = s:byte(i)
        if (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) then
            out[i] = s:sub(i, i)
        else
            local digits, h = c < 256 and 2 or 4, ""
            for _ = 1, digits do
                local r = c % 16
                h = HEX:sub(r + 1, r + 1) .. h
                c = (c - r) / 16
            end
            out[i] = (digits == 4 and "_u" or "_") .. h
        end
    end
    return table.concat(out)
end

-- 記錄裡的名稱代號：只剩英數與 _（不會有 Tab、換行），不同的名字不會變成同一個代號
function PlanStore.nameKey(name)
    return esc(tostring(name or ""))
end

-- 遊戲模式＋存檔資料夾名稱（Core.gameSaveWorld，IsoWorld.getWorld，IsoWorld.java:3220-3222）。單機＝Saves/<模式>/<資料夾>
-- （ZomboidFileSystem.java:135-146）；多人＝「IP_埠_md5(帳號)」（GameClient.java:1678），同一台伺服器不同帳號也分開；
-- 自架與 Steam 合作照伺服器名稱另起（GameClient.java:1684,1698、ConnectToServerState.java:177）。
-- 2026-11-16 實機（42.22.2）：單機兩個存檔各自不同、重新讀檔不變，多人兩個帳號不同；模式是 Sandbox／Multiplayer。
-- 玩家改存檔名、伺服器換 IP 或埠時代號會變：地上的藍圖要重擺，藍圖檔不受影響。
-- 不用 getServerName：一般連線時是玩家在伺服器清單自己取的名稱，直連時是空字串。
-- 存檔名可能有中文、. 與 ..（sanitizeWorldName 只換空白、去 /\?*<>:|，LuaManager.java:6756），所以逐字跳脫；
-- 太長的（中文一字變 6 字元）截短再接雜湊，免得路徑過長。
-- 模式字串同原版（getCore():getGameMode():toString()，ISServerSandboxOptionsUI.lua:360；GameMode.java:58-60）。
local MAX_ID = 100
function PlanStore.worldId()
    local mode = tostring(getCore():getGameMode():toString())
    local world = tostring(getWorld():getWorld())
    local id = esc(mode) .. "-" .. esc(world)
    if #id <= MAX_ID then return id end
    local h = 0
    for i = 1, #world do h = (h * 31 + world:byte(i)) % 2147483647 end
    return id:sub(1, MAX_ID - 12) .. "-" .. h
end

local function path()
    return PlanStore.DIR .. "/" .. PlanStore.worldId() .. ".txt"
end

-- PlanFile.readSafe 的讀法：收齊各行（超過上限回 false）
local function collect(nextLine)
    local lines, line = {}, nextLine()
    while line do
        lines[#lines + 1] = line
        line = nextLine()
    end
    if line == false then return nil end
    return lines
end

local function int(s)
    if type(s) ~= "string" or #s > 9 or not s:match("^%-?[0-9]+$") then return nil end
    return tonumber(s)
end

local function split(s)
    local out, n, pos = {}, 0, 1
    while true do
        local e = s:find("\t", pos, true)
        n = n + 1
        out[n] = s:sub(pos, (e or (#s + 1)) - 1)
        if not e then return out, n end
        pos = e + 1
    end
end

-- 檔案內容 → state；不完整或有看不懂的行回 nil（自己的檔，壞了就當沒有）
local function parse(lines)
    if not lines or lines[1] ~= MAGIC or lines[#lines] ~= "END" then return nil end
    local st, nb, ns = { boxes = {}, seen = {} }, 0, 0
    for i = 2, #lines - 1 do
        local f, n = split(lines[i])
        local tag = f[1]
        if tag == "file" and n == 2 and PlanFile.validFile(f[2]) then
            st.file = f[2]
        elseif tag == "name" and n == 2 and f[2]:match("^[A-Za-z0-9_]*$") then
            st.name = f[2]
        elseif tag == "rename" and n == 2 and f[2]:match("^[A-Za-z0-9_]*$") then
            st.renameTo = f[2]
        elseif tag == "pos" and n == 4 and int(f[2]) and int(f[3]) and int(f[4]) then
            st.ox, st.oy, st.oz = int(f[2]), int(f[3]), int(f[4])
        elseif tag == "prev" and n == 4 and int(f[2]) and int(f[3]) and int(f[4]) then
            st.px, st.py, st.pz = int(f[2]), int(f[3]), int(f[4])
        elseif tag == "hidden" and n == 2 and (f[2] == "0" or f[2] == "1") then
            st.hidden = f[2] == "1"
        elseif tag == "box" and n == 5 and nb < MAX_BOXES and int(f[2]) and int(f[3]) and int(f[4]) and int(f[5]) then
            nb = nb + 1
            st.boxes[nb] = { x = int(f[2]), y = int(f[3]), z = int(f[4]), index = int(f[5]) }
        elseif tag == "seen" and n == 3 and ns < MAX_SEEN and f[2]:match("^[A-Za-z0-9_]+$") and f[3] ~= "" then
            ns = ns + 1
            st.seen[f[3]] = f[2]
        elseif lines[i] ~= "" then
            return nil
        end
    end
    return st
end

-- 回 { file, name（名稱代號，舊檔沒有）, renameTo（改到一半的名稱代號，通常沒有）, ox, oy, oz, px, py, pz（上一個原點，
-- 可能沒有）, hidden, boxes＝{ { x, y, z, index }… },
-- seen＝{ [項目 ID]＝上次的狀態 } }；沒有回空表
function PlanStore.load()
    local st, why = PlanFile.readSafe(path(), function(nextLine)
        local s = parse(collect(nextLine))
        if s then return s end
        return nil, "FORMAT"
    end)
    if st then return st end
    if why ~= "NO_FILE" then print(LOG .. "plan store not loaded: the file is incomplete or unreadable") end
    return {}
end

local function serialize(st)
    local out = { MAGIC }
    local function put(s) out[#out + 1] = s end
    if st.file then put("file\t" .. st.file) end
    if st.name then put("name\t" .. st.name) end
    if st.renameTo then put("rename\t" .. st.renameTo) end
    if st.ox then put("pos\t" .. st.ox .. "\t" .. st.oy .. "\t" .. st.oz) end
    if st.px then put("prev\t" .. st.px .. "\t" .. st.py .. "\t" .. st.pz) end
    put("hidden\t" .. (st.hidden and "1" or "0"))
    for i, b in ipairs(st.boxes or {}) do
        if i > MAX_BOXES then break end
        put("box\t" .. b.x .. "\t" .. b.y .. "\t" .. b.z .. "\t" .. (b.index or 0))
    end
    local ns = 0
    for id, state in pairs(st.seen or {}) do
        ns = ns + 1
        if ns > MAX_SEEN then break end
        put("seen\t" .. tostring(state) .. "\t" .. id)
    end
    put("END")
    return table.concat(out, "\n") .. "\n"
end

-- 狀態是英數與 _ 的原因碼；項目 ID 不能有 Tab、換行。回 true，或 nil, "WRITE"（讀回和寫的不一樣）
function PlanStore.save(state)
    local ok, why = PlanFile.writeSafe(path(), serialize(state))
    if ok then return true end
    print(LOG .. "plan store save failed: the file does not hold what was written")
    return nil, why
end

return PlanStore
