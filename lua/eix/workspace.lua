---Project directory used to pick a session and start the TUI.
---
---The workspace is the git root of the file in the current buffer. When that
---file is not inside a git repository, it is the file's own directory. Buffers
---without a file (scratch, terminal, …) fall back to Neovim's working directory.
local M = {}

---@param dir string
---@return string?
local function git_root(dir)
  if vim.fn.executable("git") ~= 1 then
    return nil
  end
  local out = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local root = out and out[1]
  if not root or root == "" then
    return nil
  end
  return vim.fs.normalize(root)
end

---Workspace of a buffer.
---@param buf? integer
---@return string
function M.cwd(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return vim.fn.getcwd()
  end

  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return vim.fn.getcwd()
  end

  local file = vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
  local dir = vim.fn.fnamemodify(file, ":h")
  return git_root(dir) or dir
end

return M
