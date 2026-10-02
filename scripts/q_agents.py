#!/usr/bin/env python3
"""q_agents.py - background-agent feed for the quickshell Q chat panel.

Polls `openclaw tasks list --json --runtime subagent` and writes the panel's
agent list to $XDG_RUNTIME_DIR/q-voice/agents.json:

  openclaw tasks --> group by childSessionKey --> one row per agent session,
       showing its latest run, with earlier runs collapsed into row["runs"]

QChatWidget.qml watches that file, so the write is atomic (temp + os.replace)
and only happens when the content actually changed. A failing, hanging or
junk-returning openclaw leaves the previous file untouched.

  q_agents.py                 poll forever (installed as q-agents.service)
  q_agents.py --once          one pass, then exit
  q_agents.py --interval 5    poll every 5s instead of 2s
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

POLL_TIMEOUT = 25          # openclaw is a node CLI; a cold start is not instant
MAX_AGE_MS = 24 * 60 * 60 * 1000
MAX_ENTRIES = 50

# openclaw status -> what the panel paints. Anything unmapped falls through to
# "failed", which the panel renders red, so a new upstream status fails loud.
STATUS_MAP = {
    "running": "running",
    "queued": "queued",
    "succeeded": "done",
    "failed": "failed",
    "timed_out": "failed",
    "cancelled": "failed",
    "lost": "failed",
    "blocked": "failed",
}
LIVE = ("running", "queued")


def log(msg):
    print("%s q_agents: %s" % (time.strftime("%H:%M:%S"), msg), file=sys.stderr, flush=True)


def openclaw_bin():
    """systemd --user often has a bare PATH, so fall back to the known install."""
    found = shutil.which("openclaw")
    if found:
        return found
    local = os.path.expanduser("~/.local/bin/openclaw")
    return local if os.access(local, os.X_OK) else "openclaw"


def fetch_tasks():
    """Return the task list, or raise on anything that is not clean JSON."""
    proc = subprocess.run(
        [openclaw_bin(), "tasks", "list", "--json", "--runtime", "subagent"],
        capture_output=True, text=True, timeout=POLL_TIMEOUT,
    )
    if proc.returncode != 0:
        raise RuntimeError("exit %d: %s" % (proc.returncode, (proc.stderr or proc.stdout or "").strip()[:200]))
    payload = json.loads(proc.stdout)
    tasks = payload.get("tasks")
    if not isinstance(tasks, list):
        raise ValueError("no tasks array in output")
    return tasks


def as_ms(value):
    return value if isinstance(value, (int, float)) and value > 0 else None


def run_entry(task, run_no):
    """The {run, status, startedAt, endedAt, task, result} shape shared by runs[]."""
    status = STATUS_MAP.get(task.get("status"), "failed")
    created = as_ms(task.get("createdAt"))
    entry = {
        "run": run_no,
        "status": status,
        "startedAt": as_ms(task.get("startedAt")) or created,
        "task": task.get("task") or "",
        "result": task.get("progressSummary") or "",
    }
    ended = as_ms(task.get("endedAt"))
    # live rows must carry no endedAt at all: the panel drops finished rows 30
    # minutes after endedAt, and a stray value would hide a working agent.
    if ended and status not in LIVE:
        entry["endedAt"] = ended
    return entry


def build_agents(tasks, now_ms):
    groups = {}
    for task in tasks:
        key = task.get("childSessionKey")
        created = as_ms(task.get("createdAt"))
        if not key or created is None or now_ms - created > MAX_AGE_MS:
            continue
        groups.setdefault(key, []).append(task)

    agents = []
    for key, runs in groups.items():
        runs.sort(key=lambda t: (t.get("createdAt") or 0, t.get("taskId") or ""))
        numbered = [(i + 1, t) for i, t in enumerate(runs)]

        # trailing queued runs are follow-ups waiting their turn: the first one
        # is the row's current run, the rest are counted in "pending"
        queued_tail = 0
        for _, task in reversed(numbered):
            if STATUS_MAP.get(task.get("status")) != "queued":
                break
            queued_tail += 1
        cut = len(numbered) - queued_tail if queued_tail else len(numbered) - 1

        run_no, current = numbered[cut]
        entry = run_entry(current, run_no)
        row = {
            "id": key,
            "label": current.get("label") or current.get("agentId") or "agent",
            "status": entry["status"],
            "startedAt": entry["startedAt"],
        }
        if "endedAt" in entry:
            row["endedAt"] = entry["endedAt"]
        row["task"] = entry["task"]
        row["result"] = entry["result"]
        row["run"] = run_no
        earlier = [run_entry(t, n) for n, t in numbered[:cut]]
        if earlier:
            row["runs"] = earlier
        pending = max(0, queued_tail - 1)
        if pending:
            row["pending"] = pending
        if run_no > 1:
            row["followup"] = entry["task"]
        row["_sort"] = as_ms(current.get("createdAt")) or 0
        agents.append(row)

    agents.sort(key=lambda a: a["_sort"], reverse=True)
    for row in agents[:MAX_ENTRIES]:
        row.pop("_sort", None)
    return agents[:MAX_ENTRIES]


def write_if_changed(path, text):
    tmp = path + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser(description="write the Q panel's background-agent list")
    ap.add_argument("--once", action="store_true", help="single pass, then exit")
    ap.add_argument("--interval", type=float, default=2.0, help="seconds between polls (default 2)")
    args = ap.parse_args()

    runtime = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    outdir = os.path.join(runtime, "q-voice")
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, "agents.json")

    try:
        with open(path, encoding="utf-8") as fh:
            last = fh.read()
    except OSError:
        last = None

    failing = False
    while True:
        try:
            tasks = fetch_tasks()
            agents = build_agents(tasks, int(time.time() * 1000))
            text = json.dumps({"agents": agents}, ensure_ascii=False) + "\n"
            if text != last:
                write_if_changed(path, text)
                last = text
            if failing:
                log("openclaw recovered, %d agents" % len(agents))
                failing = False
        except subprocess.TimeoutExpired:
            if not failing:
                log("openclaw timed out after %ds, keeping previous file" % POLL_TIMEOUT)
                failing = True
        except Exception as exc:                                  # noqa: BLE001
            if not failing:
                log("%s: %s - keeping previous file" % (type(exc).__name__, exc))
                failing = True
        if args.once:
            return 0
        time.sleep(max(0.5, args.interval))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
