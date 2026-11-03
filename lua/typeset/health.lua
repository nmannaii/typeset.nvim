local M = {}

function M.check()
  local h = vim.health
  local terminal = require("typeset.terminal")
  h.start("typeset.nvim")

  local bin = require("typeset.renderer").binary()
  if bin then
    h.ok("renderer: " .. bin)
  else
    h.error("renderer not installed", { "Run :TypesetInstall (needs cargo, or `repo` set for prebuilt binaries)" })
  end

  local why = terminal.unsupported()
  if why then
    h.warn("images can't be shown: " .. why)
  else
    h.ok("nvim_ui_send and 'termguicolors' available")
  end

  if terminal.transfer() == "direct" then
    h.ok("images sent as data (transfer = direct): the terminal may be on another machine")
  else
    h.ok("images sent as file paths (transfer = file): the terminal must be on this machine")
  end

  local tty = terminal.tty()
  if tty then
    h.ok("UI tty: " .. tty)
  else
    h.warn("no UI tty found (headless or remote UI)")
  end

  local measured = terminal.measure_cell()
  if measured then
    h.ok(("cell size %dx%d px (measured)"):format(measured[1], measured[2]))
  elseif require("typeset.config").get().cell then
    h.ok("cell size set in config")
  else
    h.warn("the terminal doesn't report its pixel size; set `cell = { w, h }` (fallback 8x16)")
  end

  local ok, parser = pcall(vim.treesitter.language.inspect, "markdown")
  if ok and parser then
    h.ok("treesitter markdown parser installed")
  else
    h.error("treesitter markdown parser missing", { ":TSInstall markdown" })
  end

  h.info(("terminal: %s (needs kitty graphics unicode placeholders: kitty, ghostty)"):format(
    vim.env.TERM_PROGRAM or vim.env.TERM or "?"
  ))
end

return M
