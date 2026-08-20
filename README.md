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
wget https://raw.githubusercontent.com/vusys/ccscripts/main/install.lua install
install
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

## Architecture

- **flex.lua** -- utility API (`require("flex")`): inventory
  consolidation, wireless status broadcasting, colored terminal output
  (`#X` inline hex color codes), block/item classification helpers.
- **dig.lua** -- motion, mining, and crash-recovery API
  (`require("dig")`): coordinate-tracked movement, dig-through-obstacle
  retry with a stuck timeout, fuel management, and save/resume state so
  a program built on it survives a reboot.
- **quarry.lua / tunnel.lua / fasttunnel.lua** -- programs built on
  `dig` + `flex`.
- **pkg.lua / install.lua / manifest.json** -- the install/update
  mechanism described above.

Everything installs flat into one directory (turtles resolve
`require()` relative to the requiring program's own directory, so this
just works without any `package.path` setup).

## Roadmap

More automation is the long-term goal -- e.g. autonomous tree-farming
turtles -- added as new `manifest.json` entries without any change to
the installer/pkg architecture.
