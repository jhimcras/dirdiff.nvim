if vim.g.loaded_dirdiff then
  return
end
vim.g.loaded_dirdiff = true

vim.api.nvim_create_user_command("DirDiff", function(opts)
  local args = require("dirdiff.path").parse_args(opts.args)
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

vim.api.nvim_create_user_command("DirDiffSeparation", function()
  require("dirdiff").toggle_separation()
end, { desc = "Cycle dirdiff grouping/separation mode" })

vim.api.nvim_create_user_command("DirDiffEqual", function()
  require("dirdiff").toggle_equal()
end, { desc = "Cycle dirdiff Equal-file visibility (skip/show/hidden)" })

vim.api.nvim_create_user_command("DirDiffDiffFirst", function()
  require("dirdiff").toggle_diff_first()
end, { desc = "Toggle whether the Diff (modified) group is listed first" })

vim.api.nvim_create_user_command("DirDiffGotoList", function()
  require("dirdiff").goto_list()
end, { desc = "Jump focus from a diff window back to the result list" })
