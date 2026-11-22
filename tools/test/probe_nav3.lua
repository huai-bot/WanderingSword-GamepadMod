-- read-only: focused region + exact element (sidebar cell / backpack index / bottom button)
local function live(o) if not o or not o:IsValid() then return false end local ok, n = pcall(function() return o:GetFName():ToString() end) return ok and not n:find("^Default__") end
local team; for _, v in ipairs(FindAllOf("BPMV_PrimeTeam_C") or {}) do if live(v) then team = v end end
if not team then W("no team") return end
if not team:IsVisible() then W("closed") return end
local function fd(w) local ok, r = pcall(function() return w:HasFocusedDescendants() end); return ok and r end
for _, p in ipairs({ { "SideBar", "BPMV_TeamSideBar2_C" }, { "Property", "BPMV_Team_Property_C" }, { "Equip", "BPMV_Team_Equip_V3_C" }, { "Backpack", "BPMV_PrimeTeamBackpack_C" } }) do
  for _, v in ipairs(FindAllOf(p[2]) or {}) do
    if live(v) and v:IsVisible() and fd(v) then
      local vn = v:GetFName():ToString()
      local detail = ""
      if p[1] == "Backpack" then
        local bv; for _, x in ipairs(FindAllOf("BPMV_JHBackpack_Basic_C") or {}) do if live(x) and x:IsVisible() then bv = x end end
        local grid = bv and bv.GRID_ITEM
        for _, en in ipairs(FindAllOf("BPEntry_Item_WDT_C") or {}) do
          if live(en) and en:IsVisible() and fd(en) then
            local sp; pcall(function() sp = en:GetBindedDataObj() end)
            local idx = "?"; pcall(function() idx = tostring(grid:GetIndexForItem(sp)) end)
            detail = " idx=" .. idx .. "/" .. tostring(grid and grid:GetNumItems())
          end
        end
        if detail == "" then
          -- something else in the backpack panel holds focus: name the deepest focused widget we can find
          for _, cls in ipairs({ "JHGPCBtn_C", "Button", "NeoUIButtonBase" }) do
            for _, b in ipairs(FindAllOf(cls) or {}) do
              if live(b) and b:GetFullName():find(vn, 1, true) and (b:HasKeyboardFocus() or fd(b)) then detail = detail .. " w=" .. b:GetFullName():match("[^%.]+%.[^%.]+$") end
            end
          end
        end
      elseif p[1] == "SideBar" then
        local i, list = 0, {}
        for _, c in ipairs(FindAllOf("BPVE_SideBarCell2_C") or {}) do
          if live(c) and c:IsVisible() then i = i + 1; if fd(c) then detail = " cell=" .. (c:GetFName():ToString():gsub("BPVE_SideBarCell2_C_", "")) end end
        end
        detail = detail .. " (visible cells " .. i .. ")"
      end
      W(p[1] .. detail)
      return
    end
  end
end
for _, bn in ipairs({ "BTN_FormatonOut", "BTN_QieCuo", "BTN_SongLi", "BTN_LiDui", "BTN_QingJiao", "BTN_MountPet" }) do
  local b = team[bn]
  if b and b:IsValid() and b:IsVisible() and (fd(b) or b.JHGPCBtn_ActiveBG:IsVisible()) then W("Bottom:" .. bn:sub(5)) return end
end
W("none")
