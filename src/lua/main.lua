print("[GamepadTweaks] v4.12 loaded\n")
-- Everything runs from ONE game-thread loop (LoopInGameThreadWithDelay). Earlier versions queued a new
-- ExecuteInGameThread callback from several LoopAsync timers; UE4SS 4.0 occasionally frees such a queued
-- callback early ("Ref was not function") and the game crashes. A single registered loop avoids that.

local DIR = [[D:\TOOLS\AWSdata\WanderingSword\]]
local DLLPATH = [[D:\GAME\Wandering Sword\Wandering_Sword\Binaries\Win64\xinput1_3.dll]]
local function now() return os.clock() end
local function writeFile(n, s) local f = io.open(DIR .. n, "w"); if f then f:write(s); f:close() end end
local function readFirst(n) local f = io.open(DIR .. n, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end

local function live(o)
  if not o or not o:IsValid() then return false end
  local ok, n = pcall(function() return o:GetFName():ToString() end)
  return ok and type(n) == "string" and not n:find("^Default__")
end
local function getUI()
  for _, s in ipairs(FindAllOf("JHNeoUISubsystem") or {}) do if live(s) then return s end end
  return nil
end

local pauseUntil = 0          -- world-dependent work idles until this time (map loads, teleports)
local lastLevel = nil

-- returns pc, pawn, level, pawnFullName when the world is stable; otherwise nil
local function stableWorld()
  if now() < pauseUntil then return nil end
  local pc = FindFirstOf("BP_PlayerController_C")
  if not pc or not pc:IsValid() then return nil end
  local pawn = pc.Pawn
  if not pawn or not pawn:IsValid() then return nil end
  local full = pawn:GetFullName()
  local lv = full:match("%.([%w_]+):PersistentLevel")
  if not lv then return nil end
  if lv ~= lastLevel then lastLevel = lv; pauseUntil = now() + 5; writeFile("cur.txt", lv); return nil end
  return pc, pawn, lv, full
end

local function iniNumber(key, def)
  local s = readFirst("wsmod.ini"); if not s then return def end
  s = s:gsub("%z", "")
  return tonumber(s:match("\n%s*" .. key .. "%s*=%s*(%d+)")) or def
end

-- ---------------------------------------------------------------- 1) hide the game's own cursor
local inBattle = false
local inFight = false     -- a real fight only (inBattle is also true on the overworld travel map)
local function taskCursor()
  if inBattle then return end            -- in battle the game manages its own cursor
  local pc = stableWorld(); if pc and pc.bShowMouseCursor then pc.bShowMouseCursor = false end
end

-- ---------------------------------------------------------------- 2) world map open flag
local lastMap = nil
local function taskMapFlag()
  local open = false
  if now() >= pauseUntil then
    local w = FindFirstOf("BPMV_JHNeoUIWorldMap3_C")
    if w and w:IsValid() and w:IsVisible() then open = true end
  end
  local v = open and "1" or "0"
  if v ~= lastMap then lastMap = v; writeFile("map.flag", v) end
end

-- ---------------------------------------------------------------- 3) visited levels -> safe landing points
-- A level is "visited" once the hero has stood on the ground there for 2 s. The stored point is refreshed
-- (at most every 20 s) to where the hero last stood on solid ground, so it is always a real walkable spot.
-- (v4.3 stored the very first position after a load, which can be a staging point in the air/under the map.)
local visited = {}          -- lv -> { x, y, z }
do
  local s = readFirst("visited.txt")
  local byPos = {}
  if s then for line in s:gmatch("[^\n]+") do
    local lv, x, y, z = line:match("^([^|]+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)")
    if lv then visited[lv] = { x = tonumber(x), y = tonumber(y), z = tonumber(z) }; local k = x .. "|" .. y .. "|" .. z; byPos[k] = (byPos[k] or 0) + 1 end
  end end
  -- identical coordinates in two different levels cannot both be real: drop them, they get re-recorded
  for lv, p in pairs(visited) do
    local k = string.format("%.0f|%.0f|%.0f", p.x, p.y, p.z)
    if (byPos[k] or 0) > 1 then visited[lv] = nil; print("[GamepadTweaks] visited: dropped suspicious point for " .. lv .. "\n") end
  end
end
local function saveVisited()
  local t = {} for lv, p in pairs(visited) do t[#t + 1] = string.format("%s|%.0f|%.0f|%.0f", lv, p.x, p.y, p.z) end table.sort(t)
  writeFile("visited.txt", table.concat(t, "\n") .. "\n")
end
saveVisited()
local ground = { lv = nil, since = 0, lastSave = 0 }
local function onGround(pawn)
  local m = pawn.CharacterMovement
  if not m or not m:IsValid() or m:IsFalling() then return false end
  local mode = m.MovementMode
  return mode == 1 or mode == 2      -- Walking / NavWalking
end
local function taskVisited()
  local pc, pawn, lv, full = stableWorld(); if not pawn then ground.lv = nil return end
  if not full:find("BP_SceneHero") then ground.lv = nil return end
  if not onGround(pawn) then ground.lv = nil return end
  if ground.lv ~= lv then ground.lv = lv; ground.since = now() return end
  if now() - ground.since < 2 then return end
  local l = pawn:K2_GetActorLocation()
  local p = visited[lv]
  if not p then
    visited[lv] = { x = l.X, y = l.Y, z = l.Z }; saveVisited(); ground.lastSave = now()
    print("[GamepadTweaks] visited " .. lv .. "\n")
  elseif now() - ground.lastSave > 20 and ((l.X - p.x) ^ 2 + (l.Y - p.y) ^ 2 + (l.Z - p.z) ^ 2) > 300 * 300 then
    p.x, p.y, p.z = l.X, l.Y, l.Z; saveVisited(); ground.lastSave = now()
  end
end

-- ---------------------------------------------------------------- 4) teleport request "LEVEL|x|y|z"
-- ChangeSceneMap already starts the load; calling task:StartChangeMap() as well loaded the map twice (v4.3 bug).
-- After arrival a watchdog checks the hero for 25 s; if it is falling / below the target / gone, it is moved
-- to the level's PlayerStart (the game's own spawn point).
local arrival = nil   -- { lv, z, at, fallSince, rescued }
local function changeMap(pc, lv, x, y, z)
  local cdo = StaticFindObject("/Script/JH.Default__AsyncTaskChangeSceneMap")
  return cdo:ChangeSceneMap(pc, FName(lv), { X = x, Y = y, Z = z }, 0, true, true, true, true, false)
end
local function taskTeleport()
  local line = readFirst("teleport.req"); if not line then return end
  os.remove(DIR .. "teleport.req")
  local lv, x, y, z = line:match("^([%w_]+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)")
  if not lv then return end
  local pc, pawn, cur, full = stableWorld(); if not pc then print("[GamepadTweaks] teleport skipped: world not stable\n") return end
  if not full:find("BP_SceneHero") then print("[GamepadTweaks] teleport skipped: not in scene\n") return end
  local ui = getUI()
  local blocked = inBattle
  if ui then
    pcall(function() if ui:ShouldDisableInput() then blocked = true end end)
    pcall(function() local d = ui:GetDialogView(); if d and d:IsValid() and d:IsVisible() then blocked = true end end)
  end
  if blocked then print("[GamepadTweaks] teleport skipped: battle/dialog\n") return end
  local tx, ty, tz = tonumber(x), tonumber(y), tonumber(z)   -- panel sends the station point or our refreshed safe point
  pauseUntil = now() + 12
  if ui and ui:IsValid() then pcall(function() ui:GotoDefaultStatus() end) end
  changeMap(pc, lv, tx, ty, tz + 30)
  arrival = { lv = lv, z = tz, at = now(), fallSince = nil, rescued = false }
  print(string.format("[GamepadTweaks] teleport -> %s (%.0f %.0f %.0f)\n", lv, tx, ty, tz))
end
local function playerStart()
  for _, s in ipairs(FindAllOf("PlayerStart") or {}) do
    if live(s) then local l = s:K2_GetActorLocation(); return l.X, l.Y, l.Z end
  end
  return nil
end
local function taskArrival()
  local a = arrival; if not a then return end
  local t = now() - a.at
  if t < 3 then return end
  if t > 25 or a.rescued then arrival = nil return end
  local pc = FindFirstOf("BP_PlayerController_C"); if not live(pc) then return end
  local pawn = pc.Pawn
  local bad, why = false, ""
  if not pawn or not pawn:IsValid() then
    if t > 8 then bad, why = true, "hero missing" end
  else
    local full = pawn:GetFullName()
    if not full:find("." .. a.lv .. ":", 1, true) then return end          -- still loading
    if not full:find("BP_SceneHero") then return end
    local l = pawn:K2_GetActorLocation()
    local m = pawn.CharacterMovement
    local falling = m and m:IsValid() and m:IsFalling()
    if falling then a.fallSince = a.fallSince or now() else a.fallSince = nil end
    if l.Z < a.z - 1500 then bad, why = true, string.format("below target (z %.0f)", l.Z)
    elseif a.fallSince and now() - a.fallSince > 2.5 then bad, why = true, "falling" end
  end
  if not bad then return end
  local sx, sy, sz = playerStart()
  a.rescued = true
  if not sx then print("[GamepadTweaks] arrival rescue: " .. why .. ", but no PlayerStart found\n") return end
  pauseUntil = now() + 12
  changeMap(pc, a.lv, sx, sy, sz + 30)
  visited[a.lv] = nil; saveVisited()          -- the stored point was bad; re-record on the ground
  print(string.format("[GamepadTweaks] arrival rescue: %s -> PlayerStart %.0f %.0f %.0f\n", why, sx, sy, sz))
end

-- ---------------------------------------------------------------- 5) maintenance command channel
local function taskCmd()
  local src = readFirst("cmd.lua"); if not src then return end
  os.remove(DIR .. "cmd.lua")
  local out = io.open(DIR .. "cmd_out.txt", "w")
  local function W(s) out:write(tostring(s) .. "\n") end
  local fn, err = load(src, "cmd", "t", setmetatable({ W = W }, { __index = _G }))
  if not fn then W("COMPILE ERROR " .. tostring(err)) else local ok, e = pcall(fn); if not ok then W("RUNTIME ERROR " .. tostring(e)) end end
  W("== done"); out:close()
end

-- ---------------------------------------------------------------- 6) UI targets for pointer magnetism / A-click
local nativeScan = package.loadlib(DLLPATH, "wsmod_scan")
local nativeCommit = package.loadlib(DLLPATH, "wsmod_commit")
local geomFn = StaticFindObject("/Script/UMG.Widget:GetCachedGeometry")
local uwClass = StaticFindObject("/Script/UMG.UserWidget")
local scanReady = nativeScan and nativeCommit and geomFn and geomFn:IsValid() and uwClass and uwClass:IsValid()
print("[GamepadTweaks] ui scan " .. (scanReady and "ready" or "unavailable") .. "\n")
local function shownChain(w, memo, depth)
  if depth > 40 then return false end
  local key = w:GetAddress()
  local m = memo[key]; if m ~= nil then return m end
  memo[key] = false
  local res = false
  if w:IsVisible() then
    local p = w:GetParent()
    if p and p:IsValid() then res = shownChain(p, memo, depth + 1)
    else
      local wt = w:GetOuter()
      local owner = (wt and wt:IsValid()) and wt:GetOuter() or nil
      if owner and owner:IsValid() and owner:GetAddress() ~= key and owner:IsA(uwClass) then res = shownChain(owner, memo, depth + 1)
      elseif w:IsA(uwClass) then res = w:IsInViewport() end
    end
  end
  memo[key] = res
  return res
end
local function taskScan()
  if not scanReady or now() < pauseUntil then return end
  local flag = readFirst("ptr.flag"); if not flag or flag:sub(1, 1) ~= "1" then return end
  -- phase 1: every button address -> native geometry check (drops never-drawn widgets cheaply)
  local byAddr, lines = {}, { string.format("%X", geomFn:GetAddress()) }
  for _, b in ipairs(FindAllOf("Button") or {}) do
    if b:IsValid() then local a = string.format("%X", b:GetAddress()); byAddr[a] = b; lines[#lines + 1] = a end
  end
  local f = io.open(DIR .. "scan_in.txt", "w"); if not f then return end
  f:write(table.concat(lines, "\n")); f:close()
  nativeScan()
  -- phase 2: full parent-chain visibility only for the few that have an on-screen geometry
  local mid = readFirst("scan_mid.txt") or ""
  local memo, ok = {}, {}
  for a in mid:gmatch("%x+") do
    local b = byAddr[a]
    if b and b:IsValid() then local good, shown = pcall(shownChain, b, memo, 0); if good and shown then ok[#ok + 1] = a end end
  end
  local o = io.open(DIR .. "scan_ok.txt", "w"); if not o then return end
  o:write(table.concat(ok, "\n")); o:close()
  nativeCommit()
end
-- ---------------------------------------------------------------- 7) larger interaction range
-- the hero's overlap sphere "Sphere" (BP_SceneHero, asset default radius 35)
local function taskInteract()
  local pc, pawn, lv, full = stableWorld(); if not pawn or not full:find("BP_SceneHero") then return end
  local target = iniNumber("range", 90)
  if target < 20 then target = 20 end; if target > 400 then target = 400 end
  local pa = pawn:GetAddress()
  for _, c in ipairs(FindAllOf("SphereComponent") or {}) do
    if c:IsValid() and c:GetFName():ToString() == "Sphere" then
      local o = c:GetOuter()
      if o and o:IsValid() and o:GetAddress() == pa then
        local r = c.SphereRadius
        if math.abs(r - target) > 0.5 then
          c:SetSphereRadius(target, true)
          print(string.format("[GamepadTweaks] interact radius %.0f -> %.0f (%s)\n", r, target, lv))
        end
      end
    end
  end
end

-- ---------------------------------------------------------------- 8) battle detection -> battle.flag
-- Several independent signals; any of them means "in battle". Transitions are logged with every signal
-- so a wrong detection can be diagnosed from the log.
local function widgetShown(cls)
  local list = FindAllOf(cls); if not list then return false end
  local memo = {}
  for _, w in ipairs(list) do
    if live(w) then local ok, s = pcall(shownChain, w, memo, 0); if ok and s then return true end end
  end
  return false
end
local lastBattle = nil
local function taskBattle()
  local pc, pawn, lv, full = stableWorld()
  if not pc then return end
  local sigSpell = widgetShown("BPMV_BattleSpell_C")       -- battle skill bar on screen
  local sigPawn = not full:find("BP_SceneHero")            -- controlling something other than the field hero
  local b = sigSpell or sigPawn
  inFight = sigSpell or full:find("BP_FightSpectator") ~= nil
  if b ~= lastBattle then
    lastBattle = b; inBattle = b
    writeFile("battle.flag", b and "1" or "0")
    print(string.format("[GamepadTweaks] battle=%s (spellbar=%s pawn=%s %s)\n", tostring(b), tostring(sigSpell), tostring(sigPawn), full:match("[^%.]+$") or "?"))
  end
end
-- ---------------------------------------------------------------- 9) character-screen backpack
-- * on open: switch to the configured sort type (default 4 = 类型) or press 整理
-- * hide equipment the focused character cannot use (Requirements: OnlyHero / ExcludeNPC / OnlyDesignatedNPC)
-- * light blue-violet frame on equipment whose stats beat what the focused character is wearing in that slot
-- Objects (found by probing v1.24.32):
--   VM   JHMainCharacterBackpackInTeamVM  (HandleSortTypeItemClick(data), HandleBackpackBatchChange())
--   view vm:GetPairView() = BPMV_JHBackpack_Basic_C  (GRID_ITEM tile view, VE_SortType_Popup.VE0..VE0_3, 整理 bound event)
--   team TeamModuleVM RootData: focus_npc_index + data[i].npc_id  (hero = 0)
--   NPC  NPCManager:GetNPCInfo(id,false).EquipmentSpecs (ItemInfoSpec)
--   entry BPEntry_Item_WDT_C.BindedDataObject -> ItemInfoSpec ; ItemDisplay.CMP.IMG_Focus = frame we recolour
local BTN_SORT_EVT = "BndEvt__BPMV_JHBackpack_Basic_BTN_BackpackSort_K2Node_ComponentBoundEvent_2_BtnClick__DelegateSignature"
local POPUP_KEYS = { [1] = "VE0", [2] = "VE0_1", [3] = "VE0_2", [4] = "VE0_3" }   -- st_id 1 珍贵 2 时间 3 价钱 4 类型
-- highlight colour: [backpack] highlight_rgb = sRGB hex (default 5C6CFF, blue-violet); UMG wants linear colour
local function iniString(key, def)
  local s = readFirst("wsmod.ini"); if not s then return def end
  s = s:gsub("%z", "")
  return s:match("\n%s*" .. key .. "%s*=%s*#?([%x]+)") or def
end
local function toLinear(v) v = v / 255; if v <= 0.04045 then return v / 12.92 end return ((v + 0.055) / 1.055) ^ 2.4 end
local hlHex, hlColor = nil, nil
local function highlightColor()
  local h = iniString("highlight_rgb", "5C6CFF")
  if h ~= hlHex then
    hlHex = h
    local r, g, b = tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16)
    if not (r and g and b) then r, g, b = 0x5C, 0x6C, 0xFF end
    hlColor = { R = toLinear(r), G = toLinear(g), B = toLinear(b), A = 1.0 }
  end
  return hlColor
end
local WHITE = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }

local function eachArr(arr, fn)
  if arr == nil then return end
  if type(arr) == "table" then for i, e in ipairs(arr) do if type(e) == "userdata" and e.get then e = e:get() end fn(i, e) end
  elseif arr.ForEach then arr:ForEach(function(i, e) fn(i, e:get()) end) end
end

-- equipment rows of the Items table: requirements per item id (built once)
local reqCache = nil
local kindCache = {}     -- defId -> { sub, skill }  for books (30-38), materials (40-49), treasures (50-56), quest items (60), recipes (99)
local baseCache = {}
local function buildReqCache()
  reqCache = {}
  local dt = StaticFindObject("/Game/JH/Tables/Items.Items"); if not dt or not dt:IsValid() then return end
  dt:ForEachRow(function(name, row)
    local t = row.ItemType
    if t >= 1 and t <= 13 then
      local list = {}
      row.Requirements:ForEach(function(i, e) local r = e:get(); list[#list + 1] = { t = r.Type, id = r.ID } end)
      reqCache[row.ID] = { sub = t, req = list }
      local b = {}
      row.Actions:ForEach(function(i, e) local a = e:get(); if a.Type == 4 then b[a.ID] = (b[a.ID] or 0) + a.Num end end)
      baseCache[row.ID] = b
    elseif (t >= 30 and t <= 38) or (t >= 40 and t <= 56) or t == 60 or t == 99 then
      local sk = nil
      row.Actions:ForEach(function(i, e) local a = e:get(); if a.Type == 10 and not sk then sk = a.ID end end)
      kindCache[row.ID] = { sub = t, skill = sk }
    end
  end)
end
local function canUse(defId, npc)
  local e = reqCache[defId]; if not e then return true end
  local onlyList = nil
  for _, r in ipairs(e.req) do
    if r.t == 13 and npc ~= 0 then return false end              -- OnlyHero
    if r.t == 41 and r.id == npc then return false end           -- ExcludeNPC
    if r.t == 42 then onlyList = onlyList or {}; onlyList[r.id] = true end   -- OnlyDesignatedNPC
  end
  if onlyList and not onlyList[npc] then return false end
  return true
end
local function slotOf(sub) if sub >= 1 and sub <= 6 then return "W" end if sub >= 10 and sub <= 13 then return sub end return nil end
-- final stats = base stats from the Items table + the per-item rolled bonus (what the tooltip shows,
-- e.g. 亮银甲 44.2 + 3 = 47 防御力). v4.3 only summed the rolled bonus and missed the base.
local function baseStats(defId)
  local b = baseCache[defId]; if b then return b end
  b = {}
  local dt = StaticFindObject("/Game/JH/Tables/Items.Items")
  if dt and dt:IsValid() then
    dt:ForEachRow(function(name, row)
      if row.ID == defId then row.Actions:ForEach(function(i, e) local a = e:get(); if a.Type == 4 then b[a.ID] = (b[a.ID] or 0) + a.Num end end) end
    end)
  end
  baseCache[defId] = b
  return b
end
local function statsOf(sp)
  local t = {}
  for k, v in pairs(baseStats(sp.ItemDefId)) do t[k] = v end
  for _, arr in ipairs({ sp.Actions, sp.RandActions }) do
    eachArr(arr, function(i, a) if a.Type == 4 then t[a.ID] = (t[a.ID] or 0) + a.Num end end)
  end
  return t
end
local function better(new, old, mode)
  local keys = {}
  for k in pairs(new) do keys[k] = true end; for k in pairs(old) do keys[k] = true end
  local up, down, score = false, false, 0
  for k in pairs(keys) do
    local a, b = new[k] or 0, old[k] or 0
    if a > b + 1e-4 then up = true elseif a < b - 1e-4 then down = true end
    local m = math.max(math.abs(a), math.abs(b)); if m > 1e-6 then score = score + (a - b) / m end
  end
  if mode == 1 then return score > 0.05 end    -- "sum": net relative gain
  return up and not down                        -- "strict": nothing lower, something higher
end

local function focusedNpc()
  local ov = readFirst("npc_override.txt"); if ov and tonumber(ov) then return tonumber(ov) end
  local tv = nil
  for _, v in ipairs(FindAllOf("TeamModuleVM") or {}) do if live(v) then tv = v end end
  if not tv then return 0 end
  local js = tv.RootData:DataToString():ToString()
  local idx = tonumber(js:match('"focus_npc_index":(%-?%d+)')) or 0
  for blk in js:gmatch('{[^{}]-"index":' .. idx .. '[^{}]-}') do
    local id = tonumber(blk:match('"npc_id":(%-?%d+)')); if id and id >= 0 then return id end
  end
  return 0
end
local function wornStats(npc)
  local res = {}
  local mgr = nil; for _, m in ipairs(FindAllOf("NPCManager") or {}) do if live(m) then mgr = m end end
  if not mgr then return res end
  local info = mgr:GetNPCInfo(npc, false); if not info or not info:IsValid() then return res end
  info.EquipmentSpecs:ForEach(function(i, e)
    local sp = e:get()
    if sp and sp:IsValid() then local ent = reqCache[sp.ItemDefId]; local s = ent and slotOf(ent.sub); if s then res[s] = statsOf(sp); if s == "W" then res.wsub = ent.sub end end end
  end)
  return res
end
local function gridItems(grid)
  local out = {}
  local items = grid:GetListItems()
  if type(items) == "table" then for _, sp in ipairs(items) do if type(sp) == "userdata" and sp.get and not sp.IsValid then sp = sp:get() end out[#out + 1] = sp end
  elseif items and items.ForEach then items:ForEach(function(i, e) out[#out + 1] = e:get() end) end
  return out
end

local bp = { open = false, sortDone = false, openAt = 0, npc = nil, filter = nil, lit = {} }
local function resetEntries()
  for addr, en in pairs(bp.lit) do
    pcall(function() if en:IsValid() then local f = en.ItemDisplay.CMP.IMG_Focus; f:SetColorAndOpacity(WHITE); f:SetVisibility(2) end end)
  end
  bp.lit = {}
end

-- ================================================================ hide pipeline (no flash)
-- Decisions are per (character, item id) and are computed for every team member once per opening, then
-- reused for every tab / character switch. Hiding happens in two places:
--   * hook on the grid's OnEntryInitialized (runs while the game builds a cell, before it is drawn):
--     a cell that will be removed is made fully transparent right away, so it is never seen
--   * taskHide (every scheduler tick, ~20 ms): removes those items from the list, and when we trigger the
--     rebuild ourselves (character switch) removes them before the frame is drawn at all
-- "u" = unusable by that character: hidden in every tab
-- "a" = belongs to its own category (learned manual / learned recipe / quest item / material): hidden in 全部 only
local HOOK_FN = "/Game/JH/JHNeoUI/Modules/Shared/Backpack/Comps/Grid/BP_ItemGridWDT.BP_ItemGridWDT_C:BP_OnEntryInitialized_Event_0"
local HIDE = { vm = nil, findAt = 0, open = false, view = nil, grid = nil, gridAddr = nil, vn = nil, team = nil, btns = {},
  hooked = false, hookCount = 0, lastHook = 0, sig = nil, recheckAt = nil, removed = 0, lastNpc = nil, lastFilter = nil,
  memo = {}, info = {}, wtype = {}, dim = {}, dimWt = {}, recipeDone = {}, srcN = -1, cfgHide = true, cfgTidy = true,
  cacheAt = -1, cacheNpc = 0, cacheFilter = -1 }

local function teamInfo(npc)
  local i = HIDE.info[npc]
  if i and i:IsValid() then return i end
  i = nil
  for _, m in ipairs(FindAllOf("NPCManager") or {}) do if live(m) then i = m:GetNPCInfo(npc, false) end end
  HIDE.info[npc] = i
  return i
end
local function weaponType(npc)
  local wt = HIDE.wtype[npc]
  if wt == nil then
    wt = -1
    local info = teamInfo(npc)
    if info and info:IsValid() then pcall(function() wt = info:GetWeaponType() end) end
    HIDE.wtype[npc] = wt
  end
  return wt
end
local function teamNpcs()
  local out = {}
  local tv = HIDE.team
  if tv and tv:IsValid() then
    local js = tv.RootData:DataToString():ToString()
    for blk in js:gmatch('{[^{}]-"index":%d+[^{}]-}') do
      if blk:find('"is_valid":true', 1, true) then local id = tonumber(blk:match('"npc_id":(%-?%d+)')); if id and id >= 0 then out[#out + 1] = id end end
    end
  end
  if #out == 0 then out[1] = 0 end
  return out
end
local function decide(npc, defId)
  local m = HIDE.memo[npc]; if not m then m = {}; HIDE.memo[npc] = m end
  local d = m[defId]; if d ~= nil then return d end
  d = false
  local e, k = reqCache[defId], kindCache[defId]
  if e then
    if not canUse(defId, npc) then d = "u"
    elseif npc ~= 0 and e.sub >= 1 and e.sub <= 6 then
      local wt = weaponType(npc); if wt > 0 and e.sub ~= wt then d = "u" end      -- teammates: only their weapon type
    end
  elseif k then
    if k.sub >= 30 and k.sub <= 38 then
      local info = teamInfo(npc); local has = false
      if k.skill and info and info:IsValid() then pcall(function() has = info:HasSkillById(k.skill) end) end
      if has then d = "a"                                                        -- 学成: only in 秘籍
      elseif npc ~= 0 and k.sub <= 35 then
        local wt = weaponType(npc); if wt > 0 and (k.sub - 29) ~= wt then d = "u" end   -- teammate cannot learn other weapon arts
      end
    elseif k.sub == 60 or (k.sub >= 40 and k.sub <= 49) then d = "a"            -- quest items, materials
    elseif k.sub >= 50 and k.sub <= 56 then d = "a"                             -- 珍宝: paintings, chess, tea sets, books, lyre, treasures, flowers
    elseif k.sub == 99 and HIDE.recipeDone[defId] then d = "a"                  -- learned recipe
    end
  end
  if d == false then local dm = HIDE.dim[npc]; if dm and dm[defId] then d = "u" end end   -- the game greyed it out before
  m[defId] = d
  return d
end
local function isHidden(npc, filter, defId)
  local d = decide(npc, defId)
  if d == "u" then return HIDE.cfgHide end
  if d == "a" then return HIDE.cfgTidy and filter == 0 end
  return false
end
-- current character / tab, re-read at most once per 3 ms (one read per batch of cells)
local function current()
  local t = os.clock()
  if t - HIDE.cacheAt > 0.003 then
    HIDE.cacheAt = t
    local npc = 0
    local tv = HIDE.team
    if tv and tv:IsValid() then
      local js = tv.RootData:DataToString():ToString()
      local idx = tonumber(js:match('"focus_npc_index":(%-?%d+)')) or 0
      for blk in js:gmatch('{[^{}]-"index":' .. idx .. '[^{}]-}') do local id = tonumber(blk:match('"npc_id":(%-?%d+)')); if id and id >= 0 then npc = id end end
    end
    if t - (HIDE.ovAt or -1) > 0.5 then HIDE.ovAt = t; local ov = readFirst("npc_override.txt"); HIDE.ov = ov and tonumber(ov) or nil end
    if HIDE.ov then npc = HIDE.ov end
    -- active tab = vm:GetFilterIndex() (EBackpackFilterType_Console: 0 全部 1 武器 2 防具 3 丹药 4 秘籍 5 材料 6 珍宝 7 任务).
    -- The filter buttons' bIsActive never changes in v1.24.32 (Btn_All stays active), so up to v4.8 every tab
    -- was taken for 全部 and "a" items disappeared from their own tabs too.
    local filter = -1
    local vm = HIDE.vm
    if vm and vm:IsValid() then
      local ok, fi = pcall(function() return vm:GetFilterIndex() end)
      if ok and type(fi) == "number" then filter = fi
      else local js = ""; pcall(function() js = vm.RootData:DataToString():ToString() end); filter = tonumber(js:match('"active_filter_type":(%d+)')) or -1 end
    end
    HIDE.cacheNpc, HIDE.cacheFilter = npc, filter
  end
  return HIDE.cacheNpc, HIDE.cacheFilter
end
local function onEntryInit(self, item, widget)
  if not HIDE.open or not HIDE.gridAddr then return end
  local g = self:get(); if not g or not g:IsValid() or g:GetAddress() ~= HIDE.gridAddr then return end
  local sp, w = item:get(), widget:get()
  if not sp or not sp:IsValid() or not w or not w:IsValid() then return end
  HIDE.hookCount = HIDE.hookCount + 1
  local hid = false
  if not sp.bOnlyForLayout then local npc, filter = current(); hid = isHidden(npc, filter, sp.ItemDefId) end
  w:SetRenderOpacity(hid and 0 or 1)
end
local function onOpen(vm)
  local view = vm:GetPairView(); if not view or not view:IsValid() then return false end
  HIDE.view, HIDE.grid, HIDE.vn = view, view.GRID_ITEM, view:GetFName():ToString()
  HIDE.gridAddr = HIDE.grid:GetAddress()
  HIDE.team = nil; for _, v in ipairs(FindAllOf("TeamModuleVM") or {}) do if live(v) then HIDE.team = v end end
  HIDE.btns = {}
  for _, b in ipairs(FindAllOf("BP_BackpackFilterBtn_C") or {}) do
    if live(b) and b:GetFullName():find(HIDE.vn, 1, true) then local n = b:GetFName():ToString(); HIDE.btns[#HIDE.btns + 1] = { obj = b, name = n, all = (n == "Btn_All") } end
  end
  if not reqCache then buildReqCache() end
  HIDE.cfgHide = iniNumber("hide_unusable", 1) == 1
  HIDE.cfgTidy = iniNumber("tidy_all_tab", 1) == 1
  HIDE.memo, HIDE.info, HIDE.wtype = {}, {}, {}
  HIDE.sig, HIDE.removed, HIDE.lastNpc, HIDE.lastFilter, HIDE.cacheAt = nil, 0, nil, nil, -1
  HIDE.srcN = vm.CurrentDataSrc:GetArrayNum()
  -- one pass for every team member: all later switches reuse these decisions
  local t0 = os.clock()
  local ids = {}
  vm.CurrentDataSrc:ForEach(function(i, e) ids[e:get().ItemDefId] = true end)
  local npcs = teamNpcs()
  for _, npc in ipairs(npcs) do
    local wt = weaponType(npc)
    if HIDE.dimWt[npc] ~= nil and HIDE.dimWt[npc] ~= wt then HIDE.dim[npc] = nil end   -- weapon changed: forget greyed list
    HIDE.dimWt[npc] = wt
    for id in pairs(ids) do decide(npc, id) end
  end
  if not HIDE.hooked and iniNumber("cell_hook", 1) == 1 then
    HIDE.hooked = true
    local ok, err = pcall(function() RegisterHook(HOOK_FN, function(self, item, widget) pcall(onEntryInit, self, item, widget) end) end)
    print("[GamepadTweaks] backpack: cell hook " .. (ok and "registered" or ("failed: " .. tostring(err))) .. "\n")
  end
  print(string.format("[GamepadTweaks] backpack: preloaded %d characters x %d items in %.1f ms\n", #npcs, (function() local n = 0 for _ in pairs(ids) do n = n + 1 end return n end)(), (os.clock() - t0) * 1000))
  return true
end
local function taskHide()
  if inFight then HIDE.open = false return end
  local vm = HIDE.vm
  if not (vm and vm:IsValid()) then
    if now() < HIDE.findAt then return end
    HIDE.findAt = now() + 1
    vm = nil; for _, v in ipairs(FindAllOf("JHMainCharacterBackpackInTeamVM") or {}) do if live(v) then vm = v end end
    HIDE.vm = vm; if not vm then return end
  end
  if not vm:GetModuleVisibility() then HIDE.open = false return end
  if not HIDE.open then
    if now() < pauseUntil then return end
    if not onOpen(vm) then return end
    HIDE.open = true
  end
  local grid = HIDE.grid; if not grid or not grid:IsValid() then HIDE.open = false return end
  -- inventory changed (item used, equipped, learned): decisions may change
  local srcN = vm.CurrentDataSrc:GetArrayNum()
  if srcN ~= HIDE.srcN then HIDE.srcN = srcN; HIDE.memo = {}; HIDE.wtype = {} end
  local npc, filter = current()
  local sig = grid:GetNumItems() .. "|" .. npc .. "|" .. tostring(filter) .. "|" .. HIDE.hookCount
  local recheck = HIDE.recheckAt and now() >= HIDE.recheckAt
  if sig == HIDE.sig and not recheck then return end
  if recheck then HIDE.recheckAt = nil end
  -- character switched while we had items removed: bring them back now and filter in this same tick
  if HIDE.lastNpc ~= nil and npc ~= HIDE.lastNpc and HIDE.removed > 0 then vm:HandleBackpackBatchChange(); HIDE.removed = 0 end
  if HIDE.lastFilter ~= nil and filter ~= HIDE.lastFilter then HIDE.removed = 0 end      -- the game rebuilt the list itself
  HIDE.lastNpc, HIDE.lastFilter = npc, filter
  local gone, n = {}, 0
  for _, sp in ipairs(gridItems(grid)) do
    if sp:IsValid() and not sp.bOnlyForLayout and isHidden(npc, filter, sp.ItemDefId) then
      grid:RemoveItem(sp); gone[sp:GetAddress()] = true; n = n + 1
    end
  end
  -- learn from what the game itself shows (greyed out / recipe learned) and repair recycled cells
  local learnt = 0
  for _, en in ipairs(FindAllOf("BPEntry_Item_WDT_C") or {}) do
    if live(en) and en:GetFullName():find(HIDE.vn, 1, true) then
      local ok, sp = pcall(function() return en:GetBindedDataObj() end)
      if ok and sp and sp:IsValid() and not sp.bOnlyForLayout then
        local addr = sp:GetAddress()
        local js = ""; pcall(function() js = en.ItemDisplay:GetData():DataToString():ToString() end)
        local sid = tonumber(js:match('"setting_id":(%d+)'))
        if sid == sp.ItemDefId and not gone[addr] then
          local newly = false
          if js:find('"not_learnable":true', 1, true) and decide(npc, sid) == false then
            HIDE.dim[npc] = HIDE.dim[npc] or {}; HIDE.dim[npc][sid] = true; HIDE.memo[npc][sid] = "u"; newly = true
          elseif js:find('"is_recipe":true', 1, true) and js:find('"is_acquired":true', 1, true) and not HIDE.recipeDone[sid] then
            HIDE.recipeDone[sid] = true; for _, mm in pairs(HIDE.memo) do mm[sid] = nil end; newly = true
          end
          if newly and isHidden(npc, filter, sid) then grid:RemoveItem(sp); gone[addr] = true; learnt = learnt + 1 end
        end
        local want = gone[addr] and 0 or 1
        local ok2, op = pcall(function() return en:GetRenderOpacity() end)
        if ok2 and math.abs(op - want) > 0.01 then en:SetRenderOpacity(want) end
      end
    end
  end
  HIDE.removed = HIDE.removed + n + learnt
  if n + learnt > 0 then print(string.format("[GamepadTweaks] backpack: npc %d tab %s hid %d (+%d learnt)\n", npc, tostring(filter), n, learnt)) end
  HIDE.sig = grid:GetNumItems() .. "|" .. npc .. "|" .. tostring(filter) .. "|" .. HIDE.hookCount
  if HIDE.hookCount ~= HIDE.lastHook then HIDE.recheckAt = now() + 0.15 end   -- cell display data can arrive a little later
  HIDE.lastHook = HIDE.hookCount
end

-- ================================================================ sort on open + highlight (slow, 200 ms)
local function taskBackpack()
  if inFight or not stableWorld() then if bp.open then resetEntries(); bp.open = false end return end
  local vm = HIDE.vm
  if not (vm and vm:IsValid()) then vm = nil; for _, v in ipairs(FindAllOf("JHMainCharacterBackpackInTeamVM") or {}) do if live(v) then vm = v end end end
  local shown = vm and vm:GetModuleVisibility()
  if not shown then if bp.open then resetEntries(); bp.open = false end return end
  local view = vm:GetPairView(); if not view or not view:IsValid() then return end
  if not reqCache then buildReqCache() end
  local cfgSort = iniNumber("default_sort", 4)
  local mark = iniNumber("highlight_better", 1) == 1
  local mode = iniNumber("better_mode", 0)

  if not bp.open then bp.open = true; bp.sortDone = false; bp.openAt = now(); bp.npc = nil; bp.filter = nil end
  -- 1) sort once per opening (after the panel has had a moment to build); taskHide runs right after in the
  --    same tick, so the rebuilt list is filtered before it is drawn
  if not bp.sortDone and now() - bp.openAt > 0.3 then
    bp.sortDone = true
    if iniNumber("auto_sort", 1) == 1 then
      local js = vm.RootData:DataToString():ToString()
      local active = tonumber((js:match('"sort_types":(%b{})') or ""):match('"is_active":true,"st_id":(%d)'))
      local key = POPUP_KEYS[cfgSort]
      if key and active ~= cfgSort then
        local item = view.VE_SortType_Popup[key]
        vm:HandleSortTypeItemClick(item:GetData())
        print("[GamepadTweaks] backpack: sort type " .. tostring(active) .. " -> " .. cfgSort .. "\n")
      else
        view[BTN_SORT_EVT](view)
        print("[GamepadTweaks] backpack: 整理 (sort type " .. tostring(active) .. ")\n")
      end
      HIDE.sig = nil
    end
  end
  -- 2) highlight better equipment on the visible entries
  local npc = focusedNpc()
  if bp.npc ~= nil and npc ~= bp.npc then resetEntries() end
  bp.npc = npc
  if not mark then if next(bp.lit) then resetEntries() end return end
  local worn = wornStats(npc)
  local viewName = view:GetFName():ToString()
  for _, en in ipairs(FindAllOf("BPEntry_Item_WDT_C") or {}) do
    if live(en) and en:GetFullName():find(viewName, 1, true) then
      local key = en:GetAddress()
      local good = false
      local ok, sp = pcall(function() local d = en.BindedDataObject; if d and d.Get then d = d:Get() end; return d end)
      if ok and sp and sp:IsValid() and not sp.bOnlyForLayout then
        local ent = reqCache[sp.ItemDefId]
        local slot = ent and slotOf(ent.sub)
        -- weapons: only compare against the same weapon type the character is holding
        if slot and canUse(sp.ItemDefId, npc) and not (slot == "W" and worn.wsub and worn.wsub ~= ent.sub and iniNumber("same_weapon_type", 1) == 1) then
          good = better(statsOf(sp), worn[slot] or {}, mode)
        end
      end
      local f = en.ItemDisplay.CMP.IMG_Focus
      if good then
        f:SetColorAndOpacity(highlightColor()); if f:GetVisibility() ~= 3 then f:SetVisibility(3) end
        bp.lit[key] = en
      elseif bp.lit[key] or f.ColorAndOpacity.G < 0.99 then
        f:SetColorAndOpacity(WHITE)
        local focused = false
        pcall(function() focused = en.BTN_JHItem.BtnMain:IsHovered() or en.JHGPCBtn_ActiveBG:IsVisible() end)
        if not focused then f:SetVisibility(2) end
        bp.lit[key] = nil
      end
    end
  end
end

-- ---------------------------------------------------------------- 10) character screen: skip 属性 / 装备 for the gamepad
-- Wanted: LT/RT cycle 头像(SideBar) -> 背包(Backpack) -> 底部按钮(Bottom: 上阵/坐骑/切磋/送礼...) -> 头像, and the
-- d-pad never parks on 属性(Property) / 装备(Equip).
-- The game itself (v1.24.32, measured 2026-11-23 with injected input):
--   RT: SideBar -> Property -> Equip -> Backpack, stops there;  LT: Backpack -> Equip -> Property, stops there
--   d-pad: Property LEFT -> SideBar, SideBar RIGHT -> Property, Property DOWN x5 -> bottom row, bottom UP / RT -> Property
-- What we do every tick while the screen is shown (gamepad mode only, so mouse hovering is never fought):
--   * LT / RT (NeoUIGlobalInputManager.KeyDownStatus: key 11 = LT, 12 = RT): on press pick the next / previous
--     region of our cycle, on release move there (the game moves on release too) and hold it for 0.3 s
--   * focus lands on Property / Equip without LT/RT (d-pad): bounce to the region on the far side
-- Moving focus: SideBar / Backpack = vm:ChangeNaviFocus(FName(key), 0, "") then :SetFocus() on the widget it
-- returns (Backpack needs the SetFocus); Bottom = :SetFocus() on the first visible bottom button.
-- Not gated by inBattle: battle.flag is also 1 on the overworld travel map, and the screen cannot open in a fight.
-- v4.12, no flash for any input:
--   * every tick Lua tells the xinput1_3 proxy (wsmod_nav_* exports) which inputs would lead into 属性/装备 from
--     where the focus is: LT/RT everywhere, RIGHT on the side bar, UP on the bottom row (measured: these are
--     the game's own widget navigation, not ChangeNaviFocus). The proxy hides those presses (d-pad and left
--     stick) from the game and reports them in trig.req ("L" "R" "<" ">" "^" "v"); Lua jumps instead.
--   * the backpack's left edge (and any other module-level move) goes through the VM's ChangeNaviFocus("Equip" /
--     "Property"): a pre-hook rewrites the module key, so the game itself focuses our target directly.
--   * fallback (older proxy / anything unforeseen): LT/RT via KeyDownStatus and bouncing off 属性/装备.
local NAV = { team = nil, vm = nil, im = nil, findAt = 0, views = nil, open = false, cur = nil, stable = nil,
  beforeBottom = "SideBar", lt = false, rt = false, want = nil, wantUntil = 0, pending = nil, pendingWhy = nil, tries = 0, lastTry = 0, cfg = true, flag = nil, mask = 0, self = false, hooked = false, rewrites = 0,
  force = false, cells = nil, sideCell = nil, bpIdx = 0, memAt = 0 }
local NAV_VIEWS = { { "SideBar", "BPMV_TeamSideBar2_C" }, { "Property", "BPMV_Team_Property_C" }, { "Equip", "BPMV_Team_Equip_V3_C" }, { "Backpack", "BPMV_PrimeTeamBackpack_C" } }
local NAV_BTNS = { "BTN_FormatonOut", "BTN_QieCuo", "BTN_SongLi", "BTN_LiDui", "BTN_QingJiao", "BTN_MountPet" }   -- left to right
local NAV_ORDER = { "SideBar", "Backpack", "Bottom" }
local NAV_IDX = { SideBar = 1, Backpack = 2, Bottom = 3 }
local function navRegion()
  for _, e in ipairs(NAV.views) do
    local v = e[2]
    if v:IsValid() and v:IsVisible() and v:HasFocusedDescendants() then return e[1] end
  end
  local t = NAV.team
  for _, bn in ipairs(NAV_BTNS) do
    local b = t[bn]
    if b and b:IsValid() and b:IsVisible() then
      local bg = b.JHGPCBtn_ActiveBG
      if b:HasFocusedDescendants() or (bg and bg:IsValid() and bg:IsVisible()) then return "Bottom" end
    end
  end
  return nil
end
local function navHasBottom()
  for _, bn in ipairs(NAV_BTNS) do local b = NAV.team[bn]; if b and b:IsValid() and b:IsVisible() then return true end end
  return false
end
local function navFocus(target)
  NAV.self = true
  local ok, e = pcall(function()
  if target == "Bottom" then
    for _, bn in ipairs(NAV_BTNS) do local b = NAV.team[bn]; if b and b:IsValid() and b:IsVisible() then b:SetFocus(); return end end
    return
  end
  local w = NAV.vm:ChangeNaviFocus(FName(target), 0, "")
  if w and w:IsValid() then w:SetFocus() end
  -- come back to where we were inside the region (same frame, so the default cell is never drawn focused)
  if target == "SideBar" then
    local c = NAV.sideCell
    if c and c:IsValid() and c:IsVisible() then c:SetFocus() end
  elseif target == "Backpack" then
    local g = HIDE.grid
    if g and g:IsValid() then
      local n = g:GetNumItems()
      if n > 0 then g:NavigateToIndex(math.min(NAV.bpIdx or 0, n - 1)) end
    end
  end
  end)
  NAV.self = false
  if not ok then error(e) end
end
-- where a move into 属性/装备 should go instead, seen from the region we are in
local function navInstead()
  local base = NAV.want or NAV.stable or "SideBar"
  if base == "SideBar" then return "Backpack" end
  if base == "Backpack" then return "SideBar" end
  return NAV.beforeBottom or "SideBar"
end
local function navHook()
  if NAV.hooked then return end
  NAV.hooked = true
  local ok, e = pcall(function()
    RegisterHook("/Script/NeoUI.NeoUIUniversalModuleVMBase:ChangeNaviFocus", function(self, id, scen, str)
      if NAV.self or not NAV.open or not NAV.cfg then return end
      local key = id:get():ToString()
      if key ~= "Property" and key ~= "Equip" then return end
      local t = navInstead()
      if t == "Bottom" then t = "SideBar" end
      id:set(FName(t))
      NAV.rewrites = NAV.rewrites + 1
      -- the game lands on the region's default element; next tick navFocus puts it on the remembered one
      -- (Backpack also needs that SetFocus to take the focus at all)
      NAV.want, NAV.wantUntil, NAV.tries, NAV.lastTry, NAV.force = t, now() + (t == "SideBar" and 0.6 or 0.3), 0, 0, true
      print(string.format("[GamepadTweaks] nav: game asked for %s, sent to %s\n", key, t))
    end)
  end)
  print("[GamepadTweaks] nav: ChangeNaviFocus hook " .. (ok and "registered" or ("failed: " .. tostring(e))) .. "\n")
end
-- "arrived": for the side bar also on the remembered cell (the game re-focuses its default cell a moment
-- after the module gets the focus, so we keep putting it back while the move is held)
local function navAt(target, cur)
  if cur ~= target then return false end
  if target == "SideBar" then
    local c = NAV.sideCell
    if c and c:IsValid() and c:IsVisible() then return c:HasFocusedDescendants() end
  end
  return true
end
local function navGo(target, why)
  NAV.want, NAV.wantUntil, NAV.tries, NAV.lastTry, NAV.force = target, now() + (target == "SideBar" and 0.6 or 0.3), 0, 0, true
  print(string.format("[GamepadTweaks] nav %s -> %s (%s)\n", tostring(NAV.stable), target, why))
end
local function navTriggers()
  local lt, rt = false, false
  NAV.im.KeyDownStatus:ForEach(function(k, v) local key = k:get(); if key == 11 then lt = v:get() elseif key == 12 then rt = v:get() end end)
  return lt, rt
end
local NAVX = nil      -- wsmod_nav_* exports of the proxy (nil = older proxy)
do
  local fns = {}
  for _, n in ipairs({ "begin", "up", "down", "left", "right", "trig", "commit" }) do fns[n] = package.loadlib(DLLPATH, "wsmod_nav_" .. n) end
  if fns.begin and fns.commit then NAVX = fns end
  print("[GamepadTweaks] nav: proxy input filter " .. (NAVX and "available" or "missing (old xinput1_3.dll, LT/RT only)") .. "\n")
end
local NAV_BITS = { up = 1, down = 2, left = 4, right = 8, trig = 16 }
local function navMask(m)
  if NAVX then
    if m ~= 0 or NAV.mask ~= 0 then
      NAVX.begin()
      for n, b in pairs(NAV_BITS) do if m & b ~= 0 then NAVX[n]() end end
      NAVX.commit()                       -- refreshed every tick while non-zero; the proxy drops it after 300 ms
    end
  else
    local on = m ~= 0
    if on ~= NAV.flag then NAV.flag = on; writeFile("prime.flag", on and "1" or "0") end
  end
  NAV.mask = m
end
local function navFlag(on) if not on then navMask(0) end end
-- "L"/"R" events from the proxy (renamed first so an append racing with the read is never lost)
local function navPadEvents()
  if not os.rename(DIR .. "trig.req", DIR .. "trig.take") then return nil end
  local s = readFirst("trig.take") or ""; os.remove(DIR .. "trig.take")
  return s
end
local function navStep(base, d)
  local i = NAV_IDX[base] or 1
  local target = NAV_ORDER[(i - 1 + d) % 3 + 1]
  if target == "Bottom" and not navHasBottom() then target = NAV_ORDER[(i - 1 + 2 * d) % 3 + 1] end
  return target
end
local function taskNav()
  local t = NAV.team
  if not (t and t:IsValid()) then
    navFlag(false)
    if now() < NAV.findAt then return end
    NAV.findAt = now() + 1
    t = nil; for _, v in ipairs(FindAllOf("BPMV_PrimeTeam_C") or {}) do if live(v) then t = v end end
    NAV.team, NAV.open = t, false
    if not t then return end
  end
  if not t:IsVisible() then NAV.open = false; navFlag(false); navPadEvents() return end
  if not NAV.open then
    NAV.open, NAV.cur, NAV.stable, NAV.want, NAV.pending, NAV.beforeBottom = true, nil, nil, nil, nil, "SideBar"
    NAV.cells, NAV.sideCell, NAV.bpIdx, NAV.force = nil, nil, 0, false
    NAV.cfg = iniNumber("prime_skip_panels", 1) == 1
    if NAV.cfg then navHook() end
    NAV.vm = t:GetNeoUIVM()
    NAV.im = nil; for _, s in ipairs(FindAllOf("NeoUISubsystem") or {}) do if live(s) then NAV.im = s.InputManager end end
    NAV.views = {}
    for _, p in ipairs(NAV_VIEWS) do
      for _, v in ipairs(FindAllOf(p[2]) or {}) do if live(v) then NAV.views[#NAV.views + 1] = { p[1], v } end end
    end
    NAV.lt, NAV.rt = false, false
    pcall(function() NAV.lt, NAV.rt = navTriggers() end)
  end
  if not NAV.cfg or not (NAV.vm and NAV.vm:IsValid() and NAV.im and NAV.im:IsValid()) then navFlag(false) return end
  local cur = navRegion()
  local ev = navPadEvents()
  if ev and (NAV.mask ~= 0 or NAV.flag) then
    for ch in ev:gmatch("[LR<>%^v]") do
      local base = NAV.want or NAV.stable or (NAV_IDX[cur] and cur) or "SideBar"
      NAV.pending = nil
      if ch == "L" or ch == "R" then navGo(navStep(base, ch == "R" and 1 or -1), ch .. "T pad")
      elseif ch == ">" and base == "SideBar" then navGo("Backpack", "right pad")
      elseif ch == "^" and base == "Bottom" then navGo(NAV.beforeBottom or "SideBar", "up pad")
      elseif ch == "<" and base == "Backpack" then navGo("SideBar", "left pad") end
    end
  end
  local lt, rt = navTriggers()
  local pressed = 0
  if rt and not NAV.rt then pressed = 1 elseif lt and not NAV.lt then pressed = -1 end
  NAV.lt, NAV.rt = lt, rt
  local pad = true; pcall(function() pad = NAV.im:IsGamepadMode() end)
  -- the game moves the focus when LT/RT is RELEASED (measured: ~1 press length after the press), so the
  -- target is chosen on press and applied on release; navGo then holds it for 0.3 s against late moves
  if pressed ~= 0 and cur and pad then
    local base = NAV.stable or (NAV_IDX[cur] and cur) or "SideBar"
    NAV.pending, NAV.pendingWhy, NAV.want = navStep(base, pressed), pressed > 0 and "RT" or "LT", nil
  end
  if NAV.pending and not (lt or rt) then navGo(NAV.pending, NAV.pendingWhy); NAV.pending = nil end
  if not NAV.pending and not NAV.want and not (lt or rt) and pad and (cur == "Property" or cur == "Equip") then
    local base = NAV.stable or "SideBar"
    navGo((base == "SideBar") and "Backpack" or (base == "Backpack") and "SideBar" or NAV.beforeBottom, "d-pad into " .. cur)
  end
  if NAV.want then
    if now() > NAV.wantUntil then
      if cur ~= NAV.want then print(string.format("[GamepadTweaks] nav: gave up on %s (at %s)\n", NAV.want, tostring(cur))) end
      NAV.want = nil
    elseif (NAV.force or not navAt(NAV.want, cur)) and NAV.tries < 12 and now() - NAV.lastTry >= 0.035 then
      if not NAV.force and cur == NAV.want then print(string.format("[GamepadTweaks] nav: %s re-applied (try %d)\n", NAV.want, NAV.tries + 1)) end
      NAV.tries, NAV.lastTry, NAV.force = NAV.tries + 1, now(), false
      pcall(navFocus, NAV.want)
      cur = navRegion()
    end
  end
  if cur and NAV_IDX[cur] and not NAV.want and not NAV.pending then
    if cur == "Bottom" and NAV.stable and NAV.stable ~= "Bottom" then NAV.beforeBottom = NAV.stable end
    NAV.stable = cur
    if (cur == "SideBar" or cur == "Backpack") and now() - NAV.memAt > 0.06 then
      NAV.memAt = now()
      pcall(function()
        if cur == "SideBar" then
          if not NAV.cells then
            NAV.cells = {}
            for _, c in ipairs(FindAllOf("BPVE_SideBarCell2_C") or {}) do if live(c) then NAV.cells[#NAV.cells + 1] = c end end
          end
          local c = NAV.sideCell
          if not (c and c:IsValid() and c:IsVisible() and c:HasFocusedDescendants()) then
            for _, x in ipairs(NAV.cells) do if x:IsValid() and x:IsVisible() and x:HasFocusedDescendants() then NAV.sideCell = x; break end end
          end
        else
          local g = HIDE.grid
          if g and g:IsValid() and HIDE.vn then
            for _, en in ipairs(FindAllOf("BPEntry_Item_WDT_C") or {}) do
              if en:IsValid() and en:IsVisible() and en:HasFocusedDescendants() and en:GetFullName():find(HIDE.vn, 1, true) then
                local i = g:GetIndexForItem(en:GetBindedDataObj()); if i and i >= 0 then NAV.bpIdx = i end
                break
              end
            end
          end
        end
      end)
    end
  end
  local r = NAV.want or cur
  local m = 0
  if r == "SideBar" or r == "Backpack" or r == "Bottom" or r == "Property" or r == "Equip" then m = NAV_BITS.trig end
  if r == "SideBar" then m = m | NAV_BITS.right elseif r == "Bottom" then m = m | NAV_BITS.up end
  if not pad then m = 0 end
  navMask(m)
  NAV.cur = cur
end

-- ---------------------------------------------------------------- scheduler (100 ms tick)
-- base tick 20 ms (one game-thread loop for everything; "every" is in ticks)
local tasks = {
  { every = 25,  fn = taskCursor },
  { every = 15,  fn = taskMapFlag },
  { every = 100, fn = taskVisited },
  { every = 15,  fn = taskTeleport },
  { every = 15,  fn = taskArrival },
  { every = 50,  fn = taskCmd },
  { every = 10,  fn = taskScan },
  { every = 150, fn = taskInteract },
  { every = 15,  fn = taskBattle },
  { every = 10,  fn = taskBackpack },
  { every = 1,   fn = taskHide },
  { every = 1,   fn = taskNav },
}
local tick = 0
local errCount = {}
writeFile("map.flag", "0")
writeFile("battle.flag", "0")
writeFile("prime.flag", "0"); os.remove(DIR .. "trig.req")
LoopInGameThreadWithDelay(20, function()
  tick = tick + 1
  for i, t in ipairs(tasks) do
    if tick % t.every == 0 then
      local ok, err = pcall(t.fn)
      if not ok then
        errCount[i] = (errCount[i] or 0) + 1
        if errCount[i] <= 3 then print("[GamepadTweaks] task " .. i .. " error: " .. tostring(err) .. "\n") end
      end
    end
  end
end)
