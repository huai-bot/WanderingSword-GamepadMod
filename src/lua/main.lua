print("[GamepadTweaks] v4.39 loaded\n")
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
  print("[GamepadTweaks] runtime unavailable; install matching v4.31 DLL and Lua together\n")
  return
end
local nativeRegisterHook = RegisterHook
local function RegisterHook(path, before, after)
  local function owned(fn)
    if not fn then return nil end
    return function(...) if RUNTIME.owner and RUNTIME.playing and not RUNTIME.loading then return fn(...) end end
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

function RUNTIME.world()
  if RUNTIME.loading then return end
  if not live(RUNTIME.viewport) then
    local engine = FindFirstOf("GameEngine")
    if not live(engine) then return end
    RUNTIME.viewport = engine.GameViewport
  end
  local viewport = RUNTIME.viewport
  if not live(viewport) then return end
  local world = viewport.World
  if not live(world) or world:GetFName():ToString() == "LV_NewGame" then return end
  local instance = viewport.GameInstance
  if live(instance) then return world, instance end
end
function RUNTIME.player()
  local world, instance = RUNTIME.world()
  if not world then return end
  local level, players = world.PersistentLevel, instance.LocalPlayers
  if not live(level) then return end
  if not players or #players == 0 then return nil, nil, world, instance, level end
  local player = players[1]
  local controller = live(player) and player.PlayerController
  if not live(controller) or controller:IsActorBeingDestroyed() then return nil, nil, world, instance, level end
  local outer = controller:GetOuter()
  if not live(outer) or outer:GetAddress() ~= level:GetAddress() then return nil, nil, world, instance, level end
  local pawn = controller.Pawn
  if not live(pawn) or pawn:IsActorBeingDestroyed() then return nil, nil, world, instance, level end
  local owner, pawnLevel = pawn.Controller, pawn:GetOuter()
  if not live(owner) or owner:GetAddress() ~= controller:GetAddress() or not live(pawnLevel)
    or pawnLevel:GetAddress() ~= level:GetAddress() then return nil, nil, world, instance, level end
  return controller, pawn, world, instance, level
end

-- returns pc, pawn, level, pawnFullName when the world is stable; otherwise nil
local function stableWorld()
  if now() < pauseUntil then return nil end
  local pc, pawn, world = RUNTIME.player()
  if not pc then return end
  local full = pawn:GetFullName()
  local lv = world:GetFName():ToString()
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
local function taskMapFlag(intent)
  local view
  -- UI visibility is not world readiness. It is safe to inspect widgets during
  -- the post-travel cooldown; taskTeleport still requires a stable field pawn.
  if not inFight then
    local memo = {}
    for _, w in ipairs(FindAllOf("JHNeoUIWorldMapViewBase") or {}) do
      if live(w) then
        local ok, shown = pcall(shownChain, w, memo, 0)
        if ok and shown then view = w; break end
      end
    end
  end
  local v = view and "1" or "0"
  if v ~= lastMap and writeFile("map.flag", v) then lastMap = v; writeBattleFlag() end
  if intent and not inFight then
    if intent == "m" and view then
      local vm = view:GetNeoUIVM()
      if live(vm) then vm:Hide() end
    elseif intent == "M" and not view then
      local pc, _, _, full = stableWorld()
      if pc and (full:find("BP_SceneHero", 1, true) or full:find("BP_WorldHero", 1, true)) then
        pc:HandleOpenWorldMap()
      end
    end
  end
end

local visited = {}
do
  local s = readFirst("visited.txt")
  if s then for line in s:gmatch("[^\n]+") do
    local lv = line:match("^([%w_]+)|") or line:match("^([%w_]+)%s*$")
    if lv then visited[lv] = line:gsub("\r$", "") end
  end end
end
local function saveVisited()
  local t = {} for _, line in pairs(visited) do t[#t + 1] = line end table.sort(t)
  writeFile("visited.txt", table.concat(t, "\n") .. "\n")
end
local arrival
local ground = { lv = nil, since = 0 }
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
  if not visited[lv] then
    local pos = pawn:K2_GetActorLocation()
    visited[lv] = string.format("%s|%.0f|%.0f|%.0f", lv, pos.X, pos.Y, pos.Z); saveVisited()
    print("[GamepadTweaks] visited " .. lv .. "\n")
  end
end

local TRAVEL = { anchors = {}, hosts = {} }
do
  for _, id in ipairs({10015,10102,10132,10220,11600,11900,12000,12105,13108,13208,16041,16401,17002,17038,19109,19300,19500,19835}) do TRAVEL.hosts[id] = true end
  local function vector(text)
    local x, y, z = text:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
    if x then return {X=tonumber(x),Y=tonumber(y),Z=tonumber(z)} end
  end
  for line in (readFirst("landings.txt") or ""):gmatch("[^\r\n]+") do
    local level, entry, kind, door, keeper = line:match("^([%w_]+)\t([^\t]+)\t(%l+)\t([^\t]+)\t([^\t]+)$")
    if level and vector(entry) then
      local id, home = keeper:match("^(%d+),(.+)$")
      TRAVEL.anchors[level] = {entry=vector(entry), kind=kind, door=vector(door), keeper=tonumber(id), home=home and vector(home)}
      if id then TRAVEL.hosts[tonumber(id)] = true end
    end
  end
end
function TRAVEL.distance(first, second)
  return (first.X-second.X)^2 + (first.Y-second.Y)^2
end
function TRAVEL.place(pawn, target)
  local capsule, movement = pawn.CapsuleComponent, pawn.CharacterMovement
  if not live(capsule) or not live(movement) then return end
  local nav = StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1")
  if not nav or not nav:IsValid() then return end
  local function project(point, width, height)
    local out = {}
    if nav:K2_ProjectPointToNavigation(pawn, point, out, nil, nil, {X=width,Y=width,Z=height})
      and out.X and TRAVEL.distance(point, out) <= width^2 and math.abs(out.Z-point.Z) <= height then return out end
  end
  local base = project(target, 48, 128); if not base then return end
  local walkout = false
  for _, direction in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
    local exit = project({X=base.X+direction[1]*140,Y=base.Y+direction[2]*140,Z=base.Z}, 36, 90)
    if exit then
      local path = nav:FindPathToLocationSynchronously(pawn, base, exit, pawn, nil)
      if live(path) and not path:IsPartial() and #path.PathPoints >= 2 then walkout = true; break end
    end
  end
  if not walkout then return end
  local spot = {X=base.X,Y=base.Y,Z=base.Z+capsule:GetScaledCapsuleHalfHeight()+8}
  local floor = {}; movement:K2_FindFloor(spot, floor)
  if not floor.bWalkableFloor then return end
  local gap = floor.bLineTrace and floor.LineDist or floor.FloorDist
  if not gap or gap < -2 or gap > 48 then return end
  spot.Z = spot.Z - gap + 2
  local before = pawn:K2_GetActorLocation()
  if onGround(pawn) and TRAVEL.distance(before, spot) < 12^2 and math.abs(before.Z-spot.Z) < 16 then return spot end
  if pawn:K2_TeleportTo(spot, pawn:K2_GetActorRotation()) then
    movement:StopMovementImmediately()
    local landed = pawn:K2_GetActorLocation()
    if TRAVEL.distance(landed, spot) <= 48^2 and math.abs(landed.Z-spot.Z) <= 48 then return spot end
    pawn:K2_TeleportTo(before, pawn:K2_GetActorRotation())
  end
end
function TRAVEL.host(pawn, anchor)
  local library = StaticFindObject("/Script/Engine.Default__GameplayStatics")
  local class = StaticFindObject("/Game/JH/Core/Characters/BP_SceneNPC.BP_SceneNPC_C")
  if not library or not library:IsValid() or not class or not class:IsValid() then return end
  local actors = {}; library:GetAllActorsOfClass(pawn, class, actors)
  local pick, best, bestId
  for _, actor in ipairs(actors) do
    if type(actor) == "userdata" and not actor.IsValid and actor.get then actor = actor:get() end
    if live(actor) and not actor:IsActorBeingDestroyed() and not actor.bHidden and TRAVEL.hosts[actor.NPCId] then
      local id = tonumber(actor.NPCId)
      local pos = actor:K2_GetActorLocation()
      local distance = TRAVEL.distance(pos, anchor.home or anchor.entry)
      if id == anchor.keeper then distance = distance - 1e12 end
      if not pick or distance < best or distance == best and id < bestId then pick, best, bestId = actor, distance, id end
    end
  end
  if not pick then return end
  local pos, sprite = pick:K2_GetActorLocation(), pick.Sprite
  local offset = live(sprite) and ({[0]=-90,0,90,180})[tonumber(sprite.FlipbookDirect)]
  local camera = pawn.Controller.PlayerCameraManager
  if not offset or not live(camera) then return end
  local angle = math.rad(camera:GetCameraRotation().Yaw + offset)
  return {X=pos.X+math.cos(angle)*96,Y=pos.Y+math.sin(angle)*96,Z=pos.Z}
end
local function changeMap(pc, lv, x, y, z)
  local cdo = StaticFindObject("/Script/JH.Default__AsyncTaskChangeSceneMap")
  return cdo:ChangeSceneMap(pc, FName(lv), { X = x, Y = y, Z = z }, 0, true, true, true, true, false)
end
local pendingTravel, travelSerial = nil, 0
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
  local lv = req.line:match("^([%w_]+)%s*$") or req.line:match("^([%w_]+)|")
  local anchor = lv and visited[lv] and TRAVEL.anchors[lv]
  if not anchor or not (full:find("BP_SceneHero",1,true) or full:find("BP_WorldHero",1,true)) then return end
  local ui = getUI()
  local blocked = inFight
  if ui then
    pcall(function() if ui:ShouldDisableInput() then blocked = true end end)
    pcall(function() local d = ui:GetDialogView(); if d and d:IsValid() and d:IsVisible() then blocked = true end end)
  end
  if blocked then print("[GamepadTweaks] teleport skipped: battle/dialog\n") return end
  local _, _, world = RUNTIME.player(); if not world then return end
  local source = cur ~= lv and world:GetAddress()
  if ui and ui:IsValid() then pcall(function() ui:GotoDefaultStatus() end) end
  travelSerial = travelSerial + 1
  arrival = {lv=lv, anchor=anchor, at=now(), retry=0, source=source}
  if source then
    local pos = anchor.entry
    pauseUntil = now() + 12
    changeMap(pc, lv, pos.X, pos.Y, pos.Z)
  end
  print(string.format("[GamepadTweaks] teleport -> %s (fixed %s)\n", lv, anchor.kind))
end
local function taskArrival()
  local a = arrival; if not a then return end
  local clock = now()
  if clock-a.at > 35 or inFight then arrival = nil; return end
  local _, pawn, world = RUNTIME.player()
  if world and world:GetAddress() ~= a.source and world:GetFName():ToString() ~= a.lv then arrival = nil; return end
  if not pawn or world:GetFName():ToString() ~= a.lv or world:GetAddress() == a.source
    or not pawn:GetClass():GetFName():ToString():find("BP_SceneHero",1,true) then
    if a.ready then arrival = nil end; return
  end
  if clock < a.retry then return end
  a.retry = clock + 0.35
  local pos = pawn:K2_GetActorLocation()
  a.ready = a.ready or clock
  if a.placed then
    if onGround(pawn) and math.abs(pos.Z-a.placed.Z) < 100 then arrival = nil; return end
    if clock-a.placedAt < 1.2 then return end
    a.forceEntry = true
  end
  if a.rest and not a.placed and TRAVEL.distance(pos,a.rest) > 96^2 then arrival = nil; return end
  if not a.rest and onGround(pawn) then a.rest = {X=pos.X,Y=pos.Y} end
  local anchor, spot = a.anchor
  if not a.forceEntry and anchor.door then spot = TRAVEL.place(pawn,anchor.door) end
  if not spot and not a.forceEntry and anchor.kind ~= "entry" then
    local host = TRAVEL.host(pawn,anchor)
    if host then spot = TRAVEL.place(pawn,host) end
    if not spot and clock-a.ready < 1.5 then return end
  end
  if not spot then spot = TRAVEL.place(pawn,anchor.entry) end
  if spot then a.placed, a.placedAt = spot, clock
  elseif clock-a.ready > 5 then arrival = nil; print("[GamepadTweaks] arrival: no validated relocation in " .. a.lv .. "\n") end
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
local WALK = { on = false, pawn = nil, originals = {}, findAt = 0, cfgAt = 0, cfg = false,
  rebuildAt = 0, followerCount = nil, bridge = package.loadlib(DLLPATH, "wsmod_walk_rebuild"), warned = false }
function WALK.field()
  local _, pawn, world, instance, level = RUNTIME.player()
  if not pawn then return end
  local class = pawn:GetClass():GetFName():ToString()
  if inFight or class:find("BP_FightSpectator", 1, true) then WALK.afterFight = true; return end
  if not (class:find("BP_SceneHero", 1, true) or class:find("BP_WorldHero", 1, true)) or not live(pawn.RootComponent) then return end
  local name = world:GetFName():ToString()
  if arrival and name ~= arrival.lv then return end
  return pawn, name, instance, level:GetAddress()
end
function WALK.asset(path)
  if not path or path == "None" then return nil end
  local asset = StaticFindObject(path)
  if not asset or not asset:IsValid() then LoadAsset(path); asset = StaticFindObject(path) end
  if asset and asset:IsValid() then return asset end
end
function WALK.feet(pawn, instance)
  local id = tonumber(pawn.NPCId) or 0
  if id < 20 and id ~= 2 then id = 0 end
  if WALK.npc ~= id or not live(WALK.info) then
    WALK.npc, WALK.info = id, nil
    for _, mgr in ipairs(FindAllOf("NPCManager") or {}) do
      if live(mgr) then
        local outer = mgr:GetOuter()
        if live(outer) and outer:GetAddress() == instance:GetAddress() then
          WALK.info = mgr:GetNPCInfo(id, false); if live(WALK.info) then break end
        end
      end
    end
  end
  if not live(WALK.info) then return end
  local name = WALK.info.AvatarResourceName:ToString()
  if name == "None" or name == "" then
    local defs = StaticFindObject("/Game/JH/Tables/NPCs.NPCs")
    local def = live(defs) and defs:FindRow(tostring(id))
    if not def then return end
    name = def.ResourceName:ToString()
  end
  if WALK.skin == name and WALK.ground then return WALK.ground end
  if WALK.lookup == name and now() < WALK.retryAt then return end
  WALK.lookup, WALK.retryAt = name, now() + 0.15
  local resources = StaticFindObject("/Game/JH/Tables/NPCResources.NPCResources")
  local row = live(resources) and resources:FindRow(name)
  if not row then return end
  local ground = { Idle = {}, Run = {} }
  for _, group in ipairs({"Idle", "Run"}) do
    for index, facing in ipairs({"Left", "Up", "Right", "Down"}) do
      local ref = row[group .. facing .. "Flipbook"]
      local path = ref:GetObjectID():GetAssetPathName():ToString()
      local asset = WALK.asset(path)
      if not asset then return end
      ground[group][index] = asset
    end
  end
  WALK.skin, WALK.ground = name, ground
  print("[GamepadTweaks] walking: loaded four ground facings for " .. name .. "\n")
  return ground
end
function WALK.park(sprite, saved, enabled)
  local hold = saved.hold
  if not hold then return end
  if not enabled then
    for index, entry in pairs(hold.slots) do
      local idle = sprite.IdleFlipbooks
      local current = index <= #idle and idle[index]
      if current and current:IsValid() and current:GetAddress() == entry.applied then
        local original = entry.asset:IsValid() and entry.asset or WALK.asset(entry.path)
        if original then idle[index] = original end
      end
    end
    if sprite.DefaultRunAnimalState == 0 then sprite.DefaultRunAnimalState = hold.run end
    saved.hold = nil
    return
  end
  local idle = sprite.IdleFlipbooks
  local clip = hold.facing + 1 <= #idle and idle[hold.facing + 1]
  if not clip or not clip:IsValid() then return end
  local address = clip:GetAddress()
  for index = 1, math.min(4, #idle) do
    local current = idle[index]
    if current and current:IsValid() and current:GetAddress() ~= address then
      local entry = hold.slots[index]
      if not entry or current:GetAddress() ~= entry.applied then
        entry = {asset = current, path = current:GetFullName():match("^%S+ (.+)$")}; hold.slots[index] = entry
      end
      idle[index], entry.applied = clip, address
    end
  end
  if sprite.DefaultRunAnimalState ~= 0 then hold.run = sprite.DefaultRunAnimalState; sprite.DefaultRunAnimalState = 0 end
  if sprite.AnimalState ~= 0 then sprite.AnimalState = 0 end
  local current = sprite:GetFlipbook()
  if not current or not current:IsValid() or current:GetAddress() ~= address then sprite:SetFlipbook(clip) end
end
function WALK.rest(actor, sprite, saved, clock)
  local state = sprite.AnimalState
  if saved.hero or sprite.bShipType or (state ~= 0 and state ~= 2 and state ~= 9) then
    WALK.park(sprite, saved, false); saved.anchor = nil; return
  end
  local point = actor:K2_GetActorLocation()
  local anchor = saved.anchor
  if not anchor or (point.X - anchor.X)^2 + (point.Y - anchor.Y)^2 > 3^2 or math.abs(point.Z - anchor.Z) > 6 then
    WALK.park(sprite, saved, false)
    saved.anchor = {X = point.X, Y = point.Y, Z = point.Z, since = clock}
  elseif clock - anchor.since >= 0.25 then
    local facing = sprite.FlipbookDirect
    if facing >= 0 and facing < 4 then
      saved.hold = saved.hold or {facing = facing, run = sprite.DefaultRunAnimalState, slots = {}}
      WALK.park(sprite, saved, true)
    end
  end
end
function WALK.slots(sprite, saved, ground, restoring)
  if restoring then WALK.park(sprite, saved, false) end
  local idle, run, fast = sprite.IdleFlipbooks, sprite.RunFlipbooks, sprite.FastRunFlipbooks
  local changed = false
  local function bind(slots, index, originals, source, desired)
    if index > #slots then return end
    local current = slots[index]
    if not current or not current:IsValid() then return end
    local address, previous = current:GetAddress(), originals[index]
    local ours = previous and address == previous.applied and source == previous.source
    if restoring then
      if not ours then return end
      desired = previous.asset
      if not desired:IsValid() then desired = WALK.asset(previous.path) end
    elseif desired and desired:IsValid() then
      if address == desired:GetAddress() then
        if not ours then originals[index] = nil end
        return
      end
      if not ours then
        previous = {asset = current, before = address, path = current:GetFullName():match("^%S+ (.+)$")}; originals[index] = previous
      end
      previous.applied, previous.source = desired:GetAddress(), source
    else
      if ground then WALK.ground = nil end
      return
    end
    if desired then slots[index] = desired; changed = true end
  end
  for index = 1, 4 do
    local witness = index <= #fast and fast[index]
    local source = witness and witness:IsValid() and witness:GetAddress() or 0
    local previous = saved.FastRun[index]
    if previous and previous.applied == source then source = previous.source end
    if saved.hero then
      bind(idle, index, saved.Idle, source, ground and ground.Idle[index])
      bind(run, index, saved.Run, source, ground and ground.Run[index])
    end
    local foot = ground and ground.Run[index] or (not saved.hero and index <= #run and run[index])
    bind(fast, index, saved.FastRun, source, foot)
  end
  if sprite.bShipType then return end
  local state = sprite.AnimalState
  local active = state == 0 and idle or state == 2 and run or state == 9 and fast
  if not active then return end
  local facing = sprite.FlipbookDirect + 1
  if facing < 1 or facing > 4 or facing > #active then return end
  local clip = active[facing]
  if not clip or not clip:IsValid() then return end
  local current = sprite:GetFlipbook()
  local displayed = current and current:IsValid() and current:GetAddress()
  local original = (state == 0 and saved.Idle or state == 2 and saved.Run or saved.FastRun)[facing]
  if displayed ~= clip:GetAddress() and (changed or not displayed or original and displayed == original.before) then sprite:SetFlipbook(clip) end
  if not restoring and saved.hero and (state == 2 or state == 9) and ground and ground.Run[facing]:IsValid()
    and clip:GetAddress() == ground.Run[facing]:GetAddress() and not sprite:IsPlaying() then sprite:SetLooping(true); sprite:Play() end
end
function WALK.formation(pawn, level, members, clock)
  local position = pawn:K2_GetActorLocation()
  local function distance(first, second) return (first.X - second.X)^2 + (first.Y - second.Y)^2 end
  local team = WALK.team
  if not team or team.level ~= level or team.trip ~= travelSerial or distance(team.origin, position) > 320^2
    or math.abs(team.origin.Z - position.Z) > 160 then
    team = {level = level, trip = travelSerial, offsets = {}, seen = {}}; WALK.team = team
  end
  team.origin = {X = position.X, Y = position.Y, Z = position.Z}
  if WALK.afterFight then team.seen = {}; WALK.afterFight = false end
  local occupied, current, crowded = {team.origin}, {}, {}
  local function free(point)
    for _, other in ipairs(occupied) do if distance(point, other) < 36^2 then return false end end
    return true
  end
  for index, actor in ipairs(members) do
    local name = actor:GetFName():ToString()
    local key = tonumber(actor.NPCId) or name
    local state = team.seen[name] or {untilAt = clock + 1.5, retry = 0}
    current[name] = state
    local point = actor:K2_GetActorLocation()
    if free(point) then
      occupied[#occupied + 1] = point
      if distance(position, point) <= 700^2 and math.abs(point.Z - position.Z) < 150 then
        team.offsets[key] = {X = point.X - position.X, Y = point.Y - position.Y, Z = point.Z - position.Z}
      end
    elseif clock <= state.untilAt and clock >= state.retry then
      state.retry = clock + 0.2
      crowded[#crowded + 1] = {index = index, actor = actor, offset = team.offsets[key], state = state}
    end
  end
  team.seen = current
  if #crowded == 0 then return end
  local forward, movement = pawn:GetActorForwardVector(), pawn.CharacterMovement
  local capsule = pawn.CapsuleComponent
  if not live(capsule) then return end
  local heroHeight = capsule:GetScaledCapsuleHalfHeight()
  local function place(actor, offset)
    local followerCapsule = actor.CapsuleComponent
    if not live(followerCapsule) then return false end
    local point = {X = position.X + offset.X, Y = position.Y + offset.Y, Z = position.Z + offset.Z}
    if not free(point) then return false end
    local floor = {}; movement:K2_FindFloor(point, floor)
    if not floor.bWalkableFloor then return false end
    point.Z = point.Z - (floor.bLineTrace and floor.LineDist or floor.FloorDist) + 2
      + followerCapsule:GetScaledCapsuleHalfHeight() - heroHeight
    if not actor:K2_TeleportTo(point, actor:K2_GetActorRotation()) then return false end
    local landed = actor:K2_GetActorLocation()
    if not free(landed) then return false end
    occupied[#occupied + 1] = landed
    return true
  end
  for _, member in ipairs(crowded) do
    local placed = member.offset and place(member.actor, member.offset)
    if not placed then
      local back = 64 * member.index
      for attempt, side in ipairs({0, 64, -64, back, -back}) do
        local along = attempt <= 3 and back or 0
        placed = place(member.actor, {X = -along * forward.X - side * forward.Y, Y = -along * forward.Y + side * forward.X, Z = 0})
        if placed then break end
      end
    end
    if placed then member.state.untilAt = -1 end
  end
end
local function taskWalkAppearance()
  local clock = RUNTIME.clock or now()
  if clock >= WALK.cfgAt then WALK.cfg, WALK.cfgAt = iniNumber("walk_appearance", 0) == 1, clock + 1 end
  if (not WALK.cfg and not WALK.on) or clock < WALK.findAt then return end
  WALK.findAt = clock + 0.08
  local pawn, lv, instance, level = WALK.field(); if not pawn then return end
  if WALK.pawn ~= pawn:GetAddress() or WALK.level ~= level then
    WALK.pawn, WALK.level, WALK.originals, WALK.on, WALK.followerCount, WALK.rebuildAt = pawn:GetAddress(), level, {}, false, nil, 0
    WALK.info, WALK.skin, WALK.ground, WALK.lookup = nil, nil, nil, nil
  end
  if not WALK.cfg then
    if WALK.on and onGround(pawn) then
      WALK.on = false
      for _, original in pairs(WALK.originals) do
        if live(original.sprite) then WALK.slots(original.sprite, original, nil, true) end
      end
      if WALK.followerCount then pawn.FollowerCount = WALK.followerCount end
      pawn:DestroyFollowers(); pawn:RebuidFollowers()
      WALK.originals, WALK.ground, WALK.team, WALK.afterFight = {}, nil, nil, false
      print("[GamepadTweaks] walking appearance: off (native display restored)\n")
    end
    return
  end
  if not WALK.on then
    WALK.on, WALK.followerCount = true, tonumber(pawn.FollowerCount)
    if WALK.followerCount then pawn.FollowerCount = math.max(5, WALK.followerCount) end
    print("[GamepadTweaks] walking appearance: on (speed/effects unchanged)\n")
  end
  do
    local cls = StaticFindObject("/Script/JH.JHPaperFlipbookComponent")
    if not cls or not cls:IsValid() then return end
    local heroSprites, present, land = 0, {}, false
    local function add(actor, hero)
      if not live(actor) then return end
      eachArr(actor:K2_GetComponentsByClass(cls), function(i, sprite)
        if not live(sprite) then return end
        local address = sprite:GetAddress()
        local known = WALK.originals[address]
        if not known or not live(known.sprite) then known = {sprite = sprite, hero = hero, Idle = {}, Run = {}, FastRun = {}} end
        present[address] = known
        if hero then heroSprites = heroSprites + 1 end
        if sprite.bShipType then WALK.park(sprite, known, false); known.anchor = nil; return end
        local ground = hero and WALK.feet(pawn, instance)
        if hero and ground then land = true end
        if not hero or ground then WALK.slots(sprite, known, ground, false) end
        if not hero then WALK.rest(actor, sprite, known, clock) end
      end)
    end
    add(pawn, true)
    local grounded = land and onGround(pawn)
    local members = {}
    local function collect(_, actor)
      if live(actor) and not actor:IsActorBeingDestroyed() then members[#members + 1] = actor end
    end
    eachArr(pawn.FollowCharacters, collect)
    if #members == 0 and grounded and (clock >= WALK.rebuildAt or WALK.afterFight) then
      WALK.rebuildAt = clock + 2
      if WALK.bridge then
        if writeFile("walk_actor.txt", string.format("%x", pawn:GetAddress())) then WALK.bridge(); eachArr(pawn.FollowCharacters, collect) end
      elseif not WALK.warned then WALK.warned = true; print("[GamepadTweaks] walking followers: bridge missing (old DLL)\n") end
    end
    if grounded then WALK.formation(pawn, level, members, clock) end
    for _, actor in ipairs(members) do add(actor) end
    for address, original in pairs(WALK.originals) do
      if not present[address] and live(original.sprite) then WALK.slots(original.sprite, original, nil, true) end
    end
    WALK.originals = present
    local report = string.format("%s heroSprites=%d followers=%d", lv, heroSprites, #members)
    if report ~= WALK.report then WALK.report = report; print("[GamepadTweaks] walking: " .. report .. "\n") end
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
local EQUIP = { units = { [1]=80, [2]=80, [3]=91, [4]=91, [7]=1.5, [8]=2, [9]=51, [10]=2.35, [11]=58, [12]=1.9,
  [14]=80, [15]=57.5, [17]=60, [19]=55, [21]=55, [23]=55, [25]=55, [50]=11, [51]=13, [53]=0.15,
  [55]=27, [56]=0.33, [57]=0.5, [58]=300, [59]=110, [60]=0.13,
  [-100001]=5, [-100003]=5, [-100007]=5, [-100009]=5, [-100011]=5, [-100013]=5, [-100015]=5,
  [-100017]=5, [-100021]=5, [-100023]=6, [-100025]=6, [-100050]=3, [-100054]=5, [-100056]=2,
  [-100058]=5, [-100060]=2, [-100062]=2, [-100064]=2, [-100066]=4.5, [-100070]=5, [-100072]=2.5,
  [-100074]=3, [-100316]=6, [-100523]=5, [-100524]=10, [-100554]=4, [-100585]=7, [-100595]=7, [-100600]=7 },
  standard = { [100050]=100007, [100054]=100001, [100056]=100003, [100058]=100009, [100060]=100011,
    [100062]=100013, [100064]=100015, [100066]=100017, [100070]=100021, [100072]=100023, [100074]=100025 }, curves = {} }
function EQUIP.curve(id)
  if EQUIP.curves[id] == nil then
    local defs = StaticFindObject("/Game/JH/Tables/Buffs.Buffs")
    if not live(defs) then return end
    local row = defs:FindRow(tostring(id))
    local values = {}
    if row then
      for level = 1, 10 do
        values[level] = math.abs(tonumber(row[level == 1 and "ModifierValue" or "ModifierValue" .. (level - 1)]) or 0)
      end
      while #values > 0 and values[#values] == 0 do values[#values] = nil end
    end
    EQUIP.curves[id] = #values > 0 and values or false
  end
  return EQUIP.curves[id]
end
function EQUIP.effect(id, level)
  local standard = EQUIP.standard[id] or id
  if level == 0 then return -standard, 0 end
  local scale = EQUIP.units[-standard] or 1
  local function magnitude(curve, at)
    at = math.max(1, math.min(#curve, at))
    local index = math.floor(at)
    return curve[index] + (at - index) * ((curve[index + 1] or curve[index]) - curve[index])
  end
  local curve = EQUIP.curve(id)
  local reference = curve and (id == standard and curve or EQUIP.curve(standard))
  local typical = reference and magnitude(reference, scale)
  if typical and typical > 0 then
    return -standard, (level < 0 and -1 or 1) * magnitude(curve, math.abs(level)) / typical
  end
  return -id, level / (EQUIP.units[-id] or 1)
end
function EQUIP.read(profile, actions, source, base)
  eachArr(actions, function(_, action)
    local kind, id, amount = tonumber(action.Type), tonumber(action.ID), tonumber(action.Num)
    if (kind ~= 4 and kind ~= 5) or not id or id <= 0 or not amount or amount == 0 then return end
    local key = kind == 4 and id or -id
    if kind == 4 and (id == 53 or id == 69) then amount = -amount end
    profile.values[key] = (profile.values[key] or 0) + amount
    if amount > 0 and (source == "roll" or source == "base" and kind == 5 or source == "extra" and not base.values[key]) then
      profile.affixes = profile.affixes + 1
    end
  end)
end
function EQUIP.base(actions)
  local profile = {values = {}, affixes = 0}
  EQUIP.read(profile, actions, "base")
  return profile
end
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
  local dt = StaticFindObject("/Game/JH/Tables/Items.Items"); if not dt or not dt:IsValid() then return end
  reqCache = {}
  dt:ForEachRow(function(name, row)
    local t = row.ItemType
    if t >= 1 and t <= 13 then
      local list = {}
      row.Requirements:ForEach(function(i, e) local r = e:get(); list[#list + 1] = { t = r.Type, id = r.ID } end)
      reqCache[row.ID] = { sub = t, req = list }
      baseCache[row.ID] = EQUIP.base(row.Actions)
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
local function statsOf(sp)
  local base = baseCache[sp.ItemDefId]; if not base then return end
  local profile = {values = {}, affixes = base.affixes}
  for key, amount in pairs(base.values) do profile.values[key] = amount end
  EQUIP.read(profile, sp.Actions, "extra", base)
  EQUIP.read(profile, sp.RandActions, "roll", base)
  local totals = {}
  for key, amount in pairs(profile.values) do
    local effect, value = key, amount
    if key < 0 then effect, value = EQUIP.effect(-key, amount) end
    totals[effect] = (totals[effect] or 0) + value
  end
  profile.values = totals
  local score = 0.5 * profile.affixes
  for key, amount in pairs(profile.values) do
    local points
    if key < 0 then points = 0.65 * (amount < 0 and -1 or 1) * math.log(1 + math.abs(amount), 2)
    else
      points = amount / (EQUIP.units[key] or 1)
      if key == 56 or key == 57 then points = points * 0.25 end
    end
    score = score + points
  end
  profile.score = score
  return profile
end
local function better(new, old, mode)
  if not new then return false end
  if not old then return new.score > 1e-4 end
  if mode == 1 then return new.score > old.score + 1e-4 end
  if new.affixes < old.affixes then return false end
  for key, amount in pairs(old.values) do if (new.values[key] or 0) < amount - 1e-4 then return false end end
  for key, amount in pairs(new.values) do if amount < (old.values[key] or 0) - 1e-4 then return false end end
  return new.score > old.score + 1e-4
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
local function wornStats(npc, view)
  local res = {}
  local instance = view:GetOuter()
  local mgr
  for _, candidate in ipairs(FindAllOf("NPCManager") or {}) do
    if live(candidate) and live(instance) then
      local owner = candidate:GetOuter()
      if live(owner) and owner:GetAddress() == instance:GetAddress() then mgr = candidate; break end
    end
  end
  if not mgr then return end
  local info = mgr:GetNPCInfo(npc, false); if not info or not info:IsValid() then return end
  local complete = true
  info.EquipmentSpecs:ForEach(function(i, e)
    local sp = e:get()
    if live(sp) and not sp.bOnlyForLayout and sp.ItemDefId > 0 then
      local ent = reqCache[sp.ItemDefId]; local slot = ent and slotOf(ent.sub)
      if not ent then complete = false
      elseif slot then res[slot] = statsOf(sp); if not res[slot] then complete = false end; if slot == "W" then res.wsub = ent.sub end end
    end
  end)
  if complete then return res end
end
local function gridItems(grid, displayed)
  local out = {}
  local items
  if displayed then items = grid:GetDisplayedEntryWidgets() else items = grid:GetListItems() end
  if type(items) == "table" then for _, sp in ipairs(items) do if type(sp) == "userdata" and sp.get and not sp.IsValid then sp = sp:get() end out[#out + 1] = sp end
  elseif items and items.ForEach then items:ForEach(function(i, e) out[#out + 1] = e:get() end) end
  return out
end

local BAG = { hidden = {}, filtered = {}, observing = false }
function BAG.same(first, second)
  return first and second and first:IsValid() and second:IsValid() and first:GetAddress() == second:GetAddress()
end
function BAG.owner(vm, rootClass)
  local parent = vm
  for depth = 1, 8 do
    if not live(parent) then return end
    local view = parent:GetPairView()
    if live(view) and view:GetClass():GetFName():ToString() == rootClass then return parent end
    parent = parent:GetParentModule()
  end
end
function BAG.belongs(vm, root)
  for depth = 1, 8 do
    if not live(vm) then return false end
    if BAG.same(vm, root) then return true end
    vm = vm:GetParentModule()
  end
  return false
end
function BAG.rebuild(vm, grid)
  local address = grid:GetAddress()
  vm:HandleBackpackBatchChange()
  BAG.filtered[address] = nil
end
function BAG.observe(view)
  BAG.observing = true
  local root = view:GetNeoUIVM()
  local backpack = live(root) and root:GetSubModuleByKey(FName("Backpack"))
  local panel = live(backpack) and backpack:GetPairView()
  local grid = live(panel) and panel.GRID_ITEM
  BAG.observedGrid = live(grid) and grid or nil
  if BAG.observedGrid then
    local address = grid:GetAddress()
    if BAG.same(BAG.filtered[address], grid) and BAG.same(root:GetPairView(), view)
      and BAG.same(panel:GetNeoUIVM(), backpack) and BAG.belongs(backpack, root)
      and backpack:GetModuleVisibility() and shownChain(grid, {}, 0) then
      BAG.rebuild(backpack, grid)
    end
  end
  return root, panel, BAG.observedGrid
end
function BAG.remove(grid, item)
  if BAG.same(grid, BAG.observedGrid) then return false end
  grid:RemoveItem(item)
  local address = grid:GetAddress()
  if not BAG.same(BAG.filtered[address], grid) then
    for key, previous in pairs(BAG.filtered) do if not previous:IsValid() then BAG.filtered[key] = nil end end
    BAG.filtered[address] = grid
  end
  return true
end
function BAG.panel(vm, root, memo)
  if not live(vm) or not live(root) or not vm:GetModuleVisibility() or not root:GetModuleVisibility() then return end
  local view, rootView = vm:GetPairView(), root:GetPairView()
  if not live(view) or not live(rootView) or not BAG.same(view:GetNeoUIVM(), vm) or not BAG.belongs(vm, root) then return end
  local grid = view.GRID_ITEM
  if BAG.observing and (BAG.same(grid, BAG.observedGrid) or rootView:GetClass():GetFName():ToString() == "BPMV_PrimeTeam_C") then return end
  if live(grid) and shownChain(rootView, memo, 0) and shownChain(grid, memo, 0) then return view, grid end
end
function BAG.bound(ctx, grid)
  if not grid or not BAG.same(ctx.grid, grid) then return false end
  local view, currentGrid = BAG.panel(ctx.vm, ctx.root, {})
  return BAG.same(view, ctx.view) and BAG.same(currentGrid, grid)
end
function BAG.find(class, rootClass, memo)
  for _, vm in ipairs(FindAllOf(class) or {}) do
    if live(vm) and vm:GetModuleVisibility() then
      local root = BAG.owner(vm, rootClass)
      local view, grid = BAG.panel(vm, root, memo)
      if grid then return vm, root, view, grid end
    end
  end
end
function BAG.opacity(ctx, entry, hidden)
  local key = entry:GetAddress()
  local old = BAG.hidden[key]
  if old and not BAG.same(old.entry, entry) then BAG.hidden[key], old = nil, nil end
  if hidden then
    if not old then BAG.hidden[key] = {entry = entry, opacity = entry:GetRenderOpacity(), owner = ctx} end
    entry:SetRenderOpacity(0)
  elseif old then
    BAG.hidden[key] = nil
    if entry:GetRenderOpacity() == 0 then entry:SetRenderOpacity(old.opacity) end
  end
end
function BAG.release(ctx)
  for key, old in pairs(BAG.hidden) do
    if old.owner == ctx then
      if live(old.entry) then BAG.opacity(ctx, old.entry, false) else BAG.hidden[key] = nil end
    end
  end
  ctx.vm, ctx.root, ctx.view, ctx.grid = nil, nil, nil, nil
end

-- Gift eligibility is receiver-specific, not the ordinary backpack's weapon/learnability cache.
local ensureCellHook
local GIFT = { npc = -1, nextRead = 0, enabled = true,
  bridge = package.loadlib(DLLPATH, "wsmod_gift_context"), defs = {}, warned = false }
local function giftHidden(sp)
  if not GIFT.enabled or not live(sp) then return false end
  if sp.bIsLocked or sp.bOnlyForLayout then return true end
  local id = sp.ItemDefId
  if not id or id <= 0 then return false end
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
local function giftFilter()
  local grid = GIFT.grid; if not GIFT.enabled or not BAG.bound(GIFT, grid) then return end
  for _, sp in ipairs(gridItems(grid)) do
    if giftHidden(sp) then BAG.remove(grid, sp) end
  end
end
function GIFT.close()
  BAG.release(GIFT)
  GIFT.npc, GIFT.favor, GIFT.hobbies, GIFT.hobbySig, GIFT.nextRead = -1, nil, nil, nil, 0
end
local function taskGift()
  if not stableWorld() or inFight then if GIFT.vm then GIFT.close() end; return end
  local vm = GIFT.vm
  local opened = not BAG.bound(GIFT, GIFT.grid)
  if opened then
    if vm then GIFT.close() end
    GIFT.vm, GIFT.root, GIFT.view, GIFT.grid = BAG.find("JHMainCharacterGiftBackpackVM", "BPMV_Gift_C", {})
    vm = GIFT.vm; if not vm then return end
    ensureCellHook()
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
      BAG.rebuild(vm, GIFT.grid)
      if not BAG.bound(GIFT, GIFT.grid) then GIFT.close(); return end
      giftFilter()
      local items = gridItems(GIFT.grid); local pick = nil
      if key then for _, sp in ipairs(items) do if live(sp) and giftItemKey(sp) == key then pick = sp; break end end end
      if not pick and #items > 0 then pick = items[math.min(math.max((index or 0) + 1, 1), #items)] end
      if pick then GIFT.grid:SetSelectedItem(pick) end
      return
    end
  end
  giftFilter() -- game-driven sort/filter/item changes are filtered too; no address-keyed eligibility cache
end

local bp = { open = false, sortDone = false, openAt = 0, npc = nil, filter = nil, lit = {} }
function BAG.clearMark(key)
  local entry = bp.lit[key]
  bp.lit[key] = nil
  if not live(entry) then return end
  local frame = entry.ItemDisplay.CMP.IMG_Focus
  frame:SetColorAndOpacity(WHITE)
  local focused = entry:IsHovered() or entry:HasFocusedDescendants()
  if not focused then frame:SetVisibility(2) end
end
local function resetEntries()
  for key in pairs(bp.lit) do pcall(BAG.clearMark, key) end
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
local HIDE = { findAt = 0, open = false,
  hooked = false, hookCount = 0, lastHook = 0, sig = nil, recheckAt = nil, removed = 0, lastNpc = nil, lastFilter = nil,
  memo = {}, info = {}, wtype = {}, dim = {}, dimWt = {}, recipeDone = {}, bookDone = {}, srcN = -1, cfgHide = true, cfgTidy = true,
  cacheAt = -1, cacheNpc = -1, cacheFilter = -1 }

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
  local tv = HIDE.root
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
-- current character / tab, re-read at most once per 3 ms (one read per batch of cells)
local function current()
  local t = os.clock()
  if t - HIDE.cacheAt > 0.003 then
    HIDE.cacheAt = t
    local npc = -1
    local tv = HIDE.root
    if live(tv) and live(tv.RootData) then npc = teamNpcFromJson(tv.RootData:DataToString():ToString()) end
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
  local grid, spec, entry = self:get(), item:get(), widget:get()
  if not live(entry) then return end
  local key = entry:GetAddress()
  if BAG.hidden[key] then BAG.opacity(nil, entry, false) end
  if bp.lit[key] then pcall(BAG.clearMark, key) end
  if not live(spec) then return end
  if BAG.bound(GIFT, grid) then
    BAG.opacity(GIFT, entry, giftHidden(spec))
  elseif HIDE.open and BAG.bound(HIDE, grid) then
    HIDE.hookCount = HIDE.hookCount + 1
    local npc, filter = current()
    BAG.opacity(HIDE, entry, not spec.bOnlyForLayout and isHidden(npc, filter, spec.ItemDefId))
  end
end
ensureCellHook = function()
  if HIDE.hooked or iniNumber("cell_hook", 1) ~= 1 then return end
  local fn = StaticFindObject(HOOK_FN); if not fn or not fn:IsValid() then return end
  local ok, err = pcall(function()
    RegisterHook(HOOK_FN, function(self, item, widget)
      pcall(onEntryInit, self, item, widget)
    end)
  end)
  HIDE.hooked = ok
  print("[GamepadTweaks] backpack/gift: cell hook " .. (ok and "registered" or ("failed: " .. tostring(err))) .. "\n")
end
local function onOpen(vm)
  if not reqCache then buildReqCache() end
  if not reqCache then return false end
  local grid = HIDE.grid
  if BAG.same(BAG.filtered[grid:GetAddress()], grid) then
    BAG.rebuild(vm, grid)
    if not BAG.bound(HIDE, grid) then return false end
  end
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
  local paused = BAG.observing or inFight or now() < pauseUntil
  if paused or not BAG.bound(HIDE, HIDE.grid) then
    if HIDE.vm then BAG.release(HIDE); HIDE.open = false; resetEntries(); bp.open = false end
    if paused or now() < HIDE.findAt then return end
    HIDE.findAt = now() + 0.25
    HIDE.vm, HIDE.root, HIDE.view, HIDE.grid = BAG.find("JHMainCharacterBackpackInTeamVM", "BPMV_PrimeTeam_C", {})
    if not HIDE.vm then return end
  end
  local vm, grid = HIDE.vm, HIDE.grid
  if not HIDE.open then HIDE.open = onOpen(vm); if not HIDE.open then return end end
  -- inventory changed (item used, equipped, learned): decisions may change
  local srcN = vm.CurrentDataSrc:GetArrayNum()
  if srcN ~= HIDE.srcN then HIDE.srcN = srcN; HIDE.memo = {}; HIDE.wtype = {} end
  local npc, filter = current()
  local sig = grid:GetNumItems() .. "|" .. npc .. "|" .. tostring(filter) .. "|" .. HIDE.hookCount
  local recheck = HIDE.recheckAt and now() >= HIDE.recheckAt
  if sig == HIDE.sig and not recheck then return end
  if recheck then HIDE.recheckAt = nil end
  -- character switched while we had items removed: bring them back now and filter in this same tick
  if HIDE.lastNpc ~= nil and npc ~= HIDE.lastNpc and HIDE.removed > 0 then
    BAG.rebuild(vm, grid); HIDE.removed = 0
    if not BAG.bound(HIDE, grid) then return end
  end
  if HIDE.lastFilter ~= nil and filter ~= HIDE.lastFilter then HIDE.removed = 0 end      -- the game rebuilt the list itself
  HIDE.lastNpc, HIDE.lastFilter = npc, filter
  local gone, n = {}, 0
  for _, sp in ipairs(gridItems(grid)) do
    if sp:IsValid() and not sp.bOnlyForLayout and isHidden(npc, filter, sp.ItemDefId) and BAG.remove(grid, sp) then
      gone[sp:GetAddress()] = true; n = n + 1
    end
  end
  -- learn from what the game itself shows (greyed out / recipe learned) and repair recycled cells
  local learnt = 0
  for _, en in ipairs(gridItems(grid, true)) do
    if live(en) then
      local ok, sp = pcall(function() return en:GetBindedDataObj() end)
      if ok and sp and sp:IsValid() and not sp.bOnlyForLayout then
        local addr = sp:GetAddress()
        local js = ""; pcall(function() js = en.ItemDisplay:GetData():DataToString():ToString() end)
        local sid = tonumber(js:match('"setting_id":(%d+)'))
        if sid == sp.ItemDefId and not gone[addr] then
          local newly = false
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
          if newly and isHidden(npc, filter, sid) and BAG.remove(grid, sp) then gone[addr] = true; learnt = learnt + 1 end
        end
        BAG.opacity(HIDE, en, gone[addr] or isHidden(npc, filter, sp.ItemDefId))
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
  if inFight or not HIDE.open or not stableWorld() or not BAG.bound(HIDE, HIDE.grid) then
    if bp.open then resetEntries(); bp.open = false end; return
  end
  local vm, view = HIDE.vm, HIDE.view
  local cfgSort = iniNumber("default_sort", 4)
  local mark = iniNumber("highlight_better", 1) == 1
  local mode = iniNumber("better_mode", 1)

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
  local npc = current()
  if npc < 0 then resetEntries(); return end
  if bp.npc ~= nil and npc ~= bp.npc then resetEntries() end
  bp.npc = npc
  if not mark then if next(bp.lit) then resetEntries() end return end
  local worn = wornStats(npc, view)
  if not worn then resetEntries(); return end
  local visible = {}
  for _, en in ipairs(gridItems(HIDE.grid, true)) do
    if live(en) then
      local key = en:GetAddress()
      visible[key] = true
      local good = false
      local sp = en:GetBindedDataObj()
      if live(sp) and not sp.bOnlyForLayout then
        local ent = reqCache[sp.ItemDefId]
        local slot = ent and slotOf(ent.sub)
        -- weapons: only compare against the same weapon type the character is holding
        if slot and canUse(sp.ItemDefId, npc) and not (slot == "W" and worn.wsub and worn.wsub ~= ent.sub and iniNumber("same_weapon_type", 1) == 1) then
          good = better(statsOf(sp), worn[slot], mode)
        end
      end
      local f = en.ItemDisplay.CMP.IMG_Focus
      if good then
        f:SetColorAndOpacity(highlightColor()); if f:GetVisibility() ~= 3 then f:SetVisibility(3) end
        bp.lit[key] = en
      elseif bp.lit[key] then BAG.clearMark(key)
      end
    end
  end
  for key in pairs(bp.lit) do if not visible[key] then BAG.clearMark(key) end end
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
function NAV.pad(view)
  if not live(view) then return false end
  local ok, pad = pcall(function() return view:BP_IsGamepadMode() end)
  return ok and pad == true
end
function NAV.shown(class)
  local memo = {}
  for _, view in ipairs(FindAllOf(class) or {}) do if live(view) and shownChain(view, memo, 0) then return view end end
end
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
      if NAV.self or tonumber(scen:get()) ~= 3 then return end
      local key = id:get():ToString()
      if key ~= "Property" and key ~= "Equip" then return end
      local caller = self:get()
      if OBS_HOOK and OBS_HOOK(caller, id) then return end
      if not NAV.open or not NAV.cfg or not NAV.pad(NAV.team) or not shownChain(NAV.team, {}, 0)
        or not BAG.belongs(caller, NAV.vm) then return end
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
  if not live(t) or not shownChain(t, {}, 0) then
    NAV.open, NAV.wasPad = false, false
    if MASKS.prime ~= 0 then navFlag(false) end
    if now() < NAV.findAt then return end
    NAV.findAt = now() + 0.25
    t = NAV.shown("BPMV_PrimeTeam_C"); NAV.team = t
    if not t then return end
  end
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
  local pad = NAV.pad(t)
  local enteredPad = pad and not NAV.wasPad
  NAV.wasPad = pad
  if not pad or BAG.bound(GIFT, GIFT.grid) then
    NAV.want, NAV.pending, NAV.force, NAV.lt, NAV.rt = nil, nil, false, false, false
    navFlag(false); return
  end
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
  -- the game moves the focus when LT/RT is RELEASED (measured: ~1 press length after the press), so the
  -- target is chosen on press and applied on release; navGo then holds it for 0.3 s against late moves
  if pressed ~= 0 and cur then
    local base = NAV.stable or (NAV_IDX[cur] and cur) or "SideBar"
    NAV.pending, NAV.pendingWhy, NAV.want = navStep(base, pressed), pressed > 0 and "RT" or "LT", nil
  end
  if NAV.pending and not (lt or rt) then navGo(NAV.pending, NAV.pendingWhy); NAV.pending = nil end
  if not NAV.pending and not NAV.want and not (lt or rt) and enteredPad and (cur == "Property" or cur == "Equip") then
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
          if BAG.same(HIDE.root, NAV.vm) and live(g) then
            for _, en in ipairs(gridItems(g, true)) do
              if live(en) and en:HasFocusedDescendants() then
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
  maskSet("prime", m)
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
OBS_HOOK = function(caller, id)
  if not OBS.open or not OBS.cfg then return false end
  local v = OBS.view
  if not NAV.pad(v) or not shownChain(v, {}, 0) or not BAG.belongs(caller, OBS.vm) then return false end
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
  if not live(v) or not shownChain(v, {}, 0) then
    OBS.open, OBS.wasPad = false, false
    BAG.observing, BAG.observedGrid = false, nil
    if MASKS.obs ~= 0 then maskSet("obs", 0) end
    if now() < OBS.findAt then return end
    OBS.findAt = now() + 0.25
    v = NAV.shown("BPMV_Observe_C"); OBS.view = v
    if not v then return end
  end
  OBS.vm, OBS.bpView, OBS.grid = BAG.observe(v)
  if not OBS.open then
    OBS.open, OBS.stable, OBS.want, OBS.bpIdx, OBS.btn = true, nil, nil, 0, nil
    OBS.cfg = iniNumber("prime_skip_panels", 1) == 1
    if OBS.cfg then navHook() end
    if OBS.cfg and NAV.pad(v) then obsGo("Bottom", "open", 1.0) end
  end
  if not OBS.cfg or not (OBS.vm and OBS.vm:IsValid()) then maskSet("obs", 0) return end
  local pad = NAV.pad(v)
  local enteredPad = pad and not OBS.wasPad
  OBS.wasPad = pad
  if not pad or BAG.bound(GIFT, GIFT.grid) then OBS.want, OBS.force = nil, false; maskSet("obs", 0); return end
  local cur, btn = obsRegion()
  local ev = PADEV
  if ev and MASKS.obs ~= 0 then
    for ch in ev:gmatch("[LR<>%^v]") do
      local base = OBS.want or OBS.stable or cur or "Bottom"
      if ch == "L" or ch == "R" then obsGo(base == "Bottom" and "Backpack" or "Bottom", ch .. "T pad")
      elseif ch == "^" and base == "Bottom" then obsGo("Backpack", "up pad") end
    end
  end
  if enteredPad and not OBS.want and (cur == "Property" or cur == "Equip") then
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
        if not live(g) then return end
        for _, en in ipairs(gridItems(g, true)) do
          if live(en) and en:HasFocusedDescendants() then
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
  maskSet("obs", m)
end
local function taskPadEv()
  PADEV = navPadEvents()
  local intent = PADEV and PADEV:match(".*([Mm])")
  if intent then taskMapFlag(intent) end
end

-- ---------------------------------------------------------------- 11) battle speed: x1 -> x2 -> 速战 -> x1
-- The game's speed button only toggles x1 / x2: it sets the persistent level's WorldSettings.TimeDilation to
-- 1.0 / 2.0 (measured 2026-11-23; nothing else changes) and shows BTN_SpeedUp1 (x1 icon) or BTN_SpeedUp2 (x2).
-- Mouse speed-button hooks and the proxy's single-Y events advance the same cycle, not icon changes:
-- x1 -> x2 -> 速战 -> x1. The game restores its icon during fight startup and cut-ins; that is not a press.
-- Our own icon corrections are guarded so they cannot advance the cycle. Early presses are queued until the
-- battle view is ready. Auto battle is switched off again only if we switched it on. The level is kept for
-- the next fight. The watchdog measures time since combat activity, not the whole battle.
-- quick_mask = 1 covers the flickering battle; quick_mute = 1 temporarily mutes only this game's audio session.
-- Both native effects have a 500 ms heartbeat: a Lua restart or stopped loop releases them automatically.
-- Reads only widget visibility and simple values; no struct/slot reads (those crashed UE4SS, 2026-11-23 12:20).
local taskSpeed, spdRecover
do
local function now() return RUNTIME.clock end -- monotonic milliseconds from the native owner receipt
local SPD_Q = 3
local SPD = { view = nil, ws = nil, findAt = 0, active = false, on = nil, level = 1, mem = 1, written = nil,
  overwrites = 0, exports = nil, quick = true, qspeed = 50, qtimeout = 10, qStart = nil, qClock = nil, autoByUs = false, mask = true,
  mute = true, correcting = false, presses = 0, padPresses = 0, hooks = {}, hookAt = 0, over = false, resAt = 0,
  fightKey = nil, pressFight = nil, pc = nil, recovered = false, fast = false }
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
  local current = spdGameOn(v)
  if current == nil or current == on then return end
  SPD.correcting = true
  local ok, err = pcall(function() if on then v:HandleBtn_SpeedUp_1() else v:HandleBtn_SpeedUp_2() end end)
  SPD.correcting = false
  if not ok then error(err) end
  SPD.on = spdGameOn(v)
end
local function spdFightPawn()
  local controller, pawn, world, instance, level = RUNTIME.player()
  if controller then
    local key = pawn:GetFullName()
    return key:find("BP_FightSpectator", 1, true) ~= nil, key, controller, instance, level, pawn
  end
  return false, nil, nil, instance, level
end
local function spdOwned(widget, controller, instance)
  if not controller or not instance or not live(widget) or widget:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then return false end
  local owner = widget:GetOwningPlayer()
  if live(owner) then return owner:GetAddress() == controller:GetAddress() end
  local outer = widget:GetOuter()
  return live(outer) and outer:GetAddress() == instance:GetAddress()
end
local function spdAttached(widget, controller, instance)
  if not spdOwned(widget, controller, instance) then return false end
  for depth = 1, 32 do
    if widget:IsA(uwClass) and widget:IsInViewport() then return true end
    local parent = widget:GetParent()
    if not live(parent) then
      local tree = widget:GetOuter()
      parent = live(tree) and tree:GetOuter()
      if not live(parent) or not parent:IsA(uwClass) then return false end
    end
    widget = parent
  end
  return false
end
local function spdHud(controller, instance)
  local cached = SPD.view
  if not spdAttached(cached, controller, instance) then cached, SPD.view = nil, nil end
  if (not cached or not cached:IsVisible()) and now() >= SPD.findAt then
    SPD.findAt = now() + 0.25
    for _, candidate in ipairs(FindAllOf("BPMV_JHBattleModule_C") or {}) do
      if spdOwned(candidate, controller, instance) and shownChain(candidate, {}, 0) then SPD.view = candidate; break end
    end
  end
  return SPD.view
end
local function spdQueuePress(v)
  if not runtimePoll() or not live(v) then return end
  local fight, key, controller, instance = spdFightPawn()
  if not fight or (SPD.over and key == SPD.fightKey) or not spdAttached(v, controller, instance) then return end
  local a = v:GetAddress()
  if SPD.pressView ~= a or SPD.pressFight ~= key then SPD.pressView, SPD.pressFight, SPD.presses = a, key, 0 end
  SPD.presses = SPD.presses + 1
end
local function spdPresentation(self, animation, startTime, loops, playMode, rate)
  if not SPD.fast or loops:get() ~= 1 then return end
  local clip = animation:get(); if not live(clip) then return end
  local name = clip:GetFName():ToString():gsub("_INST$", "")
  local class = name == "ShowUltraSkill" and "BPMV_JHBattleModule_C"
    or (name == "ShowUltraSkill_CN" or name == "ShowUltraSkill_EN") and "BPMV_BattleSpell_C"
  if not class then return end
  local widget = self:get()
  local fight, key, controller, instance = spdFightPawn()
  if not fight or key ~= SPD.fightKey or not live(widget) or widget:GetClass():GetFName():ToString() ~= class
    or not spdAttached(widget, controller, instance) then return end
  local speed = tonumber(rate:get())
  if speed and speed > 0 and speed < 16 then rate:set(math.min(16, speed * 16)) end
end
local function spdBattleActor(actor, level)
  if not live(actor) or actor:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) or actor:IsActorBeingDestroyed() then return false end
  local outer = actor:GetOuter()
  if live(outer) and outer:GetAddress() == level:GetAddress() then return true end
  local world, current = actor:GetWorld(), level:GetOuter()
  return live(world) and live(current) and world:GetAddress() == current:GetAddress()
end
local function spdProgress(self, actorParam, turnStart)
  if not SPD.fast and not (turnStart and SPD.over) then return end
  local fight, key, controller, instance, level, pawn = spdFightPawn()
  if not fight or key ~= SPD.fightKey or level:GetAddress() ~= SPD.levelAddr then return end
  local manager = self:get()
  local spectator = live(manager) and manager.FightSpectator
  if live(spectator) then
    if spectator:GetAddress() ~= pawn:GetAddress() then return end
  elseif not actorParam or not spdBattleActor(actorParam:get(), level) then return end
  if SPD.over then SPD.newTurn = true else SPD.progress = now() end
end
local function spdCurrentAbility(ability)
  if not SPD.fast or not live(SPD.abilityClass) or not live(ability) or not ability:IsA(SPD.abilityClass) then return end
  local fight, key, controller, instance, level = spdFightPawn()
  if not fight or key ~= SPD.fightKey or level:GetAddress() ~= SPD.levelAddr then return end
  local actor = ability:GetOwningFightCharacter()
  if spdBattleActor(actor, level) then return actor end
end
local function spdAction(self)
  if SPD.fast and spdCurrentAbility(self:get()) then SPD.progress = now() end
end
local function spdSkillDelay(self, context, duration, latentInfo)
  if not SPD.fast then return end
  local seconds = duration:get()
  if seconds <= 0.01 then return end
  local ability = context:get()
  if not spdCurrentAbility(ability) then return end
  local latent = latentInfo:get()
  if latent.UUID ~= -1255582134 and latent.UUID ~= 819583215 then return end
  if latent.ExecutionFunction:ToString() == "ExecuteUbergraph_GA_Base" and live(latent.CallbackTarget)
    and latent.CallbackTarget:GetAddress() == ability:GetAddress() then duration:set(0.01) end
end
local function spdSkillTime(self, context, scale)
  if not SPD.fast or not SPD.written then return end
  local requested = scale:get()
  if requested > 0 and requested <= 2 and requested < SPD.written and spdCurrentAbility(context:get()) then scale:set(SPD.written) end
end
local function spdFreezeStart(self, context, paused)
  if not SPD.fast then return end
  SPD.freeze = nil
  if not paused:get() then return end
  local ability = context:get()
  local actor = spdCurrentAbility(ability)
  if not actor then return end
  local seconds = tonumber(ability["定屏总耗时"])
  if seconds and seconds > 0.03 then SPD.freeze = {actor = actor:GetAddress(), seconds = seconds} end
end
local function spdFreezeDelay(self, callback, duration)
  local freeze = SPD.freeze
  if not freeze then return end
  SPD.freeze = nil
  if not SPD.fast or duration:get() ~= freeze.seconds then return end
  local component = self:get()
  local owner = live(component) and component:GetOwner()
  if live(owner) and owner:GetAddress() == freeze.actor then duration:set(0.03) end
end
local localData = os.getenv("LOCALAPPDATA")
local battleLog = localData and (localData .. [[\Wandering_Sword\Saved\Logs\Wandering_Sword.log]])
local function spdReadActions(start)
  if start then SPD.logPos, SPD.logTail, SPD.logNext = nil, "", 0 end
  if not battleLog or (not start and now() < SPD.logNext) then return end
  SPD.logNext = now() + 0.5
  local file = io.open(battleLog, "rb"); if not file then return end
  local finish = file:seek("end")
  local previous = SPD.logPos
  SPD.logPos = finish
  if not finish or not previous or finish < previous then SPD.logTail = ""; file:close(); return end
  if finish == previous then file:close(); return end
  local offset = math.max(previous, finish - 16384)
  local data = file:seek("set", offset) and file:read(finish - offset)
  file:close()
  if not data then SPD.logTail = ""; return end
  data = (offset == previous and SPD.logTail or "") .. data
  local lines, tail = data:match("^(.*\n)([^\n]*)$")
  SPD.logTail = (tail or data):sub(-512)
  if lines and lines:find("LogTemp: 当前选中的技能 NPCId:%s*%d+,%s*SkillId:%s*%d+,%s*SkillName%s*:%s*Default__GA_[%w_]+") then SPD.progress = now() end
end
local function spdHook(path, callback)
  if SPD.hooks[path] then return end
  local fn = StaticFindObject(path)
  if fn and fn:IsValid() then SPD.hooks[path] = pcall(RegisterHook, path, function(...) pcall(callback, ...) end) end
end
local function spdInstallHooks()
  if now() < SPD.hookAt then return end
  SPD.hookAt = now() + 2
  spdHook("/Script/UMG.UserWidget:PlayAnimation", spdPresentation)
  if not live(SPD.abilityClass) then SPD.abilityClass = StaticFindObject("/Script/JH.JHGameplayAbility") end
  spdHook("/Script/JH.FightManager:HandlePawnTurnStart", function(self, actor) spdProgress(self, actor, true) end)
  spdHook("/Script/JH.FightManager:HandlePawnBeAttack", function(self, actor) spdProgress(self, actor, false) end)
  spdHook("/Script/JH.JHGameplayAbility:EndTurnForAbility", spdAction)
  spdHook("/Script/Engine.KismetSystemLibrary:Delay", spdSkillDelay)
  spdHook("/Script/Engine.GameplayStatics:SetGlobalTimeDilation", spdSkillTime)
  spdHook("/Script/Engine.GameplayStatics:SetGamePaused", spdFreezeStart)
  spdHook("/Script/JH.JHAbilitySystemComponent:AddDelayCallback", spdFreezeDelay)
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
local function spdFindWS(level)
  if not level then return end
  local settings = level.WorldSettings
  if live(settings) then return settings end
  for _, o in ipairs(FindAllOf("WorldSettings") or {}) do
    if live(o) then
      local outer = o:GetOuter()
      if live(outer) and outer:GetAddress() == level:GetAddress() then return o end
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
  if on then
    if not isAuto and not SPD.autoTried then
      SPD.autoTried = true
      if not pcall(function() v:EnableAutoBattle() end) then return false end
      ok, isAuto = pcall(function() return v:BtnAutoBattleFlagIsAuto() end)
    end
    if ok and isAuto and SPD.autoTried then spdAutoMark(true) end
    return ok and isAuto == true
  end
  if isAuto and (SPD.autoByUs or SPD.autoTried) then
    pcall(function() v:DisableAutoBattle() end)
    ok, isAuto = pcall(function() return v:BtnAutoBattleFlagIsAuto() end)
  end
  SPD.autoTried = false
  if ok and not isAuto then spdAutoMark(false) end
  return ok and isAuto == false
end
local function spdName(l) return l == SPD_Q and "速战" or ("x" .. l) end
local function spdReleaseLimit(settings)
  local limit = SPD.limit
  SPD.limit, SPD.limitChanged = nil, false
  if limit and settings and limit.address == settings:GetAddress() and settings.MaxGlobalTimeDilation == limit.applied then
    settings.MaxGlobalTimeDilation = limit.before
  end
end
local function spdQuickRate(settings)
  local ceiling, limit = settings.MaxGlobalTimeDilation, SPD.limit
  if limit and (settings:GetAddress() ~= limit.address or ceiling ~= limit.applied) then
    SPD.limit, SPD.limitChanged = nil, true
  elseif not limit and not SPD.limitChanged and ceiling == 20 and SPD.qspeed > ceiling then
    SPD.limit = {address = settings:GetAddress(), before = ceiling, applied = SPD.qspeed}
    settings.MaxGlobalTimeDilation = SPD.qspeed
    ceiling = settings.MaxGlobalTimeDilation
  end
  return math.min(SPD.qspeed, ceiling)
end
local function spdRestore(level)
  if not SPD.written and not SPD.limit then return end
  local settings = level and level:GetAddress() == SPD.levelAddr and spdFindWS(level)
  if settings and SPD.written and math.abs(settings.TimeDilation - SPD.written) < 0.01 then settings.TimeDilation = 1 end
  spdReleaseLimit(settings)
end
function RUNTIME.beforeSpeedMap()
  if not SPD.limit then return end
  local world = RUNTIME.world()
  local level = world and world.PersistentLevel
  if live(level) then spdRestore(level) end
end
local function spdEnd(level)
  SPD.fast, SPD.progress, SPD.freeze = false, nil, nil
  spdPadInput(false)
  spdMute(false)
  if SPD.active then
    spdRestore(level)
    local dur = SPD.qStart and (os.time() - SPD.qStart) or nil
    print(string.format("[GamepadTweaks] speed: fight over at %s%s (game re-applied %d times)\n", spdName(SPD.level),
      dur and string.format(", 速战 %d s", dur) or "", SPD.overwrites))
  end
  SPD.active, SPD.view, SPD.ws, SPD.on, SPD.written, SPD.qStart = false, nil, nil, nil, nil, nil
  SPD.over, SPD.qClock, SPD.seen, SPD.pressView, SPD.presses, SPD.padPresses = false, nil, nil, nil, 0, 0
  SPD.findAt, SPD.fightKey, SPD.pressFight, SPD.pc, SPD.pcAddr, SPD.levelAddr, SPD.instance = 0, nil, nil, nil, nil, nil, nil
  SPD.result, SPD.newTurn, SPD.recovered, SPD.autoTried, SPD.restoreAuto, SPD.startWait, SPD.resAt = nil, false, false, false, false, nil, -1
  spdBadge(0)
end
function RUNTIME.endSpeed(level) if SPD.fightKey then spdEnd(level) end end
-- Always release native effects first. This path must run before any HUD/icon readiness return.
spdRecover = function(reason)
  if SPD.recovered then return end
  SPD.recovered = true
  SPD.fast, SPD.progress = false, nil
  spdMute(false); spdBadge(0); spdPadInput(false)
  local wasActive = SPD.active
  SPD.level, SPD.qStart, SPD.qClock = 1, nil, nil
  SPD.presses, SPD.padPresses, SPD.restoreAuto = 0, 0, SPD.autoByUs
  spdRemember(1)
  print("[GamepadTweaks] speed: recovery -> x1 (" .. reason .. ")\n")
  local fight, key, controller, instance, level = spdFightPawn()
  spdRestore(level)
  SPD.written = nil
  if wasActive and fight and key == SPD.fightKey and level:GetAddress() == SPD.levelAddr then
    local settings = spdFindWS(level); if settings then settings.TimeDilation = 1 end
    if spdAttached(SPD.view, controller, instance) then
      pcall(spdSetGame, SPD.view, false); pcall(spdAuto, SPD.view, false); SPD.restoreAuto = false
    end
  end
end
-- result screen up: the fight is decided, stop holding the speed (the screen's own animations run normally)
local function spdResult()
  for _, cn in ipairs({ "BPMV_BattleWinMaster_C", "BPMV_BattleFailure_C" }) do
    for _, o in ipairs(FindAllOf(cn) or {}) do if spdOwned(o, SPD.pc, SPD.instance) and shownChain(o, {}, 0) then return cn end end
  end
  return nil
end
taskSpeed = function()
  SPD.freeze = nil
  spdInstallHooks()
  local fight, key, pc, instance, level = spdFightPawn()
  local pad = RUNTIME.events; RUNTIME.events = 0
  if not fight then
    if SPD.fightKey then
      spdEnd(level)
      if pc and (key:find("BP_SceneHero",1,true) or key:find("BP_WorldHero",1,true)) then
        inFight, inBattle = false, key:find("BP_WorldHero",1,true) ~= nil
        lastBattle = inBattle; writeBattleFlag()
      end
    end
    return
  end
  -- A new spectator is a new fight even if the 300 ms poll never saw the field between fights.
  if key ~= SPD.fightKey or SPD.levelAddr ~= level:GetAddress() or SPD.pcAddr ~= pc:GetAddress() then
    local pending, pv = SPD.pressFight == key and SPD.presses or 0, SPD.pressView
    spdEnd(level)
    SPD.fightKey, SPD.pc, SPD.pcAddr, SPD.instance, SPD.levelAddr, SPD.startWait = key, pc, pc:GetAddress(), instance, level:GetAddress(), now()
    SPD.presses, SPD.pressView, SPD.pressFight = pending, pv, key
  end
  if not inFight then inFight, inBattle = true, true; writeBattleFlag() end
  if not SPD.over then SPD.padPresses = SPD.padPresses + pad end
  if now() - SPD.resAt >= 0.12 then
    SPD.resAt, SPD.result = now(), spdResult()
  end
  if SPD.result and not SPD.over then
    SPD.over, SPD.newTurn, SPD.presses, SPD.padPresses, SPD.fast, SPD.progress = true, false, 0, 0, false, nil
    spdPadInput(false); spdMute(false); spdBadge(0)
    if SPD.active then
      local settings = spdFindWS(level); if settings then settings.TimeDilation = 1 end
      spdReleaseLimit(settings)
      if (SPD.autoByUs or SPD.autoTried) and spdAttached(SPD.view, pc, instance) then spdAuto(SPD.view, false) end
      SPD.written = nil
      if SPD.qClock then print(string.format("[GamepadTweaks] speed: 速战 decided in %.1f s (%s, game re-applied %d times)\n", now() - SPD.qClock, SPD.result, SPD.overwrites)) end
    end
  end
  if SPD.over then
    if not SPD.result and SPD.newTurn then
      spdEnd(level); SPD.fightKey, SPD.pc, SPD.pcAddr, SPD.instance, SPD.levelAddr, SPD.startWait = key, pc, pc:GetAddress(), instance, level:GetAddress(), now()
    end
    return
  end
  if SPD.recovered then
    local available = spdHud(pc, instance)
    if not available then spdPadInput(false); return end
    if SPD.restoreAuto then spdAuto(available, false); SPD.restoreAuto = false end
    spdPadInput(true)
    if SPD.presses == 0 and SPD.padPresses == 0 then return end
  end
  if SPD.fast then spdReadActions(false) end
  if SPD.qClock and now() - (SPD.progress or SPD.qClock) >= SPD.qtimeout then spdRecover("no combat activity"); return end
  if not SPD.active and SPD.startWait and now() - SPD.startWait >= 5 and not SPD.recovered then
    spdRecover("HUD not ready"); return
  end
  spdPadInput(true)
  local v = spdHud(pc, instance)
  if not v then
    if SPD.fast then spdRecover("battle HUD detached") end
    return
  end
  local ws = SPD.ws
  if not (ws and ws:IsValid()) then ws = spdFindWS(level); SPD.ws = ws; if not ws then return end end
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
    SPD.qspeed = math.max(3, math.min(50, iniNumber("quick_speed", 50)))
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
  if presses > 0 or SPD.written == nil then spdSetGame(v, lvl == 2) end
  SPD.on = spdGameOn(v)
  local autoReady = false
  if lvl == SPD_Q then
    if not SPD.qStart then SPD.qStart, SPD.qClock = os.time(), now() end
    autoReady = spdAuto(v, true)                                      -- never accelerate a still-manual fight
    if autoReady and not SPD.fast then SPD.progress = now(); spdReadActions(true) end
    spdMute(autoReady and SPD.mute)
  else
    spdMute(false)
    if SPD.qStart then
      SPD.qStart, SPD.qClock = nil, nil
      spdAuto(v, false)
      SPD.progress = nil
    end
  end
  SPD.fast = lvl == SPD_Q and autoReady
  if not SPD.fast then spdReleaseLimit(ws) end
  local want = (lvl == SPD_Q) and (autoReady and spdQuickRate(ws) or 1) or lvl
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

local taskBulkSettings
do
local modes = {
  BPCMP_BulkSelectionButton_Trading_C = {view="BPMV_Trading_C", file="bulk_trading.txt"},
  BPCMP_BulkSelectionButton_Decmopo_C = {view="BPMV_Decompo_C", file="bulk_decompo.txt"}
}
local applying, hooked, warned = false, {}, {}
for _, mode in pairs(modes) do
  local quality, rank = (readFirst(mode.file) or ""):match("^v1|(%d+)|(%d+)%s*$")
  quality, rank = tonumber(quality), tonumber(rank)
  if quality and rank and quality <= 63 and rank <= 1023 and (quality == 0 or rank == 0) then mode.quality, mode.rank = quality, rank end
end
local function same(first, second)
  return live(first) and live(second) and first:GetAddress() == second:GetAddress()
end
local function binding(button)
  if not live(button) or button:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then return end
  local mode = modes[button:GetClass():GetFName():ToString()]; if not mode then return end
  local tree = button:GetOuter(); local view = live(tree) and tree:GetOuter()
  if not live(view) or view:GetClass():GetFName():ToString() ~= mode.view then return end
  local controller, _, _, instance = RUNTIME.player(); if not controller then return end
  local owner = view:GetOwningPlayer()
  if live(owner) then if not same(owner, controller) then return end
  elseif not same(view:GetOuter(), instance) then return end
  local panel = button.ListPanel
  if live(panel) and same(panel:GetOuter(), tree) then return mode, panel end
end
local function group(list, button, count)
  if not live(list) or not same(list.BtnMain, button) then return end
  local rows = list.ListItems; if not rows or #rows ~= count then return end
  local result = {mask=0}
  for position = 1, count do
    local item = rows[position]; if not live(item) then return end
    local index = math.tointeger(item.DataIndex)
    if not index or index < 0 or index >= count or result[index] then return end
    local tree = item.WidgetTree; local root = live(tree) and tree.RootWidget
    if not live(root) then return end
    local mark
    for child = 0, root:GetChildrenCount()-1 do
      local widget = root:GetChildAt(child)
      if live(widget) and widget:GetFName():ToString() == "IMG" then mark = widget; break end
    end
    if not mark then return end
    local visibility = mark:GetVisibility()
    if visibility ~= 2 and visibility ~= 3 then return end
    if visibility == 3 then result.mask = result.mask | (1 << index) end
    result[index] = {item=item, mark=mark}
  end
  return result
end
local function setGroup(rows, wanted, count)
  for index = 0, count-1 do
    local row = rows[index]
    if (row.mark:GetVisibility() == 3) ~= ((wanted & (1 << index)) ~= 0) then row.item:HandleImgClicked() end
  end
end
local function apply(button)
  local mode, panel = binding(button); if not mode or mode.quality == nil then return end
  local quality, rank = group(panel.List_Quality, button, 6), group(panel.List_Rank, button, 10)
  if not quality or not rank or (quality.mask == mode.quality and rank.mask == mode.rank) then return end
  applying = true
  local ok, err = pcall(function()
    if mode.rank == 0 then setGroup(rank, 0, 10); setGroup(quality, mode.quality, 6)
    else setGroup(quality, 0, 6); setGroup(rank, mode.rank, 10) end
  end)
  applying = false
  if not ok then error(err) end
end
local function flush(mode)
  if mode.dirty and writeFile(mode.file, string.format("v1|%d|%d\n", mode.quality, mode.rank)) then mode.dirty = false end
end
local function userChanged(context)
  local item = context:get(); if not live(item) then return end
  local tree = item:GetOuter(); local list = live(tree) and tree:GetOuter()
  if not live(list) then return end
  local button = list.BtnMain; local mode, panel = binding(button); if not mode then return end
  local quality, rank = group(panel.List_Quality, button, 6), group(panel.List_Rank, button, 10)
  if not quality or not rank or (quality.mask ~= 0 and rank.mask ~= 0) then return end
  local source = same(list, panel.List_Quality) and quality or same(list, panel.List_Rank) and rank
  local row = source and source[item.DataIndex]; if not row or not same(row.item, item) then return end
  if mode.quality ~= quality.mask or mode.rank ~= rank.mask then
    mode.quality, mode.rank, mode.dirty = quality.mask, rank.mask, true; flush(mode)
  end
end
local function fromButton(context) apply(context:get()) end
local function fromArgument(context, button) apply(button:get()) end
local function fromList(context) local list = context:get(); if live(list) then apply(list.BtnMain) end end
local hooks = {
  {"BulkSelectionItem:HandleImgClicked", userChanged, true},
  {"BulkSelectionItemList:EstablishItems", fromList, true},
  {"BulkSelectionListPanel:SetMainButton", fromArgument, true},
  {"BulkSelectionButton:HandleBtn_Expand", fromButton, true},
  {"JHNeoUITradingVM:BulkSellItems", fromArgument},
  {"JHNeoUIDecompoVM:BulkPutItems", fromArgument}
}
local function noop() end
taskBulkSettings = function()
  for _, mode in pairs(modes) do flush(mode) end
  for _, hook in ipairs(hooks) do
    local name, handler, after = table.unpack(hook)
    if not hooked[name] then
      local path = "/Script/JH." .. name
      local method = StaticFindObject(path)
      if method and method:IsValid() then
        local function invoke(...)
          if applying then return end
          local ok, err = pcall(handler, ...)
          if not ok and not warned[name] then warned[name] = true; print("[GamepadTweaks] bulk settings: " .. name .. ": " .. tostring(err) .. "\n") end
        end
        hooked[name] = pcall(RegisterHook, path, after and noop or invoke, after and invoke or nil)
      end
    end
  end
end
taskBulkSettings()
end

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
  { every = 1,   fn = taskPadEv },
  { every = 1,   fn = taskStart },
  { every = 1,   fn = taskNav },
  { every = 1,   fn = taskObs },
  { every = 10,  fn = taskBackpack },
  { every = 1,   fn = taskHide },
  { every = 1,   fn = taskSpeed },
  { every = 50,  fn = taskAutoSave },
  { every = 1,   fn = taskWalkAppearance },
  { every = 5,   fn = taskGift },
  { every = 50,  fn = taskBulkSettings },
}
local tick = 0
local errCount = {}
function RUNTIME.leaveMap(level)
  local sameLevel = level and level:GetAddress() == RUNTIME.playing
  if sameLevel and inFight then WALK.afterFight = true end
  RUNTIME.playing, RUNTIME.events = false, 0
  RUNTIME.endSpeed(level)
  inFight, inBattle, lastBattle, ground.lv, pendingTravel = false, false, nil, nil, nil
  if lastMap ~= "0" and writeFile("map.flag", "0") then lastMap = "0" end
  writeBattleFlag()
  if START.pending then writeFile("start.ack", "0") end
  START.pending, START.vm, PRIMEWATCH.vis = nil, nil, false
  if arrival and (arrival.ready or not arrival.source) then arrival = nil end
  NAV.open, NAV.team, NAV.vm, NAV.views, NAV.im, NAV.sideCell, NAV.cells = false, nil, nil, nil, nil, nil, nil
  OBS.open, OBS.view, OBS.vm, OBS.bpView, OBS.grid, OBS.btn = false, nil, nil, nil, nil, nil
  MASKS.prime, MASKS.obs, PADEV = 0, 0, nil; navMask(0)
  BAG.observing, BAG.observedGrid, BAG.hidden, BAG.filtered = false, nil, {}, {}
  GIFT.vm, GIFT.root, GIFT.view, GIFT.grid, GIFT.nextRead = nil, nil, nil, nil, 0
  HIDE.vm, HIDE.root, HIDE.view, HIDE.grid, HIDE.info, HIDE.open, bp.open, bp.lit = nil, nil, nil, nil, {}, false, false, {}
  if not sameLevel then lastLevel, WALK.pawn, WALK.team, WALK.originals = nil, nil, nil, {} end
end
if RegisterLoadMapPreHook and RegisterLoadMapPostHook then
  RegisterLoadMapPostHook(function(engine, worldParam)
    RUNTIME.loading = false
    if RUNTIME.owner and arrival then
      local world = worldParam:get()
      if not live(world) or world:GetFName():ToString() ~= arrival.lv then arrival = nil end
    end
  end)
  RegisterLoadMapPreHook(function()
    if RUNTIME.owner and RUNTIME.playing then pcall(RUNTIME.beforeSpeedMap) end
    RUNTIME.loading = true
    if RUNTIME.owner and RUNTIME.playing then RUNTIME.leaveMap(nil) end
  end)
end
os.remove(DIR .. "teleport.req") -- do not replay requests from an earlier session
writeFile("map.flag", "0")
writeFile("battle.flag", "0")
writeFile("fight.flag", "0")
writeFile("prime.flag", "0"); os.remove(DIR .. "trig.req")
LoopInGameThreadWithDelay(20, function()
  if not runtimePoll() then return end
  if tick == 0 then print("[GamepadTweaks] scheduler: owner tick active\n") end
  tick = tick + 1
  local checked, controller, _, _, _, level = pcall(RUNTIME.player)
  if not checked or not controller then
    if RUNTIME.playing then RUNTIME.leaveMap(checked and level or nil) end
    if not checked and not RUNTIME.playerError then
      RUNTIME.playerError = true; print("[GamepadTweaks] player not ready: " .. tostring(controller) .. "\n")
    end
    if not RUNTIME.loading and tick % 50 == 0 then pcall(taskCmd) end
    return
  end
  RUNTIME.playerError = nil
  local address = level:GetAddress()
  if RUNTIME.playing and RUNTIME.playing ~= address then RUNTIME.leaveMap(nil) end
  RUNTIME.playing = address
  for i, t in ipairs(tasks) do
    if not RUNTIME.playing or RUNTIME.loading then break end
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
