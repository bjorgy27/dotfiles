#!/usr/bin/env bash
# hyprlock WarGames/WOPR label text:
#   wopr.sh greeting|clock|zulu|defcon|readout|winner
# Prints pango markup, or nothing. All local and bounded: weather only reads
# quickshell's cache (a stale one gets a throttled, detached refresh), and
# playerctl runs under a timeout. Label updates can be every 0.5-2 s, so
# nothing here may be slow.

GREEN='#33ff66'
DIM='#1f9f45'
AMBER='#ffb000'
RED='#ff4040'

# This desktop's /etc/localtime is an empty file (so everything reads UTC),
# so "local" falls back to Beck's zone; a machine with a zone set uses its own.
[[ -s /etc/localtime || -n ${TZ:-} ]] || export TZ=America/New_York

# Replacements are quoted: bash 5.2 expands an unquoted & to the match.
esc() {
  local s=${1//&/'&amp;'}
  s=${s//</'&lt;'}
  printf '%s' "${s//>/'&gt;'}"
}

trim() {
  local s=$1 n=$2
  (( ${#s} > n )) && s="${s:0:n-1}~"
  printf '%s' "$s"
}

span() { printf "<span foreground='%s'>%s</span>" "$1" "$2"; }

# Blinking cursor: on for the first half of each second.
cursor() {
  local ms
  ms=$(date +%-N)
  if (( ms < 500000000 )); then printf '_'; else printf ' '; fi
}

# 5 (calm) .. 1 from the 1-minute load per core. Decorative, and says so.
defcon_level() {
  local load cores pct
  read -r load _ </proc/loadavg
  cores=$(nproc 2>/dev/null || echo 1)
  pct=$(awk -v l="$load" -v c="$cores" 'BEGIN { printf "%d", 100 * l / c }')
  if (( pct < 25 )); then echo 5
  elif (( pct < 50 )); then echo 4
  elif (( pct < 75 )); then echo 3
  elif (( pct < 100 )); then echo 2
  else echo 1
  fi
}

case ${1:-} in
greeting)
  h=$(date +%-H)
  if (( h < 5 )); then g="WORKING LATE, PROFESSOR FALKEN?"
  elif (( h < 12 )); then g="GOOD MORNING, PROFESSOR FALKEN."
  elif (( h < 18 )); then g="GOOD AFTERNOON, PROFESSOR FALKEN."
  else g="GOOD EVENING, PROFESSOR FALKEN."
  fi
  printf '%s\n\nSHALL WE PLAY A GAME?%s\n' "$g" "$(cursor)"
  ;;

clock)
  date '+%H:%M:%S %Z'
  ;;

zulu)
  printf '%s  //  %s\n' "$(date -u '+ZULU %H%MZ')" "$(date '+%a %d %b %Y' | tr '[:lower:]' '[:upper:]')"
  ;;

defcon)
  lvl=$(defcon_level)
  case $lvl in 5|4) c=$GREEN ;; 3|2) c=$AMBER ;; *) c=$RED ;; esac
  printf '%s  %s\n' "$(span "$c" "DEFCON $lvl")" "$(span "$DIM" "(DECORATIVE: CPU LOAD)")"
  ;;

readout)
  # Fixed-width terminal block; missing sources drop their line.
  lines=()

  read -r up _ </proc/uptime
  up=${up%.*}
  d=$(( up / 86400 )) h=$(( up % 86400 / 3600 )) m=$(( up % 3600 / 60 ))
  if (( d > 0 )); then u="${d}D ${h}H"; elif (( h > 0 )); then u="${h}H ${m}M"; else u="${m}M"; fi
  read -r load _ </proc/loadavg
  host=$(cat /etc/hostname 2>/dev/null || uname -n)
  lines+=("SYS    ${host^^}  UP $u  LOAD $load")

  cache=/tmp/weather_cache
  poll="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/polls/weatherpoll.sh"
  kick="${XDG_RUNTIME_DIR:-/tmp}/hyprlock-weather-kick"
  now=$(date +%s)
  age=$(( now - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
  kage=$(( now - $(stat -c %Y "$kick" 2>/dev/null || echo 0) ))
  # Stale: refresh in the background at most every 5 min (curls time out at 5 s).
  if (( age > 900 && kage > 300 )) && [[ -x $poll ]]; then
    : >"$kick"
    setsid -f "$poll" >/dev/null 2>&1 </dev/null
  fi
  if (( age < 10800 )) && IFS='|' read -r city code temp _ _ <"$cache" 2>/dev/null \
      && [[ $temp =~ ^-?[0-9.]+$ ]]; then
    case $code in
      0) sky="CLEAR" ;; 1) sky="MOSTLY CLEAR" ;; 2) sky="PARTLY CLOUDY" ;;
      3) sky="OVERCAST" ;; 45|48) sky="FOG" ;; 51|53|55|56|57) sky="DRIZZLE" ;;
      61|63|65|66|67) sky="RAIN" ;; 71|73|75|77) sky="SNOW" ;;
      80|81|82) sky="SHOWERS" ;; 85|86) sky="SNOW SHOWERS" ;;
      95|96|99) sky="THUNDERSTORMS" ;; *) sky="" ;;
    esac
    c=$(printf '%.0f' "$temp")
    f=$(( (c * 9 + 160) / 5 ))
    w="${c}C/${f}F"
    [[ -n $sky ]] && w="$w  $sky"
    [[ -n $city && $city != Unknown ]] && w="$w  ${city^^}"
    lines+=("WX     $w")
  fi

  # Anything playing (spotifyd/Cider first), else a paused music player.
  list=$(timeout 0.5 playerctl -a metadata \
    --format $'{{playerName}}\t{{status}}\t{{artist}}\t{{title}}' 2>/dev/null)
  pick=""
  if [[ -n $list ]]; then
    for want in 'spotifyd|cider|Cider:Playing' '.*:Playing' 'spotifyd|cider|Cider:Paused'; do
      re=${want%:*} st=${want##*:}
      while IFS=$'\t' read -r name status artist title; do
        [[ $status == "$st" && $name =~ ^($re) && -n $title ]] || continue
        pick="$status"$'\t'"$artist"$'\t'"$title"
        break 2
      done <<<"$list"
    done
  fi
  if [[ -n $pick ]]; then
    IFS=$'\t' read -r status artist title <<<"$pick"
    a="$(trim "$title" 44)"
    [[ -n $artist ]] && a="$a - $(trim "$artist" 28)"
    [[ $status == Paused ]] && a="[HOLD] $a"
    lines+=("AUDIO  ${a^^}")
  fi

  # Battery only where one exists (the laptop).
  for s in /sys/class/power_supply/*; do
    [[ $(cat "$s/type" 2>/dev/null) == Battery ]] || continue
    cap=$(cat "$s/capacity" 2>/dev/null) || continue
    status=$(cat "$s/status" 2>/dev/null)
    b="BATTERY ${cap}%"
    [[ $status == Charging ]] && b="$b  CHARGING"
    [[ $status == Full ]] && b="$b  FULL"
    if (( cap <= 15 )) && [[ $status != Charging ]]; then
      lines+=("PWR    <<LOW>> $b")
    else
      lines+=("PWR    $b")
    fi
    break
  done

  for l in "${lines[@]}"; do
    l=$(esc "$l")
    # Colour the low-battery flag after escaping, so it stays markup.
    l=${l//'&lt;&lt;LOW&gt;&gt;'/"<span foreground='$RED'>LOW</span>"}
    printf '%s%s\n' "$(span "$DIM" "${l:0:7}")" "${l:7}"
  done
  ;;

winner)
  printf 'WINNER: NONE\nA STRANGE GAME. THE ONLY WINNING MOVE IS NOT TO PLAY.\n'
  ;;
esac
