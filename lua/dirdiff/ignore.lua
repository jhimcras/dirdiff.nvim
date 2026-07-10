-- Parsing and matching of per-folder "ignore list" files (currently
-- .gitignore). Everything here is pure Lua so it can run inside the vim.uv scan
-- callback (a fast event context), where vim.regex / vim.fn are unsafe.
--
-- Extension point: to support another format (e.g. .npmignore with different
-- semantics) register a filename in FILE_KINDS and a parser in parsers. A parser
-- takes the file text and returns a list of compiled rules understood by matches.
local M = {}

-- Filename -> parser kind. Names listed in the `ignore_files` option are looked
-- up here; unknown names fall back to gitignore semantics.
M.FILE_KINDS = { [".gitignore"] = "gitignore" }

-- Lua pattern magic characters that must be escaped to match literally.
local MAGIC = "^$()%.[]*+-?"

-- Translate a single gitignore path segment (no "/") into an anchored Lua
-- pattern matching one path component. Within a segment `*` matches any run of
-- non-separators, `?` a single non-separator, and `[...]` is a character class
-- (leading `!` negation becomes `^`).
local function segment_to_lua(seg)
  local out = { "^" }
  local i, n = 1, #seg
  while i <= n do
    local c = seg:sub(i, i)
    if c == "*" then
      out[#out + 1] = "[^/]*"
      i = i + 1
    elseif c == "?" then
      out[#out + 1] = "[^/]"
      i = i + 1
    elseif c == "[" then
      local j = i + 1
      local cls = "["
      if seg:sub(j, j) == "!" or seg:sub(j, j) == "^" then
        cls = "[^"
        j = j + 1
      end
      if seg:sub(j, j) == "]" then -- literal ] as first class member
        cls = cls .. "%]"
        j = j + 1
      end
      while j <= n and seg:sub(j, j) ~= "]" do
        local cc = seg:sub(j, j)
        cls = cls .. (cc == "%" and "%%" or cc)
        j = j + 1
      end
      if j > n then -- unterminated: treat '[' as literal
        out[#out + 1] = "%["
        i = i + 1
      else
        out[#out + 1] = cls .. "]"
        i = j + 1
      end
    else
      out[#out + 1] = MAGIC:find(c, 1, true) and ("%" .. c) or c
      i = i + 1
    end
  end
  out[#out + 1] = "$"
  return table.concat(out)
end

-- Compile one gitignore line into a rule, or nil for blank/comment lines.
-- A rule is { negate, dir_only, segs } where segs is a list whose members are
-- either the literal "**" (matches zero or more path components) or a Lua
-- pattern matching a single component. Segments are relative to the directory
-- of the ignore file (the enclosing frame's base).
local function compile_line(line)
  line = line:gsub("\r$", "")
  if line == "" or line:sub(1, 1) == "#" then
    return nil
  end
  if line:sub(1, 2) == "\\#" then
    line = line:sub(2)
  end
  line = line:gsub("%s+$", "")
  if line == "" then
    return nil
  end

  local negate = false
  if line:sub(1, 1) == "!" then
    negate = true
    line = line:sub(2)
  elseif line:sub(1, 2) == "\\!" then
    line = line:sub(2)
  end

  local dir_only = false
  if line:sub(-1) == "/" then
    dir_only = true
    line = line:sub(1, -2)
  end
  if line == "" then
    return nil
  end

  -- A slash anywhere (leading or middle) anchors the pattern to the base
  -- directory. Otherwise it matches a basename at any depth, which is the same
  -- as prefixing a "**" component.
  local anchored = line:find("/") ~= nil
  if line:sub(1, 1) == "/" then
    line = line:sub(2)
  end

  local segs = {}
  if not anchored then
    segs[#segs + 1] = "**"
  end
  for _, raw in ipairs(vim.split(line, "/", { plain = true })) do
    segs[#segs + 1] = raw == "**" and "**" or segment_to_lua(raw)
  end

  return { negate = negate, dir_only = dir_only, segs = segs }
end

local function parse_gitignore(text)
  local rules = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    local rule = compile_line(line)
    if rule then
      rules[#rules + 1] = rule
    end
  end
  return rules
end

M.parsers = { gitignore = parse_gitignore }

-- Match path components `parts` (from index j) against compiled segments `segs`
-- (from index i). "**" consumes zero or more components.
local function seg_match(segs, i, parts, j)
  if i > #segs then
    return j > #parts
  end
  local s = segs[i]
  if s == "**" then
    for k = j, #parts + 1 do
      if seg_match(segs, i + 1, parts, k) then
        return true
      end
    end
    return false
  end
  if j > #parts then
    return false
  end
  if parts[j]:match(s) then
    return seg_match(segs, i + 1, parts, j + 1)
  end
  return false
end

-- Build a frame for one ignore file. `name` selects the parser, `text` is the
-- file contents, `base_rel` is the file's directory relative to the scan root
-- ("" at the root). Returns nil when the file yields no usable rules.
function M.compile(name, text, base_rel)
  local kind = M.FILE_KINDS[name] or "gitignore"
  local parser = M.parsers[kind]
  if not parser then
    return nil
  end
  local rules = parser(text)
  if #rules == 0 then
    return nil
  end
  return { base = base_rel, rules = rules }
end

-- Decide whether `rel` (path relative to the scan root) is ignored given the
-- accumulated `stack` of ancestor frames, shallowest first. Later matches win,
-- so deeper files and later lines take precedence, and a negated rule (`!`)
-- re-includes.
function M.matches(stack, rel, is_dir)
  local ignored = false
  for _, frame in ipairs(stack) do
    local sub = frame.base == "" and rel or rel:sub(#frame.base + 2)
    local parts = vim.split(sub, "/", { plain = true })
    for _, rule in ipairs(frame.rules) do
      if (not rule.dir_only or is_dir) and seg_match(rule.segs, 1, parts, 1) then
        ignored = not rule.negate
      end
    end
  end
  return ignored
end

return M
