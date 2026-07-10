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
  -- source of truth. The two options below are reserved: only byte-exact
  -- comparison is implemented for now, so their values have no effect yet.
  compare = {
    ignore_newline = false, -- (planned) treat CRLF/LF-only differences as identical
    ignore_encoding = false, -- (planned) treat encoding/BOM-only differences as identical
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
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
