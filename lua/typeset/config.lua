local M = {}

---@class typeset.Config
local defaults = {
  filetypes = { "markdown" },
  -- The preview split.
  preview = {
    position = "right", ---@type "left"|"right"|"above"|"below"
    size = 0.45, -- fraction of the editor (<= 1) or columns / lines
  },
  -- The reading overlay (:Typeset overlay): the buffer typeset over the whole editor.
  overlay = {
    width = 110, -- cells of the centred reading column; 0: as wide as the editor
  },
  -- Inline mode: blocks typeset in the markdown buffer itself, shown as source under the cursor.
  inline = {
    enabled = false, -- turn it on in every markdown buffer
    kinds = { "heading", "table", "mermaid" }, ---@type string[]|"all" block kinds rendered
    -- Windows showing an inline buffer get at most this 'scrolloff': Nvim 0.12 loops when
    -- scrolling up past concealed lines with virtual lines at a larger one. nil: leave it.
    scrolloff = 1, ---@type integer?
    -- <C-e>, <C-y> and the mouse wheel scroll with the plugin's own scrolling in inline
    -- buffers: Nvim 0.12's gets stuck or bounces past concealed lines with virtual lines.
    scroll_fix = true,
    reveal_delay = 100, -- ms the cursor rests in a block before it shows as source
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
  if opts and opts.inline and opts.inline.kinds then
    config.inline.kinds = opts.inline.kinds
  end
end

---@return typeset.Config
function M.get()
  return config
end

return M
