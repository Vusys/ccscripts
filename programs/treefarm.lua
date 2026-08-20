-- treefarm.lua
--
-- Tends a rows x cols grid of tree plots forever (or for a fixed
-- number of passes): fells any mature tree found, replants a sapling
-- on bare ground, and leaves an already-growing sapling alone. Reboot-
-- resumable via dig.lua's usual position save; a mid-pass reboot just
-- replays that pass from its first plot, which costs a little time but
-- changes nothing (visiting an already-tended plot is a no-op), the
-- same resumability philosophy quarry.lua uses.
--
-- Usage: treefarm <rows> <cols> [passes <N>] [dump]
--   rows      required. Number of plot rows (Z axis).
--   cols      required. Number of plot columns (X axis).
--   passes <N> optional, defaults to unlimited -- stop after N full
--             passes over the grid instead of tending forever.
--   dump      automatically dump dumplist-matching items to a chest
--             sideways when the inventory fills up.
--
-- Plot layout: plots are spaced PLOT_SPACING blocks apart on both
-- axes -- not a turtle-pathing requirement (dig.lua's dig-through
-- movement would cope with adjacent plots just fine), but real trees
-- need room to grow their canopy without a neighboring trunk in the
-- way.
--
-- Per-plot mechanics: the turtle cruises at CRUISE_Y (safely above
-- any ordinary tree's canopy, so horizontal travel between plots
-- doesn't repeatedly clip a neighbor's leaves) and, to visit a plot,
-- descends straight down through that column to y=0 -- its own
-- starting height, standing directly above the plot's soil. That
-- descent is a plain dig.gotoy(0)/dig.down() call: dig.lua's existing
-- dig-through movement already fells whatever trunk/leaves are in the
-- way as a side effect of just moving down, so there is no separate
-- "chop the tree" step here. At y=0 the turtle checks the soil
-- (inspectDown): a sapling/propagule/fungus already there means this
-- tree hasn't grown yet and is left alone; anything else gets a fresh
-- sapling planted (placeDown, harmlessly a no-op if none is on hand or
-- the ground can't take one right now). Then it's back up to cruise
-- altitude and on to the next plot.
--
-- Known limitation: only the trunk column directly above each plot's
-- soil gets cleared -- leaves left hanging to the sides (and any
-- saplings they eventually drop) are not chased down. Fine for the
-- common single-block-trunk trees; a future pass could widen this.

local dig = require("dig")
local flex = require("flex")
local job = require("job")

local PLOT_SPACING = 2
local CRUISE_Y = 8 -- tall enough for most trees; taller ones just get
                    -- dug through during descent regardless, so this
                    -- is a travel-collision heuristic, not a hard cap
local SAPLING_MATCH = { "sapling", "propagule", "fungus" }

-- ===========================================================================
-- Arguments. Validated in full before anything touches saved state.
-- ===========================================================================

local args = { ... }
if #args < 2 then
  flex.printColors("treefarm <rows> <cols> [passes <N>] [dump]", colors.lightBlue)
  return
end

local rows = tonumber(args[1])
local cols = tonumber(args[2])
local maxPasses = nil
local dodumps = false

for i, a in ipairs(args) do
  if a == "passes" then
    maxPasses = tonumber(args[i + 1])
  elseif a == "dump" then
    dodumps = true
  end
end

if not rows or not cols or rows < 1 or cols < 1 then
  flex.send("Invalid grid dimensions", colors.red)
  return
end

-- ===========================================================================
-- Set up dig.lua for this job, then hook into its save/resume mechanism.
-- ===========================================================================

if dig.saveExists() then
  dig.loadCoords()
end
dig.makeStartup("treefarm", args)

flex.send("#B Tree farm: #F" .. rows .. "#Bx#F" .. cols .. "#B plots"
  .. (maxPasses and ("#B, #F" .. maxPasses .. "#B pass(es)") or ""))

-- ===========================================================================
-- Job scaffold.
-- ===========================================================================

local passIndex = 0

local j = job.new({
  kind = "treefarm",
  workingState = "farming",
  dump = dodumps,
  fuelEstimate = function() return (rows + cols + CRUISE_Y + 1) * 3 end,
  extra = function()
    return { rows = rows, cols = cols, pass = passIndex }
  end,
})

j.broadcast("farming")

-- ===========================================================================
-- Per-plot tending.
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

-- Called with the turtle already at cruise altitude, above plot (x, z).
local function tendPlot(x, z)
  if not dig.gotox(x) then return false end
  if not dig.gotoz(z) then return false end
  if not dig.gotoy(0) then return false end -- fells any mature trunk in the way

  if not flex.isBlock(SAPLING_MATCH, "down") then
    if selectSapling() then
      dig.placeDown()
    end
  end

  if not dig.gotoy(CRUISE_Y) then return false end
  return true
end

-- Sweeps the whole grid once, boustrophedon (row direction alternates
-- by row, same reasoning as quarry.lua's mineLayer -- no long return
-- trip between rows, and it's resumable with zero extra bookkeeping).
local function tendGrid()
  if not dig.gotoy(CRUISE_Y) then return false end

  for row = 0, rows - 1 do
    local z = row * PLOT_SPACING
    local forward = (row % 2 == 0)
    local colFrom = forward and 0 or (cols - 1)
    local colTo = forward and (cols - 1) or 0
    local colStep = forward and 1 or -1

    local col = colFrom
    while true do
      local x = col * PLOT_SPACING
      if not tendPlot(x, z) then
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
  if not tendGrid() then
    stoppedEarly = dig.isStuck()
    break
  end
  passIndex = passIndex + 1
  j.broadcast("farming")
end

-- ===========================================================================
-- Done (or stuck) -- head home and clear the auto-resume trigger.
-- ===========================================================================

dig.gotoy(0)
dig.gotox(0)
dig.gotoz(0)
dig.gotor(0)

if dodumps then
  dig.doDump()
end
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
