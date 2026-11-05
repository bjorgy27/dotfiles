#!/bin/bash
# Calendar for the dashboard calendar widget (CalendarWidget.qml).
# Source, first that works: Google Calendar via gog (read-only; needs `gog auth add`,
# GOG_ACCOUNT optional), then calro (Proton, upstream's source) if installed.
# Prints one JSON object, always exit 0:
#   {"state":"ok","stale":false,"events":[{"summary","start","end","all_day","calendar","location","skip","verified"}]}
#   {"state":"offline","reason":"..."}  when no source is set up or reachable
# Test mode, no account needed:  calendarpoll.sh --fixture [<file>]  (TODAY/TOMORROW become dates).
# Range mode (the month grid):  calendarpoll.sh --from YYYY-MM-DD --to YYYY-MM-DD  (both days inclusive),
# same JSON, up to 250 events from every calendar.
# No arguments: the next 7 days, up to 40 events.
from=$(date +%F); to=$(date -d '+7 days' +%F); max=40; pages=
if [ "${1:-}" = "--from" ] && [ -n "${2:-}" ] && [ "${3:-}" = "--to" ] && [ -n "${4:-}" ]; then
  from=$(date -d "$2" +%F 2>/dev/null) && to=$(date -d "$4 +1 day" +%F 2>/dev/null) \
    || { jq -cn '{state:"offline",reason:"bad date range"}'; exit 0; }
  max=250; pages=--all-pages; shift 4
fi
if [ "${1:-}" = "--fixture" ]; then
  f=${2:-$(dirname "$0")/fixtures/calendar.json}
  sed "s/TODAY/$(date +%F)/g; s/TOMORROW/$(date -d tomorrow +%F)/g" "$f" 2>/dev/null || echo '{"state":"offline","reason":"fixture missing"}'
  exit 0
fi
offline() { jq -cn --arg r "$1" '{state:"offline",reason:$r}'; exit 0; }
# gog's file keyring (no desktop keyring on this box) needs its password to read the token; it lives in a
# mode-600 file next to gog's config, never in this repo (set up 2026-10-26).
# Quickshell's PATH has no ~/.local/bin, where gog lives.
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH"; export PATH ;; esac
if [ -z "${GOG_KEYRING_PASSWORD:-}" ] && [ -r "$HOME/.config/gogcli/keyring.pass" ]; then
  GOG_KEYRING_PASSWORD=$(cat "$HOME/.config/gogcli/keyring.pass"); export GOG_KEYRING_PASSWORD
fi

if command -v gog >/dev/null && ! timeout 10 gog auth list 2>&1 | grep -q 'No tokens'; then
  json=$(timeout 20 gog --readonly --no-input calendar events --all --json --results-only --max "$max" $pages --from "$from" --to "$to" 2>/dev/null)
  if [ -n "$json" ] && ! echo "$json" | jq -e 'type == "object" and has("error")' >/dev/null 2>&1; then
    echo "$json" | jq -c '(if type == "array" then . else (.events // .items // []) end) as $ev |
      {state:"ok", stale:false, events:[$ev[] | {
        summary:(if (.summary // "") == "" then "(no title)" else .summary end),
        start:(.start.dateTime // .start.date // .start), end:(.end.dateTime // .end.date // .end),
        all_day:((.start.date // null) != null), calendar:(.calendarSummary // .organizer.displayName // .calendar // "Google"),
        location:(.location // ""), skip:((.status // "") == "cancelled" or any((.attendees // [])[]; .self == true and .responseStatus == "declined")),
        verified:true}] | sort_by(.start) | .[:$max]}' --argjson max "$max" 2>/dev/null && exit 0
  fi
fi

if command -v calro >/dev/null && [ -S /run/calro/calro.sock ]; then
  tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
  json=$(timeout 15 calro events --from "$from" --to "$to"${tz:+ --tz $tz} 2>/dev/null)
  [ -n "$json" ] || offline "calro not reachable"
  echo "$json" | jq -c 'if .error then {state:"offline",reason:.error} else
    {state:"ok", stale:(.stale // false), events:[.events[] | {summary:(if (.summary // "") == "" then "(no title)" else .summary end), start, end, all_day,
     calendar, location:(.location // ""), skip:(.cancelled or .declined), verified}] | .[:$max]} end' --argjson max "$max" 2>/dev/null \
    || offline "bad reply from calro"
  exit 0
fi
offline "no calendar linked (gog auth add <email> for Google Calendar)"
