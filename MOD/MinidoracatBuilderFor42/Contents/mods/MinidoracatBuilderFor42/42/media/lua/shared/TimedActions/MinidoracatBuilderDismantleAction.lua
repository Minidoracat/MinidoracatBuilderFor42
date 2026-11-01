require "TimedActions/ISBaseTimedAction"

-- 拆一件（拆除請求清單裡的第 i 件）。參數只放 nonce 與第幾件；拆哪一件在伺服器收到的拆除請求裡（Server.dismantleIntent），
-- complete() 只在伺服器跑（單機在本機），交給 MinidoracatBuilder.Server.dismantle。
-- 這個檔頂層不 require server 的檔（客戶端載不到）：用到時才從全域表找。
MinidoracatBuilderDismantleAction = ISBaseTimedAction:derive("MinidoracatBuilderDismantleAction")

-- 客戶端自己送出的那筆拆除請求裡的第 i 件（Client.pendingUnbuild.list[i]：畫面用，轉身、進度條）；伺服器上沒有
local function pending(self)
    local C = MinidoracatBuilder and MinidoracatBuilder.Client
    local b = C and C.pendingUnbuild
    if b and b.n == self.n then return b.list[self.i] end
    return nil
end

-- 那件已經不在（被別人拆了）也不算無效：isValid 回 false 時引擎停下動作、清掉整個佇列（ISBaseTimedAction.stop →
-- resetQueue），一區拆除後面的就都不拆了。照樣進 complete()，伺服器回 GONE 跳過這一件（施工時間 1，Server.dismantleDuration）。
function MinidoracatBuilderDismantleAction:isValid()
    return self.character:getVehicle() == nil
end

function MinidoracatBuilderDismantleAction:waitToStart()
    local it = pending(self)
    if it then self.character:faceLocation(it.x, it.y) end
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
    return S ~= nil and S.dismantle(self.character, self.n, self.i) == true
end

-- 伺服器（與單機）照請求算；MP 客戶端照自己送出的那件算，只給進度條用，完成時間由伺服器決定。
-- 那件已經不在時 1（同 Server.dismantleDuration）
function MinidoracatBuilderDismantleAction:getDuration()
    local S = MinidoracatBuilder and MinidoracatBuilder.Server
    if S then return S.dismantleDuration(self.character, self.n, self.i) end
    if self.character:isTimedActionInstant() then return 1 end
    local it = pending(self)
    local D = MinidoracatBuilder.Dismantle
    local sq = it and getCell():getGridSquare(it.x, it.y, it.z)
    if not (sq and (D.find(sq, it.name) or D.hung(sq, it.name))) then return 1 end
    return MinidoracatBuilder.Entry.duration(it.kind, self.character)
end

function MinidoracatBuilderDismantleAction:new(character, n, i)
    local o = ISBaseTimedAction.new(self, character)
    o.n, o.i = n, i
    -- new() 只存欄位；伺服器另外呼叫 getDuration（NetTimedAction.java:70-83）
    if not isServer() then o.maxTime = o:getDuration() end
    return o
end
