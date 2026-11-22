# Verify v4.10 character-screen navigation with injected input. Prints PASS/FAIL per step.
$W = 'D:\TOOLS\AWSdata\WanderingSword'
$DLL = 'D:\TOOLS\AWSdata\WanderingSword\tools\wspad\wspad4.dll'
$SHOTS = "$W\nav_shots"; New-Item -ItemType Directory -Force $SHOTS | Out-Null; Remove-Item "$SHOTS\*.png" -ErrorAction SilentlyContinue
$u = New-Object Text.UTF8Encoding $false
$probe = Get-Content "$W\tools\probe_nav2.lua" -Raw -Encoding UTF8
function Lua([string]$src, [int]$waitMs = 3000) {
  Remove-Item "$W\cmd_out.txt" -ErrorAction SilentlyContinue
  [IO.File]::WriteAllText("$W\cmd.lua", $src, $u)
  for ($i = 0; $i -lt [int]($waitMs / 50); $i++) {
    Start-Sleep -Milliseconds 50
    if (Test-Path "$W\cmd_out.txt") { $r = Get-Content "$W\cmd_out.txt" -Raw -Encoding UTF8; if ($r -match '== done') { return (($r -replace "`r", "" -replace "== done", "").Trim() -replace "`n", " | ") } }
  }
  return "(no reply)"
}
function Pad([string]$script) {
  Remove-Item "$W\pad_out.txt" -ErrorAction SilentlyContinue
  [IO.File]::WriteAllText("$W\pad.req", $script, [Text.Encoding]::ASCII)
  for ($i = 0; $i -lt 200; $i++) { Start-Sleep -Milliseconds 30; if (Test-Path "$W\pad_out.txt") { return (Get-Content "$W\pad_out.txt" -Raw) } }
  return "(pad no reply)"
}
$script:pass = 0; $script:fail = 0; $script:n = 0; $script:log = @()
function Check([string]$key, [string]$expect) {
  $null = Pad "$key 120"
  Start-Sleep -Milliseconds 500
  $r = Lua $probe
  $script:n++
  & "$W\tools\capture.ps1" -out ("{0}\v{1:D2}_{2}.png" -f $SHOTS, $script:n, $key) | Out-Null
  $ok = $r -like "$expect*"
  if ($ok) { $script:pass++ } else { $script:fail++ }
  $line = "{0:D2} {1,-6} expect {2,-9} got {3,-22} {4}" -f $script:n, $key, $expect, $r, $(if ($ok) { "PASS" } else { "FAIL" })
  Write-Host $line; $script:log += $line
  if ($r -eq 'closed') { Write-Host "screen closed, stop"; Finish }
}
function Finish {
  Write-Host ("uninstall: " + (Lua "local f = package.loadlib([[$DLL]], `"wspad_uninstall`"); if f then f() end; W(`"uninstalled`")"))
  Remove-Item "$W\cmd.lua", "$W\pad.req", "$W\pad_connect.flag" -ErrorAction SilentlyContinue
  $script:log += "PASS $($script:pass) FAIL $($script:fail)"
  $script:log | Set-Content "$W\nav_verify.txt" -Encoding UTF8
  Write-Host "PASS $($script:pass)  FAIL $($script:fail)"
  exit
}
Remove-Item "$W\pad_abort.flag" -ErrorAction SilentlyContinue
$f = Lua (Get-Content "$W\tools\probe_fight.lua" -Raw -Encoding UTF8); Write-Host "state: $f"
if ($f -notmatch '^calm') { Write-Host "not calm, giving up"; exit }
Write-Host ("install: " + (Lua "local f, e = package.loadlib([[$DLL]], `"wspad_install`"); if not f then W(`"loadlib failed `" .. tostring(e)) return end; f(); W(`"installed`")"))
# the real controller may be asleep: report pad 0 as connected and tell the game a device changed
New-Item -ItemType File -Force "$W\pad_connect.flag" | Out-Null; Start-Sleep -Milliseconds 200
Add-Type -Namespace WSM -Name M -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);'
$gw = (Get-Process JH-Win64-Shipping).MainWindowHandle; [void][WSM.M]::PostMessageW($gw, 0x219, [IntPtr]7, [IntPtr]::Zero); Start-Sleep -Milliseconds 800
Write-Host ("poll check: " + (Pad "- 300"))
$logPath = 'D:\GAME\Wandering Sword\Wandering_Sword\Binaries\Win64\ue4ss\UE4SS.log'
$logStart = (Get-Item $logPath).Length
if ((Lua $probe) -eq 'closed') {
  Write-Host ("open: " + (Lua 'for _, v in ipairs(FindAllOf("JHNeoUIPrimeModuleVM") or {}) do if v:IsValid() and not v:GetFName():ToString():find("^Default__") then v:Show() end end; W("show")'))
  Start-Sleep 3
}
Write-Host ("start: " + (Lua $probe))
# make sure the game is in gamepad mode (a d-pad press inside the side bar does that)
$null = Pad "DOWN 120"; Start-Sleep -Milliseconds 300; $null = Pad "UP 120"; Start-Sleep -Milliseconds 400
Write-Host ("after wake-up: " + (Lua $probe))

Write-Host "--- RT cycle"
Check "RT" "Backpack"; Check "RT" "Bottom"; Check "RT" "SideBar"; Check "RT" "Backpack"
Write-Host "--- LT cycle"
Check "LT" "SideBar"; Check "LT" "Bottom"; Check "LT" "Backpack"; Check "LT" "SideBar"
Write-Host "--- d-pad"
Check "RIGHT" "Backpack"       # SideBar RIGHT: game -> Property, we bounce to Backpack
Check "LEFT" "SideBar"         # Backpack LEFT: game -> Equip, we bounce to SideBar
Check "RT" "Backpack"
Check "RT" "Bottom"
Check "RIGHT" "Bottom"         # inside the bottom row
Check "LEFT" "Bottom"
Check "UP" "Backpack"          # bottom UP: game -> Property, we go back to where we came from (Backpack)
Check "LT" "SideBar"

$fs = [IO.File]::Open($logPath, 'Open', 'Read', 'ReadWrite'); $fs.Seek($logStart, 'Begin') | Out-Null
$sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); $new = $sr.ReadToEnd(); $sr.Close()
$lines = $new -split "`n" | Select-String 'GamepadTweaks\] (nav|backpack|task)' | % { $_.Line.Trim() -replace '^\[2026-11-23 ', '[' }
Write-Host "--- mod log ($($lines.Count) lines)"; $lines | Select-Object -Last 40 | % { Write-Host $_ }
$script:log += $lines
Finish
