#!/usr/bin/env bash
# Aircraft near a point, from the adsb.lol community ADS-B feed (no API key).
#
# Usage: aircraftpoll.sh LAT LON NM      (NM = search radius in nautical miles, max 250)
# Output: ONE line of compact JSON, always exit 0:
#   {"now":<ms>,"ac":[{"hex":"a7a8ed","flight":"DAL544","reg":"N593DX","type":"A21N",
#                      "lat":..,"lon":..,"alt":32025,"ground":false,"gs":451,"track":263.4,
#                      "vr":0,"cat":"A3","seen":0.2}, ...]}
#   {"error":"<message>"}

_die() { printf '{"error":%s}\n' "$(printf '%s' "$1" | jq -Rs .)"; exit 0; }

LAT="${1:-}" LON="${2:-}" NM="${3:-100}"
[[ "$LAT" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || _die "bad latitude"
[[ "$LON" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || _die "bad longitude"
[[ "$NM"  =~ ^[0-9]+(\.[0-9]+)?$ ]]   || _die "bad radius"
NM=${NM%%.*}
(( NM < 1 ))   && NM=1
(( NM > 250 )) && NM=250

UA="quickshell-desktop-bar/1.0 (single personal-use desktop widget; low frequency)"
URL="https://api.adsb.lol/v2/lat/${LAT}/lon/${LON}/dist/${NM}"

resp=$(curl -sf -m 10 -A "$UA" "$URL") || _die "adsb.lol unreachable"
[ -n "$resp" ] || _die "empty response"

out=$(printf '%s' "$resp" | jq -c '
  {
    now: (.now // (now * 1000 | floor)),
    ac: [
      (.ac // [])[]
      | select(.lat != null and .lon != null)
      | {
          hex:    (.hex // ""),
          flight: ((.flight // "") | gsub("^\\s+|\\s+$"; "")),
          reg:    (.r // ""),
          type:   (.t // ""),
          lat:    .lat,
          lon:    .lon,
          alt:    (if (.alt_baro | type) == "number" then .alt_baro
                   elif (.alt_geom | type) == "number" then .alt_geom
                   else 0 end),
          ground: (.alt_baro == "ground"),
          gs:     (.gs // 0),
          track:  (.track // -1),
          vr:     (.baro_rate // .geom_rate // 0),
          cat:    (.category // ""),
          seen:   (.seen_pos // .seen // 0)
        }
    ]
  }' 2>/dev/null) || _die "parse failed"

[ -n "$out" ] || _die "parse failed"
printf '%s\n' "$out"
