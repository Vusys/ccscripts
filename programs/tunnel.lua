-- Digs a rectangular tunnel
-- Turtle starts at floor-center
-- <width> must be odd
-- Usage: tunnel <width> <height> <length> [return]

local flex = require("flex")
local dig = require("dig")


local args = {...}
if #args < 3 then
 flex.printColors(
   "tunnel <width> <height> <length> [return]",
   colors.lightBlue)
 return
end --if


local width = tonumber(args[1])
local height = tonumber(args[2])
local length = tonumber(args[3])
local doReturn = false

for x=4,#args do
 if args[x] == "return" then
  doReturn = true
 end --if
end --for

if not width or not height or not length then
 flex.send("Invalid dimensions", colors.red)
 return
end --if

if width % 2 == 0 then
 flex.send("Width must be odd", colors.red)
 return
end --if

if width < 1 or height < 1 or length < 1 then
 flex.send("Dimensions must be positive", colors.red)
 return
end --if


-- Save/resume support
local reloaded = false
if dig.saveExists() then
 reloaded = true
 dig.loadCoords()
end --if
dig.makeStartup("tunnel", args)


local halfW = (width - 1) / 2
local xStart = -halfW
local xEnd = halfW
local sliceSize = width * height

flex.send("#B Tunnel: #F"..
  tostring(width).."#Bx#F"..
  tostring(height).."#Bx#F"..
  tostring(length))


-- Main loop
for z = 1, length do

 -- Skip slices already done on reload
 if dig.getz() < z then
  dig.fwd(1)
 end --if

 -- Sweep cross-section if not already past this slice
 if dig.getz() == z then

  -- Move to left edge
  if halfW > 0 then
   dig.gotox(xStart)
  end --if

  -- Serpentine columns left to right
  for col = 0, width - 1 do
   local x = xStart + col
   if col > 0 then
    dig.gotox(x)
   end --if

   if col % 2 == 0 then
    -- Even column: go up
    if height > 1 then
     dig.gotoy(height - 1)
    end --if
   else
    -- Odd column: go down
    if height > 1 then
     dig.gotoy(0)
    end --if
   end --if/else
  end --for columns

  -- Return to floor-center for next slice
  dig.goto(0, 0, z, 0)

 end --if at this slice

end --for slices


-- Done
if doReturn then
 dig.goto(0, 0, 0, 0)
end --if

flex.send("#A Tunnel complete! #F"..
  tostring(dig.getdug()).."#A blocks dug")

dig.saveClear()
flex.modemOff()
