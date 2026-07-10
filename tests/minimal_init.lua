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

vim.opt.runtimepath:append(cwd)
vim.opt.runtimepath:append(plenary_dir)

vim.cmd("runtime plugin/plenary.vim")
require("plenary.busted")
