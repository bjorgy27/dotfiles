#!/usr/bin/env python3 -I
"""Q duck (Beck, 2026-10-11): whenever Q's voice plays (any pw-play stream), every other app's audio drops to
DUCK_TO of its level; it returns to exactly where it was a moment after Q stops. Event driven through
`pactl subscribe`. Run as the user service q-duck.service. Covers the panel voice, presence lines, greetings."""
import json, subprocess, sys, time
DUCK_TO = 0.55           # gentle: music stays audible under Q's voice
FADE_DOWN_S = 0.30      # smooth ramp down when Q starts
FADE_UP_S = 0.90        # slow ramp back up after Q finishes
HOLD_S = 0.6            # keep ducked this long after the last voice stream ends (no flapping between sentences)
VOICE = {"pw-play", "paplay"}

def streams():
    try:
        out = subprocess.run(["pactl", "--format=json", "list", "sink-inputs"], capture_output=True, text=True, timeout=3).stdout
        return json.loads(out)
    except Exception:
        return []

def is_voice(s):
    p = s.get("properties") or {}
    return p.get("application.process.binary") in VOICE or p.get("application.name") in VOICE or p.get("node.name") in VOICE

def vol_of(si):
    return [int(v.get("value", 0)) for v in (si.get("volume") or {}).values()]

def fade(idx, start, end, secs, steps=10):
    """Linear volume ramp; start/end are single levels (max channel)."""
    for i in range(1, steps + 1):
        setvol(idx, [max(1, int(start + (end - start) * i / steps))])
        time.sleep(secs / steps)

def setvol(idx, vals):
    subprocess.run(["pactl", "set-sink-input-volume", str(idx), *[str(v) for v in vals]], capture_output=True, timeout=3)

saved = {}      # sink-input index -> original volume list
baseline = {}   # sink-input index -> highest un-ducked level ever seen (stops compounding drift, Beck 2026-10-14)
app_base = {}   # application name -> last un-ducked level; new streams of an app never start below it (Beck 2026-10-23:
                # PipeWire remembers the ducked volume per app, so a fresh Firefox stream came up quiet)
known = set()

def app_of(s):
    p = s.get("properties") or {}
    return p.get("application.name") or p.get("application.process.binary") or ""

def tick():
    global last_voice
    sis = streams()
    voice = [s for s in sis if is_voice(s) and not s.get("corked")]
    now = time.time()
    if not voice and not saved:
        for s in sis:
            if is_voice(s):
                continue
            v = vol_of(s)
            if not v:
                continue
            app = app_of(s)
            if s["index"] not in known:
                known.add(s["index"])
                b = app_base.get(app)
                if b and max(v) < max(b) * 0.9:
                    setvol(s["index"], b)       # new stream inherited a ducked level: put it back
                    v = b
            app_base[app] = v
    if voice:
        last_voice = now
        for s in sis:
            if is_voice(s) or s.get("corked") or s.get("mute") or s["index"] in saved:
                continue
            v = vol_of(s)
            if not v:
                continue
            known.add(s["index"])
            ab = app_base.get(app_of(s))
            if ab and max(v) < max(ab) * 0.9:
                v = ab                        # stream came up already ducked: trust the app's last real level
            elif s["index"] in baseline and max(v) < max(baseline[s["index"]]):
                v = baseline[s["index"]]      # a previous duck never fully restored: trust the remembered level
            else:
                baseline[s["index"]] = v
            saved[s["index"]] = v
            fade(s["index"], max(v), max(v) * DUCK_TO, FADE_DOWN_S)
    elif saved and now - last_voice >= HOLD_S:
        alive = {s["index"] for s in sis}
        for idx, v in list(saved.items()):
            if idx in alive:
                fade(idx, max(v) * DUCK_TO, max(v), FADE_UP_S)
                setvol(idx, v)
        saved.clear()

def main():
    p = subprocess.Popen(["pactl", "subscribe"], stdout=subprocess.PIPE, text=True, bufsize=1)
    tick()
    import select
    while True:
        r, _, _ = select.select([p.stdout], [], [], 0.2)
        if r:
            line = p.stdout.readline()
            if not line:
                break
            if "sink-input" in line or "sink input" in line:
                tick()
        elif saved:
            tick()          # pending restore after HOLD_S
    for idx, v in saved.items():
        setvol(idx, v)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
