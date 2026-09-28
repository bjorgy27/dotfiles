#!/usr/bin/env bash
set -euo pipefail

# Usage: wallpaper_select.sh [--preview] <wallpaper_path>
#        wallpaper_select.sh --warm
#
# Everything is kept warm so switching is instant:
# - awww-daemon is never killed. Static images go through it, and a
#   pre-scaled copy per output size (see --warm) is used when cached, so awww
#   neither decodes a 5-8K original nor resizes. The copies live in RAM.
# - A dynamic wallpaper whose bin dir has a `.keep-warm` marker (the globe,
#   the space shuttle) runs all the time on a background layer mapped above
#   awww's. It's shown or hidden (a transparent 1x1 buffer stretched over the
#   output, 0% CPU) through a control FIFO. Nothing maps, unmaps or resizes a
#   layer, so Hyprland never moves keyboard focus away from the selector or
#   animates it.
# - All warm wallpapers are scenes of one renderer (bins/spinning_globe; a
#   warm stem's bin dir may just hold a `run` that starts it with
#   `--scene <stem>`). Switching between them is `show <stem>` on the FIFO:
#   a redraw on the same layers, no restart.
#
# A dynamic wallpaper is picked by stem: wallpapers/<stem>.live (a descriptor
# the selector lists and previews live) runs bins/<stem>. Any other extension
# with that stem (the old spinning_globe.png in a saved selection) works too.
#
# --preview: the selector is still open. Show the selection but don't save it.
#   A dynamic wallpaper that isn't warm-capable only gets its still
#   (wallpapers/<stem>.png, if it has one).
# --warm: start warm-capable dynamic wallpapers hidden (if not running) and
#   fill the pre-scaled cache in the background.
mode=apply
case ${1:-} in
  --preview) mode=preview; shift ;;
  --warm) mode=warm; shift ;;
esac

CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}
RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
SAVE_FILE="$CONFIG_HOME/scripts/wallpaper/wpsave.txt"
BIN_ROOT="$CONFIG_HOME/scripts/wallpaper/bins"
WALLPAPER_DIR="$CONFIG_HOME/wallpapers"
STATE_DIR="$CACHE_HOME/wallpaper_select"
PID_FILE="$STATE_DIR/dynamic.pid"
STEM_FILE="$STATE_DIR/dynamic.stem"
VISIBLE_FILE="$STATE_DIR/dynamic.visible"
LATEST_FILE="$STATE_DIR/latest"
LOG_DIR="$STATE_DIR/logs"
# In RAM (tmpfs): kept warm, costs no disk, refilled by --warm after a reboot.
SCALED_DIR="$RUNTIME_DIR/wallpaper_select/scaled"
SELF=$(realpath -- "${BASH_SOURCE[0]}")

mkdir -p "$(dirname "$SAVE_FILE")" "$LOG_DIR" "$SCALED_DIR"

selection=""
if [[ $mode != warm ]]; then
  selection=${1:?Usage: $0 [--preview|--warm] <wallpaper_path>}
fi

alive() {
  [[ ${1:-} =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null
}

# Kernel start time of a pid (clock ticks since boot), for ordering.
start_ticks() {
  local stat
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || { echo 0; return; }
  stat=${stat##*) }
  awk '{print $20}' <<<"$stat"
}

# One FIFO for the warm renderer, whichever of its scenes it shows.
control_fifo() {
  printf '%s/wallpaper-live.ctl' "$RUNTIME_DIR"
}

running_pid() { cat "$PID_FILE" 2>/dev/null || true; }
running_stem() { cat "$STEM_FILE" 2>/dev/null || true; }

warm_capable() { [[ -n ${1:-} && -f "$BIN_ROOT/$1/.keep-warm" ]]; }

# The running dynamic wallpaper can be shown/hidden without restarting it.
running_is_warm() {
  local pid stem
  pid=$(running_pid)
  stem=$(running_stem)
  alive "$pid" && warm_capable "$stem" && [[ -p $(control_fifo) ]]
}

# Writing is safe: the process holds the FIFO open read-write, so this never
# blocks while it's alive (and running_is_warm checked that).
# `show <stem>` switches the renderer to that scene.
send_control() {
  printf '%s\n' "$*" >"$(control_fifo)"
  if [[ $1 == show ]]; then
    echo 1 >"$VISIBLE_FILE"
    [[ -n ${2:-} ]] && printf '%s\n' "$2" >"$STEM_FILE"
  else
    echo 0 >"$VISIBLE_FILE"
  fi
  return 0
}

dynamic_visible() {
  alive "$(running_pid)" && [[ $(cat "$VISIBLE_FILE" 2>/dev/null || echo 1) == 1 ]]
}

stop_dynamic() {
  local pid
  pid=$(running_pid)
  rm -f "$PID_FILE" "$STEM_FILE" "$VISIBLE_FILE"
  alive "$pid" || return 0

  kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    alive "$pid" || return 0
    sleep 0.02
  done
  kill -KILL -- "-$pid" 2>/dev/null || true
}

awww_pid() { pgrep -xo awww-daemon || true; }

start_awww() {
  [[ -n $(awww_pid) ]] && return 0
  (exec 9>&- 8>&-; exec setsid awww-daemon >"$LOG_DIR/awww-daemon.log" 2>&1) &
  for _ in $(seq 50); do
    awww query >/dev/null 2>&1 && return 0
    sleep 0.02
  done
}

# Outputs as "name width height" lines, from awww (physical pixels).
outputs() {
  awww query 2>/dev/null | sed -nE 's/^:?[[:space:]]*([^:[:space:]]+): ([0-9]+)x([0-9]+).*/\1 \2 \3/p'
}

# Cached pre-scaled copy of $1 for a WxH output (may not exist yet).
scaled_path() {
  local src=$1 w=$2 h=$3 real key
  real=$(realpath -- "$src" 2>/dev/null || printf '%s' "$src")
  key=$(stat -c '%s-%Y' -- "$real" 2>/dev/null || echo 0)
  key=$(printf '%s|%s' "$real" "$key" | md5sum)
  printf '%s/%sx%s/%s.png' "$SCALED_DIR" "$w" "$h" "${key%% *}"
}

cacheable() {
  case ${1,,} in
    *.gif) return 1 ;; # animated: awww plays it, a still copy would break that
    *) [[ -f $1 ]] ;;
  esac
}

# Cover-scale and centre-crop to exactly WxH (awww's default crop), so awww
# only has to load a screen-sized PNG. Originals are never modified.
make_scaled() {
  local src=$1 w=$2 h=$3 dst tmp
  dst=$(scaled_path "$src" "$w" "$h")
  [[ -s $dst ]] && return 0
  mkdir -p "${dst%/*}"
  tmp="${dst%.png}.tmp.$$.png"
  if vips thumbnail "$src" "$tmp[compression=1,strip]" "$w" --height "$h" --crop centre --size both 2>/dev/null; then
    mv -f "$tmp" "$dst"
  else
    rm -f "$tmp"
    return 1
  fi
}

show_static() {
  local transition=${1:-outer} pos name w h file
  pos="0.$((RANDOM % 999)),0.$((RANDOM % 999))"
  local -a pids=()
  local query
  query=$(awww query 2>/dev/null || true)
  while read -r name w h; do
    file=$selection
    if cacheable "$selection"; then
      file=$(scaled_path "$selection" "$w" "$h")
      [[ -s $file ]] || file=$selection
    fi
    # Skip outputs already showing it (e.g. committing what was previewed).
    if grep -F "$name: " <<<"$query" | grep -qF "image: $file"; then
      continue
    fi
    awww img -o "$name" \
      --transition-type "$transition" \
      --transition-pos "$pos" \
      --transition-step 25 \
      --transition-fps 120 \
      --transition-duration 0.15 \
      "$file" &
    pids+=("$!")
  done < <(outputs)

  local rc=0
  for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
  return "$rc"
}

# Launch the dynamic wallpaper for $stem. Visible unless $2 == hidden.
launch_dynamic() {
  local stem=$1 visibility=${2:-visible} bin_dir bin="" release_dir package_name
  bin_dir="$BIN_ROOT/$stem"

  [[ -x "$bin_dir/run" ]] && bin="$bin_dir/run"
  [[ -z "$bin" && -x "$bin_dir/$stem" ]] && bin="$bin_dir/$stem"

  if [[ -z "$bin" && -f "$bin_dir/Cargo.toml" ]]; then
    release_dir="$bin_dir/target/release"
    package_name=$(grep -m1 '^[[:space:]]*name[[:space:]]*=' "$bin_dir/Cargo.toml" | cut -d= -f2 | tr -d ' "')
    bin="$release_dir/$package_name"

    if [[ ! -x "$bin" ]]; then
      cargo build --release --manifest-path "$bin_dir/Cargo.toml" >&2
      bin=$(find "$release_dir" -maxdepth 1 -type f -perm -111 ! -name '*.d' ! -name '*.rlib' ! -name '*.so' | sort | head -n1)
    fi
  fi

  [[ -n "$bin" ]] || bin=$(find "$bin_dir" -maxdepth 1 -type f -perm -111 | sort | head -n1)
  [[ -n "$bin" ]] || { echo "No launcher for $stem" >&2; return 1; }

  stop_dynamic
  # awww must be up first: its layer then sits below the dynamic one.
  start_awww
  : >"$LOG_DIR/$stem.log"

  local fifo
  fifo=$(control_fifo)
  rm -f "$fifo"
  (
    exec 9>&- 8>&-
    cd "$bin_dir"
    export GLOBE_CONTROL="$fifo"
    warm_capable "$stem" && export WALLPAPER_SCENE="$stem"
    [[ $visibility == hidden ]] && export GLOBE_HIDDEN=1
    exec setsid "$bin" >>"$LOG_DIR/$stem.log" 2>&1
  ) &

  printf '%s\n' "$!" >"$PID_FILE"
  printf '%s\n' "$stem" >"$STEM_FILE"
  if [[ $visibility == hidden ]]; then echo 0 >"$VISIBLE_FILE"; else echo 1 >"$VISIBLE_FILE"; fi

  # Wait for the control FIFO so a show/hide right after doesn't miss it.
  if [[ -f "$bin_dir/.keep-warm" ]]; then
    for _ in $(seq 50); do
      [[ -p $fifo ]] && break
      sleep 0.01
    done
  fi
}

# The first warm-capable dynamic wallpaper, if any.
warm_stem() {
  local dir
  for dir in "$BIN_ROOT"/*/; do
    [[ -f "$dir.keep-warm" ]] && { basename "$dir"; return 0; }
  done
  return 1
}

if [[ $mode == warm ]]; then
  exec 9>"$STATE_DIR/lock"
  flock -x 9
  start_awww
  if ! alive "$(running_pid)"; then
    # On the saved wallpaper's scene if it's a warm one (any will do).
    stem=$(cat "$SAVE_FILE" 2>/dev/null || true)
    stem=${stem##*/}
    stem=${stem%.*}
    warm_capable "$stem" || stem=$(warm_stem) || stem=""
    [[ -n $stem ]] && launch_dynamic "$stem" hidden
  fi
  flock -u 9
  exec 9>&-

  # Fill the cache for every still image and output size, one job at a time.
  exec 8>"$STATE_DIR/cache.lock"
  flock -n 8 || exit 0
  mapfile -t outs < <(outputs)
  (( ${#outs[@]} )) || exit 0
  declare -A keep=()
  for src in "$WALLPAPER_DIR"/*; do
    cacheable "$src" || continue
    case ${src,,} in *.png|*.jpg|*.jpeg|*.webp|*.tif|*.tiff|*.bmp) ;; *) continue ;; esac
    for out in "${outs[@]}"; do
      read -r _ w h <<<"$out"
      make_scaled "$src" "$w" "$h" || true
      keep[$(scaled_path "$src" "$w" "$h")]=1
    done
  done
  # Drop copies of replaced/removed images and old output sizes.
  while IFS= read -r -d '' f; do
    [[ -n ${keep[$f]:-} ]] || rm -f -- "$f"
  done < <(find "$SCALED_DIR" -type f -print0)
  find "$SCALED_DIR" -mindepth 1 -type d -empty -delete
  exit 0
fi

# Waiters on the lock wake in no particular order, so a preview that was
# superseded (by a newer preview or a commit) while waiting must not run.
token="$$-$(date +%s%N)"
printf '%s\n' "$token" >"$LATEST_FILE"

exec 9>"$STATE_DIR/lock"
flock -x 9

if [[ $mode == preview ]] && [[ $(cat "$LATEST_FILE" 2>/dev/null || true) != "$token" ]]; then
  exit 0
fi

stem=${selection##*/}
stem=${stem%.*}
bin_dir="$BIN_ROOT/$stem"
# Saved and listed as its descriptor, whatever path it came in as.
if [[ -d $bin_dir && -f "$WALLPAPER_DIR/$stem.live" ]]; then
  selection="$WALLPAPER_DIR/$stem.live"
fi

if [[ -d "$bin_dir" ]]; then
  if warm_capable "$stem" && running_is_warm; then
    apid=$(awww_pid)
    if [[ -n $apid && $(start_ticks "$apid") -gt $(start_ticks "$(running_pid)") ]]; then
      # awww was restarted after the renderer and now covers it: relaunch.
      launch_dynamic "$stem"
    else
      send_control show "$stem"
    fi
  elif [[ $(running_stem) == "$stem" ]] && alive "$(running_pid)" && [[ ! -f "$bin_dir/.keep-warm" ]]; then
    # Non-warm dynamic already running; awww previews may cover it, and
    # (as before) only unmapping awww uncovers it.
    if [[ $mode == apply ]]; then
      pkill -x awww-daemon 2>/dev/null || true
    fi
  elif [[ $mode == preview && ! -f "$bin_dir/.keep-warm" ]]; then
    # Starting/stopping it would map/unmap layers while the selector is open;
    # show its preview image instead (a non-warm dynamic stays running).
    if running_is_warm; then send_control hide; fi
    start_awww
    if [[ -f "$WALLPAPER_DIR/$stem.png" ]]; then
      selection="$WALLPAPER_DIR/$stem.png"
      show_static
    fi
    exit 0
  else
    launch_dynamic "$stem"
    if [[ ! -f "$bin_dir/.keep-warm" ]]; then
      pkill -x awww-daemon 2>/dev/null || true
    fi
  fi
else
  start_awww
  if running_is_warm && dynamic_visible; then
    # Swap awww's image underneath first, then uncover it.
    show_static none || true
    send_control hide
  elif running_is_warm; then
    show_static
  else
    # Non-warm dynamic: stopping it unmaps layers, so not while previewing.
    [[ $mode == apply ]] && stop_dynamic
    show_static
  fi
fi

[[ $mode == apply ]] || exit 0

printf '%s\n' "$selection" >"$SAVE_FILE"

# Keep things warm for next time (cheap no-op when they already are).
flock -u 9
exec 9>&-
(exec 8>&-; exec setsid nice -n 19 ionice -c 3 "$SELF" --warm >/dev/null 2>&1) &
