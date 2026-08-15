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

TRASH_HOME=$HOME
TMP=$(mktemp -d)
discard() {
    if command -v trash >/dev/null 2>&1; then
        HOME="$TRASH_HOME" trash "$@" || :
    fi
    # ponytail: without trash, leave mktemp-owned paths to OS temp cleanup.
}
trap 'discard "$TMP"' EXIT

# The same sandbox test/run.sh builds. One case runs the installed statusline
# for real, and with no rate limits on stdin that script goes looking for an
# OAuth token — env first, then the macOS keychain or the Linux keyring — and
# calls api.anthropic.com with whatever it finds. Stub the three lookups so
# `npm test` can't spend a developer's credentials.
#
# CLAUDE_CONFIG_DIR goes with them: the cases below that expect the default
# profile would otherwise install into whatever profile the developer running
# the suite happens to have selected. The profile cases set it themselves.
unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR
mkdir -p "$TMP/bin"
printf '#!/bin/bash\nexit 7\n' > "$TMP/bin/curl"
for stub in secret-tool security; do
    printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/$stub"
done
chmod +x "$TMP/bin"/*
export PATH="$TMP/bin:$PATH"

green='\033[32m'; red='\033[31m'; yellow='\033[33m'; dim='\033[2m'; reset='\033[0m'
passed=0; failed=0; skipped=0

selected() {
    [ -z "$FILTER" ] && return 0
    case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac
}

report_pass() {
    printf "  ${green}✓${reset} %s\n" "$1"
    passed=$((passed + 1))
}

skip() {
    selected "$1" || return 0
    printf "  ${yellow}−${reset} %s ${dim}(%s)${reset}\n" "$1" "$2"
    skipped=$((skipped + 1))
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

# node on Windows reads USERPROFILE rather than HOME, and cannot follow the
# MSYS paths this script builds, so hand it the Windows spelling of the same
# directory. Elsewhere USERPROFILE is ignored and this is the path itself.
node_home() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# The installer stamps the release it came from into the copy it writes, so the
# two files differ by that one line and nothing else.
# jq rather than node: node on Windows cannot require() the MSYS path $ROOT is.
VERSION=$(jq -r .version "$ROOT/package.json")
PLATFORM=$(node -p 'process.platform' 2>/dev/null)
# shellcheck disable=SC2016  # the expansions stay literal in the command under test.
MANAGED_COMMAND='bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline.sh"'
# shellcheck disable=SC2016  # what every release up to 2.0.0 wrote.
LEGACY_COMMAND='bash "$HOME/.claude/statusline.sh"'
# An empty version turns every check below into a substring match against
# anything, which is how a broken lookup passed CI once already.
[ -n "$VERSION" ] || {
    printf "  ${red}✗${reset} %s\n\n" "could not read the version out of package.json"
    exit 1
}
version_of() { sed -n 's/^# statusline-version: *//p' "$1" | head -1; }
unstamped() { sed 's/^# statusline-version:.*$/# statusline-version:/' "$1"; }

# Each case gets its own HOME so nothing leaks between them.
OUT=""; STATUS=0
install_into() {
    local home="$1"; shift
    OUT=$(HOME="$home" USERPROFILE="$(node_home "$home")" node "$INSTALLER" "$@" 2>&1)
    STATUS=$?
}

# A second profile is a CLAUDE_CONFIG_DIR pointing somewhere other than
# ~/.claude, which node has to be handed in the same spelling as USERPROFILE.
install_profile() {
    local home="$1" profile="$2"; shift 2
    OUT=$(HOME="$home" USERPROFILE="$(node_home "$home")" \
        CLAUDE_CONFIG_DIR="$(node_home "$profile")" node "$INSTALLER" "$@" 2>&1)
    STATUS=$?
}

# The exact command is only predictable off Windows: there the installer writes
# the bash it found and an absolute script path, since cmd.exe expands neither
# $HOME nor ${CLAUDE_CONFIG_DIR:-…}.
check_command() {
    local name=$1 settings=$2 actual
    actual=$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null)
    if [ "$PLATFORM" != win32 ]; then
        check "$name" "$MANAGED_COMMAND" "$actual"
        return 0
    fi
    selected "$name" || return 0
    case "$actual" in
        *bash*\"*statusline.sh\") report_pass "$name" ;;
        *) report_fail "$name" "a quoted bash invocation ending in statusline.sh" \
            "$(printf '%q' "$actual")" ;;
    esac
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
check "the installed script matches the source apart from the stamp" "same" \
    "$(diff <(unstamped "$ROOT/bin/statusline.sh") <(unstamped "$HOME_A/.claude/statusline.sh") \
        >/dev/null 2>&1 && echo same || echo differs)"
check "the installed script carries the package version" "$VERSION" \
    "$(version_of "$HOME_A/.claude/statusline.sh")"
check "the packaged source carries an unstamped marker" "dev" \
    "$(version_of "$ROOT/bin/statusline.sh")"
check_command "it points settings.json at the installed script" "$HOME_A/.claude/settings.json"
check "it registers statusLine as a command hook" "command" \
    "$(jq -r '.statusLine.type // ""' "$HOME_A/.claude/settings.json" 2>/dev/null)"

# The installed copy is what Claude Code actually runs, so it has to render.
# cwd points at an empty directory: left to default it would be this repo, and
# the render would shell out to git against whatever the checkout looks like.
selected "the installed script renders" && {
    mkdir -p "$TMP/plain"
    rendered=$(printf '{"model":{"display_name":"Opus 5"},"cwd":"%s"}' "$TMP/plain" \
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
check "a second install skips the copy" "yes" \
    "$(printf '%s' "$OUT" | grep -q "already at $VERSION" && echo yes || echo no)"

# A settings.json written by an earlier release names the default profile
# outright. Rewrite it, or a second profile keeps running the wrong script.
HOME_T="$TMP/legacy-setting"
mkdir -p "$HOME_T/.claude"
jq -n --arg command "$LEGACY_COMMAND" '{statusLine:{type:"command",command:$command}}' \
    > "$HOME_T/.claude/settings.json"
install_into "$HOME_T"
check_command "an older command string is upgraded" "$HOME_T/.claude/settings.json"

HOME_C="$TMP/broken"
mkdir -p "$HOME_C/.claude"
printf 'not json\n' > "$HOME_C/.claude/settings.json"
install_into "$HOME_C"
check "an unparseable settings.json aborts instead of clobbering" "1" "$STATUS"
check "the unparseable file is left alone" "not json" \
    "$(cat "$HOME_C/.claude/settings.json")"

# A script left behind by an older release carries our stamp, so the installer
# knows it is looking at its own work: overwrite it, and do not squirrel it away
# as if it were something the user wrote.
section "version"

HOME_G="$TMP/stale"
mkdir -p "$HOME_G/.claude"
sed 's/^# statusline-version:.*$/# statusline-version: 0.0.1/' "$ROOT/bin/statusline.sh" \
    > "$HOME_G/.claude/statusline.sh"
install_into "$HOME_G"

check "an older install is replaced" "$VERSION" "$(version_of "$HOME_G/.claude/statusline.sh")"
check "the upgrade names both versions" "yes" \
    "$(printf '%s' "$OUT" | grep -q "0.0.1 → $VERSION" && echo yes || echo no)"
check "our own old script is not backed up as the user's" "gone" \
    "$([ -e "$HOME_G/.claude/statusline.sh.bak" ] && echo present || echo gone)"

section "dependencies"

# An empty PATH hides jq, curl and git — and bash, which the installer probes
# through — which is the closest we get to a machine without them. node itself
# has to be invoked by absolute path, since the empty PATH hides it too.
selected "a missing dependency stops the install" && {
    mkdir -p "$TMP/nodeps" "$TMP/emptybin"
    out=$(HOME="$TMP/nodeps" USERPROFILE="$(node_home "$TMP/nodeps")" PATH="$TMP/emptybin" \
        "$(command -v node)" "$INSTALLER" 2>&1)
    status=$?
    if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "Missing required dependencies"; then
        report_pass "a missing dependency stops the install"
    else
        report_fail "a missing dependency stops the install" "exit 1 + missing-deps message" \
            "exit $status: $(printf '%q' "$out")"
    fi
}

# The case above never reaches the per-dependency loop: with nothing on PATH
# the probe cannot start bash either, and reports that instead. Here bash is
# reachable and only jq is not, so the loop has to name jq and leave the two
# tools it can see out of the list.
NAMED="the probe names the one dependency that is missing"
selected "$NAMED" && {
    mkdir -p "$TMP/deps" "$TMP/onedep-home"
    for stub in curl git; do
        printf '#!/bin/bash\nexit 0\n' > "$TMP/deps/$stub"
    done
    chmod +x "$TMP/deps"/*
    ln -sf "$(command -v bash)" "$TMP/deps/bash" 2>/dev/null

    # Windows has no runnable bash outside the directory holding its DLLs, so
    # the shim above is a dead end there. Ask node, the way the installer will.
    spawns_bash='require("child_process").execFileSync("bash",["-c","exit 0"],{stdio:"ignore"})'
    if PATH="$TMP/deps" "$(command -v node)" -e "$spawns_bash" 2>/dev/null; then
        out=$(HOME="$TMP/onedep-home" USERPROFILE="$(node_home "$TMP/onedep-home")" \
            PATH="$TMP/deps" "$(command -v node)" "$INSTALLER" 2>&1)
        status=$?
        if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "Missing required dependencies: jq$"; then
            report_pass "$NAMED"
        else
            report_fail "$NAMED" "exit 1 + jq alone in the list" "exit $status: $(printf '%q' "$out")"
        fi
    else
        skip "$NAMED" "no bash outside its own directory here"
    fi
}

# The probe was `which jq`, and execSync hands that to cmd.exe on Windows, which
# has no `which` — so every Windows install stopped at "Missing required
# dependencies" with all three tools installed. A `which` that fails reproduces
# it on any platform.
selected "the dependency probe does not go through which" && {
    mkdir -p "$TMP/nowhich" "$TMP/nowhich-home"
    printf '#!/bin/bash\nexit 127\n' > "$TMP/nowhich/which"
    chmod +x "$TMP/nowhich/which"
    out=$(HOME="$TMP/nowhich-home" USERPROFILE="$(node_home "$TMP/nowhich-home")" \
        PATH="$TMP/nowhich:$PATH" node "$INSTALLER" 2>&1)
    status=$?
    if [ "$status" -eq 0 ] && [ -f "$TMP/nowhich-home/.claude/statusline.sh" ]; then
        report_pass "the dependency probe does not go through which"
    else
        report_fail "the dependency probe does not go through which" "exit 0 + installed script" \
            "exit $status: $(printf '%q' "$out")"
    fi
}

# ── Profiles ────────────────────────────────────────────

section "profiles"

# Claude Code reads the profile CLAUDE_CONFIG_DIR names, so that is the
# settings.json the statusline has to be registered in, and the directory the
# script has to sit in.
HOME_P="$TMP/profile"
PROFILE="$HOME_P/.claude-work"
mkdir -p "$PROFILE"
install_profile "$HOME_P" "$PROFILE"

check "installing under CLAUDE_CONFIG_DIR exits clean" "0" "$STATUS"
check "the script lands in the profile" "$VERSION" "$(version_of "$PROFILE/statusline.sh")"
check "the default directory is left alone" "gone" \
    "$([ -e "$HOME_P/.claude" ] && echo present || echo gone)"
check_command "the profile settings.json points at a statusline" "$PROFILE/settings.json"

install_profile "$HOME_P" "$PROFILE" --uninstall
check "uninstalling under CLAUDE_CONFIG_DIR clears the profile" "gone null" \
    "$([ -e "$PROFILE/statusline.sh" ] && echo present || echo gone) \
$(jq -r '.statusLine // "null"' "$PROFILE/settings.json" 2>/dev/null)"

# A profile nobody has installed into yet has no directory either.
HOME_Q="$TMP/profile-fresh"
mkdir -p "$HOME_Q"
install_profile "$HOME_Q" "$HOME_Q/.claude-personal"
check "a missing profile directory is created" "$VERSION" \
    "$(version_of "$HOME_Q/.claude-personal/statusline.sh")"

# The Windows branch of the command builder, run where Windows is not: cmd.exe
# expands neither variable in the POSIX command, so both paths are resolved at
# install time there.
WIN_COMMAND="the Windows command carries absolute paths"
selected "$WIN_COMMAND" && {
    if [ "$PLATFORM" = win32 ]; then
        skip "$WIN_COMMAND" "this run writes it for real"
    else
        built=$(node -e '
            const { statusLineCommand } = require(process.argv[1]);
            process.stdout.write(
                statusLineCommand("win32", "C:\\Users\\ROG\\.claude",
                                  "C:\\Program Files\\Git\\bin\\bash.exe"),
            );
        ' "$INSTALLER" 2>&1)
        check "$WIN_COMMAND" \
            '"C:\Program Files\Git\bin\bash.exe" "C:/Users/ROG/.claude/statusline.sh"' "$built"
    fi
}

# cmd.exe runs the command from wherever Claude Code is, not from where the
# install ran, so a bash named relatively has to be resolved before it is
# written down. The lookup itself is the same code on every platform.
RELATIVE_BASH="a relative CLAUDE_LINE_BASH is stored resolved"
selected "$RELATIVE_BASH" && {
    if [ "$PLATFORM" = win32 ]; then
        # A stand-in has to be a real .exe there, and a copied bash.exe comes
        # away from its DLLs.
        skip "$RELATIVE_BASH" "no runnable stand-in on Windows"
    else
        BASH_DIR="$TMP/relative-bash"
        mkdir -p "$BASH_DIR"
        printf '#!/bin/sh\nexit 0\n' > "$BASH_DIR/mybash"
        chmod +x "$BASH_DIR/mybash"
        found=$(cd "$BASH_DIR" && CLAUDE_LINE_BASH=./mybash node -e '
            const { findBash } = require(process.argv[1]);
            process.stdout.write(String(findBash()));
        ' "$INSTALLER" 2>&1)
        check "$RELATIVE_BASH" "$BASH_DIR/mybash" "$found"
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

# An install upgrades the string, but a settings.json can reach the uninstaller
# still carrying what an earlier release wrote.
HOME_S="$TMP/legacy-command"
mkdir -p "$HOME_S"
install_into "$HOME_S"
jq -n --arg command "$LEGACY_COMMAND" '{statusLine:{type:"command",command:$command}}' \
    > "$HOME_S/.claude/settings.json"
install_into "$HOME_S" --uninstall
check "uninstall recognises the command earlier releases wrote" "gone null" \
    "$([ -e "$HOME_S/.claude/statusline.sh" ] && echo present || echo gone) \
$(jq -r '.statusLine // "null"' "$HOME_S/.claude/settings.json" 2>/dev/null)"

# An uninstall command must not claim the conventional path by itself. A user
# script and the matching command can predate this package entirely.
HOME_I="$TMP/foreign"
mkdir -p "$HOME_I/.claude"
printf '#!/bin/bash\nprintf mine\n' > "$HOME_I/.claude/statusline.sh"
jq -n --arg command "$MANAGED_COMMAND" \
    '{statusLine:{type:"command",command:$command}}' > "$HOME_I/.claude/settings.json"
install_into "$HOME_I" --uninstall
check "uninstall leaves an unrecognised statusline untouched" "#!/bin/bash
printf mine" "$(cat "$HOME_I/.claude/statusline.sh")"
check "it leaves that script's setting untouched" "$MANAGED_COMMAND" \
    "$(jq -r '.statusLine.command' "$HOME_I/.claude/settings.json")"

HOME_J="$TMP/custom-setting"
mkdir -p "$HOME_J/.claude"
printf '{"statusLine":{"type":"command","command":"printf custom"}}\n' \
    > "$HOME_J/.claude/settings.json"
install_into "$HOME_J" --uninstall
check "uninstall leaves a custom statusLine command untouched" "printf custom" \
    "$(jq -r '.statusLine.command' "$HOME_J/.claude/settings.json")"

# Parse settings before changing the script, so malformed JSON cannot leave a
# half-uninstalled setup behind.
HOME_K="$TMP/broken-uninstall"
mkdir -p "$HOME_K"
install_into "$HOME_K"
printf 'not json\n' > "$HOME_K/.claude/settings.json"
install_into "$HOME_K" --uninstall
check "uninstall aborts on malformed settings" "1" "$STATUS"
check "a malformed settings file leaves the managed script in place" "$VERSION" \
    "$(version_of "$HOME_K/.claude/statusline.sh")"

# The published 1.0.6 blob predates the marker. Exercise it when the checkout
# carries that ancestor; shallow source archives skip while the hash allowlist
# remains deterministic in the installer.
LEGACY_COMMIT=ea02c0e6dcd532fea6056f7eec2b7545b3666248
if git cat-file -e "$LEGACY_COMMIT:bin/statusline.sh" 2>/dev/null; then
    HOME_L="$TMP/legacy"
    mkdir -p "$HOME_L/.claude"
    git show "$LEGACY_COMMIT:bin/statusline.sh" > "$HOME_L/.claude/statusline.sh"
    jq -n --arg command "$LEGACY_COMMAND" \
        '{statusLine:{type:"command",command:$command}}' > "$HOME_L/.claude/settings.json"
    install_into "$HOME_L" --uninstall
    check "uninstall recognises a published pre-marker script" "gone" \
        "$([ -e "$HOME_L/.claude/statusline.sh" ] && echo present || echo gone)"
    check "legacy uninstall removes its managed setting" "null" \
        "$(jq -r '.statusLine // "null"' "$HOME_L/.claude/settings.json")"

    HOME_N="$TMP/legacy-upgrade"
    mkdir -p "$HOME_N/.claude"
    git show "$LEGACY_COMMIT:bin/statusline.sh" > "$HOME_N/.claude/statusline.sh"
    install_into "$HOME_N"
    check "upgrade recognises a published pre-marker script" "$VERSION" \
        "$(version_of "$HOME_N/.claude/statusline.sh")"
    check "legacy upgrade does not back up our old release" "gone" \
        "$([ -e "$HOME_N/.claude/statusline.sh.bak" ] && echo present || echo gone)"
    install_into "$HOME_N" --uninstall
    check "an upgraded legacy install still uninstalls cleanly" "gone" \
        "$([ -e "$HOME_N/.claude/statusline.sh" ] && echo present || echo gone)"

    HOME_O="$TMP/legacy-twice"
    mkdir -p "$HOME_O/.claude"
    git show "$LEGACY_COMMIT:bin/statusline.sh" > "$HOME_O/.claude/statusline.sh"
    git show "$LEGACY_COMMIT:bin/statusline.sh" > "$HOME_O/.claude/statusline.sh.bak"
    jq -n --arg command "$LEGACY_COMMAND" \
        '{statusLine:{type:"command",command:$command}}' > "$HOME_O/.claude/settings.json"
    install_into "$HOME_O" --uninstall
    check "legacy uninstall does not restore an old package backup" "gone gone" \
        "$([ -e "$HOME_O/.claude/statusline.sh" ] && echo present || echo gone) \
$([ -e "$HOME_O/.claude/statusline.sh.bak" ] && echo present || echo gone)"
else
    skip "uninstall recognises a published pre-marker script" "published ancestor not in shallow checkout"
    skip "legacy uninstall removes its managed setting" "published ancestor not in shallow checkout"
    skip "upgrade recognises a published pre-marker script" "published ancestor not in shallow checkout"
    skip "legacy upgrade does not back up our old release" "published ancestor not in shallow checkout"
    skip "an upgraded legacy install still uninstalls cleanly" "published ancestor not in shallow checkout"
    skip "legacy uninstall does not restore an old package backup" "published ancestor not in shallow checkout"
fi

UNSAFE_BACKUP="uninstall refuses a symlinked backup"
if selected "$UNSAFE_BACKUP"; then
    HOME_M="$TMP/unsafe-backup"
    mkdir -p "$HOME_M"
    install_into "$HOME_M"
    printf 'keep me' > "$TMP/unsafe-backup-target"
    if ln -s "$TMP/unsafe-backup-target" "$HOME_M/.claude/statusline.sh.bak" 2>/dev/null &&
       [ -L "$HOME_M/.claude/statusline.sh.bak" ]; then
        install_into "$HOME_M" --uninstall
        if [ "$STATUS" -eq 1 ] && [ "$(version_of "$HOME_M/.claude/statusline.sh")" = "$VERSION" ] &&
           [ "$(cat "$TMP/unsafe-backup-target")" = "keep me" ]; then
            report_pass "$UNSAFE_BACKUP"
        else
            report_fail "$UNSAFE_BACKUP" "exit 1 + untouched script and target" \
                "exit $STATUS version=$(version_of "$HOME_M/.claude/statusline.sh") target=$(cat "$TMP/unsafe-backup-target")"
        fi
    else
        skip "$UNSAFE_BACKUP" "no symlink support here"
    fi
fi

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

# Installing twice used to copy our own script over the backup, so the user's
# original was gone and uninstall handed back ours.
HOME_F="$TMP/byo-twice"
mkdir -p "$HOME_F/.claude"
printf '#!/bin/bash\nprintf mine\n' > "$HOME_F/.claude/statusline.sh"
install_into "$HOME_F"
install_into "$HOME_F"
check "a second install leaves the first backup alone" "#!/bin/bash
printf mine" "$(cat "$HOME_F/.claude/statusline.sh.bak" 2>/dev/null)"

install_into "$HOME_F" --uninstall
check "uninstall after two installs still returns the user's script" "#!/bin/bash
printf mine" "$(cat "$HOME_F/.claude/statusline.sh" 2>/dev/null)"

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
