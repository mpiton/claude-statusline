#!/bin/bash
# statusline-version: dev
set -f

# Ask the caller's locale for its character map before the stable C locale
# below hides it. An unavailable or unknown map safely falls back to ASCII.
display_charmap=$(locale charmap 2>/dev/null)
case "$display_charmap" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ascii_output=false ;;
    *)                                     ascii_output=true ;;
esac

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

# ── Configuration ───────────────────────────────────────
blocks="model,context,directory,cost,changes,style,effort,current,burn,weekly,extra"
bar_width=10
skills_limit=3
# Claude Code reads its own configuration from CLAUDE_CONFIG_DIR when that is
# set, and from ~/.claude otherwise. A session started on a second profile
# keeps its settings, its credentials and this script's config together in
# there; going to $HOME/.claude regardless read another profile's effort level
# and missed the token the session was actually authenticated with.
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
config_file="${CLAUDE_STATUSLINE_CONFIG:-$claude_dir/statusline.json}"

if [ -f "$config_file" ]; then
    config_fields=$(jq -r '
        def known_block:
            . == "model" or . == "context" or . == "directory"
            or . == "cost" or . == "changes" or . == "style"
            or . == "effort" or . == "current" or . == "burn"
            or . == "weekly" or . == "extra" or . == "skills";
        def color: strings | select(test("^#[0-9A-Fa-f]{6}$"));

        . as $config
        | (($config.colors // {}) | if type == "object" then . else {} end) as $colors
        | [
            (if ($config.blocks | type) == "array" then
                 "set:" + ([$config.blocks[] | strings | select(known_block)] | unique | join(","))
             else "" end),
            (($config.bar_width | numbers | select(. == floor and . >= 1 and . <= 40)) // ""),
            (($config.skills_limit | numbers | select(. == floor and . >= 1 and . <= 10)) // ""),
            (($colors.blue | color) // ""),
            (($colors.orange | color) // ""),
            (($colors.green | color) // ""),
            (($colors.cyan | color) // ""),
            (($colors.red | color) // ""),
            (($colors.yellow | color) // ""),
            (($colors.white | color) // ""),
            (($colors.magenta | color) // "")
        ] | map(tostring) | join("\u001f")
    ' "$config_file" 2>/dev/null)

    if [ -n "$config_fields" ]; then
        IFS=$'\x1f' read -r config_blocks config_bar_width config_skills_limit \
            config_blue config_orange config_green config_cyan \
            config_red config_yellow config_white config_magenta <<< "$config_fields"
        case "$config_blocks" in set:*) blocks=${config_blocks#set:} ;; esac
        [ -n "$config_bar_width" ] && bar_width=$config_bar_width
        [ -n "$config_skills_limit" ] && skills_limit=$config_skills_limit

        set_color() {
            local name=$1 hex=${2#\#}
            printf -v "$name" '\033[38;2;%d;%d;%dm' \
                "$(( 16#${hex:0:2} ))" "$(( 16#${hex:2:2} ))" "$(( 16#${hex:4:2} ))"
        }
        [ -n "$config_blue" ] && set_color blue "$config_blue"
        [ -n "$config_orange" ] && set_color orange "$config_orange"
        [ -n "$config_green" ] && set_color green "$config_green"
        [ -n "$config_cyan" ] && set_color cyan "$config_cyan"
        [ -n "$config_red" ] && set_color red "$config_red"
        [ -n "$config_yellow" ] && set_color yellow "$config_yellow"
        [ -n "$config_white" ] && set_color white "$config_white"
        [ -n "$config_magenta" ] && set_color magenta "$config_magenta"
    fi
fi

block_enabled() {
    case ",$blocks," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

if $ascii_output; then
    sep_char="|"; context_char="ctx"; bar_filled="#"; bar_empty="-"; reset_char="reset"; danger_char="!"
    truncate_char="..."; burn_char="burn"
    effort_low="."; effort_medium=":"; effort_high="+"; effort_xhigh="*"; effort_max="!"
else
    sep_char="│"; context_char="✍️"; bar_filled="●"; bar_empty="○"; reset_char="⟳"; danger_char="⚡"
    truncate_char="…"; burn_char="↗"
    effort_low="◔"; effort_medium="◑"; effort_high="◕"; effort_xhigh="●"; effort_max="●"
fi
sep=" ${dim}${sep_char}${reset} "

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
    for ((i=0; i<filled; i++)); do filled_str+="$bar_filled"; done
    for ((i=0; i<empty; i++)); do empty_str+="$bar_empty"; done

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

# <path> [max-age] → true when the file exists and is younger than max-age.
# An empty path is the "caching is off" case and is never fresh.
cache_is_fresh() {
    cache_readable "$1" || return 1
    local max_age=${2:-$cache_max_age} mtime now
    if [ "$date_flavor" = gnu ]; then
        mtime=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)
    else
        mtime=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null)
    fi
    is_num "$mtime" || return 1
    now=${EPOCHSECONDS:-}
    [ -n "$now" ] || now=$(date +%s)
    [ "$(( now - mtime ))" -lt "$max_age" ]
}

# update_burn_history <pct> <reset-epoch> → $BURN_RATE_TENTHS and $BURN_NOW.
# Samples are minute-spaced, tied to one reset window and capped at five hours.
# A utilization drop starts a new series instead of reporting a negative rate.
update_burn_history() {
    local pct=$1 reset_epoch=$2 now history_source history_tmp result
    BURN_RATE_TENTHS=""
    BURN_NOW=""

    is_num "$pct" && [ "$pct" -le 100 ] || return
    is_num "$reset_epoch" || return
    now=$(date +%s 2>/dev/null)
    is_num "$now" || return
    [ "$reset_epoch" -gt "$now" ] && [ "$(( reset_epoch - now ))" -le 21600 ] || return
    cache_writable "$history_cache" || return

    history_source=/dev/null
    cache_readable "$history_cache" && history_source=$history_cache
    history_tmp=$(mktemp "$cache_dir/.statusline-history.XXXXXX" 2>/dev/null) || return

    result=$(awk -v reset_epoch="$reset_epoch" -v now="$now" -v pct="$pct" \
        -v out="$history_tmp" '
        BEGIN { FS = OFS = sprintf("%c", 31) }
        function integer(value) { return value ~ /^[0-9]+$/ }
        $1 == reset_epoch && integer($2) && integer($3) &&
        $2 >= now - 18000 && $2 <= now && $3 <= 100 {
            if (n == 0 || $2 >= sample_time[n]) {
                n++
                sample_time[n] = $2
                sample_pct[n] = $3
            }
        }
        END {
            if (n > 0 && pct < sample_pct[n]) n = 0
            if (n == 0 || now - sample_time[n] >= 60) {
                n++
                sample_time[n] = now
                sample_pct[n] = pct
            }

            first = n > 301 ? n - 300 : 1
            for (i = first; i <= n; i++)
                print reset_epoch, sample_time[i], sample_pct[i] > out
            close(out)

            elapsed = now - sample_time[first]
            delta = pct - sample_pct[first]
            if (elapsed >= 60 && delta >= 0)
                printf "%d", int(delta * 36000 / elapsed + 0.5)
        }
    ' "$history_source" 2>/dev/null)

    if mv -f "$history_tmp" "$history_cache" 2>/dev/null; then
        is_num "$result" && BURN_RATE_TENTHS=$result
        BURN_NOW=$now
    else
        rm -f "$history_tmp"
    fi
}

# Fetches the usage payload into $USAGE_RESPONSE and warms the shared cache.
# The stdin-rates path runs this in the background; its current render keeps
# using stdin and the next render gets the extra-usage data written here.
refresh_usage_cache() {
    local token="" blob creds_file response cache_tmp
    USAGE_RESPONSE=""

    creds_file="$claude_dir/.credentials.json"

    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        token="$CLAUDE_CODE_OAUTH_TOKEN"
    fi
    # The keychain holds one entry for the whole machine, so a session on a
    # second profile that read it would ask about the account the first profile
    # logged in with. A credentials file inside the profile that session named
    # is the more specific answer and goes first. The default profile keeps the
    # old order: the keychain is where Claude Code writes on macOS, and a
    # .credentials.json an older release left in ~/.claude should not outrank it.
    if [ -z "$token" ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -f "$creds_file" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
    fi
    if { [ -z "$token" ] || [ "$token" = "null" ]; } &&
       command -v security >/dev/null 2>&1; then
        blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(jq -r '.claudeAiOauth.accessToken // empty' <<< "$blob" 2>/dev/null)
        fi
    fi
    if { [ -z "$token" ] || [ "$token" = "null" ]; } && [ -f "$creds_file" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
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
            USAGE_RESPONSE="$response"
            if cache_writable "$cache_file" &&
               cache_tmp=$(mktemp "$cache_dir/.statusline-usage.XXXXXX" 2>/dev/null); then
                if ! printf '%s' "$response" > "$cache_tmp" 2>/dev/null ||
                   ! mv -f "$cache_tmp" "$cache_file" 2>/dev/null; then
                    rm -f "$cache_tmp"
                fi
            fi
        fi
    fi
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
    (.exceeds_200k_tokens == true),
    ((.transcript_path | strings) // "")
] | map(tostring) | join("\u001f")' <<< "$input" 2>/dev/null)

IFS=$'\x1f' read -r model_name size input_tokens cache_create cache_read \
    effort cwd stdin_five_pct stdin_five_reset stdin_seven_pct stdin_seven_reset \
    total_cost_usd total_lines_added total_lines_removed output_style exceeds_200k \
    transcript_path <<< "$fields"

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
if block_enabled effort && [ -z "$effort" ]; then
    settings_path="$claude_dir/settings.json"
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
# A directory that is a symlink, belongs to someone else, or is not private
# turns caching off. The empty paths that leaves fail closed through the cache
# helpers below. Git Bash exposes Windows ACLs as a synthetic 755 regardless of
# chmod, so only the ownership and symlink checks are meaningful there.
cache_dir="${CLAUDE_STATUSLINE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline}"
cache_max_age=60
extra_cache_max_age=300
# `mkdir -p -m` is the case SC2174 warns about — the mode reaches the deepest
# directory only, and MSYS drops it altogether — so set it separately. Only on
# a directory this render created: an existing one keeps whatever mode it has.
if [ ! -d "$cache_dir" ]; then
    mkdir -p "$cache_dir" 2>/dev/null && chmod 700 "$cache_dir" 2>/dev/null
fi
cache_dir_private=false
if [ -d "$cache_dir" ] && [ ! -L "$cache_dir" ] && [ -O "$cache_dir" ]; then
    case "$OSTYPE" in
        msys*|cygwin*) cache_dir_private=true ;;
        *)
            cache_dir_mode=$(stat -c %a "$cache_dir" 2>/dev/null || stat -f %Lp "$cache_dir" 2>/dev/null)
            [ "$cache_dir_mode" = 700 ] && cache_dir_private=true
            ;;
    esac
fi
if $cache_dir_private; then
    cache_file="$cache_dir/statusline-usage-cache.json"
    dirty_cache="$cache_dir/statusline-dirty-cache"
    history_cache="$cache_dir/statusline-usage-history"
else
    cache_file=""
    dirty_cache=""
    history_cache=""
fi

# ── LINE 1: Model │ Context % │ Directory (branch) │ Effort ──
line1=""
append_line1() {
    [ -n "$line1" ] && line1+="$sep"
    line1+="$1"
}

block_enabled model && append_line1 "${blue}${model_name}${reset}"

if block_enabled context; then
    color_for_pct "$pct_used"
    context_block="${context_char} ${COLOR}${pct_used}%${reset}"
    [ "$exceeds_200k" = "true" ] && context_block+=" ${red}>200k${reset}"
    append_line1 "$context_block"
fi

if block_enabled directory; then
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
            # The entry has no trailing newline, so `read` fills the fields and
            # returns non-zero at EOF.
            IFS=$'\x1f' read -r cached_expiry cached_dirty cached_cwd < "$dirty_cache"
            # A stale entry from another directory is a miss, not a wrong star.
            if [ "$cached_cwd" = "$cwd" ] && is_num "$cached_expiry" &&
               [ "$now_s" -lt "$cached_expiry" ]; then
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
        *--dangerously-skip-permissions*) skip_perms="${danger_char}  " ;;
    esac

    directory_block="${skip_perms}${cyan}${dirname}${reset}"
    [ -n "$git_branch" ] &&
        directory_block+=" ${green}(${git_branch}${red}${git_dirty}${green})${reset}"
    append_line1 "$directory_block"
fi

if block_enabled cost && [ -n "$total_cost_usd" ]; then
    printf -v total_cost_fmt "%.2f" "$total_cost_usd"
    append_line1 "${white}\$${total_cost_fmt}${reset}"
fi
if block_enabled changes &&
   { [ "$total_lines_added" -gt 0 ] || [ "$total_lines_removed" -gt 0 ]; }; then
    append_line1 "${green}+${total_lines_added}${reset}${dim}/${reset}${red}-${total_lines_removed}${reset}"
fi
block_enabled style && [ -n "$output_style" ] &&
    append_line1 "${dim}style:${reset}${white}${output_style}${reset}"

# The payload carries no list of the skills a session has loaded, so they come
# out of the transcript, where every invocation is a `Skill` tool call. Reading
# the whole file on every render would cost more than the rest of this script
# put together, so the scan is incremental: the cache entry holds how far the
# last render read and the names it found, and only the bytes appended since
# are looked at. With caching off the file is read in full each time instead.
if block_enabled skills && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    skills_cache=""
    if $cache_dir_private; then
        # The session id names the cache entry, and it arrives from stdin like
        # every other field here, so it has to be a file name and nothing else.
        # Git Bash gets the path Claude Code wrote it, backslashes and all, and
        # reads it happily — but the file name has to come off both separators
        # or the key is rejected below and every render rescans the file.
        skills_key=${transcript_path##*/}
        skills_key=${skills_key##*\\}
        skills_key=${skills_key%.jsonl}
        case "$skills_key" in
            ''|*[!A-Za-z0-9._-]*) skills_key="" ;;
        esac
        [ -n "$skills_key" ] && skills_cache="$cache_dir/statusline-skills-$skills_key"
    fi

    skills_offset=0
    skills_seen=""
    if cache_readable "$skills_cache"; then
        IFS=$'\x1f' read -r cached_offset cached_skills < "$skills_cache"
        is_num "$cached_offset" && skills_offset=$cached_offset
        skills_seen=$cached_skills
    fi

    if [ "$date_flavor" = gnu ]; then
        skills_size=$(stat -c %s "$transcript_path" 2>/dev/null || stat -f %z "$transcript_path" 2>/dev/null)
    else
        skills_size=$(stat -f %z "$transcript_path" 2>/dev/null || stat -c %s "$transcript_path" 2>/dev/null)
    fi
    is_num "$skills_size" || skills_size=0
    # A transcript shorter than where the last render stopped is a different
    # session under a reused name, or a rewritten file; either way the names
    # cached against it no longer describe it.
    if [ "$skills_size" -lt "$skills_offset" ]; then
        skills_offset=0
        skills_seen=""
    fi

    if [ "$skills_size" -gt "$skills_offset" ]; then
        # awk answers with how much of the chunk it consumed as whole lines,
        # so a render that catches the writer mid-line resumes at the start of
        # that line rather than losing its first half.
        skills_scan=$(tail -c "+$(( skills_offset + 1 ))" "$transcript_path" 2>/dev/null |
            awk -v seen="$skills_seen" -v size="$(( skills_size - skills_offset ))" '
                function remember(name,   i) {
                    if (name !~ /^[A-Za-z0-9._:-]+$/) return
                    for (i = 1; i <= n; i++) if (found[i] == name) return
                    found[++n] = name
                    # Cap the list rather than let a long session grow the cache
                    # entry without bound. The oldest names drop out first.
                    if (n > 40) { for (i = 1; i < n; i++) found[i] = found[i + 1]; n-- }
                }
                BEGIN {
                    US = sprintf("%c", 31)
                    count = split(seen, prior, ",")
                    for (i = 1; i <= count; i++) remember(prior[i])
                }
                {
                    last = length($0) + 1
                    bytes += last
                    line = $0
                    while (match(line, /"name":"Skill","input":[{][^}]*"skill":"[^"]*"/)) {
                        # The closing quote is part of the match, so that a
                        # half-written line is not read as a shortened name.
                        name = substr(line, RSTART, RLENGTH)
                        sub(/.*"skill":"/, "", name)
                        sub(/"$/, "", name)
                        remember(name)
                        line = substr(line, RSTART + RLENGTH)
                    }
                }
                END {
                    # Counting a newline the last line never had means the chunk
                    # ended mid-line: hand that line back to the next render.
                    printf "%d%s", (bytes > size ? bytes - last : bytes), US
                    for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? "," : ""), found[i]
                }
            ')
        IFS=$'\x1f' read -r skills_read skills_seen <<< "$skills_scan"
        is_num "$skills_read" || skills_read=0
        skills_offset=$(( skills_offset + skills_read ))
        if cache_writable "$skills_cache"; then
            printf '%s\x1f%s' "$skills_offset" "$skills_seen" > "$skills_cache" 2>/dev/null
        fi
    fi

    if [ -n "$skills_seen" ]; then
        IFS=, read -r -a skills_names <<< "$skills_seen"
        skills_count=${#skills_names[@]}
        skills_shown=$skills_limit
        [ "$skills_shown" -gt "$skills_count" ] && skills_shown=$skills_count
        skills_text=""
        for (( i = skills_count - skills_shown; i < skills_count; i++ )); do
            [ -n "$skills_text" ] && skills_text+=","
            skills_text+=${skills_names[i]}
        done
        skills_block="${dim}skills:${reset}${white}${skills_text}${reset}"
        [ "$skills_count" -gt "$skills_shown" ] &&
            skills_block+=" ${dim}+$(( skills_count - skills_shown ))${reset}"
        append_line1 "$skills_block"
    fi
fi

if block_enabled effort && [ -n "$effort" ]; then
    case "$effort" in
        max)    effort_block="${orange}${effort_max} ${effort}${reset}" ;;
        xhigh)  effort_block="${magenta}${effort_xhigh} ${effort}${reset}" ;;
        high)   effort_block="${magenta}${effort_high} ${effort}${reset}" ;;
        medium) effort_block="${dim}${effort_medium} ${effort}${reset}" ;;
        low)    effort_block="${dim}${effort_low} ${effort}${reset}" ;;
        *)      effort_block="${dim}${effort_medium} ${effort}${reset}" ;;
    esac
    append_line1 "$effort_block"
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
usage_requested=false
extra_requested=false
rate_blocks_requested=false
block_enabled extra && extra_requested=true
if block_enabled current || block_enabled weekly; then rate_blocks_requested=true; fi
if $extra_requested || { ! $has_stdin_rates && $rate_blocks_requested; }; then
    usage_requested=true
fi

if $usage_requested && ! $has_stdin_rates; then
    needs_refresh=true

    if cache_is_fresh "$cache_file"; then
        needs_refresh=false
        usage_data=$(<"$cache_file")
    fi

    if $needs_refresh; then
        refresh_usage_cache
        usage_data=$USAGE_RESPONSE
        if [ -z "$usage_data" ] && cache_readable "$cache_file"; then
            # The refresh failed — no token, or the call did not come back. A
            # rate-limit bar that is behind still says something, and the reset
            # time it renders alongside dates it, so the last known body beats
            # blanking the whole block. What it is too old for is below.
            usage_data=$(<"$cache_file")
            usage_stale=true
        fi
    fi
elif $extra_requested && cache_is_fresh "$cache_file" "$extra_cache_max_age"; then
    # stdin already carried the rate limits; the cache is only still worth
    # reading for the extra-usage block, which stdin does not report.
    usage_data=$(<"$cache_file")
elif $extra_requested && cache_writable "$cache_file"; then
    refresh_usage_cache </dev/null >/dev/null 2>&1 &
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

# The five-hour reset identifies the active window. One sample is not a rate;
# the indicator appears after at least a minute of history has accumulated.
BURN_RATE_TENTHS=""
if block_enabled current && block_enabled burn; then
    update_burn_history "$five_hour_pct" "$five_hour_reset_epoch"
fi
burn_rate=""
burn_color=$green
if is_num "$BURN_RATE_TENTHS"; then
    printf -v burn_rate "%d.%d" "$(( BURN_RATE_TENTHS / 10 ))" "$(( BURN_RATE_TENTHS % 10 ))"
    projected_pct_tenths=$(( five_hour_pct * 10 +
        BURN_RATE_TENTHS * (five_hour_reset_epoch - BURN_NOW) / 3600 ))
    if [ "$projected_pct_tenths" -ge 1000 ]; then
        burn_color=$red
    elif [ "$projected_pct_tenths" -ge 900 ]; then
        burn_color=$yellow
    fi
fi

# ── Rate limit lines ────────────────────────────────────
rate_lines=""

if block_enabled current && [ -n "$five_hour_pct" ]; then
    format_epoch_time "$five_hour_reset_epoch" "time"
    five_hour_reset=$FMT_TIME
    build_bar "$five_hour_pct" "$bar_width"
    printf -v five_hour_pct_fmt "%3d" "$five_hour_pct"

    rate_lines+="${white}current${reset} ${BAR} ${COLOR}${five_hour_pct_fmt}%${reset}"
    block_enabled burn && [ -n "$burn_rate" ] &&
        rate_lines+=" ${burn_color}${burn_char} ${burn_rate}%/h${reset}"
    [ -n "$five_hour_reset" ] && rate_lines+=" ${dim}${reset_char}${reset} ${white}${five_hour_reset}${reset}"
fi

if block_enabled weekly && [ -n "$seven_day_pct" ]; then
    format_epoch_time "$seven_day_reset_epoch" "datetime"
    seven_day_reset=$FMT_TIME
    build_bar "$seven_day_pct" "$bar_width"
    printf -v seven_day_pct_fmt "%3d" "$seven_day_pct"

    [ -n "$rate_lines" ] && rate_lines+="\n"
    rate_lines+="${white}weekly${reset}  ${BAR} ${COLOR}${seven_day_pct_fmt}%${reset}"
    [ -n "$seven_day_reset" ] && rate_lines+=" ${dim}${reset_char}${reset} ${white}${seven_day_reset}${reset}"
fi

if block_enabled extra && [ "$extra_enabled" = "true" ]; then
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
    [ -n "$extra_reset" ] && rate_lines+=" ${dim}${reset_char}${reset} ${white}${extra_reset}${reset}"
fi

# ── Output ──────────────────────────────────────────────
print_output() {
    [ -n "$line1" ] && printf "%b" "$line1"
    if [ -n "$rate_lines" ]; then
        [ -n "$line1" ] && printf "\n\n"
        printf "%b" "$rate_lines"
    fi
}

if is_num "${COLUMNS:-}" && [ "$COLUMNS" -gt 0 ]; then
    # SGR color sequences and combining marks take no terminal columns; CJK and
    # emoji take two. The final reset prevents a truncated colored block from
    # bleeding into the terminal.
    output=$(print_output)
    truncated=$(printf "%s" "$output" | jq -Rrsj --argjson limit "$COLUMNS" --arg marker "$truncate_char" '
        def ansi: startswith("\u001b");
        def cell_width:
            if test("^[\\p{M}\\p{Cf}]$") then 0
            else
                explode[0] as $cp
                | if (($cp >= 4352 and $cp <= 4447)
                      or $cp == 9001 or $cp == 9002
                      or ($cp >= 11904 and $cp <= 42191 and $cp != 12351)
                      or ($cp >= 44032 and $cp <= 55203)
                      or ($cp >= 63744 and $cp <= 64255)
                      or ($cp >= 65040 and $cp <= 65049)
                      or ($cp >= 65072 and $cp <= 65135)
                      or ($cp >= 65280 and $cp <= 65376)
                      or ($cp >= 65504 and $cp <= 65510)
                      or ($cp >= 9728 and $cp <= 10175)
                      or ($cp >= 127744 and $cp <= 129791)
                      or ($cp >= 131072 and $cp <= 262141))
                  then 2 else 1 end
            end;
        def width:
            map(if ansi then 0 else cell_width end) | add // 0;
        def take_cells($max):
            reduce .[] as $token (
                {text: "", width: 0, cut: false};
                if .cut then .
                elif ($token | ansi) then .text += $token
                else ($token | cell_width) as $width
                     | if .width + $width <= $max then
                           .text += $token | .width += $width
                       else .cut = true end
                end
            ) | .text;
        def truncate:
            [scan("\u001b\\[[0-9;]*m|.")] as $tokens
            | ($tokens | width) as $visible
            | if $visible <= $limit then .
              else
                  ([ $marker | scan(".") ] | take_cells($limit)) as $suffix
                  | ([ $suffix | scan(".") ] | width) as $suffix_width
                  | ($tokens | take_cells($limit - $suffix_width))
                    + $suffix + "\u001b[0m"
              end;

        split("\n") | map(truncate) | join("\n")
    ') || truncated=""
    if [ -n "$truncated" ] || [ -z "$output" ]; then
        printf "%s" "$truncated"
    else
        printf "%s" "$output"
    fi
else
    print_output
fi

exit 0
