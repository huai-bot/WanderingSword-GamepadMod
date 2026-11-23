# v4.14 观察 screen regression (injected left stick / d-pad / triggers). Requires the 观察 screen to be open.
$W = 'D:\TOOLS\AWSdata\WanderingSword'
$DLL = 'D:\TOOLS\AWSdata\WanderingSword\tools\wspad\wspad5.dll'
$u = New-Object Text.UTF8Encoding $false
$probe = Get-Content "$W\tools\probe_obsnav.lua" -Raw -Encoding UTF8
$logPath = 'D:\GAME\Wandering Sword\Wandering_Sword\Binaries\Win64\ue4ss\UE4SS.log'
function Lua([string]$src, [int]$waitMs = 3000) { Remove-Item "$W\cmd_out.txt" -ErrorAction SilentlyContinue; [IO.File]::WriteAllText("$W\cmd.lua", $src, $u); for ($i = 0; $i -lt [int]($waitMs / 50); $i++) { Start-Sleep -Milliseconds 50; if (Test-Path "$W\cmd_out.txt") { $r = Get-Content "$W\cmd_out.txt" -Raw -Encoding UTF8; if ($r -match '== done') { return (($r -replace "`r", "" -replace "== done", "").Trim() -replace "`n", " | ") } } }; return "(no reply)" }
function LogSince([long]$pos) { $fs = [IO.File]::Open($logPath, 'Open', 'Read', 'ReadWrite'); $fs.Seek($pos, 'Begin') | Out-Null; $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); $t = $sr.ReadToEnd(); $sr.Close(); return ($t -split "`n" | Select-String 'GamepadTweaks\] (observe|task)' | % { $_.Line.Trim() -replace '.*GamepadTweaks\] ', '' }) }
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
  $bad = @($l | ? { $_ -match 'landed on|gave up|error' }).Count
  $script:n++
  $ok = ($r -like "$expect*") -and $bad -eq 0
  if ($ok) { $script:pass++ } else { $script:fail++ }
  O ("{0:D2} {1,-6} expect {2,-22} got {3,-22} {4}  {5}  {6}" -f $script:n, $key, $expect, $r, $(if ($ok) { "PASS" } else { "FAIL" }), $note, ($l -join ' / '))
  if ($r -eq 'closed') { O "screen closed, stop"; Finish }
  return $r
}
function Finish {
  $null = Lua "local f = package.loadlib([[$DLL]], `"wspad_uninstall`"); if f then f() end; W(`"u`")"
  Remove-Item "$W\cmd.lua", "$W\pad.req", "$W\pad_connect.flag" -ErrorAction SilentlyContinue
  O "PASS $($script:pass)  FAIL $($script:fail)"
  O "--- proxy log"; Get-Content "$W\wsmod.log" -Encoding UTF8 -Tail 6 | % { O $_ }
  $script:out | Set-Content "$W\obs_verify.txt" -Encoding UTF8
  exit
}
Remove-Item "$W\pad_user.flag", "$W\pad_abort.flag" -ErrorAction SilentlyContinue
O ("start: " + (Lua $probe))
O ("install: " + (Lua "local f, e = package.loadlib([[$DLL]], `"wspad_install`"); if not f then W(`"loadlib failed `" .. tostring(e)) return end; f(); W(`"installed`")"))
New-Item -ItemType File -Force "$W\pad_connect.flag" | Out-Null; Start-Sleep -Milliseconds 200
Add-Type -Namespace WSM7 -Name M -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);'
$gw = (Get-Process JH-Win64-Shipping).MainWindowHandle; [void][WSM7.M]::PostMessageW($gw, 0x219, [IntPtr]7, [IntPtr]::Zero); Start-Sleep -Milliseconds 800
O "--- LT/RT and up"
$null = Check "SU" "Backpack" "bottom up -> backpack"
$null = Check "RT" "Bottom:QieCuo" ""
$null = Check "RT" "Backpack" ""
$null = Check "LT" "Bottom:QieCuo" ""
$null = Check "LT" "Backpack" ""
O "--- backpack left edge"
$null = Check "SD" "Backpack idx=6" ""
$null = Check "SR" "Backpack idx=7" ""
$null = Check "SL" "Backpack idx=6" ""
$null = Check "SL" "Backpack idx=6" "left edge: stays"
$null = Check "LEFT" "Backpack idx=6" "left edge d-pad: stays"
O "--- memory"
$null = Check "RT" "Bottom:QieCuo" ""
$null = Check "SR" "Bottom:SongLi" ""
$null = Check "LT" "Backpack idx=6" "same cell"
$null = Check "RT" "Bottom:SongLi" "same button"
$null = Check "UP" "Backpack idx=6" "d-pad up"
$null = Check "SR" "Backpack idx=7" ""
Finish
