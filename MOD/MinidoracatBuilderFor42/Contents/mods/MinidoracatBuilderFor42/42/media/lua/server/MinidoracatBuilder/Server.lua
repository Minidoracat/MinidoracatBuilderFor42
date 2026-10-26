-- 伺服器（單機在本機跑同一套）：開服建「tiledef 檔號 → MOD」表；建造的權威流程（bt-authority §9、設計稿「伺服器權威」）。
-- 身分只認 OnClientCommand 的連線玩家：客戶端先送 intent（項目、朝向、各項的原點座標），動作只帶 nonce 與第幾項。
-- complete() 不信任動作帶來的參數，只照這位玩家自己的 intent 做，sprite、種類、佔地、成本一律由伺服器重算。
if isClient() then return end
require "MinidoracatBuilder/Sources"
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Cost"
require "MinidoracatBuilder/Place"
require "MinidoracatBuilder/Materials"

local Sources, Entry, Cost = MinidoracatBuilder.Sources, MinidoracatBuilder.Entry, MinidoracatBuilder.Cost
local Place, Materials = MinidoracatBuilder.Place, MinidoracatBuilder.Materials
local Server = MinidoracatBuilder.Server or {}
MinidoracatBuilder.Server = Server

local LOG = "[MinidoracatBuilderFor42] "
local MODULE = "MinidoracatBuilder"
local INTENT_TTL_MS = 60000           -- 每做完一項再延長：拖曳 32 項、每項 4 秒也夠
local RATE_WINDOW_MS, RATE_MAX = 5000, 20 -- 照 VehicleManager 的 intent 限流
local WAKE_MS = 3000                  -- 剛喚醒區域系統的那一帶，第一項至少等這麼久（bt-authority §6.3）
local WAKE_SPAN = 24                  -- 喚醒一次涵蓋周圍 7×7 chunk，約 ±24 格
local INTENT_REACH = 100              -- 錨點離玩家最遠幾格（點畫面遠處再走過去也夠；只為限制喚醒表與亂點的位置）
-- Kahlua 沒有弱表：表裡的 player 物件靠新請求取代，過期的在下一次有人送請求時清掉（sweep）。
Server.intents = {}
local rate, woken, quietUntil = {}, {}, {}

local function now() return getTimestampMs() end
local function keyOf(player)
    if isServer() then return player:getOnlineID() end
    return "sp" .. player:getPlayerNum()
end

-- 帳號名稱可以有空白、控制字元與方括號，印進稽核行前換掉（pitfalls：寫入 username 前清理）
local function who(player)
    return (tostring(player:getUsername()):gsub("[%c%s%[%]]", "_"))
end

-- 伺服器 → 一位玩家。單機沒有通道（sendServerCommand 在單機不送），直接交給客戶端程式。
function Server.send(player, cmd, args)
    if isServer() then
        sendServerCommand(player, MODULE, cmd, args)
    elseif MinidoracatBuilder.Client then
        MinidoracatBuilder.Client.onServerCommand(cmd, args)
    end
end

function Server.refuse(player, n, i, code, extra)
    print(LOG .. "REFUSE user=" .. who(player) .. " n=" .. tostring(n) .. " i=" .. tostring(i) .. " code=" .. code)
    local args = { n = n, i = i, code = code }
    for k, v in pairs(extra or {}) do args[k] = v end
    Server.send(player, "refused", args)
    return false
end

local function setting(name, default)
    local v = Entry.settings()[name]
    if v == nil then return default end
    return v
end

-- 單機的本機玩家就是主機，算管理員；伺服器問連線的角色能力（UseBuildCheat：能開建造作弊的就是建造的管理員）
local function isAdmin(player)
    if not isServer() then return true end
    return Capability ~= nil and checkPermissions(player, Capability.UseBuildCheat) == true
end

-- 誰能用（沙盒 Enabled、WhoCanUse）；回原因碼或 nil
local function notAllowed(player)
    if setting("Enabled", true) == false then return "OFF" end
    if setting("WhoCanUse", 1) == 2 and not isAdmin(player) then return "NOT_ALLOWED" end
    if player:isDead() or player:getVehicle() then return "STATE" end
    return nil
end

local function int(v, lo, hi)
    v = tonumber(v)
    if v and v == math.floor(v) and v >= lo and v <= hi then return v end
    return nil
end

-- 區域系統第一次看到一個 chunk 時會讀周圍 7×7 chunk 的快照，同一批晚到的牆會漏存（pitfalls「伺服器端蓋自建建築，
-- 要先讓區域系統發現那一帶」）。收到請求就對錨點那一帶有地板的一格重推一次，回那一帶的喚醒時間；沒推成（格子沒載入、
-- 沒地板）不記，下次再試。ponytail：表每 24×24 格一筆、不清；只記玩家附近的錨點（intent 先查距離），量跟著蓋過的範圍走。
local function wake(x, y)
    local k = math.floor(x / WAKE_SPAN) .. "," .. math.floor(y / WAKE_SPAN)
    local t = woken[k]
    if t then return t end
    local sq = getCell():getGridSquare(x, y, 0)
    if not (sq and sq:getFloor()) then return 0 end
    IsoRegions.setPreviousFlags(nil)
    IsoRegions.squareChanged(sq)
    t = now()
    woken[k] = t
    return t
end

local function rateOk(k)
    local r, t = rate[k], now()
    if not r or t - r.t0 > RATE_WINDOW_MS then
        rate[k] = { t0 = t, n = 1 }
        return true
    end
    r.n = r.n + 1
    return r.n <= RATE_MAX
end

-- 清掉過期的請求（先收集再刪，不在 pairs 途中改表）
local function sweep(t)
    local old = {}
    for k, it in pairs(Server.intents) do
        if it.exp < t then old[#old + 1] = k end
    end
    for _, k in ipairs(old) do Server.intents[k] = nil end
end

-- 客戶端請求：{ n = nonce, e = 項目 ID, d = 朝向 0..4, c = { x1, y1, z1, x2, ... }（各項原點，攤平）, v = Entry.digest() }
-- 收下回 true；被拒回 false（原因已推給玩家）；洗包回 nil。
function Server.intent(player, args)
    if type(args) ~= "table" then return end
    local n = int(args.n, 1, 2147483647)
    if not n then return end -- 沒有 nonce 就無從回覆
    local k = keyOf(player)
    if not rateOk(k) then return end -- 洗包不回、不記 log
    sweep(now())
    local why = notAllowed(player)
    if why then return Server.refuse(player, n, 0, why) end
    if args.v ~= Entry.digest() then return Server.refuse(player, n, 0, "STALE") end
    local d = int(args.d, 0, 4)
    local c = args.c
    if not d or type(c) ~= "table" then return Server.refuse(player, n, 0, "BAD_REQUEST") end
    local maxItems = setting("MaxCellsPerDrag", 32)
    local near = INTENT_REACH
    local px, py, pz = player:getX(), player:getY(), math.floor(player:getZ())
    local anchors = {}
    for i = 1, maxItems * 3 + 1, 3 do
        if c[i] == nil then break end
        local x, y, z = int(c[i], 0, 1000000), int(c[i + 1], 0, 1000000), int(c[i + 2], -32, 31)
        if not (x and y and z) or #anchors >= maxItems or not getWorld():isValidSquare(x, y, z) then
            return Server.refuse(player, n, 0, "BAD_REQUEST")
        end
        if math.abs(x + 0.5 - px) > near or math.abs(y + 0.5 - py) > near or math.abs(z - pz) > 1 then
            return Server.refuse(player, n, 0, "TOO_FAR", { x = x, y = y, z = z })
        end
        anchors[#anchors + 1] = { x, y, z }
    end
    if #anchors == 0 then return Server.refuse(player, n, 0, "BAD_REQUEST") end
    local entry, code = Entry.resolve(args.e)
    if not entry then return Server.refuse(player, n, 0, code) end
    if not Entry.face(entry, d) then return Server.refuse(player, n, 0, "BAD_FACE") end
    Server.intents[k] = { player = player, n = n, e = entry.name, d = d, c = anchors, done = {}, left = #anchors,
        exp = now() + INTENT_TTL_MS, wake = wake(anchors[1][1], anchors[1][2]) }
    -- 收下才回 accepted，客戶端收到才排動作：請求與動作走不同通道，動作不能比請求先到
    Server.send(player, "accepted", { n = n })
    return true
end

-- 這位玩家（連線對應的角色）、這個 nonce、還沒做過的第 i 項；不符回 nil。過期的順手刪掉。
local function intentFor(player, n, i)
    local k = keyOf(player)
    local it = Server.intents[k]
    if not it then return nil end
    if it.exp < now() then
        Server.intents[k] = nil
        return nil
    end
    if it.n ~= n or it.player ~= player or not it.c[i] or it.done[i] then return nil end
    return it
end

-- 動作的施工時間（伺服器在 serverStart 前問一次；單機在建立動作時就問）。找不到請求回 1，讓它馬上進 complete() 被拒。
-- 剛喚醒區域系統的那一帶，第一項連即時動作也要等滿 WAKE_MS；後面的項目排在第一項之後，不用再等。
function Server.duration(player, n, i)
    local it = intentFor(player, n, i)
    if not it then return 1 end
    local ticks = 1
    if not player:isTimedActionInstant() then
        local entry = Entry.resolve(it.e)
        ticks = Entry.duration(entry and entry.kind, player)
    end
    local waitMs = i == 1 and it.wake + WAKE_MS - now() or 0
    if waitMs > 0 then ticks = math.max(ticks, math.ceil(waitMs / 20)) end -- 伺服器每 tick 20 ms（NetTimedAction.java:77）
    return ticks
end

-- 玩家到佔地最近一格的水平距離（格中心）、樓層差、最近的那一格
local function reach(player, cells)
    local px, py, pz = player:getX(), player:getY(), math.floor(player:getZ())
    local best, dz, near = math.huge, math.huge, nil
    for _, c in ipairs(cells) do
        local dx, dy = c.x + 0.5 - px, c.y + 0.5 - py
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist < best then best, dz, near = dist, math.abs(c.z - pz), c end
    end
    return best, dz, near
end

-- 同一層：玩家走得到最近那一格嗎。在兩格圍成的範圍外加一圈裡，沿 canReachTo 找路：牆（含透明牆）、關著的門窗都擋
-- （IsoGridSquare.java:939-961；照 pitfalls「伺服器驗證要查可及性」）。格邊種類從哪一側都能蓋，不查。
-- ponytail：範圍最大約 (2×MaxDistance＋3)² 格，只在 complete() 跑一次。
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

-- 安全屋：原版（照名字，conventions 殘餘風險）＋ Safehouse 的 v1.denies（細分權限，拒絕時它自己推通知）
local function safehouseCode(player, c)
    if not (isServer() and checkPermissions(player, Capability.CanGoInsideSafehouses) == true)
        and SafeHouse.isSafeHouse(c.sq, player:getUsername(), true) ~= nil then
        return "SAFEHOUSE"
    end
    local api = MinidoracatSafehouse and MinidoracatSafehouse.v1
    if api and api.API_MAJOR == 1 and type(api.CAPABILITIES) == "table" and api.CAPABILITIES.denies == true
        and api.denies(player, c.x, c.y, c.z, api.BITS.BUILD, { label = "MinidoracatBuilder:build" }) then
        return "PERM_DENIED"
    end
    if setting("WhereCanBuild", 1) == 2 and SafeHouse.getSafeHouse(c.sq) == nil then return "OUTSIDE_SAFEHOUSE" end
    return nil
end

local function costLine(items)
    local parts = {}
    for ft, n in pairs(items) do parts[#parts + 1] = ft .. "x" .. n end
    return table.concat(parts, ",")
end

-- MinidoracatBuilderPlaceAction:complete()。回 true＝放好；false＝MP 客戶端收到 Reject 並清掉後面的動作，原因另外推
-- （單機不看回傳值，由 Client 收到 refused 時清佇列）。
-- 順序：身分 → 目錄重算 → 距離（座標）→ 補格子 → 安全屋 → 可放置 → 材料規劃 → 放置 → 扣料 → 收尾（bt-authority §9）。
function Server.complete(player, n, i)
    local it = intentFor(player, n, i)
    if not it then
        -- 沒有對應請求的動作只記 log（每人每 5 秒最多一行，動作封包可以一直送），MP 不回覆；
        -- 單機是本機玩家自己的佇列（例：請求放太久過期），回 refused 讓客戶端清掉後面的動作
        local k, t = keyOf(player), now()
        if not isServer() then return Server.refuse(player, n, i, "NO_INTENT") end
        if (quietUntil[k] or 0) <= t then
            quietUntil[k] = t + RATE_WINDOW_MS
            print(LOG .. "REFUSE user=" .. who(player) .. " n=" .. tostring(n) .. " code=NO_INTENT")
        end
        return false
    end
    local why = notAllowed(player)
    if why then return Server.refuse(player, n, i, why) end
    local entry, code = Entry.resolve(it.e) -- 設定可能在施工途中被改
    if not entry then return Server.refuse(player, n, i, code) end
    local spr = Entry.face(entry, it.d)
    if not spr then return Server.refuse(player, n, i, "BAD_FACE") end
    local a = it.c[i]
    local cells, sprites = {}, {}
    for j, d in ipairs(Entry.cells(spr)) do
        cells[j] = { x = a[1] + d[1], y = a[2] + d[2], z = a[3] + d[3], spr = d[4] }
        sprites[j] = d[4]
    end
    -- 先用座標驗距離，通過才補格子（補格子會改世界）
    local dist, dz, nearest = reach(player, cells)
    if dist > setting("MaxDistance", 3) or dz > 1 then
        return Server.refuse(player, n, i, "TOO_FAR", { x = a[1], y = a[2], z = a[3] })
    end
    if not Entry.EDGE[entry.kind] and not reachable(player, nearest) then
        return Server.refuse(player, n, i, "UNREACHABLE", { x = nearest.x, y = nearest.y, z = nearest.z })
    end
    for _, c in ipairs(cells) do
        c.sq = Place.square(c.x, c.y, c.z)
        if not c.sq then return Server.refuse(player, n, i, "NOT_LOADED", { x = c.x, y = c.y, z = c.z }) end
    end
    for _, c in ipairs(cells) do
        local sh = safehouseCode(player, c)
        if sh then return Server.refuse(player, n, i, sh, { x = c.x, y = c.y, z = c.z }) end
    end
    for j, c in ipairs(cells) do
        local ok, fine, yoff = pcall(Place.check, entry.kind, c.spr, c.sq, player)
        if not ok then
            print(LOG .. "check failed e=" .. it.e .. ": " .. tostring(fine))
            return Server.refuse(player, n, i, "INTERNAL")
        end
        if not fine then return Server.refuse(player, n, i, "BLOCKED", { x = c.x, y = c.y, z = c.z }) end
        c.yoff = yoff
        for k2 = j + 1, #cells do -- 多格之間不能隔著牆（ISMoveableSpriteProps.lua:1616-1716 的 isWallBetweenParts）
            local o = cells[k2]
            if o.z == c.z and math.abs(o.x - c.x) + math.abs(o.y - c.y) == 1 and c.sq:isSomethingTo(o.sq) then
                return Server.refuse(player, n, i, "BLOCKED", { x = o.x, y = o.y, z = o.z })
            end
        end
    end
    local costs = Cost.forCells(entry.kind, sprites, setting("CostMultiplier", 1))
    for j, c in ipairs(cells) do c.cost = costs[j] end
    local total = Cost.sum(costs)
    local plan
    if not player:isBuildCheat() then -- 伺服器上的這個旗標只有有 UseBuildCheat 能力的人開得了（ExtraInfoPacket.java:274-277）
        local missing, tools
        plan, missing, tools = Materials.plan(player, total)
        if not plan then
            return Server.refuse(player, n, i, missing and "NO_MATERIAL" or "NO_TOOL", { need = missing, tools = tools })
        end
    end
    local placed = {}
    local ok, err = pcall(Place.build, entry.kind, cells, placed)
    if not ok then
        Place.undo(placed)
        print(LOG .. "build failed e=" .. it.e .. ": " .. tostring(err))
        return Server.refuse(player, n, i, "INTERNAL")
    end
    if plan then Materials.consume(player, plan) end
    Place.settle(cells)
    print(LOG .. "BUILD user=" .. who(player) .. " id=" .. tostring(player:getOnlineID())
        .. " e=" .. spr:getName() .. " kind=" .. entry.kind .. " at=" .. a[1] .. "," .. a[2] .. "," .. a[3]
        .. " cost=" .. (plan and costLine(total.items) or "free"))
    it.done[i] = true
    it.left = it.left - 1
    it.exp = now() + INTENT_TTL_MS
    if it.left <= 0 then Server.intents[keyOf(player)] = nil end
    Server.send(player, "placed", { n = n, i = i })
    return true
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module == MODULE and command == "intent" and player then Server.intent(player, args) end
end)

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

return Server
