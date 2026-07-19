-- lvim-jump.ts: labeled treesitter node selection — the "expand selection by syntax"
-- workflow compressed into one keypress. From the cursor, the ancestor node chain is
-- collected (duplicate ranges skipped — many grammars stack same-range wrapper nodes);
-- every node's range gets a rank-fading tint (innermost strongest) and a label at its
-- start; pressing a label visually selects that node's exact range.
--
-- Parsing goes through the native vim.treesitter API — in the lvim-tech stack the parsers
-- themselves are provisioned by lvim-ts, but nothing here binds to it: any buffer with an
-- attached parser works (health.lua reports the lvim-ts seam). Label chars here have no
-- pattern-continuation constraint (nothing is being typed/narrowed), so the plain alphabet
-- order applies verbatim: `a` is always the innermost node.
--
-- Same modal discipline as the engine: draw → :redraw → block on getcharstr → tear down
-- inline, pcall-guarded so an error can't leave tints/dim behind.
--
---@module "lvim-jump.ts"

local config = require("lvim-jump.config")
local overlay = require("lvim-jump.overlay")

local api = vim.api
local fn = vim.fn

local M = {}

local ESC = "\27"

---@class LvimJumpTsNode
---@field srow integer 0-based start row
---@field scol integer start byte col
---@field erow integer 0-based end row
---@field ecol integer EXCLUSIVE end byte col (treesitter range convention)
---@field label string assigned label char

--- The ancestor chain of ranges at the cursor, innermost first, duplicate ranges merged,
--- capped at the label alphabet (deeper ancestors would be unreachable anyway).
---@param buf integer
---@return LvimJumpTsNode[]
local function ancestor_ranges(buf)
    ---@type LvimJumpTsNode[]
    local chain = {}
    local ok_parser, parser = pcall(vim.treesitter.get_parser, buf)
    if not ok_parser or not parser then
        return chain
    end
    parser:parse() -- ensure the tree covers the current buffer state
    local ok_node, node = pcall(vim.treesitter.get_node, { bufnr = buf })
    if not ok_node then
        return chain
    end
    local alphabet_len = #config.labels
    while node and #chain < alphabet_len do
        local srow, scol, erow, ecol = node:range()
        local prev = chain[#chain]
        -- grammars wrap the same span in several nodes (expression → call → identifier…);
        -- one label per DISTINCT range keeps the ladder meaningful
        if not (prev and prev.srow == srow and prev.scol == scol and prev.erow == erow and prev.ecol == ecol) then
            chain[#chain + 1] = { srow = srow, scol = scol, erow = erow, ecol = ecol, label = "" }
        end
        node = node:parent()
    end
    for i, r in ipairs(chain) do
        r.label = config.labels:sub(i, i)
    end
    return chain
end

--- Visually select the exact node range: exit any current visual mode first (a fresh `v`
--- from inside visual would just move its end), anchor at the start, extend to the end.
--- The exclusive treesitter end col becomes the inclusive visual end char; an end col of 0
--- means "up to the end of the previous line".
---@param buf integer
---@param r LvimJumpTsNode
---@return nil
local function select_range(buf, r)
    local mode = fn.mode(1):sub(1, 1)
    if mode == "v" or mode == "V" or mode == "\22" then
        vim.cmd("normal! \27")
    end
    local erow, ecol = r.erow, r.ecol - 1
    if r.ecol == 0 then
        erow = math.max(r.erow - 1, 0)
        local line = api.nvim_buf_get_lines(buf, erow, erow + 1, false)[1] or ""
        ecol = math.max(#line - 1, 0)
    end
    api.nvim_win_set_cursor(0, { r.srow + 1, r.scol })
    vim.cmd("normal! v")
    api.nvim_win_set_cursor(0, { erow + 1, math.max(ecol, 0) })
end

--- Draw the ladder: tint ONLY the current (innermost) node's exact span with the single
--- `LvimJumpTsRange1` group (the default `<CR>` selection), then paint every ancestor's label on
--- top. Ancestor levels are conveyed by their labels, NOT by stacking faded tints per nested range.
---@param buf integer
---@param chain LvimJumpTsNode[]
---@return nil
local function draw(buf, chain)
    overlay.clear()
    -- Tint ONLY the CURRENT (innermost) node — its exact span, the default `<CR>` selection. The
    -- ancestor levels are conveyed by their LABELS at each start (flash-clean), NOT by stacking a
    -- faded tint over every nested range up to the file root (that washed the whole screen).
    local cur = chain[1]
    overlay.range(buf, cur.srow, cur.scol, cur.erow, cur.ecol, "LvimJumpTsRange1", 0)
    for _, r in ipairs(chain) do
        overlay.label_at(buf, r.srow, r.scol, r.label)
    end
    vim.cmd("redraw")
end

--- Run the treesitter select. PHASE 1 — label the ancestor ladder (dim + labels), read one key: a
--- LABEL selects that node, `<CR>` the innermost; a non-label key cancels. PHASE 2 — once a node is
--- selected, stay in an INCREMENTAL loop over the visual selection: `keys.next` (<Tab>) EXPANDS to the
--- parent, `keys.prev` (<S-Tab>) SHRINKS to the child, `<Esc>` keeps the current selection, and ANY
--- OTHER key exits AND is replayed so it operates on the selection (`d`/`y`/`c` … act on the range).
---@return nil
function M.select()
    if not config.ts.enabled then
        return
    end
    local buf = api.nvim_get_current_buf()
    local chain = ancestor_ranges(buf)
    if #chain == 0 then
        vim.notify("no treesitter parser for this buffer", vim.log.levels.WARN, { title = "lvim-jump" })
        return
    end
    local win = api.nvim_get_current_win()
    overlay.dim_on({ win })
    local accept = api.nvim_replace_termcodes(config.keys.accept or "<CR>", true, true, true)
    local expand = api.nvim_replace_termcodes(config.keys.next or "<Tab>", true, true, true)
    local shrink = api.nvim_replace_termcodes(config.keys.prev or "<S-Tab>", true, true, true)
    local ok, err = pcall(function()
        -- PHASE 1: pick the starting node from the labeled ladder
        draw(buf, chain)
        local ok_ch, ch = pcall(fn.getcharstr)
        overlay.clear()
        overlay.dim_off()
        vim.cmd("redraw")
        if not ok_ch or ch == nil or ch == "" or ch == ESC then
            return
        end
        local idx
        if ch == accept then
            idx = 1
        else
            for i, r in ipairs(chain) do
                if r.label == ch then
                    idx = i
                    break
                end
            end
        end
        if not idx then
            return -- a non-label key: cancel without selecting
        end
        select_range(buf, chain[idx])
        -- PHASE 2: incremental expand / shrink over the live visual selection
        while true do
            vim.cmd("redraw")
            local ok2, ch2 = pcall(fn.getcharstr)
            if not ok2 or ch2 == nil or ch2 == "" or ch2 == ESC then
                return -- keep the current selection
            end
            if ch2 == expand then
                idx = math.min(idx + 1, #chain)
                select_range(buf, chain[idx])
            elseif ch2 == shrink then
                idx = math.max(idx - 1, 1)
                select_range(buf, chain[idx])
            else
                -- leave the incremental loop and replay the key so it acts ON the selection
                api.nvim_feedkeys(ch2, "t", false)
                return
            end
        end
    end)
    -- teardown is inside the pcall'd body for the normal paths; repeat it here so an error
    -- can't leave the window dimmed
    overlay.clear()
    overlay.dim_off()
    if not ok then
        vim.cmd("redraw")
        vim.notify(tostring(err), vim.log.levels.ERROR, { title = "lvim-jump" })
    end
end

return M
