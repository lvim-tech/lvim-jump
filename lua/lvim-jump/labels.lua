-- lvim-jump.labels: label-alphabet assignment for a set of matches. Two invariants make the
-- label UX work, both borrowed from the best-in-class label motions:
--
--   1. NON-AMBIGUOUS — a character that could CONTINUE the typed pattern (i.e. the buffer
--      character right after any current match) is never used as a label. Typing it therefore
--      always means "narrow the search", and typing an assigned label always means "jump":
--      the engine can dispatch on "is it a label?" first with zero ambiguity, no timeout, no
--      extra confirm key.
--   2. STABLE — a match that survives a narrowing keystroke keeps the label it already had
--      (as long as that label is still allowed). Labels never shuffle under the user's eyes
--      as the pattern grows, so a label read one keystroke ago is still valid now.
--
-- Assignment order is the caller's match order (the engine passes matches distance-sorted,
-- nearest first), so the cheapest alphabet chars land on the closest targets. When there are
-- more matches than available labels, only the nearest get one — the rest stay highlighted
-- and reachable via the cycle keys.
--
---@module "lvim-jump.labels"

local M = {}

--- Split the alphabet string into its characters, once per call (the alphabet is tiny).
---@param alphabet string
---@return string[]
local function chars_of(alphabet)
    local out = {}
    for ch in alphabet:gmatch(".") do
        out[#out + 1] = ch
    end
    return out
end

--- A stable identity key for a match position — the anchor for label reuse across
--- keystrokes. A match that survives narrowing keeps the same (win,row,col) start, so the
--- key survives with it; end_col is deliberately NOT part of the key (extending the pattern
--- grows the match's end, and the label must stick regardless).
---@param m LvimJumpMatch
---@return string
function M.key(m)
    return m.win .. ":" .. m.row .. ":" .. m.col
end

--- Assign labels to `matches` IN PLACE (sets `m.label` on the ones that get a label) and
--- return the dispatch table label-char → match. `matches` must already be in the desired
--- assignment order (nearest first). `prev` is the key→label map of the previous iteration
--- (pass {} on the first): pass 1 re-grants surviving matches their old label, pass 2 hands
--- fresh alphabet chars to the still-unlabeled ones. Characters found in any match's
--- `next_char` are excluded entirely (invariant 1 above).
---@param matches LvimJumpMatch[]
---@param alphabet string
---@param prev table<string, string>  match key → label of the previous iteration
---@return table<string, LvimJumpMatch> by_label  label char → match
---@return table<string, string> keys  match key → label (feed back as `prev` next time)
function M.assign(matches, alphabet, prev)
    -- Forbidden = every character that would EXTEND the pattern if typed. The engine stores
    -- each match's following buffer char in `next_char`, already case-folded to the current
    -- case sensitivity — so with ignorecase active, a match followed by "A" forbids the
    -- label "a" too.
    ---@type table<string, boolean>
    local forbidden = {}
    for _, m in ipairs(matches) do
        if m.next_char then
            forbidden[m.next_char] = true
        end
    end
    ---@type table<string, boolean>
    local taken = {}
    ---@type table<string, LvimJumpMatch>
    local by_label = {}
    ---@type table<string, string>
    local keys = {}
    -- Pass 1 — stability: a surviving match keeps its previous label when that label is
    -- still legal (not forbidden by the new match set, not already re-granted).
    for _, m in ipairs(matches) do
        m.label = nil
        local key = M.key(m)
        local old = prev[key]
        if old and not forbidden[old] and not taken[old] then
            m.label = old
            taken[old] = true
            by_label[old] = m
            keys[key] = old
        end
    end
    -- Pass 2 — fresh chars, in alphabet order, to the unlabeled matches in caller
    -- (distance) order. A single cursor over the alphabet suffices: chars burned by pass 1
    -- or the forbidden set are skipped, and once the alphabet runs dry the remaining
    -- matches simply stay label-less (still highlighted, cycle-reachable).
    local chars = chars_of(alphabet)
    local idx = 1
    for _, m in ipairs(matches) do
        if not m.label then
            while idx <= #chars and (forbidden[chars[idx]] or taken[chars[idx]]) do
                idx = idx + 1
            end
            if idx > #chars then
                break
            end
            local ch = chars[idx]
            m.label = ch
            taken[ch] = true
            by_label[ch] = m
            keys[M.key(m)] = ch
            idx = idx + 1
        end
    end
    return by_label, keys
end

return M
