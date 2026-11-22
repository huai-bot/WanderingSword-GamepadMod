-- read-only: which region of the character screen holds the gamepad focus (HasFocusedDescendants)
local function live(o) if not o or not o:IsValid() then return false end local ok, n = pcall(function() return o:GetFName():ToString() end) return ok and not n:find("^Default__") end
local team; for _, v in ipairs(FindAllOf("BPMV_PrimeTeam_C") or {}) do if live(v) then team = v end end
if not team then W("no team") return end
local tv = false; pcall(function() tv = team:IsVisible() end)
if not tv then W("closed") return end
local hit = {}
for _, p in ipairs({ { "SideBar", "BPMV_TeamSideBar2_C" }, { "Property", "BPMV_Team_Property_C" }, { "Equip", "BPMV_Team_Equip_V3_C" }, { "Backpack", "BPMV_PrimeTeamBackpack_C" } }) do
  for _, v in ipairs(FindAllOf(p[2]) or {}) do
    if live(v) then
      local ok, f = pcall(function() return v:IsVisible() and v:HasFocusedDescendants() end)
      if ok and f then hit[#hit + 1] = p[1] end
    end
  end
end
for _, bn in ipairs({ "BTN_FormatonOut", "BTN_MountPet", "BTN_QieCuo", "BTN_SongLi", "BTN_LiDui", "BTN_QingJiao" }) do
  pcall(function() local b = team[bn]; if b:IsVisible() and (b:HasFocusedDescendants() or b.JHGPCBtn_ActiveBG:IsVisible()) then hit[#hit + 1] = "Bottom:" .. bn:sub(5) end end)
end
W(#hit > 0 and table.concat(hit, "+") or "none")
