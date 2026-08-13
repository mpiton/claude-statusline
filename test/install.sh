#!/bin/bash
# Tests for bin/install.js — run the installer against a throwaway HOME and
# check what it wrote, then uninstall and check what it took back.
#
#   test/install.sh          run everything
#   test/install.sh settings run cases whose name contains "settings"

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER="$ROOT/bin/install.js"
FILTER="${1:-}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

green='\033[32m'; red='\033[31m'; dim='\033[2m'; reset='\033[0m'
passed=0; failed=0

selected() {
    [ -z "$FILTER" ] && return 0
    case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac
}

report_pass() {
    printf "  ${green}✓${reset} %s\n" "$1"
    passed=$((passed + 1))
}

report_fail() {
    printf "  ${red}✗${reset} %s\n" "$1"
    printf "    ${dim}expected:${reset} %s\n" "$2"
    printf "    ${dim}actual:  ${reset} %s\n" "$3"
    failed=$((failed + 1))
}

check() {
    selected "$1" || return 0
    if [ "$2" = "$3" ]; then report_pass "$1"; else report_fail "$1" "$(printf '%q' "$2")" "$(printf '%q' "$3")"; fi
}

section() { [ -n "$FILTER" ] || printf "\n${dim}%s${reset}\n" "$1"; }

# Each case gets its own HOME so nothing leaks between them.
OUT=""; STATUS=0
install_into() {
    local home="$1"; shift
    OUT=$(HOME="$home" node "$INSTALLER" "$@" 2>&1)
    STATUS=$?
}

# ── Fresh install ───────────────────────────────────────

section "install"

HOME_A="$TMP/fresh"
mkdir -p "$HOME_A"
install_into "$HOME_A"

check "a fresh install exits clean" "0" "$STATUS"
check "it creates ~/.claude/statusline.sh" "yes" \
    "$([ -f "$HOME_A/.claude/statusline.sh" ] && echo yes || echo no)"
check "the installed script is executable" "yes" \
    "$([ -x "$HOME_A/.claude/statusline.sh" ] && echo yes || echo no)"
check "the installed script matches the source" "same" \
    "$(cmp -s "$ROOT/bin/statusline.sh" "$HOME_A/.claude/statusline.sh" && echo same || echo differs)"
# shellcheck disable=SC2016  # $HOME stays literal in the command the installer writes.
check "it points settings.json at the installed script" 'bash "$HOME/.claude/statusline.sh"' \
    "$(jq -r '.statusLine.command // ""' "$HOME_A/.claude/settings.json" 2>/dev/null)"
check "it registers statusLine as a command hook" "command" \
    "$(jq -r '.statusLine.type // ""' "$HOME_A/.claude/settings.json" 2>/dev/null)"

# The installed copy is what Claude Code actually runs, so it has to render.
selected "the installed script renders" && {
    rendered=$(printf '%s' '{"model":{"display_name":"Opus 5"}}' \
        | env HOME="$HOME_A" CLAUDE_STATUSLINE_CACHE_DIR="$TMP/cache" \
          bash "$HOME_A/.claude/statusline.sh" 2>/dev/null | head -1)
    case "$rendered" in
        *"Opus 5"*) report_pass "the installed script renders" ;;
        *) report_fail "the installed script renders" "contains Opus 5" "$(printf '%q' "$rendered")" ;;
    esac
}

section "settings"

HOME_B="$TMP/existing"
mkdir -p "$HOME_B/.claude"
printf '{"effortLevel":"high","model":"opus"}\n' > "$HOME_B/.claude/settings.json"
install_into "$HOME_B"

check "unrelated settings keys survive the install" "high opus" \
    "$(jq -r '[.effortLevel, .model] | join(" ")' "$HOME_B/.claude/settings.json" 2>/dev/null)"

install_into "$HOME_B"
check "a second install is a no-op on settings" "yes" \
    "$(printf '%s' "$OUT" | grep -q "Settings already configured" && echo yes || echo no)"

HOME_C="$TMP/broken"
mkdir -p "$HOME_C/.claude"
printf 'not json\n' > "$HOME_C/.claude/settings.json"
install_into "$HOME_C"
check "an unparseable settings.json aborts instead of clobbering" "1" "$STATUS"
check "the unparseable file is left alone" "not json" \
    "$(cat "$HOME_C/.claude/settings.json")"

section "dependencies"

# An empty PATH makes the installer's `which jq|curl|git` probes fail, which is
# the closest we get to a machine without them. node itself has to be invoked by
# absolute path, since the empty PATH hides it too.
selected "a missing dependency stops the install" && {
    mkdir -p "$TMP/nodeps" "$TMP/emptybin"
    out=$(HOME="$TMP/nodeps" PATH="$TMP/emptybin" "$(command -v node)" "$INSTALLER" 2>&1)
    status=$?
    if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "Missing required dependencies"; then
        report_pass "a missing dependency stops the install"
    else
        report_fail "a missing dependency stops the install" "exit 1 + missing-deps message" \
            "exit $status: $(printf '%q' "$out")"
    fi
}

# ── Uninstall ───────────────────────────────────────────

section "uninstall"

install_into "$HOME_A" --uninstall
check "uninstall exits clean" "0" "$STATUS"
check "it removes the statusline script" "gone" \
    "$([ -e "$HOME_A/.claude/statusline.sh" ] && echo present || echo gone)"
check "it drops the statusLine key" "null" \
    "$(jq -r '.statusLine // "null"' "$HOME_A/.claude/settings.json" 2>/dev/null)"

install_into "$HOME_B" --uninstall
check "uninstall keeps unrelated settings keys" "high opus" \
    "$(jq -r '[.effortLevel, .model] | join(" ")' "$HOME_B/.claude/settings.json" 2>/dev/null)"

HOME_D="$TMP/never-installed"
mkdir -p "$HOME_D"
install_into "$HOME_D" --uninstall
check "uninstalling what was never installed is not an error" "0" "$STATUS"

# A statusline.sh the user wrote themselves is backed up on install and handed
# back on uninstall.
section "backup"

HOME_E="$TMP/byo"
mkdir -p "$HOME_E/.claude"
printf '#!/bin/bash\nprintf mine\n' > "$HOME_E/.claude/statusline.sh"
install_into "$HOME_E"
check "an existing statusline is backed up" "yes" \
    "$([ -f "$HOME_E/.claude/statusline.sh.bak" ] && echo yes || echo no)"

install_into "$HOME_E" --uninstall
check "uninstall restores the user's own statusline" "#!/bin/bash
printf mine" "$(cat "$HOME_E/.claude/statusline.sh" 2>/dev/null)"
check "the backup is consumed" "gone" \
    "$([ -e "$HOME_E/.claude/statusline.sh.bak" ] && echo present || echo gone)"

# ── Summary ─────────────────────────────────────────────

printf "\n"
if [ "$failed" -gt 0 ]; then
    printf "  ${red}%d failed${reset}, %d passed\n\n" "$failed" "$passed"
else
    printf "  ${green}%d passed${reset}\n\n" "$passed"
fi

[ "$failed" -eq 0 ]
