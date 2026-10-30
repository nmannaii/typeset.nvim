-- The typeset-renderer process: started on first use, kept running (typst memoizes across
-- compilations), fed one JSON request per line, answering one JSON line per request.
local M = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local exe = vim.fn.has("win32") == 1 and ".exe" or ""

---@type vim.SystemObj?
local proc
local next_id = 0
---@type table<integer, fun(reply: table)>
local waiting = {}

--- Path of the renderer binary, or nil when it isn't installed.
---@return string?
function M.binary()
  local candidates = {
    root .. "/bin/typeset-renderer" .. exe, -- :TypesetInstall (download or build)
    root .. "/renderer/target/release/typeset-renderer" .. exe, -- plain `cargo build --release`
  }
  local configured = require("typeset.config").get().binary
  if configured then
    table.insert(candidates, 1, vim.fn.expand(configured))
  end
  for _, path in ipairs(candidates) do
    if vim.fn.executable(path) == 1 then
      return path
    end
  end
end

M.root = root

local function on_exit(result)
  proc = nil
  local orphans = waiting
  waiting = {}
  vim.schedule(function()
    for _, cb in pairs(orphans) do
      cb({ error = ("renderer exited (%s)"):format(result.signal ~= 0 and "signal " .. result.signal or result.code) })
    end
  end)
end

local function start()
  local bin = M.binary()
  if not bin then
    return nil, "typeset-renderer is not installed: run :TypesetInstall"
  end
  local pending = ""
  local ok, p = pcall(vim.system, { bin }, {
    stdin = true,
    stdout = function(_, data)
      if not data then
        return
      end
      pending = pending .. data
      for line in pending:gmatch("([^\n]*)\n") do
        local decoded, reply = pcall(vim.json.decode, line)
        if decoded and type(reply) == "table" and reply.id and waiting[reply.id] then
          local cb = waiting[reply.id]
          waiting[reply.id] = nil
          vim.schedule(function()
            cb(reply)
          end)
        end
      end
      pending = pending:match("[^\n]*$")
    end,
    stderr = false,
  }, on_exit)
  if not ok then
    return nil, tostring(p)
  end
  proc = p
  return proc
end

--- Render `request` (see renderer/src/main.rs for its fields); `cb` gets the reply on the
--- main loop: { path, width, height, cols, rows } or { error }.
---@param request table
---@param cb fun(reply: table)
function M.request(request, cb)
  local p, err = proc, nil
  if not p then
    p, err = start() -- not `proc or start()`: `or` would drop the error message
  end
  if not p then
    cb({ error = err })
    return
  end
  next_id = next_id + 1
  request.id = next_id
  waiting[next_id] = cb
  p:write(vim.json.encode(request) .. "\n")
end

function M.stop()
  if proc then
    pcall(proc.kill, proc, "sigterm")
    proc = nil
  end
end

return M
