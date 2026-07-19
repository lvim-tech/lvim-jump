-- lvim-jump.engine: the search-and-label core — pattern state, the match scan over the
-- visible window ranges, and the modal getcharstr loop that narrows / labels / jumps.
--
-- The loop is the subtle part (same modal pattern as lvim-keys-helper): getcharstr blocks
-- the main loop, which means (a) NOTHING repaints on its own — every iteration must draw its
-- overlays and then force `:redraw` BEFORE blocking, or the user never sees them; and (b) no
-- autocmds/timers are needed to keep state coherent — the whole jump is one synchronous
-- call, so overlays/dim/prompt are applied and torn down inline (pcall-guarded, so a hard
-- error can't leave the editor dimmed).
--
-- Key dispatch order per keystroke decides the whole UX:
--   control keys (accept/next/prev/back) → assigned LABEL → pattern extension.
-- Labels may be checked before extension with zero ambiguity because the label alphabet
-- excludes every char that could continue the pattern (see labels.lua): typing such a char
-- would necessarily produce 0 matches, so "label wins" is not a heuristic — it is exact.
--
---@module "lvim-jump.engine"

local config = require("lvim-jump.config")
local labels = require("lvim-jump.labels")
local overlay = require("lvim-jump.overlay")

local api = vim.api
local fn = vim.fn

local M = {}

local ESC = "\27"

---@class LvimJumpMatch
---@field win integer      window the match is visible in
---@field buf integer      buffer of that window
---@field row integer      0-based line
---@field col integer      byte column of the match start
---@field end_col integer  byte column AFTER the match
---@field next_char string|nil  the buffer character right after the match (case-folded when
--- the scan is case-insensitive) — the label alphabet excludes these
---@field label string|nil assigned label char (labels.assign)

--- Whether the scan for `pattern` is case-insensitive under smart_case: a pure-lowercase
--- pattern searches ignorecase, any uppercase character makes it exact.
---@param pattern string
---@return boolean
local function ignorecase(pattern)
    return config.smart_case and pattern == pattern:lower()
end

--- Compile `pattern` as a LITERAL vim regex (\V very-nomagic: only backslash needs
--- escaping) with explicit case flags — vim.regex folds case per the locale/UTF-8 rules,
--- which plain string.lower would get wrong outside ASCII.
---@param pattern string
---@param ic boolean  case-insensitive
---@return vim.regex
local function compile(pattern, ic)
    local esc = pattern:gsub("\\", "\\\\")
    return vim.regex("\\V" .. (ic and "\\c" or "\\C") .. esc)
end

--- First UTF-8 character of `s` (lead byte + continuations), or nil for "".
---@param s string
---@return string|nil
local function first_char(s)
    return s:match("^[%z\1-\127\194-\244][\128-\191]*")
end

--- Scan the VISIBLE line range of each window in `opts.wins` for literal `pattern` and
--- return the matches in buffer order (per window, top-down). Only what is on screen is
--- searched — that is what labels can point at, and it bounds the scan cost to the
--- viewport regardless of buffer size. Each match records its following character
--- (case-folded to the scan's sensitivity) for the label-exclusion rule.
---@param pattern string
---@param opts { wins: integer[], from?: { win: integer, row: integer, col: integer }, exact_case?: boolean }
---  `from` (0-based row/col) excludes the match sitting exactly under the cursor — jumping
---  there is a no-op and it would hog the best label. `exact_case` bypasses smart_case
---  (char motions are case-exact like native f).
---@return LvimJumpMatch[]
function M.collect(pattern, opts)
    ---@type LvimJumpMatch[]
    local matches = {}
    if pattern == "" then
        return matches
    end
    local ic = not opts.exact_case and ignorecase(pattern)
    local ok, re = pcall(compile, pattern, ic)
    if not ok then
        return matches
    end
    local from = opts.from
    for _, win in ipairs(opts.wins) do
        if api.nvim_win_is_valid(win) then
            local buf = api.nvim_win_get_buf(win)
            -- line("w0"/"w$", win): first/last DISPLAYED line of that window (1-based)
            local top = fn.line("w0", win) - 1
            local bot = fn.line("w$", win) - 1
            local lines = api.nvim_buf_get_lines(buf, top, bot + 1, false)
            for i, line in ipairs(lines) do
                local row = top + i - 1
                local col = 0
                -- match_line returns byte offsets RELATIVE to the passed start col; loop
                -- with an advancing start to enumerate every occurrence in the line.
                while col <= #line do
                    local ok_m, s, e = pcall(re.match_line, re, buf, row, col)
                    if not ok_m or not s then
                        break
                    end
                    local mcol, mend = col + s, col + e
                    if not (from and win == from.win and row == from.row and mcol == from.col) then
                        local nxt = first_char(line:sub(mend + 1))
                        matches[#matches + 1] = {
                            win = win,
                            buf = buf,
                            row = row,
                            col = mcol,
                            end_col = mend,
                            -- fold to the scan's sensitivity: with ignorecase a following
                            -- "A" must forbid the label "a" (ASCII fold is enough — the
                            -- label alphabet itself is ASCII)
                            next_char = nxt and (ic and nxt:lower() or nxt) or nil,
                        }
                    end
                    -- a \V literal can't match empty, but guard the advance anyway
                    col = mcol + math.max(mend - mcol, 1)
                end
            end
        end
    end
    return matches
end

--- Sort `matches` in place by distance from `from` (0-based row/col in from.win): the
--- from-window's matches first, nearest line then nearest column, other windows after in
--- stable buffer order. This order feeds both label assignment (nearest match gets the
--- first alphabet char) and the accept/cycle keys (accept = matches[1] = nearest).
---@param matches LvimJumpMatch[]
---@param from { win: integer, row: integer, col: integer }
---@return nil
function M.sort_by_distance(matches, from)
    table.sort(matches, function(a, b)
        local aw = (a.win == from.win) and 0 or 1
        local bw = (b.win == from.win) and 0 or 1
        if aw ~= bw then
            return aw < bw
        end
        if aw == 0 then
            local da = math.abs(a.row - from.row)
            local db = math.abs(b.row - from.row)
            if da ~= db then
                return da < db
            end
            local ca = math.abs(a.col - from.col)
            local cb = math.abs(b.col - from.col)
            if ca ~= cb then
                return ca < cb
            end
        end
        if a.win ~= b.win then
            return a.win < b.win
        end
        if a.row ~= b.row then
            return a.row < b.row
        end
        return a.col < b.col
    end)
end

--- The windows a jump searches: every non-floating window of the current tabpage with
--- multi_window in plain normal mode; ONLY the current window in visual/operator-pending —
--- a motion cannot cross windows (the operator applies in one buffer, and switching windows
--- would abandon a visual selection).
---@param restrict boolean  true = current window only
---@return integer[]
local function target_windows(restrict)
    local cur = api.nvim_get_current_win()
    if restrict or not config.multi_window then
        return { cur }
    end
    ---@type integer[]
    local wins = { cur }
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if win ~= cur and api.nvim_win_get_config(win).relative == "" then
            wins[#wins + 1] = win
        end
    end
    return wins
end

--- Land on `m`: push a jumplist entry in the window being moved (so <C-o> returns), apply
--- the configured column offset (clamped into the line), and — operator-pending only, when
--- configured — force the motion inclusive via the native |o_v| toggle instead of any
--- position fiddling.
---@param m LvimJumpMatch
---@param omode boolean  the loop was entered operator-pending
---@return nil
local function land(m, omode)
    if not (api.nvim_win_is_valid(m.win) and api.nvim_buf_is_valid(m.buf)) then
        return
    end
    if m.win ~= api.nvim_get_current_win() then
        api.nvim_set_current_win(m.win)
    end
    -- m' records the CURRENT position in this window's jumplist before we move it — but
    -- only in plain normal mode: in visual/operator-pending the fed "m'" keys would act on
    -- the selection/operator instead (and native motions don't push jumplist entries there)
    if fn.mode(1) == "n" then
        pcall(vim.cmd, "normal! m'")
    end
    if omode and config.jump.inclusive then
        -- |o_v|: an exclusive characterwise motion becomes inclusive. The native seam for
        -- "operate THROUGH the target char" — never adjust the column by hand.
        vim.cmd("normal! v")
    end
    local line = api.nvim_buf_get_lines(m.buf, m.row, m.row + 1, false)[1] or ""
    local col = m.col + (config.jump.offset or 0)
    -- Clamp into the line, but to the START byte of the LAST character (not `#line - 1`), so a non-zero
    -- jump.offset can't leave the cursor inside a multibyte char at EOL.
    local last = line:find("[%z\1-\127\194-\244][\128-\191]*$")
    col = math.max(0, math.min(col, (last or 1) - 1))
    api.nvim_win_set_cursor(m.win, { m.row + 1, col })
end

--- Resolve a vim-notation key to its typed (raw byte) form once, for comparison against
--- getcharstr output.
---@param lhs string
---@return string
local function termcode(lhs)
    return api.nvim_replace_termcodes(lhs, true, true, true)
end

--- The modal jump loop. Reads keys until a label/accept lands somewhere, or <Esc>/an
--- unusable state cancels. Returns the match landed on (nil = cancelled) — remote.lua
--- builds on that return value.
---@param ctx { omode: boolean, wins: integer[], from: { win: integer, row: integer, col: integer } }
---@return LvimJumpMatch|nil
local function loop(ctx)
    ---@type string[] typed pattern as a char list — <BS> must drop one CHARACTER, and
    --- getcharstr hands multibyte chars as multi-byte strings, so a plain string:sub(1,-2)
    --- would shear UTF-8 sequences
    local chars = {}
    ---@type LvimJumpMatch[]
    local matches = {}
    ---@type table<string, LvimJumpMatch>
    local by_label = {}
    ---@type table<string, string> previous iteration's key→label map (label stability)
    local prev_labels = {}
    local current = 1
    -- control keys resolved once per loop from the live config
    local key_accept = termcode(config.keys.accept or "<CR>")
    local key_next = termcode(config.keys.next or "<Tab>")
    local key_prev = termcode(config.keys.prev or "<S-Tab>")
    local key_back = termcode(config.keys.back or "<BS>")
    while true do
        local pattern = table.concat(chars)
        overlay.clear()
        if pattern ~= "" then
            overlay.matches(matches, current)
        end
        overlay.prompt(pattern, #matches)
        -- getcharstr does not repaint: everything drawn above is invisible until this
        vim.cmd("redraw")
        local ok, ch = pcall(fn.getcharstr)
        if not ok or ch == nil or ch == "" or ch == ESC then
            return nil -- cancelled (or interrupted)
        end
        if ch == key_accept then
            if matches[current] then
                return matches[current]
            end
        elseif ch == key_next or ch == key_prev then
            if #matches > 0 then
                current = ((current - 1 + (ch == key_next and 1 or -1)) % #matches) + 1
            end
        elseif ch == key_back then
            chars[#chars] = nil
        elseif by_label[ch] then
            -- an assigned label ALWAYS means jump: label chars are excluded from pattern
            -- continuation by construction, so extending with this char would give 0 matches
            return by_label[ch]
        elseif ch == "<" or fn.keytrans(ch):sub(1, 1) ~= "<" then
            -- a plain printable character extends the pattern; special keys keytrans to "<...>" and are
            -- deliberately ignored (mouse noise, stray function keys). `<` is the one printable char keytrans
            -- ESCAPES ("<lt>"), so it is exempted explicitly — otherwise a literal `<` could never be searched.
            chars[#chars + 1] = ch
        else
            goto continue
        end
        -- rescan for the (possibly) changed pattern
        pattern = table.concat(chars)
        if pattern == "" then
            matches, by_label, prev_labels, current = {}, {}, {}, 1
        else
            matches = M.collect(pattern, { wins = ctx.wins, from = ctx.from })
            M.sort_by_distance(matches, ctx.from)
            by_label, prev_labels = labels.assign(matches, config.labels, prev_labels)
            current = math.max(1, math.min(current, #matches))
            if #matches == 1 and config.jump.autojump_single then
                return matches[1]
            end
        end
        ::continue::
    end
end

--- Run a jump. Modal and synchronous: dims the searched windows, runs the read loop, tears
--- everything down, and lands on the accepted match (if any). Callable from normal, visual
--- and operator-pending mode — in the latter two the search is restricted to the current
--- window (a motion cannot cross windows). In operator-pending a cancel also aborts the
--- pending operator (fed <Esc>), otherwise the operator would consume the next motion.
---@param opts? { multi_window?: boolean }  per-call override (remote.lua forces true)
---@return LvimJumpMatch|nil  the match landed on, nil when cancelled
function M.run(opts)
    opts = opts or {}
    local mode = fn.mode(1)
    local omode = mode:sub(1, 2) == "no"
    local visual = mode:sub(1, 1) == "v" or mode:sub(1, 1) == "V" or mode:sub(1, 1) == "\22"
    local restrict = omode or visual
    if opts.multi_window == false then
        restrict = true
    end
    local cur = api.nvim_win_get_cursor(0)
    local ctx = {
        omode = omode,
        wins = target_windows(restrict),
        from = { win = api.nvim_get_current_win(), row = cur[1] - 1, col = cur[2] },
    }
    overlay.dim_on(ctx.wins)
    -- pcall so ANY error in the loop still reaches the teardown — a raw error here would
    -- leave the editor dimmed with stray extmarks
    local ok, result = pcall(loop, ctx)
    overlay.clear()
    overlay.dim_off()
    overlay.prompt_clear()
    vim.cmd("redraw")
    if not ok then
        vim.notify(tostring(result), vim.log.levels.ERROR, { title = "lvim-jump" })
        result = nil
    end
    if result then
        land(result, omode)
        return result
    end
    if omode then
        -- cancel the pending operator too, exactly like aborting a native motion
        api.nvim_feedkeys(ESC, "n", false)
    end
    return nil
end

return M
