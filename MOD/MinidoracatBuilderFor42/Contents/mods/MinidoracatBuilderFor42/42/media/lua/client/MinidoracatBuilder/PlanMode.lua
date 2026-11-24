-- 規劃與擺放：地上的藍圖只有這個模組持有（PlanMode.plan()）。只在客戶端：規劃片與擺放虛影由 PlanGhost 每幀畫，
-- 不建世界物件、不送指令、不寫 modData；地上的藍圖在哪記在本機檔（PlanStore），藍圖本身存藍圖檔（PlanFile）。
-- 規劃開著時，建造游標（Cursor）與配方游標（Recipes 叫 PlanMode.addCells）放開不蓋，改記進藍圖，一次放開算一步。
-- 狀態：none（沒有藍圖）→ edit（規劃中）／place（整張跟著游標）→ fixed（在地上）。
-- 藍圖的座標相對原點 plan.ox, oy, oz（世界座標）；跟著游標時 plan.ox 是 nil，位置記在拖曳物件上。
require "MinidoracatBuilder/Entry"
require "MinidoracatBuilder/Turn"
require "MinidoracatBuilder/Plan"
require "MinidoracatBuilder/PlanFile"
require "MinidoracatBuilder/PlanStore"
require "MinidoracatBuilder/Messages"
require "MinidoracatBuilder/Cursor"
require "MinidoracatBuilder/Window" -- 它的按鍵先登記，這裡的接在同一節後面

MinidoracatBuilder = MinidoracatBuilder or {}
local B = MinidoracatBuilder
local PM = B.PlanMode or {}
B.PlanMode = PM
local Entry, Turn, Plan, PlanFile, PlanStore, Messages, Cursor = B.Entry, B.Turn, B.Plan, B.PlanFile, B.PlanStore,
    B.Messages, B.Cursor

local LOG = "[MinidoracatBuilderFor42] "
PM.TINT = { r = 0.75, g = 0.6, b = 1 } -- 規劃片的淡紫色（PlanGhost、游標地框共用）
local HOME_RANGE = 100                -- 離原位置這麼近才給「放回原位置」
local SHOW_MAX = 256                  -- 框選時最多標幾格（每格一個地框）
PM.BIND_UNDO, PM.BIND_REDO = "MinidoracatBuilder_PlanUndo", "MinidoracatBuilder_PlanRedo"
PM.BIND_HIDE, PM.BIND_DELETE = "MinidoracatBuilder_PlanHide", "MinidoracatBuilder_PlanDelete"
-- DIG：挖地下室的三個項目不進藍圖（藍圖檔讀檔、擷取也不收）
local WHY = { FULL = "IGUI_MBLD_PlanFull", TOO_WIDE = "IGUI_MBLD_PlanTooWide", TOO_HIGH = "IGUI_MBLD_PlanTooHigh",
    DIG = "IGUI_MBLD_PlanNoDig" }

-- plan、mode、hidden、level、tool（draw｜select｜erase）、sel（選到的片）、selSet、drag（本模組的拖曳物件）、
-- home（放回原位置）、prev（搬的時候原本在哪，取消用）
local S = { mode = "none", hidden = false, tool = "draw", sel = {}, selSet = {}, listeners = {} }
PM.playerNum = 0

local function player() return getSpecificPlayer(PM.playerNum or 0) end
local function say(text) Messages.toast(player(), text, getText("IGUI_MBLD_PlanTitle")) end
local function floorZ(p) return math.floor(p:getZ()) end
local function whyText(code) return getText(WHY[code] or "IGUI_MBLD_PlanTooWide") end

function PM.plan() return S.plan end
function PM.state() return S.plan and S.mode or "none" end
-- 這位玩家手上的擺放／搬／複製／手把框選（沒有回 nil）；Cursor 的右鍵取消用
function PM.drag(pn) return S.drag and S.drag.player == pn and S.drag or nil end
function PM.planning() return S.mode == "edit" end
function PM.hidden() return S.hidden end
function PM.level() return S.level end
function PM.tool() return S.tool end
function PM.selected() return S.sel end
function PM.isSelected(p) return S.selSet[p] == true end
function PM.floating() return S.drag end -- PlanGhost：擺放、搬、複製中的拖曳物件（ox／oy／oz 或 dx／dy、lines）
function PM.home() return S.home end

function PM.origin()
    local p = S.plan
    if not p or S.mode == "place" or p.ox == nil then return nil end
    return p.ox, p.oy, p.oz
end

function PM.changed(fn) S.listeners[#S.listeners + 1] = fn end

local function setSel(list)
    S.sel, S.selSet = list or {}, {}
    for _, p in ipairs(S.sel) do S.selSet[p] = true end
end

-- 狀態或藍圖變了：通知面板、重排工具列、讓建造游標下一幀重算標籤（上限是照藍圖算的）
local function fire()
    for _, fn in ipairs(S.listeners) do
        local ok, err = pcall(fn)
        if not ok then print(LOG .. "plan listener failed: " .. tostring(err)) end
    end
    local c = Cursor.get(PM.playerNum or 0)
    if c then c.kgen = nil end
    if PM.refreshBar then PM.refreshBar() end
end
PM.fire = fire

local function checkReset()
    local C = B.PlanCheck
    if C and C.reset then pcall(C.reset) end
end

-- ===== 上限 =====

local function dupOf(plan, x, y, z, d, o, id)
    for _, q in ipairs(Plan.at(plan, x, y, z)) do
        local item = plan.items[q.it]
        if q.d == d and q.o == o and item and item.id == id then return true end
    end
    return false
end

-- 朝向記成同一種寫法：游標剛開是 0（項目自己那張圖），按 R 轉一圈回來是 1..4 的其中一個，兩種是同一張圖。
-- 那一面就是自己那張圖時一律記 0：同一格同一張圖才認得出重複，整張轉四次也才回到原樣。配方片的面編號不動
local function tileEntry(id)
    if type(id) ~= "string" or id:sub(1, 7) == "recipe:" then return nil end
    return Entry.resolve(id) or nil
end
local function canon(entry, d)
    if entry and d and d >= 1 and d <= 4 then
        local spr = Entry.face(entry, d)
        if spr and spr:getName() == entry.name then return 0 end
    end
    return d
end

-- 片數與包圍盒（藍圖座標）加上這幾格（世界座標 { x, y, z, d }）之後是多少。重複的片不算
local function tally(plan, cells, id, o, n, x0, y0, z0, x1, y1, z1)
    local entry, last, d = tileEntry(id), nil, nil -- 一排的朝向多半相同：換了才重查
    for _, c in ipairs(cells) do
        local x, y, z = c[1] - plan.ox, c[2] - plan.oy, c[3] - plan.oz
        if c[4] ~= last then last, d = c[4], canon(entry, c[4]) end
        if not dupOf(plan, x, y, z, d, o, id) then
            n = n + 1
            if x0 == nil then
                x0, y0, z0, x1, y1, z1 = x, y, z, x, y, z
            else
                x0, y0, z0 = math.min(x0, x), math.min(y0, y), math.min(z0, z)
                x1, y1, z1 = math.max(x1, x), math.max(y1, y), math.max(z1, z)
            end
        end
    end
    return n, x0, y0, z0, x1, y1, z1
end

local function limitWhy(n, x0, y0, z0, x1, y1, z1)
    if n > Plan.MAX_PIECES then return "FULL" end
    if x0 and (x1 - x0 >= Plan.MAX_SIDE or y1 - y0 >= Plan.MAX_SIDE) then return "TOO_WIDE" end
    if z0 and z1 - z0 >= Plan.MAX_LEVELS then return "TOO_HIGH" end
    return nil
end

-- 這幾格（世界座標 { x, y, z, d }）能不能加進藍圖：回 nil，或 DIG（挖地下室的項目不進藍圖）／FULL／TOO_WIDE／TOO_HIGH
-- （超出上限）。重複的片不算
function PM.overflow(plan, cells, id, o)
    if B.Rules.DIG[id] then return "DIG" end
    local x0, y0, z0, x1, y1, z1 = Plan.bounds(plan)
    return limitWhy(tally(plan, cells, id, o, plan.n, x0, y0, z0, x1, y1, z1))
end

-- 一種項目的格子加進藍圖（不開新的一步、不通知）。回 加了幾片
local function addGroup(plan, id, cells, o)
    local okSrc, src = pcall(PlanFile.source, id)
    local it = Plan.item(plan, id, okSrc and src or nil)
    local entry, last, d = tileEntry(id), nil, nil
    local added = 0
    for _, c in ipairs(cells) do
        if c[4] ~= last then last, d = c[4], canon(entry, c[4]) end
        local p, code = Plan.add(plan, c[1] - plan.ox, c[2] - plan.oy, c[3] - plan.oz, d, o, it, c[5])
        if p then
            added = added + 1
        elseif code ~= "DUP" then
            print(LOG .. "plan add refused e=" .. tostring(id) .. ": " .. tostring(code))
        end
    end
    return added
end

-- 記成一步：cells＝世界座標 { x, y, z, d[, w] }（w＝車庫門寬度）。回 加了幾片，或 nil, 原因碼
local function record(id, cells, o)
    local plan = S.plan
    local why = PM.overflow(plan, cells, id, o)
    if why then return nil, why end
    Plan.begin(plan)
    local added = addGroup(plan, id, cells, o)
    Plan.commit(plan)
    fire()
    return added
end

-- 配方游標（Recipes.lua）放下的格子：規劃開著時記進藍圖。回 true，或 nil, 原因碼（OFF＝規劃沒開）
function PM.addCells(playerNum, id, cells)
    if S.mode ~= "edit" or not S.plan then return nil, "OFF" end
    local n, why = record(id, cells, 0)
    if not n then
        say(whyText(why))
        return nil, why
    end
    return true
end

-- 屋頂助手（Roof.layout 的結果）：groups＝{ { id, cells＝{ { x, y, z, d[, w] }… } }… }，世界座標。整批算一步
-- （上一步一次收回）；各組合在一起算上限，會超出就一片都不加。回 加了幾片，或 nil, OFF／FULL／TOO_WIDE／TOO_HIGH
function PM.addMany(playerNum, groups)
    if S.mode ~= "edit" or not S.plan then return nil, "OFF" end
    local plan = S.plan
    local n, x0, y0, z0, x1, y1, z1 = plan.n, Plan.bounds(plan)
    for _, g in ipairs(groups) do
        n, x0, y0, z0, x1, y1, z1 = tally(plan, g.cells, g.id, 0, n, x0, y0, z0, x1, y1, z1)
    end
    local why = limitWhy(n, x0, y0, z0, x1, y1, z1)
    if why then return nil, why end
    local added = 0
    Plan.begin(plan)
    for _, g in ipairs(groups) do added = added + addGroup(plan, g.id, g.cells, 0) end
    Plan.commit(plan)
    fire()
    return added
end

-- ===== 建造游標的掛鉤（Cursor.hook；規劃開著時才掛） =====

local hook = {}

-- 這次放開會記的錨點：沒有那一面的（NO_FACE）沒有朝向，不記；缺料、被擋這類只影響現在能不能蓋，照記
local function cursorCells(c)
    local out = {}
    for _, r in ipairs(c.res or {}) do
        local a = r.a
        if a and a[4] ~= nil then out[#out + 1] = a end
    end
    return out
end

-- 每幀呼叫（Cursor.isValid）：只讀 label 算好的結果，不配置
function hook.valid(c) return c.planWhy == nil end

function hook.layer(c) return S.level - math.floor(c.character:getZ()) end

function hook.tint() return PM.TINT end

-- 第二行換成「規劃中」那一行，按鍵說明換成規劃的；超出上限時寫原因
function hook.label(c, src)
    if not S.plan then return nil end
    local cells = cursorCells(c)
    c.planWhy = PM.overflow(S.plan, cells, c.name, c.overlap and 1 or 0)
    local col = c.colors or {}
    local out = { src[1], src[2] }
    if c.planWhy then
        out[3], out[4] = whyText(c.planWhy), col.warning
    else
        out[3], out[4] = getText("IGUI_MBLD_PlanAdd", tostring(#cells)), col.text
    end
    local last = #src
    if c.hint and src[last - 1] == c.hint then last = last - 2 end
    for i = 3, last do out[#out + 1] = src[i] end
    if c.hint then
        out[#out + 1] = getText("IGUI_MBLD_PlanHint")
        out[#out + 1] = col.textMuted
    end
    return out
end

function hook.commit(c)
    if S.mode ~= "edit" or not S.plan then return false end
    local n, why = record(c.name, cursorCells(c), c.overlap and 1 or 0)
    if not n then say(whyText(why)) end
    return true
end

local HOOKS = { "valid", "commit", "label", "tint", "layer" }
local function hooks(on)
    local h = Cursor.hook
    for _, k in ipairs(HOOKS) do
        if on then
            h[k] = hook[k]
        elseif h[k] == hook[k] then
            h[k] = nil
        end
    end
    local c = Cursor.get(PM.playerNum or 0)
    if c then c.kgen = nil end
end

-- ===== 轉向 =====

local DIR_OF = { N = 1, E = 2, S = 3, W = 4 }

local function footprint(entry, spr, w)
    local set = w and entry.kind == "door" and Entry.doorSet(spr)
    if set and set.garage then return Entry.groupCells(set, w) end
    return Entry.cells(spr)
end

-- 給 Plan.rotate：順時針（北→東→南→西），Plan.rotate 先把錨點 (x, y) 轉到 M＝(minX + maxY − y, minY + x − minX)，
-- 一格的位移 (dx, dy) 轉成 (−dy, dx)。回 新朝向, 位移修正 dx, dy；這一片沒有那個方向的圖回 nil。
-- 只佔一條格邊的（牆、柵欄、門框、窗框、門、窗，含車庫門與雙開門）：北邊轉成右邊那格的西邊、西邊轉成北邊；
-- 整組佔的格子先轉，再照新方向挑錨點（北向取 x 最小、西向取 y 最大，Entry.groupCells 的排法）。
-- 其他有方向的：照 Facing 換到下一個方向，多格的對齊佔地的左上角。沒有方向的（地板、柱子）朝向不變。
-- 坡道（一組一片、錨點是頭片）：照上坡方向換到下一個（Entry.face 的 1..4），位移不用修正：一整組沿上坡方向從頭片排開，
-- 錨點轉過去之後整組跟著轉；坡道片沒有 Facing 屬性，所以不走上一條
function PM.turnPiece(p, item)
    local id = item and item.id
    if type(id) ~= "string" then return nil end
    if id:sub(1, 7) == "recipe:" then
        local R = B.Recipes
        local f = R and R.faces and R.faces(id)
        if not f or f.n == 0 then return nil end
        if f.n == 1 then return p.d, 0, 0 end
        for i = 1, f.n do
            if f[i] == p.d then return f[i % f.n + 1], 0, 0 end
        end
        return nil
    end
    local entry = Entry.resolve(id)
    if not entry then return nil end
    if entry.kind == "ramp" then
        local cur = p.d
        if cur == 0 then -- 項目自己那張圖：找它是哪個方向
            for d = 1, 4 do
                local f = Entry.face(entry, d)
                if f and f:getName() == entry.name then
                    cur = d
                    break
                end
            end
        end
        if not cur or cur < 1 or cur > 4 then return nil end
        local nd = cur % 4 + 1
        if not Entry.face(entry, nd) then return nil end
        return canon(entry, nd), 0, 0
    end
    local spr = Entry.face(entry, p.d)
    if not spr then return nil end
    local offs = footprint(entry, spr, p.w)
    local n, w = Entry.edges(entry.kind, spr)
    if n ~= w then
        local od = Turn.other(entry, p.d)
        if od == nil then return nil end
        local bx, by
        for _, o in ipairs(offs) do
            local x, y = -o[2] + (n and 1 or 0), o[1]
            if bx == nil or (n and y > by) or (not n and x < bx) then bx, by = x, y end
        end
        return od, bx, by
    end
    local cur = p.d
    if cur == 0 or cur == 5 then cur = DIR_OF[spr:getProperties():get("Facing")] end
    if not cur or cur < 1 or cur > 4 then return p.d, 0, 0 end
    local nd = cur % 4 + 1
    local nspr = Entry.face(entry, nd)
    if not nspr then return nil end
    local ax, ay, bx, by
    for _, o in ipairs(offs) do
        ax, ay = math.min(ax or -o[2], -o[2]), math.min(ay or o[1], o[1])
    end
    for _, o in ipairs(Entry.cells(nspr)) do
        bx, by = math.min(bx or o[1], o[1]), math.min(by or o[2], o[2])
    end
    return canon(entry, nd), ax - bx, ay - by
end

local function allPieces(plan)
    local out = {}
    Plan.each(plan, function(p) out[#out + 1] = p end)
    return out
end

-- 轉 90 度（整張或選到的）。回 true；超出上限通知並回 false
-- 某片查圖出錯（別的 MOD 的配方、圖塊資料）只算這片轉不了，不讓整次轉向中斷
local function safeTurn(p, item)
    local ok, d, dx, dy = pcall(PM.turnPiece, p, item)
    if ok then return d, dx, dy end
    print(LOG .. "plan turn failed e=" .. tostring(item and item.id) .. ": " .. tostring(d))
    return nil
end

local function rotate(list)
    local stuck, why = Plan.rotate(S.plan, list, safeTurn)
    if stuck == nil then
        say(whyText(why))
        return false
    end
    if stuck > 0 then say(getText("IGUI_MBLD_PlanStuck", tostring(stuck))) end
    fire()
    return true
end

-- ===== 存檔 =====

-- 只存藍圖檔（沒存過照名稱取檔名）。回 true，或 nil, 原因
local function saveFile()
    local plan = S.plan
    local file, why = plan.file, nil
    if not file then file, why = PlanFile.fileName(plan.name) end
    local ok = false
    if file then ok, why = PlanFile.save(plan, file) end
    if not ok then
        why = why or "FILE"
        print(LOG .. "plan save failed: " .. tostring(why))
        say(getText("IGUI_MBLD_PlanSaveFail"))
        return nil, why
    end
    return true
end

-- 包圍盒的角在世界上的位置：藍圖檔的 pos 與 worlds 檔的原點都記這個（藍圖檔讀回來時片是相對這個角）
local function corner(plan)
    local x0, y0, z0 = Plan.bounds(plan)
    return plan.ox + (x0 or 0), plan.oy + (y0 or 0), plan.oz + (z0 or 0)
end

-- 改這個存檔的地上藍圖記錄：edit(st) 改好再存，隱藏照現況；材料箱、上次狀態（別的模組寫的）照原樣留著。
-- 回 true；存不了說一聲並回 nil
local function storeEdit(edit)
    local st = PlanStore.load()
    if edit then edit(st) end
    st.hidden = S.hidden == true
    if PlanStore.save(st) then return true end
    say(getText("IGUI_MBLD_PlanSaveFail"))
    return nil
end

local function storeForget(st)
    st.file, st.name, st.renameTo, st.ox, st.oy, st.oz, st.px, st.py, st.pz = nil, nil, nil, nil, nil, nil, nil, nil, nil
end

-- 記錄換成這張的檔名、名稱與角；同一個檔、角變了時原本的角留在 prev（藍圖檔還沒寫成就斷掉時，讀回照藍圖檔認出舊版）
local function storePlan(plan)
    return storeEdit(function(st)
        local x, y, z = corner(plan)
        if st.file ~= plan.file then
            st.px, st.py, st.pz = nil, nil, nil
        elseif st.ox and (st.ox ~= x or st.oy ~= y or st.oz ~= z) then
            st.px, st.py, st.pz = st.ox, st.oy, st.oz
        end
        st.file, st.name, st.renameTo, st.ox, st.oy, st.oz = plan.file, PlanStore.nameKey(plan.name), nil, x, y, z
    end)
end

-- 藍圖檔與 worlds 記錄一起存（片相對包圍盒的角，角記在 worlds 檔，只存一邊的話包圍盒變過就會錯位）。
-- 記錄已經指著這個檔：先寫記錄（舊的角留在 prev）再寫藍圖檔，中間斷掉時讀回認得出舊版；
-- 沒存過、或記錄指著別張（剛從藍圖庫擺下）：先寫藍圖檔（取到檔名），再寫記錄，中間斷掉時記錄還是原本那張。
-- 任一步失敗回 nil, 原因（已說過一聲），記憶體不動、之後可以再存。擺放中、空白沒存過的不存
local function persist()
    local plan = S.plan
    if not plan or S.mode == "place" or not plan.ox or (plan.n == 0 and not plan.file) then return true end
    local ok, why
    if plan.file and PlanStore.load().file == plan.file then
        if not storePlan(plan) then return nil, "STORE" end
        ok, why = saveFile()
    else
        ok, why = saveFile()
        if ok and not storePlan(plan) then ok, why = nil, "STORE" end
    end
    if ok then S.savedRev = plan.rev end -- PM.unsaved 比這個
    return ok, why
end

-- 存檔（藍圖面板的「存檔」）。回 true，或 nil, 原因
function PM.save()
    if not S.plan then return nil, "NO_PLAN" end
    if S.mode == "place" then return nil, "PLACING" end
    return persist()
end

-- 讀不到的原因裡，只有這兩種可能下次就好了（檔案被鎖住、暫時打不開）：保留記錄、下次再試
local RETRY = { READ = true, NO_FILE = true }

-- 記錄認得這個名稱嗎：記的名稱，或藍圖庫正在改成的名稱（改名寫完藍圖檔、還沒改記錄就斷掉）
local function knownName(st, name)
    local key = PlanStore.nameKey(name)
    return key == st.name or key == st.renameTo
end

-- 藍圖資料夾裡名稱合 match(名稱) 的檔：剛好一個才回它的檔名
local function fileNamed(match)
    local found
    for _, f in ipairs(PlanFile.list()) do
        local head = PlanFile.head(f)
        if head and match(head.name) then
            if found then return nil end
            found = f
        end
    end
    return found
end

-- 藍圖檔讀回來時的角：記錄的角；藍圖檔的角（pos）等於 prev＝記錄寫好、藍圖檔還沒寫成就斷掉，檔是上一版，照上一版的角
local function savedCorner(plan, st)
    local fx, fy, fz = plan.ox, plan.oy, plan.oz
    if fx and not (fx == st.ox and fy == st.oy and fz == st.oz) and fx == st.px and fy == st.py and fz == st.pz then
        return fx, fy, fz
    end
    return st.ox, st.oy, st.oz
end

-- 進遊戲：讀回地上的藍圖。確定沒了（刪掉、壞了、檔名給了別張）才清記錄，並說一聲
function PM.restore()
    S.plan, S.mode, S.drag, S.home, S.prev = nil, "none", nil, nil, nil
    setSel(nil)
    local st = PlanStore.load()
    S.hidden = st.hidden == true
    if not st.file then return false end
    local plan, why = PlanFile.load(st.file)
    -- 正式檔與備份都不在資料夾裡：被刪掉了（例如在檔案總管刪的），不是一時打不開
    if not plan and why == "NO_FILE" and not PlanFile.exists(st.file) then why = "GONE" end
    -- 檔不在、記錄有名稱：檔被改了名（藍圖庫以外的地方）時照記錄認得的名稱找回。藍圖庫改名換了檔名、還沒改記錄就斷掉時，
    -- 舊檔已標成刪除，只找「要改成的名稱」：藍圖庫的複製保留原名稱，舊名稱可能還有一份副本。
    -- 同名的剛好一張才接，零張或好幾張照舊算沒了
    local moved = false
    local match
    if why == "GONE" and st.name then
        match = function(name) return knownName(st, name) end
    elseif why == "DELETED" and st.renameTo then
        match = function(name) return PlanStore.nameKey(name) == st.renameTo end
    end
    if match then
        local f = fileNamed(match)
        local p2, why2 = nil, nil
        if f then p2, why2 = PlanFile.load(f) end
        if p2 then
            plan, why, moved = p2, nil, true
            st.file = f
        elseif f then
            why = why2
        end
    end
    -- 記錄的名稱和檔裡的不同：這個檔名已經給了另一張藍圖（原本那張刪掉後重用），不擺別張
    if plan and (st.name or st.renameTo) and not knownName(st, plan.name) then plan, why = nil, "NAME" end
    if not plan or st.ox == nil then
        why = why or "NO_POS"
        print(LOG .. "ground plan not restored f=" .. tostring(st.file) .. ": " .. tostring(why))
        if not plan and RETRY[why] then
            say(getText("IGUI_MBLD_PlanUnread"))
            return false
        end
        say(getText("IGUI_MBLD_PlanLost"))
        storeEdit(storeForget)
        return false
    end
    plan.ox, plan.oy, plan.oz = savedCorner(plan, st)
    S.plan, S.mode = plan, "fixed"
    -- 找回別的檔、或改名做到一半：記錄改成現在這個檔與名稱（寫不進去已說過，下次進遊戲照樣認得）
    if moved or st.renameTo then
        local f, key = st.file, PlanStore.nameKey(plan.name)
        storeEdit(function(s) s.file, s.name, s.renameTo = f, key, nil end)
    end
    checkReset()
    fire()
    return true
end

-- 藍圖庫改名之前（PlanLibrary 的 L.rename）：記錄指著這個檔時先寫下要改成的名稱。改名先寫藍圖檔（可能換檔名）
-- 再改記錄（PM.retarget），中間斷掉時檔裡的名稱和記錄的不同，讀回時（PM.restore）兩個名稱都認。
-- newName 是 nil＝改名沒成，清掉。沒記名稱的舊記錄讀回時本來就不比名稱，不用記。
-- 回 true；記錄寫不進去回 nil（不要改名：斷在中間時認不出來）
function PM.renaming(file, ...)
    local newName = ...
    local st = PlanStore.load()
    if file == nil or st.file ~= file or not st.name then return true end
    local key = newName and PlanStore.nameKey(Plan.cleanName(newName)) or nil
    if st.renameTo == key then return true end
    st.renameTo = key
    if PlanStore.save(st) then return true end
    print(LOG .. "plan store save failed before rename f=" .. tostring(file))
    return nil
end

-- 藍圖庫改名、刪除之後（PlanLibrary 呼叫）：記錄或地上那張是 oldFile 才改。newFile 是 nil＝刪掉了，之後存檔另取檔名，
-- 不再寫回舊檔名（舊檔名可能已經給了別張）。回 true＝改了
-- 記錄先改：讀不到而保留的記錄（地上沒有藍圖）也要跟著改名。原點不動：改名搬過去的是磁碟上那份，不是記憶體裡還沒存的
function PM.retarget(oldFile, ...)
    local newFile, newName = ...
    if oldFile == nil then return false end
    local hit = false
    local st = PlanStore.load()
    if st.file == oldFile then
        hit = true
        if newFile then
            st.file, st.renameTo = newFile, nil
            if newName then st.name = PlanStore.nameKey(Plan.cleanName(newName)) end
        else
            storeForget(st)
        end
        if not PlanStore.save(st) then print(LOG .. "plan store save failed after rename f=" .. tostring(oldFile)) end
    end
    local plan = S.plan
    if plan and plan.file == oldFile then
        hit = true
        plan.file = newFile
        if newFile and newName then plan.name = Plan.cleanName(newName) end
    end
    if hit then fire() end
    return hit
end

-- ===== 規劃開關 =====

function PM.setLevel(z)
    z = math.floor(tonumber(z) or 0)
    local plan = S.plan
    if plan and plan.n > 0 and plan.oz then
        local _, _, z0, _, _, z1 = Plan.bounds(plan)
        z = math.max(plan.oz + z1 - (Plan.MAX_LEVELS - 1), math.min(plan.oz + z0 + (Plan.MAX_LEVELS - 1), z))
    end
    z = math.max(-32, math.min(31, z))
    if z == S.level then return end
    S.level = z
    fire()
end

local function stopTool()
    local c = Cursor.get(PM.playerNum or 0)
    if c and c.planTool then
        c.planTool = nil
        getCell():setDrag(nil, PM.playerNum or 0)
    end
    local d = S.drag
    if d and d.kind ~= "place" then getCell():setDrag(nil, d.player) end
end

local function leaveEdit()
    hooks(false)
    stopTool()
    S.tool = "draw"
    setSel(nil)
    local L = B.PlanLibrary
    if L and L.closeChooser then L.closeChooser() end -- 存檔前的三選一跟著規劃關（它不擋畫面）
end

-- 開關規劃：沒有藍圖就在腳下建一張空的；關掉時存檔（空的、沒存過的直接丟掉）。
-- 打開回 true；關掉照 stopEdit 回
function PM.toggle(playerNum)
    PM.playerNum = playerNum or PM.playerNum or 0
    if S.mode == "edit" then return PM.stopEdit() end
    local p = player()
    if not p then return false, "NO_PLAYER" end
    -- 照圖蓋正在送的那批照舊座標算：規劃會搬、轉、刪片，先暫停（Runner 載入順序在後，用到才查）
    local R = B.Runner
    if R and R.pause then
        local ok, err = pcall(R.pause, "EDIT")
        if not ok then print(LOG .. "runner pause failed: " .. tostring(err)) end
    end
    if S.drag then getCell():setDrag(nil, S.drag.player) end
    -- 手上的牆面油漆、壁紙、灰泥游標（配方游標裡沒有 mbldR 的那種，Recipes.build）放開照樣會刷：先收掉
    local held = getCell():getDrag(PM.playerNum)
    if held and held.mbldRecipe and not held.mbldR then getCell():setDrag(nil, PM.playerNum) end
    if not S.plan then
        local plan = Plan.new(getText("IGUI_MBLD_PlanUntitled"))
        plan.ox, plan.oy, plan.oz = math.floor(p:getX()), math.floor(p:getY()), floorZ(p)
        S.plan = plan
        checkReset()
    end
    if not S.plan.ox then return false, "PLACING" end
    S.mode, S.tool, S.hidden, S.savedRev = "edit", "draw", false, S.plan.rev
    setSel(nil)
    S.level = nil
    hooks(true)
    PM.setLevel(floorZ(p))
    fire()
    return true
end

-- 新的空白藍圖並開始規劃。地上已經有藍圖時不動它，回 false, "BUSY"（藍圖庫先問、收起成功再叫）
function PM.blank(playerNum)
    PM.playerNum = playerNum or PM.playerNum or 0
    if S.plan then return false, "BUSY" end
    return PM.toggle(PM.playerNum)
end

-- 規劃中那張整張丟掉（沒存過的），記錄不動
local function dropPlan()
    leaveEdit()
    S.plan, S.mode = nil, "none"
    checkReset()
    fire()
    return true
end

-- 結束規劃並存檔。存檔失敗時留在規劃裡（工具列還在、可以再按完成），回 false, 原因
function PM.stopEdit()
    if S.mode ~= "edit" then return false, "NOT_EDIT" end
    local plan = S.plan
    if plan.n == 0 and not plan.file then return dropPlan() end -- 空白、沒存過：直接丟掉，記錄不動（一時讀不到而保留的那筆要留著）
    local ok, why = persist()
    if not ok then return false, why end
    leaveEdit()
    S.mode = "fixed"
    fire()
    return true
end

local function openPanel()
    local Panel = B.PlanPanel
    if S.plan and Panel and Panel.open then pcall(Panel.open, PM.playerNum or 0) end
end

-- 「完成」：收起工具列、存檔、打開藍圖面板。回同 stopEdit
function PM.finish()
    local ok, why = PM.stopEdit()
    if not ok then return false, why end
    openPanel()
    return true
end

-- 規劃中改過、還沒存（存過的藍圖才算；上一步回到原樣也算改過）
function PM.unsaved()
    return S.mode == "edit" and S.plan ~= nil and S.plan.file ~= nil and S.plan.rev ~= S.savedRev
end

-- 上次存檔的那份：記錄指著這個檔時照記錄的角（同 restore，認得上一版），否則照檔裡的 pos。
-- 回 plan, 記錄裡的隱藏；或 nil, 原因
local function loadSaved(file)
    local plan, why = PlanFile.load(file)
    if not plan then return nil, why end
    local st = PlanStore.load()
    local mine = st.file == file
    if mine and st.ox then plan.ox, plan.oy, plan.oz = savedCorner(plan, st) end
    if not plan.ox then return nil, "NO_POS" end
    return plan, mine and st.hidden == true
end

-- 「取消」：離開規劃、丟掉沒存的改動。存過的回到上次存檔的樣子與位置（讀不回來就留在規劃、說一聲，回 false, 原因）；
-- 沒存過的整張丟掉。照圖蓋進規劃時已暫停，同「完成」之後要玩家再按
function PM.cancelEdit()
    if S.mode ~= "edit" then return false, "NOT_EDIT" end
    local file = S.plan.file
    if not file then return dropPlan() end
    local plan, more = loadSaved(file) -- more＝讀不回來的原因，或記錄裡的隱藏
    if not plan then
        print(LOG .. "plan cancel reload failed f=" .. tostring(file) .. ": " .. tostring(more))
        say(getText("IGUI_MBLD_PlanCancelFail"))
        return false, more
    end
    leaveEdit()
    S.plan, S.mode, S.hidden = plan, "fixed", more -- 進規劃時先顯示出來了，照記錄改回去
    checkReset()
    fire()
    return true
end

-- 工具列「取消」：有沒存的改動（或沒存過、有片）先確認（沒有框架就不丟）。取消了同「完成」打開藍圖面板
function PM.askCancel()
    if S.mode ~= "edit" then return false end
    local fresh = not S.plan.file
    local function go()
        local ok, why = PM.cancelEdit()
        if ok then openPanel() end
        return ok, why
    end
    if not (PM.unsaved() or (fresh and S.plan.n > 0)) then return go() end
    local L = B.PlanLibrary
    return L ~= nil and L.confirm ~= nil and L.confirm(PM.playerNum or 0, { title = getText("IGUI_MBLD_PlanDiscardTitle"),
        text = getText(fresh and "IGUI_MBLD_PlanDiscardNew" or "IGUI_MBLD_PlanDiscardText"),
        ok = getText("IGUI_MBLD_PlanDiscard"), cancel = getText("IGUI_MBLD_PlanKeep"), danger = true, onYes = go }) ~= nil
end

-- 換個名稱另存成新的一張再做 save（原本的檔不動）。失敗時名稱與檔名改回去。
-- 整張擦光了不做（回 false, "EMPTY"）：沒有檔名的空白藍圖不存檔，完成時會整張丟掉，地上那張就不見了
local function asNew(name, save)
    local plan = S.plan
    if not plan then return false, "NO_PLAN" end
    if plan.n == 0 then return false, "EMPTY" end
    local file, old = plan.file, plan.name
    local n = Plan.cleanName(name)
    if n ~= "" then plan.name = n end
    plan.file = nil
    local ok, why = save()
    if not ok then plan.file, plan.name = file, old end
    return ok, why
end

function PM.finishAs(name)
    if S.mode ~= "edit" then return false, "NOT_EDIT" end
    return asNew(name, PM.finish)
end

function PM.saveAs(name)
    if S.mode ~= "edit" then return false, "NOT_EDIT" end
    return asNew(name, PM.save)
end

-- 有沒存的改動：問覆蓋原本的、另存新檔還是取消（藍圖庫的三選一框）；沒有框架照舊覆蓋。問了回 true, "ASKED"。
-- 框不擋畫面：按下去時已經離開規劃（取消了）或地上換了一張就不做。整張擦光了不給「另存新檔」
local function askSaveTo(overwrite, saveAs)
    local L, plan = B.PlanLibrary, S.plan
    local function live(fn)
        return function(...)
            if S.plan ~= plan or S.mode ~= "edit" then return false, "NOT_EDIT" end
            return fn(...)
        end
    end
    if PM.unsaved() and L and L.askOverwrite
        and L.askOverwrite(PM.playerNum or 0, { name = plan.name, onOverwrite = live(overwrite),
            onNew = plan.n > 0 and live(saveAs) or nil }) then
        return true, "ASKED"
    end
    return overwrite()
end

-- 工具列「完成」、工具列 X、建造工坊「規劃」、面板「完成」
function PM.askFinish()
    return askSaveTo(PM.finish, PM.finishAs)
end

-- 藍圖面板「存檔」：同上但不離開規劃；存好了叫 done()
function PM.askSave(...)
    local done = ...
    local function after(ok, ...)
        local why = ...
        if ok and done then done() end
        return ok, why
    end
    if S.mode ~= "edit" then return after(PM.save()) end
    return askSaveTo(function() return after(PM.save()) end, function(name) return after(PM.saveAs(name)) end)
end

-- 只改記錄裡的「隱藏」，不重寫藍圖
function PM.setHidden(on)
    S.hidden = on == true
    storeEdit(nil)
    fire()
end

-- 「收起」：先存檔，記錄改成地上沒有這張，都成功才把地上的藍圖拿掉（蓋好的留在世界上）。
-- 任一步失敗時什麼都不動（已說過一聲），回 false, 原因
function PM.clear()
    local plan = S.plan
    if not plan then return false, "NO_PLAN" end
    local ok, why = persist()
    if not ok then return false, why end
    -- 記錄指著這張才清：從藍圖庫擺、還沒定位的那張不動原本的記錄（例如一時讀不到而保留的那筆）
    if plan.file and not storeEdit(function(st) if st.file == plan.file then storeForget(st) end end) then
        return false, "STORE"
    end
    if S.mode == "edit" then leaveEdit() end
    if S.drag then
        S.drag.done = true
        getCell():setDrag(nil, S.drag.player)
        S.drag = nil
    end
    S.plan, S.mode, S.home, S.prev = nil, "none", nil, nil
    checkReset()
    fire()
    return true
end

-- ===== 上一步、選取、擦 =====

function PM.undo()
    if S.mode ~= "edit" or not S.plan or not Plan.undo(S.plan) then return false end
    setSel(nil)
    fire()
    return true
end

function PM.redo()
    if S.mode ~= "edit" or not S.plan or not Plan.redo(S.plan) then return false end
    setSel(nil)
    fire()
    return true
end

-- 世界座標的長方形裡的片：正在規劃的那一層，all＝全部樓層
local function inRect(x1, y1, x2, y2, all)
    local plan, out = S.plan, {}
    local lx, ly, hx, hy = math.min(x1, x2), math.min(y1, y2), math.max(x1, x2), math.max(y1, y2)
    local z = S.level - plan.oz
    Plan.each(plan, function(p)
        local x, y = p.x + plan.ox, p.y + plan.oy
        if x >= lx and x <= hx and y >= ly and y <= hy and (all or p.z == z) then out[#out + 1] = p end
    end)
    return out
end

function PM.selectRect(x1, y1, x2, y2, all)
    if S.mode ~= "edit" then return 0 end
    setSel(inRect(x1, y1, x2, y2, all))
    fire()
    return #S.sel
end

function PM.eraseRect(x1, y1, x2, y2, all)
    if S.mode ~= "edit" then return 0 end
    local n = Plan.remove(S.plan, inRect(x1, y1, x2, y2, all))
    if n > 0 then
        setSel(nil)
        fire()
    end
    return n
end

local function shiftDown() return isShiftKeyDown ~= nil and isShiftKeyDown() == true end

-- 一區框選游標的長方形是玩家那層；換到規劃的那一層（畫面同一點，每差一層 x、y 各差 3 格，同 Cursor.areaValid）
local function toLevel(x, y, z) local s = 3 * (S.level - z) return x + s, y + s end

local startRect

local function rectPreview(tool, x1, y1, x2, y2, z)
    local ax, ay = toLevel(x1, y1, z)
    local bx, by = toLevel(x2, y2, z)
    local list, plan = inRect(ax, ay, bx, by, shiftDown()), S.plan
    local cells = {}
    for i = 1, math.min(#list, SHOW_MAX) do
        local p = list[i]
        cells[i] = { p.x + plan.ox, p.y + plan.oy, p.z + plan.oz, false }
    end
    return { cells = cells, lines = { getText(tool == "erase" and "IGUI_MBLD_PlanEraseN" or "IGUI_MBLD_PlanSelectN",
        tostring(#list)), getText("IGUI_MBLD_PlanRectHint") } }
end

local function rectDone(tool, x1, y1, x2, y2, all)
    if S.mode ~= "edit" then return end
    if tool == "erase" then PM.eraseRect(x1, y1, x2, y2, all) else PM.selectRect(x1, y1, x2, y2, all) end
    if S.tool == tool then startRect(tool) end -- 接著框下一塊，右鍵結束
end

-- ===== 拖曳物件：擺放、搬、複製；手把的框選（滑鼠框選用 Cursor.startArea） =====
-- 原版 ISBuildingObject 的子類別（同 Cursor：第一次用到才 derive，server 資料夾在 MP 客戶端比 client 晚載入）。
-- 引擎每幀呼叫 isValid → render，放開左鍵（手把 A 經 Cursor.padBuild）時 tryBuild；R 轉、右鍵或 B 取消（deactivate）。

local Drag

local function dragLines(o)
    local k = o.kind
    if k == "place" then
        local t = { getText("IGUI_MBLD_PlanPlaceHint", S.plan.name) }
        if S.home then t[2] = getText(o.joypad and "IGUI_MBLD_PlanHomePad" or "IGUI_MBLD_PlanHomeHint") end
        return t
    elseif k == "move" or k == "copy" then
        local t = { getText(k == "copy" and "IGUI_MBLD_PlanCopyHint" or "IGUI_MBLD_PlanMoveHint", tostring(#S.sel)) }
        if k == "copy" then
            local reps = o.reps or 1
            if reps > 1 then
                t[2] = getText("IGUI_MBLD_PlanCopyRow", tostring(reps), tostring(reps * #S.sel))
            elseif not o.joypad then
                t[2] = getText("IGUI_MBLD_PlanCopyDragHint")
            end
        end
        return t
    end
    return { getText(o.ax and "IGUI_MBLD_PlanRectPad2" or "IGUI_MBLD_PlanRectPad1"),
        getText(o.tool == "erase" and "IGUI_MBLD_PlanEraseN" or "IGUI_MBLD_PlanSelectN", tostring(o.n or 0)) }
end

-- 滑鼠那格（玩家那層）換到要對齊的那一層後，更新跟著游標的位置
function PM.dragMoved(o, x, y, z)
    local plan = S.plan
    if not plan then return end
    if o.kind == "place" then
        local x0, y0, z0, x1, y1 = Plan.bounds(plan)
        x0, y0, z0, x1, y1 = x0 or 0, y0 or 0, z0 or 0, x1 or 0, y1 or 0
        o.ox, o.oy, o.oz = x - math.floor((x0 + x1) / 2), y - math.floor((y0 + y1) / 2), z - z0
    else
        local lx, ly = toLevel(x, y, z)
        if o.kind == "rect" then
            o.bx, o.by = lx, ly
            if o.ax then o.n = #inRect(o.ax, o.ay, lx, ly, false) end
        else
            o.dx, o.dy = lx - o.cx, ly - o.cy
            -- 沒按住時游標跟著滑鼠走：上一次拖的份數不留到下一次按下
            if not o.isLeftDown then o.reps, o.rx, o.ry = nil, nil, nil end
        end
    end
    o.lines = dragLines(o)
end

-- 一片佔的格子（相對錨點的 { dx, dy, … }）：多格物件、車庫門整組照 footprint，配方照那一面整塊（Recipes.span）；查不到算錨點
local ANCHOR = { { 0, 0 } }
local function cellsOf(p)
    local item = S.plan.items[p.it]
    local id = item and item.id
    if type(id) ~= "string" then return ANCHOR end
    if id:sub(1, 7) == "recipe:" then
        local R, w, h = B.Recipes, nil, nil
        if R and R.span then w, h = R.span(id, p.d) end
        return w and { { 0, 0 }, { w - 1, h - 1 } } or ANCHOR
    end
    local entry = Entry.resolve(id)
    local spr = entry and Entry.face(entry, p.d)
    return spr and footprint(entry, spr, p.w) or ANCHOR
end

-- 跟著游標那份（轉過的預覽）的範圍；轉了就重算。錨點的包圍盒給每邊 64 格的上限（藍圖照錨點算），
-- 實際佔地的包圍盒給拖一排的間距：三格寬的車庫門只量錨點會被當成一格寬，相鄰兩份疊在一起、照圖只蓋得了一扇
local function measure(o)
    local x0, y0, x1, y1, fx0, fy0, fx1, fy1
    for _, p in ipairs(o.preview) do
        x0, y0 = math.min(x0 or p.x, p.x), math.min(y0 or p.y, p.y)
        x1, y1 = math.max(x1 or p.x, p.x), math.max(y1 or p.y, p.y)
        for _, c in ipairs(cellsOf(p)) do
            local cx, cy = p.x + c[1], p.y + c[2]
            fx0, fy0 = math.min(fx0 or cx, cx), math.min(fy0 or cy, cy)
            fx1, fy1 = math.max(fx1 or cx, cx), math.max(fy1 or cy, cy)
        end
    end
    o.px0, o.py0, o.px1, o.py1 = x0, y0, x1, y1
    o.bw, o.bh, o.rx, o.ry = fx1 - fx0 + 1, fy1 - fy0 + 1, nil, nil
end

-- 拖出來那一列每片的最終位置（preview[i] 對應 sel[i]，第 g 份接在 to[g * #preview + i]）
local function rowTo(o, reps, sx, sy)
    local to, n = {}, #o.preview
    for g = 0, reps - 1 do
        for i, p in ipairs(o.preview) do to[g * n + i] = { p.x + o.dx + g * sx, p.y + o.dy + g * sy, p.z, p.d } end
    end
    return to
end

-- 複製中按住左鍵拖：沿主軸排成一列。原版按住期間每幀把滑鼠那格傳給 rotateMouse，
-- 放下的格子停在按下那格 o.square（ISBuildingObject.lua:114-139）。份數先夾到放得下（片數、主軸每邊 64 格），放下時不會整個不做。
-- 片數只算會新增的：第 0 份和既有片一模一樣的放下時略過（Plan.copyTo），不佔額度（原位按下，或轉了也不變的無方向地板）
function PM.dragRow(o, x, y)
    local plan, at = S.plan, o.square
    if o.joypad or not plan or not at or not o.bw or #S.sel == 0 then return end
    local dx, dy = x - at:getX(), y - at:getY()
    if dx == o.rx and dy == o.ry then return end
    o.rx, o.ry = dx, dy
    local reps, sx, sy
    if math.abs(dx) >= math.abs(dy) then
        reps, sx, sy = 1 + math.floor(math.abs(dx) / o.bw), dx < 0 and -o.bw or o.bw, 0
    else
        reps, sx, sy = 1 + math.floor(math.abs(dy) / o.bh), 0, dy < 0 and -o.bh or o.bh
    end
    reps = math.min(reps, math.floor((Plan.MAX_PIECES - plan.n + Plan.dupes(plan, S.sel, rowTo(o, 1, 0, 0))) / #S.sel))
    local x0, y0, _, x1, y1 = Plan.bounds(plan)
    local lo, hi, a0, a1, step = x0, x1, o.px0 + o.dx, o.px1 + o.dx, sx
    if sx == 0 then lo, hi, a0, a1, step = y0, y1, o.py0 + o.dy, o.py1 + o.dy, sy end
    while reps > 1 and math.max(hi, a1, a1 + (reps - 1) * step) - math.min(lo, a0, a0 + (reps - 1) * step) >= Plan.MAX_SIDE do
        reps = reps - 1
    end
    reps = math.max(reps, 1)
    o.sx, o.sy = sx, sy
    if reps ~= (o.reps or 1) then
        o.reps = reps
        o.lines = dragLines(o)
    end
end

local function endDrag(o)
    o.done = true
    if S.drag == o then S.drag = nil end
    getCell():setDrag(nil, o.player)
end

-- 「搬」的那張放下或取消後回到原本的畫面（S.back，PM.pickUp 記）：規劃中搬的回規劃，工坊原本開著就重開；
-- 定住時從藍圖面板搬的把面板開回來（面板一開工坊就收起，兩條互斥）。延後一個 tick：
-- dragCancel 是在 setDrag 的 deactivate 回呼裡被叫的，PM.toggle 自己也會 setDrag(nil)，當場回規劃會巢狀進 toggle。
-- 玩家拿了別的游標（工坊的油漆、配方）也會走 dragCancel（IsoCell.setDrag 換游標先停用舊的，IsoCell.java:2558-2575）：
-- 下一個 tick 手上有游標就不做，否則 toggle 會把它收掉或改成畫進藍圖。
-- saved＝放下時存檔成功（取消的不存、內容同拿起前存好的那份，傳 true）：沒存成時回規劃後照樣算沒存
local function resume(saved)
    local back, plan, pn = S.back, S.plan, PM.playerNum or 0
    S.back = nil
    if not back then return end
    local function go()
        Events.OnTick.Remove(go)
        -- 這一 tick 之間換了張、收起、又拿起來或拿了別的游標：不做
        if S.plan ~= plan or S.mode ~= "fixed" or S.drag or getCell():getDrag(pn) then return end
        if back.panel then return openPanel() end
        if not PM.toggle(pn) then return end
        if not saved then S.savedRev = nil end -- toggle 把 savedRev 設成現在的 rev，PM.unsaved 會當成已存
        local W = B.Window
        if back.win and W and W.open then W.open(pn) end
    end
    Events.OnTick.Add(go)
end

-- 定位：原點設好、存檔、記進這個存檔的地上藍圖
local function settle(ox, oy, oz)
    local plan = S.plan
    plan.ox, plan.oy, plan.oz = ox, oy, oz
    S.mode, S.home, S.prev = "fixed", nil, nil
    local saved = persist()
    checkReset()
    fire()
    resume(saved == true)
end

-- 搬、複製中按旋轉只轉預覽（另做一份片，位置照 Plan.turned），放下才照預覽改藍圖；取消時原片完全沒動
local function turnedCopy(list)
    local to, stuck = Plan.turned(S.plan, list, safeTurn)
    if stuck > 0 then say(getText("IGUI_MBLD_PlanStuck", tostring(stuck))) end
    local out = {}
    for i, p in ipairs(list) do
        local t = to[i]
        out[i] = { x = t[1], y = t[2], z = t[3], d = t[4], o = p.o, it = p.it, w = p.w }
    end
    return out
end

function PM.dragDrop(o, x, y, z)
    if o.done or not S.plan then return end
    if o.kind == "place" then
        PM.dragMoved(o, x, y, z)
        endDrag(o)
        return settle(o.ox, o.oy, o.oz)
    end
    if o.kind == "rect" then
        local lx, ly = toLevel(x, y, z)
        if not o.ax then
            o.ax, o.ay = lx, ly
            PM.dragMoved(o, x, y, z)
            return
        end
        endDrag(o)
        return rectDone(o.tool, o.ax, o.ay, lx, ly, false)
    end
    -- 放開那一幀 isLeftDown 已經是 false，dragMoved 會把份數歸零：先記下拖出來的那一列
    local reps, sx, sy = o.reps or 1, o.sx or 0, o.sy or 0
    PM.dragMoved(o, x, y, z)
    endDrag(o)
    if o.dx == 0 and o.dy == 0 and (o.turns or 0) == 0 and reps == 1 then return fire() end
    -- 照預覽的最終位置一次做完：搬（或複製）和轉、拖出來的每一份算同一步，上一步一次拿掉；上限與重複都照最終位置算
    local to = rowTo(o, reps, sx, sy)
    local res, why
    if o.kind == "copy" then
        res, why = Plan.copyTo(S.plan, S.sel, to)
    else
        res, why = Plan.moveTo(S.plan, S.sel, to)
    end
    if not res then say(whyText(why)) end
    -- 全部和既有片重複、一片都沒加時，選取留著原片
    if o.kind == "copy" and res and #res > 0 then setSel(res) end
    fire()
end

function PM.dragRotate(o)
    if o.done or not S.plan then return end
    if o.kind == "place" then
        -- 轉是繞包圍盒的角（Plan.turned），長方形轉完中心會偏；滑鼠不動時 isValid 不會再叫 dragMoved，
        -- 這裡照滑鼠那格（isValid 記的 kx、ky、kz）重新對齊，畫面和放下的位置才一致
        if rotate(allPieces(S.plan)) then
            o.turns = (o.turns or 0) + 1
            if o.kx then PM.dragMoved(o, o.kx, o.ky, o.kz) end
        end
    elseif (o.kind == "move" or o.kind == "copy") and #S.sel > 0 then
        local rx, ry = o.rx, o.ry
        o.preview = turnedCopy(o.preview or S.sel)
        o.turns = (o.turns or 0) + 1
        measure(o)
        -- 按住拖排中轉：照同一個位移馬上重排。轉完直接放開時中間沒有 rotateMouse，放下才不會用轉之前的份數與間距
        if rx and o.square then PM.dragRow(o, o.square:getX() + rx, o.square:getY() + ry) end
    end
end

-- 右鍵、B、換了別的游標：擺放取消時轉過的撤回、搬的回原位置、從藍圖庫擺的拿掉
function PM.dragCancel(o)
    if S.drag == o then S.drag = nil end
    if o.done then return end
    o.done = true
    if o.kind == "rect" then
        if S.tool == o.tool then S.tool = "draw" end
        return fire()
    end
    if o.kind ~= "place" then return fire() end
    local plan, prev = S.plan, S.prev
    for _ = 1, o.turns or 0 do Plan.undo(plan) end
    S.home, S.prev = nil, nil
    if prev then
        plan.ox, plan.oy, plan.oz = prev.ox, prev.oy, prev.oz
        S.mode = "fixed"
    else
        S.plan, S.mode = nil, "none"
    end
    checkReset()
    fire()
    resume(true)
end

local function dragClass()
    if Drag then return Drag end
    Drag = ISBuildingObject:derive("MinidoracatBuilderPlanDrag")
    function Drag:isValid(square)
        self.overUI = not self.joypad and Cursor.mouseOverUI(nil)
        local x, y, z = square:getX(), square:getY(), square:getZ()
        if x ~= self.kx or y ~= self.ky or z ~= self.kz then
            self.kx, self.ky, self.kz = x, y, z
            PM.dragMoved(self, x, y, z)
        end
        return not self.overUI
    end
    function Drag:render() end -- PlanGhost 畫
    function Drag:getSprite() return nil end
    function Drag:rotateMouse(x, y)
        if self.kind == "copy" then PM.dragRow(self, x, y) end
    end
    function Drag:rotateKey(key)
        if getCore():isKey(KeybindId.ROTATE_BUILDING, key) then PM.dragRotate(self) end
    end
    function Drag:tryBuild(x, y, z) PM.dragDrop(self, x, y, z) end
    function Drag:deactivate() PM.dragCancel(self) end
    function Drag:onJoypadPressButton(joypadIndex, joypadData, button)
        if button == Joypad.AButton then return Cursor.padBuild(self) end
        if button == Joypad.RBumper or button == Joypad.LBumper then return PM.dragRotate(self) end
        if button == Joypad.XButton and self.kind == "place" and S.home then return PM.placeHome() end
        ISBuildingObject.onJoypadPressButton(self, joypadIndex, joypadData, button)
    end
    function Drag:getAPrompt() return getText(self.kind == "rect" and "IGUI_MBLD_PlanSelect" or "IGUI_MBLD_PlanDrop") end
    function Drag:getXPrompt()
        if self.kind == "place" and S.home then return getText("IGUI_MBLD_PlanHome") end
        return nil
    end
    function Drag:getRBPrompt()
        if self.kind ~= "rect" then return getText("IGUI_MBLD_PlanRotate") end
        return nil
    end
    function Drag:beforeWorldRender() local R = B.RoofShow if R then R.before(self.player) end end
    return Drag
end

local function startDrag(kind, playerNum)
    local p = getSpecificPlayer(playerNum)
    if not p then return nil end
    local cls = dragClass()
    local o = setmetatable({}, cls)
    cls.__index = cls
    o:init()
    o.character, o.player, o.kind = p, playerNum, kind
    o.dragNilAfterPlace = false
    o.isYButtonResetCursor = true
    o.joypad = JoypadState.players[playerNum + 1] ~= nil
    if S.drag then
        local old = S.drag
        S.drag = nil
        old.done = true
    end
    S.drag = o
    o.lines = dragLines(o)
    getCell():setDrag(o, playerNum)
    return o
end

startRect = function(tool)
    local pn = PM.playerNum or 0
    if JoypadState.players[pn + 1] then
        local o = startDrag("rect", pn)
        if o then o.tool = tool end
        return
    end
    local cb = { side = Plan.MAX_SIDE }
    cb.preview = function(x1, y1, x2, y2, z) return rectPreview(tool, x1, y1, x2, y2, z) end
    cb.release = function(x1, y1, x2, y2, z)
        local ax, ay = toLevel(x1, y1, z)
        local bx, by = toLevel(x2, y2, z)
        rectDone(tool, ax, ay, bx, by, shiftDown())
    end
    cb.cancel = function()
        if S.tool == tool then
            S.tool = "draw"
            fire()
        end
    end
    local c = Cursor.startArea(pn, cb)
    if c then c.planTool = tool end
end

function PM.setTool(tool)
    if S.mode ~= "edit" then return end
    S.tool = tool
    fire()
    if tool == "draw" then
        stopTool()
        local W = B.Window
        if W and W.open and not (W.visible and W.visible()) then W.open(PM.playerNum or 0) end
    else
        startRect(tool)
    end
end

-- 選到的片：搬、複製跟著游標；轉、刪除當場做
local function selCenter()
    local plan, x0, y0, x1, y1 = S.plan, nil, nil, nil, nil
    for _, p in ipairs(S.sel) do
        x0, y0 = math.min(x0 or p.x, p.x), math.min(y0 or p.y, p.y)
        x1, y1 = math.max(x1 or p.x, p.x), math.max(y1 or p.y, p.y)
    end
    return plan.ox + math.floor((x0 + x1) / 2), plan.oy + math.floor((y0 + y1) / 2)
end

function PM.moveSel(copy)
    if S.mode ~= "edit" or #S.sel == 0 then return false end
    stopTool()
    local o = startDrag(copy and "copy" or "move", PM.playerNum or 0)
    if not o then return false end
    o.cx, o.cy = selCenter()
    o.dx, o.dy, o.preview, o.turns = 0, 0, S.sel, 0
    measure(o)
    o.lines = dragLines(o)
    return true
end

function PM.rotateSel()
    if S.mode ~= "edit" or #S.sel == 0 then return false end
    return rotate(S.sel)
end

function PM.deleteSel()
    if S.mode ~= "edit" or #S.sel == 0 then return 0 end
    local n = Plan.remove(S.plan, S.sel)
    setSel(nil)
    fire()
    return n
end

-- 選到的片另存成一張藍圖（位置照舊，之後可以放回原位置）。回 檔名，或 nil, 原因
function PM.saveSelAs(name)
    local plan = S.plan
    if S.mode ~= "edit" or #S.sel == 0 then return nil, "EMPTY" end
    local np = Plan.new(name)
    np.ox, np.oy, np.oz = plan.ox, plan.oy, plan.oz
    for _, p in ipairs(S.sel) do
        local item = plan.items[p.it]
        if item and #Plan.at(plan, p.x, p.y, p.z) > 0 then
            Plan.add(np, p.x, p.y, p.z, p.d, p.o, Plan.item(np, item.id, item), p.w)
        end
    end
    Plan.forget(np)
    local file, why = PlanFile.fileName(np.name)
    local ok = false
    if file then ok, why = PlanFile.save(np, file) end
    if not ok then
        print(LOG .. "plan save failed: " .. tostring(why or "FILE"))
        say(getText("IGUI_MBLD_PlanSaveFail"))
        return nil, why or "FILE"
    end
    say(getText("IGUI_MBLD_PlanSavedAs", np.name))
    return file
end

-- 名稱框（框架 Dialog）：預設照地上那張的名稱
function PM.askSaveSel()
    local UI = B.Window and B.Window.ui and B.Window.ui({ "dialog" })
    if not UI then return say(getText("IGUI_MBLD_NeedFramework")) end
    UI.Dialog.show({ title = getText("IGUI_MBLD_PlanSaveSel"), text = getText("IGUI_MBLD_PlanSaveSelText"),
        input = { text = S.plan.name }, confirmText = getText("IGUI_MBLD_PlanSave"), cancelText = getText("UI_Cancel"),
        theme = UI.Theme.create({ variant = "dark" }), opaque = true,
        onResult = function(ok, text) if ok then PM.saveSelAs(text) end end })
end

-- ===== 擺放 =====

local function beginPlace(plan, playerNum, prev)
    S.back = nil
    local p = getSpecificPlayer(playerNum)
    if not p then return false end
    if S.mode == "edit" then leaveEdit() end
    local home
    if plan.ox then
        local dx, dy = plan.ox - p:getX(), plan.oy - p:getY()
        if dx * dx + dy * dy <= HOME_RANGE * HOME_RANGE then home = { plan.ox, plan.oy, plan.oz } end
    end
    S.plan, S.mode, S.home, S.prev = plan, "place", home, prev
    plan.ox, plan.oy, plan.oz = nil, nil, nil
    setSel(nil)
    checkReset()
    local o = startDrag("place", playerNum)
    if not o then
        PM.dragCancel({ kind = "place" })
        return false
    end
    local W = B.Window -- 擺放時建造工坊視窗收起，不擋地上
    if W and W.close then W.close() end
    fire()
    return true
end

-- 「放回原位置」：擺放中、原位置離玩家 100 格內
function PM.placeHome()
    local o, h = S.drag, S.home
    if not (o and o.kind == "place" and h) then return false end
    endDrag(o)
    settle(h[1], h[2], h[3])
    return true
end

-- 「搬」：地上的藍圖回到跟著游標（取消就回原位置）。規劃中改的先存，存不了留在規劃，回 false, 原因
-- （不先存的話：擺放中不存檔，跟著游標時換一張會把沒存的改動整個丟掉）。規劃中搬的，放下或取消後回規劃（resume）
function PM.pickUp(playerNum)
    PM.playerNum = playerNum or PM.playerNum or 0
    local plan = S.plan
    if not plan or S.mode == "place" or not plan.ox then return false end
    local back
    local W = B.Window
    if S.mode == "edit" then
        local ok, why = persist()
        if not ok then return false, why end
        -- 工坊開著，或剛被「藍圖」鈕收起（W.openPlans 開面板時關掉工坊、記 plansClosed；面板「搬」走到這裡時已看不到）
        back = { win = W ~= nil and W.visible ~= nil and (W.visible() or W.plansClosed == true) }
    else
        -- 定住時從藍圖面板搬：面板在 pickUp 成功後才關（PlanPanel 的 act("move")），這時還開著
        local Panel = B.PlanPanel
        if Panel and Panel.visible and Panel.visible() then back = { panel = true } end
    end
    if W then W.plansClosed = nil end -- 記號只用這一次（面板、藍圖庫關掉時 PlanLibrary.plansGone 也清）
    local ok = beginPlace(plan, PM.playerNum, { ox = plan.ox, oy = plan.oy, oz = plan.oz })
    S.back = ok and back or nil
    return ok
end

local function sameFile(cur, plan)
    return cur ~= nil and cur ~= plan and plan.file ~= nil and cur.file == plan.file
end

-- 同一個檔的另一份換上定住的地上那張：原點照包圍盒的角對齊（位置不動），照圖蓋的狀態重算
local function swapIn(plan)
    local cur = S.plan
    local cx, cy, cz = Plan.bounds(cur)
    local nx, ny, nz = Plan.bounds(plan)
    plan.ox, plan.oy = cur.ox + (cx or 0) - (nx or 0), cur.oy + (cy or 0) - (ny or 0)
    plan.oz = cur.oz + (cz or 0) - (nz or 0)
    S.plan = plan
    setSel(nil)
    checkReset()
end

-- 藍圖庫把同一個檔存成另一份之後（PlanLibrary）：地上那張定住的換成這份，不拿起來；不換的話之後地上那張存檔
-- 會把舊內容寫回去。回 true；正在規劃回 false, "EDITING"（沒存的改動比檔案新，不換）；
-- 不是同一個檔的另一份、地上沒有、正跟著游標回 false
function PM.adopt(plan)
    if not plan or not sameFile(S.plan, plan) then return false end
    if S.mode == "edit" then return false, "EDITING" end
    if S.mode ~= "fixed" then return false end
    swapIn(plan)
    persist() -- 藍圖檔的 pos 對齊記錄的角（藍圖庫存的那份帶的是它自己的 pos）；存不了已說過，下次存檔再寫
    fire()
    return true
end

-- 從藍圖庫擺到地上：地上已經有別張時先問（換的話先存檔收起那張）；同一張就是「搬」。
-- 同一個檔的另一份（重新匯入、重新讀過）：定住的換成新的這份、位置不動再拿起來；地上那張正在規劃時，
-- 沒存的改動比檔案新，新的這份當成另一張（之後存檔另取檔名），照「先問、存檔收起、再擺」
function PM.place(plan, playerNum)
    PM.playerNum = playerNum or PM.playerNum or 0
    if not plan then return false end
    local detach = false
    if sameFile(S.plan, plan) then
        if S.mode == "edit" then
            detach = true
        else
            if S.mode == "place" and S.drag then getCell():setDrag(nil, S.drag.player) end
            if S.plan and S.plan.ox then
                swapIn(plan)
                return PM.pickUp(PM.playerNum)
            end
        end
    end
    local cur = S.plan
    if cur and cur == plan then
        if S.mode == "place" then return true end
        return PM.pickUp(PM.playerNum)
    end
    if not cur then return beginPlace(plan, PM.playerNum, nil) end
    local UI = B.Window and B.Window.ui and B.Window.ui({ "dialog" })
    if not UI then
        say(getText("IGUI_MBLD_NeedFramework"))
        return false
    end
    local untitled = getText("IGUI_MBLD_PlanUntitled")
    UI.Dialog.show({ title = getText("IGUI_MBLD_PlanTitle"),
        text = getText("IGUI_MBLD_PlanSwap", cur.name ~= "" and cur.name or untitled, plan.name ~= "" and plan.name or untitled),
        confirmText = getText("IGUI_MBLD_PlanSwapGo"), cancelText = getText("UI_Cancel"),
        theme = UI.Theme.create({ variant = "dark" }), opaque = true,
        onResult = function(ok)
            if not ok then return end
            if not PM.clear() then return end -- 存檔失敗：地上那張留著，不換
            if detach then plan.file = nil end
            beginPlace(plan, PM.playerNum, nil)
        end })
    return true
end

-- ===== 工具列（家族框架 Window；畫面上方置中，不擋建造視窗與下方的快選列） =====

local Bar = {}

local function barKey()
    if S.mode == "edit" then return "e" .. S.tool .. (#S.sel > 0 and "s" or "") .. (S.hidden and "h" or "") end
    if S.mode == "place" and S.drag and S.drag.kind == "place" then return "p" .. (S.home and "h" or "") end
    return nil
end

local function buildBar(UI)
    local GAP, PAD = 6, 8
    local theme = UI.Theme.create({ variant = "dark" })
    local col = theme.colors
    local font = UIFont.Small
    local tm = getTextManager()
    local fh = tm:getFontHeight(font)
    local btnH = fh + 10
    local rows, row = {}, nil
    local function newRow() row = {} rows[#rows + 1] = row end
    local function btn(key, fn, ...)
        local opts = (...) or {}
        row[#row + 1] = UI.Button.new({ title = getText(key), theme = theme, font = font, height = btnH, style = opts.style,
            active = opts.active, onClick = function() fn() end })
    end
    -- 每幀照現況畫的文字（片數、樓層、選了幾片）：寬度照 sample 量
    local function text(sample, fn, ...)
        local warnFn = ...
        local el = ISPanel:new(0, 0, tm:MeasureStringX(font, sample) + 4, btnH)
        el:initialise()
        el.background = false
        el.render = function(self)
            local c = warnFn and warnFn() and col.warning or col.text
            self:drawText(fn(), 2, math.floor((btnH - fh) / 2), c.r, c.g, c.b, 1, font)
        end
        row[#row + 1] = el
    end
    local title
    if S.mode == "edit" then
        title = getText("IGUI_MBLD_PlanBarTitle")
        newRow()
        btn("IGUI_MBLD_PlanDraw", function() PM.setTool("draw") end, { active = S.tool == "draw" })
        btn("IGUI_MBLD_PlanSelect", function() PM.setTool("select") end, { active = S.tool == "select" })
        btn("IGUI_MBLD_PlanErase", function() PM.setTool("erase") end, { active = S.tool == "erase" })
        btn("IGUI_MBLD_PlanUndo", PM.undo)
        btn("IGUI_MBLD_PlanRedo", PM.redo)
        btn("IGUI_MBLD_PlanDown", function() PM.setLevel((S.level or 0) - 1) end)
        text(getText("IGUI_MBLD_PlanFloor", "-32"), function() return getText("IGUI_MBLD_PlanFloor", tostring((S.level or 0) + 1)) end)
        btn("IGUI_MBLD_PlanUp", function() PM.setLevel((S.level or 0) + 1) end)
        newRow()
        -- 快到單張上限變色（九成）
        text(getText("IGUI_MBLD_PlanCount", "4,096"), function()
            return getText("IGUI_MBLD_PlanCount", tostring(S.plan and S.plan.n or 0))
        end, function() return S.plan and S.plan.n >= Plan.MAX_PIECES * 0.9 end)
        btn("IGUI_MBLD_PlanLibrary", function()
            local L = B.PlanLibrary
            if L and L.open then L.open(PM.playerNum or 0) end
        end)
        btn(S.hidden and "IGUI_MBLD_PlanShow" or "IGUI_MBLD_PlanHide", function() PM.setHidden(not S.hidden) end)
        btn("UI_Cancel", PM.askCancel)
        btn("IGUI_MBLD_PlanDone", PM.askFinish, { style = "primary" })
        if #S.sel > 0 then
            newRow()
            text(getText("IGUI_MBLD_PlanSelN", "4,096"), function() return getText("IGUI_MBLD_PlanSelN", tostring(#S.sel)) end)
            btn("IGUI_MBLD_PlanMove", function() PM.moveSel(false) end)
            btn("IGUI_MBLD_PlanRotate", PM.rotateSel)
            btn("IGUI_MBLD_PlanCopy", function() PM.moveSel(true) end)
            btn("IGUI_MBLD_PlanDelete", PM.deleteSel, { style = "danger" })
            btn("IGUI_MBLD_PlanSaveSel", PM.askSaveSel)
        end
    else
        title = getText("IGUI_MBLD_PlanPlaceTitle")
        newRow()
        btn("IGUI_MBLD_PlanRotate", function() if S.drag then PM.dragRotate(S.drag) end end)
        if S.home then btn("IGUI_MBLD_PlanHome", PM.placeHome) end
        btn("UI_Cancel", function() if S.drag then getCell():setDrag(nil, S.drag.player) end end)
    end
    local w = 0
    for _, r in ipairs(rows) do
        local rw = PAD
        for _, el in ipairs(r) do rw = rw + el.width + GAP end
        w = math.max(w, rw - GAP + PAD)
    end
    local win = UI.Window.new({ x = 0, y = 0, width = w, height = 100, title = title, theme = theme, opaque = true,
        onClose = function()
            if S.mode == "edit" then
                -- 視窗已經被 close 藏起來：先重建，存檔失敗或問存哪裡時按「取消」，「完成」還按得到（完成了 fire 會收掉）
                Bar.key = nil
                PM.refreshBar()
                PM.askFinish()
            elseif S.drag then
                getCell():setDrag(nil, S.drag.player)
            end
        end })
    -- 手把 B：焦點還給角色，工具列留著（框架 Focus 先問 onEscape）
    win.onEscape = function()
        if UI.Focus and UI.Focus.releaseJoypad then UI.Focus.releaseJoypad(win) end
        return true
    end
    local y = win:contentTop() + PAD
    for _, r in ipairs(rows) do
        local x = PAD
        for _, el in ipairs(r) do
            el:setX(x)
            el:setY(y)
            win:addChild(el)
            x = x + el.width + GAP
        end
        y = y + btnH + GAP
    end
    win:setHeight(y - GAP + PAD)
    local sw = getCore():getScreenWidth()
    win:setX(Bar.x or math.floor((sw - w) / 2))
    win:setY(Bar.y or 8)
    win:addToUIManager()
    Bar.win = win
end

function PM.refreshBar()
    local key = barKey()
    if key == Bar.key then return end
    Bar.key = key
    local old = Bar.win
    if old then
        Bar.win = nil
        Bar.x, Bar.y = old:getX(), old:getY()
        old.onClose = nil
        old:setVisible(false)
        old:removeFromUIManager()
    end
    if not key then return end
    local W = B.Window
    local UI = W and W.ui and W.ui({ "window", "controls" })
    if not UI then return end -- 框架缺或太舊：工具列不出，按鍵照樣能用（UI AGENTS 契約 3）
    local ok, err = pcall(buildBar, UI)
    if not ok then print(LOG .. "plan toolbar build failed: " .. tostring(err)) end
end

-- ===== 按鍵（登記與判斷照 Window.initBinds／onKeyPressed；只有玩家 0 有鍵盤） =====

-- 上一步、下一步預設 Ctrl+Z、Ctrl+Y（keyBinding 的 ctrl 欄，MainOptions.lua:3479）；刪除選取 Delete；隱藏預設不綁
function PM.initBinds()
    if keyBinding == nil then return end
    local K = Keyboard or {}
    table.insert(keyBinding, { value = PM.BIND_UNDO, key = K.KEY_Z or 0, ctrl = true })
    table.insert(keyBinding, { value = PM.BIND_REDO, key = K.KEY_Y or 0, ctrl = true })
    table.insert(keyBinding, { value = PM.BIND_DELETE, key = K.KEY_DELETE or 0 })
    table.insert(keyBinding, { value = PM.BIND_HIDE, key = K.KEY_NONE or 0 })
end

function PM.onKeyPressed(key)
    if key == nil or key == 0 or not S.plan then return end
    local core = getCore()
    if core:isKey(PM.BIND_HIDE, key) then return PM.setHidden(not S.hidden) end
    if S.mode ~= "edit" then return end
    if core:isKey(PM.BIND_UNDO, key) then
        PM.undo()
    elseif core:isKey(PM.BIND_REDO, key) then
        PM.redo()
    elseif core:isKey(PM.BIND_DELETE, key) then
        PM.deleteSel()
    elseif core:isKey("MinidoracatBuilder_LayerUp", key) then -- 規劃時換層鍵換規劃的樓層（Cursor.rotateKey 這時不處理）
        PM.setLevel(S.level + 1)
    elseif core:isKey("MinidoracatBuilder_LayerDown", key) then
        PM.setLevel(S.level - 1)
    end
end

if not PM.loaded then
    PM.loaded = true
    Events.OnGameBoot.Add(function() MinidoracatBuilder.PlanMode.initBinds() end)
    Events.OnKeyPressed.Add(function(key) MinidoracatBuilder.PlanMode.onKeyPressed(key) end)
    Events.OnGameStart.Add(function()
        local ok, err = pcall(MinidoracatBuilder.PlanMode.restore)
        if not ok then print(LOG .. "ground plan restore failed: " .. tostring(err)) end
    end)
end

return PM
