-- The two invariants that make a label motion usable, and the scan underneath them.
--
-- 1. NON-AMBIGUOUS: a character that could continue the typed pattern is never handed out as
--    a label. So "is this an assigned label?" can be answered before "does this extend the
--    search?" with no timeout and no confirm key -- not a heuristic, an exclusion.
-- 2. STABLE: a match that survives a keystroke keeps the label it already had. The label a
--    user read one keystroke ago is still the right key to press.
--
-- The second one is easy to assume away, and assuming it away is how this spec was first
-- written wrongly: after typing "alpha" the labels are NOT the head of the alphabet, they are
-- whatever those two matches were granted back when the pattern was still "a".

local engine = require("lvim-jump.engine")
local labels = require("lvim-jump.labels")
local config = require("lvim-jump.config")

--- A buffer with `content`, the cursor at (row, col) 1-based/0-based, and its window id.
---@param content string[]
---@param row? integer
---@param col? integer
---@return integer win
local function given(content, row, col)
    vim.cmd("silent! only")
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, content)
    vim.api.nvim_win_set_cursor(0, { row or 1, col or 0 })
    return vim.api.nvim_get_current_win()
end

--- Matches as "row:col" strings, which is all these assertions care about.
---@param matches LvimJumpMatch[]
---@return string[]
local function positions(matches)
    local out = {}
    for _, m in ipairs(matches) do
        out[#out + 1] = m.row .. ":" .. m.col
    end
    return out
end

describe("lvim-jump: the scan")

it("finds every occurrence in a line, in buffer order, by byte column", function()
    local win = given({ "ab xx ab yy ab" })
    eq({ "0:0", "0:6", "0:12" }, positions(engine.collect("ab", { wins = { win } })))
end)

it("searches a literal, never a pattern", function()
    local win = given({ "alpha beta" })
    eq({}, positions(engine.collect("a.pha", { wins = { win } })), "the dot is a dot")
    eq({}, positions(engine.collect("al*", { wins = { win } })))
end)

it("an empty pattern finds nothing", function()
    local win = given({ "alpha" })
    eq({}, positions(engine.collect("", { wins = { win } })))
end)

it("smart_case: a lowercase pattern is insensitive, an uppercase one exact", function()
    local win = given({ "alpha", "ALPHA" })
    eq({ "0:0", "1:0" }, positions(engine.collect("alpha", { wins = { win } })))
    eq({ "1:0" }, positions(engine.collect("ALPHA", { wins = { win } })))
    eq({ "0:0" }, positions(engine.collect("alpha", { wins = { win }, exact_case = true })), "exact_case overrides it")
end)

it("the match under the cursor is not offered", function()
    local win = given({ "alpha alpha" }, 1, 0)
    eq({ "0:0", "0:6" }, positions(engine.collect("alpha", { wins = { win } })))
    eq(
        { "0:6" },
        positions(engine.collect("alpha", { wins = { win }, from = { win = win, row = 0, col = 0 } })),
        "jumping where the cursor already is would waste the best label on a no-op"
    )
end)

it("only what is on screen is scanned", function()
    local content = {}
    for i = 1, 300 do
        content[i] = i == 1 and "target" or ("line " .. i)
    end
    content[200] = "target"
    local win = given(content, 200, 0)
    vim.api.nvim_win_call(win, function()
        vim.cmd("normal! zt")
    end)
    eq(200, vim.fn.line("w0", win), "precondition: the viewport starts at line 200")

    local found = positions(engine.collect("target", { wins = { win } }))
    eq({ "199:0" }, found, "the match 199 lines above the viewport cannot be labelled, so it is not collected")
end)

it("the following character is recorded, and is a whole character", function()
    local win = given({ "ab", "abc", "абв" })
    local m = engine.collect("ab", { wins = { win } })
    eq(nil, m[1].next_char, "nothing follows a match at end of line")
    eq("c", m[2].next_char)

    local cyr = engine.collect("аб", { wins = { win } })
    eq(1, #cyr)
    eq("в", cyr[1].next_char, "a two-byte character is one character")
    eq(4, cyr[1].col ~= nil and cyr[1].end_col, "columns are byte columns")
end)

it("with an insensitive scan, a following uppercase letter folds down", function()
    local win = given({ "abX" })
    local m = engine.collect("ab", { wins = { win } })
    eq("x", m[1].next_char, "so that the label 'x' is forbidden too")
    local exact = engine.collect("ab", { wins = { win }, exact_case = true })
    eq("X", exact[1].next_char)
end)

describe("lvim-jump: nearest first")

it("the cursor's own window comes first, then nearest line, then nearest column", function()
    local win = given({ "x alpha", "alpha alpha", "alpha" }, 2, 0)
    local m = engine.collect("alpha", { wins = { win } })
    engine.sort_by_distance(m, { win = win, row = 1, col = 0 })
    -- Measured, not assumed: 0:2 and 2:0 are both ONE row away, and at equal row distance the
    -- nearer COLUMN wins -- so 2:0 (column distance 0) comes before 0:2 (column distance 2).
    eq({ "1:0", "1:6", "2:0", "0:2" }, positions(m), "same line by column, then row distance, then column distance")
end)

describe("lvim-jump: a label never continues the search")

it("a character that follows a match is not handed out as a label", function()
    local win = given({ "alpha beta", "gamma alpha", "alpha delta" }, 1, 0)
    local m = engine.collect("a", { wins = { win }, from = { win = win, row = 0, col = 0 } })
    engine.sort_by_distance(m, { win = win, row = 0, col = 0 })
    local by_label = labels.assign(m, config.labels, {})

    local following = {}
    for _, match in ipairs(m) do
        if match.next_char then
            following[match.next_char] = true
        end
    end
    truthy(following["l"], "precondition: 'l' follows the 'a' of alpha")
    for ch in pairs(by_label) do
        eq(nil, following[ch], "label '" .. ch .. "' would also extend the pattern")
    end
    eq(nil, by_label["l"], "so 'l' is skipped even though the alphabet offers it before 'q'")
end)

it("a match that survives a keystroke keeps its label", function()
    local win = given({ "alpha beta", "gamma alpha", "alpha delta" }, 1, 0)
    local from = { win = win, row = 0, col = 0 }

    --- One narrowing step: collect, sort, assign with the previous keys.
    ---@param pattern string
    ---@param prev table<string, string>
    ---@return table<string, LvimJumpMatch> by_label
    ---@return table<string, string> keys
    ---@return LvimJumpMatch[] matches
    local function step(pattern, prev)
        local m = engine.collect(pattern, { wins = { win }, from = from })
        engine.sort_by_distance(m, from)
        local by_label, keys = labels.assign(m, config.labels, prev)
        return by_label, keys, m
    end

    local _, keys1, m1 = step("a", {})
    local label_of_1_6
    for _, m in ipairs(m1) do
        if m.row == 1 and m.col == 6 then
            label_of_1_6 = m.label
        end
    end
    truthy(label_of_1_6, "precondition: the match at 1:6 got a label on the first keystroke")

    local keys = keys1
    for _, pattern in ipairs({ "al", "alp", "alph", "alpha" }) do
        local _, k, m = step(pattern, keys)
        keys = k
        local still
        for _, match in ipairs(m) do
            if match.row == 1 and match.col == 6 then
                still = match.label
            end
        end
        eq(label_of_1_6, still, "the label changed under the user's eyes while typing " .. pattern)
    end
end)

it("a previous label that has become forbidden is not re-granted", function()
    local win = given({ "ab", "ab" })
    local m1 = engine.collect("ab", { wins = { win } })
    local _, keys = labels.assign(m1, config.labels, {})
    local first = m1[1].label
    truthy(first)

    -- Hand the same positions back, but with the old label now forbidden as a following char.
    local m2 = engine.collect("ab", { wins = { win } })
    m2[1].next_char = first
    local by_label = labels.assign(m2, config.labels, keys)
    truthy(m2[1].label ~= first, "it would be ambiguous with extending the pattern")
    eq(nil, by_label[first])
end)

it("more matches than the alphabet leaves the far ones label-less", function()
    local content = {}
    for i = 1, 20 do
        content[i] = "ab ab"
    end
    local win = given(content, 1, 0)
    local m = engine.collect("ab", { wins = { win } })
    engine.sort_by_distance(m, { win = win, row = 0, col = 0 })
    local by_label = labels.assign(m, config.labels, {})

    truthy(#m > #config.labels, "precondition: more matches than letters (" .. #m .. ")")
    eq(#config.labels, vim.tbl_count(by_label), "every letter is spent")
    for i = 1, #config.labels do
        truthy(m[i].label, "the nearest matches are the ones that get a label")
    end
    eq(nil, m[#m].label, "the farthest stays highlighted and cycle-reachable, not mislabelled")
end)

it("a label maps to exactly the match it was drawn on", function()
    local win = given({ "ab", "ab", "ab" }, 1, 0)
    local m = engine.collect("ab", { wins = { win } })
    engine.sort_by_distance(m, { win = win, row = 0, col = 0 })
    local by_label = labels.assign(m, config.labels, {})
    for _, match in ipairs(m) do
        if match.label then
            eq(match, by_label[match.label])
        end
    end
end)

describe("lvim-jump: the whole loop, one keystroke at a time")

-- These drive engine.run() through the typeahead, the way lvim-winpick's spec does. Every case
-- must feed keys that RESOLVE the jump: the loop blocks in getcharstr, and in a headless run a
-- getcharstr with nothing left to read ends the process -- so an unresolved case would not fail,
-- it would take the suite with it.

--- Throw away anything still sitting in the typeahead.
---
--- A case that ends early leaves its unread keys behind -- autojump_single returns the moment one
--- match is left, so feeding "unique" resolves on "un" and bequeaths "ique" to the next case,
--- which then searches for the wrong thing. getchar(0) is the non-blocking read: 0 means empty.
local function drain_typeahead()
    for _ = 1, 100 do
        local ok, c = pcall(vim.fn.getchar, 0)
        if not ok or c == 0 or c == "" then
            return
        end
    end
end

--- The label standing on (row, col) once `pattern` has been typed from the cursor, following the
--- same narrowing path the loop takes (which is what makes the label stable, and not the head of
--- the alphabet).
---@param win integer
---@param pattern string
---@param row integer
---@param col integer
---@return string|nil
local function label_after_typing(win, pattern, row, col)
    local cur = vim.api.nvim_win_get_cursor(win)
    local from = { win = win, row = cur[1] - 1, col = cur[2] }
    local keys, found = {}, nil
    for n = 1, #pattern do
        local m = engine.collect(pattern:sub(1, n), { wins = { win }, from = from })
        engine.sort_by_distance(m, from)
        local _, k = labels.assign(m, config.labels, keys)
        keys = k
        found = nil
        for _, match in ipairs(m) do
            if match.row == row and match.col == col then
                found = match.label
            end
        end
    end
    return found
end

it("typing a pattern and then a label lands on that match", function()
    drain_typeahead()
    local win = given({ "alpha beta", "gamma alpha", "alpha delta" }, 1, 0)
    local label = label_after_typing(win, "alpha", 1, 6)
    truthy(label, "precondition: the match at 1:6 has a label after typing alpha")

    vim.api.nvim_feedkeys("alpha" .. label, "t", false)
    local landed = engine.run({ multi_window = false })
    truthy(landed, "the label resolved to nothing")
    eq(1, landed.row)
    eq(6, landed.col)
    eq({ 2, 6 }, vim.api.nvim_win_get_cursor(win), "the cursor is on the match, in 1-based row")
end)

it("escape cancels and leaves the cursor alone", function()
    drain_typeahead()
    local win = given({ "alpha", "alpha", "alpha" }, 1, 0)
    vim.api.nvim_feedkeys("alpha\27", "t", false)
    eq(nil, engine.run({ multi_window = false }))
    eq({ 1, 0 }, vim.api.nvim_win_get_cursor(win))
end)

it("accept lands on the nearest match", function()
    drain_typeahead()
    local win = given({ "x", "alpha", "alpha" }, 1, 0)
    vim.api.nvim_feedkeys("alpha" .. vim.api.nvim_replace_termcodes("<CR>", true, true, true), "t", false)
    local landed = engine.run({ multi_window = false })
    truthy(landed)
    eq(1, landed.row, "row 1 is nearer to the cursor on row 0 than row 2 is")
    eq({ 2, 0 }, vim.api.nvim_win_get_cursor(win))
end)

it("a single match needs no label at all", function()
    drain_typeahead()
    local win = given({ "unique here", "nothing else" }, 2, 0)
    local was = config.jump.autojump_single
    config.jump.autojump_single = true
    vim.api.nvim_feedkeys("unique", "t", false)
    local landed = engine.run({ multi_window = false })
    config.jump.autojump_single = was
    truthy(landed, "with one match left there is nothing to choose between")
    eq({ 1, 0 }, vim.api.nvim_win_get_cursor(win))
end)

it("a landing offset cannot leave the cursor inside a multibyte character", function()
    drain_typeahead()
    local win = given({ "xx", "абв" }, 1, 0)
    local was_offset, was_auto = config.jump.offset, config.jump.autojump_single
    config.jump.offset = 99 -- far past the end of the line
    config.jump.autojump_single = true

    -- "а" has exactly one match in this buffer, so the first keystroke resolves it and nothing
    -- is left in the typeahead.
    vim.api.nvim_feedkeys("а", "t", false)
    local landed = engine.run({ multi_window = false })
    config.jump.offset = was_offset
    config.jump.autojump_single = was_auto

    truthy(landed, "the jump did not resolve")
    local row, col = unpack(vim.api.nvim_win_get_cursor(win))
    eq(2, row)
    eq(4, col, "clamped to the START byte of the last character, not to #line - 1")
    local line = vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]
    eq("в", line:sub(col + 1), "landing mid-character would be a broken cursor position")
end)
