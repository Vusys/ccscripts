#!/usr/bin/env bash
#
# fetch-cc-tweaked-reference.sh
#
# Clones cc-tweaked/CC-Tweaked (mc-1.21.x by default) and extracts just
# the parts worth keeping as a local API reference:
#
#   - the hand-written guide/event/data-shape docs (doc/)
#   - the actual bundled Lua ROM source: bios.lua, rom/apis/*.lua
#     (textutils, fs, http, turtle, colors, peripheral, rednet,
#     settings, term, vector, window, parallel, keys, gps, ...),
#     rom/programs/* (wget, pastebin, edit, shell, lua, ...), and
#     rom/modules/main/cc/* (cc.require, cc.strings, cc.audio.dfpwm)
#   - every Java source file that implements a Lua-facing method
#     (annotated @LuaFunction) plus the annotation/interface contracts
#     those methods are built on
#
# Everything else -- Gradle build files, Forge/Fabric platform glue,
# rendering code, tests, textures/models/sounds, CI config -- is left
# out. It's Minecraft-mod plumbing, not part of the Lua API surface a
# turtle program actually sees.
#
# Output lands in reference/cc-tweaked/ (gitignored), mirroring
# upstream's own relative paths, so anything in there can be
# cross-referenced directly against github.com/cc-tweaked/CC-Tweaked.
#
# Usage: scripts/fetch-cc-tweaked-reference.sh [branch]
#   branch  defaults to mc-1.21.x

set -euo pipefail

BRANCH="${1:-mc-1.21.x}"
REPO_URL="https://github.com/cc-tweaked/CC-Tweaked.git"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="$ROOT_DIR/reference/cc-tweaked"
CLONE_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$CLONE_DIR"
}
trap cleanup EXIT

echo "Cloning cc-tweaked/CC-Tweaked@$BRANCH (shallow)..."
git clone --depth 1 --branch "$BRANCH" --single-branch --quiet "$REPO_URL" "$CLONE_DIR"
COMMIT="$(git -C "$CLONE_DIR" rev-parse HEAD)"

echo "Extracting reference material into ${DEST#"$ROOT_DIR"/}..."
rm -rf "$DEST"
mkdir -p "$DEST"

# Copies $1 (a file or directory, relative to the clone root) into DEST,
# preserving its relative path. Silently skips paths that don't exist --
# upstream reorganizes occasionally, and a missing optional path
# shouldn't abort the whole run.
copy_path() {
  local rel="$1"
  local src="$CLONE_DIR/$rel"
  if [ ! -e "$src" ]; then
    echo "  (skip, not found upstream: $rel)"
    return 0
  fi
  local dest="$DEST/$rel"
  mkdir -p "$(dirname "$dest")"
  cp -r "$src" "$dest"
}

# -- Hand-written docs: guides, event reference, data-shape reference --
copy_path doc/index.md
copy_path doc/mod-page.md
copy_path doc/events
copy_path doc/guides
copy_path doc/reference
copy_path doc/stub

# -- The actual bundled Lua ROM source. Ground truth, not documentation
#    *about* ground truth.
copy_path projects/core/src/main/resources/data/computercraft/lua

# -- Lua API contracts: the @LuaFunction annotation itself, IArguments/
#    MethodResult/LuaException, IPeripheral/IDynamicPeripheral, and the
#    turtle/pocket/redstone/media/network upgrade interfaces.
copy_path projects/core-api/src/main/java/dan200/computercraft/api
copy_path projects/common-api/src/main/java/dan200/computercraft/api

# The client/ subtree under common-api is rendering (turtle upgrade
# models), not Lua-facing -- drop it even though the line above just
# copied it as part of the wider api/ tree.
rm -rf "$DEST/projects/common-api/src/main/java/dan200/computercraft/api/client"

# -- Every Java source file that actually implements a Lua-facing method
#    (annotated @LuaFunction): the base os/fs/http/term/redstone/
#    peripheral API layer, turtle/pocket/command-computer APIs, and
#    every peripheral's methods (disk drive, modem, monitor, printer,
#    speaker, generic block-capability methods). Found by grep rather
#    than a hardcoded path list, since that's what "the actual API
#    surface" means and it survives upstream reorganizing folders.
#    Excludes the example mod, the CI test mod, and the browser
#    emulator (web/) -- none of those are the real Minecraft-facing API.
echo "Finding @LuaFunction-annotated source files..."
while IFS= read -r -d '' file; do
  rel="${file#"$CLONE_DIR"/}"
  case "$rel" in
    projects/common/src/examples/*|projects/common/src/testMod/*|projects/web/*)
      continue
      ;;
  esac
  copy_path "$rel"
done < <(grep -rlZ "@LuaFunction" --include="*.java" "$CLONE_DIR/projects" 2>/dev/null)

FILE_COUNT="$(find "$DEST" -type f | wc -l | tr -d ' ')"
SIZE="$(du -sh "$DEST" | cut -f1)"

cat > "$DEST/README.md" <<EOF
# CC:Tweaked reference (generated, not upstream)

Pulled from [cc-tweaked/CC-Tweaked]($REPO_URL), branch \`$BRANCH\`,
commit \`$COMMIT\`, by \`scripts/fetch-cc-tweaked-reference.sh\`. This
directory is gitignored and disposable -- re-run that script any time
to refresh it; nothing here should be hand-edited.

Paths below mirror upstream exactly, so anything here can be opened
directly at \`github.com/cc-tweaked/CC-Tweaked/blob/$BRANCH/<path>\`.

- \`doc/\` -- hand-written guides, per-event docs, and reference pages
  for data shapes returned by the API (e.g. what \`turtle.inspect()\`'s
  return table actually looks like -- see \`doc/reference/block_details.md\`).
- \`projects/core/src/main/resources/data/computercraft/lua/\` -- the
  actual Lua source shipped inside every computer: \`bios.lua\` (the
  \`require()\`/\`package\` implementation, \`os.pullEvent\`, ...),
  \`rom/apis/*.lua\` (textutils, fs, http, turtle, colors, peripheral,
  rednet, settings, term, vector, window, parallel, keys, gps, ...),
  \`rom/programs/*\` (wget, pastebin, edit, shell, lua, ...), and
  \`rom/modules/main/cc/*\` (\`cc.require\`, \`cc.strings\`,
  \`cc.audio.dfpwm\`, ...). This is the single most reliable source for
  "does this API actually work the way I think it does" -- it's the
  real interpreter-level implementation, not a description of one.
- \`projects/core-api/\`, \`projects/common-api/\` -- the Lua API
  contracts: the \`@LuaFunction\` annotation itself, \`IArguments\`/
  \`MethodResult\`/\`LuaException\`, \`IPeripheral\`/\`IDynamicPeripheral\`,
  and the turtle/pocket/redstone/media/network upgrade interfaces.
- everywhere else -- every Java source file annotated \`@LuaFunction\`
  (the base os/fs/http/term/redstone/peripheral layer, turtle/pocket/
  command-computer APIs, and every peripheral's methods), found by
  grepping upstream rather than a hardcoded path list.

Left out on purpose: Gradle/build files, Forge/Fabric platform glue,
rendering code, tests, textures/models/sounds, CI config, and the
example/test mods -- none of that is part of the Lua API surface a
turtle program actually sees.
EOF

echo ""
echo "Done: $FILE_COUNT files, $SIZE, in ${DEST#"$ROOT_DIR"/}"
echo "(gitignored -- re-run this script any time to refresh it)"
