-- 同一套牆（設計稿 builder-hardcore-sets-1101 claim 1.3、2；使用者 2026-11-01 選 both、filter）：原版牆的圖塊表一列 8 格、
-- 兩列一組，左右各一套（例 walls_exterior_house_01：0–3＋8–11 一套、4–7＋12–15 一套）。套裡的位置：
--   0 牆西、1 牆北、2 牆角、3 柱子、8 窗框西、9 窗框北、10 門框西、11 門框北。
-- 兩端共用：Cost 照同一套的牆補柱子、框的 MaterialType；建造視窗的「整套」照它列。
MinidoracatBuilder = MinidoracatBuilder or {}
local Sets = MinidoracatBuilder.Sets or {}
MinidoracatBuilder.Sets = Sets

Sets.OFFSETS = { 0, 1, 2, 3, 8, 9, 10, 11 }
Sets.ROLES = { [0] = "WallW", [1] = "WallN", [2] = "Corner", [3] = "Post", [8] = "WindowW", [9] = "WindowN",
    [10] = "DoorW", [11] = "DoorN" }
-- 每個位置該是的種類（Rules.classify）
local KIND = { [0] = "wall", [1] = "wall", [2] = "wall", [3] = "post", [8] = "windowFrame", [9] = "windowFrame",
    [10] = "doorFrame", [11] = "doorFrame" }

-- 名稱 → tileset, 這一套第一張的編號, 這張在套裡的位置（0–3、8–11）。不是「名稱_編號」回 nil
function Sets.locate(name)
    local tileset, num = name:match("^(.*)_(%d+)$")
    if not tileset then return nil end
    num = tonumber(num)
    local base = math.floor(num / 16) * 16 + math.floor((num % 8) / 4) * 4
    return tileset, base, num - base
end

local WALL = { "WallW", "WallN", "WallNW", "WallWTrans", "WallNTrans", "WallNWTrans" } -- 同 Rules.classify 的牆
local function isWall(p)
    for i = 1, #WALL do
        if p:has(WALL[i]) then return true end
    end
    return false
end

-- 這一張那一套的牆（位置 0、1、2）第一個帶 MaterialType 的值；沒有回 nil。圖塊載入後不會變，查過的記著
local matOf = {}
function Sets.wallMaterial(name)
    local tileset, base = Sets.locate(name)
    if not tileset then return nil end
    local key = tileset .. "_" .. base
    local mt = matOf[key]
    if mt == nil then
        mt = false
        local named = IsoSpriteManager.instance:getNamedMap()
        for d = 0, 2 do
            local n = tileset .. "_" .. (base + d)
            if named:containsKey(n) then
                local p = named:get(n):getProperties()
                local v = p:get("MaterialType")
                if v and isWall(p) then
                    mt = v
                    break
                end
            end
        end
        matOf[key] = mt
    end
    return mt or nil
end

-- 整套：這一張那一套裡 kindOf(名稱) 有回種類的（在目錄、沒被關掉），照 OFFSETS 排。每張的種類都要合它的位置、
-- 至少兩張、其中有一面牆（位置 0 或 1）才算一套，不然回 nil（表的排法不同，例如柵欄表的 0 是柱子：建造視窗
-- 改列同一個 tileset，Window.lua 的 W.setOf）。回 { n, 名稱… }, { [名稱] = 位置 }
function Sets.of(name, kindOf)
    local tileset, base = Sets.locate(name)
    if not tileset then return nil end
    local out, at, wall = { n = 0 }, {}, false
    for _, off in ipairs(Sets.OFFSETS) do
        local n = tileset .. "_" .. (base + off)
        local kind = kindOf(n)
        if kind then
            if kind ~= KIND[off] then return nil end
            out.n = out.n + 1
            out[out.n] = n
            at[n] = off
            if off <= 1 then wall = true end
        end
    end
    if out.n >= 2 and wall then return out, at end
    return nil
end

return Sets
