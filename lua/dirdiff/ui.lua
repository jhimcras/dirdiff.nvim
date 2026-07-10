-- Scratch-buffer result view: rendering, highlighting, and buffer-local keymaps.
local M = {}

local ns = vim.api.nvim_create_namespace("dirdiff")

local SYMBOLS = { added = "+ ", deleted = "- ", modified = "~ " }
local GROUPS = {
  added = "DirDiffAdded",
  deleted = "DirDiffDeleted",
  modified = "DirDiffModified",
}

-- Define the plugin highlight groups, linked to the configured groups.
function M.setup_highlights(highlights)
  local links = {
    DirDiffAdded = highlights.added,
    DirDiffDeleted = highlights.deleted,
    DirDiffModified = highlights.modified,
  }
  for group, link in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
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

-- ctx = { root_a, root_b, entries, on_refresh }
function M.render(ctx)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "dirdiff"

  local lines = {
    "A: " .. ctx.root_a,
    "B: " .. ctx.root_b,
    "",
  }
  local line_map = {} -- 1-indexed buffer line -> entry

  if #ctx.entries == 0 then
    lines[#lines + 1] = "No differences."
  else
    for _, e in ipairs(ctx.entries) do
      lines[#lines + 1] = SYMBOLS[e.status] .. e.rel
      line_map[#lines] = e
    end
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  for lnum, e in pairs(line_map) do
    vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
      end_row = lnum - 1,
      end_col = #lines[lnum],
      hl_group = GROUPS[e.status],
    })
  end

  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  vim.api.nvim_win_set_buf(0, buf)

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end

  map("<CR>", function()
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
  map("R", refresh)
  map("<F5>", refresh)

  map("q", function()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  return buf
end

return M
