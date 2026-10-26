-- 目錄分批整理（client）：進遊戲後才開始，不卡載入也不卡畫面（設計稿 1.1；bt-perf §10、§11）。
-- OnGameStart 只複製清單、掛事件（它是同步的，跑多久第一幀就晚多久）；之後每 tick 用時間預算分批：
--   第一段：namedMap 每個 sprite → 過濾 → Rules.classify → Index.add
--   第二段：讀 tiledef 來源表，再建搜尋鍵（有名稱的項目＋tileset）
-- 做完自己摘掉 tick 事件。每 tick 整段 pcall：出錯就停止並記 log，不會每 tick 重丟。
require "MinidoracatBuilder/Rules"
require "MinidoracatBuilder/Sources"
require "MinidoracatBuilder/Index"

MinidoracatBuilder = MinidoracatBuilder or {}
local Catalog = MinidoracatBuilder.Catalog or {}
MinidoracatBuilder.Catalog = Catalog
local Rules, Sources, Index = MinidoracatBuilder.Rules, MinidoracatBuilder.Sources, MinidoracatBuilder.Index

local LOG = "[MinidoracatBuilderFor42] "
-- 校準旋鈕：每 tick 最多 BUDGET_MS 毫秒、每 CHECK_EVERY 格看一次時鐘、每 tick 最多 CAP 格（牆鐘往回調也有上限）
local BUDGET_MS, CHECK_EVERY, CAP = 2, 64, 4096
local NO_TILE_ID = 20000000 -- 非 tiledef sprite（UI 貼圖等）的預設 id（IsoSprite.java:129-130）

Catalog.state = "idle" -- idle／running／ready／failed
local job, tickFn

local function now()
    return getTimestampMs()
end

-- 每次 Java 呼叫在遊戲裡約 0.45–0.58 µs（catalog-sp bench），單價主要看呼叫次數。
local function scanSprite(spr, named)
    -- 約四成的 tiledef 格沒有圖：先濾掉，省一次 getID。
    -- 名稱 "" 的空 sprite id 是 −1（IsoSpriteManager.java:16-24）；原版第一格 id 是 0，所以不能寫 id > 0
    if spr:hasNoTextures() then return end
    local id = spr:getID()
    if id < 0 or id == NO_TILE_ID then return end
    local name, p = spr:getName(), spr:getProperties()
    local kind = Rules.kindOf(name, p, spr:getType())
    if not kind then return end
    local key, raw
    if kind == "stairs" then
        if not Rules.stairsSet(named, name) then return end -- 只收湊得成三格的 B 片
    else
        local grid = spr:getSpriteGrid()
        if grid and grid:getAnchorSprite() ~= spr then return end -- 多格只收原點
        local custom = p:get("CustomName")
        if custom then
            local group = p:get("GroupName")
            raw = group and (group .. " " .. custom) or custom
            key = (group or "") .. "|" .. custom
        end
    end
    local tileset, num = name:match("^(.*)_(%d+)$") -- 比 find＋sub 快（bench：1.4 對 2.0 µs）
    if not tileset then return end
    Index.add(kind, name, tileset, tonumber(num), Sources.fileOf(id), key and (tileset .. "|" .. key), raw)
end

local function runSprites(budget)
    local list, named, i = job.list, job.named, job.i
    local stop = math.min(job.n, i + CAP)
    local t0 = now()
    while i < stop do
        local spr = list:get(i)
        i = i + 1
        scanSprite(spr, named)
        if budget and i % CHECK_EVERY == 0 then
            local t = now()
            if t - t0 >= budget or t < t0 then break end
        end
    end
    job.i = i
    return i >= job.n
end

local function modNameOf(file)
    if not file or not Sources.isModFile(file) then return "" end
    local id = Sources.byFile[file]
    if not id then return "" end
    local name = job.modNames[id]
    if not name then
        local info = getModInfoByID(id)
        name = info and info:getName() or id
        job.modNames[id] = name
    end
    return name
end

local function runKeys(budget)
    local groups, sets = Index.groupList, Index.setName
    local total = groups.n + sets.n
    local j = job.j
    local stop = math.min(total, j + CAP)
    local t0 = now()
    while j < stop do
        j = j + 1
        if j <= groups.n then
            Index.addNameKey(groups[j])
        else
            local k = j - groups.n
            Index.addSetKey(k, modNameOf(Index.setFile[sets[k]]))
        end
        if budget and j % CHECK_EVERY == 0 then
            local t = now()
            if t - t0 >= budget or t < t0 then break end
        end
    end
    job.j = j
    return j >= total
end

-- 回 true＝這段做完了
local function work(budget)
    if job.stage == 1 then
        if runSprites(budget) then job.stage = 2 end
        return false
    end
    if not Sources.byFile then
        -- 讀約十幾個 mod.info：單獨占一個 tick
        local t = now()
        Sources.byFile = Sources.build()
        job.sourceMs = now() - t
        return false
    end
    return runKeys(budget)
end

local function finish(state)
    if tickFn then
        Events.OnTickEvenPaused.Remove(tickFn)
        tickFn = nil
    end
    local j = job
    job = nil
    Index.finish()
    Catalog.state = state
    -- 毫秒時鐘的累計只當 log 參考；成本以 GameProfiler 為準（bt-perf §1.5）
    Catalog.stats = { sprites = j.n, items = Index.items, named = Index.nameKey.n, tilesets = Index.setName.n,
        ticks = j.ticks, busyMs = j.busy, maxMs = j.maxMs, wallMs = now() - j.t0, sourceMs = j.sourceMs }
    local s = Catalog.stats
    print(LOG .. "catalog " .. state .. ": " .. s.items .. " items from " .. s.sprites .. " sprites, "
        .. s.named .. " named, " .. s.tilesets .. " tilesets; busy " .. s.busyMs .. " ms over " .. s.ticks
        .. " ticks (max " .. s.maxMs .. " ms/tick), wall " .. s.wallMs .. " ms")
end

-- 每 tick 呼叫一次；budget＝nil 時每次做到 CAP 為止（離線測試）。回 true＝已結束。
function Catalog.step(budget)
    if not job then return true end
    local t0 = now()
    local ok, result = pcall(work, budget)
    local spent = now() - t0
    job.ticks = job.ticks + 1
    job.busy = job.busy + spent
    if spent > job.maxMs then job.maxMs = spent end
    if not ok then
        print(LOG .. "catalog stopped by error: " .. tostring(result))
        finish("failed")
        return true
    end
    if result then
        finish("ready")
        return true
    end
    return false
end

-- 整理進度（第一段）：已看過的 sprite 數、總數；不在整理中回 nil
function Catalog.progress()
    if job then return job.i, job.n end
    return nil
end

function Catalog.start()
    if job or Catalog.state == "ready" then return end
    local named = IsoSpriteManager.instance:getNamedMap()
    -- HashMap.values() 的類別沒公開，丟進公開的 ArrayList 建構子；也避免之後 getSprite 新增項目時迭代器失效
    local list = ArrayList.new(named:values())
    Index.reset()
    Sources.byFile = nil
    job = { stage = 1, list = list, named = named, i = 0, n = list:size(), j = 0, modNames = {},
        t0 = now(), ticks = 0, busy = 0, maxMs = 0 }
    Catalog.state = "running"
    -- 經模組表呼叫 step：E2E 量測可以換成包一層自訂事件的版本
    tickFn = function() Catalog.step(BUDGET_MS) end
    Events.OnTickEvenPaused.Add(tickFn)
end

Events.OnGameStart.Add(Catalog.start)

return Catalog
