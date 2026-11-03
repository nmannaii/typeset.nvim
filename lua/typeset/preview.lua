-- The preview: the current markdown buffer typeset, every block rendered and stacked.
--
-- Two modes:
-- - split: a window next to the source. It follows the markdown buffer you are in and scrolls so
--   the block under the cursor sits level with the cursor.
-- - overlay: a floating window over the whole editor, for reading. It shows one buffer, the one
--   it was opened from, in a centred column, and is scrolled on its own. Going to another buffer
--   or window closes it.
--
-- While a block is being edited its previous image stays up until the new one is rendered, so
-- typing never flickers the preview or shows raw text in it.
local M = {}

local blocks = require("typeset.blocks")
local config = require("typeset.config")
local images = require("typeset.images")
local placeholder = require("typeset.placeholder")

local ns = vim.api.nvim_create_namespace("typeset.preview")

---@class typeset.Preview
---@field win integer
---@field buf integer the preview's own buffer
---@field src? integer markdown buffer being previewed
---@field overlay boolean
---@field origin? integer overlay: the window it was opened from
---@field placed? boolean overlay: scrolled to the source cursor's block once
---@field guicursor? string overlay: 'guicursor' to restore when leaving it (the cursor is hidden)
---@field blocks typeset.Block[]
---@field starts table<integer, integer> block index -> first preview row (0-based)
---@field last table<integer, typeset.Image> block index -> image shown, kept while a newer one renders
---@field timer any uv_timer_t
---@field augroup integer
local preview ---@type typeset.Preview?

local function valid()
  return preview and vim.api.nvim_win_is_valid(preview.win) and vim.api.nvim_buf_is_valid(preview.buf)
end

--- Width the blocks are rendered at, in cells.
local function cols()
  local width = vim.api.nvim_win_get_width(preview.win)
  if preview.overlay then
    local column = config.get().overlay.width
    width = column and column > 0 and math.min(column, width - 4) or width - 4
  end
  return math.max(10, math.min(width, config.get().max_width))
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

--- Index of the block shown at preview row `row` (0-based): the last one starting at or above it.
local function block_at_row(row)
  local found
  for i, start in ipairs(preview.starts) do
    if start > row then
      break
    end
    found = i
  end
  return found
end

--- Scroll the overlay so preview row `row` (0-based) is at the top.
local function overlay_top(row)
  local count = vim.api.nvim_buf_line_count(preview.buf)
  local top = math.max(1, math.min(row + 1, count))
  vim.api.nvim_win_call(preview.win, function()
    vim.fn.winrestview({ topline = top, lnum = top })
  end)
end

--- Rebuild the preview's lines from the source's blocks.
function M.build()
  if not (valid() and preview.src and vim.api.nvim_buf_is_valid(preview.src)) then
    return
  end
  local p = preview
  local width = cols()
  -- The overlay's column is centred: every line starts with this many spaces.
  local pad = p.overlay and string.rep(" ", math.floor((vim.api.nvim_win_get_width(p.win) - width) / 2)) or ""
  -- The overlay keeps its own scroll position across rebuilds: the block at the top, and how far
  -- into it.
  local anchor
  if p.overlay and p.placed then
    local top = vim.api.nvim_win_call(p.win, vim.fn.winsaveview).topline - 1
    local i = block_at_row(top)
    anchor = i and { i, top - p.starts[i] }
  end
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
  if anchor and new_blocks[anchor[1]] then
    cursor = new_blocks[anchor[1]].srow -- the overlay is looked at, not the source cursor
  end
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
  -- Declare what is wanted before requesting it: `images.get` starts the queue, which drops any
  -- job that isn't wanted, so doing this afterwards would drop every new render.
  for _, b in ipairs(new_blocks) do
    hashes[images.hash(b.text, width)] = true
  end
  images.want("preview", hashes)
  local found = {}
  for _, i in ipairs(order) do
    found[i] = images.get(new_blocks[i].text, width, on_ready, { owner = "preview" }) or false
  end
  local shown = {}
  for i, b in ipairs(new_blocks) do
    starts[i] = #lines
    local img = found[i] or nil
    -- Still rendering: keep what this block showed before (same position and kind).
    local prev = p.blocks[i] and p.blocks[i].kind == b.kind and p.last[i] or nil
    img = img or prev
    local from = #lines
    if img and not img.error and img.rows > 0 then
      images.show(img)
      shown[img.id] = true
      last[i] = img
      for _, line in ipairs(placeholder.lines(img.cols, img.rows)) do
        lines[#lines + 1] = pad .. line
      end
      hls[#hls + 1] = { from, #lines, images.hl(img) }
      -- no spacer: the image carries the space below its block
    else
      -- Never rendered yet (or the renderer failed): the source text, dimmed.
      for _, line in ipairs(vim.list_slice(src_lines, b.srow + 1, b.erow + 1)) do
        lines[#lines + 1] = pad .. line
      end
      hls[#hls + 1] = { from, #lines, "Comment" }
      lines[#lines + 1] = ""
    end
  end
  images.retain("preview", shown)
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
  if not p.overlay then
    M.sync()
  elseif anchor and starts[anchor[1]] then
    local i = anchor[1]
    local height = (starts[i + 1] or #lines) - starts[i]
    overlay_top(starts[i] + math.min(anchor[2], math.max(height - 1, 0)))
  elseif not p.placed then
    -- First build: open on the block the source cursor is in.
    local _, i = blocks.at(new_blocks, cursor)
    overlay_top(i and starts[i] or 0)
    p.placed = true
  end
end

--- Rebuild after `delay` ms (default: config.debounce), coalescing calls made meanwhile.
function M.schedule(delay)
  if not preview then
    return
  end
  preview.timer:stop()
  preview.timer:start(delay or config.get().debounce, 0, vim.schedule_wrap(M.build))
end

--- Scroll the split preview so the cursor's block sits on the cursor's screen row.
function M.sync()
  if not valid() or preview.overlay then
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
  return vim.tbl_contains(config.get().filetypes, vim.bo[buf].filetype)
end

--- Preview `buf` from now on (the split preview follows the markdown buffer you are in).
local function follow(buf)
  if not preview or preview.overlay or preview.src == buf or not is_markdown(buf) then
    return
  end
  preview.src, preview.blocks, preview.last = buf, {}, {}
  M.build()
end

--- Where the overlay goes: the whole editor but the command line and a global statusline.
local function overlay_geometry()
  local height = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus == 3 and 1 or 0)
  return { relative = "editor", row = 0, col = 0, width = vim.o.columns, height = math.max(1, height) }
end

--- Hide the cursor while in the overlay (it would sit on the images), show it again outside.
local function hide_cursor(hide)
  local p = preview
  if not p then
    return
  end
  if hide and not p.guicursor then
    vim.api.nvim_set_hl(0, "TypesetHiddenCursor", { blend = 100, nocombine = true })
    p.guicursor = vim.o.guicursor
    vim.o.guicursor = "a:TypesetHiddenCursor"
  elseif not hide and p.guicursor then
    vim.o.guicursor = p.guicursor
    p.guicursor = nil
  end
end

--- The source window to return to from the overlay.
local function origin_win()
  local p = preview
  if p.origin and vim.api.nvim_win_is_valid(p.origin) then
    return p.origin
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= p.win and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
end

--- Close the overlay and put the source cursor on the block at its top.
local function edit_here()
  local p = preview
  if not (p and valid()) then
    return
  end
  local top = vim.api.nvim_win_call(p.win, vim.fn.winsaveview).topline - 1
  local i = block_at_row(top)
  local row = i and p.blocks[i] and p.blocks[i].srow or 0
  local src, win = p.src, origin_win()
  M.close()
  if win and src and vim.api.nvim_buf_is_valid(src) then
    vim.api.nvim_set_current_win(win)
    if vim.api.nvim_win_get_buf(win) ~= src then
      vim.api.nvim_win_set_buf(win, src)
    end
    vim.api.nvim_win_set_cursor(win, { math.min(row + 1, vim.api.nvim_buf_line_count(src)), 0 })
    vim.cmd("normal! zt")
  end
end

--- Scroll the overlay to the next (1) or previous (-1) heading.
local function jump_heading(dir)
  local p = preview
  if not valid() then
    return
  end
  local top = vim.api.nvim_win_call(p.win, vim.fn.winsaveview).topline - 1
  local first, last, step = 1, #p.blocks, 1
  if dir < 0 then
    first, last, step = #p.blocks, 1, -1
  end
  for i = first, last, step do
    local b, start = p.blocks[i], p.starts[i]
    if b.kind == "heading" and (dir > 0 and start > top or dir < 0 and start < top) then
      return overlay_top(start)
    end
  end
end

local function overlay_keys(pbuf)
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = pbuf, nowait = true, desc = desc })
  end
  map("j", "<C-e>", "Scroll down")
  map("k", "<C-y>", "Scroll up")
  map("<Down>", "<C-e>", "Scroll down")
  map("<Up>", "<C-y>", "Scroll up")
  map("d", "<C-d>", "Scroll half a page down")
  map("u", "<C-u>", "Scroll half a page up")
  map("<Space>", "<C-f>", "Scroll a page down")
  map("<S-Space>", "<C-b>", "Scroll a page up")
  map("]]", function()
    jump_heading(1)
  end, "Next heading")
  map("[[", function()
    jump_heading(-1)
  end, "Previous heading")
  map("e", edit_here, "Edit here (close the overlay)")
  map("<CR>", edit_here, "Edit here (close the overlay)")
  map("<Esc>", M.close, "Close the overlay")
end

---@class typeset.OpenOpts
---@field overlay? boolean a reading overlay over the editor instead of a split

---@param buf? integer markdown buffer to preview (default: current)
---@param opts? typeset.OpenOpts
function M.open(buf, opts)
  opts = opts or {}
  if preview then
    if not opts.overlay == not preview.overlay then
      return
    end
    M.close() -- the other mode is open: switch
  end
  buf = buf or vim.api.nvim_get_current_buf()
  local overlay = opts.overlay == true
  if overlay and not is_markdown(buf) then
    vim.notify("typeset: the overlay shows a markdown buffer", vim.log.levels.WARN)
    return
  end
  local prev_win = vim.api.nvim_get_current_win()
  local pbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[pbuf].bufhidden = "wipe"
  vim.bo[pbuf].filetype = "typeset"
  local win, vertical
  if overlay then
    local geometry = overlay_geometry()
    geometry.style, geometry.zindex, geometry.border = "minimal", 40, "none"
    win = vim.api.nvim_open_win(pbuf, true, geometry)
  else
    local split = config.get().preview
    vertical = split.position == "left" or split.position == "right"
    local total = vertical and vim.o.columns or vim.o.lines
    local size = split.size <= 1 and math.floor(total * split.size) or split.size
    win = vim.api.nvim_open_win(pbuf, false, {
      split = split.position,
      win = -1,
      width = vertical and size or nil,
      height = not vertical and size or nil,
    })
  end
  local wo = vim.wo[win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn = false, false, "no", "0"
  wo.statuscolumn, wo.colorcolumn, wo.cursorline, wo.list, wo.spell = "", "", false, false, false
  wo.wrap, wo.scrolloff, wo.sidescrolloff = false, 0, 0
  wo.fillchars = "eob: "
  if overlay then
    wo.winhighlight = "NormalFloat:Normal"
    local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
    wo.winbar = (" 󰈙 %s%%=j/k d/u ]]/[[ headings · e edit · q close "):format(name ~= "" and name or "typeset")
  else
    wo.winfixwidth, wo.winfixheight = vertical, not vertical
    wo.winbar = " 󰈙 typeset"
    vim.api.nvim_set_current_win(prev_win)
  end

  local augroup = vim.api.nvim_create_augroup("typeset.preview", { clear = true })
  preview = {
    win = win,
    buf = pbuf,
    overlay = overlay,
    origin = overlay and prev_win or nil,
    blocks = {},
    starts = {},
    last = {},
    timer = assert(vim.uv.new_timer()),
    augroup = augroup,
  }
  local function on(event, o)
    o.group = augroup
    vim.api.nvim_create_autocmd(event, o)
  end
  if not overlay then
    on("BufEnter", {
      callback = function(ev)
        follow(ev.buf)
      end,
    })
    on({ "CursorMoved", "CursorMovedI", "WinScrolled" }, {
      callback = function(ev)
        if preview and ev.buf == preview.src then
          M.sync()
        end
      end,
    })
  else
    -- The overlay is bound to its buffer: entering another (non-floating) window, or another
    -- buffer taking the overlay's window (a picker's choice), closes it.
    on("WinEnter", {
      callback = function()
        local cur = vim.api.nvim_get_current_win()
        if cur == win then
          hide_cursor(true)
        elseif vim.api.nvim_win_get_config(cur).relative == "" then
          M.close()
        end
      end,
    })
    on("WinLeave", {
      callback = function()
        if vim.api.nvim_get_current_win() == win then
          hide_cursor(false)
        end
      end,
    })
    on("BufWinEnter", {
      callback = vim.schedule_wrap(function()
        if not (preview and preview.win == win and vim.api.nvim_win_is_valid(win)) then
          return
        end
        local other = vim.api.nvim_win_get_buf(win)
        if other == preview.buf then
          return
        end
        local target = origin_win()
        M.close()
        if target then
          vim.api.nvim_win_set_buf(target, other)
          vim.api.nvim_set_current_win(target)
        end
      end),
    })
    on({ "BufDelete", "BufWipeout" }, {
      callback = function(ev)
        if preview and ev.buf == preview.src then
          vim.schedule(M.close)
        end
      end,
    })
    overlay_keys(pbuf)
    hide_cursor(true)
  end
  on({ "TextChanged", "TextChangedI" }, {
    callback = function(ev)
      if preview and ev.buf == preview.src then
        M.schedule()
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
  if overlay then
    preview.src = buf
    M.build()
  elseif is_markdown(buf) then
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
  hide_cursor(false)
  preview = nil
  p.timer:stop()
  p.timer:close()
  images.want("preview", {})
  images.retain("preview", {})
  pcall(vim.api.nvim_del_augroup_by_id, p.augroup)
  if vim.api.nvim_win_is_valid(p.win) and #vim.api.nvim_list_wins() > 1 then
    pcall(vim.api.nvim_win_close, p.win, true)
  end
  if vim.api.nvim_buf_is_valid(p.buf) then
    pcall(vim.api.nvim_buf_delete, p.buf, { force = true })
  end
  if p.overlay and p.origin and vim.api.nvim_win_is_valid(p.origin) and vim.api.nvim_get_current_win() ~= p.origin then
    local cur = vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(cur) or vim.api.nvim_win_get_config(cur).relative ~= "" then
      pcall(vim.api.nvim_set_current_win, p.origin)
    end
  end
end

---@param opts? typeset.OpenOpts
function M.toggle(opts)
  opts = opts or {}
  if preview and not opts.overlay == not preview.overlay then
    M.close()
  else
    M.open(nil, opts)
  end
end

function M.is_open()
  return preview ~= nil
end

--- Whether the open preview is the overlay.
function M.is_overlay()
  return preview ~= nil and preview.overlay
end

--- Rebuild (colours, cell size, the image cache or the editor size changed).
function M.refresh()
  if preview then
    if preview.overlay and vim.api.nvim_win_is_valid(preview.win) then
      vim.api.nvim_win_set_config(preview.win, overlay_geometry())
    end
    preview.last = {}
    M.schedule(0)
  end
end

return M
