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

local function notBroken(item) return not item:isBroken() end
-- 裝著東西的袋子不能當材料（buildUtil.predicateMaterial）
local function usable(item)
    return not instanceof(item, "InventoryContainer") or item:getInventory():getItems():isEmpty()
end

-- 玩家所在格與周圍 8 格、走得到的地上物品，只收 want（fullType → 還缺幾個，會被扣）裡的種類與數量。
-- 別人的安全屋裡的地上物品不拿。回 fullType → { IsoWorldInventoryObject, ... }
local function groundItems(player, want)
    local out = {}
    local here = player:getCurrentSquare()
    if not here then return out end
    local cell, x, y, z = getCell(), here:getX(), here:getY(), here:getZ()
    for dy = -1, 1 do
        for dx = -1, 1 do
            local sq = cell:getGridSquare(x + dx, y + dy, z)
            if sq and here:canReachTo(sq) and SafeHouse.isSafehouseAllowLoot(sq, player) then
                local list = sq:getWorldObjects()
                for i = 0, list:size() - 1 do
                    local wo = list:get(i)
                    local item = wo:getItem()
                    local ft = item and item:getFullType()
                    local need = ft and want[ft]
                    if need and need > 0 and usable(item) then
                        local bucket = out[ft] or {}
                        out[ft] = bucket
                        bucket[#bucket + 1] = wo
                        want[ft] = need - 1
                    end
                end
            end
        end
    end
    return out
end

-- 同一套找法（走得到、別人的安全屋不拿、裝著東西的袋子不算），每種幾個。summary 用：地上掃一次，
-- 不是每種材料各掃一次（視窗每秒重算，查過的材料常有 25 種）。
local function groundCounts(player)
    local out = {}
    local here = player:getCurrentSquare()
    if not here then return out end
    local cell, x, y, z = getCell(), here:getX(), here:getY(), here:getZ()
    for dy = -1, 1 do
        for dx = -1, 1 do
            local sq = cell:getGridSquare(x + dx, y + dy, z)
            if sq and here:canReachTo(sq) and SafeHouse.isSafehouseAllowLoot(sq, player) then
                local list = sq:getWorldObjects()
                for i = 0, list:size() - 1 do
                    local item = list:get(i):getItem()
                    local ft = item and item:getFullType()
                    if ft and usable(item) then out[ft] = (out[ft] or 0) + 1 end
                end
            end
        end
    end
    return out
end

-- 帶著沒壞的這種工具（ItemTag 欄位名；這個版本沒有的標籤當沒帶）。plan 與 summary 共用，兩邊才不會判斷不同。
-- 噴槍另外照型別找：42.21 的 item BlowTorch 沒有 Tags（scripts/generated/items/drainable.txt），沒有物品帶這個標籤，
-- 原版自己也照型別找（ISMoveableSpriteProps.lua:4-6、ISVehicleMenu.lua:878）。
local BY_TYPE = { BLOW_TORCH = "BlowTorch" }
local function hasTool(inv, name)
    local tag = ItemTag[name]
    if tag ~= nil and inv:getFirstTagEvalRecurse(tag, notBroken) ~= nil then return true end
    local ty = BY_TYPE[name]
    return ty ~= nil and inv:getFirstTypeEvalRecurse(ty, notBroken) ~= nil
end

-- cost＝Cost.sum 的結果。回 plan，或 nil, missing（fullType → 還差幾個）, tools（缺的 ItemTag 欄位名）
function Materials.plan(player, cost)
    local inv = player:getInventory()
    local missingTools
    for _, name in ipairs(cost.tools) do
        if not hasTool(inv, name) then
            missingTools = missingTools or {}
            missingTools[#missingTools + 1] = name
        end
    end
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
    if missing or missingTools then return nil, missing, missingTools end
    return { take = take, ground = ground, boxes = boxes, left = left }
end

-- 玩家此刻可用材料的摘要（客戶端預覽、目錄變暗用；不動任何東西）。和 plan 同一套找法：背包（含袋子）＋周圍 3×3
-- 走得到、可拿的地上物品，Base.Nails 另加背包裡的釘子盒每盒 100 根。
-- S.items[fullType]＝數量、S.tools[ItemTag 欄位名]＝true|false，都是第一次讀到才查（每種一次 Java 查詢，之後讀表），
-- 所以 pairs(S.items) 只列出查過的種類。S.cheat＝建造作弊（伺服器不扣料，Check 看它）。
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
    local tools = setmetatable({}, { __index = function(t, name)
        local v = hasTool(inv, name)
        rawset(t, name, v)
        return v
    end })
    return { items = items, tools = tools, cheat = player:isBuildCheat(), player = player }
end

-- 兩份摘要對已經查過的東西一樣嗎：只比 a 查過的種類與工具（b 照樣懶查）。介面用它判斷要不要清掉缺料標示。
-- 換了角色（死掉重生）不算一樣：懶查表綁著建它的那個角色。
function Materials.same(a, b)
    if not a or not b or a.cheat ~= b.cheat or a.player ~= b.player then return false end
    for k, v in pairs(a.items) do
        if b.items[k] ~= v then return false end
    end
    for k, v in pairs(a.tools) do
        if b.tools[k] ~= v then return false end
    end
    return true
end

-- 摘要夠不夠付 cost（Cost.sum 的結果）。回 missing（fullType → 還差幾個）或 nil、tools（缺的 ItemTag 欄位名）或 nil；
-- 同一個玩家狀態下，和 plan 的 missing、tools 相同（plan 成功時兩個都是 nil）。不看建造作弊。
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
    return missing, missingTools
end

-- 從摘要扣掉 cost.items（拖曳時照順序逐格累計：前面的格子用掉的，後面的不能再算）；不夠的扣到 0
function Materials.take(S, cost)
    for ft, n in pairs(cost.items) do
        local left = S.items[ft] - n
        S.items[ft] = left > 0 and left or 0
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

-- 照 plan 扣掉。拆開的釘子盒，用剩的釘子放回背包（buildUtil.openNailsBox）。
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
    -- 單機地上的少了，物品欄的「地上」要重畫（ISBuildUtil.lua:290-296）；MP 由移除封包觸發 OnContainerUpdate
    -- （RemoveItemFromSquarePacket.java:83-94）
    if #plan.ground > 0 and not isServer() and ISInventoryPage then ISInventoryPage.dirtyUI() end
end

return Materials
