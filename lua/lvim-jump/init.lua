-- lvim-jump: label-based motion for Neovim, built on the lvim-tech ecosystem. Type a few
-- characters of where you want to go — every match is live-highlighted, single-key labels
-- overlay the matches, one label press lands you there. Plus multi-line f/F/t/T with target
-- highlights, labeled treesitter node selection, and the remote operator-pending jump.
--
-- No windows, no pickers: the whole UI is extmark overlays over the real buffers plus a
-- modal getcharstr loop (the lvim-keys-helper pattern) — the jump IS the buffer, so there is
-- nothing to float. Highlights self-theme from the lvim-utils palette; the searched windows
-- dim through lvim-utils.dim for the modal duration.
--
-- Everything is live-switchable (config is read per jump): the default maps, the char
-- motions and each sub-feature can be toggled at runtime (see :LvimJump / the API).
--
---@module "lvim-jump"

local char = require("lvim-jump.char")
local config = require("lvim-jump.config")
local engine = require("lvim-jump.engine")
local highlights = require("lvim-jump.highlights")
local remote = require("lvim-jump.remote")
local ts = require("lvim-jump.ts")

local ok_utils, utils = pcall(require, "lvim-utils.utils")

local M = {}

---@type boolean one-time registration (maps, command) done
local registered = false

--- Start a jump (normal/visual/operator-pending — the mode is detected live). Returns the
--- match landed on, nil when cancelled.
---@param opts? { multi_window?: boolean }
---@return LvimJumpMatch|nil
function M.jump(opts)
    return engine.run(opts)
end

--- Start the labeled treesitter node selection (normal/visual).
---@return nil
function M.ts()
    ts.select()
end

--- The remote operator-pending jump (call from an o-mode mapping).
---@return nil
function M.remote()
    remote.run()
end

--- Enable the enhanced f/F/t/T/;/, maps.
---@return nil
function M.char_enable()
    config.char_motions.enabled = true
    char.attach()
end

--- Disable them (native f/F/t/T/;/, again).
---@return nil
function M.char_disable()
    config.char_motions.enabled = false
    char.detach()
end

--- Toggle the enhanced char motions; returns the new state.
---@return boolean
function M.char_toggle()
    if char.is_attached() then
        M.char_disable()
    else
        M.char_enable()
    end
    return char.is_attached()
end

--- Install the <Plug> seams plus the configured default maps. <Plug> always exists (a user
--- with `mappings.* = false` maps those); the defaults follow config.mappings.
---@return nil
local function register_maps()
    vim.keymap.set({ "n", "x", "o" }, "<Plug>(lvim-jump)", function()
        M.jump()
    end, { desc = "lvim-jump: jump" })
    vim.keymap.set({ "n", "x" }, "<Plug>(lvim-jump-ts)", function()
        M.ts()
    end, { desc = "lvim-jump: treesitter select" })
    vim.keymap.set("o", "<Plug>(lvim-jump-remote)", function()
        M.remote()
    end, { desc = "lvim-jump: remote operator jump" })
    local maps = config.mappings or {}
    if type(maps.jump) == "string" then
        vim.keymap.set({ "n", "x", "o" }, maps.jump, "<Plug>(lvim-jump)", { desc = "lvim-jump: jump" })
    end
    if type(maps.ts) == "string" and config.ts.enabled then
        vim.keymap.set({ "n", "x" }, maps.ts, "<Plug>(lvim-jump-ts)", { desc = "lvim-jump: treesitter select" })
    end
    if type(maps.remote) == "string" and config.remote.enabled then
        vim.keymap.set("o", maps.remote, "<Plug>(lvim-jump-remote)", { desc = "lvim-jump: remote operator jump" })
    end
end

--- Register the :LvimJump command (once).
---@return nil
local function register_command()
    vim.api.nvim_create_user_command("LvimJump", function(cmd)
        local sub = cmd.fargs[1]
        if sub == "jump" then
            M.jump()
        elseif sub == "ts" then
            M.ts()
        elseif sub == "char" then
            vim.notify("lvim-jump char motions: " .. (M.char_toggle() and "enabled" or "disabled"))
        else
            vim.notify(
                ("lvim-jump: labels=%d  multi_window=%s  smart_case=%s  char_motions=%s  ts=%s  remote=%s"):format(
                    #config.labels,
                    tostring(config.multi_window),
                    tostring(config.smart_case),
                    tostring(char.is_attached()),
                    tostring(config.ts.enabled),
                    tostring(config.remote.enabled)
                )
            )
        end
    end, {
        nargs = "?",
        complete = function(arg)
            return vim.tbl_filter(function(c)
                return arg == "" or c:find(arg, 1, true) == 1
            end, { "jump", "ts", "char", "status" })
        end,
        desc = "lvim-jump: jump / ts / char (toggle motions) / status",
    })
end

--- Configure and start the plugin. Idempotent — calling again re-merges the config and
--- re-syncs the char-motion maps (the <Plug>/default maps and the command register once).
---@param opts? LvimJumpConfig
---@return nil
function M.setup(opts)
    if ok_utils and utils.merge then
        utils.merge(config, opts or {})
    elseif opts then
        -- degraded merge without lvim-utils (nested tables force-extended in place)
        local merged = vim.tbl_deep_extend("force", config, opts)
        for k, v in pairs(merged) do
            config[k] = v
        end
    end
    highlights.setup()
    if config.char_motions.enabled then
        char.attach()
    else
        char.detach()
    end
    if registered then
        return
    end
    registered = true
    register_maps()
    register_command()
end

return M
