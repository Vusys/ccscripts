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
-- Deliberately doesn't need any chest anywhere -- no dump option, no
-- inventory-full round trip, and no low-fuel round trip either (skips
-- job.lua's checkFuel(), which would otherwise return to base to drop
-- items and suck up fuel from a chest there). It just mines and stops
-- once it reaches its destination. If the inventory fills up mid-dig,
-- that's on the caller to manage; if fuel runs low, dig.lua's own
-- per-move refuel(1) (used internally by fwd()/dig()) blocks and waits
-- for more fuel in the onboard fuel slot rather than going anywhere.
--
-- Usage: corridor <length> [block] [gap <N>] [return]
--   length  required. How many blocks to advance.
--   block   optional. A substring matched against inventory item names
--           (same convention as build.lua's schematic cells). If the
--           block already below the turtle matches, it's left alone
--           entirely -- no dig, no replace. Otherwise, any position
--           left with no floor after digging down -- whether a block
--           was just dug out there or it was already open air (e.g. a
--           gap in a bedrock corridor) -- gets this item placed back
--           in. If the block below can't be broken (bedrock) it's
--           still a floor, so nothing is placed there.
--   gap     optional, follows the literal word "gap". Only place every
--           N-th eligible position instead of every one (default 1,
--           i.e. every position). Purely a placement throttle -- every
--           position that needs digging is still dug regardless of
--           gap; a position already holding the right block is never
--           dug in the first place, gap or no gap.
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
  flex.printColors("corridor <length> [block] [gap <N>] [return]", colors.lightBlue)
  return
end

local length = tonumber(args[1])
local fillBlock = nil
local gap = 1
local doReturn = false

local i = 2
while i <= #args do
  local a = args[i]
  if a == "return" then
    doReturn = true
    i = i + 1
  elseif a == "gap" then
    gap = tonumber(args[i + 1])
    if not gap or gap < 1 then
      flex.send("Invalid gap", colors.red)
      return
    end
    i = i + 2
  else
    fillBlock = a
    i = i + 1
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

flex.send(
  "#B Corridor: #F" .. length .. "#B blocks"
    .. (fillBlock and (", filling #F" .. fillBlock .. "#B every #F" .. gap .. "#B block(s)") or "")
)

-- ===========================================================================
-- Job scaffold.
-- ===========================================================================

local j = job.new({
  kind = "corridor",
  workingState = "digging",
  total = length,
  extra = function() return { length = length, block = fillBlock, gap = gap } end,
})

j.broadcast("digging")

-- ===========================================================================
-- Main loop.
-- ===========================================================================

-- Same substring-match-against-inventory idiom as build.lua's
-- selectItem() -- picks the first slot holding something matching
-- `name`, leaving it selected. Returns false (nothing selected) if
-- none is found.
local function selectItem(name)
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 and flex.isItem(name, slot) then
      turtle.select(slot)
      return true
    end
  end
  return false
end

local missingCount = 0

-- Clears above and below in place, same as before -- but when a fill
-- block was given, also checks whether there's a floor left afterward
-- so it knows whether there's a hole worth filling. That covers both
-- a block that just broke *and* a spot that was already open air --
-- an unbroken block (bedrock) still detects afterward, so it's
-- correctly left alone either way.
--
-- If the block already down there is already a match for fillBlock,
-- the whole below-dig is skipped -- breaking and replacing it with an
-- identical block would just waste time (and durability/inventory)
-- for no change.
local function clearColumn(position)
  dig.dig("up")

  if fillBlock and flex.isBlockDown(fillBlock) then
    return
  end

  dig.dig("down")
  local hasFloor = turtle.detectDown()

  if fillBlock and not hasFloor and (position % gap == 0) then
    if selectItem(fillBlock) then
      dig.placeDown()
    else
      missingCount = missingCount + 1
    end
  end
end

local stoppedEarly = false
while dig.getz() < length do
  j.checkHalt()
  if dig.isStuck() then
    stoppedEarly = true
    break
  end

  clearColumn(dig.getz())

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
  clearColumn(dig.getz())
end

-- ===========================================================================
-- Done (or stuck) -- clears the auto-resume trigger either way so a
-- wedged turtle doesn't retry a dead job.
-- ===========================================================================

if doReturn and not stoppedEarly then
  dig.gotoz(0)
  dig.gotor(0)
end

if missingCount > 0 then
  flex.send("#EOut of #F" .. fillBlock .. "#E, skipped #F" .. missingCount .. "#E fill(s).", colors.orange)
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
