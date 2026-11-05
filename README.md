# pi-herdr

Minimal Neovim plugin that routes prompts to an already-running [Pi](https://github.com/earendil-works/pi-coding-agent) coding agent managed by [Herdr](https://github.com/ctbaum/herdr).

- Sends compact context only (`file:line` in normal mode, `file:start-end` + selected text in visual mode)
- Enforces **exact canonicalized CWD** matching against `herdr agent list`
- Never starts a new Pi process or terminal
- Floating prompt UI: `Enter` submits, `Esc`/`q` cancels

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
  keymap = "<leader>Oa",     -- normal + visual mode mapping
  focus_after_send = true,   -- focus the Pi agent pane after sending
  herdr_binary = nil,        -- path to herdr binary; defaults to "herdr"
})
```

## Commands

- `:PiAsk` — ask with normal-mode context
- `:PiAskVisual` — ask with visual selection context

## Keybindings

| Key | Mode | Action |
|---|---|---|
| `<leader>Oa` | Normal | Ask Pi about current file/line |
| `<leader>Oa` | Visual | Ask Pi with selection context |
