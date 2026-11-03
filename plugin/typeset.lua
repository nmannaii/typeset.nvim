if vim.g.loaded_typeset then
  return
end
vim.g.loaded_typeset = true

local commands = {
  toggle = function()
    require("typeset").toggle()
  end,
  inline = function()
    require("typeset.inline").toggle()
  end,
  rerender = function()
    vim.fn.delete(require("typeset.images").cache_dir(), "rf")
    require("typeset.images").reset()
    require("typeset.preview").refresh()
    require("typeset.inline").refresh()
  end,
  install = function()
    require("typeset.build").install()
  end,
}

vim.api.nvim_create_user_command("Typeset", function(args)
  local fn = commands[args.fargs[1] or "toggle"]
  if not fn then
    vim.notify("Typeset: unknown subcommand " .. args.fargs[1], vim.log.levels.ERROR)
    return
  end
  fn()
end, {
  nargs = "?",
  complete = function()
    return vim.tbl_keys(commands)
  end,
  desc = "typeset.nvim: toggle (the preview) | inline | rerender | install",
})

vim.api.nvim_create_user_command("TypesetInstall", commands.install, { desc = "Download or build typeset-renderer" })
