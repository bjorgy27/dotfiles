# Shared Tessie helpers — sourced by tessiepoll.sh and tessiecmd.sh.
# The sourcing script must define _die before sourcing this file; _die formats
# error output appropriately for its caller (poll emits "error|msg" + exit 0,
# cmd emits plain text + exit 1) and is invoked by the helpers below on any
# failure path.

TESSIE_BASE="https://api.tessie.com"
_KEY_FILE="$HOME/.config/tessie.key"
_VIN_CACHE="/tmp/tessie_vin_$UID"
_VIN_CACHE_TTL=300

tessie_load_token() {
  [ -s "$_KEY_FILE" ] || _die "no api key"
  TESSIE_TOKEN=$(tr -d '[:space:]' < "$_KEY_FILE")
  [ -n "$TESSIE_TOKEN" ] || _die "empty api key"
}

tessie_load_vin() {
  if [ -f "$_VIN_CACHE" ]; then
    local age
    age=$(( $(date +%s) - $(stat -c %Y "$_VIN_CACHE") ))
    if [ "$age" -lt "$_VIN_CACHE_TTL" ]; then
      TESSIE_VIN=$(cat "$_VIN_CACHE")
      [ -n "$TESSIE_VIN" ] && return 0
    fi
  fi

  local vehicles
  vehicles=$(curl -sf -m 5 -H "Authorization: Bearer $TESSIE_TOKEN" "$TESSIE_BASE/vehicles") \
    || _die "api unreachable"
  TESSIE_VIN=$(echo "$vehicles" | jq -r '.results[0].vin // empty')
  [ -n "$TESSIE_VIN" ] || _die "no vehicles"
  echo "$TESSIE_VIN" > "$_VIN_CACHE"
}
