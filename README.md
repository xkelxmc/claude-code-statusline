# Claude Code Custom Status Line

A 3-line bash status line for Claude Code with dynamic sections — if there's no data, the block is hidden.

## Layout

```
Line 1: 📁 ~/repos/project | ⬢ v22.0.0 | 📦 bun | ✓ main | 📔 42 notes
Line 2: 🤖 Opus 4.5 | 🔑 7a020cd0-edd7-4094-9e6c-0b2a5a233beb | 📝 +45 -12
Line 3: 🧠 36% ▰▰▰▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱▱▱ | 💰 $1.20 | ⏱ 12m (4m api) | 📊 25k tpm | ⏳ 2h 15m → 01:00
```

### Line 1: Environment
| Section | Description |
|---------|-------------|
| 📁 Path | Current directory (gray parent / white current) |
| ⬢ Node | Node.js version |
| 📦 Package | Package manager (npm/yarn/pnpm/bun) |
| ✓/✗ Git | Branch, file count, insertions/deletions |
| 📔 Notes | Note count (Obsidian vaults only) |

### Line 2: Session
| Section | Description |
|---------|-------------|
| 🤖 Model | Current model (Opus 4.5, Sonnet, etc.) |
| 🔑 Session | Full session ID |
| 📝 Lines | Lines added/removed by Claude this session |

### Line 3: Metrics
| Section | Description |
|---------|-------------|
| 🧠 Context | Usage % with colored progress bar |
| 💰 Cost | Session cost in USD |
| ⏱ Time | Total duration (API time) |
| 📊 TPM | Tokens per minute (session average) |
| ⏳ Reset | Time until subscription reset (via ccusage) |

## Features

- **Colored progress bar** for context usage (gray → white → yellow → orange → red)
- **Git uses `project_dir`** — works correctly when navigating subdirectories
- **API time tracking** — shows both total and pure API duration
- **Claude's contributions** — tracks lines added/removed by Claude
- **TPM (tokens per minute)** — calculated from session data
- **Subscription reset countdown** — async integration with ccusage (non-blocking, cached)

## Installation

1. Copy `statusline.sh` to `~/.claude/statusline.sh`
2. Make it executable:
   ```bash
   chmod +x ~/.claude/statusline.sh
   ```
3. Add to `~/.claude/settings.json`:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline.sh"
     }
   }
   ```
4. Restart Claude Code

## Configuration

### Hide Cost (for Max plan users)

```bash
export CLAUDE_STATUSLINE_HIDE_COST=1
```

Add to `~/.bashrc` or `~/.zshrc`, then restart terminal.

## Dependencies

- `jq` — for JSON parsing (`brew install jq` or `apt install jq`)
- `bc` — for calculations (usually pre-installed)
- `ccusage` (optional) — for reset time tracking (`npm install -g ccusage` or auto-fetched via `npx`)

## License

MIT
