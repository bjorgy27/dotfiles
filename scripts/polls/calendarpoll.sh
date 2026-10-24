#!/bin/bash
# Calendar for the dashboard calendar widget (CalendarWidget.qml).
# Source, first that works: Google Calendar via gog (read-only; needs `gog auth add`,
# GOG_ACCOUNT optional), then calro (Proton, upstream's source) if installed.
# Prints one JSON object, always exit 0:
#   {"state":"ok","stale":false,"events":[{"summary","start","end","all_day","calendar","location","skip","verified"}]}
#   {"state":"offline","reason":"..."}  when no source is set up or reachable
# Test mode, no account needed:  calendarpoll.sh --fixture [<file>]  (TODAY/TOMORROW become dates).
if [ "${1:-}" = "--fixture" ]; then
  f=${2:-$(dirname "$0")/fixtures/calendar.json}
  sed "s/TODAY/$(date +%F)/g; s/TOMORROW/$(date -d tomorrow +%F)/g" "$f" 2>/dev/null || echo '{"state":"offline","reason":"fixture missing"}'
  exit 0
fi
offline() { jq -cn --arg r "$1" '{state:"offline",reason:$r}'; exit 0; }
from=$(date +%F); to=$(date -d '+7 days' +%F)

if command -v gog >/dev/null && ! timeout 10 gog auth list 2>&1 | grep -q 'No tokens'; then
  json=$(timeout 20 gog --readonly --no-input calendar events --all --json --results-only --max 40 --from "$from" --to "$to" 2>/dev/null)
  if [ -n "$json" ] && ! echo "$json" | jq -e 'type == "object" and has("error")' >/dev/null 2>&1; then
    echo "$json" | jq -c '(if type == "array" then . else (.events // .items // []) end) as $ev |
      {state:"ok", stale:false, events:[$ev[] | {
        summary:(if (.summary // "") == "" then "(no title)" else .summary end),
        start:(.start.dateTime // .start.date // .start), end:(.end.dateTime // .end.date // .end),
        all_day:((.start.date // null) != null), calendar:(.calendarSummary // .organizer.displayName // .calendar // "Google"),
        location:(.location // ""), skip:((.status // "") == "cancelled" or any((.attendees // [])[]; .self == true and .responseStatus == "declined")),
        verified:true}] | sort_by(.start) | .[:40]}' 2>/dev/null && exit 0
  fi
fi

if command -v calro >/dev/null && [ -S /run/calro/calro.sock ]; then
  tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
  json=$(timeout 15 calro events --from "$from" --to "$to"${tz:+ --tz $tz} 2>/dev/null)
  [ -n "$json" ] || offline "calro not reachable"
  echo "$json" | jq -c 'if .error then {state:"offline",reason:.error} else
    {state:"ok", stale:(.stale // false), events:[.events[] | {summary:(if (.summary // "") == "" then "(no title)" else .summary end), start, end, all_day,
     calendar, location:(.location // ""), skip:(.cancelled or .declined), verified}] | .[:40]} end' 2>/dev/null \
    || offline "bad reply from calro"
  exit 0
fi
offline "no calendar linked (gog auth add <email> for Google Calendar)"
