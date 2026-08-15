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

# Most cases exercise the primary Unicode rendering. Pin an installed UTF-8
# locale so their expectations do not depend on the runner's default locale.
is_utf8_locale() {
    case "$(LC_ALL="$1" locale charmap 2>/dev/null)" in
        *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) return 0 ;;
        *) return 1 ;;
    esac
}

UTF8_LOCALE=""
for candidate in $(locale -a 2>/dev/null); do
    if is_utf8_locale "$candidate"; then
        UTF8_LOCALE=$candidate
        break
    fi
done
if [ -z "$UTF8_LOCALE" ]; then
    printf 'No UTF-8 locale installed\n' >&2
    exit 1
fi
export LC_ALL="$UTF8_LOCALE"

TRASH_HOME=$HOME
TMP=$(mktemp -d)
discard() {
    if command -v trash >/dev/null 2>&1; then
        HOME="$TRASH_HOME" trash "$@" || :
    fi
    # ponytail: without trash, leave mktemp-owned paths to OS temp cleanup.
}
trap 'discard "$TMP"' EXIT

export TZ=UTC
unset CLAUDE_CODE_OAUTH_TOKEN GIT_DIR GIT_WORK_TREE XDG_CACHE_HOME
export GIT_CEILING_DIRECTORIES="$TMP"

green='\033[32m'; red='\033[31m'; yellow='\033[33m'; dim='\033[2m'; reset='\033[0m'
passed=0; failed=0; skipped=0
export STATUSLINE_TEST_POLL_ATTEMPTS=600 STATUSLINE_TEST_POLL_DELAY=0.05

# ── Sandbox ─────────────────────────────────────────────

# Stubs shadow the real binaries so the API fallback can never hit the network.
# curl prints $STUB_CURL_BODY when a case sets it, otherwise fails like a timeout.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
[ -n "${STUB_CURL_CALLED:-}" ] && : > "$STUB_CURL_CALLED"
[ -n "${STUB_CURL_ARGS:-}" ] && printf '%s\n' "$@" > "$STUB_CURL_ARGS"
if [ -n "${STUB_CURL_GATE:-}" ]; then
    [ -n "${STUB_CURL_WAITING:-}" ] && : > "$STUB_CURL_WAITING"
    for ((i=0; i<STATUSLINE_TEST_POLL_ATTEMPTS; i++)); do
        [ -f "$STUB_CURL_GATE" ] && break
        sleep "$STATUSLINE_TEST_POLL_DELAY"
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
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/secret-tool"
# The macOS keychain lookup, for the cases that care which store a token came
# from. Silent unless a case puts a blob in the environment.
cat > "$TMP/bin/security" <<'EOF'
#!/bin/bash
[ -n "${STUB_KEYCHAIN_BLOB:-}" ] || exit 1
printf '%s' "$STUB_KEYCHAIN_BLOB"
EOF
chmod +x "$TMP/bin"/*
export PATH="$TMP/bin:$PATH"

export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
echo '{}' > "$HOME/.claude/settings.json"
CONFIG_FILE="$HOME/.claude/statusline.json"

export CLAUDE_STATUSLINE_CACHE_DIR="$TMP/cache"
mkdir -m 700 "$CLAUDE_STATUSLINE_CACHE_DIR"
CACHE_FILE="$CLAUDE_STATUSLINE_CACHE_DIR/statusline-usage-cache.json"
HISTORY_FILE="$CLAUDE_STATUSLINE_CACHE_DIR/statusline-usage-history"

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

STDOUT=""; LINE1=""; RAW=""; RAW1=""; STDERR=""; STATUS=0
# Renders a payload. Leaves the ANSI-stripped output in $STDOUT, its first line
# in $LINE1, that same line with colors intact in $RAW1, stderr in $STDERR and
# the exit code in $STATUS. Extra args are `env` assignments for the run.
render() {
    local input="$1" raw; shift
    raw=$(printf '%s' "$input" | env "$@" bash "$STATUSLINE" 2>"$TMP/stderr")
    # shellcheck disable=SC2034  # part of render()'s output contract, for cases to read.
    STATUS=$?
    STDERR=$(cat "$TMP/stderr")
    RAW=$raw
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

assert_not_re() {
    selected "$1" || return 0
    if [[ ! "$STDOUT" =~ $2 ]]; then report_pass "$1"; else report_fail "$1" "!~ $2" "$(printf '%q' "$STDOUT")"; fi
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

assert_output_color() {
    selected "$1" || return 0
    case "$RAW" in
        *"$2"*) report_pass "$1" ;;
        *) report_fail "$1" "contains $(printf '%q' "$2")" "$(printf '%q' "$RAW")" ;;
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
    local path=$1 i
    for ((i=0; i<STATUSLINE_TEST_POLL_ATTEMPTS; i++)); do
        [ -f "$path" ] && return 0
        sleep "$STATUSLINE_TEST_POLL_DELAY"
    done
    return 1
}

RATES_5H="current ●●●●○○○○○○  42% ⟳ 7:06am"
RATES_7D="weekly  ●○○○○○○○○○  19% ⟳ aug 10, 10:13pm"
RATES="$RATES_5H
$RATES_7D"
ASCII_RATES="current ####------  42% reset 7:06am
weekly  #---------  19% reset aug 10, 10:13pm"

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

section "width"

clear_cache
render "$(payload 'del(.rate_limits) | .model.display_name = "1234567890123456789012345"')" COLUMNS=20
assert "COLUMNS truncates a Unicode line by visible width" "1234567890123456789…"

render "$(payload 'del(.rate_limits) | .model.display_name = "1234567890123456789012345"')" \
    COLUMNS=10 LC_ALL=C
assert "COLUMNS uses an ASCII marker outside UTF-8" "1234567..."

render "$(payload 'del(.rate_limits) | .model.display_name = "界界界界"')" COLUMNS=6
assert "COLUMNS counts CJK characters as two cells" "界界…"

render "$(payload 'del(.rate_limits) | .model.display_name = "e\u0301e\u0301e\u0301"')" COLUMNS=3
assert "COLUMNS does not count combining marks twice" "éé…"

REAL_JQ=$(command -v jq)
mkdir -p "$TMP/failing-jq"
cat > "$TMP/failing-jq/jq" <<EOF
#!/bin/bash
[ "\${1:-}" = "-Rrsj" ] && exit 1
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$TMP/failing-jq/jq"
render "$(payload 'del(.rate_limits) | .model.display_name = "1234567890123456789012345"')" \
    COLUMNS=20 PATH="$TMP/failing-jq:$PATH"
assert "COLUMNS keeps the original output when truncation fails" \
    "1234567890123456789012345 │ ✍️ 25% │ repo-clean (main)"

section "configuration"

printf '{"blocks":["model","current"],"bar_width":4}\n' > "$CONFIG_FILE"
clear_cache
render "$(payload)"
assert "config selects blocks and bar width" "Opus 5

current ●○○○  42% ⟳ 7:06am"

printf '{"blocks":[]}\n' > "$CONFIG_FILE"
render "$(payload)"
assert "an empty block list renders nothing" ""

printf '{"blocks":["model"]}\n' > "$CONFIG_FILE"
clear_cache
render "$(payload 'del(.rate_limits)')" CLAUDE_CODE_OAUTH_TOKEN=test-token \
    STUB_CURL_CALLED="$TMP/config-curl-called"
assert "hidden rate blocks do not fetch usage" "Opus 5"
selected "hidden rate blocks do not fetch usage from the API" && {
    if [ ! -e "$TMP/config-curl-called" ]; then
        report_pass "hidden rate blocks do not fetch usage from the API"
    else
        report_fail "hidden rate blocks do not fetch usage from the API" "no curl call" "curl was called"
    fi
}

printf '{"colors":{"blue":"#010203","green":"#040506"}}\n' > "$CONFIG_FILE"
render "$(payload)"
assert_color "config overrides named colors" $'\033[38;2;1;2;3mOpus 5'
assert_color "configured threshold colors reach context" $'\033[38;2;4;5;6m25%'

printf '{"bar_width":0,"colors":{"blue":"not-a-color"}}\n' > "$CONFIG_FILE"
render "$(payload)"
assert_color "invalid config values keep color defaults" $'\033[38;2;0;153;255mOpus 5'
assert_re "invalid config values keep bar defaults" 'current ●●●●○○○○○○  42%'

printf 'not json\n' > "$CONFIG_FILE"
render "$(payload)"
assert "malformed config falls back without breaking output" "Opus 5 │ ✍️ 25% │ repo-clean (main)

$RATES"
assert_no_stderr "malformed config does not warn"

printf '{}\n' > "$CONFIG_FILE"

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

section "profile"

# A session started on a second profile reads it through CLAUDE_CONFIG_DIR, and
# everything this script looks up about that session is in there with it.
PROFILE_DIR="$TMP/profile"
mkdir -p "$PROFILE_DIR"
echo '{"effortLevel":"xhigh"}' > "$PROFILE_DIR/settings.json"
echo '{"effortLevel":"low"}' > "$HOME/.claude/settings.json"

render "$(payload)" CLAUDE_CONFIG_DIR="$PROFILE_DIR"
assert_line1_re "effort falls back to the profile settings.json" '│ ● xhigh$'

render "$(payload)"
assert_line1_re "an unset CLAUDE_CONFIG_DIR still means ~/.claude" '│ ◔ low$'
echo '{}' > "$HOME/.claude/settings.json"

printf '{"blocks":["model"]}\n' > "$PROFILE_DIR/statusline.json"
render "$(payload)" CLAUDE_CONFIG_DIR="$PROFILE_DIR"
assert "the profile carries its own display config" "Opus 5"
rm -f "$PROFILE_DIR/statusline.json"

# The OAuth token the API fallback needs is stored per profile as well.
printf '{"claudeAiOauth":{"accessToken":"profile-token"}}' > "$PROFILE_DIR/.credentials.json"
printf '%s' '{"five_hour":{"utilization":42.3,"resets_at":"2026-08-06T07:06:40Z"},
              "seven_day":{"utilization":18.7,"resets_at":"2026-08-10T22:13:20Z"}}' \
    > "$TMP/profile-response.json"
clear_cache
render "$(payload 'del(.rate_limits)')" CLAUDE_CONFIG_DIR="$PROFILE_DIR" \
    STUB_CURL_BODY="$TMP/profile-response.json"
assert "the profile credentials reach the API fallback" \
    "Opus 5 │ ✍️ 25% │ repo-clean (main) │ ● xhigh

$RATES"
clear_cache

# The keychain holds one entry for the machine, so on a second profile it
# answers for whichever account logged in last. The file inside the profile the
# session named is the one that describes that session.
assert_token() {
    selected "$1" || return 0
    if grep -q "Bearer $2" "$TMP/curl-args" 2>/dev/null; then
        report_pass "$1"
    else
        report_fail "$1" "Bearer $2" "$(grep -c . "$TMP/curl-args" 2>/dev/null) curl args"
    fi
}

render "$(payload 'del(.rate_limits)')" CLAUDE_CONFIG_DIR="$PROFILE_DIR" \
    STUB_CURL_BODY="$TMP/profile-response.json" STUB_CURL_ARGS="$TMP/curl-args" \
    STUB_KEYCHAIN_BLOB='{"claudeAiOauth":{"accessToken":"keychain-token"}}'
assert_token "the profile token beats the machine-wide keychain" profile-token
clear_cache

# Without a profile named, the keychain keeps the precedence it always had: it
# is where Claude Code writes on macOS, and the file may be an older release's
# leftover.
printf '{"claudeAiOauth":{"accessToken":"home-token"}}' > "$HOME/.claude/.credentials.json"
render "$(payload 'del(.rate_limits)')" STUB_CURL_BODY="$TMP/profile-response.json" \
    STUB_CURL_ARGS="$TMP/curl-args" \
    STUB_KEYCHAIN_BLOB='{"claudeAiOauth":{"accessToken":"keychain-token"}}'
assert_token "the default profile still reads the keychain first" keychain-token
clear_cache

render "$(payload 'del(.rate_limits)')" STUB_CURL_BODY="$TMP/profile-response.json" \
    STUB_CURL_ARGS="$TMP/curl-args"
assert_token "an empty keychain falls back to the credentials file" home-token
rm -f "$HOME/.claude/.credentials.json"
clear_cache
section "skills"

# Nothing in the payload says which skills a session loaded, so the block reads
# the transcript that session is writing and picks the `Skill` calls out of it.
skill_call() {
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"%s"}}]}}\n' "$1"
}
transcript() {
    local path="$TMP/$1.jsonl" skill
    : > "$path"
    shift
    for skill in "$@"; do skill_call "$skill" >> "$path"; done
    printf '%s' "$path"
}
with_transcript() {
    payload ".transcript_path = \"$1\""
}

printf '{"blocks":["model","skills"]}\n' > "$CONFIG_FILE"

render "$(with_transcript "$(transcript basic human-writer artifact-design)")"
assert "the skills of the session are listed" "Opus 5 │ skills:human-writer,artifact-design"

render "$(with_transcript "$(transcript repeats alpha beta alpha)")"
assert "a skill invoked twice is listed once" "Opus 5 │ skills:alpha,beta"

render "$(with_transcript "$(transcript many alpha beta gamma delta)")"
assert "past the limit the oldest become a count" "Opus 5 │ skills:beta,gamma,delta +1"

printf '{"blocks":["model","skills"],"skills_limit":1}\n' > "$CONFIG_FILE"
render "$(with_transcript "$TMP/many.jsonl")"
assert "skills_limit sets how many are named" "Opus 5 │ skills:delta +3"

# More skills than the default names, so a 99 that got through would show all
# four rather than three and a count.
printf '{"blocks":["model","skills"],"skills_limit":99}\n' > "$CONFIG_FILE"
render "$(with_transcript "$TMP/many.jsonl")"
assert "an out-of-range skills_limit keeps the default" "Opus 5 │ skills:beta,gamma,delta +1"

printf '{"blocks":["model","skills"]}\n' > "$CONFIG_FILE"

# Only the bytes appended since the last render are scanned, so what the cache
# carries over has to survive both a growing file and a rewritten one.
GROWING=$(transcript growing alpha)
render "$(with_transcript "$GROWING")"
skill_call beta >> "$GROWING"
render "$(with_transcript "$GROWING")"
assert "a skill invoked later joins the list" "Opus 5 │ skills:alpha,beta"

# Catch the writer mid-line: the tail of a partial line is no reason to lose
# its head on the next pass.
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","in' >> "$GROWING"
render "$(with_transcript "$GROWING")"
assert "half a line is not read as a skill" "Opus 5 │ skills:alpha,beta"
printf 'put":{"skill":"gamma"}}]}}\n' >> "$GROWING"
render "$(with_transcript "$GROWING")"
assert "the line finishes and its skill shows up" "Opus 5 │ skills:alpha,beta,gamma"

skill_call delta > "$GROWING"
render "$(with_transcript "$GROWING")"
assert "a shorter transcript is read from the start again" "Opus 5 │ skills:delta"

# The transcript is written by the model, so a name is only rendered when it
# looks like one — an escape sequence in there would otherwise reach a terminal.
{
    printf '{"name":"Skill","input":{"skill":"\\u001b[31mred"}}\n'
    printf '{"name":"Skill","input":{"skill":"has space"}}\n'
    skill_call plugin:packaged
} > "$TMP/odd-names.jsonl"
render "$(with_transcript "$TMP/odd-names.jsonl")"
assert "a skill name that is not one is dropped" "Opus 5 │ skills:plugin:packaged"

render "$(with_transcript "$TMP/no-such-transcript.jsonl")"
assert "a transcript that is not there renders nothing" "Opus 5"

render "$(payload)"
assert "a payload without a transcript renders nothing" "Opus 5"

# With caching off the offset has nowhere to live and the file is read whole,
# which has to reach the same answer.
NOCACHE_DIR="$TMP/skills-nocache"
mkdir -m 700 "$NOCACHE_DIR"
chmod 777 "$NOCACHE_DIR"
NOCACHE="skills are read without a cache to carry them"
if [ "$(dir_mode "$NOCACHE_DIR")" = 777 ]; then
    render "$(with_transcript "$TMP/basic.jsonl")" CLAUDE_STATUSLINE_CACHE_DIR="$NOCACHE_DIR"
    assert "$NOCACHE" "Opus 5 │ skills:human-writer,artifact-design"
else
    skip "$NOCACHE" "no POSIX modes on this filesystem"
fi

printf '{}\n' > "$CONFIG_FILE"
render "$(with_transcript "$TMP/basic.jsonl")"
assert_line1_re "the block stays out of the default line" 'repo-clean \(main\)$'

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

section "burn rate history"

BURN_NOW=$(date +%s)
BURN_RESET=$(( BURN_NOW + 3600 ))
printf '%s\x1f%s\x1f%s\n' "$BURN_RESET" "$(( BURN_NOW - 3600 ))" 20 > "$HISTORY_FILE"
render "$(payload '.rate_limits.five_hour.used_percentage = 50
                    | .rate_limits.five_hour.resets_at = '"$BURN_RESET"'
                    | del(.rate_limits.seven_day)')"
assert_re "burn rate comes from cached samples in the current window" \
    'current ●●●●●○○○○○  50% ↗ (29\.[0-9]|30\.0)%/h ⟳'
assert_output_color "a sustainable five-hour pace stays green" \
    $'\033[38;2;0;175;80m↗ '

render "$(payload '.rate_limits.five_hour.used_percentage = 50
                    | .rate_limits.five_hour.resets_at = '"$BURN_RESET"'
                    | del(.rate_limits.seven_day)')" LC_ALL=C
assert_re "burn rate has an ASCII fallback" \
    'current #####-----  50% burn (29\.[0-9]|30\.0)%/h reset'

selected "the current burn sample is appended to history" && {
    saved_reset=""; saved_time=""; saved_pct=""
    while IFS=$'\x1f' read -r found_reset found_time found_pct; do
        saved_reset=$found_reset; saved_time=$found_time; saved_pct=$found_pct
    done < "$HISTORY_FILE"
    case "$saved_time" in ''|*[!0-9]*) saved_time_valid=false ;; *) saved_time_valid=true ;; esac
    if [ "$saved_reset" = "$BURN_RESET" ] && [ "$saved_pct" = 50 ] &&
       [ "$saved_time_valid" = true ] && [ "$saved_time" -ge "$BURN_NOW" ]; then
        report_pass "the current burn sample is appended to history"
    else
        report_fail "the current burn sample is appended to history" \
            "reset=$BURN_RESET time>=$BURN_NOW pct=50" \
            "reset=$saved_reset time=$saved_time pct=$saved_pct"
    fi
}

# A new reset is a new rate-limit window, so a previous window cannot skew it.
NEXT_RESET=$(( BURN_RESET + 300 ))
render "$(payload '.rate_limits.five_hour.used_percentage = 51
                    | .rate_limits.five_hour.resets_at = '"$NEXT_RESET"'
                    | del(.rate_limits.seven_day)')"
assert_not_re "a reset change starts a fresh burn history" '%/h'

ALERT_RESET=$(( BURN_NOW + 7200 ))
printf '%s\x1f%s\x1f%s\n' "$ALERT_RESET" "$(( BURN_NOW - 3600 ))" 27 > "$HISTORY_FILE"
render "$(payload '.rate_limits.five_hour.used_percentage = 50
                    | .rate_limits.five_hour.resets_at = '"$ALERT_RESET"'
                    | del(.rate_limits.seven_day)')"
assert_output_color "a pace projected into the 90-percent zone turns yellow" \
    $'\033[38;2;230;200;0m↗ '

printf '%s\x1f%s\x1f%s\n' "$ALERT_RESET" "$(( BURN_NOW - 3600 ))" 20 > "$HISTORY_FILE"
render "$(payload '.rate_limits.five_hour.used_percentage = 50
                    | .rate_limits.five_hour.resets_at = '"$ALERT_RESET"'
                    | del(.rate_limits.seven_day)')"
assert_output_color "a pace projected to exhaust before reset turns red" \
    $'\033[38;2;255;85;85m↗ '

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

HISTORY_LINK="a symlinked burn history is not written through"
HISTORY_LINK_DIR="$TMP/history-link"
HISTORY_LINK_TARGET="$TMP/history-target"
mkdir -m 700 "$HISTORY_LINK_DIR"
printf 'not the history' > "$HISTORY_LINK_TARGET"
if ln -s "$HISTORY_LINK_TARGET" "$HISTORY_LINK_DIR/statusline-usage-history" 2>/dev/null &&
   sees_symlink "$HISTORY_LINK_DIR/statusline-usage-history"; then
    render "$(payload '.rate_limits.five_hour.used_percentage = 55
                        | .rate_limits.five_hour.resets_at = '"$BURN_RESET"'
                        | del(.rate_limits.seven_day)')" \
        CLAUDE_STATUSLINE_CACHE_DIR="$HISTORY_LINK_DIR"
    assert_file "$HISTORY_LINK" "$HISTORY_LINK_TARGET" 'not the history'
else
    skip "$HISTORY_LINK" "no symlink support here"
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
    if is_utf8_locale "$COMMA_LOCALE"; then
        comma_output="Opus 5 │ ✍️ 25% │ repo-clean (main)

$RATES"
    else
        comma_output="Opus 5 | ctx 25% | repo-clean (main)

$ASCII_RATES"
    fi
    assert "renders identically under a comma-decimal locale" "$comma_output"
    assert_no_stderr "no printf warning under a comma-decimal locale"
fi

render "$(payload '.effort.level = "high"')" LC_ALL=C
assert "a non-UTF-8 locale uses ASCII decorations" "Opus 5 | ctx 25% | repo-clean (main) | + high

${ASCII_RATES}"

render "$(payload '.effort.level = "high"')" LC_ALL="$UTF8_LOCALE"
assert "a UTF-8 locale keeps Unicode decorations" "Opus 5 │ ✍️ 25% │ repo-clean (main) │ ◕ high

$RATES"

render "$(payload)" -u LC_ALL LC_CTYPE="$UTF8_LOCALE" LANG=C
assert_line1_re "locale selection uses UTF-8 LC_CTYPE when LC_ALL is unset" '^Opus 5 │ ✍️ 25%'

render "$(payload)" -u LC_ALL LC_CTYPE=C LANG="$UTF8_LOCALE"
assert_line1_re "locale selection uses ASCII LC_CTYPE when LC_ALL is unset" '^Opus 5 \| ctx 25%'

render "$(payload)" -u LC_ALL -u LC_CTYPE LANG="$UTF8_LOCALE"
assert_line1_re "locale selection uses UTF-8 LANG when stronger variables are unset" '^Opus 5 │ ✍️ 25%'

render "$(payload)" -u LC_ALL -u LC_CTYPE LANG=C
assert_line1_re "locale selection uses ASCII LANG when stronger variables are unset" '^Opus 5 \| ctx 25%'

render "$(payload)" LC_ALL=C LC_CTYPE="$UTF8_LOCALE" LANG="$UTF8_LOCALE"
assert_line1_re "locale selection gives LC_ALL precedence" '^Opus 5 \| ctx 25%'

section "permissions"

render "$(payload)"
assert_line1_re "no bolt without the skip-permissions flag" '│ repo-clean'

BOLT="a UTF-8 locale uses ⚡ for the skip-permissions warning"
ASCII_BOLT="an ASCII locale uses ! for the skip-permissions warning"

# Git Bash ships an MSYS `ps` with no -o flag, so nothing there can read the
# parent's argv and the bolt never appears.
if [ -z "$(ps -o args= -p $$ 2>/dev/null)" ]; then
    skip "$BOLT" "ps -o args= unsupported here"
    skip "$ASCII_BOLT" "ps -o args= unsupported here"
else
    if selected "$BOLT"; then
        out=$(printf '%s' "$(payload)" \
            | env LC_ALL="$UTF8_LOCALE" bash "$TMP/parent.sh" --dangerously-skip-permissions 2>/dev/null \
            | strip_ansi | head -1)
        case "$out" in
            *"⚡"*) report_pass "$BOLT" ;;
            *) report_fail "$BOLT" "contains ⚡" "$(printf '%q' "$out")" ;;
        esac
    fi
    if selected "$ASCII_BOLT"; then
        out=$(printf '%s' "$(payload)" \
            | env LC_ALL=C bash "$TMP/parent.sh" --dangerously-skip-permissions 2>/dev/null \
            | strip_ansi | head -1)
        case "$out" in
            *"!  repo-clean"*) report_pass "$ASCII_BOLT" ;;
            *) report_fail "$ASCII_BOLT" "contains !  repo-clean" "$(printf '%q' "$out")" ;;
        esac
    fi
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
