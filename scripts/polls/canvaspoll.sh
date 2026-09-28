#!/usr/bin/env bash
# Canvas LMS upcoming-assignments poll (next 14 days, via the Planner API).
# Output (pipe-delimited, one line per item, sorted by due date):
#   <course>|<title>|<due_iso>|<missing>|<submitted>|<url>
#   error|<message>   (single line, only on failure)

CANVAS_BASE="https://erau.instructure.com"
KEY_FILE="$HOME/.config/canvas.key"

_die() { echo "error|$1"; exit 0; }

[ -s "$KEY_FILE" ] || _die "no api key"
TOKEN=$(tr -d '[:space:]' < "$KEY_FILE")
[ -n "$TOKEN" ] || _die "empty api key"

START=$(date -u +%Y-%m-%dT00:00:00Z)
END=$(date -u -d '+14 days' +%Y-%m-%dT00:00:00Z)

items=$(curl -sf -m 10 -H "Authorization: Bearer $TOKEN" \
  "$CANVAS_BASE/api/v1/planner/items?start_date=$START&end_date=$END&per_page=50") \
  || _die "api unreachable"

echo "$items" | jq -r '
  [.[] | select(.plannable_type as $t | ["assignment","quiz","discussion_topic"] | index($t))
   | select(.plannable.due_at != null)
   | {
       course: ((.context_name // "Unknown") | gsub("\\|"; "-")),
       title: ((.plannable.title // "Untitled") | gsub("\\|"; "-")),
       due: .plannable.due_at,
       missing: (.submissions.missing // false),
       submitted: (.submissions.submitted // false),
       url: (.html_url // "")
     }]
  | sort_by(.due)
  | .[]
  | [.course, .title, .due, (.missing|tostring), (.submitted|tostring), .url] | join("|")
' 2>/dev/null || _die "parse failed"
