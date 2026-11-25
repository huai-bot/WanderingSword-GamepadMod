print("[GamepadTweaks] v4.30 loaded\n")
-- Everything runs from ONE game-thread loop (LoopInGameThreadWithDelay). Earlier versions queued a new
-- ExecuteInGameThread callback from several LoopAsync timers; UE4SS 4.0 occasionally frees such a queued
-- callback early ("Ref was not function") and the game crashes. A single registered loop avoids that.

local DIR = [[D:\TOOLS\AWSdata\WanderingSword\]]
local DLLPATH = [[D:\GAME\Wandering Sword\Wandering_Sword\Binaries\Win64\xinput1_3.dll]]
local RUNTIME = { owner = false, events = 0 }
local function now() return os.clock() end
local function writeFile(n, s) local f = io.open(DIR .. n, "w"); if not f then return false end; local ok = f:write(s); return f:close() and ok ~= nil end
local function readFirst(n) local f = io.open(DIR .. n, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end

-- Latest load owns all tasks; older Lua instances cannot compete for files or speed state.
-- UE4SS may run initialization, the timer and hooks on distinct Lua threads. The
-- native owner key is lua_State*, so call owner-sensitive exports on one pinned coroutine.
RUNTIME.call = coroutine.wrap(function(fn)
  while true do fn(); fn = coroutine.yield() end
end)
RUNTIME.claim = package.loadlib(DLLPATH, "wsmod_runtime_claim")
RUNTIME.pollNative = package.loadlib(DLLPATH, "wsmod_runtime_poll")
RUNTIME.token = string.format("%x", os.time()) .. "_" .. (tostring(RUNTIME):match("(%x+)$") or "0"):lower()
RUNTIME.file = "runtime_" .. RUNTIME.token .. ".txt"
local function runtimePoll()
  if not RUNTIME.pollNative then RUNTIME.owner = false; return false end
  local removed, _, errno = os.remove(DIR .. RUNTIME.file)
  if not removed and errno ~= 2 then RUNTIME.owner, RUNTIME.events = false, 0; return false end
  RUNTIME.call(RUNTIME.pollNative)
  local s = readFirst(RUNTIME.file) or ""
  local owner, serial, clock = s:match("^(%d)|(%d+)|(%d+)$")
  if owner ~= "1" then RUNTIME.owner, RUNTIME.events = false, 0; return false end
  serial = tonumber(serial)
  if RUNTIME.serial then RUNTIME.events = RUNTIME.events + math.min(16, (serial - RUNTIME.serial) % 4294967296) end
  RUNTIME.owner, RUNTIME.serial, RUNTIME.clock = true, serial, tonumber(clock) / 1000
  return true
end
if RUNTIME.claim and writeFile("runtime_claim.req", RUNTIME.token) then
  RUNTIME.call(RUNTIME.claim); os.remove(DIR .. "runtime_claim.req")
end
if not runtimePoll() then
  print("[GamepadTweaks] runtime unavailable; install matching v4.30 DLL and Lua together\n")
  return
end
local nativeRegisterHook = RegisterHook
local function RegisterHook(path, before, after)
  local function owned(fn)
    if not fn then return nil end
    return function(...) if RUNTIME.owner then return fn(...) end end
  end
  if after then return nativeRegisterHook(path, owned(before), owned(after)) end
  return nativeRegisterHook(path, owned(before))
end

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
  if not live(pc) or not live(pc.Pawn) then
    pc = nil
    for _, candidate in ipairs(FindAllOf("BP_PlayerController_C") or {}) do
      if live(candidate) and live(candidate.Pawn) then pc = candidate; break end
    end
    if not pc then return nil end
  end
  local pawn = pc.Pawn
  local full = pawn:GetFullName()
  local lv = full:match("%.([%w_]+):PersistentLevel")
  if not lv then return nil end
  if lv ~= lastLevel then lastLevel = lv; pauseUntil = now() + 5; writeFile("cur.txt", lv); return nil end
  return pc, pawn, lv, full
end

-- One snapshot for all UI cells and subsystems. Keep the last usable snapshot
-- across a transient sharing failure; CP936 comments need no decoding.
local config = { nextAt = 0, values = {} }
function config.get(key)
  local t = RUNTIME.clock or now()
  if t >= config.nextAt then
    config.nextAt = t + 0.5
    local raw = readFirst("wsmod.ini")
    if raw and raw ~= "" then
      local values = {}
      for k,v in ("\n" .. raw:gsub("%z", "")):gmatch("\n[ \t]*([%w_]+)[ \t]*=[ \t]*([^;\r\n \t]+)") do
        if values[k] == nil then values[k] = v end -- same first-match rule as before
      end
      if next(values) then config.values = values end
    end
  end
  return config.values[key]
end
local function iniNumber(key, def)
  local v = config.get(key); return tonumber(v and v:match("^(%d+)")) or def
end

-- ---------------------------------------------------------------- 1) hide the game's own cursor
local inBattle = false
local inFight = false     -- a real fight only (inBattle is also true on the overworld travel map)
local function taskCursor()
  if inBattle then return end            -- in battle the game manages its own cursor
  local pc = stableWorld(); if pc and pc.bShowMouseCursor then pc.bShowMouseCursor = false end
end

-- ---------------------------------------------------------------- 1b) Start -> character screen, gamepad mode kept
-- The proxy used to open AND close the character screen by tapping keyboard B. Any keyboard event switches the
-- game to keyboard/mouse mode (log: "键鼠模式 : --- show cursor"), which hides the gamepad focus frame until the
-- stick is moved. Closing with B left the game in keyboard mode for the next opening too.
-- Now the proxy writes start.req and waits up to 0.6 s for start.ack:
--   "1" = done here without any input event: JHNeoUIPrimeModuleVM:ShowAndGotoTab(0) / :Hide() (the game stays
--         in its input mode; tabs are zero-based: 0 队伍, 1 武学, 2 任务, 3 经脉)
--   "0" = not possible here (fight, dialog, no HUD = cut-scene / loading, ...): the proxy taps B as before.
-- v4.17 "clicked" the HUD's 人物 button instead: that event does not open the screen (measured 2026-11-24).
local START = { pending = nil, at = 0 }
os.remove(DIR .. "start.req"); os.remove(DIR .. "start.take")
local function primeVM()
  for _, v in ipairs(FindAllOf("JHNeoUIPrimeModuleVM") or {}) do if live(v) then return v end end
  return nil
end
local function primeShown(v)
  v = v or primeVM(); if not v then return false end
  local ok, vis = pcall(function() return v:GetModuleVisibility() end)
  return ok and vis or false
end
-- the field's own gamepad menu (e.g. the NPC pop-up menu 交谈/观察/切磋... next to an NPC). v4.18 opened the
-- character screen over it with :Show(); that menu stayed JHGamepadMainInputManager.CurGameMenu and kept taking
-- A / d-pad under the character screen (stray 观察 etc., 2026-11-24). The game's own B path handles it, so then
-- we leave it to B.
local function fieldMenu()
  for _, o in ipairs(FindAllOf("JHGamepadMainInputManager") or {}) do
    if live(o) then
      local ok, name = pcall(function() local m = o.CurGameMenu; if m and m:IsValid() then return m:GetClass():GetFName():ToString() end return nil end)
      if ok and name then return name end
    end
  end
  return nil
end
local function hudFree()
  -- free roaming: the HUD's own 人物 button is on screen, no field menu is active and the UI does not block input
  local gm = fieldMenu()
  if gm then return false, "field menu " .. gm .. " active" end
  local btn = false
  for _, b in ipairs(FindAllOf("BPVE_HUD_NaviBtn_C") or {}) do
    if live(b) and b:GetFName():ToString() == "Btn_Prime" then local ok, vis = pcall(function() return b:IsVisible() end); if ok and vis then btn = true end end
  end
  if not btn then return false, "no HUD" end
  local ui = getUI()
  if ui then
    local blocked = false
    pcall(function() if ui:ShouldDisableInput() then blocked = true end end)
    pcall(function() local d = ui:GetDialogView(); if d and d:IsValid() and d:IsVisible() then blocked = true end end)
    if blocked then return false, "UI busy" end
  end
  return true
end
local PRIMEWATCH = { vis = false, ours = false, menu = nil }
local function primeWatch()
  local W_ = PRIMEWATCH
  local vis = primeShown()
  if vis and not W_.vis then
    W_.ours = START.openedAt ~= nil and now() - START.openedAt < 1.0
    W_.menu = fieldMenu()
    local pad = "?"                                        -- (NAV is declared further down: not visible here)
    pcall(function() for _, x in ipairs(FindAllOf("NeoUISubsystem") or {}) do if live(x) then pad = tostring(x.InputManager:IsGamepadMode()) end end end)
    print(string.format("[GamepadTweaks] Start: screen shown by %s, field menu %s, gamepad mode %s\n", W_.ours and "mod" or "game", tostring(W_.menu), pad))
  elseif vis then
    local gm = fieldMenu()
    if gm ~= W_.menu then
      print(string.format("[GamepadTweaks] Start: field menu under the character screen %s -> %s (screen opened by %s)\n", tostring(W_.menu), tostring(gm), W_.ours and "mod" or "game"))
      W_.menu = gm
    end
  end
  W_.vis = vis
end
local function taskStart()
  if (START.tick or 0) % 5 == 0 then pcall(primeWatch) end
  START.tick = (START.tick or 0) + 1
  local P = START
  if not P.pending then
    if not os.rename(DIR .. "start.req", DIR .. "start.take") then return end
    os.remove(DIR .. "start.take")
    if inFight or not stableWorld() then writeFile("start.ack", "0") return end
    local vm = primeVM()
    if not vm then writeFile("start.ack", "0") return end
    if primeShown(vm) then
      local ok = pcall(function() vm:Hide() end)
      if not ok then writeFile("start.ack", "0") return end
      P.pending, P.at, P.vm = "close", now(), vm
    else
      local free, why = hudFree()
      if not free then writeFile("start.ack", "0") print("[GamepadTweaks] Start: " .. why .. ", proxy taps B\n") return end
      local ok, accepted = pcall(function() return vm:ShowAndGotoTab(0) end)
      if not ok or not accepted then writeFile("start.ack", "0") return end
      P.pending, P.at, P.vm = "open", now(), vm
    end
  end
  local shown = primeShown(P.vm)
  local done = (P.pending == "open") == shown
  if done and P.pending == "open" then
    local ok, ready = pcall(function()
      if P.vm:CurrentTabIndex() ~= 0 then return false end
      for _, b in ipairs(FindAllOf("JHMainCharacterBackpackInTeamVM") or {}) do
        if live(b) and b:GetModuleVisibility() then return true end
      end
      return false
    end)
    done = ok and ready
  end
  if done then
    if P.pending == "open" then P.openedAt = now() end
    print(string.format("[GamepadTweaks] Start: character screen %s in %.0f ms (no key event)\n", P.pending == "open" and "opened" or "closed", (now() - P.at) * 1000))
    P.pending = nil; writeFile("start.ack", "1")
  elseif now() - P.at > 0.35 then
    print("[GamepadTweaks] Start: " .. P.pending .. " did not take effect, proxy taps B\n")
    P.pending = nil; writeFile("start.ack", "0")
  end
end

-- ---------------------------------------------------------------- 2) world map open flag
local lastMap = nil
local battleFlag = nil
local lastBattle = nil
local fightFlag = nil
local function writeBattleFlag()
  local f = inFight or (lastBattle == true and lastMap ~= "1")
  if f ~= battleFlag and writeFile("battle.flag", f and "1" or "0") then battleFlag = f end
  if inFight ~= fightFlag and writeFile("fight.flag", inFight and "1" or "0") then fightFlag = inFight end   -- proxy: Start native only here
end
local shownChain
local function taskMapFlag()
  local open = false
  -- UI visibility is not world readiness. It is safe to inspect widgets during
  -- the post-travel cooldown; taskTeleport still requires a stable field pawn.
  if not inFight then
    local memo = {}
    for _, w in ipairs(FindAllOf("JHNeoUIWorldMapViewBase") or {}) do
      if live(w) then
        local ok, shown = pcall(shownChain, w, memo, 0)
        if ok and shown then open = true; break end
      end
    end
  end
  local v = open and "1" or "0"
  if v ~= lastMap and writeFile("map.flag", v) then lastMap = v; writeBattleFlag() end
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
local arrival -- suppress visited updates until the destination is actually grounded
local ground = { lv = nil, since = 0, lastSave = 0 }
local function onGround(pawn)
  local m = pawn.CharacterMovement
  if not m or not m:IsValid() or m:IsFalling() then return false end
  local mode = m.MovementMode
  return mode == 1 or mode == 2      -- Walking / NavWalking
end
local function taskVisited()
  if arrival then ground.lv = nil; return end
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
local function changeMap(pc, lv, x, y, z)
  local cdo = StaticFindObject("/Script/JH.Default__AsyncTaskChangeSceneMap")
  return cdo:ChangeSceneMap(pc, FName(lv), { X = x, Y = y, Z = z }, 0, true, true, true, true, false)
end
local pendingTravel
local function taskTeleport()
  if not pendingTravel then
    local line = readFirst("teleport.req"); if not line then return end
    if not os.remove(DIR .. "teleport.req") then return end
    pendingTravel = { line = line, untilAt = now() + 1, source = lastLevel }
  end
  local req = pendingTravel
  if inFight or lastMap ~= "1" or lastLevel ~= req.source or now() > req.untilAt then
    pendingTravel = nil; print("[GamepadTweaks] teleport cancelled: map closed, fight, level change or timeout\n"); return
  end
  local pc, pawn, cur, full = stableWorld(); if not pc then return end
  pendingTravel = nil -- never replay after changing the map
  local lv, x, y, z = req.line:match("^([%w_]+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)")
  if not lv then return end
  -- any field pawn may teleport (scene hero, overworld hero BP_WorldHero1_C); never from a fight
  if inFight or full:find("BP_FightSpectator") then print("[GamepadTweaks] teleport skipped: in a fight\n") return end
  local ui = getUI()
  local blocked = inFight
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
local function playerStart(lv)
  for _, s in ipairs(FindAllOf("PlayerStart") or {}) do
    if live(s) and s:GetFullName():find("." .. lv .. ":PersistentLevel.", 1, true) then
      local l = s:K2_GetActorLocation(); return l.X, l.Y, l.Z
    end
  end
end
local function taskArrival()
  local a = arrival; if not a then return end
  local t = now() - a.at
  if t > 40 or inFight then arrival = nil; return end
  local pc = FindFirstOf("BP_PlayerController_C"); if not live(pc) or not live(pc.Pawn) then return end
  local pawn = pc.Pawn; local full = pawn:GetFullName()
  if not full:find("." .. a.lv .. ":PersistentLevel.", 1, true) or not full:find("BP_SceneHero", 1, true) then
    if a.seen then arrival = nil end; return
  end
  local l = pawn:K2_GetActorLocation()
  -- Ignore the pre-placement pawn seen during a same-level load.
  if not a.seen and t < 1 then return end
  a.seen = true
  local grounded = onGround(pawn)
  local low = l.Z < a.z - 180
  if grounded and not low then
    a.stood = a.stood or now()
    if now() - a.stood >= 0.6 then
      if a.rescued then visited[a.lv] = {x=l.X,y=l.Y,z=l.Z}; saveVisited() end
      arrival = nil
    end
    return
  end
  a.stood = nil
  if grounded then a.fallSince = nil else a.fallSince = a.fallSince or now() end
  if a.rescued or (not low and (not a.fallSince or now() - a.fallSince < 1.5)) then return end
  local sx, sy, sz = playerStart(a.lv); if not sx then return end
  if a.tryAt and now() < a.tryAt then return end
  a.tryAt = now() + 1
  if pawn:K2_TeleportTo({X=sx,Y=sy,Z=sz+30}, pawn:K2_GetActorRotation()) then
    pawn.CharacterMovement:StopMovementImmediately(); a.rescued, a.z, a.fallSince = true, sz, nil
    print(string.format("[GamepadTweaks] arrival rescue in place: %s z %.0f -> %.0f\n", a.lv,l.Z,sz))
  end
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
shownChain = function(w, memo, depth)
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

local eachArr -- assigned before the scheduler starts; also used to collect every matching sprite
-- ---------------------------------------------------------------- 7b) walking appearance, without changing fast-run state/speed/mount buffs
-- Remap only mounted visuals; ordinary idle/run and frame progression belong to the native sprite.
-- Followers use a version-checked native renderer copy; the real mount, speed and buffs are never toggled.
local WALK = { on = false, pawn = nil, targets = {}, originals = {}, findAt = 0, cfgAt = 0, cfg = false,
  rebuildAt = 0, followerCount = nil, bridge = package.loadlib(DLLPATH, "wsmod_walk_rebuild"), warned = false }
-- The native renderer indexes FastRunFlipbooks and RunFlipbooks by the same facing.
-- Override instance slots, not shared assets. A later native state=9 then selects the
-- same flipbook as state=2, so switching states does not reset playback to frame zero.
function WALK.slots(sprite, saved, restore)
  if sprite.bShipType then return end
  local run, fast = sprite.RunFlipbooks, sprite.FastRunFlipbooks
  if not run or not fast then return end
  fast:ForEach(function(i, slot)
    local current = slot:get(); if not current or not current:IsValid() then return end
    local old = saved[i]
    if restore then
      if old and current:GetAddress() == old.applied then
        local orig = old.asset
        if not orig:IsValid() then orig = LoadAsset(old.path) end
        if orig and orig:IsValid() then slot:set(orig) end
      end
    elseif i <= #run then
      local normal = run[i]
      if normal and normal:IsValid() and normal:GetAddress() ~= current:GetAddress() then
        if not old or current:GetAddress() ~= old.applied then
          old = { asset = current, path = current:GetFullName():match('%S+ (.+)') }; saved[i] = old
        end
        slot:set(normal); old.applied = normal:GetAddress()
      end
    end
  end)
end
local function walkApply()
  if not WALK.on then return end
  for _, target in ipairs(WALK.targets) do
    local actor, sprite = target.actor, target.sprite
    if live(actor) and live(sprite) then
      if sprite.DefaultRunAnimalState == 9 then sprite.DefaultRunAnimalState = 2 end
      if sprite.DefaultIdleAnimalState == 9 then sprite.DefaultIdleAnimalState = 1 end
      -- Keep the game's animation driver: followers can move by transform with
      -- zero reported velocity. Never overwrite ordinary idle/run every tick.
      if sprite.AnimalState == 9 then sprite.AnimalState = 2 end
      if target.hero and not sprite.bShipType and sprite.AnimalState == 2 and not sprite:IsPlaying() then
        sprite:SetLooping(true); sprite:Play() -- resume, never PlayFromStart every tick
      end
    end
  end
end
local function taskWalkAppearance()
  local pc, pawn, lv, full = stableWorld(); if not pc then return end
  if inFight or not (full:find("BP_SceneHero", 1, true) or full:find("BP_WorldHero", 1, true)) then return end
  if now() >= WALK.cfgAt then WALK.cfg, WALK.cfgAt = iniNumber("walk_appearance", 0) == 1, now() + 1 end
  if WALK.pawn ~= pawn:GetAddress() then
    WALK.pawn, WALK.targets, WALK.originals, WALK.findAt, WALK.on, WALK.followerCount, WALK.rebuildAt = pawn:GetAddress(), {}, {}, 0, false, nil, 0
  end
  if not WALK.cfg then
    if WALK.on then
      WALK.on = false
      for _, original in ipairs(WALK.originals) do
        if live(original.sprite) then
          if next(original.slots) then WALK.slots(original.sprite, original.slots, true) end
          original.sprite.bAutoCalcRunOrIdleState = original.auto
          original.sprite.DefaultRunAnimalState, original.sprite.DefaultIdleAnimalState = original.run, original.idle
        end
      end
      if WALK.followerCount then pawn.FollowerCount = WALK.followerCount end
      pawn:RebuidFollowers(); pawn:KeepFastRunState() -- restore today's real fast-run state, not a cached old one
      WALK.targets, WALK.originals = {}, {}
      print("[GamepadTweaks] walking appearance: off (native display restored)\n")
    end
    return
  end
  if not WALK.on then
    WALK.on, WALK.followerCount = true, tonumber(pawn.FollowerCount)
    if WALK.followerCount then pawn.FollowerCount = math.max(5, WALK.followerCount) end
    print("[GamepadTweaks] walking appearance: on (speed/effects unchanged)\n")
  end
  if now() >= WALK.findAt then
    WALK.findAt, WALK.targets = now() + 0.1, {}
    local cls = StaticFindObject("/Script/JH.JHPaperFlipbookComponent")
    if not cls or not cls:IsValid() then return end
    local function add(actor)
      if not live(actor) then return end
      eachArr(actor:K2_GetComponentsByClass(cls), function(i, sprite)
        if not live(sprite) then return end
        local known
        for _, original in ipairs(WALK.originals) do if live(original.sprite) and original.sprite:GetAddress() == sprite:GetAddress() then known = original; break end end
        if not known then known = { sprite = sprite, auto = sprite.bAutoCalcRunOrIdleState, slots = {},
          run = sprite.DefaultRunAnimalState, idle = sprite.DefaultIdleAnimalState }; WALK.originals[#WALK.originals + 1] = known end
        if actor == pawn then WALK.slots(sprite, known.slots, false) end
        WALK.targets[#WALK.targets + 1] = { actor = actor, sprite = sprite, hero = actor == pawn }
      end)
    end
    add(pawn)
    local heroSprites = #WALK.targets
    local count = 0
    eachArr(pawn.FollowCharacters, function(i, actor) if live(actor) then count = count + 1; add(actor) end end)
    local report = string.format("%s heroSprites=%d followers=%d", lv, heroSprites, count)
    if report ~= WALK.report then WALK.report = report; print("[GamepadTweaks] walking: " .. report .. "\n") end
    if count == 0 and now() >= WALK.rebuildAt then
      WALK.rebuildAt = now() + 2 -- no per-frame spawning; native story/scene guards are kept
      if WALK.bridge then
        if writeFile("walk_actor.txt", string.format("%x", pawn:GetAddress())) then WALK.bridge(); WALK.findAt = 0 end
      elseif not WALK.warned then WALK.warned = true; print("[GamepadTweaks] walking followers: bridge missing (old DLL)\n") end
    end
  end
  walkApply()
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
local function taskBattle()
  local pc, pawn, lv, full = stableWorld()
  if not pc then return end
  local sigSpell = widgetShown("BPMV_BattleSpell_C")       -- battle skill bar on screen
  local sigPawn = not full:find("BP_SceneHero")            -- controlling something other than the field hero
  local b = sigSpell or sigPawn
  inFight = sigSpell or full:find("BP_FightSpectator") ~= nil
  writeBattleFlag()
  if b ~= lastBattle then
    lastBattle = b; inBattle = b; writeBattleFlag()
    print(string.format("[GamepadTweaks] battle=%s (spellbar=%s pawn=%s %s)\n", tostring(b), tostring(sigSpell), tostring(sigPawn), full:match("[^%.]+$") or "?"))
  end
end

-- ---------------------------------------------------------------- 8b) periodic autosave (real seconds, never forced)
-- Keep the game's AutoSave path: its SaveSlot implementation still decides whether saving is allowed.
-- If the interval expires in battle, a dialog, a menu or a loading screen, retry when the field is safe.
local AUTOSAVE_INTERVAL = 120
local AUTOSAVE = { nextAt = nil }
local function taskAutoSave()
  local pc, pawn, lv, full = stableWorld(); if not pc then return end
  if not (full:find("BP_SceneHero", 1, true) or full:find("BP_WorldHero", 1, true)) then return end
  local t = os.time()          -- wall clock: battle speed and paused game time cannot shorten the interval
  if not AUTOSAVE.nextAt then AUTOSAVE.nextAt = t + AUTOSAVE_INTERVAL end
  if t < AUTOSAVE.nextAt then return end
  if inFight or not onGround(pawn) or primeShown() or fieldMenu() then return end
  if widgetShown("BPMV_BattleSpell_C") or not widgetShown("BPVE_HUD_NaviBtn_C") then return end
  local ui = getUI(); if not ui or ui:ShouldDisableInput() then return end
  local dialog = ui:GetDialogView()
  if dialog and dialog:IsValid() and dialog:IsVisible() then return end
  for _, sm in ipairs(FindAllOf("SaveManager") or {}) do
    if live(sm) then
      sm:AutoSave()
      AUTOSAVE.nextAt = t + AUTOSAVE_INTERVAL
      print("[GamepadTweaks] autosave: requested (120 s interval)\n")
      return
    end
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
  local v = config.get(key); return v and v:match("^#?(%x+)") or def
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

eachArr = function(arr, fn)
  if arr == nil then return end
  if type(arr) == "table" then for i, e in ipairs(arr) do if type(e) == "userdata" and e.get then e = e:get() end fn(i, e) end
  elseif arr.ForEach then arr:ForEach(function(i, e) fn(i, e:get()) end) end
end

-- equipment rows of the Items table: requirements per item id (built once)
local reqCache = nil
local kindCache = {}     -- defId -> { sub, skill }  for books (30-38), materials (40-49), treasures (50-56), quest items (60), recipes (99)
local baseCache = {}
local weaponLimits = nil -- NPCs.WeaponLimits, not the character's currently equipped weapon
local function buildWeaponLimits()
  weaponLimits = {}
  local dt = StaticFindObject("/Game/JH/Tables/NPCs.NPCs")
  if not live(dt) then weaponLimits = nil; return end
  dt:ForEachRow(function(name, row)
    local allowed = {}
    eachArr(row.WeaponLimits, function(i, v) local t = tonumber(v); if t then allowed[t] = true end end)
    weaponLimits[row.ID] = allowed
  end)
end
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
  if not npc or npc < 0 then return true end
  local e = reqCache[defId]; if not e then return true end
  if e.sub >= 1 and e.sub <= 6 then
    if not weaponLimits then buildWeaponLimits() end
    local allowed = weaponLimits and weaponLimits[npc]
    if allowed and not allowed[e.sub] then return false end
  end
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

local function teamNpcFromJson(js)
  local idx = tonumber(js:match('"focus_npc_index"%s*:%s*(%-?%d+)'))
  if not idx then return -1 end
  for blk in js:gmatch('{[^{}]-}') do
    if tonumber(blk:match('"index"%s*:%s*(%-?%d+)')) == idx then
      local id = tonumber(blk:match('"npc_id"%s*:%s*(%-?%d+)'))
      if id and id >= 0 then return id end
    end
  end
  return -1                    -- unknown focus: do not filter as if the hero were selected
end
local function focusedNpc()
  local ov = readFirst("npc_override.txt"); if ov and tonumber(ov) then return tonumber(ov) end
  for _, v in ipairs(FindAllOf("TeamModuleVM") or {}) do
    if live(v) then return teamNpcFromJson(v.RootData:DataToString():ToString()) end
  end
  return -1
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

-- Gift eligibility is receiver-specific, not the ordinary backpack's weapon/learnability cache.
local ensureCellHook
local GIFT = { vm = nil, grid = nil, addr = nil, npc = -1, favor = nil, nextRead = 0, enabled = true,
  bridge = package.loadlib(DLLPATH, "wsmod_gift_context"), defs = {}, gone = {}, warned = false, hobbies = nil }
local function giftHidden(sp)
  if not GIFT.enabled or not live(sp) then return false end
  local id = sp.ItemDefId
  if not id or id <= 0 then return false end
  if sp.bIsLocked or sp.bOnlyForLayout then return true end
  local def = GIFT.defs[id]
  if not def then
    local ok, d = pcall(function() return sp:GetDef() end)
    if not ok or type(d) ~= "table" then return false end
    def = { cant = d.bCantGift == true, quality = tonumber(d.Quality), sub = tonumber(d.ItemType) }; GIFT.defs[id] = def
  end
  if def.cant then return true end
  if GIFT.hobbies and def.sub and not GIFT.hobbies[def.sub] then return true end
  if GIFT.favor == nil or def.quality == nil then return false end -- unknown receiver/version: preserve items
  -- v1.24.32's native gift-quality predicate (0x1122f20): abs(relationship tier) + 1 is the minimum quality.
  local f, tier = GIFT.favor, 0
  if f <= -80 then tier = 4 elseif f <= -60 then tier = 3 elseif f <= -40 then tier = 2 elseif f <= -20 then tier = 1
  elseif f >= 80 then tier = 4 elseif f >= 60 then tier = 3 elseif f >= 40 then tier = 2 elseif f >= 20 then tier = 1 end
  return def.quality < tier + 1
end
local function giftItemKey(sp)
  if not live(sp) then return nil end
  local ok, id = pcall(function() return sp:GetId():ToString() end)
  return ok and id or tostring(sp.ItemDefId)
end
local function giftEntryInit(self, item, widget)
  if not GIFT.addr then return end
  local g, sp, en = self:get(), item:get(), widget:get()
  if live(g) and g:GetAddress() == GIFT.addr and live(en) then en:SetRenderOpacity(giftHidden(sp) and 0 or 1) end
end
local function giftFilter()
  local grid = GIFT.grid; if not live(grid) then return end
  local gone = {}
  for _, sp in ipairs(gridItems(grid)) do
    if live(sp) and giftHidden(sp) then gone[sp:GetAddress()] = true; grid:RemoveItem(sp) end
  end
  GIFT.gone = gone
  for _, en in ipairs(FindAllOf("BPEntry_Item_WDT_Gift_C") or {}) do
    if live(en) then
      local sp = en:GetBindedDataObj()
      if live(sp) then en:SetRenderOpacity((gone[sp:GetAddress()] or giftHidden(sp)) and 0 or 1) end
    end
  end
end
local function taskGift()
  if not stableWorld() or inFight then GIFT.vm, GIFT.grid, GIFT.addr = nil, nil, nil; return end
  local vm = GIFT.vm
  if not live(vm) or not vm:GetModuleVisibility() then
    vm = nil
    for _, v in ipairs(FindAllOf("JHMainCharacterGiftBackpackVM") or {}) do
      if live(v) and v:GetModuleVisibility() then vm = v; break end
    end
  end
  if not vm then GIFT.vm, GIFT.grid, GIFT.addr, GIFT.favor = nil, nil, nil, nil; return end
  ensureCellHook()
  local opened = not GIFT.vm or GIFT.vm:GetAddress() ~= vm:GetAddress()
  if opened then
    local view = vm:GetPairView(); if not live(view) or not live(view.GRID_ITEM) then return end
    GIFT.vm, GIFT.grid, GIFT.addr = vm, view.GRID_ITEM, view.GRID_ITEM:GetAddress()
    GIFT.npc, GIFT.favor, GIFT.nextRead = -1, nil, 0
  end
  if now() >= GIFT.nextRead then
    GIFT.nextRead = now() + 0.5
    local enabled, npc, favor, hobbies = iniNumber("gift_hide_unavailable", 1) == 1, -1, nil, nil
    if GIFT.bridge then
      local address = string.format("%x", vm:GetAddress())
      local cleared, _, errno = os.remove(DIR .. "gift_context.txt")
      if (cleared or errno == 2) and writeFile("gift_vm.txt", address) then -- ENOENT is also fresh
        GIFT.bridge()
        local result = readFirst("gift_context.txt") or ""
        local seen, value = result:match("^(%x+)|(%-?%d+)")
        if seen == address then npc = tonumber(value) or -1 end
      end
    elseif not GIFT.warned then
      GIFT.warned = true; print("[GamepadTweaks] gift: receiver bridge missing; quality filtering disabled (old DLL)\n")
    end
    if npc >= 0 then
      local lib = StaticFindObject("/Script/JH.Default__NPCFuncLib")
      if lib and lib:IsValid() then
        local ok, f = pcall(function() return lib:GetFriendliness(npc) end); if ok then favor = tonumber(f) end
        local good, h = pcall(function()
          local raw = lib:GetNPCHobbies(npc); if raw == nil then return nil end
          local out = {}; eachArr(raw, function(i, v) local t = tonumber(v); if t then out[t] = true end end)
          return out
        end)
        if good then hobbies = h end
      end
    end
    local keys = {}; for t in pairs(hobbies or {}) do keys[#keys + 1] = t end; table.sort(keys)
    local hobbySig = hobbies and table.concat(keys, ",") or "unknown"
    local changed = opened or enabled ~= GIFT.enabled or npc ~= GIFT.npc or favor ~= GIFT.favor or hobbySig ~= GIFT.hobbySig
    GIFT.enabled, GIFT.npc, GIFT.favor, GIFT.hobbies, GIFT.hobbySig = enabled, npc, favor, hobbies, hobbySig
    if changed then
      -- Recompute is_fav through the game's receiver-aware converter. Keep the selected item if still available.
      local selected = GIFT.grid:GetSelectedItem(); local key = giftItemKey(selected)
      local index = live(selected) and GIFT.grid:GetIndexForItem(selected) or 0
      vm:HandleBackpackBatchChange(); giftFilter()
      local items = gridItems(GIFT.grid); local pick = nil
      if key then for _, sp in ipairs(items) do if live(sp) and giftItemKey(sp) == key then pick = sp; break end end end
      if not pick and #items > 0 then pick = items[math.min(math.max((index or 0) + 1, 1), #items)] end
      if pick then GIFT.grid:SetSelectedItem(pick) end
    end
  end
  giftFilter() -- game-driven sort/filter/item changes are filtered too; no address-keyed eligibility cache
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
  memo = {}, info = {}, wtype = {}, dim = {}, dimWt = {}, recipeDone = {}, bookDone = {}, srcN = -1, cfgHide = true, cfgTidy = true,
  cacheAt = -1, cacheNpc = 0, cacheFilter = -1 }

-- 学成 manuals: the cell's display data says "is_acquired":true (the game's 学成 mark). This is not the same as
-- "the focused character knows the skill" (HasSkillById): most 学成 books are known by nobody in the team.
-- The flag is the same for every character, so it is learned once from the cells and kept in acquired_books.txt,
-- which lets the next opening hide those books before they are drawn.
do
  local s = readFirst("acquired_books.txt")
  if s then for id in s:gmatch("%d+") do HIDE.bookDone[tonumber(id)] = true end end
end
local function saveBooks()
  local t = {} for id in pairs(HIDE.bookDone) do t[#t + 1] = tostring(id) end table.sort(t)
  writeFile("acquired_books.txt", table.concat(t, "\n") .. "\n")
end
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
  if not npc or npc < 0 then return false end
  local m = HIDE.memo[npc]; if not m then m = {}; HIDE.memo[npc] = m end
  local d = m[defId]; if d ~= nil then return d end
  d = false
  local e, k = reqCache[defId], kindCache[defId]
  if e then
    -- Use the NPCs row's full WeaponLimits plus explicit item requirements, never a stale grey cell.
    if not canUse(defId, npc) then d = "u" end
  elseif k then
    if k.sub >= 30 and k.sub <= 38 then
      local info = teamInfo(npc); local has = false
      if k.skill and info and info:IsValid() then pcall(function() has = info:HasSkillById(k.skill) end) end
      if has then d = "a"                                                        -- known: only in 秘籍
      elseif npc ~= 0 and k.sub <= 35 and weaponType(npc) > 0 and (k.sub - 29) ~= weaponType(npc) then
        d = "u"                                                                  -- teammate cannot learn other weapon arts
      elseif HIDE.bookDone[defId] then d = "a"                                   -- 学成 (game's mark): only in 秘籍
      end
    elseif k.sub == 60 or (k.sub >= 40 and k.sub <= 49) then d = "a"            -- quest items, materials
    elseif k.sub >= 50 and k.sub <= 56 then d = "a"                             -- 珍宝: paintings, chess, tea sets, books, lyre, treasures, flowers
    elseif k.sub == 99 and HIDE.recipeDone[defId] then d = "a"                  -- learned recipe
    end
  end
  if d == false and not e then local dm = HIDE.dim[npc]; if dm and dm[defId] then d = "u" end end   -- learned only for non-equipment
  m[defId] = d
  return d
end
local function isHidden(npc, filter, defId)
  local d = decide(npc, defId)
  if d == "u" then return HIDE.cfgHide end
  if d == "a" then return HIDE.cfgTidy and filter == 0 end
  return false
end
local function observeNpcFromJson(js)
  local found = nil
  for id in js:gmatch('"npc_id"%s*:%s*(%-?%d+)') do
    id = tonumber(id)
    if found ~= nil and found ~= id then return -1 end
    found = id
  end
  return found or -1 -- never substitute the team tab's selected NPC for the observed character
end
local function observeGreyWeapon(npc, defId, js)
  if npc >= 0 or not HIDE.context or not HIDE.cfgHide then return false end
  local e = reqCache[defId]
  -- Only the active observed grid's current, ID-matched display data; never learn equipment greyness.
  return e and e.sub >= 1 and e.sub <= 6 and js:find('"not_learnable":true', 1, true) ~= nil or false
end
-- current character / tab, re-read at most once per 3 ms (one read per batch of cells)
local function current()
  local t = os.clock()
  if t - HIDE.cacheAt > 0.003 then
    HIDE.cacheAt = t
    local npc = -1
    local tv = HIDE.team
    if HIDE.context and live(HIDE.context) then
      npc = observeNpcFromJson(HIDE.context.RootData:DataToString():ToString())
    elseif tv and tv:IsValid() then npc = teamNpcFromJson(tv.RootData:DataToString():ToString()) end
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
ensureCellHook = function()
  if HIDE.hooked or iniNumber("cell_hook", 1) ~= 1 then return end
  local fn = StaticFindObject(HOOK_FN); if not fn or not fn:IsValid() then return end
  local ok, err = pcall(function()
    RegisterHook(HOOK_FN, function(self, item, widget)
      pcall(onEntryInit, self, item, widget)
      pcall(giftEntryInit, self, item, widget)
    end)
  end)
  HIDE.hooked = ok
  print("[GamepadTweaks] backpack/gift: cell hook " .. (ok and "registered" or ("failed: " .. tostring(err))) .. "\n")
end
local function onOpen(vm)
  local view = vm:GetPairView(); if not view or not view:IsValid() then return false end
  HIDE.view, HIDE.grid, HIDE.vn = view, view.GRID_ITEM, view:GetFName():ToString()
  HIDE.gridAddr = HIDE.grid:GetAddress()
  HIDE.team = nil
  if not HIDE.context then for _, v in ipairs(FindAllOf("TeamModuleVM") or {}) do if live(v) then HIDE.team = v end end end
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
  local npcs = HIDE.context and { (current()) } or teamNpcs()
  for _, npc in ipairs(npcs) do
    if npc >= 0 then
      local wt = weaponType(npc)
      if HIDE.dimWt[npc] ~= nil and HIDE.dimWt[npc] ~= wt then HIDE.dim[npc] = nil end   -- weapon changed: forget greyed list
      HIDE.dimWt[npc] = wt
      for id in pairs(ids) do decide(npc, id) end
    end
  end
  ensureCellHook()
  print(string.format("[GamepadTweaks] backpack: preloaded %d characters x %d items in %.1f ms\n", #npcs, (function() local n = 0 for _ in pairs(ids) do n = n + 1 end return n end)(), (os.clock() - t0) * 1000))
  return true
end
local function taskHide()
  if inFight then HIDE.open = false return end
  local vm = HIDE.vm
  local visible = live(vm) and vm:GetModuleVisibility()
  if not visible and now() < HIDE.findAt then HIDE.open = false; return end
  if not visible or now() >= HIDE.findAt then
    HIDE.findAt = now() + 0.25
    local picked, context = nil, nil
    for _, view in ipairs(FindAllOf("BPMV_Observe_C") or {}) do
      if live(view) and view:IsVisible() then
        local parent = view:GetNeoUIVM()
        if live(parent) then
          local child = parent:GetSubModuleByKey(FName("Backpack"))
          if live(child) and child:GetModuleVisibility() then picked, context = child, parent; break end
        end
      end
    end
    if not picked then
      for _, v in ipairs(FindAllOf("JHMainCharacterBackpackInTeamVM") or {}) do
        if live(v) and v:GetModuleVisibility() then picked = v; break end
      end
    end
    if not picked then HIDE.open, HIDE.vm, HIDE.context = false, nil, nil; return end
    if not live(vm) or vm:GetAddress() ~= picked:GetAddress() then HIDE.open = false end
    vm, HIDE.vm, HIDE.context = picked, picked, context
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
          if observeGreyWeapon(npc, sid, js) then grid:RemoveItem(sp); gone[addr] = true; learnt = learnt + 1 end
          if npc >= 0 and not reqCache[sid] and js:find('"not_learnable":true', 1, true) and decide(npc, sid) == false then
            HIDE.dim[npc] = HIDE.dim[npc] or {}; HIDE.dim[npc][sid] = true; HIDE.memo[npc][sid] = "u"; newly = true
          elseif js:find('"is_recipe":true', 1, true) and js:find('"is_acquired":true', 1, true) and not HIDE.recipeDone[sid] then
            HIDE.recipeDone[sid] = true; for _, mm in pairs(HIDE.memo) do mm[sid] = nil end; newly = true
          elseif not HIDE.bookDone[sid] and js:find('"is_acquired":true', 1, true) then
            local it = tonumber(js:match('"item_type":(%d+)'))
            if it and it >= 30 and it <= 38 then
              HIDE.bookDone[sid] = true; for _, mm in pairs(HIDE.memo) do mm[sid] = nil end; newly = true; saveBooks()
            end
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
  if npc < 0 then resetEntries(); return end
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
  -- side bar with a remembered cell: focus that cell's button directly. Going through ChangeNaviFocus("SideBar")
  -- makes the game re-focus its default cell ~0.5 s later (measured 2026-11-23), which undid the memory.
  local c = NAV.sideCell
  if target == "SideBar" and c and c:IsValid() and c:IsVisible() then
    local b = c.BTN_SidebarCell
    if b and b:IsValid() then b:SetFocus() else c:SetFocus() end
    return
  end
  local w = NAV.vm:ChangeNaviFocus(FName(target), 0, "")
  if w and w:IsValid() then w:SetFocus() end
  -- come back to where we were inside the region (same frame, so the default cell is never drawn focused)
  if target == "Backpack" then
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
OBS_HOOK = nil            -- set by the 观察 section below
local function navHook()
  if NAV.hooked then return end
  NAV.hooked = true
  local ok, e = pcall(function()
    RegisterHook("/Script/NeoUI.NeoUIUniversalModuleVMBase:ChangeNaviFocus", function(self, id, scen, str)
      if NAV.self then return end
      if OBS_HOOK and OBS_HOOK(self, id) then return end
      if not NAV.open or not NAV.cfg then return end
      local key = id:get():ToString()
      if key ~= "Property" and key ~= "Equip" then return end
      local t = navInstead()
      if t == "Bottom" then t = "SideBar" end
      local c = NAV.sideCell
      if t == "SideBar" and c and c:IsValid() and c:IsVisible() then
        id:set(FName("ModSkip"))          -- no such module: the call does nothing; navFocus focuses the remembered cell
      else
        id:set(FName(t))
      end
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
local MASKS = { prime = 0, obs = 0 }
local PADEV = nil        -- proxy events ("L" "R" "<" ">" "^" "v" "Y") of this tick, read once by taskPadEv
local navMask
local function maskSet(owner, m) MASKS[owner] = m; navMask(MASKS.prime | MASKS.obs) end
function navMask(m)
  if NAVX then
    if m ~= 0 or NAV.mask ~= 0 then
      NAVX.begin()
      for n, b in pairs(NAV_BITS) do if m & b ~= 0 then NAVX[n]() end end
      NAVX.commit()                       -- refreshed every tick while non-zero; the proxy drops it after 300 ms
    end
  else
    local on = m ~= 0
    if on ~= NAV.flag and writeFile("prime.flag", on and "1" or "0") then NAV.flag = on end
  end
  NAV.mask = m
end
local function navFlag(on) if not on then maskSet("prime", 0) end end
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
  if not t:IsVisible() then NAV.open = false; navFlag(false) return end
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
  local ev = PADEV
  if ev and (MASKS.prime ~= 0 or NAV.flag) then
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
  if pressed ~= 0 and cur then
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
  maskSet("prime", m)                 -- also in mouse mode: it only filters gamepad input
  NAV.cur = cur
end

-- ---------------------------------------------------------------- 10b) 观察 screen (BPMV_Observe_C): skip 属性 / 装备 for the gamepad
-- Regions left for the gamepad: 背包 (Backpack) and the bottom buttons (切磋/送礼/请教/击杀/离队). LT/RT switch between
-- the two, the screen opens on the first bottom button (切磋), UP on the bottom row goes to the backpack.
-- The game itself (v1.24.32, measured 2026-11-23 with injected input):
--   opens on 属性 (DefaultFocusModuleKey = Property); LT/RT do nothing; LB/RB switch backpack tabs
--   backpack left edge -> ChangeNaviFocus("Equip", 3); 装备 left -> ChangeNaviFocus("Property", 3)
--   属性 DOWN x5 -> bottom row (widget navigation); bottom row UP -> 属性 (widget navigation)
-- We: proxy blocks LT/RT everywhere and UP on the bottom row (events in trig.req); the ChangeNaviFocus hook turns
-- every game request for Property/Equip (observe VM or its sub-module VMs) into "SideBar" (a key this screen does not have, so
-- the call does nothing and the focus stays where it is, e.g. the backpack's left edge simply stops).
local OBS = { view = nil, vm = nil, findAt = 0, open = false, cfg = true, stable = nil, want = nil, wantUntil = 0,
  tries = 0, lastTry = 0, force = false, grid = nil, bpView = nil, bpIdx = 0, btn = nil, memAt = 0, vn = nil, rewrites = 0 }
local OBS_BTNS = { "BTN_QieCuo", "BTN_SongLi", "BTN_QingJiao", "BTN_JiSha", "BTN_LiDui" }      -- left to right
local function obsFD(w) return w and w:IsValid() and w:IsVisible() and w:HasFocusedDescendants() end
local function obsBtnOn(b)
  if not (b and b:IsValid() and b:IsVisible()) then return false end
  if b:HasFocusedDescendants() then return true end
  local bg = b.JHGPCBtn_ActiveBG
  return bg and bg:IsValid() and bg:IsVisible() or false
end
local function obsRegion()
  local v = OBS.view
  for _, cn in ipairs({ "BPMV_Observe_Property_C" }) do
    for _, x in ipairs(FindAllOf(cn) or {}) do if live(x) and obsFD(x) then return "Property" end end
  end
  for _, x in ipairs(FindAllOf("BPMV_Team_Equip_V3_C") or {}) do if live(x) and obsFD(x) then return "Equip" end end
  local bv = OBS.bpView
  if bv and bv:IsValid() and obsFD(bv) then return "Backpack" end
  for _, bn in ipairs(OBS_BTNS) do local b = v[bn]; if obsBtnOn(b) then return "Bottom", b end end
  return nil
end
local function obsFirstBtn()
  local b = OBS.btn
  if b and b:IsValid() and b:IsVisible() then return b end
  for _, bn in ipairs(OBS_BTNS) do local x = OBS.view[bn]; if x and x:IsValid() and x:IsVisible() then return x end end
  return nil
end
local function obsFocus(target)
  NAV.self = true
  local ok, e = pcall(function()
    if target == "Bottom" then
      local b = obsFirstBtn(); if b then b:SetFocus() end
    else
      local w = OBS.vm:ChangeNaviFocus(FName("Backpack"), 0, "")
      if w and w:IsValid() then w:SetFocus() end
      local g = OBS.grid
      if g and g:IsValid() then local n = g:GetNumItems(); if n > 0 then g:NavigateToIndex(math.min(OBS.bpIdx or 0, n - 1)) end end
    end
  end)
  NAV.self = false
  if not ok then error(e) end
end
local function obsGo(target, why, hold)
  OBS.want, OBS.wantUntil, OBS.tries, OBS.lastTry, OBS.force = target, now() + (hold or 0.3), 0, 0, true
  print(string.format("[GamepadTweaks] observe nav %s -> %s (%s)\n", tostring(OBS.stable), target, why))
end
-- the request comes from the observe VM (opening) or from a sub-module VM (backpack left edge: JHBackpackVMBase),
-- so every request while the 观察 screen is shown counts
OBS_HOOK = function(self, id)
  if not OBS.cfg then return false end                 -- not OBS.open: also the opening request, before taskObs saw it
  local v = OBS.view
  if not (v and v:IsValid() and v:IsVisible()) then return false end
  local key = id:get():ToString()
  if key == "Property" or key == "Equip" then
    id:set(FName("SideBar"))
    OBS.rewrites = OBS.rewrites + 1
    print("[GamepadTweaks] observe nav: game asked for " .. key .. ", ignored\n")
  end
  return true
end
local function taskObs()
  local v = OBS.view
  if not (v and v:IsValid()) then
    if now() < OBS.findAt then return end
    OBS.findAt = now() + 1
    v = nil; for _, x in ipairs(FindAllOf("BPMV_Observe_C") or {}) do if live(x) then v = x end end
    OBS.view, OBS.open = v, false
    if not v then return end
    OBS.cfg = iniNumber("prime_skip_panels", 1) == 1
    if OBS.cfg then navHook() end
  end
  if not v:IsVisible() then if OBS.open then OBS.open = false; maskSet("obs", 0) end return end
  if not OBS.open then
    OBS.open, OBS.stable, OBS.want, OBS.bpIdx, OBS.btn = true, nil, nil, 0, nil
    OBS.cfg = iniNumber("prime_skip_panels", 1) == 1
    if OBS.cfg then navHook() end
    OBS.vm = v:GetNeoUIVM()
    OBS.vn = v:GetFName():ToString()
    OBS.grid, OBS.bpView = nil, nil
    for _, x in ipairs(FindAllOf("BPMV_JHBackpack_Basic_C") or {}) do
      if live(x) and x:IsVisible() then local g = x.GRID_ITEM; if g and g:IsValid() then OBS.grid, OBS.bpView = g, x end end
    end
    if OBS.cfg then local c0 = obsRegion(); obsGo("Bottom", "open, game focused " .. tostring(c0), 1.0) end
  end
  if not OBS.cfg or not (OBS.vm and OBS.vm:IsValid()) then maskSet("obs", 0) return end
  local cur, btn = obsRegion()
  local pad = true; pcall(function() pad = NAV.im and NAV.im:IsValid() and NAV.im:IsGamepadMode() end)
  if not NAV.im then pcall(function() for _, s in ipairs(FindAllOf("NeoUISubsystem") or {}) do if live(s) then NAV.im = s.InputManager end end end) end
  local ev = PADEV
  if ev and MASKS.obs ~= 0 then
    for ch in ev:gmatch("[LR<>%^v]") do
      local base = OBS.want or OBS.stable or cur or "Bottom"
      if ch == "L" or ch == "R" then obsGo(base == "Bottom" and "Backpack" or "Bottom", ch .. "T pad")
      elseif ch == "^" and base == "Bottom" then obsGo("Backpack", "up pad") end
    end
  end
  if pad and not OBS.want and (cur == "Property" or cur == "Equip") then
    obsGo(OBS.stable or "Bottom", "landed on " .. cur)
  end
  if OBS.want then
    if now() > OBS.wantUntil then
      if cur ~= OBS.want then print(string.format("[GamepadTweaks] observe nav: gave up on %s (at %s)\n", OBS.want, tostring(cur))) end
      OBS.want = nil
    elseif (OBS.force or cur ~= OBS.want) and OBS.tries < 20 and now() - OBS.lastTry >= 0.035 then
      OBS.tries, OBS.lastTry, OBS.force = OBS.tries + 1, now(), false
      pcall(obsFocus, OBS.want)
      cur, btn = obsRegion()
    end
  end
  if (cur == "Backpack" or cur == "Bottom") and not OBS.want then
    OBS.stable = cur
    if cur == "Bottom" and btn then OBS.btn = btn end
    if cur == "Backpack" and now() - OBS.memAt > 0.06 then
      OBS.memAt = now()
      pcall(function()
        local g = OBS.grid
        for _, en in ipairs(FindAllOf("BPEntry_Item_WDT_C") or {}) do
          if en:IsValid() and en:IsVisible() and en:HasFocusedDescendants() and en:GetFullName():find(OBS.bpView:GetFName():ToString(), 1, true) then
            local i = g:GetIndexForItem(en:GetBindedDataObj()); if i and i >= 0 then OBS.bpIdx = i end
            break
          end
        end
      end)
    end
  end
  local r = OBS.want or cur
  local m = 0
  if r then m = NAV_BITS.trig; if r == "Bottom" then m = m | NAV_BITS.up end end
  maskSet("obs", m)                   -- also in mouse mode: it only filters gamepad input
end
local function taskPadEv() PADEV = navPadEvents() end

-- ---------------------------------------------------------------- 11) battle speed: x1 -> x2 -> 速战 -> x1
-- The game's speed button only toggles x1 / x2: it sets the persistent level's WorldSettings.TimeDilation to
-- 1.0 / 2.0 (measured 2026-11-23; nothing else changes) and shows BTN_SpeedUp1 (x1 icon) or BTN_SpeedUp2 (x2).
-- 速战 (quick battle): the game's own auto battle (view:EnableAutoBattle) + TimeDilation held at quick_speed
-- (default 500, configurable up to 1000; MaxGlobalTimeDilation raised if needed). The fight is still played out by the game - win or lose -,
-- only compressed: 1v1 sparring took 6-10 s at x2 and 0.6-2.3 s at x20/x50/x100 (9 fights, no stalls).
-- Mouse speed-button hooks and the proxy's single-Y events advance the same cycle, not icon changes:
-- x1 -> x2 -> 速战 -> x1. The game restores its icon during fight startup and cut-ins; that is not a press.
-- Our own icon corrections are guarded so they cannot advance the cycle. Early presses are queued until the
-- battle view is ready. Auto battle is switched off again only if we switched it on. The level is kept for
-- the next fight. Watchdog: real-time quick_timeout (max 30 s) releases effects and restores x1 / our auto change.
-- quick_mask = 1 covers the flickering battle; quick_mute = 1 temporarily mutes only this game's audio session.
-- Both native effects have a 500 ms heartbeat: a Lua restart or stopped loop releases them automatically.
-- Reads only widget visibility and simple values; no struct/slot reads (those crashed UE4SS, 2026-11-23 12:20).
local taskSpeed, spdRecover
do
local function now() return RUNTIME.clock end -- monotonic milliseconds from the native owner receipt
local SPD_Q = 3
local SPD = { view = nil, ws = nil, findAt = 0, active = false, on = nil, level = 1, mem = 1, written = nil,
  overwrites = 0, exports = nil, quick = true, qspeed = 500, qtimeout = 10, qStart = nil, qClock = nil, autoByUs = false, mask = true,
  mute = true, correcting = false, presses = 0, padPresses = 0, hooks = {}, hookAt = 0, maxOrig = nil, over = false, resAt = 0,
  fightKey = nil, pressFight = nil, pc = nil, lostAt = nil, recovered = false }
do                                                                     -- level kept across mod / game restarts
  local m = tonumber((readFirst("speed_level.txt") or ""):match("%d") or "")
  if m and m >= 1 and m <= 3 then SPD.mem = m end
end
local function spdRemember(l) if l ~= SPD.mem then SPD.mem = l; writeFile("speed_level.txt", tostring(l)) end end
do
  local e = {}
  for n = 0, 6 do e[n] = package.loadlib(DLLPATH, "wsmod_speed_" .. n) end
  if e[0] then SPD.exports = e end
  SPD.muteOff = package.loadlib(DLLPATH, "wsmod_mute_0")
  SPD.muteOn = package.loadlib(DLLPATH, "wsmod_mute_1")
  SPD.padOff = package.loadlib(DLLPATH, "wsmod_speed_input_0")
  SPD.padOn = package.loadlib(DLLPATH, "wsmod_speed_input_1")
  print("[GamepadTweaks] speed: gamepad input bridge " .. (SPD.padOn and SPD.padOff and "available" or "missing (old xinput1_3.dll)") .. "\n")
end
local function spdPadInput(on)
  if on then if SPD.padOn then RUNTIME.call(SPD.padOn) end
  elseif SPD.padOff then RUNTIME.call(SPD.padOff) end
end
local function spdBadge(n) if SPD.exports and SPD.exports[n] then SPD.exports[n]() end end
local function spdMute(on)
  if on then if SPD.muteOn then SPD.muteOn() end
  elseif SPD.muteOff then SPD.muteOff() end
end
local function spdGameOn(v)
  local ok, is1 = pcall(function() return v:BtnSpeedUpFlagIs1() end)
  if ok and type(is1) == "boolean" then return not is1 end
  local b1, b2 = v.BTN_SpeedUp1, v.BTN_SpeedUp2
  if not (b1 and b1:IsValid() and b2 and b2:IsValid()) then return nil end
  local v1, v2 = b1:IsVisible(), b2:IsVisible()
  if v1 == v2 then return nil end
  return v2
end
local function spdSetGame(v, on)
  if spdGameOn(v) == on then return end
  SPD.correcting = true
  local ok, err = pcall(function() if on then v:HandleBtn_SpeedUp_1() else v:HandleBtn_SpeedUp_2() end end)
  SPD.correcting = false
  if not ok then error(err) end
  SPD.on = spdGameOn(v)
end
local function spdFightPawn()
  for _, pc in ipairs(FindAllOf("BP_PlayerController_C") or {}) do
    if live(pc) and live(pc.Pawn) then
      local key = pc.Pawn:GetFullName()
      if key:find("BP_FightSpectator", 1, true) then return true, key, pc end
    end
  end
  return false
end
local function spdQueuePress(v)
  if not runtimePoll() or not live(v) then return end
  local fight, key = spdFightPawn(); if not fight or (SPD.over and key == SPD.fightKey) then return end
  local a = v:GetAddress()
  if SPD.pressView ~= a or SPD.pressFight ~= key then SPD.pressView, SPD.pressFight, SPD.presses = a, key, 0 end
  SPD.presses = SPD.presses + 1
end
local function spdInstallHooks()
  if SPD.hooks[1] and SPD.hooks[2] then return end
  if now() < SPD.hookAt then return end
  SPD.hookAt = now() + 1
  for n = 1, 2 do
    if not SPD.hooks[n] then
      local path = "/Script/JH.JHNeoUIBattleModuleView:HandleBtn_SpeedUp_" .. n
      local fn = StaticFindObject(path)
      if fn and fn:IsValid() then
        local ok, err = pcall(function()
          RegisterHook(path, function(self)
            if SPD.correcting then return end
            local good, e = pcall(function()
              spdQueuePress(self:get())
            end)
            if not good then print("[GamepadTweaks] speed: button hook error: " .. tostring(e) .. "\n") end
          end)
        end)
        SPD.hooks[n] = ok
        if ok then print("[GamepadTweaks] speed: button " .. n .. " hook registered\n")
        elseif not SPD.hookError then SPD.hookError = true; print("[GamepadTweaks] speed: hook unavailable: " .. tostring(err) .. "\n") end
      end
    end
  end
end
local function spdFindWS()
  local pc = SPD.pc; if not live(pc) then return nil end
  local lv = pc:GetFullName():match("%.([%w_]+):PersistentLevel"); if not lv then return nil end
  for _, o in ipairs(FindAllOf("WorldSettings") or {}) do
    if live(o) then
      local ok, n = pcall(function() return o:GetOuter():GetOuter():GetFName():ToString() end)
      if ok and n == lv then return o end
    end
  end
  return nil
end
-- the game keeps the auto-battle switch between fights (and across restarts), so "we switched it on" is kept in
-- quick_auto.flag: the next fight that is not 速战 switches it off again
SPD.autoByUs = readFirst("quick_auto.flag") ~= nil
local function spdAutoMark(on)
  if on == SPD.autoByUs then return end
  SPD.autoByUs = on
  if on then writeFile("quick_auto.flag", "1") else os.remove(DIR .. "quick_auto.flag") end
end
local function spdAuto(v, on)
  local ok, isAuto = pcall(function() return v:BtnAutoBattleFlagIsAuto() end)
  if not ok or type(isAuto) ~= "boolean" then return false end
  if on and not isAuto then
    local done = pcall(function() v:EnableAutoBattle() end); if done then spdAutoMark(true) end
  elseif not on and isAuto and SPD.autoByUs then
    pcall(function() v:DisableAutoBattle() end)
  elseif not on then spdAutoMark(false) end
  local read, actual = pcall(function() return v:BtnAutoBattleFlagIsAuto() end)
  if not on and read and actual == false then spdAutoMark(false) end
  return read and actual == on
end
local function spdName(l) return l == SPD_Q and "速战" or ("x" .. l) end
local function spdEnd()
  spdPadInput(false)
  spdMute(false)
  if SPD.active then
    if SPD.view and SPD.view:IsValid() then spdAuto(SPD.view, false) end
    local ws = SPD.ws
    if ws and ws:IsValid() then
      if SPD.written then ws.TimeDilation = 1.0 end
      if SPD.maxOrig then ws.MaxGlobalTimeDilation = SPD.maxOrig end
    end
    local dur = SPD.qStart and (os.time() - SPD.qStart) or nil
    print(string.format("[GamepadTweaks] speed: fight over at %s%s (game re-applied %d times)\n", spdName(SPD.level),
      dur and string.format(", 速战 %d s", dur) or "", SPD.overwrites))
  end
  SPD.active, SPD.view, SPD.ws, SPD.on, SPD.written, SPD.qStart, SPD.maxOrig = false, nil, nil, nil, nil, nil, nil
  SPD.over, SPD.qClock, SPD.seen, SPD.pressView, SPD.presses, SPD.padPresses = false, nil, nil, nil, 0, 0
  SPD.findAt, SPD.fightKey, SPD.pressFight, SPD.pc, SPD.lostAt = 0, nil, nil, nil, nil
  SPD.resultReady, SPD.recovered, SPD.startWait = false, false, nil
  spdBadge(0)
end
-- Always release native effects first. This path must run before any HUD/icon readiness return.
spdRecover = function(reason)
  spdMute(false); spdBadge(0); spdPadInput(false)
  if live(SPD.view) then pcall(spdAuto, SPD.view, false) end
  local ws = SPD.ws
  if live(ws) then
    pcall(function()
      ws.TimeDilation = 1.0
      if SPD.maxOrig then ws.MaxGlobalTimeDilation = SPD.maxOrig end
    end)
  end
  SPD.level, SPD.qStart, SPD.qClock, SPD.maxOrig, SPD.written = 1, nil, nil, nil, nil
  SPD.presses, SPD.padPresses, SPD.recovered = 0, 0, true
  spdRemember(1)
  print("[GamepadTweaks] speed: recovery -> x1/manual (" .. reason .. ")\n")
end
-- result screen up: the fight is decided, stop holding the speed (the screen's own animations run normally)
local function spdResult()
  for _, cn in ipairs({ "BPMV_BattleWinMaster_C", "BPMV_BattleFailure_C" }) do
    for _, o in ipairs(FindAllOf(cn) or {}) do if live(o) and o:IsVisible() then return cn end end
  end
  return nil
end
taskSpeed = function()
  spdInstallHooks()
  local fight, key, pc = spdFightPawn()
  local pad = RUNTIME.events; RUNTIME.events = 0
  -- A new spectator is a new fight even if the 300 ms poll never saw the field between fights.
  if fight and key ~= SPD.fightKey then
    local pending, pv = SPD.pressFight == key and SPD.presses or 0, SPD.pressView
    spdEnd()
    SPD.fightKey, SPD.pc, SPD.startWait = key, pc, now()
    SPD.presses, SPD.pressView, SPD.pressFight = pending, pv, key
  end
  if fight then
    inFight, SPD.lostAt = true, nil
    if not SPD.over then SPD.padPresses = SPD.padPresses + pad end
  else
    SPD.lostAt = SPD.lostAt or now()
    if now() - SPD.lostAt >= 0.5 then spdEnd(); return end
  end
  if SPD.over then
    spdPadInput(false)
    -- Some battles reuse the spectator: a closed result followed by a visible HUD starts a new cycle.
    if not spdResult() and live(SPD.view) and SPD.view:IsVisible() then
      local keepKey, keepPC = SPD.fightKey, SPD.pc
      spdEnd(); SPD.fightKey, SPD.pc, SPD.startWait = keepKey, keepPC, now()
    end
    return
  end
  -- Wall time and exception recovery cannot be blocked by a hidden/destroyed HUD or unreadable icons.
  if SPD.qClock and now() - SPD.qClock >= SPD.qtimeout then spdRecover("quick timeout") end
  if not SPD.active and SPD.startWait and now() - SPD.startWait >= 5 and not SPD.recovered then
    spdRecover("HUD not ready")
  end
  spdPadInput(fight and not SPD.recovered)
  -- the battle HUD is hidden during skill cut-ins: keep the view once found and keep holding the speed meanwhile
  -- (v4.15 first build dropped the view while hidden, so the game ran those cut-ins at x1)
  -- several BPMV_JHBattleModule_C instances can exist (the last fight's one lingers): switch to a visible one
  -- whenever ours is hidden, keep ours only while none is visible (cut-in)
  local v = SPD.view
  if not (v and v:IsValid() and v:IsVisible()) then
    if now() >= SPD.findAt or not (v and v:IsValid()) then
      SPD.findAt = now() + 0.25
      local vis = nil
      for _, x in ipairs(FindAllOf("BPMV_JHBattleModule_C") or {}) do if live(x) and x:IsVisible() then vis = x end end
      if vis then SPD.view = vis elseif not (v and v:IsValid()) then SPD.view = nil end
      v = SPD.view
    end
    if not v then return end
  end
  local ws = SPD.ws
  if not (ws and ws:IsValid()) then ws = spdFindWS(); SPD.ws = ws; if not ws then return end end
  if now() - SPD.resAt > 0.1 then
    SPD.resAt = now()
    local r = spdResult()
    if not r then SPD.resultReady = true end
    if r and SPD.resultReady and SPD.active then
      SPD.over, SPD.presses, SPD.padPresses = true, 0, 0
      spdPadInput(false)
      spdMute(false)
      spdAuto(v, false)
      ws.TimeDilation = 1.0
      if SPD.maxOrig then ws.MaxGlobalTimeDilation = SPD.maxOrig; SPD.maxOrig = nil end
      SPD.written = nil
      if SPD.qClock then print(string.format("[GamepadTweaks] speed: 速战 decided in %.1f s (%s, game re-applied %d times)\n", now() - SPD.qClock, r:gsub("BPMV_", ""):gsub("_C$", ""), SPD.overwrites)) end
      spdBadge(0)
      return
    end
  end
  local hudUp = v:IsVisible()
  local on = spdGameOn(v)                                           -- the game's flag also works during cut-ins
  if on == nil then on = SPD.on end
  if on == nil then
    if not SPD.active and now() - (SPD.dbgAt or 0) > 2 then
      SPD.dbgAt = now()
      local b1, b2 = "?", "?"
      pcall(function() b1 = tostring(v.BTN_SpeedUp1:IsVisible()); b2 = tostring(v.BTN_SpeedUp2:IsVisible()) end)
      print(string.format("[GamepadTweaks] speed: waiting for the speed icons (hud %s, x1 %s, x2 %s)\n", tostring(hudUp), b1, b2))
    end
    return
  end
  if not SPD.active then
    if not hudUp then return end
    SPD.seen = SPD.seen or now()
    if SPD.presses == 0 and SPD.padPresses == 0 and now() - SPD.seen < 0.3 then return end    -- pending presses never get discarded
    SPD.active, SPD.on, SPD.overwrites, SPD.recovered = true, on, 0, false
    SPD.quick = iniNumber("quick_battle", 1) == 1
    SPD.qspeed = math.max(3, math.min(1000, iniNumber("quick_speed", 500)))
    SPD.qtimeout = math.max(5, math.min(30, iniNumber("quick_timeout", 10)))
    SPD.mask = iniNumber("quick_mask", 1) == 1 and SPD.exports ~= nil and SPD.exports[6] ~= nil
    SPD.mute = iniNumber("quick_mute", 1) == 1
    local m = SPD.mem
    if m == SPD_Q and not SPD.quick then m = 1 end
    -- 速战 is kept whatever the game's own switch says (v4.15-4.19 dropped it when the game started at x2, e.g.
    -- after a fight left at x2: "fight start, game x2, level x2"); x1 / x2 follow the game's switch
    if m == SPD_Q or SPD.presses > 0 or SPD.padPresses > 0 then SPD.level = m
    else SPD.level = on and 2 or 1 end
    if SPD.level ~= SPD_Q and SPD.autoByUs then spdAuto(v, false) end
    print(string.format("[GamepadTweaks] speed: fight start, game %s, level %s\n", on and "x2" or "x1", spdName(SPD.level)))
  end
  local presses = SPD.presses
  SPD.presses = 0
  if SPD.pressView and SPD.pressView ~= v:GetAddress() then presses = 0 end
  presses = presses + SPD.padPresses
  SPD.padPresses = 0
  if presses > 0 then SPD.recovered = false end                       -- an explicit new press may retry after recovery
  for _ = 1, presses do
    local nxt
    if SPD.level == 1 then nxt = 2
    elseif SPD.level == 2 then nxt = SPD.quick and SPD_Q or 1
    else nxt = 1 end
    SPD.level = nxt; spdRemember(nxt)
    print(string.format("[GamepadTweaks] speed: button -> %s\n", spdName(nxt)))
  end
  -- Icon refreshes are not user input. Keep the game's persistent flag in sync with our chosen level.
  -- 速战 uses the game's x1 flag; its actual TimeDilation is held separately below.
  local lvl = SPD.level
  spdSetGame(v, lvl == 2)
  SPD.on = spdGameOn(v)
  local autoReady = false
  if lvl == SPD_Q then
    if not SPD.qStart then SPD.qStart, SPD.qClock = os.time(), now() end
    autoReady = spdAuto(v, true)                                      -- never accelerate a still-manual fight
    spdMute(autoReady and SPD.mute)
    if autoReady then
      SPD.maxOrig = SPD.maxOrig or ws.MaxGlobalTimeDilation
      if ws.MaxGlobalTimeDilation < SPD.qspeed then ws.MaxGlobalTimeDilation = SPD.qspeed end
    end
  else
    spdMute(false)
    if SPD.qStart then
      SPD.qStart, SPD.qClock = nil, nil
      spdAuto(v, false)
      if SPD.maxOrig then ws.MaxGlobalTimeDilation = SPD.maxOrig; SPD.maxOrig = nil end
    end
  end
  local want = (lvl == SPD_Q) and (autoReady and SPD.qspeed or 1) or lvl
  if math.abs(ws.TimeDilation - want) > 0.01 then
    if SPD.written then SPD.overwrites = SPD.overwrites + 1 end
    ws.TimeDilation = want
  end
  SPD.written = want
  if lvl == SPD_Q and autoReady and SPD.mask then spdBadge(6)           -- maintained even during cut-ins
  elseif lvl == SPD_Q and autoReady and hudUp then spdBadge(5)
  else spdBadge(0) end
end

end -- speed scope

-- ---------------------------------------------------------------- scheduler (20 ms tick)
-- base tick 20 ms (one game-thread loop for everything; "every" is in ticks)
local tasks = {
  { every = 25,  fn = taskCursor },
  { every = 3,   fn = taskMapFlag },
  { every = 100, fn = taskVisited },
  { every = 15,  fn = taskTeleport },
  { every = 15,  fn = taskArrival },
  { every = 50,  fn = taskCmd },
  { every = 10,  fn = taskScan },
  { every = 150, fn = taskInteract },
  { every = 15,  fn = taskBattle },
  { every = 10,  fn = taskBackpack },
  { every = 1,   fn = taskHide },
  { every = 1,   fn = taskPadEv },
  { every = 1,   fn = taskStart },
  { every = 1,   fn = taskNav },
  { every = 1,   fn = taskObs },
  { every = 1,   fn = taskSpeed },
  { every = 50,  fn = taskAutoSave },
  { every = 1,   fn = taskWalkAppearance },
  { every = 5,   fn = taskGift },
}
local tick = 0
local errCount = {}
os.remove(DIR .. "teleport.req") -- do not replay requests from an earlier session
writeFile("map.flag", "0")
writeFile("battle.flag", "0")
writeFile("fight.flag", "0")
writeFile("prime.flag", "0"); os.remove(DIR .. "trig.req")
LoopInGameThreadWithDelay(20, function()
  if not runtimePoll() then return end
  if tick == 0 then print("[GamepadTweaks] scheduler: owner tick active\n") end
  tick = tick + 1
  for i, t in ipairs(tasks) do
    if tick % t.every == 0 then
      local ok, err = pcall(t.fn)
      if not ok then
        if t.fn == taskSpeed then pcall(spdRecover, "speed task error: " .. tostring(err)) end
        errCount[i] = (errCount[i] or 0) + 1
        if errCount[i] <= 3 then print("[GamepadTweaks] task " .. i .. " error: " .. tostring(err) .. "\n") end
      end
    end
  end
end)
