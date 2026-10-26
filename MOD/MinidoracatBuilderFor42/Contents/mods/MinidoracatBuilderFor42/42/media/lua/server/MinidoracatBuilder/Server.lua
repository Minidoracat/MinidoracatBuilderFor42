-- 伺服器：開服只建「tiledef 檔號 → MOD」表，不建目錄、不列舉 namedMap（bt-perf §7.3）。
-- 收到建造請求才分類那一個圖塊（之後的權威放置階段）。
if isClient() then return end
require "MinidoracatBuilder/Sources"

local Sources = MinidoracatBuilder.Sources
local LOG = "[MinidoracatBuilderFor42] "

Events.OnServerStarted.Add(function()
    local t0 = getTimestampMs()
    local ok, byFile = pcall(Sources.build)
    if not ok then
        print(LOG .. "tiledef sources failed: " .. tostring(byFile))
        return
    end
    Sources.byFile = byFile
    local n = 0
    for _ in pairs(byFile) do n = n + 1 end
    print(LOG .. "tiledef sources: " .. n .. " files in " .. (getTimestampMs() - t0) .. " ms: "
        .. Sources.describe(byFile))
end)
