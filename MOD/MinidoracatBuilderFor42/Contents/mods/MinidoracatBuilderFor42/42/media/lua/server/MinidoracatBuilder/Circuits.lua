-- 線路（第六階段，設計稿「燈與開關」、研究 bt-switch）：本工具蓋的開關控制同一條線路上的燈。只在伺服器（單機在本機跑同一套）。
-- 帳本放在 Ledger 的 GOS 系統（circuits 鍵，跟世界一起存檔、一起回溯；客戶端只拿得到自己查的那一條）：
--   circuits = { next = 下一個編號, c = { [編號] = { s = { [鍵] = true }, l = { [鍵] = true } } } }，鍵＝Ledger.key。
--   一條線路最多 MAX_S 個開關、MAX_L 片燈（多格燈每片各算一片、整組一起進出）；一個開關、一片燈只屬於一條線路。
--   沒有開關的線路刪掉（燈停在當時的狀態）；沒有燈的線路（兩個開關先接成雙切、燈之後才放）按開關時照原版。
--   反查表 byKey 不存，第一次用到時從 c 重建（只有一份真相）。
-- 開關＝帳本裡（本工具蓋的）、sprite 沒有 lightR 的 IsoLightSwitch。燈＝sprite 有 lightR 的 IsoLightSwitch，本工具蓋的或
--   sprite 能搬（IsMoveAble；建構子照它設 canBeModified，IsoLightSwitch.java:76-79）。只認伺服器帳本與 sprite 屬性，不看物件
--   modData 與客戶端改得到的欄位（細節見知識庫 circuits.md）。
-- 按：包原版 ISToggleLightAction 的 complete（點擊、右鍵、手把都走它）。線路裡的開關切整條線路；本工具蓋的燈切自己（不能搬
--   的燈在地圖房屋外原版切不了，IsoLightSwitch.java:497-498）；其他照原版。不要求有電：燈亮不亮由客戶端每片照電力判斷
--   （LightingJNI.java:281-294），伺服器對自建屋一律算沒電（bt-switch §8）。原版開關切房間燈時線路上的燈不跟著動（設計稿）。
-- 接線：客戶端送 circuit（查）／wire（改），身分只認 OnClientCommand 的連線玩家；回 circuit 給那位玩家。改帳本之前先把
--   距離、每一格的建造權限、範圍、上限全部查完，任何一項不過就整筆不做。
if isClient() then return end
require "MinidoracatBuilder/Ledger"
require "MinidoracatBuilder/Check"

MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local Circuits = B.Circuits or {}
B.Circuits = Circuits
local Ledger, Check = B.Ledger, B.Check

local LOG = "[MinidoracatBuilderFor42] "
local MODULE = "MinidoracatBuilder"
local CC = Check.CIRCUIT -- 開關、燈上限與範圍（Check.lua；客戶端說明用同一份）
Circuits.MAX_S, Circuits.MAX_L, Circuits.RANGE, Circuits.LEVELS = CC.MAX_S, CC.MAX_L, CC.RANGE, CC.LEVELS
Circuits.PRESS_REACH = 2 -- 按的人離開關或燈（同一層）
Circuits.PRESS_MS, Circuits.WIRE_MS = 500, 250 -- 同一條線路（或同一盞燈）多久只切一次；同一個人多久只收一個接線指令
Circuits.QUERY_MS, Circuits.QUERY_MAX = 1000, 8 -- 只查一條線路（右鍵燈）另算：每人每 QUERY_MS 最多 QUERY_MAX 個
Circuits.ROOM_MAX = 400 -- 自動接線只認這麼大以內的封閉區域（沒封好的會和室外連成一大片）
Circuits.SYNC_MAX = 4096 -- 按開關後補同步：沿區域最多走幾格（客戶端替封閉、屋頂過半的區域建房間，WorldRegionToMetaGrid.java:183）
Circuits.MAX_CAND = 64 -- 接線模式一次回幾個附近的燈與開關（封包大小）；線路上的成員一定在裡面
Circuits.LOG_MS = 5000 -- 拒絕的 log 每人每個拒絕碼多久最多一行
local USE_OPTS = { label = "MinidoracatBuilder:switch" }

local byKey, idxOf = {}, nil
local lastPress, lastWire, queries, quietUntil = {}, {}, {}, {} -- ponytail：不清；每條按過的線路、每個接過線的人一筆

local function now() return getTimestampMs() end

-- 冷卻：上一次在 interval 內就擋。時鐘往回跳時不擋（pitfalls「getTimestampMs 會往回跳」）
local function cooling(last, t, interval)
    return last ~= nil and t >= last and t - last < interval
end

-- 帳本（沒有 GOS 系統時 nil）。換了表（開服、熱重載）就重建反查表
local function data()
    local inst = Ledger.instance
    if not inst then return nil end
    if type(inst.circuits) ~= "table" then inst.circuits = { next = 1, c = {} } end
    local d = inst.circuits
    if type(d.c) ~= "table" then d.c = {} end
    if type(d.next) ~= "number" then d.next = 1 end
    if idxOf ~= d then
        byKey = {}
        for id, c in pairs(d.c) do
            for k in pairs(c.s) do byKey[k] = id end
            for k in pairs(c.l) do byKey[k] = id end
        end
        idxOf = d
    end
    return d
end
Circuits.data = data

local function count(set)
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    return n
end

local function keys(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    return out
end

local function concat(a, b)
    local out = {}
    for _, k in ipairs(a) do out[#out + 1] = k end
    for _, k in ipairs(b) do out[#out + 1] = k end
    return out
end

-- "x,y,z,sprite" → x, y, z, sprite
local function parse(k)
    local x, y, z, name = string.match(k, "^(%-?%d+),(%-?%d+),(%-?%d+),(.+)$")
    if not x then return nil end
    return tonumber(x), tonumber(y), tonumber(z), name
end

local function objOn(sq, name)
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local spr = instanceof(o, "IsoLightSwitch") and o:getSprite()
        if spr and spr:getName() == name then return o end
    end
    return nil
end

-- 鍵 → 物件, 格子有沒有載入（鍵壞了算載入：照找不到剔除）
local function resolve(k)
    local x, y, z, name = parse(k)
    if not x then return nil, true end
    local sq = getCell():getGridSquare(x, y, z)
    if not sq then return nil, false end
    return objOn(sq, name), true
end

local function props(o)
    local spr = o:getSprite()
    return spr and spr:getProperties()
end

local function lit(o)
    local p = props(o)
    return p ~= nil and p:has("lightR")
end

function Circuits.isSwitch(o)
    if not instanceof(o, "IsoLightSwitch") then return false end
    local p = props(o)
    return p ~= nil and not p:has("lightR") and Ledger.get(o) ~= nil
end

function Circuits.isLamp(o)
    if not instanceof(o, "IsoLightSwitch") then return false end
    local p = props(o)
    return p ~= nil and p:has("lightR") and (p:has("IsMoveAble") or Ledger.get(o) ~= nil)
end

-- 一盞燈的每一片（同一組的燈；switchLight 連動多格用 setActive，不能搬的片會被擋，IsoLightSwitch.java:542-556）
local function pieces(o)
    local out = {}
    local list = o:getSpriteGridObjectsIncludingSelf(ArrayList.new())
    for i = 0, list:size() - 1 do
        local p = list:get(i)
        if (p == o or o:isConnectedSpriteGridObject(p)) and Circuits.isLamp(p) then out[#out + 1] = p end
    end
    if #out == 0 then out[1] = o end
    return out
end

local function pieceKeys(o)
    local out = {}
    for _, p in ipairs(pieces(o)) do
        local k = Ledger.key(p)
        if k then out[#out + 1] = k end
    end
    return out
end

-- 這把鍵所在、還有開關的線路編號
local function live(d, k)
    local id = k and byKey[k]
    if id and d.c[id] then return id end
    return nil
end

-- 從線路拿掉一個鍵；線路沒有開關了就整條刪掉
local function drop(d, k)
    local id = byKey[k]
    if not id then return end
    byKey[k] = nil
    local c = d.c[id]
    if not c then return end
    c.s[k], c.l[k] = nil, nil
    if count(c.s) == 0 then
        for lk in pairs(c.l) do byKey[lk] = nil end
        d.c[id] = nil
    end
end

local function put(d, id, set, k)
    if byKey[k] and byKey[k] ~= id then drop(d, k) end
    d.c[id][set][k] = true
    byKey[k] = id
end

-- 新線路，開關是 sKeys（每個先從舊線路拿掉）。只在整筆操作都查過、要寫入時呼叫
local function newCircuit(d, sKeys)
    local id = d.next
    d.next = id + 1
    d.c[id] = { s = {}, l = {} }
    for _, k in ipairs(sKeys) do put(d, id, "s", k) end
    return id
end

-- 兩把鍵的距離在範圍內（水平各軸 RANGE、樓層差 LEVELS）
local function within(a, b)
    local ax, ay, az = parse(a)
    local bx, by, bz = parse(b)
    return ax ~= nil and bx ~= nil and math.abs(ax - bx) <= Circuits.RANGE and math.abs(ay - by) <= Circuits.RANGE
        and math.abs(az - bz) <= Circuits.LEVELS
end

-- 開關兩兩之間、每片燈和每個開關都在範圍內（鍵比座標，不必載入）
local function fits(sKeys, lKeys)
    for i, sk in ipairs(sKeys) do
        for j = i + 1, #sKeys do
            if not within(sk, sKeys[j]) then return false end
        end
        for _, lk in ipairs(lKeys) do
            if not within(sk, lk) then return false end
        end
    end
    return true
end

-- 線路裡現在找得到的物件（開關在前、燈在後）。格子載入了卻找不到（或已經不是開關／燈）就剔除（當機回溯、漏掉的移除事件）；
-- 沒載入的保留、記數
local function members(d, id)
    local c = id and d.c[id]
    local sw, lamps, gone, skipped = {}, {}, {}, 0
    if not c then return sw, lamps, 0 end
    for k in pairs(c.s) do
        local o, loaded = resolve(k)
        if o and Circuits.isSwitch(o) then sw[#sw + 1] = o elseif loaded then gone[#gone + 1] = k else skipped = skipped + 1 end
    end
    for k in pairs(c.l) do
        local o, loaded = resolve(k)
        if o and Circuits.isLamp(o) then lamps[#lamps + 1] = o elseif loaded then gone[#gone + 1] = k else skipped = skipped + 1 end
    end
    for _, k in ipairs(gone) do drop(d, k) end
    return sw, lamps, skipped
end

local function server() return B.Server end

-- 伺服器 → 一位玩家（單機直接交給客戶端程式，同 Server.send）。who＝操作的人（客戶端照它找本機玩家）
function Circuits.send(player, args)
    if isServer() then
        sendServerCommand(player, MODULE, "circuit", args)
    elseif B.Wiring then
        B.Wiring.onServerCommand("circuit", args, player)
    end
end

local function useDenied(player, x, y, z)
    local api = MinidoracatSafehouse and MinidoracatSafehouse.v1
    return api ~= nil and api.API_MAJOR == 1 and type(api.CAPABILITIES) == "table" and api.CAPABILITIES.denies == true
        and api.denies(player, x, y, z, api.BITS.USE, USE_OPTS) == true
end

-- 每一把鍵那格的 BUILD 權限（原版安全屋＋Safehouse，同拆除，不看 WhereCanBuild）。格子沒載入就不做（NOT_LOADED）。
-- preview＝true 不寫稽核、不推通知（自動接線用）。回第一個拒絕碼或 nil
local function deniedKeys(player, ks, preview)
    local cell = getCell()
    for _, k in ipairs(ks) do
        local x, y, z = parse(k)
        local sq = x and cell:getGridSquare(x, y, z)
        if not sq then return "NOT_LOADED" end
        local why = Check.safehouse(player, { x = x, y = y, z = z, sq = sq }, preview, "wire")
        if why then return why end
    end
    return nil
end

-- ---------------------------------------------------------------- 區域（自動接線、同步）

-- 那一格的區域編號與區域；isEnclosed 為真才回（small＝true 時還要不超過 ROOM_MAX 格）。編號會變（IsoRegionManager.java:26），
-- 只在這一次比
local function roomOf(x, y, z, small)
    local r = IsoRegions.getIsoWorldRegion(x, y, z)
    if not (r and r:isEnclosed()) then return nil end
    if small and r:getSquareSize() > Circuits.ROOM_MAX then return nil end
    return r:getID(), r
end

local function sameRegion(rid, x, y, z)
    local r = IsoRegions.getIsoWorldRegion(x, y, z)
    return r ~= nil and r:getID() == rid
end

-- 同一層、RANGE 格內、同一個區域裡的每個 IsoLightSwitch（自動接線）
local function roomObjects(sx, sy, z, rid)
    local out, cell, R = {}, getCell(), Circuits.RANGE
    for y = sy - R, sy + R do
        for x = sx - R, sx + R do
            local sq = cell:getGridSquare(x, y, z)
            local objs = sq and sq:getObjects()
            local inRoom
            for i = 0, (objs and objs:size() or 0) - 1 do
                local o = objs:get(i)
                if instanceof(o, "IsoLightSwitch") then
                    if inRoom == nil then inRoom = sameRegion(rid, x, y, z) end
                    if inRoom then out[#out + 1] = o end
                end
            end
        end
    end
    return out
end

-- roomObjects 裡可接的燈與本工具的開關。回 lamps, switches
local function roomScan(sx, sy, z, rid)
    local lamps, switches = {}, {}
    for _, o in ipairs(roomObjects(sx, sy, z, rid)) do
        if Circuits.isLamp(o) then lamps[#lamps + 1] = o elseif Circuits.isSwitch(o) then switches[#switches + 1] = o end
    end
    return lamps, switches
end

-- 從 sq 沿四鄰走同一個封閉區域（同一層），收每個 IsoLightSwitch 到 out（seen 去重）。最多走 SYNC_MAX 格；
-- 走不完回 true。visited 每個區域各一份：別的區域的邊界格不能擋住下一個區域
local function regionObjects(sq, rid, out, seen)
    local cell = getCell()
    local z = sq:getZ()
    local queue, head, visited = { sq }, 1, { [sq] = true }
    local steps = 0
    while head <= #queue and steps < Circuits.SYNC_MAX do
        local s = queue[head]
        head = head + 1
        steps = steps + 1
        local objs = s:getObjects()
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            if instanceof(o, "IsoLightSwitch") and not seen[o] then
                seen[o] = true
                out[#out + 1] = o
            end
        end
        local x, y = s:getX(), s:getY()
        for d = 1, 4 do
            local nx, ny = x + (d == 1 and 1 or d == 2 and -1 or 0), y + (d == 3 and 1 or d == 4 and -1 or 0)
            local n = cell:getGridSquare(nx, ny, z)
            if n and not visited[n] then
                visited[n] = true
                if sameRegion(rid, nx, ny, z) then queue[#queue + 1] = n end
            end
        end
    end
    return head <= #queue
end

-- 客戶端會替這個區域建自建房間、讓開關連動整間的才要還原：地圖房屋（有 room、不是自建）照原版整間連動；
-- 屋頂不到一半的區域客戶端不建房間（WorldRegionToMetaGrid.java:183）
local function cascades(sq, r)
    if sq:getRoom() ~= nil and not sq:isUserDefinedRoom() then return false end
    local n = r:getSquareSize()
    return n > 0 and r:getRoofCnt() / n >= 0.5
end

-- ---------------------------------------------------------------- 按

-- 把 list 切成 v。開關不用燈泡（沒燈泡也照樣切，不然拿掉燈泡的開關只開不關）；燈沒燈泡的照原版當成關
-- （IsoLightSwitch.java:490-493）。先把每個物件的狀態設好，再逐一 switchLight 並同步給附近玩家（開關在前；多格燈的其他片
-- 已經是 v，不會再連動）。
-- 客戶端替封閉的自建房間建的房間把房間裡每個 IsoLightSwitch（燈與開關都算）收進 lightSwitches（WorldRegionToMetaGrid.java:
-- 631-632），開關 switchLight 時把它們的 activated 全改成開關的狀態（IsoLightSwitch.java:517-523）。單機的世界只有一份，
-- MP 的客戶端收到開關同步時也會這樣改，伺服器那份不變（builder-circuits-1029b）。所以（只在 cascades 的區域）：
--   先記下同一個區域裡不在名單上的物件（沿區域走，不受 RANGE、ROOM_MAX 限制），切完後狀態變了的照記下的還原（單機），
--   燈再照伺服器狀態同步一次（MP 客戶端，封包照順序到）。別條線路的開關在 MP 客戶端上會被蓋掉、沒辦法用封包還原
--   （開關的同步又會再改整間房），伺服器的狀態是對的，下一次按照伺服器算。
local function apply(list, v)
    local switches, lamps, done = {}, {}, {}
    for _, o in ipairs(list) do
        if not done[o] then
            done[o] = true
            if lit(o) then
                o:setActivated(v and o:hasLightBulb())
                lamps[#lamps + 1] = o
            else
                o:setActivated(v)
                switches[#switches + 1] = o
            end
        end
    end
    local others, scanned, seen = {}, {}, {}
    for o in pairs(done) do seen[o] = true end
    for _, o in ipairs(switches) do
        local sq = o:getSquare()
        local rid, r
        if sq then rid, r = roomOf(sq:getX(), sq:getY(), sq:getZ(), false) end
        if rid and not scanned[rid] and cascades(sq, r) then
            scanned[rid] = true
            if regionObjects(sq, rid, others, seen) then
                print(LOG .. "CIRCUIT sync truncated at=" .. sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ()
                    .. " max=" .. Circuits.SYNC_MAX)
            end
        end
    end
    local saved = {}
    for i, o in ipairs(others) do saved[i] = o:isActivated() end
    for _, group in ipairs({ switches, lamps }) do
        for _, o in ipairs(group) do
            local on = o:isActivated()
            o:switchLight(on)
            o:syncIsoObject(false, on and 1 or 0, nil, nil)
        end
    end
    for i, o in ipairs(others) do
        local was = saved[i]
        if o:isActivated() ~= was then
            o:setActivated(was)
            if lit(o) then o:switchLight(was) end
        end
        if lit(o) then o:syncIsoObject(false, was and 1 or 0, nil, nil) end
    end
end

-- 併進線路的開關跟 ref（線路上原有的開關）同一個狀態：按的時候新狀態＝不是被按的那個開關的狀態，不對齊的話
-- 第一次按新開關燈不會動。只動開關，燈不動。
local function align(ref, swKeys)
    local list = {}
    for _, k in ipairs(swKeys) do
        local o = resolve(k)
        if o and o ~= ref and o:isActivated() ~= ref:isActivated() then list[#list + 1] = o end
    end
    if #list > 0 then apply(list, ref:isActivated()) end
end

-- 按開關（id＝線路編號）或本工具蓋的燈（id＝nil）。順序：距離（同一層、PRESS_REACH 格內）→ Safehouse 的 USE
-- （拒絕時它自己推通知；我們的 complete 不呼叫原版，包在內層的 Safehouse 不會跑）→ 冷卻 → 切。回 complete 的結果。
function Circuits.press(player, obj, id)
    local sq = obj:getSquare()
    if not (player and sq) then return false end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local reach = Circuits.PRESS_REACH
    if math.abs(math.floor(player:getX()) - x) > reach or math.abs(math.floor(player:getY()) - y) > reach
        or math.floor(player:getZ()) ~= z then
        return false
    end
    if useDenied(player, x, y, z) then return false end
    local k = id or Ledger.key(obj)
    local t = now()
    if cooling(lastPress[k], t, Circuits.PRESS_MS) then return false end
    lastPress[k] = t
    local list, skipped = nil, 0
    local d = data()
    if id and d then
        local sw, lamps
        sw, lamps, skipped = members(d, id)
        list = concat(sw, lamps)
    else
        list = pieces(obj)
    end
    local v = not obj:isActivated()
    apply(list, v)
    print(LOG .. "CIRCUIT press user=" .. server().who(player) .. " at=" .. x .. "," .. y .. "," .. z .. " id=" .. tostring(id)
        .. " on=" .. tostring(v) .. " objects=" .. #list .. " skipped=" .. skipped)
    if skipped > 0 then Circuits.send(player, { note = "UNLOADED", n = skipped, who = player:getOnlineID() }) end
    return true
end

-- ISToggleLightAction:complete() 的本工具部分。回 nil＝不是本工具的，照原版。認定是本工具的就在動作上記 mbldClaimed
-- （包裝看到出錯時不再呼叫原版，不會切兩次）
function Circuits.onToggle(action)
    local obj = action.object
    if not (instanceof(obj, "IsoLightSwitch") and Ledger.get(obj)) then return nil end
    if Circuits.isLamp(obj) then
        action.mbldClaimed = true
        return Circuits.press(action.character, obj, nil)
    end
    local d = data()
    local id = d and live(d, Ledger.key(obj))
    -- 沒接線、或線路上還沒有燈的開關照原版（在地圖房屋裡切整間房）
    if not id or count(d.c[id].l) == 0 then return nil end
    action.mbldClaimed = true
    return Circuits.press(action.character, obj, id)
end

-- 移出世界前（拿起、砸、拆都會觸發；Ledger.lua 同一個事件）
function Circuits.forget(obj)
    local d, k = data(), Ledger.key(obj)
    if d and k then drop(d, k) end
end

-- ---------------------------------------------------------------- 自動接線

-- 加燈之前查：fresh＝還不在 id 這條的片數。回 nil 或 FULL／OUT_OF_RANGE
local function lampFits(sKeys, lampCount, pk, fresh)
    if lampCount + fresh > Circuits.MAX_L then return "FULL" end
    if not fits(sKeys, pk) then return "OUT_OF_RANGE" end
    return nil
end

-- 房間裡的開關分成幾組（同一條線路算一組，沒接線的各算一組）
local function groupsOf(d, switches)
    local seen, n = {}, 0
    for _, o in ipairs(switches) do
        local k = Ledger.key(o)
        local g = live(d, k) or k
        if g and not seen[g] then
            seen[g] = true
            n = n + 1
        end
    end
    return n
end

-- 開關放下或按「接同一房間」：同一個封閉房間裡、還沒接在別條線路的燈接上。開關自己還沒有線路時，房間裡另一個開關的線路
-- 放得下就併進去（雙切）；都沒有線路的話和房間裡另一個開關接成一條。別條線路的燈不搶、只記數。每片燈、被併的開關與
-- 成員都照預覽查 BUILD（不寫稽核；沒權限的跳過），全部查完才寫入。
-- 回 code（NOT_ENCLOSED／INTERNAL）或 nil, { id（沒有線路時 nil）, n = 接上幾片, taken = 別條線路的幾盞, skipped = 太遠、
-- 線路滿了或沒權限的幾盞, jx, jy = 併進的那個開關, later = 之後放進房間的燈會自動接上 }
function Circuits.autoWire(player, sw)
    local d = data()
    if not d then return "INTERNAL" end
    local sq = sw:getSquare()
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local rid = roomOf(x, y, z, true)
    if not rid then return "NOT_ENCLOSED" end
    local lamps, switches = roomScan(x, y, z, rid)
    local swKey = Ledger.key(sw)
    local id = live(d, swKey)
    local info = { n = 0, taken = 0, skipped = 0 }
    -- 規劃：要併進的線路（或要配對的開關）
    local joinId, joinRef, pair, sKeys, lampCount
    if id then
        sKeys, lampCount = keys(d.c[id].s), count(d.c[id].l)
    else
        for _, o in ipairs(switches) do
            local ok = Ledger.key(o)
            local oid = o ~= sw and live(d, ok)
            if oid and not joinId then
                local oc = d.c[oid]
                local s2 = concat(keys(oc.s), { swKey })
                if #s2 <= Circuits.MAX_S and fits(s2, keys(oc.l))
                    and not deniedKeys(player, concat(keys(oc.s), keys(oc.l)), true) then
                    joinId, joinRef, sKeys, lampCount = oid, o, s2, count(oc.l)
                    info.jx, info.jy = o:getSquare():getX(), o:getSquare():getY()
                end
            end
        end
        if not joinId then
            for _, o in ipairs(switches) do
                local ok = Ledger.key(o)
                if not pair and o ~= sw and not live(d, ok) and fits({ ok, swKey }, {})
                    and not deniedKeys(player, { ok }, true) then
                    pair = o
                    info.jx, info.jy = o:getSquare():getX(), o:getSquare():getY()
                end
            end
            sKeys = pair and { Ledger.key(pair), swKey } or { swKey }
            lampCount = 0
        end
    end
    local target = id or joinId
    local add, seen = {}, {}
    for _, lamp in ipairs(lamps) do
        local lk = Ledger.key(lamp)
        if lk and not seen[lk] then
            local pk = pieceKeys(lamp)
            for _, k in ipairs(pk) do seen[k] = true end
            local lid = live(d, lk)
            if lid and lid ~= target then
                info.taken = info.taken + 1
            elseif not lid then
                if deniedKeys(player, pk, true) or lampFits(sKeys, lampCount, pk, #pk) then
                    info.skipped = info.skipped + 1
                else
                    add[#add + 1] = pk
                    lampCount = lampCount + #pk
                end
            end
        end
    end
    -- 寫入（沒有燈、也沒有開關可以配對時不建線路）
    if not id then
        if joinId then
            put(d, joinId, "s", swKey)
            id = joinId
            align(joinRef, { swKey })
        elseif pair or #add > 0 then
            id = newCircuit(d, sKeys)
            if pair then align(pair, { swKey }) end
        end
    end
    for _, pk in ipairs(add) do
        for _, k in ipairs(pk) do put(d, id, "l", k) end
        info.n = info.n + #pk
    end
    info.id = id
    info.later = groupsOf(d, switches) <= 1
    return nil, info
end

-- 燈放下：同一個封閉房間裡的開關只有一組（一條線路，或只有一個沒接線的開關）就接進去（bt-switch §2.3 第 4 步）。
-- 要接的開關（新線路就是那一個，既有線路就是那條的每個開關）照預覽查 BUILD，被拒就不接。
-- 回線路編號；沒接上而房間裡（燈的 RANGE 格內）有本工具的開關時回 nil, 原因（MULTI／FULL／OUT_OF_RANGE／DENIED）
function Circuits.lampPlaced(player, lamp)
    local d = data()
    if not d then return nil end
    local sq = lamp:getSquare()
    local rid = roomOf(sq:getX(), sq:getY(), sq:getZ(), true)
    if not rid then return nil end
    local _, switches = roomScan(sq:getX(), sq:getY(), sq:getZ(), rid)
    if #switches == 0 then return nil end
    if groupsOf(d, switches) ~= 1 then return nil, "MULTI" end
    local k0 = Ledger.key(switches[1])
    local id = live(d, k0)
    local pk = pieceKeys(lamp)
    local fresh = 0
    for _, k in ipairs(pk) do if not id or byKey[k] ~= id then fresh = fresh + 1 end end
    if fresh == 0 then return nil end
    local sKeys = id and keys(d.c[id].s) or { k0 }
    local why = lampFits(sKeys, id and count(d.c[id].l) or 0, pk, fresh)
    if why then return nil, why end
    if deniedKeys(player, sKeys, true) then return nil, "DENIED" end
    id = id or newCircuit(d, { k0 })
    for _, k in ipairs(pk) do put(d, id, "l", k) end
    return id
end

-- ---------------------------------------------------------------- 回覆

local function entry(k)
    local x, y, z, e = parse(k)
    return { x = x, y = y, z = z, e = e }
end

local function sideList(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = entry(k) end
    return out
end

-- 開關附近（RANGE 格、上下 LEVELS 層）可接的燈與本工具的開關：{ x, y, z, e, k = "l"／"s", c = 線路編號或 nil }。
-- 這條線路的成員先放（一定在），再從同一層、由近到遠（一圈一圈）收，收滿 MAX_CAND 就停。不在線路上、那格沒有
-- BUILD 權限的不列（預覽，不寫稽核）。
local function candidates(player, d, sw)
    local out, seen, cell, R, L = {}, { [sw] = true }, getCell(), Circuits.RANGE, Circuits.LEVELS
    local id = live(d, Ledger.key(sw))
    local function add(o, kind)
        seen[o] = true
        local s = o:getSquare()
        out[#out + 1] = { x = s:getX(), y = s:getY(), z = s:getZ(), e = o:getSprite():getName(), k = kind, c = live(d, Ledger.key(o)) }
    end
    if id then
        local ms, ml = members(d, id)
        for _, o in ipairs(ms) do if not seen[o] then add(o, "s") end end
        for _, o in ipairs(ml) do if not seen[o] then add(o, "l") end end
    end
    local sq = sw:getSquare()
    local sx, sy, sz = sq:getX(), sq:getY(), sq:getZ()
    local function scan(x, y, z)
        local s = cell:getGridSquare(x, y, z)
        local objs = s and s:getObjects()
        for i = 0, (objs and objs:size() or 0) - 1 do
            if #out >= Circuits.MAX_CAND then return end
            local o = objs:get(i)
            if not seen[o] and instanceof(o, "IsoLightSwitch") then
                local kind = (Circuits.isLamp(o) and "l") or (Circuits.isSwitch(o) and "s") or nil
                if kind and not deniedKeys(player, { Ledger.key(o) }, true) then add(o, kind) else seen[o] = true end
            end
        end
    end
    local zs = { sz }
    for dz = 1, L do
        zs[#zs + 1] = sz - dz
        zs[#zs + 1] = sz + dz
    end
    for _, z in ipairs(zs) do
        for r = 0, R do
            for dy = -r, r do
                for dx = -r, r do
                    if #out >= Circuits.MAX_CAND then return out end
                    if math.abs(dx) == r or math.abs(dy) == r then scan(sx + dx, sy + dy, z) end
                end
            end
        end
    end
    return out
end

-- 回給玩家的那一條線路：{ q, who, id, s = { 開關 }, l = { 燈 }, cand（要的話）}
local function reply(player, q, d, id, extra, sw, cand)
    local c = d and id and d.c[id]
    local args = { q = q, who = player:getOnlineID(), id = c and id or nil, s = c and sideList(c.s) or {},
        l = c and sideList(c.l) or {} }
    for k, v in pairs(extra or {}) do args[k] = v end
    if cand and sw and d then args.cand = candidates(player, d, sw) end
    Circuits.send(player, args)
end

-- 拒絕：回碼（extra.side＝"t"／"l" 表示是目標或線路上的燈出錯，不是開關本身）。log 每人每個碼 LOG_MS 最多一行，限流不記
local function refuse(player, q, code, extra)
    local k, t = server().keyOf(player) .. ":" .. code, now()
    if code ~= "RATE_LIMITED" and not cooling(quietUntil[k], t, Circuits.LOG_MS) then
        quietUntil[k] = t
        print(LOG .. "CIRCUIT refuse user=" .. server().who(player) .. " code=" .. code)
    end
    local args = { code = code }
    for key, v in pairs(extra or {}) do args[key] = v end
    reply(player, q, nil, nil, args)
    return false
end

-- 放好一項燈（Server.complete 收尾後）：開關自動接線，燈接進房間裡唯一的線路；結果推給蓋的人（燈沒接上也說原因）
function Circuits.placed(player, objs)
    local first = objs[1]
    if not first then return end
    local d = data()
    if Circuits.isSwitch(first) then
        local code, info = Circuits.autoWire(player, first)
        if code then return reply(player, nil, d, nil, { auto = "switch", code = code }) end
        print(LOG .. "CIRCUIT auto user=" .. server().who(player) .. " id=" .. tostring(info.id) .. " lamps=" .. info.n
            .. " taken=" .. info.taken .. " skipped=" .. info.skipped .. " joined=" .. tostring(info.jx ~= nil))
        return reply(player, nil, d, info.id, { auto = "switch", n = info.n, taken = info.taken, skipped = info.skipped,
            jx = info.jx, jy = info.jy, later = info.later })
    elseif Circuits.isLamp(first) then
        local id, miss = Circuits.lampPlaced(player, first)
        if id then
            reply(player, nil, d, id, { auto = "lamp" })
        elseif miss then
            reply(player, nil, d, nil, { auto = "lamp", miss = miss })
        end
    end
end

-- ---------------------------------------------------------------- 客戶端指令

local OPS = { add = true, remove = true, join = true, room = true, clear = true, unplug = true }
local TARGET = { add = true, remove = true, join = true }

-- prefix＝""（x, y, z, e）或 "t"（tx, ty, tz, te）
local function target(args, prefix)
    local int = server().int
    return int(args[prefix .. "x"], 0, 1000000), int(args[prefix .. "y"], 0, 1000000), int(args[prefix .. "z"], -32, 31),
        args[prefix .. "e"]
end

-- (x, y, z, e) 的 IsoLightSwitch；回 obj 或 nil, code
local function find(x, y, z, e)
    if not (x and y and z) or type(e) ~= "string" or #e > 128 then return nil, "BAD_REQUEST" end
    local sq = getCell():getGridSquare(x, y, z)
    if not sq then return nil, "NOT_LOADED" end
    local o = objOn(sq, e)
    if not o then return nil, "GONE" end
    return o
end

local function near(player, o)
    local s = o:getSquare()
    return math.abs(math.floor(player:getX()) - s:getX()) <= Circuits.RANGE
        and math.abs(math.floor(player:getY()) - s:getY()) <= Circuits.RANGE
        and math.abs(math.floor(player:getZ()) - s:getZ()) <= Circuits.LEVELS
end

-- 各操作：先查完、再寫入。回 code 或 nil, extra, id（寫入後開關所在的線路）
local OP = {}

-- 燈（整組）加進開關的線路（沒有線路就這時才建）
function OP.add(player, d, id, swKey, lamp)
    if not Circuits.isLamp(lamp) then return "NOT_WIRABLE" end
    local pk = pieceKeys(lamp)
    local why = deniedKeys(player, pk, false)
    if why then return why end
    local fresh, moved = 0, false
    for _, k in ipairs(pk) do
        if not id or byKey[k] ~= id then fresh = fresh + 1 end
        if byKey[k] and byKey[k] ~= id then moved = true end
    end
    if fresh == 0 then return nil, {}, id end
    why = lampFits(id and keys(d.c[id].s) or { swKey }, id and count(d.c[id].l) or 0, pk, fresh)
    if why then return why end
    id = id or newCircuit(d, { swKey })
    for _, k in ipairs(pk) do put(d, id, "l", k) end
    return nil, { moved = moved or nil }, id
end

function OP.remove(player, d, id, _, lamp)
    if not Circuits.isLamp(lamp) then return "NOT_WIRABLE" end
    local pk, mine = pieceKeys(lamp), {}
    for _, k in ipairs(pk) do if id and byKey[k] == id then mine[#mine + 1] = k end end
    if #mine == 0 then return "NOT_WIRED" end
    local why = deniedKeys(player, pk, false)
    if why then return why end
    for _, k in ipairs(mine) do drop(d, k) end
    return nil, {}, id
end

-- 另一個開關：不在這條線路就併進來（雙切；它原本的線路整條併進來），已經在就拿掉。對方的開關與對方線路的每個成員
-- 都要 BUILD；併完開關兩兩、每盞燈和每個開關都要在範圍內
function OP.join(player, d, id, swKey, other, sw)
    if not Circuits.isSwitch(other) then return "NOT_SWITCH" end
    local ok = Ledger.key(other)
    if ok == swKey then return "BAD_REQUEST" end
    local oid = live(d, ok)
    if id and oid == id then
        local why = deniedKeys(player, { ok }, false)
        if why then return why end
        drop(d, ok)
        return nil, {}, id
    end
    local oc = oid and d.c[oid]
    local oS, oL = oc and keys(oc.s) or { ok }, oc and keys(oc.l) or {}
    local why = deniedKeys(player, concat(oS, oL), false)
    if why then return why end
    local sKeys = concat(id and keys(d.c[id].s) or { swKey }, oS)
    local lKeys = concat(id and keys(d.c[id].l) or {}, oL)
    if #sKeys > Circuits.MAX_S or #lKeys > Circuits.MAX_L then return "FULL" end
    if not fits(sKeys, lKeys) then return "OUT_OF_RANGE" end
    id = id or newCircuit(d, { swKey })
    for _, k in ipairs(oS) do put(d, id, "s", k) end -- 原線路最後一個開關移走時 drop 會刪掉那條（燈的反查一起清）
    for _, k in ipairs(oL) do put(d, id, "l", k) end
    align(sw, oS)
    return nil, { moved = oc and true or nil }, id
end

function OP.clear(player, d, id)
    if not id then return nil, {}, nil end
    local lk = keys(d.c[id].l)
    local why = deniedKeys(player, lk, false)
    if why then return why end
    for _, k in ipairs(lk) do drop(d, k) end
    return nil, {}, id
end

function OP.room(player, _, _, _, _, sw)
    local code, info = Circuits.autoWire(player, sw)
    if code then return code end
    return nil, { n = info.n, taken = info.taken, skipped = info.skipped, jx = info.jx, jy = info.jy, later = info.later }, info.id
end

-- wire：{ q, op, x, y, z, e（開關；unplug 時是燈）, tx, ty, tz, te（add／remove 的燈、join 的開關）, cand }
local function wire(player, q, args, d)
    local op = args.op
    if not OPS[op] then return refuse(player, q, "BAD_REQUEST") end
    local sx, sy, sz, se = target(args, "")
    local obj, code = find(sx, sy, sz, se)
    if not obj then return refuse(player, q, code) end
    if not near(player, obj) then return refuse(player, q, "TOO_FAR") end
    code = deniedKeys(player, { Ledger.key(obj) }, false)
    if code then return refuse(player, q, code) end
    local id, extra
    if op == "unplug" then
        if not Circuits.isLamp(obj) then return refuse(player, q, "NOT_WIRABLE") end
        id = live(d, Ledger.key(obj))
        if not id then return refuse(player, q, "NOT_WIRED") end
        local pk, mine = pieceKeys(obj), {}
        for _, k in ipairs(pk) do if byKey[k] == id then mine[#mine + 1] = k end end
        code = deniedKeys(player, pk, false)
        if code then return refuse(player, q, code) end
        for _, k in ipairs(mine) do drop(d, k) end
        extra = { op = op }
    else
        if not Circuits.isSwitch(obj) then return refuse(player, q, "NOT_SWITCH") end
        local swKey = Ledger.key(obj)
        id = live(d, swKey)
        if id then members(d, id) end
        id = live(d, swKey)
        local t
        if TARGET[op] then
            local tx, ty, tz, te = target(args, "t")
            t, code = find(tx, ty, tz, te)
            if not t then return refuse(player, q, code, { side = "t" }) end
            if not near(player, t) then return refuse(player, q, "TOO_FAR", { side = "t" }) end
        end
        code, extra, id = OP[op](player, d, id, swKey, t, obj)
        if code then return refuse(player, q, code, { side = TARGET[op] and "t" or op == "clear" and "l" or nil }) end
        extra.op = op
    end
    print(LOG .. "CIRCUIT wire user=" .. server().who(player) .. " op=" .. op .. " at=" .. sx .. "," .. sy .. "," .. sz
        .. " id=" .. tostring(id))
    reply(player, q, d, id and d.c[id] and id or nil, extra, Circuits.isSwitch(obj) and obj or nil, args.cand == true)
    return true
end

-- circuit：{ q, x, y, z, e, cand }。開關回它的線路（cand＝true 再附近可接的）；燈回控制它的那條線路
local function query(player, q, args, d)
    local x, y, z, e = target(args, "")
    local obj, code = find(x, y, z, e)
    if not obj then return refuse(player, q, code) end
    if not near(player, obj) then return refuse(player, q, "TOO_FAR") end
    local isSw = Circuits.isSwitch(obj)
    if not (isSw or Circuits.isLamp(obj)) then return refuse(player, q, "NOT_WIRABLE") end
    local id = live(d, Ledger.key(obj))
    if id then members(d, id) end
    id = live(d, Ledger.key(obj))
    reply(player, q, d, id, nil, isSw and obj or nil, isSw and args.cand == true)
    return true
end

-- 只查一條、不要附近清單的 circuit（右鍵燈，一格可能好幾盞）另算額度：每 QUERY_MS 最多 QUERY_MAX 個
local function queryOk(k, t)
    local w = queries[k]
    if not w or t < w.t0 or t - w.t0 >= Circuits.QUERY_MS then
        queries[k] = { t0 = t, n = 1 }
        return true
    end
    w.n = w.n + 1
    return w.n <= Circuits.QUERY_MAX
end

-- OnClientCommand（Server.lua 分派）與單機客戶端直接呼叫。q＝客戶端的請求編號，原樣帶回
function Circuits.command(player, cmd, args)
    if type(args) ~= "table" then return end
    local S = server()
    local q = S.int(args.q, 1, 2147483647)
    if not q then return end
    local k, t = S.keyOf(player), now()
    if cmd == "circuit" and args.cand ~= true then
        if not queryOk(k, t) then return refuse(player, q, "RATE_LIMITED") end
    else
        if cooling(lastWire[k], t, Circuits.WIRE_MS) then return refuse(player, q, "RATE_LIMITED") end
        lastWire[k] = t
    end
    local why = S.notAllowed(player)
    if why then return refuse(player, q, why) end
    local d = data()
    if not d then return refuse(player, q, "INTERNAL") end
    if cmd == "wire" then return wire(player, q, args, d) end
    return query(player, q, args, d)
end

-- 包原版開關燈動作（設計稿：只包這一個）。在類別上換 complete，伺服器照 rawget→metatable 取得到
-- （MinidoracatSafehouse Permissions.lua:4-8）；原函式只取一次（熱重載不重包），實作經模組表呼叫。
-- 出錯時：還沒認定是本工具的就照原版做（不讓本工具的錯擋住原版的燈）；已經認定（可能切到一半）就不再呼叫原版。
if ISToggleLightAction and not B.toggleComplete then
    B.toggleComplete = ISToggleLightAction.complete
    ISToggleLightAction.complete = function(self)
        local ok, r = pcall(MinidoracatBuilder.Circuits.onToggle, self)
        if ok and r ~= nil then return r end
        if not ok then
            print(LOG .. "circuit toggle failed: " .. tostring(r))
            if self.mbldClaimed then return false end
        end
        return MinidoracatBuilder.toggleComplete(self)
    end
end

Events.OnObjectAboutToBeRemoved.Add(function(obj)
    if instanceof(obj, "IsoLightSwitch") then MinidoracatBuilder.Circuits.forget(obj) end
end)

return Circuits
