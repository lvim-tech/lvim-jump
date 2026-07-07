# lvim-jump

Label-based motion for Neovim, built on the lvim-tech ecosystem (uses `lvim-utils` for
its palette / merge / dim backdrop). Type a few characters of where you want to go —
every match is live-highlighted across the visible windows, single-key **labels** overlay
the matches, and one label press lands you there.

- **Jump mode** (`s` by default, normal / visual / operator-pending) — a modal search:
  each typed character narrows the matches live; labels appear on the character *after*
  each match. Label characters are chosen so they can never continue the search
  (non-ambiguous), and a match that survives narrowing keeps its label (stable — labels
  never shuffle while you type). The searched windows dim for the duration; a jump pushes
  a jumplist entry (`<C-o>` returns).
- **Multi-window** — in normal mode every non-floating window of the tabpage is searched
  and labeled; a label press switches windows and lands. Visual and operator-pending
  jumps stay in the current window (a motion cannot cross windows).
- **Enhanced `f`/`F`/`t`/`T`** — multi-line and label-first: the motion shows only the
  occurrences in its **own direction** (`f`/`t` forward, `F`/`T` backward) within the
  visible range, **all labeled** (the nearest included, highlighted as the current
  target), and the cursor stays put until you pick. A label lands there; the motion key
  or `;` steps to the next occurrence, `,` steps back; any other key lands on the
  nearest and is replayed — so `fx` then `dw` deletes from the first `x` exactly like
  native vim. A count (`3fx`) or an active macro takes the direct native jump, no
  labels. Case-exact like the native motions.
- **Treesitter select** (`S` by default, normal / visual) — the syntax-node ancestor
  ladder at the cursor is tinted (innermost strongest) and labeled; pressing a label
  visually selects that node's exact range. `<CR>` selects the innermost node. Works with
  any buffer that has a treesitter parser (provisioned by `lvim-ts` in the lvim-tech
  stack).
- **Remote operator jump** (`r` in operator-pending) — `yr<jump>iw` yanks a word
  *somewhere else*: the pending operator is captured, a full jump runs (multi-window),
  the operator is re-issued at the target where you type the text object live, and the
  origin window / view is restored once the operation completes.

There are no popups and no pickers: the entire UI is extmark overlays over the real
buffers plus a modal key loop — the jump *is* the buffer. All highlights self-theme from
the `lvim-utils` palette and re-derive on every colorscheme / palette change.

[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](https://github.com/lvim-tech/lvim-jump/blob/main/LICENSE)

## Installation

Requires Neovim >= 0.10 and [lvim-utils](https://github.com/lvim-tech/lvim-utils)
(palette / merge / dim helpers). The treesitter select works with any attached parser;
in the lvim-tech stack parsers are provisioned by
[lvim-ts](https://github.com/lvim-tech/lvim-ts).

### lvim-installer (recommended)

Install and manage it from the LVIM package manager — open the **Plugins** tab and
install / update / pin it:

```vim
:LvimInstaller plugins
```

lvim-installer installs plugins through Neovim's built-in `vim.pack`, so no external
plugin manager is needed.

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-jump" },
})
require("lvim-jump").setup({})
```

## Setup

The full default configuration — every option at its default value:

```lua
require("lvim-jump").setup({
    -- Label alphabet in assignment order (nearest match gets the first char). Keep it
    -- lowercase and duplicate-free: characters that could continue the typed pattern
    -- are excluded per keystroke, so a label press is never ambiguous with searching.
    labels = "asdfghjklqwertyuiopzxcvbnm",
    multi_window = true, -- search every non-floating window (normal mode only)
    smart_case = true, -- lowercase pattern = ignore case; any uppercase char = exact
    jump = {
        autojump_single = true, -- jump immediately when narrowing leaves ONE match
        offset = 0, -- column offset applied to the landing position (clamped)
        -- Operator-pending: false = native exclusive motion (the target char is not
        -- part of the operated region); true forces it inclusive via |o_v|.
        inclusive = false,
    },
    -- Control keys inside the jump loop (vim notation). <Esc> always cancels.
    keys = {
        accept = "<CR>", -- jump to the current (nearest) match
        next = "<Tab>", -- cycle the current match forward
        prev = "<S-Tab>", -- cycle backward
        back = "<BS>", -- delete the last pattern character
    },
    char_motions = {
        enabled = true, -- replace f/F/t/T (and ;/,) with the multi-line, labeled versions
        -- Keys never used as char-motion labels: pressing one right after `f{char}`
        -- keeps its native meaning (lands on the nearest occurrence and replays the
        -- key, so `fxdw` flows like native vim). The motion/repeat keys themselves
        -- (f/t/F/T/;/,) are always excluded on top of this.
        label_exclude = "hjkliardc",
    },
    ts = {
        enabled = true, -- labeled treesitter node selection
    },
    remote = {
        enabled = true, -- remote operator-pending jump
    },
    dim = {
        enabled = true, -- dim the searched windows while a jump/select is active
        amount = 0.45, -- fraction the foregrounds are muted toward the background
    },
    -- Default keymaps installed by setup(); set any to false and map the <Plug> keys
    -- (or the Lua API) yourself. jump → n/x/o, ts → n/x, remote → o.
    mappings = {
        jump = "s",
        ts = "S",
        remote = "r",
    },
    prompt = {
        enabled = true, -- echo the typed pattern + match count in the command line
        icon = "➤",
    },
})
```

## Usage

### Jump mode

Press `s` (normal, visual or operator-pending) and start typing. While the loop is
active:

| Key           | Action                                                        |
| ------------- | ------------------------------------------------------------- |
| any character | narrow the search pattern                                     |
| a label       | jump to that match (also across windows)                      |
| `<CR>`        | jump to the current (nearest) match                           |
| `<Tab>` / `<S-Tab>` | cycle which match is current                            |
| `<BS>`        | delete the last pattern character                             |
| `<Esc>`       | cancel (in operator-pending the operator is aborted too)      |

In operator-pending mode the jump is a motion: `d s xy<label>` deletes from the cursor
to the target (exclusive by default; see `jump.inclusive` / `jump.offset`).

### Char motions

`f` / `F` / `t` / `T` read one character and show every in-reach occurrence in the
motion's **own direction** (multi-line, within the visible range) — `f`/`t` only
forward, `F`/`T` only backward — each with a jump label, the nearest included and
highlighted as the current target. The cursor does not move until you decide:

| Key                   | Action                                                       |
| --------------------- | ------------------------------------------------------------ |
| a label               | land on that occurrence                                      |
| `<CR>`                | land on the nearest (the current-highlighted one)            |
| the motion key or `;` | step to the next occurrence (labels follow the cursor)       |
| its upper twin or `,` | step back (reverse of the motion's direction)                |
| `<Esc>`               | cancel in place (the cursor never moved)                     |
| any other key         | land on the nearest and replay it (`fx` then `dw` = native)  |

A count jumps directly with no label prompt (`3fx` = third occurrence, native
semantics — a count past the last occurrence fails the motion), and so do motions
while a macro is being recorded or executed. In operator-pending mode the motion
consumes a single target: pick a label (or the motion key / `<CR>` for the nearest)
and the operator applies through it — `dfx` deletes through the `x` like native;
cancelling aborts the operator. After landing, `;` repeats and `,` reverses from the
new position. Labels never use `char_motions.label_exclude` or the motion/repeat keys,
so those keep their native meaning. Toggle at runtime with `:LvimJump char`.

### Treesitter select

Press `S`: the cursor's syntax-node ancestors are labeled at their start; only the
innermost (current) node is tinted, and the rest is dimmed. A label press — or `<CR>`
for the innermost — visually selects that node. Then INCREMENTAL: `<Tab>` (`keys.next`)
expands the selection to the parent, `<S-Tab>` (`keys.prev`) shrinks it to the child,
`<Esc>` keeps it, and any other key exits and acts on the selection (`d`/`y`/`c` …).

### Remote operator jump

With an operator pending, press `r`, jump anywhere (labels, any window), then type the
text object: `y r un<label> iw` yanks the word at the target and returns home. Works
with any operator (`d`, `c`, `gu`, …); the origin view is restored when the operation
completes (for `c` — after leaving insert mode).

## API

```lua
local jump = require("lvim-jump")

jump.setup(opts) -- merge opts into the live config (idempotent)
jump.jump() -- start a jump (mode detected live); returns the landed match or nil
jump.ts() -- treesitter node selection
jump.remote() -- remote operator jump (call from an o-mode mapping)
jump.char_enable() -- install the enhanced f/F/t/T/;/, maps
jump.char_disable() -- restore the native motions
jump.char_toggle() -- toggle; returns the new state
```

`<Plug>` seams (always defined, for users who set `mappings.* = false`):
`<Plug>(lvim-jump)` (n/x/o), `<Plug>(lvim-jump-ts)` (n/x), `<Plug>(lvim-jump-remote)` (o).

## Command

```
:LvimJump             " status line (labels, features, char-motion state)
:LvimJump jump        " start a jump
:LvimJump ts          " treesitter select
:LvimJump char        " toggle the enhanced char motions
```

## Highlights

All groups are derived from the `lvim-utils` palette and re-derive on theme change;
they are registered with `default = true`, so a colorscheme or the user can override
them.

| Group                                    | Purpose                                            |
| ---------------------------------------- | ------------------------------------------------- |
| `LvimJumpMatch`                          | a match body (blue tint)                           |
| `LvimJumpCurrent`                        | the current / cycle-selected match (yellow tint)   |
| `LvimJumpLabel`                          | the label block (bold magenta tint)                |
| `LvimJumpTsRange1` … `LvimJumpTsRange5`  | ts-select node ranges, fading with depth           |
| `LvimJumpPrompt` / `…Icon` / `…Count`    | the command-line pattern prompt                    |

The dim backdrop is `lvim-utils.dim` (the shared dimming namespace mechanism); the
plugin's own groups are `dim.preserve`-d so labels stay crisp on the dimmed text.

## Health

```vim
:checkhealth lvim-jump
```

Reports the lvim-utils seam, rival motion plugins holding the same keys, treesitter
parser availability for the current buffer, and validates the live config (label
alphabet, dim amount, mappings).
