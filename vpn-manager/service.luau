--!nonstrict
-- VPN Manager service: owns NetworkManager polling, VPN connect/disconnect/
-- import/delete, trusted-network tracking and the auto-connect/disconnect
-- decision. Every other entry (bar, panel, shortcut) only reads published
-- state and sends commands through noctalia.state.set("vpn.cmd", ...).

noctalia.setUpdateInterval(1000)

-- ── constants ─────────────────────────────────────────────────────────────

local SERVICE_TYPE_LABELS = {
  ["org.freedesktop.NetworkManager.openvpn"] = "OpenVPN",
  ["org.freedesktop.NetworkManager.openconnect"] = "Cisco AnyConnect (OpenConnect)",
  ["org.freedesktop.NetworkManager.vpnc"] = "Cisco VPN (vpnc)",
  ["org.freedesktop.NetworkManager.l2tp"] = "L2TP/IPsec",
  ["org.freedesktop.NetworkManager.pptp"] = "PPTP",
  ["org.freedesktop.NetworkManager.strongswan"] = "IPsec/IKEv2 (strongSwan)",
  ["org.freedesktop.NetworkManager.sstp"] = "SSTP",
  ["org.freedesktop.NetworkManager.fortisslvpn"] = "Fortinet SSL VPN",
  ["org.freedesktop.NetworkManager.ssh"] = "SSH",
}

-- service-type suffix -> Arch package name, for "install this to add support" hints.
local PACKAGE_HINTS = {
  openvpn = "networkmanager-openvpn",
  openconnect = "networkmanager-openconnect",
  vpnc = "networkmanager-vpnc",
  l2tp = "networkmanager-l2tp",
  pptp = "networkmanager-pptp",
  strongswan = "networkmanager-strongswan",
  sstp = "networkmanager-sstp",
  fortisslvpn = "networkmanager-fortisslvpn",
}

local VPN_PLUGIN_DIRS = { "/usr/lib64/NetworkManager/VPN", "/usr/lib/NetworkManager/VPN" }

-- Fortinet SAML runs openfortivpn directly: neither NetworkManager-fortisslvpn
-- nor openconnect's fortinet protocol can do SAML sign-in. Profiles are this
-- plugin's own data, and their row ids carry this prefix so they can never be
-- mistaken for (or validated as) a NetworkManager UUID.
local FORTI_PREFIX = "forti-"
local FORTI_LABEL = "Fortinet SSL VPN (SAML)"
local OPENFORTIVPN_PATHS = { "/usr/bin/openfortivpn", "/usr/sbin/openfortivpn", "/usr/local/bin/openfortivpn", "/usr/local/sbin/openfortivpn" }
local STREAM_TAG = "vpn-manager:"

-- ── small helpers ────────────────────────────────────────────────────────

local function log(msg)
  noctalia.log(`vpn-manager: {msg}`)
end

local function trim(s)
  return noctalia.string.trim(s or "")
end

local function firstLine(s)
  s = trim(s)
  local nl = s:find("\n")
  if nl ~= nil then
    return s:sub(1, nl - 1)
  end
  return s
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
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

local function run(argv, onDone, timeoutMs)
  local accepted = noctalia.runAsync(argv, onDone, timeoutMs or 15000)
  if not accepted then
    log("failed to start: " .. table.concat(argv, " "))
    if onDone ~= nil then
      onDone({ exitCode = -1, stdout = "", stderr = "failed to start process", timedOut = false })
    end
  end
end

-- Sequentially maps items through an async fn(item, done), then calls onDone(results).
local function mapAsync(items, fn, onDone)
  local results = {}
  local i = 0
  local function step()
    i += 1
    if i > #items then
      onDone(results)
      return
    end
    fn(items[i], function(result)
      results[i] = result
      step()
    end)
  end
  step()
end

local function friendlyProtocol(ctype, serviceType)
  if ctype == "wireguard" then
    return "WireGuard"
  end
  if type(serviceType) == "string" and SERVICE_TYPE_LABELS[serviceType] ~= nil then
    return SERVICE_TYPE_LABELS[serviceType]
  end
  if type(serviceType) == "string" and serviceType ~= "" then
    return (serviceType:gsub("^org%.freedesktop%.NetworkManager%.", ""))
  end
  return "VPN"
end

local function packageHintFor(typeArg)
  local hint = PACKAGE_HINTS[typeArg]
  if hint ~= nil then
    return " " .. noctalia.tr("notifications.install_hint", { package = hint })
  end
  return ""
end

local function detectImportType(content)
  if type(content) ~= "string" then
    return nil
  end
  if content:match("%[Interface%]") and content:match("%[Peer%]") then
    return "wireguard"
  end
  if content:match("^%s*client") or content:match("\nremote%s+%S") or content:match("<ca>") or content:match("%-%-%-%-%-BEGIN CERTIFICATE") then
    return "openvpn"
  end
  -- openfortivpn config: `host = ...` (checked after OpenVPN/WireGuard, which
  -- never use that key).
  if content:match("^%s*host%s*=") or content:match("\n%s*host%s*=") then
    return "openfortivpn"
  end
  return nil
end

-- ── persistent data (trusted networks, default VPN, auto-started tracking) ──

local data = {
  trustedNetworks = {},
  defaultVpnUuid = "",
  autoStartedUuid = "",
  fortiProfiles = {}, -- { id, name, host, port, realm, trustedCert }
}

local function dataPath()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/data.json"
end

local function saveData()
  local path = dataPath()
  if path == nil then
    return
  end
  local encoded = noctalia.json.encode(data)
  if encoded ~= nil then
    noctalia.writeFile(path, encoded)
  end
end

local function loadData()
  local path = dataPath()
  if path == nil then
    return
  end
  local raw = noctalia.readFile(path)
  if raw == nil then
    return
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    return
  end
  if type(decoded.trustedNetworks) == "table" then
    data.trustedNetworks = decoded.trustedNetworks
  end
  if type(decoded.defaultVpnUuid) == "string" then
    data.defaultVpnUuid = decoded.defaultVpnUuid
  end
  if type(decoded.autoStartedUuid) == "string" then
    data.autoStartedUuid = decoded.autoStartedUuid
  end
  if type(decoded.fortiProfiles) == "table" then
    data.fortiProfiles = decoded.fortiProfiles
  end
end

local function isTrusted(name)
  for _, n in ipairs(data.trustedNetworks) do
    if n == name then
      return true
    end
  end
  return false
end

-- ── installed VPN plugin detection ──────────────────────────────────────

-- pkexec wants an absolute program path, so resolve it rather than relying on
-- PATH inside the privileged environment.
local function fortiBinary()
  for _, path in ipairs(OPENFORTIVPN_PATHS) do
    if noctalia.fileExists(path) then
      return path
    end
  end
  return nil
end

local function publishAvailableProtocols()
  local available = { wireguard = true } -- always native/built in
  available.openfortivpn = fortiBinary() ~= nil and noctalia.commandExists("pkexec")
  for _, dir in ipairs(VPN_PLUGIN_DIRS) do
    local entries = noctalia.listDir(dir)
    if entries ~= nil then
      for _, entry in ipairs(entries) do
        local key = entry:match("^nm%-(.+)%-service%.name$")
        if key ~= nil then
          available[key] = true
        end
      end
    end
  end
  noctalia.state.set("vpn.availableProtocols", available)
end

-- ── live state (last refresh results) ───────────────────────────────────

local lastVpnRows = {}
local refreshInFlight = false
local opInFlight = {} -- uuid -> true while a connect/disconnect/delete is running
local untrustedStreak = 0
local trustedStreak = 0
-- Auto-connect re-evaluates on every poll, so a VPN that cannot authenticate
-- would be retried every few seconds and notify each time. A failed automatic
-- attempt backs off until this timestamp.
local autoConnectBlockedUntil = 0
local AUTO_RETRY_BACKOFF_SECONDS = 300
local tickCount = 0
-- profile id -> { phase = "auth"|"browser"|"connecting"|"up", pid, url,
-- stopping, certDigest, lastError, orphan }. phase "auth" is the polkit
-- prompt; an orphan is a tunnel found running after a plugin reload, with no
-- output stream attached.
local fortiRuns = {}

-- NetworkManager UUIDs are hex and dashes. Validated before a UUID is ever
-- interpolated into a terminal command, the only place this plugin builds a
-- shell string rather than an argv list.
local function isUuid(value)
  return type(value) == "string" and value:match("^[0-9a-fA-F%-]+$") ~= nil and #value >= 8
end

-- NetworkManager asks a secret agent for a password whose flags mark it
-- agent-owned. A bare shell has no agent, so activation fails before OpenVPN
-- even starts; nmcli --ask asks on the terminal instead.
local function needsSecrets(stderr)
  local text = tostring(stderr or ""):lower()
  return text:find("no valid secrets") ~= nil
    or text:find("secrets were required") ~= nil
    or text:find("no agents were available") ~= nil
end

local function promptForSecrets(uuid)
  if not isUuid(uuid) then
    return false
  end
  return noctalia.runInTerminal(`nmcli --ask connection up uuid {uuid}`)
end

local function nameForUuid(uuid)
  for _, row in ipairs(lastVpnRows) do
    if row.uuid == uuid then
      return row.name
    end
  end
  return nil
end

-- Returns the profile for a "forti-<id>" row id, or nil for anything else.
local function fortiProfileFor(uuid)
  if type(uuid) ~= "string" or uuid:sub(1, #FORTI_PREFIX) ~= FORTI_PREFIX then
    return nil
  end
  local id = uuid:sub(#FORTI_PREFIX + 1)
  for i, profile in ipairs(data.fortiProfiles) do
    if profile.id == id then
      return profile, i
    end
  end
  return nil
end

local function isFortiId(uuid)
  return type(uuid) == "string" and uuid:sub(1, #FORTI_PREFIX) == FORTI_PREFIX
end

local function publishConnections()
  local rows = {}
  local activeNames = {}
  for _, row in ipairs(lastVpnRows) do
    table.insert(rows, {
      uuid = row.uuid,
      name = row.name,
      protocol = row.protocol,
      ctype = row.ctype,
      active = row.active,
      isDefault = row.uuid == data.defaultVpnUuid,
      busy = opInFlight[row.uuid] == true,
    })
    if row.active then
      table.insert(activeNames, row.name)
    end
  end
  for _, profile in ipairs(data.fortiProfiles) do
    local st = fortiRuns[profile.id]
    local up = st ~= nil and st.phase == "up"
    table.insert(rows, {
      uuid = FORTI_PREFIX .. profile.id,
      name = profile.name,
      protocol = FORTI_LABEL,
      ctype = "forti-saml",
      active = up,
      -- Started but not up yet: polkit prompt, browser sign-in or tunnel setup.
      pending = st ~= nil and not up,
      phase = st ~= nil and st.phase or "",
      loginUrl = st ~= nil and st.phase == "browser" and st.url or "",
      isDefault = false,
      busy = st ~= nil and st.stopping == true,
    })
    if up then
      table.insert(activeNames, profile.name)
    end
  end
  table.sort(rows, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  noctalia.state.set("vpn.connections", rows)
  noctalia.state.set("vpn.status", {
    anyActive = #activeNames > 0,
    activeNames = activeNames,
  })
end

local function publishTrust()
  noctalia.state.set("vpn.trustedNetworks", data.trustedNetworks)
  noctalia.state.set("vpn.defaultVpnUuid", data.defaultVpnUuid)
end

-- ── connect / disconnect / delete / import ──────────────────────────────

local function refreshAll()
  -- fwd declared below; assigned once defined
end

local function connectUuid(uuid, isAuto)
  if uuid == nil or uuid == "" or opInFlight[uuid] then
    return
  end
  opInFlight[uuid] = true
  publishConnections()
  run({ "nmcli", "connection", "up", "uuid", uuid }, function(result)
    opInFlight[uuid] = nil
    if result.exitCode == 0 then
      autoConnectBlockedUntil = 0
      if isAuto then
        data.autoStartedUuid = uuid
        saveData()
        if cfgBool("notify_on_autoswitch", true) then
          noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.connected_untrusted", { name = nameForUuid(uuid) or noctalia.tr("title") }))
        end
      end
    else
      if isAuto then
        autoConnectBlockedUntil = os.time() + AUTO_RETRY_BACKOFF_SECONDS
      end
      local name = nameForUuid(uuid) or noctalia.tr("title")
      if needsSecrets(result.stderr) then
        -- Auto-connect must not seize a terminal behind the user's back, so it
        -- only says what is wrong; a deliberate connect gets the prompt.
        if isAuto or not promptForSecrets(uuid) then
          noctalia.notifyError(
            noctalia.tr("notifications.connect_failed"),
            noctalia.tr("notifications.needs_secrets", { name = name })
          )
        else
          noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.asking_secrets", { name = name }))
        end
      else
        noctalia.notifyError(
          noctalia.tr(isAuto and "notifications.auto_connect_failed" or "notifications.connect_failed"),
          firstLine(result.stderr)
        )
      end
    end
    refreshAll()
  end, 25000)
end

local function disconnectUuid(uuid, isAuto)
  if uuid == nil or uuid == "" or opInFlight[uuid] then
    return
  end
  opInFlight[uuid] = true
  publishConnections()
  run({ "nmcli", "connection", "down", "uuid", uuid }, function(result)
    opInFlight[uuid] = nil
    if uuid == data.autoStartedUuid then
      data.autoStartedUuid = ""
      saveData()
    end
    if result.exitCode == 0 then
      if isAuto and cfgBool("notify_on_autoswitch", true) then
        noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.disconnected_trusted"))
      end
    else
      noctalia.notifyError(noctalia.tr(isAuto and "notifications.auto_disconnect_failed" or "notifications.disconnect_failed"), firstLine(result.stderr))
    end
    refreshAll()
  end, 25000)
end

local function deleteUuid(uuid)
  if uuid == nil or uuid == "" then
    return
  end
  run({ "nmcli", "connection", "delete", "uuid", uuid }, function(result)
    if result.exitCode ~= 0 then
      noctalia.notifyError(noctalia.tr("notifications.delete_failed"), firstLine(result.stderr))
    else
      if data.defaultVpnUuid == uuid then
        data.defaultVpnUuid = ""
      end
      if data.autoStartedUuid == uuid then
        data.autoStartedUuid = ""
      end
      saveData()
    end
    refreshAll()
  end)
end

-- ── Fortinet SAML (openfortivpn, outside NetworkManager) ─────────────────
--
-- openfortivpn --saml-login listens on 127.0.0.1:8020 and logs
-- "Authenticate at '<url>'"; the gateway redirects the browser back to that
-- listener after IdP sign-in. It needs root (pppd), so it runs under pkexec.
-- Profile fields end up in a shell string (runStream only takes one), so
-- they are validated here, again at connect time, and shell-quoted.

local function validHost(host)
  return type(host) == "string" and #host > 0 and #host <= 253 and host:match("^[%w][%w%.%-]*$") ~= nil
end

local function validPort(port)
  port = tonumber(port)
  return port ~= nil and port == math.floor(port) and port >= 1 and port <= 65535
end

local function validRealm(realm)
  return realm == "" or (type(realm) == "string" and #realm <= 64 and realm:match("^[%w%._%-]+$") ~= nil)
end

local function validCert(cert)
  return cert == "" or (type(cert) == "string" and cert:match("^%x+$") ~= nil and #cert == 64)
end

local function validProfile(p)
  return type(p) == "table" and validHost(p.host) and validPort(p.port) and validRealm(p.realm or "") and validCert(p.trustedCert or "")
end

-- Accepts "vpn.example.com", "vpn.example.com:10443" or a pasted
-- "https://vpn.example.com:10443/remote/login" and returns host, port.
local function parseGateway(text)
  text = trim(text):gsub("^%a+://", "")
  text = text:gsub("[/?#].*$", "")
  local host, port = text:match("^([^:]+):(%d+)$")
  if host == nil then
    host, port = text, "443"
  end
  return host:lower(), tonumber(port)
end

-- Validates { name, gateway, realm, trustedCert } and stores it. A profile for
-- the same gateway and realm is updated in place rather than duplicated, so
-- re-importing after the gateway's certificate is renewed just swaps the pin.
-- Returns the stored profile, or nil and a user-facing reason.
local function saveFortiProfile(fields)
  local name = trim(fields.name)
  local host, port = parseGateway(fields.gateway or "")
  local realm = trim(fields.realm)
  local cert = trim(fields.trustedCert):lower():gsub(":", "")
  if not validHost(host) or not validPort(port) then
    return nil, noctalia.tr("notifications.forti_bad_gateway")
  elseif not validRealm(realm) then
    return nil, noctalia.tr("notifications.forti_bad_realm")
  elseif not validCert(cert) then
    return nil, noctalia.tr("notifications.forti_bad_cert")
  end
  if name == "" then
    name = host
  end
  local profile = nil
  for _, existing in ipairs(data.fortiProfiles) do
    if existing.host == host and existing.port == port and (existing.realm or "") == realm then
      profile = existing
    end
  end
  if profile == nil then
    profile = { id = tostring(math.floor(noctalia.nowMs())) }
    table.insert(data.fortiProfiles, profile)
  end
  profile.name = name:sub(1, 64)
  profile.host = host
  profile.port = port
  profile.realm = realm
  profile.trustedCert = cert
  saveData()
  publishConnections()
  return profile
end

local function addFortiProfile(cmd)
  local profile, problem = saveFortiProfile(cmd)
  if profile == nil then
    noctalia.notifyError(noctalia.tr("notifications.forti_add_failed"), problem)
    return
  end
  noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.forti_added", { name = profile.name }))
end

-- Reads the connection keys of an openfortivpn config (`key = value`, `#`
-- comments). Credentials (username, password, otp, cookie, user-key) are
-- deliberately ignored: SAML does not use them and this plugin stores no
-- secrets. The first valid trusted-cert wins, since a profile pins one.
local function parseOpenfortivpnConfig(content)
  local fields = { host = nil, port = nil, realm = "", trustedCert = "" }
  for line in content:gmatch("[^\r\n]+") do
    local key, value = line:match("^%s*([%w%-]+)%s*=%s*(.-)%s*$")
    if key ~= nil and not line:match("^%s*#") then
      key = key:lower()
      if key == "host" then
        fields.host = value
      elseif key == "port" then
        fields.port = value
      elseif key == "realm" then
        fields.realm = value
      elseif key == "trusted-cert" and fields.trustedCert == "" and validCert(value:lower()) then
        fields.trustedCert = value
      end
    end
  end
  if fields.host == nil or fields.host == "" then
    return nil
  end
  return fields
end

-- Name comes from the file ("UCY VPN.conf" -> "UCY VPN"); a pasted config's
-- temp file carries no useful name, so that falls back to the gateway.
local function importOpenfortivpnConfig(path, content, isTemp)
  local fields = type(content) == "string" and parseOpenfortivpnConfig(content) or nil
  if fields == nil then
    return nil, noctalia.tr("notifications.forti_no_host")
  end
  local base = (path:match("([^/]+)$") or ""):gsub("%.[^.]*$", "")
  local gateway = fields.host
  if fields.port ~= nil and fields.port ~= "" then
    gateway = `{fields.host}:{fields.port}`
  end
  return saveFortiProfile({
    name = if isTemp or base == "config" then "" else base,
    gateway = gateway,
    realm = fields.realm,
    trustedCert = fields.trustedCert,
  })
end

local function finishFortiRun(profile, code)
  local st = fortiRuns[profile.id]
  fortiRuns[profile.id] = nil
  publishConnections()
  if st == nil then
    return
  end
  log(`openfortivpn for {profile.name} exited code={code} phase={st.phase}`)
  if st.stopping then
    return
  end
  local title = noctalia.tr(st.phase == "up" and "notifications.forti_dropped" or "notifications.connect_failed")
  if code == 126 or code == 127 then
    -- pkexec: the polkit dialog was dismissed or authorization was refused.
    noctalia.notifyError(title, noctalia.tr("notifications.forti_not_authorized"))
  elseif st.certDigest ~= nil then
    noctalia.notifyError(title, noctalia.tr("notifications.forti_untrusted_cert", { digest = st.certDigest }))
  elseif st.phase == "browser" then
    noctalia.notifyError(title, noctalia.tr("notifications.forti_login_timeout"))
  else
    noctalia.notifyError(title, st.lastError or noctalia.tr("notifications.forti_exited", { code = tostring(code) }))
  end
end

local function onFortiLine(profile, line)
  local st = fortiRuns[profile.id]
  if st == nil or type(line) ~= "string" then
    return
  end
  local pid = line:match("^" .. STREAM_TAG .. "pid:(%d+)")
  if pid ~= nil then
    st.pid = pid
    return
  end
  local code = line:match("^" .. STREAM_TAG .. "done:(%d+)")
  if code ~= nil then
    finishFortiRun(profile, tonumber(code))
    return
  end

  local url = line:match("Authenticate at '(https://[^']+)'")
  if url ~= nil then
    st.phase = "browser"
    st.url = url
    -- The listener only waits ~50 s for the redirect, so open it right away.
    noctalia.runAsync({ "xdg-open", url })
    noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.forti_sign_in", { name = profile.name }))
    publishConnections()
  elseif line:find("Processing HTTP SAML request", 1, true) then
    st.phase = "connecting"
    publishConnections()
  elseif line:find("Tunnel is up and running", 1, true) then
    st.phase = "up"
    noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.forti_connected", { name = profile.name }))
    publishConnections()
  else
    local digest = line:match("%-%-trusted%-cert[%s=]+(%x+)")
    if digest ~= nil and #digest == 64 then
      st.certDigest = digest
    end
    local err = line:match("^ERROR:%s*(.-)%s*$")
    if err ~= nil and err ~= "" and st.lastError == nil then
      st.lastError = err
    end
  end
end

local function connectForti(profile)
  if fortiRuns[profile.id] ~= nil then
    return
  end
  local bin = fortiBinary()
  if bin == nil or not noctalia.commandExists("pkexec") then
    noctalia.notifyError(noctalia.tr("notifications.connect_failed"), noctalia.tr("notifications.forti_missing"))
    return
  end
  if not validProfile(profile) then
    noctalia.notifyError(noctalia.tr("notifications.connect_failed"), noctalia.tr("notifications.forti_bad_gateway"))
    return
  end

  local args = { "pkexec", shellQuote(bin), shellQuote(`{profile.host}:{math.floor(tonumber(profile.port))}`), "--saml-login" }
  if (profile.realm or "") ~= "" then
    table.insert(args, "--realm=" .. shellQuote(profile.realm))
  end
  if (profile.trustedCert or "") ~= "" then
    table.insert(args, "--trusted-cert=" .. shellQuote(profile.trustedCert))
  end
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    noctalia.notifyError(noctalia.tr("notifications.connect_failed"), noctalia.tr("notifications.no_data_dir"))
    return
  end
  -- openfortivpn logs to a private file that `tail --pid` follows, never
  -- straight into the stream's pipe: if a plugin reload drops that pipe, the
  -- tunnel's next log write would die of SIGPIPE. The log carries gateway
  -- messages and addresses, not the SAML cookie. pkexec execs openfortivpn in
  -- place, so $! is the tunnel's pid for the whole run.
  local logFile = shellQuote(`{dir}/forti-{profile.id}.log`)
  local cmd = `umask 077; : > {logFile}; `
    .. table.concat(args, " ")
    .. ` > {logFile} 2>&1 < /dev/null & p=$!; echo "{STREAM_TAG}pid:$p"; `
    .. `tail -n +1 --pid="$p" -f {logFile}; wait "$p"; echo "{STREAM_TAG}done:$?"`

  fortiRuns[profile.id] = { phase = "auth" }
  publishConnections()
  local ok = noctalia.runStream(cmd, function(line)
    onFortiLine(profile, line)
  end)
  if not ok then
    fortiRuns[profile.id] = nil
    publishConnections()
    noctalia.notifyError(noctalia.tr("notifications.connect_failed"), "failed to start openfortivpn")
  end
end

local function disconnectForti(profile)
  local st = fortiRuns[profile.id]
  if st == nil or st.stopping then
    return
  end
  if st.pid == nil or not st.pid:match("^%d+$") then
    return
  end
  st.stopping = true
  publishConnections()
  -- While the polkit prompt is up the pid is still pkexec with our real uid
  -- and can be signalled directly; once it has become openfortivpn it is root.
  local argv = if st.phase == "auth" then { "kill", "-TERM", st.pid } else { "pkexec", "kill", "-TERM", st.pid }
  run(argv, function(result)
    if result.exitCode ~= 0 then
      st.stopping = false
      publishConnections()
      noctalia.notifyError(noctalia.tr("notifications.disconnect_failed"), firstLine(result.stderr) ~= "" and firstLine(result.stderr) or noctalia.tr("notifications.forti_not_authorized"))
    elseif st.orphan then
      -- No stream to report the exit; the next reconcile confirms it is gone.
      fortiRuns[profile.id] = nil
      publishConnections()
    end
  end, 60000)
end

local function deleteForti(profile, index)
  if fortiRuns[profile.id] ~= nil then
    noctalia.notifyError(noctalia.tr("notifications.delete_failed"), noctalia.tr("notifications.forti_disconnect_first"))
    return
  end
  table.remove(data.fortiProfiles, index)
  saveData()
  local dir = noctalia.pluginDataDir()
  if dir ~= nil then
    noctalia.removeFile(`{dir}/forti-{profile.id}.log`)
  end
  publishConnections()
end

-- A tunnel survives a plugin reload (it is a root process), but its output
-- stream does not. Match running openfortivpn processes back to profiles by
-- their gateway argument so the row stays accurate and can be disconnected.
local function reconcileForti()
  if #data.fortiProfiles == 0 then
    return
  end
  run({ "pgrep", "-a", "-x", "openfortivpn" }, function(result)
    local running = {}
    for line in (result.stdout or ""):gmatch("[^\n]+") do
      local pid, cmdline = line:match("^(%d+)%s+(.*)$")
      if pid ~= nil then
        for token in cmdline:gmatch("%S+") do
          running[token] = pid
        end
      end
    end
    local changed = false
    for _, profile in ipairs(data.fortiProfiles) do
      local pid = running[`{profile.host}:{profile.port}`]
      local st = fortiRuns[profile.id]
      if pid ~= nil and st == nil then
        fortiRuns[profile.id] = { phase = "up", pid = pid, orphan = true }
        changed = true
      elseif pid == nil and st ~= nil and st.orphan then
        fortiRuns[profile.id] = nil
        changed = true
      end
    end
    if changed then
      publishConnections()
    end
  end)
end

-- An import can fail after the panel has closed (the picker closes it), so a
-- toast is the only thing the user sees and it is gone in seconds. Record the
-- failure too, and the panel shows it the next time it is opened.
local function importFailed(reason, path)
  noctalia.state.set("vpn.lastImport", {
    ok = false,
    reason = reason,
    path = path or "",
    at = os.time(),
  })
  noctalia.notifyError(noctalia.tr("notifications.import_failed"), reason)
end

local function finishImport(path, typeArg, isTemp)
  local function cleanup()
    if isTemp then
      noctalia.removeFile(path)
    end
  end

  local function doImport(resolvedType)
    if resolvedType == nil then
      importFailed(noctalia.tr("notifications.detect_failed"), path)
      cleanup()
      return
    end
    -- Not a NetworkManager connection: becomes a Fortinet SAML profile.
    if resolvedType == "openfortivpn" then
      local profile, problem = importOpenfortivpnConfig(path, noctalia.readFile(path), isTemp)
      cleanup()
      if profile == nil then
        importFailed(problem, if isTemp then "" else path)
        return
      end
      noctalia.state.set("vpn.lastImport", { ok = true, reason = "", path = "", at = os.time() })
      noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.imported", { name = profile.name }))
      return
    end
    run({ "nmcli", "connection", "import", "type", resolvedType, "file", path }, function(result)
      cleanup()
      log(`import result exitCode={result.exitCode} stdout={result.stdout:gsub("\n", "\\n")} stderr={result.stderr:gsub("\n", "\\n")}`)
      if result.exitCode ~= 0 then
        importFailed(firstLine(result.stderr) .. packageHintFor(resolvedType), path)
        return
      end
      -- Newly imported connections default to autoconnect=yes (NM connects them at
      -- boot / whenever the device is available); this plugin drives activation
      -- itself, so turn that off to avoid two different things deciding when the
      -- VPN comes up.
      local newName = result.stdout:match("Connection '([^']+)'")
      local newUuid = result.stdout:match("%(([%w%-]+)%)")
      if newUuid ~= nil then
        run({ "nmcli", "connection", "modify", "uuid", newUuid, "connection.autoconnect", "no" }, function() end)
      end
      noctalia.state.set("vpn.lastImport", { ok = true, reason = "", path = "", at = os.time() })
      noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.imported", { name = newName or noctalia.tr("notifications.a_connection") }))
      refreshAll()
    end, 20000)
  end

  if typeArg ~= nil and typeArg ~= "" then
    doImport(typeArg)
  else
    local content = noctalia.readFile(path)
    doImport(detectImportType(content))
  end
end

local function importFromPath(path, typeArg)
  path = trim(path)
  if path == "" then
    importFailed(noctalia.tr("notifications.no_path"), "")
    return
  end
  path = noctalia.expandPath(path)
  if not noctalia.fileExists(path) then
    importFailed(noctalia.tr("notifications.file_not_found", { path = path }), path)
    return
  end
  finishImport(path, typeArg, false)
end

local function importFromText(text, typeArg)
  if type(text) ~= "string" or trim(text) == "" then
    importFailed(noctalia.tr("notifications.no_paste"), "")
    return
  end
  -- Deliberately not logged: a pasted config carries private keys, PSKs and
  -- certificates, and the shell log is a world-readable file on disk.
  log(`importFromText received {#text} bytes`)
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    importFailed(noctalia.tr("notifications.no_data_dir"), "")
    return
  end
  local tmpPath = dir .. "/import-" .. tostring(math.floor(noctalia.nowMs())) .. ".tmp"
  local ok = noctalia.writeFile(tmpPath, text)
  if not ok then
    importFailed(noctalia.tr("notifications.write_failed"), "")
    return
  end
  finishImport(tmpPath, typeArg, true)
end

-- ── trust evaluation / auto-connect decision ────────────────────────────

local function maybeAutoConnect()
  if not cfgBool("auto_connect_enabled", false) then
    return
  end
  if os.time() < autoConnectBlockedUntil then
    return
  end
  local uuid = data.defaultVpnUuid
  if uuid == nil or uuid == "" then
    return
  end
  for _, row in ipairs(lastVpnRows) do
    if row.uuid == uuid then
      if row.active then
        return
      end
      connectUuid(uuid, true)
      return
    end
  end
  -- default VPN no longer exists
  data.defaultVpnUuid = ""
  saveData()
end

local function maybeAutoDisconnect()
  if not cfgBool("auto_disconnect_on_trusted", true) then
    return
  end
  local uuid = data.autoStartedUuid
  if uuid == nil or uuid == "" then
    return
  end

  -- The VPN may already be down: it dropped, or it was disconnected outside
  -- this plugin. Tearing down a connection that is not up makes nmcli fail and
  -- would report an auto-disconnect failure that never happened, so just drop
  -- the marker instead.
  local active = false
  for _, row in ipairs(lastVpnRows) do
    if row.uuid == uuid then
      active = row.active == true
    end
  end
  if not active then
    data.autoStartedUuid = ""
    saveData()
    return
  end

  disconnectUuid(uuid, true)
end

local function evaluateTrust(physicalRows)
  if #physicalRows == 0 then
    untrustedStreak = 0
    trustedStreak = 0
    return
  end
  local trustAllEthernet = cfgBool("trust_all_ethernet", true)
  local anyTrusted = false
  for _, row in ipairs(physicalRows) do
    if row.ctype == "802-3-ethernet" and trustAllEthernet then
      anyTrusted = true
    end
    if isTrusted(row.key) then
      anyTrusted = true
    end
  end

  local threshold = cfgInt("stable_checks", 1, 20, 3)
  if anyTrusted then
    trustedStreak += 1
    untrustedStreak = 0
    -- Back on a trusted network: the next untrusted one deserves a fresh try.
    autoConnectBlockedUntil = 0
    if trustedStreak >= threshold then
      maybeAutoDisconnect()
    end
  else
    untrustedStreak += 1
    trustedStreak = 0
    if untrustedStreak >= threshold then
      maybeAutoConnect()
    end
  end
end

-- ── full refresh: connections + network trust in one nmcli round trip ──────

refreshAll = function()
  if refreshInFlight then
    return
  end
  refreshInFlight = true

  run({ "nmcli", "-t", "-f", "NAME,TYPE,UUID,AUTOCONNECT,ACTIVE,DEVICE", "--escape", "no", "connection", "show" }, function(result)
    if result.exitCode ~= 0 then
      log("connection show failed: " .. firstLine(result.stderr))
      refreshInFlight = false
      return
    end

    local vpnRows, physicalRows = {}, {}
    for line in result.stdout:gmatch("[^\n]+") do
      local name, ctype, uuid, autoconnect, active, device = line:match("^(.*):([^:]*):([^:]*):([^:]*):([^:]*):([^:]*)$")
      if uuid ~= nil and uuid ~= "" then
        local row = {
          name = name,
          ctype = ctype,
          uuid = uuid,
          autoconnect = autoconnect == "yes",
          active = active == "yes",
          device = device,
        }
        if ctype == "vpn" or ctype == "wireguard" then
          table.insert(vpnRows, row)
        elseif row.active and (ctype == "802-11-wireless" or ctype == "802-3-ethernet" or ctype == "gsm" or ctype == "cdma") then
          table.insert(physicalRows, row)
        end
      end
    end

    mapAsync(vpnRows, function(row, done)
      if row.ctype == "wireguard" then
        row.protocol = "WireGuard"
        done(row)
      else
        run({ "nmcli", "-g", "vpn.service-type", "connection", "show", row.uuid }, function(r2)
          local svc = r2.exitCode == 0 and trim(r2.stdout) or ""
          row.protocol = friendlyProtocol(row.ctype, svc)
          done(row)
        end)
      end
    end, function(enrichedVpnRows)
      mapAsync(physicalRows, function(row, done)
        if row.ctype == "802-11-wireless" then
          run({ "nmcli", "-g", "802-11-wireless.ssid", "connection", "show", row.uuid }, function(r2)
            local ssid = r2.exitCode == 0 and trim(r2.stdout) or ""
            row.key = ssid ~= "" and ssid or row.name
            done(row)
          end)
        else
          row.key = row.name
          done(row)
        end
      end, function(enrichedPhysicalRows)
        lastVpnRows = enrichedVpnRows
        publishConnections()

        local currentNetworks = {}
        for _, row in ipairs(enrichedPhysicalRows) do
          table.insert(currentNetworks, {
            key = row.key,
            kind = if row.ctype == "802-11-wireless" then "wifi" elseif row.ctype == "802-3-ethernet" then "ethernet" else "cellular",
            trusted = isTrusted(row.key) or (row.ctype == "802-3-ethernet" and cfgBool("trust_all_ethernet", true)),
          })
        end
        noctalia.state.set("vpn.currentNetworks", currentNetworks)

        evaluateTrust(enrichedPhysicalRows)
        refreshInFlight = false
      end)
    end)
  end)
end

-- ── commands from panel / bar / shortcut ────────────────────────────────

-- ── connection details and editing ───────────────────────────────────────

local DETAIL_FIELDS = "GENERAL.STATE,GENERAL.DEVICES,VPN.VPN-STATE,IP4.ADDRESS,IP4.GATEWAY,IP6.ADDRESS"

-- nmcli returns indexed keys for repeatable fields ("IP4.ADDRESS[1]"), so the
-- index is stripped before the label lookup.
local DETAIL_LABELS = {
  ["GENERAL.STATE"] = "state",
  ["GENERAL.DEVICES"] = "device",
  ["VPN.VPN-STATE"] = "vpn_state",
  ["IP4.ADDRESS"] = "ipv4",
  ["IP4.GATEWAY"] = "gateway",
  ["IP6.ADDRESS"] = "ipv6",
}

local FORTI_PHASE_KEYS = { auth = "forti_auth", browser = "forti_browser", connecting = "forti_connecting", up = "forti_up" }

local function fortiDetails(uuid, profile)
  local st = fortiRuns[profile.id]
  local rows = {
    { label = noctalia.tr("panel.detail.gateway"), value = `{profile.host}:{profile.port}` },
    { label = noctalia.tr("panel.detail.state"), value = noctalia.tr("panel.detail." .. (st ~= nil and FORTI_PHASE_KEYS[st.phase] or "forti_down")) },
  }
  if (profile.realm or "") ~= "" then
    table.insert(rows, { label = noctalia.tr("panel.detail.realm"), value = profile.realm })
  end
  if (profile.trustedCert or "") ~= "" then
    table.insert(rows, { label = noctalia.tr("panel.detail.cert"), value = profile.trustedCert:sub(1, 16) .. "…" })
  end
  if st ~= nil and st.pid ~= nil then
    table.insert(rows, { label = noctalia.tr("panel.detail.pid"), value = st.pid })
  end
  noctalia.state.set("vpn.details", { uuid = uuid, rows = rows })
end

local function fetchDetails(uuid)
  local profile = fortiProfileFor(uuid)
  if profile ~= nil then
    fortiDetails(uuid, profile)
    return
  end
  if not isUuid(uuid) then
    return
  end
  run({ "nmcli", "-t", "-f", DETAIL_FIELDS, "connection", "show", "--active", uuid }, function(result)
    local rows = {}
    for _, line in ipairs(splitLines(result.stdout)) do
      local key, value = line:match("^([^:]+):(.*)$")
      if key ~= nil then
        local bare = key:gsub("%[%d+%]$", "")
        local labelKey = DETAIL_LABELS[bare]
        value = trim(value)
        if labelKey ~= nil and value ~= "" then
          table.insert(rows, { label = noctalia.tr(`panel.detail.{labelKey}`), value = value })
        end
      end
    end
    noctalia.state.set("vpn.details", { uuid = uuid, rows = rows })
  end)
end

-- nm-connection-editor is the graphical editor; where it is not installed, fall
-- back to nmtui-edit in a terminal. Neither is required for the plugin to work,
-- so a box with neither just gets told so.
local function editConnection(uuid)
  if not isUuid(uuid) then
    return
  end
  if noctalia.commandExists("nm-connection-editor") then
    run({ "nm-connection-editor", "--edit=" .. uuid })
  elseif noctalia.commandExists("nmtui-edit") then
    noctalia.runInTerminal("nmtui-edit " .. uuid)
  else
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notifications.no_editor"))
  end
end

-- ── file picker ──────────────────────────────────────────────────────────

-- A GUI picker outlives the runAsync call that spawns it, so it is detached
-- with `&` and writes the chosen path to a temp file that update() consumes.
-- This mirrors what other Noctalia plugins do for file selection.
local pendingPick = nil -- { path = <tmp file>, started = <epoch seconds> }

local function startFilePicker()
  if pendingPick ~= nil then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notifications.pick_in_progress"))
    return
  end

  local picker, pickerBinary, pickerNeedle
  if noctalia.commandExists("kdialog") then
    picker = "kdialog --getopenfilename ~ '*.ovpn *.conf *.zip config|VPN configurations'"
    pickerBinary, pickerNeedle = "kdialog", "--getopenfilename"
  elseif noctalia.commandExists("zenity") then
    picker = "zenity --file-selection --title='Select a VPN configuration'"
    pickerBinary, pickerNeedle = "zenity", "--file-selection"
  else
    noctalia.notifyError(noctalia.tr("notifications.import_failed"), noctalia.tr("notifications.no_picker"))
    return
  end

  local dir = noctalia.pluginDataDir()
  if dir == nil then
    noctalia.notifyError(noctalia.tr("notifications.import_failed"), noctalia.tr("notifications.no_data_dir"))
    return
  end

  local tmp = `{dir}/pick.tmp`
  noctalia.removeFile(tmp)
  pendingPick = { path = tmp, started = os.time(), binary = pickerBinary, needle = pickerNeedle, checking = false }
  noctalia.state.set("vpn.picking", true)
  noctalia.runAsync(`{picker} > {shellQuote(tmp)} 2>/dev/null &`)
end

-- Called from update(). The chosen file is imported straight away rather than
-- being written back into the path field: one action, and the connection list
-- updates in place. A cancelled picker writes nothing, so the wait is bounded
-- either way.
local function clearPick()
  if pendingPick ~= nil then
    noctalia.removeFile(pendingPick.path)
    pendingPick = nil
  end
  noctalia.state.set("vpn.picking", false)
end

local function pollFilePicker()
  if pendingPick == nil then
    return
  end

  local raw = noctalia.readFile(pendingPick.path)
  if raw ~= nil and trim(raw) ~= "" then
    local path = trim(raw)
    clearPick()
    importFromPath(path, nil)
    return
  end

  -- Cancelling writes nothing, so waiting for output alone would leave the
  -- picker "in progress" until the timeout. Watch for the process going away
  -- instead, and treat that as a cancel.
  if not pendingPick.checking and os.time() - pendingPick.started >= 2 then
    pendingPick.checking = true
    local binary, needle = pendingPick.binary, pendingPick.needle
    noctalia.processMatches(function(stillRunning)
      if pendingPick ~= nil then
        if stillRunning then
          pendingPick.checking = false
        else
          clearPick()
        end
      end
    end, binary, needle)
  end

  if os.time() - pendingPick.started > 120 then
    clearPick()
  end
end

-- connect/disconnect/delete take either a NetworkManager UUID or a Fortinet
-- SAML row id; the UI sends the same ops for both.
local function connectAny(uuid)
  local profile = fortiProfileFor(uuid)
  if profile ~= nil then
    connectForti(profile)
  elseif not isFortiId(uuid) then
    connectUuid(uuid, false)
  end
end

local function disconnectAny(uuid)
  local profile = fortiProfileFor(uuid)
  if profile ~= nil then
    disconnectForti(profile)
  elseif not isFortiId(uuid) then
    disconnectUuid(uuid, false)
  end
end

local function deleteAny(uuid)
  local profile, index = fortiProfileFor(uuid)
  if profile ~= nil then
    deleteForti(profile, index)
  elseif not isFortiId(uuid) then
    deleteUuid(uuid)
  end
end

local function handleCommand(cmd)
  if type(cmd) ~= "table" then
    return
  end
  local op = cmd.op
  if op == "connect" then
    connectAny(cmd.uuid)
  elseif op == "disconnect" then
    disconnectAny(cmd.uuid)
  elseif op == "delete" then
    deleteAny(cmd.uuid)
  elseif op == "fortiAdd" then
    addFortiProfile(cmd)
  elseif op == "fortiOpenLogin" then
    local profile = fortiProfileFor(cmd.uuid)
    local st = profile ~= nil and fortiRuns[profile.id] or nil
    if st ~= nil and st.url ~= nil then
      noctalia.runAsync({ "xdg-open", st.url })
    end
  elseif op == "setDefault" then
    -- SAML needs someone at a browser, so a Fortinet profile can never be the
    -- auto-connect default.
    if isFortiId(cmd.uuid) then
      return
    end
    data.defaultVpnUuid = cmd.uuid or ""
    saveData()
    publishTrust()
    publishConnections()
  elseif op == "trust" then
    local name = trim(cmd.name)
    if name ~= "" and not isTrusted(name) then
      table.insert(data.trustedNetworks, name)
      saveData()
      publishTrust()
      untrustedStreak = 0
    end
  elseif op == "untrust" then
    local name = trim(cmd.name)
    for i, n in ipairs(data.trustedNetworks) do
      if n == name then
        table.remove(data.trustedNetworks, i)
        break
      end
    end
    saveData()
    publishTrust()
  elseif op == "import" then
    importFromPath(cmd.path, cmd.importType)
  elseif op == "importText" then
    importFromText(cmd.text, cmd.importType)
  elseif op == "dismissImportError" then
    noctalia.state.set("vpn.lastImport", { ok = true, reason = "", path = "", at = 0 })
  elseif op == "pick" then
    startFilePicker()
  elseif op == "details" then
    fetchDetails(cmd.uuid)
  elseif op == "edit" then
    editConnection(cmd.uuid)
  elseif op == "refresh" then
    refreshAll()
  end
end

noctalia.state.watch("vpn.cmd", function(cmd)
  if cmd ~= nil then
    handleCommand(cmd)
    noctalia.state.set("vpn.cmd", nil)
  end
end)

function onIpc(event, payload)
  if event == "refresh" then
    refreshAll()
  elseif event == "connect" then
    connectAny(payload)
  elseif event == "disconnect" then
    disconnectAny(payload)
  elseif event == "status" then
    local names = {}
    for _, row in ipairs(lastVpnRows) do
      if row.active then
        table.insert(names, row.name)
      end
    end
    for _, profile in ipairs(data.fortiProfiles) do
      local st = fortiRuns[profile.id]
      if st ~= nil and st.phase == "up" then
        table.insert(names, profile.name)
      end
    end
    noctalia.notify(noctalia.tr("title"), #names > 0 and table.concat(names, ", ") or noctalia.tr("notifications.status_none"))
  elseif event == "list" then
    for _, row in ipairs(lastVpnRows) do
      log(`conn name={row.name} type={row.ctype} protocol={row.protocol} uuid={row.uuid} active={tostring(row.active)}`)
    end
    for _, profile in ipairs(data.fortiProfiles) do
      local st = fortiRuns[profile.id]
      log(`forti name={profile.name} gateway={profile.host}:{profile.port} uuid={FORTI_PREFIX}{profile.id} phase={st ~= nil and st.phase or "down"}`)
    end
    log(`trusted={table.concat(data.trustedNetworks, ",")} default={data.defaultVpnUuid} autoStarted={data.autoStartedUuid}`)
  elseif event == "import" then
    importFromPath(payload, nil)
  elseif event == "pick" then
    startFilePicker()
  elseif event == "dismiss-error" then
    noctalia.state.set("vpn.lastImport", { ok = true, reason = "", path = "", at = 0 })
  end
end

function onEnable()
  refreshAll()
end

function update()
  tickCount += 1
  pollFilePicker()
  local interval = cfgInt("poll_interval_seconds", 2, 60, 5)
  if tickCount % interval == 0 then
    refreshAll()
    reconcileForti()
  end
end

loadData()
publishTrust()
publishAvailableProtocols()
noctalia.state.set("vpn.connections", {})
noctalia.state.set("vpn.status", { anyActive = false, activeNames = {} })
noctalia.state.set("vpn.currentNetworks", {})
noctalia.state.set("vpn.details", { uuid = "", rows = {} })
noctalia.state.set("vpn.picking", false)
noctalia.state.set("vpn.lastImport", { ok = true, reason = "", path = "", at = 0 })
refreshAll()
reconcileForti()
