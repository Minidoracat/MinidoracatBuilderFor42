require "TimedActions/ISBaseTimedAction"

-- 拆一件（第五階段）。參數只放 nonce；拆哪一件在伺服器收到的拆除請求裡（Server.dismantleIntent），complete() 只在
-- 伺服器跑（單機在本機），交給 MinidoracatBuilder.Server.dismantle。
-- 這個檔頂層不 require server 的檔（客戶端載不到）：用到時才從全域表找。
MinidoracatBuilderDismantleAction = ISBaseTimedAction:derive("MinidoracatBuilderDismantleAction")

-- 客戶端自己送出的那筆拆除請求（畫面用：轉身、進度條、還在不在）；伺服器上沒有
local function pending(self)
    local C = MinidoracatBuilder and MinidoracatBuilder.Client
    local b = C and C.pendingUnbuild
    if b and b.n == self.n then return b end
    return nil
end

function MinidoracatBuilderDismantleAction:isValid()
    if self.character:getVehicle() ~= nil then return false end
    local b = pending(self)
    if not b then return true end -- 伺服器照請求重查（Server.dismantle）
    local sq = getCell():getGridSquare(b.x, b.y, b.z)
    return sq ~= nil and MinidoracatBuilder.Dismantle.find(sq, b.e) ~= nil
end

function MinidoracatBuilderDismantleAction:waitToStart()
    local b = pending(self)
    if b then self.character:faceLocation(b.x, b.y) end
    return self.character:shouldBeTurning()
end

function MinidoracatBuilderDismantleAction:start()
    self:setActionAnim("Build")
    self.sound = self.character:playSound("Hammering")
end

local function stopSound(self)
    if self.sound and self.sound ~= 0 then self.character:stopOrTriggerSound(self.sound) end
    self.sound = nil
end

function MinidoracatBuilderDismantleAction:stop()
    stopSound(self)
    ISBaseTimedAction.stop(self)
end

function MinidoracatBuilderDismantleAction:perform()
    stopSound(self)
    ISBaseTimedAction.perform(self)
end

function MinidoracatBuilderDismantleAction:complete()
    local S = MinidoracatBuilder and MinidoracatBuilder.Server
    return S ~= nil and S.dismantle(self.character, self.n) == true
end

-- 伺服器（與單機）照請求算；MP 客戶端照自己送出的那件算，只給進度條用，完成時間由伺服器決定
function MinidoracatBuilderDismantleAction:getDuration()
    local S = MinidoracatBuilder and MinidoracatBuilder.Server
    if S then return S.dismantleDuration(self.character, self.n) end
    if self.character:isTimedActionInstant() then return 1 end
    local b = pending(self)
    return MinidoracatBuilder.Entry.duration(b and b.kind, self.character)
end

function MinidoracatBuilderDismantleAction:new(character, n)
    local o = ISBaseTimedAction.new(self, character)
    o.n = n
    -- new() 只存欄位；伺服器另外呼叫 getDuration（NetTimedAction.java:70-83）
    if not isServer() then o.maxTime = o:getDuration() end
    return o
end
