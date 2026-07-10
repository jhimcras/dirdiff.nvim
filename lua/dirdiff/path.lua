-- Path normalization and platform-aware comparison helpers.
local M = {}

-- Evaluated once at load (main context). compare_key runs inside vim.uv
-- callbacks (fast event context) where vim.fn calls are unsafe.
local is_win = vim.fn.has("win32") == 1

function M.is_windows()
  return is_win
end

-- Normalize separators and expand `~`. Reuses vim.fs.normalize which turns
-- backslashes into forward slashes on Windows and collapses `.`/`..`.
function M.normalize(p)
  return vim.fs.normalize(p)
end

-- Absolute, normalized path (no trailing slash except root).
function M.absolute(p)
  return M.normalize(vim.fn.fnamemodify(p, ":p"))
end

-- Join two path segments with a forward slash.
function M.join(a, b)
  return vim.fs.joinpath(a, b)
end

-- Splits a raw :DirDiff argument string into fields. A field may be wrapped
-- in matching double or single quotes, which lets Windows paths containing
-- spaces be passed as one argument; the quotes are stripped and backslashes
-- are left untouched (not treated as escapes) so `"C:\Users\a b"` survives
-- intact. Plain nvim fargs splitting only breaks on whitespace and leaves
-- stray quote characters embedded in the path, which then fails
-- isdirectory/fnamemodify checks.
function M.parse_args(argstr)
  local args = {}
  local i, len = 1, #argstr
  while i <= len do
    local c = argstr:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c == '"' or c == "'" then
      local close = argstr:find(c, i + 1, true)
      if close then
        table.insert(args, argstr:sub(i + 1, close - 1))
        i = close + 1
      else
        table.insert(args, argstr:sub(i + 1))
        i = len + 1
      end
    else
      local j = i
      while j <= len and not argstr:sub(j, j):match("%s") do
        j = j + 1
      end
      table.insert(args, argstr:sub(i, j - 1))
      i = j
    end
  end
  return args
end

-- Comparison key for a relative path. Windows is case-insensitive, other
-- platforms are case-sensitive (spec 3.3).
function M.compare_key(rel)
  if M.is_windows() then
    return rel:lower()
  end
  return rel
end

return M
