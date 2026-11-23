param([string]$which = "1,2,3,4,5")
# Quick-battle verification, all in the background (no focus, no injected input):
# sparring fights, speed button pressed via the game's own handler, mod state read from the log + world settings.
$W = 'D:\TOOLS\AWSdata\WanderingSword'
$g = 'D:\GAME\Wandering Sword\Wandering_Sword\Binaries\Win64'
$log = "$g\ue4ss\UE4SS.log"
$u = New-Object Text.UTF8Encoding $false
$e9 = [Text.Encoding]::GetEncoding(936)
$originalIni = [IO.File]::ReadAllText("$W\wsmod.ini", $e9)
function Lua([string]$src, [int]$waitMs = 5000) { Remove-Item "$W\cmd_out.txt" -ErrorAction SilentlyContinue; [IO.File]::WriteAllText("$W\cmd.lua", $src, $u); for ($i = 0; $i -lt [int]($waitMs / 50); $i++) { Start-Sleep -Milliseconds 50; if (Test-Path "$W\cmd_out.txt") { try { $r = Get-Content "$W\cmd_out.txt" -Raw -Encoding UTF8 -ErrorAction Stop } catch { continue }; if ($r -match '== done') { return (($r -replace "`r", "" -replace "== done", "").Trim()) } } }; return "(no reply)" }
function SetIni([string]$k, [string]$v) { $f = "$W\wsmod.ini"; $t = [IO.File]::ReadAllText($f, $e9); $t = [regex]::Replace($t, "(?m)^$k=\S*", "$k=$v"); [IO.File]::WriteAllText($f, $t, $e9) }
function LogSince([long]$pos) { $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite'); $fs.Seek($pos, 'Begin') | Out-Null; $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); $t = $sr.ReadToEnd(); $sr.Close(); return @($t -split "`n" | Select-String 'GamepadTweaks\] (speed|task)' | % { $_.Line.Trim() -replace '.*GamepadTweaks\] ', '' }) }
$head = 'local function live(o) if not o or not o:IsValid() then return false end local ok, n = pcall(function() return o:GetFName():ToString() end) return ok and not n:find("^Default__") end; '
$state = $head + @'
local r = {}
for _, cn in ipairs({ "BPMV_BattleWinMaster_C", "BPMV_BattleFailure_C", "BPMV_JHBattleModule_C", "BPMV_PrimeTeam_C" }) do for _, v in ipairs(FindAllOf(cn) or {}) do if live(v) and v:IsVisible() then r[#r + 1] = cn:gsub("BPMV_", ""):gsub("_C$", "") end end end
local p = "?"; pcall(function() p = FindFirstOf("BP_PlayerController_C").Pawn:GetClass():GetFName():ToString() end)
W(p .. " [" .. table.concat(r, ",") .. "]")
'@
$qb = Get-Content (Join-Path $PSScriptRoot 'probe_qb.lua') -Raw -Encoding UTF8
$show = 'for _, v in ipairs(FindAllOf("JHNeoUIPrimeModuleVM") or {}) do if v:IsValid() and not v:GetFName():ToString():find("^Default__") then v:Show() end end; W("show")'
$hide = 'for _, v in ipairs(FindAllOf("JHNeoUIPrimeModuleVM") or {}) do if v:IsValid() and not v:GetFName():ToString():find("^Default__") then v:Hide() end end; W("hide")'
$pick = $head + @'
local team; for _, v in ipairs(FindAllOf("BPMV_PrimeTeam_C") or {}) do if live(v) then team = v end end
local tv; for _, v in ipairs(FindAllOf("TeamModuleVM") or {}) do if live(v) then tv = v end end
local function idx() local js = tv.RootData:DataToString():ToString(); return tonumber(js:match('"focus_npc_index":(%-?%d+)')) end
if team.BTN_QieCuo:IsVisible() then W("already teammate, index " .. idx()) return end
local cells = {}
for _, c in ipairs(FindAllOf("BPVE_SideBarCell2_C") or {}) do if live(c) and c:IsVisible() then cells[#cells + 1] = c end end
table.sort(cells, function(a, b) return a:GetFName():ToString() > b:GetFName():ToString() end)
local tried = {}
for i = 2, math.min(#cells, 5) do
  local c = cells[i]
  pcall(function() c.BTN_SidebarCell:SetFocus() end)
  pcall(function() c["BndEvt__BPVE_SideBarCell2_BTN_SidebarCell_K2Node_ComponentBoundEvent_3_JHNeoUIGamepadConfirmButtonClicked__DelegateSignature"](c, c.BTN_SidebarCell) end)
  tried[#tried + 1] = i .. ":" .. tostring(idx())
  if team.BTN_QieCuo:IsVisible() then break end
end
W("picked " .. table.concat(tried, " ") .. " qiecuo=" .. tostring(team.BTN_QieCuo:IsVisible()))
'@
$spar = $head + 'local team; for _, v in ipairs(FindAllOf("BPMV_PrimeTeam_C") or {}) do if live(v) then team = v end end; if not team.BTN_QieCuo:IsVisible() then W("no qiecuo button") return end; team["BndEvt__BPMV_PrimeTeam_BTN_QieCuo_K2Node_ComponentBoundEvent_2_BtnClick__DelegateSignature"](team); W("spar")'
$press = $head + @'
local v; for _, x in ipairs(FindAllOf("BPMV_JHBattleModule_C") or {}) do if live(x) and x:IsVisible() then v = x end end
if not v then W("no battle view") return end
local before = v.BTN_SpeedUp2:IsVisible() and "x2" or "x1"
if v.BTN_SpeedUp1:IsVisible() then v:HandleBtn_SpeedUp_1() else v:HandleBtn_SpeedUp_2() end
W("game icon " .. before .. " -> " .. (v.BTN_SpeedUp2:IsVisible() and "x2" or "x1"))
'@
$cont = $head + 'local done = "none"; for _, v in ipairs(FindAllOf("BPMV_BattleFailure_C") or {}) do if live(v) and v:IsVisible() then v["BndEvt__BPMV_BattleFailure_NeoUIButtonBase_76_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"](v); done = "failure" end end; local win = 0; for _, v in ipairs(FindAllOf("BPMV_BattleWinMaster_C") or {}) do if live(v) and v:IsVisible() then win = 1 end end; W(done .. " win=" .. win)'
function Wait([string]$pattern, [int]$sec) { $t0 = Get-Date; while (((Get-Date) - $t0).TotalSeconds -lt $sec) { $s = Lua $state; if ($s -match $pattern) { return $s }; Start-Sleep -Milliseconds 200 }; return "TIMEOUT: " + (Lua $state) }
$script:out = @()
function O([string]$s) { Write-Host $s; $script:out += $s }
function Finish { [IO.File]::WriteAllText("$W\wsmod.ini", $originalIni, $e9); Remove-Item "$W\cmd.lua" -ErrorAction SilentlyContinue; $script:out | Set-Content "$W\qb_verify.txt" -Encoding UTF8; exit }
# one fight: $presses = list of delays (s after the battle UI) at which the speed button is pressed
$finishAuto = $head + @'
local v; for _, x in ipairs(FindAllOf("BPMV_JHBattleModule_C") or {}) do if live(x) and x:IsVisible() then v = x end end
if not v then W("no battle view") return end
if v:BtnSpeedUpFlagIs1() then v:HandleBtn_SpeedUp_1() else v:HandleBtn_SpeedUp_2() end
ExecuteWithDelay(100, function()
  if not live(v) then return end
  if v:BtnSpeedUpFlagIs1() then v:HandleBtn_SpeedUp_1() else v:HandleBtn_SpeedUp_2() end
end)
W("test: finish via the normal x1 -> x2 -> quick-battle cycle")
'@
$autoOff = $head + @'
local n, a = 0, "?"
for _, x in ipairs(FindAllOf("BPMV_JHBattleModule_C") or {}) do if live(x) then pcall(function() x:DisableAutoBattle(); a = tostring(x:BtnAutoBattleFlagIsAuto()) end); n = n + 1 end end
W("DisableAutoBattle on " .. n .. " views, auto now " .. a)
'@
function Fight([string]$label, [double[]]$presses, [bool]$finish = $false, [bool]$cleanup = $false) {
  O "=== $label"
  $s = Lua $state; if ($s -notmatch '^BP_SceneHero') { O "not in the scene: $s"; Finish }
  $null = Lua $show; $null = Wait 'PrimeTeam' 8
  O ("pick: " + (Lua $pick))
  $pos = (Get-Item $log).Length
  O ("spar: " + (Lua $spar))
  $s = Wait 'JHBattleModule' 40; if ($s -like 'TIMEOUT*') { O "battle ui: $s"; Finish }
  $t0 = Get-Date
  Start-Sleep -Milliseconds 400
  O ("  start  " + (Lua $qb))
  foreach ($d in $presses) {
    $wait = $d - ((Get-Date) - $t0).TotalSeconds; if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]($wait * 1000)) }
    $s = Lua $state; if ($s -notmatch 'JHBattleModule') { O "  (fight already over before press at $d s)"; break }
    O ("  press  " + (Lua $press)); Start-Sleep -Milliseconds 500
    O ("  after  " + (Lua $qb))
  }
  if ($finish) { Start-Sleep -Milliseconds 300; O ("  " + (Lua $finishAuto)) }
  $s = Wait 'BattleWinMaster|BattleFailure|^BP_SceneHero' 150
  $wall = ((Get-Date) - $t0).TotalSeconds
  O ("  result after {0:N1} s: {1}" -f $wall, $s)
  Start-Sleep -Milliseconds 300
  O ("  end    " + (Lua $qb))
  foreach ($l in (LogSince $pos)) { O "  log: $l" }
  if ($cleanup) { O ("  cleanup: " + (Lua $autoOff)) }
  $s = Lua $state
  if ($s -match 'BattleFailure') { $null = Lua $cont } elseif ($s -match 'BattleWinMaster') { Start-Sleep 1; $null = Lua 'local n = 0; for _, v in ipairs(FindAllOf("JHNeoUIBattleResultVM") or {}) do if v:IsValid() and not v:GetFName():ToString():find("^Default__") and v:GetModuleVisibility() then v:HandleModuleClose(); n = n + 1 end end; W("closed " .. n)'; Start-Sleep 2; powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'bg_click.ps1') | Out-Null }
  $s = Wait '^BP_SceneHero_C \[\]' 25; if ($s -like 'TIMEOUT*') { powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'bg_click.ps1') | Out-Null; $s = Wait '^BP_SceneHero_C \[\]' 15 }
  O "  back: $s"
  if ($s -like 'TIMEOUT*') { Finish }
  Start-Sleep 2
}
O ("state: " + (Lua (Get-Content "$W\tools\probe_fight.lua" -Raw -Encoding UTF8)))
$sel = $which -split ','
if ($sel -contains '1') { SetIni 'quick_speed' '50'; Fight "1: x1 (auto left on by 速战 -> switched off), press -> x2, press -> 速战" @(1.0, 2.5) }
if ($sel -contains '2') { SetIni 'quick_speed' '50'; Fight "2: 速战 kept for the next fight" @() }
if ($sel -contains 'b3') { SetIni 'quick_speed' '3'; Fight "baseline: 速战 at x3 (same opponent)" @() }
if ($sel -contains 'b20') { SetIni 'quick_speed' '20'; Fight "速战 at x20" @() }
if ($sel -contains 'b100') { SetIni 'quick_speed' '100'; Fight "速战 at x100" @() }
if ($sel -contains '6') { SetIni 'quick_speed' '3'; Fight "6: x1 auto off, press x2, press 速战 (mod turns auto on), press x1 (mod turns auto off), test finishes" @(1.0, 2.5, 4.5) $true $true }
if ($sel -contains '7') { SetIni 'quick_speed' '3'; SetIni 'quick_timeout' '3'; Fight "7: watchdog: 速战 at x3 with quick_timeout=3 -> falls back to x2, auto stays on" @(1.0, 2.5) $false $true; SetIni 'quick_timeout' '90' }
if ($sel -contains '3') { SetIni 'quick_speed' '3'; Fight "3: 速战 at x3 (slow, for the press), press -> x1 (check auto off + x1, then test finishes the fight)" @(1.5) $true }
if ($sel -contains '4') { SetIni 'quick_speed' '50'; Fight "4: x1 kept, press -> x2, press -> 速战" @(2.0, 3.5) }
if ($sel -contains '5') { SetIni 'quick_speed' '3'; Fight "5: 速战 at x3, press -> x1, test finishes, then auto switched off" @(1.5) $true $true }
Finish
