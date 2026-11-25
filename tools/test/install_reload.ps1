# compile-check main.lua inside the game, install it, close the character screen, hot-reload (Ctrl+R)
param([string]$expect = "v4.10 loaded", [string]$backupName = "")
$ErrorActionPreference = 'Stop'
$W = 'D:\TOOLS\AWSdata\WanderingSword'; $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent; $g = 'D:\GAME\Wandering Sword\Wandering_Sword\Binaries\Win64'
$u = New-Object Text.UTF8Encoding $false
function Lua([string]$src, [int]$waitMs = 3000) {
  Remove-Item "$W\cmd_out.txt" -ErrorAction SilentlyContinue
  [IO.File]::WriteAllText("$W\cmd.lua", $src, $u)
  for ($i = 0; $i -lt [int]($waitMs / 50); $i++) { Start-Sleep -Milliseconds 50; if (Test-Path "$W\cmd_out.txt") { $r = Get-Content "$W\cmd_out.txt" -Raw -Encoding UTF8; if ($r -match '== done') { return (($r -replace "`r", "" -replace "== done", "").Trim() -replace "`n", " | ") } } }
  return "(no reply)"
}
$src = "$Repo\src\lua\main.lua"
if ([IO.File]::ReadAllBytes($src)[0] -eq 0xEF) { "HAS BOM"; exit 1 }
$r = Lua "local f = io.open([[$src]], `"r`"); local s = f:read(`"*a`"); f:close(); local fn, err = load(s, `"main`", `"t`", {}); W(`"compile `" .. (fn and `"OK`" or (`"ERROR `" .. tostring(err))))"
$r
if ($r -notmatch 'compile OK') { "NOT INSTALLING"; exit 1 }
if ($backupName) { Copy-Item "$g\ue4ss\Mods\GamepadTweaks\Scripts\main.lua" "$W\backup\$backupName" -Force }
Copy-Item $src "$g\ue4ss\Mods\GamepadTweaks\Scripts\main.lua" -Force
Copy-Item $src "$W\src\main_v4.lua" -Force
"installed, same hash: " + ((Get-FileHash $src).Hash -eq (Get-FileHash "$g\ue4ss\Mods\GamepadTweaks\Scripts\main.lua").Hash)
"close screen: " + (Lua 'for _, v in ipairs(FindAllOf("JHNeoUIPrimeModuleVM") or {}) do if v:IsValid() and not v:GetFName():ToString():find("^Default__") then v:Hide() end end; W("hidden")')
Start-Sleep 1
Remove-Item "$W\cmd.lua" -ErrorAction SilentlyContinue
powershell -NoProfile -ExecutionPolicy Bypass -File "$W\tools\hot_reload.ps1" -expect $expect
