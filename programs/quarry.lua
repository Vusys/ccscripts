-- quarry.lua
--
-- Strip-mines a rectangular volume, layer by layer, in a boustrophedon
-- (zigzag) sweep. Survives a reboot mid-job via dig.lua's position save.
--
-- Usage: quarry <length> [width] [depth] [skip <N>] [dump] [nolava] [nether]
--   length   required. Z-axis size of the quarry.
--   width    optional, defaults to length. X-axis size.
--   depth    optional (only read if `width` was numeric), defaults to
--            just short of world height. How far down to mine, measured
--            from the turtle's starting Y.
--   skip <N> start N layers below the surface instead of at Y=0 (skips
--            mining overburden that isn't worth clearing).
--   dump     automatically dump dumplist-matching items to a chest
--            sideways when the inventory fills up.
--   nolava   disable placing blocks to seal lava at the quarry's edges
--            (on by default) and free the reserved building-block slot.
--   nether   reserve 4 stacks of building block instead of 1 (nether
--            quarries tend to hit lava a lot more often).
--
-- Resumability note: unlike the version this replaces, the zigzag sweep
-- direction (which way X advances per layer, which way Z sweeps per
-- column) is computed purely from the current layer/column's position
-- parity -- not from any separately-persisted direction flag. That
-- removes the need to smuggle extra state through an unrelated dig.lua
-- field (the old code pushed the rotation value out of its normal
-- 0-359 range to encode a "just started a new layer" boolean). A
-- mid-layer reboot simply replays that layer's sweep from its start
-- column, which is safe (already-cleared cells are just air, so
-- re-visiting them costs a little time but changes nothing) and needs
-- no bookkeeping beyond dig.lua's own position tracking.

local dig = require("dig")
local flex = require("flex")
local job = require("job")

local WORLD_HEIGHT = 384

-- ===========================================================================
-- Arguments. Validated in full *before* anything touches saved state --
-- an invalid invocation should never leave a startup.lua/dig_save.cfg
-- behind for the next boot to stumble over.
-- ===========================================================================

local args = { ... }
if #args < 1 then
  flex.printColors(
    "quarry <length> [width] [depth] [skip <N>] [dump] [nolava] [nether]",
    colors.lightBlue
  )
  return
end

local length = tonumber(args[1])
local widthArg = tonumber(args[2])
local width = widthArg or length
local depth = widthArg and tonumber(args[3]) or nil
depth = depth or (WORLD_HEIGHT - 1)

local skip = 0
local dodumps = false
local lava = true
local nether = false

for i, a in ipairs(args) do
  if a == "skip" then
    skip = tonumber(args[i + 1]) or skip
  elseif a == "dump" then
    dodumps = true
  elseif a == "nolava" then
    lava = false
  elseif a == "nether" then
    nether = true
  end
end

if not length or not width or not depth
  or length < 1 or width < 1 or depth < 1 or skip < 0
then
  flex.send("Invalid dimensions", colors.red)
  return
end

-- ===========================================================================
-- Set up dig.lua for this job, then hook into its save/resume mechanism.
-- ===========================================================================

if lava then
  dig.setBlockSlot(2)
  if nether then
    dig.setBlockStacks(4)
  end
else
  dig.setBlockSlot(0)
end

if dig.saveExists() then
  dig.loadCoords()
end
dig.makeStartup("quarry", args)

if -skip < dig.getymin() then
  dig.setymin(-skip)
end

flex.send(
  "#B Quarry: #F" .. length .. "#Bx#F" .. width .. "#Bx#F" .. depth
    .. (skip > 0 and ("#B, skip #F" .. skip) or "")
)

-- ===========================================================================
-- Job scaffold: fuel/inventory/pause housekeeping and the wireless status
-- heartbeat for a companion program like programs/monitor.lua, shared with
-- every other job-shaped program via lib/job.lua. A no-op broadcast if
-- there's no modem, so this is always safe to call.
-- ===========================================================================

local totalToMine = length * width * math.max(depth - skip, 1)

local j = job.new({
  kind = "quarry",
  workingState = "mining",
  dump = dodumps,
  fuelEstimate = function() return (length + width + depth + 1) * 2 end,
  total = totalToMine,
  extra = function()
    return { length = length, width = width, depth = depth, skip = skip }
  end,
})

j.broadcast("mining")

-- ===========================================================================
-- Housekeeping run at every mined cell.
-- ===========================================================================

local function checkLava()
  if not lava then
    return
  end

  local x, z = dig.getx(), dig.getz()
  local facing = dig.getr()

  if x == 0 then
    dig.gotor(270)
    dig.blockLava()
  end
  if x == width - 1 then
    dig.gotor(90)
    dig.blockLava()
  end
  if z == 0 then
    dig.gotor(180)
    dig.blockLava()
  end
  if z == length - 1 then
    dig.gotor(0)
    dig.blockLava()
  end

  dig.gotor(facing)
  dig.blockLavaUp()
  dig.blockLavaDown()
end

-- lib/job.lua's checkProgress() already handles the dug-count milestone
-- (flex.send + broadcast) and the time-throttled heartbeat otherwise;
-- quarry additionally wants a y-depth milestone, which is specific
-- enough to this program (not every job descends through a fixed
-- depth) that it stays local rather than living in job.lua.
local lastReportedY = dig.gety()

local function checkProgress()
  local y = dig.gety()
  if lastReportedY - y >= 5 then
    lastReportedY = y
    flex.send("#8Progress: #Fy=" .. y)
    j.broadcast("mining")
  end
  j.checkProgress()
end

-- ===========================================================================
-- Mining.
-- ===========================================================================

-- Sweeps Z from zFrom to zTo (inclusive, stepping by zStep) at column x.
local function mineColumn(x, zFrom, zTo, zStep)
  -- Get to the exact start of this column first -- gotox() alone isn't
  -- enough: it only moves in X, so without this the sweep below starts
  -- from wherever the turtle happens to physically be (correct only for
  -- the very first column ever, by coincidence), not from zFrom.
  if not dig.gotox(x) then
    return false
  end
  if not dig.gotoz(zFrom) then
    return false
  end
  -- gotox()/gotoz() only turn to face the axis they actually have to
  -- move along, and leave the turtle facing however it last did
  -- otherwise -- fwd() below moves in whatever direction the turtle
  -- currently faces, not "along Z" by assumption, so this must
  -- explicitly (re)face Z before the sweep starts regardless. Skipping
  -- this turned some columns into X moves instead of Z moves.
  if not dig.gotor(zStep > 0 and 0 or 180) then
    return false
  end

  local z = zFrom
  while true do
    checkLava()
    checkProgress()
    j.checkHalt()
    j.checkFuel()
    j.checkInv()
    if dig.isStuck() then
      return false
    end

    if z == zTo then
      break
    end
    if not dig.fwd(1) then
      return false
    end
    if dig.isStuck() then
      return false
    end
    z = z + zStep
  end
  return true
end

-- Sweeps the whole X-Z footprint at the current Y. Which edge X starts
-- from alternates by layer (so consecutive layers connect without a
-- long return trip); which edge Z starts from alternates by column for
-- the same reason.
local function mineLayer(y)
  local layerIndex = (-skip) - y
  local xForward = (layerIndex % 2 == 0)
  local xFrom = xForward and 0 or (width - 1)
  local xTo = xForward and (width - 1) or 0
  local xStep = xForward and 1 or -1

  local x = xFrom
  local columnIndex = 0
  while true do
    local zForward = (columnIndex % 2 == 0)
    local zFrom = zForward and 0 or (length - 1)
    local zTo = zForward and (length - 1) or 0
    local zStep = zForward and 1 or -1

    if not mineColumn(x, zFrom, zTo, zStep) then
      return false
    end

    if x == xTo then
      break
    end
    x = x + xStep
    columnIndex = columnIndex + 1
  end
  return true
end

-- Pre-descend past any skip offset. Idempotent: a resumed turtle already
-- below -skip just falls through immediately.
while dig.gety() > -skip do
  j.checkFuel()
  j.heartbeat("mining")
  if not dig.down(1) then
    break
  end
  if dig.isStuck() then
    break
  end
end

if not dig.isStuck() then
  local y = dig.gety()
  -- `depth` layers total, measured from the turtle's starting Y (0):
  -- y = 0, -1, ..., -(depth-1) -- the floor is -(depth-1), i.e. "while
  -- y > -depth", not "while y >= -depth" (which would mine one extra
  -- layer at y = -depth).
  while y > -depth do
    if not mineLayer(y) then
      break
    end
    if dig.isStuck() then
      break
    end
    y = y - 1
    if y > -depth then
      if not dig.down(1) then
        break
      end
      y = dig.gety()
    end
  end
end

-- ===========================================================================
-- Done (or stuck) -- either way, head home, drop off, and clear the
-- auto-resume trigger so a wedged turtle doesn't retry a dead job.
-- ===========================================================================

local stoppedEarly = dig.isStuck()

dig.gotoy(0)
dig.gotox(0)
dig.gotoz(0)
if dig.getBlockSlot() ~= 0 then
  dig.placeDown()
end
dig.gotor(0)

if dodumps then
  dig.doDump()
end
dig.dropNotFuel()

if stoppedEarly then
  flex.send(
    "#EQuarry stopped early (obstruction near " .. dig.getStuckDir()
      .. ") after #F" .. dig.getdug() .. "#E blocks dug.",
    colors.red
  )
  j.broadcast("stuck")
else
  flex.send("#AQuarry complete! #F" .. dig.getdug() .. "#A blocks dug.", colors.lime)
  j.broadcast("done")
end

dig.saveClear()
flex.modemOff()
