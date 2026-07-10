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

-- Comparison key for a relative path. Windows is case-insensitive, other
-- platforms are case-sensitive (spec 3.3).
function M.compare_key(rel)
  if M.is_windows() then
    return rel:lower()
  end
  return rel
end

return M
