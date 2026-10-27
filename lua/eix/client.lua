---Daemon connection and typed request helpers.
local config = require("eix.config")
local discovery = require("eix.discovery")
local events = require("eix.events")
local Rpc = require("eix.rpc")

local M = {}

M.state = {
  rpc = nil,
  connecting = false,
  connected = false,
  waiters = {},
  hello = nil,
  endpoint = nil,
  sessions = {},
  active_session_id = nil,
  manual_close = false,
  reconnect_attempt = 0,
  reconnect_timer = nil,
}

---@param cb fun(err?: string, client?: table)
local function flush(err, client)
  local waiters = M.state.waiters
  M.state.waiters = {}
  for _, waiter in ipairs(waiters) do
    local ok, handler_err = pcall(waiter, err, client)
    if not ok then
      vim.schedule(function()
        vim.notify("eix: connection callback error: " .. tostring(handler_err), vim.log.levels.ERROR)
      end)
    end
  end
end

---@return table[] sessions
function M.sessions()
  local list = {}
  for _, session in pairs(M.state.sessions) do
    table.insert(list, session)
  end
  return list
end

---@param id? string
---@return table?
function M.session(id)
  if not id then
    return nil
  end
  return M.state.sessions[id]
end

---@param path string
---@return string
local function normalize(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

---@param a? string
---@param b? string
---@return boolean
function M.same_path(a, b)
  if not a or not b then
    return false
  end
  return normalize(a) == normalize(b)
end

---@return table?
function M.active_session()
  return M.session(M.state.active_session_id)
end

---@param session table|string
function M.set_active_session(session)
  if type(session) == "string" then
    session = M.session(session)
  end
  if not session then
    return
  end
  M.state.active_session_id = session.id
  M.state.sessions[session.id] = session
  events.set_session(session)
  events.emit("session:active", session)
end

---@return table?
function M.hello()
  return M.state.hello
end

---@param message table
local function notification(message)
  local method = message.method
  local params = message.params or {}

  if method == "session.updated" then
    if params.id then
      M.state.sessions[params.id] = params
      if M.state.active_session_id == params.id then
        if params.archived then
          -- An archived session is hidden from pickers; stop resolving it for
          -- new prompts and clear the statusline until another session is used.
          M.state.active_session_id = nil
          events.set_session(nil)
        else
          events.set_session(params)
        end
      end
    end
  elseif method == "session.deleted" then
    local id = params.session_id or params.id
    if id then
      M.state.sessions[id] = nil
      if M.state.active_session_id == id then
        M.state.active_session_id = nil
        events.set_session(nil)
      end
    end
  elseif method == "session.attention" then
    local session = M.state.sessions[params.session_id]
    if session then
      session.status = params.status or session.status
      if M.state.active_session_id == session.id then
        events.set_status(session.status)
      end
    end
  elseif method == "turn.started" then
    local session = M.state.sessions[params.session_id]
    if session then
      session.status = "running"
      if M.state.active_session_id == session.id then
        events.set_status("running")
      end
    end
  elseif method == "turn.completed" then
    local session = M.state.sessions[params.session_id]
    if session then
      session.status = params.error and params.error ~= vim.NIL and "error" or "idle"
      if M.state.active_session_id == session.id then
        events.set_status(session.status)
      end
    end
  elseif method == "tool.approval_required" or method == "patch.proposed" then
    local session = M.state.sessions[params.session_id]
    if session then
      session.status = "awaiting_approval"
      if M.state.active_session_id == session.id then
        events.set_status("awaiting_approval")
      end
    end
  elseif method == "input.required" then
    local session = M.state.sessions[params.session_id]
    if session then
      session.status = "awaiting_input"
      if M.state.active_session_id == session.id then
        events.set_status("awaiting_input")
      end
    end
  elseif method == "stream.lagged" then
    events.emit("lagged", params)
  end

  events.dispatch(message)
end

---@param reason? string
local function schedule_reconnect(reason)
  if M.state.manual_close then
    return
  end
  local opts = config.opts
  if not opts.auto_reconnect then
    return
  end
  -- A failed connect can be reported both by the transport and by the
  -- handshake callback; keep a single pending reconnect.
  if M.state.reconnect_timer then
    return
  end
  M.state.reconnect_attempt = M.state.reconnect_attempt + 1
  local delay = math.min(30000, 500 * 2 ^ math.min(M.state.reconnect_attempt - 1, 6))
  events.emit("disconnected", reason)
  if M.state.reconnect_timer then
    pcall(function()
      M.state.reconnect_timer:stop()
      M.state.reconnect_timer:close()
    end)
  end
  local timer = (vim.uv or vim.loop).new_timer()
  if not timer then
    return
  end
  M.state.reconnect_timer = timer
  timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      timer:stop()
      timer:close()
      if M.state.reconnect_timer == timer then
        M.state.reconnect_timer = nil
      end
      if M.state.manual_close then
        return
      end
      M.connect(function(err)
        if not err then
          M.state.reconnect_attempt = 0
        end
      end)
    end)
  )
end

---Connect and complete the `hello` handshake.
---@param cb? fun(err?: string, client?: table)
function M.connect(cb)
  cb = cb or function() end
  if M.state.connected and M.state.rpc then
    cb(nil, M)
    return
  end
  table.insert(M.state.waiters, cb)
  if M.state.connecting then
    return
  end
  if M.state.manual_close then
    M.state.manual_close = false
  end
  M.state.connecting = true

  discovery.resolve(config.opts, function(resolve_err, endpoint)
    if resolve_err then
      M.state.connecting = false
      events.state.connected = false
      flush(resolve_err)
      schedule_reconnect(resolve_err)
      return
    end

    M.state.endpoint = endpoint
    local rpc = Rpc.new(endpoint, config.opts)
    M.state.rpc = rpc

    rpc:on_notification(notification)
    rpc:on_close(function(reason)
      M.state.connected = false
      M.state.connecting = false
      events.state.connected = false
      if M.state.rpc == rpc then
        M.state.rpc = nil
      end
      flush(reason or "connection closed")
      schedule_reconnect(reason)
    end)

    rpc:connect(function(connect_err)
      if connect_err then
        M.state.connecting = false
        M.state.connected = false
        events.state.connected = false
        flush(connect_err)
        schedule_reconnect(connect_err)
        return
      end

      rpc:request("hello", vim.empty_dict(), function(hello_err, hello)
        M.state.connecting = false
        if hello_err then
          flush(hello_err)
          rpc:close(hello_err)
          return
        end

        M.state.hello = hello or {}
        M.state.connected = true
        events.state.connected = true
        events.state.endpoint = endpoint
        events.state.protocol = M.state.hello.protocol
        events.state.version = M.state.hello.version
        events.state.model = M.state.hello.model
        events.emit("connected", M.state.hello)

        -- Subscribe to every session so approval and input requests from other
        -- sessions still reach notifications and the statusline.
        rpc:request("session.subscribe", vim.empty_dict(), function() end)
        flush(nil, M)
      end)
    end)
  end)
end

---@param cb fun(client: table)
function M.get(cb)
  M.connect(function(err, client)
    if err then
      vim.schedule(function()
        vim.notify("eix: " .. err, vim.log.levels.ERROR)
      end)
      return
    end
    cb(client)
  end)
end

---Make a request, connecting first when necessary.
---@param method string
---@param params? any
---@param cb? fun(err?: string, result?: any)
function M.request(method, params, cb)
  M.connect(function(connect_err)
    if connect_err then
      if cb then
        cb(connect_err)
      end
      return
    end
    if not M.state.rpc or not M.state.connected then
      if cb then
        cb("not connected to eix daemon")
      end
      return
    end
    M.state.rpc:request(method, params, cb)
  end)
end

---@param cb? fun(err?: string)
function M.close(cb)
  M.state.manual_close = true
  M.state.connected = false
  M.state.connecting = false
  events.state.connected = false
  if M.state.reconnect_timer then
    pcall(function()
      M.state.reconnect_timer:stop()
      M.state.reconnect_timer:close()
    end)
    M.state.reconnect_timer = nil
  end
  local rpc = M.state.rpc
  M.state.rpc = nil
  if rpc then
    rpc:close("closed by user")
  end
  events.emit("disconnected", "closed by user")
  if cb then
    cb(nil)
  end
end

---@param opts? { force_new?: boolean, cwd?: string }
---@param cb fun(err?: string, session?: table)
function M.resolve_session(opts, cb)
  if type(opts) == "function" then
    cb = opts
    opts = {}
  end
  opts = opts or {}
  local cwd = normalize(opts.cwd or vim.fn.getcwd())

  if not opts.force_new and M.state.active_session_id then
    local active = M.active_session()
    if active and not active.archived and M.same_path(active.cwd, cwd) then
      cb(nil, active)
      return
    end
  end
  M.request("session.list", { include_archived = false }, function(err, result)
    if err then
      cb(err)
      return
    end
    local sessions = result and result.sessions or {}
    for _, session in ipairs(sessions) do
      M.state.sessions[session.id] = session
    end

    if not opts.force_new then
      local best = nil
      for _, session in ipairs(sessions) do
        if
          session.origin ~= "agent"
          and not session.archived
          and M.same_path(session.cwd, cwd)
          and (not best or (session.updated_at or 0) > (best.updated_at or 0))
        then
          best = session
        end
      end
      if best then
        M.set_active_session(best)
        cb(nil, best)
        return
      end
    end

    local name = vim.fn.fnamemodify(cwd, ":t")
    if name == "" or name == "." then
      name = "nvim"
    end
    M.request("session.create", { name = name, cwd = cwd }, function(create_err, created)
      if create_err then
        cb(create_err)
        return
      end
      local session = created and created.session
      if session then
        M.state.sessions[session.id] = session
        M.set_active_session(session)
      end
      cb(nil, session)
    end)
  end)
end

---Create a session unconditionally.
---@param opts { name?: string, cwd?: string, model?: string, worktree?: boolean, mode?: string, agent?: string }
---@param cb fun(err?: string, session?: table)
function M.create_session(opts, cb)
  opts = opts or {}
  opts.cwd = opts.cwd or vim.fn.getcwd()
  if not opts.name or opts.name == "" then
    opts.name = vim.fn.fnamemodify(opts.cwd, ":t")
  end
  M.request("session.create", opts, function(err, result)
    if err then
      cb(err)
      return
    end
    local session = result and result.session
    if session then
      M.state.sessions[session.id] = session
      M.set_active_session(session)
      events.emit("session:created", session)
    end
    cb(nil, session)
  end)
end

---Sorted sessions for pickers: attention first, then most recently used.
---@param opts? { archived?: boolean }
---@return table[]
function M.sorted_sessions(opts)
  opts = opts or {}
  local list = {}
  for _, session in pairs(M.state.sessions) do
    if session.origin ~= "agent" and (opts.archived or not session.archived) then
      table.insert(list, session)
    end
  end
  table.sort(list, function(a, b)
    local a_attention = a.status == "awaiting_approval" or a.status == "awaiting_input" or a.status == "error"
    local b_attention = b.status == "awaiting_approval" or b.status == "awaiting_input" or b.status == "error"
    if a_attention ~= b_attention then
      return a_attention
    end
    return (a.updated_at or 0) > (b.updated_at or 0)
  end)
  return list
end

---@return boolean
function M.is_connected()
  return M.state.connected
end

return M
