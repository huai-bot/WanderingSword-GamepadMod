# Restart the GamepadTweaks Lua mod from inside the game (no Ctrl+R, no focus needed):
# compile-check main.lua in the game, install it, then RestartCurrentMod() via the cmd.lua channel.
param([string]$expect = "loaded")
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$W = 'D:\TOOLS\AWSdata\WanderingSword'
$g = 'D:\GAME\Wandering Sword\Wandering_Sword\Binaries\Win64'
$u = New-Object Text.UTF8Encoding $false
function Lua([string]$src) { Remove-Item "$W\cmd_out.txt" -ErrorAction SilentlyContinue; [IO.File]::WriteAllText("$W\cmd.lua", $src, $u); for ($i = 0; $i -lt 100; $i++) { Start-Sleep -Milliseconds 50; if (Test-Path "$W\cmd_out.txt") { $r = Get-Content "$W\cmd_out.txt" -Raw -Encoding UTF8; if ($r -match '== done') { return (($r -replace "`r", "" -replace "== done", "").Trim()) } } }; return "(no reply)" }
$src = "$Repo\src\lua\main.lua"
if ([IO.File]::ReadAllBytes($src)[0] -eq 0xEF) { "HAS BOM"; exit 1 }
$r = Lua "local f = io.open([[$src]], `"r`"); local s = f:read(`"*a`"); f:close(); local fn, err = load(s, `"main`", `"t`", {}); W(`"compile `" .. (fn and `"OK`" or (`"ERROR `" .. tostring(err))))"
$r; if ($r -notmatch 'compile OK') { "NOT INSTALLING"; exit 1 }
Copy-Item $src "$g\ue4ss\Mods\GamepadTweaks\Scripts\main.lua" -Force
Copy-Item $src "$W\src\main_v4.lua" -Force
$pos = (Get-Item "$g\ue4ss\UE4SS.log").Length
"restart: " + (Lua 'ExecuteWithDelay(200, function() RestartCurrentMod() end); W("queued")')
Remove-Item "$W\cmd.lua" -ErrorAction SilentlyContinue
for ($i = 0; $i -lt 20; $i++) {
  Start-Sleep -Milliseconds 300
  $fs = [IO.File]::Open("$g\ue4ss\UE4SS.log", 'Open', 'Read', 'ReadWrite'); $fs.Seek($pos, 'Begin') | Out-Null; $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); $t = $sr.ReadToEnd(); $sr.Close()
  if ($t -match "GamepadTweaks\] v[\d\.]+ $expect") { ($t -split "`n" | Select-String 'GamepadTweaks\] v[\d\.]+ loaded').Line.Trim(); exit 0 }
}
"no load line after restart"; exit 2
