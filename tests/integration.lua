-- Daemon integration test. `tests/integration.sh` starts an isolated daemon and
-- runs this file with `nvim --headless -u tests/minimal_init.lua -l ...`.
local socket = assert(vim.env.EIX_TEST_SOCKET, "EIX_TEST_SOCKET is not set")
local work = vim.env.EIX_TEST_WORK or vim.fn.getcwd()

local client = require("eix.client")
local config = require("eix.config")
local launch = require("eix.launch")

-- `true` stands in for a terminal emulator: it is spawned with the same argv
-- shape and exits immediately, so no window is needed in headless runs.
config.setup({
  socket = socket,
  auto_start = false,
  auto_reconnect = false,
  auto_open = false,
  terminal = { cmd = { "true" } },
})

local function wait_until(label, fn, timeout)
  assert(vim.wait(timeout or 5000, fn, 10), "timeout: " .. label)
end

local connected = false
local connect_err = nil
client.connect(function(err)
  connected = true
  connect_err = err
end)
wait_until("connect", function()
  return connected
end)
assert(not connect_err, connect_err)

local function request(method, params)
  local done, err, result = false, nil, nil
  client.request(method, params, function(request_err, value)
    done, err, result = true, request_err, value
  end)
  wait_until(method, function()
    return done
  end)
  if err then
    error(method .. ": " .. err)
  end
  return result
end

local hello = client.hello()
assert(hello and hello.protocol, "no hello response")
print(("hello · version %s · protocol %s · model %s"):format(hello.version, hello.protocol, hello.model))

local listed = request("session.list", {})
assert(type(listed.sessions) == "table")
print("session.list · " .. #listed.sessions .. " session(s)")

local created = request("session.create", { name = "eix-nvim-integration", cwd = work })
local target = assert(created.session, "session.create returned no session")
print("session.create · " .. target.id)

local argv = assert(launch.argv(target), "launch.argv returned nil")
local script = argv[#argv]
assert(script:find("tui", 1, true), "TUI command is missing `tui`")
assert(script:find(target.id, 1, true), "TUI command is missing the session id")
assert(script:find(work, 1, true), "TUI command is missing the session directory")

local opened, open_err = false, nil
launch.open({ session = target }, function(err)
  opened, open_err = true, err
end)
wait_until("launch.open", function()
  return opened
end)
assert(not open_err, open_err)
assert(launch.launched[target.id], "launch.open did not remember the session")
print("launch.open · " .. table.concat(argv, " "))

assert(client.is_connected(), "client reports disconnected")
local active = client.active_session()
assert(active and active.id == target.id, "client reports the wrong session")

request("session.delete", { session_id = target.id })
client.close()
print("INTEGRATION_OK")
