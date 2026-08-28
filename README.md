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

- **quarry** `<length> [width] [depth] [skip <N>] [dump] [nolava] [nether] [vein]`
  Zigzag strip-mines a rectangular volume, layer by layer. Survives a
  reboot mid-job. `dump` auto-empties into a chest when full; `nolava`
  disables sealing lava at the quarry's edges; `nether` reserves more
  building-block stock for that; `vein` chases any ore vein visible
  through the excavated volume's walls/floor/ceiling before continuing
  the sweep, instead of leaving it half-mined at the boundary.
- **treefarm** `<rows> <cols> [passes <N>] [dump]`
  Tends a grid of tree plots forever (or for `passes` cycles): fells
  any mature tree, replants bare ground, leaves an already-growing
  sapling alone. Reboot-resumable the same way quarry is.
- **farm** `<rows> <cols> [passes <N>] [dump]`
  Tends a grid of crop plots (wheat/carrots/potatoes/beetroot/nether
  wart) forever (or for `passes` cycles): harvests and replants
  anything fully grown, leaves an immature crop alone.
- **build** `<schematic.json> [dump]`
  Constructs a structure from a schematic JSON file already on the
  turtle, pulling each block by name from the inventory. Missing
  materials are skipped and reported at the end instead of blocking
  the build. See `programs/build.lua`'s header comment for the
  schematic format.
- **bridge** `<length> [dump]`
  Walks forward in a straight line, placing a block underneath itself
  wherever the ground isn't solid -- crosses a gap, lava, or water.
  Stays at the far end when done.
- **well** `[maxDepth] [dump] [return]`
  Digs straight down until bedrock (or `maxDepth`, if given).
  `return` ascends back to the start when done instead of staying at
  the bottom.
- **corridor** `<length> [return]`
  Digs a straight 1-wide passage: clears the block above and below in
  place at each position (no vertical movement) while advancing
  through the block in front, for `length` blocks. `return` walks back
  to the start when done instead of staying at the far end. No output
  chest needed -- it doesn't manage inventory at all, just mines and
  stops.
- **courier** `<length> [trips <N>] [dump] [idle]`
  Shuttles items between a pickup chest behind the start and a dropoff
  chest ahead of the far end, `length` blocks away. `idle` waits for a
  wireless `courier_request` before each trip instead of shuttling
  continuously.
- **relay** (no args)
  Rebroadcasts everything heard on `modem_channel` back out on the
  same channel, verbatim -- extends effective wireless range between
  two points that can each reach the relay but not each other
  directly. Single-hop only: don't run two relays whose ranges
  overlap.
- **tunnel** `<width> <height> <length> [return]`
  Digs a rectangular tunnel, `width` must be odd. `return` sends it
  back to the start when done. `tunnel` is also the name of a stock
  CC:Tweaked turtle program (`<length>`-only, in `/rom/programs/turtle`)
  -- if this one isn't actually installed (`pkg install tunnel`), the
  shell silently falls back to the stock version instead of erroring,
  which looks like a broken argument parser (`tunnel <w> <h> <l>`
  prints a `tunnel <length>` usage line). Run `pkg list` if `tunnel`
  behaves like it only takes one argument.
- **fasttunnel** `<length>`
  A fixed 3x3 tunnel digger optimized to avoid backtracking.
- **dig-cli** `<save [slot]|load <slot>|clear|edit [dig|flex]|colors>`
  Save/restore a parked job, clear a stuck auto-resume trigger, or edit
  the dig/flex config files.
- **monitor** `[timeout]`
  Live wireless fleet dashboard for anything broadcasting status via
  `lib/job.lua` -- quarry/treefarm/farm/build/bridge/well/corridor/
  courier all do, out of the box. Rows are grouped by job kind with a
  per-kind count summary at the top. Run it on any computer with a
  wireless modem on the same `modem_channel` as your turtles (default
  6464 for everyone). If a `monitor` peripheral is attached it renders
  there; otherwise it uses the terminal. `timeout` is how many seconds of
  silence before a turtle is shown OFFLINE (default 30). Press `Q` to
  quit. Not installed by default --
  `pkg install monitor`.

## Wireless status

Every job-shaped program (`quarry`, `treefarm`, `farm`, `build`,
`bridge`, `well`, `corridor`, `courier`, and anything else built on
`lib/job.lua`) broadcasts a small status update -- job kind, position,
fuel, dug count, state (its own working state, e.g. `mining`, plus the
common `paused`/`refueling`/`dumping`/`done`/`stuck`), and any job-
specific detail (quarry's length/width/depth/skip) -- on state changes
and periodically while running, in addition to the human-readable
pause/complete/error messages it's always sent. `monitor` listens for
these and renders a live per-turtle dashboard, with no changes needed
for a new job kind to show up on it. Both just need
`flex_options.cfg`'s `modem_channel` to match (it does by default).

This uses `flex.sendData(table)`, not `flex.send(string)` -- see
Architecture below. Any program can call it to show up on `monitor`;
the only requirement is a `kind` field in the table so a listener can
tell message shapes apart (`monitor` looks for `kind == "job_status"`
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
  job.lua                -- shared supervised-job scaffold
                          (require("job")): fuel/inventory/pause
                          housekeeping and the wireless status
                          heartbeat, factored out of quarry.lua so
                          every job-shaped program gets it for free
programs/
  quarry.lua             -- see Programs, below
  treefarm.lua
  farm.lua
  build.lua
  bridge.lua
  well.lua
  corridor.lua
  courier.lua
  relay.lua
  tunnel.lua
  fasttunnel.lua
  dig-cli.lua
  monitor.lua
config/
  dig_options.default.cfg -- shipped defaults, copied to dig_options.cfg
  flex_options.default.cfg   on first install only (pkg won't clobber
                              a live, edited config)
```

## Development

`scripts/fetch-cc-tweaked-reference.sh` pulls a trimmed local copy of
[cc-tweaked/CC-Tweaked](https://github.com/cc-tweaked/CC-Tweaked) into
`reference/cc-tweaked/` (gitignored) -- the actual Lua ROM source,
Java API implementations, and hand-written docs, with the Gradle/mod-
loader/rendering/test noise stripped out. Useful any time you need to
check exactly how a CC:Tweaked API behaves instead of guessing.

## Roadmap

More automation is the long-term goal, added as new `manifest.json`
entries without any change to the installer/pkg architecture. Mining
(`quarry`, with optional vein-following), farming (`treefarm`, `farm`),
construction (`build`), utilities (`bridge`, `well`), and logistics
(`courier`, `relay`) are all built on a shared `lib/job.lua` scaffold,
so any future job-shaped program gets fuel/inventory/pause
housekeeping and a `monitor`-visible status heartbeat for free. Next
candidates: multi-turtle coordination for a single large quarry job
(claiming lanes over the wireless channel rather than each turtle
working in isolation), and a roaming explorer/mapper.
