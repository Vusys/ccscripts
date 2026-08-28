-- dig.lua
--
-- Motion, mining, and crash-recovery API for a turtle. Wraps turtle
-- movement with coordinate tracking (X=right, Y=up, Z=forward, R=
-- clockwise rotation in degrees), retry-and-dig-through movement, fuel
-- management, and save/resume state so a program built on this can
-- survive a reboot mid-job.
--
-- Loaded with require("dig"); returns a table of functions. All state
-- is closed over as upvalues -- nothing leaks into the global namespace
-- the way the old os.loadAPI version did.
--
-- Notable design choices vs. the program this replaces:
--   * Pure module: no top-level CLI argument handling here (that lives
--     in dig-cli.lua). require() must always get the same table back,
--     regardless of how the file happened to be invoked.
--   * saveCoords()/loadCoords() persist a 17th value ("extra") that
--     dig.lua itself ignores -- it's a place for a calling program to
--     stash one small piece of its own state across a reboot (see
--     getExtra()/setExtra()) instead of overloading an unrelated field.
--   * Blacklist routing (doBlacklist(true)) tries a single "go over,
--     then go under" detour when fwd() is blocked by a blacklisted
--     block, rather than digging it. It does not attempt an exhaustive
--     set of detours -- the guarantee this exists for is "never destroy
--     a blacklisted block", not "always find a path around it".
--   * dropNotFuel() no longer has coal-specific auto-crafting baked in;
--     see setCraftingHook() to add that back as an optional extension.
--   * saveClear() intentionally only deletes startup.lua, not
--     dig_save.cfg -- the last known position stays available for
--     diagnostics even after a clean run clears the auto-resume trigger.
--   * refuel() blocks indefinitely if no fuel is available in range.
--     That's deliberate: the turtle genuinely cannot proceed, and it
--     already reports this over flex.send() for a monitoring receiver.

local flex = require("flex")

local M = {}

-- ===========================================================================
-- Block classification lists (dig_options.cfg): "[key]" ... "[/key]"
-- sections, one keyword per line. A key containing ":" (e.g.
-- "minecraft:stone") must match a block/item name exactly; any other key
-- matches as a substring (handled by flex.isBlock/isItem).
-- ===========================================================================

local OPTIONS_FILE = "dig_options.cfg"

local DEFAULTS = {
  outputblocks = { "chest", "storage", "box", "turtle", "hopper", "dropper", "backpack" },
  blacklist = { "chest", "spawn", "hopper", "dropper", "portal", "turtle", "hive", "openblocks:grave" },
  buildingblocks = {
    "cobblestone", "minecraft:stone", "dirt", "netherrack", "basalt", "soul_s",
    "magma_block", "terracotta", "rock", "sandstone", "andesite", "diorite",
    "granite", "marble", "bricks", "smooth_stone", "glass",
  },
  dumplist = {
    "cobblestone", "deepslate", "dirt", "gravel", "andesite", "diorite", "granite",
    "netherrack", "soul_s", "magma_block", "rotten_flesh", "rock", "marble",
    "limestone", "soapstone", "dolomite", "gabbro", "scoria",
  },
  fluids = { "water", "lava", "acid", "poison", "sewage", "sludge", "blood" },
  -- "ore" alone (substring match) covers every vanilla ore name
  -- (iron_ore, deepslate_iron_ore, nether_quartz_ore, redstone_ore,
  -- ...) without needing to enumerate each one; ancient_debris is
  -- listed separately since its name doesn't contain "ore".
  ores = { "ore", "ancient_debris" },
}

local SECTION_KEYS = { "outputblocks", "blacklist", "buildingblocks", "dumplist", "fluids", "ores" }
local DUMPLIST_KEY = "dumplist"

local options = {}
for _, key in ipairs(SECTION_KEYS) do
  options[key] = {}
  for i, v in ipairs(DEFAULTS[key]) do
    options[key][i] = v
  end
end

local function optionsImport()
  local file = fs.open(OPTIONS_FILE, "r")
  if not file then
    return false
  end
  local section = nil
  local line = file.readLine()
  while line do
    local openKey = line:match("^%[(%w+)%]$")
    local closeKey = line:match("^%[/(%w+)%]$")
    if openKey and options[openKey] then
      section = openKey
      options[section] = {}
    elseif closeKey then
      section = nil
    elseif section then
      options[section][#options[section] + 1] = line
    end
    line = file.readLine()
  end
  file.close()
  return true
end

local function optionsExport()
  fs.delete(OPTIONS_FILE)
  local file = fs.open(OPTIONS_FILE, "w")
  if not file then
    error("dig: could not write " .. OPTIONS_FILE, 2)
  end
  file.writeLine("# dig API options -- block/item classification lists #")
  file.writeLine("")
  for _, key in ipairs(SECTION_KEYS) do
    file.writeLine("[" .. key .. "]")
    for _, entry in ipairs(options[key]) do
      file.writeLine(entry)
    end
    file.writeLine("[/" .. key .. "]")
    file.writeLine("")
  end
  file.close()
end

M.optionsImport = optionsImport
M.optionsExport = optionsExport

-- ===========================================================================
-- Position/orientation state.
-- ===========================================================================

local xdist, ydist, zdist, rdist = 0, 0, 0, 0
local xlast, ylast, zlast, rlast = -1, -1, -1, -1
local xmin, xmax, ymin, ymax, zmin, zmax = 0, 0, 0, 0, 0, 0
local lastmove = "r-"
local dugtotal = 0
local extra = ""

local function getx() return xdist end
local function gety() return ydist end
local function getz() return zdist end
local function getr() return rdist end
local function setx(x) xdist = x end
local function sety(y) ydist = y end
local function setz(z) zdist = z end
local function setr(r) rdist = r end

local function getxmin() return xmin end
local function getxmax() return xmax end
local function getymin() return ymin end
local function getymax() return ymax end
local function getzmin() return zmin end
local function getzmax() return zmax end
local function setxmin(x) xmin = x end
local function setxmax(x) xmax = x end
local function setymin(y) ymin = y end
local function setymax(y) ymax = y end
local function setzmin(z) zmin = z end
local function setzmax(z) zmax = z end

local function getxlast() return xlast end
local function getylast() return ylast end
local function getzlast() return zlast end
local function getrlast() return rlast end
local function setxlast(x) xlast = x end
local function setylast(y) ylast = y end
local function setzlast(z) zlast = z end
local function setrlast(r) rlast = r end

local function getlast() return lastmove end
local function setlast(lm) lastmove = lm end

local function getdug() return dugtotal end
local function setdug(d) dugtotal = d end

local function getExtra() return extra end
local function setExtra(s) extra = tostring(s or "") end

M.getx, M.gety, M.getz, M.getr = getx, gety, getz, getr
M.setx, M.sety, M.setz, M.setr = setx, sety, setz, setr
M.getxmin, M.getxmax, M.getymin, M.getymax, M.getzmin, M.getzmax =
  getxmin, getxmax, getymin, getymax, getzmin, getzmax
M.setxmin, M.setxmax, M.setymin, M.setymax, M.setzmin, M.setzmax =
  setxmin, setxmax, setymin, setymax, setzmin, setzmax
M.getxlast, M.getylast, M.getzlast, M.getrlast = getxlast, getylast, getzlast, getrlast
M.setxlast, M.setylast, M.setzlast, M.setrlast = setxlast, setylast, setzlast, setrlast
M.getlast, M.setlast = getlast, setlast
M.getdug, M.setdug = getdug, setdug
M.getExtra, M.setExtra = getExtra, setExtra

-- ===========================================================================
-- Save / crash-recovery.
-- ===========================================================================

local SAVE_FILE = "dig_save.cfg"
local STARTUP_FILE = "startup.lua"

-- 17 values, in this exact order -- goto() and any external caller may
-- depend on it, so it is additive-only (the 17th "extra" field is new;
-- 1-16 are unchanged).
local function location()
  return {
    xdist, ydist, zdist, rdist,
    xmin, xmax, ymin, ymax, zmin, zmax,
    xlast, ylast, zlast, rlast,
    lastmove, dugtotal, extra,
  }
end

-- Writes each value on its own line, flushing after the 4th (rdist) so a
-- crash mid-write still leaves position+heading recoverable.
local function saveCoords(loc, saveFile)
  loc = loc or location()
  saveFile = saveFile or SAVE_FILE
  local file = fs.open(saveFile, "w")
  if not file then
    return false
  end
  for i = 1, 4 do
    file.writeLine(tostring(loc[i]))
  end
  file.flush()
  for i = 5, #loc do
    file.writeLine(tostring(loc[i]))
  end
  file.close()
  return true
end

-- Tolerates a missing/partial file: any field not present keeps its
-- current in-memory value.
local function loadCoords(saveFile)
  saveFile = saveFile or SAVE_FILE
  local file = fs.open(saveFile, "r")
  if not file then
    return false
  end

  local function nextNum(current)
    return tonumber(file.readLine()) or current
  end

  xdist, ydist, zdist, rdist = nextNum(xdist), nextNum(ydist), nextNum(zdist), nextNum(rdist)
  xmin, xmax = nextNum(xmin), nextNum(xmax)
  ymin, ymax = nextNum(ymin), nextNum(ymax)
  zmin, zmax = nextNum(zmin), nextNum(zmax)
  xlast, ylast, zlast, rlast = nextNum(xlast), nextNum(ylast), nextNum(zlast), nextNum(rlast)
  lastmove = file.readLine() or lastmove
  dugtotal = nextNum(dugtotal)
  extra = file.readLine() or extra

  file.close()
  return true
end

local function saveExists()
  return fs.exists(STARTUP_FILE) and fs.exists(SAVE_FILE)
end

-- Only clears the auto-resume trigger, not dig_save.cfg -- see the
-- module header comment.
local function saveClear()
  if fs.exists(STARTUP_FILE) then
    fs.delete(STARTUP_FILE)
  end
end

-- Writes a startup.lua that counts down and re-invokes `command` with
-- `args`, each as its own separately-quoted shell.run() argument (not one
-- concatenated command-line string), so args containing spaces round-trip
-- correctly.
local function makeStartup(command, args)
  args = args or {}

  local file = fs.open(STARTUP_FILE, "w")
  if not file then
    error("dig: could not write " .. STARTUP_FILE, 2)
  end

  local shown = { command }
  for _, a in ipairs(args) do
    shown[#shown + 1] = tostring(a)
  end
  file.writeLine("print(" .. string.format("%q", "> " .. table.concat(shown, " ")) .. ")")
  file.writeLine("for i = 5, 1, -1 do")
  file.writeLine('  term.write(i .. " ")')
  file.writeLine("  sleep(1)")
  file.writeLine("end")
  file.writeLine("print()")

  local call = { string.format("%q", command) }
  for _, a in ipairs(args) do
    call[#call + 1] = string.format("%q", tostring(a))
  end
  file.writeLine("shell.run(" .. table.concat(call, ", ") .. ")")

  file.close()
end

M.saveExists = saveExists
M.saveClear = saveClear
M.clearSave = saveClear
M.location = location
M.saveCoords = saveCoords
M.loadCoords = loadCoords
M.makeStartup = makeStartup

-- ===========================================================================
-- Position bookkeeping. Every successful single-step move calls this,
-- which also unconditionally writes dig_save.cfg -- one file write per
-- atomic move, trading I/O cost for crash-safety.
-- ===========================================================================

local function update(kind)
  if kind == "left" then
    rdist, rlast, lastmove = (rdist - 90) % 360, -1, "r-"
  elseif kind == "right" then
    rdist, rlast, lastmove = (rdist + 90) % 360, 1, "r+"
  elseif kind == "fwd" or kind == "back" then
    local delta = (kind == "fwd") and 1 or -1
    local heading = rdist % 360
    if heading == 0 then
      zdist, zlast, lastmove = zdist + delta, delta, (delta > 0) and "z+" or "z-"
    elseif heading == 90 then
      xdist, xlast, lastmove = xdist + delta, delta, (delta > 0) and "x+" or "x-"
    elseif heading == 180 then
      zdist, zlast, lastmove = zdist - delta, -delta, (-delta > 0) and "z+" or "z-"
    elseif heading == 270 then
      xdist, xlast, lastmove = xdist - delta, -delta, (-delta > 0) and "x+" or "x-"
    end
  elseif kind == "up" then
    ydist, ylast, lastmove = ydist + 1, 1, "y+"
  elseif kind == "down" then
    ydist, ylast, lastmove = ydist - 1, -1, "y-"
  end

  if xdist < xmin then xmin = xdist end
  if xdist > xmax then xmax = xdist end
  if ydist < ymin then ymin = ydist end
  if ydist > ymax then ymax = ydist end
  if zdist < zmin then zmin = zdist end
  if zdist > zmax then zmax = zdist end

  saveCoords()
end

-- ===========================================================================
-- Fuel.
-- ===========================================================================

local FUEL_FILE = "dig_fuel.cfg"
local fuelSlot = { 1, 16 }
local fuelvalue = {}

local function loadFuelValues()
  local file = fs.open(FUEL_FILE, "r")
  if not file then
    return
  end
  local name = file.readLine()
  while name do
    local value = tonumber(file.readLine())
    if value then
      fuelvalue[name] = value
    end
    name = file.readLine()
  end
  file.close()
end

local function getFuelSlot()
  return fuelSlot[1], fuelSlot[2]
end

local function setFuelSlot(a, b)
  if a == nil then
    return false
  end
  b = b or a
  if a > b then
    a, b = b, a
  end
  fuelSlot = { a, b }
  return true
end

-- Blocks until fuel level >= target. See the module header comment for
-- why this is allowed to wait forever.
local function refuel(target)
  target = math.min(target or 1, turtle.getFuelLimit())
  local originalSlot = turtle.getSelectedSlot()
  local warned = false

  while turtle.getFuelLevel() < target do
    local refueled = false
    for slot = fuelSlot[1], fuelSlot[2] do
      turtle.select(slot)
      if turtle.refuel(1) then
        refueled = true
        break
      end
    end
    if not refueled then
      if not warned then
        local slotDesc = (fuelSlot[1] == fuelSlot[2]) and tostring(fuelSlot[1])
          or (fuelSlot[1] .. "-" .. fuelSlot[2])
        flex.send("Waiting for fuel in slot(s) " .. slotDesc .. "...", colors.orange)
        warned = true
      end
    end
  end

  if warned then
    flex.send("Thanks!", colors.lime)
  end
  turtle.select(originalSlot)
end

-- Empirically measures (and caches, in-memory and in dig_fuel.cfg) the
-- burn value of whatever item is in `slot`.
local function checkFuelValue(slot)
  slot = (type(slot) == "number") and slot or turtle.getSelectedSlot()
  if turtle.getItemCount(slot) == 0 then
    return 0
  end

  local name = turtle.getItemDetail(slot).name
  if fuelvalue[name] then
    return fuelvalue[name]
  end

  local originalSlot = turtle.getSelectedSlot()
  local before = turtle.getFuelLevel()
  turtle.select(slot)
  local consumed = turtle.refuel(1)
  local after = turtle.getFuelLevel()
  turtle.select(originalSlot)

  if not consumed then
    return 0
  end

  local value = after - before
  fuelvalue[name] = value

  local file = fs.open(FUEL_FILE, "a")
  if file then
    file.writeLine(name)
    file.writeLine(tostring(value))
    file.close()
  end

  if turtle.getItemCount(slot) == 0 then
    return 0
  end
  return value
end

M.getFuelSlot = getFuelSlot
M.setFuelSlot = setFuelSlot
M.refuel = refuel
M.checkFuelValue = checkFuelValue

-- ===========================================================================
-- Reserved building-block slot.
-- ===========================================================================

local blockSlot = 0
local blockStacks = 1
local craftingHook = nil

local function getBlockSlot() return blockSlot end
local function setBlockSlot(n) blockSlot = n end
local function getBlockStacks() return blockStacks end
local function setBlockStacks(n) blockStacks = n end

local function isBuildingBlock(slot)
  return flex.isItem(options.buildingblocks, slot)
end

-- Restocks blockSlot from any other slot holding a building block if
-- it's empty, or relocates whatever's in it if it turns out not to be a
-- building block.
local function checkBlocks()
  if blockSlot == 0 then
    return
  end

  if turtle.getItemCount(blockSlot) > 0 and not isBuildingBlock(blockSlot) then
    for slot = blockSlot + 1, 16 do
      if turtle.getItemCount(slot) == 0 then
        turtle.select(blockSlot)
        turtle.transferTo(slot)
        break
      end
    end
  end

  if turtle.getItemCount(blockSlot) == 0 then
    for slot = 1, 16 do
      if slot ~= blockSlot and isBuildingBlock(slot) then
        turtle.select(slot)
        turtle.transferTo(blockSlot)
        break
      end
    end
  end

  flex.condense(blockSlot)
  turtle.select(blockSlot)
end

-- Places from blockSlot without going through place()'s fluid-retry/stuck
-- logic -- if there's lava in `dir`, seal it and move on.
local function blockLava(dir)
  dir = dir or "fwd"
  if not flex.isBlock("lava", dir) then
    return
  end
  local originalSlot = turtle.getSelectedSlot()
  turtle.select(blockSlot)
  if dir == "up" then
    turtle.placeUp()
  elseif dir == "down" then
    turtle.placeDown()
  else
    turtle.place()
  end
  turtle.select(originalSlot)
end

local function blockLavaUp() blockLava("up") end
local function blockLavaDown() blockLava("down") end

local function setCraftingHook(fn)
  craftingHook = fn
end

M.getBlockSlot = getBlockSlot
M.setBlockSlot = setBlockSlot
M.getBlockStacks = getBlockStacks
M.setBlockStacks = setBlockStacks
M.isBuildingBlock = isBuildingBlock
M.checkBlocks = checkBlocks
M.blockLava = blockLava
M.blockLavaUp = blockLavaUp
M.blockLavaDown = blockLavaDown
M.setCraftingHook = setCraftingHook

-- ===========================================================================
-- Blacklist / attack toggles, bedrock log, stuck state.
-- ===========================================================================

local doblacklist = false
local attack = false
local knownBedrock = {}
local stuck = false
local stuckDir = "none"

local function doBlacklist(x) doblacklist = (x ~= false) end
local function doAttack(x) attack = (x ~= false) end
local function getKnownBedrock() return knownBedrock end
local function isStuck() return stuck end
local function getStuckDir() return stuckDir end

local function isChest(dir) return flex.isBlock(options.outputblocks, dir) end
local function isChestUp() return isChest("up") end
local function isChestDown() return isChest("down") end

M.doBlacklist = doBlacklist
M.doAttack = doAttack
M.getKnownBedrock = getKnownBedrock
M.isStuck = isStuck
M.getStuckDir = getStuckDir
M.isChest = isChest
M.isChestUp = isChestUp
M.isChestDown = isChestDown

-- ===========================================================================
-- Digging.
-- ===========================================================================

local STUCK_TIMEOUT = 20 -- real-world seconds

-- os.time() returns in-game hours as a fraction of a day; convert elapsed
-- hours to real seconds at the standard 20-real-minutes-per-day ratio.
local function elapsedSeconds(startTime)
  return (os.time() - startTime) / 24 * 20 * 60
end

-- Built lazily (not as a `turtle.dig` literal above) so merely
-- require()ing this module doesn't crash on a computer with no turtle
-- API -- only actually calling a motion function does, which is the
-- correct place for that to fail.
local DIG = {}
if turtle then
  DIG.fwd = turtle.dig
  DIG.up = turtle.digUp
  DIG.down = turtle.digDown
end

-- Digs in `dir` until the way is clear or `stuck` is already set,
-- bailing out after STUCK_TIMEOUT even if `digFn()` keeps succeeding --
-- a falling block (sand/gravel) or a hopper/dispenser feeding the
-- space can otherwise keep this digging forever, since "the block keeps
-- coming back" never makes digFn() return false on its own. Returns
-- false if it gave up still blocked, true if the space actually
-- cleared (or was already clear).
local function digUntilClear(digFn, startTime)
  while digFn() and not stuck do
    dugtotal = dugtotal + 1
    if elapsedSeconds(startTime) > STUCK_TIMEOUT then
      return false
    end
  end
  return true
end

-- Reaches into `dir` and digs -- does not move there itself (see
-- digThrough() for that). Gives up (without setting `stuck`; nothing
-- here is blocking forward progress, just this one space) if the block
-- keeps regenerating for a full STUCK_TIMEOUT.
local function dig(dir)
  local digFn = DIG[dir or "fwd"] or turtle.dig
  if not digUntilClear(digFn, os.time()) then
    flex.send(
      "#EGave up digging " .. (dir or "fwd") .. " after #F" .. STUCK_TIMEOUT
        .. "#Es -- block kept reappearing (falling sand/gravel?).",
      colors.orange
    )
  end
end

local function digUp() dig("up") end
local function digDown() dig("down") end

M.dig = dig
M.digUp = digUp
M.digDown = digDown

-- ===========================================================================
-- Movement.
-- ===========================================================================

local function left(n)
  n = n or 1
  if n < 0 then
    return M.right(-n)
  end
  for _ = 1, n do
    turtle.turnLeft()
    update("left")
  end
  return true
end

local function right(n)
  n = n or 1
  if n < 0 then
    return left(-n)
  end
  for _ = 1, n do
    turtle.turnRight()
    update("right")
  end
  return true
end

M.left = left
M.right = right

local function attackTowards(dir)
  if dir == "up" then
    turtle.attackUp()
  elseif dir == "down" then
    turtle.attackDown()
  else
    turtle.attack()
  end
end

-- Digs in `dir` (with a real-time stuck timeout) until the way is clear,
-- then moves. Does not consult the blacklist -- callers check that first.
local function digThrough(dir)
  local moveFn = (dir == "up" and turtle.up) or (dir == "down" and turtle.down) or turtle.forward
  local digFn = DIG[dir]
  local startTime = os.time()

  while not moveFn() do
    digUntilClear(digFn, startTime)
    if attack then
      attackTowards(dir)
    end
    if elapsedSeconds(startTime) > STUCK_TIMEOUT then
      local x, y, z = getx(), gety(), getz()
      flex.send(
        "#EUnbreakable block detected#0: {#8" .. x .. "#0,#8" .. y .. "#0,#8" .. z .. "#0}",
        colors.red
      )
      knownBedrock[#knownBedrock + 1] = { x = x, y = y, z = z }
      stuck = true
      stuckDir = dir
      return false
    end
  end

  update(dir)
  return true
end

local function up(n)
  n = n or 1
  if n < 0 then
    return M.down(-n)
  end
  for _ = 1, n do
    refuel(1)
    if turtle.up() then
      update("up")
    else
      if doblacklist and flex.isBlock(options.blacklist, "up") then
        stuck, stuckDir = true, "up"
        return false
      end
      stuck = false
      if not digThrough("up") then
        return false
      end
    end
  end
  return true
end

local function down(n)
  n = n or 1
  if n < 0 then
    return up(-n)
  end
  for _ = 1, n do
    refuel(1)
    if turtle.down() then
      update("down")
    else
      if doblacklist and flex.isBlock(options.blacklist, "down") then
        stuck, stuckDir = true, "down"
        return false
      end
      stuck = false
      if not digThrough("down") then
        return false
      end
    end
  end
  return true
end

M.up = up
M.down = down

local function fwd(n)
  n = n or 1
  if n < 0 then
    return M.back(-n)
  end
  for _ = 1, n do
    refuel(1)
    if turtle.forward() then
      update("fwd")
    else
      if doblacklist and flex.isBlock(options.blacklist, "fwd") then
        -- Route around rather than destroy it: try going over, then
        -- under. If neither works, give up in place.
        local routed = (up(1) and fwd(1) and down(1)) or (down(1) and fwd(1) and up(1))
        if not routed then
          stuck, stuckDir = true, "fwd"
          return false
        end
      else
        stuck = false
        if not digThrough("fwd") then
          return false
        end
      end
    end
  end
  return true
end

local function back(n)
  n = n or 1
  if n < 0 then
    return fwd(-n)
  end

  local remaining = n
  if turtle.back() then
    update("back")
    remaining = remaining - 1
  end

  if remaining > 0 then
    -- turtle.back() can't dig through anything -- turn around, use
    -- fwd()'s full retry/blacklist/stuck handling, then turn back.
    right(2)
    local ok = fwd(remaining)
    right(2)
    return ok
  end
  return true
end

M.fwd = fwd
M.back = back

-- ===========================================================================
-- Placement.
-- ===========================================================================

local PLACE = {}
if turtle then
  PLACE.fwd = turtle.place
  PLACE.up = turtle.placeUp
  PLACE.down = turtle.placeDown
end

local function place(dir)
  dir = dir or "fwd"
  local placeFn = PLACE[dir]
  local startTime = os.time()

  while not placeFn() do
    if not flex.isBlock(options.fluids, dir) then
      return false
    end
    if attack then
      attackTowards(dir)
    end
    if elapsedSeconds(startTime) > STUCK_TIMEOUT then
      local x, y, z = getx(), gety(), getz()
      flex.send(
        "#EEdge of world detected#0: {#8" .. x .. "#0,#8" .. y .. "#0,#8" .. z .. "#0}",
        colors.red
      )
      knownBedrock[#knownBedrock + 1] = { x = x, y = y, z = z }
      stuck, stuckDir = true, dir
      return false
    end
  end

  if turtle.getSelectedSlot() == blockSlot then
    checkBlocks()
  end
  return true
end

local function placeUp() return place("up") end
local function placeDown() return place("down") end

M.place = place
M.placeUp = placeUp
M.placeDown = placeDown

-- ===========================================================================
-- Absolute-position navigation.
-- ===========================================================================

local function gotor(r)
  local delta = (r - rdist) % 360
  if delta == 0 then
    return true
  elseif delta == 90 then
    return right(1)
  elseif delta == 180 then
    return left(rlast * 2)
  elseif delta == 270 then
    return left(1)
  else
    error("Invalid rotation parameter", 2)
  end
end

local function gotoy(y)
  while ydist < y do
    if not up(1) then return false end
  end
  while ydist > y do
    if not down(1) then return false end
  end
  return true
end

local function gotox(x)
  if x == xdist then
    return true
  elseif x > xdist then
    if rdist % 360 == 270 then
      return back(x - xdist)
    end
    gotor(90)
    return fwd(x - xdist)
  else
    if rdist % 360 == 90 then
      return back(xdist - x)
    end
    gotor(270)
    return fwd(xdist - x)
  end
end

local function gotoz(z)
  if z == zdist then
    return true
  elseif z > zdist then
    if rdist % 360 == 180 then
      return back(z - zdist)
    end
    gotor(0)
    return fwd(z - zdist)
  else
    if rdist % 360 == 0 then
      return back(zdist - z)
    end
    gotor(180)
    return fwd(zdist - z)
  end
end

-- Also accepts the 16/17-value save/location array as its sole argument,
-- reading x/y/z/r/lastmove from indices [1..4] and [15].
local function gotoLocation(x, y, z, r, lm)
  if type(x) == "table" then
    local loc = x
    x, y, z, r, lm = loc[1], loc[2], loc[3], loc[4], loc[15]
  end
  x, y, z, r = x or 0, y or 0, z or 0, r or 0

  local okX = gotox(x)
  local okZ = gotoz(z)
  local okR = gotor(r)
  local okY = gotoy(y)

  if lm then
    lastmove = lm
  end

  return okX and okZ and okR and okY
end

M.gotor = gotor
M.gotoy = gotoy
M.gotox = gotox
M.gotoz = gotoz
M.goto = gotoLocation

-- ===========================================================================
-- Vein-following mining: when a strip-mining program (quarry.lua,
-- tunnel.lua, ...) walks past an ore block, mineVein() follows every
-- block connected to it (6-connectivity: fwd/back/left/right/up/down,
-- matched against the "ores" dig_options.cfg list -- see DEFAULTS.ores
-- above) before returning to the exact position and facing the turtle
-- called it from, so the caller's own position bookkeeping never needs
-- to know a detour happened.
--
-- Recursive rather than an explicit worklist: real ore veins are small
-- (a handful to a few dozen blocks), well within a safe call-stack
-- depth, and the recursive shape is what makes "explore, then
-- backtrack exactly one step" straightforward -- each recursive call
-- corresponds to exactly one physical move in and, on return, one move
-- back out. MAX_VEIN_BLOCKS is a defensive cap in case an overly broad
-- "ores" list (or an unusually large real vein) would otherwise have
-- this wander far from the caller's original path.
-- ===========================================================================

local MAX_VEIN_BLOCKS = 64

local function veinKey(x, y, z)
  return x .. "," .. y .. "," .. z
end

-- Explores every unvisited ore-matching neighbor of the turtle's
-- current position, recursing into each and backing out afterward.
-- Always leaves the turtle back at the position/facing it was called
-- with.
local function exploreVein(visited)
  visited[veinKey(xdist, ydist, zdist)] = true
  if visited.count >= MAX_VEIN_BLOCKS then
    return
  end

  if flex.isBlock(options.ores, "up") and not visited[veinKey(xdist, ydist + 1, zdist)] then
    if up(1) then
      visited.count = visited.count + 1
      exploreVein(visited)
      down(1)
    end
  end

  if flex.isBlock(options.ores, "down") and not visited[veinKey(xdist, ydist - 1, zdist)] then
    if down(1) then
      visited.count = visited.count + 1
      exploreVein(visited)
      up(1)
    end
  end

  -- Absolute headings, not left()/right() turns relative to whatever
  -- the turtle happens to be facing -- gotor() already knows how to
  -- get from any heading to any other in at most one turn.
  local startR = rdist
  for _, r in ipairs({ 0, 90, 180, 270 }) do
    gotor(r)
    local nx, nz = xdist, zdist
    if r == 0 then nz = nz + 1
    elseif r == 90 then nx = nx + 1
    elseif r == 180 then nz = nz - 1
    else nx = nx - 1 end

    if flex.isBlock(options.ores, "fwd") and not visited[veinKey(nx, ydist, nz)] then
      if fwd(1) then
        visited.count = visited.count + 1
        exploreVein(visited)
        -- The space behind is where we just came from -- always
        -- empty, so turtle.back() (what back(1) reduces to here)
        -- returns without needing to turn around first.
        back(1)
      end
    end
  end
  gotor(startR)
end

-- dir: which direction to start from (default "fwd", i.e. whatever the
-- turtle currently faces) -- a no-op returning true if that block
-- isn't ore. Returns false (leaving the turtle wherever movement
-- actually stopped) if digging/moving into the vein got stuck partway
-- through, same convention as fwd()/up()/down().
local function mineVein(dir)
  dir = dir or "fwd"
  if not flex.isBlock(options.ores, dir) then
    return true
  end

  local moved
  if dir == "up" then
    moved = up(1)
  elseif dir == "down" then
    moved = down(1)
  else
    moved = fwd(1)
  end
  if not moved then
    return false
  end

  exploreVein({ count = 1 })

  local backOK
  if dir == "up" then
    backOK = down(1)
  elseif dir == "down" then
    backOK = up(1)
  else
    backOK = back(1)
  end

  return backOK and not stuck
end

M.mineVein = mineVein

-- ===========================================================================
-- Dump list management + dumping.
-- ===========================================================================

local function resetDumpList(n)
  options[DUMPLIST_KEY] = {}
  if n ~= 0 then
    for i, v in ipairs(DEFAULTS[DUMPLIST_KEY]) do
      options[DUMPLIST_KEY][i] = v
    end
  end
end

local function addToDumpList(key)
  local list = options[DUMPLIST_KEY]
  list[#list + 1] = tostring(key)
end

local function removeFromDumpList(key)
  local kept = {}
  for _, entry in ipairs(options[DUMPLIST_KEY]) do
    if not entry:find(key, 1, true) then
      kept[#kept + 1] = entry
    end
  end
  options[DUMPLIST_KEY] = kept
end

local function isDumpItem(x)
  return flex.isItem(options[DUMPLIST_KEY], x)
end

-- Keeps the first `blockStacks` building-block slots encountered as
-- reserve; unconditionally drops everything else on the dumplist. These
-- are two independent conditions (not one shared counter), so the
-- outcome doesn't depend on inventory iteration order.
local function doDump(dir)
  dir = dir or "fwd"
  local originalSlot = turtle.getSelectedSlot()
  local reserved = 0

  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      local isReserve = isBuildingBlock(slot) and reserved < blockStacks
      if isReserve then
        reserved = reserved + 1
      elseif isDumpItem(slot) then
        if dir == "up" then
          turtle.dropUp()
        elseif dir == "down" then
          turtle.dropDown()
        else
          turtle.drop()
        end
      end
    end
  end

  checkBlocks()
  flex.condense(blockSlot)
  turtle.select(originalSlot)
end

local function doDumpUp() doDump("up") end
local function doDumpDown() doDump("down") end

M.resetDumpList = resetDumpList
M.addToDumpList = addToDumpList
M.removeFromDumpList = removeFromDumpList
M.isDumpItem = isDumpItem
M.doDump = doDump
M.doDumpUp = doDumpUp
M.doDumpDown = doDumpDown

-- ===========================================================================
-- Unload everything but fuel/reserved blocks into a chest in front.
-- ===========================================================================

local function dropNotFuel()
  flex.condense(1)

  local waited = false
  while not isChest() do
    if not waited then
      flex.send("Output inventory not found!", colors.orange)
      waited = true
    end
    sleep(1)
  end

  local reserved = 0
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      local keepAsBuilding = blockSlot ~= 0 and isBuildingBlock(slot) and reserved < blockStacks
      if keepAsBuilding then
        reserved = reserved + 1
      elseif checkFuelValue(slot) == 0 then
        turtle.drop()
      end
    end
  end

  checkBlocks()

  if craftingHook then
    craftingHook()
  end

  -- Pick up any surplus fuel sitting above (e.g. a hopper).
  turtle.suckUp()

  -- Recycle single buckets one at a time rather than letting them pile up.
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 1 and flex.isItem("bucket", slot) then
      turtle.select(slot)
      turtle.refuel()
      if turtle.getItemCount(slot) > 0 then
        turtle.drop()
      end
    end
  end

  -- Consolidate whichever fuel type has the highest total burn value
  -- currently on hand into slot 1.
  local totals = {}
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      local value = checkFuelValue(slot)
      if value > 0 then
        local name = turtle.getItemDetail(slot).name
        totals[name] = (totals[name] or 0) + value * turtle.getItemCount(slot)
      end
    end
  end

  local bestFuel, bestValue = nil, 0
  for name, value in pairs(totals) do
    if value > bestValue then
      bestFuel, bestValue = name, value
    end
  end

  if bestFuel then
    local slot1 = turtle.getItemDetail(1)
    if turtle.getItemCount(1) > 0 and (not slot1 or slot1.name ~= bestFuel) then
      for slot = 2, 16 do
        if turtle.getItemCount(slot) == 0 then
          turtle.select(1)
          turtle.transferTo(slot)
          break
        end
      end
    end
    for slot = 2, 16 do
      local detail = turtle.getItemDetail(slot)
      if detail and detail.name == bestFuel then
        turtle.select(slot)
        turtle.transferTo(1)
      end
    end
  end

  -- Deposit surplus fuel beyond the reserved fuel slot range up above.
  for slot = fuelSlot[1] + 1, fuelSlot[2] do
    if turtle.getItemCount(slot) > 0 and checkFuelValue(slot) > 0 then
      turtle.select(slot)
      turtle.dropUp()
    end
  end

  if turtle.getItemCount(16) > 0 then
    flex.send("Inventory full!", colors.orange)
    turtle.select(16)
    while not turtle.drop() do
      sleep(5)
    end
    return dropNotFuel()
  end
end

M.dropNotFuel = dropNotFuel

-- ===========================================================================
-- Module init.
-- ===========================================================================

if not optionsImport() then
  optionsExport()
end
loadFuelValues()

return M
