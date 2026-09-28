#!/usr/bin/env bash
# Persists (6 args) or reads (no args) the map view + settings for the Radar
# dashboard widget.
#
# Usage:
#   radarstate.sh                                  -> prints "lat|lon|zoom|product|planes|animate"
#   radarstate.sh LAT LON ZOOM PRODUCT PLANES ANIMATE -> saves, no output
#
# Fields: lat/lon/zoom are decimal numbers; product is one of
# rainviewer|nws_bref|none; planes/animate are 0|1.
# A malformed or missing state file falls back to the defaults below.

STATE="$HOME/.cache/quickshell_radar_state"
# Default centre comes from quickshell's gitignored local.js (home location).
LOCAL_JS="$HOME/.config/quickshell/local.js"
HOME_LAT=$(sed -n 's/^var homeLat *= *\(-\?[0-9.]*\).*/\1/p' "$LOCAL_JS" 2>/dev/null)
HOME_LON=$(sed -n 's/^var homeLon *= *\(-\?[0-9.]*\).*/\1/p' "$LOCAL_JS" 2>/dev/null)
DEFAULT="${HOME_LAT:-0}|${HOME_LON:-0}|6|rainviewer|1|0"

is_num() { [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }
is_product() { [[ "$1" =~ ^(rainviewer|nws_bref|none)$ ]]; }
is_bool() { [[ "$1" =~ ^[01]$ ]]; }

valid() {
  is_num "$1" && is_num "$2" && is_num "$3" && is_product "$4" && is_bool "$5" && is_bool "$6"
}

if [ "$#" -ge 6 ]; then
  if valid "$1" "$2" "$3" "$4" "$5" "$6"; then
    mkdir -p "$(dirname "$STATE")"
    printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  fi
  exit 0
fi

if [ -s "$STATE" ]; then
  IFS='|' read -r lat lon zoom product planes animate < "$STATE"
  if valid "$lat" "$lon" "$zoom" "$product" "$planes" "$animate"; then
    printf '%s|%s|%s|%s|%s|%s\n' "$lat" "$lon" "$zoom" "$product" "$planes" "$animate"
    exit 0
  fi
fi

echo "$DEFAULT"
