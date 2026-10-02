#!/usr/bin/env bash
# Lock the screen: an ext-session-lock client (qs/shell.qml, Quickshell's
# WlSessionLock) in its own Quickshell instance, not the bar's. lockgen.py
# resolves meta/*.toml for the current wallpaper into JSON for it; PAM (the
# hyprlock service) checks the password. If it dies at startup this falls back
# to hyprlock (hypr/hyprlock.conf), so it always locks.
# Ported from gagehauptman/dotfiles e6f2eee, bc567de, 73b8c23.
#
#   lock.sh                 lock (Super+L, power menu, hypridle, lockdown)
#   lock.sh --locked        exit 0 if a lock (this one or hyprlock) is up
#   lock.sh --test [SECS]   SAFE: same screens as overlay windows, NOT a lock,
#                           gone after SECS (default 15). PAM uses a fixture
#                           that accepts only the password "letmein".
#   lock.sh --try [SECS]    real lock that unlocks itself after SECS (default 10)
#   lock.sh --preview [DIR] SAFEST: render every monitor's lock screen offscreen
#                           to DIR/<monitor>.png (default $XDG_RUNTIME_DIR/
#                           lockscreen/preview); nothing shows on screen.
#                           LOCK_WALLPAPER=path previews another wallpaper.
#   lock.sh --unlock        unlock a running lock (from a TTY: Ctrl+Alt+F3)
#   lock.sh --recover       the lock client died and left Hyprland's "lockscreen
#                           died" screen: start a 3s lock to clear it
dir=$(dirname "$(realpath "$0")")
run=${XDG_RUNTIME_DIR:-/run/user/$UID}
state=$run/lockscreen
mkdir -p "$state"

export XDG_RUNTIME_DIR=$run
[[ -z $WAYLAND_DISPLAY ]] && WAYLAND_DISPLAY=$(cd "$run" && ls -d wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1) && export WAYLAND_DISPLAY
if [[ -z $HYPRLAND_INSTANCE_SIGNATURE ]]; then
  HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "$run/hypr" 2>/dev/null | head -1)
  export HYPRLAND_INSTANCE_SIGNATURE
fi

qs() { quickshell -p "$dir/qs" "$@"; }

# A lock is up: a Quickshell lock instance (not --test, which is only overlay
# windows), or a hyprlock with a live parent. Orphaned hyprlocks (PPID 1) hold
# nothing and must not block a new lock (seen 2026-09-28).
locked() {
  local pid args re="-p $dir/qs( |$)"
  for pid in $(pgrep -u "$UID" -x quickshell); do
    args=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || continue
    [[ $args =~ $re ]] || continue
    tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qx 'LOCK_MODE=test' && continue
    return 0
  done
  for pid in $(pgrep -u "$UID" -x hyprlock); do
    [[ $(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') != 1 ]] && return 0
  done
  return 1
}

# Let a new locker take over a lock whose client died (Hyprland refuses that by
# default) for $1 seconds, then put the option back.
restore_window() {
  hyprctl getoption misc:allow_session_lock_restore 2>/dev/null | grep -q 'bool: true' && return
  hyprctl eval 'hl.config({misc={allow_session_lock_restore=true}})' >/dev/null
  ( sleep "$1"; hyprctl eval 'hl.config({misc={allow_session_lock_restore=false}})' >/dev/null ) &
}

case $1 in
  --locked)  locked; exit ;;
  --unlock)  exec quickshell -p "$dir/qs" ipc call lock unlock ;;
  --preview)
    out=${2:-$state/preview}
    mkdir -p "$out"
    wall=(); [[ -n $LOCK_WALLPAPER ]] && wall=(--wallpaper "$LOCK_WALLPAPER")
    python3 "$dir/lockgen.py" "${wall[@]}" --out "$out/lock.json" --check || exit 1
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
      LOCK_CONFIG=$out/lock.json LOCK_PREVIEW_OUT=$out \
      timeout 60 quickshell -p "$dir/qs/preview.qml" >"$out/preview.log" 2>&1
    ls "$out"/*.png
    exit ;;
  --recover)
    restore_window 5
    "$0" --try 3
    exit ;;
esac

mode=lock secs=0
case $1 in
  --test) mode=test secs=${2:-15} ;;
  --try)  secs=${2:-10} ;;
  "") ;;
  *) echo "usage: lock.sh [--locked | --test [SECS] | --try [SECS] | --preview [DIR] | --unlock | --recover]" >&2; exit 2 ;;
esac

# One lock at a time (a second Super+L, or hypridle on top of a lock, must not
# start another client). A --test run blocks it too, for its few seconds.
pgrep -u "$UID" -ax quickshell | grep -qE -- "-p $dir/qs( |$)" && exit 0
locked && exit 0

conf=$state/lock.json
wall=(); [[ $mode == test && -n $LOCK_WALLPAPER ]] && wall=(--wallpaper "$LOCK_WALLPAPER")   # test only: preview another wallpaper's look
python3 "$dir/lockgen.py" "${wall[@]}" --out "$conf" 2>"$state/lockgen.log" || echo '{"screens":[]}' >"$conf"

LOCK_CAPS_LEDS=$(shopt -s nullglob; leds=(/sys/class/leds/*capslock/brightness); IFS='|'; echo "${leds[*]}"); export LOCK_CAPS_LEDS
export LOCK_MODE=$mode LOCK_SECONDS=$secs LOCK_CONFIG=$conf LOCK_DIR=$dir
if [[ $mode == test ]]; then
  # PAM wants an absolute path in the service file and the repo sits somewhere
  # else on each machine, so the fixture is written here, pointing at this copy.
  mkdir -p "$state/pam"
  printf '%s\n' \
    '# lock.sh --test only: accepts one made-up password, never the real account.' \
    "auth    required    pam_exec.so expose_authtok quiet $dir/pam/test-check.sh" \
    'account required    pam_permit.so' >"$state/pam/test"
  export LOCK_PAM_DIR=$state/pam LOCK_PAM_CONFIG=test
  [[ -n $LOCK_TEST_PASSWORD ]] && export LOCK_TEST_PASSWORD
fi

# Watchdog for --try: if the timer inside the lock somehow doesn't fire, ask again over IPC.
if [[ $mode == lock && $secs -gt 0 ]]; then
  ( sleep $((secs + 6)); quickshell -p "$dir/qs" ipc call lock unlock >/dev/null 2>&1 ) &
fi

start=$SECONDS
qs 2>>"$state/lock.log"; rc=$?
[[ $mode == test || $secs -gt 0 ]] && exit $rc
(( rc == 0 || rc == 3 )) && exit 0
# It died. Fall back only if it never got going; a later death is a kill from a
# TTY, don't lock again. If it had already locked, Hyprland holds the screen on
# "lockscreen died" and only lets hyprlock in while restore is allowed.
(( SECONDS - start >= 3 )) && exit "$rc"
echo "$(date -Is) lock client exited $rc after $((SECONDS - start))s; falling back to hyprlock" >>"$state/lock.log"
restore_window 5
exec hyprlock
