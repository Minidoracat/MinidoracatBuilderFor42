-- 框選現成的房子存成藍圖：拖長方形（Cursor.startArea，只用滑鼠，同一區拆除）→ 從玩家那層往上 4 層分幀讀畫面上的圖塊 →
-- 跳結果框（能收幾片幾種、不收的照原因分組、名稱）→ 存成藍圖檔、打開藍圖庫。只讀世界，不動世界、不送伺服器。
-- 只收建造工坊能蓋的圖（Entry.resolve）與原版建造配方蓋的東西（收成 recipe: 項目）；容器裡的東西、地上物品、車、屍體
-- 不是格上的圖塊，不收。開著的門、破掉的窗、拉上的窗簾照 Entry.why 認回能蓋的那一張（門窗一律記成關著）；
-- 多格物件、樓梯、坡道只在原點那一片記一次（它補的平台照地板記、標上那一組在哪層，那層有勾時不另外收）；車庫門、雙開門照
-- Place.doorGroup 認回第一片、錨點與寬度，一扇記一片。結果框可勾要哪幾層（Capture.build 的 on）。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Place"
require "MinidoracatBuilder/Plan"
require "MinidoracatBuilder/PlanFile"
require "MinidoracatBuilder/Messages"

local B = MinidoracatBuilder
local Capture = B.Capture or {}
B.Capture = Capture
local Entry, Place, Plan, PlanFile, Messages = B.Entry, B.Place, B.Plan, B.PlanFile, B.Messages

local LOG = "[MinidoracatBuilderFor42] "
local PAD, GAP = 8, 6
Capture.BUDGET_MS = 2
Capture.LEVELS = Plan.MAX_LEVELS
Capture.SIDE = Plan.MAX_SIDE

-- 不收的原因碼 → 結果框的分組（IGUI_MBLD_Cap_Skip_<組>）；表外的碼歸 Closed
local GROUP = { TERRAIN = "Terrain", OUTSIDE = "Outside", DISABLED_KIND = "Off", DISABLED_SOURCE = "Off",
    DISABLED_TILESET = "Off", PREFIX = "Plant", TREE = "Plant", PLANT = "Plant", ENTITY = "Special",
    ENTITY_NONE = "Special", LUA = "Special", WATER = "Special", COLLECTOR = "Special", LIGHT = "Special" }
Capture.GROUP = GROUP
-- 分組照這個順序列
Capture.ORDER = { "Off", "Special", "Plant", "Terrain", "Outside", "Closed" }

-- ===== 認圖（只讀） =====

-- 不收的照層記（結果框只數勾著的層）
local function skip(res, code, z)
    local t = res.skipZ[z]
    if not t then
        t = {}
        res.skipZ[z] = t
    end
    t[code] = (t[code] or 0) + 1
    res.skipped = res.skipped + 1
end

-- 記一片（世界座標，錨點）。同一個錨點、項目、朝向只記一次
local function add(res, id, x, y, z, d, w)
    local key = id .. "|" .. x .. "," .. y .. "," .. z .. "," .. d
    if res.seen[key] then return end
    res.seen[key] = true
    res.n = res.n + 1
    res.pieces[res.n] = { id = id, x = x, y = y, z = z, d = d, w = w }
end

-- 圖塊項目：錨點＝這一張在佔地裡的位置倒推回原點（樓梯的底片在第 3 格，原點是頂片那格；多格物件的原點是自己）
local function addTile(res, entry, name, x, y, z)
    for _, o in ipairs(Entry.cells(entry.spr)) do
        if o[5] ~= "platform" and o[4]:getName() == name then
            return add(res, entry.name, x - o[1], y - o[2], z - o[3], 0, nil)
        end
    end
    return add(res, entry.name, x, y, z, 0, nil)
end

-- 配方蓋的圖：這張是配方哪一面的主圖才記（同一件的其他格不重複記）。回 true＝這張歸配方處理了
local function recipeTile(res, name, x, y, z)
    local R = B.Recipes
    if not R then return false end
    if R.all then R.all() end
    local r = R.bySprite and R.bySprite[name]
    if not r then return false end
    if R.faceOf then
        -- 只認每一面第一格有圖的（記在錨點那格）；多格的其他格、牆面油漆這類回 nil，不另外記
        local d, dx, dy = R.faceOf(r.id, name)
        if d then add(res, r.id, x - (dx or 0), y - (dy or 0), z, d, nil) end
    elseif name == r.sprite then
        add(res, r.id, x, y, z, 0, nil)
    end
    return true
end

-- 一張圖。z0＝框選的最低層（那一層的天然地面不收，連它邊緣附著的漸層圖一起：那些是地形，不是蓋出來的）。
-- 挖地下室的三個項目 ID 借用原版圖名（Rules.DIG）：世界上同名的是引擎的隱形地板、地圖的地下土塊，不是挖出來的，
-- 照有挖掘之前當引擎內部圖不收（LUA）；挖掉的地也不是能照圖蓋的東西（藍圖不認挖掘，地下室方案 §1.4）
function Capture.tile(res, name, x, y, z, z0)
    if not name:find("_%d+$") then return end
    if B.Rules.DIG[name] then return skip(res, "LUA", z) end
    local entry = Entry.resolve(name)
    if entry then
        local k = entry.kind
        if z == z0 and (k == "floor" or k == "water" or k == "floorOverlay") and name:find("^blends_natural_") then
            return skip(res, "TERRAIN", z)
        end
        return addTile(res, entry, name, x, y, z)
    end
    if recipeTile(res, name, x, y, z) then return end
    local code, _, alt = Entry.why(name)
    -- 多格的其他格、樓梯的中片頂片：原點那一張自己會被讀到
    if code == "PART" or code == "STAIRS_SET" then return end
    local altEntry = alt and Entry.resolve(alt)
    if altEntry then return addTile(res, altEntry, alt, x, y, z) end -- 開著的門、窗的狀態圖、拉上的窗簾、疊放圖
    skip(res, code or "UNKNOWN", z)
end

-- 坡道、樓梯補的平台（Place.deckOwner）：那一組收得進藍圖時回那一組在哪層（平台照地板記、標上這層，Capture.build 在這層
-- 有勾時不收：放那一組時會帶平台，Place.build；沒勾時照地板收，只勾樓上時樓梯口才有地板）。收得進＝框選會讀到、記成那一組
-- 的那一片（坡道頭片、樓梯底片）和錨點都在框裡，而且那一片能蓋（Entry.resolve）。收不進（在框外、那種沒開放）、不是坡道或
-- 樓梯通到的同圖地板、圖和那一組會補的不同時回 nil（照一般地板收）
local function inBox(b, x, y, z)
    return x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 and z >= b.z0 and z <= b.z1
end

local function platform(res, name, sq)
    local b = res.box
    if not b then return nil end
    local x, y, z, px, py, pname = Place.deckOwner(name, sq)
    if x ~= nil and inBox(b, x, y, z) and inBox(b, px, py, z) and Entry.resolve(pname) ~= nil then return z end
    return nil
end

-- 一格上的每一件（地上物品不收：容器裡的東西、車、屍體本來就不在格上的物件裡）
function Capture.square(res, sq, z0)
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        local spr = not instanceof(o, "IsoWorldInventoryObject") and o:getSprite()
        local name = spr and spr:getName()
        if name then
            -- 只有車庫門、雙開門的片才問 doorItem（其他圖它會往前後各找 16 張，整區讀下來太慢）
            local door = B.Rules.grouped(spr:getProperties()) and Entry.doorItem(name)
            if door then
                -- 車庫門、雙開門：整扇記一片，記在第一片那格（其他片讀到時錨點不是自己那格，略過）
                local g = Place.doorGroup(o)
                if not g then
                    skip(res, "DOOR_SET", z)
                elseif g.x == x and g.y == y and g.z == z then
                    add(res, g.e, x, y, z, 0, g.garage and g.w or nil)
                end
            else
                local n, deck = res.n, platform(res, name, sq)
                Capture.tile(res, name, x, y, z, z0)
                if deck and res.n > n then res.pieces[res.n].deck = deck end
            end
            local att = o:getAttachedAnimSprite()
            for j = 0, att and att:size() - 1 or -1 do
                local a = att:get(j)
                local an = a and a:getName()
                if an then Capture.tile(res, an, x, y, z, z0) end
            end
            local ov = o:getOverlaySprite()
            local on = ov and ov:getName()
            if on then Capture.tile(res, on, x, y, z, z0) end
        end
    end
end

-- ===== 分幀掃 =====

-- 開一次掃描：回 job，或 nil, "TOO_WIDE"（任一邊超過 64 格）。job 由 Capture.step 推進
function Capture.scan(x1, y1, x2, y2, z)
    if x1 > x2 then x1, x2 = x2, x1 end
    if y1 > y2 then y1, y2 = y2, y1 end
    if x2 - x1 + 1 > Capture.SIDE or y2 - y1 + 1 > Capture.SIDE then return nil, "TOO_WIDE" end
    return { x1 = x1, y1 = y1, x2 = x2, y2 = y2, z0 = z, z1 = z + Capture.LEVELS - 1, x = x1, y = y1, z = z,
        res = { pieces = {}, n = 0, seen = {}, skipZ = {}, skipped = 0,
            box = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, z0 = z, z1 = z + Capture.LEVELS - 1 } } }
end

-- 掃到時間用完（每幀 BUDGET_MS），掃完回 true
function Capture.step(job)
    local cell = getCell()
    local stop = getTimestampMs() + Capture.BUDGET_MS
    repeat
        if job.z > job.z1 then return true end
        local sq = cell:getGridSquare(job.x, job.y, job.z)
        if sq then Capture.square(job.res, sq, job.z0) end
        job.x = job.x + 1
        if job.x > job.x2 then
            job.x, job.y = job.x1, job.y + 1
            if job.y > job.y2 then job.y, job.z = job.y1, job.z + 1 end
        end
    until getTimestampMs() >= stop
    return job.z > job.z1
end

local function picked(on, dz)
    return on == nil or on[dz] == true
end

-- 掃的結果做成藍圖（原點＝框的西北角、最低勾選層）。選填的 on＝{ [層差 0..3] = true }，沒給＝四層都收；中間沒勾的層照留空
-- （壓縮會讓上層地板落在下層牆的位置）。超過 4,096 片的照掃到的順序收到滿為止。不改 job：勾選一變就再跑一次。
-- 回 { plan, kinds＝幾種, over＝沒收進去的片數, wide＝這裡蓋不了的車庫門扇數, skip＝勾選層不收的照原因數, skipped, job }
function Capture.build(job, name, ...)
    local on = ...
    local res, plan = job.res, Plan.new(name)
    local over, wide, skips, skipped, base = 0, 0, {}, 0, nil
    for dz = Capture.LEVELS - 1, 0, -1 do
        local t = res.skipZ[job.z0 + dz]
        if picked(on, dz) then base = dz end
        if t and picked(on, dz) then
            for code, n in pairs(t) do
                skips[code] = (skips[code] or 0) + n
                skipped = skipped + n
            end
        end
    end
    base = base or 0
    local maxW = math.max(2, tonumber(Entry.settings().MaxCellsPerDrag) or 32)
    for i = 1, res.n do
        local p = res.pieces[i]
        local dz = p.z - job.z0
        -- 層差不在 0..3 的（多格物件的錨點在框外）照舊交給 Plan.add 擋
        if (dz < 0 or dz >= Capture.LEVELS or picked(on, dz)) and not (p.deck and picked(on, p.deck - job.z0)) then
            if plan.n >= Plan.MAX_PIECES then
                over = over + 1
            else
                local it = Plan.item(plan, p.id, PlanFile.source(p.id))
                local ok, why = Plan.add(plan, p.x - job.x1, p.y - job.y1, dz - base, p.d, 0, it, p.w)
                if ok then
                    if p.w and p.w > maxW then wide = wide + 1 end
                elseif why == "TOO_WIDE" or why == "TOO_HIGH" or why == "RANGE" then
                    -- 原點落在框外、撐出 64 格或 4 層的多格物件
                    skips.OUTSIDE = (skips.OUTSIDE or 0) + 1
                    skipped = skipped + 1
                end
            end
        end
    end
    Plan.forget(plan) -- 擷取不是一步撤銷得回來的編輯
    local kinds = 0
    for i = 1, plan.nItems do
        if plan.items[i].n > 0 then kinds = kinds + 1 end
    end
    return { plan = plan, kinds = kinds, over = over, wide = wide, skip = skips, skipped = skipped, job = job }
end

-- 不收的照分組數：{ { group, n }… }，照 Capture.ORDER
function Capture.groups(skips)
    local by = {}
    for code, n in pairs(skips) do
        local g = GROUP[code] or "Closed"
        by[g] = (by[g] or 0) + n
    end
    local out = {}
    for _, g in ipairs(Capture.ORDER) do
        if by[g] then out[#out + 1] = { group = g, n = by[g] } end
    end
    return out
end

-- 存：名稱照 Plan.cleanName，空白用預設名稱；回 true, 檔名，或 nil, 原因
function Capture.save(plan, name, fallback)
    name = Plan.cleanName(name)
    if name == "" then name = Plan.cleanName(fallback) end
    plan.name = name
    local file = PlanFile.fileName(name)
    if not file then return nil, "FILE" end
    local ok, why = PlanFile.save(plan, file)
    if not ok then return nil, why end
    return true, file
end

-- ===== 結果框（框架 Window＋Checkbox＋TextField，同一區拆除的確認面板寫法） =====

local Panel = {}
Panel.__index = Panel

local function discard(p)
    if Capture.panel == p then Capture.panel = nil end
    if p and p.win then
        pcall(function()
            p.win:setVisible(false)
            p.win:removeFromUIManager()
        end)
    end
end

-- 一段字照寬度斷行接在 rows 後面（從 y 排起），回下一行的 y
local function para(p, rows, y, text, color)
    local lines = p.UI.Text.wrap(text, p.innerW, p.font)
    for i = 1, #lines do
        rows[#rows + 1] = { s = lines[i], y = y, c = color }
        y = y + p.fh
    end
    return y
end

-- 跟著勾選變的那幾行（收幾片、上限、車庫門、不收的分組），從 p.sumY 排起；回 rows, 下一行的 y
local function summary(p)
    local out, c, rows = p.out, p.c, {}
    local n = tostring(out.plan.n)
    local y = para(p, rows, p.sumY, getText("IGUI_MBLD_Cap_Got", n, tostring(out.kinds)), c.text)
    if out.over > 0 then y = para(p, rows, y, getText("IGUI_MBLD_Cap_Over", n, tostring(out.over)), c.warning) end
    if out.wide > 0 then y = para(p, rows, y, getText("IGUI_MBLD_Cap_Wide", tostring(out.wide)), c.warning) end
    if out.skipped > 0 then
        y = para(p, rows, y, getText("IGUI_MBLD_Cap_Skipped", tostring(out.skipped)), c.textMuted)
        for _, g in ipairs(Capture.groups(out.skip)) do
            y = para(p, rows, y, getText("IGUI_MBLD_ShortCount", getText("IGUI_MBLD_Cap_Skip_" .. g.group), tostring(g.n)),
                c.textMuted)
        end
    end
    return rows, y
end

-- 照摘要的結束位置排：摘要捲動區、名稱、名稱欄、按鈕，視窗跟著變高或變矮（勾少時原本超過上限沒收的片會真的去收，警告與
-- 不收的行可能變多）。放不下時（分割畫面、大字、小解析度）摘要區改成捲動，名稱欄與按鈕一直在視窗裡；名稱欄只挪位置，
-- 打好的名稱與焦點都留著。回視窗高度
local function place(p)
    local y
    p.sum, y = summary(p)
    p.body:setHeight(y)
    local below = GAP + p.nameH + p.fieldH + GAP + p.btnH + PAD
    local view = math.max(p.fh, math.min(y, p.maxH - p.top - below))
    local h = p.top + view + below
    p.box:setHeight(view)
    p.foot:setY(p.top + view + GAP)
    p.field:setY(p.top + view + GAP + p.nameH)
    p.win:setHeight(h)
    p.saveBtn:setY(h - PAD - p.btnH)
    p.cancel:setY(h - PAD - p.btnH)
    return h
end

-- 勾選一變：照勾的層重做藍圖、重排摘要以下；視窗變高超出畫面底就往上挪；一片都沒有時存檔鈕停用
function Panel:refresh()
    self.out = Capture.build(self.out.job, self.fallback, self.on)
    local h = place(self)
    if self.win:getY() + h > self.bottom then self.win:setY(self.bottom - h) end
    self.saveBtn:setEnabled(self.out.plan.n > 0)
end

local function draw(el, rows, font)
    for i = 1, #rows do
        local r = rows[i]
        el:drawText(r.s, PAD, r.y, r.c.r, r.c.g, r.c.b, r.c.a or 1, font)
    end
end

function Panel:save()
    local player = getSpecificPlayer(self.playerNum)
    local ok, why = Capture.save(self.out.plan, self.field:getText(), self.fallback)
    if not ok then
        Messages.toast(player, getText("IGUI_MBLD_Cap_SaveFailed", tostring(why)), getText("IGUI_MBLD_Title"))
        return
    end
    self.win:close()
    Messages.toast(player, getText("IGUI_MBLD_Cap_Saved", self.out.plan.name, tostring(self.out.plan.n)),
        getText("IGUI_MBLD_Title"))
    local L = B.PlanLibrary
    if L and L.open then L.open(self.playerNum) end
end

function Panel.new(UI, playerNum, out, cw, ch, fallback)
    local theme = UI.Theme.create({ variant = "dark" })
    local c = theme.colors
    local font = UIFont.Small
    local tm = getTextManager()
    local fh = tm:getFontHeight(font)
    local s = fh / 16
    local sx, sy = getPlayerScreenLeft(playerNum), getPlayerScreenTop(playerNum)
    local sw, sh = getPlayerScreenWidth(playerNum), getPlayerScreenHeight(playerNum)
    local w = math.min(sw - 40, math.floor(380 * s))
    -- 開頭、勾選框、摘要放在捲動區（右邊留捲軸槽），名稱與名稱欄、按鈕排在它下面
    local box = UI.ScrollPanel.new({ x = 0, y = 0, width = w, height = fh, theme = theme })
    local innerW = box:contentWidth() - PAD
    local self = setmetatable({ UI = UI, playerNum = playerNum, out = out, fallback = fallback, c = c, font = font, fh = fh,
        innerW = innerW, box = box, on = {} }, Panel)
    local rows = {}
    local y = para(self, rows, 0, getText("IGUI_MBLD_Cap_Intro", tostring(cw), tostring(ch), tostring(Capture.LEVELS)),
        c.textMuted) + GAP
    -- 每層讀到幾片；兩層以上有東西才列勾選框，預設全勾（沒東西的層沒有框、一直算勾著，全勾時和沒給 on 一樣）
    local res, per, filled, boxes = out.job.res, {}, 0, {}
    for dz = 0, Capture.LEVELS - 1 do self.on[dz], per[dz] = true, 0 end
    for i = 1, res.n do
        local dz = res.pieces[i].z - out.job.z0
        if per[dz] then per[dz] = per[dz] + 1 end
    end
    for dz = 0, Capture.LEVELS - 1 do
        if per[dz] > 0 then filled = filled + 1 end
    end
    for dz = 0, Capture.LEVELS - 1 do
        if filled > 1 and per[dz] > 0 then
            local box = UI.Checkbox.new({ x = PAD, y = y, width = innerW, theme = theme, font = font, checked = true,
                label = getText("IGUI_MBLD_Count", getText("IGUI_MBLD_PlanFloor", tostring(dz + 1)), tostring(per[dz])),
                target = self, onChange = function(p, checked)
                    p.on[dz] = checked == true
                    p:refresh()
                end })
            boxes[#boxes + 1] = box
            y = y + box.height
        end
    end
    if #boxes > 0 then y = y + GAP end
    self.sumY = y
    self.fieldH, self.btnH, self.maxH, self.bottom = fh + 10, fh + 10, sh - 40, sy + sh - 20
    self.name = {}
    self.nameH = para(self, self.name, 0, getText("IGUI_MBLD_Cap_Name"), c.text)
    local saveTitle = getText("IGUI_MBLD_Cap_Save")
    local saveW = tm:MeasureStringX(font, saveTitle) + 20
    local win = UI.Window.new({ x = 0, y = 0, width = w, height = 100, title = getText("IGUI_MBLD_Cap_Title"),
        theme = theme, opaque = true, onClose = function() discard(self) end })
    win.onEscape = function()
        win:close()
        return true
    end
    self.win = win
    Capture.panel = self
    local top = win:contentTop() + GAP
    self.top = top
    win:setX(sx + math.floor((sw - w) / 2))
    box:setY(top)
    win:addChild(box)
    local body = ISPanel:new(0, 0, box:contentWidth(), 100) -- 先加：畫在勾選框底下；不蓋到捲軸槽（滑鼠先問子元件）
    body:initialise()
    body.background = false
    body.render = function(el)
        draw(el, rows, font)
        draw(el, self.sum, font)
    end
    self.body = body
    box:addChild(body)
    -- 焦點順序照畫面由上而下：各層勾選框、名稱欄、取消、存（框架 Focus 照位置排：方向鍵與手把在控制項之間移動）
    for _, cb in ipairs(boxes) do box:addChild(cb) end
    local foot = ISPanel:new(0, top, w, self.nameH)
    foot:initialise()
    foot.background = false
    foot.render = function(el) draw(el, self.name, font) end
    self.foot = foot
    win:addChild(foot)
    self.field = UI.TextField.new({ x = PAD, y = top, width = w - 2 * PAD, height = self.fieldH, text = out.plan.name,
        maxLength = Plan.MAX_NAME, theme = theme, font = font })
    win:addChild(self.field)
    self.saveBtn = UI.Button.new({ x = w - PAD - saveW, y = 0, width = saveW, height = self.btnH, title = saveTitle,
        style = "primary", theme = theme, font = font, target = self, onClick = function(p) p:save() end })
    self.saveBtn:setEnabled(out.plan.n > 0)
    self.cancel = UI.Button.new({ x = 0, y = 0, height = self.btnH, title = getText("UI_Cancel"), theme = theme, font = font,
        onClick = function() win:close() end })
    self.cancel:setX(self.saveBtn:getX() - GAP - self.cancel.width)
    local h = place(self)
    win:setY(sy + math.floor((sh - h) / 2))
    win:addChild(self.cancel)
    win:addChild(self.saveBtn)
    win:addToUIManager()
    return self
end

-- 掃完：一片都沒收到就只說一聲；有就開結果框（同時只開一個）。框架缺或太舊時只跳通知（UI AGENTS 契約 3：不 error）
function Capture.show(playerNum, out, cw, ch, fallback)
    local player = getSpecificPlayer(playerNum)
    if out.plan.n == 0 then
        Messages.toast(player, getText("IGUI_MBLD_Cap_Empty"), getText("IGUI_MBLD_Title"))
        return false
    end
    local W = B.Window
    local UI = W and W.ui and W.ui({ "window", "controls", "textWrap", "scrollPanel" })
    if UI == nil then
        Messages.toast(player, getText("IGUI_MBLD_NeedFramework"), getText("IGUI_MBLD_Title"))
        return false
    end
    if Capture.panel then Capture.panel.win:close() end
    local ok, p = pcall(Panel.new, UI, playerNum, out, cw, ch, fallback)
    if not ok then
        print(LOG .. "capture panel build failed: " .. tostring(p))
        discard(Capture.panel)
        return false
    end
    Capture.panel = p
    p.win:setVisible(true)
    p.win:bringToTop()
    return true
end

-- ===== 入口 =====

local running -- 正在掃的 { job, playerNum, cw, ch }；一次只掃一區
local function onTick()
    if not running then return end
    local r = running
    local fine, done = pcall(Capture.step, r.job)
    if fine and not done then return end
    running = nil
    Events.OnTick.Remove(onTick)
    if not fine then
        print(LOG .. "capture failed: " .. tostring(done))
        Messages.toast(getSpecificPlayer(r.playerNum), getText("IGUI_MBLD_Cap_Fail"), getText("IGUI_MBLD_Title"))
        return
    end
    local fallback = getText("IGUI_MBLD_Cap_DefaultName", tostring(r.cw), tostring(r.ch))
    local ok, out = pcall(Capture.build, r.job, fallback)
    if not ok then
        print(LOG .. "capture build failed: " .. tostring(out))
        Messages.toast(getSpecificPlayer(r.playerNum), getText("IGUI_MBLD_Cap_Fail"), getText("IGUI_MBLD_Title"))
        return
    end
    Capture.show(r.playerNum, out, r.cw, r.ch, fallback)
end

-- 框完放開：開始分幀掃（任一邊超過 64 格只說一聲；游標本身已夾在 64 格內）
function Capture.release(playerNum, x1, y1, x2, y2, z)
    local job, why = Capture.scan(x1, y1, x2, y2, z)
    if not job then
        Messages.toast(getSpecificPlayer(playerNum), getText("IGUI_MBLD_Cap_TooWide", tostring(Capture.SIDE)),
            getText("IGUI_MBLD_Title"))
        return nil, why
    end
    if not running then Events.OnTick.Add(onTick) end
    running = { job = job, playerNum = playerNum, cw = job.x2 - job.x1 + 1, ch = job.y2 - job.y1 + 1 }
    return job
end

local function label(x1, y1, x2, y2)
    return { cells = {}, lines = {
        getText("IGUI_MBLD_Cap_Label", tostring(math.abs(x2 - x1) + 1), tostring(math.abs(y2 - y1) + 1),
            tostring(Capture.LEVELS)),
        getText("IGUI_MBLD_Cap_HintRelease") .. getText("IGUI_MBLD_HintSep") .. getText("IGUI_MBLD_HintCancel"),
    } }
end

-- 藍圖庫的「框選現成房子」：開長方形游標（每邊最多 64 格），放開掃這一區。手把沒有長方形游標（使用者 2026-11-01
-- 裁定手把不做長方形與一區），只說一聲
function Capture.start(playerNum)
    local Cursor = B.Cursor
    local player = getSpecificPlayer(playerNum)
    if not (Cursor and Cursor.startArea and player) then return nil end
    local o = Cursor.startArea(playerNum, {
        side = Capture.SIDE,
        preview = label,
        outline = label,
        release = function(x1, y1, x2, y2, z) Capture.release(playerNum, x1, y1, x2, y2, z) end,
        cancel = function() end,
    })
    if not o then Messages.toast(player, getText("IGUI_MBLD_Cap_NeedMouse"), getText("IGUI_MBLD_Title")) end
    return o
end

return Capture
