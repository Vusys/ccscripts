-- flex.lua
--
-- Shared utility API used by dig.lua and the programs built on it:
-- inventory consolidation, wireless status broadcasting, colored
-- terminal output (inline "#X" hex color codes), and simple block/item
-- classification helpers.
--
-- Loaded with require("flex"); returns a table of functions. All
-- internal state (config, modem handle, log path) is closed over as
-- upvalues here -- nothing leaks into the global namespace the way the
-- old os.loadAPI version did.

local M = {}

-- ===========================================================================
-- Config (flex_options.cfg): plain "key=value" lines.
-- ===========================================================================

local OPTIONS_FILE = "flex_options.cfg"
local LOG_FILE = "log.txt"

local modemChannel = 6464
local nameColorName = term.isColor() and "yellow" or "lightGray"

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Returns true if flex_options.cfg existed and was read.
local function optionsImport()
  local file = fs.open(OPTIONS_FILE, "r")
  if not file then
    return false
  end
  local line = file.readLine()
  while line do
    local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if key == "modem_channel" then
      modemChannel = tonumber(value) or modemChannel
    elseif key == "name_color" then
      nameColorName = trim(value)
    end
    line = file.readLine()
  end
  file.close()
  return true
end

local function optionsExport()
  fs.delete(OPTIONS_FILE)
  local file = fs.open(OPTIONS_FILE, "w")
  if not file then
    error("flex: could not write " .. OPTIONS_FILE, 2)
  end
  file.writeLine("# Flex API options #")
  file.writeLine("")
  file.writeLine("modem_channel=" .. modemChannel)
  file.writeLine("name_color=" .. nameColorName)
  file.writeLine("")
  file.close()
end

M.optionsImport = optionsImport
M.optionsExport = optionsExport

-- ===========================================================================
-- Color helpers: colors.* constants are powers of two (colors.white=1,
-- colors.orange=2, ...), so a single hex digit 0-F maps 1:1 onto them.
-- ===========================================================================

local HEX_CHARS = "0123456789ABCDEF"

local function getVal(hexChar)
  local idx = HEX_CHARS:find(hexChar:upper(), 1, true)
  if not idx then
    return colors.white
  end
  return 2 ^ (idx - 1)
end

local function getHex(colorConstant)
  -- colorConstant is always an exact power of two (1, 2, 4, ... 32768);
  -- count doublings rather than use math.log(x, base), which is a Lua
  -- 5.2+ feature not available on CC:Tweaked's Lua 5.1.
  local idx, v = 1, colorConstant
  while v > 1 do
    v = v / 2
    idx = idx + 1
  end
  return HEX_CHARS:sub(idx, idx)
end

M.getVal = getVal
M.getHex = getHex

-- ===========================================================================
-- Misc numeric/string helpers.
-- ===========================================================================

local function round(n, places)
  local mult = 10 ^ (places or 0)
  return math.floor(n * mult + 0.5) / mult
end

local function tostr(num, len)
  local s = string.format("%.10f", num)
  s = s:gsub("(%..-)0+$", "%1"):gsub("%.$", "")
  if len then
    while #s > len and s:find("%.") do
      s = s:sub(1, #s - 1):gsub("%.$", "")
    end
  end
  return s
end

M.round = round
M.tostr = tostr

-- ===========================================================================
-- Peripheral / modem discovery.
-- ===========================================================================

local SIDES = { "top", "bottom", "left", "right", "front", "back" }

local function getPeripheral(name)
  local matches = {}
  for _, side in ipairs(SIDES) do
    if peripheral.getType(side) == name then
      matches[#matches + 1] = side
    end
  end
  return matches
end

M.getPeripheral = getPeripheral

local modem, hasModem = nil, false

local function openModem()
  local sides = getPeripheral("modem")
  if sides[1] then
    modem = peripheral.wrap(sides[1])
    modem.open(modemChannel)
    hasModem = true
  end
end

local function modemOff()
  if hasModem and modem then
    modem.close(modemChannel)
  end
end

M.modemOff = modemOff

-- ===========================================================================
-- Logging. log.txt is created automatically by fs.open(..., "a") on the
-- first write, so there's nothing to bootstrap at load time.
-- ===========================================================================

local function logMessage(text)
  local file = fs.open(LOG_FILE, "a")
  if file then
    file.writeLine(text)
    file.close()
  end
end

-- ===========================================================================
-- Colored terminal output.
--
-- "#X" (X = one hex digit) switches the text color from that point on.
-- "##" is a literal "#". On a non-color terminal, markup is stripped and
-- printed as plain text instead of calling color functions the hardware
-- doesn't support.
-- ===========================================================================

-- Escapes a string for safe embedding in a printColors()/send()-formatted
-- message: any string that ISN'T a literal you wrote yourself (a
-- computer label, in particular) needs this before being concatenated
-- in, since a literal "#" immediately followed by a hex digit -- entirely
-- plausible in free-form text -- would otherwise be misread as a
-- color-switch escape instead of printed as-is.
local function escapeMarkup(s)
  return (tostring(s):gsub("#", "##"))
end

M.escapeMarkup = escapeMarkup

local function parseColorRuns(message, startColor)
  local runs = {}
  local color = startColor
  local buf = {}
  local i = 1
  local function flush()
    if #buf > 0 then
      runs[#runs + 1] = { color = color, text = table.concat(buf) }
      buf = {}
    end
  end
  while i <= #message do
    local c = message:sub(i, i)
    if c == "#" then
      local nextChar = message:sub(i + 1, i + 1)
      if nextChar == "#" then
        buf[#buf + 1] = "#"
        i = i + 2
      elseif nextChar:match("[0-9A-Fa-f]") then
        flush()
        color = getVal(nextChar)
        i = i + 2
      else
        buf[#buf + 1] = c
        i = i + 1
      end
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  flush()
  return runs
end

local function stripColorMarkup(message)
  return (message:gsub("##", "\1"):gsub("#[0-9A-Fa-f]", ""):gsub("\1", "#"))
end

local function advanceCursor(w, h)
  local x, y = term.getCursorPos()
  if x > w then
    if y >= h then
      term.scroll(1)
      term.setCursorPos(1, h)
    else
      term.setCursorPos(1, y + 1)
    end
  end
end

local function newline(h)
  local _, y = term.getCursorPos()
  if y >= h then
    term.scroll(1)
    term.setCursorPos(1, h)
  else
    term.setCursorPos(1, y + 1)
  end
end

local printColors -- forward declaration; printTable and printColors call each other

local function printTable(t, depth)
  local indent = string.rep("  ", depth)
  print(indent .. "{")
  for k, v in pairs(t) do
    if type(v) == "table" then
      print(indent .. "  " .. tostring(k) .. " =")
      printTable(v, depth + 1)
    else
      printColors(indent .. "  " .. tostring(k) .. " #0= #F" .. tostring(v))
    end
  end
  print(indent .. "}")
end

printColors = function(message, textColor)
  if type(message) == "table" then
    printTable(message, 0)
    return
  end

  message = tostring(message)
  if type(textColor) == "number" then
    message = "#" .. getHex(textColor) .. message
  end

  local oldColor = term.getTextColor()
  local w, h = term.getSize()

  if not term.isColor() then
    term.write(stripColorMarkup(message))
    print("")
    return
  end

  local runs = parseColorRuns(message, colors.white)
  for _, run in ipairs(runs) do
    term.setTextColor(run.color)
    if run.color == colors.black then
      term.setBackgroundColor(colors.lightGray)
    end
    for ch in run.text:gmatch(".") do
      if ch == "\n" then
        newline(h)
      else
        advanceCursor(w, h)
        term.write(ch)
      end
    end
    if run.color == colors.black then
      term.setBackgroundColor(colors.black)
    end
  end

  term.setTextColor(oldColor)
  print("")
end

M.printColors = printColors

-- ===========================================================================
-- Wireless status broadcasting.
--
-- send() transmits a plain, human-readable string with the same inline
-- "#X" markup as printColors -- meant for a person watching another
-- computer's terminal, echoed locally and logged to log.txt.
--
-- sendData() transmits a raw Lua table instead (CC:Tweaked's modem
-- delivers it back out as a table on the other end, no serialization
-- needed) -- meant for a companion program like programs/monitor.lua to
-- consume programmatically. It is not echoed or logged, since it's
-- meant to be called often (a status heartbeat), not as a one-off
-- human-facing event.
-- ===========================================================================

local function getModemChannel()
  return modemChannel
end

local function hasWirelessModem()
  return hasModem
end

M.getModemChannel = getModemChannel
M.hasWirelessModem = hasWirelessModem

local function send(message, textColor)
  textColor = textColor or colors.white

  if type(message) == "table" then
    -- Tables are for local/log display only; a multi-line pretty-printed
    -- table doesn't fit the single-line wire format below.
    printColors(message)
    logMessage(textutils.serialize(message))
    return
  end

  message = (message == nil) and "nil" or tostring(message)

  printColors(message, textColor)
  logMessage(message)

  if hasModem then
    local nameColor = colors[nameColorName] or colors.white
    local id = "#" .. getHex(nameColor) .. tostring(os.getComputerID())
    local label = os.getComputerLabel()
    if label then
      id = id .. "#0|#" .. getHex(nameColor) .. escapeMarkup(label)
    end
    local wireMessage = id .. "#0: #" .. getHex(textColor) .. message
    modem.transmit(modemChannel, modemChannel + 1, wireMessage)
    sleep(0.1)
  end
end

M.send = send

-- data must be a plain table (a "kind" field is a good idea so a
-- receiver listening for several message shapes can tell them apart --
-- see programs/quarry.lua and programs/monitor.lua for an example).
local function sendData(data)
  if type(data) ~= "table" then
    error("sendData: data must be a table", 2)
  end
  if hasModem then
    modem.transmit(modemChannel, modemChannel + 1, data)
    sleep(0.1)
  end
end

M.sendData = sendData

-- ===========================================================================
-- Inventory consolidation.
-- ===========================================================================

local function condense(startSlot)
  startSlot = math.floor(tonumber(startSlot) or 1)
  if startSlot < 1 or startSlot > 16 then
    startSlot = 1
  end

  local originalSlot = turtle.getSelectedSlot()
  for from = 16, startSlot + 1, -1 do
    while turtle.getItemCount(from) > 0 do
      local fromDetail = turtle.getItemDetail(from)
      local movedAny = false
      for to = startSlot, from - 1 do
        local toCount = turtle.getItemCount(to)
        local toDetail = turtle.getItemDetail(to)
        local sameItem = toDetail and fromDetail and toDetail.name == fromDetail.name
        if toCount == 0 or sameItem then
          turtle.select(from)
          if turtle.transferTo(to) then
            movedAny = true
          end
          if turtle.getItemCount(from) == 0 then
            break
          end
        end
      end
      if not movedAny then
        break
      end
    end
  end
  turtle.select(originalSlot)
end

M.condense = condense

-- ===========================================================================
-- Block detection.
-- ===========================================================================

-- Built lazily (not as a `turtle.inspect` literal here) so merely
-- require()ing flex doesn't crash on a plain computer with no turtle
-- API (e.g. programs/monitor.lua, which never inspects blocks) --
-- only actually calling getBlock()/isBlock() on one does.
local INSPECT = {}
if turtle then
  INSPECT.fwd = turtle.inspect
  INSPECT.up = turtle.inspectUp
  INSPECT.down = turtle.inspectDown
end

-- Returns (blockName, data) where data is the raw turtle.inspect*() table
-- (name/state/tags), or ("minecraft:air", nil) if there's nothing there.
local function getBlock(dir)
  local inspect = INSPECT[dir or "fwd"]
  if not inspect then
    error("getBlock: no turtle API on this computer", 2)
  end
  local ok, data = inspect()
  if not ok then
    return "minecraft:air", nil
  end
  return data.name, data
end

local function getBlockUp()
  return getBlock("up")
end

local function getBlockDown()
  return getBlock("down")
end

M.getBlock = getBlock
M.getBlockUp = getBlockUp
M.getBlockDown = getBlockDown

-- key may be a single string or a table/array of strings. A key containing
-- ":" (e.g. "minecraft:stone") must match the block name exactly; any other
-- key is matched as a substring (e.g. "stone" matches "minecraft:stone").
local function isBlock(key, dir)
  local keys
  if type(key) == "string" then
    keys = { key }
  elseif type(key) == "table" then
    keys = key
  else
    error("isBlock: key must be a string or table of strings", 2)
  end

  local block = getBlock(dir)
  for _, k in ipairs(keys) do
    if k:find(":", 1, true) then
      if block == k then
        return true
      end
    elseif block:find(k, 1, true) then
      return true
    end
  end
  return false
end

local function isBlockUp(key)
  return isBlock(key, "up")
end

local function isBlockDown(key)
  return isBlock(key, "down")
end

M.isBlock = isBlock
M.isBlockUp = isBlockUp
M.isBlockDown = isBlockDown

local FLUIDS = { "air", "water", "lava", "acid", "blood", "poison" }

local function isFluid(dir)
  return isBlock(FLUIDS, dir)
end

local function isFluidUp()
  return isFluid("up")
end

local function isFluidDown()
  return isFluid("down")
end

M.isFluid = isFluid
M.isFluidUp = isFluidUp
M.isFluidDown = isFluidDown

-- key may be a single string or a table/array of strings; always a
-- substring match against the slot's item name. slot defaults to the
-- currently selected slot.
local function isItem(key, slot)
  if key == nil then
    return false
  end
  slot = (type(slot) == "number") and slot or turtle.getSelectedSlot()
  local detail = turtle.getItemDetail(slot)
  if not detail then
    return false
  end

  local keys = (type(key) == "string") and { key } or key
  for _, k in ipairs(keys) do
    if detail.name:find(k, 1, true) then
      return true
    end
  end
  return false
end

M.isItem = isItem

-- ===========================================================================
-- Misc.
-- ===========================================================================

local function getKey()
  local _, key = os.pullEvent("key")
  return key
end

M.getKey = getKey
M.keyPress = getKey

-- ===========================================================================
-- Module init: load config, then open the modem on the *final* channel
-- (fixes the old bug where the modem got opened on the hardcoded default
-- channel before the config file -- which might specify a different
-- channel -- was ever read).
-- ===========================================================================

if not optionsImport() then
  optionsExport()
end
openModem()

return M
