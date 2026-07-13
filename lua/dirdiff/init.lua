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
    layout = config.options.layout,
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

-- Reuses the window currently showing the result buffer if it's still
-- open (so :DirDiff again, and refresh/toggle re-renders, stay in
-- place); otherwise opens a fresh tab for the result list.
local function target_list_window()
  if has_open_result_buffer() then
    local win = vim.fn.bufwinid(last_buf)
    if win ~= -1 then
      return win
    end
  end
  vim.cmd("tabnew")
  return vim.api.nvim_get_current_win()
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

-- Jumps focus to the window showing the last comparison's result list, if
-- it's still open. Used by the diff windows' goto-list keymap and by
-- :DirDiffGotoList.
function M.goto_list()
  if has_open_result_buffer() then
    local winid = vim.fn.bufwinid(last_buf)
    if winid ~= -1 then
      vim.api.nvim_set_current_win(winid)
    end
  end
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
      content.resolve(diff.compute(snap_a, snap_b, config.options.compare), config.options.compare, function(entries)
        is_comparing = false
        last_entries = entries
        render_current(target_list_window())
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

-- dir1 defaults to the current working directory when only one path is given (spec 3.3).
function M.open(dir1, dir2)
  local root_a, root_b
  if dir2 then
    root_a = path.absolute(dir1)
    root_b = path.absolute(dir2)
  else
    root_a = path.absolute(vim.fn.getcwd())
    root_b = path.absolute(dir1)
  end
  compare(root_a, root_b)
end

function M.refresh()
  if not last then
    return
  end
  compare(last.root_a, last.root_b)
end

return M
