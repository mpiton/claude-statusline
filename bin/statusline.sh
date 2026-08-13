#!/bin/bash
# statusline-version: dev
set -f

# Force C locale: `printf %.0f` rejects "42.3" when LC_NUMERIC uses a comma,
# and `date` emits localized month names with no am/pm designator.
export LC_ALL=C

# `read -d ''` consumes stdin without forking `cat`. It keeps the trailing
# newline that a command substitution would have stripped, which only matters
# for deciding whether anything was piped in at all.
IFS= read -r -d '' input
case "$input" in
    *[!$' \t\n']*) ;;
    *) printf "Claude"; exit 0 ;;
esac

# ── Colors ──────────────────────────────────────────────
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;175;80m'
cyan='\033[38;2;86;182;194m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
magenta='\033[38;2;180;140;255m'
dim='\033[2m'
reset='\033[0m'

sep=" ${dim}│${reset} "

months=(jan feb mar apr may jun jul aug sep oct nov dec)

# ── Helpers ─────────────────────────────────────────────
# These hand their result back through a global rather than stdout. A status
# line renders on every turn, and `x=$(f)` forks a subshell for each call.

# Bare non-negative integer — the only thing the arithmetic below accepts.
is_num() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# color_for_pct <pct> → $COLOR
color_for_pct() {
    local pct=$1
    is_num "$pct" || pct=0
    if   [ "$pct" -ge 90 ]; then COLOR=$red
    elif [ "$pct" -ge 70 ]; then COLOR=$yellow
    elif [ "$pct" -ge 50 ]; then COLOR=$orange
    else COLOR=$green
    fi
}

# build_bar <pct> <width> → $BAR, and $COLOR for the percentage beside it.
build_bar() {
    local pct=$1 width=$2 i
    is_num "$pct" || pct=0
    [ "$pct" -gt 100 ] && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    color_for_pct "$pct"
    BAR="${COLOR}${filled_str}${dim}${empty_str}${reset}"
}

# GNU date takes `-d @EPOCH`, BSD date takes `-r EPOCH`. Trying one and falling
# back to the other burned a fork per timestamp on whichever platform lost the
# coin toss, so guess from $OSTYPE — which costs nothing — and only probe the
# other dialect if the guess comes back empty. A mac with GNU coreutils ahead
# of /bin on PATH is the case that needs the fallback.
case "$OSTYPE" in
    darwin*|*bsd*) date_flavor=bsd ;;
    *)             date_flavor=gnu ;;
esac

# date_fields <epoch> <strftime> → $DATE_OUT
date_fields() {
    local epoch=$1 fmt=$2
    if [ "$date_flavor" = gnu ]; then
        DATE_OUT=$(date -d "@$epoch" +"$fmt" 2>/dev/null)
        [ -n "$DATE_OUT" ] && return 0
        date_flavor=bsd
        DATE_OUT=$(date -r "$epoch" +"$fmt" 2>/dev/null)
    else
        DATE_OUT=$(date -r "$epoch" +"$fmt" 2>/dev/null)
        [ -n "$DATE_OUT" ] && return 0
        date_flavor=gnu
        DATE_OUT=$(date -d "@$epoch" +"$fmt" 2>/dev/null)
    fi
    [ -n "$DATE_OUT" ]
}

# format_epoch_time <epoch> <time|datetime|date> → $FMT_TIME
#
# One `date` call yields every field and bash assembles the rest. Only POSIX
# conversion specs go in the format string: `%-d` and `%l` are GNU extensions,
# and the lowercasing they used to need went through `sed` and `tr` because
# ${x,,} is bash 4 and macOS still ships 3.2.
format_epoch_time() {
    FMT_TIME=""
    case "$1" in ''|null|0) return ;; esac
    date_fields "$1" "%m %d %I %M %p" || return

    local mo dy hh mi ap
    read -r mo dy hh mi ap <<< "$DATE_OUT"
    is_num "$mo" || return
    dy=${dy#0}
    hh=${hh#0}
    case "$ap" in [Aa]*) ap=am ;; *) ap=pm ;; esac

    local mon=${months[$(( 10#$mo - 1 ))]}
    case "$2" in
        time)     FMT_TIME="${hh}:${mi}${ap}" ;;
        datetime) FMT_TIME="${mon} ${dy}, ${hh}:${mi}${ap}" ;;
        *)        FMT_TIME="${mon} ${dy}" ;;
    esac
}

# iso_to_epoch <iso8601> → $ISO_EPOCH, empty when unparseable.
iso_to_epoch() {
    local iso_str="$1" stripped tz=""
    ISO_EPOCH=""

    if [ "$date_flavor" = gnu ]; then
        ISO_EPOCH=$(date -d "$iso_str" +%s 2>/dev/null)
        [ -n "$ISO_EPOCH" ] && return 0
    fi

    stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

    case "$iso_str" in
        *Z*|*"+00:00"*|*"-00:00"*) tz=UTC ;;
    esac

    if [ -n "$tz" ]; then
        ISO_EPOCH=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$ISO_EPOCH" ] && ISO_EPOCH=$(TZ=UTC date -d "${stripped/T/ }" +%s 2>/dev/null)
    else
        ISO_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$ISO_EPOCH" ] && ISO_EPOCH=$(date -d "${stripped/T/ }" +%s 2>/dev/null)
    fi

    [ -n "$ISO_EPOCH" ]
}

# The cache directory can predate this script, or be pointed somewhere loose
# by CLAUDE_STATUSLINE_CACHE_DIR, so the mode it was created with is no
# guarantee about what is inside it. Check each file rather than the directory
# holding it: a symlink, or a regular file this user does not own, is something
# somebody else put there.
#
# <path> → true when the file is there and is ours to read. An empty path is
# the "caching is off" case.
cache_readable() {
    [ -n "$1" ] && [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ]
}

# <path> → true when writing to it either creates a file or truncates our own.
# Without this a planted symlink would have this render overwrite whatever it
# points at, with content an attacker who can also answer the API controls.
cache_writable() {
    [ -n "$1" ] || return 1
    [ -e "$1" ] || [ -L "$1" ] || return 0
    cache_readable "$1"
}

# <path> → true when the file exists and is younger than $cache_max_age. An
# empty path is the "caching is off" case and is never fresh.
cache_is_fresh() {
    cache_readable "$1" || return 1
    local mtime now
    if [ "$date_flavor" = gnu ]; then
        mtime=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)
    else
        mtime=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null)
    fi
    is_num "$mtime" || return 1
    now=${EPOCHSECONDS:-}
    [ -n "$now" ] || now=$(date +%s)
    [ "$(( now - mtime ))" -lt "$cache_max_age" ]
}

# ── Extract JSON data ───────────────────────────────────
# One jq pass for everything stdin carries; this used to be eleven `echo | jq`
# pipelines, so eleven subshells and eleven jq processes per render.
#
# U+001F separates the fields because `read` collapses runs of whitespace
# delimiters, and one empty field would then shift every field after it.
# `numbers` rejects a value of the wrong type, so a garbage context window size
# falls back to 200k instead of poisoning the arithmetic downstream.
fields=$(jq -r '[
    (.model.display_name // "Claude"),
    ((.context_window.context_window_size | numbers | floor | select(. > 0)) // 200000),
    ((.context_window.current_usage.input_tokens | numbers | floor) // 0),
    ((.context_window.current_usage.cache_creation_input_tokens | numbers | floor) // 0),
    ((.context_window.current_usage.cache_read_input_tokens | numbers | floor) // 0),
    (.effort.level // ""),
    (.cwd // ""),
    ((.rate_limits.five_hour.used_percentage | numbers) // ""),
    (.rate_limits.five_hour.resets_at // ""),
    ((.rate_limits.seven_day.used_percentage | numbers) // ""),
    (.rate_limits.seven_day.resets_at // ""),
    ((.cost.total_cost_usd | numbers | select(. >= 0)) // ""),
    ((.cost.total_lines_added | numbers | floor | select(. >= 0)) // 0),
    ((.cost.total_lines_removed | numbers | floor | select(. >= 0)) // 0),
    ((.output_style.name | strings) // ""),
    (.exceeds_200k_tokens == true)
] | map(tostring) | join("\u001f")' <<< "$input" 2>/dev/null)

IFS=$'\x1f' read -r model_name size input_tokens cache_create cache_read \
    effort cwd stdin_five_pct stdin_five_reset stdin_seven_pct stdin_seven_reset \
    total_cost_usd total_lines_added total_lines_removed output_style exceeds_200k \
    <<< "$fields"

# Malformed stdin leaves every field empty; render the bare fallbacks.
[ -n "$model_name" ] || model_name="Claude"
is_num "$size" || size=200000
is_num "$input_tokens" || input_tokens=0
is_num "$cache_create" || cache_create=0
is_num "$cache_read" || cache_read=0
is_num "$total_lines_added" || total_lines_added=0
is_num "$total_lines_removed" || total_lines_removed=0

current=$(( input_tokens + cache_create + cache_read ))
pct_used=$(( current * 100 / size ))

# Live session effort comes from stdin and follows /effort. settings.json is a
# fallback for CLI versions that don't emit `.effort`, and goes stale otherwise.
if [ -z "$effort" ]; then
    settings_path="$HOME/.claude/settings.json"
    if [ -f "$settings_path" ]; then
        effort=$(jq -r '.effortLevel // empty' "$settings_path" 2>/dev/null)
    fi
fi

# The cache lives under the user's own cache root. The old default was a fixed
# name in a world-writable /tmp, which any other user on the host can create,
# or point a symlink at, before the first render — and everything read back out
# of these files is then theirs to choose: the git dirty flag, and the credit
# amounts this renders as currency.
#
# A directory that is a symlink, or that someone else owns, turns caching off
# rather than being written into. The empty paths that leaves fail closed
# through cache_readable/cache_writable, which vet the individual files too —
# the directory passing does not mean everything inside it came from here.
cache_dir="${CLAUDE_STATUSLINE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline}"
cache_max_age=60
# `mkdir -p -m` is the case SC2174 warns about — the mode reaches the deepest
# directory only, and MSYS drops it altogether — so set it separately. Only on
# a directory this render created: an existing one keeps whatever mode it has.
if [ ! -d "$cache_dir" ]; then
    mkdir -p "$cache_dir" 2>/dev/null && chmod 700 "$cache_dir" 2>/dev/null
fi
if [ -d "$cache_dir" ] && [ ! -L "$cache_dir" ] && [ -O "$cache_dir" ]; then
    cache_file="$cache_dir/statusline-usage-cache.json"
    dirty_cache="$cache_dir/statusline-dirty-cache"
else
    cache_file=""
    dirty_cache=""
fi

# ── LINE 1: Model │ Context % │ Directory (branch) │ Effort ──
color_for_pct "$pct_used"
pct_color=$COLOR

case "$cwd" in ''|null) cwd=$PWD ;; esac
dirname=${cwd%/}
dirname=${dirname##*/}
[ -n "$dirname" ] || dirname=/

# `symbolic-ref` already fails outside a work tree, so the separate
# `rev-parse --is-inside-work-tree` probe was a fork spent on a question its
# answer covers. A detached HEAD prints no branch either way.
git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
git_dirty=""
if [ -n "$git_branch" ]; then
    # `status --porcelain` walks the whole worktree; on a large repo that is
    # most of the render. The answer is worth reusing for a couple of seconds —
    # long enough to skip the walk between two turns, short enough that a star
    # never looks stuck. $EPOCHSECONDS is bash 5 and macOS ships 3.2, so
    # without a free clock the walk just runs, rather than forking `date` to
    # decide whether to fork `git`.
    now_s=${EPOCHSECONDS:-}
    dirty_hit=""
    if [ -n "$now_s" ] && cache_readable "$dirty_cache"; then
        # The entry is written without a trailing newline, so `read` reports EOF
        # and returns non-zero even though it filled the fields.
        IFS=$'\x1f' read -r cached_expiry cached_dirty cached_cwd < "$dirty_cache"
        # Keyed on the directory: a stale entry from another cwd is a miss, not a
        # wrong star. A path the caller spells differently misses too, which
        # costs one worktree walk and stays correct.
        if [ "$cached_cwd" = "$cwd" ] && is_num "$cached_expiry" && [ "$now_s" -lt "$cached_expiry" ]; then
            dirty_hit=yes
            git_dirty=$cached_dirty
        fi
    fi
    if [ -z "$dirty_hit" ]; then
        if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
            git_dirty="*"
        fi
        if [ -n "$now_s" ] && cache_writable "$dirty_cache"; then
            printf '%s\x1f%s\x1f%s' "$(( now_s + 2 ))" "$git_dirty" "$cwd" \
                > "$dirty_cache" 2>/dev/null
        fi
    fi
fi

# /proc/PID/cmdline is NUL-separated argv and costs no fork to read; `ps` is
# the fallback for macOS and Git Bash.
parent_cmd=""
if [ -r "/proc/$PPID/cmdline" ]; then
    while IFS= read -r -d '' parent_arg; do
        parent_cmd+=" $parent_arg"
    done < "/proc/$PPID/cmdline"
else
    parent_cmd=$(ps -o args= -p "$PPID" 2>/dev/null)
fi
skip_perms=""
case "$parent_cmd" in
    *--dangerously-skip-permissions*) skip_perms="⚡  " ;;
esac

line1="${blue}${model_name}${reset}"
line1+="${sep}"
line1+="✍️ ${pct_color}${pct_used}%${reset}"
[ "$exceeds_200k" = "true" ] && line1+=" ${red}>200k${reset}"
line1+="${sep}"
line1+="${skip_perms}${cyan}${dirname}${reset}"
if [ -n "$git_branch" ]; then
    line1+=" ${green}(${git_branch}${red}${git_dirty}${green})${reset}"
fi
if [ -n "$total_cost_usd" ]; then
    printf -v total_cost_fmt "%.2f" "$total_cost_usd"
    line1+="${sep}${white}\$${total_cost_fmt}${reset}"
fi
if [ "$total_lines_added" -gt 0 ] || [ "$total_lines_removed" -gt 0 ]; then
    line1+="${sep}${green}+${total_lines_added}${reset}${dim}/${reset}${red}-${total_lines_removed}${reset}"
fi
if [ -n "$output_style" ]; then
    line1+="${sep}${dim}style:${reset}${white}${output_style}${reset}"
fi
if [ -n "$effort" ]; then
    line1+="${sep}"
    case "$effort" in
        max)    line1+="${orange}● ${effort}${reset}" ;;
        xhigh)  line1+="${magenta}● ${effort}${reset}" ;;
        high)   line1+="${magenta}◕ ${effort}${reset}" ;;
        medium) line1+="${dim}◑ ${effort}${reset}" ;;
        low)    line1+="${dim}◔ ${effort}${reset}" ;;
        *)      line1+="${dim}◑ ${effort}${reset}" ;;
    esac
fi

# ── Rate limits from stdin (primary) ───────────────────
has_stdin_rates=false
five_hour_pct=""
five_hour_reset_epoch=""
seven_day_pct=""
seven_day_reset_epoch=""

if [ -n "$stdin_five_pct" ]; then
    has_stdin_rates=true
    printf -v five_hour_pct "%.0f" "$stdin_five_pct"
    five_hour_reset_epoch=$stdin_five_reset
    if [ -n "$stdin_seven_pct" ]; then
        printf -v seven_day_pct "%.0f" "$stdin_seven_pct"
        seven_day_reset_epoch=$stdin_seven_reset
    fi
fi

# ── Fallback: API call (cached) ────────────────────────
usage_data=""
usage_stale=false
extra_enabled="false"

if ! $has_stdin_rates; then
    needs_refresh=true

    if cache_is_fresh "$cache_file"; then
        needs_refresh=false
        usage_data=$(<"$cache_file")
    fi

    if $needs_refresh; then
        token=""
        if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
            token="$CLAUDE_CODE_OAUTH_TOKEN"
        elif command -v security >/dev/null 2>&1; then
            blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
            if [ -n "$blob" ]; then
                token=$(jq -r '.claudeAiOauth.accessToken // empty' <<< "$blob" 2>/dev/null)
            fi
        fi
        if [ -z "$token" ] || [ "$token" = "null" ]; then
            creds_file="${HOME}/.claude/.credentials.json"
            if [ -f "$creds_file" ]; then
                token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
            fi
        fi
        if [ -z "$token" ] || [ "$token" = "null" ]; then
            if command -v secret-tool >/dev/null 2>&1; then
                blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
                if [ -n "$blob" ]; then
                    token=$(jq -r '.claudeAiOauth.accessToken // empty' <<< "$blob" 2>/dev/null)
                fi
            fi
        fi

        if [ -n "$token" ] && [ "$token" != "null" ]; then
            response=$(curl -s --max-time 5 \
                -H "Accept: application/json" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $token" \
                -H "anthropic-beta: oauth-2025-04-20" \
                -H "User-Agent: claude-code/2.1.34" \
                "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
            if [ -n "$response" ] && jq -e '.five_hour' <<< "$response" >/dev/null 2>&1; then
                usage_data="$response"
                cache_writable "$cache_file" && printf '%s' "$response" > "$cache_file" 2>/dev/null
            fi
        fi
        if [ -z "$usage_data" ] && cache_readable "$cache_file"; then
            # The refresh failed — no token, or the call did not come back. A
            # rate-limit bar that is behind still says something, and the reset
            # time it renders alongside dates it, so the last known body beats
            # blanking the whole block. What it is too old for is below.
            usage_data=$(<"$cache_file")
            usage_stale=true
        fi
    fi
elif cache_is_fresh "$cache_file"; then
    # stdin already carried the rate limits; the cache is only still worth
    # reading for the extra-usage block, which stdin does not report.
    #
    # Nothing on this path ever refreshes the cache, so without the age check
    # the credit amounts came from whenever the last render that did refresh
    # happened to run, with nothing bounding how long ago that was. Currency
    # figures of unknown age read as current, so a stale cache drops the line.
    usage_data=$(<"$cache_file")
fi

# One jq pass over whichever payload we ended up with. A parse failure leaves
# every field empty, which is how a corrupt cache stays harmless.
if [ -n "$usage_data" ]; then
    api_fields=$(jq -r '[
        ((.five_hour.utilization | numbers) // 0),
        (.five_hour.resets_at // ""),
        ((.seven_day.utilization | numbers) // 0),
        (.seven_day.resets_at // ""),
        (.extra_usage.is_enabled // false),
        ((.extra_usage.utilization | numbers) // 0),
        (((.extra_usage.used_credits | numbers) // 0) / 100),
        (((.extra_usage.monthly_limit | numbers) // 0) / 100)
    ] | map(tostring) | join("\u001f")' <<< "$usage_data" 2>/dev/null)

    if [ -n "$api_fields" ]; then
        IFS=$'\x1f' read -r api_five_pct api_five_reset api_seven_pct api_seven_reset \
            extra_enabled api_extra_pct api_extra_used api_extra_limit <<< "$api_fields"

        # Nothing dates the credit figures the way a reset time dates a bar, so
        # a body of unbounded age keeps its bars and loses its currency. Money
        # that reads as current and is not is worse than no money line.
        $usage_stale && extra_enabled="false"

        if ! $has_stdin_rates; then
            printf -v five_hour_pct "%.0f" "$api_five_pct"
            iso_to_epoch "$api_five_reset" && five_hour_reset_epoch=$ISO_EPOCH
            printf -v seven_day_pct "%.0f" "$api_seven_pct"
            iso_to_epoch "$api_seven_reset" && seven_day_reset_epoch=$ISO_EPOCH
        fi
    fi
fi

# ── Rate limit lines ────────────────────────────────────
rate_lines=""
bar_width=10

if [ -n "$five_hour_pct" ]; then
    format_epoch_time "$five_hour_reset_epoch" "time"
    five_hour_reset=$FMT_TIME
    build_bar "$five_hour_pct" "$bar_width"
    printf -v five_hour_pct_fmt "%3d" "$five_hour_pct"

    rate_lines+="${white}current${reset} ${BAR} ${COLOR}${five_hour_pct_fmt}%${reset}"
    [ -n "$five_hour_reset" ] && rate_lines+=" ${dim}⟳${reset} ${white}${five_hour_reset}${reset}"
fi

if [ -n "$seven_day_pct" ]; then
    format_epoch_time "$seven_day_reset_epoch" "datetime"
    seven_day_reset=$FMT_TIME
    build_bar "$seven_day_pct" "$bar_width"
    printf -v seven_day_pct_fmt "%3d" "$seven_day_pct"

    [ -n "$rate_lines" ] && rate_lines+="\n"
    rate_lines+="${white}weekly${reset}  ${BAR} ${COLOR}${seven_day_pct_fmt}%${reset}"
    [ -n "$seven_day_reset" ] && rate_lines+=" ${dim}⟳${reset} ${white}${seven_day_reset}${reset}"
fi

if [ "$extra_enabled" = "true" ]; then
    printf -v extra_pct "%.0f" "$api_extra_pct"
    printf -v extra_used "%.2f" "$api_extra_used"
    printf -v extra_limit "%.2f" "$api_extra_limit"
    build_bar "$extra_pct" "$bar_width"

    # The extra-usage budget rolls over on the 1st, so this is always day 1 of
    # the next month. `date -v+1m -v1d` (BSD) with a nested `date` as the GNU
    # fallback cost two or three forks to say so; the month name is a lookup.
    cur_mo=$(date +%m 2>/dev/null)
    if is_num "$cur_mo"; then
        extra_reset="${months[$(( 10#$cur_mo % 12 ))]} 1"
    else
        extra_reset=""
    fi

    [ -n "$rate_lines" ] && rate_lines+="\n"
    rate_lines+="${white}extra${reset}   ${BAR} ${COLOR}\$${extra_used}${dim}/${reset}${white}\$${extra_limit}${reset}"
    [ -n "$extra_reset" ] && rate_lines+=" ${dim}⟳${reset} ${white}${extra_reset}${reset}"
fi

# ── Output ──────────────────────────────────────────────
printf "%b" "$line1"
[ -n "$rate_lines" ] && printf "\n\n%b" "$rate_lines"

exit 0
