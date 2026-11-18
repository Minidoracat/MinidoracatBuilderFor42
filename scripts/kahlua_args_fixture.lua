-- scripts/verify_local.py「呼叫自己的 Lua 函式時固定參數傳齊」驗自己用的假呼叫：不會被執行、不進 MOD。
-- 行尾有驚嘆號註解的行要被報成少傳，其他行不能報；驚嘆號後面接的字是尾端呼叫那一筆 key 最後記的函式名。
-- 對的是 MOD 現在的定義：Queue.push、Cursor.send 的固定參數各 3 個，L.saveFirst 2 個，Check.item 4 個，
-- Check.safehouse 3 個，PlanMode 的 selectRect 5 個；這幾個定義改了固定參數個數時，這個檔跟著改。
local B = MinidoracatBuilder
local Q, L = B.Queue, B.PlanLibrary -- 平行指派的別名
local C = B.Check
local function one() return 1 end
local sh = C.safehouse -- 函式別名：之後 C 換成別的模組，sh 還是 Check.safehouse

Q.push(p, name) --!
Q.push(p, name, anchors)
L.saveFirst(pn) --!
L.saveFirst(pn, go)
B.Queue.push(p, one()) --!one
B.Queue.push(p, one():rep(2)) --!?
C.item(p, name, d) --!
C.item(p, name, d, anchor)
local function inner()
    local C = B.Cursor -- 同名的別名在這個函式裡指另一個模組
    C.send(p, name) --!
    C.send(p, name, anchors)
    sh(p, c) --!
    sh(p, c, true)
end
C.item(p, name, d, anchor) -- 出了那個函式 C 又是 Check
C.item(p) --!
pcall(Q.push, p, name) --!
pcall(Q.push, p, name, anchors)
local function shadow()
    local B = {} -- 這個 B 不是 MOD 的根
    B.Queue.push(p, name)
end
local function sameLine()
    local M = B.PlanMode; M.selectRect(1, 2) --!
end
