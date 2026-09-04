--!nonstrict
-- Printers service: owns the lpstat polling and every CUPS action. The bar
-- widget, panel and shortcut only read published state and send commands
-- through noctalia.state.set("printer.cmd", ...).
--
-- Nothing about the printing setup is configured here: destinations, states
-- and jobs all come from lpstat at runtime.

noctalia.setUpdateInterval(1000)

local tickCount = 0
local lastFaulty = {} -- printer name -> true, for fault-transition notifications

-- ── helpers ──────────────────────────────────────────────────────────────

local function log(msg)
  noctalia.log(`printer: {msg}`)
end

local function trim(s)
  return noctalia.string.trim(s or "")
end

local function clampInt(v, lo, hi, default)
  v = tonumber(v)
  if v == nil then
    return default
  end
  v = math.floor(v)
  if v < lo then
    return lo
  end
  if v > hi then
    return hi
  end
  return v
end

local function cfgBool(key, default)
  local v = noctalia.getConfig(key)
  if type(v) == "boolean" then
    return v
  end
  return default
end

local function cfgInt(key, lo, hi, default)
  return clampInt(noctalia.getConfig(key), lo, hi, default)
end

local function cfgString(key, default)
  local v = noctalia.getConfig(key)
  if type(v) == "string" and trim(v) ~= "" then
    return trim(v)
  end
  return default
end

-- Every process this plugin spawns goes through here: an argv table, never a
-- shell string, so a printer or job name can never be interpreted as a command.
local function run(argv, onDone, timeoutMs)
  local accepted = noctalia.runAsync(argv, onDone, timeoutMs or 10000)
  if not accepted then
    log("failed to start: " .. table.concat(argv, " "))
    if onDone ~= nil then
      onDone({ exitCode = -1, stdout = "", stderr = "failed to start process", timedOut = false })
    end
  end
end

local function splitLines(s)
  local lines = {}
  for line in tostring(s or ""):gmatch("[^\n]+") do
    table.insert(lines, (line:gsub("\r$", "")))
  end
  return lines
end

local function splitFields(s)
  local fields = {}
  for field in tostring(s or ""):gmatch("%S+") do
    table.insert(fields, field)
  end
  return fields
end

-- ── parsing ──────────────────────────────────────────────────────────────

-- "system default destination: HP_Smart_Tank" -> "HP_Smart_Tank"
-- "no system default destination"             -> ""
local function parseDefault(stdout)
  for _, line in ipairs(splitLines(stdout)) do
    local after = line:match("destination:%s*(.+)$")
    if after ~= nil then
      return trim(after)
    end
  end
  return ""
end

-- "printer NAME is idle.  enabled since ..."  -> idle,     enabled
-- "printer NAME now printing NAME-12.  ..."   -> printing, enabled
-- "printer NAME disabled since ..."           -> disabled, not enabled
local function parsePrinters(stdout)
  local printers = {}
  for _, line in ipairs(splitLines(stdout)) do
    local name, rest = line:match("^printer%s+(%S+)%s+(.*)$")
    if name ~= nil then
      local state = "idle"
      local enabled = true
      if rest:match("^disabled") ~= nil or rest:match("^is%s+stopped") ~= nil then
        state = "disabled"
        enabled = false
      else
        local isState = rest:match("^is%s+([%w_-]+)")
        if isState ~= nil then
          state = isState
        elseif rest:match("^now%s+printing") ~= nil then
          state = "printing"
        end
      end
      table.insert(printers, { name = name, state = state, enabled = enabled })
    end
  end
  return printers
end

-- `lpstat -e` lists every destination CUPS can print to, including driverless
-- ones discovered over DNS-SD that have no permanent queue yet and so never
-- appear in `lpstat -p`. One name per line.
local function parseDestinations(stdout)
  local names = {}
  for _, line in ipairs(splitLines(stdout)) do
    local name = trim(line)
    if name ~= "" and name:match("^%S+$") ~= nil then
      table.insert(names, name)
    end
  end
  return names
end

-- Adds the discovered-only destinations to the configured ones, so a driverless
-- printer is offered before CUPS has materialized a queue for it.
local function mergeDiscovered(printers, names)
  local known = {}
  for _, p in ipairs(printers) do
    known[p.name] = true
  end
  for _, name in ipairs(names) do
    if known[name] == nil then
      table.insert(printers, { name = name, state = "available", enabled = true, discovered = true })
    end
  end
  return printers
end

-- "HP_Smart_Tank-42   andrewdems   12288   Thu 04 Sep 2026 09:12:03 PM EEST"
local function parseJobs(stdout)
  local jobs = {}
  for _, line in ipairs(splitLines(stdout)) do
    local fields = splitFields(line)
    local id = fields[1]
    if id ~= nil and id ~= "" then
      local dash = id:match("^(.*)%-%d+$")
      local when = ""
      if #fields > 3 then
        when = table.concat(fields, " ", 4)
      end
      table.insert(jobs, {
        id = id,
        printer = dash or id,
        user = fields[2] or "",
        size = fields[3] or "",
        when = when,
      })
    end
  end
  return jobs
end

-- ── publishing ───────────────────────────────────────────────────────────

local function notifyFaults(printers)
  local nowFaulty = {}
  for _, p in ipairs(printers) do
    if not p.enabled then
      nowFaulty[p.name] = true
      if lastFaulty[p.name] == nil and cfgBool("notify_on_fault", true) then
        noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notifications.printer_stopped", { printer = p.name }))
      end
    end
  end
  lastFaulty = nowFaulty
end

local function publish(defaultPrinter, printers, jobs)
  local hasFault = false
  for _, p in ipairs(printers) do
    if not p.enabled then
      hasFault = true
    end
  end

  noctalia.state.set("printer.printers", printers)
  noctalia.state.set("printer.jobs", jobs)
  noctalia.state.set("printer.status", {
    defaultPrinter = defaultPrinter,
    printerCount = #printers,
    jobCount = #jobs,
    hasFault = hasFault,
  })
end

-- lpstat is called four times with plain argv rather than once behind a shell
-- pipeline, so the plugin never needs /bin/sh.
local function refresh()
  run({ "lpstat", "-d" }, function(defResult)
    local defaultPrinter = parseDefault(defResult.stdout)
    run({ "lpstat", "-p" }, function(printerResult)
      local printers = parsePrinters(printerResult.stdout)
      run({ "lpstat", "-e" }, function(destResult)
        printers = mergeDiscovered(printers, parseDestinations(destResult.stdout))
        run({ "lpstat", "-o" }, function(jobResult)
          local jobs = parseJobs(jobResult.stdout)
          notifyFaults(printers)
          publish(defaultPrinter, printers, jobs)
        end)
      end)
    end)
  end)
end

-- ── actions ──────────────────────────────────────────────────────────────

local function cancelJob(id)
  id = trim(id)
  if id == "" then
    return
  end
  run({ "cancel", id }, function()
    refresh()
  end)
end

local function cancelAll()
  run({ "cancel", "-a" }, function()
    refresh()
  end)
end

local function setDefault(name)
  name = trim(name)
  if name == "" then
    return
  end
  run({ "lpoptions", "-d", name }, function()
    refresh()
  end)
end

-- The clipboard text is written to a file under the plugin's data dir, handed
-- to lp as an argument and removed again, so no shell pipeline is involved and
-- the text never appears on a command line.
local function printClipboard()
  local status = noctalia.state.get("printer.status")
  local defaultPrinter = type(status) == "table" and status.defaultPrinter or ""
  if defaultPrinter == "" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notifications.no_default"))
    return
  end

  local text = noctalia.clipboardText()
  if text == nil or trim(text) == "" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notifications.clipboard_empty"))
    return
  end

  local dir, dirErr = noctalia.pluginDataDir()
  if dir == nil then
    noctalia.notifyError(noctalia.tr("title"), dirErr or "no data directory")
    return
  end

  local path = `{dir}/clipboard.txt`
  local ok, writeErr = noctalia.writeFile(path, text)
  if not ok then
    noctalia.notifyError(noctalia.tr("title"), writeErr or "could not stage the clipboard")
    return
  end

  run({ "lp", "-d", defaultPrinter, path }, function(result)
    noctalia.removeFile(path)
    if result.exitCode == 0 then
      noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.sent", { printer = defaultPrinter }))
      refresh()
    else
      noctalia.notifyError(noctalia.tr("title"), trim(result.stderr) ~= "" and trim(result.stderr) or "lp failed")
    end
  end)
end

local function openQueue()
  run({ "xdg-open", cfgString("cups_url", "http://localhost:631/jobs/") })
end

local function openPrinterSettings()
  local argv = splitFields(cfgString("settings_command", "system-config-printer"))
  if #argv == 0 then
    return
  end
  if not noctalia.commandExists(argv[1]) then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notifications.missing_command", { command = argv[1] }))
    return
  end
  run(argv)
end

-- ── command channel ──────────────────────────────────────────────────────

local function handleCommand(cmd)
  if type(cmd) ~= "table" then
    return
  end
  local op = cmd.op
  if op == "cancel" then
    cancelJob(cmd.id)
  elseif op == "cancel_all" then
    cancelAll()
  elseif op == "set_default" then
    setDefault(cmd.name)
  elseif op == "print_clipboard" then
    printClipboard()
  elseif op == "open_queue" then
    openQueue()
  elseif op == "open_settings" then
    openPrinterSettings()
  elseif op == "refresh" then
    refresh()
  end
end

noctalia.state.watch("printer.cmd", function(cmd)
  if cmd ~= nil then
    handleCommand(cmd)
    noctalia.state.set("printer.cmd", nil)
  end
end)

function onIpc(event, payload)
  if event == "refresh" then
    refresh()
  elseif event == "cancel" then
    cancelJob(payload)
  elseif event == "cancel-all" then
    cancelAll()
  elseif event == "print-clipboard" then
    printClipboard()
  elseif event == "status" then
    local status = noctalia.state.get("printer.status")
    if type(status) == "table" then
      noctalia.notify(
        noctalia.tr("title"),
        noctalia.trp("notifications.status", status.jobCount or 0, {
          printer = status.defaultPrinter ~= "" and status.defaultPrinter or noctalia.tr("panel.no_default"),
          count = status.jobCount or 0,
        })
      )
    end
  end
end

function onConfigChanged()
  refresh()
end

function onEnable()
  refresh()
end

function update()
  tickCount += 1
  if tickCount % cfgInt("poll_interval_seconds", 5, 300, 10) == 0 then
    refresh()
  end
end

noctalia.state.set("printer.printers", {})
noctalia.state.set("printer.jobs", {})
noctalia.state.set("printer.status", { defaultPrinter = "", printerCount = 0, jobCount = 0, hasFault = false })
refresh()
