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
-- Wireless status broadcasting -- a structured heartbeat for a companion
-- program like programs/monitor.lua to consume, distinct from the
-- human-readable flex.send() messages above (which are for a person
-- watching a terminal, not for programmatic parsing). A no-op if there's
-- no modem, so this is always safe to call.
-- ===========================================================================

local totalToMine = length * width * math.max(depth - skip, 1)
local lastBroadcast = 0
local BROADCAST_INTERVAL_MS = 10000 -- keeps "last seen" fresh on the
                                     -- monitor even when dug/Y aren't
                                     -- changing (paused, refueling, ...)

local function broadcastStatus(state)
  if not flex.hasWirelessModem() then
    return
  end
  lastBroadcast = os.epoch("utc")
  flex.sendData({
    kind = "quarry_status",
    id = os.getComputerID(),
    label = os.getComputerLabel(),
    state = state,
    x = dig.getx(),
    y = dig.gety(),
    z = dig.getz(),
    r = dig.getr(),
    fuel = turtle.getFuelLevel(),
    fuelLimit = turtle.getFuelLimit(),
    dug = dig.getdug(),
    total = totalToMine,
    length = length,
    width = width,
    depth = depth,
    skip = skip,
  })
end

-- Time-throttled variant for call sites that run on every cell -- avoids
-- flooding the channel while still keeping the heartbeat alive.
local function maybeBroadcastStatus(state)
  if os.epoch("utc") - lastBroadcast >= BROADCAST_INTERVAL_MS then
    broadcastStatus(state)
  end
end

broadcastStatus("mining")

-- ===========================================================================
-- Housekeeping run at every mined cell.
-- ===========================================================================

local function gotoBase()
  local saved = dig.location()
  dig.gotoy(0)
  dig.gotox(0)
  dig.gotoz(0)
  dig.gotor(180)
  return saved
end

local function returnFromBase(saved)
  dig.goto(saved)
end

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

local lastReportedDug = dig.getdug()
local lastReportedY = dig.gety()

local function checkProgress()
  local milestoneHit = false
  local dug = dig.getdug()
  if dug - lastReportedDug >= 1000 then
    lastReportedDug = dug
    flex.send("#8Progress: #F" .. dug .. "#8 blocks dug (y=#F" .. dig.gety() .. "#8)")
    milestoneHit = true
  end
  local y = dig.gety()
  if lastReportedY - y >= 5 then
    lastReportedY = y
    flex.send("#8Progress: #Fy=" .. y)
    milestoneHit = true
  end

  if milestoneHit then
    broadcastStatus("mining")
  else
    maybeBroadcastStatus("mining")
  end
end

local function checkFuel()
  local level = turtle.getFuelLevel()
  if level == "unlimited" then
    return
  end
  local estimate = (length + width + depth + 1) * 2
  if level < estimate then
    broadcastStatus("refueling")
    local saved = gotoBase()
    dig.dropNotFuel()
    turtle.suckUp()
    dig.refuel(estimate)
    returnFromBase(saved)
    broadcastStatus("mining")
  end
end

local function checkInv()
  if turtle.getItemCount(16) > 0 then
    if dodumps then
      dig.right(2)
      dig.doDump()
      dig.left(2)
    end
    if turtle.getItemCount(14) > 0 then
      broadcastStatus("dumping")
      local saved = gotoBase()
      dig.dropNotFuel()
      returnFromBase(saved)
      broadcastStatus("mining")
    end
  end
end

local function checkHalt()
  if not rs.getInput("top") then
    return
  end

  flex.send("Paused. ENTER to resume, SPACE to return to base and wait.", colors.yellow)
  broadcastStatus("paused")
  local saved = dig.location()
  local wentToBase = false

  while rs.getInput("top") do
    local key = flex.getKey()
    if key == keys.space and not wentToBase then
      gotoBase()
      wentToBase = true
    elseif key == keys.enter then
      break
    end
  end

  if wentToBase then
    returnFromBase(saved)
  end
  flex.send("Resuming.", colors.lime)
  broadcastStatus("mining")
end

-- ===========================================================================
-- Mining.
-- ===========================================================================

-- Sweeps Z from zFrom to zTo (inclusive, stepping by zStep) at column x.
local function mineColumn(x, zFrom, zTo, zStep)
  if not dig.gotox(x) then
    return false
  end

  local z = zFrom
  while true do
    checkLava()
    checkProgress()
    checkHalt()
    checkFuel()
    checkInv()
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
  checkFuel()
  maybeBroadcastStatus("mining")
  if not dig.down(1) then
    break
  end
  if dig.isStuck() then
    break
  end
end

if not dig.isStuck() then
  local y = dig.gety()
  while y >= -depth do
    if not mineLayer(y) then
      break
    end
    if dig.isStuck() then
      break
    end
    y = y - 1
    if y >= -depth then
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
  broadcastStatus("stuck")
else
  flex.send("#AQuarry complete! #F" .. dig.getdug() .. "#A blocks dug.", colors.lime)
  broadcastStatus("done")
end

dig.saveClear()
flex.modemOff()
