-- dig-cli.lua
--
-- Small command-line front-end for the bits of dig.lua/flex.lua state
-- that are a person's business, not a program's: saving/loading a
-- parked job, clearing a stuck auto-resume, and editing the config
-- files. This used to live as a top-level CLI dispatch built into
-- dig.lua itself; it's a separate program now so dig.lua can be a pure
-- require()-able module with no side effects beyond returning its API.
--
-- Usage:
--   dig-cli save [slot]      -- park the current job, freeing dig_save.cfg
--                                / startup.lua for a new one
--   dig-cli load <slot>      -- restore a parked job (reboot to resume it)
--   dig-cli clear            -- delete the auto-resume trigger
--   dig-cli edit [dig|flex]  -- open a config file, reload it on save
--   dig-cli colors           -- preview the #0-#F terminal color codes

local dig = require("dig")
local flex = require("flex")

local function nextSaveSlot()
  local n = 1
  while fs.exists("startup_" .. n .. ".lua") or fs.exists("dig_save_" .. n .. ".cfg") do
    n = n + 1
  end
  return n
end

local function cmdSave(slotArg)
  if not dig.saveExists() then
    flex.printColors("Nothing to save.", colors.red)
    return
  end

  local slot = tonumber(slotArg) or nextSaveSlot()
  local ok, err = pcall(function()
    fs.move("startup.lua", "startup_" .. slot .. ".lua")
    fs.move("dig_save.cfg", "dig_save_" .. slot .. ".cfg")
  end)
  if not ok then
    flex.printColors("Could not save to slot " .. slot .. ": " .. tostring(err), colors.red)
    return
  end
  flex.printColors("Saved to slot #F" .. slot .. "#0. Restore with: #Fdig-cli load " .. slot)
end

local function cmdLoad(slotArg)
  local slot = tonumber(slotArg)
  if not slot then
    flex.printColors("Usage: dig-cli load <slot>", colors.lightBlue)
    return
  end
  if not (fs.exists("startup_" .. slot .. ".lua") and fs.exists("dig_save_" .. slot .. ".cfg")) then
    flex.printColors("No saved job in slot " .. slot .. ".", colors.red)
    return
  end

  dig.saveClear()
  if fs.exists("dig_save.cfg") then
    fs.delete("dig_save.cfg")
  end
  fs.move("startup_" .. slot .. ".lua", "startup.lua")
  fs.move("dig_save_" .. slot .. ".cfg", "dig_save.cfg")
  flex.printColors("Loaded slot #F" .. slot .. "#0. Reboot to resume it.")
end

local function cmdClear()
  dig.saveClear()
  flex.printColors("Cleared the saved job (startup.lua removed).", colors.lime)
end

local function cmdEdit(which)
  if which == "flex" then
    shell.run("edit", "flex_options.cfg")
    flex.optionsImport()
  else
    shell.run("edit", "dig_options.cfg")
    dig.optionsImport()
  end
  flex.printColors("Reloaded.", colors.lime)
end

local function cmdColors()
  local chars = "0123456789ABCDEF"
  for c in chars:gmatch(".") do
    flex.printColors("#" .. c .. "Color " .. c)
  end
end

local args = { ... }
local sub = args[1]

if sub == "save" then
  cmdSave(args[2])
elseif sub == "load" then
  cmdLoad(args[2])
elseif sub == "clear" then
  cmdClear()
elseif sub == "edit" then
  cmdEdit(args[2])
elseif sub == "colors" or sub == "color" then
  cmdColors()
else
  flex.printColors(
    "Usage: dig-cli <save [slot]|load <slot>|clear|edit [dig|flex]|colors>",
    colors.lightBlue
  )
end
