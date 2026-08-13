# claude-statusline

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
npm test              # everything
npm test -- effort    # only cases whose name contains "effort"
```

Each case pipes a statusline JSON payload into `bin/statusline.sh` and checks what it renders. The run is sandboxed — `TZ` is pinned to UTC, `HOME` and the usage cache point at a temp dir, and `curl` is stubbed — so nothing touches the network or your real config. Cases that need a comma-decimal locale are skipped if none is installed.

## Uninstall

```bash
npx @kamranahmedse/claude-statusline --uninstall
```

If you had a previous statusline, it restores it from the backup. Otherwise it removes the script and cleans up your settings.

## License

MIT
