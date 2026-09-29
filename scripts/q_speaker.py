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

# Cosine similarity over WeSpeaker embeddings. 0.55 is the usual same-speaker
# line for this model; MARGIN keeps apart two profiles that both fit, so the
# assistant is told "unsure" rather than confidently picking the wrong person.
THRESHOLD = float(os.environ.get("Q_SPEAKER_THRESHOLD", "0.55"))
MARGIN = float(os.environ.get("Q_SPEAKER_MARGIN", "0.06"))
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


def best_match(vec, profiles):
    """-> (name, score, ranked [(name, score)]). Each profile scores as the better of its
    average voice and its closest single clip, so one odd recording can't sink it."""
    ranked = []
    for name, vecs in profiles.items():
        if not vecs:
            continue
        stack = np.vstack(vecs)
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
    if score < THRESHOLD:
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


def identify(raw):
    samples, rate = read_wav(raw)
    if len(samples) < MIN_SECONDS * rate:
        return {"speaker": "unknown", "score": 0.0, "speakers": [], "shift": False, "segments": []}

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
    return {
        "speaker": whole,
        "score": round(score, 3),
        "speakers": present or ([whole] if whole != "unknown" else []),
        "shift": shift,
        "segments": segments if shift else [],
        "candidates": candidates,
    }


def enroll(name, raw):
    samples, rate = read_wav(raw)
    if len(samples) < MIN_SECONDS * rate:
        raise ValueError("clip too short to enrol")
    with _lock:
        profiles = load_profiles()
        profiles.setdefault(name, []).append(embed(samples, rate))
        save_profiles(profiles)
        return {"ok": True, "name": name, "clips": len(profiles[name])}


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
        if urlparse(self.path).path != "/speakers":
            return self._send(404, {"error": "not found"})
        with _lock:
            profiles = load_profiles()
        self._send(200, {name: {"clips": len(vs)} for name, vs in profiles.items()})

    def do_DELETE(self):
        url = urlparse(self.path)
        if url.path != "/speakers":
            return self._send(404, {"error": "not found"})
        name = (parse_qs(url.query).get("name") or [""])[0]
        with _lock:
            profiles = load_profiles()
            existed = profiles.pop(name, None) is not None
            save_profiles(profiles)
        self._send(200, {"ok": existed, "name": name})

    def do_POST(self):
        url = urlparse(self.path)
        try:
            if url.path == "/identify":
                return self._send(200, identify(self._body()))
            if url.path == "/enroll":
                name = (parse_qs(url.query).get("name") or [""])[0].strip().lower()
                if not name:
                    return self._send(400, {"error": "name required"})
                return self._send(200, enroll(name, self._body()))
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
