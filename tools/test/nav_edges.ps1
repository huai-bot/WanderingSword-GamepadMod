# Measure the game's own navigation at every edge of the character screen (prime_skip_panels temporarily 0).
# Aborts at once if the real controller is touched.
$W = 'D:\TOOLS\AWSdata\WanderingSword'
$DLL = 'D:\TOOLS\AWSdata\WanderingSword\tools\wspad\wspad5.dll'
$u = New-Object Text.UTF8Encoding $false
$e9 = [Text.Encoding]::GetEncoding(936)
$probe = Get-Content "$W\tools\probe_nav3.lua" -Raw -Encoding UTF8
function Lua([string]$src, [int]$waitMs = 3000) {
  Remove-Item "$W\cmd_out.txt" -ErrorAction SilentlyContinue
  [IO.File]::WriteAllText("$W\cmd.lua", $src, $u)
  for ($i = 0; $i -lt [int]($waitMs / 50); $i++) { Start-Sleep -Milliseconds 50; if (Test-Path "$W\cmd_out.txt") { $r = Get-Content "$W\cmd_out.txt" -Raw -Encoding UTF8; if ($r -match '== done') { return (($r -replace "`r", "" -replace "== done", "").Trim() -replace "`n", " | ") } } }
  return "(no reply)"
}
function SetIni([int]$v) { $f = "$W\wsmod.ini"; $t = [IO.File]::ReadAllText($f, $e9); $t = [regex]::Replace($t, '(?m)^prime_skip_panels=\d', "prime_skip_panels=$v"); [IO.File]::WriteAllText($f, $t, $e9) }
$open = 'for _, v in ipairs(FindAllOf("JHNeoUIPrimeModuleVM") or {}) do if v:IsValid() and not v:GetFName():ToString():find("^Default__") then v:Show() end end; W("show")'
$hide = 'for _, v in ipairs(FindAllOf("JHNeoUIPrimeModuleVM") or {}) do if v:IsValid() and not v:GetFName():ToString():find("^Default__") then v:Hide() end end; W("hide")'
$head = 'local function live(o) if not o or not o:IsValid() then return false end local ok, n = pcall(function() return o:GetFName():ToString() end) return ok and not n:find("^Default__") end; local team; for _, v in ipairs(FindAllOf("BPMV_PrimeTeam_C") or {}) do if live(v) then team = v end end; local vm = team:GetNeoUIVM(); '
function To([string]$key) { $null = Lua ($head + "local w = vm:ChangeNaviFocus(FName(`"$key`"), 0, `"`"); if w and w:IsValid() then w:SetFocus() end; W(`"to`")"); Start-Sleep -Milliseconds 500 }
function ToBtn([string]$bn) { $null = Lua ($head + "team.$bn`:SetFocus(); W(`"to`")"); Start-Sleep -Milliseconds 500 }
$script:log = @()
function Out([string]$s) { Write-Host $s; $script:log += $s }
function Done([string]$why) {
  if ($why) { Out "STOP: $why" }
  SetIni 1
  $null = Lua $hide; Start-Sleep 1; $null = Lua $open; Start-Sleep 2
  Out ("after restore: " + (Lua $probe))
  $null = Lua "local f = package.loadlib([[$DLL]], `"wspad_uninstall`"); if f then f() end; W(`"u`")"
  Remove-Item "$W\cmd.lua", "$W\pad.req", "$W\pad_connect.flag" -ErrorAction SilentlyContinue
  $script:log | Set-Content "$W\nav_edges.txt" -Encoding UTF8
  exit
}
function Key([string]$k) {
  Remove-Item "$W\pad_out.txt" -ErrorAction SilentlyContinue
  [IO.File]::WriteAllText("$W\pad.req", "$k 110", [Text.Encoding]::ASCII)
  $o = ""; for ($i = 0; $i -lt 100; $i++) { Start-Sleep -Milliseconds 30; if (Test-Path "$W\pad_out.txt") { $o = Get-Content "$W\pad_out.txt" -Raw; break } }
  if ($o -match 'ABORT') { Done "real controller used ($o)" }
  Start-Sleep -Milliseconds 420
  return (Lua $probe)
}
function Walk([string]$label, [string]$k, [int]$max) {
  $prev = Lua $probe; $path = @($prev)
  for ($i = 0; $i -lt $max; $i++) {
    $r = Key $k; $path += $r
    if ($r -notlike ($prev.Split(' ')[0] + '*')) { break }   # left the region
    if ($r -eq $prev) { break }                                # stuck
    $prev = $r
  }
  Out ("{0,-26} {1}" -f $label, ($path -join '  ->  '))
}

Remove-Item "$W\pad_user.flag", "$W\pad_abort.flag" -ErrorAction SilentlyContinue
$f = Lua (Get-Content "$W\tools\probe_fight.lua" -Raw -Encoding UTF8); Out "state: $f"
if ($f -notmatch '^calm') { Out "not calm"; exit }
Out ("install: " + (Lua "local f, e = package.loadlib([[$DLL]], `"wspad_install`"); if not f then W(`"loadlib failed `" .. tostring(e)) return end; f(); W(`"installed`")"))
New-Item -ItemType File -Force "$W\pad_connect.flag" | Out-Null; Start-Sleep -Milliseconds 200
Add-Type -Namespace WSM2 -Name M -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);'
$gw = (Get-Process JH-Win64-Shipping).MainWindowHandle; [void][WSM2.M]::PostMessageW($gw, 0x219, [IntPtr]7, [IntPtr]::Zero); Start-Sleep -Milliseconds 800
Remove-Item "$W\pad_out.txt" -ErrorAction SilentlyContinue; [IO.File]::WriteAllText("$W\pad.req", "- 300", [Text.Encoding]::ASCII); Start-Sleep -Milliseconds 700
Out ("poll check: " + (Get-Content "$W\pad_out.txt" -Raw -ErrorAction SilentlyContinue))
SetIni 0
$null = Lua $hide; Start-Sleep 1; $null = Lua $open; Start-Sleep 3
Out ("open: " + (Lua $probe))

# --- side bar: every cell, RIGHT and LEFT
for ($k = 0; $k -le 4; $k++) {
  To "SideBar"; for ($j = 0; $j -lt $k; $j++) { $null = Key "SD" }
  $c = Lua $probe; $r = Key "SR"; Out ("side DOWNx{0} RIGHT           {1}  ->  {2}" -f $k, $c, $r)
}
To "SideBar"; $c = Lua $probe; $r = Key "SL"; Out ("side LEFT                  $c  ->  $r")
To "SideBar"; $c = Lua $probe; $r = Key "SR"; Out ("side stick-RIGHT           $c  ->  $r")
To "SideBar"; Walk "side UP walk" "SU" 6
To "SideBar"; Walk "side DOWN walk" "SD" 8
# --- backpack edges
To "Backpack"; Walk "bp LEFT walk" "SL" 8
To "Backpack"; Walk "bp UP walk" "SU" 12
To "Backpack"; Walk "bp DOWN walk" "SD" 30
To "Backpack"; Walk "bp RIGHT walk" "SR" 8
To "Backpack"; $null = Key "SD"; Walk "bp row2 LEFT walk" "SL" 8
To "Backpack"; $null = Key "SD"; $null = Key "SR"; $null = Key "SR"; Walk "bp row2 col3 LEFT walk" "SL" 8
To "Backpack"; $c = Lua $probe; $r = Key "SL"; Out ("bp stick-LEFT              $c  ->  $r")
# --- bottom row
ToBtn "BTN_FormatonOut"; $c = Lua $probe; $r = Key "SL"; Out ("btm first LEFT             $c  ->  $r")
ToBtn "BTN_FormatonOut"; $c = Lua $probe; $r = Key "SD"; Out ("btm first DOWN             $c  ->  $r")
ToBtn "BTN_FormatonOut"; $c = Lua $probe; $r = Key "SU"; Out ("btm first UP               $c  ->  $r")
ToBtn "BTN_MountPet"; $c = Lua $probe; $r = Key "SR"; Out ("btm last RIGHT             $c  ->  $r")
ToBtn "BTN_MountPet"; $c = Lua $probe; $r = Key "SU"; Out ("btm last UP                $c  ->  $r")
ToBtn "BTN_MountPet"; $c = Lua $probe; $r = Key "SU"; Out ("btm last stick-UP          $c  ->  $r")
# --- what leads INTO the bottom row natively (besides Property DOWN)
To "Backpack"; Walk "bp DOWN walk (again)" "SD" 30
# --- column structure: from idx 0 go right k cells then LEFT until leaving
for ($k = 1; $k -le 7; $k++) { To "Backpack"; for ($j = 0; $j -lt $k; $j++) { $null = Key "SR" }; Walk ("bp right{0} then LEFT walk" -f $k) "SL" 9 }
# --- d-pad once more for the record
To "SideBar"; $c = Lua $probe; $r = Key "RIGHT"; Out ("side DPAD-RIGHT            $c  ->  $r")
Done ""
