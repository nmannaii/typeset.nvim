-- Rendered blocks: one PNG per (markdown, width, cell size, theme), cached on disk by content
-- hash, each with a kitty image id. The terminal gets an image the first time it is shown.
local M = {}

local renderer = require("typeset.renderer")
local terminal = require("typeset.terminal")

-- Bump when the renderer's output changes for the same input, to invalidate the disk cache.
local CACHE_VERSION = "5"
local cache_dir = vim.fn.stdpath("cache") .. "/typeset"

---@class typeset.Image
---@field id integer kitty image id (24-bit: it travels as the placeholders' fg colour)
---@field hash string
---@field path string
---@field cols integer
---@field rows integer
---@field error? string

---@type table<string, typeset.Image>
local images = {}
---@type table<string, fun(img: typeset.Image)[]>
local pending = {}
---@type table<integer, string> id -> "cols x rows" it was transmitted with
local transmitted = {}
local next_id = 0x7a0000 -- well away from the small ids snacks.image hands out

local function hl_group(id)
  local name = "TypesetImage" .. id
  vim.api.nvim_set_hl(0, name, { fg = id, nocombine = true })
  return name
end

--- Highlight group whose foreground carries the image id.
---@param img typeset.Image
function M.hl(img)
  return hl_group(img.id)
end

--- Width and height of a PNG, from its IHDR chunk.
local function png_size(path)
  local fd = vim.uv.fs_open(path, "r", 0)
  if not fd then
    return
  end
  local header = vim.uv.fs_read(fd, 24, 0)
  vim.uv.fs_close(fd)
  if not header or #header < 24 or header:sub(2, 4) ~= "PNG" then
    return
  end
  local function u32(i)
    local a, b, c, d = header:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return u32(17), u32(21)
end

local function new_image(hash, path, cols, rows, err)
  next_id = next_id + 1
  local img = { id = next_id, hash = hash, path = path, cols = cols, rows = rows, error = err }
  images[hash] = img
  return img
end

---@class typeset.Job
---@field hash string
---@field request table
---@field owner any who asked (a buffer); its latest `want` decides whether the job still matters

---@type typeset.Job[]
local queue = {}
local busy = false
---@type table<any, table<string, true>>
local wanted = {}

--- Declare the images `owner` needs now. Queued renders it asked for earlier and no longer
--- needs (text edited since, window resized) are dropped instead of rendered.
---@param owner any
---@param hashes table<string, true>
function M.want(owner, hashes)
  wanted[owner] = hashes
end

local function finish(job, reply)
  local img = new_image(job.hash, job.request.out, reply.cols or 0, reply.rows or 0, reply.error)
  if reply.error then
    vim.notify_once("typeset: " .. reply.error, vim.log.levels.WARN)
  end
  local callbacks = pending[job.hash] or {}
  pending[job.hash] = nil
  for _, cb in ipairs(callbacks) do
    cb(img)
  end
end

--- One render at a time: the renderer is sequential anyway, and waiting here (not in its stdin)
--- is what lets stale jobs be dropped.
local function pump()
  while not busy and #queue > 0 do
    local job = table.remove(queue, 1)
    local w = job.owner ~= nil and wanted[job.owner]
    if w and not w[job.hash] then
      pending[job.hash] = nil
    else
      busy = true
      renderer.request(job.request, function(reply)
        busy = false
        finish(job, reply)
        pump()
      end)
    end
  end
end

--- Hash of `markdown` rendered `cols` cells wide with the current cell size and colours.
---@return string
function M.hash(markdown, cols)
  local cell = terminal.cell()
  return vim.fn.sha256(table.concat({
    CACHE_VERSION,
    markdown,
    cols,
    cell[1],
    cell[2],
    require("typeset.config").get().text_scale,
    require("typeset.theme").json(),
  }, "\0"))
end

---@class typeset.GetOpts
---@field owner? any see `want`
---@field render? boolean false: only look in the cache, never start a render (default true)

--- The image of `markdown` rendered `cols` cells wide, and its hash. Returns the image at once
--- when it is ready (memory or disk cache); otherwise queues a render, returns nil, and calls
--- `on_ready` once it is done.
---@param markdown string
---@param cols integer
---@param on_ready fun(img: typeset.Image)
---@param opts? typeset.GetOpts
---@return typeset.Image?, string
function M.get(markdown, cols, on_ready, opts)
  opts = opts or {}
  local hash = M.hash(markdown, cols)
  if images[hash] then
    return images[hash], hash
  end
  local cell = terminal.cell()
  local path = ("%s/%s.png"):format(cache_dir, hash)
  local w, h = png_size(path)
  if w then
    return new_image(hash, path, math.ceil(w / cell[1]), math.ceil(h / cell[2])), hash
  end
  if opts.render == false then
    return nil, hash
  end
  if pending[hash] then
    table.insert(pending[hash], on_ready)
    return nil, hash
  end
  pending[hash] = { on_ready }
  vim.fn.mkdir(cache_dir, "p")
  local config = require("typeset.config").get()
  table.insert(queue, {
    hash = hash,
    owner = opts.owner,
    request = {
      markdown = markdown,
      width = cols * cell[1],
      cell = cell,
      out = path,
      theme = require("typeset.theme").get(),
      text_scale = config.text_scale,
    },
  })
  pump()
  return nil, hash
end

--- Make sure the terminal has `img`, with a virtual placement over its cells.
---@param img typeset.Image
function M.show(img)
  local key = img.cols .. "x" .. img.rows
  if transmitted[img.id] ~= key then
    terminal.transmit(img.id, img.path, img.cols, img.rows)
    transmitted[img.id] = key
  end
end

--- Free every image in the terminal except `ids`. Terminals cap image storage and evict silently,
--- leaving blank placeholders, so images left behind by resizes must not pile up there.
---@param ids table<integer, true>
function M.retain(ids)
  for id in pairs(transmitted) do
    if not ids[id] then
      terminal.delete(id)
      transmitted[id] = nil
    end
  end
end

--- The terminal may have lost its images (a reset after a suspend, a resize): send them again
--- when next shown. Ids stay known so `retain` can still free the ones not shown again.
function M.forget_transmitted()
  for id in pairs(transmitted) do
    transmitted[id] = false
  end
end

--- Free every image in the terminal.
function M.clear_terminal()
  for id in pairs(transmitted) do
    terminal.delete(id)
  end
  transmitted = {}
end

--- Forget every rendered image (the disk cache was cleared).
function M.reset()
  M.clear_terminal()
  images = {}
end

--- Re-create highlight groups (a colourscheme change clears them).
function M.refresh_hl()
  for _, img in pairs(images) do
    hl_group(img.id)
  end
end

function M.cache_dir()
  return cache_dir
end

return M
