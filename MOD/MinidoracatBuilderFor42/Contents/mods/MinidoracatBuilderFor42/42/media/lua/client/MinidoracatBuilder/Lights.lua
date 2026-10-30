-- 本工具蓋的 IsoThumpable 帶 lightR 時，照 sprite 建的光源跟著電力亮暗（只有客戶端有這種光源）。
-- 引擎在加進世界時照 checkObjectPowered 建光源（IsoObject.java:6510-6540），之後靠 checkLightSourceActive 更新
-- （停電、發電機開關時，IsoObject.java:5183,6557-6565），它讀 getLightSource()；IsoThumpable 改寫成回自己的燃料燈欄位
-- （IsoThumpable.java:1761-1763），所以光源停在加進世界那刻。這裡每遊戲分鐘照同一個判斷補做一次。
MinidoracatBuilder = MinidoracatBuilder or {}
local Lights = MinidoracatBuilder.Lights or {}
MinidoracatBuilder.Lights = Lights

-- 光源 → 擁有它的本工具物件，不是的記 false。光源跟著物件建、跟著物件拆，擁有者不會變；每次只留還在清單上的
local owners = {}

-- 照 sprite 建的光源：顏色是 lightR/G/B ÷ 255，半徑是 LightRadius（沒有或 ≤ 0 時 10）（IsoObject.java:6527-6535）
local function same(l, p)
    local r, g, b = tonumber(p:get("lightR")), tonumber(p:get("lightG")), tonumber(p:get("lightB"))
    if not (r and g and b) then return false end
    local rad = tonumber(p:get("LightRadius")) or 0
    if rad <= 0 then rad = 10 end
    return l:getRadius() == rad and math.abs(l:getR() * 255 - r) < 0.01
        and math.abs(l:getG() * 255 - g) < 0.01 and math.abs(l:getB() * 255 - b) < 0.01
end

local function ownerOf(l)
    -- 開關的燈都是 hydroPowered（IsoLightSwitch.java:130-133、CellLoader.java:119-121）
    if l:isHydroPowered() then return false end
    local sq = getCell():getGridSquare(l:getX(), l:getY(), l:getZ())
    if not sq then return false end
    local objs, found = sq:getObjects(), false
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        -- 拿得到的光源都有主人：一般物件與火照 sprite 建的、IsoThumpable 的燃料燈
        if o:getLightSource() == l then return false end
        if not found and instanceof(o, "IsoThumpable") and o:hasModData() and o:getModData().builderEntry then
            local p = o:getProperties()
            if p and p:has("lightR") and same(l, p) then found = o end
        end
    end
    return found
end

-- 回這次切了幾盞（E2E 讀）
function Lights.sync()
    local cell = getCell()
    if not cell then return 0 end
    local list, keep, changed = cell:getLamppostPositions(), {}, 0
    for i = 0, list:size() - 1 do
        local l = list:get(i)
        local o = owners[l]
        if o == nil then o = ownerOf(l) end
        keep[l] = o
        if o then
            local want = o:checkObjectPowered()
            if l:isActive() ~= want then
                l:setActive(want)
                changed = changed + 1
            end
        end
    end
    owners = keep
    if changed > 0 then IsoGridSquare.setRecalcLightTime(-1) end
    return changed
end

Events.EveryOneMinute.Add(Lights.sync)

return Lights
