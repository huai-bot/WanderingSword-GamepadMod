# Poll a read-only Lua probe through the cmd.lua channel and print every change.
# usage: powershell -File poll_probe.ps1 -probe probe_nav.lua -seconds 80 [-gapMs 250]
param([string]$probe = "probe_nav.lua", [int]$seconds = 80, [int]$gapMs = 250)
$W = 'D:\TOOLS\AWSdata\WanderingSword'
$src = Get-Content "$W\tools\$probe" -Raw -Encoding UTF8
$u = New-Object Text.UTF8Encoding $false
$last = ''; $t0 = Get-Date
while (((Get-Date) - $t0).TotalSeconds -lt $seconds) {
  Remove-Item "$W\cmd_out.txt" -ErrorAction SilentlyContinue
  [IO.File]::WriteAllText("$W\cmd.lua", $src, $u)
  $ok = $false
  for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Milliseconds 50; if (Test-Path "$W\cmd_out.txt") { $r = Get-Content "$W\cmd_out.txt" -Raw -Encoding UTF8; if ($r -match '== done') { $ok = $true; break } } }
  if ($ok) { $s = ($r -replace "`r", "" -replace "== done", "").Trim() -replace "`n", " | "; if ($s -ne $last) { "{0:mm:ss.f} {1}" -f (Get-Date), $s; $last = $s } }
  else { "{0:mm:ss.f} (no reply)" -f (Get-Date) }
  Start-Sleep -Milliseconds $gapMs
}
Remove-Item "$W\cmd.lua" -ErrorAction SilentlyContinue
"done"
