-- 最近用的：存 Zomboid/Lua/MinidoracatBuilder/recent.txt，一行一個項目 ID、新的在前、最多 Recent.MAX 項，最後一行是結尾記號
-- （格式同 favorites.txt：Favorites.parse／serialize）。引擎會吞掉讀寫錯誤（見 Favorites.lua 檔頭），所以讀要看到結尾記號
-- 才採用；和最愛不同，讀不完整時照樣寫：這裡只是歷史，每次建造都寫，寫回眼前這份比讓壞檔一直留著（之後永遠存不了）好。
MinidoracatBuilder = MinidoracatBuilder or {}
require "MinidoracatBuilder/Favorites"
local B = MinidoracatBuilder
local Recent = B.Recent or {}
B.Recent = Recent

local LOG = "[MinidoracatBuilderFor42] "
Recent.FILE = "MinidoracatBuilder/recent.txt"
Recent.MAX = 30
local END = "#end" -- 同 Favorites 的結尾記號

local list, loaded, warned = { n = 0 }, false, false

local function readLines()
    local reader = getFileReader(Recent.FILE, false)
    if not reader then return nil end
    local lines, line = {}, reader:readLine()
    while line do
        lines[#lines + 1] = line
        line = reader:readLine()
    end
    reader:close()
    return lines
end

-- 重新讀檔；沒有檔、打不開、沒讀完整都當空清單
function Recent.load()
    loaded, list = true, { n = 0 }
    local ok, lines = pcall(readLines)
    if not (ok and lines and lines[#lines] == END) then return end
    local parsed = B.Favorites.parse(table.concat(lines, "\n"))
    for i = 1, math.min(parsed.n, Recent.MAX) do
        list[i] = parsed[i]
        list.n = i
    end
end

-- { n, 名稱… }，新的在前；第一次用到才讀檔。回傳的表唯讀（Recent.add 換新表，不改舊的）
function Recent.list()
    if not loaded then Recent.load() end
    return list
end

-- 搬到最前面（已經在清單裡就從原位置拿掉），超過上限的丟掉，馬上寫檔
function Recent.add(name)
    local old = Recent.list()
    local new = { n = 1, name }
    for i = 1, old.n do
        if old[i] ~= name and new.n < Recent.MAX then
            new.n = new.n + 1
            new[new.n] = old[i]
        end
    end
    list = new
    local text = B.Favorites.serialize(new)
    local ok = pcall(function()
        local w = getFileWriter(Recent.FILE, true, false)
        if not w then error("no writer") end
        w:write(text)
        w:close()
    end)
    if not ok and not warned then
        warned = true -- 每次建造都寫：只記第一次失敗
        print(LOG .. "recent list not saved")
    end
end

return Recent
