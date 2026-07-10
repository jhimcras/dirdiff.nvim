-- Asynchronous content verification for "modified" candidates.
--
-- diff.compute marks same-size / different-mtime pairs with verify=true because
-- mtime alone is unreliable (it changes on copy/checkout). This module reads
-- both sides via vim.uv and drops the entry when the bytes are equal, so files
-- that are actually identical no longer show up as modified.
--
-- Reads are async (never blocking the UI) and bounded: at most CONCURRENCY
-- pairs are in flight, and files larger than MAX_SIZE are left as "modified"
-- rather than loaded into memory.
local M = {}

local uv = vim.uv

local MAX_SIZE = 20 * 1024 * 1024 -- 20 MiB; larger pairs are kept as modified
local CONCURRENCY = 16

-- Byte comparison of two file contents. Extension point: when
-- compare_opts.ignore_newline / ignore_encoding are implemented, normalize a
-- and b here before comparing. For now only byte-exact comparison exists, so
-- the options have no effect.
local function contents_equal(a, b, _compare_opts)
  return a == b
end

-- Read a whole file asynchronously. Calls cb("ok", data) / cb("toobig") /
-- cb("error"). Never throws; callers treat anything but "ok" as "cannot
-- confirm identical" and keep the entry as modified.
local function read_async(pathname, cb)
  uv.fs_open(pathname, "r", 420, function(oerr, fd) -- 0644
    if oerr or not fd then
      return cb("error")
    end
    uv.fs_fstat(fd, function(serr, stat)
      if serr or not stat then
        uv.fs_close(fd, function() end)
        return cb("error")
      end
      if stat.size > MAX_SIZE then
        uv.fs_close(fd, function() end)
        return cb("toobig")
      end
      if stat.size == 0 then
        uv.fs_close(fd, function() end)
        return cb("ok", "")
      end
      uv.fs_read(fd, stat.size, 0, function(rerr, data)
        uv.fs_close(fd, function() end)
        if rerr or not data then
          return cb("error")
        end
        cb("ok", data)
      end)
    end)
  end)
end

-- Read both sides of one candidate and report whether they are identical.
local function compare_entry(entry, compare_opts, cb)
  read_async(entry.abs_a, function(sa, da)
    if sa ~= "ok" then
      return cb(false)
    end
    read_async(entry.abs_b, function(sb, db)
      if sb ~= "ok" then
        return cb(false)
      end
      cb(contents_equal(da, db, compare_opts))
    end)
  end)
end

-- entries: output of diff.compute. Resolves every entry with verify=true by
-- reading content, then calls done(entries) with identical pairs removed and
-- the verify flag stripped. Safe to call on the main loop (all I/O is async).
function M.resolve(entries, compare_opts, done)
  local candidates = {}
  for _, e in ipairs(entries) do
    if e.verify then
      candidates[#candidates + 1] = e
    end
  end

  local function finalize()
    local out = {}
    for _, e in ipairs(entries) do
      e.verify = nil
      if e._identical then
        e._identical = nil
      else
        out[#out + 1] = e
      end
    end
    -- finalize runs inside a libuv fs callback (fast event context), where the
    -- Vim API used by the renderer is forbidden; hop back to the main loop.
    vim.schedule(function()
      done(out)
    end)
  end

  if #candidates == 0 then
    return finalize()
  end

  local next_i = 0
  local remaining = #candidates
  local active = 0

  local function launch()
    while active < CONCURRENCY and next_i < #candidates do
      next_i = next_i + 1
      active = active + 1
      local entry = candidates[next_i]
      compare_entry(entry, compare_opts, function(identical)
        if identical then
          entry._identical = true
        end
        active = active - 1
        remaining = remaining - 1
        if remaining == 0 then
          finalize()
        else
          launch()
        end
      end)
    end
  end

  launch()
end

return M
