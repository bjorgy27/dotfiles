#!/usr/bin/env bash
# Lightweight bluetooth status for the bar icon (cheap: no per-device info calls).
# Output: power|connectedCount|primaryName
#   power : on|off|unavailable

if ! command -v bluetoothctl >/dev/null 2>&1; then
  echo "unavailable|0|"
  exit 0
fi

show=$(timeout 1 bluetoothctl show 2>/dev/null)
if [ -z "$show" ]; then
  echo "unavailable|0|"
  exit 0
fi

powered=$(echo "$show" | awk '/^\s*Powered:/{print $2; exit}')
if [ "$powered" != "yes" ]; then
  echo "off|0|"
  exit 0
fi

connected=$(timeout 2 bluetoothctl devices Connected 2>/dev/null)
count=$(printf '%s\n' "$connected" | grep -c '^Device')
name=$(printf '%s\n' "$connected" | head -1 | cut -d' ' -f3-)
echo "on|$count|$name"
