-- 管理面板（設計稿 builder-feedback-1031 第 1、2 節）：管理員開關種類、來源、圖塊組，改規則頁的沙盒值（Admin.RULES）。
-- 改開關只改面板裡的草稿；按「套用」才寫沙盒，走原版沙盒封包（不新增網路指令）：
--   多人：當下從 getSandboxOptions() 複製一份、只改本 MOD 的鍵、sendToServer。伺服器先驗 Capability.SandboxOptions
--   （PacketTypes.java:300-305,421），再存檔、轉送給每個連線（GameServer.java:1710-1728），客戶端收到後 toLua 更新
--   SandboxVars（GameClient.java:2772-2779）。伺服器不回成功或失敗：SandboxVars 變成送出的值才算成功，10 秒沒變算失敗。
--   單機：直接 set 原版選項再 toLua（存檔時 GameWindow.java:1032-1040 寫進 map_sand.bin）。
-- 原版沙盒頁同一條路：ISServerSandboxOptionsUI.lua:762-771,794-795。
-- 每幀路徑（清單格、狀態列、說明文字的 render）只畫備好的字串；字串在狀態改變時才組。
if isServer() then return end

require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Window"
require "MinidoracatBuilder/Names"
require "MinidoracatBuilder/Index"
require "MinidoracatBuilder/Sources"

local B = MinidoracatBuilder
local first = B.Admin == nil
local Admin = B.Admin or {}
B.Admin = Admin
local Entry, W, Names, Index = B.Entry, B.Window, B.Names, B.Index

local LOG = "[MinidoracatBuilderFor42] "
local PREFIX = "MinidoracatBuilder."
-- 沙盒封包的字串以 2 位元組（有號 short）記 UTF-8 長度，超過 32767 讀回空字串（GameWindow.java:1263-1276）。
-- 這裡量的是字元數：MOD ID 與 tileset 名稱都是 ASCII，字元數＝位元組數。
Admin.MAX_STRING = 32000
Admin.TIMEOUT_MS = 10000
local PAD, GAP = 8, 6
local SWITCH_W = 32 -- 同 NavList 的開關寬（Widgets/NavList.lua:38）
local EMPTY = {}

-- 面板要的框架能力：建造視窗的全部，加上確認框與可停用的頁籤
local CAPS = {}
for i, cap in ipairs(W.CAPS) do CAPS[i] = cap end
CAPS[#CAPS + 1] = "dialog"
CAPS[#CAPS + 1] = "tabsEnabled"

-- 規則頁：sandbox-options.txt 的順序。預設值只給離線、沒有 SandboxVars 時用
Admin.RULES = {
    { key = "Enabled", kind = "bool", default = true },
    { key = "WhoCanUse", kind = "enum", count = 2, default = 1 },
    { key = "WhereCanBuild", kind = "enum", count = 2, default = 1 },
    { key = "MaxDistance", kind = "number", min = 2, max = 8, step = 1, default = 3 },
    { key = "MaxCellsPerDrag", kind = "number", min = 1, max = 64, step = 1, default = 32 },
    { key = "CostMultiplier", kind = "number", min = 0, max = 10, step = 0.05, default = 1 },
    { key = "RequireSkill", kind = "bool", default = false },
    { key = "RecipeMaterials", kind = "bool", default = false },
    { key = "ZombieProof", kind = "bool", default = false },
    { key = "ZombieProofDoors", kind = "bool", default = false },
    { key = "ContainerCapacityMultiplier", kind = "number", min = 1, max = 10, step = 0.1, default = 1 },
}
local TABS = { "kinds", "sources", "tilesets", "rules" }

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

local function counted(label, n)
    return getText("IGUI_MBLD_Count", label, tostring(n))
end

-- 沙盒值相等：數字差 1e-3 內（double 選項來回會有誤差），其他照 ==
local function same(a, b)
    if type(a) == "number" and type(b) == "number" then return math.abs(a - b) < 1e-3 end
    return a == b
end

local function parseSet(raw)
    local set = {}
    for part in (raw or ""):gmatch("[^;]+") do
        local id = trim(part)
        if id ~= "" then set[id] = true end
    end
    return set
end

local function catalogReady()
    return B.Catalog ~= nil and B.Catalog.state == "ready"
end

-- 框架有 Toast 就用（同 Window.lua 的 notify），沒有只寫 log
local function tell(text)
    local UI = MinidoracatUI and MinidoracatUI.v1
    if UI and UI.Toast and UI.Toast.show then
        pcall(UI.Toast.show, { title = getText("IGUI_MBLD_Admin_Title"), message = text, maxLines = 8 })
        return
    end
    print(LOG .. text)
end

-- apply 的失敗碼 → 給管理員看的句子（NOTHING 不必說）
local function errText(err, key)
    if err == "NOTHING" then return nil end
    if err == "NO_PERMISSION" then return getText("IGUI_MBLD_Admin_NoPermission") end
    if err == "BUSY" then return getText("IGUI_MBLD_Admin_Busy") end
    if err == "TOO_LONG" then return getText("IGUI_MBLD_Admin_TooLong", getText("Sandbox_MinidoracatBuilder_" .. tostring(key))) end
    return getText("IGUI_MBLD_Admin_Error", tostring(err) .. " " .. tostring(key or ""))
end

-- ===== 權限與能力 =====

function Admin.available()
    return W.ui(CAPS) ~= nil
end

-- 和原版沙盒封包同一個判斷（PacketTypes.java:300-302）：看這條連線的角色（haveAccess，LuaManager.java:4443-4446；
-- 分割畫面的玩家共用一條連線，個別玩家的 getRole 可能和連線的不同），合作模式的主機另外放行（isCoopHost，:9153-9154）。
-- UI 放行而封包被拒時伺服器記反作弊點數（PacketTypes.java:310-311）。不用 checkPermissions（客戶端一律回 true）。
function Admin.canManage()
    if not isClient() then return true end -- 單機：本機玩家就是主機
    return isCoopHost() or haveAccess("SandboxOptions") == true
end

-- ===== 合併與套用 =====

-- raw：伺服器現在的分號字串；changes[id] = true（關掉，加進去）或 false（打開，拿掉）。沒改到的 id 照舊。
-- 結果排序後用分號接（ScriptParser 拿逗號當欄位分隔）。不用 table.sort（Kahlua 的是遞迴、深度有上限；家族規則）
function Admin.merge(raw, changes)
    local set = parseSet(raw)
    for id, off in pairs(changes or EMPTY) do
        if off then set[id] = true else set[id] = nil end
    end
    local out = {}
    for id in pairs(set) do out[#out + 1] = { key = id } end
    W.sortByKey(out)
    for i = 1, #out do out[i] = out[i].key end
    return table.concat(out, ";")
end

local poll

local function finish(ok)
    local p = Admin.pending
    Admin.pending = nil
    Events.OnTick.Remove(poll) -- 原版同法（DebugUIs/ISFastTeleportMove.lua:24）
    if p and p.onDone then
        local good, err = pcall(p.onDone, ok)
        if not good then print(LOG .. "admin apply callback failed: " .. tostring(err)) end
    end
    if Admin.win then Admin.win:applied(ok) end
end

local function arrived(expect)
    local s = Entry.settings()
    for k, v in pairs(expect) do
        if not same(s[k], v) then return false end
    end
    return true
end

-- 送出後每 tick 比對（只在等待中掛著）
poll = function()
    local p = Admin.pending
    if not p then
        Events.OnTick.Remove(poll)
    elseif arrived(p.expect) then
        finish(true)
    elseif getTimestampMs() - p.at > Admin.TIMEOUT_MS then
        finish(false)
    end
end

-- changes = { kinds = { [種類] = 開 }, sources = { [MOD ID] = 關 }, tilesets = { [tileset] = 關 },
--             rules = { [選項短名] = 值 } }，每段都可省略。onDone(ok) 選填：伺服器的值到了（或單機改好）時 true，逾時 false。
-- 回 true，或 false＋原因碼（BUSY／NO_PERMISSION／NOTHING／TOO_LONG／UNKNOWN_KIND／UNKNOWN_OPTION）＋鍵。
function Admin.apply(changes, onDone)
    if Admin.pending then return false, "BUSY" end
    if not Admin.canManage() then return false, "NO_PERMISSION" end
    changes = changes or EMPTY
    local s = Entry.settings()
    local expect, any = {}, false
    local keyOf = Entry.KIND_KEY or EMPTY
    for kind, on in pairs(changes.kinds or EMPTY) do
        local key = keyOf[kind]
        if not key then return false, "UNKNOWN_KIND", tostring(kind) end
        expect[key] = on == true
        any = true
    end
    -- 字串從這台客戶端收到的最新值合併：別的管理員先套用、廣播已經到了的別項留著。不用 next（家族閘門：Kahlua 禁用全域）
    local function hasAny(t)
        for _ in pairs(t or EMPTY) do return true end
        return false
    end
    if hasAny(changes.sources) then
        expect.DisabledSources = Admin.merge(s.DisabledSources, changes.sources)
        any = true
    end
    if hasAny(changes.tilesets) then
        expect.DisabledTilesets = Admin.merge(s.DisabledTilesets, changes.tilesets)
        any = true
    end
    for k, v in pairs(changes.rules or EMPTY) do
        expect[k] = v
        any = true
    end
    if not any then return false, "NOTHING" end
    local live = getSandboxOptions()
    -- 先全部檢查再動手：set 遇到不存在的選項會丟例外（SandboxOptions.java:572-583），單機時會改到一半
    for k, v in pairs(expect) do
        if type(v) == "string" and #v > Admin.MAX_STRING then return false, "TOO_LONG", k end
        if live:getOptionByName(PREFIX .. k) == nil then return false, "UNKNOWN_OPTION", k end
    end
    if isClient() then
        -- 套用當下才複製：別的 MOD 的值與別的管理員改的值照這台最後收到的（伺服器每次收到都廣播整份，GameServer.java:1710-1724）。
        -- 封包是整份快照、伺服器整份照存（SandboxOptions.java:467-509）：兩人在對方的廣播到之前同時套用，後到的蓋掉先到的
        -- （原版伺服器沙盒視窗同樣送整份，ISServerSandboxOptionsUI.lua:762-771）。要不掉得在伺服器合併，不在這裡做
        local copy = SandboxOptions.new()
        copy:copyValuesFrom(live)
        for k, v in pairs(expect) do copy:set(PREFIX .. k, v) end
        copy:sendToServer() -- SandboxOptions.java:1107-1111
        Admin.pending = { expect = expect, at = getTimestampMs(), onDone = onDone }
        Events.OnTick.Add(poll)
        if Admin.win then Admin.win:setStatus() end
    else
        for k, v in pairs(expect) do live:set(PREFIX .. k, v) end
        live:toLua() -- SandboxVars 這時才更新（SandboxOptions.java:279-285）
        Admin.pending = { expect = expect, onDone = onDone }
        finish(true)
    end
    return true
end

-- ===== 詳情的快捷鈕：停用這個圖塊組／來源 =====

local function quickCount(isTileset, id)
    if not catalogReady() then return nil end
    if isTileset then return Index.sets[id] or 0 end
    local n, sn = 0, Index.setName
    for i = 1, sn.n do
        local ts = sn[i]
        if W.sourceOf(ts) == id then n = n + (Index.sets[ts] or 0) end
    end
    return n
end

-- field："tileset" 或 "source"（MOD ID；原版不會進來）
function Admin.quick(playerNum, field, id)
    local UI = W.ui(CAPS)
    if UI == nil or type(id) ~= "string" or id == "" then return false end
    if not Admin.canManage() then
        tell(getText("IGUI_MBLD_Admin_NoPermission"))
        return false
    end
    local isTileset = field == "tileset"
    local name = isTileset and id or W.modName(id)
    local what = isTileset and "Tileset" or "Source"
    local n = quickCount(isTileset, id)
    local text = n and getText("IGUI_MBLD_Admin_Quick" .. what, name, tostring(n))
        or getText("IGUI_MBLD_Admin_Quick" .. what .. "NoCount", name)
    UI.Dialog.show({ title = getText(isTileset and "IGUI_MBLD_Admin_DisableTileset" or "IGUI_MBLD_Admin_DisableSource"),
        text = text, confirmText = getText("IGUI_MBLD_Admin_TurnOff"), cancelText = getText("UI_Cancel"),
        danger = true, opaque = true, theme = UI.Theme.create({ variant = "dark" }),
        onResult = function(ok)
            if not ok then return end
            local changes = isTileset and { tilesets = { [id] = true } } or { sources = { [id] = true } }
            local sent, err, key = Admin.apply(changes, function(done)
                tell(done and getText("IGUI_MBLD_Admin_QuickDone", name) or getText("IGUI_MBLD_Admin_Failed"))
            end)
            if not sent then
                local msg = errText(err, key)
                if msg then tell(msg) end
            end
        end })
    return true
end

-- ===== 面板 =====

local Panel = {}
Panel.__index = Panel

-- 圖塊組清單的一列：名稱、項目數、開關。字串在 bind 時組好，render 只畫
local Cell = ISPanel:derive("MinidoracatBuilderAdminCell")
function Cell:render()
    if not self.row then return end
    local p, list = self.p, self.list
    local c = p.colors
    -- 選取列（鍵盤方向鍵、手把移動的那一列，Enter／A 切換它）要看得到：清單只記 selectedIndex，不自己畫（VirtualList.lua:94-96）
    local hl = list:isSelected(self.index) and (c.selected or c.hover)
        or list:isMouseOver() and list:indexAt(list:getMouseX(), list:getMouseY()) == self.index and c.hover
    if hl then self:drawRect(0, 0, self.width, self.height, hl.a or 1, hl.r, hl.g, hl.b) end
    local t = self.on and c.text or c.textMuted
    self:drawText(self.label, PAD, self.ty, t.r, t.g, t.b, t.a or 1, p.font)
    if self.count then
        local m = c.textMuted
        self:drawTextRight(self.count, self.countX, self.ty, m.r, m.g, m.b, m.a or 1, p.font)
    end
    p.UI.Skin.toggle(self, self.swX, 0, SWITCH_W, self.height, self.on, p.toggleColors, self.alpha)
end

local function newPane(parent, x, y, w, h)
    local pane = ISPanel:new(x, y, w, h)
    pane:initialise()
    pane.background = false
    parent:addChild(pane)
    return pane
end

-- 每段（翻譯的 "\n" 起新段）照寬度斷行；Text.wrap 回的是框架快取，只讀
local function paragraphs(UI, s, w, font)
    local out = {}
    for para in string.gmatch(tostring(s) .. "\n", "([^\n]*)\n") do
        if para ~= "" then
            local lines = UI.Text.wrap(para, w, font)
            for i = 1, #lines do out[#out + 1] = lines[i] end
        end
    end
    return out
end

function Panel:kindOn(k)
    local v = self.edit.kinds[k]
    if v == nil then v = self.base.kinds[k] end
    return v ~= false
end

function Panel:srcOff(id)
    local v = self.edit.sources[id]
    if v == nil then return self.base.srcOff[id] == true end
    return v
end

function Panel:tsOff(ts)
    local v = self.edit.tilesets[ts]
    if v == nil then return self.base.tsOff[ts] == true end
    return v
end

function Panel:rule(key)
    local v = self.edit.rules[key]
    if v == nil then return self.base.rules[key] end
    return v
end

-- 草稿只存和目前值不同的項目：改回原值就拿掉，改動數＝草稿項數
function Panel:put(part, id, v, baseV)
    if same(v, baseV) then self.edit[part][id] = nil else self.edit[part][id] = v end
    local n = 0
    for _, t in pairs(self.edit) do
        for _ in pairs(t) do n = n + 1 end
    end
    self.n = n
    if n == 0 then self.failed = false end
    self.error = nil
    self:setStatus()
end

-- ----- 種類頁：照建造視窗的頁籤分組 -----

function Panel:kindItem(k)
    local label = Names.kind(k)
    if self.ready then label = counted(label, Index.kindCount[k] or 0) end
    return { id = k, label = label, switch = {
        get = function() return self:kindOn(k) end,
        set = function(on) self:put("kinds", k, on == true, self.base.kinds[k] ~= false) end,
        enabled = self.editable } }
end

function Panel:buildKinds()
    local keyOf = Entry.KIND_KEY or EMPTY
    local groups, seen = {}, {}
    for _, tab in ipairs(W.TABS) do
        if tab ~= "all" then
            local items = {}
            for _, k in ipairs(W.TAB_KINDS[tab] or EMPTY) do
                if keyOf[k] and not seen[k] then
                    seen[k] = true
                    items[#items + 1] = self:kindItem(k)
                end
            end
            if #items > 0 then groups[#groups + 1] = { title = getText("IGUI_MBLD_Tab_" .. tab), items = items } end
        end
    end
    -- 不在任何頁籤的種類（不該有）也列出來，免得關不掉
    local rest = {}
    for _, k in ipairs(Entry.KINDS or EMPTY) do
        if not seen[k] then rest[#rest + 1] = self:kindItem(k) end
    end
    if #rest > 0 then groups[#groups + 1] = { items = rest } end
    self.kindNav:setGroups(groups)
end

-- ----- 來源頁：有圖塊的 MOD，加上目前關著但沒載入的 -----

function Panel:buildSources()
    local counts, order = {}, {}
    if self.ready then
        local sn = Index.setName
        for i = 1, sn.n do
            local ts = sn[i]
            local src = W.sourceOf(ts)
            if src ~= "vanilla" and src ~= "?" then
                if not counts[src] then
                    counts[src] = 0
                    order[#order + 1] = src
                end
                counts[src] = counts[src] + (Index.sets[ts] or 0)
            end
        end
    end
    for _, t in ipairs({ self.base.srcOff, self.edit.sources }) do
        for id in pairs(t) do
            if counts[id] == nil then
                counts[id] = false
                order[#order + 1] = id
            end
        end
    end
    local rows = {}
    for i, id in ipairs(order) do
        local name = W.modName(id)
        rows[i] = { id = id, key = string.lower(name), label = counts[id] and counted(name, counts[id]) or name, switch = {
            get = function() return not self:srcOff(id) end,
            set = function(on) self:put("sources", id, not on, self.base.srcOff[id] == true) end,
            enabled = self.editable } }
    end
    W.sortByKey(rows)
    self.srcNav:setGroups({ { items = rows } })
    local note = getText("IGUI_MBLD_Admin_SourcesHint")
    if not self.ready then
        note = getText("IGUI_MBLD_Admin_Building")
    elseif #rows == 0 then
        note = getText("IGUI_MBLD_Admin_NoSources")
    end
    self.srcNote = self.UI.Text.fit(note, self.innerW, self.font)
end

-- ----- 圖塊組頁：篩選＋虛擬清單（800 多列） -----

local function tsRow(ts, n)
    local fam = ts:match("^(.-)_%d+$") or ts
    local shown = getTextOrNull("IGUI_MBLD_Family_" .. fam) -- 有譯名才接在後面（同 Names.tileset 的鍵）
    local label = shown and (ts .. "  " .. Names.tileset(ts)) or ts
    return { ts = ts, key = string.lower(ts), q = string.lower(label), label = label, n = n }
end

function Panel:buildTilesets()
    local rows, have = {}, {}
    if self.ready then
        local sn = Index.setName
        for i = 1, sn.n do
            local ts = sn[i]
            have[ts] = true
            rows[#rows + 1] = tsRow(ts, Index.sets[ts])
        end
    end
    for _, t in ipairs({ self.base.tsOff, self.edit.tilesets }) do
        for ts in pairs(t) do
            if not have[ts] then
                have[ts] = true
                rows[#rows + 1] = tsRow(ts, nil)
            end
        end
    end
    W.sortByKey(rows)
    self.tsAll = rows
    self.tsNote = self.UI.Text.fit(getText(self.ready and "IGUI_MBLD_Admin_TilesetsHint" or "IGUI_MBLD_Admin_Building"),
        self.innerW, self.font)
    self:filterTilesets(self.filter:getText())
end

function Panel:filterTilesets(text)
    local q = string.lower(trim(text))
    local all = self.tsAll or EMPTY
    local out = all
    if q ~= "" then
        out = {}
        for _, r in ipairs(all) do
            if string.find(r.q, q, 1, true) then out[#out + 1] = r end
        end
    end
    self.tsList:setItems(out)
end

function Panel:bindCell(cell, row, index)
    local fh = self.fh
    cell.index, cell.row = index, row
    cell.on = not self:tsOff(row.ts)
    cell.alpha = self.editable() and 1 or 0.45
    cell.ty = math.floor((cell.height - fh) / 2)
    cell.swX = cell.width - PAD - SWITCH_W
    cell.countX = cell.swX - GAP
    local right = cell.countX
    cell.count = row.n and tostring(row.n) or nil
    if cell.count then right = right - getTextManager():MeasureStringX(self.font, cell.count) - GAP end
    cell.label = self.UI.Text.fit(row.label, right - PAD, self.font)
end

function Panel:toggleTileset(row)
    if not self.editable() then return end
    self:put("tilesets", row.ts, not self:tsOff(row.ts), self.base.tsOff[row.ts] == true)
    self.tsList:setItems(self.tsList:getItems()) -- revision 加一：可見列重綁（VirtualList.lua:78-86）
end

-- ----- 規則頁：勾選框、下拉、滑桿，名稱與說明用沙盒頁的翻譯 -----

local function stepped(v, step)
    if step == math.floor(step) then return math.floor(v + 0.5) end
    return math.floor(v * 100 + 0.5) / 100
end

function Panel:buildRules(pane)
    local UI, theme, font, fh = self.UI, self.theme, self.font, self.fh
    local box = UI.ScrollPanel.new({ x = PAD, y = 0, width = pane.width - 2 * PAD, height = pane.height, theme = theme })
    pane:addChild(box)
    local cw = box:contentWidth()
    local body = ISPanel:new(0, 0, cw, 1) -- 先加：畫在控制項底下
    body:initialise()
    body.background = false
    box:addChild(body)
    local texts, y = {}, GAP
    self.ruleCtl = {}
    for _, r in ipairs(Admin.RULES) do
        local key, name = r.key, "Sandbox_MinidoracatBuilder_" .. r.key
        local label = getText(name)
        local ctl
        if r.kind == "bool" then
            ctl = UI.Checkbox.new({ x = 0, y = y, width = cw, label = label, theme = theme, target = self,
                onChange = function(t, checked) t:put("rules", key, checked == true, t.base.rules[key]) end })
        elseif r.kind == "enum" then
            local opts = {}
            for v = 1, r.count do opts[v] = { id = v, label = getText(name .. "_option" .. v) } end
            local ddW = math.floor(cw * 0.45)
            ctl = UI.Dropdown.new({ x = cw - ddW, y = y, width = ddW, options = opts, selected = r.default, theme = theme,
                target = self, onChange = function(t, id) t:put("rules", key, id, t.base.rules[key]) end })
            ctl._focusLabel = label
            texts[#texts + 1] = { s = UI.Text.fit(label, cw - ddW - GAP, font), y = y + math.floor((ctl.height - fh) / 2),
                c = self.colors.text }
        else
            ctl = UI.SliderRow.new({ x = 0, y = y, width = cw, label = label, labelWidth = math.floor(cw * 0.45),
                min = r.min, max = r.max, step = r.step, value = r.default, theme = theme, target = self,
                onChange = function(t, v) t:put("rules", key, stepped(v, r.step), t.base.rules[key]) end })
        end
        box:addChild(ctl)
        self.ruleCtl[key] = ctl
        y = y + ctl.height + 2
        for _, line in ipairs(paragraphs(UI, getText(name .. "_tooltip"), cw, font)) do
            texts[#texts + 1] = { s = line, y = y, c = self.colors.textMuted }
            y = y + fh
        end
        y = y + GAP * 2
    end
    body:setHeight(y)
    body.render = function(el)
        for i = 1, #texts do
            local t = texts[i]
            el:drawText(t.s, 0, t.y, t.c.r, t.c.g, t.c.b, t.c.a or 1, font)
        end
    end
end

-- 控制項照草稿顯示（不回呼）；送出中整面鎖住
function Panel:syncControls()
    local editable = self.editable()
    for _, r in ipairs(Admin.RULES) do
        local ctl, v = self.ruleCtl[r.key], self:rule(r.key)
        if r.kind == "bool" then
            ctl:setChecked(v == true, true)
        elseif r.kind == "enum" then
            ctl:setSelected(math.floor((tonumber(v) or r.default) + 0.5), true)
        else
            ctl:setValue(tonumber(v) or r.default, true)
        end
        ctl:setEnabled(editable)
    end
    self.kindNav:refresh()
    self.srcNav:refresh()
    self.tsList:setItems(self.tsList:getItems())
end

-- ----- 草稿與狀態列 -----

-- 從 SandboxVars 重讀。開面板、自己的套用成功、還原：草稿清掉。設定被別人或快捷鈕改了：keep＝true，草稿只留和新值
-- 還不一樣的項目（不然開關照舊值畫，按套用時又把剛改的蓋回去）
function Panel:reload(keep)
    local s, old = Entry.settings(), keep and self.edit
    local b = { kinds = {}, srcOff = parseSet(s.DisabledSources), tsOff = parseSet(s.DisabledTilesets), rules = {},
        rawSrc = s.DisabledSources or "", rawTs = s.DisabledTilesets or "" }
    for _, k in ipairs(Entry.KINDS or EMPTY) do b.kinds[k] = Entry.kindOn(k, s) ~= false end
    for _, r in ipairs(Admin.RULES) do
        local v = s[r.key]
        if v == nil then v = r.default end
        b.rules[r.key] = v
    end
    self.base = b
    self.edit = { kinds = {}, sources = {}, tilesets = {}, rules = {} }
    local n = 0
    if old then
        local now = { kinds = b.kinds, sources = b.srcOff, tilesets = b.tsOff, rules = b.rules }
        for part, t in pairs(old) do
            for id, v in pairs(t) do
                local cur = now[part][id]
                if part == "sources" or part == "tilesets" then cur = cur == true end
                if not same(v, cur) then
                    self.edit[part][id] = v
                    n = n + 1
                end
            end
        end
    end
    self.n, self.failed, self.error = n, self.failed == true and n > 0, nil
    self:rebuild()
    self:syncControls()
    self:setStatus()
end

function Panel:rebuild()
    self.ready = catalogReady()
    self:buildKinds()
    self:buildSources()
    self:buildTilesets()
end

-- SandboxVars 和面板讀進來的值不一樣了（別的管理員或快捷鈕改的）
function Panel:stale()
    local s, b = Entry.settings(), self.base
    if (s.DisabledSources or "") ~= b.rawSrc or (s.DisabledTilesets or "") ~= b.rawTs then return true end
    for k, on in pairs(b.kinds) do
        if (Entry.kindOn(k, s) ~= false) ~= on then return true end
    end
    for _, r in ipairs(Admin.RULES) do
        local v = s[r.key]
        if v ~= nil and not same(v, b.rules[r.key]) then return true end
    end
    return false
end

function Panel:layoutFoot()
    local x = self.foot.width - PAD - self.applyBtn.width
    self.applyBtn:setX(x)
    self.revertBtn:setX(x - GAP - self.revertBtn.width)
end

-- 設計稿的四態：clean／dirty／sending／failed，另加沒有權限與套用前就被擋下（error）
function Panel:setStatus()
    local c = self.colors
    self.allowed = Admin.canManage()
    local sending = Admin.pending ~= nil
    local text, color
    if not self.allowed then
        text, color = getText("IGUI_MBLD_Admin_NoPermission"), c.errorText
    elseif sending then
        text, color = getText("IGUI_MBLD_Admin_Sending"), c.textMuted
    elseif self.error then
        text, color = self.error, c.errorText
    elseif self.failed then
        text, color = getText("IGUI_MBLD_Admin_Failed"), c.errorText
    elseif self.n > 0 then
        text, color = getText("IGUI_MBLD_Admin_Dirty", tostring(self.n)), c.text
    else
        text, color = getText("IGUI_MBLD_Admin_Clean"), c.textMuted
    end
    local title = getText(self.failed and not sending and "IGUI_MBLD_Admin_Retry" or "IGUI_MBLD_Admin_Apply")
    if title ~= self.applyBtn.title then
        self.applyBtn:setTitle(title) -- 沒給寬度建的按鈕 setTitle 會重算寬度（Controls.lua:260-269）：重排
        self:layoutFoot()
    end
    self.revertBtn:setEnabled(not sending and self.n > 0)
    self.applyBtn:setEnabled(self.allowed and not sending and self.n > 0)
    -- 狀態列在按鈕上面、用整個寬度，最多兩行（失敗的說明在 EN、DE、FR、PL 放在按鈕旁一行放不下：E2E admin-mp 1031c）。
    -- Text.wrap 回框架快取，只讀；超過兩行時第二行接上其餘再截
    local lines = self.UI.Text.wrap(text, self.innerW, self.font)
    local out = { lines[1] or "" }
    if #lines == 2 then
        out[2] = lines[2]
    elseif #lines > 2 then
        local rest = {}
        for i = 2, #lines do rest[#rest + 1] = lines[i] end
        out[2] = self.UI.Text.fit(table.concat(rest, " "), self.innerW, self.font)
    end
    self.statusLines = out
    self.statusColor = color
    if self.locked ~= sending then
        self.locked = sending
        self:syncControls()
    end
end

function Panel:applied(ok)
    local mine = self.sent
    self.sent = false
    if ok then
        self:reload(not mine) -- 快捷鈕的套用：面板的草稿留著，只留和新值還不一樣的
        if mine then tell(getText("IGUI_MBLD_Admin_Applied")) end
        return
    end
    if mine then
        self.failed = true
        tell(getText("IGUI_MBLD_Admin_Failed")) -- 和成功一樣跳通知：等待中關掉面板也看得到
    end
    self:setStatus()
end

function Panel:onApply()
    if self.n == 0 or Admin.pending then return end
    self.sent = true
    self.failed, self.error = false, nil
    local ok, err, key = Admin.apply(self.edit)
    if not ok then
        self.sent = false
        self.error = errText(err, key)
        self:setStatus()
    end
end

-- 狀態列的 prerender：每秒看一次權限、目錄、SandboxVars（只比對，不配置）
function Panel:pump()
    local now = getTimestampMs()
    if now < self.checkAt then return end
    self.checkAt = now + 1000
    if catalogReady() ~= self.ready then
        self:rebuild()
        self:syncControls()
    end
    if not Admin.pending and self:stale() then
        self:reload(true)
    elseif Admin.canManage() ~= self.allowed then
        self:setStatus()
    end
end

function Panel:show(id)
    self.tab = id
    for _, t in ipairs(TABS) do self.panes[t]:setVisible(t == id) end
    self.UI.Dropdown.close(self.win)
end

-- ----- 建面板 -----

function Panel:buildLists(bodyY, bodyH)
    local UI, theme, w, fh = self.UI, self.theme, self.w, self.fh
    local panes = {}
    for _, t in ipairs(TABS) do panes[t] = newPane(self.win, 0, bodyY, w, bodyH) end
    self.panes = panes
    -- 種類
    local box = UI.ScrollPanel.new({ x = PAD, y = 0, width = self.innerW, height = bodyH, theme = theme })
    panes.kinds:addChild(box)
    self.kindNav = UI.NavList.new({ x = 0, y = 0, width = box:contentWidth(), groups = {}, theme = theme, target = self })
    box:addChild(self.kindNav)
    -- 來源：上面一行說明
    local noteH = fh + GAP
    panes.sources.render = function(el)
        local c = self.colors.textMuted
        if self.srcNote then el:drawText(self.srcNote, PAD, 0, c.r, c.g, c.b, c.a or 1, self.font) end
    end
    box = UI.ScrollPanel.new({ x = PAD, y = noteH, width = self.innerW, height = bodyH - noteH, theme = theme })
    panes.sources:addChild(box)
    self.srcNav = UI.NavList.new({ x = 0, y = 0, width = box:contentWidth(), groups = {}, theme = theme, target = self })
    box:addChild(self.srcNav)
    -- 圖塊組：篩選欄、一行說明、清單
    self.filter = UI.TextField.new({ x = PAD, y = 0, width = self.innerW, placeholder = getText("IGUI_MBLD_Admin_Filter"),
        clearButton = true, theme = theme, onChange = function(_, text) self:filterTilesets(text) end })
    panes.tilesets:addChild(self.filter)
    local noteY = self.filter.height + GAP
    panes.tilesets.render = function(el)
        local c = self.colors.textMuted
        if self.tsNote then el:drawText(self.tsNote, PAD, noteY, c.r, c.g, c.b, c.a or 1, self.font) end
    end
    local listY = noteY + noteH
    self.tsList = UI.VirtualList.new({ x = PAD, y = listY, width = self.innerW, height = bodyH - listY,
        rowHeight = math.max(24, fh + 8), padding = 2,
        createCell = function(list)
            local cell = Cell:new(0, 0, 0, 0)
            cell.background = false
            cell.p, cell.list = self, list
            return cell
        end,
        bindCell = function(_, cell, row, index) self:bindCell(cell, row, index) end,
        unbindCell = function(_, cell) cell.row = nil end,
        onSelect = function(_, row) self:toggleTileset(row) end,
        colors = { thumb = self.colors.textFaint, thumbHover = self.colors.textMuted, track = self.colors.hover } })
    self.tsList:initialise()
    panes.tilesets:addChild(self.tsList)
    self:buildRules(panes.rules)
end

-- 底部：上面兩行狀態（整個寬度），下面一排按鈕靠右
function Panel:buildFoot(footY, footH, btnH)
    local UI, theme = self.UI, self.theme
    local foot = newPane(self.win, 0, footY, self.w, footH)
    self.foot = foot
    foot.prerender = function() self:pump() end
    foot.render = function(el)
        local c, lines = self.statusColor, self.statusLines
        if lines and c then
            for i = 1, #lines do
                el:drawText(lines[i], PAD, (i - 1) * self.fh, c.r, c.g, c.b, c.a or 1, self.font)
            end
        end
    end
    local by = footH - btnH
    self.revertBtn = UI.Button.new({ x = 0, y = by, height = btnH, title = getText("IGUI_MBLD_Admin_Revert"), theme = theme,
        target = self, onClick = function(t) t:reload() end })
    self.applyBtn = UI.Button.new({ x = 0, y = by, height = btnH, title = getText("IGUI_MBLD_Admin_Apply"),
        style = "primary", theme = theme, target = self, onClick = function(t) t:onApply() end })
    foot:addChild(self.revertBtn)
    foot:addChild(self.applyBtn)
    self:layoutFoot()
end

function Panel.new(UI, playerNum)
    local theme = UI.Theme.create({ variant = "dark" })
    local font = UIFont.Small
    local fh = getTextManager():getFontHeight(font)
    local s = fh / 16 -- 字級比例（同 Window.lua 的 W.create）
    local self = setmetatable({ UI = UI, theme = theme, colors = theme.colors, font = font, fh = fh,
        playerNum = playerNum, checkAt = 0, n = 0, locked = false,
        edit = { kinds = {}, sources = {}, tilesets = {}, rules = {} } }, Panel)
    self.editable = function() return Admin.pending == nil end
    self.toggleColors = { off = theme.colors.well, on = theme.colors.accent, border = theme.colors.border }
    local items = {}
    for i, id in ipairs(TABS) do items[i] = { id = id, label = getText("IGUI_MBLD_Admin_Tab_" .. id) } end
    -- 視窗裡第一個 Tabs：手把 LB／RB 切它（Widgets/Window.lua:315-325）
    self.tabs = UI.Tabs.new({ x = PAD, y = 0, items = items, selected = "kinds", theme = theme, target = self,
        onSelect = function(t, id) t:show(id) end })
    -- 用該玩家的畫面範圍（分割畫面；LuaManager.java:3908-3934，同 Window.lua）。1280×720 時 560×600
    local sx, sy = getPlayerScreenLeft(playerNum), getPlayerScreenTop(playerNum)
    local sw, sh = getPlayerScreenWidth(playerNum), getPlayerScreenHeight(playerNum)
    local w = math.min(sw - 40, math.max(math.floor(560 * s), self.tabs.width + 2 * PAD))
    local h = math.min(sh - 80, math.floor(600 * s))
    self.w, self.innerW = w, w - 2 * PAD
    local win = UI.Window.new({ x = sx + math.floor((sw - w) / 2), y = sy + math.floor((sh - h) / 2), width = w, height = h,
        title = getText("IGUI_MBLD_Admin_Title"), icon = "settings", theme = theme, opaque = true,
        onClose = function(wnd) UI.Dropdown.close(wnd) end }) -- 只關這個視窗的下拉（ARCH §3.17）
    win.onEscape = function()
        win:close()
        return true
    end
    self.win = win
    Admin.win = self -- 建到一半出錯時 discard 收得到
    local top = win:contentTop() + GAP
    self.tabs:setY(top)
    win:addChild(self.tabs)
    local btnH = fh + 10
    local footH = 2 * fh + GAP + btnH
    local footY = h - PAD - footH
    local bodyY = top + self.tabs.height + GAP
    self:buildFoot(footY, footH, btnH)
    self:buildLists(bodyY, footY - GAP - bodyY)
    self:show("kinds")
    win:addToUIManager()
    return self
end

local function discard()
    local p = Admin.win
    Admin.win = nil
    if p and p.win then
        pcall(function()
            p.win:setVisible(false)
            p.win:removeFromUIManager()
        end)
    end
end

function Admin.open(playerNum)
    local UI = W.ui(CAPS)
    if UI == nil then
        tell(getText("IGUI_MBLD_NeedFramework"))
        return false
    end
    playerNum = playerNum or 0
    if not Admin.canManage() then
        tell(getText("IGUI_MBLD_Admin_NoPermission"))
        return false
    end
    local p = Admin.win
    if p == nil or p.UI ~= UI or p.playerNum ~= playerNum then
        discard()
        local ok, err = pcall(Panel.new, UI, playerNum)
        if not ok then
            print(LOG .. "admin panel build failed: " .. tostring(err))
            tell(getText("IGUI_MBLD_Admin_BuildFailed")) -- 框架版本已經過 W.ui(CAPS)，走到這裡是本 MOD 的錯；細節在 console
            discard()
            return false
        end
        p = Admin.win
    elseif p.win:getIsVisible() then
        p.win:bringToTop() -- 已經開著：不丟掉還沒套用的草稿
        return true
    end
    if p.sent or p.failed then
        p:setStatus() -- 等待中或失敗：草稿留著（「再試一次」要用），不重讀
    else
        p:reload()
    end
    p.win:setVisible(true) -- 框架 Window：Focus.onFocus＋takeJoypad（Widgets/Window.lua:336-348）
    p.win:bringToTop()
    return true
end

function Admin.close()
    local p = Admin.win
    if p and p.win:getIsVisible() then p.win:close() end
end

-- 角色換了（原版管理面板同兩個事件：ISAdminPanelUI.lua:421,441）：重排建造視窗的「管理」鈕；沒有權限了就關面板
function Admin.onRoles()
    local Win = MinidoracatBuilder.Window
    if Win.v then Win.layout() end
    local p = Admin.win
    if p and p.win:getIsVisible() and not Admin.canManage() then Admin.close() end
end

if first then
    Events.OnRolesReceived.Add(function() MinidoracatBuilder.Admin.onRoles() end) -- RolesPacket.java:117
    Events.RefreshCheats.Add(function() MinidoracatBuilder.Admin.onRoles() end)   -- ExtraInfoPacket.java:224
end

return Admin
