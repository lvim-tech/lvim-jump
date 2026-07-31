-- lvim-jump.highlights: self-theming from the lvim-utils palette. All groups are derived
-- from the LIVE palette via lvim-utils.highlight.bind, so they re-derive on every palette
-- sync / ColorScheme — the canonical lvim-tech mechanism. Tint canon: each coloured cell is
-- its own accent mtint-ed toward the editor bg (blend(accent, bg, t)); the label is the
-- strong hover_active-style block (0.3, bold), match bodies the lighter body tint (0.2).
--
-- The groups are also registered with lvim-utils.dim.preserve: the jump backdrop copies
-- every global group MUTED into its namespace, and without the preserve our own labels and
-- match tints would be dimmed along with the text they must stand out from.
--
---@module "lvim-jump.highlights"

local ok_hl, hl = pcall(require, "lvim-utils.highlight")
local ok_dim, dim = pcall(require, "lvim-utils.dim")

local M = {}

---@type boolean one-time bind guard (setup() is idempotent)
local bound = false

--- Register the highlight groups. With lvim-utils present they are a bound palette
--- factory (re-derived on theme change); without it, plain default links so the plugin
--- still renders.
---@return nil
function M.setup()
    if bound then
        return
    end
    bound = true
    if ok_dim then
        -- keep every LvimJump* group crisp inside the dim backdrop namespace (see module header)
        dim.preserve("^LvimJump", { data = true }) -- the labels are what you aim at; a veil must never mute them
    end
    if not ok_hl then
        local links = {
            LvimJumpMatch = "Search",
            LvimJumpCurrent = "CurSearch",
            LvimJumpLabel = "IncSearch",
            LvimJumpPrompt = "Normal",
            LvimJumpPromptIcon = "Special",
            LvimJumpPromptCount = "Comment",
        }
        links["LvimJumpTsRange1"] = "Visual"
        for name, target in pairs(links) do
            vim.api.nvim_set_hl(0, name, { link = target, default = true })
        end
        return
    end
    hl.bind(function(c)
        c = c or require("lvim-utils.colors")
        --- accent mtint toward the live bg — the shared lvim-tech tint formula
        ---@param col string
        ---@param t number
        ---@return string
        local function mtint(col, t)
            return hl.blend(col, c.bg, t)
        end
        local groups = {
            -- match body: blue body tint; the cycle-selected match: yellow, one step stronger
            LvimJumpMatch = { fg = c.blue, bg = mtint(c.blue, 0.2) },
            LvimJumpCurrent = { fg = c.yellow, bg = mtint(c.yellow, 0.3), bold = true },
            -- the label block: magenta hover_active-style strong tint, bold
            LvimJumpLabel = { fg = c.magenta, bg = mtint(c.magenta, 0.3), bold = true },
            LvimJumpPrompt = { fg = c.fg_light },
            LvimJumpPromptIcon = { fg = c.blue, bold = true },
            LvimJumpPromptCount = { fg = c.comment },
        }
        -- ts-select tints ONLY the current (innermost) node span (see ts.draw); one blue tint, no depth ladder
        groups.LvimJumpTsRange1 = { bg = mtint(c.blue, 0.25) }
        return groups
    end)
end

return M
