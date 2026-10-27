-- 客戶端：送建造請求並排動作。第三階段的游標與視窗呼叫 Client.build；這裡只做請求、排隊、收結果。
-- 客戶端的判斷只給畫面用；能不能蓋、扣什麼料都由伺服器重算（Server.intent／Server.complete）。
require "MinidoracatBuilder/Entry"
require "TimedActions/MinidoracatBuilderPlaceAction"

MinidoracatBuilder = MinidoracatBuilder or {}
local Client = MinidoracatBuilder.Client or {}
MinidoracatBuilder.Client = Client
local Entry = MinidoracatBuilder.Entry

local LOG = "[MinidoracatBuilderFor42] "
local MODULE = "MinidoracatBuilder"
local KEEP = 32 -- Client.results 只留最近幾筆

Client.pending = nil -- 最近送出的請求：{ n, e, d, kind, cells = { { x, y, z }, ... } }
Client.results = {}  -- 伺服器回覆（refused／placed），新的在後；介面與 E2E 讀
-- Client.onResult(cmd, args)：游標設定（Cursor.lua）；每則回覆（accepted／refused／placed）收進 results 之後呼叫
local lastNonce = getTimestampMs() % 1000000

local function walkTo(player, kind, spr, c)
    local sq = getCell():getGridSquare(c[1], c[2], c[3])
    if not sq then return end
    if Entry.EDGE[kind] then
        local north = Entry.north(kind, spr)
        luautils.walkAdjWall(player, sq, north, true) -- 原版 ISBuildingObject:walkTo 的牆寫法
    else
        -- 多格物件不站在自己的其他格上：實心的格子有人站著，伺服器會回 BLOCKED（Place.check 的佔用檢查）
        local cell, own = getCell(), {}
        for _, d in ipairs(Entry.cells(spr)) do
            local o = cell:getGridSquare(c[1] + d[1], c[2] + d[2], c[3] + d[3])
            if o then own[#own + 1] = o end
        end
        luautils.walkAdj(player, sq, true, own)
    end
end

-- 蓋 e（項目 ID）朝向 d（0＝項目本身那一面、1..4＝N、E、S、W），每個原點 cells[i] = { x, y, z } 一項。
-- 回 nonce；不能送（項目或朝向不存在、單機時請求當場被拒）回 nil 與原因碼。會清掉玩家目前排著的動作（每人只留一個請求，設計稿）。
-- 動作等伺服器回 accepted 才排（單機當場就回）。
function Client.build(player, e, d, cells)
    local entry, code = Entry.resolve(e)
    if not entry then return nil, code end
    local spr = Entry.face(entry, d)
    if not spr then return nil, "BAD_FACE" end
    lastNonce = lastNonce % 2000000000 + 1
    local n = lastNonce
    local flat = {}
    for _, c in ipairs(cells) do
        flat[#flat + 1] = c[1]
        flat[#flat + 1] = c[2]
        flat[#flat + 1] = c[3]
    end
    local args = { n = n, e = e, d = d, c = flat, v = Entry.digest() }
    Client.pending = { n = n, e = e, d = d, kind = entry.kind, spr = spr, cells = cells, player = player }
    ISTimedActionQueue.clear(player)
    if isClient() then
        sendClientCommand(player, MODULE, "intent", args)
    elseif not MinidoracatBuilder.Server.intent(player, args) then -- 單機：同一個 Lua 狀態，被拒當場就知道
        local r = Client.results[#Client.results]
        return nil, (r and r.n == n and r.code) or "RATE_LIMITED"
    end
    return n
end

-- 伺服器收下請求後才走路、排動作：請求與動作走不同通道，先到的動作會被當成沒有請求
local function queue(b)
    b.queued = true
    for i, c in ipairs(b.cells) do
        walkTo(b.player, b.kind, b.spr, c)
        ISTimedActionQueue.add(MinidoracatBuilderPlaceAction:new(b.player, b.n, i))
    end
end

-- accepted：{ n }；refused：{ n, i（0＝請求本身被拒）, code, x, y, z, need = { fullType = 數量 }, tools = { ItemTag 欄位名 } }；
-- placed：{ n, i }
-- 目前這筆請求被拒時清掉後面的動作：MP 的 Reject 已清過（再清無害），單機的 complete() 回傳值沒人看，要在這裡清。
function Client.onServerCommand(cmd, args)
    if cmd ~= "accepted" and cmd ~= "refused" and cmd ~= "placed" then return end
    local b = Client.pending
    if cmd == "accepted" and b and b.n == args.n and not b.queued then queue(b) end
    args.cmd = cmd
    local list = Client.results
    list[#list + 1] = args
    if #list > KEEP then table.remove(list, 1) end
    if cmd == "refused" then
        print(LOG .. "refused n=" .. tostring(args.n) .. " i=" .. tostring(args.i) .. " code=" .. tostring(args.code))
        if b and b.n == args.n then ISTimedActionQueue.clear(b.player) end
    end
    if Client.onResult then Client.onResult(cmd, args) end
end

Events.OnServerCommand.Add(function(module, command, args)
    if module == MODULE then Client.onServerCommand(command, args or {}) end
end)

return Client
