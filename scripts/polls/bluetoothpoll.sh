#!/usr/bin/env bash
# Bluetooth status. Output format:
#   power|<on|off|unavailable>
#   device|<MAC>|<Name>|<connected:0|1>|<paired:0|1>|<battery_or_NA>|<icon>

if ! command -v bluetoothctl >/dev/null 2>&1; then
  echo "power|unavailable"
  exit 0
fi

show=$(timeout 1 bluetoothctl show 2>/dev/null)
if [ -z "$show" ]; then
  echo "power|unavailable"
  exit 0
fi

powered=$(echo "$show" | awk '/^\s*Powered:/{print $2; exit}')
[ "$powered" = "yes" ] && echo "power|on" || echo "power|off"

[ "$powered" = "yes" ] || exit 0

timeout 2 bluetoothctl devices 2>/dev/null | while read -r _ mac rest; do
  [ -z "$mac" ] && continue
  name="$rest"

  info=$(timeout 1 bluetoothctl info "$mac" 2>/dev/null)
  [ -z "$info" ] && continue

  connected=$(echo "$info" | awk -F': ' '/^\s*Connected:/{print ($2 == "yes" ? 1 : 0); exit}')
  [ -z "$connected" ] && connected=0

  paired=$(echo "$info" | awk -F': ' '/^\s*Paired:/{print ($2 == "yes" ? 1 : 0); exit}')
  [ -z "$paired" ] && paired=0

  icon=$(echo "$info" | awk -F': ' '/^\s*Icon:/{print $2; exit}')

  battery="NA"
  if [ "$connected" = "1" ]; then
    bat=$(echo "$info" | awk -F'[()]' '/Battery Percentage:/{print $2; exit}')
    [ -n "$bat" ] && battery="$bat"
  fi

  echo "device|$mac|$name|$connected|$paired|$battery|$icon"
done
