-- corridor.lua
--
-- Digs a straight, 1-wide passage: at each position along the line it
-- clears the block above and the block below in place (turtle.digUp()/
-- digDown() via dig.dig(), no vertical movement involved -- see
-- fasttunnel.lua's clearColumn() for the same idiom), then advances
-- one block (dig.fwd()'s own dig-through movement clears whatever is
-- directly ahead). No sweeping side to side and no width/height
-- parameters -- just forward, for the given distance.
--
-- Deliberately doesn't need an output chest anywhere: no dump option,
-- no inventory-full round trip back to base -- it just mines and stops
-- once it reaches its destination. If the inventory fills up mid-dig,
-- that's on the caller to manage (dig-cli/pkg still work normally
-- afterward); this program doesn't go looking for somewhere to unload.
--
-- Usage: corridor <length> [return]
--   length  required. How many blocks to advance.
--   return  walk back to the starting position when done instead of
--           staying at the far end.

local dig = require("dig")
local flex = require("flex")
local job = require("job")

-- ===========================================================================
-- Arguments. Validated in full before anything touches saved state.
-- ===========================================================================

local args = { ... }
if #args < 1 then
  flex.printColors("corridor <length> [return]", colors.lightBlue)
  return
end

local length = tonumber(args[1])
local doReturn = false
for _, a in ipairs(args) do
  if a == "return" then
    doReturn = true
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
dig.makeStartup("corridor", args)

flex.send("#B Corridor: #F" .. length .. "#B blocks")

-- ===========================================================================
-- Job scaffold.
-- ===========================================================================

local j = job.new({
  kind = "corridor",
  workingState = "digging",
  fuelEstimate = function() return length + 1 end,
  total = length,
  extra = function() return { length = length } end,
})

j.broadcast("digging")

-- ===========================================================================
-- Main loop.
-- ===========================================================================

local function clearColumn()
  dig.dig("up")
  dig.dig("down")
end

local stoppedEarly = false
while dig.getz() < length do
  j.checkHalt()
  j.checkFuel()
  if dig.isStuck() then
    stoppedEarly = true
    break
  end

  clearColumn()

  if not dig.fwd(1) then
    stoppedEarly = dig.isStuck()
    break
  end
  if dig.isStuck() then
    stoppedEarly = true
    break
  end

  j.checkProgress()
end

if not stoppedEarly then
  clearColumn()
end

-- ===========================================================================
-- Done (or stuck) -- clears the auto-resume trigger either way so a
-- wedged turtle doesn't retry a dead job.
-- ===========================================================================

if doReturn and not stoppedEarly then
  dig.gotoz(0)
  dig.gotor(0)
end

if stoppedEarly then
  flex.send(
    "#ECorridor stopped early (obstruction near " .. dig.getStuckDir()
      .. ") after #F" .. dig.getz() .. "#E/#F" .. length .. "#E blocks.",
    colors.red
  )
  j.broadcast("stuck")
else
  flex.send("#ACorridor complete! #F" .. dig.getz() .. "#A blocks, #F" .. dig.getdug() .. "#A dug.", colors.lime)
  j.broadcast("done")
end

dig.saveClear()
flex.modemOff()
