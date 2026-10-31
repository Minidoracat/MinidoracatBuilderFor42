-- 客戶端：送建造、拆除請求並排動作。第三階段的游標與視窗呼叫 Client.build，右鍵選單（Menu.lua）呼叫 Client.dismantle；
-- 這裡只做請求、排隊、收結果。客戶端的判斷只給畫面用；能不能蓋、扣什麼料、能不能拆、退什麼料都由伺服器重算
-- （Server.intent／Server.complete、Server.dismantleIntent／Server.dismantle）。
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

Client.pending = nil -- 最近送出的請求：{ n, e, d, kind, cells = { { x, y, z }, ... } }
Client.pendingUnbuild = nil -- 最近送出的拆除請求：{ n, x, y, z, e, kind, north, own, player }
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
    Client.pendingUnbuild = nil -- 每人只留一個請求：還沒收下的拆除，收到回覆也不再排
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
        if walkTo(b.player, b.kind, b.spr, c) == false then
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

-- 拆 sq 格上叫 name 的那件（kind 種類；north＝格邊種類的方向；own＝同一件各片所在的格子，走路時不站上去）。先送請求，
-- 伺服器收下才走過去、排動作（同 Client.build）。會清掉玩家目前排著的動作。回 nonce。
local function unbuild(player, sq, name, kind, north, own)
    lastNonce = lastNonce % 2000000000 + 1
    local n = lastNonce
    local args = { n = n, x = sq:getX(), y = sq:getY(), z = sq:getZ(), e = name }
    Client.pendingUnbuild = { n = n, x = args.x, y = args.y, z = args.z, e = args.e, kind = kind,
        north = north, own = own or {}, player = player }
    Client.pending = nil -- 同上：還沒收下的建造請求作廢
    ISTimedActionQueue.clear(player)
    if isClient() then
        sendClientCommand(player, MODULE, "dismantle", args)
    else
        MinidoracatBuilder.Server.dismantleIntent(player, args) -- 單機：當場回覆（Server.send 直接呼叫 onServerCommand）
    end
    return n
end

-- 拆 obj（本 MOD 蓋的那件，Dismantle.kindOf 是 kind；own＝同一件各片所在的格子）
function Client.dismantle(player, obj, kind, own)
    local spr = obj:getSprite()
    return unbuild(player, obj:getSquare(), spr:getName(), kind, Entry.north(kind, spr), own)
end

-- 拆掛在地板上的地面覆蓋（t＝Dismantle.overlay 的結果）
function Client.dismantleOverlay(player, t)
    return unbuild(player, t.sq, t.name, "floorOverlay", nil, {})
end

local function queueUnbuild(b)
    b.queued = true
    if walkNear(b.player, b.kind, b.north, b.x, b.y, b.z, b.own) == false then
        print(LOG .. "no free square next to " .. b.x .. "," .. b.y .. "," .. b.z .. "; dismantle not queued")
        Messages.toast(b.player, Messages.unbuildRefusal("NO_ROOM"), getText("IGUI_MBLD_NotRemoved"))
        return
    end
    ISTimedActionQueue.add(MinidoracatBuilderDismantleAction:new(b.player, b.n))
end

-- dismantleAccepted：{ n }；dismantleRefused：{ n, code, x, y, z, tools }；dismantled：{ n, x, y, z, e }
local UNBUILD = { dismantleAccepted = true, dismantleRefused = true, dismantled = true }
local function onUnbuild(cmd, args)
    local b = Client.pendingUnbuild
    remember(cmd, args)
    if cmd == "dismantleAccepted" then
        if b and b.n == args.n and not b.queued then queueUnbuild(b) end
    elseif cmd == "dismantleRefused" then
        print(LOG .. "dismantle refused n=" .. tostring(args.n) .. " code=" .. tostring(args.code))
        if b and b.n == args.n then ISTimedActionQueue.clear(b.player) end
        if args.code ~= "PERM_DENIED" then -- Safehouse 拒絕時自己推了通知（同 Cursor 的 tell）
            Messages.toast(b and b.player or getSpecificPlayer(0), Messages.unbuildRefusal(args.code, args),
                getText("IGUI_MBLD_NotRemoved"))
        end
    end
end

-- accepted：{ n }；refused：{ n, i（0＝請求本身被拒）, code, x, y, z, need = { fullType = 數量 }, tools = { ItemTag 欄位名 } }；
-- placed：{ n, i }
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
