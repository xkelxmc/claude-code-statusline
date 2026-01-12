#!/bin/bash

# Claude Code Custom Status Line (v2 - 3 lines)
# https://github.com/anthropics/claude-code

input=$(cat)

# ============================================================================
# EXTRACT DATA
# ============================================================================

# Basic info
session_id=$(echo "$input" | jq -r '.session_id // ""')
model=$(echo "$input" | jq -r '.model.display_name // .model.id // "unknown"')
project_dir=$(echo "$input" | jq -r '.workspace.project_dir // .workspace.current_dir')
current_dir=$(echo "$input" | jq -r '.workspace.current_dir')
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')

# Cost and time
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
api_duration_ms=$(echo "$input" | jq -r '.cost.total_api_duration_ms // 0')
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')

# Context tokens
current_usage=$(echo "$input" | jq '.context_window.current_usage')
if [ "$current_usage" != "null" ]; then
    ctx_tokens=$(echo "$current_usage" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
else
    ctx_tokens=0
fi

# ============================================================================
# FORMAT HELPERS
# ============================================================================

# Format path: ~/repos/me/project with colored current dir
format_path() {
    local dir="$1"
    local path_with_home=$(echo "$dir" | sed "s|^$HOME|~|")
    local parent=$(dirname "$path_with_home")
    local current=$(basename "$path_with_home")
    echo "\033[90m${parent}/\033[0m\033[97m${current}\033[0m"
}

# Format duration: ms -> "5m" or "45s"
format_duration() {
    local ms=$1
    local sec=$((ms / 1000))
    local min=$((sec / 60))
    if [ "$min" -gt 0 ]; then
        echo "${min}m"
    else
        echo "${sec}s"
    fi
}

# Progress bar with color based on percentage
# Usage: progress_bar <used_pct> <width>
# Returns: colored bar AND sets $bar_color for use with percentage text
progress_bar() {
    local pct=$1
    local width=${2:-20}
    local filled=$((pct * width / 100))
    local empty=$((width - filled))

    # Color based on usage: < 20% gray, < 50% white, < 75% yellow, < 85% orange, >= 85% red
    if [ "$pct" -lt 20 ]; then
        bar_color="\033[90m"  # gray
    elif [ "$pct" -lt 50 ]; then
        bar_color="\033[97m"  # white
    elif [ "$pct" -lt 75 ]; then
        bar_color="\033[33m"  # yellow
    elif [ "$pct" -lt 85 ]; then
        bar_color="\033[38;5;208m"  # orange
    else
        bar_color="\033[31m"  # red
    fi

    local bar="${bar_color}"
    for ((i=0; i<filled; i++)); do bar+="▰"; done
    bar+="\033[90m"
    for ((i=0; i<empty; i++)); do bar+="▱"; done
    bar+="\033[0m"

    echo "$bar"
}

# ============================================================================
# LINE 1: Location & Environment - path, node, pkg, git, obsidian
# ============================================================================

# Path
short_path=$(format_path "$current_dir")
line1="📁 $short_path"

# Node.js version
if command -v node >/dev/null 2>&1; then
    node_ver=$(node -v)
    line1="$line1 | ⬢ \033[90m${node_ver}\033[0m"
fi

# Package manager (check in project_dir)
pkg_manager=""
if [ -f "$project_dir/bun.lockb" ] || [ -f "$project_dir/bun.lock" ]; then
    pkg_manager="bun"
elif [ -f "$project_dir/pnpm-lock.yaml" ]; then
    pkg_manager="pnpm"
elif [ -f "$project_dir/yarn.lock" ]; then
    pkg_manager="yarn"
elif [ -f "$project_dir/package-lock.json" ]; then
    pkg_manager="npm"
fi
[ -n "$pkg_manager" ] && line1="$line1 | 📦 $pkg_manager"

# Git info (based on project_dir, not current_dir!)
if [ -d "$project_dir/.git" ] && cd "$project_dir" 2>/dev/null; then
    git_branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)

    if [ -n "$git_branch" ]; then
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

        # Lines in untracked files
        untracked_files=$(git ls-files --others --exclude-standard 2>/dev/null)
        if [ -n "$untracked_files" ]; then
            untracked_lines=$(echo "$untracked_files" | tr '\n' '\0' | xargs -0 cat 2>/dev/null | wc -l | tr -d ' ')
            [ -n "$untracked_lines" ] && insertions=$((insertions + untracked_lines))

            untracked_count=$(echo "$untracked_files" | wc -l | tr -d ' ')
            status_untracked=$(git status --porcelain 2>/dev/null | grep -c '^??')
            if [ "$untracked_count" -gt "$status_untracked" ]; then
                changed_files=$((changed_files + untracked_count - status_untracked))
            fi
        fi

        # Build git block
        if [ "$changed_files" -gt 0 ]; then
            diff_info=""
            [ "$insertions" -gt 0 ] && diff_info="\033[32m+${insertions}\033[0m"
            [ "$deletions" -gt 0 ] && diff_info="${diff_info}\033[31m-${deletions}\033[0m"
            git_block="\033[33m✗ ${git_branch}\033[0m ${changed_files}/${diff_info}"
        else
            git_block="\033[32m✓ ${git_branch}\033[0m"
        fi

        line1="$line1 | $(printf '%b' "$git_block")"
    fi
fi

# Obsidian vault
if [ -d "$project_dir/.obsidian" ]; then
    obsidian_notes=$(find "$project_dir" -name "*.md" -type f \
        -not -path "*/.claude/*" \
        -not -path "*Templates*" \
        -not -name "CLAUDE.md" \
        2>/dev/null | wc -l | tr -d ' ')
    obsidian_tpl=$(find "$project_dir" -path "*Templates*" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')

    obs_info="$obsidian_notes notes"
    [ "$obsidian_tpl" -gt 0 ] && obs_info="$obs_info / $obsidian_tpl tpl"
    line1="$line1 | 📔 $obs_info"
fi

# ============================================================================
# LINE 2: Session - model, session_id, claude lines
# ============================================================================

line2_parts=()

# Model
line2_parts+=("🤖 $model")

# Session ID (full)
if [ -n "$session_id" ]; then
    line2_parts+=("🔑 \033[90m${session_id}\033[0m")
fi

# Claude's lines added/removed this session
if [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; then
    claude_lines=""
    [ "$lines_added" -gt 0 ] && claude_lines="\033[32m+${lines_added}\033[0m"
    [ "$lines_removed" -gt 0 ] && claude_lines="${claude_lines} \033[31m-${lines_removed}\033[0m"
    line2_parts+=("📝 $(printf '%b' "$claude_lines")")
fi

# Join line2 parts
line2=""
for i in "${!line2_parts[@]}"; do
    if [ $i -eq 0 ]; then
        line2="${line2_parts[$i]}"
    else
        line2="$line2 | ${line2_parts[$i]}"
    fi
done

# ============================================================================
# LINE 3: Metrics - context, cost, time
# ============================================================================

line3_parts=()

# Context with progress bar
if [ "$ctx_tokens" -gt 0 ]; then
    pct=$((ctx_tokens * 100 / context_size))
    bar=$(progress_bar "$pct" 20)

    # Format tokens: 44236 -> 44.2k
    if [ "$ctx_tokens" -ge 1000 ]; then
        tokens_fmt=$(echo "scale=1; $ctx_tokens / 1000" | bc)k
    else
        tokens_fmt=$ctx_tokens
    fi

    # Use same color for percentage as progress bar
    line3_parts+=("🧠 ${bar_color}${pct}%\033[0m $(printf '%b' "$bar")")
fi

# Cost
if [ -z "$CLAUDE_STATUSLINE_HIDE_COST" ] && [ "$(echo "$cost > 0" | bc)" -eq 1 ]; then
    line3_parts+=("💰 \$$(printf '%.2f' "$cost")")
fi

# Duration (total + api)
duration_sec=$((duration_ms / 1000))
if [ "$duration_sec" -gt 0 ]; then
    time_total=$(format_duration "$duration_ms")
    time_api=$(format_duration "$api_duration_ms")
    line3_parts+=("⏱ ${time_total} (${time_api} api)")
fi

# Join line3 parts
line3=""
for i in "${!line3_parts[@]}"; do
    if [ $i -eq 0 ]; then
        line3="${line3_parts[$i]}"
    else
        line3="$line3 | ${line3_parts[$i]}"
    fi
done

# ============================================================================
# OUTPUT
# ============================================================================

printf '%b\n' "$line1"
[ -n "$line2" ] && printf '%b\n' "$line2"
[ -n "$line3" ] && printf '%b\n' "$line3"
