local scan = require("dirdiff.scan")

local function tmproot()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

local function write_file(p, content)
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  local fd = assert(io.open(p, "w"))
  fd:write(content or "")
  fd:close()
end

local function run_scan(root, opts)
  local result
  scan.scan(root, opts or {}, function(snap)
    result = snap
  end)
  vim.wait(2000, function()
    return result ~= nil
  end, 20)
  return result
end

describe("dirdiff.scan", function()
  it("records files recursively with relative keys and metadata", function()
    local root = tmproot()
    write_file(root .. "/top.txt", "hello")
    write_file(root .. "/sub/nested.txt", "hi")

    local snap = run_scan(root)
    assert.is_not_nil(snap)

    assert.is_not_nil(snap["top.txt"])
    assert.is_not_nil(snap["sub/nested.txt"])
    assert.equals("sub/nested.txt", snap["sub/nested.txt"].rel)
    assert.equals(5, snap["top.txt"].size)
    assert.is_number(snap["top.txt"].mtime)
    assert.equals(root .. "/top.txt", snap["top.txt"].abs)
  end)

  it("honors exclude glob patterns", function()
    local root = tmproot()
    write_file(root .. "/keep.txt", "x")
    write_file(root .. "/.git/config", "x")
    write_file(root .. "/build.tmp", "x")

    local snap = run_scan(root, { exclude = { ".git", "*.tmp" } })

    assert.is_not_nil(snap["keep.txt"])
    assert.is_nil(snap[".git/config"])
    assert.is_nil(snap["build.tmp"])
  end)

  it("applies ignore files recursively, keeping the ignore file itself", function()
    local root = tmproot()
    write_file(root .. "/.gitignore", "*.log\nbuild/\n")
    write_file(root .. "/keep.txt", "x")
    write_file(root .. "/app.log", "x")
    write_file(root .. "/build/out.o", "x")
    -- Nested ignore file applies to its own subtree only.
    write_file(root .. "/sub/.gitignore", "secret.txt\n")
    write_file(root .. "/sub/secret.txt", "x")
    write_file(root .. "/sub/nested.log", "x")
    write_file(root .. "/sub/ok.txt", "x")

    local snap = run_scan(root, { ignore_files = { ".gitignore" } })

    assert.is_not_nil(snap["keep.txt"])
    assert.is_not_nil(snap["sub/ok.txt"])
    -- Ignore files themselves are recorded (not in exclude).
    assert.is_not_nil(snap[".gitignore"])
    assert.is_not_nil(snap["sub/.gitignore"])

    assert.is_nil(snap["app.log"])
    assert.is_nil(snap["build/out.o"])
    -- Root rule reaches subfolders; nested rule is scoped to sub/.
    assert.is_nil(snap["sub/nested.log"])
    assert.is_nil(snap["sub/secret.txt"])
  end)

  it("returns an empty snapshot for an empty directory", function()
    local root = tmproot()
    local snap = run_scan(root)
    assert.same({}, snap)
  end)
end)
