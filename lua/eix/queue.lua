---Client-side prompt queue.
---
---The daemon refuses `prompt.submit` while a turn is running, and the TUI's
---queue lives in the TUI process. Prompts sent from Neovim while a session is
---busy are kept here and flushed one at a time when the session goes idle.
local events = require("eix.events")

local M = {
  ---@type table<string, string[]> Pending prompts per session, oldest first.
  queues = {},
  ---@type table<string, boolean> Sessions with a flush already in flight.
  inflight = {},
  ---@type fun(session_id: string, text: string, cb: fun(err?: string))|nil
  sender = nil,
}

---@param message string
---@param level? integer
local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "eix" })
end

---Whether an RPC error means "a turn is already running".
---@param err? string
---@return boolean
function M.is_busy(err)
  if type(err) ~= "string" then
    return false
  end
  return err:find("busy", 1, true) ~= nil or err:find("already running", 1, true) ~= nil
end

---@param session_id string
---@return integer
function M.len(session_id)
  return #(M.queues[session_id] or {})
end

---@param session_id string
---@return string?
function M.peek(session_id)
  local queue = M.queues[session_id]
  return queue and queue[1] or nil
end

---Drop the oldest prompt for a session.
---@param session_id string
---@return string?
function M.pop(session_id)
  local queue = M.queues[session_id]
  if not queue then
    return nil
  end
  local text = table.remove(queue, 1)
  if #queue == 0 then
    M.queues[session_id] = nil
  end
  return text
end

---Append a prompt to a session's queue.
---@param session_id string
---@param text string
---@return integer len
function M.push(session_id, text)
  local queue = M.queues[session_id]
  if not queue then
    queue = {}
    M.queues[session_id] = queue
  end
  queue[#queue + 1] = text
  return #queue
end

---@param session_id string
function M.clear(session_id)
  M.queues[session_id] = nil
  M.inflight[session_id] = nil
end

---Send the oldest queued prompt for a session, if any.
---A `busy` race leaves the prompt at the head so the next idle event retries.
---@param session_id? string
---@return boolean attempted
function M.flush(session_id)
  if not session_id or M.inflight[session_id] or not M.sender then
    return false
  end
  local text = M.peek(session_id)
  if not text then
    return false
  end

  M.inflight[session_id] = true
  M.sender(session_id, text, function(err)
    M.inflight[session_id] = nil
    if not err then
      M.pop(session_id)
      return
    end
    if M.is_busy(err) then
      -- The turn we queued behind is still finishing; keep the prompt.
      return
    end
    -- The prompt can never be delivered (deleted session, bad params, …).
    -- Drop it so the queue cannot stall.
    M.pop(session_id)
    notify("eix: " .. err, vim.log.levels.ERROR)
  end)
  return true
end

events.on("turn.completed", function(params)
  M.flush(params and params.session_id)
end)

events.on("session.updated", function(params)
  if params and params.id and (params.status == nil or params.status == "idle") then
    M.flush(params.id)
  end
end)

events.on("session.deleted", function(params)
  local id = params and (params.session_id or params.id)
  if id then
    M.clear(id)
  end
end)

-- After a reconnect the daemon may be idle again, so retry what is left.
events.on("connected", function()
  for session_id in pairs(M.queues) do
    M.flush(session_id)
  end
end)

return M
