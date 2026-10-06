"""q_pickup.py - agent pickup for the quickshell Q chat panel, driven by q_agents.py.

The panel session spawns its agents with expectsCompletionMessage false, so the
gateway never runs its own completion turn in the panel's lane. On the
claude-cli backend that turn has its tools stripped and nothing bounds it; it
has degenerated into fake tool calls and blank lines up to max_tokens and held
the panel's lane for 14 minutes. Instead, when one of those agents ends, this
starts an ordinary panel turn with full tools:

  q_agents.py poll (openclaw tasks list, already running every 2s)
       --> Pickup.tick(): panel agents that ended, not yet reported
       --> q_voice.py turn --json --pickup --text '[agent "x" finished (done); read
           its result with sessions_history <key> and tell me in one to three sentences]'
       --> the reply shows, is read aloud and lands in chat.jsonl like any typed turn

One pickup turn at a time, only while the panel is idle (the same state.json
test the panel uses before it sends, plus the turn pid files) and the desktop
is unlocked; lockdown.sh keeps no state file but always locks the desktop, so
reports wait out a lockdown and arrive after unlock. Agents spawned the default
way are left to the gateway's announce and q_inbox.py, so nothing is reported
twice. Delivered task ids live in ~/.local/state/q-voice/pickup.json: a restart
never repeats a report, and a pickup turn that died with the service runs again.

  Q_PICKUP=0                 off
  Q_PICKUP_SESSION=<key>     watch another requester session (default: the panel's)
"""

import json
import os
import socket
import subprocess
import sys
import time


def _conf(path=os.environ.get("Q_CONF") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "q-voice/env")):
    """q_voice.py's per-machine settings, environment first. Read into a dict, not
    os.environ, so the gateway token never rides along to openclaw or the mirror."""
    conf = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                conf[k.strip()] = v.split(" #", 1)[0].strip().strip('"').strip("'")
    except OSError:
        pass
    conf.update(os.environ)
    return conf


CONF = _conf()
ENABLED = CONF.get("Q_PICKUP", "1") == "1"
# the panel's session, worked out the way q_voice.py does it
PANEL_KEY = (CONF.get("Q_PICKUP_SESSION") or "agent:%s:openai-user:%s" % (
    CONF.get("Q_AGENT", "main"),
    CONF.get("Q_USER") or "%s-voice" % (CONF.get("Q_DEVICE") or socket.gethostname()))).lower()
RUN = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "q-voice")
STATEF = CONF.get("Q_PICKUP_STATE") or os.path.expanduser("~/.local/state/q-voice/pickup.json")
VOICE_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "q_voice.py")
VOICE_PYTHON = CONF.get("Q_PY") or os.path.expanduser("~/.local/share/q-voice/venv/bin/python")

# openclaw task status -> how the note words it. Not cancelled: Beck did that himself.
FIRE = {"succeeded": "done", "failed": "failed", "timed_out": "timed out", "lost": "lost"}
NO_ANNOUNCE = ("not_applicable", "not_required")   # spawned with expectsCompletionMessage:false
MAX_AGE_MS = 12 * 60 * 60 * 1000   # ended longer ago than this when first noticed: skipped
BATCH = 4                  # agents per pickup turn
TRIES = 3
RETRY = 60                 # seconds before a failed pickup turn goes again
TIMEOUT = 900              # a pickup turn still running after this is stopped
KEEP = 500                 # task ids remembered
BUSY_EXIT = 75             # q_voice.py --pickup found a turn already running (EX_TEMPFAIL)
STALE_STATE = 600          # a non-idle state.json this old with no q_voice.py alive is a leftover


def log(msg):
    print("%s q_pickup: %s" % (time.strftime("%H:%M:%S"), msg), file=sys.stderr, flush=True)


def as_ms(value):
    return value if isinstance(value, (int, float)) and value > 0 else None


def is_voice(pid, mark=b"q_voice"):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            return mark in f.read()
    except (OSError, ValueError, TypeError):
        return False


def voice_pid_alive(name):
    """True if $RUN/<name> names a live q_voice.py (a recycled pid doesn't count)."""
    try:
        with open(os.path.join(RUN, name)) as f:
            return is_voice(int(f.read().strip()))
    except (OSError, ValueError):
        return False


def panel_busy():
    """A turn in flight: what the panel checks before it sends (state.json not idle),
    plus the typed-turn and SUPER+T pid files. A pickup never talks over Beck."""
    if voice_pid_alive("typed.pid") or voice_pid_alive("turn.pid"):
        return True
    try:
        with open(os.path.join(RUN, "state.json")) as f:
            st = json.load(f)
    except (OSError, ValueError):
        return False
    return st.get("state") not in ("idle", "", None) and time.time() - (st.get("ts") or 0) < STALE_STATE


def screen_locked():
    """A live hyprlock here; orphans (PPID 1) hold no lock, as in lockwatch-stream.sh."""
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open("/proc/%s/comm" % pid) as f:
                if f.read().strip() != "hyprlock":
                    continue
            with open("/proc/%s/stat" % pid) as f:
                stat = f.read()
        except OSError:
            continue
        if stat[stat.rindex(")") + 2:].split()[1] != "1":
            return True
    return False


def _clean(s, n):
    """Model-written labels go inside a bracketed note: no quotes, brackets or newlines."""
    return " ".join(str(s).replace('"', "'").replace("[", "(").replace("]", ")").split())[:n]


def prompt(batch):
    """The bracketed note a pickup turn sends in the panel session."""
    def one(t):
        status = FIRE[t["status"]]
        err = _clean(t.get("error") or "", 160) if status != "done" else ""
        return '"%s" finished (%s)' % (_clean(t.get("label") or t.get("agentId") or "agent", 80),
                                       status + (": " + err if err else ""))
    if len(batch) == 1:
        return ("[agent %s; read its result with sessions_history %s and tell me in one to three sentences]"
                % (one(batch[0]), batch[0]["childSessionKey"]))
    return ("[agents finished: %s; read each result with sessions_history and tell me in one to three sentences]"
            % "; ".join("%s, %s" % (one(t), t["childSessionKey"]) for t in batch))


def emit(ev):
    """Append one panel event, like q_voice.py emit(). Best effort."""
    try:
        os.makedirs(RUN, exist_ok=True)
        with open(os.path.join(RUN, "events.jsonl"), "a") as f:
            f.write(json.dumps(dict(ev, ts=int(time.time() * 1000))) + "\n")
    except OSError:
        pass


class Pickup:
    """tick() runs once per q_agents.py poll and never blocks, so there's no loop of its own.

    pickup.json: {"seen": [taskId, ...], "inflight": {"ids": [...], "pid": n} or null}.
    An id is seen once its turn exits 0 (or is given up on). A turn that outlived a
    restart is waited out and counted; one that died with the service runs again."""

    def __init__(self):
        self.seen, self.inflight, self.first = [], None, True
        try:
            with open(STATEF) as f:
                d = json.load(f)
            self.seen, self.inflight, self.first = list(d.get("seen") or []), d.get("inflight"), False
        except (OSError, ValueError):
            pass
        self.seen_set = set(self.seen)
        self.proc, self.batch, self.started = None, [], 0.0
        self.outlived = False      # the inflight turn from before a restart is still going
        self.tries, self.retry_at = {}, {}
        self.waiting = ""          # why ready reports are held; logged once per change

    def save(self):
        os.makedirs(os.path.dirname(STATEF), exist_ok=True)
        tmp = STATEF + ".tmp.%d" % os.getpid()
        with open(tmp, "w") as f:
            json.dump({"seen": self.seen[-KEEP:], "inflight": self.inflight}, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, STATEF)

    def mark(self, ids):
        for i in ids:
            if i not in self.seen_set:
                self.seen.append(i)
                self.seen_set.add(i)
            self.tries.pop(i, None)
            self.retry_at.pop(i, None)

    def finished(self, tasks):
        """The panel's no-announce agent runs that ended and weren't reported, oldest first."""
        out = []
        for t in tasks:
            tid = t.get("taskId") or t.get("runId")
            if (tid and tid not in self.seen_set and t.get("childSessionKey")
                    and (t.get("requesterSessionKey") or "").lower() == PANEL_KEY
                    and t.get("deliveryStatus") in NO_ANNOUNCE and t.get("status") in FIRE):
                out.append((tid, t))
        out.sort(key=lambda p: as_ms(p[1].get("endedAt")) or 0)
        return out

    def tick(self, tasks, now_ms):
        if self.proc is not None:
            rc = self.proc.poll()
            if rc is None:
                if time.monotonic() - self.started > TIMEOUT:
                    log("pickup turn still running after %ds, stopping it" % TIMEOUT)
                    self.proc.terminate()       # q_voice.py winds down as on Esc; reaped next poll
                    self.started = time.monotonic()
                return
            self.reap(rc)
        elif self.inflight:
            if is_voice(self.inflight.get("pid"), b"--pickup"):
                self.outlived = True
                return
            if self.outlived:
                self.mark(self.inflight.get("ids") or [])
            self.inflight, self.outlived = None, False
            self.save()

        fresh = self.finished(tasks)
        if self.first:
            # first start: whatever already ended is history, not news
            self.mark([tid for tid, _ in fresh])
            self.first = False
            self.save()
            log("watching %s, %d finished agent(s) marked read" % (PANEL_KEY, len(fresh)))
            return
        stale = [tid for tid, t in fresh if now_ms - (as_ms(t.get("endedAt")) or now_ms) > MAX_AGE_MS]
        if stale:
            self.mark(stale)
            self.save()
            log("%d agent(s) ended too long ago, not reported" % len(stale))
        mono = time.monotonic()
        ready = [(tid, t) for tid, t in fresh if tid not in self.seen_set and self.retry_at.get(tid, 0) <= mono]
        if not ready:
            return
        why = "a turn is in flight" if panel_busy() else "the screen is locked" if screen_locked() else ""
        if why:
            if why != self.waiting:
                log("%d agent report(s) waiting: %s" % (len(ready), why))
                self.waiting = why
            return
        self.waiting = ""
        self.launch(ready[:BATCH])

    def launch(self, ready):
        python = VOICE_PYTHON if os.access(VOICE_PYTHON, os.X_OK) else sys.executable
        cmd = [python, VOICE_PY, "turn", "--json", "--pickup", "--text", prompt([t for _, t in ready])]
        self.batch = [tid for tid, _ in ready]
        self.proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                     start_new_session=True)
        self.started = time.monotonic()
        self.inflight = {"ids": self.batch, "pid": self.proc.pid}
        self.save()
        log("reporting %s" % ", ".join(_clean(t.get("label") or tid, 40) for tid, t in ready))

    def reap(self, rc):
        ids, self.proc, self.batch, self.inflight = self.batch, None, [], None
        mono = time.monotonic()
        if rc == 0 or rc < 0:          # delivered, or stopped (Esc, SUPER+T, timeout): done either way
            self.mark(ids)
        elif rc == BUSY_EXIT:          # Beck got in first; go again once the panel is idle
            for i in ids:
                self.retry_at[i] = mono + 5
        else:
            given_up = []
            for i in ids:
                self.tries[i] = self.tries.get(i, 0) + 1
                if self.tries[i] >= TRIES:
                    given_up.append(i)
                else:
                    self.retry_at[i] = mono + RETRY
            if given_up:
                self.mark(given_up)
                emit({"type": "error", "message": "couldn't fetch %d agent report(s); the results are in "
                      "the agents list" % len(given_up)})
            log("pickup turn failed (exit %d), %s" % (rc, "gave up on %d" % len(given_up) if given_up
                                                      else "retrying in %ds" % RETRY))
        self.save()
