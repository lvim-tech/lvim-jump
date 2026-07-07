-- lvim-jump.remote: the remote operator-pending jump — `y r <jump-to-target> iw` yanks a
-- word SOMEWHERE ELSE without the cursor (visibly) leaving home. Deep magic, in three acts,
-- because an operator's motion cannot be "go somewhere and keep operating" natively:
--
--   1. CAPTURE + ABORT — inside the o-mode map the pending operator's state is still
--      readable (v:operator, v:register, v:count, and the forced-motion submode from
--      mode(1) — "nov"/"noV"/"no^V" carry the |o_v|/|o_V| force). The operator is then
--      aborted with a fed <Esc>: it cannot be left pending across the modal jump (it would
--      swallow the jump's own cursor motion as its motion).
--   2. JUMP — scheduled (so the abort drains first), a plain normal-mode engine.run(),
--      multi-window: the whole point is reaching another window/position.
--   3. RE-ISSUE + RESTORE — at the target the captured operator is re-fed NATIVELY
--      (register + count + operator + force), which puts Vim back into operator-pending
--      right there; the user types the text object / motion LIVE ("iw"), exactly as they
--      would have. A one-shot ModeChanged *:n autocmd restores the origin window + view
--      once the editor is back in plain normal mode. *:n is the precise completion seam:
--      feeding the operator goes n→no (no *:n), a motion completes no→n (fires), a `c`
--      change goes no→i and fires only on the later i→n (InsertLeave) — so the restore
--      never yanks the cursor home while the user is still typing the change at the target.
--      An <Esc> that cancels the re-issued operator also lands on no→n: cancel restores
--      home too, which is the right reading of "nothing happened".
--
-- Known shape of the trade: the TARGET window keeps the cursor/scroll position the
-- operation left behind (only the ORIGIN view is restored) — restoring a foreign window's
-- view would fight whatever the operator legitimately did there (e.g. `c` insertions).
--
---@module "lvim-jump.remote"

local config = require("lvim-jump.config")
local engine = require("lvim-jump.engine")

local api = vim.api
local fn = vim.fn

local M = {}

local ESC = "\27"

--- Vim's default register under the current 'clipboard' setting — a captured v:register
--- equal to it was not explicitly typed, so it is not re-issued (same rule as
--- lvim-keys-helper's replay).
---@return string
local function default_register()
    local cb = vim.o.clipboard
    return (cb:find("unnamedplus") and "+") or (cb:find("unnamed") and "*") or '"'
end

--- Run the remote jump. Only meaningful while an operator is pending (this is what the
--- o-mode map calls); a stray normal-mode call is a no-op with a hint.
---@return nil
function M.run()
    if not config.remote.enabled then
        return
    end
    local mode = fn.mode(1)
    if mode:sub(1, 2) ~= "no" then
        vim.notify("remote jump is an operator-pending motion (e.g. yr<label>iw)", vim.log.levels.WARN, {
            title = "lvim-jump",
        })
        return
    end
    -- act 1: capture, then abort the pending operator
    local op = vim.v.operator
    if op == nil or op == "" then
        return
    end
    local reg = vim.v.register
    local count = vim.v.count
    local forced = mode:sub(3) -- "" | "v" | "V" | "\22" — the |forced-motion| submode
    local origin_win = api.nvim_get_current_win()
    local view = fn.winsaveview()
    api.nvim_feedkeys(ESC, "n", false)
    -- act 2 + 3, scheduled so the <Esc> abort has fully drained and mode is plain normal
    vim.schedule(function()
        if not engine.run({}) then
            return -- jump cancelled: the abort already left everything untouched
        end
        -- one-shot restore, armed BEFORE the operator is re-fed (see module header for why
        -- *:n is exactly the completion seam)
        api.nvim_create_autocmd("ModeChanged", {
            pattern = "*:n",
            once = true,
            callback = function()
                -- schedule: ModeChanged fires inside the mode switch; moving windows there
                -- is restricted. By the time this runs the operator has fully completed.
                vim.schedule(function()
                    if api.nvim_win_is_valid(origin_win) then
                        api.nvim_set_current_win(origin_win)
                        fn.winrestview(view)
                    end
                end)
            end,
        })
        local seq = ""
        if reg ~= "" and reg ~= default_register() then
            seq = '"' .. reg
        end
        if count > 0 then
            seq = seq .. count
        end
        seq = seq .. op .. forced
        -- native, no remap: the OPERATOR itself must be the real one; the text object the
        -- user types next arrives from real typeahead and resolves through mappings normally
        api.nvim_feedkeys(seq, "n", false)
    end)
end

return M
