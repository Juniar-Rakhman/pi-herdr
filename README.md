# pi-herdr

> Lightweight bridge between Neovim and a running Pi coding agent via Herdr.

Minimal Neovim plugin that routes prompts to an already-running [Pi](https://github.com/earendil-works/pi-coding-agent) coding agent managed by [Herdr](https://github.com/ctbaum/herdr).

- Sends compact context only (`@file:line` in normal mode, `@file:start-end` for line-wise visual, `@file:start-end:startcol-endcol` for char/block visual)
- Matches agents by **exact canonicalized CWD** against `herdr agent list`; prompts you to pick when multiple match
- Never starts a new Pi process or terminal
- Minimal floating prompt: `Enter` sends, `Esc`/`q` cancels
- Automatically uses `snacks.input` when available (with π icon), falling back to a custom float

## Requirements

- Neovim 0.10+
- [Herdr](https://github.com/ctbaum/herdr) installed and running a Pi agent in the same directory as Neovim

## Installation

### lazy.nvim

```lua
{
  "Juniar-Rakhman/pi-herdr",
  opts = {},
}
```

## Configuration

```lua
require("pi-herdr").setup({
  keymap = "<leader>pa",         -- normal + visual mode mapping
  buffer_keymap = "<leader>pb",  -- ask about the current buffer only
  focus_after_send = true,       -- focus the Pi agent pane after sending
  submit_after_send = false,     -- false types the prompt in Pi without submitting
  herdr_binary = nil,            -- path to herdr binary; defaults to "herdr"
})
```

## Integrations

### snacks.input

If you have [snacks.nvim](https://github.com/folke/snacks.nvim) installed with `input` enabled, pi-herdr will use it for the prompt UI and show a π icon. Otherwise it falls back to a minimal custom float.

```lua
require("snacks").setup({
  input = { enabled = true },
})
```

## Context placeholders

Type these directly in the floating prompt or in custom prompt templates:

| Placeholder | Expands to |
|---|---|
| `@this` | Current file/line, or selected range (with columns for char/block selections) |
| `@buffer` | Full path of the current buffer |
| `@diagnostics` | Diagnostics for the current buffer or selection |

## Commands

| Command | Usage |
|---|---|
| `:PiAsk` | Ask Pi with normal-mode context |
| `:PiAskVisual` | Ask Pi with visual selection context |
| `:PiAskBuffer` | Ask Pi about the current buffer only |
| `:PiPrompt <text>` | Send a prompt directly, without opening the float |
| `:PiSelect` | Pick a built-in prompt template |

## Keybindings

| Key | Mode | Action |
|---|---|---|
| `<leader>pa` | Normal | Ask Pi about current file/line |
| `<leader>pa` | Visual | Ask Pi with selection context |
| `<leader>pb` | Normal | Ask Pi about the current buffer |

