local content = require("dirdiff.content")

local function tmpfile(text)
  local p = vim.fn.tempname()
  local fd = assert(io.open(p, "w"))
  fd:write(text)
  fd:close()
  return p
end

local function resolve(entries)
  local out
  content.resolve(entries, {}, function(r)
    out = r
  end)
  vim.wait(2000, function()
    return out ~= nil
  end, 20)
  return out
end

describe("dirdiff.content", function()
  it("drops a verify candidate whose contents are identical", function()
    local a = tmpfile("hello world")
    local b = tmpfile("hello world")
    local out = resolve({
      { rel = "x.txt", status = "modified", abs_a = a, abs_b = b, verify = true },
    })
    assert.equals(0, #out)
  end)

  it("keeps a verify candidate whose contents differ and strips verify", function()
    -- Same byte length, so this is the same-size / different-mtime case.
    local a = tmpfile("hello")
    local b = tmpfile("world")
    local out = resolve({
      { rel = "x.txt", status = "modified", abs_a = a, abs_b = b, verify = true },
    })
    assert.equals(1, #out)
    assert.equals("modified", out[1].status)
    assert.is_nil(out[1].verify)
  end)

  it("passes non-verify entries through untouched and in order", function()
    local out = resolve({
      { rel = "add.txt", status = "added", abs_a = "/x/add.txt" },
      { rel = "del.txt", status = "deleted", abs_b = "/y/del.txt" },
    })
    assert.equals(2, #out)
    assert.equals("add.txt", out[1].rel)
    assert.equals("del.txt", out[2].rel)
  end)

  it("keeps a candidate as modified when a side cannot be read", function()
    local out = resolve({
      {
        rel = "x.txt",
        status = "modified",
        abs_a = "/no/such/a",
        abs_b = "/no/such/b",
        verify = true,
      },
    })
    assert.equals(1, #out)
    assert.equals("modified", out[1].status)
  end)

  it("resolves a mix, preserving surviving order", function()
    local same_a = tmpfile("dup")
    local same_b = tmpfile("dup")
    local diff_a = tmpfile("aaa")
    local diff_b = tmpfile("bbb")
    local out = resolve({
      { rel = "a.txt", status = "added", abs_a = "/x/a.txt" },
      { rel = "b.txt", status = "modified", abs_a = same_a, abs_b = same_b, verify = true },
      { rel = "c.txt", status = "modified", abs_a = diff_a, abs_b = diff_b, verify = true },
    })
    -- b.txt (identical) is dropped; a.txt and c.txt survive in order.
    assert.equals(2, #out)
    assert.equals("a.txt", out[1].rel)
    assert.equals("c.txt", out[2].rel)
  end)
end)
