---Editor context injected into prompts through `@placeholders`.
local M = {}

local config = require("eix.config")

local ns = vim.api.nvim_create_namespace("eix-context")

---@class eix.Context.Range
---@field from integer[] { line (1-based), col (0-based) }
---@field to integer[] { line (1-based), col (0-based) }
---@field kind "char"|"line"|"block"

---@class eix.Context
---@field buf integer
---@field win integer
---@field cursor integer[]
---@field cwd string
---@field range? eix.Context.Range
---@field mark? integer Extmark that keeps the range highlighted while a prompt is open.
local Context = {}
Context.__index = Context

---@param text string
---@return string[]
local function split(text)
  if text == "" then
    return { "" }
  end
  return vim.split(text, "\n", { plain = true })
end

---Cut `text` to at most `max_bytes` bytes without splitting a UTF-8 character.
---@param text string
---@param max_bytes integer
---@return string
local function head_bytes(text, max_bytes)
  if max_bytes <= 0 or #text <= max_bytes then
    return text
  end
  local cut = max_bytes
  -- UTF-8 continuation bytes are 0x80-0xBF. Back off until the next byte starts
  -- a fresh character, then the kept prefix ends on a character boundary.
  while cut > 0 do
    local byte = text:byte(cut + 1)
    if not byte or byte < 0x80 or byte > 0xBF then
      break
    end
    cut = cut - 1
  end
  return text:sub(1, cut)
end

---@param text string
---@param max_lines number
---@param max_bytes number
---@return string
local function cap(text, max_lines, max_bytes)
  if max_bytes > 0 and #text > max_bytes then
    text = head_bytes(text, max_bytes) .. "\n… (truncated)"
  end
  local lines = split(text)
  if max_lines > 0 and #lines > max_lines then
    local omitted = #lines - max_lines
    lines = vim.list_slice(lines, 1, max_lines)
    table.insert(lines, ("… (%d more line(s))"):format(omitted))
  end
  return table.concat(lines, "\n")
end

---@param buf integer
---@return string?
local function buffer_path(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  return vim.fn.fnamemodify(name, ":p")
end

---@param path string
---@param cwd string
---@return string
local function relative(path, cwd)
  local normalized = vim.fs.normalize(path)
  local root = vim.fs.normalize(cwd)
  local prefix = root:match("/$") and root or (root .. "/")
  if normalized:find(prefix, 1, true) == 1 then
    return normalized:sub(#prefix + 1)
  end
  return normalized
end

---@param col integer
---@return string
local function column(col)
  if col == math.huge then
    return ""
  end
  return ("C%d"):format(col + 1)
end

---@param from integer[]
---@param to integer[]?
---@return string
local function location(from, to)
  if to and to[2] == math.huge then
    return ("L%d-L%d"):format(from[1], to[1])
  end
  local from_col = column(from[2])
  local out = ("L%d"):format(from[1]) .. (from_col ~= "" and (":" .. from_col) or "")
  if to then
    local to_col = column(to[2])
    out = out .. ("-L%d"):format(to[1]) .. (to_col ~= "" and (":" .. to_col) or "")
  end
  return out
end

---@param buf integer
---@param from_line integer
---@param from_col integer
---@param to_line integer
---@param to_col integer
---@param kind? "char"|"line"|"block"
---@return string[]
local function get_range(buf, from_line, from_col, to_line, to_col, kind)
  local lines = vim.api.nvim_buf_get_lines(buf, from_line - 1, to_line, false)
  if #lines == 0 then
    return { "" }
  end
  if kind == "block" then
    local first = from_col + 1
    local last = to_col + 1
    for index, value in ipairs(lines) do
      lines[index] = value:sub(first, last)
    end
    return lines
  end
  if #lines == 1 then
    local last = math.min(to_col, math.max(#lines[1] - 1, 0))
    return { lines[1]:sub(from_col + 1, last + 1) }
  end
  lines[1] = lines[1]:sub(from_col + 1)
  local last = math.min(to_col, math.max(#lines[#lines] - 1, 0))
  lines[#lines] = lines[#lines]:sub(1, last + 1)
  return lines
end

---@param buf integer
---@return string
local function filetype(buf)
  local ft = vim.bo[buf].filetype
  if ft == "" then
    return "text"
  end
  return ft
end

---@param lang string
---@param body string
---@return string
local function fence(lang, body)
  return ("```%s\n%s\n```"):format(lang, body)
end

---@param buf integer
---@param from integer[]
---@param to integer[]
---@param cwd string
---@param kind? "char"|"line"|"block"
---@return string
local function range_context(buf, from, to, cwd, kind)
  local text = table.concat(get_range(buf, from[1], from[2], to[1], to[2], kind), "\n")
  local path = buffer_path(buf)
  local label = (path and relative(path, cwd) or "buffer") .. ":" .. location(from, to)
  return label .. "\n" .. fence(filetype(buf), text)
end

---@return eix.Context.Range?
local function visual_selection(buf)
  local mode = vim.fn.mode()
  local kind = (mode == "V" and "line") or (mode == "v" and "char") or (mode == "\22" and "block")
  if not kind then
    return nil
  end

  -- Leave visual mode first so `<` and `>` are updated for the selection.
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "x", false)

  local from = vim.api.nvim_buf_get_mark(buf, "<")
  local to = vim.api.nvim_buf_get_mark(buf, ">")
  if from[1] == 0 or to[1] == 0 then
    return nil
  end
  if from[1] > to[1] or (from[1] == to[1] and from[2] > to[2]) then
    from, to = to, from
  end
  if kind == "block" and from[2] > to[2] then
    from[2], to[2] = to[2], from[2]
  end
  return { from = { from[1], from[2] }, to = { to[1], to[2] }, kind = kind }
end

---@param buf integer
---@param range eix.Context.Range
---@return integer? mark_id
local function highlight(buf, range)
  local row = range.from[1] - 1
  local end_row = range.kind == "line" and range.to[1] or (range.to[1] - 1)
  local line = vim.api.nvim_buf_get_lines(buf, end_row, end_row + 1, false)[1] or ""
  local end_col = range.kind == "line" and nil or math.min(range.to[2] + 1, #line)
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, range.from[2], {
    end_row = end_row,
    end_col = end_col,
    hl_group = "Visual",
  })
  return ok and id or nil
end

---Create a context before opening a prompt UI.
---@param opts? { range?: eix.Context.Range, cwd?: string, win?: integer }
---@return eix.Context
function M.new(opts)
  opts = opts or {}
  local win = opts.win or vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local cwd = opts.cwd or require("eix.workspace").cwd(buf)
  local self = setmetatable({
    buf = buf,
    win = win,
    cursor = vim.api.nvim_win_get_cursor(win),
    cwd = vim.fs.normalize(vim.fn.fnamemodify(cwd, ":p")),
    range = opts.range or visual_selection(buf),
  }, Context)
  if self.range then
    self.mark = highlight(buf, self.range)
  end
  M.current = self
  return self
end

function Context:clear()
  if self.mark and vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_del_extmark, self.buf, ns, self.mark)
    self.mark = nil
  end
  if M.current == self then
    M.current = nil
  end
end

function Context:resume()
  self:clear()
  if self.range and vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_set_current_win, self.win)
    pcall(vim.cmd, "normal! gv")
  end
end

---@param buf integer
---@return string
function Context:buffer_placeholder(buf)
  local path = buffer_path(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if path then
    local label = relative(path, self.cwd)
    return label
      .. ":"
      .. location({ 1, 0 }, { #lines, math.max(0, (#lines[#lines] or 1) - 1) })
      .. "\n"
      .. fence(filetype(buf), table.concat(lines, "\n"))
  end
  return "Current buffer\n" .. fence(filetype(buf), table.concat(lines, "\n"))
end

---@return string
function Context:this()
  if self.range then
    return range_context(self.buf, self.range.from, self.range.to, self.cwd, self.range.kind)
  end
  local line = self.cursor[1]
  local text = vim.api.nvim_buf_get_lines(self.buf, line - 1, line, false)[1] or ""
  local path = buffer_path(self.buf)
  local label = (path and relative(path, self.cwd) or "buffer") .. ":" .. location({ line, self.cursor[2] })
  return label .. "\n" .. fence(filetype(self.buf), text)
end

---@return string
function Context:buffers()
  local paths = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
      local path = buffer_path(buf)
      if path then
        table.insert(paths, relative(path, self.cwd))
      end
    end
  end
  if #paths == 0 then
    return "No file-backed buffers are open."
  end
  return "Open buffers:\n" .. table.concat(paths, "\n")
end

---@return string
function Context:diagnostics()
  local diagnostics = vim.diagnostic.get(self.buf)
  if self.range then
    diagnostics = vim.tbl_filter(function(d)
      return not (d.lnum + 1 > self.range.to[1] or d.end_lnum + 1 < self.range.from[1])
    end, diagnostics)
  end
  local path = buffer_path(self.buf)
  local label = path and relative(path, self.cwd) or "buffer"
  if #diagnostics == 0 then
    return "No diagnostics for " .. label .. "."
  end
  local severities = { "error", "warning", "info", "hint" }
  local lines = { "Diagnostics for " .. label .. ":" }
  for _, d in ipairs(diagnostics) do
    table.insert(
      lines,
      ("- %s:%d:%d: [%s] %s"):format(
        label,
        d.lnum + 1,
        d.col + 1,
        severities[d.severity] or tostring(d.severity),
        vim.trim((d.message or ""):gsub("\n", " "))
      )
    )
  end
  return table.concat(lines, "\n")
end

---@return string
function Context:quickfix()
  local list = vim.fn.getqflist()
  if #list == 0 then
    return "Quickfix list is empty."
  end
  local lines = { "Quickfix entries:" }
  for _, entry in ipairs(list) do
    local path = entry.bufnr ~= 0 and buffer_path(entry.bufnr) or nil
    if path then
      table.insert(
        lines,
        ("- %s:L%d:C%d: %s"):format(relative(path, self.cwd), entry.lnum, math.max(1, entry.col), entry.text or "")
      )
    end
  end
  if #lines == 1 then
    return "Quickfix list has no file-backed entries."
  end
  return table.concat(lines, "\n")
end

---@return string
function Context:visible()
  local chunks = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local from = vim.fn.line("w0", win)
    local to = vim.fn.line("w$", win)
    if from > 0 and to >= from and not is_eix_buffer(buf) then
      table.insert(chunks, range_context(buf, { from, 0 }, { to, math.huge }, self.cwd, "line"))
    end
  end
  if #chunks == 0 then
    return "No visible text."
  end
  return table.concat(chunks, "\n\n")
end

---@return string
function Context:diff()
  local cwd = self.cwd
  local lines = vim.fn.systemlist({ "git", "-C", cwd, "diff", "--no-color", "HEAD", "--", "." })
  if vim.v.shell_error ~= 0 or #lines == 0 then
    lines = vim.fn.systemlist({ "git", "-C", cwd, "diff", "--no-color", "--", "." })
  end
  if vim.v.shell_error ~= 0 then
    return "No git diff available for " .. cwd .. "."
  end
  if #lines == 0 then
    return "No uncommitted git diff."
  end
  return "Uncommitted diff in " .. cwd .. ":\n" .. fence("diff", table.concat(lines, "\n"))
end

---@return table<string, fun(self: eix.Context): string>
local placeholders = {
  ["@this"] = Context.this,
  ["@buffer"] = function(self)
    return self:buffer_placeholder(self.buf)
  end,
  ["@buffers"] = Context.buffers,
  ["@diagnostics"] = Context.diagnostics,
  ["@quickfix"] = Context.quickfix,
  ["@visible"] = Context.visible,
  ["@diff"] = Context.diff,
}

---Names available to completion and docs.
---@return string[]
function M.names()
  local names = {}
  for name in pairs(placeholders) do
    if config.opts.context.placeholders[name] ~= false then
      table.insert(names, name)
    end
  end
  table.sort(names, function(a, b)
    return #a > #b
  end)
  return names
end

---Find a placeholder that starts on a word boundary. `mail@this.example`
---and `@buffers2` must not expand.
---@param text string
---@param name string
---@param init integer
---@return integer?
local function find_placeholder(text, name, init)
  local pos = init
  while true do
    local found = text:find(name, pos, true)
    if not found then
      return nil
    end
    local before = found > 1 and text:sub(found - 1, found - 1) or ""
    local after = text:sub(found + #name, found + #name)
    if not before:match("[%w_]") and not after:match("[%w_]") then
      return found
    end
    pos = found + 1
  end
end

---Expand enabled placeholders in a prompt.
---@param text string
---@return string
function Context:render(text)
  local enabled = {}
  for name, enabled_placeholder in pairs(config.opts.context.placeholders) do
    if enabled_placeholder ~= false and placeholders[name] then
      table.insert(enabled, name)
    end
  end
  table.sort(enabled, function(a, b)
    return #a > #b
  end)

  local out = {}
  local i = 1
  while i <= #text do
    local next_pos, next_name = #text + 1, nil
    for _, name in ipairs(enabled) do
      local pos = find_placeholder(text, name, i)
      if pos and pos < next_pos then
        next_pos, next_name = pos, name
      end
    end

    if next_pos > i then
      table.insert(out, text:sub(i, next_pos - 1))
    end
    if not next_name then
      break
    end

    local ok, value = pcall(placeholders[next_name], self)
    if ok and type(value) == "string" and value ~= "" then
      table.insert(out, cap(value, config.opts.context.max_lines, config.opts.context.max_bytes))
    else
      table.insert(out, next_name)
    end
    i = next_pos + #next_name
  end
  return table.concat(out)
end

---Format a file location the same way `@this` does.
---@param opts { path?: string, buf?: integer, from?: integer[], to?: integer[], cwd?: string }
---@return string?
function M.format(opts)
  local path = opts.path
  if not path and opts.buf then
    path = buffer_path(opts.buf)
  end
  if not path or path == "" then
    return nil
  end
  local cwd = opts.cwd or vim.fn.getcwd()
  local label = relative(path, cwd)
  if opts.from then
    return label .. ":" .. location(opts.from, opts.to)
  end
  return label
end

return M
