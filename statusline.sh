#!/bin/bash

# Claude Code Custom Status Line (v2 - 3 lines)
# https://github.com/anthropics/claude-code

set -f
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

# Context progress bar (▰▱ style)
progress_bar() {
    local pct=$1
    local width=${2:-20}
    local filled=$((pct * width / 100))
    local empty=$((width - filled))

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

# Usage color by percentage (green -> orange -> yellow -> red)
usage_color() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then echo "\033[38;2;255;85;85m"
    elif [ "$pct" -ge 70 ]; then echo "\033[38;2;230;200;0m"
    elif [ "$pct" -ge 50 ]; then echo "\033[38;2;255;176;85m"
    else echo "\033[38;2;0;175;80m"
    fi
}

# Usage bar (●○ style)
usage_bar() {
    local pct=$1
    local width=$2
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local ucolor
    ucolor=$(usage_color "$pct")

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    echo "${ucolor}${filled_str}\033[2m${empty_str}\033[0m"
}

# Convert ISO timestamp to epoch
iso_to_epoch() {
    local iso_str="$1"
    local epoch

    # Try GNU date first
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    # BSD date (macOS)
    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    fi

    [ -n "$epoch" ] && echo "$epoch"
}

# Format reset time from ISO
format_reset_time() {
    local iso_str="$1"
    local style="$2"
    [ -z "$iso_str" ] || [ "$iso_str" = "null" ] && return

    local epoch
    epoch=$(iso_to_epoch "$iso_str")
    [ -z "$epoch" ] && return

    case "$style" in
        time)
            date -j -r "$epoch" +"%H:%M" 2>/dev/null || \
            date -d "@$epoch" +"%H:%M" 2>/dev/null
            ;;
        datetime)
            date -j -r "$epoch" +"%b %-d, %H:%M" 2>/dev/null | sed 's/  / /g' | tr '[:upper:]' '[:lower:]' || \
            date -d "@$epoch" +"%b %-d, %H:%M" 2>/dev/null | tr '[:upper:]' '[:lower:]'
            ;;
    esac
}

# ============================================================================
# OAUTH TOKEN & USAGE API (cached)
# ============================================================================

get_oauth_token() {
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        echo "$CLAUDE_CODE_OAUTH_TOKEN"
        return 0
    fi

    local token=""

    # macOS Keychain
    if command -v security >/dev/null 2>&1; then
        local blob
        blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi

    # Credentials file
    local creds_file="${HOME}/.claude/.credentials.json"
    if [ -f "$creds_file" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            echo "$token"
            return 0
        fi
    fi

    # Linux secret-tool
    if command -v secret-tool >/dev/null 2>&1; then
        local blob
        blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi

    echo ""
}

# Fetch usage data with cache
USAGE_CACHE="/tmp/claude/statusline-usage-cache.json"
USAGE_CACHE_LOCK="/tmp/claude/statusline-usage.lock"
USAGE_CACHE_TTL=60
mkdir -p /tmp/claude

usage_data=""
needs_refresh=true

if [ -f "$USAGE_CACHE" ]; then
    cache_mtime=$(stat -f %m "$USAGE_CACHE" 2>/dev/null || stat -c %Y "$USAGE_CACHE" 2>/dev/null)
    cache_now=$(date +%s)
    cache_age=$(( cache_now - cache_mtime ))
    if [ "$cache_age" -lt "$USAGE_CACHE_TTL" ]; then
        needs_refresh=false
    fi
    usage_data=$(cat "$USAGE_CACHE" 2>/dev/null)
fi

if $needs_refresh; then
    # Clean stale lock (>2min)
    if [ -d "$USAGE_CACHE_LOCK" ]; then
        lock_mtime=$(stat -f %m "$USAGE_CACHE_LOCK" 2>/dev/null || stat -c %Y "$USAGE_CACHE_LOCK" 2>/dev/null)
        lock_age=$(( $(date +%s) - lock_mtime ))
        [ "$lock_age" -gt 120 ] && rmdir "$USAGE_CACHE_LOCK" 2>/dev/null
    fi

    # Async fetch with lock
    if mkdir "$USAGE_CACHE_LOCK" 2>/dev/null; then
        (
            token=$(get_oauth_token)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                response=$(curl -s --max-time 5 \
                    -H "Accept: application/json" \
                    -H "Content-Type: application/json" \
                    -H "Authorization: Bearer $token" \
                    -H "anthropic-beta: oauth-2025-04-20" \
                    -H "User-Agent: claude-code/2.1.34" \
                    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
                if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
                    echo "$response" > "$USAGE_CACHE"
                fi
            fi
            rmdir "$USAGE_CACHE_LOCK" 2>/dev/null
        ) &
    fi
fi

# Parse usage data into line prefixes
five_hour_prefix=""
seven_day_prefix=""
usage_bar_width=10

if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
    # 5-hour usage
    five_pct=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
    five_reset_iso=$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty')
    five_reset=$(format_reset_time "$five_reset_iso" "time")
    five_bar=$(usage_bar "$five_pct" "$usage_bar_width")
    five_color=$(usage_color "$five_pct")
    five_pct_fmt=$(printf "%3d" "$five_pct")

    five_hour_prefix="\033[97mc:\033[0m ${five_bar} ${five_color}${five_pct_fmt}%\033[0m"
    [ -n "$five_reset" ] && five_hour_prefix+=" \033[2m⟳\033[0m \033[97m${five_reset}\033[0m"

    # 7-day usage
    week_pct=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
    week_reset_iso=$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty')
    week_reset=$(format_reset_time "$week_reset_iso" "datetime")
    week_bar=$(usage_bar "$week_pct" "$usage_bar_width")
    week_color=$(usage_color "$week_pct")
    week_pct_fmt=$(printf "%3d" "$week_pct")

    seven_day_prefix="\033[97mw:\033[0m ${week_bar} ${week_color}${week_pct_fmt}%\033[0m"
    [ -n "$week_reset" ] && seven_day_prefix+=" \033[2m⟳\033[0m \033[97m${week_reset}\033[0m"
fi

# ============================================================================
# LINE 1: Location & Environment - path, node, pkg, git, obsidian
# ============================================================================

# Path
short_path=$(format_path "$current_dir")
line1="🤖 $model | 📁 $short_path"

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
# LINE 2: 5h usage | Session - model, session_id, claude lines
# ============================================================================

line2_parts=()

# Session ID (full)
if [ -n "$session_id" ]; then
    line2_parts+=("🔑 \033[90m${session_id}\033[0m")
fi

# Claude's lines added/removed this session
if [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; then
    claude_lines=""
    [ "$lines_added" -gt 0 ] && claude_lines="\033[32m+${lines_added}\033[0m"
    [ "$lines_removed" -gt 0 ] && claude_lines="${claude_lines} \033[31m-${lines_removed}\033[0m"
    # line2_parts+=("📝 $(printf '%b' "$claude_lines")")
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

# Prepend 5h usage graph
if [ -n "$five_hour_prefix" ]; then
    if [ -n "$line2" ]; then
        line2="${five_hour_prefix} | ${line2}"
    else
        line2="${five_hour_prefix}"
    fi
fi

# ============================================================================
# LINE 3: weekly usage | Metrics - context, cost, time
# ============================================================================

line3_parts=()

# Context with progress bar
used_pct_raw=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
used_pct=${used_pct_raw%.*}  # Truncate to integer
[ -z "$used_pct" ] && used_pct=0
if [ "$used_pct" -gt 0 ]; then
    bar=$(progress_bar "$used_pct" 20)

    # Format tokens: 44236 -> 44.2k
    if [ "$ctx_tokens" -ge 1000 ]; then
        tokens_fmt=$(echo "scale=1; $ctx_tokens / 1000" | bc)k
    else
        tokens_fmt=$ctx_tokens
    fi

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
    # line3_parts+=("⏱ ${time_total} (${time_api} api)")
fi

# TPM (tokens per minute)
if [ -n "$tpm" ] && [ "$tpm" -gt 0 ] 2>/dev/null; then
    if [ "$tpm" -ge 1000 ]; then
        tpm_fmt=$(echo "scale=1; $tpm / 1000" | bc)k
    else
        tpm_fmt=$tpm
    fi
    # line3_parts+=("📊 ${tpm_fmt} tpm")
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

# Prepend weekly usage graph
if [ -n "$seven_day_prefix" ]; then
    if [ -n "$line3" ]; then
        line3="${seven_day_prefix} | ${line3}"
    else
        line3="${seven_day_prefix}"
    fi
fi

# ============================================================================
# OUTPUT
# ============================================================================

printf '%b\n' "$line1"
[ -n "$line2" ] && printf '%b\n' "$line2"
[ -n "$line3" ] && printf '%b\n' "$line3"
