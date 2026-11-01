-- 客戶端：送建造、拆除請求並排動作。游標與視窗呼叫 Client.build，右鍵選單（Menu.lua）與一區拆除（Area.lua）呼叫
-- Client.dismantle／Client.dismantleMany；這裡只做請求、排隊、收結果。客戶端的判斷只給畫面用；能不能蓋、扣什麼料、
-- 能不能拆、退什麼料都由伺服器重算（Server.intent／Server.complete、Server.dismantleIntent／Server.dismantle）。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Messages"
require "TimedActions/MinidoracatBuilderPlaceAction"
require "TimedActions/MinidoracatBuilderDismantleAction"

MinidoracatBuilder = MinidoracatBuilder or {}
local Client = MinidoracatBuilder.Client or {}
MinidoracatBuilder.Client = Client
local Entry, Messages = MinidoracatBuilder.Entry, MinidoracatBuilder.Messages

local LOG = "[MinidoracatBuilderFor42] "
local MODULE = "MinidoracatBuilder"
local KEEP = 32 -- Client.results 只留最近幾筆

Client.pending = nil -- 最近送出的請求：{ n, e, entry, kind, player, cells = { { x, y, z, d }, ... } }
-- 最近送出、還沒輪完的拆除：{ n, list（送給伺服器的那幾件，照順序）, items（全部，含原版拆解的）, player, done,
-- skipped = { [碼] = 件數 }, refund = { [fullType] = 件數 }, total, left（還沒輪到的件數）, onDone }。輪完就清成 nil
Client.pendingUnbuild = nil
Client.results = {}  -- 伺服器回覆（refused／placed／dismantle*），新的在後；介面與 E2E 讀
-- Client.onResult(cmd, args)：游標設定（Cursor.lua）；每則建造回覆（accepted／refused／placed）收進 results 之後呼叫
local lastNonce = getTimestampMs() % 1000000

-- 走到 (x, y, z) 旁邊。格邊種類照原版牆的寫法（ISBuildingObject:walkTo）；其他不站在 own（同一件的其他格）上，
-- 在上一層的（屋頂）走到正下方那格旁邊。回 false＝旁邊沒有站得到的空格（luautils.walkAdj／walkAdjWall 沒排走路）；
-- 格子沒載入回 nil，照樣送，伺服器回 NOT_LOADED
local function walkNear(player, kind, north, x, y, z, own)
    local cell = getCell()
    if Entry.EDGE[kind] then
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
function Client.build(player, e, cells)
    local entry, code = Entry.resolve(e)
    if not entry then return nil, code end
    local flat = {}
    for _, c in ipairs(cells) do
        if not Entry.face(entry, c[4]) then return nil, "BAD_FACE" end
        for k = 1, 4 do flat[#flat + 1] = c[k] end
    end
    lastNonce = lastNonce % 2000000000 + 1
    local n = lastNonce
    local args = { n = n, e = e, c = flat, v = Entry.digest() }
    Client.pending = { n = n, e = e, entry = entry, kind = entry.kind, cells = cells, player = player }
    Client.pendingUnbuild = nil -- 每人只留一個請求：還沒輪完的拆除，收到回覆也不再排
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
-- 旁邊沒有空位可站的那一格起就不排：原地做動作只會被伺服器以太遠拒絕，訊息會誤導。記下是第幾格（b.noRoom），
-- 佇列空了以後 Cursor.tick 照它提示
local function queue(b)
    b.queued = true
    for i, c in ipairs(b.cells) do
        if walkTo(b.player, b.kind, Entry.face(b.entry, c[4]), c) == false then
            print(LOG .. "no free square next to " .. c[1] .. "," .. c[2] .. "," .. c[3] .. "; stopped queuing at " .. i)
            b.noRoom = i
            return
        end
        ISTimedActionQueue.add(MinidoracatBuilderPlaceAction:new(b.player, b.n, i))
    end
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
local function finish(b, refused)
    if Client.pendingUnbuild ~= b then return end
    Client.pendingUnbuild = nil
    for _, it in ipairs(b.scrapping) do
        local sq = it.obj:getSquare()
        if not (sq and sq:getObjects():contains(it.obj)) then settle(b, nil, nil) end
    end
    local s = { done = b.done, total = b.total, skipped = b.skipped, refund = b.refund, stopped = b.left > 0,
        refused = refused }
    if b.onDone then b.onDone(s) else tell(b, s) end
end

-- 伺服器收下才走過去、照 items 的順序排動作（同 Client.build）。旁邊沒空位、原版拆解現在不能拆的那一件跳過，照排下一件。
local function queueUnbuild(b)
    b.queued = true
    for _, it in ipairs(b.items) do
        local code
        if it.route == "scrap" then
            code = queueScrap(b.player, it.obj)
            if code then settle(b, code, { code = code }) else b.scrapping[#b.scrapping + 1] = it end
        elseif walkNear(b.player, it.kind, it.north, it.x, it.y, it.z, it.own or {}) == false then
            code = "NO_ROOM"
            resolve(b, b.index[it], code, { code = code })
        else
            ISTimedActionQueue.add(MinidoracatBuilderDismantleAction:new(b.player, b.n, b.index[it]))
        end
        if code then print(LOG .. "dismantle not queued at " .. it.x .. "," .. it.y .. "," .. it.z .. ": " .. code) end
    end
    if b.got >= #b.list and #b.scrapping == 0 then finish(b) end
end

-- 拆一串（一區拆除，或右鍵拆一件）：items[i] = { x, y, z, name（sprite 名稱）, kind, north（格邊種類的方向）, own（同一件
-- 各片所在的格子，走路時不站上去）, route = "builder"（本工具拆）| "scrap"（原版拆解，obj＝物件）, obj }，照拆的順序。
-- builder 的照順序送一筆拆除請求，伺服器收下後兩種動作照 items 的順序一起排（沒有 builder 的不送請求，直接排）。
-- 全部輪完、被拒或停下時呼叫 onDone({ done, total, skipped = { [碼] = 件數 }, refund = { [fullType] = 件數 }, stopped,
-- refused＝整筆被拒的碼或 nil })；沒給 onDone 時自己跳通知。會清掉玩家目前排著的動作、取代還沒輪完的建造或拆除。回 nonce。
function Client.dismantleMany(player, items, onDone)
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
        total = #items, left = #items, got = 0, res = {}, scrapping = {}, onDone = onDone, at = getTimestampMs() }
    Client.pendingUnbuild = b
    Client.pending = nil -- 同上：還沒收下的建造請求作廢
    ISTimedActionQueue.clear(player)
    if #list == 0 then
        queueUnbuild(b)
    elseif isClient() then
        sendClientCommand(player, MODULE, "dismantle", { n = n, t = t })
    else
        MinidoracatBuilder.Server.dismantleIntent(player, { n = n, t = t }) -- 單機：當場回覆（Server.send 直接呼叫 onServerCommand）
    end
    return n
end

-- 拆 obj（本 MOD 蓋的那件，Dismantle.kindOf 是 kind；own＝同一件各片所在的格子）
function Client.dismantle(player, obj, kind, own)
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
    if cmd ~= "accepted" and cmd ~= "refused" and cmd ~= "placed" then return end
    local b = Client.pending
    if cmd == "accepted" and b and b.n == args.n and not b.queued then queue(b) end
    remember(cmd, args)
    if cmd == "refused" then
        print(LOG .. "refused n=" .. tostring(args.n) .. " i=" .. tostring(args.i) .. " code=" .. tostring(args.code))
        if b and b.n == args.n then ISTimedActionQueue.clear(b.player) end
    end
    if Client.onResult then Client.onResult(cmd, args) end
end

Events.OnServerCommand.Add(function(module, command, args)
    if module == MODULE then Client.onServerCommand(command, args or {}) end
end)

-- 伺服器剛放的物件，客戶端收到時引擎先 load 才設格子（IsoObject.java:4432,4448），IsoLightSwitch.load 要有格子的兩段都被跳過
-- （IsoLightSwitch.java:350-379）。本 MOD 蓋的照 load 補上：
--   不能改裝的燈：照 sprite 設顏色。processClient 用預設的白色建光源（AddItemToMapPacket.java:62-64），重新載入區塊才是 sprite
--     的顏色（E2E builder-rooms-1029d）；LightingJNI 下次更新看到顏色變了就送（LightingJNI.java:334-343）。能改裝的燈顏色在封包裡。
--   自建房間裡的開關：switchLight(activated)（:351-352）。沒補的話房間燈停在房間原本的狀態：開關顯示開著、房間卻暗，第一次按
--     看起來沒反應（builder-rooms-1029g）。switchLight 會把房間裡其他燈與開關的 activated 一起改掉（:517-523），同一幀照原值
--     還原（同伺服器 Circuits 的 apply）。地圖房屋的房間燈由伺服器同步，客戶端自己切會和伺服器不一致；沒有房間時切了也看不到
--     （開關的光源不畫，:790-794）。招牌不算開關（Rules.switchProps），不補。
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
    local sq = obj:getSquare()
    local room = sq and sq:isUserDefinedRoom() and sq:getRoom()
    if not room then return end
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
end

Events.OnObjectAdded.Add(onAdded)

return Client
