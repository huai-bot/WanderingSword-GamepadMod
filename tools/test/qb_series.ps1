# Background quick-battle series: sparring (切磋) with the selected teammate, auto battle on, TimeDilation held at
# each value, real time from the battle UI appearing to the result screen. No foreground needed.
param([string]$speeds = "2,8,20,50", [int]$maxTD = 100)
$W = 'D:\TOOLS\AWSdata\WanderingSword'
$u = New-Object Text.UTF8Encoding $false
function Lua([string]$src, [int]$waitMs = 5000) { Remove-Item "$W\cmd_out.txt" -ErrorAction SilentlyContinue; [IO.File]::WriteAllText("$W\cmd.lua", $src, $u); for ($i = 0; $i -lt [int]($waitMs / 50); $i++) { Start-Sleep -Milliseconds 50; if (Test-Path "$W\cmd_out.txt") { $r = Get-Content "$W\cmd_out.txt" -Raw -Encoding UTF8; if ($r -match '== done') { return (($r -replace "`r", "" -replace "== done", "").Trim()) } } }; return "(no reply)" }
$head = 'local function live(o) if not o or not o:IsValid() then return false end local ok, n = pcall(function() return o:GetFName():ToString() end) return ok and not n:find("^Default__") end; '
$state = $head + @'
local r = {}
for _, cn in ipairs({ "BPMV_BattleWinMaster_C", "BPMV_BattleFailure_C", "BPMV_JHBattleModule_C", "BPMV_PrimeTeam_C" }) do for _, v in ipairs(FindAllOf(cn) or {}) do if live(v) and v:IsVisible() then r[#r + 1] = cn:gsub("BPMV_", ""):gsub("_C$", "") end end end
local p = "?"; pcall(function() p = FindFirstOf("BP_PlayerController_C").Pawn:GetClass():GetFName():ToString() end)
W(p .. " [" .. table.concat(r, ",") .. "]")
'@
$show = 'for _, v in ipairs(FindAllOf("JHNeoUIPrimeModuleVM") or {}) do if v:IsValid() and not v:GetFName():ToString():find("^Default__") then v:Show() end end; W("show")'
$spar = $head + 'local team; for _, v in ipairs(FindAllOf("BPMV_PrimeTeam_C") or {}) do if live(v) then team = v end end; if not team.BTN_QieCuo:IsVisible() then W("no qiecuo button") return end; team["BndEvt__BPMV_PrimeTeam_BTN_QieCuo_K2Node_ComponentBoundEvent_2_BtnClick__DelegateSignature"](team); W("spar")'
$cont = $head + @'
local done = "none"
for _, v in ipairs(FindAllOf("BPMV_BattleFailure_C") or {}) do if live(v) and v:IsVisible() then v["BndEvt__BPMV_BattleFailure_NeoUIButtonBase_76_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"](v); done = "failure" end end
W(done)
'@
function Wait([string]$pattern, [int]$sec) { $t0 = Get-Date; while (((Get-Date) - $t0).TotalSeconds -lt $sec) { $s = Lua $state; if ($s -match $pattern) { return $s }; Start-Sleep -Milliseconds 300 }; return "TIMEOUT: " + (Lua $state) }
$results = @()
foreach ($td in ($speeds -split ',')) {
  Write-Host "=== x$td"
  $s = Lua $state
  if ($s -notmatch '^BP_SceneHero') { Write-Host "not in the scene: $s"; break }
  $null = Lua $show; $null = Wait 'PrimeTeam' 6
  Write-Host ("spar: " + (Lua $spar))
  $s = Wait 'JHBattleModule' 40; Write-Host "battle ui: $s"
  if ($s -like 'TIMEOUT*') { break }
  Remove-Item "$W\qb_run.txt" -ErrorAction SilentlyContinue
  Write-Host ("run: " + (Lua ("__TD = $td`n__MAX = $maxTD`n" + (Get-Content "$W\tools\qb_run.lua" -Raw -Encoding UTF8))))
  $t0 = Get-Date
  $r = ""; for ($k = 0; $k -lt 1000; $k++) { Start-Sleep -Milliseconds 200; $r = Get-Content "$W\qb_run.txt" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue; if ($r -match 'result|fight over|watchdog') { break } }
  $wall = ((Get-Date) - $t0).TotalSeconds
  $line = ($r -split "`n" | Select-String 'result|fight over|watchdog' | Select-Object -Last 1).Line -replace '^\s*[\d\.]+ ---- ', '' -replace 'after [\d\.]+s real, ', ''
  $res = "x{0,-4} wall {1,6:N1} s  {2}" -f $td, $wall, $line
  Write-Host $res
  $results += $res
  & "$W\tools\capture.ps1" -out "$W\nav_shots\qb_x$td.png" | Out-Null
  Start-Sleep 1
  # continue: win screen takes a background click, failure screen its button event
  $s = Lua $state
  if ($s -match 'BattleFailure') { Write-Host ("continue: " + (Lua $cont)) } else { powershell -NoProfile -ExecutionPolicy Bypass -File "$W\tools\bg_click.ps1" | Out-Null }
  $s = Wait '^BP_SceneHero.*\[(PrimeTeam)?\]$|^BP_SceneHero' 20; Write-Host "back: $s"
  if ($s -like 'TIMEOUT*') { powershell -NoProfile -ExecutionPolicy Bypass -File "$W\tools\bg_click.ps1" | Out-Null; $s = Wait '^BP_SceneHero' 15; Write-Host "back(2): $s"; if ($s -like 'TIMEOUT*') { break } }
  Start-Sleep 2
}
Remove-Item "$W\cmd.lua" -ErrorAction SilentlyContinue
"=== summary"; $results
$results | Set-Content "$W\qb_series.txt" -Encoding UTF8
