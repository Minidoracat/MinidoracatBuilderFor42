-- 拒絕碼 → 玩家看得懂的一句話＋補救。伺服器只送碼與欄位（need、tools、x,y,z），字在客戶端組：
-- 伺服器的語言不是玩家的語言（pz-family-docs pitfalls「伺服器組好的文字是伺服器的語言」）。
require "MinidoracatBuilder/Entry"

MinidoracatBuilder = MinidoracatBuilder or {}
local Messages = MinidoracatBuilder.Messages or {}
MinidoracatBuilder.Messages = Messages
local Entry = MinidoracatBuilder.Entry

-- 每個碼一個翻譯鍵 IGUI_MBLD_Refuse_<碼>：伺服器的拒絕碼（Server.intent／Check.item）與 WALK（游標判斷的走不到）。
-- 不在表裡的碼退回 IGUI_MBLD_Refuse_Other 並附上碼，玩家回報時看得到。
Messages.CODES = { OFF = true, NOT_ALLOWED = true, STATE = true, STALE = true, RATE_LIMITED = true,
    BAD_REQUEST = true, NO_INTENT = true, UNKNOWN = true, UNSUPPORTED = true, DISABLED = true, BAD_FACE = true,
    TOO_FAR = true, UNREACHABLE = true, NOT_LOADED = true, SAFEHOUSE = true, PERM_DENIED = true,
    OUTSIDE_SAFEHOUSE = true, BLOCKED = true, NO_MATERIAL = true, NO_TOOL = true, INTERNAL = true, WALK = true }

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
    return getText(key)
end

-- 跳出通知：家族框架的 Toast（右上一欄，所有 MOD 共用堆疊），沒有框架時退回原版頭頂紅字。
function Messages.toast(player, text)
    local UI = MinidoracatUI and MinidoracatUI.v1
    if UI and UI.Toast and UI.Toast.show then
        UI.Toast.show({ title = getText("IGUI_MBLD_NotBuilt"), message = text, maxLines = 4 })
    elseif player then
        HaloTextHelper.addBadText(player, text)
    end
end

return Messages
