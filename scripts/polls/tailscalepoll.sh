#!/usr/bin/env bash
# Tailscale health poll for TailscaleHealthWidget.qml. Prints one JSON doc.
#
# Passive: `tailscale status --json` (userspace tailscaled socket read from the
# running process). The only active part is a path probe: at most one
# `tailscale ping -c 1` per online peer every 5 minutes, run detached in the
# background so this script (and the UI) never waits on it. Results are cached
# in ~/.cache/quickshell_tsping/<peer>.json and picked up on the next poll.
#
# Schema "q.tailscale/1":
#   { schema, generatedAtMs, ok, error, backendState, health[], magicDNSSuffix,
#     devices: [ { name, dnsName, os, online, lastSeen, ip, self, exitNode,
#                  keyExpiry, keyExpiryDays, conn, relay, curAddr, probe } ] }
#   conn: "self" | "direct" | "relayed" | "idle" | "offline"

PING_DIR="$HOME/.cache/quickshell_tsping"
PING_EVERY=300

if [ -z "$TS_SOCKET" ]; then
  pid=$(pgrep -x tailscaled | head -n1)
  [ -n "$pid" ] && TS_SOCKET=$(ps -o args= -p "$pid" | grep -o -- '--socket[= ][^ ]*' | sed 's/--socket[= ]//')
fi
TS_BIN=$(command -v tailscale || echo "$HOME/.local/bin/tailscale")
TS=("$TS_BIN")
[ -n "$TS_SOCKET" ] && TS+=("--socket=$TS_SOCKET")

TS_JSON=""; TS_ERR=""
if [ -x "$TS_BIN" ]; then
  TS_JSON=$(timeout 5 "${TS[@]}" status --json 2>/dev/null) || TS_ERR="tailscale status failed"
else
  TS_ERR="tailscale not installed"
fi

mkdir -p "$PING_DIR"
DUE=$(TS_JSON="$TS_JSON" TS_ERR="$TS_ERR" PING_DIR="$PING_DIR" PING_EVERY="$PING_EVERY" python3 -I - <<'PY'
import json, os, time, glob
from datetime import datetime, timezone

def parse_ts(s):
    if not s or s.startswith("0001-"): return None
    try:
        s = s.rstrip("Z")
        if "." in s:
            a, b = s.split("."); s = a + "." + b[:6]
        return datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp()
    except Exception:
        return None

now = time.time()
pdir = os.environ["PING_DIR"]; every = int(os.environ["PING_EVERY"])
doc = {"schema": "q.tailscale/1", "generatedAtMs": int(now * 1000), "ok": False,
       "error": "", "backendState": "", "health": [], "magicDNSSuffix": "", "devices": []}
due = []
try:
    ts = json.loads(os.environ.get("TS_JSON") or "")
except Exception:
    ts = None
if ts is None:
    doc["error"] = os.environ.get("TS_ERR") or "no tailscale data"
else:
    doc["backendState"] = ts.get("BackendState") or "unknown"
    doc["ok"] = doc["backendState"] == "Running"
    if not doc["ok"]: doc["error"] = "tailscale " + doc["backendState"].lower()
    doc["health"] = [str(h) for h in (ts.get("Health") or [])]
    doc["magicDNSSuffix"] = ts.get("MagicDNSSuffix") or ""

    def dev(p, is_self):
        tags = p.get("Tags") or []
        if not is_self and (p.get("ShareeNode") or "tag:ingress" in tags):
            return None
        dns = (p.get("DNSName") or "").rstrip(".")
        host = p.get("HostName") or ""
        short = dns.split(".")[0] if dns else host
        name = (host if host and host != "localhost" else short) or "?"
        ips = p.get("TailscaleIPs") or []
        v4 = next((i for i in ips if ":" not in i), ips[0] if ips else "")
        online = bool(p.get("Online")) or is_self
        exp = parse_ts(p.get("KeyExpiry"))
        relay = p.get("Relay") or ""
        cur = p.get("CurAddr") or ""
        probe = None
        if is_self: conn = "self"
        elif not online: conn = "offline"
        elif cur: conn = "direct"
        elif p.get("Active") and relay: conn = "relayed"
        else: conn = "idle"
        key = "".join(c for c in name if c.isalnum() or c in "-_")
        if not is_self and online and v4:
            f = os.path.join(pdir, key + ".json")
            try:
                probe = json.load(open(f))
            except Exception:
                probe = None
            try: age = now - os.path.getmtime(f)
            except OSError: age = 1e9
            lock = os.path.join(pdir, key + ".lock")
            locked = os.path.exists(lock) and now - os.path.getmtime(lock) < 60
            if age >= every and not locked:
                due.append(key + " " + v4)
            # A fresh probe refines "idle": the path it found is the real one.
            if conn == "idle" and probe and now - probe.get("atMs", 0) / 1000 < every * 2:
                if probe.get("via") == "direct": conn = "direct"
                elif probe.get("via") == "derp":
                    conn = "relayed"; relay = probe.get("derp") or relay
        return {"name": name, "dnsName": dns, "os": p.get("OS") or "", "online": online,
                "lastSeen": "" if (p.get("LastSeen") or "").startswith("0001-") else (p.get("LastSeen") or ""),
                "ip": v4, "self": is_self, "exitNode": bool(p.get("ExitNode")),
                "keyExpiry": p.get("KeyExpiry") or "",
                "keyExpiryDays": None if exp is None or p.get("KeyExpiry") is None else round((exp - now) / 86400, 1),
                "conn": conn, "relay": relay, "curAddr": cur, "probe": probe}

    devs = []
    if ts.get("Self"):
        d = dev(ts["Self"], True)
        if d: devs.append(d)
    for p in (ts.get("Peer") or {}).values():
        d = dev(p, False)
        if d: devs.append(d)
    devs.sort(key=lambda d: (not d["self"], not d["online"], d["name"].lower()))
    doc["devices"] = devs
with open(os.path.join(pdir, "status.json.tmp"), "w") as f:
    json.dump(doc, f, separators=(",", ":"))
for d in due: print(d)
PY
)

# Detached, rate-limited path probes: never waited on.
while read -r key ip; do
  [ -z "$key" ] && continue
  touch "$PING_DIR/$key.lock"
  IP="$ip" F="$PING_DIR/$key.json" L="$PING_DIR/$key.lock" setsid -f bash -c '
    out=$(timeout 6 "$@" ping -c 1 --timeout 4s "$IP" 2>&1)
    via=none; derp=""; ms=""
    if   [[ $out =~ via\ DERP\(([a-z0-9-]+)\)\ in\ ([0-9.]+)ms ]]; then via=derp; derp=${BASH_REMATCH[1]}; ms=${BASH_REMATCH[2]}
    elif [[ $out =~ via\ ([^ ]+)\ in\ ([0-9.]+)ms ]]; then via=direct; ms=${BASH_REMATCH[2]}; fi
    printf "{\"atMs\":%s,\"via\":\"%s\",\"derp\":\"%s\",\"ms\":\"%s\"}\n" "$(date +%s%3N)" "$via" "$derp" "$ms" > "$F.tmp" && mv "$F.tmp" "$F"
    rm -f "$L"
  ' _ "${TS[@]}" </dev/null >/dev/null 2>&1
done <<< "$DUE"

cat "$PING_DIR/status.json.tmp"
