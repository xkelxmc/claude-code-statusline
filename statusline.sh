#!/bin/bash

# Claude Code Custom Status Line
# https://github.com/anthropics/claude-code
#
# Installation:
# 1. Save this file to ~/.claude/statusline.sh
# 2. Make executable: chmod +x ~/.claude/statusline.sh
# 3. Add to ~/.claude/settings.json:
#    { "statusLine": { "type": "command", "command": "~/.claude/statusline.sh" } }

input=$(cat)

# Extract data from Claude Code JSON
dir=$(echo "$input" | jq -r '.workspace.current_dir')
model=$(echo "$input" | jq -r '.model.display_name // .model.id // "unknown"')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
transcript=$(echo "$input" | jq -r '.transcript_path // ""')
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')

# Format path: /Users/username/repos/... -> ~/repos/... with colored current dir
path_with_home=$(echo "$dir" | sed "s|^$HOME|~|")
parent_path=$(dirname "$path_with_home")
current_dir=$(basename "$path_with_home")
# Gray parent + white current dir
short_path="\033[90m${parent_path}/\033[0m\033[97m${current_dir}\033[0m"

# Session duration
duration_sec=$((duration_ms / 1000))
duration_min=$((duration_sec / 60))
if [ "$duration_min" -gt 0 ]; then
    time_fmt="${duration_min}m"
else
    time_fmt="${duration_sec}s"
fi

# Node.js version (gray)
node_ver=""
if command -v node >/dev/null 2>&1; then
    node_ver="\033[90m$(node -v)\033[0m"
fi

# Package manager detection
pkg_manager=""
if [ -f "$dir/bun.lockb" ] || [ -f "$dir/bun.lock" ]; then
    pkg_manager="bun"
elif [ -f "$dir/pnpm-lock.yaml" ]; then
    pkg_manager="pnpm"
elif [ -f "$dir/yarn.lock" ]; then
    pkg_manager="yarn"
elif [ -f "$dir/package-lock.json" ]; then
    pkg_manager="npm"
fi

# Obsidian vault detection
obsidian_notes=""
obsidian_tpl=""
if [ -d "$dir/.obsidian" ]; then
    # Count notes (excluding templates, .claude, CLAUDE.md)
    obsidian_notes=$(find "$dir" -name "*.md" -type f \
        -not -path "*/.claude/*" \
        -not -path "*Templates*" \
        -not -name "CLAUDE.md" \
        2>/dev/null | wc -l | tr -d ' ')
    # Count templates
    obsidian_tpl=$(find "$dir" -path "*Templates*" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
fi

# Git info: branch, status, changes
git_block=""
if [ -d "$dir/.git" ]; then
    cd "$dir"
    git_branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)

    if [ -n "$git_branch" ]; then
        # Count changed files
        changed_files=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')

        insertions=0
        deletions=0

        # Lines in modified/staged files
        diff_stat=$(git diff --shortstat 2>/dev/null)
        staged_stat=$(git diff --cached --shortstat 2>/dev/null)

        if [ -n "$diff_stat" ]; then
            ins=$(echo "$diff_stat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+')
            del=$(echo "$diff_stat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+')
            [ -n "$ins" ] && insertions=$((insertions + ins))
            [ -n "$del" ] && deletions=$((deletions + del))
        fi

        if [ -n "$staged_stat" ]; then
            ins=$(echo "$staged_stat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+')
            del=$(echo "$staged_stat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+')
            [ -n "$ins" ] && insertions=$((insertions + ins))
            [ -n "$del" ] && deletions=$((deletions + del))
        fi

        # Lines in untracked files and directories
        untracked=$(git status --porcelain 2>/dev/null | grep '^??' | cut -c4-)
        if [ -n "$untracked" ]; then
            for f in $untracked; do
                if [ -f "$f" ]; then
                    lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
                    [ -n "$lines" ] && insertions=$((insertions + lines))
                elif [ -d "$f" ]; then
                    # Recursively count lines in all files in untracked directory
                    dir_lines=$(find "$f" -type f -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
                    [ -n "$dir_lines" ] && insertions=$((insertions + dir_lines))
                    # Count files in directory and adjust file count (dir counts as 1, but has N files)
                    dir_files=$(find "$f" -type f 2>/dev/null | wc -l | tr -d ' ')
                    [ -n "$dir_files" ] && changed_files=$((changed_files + dir_files - 1))
                fi
            done
        fi

        # Build git block with colors
        # ✓ green for clean, ✗ yellow for dirty
        if [ "$changed_files" -gt 0 ]; then
            # Has changes: ✗ yellow branch, show diff
            diff_info=""
            [ "$insertions" -gt 0 ] && diff_info="\033[32m+${insertions}\033[0m"
            [ "$deletions" -gt 0 ] && diff_info="${diff_info}\033[31m-${deletions}\033[0m"

            git_block="\033[33m✗ ${git_branch}\033[0m ${changed_files}/${diff_info}"
        else
            # Clean: ✓ green branch
            git_block="\033[32m✓ ${git_branch}\033[0m"
        fi
    fi
fi

# Context usage tokens
tokens=""
ctx_tokens=0
token_icon="🧠"  # new API

# Try new API first: context_window.current_usage
current_usage=$(echo "$input" | jq '.context_window.current_usage')
if [ "$current_usage" != "null" ]; then
    # New API available - use it directly
    ctx_tokens=$(echo "$current_usage" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
fi

# Fallback to transcript if new API returned null or 0
if [ "$ctx_tokens" -eq 0 ] && [ -f "$transcript" ]; then
    token_icon="📜"  # fallback to transcript
    last_usage=$(grep '"input_tokens"' "$transcript" 2>/dev/null | tail -1)
    if [ -n "$last_usage" ]; then
        input_t=$(echo "$last_usage" | jq -r '.message.usage.input_tokens // .usage.input_tokens // 0' 2>/dev/null)
        cache_read=$(echo "$last_usage" | jq -r '.message.usage.cache_read_input_tokens // .usage.cache_read_input_tokens // 0' 2>/dev/null)
        cache_create=$(echo "$last_usage" | jq -r '.message.usage.cache_creation_input_tokens // .usage.cache_creation_input_tokens // 0' 2>/dev/null)
        [ "$input_t" = "null" ] && input_t=0
        [ "$cache_read" = "null" ] && cache_read=0
        [ "$cache_create" = "null" ] && cache_create=0
        ctx_tokens=$((input_t + cache_read + cache_create))
    fi
fi

# Format and color tokens if we have data
if [ "$ctx_tokens" -gt 0 ]; then
    # Format: 44236 -> 44.2k
    if [ "$ctx_tokens" -ge 1000 ]; then
        tokens_fmt=$(echo "scale=1; $ctx_tokens / 1000" | bc)k
    else
        tokens_fmt=$ctx_tokens
    fi
    # Percentage of context window
    pct=$((ctx_tokens * 100 / context_size))

    # Color based on context usage percentage:
    # < 20% gray, < 50% white, < 75% yellow, < 85% orange, >= 85% red
    if [ "$pct" -lt 20 ]; then
        token_color="\033[90m"  # gray
    elif [ "$pct" -lt 50 ]; then
        token_color="\033[97m"  # white
    elif [ "$pct" -lt 75 ]; then
        token_color="\033[33m"  # yellow
    elif [ "$pct" -lt 85 ]; then
        token_color="\033[38;5;208m"  # orange
    else
        token_color="\033[31m"  # red
    fi

    tokens="${token_color}${tokens_fmt} (${pct}%)\033[0m"
fi

# Build output dynamically - only add sections with data
sections=()

# Always show model
sections+=("$model")

# Session ID - from TTY-based file (first 4..last 4)
if [ -n "$GPG_TTY" ]; then
    tty_id=$(echo "$GPG_TTY" | sed 's|/|-|g')
    session_id=$(cat ~/.claude/sessions/${tty_id}.id 2>/dev/null)
    if [ -n "$session_id" ]; then
        sid_short="${session_id:0:4}..${session_id: -4}"
        sections+=("\033[90m${sid_short}\033[0m")
    fi
fi

# Always show path
sections+=("📁 $(printf '%b' "$short_path")")

# Obsidian vault - only if detected
if [ -n "$obsidian_notes" ]; then
    obs_info="$obsidian_notes notes"
    if [ -n "$obsidian_tpl" ] && [ "$obsidian_tpl" -gt 0 ]; then
        obs_info="$obs_info / $obsidian_tpl tpl"
    fi
    sections+=("📔 $obs_info")
fi

# Node.js version - only if detected
if [ -n "$node_ver" ]; then
    sections+=("⬢ $(printf '%b' "$node_ver")")
fi

# Package manager - only if detected
if [ -n "$pkg_manager" ]; then
    sections+=("📦 $pkg_manager")
fi

# Git info - only if in a git repo
if [ -n "$git_block" ]; then
    sections+=("$(printf '%b' "$git_block")")
fi

# Cost - only if > 0 and not hidden by env var
if [ -z "$CLAUDE_STATUSLINE_HIDE_COST" ] && [ "$(echo "$cost > 0" | bc)" -eq 1 ]; then
    sections+=("💰 \$$(printf '%.2f' "$cost")")
fi

# Duration - only if > 0
if [ "$duration_sec" -gt 0 ]; then
    sections+=("⏱ $time_fmt")
fi

# Tokens - only if calculated
if [ -n "$tokens" ]; then
    sections+=("$token_icon $tokens")
fi

# Join sections with " | "
output=""
for i in "${!sections[@]}"; do
    if [ $i -eq 0 ]; then
        output="${sections[$i]}"
    else
        output="$output | ${sections[$i]}"
    fi
done

printf '%b' "$output"
