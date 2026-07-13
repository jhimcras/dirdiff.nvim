local dirdiff = require("dirdiff")
local config = require("dirdiff.config")

-- Creates two temp dirs with one "modified" pair per entry in `pairs_spec`
-- ({ rel, content_a, content_b }). Different byte lengths so the entries are
-- unambiguously "modified" -- same-size files short-circuit to "equal"
-- without content comparison and get hidden by the default sort.equal="skip".
local function make_roots(pairs_spec)
  local base = vim.fn.tempname()
  vim.fn.mkdir(base .. "/a", "p")
  vim.fn.mkdir(base .. "/b", "p")
  for _, p in ipairs(pairs_spec) do
    vim.fn.writefile({ p.content_a }, base .. "/a/" .. p.rel)
    vim.fn.writefile({ p.content_b }, base .. "/b/" .. p.rel)
  end
  return base .. "/a", base .. "/b"
end

local function open_dirdiff(pairs_spec)
  config.setup({})
  local root_a, root_b = make_roots(pairs_spec)
  dirdiff.open(root_a, root_b)
  vim.wait(500, function()
    return vim.bo.filetype == "dirdiff"
  end, 10)
  return vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
end

-- Finds the buffer line for a "~ <rel>" (modified) entry.
local function modified_lnum(buf, rel)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line == "~ " .. rel then
      return i
    end
  end
  error("no modified entry line for " .. rel)
end

local function press_enter_on(list_win, list_buf, rel)
  vim.api.nvim_set_current_win(list_win)
  vim.api.nvim_win_set_cursor(list_win, { modified_lnum(list_buf, rel), 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  vim.wait(200)
end

local function press_close(list_win)
  vim.api.nvim_set_current_win(list_win)
  vim.api.nvim_feedkeys("q", "x", false)
  vim.wait(200)
end

-- Every diff/other window in tabpage besides list_win.
local function other_wins(tabpage, list_win)
  local out = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if w ~= list_win then
      out[#out + 1] = w
    end
  end
  return out
end

describe("dirdiff.ui diff split sizing", function()
  after_each(function()
    vim.cmd("tabfirst")
    pcall(vim.cmd, "tabonly!")
  end)

  it("sizes list/A/B from list_win's real available width, not vim.o.columns (wide layout)", function()
    vim.o.columns = 160
    vim.o.lines = 40
    local list_win, list_buf = open_dirdiff({
      { rel = "one.txt", content_a = "hello a, a longer line for a", content_b = "hello b" },
    })

    -- Squeeze list_win's real space with a sibling window opened on a real
    -- (unrelated) file -- plain `:vsplit` with no arg would just duplicate
    -- the current buffer instead of being a genuinely separate window.
    local unrelated_file = vim.fn.tempname()
    vim.fn.writefile({ "unrelated" }, unrelated_file)
    vim.cmd("vsplit " .. vim.fn.fnameescape(unrelated_file))
    vim.api.nvim_set_current_win(list_win)

    local avail_w = vim.api.nvim_win_get_width(list_win)
    press_enter_on(list_win, list_buf, "one.txt")

    local cfg = config.options.layout.wide
    local expected = math.floor(avail_w * cfg.list / (cfg.list + cfg.a + cfg.b))
    local buggy = math.floor(vim.o.columns * cfg.list / (cfg.list + cfg.a + cfg.b))
    local actual = vim.api.nvim_win_get_width(list_win)

    assert.is_true(
      math.abs(actual - expected) <= 1,
      string.format("list width %d should match real-space proportion %d (not full-editor-width %d)", actual, expected, buggy)
    )
  end)

  it("gives list_win the configured fixed height and splits A/B by ratio (tall layout)", function()
    vim.o.columns = 80
    vim.o.lines = 100
    local list_win, list_buf = open_dirdiff({
      { rel = "one.txt", content_a = "hello a, a longer line for a", content_b = "hello b" },
    })

    press_enter_on(list_win, list_buf, "one.txt")

    local cfg = config.options.layout.tall
    assert.equals(cfg.list_height, vim.api.nvim_win_get_height(list_win))

    local diff_wins = other_wins(vim.api.nvim_win_get_tabpage(list_win), list_win)
    assert.equals(2, #diff_wins)
    table.sort(diff_wins, function(a, b)
      return vim.api.nvim_win_get_position(a)[2] < vim.api.nvim_win_get_position(b)[2]
    end)
    local win_a, win_b = diff_wins[1], diff_wins[2]
    local total = vim.api.nvim_win_get_width(win_a) + vim.api.nvim_win_get_width(win_b) + 1
    local expected_a = math.floor(total * cfg.a / (cfg.a + cfg.b))
    assert.is_true(math.abs(vim.api.nvim_win_get_width(win_a) - expected_a) <= 2)
  end)
end)

describe("dirdiff.ui diff pane reuse", function()
  after_each(function()
    vim.cmd("tabfirst")
    pcall(vim.cmd, "tabonly!")
  end)

  it("reuses the same diff windows when navigating between two modified entries", function()
    local list_win, list_buf = open_dirdiff({
      { rel = "one.txt", content_a = "hello a, a longer line for a", content_b = "hello b" },
      { rel = "two.txt", content_a = "foo a, a longer line for a", content_b = "foo b" },
    })

    press_enter_on(list_win, list_buf, "one.txt")
    local tabpage = vim.api.nvim_win_get_tabpage(list_win)
    local first = other_wins(tabpage, list_win)
    table.sort(first)
    assert.equals(2, #first)

    press_enter_on(list_win, list_buf, "two.txt")
    local second = other_wins(tabpage, list_win)
    table.sort(second)

    assert.same(first, second)
  end)

  it("closes and re-splits when the pane count changes (two-sided -> one-sided)", function()
    local list_win, list_buf = open_dirdiff({
      { rel = "one.txt", content_a = "hello a, a longer line for a", content_b = "hello b" },
    })
    press_enter_on(list_win, list_buf, "one.txt")
    local tabpage = vim.api.nvim_win_get_tabpage(list_win)
    assert.equals(2, #other_wins(tabpage, list_win))

    -- Add an "A only" entry (b-side removed) and open it: only one side
    -- exists, so open_entry must fall back to close+resplit with a single pane.
    local base = vim.fn.tempname()
    vim.fn.mkdir(base .. "/a", "p")
    vim.fn.mkdir(base .. "/b", "p")
    vim.fn.writefile({ "only on a side" }, base .. "/a/added.txt")
    config.setup({})
    dirdiff.open(base .. "/a", base .. "/b")
    vim.wait(500, function()
      return vim.bo.filetype == "dirdiff"
    end, 10)
    list_win = vim.api.nvim_get_current_win()
    list_buf = vim.api.nvim_get_current_buf()
    local added_lnum
    for i, line in ipairs(vim.api.nvim_buf_get_lines(list_buf, 0, -1, false)) do
      if line == "+ added.txt" then
        added_lnum = i
      end
    end
    assert.is_not_nil(added_lnum)
    vim.api.nvim_win_set_cursor(list_win, { added_lnum, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    vim.wait(200)

    tabpage = vim.api.nvim_win_get_tabpage(list_win)
    assert.equals(1, #other_wins(tabpage, list_win))
  end)
end)

describe("dirdiff.ui cleanup on close", function()
  after_each(function()
    vim.cmd("tabfirst")
    pcall(vim.cmd, "tabonly!")
  end)

  it("closes diff panes and the whole tab when nothing else is open", function()
    local list_win, list_buf = open_dirdiff({
      { rel = "one.txt", content_a = "hello a, a longer line for a", content_b = "hello b" },
    })
    press_enter_on(list_win, list_buf, "one.txt")
    local tabpage = vim.api.nvim_win_get_tabpage(list_win)
    local diff_wins = other_wins(tabpage, list_win)
    assert.equals(2, #diff_wins)

    press_close(list_win)

    assert.is_false(vim.api.nvim_tabpage_is_valid(tabpage))
    for _, w in ipairs(diff_wins) do
      assert.is_false(vim.api.nvim_win_is_valid(w))
    end
  end)

  it("closes a loclist opened from a diff pane, but leaves an unrelated window and its own loclist alone", function()
    local list_win, list_buf = open_dirdiff({
      { rel = "one.txt", content_a = "hello a, a longer line for a", content_b = "hello b" },
    })

    -- A genuinely unrelated window (real file, not a duplicate of the list
    -- buffer) with its own loclist -- not owned by any diff pane, so it must
    -- survive cleanup.
    local unrelated_file = vim.fn.tempname()
    vim.fn.writefile({ "unrelated" }, unrelated_file)
    vim.cmd("vsplit " .. vim.fn.fnameescape(unrelated_file))
    local unrelated_win = vim.api.nvim_get_current_win()
    vim.fn.setloclist(unrelated_win, { { text = "dummy", bufnr = vim.api.nvim_win_get_buf(unrelated_win) } })
    vim.api.nvim_win_call(unrelated_win, function()
      vim.cmd("lopen")
    end)
    vim.wait(100)
    vim.api.nvim_set_current_win(list_win)

    press_enter_on(list_win, list_buf, "one.txt")
    local tabpage = vim.api.nvim_win_get_tabpage(list_win)
    local diff_wins = other_wins(tabpage, list_win)
    local win_a
    for _, w in ipairs(diff_wins) do
      local info = vim.fn.getwininfo(w)[1]
      if info.loclist ~= 1 and w ~= unrelated_win then
        win_a = w
        break
      end
    end
    assert.is_not_nil(win_a)

    -- A loclist opened from inside the diff pane itself: owned by win_a,
    -- so it must close together with the diff panes.
    vim.fn.setloclist(win_a, { { text = "dummy", bufnr = vim.api.nvim_win_get_buf(win_a) } })
    vim.api.nvim_win_call(win_a, function()
      vim.cmd("lopen")
    end)
    vim.wait(100)
    local owned_loclist_win
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
      local info = vim.fn.getwininfo(w)[1]
      if info.loclist == 1 and vim.fn.getloclist(w, { filewinid = 0 }).filewinid == win_a then
        owned_loclist_win = w
      end
    end
    assert.is_not_nil(owned_loclist_win)

    press_close(list_win)

    assert.is_true(vim.api.nvim_tabpage_is_valid(tabpage), "tab stays open because the unrelated window remains")
    assert.is_true(vim.api.nvim_win_is_valid(unrelated_win), "unrelated window survives")
    assert.is_false(vim.api.nvim_win_is_valid(owned_loclist_win), "loclist owned by the diff pane is closed")

    local has_unrelated_loclist = false
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
      if vim.fn.getwininfo(w)[1].loclist == 1 then
        has_unrelated_loclist = true
      end
    end
    assert.is_true(has_unrelated_loclist, "the unrelated window's own loclist survives")
  end)
end)
