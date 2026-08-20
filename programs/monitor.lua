-- monitor.lua
--
-- Companion dashboard for anything broadcasting structured status via
-- lib/job.lua's wireless heartbeat (kind="job_status") -- every
-- job-shaped program (quarry.lua, treefarm.lua, ...) does, out of the
-- box, since they all build on the same lib/job.lua scaffold. Run on
-- any computer with a wireless modem, listening on the same
-- modem_channel as your turtles (flex_options.cfg, default 6464 for
-- everyone). If a "monitor" peripheral is attached, the dashboard
-- renders there instead of the terminal; otherwise it uses the
-- terminal.
--
-- Usage: monitor [timeout]
--   timeout   seconds of silence before a turtle is shown OFFLINE
--             (default 30)
--
-- Requiring flex.lua already opens the wireless modem on the right
-- channel as a side effect -- this program just listens for
-- "modem_message" events and renders whatever shows up.

local flex = require("flex")

if not flex.hasWirelessModem() then
  print("No wireless modem attached -- monitor needs one to listen on.")
  return
end

local args = { ... }
local staleAfterMs = (tonumber(args[1]) or 30) * 1000

-- ===========================================================================
-- Render target: a "monitor" peripheral if one's attached, else the
-- terminal. term.redirect() makes every plain term.* call (including the
-- ones inside flex.printColors) go to the new target from here on.
-- ===========================================================================

local originalTerm = term.current()
local screen = peripheral.find("monitor")
if screen then
  term.redirect(screen)
  if screen.setTextScale then
    screen.setTextScale(0.5)
  end
end

-- ===========================================================================
-- State: last known status per turtle (by computer id), plus a small
-- scrolling log of plain-text flex.send() messages from anything on the
-- channel (quarry's pause/complete/error messages, etc.).
-- ===========================================================================

local turtles = {}
local log = {}
local LOG_LINES = 6

-- Common vocabulary from lib/job.lua, plus "mining" (quarry's
-- workingState -- kept as its own entry for a nicer color than the
-- generic default). Any job kind's workingState not listed here (a
-- future "farming"/"building"/...) just falls through to the unknown-
-- state default below rather than needing an entry added here too.
local STATE_COLOR = {
  working = colors.lime,
  mining = colors.lime,
  farming = colors.lime,
  building = colors.lime,
  bridging = colors.lime,
  digging = colors.lime,
  paused = colors.yellow,
  refueling = colors.orange,
  dumping = colors.orange,
  returning = colors.orange,
  done = colors.lightBlue,
  stuck = colors.red,
}

local function formatFuel(t)
  if t.fuel == nil then
    return "?"
  end
  if t.fuel == "unlimited" then
    return "unlimited"
  end
  if type(t.fuelLimit) == "number" and t.fuelLimit > 0 then
    return t.fuel .. "/" .. t.fuelLimit
  end
  return tostring(t.fuel)
end

local function formatProgress(t)
  if type(t.total) ~= "number" or t.total <= 0 then
    return tostring(t.dug or 0) .. " dug"
  end
  local dug = t.dug or 0
  local pct = math.floor((dug / t.total) * 100)
  if pct > 100 then
    pct = 100
  end
  return dug .. "/" .. t.total .. " (" .. pct .. "%)"
end

-- Job-specific detail (quarry's length/width/depth/skip, etc.) as a
-- compact "key=value key=value" line -- sorted so the same job kind
-- renders in a stable order across broadcasts (and is trivially
-- testable) instead of whatever order pairs() happens to walk in.
local function formatExtra(t)
  if type(t.extra) ~= "table" then
    return nil
  end
  local keys = {}
  for k in pairs(t.extra) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  if #keys == 0 then
    return nil
  end
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = tostring(k) .. "=" .. tostring(t.extra[k])
  end
  return table.concat(parts, " ")
end

-- ===========================================================================
-- Rendering.
-- ===========================================================================

local function render()
  term.clear()
  local w, h = term.getSize()

  term.setCursorPos(1, 1)
  flex.printColors("#BTurtle Monitor #8(channel " .. flex.getModemChannel() .. ")")

  local now = os.epoch("utc")
  local ids = {}
  for id in pairs(turtles) do
    ids[#ids + 1] = id
  end
  table.sort(ids)

  local row = 3
  local logStart = math.max(row, h - LOG_LINES - 1)

  if #ids == 0 then
    term.setCursorPos(1, row)
    flex.printColors("#8Waiting for status broadcasts...")
  end

  for _, id in ipairs(ids) do
    if row >= logStart - 1 then
      break
    end
    local t = turtles[id]
    local offline = (now - t.lastSeen) > staleAfterMs
    local state = offline and "offline" or (t.state or "?")
    local color = offline and colors.gray or (STATE_COLOR[t.state] or colors.white)
    local hex = flex.getHex(color)

    term.setCursorPos(1, row)
    local name = flex.escapeMarkup(t.label or ("turtle #" .. id))
    local jobLabel = flex.escapeMarkup(t.job or "?")
    flex.printColors("#F" .. name .. " #7(" .. jobLabel .. ") #8[#" .. hex .. state .. "#8]")
    row = row + 1

    if row < logStart then
      term.setCursorPos(1, row)
      flex.printColors(
        "  #8pos (#F" .. t.x .. "#8,#F" .. t.y .. "#8,#F" .. t.z .. "#8) "
          .. "fuel #F" .. formatFuel(t) .. " #8dug #F" .. formatProgress(t)
      )
      row = row + 1
    end

    local extraLine = formatExtra(t)
    if extraLine and row < logStart then
      term.setCursorPos(1, row)
      flex.printColors("  #8" .. extraLine)
      row = row + 1
    end
  end

  term.setCursorPos(1, logStart)
  flex.printColors("#B-- recent --")
  for i = 1, math.min(LOG_LINES, h - logStart) do
    if log[i] then
      term.setCursorPos(1, logStart + i)
      flex.printColors(log[i])
    end
  end
end

render()

-- ===========================================================================
-- Event loop. Any "job_status"-kind table becomes a dashboard row; any
-- plain string becomes a log line; anything else is ignored. Press Q
-- to quit.
-- ===========================================================================

while true do
  local event, a, b, c, message = os.pullEvent()

  if event == "modem_message" then
    if type(message) == "table" and message.kind == "job_status" then
      message.lastSeen = os.epoch("utc")
      turtles[message.id] = message
      render()
    elseif type(message) == "string" then
      table.insert(log, 1, message)
      while #log > LOG_LINES do
        table.remove(log)
      end
      render()
    end
  elseif event == "key" then
    local key = a
    if key == keys.q then
      break
    end
  elseif event == "term_resize" or event == "monitor_resize" then
    render()
  end
end

term.redirect(originalTerm)
term.clear()
term.setCursorPos(1, 1)
