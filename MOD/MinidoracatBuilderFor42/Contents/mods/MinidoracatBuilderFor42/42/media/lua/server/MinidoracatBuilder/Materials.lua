-- 材料（伺服器；單機在本機跑）：伺服器自己找，不收客戶端給的清單（bt-authority §5.1）。
-- 找的範圍照原版建造扣料（buildUtil.consumeMaterial，ISBuildUtil.lua:125-237）：背包（含袋子），不夠再找周圍 3×3 地上的物品。
-- ponytail：家具、車上的容器不找；要找時照 §5.1 逐個過安全屋拿取權限、上鎖與 2.5 格。
-- 先 plan（只找、不動），物件放好後才 consume，放失敗就不扣（§5.6）。扣料只在 complete() 跑，MP 只發生一次。
if isClient() then return end

MinidoracatBuilder = MinidoracatBuilder or {}
local Materials = MinidoracatBuilder.Materials or {}
MinidoracatBuilder.Materials = Materials

local function notBroken(item) return not item:isBroken() end
-- 裝著東西的袋子不能當材料（buildUtil.predicateMaterial）
local function usable(item)
    return not instanceof(item, "InventoryContainer") or item:getInventory():getItems():isEmpty()
end

-- 玩家所在格與周圍 8 格地上的物品：fullType → { IsoWorldInventoryObject, ... }。別人的安全屋裡的地上物品不拿。
local function groundItems(player)
    local out = {}
    local here = player:getCurrentSquare()
    if not here then return out end
    local cell, x, y, z = getCell(), here:getX(), here:getY(), here:getZ()
    for dy = -1, 1 do
        for dx = -1, 1 do
            local sq = cell:getGridSquare(x + dx, y + dy, z)
            if sq and SafeHouse.isSafehouseAllowLoot(sq, player) then
                local list = sq:getWorldObjects()
                for i = 0, list:size() - 1 do
                    local wo = list:get(i)
                    local item = wo:getItem()
                    if item and usable(item) then
                        local ft = item:getFullType()
                        local bucket = out[ft]
                        if not bucket then
                            bucket = {}
                            out[ft] = bucket
                        end
                        bucket[#bucket + 1] = wo
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
    local take, ground, missing, nearby = {}, {}, nil, nil
    for ft, n in pairs(cost.items) do
        local got = inv:getSomeTypeEvalRecurse(ft, usable, n)
        local have = got:size()
        for i = 0, have - 1 do take[#take + 1] = got:get(i) end
        if have < n then
            nearby = nearby or groundItems(player)
            local list = nearby[ft] or {}
            local k = math.min(n - have, #list)
            for i = 1, k do ground[#ground + 1] = list[i] end
            have = have + k
        end
        if have < n then
            missing = missing or {}
            missing[ft] = n - have
        end
    end
    if missing or missingTools then return nil, missing, missingTools end
    return { take = take, ground = ground }
end

-- 照 plan 扣掉。伺服器上 sendRemoveItemFromContainer 只送封包，要先 Remove（pitfalls：伺服器端 send 不動容器）。
function Materials.consume(player, plan)
    for _, item in ipairs(plan.take) do
        player:removeFromHands(item)
        local c = item:getContainer()
        if c then
            c:Remove(item)
            sendRemoveItemFromContainer(c, item)
        end
    end
    for _, wo in ipairs(plan.ground) do
        local sq = wo:getSquare()
        if sq then sq:transmitRemoveItemFromSquare(wo) end
    end
end

return Materials
