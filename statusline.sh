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

# Total tokens (for TPM calculation)
total_input_tokens=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
total_output_tokens=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
tot_tokens=$((total_input_tokens + total_output_tokens))

# TPM (tokens per minute) from native data
tpm=""
if [ "$tot_tokens" -gt 0 ] && [ "$duration_ms" -gt 0 ]; then
    tpm=$(echo "$tot_tokens $duration_ms" | awk '{printf "%.0f", $1 * 60000 / $2}')
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
# CCUSAGE ASYNC CACHE (for reset time)
# ============================================================================

CCUSAGE_CACHE="/tmp/ccusage_statusline_cache.json"
CCUSAGE_LOCK="/tmp/ccusage_statusline.lock"
CCUSAGE_CACHE_TTL=30  # seconds

reset_time=""
reset_remaining=""

# Check if ccusage is available
if command -v ccusage >/dev/null 2>&1 || command -v npx >/dev/null 2>&1; then
    now=$(date +%s)
    cache_valid=0

    # Check if cache exists and is fresh
    if [ -f "$CCUSAGE_CACHE" ]; then
        cache_mtime=$(stat -f %m "$CCUSAGE_CACHE" 2>/dev/null || stat -c %Y "$CCUSAGE_CACHE" 2>/dev/null)
        cache_age=$((now - cache_mtime))
        if [ "$cache_age" -lt "$CCUSAGE_CACHE_TTL" ]; then
            cache_valid=1
        fi
    fi

    # If cache is stale, trigger async update (non-blocking)
    if [ "$cache_valid" -eq 0 ]; then
        # Use lock to prevent multiple concurrent updates
        if mkdir "$CCUSAGE_LOCK" 2>/dev/null; then
            (
                # Run ccusage in background
                if command -v ccusage >/dev/null 2>&1; then
                    ccusage blocks --json 2>/dev/null > "$CCUSAGE_CACHE.tmp" && mv "$CCUSAGE_CACHE.tmp" "$CCUSAGE_CACHE"
                else
                    npx -y ccusage@latest blocks --json 2>/dev/null > "$CCUSAGE_CACHE.tmp" && mv "$CCUSAGE_CACHE.tmp" "$CCUSAGE_CACHE"
                fi
                rmdir "$CCUSAGE_LOCK" 2>/dev/null
            ) &
        fi
    fi

    # Read from cache (even if stale - better than nothing)
    if [ -f "$CCUSAGE_CACHE" ]; then
        active_block=$(jq -c '.blocks[] | select(.isActive == true)' "$CCUSAGE_CACHE" 2>/dev/null | head -n1)
        if [ -n "$active_block" ]; then
            end_time=$(echo "$active_block" | jq -r '.endTime // empty')
            remaining_min=$(echo "$active_block" | jq -r '.projection.remainingMinutes // empty')

            if [ -n "$end_time" ]; then
                # Format reset time as HH:MM (local timezone)
                if date -r 0 +%s >/dev/null 2>&1; then
                    # BSD date (macOS) - convert ISO to epoch, then to local time
                    end_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${end_time%%.*}" +%s 2>/dev/null)
                    reset_time=$(date -r "$end_epoch" +"%H:%M" 2>/dev/null)
                else
                    # GNU date (Linux) - handles ISO format with timezone
                    reset_time=$(date -d "$end_time" +"%H:%M" 2>/dev/null)
                fi
            fi

            if [ -n "$remaining_min" ] && [ "$remaining_min" != "null" ]; then
                remaining_min=${remaining_min%.*}  # Remove decimal
                if [ "$remaining_min" -ge 60 ]; then
                    reset_remaining="$((remaining_min / 60))h $((remaining_min % 60))m"
                else
                    reset_remaining="${remaining_min}m"
                fi
            fi
        fi
    fi
fi

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

        # Lines in untracked files (skip binaries with grep -I)
        untracked_files=$(git ls-files --others --exclude-standard 2>/dev/null)
        if [ -n "$untracked_files" ]; then
            untracked_lines=$(echo "$untracked_files" | tr '\n' '\0' | xargs -0 grep -chI '' 2>/dev/null | awk '{s+=$1} END {print s+0}')
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
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
if [ "$used_pct" -gt 0 ]; then
    bar=$(progress_bar "$used_pct" 20)

    # Format tokens: 44236 -> 44.2k
    if [ "$ctx_tokens" -ge 1000 ]; then
        tokens_fmt=$(echo "scale=1; $ctx_tokens / 1000" | bc)k
    else
        tokens_fmt=$ctx_tokens
    fi

    # Use same color for percentage as progress bar
    line3_parts+=("🧠 ${bar_color}${used_pct}%\033[0m $(printf '%b' "$bar") ${bar_color}${tokens_fmt}\033[0m")
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

# TPM (tokens per minute)
if [ -n "$tpm" ] && [ "$tpm" -gt 0 ] 2>/dev/null; then
    # Format: 28000 -> 28k tpm
    if [ "$tpm" -ge 1000 ]; then
        tpm_fmt=$(echo "scale=1; $tpm / 1000" | bc)k
    else
        tpm_fmt=$tpm
    fi
    line3_parts+=("📊 ${tpm_fmt} tpm")
fi

# Reset time (from ccusage cache)
if [ -n "$reset_remaining" ] && [ -n "$reset_time" ]; then
    line3_parts+=("⏳ ${reset_remaining} → ${reset_time}")
elif [ -n "$reset_remaining" ]; then
    line3_parts+=("⏳ ${reset_remaining}")
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
