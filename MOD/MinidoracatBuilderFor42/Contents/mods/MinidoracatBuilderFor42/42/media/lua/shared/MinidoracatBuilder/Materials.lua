-- 材料：自己找，不收客戶端給的清單（bt-authority §5.1）。
-- 找的順序照原版建造扣料（buildUtil.consumeMaterial，ISBuildUtil.lua:125-237）：背包（含袋子）→ 周圍 3×3 地上 →
-- 釘子還不夠就拆背包裡的釘子盒。差別：地上以玩家所在格為中心（原版以建造格為中心），隔牆、隔關著的門窗的不拿。
-- ponytail：家具、車上的容器不找；要找時照 §5.1 逐個過安全屋拿取權限、上鎖與 2.5 格。
-- 先 plan（只找、不動），物件放好後才 consume，放失敗就不扣（§5.6）。plan／consume 只在伺服器的 complete() 跑，
-- MP 只發生一次。客戶端只用 summary／short／take 給畫面看（同一套找法），伺服器照樣重算。

MinidoracatBuilder = MinidoracatBuilder or {}
local Materials = MinidoracatBuilder.Materials or {}
MinidoracatBuilder.Materials = Materials

local NAILS, NAILS_BOX, PER_BOX = "Base.Nails", "Base.NailsBox", 100 -- 拆盒配方一盒 100 根（recipes_packing.txt:230-260）
-- 缺的耗材（Cost 的 uses）在 missing 裡的鍵＝這個字首＋耗材鍵（例 use:Base.WeldingRods），和 fullType 分開；Messages 照它寫「次」
Materials.USE = "use:"
local USE = Materials.USE
local EMPTY = {}

local function notBroken(item) return not item:isBroken() end
-- 裝著東西的袋子不能當材料（buildUtil.predicateMaterial）
local function usable(item)
    return not instanceof(item, "InventoryContainer") or item:getInventory():getItems():isEmpty()
end

-- 玩家所在格與周圍 8 格、走得到的地上物品，逐個交給 fn(wo, item)，fn 回 true 就停。別人的安全屋裡的、裝著東西的袋子
-- 不算。plan、summary 都走這裡，兩邊才不會判斷不同
local function eachGround(player, fn)
    local here = player:getCurrentSquare()
    if not here then return end
    local cell, x, y, z = getCell(), here:getX(), here:getY(), here:getZ()
    for dy = -1, 1 do
        for dx = -1, 1 do
            local sq = cell:getGridSquare(x + dx, y + dy, z)
            if sq and here:canReachTo(sq) and SafeHouse.isSafehouseAllowLoot(sq, player) then
                local list = sq:getWorldObjects()
                for i = 0, list:size() - 1 do
                    local wo = list:get(i)
                    local item = wo:getItem()
                    if item and usable(item) and fn(wo, item) then return end
                end
            end
        end
    end
end

-- 只收 want（fullType → 還缺幾個，會被扣）裡的種類與數量。回 fullType → { IsoWorldInventoryObject, ... }
local function groundItems(player, want)
    local out = {}
    eachGround(player, function(wo, item)
        local ft = item:getFullType()
        local need = want[ft]
        if need and need > 0 then
            local bucket = out[ft] or {}
            out[ft] = bucket
            bucket[#bucket + 1] = wo
            want[ft] = need - 1
        end
    end)
    return out
end

-- 每種幾個。summary 用：地上掃一次，不是每種材料各掃一次（視窗每秒重算，查過的材料常有 25 種）。
local function groundCounts(player)
    local out = {}
    eachGround(player, function(_, item)
        local ft = item:getFullType()
        out[ft] = (out[ft] or 0) + 1
    end)
    return out
end

-- 帶著沒壞的這種工具（ItemTag 欄位名；這個版本沒有的標籤當沒帶）。plan 與 summary 共用，兩邊才不會判斷不同。
-- 噴槍另外照型別找：42.21 的 item BlowTorch 沒有 Tags（scripts/generated/items/drainable.txt），沒有物品帶這個標籤，
-- 原版自己也照型別找（ISMoveableSpriteProps.lua:4-6、ISVehicleMenu.lua:878）。原版拆解還要燃料（uses ≥ 1）；
-- 這裡工具不消耗（使用者 2026-10-27 決定），所以不看燃料，空的噴槍也算。硬核「原版材料」打開時燃料另照耗材
-- （Cost 的 uses、findUses）扣，那裡才看次數。
local BY_TYPE = { BLOW_TORCH = "BlowTorch" }
local function hasTool(inv, name)
    local tag = ItemTag[name]
    if tag ~= nil and inv:getFirstTagEvalRecurse(tag, notBroken) ~= nil then return true end
    local ty = BY_TYPE[name]
    return ty ~= nil and inv:getFirstTypeEvalRecurse(ty, notBroken) ~= nil
end

-- 缺的工具（ItemTag 欄位名陣列）；都帶著回 nil。拆除也用（和蓋的時候一樣的工具，使用者 2026-10-28 選）
function Materials.missingTools(player, tools)
    local inv, out = player:getInventory(), nil
    for _, name in ipairs(tools) do
        if not hasTool(inv, name) then
            out = out or {}
            out[#out + 1] = name
        end
    end
    return out
end

-- 硬核「原版材料」的耗材（Cost 的 uses）：照次數用，背包（含袋子）先、周圍 3×3 地上後（同原版 consumeMaterial 的
-- use:，ISBuildUtil.lua:196-224）。tag:base:concrete 照標籤找（黏土漿、混凝土，鐵桶木桶都算），其他鍵是 fullType。
local USE_TAG = { ["tag:base:concrete"] = "CONCRETE" }
local function isUse(key, item)
    local tag = USE_TAG[key]
    if not tag then return item:getFullType() == key end
    return ItemTag[tag] ~= nil and item:hasTag(ItemTag[tag])
end
-- 找到 n 次為止：回 { { item, n＝用幾次 }, ... }, 找到幾次。summary 傳 math.huge 數全部
local function findUses(player, key, n)
    local out, got = {}, 0
    local function take(item)
        local u = item:getCurrentUses()
        if u > 0 then
            local k = math.min(u, n - got)
            out[#out + 1] = { item = item, n = k }
            got = got + k
        end
        return got >= n
    end
    local inv, tag = player:getInventory(), USE_TAG[key]
    local list
    if not tag then
        list = inv:getAllTypeRecurse(key)
    elseif ItemTag[tag] ~= nil then
        list = inv:getAllTagRecurse(ItemTag[tag], ArrayList.new())
    end
    for i = 0, (list and list:size() or 0) - 1 do
        if take(list:get(i)) then return out, got end
    end
    eachGround(player, function(_, item) return isUse(key, item) and take(item) end)
    return out, got
end

-- cost＝Cost.sum 的結果。回 plan，或 nil, missing（fullType → 還差幾個；耗材 use:鍵 → 還差幾次）, tools（缺的 ItemTag 欄位名）
function Materials.plan(player, cost)
    local inv = player:getInventory()
    local missingTools = Materials.missingTools(player, cost.tools)
    local take, short, anyShort = {}, {}, false
    for ft, n in pairs(cost.items) do
        local got = inv:getSomeTypeEvalRecurse(ft, usable, n)
        for i = 0, got:size() - 1 do take[#take + 1] = got:get(i) end
        if got:size() < n then
            short[ft] = n - got:size()
            anyShort = true
        end
    end
    local ground, boxes, left = {}, {}, 0
    if anyShort then
        local want = {}
        for ft, k in pairs(short) do want[ft] = k end
        for ft, list in pairs(groundItems(player, want)) do
            for _, wo in ipairs(list) do ground[#ground + 1] = wo end
            short[ft] = short[ft] - #list
        end
        local nails = short[NAILS]
        if nails and nails > 0 then
            local got = inv:getSomeTypeEvalRecurse(NAILS_BOX, usable, math.ceil(nails / PER_BOX))
            for i = 0, got:size() - 1 do boxes[#boxes + 1] = got:get(i) end
            local opened = #boxes * PER_BOX
            if opened >= nails then left = opened - nails end
            short[NAILS] = nails - opened
        end
    end
    local missing
    for ft, k in pairs(short) do
        if k > 0 then
            missing = missing or {}
            missing[ft] = k
        end
    end
    local uses = {}
    for key, n in pairs(cost.uses or EMPTY) do
        local found, got = findUses(player, key, n)
        for _, u in ipairs(found) do uses[#uses + 1] = u end
        if got < n then
            missing = missing or {}
            missing[USE .. key] = n - got
        end
    end
    if missing or missingTools then return nil, missing, missingTools end
    return { take = take, ground = ground, boxes = boxes, left = left, uses = uses }
end

-- 建造作弊（不扣料、不要工具）。多人兩端都只認 isBuildCheat：伺服器上要 UseBuildCheat 能力才開得了
-- （ExtraInfoPacket.java:274-277），客戶端的 Lua 全域伺服器看不到。單機另認原版的 ISBuildMenu.cheat：debug 選單
-- 「Build Cheat」和管理面板的按鈕只設它（ISGeneralCheats.lua:16、ISAdminPanelUI.lua:255），debug 模式預設開
-- （ISBuildMenu.lua:2），原版建造也認它（ISBuildingObject.lua:382-385）。
function Materials.cheat(player)
    if player:isBuildCheat() then return true end
    return not isClient() and not isServer() and ISBuildMenu ~= nil and ISBuildMenu.cheat == true
end

-- 玩家此刻可用材料的摘要（客戶端預覽、目錄變暗用；不動任何東西）。和 plan 同一套找法：背包（含袋子）＋周圍 3×3
-- 走得到、可拿的地上物品，Base.Nails 另加背包裡的釘子盒每盒 100 根。
-- S.items[fullType]＝數量、S.uses[耗材鍵]＝次數、S.tools[ItemTag 欄位名]＝true|false，都是第一次讀到才查（每種一次
-- Java 查詢，之後讀表），所以 pairs(S.items) 只列出查過的種類。S.cheat＝建造作弊（Materials.cheat；伺服器不扣料，Check 看它）。
-- 背包用 getCountTypeEvalRecurse：和 plan 的 getSomeTypeEvalRecurse 走同一套遞迴、同一個 predicate
-- （ItemContainer.java:1267-1300,1316-1343,1357-1360,1435-1438）。
function Materials.summary(player)
    local inv = player:getInventory()
    local ground
    local items = setmetatable({}, { __index = function(t, ft)
        ground = ground or groundCounts(player)
        local n = inv:getCountTypeEvalRecurse(ft, usable) + (ground[ft] or 0)
        if ft == NAILS then n = n + inv:getCountTypeEvalRecurse(NAILS_BOX, usable) * PER_BOX end
        rawset(t, ft, n)
        return n
    end })
    local uses = setmetatable({}, { __index = function(t, key)
        local _, n = findUses(player, key, math.huge)
        rawset(t, key, n)
        return n
    end })
    local tools = setmetatable({}, { __index = function(t, name)
        local v = hasTool(inv, name)
        rawset(t, name, v)
        return v
    end })
    return { items = items, uses = uses, tools = tools, cheat = Materials.cheat(player), player = player }
end

-- 兩份摘要對已經查過的東西一樣嗎：只比 a 查過的種類、耗材與工具（b 照樣懶查）。介面用它判斷要不要清掉缺料標示。
-- 換了角色（死掉重生）不算一樣：懶查表綁著建它的那個角色。
function Materials.same(a, b)
    if not a or not b or a.cheat ~= b.cheat or a.player ~= b.player then return false end
    for k, v in pairs(a.items) do
        if b.items[k] ~= v then return false end
    end
    for k, v in pairs(a.tools) do
        if b.tools[k] ~= v then return false end
    end
    for k, v in pairs(a.uses) do
        if b.uses[k] ~= v then return false end
    end
    return true
end

-- 摘要夠不夠付 cost（Cost.sum 的結果）。回 missing（fullType → 還差幾個；耗材是 use:鍵 → 還差幾次）或 nil、
-- tools（缺的 ItemTag 欄位名）或 nil；同一個玩家狀態下，和 plan 的 missing、tools 相同（plan 成功時兩個都是 nil）。
-- 不看建造作弊。
function Materials.short(S, cost)
    local missingTools, missing
    for _, name in ipairs(cost.tools) do
        if not S.tools[name] then
            missingTools = missingTools or {}
            missingTools[#missingTools + 1] = name
        end
    end
    for ft, n in pairs(cost.items) do
        local have = S.items[ft]
        if have < n then
            missing = missing or {}
            missing[ft] = n - have
        end
    end
    for key, n in pairs(cost.uses or EMPTY) do
        local have = S.uses[key]
        if have < n then
            missing = missing or {}
            missing[USE .. key] = n - have
        end
    end
    return missing, missingTools
end

-- 從摘要扣掉 cost.items 與耗材（拖曳時照順序逐格累計：前面的格子用掉的，後面的不能再算）；不夠的扣到 0
function Materials.take(S, cost)
    for ft, n in pairs(cost.items) do
        local left = S.items[ft] - n
        S.items[ft] = left > 0 and left or 0
    end
    for key, n in pairs(cost.uses or EMPTY) do
        local left = S.uses[key] - n
        S.uses[key] = left > 0 and left or 0
    end
end

-- 伺服器上 sendRemoveItemFromContainer 只送封包，要先 Remove（pitfalls：伺服器端 send 不動容器）
local function removeItem(player, item)
    player:removeFromHands(item)
    local c = item:getContainer()
    if c then
        c:Remove(item)
        sendRemoveItemFromContainer(c, item)
    end
end

-- 照 plan 扣掉。拆開的釘子盒，用剩的釘子放回背包（buildUtil.openNailsBox）。耗材照次數用：原版建造同一個函式
-- （buildUtil.useDrainable，ISBuildUtil.lua:114-120；UseAndSync 同步給客戶端，用完照原版換成空桶）
function Materials.consume(player, plan)
    for _, item in ipairs(plan.take) do removeItem(player, item) end
    for _, wo in ipairs(plan.ground) do
        local sq = wo:getSquare()
        if sq then sq:transmitRemoveItemFromSquare(wo) end
    end
    for _, box in ipairs(plan.boxes) do removeItem(player, box) end
    if plan.left > 0 then
        local inv = player:getInventory()
        sendAddItemsToContainer(inv, inv:AddItems(NAILS, plan.left))
    end
    local uses = plan.uses or EMPTY
    for _, u in ipairs(uses) do buildUtil.useDrainable(u.item, u.n) end
    -- 單機地上的少了，物品欄的「地上」要重畫（ISBuildUtil.lua:290-296）；MP 由移除封包觸發 OnContainerUpdate
    -- （RemoveItemFromSquarePacket.java:83-94）
    if (#plan.ground > 0 or #uses > 0) and not isServer() and ISInventoryPage then ISInventoryPage.dirtyUI() end
end

return Materials
