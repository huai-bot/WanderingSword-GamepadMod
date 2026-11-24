param(
  [string]$Game = 'D:\GAME\Wandering Sword',
  [string]$Data = 'D:\TOOLS\AWSdata\WanderingSword',
  [string]$Backup = '',
  [switch]$NoBackup
)
# Installs build\xinput1_3.dll, the Lua mod and the data files. Backups are on unless explicitly skipped.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$win64 = Join-Path $Game 'Wandering_Sword\Binaries\Win64'
$mods = Join-Path $win64 'ue4ss\Mods'
if (-not (Test-Path (Join-Path $win64 'ue4ss\UE4SS.dll'))) { throw "UE4SS not found under $win64 - install RE-UE4SS v4.0.0 first" }
$dll = Join-Path $root 'build\xinput1_3.dll'
if (-not (Test-Path $dll)) { throw "build\xinput1_3.dll missing - run tools\build.bat first" }

if (Get-Process -Name JH,JH-Win64-Shipping -ErrorAction SilentlyContinue) { throw 'Exit the game normally before installing.' }
$stamp = Get-Date -Format yyyyMMdd_HHmmss
if (-not $Backup) { $Backup = "D:\TOOLS\dshdata\dshbackup\WanderingSword-install_$stamp" }
$bak = [IO.Path]::GetFullPath($Backup)
function BackupFile([string]$source, [string]$relative) {
  if ($NoBackup) { return }
  $dest = Join-Path $bak $relative
  if ((Test-Path -LiteralPath $source) -and -not (Test-Path -LiteralPath $dest)) {
    New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null
    Copy-Item -LiteralPath $source -Destination $dest
  }
}

# Prepare the UE4SS settings first. These only control windows; UE4SS.log remains enabled.
$settings = Join-Path $win64 'ue4ss\UE4SS-settings.ini'
$utf8 = New-Object Text.UTF8Encoding $false
$text = [IO.File]::ReadAllText($settings, $utf8)
foreach ($key in @('ConsoleEnabled', 'GuiConsoleEnabled', 'GuiConsoleVisible')) {
  if ($text -notmatch "(?m)^\s*$key\s*=\s*\d+") { throw "UE4SS setting missing: $key" }
  $text = [regex]::Replace($text, "(?m)^(\s*$key\s*=\s*)\d+", '${1}0')
}
BackupFile $settings 'game\ue4ss\UE4SS-settings.ini'

# native: replace only with the game closed, without deleting or renaming a loaded DLL
$target = Join-Path $win64 'xinput1_3.dll'
BackupFile $target 'game\xinput1_3.dll'
Copy-Item -LiteralPath $dll -Destination $target -Force

# lua (must stay UTF-8 without BOM)
$lua = Join-Path $mods 'GamepadTweaks\Scripts\main.lua'
BackupFile $lua 'game\ue4ss\Mods\GamepadTweaks\Scripts\main.lua'
New-Item -ItemType Directory -Force (Split-Path $lua -Parent) | Out-Null
Copy-Item (Join-Path $root 'src\lua\main.lua') $lua -Force
$modsTxt = Join-Path $mods 'mods.txt'
if (-not (Test-Path -LiteralPath $modsTxt) -or -not (Select-String $modsTxt -Pattern '^\s*GamepadTweaks\s*:' -Quiet)) {
  BackupFile $modsTxt 'game\ue4ss\Mods\mods.txt'
  Add-Content $modsTxt "`r`nGamepadTweaks : 1"
}
[IO.File]::WriteAllText($settings, $text, $utf8)

# data: keep the user's existing configuration
New-Item -ItemType Directory -Force $Data | Out-Null
$places = Join-Path $Data 'places.txt'
BackupFile $places 'data\places.txt'
Copy-Item (Join-Path $root 'data\places.txt') $places -Force
if (-not (Test-Path (Join-Path $Data 'wsmod.ini'))) { Copy-Item (Join-Path $root 'data\wsmod.ini') (Join-Path $Data 'wsmod.ini') }
if (-not (Test-Path (Join-Path $Data 'cursor.png'))) { Write-Warning 'cursor.png missing - run tools\extract_cursor.ps1 (pointer overlay will be invisible without it)' }
if ($NoBackup) { 'installed (log windows hidden). backup skipped by request.' }
else { "installed (log windows hidden). backup: $bak" }
