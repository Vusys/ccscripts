-- bridge.lua
--
-- Walks forward in a straight line, placing a block underneath itself
-- wherever the ground isn't solid -- crosses a gap, a lava lake, or
-- open water without falling in or needing to seal anything by hand.
--
-- Usage: bridge <length> [dump]
--   length  required. How many blocks to advance.
--   dump    automatically dump dumplist-matching items to a chest
--           sideways when the inventory fills up (relevant only if
--           fwd() ends up digging through an obstruction along the way).
--
-- Reserves inventory slot 1 as building material the same way
-- quarry.lua reserves a lava-sealing slot (dig.setBlockSlot());
-- dig.checkBlocks() keeps it topped up from any other slot holding a
-- matching buildingblocks-classified item. Stays at the far end when
-- done rather than returning to base -- the point of a bridge is
-- having crossed it, and unlike quarry/treefarm/farm/build there's
-- normally nothing accumulated worth a special trip back (checkFuel()
-- still works mid-bridge regardless, since its round trip walks back
-- over the floor already placed).

local dig = require("dig")
local flex = require("flex")
local job = require("job")

local BRIDGE_SLOT = 1

-- ===========================================================================
-- Arguments. Validated in full before anything touches saved state.
-- ===========================================================================

local args = { ... }
if #args < 1 then
  flex.printColors("bridge <length> [dump]", colors.lightBlue)
  return
end

local length = tonumber(args[1])
local dodumps = false
for _, a in ipairs(args) do
  if a == "dump" then
    dodumps = true
  end
end

if not length or length < 1 then
  flex.send("Invalid length", colors.red)
  return
end

-- ===========================================================================
-- Set up dig.lua for this job, then hook into its save/resume mechanism.
-- ===========================================================================

dig.setBlockSlot(BRIDGE_SLOT)

if dig.saveExists() then
  dig.loadCoords()
end
dig.makeStartup("bridge", args)

flex.send("#B Bridge: #F" .. length .. "#B blocks")

-- ===========================================================================
-- Job scaffold.
-- ===========================================================================

local j = job.new({
  kind = "bridge",
  workingState = "bridging",
  dump = dodumps,
  fuelEstimate = function() return length + 1 end,
  total = length,
  extra = function() return { length = length } end,
})

j.broadcast("bridging")

-- ===========================================================================
-- Main loop.
-- ===========================================================================

local stoppedEarly = false
while dig.getz() < length do
  j.checkHalt()
  j.checkFuel()
  j.checkInv()
  if dig.isStuck() then
    stoppedEarly = true
    break
  end

  if not dig.fwd(1) then
    stoppedEarly = dig.isStuck()
    break
  end
  if dig.isStuck() then
    stoppedEarly = true
    break
  end

  -- "Fluid" here includes plain air (see flex.lua's FLUIDS list) --
  -- exactly the "nothing solid to stand over" condition a bridge
  -- needs to fill in.
  if flex.isFluid("down") then
    dig.checkBlocks()
    dig.placeDown()
  end

  j.checkProgress()
end

-- ===========================================================================
-- Done (or stuck) -- stays put at the far end; clears the auto-resume
-- trigger either way so a wedged turtle doesn't retry a dead job.
-- ===========================================================================

if dodumps then
  dig.doDump()
end

if stoppedEarly then
  flex.send(
    "#EBridge stopped early (obstruction near " .. dig.getStuckDir()
      .. ") after #F" .. dig.getz() .. "#E/#F" .. length .. "#E blocks.",
    colors.red
  )
  j.broadcast("stuck")
else
  flex.send("#ABridge complete! #F" .. dig.getz() .. "#A blocks crossed.", colors.lime)
  j.broadcast("done")
end

dig.saveClear()
flex.modemOff()
