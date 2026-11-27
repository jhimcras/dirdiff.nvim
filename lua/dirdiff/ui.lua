-- Scratch-buffer result view: rendering, highlighting, and buffer-local keymaps.
local group = require("dirdiff.group")

local M = {}

local ns = vim.api.nvim_create_namespace("dirdiff")

-- Lines before the first grouped item: "A: ...", "B: ...", "Sort: ...", "".
local PRELUDE = 4

local SYMBOLS = { added = "+ ", deleted = "- ", modified = "~ ", equal = "= " }
local GROUPS = {
  added = "DirDiffAdded",
  deleted = "DirDiffDeleted",
  modified = "DirDiffModified",
  equal = "DirDiffEqual",
}

local FOLD_OPEN = "\u{25bc}" -- ▼
local FOLD_CLOSED = "\u{25b6}" -- ▶

-- Define the plugin highlight groups, linked to the configured groups.
function M.setup_highlights(highlights)
  local links = {
    DirDiffAdded = highlights.added,
    DirDiffDeleted = highlights.deleted,
    DirDiffModified = highlights.modified,
    DirDiffEqual = highlights.equal,
  }
  for hl_group, link in pairs(links) do
    vim.api.nvim_set_hl(0, hl_group, { link = link, default = true })
  end
  vim.api.nvim_set_hl(0, "DirDiffGroupHeader", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "DirDiffSubHeader", { link = "NonText", default = true })
  vim.api.nvim_set_hl(0, "DirDiffCurrent", { link = "QuickFixLine", default = true })
end

-- Result lines can't contain a literal newline (valid in Linux file names).
local function display(s)
  return (s:gsub("\n", "\\n"))
end

local function exists(p)
  return p ~= nil and vim.uv.fs_stat(p) ~= nil
end

-- Per-comparison UI state (created by init.lua, one per result list):
--   buf      current result buffer (a re-render swaps it)
--   tabpage  tabpage the result list lives in
--   diff_wins  winids of the open diff pane(s) (one for single-side entries,
--            two when both sides exist), so the next selection can reuse or
--            replace them instead of accumulating splits
--   mark     { buf, id } extmark of the line currently shown in the panes
--   mapped   buf -> lhs -> previous buffer-local mapping (or false) that the
--            goto-list binding on a diff pane buffer replaced
-- Keeping this per comparison (not module-global) stops one comparison's
-- panes/cleanup from touching another tab's.

-- Undo the goto-list bindings made on diff pane buffers, restoring any
-- buffer-local mapping the user already had on that same key (a pane may
-- show a buffer that is also open in a normal window).
local function unbind_goto(state)
  for buf, keys in pairs(state.mapped) do
    if vim.api.nvim_buf_is_valid(buf) then
      for lhs, saved in pairs(keys) do
        pcall(vim.api.nvim_buf_del_keymap, buf, "n", lhs)
        if saved then
          vim.api.nvim_buf_call(buf, function()
            vim.fn.mapset("n", false, saved)
          end)
        end
      end
    end
  end
  state.mapped = {}
end

local function close_diff_wins(state)
  unbind_goto(state)
  for _, win in ipairs(state.diff_wins) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  state.diff_wins = {}
end

local function valid_wins(wins)
  local out = {}
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      out[#out + 1] = win
    end
  end
  return out
end

-- Windows in tabpage that "belong to" the diff panes: a loclist opened
-- from win_a/win_b, or the tab's quickfix window. Closed together with
-- the diff panes when the result list itself closes.
local function related_windows(state, tabpage)
  local related = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    local info = vim.fn.getwininfo(win)[1]
    if info and info.loclist == 1 then
      local owner = vim.fn.getloclist(win, { filewinid = 0 }).filewinid
      for _, dwin in ipairs(state.diff_wins) do
        if owner == dwin then
          related[#related + 1] = win
          break
        end
      end
    elseif info and info.quickfix == 1 then
      related[#related + 1] = win
    end
  end
  return related
end

-- Closes the diff panes (and any loclist/quickfix window opened from
-- them) when the result list buffer closes. Closes the whole tab too,
-- unless some unrelated window is also open there.
local function cleanup_on_close(state, tabpage)
  local related = related_windows(state, tabpage)
  close_diff_wins(state)
  for _, win in ipairs(related) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  if vim.api.nvim_tabpage_is_valid(tabpage) then
    local remaining = vim.api.nvim_tabpage_list_wins(tabpage)
    if #remaining <= 1 and #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(tabpage))
    end
  end
end

-- lhs may be a string, a list of strings (bound to the same fn), or false
-- to disable that binding (config.lua's `keymaps` option).
local function bind(buf, lhs, fn)
  if lhs == false or lhs == nil then
    return
  end
  if type(lhs) == "table" then
    for _, k in ipairs(lhs) do
      bind(buf, k, fn)
    end
    return
  end
  vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
end

-- Binds the goto-list key on a diff pane buffer, remembering the user's own
-- buffer-local mapping of that key so unbind_goto can restore it.
local function bind_goto(state, buf, lhs, fn)
  if lhs == false or lhs == nil then
    return
  end
  if type(lhs) == "table" then
    for _, k in ipairs(lhs) do
      bind_goto(state, buf, k, fn)
    end
    return
  end
  local keys = state.mapped[buf] or {}
  state.mapped[buf] = keys
  if keys[lhs] == nil then
    local prev = vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg(lhs, "n", false, true)
    end)
    keys[lhs] = prev.buffer == 1 and prev or false
  end
  bind(buf, lhs, fn)
end

-- Extmark marking which difflist line is currently shown in the diff
-- split, so the marker moves (not accumulates) as the user selects new
-- entries.
local function mark_current_line(state, buf, lnum, len)
  local opts = {
    end_row = lnum - 1,
    end_col = len,
    hl_group = "DirDiffCurrent",
    hl_mode = "combine",
    priority = 4097,
  }
  local mark = state.mark
  if mark and mark.buf == buf then
    opts.id = mark.id
  end
  state.mark = { buf = buf, id = vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, opts) }
end

-- Shows path in win via its buffer (not `:edit <path>`, which can't take
-- file names containing a newline).
local function show_file(win, path)
  vim.api.nvim_win_set_buf(win, vim.fn.bufadd(path))
end

-- Splits list_win, inside the same tab, to show the given file(s) as diff
-- pane(s): three vertical splits (list | A | B) when the tab is wider
-- than it is tall, or a fixed-height list strip on top with A/B
-- side-by-side below when it's taller than wide (config.lua's `layout`
-- option). Sizes are set *after* splitting so Neovim auto-grows the
-- sibling window to fill whatever space is left.
local function open_pair(state, list_win, abs_a, abs_b, layout, goto_list_lhs)
  vim.api.nvim_set_current_win(list_win)
  -- list_win's own size (not the editor's) is what's actually available to
  -- split, since other windows already in the tab (e.g. a loclist/quickfix
  -- window) aren't touched by splitting list_win.
  local avail_w = vim.api.nvim_win_get_width(list_win)
  local avail_h = vim.api.nvim_win_get_height(list_win)
  local wide = avail_w > avail_h

  -- With 'equalalways' on (Neovim's default), each split below triggers a
  -- re-equalization across *every* window in the tab, not just the ones
  -- being split -- so other windows (e.g. a loclist/quickfix pane) get
  -- resized too, and win_b's auto-grow absorbs whatever that leaves
  -- behind instead of just list_win's own space. Disable it for the
  -- split sequence so only list_win's own area is redistributed.
  local saved_equalalways = vim.o.equalalways
  vim.o.equalalways = false

  local win_a, win_b
  if wide then
    vim.cmd("belowright vsplit")
    win_a = vim.api.nvim_get_current_win()
    show_file(win_a, abs_a)
    if abs_b then
      vim.cmd("belowright vsplit")
      win_b = vim.api.nvim_get_current_win()
      show_file(win_b, abs_b)
    end

    vim.o.equalalways = saved_equalalways
    local cfg = layout.wide
    local list_w = math.floor(avail_w * cfg.list / (cfg.list + cfg.a + cfg.b))
    vim.api.nvim_win_set_width(list_win, list_w)
    if win_b then
      local a_w = math.floor((avail_w - list_w) * cfg.a / (cfg.a + cfg.b))
      vim.api.nvim_win_set_width(win_a, a_w)
    end
  else
    vim.cmd("belowright split")
    win_a = vim.api.nvim_get_current_win()
    show_file(win_a, abs_a)
    if abs_b then
      vim.cmd("belowright vsplit")
      win_b = vim.api.nvim_get_current_win()
      show_file(win_b, abs_b)
    end

    -- Same equalalways-restore-before-resize ordering as the wide branch:
    -- restoring it after these nvim_win_set_height/width calls would trigger
    -- an immediate re-equalize pass that undoes them.
    vim.o.equalalways = saved_equalalways
    local cfg = layout.tall
    vim.api.nvim_win_set_height(list_win, cfg.list_height)
    if win_b then
      local a_w = math.floor(avail_w * cfg.a / (cfg.a + cfg.b))
      vim.api.nvim_win_set_width(win_a, a_w)
    end
  end

  -- win_a/win_b were split off of list_win, so they inherit its window-local
  -- 'foldtext' override; clear it so they fall back to the (global) default
  -- instead of showing dirdiff's group-fold text on the user's own files.
  vim.api.nvim_win_call(win_a, function()
    vim.cmd("setlocal foldtext<")
  end)
  if win_b then
    vim.api.nvim_win_call(win_b, function()
      vim.cmd("setlocal foldtext<")
    end)
  end

  if win_b then
    vim.api.nvim_win_call(win_a, function()
      vim.cmd("diffthis")
    end)
    vim.api.nvim_win_call(win_b, function()
      vim.cmd("diffthis")
    end)
    state.diff_wins = { win_a, win_b }
  else
    state.diff_wins = { win_a }
  end

  for _, win in ipairs(state.diff_wins) do
    bind_goto(state, vim.api.nvim_win_get_buf(win), goto_list_lhs, function()
      M.goto_list(state)
    end)
  end

  -- B is created last and would otherwise keep focus; always land in A.
  vim.api.nvim_set_current_win(win_a)
end

-- Reuses already-open diff windows for a new entry instead of closing and
-- re-splitting: swaps each window's buffer and re-diffs in place. Avoids
-- re-triggering open_pair's split/resize (and the size-squeeze it can
-- suffer from other tab windows) on every navigation.
local function reuse_pair(state, wins, paths, goto_list_lhs)
  -- Restore mappings on the buffers about to leave the panes.
  unbind_goto(state)
  -- Window-local `diffoff` on our panes only: `diffoff!` would also turn
  -- off diff mode in unrelated windows of the same tab.
  for _, win in ipairs(wins) do
    vim.api.nvim_win_call(win, function()
      vim.cmd("diffoff")
    end)
  end
  for i, win in ipairs(wins) do
    show_file(win, paths[i])
  end

  if #wins == 2 then
    for _, win in ipairs(wins) do
      vim.api.nvim_win_call(win, function()
        vim.cmd("diffthis")
      end)
    end
  end

  for _, win in ipairs(wins) do
    bind_goto(state, vim.api.nvim_win_get_buf(win), goto_list_lhs, function()
      M.goto_list(state)
    end)
  end

  vim.api.nvim_set_current_win(wins[1])
end

-- Open the diff/file for an entry inside list_win's tab, re-validating
-- existence first (spec 2.3). Reuses the currently open diff windows when
-- there are exactly as many as this entry needs; otherwise replaces
-- whatever diff panes are open. Returns true if a diff pane was actually
-- opened.
local function open_entry(state, list_win, entry, layout, goto_list_lhs)
  local a_ok = exists(entry.abs_a)
  local b_ok = exists(entry.abs_b)

  local paths, warning
  if entry.status == "modified" or entry.status == "equal" then
    if a_ok and b_ok then
      paths = { entry.abs_a, entry.abs_b }
    elseif a_ok then
      paths = { entry.abs_a }
      warning = "dirdiff: other side no longer exists"
    elseif b_ok then
      paths = { entry.abs_b }
      warning = "dirdiff: other side no longer exists"
    end
  else
    local target = a_ok and entry.abs_a or (b_ok and entry.abs_b or nil)
    if target then
      paths = { target }
    end
  end

  if not paths then
    close_diff_wins(state)
    vim.notify("dirdiff: file no longer exists", vim.log.levels.WARN)
    return false
  end

  local existing = valid_wins(state.diff_wins)
  if #existing == #paths then
    state.diff_wins = existing
    reuse_pair(state, existing, paths, goto_list_lhs)
  else
    close_diff_wins(state)
    open_pair(state, list_win, paths[1], paths[2], layout, goto_list_lhs)
  end

  if warning then
    vim.notify(warning, vim.log.levels.WARN)
  end
  return true
end

function M.new_state()
  return { diff_wins = {}, mapped = {} }
end

-- Focuses the window showing state's result list, if it is still open.
function M.goto_list(state)
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    local win = vim.fn.win_findbuf(state.buf)[1]
    if win then
      vim.api.nvim_set_current_win(win)
    end
  end
end

-- Whether win is one of state's open diff panes.
function M.owns_win(state, win)
  return vim.tbl_contains(state.diff_wins, win)
end

-- foldtext for closed dirdiff group folds: swap the trailing "▼" baked into
-- the (open-state) header line for "▶", using the buffer-local text saved by
-- M.render (avoids re-deriving label/count from the folded line itself).
function M.foldtext()
  local display = vim.b.dirdiff_fold_display or {}
  local base = display[vim.v.foldstart] or vim.fn.getline(vim.v.foldstart)
  return base .. " " .. FOLD_CLOSED
end

-- ctx = { state (from M.new_state), root_a, root_b, entries, sort, keymaps, win, on_refresh,
--         on_toggle_separation, on_toggle_equal, on_toggle_diff_first }
function M.render(ctx)
  local state = ctx.state
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "dirdiff"

  local sort_line = string.format(
    "Sort: %s | Equal: %s | Diff-first: %s",
    ctx.sort.separation,
    ctx.sort.equal,
    tostring(ctx.sort.diff_first)
  )
  local lines = {
    "A: " .. ctx.root_a,
    "B: " .. ctx.root_b,
    sort_line,
    "",
  }
  local line_map = {} -- 1-indexed buffer line -> entry
  local fold_display = {} -- 1-indexed buffer line -> header text (sans arrow)

  local items, folds = group.build(ctx.entries, ctx.sort)

  if #items == 0 then
    lines[#lines + 1] = "No differences."
  else
    for _, item in ipairs(items) do
      if item.kind == "header" then
        local indent = item.level == 2 and "  " or ""
        local unit = item.count == 1 and "file" or "files"
        local label = indent .. display(item.text) .. " (" .. item.count .. " " .. unit .. ")"
        lines[#lines + 1] = label .. " " .. FOLD_OPEN
        fold_display[#lines] = label
      elseif item.kind == "blank" then
        lines[#lines + 1] = ""
      else
        lines[#lines + 1] = SYMBOLS[item.entry.status] .. display(item.entry.rel)
        line_map[#lines] = item.entry
      end
    end
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.b[buf].dirdiff_fold_display = fold_display

  for lnum, e in pairs(line_map) do
    vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
      end_row = lnum - 1,
      end_col = #lines[lnum],
      hl_group = GROUPS[e.status],
    })
  end

  for i, item in ipairs(items) do
    if item.kind == "header" then
      local lnum = PRELUDE + i
      vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
        end_row = lnum - 1,
        end_col = #lines[lnum],
        hl_group = item.level == 2 and "DirDiffSubHeader" or "DirDiffGroupHeader",
      })
    end
  end

  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  local target_win = ctx.win or 0
  -- Make buf the current result buffer *before* it replaces the old one in
  -- the window: the old buffer's wipeout is then recognised as a re-render
  -- (not a close) and leaves the diff panes alone.
  state.buf = buf
  state.tabpage = vim.api.nvim_win_get_tabpage(target_win)
  vim.api.nvim_win_set_buf(target_win, buf)

  -- Fires however the result buffer goes away (the `close` keymap, :bd,
  -- :bwipeout) since bufhidden=wipe means it always ends in a wipeout.
  local tabpage = state.tabpage
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if state.buf ~= buf then
        return
      end
      cleanup_on_close(state, tabpage)
    end,
  })

  -- Native folds so every group (not just "hidden" equal blocks) is
  -- user-collapsible with zo/za; the header's baked-in "▼"/"▶" (via
  -- M.foldtext) tracks the open/closed state automatically.
  vim.wo[target_win].foldmethod = "manual"
  vim.wo[target_win].foldenable = true
  -- Use scope="local" (not vim.wo, which also sets the hidden global default
  -- for this window-local option) so this custom foldtext doesn't become the
  -- default for every window Neovim creates afterwards, including win_a/win_b.
  vim.api.nvim_set_option_value("foldtext", "v:lua.require'dirdiff.ui'.foldtext()", {
    scope = "local",
    win = target_win,
  })
  if #folds > 0 then
    vim.api.nvim_win_call(target_win, function()
      for _, r in ipairs(folds) do
        vim.cmd(string.format("%d,%dfold", PRELUDE + r.first, PRELUDE + r.last))
      end
      vim.cmd("normal! zR")
      for _, r in ipairs(folds) do
        if r.closed then
          vim.cmd(string.format("%d,%dfoldclose", PRELUDE + r.first, PRELUDE + r.last))
        end
      end
    end)
  end

  local function map(lhs, fn)
    bind(buf, lhs, fn)
  end

  local keymaps = ctx.keymaps or {}

  map(keymaps.open, function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local entry = line_map[lnum]
    if entry then
      local opened = open_entry(state, vim.api.nvim_get_current_win(), entry, ctx.layout, keymaps.goto_list)
      if opened then
        mark_current_line(state, buf, lnum, #lines[lnum])
      end
    end
  end)

  local function refresh()
    if ctx.on_refresh then
      ctx.on_refresh()
    end
  end
  map(keymaps.refresh, refresh)

  map(keymaps.close, function()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  map(keymaps.toggle_separation, function()
    if ctx.on_toggle_separation then
      ctx.on_toggle_separation()
    end
  end)

  map(keymaps.toggle_equal, function()
    if ctx.on_toggle_equal then
      ctx.on_toggle_equal()
    end
  end)

  map(keymaps.toggle_diff_first, function()
    if ctx.on_toggle_diff_first then
      ctx.on_toggle_diff_first()
    end
  end)

  return buf
end

return M
