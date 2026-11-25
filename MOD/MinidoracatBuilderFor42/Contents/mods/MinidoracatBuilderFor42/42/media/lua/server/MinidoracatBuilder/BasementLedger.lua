-- 本 MOD 挖的地下室的格子帳本（只在伺服器）：一格一筆，鍵＝Store.pos、
-- 值＝空表（整本共用一個對照表項）。算不算室內、哪裡是外邊以這裡為準；鍵只由伺服器寫（Server.complete → commit），
-- 不收客戶端指令。開服載入進 Basement 的集合、當下登錄進引擎；挖了就延後一起登錄、推給附近的玩家。
-- 存檔在 Store（gos_MinidoracatBuilderBasements_<n>.bin，跟世界一起存檔、一起回溯）。
if isClient() then return end
require "Map/SGlobalObjectSystem"
require "MinidoracatBuilder/Store"
require "MinidoracatBuilder/Basement"

MinidoracatBuilder = MinidoracatBuilder or {}
local NAME = "MinidoracatBuilderBasements"
local LOG = "[MinidoracatBuilderFor42] "
local Store, Basement, Place = MinidoracatBuilder.Store, MinidoracatBuilder.Basement, MinidoracatBuilder.Place
local BasementLedger = SGlobalObjectSystem:derive(NAME)
MinidoracatBuilder.BasementLedger = BasementLedger

local S -- 這一場的帳本（initSystem 開）
local EMPTY = {}
local Z = -1
local DUG = { top = true, mid = true, bottom = true, dig = true } -- 記進帳本的角色（樓梯三格也算已挖）
local DIRS = { { 0, -1 }, { -1, 0 }, { 1, 0 }, { 0, 1 } }

function BasementLedger:new()
    return SGlobalObjectSystem.new(self, NAME)
end

-- 值只收空表
local function valid(v)
    if type(v) ~= "table" then return false end
    for _ in pairs(v) do return false end
    return true
end
local function sig() return "b" end

-- 開服登錄，兩本帳本（本帳本與燈的帳本 Ledger）都開了才做一次：兩邊的 initSystem 結尾各叫一次，不靠系統的啟動順序。
-- 專用伺服器先從燈的帳本記下開關格（z＝-1、在集合裡、圖是牆上開關 Rules.switchProps，Basement.setSwitchTile），再分房、
-- 全部登錄。單機這時世界已經載完、玩家周圍的 chunk 都在（GameLoadingState.java:308-317 先 IsoWorld.init 才 initSystems）；
-- 專用伺服器這時還沒有 chunk（分房等巡查），之後載入時引擎自己照 metaGrid 設房間（IsoChunk.java:2370-2375）
local started = false
function BasementLedger.start()
    local Ledger = MinidoracatBuilder.Ledger
    if started or not (BasementLedger.instance and Ledger and Ledger.instance) then return end
    started = true
    if isServer() then
        local scan, e = pcall(function()
            local named = IsoSpriteManager.instance:getNamedMap()
            Ledger.eachLight(function(x, y, z, name)
                local spr = z == Z and Basement.has(x, y, z) and named:get(name)
                if spr and MinidoracatBuilder.Rules.switchProps(spr:getProperties()) then Basement.setSwitchTile(x, y, true) end
            end)
        end)
        if not scan then print(LOG .. "basement switch scan failed: " .. tostring(e)) end
    end
    local split, serr = pcall(Basement.splitAll)
    if not split then print(LOG .. "basement split failed: " .. tostring(serr)) end
    local ok, err = pcall(Basement.registerAll)
    if not (ok and err) then print(LOG .. "basement register failed: " .. tostring(err)) end
end

function BasementLedger:initSystem()
    if BasementLedger.instance == self then return end
    SGlobalObjectSystem.initSystem(self)
    self.system:setModDataKeys({})
    self.system:setObjectModDataKeys({})
    self.system:setObjectSyncKeys({})
    S = Store.open(NAME, { id = "basements", label = "basement", valid = valid, sig = sig })
    local tiles = {}
    S:each(function(k)
        local x, y, z, edge = Store.unpos(k)
        if z == Z and edge == 0 then tiles[#tiles + 1] = { x, y } end
    end)
    Basement.add(tiles)
    S:summary()
    BasementLedger.instance = self
    started = false
    BasementLedger.start()
end

-- GOS 會對系統表呼叫這幾個（SGlobalObjectSystem.java:96-162）；本系統不持有全域物件、不收客戶端指令
function BasementLedger:getInitialStateForClient() return nil end
function BasementLedger:isValidIsoObject() return false end
function BasementLedger:newLuaObject() error("MinidoracatBuilder basements own no global objects") end
function BasementLedger:OnChunkLoaded() end
function BasementLedger:OnClientCommand() end

SGlobalObjectSystem.RegisterSystemClass(BasementLedger)

local function areaOf(x, y) return math.floor(x / Basement.AREA), math.floor(y / Basement.AREA) end

-- 指令推給所在大區與 tiles 任一格的大區相距不到一區（3×3）的連線玩家
local function sendNear(cmd, args, tiles)
    local areas, seen = {}, {}
    for _, t in ipairs(tiles) do
        local ax, ay = areaOf(t[1], t[2])
        local k = ax .. "," .. ay
        if not seen[k] then seen[k], areas[#areas + 1] = true, { ax, ay } end
    end
    local Server, players = MinidoracatBuilder.Server, getOnlinePlayers()
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        local px, py = areaOf(p:getX(), p:getY())
        for _, a in ipairs(areas) do
            if math.abs(px - a[1]) <= 1 and math.abs(py - a[2]) <= 1 then
                Server.send(p, cmd, args)
                break
            end
        end
    end
end

-- 洞那格：拿掉地板與草、可移除的植物（上下才看得到、走得通），格邊的牆與掛件留著
-- （Basement.checkCell 已經擋掉其他東西）。本工具蓋的地板照拆除退料（Place.refundOf），真的拆掉了才算
-- （transmitRemoveItemFromSquare 回 -1＝沒拆，IsoGridSquare.java:5929-5960）。拆掉地板時補推區域資料
-- （Place.repush；洞在 z=0，引擎的區域資料只收 z ≥ 0，IsoRegionWorker.java:379）。回退料表或 nil
local function openHole(sq)
    local had, gone, objects = nil, false, sq:getObjects()
    for i = objects:size() - 1, 0, -1 do
        local o = objects:get(i)
        local p = o:getProperties()
        local floor = p and p:has(IsoFlagType.solidfloor)
        local tex = o:getTextureName()
        if floor or (p and (p:has(IsoFlagType.canBeRemoved)
            or (p:has(IsoFlagType.vegitation) and o:getType() ~= IsoObjectType.tree)))
            or (tex and tex:find("blends_grassoverlays", 1, true)) then
            local refund = floor and Place.refundOf(o)
            if sq:transmitRemoveItemFromSquare(o) >= 0 and floor then
                gone = true
                if refund then had = refund end
            end
        end
    end
    sq:RecalcAllWithNeighbours(true)
    if gone then Place.repush(sq, nil) end
    return had
end

-- 帳本寫好之後的一步：出錯只記 log、不丟錯。回 pcall 的結果
local function step(what, fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then print(LOG .. "basement " .. what .. " failed: " .. tostring(res)) end
    return ok, res
end

-- 從這次要挖的格子 new 往外找地板有、帳本沒有的格子（當機時 chunk 存了、帳本沒存）：z=-1、格子在、有地板、沒有房間
-- （地圖的地下室與別的 MOD 登錄的都有房間）。沿著找到的繼續找，併起來那一塊不超過 Basement.MAX。回 { { x, y, z }, ... }。
-- 每一格照直接挖那一格的同一套檢查（那一格的安全屋、Basement.opens）：不過的不收，也不從它往外找。
-- 只在玩家挖到旁邊時順手收，不掃描、不載入格子。Basement Building 開著時挖不了（Basement.pre 回 DIG_BD），不會走到這裡
local function orphans(player, new)
    local cell, grid, Check = getCell(), getWorld():getMetaGrid(), MinidoracatBuilder.Check
    local seen, ids, size, queue, out, taken = {}, {}, #new, {}, {}, {}
    -- 併進 (x, y) 四鄰的塊之後多幾格（還沒算過的塊）；mark＝記成算過
    local function blocksNear(x, y, mark)
        local n, got = 0, {}
        for _, d in ipairs(DIRS) do
            local id, bn = Basement.blockOf(x + d[1], y + d[2], Z)
            if id and not ids[id] and not got[id] then got[id], n = true, n + bn end
        end
        if mark then
            for id in pairs(got) do ids[id] = true end
        end
        return n
    end
    for _, c in ipairs(new) do
        local k = Place.key(c.x, c.y, Z)
        seen[k], taken[k], queue[#queue + 1] = true, true, c
        size = size + blocksNear(c.x, c.y, true)
    end
    local i = 1
    while queue[i] and size < Basement.MAX do
        local q = queue[i]
        for _, d in ipairs(DIRS) do
            local x, y = q.x + d[1], q.y + d[2]
            local k = Place.key(x, y, Z)
            if not seen[k] then
                seen[k] = true
                local sq = Basement.inRange(x, y) and not Basement.has(x, y, Z) and cell:getGridSquare(x, y, Z)
                if sq and sq:getFloor() and not grid:getRoomAt(x, y, Z) then
                    local grow = 1 + blocksNear(x, y, false)
                    local c = { x = x, y = y, z = Z, sq = sq }
                    if size + grow <= Basement.MAX and not Check.safehouse(player, c, nil)
                        and not Basement.opens(player, c, nil, taken) then
                        blocksNear(x, y, true)
                        c.sq, taken[k] = nil, true
                        out[#out + 1], queue[#queue + 1], size = c, c, size + grow
                    end
                end
            end
        end
        i = i + 1
    end
    if #out > 0 then print(LOG .. "basement: " .. #out .. " dug tiles missing from the ledger were added back") end
    return out
end

-- Server.complete 在 Place.build 成功後呼叫（cells＝Check.item 的格子，帶 role）；回 holes＝洞格地板的退料表清單、
-- partial＝加進集合、補牆、開洞有一步出錯（玩家看得到的部分沒做完；給蓋的人一句提示）。
-- 帳本寫成功之前不做拿不回來的事（開洞在後）；有一格寫不進去就把這次寫的拿掉並丟錯（Server.complete 撤回、不扣料）。
-- 帳本寫好了就算蓋成（Server.complete 照常扣料、磨鏟子）：之後每一步（加進集合、補牆、開洞、登錄、同步）出錯只記 log、
-- 不丟錯，漏掉的登錄與畫面在下一次開服或進場時照帳本補上。
-- 當機後帳本和地板可能對不上（chunk 隨時寫、帳本跟整體存檔）：帳本有、地板沒有的格子（Basement.pre 當成沒挖過、准它重挖）
-- 不重寫帳本，照樣補牆；地板有、帳本沒有的（orphans）收進這一批
function BasementLedger.commit(player, cells, anchor)
    local new, again = {}, {}
    for _, c in ipairs(cells) do
        if DUG[c.role] and c.z == Z then
            if Basement.has(c.x, c.y, c.z) then again[#again + 1] = { c.x, c.y } else new[#new + 1] = c end
        end
    end
    local found, more = step("adopt", orphans, player, new)
    for _, c in ipairs(found and more or {}) do new[#new + 1] = c end
    local written = {}
    for _, c in ipairs(new) do
        local k = Store.pos(c.x, c.y, c.z)
        if not (k and S and S:put(k, EMPTY)) then
            for _, w in ipairs(written) do S:del(w) end
            error("basement ledger not recorded at " .. c.x .. "," .. c.y .. "," .. c.z)
        end
        written[#written + 1] = k
    end
    local tiles = {}
    for i, c in ipairs(new) do tiles[i] = { c.x, c.y } end
    local ok, added = step("add", Basement.add, tiles)
    local partial = not ok
    if not ok then added = {} end
    for _, t in ipairs(again) do added[#added + 1] = t end
    for _, t in ipairs(added) do
        partial = not step("edges", function()
            Basement.fixEdges(t[1], t[2], Z)
            Basement.fixEdges(t[1] + 1, t[2], Z)
            Basement.fixEdges(t[1], t[2] + 1, Z)
        end) or partial
    end
    local holes, cell = {}, getCell()
    for _, c in ipairs(cells) do
        local sq = c.role == "hole" and (c.sq or cell:getGridSquare(c.x, c.y, c.z))
        if sq then
            local opened, h = step("hole", openHole, sq)
            if opened then holes[#holes + 1] = h else partial = true end
        end
    end
    -- 登錄延後一起做（Basement.growLater）：一次拖曳挖很多格只登錄一次。重挖的格子在集合裡，growLater 照「還沒登錄」篩
    if #added > 0 then step("grow", Basement.growLater, added) end
    step("sync", function()
        if not isServer() then return Basement.recalcZ() end
        if #added == 0 then return end
        local flat = {}
        for _, t in ipairs(added) do flat[#flat + 1], flat[#flat + 2] = t[1], t[2] end
        sendNear("dug", { t = flat }, added)
    end)
    return holes, partial
end

-- 一個 basements 封包最多帶幾個矩形：同一塊不拆開，塞不下就換下一段
local SEGMENT = 500

-- 一塊的房間 { { { x, y }, ... }, ... } → { { x, y, w, h, x, y, w, h, ... }, ... }（每間一組矩形）、矩形數
local function roomRects(rooms)
    local out, n = {}, 0
    for i, list in ipairs(rooms) do
        local flat = {}
        for _, r in ipairs(Basement.rects(list)) do
            for j = 1, 4 do flat[#flat + 1] = r[j] end
        end
        out[i], n = flat, n + #flat / 4
    end
    return out, n
end

-- 修訂號：每推一次 block 加 1，快照帶當下的值；客戶端照它略過較舊的（指令不保序，PacketTypes.java:508）。不存檔：客戶端連線時
-- Lua 整個重來（ConnectToServerState.java:126），伺服器重開後沒有客戶端留著舊的
local rev = 0

-- 這位玩家所在大區與周圍一圈（3×3）的地下室，一塊一個房間清單 { { x, y, w, h, ... }, ... }（每間一組矩形），分段送（指令
-- basements：{ ax, ay, i＝第幾段, n＝共幾段, v＝修訂號（每段一樣）, b＝這一段的塊 }；沒有地下室也送一段空的 i＝1、n＝1、
-- b＝{}）。位置只用連線玩家自己的座標
function BasementLedger.send(player)
    local ax, ay = areaOf(player:getX(), player:getY())
    local segs, cur, count = {}, {}, 0
    for _, list in ipairs(Basement.area(ax, ay)) do
        local rooms, n = roomRects(Basement.byRoom(list))
        if count > 0 and count + n > SEGMENT then
            segs[#segs + 1], cur, count = cur, {}, 0
        end
        cur[#cur + 1], count = rooms, count + n
    end
    segs[#segs + 1] = cur
    local Server = MinidoracatBuilder.Server
    for i, b in ipairs(segs) do
        Server.send(player, "basements", { ax = ax, ay = ay, i = i, n = #segs, v = rev, b = b })
    end
end

-- 一塊有新格子或分房變了、伺服器那一批登錄之後（Basement.growLater／patrol）：修訂號加 1，整塊推給附近的玩家（指令 block：
-- { v＝修訂號, r = { 每間一組矩形 } }）。單機的集合與登錄是同一份，不送
function BasementLedger.sendBlock(rooms)
    if not isServer() then return end
    local all = {}
    for _, list in ipairs(rooms) do
        for _, t in ipairs(list) do all[#all + 1] = t end
    end
    rev = rev + 1
    sendNear("block", { v = rev, r = (roomRects(rooms)) }, all)
end

Events.EveryOneMinute.Add(function() Basement.patrol() end)

-- 帳本現在的樣子（離線測試與管理面板）：筆數、每一片的筆數與估計 bytes
function BasementLedger.stats()
    return S:stats()
end

return BasementLedger
