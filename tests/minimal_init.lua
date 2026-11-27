-- Minimal init for running the test suite headless.
-- Bootstraps plenary.nvim into .tests/ if it is not already available.
local cwd = vim.fn.getcwd()
local plenary_dir = cwd .. "/.tests/plenary.nvim"

if vim.fn.isdirectory(plenary_dir) == 0 then
  vim.fn.system({
    "git",
    "clone",
    "--depth=1",
    "https://github.com/nvim-lua/plenary.nvim",
    plenary_dir,
  })
end

-- Tests open real files with :split/:vsplit. Swap files would otherwise go to
-- the user's $XDG_STATE_HOME/nvim/swap, and E303 aborts the split whenever that
-- directory is not writable (sandboxed runs), failing ui_spec.
vim.opt.swapfile = false

vim.opt.runtimepath:append(cwd)
vim.opt.runtimepath:append(plenary_dir)

vim.cmd("runtime plugin/plenary.vim")
require("plenary.busted")
