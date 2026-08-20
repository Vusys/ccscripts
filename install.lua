-- install.lua
--
-- Bootstrap. Run this once via wget, then let pkg.lua take over:
--
--   wget https://raw.githubusercontent.com/vusys/ccscripts/main/install.lua install
--   install
--
-- Deliberately minimal -- this is the one file you run before there's
-- any reason to trust it, so it does the least possible amount of
-- work: fetch the manifest, grab whatever it flags as "first_run", and
-- get out of the way. Everything else (updates, installing more
-- programs, uninstalling) lives in pkg.lua from here on. Re-running
-- this later is safe -- it doesn't depend on any of its own state
-- existing already.

local REPO = "vusys/ccscripts"
local BRANCH = "main"

if not http then
  print("HTTP API is disabled.")
  print("Ask the server admin to enable it in CC:Tweaked's config")
  print("(and allow raw.githubusercontent.com if there's an allowlist).")
  return
end

local function rawURL(path)
  return "https://raw.githubusercontent.com/" .. REPO .. "/" .. BRANCH .. "/" .. path
end

local function fetch(path)
  local response, err = http.get(rawURL(path))
  if not response then
    return nil, err or "request failed"
  end
  local body = response.readAll()
  response.close()
  return body
end

local function downloadEntry(entry)
  if entry.install_mode == "if-missing" and fs.exists(entry.install_as) then
    return true
  end
  local body, err = fetch(entry.path)
  if not body then
    return false, err
  end
  if fs.exists(entry.install_as) then
    fs.delete(entry.install_as)
  end
  local file = fs.open(entry.install_as, "w")
  if not file then
    return false, "could not write " .. entry.install_as
  end
  file.write(body)
  file.close()
  return true
end

print("Fetching manifest from " .. REPO .. "@" .. BRANCH .. "...")
local manifestBody, manifestErr = fetch("manifest.json")
if not manifestBody then
  print("Install failed: " .. tostring(manifestErr))
  return
end

local ok, manifest = pcall(textutils.unserialiseJSON, manifestBody)
if not ok or not manifest or not manifest.entries then
  print("Install failed: manifest.json is not valid.")
  return
end

local configFile = fs.open("pkg_config.cfg", "w")
configFile.writeLine("repo=" .. REPO)
configFile.writeLine("branch=" .. BRANCH)
configFile.close()

local installed = {}
local installedAny = false
for _, entry in ipairs(manifest.entries) do
  if entry.first_run then
    print("Installing " .. entry.name .. "...")
    local entryOK, entryErr = downloadEntry(entry)
    if entryOK then
      installed[entry.name] = entry.version
      installedAny = true
    else
      print("  failed: " .. tostring(entryErr))
    end
  end
end

-- Seed pkg's bookkeeping so `pkg list`/`pkg update` know what's already
-- here, instead of pkg thinking nothing is installed until you run it.
local installedFile = fs.open("pkg_installed.json", "w")
installedFile.write(textutils.serialiseJSON(installed))
installedFile.close()

print("")
if installedAny then
  print("Installed. Run 'pkg list' to see everything available,")
  print("or 'pkg install <name>' to add more (e.g. tunnel, fasttunnel).")
else
  print("Nothing installed -- check the errors above.")
end
