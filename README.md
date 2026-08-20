# ccscripts

ComputerCraft/CC:Tweaked turtle automation: mining, tunneling, and a
small package manager so you can install and update it all straight
from GitHub instead of copying files into your save by hand.

## Requirements

- CC:Tweaked, with the `http` API enabled server-side.
- If the server restricts HTTP to an allowlist, `raw.githubusercontent.com`
  needs to be on it.

## Install

On a turtle or computer:

```
wget run https://raw.githubusercontent.com/vusys/ccscripts/main/install.lua
```

This downloads `pkg.lua` (the package manager) along with `dig.lua`,
`flex.lua`, `quarry.lua`, and the default config files. From then on,
`pkg` handles everything else.

## Using pkg

```
pkg list                     -- what's available, what's installed, what's out of date
pkg install <name> [name...] -- install a package + its dependencies
pkg update [name...]         -- update one thing, or everything installed
pkg remove <name>            -- uninstall (never deletes your config data)
pkg refresh                  -- force re-fetch of manifest.json
```

Example: `pkg install tunnel fasttunnel`.

## Programs

- **quarry** `<length> [width] [depth] [skip <N>] [dump] [nolava] [nether]`
  Zigzag strip-mines a rectangular volume, layer by layer. Survives a
  reboot mid-job. `dump` auto-empties into a chest when full; `nolava`
  disables sealing lava at the quarry's edges; `nether` reserves more
  building-block stock for that.
- **tunnel** `<width> <height> <length> [return]`
  Digs a rectangular tunnel, `width` must be odd. `return` sends it
  back to the start when done.
- **fasttunnel** `<length>`
  A fixed 3x3 tunnel digger optimized to avoid backtracking.
- **dig-cli** `<save [slot]|load <slot>|clear|edit [dig|flex]|colors>`
  Save/restore a parked job, clear a stuck auto-resume trigger, or edit
  the dig/flex config files.
- **monitor** `[timeout]`
  Live wireless dashboard for anything broadcasting status via
  `flex.sendData()` -- quarry does, out of the box. Run it on any
  computer with a wireless modem on the same `modem_channel` as your
  turtles (default 6464 for everyone). If a `monitor` peripheral is
  attached it renders there; otherwise it uses the terminal. `timeout`
  is how many seconds of silence before a turtle is shown OFFLINE
  (default 30). Press `Q` to quit. Not installed by default --
  `pkg install monitor`.

## Wireless status

`quarry` broadcasts a small status update (position, fuel, dug count,
state -- mining/paused/refueling/dumping/done/stuck) on state changes
and periodically while running, in addition to the human-readable
pause/complete/error messages it's always sent. `monitor` listens for
these and renders a live per-turtle dashboard. Both just need
`flex_options.cfg`'s `modem_channel` to match (it does by default).

This uses `flex.sendData(table)`, not `flex.send(string)` -- see
Architecture below. Any program can call it to show up on `monitor`;
the only requirement is a `kind` field in the table so a listener can
tell message shapes apart (`monitor` looks for `kind == "quarry_status"`
specifically, but ignores anything else it doesn't recognize rather
than erroring on it).

## Architecture

This repo is organized into folders, but everything installs **flat**
into one directory on the turtle (`manifest.json` maps each repo path
to a flat on-device filename) -- turtles resolve `require()` relative
to the requiring program's own directory, so a flat install just works
without any `package.path` setup.

```
install.lua        -- bootstrap, wget'd once
pkg.lua             -- package manager, installed by install.lua
manifest.json         -- source of truth for what pkg can install
lib/
  flex.lua             -- utility API (require("flex")): inventory
                          consolidation, wireless status broadcasting,
                          colored terminal output (#X inline hex color
                          codes), block/item classification helpers
  dig.lua               -- motion, mining, and crash-recovery API
                          (require("dig")): coordinate-tracked movement,
                          dig-through-obstacle retry with a stuck
                          timeout, fuel management, save/resume state
programs/
  quarry.lua             -- see Programs, below
  tunnel.lua
  fasttunnel.lua
  dig-cli.lua
  monitor.lua
config/
  dig_options.default.cfg -- shipped defaults, copied to dig_options.cfg
  flex_options.default.cfg   on first install only (pkg won't clobber
                              a live, edited config)
```

## Roadmap

More automation is the long-term goal -- e.g. autonomous tree-farming
turtles -- added as new `manifest.json` entries without any change to
the installer/pkg architecture.
