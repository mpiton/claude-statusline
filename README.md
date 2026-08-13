# claude-statusline

[![CI](https://github.com/mpiton/claude-statusline/actions/workflows/ci.yml/badge.svg)](https://github.com/mpiton/claude-statusline/actions/workflows/ci.yml)

Configure your Claude Code statusline to show limits, directory and git info

![demo](./.github/demo.png)

## Install

Run the command below to set it up

```bash
npx @kamranahmedse/claude-statusline
```

It backups your old status line if any and copies the status line script to `~/.claude/statusline.sh` and configures your Claude Code settings.

The installed copy carries the release it came from on its second line:

```bash
head -2 ~/.claude/statusline.sh    # => # statusline-version: 1.0.6
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
npx @kamranahmedse/claude-statusline --uninstall
```

If you had a previous statusline, it restores it from the backup. Otherwise it removes the script and cleans up your settings.

## License

MIT
