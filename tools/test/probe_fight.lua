-- read-only: is a real fight running? (pawn class + battle skill bar), and where is the hero
local pc = FindFirstOf("BP_PlayerController_C")
local pawn = "none"
pcall(function() if pc and pc:IsValid() and pc.Pawn and pc.Pawn:IsValid() then pawn = pc.Pawn:GetClass():GetFName():ToString() end end)
local bar = false
for _, w in ipairs(FindAllOf("BPMV_BattleSpell_C") or {}) do
  pcall(function() if w:IsValid() and not w:GetFName():ToString():find("^Default__") and w:IsVisible() and w:IsInViewport() then bar = true end end)
end
local fight = pawn:find("FightSpectator") ~= nil or bar
W((fight and "FIGHT" or "calm") .. " pawn=" .. pawn .. " spellbar=" .. tostring(bar))
