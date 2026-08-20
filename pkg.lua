-- pkg.lua
--
-- Package manager for this repo. Installed by install.lua; from then on
-- it's how you get everything else (and updates to what you already
-- have).
--
-- Usage:
--   pkg list                     -- what's available, what's installed
--   pkg install <name> [name...] -- install a package + its dependencies
--   pkg update [name...]         -- update one, or everything installed
--   pkg remove <name>            -- uninstall (never deletes config data)
--   pkg refresh                  -- force re-fetch manifest.json

local CONFIG_FILE = "pkg_config.cfg"
local MANIFEST_CACHE = "pkg_manifest_cache.json"
local INSTALLED_FILE = "pkg_installed.json"

-- flex.lua should already be installed (it's a first_run package), but
-- don't hard-depend on it -- a broken/partial install shouldn't make
-- pkg itself unusable.
local haveFlex, flex = pcall(require, "flex")
if not haveFlex then
  flex = nil
end

local function say(message, color)
  if flex then
    flex.printColors(message, color)
  else
    print(message)
  end
end

-- ===========================================================================
-- Config, manifest cache, installed-package bookkeeping.
-- ===========================================================================

local function loadConfig()
  local repo, branch = "vusys/ccscripts", "main"
  local file = fs.open(CONFIG_FILE, "r")
  if file then
    local line = file.readLine()
    while line do
      local key, value = line:match("^(%w+)=(.*)$")
      if key == "repo" then
        repo = value
      elseif key == "branch" then
        branch = value
      end
      line = file.readLine()
    end
    file.close()
  end
  return repo, branch
end

local function readJSON(path)
  local file = fs.open(path, "r")
  if not file then
    return nil
  end
  local body = file.readAll()
  file.close()
  local ok, value = pcall(textutils.unserialiseJSON, body)
  if not ok then
    return nil
  end
  return value
end

local function writeJSON(path, value)
  local file = fs.open(path, "w")
  if not file then
    return false
  end
  file.write(textutils.serialiseJSON(value))
  file.close()
  return true
end

local function loadInstalled()
  return readJSON(INSTALLED_FILE) or {}
end

local function saveInstalled(t)
  writeJSON(INSTALLED_FILE, t)
end

-- ===========================================================================
-- Manifest fetch + package download.
-- ===========================================================================

local function fetchManifest(forceRefresh)
  if not forceRefresh then
    local cached = readJSON(MANIFEST_CACHE)
    if cached then
      return cached
    end
  end

  if not http then
    say("HTTP API is disabled -- ask the server admin to enable it", colors.red)
    say("(and allow raw.githubusercontent.com if there's an allowlist).", colors.red)
    return nil
  end

  local repo, branch = loadConfig()
  local url = "https://raw.githubusercontent.com/" .. repo .. "/" .. branch .. "/manifest.json"
  local response, err = http.get(url)
  if not response then
    say("Could not fetch manifest.json: " .. tostring(err), colors.red)
    return nil
  end
  local body = response.readAll()
  response.close()

  local ok, manifest = pcall(textutils.unserialiseJSON, body)
  if not ok or not manifest or not manifest.entries then
    say("manifest.json is not valid.", colors.red)
    return nil
  end

  writeJSON(MANIFEST_CACHE, manifest)
  return manifest
end

local function findEntry(manifest, name)
  for _, entry in ipairs(manifest.entries) do
    if entry.name == name then
      return entry
    end
  end
  return nil
end

-- Dependency-first, deduplicated resolution of `names` against `manifest`.
local function resolveDeps(names, manifest)
  local resolved, seen = {}, {}

  local function visit(name)
    if seen[name] then
      return
    end
    seen[name] = true
    local entry = findEntry(manifest, name)
    if not entry then
      say("Unknown package: " .. name, colors.red)
      return
    end
    for _, dep in ipairs(entry.depends or {}) do
      visit(dep)
    end
    resolved[#resolved + 1] = entry
  end

  for _, name in ipairs(names) do
    visit(name)
  end
  return resolved
end

local function compareVersions(a, b)
  local function parts(v)
    local t = {}
    for n in tostring(v):gmatch("%d+") do
      t[#t + 1] = tonumber(n)
    end
    return t
  end
  local pa, pb = parts(a), parts(b)
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then
      return (x < y) and -1 or 1
    end
  end
  return 0
end

local function downloadEntry(entry, repo, branch)
  if entry.install_mode == "if-missing" and fs.exists(entry.install_as) then
    return true
  end
  if not http then
    return false, "HTTP API is disabled"
  end

  local url = "https://raw.githubusercontent.com/" .. repo .. "/" .. branch .. "/" .. entry.path
  local response, err = http.get(url)
  if not response then
    return false, err or "request failed"
  end
  local body = response.readAll()
  response.close()

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

-- ===========================================================================
-- Subcommands.
-- ===========================================================================

local function cmdList()
  local manifest = fetchManifest(false)
  if not manifest then
    return
  end
  local installed = loadInstalled()

  for _, entry in ipairs(manifest.entries) do
    local have = installed[entry.name]
    local status
    if not have then
      status = "#8not installed"
    elseif compareVersions(have, entry.version) < 0 then
      status = "#F" .. have .. " #8-> #F" .. entry.version .. " #8available"
    else
      status = "#F" .. have .. " #8(up to date)"
    end
    say("#F" .. entry.name .. " #8[" .. entry.category .. "] " .. status .. " #8-- " .. entry.description)
  end
end

local function cmdInstall(names)
  if #names == 0 then
    say("Usage: pkg install <name> [name2 ...]", colors.lightBlue)
    return
  end
  local manifest = fetchManifest(false)
  if not manifest then
    return
  end
  local repo, branch = loadConfig()
  local installed = loadInstalled()

  for _, entry in ipairs(resolveDeps(names, manifest)) do
    say("Installing " .. entry.name .. "...")
    local ok, err = downloadEntry(entry, repo, branch)
    if ok then
      installed[entry.name] = entry.version
      saveInstalled(installed)
    else
      say("  failed: " .. tostring(err), colors.red)
    end
  end
end

local function cmdUpdate(names)
  local manifest = fetchManifest(true)
  if not manifest then
    return
  end
  local repo, branch = loadConfig()
  local installed = loadInstalled()

  local targets = names
  if #targets == 0 then
    for name in pairs(installed) do
      targets[#targets + 1] = name
    end
  end

  local didAny = false
  for _, entry in ipairs(resolveDeps(targets, manifest)) do
    local have = installed[entry.name]
    if not have or compareVersions(have, entry.version) < 0 then
      say("Updating " .. entry.name .. " -> " .. entry.version .. "...")
      local ok, err = downloadEntry(entry, repo, branch)
      if ok then
        installed[entry.name] = entry.version
        saveInstalled(installed)
        didAny = true
      else
        say("  failed: " .. tostring(err), colors.red)
      end
    end
  end

  if not didAny then
    say("Everything is up to date.", colors.lime)
  end
end

local function cmdRemove(names)
  if #names == 0 then
    say("Usage: pkg remove <name>", colors.lightBlue)
    return
  end
  local manifest = fetchManifest(false)
  local installed = loadInstalled()

  for _, name in ipairs(names) do
    local entry = manifest and findEntry(manifest, name)
    if entry and entry.category == "config" then
      say("Leaving " .. entry.install_as .. " in place (it's your config) -- just forgetting it.", colors.orange)
    elseif entry and fs.exists(entry.install_as) then
      fs.delete(entry.install_as)
    end
    installed[name] = nil
  end
  saveInstalled(installed)

  if manifest then
    for _, entry in ipairs(manifest.entries) do
      if installed[entry.name] then
        for _, dep in ipairs(entry.depends or {}) do
          for _, removed in ipairs(names) do
            if dep == removed then
              say("Warning: " .. entry.name .. " still depends on " .. removed, colors.orange)
            end
          end
        end
      end
    end
  end
end

local function cmdRefresh()
  if fetchManifest(true) then
    say("manifest.json refreshed.", colors.lime)
  end
end

-- ===========================================================================
-- Dispatch.
-- ===========================================================================

local args = { ... }
local sub = args[1]
local rest = {}
for i = 2, #args do
  rest[#rest + 1] = args[i]
end

if sub == "list" then
  cmdList()
elseif sub == "install" then
  cmdInstall(rest)
elseif sub == "update" then
  cmdUpdate(rest)
elseif sub == "remove" then
  cmdRemove(rest)
elseif sub == "refresh" then
  cmdRefresh()
else
  say("Usage: pkg <list|install <name>|update [name]|remove <name>|refresh>", colors.lightBlue)
end
