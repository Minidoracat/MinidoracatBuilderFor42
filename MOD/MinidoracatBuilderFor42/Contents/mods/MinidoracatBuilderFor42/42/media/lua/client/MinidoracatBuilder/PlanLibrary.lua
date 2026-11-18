-- 藍圖庫：列出 Zomboid/Lua/MinidoracatBuilder/plans/ 的藍圖檔，搜尋、排序、擺到地上、分享碼、改名、複製、刪除；
-- 匯入框（貼分享碼或讀資料夾裡別人給的檔）；地上的藍圖遇到 MOD 更新或下架時的告知（L.notices）。
-- 打開時只列檔名（PlanFile.list），檔頭（名稱、大小、片數、項目）在視窗的 prerender 裡分幀補（L.pump：每幀最多
-- HEAD_MAX 個或 HEAD_MS 毫秒），所以 1,000 個檔時打開的那一下不讀檔頭；擺到地上、分享時才讀整份。
-- 「這裡不能蓋」問 PlanCheck.item（能不能蓋只判斷一份），每種項目在一次打開藍圖庫裡只問一次。
-- 「最近用過」的時間存本機 plans-used.txt（一行「檔名<Tab>秒」，最後一行 #end；讀寫做法同 Favorites.lua：
-- 讀到 #end 才算完整、寫完讀回比對）。藍圖的一切只在客戶端：不送指令、不寫 modData。
-- 別的藍圖模組（PlanMode、PlanCheck、Capture）一律晚綁定：載入順序照檔名，別的包也可能還沒寫完。
require "MinidoracatBuilder/Plan"
require "MinidoracatBuilder/PlanFile"
require "MinidoracatBuilder/PlanStore"
require "MinidoracatBuilder/Messages"

MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local first = B.PlanLibrary == nil
local L = B.PlanLibrary or {}
B.PlanLibrary = L
local Plan, PlanFile, PlanStore, Messages = B.Plan, B.PlanFile, B.PlanStore, B.Messages

local LOG = "[MinidoracatBuilderFor42] "
L.USED_FILE = "MinidoracatBuilder/plans-used.txt"
L.HEAD_MS, L.HEAD_MAX = 2, 25
-- shortcut: 超過這個字數就提示改傳檔案（常見聊天軟體單則上限 2,000 字）；玩家回報別的管道更短再調
L.SHARE_LONG = 2000
L.CAPS = { "window", "controls", "dialog", "focus", "table", "scrollPanel", "dropdown", "textWrap" }
-- PlanFile 的原因碼（temp 契約 PlanData 第 2 節）：每個碼一個 IGUI_MBLD_PlanErr_<碼>，句子寫出下一步
L.ERRORS = { FORMAT = true, VERSION = true, NO_END = true, NAME = true, RANGE = true, COUNT = true, ITEM = true,
    FULL = true, DUP = true, TOO_BIG = true, CHECKSUM = true, DELETED = true, FILE = true, NO_FILE = true, WRITE = true,
    READ = true }
L.SORTS = { "used", "name", "pieces" }
L.LIST_MAX = 30 -- 匯入結果最多列幾種缺的項目、幾個 MOD：每種一列加一顆鈕，陌生藍圖可能有上千種
local PAD, GAP = 8, 6
local END = "#end"
local MAX_USED = 5000

-- ---------------------------------------------------------------- 共用小工具（PlanPanel 也用）

-- 由下往上的合併排序：穩定、不遞迴（Kahlua 的 table.sort 是遞迴快排，幾百筆已排好的資料就爆堆疊）
function L.sort(list, less)
    local n = #list
    if n < 2 then return list end
    local buf, width = {}, 1
    while width < n do
        local i = 1
        while i <= n do
            local mid, hi = math.min(i + width - 1, n), math.min(i + width * 2 - 1, n)
            local a, b, k = i, mid + 1, i
            while a <= mid and b <= hi do
                if less(list[b], list[a]) then
                    buf[k] = list[b]
                    b = b + 1
                else
                    buf[k] = list[a]
                    a = a + 1
                end
                k = k + 1
            end
            while a <= mid do buf[k] = list[a]; a = a + 1; k = k + 1 end
            while b <= hi do buf[k] = list[b]; b = b + 1; k = k + 1 end
            i = i + width * 2
        end
        for j = 1, n do list[j] = buf[j] end
        width = width * 2
    end
    return list
end

function L.tell(text)
    print(LOG .. tostring(text))
    Messages.toast(nil, text, getText("IGUI_MBLD_Lib_Title"))
end

-- PlanFile 的原因碼 → 句子；pos＝行號或分享碼的第幾段（0 或 nil 不寫）
function L.errText(code, pos)
    local s = L.ERRORS[code] and getText("IGUI_MBLD_PlanErr_" .. code) or getText("IGUI_MBLD_PlanErr_Other", tostring(code))
    if type(pos) == "number" and pos > 0 then s = s .. getText("IGUI_MBLD_PlanErr_At", tostring(pos)) end
    return s
end

-- 框架探測交給建造視窗的 W.ui（同一套最低版本與旗標檢查）
function L.ui()
    local W = B.Window
    if W and W.ui then return W.ui(L.CAPS) end
    return nil
end

function L.usingPad(pn)
    return JoypadState ~= nil and JoypadState.players ~= nil and JoypadState.players[pn + 1] ~= nil
end

-- 確認框：o＝{ title, text, ok, cancel?, single?, danger?, input?, onYes(text), onNo() }。框架不擋操作的 Dialog
-- （rev 26；舊框架忽略 modal／anchor，照舊置中加遮罩）；滑鼠時開在游標旁。回 dialog；沒有框架回 nil（不做事）
function L.confirm(pn, o)
    local UI = L.ui()
    if not UI then
        L.tell(getText("IGUI_MBLD_NeedFramework"))
        return nil
    end
    return UI.Dialog.show({ title = o.title, text = o.text, confirmText = o.ok,
        cancelText = not o.single and (o.cancel or getText("UI_Cancel")) or nil, danger = o.danger == true,
        input = o.input, opaque = true, theme = UI.Theme.create({ variant = "dark" }), modal = false,
        anchor = not L.usingPad(pn) and "mouse" or nil,
        onResult = function(ok, text)
            if ok then
                if o.onYes then o.onYes(text) end
            elseif o.onNo then
                o.onNo()
            end
        end })
end

-- 透明面板：畫 lines＝{ { s, tok }… }（tok＝theme 色名，省略＝text）。setLines 照寬度換行並設高度
local function drawLines(p)
    local c, fh = p.colors, p.fh
    for i, ln in ipairs(p.lines) do
        local col = c[ln.tok or "text"] or c.text
        p:drawText(ln.s, 0, (i - 1) * fh, col.r, col.g, col.b, col.a or 1, p.font)
    end
end

function L.textPanel(parent, x, y, w, theme, font)
    local p = ISPanel:new(x, y, w, 1)
    p:initialise()
    p.background = false
    p.colors, p.font, p.fh, p.lines = theme.colors, font, getTextManager():getFontHeight(font), {}
    p.render = drawLines
    parent:addChild(p)
    return p
end

function L.setLines(p, src)
    local UI = MinidoracatUI and MinidoracatUI.v1
    local wrap = UI and UI.Text and UI.Text.wrap
    local out = {}
    for _, ln in ipairs(src) do
        local parts = wrap and wrap(ln[1], p.width, p.font) or { ln[1] }
        for _, s in ipairs(parts) do out[#out + 1] = { s = s, tok = ln[2] } end
    end
    p.lines = out
    p:setHeight(math.max(1, #out * p.fh))
    return p.height
end

-- 由左而右排，放不下換行；回最後一列的下緣
function L.flow(items, x, y, w)
    local cx, rowH = x, 0
    for _, b in ipairs(items) do
        if cx > x and cx + b.width > x + w then
            cx, y, rowH = x, y + rowH + GAP, 0
        end
        b:setX(cx)
        b:setY(y)
        cx = cx + b.width + GAP
        rowH = math.max(rowH, b.height)
    end
    return y + rowH
end

function L.flowHeight(items, w)
    local cx, h, rowH = 0, 0, 0
    for _, b in ipairs(items) do
        if cx > 0 and cx + b.width > w then
            h, cx, rowH = h + rowH + GAP, 0, 0
        end
        cx = cx + b.width + GAP
        rowH = math.max(rowH, b.height)
    end
    return h + rowH
end

-- ---------------------------------------------------------------- 引擎函式（不存在的平台：按鈕不顯示或改寫路徑）

-- 藍圖資料夾的絕對路徑：getMyDocumentFolder＝Zomboid 資料夾（Core.java:1251-1253），getFileReader 的路徑相對它的 Lua/
function L.folder()
    if type(getMyDocumentFolder) ~= "function" or type(getFileSeparator) ~= "function" then return nil end
    local ok, root = pcall(getMyDocumentFolder)
    local okSep, sep = pcall(getFileSeparator)
    if not (ok and okSep and root and sep) then return nil end
    return root .. sep .. "Lua" .. sep .. "MinidoracatBuilder" .. sep .. "plans"
end

-- showFolderInDesktop 只開允許的前綴底下、而且已存在的資料夾（LuaManager.java:7369-7393，ZomboidFileSystem.java:1457-1470；
-- 前綴含 Zomboid 資料夾，:65-71）
function L.canOpenFolder()
    if type(showFolderInDesktop) ~= "function" or L.folder() == nil then return false end
    if type(isDesktopOpenSupported) == "function" then
        local ok, yes = pcall(isDesktopOpenSupported)
        return ok and yes == true
    end
    return true
end

function L.folderText()
    return getText("IGUI_MBLD_Lib_FolderPath", L.folder() or "Zomboid/Lua/MinidoracatBuilder/plans")
end

function L.openFolder()
    if not L.canOpenFolder() then
        L.tell(L.folderText())
        return false
    end
    -- 還沒有藍圖檔時資料夾可能還不存在（第一次存檔才建），引擎遇到不存在的資料夾什麼都不做
    if L.st and #L.st.files == 0 then
        L.tell(getText("IGUI_MBLD_Lib_FolderEmpty", L.folder()))
        return false
    end
    local ok = pcall(showFolderInDesktop, L.folder())
    if not ok then L.tell(L.folderText()) end
    return ok
end

-- 開工作坊頁：Steam 版、遮罩開著才有作用（LuaManager.java:9382-9389；原版 MissedModsPanel.lua:34）
function L.canWorkshop()
    if type(activateSteamOverlayToWorkshopItem) ~= "function" then return false end
    if type(getSteamModeActive) == "function" then
        local ok, on = pcall(getSteamModeActive)
        if not (ok and on) then return false end
    end
    if type(isSteamOverlayEnabled) == "function" then
        local ok, on = pcall(isSteamOverlayEnabled)
        if not (ok and on) then return false end
    end
    return true
end

function L.openWorkshop(ws)
    if not ws or not L.canWorkshop() then return false end
    return pcall(activateSteamOverlayToWorkshopItem, tostring(ws))
end

-- 剪貼簿：Clipboard 類別開給 Lua（LuaManager.java:1848；core/Clipboard.java:32,52；原版用例 ModListPresets.lua:155）。
-- 超過 PlanFile.SHARE_MAX 不寫：實際寫入在 render 執行緒，太長會整個遊戲當掉、pcall 擋不住（分享碼只有 ASCII，字數＝位元組）
function L.copy(text)
    if not (Clipboard and Clipboard.setClipboard) or #text > PlanFile.SHARE_MAX then return false end
    return pcall(Clipboard.setClipboard, text) == true
end

function L.paste()
    if not (Clipboard and Clipboard.getClipboard) then return nil end
    local ok, s = pcall(Clipboard.getClipboard)
    if ok and type(s) == "string" then return s end
    return nil
end

-- 從剪貼簿收的分享碼上限，同 L.copy 放得進剪貼簿的上限（超過的不是分享出來的，改請用檔案）。
-- 有非 ASCII 字時一字最多算 3 位元組
function L.fits(s)
    local n = #s
    if n > PlanFile.SHARE_MAX then return false end
    return n * 3 <= PlanFile.SHARE_MAX or not s:find("[^\1-\127]")
end

function L.modVersion(mod)
    if type(getModInfoByID) ~= "function" then return nil end
    local ok, info = pcall(getModInfoByID, mod)
    if not ok or not info or not info.getModVersion then return nil end
    local okV, v = pcall(info.getModVersion, info)
    if okV and v ~= nil and v ~= "" then return tostring(v) end
    return nil
end

-- 這個 MOD 現在有沒有啟用（Sources 同一個來源，LuaManager.java:7397-7399）；查不到回 nil
function L.modActive(mod)
    if type(getActivatedMods) ~= "function" then return nil end
    local ok, list = pcall(getActivatedMods)
    if not ok or not list then return nil end
    local okHas, has = pcall(list.contains, list, mod)
    if not okHas then return nil end
    return has == true
end

-- ---------------------------------------------------------------- 項目的狀態與說明

local stateCache = {}

-- 一種項目在這裡的狀態（PlanCheck.item）："ok"｜"missing"｜"off"｜"closed", 細節；沒有 PlanCheck 回 nil。快取到下次打開藍圖庫
function L.itemState(id)
    local PC = B.PlanCheck
    if not (PC and PC.item) then return nil end
    local c = stateCache[id]
    if not c then
        local s, d, a = PC.item(id)
        c = { s, d, a }
        stateCache[id] = c
    end
    return c[1], c[2], c[3]
end

function L.resetStates()
    stateCache = {}
end

-- 項目表（plan.items 或檔頭的 items：{ id, n, mod, modName, workshop, version }）照狀態合計：
-- { n, ok, missing, off, closed, unknown, mods＝{ { mod, modName, workshop, version, n, kinds }… }, list＝{ { it, item, state, detail }… }, updated }
function L.summary(items)
    local s = { n = 0, ok = 0, missing = 0, off = 0, closed = 0, unknown = 0, mods = {}, list = {}, updated = 0 }
    local byMod, seenMod = {}, {}
    for it, item in pairs(items or {}) do
        local st, detail, arg = L.itemState(item.id)
        local n = item.n or 0
        s.n = s.n + n
        local key = s[st or "unknown"] and (st or "unknown") or "closed"
        s[key] = s[key] + n
        -- 換掉後沒片的項目（Plan.replace 留著編號）不列、不算 MOD
        if key ~= "ok" and n > 0 then s.list[#s.list + 1] = { it = it, item = item, state = key, detail = detail, arg = arg } end
        if key == "missing" and item.mod and n > 0 then
            local g = byMod[item.mod]
            if not g then
                g = { mod = item.mod, modName = item.modName, workshop = item.workshop, version = item.version, n = 0, kinds = 0 }
                byMod[item.mod] = g
                s.mods[#s.mods + 1] = g
            end
            g.n, g.kinds = g.n + n, g.kinds + 1
        end
        if item.mod and not seenMod[item.mod] then
            seenMod[item.mod] = true
            local cur = L.modVersion(item.mod)
            if item.version and cur and cur ~= item.version then s.updated = s.updated + 1 end
        end
    end
    L.sort(s.list, function(a, b)
        if a.item.n ~= b.item.n then return (a.item.n or 0) > (b.item.n or 0) end
        return a.item.id < b.item.id
    end)
    L.sort(s.mods, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.mod < b.mod
    end)
    return s
end

-- 合計 → 說明行 { { 句子, 色名, ws＝要附「開工作坊頁」的編號 }… }。all＝true：四種狀態都列（匯入框），否則只列不能蓋的
function L.describe(s, all)
    local out = {}
    local function add(t, tok, ws) out[#out + 1] = { t, tok, ws = ws } end
    if all or s.ok < s.n then add(getText("IGUI_MBLD_Imp_Ok", tostring(s.ok)), s.ok == s.n and "success" or "text") end
    if all or s.missing > 0 then add(getText("IGUI_MBLD_Imp_Missing", tostring(s.missing)), s.missing > 0 and "warning" or "textMuted") end
    for i, g in ipairs(s.mods) do
        if i > L.LIST_MAX then
            add(getText("IGUI_MBLD_Imp_More", tostring(#s.mods - L.LIST_MAX)), "textMuted")
            break
        end
        local name = g.modName or g.mod
        local active = L.modActive(g.mod)
        if active then
            add(getText("IGUI_MBLD_Imp_ModLess", name, tostring(g.kinds), tostring(g.n)), "textMuted")
            local cur = L.modVersion(g.mod)
            if g.version and cur and cur ~= g.version then
                add(getText("IGUI_MBLD_Imp_ModVersion", g.version, cur), "textMuted")
            end
        else
            local line = g.workshop and getText("IGUI_MBLD_Imp_ModOffWs", name, tostring(g.n), g.workshop)
                or getText("IGUI_MBLD_Imp_ModOff", name, tostring(g.n))
            add(line, "textMuted", g.workshop)
        end
    end
    local noMod = 0
    for _, r in ipairs(s.list) do
        if r.state == "missing" and not r.item.mod then noMod = noMod + (r.item.n or 0) end
    end
    if noMod > 0 then add(getText("IGUI_MBLD_Imp_NoSource", tostring(noMod)), "textMuted") end
    if all or s.off > 0 then add(getText("IGUI_MBLD_Imp_Off", tostring(s.off)), s.off > 0 and "warning" or "textMuted") end
    if all or s.closed > 0 then
        add(getText("IGUI_MBLD_Imp_Closed", tostring(s.closed)), s.closed > 0 and "warning" or "textMuted")
        for _, r in ipairs(s.list) do -- 第一個有原因說明的那種（Entry.why 的碼，Window 的詳情同一套字串）
            local why = r.state == "closed" and r.detail and getTextOrNull("IGUI_MBLD_Why_" .. tostring(r.detail))
                and getText("IGUI_MBLD_Why_" .. tostring(r.detail), tostring(r.arg or ""))
            if why then
                add(why, "textMuted")
                break
            end
        end
    end
    if s.unknown > 0 then add(getText("IGUI_MBLD_Imp_Unknown", tostring(s.unknown)), "textMuted") end
    if s.updated > 0 then add(getText("IGUI_MBLD_Imp_Updated", tostring(s.updated)), "textMuted") end
    return out
end

-- 一種項目的顯示名：圖還在就用名稱表，不在就照 ID（這裡沒有那張圖，查不到名稱）
function L.itemName(id)
    local Names = B.Names
    if Names and Names.of then
        local ok, s = pcall(Names.of, id)
        if ok and s then return s end
    end
    return id
end

-- ---------------------------------------------------------------- 最近用過（plans-used.txt）

local used, usedOk = {}, false

local function readLines(file)
    local w = getFileWriter(file, true, true) -- 附加模式開一次：沒有就建空檔，有就不動
    if not w then return nil end
    w:close()
    local r = getFileReader(file, false)
    if not r then return nil end
    local lines, line = {}, r:readLine()
    while line do
        lines[#lines + 1] = line
        line = r:readLine()
    end
    r:close()
    return lines
end

local function now()
    return math.floor(os.time()) -- Kahlua 的 os.time＝currentTimeMillis／1000（OsLib.java:71）
end

-- 讀不到檔就不載入、也不准寫（免得蓋掉檔裡的紀錄）；少了 #end（寫到一半當掉）就收讀得出來的行，下次寫入時補齊
function L.loadUsed()
    local ok, lines = pcall(readLines, L.USED_FILE)
    usedOk = ok and lines ~= nil
    used = {}
    if not usedOk then
        print(LOG .. "plan usage times not loaded: the file could not be read")
        return false
    end
    if #lines > 0 and lines[#lines] ~= END then print(LOG .. "plan usage times incomplete: kept the readable lines") end
    for i = 1, #lines do
        local f, t = lines[i]:match("^([%w]+%.txt)\t(%d+)$")
        if f then used[f] = tonumber(t) end
    end
    return true
end

local function saveUsed()
    if not usedOk then return false end
    local rows, n = {}, 0
    for f, t in pairs(used) do
        if n >= MAX_USED then break end
        n = n + 1
        rows[n] = f .. "\t" .. t
    end
    rows[n + 1] = END
    local text = table.concat(rows, "\n") .. "\n"
    local ok = pcall(function()
        local w = getFileWriter(L.USED_FILE, true, false)
        if not w then error("no writer") end
        w:write(text)
        w:close()
    end)
    local okRead, lines = pcall(readLines, L.USED_FILE)
    local saved = ok and okRead and lines ~= nil and table.concat(lines, "\n") .. "\n" == text
    if not saved then print(LOG .. "plan usage times not saved: the file does not hold what was written") end
    return saved
end

function L.usedAt(file)
    return used[file]
end

-- 記一次「用過」（擺到地上、分享、存檔）；old＝改名前的檔名（時間搬過去）
function L.markUsed(file, old)
    if not usedOk then L.loadUsed() end
    if not file then return false end
    if old then used[old] = nil end
    used[file] = now()
    return saveUsed()
end

function L.usedText(t)
    if not t then return "-" end
    local days = math.floor((now() - t) / 86400)
    if days <= 0 then return getText("IGUI_MBLD_Lib_Today") end
    return getText("IGUI_MBLD_Lib_DaysAgo", tostring(days))
end

-- ---------------------------------------------------------------- 清單（列檔名、分幀補檔頭、搜尋與排序）

-- st＝{ files＝{ e… }, byFile, next＝下一個要補檔頭的位置, query, sort, rows, dirty }；e＝{ file, head, bad, miss }
function L.scan()
    local st = L.st or { query = "", sort = "used" }
    L.st = st
    local old = st.byFile or {}
    st.files, st.byFile, st.next, st.dirty = {}, {}, 1, true
    local files, skipped = PlanFile.list()
    st.skipped = skipped or 0
    for i, f in ipairs(files) do
        local e = old[f] or { file = f }
        st.files[i], st.byFile[f] = e, e
    end
    return st
end

-- 這個檔的內容變了：下次補檔頭時重讀
function L.touch(file)
    local st = L.st
    local e = st and st.byFile[file]
    if e then
        e.head, e.bad, e.miss = nil, nil, nil
        st.next, st.dirty = 1, true
    end
end

function L.missingOf(items)
    local n = 0
    for _, item in pairs(items or {}) do
        local s = L.itemState(item.id)
        if s == nil then return nil end
        if s ~= "ok" then n = n + (item.n or 0) end
    end
    return n
end

-- 補檔頭：最多 HEAD_MAX 個、超過 ms 毫秒就停（下一幀接著）。回這次讀了幾個
function L.pump(ms)
    local st = L.st
    if not st then return 0 end
    local t0, n, files = getTimestampMs(), 0, st.files
    while st.next <= #files and n < L.HEAD_MAX do
        local e = files[st.next]
        st.next = st.next + 1
        if e.head == nil and e.bad == nil then
            local h, why = PlanFile.head(e.file)
            if h then
                e.head, e.miss = h, L.missingOf(h.items)
            else
                e.bad = why or "READ"
            end
            n = n + 1
            st.dirty = true
            if getTimestampMs() - t0 >= ms then break end
        end
    end
    return n
end

function L.pending()
    local st, n = L.st, 0
    for _, e in ipairs(st and st.files or {}) do
        if e.head == nil and e.bad == nil then n = n + 1 end
    end
    return n
end

local function nameOf(e)
    return e.head and e.head.name or e.file
end

local LESS = {}
LESS.name = function(a, b)
    if a.low ~= b.low then return a.low < b.low end
    return a.file < b.file
end
LESS.used = function(a, b)
    local x, y = used[a.file] or 0, used[b.file] or 0
    if x ~= y then return x > y end
    return LESS.name(a, b)
end
LESS.pieces = function(a, b)
    local x, y = a.head and a.head.n or -1, b.head and b.head.n or -1
    if x ~= y then return x > y end
    return LESS.name(a, b)
end

-- 照搜尋字（名稱或檔名，不分大小寫）與排序（最近用過、名稱、片數）排出要顯示的列
function L.view()
    local st = L.st
    local q = string.lower(st.query or "")
    local out = {}
    for _, e in ipairs(st.files) do
        e.low = string.lower(nameOf(e))
        if q == "" or e.low:find(q, 1, true) or e.file:find(q, 1, true) then out[#out + 1] = e end
    end
    L.sort(out, LESS[st.sort] or LESS.used)
    st.rows, st.dirty = out, false
    return out
end

-- 一列的欄位文字：名稱、大小、片數、這裡不能蓋的片數、上次用
function L.cells(e)
    local h = e.head
    if e.bad then return { e.file, getText("IGUI_MBLD_Lib_Bad"), "", "", L.usedText(used[e.file]) } end
    if not h then return { e.file, "...", "...", "", L.usedText(used[e.file]) } end
    local size = h.levels and h.levels > 1 and getText("IGUI_MBLD_Lib_SizeLv", tostring(h.w), tostring(h.h), tostring(h.levels))
        or getText("IGUI_MBLD_Lib_Size", tostring(h.w), tostring(h.h))
    local miss = e.miss == nil and "" or (e.miss > 0 and tostring(e.miss) or "-")
    return { h.name ~= "" and h.name or e.file, size, tostring(h.n), miss, L.usedText(used[e.file]) }
end

-- 選到的那張的說明行
function L.details(e)
    if not e then return { { getText("IGUI_MBLD_Lib_PickOne"), "textMuted" } } end
    if e.bad then return { { L.errText(e.bad, 0), "warning" } } end
    local h = e.head
    if not h then return { { getText("IGUI_MBLD_Lib_Reading"), "textMuted" } } end
    local out = { { getText("IGUI_MBLD_Lib_Line", h.name ~= "" and h.name or e.file, tostring(h.n), e.file), "text" } }
    if h.pos then
        out[#out + 1] = { getText("IGUI_MBLD_Lib_Pos", tostring(h.pos[1]), tostring(h.pos[2]), tostring(h.pos[3])), "textMuted" }
    end
    for _, ln in ipairs(L.describe(L.summary(h.items), false)) do out[#out + 1] = ln end
    return out
end

-- ---------------------------------------------------------------- 動作

-- 讀整份；回 plan，或 nil, 句子
function L.loadFile(file)
    local plan, why = PlanFile.load(file)
    if not plan then return nil, L.errText(why, 0) end
    return plan
end

function L.parseCode(text)
    local plan, why, pos = PlanFile.unshare(text)
    if not plan then return nil, L.errText(why, pos) end
    return plan
end

-- 各項目在這裡的狀態（PlanStore 的 seen：只用英數與 _ 的狀態字）。不用快取：進遊戲時要的是現在的答案
function L.states(plan)
    local PC, out = B.PlanCheck, {}
    if not (PC and PC.item) then return out end
    for _, item in pairs(plan.items) do out[item.id] = PC.item(item.id) end
    return out
end

-- 擺上地的這張的狀態記成「上次」：匯入時就缺的片，下次進遊戲不再通知一次
function L.baseline(plan)
    local st = PlanStore.load()
    st.seen = L.states(plan)
    PlanStore.save(st)
end

local function closeAll()
    L.close()
    L.closeImport()
    L.closePicker()
    L.closeChooser()
end

-- 地上那張規劃中有沒存的改動：換張、收起、搬會替玩家決定存不存，先請玩家在工具列完成或取消。回 true＝擋下了
function L.blockUnsaved()
    local PM = B.PlanMode
    if not (PM and PM.unsaved and PM.unsaved()) then return false end
    local cur = PM.plan()
    L.tell(getText("IGUI_MBLD_PlanUnsaved", cur and cur.name or ""))
    return true
end

-- 地上那張換成別張？同一張（同一個物件或同一個檔）＝PlanMode.place 自己當「搬」
local function other(cur, plan)
    return cur ~= nil and cur ~= plan and not (plan.file ~= nil and cur.file == plan.file)
end

function L.doPlace(plan, pn)
    local PM = B.PlanMode
    -- 先收起地上那張（PlanMode.clear 會先存檔），PlanMode.place 就不會再問一次；存不了就停在這裡，地上那張照留
    if other(PM.plan and PM.plan(), plan) and PM.clear and not PM.clear() then return false end
    if PM.place(plan, pn) == false then return false end
    if plan.file then
        L.markUsed(plan.file, nil)
        L.touch(plan.file)
    end
    L.baseline(plan)
    closeAll()
    return true
end

-- 擺到地上（整張跟著游標，PlanMode.place）。地上已經有別張時先確認（地上同時只有一張）
function L.placePlan(plan, pn)
    local PM = B.PlanMode
    if not (PM and PM.place) then
        L.tell(getText("IGUI_MBLD_Lib_NoPlanMode"))
        return false
    end
    if L.blockUnsaved() then return false end
    local cur = PM.plan and PM.plan()
    if other(cur, plan) then
        return L.confirm(pn, { title = getText("IGUI_MBLD_Lib_ReplaceTitle", cur.name or ""),
            text = getText("IGUI_MBLD_Lib_ReplaceText", plan.name or ""), ok = getText("IGUI_MBLD_Lib_Replace"),
            onYes = function() L.doPlace(plan, pn) end }) ~= nil
    end
    return L.doPlace(plan, pn)
end

function L.placeFile(file, pn)
    local plan, err = L.loadFile(file)
    if not plan then
        L.tell(err)
        return false
    end
    return L.placePlan(plan, pn)
end

-- 分享碼放進剪貼簿；太長時提示改傳檔案（附「開資料夾」）；放不進剪貼簿時開一個框讓玩家自己複製。回 code, copied
function L.share(plan, withPos, pn)
    local code = PlanFile.share(plan, withPos)
    local copied = L.copy(code)
    if plan.file then L.markUsed(plan.file, nil) end
    if #code > L.SHARE_LONG then
        local canDir = L.canOpenFolder()
        L.confirm(pn, { title = getText("IGUI_MBLD_Lib_LongTitle", tostring(#code)),
            text = getText(copied and "IGUI_MBLD_Lib_LongCopied" or "IGUI_MBLD_Lib_LongNotCopied", plan.file or "-")
                .. (canDir and "" or ("\n" .. L.folderText())),
            ok = getText(canDir and "IGUI_MBLD_Lib_OpenFolder" or "UI_Ok"), cancel = getText("UI_Close"), single = not canDir,
            onYes = function() if canDir then L.openFolder() end end })
    elseif copied then
        L.tell(getText("IGUI_MBLD_Lib_Copied", tostring(#code)))
    else
        L.confirm(pn, { title = getText("IGUI_MBLD_Lib_ShareTitle"), text = getText("IGUI_MBLD_Lib_CopyByHand"),
            input = { text = code }, ok = getText("UI_Close"), single = true })
    end
    return code, copied
end

-- 存檔時有位置的藍圖先問要不要帶位置（帶了對方在同一張地圖、原位置附近才放得回原位置）
function L.shareFile(file, pn)
    local plan, err = L.loadFile(file)
    if not plan then
        L.tell(err)
        return nil
    end
    if plan.ox then
        L.confirm(pn, { title = getText("IGUI_MBLD_Lib_ShareTitle"), text = getText("IGUI_MBLD_Lib_SharePos"),
            ok = getText("IGUI_MBLD_Lib_WithPos"), cancel = getText("IGUI_MBLD_Lib_NoPos"),
            onYes = function() L.share(plan, true, pn) end, onNo = function() L.share(plan, false, pn) end })
        return nil
    end
    return L.share(plan, false, pn)
end

-- 地上那張是這個檔時跟著改：不然之後存檔會寫回舊檔名（刪掉的復活、或蓋掉重用這個檔名的新藍圖）
local function retarget(file, nf, name)
    local PM = B.PlanMode
    if PM and PM.retarget then PM.retarget(file, nf, name) end
end

-- 改名：回 新檔名，或 nil, 句子。檔名跟著改（PlanFile.rename：寫新檔、舊檔標成刪除）。
-- 地上那張是這個檔時，先在記錄寫下要改成的名稱（PM.renaming），寫檔與改記錄中間斷掉時讀回認得。
-- 改名失敗也不清：存檔可能已經寫好新名稱的備份、只有正式檔沒寫成，下次讀回的是新名稱。
-- 兩個名稱都認只到下一次存檔、讀回或改名（storePlan、PM.restore、PM.retarget 會清掉）
function L.rename(file, name)
    local PM = B.PlanMode
    if PM and PM.renaming and not PM.renaming(file, Plan.cleanName(name)) then return nil, L.errText("WRITE", 0) end
    local nf, why = PlanFile.rename(file, name)
    if not nf then return nil, L.errText(why, 0) end
    retarget(file, nf, Plan.cleanName(name))
    if used[file] then L.markUsed(nf, file) end
    if why == "OLD_LEFT" then L.tell(getText("IGUI_MBLD_Lib_OldLeft", file)) end
    L.touch(nf)
    return nf
end

function L.duplicate(file)
    local nf, why = PlanFile.duplicate(file)
    if not nf then return nil, L.errText(why, 0) end
    return nf
end

function L.remove(file)
    local ok, why = PlanFile.remove(file)
    if not ok then return nil, L.errText(why, 0) end
    retarget(file, nil, nil)
    if used[file] then
        used[file] = nil
        saveUsed()
    end
    return true
end

-- 新的空白藍圖：地上已經有一張時先問，收起（先存檔）成功才開新的；存不了就停，地上那張照留
function L.newBlank(pn)
    local PM = B.PlanMode
    if not (PM and PM.blank) then
        L.tell(getText("IGUI_MBLD_Lib_NoPlanMode"))
        return false
    end
    if L.blockUnsaved() then return false end
    local function go()
        if PM.plan() and not PM.clear() then return false end
        closeAll()
        if PM.blank(pn) == false then return false end
        local W = B.Window -- 規劃要用建造工坊挑項目
        if W and W.open then W.open(pn) end
        return true
    end
    local cur = PM.plan()
    if not cur then return go() end
    return L.confirm(pn, { title = getText("IGUI_MBLD_Lib_ReplaceTitle", cur.name or ""), text = getText("IGUI_MBLD_Lib_NewText"),
        ok = getText("IGUI_MBLD_Lib_New"), onYes = go }) ~= nil
end

-- 刪除先確認（危險樣式，寫出名稱與片數）；按確認才刪。onDone(ok, 句子)
function L.askRemove(file, name, n, pn, onDone)
    return L.confirm(pn, { title = getText("IGUI_MBLD_Lib_DeleteTitle", name or file),
        text = getText("IGUI_MBLD_Lib_DeleteText", n and tostring(n) or "?"), ok = getText("IGUI_MBLD_Lib_Delete"),
        danger = true,
        onYes = function()
            local ok, err = L.remove(file)
            if onDone then onDone(ok, err) end
        end })
end

-- 存進藍圖庫（匯入的、換過項目的）：從檔案讀的存回同一個檔，分享碼照名稱取新檔名。回 檔名, 是否另存成新的一張；或 nil, 句子。
-- 地上那張用同一個檔：規劃中＝另存成新的一張（不動地上那張的檔）；其他＝存好後地上那張換成這份（不然它之後存檔會寫回舊內容）
function L.store(plan)
    local PM = B.PlanMode
    local cur = PM and PM.plan and PM.plan()
    local asNew = plan.file ~= nil and cur ~= nil and cur ~= plan and cur.file == plan.file
        and PM.state ~= nil and PM.state() == "edit"
    if asNew then plan.file = nil end
    local file, why = plan.file, nil
    if not file then file, why = PlanFile.fileName(plan.name) end
    if not file then return nil, L.errText(why or "FILE", 0) end
    local ok
    ok, why = PlanFile.save(plan, file)
    if not ok then return nil, L.errText(why, 0) end
    if not asNew and PM and PM.adopt then PM.adopt(plan) end
    L.markUsed(file, nil)
    L.touch(file)
    return file, asNew
end

-- 「把缺的換成…」：這款（項目編號 it）的片全部改指到這裡有的 id。回 換了幾片，或 nil, 句子
function L.swap(plan, it, id)
    local st = L.itemState(id)
    if st ~= "ok" then return nil, getText("IGUI_MBLD_Imp_SwapBad") end
    return Plan.replace(plan, it, id, PlanFile.source(id))
end

-- ---------------------------------------------------------------- MOD 更新或下架的告知

-- 進遊戲時：地上的藍圖比上次多了不能蓋的項目才發一則通知（每種項目上次的狀態存在 PlanStore 的 seen，比完就更新）。
-- 上次沒記的項目當成能蓋（規劃時加的都在這裡有；從藍圖庫或匯入擺上的，擺的時候已經記了 L.baseline）。回 有沒有發
function L.notices()
    local PM, PC = B.PlanMode, B.PlanCheck
    local plan = PM and PM.plan and PM.plan()
    if not plan or not (PC and PC.item) then return false end
    local st = PlanStore.load()
    local seen = st.seen or {}
    local now, news = {}, {}
    for it, item in pairs(plan.items) do
        local s = PC.item(item.id)
        now[item.id] = s
        if s ~= "ok" and (seen[item.id] or "ok") == "ok" then news[it] = item end
    end
    st.seen = now
    PlanStore.save(st)
    local any = false
    for _ in pairs(news) do
        any = true
        break
    end
    if not any then return false end
    L.resetStates()
    local lines = { getText("IGUI_MBLD_Notice_Head", plan.name or "") }
    for _, ln in ipairs(L.describe(L.summary(news), false)) do lines[#lines + 1] = ln[1] end
    lines[#lines + 1] = getText("IGUI_MBLD_Notice_Next")
    Messages.toast(nil, table.concat(lines, " "), getText("IGUI_MBLD_Notice_Title"), 12)
    return true
end

-- 進遊戲後等 PlanMode 從 PlanStore 還原地上的藍圖（載入順序不保證），最多等 WAIT_TICKS 幀；等到或放棄都摘掉
L.WAIT_TICKS = 600
local waitTicks = 0
local function waitNotices()
    waitTicks = waitTicks + 1
    local PM = B.PlanMode
    local ready = PM ~= nil and PM.plan ~= nil and PM.plan() ~= nil
    if ready or waitTicks > L.WAIT_TICKS then
        Events.OnTick.Remove(waitNotices)
        if ready then B.PlanLibrary.notices() end
    end
end

function L.startNotices()
    waitTicks = 0
    Events.OnTick.Remove(waitNotices)
    Events.OnTick.Add(waitNotices)
end

-- ---------------------------------------------------------------- 藍圖庫視窗

local Lib = {}
Lib.__index = Lib

local function newPane(parent, x, y, w, h)
    local pane = ISPanel:new(x, y, w, h)
    pane:initialise()
    pane.background = false
    parent:addChild(pane)
    return pane
end

local function measure(font, s)
    return getTextManager():MeasureStringX(font, s)
end

-- 欄位：名稱（彈性、截字）、大小、片數、這裡不能蓋、上次用（靠右）。窄到名稱放不下時拿掉「上次用」
function Lib:columns(cw)
    local f = self.font
    local function wid(title, sample) return math.max(measure(f, title), measure(f, sample)) + 12 end
    local titles = { getText("IGUI_MBLD_Lib_ColName"), getText("IGUI_MBLD_Lib_ColSize"), getText("IGUI_MBLD_Lib_ColPieces"),
        getText("IGUI_MBLD_Lib_ColMissing"), getText("IGUI_MBLD_Lib_ColUsed") }
    local ws = { 0, wid(titles[2], getText("IGUI_MBLD_Lib_SizeLv", "64", "64", "4")), wid(titles[3], "4096"),
        wid(titles[4], "4096"), wid(titles[5], getText("IGUI_MBLD_Lib_DaysAgo", "30")) }
    local count = 5
    local function nameW(k)
        local r = cw - 4
        for i = k, 2, -1 do r = r - ws[i] end
        return r - 6
    end
    if nameW(5) < measure(f, "MMMMMMMMMM") then count = 4 end
    local cols, r = {}, cw - 4
    for i = count, 2, -1 do
        cols[i] = { x = r, right = true }
        r = r - ws[i]
    end
    cols[1] = { x = 6, width = r - 12 }
    self.titles, self.ncols = titles, count
    return cols
end

function Lib:headerRender(el)
    local c, f = self.colors, self.font
    local mu = c.textMuted
    local st = L.st
    local left = L.pending()
    local count = left > 0 and getText("IGUI_MBLD_Lib_CountReading", tostring(#st.files), tostring(left))
        or getText("IGUI_MBLD_Lib_Count", tostring(#st.files))
    if (st.skipped or 0) > 0 then count = count .. "  " .. getText("IGUI_MBLD_Lib_Skipped", tostring(st.skipped)) end
    el:drawText(count, 0, 0, mu.r, mu.g, mu.b, mu.a or 1, f)
    local y = self.fh
    for i = 1, self.ncols do
        local col = self.list.cols[i]
        if col.right then
            el:drawTextRight(self.titles[i], col.x, y, mu.r, mu.g, mu.b, mu.a or 1, f)
        else
            el:drawText(self.titles[i], col.x, y, mu.r, mu.g, mu.b, mu.a or 1, f)
        end
    end
end

function Lib.new(UI, pn)
    local theme = UI.Theme.create({ variant = "dark" })
    local font = UIFont.Small
    local fh = getTextManager():getFontHeight(font)
    local s = fh / 16
    local self = setmetatable({ UI = UI, theme = theme, colors = theme.colors, font = font, fh = fh, pn = pn, sortedAt = 0 }, Lib)
    L.v = self -- 建到一半出錯時 discard 收得到
    -- 用該玩家的畫面範圍（分割畫面，同 Admin.lua）；窄螢幕就照螢幕寬
    local sx, sy = getPlayerScreenLeft(pn), getPlayerScreenTop(pn)
    local sw, sh = getPlayerScreenWidth(pn), getPlayerScreenHeight(pn)
    local w, h = math.min(sw - 20, math.floor(600 * s)), math.min(sh - 40, math.floor(640 * s))
    local win = UI.Window.new({ x = sx + math.floor((sw - w) / 2), y = sy + math.floor((sh - h) / 2), width = w, height = h,
        title = getText("IGUI_MBLD_Lib_Title"), icon = "folder", theme = theme, opaque = true,
        onClose = function(wnd) UI.Dropdown.close(wnd) end })
    win.onEscape = function()
        win:close()
        return true
    end
    self.win = win
    local innerW = w - 2 * PAD
    local top = win:contentTop() + GAP
    -- 搜尋＋排序
    local opts = {}
    for i, id in ipairs(L.SORTS) do opts[i] = { id = id, label = getText("IGUI_MBLD_Lib_Sort_" .. id) } end
    self.sortDD = UI.Dropdown.new({ x = 0, y = top, options = opts, selected = L.st.sort, theme = theme, target = self,
        onChange = function(_, id)
            L.st.sort = id
            L.st.dirty = true
            self.sortedAt = 0
        end })
    self.sortDD:setX(w - PAD - self.sortDD.width)
    self.search = UI.TextField.new({ x = PAD, y = top, width = innerW - self.sortDD.width - GAP, text = L.st.query,
        placeholder = getText("IGUI_MBLD_Lib_Search"), clearButton = true, theme = theme,
        onChange = function(_, text)
            L.st.query = text or ""
            L.st.dirty = true
            self.sortedAt = 0
        end })
    win:addChild(self.search)
    win:addChild(self.sortDD)
    -- 按鈕（由下往上排）：整個藍圖庫的、選到那張的
    local function button(key, style, fn)
        local b = UI.Button.new({ x = 0, y = 0, title = getText(key), style = style, theme = theme, target = self, onClick = fn })
        win:addChild(b)
        return b
    end
    self.placeBtn = button("IGUI_MBLD_Lib_Place", "primary", function(t) t:act("place") end)
    self.shareBtn = button("IGUI_MBLD_Lib_Share", nil, function(t) t:act("share") end)
    self.renameBtn = button("IGUI_MBLD_Lib_Rename", nil, function(t) t:act("rename") end)
    self.copyBtn = button("IGUI_MBLD_Lib_Duplicate", nil, function(t) t:act("copy") end)
    self.delBtn = button("IGUI_MBLD_Lib_Delete", "danger", function(t) t:act("delete") end)
    local planBtns = { self.placeBtn, self.shareBtn, self.renameBtn, self.copyBtn, self.delBtn }
    local globals = { button("IGUI_MBLD_Lib_Import", nil, function(t) L.import(t.pn) end) }
    if L.canOpenFolder() then globals[#globals + 1] = button("IGUI_MBLD_Lib_OpenFolder", nil, function() L.openFolder() end) end
    if B.Capture and B.Capture.start then
        globals[#globals + 1] = button("IGUI_MBLD_Lib_Capture", nil, function(t)
            closeAll()
            B.Capture.start(t.pn)
        end)
    end
    if B.PlanMode and B.PlanMode.blank then
        globals[#globals + 1] = button("IGUI_MBLD_Lib_New", nil, function(t) L.newBlank(t.pn) end)
    end
    local gy = h - PAD - L.flowHeight(globals, innerW)
    L.flow(globals, PAD, gy, innerW)
    local bottom = gy - GAP
    if not L.canOpenFolder() then -- 不支援開資料夾的平台：寫出路徑
        local p = L.textPanel(win, PAD, 0, innerW, theme, font)
        local ph = L.setLines(p, { { L.folderText(), "textMuted" } })
        p:setY(bottom - ph)
        bottom = bottom - ph - GAP
    end
    local py = bottom - L.flowHeight(planBtns, innerW)
    L.flow(planBtns, PAD, py, innerW)
    -- 選到那張的說明（可捲動）
    local detailH = fh * 5
    local box = UI.ScrollPanel.new({ x = PAD, y = py - GAP - detailH, width = innerW, height = detailH, theme = theme })
    win:addChild(box)
    self.detail = L.textPanel(box, 0, 0, box:contentWidth(), theme, font)
    box._focusLabel = getText("IGUI_MBLD_Lib_Title") -- 說明區沒有控制項：手把把整塊當捲動目標
    -- 欄位標題＋清單
    local hy = top + math.max(self.search.height, self.sortDD.height) + GAP
    local header = newPane(win, PAD, hy, innerW, fh * 2)
    header.render = function(el) self:headerRender(el) end
    header.prerender = function() self:pump() end -- 只在視窗開著時補檔頭
    local ly = hy + fh * 2 + 2
    self.list = UI.Table.new({ x = PAD, y = ly, width = innerW, height = math.max(fh * 3, box.y - GAP - ly),
        rowHeight = fh + 8, theme = theme,
        onSelect = function(_, item) self:select(item) end, onHighlight = function(_, item) self:select(item) end })
    self.list.cols = self:columns(innerW - 12)
    win:addChild(self.list)
    win:addToUIManager()
    return self
end

function Lib:pump()
    local st = L.st
    if not st then return end
    L.pump(L.HEAD_MS)
    local t = getTimestampMs()
    -- 補檔頭的期間每 0.5 秒重排一次（片數、名稱排序要等檔頭），補完、打字、換排序時馬上排
    if st.dirty and (st.next > #st.files or t - self.sortedAt >= 500) then
        self.sortedAt = t
        self:refreshRows()
    end
end

function Lib:refreshRows()
    local rows = L.view()
    local items, pick = {}, nil
    local sel = self.selected and self.selected.file
    for i, e in ipairs(rows) do
        local cells = L.cells(e)
        if self.ncols < 5 then cells[5] = nil end
        items[i] = { cells = cells, tokens = { "text", "textMuted", "text", e.miss and e.miss > 0 and "warning" or "textMuted",
            "textMuted" }, muted = e.bad ~= nil, e = e }
        if e.file == sel then pick = i end
    end
    self.list:setItems(items)
    self.list:setSelectedIndex(pick)
    if not pick then self.selected = nil end
    self:refreshDetail()
end

function Lib:select(item)
    self.selected = item and item.e or nil
    self:refreshDetail()
end

function Lib:refreshDetail()
    local e = self.selected
    L.setLines(self.detail, L.details(e))
    local ready = e ~= nil and e.head ~= nil
    for _, b in ipairs({ self.placeBtn, self.shareBtn, self.renameBtn, self.copyBtn }) do b:setEnabled(ready) end
    self.delBtn:setEnabled(e ~= nil)
end

-- 改名、複製、刪除之後：重列檔名（檔頭沿用快取），選到 file
function Lib:reload(file)
    L.scan()
    self.selected = file and L.st.byFile[file] or nil
    self:refreshRows()
end

function Lib:act(what)
    local e, pn = self.selected, self.pn
    if not e then return end
    local h = e.head
    if what == "place" then
        L.placeFile(e.file, pn)
    elseif what == "share" then
        L.shareFile(e.file, pn)
    elseif what == "copy" then
        local nf, err = L.duplicate(e.file)
        if nf then self:reload(nf) else L.tell(err) end
    elseif what == "rename" then
        L.confirm(pn, { title = getText("IGUI_MBLD_Lib_RenameTitle"), text = getText("IGUI_MBLD_Lib_RenameText", tostring(Plan.MAX_NAME)),
            input = { text = h and h.name or "" }, ok = getText("IGUI_MBLD_Lib_Rename"),
            onYes = function(text)
                local nf, err = L.rename(e.file, text or "")
                if nf then self:reload(nf) else L.tell(err) end
            end })
    elseif what == "delete" then
        L.askRemove(e.file, h and h.name ~= "" and h.name or e.file, h and h.n, pn, function(ok, err)
            if ok then self:reload(nil) else L.tell(err) end
        end)
    end
end

local function discard(k)
    local v = L[k]
    L[k] = nil
    if v and v.win then
        pcall(function()
            v.win:setVisible(false)
            v.win:removeFromUIManager()
        end)
    end
end

-- 每次打開都重列檔名、檔頭重新分幀補（別的存檔、手動搬檔都看得到），項目狀態重問
function L.open(...)
    local pn = select("#", ...) > 0 and (...) or 0
    local UI = L.ui()
    if not UI then
        L.tell(getText("IGUI_MBLD_NeedFramework"))
        return false
    end
    L.resetStates()
    if L.st then L.st.byFile = nil end
    L.loadUsed()
    L.scan()
    local v = L.v
    if v and (v.UI ~= UI or v.pn ~= pn) then
        discard("v")
        v = nil
    end
    if not v then
        local ok, err = pcall(Lib.new, UI, pn)
        if not ok then
            print(LOG .. "plan library build failed: " .. tostring(err))
            discard("v")
            L.tell(getText("IGUI_MBLD_Lib_BuildFailed"))
            return false
        end
        v = L.v
    end
    v.selected = nil
    v.sortedAt = 0
    v:refreshRows()
    v.win:setVisible(true)
    v.win:bringToTop()
    return true
end

function L.close()
    local v = L.v
    if v and v.win:getIsVisible() then v.win:close() end
end

function L.visible()
    return L.v ~= nil and L.v.win:getIsVisible()
end

-- ---------------------------------------------------------------- 匯入框

local Imp = {}
Imp.__index = Imp
Imp.TYPE_MAX = 200 -- 文字欄裡最多留幾個字：更長的一進框就清掉、改走貼上鈕那條路（見 Imp:typed）
Imp.SHOW = 60 -- 收下的碼比 TYPE_MAX 長時，框裡只放開頭這幾個字加「...」

function Imp.new(UI, pn)
    local theme = UI.Theme.create({ variant = "dark" })
    local font = UIFont.Small
    local fh = getTextManager():getFontHeight(font)
    local s = fh / 16
    local self = setmetatable({ UI = UI, theme = theme, font = font, fh = fh, pn = pn }, Imp)
    L.imp = self
    local sx, sy = getPlayerScreenLeft(pn), getPlayerScreenTop(pn)
    local sw, sh = getPlayerScreenWidth(pn), getPlayerScreenHeight(pn)
    local w, h = math.min(sw - 20, math.floor(520 * s)), math.min(sh - 40, math.floor(560 * s))
    local win = UI.Window.new({ x = sx + math.floor((sw - w) / 2) + 20, y = sy + math.floor((sh - h) / 2) + 20, width = w,
        height = h, title = getText("IGUI_MBLD_Imp_Title"), icon = "folder", theme = theme, opaque = true,
        onClose = function(wnd) UI.Dropdown.close(wnd) end })
    win.onEscape = function()
        win:close()
        return true
    end
    self.win = win
    local innerW = w - 2 * PAD
    local y = win:contentTop() + GAP
    local function button(key, style, fn)
        local b = UI.Button.new({ x = 0, y = 0, title = getText(key), style = style, theme = theme, target = self, onClick = fn })
        win:addChild(b)
        return b
    end
    -- 第一列：分享碼文字欄（框架有同步回呼才放）＋從剪貼簿貼上；狀態行（讀到了什麼）在文字欄下面，沒有文字欄時在貼上鈕右邊。
    -- 原生文字框的 Ctrl+C／X 直接把框裡的字送進剪貼簿，太長會讓遊戲當掉（實機 97,746 bytes 當），而貼上不看長度上限、
    -- 上限要等 update 才截、同一輪按鍵可以接著全選加複製（UITextBox2.java:398-401,1235-1257、Core.java:1657-1661）。
    -- 所以文字欄只在框架給得出同步的 onTextChange（貼上的當下、複製之前）時才放：超過 TYPE_MAX 當場清空（Imp:typed）
    local pasteBtn = (Clipboard and Clipboard.getClipboard) and button("IGUI_MBLD_Imp_Paste", nil, function(t) t:paste() end)
    local th
    if UI.CAPABILITIES.textFieldSync == true then
        local bw = pasteBtn and pasteBtn.width + GAP or 0
        -- onTextChange（同步）只涵蓋打字、刪除、貼上、清除；剪下、輸入法送出、截字不叫它，由每幀的 onChange 補
        -- （框架 rev 28 交接檔「結果」）。兩個走同一條 typed，同一段字只處理一次（Imp.seen）
        self.seen = ""
        local function typed(f, text) self:typed(f, text) end
        self.field = UI.TextField.new({ x = PAD, y = y, width = innerW - bw, text = "", maxLength = Imp.TYPE_MAX,
            placeholder = getText("IGUI_MBLD_Imp_CodeField"), theme = theme, onTextChange = typed, onChange = typed })
        win:addChild(self.field)
        local rowH = self.field.height
        if pasteBtn then
            pasteBtn:setX(PAD + innerW - pasteBtn.width)
            pasteBtn:setY(y)
            rowH = math.max(rowH, pasteBtn.height)
        end
        y = y + rowH + GAP
        self.status = L.textPanel(win, PAD, y, innerW, theme, font)
    elseif pasteBtn then
        pasteBtn:setX(PAD)
        pasteBtn:setY(y)
        local tx = PAD + pasteBtn.width + GAP
        self.status = L.textPanel(win, tx, y, PAD + innerW - tx, theme, font)
        th = pasteBtn.height
    end
    if self.status then
        -- 這一列的高度照兩種狀態裡較高的那個（翻譯長了就換行，不蓋到下面）
        th = math.max(th or 0, L.setLines(self.status, { { getText("IGUI_MBLD_Imp_CodeRead", "60000"), "text" } }),
            L.setLines(self.status, { { getText("IGUI_MBLD_Imp_CodeHint"), "textMuted" } }))
        y = y + th + GAP
    end
    -- 第二列：資料夾裡的檔＋檢查
    local checkBtn = button("IGUI_MBLD_Imp_Check", "primary", function(t) t:check() end)
    local opts = {}
    local files, skipped = PlanFile.list()
    self.skipped = skipped or 0
    for i, f in ipairs(files) do
        local e = L.st and L.st.byFile and L.st.byFile[f]
        opts[i] = { id = f, label = e and e.head and e.head.name ~= "" and (e.head.name .. " (" .. f .. ")") or f }
    end
    self.fileDD = UI.Dropdown.new({ x = PAD, y = y, width = innerW - checkBtn.width - GAP, options = opts,
        placeholder = getText(#opts > 0 and "IGUI_MBLD_Imp_FileHint" or "IGUI_MBLD_Imp_NoFiles"), theme = theme, target = self,
        onChange = function(t)
            t:clearField()
            t:setCode(nil)
            t:check()
        end })
    win:addChild(self.fileDD)
    checkBtn:setX(PAD + self.fileDD.width + GAP)
    checkBtn:setY(y)
    y = y + math.max(self.fileDD.height, checkBtn.height) + GAP
    -- 最下面：存進藍圖庫、擺到地上、取消
    self.storeBtn = button("IGUI_MBLD_Imp_Store", "primary", function(t) t:finish("store") end)
    self.placeBtn = button("IGUI_MBLD_Lib_Place", nil, function(t) t:finish("place") end)
    local cancel = button("UI_Cancel", nil, function() L.closeImport() end)
    local foot = { self.storeBtn, self.placeBtn, cancel }
    local fy = h - PAD - L.flowHeight(foot, innerW)
    L.flow(foot, PAD, fy, innerW)
    self.box = UI.ScrollPanel.new({ x = PAD, y = y, width = innerW, height = math.max(fh * 3, fy - GAP - y), theme = theme })
    win:addChild(self.box)
    win:addToUIManager()
    self:setCode(nil)
    self:render()
    return self
end

-- 已讀到的分享碼（nil＝沒有）與狀態那一行
function Imp:setCode(s)
    self.code = s
    if not self.status then return end
    L.setLines(self.status, { s and { getText("IGUI_MBLD_Imp_CodeRead", tostring(#s)), "text" }
        or { getText("IGUI_MBLD_Imp_CodeHint"), "textMuted" } })
end

-- 太長的不收（L.fits），改請玩家用藍圖檔匯入
function Imp:tooLong()
    self:setCode(nil)
    self.plan, self.err, self.pasted = nil, getText("IGUI_MBLD_Imp_TooLong"), false
    self:render()
end

-- 收到一段分享碼（貼上鈕、文字欄裡太長的）：太長的不收，其餘檢查並寫出結果。
-- 框裡放收下的碼讓玩家看得到：短的整串、長的只放開頭加「...」——框裡任何時候都不超過 TYPE_MAX 字，
-- 因為原生文字框的 Ctrl+C 會把框裡的字整段送進剪貼簿，超過約 64 KiB 遊戲會當掉（見 Imp.new）。
-- 記成已處理過（seen），兩個回呼不會把它當成玩家打的字；玩家之後改框裡的字照「打到一半」丟掉這個碼
function Imp:take(s)
    if not L.fits(s) then return self:tooLong() end
    self:setCode(s)
    if self.field then
        local shown = #s <= Imp.TYPE_MAX and s or (Plan.cut(s, Imp.SHOW) .. "...")
        self.field:setText(shown)
        self.seen = shown
    end
    self:check(true)
end

-- 清空文字欄（setText 不觸發兩個回呼）：記成已處理過空字串，下一幀的 onChange 不會把剛收下的碼當成玩家清了框
function Imp:clearField()
    if not self.field then return end
    self.field:setText("")
    self.seen = ""
end

-- 讀到的是遊戲視窗上次取得焦點時的剪貼簿（Display.java:227-236、Clipboard.java:32-49）：讀不到或不是分享碼時多寫一行怎麼辦。
-- 再按一次＝換成新的
function Imp:paste()
    local s = L.paste()
    self:clearField()
    if not s or s == "" then
        self:setCode(nil)
        self.plan, self.err, self.pasted = nil, getText("IGUI_MBLD_Imp_ClipEmpty"), true
        return self:render()
    end
    self:take(s)
end

-- 文字欄的回呼（同步的 onTextChange 與每幀的 onChange 都走這裡；同一段字只處理一次）。
-- 超過 TYPE_MAX：先清框（框裡永遠不留長字串，就沒有東西能被複製）再照貼上鈕收；同步回呼拿到的字可能比 maxLength 長
-- （截字要等 update），照長度判斷正好接住。
-- 其餘的字就是框裡現在的字：是完整的分享碼就直接採用；不是（打到一半、剪掉了）就丟掉上次讀到的碼與結果、不寫錯誤，
-- 按「檢查」才檢查框裡的字。分享碼的錯誤由 L.parseCode 回原因、不丟錯
function Imp:typed(_, text)
    text = text or ""
    if text == self.seen then return end
    self.seen = text
    if #text > Imp.TYPE_MAX then
        self:clearField()
        return self:take(text)
    end
    if text ~= "" and L.parseCode(text) then
        self:setCode(text)
        return self:check(true)
    end
    if self.code or self.plan or self.err then
        self:setCode(nil)
        self.plan, self.err = nil, nil
        self:render()
    end
end

-- 文字欄的字和上次處理過的不同（剪下之後還沒到下一幀）：先照框裡現在的字重來
local function sync(self)
    if self.field then self:typed(self.field, self.field:getText()) end
end

-- 分享碼優先（已讀到的、再來是文字欄裡打到一半的）；都沒有才讀選的檔
function Imp:check(pasted)
    sync(self)
    self.pasted = pasted == true
    local file = self.fileDD:getSelected()
    local typed = self.field and self.field:getText() or ""
    if self.code then
        self.plan, self.err = L.parseCode(self.code)
    elseif typed ~= "" then
        self.plan, self.err = L.parseCode(typed)
    elseif file then
        self.plan, self.err = L.loadFile(file)
    else
        self.plan, self.err = nil, getText("IGUI_MBLD_Imp_Empty")
    end
    self.rev = self.plan and self.plan.rev -- 之後換過項目（rev 變了）存進藍圖庫時先問覆蓋或另存
    L.resetStates()
    self:render()
end

-- 結果區：重建（只在檢查、換項目之後，不每幀）
function Imp:render()
    local UI, theme, box = self.UI, self.theme, self.box
    box:clearChildren()
    box:setYScroll(0)
    local cw = box:contentWidth()
    local y = 0
    local function text(lines)
        local p = L.textPanel(box, 0, y, cw, theme, self.font)
        y = y + L.setLines(p, lines) + 2
    end
    local function button(title, fn)
        local b = UI.Button.new({ x = 0, y = y, title = title, theme = theme, target = self, onClick = fn })
        box:addChild(b)
        y = y + b.height + GAP
        return b
    end
    local plan = self.plan
    self.storeBtn:setEnabled(plan ~= nil)
    self.placeBtn:setEnabled(plan ~= nil)
    if (self.skipped or 0) > 0 then text({ { getText("IGUI_MBLD_Lib_Skipped", tostring(self.skipped)), "textMuted" } }) end
    if not plan then
        text({ { self.err or getText("IGUI_MBLD_Imp_Intro"), self.err and "warning" or "textMuted" } })
        if self.err and self.pasted then text({ { getText("IGUI_MBLD_Imp_ClipHint"), "textMuted" } }) end
        return
    end
    text({ { getText("IGUI_MBLD_Imp_Head", plan.name ~= "" and plan.name or "-", tostring(plan.n)), "text" } })
    local s = L.summary(plan.items)
    local ws = L.canWorkshop()
    for _, ln in ipairs(L.describe(s, true)) do
        text({ ln })
        if ln.ws and ws then
            local id = ln.ws
            button(getText("IGUI_MBLD_Imp_Workshop"), function() L.openWorkshop(id) end)
        end
    end
    if #s.list > 0 then
        y = y + GAP
        text({ { getText("IGUI_MBLD_Imp_SwapIntro"), "textMuted" } })
        for i, r in ipairs(s.list) do
            if i > L.LIST_MAX then
                text({ { getText("IGUI_MBLD_Imp_More", tostring(#s.list - L.LIST_MAX)), "textMuted" } })
                break
            end
            text({ { getText("IGUI_MBLD_Imp_SwapRow", L.itemName(r.item.id), tostring(r.item.n or 0)), "text" } })
            local it = r.it
            button(getText("IGUI_MBLD_Imp_Swap"), function(t)
                L.pickSwap(t.pn, plan, it, function() t:render() end)
            end)
        end
    end
end

function Imp:store(plan)
    local file, asNew = L.store(plan)
    if not file then return L.tell(asNew) end
    L.tell(getText(asNew and "IGUI_MBLD_Imp_StoredNew" or "IGUI_MBLD_Imp_Stored", plan.name, file))
    L.closeImport()
    if L.visible() and L.v then L.v:reload(file) end
end

-- 藍圖庫裡顯示名稱完全相同的：剛好一張才回它的檔名（藍圖庫讀好的檔頭先用）
function L.sameName(name)
    local found
    for _, f in ipairs(PlanFile.list()) do
        local e = L.st and L.st.byFile and L.st.byFile[f]
        local head = e and e.head or PlanFile.head(f)
        if head and head.name == name then
            if found then return nil end
            found = f
        end
    end
    return found
end

-- 「存進藍圖庫」：從檔案讀的、換過項目＝問覆蓋原本的或另存；分享碼、藍圖庫裡剛好一張同名＝問蓋掉它或另存。
-- 其他照舊（從檔案讀的存回同一個檔，分享碼存成新的一張）
function Imp:finish(how)
    sync(self)
    local plan = self.plan
    if not plan then return end
    if how ~= "store" then return L.placePlan(plan, self.pn) end
    local function asNew(name)
        plan.file = nil
        local n = Plan.cleanName(name)
        if n ~= "" then plan.name = n end
        self:store(plan)
    end
    if plan.file then
        if plan.rev ~= self.rev then
            return L.askOverwrite(self.pn, { name = plan.name, onOverwrite = function() self:store(plan) end, onNew = asNew })
        end
    else
        local same = L.sameName(plan.name)
        if same then
            return L.askOverwrite(self.pn, { name = plan.name, text = getText("IGUI_MBLD_Imp_SameName", plan.name),
                onOverwrite = function()
                    plan.file = same
                    self:store(plan)
                end, onNew = asNew })
        end
    end
    self:store(plan)
end

function L.import(...)
    local pn = select("#", ...) > 0 and (...) or 0
    local UI = L.ui()
    if not UI then
        L.tell(getText("IGUI_MBLD_NeedFramework"))
        return false
    end
    discard("imp")
    local ok, err = pcall(Imp.new, UI, pn)
    if not ok then
        print(LOG .. "plan import build failed: " .. tostring(err))
        discard("imp")
        L.tell(getText("IGUI_MBLD_Lib_BuildFailed"))
        return false
    end
    L.imp.win:setVisible(true)
    L.imp.win:bringToTop()
    return true
end

function L.closeImport()
    discard("imp")
    L.closePicker()
end

-- ---------------------------------------------------------------- 「把缺的換成…」挑一個這裡有的同種類項目

-- 缺的圖查不到種類（圖不在），照圖塊名的開頭猜一個當預設，玩家可以換。shortcut: 只認原版常見的前綴，猜不到就是家具
local GUESS = { { "^walls_", "wall" }, { "^floors_", "floor" }, { "^roofs_", "roof" }, { "^fixtures_doors_", "door" },
    { "^fixtures_windows_", "window" }, { "^fencing_", "fence" }, { "^fixtures_stairs_", "stairs" },
    { "^lighting_", "light" }, { "^ramps_", "ramp" } }

function L.guessKind(id)
    for _, g in ipairs(GUESS) do
        if id:match(g[1]) then return g[2] end
    end
    return "furniture"
end

local Pick = {}
Pick.__index = Pick

function Pick.new(UI, pn, plan, it, onDone)
    local theme = UI.Theme.create({ variant = "dark" })
    local font = UIFont.Small
    local fh = getTextManager():getFontHeight(font)
    local s = fh / 16
    local item = plan.items[it]
    local self = setmetatable({ UI = UI, theme = theme, font = font, fh = fh, pn = pn, plan = plan, it = it,
        onDone = onDone, disp = {} }, Pick)
    L.pick = self
    local sx, sy = getPlayerScreenLeft(pn), getPlayerScreenTop(pn)
    local sw, sh = getPlayerScreenWidth(pn), getPlayerScreenHeight(pn)
    local w, h = math.min(sw - 20, math.floor(460 * s)), math.min(sh - 40, math.floor(520 * s))
    local win = UI.Window.new({ x = sx + math.floor((sw - w) / 2) + 40, y = sy + math.floor((sh - h) / 2) + 40, width = w,
        height = h, title = getText("IGUI_MBLD_Swap_Title", L.itemName(item.id)), theme = theme, opaque = true,
        onClose = function(wnd) UI.Dropdown.close(wnd) end })
    win.onEscape = function()
        win:close()
        return true
    end
    self.win = win
    local innerW = w - 2 * PAD
    local y = win:contentTop() + GAP
    local Entry, Names = B.Entry, B.Names
    local opts = {}
    for _, k in ipairs(Entry.KINDS) do
        if Entry.BUILDABLE[k] then opts[#opts + 1] = { id = k, label = Names and Names.kind(k) or k } end
    end
    self.kind = L.guessKind(item.id)
    self.kindDD = UI.Dropdown.new({ x = PAD, y = y, options = opts, selected = self.kind, theme = theme, target = self,
        onChange = function(t, id)
            t.kind = id
            t:fill()
        end })
    win:addChild(self.kindDD)
    self.query = ""
    self.search = UI.TextField.new({ x = PAD + self.kindDD.width + GAP, y = y, width = innerW - self.kindDD.width - GAP,
        placeholder = getText("IGUI_MBLD_Lib_Search"), clearButton = true, theme = theme,
        onChange = function(_, text)
            self.query = string.lower(text or "")
            self:fill()
        end })
    win:addChild(self.search)
    y = y + math.max(self.kindDD.height, self.search.height) + GAP
    self.okBtn = UI.Button.new({ x = 0, y = 0, title = getText("IGUI_MBLD_Swap_Ok"), style = "primary", theme = theme,
        target = self, onClick = function(t) t:confirm() end })
    local cancel = UI.Button.new({ x = 0, y = 0, title = getText("UI_Cancel"), theme = theme, onClick = function() L.closePicker() end })
    win:addChild(self.okBtn)
    win:addChild(cancel)
    local foot = { self.okBtn, cancel }
    local fy = h - PAD - L.flowHeight(foot, innerW)
    L.flow(foot, PAD, fy, innerW)
    self.status = L.textPanel(win, PAD, 0, innerW, theme, font)
    self.status:setY(fy - GAP - fh * 2)
    self.status.prerender = function() self:poll() end
    self.list = UI.Table.new({ x = PAD, y = y, width = innerW, height = math.max(fh * 3, fy - GAP * 2 - fh * 2 - y),
        rowHeight = fh + 8, theme = theme,
        onSelect = function(_, row) self:choose(row) end, onHighlight = function(_, row) self:choose(row) end })
    self.list.cols = { { x = 6, width = innerW - 24 } }
    win:addChild(self.list)
    win:addToUIManager()
    self:fill()
    return self
end

-- 目錄還在整理時等它（Catalog 進遊戲就開始整理，Catalog.start）
function Pick:poll()
    if self.waiting and B.Catalog and B.Catalog.state == "ready" then self:fill() end
end

function Pick:fill()
    local Catalog, Index = B.Catalog, B.Index
    self.chosen = nil
    self.okBtn:setEnabled(false)
    if not (Catalog and Index) or Catalog.state ~= "ready" then
        self.waiting = true
        if Catalog and Catalog.state == "idle" then Catalog.start() end
        self.list:setItems({})
        L.setLines(self.status, { { getText("IGUI_MBLD_Swap_Wait"), "textMuted" } })
        return
    end
    self.waiting = false
    local names, rows, q = Index.names(self.kind), {}, self.query
    for i = 1, names.n do
        local id = names[i]
        local d = self.disp[id]
        if not d then
            d = L.itemName(id)
            self.disp[id] = d
        end
        if q == "" or id:lower():find(q, 1, true) or d:lower():find(q, 1, true) then
            rows[#rows + 1] = { cells = { d }, id = id }
        end
    end
    self.list:setItems(rows)
    L.setLines(self.status, { { getText("IGUI_MBLD_Swap_Count", tostring(#rows)), "textMuted" } })
end

function Pick:choose(row)
    self.chosen = row and row.id or nil
    self.okBtn:setEnabled(self.chosen ~= nil)
end

function Pick:confirm()
    if not self.chosen then return end
    local n, err = L.swap(self.plan, self.it, self.chosen)
    if not n then
        L.setLines(self.status, { { err, "warning" } })
        return
    end
    L.resetStates()
    local done = self.onDone
    L.closePicker()
    if done then done(n) end
end

function L.pickSwap(pn, plan, it, onDone)
    local UI = L.ui()
    if not UI then return false end
    discard("pick")
    local ok, err = pcall(Pick.new, UI, pn, plan, it, onDone)
    if not ok then
        print(LOG .. "plan swap picker build failed: " .. tostring(err))
        discard("pick")
        return false
    end
    L.pick.win:setVisible(true)
    L.pick.win:bringToTop()
    return true
end

function L.closePicker()
    discard("pick")
end

-- ---------------------------------------------------------------- 三選一的小框（框架 Dialog 只有兩顆鈕）

-- o＝{ title, text, buttons＝{ { text, style?, onClick? }… } }。按鈕先關框再做事；Esc、X＝不做事關掉。
-- 滑鼠時開在游標旁（同 L.confirm），手把時置中、焦點在第一顆。同時只開一個。回 true；沒有框架回 nil（不做事）
function L.choose(pn, o)
    local UI = L.ui()
    if not UI then return nil end
    discard("chooser")
    local ok, err = pcall(function()
        local theme = UI.Theme.create({ variant = "dark" })
        local font = UIFont.Small
        local w = math.floor(360 * getTextManager():getFontHeight(font) / 16)
        local v = {}
        local win = UI.Window.new({ x = 0, y = 0, width = w, height = 100, title = o.title, theme = theme, opaque = true,
            onClose = function() if L.chooser == v then L.chooser = nil end end })
        win.onEscape = function()
            win:close()
            return true
        end
        v.win = win
        L.chooser = v
        local y = win:contentTop() + GAP
        y = y + L.setLines(L.textPanel(win, PAD, y, w - 2 * PAD, theme, font), { { o.text or "" } }) + GAP * 2
        local btns = {}
        for i, b in ipairs(o.buttons) do
            local fn = b.onClick
            btns[i] = UI.Button.new({ x = 0, y = 0, title = b.text, style = b.style, theme = theme,
                onClick = function()
                    if L.chooser == v then discard("chooser") end
                    if fn then fn() end
                end })
            win:addChild(btns[i])
        end
        local h = L.flow(btns, PAD, y, w - 2 * PAD) + PAD
        win:setHeight(h)
        local sx, sy = getPlayerScreenLeft(pn), getPlayerScreenTop(pn)
        local sw, sh = getPlayerScreenWidth(pn), getPlayerScreenHeight(pn)
        local x, top = sx + math.floor((sw - w) / 2), sy + math.floor((sh - h) / 2)
        if not L.usingPad(pn) and getMouseX then
            -- 中心對準游標、夾在畫面內；游標會落在按鈕列時改放到游標上方（同框架 Dialog 的 anchor）
            local mx, my = math.floor(getMouseX()), math.floor(getMouseY())
            x = math.max(sx, math.min(mx - math.floor(w / 2), sx + sw - w))
            top = math.max(sy, math.min(my - math.floor(h / 2), sy + sh - h))
            if my >= top + y then top = math.max(sy, my - h - 10) end
        end
        win:setX(x)
        win:setY(top)
        win:addToUIManager()
        win:setVisible(true)
        win:bringToTop()
        local F = UI.Focus
        if F and F.holdsJoypad and F.focusControl and btns[1] and F.holdsJoypad(win) then F.focusControl(btns[1], true) end
    end)
    if not ok then
        print(LOG .. "plan chooser build failed: " .. tostring(err))
        discard("chooser")
        return nil
    end
    return true
end

function L.closeChooser()
    discard("chooser")
end

-- 存檔前三選一：覆蓋原本的／另存新檔／取消。o＝{ name, text?, onOverwrite(), onNew(新名稱) }；
-- 另存新檔再問名稱（預設現在的名稱）。回 true；沒有框架回 nil
function L.askOverwrite(pn, o)
    local name = o.name or ""
    return L.choose(pn, { title = getText("IGUI_MBLD_SaveTitle", name), text = o.text or getText("IGUI_MBLD_SaveText", name),
        buttons = {
            { text = getText("IGUI_MBLD_SaveOverwrite"), style = "primary", onClick = o.onOverwrite },
            { text = getText("IGUI_MBLD_SaveAsNew"), onClick = function()
                L.confirm(pn, { title = getText("IGUI_MBLD_SaveAsNew"), text = getText("IGUI_MBLD_SaveAsText", tostring(Plan.MAX_NAME)),
                    input = { text = name }, ok = getText("IGUI_MBLD_SaveAsNew"), onYes = function(t) o.onNew(t or "") end })
            end },
            { text = getText("UI_Cancel") } } })
end

if first then
    Events.OnGameStart.Add(function() B.PlanLibrary.startNotices() end)
end

return L
