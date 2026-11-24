-- 客戶端：送建造、拆除請求並排動作。游標與視窗呼叫 Client.build，右鍵選單（Menu.lua）與一區拆除（Area.lua）呼叫
-- Client.dismantle／Client.dismantleMany；這裡只做請求、排隊、收結果。客戶端的判斷只給畫面用；能不能蓋、扣什麼料、
-- 能不能拆、退什麼料都由伺服器重算（Server.intent／Server.complete、Server.dismantleIntent／Server.dismantle）。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Messages"
require "MinidoracatBuilder/Materials"
require "TimedActions/MinidoracatBuilderPlaceAction"
require "TimedActions/MinidoracatBuilderDismantleAction"
require "TimedActions/MinidoracatBuilderStandAction"
require "MinidoracatBuilder/Place"
require "MinidoracatBuilder/Check"

MinidoracatBuilder = MinidoracatBuilder or {}
local Client = MinidoracatBuilder.Client or {}
MinidoracatBuilder.Client = Client
local Entry, Messages, Materials = MinidoracatBuilder.Entry, MinidoracatBuilder.Messages, MinidoracatBuilder.Materials
local Check = MinidoracatBuilder.Check

local LOG = "[MinidoracatBuilderFor42] "
local MODULE = "MinidoracatBuilder"
local KEEP = 32 -- Client.results 只留最近幾筆

Client.pending = nil -- 最近送出的請求：{ n, e, entry, kind, player, cells = { { x, y, z, d }, ... } }
-- 最近送出、還沒輪完的拆除：{ n, list（送給伺服器的那幾件，照順序）, items（全部，含原版拆解的）, player, done,
-- skipped = { [碼] = 件數 }, refund = { [fullType] = 件數 }, total, left（還沒輪到的件數）, onDone }。輪完就清成 nil
Client.pendingUnbuild = nil
Client.results = {}  -- 伺服器回覆（refused／placed／dismantle*），新的在後；介面與 E2E 讀
-- Client.onResult(cmd, args)：排程設定（Queue.lua）；每則建造回覆（accepted／refused／placed）收進 results 之後呼叫
local lastNonce = getTimestampMs() % 1000000

-- 伺服器限流（server/Server.lua 的 RATE_WINDOW_MS、RATE_MAX：每人每 5 秒最多 20 個建造、拆除請求，多人連線時超過的
-- 不收也不回覆）。那份在 server 目錄、客戶端讀不到：兩邊要一起改（harness 讀 Server.lua 釘住兩邊一致）。
-- 建造（Client.build）、拆除（Client.dismantleMany）送出時各記一筆；照圖蓋送之前看最近一個窗的總數（手動送的也算）
Client.RATE_WINDOW_MS, Client.RATE_MAX = 5000, 20
local sends = {} -- 最近送出請求的時間（舊的在前）；分割畫面幾位玩家合算（寧可少送）

-- 最近一個限流窗（含兩端，同 Server 的 rateOk）送過幾個請求。順便原地丟掉窗外的與時鐘往回調後「在未來」的紀錄
function Client.recentSends(...)
    local t = (...) or getTimestampMs()
    local n = 0
    for i = 1, #sends do
        local s = sends[i]
        sends[i] = nil
        if s <= t and t - s <= Client.RATE_WINDOW_MS then
            n = n + 1
            sends[n] = s
        end
    end
    return n
end

-- 記一筆送出的請求（只留窗內的，不無限長）
function Client.sent()
    local t = getTimestampMs()
    Client.recentSends(t)
    sends[#sends + 1] = t
end

-- 走到 (x, y, z) 旁邊。格邊種類照原版牆的寫法（ISBuildingObject:walkTo）；在上一層的先走到正下方同一條邊旁邊
-- （樓上那格沒有地板時 walkAdjWall 找不到站位），走不到才照上一層找。其他不站在 own（同一件的其他格）上，
-- 在上一層的（屋頂）走到正下方那格旁邊。回 false＝旁邊沒有站得到的空格（luautils.walkAdj／walkAdjWall 沒排走路）；
-- 格子沒載入回 nil，照樣送，伺服器回 NOT_LOADED
local function walkNear(player, kind, north, x, y, z, ...)
    local own = ...
    local cell = getCell()
    if Entry.EDGE[kind] then
        local below = z > math.floor(player:getZ()) and cell:getGridSquare(x, y, z - 1)
        if below and luautils.walkAdjWall(player, below, north, true) then return true end
        local sq = cell:getGridSquare(x, y, z)
        if not sq then return nil end
        return luautils.walkAdjWall(player, sq, north, true)
    end
    if z > math.floor(player:getZ()) then z = z - 1 end
    local sq = cell:getGridSquare(x, y, z)
    if not sq then return nil end
    return luautils.walkAdj(player, sq, true, own)
end

-- 多格物件不站在自己的其他格上：實心的格子有人站著，伺服器會回 BLOCKED（Place.check 的佔用檢查）。
-- 樓梯照原版走到底片旁邊（ISBuildIsoEntity.lua:16-24）。
local function walkTo(player, kind, spr, c)
    if Entry.EDGE[kind] then return walkNear(player, kind, Entry.north(kind, spr), c[1], c[2], c[3]) end
    local cell = getCell()
    local own, x, y = {}, c[1], c[2]
    for _, d in ipairs(Entry.cells(spr)) do
        local o = cell:getGridSquare(c[1] + d[1], c[2] + d[2], c[3] + d[3])
        if o then own[#own + 1] = o end
        if d[5] == "bottom" then x, y = c[1] + d[1], c[2] + d[2] end
    end
    return walkNear(player, kind, nil, x, y, c[3], own)
end

-- 蓋 e（項目 ID），每格 cells[i] = { x, y, z, d } 一項：原點與朝向（0＝項目本身那一面、1..4＝N、E、S、W、5＝配對面，
-- Entry.face；牆拉長方形圍一圈時四邊的朝向不同）。回 nonce；不能送（項目或某格的朝向不存在、單機時請求當場被拒）回 nil
-- 與原因碼。會清掉玩家目前排著的動作（每人只留一個請求，設計稿）。動作等伺服器回 accepted 才排（單機當場就回）。
-- overlap＝true：疊放模式（建造視窗的「疊放」鈕），隨請求送去，伺服器照沙盒重算。
-- 車庫門只送一個錨點，第 5 欄是寬度（格數，Cursor.garageAnchor），送成 args.w；其他項目不送 w（伺服器收到會回 BAD_REQUEST）
function Client.build(player, e, cells, ...)
    local overlap = ...
    local entry, code = Entry.resolve(e)
    if not entry then return nil, code end
    local flat = {}
    for _, c in ipairs(cells) do
        if not Entry.face(entry, c[4]) then return nil, "BAD_FACE" end
        for k = 1, 4 do flat[#flat + 1] = c[k] end
    end
    lastNonce = lastNonce % 2000000000 + 1
    local n = lastNonce
    local set = entry.kind == "door" and Entry.doorSet(entry.spr)
    local w = set and set.garage and cells[1] and cells[1][5] or nil
    local args = { n = n, e = e, c = flat, v = Entry.digest(), o = overlap == true or nil, w = w }
    Client.pending = { n = n, e = e, entry = entry, kind = entry.kind, cells = cells, player = player }
    Client.pendingUnbuild = nil -- 每人只留一個請求：還沒輪完的拆除，收到回覆也不再排
    ISTimedActionQueue.clear(player)
    Client.sent() -- 伺服器限流照請求數算（單機被限流的也算）
    if isClient() then
        sendClientCommand(player, MODULE, "intent", args)
    elseif not MinidoracatBuilder.Server.intent(player, args) then -- 單機：同一個 Lua 狀態，被拒當場就知道
        local r = Client.results[#Client.results]
        return nil, (r and r.n == n and r.code) or "RATE_LIMITED"
    end
    return n
end

-- 拖一片水面時第 i 格要站哪：前面幾格輪到它時已經是水，站位不挑它們和它自己（AdjacentFreeTileFinder 的排除清單）。
-- 排除清單只放緊鄰這一格的（原版對每個候選格逐筆比對清單，全放會隨格數平方長）。dug＝前面排過的 { x, y, sq }。
-- 回站位的格子；false＝旁邊沒有站得到的空格；格子沒載入回 nil，照樣送
local function standToDig(player, c, dug)
    local sq = getCell():getGridSquare(c[1], c[2], c[3])
    if not sq then return nil end
    local skip = { sq }
    for _, d in ipairs(dug) do
        if math.abs(d[1] - c[1]) <= 1 and math.abs(d[2] - c[2]) <= 1 then skip[#skip + 1] = d[3] end
    end
    dug[#dug + 1] = { c[1], c[2], sq }
    return AdjacentFreeTileFinder.Find(sq, player, skip) or false
end

-- 水面一次挖好幾格（游標已經把格子排成離玩家遠的在前，Cursor.farFirst）：先把每格的站位都排出來，有一格沒有站位就
-- 整批不排，只排前面幾格的話挖完可能把最後站的地方圍住。每格都真的排一次走路：luautils.walkAdj 照排隊當下的位置判斷，
-- 覺得已經在旁邊就不排，輪到時玩家卻可能正站在這一格上（挖前一格時站的），伺服器會回有人擋著
local function queueDig(b)
    local dug, stands = {}, {}
    for i, c in ipairs(b.cells) do
        local s = standToDig(b.player, c, dug)
        if s == false then
            print(LOG .. "no free square next to " .. c[1] .. "," .. c[2] .. "," .. c[3] .. "; nothing queued")
            b.noRoom, b.noneQueued = i, true -- 整批沒排：提示照「第 i 格旁邊沒有空位」說（Queue.tick）
            return
        end
        stands[i] = s or false
    end
    for i = 1, #b.cells do
        if stands[i] then ISTimedActionQueue.add(ISWalkToTimedAction:new(b.player, stands[i])) end
        ISTimedActionQueue.add(MinidoracatBuilderPlaceAction:new(b.player, b.n, i))
    end
end

-- 伺服器收下請求後才走路、排動作：請求與動作走不同通道，先到的動作會被當成沒有請求
-- 旁邊沒有空位可站的那一格起就不排：原地做動作只會被伺服器以太遠拒絕，訊息會誤導。記下是第幾格（b.noRoom），
-- 佇列空了以後 Queue.tick 照它提示。第 2 格起排隊當下沒排進走路的（地板、屋頂找不到站位或沒有格子；任何種類「現在就在旁邊」，
-- luautils.lua:136-142，走完前面幾格就不在旁邊了），先排站位動作，輪到時才找（Client.stand）。
-- 建造作弊照原版不走過去、原地蓋（ISBuildingObject.lua:212；伺服器也不限距離，Check.near）
local DEFER = { floor = true, roof = true }
local function queue(b)
    b.queued = true
    local walk = not Materials.cheat(b.player)
    if walk and b.kind == "water" and #b.cells > 1 then return queueDig(b) end
    local actions = walk and #b.cells > 1 and ISTimedActionQueue.getTimedActionQueue(b.player).queue
    for i, c in ipairs(b.cells) do
        local before = actions and #actions
        local r = walk and walkTo(b.player, b.kind, Entry.face(b.entry, c[4]), c)
        local late = walk and i > 1 and (r == true and #actions == before or r ~= true and DEFER[b.kind])
        if late then
            ISTimedActionQueue.add(MinidoracatBuilderStandAction:new(b.player, b.n, i))
        elseif walk and r == false then
            print(LOG .. "no free square next to " .. c[1] .. "," .. c[2] .. "," .. c[3] .. "; stopped queuing at " .. i)
            b.noRoom = i
            return
        end
        ISTimedActionQueue.add(MinidoracatBuilderPlaceAction:new(b.player, b.n, i))
    end
end

-- 站位動作（MinidoracatBuilderStandAction）開始前：地板、屋頂要等前一格回了 placed（b.last）；前一格建造動作的 perform
-- 當場就開始下一個動作，complete（真正蓋）在後（IsoGameCharacter 的動作迴圈）。地板還要等前一格的地板出現在客戶端
-- （站位靠它；多人要等同步）。其他種類不靠前一格、請求換掉了都不等
function Client.standReady(n, i)
    local b = Client.pending
    if not (b and b.n == n) or not DEFER[b.kind] then return true end
    if (b.last or 0) < i - 1 then return false end
    if b.kind ~= "floor" then return true end
    local p = b.cells[i - 1]
    local sq = p and getCell():getGridSquare(p[1], p[2], p[3])
    return sq ~= nil and sq:has(IsoFlagType.solidfloor)
end

-- 樓上往外還沒蓋的那一格沒有格子（walkNear 回 nil；2026-11-24 實機）：站到它四周已有、能站的格子（通常是剛蓋好的前一格），
-- 挑離玩家最近的；已經站在它旁邊就不走。回 true（不必走或排了走路）或 false（四周沒有能站的格子）
local function standBeside(player, x, y, z)
    if z > math.floor(player:getZ()) then z = z - 1 end
    local cell, here, best, far = getCell(), player:getCurrentSquare(), nil, math.huge
    for dy = -1, 1 do
        for dx = -1, 1 do
            local sq = (dx ~= 0 or dy ~= 0) and cell:getGridSquare(x + dx, y + dy, z)
            if sq and sq == here then return true end
            if sq and sq:isFree(false) then
                local d = math.abs(x + dx + 0.5 - player:getX()) + math.abs(y + dy + 0.5 - player:getY())
                if d < far then best, far = sq, d end
            end
        end
    end
    if not best then return false end
    ISTimedActionQueue.add(ISWalkToTimedAction:new(player, best))
    return true
end

-- 輪到第 i 格才找站位、排走路（站位動作開著 beginAddingActions，走路插在它後面）。找不到站位但伺服器的距離檢查原地就過
-- （屋頂站位算在下一層，前面蓋好的屋頂片不會變出站位），原地蓋。都不行時記 noRoom、回 false
function Client.stand(n, i)
    local b = Client.pending
    if not (b and b.n == n) then return false end
    local c = b.cells[i]
    local r = walkTo(b.player, b.kind, Entry.face(b.entry, c[4]), c)
    if r == nil then r = standBeside(b.player, c[1], c[2], c[3]) end
    if r then return true end
    if Check.near(b.player, { { x = c[1], y = c[2], z = c[3] } }, false, true) == nil then return true end
    print(LOG .. "no free square next to " .. c[1] .. "," .. c[2] .. "," .. c[3] .. "; stopped at " .. i)
    b.noRoom = i
    return false
end

local function remember(cmd, args)
    args.cmd = cmd
    local list = Client.results
    list[#list + 1] = args
    if #list > KEEP then table.remove(list, 1) end
end

local ACCEPT_MS = 10000 -- 送出後這麼久沒有 dismantleAccepted：MP 伺服器限流時不回覆（Server.dismantleIntent 的 rateOk）
local IDLE_MS = 1500    -- 收下後動作佇列空了這麼久還沒輪完，算停下（MP 的回覆比客戶端動作結束晚到；同 Cursor）

-- 原版 walkToAndEquip(…, "scrap") 走路時一律不留排好的動作（keepActions 只在坐著時才是 true，
-- ISMoveableSpriteProps.lua:3070-3124；luautils.lua:119-122、229-232 不留就先清佇列）：一區拆除的第二件起會把前面排好的
-- 動作清掉。照它的分支自己走（keepActions＝true），工具照它的寫法拿上手。回原因碼或 nil。
local function walkScrap(props, player, sq)
    local o, walked = props.object, nil
    if props.type == "Window" or props.type == "WindowObject" then
        local dir = props.facing
        if props.type == "Window" then dir = (dir == "N" or dir == "S") and "S" or "E" end
        local frame = props:getWallForFacing(sq, dir, "WindowFrame")
        walked = frame and luautils.walkAdjWindowOrDoor(player, sq, frame, true)
    elseif instanceof(o, "IsoDoor") or (instanceof(o, "IsoThumpable") and o:isDoor())
        or o:getType() == IsoObjectType.wall then
        walked = luautils.walkAdjWindowOrDoor(player, sq, o, true)
    else
        walked = props:walkAdj(player, sq, true)
    end
    local cheat = ISMoveableDefinitions.cheat
    if not walked and not cheat then return "NO_ROOM" end
    local tool, tool2 = props:hasScrapTool(player, false), props:hasScrapTool(player, true)
    if not (tool and tool2) then return (not cheat) and "NO_TOOL" or nil end
    local W = ISWorldObjectContextMenu
    if tool ~= true then W.equip(player, player:getPrimaryHandItem(), tool, true) end
    if tool2 ~= true then
        if not instanceof(tool2, "Clothing") then
            W.equip(player, player:getSecondaryHandItem(), tool2, false)
        elseif not player:isEquippedClothing(tool2) then -- 焊接面罩
            ISInventoryPaneContextMenu.wearItem(tool2, player:getPlayerNum())
        end
    end
    return nil
end

-- 原版拆解（ISDisassembleMenu.disassemble 的做法，ISDisassembleMenu.lua:83-102）排進佇列；退什麼照原版。不能排回原因碼
local function queueScrap(player, obj)
    local sq = obj:getSquare()
    if not (sq and sq:getObjects():contains(obj)) then return "GONE" end
    local props = ISMoveableSpriteProps.fromObject(obj)
    if not props or (props.isMultiSprite and not props:getSpriteGridInfo(sq, true)) then return "GONE" end
    local r = props:canScrapObject(player)
    if not r.canScrap then
        if r.containerFull then return "NOT_EMPTY" end
        if props.scrapUseTool and not (r.haveTool and r.haveTool2) then return "NO_TOOL" end
        return "SCRAP"
    end
    local why = walkScrap(props, player, sq)
    if why then return why end
    if instanceof(obj, "IsoLightSwitch") and obj:hasLightBulb() then
        ISTimedActionQueue.add(ISLightActions:new("RemoveLightBulb", player, obj))
    end
    if obj:getProperties():has(IsoFlagType.solidfloor) then
        local adjacent = AdjacentFreeTileFinder.Find(sq, player)
        if adjacent then ISTimedActionQueue.add(ISWalkToTimedAction:new(player, adjacent)) end
    end
    local dir = props:getFaceDirectionFromSpriteName(props.sprite:getName())
    local object = props:findOnSquare(sq, props.spriteName)
    local act = ISMoveablesAction:new(player, sq, "scrap", nil, object, dir, nil, nil)
    -- MP：伺服器 complete() 拆掉物件後，移除封包常比「動作完成」先到；原版 isValid 見物件不在就 stop()，stop 會 resetQueue
    -- （ISMoveablesAction.lua:31-37、ISBaseTimedAction.lua:63-64），一區拆除排在後面的動作全被清掉（E2E builder-batch-1101g-area：
    -- 原版拆解那件拆完佇列整個空掉）。已經開始的就不再查物件，等伺服器的完成（LuaTimedActionNew.update 的 isDone →
    -- forceComplete）照常輪下一件。只蓋在這個實例上（NetTimedAction 只送 new 的參數，NetTimedAction.java:36-50），不改原版類別
    local valid = act.isValid
    act.isValid = function(self)
        if self:isStarted() and not self:isValidObject() then return true end
        return valid(self)
    end
    ISTimedActionQueue.add(act)
    return nil
end

-- 拆好或跳過一件：累計件數、退料、跳過的原因
local function settle(b, code, args)
    b.left = b.left - 1
    if code then
        b.skipped[code] = (b.skipped[code] or 0) + 1
        b.lastSkip = args
        return
    end
    b.done = b.done + 1
    for ft, c in pairs(args and args.refund or {}) do b.refund[ft] = (b.refund[ft] or 0) + c end
end

-- 送給伺服器的第 i 件有了結果（伺服器回覆，或排隊時就知道旁邊沒空位）；每件只算一次
local function resolve(b, i, code, args)
    if not b.list[i] or b.res[i] then return end
    b.res[i] = true
    b.got = b.got + 1
    b.result[b.list[i]] = code or true
    settle(b, code, args)
end

-- 沒給 onDone 時的通知：單件拆不了照舊說原因；其他照 Messages.unbuildSummary（拆了幾件、退了什麼、留著幾件與原因、停下）
local function tell(b, s)
    -- 一件都還沒拆就被拒：原因收到 dismantleRefused 時已經說了；拆到一半才被拒（例：中途 INTERNAL）照停下跳總結
    if s.refused and (s.done or 0) == 0 then return end
    local a = b.lastSkip
    if s.total == 1 and a and not s.stopped then
        if a.code ~= "PERM_DENIED" then -- Safehouse 拒絕時自己推了通知（同 Cursor 的 tell）
            Messages.toast(b.player, Messages.unbuildRefusal(a.code, a), getText("IGUI_MBLD_NotRemoved"))
        end
        return
    end
    local name
    if s.total == 1 then
        require "MinidoracatBuilder/Names"
        name = MinidoracatBuilder.Names.of(b.items[1].name, b.items[1].kind)
    end
    local text, title = Messages.unbuildSummary(s, name)
    Messages.toast(b.player, text, title)
end

-- 輪完（或被拒、停下）：原版拆解的那幾件照物件還在不在格子上算拆好沒；還沒輪到的算停下。onDone(summary) 或自己通知。
local function finish(b, ...)
    local refused = ...
    if Client.pendingUnbuild ~= b then return end
    Client.pendingUnbuild = nil
    for _, it in ipairs(b.scrapping) do
        local sq = it.obj:getSquare()
        if not (sq and sq:getObjects():contains(it.obj)) then
            settle(b, nil, nil)
            b.result[it] = true
        end
    end
    local s = { done = b.done, total = b.total, skipped = b.skipped, refund = b.refund, stopped = b.left > 0,
        refused = refused, res = b.result }
    if b.onDone then b.onDone(s) else tell(b, s) end
end

-- 斜面格上的地板（舊版照地板一片一片蓋的坡道片）要站哪：原版找站位不分斜面（AdjacentFreeTileFinder），挑到隔壁的坡道格時
-- 角色得繞到坡底爬上去，路斷了走路當場停、整串佇列清空（玩家 2026-11-21 回報舊片拆不了；E2E ramp-legacy-mp）。
-- 先找緊鄰、不是斜面的空格：排除清單放 own 與緊鄰的斜面格。回站位的格子；nil＝緊鄰的都是斜面
local function flatStand(player, sq, own)
    local skip, cell = {}, getCell()
    for i, o in ipairs(own) do skip[i] = o end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    for dy = -1, 1 do
        for dx = -1, 1 do
            local n = cell:getGridSquare(x + dx, y + dy, z)
            if n and n:hasSlopedSurface() then skip[#skip + 1] = n end
        end
    end
    return AdjacentFreeTileFinder.Find(sq, player, skip)
end

-- 一次填平好幾格水面、拆斜面格上的地板（slope[it]）：近的先排。排隊當下裡面那幾格四周都是水（或斜面）、沒有地方站；
-- 前面排過的格子輪到時已經填成（拆成）平地，找不到站位的就走到緊鄰（上下左右）、前面排過的那一格。都沒有：水面跳過
-- （NO_ROOM），斜面格照原版站隔壁的坡道格（可能要繞到坡底）。逐筆插入，不用 table.sort（家族規則）
local function queueFill(b, ponds, slope)
    local px, py = b.player:getX(), b.player:getY()
    local order, key = {}, {}
    for _, it in ipairs(ponds) do
        local dx, dy = it.x + 0.5 - px, it.y + 0.5 - py
        local k, i = dx * dx + dy * dy, #order
        while i > 0 and key[i] > k do
            order[i + 1], key[i + 1] = order[i], key[i]
            i = i - 1
        end
        order[i + 1], key[i + 1] = it, k
    end
    local cell, filled = getCell(), {}
    for _, it in ipairs(order) do
        local sq = slope[it] and cell:getGridSquare(it.x, it.y, it.z)
        local stand
        if sq then
            local flat = flatStand(b.player, sq, it.own or {})
            if flat then ISTimedActionQueue.add(ISWalkToTimedAction:new(b.player, flat)) end
            stand = flat ~= nil
        else
            stand = walkNear(b.player, it.kind, it.north, it.x, it.y, it.z, it.own or {})
        end
        if stand == false then
            for _, f in ipairs(filled) do
                local sq = math.abs(f.x - it.x) + math.abs(f.y - it.y) == 1 and cell:getGridSquare(f.x, f.y, f.z)
                if sq then
                    ISTimedActionQueue.add(ISWalkToTimedAction:new(b.player, sq))
                    stand = true
                    break
                end
            end
        end
        if stand == false and sq then
            stand = walkNear(b.player, it.kind, it.north, it.x, it.y, it.z, it.own or {})
        end
        if stand == false then
            resolve(b, b.index[it], "NO_ROOM", { code = "NO_ROOM" })
            print(LOG .. "dismantle not queued at " .. it.x .. "," .. it.y .. "," .. it.z .. ": NO_ROOM")
        else
            ISTimedActionQueue.add(MinidoracatBuilderDismantleAction:new(b.player, b.n, b.index[it]))
            filled[#filled + 1] = it
        end
    end
end

-- 伺服器收下才走過去、照 items 的順序排動作（同 Client.build）。旁邊沒空位、原版拆解現在不能拆的那一件跳過，照排下一件。
-- 建造作弊時本工具拆的不走過去（同 queue；原版 ISDestroyCursor.lua:24），原版拆解的照原版走（它看搬運作弊，不看建造作弊）。
-- 水面超過一格、斜面格上的地板（舊版照地板蓋的坡道片，一片也算）留到最後一起排（queueFill）
local function queueUnbuild(b)
    b.queued = true
    local walk = not Materials.cheat(b.player)
    local late, slope, cell = {}, {}, getCell()
    if walk then
        for _, it in ipairs(b.items) do
            local sq = it.route ~= "scrap" and it.kind == "floor" and cell:getGridSquare(it.x, it.y, it.z)
            if sq and sq:hasSlopedSurface() then slope[it] = true end
            if slope[it] or (it.kind == "water" and it.route ~= "scrap") then late[#late + 1] = it end
        end
    end
    local batch = #late > 1 or (#late == 1 and slope[late[1]] == true)
    for _, it in ipairs(b.items) do
        local code
        if batch and (slope[it] or (it.kind == "water" and it.route ~= "scrap")) then
            code = nil -- 留給 queueFill
        elseif it.route == "scrap" then
            code = queueScrap(b.player, it.obj)
            if code then
                settle(b, code, { code = code })
                b.result[it] = code
            else
                b.scrapping[#b.scrapping + 1] = it
            end
        elseif walk and walkNear(b.player, it.kind, it.north, it.x, it.y, it.z, it.own or {}) == false then
            code = "NO_ROOM"
            resolve(b, b.index[it], code, { code = code })
        else
            ISTimedActionQueue.add(MinidoracatBuilderDismantleAction:new(b.player, b.n, b.index[it]))
        end
        if code then print(LOG .. "dismantle not queued at " .. it.x .. "," .. it.y .. "," .. it.z .. ": " .. code) end
    end
    if batch then queueFill(b, late, slope) end
    if b.got >= #b.list and #b.scrapping == 0 then finish(b) end
end

-- 拆一串（一區拆除，或右鍵拆一件）：items[i] = { x, y, z, name（sprite 名稱）, kind, north（格邊種類的方向）, own（同一件
-- 各片所在的格子，走路時不站上去）, route = "builder"（本工具拆）| "scrap"（原版拆解，obj＝物件）, obj }，照拆的順序。
-- builder 的照順序送一筆拆除請求，伺服器收下後兩種動作照 items 的順序一起排（沒有 builder 的不送請求，直接排）。
-- 全部輪完、被拒或停下時呼叫 onDone({ done, total, skipped = { [碼] = 件數 }, refund = { [fullType] = 件數 }, stopped,
-- refused＝整筆被拒的碼或 nil, res = { [items 的那一項] = true（拆好）或跳過的碼；沒輪到的沒有 } })；沒給 onDone 時自己跳通知。
-- 會清掉玩家目前排著的動作、取代還沒輪完的建造或拆除。回 nonce。
function Client.dismantleMany(player, items, ...)
    local onDone = ...
    lastNonce = lastNonce % 2000000000 + 1
    local n = lastNonce
    local list, index, t = {}, {}, {}
    for _, it in ipairs(items) do
        if it.route ~= "scrap" then
            list[#list + 1] = it
            index[it] = #list
            local k = #t
            t[k + 1], t[k + 2], t[k + 3], t[k + 4] = it.x, it.y, it.z, it.name
        end
    end
    local b = { n = n, list = list, index = index, items = items, player = player, done = 0, skipped = {}, refund = {},
        total = #items, left = #items, got = 0, res = {}, result = {}, scrapping = {}, onDone = onDone, at = getTimestampMs() }
    -- 拆除照「停下」處理：圖塊建造排著的全部取消（選單、一區拆除放開前已寫出會取消幾格，Cursor.cancels）
    local Q = MinidoracatBuilder.Queue
    if Q then Q.cancel(player) end
    Client.pendingUnbuild = b
    Client.pending = nil -- 同上：還沒收下的建造請求作廢
    ISTimedActionQueue.clear(player)
    if #list == 0 then
        queueUnbuild(b)
        return n
    end
    Client.sent() -- 同建造：伺服器限流照請求數算
    if isClient() then
        sendClientCommand(player, MODULE, "dismantle", { n = n, t = t })
    else
        MinidoracatBuilder.Server.dismantleIntent(player, { n = n, t = t }) -- 單機：當場回覆（Server.send 直接呼叫 onServerCommand）
    end
    return n
end

-- 拆 obj（本 MOD 蓋的那件，Dismantle.kindOf 是 kind；own＝同一件各片所在的格子）
function Client.dismantle(player, obj, kind, ...)
    local own = ...
    local spr, sq = obj:getSprite(), obj:getSquare()
    return Client.dismantleMany(player, { { x = sq:getX(), y = sq:getY(), z = sq:getZ(), name = spr:getName(), kind = kind,
        north = Entry.north(kind, spr), own = own, route = "builder", obj = obj } })
end

-- dismantleAccepted：{ n }；dismantleRefused：{ n, i（0＝請求本身）, code, x, y, z }；
-- dismantleSkipped：{ n, i, code, x, y, z, tools }；dismantled：{ n, i, x, y, z, e, refund = { [fullType] = 件數 } }
local UNBUILD = { dismantleAccepted = true, dismantleRefused = true, dismantleSkipped = true, dismantled = true }
local function onUnbuild(cmd, args)
    local b = Client.pendingUnbuild
    remember(cmd, args)
    if cmd == "dismantleRefused" or cmd == "dismantleSkipped" then
        print(LOG .. cmd .. " n=" .. tostring(args.n) .. " i=" .. tostring(args.i) .. " code=" .. tostring(args.code))
    end
    if not (b and b.n == args.n) then return end -- 被取代的那筆：不再排、不再通知
    if cmd == "dismantleAccepted" then
        if not b.queued then queueUnbuild(b) end
        return
    end
    if cmd == "dismantleRefused" then
        ISTimedActionQueue.clear(b.player) -- MP 的 Reject 已清過（再清無害），單機要在這裡清
        if args.code ~= "PERM_DENIED" then -- Safehouse 拒絕時自己推了通知（同 Cursor 的 tell）
            Messages.toast(b.player, Messages.unbuildRefusal(args.code, args), getText("IGUI_MBLD_NotRemoved"))
        end
        return finish(b, args.code)
    end
    resolve(b, args.i, cmd == "dismantleSkipped" and args.code or nil, args)
    if b.queued and b.got >= #b.list and #b.scrapping == 0 then finish(b) end
end

-- 每 tick：收下後動作佇列空了一陣子還沒輪完＝停下了（玩家走開、按 ESC、原版拆解失敗清了佇列，分不出來，
-- ISBaseTimedAction.lua:63-64），照實說拆了幾件；原版拆解的那幾件也在這時候算。一直沒收下（限流不回覆）也算停下。
function Client.tickUnbuild()
    local b = Client.pendingUnbuild
    if not b then return end
    local now = getTimestampMs()
    if not b.queued then
        if now - b.at > ACCEPT_MS then finish(b) end
        return
    end
    if ISTimedActionQueue.isPlayerDoingAction(b.player) then
        b.idleAt = nil
        return
    end
    b.idleAt = b.idleAt or now
    if now - b.idleAt >= IDLE_MS then finish(b) end
end
Events.OnTick.Add(Client.tickUnbuild)

-- accepted：{ n }；refused：{ n, i（0＝請求本身被拒）, code, x, y, z, need = { fullType = 數量 }, tools = { ItemTag 欄位名 } }；
-- placed：{ n, i, replaced（原地替換了舊的那件時 true）}
-- 目前這筆請求被拒時清掉後面的動作：MP 的 Reject 已清過（再清無害），單機的 complete() 回傳值沒人看，要在這裡清。
function Client.onServerCommand(cmd, args)
    if UNBUILD[cmd] then return onUnbuild(cmd, args) end
    if cmd == "ledgers" then -- 管理面板的伺服器紀錄（Server.ledgers）
        if MinidoracatBuilder.Admin then MinidoracatBuilder.Admin.onLedgers(args) end
        return
    end
    if cmd ~= "accepted" and cmd ~= "refused" and cmd ~= "placed" then return end
    local b = Client.pending
    if cmd == "accepted" and b and b.n == args.n and not b.queued then queue(b) end
    remember(cmd, args)
    if cmd == "refused" then
        print(LOG .. "refused n=" .. tostring(args.n) .. " i=" .. tostring(args.i) .. " code=" .. tostring(args.code))
        if b and b.n == args.n then ISTimedActionQueue.clear(b.player) end
    end
    if cmd == "placed" and b and b.n == args.n then b.last = math.max(b.last or 0, args.i or 0) end
    if Client.onResult then Client.onResult(cmd, args) end
end

Events.OnServerCommand.Add(function(module, command, args)
    if module == MODULE then Client.onServerCommand(command, args or {}) end
end)

-- 伺服器剛放的物件，客戶端收到時引擎先 load 才設格子（IsoObject.java:4421,4437），IsoLightSwitch.load 要有格子的兩段都被跳過
-- （IsoLightSwitch.java:351-380）。本 MOD 蓋的照 load 補上：
--   不能改裝的燈：照 sprite 設顏色。processClient 用預設的白色建光源（AddItemToMapPacket.java:62-64），重新載入區塊才是 sprite
--     的顏色（E2E builder-rooms-1029d）；LightingJNI 下次更新看到顏色變了就送（LightingJNI.java:334-343）。能改裝的燈顏色在封包裡。
--   自建房間裡的開關：switchLight(activated)（:351-352）。沒補的話房間燈停在房間原本的狀態：開關顯示開著、房間卻暗，第一次按
--     看起來沒反應（builder-rooms-1029g）。switchLight 會把房間裡其他燈與開關的 activated 一起改掉（:517-523），同一幀照原值
--     還原（同伺服器 Circuits 的 apply）。地圖房屋的房間燈由伺服器同步，客戶端自己切會和伺服器不一致；沒有房間時切了也看不到
--     （開關的光源不畫，:790-794）。招牌不算開關（Rules.switchProps），不補。
-- 自建房間的開關照自己的狀態切房間燈，房間裡其他燈與開關的 activated 同一幀還原。回那個房間（不在自建房間回 nil）
local function lightRoom(obj)
    local sq = obj:getSquare()
    local room = sq and sq:isUserDefinedRoom() and sq:getRoom()
    if not room then return nil end
    local list, others, was = room:getLightSwitches(), {}, {}
    for i = 0, list:size() - 1 do
        local o = list:get(i)
        if o ~= obj then
            others[#others + 1] = o
            was[#others] = o:isActivated()
        end
    end
    obj:switchLight(obj:isActivated())
    for i, o in ipairs(others) do
        if o:isActivated() ~= was[i] then o:setActivated(was[i]) end
    end
    return room
end

-- 自建房間重建後房間燈會熄（2026-11-14 群聊回報：拆一面牆重新裝修，整棟其他房間的燈都滅了，開關卻還顯示開著）。
-- 蓋牆、拆牆讓區域重算時，引擎把那棟的房間全部丟掉重建（WorldRegionToMetaGrid.java:386-431 移除並 clear 舊的 IsoRoom，
-- IsoMetaGrid.java:382-399 建新的），房間燈照物件池裡 RoomDef 的舊值建（:271、:610-612），不看開關；單機讀檔時開關先載入、
-- 房間後建，load 裡補切的那段又只在多人客戶端跑（IsoLightSwitch.java:352-353）。重建沒有 Lua 事件，RoomDef 的 lightsActive
-- 也讀不到，所以記下每個本工具開關上次所在的 IsoRoom，每秒比一次：換了一個（或從沒有變成有）就照開關的狀態補切一次。
-- 只在換房間物件時切：switchLight 會讓整張光照重算（:556 recalcLightTime），不能每秒都切。
local WATCH_MS = 1000
local watched, watchAt, watching = {}, 0, false
local function watchTick()
    local t = getTimestampMs()
    if t >= watchAt and t - watchAt < WATCH_MS then return end
    watchAt = t
    for i = #watched, 1, -1 do
        local w = watched[i]
        local obj = w.obj
        local sq = obj:getSquare()
        if not sq or obj:getObjectIndex() < 0 then -- 拆掉、拿走或那一塊卸載了
            table.remove(watched, i)
        else
            -- 也比 RoomDef：房間物件沒換、定義換了一份時一樣算重建
            local room = sq:getRoom()
            local def = room and room:getRoomDef() or nil
            if room ~= w.room or def ~= w.def then
                w.room, w.def = room, def
                if room then lightRoom(obj) end
            end
        end
    end
    if #watched == 0 then
        watching = false
        Events.OnTick.Remove(watchTick)
    end
end

-- 本工具的開關（不含燈、招牌）進到客戶端的世界：多人新放的（OnObjectAdded）、單機新放的（Place.build）與讀格子時
-- 載入的（Place.migrate）
local function watch(obj, room)
    local def = room and room:getRoomDef() or nil
    for i = 1, #watched do
        if watched[i].obj == obj then
            watched[i].room, watched[i].def = room, def
            return
        end
    end
    watched[#watched + 1] = { obj = obj, room = room, def = def }
    if not watching then
        watching = true
        Events.OnTick.Add(watchTick)
    end
end

local function onAdded(obj)
    if not instanceof(obj, "IsoLightSwitch") or not obj:hasModData() or not obj:getModData().builderEntry then return end
    local spr = obj:getSprite()
    local p = spr and spr:getProperties()
    if not p then return end
    if p:has("lightR") then
        if obj:getCanBeModified() then return end
        local r, g, b = tonumber(p:get("lightR")), tonumber(p:get("lightG")), tonumber(p:get("lightB"))
        if not (r and g and b) then return end
        obj:setPrimaryR(r / 255)
        obj:setPrimaryG(g / 255)
        obj:setPrimaryB(b / 255)
        return
    end
    if not MinidoracatBuilder.Rules.switchProps(p) then return end
    watch(obj, lightRoom(obj))
end

Events.OnObjectAdded.Add(onAdded)

-- 讀格子時載入的開關只登記、不馬上切（房間記成沒有）：這時房間多半還沒建；建好後、或本來就有時，watchTick 補切一次
MinidoracatBuilder.Place.onLoaded = function(obj)
    if not instanceof(obj, "IsoLightSwitch") then return end
    local spr = obj:getSprite()
    local p = spr and spr:getProperties()
    if p and MinidoracatBuilder.Rules.switchProps(p) then watch(obj, nil) end
end

return Client
