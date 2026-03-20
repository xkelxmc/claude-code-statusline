# Claude Code Custom Status Line

A 3-line bash status line for Claude Code with dynamic sections — if there's no data, the block is hidden.

## Layout

```
╭──────╮ 🤖 Opus 4.6 | 📁 ~/repos/personal/my-app | ⬢ v22.0.0 | 📦 bun | ✓ main
│ HOME │ c: ●●○○○○○○○○ 18% ⟳ 15:00 | 🔑 7a020cd0-edd7-4094-9e6c-0b2a5a233beb
╰──────╯ w: ●●●○○○○○○○ 34% ⟳ mar 13, 15:00 | 🧠 36% ▰▰▰▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱▱▱ 72.4k | 💰 $1.20
```

### Line 1: Environment
| Section | Description |
|---------|-------------|
| 🤖 Model | Current model (Opus 4.6, Sonnet, etc.) |
| 📁 Path | Current directory (gray parent / colored current) |
| ⬢ Node | Node.js version |
| 📦 Package | Package manager (npm/yarn/pnpm/bun) |
| ✓/✗ Git | Branch, file count, insertions/deletions |
| 📔 Notes | Note count (Obsidian vaults only) |

### Line 2: 5-Hour Usage & Session
| Section | Description |
|---------|-------------|
| c: ●●○○○○○○○○ | 5-hour usage bar with % and reset time |
| 🔑 Session | Full session ID |

### Line 3: Weekly Usage & Metrics
| Section | Description |
|---------|-------------|
| w: ●●●○○○○○○○ | 7-day usage bar with % and reset time |
| 🧠 Context | Usage %, colored progress bar, token count |
| 💰 Cost | Session cost in USD |

## Features

- **Project badges** — configurable colored badges per directory pattern (see below)
- **Native rate limits** — 5-hour and 7-day usage bars from Claude Code's built-in `rate_limits` (v2.1.80+), with automatic fallback to OAuth API for older versions
- **Colored progress bar** for context usage (gray → white → yellow → orange → red)
- **Usage color scale** — gray (<25%) → green (25-49%) → orange (50-69%) → yellow (70-89%) → red (90%+)
- **Git uses `project_dir`** — works correctly when navigating subdirectories
- **Path highlighting** — current directory name colored per badge config
- **Async API fallback** — for Claude Code < 2.1.80, OAuth usage is fetched in background with 5min cache

## Badges

Badges are colored labels shown on the left side of the status line, configured per directory pattern.

### Configuration

Create `~/.claude/statusline-config.json`:

```json
{
  "badges": [
    {
      "pathPattern": "~/repos/personal/*",
      "label": "HOME",
      "color": "#77dd77",
      "pathColor": "#77dd77",
      "border": "round"
    },
    {
      "pathPattern": "~/repos/work/*",
      "label": "WORK",
      "color": "#b388ff",
      "pathColor": "#b388ff",
      "border": "double"
    }
  ]
}
```

### Badge Fields

| Field | Description |
|-------|-------------|
| `pathPattern` | Glob pattern to match `project_dir` (`~` expands to `$HOME`, `*` matches any path) |
| `label` | Text inside the badge (e.g. `ME`, `WORK`, `URNM`) |
| `color` | Badge frame color as hex (`#rrggbb`) |
| `pathColor` | Directory name highlight color as hex (defaults to `color` if omitted) |
| `border` | Border style (see below) |

### Border Styles

| Style | Example |
|-------|---------|
| `double` | `╔════╗` `║ ME ║` `╚════╝` |
| `round` | `╭────╮` `│ ME │` `╰────╯` |
| `heavy` | `┏━━━━┓` `┃ ME ┃` `┗━━━━┛` |
| `light` | `┌────┐` `│ ME │` `└────┘` |
| `ascii` | `+----+` `| ME |` `+----+` |

First matching badge wins, so order matters.

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
5. (Optional) Create `~/.claude/statusline-config.json` for badges

## Configuration

### Hide Cost (for Max plan users)

```bash
export CLAUDE_STATUSLINE_HIDE_COST=1
```

Add to `~/.bashrc` or `~/.zshrc`, then restart terminal.

### Usage Data

**Claude Code v2.1.80+**: Usage data (5-hour and 7-day rate limits) is provided natively via the `rate_limits` field in the statusline input — no API calls, no tokens, no cache needed.

**Claude Code < v2.1.80** (legacy fallback): Usage is fetched from the Anthropic OAuth API. Token is resolved from (in order):

1. `CLAUDE_CODE_OAUTH_TOKEN` environment variable
2. macOS Keychain (`Claude Code-credentials`)
3. `~/.claude/.credentials.json`
4. Linux `secret-tool`

Usage data is cached in `/tmp/claude/` for 5 minutes and fetched asynchronously to avoid blocking.

## Dependencies

- `jq` — for JSON parsing (`brew install jq` or `apt install jq`)
- `bc` — for calculations (usually pre-installed)
- `curl` — for OAuth usage API on Claude Code < 2.1.80 (usually pre-installed)

## License

MIT
