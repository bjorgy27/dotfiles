#!/usr/bin/env bash
# Flight route (origin/destination airport) for a callsign, via adsbdb.com (no key).
#
# Usage: routepoll.sh CALLSIGN
# Output: ONE line of compact JSON, always exit 0:
#   {"callsign":"DAL544","origin":{"icao":"KATL","iata":"ATL","name":"...","city":"Atlanta","lat":..,"lon":..},
#                        "dest":{...}}
#   {"error":"no route"}
# Routes rarely change, so results are cached per callsign: 24 h for hits, 1 h for misses.

_die() { printf '{"error":%s}\n' "$(printf '%s' "$1" | jq -Rs .)"; exit 0; }

CS=$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9')
[[ "$CS" =~ ^[A-Z0-9]{2,8}$ ]] || _die "bad callsign"

CACHE_DIR="$HOME/.cache/quickshell_routes"
CACHE="$CACHE_DIR/$CS.json"
HIT_TTL=86400
MISS_TTL=3600

if [ -s "$CACHE" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$CACHE") ))
  if grep -q '"error"' "$CACHE"; then ttl=$MISS_TTL; else ttl=$HIT_TTL; fi
  if [ "$age" -lt "$ttl" ]; then
    cat "$CACHE"
    exit 0
  fi
fi

UA="quickshell-desktop-bar/1.0 (single personal-use desktop widget; low frequency)"
resp=$(curl -s -m 10 -A "$UA" "https://api.adsbdb.com/v0/callsign/$CS")
# Network failure or a non-JSON body (proxy/5xx HTML page): don't cache, just report.
[ -n "$resp" ] || _die "adsbdb unreachable"
printf '%s' "$resp" | jq -e 'type == "object"' >/dev/null 2>&1 || _die "adsbdb error"

out=$(printf '%s' "$resp" | jq -c --arg cs "$CS" '
  def ap: {
    icao: (.icao_code // ""), iata: (.iata_code // ""), name: (.name // ""),
    city: (.municipality // ""), lat: .latitude, lon: .longitude
  };
  .response.flightroute as $r
  | if ($r | type) == "object" and $r.origin.latitude != null and $r.destination.latitude != null
    then { callsign: ($r.callsign // $cs), origin: ($r.origin | ap), dest: ($r.destination | ap) }
    else { error: "no route" } end' 2>/dev/null)
[ -n "$out" ] || out='{"error":"no route"}'

{ mkdir -p "$CACHE_DIR" && printf '%s\n' "$out" > "$CACHE"; } 2>/dev/null   # cache is best-effort
printf '%s\n' "$out"
exit 0
