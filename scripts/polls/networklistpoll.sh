#!/bin/bash

# Available Wi-Fi networks, deduped by SSID (in-use / strongest signal wins).
# Output: one line per network as inUse|ssid|signal|secured|saved
# Note: assumes SSIDs don't contain ':' (nmcli's -t field separator).

mapfile -t saved_lines < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1}')

declare -A is_saved
for name in "${saved_lines[@]}"; do
  is_saved["$name"]=1
done

declare -A best_signal
declare -A best_line

while IFS=: read -r inuse ssid signal security; do
  [ -z "$ssid" ] && continue

  secured=0
  [ -n "$security" ] && [ "$security" != "--" ] && secured=1

  active=0
  [ "$inuse" = "*" ] && active=1

  saved_flag=${is_saved[$ssid]:-0}

  current_best=${best_signal[$ssid]:--1}
  if [ "$active" = "1" ] || [ "$signal" -gt "$current_best" ]; then
    best_signal["$ssid"]=$signal
    best_line["$ssid"]="$active|$ssid|$signal|$secured|$saved_flag"
  fi
done < <(nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY device wifi list 2>/dev/null)

for ssid in "${!best_line[@]}"; do
  echo "${best_line[$ssid]}"
done | sort -t'|' -k1,1nr -k3,3nr
