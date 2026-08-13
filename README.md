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

## Requirements

- [jq](https://jqlang.github.io/jq/) — for parsing JSON
- curl — for fetching rate limit data
- git — for branch info

On macOS:

```bash
brew install jq
```

## Tests

```bash
npm test                   # everything
npm run lint               # shellcheck
bash test/run.sh effort    # only cases whose name contains "effort"
```

`test/run.sh` pipes a statusline JSON payload into `bin/statusline.sh` and checks what it renders. The run is sandboxed — `TZ` is pinned to UTC, `HOME` and the usage cache point at a temp dir, and `curl` is stubbed — so nothing touches the network or your real config. Cases that need a comma-decimal locale are skipped if none is installed.

`test/install.sh` runs `bin/install.js` against a throwaway `HOME` and checks the install, the uninstall and the backup round-trip.

Both take a filter argument. CI runs shellcheck, then the suite on Linux, macOS and Windows/Git Bash. The installer tests are Linux and macOS only — `bin/install.js` probes for `jq`/`curl`/`git` with `which`, which does not resolve under `cmd.exe`.

## Uninstall

```bash
npx @kamranahmedse/claude-statusline --uninstall
```

If you had a previous statusline, it restores it from the backup. Otherwise it removes the script and cleans up your settings.

## License

MIT
