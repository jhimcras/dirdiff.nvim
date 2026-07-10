-- Pure comparison of two snapshots into a sorted list of diff entries.
--
-- A snapshot is a table keyed by comparison key:
--   snapshot[key] = { rel = <display path>, abs = <absolute path>,
--                     size = <bytes>, mtime = <seconds> }
--
-- An entry is:
--   { rel = <display path>, status = "added"|"deleted"|"modified"|"equal",
--     abs_a = <path or nil>, abs_b = <path or nil> }
--
-- Semantics (spec 3.1): A is the "new" side, B the "base" side.
--   only in A -> added, only in B -> deleted.
-- For a file present on both sides:
--   size differs                 -> modified (content unread, certain)
--   size equal, mtime equal      -> status=equal, assumed identical without
--                                   reading content (fast path; mtime is only
--                                   trusted to say "same", never "modified",
--                                   so this fast path is never re-verified)
--   size equal, mtime differs    -> modified with verify=true, meaning the
--                                   content module must confirm by reading both
--                                   files; identical content retags the entry
--                                   as status=equal instead of dropping it.
local M = {}

function M.compute(snap_a, snap_b)
  local entries = {}

  for key, a in pairs(snap_a) do
    local b = snap_b[key]
    if b == nil then
      entries[#entries + 1] =
        { rel = a.rel, status = "added", abs_a = a.abs }
    elseif a.size ~= b.size then
      entries[#entries + 1] =
        { rel = a.rel, status = "modified", abs_a = a.abs, abs_b = b.abs }
    elseif a.mtime ~= b.mtime then
      entries[#entries + 1] = {
        rel = a.rel,
        status = "modified",
        abs_a = a.abs,
        abs_b = b.abs,
        verify = true,
      }
    else
      entries[#entries + 1] =
        { rel = a.rel, status = "equal", abs_a = a.abs, abs_b = b.abs }
    end
  end

  for key, b in pairs(snap_b) do
    if snap_a[key] == nil then
      entries[#entries + 1] =
        { rel = b.rel, status = "deleted", abs_b = b.abs }
    end
  end

  table.sort(entries, function(x, y)
    return x.rel < y.rel
  end)

  return entries
end

return M
