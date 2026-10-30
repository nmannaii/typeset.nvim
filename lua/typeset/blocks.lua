-- Top-level markdown blocks of a buffer, from the treesitter markdown tree.
local M = {}

---@class typeset.Block
---@field kind string heading|table|mermaid|math|code|quote|list|paragraph|rule|frontmatter
---@field srow integer first line, 0-based
---@field erow integer last line, 0-based, inclusive
---@field text string

local KIND = {
  atx_heading = "heading",
  setext_heading = "heading",
  pipe_table = "table",
  block_quote = "quote",
  list = "list",
  paragraph = "paragraph",
  thematic_break = "rule",
  minus_metadata = "frontmatter",
  indented_code_block = "code",
  fenced_code_block = "code",
}

local CODE_KIND = { mermaid = "mermaid", math = "math", latex = "math", tex = "math" }

---@param node TSNode
---@param buf integer
local function code_kind(node, buf)
  for child in node:iter_children() do
    if child:type() == "info_string" then
      for part in child:iter_children() do
        if part:type() == "language" then
          return CODE_KIND[vim.treesitter.get_node_text(part, buf):lower()] or "code"
        end
      end
    end
  end
  return "code"
end

--- Blocks of `buf`, in document order.
---@param buf integer
---@return typeset.Block[]
function M.get(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if not ok or not parser then
    return {}
  end
  local tree = parser:parse()[1]
  if not tree then
    return {}
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local out = {} ---@type typeset.Block[]

  local function walk(node)
    for child in node:iter_children() do
      local type = child:type()
      if type == "section" then
        walk(child)
      elseif KIND[type] then
        local srow, _, erow, ecol = child:range()
        if ecol == 0 then
          erow = erow - 1 -- the range ends at column 0 of the next line
        end
        while erow > srow and (lines[erow + 1] or ""):match("^%s*$") do
          erow = erow - 1 -- trailing blank lines belong to no block
        end
        local text = table.concat(vim.list_slice(lines, srow + 1, erow + 1), "\n")
        local kind = KIND[type]
        if type == "fenced_code_block" then
          kind = code_kind(child, buf)
        end
        out[#out + 1] = { kind = kind, srow = srow, erow = erow, text = text }
      end
    end
  end
  walk(tree:root())
  return out
end

--- The block containing `row` (0-based), if any.
---@param blocks typeset.Block[]
---@param row integer
---@return typeset.Block?, integer?
function M.at(blocks, row)
  for i, b in ipairs(blocks) do
    if row >= b.srow and row <= b.erow then
      return b, i
    end
  end
end

return M
