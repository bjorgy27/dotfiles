#!/usr/bin/env bash
# hyprlock label text: info.sh time|date|stats|greeting|weather|music|system|battery
# Prints pango markup, or nothing to hide the line. Everything is local and
# bounded: no network here (weather only reads quickshell's cache and kicks a
# detached refresh), and playerctl is under a timeout.

# Replacements are quoted: bash 5.2 expands an unquoted & to the match.
esc() {
  local s=${1//&/'&amp;'}
  s=${s//</'&lt;'}
  printf '%s' "${s//>/'&gt;'}"
}

# Cut to $2 characters with an ellipsis.
trim() {
  local s=$1 n=$2
  (( ${#s} > n )) && s="${s:0:n-1}…"
  printf '%s' "$s"
}

# This desktop's /etc/localtime is empty (so UTC); Beck lives on Eastern time.
[[ -z ${TZ:-} && ! -s /etc/localtime ]] && export TZ=America/New_York

case ${1:-} in
time)
  date '+%-I:%M %p'
  ;;

stats)
  # CPU busy % over a 0.2 s sample, RAM used/total, uptime.
  read -r _ a1 b1 c1 d1 e1 f1 g1 _ </proc/stat
  sleep 0.2
  read -r _ a2 b2 c2 d2 e2 f2 g2 _ </proc/stat
  busy=$(( (a2+b2+c2+f2+g2) - (a1+b1+c1+f1+g1) ))
  total=$(( busy + (d2+e2) - (d1+e1) ))
  cpu=$(( total > 0 ? 100 * busy / total : 0 ))
  while read -r k v _; do
    case $k in MemTotal:) mt=$v ;; MemAvailable:) ma=$v ;; esac
  done </proc/meminfo
  used=$(( (mt - ma) * 10 / 1048576 )) tot=$(( mt * 10 / 1048576 ))
  read -r up _ </proc/uptime
  up=${up%.*}
  d=$(( up / 86400 )) h=$(( up % 86400 / 3600 )) m=$(( up % 3600 / 60 ))
  if (( d > 0 )); then u="${d}d ${h}h"; elif (( h > 0 )); then u="${h}h ${m}m"; else u="${m}m"; fi
  printf 'cpu %s%%\nram %s.%s / %s.%s GiB\nup %s\n' "$cpu" \
    $(( used / 10 )) $(( used % 10 )) $(( tot / 10 )) $(( tot % 10 )) "$u"
  ;;

greeting)
  h=$(date +%-H)
  if (( h < 5 )); then g="up late"
  elif (( h < 12 )); then g="good morning"
  elif (( h < 18 )); then g="good afternoon"
  else g="good evening"
  fi
  printf '%s, %s\n' "$g" "$(esc "$USER")"
  ;;

date)
  date '+%A, %B %-d'
  ;;

weather)
  # Written by quickshell's weather poll: city|wmo_code|temp_c|humidity|wind.
  cache=/tmp/weather_cache
  poll="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/polls/weatherpoll.sh"
  now=$(date +%s)
  mtime=$(stat -c %Y "$cache" 2>/dev/null || echo 0)
  age=$(( now - mtime ))
  # Stale: refresh in the background for the next update (its curls time out
  # at 5 s each), and show what we have meanwhile.
  if (( age > 900 )) && [[ -x $poll ]]; then
    setsid -f "$poll" >/dev/null 2>&1 </dev/null
  fi
  (( age < 10800 )) || exit 0
  IFS='|' read -r city code temp _ _ <"$cache" || exit 0
  [[ $temp =~ ^-?[0-9.]+$ ]] || exit 0
  case $code in
    0) sky="clear" ;;
    1) sky="mostly clear" ;;
    2) sky="partly cloudy" ;;
    3) sky="overcast" ;;
    45|48) sky="fog" ;;
    51|53|55|56|57) sky="drizzle" ;;
    61|63|65|66|67) sky="rain" ;;
    71|73|75|77) sky="snow" ;;
    80|81|82) sky="showers" ;;
    85|86) sky="snow showers" ;;
    95|96|99) sky="thunderstorms" ;;
    *) sky="" ;;
  esac
  c=$(printf '%.0f' "$temp")
  f=$(( (c * 9 + 160) / 5 ))
  line="${c}°C / ${f}°F"
  [[ -n $sky ]] && line="$line  ·  $sky"
  [[ -n $city && $city != Unknown ]] && line="$line  ·  $city"
  esc "$line"; echo
  ;;

music)
  # Prefer anything playing (spotifyd/Cider first), else a paused music player.
  # Tab-separated: titles can contain '|'.
  list=$(timeout 0.5 playerctl -a metadata \
    --format $'{{playerName}}\t{{status}}\t{{artist}}\t{{title}}' 2>/dev/null)
  [[ -n $list ]] || exit 0
  pick=""
  for want in 'spotifyd|cider|Cider:Playing' '.*:Playing' 'spotifyd|cider|Cider:Paused'; do
    re=${want%:*} st=${want##*:}
    while IFS=$'\t' read -r name status artist title; do
      [[ $status == "$st" && $name =~ ^($re) && -n $title ]] || continue
      pick="$status"$'\t'"$artist"$'\t'"$title"
      break 2
    done <<<"$list"
  done
  [[ -n $pick ]] || exit 0
  IFS=$'\t' read -r status artist title <<<"$pick"
  text=$(trim "$title" 60)
  [[ -n $artist ]] && text="$text  —  $(trim "$artist" 40)"
  icon="♪"
  [[ $status == Paused ]] && icon="paused"
  printf '%s  %s\n' "$icon" "$(esc "$text")"
  ;;

system)
  read -r up _ </proc/uptime
  up=${up%.*}
  d=$(( up / 86400 )) h=$(( up % 86400 / 3600 )) m=$(( up % 3600 / 60 ))
  if (( d > 0 )); then u="${d}d ${h}h"; elif (( h > 0 )); then u="${h}h ${m}m"; else u="${m}m"; fi
  read -r load _ </proc/loadavg
  host=$(cat /etc/hostname 2>/dev/null || uname -n)
  printf '%s  ·  up %s  ·  load %s\n' "$(esc "$host")" "$u" "$load"
  ;;

battery)
  # Nothing at all on machines without a battery (the desktop).
  for s in /sys/class/power_supply/*; do
    [[ $(cat "$s/type" 2>/dev/null) == Battery ]] || continue
    cap=$(cat "$s/capacity" 2>/dev/null) || continue
    status=$(cat "$s/status" 2>/dev/null)
    case $status in
      Charging) note="  ·  charging" ;;
      Full) note="  ·  full" ;;
      *) note="" ;;
    esac
    if (( cap <= 15 )) && [[ $status != Charging ]]; then
      printf "<span foreground='#f38ba8'>battery %s%%%s</span>\n" "$cap" "$note"
    else
      printf 'battery %s%%%s\n' "$cap" "$note"
    fi
    exit 0
  done
  ;;
esac
