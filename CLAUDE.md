# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ComputerCraft/CC:Tweaked turtle automation scripts in Lua, distributed via GitHub. There is no build system or test framework in the traditional sense (these are Minecraft-API-dependent scripts that only really run on a turtle/CraftOS-PC), but there is a real install/update mechanism: `install.lua` (a one-shot `wget` bootstrap) and `pkg.lua` (a small package manager), driven by `manifest.json`. See README.md for the user-facing install/usage instructions.

All original code — `lib/dig.lua`, `lib/flex.lua`, `programs/quarry.lua`, `programs/dig-cli.lua`, `pkg.lua`, `install.lua` are from-scratch implementations written for this repo (no third-party code is vendored here).

## Repo layout vs. on-device layout

The repo is organized into folders (`lib/`, `programs/`, `config/`), but **every install is flat** — `manifest.json` maps each entry's repo-relative `path` to a flat on-device `install_as` filename (e.g. `lib/dig.lua` → `dig.lua`). This matters because CC:Tweaked's `require()` resolves relative to the *requiring program's own directory*; keeping the on-device install flat means `require("dig")`/`require("flex")` just work with zero `package.path` setup, regardless of how the repo itself is organized. **When adding a new file: put it wherever makes sense in the repo tree, but give it a flat `install_as` in `manifest.json` and never introduce a subdirectory on the on-device side.**

## Module Architecture

```
programs/quarry.lua, tunnel.lua, fasttunnel.lua, dig-cli.lua  →  lib/dig.lua  →  lib/flex.lua
(programs)                                                        (motion API)   (utility API)
```

Modules are loaded with `require()`, not the deprecated `os.loadAPI()` — `local dig = require("dig")`, `local flex = require("flex")`. Each returns a table; there is no global-namespace state.

- **lib/flex.lua** — Utility API. Inventory consolidation (`condense`), wireless modem broadcasting (`send`), block/item detection (`getBlock`/`isBlock`/`isItem`/`isFluid`), colored terminal output (`printColors`, inline `#X` hex color codes, degrades to plain text on non-color terminals), config I/O for `flex_options.cfg`.
- **lib/dig.lua** — Motion, mining, and crash-recovery API. Coordinate tracking (X=right, Y=up, Z=forward, R=rotation in degrees), getter/setter pattern for all state (e.g. `dig.getx()`/`dig.setx()` — internal state is closed over as upvalues, never accessed directly), navigation (`goto`, `gotox`/`gotoy`/`gotoz`/`gotor`), retry-and-dig-through movement with a 20-second stuck timeout (applies uniformly to `fwd`/`up`/`down`), placement (fluid-aware retry, same timeout), fuel management, and save/resume state. Depends on flex.lua.
- **programs/dig-cli.lua** — `save`/`load`/`clear`/`edit`/`colors` subcommands for a person to run interactively. This used to be baked into `dig.lua` itself as a top-level CLI dispatch; it's a separate program now so `dig.lua` can be a pure `require()`-able module with no side effects beyond returning its API table.
- **programs/quarry.lua** — `quarry <length> [width] [depth] [skip <N>] [dump] [nolava] [nether]`. Zigzag/boustrophedon strip-mining, layer by layer. Sweep direction is derived purely from layer/column position parity (not any persisted flag), which is what makes a mid-layer reboot resumable without extra bookkeeping. Pause via redstone signal on `rs.getInput("top")`, automatic inventory dumps, wireless progress reporting.
- **programs/tunnel.lua** / **programs/fasttunnel.lua** — simpler rectangular/3x3 tunnel diggers, resumed purely from `dig`'s position getters.
- **pkg.lua** / **install.lua** — the install/update mechanism, both at repo root (root keeps the `wget run` URL short, and `install.lua` in particular needs to be trivially discoverable). `install.lua` is a deliberately minimal one-shot bootstrap (run via `wget run`); `pkg.lua` does everything after that (list/install/update/remove/refresh), reading `manifest.json` from the repo over `http.get` + `textutils.unserialiseJSON`.

## Configuration Files

- **dig_options.cfg** (on-device, flat) — Block classification lists: `[outputblocks]` (chests), `[blacklist]` (protected blocks — only enforced when `dig.doBlacklist(true)` is set), `[buildingblocks]` (scaffolding), `[dumplist]` (discard), `[fluids]`. Seeded from `config/dig_options.default.cfg` on first install; pkg never overwrites an existing one.
- **flex_options.cfg** (on-device, flat) — `modem_channel` (default 6464) and `name_color`. Seeded from `config/flex_options.default.cfg` the same way.
- Both live files are gitignored — only the `*.default.cfg` shipped defaults are tracked. Runtime-generated files (`dig_save.cfg`, `dig_fuel.cfg`, `log.txt`, `startup.lua`, `pkg_installed.json`, `pkg_manifest_cache.json`, `pkg_config.cfg`) are gitignored too — they're produced on-device, never authored by hand.

## Key Patterns

- **State persistence**: `dig.lua` saves a 17-value array to `dig_save.cfg` (16 original fields, plus an additive 17th "extra" string field via `getExtra()`/`setExtra()` that `dig.lua` itself ignores — it exists so a calling program can persist one small piece of its own state across a reboot instead of overloading an unrelated field) and writes a `startup.lua` to auto-resume after reboot. The 17-value order is a de facto public contract (`goto()` accepts this array directly) — any change must be additive, never reordering/removing existing fields.
- **API loading**: `require("dig")` / `require("flex")`, not `os.loadAPI()`. Modules are pure — no top-level CLI argument handling or other side effects beyond returning their API table.
- **Getter/setter pattern**: all `dig.lua` state is closed over as `local` upvalues, exposed only through getter/setter function pairs (e.g. `dig.getx()`/`dig.setx()`).
- **Stuck detection**: movement functions (`fwd`/`up`/`down`) retry-and-dig for 20 real-world seconds before reporting failure, uniformly. Unbreakable blocks are logged to an in-memory bedrock list and reported via `flex.send`.
- **Fuel awareness**: `dig.refuel()` blocks until enough fuel is available (intentionally — it has nowhere else to go); calling programs like `quarry.lua` are responsible for noticing low fuel and returning to base themselves (`dig.lua` has no "return to surface" logic of its own).
- **Lua 5.1 target**: CC:Tweaked runs Lua 5.1 semantics. No `math.log(x, base)` (2-arg form is 5.2+), no bitwise operators, no `goto`/labels as statements. Verify anything version-sensitive against a real `lua5.1` interpreter, not just a syntax check — `luac5.1 -p` catches parse errors but not stdlib differences like the missing 2-arg `math.log`.
- **Testing without a turtle**: there's no CC:Tweaked emulator in this environment, so changes are verified with a mocked-API smoke test (stub `turtle`/`fs`/`term`/`http`/etc. globals, `require()` the real files, exercise them, including a simulated mid-job reboot for `dig.lua`/`quarry.lua`'s save/resume path). Write throwaway test harnesses in a scratch directory, not into the repo.
