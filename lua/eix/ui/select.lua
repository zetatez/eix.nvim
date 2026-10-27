---Prompt picker for `select()`.
local config = require("eix.config")

local M = {}

---@class eix.select.Item
---@field label string
---@field run fun()

---Use fzf-lua when it is installed and `fzf` is available.
---@return table?
local function fzf()
  if vim.fn.executable("fzf") ~= 1 then
    return nil
  end
  local ok, mod = pcall(require, "fzf-lua")
  if ok and type(mod.fzf_exec) == "function" then
    return mod
  end
  return nil
end

---@param items eix.select.Item[]
---@param prompt string
---@param cb fun(item: eix.select.Item)
local function choose(items, prompt, cb)
  local by_label = {}
  local labels = {}
  for _, item in ipairs(items) do
    labels[#labels + 1] = item.label
    by_label[item.label] = item
  end

  local fz = fzf()
  if fz then
    fz.fzf_exec(labels, {
      prompt = prompt .. "> ",
      actions = {
        ["enter"] = function(selected)
          local item = selected and by_label[selected[1]]
          if item then
            vim.schedule(function()
              cb(item)
            end)
          end
        end,
      },
    })
    return
  end

  vim.ui.select(items, {
    prompt = prompt,
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if item then
      cb(item)
    end
  end)
end

---@class eix.select.Actions
---@field ask fun()
---@field prompt fun(text: string)
---@field open fun()

---Open the main picker.
---@param actions eix.select.Actions
function M.open(actions)
  local items = {
    { label = "Ask freely…", run = actions.ask },
  }

  local prompts = {}
  for name, text in pairs(config.opts.select.prompts or {}) do
    prompts[#prompts + 1] = {
      label = name,
      run = function()
        actions.prompt(text)
      end,
    }
  end
  table.sort(prompts, function(a, b)
    return a.label:lower() < b.label:lower()
  end)
  vim.list_extend(items, prompts)

  items[#items + 1] = { label = "Open eix", run = actions.open }

  choose(items, "eix", function(item)
    item.run()
  end)
end

return M
