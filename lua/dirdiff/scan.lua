-- Asynchronous recursive directory scan using vim.uv (libuv).
--
-- libuv performs the actual filesystem I/O on its threadpool, so the main UI
-- thread stays responsive even for very large trees (spec 2.1). The callback
-- runs on the main loop via vim.schedule once every outstanding operation has
-- completed.
local path = require("dirdiff.path")
local ignore = require("dirdiff.ignore")

local M = {}

-- Read a (small) file synchronously via libuv. Safe in a fast event context
-- because it only calls vim.uv, not the Vim API. Returns nil on any failure.
local function read_file_sync(fpath)
  local uv = vim.uv
  local fd = uv.fs_open(fpath, "r", 420) -- 0644
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local data
  if stat and stat.size > 0 then
    data = uv.fs_read(fd, math.min(stat.size, 1024 * 1024), 0)
  end
  uv.fs_close(fd)
  return data
end

-- Translate a shell glob into an anchored Lua pattern. Pure Lua so it can be
-- matched inside the vim.uv callback (a fast event context), where vim.regex /
-- vim.fn are unsafe and abort Neovim under load.
local function glob_to_pattern(glob)
  local pat = glob
    :gsub("[%(%)%.%%%+%-%^%$%[%]]", "%%%1")
    :gsub("%*", ".*")
    :gsub("%?", ".")
  return "^" .. pat .. "$"
end

-- Compile a list of shell-glob exclude patterns, matched against each entry's
-- basename.
local function compile_excludes(globs)
  local res = {}
  for _, g in ipairs(globs or {}) do
    res[#res + 1] = glob_to_pattern(g)
  end
  return res
end

-- root: directory to scan. opts.exclude: list of glob patterns.
-- on_done(snapshot) is called once, on the main loop.
function M.scan(root, opts, on_done)
  local uv = vim.uv
  root = path.absolute(root)
  local excludes = compile_excludes(opts and opts.exclude)

  local ignore_names = {}
  local ignore_enabled = false
  for _, name in ipairs(opts and opts.ignore_files or {}) do
    ignore_names[name] = true
    ignore_enabled = true
  end

  local snapshot = {}
  local pending = 0
  local done = false

  local function finish()
    if pending == 0 and not done then
      done = true
      vim.schedule(function()
        on_done(snapshot)
      end)
    end
  end

  local function is_excluded(name)
    for _, pat in ipairs(excludes) do
      if name:find(pat) then
        return true
      end
    end
    return false
  end

  local function record_file(rel, abs, stat)
    snapshot[path.compare_key(rel)] = {
      rel = rel,
      abs = abs,
      size = stat.size,
      mtime = stat.mtime.sec,
    }
  end

  local walk
  walk = function(dir, rel_prefix, stack)
    pending = pending + 1
    uv.fs_scandir(dir, function(err, handle)
      if err or not handle then
        pending = pending - 1
        return finish()
      end

      -- Collect entries first: an ignore file affects its sibling entries, and
      -- scandir order is not guaranteed, so we must read it before applying.
      local entries = {}
      while true do
        local name, typ = uv.fs_scandir_next(handle)
        if not name then
          break
        end
        entries[#entries + 1] = { name = name, typ = typ }
      end

      -- Load any ignore files in this directory and extend the rule stack for
      -- this subtree (a fresh table, so sibling directories are unaffected).
      if ignore_enabled then
        for _, e in ipairs(entries) do
          if ignore_names[e.name] and e.typ ~= "directory" then
            local text = read_file_sync(dir .. "/" .. e.name)
            local frame = text and ignore.compile(e.name, text, rel_prefix)
            if frame then
              local extended = {}
              for _, f in ipairs(stack) do
                extended[#extended + 1] = f
              end
              extended[#extended + 1] = frame
              stack = extended
            end
          end
        end
      end

      for _, e in ipairs(entries) do
        local name, typ = e.name, e.typ
        if not is_excluded(name) then
          local rel = rel_prefix == "" and name or (rel_prefix .. "/" .. name)
          local is_dir = typ == "directory"
          if not ignore.matches(stack, rel, is_dir) then
            local abs = dir .. "/" .. name
            if is_dir then
              walk(abs, rel, stack)
            else
              -- file, symlink, or unknown type: stat to obtain metadata and
              -- resolve. Only regular files are recorded; symlinked/unknown
              -- directories are not followed (spec: symlink loops out of scope).
              pending = pending + 1
              uv.fs_stat(abs, function(serr, stat)
                if not serr and stat and stat.type == "file" then
                  record_file(rel, abs, stat)
                end
                pending = pending - 1
                finish()
              end)
            end
          end
        end
      end

      pending = pending - 1
      finish()
    end)
  end

  walk(root, "", {})
end

return M
