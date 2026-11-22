# Hot-reload UE4SS mods: Ctrl+R to the game window (only if it is the foreground window), then wait for the log line.
param([string]$expect = "v4.10 loaded", [int]$wait = 15)
Add-Type -Namespace WSK -Name K -MemberDefinition @'
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(System.IntPtr h, out int pid);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
[DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
'@
$p = Get-Process JH-Win64-Shipping -ErrorAction Stop
$h = [WSK.K]::GetForegroundWindow(); $fp = 0; [void][WSK.K]::GetWindowThreadProcessId($h, [ref]$fp)
if ($fp -ne $p.Id) { "game is not the foreground window, not sending keys"; exit 1 }
$log = 'D:\GAME\Wandering Sword\Wandering_Sword\Binaries\Win64\ue4ss\UE4SS.log'
$before = (Get-Item $log).Length
function K([byte]$vk, [bool]$up) { [WSK.K]::keybd_event($vk, [byte][WSK.K]::MapVirtualKey($vk, 0), $(if ($up) { 2 } else { 0 }), [UIntPtr]::Zero) }
K 0x11 $false; Start-Sleep -Milliseconds 60; K 0x52 $false; Start-Sleep -Milliseconds 120; K 0x52 $true; Start-Sleep -Milliseconds 60; K 0x11 $true
"sent Ctrl+R"
$t0 = Get-Date
while (((Get-Date) - $t0).TotalSeconds -lt $wait) {
  Start-Sleep -Milliseconds 300
  $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite'); $fs.Seek($before, 'Begin') | Out-Null
  $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); $new = $sr.ReadToEnd(); $sr.Close()
  if ($new -match [regex]::Escape($expect)) { "reloaded: " + (($new -split "`n" | Select-String 'GamepadTweaks' | Select-Object -First 4 | % { $_.Line.Trim() }) -join ' || '); exit 0 }
}
"no reload line within $wait s"; exit 2
