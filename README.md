# Claude Code Custom Status Line

A bash script for creating an informative status line in Claude Code. Sections are rendered dynamically — if there's no data, the block is hidden.

## What's Displayed

| Section | Description |
|---------|-------------|
| Model | Current model name (Opus 4.5, Sonnet, etc.) |
| 📁 Path | Current directory path |
| 📔 Notes | Note and template count (Obsidian vaults only) |
| ⬢ Node | Node.js version (if installed) |
| 📦 Package | Package manager (npm/yarn/pnpm/bun) |
| ✓/✗ Git | Branch, status, changes (+/-) |
| 💰 Cost | Session cost in USD |
| ⏱ Time | Session duration |
| 🧠/📜 Tokens | Context usage (tokens and %). 🧠 = new API, 📜 = transcript fallback |

## Example Output

```
Opus 4.5 | 📁 ~/projects/myapp | ⬢ v20.10.0 | 📦 pnpm | ✗ main 3/+45-12 | 💰 $1.25 | ⏱ 8m | 🧠 44.2k (22%)
```

```
Opus 4.5 | 📁 ~/obsidian/vault | 📔 127 notes / 7 tpl | 💰 $0.50 | ⏱ 3m
```

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

## Dependencies

- `jq` — for JSON parsing (install via `brew install jq` or `apt install jq`)
- `bc` — for calculations (usually pre-installed)

## License

MIT
