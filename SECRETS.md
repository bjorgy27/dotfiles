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

## Bambu Lab printer (LAN mode)

The `bambu` quickshell widget reads print progress straight off the printer, with no
cloud account involved. It needs the printer's address, serial and LAN access code:

```sh
cat > ~/.config/bambu.conf <<'EOF'
BAMBU_HOST=<printer's address on the LAN>
BAMBU_SERIAL=<serial, shown on the printer and in Bambu Studio>
BAMBU_CODE=<LAN access code from the printer screen>
EOF
chmod 600 ~/.config/bambu.conf
```

The access code lives on the printer under network / LAN mode settings, and changes if
LAN mode is toggled off and on. Used by `scripts/polls/bambupoll.sh`, which shells out to
`scripts/polls/bambu_mqtt.py`. Without the file the widget just shows a setup hint.

Note the address is whatever DHCP handed the printer; a static lease is worth setting.

## Claude Code login

`~/.claude/.credentials.json` is per-machine and is not in this repo. On the new machine, run:

```sh
claude
```

and complete the login flow normally. Global `settings.json` and this machine's memory files
are already restored by `install.sh`.
