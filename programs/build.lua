-- build.lua
--
-- Constructs a structure from a schematic JSON file already present on
-- the turtle's filesystem, pulling each block by name from whatever's
-- in the inventory.
--
-- Usage: build <schematic.json> [dump]
--   schematic.json  required. Path to a schematic file (see format below).
--   dump            automatically dump dumplist-matching items to a
--                   chest sideways when the inventory fills up.
--
-- Schematic format (a plain JSON object):
--   {
--     "layers": [
--       [
--         ["stone", "stone", "stone"],
--         ["stone", "",      "stone"],
--         ["stone", "stone", "stone"]
--       ]
--     ]
--   }
-- `layers[y+1][x+1][z+1]` is the block for that cell, relative to the
-- turtle's starting position (x=0,z=0 under the turtle, y=0 the layer
-- built directly above where it started standing) -- each layer is an
-- array of X-columns, and each column an array of cells along Z,
-- matching quarry.lua's own X-outer/Z-inner sweep convention. Each cell is a
-- plain string matched by substring against inventory item names
-- (same convention as dig_options.cfg's classification lists) --
-- **empty string, not JSON `null`**, means "leave this cell empty".
-- That's deliberate, not a stylistic choice: textutils.unserialiseJSON
-- turns `null` into a real Lua `nil` by default (see
-- doc/reference/... textutils.lua's `parse_null` option in the
-- CC:Tweaked reference), and a `nil` in the middle of a JSON array
-- turns it into a Lua table with a hole in it -- #row/ipairs over a
-- row would then stop early or skip cells silently. Plain empty
-- strings have no such trap.
--
-- Building strategy: to place a block at layer y, the turtle travels
-- one cell *above* that layer (y+1) and uses placeDown() at each grid
-- position -- so it's never standing where a block needs to go, and
-- by the time layer y+1 is being placed, layer y is already solid
-- beneath it (never in the way of horizontal travel one cell up).
-- Layers are therefore placed bottom-to-top in schematic order.
--
-- Missing materials don't block the build (unlike dig.refuel(), which
-- deliberately waits forever) -- a cell whose block isn't found in the
-- inventory is just skipped, and every skipped block/count is reported
-- in one summary message at the end instead of failing outright or
-- spamming a warning per cell.

local dig = require("dig")
local flex = require("flex")
local job = require("job")

-- ===========================================================================
-- Arguments. Validated (and the schematic loaded and structurally
-- checked) in full before anything touches saved state.
-- ===========================================================================

local args = { ... }
if #args < 1 then
  flex.printColors("build <schematic.json> [dump]", colors.lightBlue)
  return
end

local schematicPath = args[1]
local dodumps = false
for i = 2, #args do
  if args[i] == "dump" then
    dodumps = true
  end
end

local function loadSchematic(path)
  local file = fs.open(path, "r")
  if not file then
    return nil, "file not found: " .. path
  end
  local body = file.readAll()
  file.close()

  local ok, data = pcall(textutils.unserialiseJSON, body)
  if not ok or type(data) ~= "table" or type(data.layers) ~= "table" then
    return nil, "invalid schematic JSON (expected a {layers: [...]} object)"
  end
  for y, layer in ipairs(data.layers) do
    if type(layer) ~= "table" then
      return nil, "layer " .. y .. " is not an array of rows"
    end
    for z, row in ipairs(layer) do
      if type(row) ~= "table" then
        return nil, "layer " .. y .. " row " .. z .. " is not an array of cells"
      end
    end
  end
  return data
end

local schematic, schematicErr = loadSchematic(schematicPath)
if not schematic then
  flex.send("Could not load schematic: " .. schematicErr, colors.red)
  return
end
if #schematic.layers == 0 then
  flex.send("Schematic has no layers -- nothing to build.", colors.orange)
  return
end

-- ===========================================================================
-- Set up dig.lua for this job, then hook into its save/resume mechanism.
-- ===========================================================================

if dig.saveExists() then
  dig.loadCoords()
end
dig.makeStartup("build", args)

flex.send("#B Build: #F" .. schematicPath .. "#B (#F" .. #schematic.layers .. "#B layers)")

-- ===========================================================================
-- Job scaffold.
-- ===========================================================================

local currentLayer = 0

local j = job.new({
  kind = "build",
  workingState = "building",
  dump = dodumps,
  fuelEstimate = function()
    local layer = schematic.layers[1] or {}
    local rows = #layer
    local cols = #(layer[1] or {})
    return (rows + cols + #schematic.layers + 1) * 2
  end,
  total = #schematic.layers,
  extra = function()
    return { schematic = schematicPath, layer = currentLayer, of = #schematic.layers }
  end,
})

j.broadcast("building")

-- ===========================================================================
-- Placement.
-- ===========================================================================

local missingCounts = {}

local function selectItem(name)
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 and flex.isItem(name, slot) then
      turtle.select(slot)
      return true
    end
  end
  return false
end

local function placeCell(name)
  if name == nil or name == "" then
    return
  end
  if selectItem(name) then
    dig.placeDown()
  else
    missingCounts[name] = (missingCounts[name] or 0) + 1
  end
end

-- Sweeps one column of the current layer (fixed x, z from zFrom to
-- zTo) -- same boustrophedon-column shape as quarry.lua's mineColumn.
-- `column` is layer[x+1], i.e. indexed by the real x coordinate, not
-- by however many iterations the outer sweep has taken -- that
-- distinction matters once the outer sweep runs in reverse (xStep ==
-- -1), where iteration count and x diverge.
local function buildColumn(column, x, zFrom, zTo, zStep)
  if not dig.gotox(x) then return false end
  if not dig.gotoz(zFrom) then return false end
  if not dig.gotor(zStep > 0 and 0 or 180) then return false end

  local z = zFrom
  while true do
    placeCell(column[z + 1])
    j.checkHalt()
    j.checkFuel()
    j.checkInv()
    j.heartbeat("building")
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

-- Sweeps a whole layer, boustrophedon -- same shape as quarry.lua's
-- mineLayer.
local function buildLayer(layerIndex, layer)
  local cols = #layer
  local rows = #(layer[1] or {})
  if rows == 0 or cols == 0 then
    return true
  end

  local xForward = (layerIndex % 2 == 0)
  local xFrom = xForward and 0 or (cols - 1)
  local xTo = xForward and (cols - 1) or 0
  local xStep = xForward and 1 or -1

  local x = xFrom
  while true do
    local column = layer[x + 1]
    local zForward = (x % 2 == 0)
    local zFrom = zForward and 0 or (rows - 1)
    local zTo = zForward and (rows - 1) or 0
    local zStep = zForward and 1 or -1

    if not buildColumn(column, x, zFrom, zTo, zStep) then
      return false
    end

    if x == xTo then
      break
    end
    x = x + xStep
  end
  return true
end

-- ===========================================================================
-- Main loop: one control pass per schematic layer, one cell above
-- where that layer's blocks actually land. Layer index and control
-- height coincide 1:1 (control height for schematic layer index N is
-- N), so a resumed run can pick straight back up at whatever control
-- height dig.loadCoords() restored -- no separate progress bookkeeping
-- needed, same reasoning as quarry.lua's y-depth resume. Re-walking a
-- partially-built layer from its start is safe: an already-filled
-- cell just makes placeDown() fail harmlessly (not a fluid, so
-- dig.place() returns false immediately rather than retrying).
-- ===========================================================================

local stoppedEarly = false
local startLayerIndex = math.max(1, dig.gety())

for layerIndex = startLayerIndex, #schematic.layers do
  currentLayer = layerIndex - 1
  local layer = schematic.layers[layerIndex]
  if not dig.gotoy(layerIndex) then
    stoppedEarly = dig.isStuck()
    break
  end
  if not buildLayer(currentLayer, layer) then
    stoppedEarly = dig.isStuck()
    break
  end
  j.broadcast("building")
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

local missingList = {}
for name, count in pairs(missingCounts) do
  missingList[#missingList + 1] = name .. " x" .. count
end
if #missingList > 0 then
  flex.send("#EMissing materials, skipped: #F" .. table.concat(missingList, ", "), colors.orange)
end

if stoppedEarly then
  flex.send(
    "#EBuild stopped early (obstruction near " .. dig.getStuckDir() .. ").",
    colors.red
  )
  j.broadcast("stuck")
else
  flex.send("#ABuild complete!", colors.lime)
  j.broadcast("done")
end

dig.saveClear()
flex.modemOff()
