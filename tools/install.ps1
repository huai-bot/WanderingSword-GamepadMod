param(
  [string]$Game = 'D:\GAME\Wandering Sword',
  [string]$Data = 'D:\TOOLS\AWSdata\WanderingSword'
)
# Installs build\xinput1_3.dll, the Lua mod and the data files. Backs up what it replaces.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$win64 = Join-Path $Game 'Wandering_Sword\Binaries\Win64'
$mods = Join-Path $win64 'ue4ss\Mods'
if (-not (Test-Path (Join-Path $win64 'ue4ss\UE4SS.dll'))) { throw "UE4SS not found under $win64 - install RE-UE4SS v4.0.0 first" }
$dll = Join-Path $root 'build\xinput1_3.dll'
if (-not (Test-Path $dll)) { throw "build\xinput1_3.dll missing - run tools\build.bat first" }

$stamp = Get-Date -Format yyyyMMdd_HHmmss
$bak = Join-Path $Data "backup\install_$stamp"
New-Item -ItemType Directory -Force $bak | Out-Null
New-Item -ItemType Directory -Force (Join-Path $mods 'GamepadTweaks\Scripts') | Out-Null

# native: the game keeps the dll locked while running -> rename the old one, new one loads on next start
$target = Join-Path $win64 'xinput1_3.dll'
if (Test-Path $target) {
  Copy-Item $target (Join-Path $bak 'xinput1_3.dll')
  try { Remove-Item $target -ErrorAction Stop } catch { Rename-Item $target ("xinput1_3.old_$stamp") }
}
Copy-Item $dll $target

# lua (must stay UTF-8 without BOM)
$lua = Join-Path $mods 'GamepadTweaks\Scripts\main.lua'
if (Test-Path $lua) { Copy-Item $lua (Join-Path $bak 'main.lua') }
Copy-Item (Join-Path $root 'src\lua\main.lua') $lua
$modsTxt = Join-Path $mods 'mods.txt'
if (-not (Select-String $modsTxt -Pattern '^\s*GamepadTweaks\s*:' -Quiet)) { Add-Content $modsTxt "`r`nGamepadTweaks : 1" }

# data
New-Item -ItemType Directory -Force $Data | Out-Null
Copy-Item (Join-Path $root 'data\places.txt') (Join-Path $Data 'places.txt') -Force
if (-not (Test-Path (Join-Path $Data 'wsmod.ini'))) { Copy-Item (Join-Path $root 'data\wsmod.ini') (Join-Path $Data 'wsmod.ini') }
if (-not (Test-Path (Join-Path $Data 'cursor.png'))) { Write-Warning 'cursor.png missing - run tools\extract_cursor.ps1 (pointer overlay will be invisible without it)' }
"installed. backup: $bak"
