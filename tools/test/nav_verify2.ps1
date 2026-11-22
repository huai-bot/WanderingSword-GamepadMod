# v4.12 regression: d-pad + left stick + LT/RT on the character screen, and no visit of 属性/装备 at all.
$W = 'D:\TOOLS\AWSdata\WanderingSword'
$DLL = 'D:\TOOLS\AWSdata\WanderingSword\tools\wspad\wspad5.dll'
$u = New-Object Text.UTF8Encoding $false
$probe = Get-Content "$W\tools\probe_nav3.lua" -Raw -Encoding UTF8
$logPath = 'D:\GAME\Wandering Sword\Wandering_Sword\Binaries\Win64\ue4ss\UE4SS.log'
function Lua([string]$src, [int]$waitMs = 3000) { Remove-Item "$W\cmd_out.txt" -ErrorAction SilentlyContinue; [IO.File]::WriteAllText("$W\cmd.lua", $src, $u); for ($i = 0; $i -lt [int]($waitMs / 50); $i++) { Start-Sleep -Milliseconds 50; if (Test-Path "$W\cmd_out.txt") { $r = Get-Content "$W\cmd_out.txt" -Raw -Encoding UTF8; if ($r -match '== done') { return (($r -replace "`r", "" -replace "== done", "").Trim() -replace "`n", " | ") } } }; return "(no reply)" }
function LogSince([long]$pos) { $fs = [IO.File]::Open($logPath, 'Open', 'Read', 'ReadWrite'); $fs.Seek($pos, 'Begin') | Out-Null; $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); $t = $sr.ReadToEnd(); $sr.Close(); return ($t -split "`n" | Select-String 'GamepadTweaks\] nav' | % { $_.Line.Trim() -replace '^\[2026-11-23 \d\d:', '[' }) }
$script:pass = 0; $script:fail = 0; $script:n = 0; $script:out = @()
function O([string]$s) { Write-Host $s; $script:out += $s }
function Check([string]$key, [string]$expect, [string]$note = "") {
  $pos = (Get-Item $logPath).Length
  Remove-Item "$W\pad_out.txt" -ErrorAction SilentlyContinue
  [IO.File]::WriteAllText("$W\pad.req", "$key 110", [Text.Encoding]::ASCII)
  $o = ""; for ($i = 0; $i -lt 100; $i++) { Start-Sleep -Milliseconds 30; if (Test-Path "$W\pad_out.txt") { $o = Get-Content "$W\pad_out.txt" -Raw; break } }
  if ($o -match 'ABORT') { O "STOP: $o"; Finish }
  Start-Sleep -Milliseconds 500
  $r = Lua $probe
  $l = @(LogSince $pos)
  $flash = @($l | ? { $_ -match 'd-pad into' }).Count
  $script:n++
  $ok = ($r -like "$expect*") -and $flash -eq 0
  if ($ok) { $script:pass++ } else { $script:fail++ }
  O ("{0:D2} {1,-6} expect {2,-9} got {3,-34} {4}  {5}  {6}" -f $script:n, $key, $expect, $r, $(if ($ok) { "PASS" } else { "FAIL" }), $note, (($l | % { $_ -replace '.*GamepadTweaks\] ', '' }) -join ' / '))
}
function Finish {
  $null = Lua "local f = package.loadlib([[$DLL]], `"wspad_uninstall`"); if f then f() end; W(`"u`")"
  Remove-Item "$W\cmd.lua", "$W\pad.req", "$W\pad_connect.flag" -ErrorAction SilentlyContinue
  O "PASS $($script:pass)  FAIL $($script:fail)"
  O "--- proxy log"; Get-Content "$W\wsmod.log" -Encoding UTF8 -Tail 8 | % { O $_ }
  $script:out | Set-Content "$W\nav_verify2.txt" -Encoding UTF8
  exit
}
Remove-Item "$W\pad_user.flag", "$W\pad_abort.flag" -ErrorAction SilentlyContinue
$f = Lua (Get-Content "$W\tools\probe_fight.lua" -Raw -Encoding UTF8); O "state: $f"
if ($f -notmatch '^calm') { O "not calm"; exit }
O ("install: " + (Lua "local f, e = package.loadlib([[$DLL]], `"wspad_install`"); if not f then W(`"loadlib failed `" .. tostring(e)) return end; f(); W(`"installed`")"))
New-Item -ItemType File -Force "$W\pad_connect.flag" | Out-Null; Start-Sleep -Milliseconds 200
Add-Type -Namespace WSM5 -Name M -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);'
$gw = (Get-Process JH-Win64-Shipping).MainWindowHandle; [void][WSM5.M]::PostMessageW($gw, 0x219, [IntPtr]7, [IntPtr]::Zero); Start-Sleep -Milliseconds 800
Remove-Item "$W\pad_out.txt" -ErrorAction SilentlyContinue; [IO.File]::WriteAllText("$W\pad.req", "- 300", [Text.Encoding]::ASCII); Start-Sleep -Milliseconds 700
O ("poll check: " + (Get-Content "$W\pad_out.txt" -Raw -ErrorAction SilentlyContinue))
if ((Lua $probe) -eq 'closed') { $null = Lua 'for _, v in ipairs(FindAllOf("JHNeoUIPrimeModuleVM") or {}) do if v:IsValid() and not v:GetFName():ToString():find("^Default__") then v:Show() end end; W("show")'; Start-Sleep 3 }
O ("start: " + (Lua $probe))
# make the game take gamepad mode, then park on the side bar with LT/RT
Check "SD" "" "wake"
for ($i = 0; $i -lt 3; $i++) { if ((Lua $probe) -like 'SideBar*') { break }; Check "RT" "" "seek SideBar" }
O "--- LT/RT cycle"
Check "RT" "Backpack"; Check "RT" "Bottom"; Check "RT" "SideBar"
Check "LT" "Bottom"; Check "LT" "Backpack"; Check "LT" "SideBar"
O "--- side bar"
Check "SD" "SideBar" "stick down: next cell"
Check "RIGHT" "Backpack" "d-pad right"
Check "LT" "SideBar"
Check "SR" "Backpack" "stick right"
O "--- backpack left edge (game's own ChangeNaviFocus, rewritten)"
Check "SD" "Backpack" "into the grid"
Check "SR" "Backpack" "col 1"
Check "SL" "Backpack" "col 0"
Check "SL" "SideBar" "stick left at col 0"
O "--- bottom row"
Check "RT" "Backpack"; Check "RT" "Bottom"
Check "SR" "Bottom" "stick right inside the row"
Check "UP" "Backpack" "d-pad up -> where we came from"
Check "LT" "SideBar"; Check "LT" "Bottom"
Check "SU" "SideBar" "stick up -> where we came from"
O "--- memory: side bar cell / backpack position"
Check "SD" "SideBar" "cell 2"; Check "SD" "SideBar" "cell 3"
$cell = (Lua $probe)
Check "RT" "Backpack idx=" "lands on a cell"
Check "SR" "Backpack" ; Check "SR" "Backpack"
$idx = (Lua $probe)
Check "LT" $cell "back on the same side bar cell"
Check "RT" $idx "back on the same backpack cell"
Check "SL" "Backpack"; Check "SL" "Backpack"
Check "SL" $cell "backpack left edge -> same side bar cell"
Finish
