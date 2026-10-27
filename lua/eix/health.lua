---`:checkhealth eix`
local M = {}

---@param cmd string|string[]
---@return string
local function command_name(cmd)
  if type(cmd) == "table" then
    return tostring(cmd[1] or "")
  end
  return tostring(cmd or "eix")
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

function M.check()
  vim.health.start("eix.nvim")

  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.11 or newer is required")
  end

  local config = require("eix.config")
  local discovery = require("eix.discovery")
  local opts = config.opts

  local binary = command_name(opts.eix_cmd)
  if vim.fn.executable(binary) == 1 then
    vim.health.ok("eix executable: " .. binary)
  else
    vim.health.error(
      "eix executable not found: " .. binary,
      { "Install eix or set `eix_cmd` in `require('eix').setup()`." }
    )
  end

  if opts.endpoint then
    vim.health.info("configured endpoint: " .. tostring(opts.endpoint))
  elseif opts.socket then
    vim.health.info("configured socket: " .. tostring(opts.socket))
  else
    vim.health.info("default socket: " .. discovery.default_socket())
  end

  local prefix = require("eix.launch").prefix(vim.fn.getcwd())
  if prefix then
    vim.health.ok("terminal: " .. table.concat(prefix, " "))
  else
    vim.health.warn("no terminal emulator found", { "Set `terminal.cmd`, e.g. `{ cmd = { 'ghostty', '-e' } }`." })
  end

  if vim.env.TMUX and vim.env.TMUX ~= "" and vim.fn.executable("tmux") == 1 then
    vim.health.ok("`:Eix` closes the TUI window with tmux")
  elseif vim.fn.executable("wmctrl") == 1 then
    vim.health.ok("`:Eix` closes the TUI window with wmctrl")
  else
    vim.health.warn("wmctrl not found; `:Eix` always opens a new window")
  end

  if vim.fn.executable(binary) ~= 1 then
    return
  end

  local cmd = type(opts.eix_cmd) == "table" and vim.deepcopy(opts.eix_cmd) or { binary }
  vim.list_extend(cmd, { "status", "--json" })

  local result = vim.system(cmd, { text = true, env = status_env(opts) }):wait(5000)
  if result.code ~= 0 then
    local message = vim.trim(result.stderr or "")
    if message == "" then
      message = "exit code " .. tostring(result.code)
    end
    vim.health.error("`eix status --json` failed: " .. message, { "Start the daemon with `eix status --json`." })
    return
  end

  local ok, status = pcall(vim.json.decode, result.stdout or "")
  if not ok or type(status) ~= "table" then
    vim.health.error("cannot parse `eix status --json` output")
    return
  end
  vim.health.ok("daemon reachable")

  local daemon = status.daemon or {}
  if daemon.endpoint then
    vim.health.info("endpoint: " .. tostring(daemon.endpoint))
  end
  if daemon.pid then
    vim.health.info("pid: " .. tostring(daemon.pid))
  end
  if daemon.version then
    vim.health.info("version: " .. tostring(daemon.version))
  end
  if daemon.protocol then
    vim.health.info("protocol: " .. tostring(daemon.protocol))
  end

  local endpoint = daemon.endpoint
  if type(endpoint) ~= "string" or endpoint == "" then
    vim.health.error("`eix status --json` did not report a daemon endpoint")
    return
  end

  local Rpc = require("eix.rpc")
  local rpc = Rpc.new(endpoint, opts)
  local finished = false
  local hello
  local connect_error
  rpc:connect(function(err)
    if err then
      connect_error = err
      finished = true
      return
    end
    rpc:request("hello", vim.empty_dict(), function(request_err, value)
      if request_err then
        connect_error = request_err
      else
        hello = value
      end
      finished = true
    end)
  end)
  vim.wait(3000, function()
    return finished
  end, 20)
  pcall(rpc.close, rpc)

  if connect_error then
    vim.health.error("RPC handshake failed: " .. tostring(connect_error))
  elseif not hello then
    vim.health.warn("RPC handshake timed out")
  else
    vim.health.ok(
      ("RPC handshake: version %s · protocol %s · model %s"):format(
        tostring(hello.version or "?"),
        tostring(hello.protocol or "?"),
        tostring(hello.model or "?")
      )
    )
  end

  local client = require("eix.client")
  if client.is_connected() then
    vim.health.ok("plugin is connected")
  else
    vim.health.info("plugin is not connected yet (it connects on first use)")
  end
end

return M
