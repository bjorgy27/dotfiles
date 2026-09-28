#!/usr/bin/env bash
# Picks a random image from ~/.config/wallpapers (excluding the current one,
# when more than one option exists) and hands it to wallpaper_select.sh.
set -euo pipefail

CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
WALLPAPER_DIR="$CONFIG_HOME/wallpapers"
SAVE_FILE="$CONFIG_HOME/scripts/wallpaper/wpsave.txt"

mapfile -d '' candidates < <(find "$WALLPAPER_DIR" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
    -print0)

(( ${#candidates[@]} > 0 )) || { echo "No wallpapers found in $WALLPAPER_DIR" >&2; exit 1; }

current=$(cat "$SAVE_FILE" 2>/dev/null || true)

if (( ${#candidates[@]} > 1 )) && [[ -n "$current" ]]; then
    filtered=()
    for c in "${candidates[@]}"; do
        [[ "$c" == "$current" ]] || filtered+=("$c")
    done
    candidates=("${filtered[@]}")
fi

pick=${candidates[RANDOM % ${#candidates[@]}]}
exec "$CONFIG_HOME/scripts/wallpaper/wallpaper_select.sh" "$pick"
