-- Default options and user merge.
local M = {}

M.defaults = {
  -- Glob patterns matched against each entry's basename and skipped.
  exclude = { ".git", "node_modules", ".DS_Store" },
  -- Names of per-folder ignore-list files (e.g. { ".gitignore" }) whose
  -- contents are read and applied as ignore rules to that folder and all of its
  -- subfolders. Empty disables the feature. The ignore file itself is not
  -- skipped unless its name is also in `exclude`.
  ignore_files = { ".gitignore" },
  -- How "modified" is decided when a file exists on both sides. mtime alone
  -- never marks a file modified (it changes on copy/checkout); content is the
  -- source of truth. Enabling either option below makes files whose byte size
  -- differs only because of newlines/BOM get content-verified instead of being
  -- assumed modified.
  compare = {
    ignore_newline = false, -- treat CRLF/CR/LF newline differences as identical
    ignore_encoding = false, -- treat a leading BOM difference as identical (BOM strip only)
  },
  -- Sort/grouping of the result view.
  sort = {
    -- "folder_diff": folder groups, then status subgroups within each.
    -- "diff_folder": status groups, then folder subgroups within each.
    -- "diff_only": status groups only, entries listed flat.
    -- "folder_only": folder groups only, statuses mixed inline.
    separation = "diff_only",
    -- "skip": never show identical files. "show": show them normally.
    -- "hidden": show them, but folded closed by default.
    equal = "skip",
    -- true: the "Diff" (modified) group is listed before "A only"/"B only".
    diff_first = false,
  },
  -- Highlight groups used for each diff status. Linked to built-in diff
  -- groups so they follow the active colorscheme (green/red/yellow).
  highlights = {
    added = "DiffAdd",
    deleted = "DiffDelete",
    modified = "DiffChange",
    equal = "Comment",
  },
  -- Buffer-local keymaps for the result view. Set an entry to `false` to
  -- disable it. `refresh` accepts a list of keys bound to the same action.
  keymaps = {
    open = "<CR>",
    refresh = { "R", "<F5>" },
    close = "q",
    toggle_separation = "gs",
    toggle_equal = "ge",
    toggle_diff_first = "gd",
  },
  -- Split layout for the per-file diff view, shown inside the same tab as
  -- the result list. Orientation is chosen by comparing the editor's total
  -- columns vs. lines.
  layout = {
    -- Used when columns > lines: three vertical splits, list | A | B.
    -- Values are ratios (not literal columns); list's share of the total
    -- width is list/(list+a+b), and a/b split the remainder by a/(a+b).
    wide = { list = 10, a = 45, b = 45 },
    -- Used when lines >= columns: list gets a fixed height (lines) across
    -- the full width; A/B split the remaining height's width side-by-side,
    -- by ratio a/(a+b).
    tall = { list_height = 10, a = 50, b = 50 },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
