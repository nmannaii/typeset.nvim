-- Installs the renderer into <plugin>/bin: a prebuilt release binary when `repo` is configured
-- and one exists for this platform, otherwise `cargo build --release` from renderer/.
local M = {}

local renderer = require("typeset.renderer")

--- Release asset name for this machine, e.g. typeset-renderer-x86_64-unknown-linux-gnu.
function M.target()
  local uname = vim.uv.os_uname()
  local arch = ({ x86_64 = "x86_64", amd64 = "x86_64", aarch64 = "aarch64", arm64 = "aarch64" })[uname.machine]
  local os = ({ Linux = "unknown-linux-gnu", Darwin = "apple-darwin" })[uname.sysname]
  if arch and os then
    return ("%s-%s"):format(arch, os)
  end
end

local function notify(msg, level)
  vim.schedule(function()
    vim.notify("typeset: " .. msg, level or vim.log.levels.INFO)
  end)
end

local function bin_path()
  return renderer.root .. "/bin/typeset-renderer"
end

---@param done fun(ok: boolean)
local function download(done)
  local repo, target = require("typeset.config").get().repo, M.target()
  if not (repo and target and vim.fn.executable("curl") == 1) then
    return done(false)
  end
  local url = ("https://github.com/%s/releases/latest/download/typeset-renderer-%s"):format(repo, target)
  local tmp = bin_path() .. ".download"
  notify("downloading " .. url)
  vim.fn.mkdir(renderer.root .. "/bin", "p")
  vim.system({ "curl", "-fsSL", "-o", tmp, url }, {}, vim.schedule_wrap(function(res)
    if res.code ~= 0 then
      os.remove(tmp)
      notify("download failed (" .. vim.trim(res.stderr or "") .. "), building instead", vim.log.levels.WARN)
      return done(false)
    end
    vim.uv.fs_chmod(tmp, tonumber("755", 8))
    os.rename(tmp, bin_path())
    done(true)
  end))
end

---@param done fun(ok: boolean)
local function build(done)
  if vim.fn.executable("cargo") == 0 then
    notify("no prebuilt binary and no cargo: install Rust (https://rustup.rs) or set `repo`", vim.log.levels.ERROR)
    return done(false)
  end
  notify("building the renderer with cargo (the first build takes a few minutes)…")
  local manifest = renderer.root .. "/renderer/Cargo.toml"
  -- schedule_wrap: the exit callback runs in a fast context, where vim.fn is off limits.
  vim.system({ "cargo", "build", "--release", "--locked", "--manifest-path", manifest }, { text = true }, vim.schedule_wrap(function(res)
    if res.code ~= 0 then
      notify("cargo build failed:\n" .. (res.stderr or ""):sub(-2000), vim.log.levels.ERROR)
      return done(false)
    end
    vim.fn.mkdir(renderer.root .. "/bin", "p")
    -- Copy next to it, then rename over it: the running renderer keeps the old file open, and
    -- writing into a running executable fails ("text file busy") where a rename does not.
    local tmp = bin_path() .. ".new"
    local ok = vim.uv.fs_copyfile(renderer.root .. "/renderer/target/release/typeset-renderer", tmp)
    if ok then
      vim.uv.fs_chmod(tmp, tonumber("755", 8))
      ok = vim.uv.fs_rename(tmp, bin_path())
    end
    done(ok == true)
  end))
end

--- Install the renderer. With `opts.sync`, wait for it (for lazy.nvim's `build`).
---@param opts? { sync?: boolean }
function M.install(opts)
  local finished, result = false, false
  local function done(ok)
    finished, result = true, ok
    if ok then
      renderer.stop() -- the next request starts the new binary
      notify("renderer installed: " .. bin_path())
    end
  end
  download(function(ok)
    if ok then
      done(true)
    else
      build(done)
    end
  end)
  if opts and opts.sync then
    vim.wait(30 * 60 * 1000, function()
      return finished
    end, 200)
  end
  return result
end

return M
