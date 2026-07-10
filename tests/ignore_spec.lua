local ignore = require("dirdiff.ignore")

-- Build a single-frame stack rooted at the scan root from gitignore text.
local function frame(text, base)
  local f = ignore.compile(".gitignore", text, base or "")
  return f and { f } or {}
end

local function ignored(text, rel, is_dir)
  return ignore.matches(frame(text), rel, is_dir or false)
end

describe("dirdiff.ignore", function()
  it("skips comments and blank lines", function()
    assert.is_nil(ignore.compile(".gitignore", "# comment\n\n   \n", ""))
  end)

  it("matches a basename at any depth", function()
    assert.is_true(ignored("node_modules\n", "node_modules", true))
    assert.is_true(ignored("node_modules\n", "a/b/node_modules", true))
    assert.is_false(ignored("node_modules\n", "a/node_modules_x", false))
  end)

  it("anchors patterns that contain a slash", function()
    assert.is_true(ignored("/build\n", "build", true))
    assert.is_false(ignored("/build\n", "sub/build", true))
    assert.is_true(ignored("a/b\n", "a/b", false))
    assert.is_false(ignored("a/b\n", "x/a/b", false))
  end)

  it("honors directory-only patterns", function()
    assert.is_true(ignored("dist/\n", "dist", true))
    assert.is_false(ignored("dist/\n", "dist", false))
    assert.is_true(ignored("dist/\n", "pkg/dist", true))
  end)

  it("supports wildcards", function()
    assert.is_true(ignored("*.log\n", "app.log", false))
    assert.is_true(ignored("*.log\n", "logs/app.log", false))
    assert.is_false(ignored("*.log\n", "app.txt", false))
    assert.is_true(ignored("**/tmp\n", "a/b/tmp", true))
    assert.is_true(ignored("**/tmp\n", "tmp", true))
  end)

  it("re-includes with negation, last match wins", function()
    local text = "*.log\n!keep.log\n"
    assert.is_true(ignored(text, "app.log", false))
    assert.is_false(ignored(text, "keep.log", false))
  end)

  it("lets a deeper file override a shallower one", function()
    local shallow = ignore.compile(".gitignore", "*.log\n", "")
    local deep = ignore.compile(".gitignore", "!debug.log\n", "sub")
    local stack = { shallow, deep }
    assert.is_true(ignore.matches(stack, "sub/app.log", false))
    assert.is_false(ignore.matches(stack, "sub/debug.log", false))
  end)
end)
