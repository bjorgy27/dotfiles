# Manual steps (not synced by this repo)

These are intentionally excluded from git so they never end up in a repo, even a private one.

## API keys

Create these two files on the new machine, then lock down permissions:

```sh
echo '<your canvas token>' > ~/.config/canvas.key
echo '<your tessie token>' > ~/.config/tessie.key
chmod 600 ~/.config/canvas.key ~/.config/tessie.key
```

- `canvas.key` - Canvas LMS API token, used by `scripts/polls/canvaspoll.sh`
  (points at `https://erau.instructure.com`)
- `tessie.key` - Tessie (Tesla) API token, used by `scripts/polls/tessiepoll.sh`,
  `tessiecmd.sh`, `_tessie.sh`

Without these, the corresponding quickshell widgets will just show their "no api key" error
state - nothing else breaks.

## Claude Code login

`~/.claude/.credentials.json` is per-machine and is not in this repo. On the new machine, run:

```sh
claude
```

and complete the login flow normally. Global `settings.json` and this machine's memory files
are already restored by `install.sh`.
