-- 最愛：存 Zomboid/Lua/MinidoracatBuilder/favorites.txt，一行一個項目 ID（sprite 名稱；設計稿 DD:727），最後一行是 END。
-- 一個檔涵蓋所有伺服器：這個伺服器沒有的名稱照樣留在檔裡（換回有那個 MOD 的伺服器還在），
-- 只在視窗列出時略過（Window 的最愛分類逐項 Entry.resolve，解析不了的不列，DD:133）。
-- getFileReader／getFileWriter 的路徑相對 Zomboid/Lua；寫入時自動建資料夾（LuaManager.java:5936-5963,6727-6759）。
-- 引擎會吞掉讀寫錯誤：檔案在卻打不開時 getFileReader 回 nil（和檔案不存在一樣），讀到一半出錯時 readLine 回 nil
-- （和讀完一樣，MethodCaller.java:34-42），寫入走 PrintWriter 不丟錯。所以讀要看到最後一行 END 才算完整，
-- 寫完要讀回來比對；沒讀完整就不寫，免得拿殘缺的清單蓋掉檔裡的最愛。
MinidoracatBuilder = MinidoracatBuilder or {}
local Favorites = MinidoracatBuilder.Favorites or {}
MinidoracatBuilder.Favorites = Favorites

local LOG = "[MinidoracatBuilderFor42] "
Favorites.FILE = "MinidoracatBuilder/favorites.txt"
local END = "#end"
local MAX_NAME = 128 -- 同 Entry.sprite 的上限

-- 檔案內容 → list（{ n, 名稱… }，照檔案順序）、set（名稱 → true）。空行、前後空白、重複、過長、# 開頭的略過。
function Favorites.parse(text)
    local list, set = { n = 0 }, {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local name = line:match("^%s*(.-)%s*$")
        if name ~= "" and #name <= MAX_NAME and name:sub(1, 1) ~= "#" and not set[name] then
            set[name] = true
            list.n = list.n + 1
            list[list.n] = name
        end
    end
    return list, set
end

function Favorites.serialize(list)
    local lines = {}
    for i = 1, list.n do lines[i] = list[i] end
    lines[#lines + 1] = END
    return table.concat(lines, "\n") .. "\n"
end

Favorites.list, Favorites.set = { n = 0 }, {}
local loaded = false

-- 整個檔讀成一行一個的陣列；打不開回 nil。先用附加模式開一次寫入：檔案（連資料夾）不存在就建空檔，
-- 存在不動內容，之後 getFileReader 回 nil 就只會是「檔案在、打不開」。
local function readLines()
    local w = getFileWriter(Favorites.FILE, true, true)
    if not w then return nil end
    w:close()
    local reader = getFileReader(Favorites.FILE, false)
    if not reader then return nil end
    local lines, line = {}, reader:readLine()
    while line do
        lines[#lines + 1] = line
        line = reader:readLine()
    end
    reader:close()
    return lines
end

-- 空檔（第一次用、剛建的）或最後一行是 END 才算讀完整；沒讀完整時不載入，下次再讀，也不准寫
function Favorites.load()
    local ok, lines = pcall(readLines)
    loaded = ok and lines ~= nil and (#lines == 0 or lines[#lines] == END)
    if loaded then
        Favorites.list, Favorites.set = Favorites.parse(table.concat(lines, "\n"))
    else
        print(LOG .. "favorites not loaded: the file could not be read completely")
    end
end

-- 回 true＝寫進檔案了（讀回來和要寫的一樣）
function Favorites.save()
    if not loaded then
        print(LOG .. "favorites not saved: the file could not be read")
        return false
    end
    local text = Favorites.serialize(Favorites.list)
    local ok = pcall(function()
        local writer = getFileWriter(Favorites.FILE, true, false)
        if not writer then error("no writer") end
        writer:write(text)
        writer:close()
    end)
    local okRead, lines = pcall(readLines)
    local saved = ok and okRead and lines ~= nil and table.concat(lines, "\n") .. "\n" == text
    if not saved then print(LOG .. "favorites save failed: the file does not hold what was written") end
    return saved
end

-- 第一次用到才讀檔（不在載入 Lua 時碰硬碟）
function Favorites.ensure()
    if not loaded then Favorites.load() end
end

function Favorites.has(name)
    return Favorites.set[name] == true
end

-- 加入或移除，馬上寫檔；回新的狀態（true＝現在是最愛）, 有沒有寫進檔案
function Favorites.toggle(name)
    Favorites.ensure()
    local list = Favorites.list
    if Favorites.set[name] then
        Favorites.set[name] = nil
        local out = { n = 0 }
        for i = 1, list.n do
            if list[i] ~= name then
                out.n = out.n + 1
                out[out.n] = list[i]
            end
        end
        Favorites.list = out
    else
        Favorites.set[name] = true
        list.n = list.n + 1
        list[list.n] = name
    end
    return Favorites.set[name] == true, Favorites.save()
end

return Favorites
