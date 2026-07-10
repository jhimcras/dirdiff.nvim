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
  "your-name/dirdiff.nvim",
  cmd = "DirDiff",
  opts = {},
}
```

### [pckr.nvim](https://github.com/lewis6991/pckr.nvim)

```lua
{
  "your-name/dirdiff.nvim",
  config = function()
    require("dirdiff").setup()
  end,
}
```

## Usage

```vim
:DirDiff <dir1> [<dir2>]
```

- Both relative and absolute paths are supported. If `<dir2>` is omitted, it compares `<dir1>` against the current working directory (`:pwd`).
- Directory completion (`-complete=dir`) is supported. Folder names containing spaces are automatically escaped during completion.
- Comparison is case-insensitive on Windows and case-sensitive on Linux/macOS.

### Result view keymaps

Buffer-local mappings that only apply inside the result buffer:

| Key           | Action                                                                          |
| ------------- | -------------------------------------------------------------------------------- |
| `<CR>`        | Open the diff. Opens vimdiff if the file exists on both sides, otherwise opens the single existing file. |
| `R` / `<F5>`  | Re-scan both directories and refresh the result                                  |
| `q`           | Close the result view and clean up resources                                     |

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
  -- How "modified" is determined. The two options below are reserved for
  -- future support; only byte-exact comparison is implemented for now.
  compare = {
    ignore_newline = false,  -- (planned) treat newline-only differences (CRLF/LF) as identical
    ignore_encoding = false, -- (planned) treat encoding-only differences (BOM, etc.) as identical
  },
  -- Highlight groups per status (linked to the colorscheme's diff colors).
  highlights = {
    added = "DiffAdd",
    deleted = "DiffDelete",
    modified = "DiffChange",
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

`compare.ignore_newline` / `compare.ignore_encoding` are reserved options for treating newline-only or encoding-only differences as identical. Both default to `false`, and only byte-exact comparison is implemented for now (support planned).

## Development / Testing

```sh
make test
```

If [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) isn't found, it is automatically cloned into `.tests/` on first run.
