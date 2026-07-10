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
end

local function exists(p)
  return p ~= nil and vim.uv.fs_stat(p) ~= nil
end

-- Open the diff/file for an entry, re-validating existence first (spec 2.3).
local function open_entry(entry)
  local a_ok = exists(entry.abs_a)
  local b_ok = exists(entry.abs_b)

  if entry.status == "modified" then
    if a_ok and b_ok then
      vim.cmd.tabedit(vim.fn.fnameescape(entry.abs_a))
      vim.cmd("diffsplit " .. vim.fn.fnameescape(entry.abs_b))
    elseif a_ok then
      vim.cmd.tabedit(vim.fn.fnameescape(entry.abs_a))
      vim.notify("dirdiff: other side no longer exists", vim.log.levels.WARN)
    elseif b_ok then
      vim.cmd.tabedit(vim.fn.fnameescape(entry.abs_b))
      vim.notify("dirdiff: other side no longer exists", vim.log.levels.WARN)
    else
      vim.notify("dirdiff: file no longer exists", vim.log.levels.WARN)
    end
    return
  end

  local target = a_ok and entry.abs_a or (b_ok and entry.abs_b or nil)
  if target then
    vim.cmd.tabedit(vim.fn.fnameescape(target))
  else
    vim.notify("dirdiff: file no longer exists", vim.log.levels.WARN)
  end
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

  -- Native folds so every group (not just "hidden" equal blocks) is
  -- user-collapsible with zo/za; the header's baked-in "▼"/"▶" (via
  -- M.foldtext) tracks the open/closed state automatically.
  vim.wo[target_win].foldmethod = "manual"
  vim.wo[target_win].foldenable = true
  vim.wo[target_win].foldtext = "v:lua.require'dirdiff.ui'.foldtext()"
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

  -- lhs may be a string, a list of strings (bound to the same fn), or false
  -- to disable that binding (config.lua's `keymaps` option).
  local function map(lhs, fn)
    if lhs == false or lhs == nil then
      return
    end
    if type(lhs) == "table" then
      for _, k in ipairs(lhs) do
        map(k, fn)
      end
      return
    end
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end

  local keymaps = ctx.keymaps or {}

  map(keymaps.open, function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local entry = line_map[lnum]
    if entry then
      open_entry(entry)
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
