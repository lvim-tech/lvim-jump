-- lvim-jump: :checkhealth lvim-jump.
-- Diagnoses what makes a LABEL MOTION misbehave invisibly: a rival motion plugin holding the
-- same keys (double handling of s/f), a label alphabet that is internally broken (duplicates
-- silently shrink the label pool), the dim backdrop's lvim-utils seam, and — for the
-- treesitter select — whether the current buffer actually has a parser (provisioned by
-- lvim-ts in the lvim-tech stack). Read-only reporting; never mutates config or state.
--
---@module "lvim-jump.health"

local config = require("lvim-jump.config")

local M = {}

-- Rival label/char motion plugins: if one is live it competes for the same s/f/t keys and
-- both fire on the same keystrokes. Keyed by require name.
---@type table<string, string>
local RIVALS = {
    ["flash"] = "flash.nvim",
    ["leap"] = "leap.nvim",
    ["hop"] = "hop.nvim",
}

--- Warn on any rival motion plugin that is loaded (or merely installed) alongside us.
---@param health table  the vim.health reporter
---@return nil
local function check_rivals(health)
    for mod, label in pairs(RIVALS) do
        if package.loaded[mod] then
            health.warn(("%s is loaded — both claim the jump/char keys; disable one"):format(label))
        elseif #vim.api.nvim_get_runtime_file("lua/" .. mod .. "/", false) > 0 then
            health.info(("%s is installed but not loaded — keep it off to avoid key conflicts"):format(label))
        end
    end
end

--- Validate the live config; error/warn per violation, ok when clean.
---@param health table  the vim.health reporter
---@return nil
local function check_config(health)
    local problems = 0
    if type(config.labels) ~= "string" or #config.labels < 2 then
        health.error(("labels must be a string of at least 2 characters (got %s)"):format(vim.inspect(config.labels)))
        problems = problems + 1
    else
        local seen = {}
        for ch in config.labels:gmatch(".") do
            if seen[ch] then
                health.error(("labels contains %q twice — duplicates shrink the label pool"):format(ch))
                problems = problems + 1
            end
            seen[ch] = true
        end
        if config.labels ~= config.labels:lower() then
            health.warn(
                "labels contains uppercase characters — uppercase typed chars always extend the pattern, so those labels are unreachable"
            )
        end
    end
    local amount = config.dim and config.dim.amount
    if type(amount) ~= "number" or amount < 0 or amount > 1 then
        health.error(("dim.amount must be a number in 0..1 (got %s)"):format(vim.inspect(amount)))
        problems = problems + 1
    end
    local exclude = config.char_motions and config.char_motions.label_exclude
    if type(exclude) ~= "string" then
        health.error(("char_motions.label_exclude must be a string of keys (got %s)"):format(vim.inspect(exclude)))
        problems = problems + 1
    end
    for _, name in ipairs({ "jump", "ts", "remote" }) do
        local m = (config.mappings or {})[name]
        if m ~= false and type(m) ~= "string" then
            health.error(("mappings.%s must be a key string or false (got %s)"):format(name, vim.inspect(m)))
            problems = problems + 1
        end
    end
    if problems == 0 then
        health.ok("config valid")
    end
end

--- Run the health report.
---@return nil
function M.check()
    local health = vim.health
    health.start("lvim-jump")

    if vim.fn.has("nvim-0.12") == 1 then
        health.ok("Neovim >= 0.12")
    else
        health.error("Neovim >= 0.12 is required (the lvim-tech set targets 0.12; lvim-utils requires it)")
    end

    local ok_utils = pcall(require, "lvim-utils.utils")
    local ok_colors, colors = pcall(require, "lvim-utils.colors")
    local ok_dim = pcall(require, "lvim-utils.dim")
    if ok_utils and ok_colors and type(colors.blend) == "function" and ok_dim then
        health.ok("lvim-utils found (palette + merge + dim backdrop)")
    else
        health.warn("lvim-utils not found — plain highlight links, no dim backdrop, tbl_deep_extend merge")
    end

    check_rivals(health)

    -- treesitter select: native vim.treesitter drives it; lvim-ts is the parser provisioner
    if config.ts.enabled then
        local ok_ts = pcall(require, "lvim-ts")
        if ok_ts then
            health.ok("lvim-ts found (treesitter parsers provisioned)")
        else
            health.info("lvim-ts not found — treesitter select still works for any buffer with an attached parser")
        end
        local ok_parser = pcall(vim.treesitter.get_parser, 0)
        if ok_parser then
            health.ok("current buffer has a treesitter parser")
        else
            health.info("current buffer has no treesitter parser — treesitter select is unavailable here")
        end
    else
        health.info("treesitter select disabled (ts.enabled = false)")
    end

    local char = require("lvim-jump.char")
    health.info(
        ("mappings: jump=%s  ts=%s  remote=%s  char_motions=%s"):format(
            tostring(config.mappings.jump),
            tostring(config.mappings.ts),
            tostring(config.mappings.remote),
            char.is_attached() and "attached (f F t T ; ,)" or "detached"
        )
    )

    check_config(health)
end

return M
