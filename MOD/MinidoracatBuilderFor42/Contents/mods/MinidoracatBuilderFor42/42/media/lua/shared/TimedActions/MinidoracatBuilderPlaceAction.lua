require "TimedActions/ISBaseTimedAction"

-- 蓋一項（建造請求裡的第 i 項）。參數只放 nonce 與第幾項；項目、朝向、座標都在伺服器收到的請求裡（Server.intent），
-- complete() 只在伺服器跑（單機在本機），交給 MinidoracatBuilder.Server.complete。
-- 這個檔頂層不 require server 的檔（客戶端載不到）：用到時才從全域表找。
MinidoracatBuilderPlaceAction = ISBaseTimedAction:derive("MinidoracatBuilderPlaceAction")

-- 客戶端自己送出的那筆請求（畫面用：轉身、進度條）；伺服器上沒有
local function pending(self)
    local C = MinidoracatBuilder and MinidoracatBuilder.Client
    local b = C and C.pending
    if b and b.n == self.n then return b end
    return nil
end

function MinidoracatBuilderPlaceAction:isValid()
    return self.character:getVehicle() == nil
end

function MinidoracatBuilderPlaceAction:waitToStart()
    local b = pending(self)
    local c = b and b.cells[self.i]
    if c then self.character:faceLocation(c[1], c[2]) end
    return self.character:shouldBeTurning()
end

function MinidoracatBuilderPlaceAction:start()
    self:setActionAnim("Build")
    self.sound = self.character:playSound("Hammering")
end

local function stopSound(self)
    if self.sound and self.sound ~= 0 then self.character:stopOrTriggerSound(self.sound) end
    self.sound = nil
end

function MinidoracatBuilderPlaceAction:stop()
    stopSound(self)
    ISBaseTimedAction.stop(self)
end

function MinidoracatBuilderPlaceAction:perform()
    stopSound(self)
    ISBaseTimedAction.perform(self)
end

function MinidoracatBuilderPlaceAction:complete()
    local S = MinidoracatBuilder and MinidoracatBuilder.Server
    return S ~= nil and S.complete(self.character, self.n, self.i) == true
end

-- 伺服器（與單機）照請求算（即時動作也要等區域系統喚醒）；MP 客戶端照自己送出的項目算，只給進度條用，
-- 完成時間由伺服器決定
function MinidoracatBuilderPlaceAction:getDuration()
    local S = MinidoracatBuilder and MinidoracatBuilder.Server
    if S then return S.duration(self.character, self.n, self.i) end
    if self.character:isTimedActionInstant() then return 1 end
    local b = pending(self)
    return MinidoracatBuilder.Entry.duration(b and b.kind, self.character)
end

function MinidoracatBuilderPlaceAction:new(character, n, i)
    local o = ISBaseTimedAction.new(self, character)
    o.n, o.i = n, i
    -- 伺服器在 parse 時就會跑 new()（這時還沒驗連線），只存欄位；它另外呼叫 getDuration（NetTimedAction.java:70-83）
    if not isServer() then o.maxTime = o:getDuration() end
    return o
end
