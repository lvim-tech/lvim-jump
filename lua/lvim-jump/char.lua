-- lvim-jump.char: enhanced f/F/t/T — multi-line, LABEL-FIRST (the flash char UX). The
-- motion reads its target char, then shows ONLY the occurrences in the MOTION'S OWN
-- direction within the visible range (f/t forward, F/T backward — never the other side),
-- every one of them labeled, the nearest included and highlighted as the current target.
-- The cursor does NOT move until the user decides:
--
--   a label        → land on that occurrence and exit
--   accept (<CR>)  → land on the nearest (the current-highlighted one) and exit
--   f/t (the motion's own key) or `;` → step to the next occurrence, labels follow
--   F/T (its upper twin) or `,`       → step back (reverse of the motion's direction)
--   <Esc>          → cancel in place (the cursor never moved)
--   anything else  → land on the NEAREST and replay the key, so `fx` then `dw` deletes
--     from the first x exactly like native vim. Once the user has stepped (cursor already
--     placed by them), a foreign key only exits and replays — no surprise extra jump.
--
-- A count (`3fx`) or an active register recording/execution takes the DIRECT native path:
-- jump straight to the count-th occurrence, no labels, no loop — an interactive label
-- phase inside a macro would corrupt the replay (same rule as flash).
--
-- Semantics kept native where it matters:
--   • exact case always (native f is case-sensitive even under 'ignorecase' defaults; the
--     engine's smart_case is a SEARCH affordance, not a motion one) — collect() is called
--     with exact_case.
--   • t lands BEFORE the char, T AFTER it; the repeat filter compares the computed TARGET
--     against the cursor STRICTLY, which reproduces the native `;`-after-t quirk for free
--     (cursor already one-before an occurrence ⇒ that occurrence yields target == cursor ⇒
--     filtered out ⇒ the repeat advances to the NEXT one).
--   • operator-pending: forward f/t must operate THROUGH the landing char (native df/dt
--     behaviour), but a custom motion is exclusive — the native |o_v| toggle (`normal! v`)
--     flips it to inclusive. Backward F/T are exclusive both natively and here: an exclusive
--     backward motion covers [target, origin), which already includes the target char.
--     In o-mode the motion consumes a SINGLE target (no step keys — the repeat keys accept
--     the nearest instead) and a cancel aborts the operator like a failed native motion.
--
-- The label alphabet excludes the loop's own keys (f/t/F/T/;/,) and char_motions.
-- label_exclude (operator / immediate-edit keys, flash's set) so those keys keep their
-- native meaning right after a motion; labels.assign additionally forbids each target's
-- following buffer char (its overlay cell), keeping every label press unambiguous.
--
---@module "lvim-jump.char"

local config = require("lvim-jump.config")
local engine = require("lvim-jump.engine")
local labels = require("lvim-jump.labels")
local overlay = require("lvim-jump.overlay")

local api = vim.api
local fn = vim.fn

local M = {}

local ESC = "\27"

---@class LvimJumpCharLast
---@field char string    the searched character
---@field motion "f"|"t" landing style (on the char / before-after it)
---@field forward boolean the ORIGINAL direction (`;` repeats it, `,` reverses it)

---@type LvimJumpCharLast|nil the last char motion, shared by ;/, across invocations
local last = nil

---@type boolean default maps installed (attach/detach guard)
local attached = false

---@class LvimJumpCharTarget: LvimJumpMatch
---@field trow integer 0-based row the cursor would LAND on (differs from row for t at col 0)
---@field tcol integer byte col the cursor would land on

--- Compute the landing position for match `m` under motion style `motion`/direction.
--- t forward lands one char before the match — a match at col 0 wraps the target to the end
--- of the previous line (the motion is multi-line here, unlike native t). T backward lands
--- right after the char, clamped into the line for a char at EOL.
---@param m LvimJumpMatch
---@param motion "f"|"t"
---@param forward boolean
---@return integer trow, integer tcol
local function target_pos(m, motion, forward)
    if motion == "f" then
        return m.row, m.col
    end
    if forward then
        if m.col > 0 then
            return m.row, m.col - 1
        end
        -- char at col 0: land on the last cell of the previous line
        local prev = api.nvim_buf_get_lines(m.buf, m.row - 1, m.row, false)[1] or ""
        return math.max(m.row - 1, 0), math.max(#prev - 1, 0)
    end
    -- T backward: after the char; clamp for a char sitting at EOL
    local line = api.nvim_buf_get_lines(m.buf, m.row, m.row + 1, false)[1] or ""
    return m.row, math.max(0, math.min(m.end_col, math.max(#line - 1, 0)))
end

--- All in-reach targets for `char` in the current window's visible range, targets computed
--- for `motion`, filtered STRICTLY beyond the cursor in `forward` direction and sorted
--- nearest-first along it.
---@param char string
---@param motion "f"|"t"
---@param forward boolean
---@return LvimJumpCharTarget[]
local function collect_targets(char, motion, forward)
    local win = api.nvim_get_current_win()
    local cur = api.nvim_win_get_cursor(0)
    local crow, ccol = cur[1] - 1, cur[2]
    local matches = engine.collect(char, { wins = { win }, exact_case = true })
    ---@type LvimJumpCharTarget[]
    local targets = {}
    for _, m in ipairs(matches) do
        local trow, tcol = target_pos(m, motion, forward)
        local beyond
        if forward then
            beyond = trow > crow or (trow == crow and tcol > ccol)
        else
            beyond = trow < crow or (trow == crow and tcol < ccol)
        end
        if beyond then
            local t = m --[[@as LvimJumpCharTarget]]
            t.trow, t.tcol = trow, tcol
            targets[#targets + 1] = t
        end
    end
    table.sort(targets, function(a, b)
        if a.trow ~= b.trow then
            if forward then
                return a.trow < b.trow
            end
            return a.trow > b.trow
        end
        if forward then
            return a.tcol < b.tcol
        end
        return a.tcol > b.tcol
    end)
    return targets
end

--- Move the cursor onto target `t`. In operator-pending, forward motions are first forced
--- inclusive via |o_v| (see module header).
---@param t LvimJumpCharTarget
---@param forward boolean
---@param omode boolean
---@return nil
local function land(t, forward, omode)
    if omode and forward then
        vim.cmd("normal! v")
    end
    api.nvim_win_set_cursor(0, { t.trow + 1, t.tcol })
end

--- Perform ONE step: nth target in `forward` direction of `last`; false when none exist.
---@param n integer
---@param forward boolean
---@param omode boolean
---@return boolean moved
local function step(n, forward, omode)
    if not last then
        return false
    end
    local targets = collect_targets(last.char, last.motion, forward)
    -- count semantics are native: a count beyond the reachable targets FAILS the whole
    -- motion (no clamped landing on the last one)
    local t = targets[n]
    if not t then
        return false
    end
    land(t, forward, omode)
    return true
end

--- Resolve a vim-notation key to its typed (raw byte) form once, for comparison against
--- getcharstr output.
---@param lhs string
---@return string
local function termcode(lhs)
    return api.nvim_replace_termcodes(lhs, true, true, true)
end

--- The char-motion label alphabet: config.labels minus the loop's own keys (f/t/F/T/;/,)
--- and the char_motions.label_exclude set — those keys keep their native meaning right
--- after a motion (they act on / exit the label phase), so they must never be consumed
--- as labels.
---@return string
local function label_alphabet()
    ---@type table<string, boolean>
    local excluded = {}
    for c in ("ftFT;," .. (config.char_motions.label_exclude or "")):gmatch(".") do
        excluded[c] = true
    end
    ---@type string[]
    local out = {}
    for c in (config.labels or ""):gmatch(".") do
        if not excluded[c] then
            out[#out + 1] = c
        end
    end
    return table.concat(out)
end

--- Direction-scoped draw: collect the motion-direction occurrences from the CURRENT cursor
--- position (nearest first), label ALL of them — the nearest included, painted as the
--- current/yellow target — and force a redraw so the overlays AND the real (unmoved)
--- cursor are on screen before the loop blocks on the next key. Targets are strictly
--- beyond the cursor, so nothing is ever painted over the cursor cell.
---@param prev table<string, string> previous iteration's match-key→label map (stability)
---@return table<string, LvimJumpCharTarget> by_label
---@return LvimJumpCharTarget[] targets
---@return table<string, string> keys  feed back as `prev` on the next iteration
local function draw(prev)
    overlay.clear()
    if not last then
        return {}, {}, {}
    end
    local targets = collect_targets(last.char, last.motion, last.forward)
    local by_label, keys = labels.assign(targets, label_alphabet(), prev)
    ---@cast by_label table<string, LvimJumpCharTarget>
    overlay.matches(targets, 1)
    vim.cmd("redraw")
    return by_label, targets, keys
end

--- The label-first modal phase (see module header for the full key table). `moved` starts
--- true when the cursor already sits on an occurrence (entry via ;/, repeat) — then a
--- foreign key only exits and replays instead of first landing on the nearest.
---@param omode boolean  operator-pending: single-consume semantics, cancel aborts the operator
---@param moved boolean  the cursor has already been placed on an occurrence
---@return nil
local function pick(omode, moved)
    if not last then
        return
    end
    local key_accept = termcode(config.keys.accept or "<CR>")
    ---@type table<string, string> label stability across steps
    local prev = {}
    local ok, err = pcall(function()
        while true do
            local by_label, targets, keys = draw(prev)
            if #targets == 0 then
                -- stepped past the last in-reach occurrence: nothing left to offer, so do
                -- NOT block on an empty screen — ;/, keep working through their own maps
                return
            end
            prev = keys
            local ok_ch, ch = pcall(fn.getcharstr)
            if not ok_ch or ch == nil or ch == "" or ch == ESC then
                if omode then
                    api.nvim_feedkeys(ESC, "n", false)
                end
                return
            end
            if by_label[ch] then
                land(by_label[ch], last.forward, omode)
                return
            end
            local key_next = ch == ";" or ch == last.motion
            local key_prev = ch == "," or ch == last.motion:upper()
            if ch == key_accept or (omode and (key_next or key_prev)) then
                -- o-mode consumes a SINGLE target: the repeat keys mean "the plain motion",
                -- i.e. accept the nearest (like native dfx), never a multi-step
                land(targets[1], last.forward, omode)
                return
            end
            if key_next then
                moved = step(1, last.forward, false) or moved
            elseif key_prev then
                moved = step(1, not last.forward, false) or moved
            else
                -- foreign key: before any step the motion still owes its native landing —
                -- go to the nearest first, so `fxdw` deletes from the first x like native
                -- vim; after a step the cursor is already where the user put it
                if not moved then
                    land(targets[1], last.forward, omode)
                end
                api.nvim_feedkeys(ch, "t", false)
                return
            end
        end
    end)
    overlay.clear()
    vim.cmd("redraw")
    if not ok then
        vim.notify(tostring(err), vim.log.levels.ERROR, { title = "lvim-jump" })
    end
end

--- Entry point for the f/F/t/T maps: read the target char (blocking, like native), record
--- the motion for ;/, and enter the label-first phase — the cursor does not move until the
--- user picks. With a count or during register recording/execution the motion is DIRECT
--- (count-th occurrence, no labels). Operator-pending aborts the operator when the char
--- read is cancelled or nothing is in reach, like a failed native motion.
---@param key "f"|"F"|"t"|"T"
---@return nil
function M.motion(key)
    local count = vim.v.count1
    local direct = vim.v.count > 0 or fn.reg_recording() ~= "" or fn.reg_executing() ~= ""
    local omode = fn.mode(1):sub(1, 2) == "no"
    local ok, ch = pcall(fn.getcharstr)
    if not ok or ch == nil or ch == "" or ch == ESC or fn.keytrans(ch):sub(1, 1) == "<" then
        if omode then
            api.nvim_feedkeys(ESC, "n", false)
        end
        return
    end
    local forward = key == "f" or key == "t"
    last = {
        char = ch,
        motion = key:lower() --[[@as "f"|"t"]],
        forward = forward,
    }
    if direct then
        if not step(count, forward, omode) and omode then
            api.nvim_feedkeys(ESC, "n", false)
        end
        return
    end
    if #collect_targets(ch, last.motion, forward) == 0 then
        if omode then
            api.nvim_feedkeys(ESC, "n", false)
        end
        return
    end
    pick(omode, false)
end

--- Entry point for the ;/, maps: repeat the last char motion (`,` reversed) — the step is
--- immediate (native semantics), then normal/visual mode re-enters the label phase from
--- the new position for further picks. Without a recorded motion the key is replayed
--- natively, so ;/, keep meaning whatever they meant.
---@param reverse boolean
---@return nil
function M.repeat_move(reverse)
    if not last then
        api.nvim_feedkeys(reverse and "," or ";", "n", false)
        return
    end
    local count = vim.v.count1
    local direct = vim.v.count > 0 or fn.reg_recording() ~= "" or fn.reg_executing() ~= ""
    local omode = fn.mode(1):sub(1, 2) == "no"
    local forward = last.forward
    if reverse then
        forward = not forward
    end
    if not step(count, forward, omode) then
        if omode then
            api.nvim_feedkeys(ESC, "n", false)
        end
        return
    end
    if not (omode or direct) then
        pick(false, true)
    end
end

--- Install the f/F/t/T/;/, maps in n/x/o. Idempotent.
---@return nil
function M.attach()
    if attached then
        return
    end
    attached = true
    local modes = { "n", "x", "o" }
    for _, key in ipairs({ "f", "F", "t", "T" }) do
        vim.keymap.set(modes, key, function()
            M.motion(key)
        end, { desc = "lvim-jump: " .. key .. " (multi-line)" })
    end
    vim.keymap.set(modes, ";", function()
        M.repeat_move(false)
    end, { desc = "lvim-jump: repeat char motion" })
    vim.keymap.set(modes, ",", function()
        M.repeat_move(true)
    end, { desc = "lvim-jump: repeat char motion reversed" })
end

--- Remove the maps installed by attach(); f/F/t/T/;/, behave natively again.
---@return nil
function M.detach()
    if not attached then
        return
    end
    attached = false
    for _, key in ipairs({ "f", "F", "t", "T", ";", "," }) do
        pcall(vim.keymap.del, { "n", "x", "o" }, key)
    end
end

--- Whether the enhanced maps are currently installed.
---@return boolean
function M.is_attached()
    return attached
end

return M
