---Configuration for eix.nvim.
local M = {}

---@class eix.TerminalOpts
---@field cmd? string|string[] Terminal command prefix that accepts `sh -c <script>`.
---  Forces this terminal and skips detection.
---@field prefer? string[] Terminal names in priority order. The first executable
---  wins. Defaults to the terminal Neovim runs in, then `st`, `kitty`, …

---@class eix.AskOpts
---@field width number Fraction of the editor width for the ask float.

---@class eix.ContextOpts
---@field max_lines number Maximum lines included by one placeholder.
---@field max_bytes number Maximum bytes included by one placeholder.
---@field placeholders table<string, boolean> Enabled placeholders.

---@class eix.Opts
---@field eix_cmd string|string[] Executable used to discover/start the daemon and TUI.
---@field endpoint? string Unix socket path or `tcp://host:port`.
---@field socket? string Explicit Unix socket path. Overrides `endpoint`.
---@field token? string Token for a TCP endpoint.
---@field auto_start boolean Start/attach the daemon through `eix status --json`.
---@field auto_reconnect boolean Reconnect when the daemon connection drops.
---@field request_timeout number Milliseconds before a request is considered failed (0 disables).
---@field auto_open boolean Open the TUI terminal after submitting a prompt.
---@field notifications boolean Forward attention events to `vim.notify`.
---@field terminal eix.TerminalOpts How the TUI is launched outside Neovim.
---@field ask eix.AskOpts Ask float options.
---@field select { prompts: table<string, string> } Prompts offered by `select()`.
---@field context eix.ContextOpts

---Default configuration.
---@type eix.Opts
local defaults = {
  eix_cmd = "eix",
  endpoint = nil,
  socket = nil,
  token = nil,
  auto_start = true,
  auto_reconnect = true,
  request_timeout = 0,
  auto_open = true,
  notifications = true,
  terminal = {
    cmd = nil,
    prefer = nil,
  },
  ask = {
    width = 0.4,
  },
  select = {
    prompts = {
      ["Add tests"] = "Add tests for @this",
      ["Document this"] = "Add comments documenting @this",
      ["Explain this"] = "Explain @this and its context",
      ["Fix diagnostics"] = "Fix @diagnostics",
      ["Implement this"] = "Implement @this",
      ["Optimize this"] = "Optimize @this for performance and readability",
      ["Review this"] = "Review @this for correctness and readability",
    },
  },
  context = {
    max_lines = 300,
    max_bytes = 60000,
    placeholders = {
      ["@this"] = true,
      ["@buffer"] = true,
      ["@buffers"] = true,
      ["@diagnostics"] = true,
      ["@quickfix"] = true,
      ["@visible"] = true,
      ["@diff"] = true,
    },
  },
}

---Configured options.
---@type eix.Opts
M.opts = vim.deepcopy(defaults)

---Keep `chat.auto_open` from older configs working and drop removed keys.
---@param opts table
---@return table
local function migrate(opts)
  local chat = opts.chat
  if type(chat) == "table" and opts.auto_open == nil and chat.auto_open ~= nil then
    opts.auto_open = chat.auto_open
  end
  opts.chat = nil
  opts.window = nil
  return opts
end

---@param opts? eix.Opts
---@return eix.Opts
function M.setup(opts)
  opts = migrate(vim.deepcopy(opts or {}))
  M.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  return M.opts
end

---@return eix.Opts
function M.get()
  return M.opts
end

---@return eix.Opts
function M.defaults()
  return vim.deepcopy(defaults)
end

return M
