-- courier.lua
--
-- Shuttles items between two fixed chest waypoints: a pickup chest
-- immediately behind the starting position, and a dropoff chest
-- immediately ahead of the far end, `length` blocks away.
--
-- Usage: courier <length> [trips <N>] [dump] [idle]
--   length    required. Distance between the two waypoints.
--   trips <N> optional, defaults to unlimited -- stop after N round
--             trips instead of shuttling forever.
--   dump      automatically dump dumplist-matching items to a chest
--             sideways when the inventory fills up mid-trip.
--   idle      wait at the pickup waypoint for a wireless
--             `courier_request` (flex.sendData({kind =
--             "courier_request"})) before each trip, instead of
--             shuttling continuously. Useful when there's nothing
--             regularly arriving at the pickup chest and running empty
--             round trips would just waste fuel.
--
-- Reuses dig.lua's existing forward-facing chest machinery instead of
-- inventing a new one: the dropoff chest is picked up by
-- dig.dropNotFuel() (already "wait for a chest ahead, drop everything
-- but fuel/reserved blocks"), which is exactly what a courier wants at
-- its destination. The pickup chest sits behind the start, so pickup()
-- just turns around, turtle.suck()s until the chest (or the courier's
-- own inventory) is empty, and turns back.
--
-- That "behind the start" placement isn't arbitrary: it's exactly
-- where lib/job.lua's checkFuel()/checkInv() already return to and
-- face (gotoBase() ends at r=180) for their own mid-trip refuel/unload
-- round trips -- so the pickup chest doing double duty as the base
-- chest for those is a deliberate use of the existing convention, not
-- a coincidence to "fix" later.

local dig = require("dig")
local flex = require("flex")
local job = require("job")

-- ===========================================================================
-- Arguments. Validated in full before anything touches saved state.
-- ===========================================================================

local args = { ... }
if #args < 1 then
  flex.printColors("courier <length> [trips <N>] [dump] [idle]", colors.lightBlue)
  return
end

local length = tonumber(args[1])
local maxTrips = nil
local dodumps = false
local idleMode = false

for i, a in ipairs(args) do
  if a == "trips" then
    maxTrips = tonumber(args[i + 1])
  elseif a == "dump" then
    dodumps = true
  elseif a == "idle" then
    idleMode = true
  end
end

if not length or length < 1 then
  flex.send("Invalid length", colors.red)
  return
end

-- ===========================================================================
-- Set up dig.lua for this job, then hook into its save/resume mechanism.
-- ===========================================================================

if dig.saveExists() then
  dig.loadCoords()
end
dig.makeStartup("courier", args)

flex.send("#B Courier: #F" .. length .. "#B blocks"
  .. (maxTrips and ("#B, #F" .. maxTrips .. "#B trip(s)") or ""))

-- ===========================================================================
-- Job scaffold.
-- ===========================================================================

local tripIndex = 0

local j = job.new({
  kind = "courier",
  workingState = "courier",
  dump = dodumps,
  fuelEstimate = function() return (length + 1) * 2 end,
  extra = function()
    return { length = length, trip = tripIndex, mode = idleMode and "idle" or "loop" }
  end,
})

j.broadcast(idleMode and "idle" or "courier")

-- ===========================================================================
-- Waypoint interactions.
-- ===========================================================================

-- The pickup chest is behind the start -- turn to face it, drain it,
-- turn back to the travel heading.
local function pickup()
  dig.gotor(180)
  while turtle.suck() do
    -- keep pulling until the chest (or our own inventory) runs dry
  end
  dig.gotor(0)
end

-- The dropoff chest is directly ahead once at the far waypoint --
-- dig.dropNotFuel() already does exactly "wait for a chest ahead, drop
-- everything but fuel/reserved blocks".
local function dropoff()
  dig.dropNotFuel()
end

-- Steps toward z one cell at a time so the usual housekeeping runs
-- throughout a long haul, not just at the endpoints.
local function travelTo(z)
  while dig.getz() ~= z do
    j.checkHalt()
    j.checkFuel()
    j.checkInv()
    j.heartbeat(idleMode and "idle" or "courier")
    if dig.isStuck() then
      return false
    end

    dig.gotor(z > dig.getz() and 0 or 180)
    if not dig.fwd(1) then
      return false
    end
    if dig.isStuck() then
      return false
    end
  end
  return true
end

-- Blocks until a flex.sendData({kind = "courier_request", ...})
-- arrives on the shared channel.
local function waitForRequest()
  while true do
    local event, side, channel, replyChannel, message = os.pullEvent("modem_message")
    if type(message) == "table" and message.kind == "courier_request" then
      return
    end
  end
end

-- ===========================================================================
-- Main loop.
-- ===========================================================================

local stoppedEarly = false
while not maxTrips or tripIndex < maxTrips do
  if idleMode then
    j.broadcast("idle")
    waitForRequest()
  end

  j.broadcast("courier")
  pickup()

  if not travelTo(length) then
    stoppedEarly = dig.isStuck()
    break
  end
  dropoff()

  if not travelTo(0) then
    stoppedEarly = dig.isStuck()
    break
  end

  tripIndex = tripIndex + 1
end

-- ===========================================================================
-- Done (or stuck) -- normalize facing (travelTo(0) leaves the turtle
-- facing r=180, having just walked backward to get there) and clear
-- the auto-resume trigger either way.
-- ===========================================================================

dig.gotor(0)

if stoppedEarly then
  flex.send(
    "#ECourier stopped early (obstruction near " .. dig.getStuckDir()
      .. ") after #F" .. tripIndex .. "#E trip(s).",
    colors.red
  )
  j.broadcast("stuck")
else
  flex.send("#ACourier complete! #F" .. tripIndex .. "#A trip(s) done.", colors.lime)
  j.broadcast("done")
end

dig.saveClear()
flex.modemOff()
