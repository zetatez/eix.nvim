---Session resolution shared by the API and the TUI launcher.
local client = require("eix.client")
local workspace = require("eix.workspace")

local M = {}

---@param message string
---@param level? integer
local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "eix" })
end

---Resolve a session reference into a session table.
---@param ref? table|string
---@param cb fun(session?: table)
---@param opts? { cwd?: string, force_new?: boolean }
function M.resolve(ref, cb, opts)
  if type(ref) == "table" then
    cb(ref)
    return
  end
  if type(ref) == "string" then
    local cached = client.session(ref)
    if cached then
      cb(cached)
      return
    end
    client.request("session.get", { session_id = ref }, function(err, result)
      if err then
        notify("eix: " .. err, vim.log.levels.ERROR)
        cb(nil)
        return
      end
      local found = result and result.session
      if found then
        client.state.sessions[found.id] = found
      end
      cb(found)
    end)
    return
  end
  opts = opts or {}
  if opts.cwd == nil then
    opts = vim.tbl_extend("keep", opts, { cwd = workspace.cwd() })
  end
  client.resolve_session(opts, function(err, found)
    if err then
      notify("eix: " .. err, vim.log.levels.ERROR)
      cb(nil)
      return
    end
    cb(found)
  end)
end

---@param session table
function M.activate(session)
  client.set_active_session(session)
end

return M
