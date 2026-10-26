-- 圖塊來源：sprite ID → tiledef 檔號 → MOD ID。兩端共用。
-- Lua 讀不到 TileDef 的欄位（只有公開欄位、沒有 getter），所以檔號由 sprite ID 反算，
-- 檔號對 MOD 讀各 MOD 的 mod.info（bt-perf §7.2）。
MinidoracatBuilder = MinidoracatBuilder or {}
local Sources = MinidoracatBuilder.Sources or {}
MinidoracatBuilder.Sources = Sources

-- IsoWorld.getSpriteID（IsoWorld.java:632-634）的反算：檔號 1 用 1024×1024 格，其餘每檔 262144 格、從 1048576 起
function Sources.fileOf(id)
    if id < 1048576 then return 1 end
    return math.floor((id - 1048576) / 262144) + 2
end

-- MOD 的 tiledef 檔號限 100–8189（ChooseGameInfo.java:309-314），原版是 1、2、4–8
function Sources.isModFile(file)
    return file >= 100
end

-- 回 { [檔號] = MOD ID }。照引擎載入順序（getActivatedMods，ZomboidFileSystem.loadModTileDefs）
-- 同一檔號先載入的 MOD 贏，後面的整份略過。只讀有 tiledef 的 MOD。
function Sources.build()
    local byFile = {}
    local mods = getActivatedMods()
    for i = 0, mods:size() - 1 do
        local id = mods:get(i)
        local info = getModInfoByID(id)
        local defs = info and info:getTileDefs()
        if defs and defs:size() > 0 then
            local reader = getModFileReader(id, "mod.info", false)
            if reader then
                local line = reader:readLine()
                while line do
                    -- ChooseGameInfo.java:292-316：含 tiledef= 的行，去掉後剩「名稱 檔號」
                    if line:find("tiledef=", 1, true) then
                        local num = tonumber(line:match("tiledef=%s*%S+%s+(%d+)%s*$"))
                        if num and not byFile[num] then byFile[num] = id end
                    end
                    line = reader:readLine()
                end
                reader:close()
            end
        end
    end
    return byFile
end

-- 目前的檔號表；還沒建就建一次（伺服器在 OnServerStarted 建好，單機由目錄第二段建，請求可能比它早到）
function Sources.map()
    if not Sources.byFile then Sources.byFile = Sources.build() end
    return Sources.byFile
end

-- 依檔號由小到大印出（不用 table.sort：檔號上限 8189，直接掃一遍）
function Sources.describe(byFile)
    local parts = {}
    for file = 100, 8189 do
        if byFile[file] then parts[#parts + 1] = file .. "=" .. byFile[file] end
    end
    return table.concat(parts, " ")
end

return Sources
