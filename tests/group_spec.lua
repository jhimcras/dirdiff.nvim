local group = require("dirdiff.group")

local function e(rel, status)
  return { rel = rel, status = status, abs_a = "/a/" .. rel, abs_b = "/b/" .. rel }
end

local function opts(overrides)
  return vim.tbl_extend("force", {
    separation = "diff_only",
    equal = "skip",
    diff_first = false,
  }, overrides or {})
end

local function headers(items)
  local out = {}
  for _, item in ipairs(items) do
    if item.kind == "header" then
      out[#out + 1] = item.text
    end
  end
  return out
end

describe("dirdiff.group diff_only", function()
  local entries = {
    e("added.txt", "added"),
    e("deleted.txt", "deleted"),
    e("modified.txt", "modified"),
    e("equal.txt", "equal"),
  }

  it("orders status groups added, deleted, modified and excludes equal on skip", function()
    local items, folds = group.build(entries, opts())
    assert.same({ "A only", "B only", "Diff" }, headers(items))
    assert.equals(3, #folds)
    for _, f in ipairs(folds) do
      assert.is_false(f.closed)
    end
    for _, item in ipairs(items) do
      if item.kind == "entry" then
        assert.is_not.equals("equal", item.entry.status)
      end
    end
  end)

  it("diff_first moves Diff before A only/B only, keeping their relative order", function()
    local items = group.build(entries, opts({ diff_first = true }))
    assert.same({ "Diff", "A only", "B only" }, headers(items))
  end)

  it("equal=show appends a trailing Equal header whose fold starts open", function()
    local items, folds = group.build(entries, opts({ equal = "show" }))
    assert.same({ "A only", "B only", "Diff", "Equal" }, headers(items))
    assert.equals(4, #folds)
    for _, f in ipairs(folds) do
      assert.is_false(f.closed)
    end
  end)

  it("equal=hidden appends Equal and returns a closed fold bounding header+entries", function()
    local items, folds = group.build(entries, opts({ equal = "hidden" }))
    assert.same({ "A only", "B only", "Diff", "Equal" }, headers(items))
    local closed = {}
    for _, f in ipairs(folds) do
      if f.closed then
        closed[#closed + 1] = f
      end
    end
    assert.equals(1, #closed)
    local range = closed[1]
    assert.equals("header", items[range.first].kind)
    assert.equals("Equal", items[range.first].text)
    for i = range.first + 1, range.last do
      assert.equals("entry", items[i].kind)
      assert.equals("equal", items[i].entry.status)
    end
  end)

  it("equal=skip with only equal entries yields no items (matches 'No differences')", function()
    local items = group.build({ e("a.txt", "equal"), e("b.txt", "equal") }, opts())
    assert.same({}, items)
  end)

  it("empty status groups produce no header", function()
    local items = group.build({ e("added.txt", "added") }, opts())
    assert.same({ "A only" }, headers(items))
  end)
end)

describe("dirdiff.group folder_diff", function()
  it("groups by folder (ascending) then by non-empty status subgroups", function()
    local entries = {
      e("folder1/a.txt", "added"),
      e("folder1/b.txt", "deleted"),
      e("folder2/c.txt", "modified"),
    }
    local items = group.build(entries, opts({ separation = "folder_diff" }))
    assert.same({ "folder1/", "A only", "B only", "folder2/", "Diff" }, headers(items))
  end)
end)

describe("dirdiff.group diff_folder", function()
  it("groups by status first, then by folder (ascending) within each status", function()
    local entries = {
      e("folder2/a.txt", "added"),
      e("folder1/b.txt", "added"),
      e("folder1/c.txt", "deleted"),
    }
    local items = group.build(entries, opts({ separation = "diff_folder" }))
    assert.same({ "A only", "folder1/", "folder2/", "B only", "folder1/" }, headers(items))
  end)
end)

describe("dirdiff.group folder_only", function()
  it("mixes non-equal statuses inline with no per-status header, ascending by rel", function()
    local entries = {
      e("folder1/b.txt", "deleted"),
      e("folder1/a.txt", "added"),
    }
    local items = group.build(entries, opts({ separation = "folder_only" }))
    assert.equals("header", items[1].kind)
    assert.equals("folder1/", items[1].text)
    assert.equals("folder1/a.txt", items[2].entry.rel)
    assert.equals("folder1/b.txt", items[3].entry.rel)
  end)

  it("puts Equal entries in their own trailing block per folder when not skipped", function()
    local entries = {
      e("folder1/a.txt", "added"),
      e("folder1/z.txt", "equal"),
    }
    local items, folds = group.build(entries, opts({ separation = "folder_only", equal = "hidden" }))
    assert.same({ "folder1/", "Equal" }, headers(items))
    assert.equals("folder1/a.txt", items[2].entry.rel)
    assert.equals("Equal", items[3].text)
    assert.equals("folder1/z.txt", items[4].entry.rel)
    assert.equals(2, #folds)
    local closed = {}
    for _, f in ipairs(folds) do
      if f.closed then
        closed[#closed + 1] = f
      end
    end
    assert.same({ { first = 3, last = 4, closed = true } }, closed)
  end)

  it("does not show Equal entries at all when equal=skip", function()
    local entries = { e("folder1/a.txt", "added"), e("folder1/z.txt", "equal") }
    local items = group.build(entries, opts({ separation = "folder_only", equal = "skip" }))
    assert.same({ "folder1/" }, headers(items))
    assert.equals(2, #items)
  end)
end)

describe("dirdiff.group root-level folder", function()
  it("groups root-level files under (root) and sorts it before subfolders", function()
    local entries = { e("sub/file.txt", "added"), e("root.txt", "added") }
    local items = group.build(entries, opts({ separation = "folder_diff" }))
    assert.same({ "(root)", "A only", "sub/", "A only" }, headers(items))
  end)
end)

describe("dirdiff.group cycle helpers", function()
  it("next_separation cycles through all four modes and wraps", function()
    assert.equals("diff_folder", group.next_separation("folder_diff"))
    assert.equals("diff_only", group.next_separation("diff_folder"))
    assert.equals("folder_only", group.next_separation("diff_only"))
    assert.equals("folder_diff", group.next_separation("folder_only"))
  end)

  it("next_equal cycles skip -> show -> hidden -> skip", function()
    assert.equals("show", group.next_equal("skip"))
    assert.equals("hidden", group.next_equal("show"))
    assert.equals("skip", group.next_equal("hidden"))
  end)
end)
