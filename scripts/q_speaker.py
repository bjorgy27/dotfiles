#!/usr/bin/env python3
"""q-speaker: who is talking.

The voice assistant (q_voice.py) posts each turn's audio here and gets back a
profile name, so replies can be addressed to the right person and strangers can
be refused. Speech never leaves the machine: a WeSpeaker ResNet34 model runs
locally through sherpa-onnx and only 256-float embeddings are stored, never the
audio itself.

Endpoints, matching what q_voice.py expects (Q_SPEAKER_URL points at /identify):

  POST /identify            wav body  -> {"speaker", "score", "speakers", "shift", "segments", "candidates"}
  POST /enroll?name=<name>  wav body  -> {"ok", "name", "clips"}
  GET  /speakers                      -> {"<name>": {"clips": n}, ...}
  DELETE /speakers?name=<name>        -> forget a profile

Run it through the q-speaker user unit; see `q_voice.sh setup speaker`.
Model and profiles live under ~/.local/share/q-speaker.
"""

import io
import json
import os
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import numpy as np
import sherpa_onnx

HOME = os.path.expanduser("~")
SHARE = os.environ.get("Q_SPEAKER_DIR", os.path.join(HOME, ".local/share/q-speaker"))
MODEL = os.environ.get("Q_SPEAKER_MODEL", os.path.join(SHARE, "wespeaker_en_voxceleb_resnet34_LM.onnx"))
PROFILES = os.path.join(SHARE, "profiles.json")
HOST = os.environ.get("Q_SPEAKER_HOST", "127.0.0.1")
PORT = int(os.environ.get("Q_SPEAKER_PORT", "8179"))

META = os.path.join(SHARE, "profiles-meta.json")     # per clip: which device it came from, when
DECISIONS = os.path.join(SHARE, "decisions.jsonl")    # recent identify results (no audio, no embeddings)
COHORT = os.path.join(SHARE, "cohort.npz")            # "mean" + "voices": other speakers, for normalisation

# Calibrated 2026-10-06 (q-speaker-audit.md): raw cosine put every voice, Beck's
# or not, at 0.6-0.85, so embeddings are centred on a cohort mean first. A match
# then needs THRESHOLD, and must beat the closest cohort voices by COHORT_MARGIN
# (a noisy clip resembles everybody). Short or noisy clips that otherwise match
# come back "unsure" with repeat=true: fail closed, ask again.
THRESHOLD = float(os.environ.get("Q_SPEAKER_THRESHOLD", "0.70"))
MARGIN = float(os.environ.get("Q_SPEAKER_MARGIN", "0.06"))
COHORT_MARGIN = float(os.environ.get("Q_SPEAKER_COHORT_MARGIN", "0.25"))
SHORT_SECONDS = 3.0        # below this a match needs SHORT_THRESHOLD
SHORT_THRESHOLD = float(os.environ.get("Q_SPEAKER_SHORT_THRESHOLD", "0.78"))
MIN_SNR_DB = float(os.environ.get("Q_SPEAKER_MIN_SNR", "15"))
MIN_SECONDS = 0.8          # shorter clips are too thin to judge
WINDOW_SECONDS = 1.5       # per-window labelling, for who-spoke-when
HOP_SECONDS = 0.75

_lock = threading.Lock()
_extractor = None


def extractor():
    global _extractor
    if _extractor is None:
        cfg = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=MODEL, num_threads=2)
        _extractor = sherpa_onnx.SpeakerEmbeddingExtractor(cfg)
    return _extractor


def load_profiles():
    try:
        with open(PROFILES) as f:
            return {k: [np.array(v, dtype=np.float32) for v in vs] for k, vs in json.load(f).items()}
    except Exception:
        return {}


def save_profiles(profiles):
    os.makedirs(SHARE, exist_ok=True)
    tmp = PROFILES + ".tmp"
    with open(tmp, "w") as f:
        json.dump({k: [v.tolist() for v in vs] for k, vs in profiles.items()}, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, PROFILES)


def read_wav(raw):
    """wav bytes -> (float32 samples in [-1, 1], sample rate). Mono, 16-bit only."""
    with wave.open(io.BytesIO(raw)) as w:
        rate, width, channels = w.getframerate(), w.getsampwidth(), w.getnchannels()
        frames = w.readframes(w.getnframes())
    if width != 2:
        raise ValueError("expected 16-bit audio")
    samples = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)
    if rate != 16000:  # the model is fixed at 16 kHz
        n = int(round(len(samples) * 16000 / rate))
        samples = np.interp(np.linspace(0, len(samples) - 1, n), np.arange(len(samples)), samples).astype(np.float32)
        rate = 16000
    return samples, rate


def embed(samples, rate=16000):
    """One L2-normalised embedding for a stretch of audio."""
    stream = extractor().create_stream()
    stream.accept_waveform(sample_rate=rate, waveform=samples)
    stream.input_finished()
    vec = np.array(extractor().compute(stream), dtype=np.float32)
    norm = np.linalg.norm(vec)
    return vec / norm if norm else vec


_cohort = None


def cohort():
    """-> (mean, voices) from cohort.npz, or (None, None) when it has not been built."""
    global _cohort
    if _cohort is None:
        try:
            z = np.load(COHORT)
            _cohort = (z["mean"].astype(np.float32), z["voices"].astype(np.float32))
        except Exception:
            _cohort = (None, None)
    return _cohort


def centre(v):
    mean = cohort()[0]
    if mean is None:
        return v
    v = v - mean
    return v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-9)


def cohort_score(vec, k=5):
    """Mean of the k closest cohort voices to an already-centred vector (0 without a cohort)."""
    voices = cohort()[1]
    if voices is None:
        return 0.0
    return float(np.mean(np.sort(voices @ vec)[-k:]))


def snr_db(samples, rate=16000):
    """Rough loud-frame vs quiet-frame energy spread; low means the noise is as loud as the speech."""
    n = rate // 50
    fr = samples[:len(samples) // n * n].reshape(-1, n)
    e = 10 * np.log10((fr ** 2).mean(axis=1) + 1e-10)
    return float(np.percentile(e, 95) - np.percentile(e, 10))


def best_match(vec, profiles):
    """-> (name, score, ranked [(name, score)]). Each profile scores as the better of its
    average voice and its closest single clip, so one odd recording can't sink it."""
    ranked = []
    vec = centre(vec)
    for name, vecs in profiles.items():
        if not vecs:
            continue
        stack = centre(np.vstack(vecs))
        mean = stack.mean(axis=0)
        mean /= np.linalg.norm(mean) or 1.0
        ranked.append((name, max(float(mean @ vec), float(np.max(stack @ vec)))))
    ranked.sort(key=lambda kv: kv[1], reverse=True)
    if not ranked:
        return None, 0.0, ranked
    return ranked[0][0], ranked[0][1], ranked


def label(vec, profiles):
    """-> (speaker, score, candidates). 'guest' once somebody is enrolled but nobody fits."""
    name, score, ranked = best_match(vec, profiles)
    if name is None:
        return "unknown", 0.0, []
    if score < THRESHOLD or score - cohort_score(centre(vec)) < COHORT_MARGIN:
        return "guest", score, []
    close = [n for n, s in ranked if s >= THRESHOLD and ranked[0][1] - s <= MARGIN]
    if len(close) > 1:
        return "unsure", score, close
    return name, score, []


def windows(samples, rate):
    """Label overlapping windows, then merge neighbours that agree -> who spoke when."""
    win, hop = int(WINDOW_SECONDS * rate), int(HOP_SECONDS * rate)
    if len(samples) < win:
        return []
    out = []
    for start in range(0, len(samples) - win + 1, hop):
        out.append((start / rate, (start + win) / rate, samples[start:start + win]))
    return out


def log_decision(res, device):
    """One line per identify call, so `q_voice.py speaker-status` can show recent accepts and refusals."""
    line = {"ts": int(time.time()), "device": device[:24], "speaker": res["speaker"], "score": res["score"],
            "seconds": res.get("seconds", 0), "repeat": res.get("repeat", False)}
    try:
        with open(os.open(DECISIONS, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600), "a") as f:
            f.write(json.dumps(line) + "\n")
        if os.path.getsize(DECISIONS) > 200_000:
            with open(DECISIONS) as f:
                keep = f.readlines()[-500:]
            with open(DECISIONS, "w") as f:
                f.writelines(keep)
    except OSError:
        pass


def identify(raw, device=""):
    res = _identify(raw)
    log_decision(res, device)
    return res


def _identify(raw):
    samples, rate = read_wav(raw)
    seconds = round(len(samples) / rate, 2)
    if len(samples) < MIN_SECONDS * rate:
        return {"speaker": "unknown", "score": 0.0, "speakers": [], "shift": False, "segments": [],
                "seconds": seconds, "repeat": True}

    with _lock:
        profiles = load_profiles()
        whole, score, candidates = label(embed(samples, rate), profiles)

        segments = []
        for start, end, chunk in windows(samples, rate):
            who, sc, _ = label(embed(chunk, rate), profiles)
            if segments and segments[-1]["speaker"] == who:
                segments[-1]["end"] = end
                segments[-1]["score"] = max(segments[-1]["score"], round(sc, 3))
            else:
                segments.append({"speaker": who, "score": round(sc, 3), "start": round(start, 2), "end": round(end, 2)})

    # Ignore blips: a single short window disagreeing with its neighbours is
    # usually a breath or an overlap, not a second person in the room.
    segments = [s for s in segments if s["end"] - s["start"] >= WINDOW_SECONDS or len(segments) == 1]
    present = list(dict.fromkeys(s["speaker"] for s in segments if s["speaker"] not in ("unknown",)))
    shift = len(present) > 1
    # A match on a short or noisy clip is too soft to act on: fail closed, ask again.
    repeat = False
    if whole in profiles and (snr_db(samples, rate) < MIN_SNR_DB
                              or (seconds < SHORT_SECONDS and score < SHORT_THRESHOLD)):
        whole, candidates, repeat = "unsure", [whole], True
    return {
        "seconds": seconds,
        "repeat": repeat,
        "speaker": whole,
        "score": round(score, 3),
        "speakers": present or ([whole] if whole != "unknown" else []),
        "shift": shift,
        "segments": segments if shift else [],
        "candidates": candidates,
    }


def load_meta():
    try:
        with open(META) as f:
            return json.load(f)
    except Exception:
        return {}


def save_meta(meta):
    tmp = META + ".tmp"
    with open(tmp, "w") as f:
        json.dump(meta, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, META)


def enroll(name, raw, device=""):
    samples, rate = read_wav(raw)
    if len(samples) < MIN_SECONDS * rate:
        raise ValueError("clip too short to enrol")
    with _lock:
        profiles = load_profiles()
        profiles.setdefault(name, []).append(embed(samples, rate))
        save_profiles(profiles)
        meta = load_meta()
        rows = meta.setdefault(name, [])
        rows += [{"device": "unknown", "ts": 0}] * (len(profiles[name]) - 1 - len(rows))
        rows.append({"device": (device or "unknown")[:24], "ts": int(time.time())})
        save_meta(meta)
        return {"ok": True, "name": name, "clips": len(profiles[name])}


def speakers_summary():
    profiles, meta = load_profiles(), load_meta()
    out = {}
    for name, vs in profiles.items():
        devices = {}
        for i in range(len(vs)):
            d = (meta.get(name) or [])[i]["device"] if i < len(meta.get(name) or []) else "unknown"
            devices[d] = devices.get(d, 0) + 1
        out[name] = {"clips": len(vs), "devices": devices}
    return out


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # the unit's journal entry per request is noise
        pass

    def _send(self, code, body):
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", 0)))

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/decisions":
            n = max(1, min(200, int((parse_qs(url.query).get("n") or ["20"])[0] or 20)))
            try:
                with open(DECISIONS) as f:
                    rows = [json.loads(x) for x in f.readlines()[-n:]]
            except (OSError, ValueError):
                rows = []
            return self._send(200, rows)
        if url.path != "/speakers":
            return self._send(404, {"error": "not found"})
        with _lock:
            summary = speakers_summary()
        self._send(200, summary)

    def do_DELETE(self):
        url = urlparse(self.path)
        if url.path != "/speakers":
            return self._send(404, {"error": "not found"})
        name = (parse_qs(url.query).get("name") or [""])[0]
        with _lock:
            profiles = load_profiles()
            existed = profiles.pop(name, None) is not None
            save_profiles(profiles)
            meta = load_meta()
            if meta.pop(name, None) is not None:
                save_meta(meta)
        self._send(200, {"ok": existed, "name": name})

    def do_POST(self):
        url = urlparse(self.path)
        try:
            q = parse_qs(url.query)
            device = (q.get("device") or [""])[0].strip().lower()
            if url.path == "/identify":
                return self._send(200, identify(self._body(), device))
            if url.path == "/enroll":
                name = (q.get("name") or [""])[0].strip().lower()
                if not name:
                    return self._send(400, {"error": "name required"})
                return self._send(200, enroll(name, self._body(), device))
        except Exception as exc:
            return self._send(400, {"error": str(exc) or exc.__class__.__name__})
        self._send(404, {"error": "not found"})


def main():
    if not os.path.exists(MODEL):
        sys.exit(f"speaker model missing: {MODEL}")
    extractor()  # fail loudly at start-up rather than on the first turn
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"q-speaker on http://{HOST}:{PORT} (model {os.path.basename(MODEL)})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
