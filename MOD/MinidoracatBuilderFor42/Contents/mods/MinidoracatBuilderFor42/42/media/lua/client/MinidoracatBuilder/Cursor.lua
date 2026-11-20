-- 建造游標：原版 ISBuildingObject 的子類別（server/BuildingObjects/ISBuildingObject.lua），不覆寫原版全域函式，
-- 也不動 DoTileBuilding。引擎每幀照常呼叫：isValid（只給畫面用）→ render → 放開左鍵、或按下手把 A 且可蓋時 tryBuild
-- （ISBuildingObject.lua:97-178）。能不能蓋、扣什麼料一律由伺服器重算（Server.complete）；這裡只是預覽與送請求。
-- 收尾只放在 deactivate：右鍵選單（ISWorldObjectContextMenu.lua:180）、Neat_Building 關面板都會直接 setDrag(nil)，
-- 換游標時引擎呼叫舊游標的 deactivate（IsoCell.java:2558-2575）。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Check"
require "MinidoracatBuilder/Materials"
require "MinidoracatBuilder/Queue"
require "MinidoracatBuilder/Turn"
require "MinidoracatBuilder/Messages"

MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local Cursor = B.Cursor or {}
B.Cursor = Cursor
local Entry, Check, Materials, Queue, Turn, Messages = B.Entry, B.Check, B.Materials, B.Queue, B.Turn, B.Messages

-- 給其他模組在游標的固定時機插手（規劃模式從自己的檔案設欄位，不改這個檔；不要整張換掉，Class 建立時複製了這張表的參照）。
-- 欄位都可以是 nil：valid(cursor) 回 true＝沒有一格可蓋也照樣在放開時呼叫 tryBuild，回 false＝這次不能放（地框變紅）；commit(cursor) 在 tryBuild 算完
-- self.res 之後、送出之前，回 true＝已處理、不送伺服器；label(cursor, src) 在標籤文字（文字、顏色交錯的陣列）組好後，
-- 回新的陣列或 nil；tint(cursor) 回 { r, g, b }（或 { r = , g = , b = }）換掉可蓋格子的地框顏色；layer(cursor) 回數字＝
-- 蓋在滑鼠那格往上幾層（取代 self.up，換層鍵也不處理），nil＝照舊。
-- 掛鉤丟錯時：commit 這次放開取消、不送（掛了就是要接手，落到真的建造會扣料）；這次按住拖曳期間 layer 出過錯也一樣
-- （格子照 self.up 算了，會記到或蓋到別的樓層）；valid 回不能放；其他照沒掛
Cursor.hook = Cursor.hook or {}
local LOG = "[MinidoracatBuilderFor42] "
local hookErr = {} -- 掛鉤名 → 上次的錯誤：每幀呼叫的掛鉤一直錯時 log 只印一次
-- 回 結果, failed（true＝掛了但丟錯）；沒掛回 nil, false
local function hook(name, ...)
    local f = Cursor.hook[name]
    if not f then return nil, false end
    local ok, r = pcall(f, ...)
    if not ok then
        local msg = tostring(r)
        if hookErr[name] ~= msg then
            hookErr[name] = msg
            print(LOG .. "cursor hook " .. name .. " failed: " .. msg)
        end
        return nil, true
    end
    return r, false
end

-- Cursor.onEnd(playerNum)：Window 設定；建造游標離開時（任何原因）呼叫，換成另一個本工具建造游標時不呼叫。
-- 一區拆除模式（Cursor.startArea）不呼叫：它不是從視窗開的。

-- 方法寫在 Cursor，類別第一次用到才 derive：ISBuildingObject 在 server 資料夾，MP 客戶端比 client 晚載入。
local Class, Marks, Panel
-- 能按住拖的種類，與兩邊都 ≥2 格時拉成長方形的畫法（設計稿 builder-batch-1101 claim 2，使用者 2026-11-01 選 ring）：
-- fill＝鋪滿、ring＝沿四邊圍一圈（牆、柵欄佔格邊）、edge＝沿四邊每一格（柱子）。寬或高是 1 時照舊一排、照目前朝向。
-- 配方項目照同一份（Recipes.dragMode）。水面（2026-11-13）照地板鋪滿：一次挖一片池塘
local DRAG = { floor = "fill", roof = "fill", floorOverlay = "fill", water = "fill", wall = "ring", fence = "ring",
    post = "edge" }
Cursor.DRAG = DRAG
-- 能換層的種類（換層鍵預設 PgUp／PgDn，可在按鍵設定改；手把 X）：屋頂預設上一層；地板預設這一層，站在下面也能往上一層鋪（使用者 2026-11-09 選）。
-- 同一排前面可蓋的格子算後面格子的支撐（Cursor.preview 的 planned）
local LAYERED = { roof = true, floor = true }
local SIDE_MAX = 64   -- 拖出的範圍每邊最多離按下那格幾格（MaxCellsPerDrag 上限 64）
local DRAW_MAX = 512  -- ponytail：一次拖曳最多排 512 格（超過 MaxCellsPerDrag 的分批送，Queue.push），量到卡頓再縮
local AREA_SIDE = 40  -- 一區拆除每邊最多幾格（Area 每次預覽掃整區）
local AREA_SETTLE_MS = 200 -- 一區拆除：範圍停住這麼久才算預覽，拖曳中只畫外框
local AREA_MARKS = 128 -- ponytail：一區拆除最多畫幾個警告三角（每個每幀約 6 µs），玩家嫌少再加
local SUMMARY_MS = 1000 -- 材料摘要多久重查一次；一區拆除同時再問一次預覽（Area.preview 世界沒變就不重算）
-- 虛影染色：可蓋白、不能蓋照原版紅（ISBuildingObject.lua:576-580）；多格物件被擋時沒出問題的那幾格地框中性灰
local WHITE, RED, NEUTRAL = { r = 1, g = 1, b = 1 }, { r = 0.65, g = 0.2, b = 0.2 }, { r = 0.6, g = 0.6, b = 0.6 }
local MARK_BAD, MARK_SWAP = 1, 2 -- 格子上的記號（不只靠顏色）：警告三角／替換
local NO_OFFS = { { 0, 0, 0 } }  -- 沒有那一面（NO_FACE）：只畫地框與記號，不畫虛影
local ICON, PAD = 16, 6
-- 指出某一格的拒絕碼：只標那一格；其他碼整個項目的格子都標
local AT_CELL = { BLOCKED = true, NOT_LOADED = true, SAFEHOUSE = true, PERM_DENIED = true, OUTSIDE_SAFEHOUSE = true,
    UNREACHABLE = true, SAME_TILE = true, VEHICLE = true, OCCUPIED = true, STACK_FULL = true, NOT_SURFACE = true,
    NOT_NATURAL = true, NO_UPPER = true, SQUARE_FULL = true, NOT_EMPTY = true, ATTACHED = true }
local SHORT = { NO_MATERIAL = true, NO_TOOL = true }

-- 從按下那格 (ax, ay) 拉到 (ex, ey) 的一排：同一列或同一欄（取位移大的那一軸），最多 max 格。回 { { x, y, z }, ... }
function Cursor.line(ax, ay, az, ex, ey, max)
    local dx, dy = ex - ax, ey - ay
    local sx, sy, n = 0, 0, math.abs(dx)
    if math.abs(dx) >= math.abs(dy) then
        sx = dx > 0 and 1 or -1
    else
        sy, n = dy > 0 and 1 or -1, math.abs(dy)
    end
    local out = {}
    for i = 0, math.min(n + 1, max) - 1 do out[i + 1] = { ax + sx * i, ay + sy * i, az } end
    return out
end

-- 從 (ax, ay) 拉到 (ex, ey) 的長方形（兩邊都 ≥2 格；edge 也接受 1 格寬，一區拆除畫外框用），最多 limit 格。
-- 回 { { x, y, z, side = "n" | "w" | nil }, ... }。fill 從按下那格起蛇形排（走路短；屋頂靠前面可蓋的格子撐著，從有支撐的
-- 那一角拖）。ring 照格邊：北邊＝y1 那排的北邊、南邊＝y2+1 那排的北邊、西邊＝x1 那欄的西邊、東邊＝x2+1 那欄的西邊，
-- 順時針一圈（2W＋2H 條邊）。edge 是範圍最外圈的格子，也順時針。
function Cursor.shape(ax, ay, az, ex, ey, mode, limit)
    local out = {}
    local function add(x, y, ...)
        local side = ...
        if #out < limit then out[#out + 1] = { x, y, az, side = side } end
    end
    local x1, x2, y1, y2 = math.min(ax, ex), math.max(ax, ex), math.min(ay, ey), math.max(ay, ey)
    if mode == "fill" then
        local sx, sy, w = ex >= ax and 1 or -1, ey >= ay and 1 or -1, x2 - x1
        for j = 0, y2 - y1 do
            for i = 0, w do add(ax + sx * (j % 2 == 0 and i or w - i), ay + sy * j) end
        end
    elseif mode == "ring" then
        for x = x1, x2 do add(x, y1, "n") end
        for y = y1, y2 do add(x2 + 1, y, "w") end
        for x = x2, x1, -1 do add(x, y2 + 1, "n") end
        for y = y2, y1, -1 do add(x1, y, "w") end
    else
        for x = x1, x2 do add(x, y1) end
        for y = y1 + 1, y2 do add(x2, y) end
        if y2 > y1 then
            for x = x2 - 1, x1, -1 do add(x, y2) end
        end
        if x2 > x1 then
            for y = y2 - 1, y1 + 1, -1 do add(x1, y) end
        end
    end
    return out
end

-- 圍一圈時北、南兩邊與西、東兩邊各用哪一面（Turn.sides）、項目有的朝向（Turn.faces）：建造視窗的旋轉標記與 E2E 讀
Cursor.sides = Turn.sides
Cursor.faces = Turn.faces

-- 屋頂的鏡像片（2026-11-14 群聊 Patty：「原版材質拉出來都只有一個方向」）：屋頂的兩個坡向是目錄裡的兩項，圖塊屬性沒有
-- 方向，編號排法又每個 tileset 不一樣（同一列 c↔5−c、上下列 c↔5−c、c↔7−c、相鄰兩張、隔一兩列）。所以照這幾種排法
-- 列候選，再比圖：候選的遮罩水平翻過來和自己一樣才算（IsoSprite.isMaskClicked 的 flip，IsoSprite.java:338-360）。
-- 自己左右對稱的（平頂、四角錐）不配。離線用同一個做法量原版 1,987 張屋頂：配到 1,018 張，配錯 6 張。
-- 只在客戶端：伺服器沒有貼圖，所以不是朝向（d），按旋轉鍵是換成那一項重開游標（Cursor.turn）。
local MIRROR_STEP, MIRROR_TOL = 8, 6 -- 每 8 px 取一點；不一樣的點最多 6 個
local mirrorCache = {}
local function maskDiff(spr, flip, ref, w, h)
    local out, n, bad = {}, 0, 0
    for y = MIRROR_STEP / 2, h - 1, MIRROR_STEP do
        for x = MIRROR_STEP / 2, w - 1, MIRROR_STEP do
            n = n + 1
            -- 引擎翻轉時讀的是第「圖寬 − x」欄，比真正的鏡像偏 1 px（IsoSprite.java:351-353），所以翻轉那邊查 x+1。
            -- 不補的話少配約兩成（E2E builder-fb1114-roof1：800 張，離線照引擎算 849、補了 1,018）
            out[n] = spr:isMaskClicked(IsoDirections.N, flip and x + 1 or x, y, flip)
            if ref and out[n] ~= ref[n] then
                bad = bad + 1
                if bad > MIRROR_TOL then return nil end
            end
        end
    end
    return out
end

function Cursor.mirror(entry)
    if entry.kind ~= "roof" then return nil end
    local hit = mirrorCache[entry.name]
    if hit ~= nil then return hit or nil end
    mirrorCache[entry.name] = false
    local tex = entry.spr:getTextureForCurrentFrame(IsoDirections.N)
    if not tex then return nil end
    local w, h = tex:getWidthOrig(), tex:getHeightOrig()
    local own = maskDiff(entry.spr, false, nil, w, h)
    if maskDiff(entry.spr, true, own, w, h) then return nil end -- 左右對稱（沒有遮罩時整張都是 false，也走這裡）
    local n = entry.num
    local row, col = n - n % 8, n % 8
    for _, num in ipairs({ row + 5 - col, row + 8 + 5 - col, row - 8 + 5 - col, row + 7 - col, n % 2 == 0 and n + 1 or n - 1,
        n + 8, n - 8, n + 16, n - 16 }) do
        local other = num >= 0 and num ~= n and Entry.resolve(entry.tileset .. "_" .. num)
        if other and other.kind == "roof" then
            local t = other.spr:getTextureForCurrentFrame(IsoDirections.N)
            if t and t:getWidthOrig() == w and t:getHeightOrig() == h and maskDiff(other.spr, true, own, w, h) then
                mirrorCache[entry.name] = other.name
                return other.name
            end
        end
    end
    return nil
end

-- 起始狀態（Turn.states 的第幾個）：朝向 d 在原處（dx＝dy＝0）的有就用；否則用項目本身那一面（標籤才寫得出朝向），
-- 再不然第一個
function Cursor.pickState(entry, states, d)
    for i = 1, states.n do
        local s = states[i]
        if s.d == d and s.dx == 0 and s.dy == 0 then return i end
    end
    for i = 1, states.n do
        local s = states[i]
        local spr = s.dx == 0 and s.dy == 0 and Entry.face(entry, s.d)
        if spr and spr:getName() == entry.name then return i end
    end
    return 1
end

local cautionBroken = false -- Place.caution 丟過錯：印一次、之後不再問（同 Place.lua 的 basement）

-- 各格的預覽：照順序每格 Check.item（朝向照錨點的第 4 欄，沒有用 d），可蓋的從摘要副本扣掉成本（Materials.take；替換的
-- 格子扣要補的 info.pay 與耗材），所以前面的格子用掉的材料後面的格子拿不到，缺料的格子不扣、放開時跳過。S＝Materials.summary；
-- 副本的 items、uses 讀穿到 S（S 是懶查表，不能用 pairs 複製），扣料只寫進副本。屋頂、地板可以靠同一排前面可蓋的撐著（伺服器
-- 照同一個順序一格一格蓋），所以從有支撐的那一頭拖。walk：Client.build 會先走過去（建造作弊不走），所以距離只照 Server.intent
-- 的範圍（Check.inReach），不看 MaxDistance、不查走不走得到（走到一半停下由送出後的 Queue.tick 提示）。
-- 錨點已帶 code（游標自己判斷的 NO_FACE、配方拖一排的 OVER_MAX）的不跑 Check.item，照那個碼。
-- overlap：疊放模式（Check.item 的 opts.overlap），放開時隨請求送給伺服器。
-- 回 { { a, code, extra, cells, info }, ... }（info 只在可蓋時有）、可蓋格數、缺料格數。
function Cursor.preview(player, name, d, anchors, S, ...)
    local overlap = ...
    local work
    if S then
        work = {}
        for k, v in pairs(S) do work[k] = v end
        work.items = setmetatable({}, { __index = S.items })
        work.uses = setmetatable({}, { __index = S.uses })
    end
    local out, ok, short, planned = {}, 0, 0, {}
    for i, a in ipairs(anchors) do
        local fine, code, extra, info
        if a.code then
            fine, code, extra = true, a.code, a.extra
        else
            fine, code, extra, info = pcall(Check.item, player, name, a[4] or d, a,
                { preview = true, walk = true, summary = work, planned = planned, overlap = overlap })
        end
        if not fine then
            print(LOG .. "preview failed e=" .. tostring(name) .. ": " .. tostring(code))
            code, extra, info = "INTERNAL", nil, nil
        end
        if code == nil then
            ok = ok + 1
            if work and info then
                if info.replace then
                    Materials.take(work, { items = info.pay or {}, uses = info.total and info.total.uses })
                elseif info.total then
                    Materials.take(work, info.total)
                end
            end
            if info and info.entry and LAYERED[info.entry.kind] then
                for _, c in ipairs(info.cells) do planned[B.Place.key(c.x, c.y, c.z)] = true end
            end
            -- 預覽提醒（Place.caution：全高窗的框不合、坡頂出口）只提醒不擋：丟錯時照樣可蓋。不放進 Check.item：
            -- 藍圖檢查與照圖蓋也帶 walk 呼叫它（PlanCheck、Runner），會每片多算一次
            if info and not cautionBroken then
                for _, c in ipairs(info.cells) do
                    if c.sq then
                        local okW, w = pcall(B.Place.caution, info.entry.kind, c.spr, c.sq)
                        if not okW then
                            cautionBroken = true
                            print(LOG .. "caution failed, warnings off: " .. tostring(w))
                            break
                        elseif w then
                            info.warn = w
                            break
                        end
                    end
                end
            end
        elseif SHORT[code] then
            short = short + 1
        end
        out[i] = { a = a, code = code, extra = extra, cells = info and info.cells, info = code == nil and info or nil }
    end
    return out, ok, short
end

-- ---------------------------------------------------------------- 游標物件

-- 每格要畫的東西攤平成陣列（render 每幀只照陣列畫，不配置）：位置、虛影圖（nil＝只畫地框）、高度、虛影染色、地框色、記號
local function newGhosts()
    return { n = 0, x = {}, y = {}, z = {}, spr = {}, yoff = {}, tr = {}, tg = {}, tb = {}, fr = {}, fg = {}, fb = {}, m = {} }
end

local function ghost(g, x, y, z, spr, yoff, tint, floor, ...)
    local mark = ...
    local i = g.n + 1
    g.n = i
    g.x[i], g.y[i], g.z[i], g.spr[i], g.yoff[i], g.m[i] = x, y, z, spr, yoff, mark or 0
    g.tr[i], g.tg[i], g.tb[i] = tint.r, tint.g, tint.b
    g.fr[i], g.fg[i], g.fb[i] = floor.r, floor.g, floor.b
end

-- 原版設定的可蓋／不可蓋地框色（ISBuildIsoEntity.lua:46-68）
local function coreColors()
    local good, bad = getCore():getGoodHighlitedColor(), getCore():getBadHighlitedColor()
    return { r = good:getR(), g = good:getG(), b = good:getB() }, { r = bad:getR(), g = bad:getG(), b = bad:getB() }
end

-- 建造游標與一區拆除游標共用的部分
local function base(player)
    if not Class then
        Class = ISBuildingObject:derive("MinidoracatBuilderCursor")
        for k, v in pairs(Cursor) do Class[k] = v end
    end
    local o = {}
    setmetatable(o, Class)
    Class.__index = Class
    o:init()
    o.character = player
    o.player = player:getPlayerNum()
    o.isYButtonResetCursor = true -- 手把 Y 回到角色位置（ISBuildingObject.lua:633-638）
    o.dragNilAfterPlace = false   -- 蓋完游標留著，可以連續蓋
    o.joypad = JoypadState.players[o.player + 1] ~= nil
    o.sAt = 0
    o.g, o.gn = newGhosts(), 0
    -- 框架深色色票（V1.lua:603-622；warning 是 rev 18 token）。游標只從建造視窗或右鍵選單開，視窗要 rev ≥ 22（Window.ui）
    o.colors = MinidoracatUI.v1.Theme.create({ variant = "dark" }).colors
    return o
end

-- overlap：建造視窗的「疊放」開著（Window.build）；只在這一種能疊、伺服器沒關掉時記下
function Cursor.new(player, entry, d, overlap)
    local o = base(player)
    o.name, o.entry = entry.name, entry
    local P = B.Place
    o.overlap = overlap == true and P.OVERLAP[entry.kind] == true and P.maxPerSquare() > 1 or nil
    o.offsBy = {}
    o.states = Turn.states(entry) -- 按旋轉鍵輪流的朝向與邊（格邊種類四條邊，Turn）
    o:setState(Cursor.pickState(entry, o.states, d))
    -- 欄位不能叫 mirror：實例查不到欄位時會拿到 Cursor.mirror 這個函式，判斷永遠成立（roof1 實踩）
    o.mirrorName = o.states.n == 1 and Cursor.mirror(entry) or nil
    o.canDrag = DRAG[entry.kind] ~= nil and not o.joypad -- 手把只做單格（使用者 10-29、11-01 裁定）
    -- 屋頂預設蓋在上一層：站在下面那層往上蓋。屋頂與地板都能用 PgUp／PgDn、手把 X 切換（LAYERED；isValid 照它換算）
    o.up = entry.kind == "roof"
    -- 一次送幾格（MaxCellsPerDrag）：拖得更多的放開後分批接著送（Queue.push 照同一個沙盒值切）
    o.perBatch = math.max(1, math.floor(tonumber(Entry.settings().MaxCellsPerDrag) or 32))
    -- 車庫門：拖一排決定寬度，整扇是一個錨點帶寬度 w（第 5 欄，Check.item 照它排頭、中段、尾）；手把蓋最短的 2 格。
    -- 雙開門不在 DRAG：點一下放整組四片（Entry.cells）
    local set = entry.kind == "door" and Entry.doorSet(entry.spr)
    o.garage = set and set.garage or nil
    if o.garage then o.canDrag = not o.joypad end
    local key = getCore():getKey(KeybindId.ROTATE_BUILDING)
    o.rotateName = key and key > 0 and getKeyName(key) or nil
    o.sGen = 0
    o.res, o.okN, o.shortN, o.swapN = {}, 0, 0, 0
    return o
end

-- 開始放置：建游標交給引擎。項目已經不能蓋（目錄過期、管理員關了來源）就發通知、不開。
function Cursor.start(playerNum, name, d, ...)
    local overlap = ...
    local player = getSpecificPlayer(playerNum)
    if not player then return nil end
    local entry, code = Entry.resolve(name)
    if not entry then
        Messages.toast(player, Messages.refusal(code))
        return nil
    end
    -- 換項目：舊游標（本工具的，或建造配方開的原版游標，Recipes.cursor）的 deactivate 不通知視窗回來
    local old = Cursor.get(playerNum) or (B.Recipes and B.Recipes.cursor(playerNum))
    if old then old.replaced = true end
    local o = Cursor.new(player, entry, d or 0, overlap)
    getCell():setDrag(o, playerNum)
    local H = B.Hotbar -- 快選列（Hotbar.lua）：開著就換內容，沒開就開
    if H then
        local ok, err = pcall(H.show, playerNum)
        if not ok then print(LOG .. "hotbar failed: " .. tostring(err)) end
    end
    return o
end

-- 一區拆除模式（契約 C7）：拖一個長方形，畫法、按下判斷（介面上按下不算）、右鍵取消、標籤框沿用建造游標。只用滑鼠：
-- 手把玩家回 nil、不開（使用者 2026-11-01 選 no）。z＝玩家那層。cb.preview(x1, y1, x2, y2, z) 回
-- { cells = { { x, y, z, bad }, ... }, lines = { 字串, ... } }：要拆的格子畫紅框，bad 的灰框加警告三角（over＝true 的不加，
-- 見 areaShow），範圍外圈沒東西的格子淡灰；lines 一行一行畫在標籤框，最後一行當按鍵說明（淡色）。cb.outline（選填）同格式，
-- 拖曳中範圍還沒停住時用（areaValid）。放開左鍵：游標先關掉再呼叫 cb.release(x1, y1, x2, y2, z)；
-- 其他原因關掉（右鍵、換了別的游標）呼叫 cb.cancel()。
function Cursor.startArea(playerNum, cb)
    local player = getSpecificPlayer(playerNum)
    if not player or JoypadState.players[playerNum + 1] then return nil end
    local o = base(player)
    o.area, o.canDrag = cb, true
    getCell():setDrag(o, playerNum) -- 舊的建造游標照常 deactivate（視窗回來）
    return o
end

-- 吸管（設計稿 builder-hardcore-sets-1101 claim 3，使用者 2026-11-01 選 button）：一區拆除模式只框一格（滑鼠那格、
-- 換到玩家那層），格子畫可蓋的綠框；cb 同 startArea（preview 回 { cells, lines }，放開左鍵 cb.release(x, y, x, y, z)、
-- 右鍵或換了別的游標 cb.cancel()）。手把回 nil，同 startArea。
function Cursor.startPick(playerNum, cb)
    local o = Cursor.startArea(playerNum, cb)
    if o then o.one = true end
    return o
end

-- 這位玩家目前的本工具游標（別的 MOD 或原版的游標回 nil）
function Cursor.get(playerNum)
    local cell = getCell()
    local drag = cell and cell:getDrag(playerNum)
    if drag and Class and getmetatable(drag) == Class then return drag end
    return nil
end

function Cursor.stop(playerNum)
    if Cursor.get(playerNum) then getCell():setDrag(nil, playerNum) end
end

-- 這一面的佔地（Entry.cells），查過的記著；沒有這一面回 nil
function Cursor:offsOf(d)
    local offs = self.offsBy[d]
    if offs == nil then
        local spr = d and Entry.face(self.entry, d)
        offs = spr and Entry.cells(spr) or false
        self.offsBy[d] = offs
    end
    return offs or nil
end

-- 這個錨點的佔地：車庫門照它帶的寬度 a[5]（Entry.groupCells），其他照朝向（offsOf）；沒有那一面回 nil
function Cursor:offsFor(a)
    local set = a[5] and a[4] and Entry.doorSet(Entry.face(self.entry, a[4]))
    if set then return Entry.groupCells(set, a[5]) end
    return a[4] and self:offsOf(a[4]) or nil
end

-- 車庫門的錨點：拖的那條線只看門的方向那一軸（N 型沿 +x、W 型頭片在 y 最大那格沿 −y，Entry.groupCells），
-- 寬度夾在 2..一次上限（伺服器 Server.intent、Check.item 照同一個範圍驗）
function Cursor:garageAnchor(ax, ay, az, ex, ey)
    local north = Entry.doorSet(self.spr).north
    local lo, hi = ax, ex
    if not north then lo, hi = ay, ey end
    local len = math.min(math.abs(hi - lo) + 1, math.max(2, self.perBatch))
    local w = math.max(2, len)
    if north then return { hi < lo and lo - len + 1 or lo, ay, az, self.d, w } end
    return { ax, hi > lo and lo + len - 1 or lo, az, self.d, w }
end

-- 換到 Turn.states 的第 i 個：朝向 d，錨點移 dx, dy（格邊種類的東邊、南邊蓋在右邊、下面那格）
function Cursor:setState(i)
    local s = self.states[i]
    self.si, self.d, self.dx, self.dy, self.edge = i, s.d, s.dx, s.dy, s.edge
    self.spr = Entry.face(self.entry, s.d)
    self.sprName = self.spr:getName()
    if DRAG[self.entry.kind] == "ring" then self.sides = Cursor.sides(self.entry, s.d) end
end

function Cursor:turn(step)
    local n = self.states.n
    if n > 1 then return self:setState((self.si - 1 + step + n) % n + 1) end
    if self.mirrorName then -- 屋頂：換成鏡像的那一項（Cursor.mirror），蓋在哪一層照舊
        local o = Cursor.start(self.character:getPlayerNum(), self.mirrorName, 0, self.overlap)
        if o then o.up = self.up end
    end
end

-- DoTileBuilding 每幀拿它當目前的 sprite 名稱（ISBuildingObject.lua:129）；原版的四向 sprite 欄位這裡不用
function Cursor:getSprite()
    return self.sprName
end

-- 翻譯寫的是預設鍵名 PgUp／PgDn；玩家改過換層鍵（Window.initBinds 登記）時換成實際的鍵名，沒綁寫「-」
function Cursor.keyText(s)
    local core = getCore()
    local up, down = core:getKey("MinidoracatBuilder_LayerUp"), core:getKey("MinidoracatBuilder_LayerDown")
    if up ~= Keyboard.KEY_PRIOR then s = (s:gsub("PgUp", up > 0 and getKeyName(up) or "-")) end
    if down ~= Keyboard.KEY_NEXT then s = (s:gsub("PgDn", down > 0 and getKeyName(down) or "-")) end
    return s
end

-- R：原版全域按鍵處理只轉 getDrag(0)（ISBuildingObject.lua:592-596），所以只有玩家 0 能用鍵盤轉、換層
function Cursor:rotateKey(key)
    if self.area then return end
    if getCore():isKey(KeybindId.ROTATE_BUILDING, key) then return self:turn(1) end
    if not LAYERED[self.entry.kind] or hook("layer", self) ~= nil then return end -- 規劃的樓層由 PlanMode 自己接換層鍵
    -- isKey 連修飾鍵、替代鍵一起比（Core.java:2405-2408），同 R 那一行
    if getCore():isKey("MinidoracatBuilder_LayerUp", key) then
        self.up = true
    elseif getCore():isKey("MinidoracatBuilder_LayerDown", key) then
        self.up = false
    end
end

-- 按住左鍵時每幀呼叫，x, y 是滑鼠目前那格；self.square 是按下那格（ISBuildingObject.lua:117-139）。
-- 能拖的種類記下拉到哪裡畫一排；其他種類照原版往哪邊拖就轉向哪邊（:599-621），只轉到項目有的朝向。
function Cursor:rotateMouse(x, y)
    -- 在介面上按住不算（見 isValid 的 pressUI）：不擋的話拖過不吃滑鼠的介面會把朝向轉掉
    if self.joypad or not self.square or self.pressUI or self.picking then return end
    if self.canDrag then
        self.lineX, self.lineY = x, y
        return
    end
    local dx, dy = x - self.square:getX(), y - self.square:getY()
    local want
    if math.abs(dx) > math.abs(dy) then
        want = dx < 0 and 4 or 2
    elseif math.abs(dy) > math.abs(dx) then
        want = dy < 0 and 1 or 3
    end
    for i = 1, self.states.n do
        local s = self.states[i]
        if s.d == want and s.dx == 0 and s.dy == 0 and want ~= self.d then self:setState(i) end
    end
end

-- 手把 A（42.22.2）：原版 DoTileBuilding 對手把玩家不再讀建造鍵（ISBuildingObject.lua:114-126），A 只送到拖曳物件的
-- onJoypadPressButton（JoyPadSetup.lua:363-366），原版基底又不處理 A（:627-653；原版只有 ISMoveableCursor 自己接，
-- ISMoveableCursor.lua:1053-1057）。這裡照手把游標現在那一格（xJoypad…）重算可不可蓋、記成 square，再設建造旗標；
-- 下一幀 DoTileBuilding 照 square 那格呼叫 tryBuild（:133-136,171-174）。不沿用上一幀的 square／canBeBuild：方向鍵
-- 連跳和 A 落在同一次手把輪詢時（先跑方向、再掃按鍵，JoyPadSetup.lua:940-963）它們還是剛離開的那一格（審查 1110 Grok）。
-- 那一格還沒建出來（原版下一幀才補）就不蓋。接線游標、配方項目開的原版游標實例共用（Wiring.lua、Recipes.lua）。
-- 42.21 的 DoTileBuilding 還會替手把讀建造鍵，放開 A 時自己蓋（那一版 ISBuildingObject.lua:114-121 的
-- isBuildButtonReleased）；這裡再設旗標會蓋兩次，所以 42.22 以前交回原版。讀碼推論，沒有在 42.21 實測
function Cursor.padBuild(c)
    local v = getCore():getGameVersion()
    if v:getMajor() == 42 and v:getMinor() < 22 then return end
    local sq = c.xJoypad and c.zJoypad and getCell():getGridSquare(c.xJoypad, c.yJoypad, c.zJoypad)
    if not sq then return end
    c.square = sq
    c.canBeBuild = c:isValid(sq, c.north)
    c.build = c.canBeBuild
end

-- 手把：A 蓋；LB／RB 在有的朝向之間轉；X 換層（屋頂）；B 取消、Y 回角色位置照原版（ISBuildingObject.lua:627-653）
function Cursor:onJoypadPressButton(joypadIndex, joypadData, button)
    if button == Joypad.AButton then return Cursor.padBuild(self) end
    if button == Joypad.RBumper then return self:turn(1) end
    if button == Joypad.LBumper then return self:turn(-1) end
    if button == Joypad.XButton and LAYERED[self.entry.kind] then
        self.up = not self.up
        return
    end
    -- 右搖桿按下：手把焦點交給快選列（Hotbar.focus；A 換項目、B 回游標）。游標用掉了 A、B、X、Y、LB、RB，十字鍵移游標
    -- （ISBuildingObject.lua:627-669），拖曳中所有按鍵都先交給游標（JoyPadSetup.lua:363-366）
    if button == Joypad.RStickButton and B.Hotbar then return B.Hotbar.focus(self.player) end
    ISBuildingObject.onJoypadPressButton(self, joypadIndex, joypadData, button)
end

-- 原版按鈕提示列照拖曳物件的 getXPrompt 顯示 X（ISButtonPrompt.lua:1012-1013）
function Cursor:getXPrompt()
    if not (self.entry and LAYERED[self.entry.kind]) then return nil end
    return getText(self.up and "IGUI_MBLD_PadLayerHere" or "IGUI_MBLD_PadLayerUp")
end

function Cursor:getLBPrompt()
    if self.states and (self.states.n > 1 or self.mirrorName) then return getText("IGUI_Controller_RotateLeft") end
    return nil
end

function Cursor:getRBPrompt()
    if self.states and (self.states.n > 1 or self.mirrorName) then return getText("IGUI_Controller_RotateRight") end
    return nil
end
-- getAPrompt 用原版的：canBeBuild（＝isValid）為真才回「建造」（ISBuildingObject.lua:671-676）

-- 滑鼠在任何介面上（原版 ISMoveableCursor.lua:301-323 同寫法；E2E 可換掉）。每幀一次 Java 迴圈，不配置。
-- 游標自己的兩個元件不算（overlay＝警告三角層、tooltip＝跟著滑鼠的標籤框）：只顯示、不收滑鼠（引擎的 isMouseOver
-- 只看範圍，不看 wantMouseEvents）。
function Cursor.mouseOverUI(c)
    local own1 = c and c.overlay and c.overlay.javaObject
    local own2 = c and c.tooltip and c.tooltip.javaObject
    local uis = UIManager.getUI()
    for i = 0, uis:size() - 1 do
        local ui = uis:get(i)
        if ui ~= own1 and ui ~= own2 and ui:isMouseOver() then return true end
    end
    return false
end

-- 吸管鍵（Window.initBinds 登記，預設 Shift+Z）按著。isKeyDown(名稱) 連修飾鍵一起比（LuaManager.java:7052）；
-- 離線測試沒有 isKeyDown
function Cursor.pickHeld()
    return isKeyDown ~= nil and isKeyDown("MinidoracatBuilder_Pick") == true
end

-- 按著吸管鍵：不蓋、不畫虛影，標籤換成吸管說明。按下左鍵點到的物件（onObjectLeftMouseButtonDown 記的 pickObj）等放開
-- 左鍵才換（Window.pickSwap）：按著時就換，新游標接著看到建造鍵按著，放開就蓋下去（ISBuildingObject.lua:114-126）；
-- 放開這一幀 DoTileBuilding 先照上一幀的 canBeBuild（false）設 build，所以舊游標也不蓋
function Cursor:pickValid()
    if not self.picking then
        self.picking = true
        local col = self.colors
        self.src = { getText("IGUI_MBLD_Pick_Label"), col.text, getText("IGUI_MBLD_Pick_Many"), col.text,
            getText("IGUI_MBLD_Pick_HintClick"), col.textMuted }
        self:layout()
    end
    local obj = self.pickObj
    if obj and not self.isLeftDown then
        self.pickObj = nil
        local W = B.Window
        if W and W.pickSwap then W.pickSwap(self.player, obj) end
    end
    return false
end

-- 每幀被引擎呼叫（DoTileBuilding 的 canBeBuild）。只在按下那格、拉到哪格、朝向、玩家站的格子變了，或每秒一次
-- （材料摘要重算的同時；目標格被別人占走、讓開、權限變了，材料都不變）才重算；其餘幀只比數字，不配置。
-- 至少一格能蓋就算可蓋。
-- 滑鼠玩家在介面上按下不算建造。有 onMouseDown 的介面（建造視窗、大部分面板）吃掉按下時，引擎本來就不當建造鍵
-- （UIManager.java:713-721 → Mouse.UIBlockButtonDown，GameKeyboard.isKeyDown 走 isButtonDownUICheck；E2E ui-mp
-- realclick 實測）；不吃滑鼠的介面（提示框、標籤）照樣算按下，放開會蓋在介面底下看不到的格子，這裡補上。
-- 從世界按下、拖過介面的照算（同 ISMoveableCursor）。沒按時滑鼠在介面上也不算可蓋，虛影與提示框收起。
function Cursor:isValid(square)
    if not self.joypad then
        if self.isLeftDown or self.build then
            if self.pressUI == nil then self.pressUI = Cursor.mouseOverUI(self) end
            self.overUI = self.pressUI
        else
            self.pressUI = nil
            self.overUI = Cursor.mouseOverUI(self)
        end
        if self.overUI then return false end
    end
    if not self.isLeftDown and not self.build then self.lineX, self.lineY, self.layerBad = nil, nil, nil end
    if self.area then return self:areaValid(square) end
    if not self.joypad and (self.pickObj or Cursor.pickHeld()) then return self:pickValid() end
    if self.picking then self.picking, self.kgen = nil, nil end -- 放開吸管鍵：下面重算，標籤換回來
    local now = getTimestampMs()
    if now - self.sAt >= SUMMARY_MS then
        self.sAt = now
        self.S = Materials.summary(self.character)
        self.sGen = self.sGen + 1
    end
    local p = self.character
    local ax, ay, az = square:getX(), square:getY(), square:getZ()
    local ex, ey, drag = self.lineX or ax, self.lineY or ay, self.lineX ~= nil
    local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
    -- Cursor.hook.layer(cursor) 回數字＝規劃模式指定的樓層差（蓋在滑鼠那格往上 dz 層），nil＝照 self.up
    local dz, layerBad = hook("layer", self)
    if layerBad then self.layerBad = true end
    if type(dz) ~= "number" then dz = self.up and 1 or 0 end
    if ax ~= self.kx or ay ~= self.ky or az ~= self.kz or ex ~= self.kex or ey ~= self.key or self.si ~= self.kd
        or px ~= self.kpx or py ~= self.kpy or pz ~= self.kpz or self.sGen ~= self.kgen or dz ~= self.kdz
        or drag ~= self.kdrag then -- 開始拖：按鍵說明換成「放開 蓋 N 格」
        self.kx, self.ky, self.kz, self.kex, self.key, self.kd = ax, ay, az, ex, ey, self.si
        self.kpx, self.kpy, self.kpz, self.kgen, self.kdz, self.kdrag = px, py, pz, self.sGen, dz, drag
        -- 上一層：畫面上同一個位置，上一層是 (x+3, y+3)（IsoUtils.XToIso／YToIso 每層加 3 格）
        local u = 3 * dz
        self:refresh(ax + u, ay + u, az + dz, ex + u, ey + u)
    end
    local v, bad = hook("valid", self)
    if bad then return false end
    if v ~= nil then return v == true end
    return self.okN > 0
end

-- 水面：離玩家遠的先挖（Client 的 walkToDig 照這個順序排站位：挖過的不站，還沒挖的可以站）。照格子中心到玩家的距離，
-- 同原版挑站位的算法（AdjacentFreeTileFinder.lua:36-47）。超過一次上限時沒排進去的是離玩家最近的那幾格。
-- 逐筆插入，不用 table.sort（家族規則）；從比較遠的那一頭讀起：拖曳的清單大致照距離排，這樣幾乎不用搬
function Cursor.farFirst(list, px, py)
    local out, key = {}, {}
    local last = #list
    if last == 0 then return out end
    local function dist(a)
        local dx, dy = a[1] + 0.5 - px, a[2] + 0.5 - py
        return dx * dx + dy * dy
    end
    local from, to, step = last, 1, -1
    if dist(list[1]) > dist(list[last]) then from, to, step = 1, last, 1 end
    for n = from, to, step do
        local a = list[n]
        local k, i = dist(a), #out
        while i > 0 and key[i] < k do
            out[i + 1], key[i + 1] = out[i], key[i]
            i = i - 1
        end
        out[i + 1], key[i + 1] = a, k
    end
    return out
end

-- 這次要預覽的錨點 { x, y, z, d }：不能拖的只有按下那格；拖成一直線照目前朝向；兩邊都 ≥2 格照 DRAG 拉長方形
-- （圍一圈時每格的 d 照 self.sides）。照目前朝向的格子移 self.dx, self.dy（Turn 的東邊、南邊）。沒有那一面的格子帶
-- code＝NO_FACE。有 self.max 的（配方拖一排，Recipes.lua）排在上限之後的帶 OVER_MAX（照畫、不送）；圖塊游標不設，
-- 超過的放開後分批送（Queue.push）。
-- 一次挖好幾格水面而玩家站在範圍裡：整片帶 STAND_OUTSIDE、不送。照走路的排法，四周挖完後玩家會被水圍在中間出不來
function Cursor:anchors(ax, ay, az, ex, ey)
    self.mode = nil
    local dx, dy = self.dx or 0, self.dy or 0
    if self.garage then return { self:garageAnchor(ax + dx, ay + dy, az, ex + dx, ey + dy) } end
    if not self.canDrag then return { { ax + dx, ay + dy, az, self.d } } end
    ex = math.max(ax - SIDE_MAX, math.min(ax + SIDE_MAX, ex))
    ey = math.max(ay - SIDE_MAX, math.min(ay + SIDE_MAX, ey))
    local list
    if ax ~= ex and ay ~= ey then
        self.mode, self.shapeW, self.shapeH = DRAG[self.entry.kind], math.abs(ex - ax) + 1, math.abs(ey - ay) + 1
        list = Cursor.shape(ax, ay, az, ex, ey, self.mode, DRAW_MAX)
    else
        list = Cursor.line(ax, ay, az, ex, ey, DRAW_MAX)
    end
    if self.entry.kind == "water" then list = Cursor.farFirst(list, self.character:getX(), self.character:getY()) end
    for i, a in ipairs(list) do
        if a.side then
            a[4] = self.sides[a.side]
        else
            a[1], a[2], a[4] = a[1] + dx, a[2] + dy, self.d
        end
        if a[4] == nil then
            a.code = "NO_FACE"
        elseif self.max and i > self.max then
            a.code, a.extra = "OVER_MAX", { max = self.max }
        end
    end
    if self.entry.kind == "water" and #list > 1 then
        local px, py = math.floor(self.character:getX()), math.floor(self.character:getY())
        if px >= math.min(ax, ex) and px <= math.max(ax, ex) and py >= math.min(ay, ey) and py <= math.max(ay, ey) then
            for _, a in ipairs(list) do a.code, a.extra = "STAND_OUTSIDE", nil end
        end
    end
    return list
end

-- 重算預覽與要畫的東西（只在 isValid 判斷有變時）。每格攤平成陣列，render 只照陣列畫。
-- ponytail：拖曳時每換一格整片重算（最多 DRAW_MAX 次 Check.item）；量到卡頓再改成只算新增的格子。
function Cursor:refresh(ax, ay, az, ex, ey)
    local anchors = self:anchors(ax, ay, az, ex, ey)
    self.res, self.okN, self.shortN = Cursor.preview(self.character, self.name, self.d, anchors, self.S, self.overlap)
    local g, scale, warn = newGhosts(), Core.getTileScale(), self.colors.warning
    local good, bad = coreColors()
    local tint = hook("tint", self) -- 規劃模式換可蓋格子的地框色
    if type(tint) == "table" then good = { r = tint.r or tint[1], g = tint.g or tint[2], b = tint.b or tint[3] } end
    local swapN = 0
    for _, r in ipairs(self.res) do
        local a, code, e = r.a, r.code, r.extra
        local at = code and AT_CELL[code] and e and e.x
        -- 替換格（契約 C7）：黃色虛影與地框＋替換記號，不只靠顏色
        local swap = code == nil and r.info ~= nil and r.info.replace ~= nil
        if swap then swapN = swapN + 1 end
        for j, o in ipairs(self:offsFor(a) or NO_OFFS) do
            local x, y, z = a[1] + o[1], a[2] + o[2], a[3] + o[3]
            local spr = Entry.alternate(o[4], x, y) -- 交替柵欄：畫這一格實際放的那張（Check.item 同一份）
            -- 放在桌上的高度：Check.item 的 info.cells 和 Entry.cells 同順序，yoff 是 Place.check 的第三個回傳值；
            -- 原版虛影同樣乘 tileScale 當 offsetY（ISBuildingObject.lua:564-571）。沒算到那一格的畫在地上。
            local c = r.cells and r.cells[j]
            local yoff = (c and c.yoff or 0) * scale
            if code == nil then
                ghost(g, x, y, z, spr, yoff, swap and warn or WHITE, swap and warn or good, swap and MARK_SWAP)
            elseif not at or (e.x == x and e.y == y and e.z == z) then
                ghost(g, x, y, z, spr, yoff, RED, bad, MARK_BAD)
            else
                ghost(g, x, y, z, spr, yoff, RED, NEUTRAL)
            end
        end
    end
    self.g, self.gn, self.swapN = g, g.n, swapN
    self:texts()
end

-- 疊放的那一格是第幾層：格上原版算桌面的物件（IsTable，ISMoveableSpriteProps.lua:94）數＋1。沒有疊（yoff 都是 0）回 nil
local function stackLevel(r)
    for _, c in ipairs(r.cells or {}) do
        if c.yoff and c.yoff > 0 and c.sq then
            local n, objects = 1, c.sq:getObjects()
            for i = 0, objects:size() - 1 do
                local spr = objects:get(i):getSprite()
                if spr and spr:getProperties():has("IsTable") then n = n + 1 end
            end
            return n
        end
    end
    return nil
end

-- 照疊放放的那一格（Check.item 的 cells[i].over）：放下後是這一格第幾件、最多幾件。不是照疊放放的回 nil
local function overlapLevel(r)
    for _, c in ipairs(r.cells or {}) do
        if c.over and c.sq then return B.Place.occupants(c.sq) + 1, B.Place.maxPerSquare() end
    end
    return nil
end

-- 替換格要補、會退的料加總成一兩行；都空寫「材料相同，不用補料」。建造作弊不扣也不退，不寫。
-- 硬核耗材不在舊的退料表裡，照整份付（Check.item 的 need.uses），寫在要補的那行
function Cursor:swapText()
    if self.swapN == 0 or (self.S and self.S.cheat) then return nil end
    local pay, back, anyPay, anyBack = {}, {}, false, false
    for _, r in ipairs(self.res) do
        local info = r.info
        if info and info.replace then
            for ft, k in pairs(info.pay or {}) do
                pay[ft] = (pay[ft] or 0) + (tonumber(k) or 0)
                anyPay = true
            end
            for key, k in pairs(info.total and info.total.uses or {}) do
                local ft = Materials.USE .. key
                pay[ft] = (pay[ft] or 0) + k
                anyPay = true
            end
            for ft, k in pairs(info.back or {}) do
                back[ft] = (back[ft] or 0) + (tonumber(k) or 0)
                anyBack = true
            end
        end
    end
    if not anyPay and not anyBack then return getText("IGUI_MBLD_SwapSame") end
    local lines = {}
    if anyPay then lines[#lines + 1] = getText("IGUI_MBLD_SwapPay", Messages.items(pay)) end
    if anyBack then lines[#lines + 1] = getText("IGUI_MBLD_SwapBack", Messages.items(back)) end
    return table.concat(lines, "\n")
end

-- 被擋的原因（審查 #6）：一格時照那一格；拖一片時每個原因碼一行、寫幾格（Messages.reasons），缺料的合成一行寫整片還差多少
function Cursor:reasons()
    local res, n, ok = self.res, #self.res, self.okN
    if n == 1 then return res[1].code and Messages.refusal(res[1].code, res[1].extra) end
    if ok == n then return nil end
    local need, tools, toolSeen, counts = {}, {}, {}, {}
    for _, r in ipairs(res) do
        local code = r.code
        if SHORT[code] then
            -- 缺料的格子各自的缺額（照剩下的材料算）加起來＝整片還差多少
            local e = r.extra or {}
            for ft, k in pairs(e.need or {}) do need[ft] = (need[ft] or 0) + k end
            for _, t in ipairs(e.tools or {}) do
                if not toolSeen[t] then
                    toolSeen[t] = true
                    tools[#tools + 1] = t
                end
            end
        elseif code then
            local c = counts[code]
            if c then c.n = c.n + 1 else counts[code] = { n = 1, extra = r.extra } end
        end
    end
    local lines = Messages.reasons(counts)
    if self.shortN > 0 then
        lines[#lines + 1] = getText(self.shortN == 1 and "IGUI_MBLD_DragShortOne" or "IGUI_MBLD_DragShort",
            tostring(self.shortN), Messages.missing(need, tools))
    end
    return table.concat(lines, "\n")
end

-- 標籤（名稱 · 朝向或形狀；拖曳時多一行格數；疊放第幾層；替換的料）、排隊提示、原因、按鍵說明。字串只在這裡組，
-- 全部畫在跟著滑鼠的標籤框（self.src：文字、顏色交錯）。
function Cursor:texts()
    local Names, Sep = B.Names, getText("IGUI_MBLD_Sep")
    -- 配對面是目錄裡的另一項、格邊種類轉到另一條邊時也可能是：標籤寫實際用的那一張的名稱
    local name = (self.d == 5 or self.edge) and self.sprName or self.name
    name = Names and Names.of(name) or name
    if self.mode then
        local key = self.mode == "ring" and "IGUI_MBLD_ShapeRing" or self.mode == "edge" and "IGUI_MBLD_ShapeEdge"
            or "IGUI_MBLD_Size"
        name = name .. Sep .. getText(key, tostring(self.shapeW), tostring(self.shapeH))
    elseif self.edge then
        name = name .. Sep .. getText("IGUI_MBLD_Edge_" .. self.edge)
    elseif self.d ~= 0 and self.d ~= 5 then
        name = name .. Sep .. (Names and Names.face(self.d) or tostring(self.d)) -- 鍵由 Window 定義
    end
    self.label = name
    local res, n, ok, swap = self.res, #self.res, self.okN, self.swapN
    -- 跳過＝被擋＋缺料，數字加得起來（審查 #10）；有替換時新蓋＋替換＋跳過＝全部
    local label2
    if n > 1 and swap > 0 then
        label2 = ok == n and getText("IGUI_MBLD_DragSwap", tostring(n), tostring(ok - swap), tostring(swap))
            or getText("IGUI_MBLD_DragSwapSkip", tostring(n), tostring(ok - swap), tostring(swap), tostring(n - ok))
    elseif n > 1 then
        label2 = ok == n and getText("IGUI_MBLD_DragAll", tostring(n))
            or getText("IGUI_MBLD_DragSummary", tostring(n), tostring(ok), tostring(n - ok))
    elseif swap > 0 then
        local rep = res[1].info.replace
        local spr = rep.obj and rep.obj:getSprite()
        local old = spr and spr:getName() or "?"
        label2 = getText("IGUI_MBLD_SwapOld", Names and Names.of(old, rep.kind) or old)
    end
    self.label2 = label2
    -- 超過一次上限（MaxCellsPerDrag）：放開後分幾批依序送
    local batches = self.perBatch and math.ceil(ok / self.perBatch) or 1
    self.batch = batches > 1 and getText("IGUI_MBLD_Batches", tostring(batches), tostring(self.perBatch)) or nil
    local level = n == 1 and ok == 1 and stackLevel(res[1])
    local over, max = nil, nil
    if n == 1 and ok == 1 then over, max = overlapLevel(res[1]) end
    self.stack = level and getText("IGUI_MBLD_StackLevel", tostring(level))
        or over and getText("IGUI_MBLD_OverlapLevel", tostring(over), tostring(max))
        or self.overlap and getText("IGUI_MBLD_OverlapOn") or nil -- 疊放鍵切換時看得出開著；關掉就不寫
    self.swap = self:swapText()
    -- 前面還有手拖排著、還沒蓋好的：這一排接在後面蓋（使用者 2026-11-16 選 queue=append，改掉 10-29 的「取代前一排」）。
    -- 照圖蓋排著的（Queue 的 owner＝plan、配方的 runCells）放開就取消（Queue.push、Recipes 的 advance），先警告；
    -- 玩家自己拖的配方一排還沒蓋完時，圖塊的請求照舊清掉角色的動作佇列、取代它（Recipes.left），放開前先說
    local ahead, run, cut = 0, 0, 0
    if ok > 0 then
        ahead, run = Queue.left(self.character, "drag"), Queue.left(self.character, "plan")
        local R = B.Recipes
        local row = R and R.row and R.row(self.player)
        local rl = row and R.left(self.player, true) or 0
        if row and row.silent then run = run + rl else cut = rl end
    end
    if run > 0 then
        self.label3, self.label3warn = getText("IGUI_MBLD_PausesRun", tostring(run)), true
    elseif ahead > 0 then
        self.label3, self.label3warn = getText("IGUI_MBLD_Append", tostring(ahead)), false
    else
        self.label3, self.label3warn = cut > 0
            and getText(cut == 1 and "IGUI_MBLD_ReplaceOne" or "IGUI_MBLD_Replace", tostring(cut)) or nil, true
    end
    self.tip = self:reasons()
    local hint
    if not self.joypad then -- 手把用原版按鈕提示（getAPrompt 等）
        local parts = {}
        if ok > 0 and self.canDrag and self.lineX then -- 已經在拖：說放開會蓋幾格、換幾格，不再教拖
            if swap == 0 then
                parts[#parts + 1] = getText(ok == 1 and "IGUI_MBLD_HintReleaseOne" or "IGUI_MBLD_HintRelease", tostring(ok))
            elseif swap == ok then
                parts[#parts + 1] = getText("IGUI_MBLD_HintReleaseSwap", tostring(swap))
            else
                parts[#parts + 1] = getText("IGUI_MBLD_HintReleaseMix", tostring(ok - swap), tostring(swap))
            end
        elseif ok > 0 then
            parts[#parts + 1] = getText(swap > 0 and "IGUI_MBLD_HintSwap" or "IGUI_MBLD_HintBuild")
            if self.canDrag then parts[#parts + 1] = getText("IGUI_MBLD_HintDrag") end
        end
        if (self.states.n > 1 or self.mirrorName) and self.rotateName then
            parts[#parts + 1] = getText("IGUI_MBLD_HintRotate", self.rotateName)
        end
        if LAYERED[self.entry.kind] then
            parts[#parts + 1] = Cursor.keyText(getText(self.up and "IGUI_MBLD_HintLayerHere" or "IGUI_MBLD_HintLayerUp"))
        end
        parts[#parts + 1] = getText("IGUI_MBLD_HintCancel")
        hint = table.concat(parts, getText("IGUI_MBLD_HintSep"))
    end
    self.hint = hint
    local col, src = self.colors, {}
    local function add(t, c)
        if t then
            src[#src + 1] = t
            src[#src + 1] = c
        end
    end
    add(self.label, col.text)
    add(label2, ok < n and col.warning or col.text)
    add(self.batch, col.text)
    add(self.stack, col.text)
    add(self.swap, col.text)
    add(self.label3, self.label3warn and col.warning or col.text)
    -- 預覽提醒（Cursor.preview 的 info.warn）：每種碼寫一次。長句照其他段由 layout 斷行
    local warned = {}
    for _, r in ipairs(res) do
        local w = r.info and r.info.warn
        if w and not warned[w] then
            warned[w] = true
            add(getText("IGUI_MBLD_Warn_" .. w), col.warning)
        end
    end
    add(self.tip, col.text)
    add(hint, col.textMuted)
    local repl = hook("label", self, src)
    if type(repl) == "table" then src = repl end
    self.src = src
    self:layout()
end

-- ---------------------------------------------------------------- 一區拆除模式

-- 一區拆除的 isValid（滑鼠在介面上的判斷已在 isValid 做完）：按下那格到滑鼠那格的長方形，換到玩家那層
-- （畫面同一點，每差一層 x、y 各差 3 格，IsoUtils.XToIso／YToIso），每邊最多 AREA_SIDE 格；吸管（self.one）只框滑鼠那格。
-- 範圍變了：有 cb.outline 的先只畫外框，停住 AREA_SETTLE_MS 才問 cb.preview（40×40 的大基地一次要幾十毫秒，拖曳中每變一格
-- 就算會掉到 10 FPS，temp/area-perf 實測）；沒有 outline 的（吸管）照舊馬上問。範圍沒變時每秒再問一次：Area.preview 照
-- 世界戳記決定要不要重算，沒變回同一份、這裡不重排。放開就算確認，所以一直回 true。
function Cursor:areaValid(square)
    local z = math.floor(self.character:getZ())
    local s = 3 * (z - square:getZ())
    local ax, ay = square:getX() + s, square:getY() + s
    local ex, ey = (self.lineX or square:getX()) + s, (self.lineY or square:getY()) + s
    if self.one then ex, ey = ax, ay end
    local side = self.area.side or AREA_SIDE -- cb.side：框選擷取（Capture）每邊 64；一區拆除不傳
    ex = math.max(ax - side + 1, math.min(ax + side - 1, ex))
    ey = math.max(ay - side + 1, math.min(ay + side - 1, ey))
    local x1, y1, x2, y2 = math.min(ax, ex), math.min(ay, ey), math.max(ax, ex), math.max(ay, ey)
    local now = getTimestampMs()
    if x1 ~= self.kx or y1 ~= self.ky or x2 ~= self.kex or y2 ~= self.key or z ~= self.kz then
        self.kx, self.ky, self.kex, self.key, self.kz, self.kAt = x1, y1, x2, y2, z, now
        self.rect = { x1, y1, x2, y2, z }
        local outline = self.area.outline
        if outline then
            self.settled = false
            local fine, res = pcall(outline, x1, y1, x2, y2, z)
            if not fine then print(LOG .. "area outline failed: " .. tostring(res)) end
            self.areaRes = nil
            self:areaShow(fine and type(res) == "table" and res or {}, x1, y1, x2, y2, z)
            return true
        end
        self.settled = true
        self.sAt = now
        self:areaRefresh(x1, y1, x2, y2, z)
    elseif not self.settled then
        if now - self.kAt >= AREA_SETTLE_MS then
            self.settled, self.sAt = true, now
            self:areaRefresh(x1, y1, x2, y2, z)
        end
    elseif now - self.sAt >= SUMMARY_MS then
        self.sAt = now
        self:areaRefresh(x1, y1, x2, y2, z)
    end
    return true
end

-- 問 cb.preview 並照它重排；拿到和上次同一份（Area.preview 沒重算）就照畫原本的
function Cursor:areaRefresh(x1, y1, x2, y2, z)
    local fine, res = pcall(self.area.preview, x1, y1, x2, y2, z)
    if not fine then print(LOG .. "area preview failed: " .. tostring(res)) end
    if not (fine and type(res) == "table") then res = {} end
    if res == self.areaRes then return end
    self.areaRes = res
    self:areaShow(res, x1, y1, x2, y2, z)
end

-- Area 的 cells 每格接受 { x, y, z, bad } 或 { x = , y = , z = , bad = , over = }：bad＝灰框，bad 而且不是 over（只是超過
-- 一次上限）的加警告三角，最多 AREA_MARKS 個（記號層每幀每個三角都要畫，整區 3,000 多個時一幀 20 ms，temp/area-perf 實測）
function Cursor:areaShow(res, x1, y1, x2, y2, z)
    local g, seen, marks = newGhosts(), {}, 0
    local good, bad = coreColors()
    if self.one then bad = good end -- 吸管：點得下去的格子，不是要拆的
    for _, c in ipairs(res.cells or {}) do
        local x, y, cz, skip = c.x or c[1], c.y or c[2], c.z or c[3], c.bad
        if skip == nil then skip = c[4] end
        seen[B.Place.key(x, y, cz)] = true
        if not skip then
            ghost(g, x, y, cz, nil, 0, WHITE, bad)
        elseif not c.over and marks < AREA_MARKS then
            marks = marks + 1
            ghost(g, x, y, cz, nil, 0, WHITE, NEUTRAL, MARK_BAD)
        else
            ghost(g, x, y, cz, nil, 0, WHITE, NEUTRAL)
        end
    end
    -- 範圍外圈沒東西的格子也畫淡灰，看得出框到哪裡
    for _, a in ipairs(Cursor.shape(x1, y1, z, x2, y2, "edge", DRAW_MAX)) do
        if not seen[B.Place.key(a[1], a[2], z)] then ghost(g, a[1], a[2], z, nil, 0, WHITE, NEUTRAL) end
    end
    self.g, self.gn = g, g.n
    local col, src, lines = self.colors, {}, res.lines or {}
    for i, t in ipairs(lines) do
        src[#src + 1] = tostring(t)
        src[#src + 1] = (i == #lines and i > 1) and col.textMuted or col.text
    end
    self.src = src
    self:layout()
end

-- ---------------------------------------------------------------- 畫面
-- 兩個元件都只顯示、不收滑鼠：wantMouseEvents=false 讓左鍵與移動穿過（ISUIElement.lua:1004），右鍵要明確回 false
-- （UIElement.java:1513-1515；框架 Toast 同做法）。元件不裁切，畫在自己範圍外照樣看得到。
-- 開頭先比 getDrag：已關掉的游標，removeFromUIManager 排隊中這一幀還會畫。

-- 記號層：每個壞格子上一個警告三角、每個替換格上一個替換圖示（框架 UI.Icons 的 reload，rev 2；不只靠顏色），下面墊
-- surface 底，在紅色、黃色虛影上也看得清楚（審查 #11）。缺圖示時退回字：「!」與「~」（框架紅線：get／draw 回 false）。
-- backMost：UIManager 每次 update 把它移到最底層（UIManager.java:560-564），不畫在聊天框、建造視窗等介面上面。
local function marksRender(self)
    local c = self.cursor
    if getCell():getDrag(c.player) ~= c or c.overUI then return end -- 滑鼠在介面上時虛影收起，記號也不畫
    local p, ox, oy, col, UI = c.player, self:getAbsoluteX(), self:getAbsoluteY(), c.colors, self.UI
    local g, warn = c.g, c.colors.warning
    local gx, gy, gz, gm = g.x, g.y, g.z, g.m
    for i = 1, g.n do
        local m = gm[i]
        if m ~= 0 then
            local sx = isoToScreenX(p, gx[i] + 0.5, gy[i] + 0.5, gz[i]) - ox - ICON / 2
            local sy = isoToScreenY(p, gx[i] + 0.5, gy[i] + 0.5, gz[i]) - oy - ICON / 2
            UI.Skin.fill(self, sx - 2, sy - 2, ICON + 4, ICON + 4, col.surface, nil, 1)
            if not UI.Icons.draw(self, m == MARK_SWAP and "reload" or "warning", sx, sy, ICON, warn, 1) then
                self:drawText(m == MARK_SWAP and "~" or "!", sx + 5, sy, warn.r, warn.g, warn.b, 1, UIFont.Medium)
            end
        end
    end
end

-- 標籤框：名稱、拖曳摘要、排隊提示、原因、按鍵說明，跟著滑鼠（手把：游標那一格）。行在 layout 排好，這裡只畫。
-- 位置照原版提示框（滑鼠右下 32, 10，ISToolTip.lua:67-79）；超出玩家畫面就翻到滑鼠另一邊，不蓋住滑鼠。
local function panelRender(self)
    local c = self.cursor
    if getCell():getDrag(c.player) ~= c or not c.lines then return end
    local p, w, h = c.player, self.width, self.height
    local mx, my
    if c.joypad then
        if not c.kx then return end
        mx, my = isoToScreenX(p, c.kx, c.ky, c.kz), isoToScreenY(p, c.kx, c.ky, c.kz)
    else
        mx, my = getMouseX(), getMouseY()
    end
    local left, top = getPlayerScreenLeft(p), getPlayerScreenTop(p)
    local x, y = mx + 32, my + 10
    if x + w > left + getPlayerScreenWidth(p) then x = mx - 16 - w end
    if y + h > top + getPlayerScreenHeight(p) then y = my - 10 - h end
    self:setX(math.max(left, x))
    self:setY(math.max(top, y))
    local col, UI, lines, fh, font = c.colors, self.UI, c.lines, self.fh, self.font
    UI.Skin.fill(self, 0, 0, w, h, col.surface, nil, 1)
    UI.Skin.border(self, 0, 0, w, h, col.border, nil, 1)
    for i = 1, lines.n do
        local l = lines[i]
        self:drawText(l.t, PAD, PAD + (i - 1) * fh, l.c.r, l.c.g, l.c.b, 1, font)
    end
end

local function noClick() return false end

local function newElement(cls, cursor)
    local o = cls:new(0, 0, 1, 1)
    o.wantMouseEvents = false
    o.cursor = cursor
    o.UI = MinidoracatUI.v1
    o.font = UIFont.Small
    o:initialise()
    o:addToUIManager()
    return o
end

-- 第一次 render 才建三角層與標籤框
function Cursor:showUI()
    if self.overlay then return end
    if not Marks then
        Marks = ISUIElement:derive("MinidoracatBuilderCursorMarks")
        Marks.render, Marks.onRightMouseDown, Marks.onRightMouseUp = marksRender, noClick, noClick
        Panel = ISUIElement:derive("MinidoracatBuilderCursorPanel")
        Panel.render, Panel.onRightMouseDown, Panel.onRightMouseUp = panelRender, noClick, noClick
    end
    self.overlay = newElement(Marks, self)
    self.overlay:backMost()
    self.tooltip = newElement(Panel, self)
    self:layout()
end

-- 文字變了才排：self.src（文字、顏色交錯，texts／areaShow 組）每段照框架斷行（Text.wrap，rev 16；視窗要 rev 22 才開）
-- 拆成行、配好色，量出標籤框寬高
function Cursor:layout()
    local o, src = self.tooltip, self.src
    if not (o and src) then return end
    local font, tm = o.font, getTextManager()
    local fh = tm:getFontHeight(font)
    local maxW = fh * 32
    local lines, w = { n = 0 }, 0
    for i = 1, #src, 2 do
        for _, line in ipairs(o.UI.Text.wrap(src[i], maxW, font)) do
            lines.n = lines.n + 1
            lines[lines.n] = { t = line, c = src[i + 1] }
            w = math.max(w, tm:MeasureStringX(font, line))
        end
    end
    self.lines = lines
    o.fh = fh
    -- 右邊多留半個字寬：中文句尾的全形句號量出來比畫出來窄，會畫到框外（介面審查第 8 條）
    o:setWidth(w + PAD * 2 + math.ceil(fh / 2))
    o:setHeight(lines.n * fh + PAD * 2)
    o:setVisible(not self.overUI)
end

function Cursor:hideUI()
    for _, k in ipairs({ "tooltip", "overlay" }) do
        local o = self[k]
        if o then
            o:setVisible(false)
            o:removeFromUIManager()
            self[k] = nil
        end
    end
end

-- 每幀畫虛影：每格各自的 sprite 照 refresh 算好的染色（可蓋白、不能蓋照原版紅、替換黃；ISBuildingObject.lua:576-580、
-- IsoSprite.java:507-516），地框照玩家設定的好／壞色（ISBuildIsoEntity.lua:46-68）、中性灰或黃。沒有 sprite 的格子
-- （NO_FACE、一區拆除）只畫地框。不配置 table／字串。
-- 開頭先比 getDrag：同一幀每個 OnDoTileBuilding2 處理器拿到同一個拖曳物件（IsoCell.java:2612），
-- 已經關掉的游標可能被別的 MOD 再 render 一次，這時收掉自己的 UI 就走。
function Cursor:render(x, y, z, square)
    if getCell():getDrag(self.player) ~= self then return self:hideUI() end
    self:showUI()
    local t = self.tooltip
    if t:getIsVisible() == self.overUI then t:setVisible(not self.overUI) end
    if self.overUI or self.picking then return end
    local floor = self:getFloorCursorSprite()
    local g = self.g
    local gx, gy, gz, gspr, gyoff = g.x, g.y, g.z, g.spr, g.yoff
    for i = 1, g.n do
        local spr = gspr[i]
        if spr then spr:RenderGhostTileColor(gx[i], gy[i], gz[i], 0, gyoff[i], g.tr[i], g.tg[i], g.tb[i], 0.6) end
        floor:RenderGhostTileColor(gx[i], gy[i], gz[i], g.fr[i], g.fg[i], g.fb[i], 0.8)
    end
end

-- 放開左鍵、或按下手把 A，而且至少一格可蓋（ISBuildingObject.lua:171-174）。只送可蓋的格子（含替換格）；缺料、擋住、
-- 沒有那一面的跳過；超過 MaxCellsPerDrag 的由 Queue.push 切成幾筆依序送。覆寫它就不經過原版 ISBuildAction；角色走過去
-- 與排動作在 Client.build（伺服器收下才排）。前面還有排著的就接在後面（Queue）。
-- 送出的每格順便記下各片的虛影（照那一格自己的面，同 refresh 的算法），還沒蓋好前照畫（Queue.draw）。
-- Cursor.hook.commit 回 true＝規劃模式自己收下這次放開，不送。
-- 一區拆除模式：先關游標（deactivate 看 released 不呼叫 cancel），再把範圍交給 cb.release。
function Cursor:tryBuild(x, y, z)
    if self.area then
        local r, cb = self.rect, self.area
        self.released = true
        getCell():setDrag(nil, self.player)
        if r and cb.release then
            local ok, err = pcall(cb.release, r[1], r[2], r[3], r[4], r[5])
            if not ok then print(LOG .. "area release failed: " .. tostring(err)) end
        end
        return
    end
    -- 傳進來的格子和上次算的不一樣就先照它重算。手把按 A 時 padBuild 已經照那一格算過、x／y 會相同；原版只換 x／y，
    -- z 照這一幀的（ISBuildingObject.lua:133-136），按 A 之後換了層就會不同
    if x ~= self.kx or y ~= self.ky or z ~= self.kz then
        local sq = getCell():getGridSquare(x, y, z)
        if not (sq and self:isValid(sq)) then return end
    end
    local done, bad
    if not self.layerBad then done, bad = hook("commit", self) end
    if bad or self.layerBad then -- 掛鉤接手卻出錯：這次不放、不送，說一聲（layer 出過錯就不交給 commit）
        self.lineX, self.lineY, self.kgen, self.layerBad = nil, nil, nil, nil
        Messages.toast(self.character, getText("IGUI_MBLD_CommitFailed"))
        return
    end
    if done == true then
        self.lineX, self.lineY, self.kgen = nil, nil, nil
        return
    end
    local anchors, parts, scale = {}, {}, Core.getTileScale()
    for _, r in ipairs(self.res) do
        if r.code == nil then
            local a, ps = r.a, {}
            for j, o in ipairs(self:offsFor(a)) do
                local c = r.cells and r.cells[j]
                local x, y = a[1] + o[1], a[2] + o[2]
                ps[j] = { x, y, a[3] + o[3], Entry.alternate(o[4], x, y), (c and c.yoff or 0) * scale }
            end
            anchors[#anchors + 1] = { a[1], a[2], a[3], a[4], a[5] } -- a[5]：車庫門的寬度（Client.build 送 w）
            parts[#anchors] = ps
        end
    end
    self.lineX, self.lineY = nil, nil
    if #anchors > 0 then
        Cursor.send(self.character, self.name, anchors, parts, self.overlap)
        self.kgen = nil -- 下一幀重算：標籤馬上寫出「接在前一排後面」
    end
end

-- 放置中點到物件時不讓原版處理（開門、開關燈、拉窗簾）。原版只在拖曳物件有這個方法時才擋
-- （ISObjectClickHandler.lua:315-318），而且是用點號呼叫、第一個參數是被點的物件，不是游標（同 ISMoveableCursor.lua:73）。
-- 吸管記下這個物件：引擎按下左鍵時照圖挑（UIManager.java:584-586），早於放開時的 tryBuild；放開時照它的格子列圖
-- （Window.startPick）。建造游標按著吸管鍵時記在 pickObj（Cursor:pickValid 放開左鍵才換）。滑鼠只有玩家 0 用
function Cursor.onObjectLeftMouseButtonDown(object)
    local c = Cursor.get(0)
    if c and c.one then c.picked = object end
    if c and not c.area and not c.joypad and (c.picking or Cursor.pickHeld()) then c.pickObj = object end
    return true
end

-- 引擎 setDrag 換掉或清掉這個游標時呼叫（IsoCell.java:2563-2567）。一區拆除沒放開就關掉（右鍵、換了別的游標）＝取消。
function Cursor:deactivate()
    self:hideUI()
    if self.area then
        if not self.released and self.area.cancel then
            local ok, err = pcall(self.area.cancel)
            if not ok then print(LOG .. "area cancel failed: " .. tostring(err)) end
        end
        return
    end
    if not self.replaced then
        if B.Hotbar then B.Hotbar.hide() end
        if Cursor.onEnd then
            local ok, err = pcall(Cursor.onEnd, self.player)
            if not ok then print(LOG .. "onEnd failed: " .. tostring(err)) end
        end
    end
end

-- ---------------------------------------------------------------- 送出後（排程、通知、排隊虛影在 Queue.lua）
-- 下面幾個名稱 Recipes.lua、Menu.lua 與 E2E 在用，照舊保留，轉給 Queue。

-- 送一次建造（游標放開時，契約 C4）：交給排程（Queue.push，手拖的），前面有排著的就接在後面。anchors＝{ { x, y, z, d }, ... }
-- （每格自己的朝向 0..5）；parts[i]＝第 i 格各片的虛影 { x, y, z, sprite, yoff }，省略就不畫排隊虛影。overlap＝疊放模式。
-- 回 nonce（排在別筆後面、還沒送出時回組的 id），或 nil, 原因碼。
function Cursor.send(player, name, anchors, ...)
    local parts, overlap = ...
    local id, n = Queue.push(player, name, anchors, parts, overlap)
    if not id then return nil, n end
    return n or id
end

-- 還沒蓋好的格子（排著的與正在蓋的）：{ 各片, ... }，都沒有回 nil（E2E 讀）
function Cursor.queued()
    return Queue.queued()
end

-- 這個角色排著、還沒蓋好的格數（圖塊游標的「接在後面」提示）
function Cursor.left(player)
    return Queue.left(player)
end

-- 這個角色送出會清佇列的請求（配方拖一排、拆除）時會取消幾格：圖塊排著的（Queue）＋配方拖的一排還沒蓋的（Recipes.left）
function Cursor.cancels(player)
    local R = B.Recipes
    return Queue.left(player) + (R and R.left(player:getPlayerNum(), true) or 0)
end

-- 畫已送出、還沒蓋好的格子（Queue.drawParts）；配方項目拖的一排（Recipes.lua）也用
function Cursor.drawParts(parts)
    return Queue.drawParts(parts)
end

-- 右鍵取消放置，不跳原版右鍵選單：原版放開右鍵時，按下與放開點到同一個物件才開選單（ISObjectClickHandler.lua:387-401），
-- 引擎先發 OnRightMouseUp 再發 OnObjectRightMouseButtonUp（UIManager.java:750-756），所以這裡清掉按下時記的物件、自己關
-- 游標（原版是開選單時順便關，ISWorldObjectContextMenu.lua:180）。沒點到物件時原版本來不開選單，現在一樣關游標。
-- 只清原版的欄位，不換原版函式。滑鼠只有玩家 0 用；配方項目開的游標、藍圖的擺放／搬／複製（PlanMode 的拖曳物件）一起
function Cursor.onRightMouseUp()
    local R, PM = B.Recipes, B.PlanMode
    if not (Cursor.get(0) or (R and R.cursor(0)) or (PM and PM.drag and PM.drag(0))) then return end
    if ISObjectClickHandler then ISObjectClickHandler.rdownObject = nil end
    local cell = getCell() -- 沒有世界時（主選單）不取值
    if cell then cell:setDrag(nil, 0) end
end
if not Cursor.rightHooked then
    Cursor.rightHooked = true
    Events.OnRightMouseUp.Add(function() MinidoracatBuilder.Cursor.onRightMouseUp() end)
end

return Cursor
