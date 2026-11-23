-- read-only + optional actions for the quick-battle test.  __ACT: nil | "auto_on" | "auto_off" | "td=<n>" | "max=<n>"
local function live(o) if not o or not o:IsValid() then return false end local ok, n = pcall(function() return o:GetFName():ToString() end) return ok and not n:find("^Default__") end
local pc = FindFirstOf("BP_PlayerController_C")
local pawn = "none"; pcall(function() pawn = pc.Pawn:GetClass():GetFName():ToString() end)
local lv = pc:GetFullName():match("%.([%w_]+):PersistentLevel")
local ws
for _, o in ipairs(FindAllOf("WorldSettings") or {}) do if live(o) then local ok, n = pcall(function() return o:GetOuter():GetOuter():GetFName():ToString() end); if ok and n == lv then ws = o end end end
local view; for _, x in ipairs(FindAllOf("BPMV_JHBattleModule_C") or {}) do if live(x) and x:IsVisible() then view = x end end
local act = __ACT
if act and view then
  if act == "auto_on" then view:EnableAutoBattle() elseif act == "auto_off" then view:DisableAutoBattle() end
end
if act and ws then
  local n = tonumber(act:match("^td=([%d%.]+)")); if n then ws.TimeDilation = n end
  local m = tonumber(act:match("^max=([%d%.]+)")); if m then ws.MaxGlobalTimeDilation = m end
end
local s = { "pawn=" .. pawn, "lv=" .. tostring(lv) }
if ws then s[#s + 1] = string.format("TD=%.1f max=%.1f", ws.TimeDilation, ws.MaxGlobalTimeDilation) end
if view then
  pcall(function() s[#s + 1] = "auto=" .. tostring(view:BtnAutoBattleFlagIsAuto()) end)
  pcall(function() s[#s + 1] = "speedFlag1=" .. tostring(view:BtnSpeedUpFlagIs1()) end)
else s[#s + 1] = "no battle view" end
pcall(function() local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics"); s[#s + 1] = string.format("effective=%.1f", gs:GetGlobalTimeDilation(pc)) end)
W(table.concat(s, " "))
