-- Public API and orchestration for dirdiff.nvim.
local config = require("dirdiff.config")
local path = require("dirdiff.path")
local scan = require("dirdiff.scan")
local diff = require("dirdiff.diff")
local content = require("dirdiff.content")
local ui = require("dirdiff.ui")

local M = {}

-- Soft lock: reject overlapping comparison/refresh requests (spec 2.2).
local is_comparing = false
-- Remembers the last comparison so refresh can rescan the same roots.
local last = nil

function M.setup(opts)
  config.setup(opts)
  ui.setup_highlights(config.options.highlights)
end

local function compare(root_a, root_b)
  if is_comparing then
    vim.notify("dirdiff: a scan is already in progress", vim.log.levels.INFO)
    return
  end
  if vim.fn.isdirectory(root_a) == 0 then
    vim.notify("dirdiff: not a directory: " .. root_a, vim.log.levels.ERROR)
    return
  end
  if vim.fn.isdirectory(root_b) == 0 then
    vim.notify("dirdiff: not a directory: " .. root_b, vim.log.levels.ERROR)
    return
  end

  -- Highlight groups are idempotent + default=true, so this is safe to call
  -- even when the user never invoked setup().
  ui.setup_highlights(config.options.highlights)

  is_comparing = true
  last = { root_a = root_a, root_b = root_b }

  local snap_a, snap_b
  local function try_render()
    if snap_a and snap_b then
      -- Confirm same-size/different-mtime candidates by content before
      -- rendering; is_comparing is released once verification completes.
      content.resolve(diff.compute(snap_a, snap_b), config.options.compare, function(entries)
        is_comparing = false
        ui.render({
          root_a = root_a,
          root_b = root_b,
          entries = entries,
          on_refresh = M.refresh,
        })
      end)
    end
  end

  scan.scan(root_a, config.options, function(s)
    snap_a = s
    try_render()
  end)
  scan.scan(root_b, config.options, function(s)
    snap_b = s
    try_render()
  end)
end

-- dir2 defaults to the current working directory (spec 3.3).
function M.open(dir1, dir2)
  local root_a = path.absolute(dir1)
  local root_b = dir2 and path.absolute(dir2) or path.absolute(vim.fn.getcwd())
  compare(root_a, root_b)
end

function M.refresh()
  if not last then
    return
  end
  compare(last.root_a, last.root_b)
end

return M
