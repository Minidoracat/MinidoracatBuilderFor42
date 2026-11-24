require "TimedActions/ISBaseTimedAction"

-- 排在建造請求第 i 項（第 2 項起）的建造動作前面：排隊當下沒排進走路的（地板、屋頂旁邊沒地方站或還沒有格子；
-- 任何種類「現在就在旁邊」），輪到時才找站位、把走路插在自己後面（Client.stand）。
-- 不定義 complete：只在客戶端跑，不是網路動作（LuaTimedActionNew 看類別有沒有 complete）
MinidoracatBuilderStandAction = ISBaseTimedAction:derive("MinidoracatBuilderStandAction")

local WAIT_MS = 2000 -- 多人等前一格同步到客戶端最多這麼久，之後照樣找站位

function MinidoracatBuilderStandAction:isValid()
    return self.character:getVehicle() == nil
end

local function ready(self)
    local now = getTimestampMs()
    if not self.since or now < self.since then self.since = now end -- 時鐘往回調（家族 pitfalls）
    return now - self.since >= WAIT_MS or MinidoracatBuilder.Client.standReady(self.n, self.i)
end

-- 引擎的 waitToStart 丟錯時不會開始，佇列就卡住：丟錯當作可以開始。回 false 後引擎還可能因角色狀態
-- （shouldWaitToStartTimedAction）下一幀再叫，錯誤只印一次
function MinidoracatBuilderStandAction:waitToStart()
    local ok, go = pcall(ready, self)
    if not ok and not self.warned then
        self.warned = true
        print("[MinidoracatBuilderFor42] stand wait failed n=" .. tostring(self.n) .. " i=" .. tostring(self.i) .. ": " .. tostring(go))
    end
    return ok and not go
end

function MinidoracatBuilderStandAction:start()
    self:beginAddingActions()
    local ok, stood = pcall(MinidoracatBuilder.Client.stand, self.n, self.i)
    self:endAddingActions()
    if not ok then print("[MinidoracatBuilderFor42] stand failed: " .. tostring(stood)) end
    if ok and stood then self:forceComplete() else self:forceStop() end
end

-- start 裡已經結束；走到這裡＝start 中途出錯
function MinidoracatBuilderStandAction:update()
    self:forceStop()
end

function MinidoracatBuilderStandAction:new(character, n, i)
    local o = ISBaseTimedAction.new(self, character)
    o.n, o.i = n, i
    return o
end
