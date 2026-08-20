-- well.lua
--
-- Digs straight down until it hits bedrock (or a configured max
-- depth), using dig.lua's existing stuck-detection to recognize
-- bedrock rather than digging forever.
--
-- Usage: well [maxDepth] [dump] [return]
--   maxDepth  optional. Stop after this many blocks down even if
--             nothing stopped it first; unbounded (dig until stuck) if
--             omitted.
--   dump      automatically dump dumplist-matching items to a chest
--             sideways when the inventory fills up.
--   return    ascend back to the starting height when done instead of
--             staying at the bottom.

local dig = require("dig")
local flex = require("flex")
local job = require("job")

-- ===========================================================================
-- Arguments. Validated in full before anything touches saved state.
-- ===========================================================================

local args = { ... }
local maxDepth = nil
local dodumps = false
local doReturn = false

for _, a in ipairs(args) do
  if a == "dump" then
    dodumps = true
  elseif a == "return" then
    doReturn = true
  elseif tonumber(a) then
    maxDepth = tonumber(a)
  end
end

if maxDepth and maxDepth < 1 then
  flex.send("Invalid depth", colors.red)
  return
end

-- ===========================================================================
-- Set up dig.lua for this job, then hook into its save/resume mechanism.
-- ===========================================================================

if dig.saveExists() then
  dig.loadCoords()
end
dig.makeStartup("well", args)

flex.send("#B Well" .. (maxDepth and (": #F" .. maxDepth .. "#B deep") or ": #Fto bedrock"))

-- ===========================================================================
-- Job scaffold.
-- ===========================================================================

local j = job.new({
  kind = "well",
  workingState = "digging",
  dump = dodumps,
  fuelEstimate = function() return (maxDepth or 64) + 1 end,
  total = maxDepth,
  extra = function() return { depth = -dig.gety(), maxDepth = maxDepth } end,
})

j.broadcast("digging")

-- ===========================================================================
-- Main loop.
-- ===========================================================================

while not maxDepth or -dig.gety() < maxDepth do
  j.checkHalt()
  j.checkFuel()
  j.checkInv()
  if dig.isStuck() then
    break
  end

  if not dig.down(1) then
    break
  end
  if dig.isStuck() then
    break
  end

  j.checkProgress()
end

-- ===========================================================================
-- Done (or stuck on bedrock -- for a well, that's the expected way to
-- finish, not a failure) -- clear the auto-resume trigger either way.
-- ===========================================================================

local hitBedrock = dig.isStuck()

if doReturn then
  dig.gotoy(0)
  dig.gotor(0)
end

if dodumps then
  dig.doDump()
end

if hitBedrock then
  flex.send("#AWell complete! #F" .. (-dig.gety()) .. "#A blocks deep (hit bedrock).", colors.lime)
else
  flex.send("#AWell complete! #F" .. (-dig.gety()) .. "#A blocks deep.", colors.lime)
end
j.broadcast("done")

dig.saveClear()
flex.modemOff()
