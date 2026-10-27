-- 最愛：存 Zomboid/Lua/MinidoracatBuilder/favorites.txt，一行一個項目 ID（sprite 名稱；設計稿 DD:727）。
-- 一個檔涵蓋所有伺服器：這個伺服器沒有的名稱照樣留在檔裡（換回有那個 MOD 的伺服器還在），
-- 只在視窗列出時略過（Window 的最愛分類逐項 Entry.resolve，解析不了的不列，DD:133）。
-- getFileReader／getFileWriter 的路徑相對 Zomboid/Lua；寫入時自動建資料夾（LuaManager.java:5936-5963,6727-6737）。
MinidoracatBuilder = MinidoracatBuilder or {}
local Favorites = MinidoracatBuilder.Favorites or {}
MinidoracatBuilder.Favorites = Favorites

local LOG = "[MinidoracatBuilderFor42] "
Favorites.FILE = "MinidoracatBuilder/favorites.txt"
local MAX_NAME = 128 -- 同 Entry.sprite 的上限

-- 檔案內容 → list（{ n, 名稱… }，照檔案順序）、set（名稱 → true）。空行、前後空白、重複、過長的略過。
function Favorites.parse(text)
    local list, set = { n = 0 }, {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local name = line:match("^%s*(.-)%s*$")
        if name ~= "" and #name <= MAX_NAME and not set[name] then
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
    if #lines == 0 then return "" end
    return table.concat(lines, "\n") .. "\n"
end

Favorites.list, Favorites.set = { n = 0 }, {}
local loaded = false

-- 讀成功（或檔案不存在）才算載入；讀到一半出錯時不載入，下次再讀，也不准寫（不然空清單會蓋掉檔裡的最愛）
function Favorites.load()
    local ok, err = pcall(function()
        local reader = getFileReader(Favorites.FILE, false) -- 檔案不存在回 nil（createIfNull＝false）
        if not reader then return end
        local parts, line = {}, reader:readLine()
        while line do
            parts[#parts + 1] = line
            line = reader:readLine()
        end
        reader:close()
        Favorites.list, Favorites.set = Favorites.parse(table.concat(parts, "\n"))
    end)
    loaded = ok
    if not ok then print(LOG .. "favorites load failed: " .. tostring(err)) end
end

-- 回 true＝寫進檔案了
function Favorites.save()
    if not loaded then
        print(LOG .. "favorites not saved: the file could not be read")
        return false
    end
    local ok, err = pcall(function()
        local writer = getFileWriter(Favorites.FILE, true, false)
        if not writer then error("no writer") end
        writer:write(Favorites.serialize(Favorites.list))
        writer:close()
    end)
    if not ok then print(LOG .. "favorites save failed: " .. tostring(err)) end
    return ok
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
