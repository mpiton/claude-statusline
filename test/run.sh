#!/bin/bash
# Tests for bin/statusline.sh — feed a statusline JSON payload on stdin, compare
# the rendered output against an expectation.
#
#   test/run.sh              run everything
#   test/run.sh locale       run cases whose name contains "locale"
#
# Determinism: TZ is pinned to UTC, HOME points at a sandbox, the usage cache
# lives in a temp dir, and curl/secret-tool/security are stubbed out on PATH so
# no case can reach the network or the real keychain.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STATUSLINE="$ROOT/bin/statusline.sh"
FILTER="${1:-}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export TZ=UTC
unset CLAUDE_CODE_OAUTH_TOKEN GIT_DIR GIT_WORK_TREE XDG_CACHE_HOME
export GIT_CEILING_DIRECTORIES="$TMP"

green='\033[32m'; red='\033[31m'; yellow='\033[33m'; dim='\033[2m'; reset='\033[0m'
passed=0; failed=0; skipped=0

# ── Sandbox ─────────────────────────────────────────────

# Stubs shadow the real binaries so the API fallback can never hit the network.
# curl prints $STUB_CURL_BODY when a case sets it, otherwise fails like a timeout.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
if [ -n "${STUB_CURL_GATE:-}" ]; then
    [ -n "${STUB_CURL_WAITING:-}" ] && : > "$STUB_CURL_WAITING"
    for _ in {1..600}; do
        [ -f "$STUB_CURL_GATE" ] && break
        sleep 0.05
    done
    if [ ! -f "$STUB_CURL_GATE" ]; then
        [ -n "${STUB_CURL_TIMED_OUT:-}" ] && : > "$STUB_CURL_TIMED_OUT"
        exit 7
    fi
fi
if [ -n "${STUB_CURL_BODY:-}" ] && [ -f "$STUB_CURL_BODY" ]; then
    cat "$STUB_CURL_BODY"
    exit 0
fi
exit 7
EOF
for stub in secret-tool security; do
    printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/$stub"
done
chmod +x "$TMP/bin"/*
export PATH="$TMP/bin:$PATH"

export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
echo '{}' > "$HOME/.claude/settings.json"

export CLAUDE_STATUSLINE_CACHE_DIR="$TMP/cache"
mkdir -m 700 "$CLAUDE_STATUSLINE_CACHE_DIR"
CACHE_FILE="$CLAUDE_STATUSLINE_CACHE_DIR/statusline-usage-cache.json"

REPO_CLEAN="$TMP/repo-clean"
REPO_DIRTY="$TMP/repo-dirty"
PLAIN_DIR="$TMP/plain"
mkdir -p "$PLAIN_DIR"
for repo in "$REPO_CLEAN" "$REPO_DIRTY"; do
    git init -q "$repo"
    git -C "$repo" symbolic-ref HEAD refs/heads/main
done
touch "$REPO_DIRTY/untracked.txt"

# A parent process whose argv carries the flag, so the ⚡ detection has something
# to find in `ps -o args= -p $PPID`.
cat > "$TMP/parent.sh" <<EOF
#!/bin/bash
bash "$STATUSLINE"
EOF

# ── Harness ─────────────────────────────────────────────

# Base payload; the argument is a jq expression applied on top of it.
payload() {
    jq -cn --arg cwd "$REPO_CLEAN" '{
        model: {display_name: "Opus 5"},
        cwd: $cwd,
        context_window: {
            context_window_size: 200000,
            current_usage: {
                input_tokens: 1000,
                output_tokens: 500,
                cache_creation_input_tokens: 3000,
                cache_read_input_tokens: 46000
            }
        },
        rate_limits: {
            five_hour: {used_percentage: 42.3, resets_at: 1786000000},
            seven_day: {used_percentage: 18.7, resets_at: 1786400000}
        }
    }' | jq -c "${1:-.}"
}

strip_ansi() { sed $'s/\033\\[[0-9;]*m//g'; }

STDOUT=""; LINE1=""; RAW1=""; STDERR=""; STATUS=0
# Renders a payload. Leaves the ANSI-stripped output in $STDOUT, its first line
# in $LINE1, that same line with colors intact in $RAW1, stderr in $STDERR and
# the exit code in $STATUS. Extra args are `env` assignments for the run.
render() {
    local input="$1" raw; shift
    raw=$(printf '%s' "$input" | env "$@" bash "$STATUSLINE" 2>"$TMP/stderr")
    # shellcheck disable=SC2034  # part of render()'s output contract, for cases to read.
    STATUS=$?
    STDERR=$(cat "$TMP/stderr")
    RAW1=$(printf '%s' "$raw" | head -1)
    STDOUT=$(printf '%s' "$raw" | strip_ansi)
    LINE1=$(printf '%s' "$STDOUT" | head -1)
}

report_fail() {
    printf "  ${red}✗${reset} %s\n" "$1"
    printf "    ${dim}expected:${reset} %s\n" "$2"
    printf "    ${dim}actual:  ${reset} %s\n" "$3"
    [ -n "$STDERR" ] && printf "    ${dim}stderr:  ${reset} %s\n" "$STDERR"
    failed=$((failed + 1))
}

report_pass() {
    printf "  ${green}✓${reset} %s\n" "$1"
    passed=$((passed + 1))
}

selected() {
    [ -z "$FILTER" ] && return 0
    case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac
}

skip() {
    selected "$1" || return 0
    printf "  ${yellow}−${reset} %s ${dim}(%s)${reset}\n" "$1" "$2"
    skipped=$((skipped + 1))
}

# assert <name> <expected> — exact match against the whole stripped output.
assert() {
    selected "$1" || return 0
    if [ "$STDOUT" = "$2" ]; then report_pass "$1"; else report_fail "$1" "$(printf '%q' "$2")" "$(printf '%q' "$STDOUT")"; fi
}

# assert_re <name> <regex> — for output holding a value that moves with the
# calendar or the terminal.
assert_re() {
    selected "$1" || return 0
    if [[ "$STDOUT" =~ $2 ]]; then report_pass "$1"; else report_fail "$1" "=~ $2" "$(printf '%q' "$STDOUT")"; fi
}

# Line-1 variants. `$` in a bash regex anchors the end of the whole string, so
# matching a trailing segment of the first line needs that line on its own.
assert_line1_re() {
    selected "$1" || return 0
    if [[ "$LINE1" =~ $2 ]]; then report_pass "$1"; else report_fail "$1" "=~ $2" "$(printf '%q' "$LINE1")"; fi
}

# assert_color <name> <ansi-prefixed-text> — colors survive ANSI stripping only
# here, where the escape itself is the thing under test.
assert_color() {
    selected "$1" || return 0
    case "$RAW1" in
        *"$2"*) report_pass "$1" ;;
        *) report_fail "$1" "contains $(printf '%q' "$2")" "$(printf '%q' "$RAW1")" ;;
    esac
}

# assert_dir <name> <path> — the directory a render was supposed to create.
assert_dir() {
    selected "$1" || return 0
    if [ -d "$2" ]; then report_pass "$1"; else report_fail "$1" "directory $2" "$(ls -ld "$2" 2>&1)"; fi
}

# assert_file <name> <path> <contents> — a file a render was not supposed to touch.
assert_file() {
    selected "$1" || return 0
    local got
    got=$(cat "$2" 2>&1)
    if [ "$got" = "$3" ]; then report_pass "$1"; else report_fail "$1" "$3" "$got"; fi
}

dir_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }

# assert_mode <name> <path> <octal>
assert_mode() {
    selected "$1" || return 0
    local mode
    mode=$(dir_mode "$2")
    if [ "$mode" = "$3" ]; then report_pass "$1"; else report_fail "$1" "mode $3" "mode ${mode:-unknown}"; fi
}

assert_no_stderr() {
    selected "$1" || return 0
    if [ -z "$STDERR" ]; then report_pass "$1"; else report_fail "$1" "(empty stderr)" "$(printf '%q' "$STDERR")"; fi
}

# Headers would sit above nothing once a filter drops their cases, so a filtered
# run prints a flat list instead.
section() { [ -n "$FILTER" ] || printf "\n${dim}%s${reset}\n" "$1"; }

# Renders share one cache; seed or clear it explicitly per case.
seed_cache() { printf '%s' "$1" > "$CACHE_FILE"; }
clear_cache() { rm -f "$CACHE_FILE"; }
wait_for_file() {
    local path=$1
    for _ in {1..600}; do
        [ -f "$path" ] && return 0
        sleep 0.05
    done
    return 1
}

RATES_5H="current ●●●●○○○○○○  42% ⟳ 7:06am"
RATES_7D="weekly  ●○○○○○○○○○  19% ⟳ aug 10, 10:13pm"
RATES="$RATES_5H
$RATES_7D"

# ── Cases ───────────────────────────────────────────────

section "input"

render ""
assert "empty stdin falls back to a bare name" "Claude"

clear_cache
render "$(payload)"
assert "renders model, context, repo and rate limits" "Opus 5 │ ✍️ 25% │ repo-clean (main)

$RATES"

render "$(payload '.cwd = "'"$PLAIN_DIR"'"')"
assert "no git segment outside a repo" "Opus 5 │ ✍️ 25% │ plain

$RATES"

render "$(payload '.cwd = "'"$REPO_DIRTY"'"')"
assert "dirty worktree gets a star" "Opus 5 │ ✍️ 25% │ repo-dirty (main*)

$RATES"

# The dirty flag is cached to skip a worktree walk per render. Each case seeds
# the entry rather than inheriting one from the case above: leaving it to
# residue would let these pass on a slow runner, where the real entry has
# expired before the render that is supposed to reject it. The expiry is far
# enough out that no case has to reason about the clock.
LEAK="a cached dirty flag does not leak into another directory"
LEAK2="nor does a cached clean flag"
CACHED="a cached flag is reused within its own directory"
EXPIRED="an expired entry is ignored"
CORRUPT="a corrupt entry is ignored"
CORRUPT_QUIET="a corrupt entry does not warn"
DIRTY_CACHE="$CLAUDE_STATUSLINE_CACHE_DIR/statusline-dirty-cache"
rm -f "$DIRTY_CACHE"
render "$(payload)"

if [ ! -f "$DIRTY_CACHE" ]; then
    # No $EPOCHSECONDS means no clock to expire an entry on, so the script
    # never writes one and the whole feature is off. Nothing to seed against.
    for name in "$LEAK" "$LEAK2" "$CACHED" "$EXPIRED" "$CORRUPT" "$CORRUPT_QUIET"; do
        skip "$name" "no dirty-flag cache before bash 5"
    done
else
    # Seed against the directory as the script spelled it, read back from the
    # entry it just wrote. Under Git Bash the cwd it receives comes back
    # MSYS-rewritten (`C:/Users/RUNNER~1/...`) whichever way the payload
    # carries it, so a path spelled by hand here would key the entry on a
    # directory the lookup never asks about, and every case would read as a
    # miss.
    IFS=$'\x1f' read -r _ _ SEEN_CWD < "$DIRTY_CACHE"
    seed_dirty() { printf '%s\x1f%s\x1f%s' 9999999999 "$1" "$2" > "$DIRTY_CACHE"; }

    seed_dirty '*' "$SEEN_CWD/elsewhere"
    render "$(payload)"
    assert "$LEAK" "Opus 5 │ ✍️ 25% │ repo-clean (main)

$RATES"

    seed_dirty '' "$SEEN_CWD"
    render "$(payload '.cwd = "'"$REPO_DIRTY"'"')"
    assert "$LEAK2" "Opus 5 │ ✍️ 25% │ repo-dirty (main*)

$RATES"

    # The other half: a cache nothing reads would pass both cases above. A
    # clean worktree printing a star can only come from the cached entry.
    seed_dirty '*' "$SEEN_CWD"
    render "$(payload)"
    assert "$CACHED" "Opus 5 │ ✍️ 25% │ repo-clean (main*)

$RATES"

    # An entry past its expiry is a miss. Seeding one dead on arrival tests the
    # clock without a case having to wait out the real two-second window.
    printf '%s\x1f%s\x1f%s' 1 '*' "$SEEN_CWD" > "$DIRTY_CACHE"
    render "$(payload)"
    assert "$EXPIRED" "Opus 5 │ ✍️ 25% │ repo-clean (main)

$RATES"

    # A half-written entry is a miss too, and the expiry compare must not warn
    # about the garbage it was handed.
    printf '%s\x1f%s\x1f%s' 'nope' '*' "$SEEN_CWD" > "$DIRTY_CACHE"
    render "$(payload)"
    assert "$CORRUPT" "Opus 5 │ ✍️ 25% │ repo-clean (main)

$RATES"
    assert_no_stderr "$CORRUPT_QUIET"
fi
rm -f "$DIRTY_CACHE"

render "$(payload 'del(.model)')"
assert_line1_re "missing model falls back to Claude" '^Claude │'

section "context window"

render "$(payload '.context_window.current_usage.cache_read_input_tokens = 196000')"
assert_line1_re "context percentage tracks token usage" '✍️ 100%'

render "$(payload '.context_window.context_window_size = 0')"
assert_line1_re "zero window size falls back to 200k" '✍️ 25%'

# A size of the wrong type used to survive the `-eq 0` guard — the test errors
# out instead of comparing, the fallback never fires, and the percentage silently
# reads 0 for the rest of the render.
render "$(payload '.context_window.context_window_size = "wide"')"
assert_line1_re "a non-numeric window size falls back to 200k" '✍️ 25%'
assert_no_stderr "a non-numeric window size does not warn"

render "$(payload '.context_window.current_usage.cache_read_input_tokens = 46000')"
assert_color "context under 50% is green" $'\033[38;2;0;175;80m25%'

render "$(payload '.context_window.current_usage.cache_read_input_tokens = 116000')"
assert_color "context over 50% is orange" $'\033[38;2;255;176;85m60%'

render "$(payload '.context_window.current_usage.cache_read_input_tokens = 146000')"
assert_color "context over 70% is yellow" $'\033[38;2;230;200;0m75%'

render "$(payload '.context_window.current_usage.cache_read_input_tokens = 186000')"
assert_color "context over 90% is red" $'\033[38;2;255;85;85m95%'

section "session metrics"

render "$(payload '.cost = {
    total_cost_usd: 1.236,
    total_lines_added: 12,
    total_lines_removed: 3
} | .output_style.name = "Explanatory" | .exceeds_200k_tokens = true')"
assert "renders cost, changed lines, output style and the 200k warning" "Opus 5 │ ✍️ 25% >200k │ repo-clean (main) │ \$1.24 │ +12/-3 │ style:Explanatory

$RATES"

render "$(payload '.cost = {
    total_cost_usd: 0,
    total_lines_added: 0,
    total_lines_removed: 0
} | .output_style.name = "default"')"
assert "zero cost and the default output style still render" \
    "Opus 5 │ ✍️ 25% │ repo-clean (main) │ \$0.00 │ style:default

$RATES"

section "effort"

# An alternation, not a bracket expression: Git Bash matches bracket sets byte
# by byte, and each of these glyphs is three bytes.
for level in low medium high xhigh max; do
    render "$(payload ".effort.level = \"$level\"")"
    assert_line1_re "effort $level comes from stdin" "│ (◔|◑|◕|●) $level\$"
done

echo '{"effortLevel":"high"}' > "$HOME/.claude/settings.json"
render "$(payload)"
assert_line1_re "effort falls back to settings.json when stdin omits it" '│ ◕ high$'

render "$(payload '.effort.level = "low"')"
assert_line1_re "stdin effort wins over settings.json" '│ ◔ low$'

echo '{}' > "$HOME/.claude/settings.json"
render "$(payload)"
assert_line1_re "effort segment is dropped when no source has one" 'repo-clean \(main\)$'

section "rate limits from stdin"

render "$(payload 'del(.rate_limits)')"
assert "no rate limits and no cache means no extra lines" "Opus 5 │ ✍️ 25% │ repo-clean (main)"

render "$(payload '.rate_limits.five_hour.used_percentage = 87.6 | del(.rate_limits.seven_day)')"
assert "seven-day line is skipped when absent" "Opus 5 │ ✍️ 25% │ repo-clean (main)

current ●●●●●●●●○○  88% ⟳ 7:06am"

render "$(payload '.rate_limits.five_hour.used_percentage = 42.3')"
assert_no_stderr "fractional percentages do not warn"

# A reset time of 0 or null means "unknown", not "midnight 1970".
for missing in 0 null; do
    render "$(payload ".rate_limits.five_hour.resets_at = $missing | del(.rate_limits.seven_day)")"
    assert "a $missing reset time drops the ⟳ suffix" "Opus 5 │ ✍️ 25% │ repo-clean (main)

current ●●●●○○○○○○  42%"
done

section "rate limits from the API cache"

API_BODY='{"five_hour":{"utilization":42.3,"resets_at":"2026-08-06T07:06:40Z"},
           "seven_day":{"utilization":18.7,"resets_at":"2026-08-10T22:13:20Z"},
           "extra_usage":{"is_enabled":false}}'

seed_cache "$API_BODY"
render "$(payload 'del(.rate_limits)')"
assert "a fresh cache supplies rate limits with ISO reset times" "Opus 5 │ ✍️ 25% │ repo-clean (main)

$RATES"

printf '%s' "$API_BODY" > "$TMP/api-response.json"
clear_cache
render "$(payload 'del(.rate_limits)')" \
    CLAUDE_CODE_OAUTH_TOKEN=test-token STUB_CURL_BODY="$TMP/api-response.json"
assert "a cold cache fetches from the API" "Opus 5 │ ✍️ 25% │ repo-clean (main)

$RATES"

selected "the fetched response is written to the cache" && {
    if [ -f "$CACHE_FILE" ] && jq -e '.five_hour' "$CACHE_FILE" >/dev/null 2>&1; then
        report_pass "the fetched response is written to the cache"
    else
        report_fail "the fetched response is written to the cache" "cache holds .five_hour" "$(cat "$CACHE_FILE" 2>&1)"
    fi
}

clear_cache
render "$(payload 'del(.rate_limits)')" CLAUDE_CODE_OAUTH_TOKEN=test-token
assert "a failing API call degrades to no rate lines" "Opus 5 │ ✍️ 25% │ repo-clean (main)"

# On the path that does refresh, a stale cache means refetch rather than reuse.
# The seeded body reads 99% with no weekly line, so reusing it would show.
seed_cache '{"five_hour":{"utilization":99,"resets_at":"2026-08-06T07:06:40Z"}}'
touch -t 200001010000 "$CACHE_FILE"
render "$(payload 'del(.rate_limits)')" \
    CLAUDE_CODE_OAUTH_TOKEN=test-token STUB_CURL_BODY="$TMP/api-response.json"
assert "a stale cache is refetched, not reused" "Opus 5 │ ✍️ 25% │ repo-clean (main)

$RATES"

EXTRA_BODY='{"five_hour":{"utilization":42.3,"resets_at":"2026-08-06T07:06:40Z"},
             "extra_usage":{"is_enabled":true,"utilization":30,"used_credits":1234,"monthly_limit":5000}}'

seed_cache "$EXTRA_BODY"
render "$(payload 'del(.rate_limits)')"
# shellcheck disable=SC2016  # `\$` and `$` are regex, not shell expansions.
assert_re "extra usage renders credits against the monthly limit" \
    'extra   ●●●○○○○○○○ \$12\.34/\$50\.00 ⟳ [a-z]{3} 1$'

# Extra usage is the one thing stdin never reports, so the cache is still read
# when stdin covered the rate limits.
seed_cache "$EXTRA_BODY"
render "$(payload)"
# shellcheck disable=SC2016  # `\$` and `$` are regex, not shell expansions.
assert_re "extra usage rides alongside rate limits from stdin" \
    'extra   ●●●○○○○○○○ \$12\.34/\$50\.00'

# A cold cache on the stdin-rates path cannot supply extra usage yet, but it
# should be warmed for the next render without making the current one wait.
ASYNC_CACHE="stdin rate limits warm a cold extra-usage cache"
if selected "$ASYNC_CACHE"; then
    printf '%s' "$EXTRA_BODY" > "$TMP/extra-response.json"
    clear_cache
    (
        render "$(payload)" CLAUDE_CODE_OAUTH_TOKEN=test-token \
            STUB_CURL_BODY="$TMP/extra-response.json" STUB_CURL_GATE="$TMP/curl-release" \
            STUB_CURL_WAITING="$TMP/curl-waiting" STUB_CURL_TIMED_OUT="$TMP/curl-timeout"
        printf '%s' "$STDOUT" > "$TMP/async-render-output"
    ) &
    render_pid=$!

    curl_waiting=false
    wait_for_file "$TMP/curl-waiting" && curl_waiting=true
    wait "$render_pid"
    render_finished=false
    if [ "$curl_waiting" = true ] && [ ! -f "$TMP/curl-timeout" ]; then
        render_finished=true
    fi
    : > "$TMP/curl-release"

    cache_warmed=false
    if [ "$render_finished" = true ] && wait_for_file "$CACHE_FILE" &&
       jq -e '.extra_usage.is_enabled == true' "$CACHE_FILE" >/dev/null 2>&1; then
        cache_warmed=true
    fi
    async_output=$(<"$TMP/async-render-output")
    expected_async="Opus 5 │ ✍️ 25% │ repo-clean (main)

$RATES"
    if [ "$render_finished" = true ] && [ "$async_output" = "$expected_async" ] &&
       [ "$cache_warmed" = true ]; then
        report_pass "$ASYNC_CACHE"
    else
        report_fail "$ASYNC_CACHE" \
            "render finishes with stdin rates before release, then cache warms" \
            "finished=$render_finished output=$(printf '%q' "$async_output") cache=$(cat "$CACHE_FILE" 2>&1)"
    fi
fi

# Nothing on that path ever refreshes the cache, so an unbounded-age read put
# credit amounts on screen from whenever the last refreshing render happened to
# run. Currency of unknown age reads as current, so a stale cache drops the
# line instead.
seed_cache "$EXTRA_BODY"
touch -t 200001010000 "$CACHE_FILE"
render "$(payload)"
assert "a stale cache drops the extra-usage line" "Opus 5 │ ✍️ 25% │ repo-clean (main)

$RATES"

# Same body on the path that does refresh, with the refresh failing (no token to
# make the call with). Falling back to the cache is the point — a bar behind by
# some minutes still says something, and the reset time next to it dates it. The
# credits have nothing dating them, so they are what the fallback drops.
STALE_BODY='{"five_hour":{"utilization":42.3,"resets_at":"2026-08-06T07:06:40Z"},
             "seven_day":{"utilization":18.7,"resets_at":"2026-08-10T22:13:20Z"},
             "extra_usage":{"is_enabled":true,"utilization":30,"used_credits":1234,"monthly_limit":5000}}'
seed_cache "$STALE_BODY"
touch -t 200001010000 "$CACHE_FILE"
render "$(payload 'del(.rate_limits)')"
assert "a failed refresh keeps the stale bars and drops the stale credits" \
    "Opus 5 │ ✍️ 25% │ repo-clean (main)

$RATES"

seed_cache 'not json at all'
render "$(payload)"
assert "a corrupt cache does not break the render" "Opus 5 │ ✍️ 25% │ repo-clean (main)

$RATES"
clear_cache

section "cache directory"

# Both defaults are derived rather than passed in, so these cases drop the
# override the rest of the suite runs with.
DEFAULT_CACHE_DIR="$HOME/.cache/claude-statusline"
rm -rf "$HOME/.cache"
render "$(payload)" -u CLAUDE_STATUSLINE_CACHE_DIR
assert_dir "the cache lands under \$HOME/.cache by default" "$DEFAULT_CACHE_DIR"

# NTFS under Git Bash reports 755 whatever mkdir was asked for, so probe the
# filesystem with a directory of our own before holding the script to it.
PRIVATE="a created cache directory is private"
mkdir -m 700 "$TMP/mode-probe"
if [ "$(dir_mode "$TMP/mode-probe")" = 700 ]; then
    assert_mode "$PRIVATE" "$DEFAULT_CACHE_DIR" 700
else
    skip "$PRIVATE" "no POSIX modes on this filesystem"
fi

NONPRIVATE="a non-private cache directory is refused"
NONPRIVATE_DIR="$TMP/nonprivate"
mkdir -m 700 "$NONPRIVATE_DIR"
chmod 777 "$NONPRIVATE_DIR"
if [ "$(dir_mode "$NONPRIVATE_DIR")" = 777 ]; then
    printf '%s' "$API_BODY" > "$NONPRIVATE_DIR/statusline-usage-cache.json"
    render "$(payload 'del(.rate_limits)')" CLAUDE_STATUSLINE_CACHE_DIR="$NONPRIVATE_DIR"
    assert "$NONPRIVATE" "Opus 5 │ ✍️ 25% │ repo-clean (main)"
else
    skip "$NONPRIVATE" "no POSIX modes on this filesystem"
fi

rm -rf "$TMP/xdg"
render "$(payload)" -u CLAUDE_STATUSLINE_CACHE_DIR XDG_CACHE_HOME="$TMP/xdg"
assert_dir "XDG_CACHE_HOME moves it" "$TMP/xdg/claude-statusline"

# The shared-/tmp attack in miniature: a directory someone else can point
# elsewhere is not written into and not read back. Without the guard the seeded
# cache behind the link would supply the rate lines this expects to be missing.
LINK_TARGET="$TMP/link-target"
mkdir -p "$LINK_TARGET"
printf '%s' "$API_BODY" > "$LINK_TARGET/statusline-usage-cache.json"
SYMLINKED="a symlinked cache directory is refused"
# Git Bash makes something `ln -s` calls a link and `-L` agrees with, which a
# child handed the path through the environment no longer sees as one. Probe
# under the conditions the render runs in rather than the ones here.
# shellcheck disable=SC2016  # $L expands in the child, which is the whole point.
sees_symlink() { [ "$(env L="$1" bash -c '[ -L "$L" ] && echo yes')" = yes ]; }
if ln -s "$LINK_TARGET" "$TMP/link" 2>/dev/null && sees_symlink "$TMP/link"; then
    render "$(payload 'del(.rate_limits)')" CLAUDE_STATUSLINE_CACHE_DIR="$TMP/link"
    assert "$SYMLINKED" "Opus 5 │ ✍️ 25% │ repo-clean (main)"
else
    skip "$SYMLINKED" "no symlink support here"
fi

# The other half, and the case the move is for: a directory someone else owns
# holding a cache file this user can still write. /tmp is that directory on any
# multi-user host — which is what the old default sat in. Skipped where /tmp is
# this user's own (Git Bash) or a symlink the case above already covers (macOS).
FOREIGN="a cache directory owned by someone else is refused"
FOREIGN_CACHE="/tmp/statusline-usage-cache.json"
if [ -O /tmp ] || [ -L /tmp ]; then
    skip "$FOREIGN" "/tmp is not another user's here"
# This fixture writes a predictable name into a directory anyone can write, so
# it is open to the very trick it exists to test: whatever already sits at that
# path could be someone else's symlink pointing at a file this user owns.
# `noclobber` opens with O_EXCL, so either nothing is there or there is no
# fixture. Anything left behind by a killed run skips the case rather than
# being cleared, since by then it is no longer ours to judge.
elif ! (set -o noclobber; printf '%s' "$API_BODY" > "$FOREIGN_CACHE") 2>/dev/null; then
    skip "$FOREIGN" "$FOREIGN_CACHE is not ours to create"
else
    render "$(payload 'del(.rate_limits)')" CLAUDE_STATUSLINE_CACHE_DIR=/tmp
    assert "$FOREIGN" "Opus 5 │ ✍️ 25% │ repo-clean (main)"
    rm -f "$FOREIGN_CACHE"
fi

# A directory clearing every check above can still hold a file that did not come
# from here: it may predate this script, or CLAUDE_STATUSLINE_CACHE_DIR may point
# somewhere the caller left group-writable. So the files get checked too.
PLANTED_LINK="a symlinked cache file is not read"
PLANTED_WRITE="nor written through"
PLANTED_DIR="$TMP/planted"
PLANTED_TARGET="$TMP/planted-target.json"
mkdir -m 700 "$PLANTED_DIR"
printf '%s' "$API_BODY" > "$PLANTED_TARGET"
if ln -sf "$PLANTED_TARGET" "$PLANTED_DIR/statusline-usage-cache.json" 2>/dev/null &&
   sees_symlink "$PLANTED_DIR/statusline-usage-cache.json"; then
    # Without the read guard the body behind the link supplies these rate lines.
    render "$(payload 'del(.rate_limits)')" CLAUDE_STATUSLINE_CACHE_DIR="$PLANTED_DIR"
    assert "$PLANTED_LINK" "Opus 5 │ ✍️ 25% │ repo-clean (main)"

    # And the more damaging half: a refresh that succeeds would truncate whatever
    # the link points at. Here that is a file of ours; in the real version of this
    # it is whichever of the user's files the attacker named.
    printf 'not the cache' > "$PLANTED_TARGET"
    render "$(payload 'del(.rate_limits)')" CLAUDE_STATUSLINE_CACHE_DIR="$PLANTED_DIR" \
        CLAUDE_CODE_OAUTH_TOKEN=test-token STUB_CURL_BODY="$TMP/api-response.json"
    assert_file "$PLANTED_WRITE" "$PLANTED_TARGET" 'not the cache'
else
    skip "$PLANTED_LINK" "no symlink support here"
    skip "$PLANTED_WRITE" "no symlink support here"
fi

section "locale"

# Regression: bash printf rejects "42.3" and date drops am/pm under a locale
# whose decimal separator is a comma, unless the script forces LC_ALL=C.
COMMA_LOCALE=""
for candidate in $(locale -a 2>/dev/null); do
    if ! LC_ALL="$candidate" printf '%.0f' 42.3 >/dev/null 2>&1; then
        COMMA_LOCALE="$candidate"
        break
    fi
done

if [ -z "$COMMA_LOCALE" ]; then
    skip "renders identically under a comma-decimal locale" "no comma-decimal locale installed"
    skip "no printf warning under a comma-decimal locale" "no comma-decimal locale installed"
else
    render "$(payload)" LC_ALL="$COMMA_LOCALE"
    assert "renders identically under a comma-decimal locale" "Opus 5 │ ✍️ 25% │ repo-clean (main)

$RATES"
    assert_no_stderr "no printf warning under a comma-decimal locale"
fi

section "permissions"

render "$(payload)"
assert_line1_re "no bolt without the skip-permissions flag" '│ repo-clean'

BOLT="bolt shows when the parent ran with --dangerously-skip-permissions"

# Git Bash ships an MSYS `ps` with no -o flag, so nothing there can read the
# parent's argv and the bolt never appears.
if [ -z "$(ps -o args= -p $$ 2>/dev/null)" ]; then
    skip "$BOLT" "ps -o args= unsupported here"
elif selected "$BOLT"; then
    out=$(printf '%s' "$(payload)" | bash "$TMP/parent.sh" --dangerously-skip-permissions 2>/dev/null \
        | strip_ansi | head -1)
    case "$out" in
        *"⚡"*) report_pass "$BOLT" ;;
        *) report_fail "$BOLT" "contains ⚡" "$(printf '%q' "$out")" ;;
    esac
fi

# ── Summary ─────────────────────────────────────────────

printf "\n"
if [ "$failed" -gt 0 ]; then
    printf "  ${red}%d failed${reset}, %d passed" "$failed" "$passed"
else
    printf "  ${green}%d passed${reset}" "$passed"
fi
[ "$skipped" -gt 0 ] && printf ", ${yellow}%d skipped${reset}" "$skipped"
printf "\n\n"

[ "$failed" -eq 0 ]
