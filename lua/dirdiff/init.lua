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
-- One session per comparison/result list (each normally in its own tab):
-- { root_a, root_b, entries, ui }. `entries` are the full resolved entries
-- (incl. "equal") from the last completed compare, kept so sort/grouping
-- toggles can re-render without re-scanning; `ui` is the per-list UI state
-- owned by dirdiff.ui. Most recently rendered is last.
local sessions = {}

function M.setup(opts)
  config.setup(opts)
  ui.setup_highlights(config.options.highlights)
end

local function session_open(session)
  return session.ui.buf ~= nil and vim.api.nvim_buf_is_valid(session.ui.buf)
end

-- Drops sessions whose result buffer is gone and returns the live ones.
local function live_sessions()
  local live = {}
  for _, session in ipairs(sessions) do
    if session_open(session) then
      live[#live + 1] = session
    end
  end
  sessions = live
  return live
end

-- Session whose result list or diff panes are in the current tab, or nil.
local function current_session()
  local tabpage = vim.api.nvim_get_current_tabpage()
  for _, session in ipairs(live_sessions()) do
    if session.ui.tabpage == tabpage then
      return session
    end
  end
end

-- The comparison in the current tab, else the most recently rendered one.
local function default_session()
  local session = current_session()
  if session then
    return session
  end
  local live = live_sessions()
  return live[#live]
end

-- Renders session.entries into win (or the current window if win is nil),
-- using the current sort/keymaps config.
local function render_session(session, win)
  ui.render({
    state = session.ui,
    root_a = session.root_a,
    root_b = session.root_b,
    entries = session.entries,
    sort = config.options.sort,
    keymaps = config.options.keymaps,
    layout = config.options.layout,
    win = win,
    on_refresh = function()
      M.refresh(session)
    end,
    on_toggle_separation = M.toggle_separation,
    on_toggle_equal = M.toggle_equal,
    on_toggle_diff_first = M.toggle_diff_first,
  })
  if not vim.tbl_contains(sessions, session) then
    sessions[#sessions + 1] = session
  end
end

-- Reuses the window currently showing the session's result buffer if it's
-- still open (so :DirDiff again, and refresh/toggle re-renders, stay in
-- place); otherwise opens a fresh tab for the result list.
local function target_list_window(session)
  if session_open(session) then
    local win = vim.fn.win_findbuf(session.ui.buf)[1]
    if win then
      return win
    end
  end
  vim.cmd("tabnew")
  return vim.api.nvim_get_current_win()
end

-- Mutates config.options.sort (so the change persists as the session
-- default) and re-renders every open result list in place, in whichever
-- tab it is, without triggering a re-scan. Never hijacks an unrelated
-- window.
local function apply_toggle(mutate)
  mutate()
  local rendered = false
  for _, session in ipairs(live_sessions()) do
    local winid = vim.fn.win_findbuf(session.ui.buf)[1]
    if winid then
      render_session(session, winid)
      rendered = true
    end
  end
  if not rendered then
    vim.notify("dirdiff: setting saved for the next :DirDiff", vim.log.levels.INFO)
  end
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

-- Jumps focus to the window showing the result list of the comparison in
-- the current tab (else the most recent one), if it's still open. Used by
-- :DirDiffGotoList.
function M.goto_list()
  local session = default_session()
  if session then
    ui.goto_list(session.ui)
  end
end

local function compare(session, root_a, root_b, refreshing)
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
  session.root_a = root_a
  session.root_b = root_b

  local snap_a, snap_b
  local function try_render()
    if snap_a and snap_b then
      -- Confirm same-size/different-mtime candidates by content before
      -- rendering; is_comparing is released once verification completes.
      content.resolve(diff.compute(snap_a, snap_b, config.options.compare), config.options.compare, function(entries)
        is_comparing = false
        -- A refresh whose list was closed meanwhile must not reopen it.
        if refreshing and not session_open(session) then
          return
        end
        session.entries = entries
        render_session(session, target_list_window(session))
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
  compare(current_session() or { ui = ui.new_state() }, root_a, root_b)
end

-- Rescans the roots of `session` (default: the comparison in the current
-- tab, else the most recent one) and re-renders it in place.
function M.refresh(session)
  session = session or default_session()
  if not session then
    return
  end
  compare(session, session.root_a, session.root_b, true)
end

return M
