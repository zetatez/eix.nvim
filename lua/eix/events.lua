---Notification fan-out, autocmds and statusline state.
local config = require("eix.config")

local M = {}

---@class eix.State
---@field connected boolean
---@field endpoint? string
---@field session? table
---@field status string
---@field turn_id? string
---@field error? string
---@field model? string
---@field protocol? integer
---@field version? string
M.state = {
  connected = false,
  status = "idle",
}

---@type table<string, fun(...): any[]>
local listeners = {}

---Subscribe to an internal event.
---@param name string
---@param fn fun(...): any
---@return fun() unsubscribe
function M.on(name, fn)
  listeners[name] = listeners[name] or {}
  table.insert(listeners[name], fn)
  return function()
    M.off(name, fn)
  end
end

---@param name string
---@param fn fun(...): any
function M.off(name, fn)
  local list = listeners[name]
  if not list then
    return
  end
  for i = #list, 1, -1 do
    if list[i] == fn then
      table.remove(list, i)
    end
  end
end

---@param name string
---@param ... any
function M.emit(name, ...)
  local list = listeners[name]
  if not list then
    return
  end
  for _, fn in ipairs(vim.deepcopy(list)) do
    local ok, err = pcall(fn, ...)
    if not ok then
      vim.schedule(function()
        vim.notify("eix: event handler error: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  end
end

---@param enabled boolean
local function redraw(enabled)
  if enabled then
    pcall(vim.cmd, "redrawstatus")
  end
end

---@param message string
---@param level integer
local function notify(message, level)
  if config.opts.notifications == false then
    return
  end
  vim.schedule(function()
    vim.notify(message, level)
  end)
end

---@param session? table
function M.set_session(session)
  M.state.session = session
  if session then
    M.state.status = session.status or M.state.status
    M.state.model = session.model
  end
  redraw(true)
end

---@param status string
function M.set_status(status)
  M.state.status = status
  redraw(true)
end

---@param message table
function M.dispatch(message)
  local method = message.method
  local params = message.params or {}

  -- Keep the small amount of state the statusline and notifications need.
  -- Turn events for other sessions must not overwrite the active session's
  -- status.
  local active = not M.state.session or (M.state.session.id == params.session_id)
  if method == "turn.started" then
    if active then
      M.state.status = "running"
      M.state.turn_id = params.turn_id
      M.state.error = nil
      redraw(true)
    end
  elseif method == "turn.completed" then
    if active then
      if params.error and params.error ~= vim.NIL then
        M.state.status = "error"
        M.state.error = tostring(params.error)
      else
        M.state.status = "idle"
        M.state.error = nil
      end
      M.state.turn_id = nil
      redraw(true)
    end
    if params.error and params.error ~= vim.NIL then
      notify("eix: " .. tostring(params.error), vim.log.levels.ERROR)
    end
  elseif method == "session.updated" then
    if M.state.session and M.state.session.id == params.id then
      M.state.session = params
      M.state.status = params.status or M.state.status
      M.state.model = params.model
      redraw(true)
    end
  elseif method == "session.attention" then
    if M.state.session and M.state.session.id == params.session_id then
      M.state.status = params.status or M.state.status
      redraw(true)
    end
  elseif method == "tool.approval_required" or method == "patch.proposed" then
    if M.state.session and M.state.session.id == params.session_id then
      M.state.status = "awaiting_approval"
      redraw(true)
    end
    notify(
      ("eix: %s needs approval%s"):format(
        tostring(params.tool or params.path or "a tool"),
        params.summary and (" · " .. tostring(params.summary)) or ""
      ),
      vim.log.levels.WARN
    )
  elseif method == "input.required" then
    if M.state.session and M.state.session.id == params.session_id then
      M.state.status = "awaiting_input"
      redraw(true)
    end
    notify("eix: the agent asked a question", vim.log.levels.WARN)
  elseif method == "stream.lagged" then
    notify(
      ("eix: stream lagged, %s event(s) may be missing; re-syncing"):format(tostring(params.skipped or "?")),
      vim.log.levels.WARN
    )
  elseif method == "config.error" then
    notify("eix config: " .. tostring(params.error or "reload failed"), vim.log.levels.ERROR)
  elseif method == "integration.attention" then
    notify(
      ("eix integration: %s"):format(tostring(params.error or params.session_name or "needs attention")),
      vim.log.levels.WARN
    )
  elseif method == "session.event" then
    if M.state.session and M.state.session.id == params.session_id then
      if params.kind == "status_changed" and params.payload and params.payload.to then
        M.state.status = params.payload.to
        M.state.session.status = params.payload.to
        redraw(true)
      elseif params.kind == "mode" and params.payload and params.payload.to then
        M.state.session.mode = params.payload.to
        redraw(true)
      end
    end
  end

  M.emit("notification", message)
  M.emit(method, params)
  if method == "session.event" then
    M.emit("event", params)
    M.emit("event:" .. tostring(params.kind), params)
  end

  -- Autocmds are intentionally not emitted for token-level deltas; user
  -- handlers get those through `events.on("message.delta", ...)` instead.
  if method ~= "message.delta" and method ~= "reasoning.delta" then
    local acmd = ({
      ["turn.completed"] = "EixTurnCompleted",
      ["tool.approval_required"] = "EixApprovalRequired",
      ["patch.proposed"] = "EixPatchProposed",
      ["input.required"] = "EixInputRequired",
      ["session.updated"] = "EixSessionUpdated",
      ["stream.lagged"] = "EixStreamLagged",
      ["session.event"] = "EixSessionEvent",
    })[method]
    local data = { method = method, params = params }
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "EixEvent", data = data })
    if acmd then
      pcall(vim.api.nvim_exec_autocmds, "User", { pattern = acmd, data = data })
    end
  end
end

local STATUS = {
  idle = { icon = "○", group = "EixStatusIdle" },
  running = { icon = "●", group = "EixStatusRunning" },
  awaiting_approval = { icon = "⚠", group = "EixStatusAttention" },
  awaiting_input = { icon = "◐", group = "EixStatusAttention" },
  error = { icon = "✗", group = "EixStatusError" },
  paused = { icon = "◌", group = "EixStatusPaused" },
}

---@param text string
---@return string
local function escape(text)
  return tostring(text):gsub("%%", "%%%%")
end

---Statusline component. Safe to call when eix is not connected.
---@return string
function M.statusline()
  if not M.state.connected or not M.state.session then
    return ""
  end
  local status = STATUS[M.state.status] or STATUS.idle
  local session = M.state.session
  local model = session.model or M.state.model or "default"
  local mode = session.mode or "build"
  return table.concat({
    "%#" .. status.group .. "#" .. status.icon .. " eix",
    "%#EixStatusName# " .. escape(session.name or session.id or ""),
    "%#EixStatusMeta# " .. escape(mode) .. " · " .. escape(model),
    "%#EixStatusMeta# %*",
  })
end

return M
