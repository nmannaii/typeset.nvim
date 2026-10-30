-- typeset.nvim: a live, typeset preview of markdown in a split, rendered by a standalone renderer
-- (typst + a Rust mermaid port, fonts embedded) and drawn with kitty graphics placeholders.
-- No browser, no node.
local M = {}

local config = require("typeset.config")

local function preview()
  return require("typeset.preview")
end

---@param opts? typeset.Config
function M.setup(opts)
  config.set(opts)
  local group = vim.api.nvim_create_augroup("typeset", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      require("typeset.theme").reset()
      require("typeset.images").refresh_hl()
      preview().refresh()
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      require("typeset.terminal").reset() -- a terminal zoom changes the cell size too
      preview().refresh()
    end,
  })
  vim.api.nvim_create_autocmd("VimResume", {
    group = group,
    callback = function()
      require("typeset.images").forget_transmitted()
      preview().refresh()
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      require("typeset.images").clear_terminal()
      require("typeset.renderer").stop()
    end,
  })
end

--- Why the preview can't be shown here, or nil when it can.
function M.unsupported()
  return require("typeset.terminal").unsupported()
end

--- Open or close the preview.
function M.toggle()
  local why = M.unsupported()
  if why and not preview().is_open() then
    vim.notify("typeset: " .. why, vim.log.levels.WARN)
    return
  end
  preview().toggle()
end

return M
