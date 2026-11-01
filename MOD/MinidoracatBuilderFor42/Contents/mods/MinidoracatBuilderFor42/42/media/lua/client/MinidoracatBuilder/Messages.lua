-- 拒絕碼 → 玩家看得懂的一句話＋補救。伺服器只送碼與欄位（need、tools、x,y,z），字在客戶端組：
-- 伺服器的語言不是玩家的語言（pz-family-docs pitfalls「伺服器組好的文字是伺服器的語言」）。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Materials"

MinidoracatBuilder = MinidoracatBuilder or {}
local Messages = MinidoracatBuilder.Messages or {}
MinidoracatBuilder.Messages = Messages
local Entry, USE = MinidoracatBuilder.Entry, MinidoracatBuilder.Materials.USE

-- 每個碼一個翻譯鍵 IGUI_MBLD_Refuse_<碼>：伺服器的拒絕碼（Server.intent／Check.item，含 Place.check 的放不下原因
-- SAME_TILE、VEHICLE、OCCUPIED、STACK_FULL，原地替換時舊的那件的 NOT_EMPTY、ATTACHED、NOT_OURS，硬核「需要技能」的
-- SKILL），加上客戶端自己判斷的
-- WALK（一格都還沒蓋就停下）、NO_ROOM（第 i 格旁邊沒有空位可站，Client.lua 的 queue）、游標的 OVER_MAX（超過一次拖曳
-- 最多幾項，extra.max）與 NO_FACE（長方形那一邊這款沒有對應的朝向）。
-- 不在表裡的碼退回 IGUI_MBLD_Refuse_Other 並附上碼，玩家回報時看得到。
Messages.CODES = { OFF = true, NOT_ALLOWED = true, STATE = true, STALE = true, RATE_LIMITED = true,
    BAD_REQUEST = true, NO_INTENT = true, UNKNOWN = true, UNSUPPORTED = true, DISABLED = true, BAD_FACE = true,
    TOO_FAR = true, UNREACHABLE = true, NOT_LOADED = true, SAFEHOUSE = true, PERM_DENIED = true,
    OUTSIDE_SAFEHOUSE = true, BLOCKED = true, NO_MATERIAL = true, NO_TOOL = true, INTERNAL = true, WALK = true,
    NO_ROOM = true, SAME_TILE = true, VEHICLE = true, OCCUPIED = true, STACK_FULL = true, OVER_MAX = true, NO_FACE = true,
    NOT_EMPTY = true, ATTACHED = true, NOT_OURS = true, SKILL = true }

-- 耗材鍵（Cost 的 uses）→ 名稱：tag:base:concrete 照標籤收（黏土漿、混凝土的桶子都算），寫通稱；其他是 fullType
function Messages.useName(key)
    if key == "tag:base:concrete" then return getText("IGUI_MBLD_Use_Concrete") end
    return getItemName(key) or key
end

-- need＝{ [fullType] = 數量 } → 「木板 ×2、釘子 ×4」。物品名照玩家語言（getItemName，LuaManager.java:8749；verify_mod 規定用它）。
-- 缺的耗材（鍵是 Materials.USE＋耗材鍵）寫次數：「焊條 2 次」
function Messages.items(need)
    local parts, n = {}, 0
    for ft, count in pairs(need or {}) do
        n = n + 1
        if ft:sub(1, #USE) == USE then
            parts[n] = getText("IGUI_MBLD_UseCount", Messages.useName(ft:sub(#USE + 1)), tostring(count))
        else
            parts[n] = getText("IGUI_MBLD_ItemCount", getItemName(ft), tostring(count))
        end
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
    if code == "OVER_MAX" then return getText(key, tostring(extra and extra.max or "")) end
    if code == "SKILL" then -- Check.item 的 { perk, level, have }
        local perk = extra and extra.perk
        return getText(key, perk and getText("IGUI_perks_" .. perk) or "?", tostring(extra and extra.level or ""),
            tostring(extra and extra.have or 0))
    end
    if code == "NO_ROOM" then -- 只送一格時不寫「第 1 格」
        if extra and extra.n == 1 then return getText("IGUI_MBLD_Refuse_NO_ROOM_One") end
        return getText(key, tostring(extra and extra.i or 1))
    end
    return getText(key)
end

-- 拆除的拒絕碼（Server.dismantleIntent／Server.dismantle、Dismantle.check）＋客戶端的 NO_ROOM（旁邊沒有空位可站）、
-- SCRAP（原版拆解現在不給拆，Client.dismantleMany 排原版動作前查）：翻譯鍵 IGUI_MBLD_UnbuildRefuse_<碼>。
-- 和建造分開：同一個碼的補救不同（「再蓋一次」對拆除是錯的）。
Messages.UNBUILD_CODES = { OFF = true, NOT_ALLOWED = true, STATE = true, BAD_REQUEST = true, NO_INTENT = true,
    TOO_FAR = true, UNREACHABLE = true, NOT_LOADED = true, GONE = true, NOT_OURS = true, SAFEHOUSE = true,
    PERM_DENIED = true, NOT_EMPTY = true, ATTACHED = true, FLOOR_IN_USE = true, STAIRS_TOP = true, NO_TOOL = true,
    INTERNAL = true, NO_ROOM = true, SCRAP = true }

function Messages.unbuildRefusal(code, extra)
    if not Messages.UNBUILD_CODES[code] then return getText("IGUI_MBLD_UnbuildRefuse_Other", tostring(code)) end
    local key = "IGUI_MBLD_UnbuildRefuse_" .. code
    if code == "NO_TOOL" then return getText(key, Messages.tools(extra and extra.tools)) end
    if code == "TOO_FAR" then return getText(key, tostring(Entry.settings().MaxDistance or 3)) end
    return getText(key)
end

-- 拆除碼的短字（一區拆除的確認面板、總結通知「裡面還有東西 1、框上裝著門 1」）：IGUI_MBLD_UnbuildShort_<碼>
function Messages.unbuildShort(code)
    if not Messages.UNBUILD_CODES[code] then return getText("IGUI_MBLD_UnbuildShort_Other", tostring(code)) end
    return getText("IGUI_MBLD_UnbuildShort_" .. code)
end

-- 照原因數件數，每個碼一行，件數多的在前（同數照碼名；逐筆插入，不用 table.sort，家族規則）。
-- counts＝{ [碼] = 件數 } 或 { [碼] = { n = 件數, extra = 拒絕附帶的欄位 } }（缺料、缺工具要 extra 才寫得出缺什麼）。
-- unbuild＝true：拆除碼的短字＋件數（「裡面還有東西 1」）；否則建造的一句話＋格數（游標拖一片時每種原因一行，審查 #6）
function Messages.reasons(counts, unbuild)
    local rows = {}
    for code, v in pairs(counts or {}) do
        local n = type(v) == "table" and v.n or v
        local i = #rows + 1
        while i > 1 and (rows[i - 1].n < n or (rows[i - 1].n == n and rows[i - 1].code > code)) do
            rows[i] = rows[i - 1]
            i = i - 1
        end
        rows[i] = { code = code, n = n, extra = type(v) == "table" and v.extra or nil }
    end
    local out = {}
    for i, r in ipairs(rows) do
        if unbuild then
            out[i] = getText("IGUI_MBLD_ShortCount", Messages.unbuildShort(r.code), tostring(r.n))
        else
            out[i] = getText("IGUI_MBLD_ReasonCount", tostring(r.n), Messages.refusal(r.code, r.extra))
        end
    end
    return out
end

-- 拆除跳過的原因接成一行（「裡面還有東西 1、框上裝著門 1」）
function Messages.skipped(counts)
    return table.concat(Messages.reasons(counts, true), getText("IGUI_MBLD_ListSep"))
end

-- 拆除的總結通知（Client.pendingUnbuild 輪完、停下時）：回 text, title。summary＝{ done, total, skipped = { [碼] = 件數 },
-- refund = { [fullType] = 件數 }, stopped }；name＝只拆一件時那件的名稱。
--   一件、拆好：「名稱：退回 …。」　一件、拆不了：那個碼的拆除拒絕句。
--   多件：「拆了 N 件，退回 …。」　停下：「拆了 N／M 件後停下，退回 …。」，有跳過的再加「留著 K 件：原因 數…。」
function Messages.unbuildSummary(summary, name)
    local done, total = summary.done or 0, summary.total or 0
    local back
    for _ in pairs(summary.refund or {}) do back = Messages.items(summary.refund) break end -- Kahlua 沒有全域 next
    back = back or getText("IGUI_MBLD_RefundNothing")
    if total == 1 and not summary.stopped then
        if done == 1 then return getText("IGUI_MBLD_UnbuildSummary_One", name or "", back), getText("IGUI_MBLD_UnbuildDone") end
        local code
        for c in pairs(summary.skipped or {}) do code = c break end
        return Messages.unbuildRefusal(code), getText("IGUI_MBLD_NotRemoved")
    end
    local text, title
    if summary.stopped then
        text = getText("IGUI_MBLD_UnbuildSummary_Stopped", tostring(done), tostring(total), back)
        title = getText("IGUI_MBLD_UnbuildStopped")
    else
        text = getText("IGUI_MBLD_UnbuildSummary_Many", tostring(done), back)
        title = getText("IGUI_MBLD_UnbuildDone")
    end
    local kept = 0
    for _, n in pairs(summary.skipped or {}) do kept = kept + n end
    if kept > 0 then
        text = text .. " " .. getText("IGUI_MBLD_UnbuildSummary_Kept", tostring(kept), Messages.skipped(summary.skipped))
    end
    return text, title
end

-- 跳出通知：家族框架的 Toast（右上一欄，所有 MOD 共用堆疊），沒有框架時退回原版頭頂紅字。title 省略＝「無法建造」；
-- maxLines 省略＝8（超過的最後一行截字；Toast 只長到實際行數）。4 行時 CatLang 字型下英文的缺料句就放不下，
-- 法、西、德文更寬
function Messages.toast(player, text, title, maxLines)
    local UI = MinidoracatUI and MinidoracatUI.v1
    if UI and UI.Toast and UI.Toast.show then
        UI.Toast.show({ title = title or getText("IGUI_MBLD_NotBuilt"), message = text, maxLines = maxLines or 8 })
    elseif player then
        HaloTextHelper.addBadText(player, text)
    end
end

return Messages
