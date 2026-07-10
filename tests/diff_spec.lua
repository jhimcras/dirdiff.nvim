local diff = require("dirdiff.diff")

local function entry(rel, size, mtime, abs)
  return { rel = rel, abs = abs or ("/a/" .. rel), size = size, mtime = mtime }
end

describe("dirdiff.diff", function()
  it("detects added / deleted / modified and skips identical", function()
    local a = {
      ["same.txt"] = entry("same.txt", 10, 100),
      ["only_a.txt"] = entry("only_a.txt", 5, 100),
      ["diff_size.txt"] = entry("diff_size.txt", 20, 100),
      ["diff_mtime.txt"] = entry("diff_mtime.txt", 10, 200),
    }
    local b = {
      ["same.txt"] = entry("same.txt", 10, 100),
      ["only_b.txt"] = entry("only_b.txt", 5, 100),
      ["diff_size.txt"] = entry("diff_size.txt", 15, 100),
      ["diff_mtime.txt"] = entry("diff_mtime.txt", 10, 100),
    }

    local result = diff.compute(a, b)
    local by_rel = {}
    for _, e in ipairs(result) do
      by_rel[e.rel] = e
    end

    -- Identical size and mtime: assumed identical, no entry.
    assert.is_nil(by_rel["same.txt"])
    assert.equals("added", by_rel["only_a.txt"].status)
    assert.equals("deleted", by_rel["only_b.txt"].status)
    -- Different size: modified for certain, no content check needed.
    assert.equals("modified", by_rel["diff_size.txt"].status)
    assert.is_nil(by_rel["diff_size.txt"].verify)
    -- Same size, different mtime: modified only if content confirms it.
    assert.equals("modified", by_rel["diff_mtime.txt"].status)
    assert.is_true(by_rel["diff_mtime.txt"].verify)
    assert.equals(4, #result)
  end)

  it("returns entries sorted by rel path", function()
    local a = { ["z.txt"] = entry("z.txt", 1, 1), ["a.txt"] = entry("a.txt", 1, 1) }
    local result = diff.compute(a, {})
    assert.equals("a.txt", result[1].rel)
    assert.equals("z.txt", result[2].rel)
  end)

  it("populates abs_a/abs_b per status", function()
    local a = {
      ["m.txt"] = { rel = "m.txt", abs = "/a/m.txt", size = 1, mtime = 1 },
      ["add.txt"] = { rel = "add.txt", abs = "/a/add.txt", size = 1, mtime = 1 },
    }
    local b = {
      ["m.txt"] = { rel = "m.txt", abs = "/b/m.txt", size = 2, mtime = 1 },
      ["del.txt"] = { rel = "del.txt", abs = "/b/del.txt", size = 1, mtime = 1 },
    }
    local result = diff.compute(a, b)
    local by_rel = {}
    for _, e in ipairs(result) do
      by_rel[e.rel] = e
    end

    assert.equals("/a/add.txt", by_rel["add.txt"].abs_a)
    assert.is_nil(by_rel["add.txt"].abs_b)
    assert.equals("/b/del.txt", by_rel["del.txt"].abs_b)
    assert.is_nil(by_rel["del.txt"].abs_a)
    assert.equals("/a/m.txt", by_rel["m.txt"].abs_a)
    assert.equals("/b/m.txt", by_rel["m.txt"].abs_b)
  end)
end)
