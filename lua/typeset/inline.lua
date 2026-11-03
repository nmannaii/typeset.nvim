-- Inline mode: blocks of a markdown buffer shown typeset in the buffer itself, the way Emacs
-- shows images and scaled headings in place. A rendered block's source lines are concealed
-- (`conceal_lines`) and its image is drawn as virtual lines of placeholder cells; the block under
-- the cursor shows as source, so it can be edited.
--
-- Layout rules, from how Nvim 0.12 scrolls:
-- - Images hang above the next visible line. Only virtual lines above a line can be partly
--   scrolled off the top of a window (like diff filler); those below a line jump off at once.
-- - The images above one line must be shorter than the window, or the top of them can never be
--   scrolled into view: blocks that would break this stay source.
-- - Scrolling up past concealed lines with virtual lines gets stuck or loops (worse with a
--   larger 'scrolloff'), so windows showing the buffer get `inline.scrolloff`, and <C-y> and the
--   wheel scroll up through `M.scroll_up`.
local M = {}

local blocks = require("typeset.blocks")
local config = require("typeset.config")
local images = require("typeset.images")
local placeholder = require("typeset.placeholder")

local ns = vim.api.nvim_create_namespace("typeset.inline")
local on_key_ns = vim.api.nvim_create_namespace("typeset.inline.keys")

---@class typeset.Inline
---@field augroup integer
---@field timer any uv_timer_t: re-layout after edits
---@field reveal_timer any uv_timer_t: reveal after the cursor rests
---@field row integer cursor row (0-based) the reveal follows
---@field chosen typeset.Block[] blocks of the configured kinds, as of the last layout
---@field revealed? integer first row of the block shown as source

local states = {} ---@type table<integer, typeset.Inline>
---@type table<integer, integer> window -> its own 'scrolloff' before inline mode changed it
local saved_scrolloff = {}
local scroll_until = 0 -- ms (hrtime): cursor moves before this come from scrolling

local function now()
  return vim.uv.hrtime() / 1e6
end

local function owner(buf)
  return "inline:" .. buf
end

local function kinds()
  local k = config.get().inline.kinds
  if k == "all" then
    return setmetatable({}, {
      __index = function(_, kind)
        return kind ~= "frontmatter"
      end,
    })
  end
  local set = {}
  for _, kind in ipairs(k) do
    set[kind] = true
  end
  return set
end

--- The window the layout is sized for: the current one when it shows `buf`.
local function main_win(buf)
  if vim.api.nvim_get_current_buf() == buf then
    return vim.api.nvim_get_current_win()
  end
  return vim.fn.win_findbuf(buf)[1]
end

local function block_at(list, row)
  for _, b in ipairs(list) do
    if row >= b.srow and row <= b.erow then
      return b
    end
  end
end

--- Blocks of the configured kinds and the buffer's blank lines, parsed again only after an edit
--- (not on every cursor move).
local function parse(buf, st)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if st.tick == tick then
    return
  end
  local want = kinds()
  local chosen = {}
  for _, b in ipairs(blocks.get(buf)) do
    if want[b.kind] then
      chosen[#chosen + 1] = b
    end
  end
  local blank = {}
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if not line:find("%S") then
      blank[i - 1] = true
    end
  end
  st.chosen, st.blank, st.tick = chosen, blank, tick
end

---@class typeset.Hidden
---@field img typeset.Image
---@field srow integer first concealed row: the block and the blank lines above it it took
---@field erow integer last concealed row: the block and the blank lines after it
---@field above integer blank lines taken above, shown as empty rows over the image
---@field below integer blank lines taken below, shown as empty rows under it

--- Which blocks to hide and where their images go: groups of hidden blocks sharing an anchor
--- line. A hidden block takes the blank lines around it and shows them as empty rows, so spacing
--- stays the source's while decorations other plugins draw on those lines (render-markdown's
--- table borders) are hidden with the block. Blocks that can't be placed (no visible line to
--- hang from, or too tall together) stay source.
---@param chosen typeset.Block[]
---@param imgs table<integer, typeset.Image> block index -> image, edited in place
---@param blank table<integer, true> blank rows
---@param count integer buffer lines
---@param max_rows integer tallest group allowed
---@return typeset.Hidden[], table[]
local function place(chosen, imgs, blank, count, max_rows)
  for _ = 0, #chosen do
    local hidden, prev_end = {}, -1
    for i, b in ipairs(chosen) do
      if imgs[i] then
        local s, e, above, below = b.srow, b.erow, 0, 0
        while e + 1 < count and blank[e + 1] do
          e, below = e + 1, below + 1
        end
        while s - 1 > prev_end and blank[s - 1] do
          s, above = s - 1, above + 1
        end
        hidden[#hidden + 1] = { i = i, img = imgs[i], srow = s, erow = e, above = above, below = below }
        prev_end = e
      end
    end
    local concealed = {}
    for _, h in ipairs(hidden) do
      for r = h.srow, h.erow do
        concealed[r] = true
      end
    end
    local groups, list, changed = {}, {}, false
    for _, h in ipairs(hidden) do
      local row, above = h.erow + 1, true
      while row < count and concealed[row] do
        row = row + 1
      end
      if row >= count then -- nothing visible after it: hang below the line before
        row, above = h.srow - 1, false
        while row >= 0 and concealed[row] do
          row = row - 1
        end
      end
      if row < 0 then
        imgs[h.i], changed = nil, true
        break
      end
      local key = row .. (above and "a" or "b")
      local g = groups[key]
      if not g then
        g = { row = row, above = above, members = {}, rows = 0 }
        groups[key] = g
        list[#list + 1] = g
      end
      g.members[#g.members + 1] = h
      g.rows = g.rows + h.above + h.img.rows + h.below
    end
    if not changed then
      for _, g in ipairs(list) do
        if g.rows > max_rows then
          imgs[g.members[#g.members].i], changed = nil, true
        end
      end
    end
    if not changed then
      return hidden, list
    end
  end
  return {}, {}
end

local EMPTY_ROW = { { " " } }

--- Render and lay out `buf` for the window showing it.
function M.layout(buf)
  local st = states[buf]
  if not (st and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local win = main_win(buf)
  if not win then
    return -- not shown anywhere: the marks stay as they are
  end
  local info = vim.fn.getwininfo(win)[1]
  local width = math.max(10, math.min(info.width - info.textoff, config.get().max_width))
  local max_rows = info.height - 1

  parse(buf, st)
  local chosen = st.chosen
  local revealed = block_at(chosen, st.row)
  st.revealed = revealed and revealed.srow or nil

  -- Declared before any request: the render queue drops jobs nobody wants.
  local hashes = {}
  for _, b in ipairs(chosen) do
    hashes[images.hash(b.text, width, true)] = true
  end
  images.want(owner(buf), hashes)
  -- Nearest the cursor first. The revealed block is rendered too, so it shows the moment the
  -- cursor leaves it.
  local order = {}
  for i in ipairs(chosen) do
    order[i] = i
  end
  local function distance(b)
    return b.erow < st.row and st.row - b.erow or b.srow > st.row and b.srow - st.row or 0
  end
  table.sort(order, function(x, y)
    local dx, dy = distance(chosen[x]), distance(chosen[y])
    if dx ~= dy then
      return dx < dy
    end
    return x < y
  end)
  local function on_ready()
    M.schedule(buf, 30) -- renders finishing together: one layout
  end
  local imgs = {} ---@type table<integer, typeset.Image>
  for _, i in ipairs(order) do
    local img = images.get(chosen[i].text, width, on_ready, { owner = owner(buf), inline = true })
    if img and not img.error and img.rows > 0 and img.rows <= max_rows and chosen[i] ~= revealed then
      imgs[i] = img
    end
  end
  local hidden, groups = place(chosen, imgs, st.blank, vim.api.nvim_buf_line_count(buf), max_rows)

  local shown, parts = {}, {}
  for _, h in ipairs(hidden) do
    images.show(h.img) -- (again after the terminal lost its images)
    shown[h.img.id] = true
    parts[#parts + 1] = h.srow .. "-" .. h.erow
  end
  for _, g in ipairs(groups) do
    parts[#parts + 1] = g.row .. (g.above and "^" or "v")
    for _, h in ipairs(g.members) do
      parts[#parts + 1] = h.img.id .. "/" .. h.above .. "/" .. h.below
    end
  end
  -- Same layout as already drawn (a render of a block that stays source, a cursor move that
  -- changes nothing): leave the marks, and Nvim nothing to redraw.
  local signature = table.concat(parts, " ")
  local drawn = #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { limit = 1 }) > 0
  if signature ~= st.signature or (#parts > 0 and not drawn) then -- (marks lost on a reload)
    st.signature = signature
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, h in ipairs(hidden) do
      vim.api.nvim_buf_set_extmark(buf, ns, h.srow, 0, { end_row = h.erow, conceal_lines = "" })
    end
    for _, g in ipairs(groups) do
      local lines = {}
      for _, h in ipairs(g.members) do
        for _ = 1, h.above do
          lines[#lines + 1] = EMPTY_ROW
        end
        local hl = images.hl(h.img)
        for _, line in ipairs(placeholder.lines(h.img.cols, h.img.rows)) do
          lines[#lines + 1] = { { line, hl } }
        end
        for _ = 1, h.below do
          lines[#lines + 1] = EMPTY_ROW
        end
      end
      vim.api.nvim_buf_set_extmark(buf, ns, g.row, 0, { virt_lines = lines, virt_lines_above = g.above })
    end
  end
  images.retain(owner(buf), shown)
end

--- Re-layout `buf` after `delay` ms (default: config.debounce), coalescing calls made meanwhile.
function M.schedule(buf, delay)
  local st = states[buf]
  if not st then
    return
  end
  st.timer:stop()
  st.timer:start(
    delay or config.get().debounce,
    0,
    vim.schedule_wrap(function()
      M.layout(buf)
    end)
  )
end

--- The cursor moved: show the block it is in as source, once it rests there (at once in insert
--- mode). Moves made by scrolling leave the layout alone, or it would reshuffle under the wheel.
local function on_cursor(buf)
  local st = states[buf]
  if not st then
    return
  end
  local insert = vim.fn.mode():match("^[iR]") ~= nil
  if not insert and now() < scroll_until then
    return
  end
  local function reveal()
    if states[buf] ~= st or vim.api.nvim_get_current_buf() ~= buf then
      return
    end
    st.row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local b = block_at(st.chosen, st.row)
    if (b and b.srow) ~= st.revealed then
      M.layout(buf)
    end
  end
  st.reveal_timer:stop()
  if insert then
    reveal()
  else
    st.reveal_timer:start(config.get().inline.reveal_delay, 0, vim.schedule_wrap(reveal))
  end
end

--- Text rows of line `row` (0 when concealed) and the filler rows above it.
local function line_rows(win, row)
  local h = vim.api.nvim_win_text_height(win, { start_row = row, end_row = row })
  return h.all - h.fill, h.fill
end

--- Scroll `win` up by `count` screen rows. Nvim 0.12's own scrolling up gets stuck or loops
--- past concealed lines with virtual lines above them, whatever 'scrolloff' is, so inline
--- buffers scroll up through here: one filler row or one line at a time, then the cursor is
--- moved up just enough to stay in view, and the view is set in one go.
---@param win integer
---@param count integer
function M.scroll_up(win, count)
  local v = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  for _ = 1, count do
    local top = v.topline - 1
    local _, fill = line_rows(win, top)
    if v.topfill < fill then
      v.topfill = v.topfill + 1
    else
      local prev = top - 1
      while prev >= 0 and line_rows(win, prev) == 0 do
        prev = prev - 1
      end
      if prev < 0 then
        break
      end
      v.topline, v.topfill = prev + 1, 0
    end
  end
  local so = vim.api.nvim_get_option_value("scrolloff", { win = win })
  local room = math.max(1, vim.api.nvim_win_get_height(win) - so)
  local function used(row) -- screen rows from the top of the window down to `row`
    local h = vim.api.nvim_win_text_height(win, { start_row = v.topline - 1, end_row = row })
    local _, fill = line_rows(win, v.topline - 1)
    return h.all - fill + v.topfill
  end
  local cur = v.lnum - 1
  while cur > v.topline - 1 and used(cur) > room do
    cur = cur - 1
    while cur > v.topline - 1 and line_rows(win, cur) == 0 do
      cur = cur - 1
    end
  end
  v.lnum = cur + 1
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview(v)
  end)
end

--- Scroll `win` down by `count` screen rows, the same way as `M.scroll_up` (Nvim's own <C-e>
--- bounces back past a concealed block with a tall image under it).
---@param win integer
---@param count integer
function M.scroll_down(win, count)
  local v = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) - 1
  for _ = 1, count do
    if v.topfill > 0 then
      v.topfill = v.topfill - 1
    else
      local next = v.topline -- 0-based row after the top line
      while next <= last and line_rows(win, next) == 0 do
        next = next + 1
      end
      if next > last then
        break
      end
      local _, fill = line_rows(win, next)
      v.topline, v.topfill = next + 1, fill -- its filler (the image above it) comes first
    end
  end
  -- The cursor below the top line, and off the top row when 'scrolloff' asks for it.
  local top = v.topline - 1
  local cur = math.max(v.lnum - 1, top)
  local so = vim.api.nvim_get_option_value("scrolloff", { win = win })
  if so > 0 and cur == top and v.topfill == 0 and top > 0 then
    local next = cur + 1
    while next <= last and line_rows(win, next) == 0 do
      next = next + 1
    end
    if next <= last then
      cur = next
    end
  end
  while cur > top and line_rows(win, cur) == 0 do -- never on a concealed line
    cur = cur + 1 <= last and cur + 1 or top
  end
  v.lnum = cur + 1
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview(v)
  end)
end

local SCROLL_MAPS = {
  { "<C-y>", "scroll_up", { "n" } },
  { "<C-e>", "scroll_down", { "n" } },
  { "<ScrollWheelUp>", "scroll_up", { "n", "i", "v" }, true },
  { "<ScrollWheelDown>", "scroll_down", { "n", "i", "v" }, true },
}

local function map_scroll(buf)
  for _, m in ipairs(SCROLL_MAPS) do
    local key, fn, modes, wheel = m[1], m[2], m[3], m[4]
    vim.keymap.set(modes, key, function()
      scroll_until = now() + 300
      if not wheel then
        return M[fn](0, vim.v.count1)
      end
      local win = vim.fn.getmousepos().winid
      if win ~= 0 and states[vim.api.nvim_win_get_buf(win)] then
        M[fn](win, tonumber(vim.o.mousescroll:match("ver:(%d+)")) or 3)
      else -- over another window: its own scrolling
        vim.api.nvim_feedkeys(vim.keycode(key), "n", false)
      end
    end, { buffer = buf, desc = "Scroll (typeset inline)" })
  end
end

local function unmap_scroll(buf)
  for _, m in ipairs(SCROLL_MAPS) do
    for _, mode in ipairs(m[3]) do
      pcall(vim.keymap.del, mode, m[1], { buffer = buf })
    end
  end
end

--- Give windows showing an inline buffer `inline.scrolloff`, and give back the others' own.
local function sync_windows()
  local limit = config.get().inline.scrolloff
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local inline = states[vim.api.nvim_win_get_buf(win)] ~= nil
    if inline and limit and saved_scrolloff[win] == nil then
      local own = vim.api.nvim_get_option_value("scrolloff", { win = win, scope = "local" })
      local effective = own >= 0 and own or vim.o.scrolloff
      if effective > limit then
        saved_scrolloff[win] = own
        vim.wo[win].scrolloff = limit
      end
    elseif not inline and saved_scrolloff[win] ~= nil then
      vim.wo[win].scrolloff = saved_scrolloff[win]
      saved_scrolloff[win] = nil
    end
  end
  for win in pairs(saved_scrolloff) do
    if not vim.api.nvim_win_is_valid(win) then
      saved_scrolloff[win] = nil
    end
  end
end

local global_group
local function ensure_global()
  if global_group then
    return
  end
  global_group = vim.api.nvim_create_augroup("typeset.inline", { clear = true })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinNew", "WinClosed" }, {
    group = global_group,
    callback = vim.schedule_wrap(sync_windows),
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = global_group,
    callback = function()
      for _, win in ipairs(vim.v.event.windows or {}) do
        if vim.api.nvim_win_is_valid(win) then
          M.schedule(vim.api.nvim_win_get_buf(win), 0) -- new width or height: lay out for it
        end
      end
    end,
  })
  local scroll_keys = {}
  for _, key in ipairs({ "<C-e>", "<C-y>", "<ScrollWheelUp>", "<ScrollWheelDown>" }) do
    scroll_keys[vim.keycode(key)] = true
  end
  vim.on_key(function(key, typed)
    if next(states) and (scroll_keys[key] or scroll_keys[typed or ""]) then
      scroll_until = now() + 300
    end
  end, on_key_ns)
end

---@param buf? integer default: current
function M.attach(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if states[buf] or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local why = require("typeset.terminal").unsupported()
  if why then
    vim.notify_once("typeset: " .. why, vim.log.levels.WARN)
    return
  end
  ensure_global()
  local win = main_win(buf)
  local augroup = vim.api.nvim_create_augroup("typeset.inline." .. buf, { clear = true })
  states[buf] = {
    augroup = augroup,
    timer = assert(vim.uv.new_timer()),
    reveal_timer = assert(vim.uv.new_timer()),
    row = win and vim.api.nvim_win_get_cursor(win)[1] - 1 or 0,
    chosen = {},
  }
  local function on(event, callback)
    vim.api.nvim_create_autocmd(event, { group = augroup, buffer = buf, callback = callback })
  end
  on({ "TextChanged", "TextChangedI" }, function()
    M.schedule(buf)
  end)
  on({ "CursorMoved", "CursorMovedI", "InsertEnter" }, function()
    on_cursor(buf)
  end)
  on("BufWinEnter", function()
    M.schedule(buf, 0) -- possibly a window of another width
  end)
  on({ "BufUnload", "BufWipeout" }, function()
    M.detach(buf)
  end)
  if config.get().inline.scroll_fix then
    map_scroll(buf)
  end
  sync_windows()
  M.layout(buf)
end

---@param buf? integer default: current
function M.detach(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local st = states[buf]
  if not st then
    return
  end
  states[buf] = nil
  for _, timer in ipairs({ st.timer, st.reveal_timer }) do
    timer:stop()
    timer:close()
  end
  pcall(vim.api.nvim_del_augroup_by_id, st.augroup)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if config.get().inline.scroll_fix then
      unmap_scroll(buf)
    end
  end
  images.want(owner(buf), {})
  images.retain(owner(buf), {})
  sync_windows()
end

---@param buf? integer default: current
function M.toggle(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if states[buf] then
    M.detach(buf)
  else
    M.attach(buf)
  end
end

---@param buf? integer default: current
function M.is_attached(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  return states[buf] ~= nil
end

--- Re-layout every inline buffer (colours, cell size or the terminal's images changed).
function M.refresh()
  for buf in pairs(states) do
    M.schedule(buf, 0)
  end
end

M.ns = ns

return M
