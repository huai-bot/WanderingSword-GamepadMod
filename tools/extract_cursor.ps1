param(
  [string]$Game = 'D:\GAME\Wandering Sword',
  [string]$Data = 'D:\TOOLS\AWSdata\WanderingSword'
)
# Extracts the game's own sword cursor (Slate/MouseCursor.png, 37x35) from the pak into $Data\cursor.png.
# The pak stores it as a raw PNG near the end of the file; we scan for PNG headers with that size.
$ErrorActionPreference = 'Stop'
$pak = Join-Path $Game 'Wandering_Sword\Content\Paks\Wandering_Sword-WindowsNoEditor.pak'
if (-not ('WSPng.Scan' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @'
using System; using System.IO;
namespace WSPng { public static class Scan {
  public static byte[] Find(string path, int wantW, int wantH) {
    byte[] last = null;
    using (var f = File.OpenRead(path)) {
      int CH = 64 * 1024 * 1024; var b = new byte[CH + 64];
      for (long off = 0; off < f.Length; off += CH) {
        f.Seek(off, SeekOrigin.Begin); int n = f.Read(b, 0, b.Length);
        for (int j = 0; j + 33 < n; j++) {
          if (b[j] != 0x89 || b[j+1] != 0x50 || b[j+2] != 0x4E || b[j+3] != 0x47 || b[j+12] != 0x49 || b[j+13] != 0x48) continue;
          int w = (b[j+16] << 24) | (b[j+17] << 16) | (b[j+18] << 8) | b[j+19];
          int h = (b[j+20] << 24) | (b[j+21] << 16) | (b[j+22] << 8) | b[j+23];
          if (w != wantW || h != wantH) continue;
          var pb = new byte[300000];
          using (var g = File.OpenRead(path)) {
            g.Seek(off + j, SeekOrigin.Begin); int pn = g.Read(pb, 0, pb.Length);
            for (int k = 8; k + 8 < pn; k++) if (pb[k] == 0x49 && pb[k+1] == 0x45 && pb[k+2] == 0x4E && pb[k+3] == 0x44) {
              last = new byte[k + 8]; Array.Copy(pb, last, k + 8); break; }
          }
        }
      }
    }
    return last;
  }
} }
'@
}
$png = [WSPng.Scan]::Find($pak, 37, 35)
if (-not $png) { throw 'cursor PNG (37x35) not found in pak' }
New-Item -ItemType Directory -Force $Data | Out-Null
[IO.File]::WriteAllBytes((Join-Path $Data 'cursor.png'), $png)
"cursor.png extracted ($($png.Length) bytes) -> $Data"
