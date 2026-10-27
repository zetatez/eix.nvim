---eix.nvim commands, <Plug> mappings and statusline highlights.
local eix = require("eix")

---@param name string
---@param fn fun(args: table)
---@param opts? table
local function cmd(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, vim.tbl_extend("force", { force = true }, opts or {}))
end

---@param from_line integer
---@param from_col integer
---@param to_line integer
---@param to_col integer
---@param kind string
---@return eix.Context.Range
local function make_range(from_line, from_col, to_line, to_col, kind)
  from_col, to_col = math.max(0, from_col), math.max(0, to_col)
  if from_line > to_line or (from_line == to_line and from_col > to_col) then
    from_line, to_line = to_line, from_line
    from_col, to_col = to_col, from_col
  end
  if kind == "block" and from_col > to_col then
    from_col, to_col = to_col, from_col
  end
  if kind == "line" then
    from_col, to_col = 0, math.huge
  end
  return { from = { from_line, from_col }, to = { to_line, to_col }, kind = kind }
end

---@return eix.Context.Range?
local function visual_range()
  local from = vim.fn.getpos("'<")
  local to = vim.fn.getpos("'>")
  if from[2] == 0 or to[2] == 0 then
    return nil
  end
  local mode = vim.fn.visualmode()
  local kind = (mode == "V" and "line") or (mode == "\22" and "block") or "char"
  return make_range(from[2], from[3] - 1, to[2], to[3] - 1, kind)
end

---@return eix.Context.Range?
local function current_visual_range()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return visual_range()
  end
  local from = vim.fn.getpos("v")
  local to = vim.fn.getpos(".")
  if from[2] == 0 or to[2] == 0 then
    return nil
  end
  local kind = (mode == "V" and "line") or (mode == "\22" and "block") or "char"
  return make_range(from[2], from[3] - 1, to[2], to[3] - 1, kind)
end

---@param args table
---@return eix.Context.Range?
local function command_range(args)
  if args.range <= 0 then
    return nil
  end
  if args.range == 2 then
    local range = visual_range()
    if range and range.from[1] == args.line1 and range.to[1] == args.line2 then
      return range
    end
  end
  return {
    from = { args.line1, 0 },
    to = { args.line2, math.huge },
    kind = "line",
  }
end

cmd("Eix", function(args)
  eix.toggle({ session = args.args ~= "" and args.args or nil })
end, { nargs = "?", desc = "eix: toggle the TUI terminal" })

cmd("EixAsk", function(args)
  local range = command_range(args)
  local text = args.args
  if range and text ~= "" and not text:find("@", 1, true) then
    text = "@this: " .. text
  end
  if text == "" then
    text = "@this: "
  end
  eix.ask(text, range)
end, { nargs = "*", range = true, desc = "eix: ask in a floating prompt" })

cmd("EixSelect", function()
  eix.select()
end, { desc = "eix: choose a prompt" })

--============================================================================
-- <Plug> mappings
--============================================================================

vim.keymap.set("n", "<Plug>(EixAsk)", function()
  eix.ask("@this: ")
end, { silent = true, desc = "eix: ask about this" })

vim.keymap.set("x", "<Plug>(EixAsk)", function()
  local range = current_visual_range()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  eix.ask("@this: ", range)
end, { silent = true, desc = "eix: ask about the selection" })

vim.keymap.set("n", "<Plug>(EixSelect)", function()
  eix.select()
end, { silent = true, desc = "eix: select" })

vim.keymap.set("x", "<Plug>(EixSelect)", function()
  eix.select()
end, { silent = true, desc = "eix: select" })

vim.keymap.set("n", "<Plug>(EixOperator)", function()
  return eix.operator("@this")
end, { expr = true, silent = true, desc = "eix: send range" })

vim.keymap.set("n", "<Plug>(EixToggle)", function()
  eix.toggle()
end, { silent = true, desc = "eix: toggle the TUI" })

--============================================================================
-- Highlights
--============================================================================

local HIGHLIGHTS = {
  EixStatusIdle = "Comment",
  EixStatusRunning = "DiagnosticOk",
  EixStatusAttention = "DiagnosticWarn",
  EixStatusError = "DiagnosticError",
  EixStatusPaused = "DiagnosticInfo",
  EixStatusName = "Title",
  EixStatusMeta = "Comment",
}

local function apply_highlights()
  for group, link in pairs(HIGHLIGHTS) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

apply_highlights()
local group = vim.api.nvim_create_augroup("eix-highlights", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = apply_highlights,
})
