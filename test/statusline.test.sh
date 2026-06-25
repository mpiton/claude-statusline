#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/bin/statusline.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

tmp_home=$(mktemp -d)
cleanup() {
    if command -v trash >/dev/null 2>&1; then
        trash "$tmp_home" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

mkdir -p "$tmp_home/.claude"
printf '{"effortLevel":"xhigh"}\n' > "$tmp_home/.claude/settings.json"

input=$(cat <<JSON
{
  "model": {"display_name": "Claude Opus"},
  "effort": {"level": "max"},
  "context_window": {
    "context_window_size": 200000,
    "current_usage": {
      "input_tokens": 1000,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 0
    }
  },
  "cwd": "$repo_root",
  "rate_limits": {
    "five_hour": {"used_percentage": 12, "resets_at": 1792929600},
    "seven_day": {"used_percentage": 25, "resets_at": 1793361600}
  }
}
JSON
)

output=$(HOME="$tmp_home" bash "$script" <<< "$input")

case "$output" in
    *"max"*) ;;
    *) fail "expected statusline to display live effort level 'max'; got: $output" ;;
esac

case "$output" in
    *"xhigh"*) fail "expected stdin effort to override settings effort; got: $output" ;;
esac

printf 'PASS: statusline displays live max effort\n'
