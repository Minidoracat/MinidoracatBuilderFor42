-- 建造游標：原版 ISBuildingObject 的子類別（server/BuildingObjects/ISBuildingObject.lua），不覆寫原版全域函式，
-- 也不動 DoTileBuilding。引擎每幀照常呼叫：isValid（只給畫面用）→ render → 放開左鍵／手把 A 且可蓋時 tryBuild
-- （ISBuildingObject.lua:97-174）。能不能蓋、扣什麼料一律由伺服器重算（Server.complete）；這裡只是預覽與送請求。
-- 收尾只放在 deactivate：右鍵選單（ISWorldObjectContextMenu.lua:180）、Neat_Building 關面板都會直接 setDrag(nil)，
-- 換游標時引擎呼叫舊游標的 deactivate（IsoCell.java:2558-2575）。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Check"
require "MinidoracatBuilder/Materials"
require "MinidoracatBuilder/Client"
require "MinidoracatBuilder/Messages"

MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local Cursor = B.Cursor or {}
B.Cursor = Cursor
local Entry, Check, Materials, Client, Messages = B.Entry, B.Check, B.Materials, B.Client, B.Messages

-- Cursor.onEnd(playerNum)：Window 設定；建造游標離開時（任何原因）呼叫，換成另一個本工具建造游標時不呼叫。
-- 一區拆除模式（Cursor.startArea）不呼叫：它不是從視窗開的。

-- 方法寫在 Cursor，類別第一次用到才 derive：ISBuildingObject 在 server 資料夾，MP 客戶端比 client 晚載入
-- （PackThrow ThrowCursor.lua 同做法）。
local Class, Marks, Panel
local LOG = "[MinidoracatBuilderFor42] "
-- 能按住拖的種類，與兩邊都 ≥2 格時拉成長方形的畫法（設計稿 builder-batch-1101 claim 2，使用者 2026-11-01 選 ring）：
-- fill＝鋪滿、ring＝沿四邊圍一圈（牆、柵欄佔格邊）、edge＝沿四邊每一格（柱子）。寬或高是 1 時照舊一排、照目前朝向。
local DRAG = { floor = "fill", roof = "fill", floorOverlay = "fill", wall = "ring", fence = "ring", post = "edge" }
local SIDE_MAX = 64   -- 拖出的範圍每邊最多離按下那格幾格（MaxCellsPerDrag 上限 64，再遠的都是 OVER_MAX）
local DRAW_MAX = 512  -- ponytail：一次最多畫 512 格（超過上限的照畫紅），量到卡頓再縮
local AREA_SIDE = 40  -- 一區拆除每邊最多幾格（Area 每次預覽掃整區）
local SUMMARY_MS = 1000 -- 材料摘要多久重查一次；同時整個預覽重算一次（世界變了也看得到）
local ACCEPT_MS = 10000 -- 送出後這麼久沒有 accepted：MP 伺服器限流時不回覆（Server.intent 的 rateOk）
local IDLE_MS = 1500    -- 收下後動作佇列空了這麼久還沒蓋完，算停下（MP 的 placed 比客戶端動作結束晚到）
local QR, QG, QB = 0.45, 0.75, 1 -- 已送出、還沒蓋好的格子外框（藍）；游標預覽用原版的可蓋綠／不可蓋紅，排隊的要分得出來
-- 虛影染色：可蓋白、不能蓋照原版紅（ISBuildingObject.lua:572-576）；多格物件被擋時沒出問題的那幾格地框中性灰
local WHITE, RED, NEUTRAL = { r = 1, g = 1, b = 1 }, { r = 0.65, g = 0.2, b = 0.2 }, { r = 0.6, g = 0.6, b = 0.6 }
local MARK_BAD, MARK_SWAP = 1, 2 -- 格子上的記號（不只靠顏色）：警告三角／替換
local NO_OFFS = { { 0, 0, 0 } }  -- 沒有那一面（NO_FACE）：只畫地框與記號，不畫虛影
local ICON, PAD = 16, 6
-- 指出某一格的拒絕碼：只標那一格；其他碼整個項目的格子都標
local AT_CELL = { BLOCKED = true, NOT_LOADED = true, SAFEHOUSE = true, PERM_DENIED = true, OUTSIDE_SAFEHOUSE = true,
    UNREACHABLE = true, SAME_TILE = true, VEHICLE = true, OCCUPIED = true, STACK_FULL = true, NOT_EMPTY = true,
    ATTACHED = true }
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
    local function add(x, y, side)
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

-- 圍一圈時北、南兩邊與西、東兩邊各用哪一面（主代理 2026-11-01 定案）：目前那面優先，再照 0..4 找只佔北邊／只佔西邊的；
-- 缺的那條邊用 d＝5（配對面：同一個 tileset 裡相反那條邊的圖，Entry.face）。原版北牆、西牆多半是兩個各只有一面的項目
-- （tiledef：walls_exterior_wooden_01 4,5 是西、6,7 是北）。都沒有＝nil，那兩邊標 NO_FACE。回 { n = d, w = d }
function Cursor.sides(entry, cur)
    local out = {}
    for _, d in ipairs({ cur, 0, 1, 2, 3, 4, 5 }) do
        local spr = Entry.face(entry, d)
        if spr then
            local n, w = Entry.edges(entry.kind, spr)
            if n and not w and out.n == nil then out.n = d end
            if w and not n and out.w == nil then out.w = d end
        end
    end
    return out
end

-- 項目有的朝向：1..4（N、E、S、W）裡 Entry.face 有回值、sprite 不重複的；一個都沒有時只有 0（項目本身）
function Cursor.faces(entry)
    local out, seen = { n = 0 }, {}
    for d = 1, 4 do
        local spr = Entry.face(entry, d)
        local name = spr and spr:getName()
        if name and not seen[name] then
            seen[name] = true
            out.n = out.n + 1
            out[out.n] = d
        end
    end
    if out.n == 0 then out.n, out[1] = 1, 0 end
    return out
end

-- 起始朝向：指定的有就用；否則用項目本身那一面（標籤才寫得出朝向），再不然第一個
function Cursor.pickFace(entry, faces, d)
    for i = 1, faces.n do
        if faces[i] == d then return d end
    end
    for i = 1, faces.n do
        local spr = Entry.face(entry, faces[i])
        if spr and spr:getName() == entry.name then return faces[i] end
    end
    return faces[1]
end

-- 在有的朝向之間循環；step＝1 或 −1
function Cursor.nextFace(faces, d, step)
    local n = faces.n
    for i = 1, n do
        if faces[i] == d then return faces[(i - 1 + step + n) % n + 1] end
    end
    return faces[1]
end

-- 各格的預覽：照順序每格 Check.item（朝向照錨點的第 4 欄，沒有用 d），可蓋的從摘要副本扣掉成本（Materials.take；替換的
-- 格子只扣要補的 info.pay），所以前面的格子用掉的材料後面的格子拿不到，缺料的格子不扣、放開時跳過。S＝Materials.summary；
-- 副本的 items 讀穿到 S（S 是懶查表，不能用 pairs 複製），扣料只寫進副本。屋頂可以靠前面可蓋的屋頂撐著（伺服器照同一個
-- 順序一格一格蓋），所以從有支撐的那一頭拖。walk：Client.build 會先走過去（建造作弊不走），所以距離只照 Server.intent
-- 的範圍（Check.inReach），不看 MaxDistance、不查走不走得到（走到一半停下由送出後的 Cursor.tick 提示）。
-- 錨點已帶 code（游標自己判斷的 NO_FACE、OVER_MAX）的不跑 Check.item，照那個碼。
-- 回 { { a, code, extra, cells, info }, ... }（info 只在可蓋時有）、可蓋格數、缺料格數。
function Cursor.preview(player, name, d, anchors, S)
    local work
    if S then
        work = {}
        for k, v in pairs(S) do work[k] = v end
        work.items = setmetatable({}, { __index = S.items })
    end
    local out, ok, short, planned = {}, 0, 0, {}
    for i, a in ipairs(anchors) do
        local fine, code, extra, info
        if a.code then
            fine, code, extra = true, a.code, a.extra
        else
            fine, code, extra, info = pcall(Check.item, player, name, a[4] or d, a,
                { preview = true, walk = true, summary = work, planned = planned })
        end
        if not fine then
            print(LOG .. "preview failed e=" .. tostring(name) .. ": " .. tostring(code))
            code, extra, info = "INTERNAL", nil, nil
        end
        if code == nil then
            ok = ok + 1
            if work and info then
                if info.replace then
                    Materials.take(work, { items = info.pay or {} })
                elseif info.total then
                    Materials.take(work, info.total)
                end
            end
            if info and info.entry and info.entry.kind == "roof" then
                for _, c in ipairs(info.cells) do planned[B.Place.key(c.x, c.y, c.z)] = true end
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

local function ghost(g, x, y, z, spr, yoff, tint, floor, mark)
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
    o.isYButtonResetCursor = true -- 手把 Y 回到角色位置（ISBuildingObject.lua:629-634）
    o.dragNilAfterPlace = false   -- 蓋完游標留著，可以連續蓋
    o.joypad = JoypadState.players[o.player + 1] ~= nil
    o.sAt = 0
    o.g, o.gn = newGhosts(), 0
    -- 框架深色色票（V1.lua:603-622；warning 是 rev 18 token）。游標只從建造視窗或右鍵選單開，視窗要 rev ≥ 22（Window.ui）
    o.colors = MinidoracatUI.v1.Theme.create({ variant = "dark" }).colors
    return o
end

function Cursor.new(player, entry, d)
    local o = base(player)
    o.name, o.entry = entry.name, entry
    o.offsBy = {}
    o.faces = Cursor.faces(entry)
    o:setFace(Cursor.pickFace(entry, o.faces, d))
    o.canDrag = DRAG[entry.kind] ~= nil and not o.joypad -- 手把只做單格（使用者 10-29、11-01 裁定）
    -- 屋頂預設蓋在上一層：站在下面那層往上蓋。PgUp／PgDn、手把 X 切換（isValid 照它換算）
    o.up = entry.kind == "roof"
    o.max = math.max(1, math.floor(tonumber(Entry.settings().MaxCellsPerDrag) or 32))
    local key = getCore():getKey(KeybindId.ROTATE_BUILDING)
    o.rotateName = key and key > 0 and getKeyName(key) or nil
    o.sGen = 0
    o.res, o.okN, o.shortN, o.swapN = {}, 0, 0, 0
    return o
end

-- 開始放置：建游標交給引擎。項目已經不能蓋（目錄過期、管理員關了來源）就發通知、不開。
function Cursor.start(playerNum, name, d)
    local player = getSpecificPlayer(playerNum)
    if not player then return nil end
    local entry, code = Entry.resolve(name)
    if not entry then
        Messages.toast(player, Messages.refusal(code))
        return nil
    end
    local old = Cursor.get(playerNum)
    if old then old.replaced = true end -- 換項目：舊游標的 deactivate 不通知視窗回來
    local o = Cursor.new(player, entry, d or 0)
    getCell():setDrag(o, playerNum)
    return o
end

-- 一區拆除模式（契約 C7）：拖一個長方形，畫法、按下判斷（介面上按下不算）、右鍵取消、標籤框沿用建造游標。只用滑鼠：
-- 手把玩家回 nil、不開（使用者 2026-11-01 選 no）。z＝玩家那層。cb.preview(x1, y1, x2, y2, z) 回
-- { cells = { { x, y, z, bad }, ... }, lines = { 字串, ... } }：要拆的格子畫紅框，bad 的灰框加警告三角，範圍外圈沒東西的
-- 格子淡灰；lines 一行一行畫在標籤框，最後一行當按鍵說明（淡色）。放開左鍵：游標先關掉再呼叫 cb.release(x1, y1, x2, y2, z)；
-- 其他原因關掉（右鍵、換了別的游標）呼叫 cb.cancel()。
function Cursor.startArea(playerNum, cb)
    local player = getSpecificPlayer(playerNum)
    if not player or JoypadState.players[playerNum + 1] then return nil end
    local o = base(player)
    o.area, o.canDrag = cb, true
    getCell():setDrag(o, playerNum) -- 舊的建造游標照常 deactivate（視窗回來）
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

function Cursor:setFace(d)
    self.d = d
    self.spr = Entry.face(self.entry, d)
    self.sprName = self.spr:getName()
    if DRAG[self.entry.kind] == "ring" then self.sides = Cursor.sides(self.entry, d) end
end

function Cursor:turn(step)
    if self.faces.n > 1 then self:setFace(Cursor.nextFace(self.faces, self.d, step)) end
end

-- DoTileBuilding 每幀拿它當目前的 sprite 名稱（ISBuildingObject.lua:125）；原版的四向 sprite 欄位這裡不用
function Cursor:getSprite()
    return self.sprName
end

-- R：原版全域按鍵處理只轉 getDrag(0)（ISBuildingObject.lua:588-592），所以只有玩家 0 能用鍵盤轉、換層
function Cursor:rotateKey(key)
    if self.area then return end
    if getCore():isKey(KeybindId.ROTATE_BUILDING, key) then return self:turn(1) end
    if self.entry.kind ~= "roof" then return end
    if key == Keyboard.KEY_PRIOR then
        self.up = true
    elseif key == Keyboard.KEY_NEXT then
        self.up = false
    end
end

-- 按住左鍵時每幀呼叫，x, y 是滑鼠目前那格；self.square 是按下那格（ISBuildingObject.lua:114-135）。
-- 能拖的種類記下拉到哪裡畫一排；其他種類照原版往哪邊拖就轉向哪邊（:595-617），只轉到項目有的朝向。
function Cursor:rotateMouse(x, y)
    -- 在介面上按住不算（見 isValid 的 pressUI）：不擋的話拖過不吃滑鼠的介面會把朝向轉掉
    if self.joypad or not self.square or self.pressUI then return end
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
    for i = 1, self.faces.n do
        if self.faces[i] == want and want ~= self.d then self:setFace(want) end
    end
end

-- 手把：LB／RB 在有的朝向之間轉；X 換層（屋頂）；B 取消、Y 回角色位置照原版（ISBuildingObject.lua:623-649）。
-- A 由引擎的 isBuildButtonDown 處理（手把是 Interact 鍵，CharacterInputComponent.java:385-391）。
function Cursor:onJoypadPressButton(joypadIndex, joypadData, button)
    if button == Joypad.RBumper then return self:turn(1) end
    if button == Joypad.LBumper then return self:turn(-1) end
    if button == Joypad.XButton and self.entry.kind == "roof" then
        self.up = not self.up
        return
    end
    ISBuildingObject.onJoypadPressButton(self, joypadIndex, joypadData, button)
end

-- 原版按鈕提示列照拖曳物件的 getXPrompt 顯示 X（ISButtonPrompt.lua:1012-1013）
function Cursor:getXPrompt()
    if not (self.entry and self.entry.kind == "roof") then return nil end
    return getText(self.up and "IGUI_MBLD_PadLayerHere" or "IGUI_MBLD_PadLayerUp")
end

function Cursor:getLBPrompt()
    if self.faces and self.faces.n > 1 then return getText("IGUI_Controller_RotateLeft") end
    return nil
end

function Cursor:getRBPrompt()
    if self.faces and self.faces.n > 1 then return getText("IGUI_Controller_RotateRight") end
    return nil
end
-- getAPrompt 用原版的：canBeBuild（＝isValid）為真才回「建造」（ISBuildingObject.lua:667-672）

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

-- 每幀被引擎呼叫（DoTileBuilding 的 canBeBuild）。只在按下那格、拉到哪格、朝向、玩家站的格子變了，或每秒一次
-- （材料摘要重算的同時；目標格被別人占走、讓開、權限變了，材料都不變）才重算；其餘幀只比數字，不配置。
-- 至少一格能蓋就算可蓋。
-- 滑鼠玩家在介面上按下不算建造。有 onMouseDown 的介面（建造視窗、大部分面板）吃掉按下時，引擎本來就不當建造鍵
-- （UIManager.java:716-724 → Mouse.UIBlockButtonDown，GameKeyboard.isKeyDown 走 isButtonDownUICheck；E2E ui-mp
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
    if not self.isLeftDown and not self.build then self.lineX, self.lineY = nil, nil end
    if self.area then return self:areaValid(square) end
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
    if ax ~= self.kx or ay ~= self.ky or az ~= self.kz or ex ~= self.kex or ey ~= self.key or self.d ~= self.kd
        or px ~= self.kpx or py ~= self.kpy or pz ~= self.kpz or self.sGen ~= self.kgen or self.up ~= self.kup
        or drag ~= self.kdrag then -- 開始拖：按鍵說明換成「放開 蓋 N 格」
        self.kx, self.ky, self.kz, self.kex, self.key, self.kd = ax, ay, az, ex, ey, self.d
        self.kpx, self.kpy, self.kpz, self.kgen, self.kup, self.kdrag = px, py, pz, self.sGen, self.up, drag
        -- 上一層：畫面上同一個位置，上一層是 (x+3, y+3)（IsoUtils.XToIso／YToIso 每層加 3 格）
        local u = self.up and 3 or 0
        self:refresh(ax + u, ay + u, az + (self.up and 1 or 0), ex + u, ey + u)
    end
    return self.okN > 0
end

-- 這次要預覽的錨點 { x, y, z, d }：不能拖的只有按下那格；拖成一直線照目前朝向；兩邊都 ≥2 格照 DRAG 拉長方形
-- （圍一圈時每格的 d 照 self.sides）。沒有那一面的格子帶 code＝NO_FACE，排在上限之後的帶 OVER_MAX（照畫、不送）。
function Cursor:anchors(ax, ay, az, ex, ey)
    self.mode = nil
    if not self.canDrag then return { { ax, ay, az, self.d } } end
    ex = math.max(ax - SIDE_MAX, math.min(ax + SIDE_MAX, ex))
    ey = math.max(ay - SIDE_MAX, math.min(ay + SIDE_MAX, ey))
    local list
    if ax ~= ex and ay ~= ey then
        self.mode, self.shapeW, self.shapeH = DRAG[self.entry.kind], math.abs(ex - ax) + 1, math.abs(ey - ay) + 1
        list = Cursor.shape(ax, ay, az, ex, ey, self.mode, DRAW_MAX)
    else
        list = Cursor.line(ax, ay, az, ex, ey, DRAW_MAX)
    end
    for i, a in ipairs(list) do
        if a.side then a[4] = self.sides[a.side] else a[4] = self.d end
        if a[4] == nil then
            a.code = "NO_FACE"
        elseif i > self.max then
            a.code, a.extra = "OVER_MAX", { max = self.max }
        end
    end
    return list
end

-- 重算預覽與要畫的東西（只在 isValid 判斷有變時）。每格攤平成陣列，render 只照陣列畫。
-- ponytail：拖曳時每換一格整片重算（最多 MaxCellsPerDrag 次 Check.item）；量到卡頓再改成只算新增的格子。
function Cursor:refresh(ax, ay, az, ex, ey)
    local anchors = self:anchors(ax, ay, az, ex, ey)
    self.res, self.okN, self.shortN = Cursor.preview(self.character, self.name, self.d, anchors, self.S)
    local g, scale, warn = newGhosts(), Core.getTileScale(), self.colors.warning
    local good, bad = coreColors()
    local swapN = 0
    for _, r in ipairs(self.res) do
        local a, code, e = r.a, r.code, r.extra
        local at = code and AT_CELL[code] and e and e.x
        -- 替換格（契約 C7）：黃色虛影與地框＋替換記號，不只靠顏色
        local swap = code == nil and r.info ~= nil and r.info.replace ~= nil
        if swap then swapN = swapN + 1 end
        for j, o in ipairs(a[4] and self:offsOf(a[4]) or NO_OFFS) do
            local x, y, z = a[1] + o[1], a[2] + o[2], a[3] + o[3]
            -- 放在桌上的高度：Check.item 的 info.cells 和 Entry.cells 同順序，yoff 是 Place.check 的第三個回傳值；
            -- 原版虛影同樣乘 tileScale 當 offsetY（ISBuildingObject.lua:560-567）。沒算到那一格的畫在地上。
            local c = r.cells and r.cells[j]
            local yoff = (c and c.yoff or 0) * scale
            if code == nil then
                ghost(g, x, y, z, o[4], yoff, swap and warn or WHITE, swap and warn or good, swap and MARK_SWAP)
            elseif not at or (e.x == x and e.y == y and e.z == z) then
                ghost(g, x, y, z, o[4], yoff, RED, bad, MARK_BAD)
            else
                ghost(g, x, y, z, o[4], yoff, RED, NEUTRAL)
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

-- 替換格要補、會退的料加總成一兩行；都空寫「材料相同，不用補料」。建造作弊不扣也不退，不寫
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
    local name = Names and Names.of(self.name) or self.name
    if self.mode then
        local key = self.mode == "ring" and "IGUI_MBLD_ShapeRing" or self.mode == "edge" and "IGUI_MBLD_ShapeEdge"
            or "IGUI_MBLD_Size"
        name = name .. Sep .. getText(key, tostring(self.shapeW), tostring(self.shapeH))
    elseif self.d ~= 0 then
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
    local level = n == 1 and ok == 1 and stackLevel(res[1])
    self.stack = level and getText("IGUI_MBLD_StackLevel", tostring(level)) or nil
    self.swap = self:swapText()
    -- 前一筆還有格子在排隊：再放一次，Client.build 會清掉角色的動作佇列（redrag＝replace，使用者 2026-10-29），放開前先說
    local left, q = 0, ok > 0 and Cursor.queued()
    if q then
        for _ in pairs(q) do left = left + 1 end
    end
    self.label3 = left > 0 and getText(left == 1 and "IGUI_MBLD_ReplaceOne" or "IGUI_MBLD_Replace", tostring(left)) or nil
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
        if self.faces.n > 1 and self.rotateName then
            parts[#parts + 1] = getText("IGUI_MBLD_HintRotate", self.rotateName)
        end
        if self.entry.kind == "roof" then
            parts[#parts + 1] = getText(self.up and "IGUI_MBLD_HintLayerHere" or "IGUI_MBLD_HintLayerUp")
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
    add(self.stack, col.text)
    add(self.swap, col.text)
    add(self.label3, col.warning)
    add(self.tip, col.text)
    add(hint, col.textMuted)
    self.src = src
    self:layout()
end

-- ---------------------------------------------------------------- 一區拆除模式

-- 一區拆除的 isValid（滑鼠在介面上的判斷已在 isValid 做完）：按下那格到滑鼠那格的長方形，換到玩家那層
-- （畫面同一點，每差一層 x、y 各差 3 格，IsoUtils.XToIso／YToIso），每邊最多 AREA_SIDE 格。範圍變了或每秒一次重問 Area。
-- 放開就算確認，所以一直回 true。
function Cursor:areaValid(square)
    local z = math.floor(self.character:getZ())
    local s = 3 * (z - square:getZ())
    local ax, ay = square:getX() + s, square:getY() + s
    local ex, ey = (self.lineX or square:getX()) + s, (self.lineY or square:getY()) + s
    ex = math.max(ax - AREA_SIDE + 1, math.min(ax + AREA_SIDE - 1, ex))
    ey = math.max(ay - AREA_SIDE + 1, math.min(ay + AREA_SIDE - 1, ey))
    local x1, y1, x2, y2 = math.min(ax, ex), math.min(ay, ey), math.max(ax, ex), math.max(ay, ey)
    local now = getTimestampMs()
    if x1 ~= self.kx or y1 ~= self.ky or x2 ~= self.kex or y2 ~= self.key or z ~= self.kz or now - self.sAt >= SUMMARY_MS then
        self.sAt, self.kx, self.ky, self.kex, self.key, self.kz = now, x1, y1, x2, y2, z
        self.rect = { x1, y1, x2, y2, z }
        self:areaRefresh(x1, y1, x2, y2, z)
    end
    return true
end

-- Area 的 cells 每格接受 { x, y, z, bad } 或 { x = , y = , z = , bad = }
function Cursor:areaRefresh(x1, y1, x2, y2, z)
    local fine, res = pcall(self.area.preview, x1, y1, x2, y2, z)
    if not fine then print(LOG .. "area preview failed: " .. tostring(res)) end
    if not (fine and type(res) == "table") then res = {} end
    local g, seen = newGhosts(), {}
    local _, bad = coreColors()
    for _, c in ipairs(res.cells or {}) do
        local x, y, cz, skip = c.x or c[1], c.y or c[2], c.z or c[3], c.bad
        if skip == nil then skip = c[4] end
        seen[B.Place.key(x, y, cz)] = true
        if skip then ghost(g, x, y, cz, nil, 0, WHITE, NEUTRAL, MARK_BAD) else ghost(g, x, y, cz, nil, 0, WHITE, bad) end
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
-- backMost：UIManager 每次 update 把它移到最底層（UIManager.java:563-567），不畫在聊天框、建造視窗等介面上面。
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

-- 文字變了才排：self.src（文字、顏色交錯，texts／areaRefresh 組）每段照框架斷行（Text.wrap，rev 16；視窗要 rev 22 才開）
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
    o:setWidth(w + PAD * 2)
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

-- 每幀畫虛影：每格各自的 sprite 照 refresh 算好的染色（可蓋白、不能蓋照原版紅、替換黃；ISBuildingObject.lua:572-576、
-- IsoSprite.java:507-516），地框照玩家設定的好／壞色（ISBuildIsoEntity.lua:46-68）、中性灰或黃。沒有 sprite 的格子
-- （NO_FACE、一區拆除）只畫地框。不配置 table／字串。
-- 開頭先比 getDrag：同一幀每個 OnDoTileBuilding2 處理器拿到同一個拖曳物件（IsoCell.java:2612），
-- 已經關掉的游標可能被別的 MOD 再 render 一次，這時收掉自己的 UI 就走。
function Cursor:render(x, y, z, square)
    if getCell():getDrag(self.player) ~= self then return self:hideUI() end
    self:showUI()
    local t = self.tooltip
    if t:getIsVisible() == self.overUI then t:setVisible(not self.overUI) end
    if self.overUI then return end
    local floor = self:getFloorCursorSprite()
    local g = self.g
    local gx, gy, gz, gspr, gyoff = g.x, g.y, g.z, g.spr, g.yoff
    for i = 1, g.n do
        local spr = gspr[i]
        if spr then spr:RenderGhostTileColor(gx[i], gy[i], gz[i], 0, gyoff[i], g.tr[i], g.tg[i], g.tb[i], 0.6) end
        floor:RenderGhostTileColor(gx[i], gy[i], gz[i], g.fr[i], g.fg[i], g.fb[i], 0.8)
    end
end

-- 放開左鍵／手把 A，而且至少一格可蓋（DoTileBuilding:167-170）。只送可蓋的格子（含替換格）；缺料、擋住、
-- 沒有那一面、超過上限的跳過。覆寫它就不經過原版 ISBuildAction；角色走過去與排動作在 Client.build（伺服器收下才排）。
-- 送出的每格順便記下各片的虛影（照那一格自己的面，同 refresh 的算法），還沒蓋好前照畫（Cursor.drawQueued）。
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
    if x ~= self.kx or y ~= self.ky or z ~= self.kz then -- 手把同一幀移了游標：先照那一格重算
        local sq = getCell():getGridSquare(x, y, z)
        if not (sq and self:isValid(sq)) then return end
    end
    local anchors, parts, scale = {}, {}, Core.getTileScale()
    for _, r in ipairs(self.res) do
        if r.code == nil then
            local a, ps = r.a, {}
            for j, o in ipairs(self:offsOf(a[4])) do
                local c = r.cells and r.cells[j]
                ps[j] = { a[1] + o[1], a[2] + o[2], a[3] + o[3], o[4], (c and c.yoff or 0) * scale }
            end
            anchors[#anchors + 1] = { a[1], a[2], a[3], a[4] }
            parts[#anchors] = ps
        end
    end
    self.lineX, self.lineY = nil, nil
    if #anchors > 0 then
        Cursor.send(self.character, self.name, anchors, parts)
        self.kgen = nil -- 下一幀重算：標籤馬上寫出「再放一次會取消剛送出的 N 格」
    end
end

-- 放置中點到物件時不讓原版處理（開門、開關燈、拉窗簾）。原版只在拖曳物件有這個方法時才擋
-- （ISObjectClickHandler.lua:341-344），而且是用點號呼叫、第一個參數是被點的物件，不是游標（同 ISMoveableCursor.lua:73）
function Cursor.onObjectLeftMouseButtonDown()
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
    if not self.replaced and Cursor.onEnd then
        local ok, err = pcall(Cursor.onEnd, self.player)
        if not ok then print(LOG .. "onEnd failed: " .. tostring(err)) end
    end
end

-- ---------------------------------------------------------------- 送出後：被拒與停下的通知

-- 目前等結果的請求：{ player, n, count, placed, accepted, at, idleAt, parts }。每人只留一個請求（Client.build 會清佇列），
-- 所以只追最近一筆。游標關掉後照樣追，通知照發。watch 清掉（蓋完、被拒、停下、換了別的請求）時排隊虛影一起收。
local watch

-- title 省略＝「無法建造」（Messages.toast）
local function tell(player, code, extra, title)
    if code == "PERM_DENIED" then return end -- Safehouse 拒絕時自己推了通知，不再疊一則
    Messages.toast(player, Messages.refusal(code, extra), title)
end

-- 送一次建造（游標放開時，契約 C4）。anchors＝{ { x, y, z, d }, ... }（每格自己的朝向 0..5）；parts[i]＝第 i 格各片的虛影
-- { x, y, z, sprite, yoff }，省略就不畫排隊虛影。回 nonce，或 nil, 原因碼。
function Cursor.send(player, name, anchors, parts)
    local w = { player = player, count = #anchors, placed = 0, at = getTimestampMs(), parts = parts }
    watch = w
    local n, code = Client.build(player, name, anchors)
    if not n then
        if watch == w then watch = nil end
        if not w.told then tell(player, code) end -- 單機的 intent 當場被拒時 onResult 已經通知過
        return nil, code
    end
    w.n = n
    return n
end

-- 還沒蓋好的格子：{ [i] = 各片 }，沒有在等的請求回 nil（E2E 讀）
function Cursor.queued()
    return watch and watch.parts
end

-- Client.onServerCommand 收進 results 後呼叫。單機的 intent 在 Client.build 回傳前就答覆，那時 nonce 只在 Client.pending。
function Cursor.onResult(cmd, args)
    local w = watch
    if not w then return end
    local n = w.n or (Client.pending and Client.pending.n)
    if args.n ~= n then return end
    if cmd ~= "accepted" then
        local c = Cursor.get(w.player:getPlayerNum())
        if c then c.kgen = nil end -- 剛蓋好或被拒：下一幀重算預覽，不等每秒那一次
    end
    if cmd == "accepted" then
        w.accepted = true
    elseif cmd == "placed" then
        w.placed = w.placed + 1
        if w.parts and args.i then w.parts[args.i] = nil end
        if w.placed >= w.count then watch = nil end
    elseif cmd == "refused" then
        -- 被拒就停整串：MP 的 Reject 與 Client 都清掉了後面的動作
        w.told = true
        watch = nil
        tell(w.player, args.code, args)
    end
end
Client.onResult = Cursor.onResult

-- 每 tick：沒有在等的請求就直接回。收下後佇列空了一陣子還沒蓋完＝停下了，提示一次。佇列空了分不出是玩家自己走開、
-- 按 ESC，還是路徑走不通（動作停下一律 resetQueue，不留原因：ISBaseTimedAction.lua:63-64），所以只有排隊時就知道的
-- 「旁邊沒空位」（Client.lua 的 queue 記在 noRoom）另外說；其他照實說蓋好幾格。材料是一格一格在 Server.complete 扣的
-- （Place.build 成功後才 Materials.consume，Server.lua:241-251），停下時沒蓋的格子沒有扣。
function Cursor.tick()
    local w = watch
    if not w or not w.n then return end
    if not Client.pending or Client.pending.n ~= w.n then -- 有別的請求取代了它
        watch = nil
        return
    end
    local now = getTimestampMs()
    if not w.accepted then
        if now - w.at > ACCEPT_MS then
            watch = nil
            tell(w.player, "RATE_LIMITED")
        end
        return
    end
    if ISTimedActionQueue.isPlayerDoingAction(w.player) then
        w.idleAt = nil
        return
    end
    w.idleAt = w.idleAt or now
    if now - w.idleAt < IDLE_MS then return end
    watch = nil
    if w.placed >= w.count then return end
    local stuck, title = Client.pending.noRoom, w.placed > 0 and getText("IGUI_MBLD_Interrupted") or nil
    if stuck and w.placed + 1 >= stuck then -- 前面的都蓋好了，停在旁邊沒空位的那一格
        tell(w.player, "NO_ROOM", { i = stuck, n = w.count }, title)
    elseif w.placed > 0 then
        Messages.toast(w.player, getText("IGUI_MBLD_Stopped", tostring(w.placed), tostring(w.count)), title)
    else
        tell(w.player, "WALK")
    end
end
Events.OnTick.Add(Cursor.tick)

-- 已送出、還沒蓋好的格子（使用者 2026-10-29：還沒蓋完前要顯示預計要蓋的格子）：淡虛影＋藍框，蓋好一格收一格。
-- 游標關掉後角色照樣在蓋，所以不畫在游標的 render，改在世界畫完時畫（OnPostRender，IngameState.java:1198-1201）：
-- 游標虛影也是在同一處、世界的 cell 畫完後才畫（FBORenderCell.java:319 的 DoBuilding），所以一樣畫在世界最上層。
-- 不能用 OnPostFloorLayerDraw：它只在舊渲染器（IsoCell.java:856-860）觸發，B42 預設的 FBO 渲染器沒有
-- （builder-ui-1029a 截圖一格都沒畫出來）。
-- 各片的 sprite 是 tryBuild 照那一格自己的面記的（圍一圈時北、西兩種邊各畫各的）。
function Cursor.drawQueued()
    local w = watch
    local parts = w and w.parts
    if not parts then return end
    local floor = ISBuildingObject.getFloorCursorSprite() -- 不用 self（ISBuildingObject.lua:693-700）
    for _, ps in pairs(parts) do
        for _, g in ipairs(ps) do
            g[4]:RenderGhostTileColor(g[1], g[2], g[3], 0, g[5], 1, 1, 1, 0.35)
            floor:RenderGhostTileColor(g[1], g[2], g[3], QR, QG, QB, 0.8)
        end
    end
end
Events.OnPostRender.Add(Cursor.drawQueued)

return Cursor
