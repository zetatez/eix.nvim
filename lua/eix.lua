---Public API for eix.nvim.
local ask_ui = require("eix.ui.ask")
local client = require("eix.client")
local config = require("eix.config")
local context = require("eix.context")
local events = require("eix.events")
local launch = require("eix.launch")
local queue = require("eix.queue")
local session = require("eix.session")
local ui_select = require("eix.ui.select")

local M = {}

---@param message string
---@param level? integer
local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "eix" })
end

---Open the TUI in a terminal when the caller and the configuration allow it.
---@param found table
---@param opts { open?: boolean }
local function open_tui(found, opts)
  if opts.open ~= false and config.opts.auto_open ~= false then
    launch.open({ session = found, once = true })
  end
end

---Submit an already-expanded prompt. When a turn is already running the prompt
---is queued instead, and `queue` sends it once the session goes idle.
---@param found table
---@param text string
---@param opts { open?: boolean }
local function deliver(found, text, opts)
  client.request("prompt.submit", { session_id = found.id, text = text }, function(err)
    if err then
      if queue.is_busy(err) then
        local waiting = queue.push(found.id, text)
        notify(("eix: queued · %d prompt(s) waiting"):format(waiting))
        open_tui(found, opts)
        return
      end
      notify("eix: " .. err, vim.log.levels.ERROR)
      return
    end
    open_tui(found, opts)
  end)
end

-- How `queue` sends prompts it flushed, once their session is idle again.
queue.sender = function(session_id, text, cb)
  client.request("prompt.submit", { session_id = session_id, text = text }, function(err)
    if not err then
      local found = client.session(session_id)
      if found then
        open_tui(found, {})
      end
    end
    cb(err)
  end)
end

---Set up the plugin. Safe to call more than once.
---@param opts? eix.Opts
---@return eix.Opts
function M.setup(opts)
  return config.setup(opts)
end

---Submit `text` to the most recent session for the current workspace.
---Context placeholders in `text` are expanded first.
---@param text string
---@param opts? { session?: table|string, cwd?: string, force_new?: boolean, range?: eix.Context.Range, context?: boolean, open?: boolean }
function M.prompt(text, opts)
  opts = opts or {}
  if type(text) ~= "string" or vim.trim(text) == "" then
    return
  end

  session.resolve(opts.session, function(found)
    if not found then
      return
    end
    session.activate(found)

    local expanded = text
    if opts.context ~= false then
      local ok, ctx = pcall(context.new, { range = opts.range, cwd = found.cwd })
      if ok then
        local rendered_ok, rendered = pcall(ctx.render, ctx, text)
        if rendered_ok and type(rendered) == "string" then
          expanded = rendered
        end
        pcall(ctx.clear, ctx)
      end
    end

    deliver(found, expanded, { open = opts.open })
  end, { cwd = opts.cwd, force_new = opts.force_new })
end

---Open a small floating prompt, then submit its contents with `prompt()`.
---`default` is pre-filled; the caller decides whether to include `@this:`.
---@param default? string
---@param range? eix.Context.Range
function M.ask(default, range)
  -- Capture the context from the editor window, not from a prompt that is
  -- already open.
  if ask_ui.is_open() then
    ask_ui.cancel()
  end

  local ctx = nil
  local ok, created = pcall(context.new, { range = range })
  if ok then
    ctx = created
  end

  ---Drop the temporary highlight, whatever ends the prompt.
  local function clear()
    if ctx then
      pcall(ctx.clear, ctx)
      ctx = nil
    end
  end

  ask_ui.open(default or "", function(text)
    if vim.trim(text) == "" then
      clear()
      return
    end

    local expanded = text
    if ctx then
      local rendered_ok, rendered = pcall(ctx.render, ctx, text)
      if rendered_ok and type(rendered) == "string" then
        expanded = rendered
      end
      clear()
    end
    M.prompt(expanded, { context = false })
  end, clear)
end

---@param from integer[]
---@param to integer[]
---@param kind string
---@return eix.Context.Range
local function make_range(from, to, kind)
  local from_pos = { from[2], math.max(0, from[3] - 1) }
  local to_pos = { to[2], math.max(0, to[3] - 1) }
  if from_pos[1] > to_pos[1] or (from_pos[1] == to_pos[1] and from_pos[2] > to_pos[2]) then
    from_pos, to_pos = to_pos, from_pos
  end
  if kind == "line" then
    from_pos[2], to_pos[2] = 0, math.huge
  end
  return { from = from_pos, to = to_pos, kind = kind }
end

---Range covered by the last `g@` motion.
---@param kind? string
---@return eix.Context.Range?
function M.operator_range(kind)
  local from = vim.fn.getpos("'[")
  local to = vim.fn.getpos("']")
  if from[2] == 0 or to[2] == 0 then
    return nil
  end
  return make_range(from, to, kind or "char")
end

---Wrap `prompt()` as an operator, e.g. `g@ip`.
---@param text string
---@return string
function M.operator(text)
  _G.eix_prompt_operator = function(kind)
    M.prompt(text, { range = M.operator_range(kind) })
  end
  vim.o.operatorfunc = "v:lua.eix_prompt_operator"
  return "g@"
end

---Pick a common prompt, ask freely, or open the TUI.
function M.select()
  ui_select.open({
    ask = function()
      M.ask()
    end,
    prompt = function(text)
      M.prompt(text)
    end,
    open = function()
      M.open()
    end,
  })
end

---Open the eix TUI in an external terminal, in the session's directory.
---@param opts? { session?: table|string, cwd?: string, force_new?: boolean, once?: boolean }
---@param cb? fun(err?: string)
function M.open(opts, cb)
  launch.open(opts, cb)
end

---Open the TUI, or close its window when it is already open.
---@param opts? { session?: table|string, cwd?: string, force_new?: boolean }
---@param cb? fun(err?: string, closed?: boolean)
function M.toggle(opts, cb)
  launch.toggle(opts, cb)
end

---Statusline component, e.g. `%{%v:lua.eix_statusline()%}`.
---@return string
function M.statusline()
  return events.statusline()
end

_G.eix_statusline = function()
  return M.statusline()
end

return M
