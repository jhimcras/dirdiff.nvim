if vim.g.loaded_dirdiff then
  return
end
vim.g.loaded_dirdiff = true

vim.api.nvim_create_user_command("DirDiff", function(opts)
  local args = opts.fargs
  if #args < 1 then
    vim.notify("dirdiff: usage :DirDiff <dir1> [<dir2>]", vim.log.levels.ERROR)
    return
  end
  require("dirdiff").open(args[1], args[2])
end, {
  nargs = "+",
  complete = "dir",
  desc = "List file differences between two directories",
})
