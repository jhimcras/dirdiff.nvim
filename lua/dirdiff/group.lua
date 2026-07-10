-- Pure re-grouping/sorting layer between resolved diff entries (added /
-- deleted / modified / equal) and the renderer. No vim.* API calls, so
-- toggling any option is an instant re-render over already-known entries,
-- never a re-scan.
--
-- M.build(entries, opts) -> items, folds
--   items: ordered list of
--     { kind = "header", text = <string>, level = 1|2, count = <int> }
--     { kind = "entry", entry = <diff entry> }
--     { kind = "blank" }
--   folds: list of { first, last, closed } -- 1-based indices into `items`
--     (not buffer line numbers), one per header (both levels), spanning the
--     header line itself through its last descendant. `closed` is true only
--     for the Equal group when opts.equal == "hidden"; every other fold
--     starts open.
--
-- opts = { separation = "folder_diff"|"diff_folder"|"diff_only"|"folder_only",
--          equal = "skip"|"show"|"hidden", diff_first = boolean }
local M = {}

M.SEPARATIONS = { "folder_diff", "diff_folder", "diff_only", "folder_only" }
M.EQUAL_MODES = { "skip", "show", "hidden" }

local STATUS_LABEL = { added = "A only", deleted = "B only", modified = "Diff", equal = "Equal" }
local ROOT_LABEL = "(root)"

-- Immediate parent directory of rel, or "" for root-level files. "" sorts
-- before any non-empty string, so root-level groups naturally come first.
local function dirname(rel)
  return rel:match("^(.*)/[^/]+$") or ""
end

local function folder_label(dir)
  return dir == "" and ROOT_LABEL or (dir .. "/")
end

local function rel_lt(x, y)
  return x.rel < y.rel
end

-- Status order: [added, deleted, modified], or [modified, added, deleted]
-- when diff_first; "equal" appended last iff equal ~= "skip". Any entry
-- whose status isn't in this list is implicitly excluded everywhere.
local function status_order(opts)
  local order = opts.diff_first and { "modified", "added", "deleted" }
    or { "added", "deleted", "modified" }
  if opts.equal ~= "skip" then
    order[#order + 1] = "equal"
  end
  return order
end

-- separation = "diff_only": status groups only, entries listed flat by rel.
local function build_diff_only(entries, opts)
  local order = status_order(opts)
  local by_status = {}
  for _, s in ipairs(order) do
    by_status[s] = {}
  end
  for _, e in ipairs(entries) do
    local bucket = by_status[e.status]
    if bucket then
      bucket[#bucket + 1] = e
    end
  end

  local items, folds = {}, {}
  local first_group = true
  for _, status in ipairs(order) do
    local list = by_status[status]
    if #list > 0 then
      table.sort(list, rel_lt)
      if not first_group then
        items[#items + 1] = { kind = "blank" }
      end
      first_group = false
      local header_idx = #items + 1
      items[header_idx] = { kind = "header", text = STATUS_LABEL[status], level = 1, count = #list }
      for _, e in ipairs(list) do
        items[#items + 1] = { kind = "entry", entry = e }
      end
      folds[#folds + 1] =
        { first = header_idx, last = #items, closed = status == "equal" and opts.equal == "hidden" }
    end
  end
  return items, folds
end

-- separation = "folder_diff": folder groups first (ascending), then status
-- sub-groups within each folder (only non-empty ones get a header).
local function build_folder_diff(entries, opts)
  local order = status_order(opts)
  local allowed = {}
  for _, s in ipairs(order) do
    allowed[s] = true
  end

  local folders, folder_keys = {}, {}
  for _, e in ipairs(entries) do
    if allowed[e.status] then
      local dir = dirname(e.rel)
      local bucket = folders[dir]
      if not bucket then
        bucket = {}
        folders[dir] = bucket
        folder_keys[#folder_keys + 1] = dir
      end
      local list = bucket[e.status]
      if not list then
        list = {}
        bucket[e.status] = list
      end
      list[#list + 1] = e
    end
  end
  table.sort(folder_keys)

  local items, folds = {}, {}
  local first_group = true
  for _, dir in ipairs(folder_keys) do
    if not first_group then
      items[#items + 1] = { kind = "blank" }
    end
    first_group = false

    local folder_header_idx = #items + 1
    items[folder_header_idx] = { kind = "header", text = folder_label(dir), level = 1, count = 0 }
    local bucket = folders[dir]
    local folder_count = 0
    for _, status in ipairs(order) do
      local list = bucket[status]
      if list and #list > 0 then
        table.sort(list, rel_lt)
        local sub_header_idx = #items + 1
        items[sub_header_idx] = { kind = "header", text = STATUS_LABEL[status], level = 2, count = #list }
        for _, e in ipairs(list) do
          items[#items + 1] = { kind = "entry", entry = e }
        end
        folds[#folds + 1] = {
          first = sub_header_idx,
          last = #items,
          closed = status == "equal" and opts.equal == "hidden",
        }
        folder_count = folder_count + #list
      end
    end
    items[folder_header_idx].count = folder_count
    folds[#folds + 1] = { first = folder_header_idx, last = #items, closed = false }
  end
  return items, folds
end

-- separation = "diff_folder": status groups first, then folder sub-groups
-- (ascending) within each status.
local function build_diff_folder(entries, opts)
  local order = status_order(opts)
  local by_status = {}
  for _, s in ipairs(order) do
    by_status[s] = {}
  end
  for _, e in ipairs(entries) do
    local bucket = by_status[e.status]
    if bucket then
      bucket[#bucket + 1] = e
    end
  end

  local items, folds = {}, {}
  local first_group = true
  for _, status in ipairs(order) do
    local list = by_status[status]
    if #list > 0 then
      if not first_group then
        items[#items + 1] = { kind = "blank" }
      end
      first_group = false

      local status_header_idx = #items + 1
      items[status_header_idx] = { kind = "header", text = STATUS_LABEL[status], level = 1, count = #list }

      local folders, folder_keys = {}, {}
      for _, e in ipairs(list) do
        local dir = dirname(e.rel)
        local fl = folders[dir]
        if not fl then
          fl = {}
          folders[dir] = fl
          folder_keys[#folder_keys + 1] = dir
        end
        fl[#fl + 1] = e
      end
      table.sort(folder_keys)

      for _, dir in ipairs(folder_keys) do
        local fl = folders[dir]
        table.sort(fl, rel_lt)
        local sub_header_idx = #items + 1
        items[sub_header_idx] = { kind = "header", text = folder_label(dir), level = 2, count = #fl }
        for _, e in ipairs(fl) do
          items[#items + 1] = { kind = "entry", entry = e }
        end
        folds[#folds + 1] = {
          first = sub_header_idx,
          last = #items,
          closed = status == "equal" and opts.equal == "hidden",
        }
      end

      folds[#folds + 1] = { first = status_header_idx, last = #items, closed = false }
    end
  end
  return items, folds
end

-- separation = "folder_only": folder groups only (ascending). Non-equal
-- statuses are mixed inline (no sub-header, symbols alone distinguish them).
-- Equal entries always form their own trailing contiguous block per folder,
-- so "Equal always last" and fold ranges stay consistent with the other
-- three modes even though this mode has no other sub-headers.
local function build_folder_only(entries, opts)
  local folders, folder_keys = {}, {}
  for _, e in ipairs(entries) do
    if e.status ~= "equal" or opts.equal ~= "skip" then
      local dir = dirname(e.rel)
      local bucket = folders[dir]
      if not bucket then
        bucket = { main = {}, equal = {} }
        folders[dir] = bucket
        folder_keys[#folder_keys + 1] = dir
      end
      if e.status == "equal" then
        bucket.equal[#bucket.equal + 1] = e
      else
        bucket.main[#bucket.main + 1] = e
      end
    end
  end
  table.sort(folder_keys)

  local items, folds = {}, {}
  local first_group = true
  for _, dir in ipairs(folder_keys) do
    if not first_group then
      items[#items + 1] = { kind = "blank" }
    end
    first_group = false

    local bucket = folders[dir]
    local folder_header_idx = #items + 1
    items[folder_header_idx] =
      { kind = "header", text = folder_label(dir), level = 1, count = #bucket.main + #bucket.equal }

    if #bucket.main > 0 then
      table.sort(bucket.main, rel_lt)
      for _, e in ipairs(bucket.main) do
        items[#items + 1] = { kind = "entry", entry = e }
      end
    end

    if opts.equal ~= "skip" and #bucket.equal > 0 then
      table.sort(bucket.equal, rel_lt)
      local equal_header_idx = #items + 1
      items[equal_header_idx] = { kind = "header", text = STATUS_LABEL.equal, level = 2, count = #bucket.equal }
      for _, e in ipairs(bucket.equal) do
        items[#items + 1] = { kind = "entry", entry = e }
      end
      folds[#folds + 1] = { first = equal_header_idx, last = #items, closed = opts.equal == "hidden" }
    end

    folds[#folds + 1] = { first = folder_header_idx, last = #items, closed = false }
  end
  return items, folds
end

local BUILDERS = {
  folder_diff = build_folder_diff,
  diff_folder = build_diff_folder,
  diff_only = build_diff_only,
  folder_only = build_folder_only,
}

function M.build(entries, opts)
  local builder = BUILDERS[opts.separation] or build_diff_only
  return builder(entries, opts)
end

local function cycle(list, current)
  for i, v in ipairs(list) do
    if v == current then
      return list[(i % #list) + 1]
    end
  end
  return list[1]
end

function M.next_separation(current)
  return cycle(M.SEPARATIONS, current)
end

function M.next_equal(current)
  return cycle(M.EQUAL_MODES, current)
end

return M
