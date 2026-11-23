# bring the game window to the foreground (Alt-tap trick so Windows allows it)
Add-Type -Namespace FGW -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int c);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
'@
$g = (Get-Process JH-Win64-Shipping -ErrorAction Stop).MainWindowHandle
if ([FGW.U]::GetForegroundWindow() -eq $g) { "already foreground"; exit 0 }
if ([FGW.U]::IsIconic($g)) { [void][FGW.U]::ShowWindow($g, 9) }
[FGW.U]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [FGW.U]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
[void][FGW.U]::SetForegroundWindow($g)
Start-Sleep -Milliseconds 400
if ([FGW.U]::GetForegroundWindow() -eq $g) { "game is foreground now"; exit 0 } else { "could not bring the game to the front"; exit 1 }
