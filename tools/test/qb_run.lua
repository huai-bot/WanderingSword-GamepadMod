-- quick-battle experiment: auto battle on + hold TimeDilation at __TD until the fight ends; log turns and duration
local TD = __TD or 20
local MAX = __MAX
local LOG = [[D:\TOOLS\AWSdata\WanderingSword\qb_run.txt]]
local function live(o) if not o or not o:IsValid() then return false end local ok, n = pcall(function() return o:GetFName():ToString() end) return ok and not n:find("^Default__") end
local function L(s) local f = io.open(LOG, "a"); if f then f:write(string.format("%8.3f ", os.clock()) .. s .. "\n"); f:close() end end
local pc = FindFirstOf("BP_PlayerController_C")
local lv = pc:GetFullName():match("%.([%w_]+):PersistentLevel")
local ws
for _, o in ipairs(FindAllOf("WorldSettings") or {}) do if live(o) then local ok, n = pcall(function() return o:GetOuter():GetOuter():GetFName():ToString() end); if ok and n == lv then ws = o end end end
local view; for _, x in ipairs(FindAllOf("BPMV_JHBattleModule_C") or {}) do if live(x) and x:IsVisible() then view = x end end
if not (ws and view) then W("not in a fight view") return end
if MAX then ws.MaxGlobalTimeDilation = MAX end
view:EnableAutoBattle()
L(string.format("---- start TD=%s max=%.0f auto=%s", tostring(TD), ws.MaxGlobalTimeDilation, tostring(view:BtnAutoBattleFlagIsAuto())))
_G.__QB = { t0 = os.clock(), turns = 0, over = 0, done = false, ws = ws, td = TD }
if not _G.__QBhook then
  _G.__QBhook = true
  pcall(function()
    RegisterHook("/Script/JH.FightManager:HandlePawnTurnStart", function(self, p)
      local Q = _G.__QB; if not Q or Q.done then return end
      Q.turns = Q.turns + 1
      local n = "?"; pcall(function() n = p:get():GetClass():GetFName():ToString() end)
      L(string.format("turn %d %s  t=%.2fs", Q.turns, n, os.clock() - Q.t0))
    end)
  end)
end
LoopInGameThreadWithDelay(16, function()
  local Q = _G.__QB
  if not Q or Q.done then return true end
  local pawn = "none"; pcall(function() pawn = FindFirstOf("BP_PlayerController_C").Pawn:GetClass():GetFName():ToString() end)
  local res = nil
  for _, cn in ipairs({ "BPMV_BattleWinMaster_C", "BPMV_BattleFailure_C" }) do
    for _, o in ipairs(FindAllOf(cn) or {}) do if live(o) and o:IsVisible() then res = cn end end
  end
  if res then
    Q.done = true
    local w = Q.ws; if w and w:IsValid() then w.TimeDilation = 1.0 end
    L(string.format("---- result %s after %.2fs real, %d overwrites", res, os.clock() - Q.t0, Q.over))
    return true
  end
  if not pawn:find("FightSpectator") then
    Q.done = true
    L(string.format("---- fight over after %.2fs real, %d turns, %d overwrites, pawn=%s", os.clock() - Q.t0, Q.turns, Q.over, pawn))
    return true
  end
  if os.clock() - Q.t0 > 180 then Q.done = true; L("---- watchdog: 180 s, stop holding"); return true end
  local w = Q.ws
  if w and w:IsValid() and math.abs(w.TimeDilation - Q.td) > 0.01 then w.TimeDilation = Q.td; Q.over = Q.over + 1 end
  return false
end)
W("holding TD=" .. TD)
