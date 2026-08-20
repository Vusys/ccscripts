-- relay.lua
--
-- Rebroadcasts everything heard on modem_channel back out on the same
-- channel, verbatim -- extends effective wireless range between two
-- turtles/computers that can each reach the relay but not each other
-- directly. Wireless modems are range-limited (64 blocks at low
-- altitude, scaling up to 384 at world height -- see ModemPeripheral's
-- doc comment in the CC:Tweaked reference), so a relay sitting between
-- two far-apart job sites is a real, common need once a base gets big.
--
-- Usage: relay
--
-- Deliberately single-hop: a modem never receives its own transmission
-- back (confirmed against CC:Tweaked's ModemPeripheral source --
-- receiveSameDimension()/receiveDifferentDimension() both bail out
-- when `packet.sender() == this`), so exactly one relay on a channel
-- is always safe regardless of how much traffic it repeats. Running
-- two relays whose ranges overlap is NOT safe: each retransmission is
-- a brand new packet from a different sender, so a second relay would
-- hear the first relay's retransmission as if it were original traffic
-- and repeat it right back -- an unbounded ping-pong loop with no
-- protection against it here. Don't deploy overlapping relays.
--
-- No dependency on dig.lua -- like monitor.lua, this never moves
-- anything, just listens and retransmits, so it runs fine on a plain
-- computer with just a wireless modem.

local flex = require("flex")

if not flex.hasWirelessModem() then
  print("No wireless modem attached -- relay needs one.")
  return
end

local channel = flex.getModemChannel()
local sides = flex.getPeripheral("modem")
local modem = peripheral.wrap(sides[1])
modem.open(channel)

print("Relaying channel " .. channel .. ". Press Q to stop.")

local relayedCount = 0
local running = true
while running do
  local event, a, b, c, message = os.pullEvent()
  if event == "modem_message" then
    -- modem_message's full signature is (side, channel, replyChannel,
    -- message, distance) -- `a` is the side, `b`/`c` are channel/replyChannel.
    local recvChannel, replyChannel = b, c
    if recvChannel == channel then
      modem.transmit(channel, replyChannel, message)
      relayedCount = relayedCount + 1
    end
  elseif event == "key" and a == keys.q then
    running = false
  end
end

print("Stopped. Relayed " .. relayedCount .. " message(s).")
modem.close(channel)
