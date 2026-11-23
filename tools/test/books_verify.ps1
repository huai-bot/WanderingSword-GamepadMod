# check the 学成-book hiding on the 人物 screen: open, count book cells in 全部 and in 秘籍
$W = 'D:\TOOLS\AWSdata\WanderingSword'
$u = New-Object Text.UTF8Encoding $false
$g = 'D:\GAME\Wandering Sword\Wandering_Sword\Binaries\Win64'
function Lua([string]$src) { Remove-Item "$W\cmd_out.txt" -ErrorAction SilentlyContinue; [IO.File]::WriteAllText("$W\cmd.lua", $src, $u); for ($i = 0; $i -lt 80; $i++) { Start-Sleep -Milliseconds 50; if (Test-Path "$W\cmd_out.txt") { $r = Get-Content "$W\cmd_out.txt" -Raw -Encoding UTF8; if ($r -match '== done') { return (($r -replace "`r", "" -replace "== done", "").Trim()) } } }; return "(no reply)" }
$count = @'
local function live(o) if not o or not o:IsValid() then return false end local ok, n = pcall(function() return o:GetFName():ToString() end) return ok and not n:find("^Default__") end
local bv; for _, x in ipairs(FindAllOf("BPMV_JHBackpack_Basic_C") or {}) do if live(x) and x:IsVisible() then bv = x end end
if not bv then W("no backpack") return end
local vm; for _, v in ipairs(FindAllOf("JHMainCharacterBackpackInTeamVM") or {}) do if live(v) then vm = v end end
local vn = bv:GetFName():ToString()
local inList = {}
local items = bv.GRID_ITEM:GetListItems()
if type(items) == "table" then for _, sp in ipairs(items) do if type(sp) == "userdata" and sp.get and not sp.IsValid then sp = sp:get() end; pcall(function() inList[sp:GetAddress()] = true end) end end
local shown, acq = 0, 0
for _, en in ipairs(FindAllOf("BPEntry_Item_WDT_C") or {}) do
  if live(en) and en:IsVisible() and en:GetFullName():find(vn, 1, true) and en:GetRenderOpacity() > 0.5 then
    local listed = false; pcall(function() listed = inList[en:GetBindedDataObj():GetAddress()] == true end)
    local js = ""; pcall(function() js = en.ItemDisplay:GetData():DataToString():ToString() end)
    local it = tonumber(js:match('"item_type":(%d+)'))
    if listed and it and it >= 30 and it <= 38 then shown = shown + 1; if js:find('"is_acquired":true', 1, true) then acq = acq + 1 end end
  end
end
W(string.format("tab=%s books shown=%d of which 学成=%d (grid %d)", tostring(vm:GetFilterIndex()), shown, acq, bv.GRID_ITEM:GetNumItems()))
'@
$show = 'for _, v in ipairs(FindAllOf("JHNeoUIPrimeModuleVM") or {}) do if v:IsValid() and not v:GetFName():ToString():find("^Default__") then v:Show() end end; W("show")'
$hide = 'for _, v in ipairs(FindAllOf("JHNeoUIPrimeModuleVM") or {}) do if v:IsValid() and not v:GetFName():ToString():find("^Default__") then v:Hide() end end; W("hide")'
foreach ($round in 1, 2) {
  $pos = (Get-Item "$g\ue4ss\UE4SS.log").Length
  $null = Lua $show; Start-Sleep 3
  "round $round, 全部: " + (Lua $count)
  if ($round -eq 1) { & "$W\tools\capture.ps1" -out "$W\nav_shots\books_all.png" | Out-Null }
  $fs = [IO.File]::Open("$g\ue4ss\UE4SS.log", 'Open', 'Read', 'ReadWrite'); $fs.Seek($pos, 'Begin') | Out-Null; $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); $t = $sr.ReadToEnd(); $sr.Close()
  $t -split "`n" | Select-String 'GamepadTweaks\] backpack: npc' | % { "   " + ($_.Line.Trim() -replace '.*GamepadTweaks\] ', '') }
  if ($round -eq 2) {
    powershell -NoProfile -ExecutionPolicy Bypass -File "$W\tools\game_front.ps1" | Out-Null
    powershell -NoProfile -ExecutionPolicy Bypass -File "$W\tools\press.ps1" -keys "RB,RB,RB,RB"
    Start-Sleep 1; "秘籍 tab: " + (Lua $count)
    & "$W\tools\capture.ps1" -out "$W\nav_shots\books_tab.png" | Out-Null
    powershell -NoProfile -ExecutionPolicy Bypass -File "$W\tools\press.ps1" -keys "LB,LB,LB,LB"
    Start-Sleep 1; "back to 全部: " + (Lua $count)
  }
  $null = Lua $hide; Start-Sleep 1.5
}
"books file: " + (@(Get-Content "$W\acquired_books.txt" -ErrorAction SilentlyContinue).Count) + " ids"
$null = Lua $show
Remove-Item "$W\cmd.lua" -ErrorAction SilentlyContinue
