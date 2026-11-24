-- 本 MOD 挖的地下室的格子帳本（只在伺服器；設計：temp/feedback-1124/basement/plan.md §1.2、§2.2）：一格一筆，鍵＝Store.pos、
-- 值＝空表（整本共用一個對照表項）。算不算室內、哪裡是外邊以這裡為準；鍵只由伺服器寫（Server.complete → commit），
-- 不收客戶端指令。開服載入進 Basement 的集合，60 tick 後一次登錄進引擎；挖了就增量登錄、推給附近的玩家。
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

-- 開服 60 tick 後才登錄：開始時玩家周圍的 chunk 還沒齊（BD aparosa_BD_Rooms.lua 檔尾同一個等法）
local ticks = 0
local function countdown()
    ticks = ticks - 1
    if ticks > 0 then return end
    Events.OnTick.Remove(countdown)
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
    if ticks <= 0 then Events.OnTick.Add(countdown) end
    ticks = 60
end

-- GOS 會對系統表呼叫這幾個（SGlobalObjectSystem.java:96-162）；本系統不持有全域物件、不收客戶端指令
function BasementLedger:getInitialStateForClient() return nil end
function BasementLedger:isValidIsoObject() return false end
function BasementLedger:newLuaObject() error("MinidoracatBuilder basements own no global objects") end
function BasementLedger:OnChunkLoaded() end
function BasementLedger:OnClientCommand() end

SGlobalObjectSystem.RegisterSystemClass(BasementLedger)

local function areaOf(x, y) return math.floor(x / Basement.AREA), math.floor(y / Basement.AREA) end

-- 洞那格：照 BD openHole（aparosa_BD_Build.lua:383-393）拿掉地板與草、可移除的植物，格邊的牆與掛件留著
-- （Basement.checkCell 已經擋掉其他東西）。本工具蓋的地板照拆除退料（Place.refundOf），真的拆掉了才算
-- （transmitRemoveItemFromSquare 回 -1＝沒拆，IsoGridSquare.java:5929-5960；審查 round1 F2）。回退料表或 nil
local function openHole(sq)
    local had, objects = nil, sq:getObjects()
    for i = objects:size() - 1, 0, -1 do
        local o = objects:get(i)
        local p = o:getProperties()
        local floor = p and p:has(IsoFlagType.solidfloor)
        local tex = o:getTextureName()
        if floor or (p and (p:has(IsoFlagType.canBeRemoved)
            or (p:has(IsoFlagType.vegitation) and o:getType() ~= IsoObjectType.tree)))
            or (tex and tex:find("blends_grassoverlays", 1, true)) then
            local refund = floor and Place.refundOf(o)
            if sq:transmitRemoveItemFromSquare(o) >= 0 and refund then had = refund end
        end
    end
    sq:RecalcAllWithNeighbours(true)
    return had
end

-- 帳本寫好之後的一步：出錯只記 log、不丟錯。回 pcall 的結果
local function step(what, fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then print(LOG .. "basement " .. what .. " failed: " .. tostring(res)) end
    return ok, res
end

-- Server.complete 在 Place.build 成功後呼叫（cells＝Check.item 的格子，帶 role）；回 holes＝洞格地板的退料表清單。
-- 帳本寫成功之前不做拿不回來的事（開洞在後）；有一格寫不進去就把這次寫的拿掉並丟錯（Server.complete 撤回、不扣料）。
-- 帳本寫好了就算蓋成（Server.complete 照常扣料、磨鏟子）：之後每一步（加進集合、補牆、開洞、登錄、同步）出錯只記 log、
-- 不丟錯，漏掉的登錄與畫面在下一次開服或進場時照帳本補上（審查 round1 F1）
function BasementLedger.commit(player, cells, anchor)
    local new = {}
    for _, c in ipairs(cells) do
        if DUG[c.role] and c.z == Z and not Basement.has(c.x, c.y, c.z) then new[#new + 1] = c end
    end
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
    if not ok then added = {} end
    for _, t in ipairs(added) do
        step("edges", function()
            Basement.fixEdges(t[1], t[2], Z)
            Basement.fixEdges(t[1] + 1, t[2], Z)
            Basement.fixEdges(t[1], t[2] + 1, Z)
        end)
    end
    local holes, cell = {}, getCell()
    for _, c in ipairs(cells) do
        local sq = c.role == "hole" and (c.sq or cell:getGridSquare(c.x, c.y, c.z))
        if sq then
            local opened, h = step("hole", openHole, sq)
            if opened then holes[#holes + 1] = h end
        end
    end
    -- 登錄延後一起做（Basement.growLater）：一次拖曳挖很多格只登錄一次
    if #added > 0 then step("grow", Basement.growLater, added) end
    step("sync", function()
        if not isServer() then return Basement.recalcZ() end
        if #added == 0 then return end
        local flat, areas = {}, {}
        for _, t in ipairs(added) do
            flat[#flat + 1], flat[#flat + 2] = t[1], t[2]
            local ax, ay = areaOf(t[1], t[2])
            areas[#areas + 1] = { ax, ay }
        end
        local Server, players = MinidoracatBuilder.Server, getOnlinePlayers()
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            local px, py = areaOf(p:getX(), p:getY())
            for _, a in ipairs(areas) do
                if math.abs(px - a[1]) <= 1 and math.abs(py - a[2]) <= 1 then
                    Server.send(p, "dug", { t = flat })
                    break
                end
            end
        end
    end)
    return holes
end

-- 一個 basements 封包最多帶幾個矩形：同一塊不拆開，塞不下就換下一段（審查 round1 F11）
local SEGMENT = 500

-- 這位玩家所在大區與周圍一圈（3×3）的地下室，一塊一個 { x, y, w, h, x, y, w, h, ... }，分段送（指令 basements：
-- { ax, ay, i＝第幾段, n＝共幾段, b＝這一段的塊 }；沒有地下室也送一段空的 i＝1、n＝1、b＝{}）。位置只用連線玩家自己的座標
function BasementLedger.send(player)
    local ax, ay = areaOf(player:getX(), player:getY())
    local segs, cur, count = {}, {}, 0
    for _, list in ipairs(Basement.area(ax, ay)) do
        local flat = {}
        for _, r in ipairs(Basement.rects(list)) do
            for j = 1, 4 do flat[#flat + 1] = r[j] end
        end
        local n = #flat / 4
        if count > 0 and count + n > SEGMENT then
            segs[#segs + 1], cur, count = cur, {}, 0
        end
        cur[#cur + 1], count = flat, count + n
    end
    segs[#segs + 1] = cur
    local Server = MinidoracatBuilder.Server
    for i, b in ipairs(segs) do
        Server.send(player, "basements", { ax = ax, ay = ay, i = i, n = #segs, b = b })
    end
end

-- 帳本現在的樣子（離線測試與管理面板）：筆數、每一片的筆數與估計 bytes
function BasementLedger.stats()
    return S:stats()
end

return BasementLedger
