# Dashboard presets

The dashboard (SUPER+N) is laid out from `presets.json`; SUPER+SHIFT+N cycles
presets, and the last one picked is remembered in
`~/.local/state/quickshell/dashboard.json`. Both preset files are watched, so
edits show up live. Adapted from gagehauptman/dotfiles (`DashboardConfig.qml`).

```json
{ "active": "default",
  "presets": {
    "name": {
      "columns": 6,            // equal-width columns (landscape)
      "widthPercent": 60,      // pocket length along the bar, % of the screen
      "widgets": [ { "type": "radar", "col": 2, "row": 0, "colSpan": 4, "rowSpan": 4.2, "options": {} } ],
      "portrait": { "columns": 2, "widgets": [ ... ] }   // optional; else auto re-pack
    } } }
```

- `type`: one of the registry keys in `DashboardConfig.qml`: canvas, systemstats,
  miscstats, radar, weather, network, music. New widget = one registry line.
- `col`/`row` pin a widget; leave them out and it flows into the lowest free
  spot. Rows can be fractional. Row height is one dashboard widget height.
- `presets.local.json` (gitignored) adds or replaces presets on one machine.
- IPC: `qs ipc call dashboard setPreset <name> | nextPreset | listPresets | reload`.
