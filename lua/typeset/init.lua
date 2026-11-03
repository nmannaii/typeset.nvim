-- typeset.nvim: a live, typeset preview of markdown in a split, rendered by a standalone renderer
-- (typst + a Rust mermaid port, fonts embedded) and drawn with kitty graphics placeholders.
-- No browser, no node.
local M = {}

local config = require("typeset.config")

local function preview()
  return require("typeset.preview")
end

--- Re-render everything shown: the preview and the inline buffers.
local function refresh()
  preview().refresh()
  require("typeset.inline").refresh()
end

local function is_markdown(buf)
  return vim.tbl_contains(config.get().filetypes, vim.bo[buf].filetype)
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
      refresh()
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      require("typeset.terminal").reset() -- a terminal zoom changes the cell size too
      require("typeset.images").forget_transmitted()
      refresh()
    end,
  })
  vim.api.nvim_create_autocmd("VimResume", {
    group = group,
    callback = function()
      require("typeset.images").forget_transmitted()
      refresh()
    end,
  })
  if config.get().inline.enabled then
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = config.get().filetypes,
      callback = function(ev)
        require("typeset.inline").attach(ev.buf)
      end,
    })
    -- Buffers that got their filetype before setup (lazy-loading on `ft` does that).
    vim.schedule(function()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and is_markdown(buf) then
          require("typeset.inline").attach(buf)
        end
      end
    end)
  end
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
