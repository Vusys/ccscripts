-- farm.lua
--
-- Tends a rows x cols grid of crop plots forever (or for a fixed
-- number of passes): harvests and replants anything fully grown,
-- plants bare farmland, leaves an immature crop alone. Same reboot-
-- resume philosophy as quarry.lua/treefarm.lua -- revisiting an
-- already-tended plot is harmless, so a mid-pass reboot just replays
-- the current pass from its first plot.
--
-- Usage: farm <rows> <cols> [passes <N>] [dump]
--   rows      required. Z-axis size of the plot grid.
--   cols      required. X-axis size of the plot grid.
--   passes <N> optional, defaults to unlimited -- stop after N full
--             passes over the grid instead of tending forever.
--   dump      automatically dump dumplist-matching items to a chest
--             sideways when the inventory fills up.
--
-- Unlike treefarm.lua, crops are exactly one block tall, so there's no
-- need to cruise above canopy height between plots -- the turtle just
-- walks the grid directly (boustrophedon, same sweep-by-position-
-- parity pattern as quarry.lua's mineLayer/mineColumn), tending
-- whatever's directly below it via inspectDown/digDown/placeDown at
-- each cell.
--
-- Maturity comes from the block's real state, not a timer:
-- turtle.inspect's `state.age` is the block's actual Minecraft
-- blockstate property (see doc/reference/block_details.md in the
-- CC:Tweaked reference), which is exactly what wheat/carrots/
-- potatoes/beetroot/nether wart use to track growth. CROP_MAX_AGE
-- below is the per-crop age at which that property means "fully
-- grown" -- add an entry there for any other age-tracked crop.
--
-- Replanting always picks whatever known seed type the turtle happens
-- to have on hand (CROP_SEED, checked in a fixed order) rather than
-- trying to remember what was growing in a given plot before -- a
-- reasonable simplification for the common case of one crop type per
-- farm.

local dig = require("dig")
local flex = require("flex")
local job = require("job")

local CROP_MAX_AGE = {
  wheat = 7,
  carrots = 7,
  potatoes = 7,
  beetroots = 3,
  nether_wart = 3,
}

-- Order matters: carrots/potatoes are their own seed item (you plant
-- the harvested crop directly), while wheat/beetroot need their
-- distinct *_seeds item.
local CROP_SEED = {
  { crop = "wheat", seed = "wheat_seeds" },
  { crop = "carrots", seed = "carrot" },
  { crop = "potatoes", seed = "potato" },
  { crop = "beetroots", seed = "beetroot_seeds" },
  { crop = "nether_wart", seed = "nether_wart" },
}

-- ===========================================================================
-- Arguments. Validated in full before anything touches saved state.
-- ===========================================================================

local args = { ... }
if #args < 2 then
  flex.printColors("farm <rows> <cols> [passes <N>] [dump]", colors.lightBlue)
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
dig.makeStartup("farm", args)

flex.send("#B Farm: #F" .. rows .. "#Bx#F" .. cols .. "#B plots"
  .. (maxPasses and ("#B, #F" .. maxPasses .. "#B pass(es)") or ""))

-- ===========================================================================
-- Job scaffold.
-- ===========================================================================

local passIndex = 0

local j = job.new({
  kind = "farm",
  workingState = "farming",
  dump = dodumps,
  fuelEstimate = function() return (rows + cols + 1) * 2 end,
  extra = function()
    return { rows = rows, cols = cols, pass = passIndex }
  end,
})

j.broadcast("farming")

-- ===========================================================================
-- Per-plot tending.
-- ===========================================================================

local function cropInfo(name)
  for key, maxAge in pairs(CROP_MAX_AGE) do
    if name:find(key, 1, true) then
      return key, maxAge
    end
  end
  return nil
end

local function selectSeed()
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      for _, entry in ipairs(CROP_SEED) do
        if flex.isItem(entry.seed, slot) then
          turtle.select(slot)
          return true
        end
      end
    end
  end
  return false
end

local function tendPlot()
  local name, data = flex.getBlockDown()
  local cropKey, maxAge = cropInfo(name)

  if cropKey then
    local age = data and data.state and tonumber(data.state.age)
    if age and age >= maxAge then
      dig.digDown()
      if selectSeed() then
        dig.placeDown()
      end
    end
    -- else: still growing, leave it alone
  elseif flex.isBlock("farmland", "down") then
    -- Bare tilled soil, nothing planted yet.
    if selectSeed() then
      dig.placeDown()
    end
  end
  -- else: something else entirely (a path block, water, ...) -- leave it.
end

-- Sweeps one row (fixed x, z from zFrom to zTo) -- same shape as
-- quarry.lua's mineColumn, action swapped from digging to tending.
local function tendRow(x, zFrom, zTo, zStep)
  if not dig.gotox(x) then return false end
  if not dig.gotoz(zFrom) then return false end
  if not dig.gotor(zStep > 0 and 0 or 180) then return false end

  local z = zFrom
  while true do
    tendPlot()
    j.checkHalt()
    j.checkFuel()
    j.checkInv()
    j.heartbeat("farming")
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

-- Sweeps the whole grid once, boustrophedon -- same shape as
-- quarry.lua's mineLayer.
local function tendGrid()
  local xForward = (passIndex % 2 == 0)
  local xFrom = xForward and 0 or (cols - 1)
  local xTo = xForward and (cols - 1) or 0
  local xStep = xForward and 1 or -1

  local x = xFrom
  local rowIndex = 0
  while true do
    local zForward = (rowIndex % 2 == 0)
    local zFrom = zForward and 0 or (rows - 1)
    local zTo = zForward and (rows - 1) or 0
    local zStep = zForward and 1 or -1

    if not tendRow(x, zFrom, zTo, zStep) then
      return false
    end

    if x == xTo then
      break
    end
    x = x + xStep
    rowIndex = rowIndex + 1
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
  flex.send("#AFarm complete! #F" .. passIndex .. "#A pass(es) done.", colors.lime)
  j.broadcast("done")
end

dig.saveClear()
flex.modemOff()
