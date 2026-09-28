#!/usr/bin/env bash
# RainViewer global radar frame index for the map widget's weather layer.
# Output, one line per frame (past frames first, then nowcast, chronological):
#   <unix_time>|<past|nowcast>|<host><path>
#   error|<message>   (single line, only on failure)
# Always exits 0 so the widget shows the error text instead of an empty tile.

_die() { echo "error|$1"; exit 0; }

UA="quickshell-desktop-bar/1.0 (single personal-use desktop widget; low frequency)"

maps=$(curl -sf -m 10 -A "$UA" "https://api.rainviewer.com/public/weather-maps.json") \
  || _die "rainviewer unreachable"

out=$(echo "$maps" | jq -r '
  (.host // empty) as $host
  | if ($host | length) == 0 then error("bad response") else . end
  | ((.radar.past // []) | sort_by(.time) | map(. + {kind: "past"}))
    + ((.radar.nowcast // []) | sort_by(.time) | map(. + {kind: "nowcast"}))
  | .[]
  | [(.time|tostring), .kind, ($host + .path)]
  | join("|")
' 2>/dev/null) || _die "parse failed"

[ -n "$out" ] || _die "no frames"
echo "$out"
