local path = require("dirdiff.path")

describe("dirdiff.path", function()
  it("normalizes backslashes and collapses segments", function()
    assert.equals("/foo/bar", path.normalize("/foo/bar"))
    assert.equals("/foo/bar", path.normalize("/foo/./bar"))
    assert.equals("/foo", path.normalize("/foo/baz/.."))
  end)

  it("produces absolute paths", function()
    local abs = path.absolute(".")
    assert.equals(1, vim.startswith(abs, "/") and 1 or 0)
    assert.equals(vim.fn.getcwd(), abs)
  end)

  it("joins segments with a forward slash", function()
    assert.equals("a/b/c", path.join("a/b", "c"))
  end)

  it("compare_key respects platform case sensitivity", function()
    local key = path.compare_key("Foo/Bar.txt")
    if path.is_windows() then
      assert.equals("foo/bar.txt", key)
    else
      assert.equals("Foo/Bar.txt", key)
    end
  end)
end)
