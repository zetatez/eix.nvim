---Newline-delimited JSON-RPC client for eixd.
---
---The daemon speaks one JSON object per line over a Unix socket (or TCP with a
---token). This module is deliberately UI-free: it owns the socket, request ids,
---reconnection, and notification fan-out.
local uv = vim.uv or vim.loop

local M = {}

---@class eix.rpc.Endpoint
---@field kind "unix"|"tcp"
---@field path? string
---@field addr? string
---@field token? string

---@param endpoint string|eix.rpc.Endpoint
---@param token? string
---@return eix.rpc.Endpoint
function M.endpoint(endpoint, token)
  if type(endpoint) == "table" then
    return endpoint
  end
  token = token or vim.env.EIX_TCP_TOKEN
  local tcp = endpoint:match("^tcp://(.+)$")
  if tcp then
    return { kind = "tcp", addr = tcp, token = token }
  end
  local path = endpoint:match("^unix://(.+)$") or endpoint
  return { kind = "unix", path = path, token = token }
end

---@class eix.rpc.Client
---@field endpoint eix.rpc.Endpoint
---@field opts table
---@field next_id integer
---@field pending table<integer, { cb: fun(err?: string, result?: any), timer?: uv.uv_timer_t }>
---@field queue string[]
---@field buffer string
---@field connected boolean
---@field closed boolean
---@field handle? uv.uv_pipe_t|uv.uv_tcp_t
---@field notification_handlers fun(message: table)[]
---@field close_handlers fun(err?: string)[]
local Client = {}
Client.__index = Client

---@param endpoint string|eix.rpc.Endpoint
---@param opts? table
---@return eix.rpc.Client
function M.new(endpoint, opts)
  opts = opts or {}
  return setmetatable({
    endpoint = M.endpoint(endpoint, opts.token),
    opts = opts,
    next_id = 0,
    pending = {},
    queue = {},
    buffer = "",
    connected = false,
    closed = false,
    notification_handlers = {},
    close_handlers = {},
  }, Client)
end

---Register a notification handler.
---@param fn fun(message: table)
function Client:on_notification(fn)
  table.insert(self.notification_handlers, fn)
end

---Register a close handler.
---@param fn fun(err?: string)
function Client:on_close(fn)
  table.insert(self.close_handlers, fn)
end

---@return string
function Client:address()
  if self.endpoint.kind == "tcp" then
    return "tcp://" .. (self.endpoint.addr or "")
  end
  return self.endpoint.path or ""
end

---@param method string
---@param params? any
---@param cb? fun(err?: string, result?: any)
---@return integer
function Client:request(method, params, cb)
  self.next_id = self.next_id + 1
  local id = self.next_id
  local entry = { cb = cb or function() end }
  local timeout = tonumber(self.opts.request_timeout or 0) or 0
  if timeout > 0 and not self.closed then
    local timer = uv.new_timer()
    if timer then
      timer:start(
        timeout,
        0,
        vim.schedule_wrap(function()
          if not self.pending[id] then
            return
          end
          self.pending[id] = nil
          timer:stop()
          timer:close()
          entry.cb(("request %s timed out after %dms"):format(method, timeout))
        end)
      )
      entry.timer = timer
    end
  end
  self.pending[id] = entry

  local line = vim.json.encode({
    id = id,
    method = method,
    params = params == nil and vim.empty_dict() or params,
  }) .. "\n"

  if self.connected then
    self:_write(line)
  else
    table.insert(self.queue, line)
  end
  return id
end

---@param line string
function Client:_write(line)
  if not self.handle or self.closed then
    return
  end
  local ok, err = self.handle:write(line, function(write_err)
    if write_err then
      self:close("write failed: " .. tostring(write_err))
    end
  end)
  if not ok then
    self:close("write failed: " .. tostring(err))
  end
end

---@param chunk string
function Client:_read(chunk)
  self.buffer = self.buffer .. chunk
  while true do
    local newline = self.buffer:find("\n", 1, true)
    if not newline then
      break
    end
    local line = self.buffer:sub(1, newline - 1)
    self.buffer = self.buffer:sub(newline + 1)
    if line ~= "" then
      -- Run handlers on the main loop. They touch buffers and windows, and
      -- ordering is preserved by the scheduler.
      vim.schedule(function()
        self:_dispatch(line)
      end)
    end
  end
end

---@param line string
function Client:_dispatch(line)
  local ok, message = pcall(vim.json.decode, line)
  if not ok or type(message) ~= "table" then
    return
  end

  if message.id == 0 and self._auth_cb then
    local cb = self._auth_cb
    self._auth_cb = nil
    if message.error then
      cb("eix authentication failed: " .. tostring(message.error.message or ""))
    else
      cb(nil)
    end
    return
  end

  if message.id ~= nil then
    local entry = self.pending[message.id]
    if not entry then
      return
    end
    self.pending[message.id] = nil
    if entry.timer then
      entry.timer:stop()
      entry.timer:close()
    end
    local err = message.error
    if err then
      local code = type(err) == "table" and (err.code or "error") or "error"
      local text = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
      entry.cb(tostring(code) .. ": " .. tostring(text), nil)
    else
      entry.cb(nil, message.result)
    end
    return
  end

  for _, handler in ipairs(self.notification_handlers) do
    local handler_ok, handler_err = pcall(handler, message)
    if not handler_ok then
      vim.schedule(function()
        vim.notify("eix: notification handler error: " .. tostring(handler_err), vim.log.levels.ERROR)
      end)
    end
  end
end

---Open the transport and complete the optional TCP handshake.
---@param cb fun(err?: string)
function Client:connect(cb)
  self.closed = false
  local endpoint = self.endpoint

  local function failed(err)
    self:close(err)
    cb(err)
  end

  if endpoint.kind == "tcp" then
    local host, port = (endpoint.addr or ""):match("^(.*):(%d+)$")
    if not host or not port then
      failed("invalid TCP endpoint: " .. tostring(endpoint.addr))
      return
    end
    local tcp = uv.new_tcp()
    if not tcp then
      failed("cannot create TCP handle")
      return
    end
    self.handle = tcp
    tcp:connect(host, tonumber(port), function(err)
      if err then
        failed("cannot connect to " .. endpoint.addr .. ": " .. tostring(err))
        return
      end
      self:_on_connect(cb)
    end)
    return
  end

  local path = endpoint.path
  if not path or path == "" then
    failed("no eix socket configured")
    return
  end
  local pipe = uv.new_pipe(false)
  if not pipe then
    failed("cannot create Unix socket handle")
    return
  end
  self.handle = pipe
  pipe:connect(path, function(err)
    if err then
      failed("cannot connect to " .. path .. ": " .. tostring(err))
      return
    end
    self:_on_connect(cb)
  end)
end

---@param cb fun(err?: string)
function Client:_on_connect(cb)
  if self.closed or not self.handle then
    cb("connection closed")
    return
  end
  self.handle:read_start(function(err, chunk)
    if err then
      self:close(tostring(err))
      return
    end
    if not chunk then
      self:close("daemon closed the connection")
      return
    end
    self:_read(chunk)
  end)

  local function ready()
    if self.closed then
      return
    end
    self.connected = true
    local queued = self.queue
    self.queue = {}
    for _, line in ipairs(queued) do
      self:_write(line)
    end
    cb(nil)
  end

  if self.endpoint.kind == "tcp" and self.endpoint.token and self.endpoint.token ~= "" then
    -- The first request on a TCP connection must be `auth`. Keep `connected`
    -- false so user requests stay queued until the handshake succeeds.
    self._auth_cb = function(err)
      if err then
        self:close(err)
        cb(err)
        return
      end
      ready()
    end
    self:_write(vim.json.encode({
      id = 0,
      method = "auth",
      params = { token = self.endpoint.token },
    }) .. "\n")
    return
  end

  ready()
end

---Close the client. Pending requests fail with `reason`.
---@param reason? string
function Client:close(reason)
  if self.closed then
    return
  end
  self.closed = true
  self.connected = false
  self._auth_cb = nil
  if self.handle then
    pcall(function()
      if not self.handle:is_closing() then
        self.handle:read_stop()
        self.handle:close()
      end
    end)
    self.handle = nil
  end
  for id, entry in pairs(self.pending) do
    self.pending[id] = nil
    if entry.timer then
      entry.timer:stop()
      entry.timer:close()
    end
    entry.cb(reason or "connection closed")
  end
  self.queue = {}
  for _, handler in ipairs(self.close_handlers) do
    pcall(handler, reason or "connection closed")
  end
end

return M
