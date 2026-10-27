---Find (and optionally start) the eix daemon.
local uv = vim.uv or vim.loop

local M = {}

---@param path string
---@return boolean
local function is_file(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

---Best-effort copy of eix's own default socket resolution.
---@return string
function M.default_socket()
  if (vim.env.EIX_SOCKET or "") ~= "" then
    return vim.env.EIX_SOCKET
  end
  local runtime = vim.env.XDG_RUNTIME_DIR
  if runtime and runtime ~= "" then
    return runtime .. "/eix.sock"
  end
  local home = uv.os_homedir() or vim.env.HOME or ""
  local sysname = (uv.os_uname() or {}).sysname or ""
  if sysname == "Darwin" then
    return home .. "/Library/Caches/eix/eix.sock"
  end
  if home ~= "" then
    return home .. "/.cache/eix/eix.sock"
  end
  return "/tmp/eix-" .. (vim.env.USER or "user") .. ".sock"
end

---@param opts eix.Opts
---@return string[]
local function status_command(opts)
  local cmd = opts.eix_cmd or "eix"
  if type(cmd) == "table" then
    local out = vim.deepcopy(cmd)
    vim.list_extend(out, { "status", "--json" })
    return out
  end
  return { cmd, "status", "--json" }
end

---@param opts eix.Opts
---@return table<string, string>
local function status_env(opts)
  local env = vim.fn.environ()
  local socket = opts.socket
  if not socket and opts.endpoint and not tostring(opts.endpoint):match("^tcp://") then
    socket = tostring(opts.endpoint):gsub("^unix://", "")
  end
  if socket then
    env.EIX_SOCKET = socket
  end
  return env
end

---@param cmd string[]
---@param env table<string, string>
---@param cb fun(err?: string, endpoint?: string)
local function run_status(cmd, env, cb)
  if vim.fn.executable(cmd[1]) ~= 1 then
    cb("`" .. cmd[1] .. "` not found in PATH; install eix or set `eix_cmd`")
    return
  end

  local stdout, stderr = {}, {}
  local ok, job = pcall(vim.fn.jobstart, cmd, {
    env = env,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        stdout = data
      end
    end,
    on_stderr = function(_, data)
      if data then
        stderr = data
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          local message = table.concat(stderr, "\n")
          if message == "" then
            message = "`eix status --json` exited with code " .. tostring(code)
          end
          cb("cannot reach eix daemon: " .. message)
          return
        end
        local out = table.concat(stdout, "\n")
        local decoded_ok, decoded = pcall(vim.json.decode, out)
        if not decoded_ok or type(decoded) ~= "table" then
          cb("cannot parse `eix status --json` output: " .. out)
          return
        end
        local endpoint = decoded.daemon and decoded.daemon.endpoint
        if type(endpoint) ~= "string" or endpoint == "" then
          cb("`eix status --json` did not report a daemon endpoint")
          return
        end
        cb(nil, endpoint)
      end)
    end,
  })
  if not ok or job <= 0 then
    cb("failed to run `" .. table.concat(cmd, " ") .. "`")
  end
end

---Resolve the daemon endpoint.
---
---Order: explicit `endpoint`/`socket` options, `EIX_TCP`, `EIX_SOCKET`, an
---existing default socket, then `eix status --json` (which starts the daemon
---when it is not running).
---@param opts eix.Opts
---@param cb fun(err?: string, endpoint?: string)
function M.resolve(opts, cb)
  if opts.endpoint and tostring(opts.endpoint):match("^tcp://") then
    cb(nil, opts.endpoint)
    return
  end
  if opts.socket and opts.socket ~= "" then
    if is_file(opts.socket) or not opts.auto_start then
      cb(nil, opts.socket)
      return
    end
    run_status(status_command(opts), status_env(opts), cb)
    return
  end
  if opts.endpoint and opts.endpoint ~= "" then
    if is_file(opts.endpoint) or not opts.auto_start then
      cb(nil, opts.endpoint)
      return
    end
    run_status(status_command(opts), status_env(opts), cb)
    return
  end

  local tcp = vim.env.EIX_TCP
  if tcp and tcp ~= "" then
    cb(nil, "tcp://" .. tcp)
    return
  end

  local env_socket = vim.env.EIX_SOCKET
  if env_socket and env_socket ~= "" and is_file(env_socket) then
    cb(nil, env_socket)
    return
  end

  local default = M.default_socket()
  if is_file(default) then
    cb(nil, default)
    return
  end

  if not opts.auto_start then
    cb("no eix daemon found at " .. default .. " (auto_start is disabled)")
    return
  end
  run_status(status_command(opts), status_env(opts), cb)
end

return M
