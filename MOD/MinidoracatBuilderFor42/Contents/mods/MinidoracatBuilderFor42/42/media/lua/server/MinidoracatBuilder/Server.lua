-- 伺服器（單機在本機跑同一套）：開服建「tiledef 檔號 → MOD」表；建造的權威流程（bt-authority §9、設計稿「伺服器權威」）。
-- 身分只認 OnClientCommand 的連線玩家：客戶端先送 intent（項目、朝向、各項的原點座標），動作只帶 nonce 與第幾項。
-- complete() 不信任動作帶來的參數，只照這位玩家自己的 intent 做，sprite、種類、佔地、成本一律由伺服器重算。
if isClient() then return end
require "MinidoracatBuilder/Sources"
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Cost"
require "MinidoracatBuilder/Place"
require "MinidoracatBuilder/Materials"
require "MinidoracatBuilder/Check"
require "MinidoracatBuilder/Dismantle"
require "MinidoracatBuilder/Ledger"
require "MinidoracatBuilder/Floors"
require "MinidoracatBuilder/Overlays"
require "MinidoracatBuilder/Circuits"

local Sources, Entry, Cost = MinidoracatBuilder.Sources, MinidoracatBuilder.Entry, MinidoracatBuilder.Cost
local Place, Materials, Check = MinidoracatBuilder.Place, MinidoracatBuilder.Materials, MinidoracatBuilder.Check
local Dismantle, Ledger, Rules = MinidoracatBuilder.Dismantle, MinidoracatBuilder.Ledger, MinidoracatBuilder.Rules
local Overlays = MinidoracatBuilder.Overlays
local Server = MinidoracatBuilder.Server or {}
MinidoracatBuilder.Server = Server

local LOG = "[MinidoracatBuilderFor42] "
local MODULE = "MinidoracatBuilder"
local INTENT_TTL_MS = 180000          -- 收下後要先走過去（INTENT_REACH 100 格，繞路也夠）；每做完一項再延長
local RATE_WINDOW_MS, RATE_MAX = 5000, 20 -- 照 VehicleManager 的 intent 限流
local WAKE_MS = 3000                  -- 剛喚醒區域系統的那一帶，第一項至少等這麼久（bt-authority §6.3）
local WAKE_SPAN = 24                  -- 喚醒一次涵蓋周圍 7×7 chunk，約 ±24 格
-- Kahlua 沒有弱表：表裡的 player 物件靠新請求取代，過期的在下一次有人送請求時清掉（sweep）。
Server.intents = {}
local rate, woken, quietUntil = {}, {}, {}

local function now() return getTimestampMs() end
local function keyOf(player)
    if isServer() then return player:getOnlineID() end
    return "sp" .. player:getPlayerNum()
end

-- 帳號名稱可以有空白、控制字元與方括號，印進稽核行前換掉（pitfalls：寫入 username 前清理）
local function who(player)
    return (tostring(player:getUsername()):gsub("[%c%s%[%]]", "_"))
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
    print(LOG .. "REFUSE user=" .. who(player) .. " n=" .. tostring(n) .. " i=" .. tostring(i) .. " code=" .. code)
    local args = { n = n, i = i, code = code }
    for k, v in pairs(extra or {}) do args[k] = v end
    Server.send(player, "refused", args)
    return false
end

local setting = Check.setting

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
-- 要先讓區域系統發現那一帶」）。收到請求就對錨點那一帶有地板的一格重推一次，回那一帶的喚醒時間；沒推成（格子沒載入、
-- 沒地板）不記，下次再試。ponytail：表每 24×24 格一筆、不清；只記玩家附近的錨點（intent 先查距離），量跟著蓋過的範圍走。
local function wake(x, y)
    local k = math.floor(x / WAKE_SPAN) .. "," .. math.floor(y / WAKE_SPAN)
    local t = woken[k]
    if t then return t end
    local sq = getCell():getGridSquare(x, y, 0)
    if not (sq and sq:getFloor()) then return 0 end
    IsoRegions.setPreviousFlags(nil)
    IsoRegions.squareChanged(sq)
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

-- 清掉過期的請求（先收集再刪，不在 pairs 途中改表）。list＝Server.intents 或 Server.unbuilds
local function sweep(t, list)
    local old = {}
    for k, it in pairs(list) do
        if it.exp < t then old[#old + 1] = k end
    end
    for _, k in ipairs(old) do list[k] = nil end
end

-- 沒有對應請求的動作只記 log（每人每 5 秒最多一行，動作封包可以一直送）
local function quietLog(player, msg)
    local k, t = keyOf(player), now()
    if (quietUntil[k] or 0) <= t then
        quietUntil[k] = t + RATE_WINDOW_MS
        print(LOG .. msg .. " user=" .. who(player))
    end
end

-- 客戶端請求：{ n = nonce, e = 項目 ID, c = { x1, y1, z1, d1, x2, ... }（各項原點與朝向，攤平）, v = Entry.digest() }
-- 朝向 d：0＝項目本身那一面、1..4＝N、E、S、W、5＝配對面（Entry.face）；每格各帶一個（牆拉長方形圍一圈時四邊不同）。
-- 收下回 true；被拒回 false（原因已推給玩家）；洗包回 nil。
function Server.intent(player, args)
    if type(args) ~= "table" then return end
    local n = int(args.n, 1, 2147483647)
    if not n then return end -- 沒有 nonce 就無從回覆
    local k = keyOf(player)
    if not rateOk(k) then return end -- 洗包不回、不記 log
    sweep(now(), Server.intents)
    local why = notAllowed(player)
    if why then return Server.refuse(player, n, 0, why) end
    if args.v ~= Entry.digest() then return Server.refuse(player, n, 0, "STALE") end
    local c = args.c
    if type(c) ~= "table" then return Server.refuse(player, n, 0, "BAD_REQUEST") end
    local maxItems = setting("MaxCellsPerDrag", 32)
    local near = Check.INTENT_REACH
    local px, py, pz = player:getX(), player:getY(), math.floor(player:getZ())
    local anchors = {}
    for i = 1, maxItems * 4 + 1, 4 do
        if c[i] == nil then break end
        local x, y, z = int(c[i], 0, 1000000), int(c[i + 1], 0, 1000000), int(c[i + 2], -32, 31)
        local d = int(c[i + 3], 0, 5)
        if not (x and y and z and d) or #anchors >= maxItems or not getWorld():isValidSquare(x, y, z) then
            return Server.refuse(player, n, 0, "BAD_REQUEST")
        end
        if math.abs(x + 0.5 - px) > near or math.abs(y + 0.5 - py) > near or math.abs(z - pz) > 1 then
            return Server.refuse(player, n, 0, "TOO_FAR", { x = x, y = y, z = z })
        end
        anchors[#anchors + 1] = { x, y, z, d }
    end
    if #anchors == 0 then return Server.refuse(player, n, 0, "BAD_REQUEST") end
    local entry, code = Entry.resolve(args.e)
    if not entry then return Server.refuse(player, n, 0, code) end
    for _, a in ipairs(anchors) do
        if not Entry.face(entry, a[4]) then return Server.refuse(player, n, 0, "BAD_FACE", { x = a[1], y = a[2], z = a[3] }) end
    end
    Server.intents[k] = { player = player, n = n, e = entry.name, c = anchors, done = {}, left = #anchors,
        exp = now() + INTENT_TTL_MS, wake = wake(anchors[1][1], anchors[1][2]) }
    -- 收下才回 accepted，客戶端收到才排動作：請求與動作走不同通道，動作不能比請求先到
    Server.send(player, "accepted", { n = n })
    return true
end

-- 這位玩家（連線對應的角色）、這個 nonce、還沒做過的第 i 項；不符回 nil。過期的順手刪掉。
local function intentFor(player, n, i)
    local k = keyOf(player)
    local it = Server.intents[k]
    if not it then return nil end
    if it.exp < now() then
        Server.intents[k] = nil
        return nil
    end
    if it.n ~= n or it.player ~= player or not it.c[i] or it.done[i] then return nil end
    return it
end

-- 動作的施工時間（伺服器在 serverStart 前問一次；單機在建立動作時就問）。找不到請求回 1，讓它馬上進 complete() 被拒。
-- 剛喚醒區域系統的那一帶，第一項連即時動作也要等滿 WAKE_MS；後面的項目排在第一項之後，不用再等。
function Server.duration(player, n, i)
    local it = intentFor(player, n, i)
    if not it then return 1 end
    local ticks = 1
    if not player:isTimedActionInstant() then
        local entry = Entry.resolve(it.e)
        ticks = Entry.duration(entry and entry.kind, player)
    end
    local waitMs = i == 1 and it.wake + WAKE_MS - now() or 0
    if waitMs > 0 then ticks = math.max(ticks, math.ceil(waitMs / 20)) end -- 伺服器每 tick 20 ms（NetTimedAction.java:77）
    return ticks
end

local function costLine(items)
    local parts = {}
    for ft, n in pairs(items) do parts[#parts + 1] = ft .. "x" .. n end
    return table.concat(parts, ",")
end

-- 照付的材料給經驗（Cost.xp，退料率照蓋的人現在的技能等級）。addXp 和原版建造一樣（ISBuildUtil.lua:107,232）套經驗倍率
-- （沒有加成的技能 ×0.25 等，IsoGameCharacter.java:17457-17521）；伺服器上加在連線玩家自己身上，並更新防作弊的經驗基準，
-- 一次拖曳很多項也不會被當成經驗漲太快（LuaManager.java:11845-11857、GameServer.java:1862-1869、AntiCheatXPUpdate.java）。
local function giveXp(player, costs)
    local parts = {}
    for perk, xp in pairs(Cost.xp(costs, player)) do
        addXp(player, Perks.FromString(perk), xp)
        parts[#parts + 1] = perk .. "+" .. xp
    end
    return table.concat(parts, ",")
end

-- ---------------------------------------------------------------- 移除與退料（拆除、原地替換共用）
local DIRT = "blends_natural_01_64" -- 原版拆掉 z ≤ 0 的地板換成泥土（ISDismantleAction.lua:74-81）

-- 每項退 1..v 件（原版 ISDismantleAction、ISThumpableSpriteProps 同一算法，ISDismantleAction.lua:55-66）
local function rollInto(into, mats)
    for ft, v in pairs(mats) do
        local c = math.floor(tonumber(v) or 0)
        if c >= 1 then into[ft] = (into[ft] or 0) + ZombRand(c) + 1 end
    end
end

-- 退的料掉在玩家腳下（屋頂這類在上一層的，拆了也拿得到）；玩家沒有格子時掉在 sq
local function drop(player, sq, refund)
    local here = player:getCurrentSquare() or sq
    for ft, c in pairs(refund) do
        for _ = 1, c do here:AddWorldInventoryItem(ft, ZombRandFloat(0.1, 0.9), ZombRandFloat(0.1, 0.9), 0) end
    end
end

-- 移除並補地：樓梯清掉平台格的 ConnectedToStairs（Place.build 記的，同向的樓梯才能再蓋），平台照 plan.landing 拆；
-- z ≤ 0 的地板拆了換泥土（原版 ISDismantleAction.lua:74-81）；掛在地板上的地面覆蓋拿掉那張、清覆蓋帳本。移除時引擎丟的
-- 例外 Kahlua 只記 log、不往上丟（MethodCaller.java:34-43），pcall 看不到：每片拆完確認已經不在格子上，還在就當失敗（不退料）。
local function removeAll(kind, plan)
    local t = plan.overlay
    if t then
        if not Place.detach(t.floor, t.name) then
            error("overlay not removed at " .. t.sq:getX() .. "," .. t.sq:getY() .. "," .. t.sq:getZ())
        end
        Overlays.forget(t.sq, t.name)
    end
    local top, west, squares = nil, false, {}
    for i, o in ipairs(plan.remove) do
        local t, s = o:getSprite():getType(), o:getSquare()
        squares[i] = s
        if t == IsoObjectType.stairsTW or t == IsoObjectType.stairsTN then top, west = s, Rules.westStairs(t) end
        s:transmitRemoveItemFromSquare(o, false) -- 只拆這一片：多格的一組已經逐片列進 plan
        if s:getObjects():contains(o) then error("not removed at " .. s:getX() .. "," .. s:getY() .. "," .. s:getZ()) end
    end
    if top then
        local lsq = getCell():getGridSquare(top:getX() - (west and 1 or 0), top:getY() - (west and 0 or 1), top:getZ() + 1)
        if lsq then lsq:getModData()["ConnectedToStairs" .. tostring(not west)] = nil end
    end
    if plan.landing then plan.landing:getSquare():transmitRemoveItemFromSquare(plan.landing, false) end
    if kind == "floor" then
        for _, s in ipairs(squares) do
            if s:getZ() <= 0 and not s:getFloor() then
                Place.clearFloor(s)
                s:addFloor(DIRT)
            end
        end
    end
end

-- 原地替換：新的蓋好後移除舊的那件。地板的舊片 Place.clearFloor 蓋新的時已經拆了：已不在格子上的片略過。
local function removeOld(rep)
    local left = {}
    for _, o in ipairs(rep.plan.remove) do
        local s = o:getSquare()
        if s and s:getObjects():contains(o) then left[#left + 1] = o end
    end
    removeAll(rep.kind, { remove = left })
end

-- 替換失敗、新的已收回時：舊的不在格子上了（地板蓋新的時被 Place.clearFloor 拆掉）就照原圖、原退料表蓋回去。
-- had＝移除前複製的退料表（移除時 Place.onAboutToBeRemoved 會清掉物件上那一份）。回 true＝舊的在格子上（本來就在或蓋回了）；
-- 蓋回也出錯時收回蓋到一半的、回 false，呼叫端把 had 整份退給玩家（材料不會跟著舊的一起不見）
local function restoreOld(rep, sq, spr, had)
    if sq:getObjects():contains(rep.obj) then return true end
    local back = {}
    local ok, err = pcall(Place.build, rep.kind, { { sq = sq, spr = spr, cost = { items = had, fee = {} } } }, back)
    if ok then return true end
    print(LOG .. "replace restore failed e=" .. spr:getName() .. ": " .. tostring(err))
    Place.undo(back)
    return false
end

-- 整份退料（不擲 1..v）：替換失敗、東西蓋不回去或掛不回去時，材料不跟著不見
local function whole(t)
    local out = {}
    for ft, v in pairs(t or {}) do
        local c = math.floor(tonumber(v) or 0)
        if c >= 1 then out[ft] = c end
    end
    return out
end

-- 換一樓地板時，舊地板上本工具掛的地面覆蓋（換之前 Overlays.at 記下的）：Place.clearFloor 拆掉舊片時帳本整格清掉
-- （Overlays.dropFloor）。換好、或失敗後蓋回舊地板之後，照記下的圖與退料表掛回去；掛不回去（地板沒了、出錯）就整份退
local function rehang(player, sq, saved)
    for name, items in pairs(saved or {}) do
        if Dismantle.hung(sq, name) then
            -- 圖還掛著（舊地板沒移掉）：引擎先發移除事件才移除，帳本可能已被 dropFloor 清掉，照記下的補回
            if not Overlays.get(sq, name) then Overlays.put(sq, name, items) end
        else
            local spr = Entry.sprite(name)
            local rec = {}
            local ok = sq:getFloor() ~= nil and spr ~= nil and pcall(Place.attach, sq, spr, items, rec)
            if not ok then
                Place.undo(rec) -- 掛到一半的拿掉，免得圖還在又退料
                Overlays.forget(sq, name) -- 照理 Overlays.dropFloor 已清；沒清到也不留一筆退料給掛不上的圖
                drop(player, sq, whole(items))
                print(LOG .. "REPLACE OVERLAY LOST user=" .. who(player) .. " e=" .. name .. " refund=" .. costLine(whole(items)))
            end
        end
    end
end

-- 替換的經驗只照補的料給（舊的料拿回來再用，不算新付的）：新的那格成本複製一份，items 換成 pay；電器費不超過補的件數
local function paidCost(c, pay)
    local fee = {}
    for ft, f in pairs(c.fee or {}) do fee[ft] = math.min(f, pay[ft] or 0) end
    return { items = pay, tools = c.tools, perkOf = c.perkOf, chanceOf = c.chanceOf, fee = fee, back = c.back,
        uniform = c.uniform }
end

-- MinidoracatBuilderPlaceAction:complete()。回 true＝放好；false＝MP 客戶端收到 Reject 並清掉後面的動作，原因另外推
-- （單機不看回傳值，由 Client 收到 refused 時清佇列）。
-- 順序：身分 → 目錄重算 → 距離（座標）→ 補格子 → 安全屋 → 可放置 → 材料規劃 → 放置 → 扣料 → 收尾（bt-authority §9）。
-- 原地替換（Check.item 的 info.replace，設計稿 claim 4）：只補新的比舊的多的料（Check.net 的 pay），多的照拆除每項退
-- 1..v（back）；工具要新舊兩件的聯集。先蓋新的、再移除舊的；任一步失敗就收回新的、舊的不在了就蓋回，不扣料、不退料
-- （蓋回也失敗時舊的退料表整份退）。舊的一樓地板查不到帳本時照一般蓋。新的耐久照舊的剩下的比例。
-- 建造作弊照一般建造：不扣、不退，新的退料表記空。經驗只照 pay 給。
function Server.complete(player, n, i)
    local it = intentFor(player, n, i)
    if not it then
        -- MP 不回覆；單機是本機玩家自己的佇列（例：請求放太久過期），回 refused 讓客戶端清掉後面的動作
        if not isServer() then return Server.refuse(player, n, i, "NO_INTENT") end
        quietLog(player, "REFUSE n=" .. tostring(n) .. " code=NO_INTENT")
        return false
    end
    local why = notAllowed(player)
    if why then return Server.refuse(player, n, i, why) end
    -- 目錄重算、距離、補格子、安全屋、可放置（和客戶端預覽同一份）
    local a = it.c[i]
    local code, extra, info = Check.item(player, it.e, a[4], a)
    if code then return Server.refuse(player, n, i, code, extra) end
    local entry, spr, cells, costs, total = info.entry, info.spr, info.cells, info.costs, info.total
    local rep = info.replace
    local pay, back, tools, had = total.items, nil, total.tools, nil
    if rep and not rep.had and entry.kind == "floor" then
        -- 舊地板查不到退料表（一樓地板帳本對不上）：照改版前蓋新地板（Place.clearFloor 拆掉舊片、不退料），不卡在拆也拆不掉、
        -- 換也換不了
        rep = nil
    end
    if rep then
        -- 舊的那件查不到退料表（Place.refundOf 回 nil）：不換，同拆除的 NOT_OURS
        if not rep.had then return Server.refuse(player, n, i, "NOT_OURS", { x = a[1], y = a[2], z = a[3] }) end
        pay, back = Check.net(total.items, rep.had)
        tools = Cost.sum({ total, { items = {}, tools = Dismantle.tools(rep.kind, rep.plan) } }).tools
        had = {}
        for ft, v in pairs(rep.had) do had[ft] = tonumber(v) or 0 end
    end
    local plan
    if not Materials.cheat(player) then -- 多人只認 isBuildCheat（要 UseBuildCheat 能力）；單機另認原版 ISBuildMenu.cheat
        local missing, mtools
        plan, missing, mtools = Materials.plan(player, { items = pay, tools = tools })
        if not plan then
            return Server.refuse(player, n, i, missing and "NO_MATERIAL" or "NO_TOOL", { need = missing, tools = mtools })
        end
    else
        -- 沒付料：退料表、燈的帳本都記空的（原版作弊蓋的也沒有退料表，ISBuildUtil.lua:125-129），拆了不退
        for _, c in ipairs(cells) do c.cost = { items = {}, fee = {} } end
    end
    local oldSq, oldSpr = rep and cells[1].sq, rep and rep.obj:getSprite()
    if rep and instanceof(rep.obj, "IsoThumpable") and rep.obj:getMaxHealth() > 0 then
        cells[1].wear = math.min(1, rep.obj:getHealth() / rep.obj:getMaxHealth()) -- Place.thumpable 照比例給新的耐久
    end
    -- 換一樓地板：舊地板上本工具掛的地面覆蓋先記下來（換好或蓋回舊的之後掛回去，rehang）
    local saved = rep and entry.kind == "floor" and Overlays and Overlays.at(oldSq) or nil
    local placed = {}
    local ok, err = pcall(Place.build, entry.kind, cells, placed)
    if ok and rep then ok, err = pcall(removeOld, rep) end
    if not ok then
        Place.undo(placed)
        if rep and not restoreOld(rep, oldSq, oldSpr, had) then
            -- 舊的蓋不回去：舊的退料表整份退（不擲 1..v），不扣新的料
            local all = whole(had)
            drop(player, oldSq, all)
            print(LOG .. "REPLACE RESTORE FAIL user=" .. who(player) .. " old=" .. oldSpr:getName() .. " at=" .. a[1] .. ","
                .. a[2] .. "," .. a[3] .. " refund=" .. costLine(all))
        end
        rehang(player, oldSq or cells[1].sq, saved)
        print(LOG .. (rep and "replace" or "build") .. " failed e=" .. it.e .. ": " .. tostring(err))
        return Server.refuse(player, n, i, "INTERNAL")
    end
    rehang(player, cells[1].sq, saved)
    local refund = {}
    if rep and plan then rollInto(refund, back) end
    local xp = ""
    if plan then
        Materials.consume(player, plan)
        xp = giveXp(player, rep and { paidCost(costs[1], pay) } or costs)
        drop(player, cells[1].sq, refund)
    end
    Place.settle(cells)
    if entry.kind == "light" then -- 開關自動接線、燈接進房間裡的線路（第六階段）；出錯不影響這一項已經蓋好
        local cok, cerr = pcall(MinidoracatBuilder.Circuits.placed, player, placed)
        if not cok then
            print(LOG .. "circuit auto-wire failed: " .. tostring(cerr))
            MinidoracatBuilder.Circuits.send(player, { auto = "switch", code = "INTERNAL", who = player:getOnlineID() })
        end
    end
    local head = LOG .. (rep and "REPLACE" or "BUILD") .. " user=" .. who(player) .. " id=" .. tostring(player:getOnlineID())
        .. " e=" .. spr:getName() .. (rep and " old=" .. oldSpr:getName() or "") .. " kind=" .. entry.kind
        .. " at=" .. a[1] .. "," .. a[2] .. "," .. a[3]
    if rep then
        print(head .. " pay=" .. (plan and costLine(pay) or "free") .. " back=" .. costLine(refund) .. " xp=" .. xp)
    else
        print(head .. " cost=" .. (plan and costLine(total.items) or "free") .. " xp=" .. xp)
    end
    it.done[i] = true
    it.left = it.left - 1
    it.exp = now() + INTENT_TTL_MS
    if it.left <= 0 then Server.intents[keyOf(player)] = nil end
    Server.send(player, "placed", { n = n, i = i, replaced = rep and true or nil })
    return true
end

-- ---------------------------------------------------------------- 拆除（第五階段；一區拆除起一次一張清單）
-- 身分照建造：客戶端先送 dismantle 請求，列出要拆的每一件（照拆的順序），動作只帶 nonce 與第幾件，完成時照這位玩家
-- 自己的請求做。每人只留一筆；每件只輪一次，拆不了的跳過（回 true，引擎不清後面的動作），這個人整個不能拆時才停。
Server.unbuilds = {}

-- 這個人整個不能拆（OFF、NOT_ALLOWED、STATE、NO_INTENT）或請求本身被拒（i＝0）
local function dismantleRefused(player, n, i, code, extra)
    print(LOG .. "UNBUILD REFUSE user=" .. who(player) .. " n=" .. tostring(n) .. " i=" .. tostring(i) .. " code=" .. code)
    local args = { n = n, i = i, code = code }
    for k, v in pairs(extra or {}) do args[k] = v end
    Server.send(player, "dismantleRefused", args)
    return false
end

-- 客戶端請求：{ n = nonce, t = { x1, y1, z1, "名稱1", x2, ... }（照拆的順序，攤平；名稱＝那件的 sprite 名稱）}，最多
-- MaxCellsPerDrag 件（和建造同一個上限）。收下回 true；被拒回 false（原因已推給玩家）；洗包回 nil。
-- 能不能拆在動作完成時才查（玩家要先走過去），這裡只驗格式與大概的距離（和建造請求同一個範圍）。
function Server.dismantleIntent(player, args)
    if type(args) ~= "table" then return end
    local n = int(args.n, 1, 2147483647)
    if not n then return end
    local k = keyOf(player)
    if not rateOk(k) then return end
    sweep(now(), Server.unbuilds)
    local why = notAllowed(player)
    if why then return dismantleRefused(player, n, 0, why) end
    local t = args.t
    if type(t) ~= "table" then return dismantleRefused(player, n, 0, "BAD_REQUEST") end
    local maxItems = setting("MaxCellsPerDrag", 32)
    local near = Check.INTENT_REACH
    local px, py, pz = player:getX(), player:getY(), math.floor(player:getZ())
    local list = {}
    for i = 1, maxItems * 4 + 1, 4 do
        if t[i] == nil then break end
        local x, y, z, e = int(t[i], 0, 1000000), int(t[i + 1], 0, 1000000), int(t[i + 2], -32, 31), t[i + 3]
        if not (x and y and z) or type(e) ~= "string" or #e > 128 or e:find("%c") or #list >= maxItems then
            return dismantleRefused(player, n, 0, "BAD_REQUEST")
        end
        if math.abs(x + 0.5 - px) > near or math.abs(y + 0.5 - py) > near or math.abs(z - pz) > 1 then
            return dismantleRefused(player, n, 0, "TOO_FAR", { x = x, y = y, z = z })
        end
        list[#list + 1] = { x, y, z, e }
    end
    if #list == 0 then return dismantleRefused(player, n, 0, "BAD_REQUEST") end
    -- 期限照一區最多幾件給：清單只列本工具拆的，一區裡夾著的原版拆解伺服器看不到（不經過這裡、不會延長），每件留一份 TTL
    local ttl = INTENT_TTL_MS * maxItems
    Server.unbuilds[k] = { player = player, n = n, list = list, done = {}, left = #list, ttl = ttl, exp = now() + ttl }
    Server.send(player, "dismantleAccepted", { n = n })
    return true
end

-- 這位玩家、這個 nonce、還沒輪過的第 i 件；不符回 nil。過期的順手刪掉。
local function unbuildFor(player, n, i)
    local k = keyOf(player)
    local it = Server.unbuilds[k]
    if not it then return nil end
    if it.exp < now() then
        Server.unbuilds[k] = nil
        return nil
    end
    if it.n ~= n or it.player ~= player or not it.list[i] or it.done[i] then return nil end
    return it
end

-- 拆除動作的施工時間：和蓋同一種類一樣（Entry.duration）。找不到請求或那一件回 1，讓它馬上進 complete()（被拒或跳過）。
function Server.dismantleDuration(player, n, i)
    local it = unbuildFor(player, n, i)
    if not it or player:isTimedActionInstant() then return 1 end
    local a = it.list[i]
    local sq = getCell():getGridSquare(a[1], a[2], a[3])
    local obj = sq and Dismantle.find(sq, a[4])
    local kind = obj and Dismantle.kindOf(obj) or (sq and Dismantle.hung(sq, a[4]) and "floorOverlay") or nil
    if not kind then return 1 end
    return Entry.duration(kind, player)
end

-- 樓梯平台留著的情況：不是本 MOD 補的（帳本沒記：蓋樓梯時那格原本就有地板）、上面還有別的東西、或沒有 BUILD 權限。
-- 平台不退料，留著只是一塊地板；安全屋照預覽查（只決定留不留，不推通知、不寫稽核）。
local function keepLanding(player, l)
    local s = l:getSquare()
    return not (s and Ledger.get(l)) or s:getObjects():size() > 1
        or Check.safehouse(player, { x = s:getX(), y = s:getY(), z = s:getZ(), sq = s }, true, "dismantle") ~= nil
end

-- 拆一件：拆那格上 sprite 名稱相同、本 MOD 蓋的那件；格上沒有那件物件時，找那格地板上掛的那張地面覆蓋
-- （Dismantle.hung，不看記號）。物件由伺服器自己找（不傳物件：物件索引兩端的順序可能不同），能不能拆照 Dismantle.check 重查。
-- 退料表先讀完再移除（移除前 Place.onAboutToBeRemoved 清掉退料表、帳本清掉燈）：同一件被兩個動作拆時，後到的
-- 找不到物件（GONE），不會再退。燈與平台只認帳本；地面覆蓋只認覆蓋帳本（Overlays）；IsoThumpable 照 Place.refundOf
-- （一樓以下的地板在地板帳本）。查不到退料表的不拆（NOT_OURS，平台留著）。移除出錯時不退料（只會少，不會多）。不給經驗。
-- 拆好回 nil, nil, refund, kind, 片數；拆不了回 code, extra。
local function unbuildOne(player, x, y, z, name)
    local at = { x = x, y = y, z = z }
    local sq = getCell():getGridSquare(x, y, z)
    if not sq then return "NOT_LOADED", at end
    local obj = Dismantle.find(sq, name)
    local kind, plan
    if obj then
        kind = Dismantle.kindOf(obj)
        plan = Dismantle.plan(obj, kind)
    else
        local t = Dismantle.hung(sq, name)
        if not t then return "GONE", at end
        kind, plan = "floorOverlay", Dismantle.overlayPlan(t)
    end
    local code, extra = Dismantle.check(player, kind, plan)
    if code then return code, extra end
    local refund = {}
    if plan.overlay then
        local mats = Overlays.get(sq, name)
        if not mats then return "NOT_OURS", at end
        rollInto(refund, mats)
    end
    for _, o in ipairs(plan.refund) do
        local mats
        if instanceof(o, "IsoLightSwitch") then
            mats = Ledger.get(o)
        else
            mats = Place.refundOf(o)
        end
        if not mats then return "NOT_OURS", at end
        rollInto(refund, mats)
    end
    if plan.landing and keepLanding(player, plan.landing) then plan.landing = nil end
    local ok, err = pcall(removeAll, kind, plan)
    if not ok then
        print(LOG .. "dismantle failed e=" .. name .. ": " .. tostring(err))
        return "INTERNAL", at
    end
    drop(player, sq, refund)
    return nil, nil, refund, kind, #plan.remove
end

-- MinidoracatBuilderDismantleAction:complete()：照這位玩家的拆除請求拆第 i 件。拆好送 dismantled（帶退了什麼）；
-- 這一件拆不了送 dismantleSkipped、回 true（佇列照走，下一件照拆）；這個人整個不能拆時清掉請求、送 dismantleRefused、回 false。
function Server.dismantle(player, n, i)
    local it = unbuildFor(player, n, i)
    if not it then
        if not isServer() then return dismantleRefused(player, n, i, "NO_INTENT") end
        quietLog(player, "UNBUILD REFUSE n=" .. tostring(n) .. " code=NO_INTENT")
        return false
    end
    local k = keyOf(player)
    local why = notAllowed(player)
    if why then
        Server.unbuilds[k] = nil
        return dismantleRefused(player, n, i, why)
    end
    it.done[i] = true -- 每件只輪一次（拆好、跳過都算）
    it.left = it.left - 1
    it.exp = now() + it.ttl
    if it.left <= 0 then Server.unbuilds[k] = nil end
    local a = it.list[i]
    local x, y, z, name = a[1], a[2], a[3], a[4]
    local code, extra, refund, kind, parts = unbuildOne(player, x, y, z, name)
    if code == "INTERNAL" then
        -- 移除出錯（引擎例外被吞掉，多片的可能只拆了一部分）：整批停，不再往下拆，留給玩家與管理員看
        Server.unbuilds[k] = nil
        print(LOG .. "UNBUILD FAIL user=" .. who(player) .. " n=" .. n .. " i=" .. i .. " e=" .. name .. " at=" .. x .. ","
            .. y .. "," .. z)
        return dismantleRefused(player, n, i, code, extra)
    end
    if code then
        print(LOG .. "UNBUILD SKIP user=" .. who(player) .. " n=" .. n .. " i=" .. i .. " e=" .. name .. " code=" .. code)
        local args = { n = n, i = i, code = code, x = x, y = y, z = z }
        for key, v in pairs(extra or {}) do args[key] = v end
        Server.send(player, "dismantleSkipped", args)
        return true
    end
    print(LOG .. "UNBUILD user=" .. who(player) .. " id=" .. tostring(player:getOnlineID()) .. " e=" .. name
        .. " kind=" .. kind .. " at=" .. x .. "," .. y .. "," .. z .. " parts=" .. parts .. " refund=" .. costLine(refund))
    Server.send(player, "dismantled", { n = n, i = i, x = x, y = y, z = z, e = name, refund = refund })
    return true
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE or not player then return end
    if command == "intent" then
        Server.intent(player, args)
    elseif command == "dismantle" then
        Server.dismantleIntent(player, args)
    elseif command == "circuit" or command == "wire" then
        MinidoracatBuilder.Circuits.command(player, command, args)
    end
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

-- Circuits.lua 用的（同一份身分、權限與參數檢查）
Server.keyOf, Server.who, Server.notAllowed, Server.int = keyOf, who, notAllowed, int

return Server
