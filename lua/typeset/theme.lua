-- Colours for the renderer, taken from the current colourscheme's highlight groups.
local M = {}

local function hex(n)
  return n and ("#%06x"):format(n) or nil
end

---@param groups string[] first group with the attribute wins
---@param attr "fg"|"bg"
local function color(groups, attr)
  for _, name in ipairs(groups) do
    local hl = vim.api.nvim_get_hl(0, { name = name, link = false, create = false })
    if hl[attr] then
      return hex(hl[attr])
    end
  end
end

local function blend(a, b, alpha)
  local function c(s, i)
    return tonumber(s:sub(i, i + 1), 16)
  end
  local out = {}
  for _, i in ipairs({ 2, 4, 6 }) do
    out[#out + 1] = ("%02x"):format(math.floor(c(a, i) * alpha + c(b, i) * (1 - alpha) + 0.5))
  end
  return "#" .. table.concat(out)
end

local cached, cached_json

--- Forget the colours (the colourscheme or 'background' changed).
function M.reset()
  cached, cached_json = nil, nil
end

--- The theme as JSON, for cache keys (encoded once, not once per block).
function M.json()
  cached_json = cached_json or vim.json.encode(M.get())
  return cached_json
end

--- The theme sent with every render request.
---@return table
function M.get()
  cached = cached or M.compute()
  return cached
end

---@return table
function M.compute()
  local config = require("typeset.config").get()
  local dark = vim.o.background == "dark"
  local fg = color({ "Normal" }, "fg") or (dark and "#d0d0d0" or "#202020")
  local bg = color({ "Normal" }, "bg") or (dark and "#000000" or "#ffffff")
  local headings = {}
  for level = 1, 6 do
    headings[level] = color({ "@markup.heading." .. level .. ".markdown", "markdownH" .. level, "Title" }, "fg") or fg
  end
  local theme = {
    dark = dark,
    fg = fg,
    base = bg,
    muted = color({ "Comment" }, "fg") or blend(fg, bg, 0.5),
    border = blend(fg, bg, 0.22),
    link = color({ "@markup.link.url", "@markup.link", "Underlined" }, "fg") or fg,
    code_bg = color({ "ColorColumn", "CursorLine" }, "bg") or blend(fg, bg, 0.1),
    headings = headings,
    font = config.font,
    mono_font = config.mono_font,
    syntax = {
      keyword = color({ "@keyword", "Keyword", "Statement" }, "fg"),
      string = color({ "@string", "String" }, "fg"),
      comment = color({ "@comment", "Comment" }, "fg"),
      ["function"] = color({ "@function", "Function" }, "fg"),
      type = color({ "@type", "Type" }, "fg"),
      number = color({ "@number", "Number" }, "fg"),
      constant = color({ "@constant", "Constant" }, "fg"),
      operator = color({ "@operator", "Operator" }, "fg"),
    },
  }
  if type(config.theme) == "function" then
    theme = config.theme(theme) or theme
  elseif type(config.theme) == "table" then
    theme = vim.tbl_deep_extend("force", theme, config.theme)
  end
  return theme
end

return M
