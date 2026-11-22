print("[GamepadTweaks] v4.5 loaded\n")
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

local bp = { open = false, sortDone = false, openAt = 0, npc = nil, removed = 0, lit = {}, statCache = {} }
local function resetEntries(viewName)
  for addr, en in pairs(bp.lit) do
    pcall(function() if en:IsValid() then local f = en.ItemDisplay.CMP.IMG_Focus; f:SetColorAndOpacity(WHITE); f:SetVisibility(2) end end)
  end
  bp.lit = {}
end
local function taskBackpack()
  if inBattle or not stableWorld() then if bp.open then resetEntries(); bp.open = false end return end
  local vm = nil
  for _, v in ipairs(FindAllOf("JHMainCharacterBackpackInTeamVM") or {}) do if live(v) then vm = v end end
  local shown = vm and vm:GetModuleVisibility()
  if not shown then if bp.open then resetEntries(); bp.open = false end return end
  local view = vm:GetPairView(); if not view or not view:IsValid() then return end
  if not reqCache then buildReqCache() end
  local cfgSort = iniNumber("default_sort", 4)
  local hide = iniNumber("hide_unusable", 1) == 1
  local mark = iniNumber("highlight_better", 1) == 1
  local mode = iniNumber("better_mode", 0)

  if not bp.open then bp.open = true; bp.sortDone = false; bp.openAt = now(); bp.npc = nil; bp.removed = 0; bp.statCache = {} end
  -- 1) sort once per opening (after the panel has had a moment to build)
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
    end
  end
  -- 2) focused character changed -> rebuild the list so items hidden for the previous one come back
  local npc = focusedNpc()
  if bp.npc ~= nil and npc ~= bp.npc then
    resetEntries()
    if bp.removed > 0 then vm:HandleBackpackBatchChange(); bp.removed = 0 end
    bp.npc = npc
    return
  end
  bp.npc = npc
  -- 3) hide what this character cannot use
  local grid = view.GRID_ITEM
  local items = gridItems(grid)
  if hide then
    local n = 0
    for _, sp in ipairs(items) do
      if sp:IsValid() and not sp.bOnlyForLayout and reqCache[sp.ItemDefId] and not canUse(sp.ItemDefId, npc) then grid:RemoveItem(sp); n = n + 1 end
    end
    if n > 0 then bp.removed = bp.removed + n; print("[GamepadTweaks] backpack: hid " .. n .. " item(s) unusable by npc " .. npc .. "\n") end
  end
  -- 4) highlight better equipment on the visible entries
  if not mark then if next(bp.lit) then resetEntries() end return end
  local worn = wornStats(npc)
  local viewName = view:GetFName():ToString()
  local seen = {}
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
        bp.lit[key] = en; seen[key] = true
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

-- ---------------------------------------------------------------- scheduler (100 ms tick)
local tasks = {
  { every = 5,  fn = taskCursor },
  { every = 3,  fn = taskMapFlag },
  { every = 20, fn = taskVisited },
  { every = 3,  fn = taskTeleport },
  { every = 3,  fn = taskArrival },
  { every = 10, fn = taskCmd },
  { every = 2,  fn = taskScan },
  { every = 30, fn = taskInteract },
  { every = 3,  fn = taskBattle },
  { every = 3,  fn = taskBackpack },
}
local tick = 0
local errCount = {}
writeFile("map.flag", "0")
writeFile("battle.flag", "0")
LoopInGameThreadWithDelay(100, function()
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
