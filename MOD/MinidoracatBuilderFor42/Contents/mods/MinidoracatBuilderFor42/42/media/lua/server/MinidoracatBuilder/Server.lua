-- 伺服器（單機在本機跑同一套）：開服建「tiledef 檔號 → MOD」表；建造的權威流程（bt-authority §9、設計稿「伺服器權威」）。
-- MP 的 timed action 只在伺服器跑 complete()，而且照客戶端送來的 new() 參數重建，連 character 都由客戶端指定
-- （NetTimedAction.java:141-170）。所以身分從 OnClientCommand 取（伺服器依連線反查）：客戶端先送 intent
-- （項目、朝向、各項的原點座標），動作只帶 nonce 與第幾項；complete() 只照 intent 做，sprite 一律由伺服器重算。
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
-- Kahlua 沒有弱表，表裡的 player 物件靠新請求取代或過期清掉（pitfalls：Kahlua 沒有弱表）。
Server.intents = {}
local rate, woken, quietUntil = {}, {}, {}

local function now() return getTimestampMs() end
local function keyOf(player)
    if isServer() then return player:getOnlineID() end
    return "sp" .. player:getPlayerNum()
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
    print(LOG .. "REFUSE user=" .. tostring(player:getUsername()) .. " n=" .. tostring(n) .. " i=" .. tostring(i)
        .. " code=" .. code)
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
-- 要先讓區域系統發現那一帶」）。收到請求就先對錨點那一帶有地板的一格重推一次，回那一帶的喚醒時間。
-- ponytail：表只會長（每 24×24 格一筆）；玩家只能在自己附近蓋，量不大。
local function wake(x, y)
    local k = math.floor(x / WAKE_SPAN) .. "," .. math.floor(y / WAKE_SPAN)
    local t = woken[k]
    if t then return t end
    local sq = getCell():getGridSquare(x, y, 0)
    if sq and sq:getFloor() then
        IsoRegions.setPreviousFlags(nil)
        IsoRegions.squareChanged(sq)
    end
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

-- 客戶端請求：{ n = nonce, e = 項目 ID, d = 朝向 0..4, c = { x1, y1, z1, x2, ... }（各項原點，攤平）, v = Entry.digest() }
function Server.intent(player, args)
    if type(args) ~= "table" then return end
    local n = int(args.n, 1, 2147483647)
    if not n then return end -- 沒有 nonce 就無從回覆
    local k = keyOf(player)
    if not rateOk(k) then return end -- 洗包不回、不記 log
    local why = notAllowed(player)
    if why then return Server.refuse(player, n, 0, why) end
    if args.v ~= Entry.digest() then return Server.refuse(player, n, 0, "STALE") end
    local d = int(args.d, 0, 4)
    local c = args.c
    if not d or type(c) ~= "table" then return Server.refuse(player, n, 0, "BAD_REQUEST") end
    local maxItems = setting("MaxCellsPerDrag", 32)
    local anchors = {}
    for i = 1, maxItems * 3 + 1, 3 do
        if c[i] == nil then break end
        local x, y, z = int(c[i], 0, 1000000), int(c[i + 1], 0, 1000000), int(c[i + 2], -32, 31)
        if not (x and y and z) or #anchors >= maxItems or not getWorld():isValidSquare(x, y, z) then
            return Server.refuse(player, n, 0, "BAD_REQUEST")
        end
        anchors[#anchors + 1] = { x, y, z }
    end
    if #anchors == 0 then return Server.refuse(player, n, 0, "BAD_REQUEST") end
    local entry, code = Entry.resolve(args.e)
    if not entry then return Server.refuse(player, n, 0, code) end
    if not Entry.face(entry, d) then return Server.refuse(player, n, 0, "BAD_FACE") end
    Server.intents[k] = { player = player, n = n, e = entry.name, d = d, c = anchors, done = {}, left = #anchors,
        exp = now() + INTENT_TTL_MS, wake = wake(anchors[1][1], anchors[1][2]) }
end

-- 這位玩家、這個 nonce、還沒做過的第 i 項；不符回 nil。比對 player 物件：偽造的 character 指向別人時，
-- 那個人的請求裡不會有這個 nonce（bt-authority §1.4）。
local function intentFor(player, n, i)
    local it = Server.intents[keyOf(player)]
    if not it or it.n ~= n or it.player ~= player or it.exp < now() or not it.c[i] or it.done[i] then return nil end
    return it
end

-- 動作的施工時間（伺服器在 serverStart 前問一次）。找不到請求回 1，讓它馬上進 complete() 被拒。
function Server.duration(player, n, i)
    local it = intentFor(player, n, i)
    if not it then return 1 end
    if player:isTimedActionInstant() then return 1 end
    local entry = Entry.resolve(it.e)
    local ticks = Entry.duration(entry and entry.kind, player)
    local waitMs = it.wake + WAKE_MS - now()
    if waitMs > 0 then ticks = math.max(ticks, math.ceil(waitMs / 20)) end -- 伺服器每 tick 20 ms（NetTimedAction.java:77）
    return ticks
end

-- 玩家到佔地最近一格的水平距離（格中心），與樓層差
local function reach(player, cells)
    local px, py, pz = player:getX(), player:getY(), math.floor(player:getZ())
    local best, dz = math.huge, math.huge
    for _, c in ipairs(cells) do
        local dx, dy = c.x + 0.5 - px, c.y + 0.5 - py
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist < best then best, dz = dist, math.abs(c.z - pz) end
    end
    return best, dz
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

-- MinidoracatBuilderPlaceAction:complete()。回 true＝放好；false＝客戶端收到 Reject 並清掉後面的動作，原因另外推。
-- 順序：身分 → 目錄重算 → 補格子 → 距離 → 安全屋 → 可放置 → 材料規劃 → 放置 → 扣料 → 收尾（bt-authority §9）。
function Server.complete(player, n, i)
    local it = intentFor(player, n, i)
    if not it then
        -- 不推給 player：偽造時它是別人，推了等於讓人灌別人的訊息。log 每人每 5 秒最多一行（動作封包可以一直送）。
        local k, t = keyOf(player), now()
        if (quietUntil[k] or 0) <= t then
            quietUntil[k] = t + RATE_WINDOW_MS
            print(LOG .. "REFUSE user=" .. tostring(player:getUsername()) .. " n=" .. tostring(n) .. " code=NO_INTENT")
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
    local cells = {}
    for _, d in ipairs(Entry.cells(spr)) do
        local x, y, z = a[1] + d[1], a[2] + d[2], a[3] + d[3]
        local sq = Place.square(x, y, z)
        if not sq then return Server.refuse(player, n, i, "NOT_LOADED", { x = x, y = y, z = z }) end
        cells[#cells + 1] = { x = x, y = y, z = z, sq = sq, spr = d[4] }
    end
    local dist, dz = reach(player, cells)
    if dist > setting("MaxDistance", 3) or dz > 1 then
        return Server.refuse(player, n, i, "TOO_FAR", { x = a[1], y = a[2], z = a[3] })
    end
    for _, c in ipairs(cells) do
        local sh = safehouseCode(player, c)
        if sh then return Server.refuse(player, n, i, sh, { x = c.x, y = c.y, z = c.z }) end
    end
    for j, c in ipairs(cells) do
        if not Place.check(entry.kind, c.spr, c.sq, player) then
            return Server.refuse(player, n, i, "BLOCKED", { x = c.x, y = c.y, z = c.z })
        end
        for k2 = j + 1, #cells do -- 多格之間不能隔著牆（ISMoveableSpriteProps.lua:1616-1716 的 isWallBetweenParts）
            local o = cells[k2]
            if o.z == c.z and math.abs(o.x - c.x) + math.abs(o.y - c.y) == 1 and c.sq:isSomethingTo(o.sq) then
                return Server.refuse(player, n, i, "BLOCKED", { x = o.x, y = o.y, z = o.z })
            end
        end
    end
    local mult = setting("CostMultiplier", 1)
    local costs = {}
    for _, c in ipairs(cells) do
        c.cost = Cost.of(entry.kind, c.spr, mult)
        costs[#costs + 1] = c.cost
    end
    local total = Cost.sum(costs)
    local plan
    if not player:isBuildCheat() then -- 伺服器上可信：ExtraInfo 封包要 UseBuildCheat 能力（ExtraInfoPacket.java:274-277）
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
    print(LOG .. "BUILD user=" .. tostring(player:getUsername()) .. " id=" .. tostring(player:getOnlineID())
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
