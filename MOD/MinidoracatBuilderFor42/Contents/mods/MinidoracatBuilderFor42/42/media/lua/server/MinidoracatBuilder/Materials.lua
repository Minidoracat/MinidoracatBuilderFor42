-- 材料（伺服器；單機在本機跑）：伺服器自己找，不收客戶端給的清單（bt-authority §5.1）。
-- 找的順序照原版建造扣料（buildUtil.consumeMaterial，ISBuildUtil.lua:125-237）：背包（含袋子）→ 周圍 3×3 地上 →
-- 釘子還不夠就拆背包裡的釘子盒。差別：地上以玩家所在格為中心（原版以建造格為中心），隔牆、隔關著的門窗的不拿。
-- ponytail：家具、車上的容器不找；要找時照 §5.1 逐個過安全屋拿取權限、上鎖與 2.5 格。
-- 先 plan（只找、不動），物件放好後才 consume，放失敗就不扣（§5.6）。扣料只在 complete() 跑，MP 只發生一次。
if isClient() then return end

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

-- cost＝Cost.sum 的結果。回 plan，或 nil, missing（fullType → 還差幾個）, tools（缺的 ItemTag 欄位名）
function Materials.plan(player, cost)
    local inv = player:getInventory()
    local missingTools
    for _, name in ipairs(cost.tools) do
        local tag = ItemTag[name]
        if not (tag and inv:getFirstTagEvalRecurse(tag, notBroken)) then
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
