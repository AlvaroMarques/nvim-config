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
  claudedoc.lua             → Markdown skeleton + Claude-filled sidecar snippets (see below)
bin/claudedoc.py            → CLI behind claudedoc.lua (blocks/render/ask/ask-all/new-id)
```

## Plugins (managed by lazy.nvim)

- **rose-pine/neovim** — Theme (moon variant)
- **nvim-lua/plenary.nvim** — Core utility lib
- **hrsh7th/nvim-cmp** + cmp-nvim-lsp + cmp-vsnip + vim-vsnip — Completion + snippets
- **mhartington/formatter.nvim** — Format-on-save for multiple languages
- **nvim-telescope/telescope.nvim** (0.1.8) — Fuzzy finder
- **folke/persistence.nvim** — Session management
- **scalameta/nvim-metals** + fidget.nvim + nvim-dap — Scala/Java LSP & debug
- **MeanderingProgrammer/render-markdown.nvim** — In-buffer markdown rendering (`ft = markdown`); uses the `markdown`/`markdown_inline` treesitter parsers bundled with Neovim 0.10+, so nvim-treesitter is deliberately not installed. Do not toggle `wrap` per render state: the plugin stops rendering when the view is scrolled sideways, so nowrap-while-rendered flickers on long lines. Uneven wraps around concealed link URLs are a known plugin limitation. `ftplugin/markdown.lua` sets `linebreak` + `breakindent`.

## Key Bindings (leader = space)

| Key | Action |
|-----|--------|
| `<leader>pv` | File explorer (netrw) |
| `<leader>pf` | Telescope find files |
| `<leader>pq` | Telescope git files |
| `<leader>ps` | Telescope grep string |
| `<leader>fp` | Copy file path to clipboard |
| `<leader>md` | Toggle markdown render (render-markdown.nvim) |
| `<leader>qs` / `<leader>ql` | Load last session |
| `<leader>qS` | Select session |
| `<leader>qd` | Stop session tracking |
| `gd` / `gD` / `K` / `<leader>rn` | LSP: definition / declaration / hover / rename |
| `<leader>cl*` (markdown only) | claudedoc, see below |

## claudedoc (markdown skeleton + Claude snippets)

The skeleton `doc.md` is the source of truth and is never written by Claude.
Prompts are tagged blocks; answers go to `doc.snippets/<id>.md` (plus
`<id>.prompt` for cache invalidation and `.session` to resume the same
`claude -p` session); `doc.out.md` is rendered from skeleton + snippets and
opened read-only. Blocks without a snippet render as-is.

```markdown
```claude-command id=foo
multi-line prompt, replaced by the snippet
```
Objective: [claude id=bar] one-line prompt; marker..EOL replaced by the snippet
text [claude id=baz] embedded prompt [/claude] more text   (several per line ok; cursor column picks which)
```

| Key | Action |
|-----|--------|
| `<leader>cl` (n) / (x) | New fenced block with fresh id / wrap selection as prompt |
| `<leader>cli` | New inline `[claude id=]` marker at cursor |
| `<leader>cld` / `clD` | Fill block under cursor: cached unless prompt changed / force |
| `<leader>cla` / `clA` | Fill all missing+stale blocks / force all |
| `<leader>clt` | Toggle skeleton <-> rendered, cursor on the same block |
| `<leader>cls` | Open the snippet of the block under cursor in a vsplit (hand-edit) |
| `<leader>clb` | Quickfix list of blocks with status (missing/stale/cached) |
| `<leader>clr` | Re-render (also automatic on save of skeleton or snippet) |
| `<leader>clL` / `clS` | Link asks to an existing Claude session: fork (interactive session untouched) / shared |
| `<leader>clU` | Unlink session (next ask starts fresh) |
| `<leader>clh` | Help popup with this table |
| `<leader>clw` | Watch the live log of the block under cursor (tool calls, text, cost) in a bottom split |
| `<leader>clq` | Show the per-document queue |
| `<leader>clx` / `clX` | Cancel the running ask / cancel and drop the queue (old snippet is kept) |

Asks stack: one `claude -p` runs at a time per document (they share
`.session`), the rest wait in a Lua-side queue in order. The statusline shows
`⠋ claudedoc:<running> +<queued>` via `v:lua.ClaudeDocStatus()` in `init.lua`,
and `<leader>clb` marks blocks `running` / `queued`. Each ask streams
`--output-format stream-json` into `doc.snippets/<id>.log` (what `clw` tails).
The ask's system prompt ends with "You are a subagent. Don't run memo."

`CLAUDEDOC_FLAGS` (default `--dangerously-skip-permissions`) and
`CLAUDEDOC_MODEL` tune the `claude -p` call. Toggle works from either file via
`doc.snippets/.linemap`, so the rendered file carries no `<!-- claude id -->`
comments (Confluence shows them); `render --markers` adds them if wanted. Linking reads `~/.claude/projects/<cwd-slug>/*.jsonl`;
an interactive session's transcript is flushed per turn, so a fork sees it up to
its last completed turn.

## Formatting (format-on-save via BufWritePost)

| Filetype | Formatter |
|----------|-----------|
| lua | stylua |
| python | black (via uv → hatch → system fallback) |
| json | jq |
| javascript | js-beautify |
| typescriptreact | prettier (npx) |
| shell | shfmt |
| sql | sqlfluff (system → `uv tool run` fallback) |
| * | trailing whitespace removal |

The `black_or_hatch()` function in `formatter.lua` picks the best available Python formatter: prefers `uv run black`, falls back to `hatch run dev:black`, then plain `black`.

The `sqlfluff()` function passes no dialect flag — dialect and rules come from sqlfluff's own config cascade: a project `.sqlfluff` if present, otherwise `~/.sqlfluff` (not in this repo). That global config sets `dialect = databricks` so backtick-quoted identifiers (`` `type` ``), `DECLARE VARIABLE`, `IDENTIFIER()`, and ``delta.`s3://...` `` parse correctly, plus lowercase capitalisation policies. The `ansi` dialect cannot parse backticks and silently leaves the file unformatted.

## LSP

Only Scala/Java via nvim-metals. No general LSP config for other languages. Metals auto-attaches on `scala`, `sbt`, `java` filetypes. Root detection uses `build.sbt`.

## Conventions

- Indentation: 2 spaces (init.lua sets tabstop/shiftwidth), formatter defaults to 4
- All config is modular under `lua/controller/`
- Lean setup — no unnecessary plugins or abstractions
