# pi-herdr Roadmap

Features that are out of scope for the current minimal implementation but may be added later.

## Editor experience

- [ ] LSP-style completions inside the prompt float (e.g. placeholder names, recent prompts)
- [ ] Prompt history with up/down navigation
- [ ] Multi-line prompt input

## Context placeholders

- [ ] `@buffers` — all open buffers
- [ ] `@marks` — global marks
- [ ] `@quickfix` — quickfix list entries
- [ ] `@visible` — visible text in the current window

## Pi agent integration

- [ ] Subscribe to Pi server/agent events and expose them as Neovim `User` autocmds
- [ ] Accept/reject diff UI for agent-suggested edits
- [ ] Permission prompts before destructive agent actions
- [ ] Statusline component showing connected agent state
