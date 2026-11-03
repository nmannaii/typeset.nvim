-- The terminal Neovim's UI draws on: its tty, its cell size in pixels, and kitty graphics
-- commands sent through Neovim's own output (nvim_ui_send), so they are serialized with
-- Neovim's redraws instead of racing them on the tty.
local M = {}

local ffi = require("ffi")
-- Each declaration on its own: other plugins (snacks.image) may have declared some already.
for _, decl in ipairs({
  "typedef struct { unsigned short row, col, xpixel, ypixel; } typeset_winsize;",
  "int ioctl(int, unsigned long, ...);",
  "int open(const char *, int, ...);",
  "int close(int);",
}) do
  pcall(ffi.cdef, decl)
end

local IS_MAC = vim.fn.has("mac") == 1
local TIOCGWINSZ = IS_MAC and 0x40087468 or 0x5413
local O_NOCTTY = IS_MAC and 0x20000 or 0x100

--- The tty the TUI draws on. Since nvim 0.10 the TUI is a separate process (our parent) and
--- this server process has no tty of its own; `--embed`-style setups fall back to ours.
---@return string?
function M.tty()
  if M._tty ~= nil then
    return M._tty or nil
  end
  for _, pid in ipairs({ vim.uv.os_getppid(), vim.fn.getpid() }) do
    for fd = 0, 2 do
      local target = vim.uv.fs_readlink(("/proc/%d/fd/%d"):format(pid, fd))
      if target and (target:match("^/dev/pts/%d+$") or target:match("^/dev/tty")) then
        M._tty = target
        return target
      end
    end
  end
  local ok, tty = pcall(vim.fn.system, { "ps", "-o", "tty=", "-p", tostring(vim.uv.os_getppid()) })
  tty = ok and vim.trim(tty) or ""
  if tty ~= "" and not tty:match("^%?") then
    M._tty = tty:match("^/") and tty or "/dev/" .. tty
    return M._tty
  end
  M._tty = false
end

--- Pixel size of one cell, from TIOCGWINSZ on the UI's tty (kitty, ghostty and herdr fill
--- in the pixel fields). nil when the terminal doesn't report pixels.
---@return integer[]? { width, height }
function M.measure_cell()
  local tty = M.tty()
  if not tty then
    return
  end
  local fd = ffi.C.open(tty, O_NOCTTY) -- O_RDONLY = 0
  if fd < 0 then
    return
  end
  local ws = ffi.new("typeset_winsize")
  local ok = ffi.C.ioctl(fd, TIOCGWINSZ, ws) == 0
  ffi.C.close(fd)
  if ok and ws.col > 0 and ws.row > 0 and ws.xpixel > 0 and ws.ypixel > 0 then
    return { math.floor(ws.xpixel / ws.col), math.floor(ws.ypixel / ws.row) }
  end
end

---@type integer[]?
local cell

--- Cell size in pixels: config override, else measured (cached until `reset`).
---@return integer[] { width, height }
function M.cell()
  local configured = require("typeset.config").get().cell
  if configured then
    return configured
  end
  cell = cell or M.measure_cell() or { 8, 16 }
  return cell
end

--- Forget the measured cell size (font size or terminal zoom changed).
function M.reset()
  cell = nil
end

--- Why images can't be shown here, or nil when they can.
---@return string?
function M.unsupported()
  if not vim.api.nvim_ui_send then
    return "needs Neovim 0.12+ (nvim_ui_send)"
  end
  if not vim.o.termguicolors then
    return "needs 'termguicolors' (image ids travel as 24-bit colours)"
  end
  -- No UI check: files given on the command line get their FileType before the TUI attaches.
end

--- How images reach the terminal: "file" (it reads the PNG by path) or "direct" (the PNG's
--- bytes travel in the escape codes, so the terminal can be on another machine).
---@return "file"|"direct"
function M.transfer()
  local mode = require("typeset.config").get().transfer
  if mode == "file" or mode == "direct" then
    return mode
  end
  -- auto: over ssh the terminal can't read our files.
  return (vim.env.SSH_CONNECTION or vim.env.SSH_CLIENT or vim.env.SSH_TTY) and "direct" or "file"
end

local function apc(keys, payload)
  return "\27_G" .. keys .. (payload and (";" .. payload) or "") .. "\27\\"
end

local CHUNK = 4096 -- the protocol's limit for one chunk of base64 data

--- The escape codes that send a PNG as image `id` with a virtual placement over `cols` x
--- `rows` cells. nil when `direct` and the file can't be read.
---@return string?
function M.transmit_codes(id, path, cols, rows, mode)
  local keys = ("a=T,f=100,i=%d,U=1,c=%d,r=%d,q=2"):format(id, cols, rows)
  if mode ~= "direct" then
    return apc(keys .. ",t=f", vim.base64.encode(path))
  end
  local f = io.open(path, "rb")
  if not f then
    return
  end
  local data = vim.base64.encode(f:read("*a"))
  f:close()
  -- The first chunk carries the keys, the rest only m= (1: more follow, 0: the last).
  local out = {}
  for i = 1, #data, CHUNK do
    local more = i + CHUNK <= #data and 1 or 0
    local head = i == 1 and (keys .. ",t=d,m=" .. more) or ("q=2,m=" .. more)
    out[#out + 1] = apc(head, data:sub(i, i + CHUNK - 1))
  end
  return table.concat(out)
end

--- Send a PNG file as image `id` and give it a virtual placement over `cols` x `rows` cells.
--- Placeholder cells coloured with `id` then show it, wherever they are on screen.
function M.transmit(id, path, cols, rows)
  local codes = M.transmit_codes(id, path, cols, rows, M.transfer())
  if codes then
    vim.api.nvim_ui_send(codes)
  end
end

--- Free image `id` in the terminal.
function M.delete(id)
  pcall(vim.api.nvim_ui_send, apc(("a=d,d=I,i=%d,q=2"):format(id)))
end

return M
