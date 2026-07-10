-- Asynchronous content verification for "modified" candidates.
--
-- diff.compute marks same-size / different-mtime pairs with verify=true because
-- mtime alone is unreliable (it changes on copy/checkout). This module reads
-- both sides via vim.uv and retags the entry status="equal" when the bytes
-- are equal (keeping it in the output, not dropping it), so files that are
-- actually identical no longer show up as modified but can still be
-- displayed/toggled without a re-scan.
--
-- Reads are async (never blocking the UI) and bounded: at most CONCURRENCY
-- pairs are in flight, and files larger than MAX_SIZE are left as "modified"
-- rather than loaded into memory.
local M = {}

local uv = vim.uv

local MAX_SIZE = 20 * 1024 * 1024 -- 20 MiB; larger pairs are kept as modified
local CONCURRENCY = 16

local UTF8_BOM = "\239\187\191"
local UTF16LE_BOM = "\255\254"
local UTF16BE_BOM = "\254\255"

-- Drop a leading byte-order mark. ignore_encoding only strips the BOM; it does
-- not transcode between encodings (that is left to a future external tool).
local function strip_bom(s)
  if s:sub(1, 3) == UTF8_BOM then
    return s:sub(4)
  elseif s:sub(1, 2) == UTF16LE_BOM or s:sub(1, 2) == UTF16BE_BOM then
    return s:sub(3)
  end
  return s
end

-- Normalize line endings to LF. CRLF is collapsed first so the trailing CR is
-- not turned into an extra LF; any remaining lone CR (classic Mac) follows.
local function normalize_newlines(s)
  s = s:gsub("\r\n", "\n")
  s = s:gsub("\r", "\n")
  return s
end

-- Compare two file contents, honoring the compare options. When both options
-- are off this is a plain byte-exact compare (the common fast path); otherwise
-- both sides are normalized before comparing.
local function contents_equal(a, b, compare_opts)
  if not compare_opts
    or (not compare_opts.ignore_newline and not compare_opts.ignore_encoding) then
    return a == b
  end
  if compare_opts.ignore_encoding then
    a, b = strip_bom(a), strip_bom(b)
  end
  if compare_opts.ignore_newline then
    a, b = normalize_newlines(a), normalize_newlines(b)
  end
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
-- reading content, then calls done(entries) with identical pairs retagged
-- status="equal" and the verify flag stripped. Safe to call on the main loop
-- (all I/O is async).
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
        e.status = "equal"
      end
      out[#out + 1] = e
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
