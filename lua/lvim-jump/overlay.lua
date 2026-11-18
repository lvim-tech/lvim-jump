-- lvim-jump.overlay: every visual the jump modes paint — match/range extmarks, the label
-- virt_text overlays, and the window dim backdrop — plus the pattern prompt echo. The jump
-- loops are modal (blocked on getcharstr), so nothing here is event-driven: the engine draws,
-- forces a redraw, blocks, and finally clears. Extmark priorities are deliberately high
-- (~5000) so the overlays paint over treesitter/semantic/search highlighting; the label sits
-- one step above its match so a label on a 1-char match wins the cell.
--
-- The backdrop uses lvim-utils.dim's LOW-LEVEL primitives (build/set with a caller-owned
-- namespace), NOT dim.apply_backdrop: the focus-aware backdrop assumes a consumer-owned
-- float has focus and lifts when it doesn't — but during a jump the CURRENT window is itself
-- a searched (and dimmed) window, so ownership here is "every searched window for the
-- blocking duration", applied and restored inline. Each window's previous namespace is
-- captured and restored exactly (it may sit on lvim-colorscheme's focus-dim namespace).
-- The plugin's own highlight groups are registered with dim.preserve (see highlights.lua),
-- so the muted namespace copies them verbatim and the labels stay crisp on the dim text.
--
---@module "lvim-jump.overlay"

local config = require("lvim-jump.config")

local api = vim.api

local ok_dim, dim = pcall(require, "lvim-utils.dim")
local ok_colors, colors = pcall(require, "lvim-utils.colors")

local M = {}

---@type integer extmark namespace for every overlay this plugin draws
local ns = api.nvim_create_namespace("lvim_jump")
---@type integer|nil caller-owned dim namespace (never the lvim-utils default, so our amount
--- can't clobber the focus-dim consumer's — see lvim-utils.dim's header contract)
local dim_ns = nil
---@type table<integer, boolean> buffers we drew extmarks into (cleared on M.clear)
local drawn = {}
---@type table<integer, integer> window → highlight namespace it was on before we dimmed it
local dimmed = {}

-- Extmark priorities: match body < current match < label. High enough to beat treesitter
-- (~100), LSP semantic tokens (~125) and hlsearch, low enough to stay under other modal UIs.
local PRIO_RANGE = 4900 -- ts-select node range tints (labels must beat them)
local PRIO_MATCH = 5000
local PRIO_LABEL = 5010

--- Byte length of line `row` (0-based) in `buf`; 0 for an out-of-range row.
---@param buf integer
---@param row integer
---@return integer
local function line_len(buf, row)
    local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    return line and #line or 0
end

--- Paint one match's body. The current (cycle-selected) match uses the yellow variant so
--- the accept key's target is always visible even when it has no label.
---@param m LvimJumpMatch
---@param current boolean
---@return nil
function M.match(m, current)
    if not api.nvim_buf_is_valid(m.buf) then
        return
    end
    drawn[m.buf] = true
    pcall(api.nvim_buf_set_extmark, m.buf, ns, m.row, m.col, {
        end_col = math.min(m.end_col, line_len(m.buf, m.row)),
        hl_group = current and "LvimJumpCurrent" or "LvimJumpMatch",
        priority = PRIO_MATCH,
    })
end

--- Paint a label as a 1-cell virt_text OVERLAY on the character AFTER the match (col =
--- match end), the canonical label spot: the match text itself stays readable while the
--- label covers the char whose typing is impossible anyway (it is excluded from the
--- alphabet). For a match ending at EOL the extmark anchors at the line's byte length —
--- an overlay there renders in the virtual cell past the text, which is exactly where the
--- "next char" would be.
---@param m LvimJumpMatch
---@return nil
function M.label(m)
    if not m.label or not api.nvim_buf_is_valid(m.buf) then
        return
    end
    drawn[m.buf] = true
    pcall(api.nvim_buf_set_extmark, m.buf, ns, m.row, math.min(m.end_col, line_len(m.buf, m.row)), {
        virt_text = { { m.label, "LvimJumpLabel" } },
        virt_text_pos = "overlay",
        priority = PRIO_LABEL,
    })
end

--- Draw a whole match set: bodies + labels, with `matches[current]` in the current-match
--- variant. One call per loop iteration, after M.clear().
---@param matches LvimJumpMatch[]
---@param current integer  1-based index of the cycle-selected match
---@return nil
function M.matches(matches, current)
    for i, m in ipairs(matches) do
        M.match(m, i == current)
    end
    -- labels second, so a label overlaying a 1-char neighbouring match paints on top
    for _, m in ipairs(matches) do
        M.label(m)
    end
end

--- Paint a multi-line range tint (ts-select node ranges). end_col is exclusive,
--- treesitter-style; hl_end_row+eol semantics come free from strict extmark ranges.
---@param buf integer
---@param srow integer 0-based
---@param scol integer byte col
---@param erow integer 0-based
---@param ecol integer exclusive byte col
---@param group string highlight group
---@param prio? integer priority offset added to the range base (deeper node = higher)
---@return nil
function M.range(buf, srow, scol, erow, ecol, group, prio)
    if not api.nvim_buf_is_valid(buf) then
        return
    end
    drawn[buf] = true
    pcall(api.nvim_buf_set_extmark, buf, ns, srow, scol, {
        end_row = erow,
        end_col = ecol,
        hl_group = group,
        -- follow the node's TEXT, do NOT fill the empty space to the window edge (hl_eol filled whole
        -- lines, so a multi-line node washed the screen in tint — the ts-select clutter)
        hl_eol = false,
        priority = PRIO_RANGE + (prio or 0),
    })
end

--- Paint a bare label glyph at a position (ts-select node starts — no match record).
---@param buf integer
---@param row integer 0-based
---@param col integer byte col
---@param label string
---@return nil
function M.label_at(buf, row, col, label)
    if not api.nvim_buf_is_valid(buf) then
        return
    end
    drawn[buf] = true
    pcall(api.nvim_buf_set_extmark, buf, ns, row, math.min(col, line_len(buf, row)), {
        virt_text = { { label, "LvimJumpLabel" } },
        virt_text_pos = "overlay",
        priority = PRIO_LABEL,
    })
end

--- Remove every extmark this plugin drew, in every buffer it drew into.
---@return nil
function M.clear()
    for buf in pairs(drawn) do
        if api.nvim_buf_is_valid(buf) then
            api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        end
    end
    drawn = {}
end

--- Dim the given windows' text for the duration of a jump: (re)build our OWN dim namespace
--- from the live global highlights (so it always tracks the current theme) and switch each
--- window onto it, remembering the namespace it was on. Windows showing a special-buftype
--- buffer are skipped — they paint their own background, and muting their fg toward the
--- EDITOR bg would lighten them (same rule as the lvim-utils backdrop applier).
---@param wins integer[]
---@return nil
function M.dim_on(wins)
    if not (config.dim.enabled and ok_dim and ok_colors) then
        return
    end
    if not dim_ns then
        dim_ns = api.nvim_create_namespace("lvim_jump_dim")
    end
    local built = dim.build(colors.bg, config.dim.amount or 0.45, dim_ns)
    for _, win in ipairs(wins) do
        if api.nvim_win_is_valid(win) and not dimmed[win] then
            local buf = api.nvim_win_get_buf(win)
            if vim.bo[buf].buftype == "" then
                local prev = 0
                pcall(function()
                    prev = api.nvim_get_hl_ns({ winid = win })
                end)
                -- a window can't sensibly "restore" to our own dim ns (a crashed prior
                -- jump); its true original is the global namespace then
                if prev == dim_ns then
                    prev = 0
                end
                dimmed[win] = (type(prev) == "number" and prev >= 0) and prev or 0
                dim.set(win, built)
            end
        end
    end
end

--- Restore every window dimmed by dim_on to the exact namespace it was on before.
---@return nil
function M.dim_off()
    if not ok_dim then
        return
    end
    for win, prev in pairs(dimmed) do
        dim.set(win, prev)
    end
    dimmed = {}
end

--- Echo the live pattern prompt (`󰅂 pattern  N`). getcharstr blocks all normal redrawing,
--- so the engine calls this right before its explicit :redraw each iteration. Skipped with
--- cmdheight=0 — there is no command line cell to draw into, and forcing a message there
--- would open the message area over the jump overlays.
---@param pattern string
---@param count integer  current match count
---@return nil
function M.prompt(pattern, count)
    if not config.prompt.enabled or vim.o.cmdheight == 0 then
        return
    end
    api.nvim_echo({
        { config.prompt.icon .. " ", "LvimJumpPromptIcon" },
        { pattern, "LvimJumpPrompt" },
        { count > 0 and ("  " .. count) or "", "LvimJumpPromptCount" },
    }, false, {})
end

--- Clear the prompt line (end of a jump).
---@return nil
function M.prompt_clear()
    if not config.prompt.enabled or vim.o.cmdheight == 0 then
        return
    end
    api.nvim_echo({ { "" } }, false, {})
end

return M
