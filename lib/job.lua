-- job.lua
--
-- Shared "supervised job" scaffold for long-running turtle programs
-- (quarry.lua, treefarm.lua, ...): the periodic housekeeping every one
-- of them needs -- a low-fuel round trip, an inventory-full round
-- trip, a redstone pause/resume gate, and a throttled wireless status
-- heartbeat -- lives here once instead of being reimplemented (and
-- re-debugged -- see quarry.lua's git history) per program.
--
-- Loaded with require("job"); job.new(opts) returns a fresh job
-- instance (a table of closures). Unlike dig.lua/flex.lua, which are
-- singletons (a program only ever drives one turtle, so module-level
-- state is fine), this is a factory: a program could in principle run
-- more than one job in sequence, and each needs its own throttle timer
-- and milestone counters.
--
-- opts:
--   kind           required string, e.g. "quarry"/"treefarm" -- goes
--                  in the wireless job_status.job field so a listener
--                  like programs/monitor.lua can label the row.
--   fuelEstimate   required number, or a zero-arg function returning
--                  one -- the fuel level below which checkFuel() heads
--                  back to base and blocks on dig.refuel().
--   dump           boolean, default false -- whether checkInv() tries
--                  dig.doDump() (a sideways dump via the dumplist)
--                  once turtle slot 16 has anything in it, before
--                  falling back to a base trip if slot 14 is still
--                  full afterward.
--   total          optional number, or a zero-arg function returning
--                  one -- denominator for the wireless dug/total
--                  progress field; omitted from the broadcast if not
--                  given.
--   extra          optional zero-arg function returning a plain table
--                  merged into the wireless broadcast's `extra` field
--                  -- job-specific detail (quarry's length/width/
--                  depth/skip, for instance) that isn't part of the
--                  common shape.
--   workingState   optional string, default "working" -- the state
--                  name broadcast once a fuel/inventory/pause round
--                  trip finishes and normal operation resumes.
--   milestoneEvery optional number, default 1000 -- dug-count interval
--                  between flex.send() progress reports to a person
--                  watching the terminal (separate from the wireless
--                  heartbeat, which is throttled by time, not count).
--
-- A job instance `j` exposes:
--   j.broadcast(state)            immediate wireless status broadcast
--   j.heartbeat(state)             time-throttled variant (>=10s apart)
--   j.checkFuel()                   refuel round-trip when low
--   j.checkInv()                     dump/unload round-trip when full
--   j.checkHalt()                     redstone pause/resume gate
--   j.checkProgress()                  milestone flex.send + heartbeat
--   j.gotoBase()/j.returnFromBase(saved)  base round-trip primitives,
--                                          exposed for a program that
--                                          needs extra choreography
--                                          around its own base trips
--                                          (quarry's lava-sealing, a
--                                          final placeDown, etc.)

local dig = require("dig")
local flex = require("flex")

local M = {}

local BROADCAST_INTERVAL_MS = 10000

local function resolve(v)
  if type(v) == "function" then
    return v()
  end
  return v
end

local function new(opts)
  opts = opts or {}
  if not opts.kind then
    error("job.new: opts.kind is required", 2)
  end

  local kind = opts.kind
  local fuelEstimate = opts.fuelEstimate or 0
  local dumpEnabled = opts.dump or false
  local totalFn = opts.total
  local extraFn = opts.extra
  local workingState = opts.workingState or "working"
  local milestoneEvery = opts.milestoneEvery or 1000

  local lastBroadcast = 0
  local lastReportedDug = dig.getdug()

  local j = {}

  local function broadcast(state)
    if not flex.hasWirelessModem() then
      return
    end
    lastBroadcast = os.epoch("utc")
    flex.sendData({
      kind = "job_status",
      job = kind,
      id = os.getComputerID(),
      label = os.getComputerLabel(),
      state = state,
      x = dig.getx(),
      y = dig.gety(),
      z = dig.getz(),
      r = dig.getr(),
      fuel = turtle.getFuelLevel(),
      fuelLimit = turtle.getFuelLimit(),
      dug = dig.getdug(),
      total = totalFn and resolve(totalFn) or nil,
      extra = extraFn and resolve(extraFn) or nil,
    })
  end

  -- Keeps "last seen" fresh on a listener even when nothing else about
  -- the job is changing (paused, refueling, ...), without flooding the
  -- channel on every single cell.
  local function heartbeat(state)
    if os.epoch("utc") - lastBroadcast >= BROADCAST_INTERVAL_MS then
      broadcast(state)
    end
  end

  local function gotoBase()
    local saved = dig.location()
    dig.gotoy(0)
    dig.gotox(0)
    dig.gotoz(0)
    dig.gotor(180)
    return saved
  end

  local function returnFromBase(saved)
    dig.goto(saved)
  end

  local function checkFuel()
    local level = turtle.getFuelLevel()
    if level == "unlimited" then
      return
    end
    local estimate = resolve(fuelEstimate)
    if level < estimate then
      broadcast("refueling")
      local saved = gotoBase()
      dig.dropNotFuel()
      turtle.suckUp()
      dig.refuel(estimate)
      returnFromBase(saved)
      broadcast(workingState)
    end
  end

  local function checkInv()
    if turtle.getItemCount(16) > 0 then
      if dumpEnabled then
        dig.right(2)
        dig.doDump()
        dig.left(2)
      end
      if turtle.getItemCount(14) > 0 then
        broadcast("dumping")
        local saved = gotoBase()
        dig.dropNotFuel()
        returnFromBase(saved)
        broadcast(workingState)
      end
    end
  end

  local function checkHalt()
    if not rs.getInput("top") then
      return
    end

    flex.send("Paused. ENTER to resume, SPACE to return to base and wait.", colors.yellow)
    broadcast("paused")
    local saved = dig.location()
    local wentToBase = false

    while rs.getInput("top") do
      local key = flex.getKey()
      if key == keys.space and not wentToBase then
        gotoBase()
        wentToBase = true
      elseif key == keys.enter then
        break
      end
    end

    if wentToBase then
      returnFromBase(saved)
    end
    flex.send("Resuming.", colors.lime)
    broadcast(workingState)
  end

  local function checkProgress()
    local dug = dig.getdug()
    local milestoneHit = false
    if dug - lastReportedDug >= milestoneEvery then
      lastReportedDug = dug
      flex.send("#8Progress: #F" .. dug .. "#8 blocks dug")
      milestoneHit = true
    end

    if milestoneHit then
      broadcast(workingState)
    else
      heartbeat(workingState)
    end
  end

  j.broadcast = broadcast
  j.heartbeat = heartbeat
  j.checkFuel = checkFuel
  j.checkInv = checkInv
  j.checkHalt = checkHalt
  j.checkProgress = checkProgress
  j.gotoBase = gotoBase
  j.returnFromBase = returnFromBase

  return j
end

M.new = new

return M
