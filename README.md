# dirdiff.nvim

A lightweight, fast Neovim plugin that lists structural differences (added/deleted/modified) between two directories. File **content** diffing is delegated to Neovim's built-in vimdiff; the plugin focuses solely on **listing differences across the whole directory tree**, including subfolders.

- Async scan powered by `vim.uv` (libuv) so even tens of thousands of files don't freeze the UI
- Zero external CLI dependencies, cross-platform on Windows/Linux/macOS
- Per-status highlights: added (green) / deleted (red) / modified (yellow)

## Requirements

Neovim 0.10+ (uses `vim.uv`, `vim.fs.joinpath`)

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "jhimcras/dirdiff.nvim",
  cmd = "DirDiff",
  opts = {},
}
```

### [pckr.nvim](https://github.com/lewis6991/pckr.nvim)

```lua
{
  "jhimcras/dirdiff.nvim",
  config = function()
    require("dirdiff").setup()
  end,
}
```

## Usage

```vim
:DirDiff <dir1> [<dir2>]
:DirDiffSeparation   " cycle the separation/grouping mode
:DirDiffEqual        " cycle Equal-file visibility (skip/show/hidden)
:DirDiffDiffFirst    " toggle whether Diff is listed before A only/B only
```

- Both relative and absolute paths are supported. If `<dir2>` is omitted, it compares `<dir1>` against the current working directory (`:pwd`).
- Directory completion (`-complete=dir`) is supported. Folder names containing spaces are automatically escaped during completion.
- Comparison is case-insensitive on Windows and case-sensitive on Linux/macOS.
- `:DirDiffSeparation` / `:DirDiffEqual` / `:DirDiffDiffFirst` change how the result is grouped and sorted; see [Sorting and grouping](#sorting-and-grouping). The chosen setting persists as the session default for subsequent `:DirDiff` calls. If run while no result buffer is open, the setting is saved silently (a notification confirms it) and applied the next time `:DirDiff` runs.

### Result view keymaps

Buffer-local mappings that only apply inside the result buffer:

| Key           | Action                                                                          |
| ------------- | -------------------------------------------------------------------------------- |
| `<CR>`        | Open the diff. Opens vimdiff if the file exists on both sides, otherwise opens the single existing file. |
| `R` / `<F5>`  | Re-scan both directories and refresh the result                                  |
| `q`           | Close the result view and clean up resources                                     |
| `gs`          | Cycle the separation/grouping mode (`folder_diff` → `diff_folder` → `diff_only` → `folder_only`) |
| `ge`          | Cycle Equal-file visibility (`skip` → `show` → `hidden`)                          |
| `gd`          | Toggle whether the Diff (modified) group is listed before A only/B only          |

All of the above are configurable via `keymaps` (see Configuration) — set a key to `false` to disable it, or a list of strings to bind several keys to the same action.

## Configuration

Works out of the box without calling `setup()`. To customize:

```lua
require("dirdiff").setup({
  -- Glob patterns matched against each entry's basename and skipped during
  -- the scan.
  exclude = { ".git", "node_modules", ".DS_Store" },
  -- Names of per-folder "ignore-list files". While scanning, each folder is
  -- checked for a file with this name and its contents are applied as ignore
  -- rules (default: empty = disabled).
  ignore_files = { ".gitignore" },
  -- How "modified" is determined. When either option is enabled, files that
  -- differ only in newlines/BOM are content-verified and reported as Equal.
  compare = {
    ignore_newline = false,  -- treat CRLF/CR/LF newline differences as identical
    ignore_encoding = false, -- treat a leading BOM difference as identical (BOM strip only)
  },
  -- Sort/grouping of the result view. See "Sorting and grouping" below.
  sort = {
    separation = "diff_only", -- "folder_diff" | "diff_folder" | "diff_only" | "folder_only"
    equal = "skip",           -- "skip" | "show" | "hidden"
    diff_first = false,
  },
  -- Highlight groups per status (linked to the colorscheme's diff colors).
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
})
```

### Ignore-list files (`ignore_files`)

Specifying a file name (e.g. `.gitignore`) in `ignore_files` means that whenever a file with that name is encountered during the scan, its **contents** are read and applied as ignore rules.

- Rules apply to the folder containing the file and **recursively to all of its subfolders** (standard `.gitignore` scope). Negation (`!`), path anchoring (`/`), directory-only (`dist/`), and wildcards (`*`, `?`, `**`) are all supported.
- Ignore rules are applied **per folder independently**. That is, folder A's `.gitignore` only affects A, and folder B's `.gitignore` only affects B (if only one side has an ignore file, the other side isn't filtered and those entries may show up as added/deleted).
- The ignore file itself (e.g. `.gitignore`) is not excluded from the result unless it's also listed in `exclude`.
- Only `.gitignore` syntax is supported for now; other formats may be added later.

### `Modified` detection

`Modified` is only shown when a file's **content** actually differs. Modification time (mtime) alone is not treated as a change, since it can change from a mere copy or git checkout.

- Different size → modified (decided without reading content).
- Same size and same mtime → assumed identical (fast path, content not read).
- Same size but different mtime → both sides are read and compared byte-for-byte; shown as modified only if the bytes differ. This read is asynchronous so it doesn't block the UI, and very large files (over 20MiB) are left as modified without being read.

`compare.ignore_newline` / `compare.ignore_encoding` relax the byte-exact comparison so that files differing only in line endings or a byte-order mark are treated as identical. Both default to `false` (plain byte-exact compare). When either is enabled, size-mismatched pairs that would otherwise be assumed modified are read and compared under the relaxed rules, and identical pairs are reported as Equal.

- `ignore_newline`: normalizes `CRLF` and lone `CR` to `LF` before comparing, so a file converted between DOS/Unix/classic-Mac line endings is not flagged as modified.
- `ignore_encoding`: strips a leading BOM (UTF-8, UTF-16LE, UTF-16BE) before comparing. This only removes the BOM; it does **not** transcode between encodings, so two files with genuinely different byte encodings still compare as modified.

Both options apply only to the content-comparison step. The 20 MiB size cap still applies: pairs larger than that are left as modified without being read.

## Sorting and grouping

The result view is always sorted ascending by relative path. On top of that, `sort` (and its runtime toggles `gs`/`ge`/`gd`) controls how entries are grouped. The buffer's third line (`Sort: ...`, right under `A:`/`B:`) always shows the current `separation` / `equal` / `diff_first` values and updates live as you toggle.

> **Note:** the default `separation` is `"diff_only"`, which shows status headers ("A only" / "B only" / "Diff") instead of a flat list. This is a visible behavior change even with no `setup()` call at all.

Every group header — at any nesting level — is a native fold covering that header and its entries, shown as `Label (N files) ▼` when open and `Label (N files) ▶` when closed; toggle it as usual with `zo`/`za`/`zc`. Only the Equal group starts closed, and only when `sort.equal == "hidden"`; every other group starts open. A blank line separates each top-level group.

### Equal-file visibility (`sort.equal` / `ge` / `:DirDiffEqual`)

Files that are identical on both sides ("Equal") are, by default, not shown at all.

- `"skip"` (default): Equal files never appear.
- `"show"`: Equal files appear, in their own group/section (starts open, like any other group).
- `"hidden"`: Equal files appear but their fold starts closed. Open with `zo`/`za` as usual.

### Diff-first ordering (`sort.diff_first` / `gd` / `:DirDiffDiffFirst`)

Controls whether the "Diff" (modified) group is listed before or after "A only"/"B only". The Equal group, when shown, is always listed last regardless of this setting.

### Separation modes (`sort.separation` / `gs` / `:DirDiffSeparation`)

- `"diff_only"` (default): status groups only, entries listed with their full relative path.
  ```
  A only (1 file) ▼
    added.txt

  B only (1 file) ▼
    deleted.txt

  Diff (1 file) ▼
    src/lib/modified.txt
  ```
- `"folder_diff"`: folder groups first (ascending), then status subgroups within each folder.
  ```
  (root) (1 file) ▼
    A only (1 file) ▼
      added.txt

  src/lib/ (1 file) ▼
    Diff (1 file) ▼
      modified.txt
  ```
- `"diff_folder"`: status groups first, then folder subgroups within each status.
  ```
  A only (1 file) ▼
    (root) (1 file) ▼
      added.txt

  Diff (1 file) ▼
    src/lib/ (1 file) ▼
      modified.txt
  ```
- `"folder_only"`: folder groups only, with statuses mixed inline (no per-status header). Equal entries, if shown, always form their own trailing block per folder so folding stays predictable.
  ```
  (root) (2 files) ▼
    + added.txt
    - deleted.txt

  src/lib/ (2 files) ▼
    ~ modified.txt
    Equal (1 file) ▼
      = same.txt
  ```

Folder grouping is flat by immediate parent directory (e.g. `src/lib/` is its own header, not nested under `src/`); root-level files group under `(root)`. The blank line between top-level groups above is the actual, literal separator rendered in the buffer.

## Development / Testing

```sh
make test
```

If [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) isn't found, it is automatically cloned into `.tests/` on first run.
