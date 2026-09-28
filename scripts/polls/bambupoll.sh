#!/usr/bin/env bash
# Bambu Lab print status poll (LAN mode, no cloud).
# Output (pipe-delimited, one line):
#   ok|<state>|<percent>|<remaining_min>|<layer>|<total_layers>|<nozzle_c>|<nozzle_target_c>|<bed_c>|<bed_target_c>|<job_name>
#   error|<message>
#
# Needs ~/.config/bambu.conf (see SECRETS.md in the dotfiles repo):
#   BAMBU_HOST=<printer's address on the LAN>
#   BAMBU_SERIAL=<printer serial>
#   BAMBU_CODE=<LAN access code from the printer screen>

CONF="$HOME/.config/bambu.conf"
CACHE="/tmp/bambu_status_$UID"
CACHE_MAX_AGE=5

_die() { echo "error|$1"; exit 0; }

# Serve a fresh cache so several screens don't each open a TLS session.
if [[ -f "$CACHE" ]] && (( $(date +%s) - $(stat -c %Y "$CACHE") < CACHE_MAX_AGE )); then
  cat "$CACHE"
  exit 0
fi

[[ -f "$CONF" ]] || _die "no bambu.conf"
# shellcheck source=/dev/null
source "$CONF"
[[ -n "$BAMBU_HOST" && -n "$BAMBU_SERIAL" && -n "$BAMBU_CODE" ]] || _die "bambu.conf incomplete"

report=$(python3 "$(dirname "$0")/bambu_mqtt.py" "$BAMBU_HOST" "$BAMBU_SERIAL" "$BAMBU_CODE" 2>/tmp/bambu_err_$UID)
if [[ -z "$report" ]]; then
  _die "$(tr -d '\n' </tmp/bambu_err_$UID | cut -c1-60)"
fi

line=$(echo "$report" | jq -r '
  [
    "ok",
    (.gcode_state // "UNKNOWN"),
    (.mc_percent // 0),
    (.mc_remaining_time // 0),
    (.layer_num // 0),
    (.total_layer_num // 0),
    ((.nozzle_temper // 0) | floor),
    ((.nozzle_target_temper // 0) | floor),
    ((.bed_temper // 0) | floor),
    ((.bed_target_temper // 0) | floor),
    ((.subtask_name // .gcode_file // "") | sub("\\.(3mf|gcode)$"; ""))
  ] | join("|")
') || _die "unparseable report"

echo "$line" | tee "$CACHE"
