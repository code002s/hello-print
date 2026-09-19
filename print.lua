-- ═══════════════════════════════════════════════════════════════════════════
-- KYNX KINETIC CONTROL — Full module (v2.4.1)
-- Host this file raw and load with:
--   loadstring(game:HttpGet("https://your.host/kynx.lua"))()
-- ═══════════════════════════════════════════════════════════════════════════

local Kynx = {}
Kynx._version = "2.4.1"

local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ═══════════════════════════════════════════════════════════════════════════
-- SHARED CONFIG
-- ═══════════════════════════════════════════════════════════════════════════
local Config = {}
Config.PANEL_URL = "https://ada07613-0327-47ff-9c9e-3bf2e243362e-00-cj11f1iag30v.sisko.replit.dev"
Config.USERNAME = "cere"
Config.PASSWORD = "cere"
Config.PASSWORD_VALUE_NAME = "KynxPanelPassword"
Config.HEARTBEAT_INTERVAL = 30
Config.THREAT_KICK_TIER = 3
Config.AUTO_BAN_TIER4 = true
Config.CMD_PREFIX = "/kynx"
Config.LOG_CHAT = true
Config.LOG_JOINS = true
Config.CLIENT_SCAN_INTERVAL = 15
Config.LOG_LOCAL = false
Config.ANTI_TAMPER = true

local function getPassword(): string?
  if type(Config.PASSWORD) == "string" and Config.PASSWORD ~= "" then
    return Config.PASSWORD
  end
  local ok, serverStorage = pcall(function() return game:GetService("ServerStorage") end)
  if ok and serverStorage then
    local value = serverStorage:FindFirstChild(Config.PASSWORD_VALUE_NAME)
    if value and value:IsA("StringValue") and value.Value ~= "" then
      return value.Value
    end
  end
  return nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SHARED THREAT MAP (single source of truth for client + server)
-- ═══════════════════════════════════════════════════════════════════════════
local EXECUTOR_TIER_MAP = {
  ["syn"] = 4, ["SENTINEL_V2"] = 4, ["elysian"] = 4, ["scriptware"] = 4,
  ["KRNL_ENV"] = 3, ["fluxus"] = 3, ["hydrogen"] = 3, ["delta"] = 3,
  ["deluaenv"] = 3, ["oxylua"] = 3, ["coco_z"] = 3,
  ["getgenv"] = 2, ["getsenv"] = 2, ["getrawmetatable"] = 2,
  ["hookfunction"] = 2, ["hookmetamethod"] = 2, ["newcclosure"] = 2,
  ["isexecutorclosure"] = 2, ["checkcaller"] = 2, ["getnamecallmethod"] = 2,
  ["readfile"] = 1, ["writefile"] = 1, ["request"] = 1, ["http_request"] = 1,
  ["Drawing"] = 1, ["identifyexecutor"] = 1, ["decompile"] = 1,
  ["loadstring"] = 1, ["getconnections"] = 1,
}

local function tierName(tier: number): string
  if tier >= 4 then return "CRITICAL" end
  if tier == 3 then return "HIGH" end
  if tier == 2 then return "MEDIUM" end
  return "LOW"
end

local SERVER_ONLY_ACTIONS = {
  KICK_PLAYER = true, BAN_PLAYER = true,
  SHUTDOWN_SERVER = true, EXECUTE_SCRIPT = true,
}

-- ═══════════════════════════════════════════════════════════════════════════
-- SERVER BRANCH
-- ═══════════════════════════════════════════════════════════════════════════
if RunService:IsServer() then

  local Stats = game:GetService("Stats")

  -- ── REMOTES ──────────────────────────────────────────────────────────
  local Remotes = {}
  local function ensureRemote(className, name)
    local existing = ReplicatedStorage:FindFirstChild(name)
    if existing then return existing end
    local inst = Instance.new(className)
    inst.Name = name
    inst.Parent = ReplicatedStorage
    return inst
  end

  Remotes.probe       = ensureRemote("RemoteFunction", "KynxProbe")
  Remotes.config      = ensureRemote("RemoteEvent",    "KynxConfig")
  Remotes.automations = ensureRemote("RemoteEvent",    "KynxAutomations")
  Remotes.telemetry   = ensureRemote("RemoteEvent",    "KynxTelemetry")
  Remotes.clientEvent = ensureRemote("RemoteEvent",    "KynxClientEvent")

  -- ── API ──────────────────────────────────────────────────────────────
  local API = {}
  local _token = nil
  local _baseUrl = Config.PANEL_URL
  API._logQueue = {}
  API._ackQueue = {}

  local _jobId = game.JobId
  if _jobId == "" then
    _jobId = "STUDIO-" .. game.PlaceId .. "-" .. HttpService:GenerateGUID(false)
  end

  local function buildHeaders()
    local h = {["Content-Type"] = "application/json", ["Accept"] = "application/json"}
    if _token then h["Authorization"] = "Bearer " .. _token end
    return h
  end

  local function request(method, path, body)
    local url = _baseUrl .. "/api" .. path
    local ok, result = pcall(function()
      return HttpService:RequestAsync({
        Url = url, Method = method,
        Headers = buildHeaders(),
        Body = body and HttpService:JSONEncode(body) or nil,
      })
    end)
    if not ok then warn("[KYNX/API] Fail:", result); return false, nil end
    if typeof(result) ~= "table" then return false, nil end
    if result.StatusCode == 401 then _token = nil; return false, nil end
    if result.StatusCode < 200 or result.StatusCode >= 300 then
      warn("[KYNX/API] " .. method .. " " .. path .. " -> " .. result.StatusCode)
      return false, nil
    end
    local data = nil
    if result.Body and #result.Body > 0 then
      local pOk, parsed = pcall(function() return HttpService:JSONDecode(result.Body) end)
      if pOk then data = parsed end
    end
    return true, data
  end

  function API.ensureSession()
    if _token then return true end
    if _baseUrl == "" then return false end
    local password = getPassword()
    if not password then
      warn("[KYNX] No panel password configured — see getPassword() in this module.")
      return false
    end
    local ok, data = request("POST", "/auth/login", {username = Config.USERNAME, password = password})
    if ok and data and data.token and typeof(data.token) == "string" then
      _token = data.token; return true
    end
    return false
  end

  function API.getThreats()
    if not API.ensureSession() then return nil, false end
    local ok, data = request("GET", "/threats")
    return ok and data or nil, ok
  end

  function API.getThreatStats()
    if not API.ensureSession() then return nil, false end
    local ok, data = request("GET", "/dashboard/stats")
    return ok and data or nil, ok
  end

  function API.getBans(userId)
    if not API.ensureSession() then return nil, false end
    local ok, data = request("GET", "/bans?search=" .. HttpService:UrlEncode(userId))
    return ok and data or nil, ok
  end

  function API.createBan(username, userId, reason, bannedBy)
    if not API.ensureSession() then return nil, false end
    local ok, data = request("POST", "/bans", {
      username = username, userId = userId, reason = reason,
      bannedBy = bannedBy or "KYNX",
    })
    return ok and data or nil, ok
  end

  function API.createLog(logType, user, message, extras)
    local entry = {type = logType, user = user, message = message}
    if extras then
      if extras.knownAlts then entry.knownAlts = extras.knownAlts end
      if extras.assetId then entry.assetId = extras.assetId end
      if extras.scriptSource then entry.scriptSource = extras.scriptSource end
    end
    table.insert(API._logQueue, entry)
    return true
  end

  function API.flushLogs()
    if not API.ensureSession() then return false end
    local logs = API._logQueue
    API._logQueue = {}
    if #logs == 0 then return true end
    for _, log in ipairs(logs) do request("POST", "/logs", log) end
    return true
  end

  function API.getAutomations()
    if not API.ensureSession() then return nil, false end
    local ok, data = request("GET", "/automations")
    return ok and data or nil, ok
  end

  function API.reportLeave(jobId, userId, username, durationMinutes)
    if not API.ensureSession() then return false end
    local ok = request("POST", "/servers/" .. HttpService:UrlEncode(jobId) .. "/leaves", {
      userId = tostring(userId),
      username = username,
      leftAt = DateTime.now():ToIsoDate(),
      durationMinutes = durationMinutes,
    })
    return ok
  end

  function API.heartbeat(serverData)
    if not API.ensureSession() then return nil end
    serverData.ackCommands = API._ackQueue
    API._ackQueue = {}
    local ok, data = request("POST", "/servers", serverData)
    if ok then API.flushLogs() end
    if ok and data and data.commands then return data.commands end
    return ok and {} or nil
  end

  function API.ackCommand(commandId, status)
    table.insert(API._ackQueue, {id = commandId, status = status})
    return true
  end

  -- ── BANS ─────────────────────────────────────────────────────────────
  local Bans = {}
  local function isBanned(player)
    local bans, ok = API.getBans(tostring(player.UserId))
    if not ok or not bans then return false, nil end
    for _, ban in ipairs(bans) do
      if tostring(ban.userId) == tostring(player.UserId) and not ban.whitelisted then
        return true, ban.reason
      end
    end
    return false, nil
  end

  function Bans.onPlayerAdded(player)
    local banned, reason = isBanned(player)
    if banned then
      player:Kick("Banned.\nReason: " .. (reason or "No reason"))
      API.createLog("action", "KYNX", "Kicked banned: " .. player.Name)
    end
  end

  function Bans.banPlayer(player, reason, bannedBy)
    local _, data = API.createBan(player.Name, tostring(player.UserId), reason, bannedBy or "KYNX")
    if data then
      player:Kick("Banned.\nReason: " .. reason)
      API.createLog("action", "KYNX", "Banned " .. player.Name .. ": " .. reason)
      return true
    end
    return false
  end

  -- ── AUTOMATIONS (forward-declared) ───────────────────────────────────
  local Automations = {}

  -- ── LOGS ─────────────────────────────────────────────────────────────
  local Logs = {}
  local _joinTimes = {}
  function Logs.hookPlayer(player)
    if Config.LOG_CHAT then
      player.Chatted:Connect(function(msg)
        if msg:lower():sub(1, #Config.CMD_PREFIX) == Config.CMD_PREFIX:lower() then return end
        API.createLog("chat", player.Name, msg)
        Automations.fire("CHAT_MESSAGE", player, {message = msg})
      end)
    end
  end
  function Logs.onPlayerAdded(player)
    _joinTimes[player.UserId] = os.time()
    if Config.LOG_JOINS then
      API.createLog("action", player.Name, "Joined (UserId: " .. player.UserId .. ")")
    end
    Logs.hookPlayer(player)
    player.CharacterAdded:Connect(function(character)
      local humanoid = character:WaitForChild("Humanoid", 5)
      if not humanoid then return end
      humanoid.Died:Connect(function()
        Automations.fire("PLAYER_DEATH", player)
      end)
    end)
  end
  function Logs.onPlayerRemoving(player)
    if Config.LOG_JOINS then
      API.createLog("action", player.Name, "Left (UserId: " .. player.UserId .. ")")
    end
    local joinedAt = _joinTimes[player.UserId]
    local durationMinutes = joinedAt and ((os.time() - joinedAt) / 60) or nil
    _joinTimes[player.UserId] = nil
    task.spawn(function()
      API.reportLeave(_jobId, player.UserId, player.Name, durationMinutes)
    end)
  end

  -- ── THREATS ──────────────────────────────────────────────────────────
  local Threats = {}
  local _cache = {}
  local _strictMode = false
  local _lastFetch = 0
  local CACHE_TTL = 120
  local _flaggedPlayers = {}

  local function recomputeFlagStatus()
    local maxTier = 0
    for _, tier in pairs(_flaggedPlayers) do
      if tier > maxTier then maxTier = tier end
    end
    if maxTier >= 3 then return "THREAT" end
    if maxTier >= 1 then return "SUSPICIOUS" end
    return "CLEAN"
  end

  local function refreshIfStale()
    local now = os.time()
    if now - _lastFetch < CACHE_TTL then return end
    _lastFetch = now
    local threats, ok = API.getThreats()
    if ok and threats then _cache = threats end
    local stats = API.getThreatStats()
    if stats then _strictMode = stats.strictModeEnabled == true end
  end

  local function effectiveKickTier()
    if _strictMode then
      return math.max(1, Config.THREAT_KICK_TIER - 1)
    end
    return Config.THREAT_KICK_TIER
  end

  function Threats.getServerFlagStatus() return recomputeFlagStatus() end

  function Threats.init()
    task.spawn(function()
      while true do
        refreshIfStale()
        for _, player in ipairs(Players:GetPlayers()) do
          task.spawn(function() Threats.probePlayer(player) end)
        end
        task.wait(15)
      end
    end)
  end

  function Threats.probePlayer(player)
    local probe = Remotes.probe
    if not probe or not probe:IsA("RemoteFunction") then return end
    local token = {}
    local completed = false
    local detected = nil

    task.spawn(function()
      local ok, result = pcall(function() return probe:InvokeClient(player) end)
      if token.cancelled then return end
      completed = true
      if ok then detected = result end
    end)

    local elapsed = 0
    while not completed and elapsed < 5 do
      task.wait(0.1)
      elapsed += 0.1
    end
    if not completed then
      token.cancelled = true
      return
    end

    if not detected or #detected == 0 then
      if _flaggedPlayers[player.UserId] then _flaggedPlayers[player.UserId] = nil end
      return
    end

    local maxTier = 0
    local detectedNames = {}
    for _, name in ipairs(detected) do
      local tier = EXECUTOR_TIER_MAP[name] or 1
      if tier > maxTier then maxTier = tier end
      table.insert(detectedNames, name)
    end
    if maxTier == 0 then return end
    _flaggedPlayers[player.UserId] = maxTier

    local threat = {
      name = "Executor: " .. table.concat(detectedNames, ", "),
      tier = maxTier, reason = "Client globals detected",
    }
    API.createLog("threat", player.Name,
      string.format("[T%d %s] %s", maxTier, tierName(maxTier), table.concat(detectedNames, ", ")))
    Automations.fire("THREAT_DETECTED", player, {tier = maxTier})
    Threats.handleThreat(player, threat)
  end

  function Threats.handleThreat(player, threat)
    local tier = threat.tier or 2
    local name = threat.name or "Unknown"
    local displayName = name
    if #displayName > 120 then displayName = string.sub(displayName, 1, 120) .. "..." end
    API.createLog("action", "KYNX",
      string.format("Blocked '%s' (T%d) for %s", displayName, tier, player.Name))
    Automations.fire("SCRIPT_BLOCKED", player, {tier = tier})
    if tier >= 4 and Config.AUTO_BAN_TIER4 then
      _flaggedPlayers[player.UserId] = nil
      Bans.banPlayer(player, "Auto-ban: " .. displayName, "KYNX/AUTO")
      return
    end
    if tier >= effectiveKickTier() then
      _flaggedPlayers[player.UserId] = nil
      player:Kick(string.format("Removed.\nReason: %s (Tier %d)", displayName, tier))
    end
  end

  Players.PlayerRemoving:Connect(function(player)
    _flaggedPlayers[player.UserId] = nil
  end)

  -- ── AUTOMATIONS ──────────────────────────────────────────────────────
  local _rules = {}
  local _rulesVersion = 0
  local _lastFetchAuto = 0
  local CACHE_TTL_AUTO = 60
  local _lastFired = {}

  local function sanitizeRuleForClient(rule)
    if SERVER_ONLY_ACTIONS[rule.action] then return nil end
    return {
      id = rule.id, name = rule.name, trigger = rule.trigger,
      condition = rule.condition, action = rule.action,
      message = rule.message, enabled = rule.enabled,
    }
  end

  local function broadcastRules()
    local out = {}
    for _, r in ipairs(_rules) do
      local s = sanitizeRuleForClient(r)
      if s then table.insert(out, s) end
    end
    Remotes.automations:FireAllClients({rules = out, version = _rulesVersion})
  end

  local function refreshRules()
    local now = os.time()
    if now - _lastFetchAuto < CACHE_TTL_AUTO then return end
    _lastFetchAuto = now
    local rules, ok = API.getAutomations()
    if ok and rules then
      _rules = rules
      _rulesVersion += 1
      broadcastRules()
    end
  end

  local function evalCondition(condition, ctx)
    if condition == "" or condition == "true" or condition == nil then return true end
    local field, op, value = condition:match("^%s*([%w_]+)%s*([=!<>]+)%s*([%w_%.%-]+)%s*$")
    if not field then
      warn("[KYNX/AUTO] Could not parse condition:", condition)
      return false
    end
    local actual = ctx[field]
    if actual == nil then return false end
    local numValue, numActual = tonumber(value), tonumber(actual)
    if numValue and numActual then
      if op == ">=" then return numActual >= numValue end
      if op == "<=" then return numActual <= numValue end
      if op == ">"  then return numActual >  numValue end
      if op == "<"  then return numActual <  numValue end
      if op == "==" then return numActual == numValue end
      if op == "!=" then return numActual ~= numValue end
    else
      local strActual = tostring(actual)
      if op == "==" then return strActual == value end
      if op == "!=" then return strActual ~= value end
    end
    return false
  end

  local function executeAction(rule, player, ctx)
    local action = rule.action or ""
    if action == "KICK_PLAYER" and player then
      player:Kick("[KYNX] Automation: " .. rule.name)
    elseif action == "BAN_PLAYER" and player then
      Bans.banPlayer(player, "Auto: " .. rule.name, "KYNX/AUTO")
    elseif action == "SEND_MESSAGE" and player then
      API.createLog("action", player.Name, "Auto-msg: " .. rule.name)
    elseif action == "SHUTDOWN_SERVER" then
      if not RunService:IsStudio() then
        pcall(function()
          game:GetService("TeleportService"):TeleportAsync(game.PlaceId, Players:GetPlayers())
        end)
      end
    elseif action == "LOG_EVENT" then
      local who = player and player.Name or "SERVER"
      API.createLog("action", who, "Auto fired: " .. rule.name)
    elseif action == "EXECUTE_SCRIPT" then
      warn("[KYNX/AUTO] Rule '" .. tostring(rule.name) .. "' requests EXECUTE_SCRIPT — unsupported, skipping.")
    end
  end

  function Automations.fire(trigger, player, extraCtx)
    refreshRules()
    local ctx = extraCtx or {}
    if player then ctx.playerId = player.UserId; ctx.playerName = player.Name end
    local now = os.time()
    for _, rule in ipairs(_rules) do
      if rule.trigger == trigger and rule.enabled then
        local cooldown = rule.cooldownSecs or 0
        local skip = false
        if cooldown > 0 then
          local last = _lastFired[rule.id] or 0
          if now - last < cooldown then skip = true end
        end
        if not skip and evalCondition(rule.condition or "true", ctx) then
          executeAction(rule, player, ctx)
          _lastFired[rule.id] = now
          API.createLog("action", "KYNX/AUTO", "Rule '" .. rule.name .. "' fired")
        end
      end
    end
  end

  -- ── TELEMETRY ────────────────────────────────────────────────────────
  local Telemetry = {}
  local _lastHeartbeat = os.clock()
  local _frameCount = 0
  Telemetry._lastExecutor = "N/A"
  RunService.Heartbeat:Connect(function() _frameCount += 1 end)

  local function collectMetrics()
    local playerList = Players:GetPlayers()
    local now = os.clock()
    local elapsed = now - _lastHeartbeat
    local fps = 0
    if elapsed > 0 then fps = math.floor(_frameCount / elapsed) end
    _lastHeartbeat = now
    _frameCount = 0
    local ping = 0
    local ok, p = pcall(function()
      return math.floor(Stats.Network.ServerStatsItem["Data Ping"]:GetValue())
    end)
    if ok then ping = p end
    local placeName = "Unknown"
    local ok2, info = pcall(function()
      return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
    end)
    if ok2 and info and info.Name then placeName = info.Name end

    local players = {}
    for _, plr in ipairs(playerList) do
      table.insert(players, { userId = plr.UserId, username = plr.Name })
    end

    return {
      jobId = _jobId, placeName = placeName, players = #playerList,
      playerList = players,
      ping = ping or 0, fps = fps or 0,
      flagStatus = Threats.getServerFlagStatus(),
      status = "online",
      executor = Telemetry._lastExecutor,
    }
  end

  local function executeCommand(cmd)
    local t = cmd.type or ""
    local id = cmd.id
    if t == "kick" then
      local target = Players:FindFirstChild(cmd.targetPlayer or "")
      if target then
        target:Kick("[KYNX Panel] Remote kick")
        API.createLog("action", "KYNX", "Remote kick: " .. target.Name)
        API.ackCommand(id, "executed")
      else
        API.ackCommand(id, "failed")
      end
    elseif t == "ban" then
      local target = Players:FindFirstChild(cmd.targetPlayer or "")
      if target then
        local banOk = pcall(function() Bans.banPlayer(target, "Remote ban via panel", "KYNX/PANEL") end)
        API.ackCommand(id, banOk and "executed" or "failed")
      else
        API.ackCommand(id, "failed")
      end
    elseif t == "shutdown" then
      API.createLog("action", "KYNX", "Remote shutdown")
      API.ackCommand(id, "executed")
      if not RunService:IsStudio() then
        task.wait(2)
        pcall(function()
          game:GetService("TeleportService"):TeleportAsync(game.PlaceId, Players:GetPlayers())
        end)
      end
    else
      warn("[KYNX/TELEMETRY] Unsupported command type:", t)
      API.ackCommand(id, "failed")
    end
  end

  function Telemetry.start()
    task.spawn(function()
      while true do
        local metrics = collectMetrics()
        local commands = API.heartbeat(metrics)
        if commands then
          for _, cmd in ipairs(commands) do
            task.spawn(function()
              local ok, err = pcall(executeCommand, cmd)
              if not ok then
                warn("[KYNX/TELEMETRY] Exec error:", err)
                API.ackCommand(cmd.id, "failed")
              end
            end)
          end
        end
        task.wait(Config.HEARTBEAT_INTERVAL)
      end
    end)
  end

  -- ── REMOTE HANDLERS ──────────────────────────────────────────────────
  Remotes.telemetry.OnServerEvent:Connect(function(player, payload)
    if type(payload) ~= "table" then return end
    if type(payload.executor) == "string" and payload.executor ~= "N/A" then
      Telemetry._lastExecutor = payload.executor
      if player and player.Parent then
        local maxTier = 0
        for name in string.gmatch(payload.executor, "([^,]+)") do
          name = name:gsub("^%s+", ""):gsub("%s+$", "")
          local t = EXECUTOR_TIER_MAP[name] or 1
          if t > maxTier then maxTier = t end
        end
        if maxTier > 0 then _flaggedPlayers[player.UserId] = maxTier end
      end
    end
  end)

  Remotes.clientEvent.OnServerEvent:Connect(function(player, trigger, ctx)
    if type(trigger) ~= "string" then return end
    Automations.fire(trigger, player, type(ctx) == "table" and ctx or {})
  end)

  -- ── SERVER INIT ──────────────────────────────────────────────────────
  if Config.PANEL_URL == "" then
    warn("[KYNX] WARNING: PANEL_URL not set")
  end
  if not getPassword() then
    warn("[KYNX] WARNING: panel password not configured — see getPassword()")
  end
  print("[KYNX] Starting Kynx Kinetic Control…")

  local authOk = API.ensureSession()
  if not authOk then warn("[KYNX] Auth failed — some features unavailable") end
  refreshIfStale()
  Threats.init()

  local function pushConfigTo(player)
    Remotes.config:FireClient(player, {
      CMD_PREFIX = Config.CMD_PREFIX,
      LOG_CHAT = Config.LOG_CHAT,
      LOG_LOCAL = Config.LOG_LOCAL,
      CLIENT_SCAN_INTERVAL = Config.CLIENT_SCAN_INTERVAL,
      ANTI_TAMPER = Config.ANTI_TAMPER,
      version = Kynx._version,
    })
  end

  Players.PlayerAdded:Connect(function(player)
    Bans.onPlayerAdded(player)
    Logs.onPlayerAdded(player)
    pushConfigTo(player)
    local out = {}
    for _, r in ipairs(_rules) do
      local s = sanitizeRuleForClient(r)
      if s then table.insert(out, s) end
    end
    Remotes.automations:FireClient(player, {rules = out, version = _rulesVersion})
    Automations.fire("PLAYER_JOIN", player)
  end)

  Players.PlayerRemoving:Connect(function(player)
    Logs.onPlayerRemoving(player)
    Automations.fire("PLAYER_LEAVE", player)
  end)

  for _, player in ipairs(Players:GetPlayers()) do
    task.spawn(function()
      Bans.onPlayerAdded(player)
      Logs.onPlayerAdded(player)
      pushConfigTo(player)
      Automations.fire("PLAYER_JOIN", player)
    end)
  end

  Telemetry.start()

  print("[KYNX] Kynx Kinetic Control is running ✓")
  print(string.format("[KYNX] Panel: %s | Heartbeat: %ds | Tier: %d",
    Config.PANEL_URL ~= "" and Config.PANEL_URL or "(not set)",
    Config.HEARTBEAT_INTERVAL, effectiveKickTier()))

-- ═══════════════════════════════════════════════════════════════════════════
-- CLIENT BRANCH
-- ═══════════════════════════════════════════════════════════════════════════
elseif RunService:IsClient() then

  local Stats = game:GetService("Stats")
  local LocalPlayer = Players.LocalPlayer

  Kynx.Config = Config
  Kynx.API = { _logQueue = {}, _ackQueue = {}, _sessionReady = false }

  function Kynx.API:createLog(logType, user, message)
    table.insert(self._logQueue,
      {type = logType, user = user, message = message, timestamp = os.time()})
    if Config.LOG_LOCAL then
      print(string.format("[KYNX/LOG][%s] %s: %s", logType:upper(), user, message))
    end
    return true
  end
  function Kynx.API:ackCommand(id, status)
    table.insert(self._ackQueue, {id = id, status = status})
    return true
  end

  -- ── REMOTES (bounded waits) ──────────────────────────────────────────
  local Remotes = {}
  Remotes.probe       = ReplicatedStorage:WaitForChild("KynxProbe",       10)
  Remotes.config      = ReplicatedStorage:WaitForChild("KynxConfig",      10)
  Remotes.automations = ReplicatedStorage:WaitForChild("KynxAutomations", 10)
  Remotes.telemetry   = ReplicatedStorage:WaitForChild("KynxTelemetry",   10)
  Remotes.clientEvent = ReplicatedStorage:WaitForChild("KynxClientEvent", 10)

  -- ── THREATS ──────────────────────────────────────────────────────────
  Kynx.Threats = {
    _serverFlagStatus = "CLEAN",
    EXECUTOR_TIER_MAP = EXECUTOR_TIER_MAP,
    _ready = false,
  }

  function Kynx.Threats:tierName(tier) return tierName(tier) end

  function Kynx.Threats:scanClient()
    local detected = {}
    for name in pairs(self.EXECUTOR_TIER_MAP) do
      local ok, exists = pcall(function()
        return _G[name] ~= nil or rawget(_G, name) ~= nil
      end)
      if ok and exists then table.insert(detected, name) end
    end
    return detected
  end

  function Kynx.Threats:handleThreat(detected)
    local maxTier = 0
    for _, name in ipairs(detected) do
      local tier = self.EXECUTOR_TIER_MAP[name] or 1
      if tier > maxTier then maxTier = tier end
    end
    if maxTier == 0 then return end
    if maxTier >= 3 then self._serverFlagStatus = "THREAT"
    elseif maxTier >= 1 then self._serverFlagStatus = "SUSPICIOUS" end
    Kynx.API:createLog("threat", LocalPlayer.Name,
      string.format("[T%d %s] %s", maxTier, self:tierName(maxTier), table.concat(detected, ", ")))
  end

  function Kynx.Threats:init()
    if Remotes.probe and Remotes.probe:IsA("RemoteFunction") then
      Remotes.probe.OnClientInvoke = function() return self:scanClient() end
      self._ready = true
    else
      warn("[KYNX/THREATS] KynxProbe not available after 10s — running scan loop without handshake.")
    end

    task.spawn(function()
      while true do
        local detected = self:scanClient()
        if #detected > 0 then
          self:handleThreat(detected)
          if Remotes.telemetry then
            Remotes.telemetry:FireServer({
              executor = table.concat(detected, ", "),
              flagStatus = self._serverFlagStatus,
              timestamp = os.time(),
            })
          end
        else
          self._serverFlagStatus = "CLEAN"
        end
        task.wait(Config.CLIENT_SCAN_INTERVAL or 15)
      end
    end)

    print("[KYNX/THREATS] Client monitoring initialised (probe=" .. tostring(self._ready) .. ")")
  end

  function Kynx.Threats:getServerFlagStatus() return self._serverFlagStatus end

  -- ── CONFIG REMOTE ────────────────────────────────────────────────────
  if Remotes.config then
    Remotes.config.OnClientEvent:Connect(function(payload)
      if type(payload) ~= "table" then return end
      if type(payload.CMD_PREFIX) == "string" then Config.CMD_PREFIX = payload.CMD_PREFIX end
      if type(payload.LOG_CHAT) == "boolean" then Config.LOG_CHAT = payload.LOG_CHAT end
      if type(payload.LOG_LOCAL) == "boolean" then Config.LOG_LOCAL = payload.LOG_LOCAL end
      if type(payload.CLIENT_SCAN_INTERVAL) == "number" then
        Config.CLIENT_SCAN_INTERVAL = payload.CLIENT_SCAN_INTERVAL
      end
      if type(payload.ANTI_TAMPER) == "boolean" then Config.ANTI_TAMPER = payload.ANTI_TAMPER end
    end)
  end

  -- ── LOGS ─────────────────────────────────────────────────────────────
  Kynx.Logs = {}
  function Kynx.Logs:hookChat()
    if not Config.LOG_CHAT then return end
    LocalPlayer.Chatted:Connect(function(msg)
      if msg:lower():sub(1, #Config.CMD_PREFIX) == Config.CMD_PREFIX:lower() then return end
      Kynx.API:createLog("chat", LocalPlayer.Name, msg)
      Kynx.Automations:fire("CHAT_MESSAGE", {message = msg})
    end)
  end
  function Kynx.Logs:init()
    self:hookChat()
    LocalPlayer.CharacterAdded:Connect(function(character)
      Kynx.API:createLog("action", LocalPlayer.Name, "Character spawned")
      local humanoid = character:WaitForChild("Humanoid", 5)
      if humanoid then
        humanoid.Died:Connect(function()
          Kynx.Automations:fire("PLAYER_DEATH", {})
        end)
      end
    end)
    print("[KYNX/LOGS] Client logging initialised")
  end

  -- ── TELEMETRY ────────────────────────────────────────────────────────
  Kynx.Telemetry = { _lastHeartbeat = os.clock(), _frameCount = 0, _started = false }
  function Kynx.Telemetry:collectMetrics()
    local now = os.clock()
    local elapsed = now - self._lastHeartbeat
    local fps = 0
    if elapsed > 0 then fps = math.floor(self._frameCount / elapsed) end
    self._lastHeartbeat = now
    self._frameCount = 0
    local ping = 0
    local ok, p = pcall(function()
      return math.floor(Stats.Network.ServerStatsItem["Data Ping"]:GetValue())
    end)
    if ok then ping = p end
    return {
      players = #Players:GetPlayers(), ping = ping, fps = fps,
      flagStatus = Kynx.Threats:getServerFlagStatus(),
      status = "online", executor = self:detectExecutor(),
    }
  end
  function Kynx.Telemetry:detectExecutor()
    local detected = Kynx.Threats:scanClient()
    if #detected == 0 then return "N/A" end
    return table.concat(detected, ", ")
  end
  function Kynx.Telemetry:start()
    if self._started then return end
    self._started = true
    RunService.Heartbeat:Connect(function() self._frameCount += 1 end)
    task.spawn(function()
      while true do
        local m = self:collectMetrics()
        if Remotes.telemetry then
          pcall(function() Remotes.telemetry:FireServer(m) end)
        end
        if Config.LOG_LOCAL then
          print(string.format("[KYNX/TELEMETRY] FPS:%d Ping:%d Players:%d Status:%s Exec:%s",
            m.fps, m.ping, m.players, m.flagStatus, m.executor))
        end
        task.wait(Config.HEARTBEAT_INTERVAL)
      end
    end)
    print("[KYNX/TELEMETRY] Client telemetry started")
  end

  -- ── AUTOMATIONS ──────────────────────────────────────────────────────
  Kynx.Automations = { _rules = {}, _lastFetch = 0, CACHE_TTL = 60, _rulesVersion = 0 }

  if Remotes.automations then
    Remotes.automations.OnClientEvent:Connect(function(payload)
      if type(payload) ~= "table" then return end
      if payload.version and payload.version >= Kynx.Automations._rulesVersion then
        Kynx.Automations._rules = payload.rules or {}
        Kynx.Automations._rulesVersion = payload.version
        print(string.format("[KYNX/AUTO] Received %d rule(s) (v%d)",
          #Kynx.Automations._rules, payload.version))
      end
    end)
  else
    warn("[KYNX/AUTO] No KynxAutomations RemoteEvent — client rules disabled.")
  end

  function Kynx.Automations:refreshRules() self._lastFetch = os.time() end

  function Kynx.Automations:evalCondition(condition, ctx)
    if condition == "" or condition == "true" or condition == nil then return true end
    local field, op, value = condition:match("^%s*([%w_]+)%s*([=!<>]+)%s*([%w_%.%-]+)%s*$")
    if not field then
      warn("[KYNX/AUTO] Could not parse condition:", condition)
      return false
    end
    local actual = ctx[field]
    if actual == nil then return false end
    local numValue, numActual = tonumber(value), tonumber(actual)
    if numValue and numActual then
      if op == ">=" then return numActual >= numValue end
      if op == "<=" then return numActual <= numValue end
      if op == ">"  then return numActual >  numValue end
      if op == "<"  then return numActual <  numValue end
      if op == "==" then return numActual == numValue end
      if op == "!=" then return numActual ~= numValue end
    else
      local strActual = tostring(actual)
      if op == "==" then return strActual == value end
      if op == "!=" then return strActual ~= value end
    end
    return false
  end

  function Kynx.Automations:executeAction(rule, ctx)
    local action = rule.action or ""
    if action == "LOG_EVENT" then
      Kynx.API:createLog("action", LocalPlayer.Name, "Auto: " .. (rule.name or "unnamed"))
    elseif action == "SEND_MESSAGE" then
      pcall(function()
        game:GetService("StarterGui"):SetCore("ChatMakeSystemMessage", {
          Text = "[KYNX] " .. (rule.message or rule.name or ""),
          Color = Color3.fromRGB(255, 50, 50),
        })
      end)
    elseif action == "EXECUTE_SCRIPT" then
      warn("[KYNX/AUTO] Rule '" .. tostring(rule.name) .. "' requests EXECUTE_SCRIPT — unsupported, skipping.")
    end
  end

  function Kynx.Automations:fire(trigger, extraCtx)
    self:refreshRules()
    local ctx = extraCtx or {}
    ctx.playerId = LocalPlayer.UserId
    ctx.playerName = LocalPlayer.Name
    for _, rule in ipairs(self._rules) do
      if rule.trigger == trigger and rule.enabled then
        if self:evalCondition(rule.condition or "true", ctx) then
          self:executeAction(rule, ctx)
        end
      end
    end
  end

  -- ── ANTI-TAMPER ──────────────────────────────────────────────────────
  Kynx.AntiTamper = {}
  function Kynx.AntiTamper:checkIntegrity()
    if not Config.ANTI_TAMPER then return end
    local ok = type(Kynx) == "table"
      and type(Kynx.Init) == "function"
      and Kynx._version == "2.4.1"
      and type(Kynx.Threats) == "table"
      and type(Kynx.Threats.scanClient) == "function"
      and type(Kynx.Automations) == "table"
      and type(Kynx.Automations.fire) == "function"
      and getmetatable(Kynx) == nil
    if not ok then
      warn("[KYNX/ANTI-TAMPER] Integrity check failed!")
    end
  end

  -- ── INIT ─────────────────────────────────────────────────────────────
  function Kynx.Init()
    print(string.format("[KYNX CLIENT] v%s starting...", Kynx._version))

    local okT, errT = pcall(function() Kynx.Threats:init() end)
    if not okT then warn("[KYNX] Threats init failed:", errT) end

    local okL, errL = pcall(function() Kynx.Logs:init() end)
    if not okL then warn("[KYNX] Logs init failed:", errL) end

    local okTel, errTel = pcall(function() Kynx.Telemetry:start() end)
    if not okTel then warn("[KYNX] Telemetry init failed:", errTel) end

    Players.PlayerAdded:Connect(function(p)
      Kynx.Automations:fire("PLAYER_JOIN", {targetId = p.UserId, targetName = p.Name})
    end)
    Players.PlayerRemoving:Connect(function(p)
      Kynx.Automations:fire("PLAYER_LEAVE", {targetId = p.UserId, targetName = p.Name})
    end)

    task.spawn(function()
      local waited = 0
      while not Kynx.Threats._ready and waited < 10 do
        task.wait(0.25); waited += 0.25
      end
      Kynx.Automations:fire("CLIENT_INIT")
    end)

    task.spawn(function()
      while true do
        task.wait(30)
        Kynx.AntiTamper:checkIntegrity()
      end
    end)

    print("[KYNX CLIENT] Initialised ✓")
  end

  task.spawn(function()
    local ok, err = pcall(Kynx.Init, Kynx)
    if not ok then warn("[KYNX CLIENT] Init failed:", err) end
  end)

else
  warn("[KYNX] Unknown run context — neither server nor client. Module idle.")
end

return Kynx
