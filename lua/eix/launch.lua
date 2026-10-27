---Launch the eix TUI in an external terminal window.
---
---The TUI runs outside Neovim, in the session's directory, so eix keeps its own
---full-size terminal and keyboard handling.
local client = require("eix.client")
local config = require("eix.config")
local session = require("eix.session")

local M = {
  ---Session ids that already had a terminal opened by this Neovim instance.
  ---Used to avoid spawning a window for every prompt.
  launched = {},
}

---@param message string
---@param level? integer
local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "eix" })
end

---Known terminals, in the default detection order. The prefix is followed by
---`sh -c <script>`. `title` is the terminal's own flag for the window title
---(`%s` is the title), so `toggle()` can find the window again.
local TERMINALS = {
  { bin = "st", prefix = { "st", "-e" }, title = { "-T", "%s" } },
  { bin = "kitty", prefix = { "kitty" }, title = { "--title", "%s" } },
  { bin = "ghostty", prefix = { "ghostty", "-e" }, title = { "--title", "%s" } },
  -- wezterm has no title flag; the OSC title in the launch script is enough.
  { bin = "wezterm", prefix = { "wezterm", "start", "--" } },
  { bin = "alacritty", prefix = { "alacritty", "-e" }, title = { "-t", "%s" } },
  { bin = "foot", prefix = { "foot" }, title = { "-T", "%s" } },
  { bin = "konsole", prefix = { "konsole", "-e" }, title = { "-p", "tabtitle=%s" } },
  { bin = "gnome-terminal", prefix = { "gnome-terminal", "--" }, title = { "--title", "%s" } },
  { bin = "xterm", prefix = { "xterm", "-e" }, title = { "-T", "%s" } },
}

---Arguments that point the TUI at the same daemon as the plugin.
---@return string[]
local function daemon_args()
  local args = {}
  local endpoint = client.state.endpoint or config.opts.endpoint
  local token = config.opts.token or vim.env.EIX_TCP_TOKEN
  if endpoint and tostring(endpoint) ~= "" then
    local tcp = tostring(endpoint):match("^tcp://(.+)$")
    if tcp then
      vim.list_extend(args, { "--tcp", tcp })
      if token and token ~= "" then
        vim.list_extend(args, { "--token", token })
      end
    else
      vim.list_extend(args, { "--socket", (tostring(endpoint):gsub("^unix://", "")) })
    end
  elseif config.opts.socket and config.opts.socket ~= "" then
    vim.list_extend(args, { "--socket", config.opts.socket })
  end
  return args
end

---The `eix tui` command for a session.
---@param session_id? string
---@return string[]
function M.command(session_id)
  local cmd = config.opts.eix_cmd or "eix"
  cmd = type(cmd) == "table" and vim.deepcopy(cmd) or { cmd }
  vim.list_extend(cmd, daemon_args())
  cmd[#cmd + 1] = "tui"
  if session_id and session_id ~= "" then
    vim.list_extend(cmd, { "--session", session_id })
  end
  return cmd
end

---@param bin string
---@return table?
local function known(bin)
  for _, terminal in ipairs(TERMINALS) do
    if terminal.bin == bin then
      return terminal
    end
  end
  return nil
end

---Map a process name to a known terminal. Handles wrappers such as
---`wezterm-gui` and the truncated `gnome-terminal-` comm.
---@param comm string
---@return string?
local function terminal_of_comm(comm)
  local name = vim.fs.basename(comm):lower():gsub("%-gui$", ""):gsub("%-$", "")
  local terminal = known(name)
  return terminal and terminal.bin or nil
end

---Walk Neovim's ancestors to find the terminal emulator it runs inside.
---@return string?
local function terminal_from_processes()
  local lines = vim.fn.systemlist({ "ps", "-eo", "pid=,ppid=,comm=" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local parents, commands = {}, {}
  for _, line in ipairs(lines) do
    local pid, ppid, comm = line:match("^%s*(%d+)%s+(%d+)%s+(.+)$")
    if pid then
      parents[pid] = ppid
      commands[pid] = comm
    end
  end

  local pid = tostring(vim.fn.getpid())
  for _ = 1, 20 do
    if not commands[pid] then
      return nil
    end
    local name = terminal_of_comm(commands[pid])
    if name then
      return name
    end
    pid = parents[pid]
    if not pid or pid == "0" then
      return nil
    end
  end
  return nil
end

local ENV_TERMINALS = {
  { var = "KITTY_WINDOW_ID", bin = "kitty" },
  { var = "WEZTERM_PANE", bin = "wezterm" },
  { var = "ALACRITTY_WINDOW_ID", bin = "alacritty" },
  { var = "KONSOLE_VERSION", bin = "konsole" },
}

local TERM_PATTERNS = {
  { pattern = "^xterm%-kitty", bin = "kitty" },
  { pattern = "^xterm%-ghostty", bin = "ghostty" },
  { pattern = "^alacritty", bin = "alacritty" },
  { pattern = "^foot", bin = "foot" },
  { pattern = "^wezterm", bin = "wezterm" },
  { pattern = "^konsole", bin = "konsole" },
  { pattern = "^st%-", bin = "st" },
  { pattern = "^st$", bin = "st" },
}

---Fallback detection from the environment, for platforms without `ps` data or
---when Neovim is not a direct descendant of the terminal.
---@return string?
function M.terminal_from_env()
  for _, hint in ipairs(ENV_TERMINALS) do
    if (vim.env[hint.var] or "") ~= "" then
      return hint.bin
    end
  end

  local program = (vim.env.TERM_PROGRAM or ""):lower():gsub("%.app$", "")
  local by_program = program ~= "" and known(program)
  if by_program then
    return by_program.bin
  end

  local term = (vim.env.TERM or ""):lower()
  for _, hint in ipairs(TERM_PATTERNS) do
    if term:find(hint.pattern) then
      return hint.bin
    end
  end

  local env_term = vim.env.TERMINAL
  if env_term and env_term ~= "" then
    local bin = vim.split(env_term, "%s+", { trimempty = true })[1]
    local terminal = bin and known(bin)
    if terminal then
      return terminal.bin
    end
  end
  return nil
end

---Terminal emulator Neovim currently runs inside, when it is a known one.
---@return string?
function M.current_terminal()
  return terminal_from_processes() or M.terminal_from_env()
end

---@return boolean
local function in_tmux()
  return vim.env.TMUX ~= nil and vim.env.TMUX ~= "" and vim.fn.executable("tmux") == 1
end

---Terminal names to try, in order. `terminal.prefer` wins; otherwise the
---current terminal comes first, then the default order.
---@return string[]
local function candidates()
  local prefer = config.opts.terminal and config.opts.terminal.prefer
  if type(prefer) == "table" and #prefer > 0 then
    return vim.deepcopy(prefer)
  end

  local names = {}
  local current = M.current_terminal()
  if current then
    names[#names + 1] = current
  end
  for _, terminal in ipairs(TERMINALS) do
    names[#names + 1] = terminal.bin
  end
  return names
end

---Resolve the terminal command prefix: configuration, tmux, then detection.
---@param cwd string
---@return string[]?
function M.prefix(cwd)
  local configured = config.opts.terminal and config.opts.terminal.cmd
  if type(configured) == "string" then
    configured = vim.split(configured, "%s+", { trimempty = true })
  end
  if type(configured) == "table" and #configured > 0 then
    return vim.deepcopy(configured)
  end

  if in_tmux() then
    return { "tmux", "new-window", "-c", cwd, "--" }
  end

  local seen = {}
  for _, name in ipairs(candidates()) do
    name = tostring(name)
    if not seen[name] then
      seen[name] = true
      if vim.fn.executable(name) == 1 then
        local terminal = known(name)
        return vim.deepcopy(terminal and terminal.prefix or { name, "-e" })
      end
    end
  end
  return nil
end

---@param args string[]
---@return string
local function shell_join(args)
  local quoted = {}
  for _, arg in ipairs(args) do
    quoted[#quoted + 1] = vim.fn.shellescape(arg)
  end
  return table.concat(quoted, " ")
end

---Window title for a session's TUI. Used to find the window on toggling.
---@param found? table|string
---@return string
function M.title(found)
  local name
  if type(found) == "table" then
    name = found.name
    if (not name or name == "") and found.cwd then
      name = vim.fs.basename(found.cwd)
    end
  end
  if not name or name == "" then
    return "eix"
  end
  -- A title ends up in the terminal's OSC sequence and in window lists.
  return "eix · " .. (tostring(name):gsub("%c", " "))
end

---Terminal args that set the window title, when the terminal has a flag for it.
---@param prefix string[]
---@param title string
---@return string[] argv
function M.with_title(prefix, title)
  local argv = vim.deepcopy(prefix)

  if argv[1] == "tmux" and argv[2] == "new-window" and argv[#argv] == "--" then
    -- `tmux new-window -c DIR [-n NAME] --`
    table.insert(argv, #argv, "-n")
    table.insert(argv, #argv, title)
    return argv
  end

  local terminal = known(argv[1])
  if terminal and terminal.title then
    for index = #terminal.title, 1, -1 do
      table.insert(argv, 2, (terminal.title[index]:gsub("%%s", function()
        return title
      end)))
    end
  end
  return argv
end

---Find the TUI window of a session by its title.
---@param found? table|string
---@return string? id Window id on X11, window id in tmux.
---@return string? kind "x11" or "tmux".
function M.find_window(found)
  local title = M.title(found)

  if in_tmux() then
    local lines = vim.fn.systemlist({ "tmux", "list-windows", "-F", "#{window_id} #{window_name}" })
    if vim.v.shell_error ~= 0 then
      return nil
    end
    for _, line in ipairs(lines) do
      local id, name = line:match("^(%S+)%s+(.*)$")
      if name == title then
        return id, "tmux"
      end
    end
    return nil
  end

  if vim.fn.executable("wmctrl") ~= 1 then
    return nil
  end
  local lines = vim.fn.systemlist({ "wmctrl", "-l" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  for _, line in ipairs(lines) do
    local id, name = line:match("^(0x%x+)%s+%S+%s+%S+%s+(.*)$")
    if id and name == title then
      return id, "x11"
    end
  end
  return nil
end

---Pid of an X11 window, from `wmctrl -lp`.
---@param id string
---@return integer?
local function window_pid(id)
  for _, line in ipairs(vim.fn.systemlist({ "wmctrl", "-lp" })) do
    local wid, pid = line:match("^(0x%x+)%s+%-?%d+%s+(%d+)")
    if wid == id then
      return tonumber(pid)
    end
  end
end

---Command line of a process.
---@param pid string
---@return string
local function process_args(pid)
  return table.concat(vim.fn.systemlist({ "ps", "-o", "args=", "-p", pid }), " ")
end

---Children of the terminal process that run the eix TUI, the session's own first.
---@param pid integer
---@param session_id? string
---@return string[]
local function tui_pids(pid, session_id)
  local all, own = {}, {}
  for _, line in ipairs(vim.fn.systemlist({ "pgrep", "-P", tostring(pid) })) do
    local child = vim.trim(line)
    local cmdline = child ~= "" and process_args(child) or ""
    if cmdline:find("%f[%w]tui%f[%W]") then
      all[#all + 1] = child
      if session_id and cmdline:find(session_id, 1, true) then
        own[#own + 1] = child
      end
    end
  end
  return #own > 0 and own or all
end

---Close the TUI window of a session, if it is open.
---The daemon keeps the session and a running turn; only the TUI goes away.
---@param found? table|string
---@return boolean closed
function M.close(found)
  local id, kind = M.find_window(found)
  if not id then
    return false
  end

  if kind == "tmux" then
    vim.fn.system({ "tmux", "kill-window", "-t", id })
    return vim.v.shell_error == 0
  end

  -- Terminating the TUI makes the terminal exit and its window disappear,
  -- which also works for terminals that ignore `WM_DELETE_WINDOW` (st, kitty
  -- under dwm) without killing the whole terminal application.
  local pid = window_pid(id)
  local session_id = type(found) == "table" and found.id or nil
  local tuis = pid and tui_pids(pid, session_id) or {}
  if #tuis > 0 then
    local argv = { "kill", "-TERM" }
    vim.list_extend(argv, tuis)
    vim.fn.system(argv)
    return vim.wait(2000, function()
      return M.find_window(found) == nil
    end, 50)
  end

  -- No TUI process behind the window (started by hand?): ask the window to close.
  if vim.fn.executable("xdotool") == 1 then
    vim.fn.system({ "xdotool", "windowclose", id })
  else
    vim.fn.system({ "wmctrl", "-i", "-c", id })
  end
  return vim.v.shell_error == 0
end

---Wrap `argv` so the terminal does not stay in Neovim's process tree.
---
---`vim.system(..., { detach = true })` starts a new session but keeps the
---process as a child of Neovim. Window managers with a "swallow" patch (dwm and
---its forks) hide the terminal window that owns Neovim when a new window's
---process descends from it, which makes the editor disappear behind eix.
---Backgrounding the command from a short-lived shell reparents it to init, so
---the ancestry check no longer matches.
---@param argv string[]
---@return string[]
function M.detach(argv)
  return { "sh", "-c", shell_join(argv) .. " &" }
end

---Full terminal argv for a session, or nil when no terminal can be found.
---@param found? table|string
---@return string[]? argv
---@return string? err
function M.argv(found)
  local cwd = type(found) == "table" and found.cwd or nil
  if not cwd or vim.fn.isdirectory(cwd) ~= 1 then
    cwd = vim.fn.getcwd()
  end
  local prefix = M.prefix(cwd)
  if not prefix then
    return nil, "no terminal found; set `terminal.cmd` in `require('eix').setup()`"
  end

  local configured = config.opts.terminal and config.opts.terminal.cmd
  local bin = prefix[1]
  if not configured and bin and not bin:find("/", 1, true) and vim.fn.executable(bin) ~= 1 then
    return nil, "terminal not executable: " .. bin
  end

  if not vim.env.DISPLAY and not vim.env.WAYLAND_DISPLAY and not in_tmux() and not configured then
    return nil, "no display available to open a terminal"
  end

  local title = M.title(found)
  local script = ("cd %s && printf %s %s && exec %s"):format(
    vim.fn.shellescape(cwd),
    vim.fn.shellescape("\\033]2;%s\\007"),
    vim.fn.shellescape(title),
    shell_join(M.command(type(found) == "table" and found.id or nil))
  )
  if not configured and prefix[1] == "tmux" then
    -- Keep the tmux window name stable so `find_window()` can match it.
    script = 'tmux set-option -w -t "$TMUX_PANE" automatic-rename off 2>/dev/null; ' .. script
  end
  local argv = M.with_title(prefix, title)
  vim.list_extend(argv, { "sh", "-c", script })
  return argv
end

---Open the TUI in a terminal. `once` skips sessions that were already launched.
---@param opts? { session?: table|string, cwd?: string, force_new?: boolean, once?: boolean }
---@param cb? fun(err?: string)
function M.open(opts, cb)
  if type(opts) == "string" then
    opts = { session = opts }
  end
  opts = opts or {}

  session.resolve(opts.session, function(found)
    if not found then
      if cb then
        cb("no session")
      end
      return
    end
    session.activate(found)

    if opts.once and M.launched[found.id] then
      if cb then
        cb(nil)
      end
      return
    end

    local argv, err = M.argv(found)
    if not argv then
      notify("eix: " .. err, vim.log.levels.ERROR)
      if cb then
        cb(err)
      end
      return
    end

    local ok, spawn_err = pcall(vim.system, M.detach(argv), {
      cwd = vim.fn.isdirectory(found.cwd or "") == 1 and found.cwd or vim.fn.getcwd(),
      detach = true,
      stdio = { "ignore", "ignore", "ignore" },
    })
    if not ok then
      notify("eix: cannot open a terminal: " .. tostring(spawn_err), vim.log.levels.ERROR)
      if cb then
        cb(tostring(spawn_err))
      end
      return
    end

    M.launched[found.id] = true
    if cb then
      cb(nil)
    end
  end, { cwd = opts.cwd, force_new = opts.force_new })
end

---Open the TUI for a session, or close its window when it is already open.
---@param opts? { session?: table|string, cwd?: string, force_new?: boolean }
---@param cb? fun(err?: string, closed?: boolean)
function M.toggle(opts, cb)
  if type(opts) == "string" then
    opts = { session = opts }
  end
  opts = opts or {}

  session.resolve(opts.session, function(found)
    if not found then
      if cb then
        cb("no session")
      end
      return
    end
    session.activate(found)

    if M.close(found) then
      -- The window is gone, so a later prompt may open it again.
      M.launched[found.id] = nil
      if cb then
        cb(nil, true)
      end
      return
    end

    M.open({ session = found }, function(err)
      if cb then
        cb(err, false)
      end
    end)
  end, { cwd = opts.cwd, force_new = opts.force_new })
end

return M
