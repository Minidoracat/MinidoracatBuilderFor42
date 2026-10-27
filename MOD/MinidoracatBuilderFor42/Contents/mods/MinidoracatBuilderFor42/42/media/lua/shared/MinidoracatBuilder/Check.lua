-- 一項能不能蓋：伺服器 complete() 與客戶端預覽共用同一份判斷（從 Server.complete 抽出）。
-- 伺服器：照 bt-authority §9 的順序（目錄重算 → 距離（座標）→ 補格子 → 安全屋 → 可放置），通過後材料、放置、扣料、
-- 經驗仍在 Server.complete。客戶端 preview：不補格子、不寫任何東西，格子不存在就略過要格子的檢查（交給伺服器），
-- 材料用 Materials.summary 的摘要估。客戶端的結果只給畫面看，伺服器照樣每格重算。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Cost"
require "MinidoracatBuilder/Place"
require "MinidoracatBuilder/Materials"

MinidoracatBuilder = MinidoracatBuilder or {}
local Check = MinidoracatBuilder.Check or {}
MinidoracatBuilder.Check = Check
local Entry, Cost = MinidoracatBuilder.Entry, MinidoracatBuilder.Cost
local Place, Materials = MinidoracatBuilder.Place, MinidoracatBuilder.Materials

local LOG = "[MinidoracatBuilderFor42] "
-- Safehouse 的 denies 選項：伺服器照常寫稽核、推通知；預覽只判定（docs/public-api.md「opts 的欄位」）
local DENY_SERVER = { label = "MinidoracatBuilder:build" }
local DENY_PREVIEW = { label = "MinidoracatBuilder:build", preview = true }
-- 請求的錨點離玩家最遠幾格（點畫面遠處再走過去也夠；只為限制喚醒表與亂點的位置）。Server.intent 與游標預覽共用
Check.INTENT_REACH = 100

-- 沙盒值，沒設時用 default
function Check.setting(name, default)
    local v = Entry.settings()[name]
    if v == nil then return default end
    return v
end
local setting = Check.setting

-- 玩家到佔地最近一格的水平距離（格中心）、樓層差、最近的那一格。樓梯的平台不算（在上一層，靠近它不等於靠近樓梯）。
local function reach(player, cells)
    local px, py, pz = player:getX(), player:getY(), math.floor(player:getZ())
    local best, dz, near = math.huge, math.huge, nil
    for _, c in ipairs(cells) do
        local dx, dy = c.x + 0.5 - px, c.y + 0.5 - py
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist < best and c.role ~= "platform" then best, dz, near = dist, math.abs(c.z - pz), c end
    end
    return best, dz, near
end

-- 同一層：玩家走得到最近那一格嗎。在兩格圍成的範圍外加一圈裡，沿 canReachTo 找路：牆（含透明牆）、關著的門窗都擋
-- （IsoGridSquare.java:939-961；照 pitfalls「伺服器驗證要查可及性」）。格邊種類從哪一側都能蓋，不查。
-- 只讀已有的格子（getGridSquare 不建格子）。ponytail：範圍最大約 (2×MaxDistance＋3)² 格，每次判斷跑一次。
local function reachable(player, c)
    local pz = math.floor(player:getZ())
    if c.z ~= pz then return true end -- 上下樓層另由樓層差限制
    local px, py = math.floor(player:getX()), math.floor(player:getY())
    local cell = getCell()
    local start = cell:getGridSquare(px, py, pz)
    if not start then return false end
    local x0, x1 = math.min(px, c.x) - 1, math.max(px, c.x) + 1
    local y0, y1 = math.min(py, c.y) - 1, math.max(py, c.y) + 1
    local seen, queue, head = { [px .. "," .. py] = true }, { start }, 1
    while queue[head] do
        local sq = queue[head]
        head = head + 1
        local x, y = sq:getX(), sq:getY()
        if x == c.x and y == c.y then return true end
        for dy = -1, 1 do
            for dx = -1, 1 do
                local nx, ny = x + dx, y + dy
                local k = nx .. "," .. ny
                if not seen[k] and nx >= x0 and nx <= x1 and ny >= y0 and ny <= y1 then
                    local nsq = cell:getGridSquare(nx, ny, pz)
                    if nsq and sq:canReachTo(nsq) then
                        seen[k] = true
                        queue[#queue + 1] = nsq
                    end
                end
            end
        end
    end
    return false
end

-- 安全屋：原版（照名字，conventions 殘餘風險）＋ Safehouse 的 v1.denies（細分權限，伺服器拒絕時它自己推通知）。
-- 預覽時格子可能不存在：要格子的原版查詢略過（交給伺服器），denies 照座標查（格子不必存在）。
-- checkPermissions 只在伺服器回 true（LuaManager.java:3054-3057），所以客戶端預覽對能進別人安全屋的管理員會偏嚴。
local function safehouseCode(player, c, preview)
    if c.sq and not (isServer() and checkPermissions(player, Capability.CanGoInsideSafehouses) == true)
        and SafeHouse.isSafeHouse(c.sq, player:getUsername(), true) ~= nil then
        return "SAFEHOUSE"
    end
    local api = MinidoracatSafehouse and MinidoracatSafehouse.v1
    if api and api.API_MAJOR == 1 and type(api.CAPABILITIES) == "table" and api.CAPABILITIES.denies == true
        and api.denies(player, c.x, c.y, c.z, api.BITS.BUILD, preview and DENY_PREVIEW or DENY_SERVER) then
        return "PERM_DENIED"
    end
    if c.sq and setting("WhereCanBuild", 1) == 2 and SafeHouse.getSafeHouse(c.sq) == nil then return "OUTSIDE_SAFEHOUSE" end
    return nil
end

-- 蓋 name（項目 ID）朝向 d、原點 anchor＝{ x, y, z }。回 code, extra, info：
--   code＝nil 通過；否則伺服器的拒絕碼。extra＝拒絕附帶的欄位（x, y, z／need, tools）。
--   info＝{ entry, spr, cells = { { x, y, z, spr, sq, yoff, cost }, ... }, sprites, costs, total }，算到哪填到哪。
-- opts.preview：客戶端預覽（見檔頭）；opts.summary＝Materials.summary 的結果，有才查材料（建造作弊不查，照伺服器）。
-- opts.walk（配 preview）：游標預覽，Client.build 會先走到旁邊再蓋，所以距離只照 Server.intent 收請求的規則
-- （錨點離玩家水平各軸 ≤ INTENT_REACH、樓層差 ≤ 1），不看 MaxDistance、不查走不走得到（伺服器 complete 時照樣查）。
-- 伺服器（opts 為 nil）不查材料：Server.complete 自己 plan。
function Check.item(player, name, d, anchor, opts)
    local preview = opts ~= nil and opts.preview == true
    local walk = preview and opts.walk == true
    local info = {}
    local entry, code = Entry.resolve(name) -- 設定可能在施工途中被改
    if not entry then return code, nil, info end
    info.entry = entry
    local spr = Entry.face(entry, d)
    if not spr then return "BAD_FACE", nil, info end
    info.spr = spr
    local cells, sprites = {}, {}
    for j, o in ipairs(Entry.cells(spr)) do
        cells[j] = { x = anchor[1] + o[1], y = anchor[2] + o[2], z = anchor[3] + o[3], spr = o[4], role = o[5] }
        sprites[j] = o[4]
    end
    info.cells, info.sprites = cells, sprites
    -- 先用座標驗距離，通過才補格子（補格子會改世界）
    if walk then
        local px, py, pz = player:getX(), player:getY(), math.floor(player:getZ())
        local near = Check.INTENT_REACH
        if math.abs(anchor[1] + 0.5 - px) > near or math.abs(anchor[2] + 0.5 - py) > near or math.abs(anchor[3] - pz) > 1 then
            return "TOO_FAR", { x = anchor[1], y = anchor[2], z = anchor[3] }, info
        end
    else
        local dist, dz, nearest = reach(player, cells)
        if dist > setting("MaxDistance", 3) or dz > 1 then
            return "TOO_FAR", { x = anchor[1], y = anchor[2], z = anchor[3] }, info
        end
        -- 預覽：最近那一格還沒有格子時不判斷（伺服器會補格子再查）
        if not Entry.EDGE[entry.kind]
            and not (preview and not getCell():getGridSquare(nearest.x, nearest.y, nearest.z))
            and not reachable(player, nearest) then
            return "UNREACHABLE", { x = nearest.x, y = nearest.y, z = nearest.z }, info
        end
    end
    local cell = getCell()
    for _, c in ipairs(cells) do
        if preview then
            c.sq = cell:getGridSquare(c.x, c.y, c.z)
        else
            c.sq = Place.square(c.x, c.y, c.z)
            if not c.sq then return "NOT_LOADED", { x = c.x, y = c.y, z = c.z }, info end
        end
    end
    for _, c in ipairs(cells) do
        local sh = safehouseCode(player, c, preview)
        if sh then return sh, { x = c.x, y = c.y, z = c.z }, info end
    end
    for j, c in ipairs(cells) do
        if c.sq then
            local ok, fine, yoff = pcall(Place.check, entry.kind, c.spr, c.sq, player, c.role)
            if not ok then
                print(LOG .. "check failed e=" .. name .. ": " .. tostring(fine))
                return "INTERNAL", nil, info
            end
            if not fine then return "BLOCKED", { x = c.x, y = c.y, z = c.z }, info end
            c.yoff = yoff
            for k2 = j + 1, #cells do -- 多格之間不能隔著牆（ISMoveableSpriteProps.lua:1616-1716 的 isWallBetweenParts）
                local o = cells[k2]
                if o.sq and o.z == c.z and math.abs(o.x - c.x) + math.abs(o.y - c.y) == 1 and c.sq:isSomethingTo(o.sq) then
                    return "BLOCKED", { x = o.x, y = o.y, z = o.z }, info
                end
            end
        elseif entry.kind == "roof" and not Place.roofAt(c.x, c.y, c.z) then
            -- 預覽：上一層的格子常常還沒建，屋頂照座標查撐不撐得住（伺服器補了格子照樣走上面那段）
            return "BLOCKED", { x = c.x, y = c.y, z = c.z }, info
        end
    end
    local costs = Cost.forCells(entry.kind, sprites, setting("CostMultiplier", 1))
    for j, c in ipairs(cells) do c.cost = costs[j] end
    local total = Cost.sum(costs)
    info.costs, info.total = costs, total
    local S = preview and opts.summary
    if S and not S.cheat then
        local missing, tools = Materials.short(S, total)
        if missing or tools then
            return missing and "NO_MATERIAL" or "NO_TOOL", { need = missing, tools = tools }, info
        end
    end
    return nil, nil, info
end

-- 只看材料與工具（目錄變暗、「只看能蓋的」用）：朝向 0、全部格子。S＝Materials.summary 的結果；
-- multiplier 省略時用沙盒 CostMultiplier。回 missing, tools, total（同 Materials.short；建造作弊時都夠）。
-- 項目解析不了（不存在、不能蓋、被管理員關掉）回 nil, nil, nil：total 是 nil 就是不能蓋，不是夠料。
function Check.affordable(S, name, multiplier)
    local entry = Entry.resolve(name)
    if not entry then return nil, nil, nil end
    local sprites = {}
    for j, o in ipairs(Entry.cells(entry.spr)) do sprites[j] = o[4] end
    local total = Cost.sum(Cost.forCells(entry.kind, sprites, multiplier or setting("CostMultiplier", 1)))
    if S.cheat then return nil, nil, total end
    local missing, tools = Materials.short(S, total)
    return missing, tools, total
end

return Check
