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

-- Cursor.onEnd(playerNum)：Window 設定；游標離開時（任何原因）呼叫，換成另一個本工具游標時不呼叫。

-- 方法寫在 Cursor，類別第一次用到才 derive：ISBuildingObject 在 server 資料夾，MP 客戶端比 client 晚載入
-- （PackThrow ThrowCursor.lua 同做法）。
local Class, Overlay
local LOG = "[MinidoracatBuilderFor42] "
local DRAG = { floor = true, wall = true, fence = true, roof = true } -- 能按住拖一排的種類（第三、四階段的決定）
local SUMMARY_MS = 1000 -- 材料摘要多久重查一次；同時整個預覽重算一次（世界變了也看得到）
local ACCEPT_MS = 10000 -- 送出後這麼久沒有 accepted：MP 伺服器限流時不回覆（Server.intent 的 rateOk）
local IDLE_MS = 1500    -- 收下後動作佇列空了這麼久還沒蓋完，算走不到（MP 的 placed 比客戶端動作結束晚到）
local ICON, PAD, BOTTOM = 16, 6, 200
-- 指出某一格的拒絕碼：只標那一格；其他碼整個項目的格子都標
local AT_CELL = { BLOCKED = true, NOT_LOADED = true, SAFEHOUSE = true, PERM_DENIED = true, OUTSIDE_SAFEHOUSE = true,
    UNREACHABLE = true }
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

-- 一排各格的預覽：照順序每格 Check.item，可蓋的從摘要副本扣掉成本（Materials.take），所以前面的格子用掉的材料
-- 後面的格子拿不到，缺料的格子不扣、放開時跳過。S＝Materials.summary；副本的 items 讀穿到 S（S 是懶查表，
-- 不能用 pairs 複製），扣料只寫進副本。walk：Client.build 會先走過去，所以距離只照 Server.intent 的範圍，
-- 不看 MaxDistance、不查走不走得到（走不到由送出後的 Cursor.tick 提示）。回 { { a, code, extra }, ... }、可蓋格數、缺料格數。
function Cursor.preview(player, name, d, anchors, S)
    local work
    if S then
        work = {}
        for k, v in pairs(S) do work[k] = v end
        work.items = setmetatable({}, { __index = S.items })
    end
    local out, ok, short = {}, 0, 0
    for i, a in ipairs(anchors) do
        local fine, code, extra, info = pcall(Check.item, player, name, d, a,
            { preview = true, walk = true, summary = work })
        if not fine then
            print(LOG .. "preview failed e=" .. tostring(name) .. ": " .. tostring(code))
            code, extra, info = "INTERNAL", nil, nil
        end
        if code == nil then
            ok = ok + 1
            if work and info and info.total then Materials.take(work, info.total) end
        elseif SHORT[code] then
            short = short + 1
        end
        out[i] = { a = a, code = code, extra = extra, cells = info and info.cells }
    end
    return out, ok, short
end

-- ---------------------------------------------------------------- 游標物件

function Cursor.new(player, entry, d)
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
    o.name, o.entry = entry.name, entry
    o.faces = Cursor.faces(entry)
    o:setFace(Cursor.pickFace(entry, o.faces, d))
    o.canDrag = DRAG[entry.kind] == true and not o.joypad -- 手把只做單格
    -- 屋頂預設蓋在上一層：站在下面那層往上蓋。PgUp／PgDn、手把 X 切換（isValid 照它換算）
    o.up = entry.kind == "roof"
    o.max = math.max(1, math.floor(tonumber(Entry.settings().MaxCellsPerDrag) or 32))
    local key = getCore():getKey(KeybindId.ROTATE_BUILDING)
    o.rotateName = key and key > 0 and getKeyName(key) or nil
    o.sAt, o.sGen = 0, 0
    o.res, o.okN, o.shortN, o.gn = {}, 0, 0, 0
    o.warn = { r = 1, g = 0.55, b = 0.2, a = 1 } -- 框架 warning 色（深色 #FF8C33），警告三角用
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

function Cursor:setFace(d)
    self.d = d
    self.spr = Entry.face(self.entry, d)
    self.sprName = self.spr:getName()
    self.offs = Entry.cells(self.spr)
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
    if self.entry.kind ~= "roof" then return nil end
    return getText(self.up and "IGUI_MBLD_PadLayerHere" or "IGUI_MBLD_PadLayerUp")
end

function Cursor:getLBPrompt()
    if self.faces.n > 1 then return getText("IGUI_Controller_RotateLeft") end
    return nil
end

function Cursor:getRBPrompt()
    if self.faces.n > 1 then return getText("IGUI_Controller_RotateRight") end
    return nil
end
-- getAPrompt 用原版的：canBeBuild（＝isValid）為真才回「建造」（ISBuildingObject.lua:667-672）

-- 滑鼠在任何介面上（原版 ISMoveableCursor.lua:301-323 同寫法；E2E 可換掉）。每幀一次 Java 迴圈，不配置。
-- 游標自己的標籤面板與提示框不算：只顯示、不收滑鼠（引擎的 isMouseOver 只看範圍，不看 wantMouseEvents）。
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
    local now = getTimestampMs()
    if now - self.sAt >= SUMMARY_MS then
        self.sAt = now
        self.S = Materials.summary(self.character)
        self.sGen = self.sGen + 1
    end
    local p = self.character
    local ax, ay, az = square:getX(), square:getY(), square:getZ()
    local ex, ey = self.lineX or ax, self.lineY or ay
    local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
    if ax ~= self.kx or ay ~= self.ky or az ~= self.kz or ex ~= self.kex or ey ~= self.key or self.d ~= self.kd
        or px ~= self.kpx or py ~= self.kpy or pz ~= self.kpz or self.sGen ~= self.kgen or self.up ~= self.kup then
        self.kx, self.ky, self.kz, self.kex, self.key, self.kd = ax, ay, az, ex, ey, self.d
        self.kpx, self.kpy, self.kpz, self.kgen, self.kup = px, py, pz, self.sGen, self.up
        -- 上一層：畫面上同一個位置，上一層是 (x+3, y+3)（IsoUtils.XToIso／YToIso 每層加 3 格）
        local u = self.up and 3 or 0
        self:refresh(ax + u, ay + u, az + (self.up and 1 or 0), ex + u, ey + u)
    end
    return self.okN > 0
end

-- 重算預覽與要畫的東西（只在 isValid 判斷有變時）。每格攤平成陣列，render 只照陣列畫。
-- ponytail：拖曳時每換一格整排重算（最多 MaxCellsPerDrag 次 Check.item）；量到卡頓再改成只算新增的格子。
function Cursor:refresh(ax, ay, az, ex, ey)
    local anchors = self.canDrag and Cursor.line(ax, ay, az, ex, ey, self.max) or { { ax, ay, az } }
    self.res, self.okN, self.shortN = Cursor.preview(self.character, self.name, self.d, anchors, self.S)
    local gx, gy, gz, gspr, gbad, gred, gyoff, gn = {}, {}, {}, {}, {}, {}, {}, 0
    local scale = Core.getTileScale()
    for _, r in ipairs(self.res) do
        local a, code, e = r.a, r.code, r.extra
        local at = code and AT_CELL[code] and e and e.x
        for j, o in ipairs(self.offs) do
            gn = gn + 1
            local x, y, z = a[1] + o[1], a[2] + o[2], a[3] + o[3]
            gx[gn], gy[gn], gz[gn], gspr[gn] = x, y, z, o[4]
            -- 放在桌上的高度：Check.item 的 info.cells 和 Entry.cells 同順序，yoff 是 Place.check 的第三個回傳值；
            -- 原版虛影同樣乘 tileScale 當 offsetY（ISBuildingObject.lua:560-567）。沒算到那一格的畫在地上。
            local c = r.cells and r.cells[j]
            gyoff[gn] = (c and c.yoff or 0) * scale
            gred[gn] = code ~= nil
            gbad[gn] = code ~= nil and (not at or (e.x == x and e.y == y and e.z == z))
        end
    end
    self.gx, self.gy, self.gz, self.gspr, self.gbad, self.gred, self.gyoff, self.gn = gx, gy, gz, gspr, gbad, gred, gyoff, gn
    local good, bad = getCore():getGoodHighlitedColor(), getCore():getBadHighlitedColor()
    self.goodR, self.goodG, self.goodB = good:getR(), good:getG(), good:getB()
    self.badR, self.badG, self.badB = bad:getR(), bad:getG(), bad:getB()
    self:texts()
end

-- 標籤（名稱 · 朝向；拖曳時多一行格數）、按鍵說明、提示框的原因。字串只在這裡組。
function Cursor:texts()
    local Names = B.Names
    local name = Names and Names.of(self.name) or self.name
    if self.d ~= 0 then
        name = name .. getText("IGUI_MBLD_Sep") .. (Names and Names.face(self.d) or tostring(self.d)) -- 鍵由 Window 定義
    end
    self.label = name
    local res, n = self.res, #self.res
    self.label2 = n > 1 and getText("IGUI_MBLD_DragSummary", tostring(n), tostring(self.okN), tostring(self.shortN))
        or nil
    local tip
    if n == 1 then
        tip = res[1].code and Messages.refusal(res[1].code, res[1].extra)
    elseif n > 1 and self.okN < n then
        -- 缺料的格子各自的缺額（照剩下的材料算）加起來＝整排還差多少
        local need, tools, toolSeen, other = {}, {}, {}, nil
        for _, r in ipairs(res) do
            if SHORT[r.code] then
                local e = r.extra or {}
                for ft, k in pairs(e.need or {}) do need[ft] = (need[ft] or 0) + k end
                for _, t in ipairs(e.tools or {}) do
                    if not toolSeen[t] then
                        toolSeen[t] = true
                        tools[#tools + 1] = t
                    end
                end
            elseif r.code and not other then
                other = r
            end
        end
        local lines = {}
        if other then lines[#lines + 1] = Messages.refusal(other.code, other.extra) end
        if self.shortN > 0 then
            lines[#lines + 1] = getText("IGUI_MBLD_DragShort", tostring(self.shortN), Messages.missing(need, tools))
        end
        lines[#lines + 1] = getText("IGUI_MBLD_DragSkip", tostring(n - self.okN))
        tip = table.concat(lines, " <LINE> ")
    end
    self.tip = tip
    local hint
    if not self.joypad then -- 手把用原版按鈕提示（getAPrompt 等）
        local parts = {}
        if self.okN > 0 then
            parts[#parts + 1] = getText("IGUI_MBLD_HintBuild")
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
    self:layout()
end

-- ---------------------------------------------------------------- 畫面

-- 標籤面板（玩家畫面左下）：畫標籤、按鍵說明，並在每個壞格子上畫警告三角（不只靠顏色）。
-- 只顯示、不收滑鼠：wantMouseEvents=false 讓左鍵與移動穿過（ISUIElement.lua:1004），右鍵要明確回 false
-- （UIElement.java:1513-1515；框架 Toast 同做法）。元件不裁切，畫在自己範圍外照樣看得到。
local function overlayRender(self)
    local c = self.cursor
    if getCell():getDrag(c.player) ~= c then return end -- 已關掉的游標，removeFromUIManager 排隊中這一幀還會畫
    local p, ox, oy, warn, UI = c.player, self:getAbsoluteX(), self:getAbsoluteY(), c.warn, self.UI
    local gx, gy, gz, gbad = c.gx, c.gy, c.gz, c.gbad
    for i = 1, c.overUI and 0 or c.gn do -- 滑鼠在介面上時虛影收起，警告三角也不畫
        if gbad[i] then
            local sx = isoToScreenX(p, gx[i] + 0.5, gy[i] + 0.5, gz[i]) - ox - ICON / 2
            local sy = isoToScreenY(p, gx[i] + 0.5, gy[i] + 0.5, gz[i]) - oy - ICON / 2
            if not (UI and UI.Icons and UI.Icons.draw(self, "warning", sx, sy, ICON, warn, 1)) then
                self:drawText("!", sx + 5, sy, warn.r, warn.g, warn.b, 1, UIFont.Medium)
            end
        end
    end
    self:drawRect(0, 0, self.width, self.height, 0.65, 0, 0, 0)
    local y, fh, font = PAD, self.fh, self.font
    self:drawText(c.label, PAD, y, 1, 1, 1, 1, font)
    if c.label2 then
        y = y + fh
        if c.okN < #c.res then
            self:drawText(c.label2, PAD, y, warn.r, warn.g, warn.b, 1, font)
        else
            self:drawText(c.label2, PAD, y, 1, 1, 1, 1, font)
        end
    end
    if c.hint then self:drawText(c.hint, PAD, y + fh, 0.8, 0.8, 0.8, 1, font) end
end

local function noClick() return false end

-- 第一次 render 才建標籤面板與提示框（之後每幀只更新手把提示框的位置）
function Cursor:showUI()
    if not self.overlay then
        if not Overlay then
            Overlay = ISUIElement:derive("MinidoracatBuilderCursorOverlay")
            Overlay.render = overlayRender
            Overlay.onRightMouseDown = noClick
            Overlay.onRightMouseUp = noClick
        end
        local o = Overlay:new(0, 0, 1, 1)
        o.wantMouseEvents = false
        o.cursor = self
        o.UI = MinidoracatUI and MinidoracatUI.v1
        o.font = UIFont.Small
        o:initialise()
        o:addToUIManager()
        self.overlay = o
        local t = ISToolTip:new() -- 自己的一份，不借 ISWorldObjectContextMenu 的池（別的選單會收回去重用）
        t:initialise()
        t.followMouse = not self.joypad
        t.maxLineWidth = 600
        t:addToUIManager()
        self.tooltip = t
        self:layout()
    end
    if self.joypad and self.tip then
        self.tooltip:setDesiredPosition(isoToScreenX(self.player, self.kx, self.ky, self.kz),
            isoToScreenY(self.player, self.kx, self.ky, self.kz))
    end
end

-- 文字變了才排：面板寬高與位置、提示框內容與顯示
function Cursor:layout()
    local o = self.overlay
    if not o then return end
    local tm = getTextManager()
    local w, n = 0, 0
    local lines = { self.label, self.label2, self.hint }
    for i = 1, 3 do
        if lines[i] then
            w = math.max(w, tm:MeasureStringX(o.font, lines[i]))
            n = n + 1
        end
    end
    o.fh = tm:getFontHeight(o.font)
    o:setWidth(w + PAD * 2)
    o:setHeight(n * o.fh + PAD * 2)
    o:setX(getPlayerScreenLeft(self.player) + 16)
    o:setY(getPlayerScreenTop(self.player) + getPlayerScreenHeight(self.player) - o.height - BOTTOM)
    local t = self.tooltip
    t.description = self.tip or ""
    t:setVisible(self.tip ~= nil and not self.overUI)
end

function Cursor:hideUI()
    if self.tooltip then
        self.tooltip:setVisible(false)
        self.tooltip:removeFromUIManager()
        self.tooltip = nil
    end
    if self.overlay then
        self.overlay:setVisible(false)
        self.overlay:removeFromUIManager()
        self.overlay = nil
    end
end

-- 每幀畫虛影：每格各自的 sprite，可蓋白色、不能蓋照原版紅（ISBuildingObject.lua:572-576、IsoSprite.java:507-516）；
-- 地面格照玩家設定的好／壞色（ISBuildIsoEntity.lua:46-68）。不配置 table／字串。
-- 開頭先比 getDrag：同一幀每個 OnDoTileBuilding2 處理器拿到同一個拖曳物件（IsoCell.java:2612），
-- 已經關掉的游標可能被別的 MOD 再 render 一次，這時收掉自己的 UI 就走。
function Cursor:render(x, y, z, square)
    if getCell():getDrag(self.player) ~= self then return self:hideUI() end
    self:showUI()
    local t, show = self.tooltip, self.tip ~= nil and not self.overUI
    if t:getIsVisible() ~= show then t:setVisible(show) end
    if self.overUI then return end
    local floor = self:getFloorCursorSprite()
    local gx, gy, gz, gspr, gbad, gred, gyoff = self.gx, self.gy, self.gz, self.gspr, self.gbad, self.gred, self.gyoff
    for i = 1, self.gn do
        if gred[i] then
            gspr[i]:RenderGhostTileColor(gx[i], gy[i], gz[i], 0, gyoff[i], 0.65, 0.2, 0.2, 0.6)
        else
            gspr[i]:RenderGhostTileColor(gx[i], gy[i], gz[i], 0, gyoff[i], 1, 1, 1, 0.6)
        end
        if gbad[i] then
            floor:RenderGhostTileColor(gx[i], gy[i], gz[i], self.badR, self.badG, self.badB, 0.8)
        else
            floor:RenderGhostTileColor(gx[i], gy[i], gz[i], self.goodR, self.goodG, self.goodB, 0.8)
        end
    end
end

-- 放開左鍵／手把 A，而且至少一格可蓋（DoTileBuilding:167-170）。只送可蓋的格子；缺料、擋住的跳過。
-- 覆寫它就不經過原版 ISBuildAction；角色走過去與排動作在 Client.build（伺服器收下才排）。
function Cursor:tryBuild(x, y, z)
    if x ~= self.kx or y ~= self.ky or z ~= self.kz then -- 手把同一幀移了游標：先照那一格重算
        local sq = getCell():getGridSquare(x, y, z)
        if not (sq and self:isValid(sq)) then return end
    end
    local anchors = {}
    for _, r in ipairs(self.res) do
        if r.code == nil then anchors[#anchors + 1] = r.a end
    end
    self.lineX, self.lineY = nil, nil
    if #anchors > 0 then Cursor.send(self.character, self.name, self.d, anchors) end
end

-- 引擎 setDrag 換掉或清掉這個游標時呼叫（IsoCell.java:2563-2567）。
function Cursor:deactivate()
    self:hideUI()
    if not self.replaced and Cursor.onEnd then
        local ok, err = pcall(Cursor.onEnd, self.player)
        if not ok then print(LOG .. "onEnd failed: " .. tostring(err)) end
    end
end

-- ---------------------------------------------------------------- 送出後：被拒與走不到的通知

-- 目前等結果的請求：{ player, n, count, placed, accepted, at, idleAt }。每人只留一個請求（Client.build 會清佇列），
-- 所以只追最近一筆。游標關掉後照樣追，通知照發。
local watch

local function tell(player, code, extra)
    if code == "PERM_DENIED" then return end -- Safehouse 拒絕時自己推了通知，不再疊一則
    Messages.toast(player, Messages.refusal(code, extra))
end

-- 送一次建造（游標放開時；E2E 也可直接呼叫）。anchors＝{ { x, y, z }, ... }。回 nonce，或 nil, 原因碼。
function Cursor.send(player, name, d, anchors)
    local w = { player = player, count = #anchors, placed = 0, at = getTimestampMs() }
    watch = w
    local n, code = Client.build(player, name, d, anchors)
    if not n then
        if watch == w then watch = nil end
        if not w.told then tell(player, code) end -- 單機的 intent 當場被拒時 onResult 已經通知過
        return nil, code
    end
    w.n = n
    return n
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
        if w.placed >= w.count then watch = nil end
    elseif cmd == "refused" then
        -- 被拒就停整串：MP 的 Reject 與 Client 都清掉了後面的動作
        w.told = true
        watch = nil
        tell(w.player, args.code, args)
    end
end
Client.onResult = Cursor.onResult

-- 每 tick：沒有在等的請求就直接回。收下後佇列空了一陣子還沒蓋完＝走不到（或被打斷），提示一次。
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
    if w.placed < w.count then tell(w.player, "WALK") end
end
Events.OnTick.Add(Cursor.tick)

return Cursor
