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

local function exists(p)
  return p ~= nil and vim.uv.fs_stat(p) ~= nil
end

-- Winids of the currently open diff pane(s) (one for single-side entries,
-- two for a modified entry with both sides present), so the next
-- selection can close them before opening the new one instead of
-- accumulating splits (spec: replace, don't accumulate).
local diff_wins = {}

local function close_diff_wins()
  for _, win in ipairs(diff_wins) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  diff_wins = {}
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
local function related_windows(tabpage)
  local related = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    local info = vim.fn.getwininfo(win)[1]
    if info and info.loclist == 1 then
      local owner = vim.fn.getloclist(win, { filewinid = 0 }).filewinid
      for _, dwin in ipairs(diff_wins) do
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
local function cleanup_on_close(tabpage)
  local related = related_windows(tabpage)
  close_diff_wins()
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

-- Extmark marking which difflist line is currently shown in the diff
-- split, so the marker moves (not accumulates) as the user selects new
-- entries.
local current_mark = { buf = nil, id = nil }

local function mark_current_line(buf, lnum, len)
  local opts = {
    end_row = lnum - 1,
    end_col = len,
    hl_group = "DirDiffCurrent",
    hl_mode = "combine",
    priority = 4097,
  }
  if current_mark.buf == buf then
    opts.id = current_mark.id
  end
  current_mark.id = vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, opts)
  current_mark.buf = buf
end

-- Splits list_win, inside the same tab, to show the given file(s) as diff
-- pane(s): three vertical splits (list | A | B) when the tab is wider
-- than it is tall, or a fixed-height list strip on top with A/B
-- side-by-side below when it's taller than wide (config.lua's `layout`
-- option). Sizes are set *after* splitting so Neovim auto-grows the
-- sibling window to fill whatever space is left.
local function open_pair(list_win, abs_a, abs_b, layout, goto_list_lhs)
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
    vim.cmd("belowright vsplit " .. vim.fn.fnameescape(abs_a))
    win_a = vim.api.nvim_get_current_win()
    if abs_b then
      vim.cmd("belowright vsplit " .. vim.fn.fnameescape(abs_b))
      win_b = vim.api.nvim_get_current_win()
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
    vim.cmd("belowright split " .. vim.fn.fnameescape(abs_a))
    win_a = vim.api.nvim_get_current_win()
    if abs_b then
      vim.cmd("belowright vsplit " .. vim.fn.fnameescape(abs_b))
      win_b = vim.api.nvim_get_current_win()
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
    diff_wins = { win_a, win_b }
  else
    diff_wins = { win_a }
  end

  local function goto_list()
    require("dirdiff").goto_list()
  end
  bind(vim.api.nvim_win_get_buf(win_a), goto_list_lhs, goto_list)
  if win_b then
    bind(vim.api.nvim_win_get_buf(win_b), goto_list_lhs, goto_list)
  end

  -- B is created last and would otherwise keep focus; always land in A.
  vim.api.nvim_set_current_win(win_a)
end

-- Reuses already-open diff windows for a new entry instead of closing and
-- re-splitting: swaps each window's buffer and re-diffs in place. Avoids
-- re-triggering open_pair's split/resize (and the size-squeeze it can
-- suffer from other tab windows) on every navigation.
local function reuse_pair(wins, paths, goto_list_lhs)
  vim.cmd("diffoff!")
  for i, win in ipairs(wins) do
    vim.api.nvim_win_call(win, function()
      vim.cmd("edit " .. vim.fn.fnameescape(paths[i]))
    end)
  end

  if #wins == 2 then
    for _, win in ipairs(wins) do
      vim.api.nvim_win_call(win, function()
        vim.cmd("diffthis")
      end)
    end
  end

  local function goto_list()
    require("dirdiff").goto_list()
  end
  for _, win in ipairs(wins) do
    bind(vim.api.nvim_win_get_buf(win), goto_list_lhs, goto_list)
  end

  vim.api.nvim_set_current_win(wins[1])
end

-- Open the diff/file for an entry inside list_win's tab, re-validating
-- existence first (spec 2.3). Reuses the currently open diff windows when
-- there are exactly as many as this entry needs; otherwise replaces
-- whatever diff panes are open. Returns true if a diff pane was actually
-- opened.
local function open_entry(list_win, entry, layout, goto_list_lhs)
  local a_ok = exists(entry.abs_a)
  local b_ok = exists(entry.abs_b)

  local paths, warning
  if entry.status == "modified" then
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
    close_diff_wins()
    vim.notify("dirdiff: file no longer exists", vim.log.levels.WARN)
    return false
  end

  local existing = valid_wins(diff_wins)
  if #existing == #paths then
    diff_wins = existing
    reuse_pair(existing, paths, goto_list_lhs)
  else
    close_diff_wins()
    open_pair(list_win, paths[1], paths[2], layout, goto_list_lhs)
  end

  if warning then
    vim.notify(warning, vim.log.levels.WARN)
  end
  return true
end

-- foldtext for closed dirdiff group folds: swap the trailing "▼" baked into
-- the (open-state) header line for "▶", using the buffer-local text saved by
-- M.render (avoids re-deriving label/count from the folded line itself).
function M.foldtext()
  local display = vim.b.dirdiff_fold_display or {}
  local base = display[vim.v.foldstart] or vim.fn.getline(vim.v.foldstart)
  return base .. " " .. FOLD_CLOSED
end

-- ctx = { root_a, root_b, entries, sort, keymaps, win, on_refresh,
--         on_toggle_separation, on_toggle_equal, on_toggle_diff_first }
function M.render(ctx)
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
        local label = indent .. item.text .. " (" .. item.count .. " " .. unit .. ")"
        lines[#lines + 1] = label .. " " .. FOLD_OPEN
        fold_display[#lines] = label
      elseif item.kind == "blank" then
        lines[#lines + 1] = ""
      else
        lines[#lines + 1] = SYMBOLS[item.entry.status] .. item.entry.rel
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
  vim.api.nvim_win_set_buf(target_win, buf)

  -- Fires however the result buffer goes away (the `close` keymap, :bd,
  -- :bwipeout) since bufhidden=wipe means it always ends in a wipeout.
  local tabpage = vim.api.nvim_win_get_tabpage(target_win)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      cleanup_on_close(tabpage)
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
      local opened = open_entry(vim.api.nvim_get_current_win(), entry, ctx.layout, keymaps.goto_list)
      if opened then
        mark_current_line(buf, lnum, #lines[lnum])
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
