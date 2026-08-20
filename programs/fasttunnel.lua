-- Digs a 3x3 tunnel optimized for speed
-- Turtle starts at floor level, center
-- Zigzags left/right to avoid backtracking
-- Usage: fasttunnel <length>

local flex = require("flex")
local dig = require("dig")


local args = {...}
if #args < 1 then
 flex.printColors(
   "fasttunnel <length>",
   colors.lightBlue)
 return
end --if

local length = tonumber(args[1])
if not length or length < 1 then
 flex.send("Invalid length", colors.red)
 return
end --if


-- Save/resume support
local reloaded = false
if dig.saveExists() then
 reloaded = true
 dig.loadCoords()
end --if
dig.makeStartup("fasttunnel", args)

dig.setFuelSlot(1)


-- Dig above and below current position
local function clearColumn()
 dig.dig("up")
 dig.dig("down")
end --function


-- First slice from center; ends at X=+1 R=90
local function clearFirstSlice()
 dig.fwd()
 clearColumn()
 dig.left()
 dig.fwd()
 clearColumn()
 dig.right()
 dig.right()
 dig.fwd()
 dig.fwd()
 clearColumn()
end --function


-- Slice entering from right; ends at X=-1 R=270
local function clearSliceFromRight()
 dig.left()
 dig.fwd()
 clearColumn()
 dig.left()
 dig.fwd()
 clearColumn()
 dig.fwd()
 clearColumn()
end --function


-- Slice entering from left; ends at X=+1 R=90
local function clearSliceFromLeft()
 dig.right()
 dig.fwd()
 clearColumn()
 dig.right()
 dig.fwd()
 clearColumn()
 dig.fwd()
 clearColumn()
end --function


-- true = turtle at X=+1 R=90
-- false = turtle at X=-1 R=270
local atRight = true


if reloaded then
 flex.send("Resuming fasttunnel", colors.yellow)
 dig.gotor(0)
 dig.gotoy(1)
 dig.gotox(0)

 if dig.getz() > 0 then
  -- Re-clear current slice from center
  clearColumn()
  dig.left()
  dig.fwd()
  clearColumn()
  dig.right()
  dig.right()
  dig.fwd()
  dig.fwd()
  clearColumn()
  -- Now at X=+1, R=90
  atRight = true

  if dig.getz() % 2 == 0 then
   -- Should be at left side
   dig.left()
   dig.left()
   dig.fwd()
   dig.fwd()
   atRight = false
  end --if
 end --if

else
 flex.send("#B Fast Tunnel: #F"..
   tostring(length).."#B blocks")
 dig.up()
end --if/else


while dig.getz() < length do

 if dig.getz() == 0 then
  clearFirstSlice()
  atRight = true
 elseif atRight then
  clearSliceFromRight()
  atRight = false
 else
  clearSliceFromLeft()
  atRight = true
 end --if/else

 if dig.isStuck() then
  flex.send("Hit unbreakable block!", colors.red)
  break
 end --if

 -- Inventory management
 if turtle.getItemCount(16) > 0 then
  flex.condense(2)
  if turtle.getItemCount(14) > 0 then
   dig.doDumpDown()
  end --if
 end --if

 -- Progress
 if dig.getz() % 50 == 0 then
  flex.send("#8 Progress: #F"..
    tostring(dig.getz()).."#8/#F"..
    tostring(length))
 end --if

end --while


-- Return to center and floor
dig.gotox(0)
dig.gotor(0)
dig.down()

flex.send("#A Tunnel complete! #F"..
  tostring(dig.getz()).."#A blocks, #F"..
  tostring(dig.getdug()).."#A dug")

dig.saveClear()
flex.modemOff()
