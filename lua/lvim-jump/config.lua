-- lvim-jump: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it in place (lvim-utils.utils.merge),
-- so every require("lvim-jump.config") reader sees the effective values. Runtime match/label
-- state lives in the engine, never here — this table is pure configuration and everything in
-- it may be flipped live (the next jump reads the current values).
--
---@module "lvim-jump.config"

---@class LvimJumpJumpConfig
---@field autojump_single boolean  Jump immediately when narrowing leaves exactly one match
---@field offset          integer  Column offset applied to the landing position (clamped to the line)
---@field inclusive       boolean  Operator-pending only: force the motion inclusive (|o_v|); false = native exclusive

---@class LvimJumpKeysConfig
---@field accept string  Jump to the current (nearest) match
---@field next   string  Cycle the current match forward
---@field prev   string  Cycle the current match backward
---@field back   string  Delete the last pattern character

---@class LvimJumpCharConfig
---@field enabled       boolean  Replace f/F/t/T (and ;/,) with the multi-line, labeled versions
---@field label_exclude string   Keys never used as char-motion labels, so they keep their native meaning right after a motion

---@class LvimJumpTsConfig
---@field enabled boolean  Enable the labeled treesitter node selection (needs a parser for the buffer)

---@class LvimJumpRemoteConfig
---@field enabled boolean  Enable the remote operator-pending jump (run the operator at the target)

---@class LvimJumpDimConfig
---@field enabled boolean  Dim the searched windows while a jump/select is active (lvim-utils.dim)
---@field amount  number   Fraction the foregrounds are muted toward the background (0..1)

---@class LvimJumpMappingsConfig
---@field jump   string|false  Key that starts jump mode in n/x/o (false = no default mapping)
---@field ts     string|false  Key that starts treesitter select in n/x (false = no default mapping)
---@field remote string|false  Operator-pending key for the remote jump (false = no default mapping)

---@class LvimJumpPromptConfig
---@field enabled boolean  Echo the typed pattern + match count in the command line while jumping
---@field icon    string   Pointer glyph shown before the pattern

---@class LvimJumpConfig
---@field labels       string                  Label alphabet, nearest match first; keep it lowercase and duplicate-free
---@field multi_window boolean                 Search every non-floating window of the tabpage (normal mode only)
---@field smart_case   boolean                 Lowercase pattern = case-insensitive; any uppercase char = exact
---@field jump         LvimJumpJumpConfig      Landing behaviour
---@field keys         LvimJumpKeysConfig      Control keys inside the jump loop (vim notation)
---@field char_motions LvimJumpCharConfig      Enhanced f/F/t/T
---@field ts           LvimJumpTsConfig        Treesitter node selection
---@field remote       LvimJumpRemoteConfig    Remote operator-pending jump
---@field dim          LvimJumpDimConfig       Backdrop dimming
---@field mappings     LvimJumpMappingsConfig  Default keymaps installed by setup()
---@field prompt       LvimJumpPromptConfig    Command-line pattern prompt

---@type LvimJumpConfig
return {
    -- Label alphabet in assignment order (nearest match gets the first char). Characters that
    -- could CONTINUE the typed pattern are skipped per keystroke, so a label press is never
    -- ambiguous with searching — keep the alphabet lowercase (uppercase typed chars always
    -- extend the pattern and flip smart_case to exact).
    labels = "asdfghjklqwertyuiopzxcvbnm",
    multi_window = true,
    smart_case = true,
    jump = {
        autojump_single = true,
        offset = 0,
        -- Operator-pending motions are exclusive by nature (the target char is not part of the
        -- operated region, like native `/`). true forces them inclusive via |o_v|.
        inclusive = false,
    },
    -- Control keys inside the jump loop (vim notation). Any other special key is ignored;
    -- <Esc> always cancels.
    keys = {
        accept = "<CR>",
        next = "<Tab>",
        prev = "<S-Tab>",
        back = "<BS>",
    },
    char_motions = {
        enabled = true,
        -- Keys never used as char-motion labels: pressing one right after `f{char}` keeps
        -- its native meaning — it lands on the nearest occurrence and replays, so `fxdw`
        -- flows like native vim. Operators and immediate edit/movement keys by default;
        -- the motion/repeat keys themselves (f/t/F/T/;/,) are always excluded on top.
        label_exclude = "hjkliardc",
    },
    ts = {
        enabled = true,
    },
    remote = {
        enabled = true,
    },
    dim = {
        enabled = true,
        amount = 0.45,
    },
    -- Default keymaps installed by setup(); set any to false and map the <Plug> keys (or the
    -- Lua API) yourself. jump → n/x/o, ts → n/x, remote → o.
    mappings = {
        jump = "s",
        ts = "S",
        remote = "r",
    },
    prompt = {
        enabled = true,
        icon = "➤", -- the canonical lvim-tech pointer
    },
}
