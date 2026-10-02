#!/usr/bin/env bash
# Point $XDG_CACHE_HOME/hyprlock/wallpaper at the wallpaper currently picked in
# the quickshell selector (wallpaper_select.sh saves it to wpsave.txt), and
# print that link for hyprlock's background reload_cmd.
#
# hyprlock only reloads when the printed path or the target's mtime changes,
# so printing the (constant) link path means it reloads only on a real change.
# It runs this synchronously on its main thread: keep it to file tests.
#
# A dynamic wallpaper (<stem>.live, or a gif) can't be a still background, so
# its still wallpapers/<stem>.png is used, else the old lock.png art.

CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}
SAVE_FILE="$CONFIG_HOME/scripts/wallpaper/wpsave.txt"
WALLPAPER_DIR="$CONFIG_HOME/wallpapers"
FALLBACK="$CONFIG_HOME/scripts/lock/lock.png"
LINK="$CACHE_HOME/hyprlock/wallpaper"

sel=$(head -n1 "$SAVE_FILE" 2>/dev/null)
stem=${sel##*/}
stem=${stem%.*}

case ${sel,,} in
  *.png|*.jpg|*.jpeg|*.webp|*.jxl|*.bmp) target=$sel ;;
  *) target="$WALLPAPER_DIR/$stem.png" ;;
esac
[[ -n $stem && -f $target ]] || target=$FALLBACK

mkdir -p "${LINK%/*}"
[[ $(readlink -- "$LINK") == "$target" ]] || ln -sfn -- "$target" "$LINK"
printf '%s\n' "$LINK"
