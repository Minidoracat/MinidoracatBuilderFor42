-- 線路（第六階段，設計稿「燈與開關」、研究 bt-switch）：本工具蓋的開關控制同一條線路上的燈。只在伺服器（單機在本機跑同一套）。
-- 帳本放在 Ledger 的 GOS 系統（circuits 鍵，跟世界一起存檔、一起回溯；客戶端只拿得到自己查的那一條）：
--   circuits = { next = 下一個編號, c = { [編號] = { s = { [鍵] = true }, l = { [鍵] = true } } } }，鍵＝Ledger.key。
--   一條線路最多 MAX_S 個開關、MAX_L 片燈（多格燈每片各算一片、整組一起進出）；一個開關、一片燈只屬於一條線路。
--   沒有開關的線路刪掉（燈停在當時的狀態）。反查表 byKey 不存，第一次用到時從 c 重建（只有一份真相）。
-- 開關＝帳本裡（本工具蓋的）、sprite 沒有 lightR 的 IsoLightSwitch。燈＝sprite 有 lightR 的 IsoLightSwitch，本工具蓋的或
--   sprite 能搬（IsMoveAble；建構子照它設 canBeModified，IsoLightSwitch.java:76-79）。不看燈的 canBeModified、燈泡、電池
--   欄位與物件 modData：任何登入的客戶端都改得到（ObjectModDataPacket、SyncCustomLightSettingsPacket；open-issues 出處）。
-- 按：包原版 ISToggleLightAction 的 complete（點擊、右鍵、手把都走它）。線路裡的開關切整條線路；本工具蓋的燈切自己（不能搬
--   的燈在地圖房屋外原版切不了，IsoLightSwitch.java:497-498）；其他照原版。不要求有電：燈亮不亮由客戶端每片照電力判斷
--   （LightingJNI.java:281-294），伺服器對自建屋一律算沒電（bt-switch §8）。原版開關切房間燈時線路上的燈不跟著動（設計稿）。
-- 接線：客戶端送 circuit（查）／wire（改），身分只認 OnClientCommand 的連線玩家；回 circuit 給那位玩家。
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
Circuits.ROOM_MAX = 400 -- 自動接線只認這麼大以內的封閉區域（沒封好的會和室外連成一大片）
Circuits.MAX_CAND = 64 -- 接線模式一次回幾個附近的燈與開關（封包大小）
local USE_OPTS = { label = "MinidoracatBuilder:switch" }

local byKey, idxOf = {}, nil
local lastPress, lastWire = {}, {} -- ponytail：不清；每條按過的線路、每個接過線的人一筆

local function now() return getTimestampMs() end

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

-- 開關所在的線路；沒有就建一條只有它的
local function ensure(d, swKey)
    local id = byKey[swKey]
    if id and d.c[id] then return id end
    id = d.next
    d.next = id + 1
    d.c[id] = { s = { [swKey] = true }, l = {} }
    byKey[swKey] = id
    return id
end

-- 每片燈都在每個開關的範圍內（鍵比座標，不必載入）
local function fits(sKeys, lKeys)
    local R, L = Circuits.RANGE, Circuits.LEVELS
    for _, sk in ipairs(sKeys) do
        local sx, sy, sz = parse(sk)
        for _, lk in ipairs(lKeys) do
            local lx, ly, lz = parse(lk)
            if not (sx and lx) or math.abs(sx - lx) > R or math.abs(sy - ly) > R or math.abs(sz - lz) > L then return false end
        end
    end
    return true
end

local function keys(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    return out
end

-- 線路裡現在找得到的物件。格子載入了卻找不到（或已經不是開關／燈）就剔除（當機回溯、漏掉的移除事件）；沒載入的保留、記數
local function members(d, id)
    local c = d.c[id]
    local out, gone, skipped = {}, {}, 0
    if not c then return out, 0 end
    for k in pairs(c.s) do
        local o, loaded = resolve(k)
        if o and Circuits.isSwitch(o) then out[#out + 1] = o elseif loaded then gone[#gone + 1] = k else skipped = skipped + 1 end
    end
    for k in pairs(c.l) do
        local o, loaded = resolve(k)
        if o and Circuits.isLamp(o) then out[#out + 1] = o elseif loaded then gone[#gone + 1] = k else skipped = skipped + 1 end
    end
    for _, k in ipairs(gone) do drop(d, k) end
    return out, skipped
end

local function server() return B.Server end

-- 伺服器 → 一位玩家（單機直接交給客戶端程式，同 Server.send）
function Circuits.send(player, args)
    if isServer() then
        sendServerCommand(player, MODULE, "circuit", args)
    elseif B.Wiring then
        B.Wiring.onServerCommand("circuit", args)
    end
end

local function useDenied(player, x, y, z)
    local api = MinidoracatSafehouse and MinidoracatSafehouse.v1
    return api ~= nil and api.API_MAJOR == 1 and type(api.CAPABILITIES) == "table" and api.CAPABILITIES.denies == true
        and api.denies(player, x, y, z, api.BITS.USE, USE_OPTS) == true
end

-- ---------------------------------------------------------------- 區域（自動接線、同步）

local function sameRegion(rid, x, y, z)
    local r = IsoRegions.getIsoWorldRegion(x, y, z)
    return r ~= nil and r:getID() == rid
end

-- 開關所在的封閉區域（isEnclosed、不超過 ROOM_MAX 格）的編號；沒有回 nil。編號會變（IsoRegionManager.java:26），只在這一次比
local function roomOf(x, y, z)
    local r = IsoRegions.getIsoWorldRegion(x, y, z)
    if not (r and r:isEnclosed() and r:getSquareSize() <= Circuits.ROOM_MAX) then return nil end
    return r:getID()
end

-- 同一層、RANGE 格內、同一個區域裡的每個 IsoLightSwitch
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

-- ---------------------------------------------------------------- 按

-- 切成 v：先把每個物件的狀態設好，再逐一 switchLight 並同步給附近玩家（多格燈的其他片已經是 v，不會再連動）。
-- 沒燈泡的照原版當成關（IsoLightSwitch.java:490-493）。
-- 客戶端替封閉的自建房間建的房間把房間裡每個 IsoLightSwitch（燈也算）都收進 lightSwitches（WorldRegionToMetaGrid.java:631-632），
-- 開關收到同步時客戶端 switchLight 會把它們的 activated 全改成開關的狀態（IsoLightSwitch.java:517-523），伺服器不變
-- （builder-circuits-1029b：沒接線的燈在客戶端跟著切）。所以同步開關之後，同一個區域裡不在這次名單上的燈再照伺服器的
-- 狀態同步一次（封包照順序到，後到的蓋回去）。
local function apply(list, v)
    for _, o in ipairs(list) do o:setActivated(v and o:hasLightBulb()) end
    local done, rooms = {}, {}
    for _, o in ipairs(list) do
        local on = o:isActivated()
        o:switchLight(on)
        o:syncIsoObject(false, on and 1 or 0, nil, nil)
        done[o] = true
        local p = props(o)
        local sq = o:getSquare()
        local rid = p and not p:has("lightR") and sq and roomOf(sq:getX(), sq:getY(), sq:getZ())
        if rid and not rooms[rid] then rooms[rid] = sq end
    end
    for rid, sq in pairs(rooms) do
        for _, o in ipairs(roomObjects(sq:getX(), sq:getY(), sq:getZ(), rid)) do
            local p = props(o)
            if not done[o] and p and p:has("lightR") then o:syncIsoObject(false, o:isActivated() and 1 or 0, nil, nil) end
        end
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
    apply(list, ref:isActivated())
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
    if lastPress[k] and t - lastPress[k] < Circuits.PRESS_MS then return false end
    lastPress[k] = t
    local list, skipped
    local d = data()
    if id and d then
        list, skipped = members(d, id)
    else
        list, skipped = pieces(obj), 0
    end
    local v = not obj:isActivated()
    apply(list, v)
    print(LOG .. "CIRCUIT press user=" .. server().who(player) .. " at=" .. x .. "," .. y .. "," .. z .. " id=" .. tostring(id)
        .. " on=" .. tostring(v) .. " objects=" .. #list .. " skipped=" .. skipped)
    if skipped > 0 then Circuits.send(player, { note = "UNLOADED", n = skipped }) end
    return true
end

-- ISToggleLightAction:complete() 的本工具部分。回 nil＝不是本工具的，照原版
function Circuits.onToggle(action)
    local obj = action.object
    if not (instanceof(obj, "IsoLightSwitch") and Ledger.get(obj)) then return nil end
    if Circuits.isLamp(obj) then return Circuits.press(action.character, obj, nil) end
    local d = data()
    local id = d and byKey[Ledger.key(obj)]
    if not (id and d.c[id]) then return nil end -- 沒接線的開關照原版（在地圖房屋裡切整間房）
    return Circuits.press(action.character, obj, id)
end

-- 移出世界前（拿起、砸、拆都會觸發；Ledger.lua 同一個事件）
function Circuits.forget(obj)
    local d, k = data(), Ledger.key(obj)
    if d and k then drop(d, k) end
end

-- ---------------------------------------------------------------- 自動接線


-- 接線要那一格的 BUILD 權限（原版安全屋＋Safehouse，同拆除，不看 WhereCanBuild）。回拒絕碼或 nil
local function wireDenied(player, o, preview)
    local s = o:getSquare()
    return Check.safehouse(player, { x = s:getX(), y = s:getY(), z = s:getZ(), sq = s }, preview, "wire")
end

-- 加一盞燈（整組）到線路：放得下、在每個開關範圍內才加。回加了幾片、是不是從別條線路移過來
local function addLamp(d, id, lamp)
    local c = d.c[id]
    local ks, moved, fresh = {}, false, 0
    for _, p in ipairs(pieces(lamp)) do
        local k = Ledger.key(p)
        if k then
            ks[#ks + 1] = k
            if byKey[k] ~= id then fresh = fresh + 1 end
            if byKey[k] and byKey[k] ~= id then moved = true end
        end
    end
    if fresh == 0 then return 0, false end
    if count(c.l) + fresh > Circuits.MAX_L then return nil, "FULL" end
    if not fits(keys(c.s), ks) then return nil, "OUT_OF_RANGE" end
    for _, k in ipairs(ks) do put(d, id, "l", k) end
    return fresh, moved
end

-- 開關放下或按「接同一房間」：同一個封閉房間裡、還沒接在別條線路的燈接上。開關自己還沒有線路、房間裡另一個開關有，
-- 就併進那條（雙切）。別條線路的燈不搶、只記數。每盞燈那格照預覽查 BUILD（不寫稽核；沒權限的跳過）。
-- 回 code（NOT_ENCLOSED）或 nil, { id, n = 接上幾片, taken = 別條線路的幾片, jx, jy = 併進的那個開關 }
function Circuits.autoWire(player, sw)
    local d = data()
    if not d then return "INTERNAL" end
    local sq = sw:getSquare()
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local rid = roomOf(x, y, z)
    if not rid then return "NOT_ENCLOSED" end
    local lamps, switches = roomScan(x, y, z, rid)
    local swKey = Ledger.key(sw)
    local id, info = byKey[swKey], { n = 0, taken = 0 }
    if not (id and d.c[id]) then
        for _, o in ipairs(switches) do
            local oid = o ~= sw and byKey[Ledger.key(o)]
            local oc = oid and d.c[oid]
            if oc and count(oc.s) < Circuits.MAX_S and fits({ swKey }, keys(oc.l)) then
                put(d, oid, "s", swKey)
                align(o, { swKey })
                id, info.jx, info.jy = oid, o:getSquare():getX(), o:getSquare():getY()
                break
            end
        end
    end
    id = id or ensure(d, swKey)
    for _, lamp in ipairs(lamps) do
        local lid = byKey[Ledger.key(lamp)]
        if lid and lid ~= id then
            info.taken = info.taken + 1
        elseif not lid and not wireDenied(player, lamp, true) then
            info.n = info.n + (addLamp(d, id, lamp) or 0)
        end
    end
    info.id = id
    return nil, info
end

-- 燈放下：同一個封閉房間裡的開關只屬於一條線路就接進去（bt-switch §2.3 第 4 步）。回線路編號或 nil
function Circuits.lampPlaced(lamp)
    local d = data()
    if not d then return nil end
    local sq = lamp:getSquare()
    local rid = roomOf(sq:getX(), sq:getY(), sq:getZ())
    if not rid then return nil end
    local _, switches = roomScan(sq:getX(), sq:getY(), sq:getZ(), rid)
    local only
    for _, o in ipairs(switches) do
        local oid = byKey[Ledger.key(o)]
        if oid and d.c[oid] then
            if only and only ~= oid then return nil end
            only = oid
        end
    end
    if only and (addLamp(d, only, lamp) or 0) > 0 then return only end
    return nil
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

-- 開關附近（RANGE 格、上下 LEVELS 層）可接的燈與本工具的開關：{ x, y, z, e, k = "l"／"s", c = 線路編號或 nil }
local function candidates(sw)
    local out, cell, R, L = {}, getCell(), Circuits.RANGE, Circuits.LEVELS
    local sq = sw:getSquare()
    local sx, sy, sz = sq:getX(), sq:getY(), sq:getZ()
    for z = sz - L, sz + L do
        for y = sy - R, sy + R do
            for x = sx - R, sx + R do
                local s = cell:getGridSquare(x, y, z)
                local objs = s and s:getObjects()
                for i = 0, (objs and objs:size() or 0) - 1 do
                    local o = objs:get(i)
                    if o ~= sw and instanceof(o, "IsoLightSwitch") and #out < Circuits.MAX_CAND then
                        local kind = (Circuits.isLamp(o) and "l") or (Circuits.isSwitch(o) and "s") or nil
                        if kind then
                            out[#out + 1] = { x = x, y = y, z = z, e = o:getSprite():getName(), k = kind, c = byKey[Ledger.key(o)] }
                        end
                    end
                end
            end
        end
    end
    return out
end

-- 回給玩家的那一條線路：{ q, id, s = { 開關 }, l = { 燈 }, cand（要的話）}
local function reply(player, q, d, id, extra, sw, cand)
    local c = d and id and d.c[id]
    local args = { q = q, id = c and id or nil, s = c and sideList(c.s) or {}, l = c and sideList(c.l) or {} }
    for k, v in pairs(extra or {}) do args[k] = v end
    if cand and sw then args.cand = candidates(sw) end
    Circuits.send(player, args)
end

local function refuse(player, q, code, extra)
    if code ~= "RATE_LIMITED" then print(LOG .. "CIRCUIT refuse user=" .. server().who(player) .. " code=" .. code) end
    local args = { code = code }
    for k, v in pairs(extra or {}) do args[k] = v end
    reply(player, q, nil, nil, args)
    return false
end

-- 放好一項燈（Server.complete 收尾後）：開關自動接線，燈接進房間裡唯一的線路；結果推給蓋的人
function Circuits.placed(player, objs)
    local first = objs[1]
    if not first then return end
    local d = data()
    if Circuits.isSwitch(first) then
        local code, info = Circuits.autoWire(player, first)
        if code then return reply(player, nil, d, nil, { auto = "switch", code = code }) end
        print(LOG .. "CIRCUIT auto user=" .. server().who(player) .. " id=" .. info.id .. " lamps=" .. info.n
            .. " taken=" .. info.taken .. " joined=" .. tostring(info.jx ~= nil))
        return reply(player, nil, d, info.id, { auto = "switch", n = info.n, taken = info.taken, jx = info.jx, jy = info.jy })
    elseif Circuits.isLamp(first) then
        local id = Circuits.lampPlaced(first)
        if id then reply(player, nil, d, id, { auto = "lamp" }) end
    end
end

-- ---------------------------------------------------------------- 客戶端指令

local OPS = { add = true, remove = true, join = true, room = true, clear = true, unplug = true }

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

local function lampOp(player, d, id, op, lamp)
    for _, p in ipairs(pieces(lamp)) do
        local why = wireDenied(player, p, false)
        if why then return why end
    end
    if op == "remove" then
        if byKey[Ledger.key(lamp)] ~= id then return "NOT_WIRED" end
        for _, p in ipairs(pieces(lamp)) do drop(d, Ledger.key(p)) end
        return nil, {}
    end
    local n, moved = addLamp(d, id, lamp)
    if not n then return moved end
    return nil, { moved = moved == true or nil }
end

-- 另一個開關：不在這條線路就併進來（雙切；它原本的線路整條併進來），已經在就拿掉
local function joinOp(player, d, id, other, sw)
    if not Circuits.isSwitch(other) then return "NOT_SWITCH" end
    local why = wireDenied(player, other, false)
    if why then return why end
    local ok = Ledger.key(other)
    local oid = byKey[ok]
    local c = d.c[id]
    if oid == id then
        if count(c.s) <= 1 then return "BAD_REQUEST" end
        drop(d, ok)
        return nil, {}
    end
    local oc = oid and d.c[oid]
    local sKeys, lKeys = keys(c.s), keys(c.l)
    local oS, oL = oc and keys(oc.s) or { ok }, oc and keys(oc.l) or {}
    for _, k in ipairs(oS) do sKeys[#sKeys + 1] = k end
    for _, k in ipairs(oL) do lKeys[#lKeys + 1] = k end
    if #sKeys > Circuits.MAX_S or #lKeys > Circuits.MAX_L then return "FULL" end
    if not fits(sKeys, lKeys) then return "OUT_OF_RANGE" end
    for _, k in ipairs(oS) do put(d, id, "s", k) end -- 原線路最後一個開關移走時 drop 會刪掉那條（燈的反查一起清）
    align(sw, oS)
    for _, k in ipairs(oL) do put(d, id, "l", k) end
    return nil, { moved = oc and true or nil }
end

-- wire：{ q, op, x, y, z, e（開關；unplug 時是燈）, tx, ty, tz, te（add／remove 的燈、join 的開關）, cand }
local function wire(player, q, args, d)
    local op = args.op
    if not OPS[op] then return refuse(player, q, "BAD_REQUEST") end
    local sx, sy, sz, se = target(args, "")
    local obj, code = find(sx, sy, sz, se)
    if not obj then return refuse(player, q, code) end
    if not near(player, obj) then return refuse(player, q, "TOO_FAR") end
    code = wireDenied(player, obj, false)
    if code then return refuse(player, q, code) end
    local id, extra
    if op == "unplug" then
        if not Circuits.isLamp(obj) then return refuse(player, q, "NOT_WIRABLE") end
        id = byKey[Ledger.key(obj)]
        if not (id and d.c[id]) then return refuse(player, q, "NOT_WIRED") end
        for _, p in ipairs(pieces(obj)) do drop(d, Ledger.key(p)) end
        extra = { op = op }
    else
        if not Circuits.isSwitch(obj) then return refuse(player, q, "NOT_SWITCH") end
        members(d, byKey[Ledger.key(obj)] or -1)
        id = ensure(d, Ledger.key(obj))
        if op == "room" then
            local info
            code, info = Circuits.autoWire(player, obj)
            if code then return refuse(player, q, code) end
            extra = { n = info.n, taken = info.taken, jx = info.jx, jy = info.jy }
            id = info.id
        elseif op == "clear" then
            for _, k in ipairs(keys(d.c[id].l)) do drop(d, k) end
            extra = {}
        else
            local tx, ty, tz, te = target(args, "t")
            local t
            t, code = find(tx, ty, tz, te)
            if not t then return refuse(player, q, code) end
            if op == "join" then
                code, extra = joinOp(player, d, id, t, obj)
            elseif not Circuits.isLamp(t) then
                code = "NOT_WIRABLE"
            else
                code, extra = lampOp(player, d, id, op, t)
            end
            if code then return refuse(player, q, code) end
        end
        extra.op = op
    end
    print(LOG .. "CIRCUIT wire user=" .. server().who(player) .. " op=" .. op .. " at=" .. sx .. "," .. sy .. "," .. sz
        .. " id=" .. tostring(id))
    reply(player, q, d, d.c[id] and id or nil, extra, Circuits.isSwitch(obj) and obj or nil, args.cand == true)
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
    local id = byKey[Ledger.key(obj)]
    if id then members(d, id) end
    reply(player, q, d, id and d.c[id] and id or nil, nil, isSw and obj or nil, isSw and args.cand == true)
    return true
end

-- OnClientCommand（Server.lua 分派）與單機客戶端直接呼叫。q＝客戶端的請求編號，原樣帶回
function Circuits.command(player, cmd, args)
    if type(args) ~= "table" then return end
    local S = server()
    local q = S.int(args.q, 1, 2147483647)
    if not q then return end
    local k, t = S.keyOf(player), now()
    if lastWire[k] and t - lastWire[k] < Circuits.WIRE_MS then return refuse(player, q, "RATE_LIMITED") end
    lastWire[k] = t
    local why = S.notAllowed(player)
    if why then return refuse(player, q, why) end
    local d = data()
    if not d then return refuse(player, q, "INTERNAL") end
    if cmd == "wire" then return wire(player, q, args, d) end
    return query(player, q, args, d)
end

-- 包原版開關燈動作（設計稿：只包這一個）。在類別上換 complete，伺服器照 rawget→metatable 取得到
-- （MinidoracatSafehouse Permissions.lua:4-8）；原函式只取一次（熱重載不重包），實作經模組表呼叫。
-- 出錯時照原版做，不讓本工具的錯擋住原版的燈。
if ISToggleLightAction and not B.toggleComplete then
    B.toggleComplete = ISToggleLightAction.complete
    ISToggleLightAction.complete = function(self)
        local ok, r = pcall(MinidoracatBuilder.Circuits.onToggle, self)
        if ok and r ~= nil then return r end
        if not ok then print(LOG .. "circuit toggle failed: " .. tostring(r)) end
        return MinidoracatBuilder.toggleComplete(self)
    end
end

Events.OnObjectAboutToBeRemoved.Add(function(obj)
    if instanceof(obj, "IsoLightSwitch") then MinidoracatBuilder.Circuits.forget(obj) end
end)

return Circuits
