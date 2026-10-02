# Lock screen

Ported from gagehauptman/dotfiles (e6f2eee, bc567de, 73b8c23) onto `beck`.

`lock.sh` is what Super+L, the power menu's Lock, hypridle (`lock_cmd`) and
Q's lockdown run. It is a real ext-session-lock-v1 client: a Quickshell
`WlSessionLock` (`qs/shell.qml`) in its own Quickshell instance, not the bar's.
PAM is Quickshell's `PamContext` on the `hyprlock` service (`auth include
login`), so the login password works. If the client dies within 3 s of starting,
`lock.sh` falls back to `hyprlock` with `hypr/hyprlock.conf`, briefly allowing
Hyprland's lock restore so hyprlock can take over a lock the client already
held. It never logs out.

`lockgen.py` resolves the current wallpaper (`scripts/wallpaper/wpsave.txt`)
into `$XDG_RUNTIME_DIR/lockscreen/lock.json`, which the QML reads.

## What differs from upstream

- Wallpapers here are flat files (`wallpapers/<stem>.jpg`), not upstream's
  per-wallpaper folders, so a wallpaper's lock settings are
  `meta/<stem>.toml` and its depth masks `meta/<stem>/*.png`. A
  `wallpapers/<stem>/lock.toml` still wins if one ever exists.
- No live Bevy background (this repo doesn't build the Bevy QML module): a
  `.live` wallpaper shows its still `wallpapers/<stem>.png`, else the flat colour.
- Font: Adwaita Sans (Inter-based) instead of Inter Display, which isn't installed.
- `meta/layouts/right.toml` offsets x by -5% (upstream's +5% pushed the column
  off the right edge).
- `lock.sh --locked` (exit 0 if any lock is up, ignoring orphaned hyprlocks),
  used by lock.sh itself and by lockdown. The `--test` PAM fixture is written to
  `$XDG_RUNTIME_DIR` at run time, so no machine's repo path is hardcoded.
- Not ported: upstream's hyprlock.conf restyle (Beck's stays as the fallback),
  the old `clock.sh`/`markup.sh` helpers, the 20+ upstream wallpapers and their
  masks.

## Layout and text

- `meta/<stem>.toml` over `meta/default.toml`; a file lists only what it
  changes. `base = "left"` / `"right"` pulls in `meta/layouts/`. A wallpaper
  without its own file gets the centred default.
- Positions are `"x%, y%"` (+y up) from the `halign`/`valign` anchor.
- Alignment is by ink: an element's box is its glyphs' tight width x the font's
  cap height, so a big clock, a tracked date and the field share an edge.
- `below = "clock"` / `above = "input"` + `gap` hangs an element off another.
- `font_size` is points or `"N%"` of the screen height. Points scale with the
  screen (designed for 1440 px tall), so they hold their proportions on the
  laptop and on portrait screens; `%` sizes follow height only.
- Per element: `font_family`, `font_weight`, `font_size`, `letter_spacing`,
  `uppercase`, `font_style`, `color`, `opacity`, `format`/`text`,
  `shadow_strength`, `position`, `show`. `[text] accent` is the field's typing
  colour. The field also takes `size`, `rounding`, `inner_color`,
  `outer_color`, `highlight_color`, `fail_text`, `placeholder_text`.
- Per monitor: `[monitor."DP-2".clock]`, but names differ between the desktop
  and the laptop, so prefer layouts that work on any screen.

## Depth (optional)

Masks put text between the background and the subject (`[depth]`,
`depth = "behind"|"far"` per element; see `meta/default.toml`). `masks.py STEM`
makes a subject mask with BiRefNet (needs the rembg venv described in its
docstring); `masks.py --sky STEM` a skyline mask for silhouettes against a bright
sky (Pillow + numpy only). Neither current wallpaper has masks: shuttle.jpg's
subject is tiny, and firewatch's sky darkens upward, which the `--sky`
heuristic can't handle.

## Testing safely

- `lock.sh --preview [DIR]`: renders every monitor offscreen to
  `DIR/<monitor>.png`; nothing shows, no PAM. `LOCK_WALLPAPER=path` previews
  another wallpaper, `LOCK_PREVIEW_BOXES=1` outlines the alignment boxes.
- `python3 lockgen.py --check [--monitors eDP-1:1920x1200,...]` validates the
  config per monitor.
- `lock.sh --test [SECS]`: the same screens as overlay windows, NOT a lock,
  closed after SECS (default 15). PAM accepts only `letmein`.
  `LOCK_TEST_PASSWORD=letmein` auto-types it; `LOCK_TEST_KEYS="abc<<x!"` types
  (`<` backspace, `!` enter).
- `lock.sh --try [SECS]`: a real lock that unlocks itself after SECS (default
  10), with a watchdog.
- Real lock: keep a TTY open (Ctrl+Alt+F3). `lock.sh --unlock` from it unlocks;
  if the client was killed and Hyprland shows "lockscreen died",
  `lock.sh --recover`.

Revert: point Super+L (`hypr/hyprland.lua`), the power menu
(`quickshell/PowerMenuWidget.qml`) and hypridle's `lock_cmd` back at `hyprlock`.
