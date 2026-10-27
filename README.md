# eix.nvim

Neovim frontend for [eix](https://github.com/zetatez/eix), built the way
[opencode.nvim](https://github.com/nickjvandyke/opencode.nvim) is: keep the
agent's own TUI, and add the editor glue around it.

- Ask in a small floating window at the cursor.
- Open the real `eix` TUI in a new terminal window, in the session directory.
- Pick a common prompt or open the TUI.
- Send a motion or visual range with `g@`.
- Expand `@this`, `@buffer`, `@diagnostics`, `@diff` and friends.

The plugin does not draw a chat transcript and does not embed a terminal. `eix`
owns streaming, tool output, diffs and approvals in its own window; Neovim and
the terminal `eix` share the same sessions.

## Requirements

- Neovim 0.11 or newer.
- `eix` on `PATH` (or set `eix_cmd`).
- A daemon. With `auto_start` (default) the plugin runs `eix status --json`
  to discover or start it.
- Optional: `fzf-lua` for a fuzzy `select()` picker. Without it the native
  `vim.ui.select` is used.
- A terminal emulator (`st`, `kitty`, `ghostty`, `wezterm`, `alacritty`, `foot`,
  `konsole`, `xterm`, …), or `tmux`. See `terminal.prefer` below.
- Optional on X11: `wmctrl`, so `:Eix` can find the TUI window and close it
  again. Without it `:Eix` only ever opens a new window.

## Setup

```lua
{
  "zetatez/eix.nvim",
  config = function()
    require("eix").setup()
  end,
  keys = {
    { "<leader>s", "<Plug>(EixAsk)", mode = { "n", "x" }, desc = "Ask eix…" },
    { "<leader>o", "<Plug>(EixSelect)", mode = { "n", "x" }, desc = "Select eix…" },
    { "<leader>t", "<Plug>(EixToggle)", desc = "Toggle eix TUI" },
  },
}
```

These are the same three actions as `opencode.nvim`:

| Key | Action |
| --- | --- |
| `<leader>s` | Ask about the current line or selection in a float. |
| `<leader>o` | Pick a common prompt or open the TUI. |
| `<leader>t` | Open the TUI, or close its window when it is already open. |

`<leader>s` pre-fills `@this: `, so the current line (or the visual range) is
attached unless you delete it. Press `<CR>` to send, `<Esc>` to cancel.

To send a range immediately without the float:

```lua
vim.keymap.set("n", "<leader>go", "<Plug>(EixOperator)", { desc = "Send range to eix" })
-- then <leader>go ip, <leader>go G, ...
```

`<Plug>(EixOperator)` uses `@this`; use the API to send a different prompt:

```lua
vim.keymap.set("n", "go", function()
  return require("eix").operator("Explain @this")
end, { expr = true, desc = "Explain range with eix" })
```

## Commands

| Command | Description |
| --- | --- |
| `:Eix [session_id]` | Open the TUI, or close its window if it is already open. |
| `:EixAsk [text]` | Open the ask float, optionally with `text` pre-filled. |
| `:EixSelect` | Open the prompt picker. |

`:EixAsk` supports a range:

```vim
:'<,'>EixAsk
:10,20EixAsk why is this slow?
```

## The ask float

`ask()` opens a cursor-relative float with a single-line prompt. Enter submits,
Esc cancels. The text is expanded with context placeholders, then sent with
`prompt.submit` to the session for the current workspace. When `auto_open` is
true, the TUI opens in a terminal window (once per session) while it streams.

When a turn is already running, the prompt is not rejected: it is kept in a
per-session queue and sent as soon as that session is idle. Queued prompts keep
their order, and a notification reports how many are waiting. This also applies
to `prompt()` and the operator mapping.

```lua
require("eix").ask("@this: what does this do?")
require("eix").ask() -- empty prompt
```

## The TUI terminal

`eix` is a full-screen TUI, so it runs in its own terminal window rather than
inside Neovim. `open()` starts:

```sh
st -e sh -c "cd /path/to/project && exec eix tui --session <id>"
```

The launcher is picked in this order:

1. `terminal.cmd`, when configured. Forces that terminal.
2. `tmux new-window` when Neovim runs inside tmux.
3. `terminal.prefer`, when configured: the first entry that is installed.
4. Otherwise the terminal Neovim itself runs in (detected from the process
   tree, with environment hints as a fallback), then the default order:
   `st`, `kitty`, `ghostty`, `wezterm`, `alacritty`, `foot`, `konsole`,
   `gnome-terminal`, `xterm`.

So Neovim running in `st` opens a new `st` window, and Neovim running in
`kitty` opens `kitty`. Pin an explicit order when the defaults do not fit:

```lua
require("eix").setup({
  terminal = { prefer = { "kitty", "st" } }, -- first installed wins
})
```

`terminal.cmd` is a command prefix that accepts `sh -c <script>`, so any
terminal works:

```lua
require("eix").setup({
  terminal = { cmd = { "ghostty", "-e" } },
})
```

The new window starts in the session directory and talks to the same daemon as
the plugin. Its title is `eix · <session name>`, so `<leader>t` (or `:Eix`) can
find it: when that window is already open the command closes it again (`wmctrl`
on X11, `tmux kill-window` inside tmux); otherwise it spawns one. The daemon
and a running turn keep going after the window closes. Call `open()` directly
to force another window. After the first prompt for a session, `auto_open` does
not spawn duplicate windows either.

The terminal is launched in the background and reparented to init, so it never
stays a child of Neovim. Window managers with a "swallow" patch (dwm and its
forks) otherwise hide the terminal that runs Neovim when a new window descends
from it, which makes the editor disappear behind eix.

## Workspace

Sessions, the TUI and `@diff` use the workspace of the file in the current
buffer, not Neovim's working directory:

- file inside a git repository: the repository root
- file outside git: the file's own directory
- no file (scratch or terminal buffers): Neovim's working directory

So `:Eix` from `lua/eix/ui/ask.lua` starts eix at the repository root, even if
Neovim was started elsewhere. Pass `cwd` to `prompt()` or `open()` to override.

## Context placeholders

Expanded before submission:

| Placeholder | Content |
| --- | --- |
| `@this` | Current line, or the active range. |
| `@buffer` | Whole current buffer. |
| `@buffers` | Paths of loaded file buffers. |
| `@diagnostics` | Diagnostics for the buffer, filtered by the range. |
| `@quickfix` | File-backed quickfix entries. |
| `@visible` | Text visible in the current tab page. |
| `@diff` | Uncommitted `git diff` for the workspace. |

Placeholders only match on word boundaries, so `mail@this.example` is left
alone. Each expansion is capped by `context.max_lines` and `context.max_bytes`.
Disable one with `context.placeholders`:

```lua
require("eix").setup({
  context = { placeholders = { ["@diff"] = false } },
})
```

When invoked outside the TUI there is no terminal buffer involved; context always
refers to the window you are editing.

## Configuration

```lua
require("eix").setup({
  eix_cmd = "eix",        -- string or argv table
  socket = nil,           -- explicit unix socket
  endpoint = nil,         -- unix path or "tcp://host:port"
  token = nil,            -- token for a TCP endpoint
  auto_start = true,
  auto_reconnect = true,
  request_timeout = 0,    -- milliseconds; 0 disables
  auto_open = true,       -- open the TUI after submitting
  notifications = true,   -- approval/question notifications

  terminal = {
    cmd = nil,            -- e.g. { "ghostty", "-e" }; forces a terminal
    prefer = nil,         -- e.g. { "kitty", "st" }; first installed wins
  },

  ask = {
    width = 0.4,          -- ask float width fraction
  },

  select = {
    prompts = {
      ["Explain this"] = "Explain @this and its context",
      ["Fix diagnostics"] = "Fix @diagnostics",
      ["Review this"] = "Review @this for correctness and readability",
      ["Add tests"] = "Add tests for @this",
      ["Document this"] = "Add comments documenting @this",
      ["Implement this"] = "Implement @this",
      ["Optimize this"] = "Optimize @this for performance and readability",
    },
  },

  context = {
    max_lines = 300,
    max_bytes = 60000,
    placeholders = { --[[ all enabled by default ]] },
  },
})
```

### TCP endpoints

With a TCP daemon, the plugin authenticates the RPC connection and passes the
endpoint and token to the TUI:

```lua
require("eix").setup({
  endpoint = "tcp://127.0.0.1:7777",
  token = vim.env.EIX_TCP_TOKEN,
})
```

## Statusline

```lua
vim.o.statusline = "%{%v:lua.eix_statusline()%} " .. vim.o.statusline
```

Renders `icon eix · session · mode · model`, or nothing when disconnected.

## API

```lua
local eix = require("eix")

eix.setup(opts)
eix.ask(default?, range?)     -- floating prompt
eix.prompt(text, opts?)       -- submit directly
eix.operator(text)            -- returns "g@"
eix.operator_range(kind?)     -- range covered by the last motion
eix.select()
eix.open(opts?, cb?)           -- always spawn a terminal
eix.toggle(opts?, cb?)         -- open, or close the existing window
eix.statusline()
```

Approvals, models, agents, modes, forks and background processes live in the
eix TUI, so the plugin does not duplicate them. Approvals and questions are
still forwarded to `vim.notify` while you work in Neovim.

Daemon notifications are available through `require("eix.events")`:

```lua
local events = require("eix.events")
events.on("turn.completed", function(params) end)
events.on("message.delta", function(params) end)
```

## How it works

- One newline-delimited JSON-RPC connection per Neovim process over the eix
  socket (TCP with `auth` when configured).
- `ask` renders the prompt with editor context and calls `prompt.submit`.
- The TUI is a detached `eix tui --session <id>` process in a new terminal
  window, started in the session directory. Neovim never owns the process.

## Tests

```sh
tests/run.sh
EIX_BIN=/path/to/eix tests/run.sh
```

The integration test starts an isolated daemon, creates a session, builds and
spawns the TUI launcher command, then deletes the session.

## License

MIT. See [LICENSE](LICENSE).
