param([int]$x = -1, [int]$y = -1, [string]$key = "")
# send a click (client coords, default centre) or a key to the game window WITHOUT bringing it to the front
if (-not ('WSBG.M' -as [type])) {
Add-Type -Namespace WSBG -Name M -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool GetClientRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint c, uint t);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(System.IntPtr h, System.Text.StringBuilder c, int n);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumCallback cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint p);
public delegate bool EnumCallback(System.IntPtr h, System.IntPtr p);
public struct RECT { public int L, T, R, B; }
'@
}
$game = Get-Process JH-Win64-Shipping -ErrorAction Stop
$script:gameId = $game.Id
$script:gameHwnd = [IntPtr]::Zero
$callback = [WSBG.M+EnumCallback]{
  param($window, $unused)
  $owner = [uint32]0
  [void][WSBG.M]::GetWindowThreadProcessId($window, [ref]$owner)
  if ($owner -eq $script:gameId) {
    $class = New-Object Text.StringBuilder 128
    [void][WSBG.M]::GetClassNameW($window, $class, $class.Capacity)
    if ($class.ToString() -eq 'UnrealWindow') { $script:gameHwnd = $window; return $false }
  }
  return $true
}
[void][WSBG.M]::EnumWindows($callback, [IntPtr]::Zero)
$h = $script:gameHwnd
if ($h -eq [IntPtr]::Zero) { throw 'Game UnrealWindow not found' }
if ($key) {
  $vk = switch ($key) { "space" { 0x20 } "enter" { 0x0D } "esc" { 0x1B } "e" { 0x45 } default { [int][char]$key.ToUpper() } }
  $sc = [WSBG.M]::MapVirtualKeyW($vk, 0)
  $down = [IntPtr](1 -bor ($sc -shl 16)); $up = [IntPtr]([int64]1 -bor ([int64]$sc -shl 16) -bor 0xC0000000)
  [void][WSBG.M]::PostMessageW($h, 0x100, [IntPtr]$vk, $down); Start-Sleep -Milliseconds 80
  [void][WSBG.M]::PostMessageW($h, 0x101, [IntPtr]$vk, $up)
  "key $key posted"; exit
}
$r = New-Object WSBG.M+RECT; [void][WSBG.M]::GetClientRect($h, [ref]$r)
if ($x -lt 0) { $x = [int]($r.R / 2) }; if ($y -lt 0) { $y = [int]($r.B / 2) }
$lp = [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF))
[void][WSBG.M]::PostMessageW($h, 0x200, [IntPtr]0, $lp); Start-Sleep -Milliseconds 50
[void][WSBG.M]::PostMessageW($h, 0x201, [IntPtr]1, $lp); Start-Sleep -Milliseconds 80
[void][WSBG.M]::PostMessageW($h, 0x202, [IntPtr]0, $lp)
"click posted at $x,$y (client $($r.R)x$($r.B))"
