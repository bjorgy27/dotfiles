#!/bin/bash

# Current network status for the bar icon.
# Output: radioState|type|name|signal|device
#   radioState : enabled|disabled
#   type       : wifi|ethernet|none
#   name       : SSID (wifi) or interface (ethernet)
#   signal     : 0-100 (wifi only, else empty)
#   device     : wifi device name (for disconnect actions), else empty

radio=$(nmcli radio wifi 2>/dev/null)
[ -z "$radio" ] && radio="disabled"

wifi_device=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')

active_wifi=$(nmcli -t -f IN-USE,SSID,SIGNAL device wifi list 2>/dev/null | awk -F: '$1=="*"{print $2"|"$3; exit}')

if [ -n "$active_wifi" ]; then
  ssid="${active_wifi%%|*}"
  signal="${active_wifi##*|}"
  echo "$radio|wifi|$ssid|$signal|$wifi_device"
  exit 0
fi

eth_device=$(nmcli -t -f TYPE,STATE,DEVICE device status 2>/dev/null | awk -F: '$1=="ethernet" && $2=="connected"{print $3; exit}')

if [ -n "$eth_device" ]; then
  echo "$radio|ethernet|$eth_device||"
  exit 0
fi

echo "$radio|none|||$wifi_device"
