-- read-only: focused region on the 观察 screen: Property / Equip / Backpack idx / Bottom:<btn> / none / closed
local function live(o) if not o or not o:IsValid() then return false end local ok, n = pcall(function() return o:GetFName():ToString() end) return ok and not n:find("^Default__") end
local function fd(w) local ok, r = pcall(function() return w:IsVisible() and w:HasFocusedDescendants() end); return ok and r end
local view; for _, v in ipairs(FindAllOf("BPMV_Observe_C") or {}) do if live(v) then local ok, vis = pcall(function() return v:IsVisible() end); if ok and vis then view = v end end end
if not view then W("closed") return end
for _, v in ipairs(FindAllOf("BPMV_Observe_Property_C") or {}) do if live(v) and fd(v) then W("Property") return end end
for _, v in ipairs(FindAllOf("BPMV_Team_Equip_V3_C") or {}) do if live(v) and fd(v) then W("Equip") return end end
for _, v in ipairs(FindAllOf("BPMV_JHBackpack_Basic_C") or {}) do
  if live(v) and fd(v) then
    local vn = v:GetFName():ToString(); local g = v.GRID_ITEM; local det = ""
    for _, en in ipairs(FindAllOf("BPEntry_Item_WDT_C") or {}) do
      if live(en) and fd(en) and en:GetFullName():find(vn, 1, true) then local i = "?"; pcall(function() i = tostring(g:GetIndexForItem(en:GetBindedDataObj())) end); det = " idx=" .. i .. "/" .. tostring(g:GetNumItems()) end
    end
    W("Backpack" .. det) return
  end
end
for _, bn in ipairs({ "BTN_QieCuo", "BTN_SongLi", "BTN_QingJiao", "BTN_JiSha", "BTN_LiDui" }) do
  local b = view[bn]
  if b and b:IsValid() and b:IsVisible() then
    local on = fd(b); pcall(function() on = on or b.JHGPCBtn_ActiveBG:IsVisible() end)
    if on then W("Bottom:" .. bn:sub(5)) return end
  end
end
W("none")
