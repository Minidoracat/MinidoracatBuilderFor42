-- 拒絕碼 → 玩家看得懂的一句話＋補救。伺服器只送碼與欄位（need、tools、x,y,z），字在客戶端組：
-- 伺服器的語言不是玩家的語言（pz-family-docs pitfalls「伺服器組好的文字是伺服器的語言」）。
require "MinidoracatBuilder/Entry"

MinidoracatBuilder = MinidoracatBuilder or {}
local Messages = MinidoracatBuilder.Messages or {}
MinidoracatBuilder.Messages = Messages
local Entry = MinidoracatBuilder.Entry

-- 每個碼一個翻譯鍵 IGUI_MBLD_Refuse_<碼>：伺服器的拒絕碼（Server.intent／Check.item），加上客戶端自己判斷的
-- WALK（一格都還沒蓋就停下）與 NO_ROOM（第 i 格旁邊沒有空位可站，Client.lua 的 queue）。
-- 不在表裡的碼退回 IGUI_MBLD_Refuse_Other 並附上碼，玩家回報時看得到。
Messages.CODES = { OFF = true, NOT_ALLOWED = true, STATE = true, STALE = true, RATE_LIMITED = true,
    BAD_REQUEST = true, NO_INTENT = true, UNKNOWN = true, UNSUPPORTED = true, DISABLED = true, BAD_FACE = true,
    TOO_FAR = true, UNREACHABLE = true, NOT_LOADED = true, SAFEHOUSE = true, PERM_DENIED = true,
    OUTSIDE_SAFEHOUSE = true, BLOCKED = true, NO_MATERIAL = true, NO_TOOL = true, INTERNAL = true, WALK = true,
    NO_ROOM = true }

-- need＝{ [fullType] = 數量 } → 「木板 ×2、釘子 ×4」。物品名照玩家語言（getItemName，LuaManager.java:8749；verify_mod 規定用它）。
function Messages.items(need)
    local parts, n = {}, 0
    for ft, count in pairs(need or {}) do
        n = n + 1
        parts[n] = getText("IGUI_MBLD_ItemCount", getItemName(ft), tostring(count))
    end
    return table.concat(parts, getText("IGUI_MBLD_ListSep"))
end

-- tools＝ItemTag 欄位名陣列（Cost 的 tools，例 HAMMER）→ 名稱。沒有翻譯的照原名。
function Messages.tools(tools)
    local parts = {}
    for i, tag in ipairs(tools or {}) do
        parts[i] = getTextOrNull("IGUI_MBLD_Tool_" .. tag) or tag
    end
    return table.concat(parts, getText("IGUI_MBLD_ListSep"))
end

-- 缺料那句也列缺的工具：伺服器缺料時 NO_MATERIAL 的 tools 欄位照樣帶著缺的工具（Server.complete 的 Materials.plan）
function Messages.missing(need, tools)
    local what = Messages.items(need)
    if tools and #tools > 0 then
        what = (what ~= "" and what .. getText("IGUI_MBLD_ListSep") or "") .. Messages.tools(tools)
    end
    return what
end

function Messages.refusal(code, extra)
    if not Messages.CODES[code] then return getText("IGUI_MBLD_Refuse_Other", tostring(code)) end
    local key = "IGUI_MBLD_Refuse_" .. code
    if code == "NO_MATERIAL" then return getText(key, Messages.missing(extra and extra.need, extra and extra.tools)) end
    if code == "NO_TOOL" then return getText(key, Messages.tools(extra and extra.tools)) end
    if code == "TOO_FAR" then return getText(key, tostring(Entry.settings().MaxDistance or 3)) end
    if code == "NO_ROOM" then -- 只送一格時不寫「第 1 格」
        if extra and extra.n == 1 then return getText("IGUI_MBLD_Refuse_NO_ROOM_One") end
        return getText(key, tostring(extra and extra.i or 1))
    end
    return getText(key)
end

-- 拆除的拒絕碼（Server.dismantleIntent／Server.dismantle、Dismantle.check）＋NO_ROOM（旁邊沒有空位可站）：
-- 翻譯鍵 IGUI_MBLD_UnbuildRefuse_<碼>。和建造分開：同一個碼的補救不同（「再蓋一次」對拆除是錯的）。
Messages.UNBUILD_CODES = { OFF = true, NOT_ALLOWED = true, STATE = true, BAD_REQUEST = true, NO_INTENT = true,
    TOO_FAR = true, UNREACHABLE = true, NOT_LOADED = true, GONE = true, NOT_OURS = true, SAFEHOUSE = true,
    PERM_DENIED = true, NOT_EMPTY = true, ATTACHED = true, FLOOR_IN_USE = true, STAIRS_TOP = true, NO_TOOL = true,
    INTERNAL = true, NO_ROOM = true }

function Messages.unbuildRefusal(code, extra)
    if not Messages.UNBUILD_CODES[code] then return getText("IGUI_MBLD_UnbuildRefuse_Other", tostring(code)) end
    local key = "IGUI_MBLD_UnbuildRefuse_" .. code
    if code == "NO_TOOL" then return getText(key, Messages.tools(extra and extra.tools)) end
    if code == "TOO_FAR" then return getText(key, tostring(Entry.settings().MaxDistance or 3)) end
    return getText(key)
end

-- 跳出通知：家族框架的 Toast（右上一欄，所有 MOD 共用堆疊），沒有框架時退回原版頭頂紅字。title 省略＝「無法建造」。
function Messages.toast(player, text, title)
    local UI = MinidoracatUI and MinidoracatUI.v1
    if UI and UI.Toast and UI.Toast.show then
        UI.Toast.show({ title = title or getText("IGUI_MBLD_NotBuilt"), message = text, maxLines = 4 })
    elseif player then
        HaloTextHelper.addBadText(player, text)
    end
end

return Messages
