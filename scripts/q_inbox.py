#!/usr/bin/env python3
"""q_inbox.py - unsolicited-message bridge for the quickshell Q chat panel.

The panel talks to the gateway over `/v1/chat/completions`, which is strictly
request/response: it only ever renders a reply to a request it made itself.
When a background agent finishes, the gateway runs the parent's turn and writes
that reply into the session transcript, but nothing asks for it, so the panel
never shows it and nothing speaks it. QChatWidget.qml has handled
`{"type": "report"}` events from "q-inbox.service" since it was written; this
is the producer that was missing.

  gateway sessions_list (cheap updatedAt probe)
       --> sessions_history on change
       --> assistant turns the panel never asked for
       --> $XDG_RUNTIME_DIR/q-voice/events.jsonl  (panel renders them)
         + ~/.local/state/q-voice/chat.jsonl      (survives a panel reload)
         + q_voice.py say                         (spoken in the Q voice)

Which turns are "unsolicited" comes from the transcript's idempotencyKey:

  cli-assistant:chatcmpl_<id>   the panel's own reply, already on screen - skip
  cli-assistant:announce:...    a completion the gateway delivered by itself - emit
  (absent)                      a mid-turn assistant step, already streamed - skip

Both announce flavours are the parent speaking to Beck: `announce:v1:...` after
a child reports, `announce:requester-settle:...` after a sessions_yield settles.

  q_inbox.py                  poll forever (installed as q-inbox.service)
  q_inbox.py --once           one pass, then exit
  q_inbox.py --replay 2       re-emit the last 2 announcements (verification)
  q_inbox.py --once --dry-run show what would be emitted, touch nothing
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

import requests

HOME = os.path.expanduser("~")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


# ---------------------------------------------------------------- config (env)
# Same per-machine file q_voice.py reads, same precedence: the environment wins.
def _load_conf(path=os.environ.get("Q_CONF") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "q-voice/env")):
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.split(" #", 1)[0].strip().strip('"').strip("'")
                os.environ.setdefault(k.strip(), v)
    except OSError:
        pass


_load_conf()
E = os.environ.get
RUN = os.path.join(E("XDG_RUNTIME_DIR", "/tmp"), "q-voice")
STATE_DIR = os.path.join(HOME, ".local/state/q-voice")
EVENTS = os.path.join(RUN, "events.jsonl")
STATEF = os.path.join(RUN, "state.json")
CHATF = os.path.join(STATE_DIR, "chat.jsonl")
INBOXF = E("Q_INBOX_STATE") or os.path.join(STATE_DIR, "inbox.json")

GATEWAY_URL = E("Q_GATEWAY_URL", "").rstrip("/")
GATEWAY_TOKEN = E("Q_GATEWAY_TOKEN", "")
AGENT = E("Q_AGENT", "main")
DEVICE = E("Q_DEVICE", "")
USER = E("Q_USER", f"{DEVICE or 'desktop'}-voice")
SESSION_KEY = E("Q_SESSION_KEY", f"agent:{AGENT}:openai-user:{USER}").lower()
SPEAK = E("Q_INBOX_SPEAK", "1") == "1" and E("Q_MUTE", "0") != "1"
SPEAK_MAX_CHARS = int(E("Q_SPEAK_MAX_CHARS", "1200"))
NOTIFY = E("Q_INBOX_NOTIFY", "1") == "1"
NAME = E("Q_NAME", "Q")

HTTP_TIMEOUT = 30
SEEN_KEEP = 200            # ids remembered; a day of announcements is a handful
SESSION = requests.Session()

# Output directives (MEDIA:, [[audio_as_voice]], [[reply_to...]]) are delivery
# instructions for a chat channel, never something to show or read aloud.
_DIRECTIVE = re.compile(r"^(?:MEDIA:\S*|\[\[[a-z_][a-z0-9_:\-]*\]\])\s*$", re.I)
_TAG = re.compile(r"\[[a-z][a-z' -]{1,30}\]")       # ElevenLabs v3 audio tags


def log(msg):
    print("%s q_inbox: %s" % (time.strftime("%H:%M:%S"), msg), file=sys.stderr, flush=True)


def invoke(tool, args):
    """Call one gateway tool over the always-on /tools/invoke endpoint."""
    r = SESSION.post(f"{GATEWAY_URL}/tools/invoke",
                     headers={"Authorization": f"Bearer {GATEWAY_TOKEN}"},
                     json={"tool": tool, "args": args}, timeout=HTTP_TIMEOUT)
    body = r.json()
    if not body.get("ok"):
        raise RuntimeError(body.get("error") or f"HTTP {r.status_code}")
    return json.loads(body["result"]["content"][0]["text"])


def session_updated_at():
    """Cheap change probe: the session row carries updatedAt without the transcript.

    `search` keeps the payload to a few KB; a miss falls back to a plain listing
    so a changed search behaviour costs efficiency, never delivery."""
    for args in ({"agentId": AGENT, "limit": 20, "search": USER},
                 {"agentId": AGENT, "limit": 100}):
        for row in invoke("sessions_list", args).get("sessions") or []:
            if (row.get("key") or "").lower() == SESSION_KEY:
                return row.get("updatedAt") or 0
    return 0


def history():
    return invoke("sessions_history", {"sessionKey": SESSION_KEY, "limit": 40, "includeTools": False})


def message_text(msg):
    """Join an assistant message's text blocks, minus the delivery directives."""
    content = msg.get("content")
    if isinstance(content, str):
        raw = content
    else:
        raw = "\n".join(b.get("text") or "" for b in (content or [])
                        if isinstance(b, dict) and b.get("type") == "text")
    keep = [ln for ln in raw.splitlines() if not _DIRECTIVE.match(ln.strip())]
    return "\n".join(keep).strip()


def announcements(hist):
    """The assistant turns the gateway delivered on its own, oldest first."""
    out = []
    for msg in hist.get("messages") or []:
        if msg.get("role") != "assistant":
            continue
        oc = msg.get("__openclaw") or {}
        idem = msg.get("idempotencyKey") or oc.get("idempotencyKey") or ""
        if ":announce:" not in idem:
            continue
        mid = oc.get("id") or idem
        text = message_text(msg)
        if not text or re.fullmatch(r"NO_REPLY\.?", text.strip()):
            continue
        out.append({"id": mid, "text": text,
                    "ts": oc.get("recordTimestampMs") or msg.get("timestamp") or 0})
    out.sort(key=lambda m: m["ts"])
    return out


def load_state():
    try:
        with open(INBOXF) as f:
            d = json.load(f)
        return list(d.get("seen") or []), d.get("updatedAt") or 0
    except (OSError, ValueError):
        return None, 0


def save_state(seen, updated_at):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = INBOXF + ".tmp.%d" % os.getpid()
    with open(tmp, "w") as f:
        json.dump({"seen": seen[-SEEN_KEEP:], "updatedAt": updated_at}, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, INBOXF)


def emit(ev):
    """Append one panel event. A missing panel must never break the bridge."""
    try:
        os.makedirs(RUN, exist_ok=True)
        with open(EVENTS, "a") as f:
            f.write(json.dumps(dict(ev, ts=int(time.time() * 1000))) + "\n")
    except OSError as exc:
        log("events.jsonl: %s" % exc)


def remember(text):
    """Panel history, so a reload still shows the report."""
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(CHATF, "a") as f:
            f.write(json.dumps({"role": "q", "text": text, "ts": int(time.time())}) + "\n")
    except OSError as exc:
        log("chat.jsonl: %s" % exc)


def panel_state():
    try:
        with open(STATEF) as f:
            return (json.load(f).get("state") or "idle")
    except (OSError, ValueError):
        return "idle"


def busy():
    """Never talk over a turn Beck is in the middle of; the report waits a pass."""
    if panel_state() not in ("idle", ""):
        return True
    return os.path.exists(os.path.join(RUN, "typed.pid"))


def notify(text):
    if not NOTIFY:
        return
    body = _TAG.sub("", text).strip()
    try:
        subprocess.Popen(["notify-send", "-a", NAME, "-t", "8000", "%s: agent report" % NAME, body[:300]],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


def speak(text):
    """Read the report in the Q voice via the existing TTS chain."""
    said = _TAG.sub("", text).strip()[:SPEAK_MAX_CHARS]
    if not said:
        return
    try:
        subprocess.run([sys.executable, os.path.join(SCRIPT_DIR, "q_voice.py"), "say", said],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
    except (OSError, subprocess.SubprocessError) as exc:
        log("say failed: %s" % exc)


def show(msg, dry_run=False):
    """Put the report on screen. Returns False if nothing was written."""
    text = msg["text"]
    if dry_run:
        log("would deliver %s: %s" % (msg["id"][:8], text[:120].replace("\n", " ")))
        return False
    emit({"type": "report", "text": text})
    remember(text)
    notify(text)
    log("delivered %s (%d chars)" % (msg["id"][:8], len(text)))
    return True


def main():
    ap = argparse.ArgumentParser(description="bridge unsolicited gateway replies into the Q chat panel")
    ap.add_argument("--once", action="store_true", help="single pass, then exit")
    ap.add_argument("--interval", type=float, default=4.0, help="seconds between polls (default 4)")
    ap.add_argument("--replay", type=int, metavar="N",
                    help="re-deliver the last N announcements, ignoring the seen list")
    ap.add_argument("--dry-run", action="store_true", help="report what would be delivered, write nothing")
    ap.add_argument("--no-speak", action="store_true", help="panel only, stay silent")
    ap.add_argument("--session", help="override the session key to watch")
    args = ap.parse_args()

    global SESSION_KEY
    if args.session:
        SESSION_KEY = args.session.lower()
    if not GATEWAY_URL or not GATEWAY_TOKEN:
        sys.exit("Q_GATEWAY_URL / Q_GATEWAY_TOKEN not set (see q_voice.env.example)")
    do_speak = not args.no_speak

    if args.replay:
        recent = announcements(history())[-args.replay:]
        if not recent:
            log("no announcements in the recent transcript")
            return 0
        for msg in recent:
            if show(msg, args.dry_run) and do_speak and SPEAK:
                speak(msg["text"])
        return 0

    seen, last_updated = load_state()
    if seen is None:
        # First start: adopt the existing backlog as read, so enabling the
        # bridge does not replay a day of reports at Beck in one go.
        seen = [m["id"] for m in announcements(history())]
        last_updated = session_updated_at()
        if not args.dry_run:
            save_state(seen, last_updated)
        log("first run: %d past announcement(s) marked read, watching %s" % (len(seen), SESSION_KEY))
        if args.once:
            return 0

    seen_set = set(seen)
    failing = False
    while True:
        try:
            updated = session_updated_at()
            if updated != last_updated or args.once:
                fresh = [m for m in announcements(history()) if m["id"] not in seen_set]
                if fresh and busy():
                    # Leave last_updated alone so the next pass retries.
                    log("%d report(s) waiting: a turn is in flight" % len(fresh))
                else:
                    for msg in fresh:
                        shown = show(msg, args.dry_run)
                        seen.append(msg["id"])
                        seen_set.add(msg["id"])
                        # Record it before speaking: reading a long report aloud
                        # blocks for a minute or more, and a restart in that
                        # window must not deliver it a second time.
                        if not args.dry_run:
                            save_state(seen, updated)
                        if shown and do_speak and SPEAK:
                            speak(msg["text"])
                    last_updated = updated
                    if not args.dry_run:
                        save_state(seen, last_updated)
            if failing:
                log("gateway recovered")
                failing = False
        except Exception as exc:                                  # noqa: BLE001
            if not failing:
                log("%s: %s - retrying" % (type(exc).__name__, exc))
                failing = True
        if args.once:
            return 0
        time.sleep(max(1.0, args.interval))


if __name__ == "__main__":
    sys.exit(main() or 0)
