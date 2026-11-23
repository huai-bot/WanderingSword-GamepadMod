param([string]$keys = "B", [string]$shot = "")
# press keys via the injector (installs/uninstalls around it), then optionally take a screenshot
$W = 'D:\TOOLS\AWSdata\WanderingSword'
$DLL = 'D:\TOOLS\AWSdata\WanderingSword\tools\wspad\wspad5.dll'
$u = New-Object Text.UTF8Encoding $false
function Lua([string]$src) { Remove-Item "$W\cmd_out.txt" -ErrorAction SilentlyContinue; [IO.File]::WriteAllText("$W\cmd.lua", $src, $u); for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Milliseconds 50; if (Test-Path "$W\cmd_out.txt") { $r = Get-Content "$W\cmd_out.txt" -Raw -Encoding UTF8; if ($r -match '== done') { return (($r -replace "`r", "" -replace "== done", "").Trim()) } } }; return "(no reply)" }
$null = Lua "local f = package.loadlib([[$DLL]], `"wspad_install`"); f(); W(`"i`")"
New-Item -ItemType File -Force "$W\pad_connect.flag" | Out-Null; Start-Sleep -Milliseconds 150
if (-not ('WSMP.M' -as [type])) { Add-Type -Namespace WSMP -Name M -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);' }
$gw = (Get-Process JH-Win64-Shipping).MainWindowHandle; [void][WSMP.M]::PostMessageW($gw, 0x219, [IntPtr]7, [IntPtr]::Zero); Start-Sleep -Milliseconds 600
foreach ($k in ($keys -split ',')) {
  Remove-Item "$W\pad_out.txt" -ErrorAction SilentlyContinue
  [IO.File]::WriteAllText("$W\pad.req", "$k 120", [Text.Encoding]::ASCII)
  $o = ""; for ($i = 0; $i -lt 100; $i++) { Start-Sleep -Milliseconds 30; if (Test-Path "$W\pad_out.txt") { $o = Get-Content "$W\pad_out.txt" -Raw; break } }
  if ($o -match 'ABORT') { "ABORT $o"; break }
  Start-Sleep -Milliseconds 900
}
$null = Lua "local f = package.loadlib([[$DLL]], `"wspad_uninstall`"); f(); W(`"u`")"
Remove-Item "$W\pad_connect.flag", "$W\cmd.lua" -ErrorAction SilentlyContinue
if ($shot) { & "$W\tools\capture.ps1" -out $shot | Out-Null; "shot $shot" }
