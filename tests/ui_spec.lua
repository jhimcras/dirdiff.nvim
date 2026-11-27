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
    vim.fn.mkdir(vim.fn.fnamemodify(base .. "/a/" .. p.rel, ":h"), "p")
    vim.fn.mkdir(vim.fn.fnamemodify(base .. "/b/" .. p.rel, ":h"), "p")
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

  it("keeps diff mode on an unrelated diff window in the same tab when navigating", function()
    local list_win, list_buf = open_dirdiff({
      { rel = "one.txt", content_a = "hello a, a longer line for a", content_b = "hello b" },
      { rel = "two.txt", content_a = "foo a, a longer line for a", content_b = "foo b" },
    })

    local unrelated_file = vim.fn.tempname()
    vim.fn.writefile({ "unrelated" }, unrelated_file)
    vim.cmd("vsplit " .. vim.fn.fnameescape(unrelated_file))
    local unrelated_win = vim.api.nvim_get_current_win()
    vim.cmd("diffthis")

    press_enter_on(list_win, list_buf, "one.txt")
    assert.is_true(vim.wo[unrelated_win].diff)

    press_enter_on(list_win, list_buf, "two.txt")
    assert.is_true(vim.wo[unrelated_win].diff)
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
    -- Same tab: the new comparison re-renders in the existing list window
    -- (focus stays where it was).
    vim.wait(500, function()
      return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(list_win), 0, -1, false), "\n"):find("added.txt", 1, true)
    end, 10)
    list_buf = vim.api.nvim_win_get_buf(list_win)
    vim.api.nvim_set_current_win(list_win)
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

-- Helpers for the multi-comparison / refresh specs below.

local function list_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function has_line(buf, text)
  return vim.tbl_contains(list_lines(buf), text)
end

-- Runs :DirDiff for the given roots from the current (non-list) tab and
-- returns the new result list's window and buffer.
local function open_roots(root_a, root_b, opts)
  config.setup(opts or {})
  dirdiff.open(root_a, root_b)
  vim.wait(500, function()
    return vim.bo.filetype == "dirdiff"
  end, 10)
  return vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function press_enter_on_line(list_win, list_buf, line)
  for i, l in ipairs(list_lines(list_buf)) do
    if l == line then
      vim.api.nvim_set_current_win(list_win)
      vim.api.nvim_win_set_cursor(list_win, { i, 0 })
      press("<CR>")
      vim.wait(200)
      return
    end
  end
  error("no list line " .. line)
end

-- The diff panes of a list's tab: every window except the list itself,
-- ordered left to right.
local function panes_of(list_win)
  local wins = other_wins(vim.api.nvim_win_get_tabpage(list_win), list_win)
  table.sort(wins, function(a, b)
    return vim.api.nvim_win_get_position(a)[2] < vim.api.nvim_win_get_position(b)[2]
  end)
  return wins
end

local function win_path(win)
  return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
end

local function wait_for_line(buf, text)
  vim.wait(1000, function()
    return vim.api.nvim_buf_is_valid(buf) and has_line(buf, text)
  end, 10)
end

describe("dirdiff refresh and multiple comparisons", function()
  after_each(function()
    vim.cmd("tabfirst")
    pcall(vim.cmd, "tabonly!")
  end)

  it("R keeps the open diff panes (same windows, files and diff mode)", function()
    local root_a, root_b = make_roots({
      { rel = "x.txt", content_a = "left", content_b = "right text" },
    })
    local list_win, list_buf = open_roots(root_a, root_b)
    press_enter_on_line(list_win, list_buf, "~ x.txt")
    local panes = panes_of(list_win)
    assert.equals(2, #panes)
    local paths = { win_path(panes[1]), win_path(panes[2]) }

    vim.fn.writefile({ "a" }, root_a .. "/added.txt")
    vim.api.nvim_set_current_win(list_win)
    press("R")
    wait_for_line(vim.api.nvim_win_get_buf(list_win), "+ added.txt")

    assert.is_true(has_line(vim.api.nvim_win_get_buf(list_win), "+ added.txt"))
    assert.same(panes, panes_of(list_win))
    assert.same(paths, { win_path(panes[1]), win_path(panes[2]) })
    assert.is_true(vim.wo[panes[1]].diff)
    assert.is_true(vim.wo[panes[2]].diff)
  end)

  it("R on the first of two comparisons rescans only that one", function()
    local a1, b1 = make_roots({ { rel = "first.txt", content_a = "one long", content_b = "1" } })
    local a2, b2 = make_roots({ { rel = "second.txt", content_a = "two long", content_b = "2" } })
    vim.cmd("tabfirst")
    local win1, buf1 = open_roots(a1, b1)
    vim.cmd("tabfirst")
    local win2, buf2 = open_roots(a2, b2)
    local tab1 = vim.api.nvim_win_get_tabpage(win1)
    local ntabs = #vim.api.nvim_list_tabpages()
    assert.equals(3, ntabs)
    local before2 = list_lines(buf2)

    vim.api.nvim_set_current_win(win1)
    vim.fn.writefile({ "x" }, a1 .. "/new-first.txt")
    press("R")
    wait_for_line(vim.api.nvim_win_get_buf(win1), "+ new-first.txt")

    assert.is_true(has_line(vim.api.nvim_win_get_buf(win1), "+ new-first.txt"))
    assert.is_true(has_line(vim.api.nvim_win_get_buf(win1), "~ first.txt"))
    assert.equals(tab1, vim.api.nvim_get_current_tabpage())
    assert.equals(win1, vim.api.nvim_get_current_win())
    assert.equals(ntabs, #vim.api.nvim_list_tabpages())
    assert.same(before2, list_lines(buf2))
    assert.is_false(has_line(vim.api.nvim_win_get_buf(win2), "~ first.txt"))
  end)

  it("q before a refresh completes does not reopen the list", function()
    local root_a, root_b = make_roots({ { rel = "x.txt", content_a = "left", content_b = "right text" } })
    local orig_tab = vim.api.nvim_get_current_tabpage()
    local list_win, list_buf = open_roots(root_a, root_b)
    local ntabs = #vim.api.nvim_list_tabpages()
    vim.fn.writefile({ "a" }, root_a .. "/added.txt")
    vim.api.nvim_set_current_win(list_win)
    press("R")
    press("q")
    vim.wait(500)

    assert.is_false(vim.api.nvim_buf_is_valid(list_buf))
    assert.equals(ntabs - 1, #vim.api.nvim_list_tabpages())
    assert.equals(orig_tab, vim.api.nvim_get_current_tabpage())
  end)

  it("q after a refresh completes closes normally, and R shows new entries while open", function()
    local root_a, root_b = make_roots({ { rel = "x.txt", content_a = "left", content_b = "right text" } })
    local orig_tab = vim.api.nvim_get_current_tabpage()
    local list_win = open_roots(root_a, root_b)
    vim.fn.writefile({ "a" }, root_a .. "/added.txt")
    vim.api.nvim_set_current_win(list_win)
    press("R")
    -- A refresh re-renders into a new buffer in the same window.
    wait_for_line(vim.api.nvim_win_get_buf(list_win), "+ added.txt")
    local list_buf = vim.api.nvim_win_get_buf(list_win)
    assert.is_true(has_line(list_buf, "+ added.txt"))
    press("q")
    vim.wait(200)
    assert.is_false(vim.api.nvim_buf_is_valid(list_buf))
    assert.equals(orig_tab, vim.api.nvim_get_current_tabpage())
  end)

  it("q on the first of two comparisons leaves the other tab's diff panes alone", function()
    local a1, b1 = make_roots({ { rel = "first.txt", content_a = "one long", content_b = "1" } })
    local a2, b2 = make_roots({ { rel = "second.txt", content_a = "left second", content_b = "right second!" } })
    vim.cmd("tabfirst")
    local win1, buf1 = open_roots(a1, b1)
    vim.cmd("tabfirst")
    local win2, buf2 = open_roots(a2, b2)
    press_enter_on_line(win2, buf2, "~ second.txt")
    local panes2 = panes_of(win2)
    assert.equals(2, #panes2)
    local paths2 = { win_path(panes2[1]), win_path(panes2[2]) }
    local tab1 = vim.api.nvim_win_get_tabpage(win1)
    local tab2 = vim.api.nvim_win_get_tabpage(win2)

    press_close(win1)

    assert.is_false(vim.api.nvim_tabpage_is_valid(tab1))
    assert.is_false(vim.api.nvim_buf_is_valid(buf1))
    assert.is_true(vim.api.nvim_tabpage_is_valid(tab2))
    assert.same(panes2, panes_of(win2))
    assert.same(paths2, { win_path(panes2[1]), win_path(panes2[2]) })
    assert.is_true(vim.wo[panes2[1]].diff and vim.wo[panes2[2]].diff)

    -- Control: closing the second one only closes its own tab.
    local a3, b3 = make_roots({ { rel = "third.txt", content_a = "three long", content_b = "3" } })
    vim.cmd("tabfirst")
    local win3, buf3 = open_roots(a3, b3)
    press_close(win2)
    assert.is_false(vim.api.nvim_tabpage_is_valid(tab2))
    assert.is_true(vim.api.nvim_win_is_valid(win3))
    assert.is_true(vim.api.nvim_buf_is_valid(buf3))
  end)

  it("DirDiffSeparation from another tab re-renders the existing result in place", function()
    local root_a, root_b = make_roots({
      { rel = "sub/x.txt", content_a = "left side", content_b = "r" },
    })
    local list_win, list_buf = open_roots(root_a, root_b)
    local group = require("dirdiff.group")
    local old = config.options.sort.separation
    assert.equals("diff_only", old)
    assert.is_true(vim.api.nvim_buf_get_lines(list_buf, 2, 3, false)[1]:find("diff_only", 1, true) ~= nil)

    vim.cmd("tabfirst")
    assert.not_equals(vim.api.nvim_win_get_tabpage(list_win), vim.api.nvim_get_current_tabpage())
    dirdiff.toggle_separation()

    local expected = group.next_separation(old)
    assert.equals("folder_only", expected)
    assert.is_true(vim.api.nvim_win_is_valid(list_win))
    local buf = vim.api.nvim_win_get_buf(list_win)
    assert.is_true(vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:find(expected, 1, true) ~= nil)
    local found = false
    for _, l in ipairs(list_lines(buf)) do
      if l:find("sub", 1, true) and l:find("1 file", 1, true) then
        found = true
      end
    end
    assert.is_true(found, "folder group header for sub is shown")
    assert.is_true(has_line(buf, "~ sub/x.txt"))
    assert.is_false(vim.api.nvim_tabpage_get_number(vim.api.nvim_win_get_tabpage(list_win)) == vim.api.nvim_tabpage_get_number(0))
  end)
end)

describe("dirdiff entries and mappings", function()
  after_each(function()
    vim.cmd("tabfirst")
    pcall(vim.cmd, "tabonly!")
  end)

  it("opens both sides of an Equal entry in diff mode", function()
    local root_a, root_b = make_roots({ { rel = "report.txt", content_a = "same", content_b = "same" } })
    local list_win, list_buf = open_roots(root_a, root_b, { sort = { equal = "show" } })
    press_enter_on_line(list_win, list_buf, "= report.txt")

    local panes = panes_of(list_win)
    assert.equals(2, #panes)
    assert.equals(vim.uv.fs_realpath(root_a .. "/report.txt"), vim.uv.fs_realpath(win_path(panes[1])))
    assert.equals(vim.uv.fs_realpath(root_b .. "/report.txt"), vim.uv.fs_realpath(win_path(panes[2])))
    assert.is_true(vim.wo[panes[1]].diff and vim.wo[panes[2]].diff)
  end)

  it("restores a pre-existing buffer-local gl mapping after the comparison closes", function()
    local root_a, root_b = make_roots({ { rel = "x.txt", content_a = "alpha bravo charlie", content_b = "other side" } })
    vim.cmd("tabfirst")
    vim.cmd("edit " .. vim.fn.fnameescape(root_a .. "/x.txt"))
    vim.cmd("nnoremap <buffer> gl $")
    local normal_win = vim.api.nvim_get_current_win()
    local normal_buf = vim.api.nvim_get_current_buf()

    local list_win, list_buf = open_roots(root_a, root_b)
    press_enter_on_line(list_win, list_buf, "~ x.txt")
    local win_a = panes_of(list_win)[1]
    assert.equals(normal_buf, vim.api.nvim_win_get_buf(win_a))
    assert.equals(win_a, vim.api.nvim_get_current_win())

    -- In the diff pane gl goes to the list (the plugin's mapping wins).
    press("gl")
    assert.equals(list_win, vim.api.nvim_get_current_win())

    press_close(list_win)

    vim.api.nvim_set_current_win(normal_win)
    local map = vim.fn.maparg("gl", "n", false, true)
    assert.equals("$", map.rhs)
    assert.equals(1, map.buffer)
    vim.api.nvim_win_set_cursor(normal_win, { 1, 0 })
    press("0gl")
    assert.equals(18, vim.api.nvim_win_get_cursor(normal_win)[2])
    vim.cmd("bwipeout!")
  end)

  it("lists and opens a file whose name contains a newline", function()
    local base = vim.fn.tempname()
    vim.fn.mkdir(base .. "/a", "p")
    vim.fn.mkdir(base .. "/b", "p")
    local name = "alpha\nbeta.txt"
    vim.fn.writefile({ "payload" }, base .. "/a/" .. name)
    vim.fn.writefile({ "payload" }, base .. "/a/plain.txt")
    local list_win, list_buf = open_roots(base .. "/a", base .. "/b")

    assert.is_true(has_line(list_buf, "+ alpha\\nbeta.txt"))
    press_enter_on_line(list_win, list_buf, "+ alpha\\nbeta.txt")
    local panes = panes_of(list_win)
    assert.equals(1, #panes)
    assert.equals(vim.uv.fs_realpath(base .. "/a/" .. name), vim.uv.fs_realpath(win_path(panes[1])))
    assert.same({ "payload" }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(panes[1]), 0, -1, false))

    -- Control: an ordinary name still works (and reuses the single pane).
    press_enter_on_line(list_win, list_buf, "+ plain.txt")
    assert.equals(vim.uv.fs_realpath(base .. "/a/plain.txt"), vim.uv.fs_realpath(win_path(panes_of(list_win)[1])))
  end)
end)
