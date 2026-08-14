# Claude Line

[![CI](https://github.com/mpiton/claude-statusline/actions/workflows/ci.yml/badge.svg)](https://github.com/mpiton/claude-statusline/actions/workflows/ci.yml)

Configure your Claude Code statusline to show limits, directory and git info

![demo](./.github/demo.png)

## Install

Run the command below to set it up

```bash
npx @mpiton/claude-line
```

It backs up your old status line if any, copies the status line script to
`~/.claude/statusline.sh`, and configures your Claude Code settings.

The installed copy carries the release it came from on its second line:

```bash
sed -n 2p ~/.claude/statusline.sh    # => # statusline-version: 2.0.0
```

Rerun the install command to update it. A copy that is already current is left
where it is, and an older one of ours is replaced rather than backed up — only
a statusline you wrote yourself ends up in `statusline.sh.bak`.

## Requirements

- [jq](https://jqlang.github.io/jq/) — for parsing JSON
- curl — for fetching rate limit data
- git — for branch info

On macOS:

```bash
brew install jq
```

On Windows the statusline runs under the bash that Git for Windows ships, which
brings curl and git with it. jq you install yourself:

```bash
winget install jqlang.jq
```

## Cache

Rate limit responses and the git dirty flag are cached in
`${XDG_CACHE_HOME:-~/.cache}/claude-statusline`, created private to you.
`CLAUDE_STATUSLINE_CACHE_DIR` moves it. A directory that is a symlink, or that
another user owns, is left alone and caching is skipped for that run. Inside a
directory that passes, each cache file is checked the same way, so a file
planted before the first render is neither read nor written through.

The five-hour line adds a burn rate after one minute of observations. Samples
are kept at most once a minute, only for the current reset window, and age out
after five hours. The pace is green when its projection stays below 90% at the
reset, yellow for 90–99%, and red when it would exhaust the allowance first.

## Configuration

Create `~/.claude/statusline.json` to override the defaults. The example below
shows every supported setting; omitted keys keep their built-in value.

```json
{
  "blocks": [
    "model", "context", "directory", "cost", "changes", "style", "effort",
    "current", "burn", "weekly", "extra"
  ],
  "bar_width": 10,
  "colors": {
    "blue": "#0099ff",
    "orange": "#ffb055",
    "green": "#00af50",
    "cyan": "#56b6c2",
    "red": "#ff5555",
    "yellow": "#e6c800",
    "white": "#dcdcdc",
    "magenta": "#b48cff"
  }
}
```

Blocks always render in the order above; the array only selects them. `burn`
is part of `current`, and has no effect when `current` is hidden. `bar_width`
accepts integers from 1 to 40 and colors accept `#RRGGBB`. Invalid values are
ignored. Set `CLAUDE_STATUSLINE_CONFIG` to use another file.

## Tests

```bash
npm test                   # everything
npm run lint               # shellcheck
bash test/run.sh effort    # only cases whose name contains "effort"
```

`test/run.sh` pipes a statusline JSON payload into `bin/statusline.sh` and checks what it renders. The run is sandboxed — `TZ` is pinned to UTC, `HOME` and the usage cache point at a temp dir, and `curl` is stubbed — so nothing touches the network or your real config. Cases that need a comma-decimal locale are skipped if none is installed.

`test/install.sh` runs `bin/install.js` against a throwaway `HOME` and checks the install, the uninstall and the backup round-trip.

Both take a filter argument. CI runs shellcheck, then the full suite on Linux, macOS and Windows/Git Bash.

## Uninstall

```bash
npx @mpiton/claude-line --uninstall
```

If you had a previous statusline, it restores it from the backup. Otherwise it
removes the script and cleans up your settings. The uninstaller only changes a
versioned copy from this package, or an exact copy of one of its pre-versioned
npm releases; an unknown script or custom setting is left alone.

## License

MIT
