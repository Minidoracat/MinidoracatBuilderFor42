-- 本工具蓋的燈，引擎不會照電力亮暗的兩種，客戶端自己補（只動這台客戶端的光源與附加圖）：
-- 一、IsoThumpable 帶 lightR：引擎在加進世界時照 checkObjectPowered 建光源（IsoObject.java:6510-6540），之後靠
--   checkLightSourceActive 更新（停電、發電機開關時，IsoObject.java:5183,6557-6565），它讀 getLightSource()；IsoThumpable
--   改寫成回自己的燃料燈欄位（IsoThumpable.java:1761-1763），所以光源停在加進世界那刻。每遊戲分鐘照同一個判斷補做一次。
-- 二、路燈（sprite 帶 streetlight 的 IsoLightSwitch）：引擎只在夜裡、那格有市電時點亮它的光源與亮燈圖
--   （LightingJNI.java:282-294、IsoLightSwitch.java:873-885），發電機、電池都不算。夜裡、沒有市電、開著又有其他電
--   （canSwitchLight）時，在那格另加一盞同色同半徑的光源（addLamppost：不是 hydroPowered、沒有開關，引擎不套路燈規則，
--   IsoCell.java:2803-2806、LightingJNI.java:266-296），亮燈圖（同號 _on 圖塊，IsoObject.java:6081-6087）掛成附加圖；
--   有市電時交給引擎。附加圖跟著物件存檔（IsoObject.java:1352-1370），單機讀檔後照樣由這裡判斷留著或收掉。
MinidoracatBuilder = MinidoracatBuilder or {}
local Lights = MinidoracatBuilder.Lights or {}
MinidoracatBuilder.Lights = Lights

-- 光源 → false（不歸本工具管）、{ thump = IsoThumpable }（照 sprite 建的光源）或路燈紀錄 { sw, own, extra, act }。
-- 光源跟著物件建、跟著物件拆，擁有者不會變；每次只留還在清單上的
local owners = {}
local street = {} -- 路燈（IsoLightSwitch）→ 紀錄
local extras = {} -- 補的光源 → true（在清單上不當成別人的光源）
local ON = {}     -- sprite 名稱 → 亮燈圖（IsoSprite）或 false

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
    if l:isHydroPowered() then
        -- 開關的燈都是 hydroPowered，第一個開關就是燈自己（IsoLightSwitch.java:130-135、CellLoader.java:119-121）
        local sws = l:getSwitches()
        local sw = sws:size() > 0 and sws:get(0) or nil
        if not (sw and sw:hasModData() and sw:getModData().builderEntry and sw:getProperties():has("streetlight")) then
            return false
        end
        local rec = street[sw] -- 同一盞燈換了光源（重建）時沿用紀錄，補的光源才收得掉
        if rec then
            rec.own = l
            return rec
        end
        return { sw = sw, own = l }
    end
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
    return found and { thump = found } or false
end

-- 亮燈圖：sprite 有 HasLightOnSprite、同號的 _on 圖塊存在（引擎同一個找法，IsoObject.java:6081-6087）
local function onSprite(spr)
    local name = spr and spr:getName()
    if not name then return false end
    local v = ON[name]
    if v == nil then
        v = false
        local base, n = string.match(name, "^(.+)_(%d+)$")
        local map = IsoSpriteManager.instance:getNamedMap()
        if base and spr:getProperties():has(IsoFlagType.HasLightOnSprite) and map:containsKey(base .. "_on_" .. n) then
            v = map:get(base .. "_on_" .. n)
        end
        ON[name] = v
    end
    return v
end

local function showOn(sw, show)
    local on = onSprite(sw:getSprite())
    if not on then return end
    if show then
        if not sw:isAttachedAnimSprite(on) then sw:addAttachedAnimSprite(on) end
        return
    end
    local list = sw:getAttachedAnimSprite()
    for i = (list and list:size() or 0) - 1, 0, -1 do
        if list:get(i):getParentSprite() == on then sw:RemoveAttachedAnim(i) end
    end
end

local function dropExtra(rec)
    if not rec.extra then return false end
    getCell():removeLamppost(rec.extra)
    extras[rec.extra] = nil
    rec.extra = nil
    return true
end

local function isNight() return getGameTime():getNight() >= 0.5 end

-- 路燈照現在的狀態補或收；回有沒有動到光源
local function apply(rec, night)
    local sw, own = rec.sw, rec.own
    rec.act = sw:isActivated()
    local want = rec.act and night and not sw:hasGridPower() and sw:canSwitchLight()
    local x, changed = rec.extra, false
    -- 顏色跟著燈自己的光源（換彩色燈泡；客戶端剛收到時才補顏色，Client.lua onAdded）
    if x and not (want and x:getR() == own:getR() and x:getG() == own:getG() and x:getB() == own:getB()) then
        changed = dropExtra(rec)
        x = nil
    end
    if want and not x then
        x = getCell():addLamppost(own:getX(), own:getY(), own:getZ(), own:getR(), own:getG(), own:getB(), own:getRadius())
        rec.extra, extras[x], changed = x, true, true
    end
    showOn(sw, want)
    return changed
end

-- 回這次切了幾盞（E2E 讀）
function Lights.sync()
    local cell = getCell()
    if not cell then return 0 end
    local list, keep, lamps, changed = cell:getLamppostPositions(), {}, {}, 0
    for i = 0, list:size() - 1 do
        local l = list:get(i)
        if not extras[l] then
            local o = owners[l]
            if o == nil then o = ownerOf(l) end
            keep[l] = o
            if o and o.sw then
                lamps[o.sw] = o
            elseif o then
                local want = o.thump:checkObjectPowered()
                if l:isActive() ~= want then
                    l:setActive(want)
                    changed = changed + 1
                end
            end
        end
    end
    owners = keep
    -- 路燈不在清單上了（拆掉、走遠卸載）：收掉補的光源；物件可能已經不在世界，不碰它
    for sw, rec in pairs(street) do
        if not lamps[sw] and dropExtra(rec) then changed = changed + 1 end
    end
    street = lamps
    local night
    for _, rec in pairs(lamps) do
        if night == nil then night = isNight() end
        if apply(rec, night) then changed = changed + 1 end
    end
    if changed > 0 then IsoGridSquare.setRecalcLightTime(-1) end
    return changed
end

-- 按燈、按開關（伺服器同步過來）當下就跟，不等下一個遊戲分鐘
local function onTick()
    local night
    for sw, rec in pairs(street) do
        if sw:isActivated() ~= rec.act then
            if night == nil then night = isNight() end
            if apply(rec, night) then IsoGridSquare.setRecalcLightTime(-1) end
        end
    end
end

Events.EveryOneMinute.Add(Lights.sync)
Events.OnTick.Add(onTick)
Events.OnObjectAboutToBeRemoved.Add(function(obj)
    local rec = street[obj]
    if rec then
        dropExtra(rec)
        street[obj] = nil
    end
end)

return Lights
