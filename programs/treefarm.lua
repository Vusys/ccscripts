-- treefarm.lua
--
-- Tends a flat, sapling-covered patch forever (or for a fixed number of
-- passes): fells any mature tree found, replants bare ground, and
-- leaves an already-growing sapling alone. Reboot-resumable via
-- dig.lua's usual position save; a mid-pass reboot just replays that
-- pass from its first cell, which costs a little time but changes
-- nothing (revisiting an already-tended cell is a no-op), the same
-- resumability philosophy quarry.lua uses.
--
-- Usage: treefarm <width> <length> [passes <N>] [dump]
--   width     required. X-axis size of the patch, in blocks.
--   length    required. Z-axis size of the patch, in blocks.
--   passes <N> optional, defaults to unlimited -- stop after N full
--             passes over the patch instead of tending forever.
--   dump      automatically dump dumplist-matching items to a chest
--             sideways when the inventory fills up.
--
-- `width`/`length` are the *actual footprint in blocks*, not a plot
-- count -- every single ground cell in that width x length rectangle
-- gets its own visit, starting at the turtle's own position (its
-- (0,0) corner). Set up like this:
--
--     [chest] [turtle] [grass][grass][grass]...
--                       ^ (0,0)      ^ (width-1, 0)
--
-- i.e. a chest directly behind the turtle's start position/facing
-- (this doubles as the base chest lib/job.lua's checkFuel()/checkInv()
-- round trips already return to and face -- gotoBase() ends at
-- (0,0,0), r=180, looking straight at it) and the patch itself
-- starting at the turtle's feet and extending forward (+Z) and to the
-- right (+X) from there.
--
-- Per-cell mechanics: the turtle cruises at CRUISE_Y (safely above any
-- ordinary tree's canopy, so horizontal travel between cells doesn't
-- repeatedly clip a neighboring tree's leaves) and, to visit a cell,
-- descends straight down through that column to y=0 -- its own
-- starting height, standing directly above the cell's soil. That
-- descent is a plain dig.gotoy(0) call: dig.lua's existing dig-through
-- movement already fells whatever trunk/leaves are in the way as a
-- side effect of just moving down, so there is no separate "chop the
-- tree" step here. At y=0 the turtle checks the soil (inspectDown): a
-- sapling/propagule/fungus already there means this tree hasn't grown
-- yet and is left alone; anything else gets a fresh sapling planted
-- (placeDown, harmlessly a no-op if none is on hand or the ground
-- can't take one right now). Then it's back up to cruise altitude and
-- on to the next cell.
--
-- Because every ground cell gets its own descent (not just a sparse
-- subset of "plots"), a neighboring tree's leaves hanging out over an
-- adjacent cell get cleared too, when that cell's own turn comes --
-- there's no dedicated column left permanently unchecked the way a
-- widely-spaced plot layout would leave one.

local dig = require("dig")
local flex = require("flex")
local job = require("job")

local CRUISE_Y = 8 -- tall enough for most trees; taller ones just get
                    -- dug through during descent regardless, so this
                    -- is a travel-collision heuristic, not a hard cap
local SAPLING_MATCH = { "sapling", "propagule", "fungus" }

-- ===========================================================================
-- Arguments. Validated in full before anything touches saved state.
-- ===========================================================================

local args = { ... }
if #args < 2 then
  flex.printColors("treefarm <width> <length> [passes <N>] [dump]", colors.lightBlue)
  return
end

local width = tonumber(args[1])
local length = tonumber(args[2])
local maxPasses = nil
local dodumps = false

for i, a in ipairs(args) do
  if a == "passes" then
    maxPasses = tonumber(args[i + 1])
  elseif a == "dump" then
    dodumps = true
  end
end

if not width or not length or width < 1 or length < 1 then
  flex.send("Invalid patch dimensions", colors.red)
  return
end

-- ===========================================================================
-- Set up dig.lua for this job, then hook into its save/resume mechanism.
-- ===========================================================================

if dig.saveExists() then
  dig.loadCoords()
end
dig.makeStartup("treefarm", args)

flex.send("#B Tree farm: #F" .. width .. "#Bx#F" .. length .. "#B blocks"
  .. (maxPasses and ("#B, #F" .. maxPasses .. "#B pass(es)") or ""))

-- ===========================================================================
-- Job scaffold.
-- ===========================================================================

local passIndex = 0

local j = job.new({
  kind = "treefarm",
  workingState = "farming",
  dump = dodumps,
  fuelEstimate = function() return (width + length + CRUISE_Y + 1) * 3 end,
  extra = function()
    return { width = width, length = length, pass = passIndex }
  end,
})

j.broadcast("farming")

-- ===========================================================================
-- Per-cell tending.
-- ===========================================================================

local function selectSapling()
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 and flex.isItem(SAPLING_MATCH, slot) then
      turtle.select(slot)
      return true
    end
  end
  return false
end

-- Called with the turtle already at cruise altitude, above cell (x, z).
--
-- The sapling itself sits at the *same* height as the turtle's own
-- starting position (y=0) -- both rest on the soil one level below
-- (y=-1) -- so the turtle stops one cell short, at y=1, rather than
-- descending all the way to y=0. Landing at y=0 would mean physically
-- moving into the sapling's own cell just to arrive, digging up
-- whatever's growing there (mature or not) as a side effect of travel,
-- before ever checking what it was. Stopping at y=1 digs through any
-- trunk/leaves *above* the sapling layer on the way down (still a
-- side effect of gotoy, same as before) without disturbing y=0 itself,
-- so inspectDown()/digDown()/placeDown() below can tell an immature
-- sapling apart from a felled trunk's base log/bare soil correctly.
local function tendCell(x, z)
  if not dig.gotox(x) then return false end
  if not dig.gotoz(z) then return false end
  if not dig.gotoy(1) then return false end

  if not flex.isBlock(SAPLING_MATCH, "down") then
    dig.digDown() -- clear a felled trunk's base log or stray leaves;
                   -- harmless no-op if the cell's already bare
    if selectSapling() then
      dig.placeDown()
    end
  end

  if not dig.gotoy(CRUISE_Y) then return false end
  return true
end

-- Sweeps the whole patch once, boustrophedon (row direction alternates
-- by row, same reasoning as quarry.lua's mineLayer -- no long return
-- trip between rows, and it's resumable with zero extra bookkeeping).
local function tendPatch()
  if not dig.gotoy(CRUISE_Y) then return false end

  for row = 0, length - 1 do
    local z = row
    local forward = (row % 2 == 0)
    local colFrom = forward and 0 or (width - 1)
    local colTo = forward and (width - 1) or 0
    local colStep = forward and 1 or -1

    local col = colFrom
    while true do
      local x = col
      if not tendCell(x, z) then
        return false
      end

      j.checkHalt()
      j.checkFuel()
      j.checkInv()
      j.heartbeat("farming")
      if dig.isStuck() then
        return false
      end

      if col == colTo then
        break
      end
      col = col + colStep
    end
  end
  return true
end

-- ===========================================================================
-- Main loop.
-- ===========================================================================

local stoppedEarly = false
while not maxPasses or passIndex < maxPasses do
  if not tendPatch() then
    stoppedEarly = dig.isStuck()
    break
  end
  passIndex = passIndex + 1
  j.broadcast("farming")
end

-- ===========================================================================
-- Done (or stuck) -- head home and clear the auto-resume trigger.
-- ===========================================================================

-- Horizontal travel first, while still at cruise altitude (tendPatch()
-- always leaves the turtle there) -- descending to y=0 elsewhere in
-- the patch, then traveling home at ground level, would plow straight
-- through whatever the last few cells just had planted. Only descend
-- once actually over the home cell.
dig.gotox(0)
dig.gotoz(0)
dig.gotoy(0)
dig.gotor(0)

if dodumps then
  dig.doDump()
end

-- The base chest is *behind* the turtle's start facing (r=180), same
-- convention as job.lua's gotoBase() -- not r=0, which faces into the
-- patch itself. dropNotFuel() blocks forever waiting for a chest it
-- can see, so this turn is required, not cosmetic.
dig.gotor(180)
dig.dropNotFuel()

if stoppedEarly then
  flex.send(
    "#EStopped early (obstruction near " .. dig.getStuckDir()
      .. ") after #F" .. passIndex .. "#E pass(es).",
    colors.red
  )
  j.broadcast("stuck")
else
  flex.send("#ATree farm complete! #F" .. passIndex .. "#A pass(es) done.", colors.lime)
  j.broadcast("done")
end

dig.saveClear()
flex.modemOff()
