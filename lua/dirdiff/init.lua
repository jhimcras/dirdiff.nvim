-- Public API and orchestration for dirdiff.nvim.
local config = require("dirdiff.config")
local path = require("dirdiff.path")
local scan = require("dirdiff.scan")
local diff = require("dirdiff.diff")
local content = require("dirdiff.content")
local group = require("dirdiff.group")
local ui = require("dirdiff.ui")

local M = {}

-- Soft lock: reject overlapping comparison/refresh requests (spec 2.2).
local is_comparing = false
-- Remembers the last comparison so refresh can rescan the same roots.
local last = nil
-- Full resolved entries (incl. "equal") from the most recent completed
-- compare, kept around so sort/grouping toggles can re-render without
-- re-scanning the filesystem.
local last_entries = nil
-- bufnr of the most recently rendered result buffer, or nil.
local last_buf = nil

function M.setup(opts)
  config.setup(opts)
  ui.setup_highlights(config.options.highlights)
end

-- Renders last_entries into win (or the current window if win is nil),
-- using the current sort/keymaps config. No-op if nothing has been compared
-- yet.
local function render_current(win)
  if not last or not last_entries then
    return
  end
  last_buf = ui.render({
    root_a = last.root_a,
    root_b = last.root_b,
    entries = last_entries,
    sort = config.options.sort,
    keymaps = config.options.keymaps,
    win = win,
    on_refresh = M.refresh,
    on_toggle_separation = M.toggle_separation,
    on_toggle_equal = M.toggle_equal,
    on_toggle_diff_first = M.toggle_diff_first,
  })
end

local function has_open_result_buffer()
  return last_buf ~= nil and vim.api.nvim_buf_is_valid(last_buf)
end

-- Mutates config.options.sort (so the change persists as the session
-- default) and, if a result buffer is currently displayed somewhere,
-- re-renders it in place without triggering a re-scan. Never hijacks an
-- unrelated window.
local function apply_toggle(mutate)
  mutate()
  if has_open_result_buffer() then
    local winid = vim.fn.bufwinid(last_buf)
    if winid ~= -1 then
      render_current(winid)
      return
    end
  end
  vim.notify("dirdiff: setting saved for the next :DirDiff", vim.log.levels.INFO)
end

function M.toggle_separation()
  apply_toggle(function()
    config.options.sort.separation = group.next_separation(config.options.sort.separation)
  end)
end

function M.toggle_equal()
  apply_toggle(function()
    config.options.sort.equal = group.next_equal(config.options.sort.equal)
  end)
end

function M.toggle_diff_first()
  apply_toggle(function()
    config.options.sort.diff_first = not config.options.sort.diff_first
  end)
end

local function compare(root_a, root_b)
  if is_comparing then
    vim.notify("dirdiff: a scan is already in progress", vim.log.levels.INFO)
    return
  end
  if vim.fn.isdirectory(root_a) == 0 then
    vim.notify("dirdiff: not a directory: " .. root_a, vim.log.levels.ERROR)
    return
  end
  if vim.fn.isdirectory(root_b) == 0 then
    vim.notify("dirdiff: not a directory: " .. root_b, vim.log.levels.ERROR)
    return
  end

  -- Highlight groups are idempotent + default=true, so this is safe to call
  -- even when the user never invoked setup().
  ui.setup_highlights(config.options.highlights)

  is_comparing = true
  last = { root_a = root_a, root_b = root_b }

  local snap_a, snap_b
  local function try_render()
    if snap_a and snap_b then
      -- Confirm same-size/different-mtime candidates by content before
      -- rendering; is_comparing is released once verification completes.
      content.resolve(diff.compute(snap_a, snap_b), config.options.compare, function(entries)
        is_comparing = false
        last_entries = entries
        render_current(nil)
      end)
    end
  end

  scan.scan(root_a, config.options, function(s)
    snap_a = s
    try_render()
  end)
  scan.scan(root_b, config.options, function(s)
    snap_b = s
    try_render()
  end)
end

-- dir2 defaults to the current working directory (spec 3.3).
function M.open(dir1, dir2)
  local root_a = path.absolute(dir1)
  local root_b = dir2 and path.absolute(dir2) or path.absolute(vim.fn.getcwd())
  compare(root_a, root_b)
end

function M.refresh()
  if not last then
    return
  end
  compare(last.root_a, last.root_b)
end

return M
