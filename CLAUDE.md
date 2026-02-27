# Neovim Configuration

## Structure

```
init.lua                    → Entry point, requires controller/
lua/controller/
  init.lua                  → Loads all modules
  lazy.lua                  → lazy.nvim plugin manager bootstrap + plugin list
  colors.lua                → Rose Pine (moon variant) theme
  keybinds.lua              → All keybindings (leader = <space>)
  formatter.lua             → formatter.nvim setup + format-on-save
  metals.lua                → Scala/Java LSP (nvim-metals) + DAP + completion
```

## Plugins (managed by lazy.nvim)

- **rose-pine/neovim** — Theme (moon variant)
- **nvim-lua/plenary.nvim** — Core utility lib
- **hrsh7th/nvim-cmp** + cmp-nvim-lsp + cmp-vsnip + vim-vsnip — Completion + snippets
- **mhartington/formatter.nvim** — Format-on-save for multiple languages
- **nvim-telescope/telescope.nvim** (0.1.8) — Fuzzy finder
- **folke/persistence.nvim** — Session management
- **scalameta/nvim-metals** + fidget.nvim + nvim-dap — Scala/Java LSP & debug

## Key Bindings (leader = space)

| Key | Action |
|-----|--------|
| `<leader>pv` | File explorer (netrw) |
| `<leader>pf` | Telescope find files |
| `<leader>pq` | Telescope git files |
| `<leader>ps` | Telescope grep string |
| `<leader>fp` | Copy file path to clipboard |
| `<leader>qs` / `<leader>ql` | Load last session |
| `<leader>qS` | Select session |
| `<leader>qd` | Stop session tracking |
| `gd` / `gD` / `K` / `<leader>rn` | LSP: definition / declaration / hover / rename |

## Formatting (format-on-save via BufWritePost)

| Filetype | Formatter |
|----------|-----------|
| lua | stylua |
| python | black (via uv → hatch → system fallback) |
| json | jq |
| javascript | js-beautify |
| typescriptreact | prettier (npx) |
| shell | shfmt |
| * | trailing whitespace removal |

The `black_or_hatch()` function in `formatter.lua` picks the best available Python formatter: prefers `uv run black`, falls back to `hatch run dev:black`, then plain `black`.

## LSP

Only Scala/Java via nvim-metals. No general LSP config for other languages. Metals auto-attaches on `scala`, `sbt`, `java` filetypes. Root detection uses `build.sbt`.

## Conventions

- Indentation: 2 spaces (init.lua sets tabstop/shiftwidth), formatter defaults to 4
- All config is modular under `lua/controller/`
- Lean setup — no unnecessary plugins or abstractions
