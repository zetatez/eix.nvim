-- Headless unit tests: `nvim --headless -u tests/minimal_init.lua -l tests/unit.lua`
local failures = 0

---@param name string
---@param fn fun()
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("ok - " .. name)
  else
    failures = failures + 1
    print("not ok - " .. name)
    print(tostring(err))
  end
end

local function eq(actual, expected, label)
  if not vim.deep_equal(actual, expected) then
    error(
      ("%s\nexpected: %s\nactual:   %s"):format(label or "values differ", vim.inspect(expected), vim.inspect(actual))
    )
  end
end

local function contains(text, needle, label)
  if not tostring(text):find(needle, 1, true) then
    error(("%s\nmissing: %s\nin:\n%s"):format(label or "substring missing", needle, tostring(text)))
  end
end

test("config merges nested options", function()
  local config = require("eix.config")
  local opts = config.setup({ ask = { width = 0.6 }, context = { max_lines = 10 } })
  eq(opts.ask.width, 0.6)
  eq(opts.terminal.cmd, nil)
  eq(opts.terminal.prefer, nil)
  eq(opts.context.max_lines, 10)
  eq(type(opts.select.prompts["Explain this"]), "string")
  config.setup()
end)

test("config migrates chat.auto_open", function()
  local config = require("eix.config")
  local opts = config.setup({ chat = { auto_open = false } })
  eq(opts.auto_open, false)
  eq(opts.chat, nil)
  config.setup()
end)

test("workspace uses the git root of the current file", function()
  if vim.fn.executable("git") ~= 1 then
    return
  end
  local workspace = require("eix.workspace")

  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/src/nested", "p")
  root = vim.fn.resolve(root)
  local file = root .. "/src/nested/a.lua"
  vim.fn.writefile({ "return 1" }, file)
  vim.fn.system({ "git", "-C", root, "init", "-q" })
  vim.cmd.edit(vim.fn.fnameescape(file))
  eq(workspace.cwd(), vim.fs.normalize(root), "a tracked file must use the git root")

  local loose = vim.fn.tempname()
  vim.fn.mkdir(loose, "p")
  loose = vim.fn.resolve(loose)
  local loose_file = loose .. "/b.lua"
  vim.fn.writefile({ "return 2" }, loose_file)
  vim.cmd.edit(vim.fn.fnameescape(loose_file))
  eq(workspace.cwd(), vim.fs.normalize(loose), "an untracked file must use its own directory")

  vim.cmd("enew")
  eq(workspace.cwd(), vim.fn.getcwd(), "an unnamed buffer must fall back to the cwd")
end)

test("session resolve defaults to the workspace of the current file", function()
  local client = require("eix.client")
  local sessions = require("eix.session")
  local workspace = require("eix.workspace")
  local saved = client.resolve_session
  local captured
  client.resolve_session = function(opts, cb)
    captured = opts
    cb(nil, { id = "s1" })
  end

  sessions.resolve(nil, function() end)
  eq(captured and captured.cwd, workspace.cwd())

  sessions.resolve(nil, function() end, { cwd = "/tmp/explicit" })
  eq(captured and captured.cwd, "/tmp/explicit", "an explicit cwd must win")

  client.resolve_session = saved
end)

test("context expands placeholders on word boundaries", function()
  local context = require("eix.context")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local value = 1", "print(value)" })
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { 1, 2 })

  local ctx = context.new({ cwd = "/tmp/eix-unit" })
  local out = ctx:render("@this and mail@this.example and @buffers2")
  contains(out, "local value = 1")
  contains(out, "mail@this.example")
  contains(out, "@buffers2")
  ctx:clear()
end)

test("context honors line, block and explicit ranges", function()
  local context = require("eix.context")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcdef", "ghijkl" })
  vim.api.nvim_win_set_buf(0, buf)

  local line = context.new({
    cwd = "/tmp/eix-unit",
    range = { from = { 1, 0 }, to = { 2, math.huge }, kind = "line" },
  })
  local line_out = line:render("@this")
  contains(line_out, "abcdef")
  contains(line_out, "ghijkl")
  contains(line_out, "L1-L2")
  eq(line_out:find("-9223372036854775808", 1, true), nil)
  line:clear()

  local block = context.new({
    cwd = "/tmp/eix-unit",
    range = { from = { 1, 1 }, to = { 2, 3 }, kind = "block" },
  })
  local block_out = block:render("@this")
  contains(block_out, "bcd")
  contains(block_out, "hij")
  block:clear()
end)

test("resolve_session prefers the session for the cwd", function()
  local client = require("eix.client")
  local saved_request = client.request
  local saved_sessions = client.state.sessions
  local saved_active = client.state.active_session_id

  local here = vim.fn.getcwd()
  local elsewhere = vim.fn.fnamemodify(here, ":h")
  client.state.sessions = {
    stale = { id = "stale", cwd = elsewhere, status = "idle" },
    fresh = { id = "fresh", cwd = here, status = "idle" },
  }
  client.state.active_session_id = "stale"
  client.request = function(method, _, cb)
    if method == "session.list" then
      cb(nil, { sessions = { { id = "stale", cwd = elsewhere }, { id = "fresh", cwd = here } } })
      return
    end
    cb("unexpected request: " .. method)
  end

  local resolved
  client.resolve_session({}, function(err, found)
    eq(err, nil)
    resolved = found
  end)

  client.request = saved_request
  client.state.sessions = saved_sessions
  client.state.active_session_id = saved_active
  eq(resolved and resolved.id, "fresh")
end)

test("operator range follows whole-line motions", function()
  local eix = require("eix")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "", "four" })
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  local captured
  _G.eix_test_operator = function(kind)
    captured = eix.operator_range(kind)
  end
  vim.o.operatorfunc = "v:lua.eix_test_operator"
  vim.cmd("normal g@ip")
  eq(captured and captured.kind, "line")
  eq(captured.from[1], 1)
  eq(captured.to[1], 3)
  vim.o.operatorfunc = ""
  _G.eix_test_operator = nil
end)

test("turn events only update the active session status", function()
  local events = require("eix.events")
  events.state.session = { id = "s1", status = "idle", mode = "build" }
  events.state.status = "idle"
  events.state.turn_id = nil

  events.dispatch({ method = "turn.started", params = { session_id = "s2", turn_id = "t2" } })
  eq(events.state.status, "idle", "a background turn must not mark the active session running")
  eq(events.state.turn_id, nil)

  events.dispatch({ method = "turn.started", params = { session_id = "s1", turn_id = "t1" } })
  eq(events.state.status, "running")
  eq(events.state.turn_id, "t1")

  events.dispatch({ method = "turn.completed", params = { session_id = "s2", cancelled = false } })
  eq(events.state.status, "running", "a background turn must not finish the active session")

  events.dispatch({ method = "turn.completed", params = { session_id = "s1", cancelled = false } })
  eq(events.state.status, "idle")
  eq(events.state.turn_id, nil)

  events.state.session = nil
  events.state.status = "idle"
end)

test("context byte cap does not split UTF-8 characters", function()
  local config = require("eix.config")
  local context = require("eix.context")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "ééé" })
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  -- 22 bytes lands one byte into the first two-byte character.
  config.setup({ context = { max_lines = 0, max_bytes = 22 } })
  local ctx = context.new({ cwd = "/tmp/eix-unit" })
  local out = ctx:render("@this")
  ctx:clear()
  config.setup()
  eq(out, "buffer:L1:C1\n```text\n\n… (truncated)")
end)

test("launch command points at the resolved daemon", function()
  local config = require("eix.config")
  local client = require("eix.client")
  local launch = require("eix.launch")
  local saved_endpoint = client.state.endpoint

  client.state.endpoint = nil
  config.setup({ socket = "/tmp/eix.sock" })
  eq(launch.command("s1"), { "eix", "--socket", "/tmp/eix.sock", "tui", "--session", "s1" })

  config.setup({ endpoint = "tcp://127.0.0.1:7333", token = "secret" })
  eq(launch.command("s1"), { "eix", "--tcp", "127.0.0.1:7333", "--token", "secret", "tui", "--session", "s1" })

  config.setup({ eix_cmd = { "eix", "--config", "/tmp/eix.yaml" } })
  eq(launch.command(), { "eix", "--config", "/tmp/eix.yaml", "tui" })

  config.setup()
  client.state.endpoint = saved_endpoint
end)

test("launch wraps the TUI in the configured terminal", function()
  local config = require("eix.config")
  local launch = require("eix.launch")
  local client = require("eix.client")
  local saved_endpoint = client.state.endpoint
  local cwd = vim.fn.getcwd()

  client.state.endpoint = nil
  config.setup({ terminal = { cmd = "kitty --single-instance" }, auto_open = false })
  eq(launch.prefix(cwd), { "kitty", "--single-instance" })

  config.setup({ terminal = { cmd = { "ghostty", "-e" } }, auto_open = false })
  local argv = assert(launch.argv({ id = "s1", cwd = cwd }))
  eq(argv[1], "ghostty")
  eq(argv[2], "--title")
  eq(argv[3], "eix · " .. vim.fs.basename(cwd))
  eq(argv[4], "-e")
  eq(argv[5], "sh")
  eq(argv[6], "-c")
  contains(argv[7], "cd " .. vim.fn.shellescape(cwd))
  contains(argv[7], "exec 'eix' 'tui' '--session' 's1'")
  contains(argv[7], "printf", "the launch script must set the window title")

  client.state.endpoint = saved_endpoint
  config.setup()
end)

test("launch opens a window of the terminal Neovim runs in", function()
  local config = require("eix.config")
  local launch = require("eix.launch")
  local cwd = vim.fn.getcwd()
  local saved, saved_tmux = launch.current_terminal, vim.env.TMUX

  vim.env.TMUX = nil
  config.setup({ terminal = { cmd = nil, prefer = nil }, auto_open = false })

  if vim.fn.executable("st") == 1 then
    launch.current_terminal = function()
      return "st"
    end
    eq(launch.prefix(cwd), { "st", "-e" })
  end
  if vim.fn.executable("kitty") == 1 then
    launch.current_terminal = function()
      return "kitty"
    end
    eq(launch.prefix(cwd), { "kitty" })
  end

  -- An unknown current terminal falls back to the default order.
  launch.current_terminal = function()
    return nil
  end
  local first = (launch.prefix(cwd) or {})[1]
  assert(first and vim.fn.executable(first) == 1, "no fallback terminal was detected")

  launch.current_terminal = saved
  vim.env.TMUX = saved_tmux
  config.setup()
end)

test("launch honors terminal.prefer order", function()
  local config = require("eix.config")
  local launch = require("eix.launch")
  local cwd = vim.fn.getcwd()
  local saved, saved_tmux = launch.current_terminal, vim.env.TMUX

  vim.env.TMUX = nil
  launch.current_terminal = function()
    return "kitty"
  end

  if vim.fn.executable("st") == 1 then
    config.setup({ terminal = { prefer = { "st", "kitty" } }, auto_open = false })
    eq(launch.prefix(cwd), { "st", "-e" })
  end
  if vim.fn.executable("kitty") == 1 then
    config.setup({ terminal = { prefer = { "kitty", "st" } }, auto_open = false })
    eq(launch.prefix(cwd), { "kitty" })

    -- A configured order wins over the current terminal.
    launch.current_terminal = function()
      return "st"
    end
    config.setup({ terminal = { prefer = { "kitty" } }, auto_open = false })
    eq(launch.prefix(cwd), { "kitty" })
  end

  -- Missing entries are skipped.
  config.setup({ terminal = { prefer = { "definitely-not-a-terminal" } }, auto_open = false })
  eq(launch.prefix(cwd), nil)

  launch.current_terminal = saved
  vim.env.TMUX = saved_tmux
  config.setup()
end)

test("launch detects terminals from environment hints", function()
  local launch = require("eix.launch")
  local vars = {
    "KITTY_WINDOW_ID",
    "WEZTERM_PANE",
    "ALACRITTY_WINDOW_ID",
    "KONSOLE_VERSION",
    "TERM_PROGRAM",
    "TERM",
    "TERMINAL",
  }
  local saved = {}
  for _, var in ipairs(vars) do
    saved[var] = vim.env[var]
    vim.env[var] = nil
  end

  vim.env.TERMINAL = "kitty"
  eq(launch.terminal_from_env(), "kitty")

  vim.env.TERMINAL = nil
  vim.env.TERM = "st-256color"
  eq(launch.terminal_from_env(), "st")

  vim.env.TERM = "xterm-kitty"
  eq(launch.terminal_from_env(), "kitty")

  vim.env.TERM = "xterm-256color"
  vim.env.TERM_PROGRAM = "ghostty"
  eq(launch.terminal_from_env(), "ghostty", "ghostty must not match st")

  vim.env.TERM_PROGRAM = nil
  vim.env.KITTY_WINDOW_ID = "1"
  eq(launch.terminal_from_env(), "kitty")

  for _, var in ipairs(vars) do
    vim.env[var] = saved[var]
  end
end)

test("launch uses tmux when Neovim runs inside it", function()
  local config = require("eix.config")
  local launch = require("eix.launch")
  local saved_tmux = vim.env.TMUX
  local cwd = vim.fn.getcwd()

  config.setup({ terminal = { cmd = nil }, auto_open = false })
  if vim.fn.executable("tmux") ~= 1 then
    return
  end

  vim.env.TMUX = "/tmp/tmux-1000/default,123,0"
  eq(launch.prefix(cwd), { "tmux", "new-window", "-c", cwd, "--" })

  vim.env.TMUX = saved_tmux
  config.setup()
end)

test("launch detaches the terminal from Neovim's process tree", function()
  local launch = require("eix.launch")

  local argv = launch.detach({ "kitty", "sh", "-c", "cd /tmp && exec eix tui" })
  eq(argv[1], "sh")
  eq(argv[2], "-c")
  contains(argv[3], "kitty")
  contains(argv[3], " &")

  -- Real check: the spawned process must be reparented, otherwise a window
  -- manager with a swallow patch (dwm) hides the terminal running Neovim.
  local file = vim.fn.tempname()
  local child = vim.system(
    launch.detach({ "sh", "-c", ("echo $$ > %s; sleep 2"):format(vim.fn.shellescape(file)) }),
    { detach = true, stdio = { "ignore", "ignore", "ignore" } }
  )
  assert(
    vim.wait(2000, function()
      return vim.fn.filereadable(file) == 1 and (vim.fn.readfile(file)[1] or "") ~= ""
    end),
    "the detached command did not start"
  )
  local pid = vim.fn.readfile(file)[1]
  vim.fn.delete(file)

  ---@param p string
  ---@return string
  local function parent(p)
    return ((vim.fn.systemlist({ "ps", "-o", "ppid=", "-p", p })[1] or ""):gsub("%s", ""))
  end
  assert(
    vim.wait(2000, function()
      local ppid = parent(pid)
      return ppid ~= "" and ppid ~= tostring(child.pid) and ppid ~= tostring(vim.fn.getpid())
    end),
    ("still a child of Neovim: %s"):format(parent(pid))
  )
  vim.fn.system({ "kill", pid })
end)

test("launch titles the TUI window so it can be found again", function()
  local config = require("eix.config")
  local launch = require("eix.launch")
  local client = require("eix.client")
  local saved_endpoint = client.state.endpoint
  local cwd = vim.fn.getcwd()

  client.state.endpoint = nil
  eq(launch.title({ name = "demo", cwd = cwd }), "eix · demo")
  eq(launch.title({ cwd = "/tmp/demo" }), "eix · demo")
  eq(launch.title(), "eix")

  -- A terminal with a title flag gets it before the command.
  config.setup({ terminal = { cmd = { "st", "-e" } }, auto_open = false })
  local argv = assert(launch.argv({ id = "s1", cwd = cwd, name = "demo" }))
  eq(vim.list_slice(argv, 1, 4), { "st", "-T", "eix · demo", "-e" })
  contains(argv[#argv], "printf", "the launch script must set the window title too")
  contains(argv[#argv], "eix · demo")

  -- An unknown configured terminal keeps its argv; only the OSC title is set.
  config.setup({ terminal = { cmd = { "sh", "-e" } }, auto_open = false })
  local custom = assert(launch.argv({ id = "s1", cwd = cwd, name = "demo" }))
  eq(vim.list_slice(custom, 1, 3), { "sh", "-e", "sh" })
  contains(custom[#custom], "printf")

  client.state.endpoint = saved_endpoint
  config.setup()
end)

test("launch titles tmux and leaves custom commands alone", function()
  local launch = require("eix.launch")

  eq(
    launch.with_title({ "tmux", "new-window", "-c", "/tmp", "--" }, "eix · demo"),
    { "tmux", "new-window", "-c", "/tmp", "-n", "eix · demo", "--" }
  )
  eq(
    launch.with_title({ "tmux", "new-session", "-A" }, "eix · demo"),
    { "tmux", "new-session", "-A" },
    "a custom tmux command must keep its arguments"
  )
  eq(launch.with_title({ "sh", "-e" }, "eix · demo"), { "sh", "-e" })
  eq(launch.with_title({ "konsole", "-e" }, "demo"), { "konsole", "-p", "tabtitle=demo", "-e" })
end)

test("launch finds and closes an existing TUI window", function()
  local launch = require("eix.launch")
  local saved_executable, saved_systemlist, saved_system = vim.fn.executable, vim.fn.systemlist, vim.fn.system
  local saved_tmux = vim.env.TMUX

  vim.env.TMUX = nil
  vim.fn.executable = function(bin)
    return bin == "wmctrl" and 1 or 0
  end

  local windows = { "0x00a00003  0 host other", "0x00b00004  0 host eix · demo" }
  local demo = { id = "s1", name = "demo" }
  vim.fn.systemlist = function(argv)
    if argv[1] == "wmctrl" and argv[2] == "-l" then
      return vim.deepcopy(windows)
    elseif argv[1] == "wmctrl" and argv[2] == "-lp" then
      return { "0x00b00004  0  4242 host eix · demo" }
    elseif argv[1] == "pgrep" then
      return { "4243", "4244" }
    elseif argv[1] == "ps" then
      local pid = argv[#argv]
      return { pid == "4243" and "eix --socket /tmp/eix.sock tui --session s1" or "sleep 30" }
    end
    return {}
  end
  eq({ launch.find_window(demo) }, { "0x00b00004", "x11" })

  -- The TUI of the session is stopped, not the whole terminal application.
  local closed
  vim.fn.system = function(argv)
    closed = argv
    windows = { "0x00a00003  0 host other" }
    return ""
  end
  eq(launch.close(demo), true)
  eq(closed, { "kill", "-TERM", "4243" }, "the session's TUI process must be stopped")

  -- A window that is not ours and has no TUI behind it is closed as a fallback.
  windows = { "0x00b00005  0 host eix · demo" }
  vim.fn.systemlist = function(argv)
    if argv[1] == "wmctrl" and argv[2] == "-l" then
      return vim.deepcopy(windows)
    elseif argv[1] == "wmctrl" and argv[2] == "-lp" then
      return { "0x00b00005  0  4250 host eix · demo" }
    elseif argv[1] == "pgrep" then
      return {}
    end
    return {}
  end
  closed = nil
  vim.fn.system = function(argv)
    closed = argv
    windows = {}
    return ""
  end
  eq(launch.close(demo), true)
  eq(closed, { "wmctrl", "-i", "-c", "0x00b00005" }, "a foreign window must be asked to close")

  windows = { "0x00a00003  0 host other" }
  closed = nil
  eq(launch.close(demo), false)
  eq(closed, nil, "an unrelated window must not be closed")

  vim.fn.executable, vim.fn.systemlist, vim.fn.system = saved_executable, saved_systemlist, saved_system
  vim.env.TMUX = saved_tmux
end)

test("launch toggle closes an open window before opening one", function()
  local launch = require("eix.launch")
  local saved_close, saved_open = launch.close, launch.open
  local target = { id = "s1", cwd = vim.fn.getcwd(), name = "demo" }
  local opened, closed

  launch.close = function()
    return true
  end
  launch.open = function(_, cb)
    opened = true
    if cb then
      cb(nil)
    end
  end

  launch.launched[target.id] = true
  launch.toggle({ session = target }, function(_, was_closed)
    closed = was_closed
  end)
  eq(opened, nil, "toggle must not open a window that is already open")
  eq(closed, true)
  eq(launch.launched[target.id], nil, "a closed window may be opened again later")

  launch.close = function()
    return false
  end
  launch.toggle({ session = target }, function(_, was_closed)
    closed = was_closed
  end)
  eq(opened, true, "toggle must open a window when none is open")
  eq(closed, false)

  launch.close, launch.open = saved_close, saved_open
end)

test("select runs the chosen prompt", function()
  local config = require("eix.config")
  local ui_select = require("eix.ui.select")
  local saved = vim.ui.select
  vim.ui.select = function(items, _, cb)
    for _, item in ipairs(items) do
      if item.label == "Explain this" then
        cb(item)
        return
      end
    end
    error("missing prompt item")
  end
  local chosen
  ui_select.open({
    ask = function() end,
    prompt = function(text)
      chosen = text
    end,
    open = function() end,
  })
  vim.ui.select = saved
  eq(chosen, config.opts.select.prompts["Explain this"])
end)

test("cancelling the ask float clears the selection highlight", function()
  local eix = require("eix")
  local ask_ui = require("eix.ui.ask")
  local ns = vim.api.nvim_create_namespace("eix-context")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  eix.ask("@this: ", { from = { 1, 0 }, to = { 2, 0 }, kind = "line" })
  eq(ask_ui.is_open(), true)
  eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 1, "the range must be highlighted while asking")

  ask_ui.cancel()
  eq(ask_ui.is_open(), false)
  eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 0, "cancelling must clear the highlight")

  -- Reopening the prompt must not keep the previous highlight either.
  eix.ask("@this: ", { from = { 1, 0 }, to = { 2, 0 }, kind = "line" })
  eix.ask("@this: ", { from = { 2, 0 }, to = { 3, 0 }, kind = "line" })
  eq(ask_ui.is_open(), true)
  eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 1, "only the current range stays highlighted")

  -- Closing the float by other means must clear it too.
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_close(win, true)
  vim.wait(100, function()
    return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 0
  end)
  eq(ask_ui.is_open(), false)
  eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 0, "closing the float must clear the highlight")
end)

test("ask opens a small float and submits expanded text", function()
  local client = require("eix.client")
  local config = require("eix.config")
  local eix = require("eix")
  local ask_ui = require("eix.ui.ask")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "code" })
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  local submitted
  local saved = client.request
  client.request = function(method, params, cb)
    if method == "prompt.submit" then
      submitted = params
      cb(nil, {})
      return
    end
    cb("unexpected request: " .. method)
  end
  config.setup({ auto_open = false })

  local saved_active = client.state.active_session_id
  local saved_sessions = client.state.sessions
  client.state.sessions = { s1 = { id = "s1", cwd = vim.fn.getcwd(), status = "idle" } }
  client.state.active_session_id = "s1"

  eix.ask("@this: hello", { from = { 1, 0 }, to = { 1, 3 }, kind = "char" })
  eq(ask_ui.is_open(), true)
  local win = vim.api.nvim_get_current_win()
  local cfg = vim.api.nvim_win_get_config(win)
  assert(cfg.relative == "cursor" or cfg.relative == "win", "ask must be a cursor-relative float")
  assert(cfg.width <= vim.o.columns, "ask float must fit the editor")
  eq(ask_ui.value(), "@this: hello")

  ask_ui.submit()
  eq(ask_ui.is_open(), false)
  eq(submitted and submitted.session_id, "s1")
  contains(submitted and submitted.text, "code")
  contains(submitted and submitted.text, "hello")

  client.state.active_session_id = saved_active
  client.state.sessions = saved_sessions
  client.request = saved
  config.setup()
end)

test("prompt submits directly when context is disabled", function()
  local client = require("eix.client")
  local config = require("eix.config")
  local eix = require("eix")
  local saved = client.request
  local submitted
  client.request = function(method, params, cb)
    submitted = { method = method, params = params }
    cb(nil, {})
  end
  config.setup({ auto_open = false })
  eix.prompt("plain question", { session = { id = "s1", cwd = "/tmp" }, context = false })
  client.request = saved
  config.setup()
  eq(submitted and submitted.method, "prompt.submit")
  eq(submitted and submitted.params.session_id, "s1")
  eq(submitted and submitted.params.text, "plain question")
end)

test("a prompt sent while the session is busy is queued and flushed when idle", function()
  local client = require("eix.client")
  local config = require("eix.config")
  local eix = require("eix")
  local events = require("eix.events")
  local queue = require("eix.queue")

  local saved = client.request
  local sent = {}
  local busy = true
  client.request = function(method, params, cb)
    if method ~= "prompt.submit" then
      cb(nil, {})
      return
    end
    if busy then
      cb("busy: session " .. params.session_id .. " is already running")
      return
    end
    table.insert(sent, params)
    cb(nil, {})
  end
  config.setup({ auto_open = false })
  queue.clear("s1")

  eix.prompt("first", { session = { id = "s1", cwd = "/tmp" }, context = false })
  eq(queue.len("s1"), 1, "a prompt rejected as busy must be queued")
  eq(#sent, 0)

  busy = false
  events.emit("turn.completed", { session_id = "s1" })
  eq(queue.len("s1"), 0, "the queue must drain when the turn ends")
  eq(#sent, 1, "the queued prompt must be submitted")
  eq(sent[1].text, "first")

  client.request = saved
  config.setup()
  queue.clear("s1")
end)

test("a queued prompt is flushed on an idle session update", function()
  local client = require("eix.client")
  local config = require("eix.config")
  local events = require("eix.events")
  local queue = require("eix.queue")

  local saved = client.request
  local sent = {}
  client.request = function(method, params, cb)
    if method == "prompt.submit" then
      table.insert(sent, params.text)
      cb(nil, {})
      return
    end
    cb(nil, {})
  end
  config.setup({ auto_open = false })
  queue.push("s2", "queued text")

  events.emit("session.updated", { id = "s2", status = "running" })
  eq(queue.len("s2"), 1, "a running session must not be flushed")

  events.emit("session.updated", { id = "s2", status = "idle" })
  eq(queue.len("s2"), 0)
  eq(sent, { "queued text" })

  client.request = saved
  config.setup()
  queue.clear("s2")
end)

test("queueing keeps prompts in order and survives a busy race", function()
  local client = require("eix.client")
  local config = require("eix.config")
  local queue = require("eix.queue")
  require("eix") -- installs queue.sender

  local saved = client.request
  local sent = {}
  local busy = true
  client.request = function(method, params, cb)
    if method == "prompt.submit" then
      if busy then
        cb("busy: session " .. params.session_id .. " is already running")
      else
        table.insert(sent, params.text)
        cb(nil, {})
      end
      return
    end
    cb(nil, {})
  end
  config.setup({ auto_open = false })
  queue.push("s3", "one")
  queue.push("s3", "two")

  eq(queue.flush("s3"), true)
  eq(queue.len("s3"), 2, "a busy race must keep the prompt at the head")

  busy = false
  eq(queue.flush("s3"), true)
  eq(queue.len("s3"), 1)
  eq(sent, { "one" })

  eq(queue.flush("s3"), true)
  eq(queue.len("s3"), 0)
  eq(sent, { "one", "two" }, "queued prompts must keep their order")

  client.request = saved
  config.setup()
end)

test("an undeliverable queued prompt is dropped", function()
  local client = require("eix.client")
  local config = require("eix.config")
  local events = require("eix.events")
  local queue = require("eix.queue")

  local saved = client.request
  client.request = function(_, _, cb)
    cb("invalid_params: prompt must not be empty")
  end
  config.setup({ auto_open = false })

  queue.push("s4", "text")
  events.emit("turn.completed", { session_id = "s4" })
  eq(queue.len("s4"), 0, "an undeliverable prompt must not stall the queue")

  queue.push("s4", "text")
  events.emit("session.deleted", { session_id = "s4" })
  eq(queue.len("s4"), 0, "a deleted session drops its queue")

  client.request = saved
  config.setup()
end)

test("visual EixAsk keeps visual range kinds and columns", function()
  local eix = require("eix")
  local saved_ask = eix.ask
  local captured
  eix.ask = function(default, range)
    captured = { default = default, range = range }
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  vim.cmd("normal! ggVj")
  vim.cmd("normal! \27")
  vim.cmd("1,2EixAsk")
  eq(captured and captured.range and captured.range.kind, "line")
  eq(captured.range.from, { 1, 0 })
  eq(captured.range.to, { 2, math.huge })
  contains(captured.default, "@this: ")

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal! 0vll")
  vim.cmd("normal! \27")
  vim.cmd("1,1EixAsk")
  eq(captured and captured.range and captured.range.kind, "char", "a charwise selection must not widen to lines")
  eq(captured.range.from, { 1, 0 })
  eq(captured.range.to, { 1, 2 })

  eix.ask = saved_ask
end)

test("plugin defines commands, mappings and highlights", function()
  vim.cmd("runtime plugin/eix.lua")
  for _, name in ipairs({ "Eix", "EixAsk", "EixSelect" }) do
    if vim.fn.exists(":" .. name) ~= 2 then
      error("missing command :" .. name)
    end
  end
  for _, mapping in ipairs({ "<Plug>(EixAsk)", "<Plug>(EixSelect)", "<Plug>(EixOperator)", "<Plug>(EixToggle)" }) do
    if vim.fn.maparg(mapping, "n") == "" then
      error("missing " .. mapping)
    end
  end
  local hl = vim.api.nvim_get_hl(0, { name = "EixStatusAttention" })
  eq(hl.link, "DiagnosticWarn")
  eq(type(_G.eix_statusline), "function")
end)

if failures > 0 then
  print(("%d test(s) failed"):format(failures))
  vim.cmd("cquit 1")
else
  print("UNIT_OK")
end
