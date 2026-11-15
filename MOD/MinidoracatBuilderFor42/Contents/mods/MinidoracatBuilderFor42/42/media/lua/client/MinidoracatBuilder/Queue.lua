-- 客戶端的建造排程（使用者 2026-11-16 選 queue=append：排隊中再拖一排，接在後面蓋）。伺服器每人只留一個請求，
-- Client.build 每送一筆就清角色的動作佇列，所以一次只跑一筆：前一筆蓋完、角色的動作佇列空了才送下一筆。
-- 超過沙盒「一次最多幾格」（MaxCellsPerDrag）的切成幾筆依序送，算同一組；伺服器每筆照舊驗上限（Server.intent）。
-- 一筆停下（玩家走開、按 Esc、動作被打斷）或被拒：這位玩家排著的全部取消，照圖蓋（owner＝"plan"）的結果交給它的
-- onDone。游標關掉後照樣排、照樣通知。能不能蓋、扣什麼料照舊由伺服器重算；這裡只排程、畫排隊虛影、發通知。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Client"
require "MinidoracatBuilder/Messages"

MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local Queue = B.Queue or {}
B.Queue = Queue
local Entry, Client, Messages = B.Entry, B.Client, B.Messages

local LOG = "[MinidoracatBuilderFor42] "
local ACCEPT_MS = 10000 -- 送出後這麼久沒有 accepted：MP 伺服器限流時不回覆（Server.intent 的 rateOk）
local IDLE_MS = 1500    -- 收下後動作佇列空了這麼久還沒蓋完，算停下（MP 的 placed 比客戶端動作結束晚到）
local QR, QG, QB = 0.45, 0.75, 1 -- 排著與正在蓋的格子外框（藍）；游標預覽用原版的可蓋綠／不可蓋紅，排隊的要分得出來

-- playerNum → { player, list＝{ 筆, ... }（第一筆有 n＝已送出、正在跑；沒有 n＝前一筆剛做完、等動作佇列空了才送）,
-- last＝上一組手拖的蓋好的片 }。
-- 筆＝{ group, slot, anchors, parts, base（組裡前面有幾格）, count, placed, n, req（送出時的 Client.pending）, accepted,
-- at, idleAt }；組＝{ id, owner, onDone, name, entry, overlap, count, placed, built, done }
local slots = {}
local lastId = 0
local sending -- 正在 Client.build 裡的那一筆：單機的 intent 在 Client.build 回傳前就答覆，那時 n 還沒記到筆上

-- title 省略＝「無法建造」（Messages.toast）
local function tell(player, code, extra, title)
    if code == "PERM_DENIED" then return end -- Safehouse 拒絕時自己推了通知，不再疊一則
    Messages.toast(player, Messages.refusal(code, extra), title)
end

-- 整組結束（蓋完、停下、被拒、被取消）：交給 onDone 一次。why＝nil（蓋完）或 { refused, extra, noRoom }
local function finish(g, why)
    if g.done then return end
    g.done = true
    if not g.onDone then return end
    why = why or {}
    local sum = { owner = g.owner, count = g.count, placed = g.placed, refused = why.refused, extra = why.extra,
        stopped = g.placed < g.count, noRoom = why.noRoom }
    local ok, err = pcall(g.onDone, sum)
    if not ok then print(LOG .. "queue onDone failed: " .. tostring(err)) end
end

-- 停下或被拒：這位玩家排著的全部取消。g＝出事的那一組（帶 why），其他組只算停下
local function stopAll(s, g, why)
    local list = s.list
    s.list = {}
    if g then finish(g, why) end
    for _, j in ipairs(list) do finish(j.group, {}) end
end

-- 送出一筆。當場不能送（項目不能蓋、某格沒有那一面、單機時請求當場被拒）照被拒停下；回 nonce，或 nil, 原因碼
local function send(s, j)
    local g = j.group
    j.at, j.placed = getTimestampMs(), 0
    sending = j
    local ok, n, code = pcall(Client.build, s.player, g.name, j.anchors, g.overlap)
    sending = nil
    if not ok then
        print(LOG .. "build failed e=" .. tostring(g.name) .. ": " .. tostring(n))
        n, code = nil, "INTERNAL"
    end
    if n then
        j.n, j.req = n, Client.pending
        return n
    end
    if s.list[1] == j then -- 單機的 intent 當場被拒時 onResult 已經停過、通知過
        stopAll(s, g, { refused = code })
        if g.owner == "drag" then tell(s.player, code) end
    end
    return nil, code
end

-- 排一筆建造（契約「Queue」）。anchors＝{ { x, y, z, d }, ... }；parts[i]＝第 i 格各片的虛影 { x, y, z, sprite, yoff }，
-- 省略就不畫排隊虛影；overlap＝疊放（Client.build）。opts.owner＝"drag"（預設）或 "plan"，opts.onDone(sum) 整組結束時叫一次。
-- 手拖的進來時先取消照圖蓋的（玩家動手＝照圖蓋暫停）。沒有在跑的就立刻送，有就接在後面。
-- 回 組的 id 與（立刻送出時的）nonce；立刻送卻送不出去回 nil, 原因碼
function Queue.push(player, name, anchors, parts, overlap, opts)
    opts = opts or {}
    local owner = opts.owner or "drag"
    local pn = player:getPlayerNum()
    local s = slots[pn]
    if not s then
        s = { list = {} }
        slots[pn] = s
    end
    s.player = player
    if owner == "drag" then Queue.cancel(player, "plan") end
    local max = math.max(1, math.floor(tonumber(Entry.settings().MaxCellsPerDrag) or 32))
    lastId = lastId + 1
    local g = { id = lastId, owner = owner, onDone = opts.onDone, name = name, overlap = overlap, count = #anchors,
        placed = 0, built = {} }
    local idle = s.list[1] == nil
    for base = 0, #anchors - 1, max do
        local j = { group = g, slot = s, anchors = {}, parts = parts and {} or nil, base = base, placed = 0 }
        for k = 1, math.min(max, #anchors - base) do
            j.anchors[k] = anchors[base + k]
            if parts then j.parts[k] = parts[base + k] end
        end
        j.count = #j.anchors
        s.list[#s.list + 1] = j
    end
    if not s.list[1] then -- 沒有格子
        finish(g)
        return g.id
    end
    if not idle then return g.id end
    local n, code = send(s, s.list[1])
    if not n then return nil, code end
    return g.id, n
end

-- 取消這位玩家還沒蓋完的（owner 省略＝全部）。正在跑的那一筆屬於這個 owner 時清掉角色排著的動作；不通知
-- （放開前游標、選單已經寫出會取消幾格），照圖蓋的 onDone 收到 stopped
function Queue.cancel(player, owner)
    local s = slots[player:getPlayerNum()]
    if not s then return end
    local keep, gone = {}, {}
    for _, j in ipairs(s.list) do
        if owner == nil or j.group.owner == owner then
            gone[#gone + 1] = j.group
            if j.n then
                if Client.pending == j.req then Client.pending = nil end
                ISTimedActionQueue.clear(player)
            end
        else
            keep[#keep + 1] = j
        end
    end
    s.list = keep
    for _, g in ipairs(gone) do finish(g, {}) end
end

-- 跑著＋排著的筆數
function Queue.busy(player)
    local s = slots[player:getPlayerNum()]
    return s and #s.list or 0
end

-- 還沒蓋好的格數（含排著的）
function Queue.left(player)
    local s = slots[player:getPlayerNum()]
    if not s then return 0 end
    local n = 0
    for _, j in ipairs(s.list) do n = n + j.count - j.placed end
    return n
end

-- 上一組手拖的蓋好的片：{ { x, y, z, name＝sprite 名, e＝項目 ID, ... }, ... }，照蓋好的順序；沒有回 nil。
-- 只記在這次遊戲裡，重開遊戲後不記得
function Queue.last(player)
    local s = slots[player:getPlayerNum()]
    local l = s and s.last
    if not (l and l[1]) then return nil end
    return l
end

-- 拆掉剛蓋的：Queue.last 那幾片後蓋的先拆，送一筆拆除（Client.dismantleMany，會取消還沒蓋完的）；回送出幾件
function Queue.undoLast(player)
    local list = Queue.last(player)
    if not list then return 0 end
    slots[player:getPlayerNum()].last = nil
    local cell, items = getCell(), {}
    for i = #list, 1, -1 do
        local p = list[i]
        local own = {} -- 同一件的各格：走路時不站上去（Client 的 walkNear）
        for _, c in ipairs(p.cells) do
            local sq = cell:getGridSquare(p.a[1] + c[1], p.a[2] + c[2], p.a[3] + c[3])
            if sq then own[#own + 1] = sq end
        end
        items[#items + 1] = { x = p.x, y = p.y, z = p.z, name = p.name, kind = p.kind, north = p.north, own = own,
            route = "builder" }
    end
    Client.dismantleMany(player, items)
    return #items
end

-- 蓋好的那一格放下的是哪一片：原點那格（Entry.cells 第一個）、交替柵欄照座標（Entry.alternate，同伺服器）
local function piece(g, a)
    if g.entry == nil then g.entry = Entry.resolve(g.name) or false end
    local spr = g.entry and Entry.face(g.entry, a[4])
    local cells = spr and Entry.cells(spr)
    local c = cells and cells[1]
    if not c then return nil end
    local x, y = a[1] + c[1], a[2] + c[2]
    local put = Entry.alternate(c[4], x, y)
    return { x = x, y = y, z = a[3] + c[3], name = put:getName(), e = g.name, kind = g.entry.kind,
        north = Entry.north(g.entry.kind, put), a = a, cells = cells }
end

local function find(n)
    local j = sending
    if j and Client.pending and Client.pending.n == n then return j end
    for _, s in pairs(slots) do
        local h = s.list[1]
        if h and h.n == n then return h end
    end
    return nil
end

-- Client.onServerCommand 收進 results 後呼叫（Client.onResult）
function Queue.onResult(cmd, args)
    local j = find(args.n)
    if not j then return end
    local s, g = j.slot, j.group
    if cmd ~= "accepted" then
        local C = B.Cursor
        local c = C and C.get(s.player:getPlayerNum())
        if c then c.kgen = nil end -- 剛蓋好或被拒：下一幀重算預覽，不等每秒那一次
    end
    if cmd == "accepted" then
        j.accepted = true
    elseif cmd == "placed" then
        j.placed, g.placed = j.placed + 1, g.placed + 1
        local a = args.i and j.anchors[args.i]
        if args.i and j.parts then j.parts[args.i] = nil end
        local p = a and g.owner == "drag" and piece(g, a)
        if p then
            g.built[#g.built + 1] = p
            s.last = g.built
        end
        if j.placed >= j.count then
            if s.list[1] == j then table.remove(s.list, 1) end
            -- 下一筆等角色的動作佇列空了才送（Queue.tick）：MP 這時這一格的動作常還在佇列裡
            if not (s.list[1] and s.list[1].group == g) then finish(g) end
        end
    elseif cmd == "refused" then
        -- 被拒就停整串：MP 的 Reject 與 Client 都清掉了後面的動作
        stopAll(s, g, { refused = args.code, extra = args })
        if g.owner == "drag" then tell(s.player, args.code, args) end
    end
end
Client.onResult = Queue.onResult

-- 一位玩家的第一筆：還沒送的等動作佇列空了送；送出的收下後佇列空了一陣子還沒蓋完＝停下了，取消全部、提示一次。
-- 佇列空了分不出是玩家自己走開、按 ESC，還是路徑走不通（動作停下一律 resetQueue，不留原因：ISBaseTimedAction.lua:63-64），
-- 所以只有排隊時就知道的「旁邊沒空位」（Client.lua 的 queue 記在 noRoom）另外說；其他照實說蓋好幾格。材料是一格一格在
-- Server.complete 扣的（Place.build 成功後才 Materials.consume），停下時沒蓋的格子沒有扣。
local function step(s, j)
    local p, g = s.player, j.group
    if not j.n then
        if not ISTimedActionQueue.isPlayerDoingAction(p) then send(s, j) end
        return
    end
    -- 被別的請求取代（別處直接呼叫 Client.build、分割畫面的另一位玩家）：不通知
    if Client.pending ~= j.req then return stopAll(s, g, {}) end
    local now = getTimestampMs()
    if now < j.at then j.at = now end -- 時鐘往回調（家族 pitfalls）
    if not j.accepted then
        if now - j.at > ACCEPT_MS then
            stopAll(s, g, {})
            if g.owner == "drag" then tell(p, "RATE_LIMITED") end
        end
        return
    end
    if ISTimedActionQueue.isPlayerDoingAction(p) then
        j.idleAt = nil
        return
    end
    j.idleAt = j.idleAt or now
    if now - j.idleAt < IDLE_MS then return end
    -- 前面的都蓋好了，停在旁邊沒空位的那一格；一次挖好幾格水面時有一格沒空位就整批沒排（Client 的 noneQueued）
    local req = j.req
    local stuck = req.noRoom
    local noRoom = stuck and (j.placed + 1 >= stuck or req.noneQueued) and j.base + stuck or nil
    stopAll(s, g, { noRoom = noRoom })
    if g.owner ~= "drag" then return end
    local title = g.placed > 0 and getText("IGUI_MBLD_Interrupted") or nil
    if noRoom then
        tell(p, "NO_ROOM", { i = noRoom, n = g.count }, title)
    elseif g.placed > 0 then
        Messages.toast(p, getText("IGUI_MBLD_Stopped", tostring(g.placed), tostring(g.count)), title)
    else
        tell(p, "WALK")
    end
end

function Queue.tick()
    for _, s in pairs(slots) do
        local j = s.list[1]
        if j then step(s, j) end
    end
end
Events.OnTick.Add(Queue.tick)

-- 排著與正在蓋、還沒蓋好的格子：{ 各片, ... }（每格一項），都沒有回 nil（E2E 讀，Cursor.queued）
function Queue.queued()
    local out, n = nil, 0
    for _, s in pairs(slots) do
        for _, j in ipairs(s.list) do
            for _, ps in pairs(j.parts or {}) do -- 蓋好的格子設成 nil 了，用 pairs
                out = out or {}
                n = n + 1
                out[n] = ps
            end
        end
    end
    return out
end

-- 已送出、還沒蓋好的格子（使用者 2026-10-29：還沒蓋完前要顯示預計要蓋的格子）：淡虛影＋藍框，蓋好一格收一格。
-- 游標關掉後角色照樣在蓋，所以不畫在游標的 render，改在世界畫完時畫（OnPostRender，IngameState.java:1197-1200）：
-- 游標虛影也是在同一處、世界的 cell 畫完後才畫（FBORenderCell.java:316 的 DoBuilding），所以一樣畫在世界最上層。
-- 不能用 OnPostFloorLayerDraw：它只在舊渲染器（IsoCell.java:856-860）觸發，B42 預設的 FBO 渲染器沒有
-- （builder-ui-1029a 截圖一格都沒畫出來）。
-- parts＝{ [i] = { { x, y, z, sprite, yoff }, ... } }（各片的 sprite 是游標照那一格自己的面記的，圍一圈時北、西兩種邊
-- 各畫各的）；配方項目拖的一排（Recipes.lua）也用這支
function Queue.drawParts(parts)
    local floor = ISBuildingObject.getFloorCursorSprite() -- 不用 self（ISBuildingObject.lua:697-703）
    for _, ps in pairs(parts) do
        for _, g in ipairs(ps) do
            g[4]:RenderGhostTileColor(g[1], g[2], g[3], 0, g[5], 1, 1, 1, 0.35)
            floor:RenderGhostTileColor(g[1], g[2], g[3], QR, QG, QB, 0.8)
        end
    end
end

function Queue.draw()
    for _, s in pairs(slots) do
        for _, j in ipairs(s.list) do
            if j.parts then Queue.drawParts(j.parts) end
        end
    end
end
Events.OnPostRender.Add(Queue.draw)

return Queue
