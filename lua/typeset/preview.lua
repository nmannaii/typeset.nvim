-- The preview: a split next to the source showing the current markdown buffer typeset, every
-- block rendered and stacked. The source stays plain text; the preview follows the buffer you
-- are in and scrolls so the block under the cursor sits level with the cursor.
--
-- While a block is being edited its previous image stays up until the new one is rendered, so
-- typing never flickers the preview or shows raw text in it.
local M = {}

local blocks = require("typeset.blocks")
local images = require("typeset.images")
local placeholder = require("typeset.placeholder")

local ns = vim.api.nvim_create_namespace("typeset.preview")

---@class typeset.Preview
---@field win integer
---@field buf integer the preview's own buffer
---@field src? integer markdown buffer being previewed
---@field blocks typeset.Block[]
---@field starts table<integer, integer> block index -> first preview row (0-based)
---@field last table<integer, typeset.Image> block index -> image shown, kept while a newer one renders
---@field timer any uv_timer_t
---@field augroup integer
local preview ---@type typeset.Preview?

local function valid()
  return preview and vim.api.nvim_win_is_valid(preview.win) and vim.api.nvim_buf_is_valid(preview.buf)
end

local function cols()
  return math.max(10, math.min(vim.api.nvim_win_get_width(preview.win), require("typeset.config").get().max_width))
end

--- The window showing the previewed buffer (the current one when it does).
local function src_win()
  local p = preview
  if not (p and p.src) then
    return
  end
  if vim.api.nvim_get_current_buf() == p.src then
    return vim.api.nvim_get_current_win()
  end
  for _, win in ipairs(vim.fn.win_findbuf(p.src)) do
    if win ~= p.win then
      return win
    end
  end
end

--- Rebuild the preview's lines from the source's blocks.
function M.build()
  if not (valid() and preview.src and vim.api.nvim_buf_is_valid(preview.src)) then
    return
  end
  local p = preview
  local width = cols()
  local new_blocks = blocks.get(p.src)
  local lines, hls, starts, last, hashes = {}, {}, {}, {}, {}
  local src_lines = vim.api.nvim_buf_get_lines(p.src, 0, -1, false)
  local function on_ready()
    M.schedule(0)
  end
  -- Queue renders outward from the cursor's block: renders run one at a time, and a slow diagram
  -- elsewhere must not hold up what is being looked at.
  local win = src_win()
  local cursor = win and vim.api.nvim_win_get_cursor(win)[1] - 1 or 0
  local order = {}
  for i in ipairs(new_blocks) do
    order[i] = i
  end
  local function distance(b)
    return b.erow < cursor and cursor - b.erow or b.srow > cursor and b.srow - cursor or 0
  end
  table.sort(order, function(x, y)
    local dx, dy = distance(new_blocks[x]), distance(new_blocks[y])
    if dx ~= dy then
      return dx < dy
    end
    return x < y
  end)
  local found = {}
  for _, i in ipairs(order) do
    local img, hash = images.get(new_blocks[i].text, width, on_ready, { owner = "preview" })
    hashes[hash] = true
    found[i] = img or false
  end
  for i, b in ipairs(new_blocks) do
    starts[i] = #lines
    local img = found[i] or nil
    -- Still rendering: keep what this block showed before (same position and kind).
    local prev = p.blocks[i] and p.blocks[i].kind == b.kind and p.last[i] or nil
    img = img or prev
    if img and not img.error and img.rows > 0 then
      images.show(img)
      last[i] = img
      local from = #lines
      vim.list_extend(lines, placeholder.lines(img.cols, img.rows))
      hls[#hls + 1] = { from, #lines, images.hl(img) }
      -- no spacer: the image carries the space below its block
    else
      -- Never rendered yet (or the renderer failed): the source text, dimmed.
      local from = #lines
      vim.list_extend(lines, vim.list_slice(src_lines, b.srow + 1, b.erow + 1))
      hls[#hls + 1] = { from, #lines, "Comment" }
      lines[#lines + 1] = ""
    end
  end
  images.want("preview", hashes)
  p.blocks, p.starts, p.last = new_blocks, starts, last
  vim.bo[p.buf].modifiable = true
  vim.api.nvim_buf_set_lines(p.buf, 0, -1, false, lines)
  vim.bo[p.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(p.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    if h[2] > h[1] then
      vim.api.nvim_buf_set_extmark(p.buf, ns, h[1], 0, { end_row = h[2], hl_group = h[3], priority = 4096 })
    end
  end
  M.sync()
end

--- Rebuild after `delay` ms (default: config.debounce), coalescing calls made meanwhile.
function M.schedule(delay)
  if not preview then
    return
  end
  preview.timer:stop()
  preview.timer:start(delay or require("typeset.config").get().debounce, 0, vim.schedule_wrap(M.build))
end

--- Scroll the preview so the cursor's block sits on the cursor's screen row.
function M.sync()
  if not valid() then
    return
  end
  local p = preview
  local win = src_win()
  if not win then
    return
  end
  local row, screen_row
  vim.api.nvim_win_call(win, function()
    row, screen_row = vim.fn.line(".") - 1, vim.fn.winline()
  end)
  local _, i = blocks.at(p.blocks, row)
  if not i then -- between blocks: the next one
    for k, b in ipairs(p.blocks) do
      if b.srow > row then
        i = k
        break
      end
    end
  end
  local count = vim.api.nvim_buf_line_count(p.buf)
  local target = i and p.starts[i] or count - 1
  local top = math.max(1, math.min(target + 1 - (screen_row - 1), count))
  vim.api.nvim_win_call(p.win, function()
    vim.fn.winrestview({ topline = top, lnum = math.min(target + 1, count) })
  end)
end

local function is_markdown(buf)
  return vim.tbl_contains(require("typeset.config").get().filetypes, vim.bo[buf].filetype)
end

--- Preview `buf` from now on (the preview follows the markdown buffer you are in).
local function follow(buf)
  if not preview or preview.src == buf or not is_markdown(buf) then
    return
  end
  preview.src, preview.blocks, preview.last = buf, {}, {}
  M.build()
end

---@param buf? integer markdown buffer to preview (default: current)
function M.open(buf)
  if preview then
    return
  end
  buf = buf or vim.api.nvim_get_current_buf()
  local config = require("typeset.config").get().preview
  local prev_win = vim.api.nvim_get_current_win()
  local pbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[pbuf].bufhidden = "wipe"
  vim.bo[pbuf].filetype = "typeset"
  local vertical = config.position == "left" or config.position == "right"
  local total = vertical and vim.o.columns or vim.o.lines
  local size = config.size <= 1 and math.floor(total * config.size) or config.size
  local win = vim.api.nvim_open_win(pbuf, false, {
    split = config.position,
    win = -1,
    width = vertical and size or nil,
    height = not vertical and size or nil,
  })
  local wo = vim.wo[win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn = false, false, "no", "0"
  wo.statuscolumn, wo.colorcolumn, wo.cursorline, wo.list, wo.spell = "", "", false, false, false
  wo.wrap, wo.scrolloff, wo.sidescrolloff = false, 0, 0
  wo.winfixwidth, wo.winfixheight = vertical, not vertical
  wo.fillchars = "eob: "
  wo.winbar = " 󰈙 typeset"
  vim.api.nvim_set_current_win(prev_win)

  local augroup = vim.api.nvim_create_augroup("typeset.preview", { clear = true })
  preview = {
    win = win,
    buf = pbuf,
    blocks = {},
    starts = {},
    last = {},
    timer = assert(vim.uv.new_timer()),
    augroup = augroup,
  }
  local function on(event, opts)
    opts.group = augroup
    vim.api.nvim_create_autocmd(event, opts)
  end
  on("BufEnter", {
    callback = function(ev)
      follow(ev.buf)
    end,
  })
  on({ "TextChanged", "TextChangedI" }, {
    callback = function(ev)
      if preview and ev.buf == preview.src then
        M.schedule()
      end
    end,
  })
  on({ "CursorMoved", "CursorMovedI", "WinScrolled" }, {
    callback = function(ev)
      if preview and ev.buf == preview.src then
        M.sync()
      end
    end,
  })
  on("WinResized", {
    callback = function()
      if preview and vim.tbl_contains(vim.v.event.windows, preview.win) then
        M.schedule(0) -- new width: render at it
      end
    end,
  })
  on("WinClosed", {
    pattern = tostring(win),
    callback = vim.schedule_wrap(function()
      M.close()
    end),
  })
  vim.keymap.set("n", "q", M.close, { buffer = pbuf, nowait = true, desc = "Close typeset preview" })
  if is_markdown(buf) then
    follow(buf)
  else
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { "", "  open a markdown buffer to preview it" })
  end
end

function M.close()
  local p = preview
  if not p then
    return
  end
  preview = nil
  p.timer:stop()
  p.timer:close()
  images.want("preview", {})
  pcall(vim.api.nvim_del_augroup_by_id, p.augroup)
  if vim.api.nvim_win_is_valid(p.win) and #vim.api.nvim_list_wins() > 1 then
    pcall(vim.api.nvim_win_close, p.win, true)
  end
  if vim.api.nvim_buf_is_valid(p.buf) then
    pcall(vim.api.nvim_buf_delete, p.buf, { force = true })
  end
end

function M.toggle()
  if preview then
    M.close()
  else
    M.open()
  end
end

function M.is_open()
  return preview ~= nil
end

--- Rebuild (colours, cell size or the image cache changed).
function M.refresh()
  if preview then
    preview.last = {}
    M.schedule(0)
  end
end

return M
