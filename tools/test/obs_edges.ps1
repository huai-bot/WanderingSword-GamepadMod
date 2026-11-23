# Measure the game's own navigation on the 观察 screen (injected left stick / d-pad / triggers), and log which
# moves go through ChangeNaviFocus. Aborts if the real controller is touched.
$W = 'D:\TOOLS\AWSdata\WanderingSword'
$DLL = 'D:\TOOLS\AWSdata\WanderingSword\tools\wspad\wspad5.dll'
$u = New-Object Text.UTF8Encoding $false
$probe = Get-Content "$W\tools\probe_obsnav.lua" -Raw -Encoding UTF8
function Lua([string]$src, [int]$waitMs = 3000) { Remove-Item "$W\cmd_out.txt" -ErrorAction SilentlyContinue; [IO.File]::WriteAllText("$W\cmd.lua", $src, $u); for ($i = 0; $i -lt [int]($waitMs / 50); $i++) { Start-Sleep -Milliseconds 50; if (Test-Path "$W\cmd_out.txt") { $r = Get-Content "$W\cmd_out.txt" -Raw -Encoding UTF8; if ($r -match '== done') { return (($r -replace "`r", "" -replace "== done", "").Trim() -replace "`n", " | ") } } }; return "(no reply)" }
$script:log = @()
function O([string]$s) { Write-Host $s; $script:log += $s }
function Done([string]$why) {
  if ($why) { O "STOP: $why" }
  $null = Lua "local f = package.loadlib([[$DLL]], `"wspad_uninstall`"); if f then f() end; W(`"u`")"
  Remove-Item "$W\cmd.lua", "$W\pad.req", "$W\pad_connect.flag" -ErrorAction SilentlyContinue
  O "=== navhook.log"; Get-Content "$W\navhook.log" -Encoding UTF8 -ErrorAction SilentlyContinue | % { O $_ }
  $script:log | Set-Content "$W\obs_edges.txt" -Encoding UTF8
  exit
}
function Key([string]$k) {
  Add-Content "$W\navhook.log" "---- $k" -Encoding UTF8
  Remove-Item "$W\pad_out.txt" -ErrorAction SilentlyContinue
  [IO.File]::WriteAllText("$W\pad.req", "$k 110", [Text.Encoding]::ASCII)
  $o = ""; for ($i = 0; $i -lt 100; $i++) { Start-Sleep -Milliseconds 30; if (Test-Path "$W\pad_out.txt") { $o = Get-Content "$W\pad_out.txt" -Raw; break } }
  if ($o -match 'ABORT') { Done "real controller used ($o)" }
  Start-Sleep -Milliseconds 450
  $r = Lua $probe
  if ($r -eq 'closed') { Done "observe screen closed after $k" }
  return $r
}
$head = 'local function live(o) if not o or not o:IsValid() then return false end local ok, n = pcall(function() return o:GetFName():ToString() end) return ok and not n:find("^Default__") end; local view; for _, v in ipairs(FindAllOf("BPMV_Observe_C") or {}) do if live(v) and v:IsVisible() then view = v end end; local vm = view:GetNeoUIVM(); '
function To([string]$key) { $null = Lua ($head + "local w = vm:ChangeNaviFocus(FName(`"$key`"), 0, `"`"); if w and w:IsValid() then w:SetFocus() end; W(`"to`")"); Start-Sleep -Milliseconds 500; return (Lua $probe) }
function ToBtn([string]$bn) { $null = Lua ($head + "view.$bn`:SetFocus(); W(`"to`")"); Start-Sleep -Milliseconds 500; return (Lua $probe) }
function T([string]$label, [string]$from, [string]$k) { $r = Key $k; O ("{0,-30} {1,-26} {2,-5} -> {3}" -f $label, $from, $k, $r); return $r }

Remove-Item "$W\pad_user.flag", "$W\pad_abort.flag", "$W\navhook.log" -ErrorAction SilentlyContinue
O ("start: " + (Lua $probe))
O ("install: " + (Lua "local f, e = package.loadlib([[$DLL]], `"wspad_install`"); if not f then W(`"loadlib failed `" .. tostring(e)) return end; f(); W(`"installed`")"))
New-Item -ItemType File -Force "$W\pad_connect.flag" | Out-Null; Start-Sleep -Milliseconds 200
Add-Type -Namespace WSM6 -Name M -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);'
$gw = (Get-Process JH-Win64-Shipping).MainWindowHandle; [void][WSM6.M]::PostMessageW($gw, 0x219, [IntPtr]7, [IntPtr]::Zero); Start-Sleep -Milliseconds 800
Remove-Item "$W\pad_out.txt" -ErrorAction SilentlyContinue; [IO.File]::WriteAllText("$W\pad.req", "- 300", [Text.Encoding]::ASCII); Start-Sleep -Milliseconds 700
O ("poll check: " + (Get-Content "$W\pad_out.txt" -Raw -ErrorAction SilentlyContinue))
# hook ChangeNaviFocus (logging only)
O ("hook: " + (Lua @'
if _G.__obsHook then W("already") return end
_G.__obsHook = true
local log = [[D:\TOOLS\AWSdata\WanderingSword\navhook.log]]
RegisterHook("/Script/NeoUI.NeoUIUniversalModuleVMBase:ChangeNaviFocus", function(self, id, scen, str)
  local s, sc, who = "?", "?", "?"
  pcall(function() s = id:get():ToString() end); pcall(function() sc = tostring(scen:get()) end); pcall(function() who = self:get():GetClass():GetFName():ToString() end)
  local f = io.open(log, "a"); if f then f:write(string.format("%.3f ChangeNaviFocus %s scen=%s on %s\n", os.clock(), s, sc, who)); f:close() end
end)
W("hooked")
'@))
O "--- d-pad vs stick sanity"
$r = To "Property"; O "at $r"; $null = T "Property dpad DOWN" $r "DOWN"
$r = To "Property"; $null = T "Property stick DOWN" $r "SD"
O "--- triggers / shoulders from each region"
foreach ($k in 'RT', 'LT', 'RB', 'LB') { $r = To "Property"; $null = T "Property $k" $r $k }
foreach ($k in 'RT', 'LT') { $r = To "Backpack"; $null = T "Backpack $k" $r $k }
foreach ($k in 'RT', 'LT') { $r = ToBtn "BTN_QieCuo"; $null = T "QieCuo $k" $r $k }
O "--- property edges"
foreach ($k in 'SL', 'SR', 'SU') { $r = To "Property"; $null = T "Property $k" $r $k }
$r = To "Property"; $p = $r; for ($i = 0; $i -lt 8; $i++) { $r = T "Property SD walk" $p "SD"; if ($r -ne $p) { if ($r -notlike 'Property*') { break } }; $p = $r }
O "--- equip edges"
foreach ($k in 'SL', 'SR', 'SU', 'SD') { $r = To "Equip"; $null = T "Equip $k" $r $k }
$r = To "Equip"; $p = $r; for ($i = 0; $i -lt 6; $i++) { $r = T "Equip SD walk" $p "SD"; if ($r -notlike 'Equip*') { break }; $p = $r }
O "--- backpack edges"
$r = To "Backpack"; O "backpack entered: $r"
$r = T "Backpack SD" $r "SD"
$r = T "Backpack(idx) SL" $r "SL"
$r = To "Backpack"; $r = T "Backpack SU" $r "SU"; $r = T "Backpack SU again" $r "SU"
$r = To "Backpack"; $r = T "Backpack SR" $r "SR"
$r = To "Backpack"; $r = Key "SD"; $p = $r; for ($i = 0; $i -lt 14; $i++) { $r = T "Backpack SD walk" $p "SD"; if ($r -eq $p -or $r -notlike 'Backpack*') { break }; $p = $r }
O "--- bottom row"
$r = ToBtn "BTN_QieCuo"; $null = T "QieCuo SL" $r "SL"
$r = ToBtn "BTN_QieCuo"; $null = T "QieCuo SU" $r "SU"
$r = ToBtn "BTN_QieCuo"; $null = T "QieCuo SD" $r "SD"
$r = ToBtn "BTN_QieCuo"; $r = T "QieCuo SR" $r "SR"; $r = T "SongLi SR" $r "SR"; $r = T "QingJiao SR" $r "SR"
$r = ToBtn "BTN_SongLi"; $null = T "SongLi SU" $r "SU"
$r = ToBtn "BTN_QingJiao"; $null = T "QingJiao SU" $r "SU"
$r = ToBtn "BTN_QieCuo"; $null = T "QieCuo dpad UP" $r "UP"
$null = To "Property"
Done ""
