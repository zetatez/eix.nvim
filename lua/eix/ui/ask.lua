---Small floating prompt used by `ask()`.
local config = require("eix.config")

local M = {
  state = {
    buf = nil,
    win = nil,
    prev_win = nil,
    on_submit = nil,
    on_cancel = nil,
  },
}

---@param win? integer
---@return boolean
local function valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---@return boolean
function M.is_open()
  return valid(M.state.win)
end

---@return string
function M.value()
  local buf = M.state.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return ""
  end
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

function M.close()
  local state = M.state
  local win, buf = state.win, state.buf
  state.win, state.buf, state.on_submit, state.on_cancel = nil, nil, nil, nil
  if valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  if valid(state.prev_win) then
    pcall(vim.api.nvim_set_current_win, state.prev_win)
  end
  state.prev_win = nil
  pcall(vim.cmd, "stopinsert")
end

function M.cancel()
  local on_cancel = M.state.on_cancel
  M.close()
  if on_cancel then
    on_cancel()
  end
end

function M.submit()
  local buf = M.state.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local text = M.value()
  local on_submit = M.state.on_submit
  M.close()
  if on_submit then
    on_submit(text)
  end
end

---@param buf integer
local function bind(buf)
  vim.keymap.set({ "i", "n" }, "<CR>", M.submit, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set({ "i", "n" }, "<Esc>", M.cancel, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set({ "i", "n" }, "<C-c>", M.cancel, { buffer = buf, silent = true, nowait = true })
end

---Open the prompt. `on_submit` receives the raw text and can be empty.
---`on_cancel` runs when the prompt is dismissed, so callers can drop the
---highlight or context they prepared for it.
---@param default? string
---@param on_submit fun(text: string)
---@param on_cancel? fun()
function M.open(default, on_submit, on_cancel)
  if M.is_open() then
    M.cancel()
  end

  local lines = vim.split(default or "", "\n", { plain = true })
  local height = math.max(1, math.min(#lines, 5))
  local width = math.max(24, math.min(vim.o.columns - 8, math.floor(vim.o.columns * (config.opts.ask.width or 0.4))))
  local above = vim.fn.winline() > height + 2

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].filetype = "eix-ask"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  M.state.prev_win = vim.api.nvim_get_current_win()
  M.state.buf = buf
  M.state.on_submit = on_submit
  M.state.on_cancel = on_cancel

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = above and -(height + 1) or 2,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " eix ",
    title_pos = "left",
  })
  M.state.win = win

  -- Also clean up when the float is closed without going through cancel().
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if M.state.win == win then
        M.cancel()
      end
    end,
  })

  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false

  bind(buf)
  vim.api.nvim_win_set_cursor(win, { #lines, #lines[#lines] })
  vim.cmd("startinsert!")
end

return M
