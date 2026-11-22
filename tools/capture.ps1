param([string]$out = 'D:\TOOLS\AWSdata\WanderingSword\game_shot.png', [int]$cx = 0, [int]$cy = 0, [int]$cw = 0, [int]$ch = 0)
Add-Type -AssemblyName System.Drawing
if (-not ('WSCap.N' -as [type])) {
Add-Type -Namespace WSCap -Name N -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool PrintWindow(System.IntPtr h, System.IntPtr hdc, uint f);
[DllImport("user32.dll")] public static extern bool GetClientRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr l);
public struct RECT { public int L, T, R, B; }
public static System.IntPtr Find(uint pid) {
  System.IntPtr best = System.IntPtr.Zero; long bestArea = 0;
  EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p != pid) return true;
    var sb = new System.Text.StringBuilder(64); GetClassName(h, sb, 64); if (sb.ToString() != "UnrealWindow") return true;
    RECT r; GetClientRect(h, out r); long a = (long)r.R * r.B; if (a > bestArea) { bestArea = a; best = h; } return true; }, System.IntPtr.Zero);
  return best;
}
'@
}
[WSCap.N]::SetProcessDPIAware() | Out-Null
$p = Get-Process JH-Win64-Shipping -ErrorAction Stop | Select-Object -First 1
$h = [WSCap.N]::Find([uint32]$p.Id)
$r = New-Object WSCap.N+RECT; [WSCap.N]::GetClientRect($h, [ref]$r) | Out-Null
$bmp = New-Object Drawing.Bitmap $r.R, $r.B; $g = [Drawing.Graphics]::FromImage($bmp); $hdc = $g.GetHdc(); [WSCap.N]::PrintWindow($h, $hdc, 3) | Out-Null; $g.ReleaseHdc($hdc)
if ($cw -gt 0) { $img = $bmp.Clone((New-Object Drawing.Rectangle $cx, $cy, $cw, $ch), $bmp.PixelFormat) }
else { $img = New-Object Drawing.Bitmap 1280, 720; [Drawing.Graphics]::FromImage($img).DrawImage($bmp, 0, 0, 1280, 720) }
$img.Save($out); "captured $($r.R)x$($r.B) -> $out"
