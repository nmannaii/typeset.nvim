local M = {}

---@class typeset.Config
local defaults = {
  filetypes = { "markdown" },
  -- The preview split.
  preview = {
    position = "right", ---@type "left"|"right"|"above"|"below"
    size = 0.45, -- fraction of the editor (<= 1) or columns / lines
  },
  max_width = 120, -- cells; images never get wider than this, even in wide windows
  text_scale = 0.72, -- body text size as a fraction of the cell height
  debounce = 150, -- ms after the last edit before the preview re-renders
  cell = nil, ---@type integer[]? { width, height } in pixels; nil = measured from the terminal
  font = "Inter", -- embedded in the renderer: Inter, Libertinus Serif, New Computer Modern
  mono_font = "DejaVu Sans Mono",
  theme = nil, ---@type table|fun(theme: table): table? overrides for the colours taken from highlights
  binary = nil, ---@type string? path to typeset-renderer; nil = the one installed with the plugin
  -- Where `:TypesetInstall` downloads prebuilt binaries (GitHub releases); cargo builds otherwise.
  repo = "nmannaii/typeset.nvim", ---@type string?
}

---@type typeset.Config
local config = vim.deepcopy(defaults)

---@param opts? typeset.Config
function M.set(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  -- Lists are replaced, not merged index by index.
  if opts and opts.filetypes then
    config.filetypes = opts.filetypes
  end
end

---@return typeset.Config
function M.get()
  return config
end

return M
