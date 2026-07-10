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

  it("parse_args splits unquoted args on whitespace", function()
    assert.same({ "a", "b" }, path.parse_args("a b"))
    assert.same({ "a", "b" }, path.parse_args("  a   b  "))
  end)

  it("parse_args strips quotes and preserves backslashes inside them", function()
    assert.same(
      { [[d:\Source\hi6_control_sw]], [[d:\Source\remote]] },
      path.parse_args([["d:\Source\hi6_control_sw" "d:\Source\remote"]])
    )
  end)

  it("parse_args keeps spaces inside quoted args as one field", function()
    assert.same({ "C:\\Program Files\\a", "b" }, path.parse_args([["C:\Program Files\a" b]]))
  end)

  it("parse_args supports single quotes too", function()
    assert.same({ "a b", "c" }, path.parse_args("'a b' c"))
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
