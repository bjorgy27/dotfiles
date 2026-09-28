#!/usr/bin/env python3
"""q_voice.py - streaming voice engine behind q_voice.sh (Hyprland SUPER+T).

Everything overlaps so first audio lands ~1s after you stop talking:

  mic  --pw-record--> Silero VAD (auto end-of-speech) --> whisper-server (local)
       --> q-speaker /identify, in parallel (Q_SPEAKER_URL: who is talking, shared with other clients)
       --> gateway /v1/chat/completions  stream:true  (SSE deltas)
       --> sentence splitter --> TTS per sentence, run-ahead
             elevenlabs : direct streaming PCM (Q_ELEVENLABS_API_KEY + Q_ELEVENLABS_VOICE)
             gateway    : `openclaw gateway call tts.speak` over SSH (Q_GATEWAY_SSH; key stays there)
             piper      : local, always works
       --> one pw-play process fed raw s16 mono 24 kHz

Everything device-specific comes from the environment, loaded by q_voice.sh from
~/.config/q-voice/env (see q_voice.env.example next to this file); nothing in
here names a machine. `q_voice.sh setup` creates the venv this runs in.

Commands:
  turn --listen [--converse]   record with VAD, then answer; converse = keep listening after replying
  turn --text "..."            skip the mic
  turn --wav file.wav          transcribe a file, then answer
  say "..."                    TTS only
  enroll [name] [--last N]     teach the shared speaker service a voice from the last N clips (no name = list)

Who is talking: with Q_SPEAKER_URL set, every turn is matched against the enrolled profiles on q-speaker
(the service can be shared with other clients, so enrolling once is enough for all of them). The model is told
who it is, a turn where two people speak comes through as "Alex: ... Sam: ...", and an unrecognized voice is
handled as a guest. Who the profiles are is local, in ~/.config/q-voice/speakers.json (Q_SPEAKERS):
  {"owner": "alex", "household": ["alex", "sam"],
   "people": {"alex": "Alex", "sam": "Sam, Alex's roommate", "jo": "Jo, a friend who visits (...how to treat them)"}}
Each person is "Short name, how the model hears about them"; the text before the first comma is the display name. The last Q_KEEP_CLIPS turns are kept in ~/.local/state/q-voice/clips for `enroll`.
What machine this is: Q_DEVICE plus Q_DEVICE_NOTE (a line of room/setup context) go in the same prefix.

Signals (sent by q_voice.sh):
  SIGUSR1  toggle pressed: listening -> send now; thinking/speaking -> interrupt and listen again
  SIGTERM  cancel: stop everything, go idle

State for the Quickshell bar: $XDG_RUNTIME_DIR/q-voice/state.json
  {state: idle|listening|transcribing|thinking|speaking|error, text, reply, ts,
   speaker: "" | "Alex" | "Guest" | "Alex/Sam" (too close to call), speakers: [everyone heard in the turn]}
"""
import argparse
import base64
import collections
import glob
import io
import json
import os
import queue
import re
import shlex
import signal
import socket
import subprocess
import sys
import threading
import concurrent.futures
import time
import wave

import numpy as np
import requests

# ---------------------------------------------------------------- config (env)
E = os.environ.get
HOME = os.path.expanduser("~")
RUN = os.path.join(E("XDG_RUNTIME_DIR", "/tmp"), "q-voice")
STATE_DIR = os.path.join(HOME, ".local/state/q-voice")
SHARE = os.path.join(HOME, ".local/share/q-voice")
STATEF = os.path.join(RUN, "state.json")
LOGF = os.path.join(STATE_DIR, "conversation.log")
NID = "4242"

NAME = E("Q_NAME", "Q")                       # how the assistant is addressed in notifications and the log
DEVICE = E("Q_DEVICE", socket.gethostname())     # how this machine introduces itself to the agent
DEVICE_NOTE = E("Q_DEVICE_NOTE", "")             # one line of context about this machine/room for the agent
SPEAKER_URL = E("Q_SPEAKER_URL", "")             # q-speaker /identify (can be shared); empty = no speaker id
SPEAKERS_FILE = E("Q_SPEAKERS", os.path.join(HOME, ".config/q-voice/speakers.json"))  # who the profiles are
KEEP_CLIPS = int(E("Q_KEEP_CLIPS", "40"))        # turns of audio kept for after-the-fact enrollment
CLIPS_DIR = os.path.join(STATE_DIR, "clips")
GATEWAY_URL = E("Q_GATEWAY_URL", "")
GATEWAY_TOKEN = E("Q_GATEWAY_TOKEN", "")
AGENT = E("Q_AGENT", "main")
USER = E("Q_USER", f"{DEVICE}-voice")
MODEL = E("Q_MODEL", "")                          # empty = the gateway's default model
BRIEF = E("Q_BRIEF", "1") == "1"
WHISPER_URL = E("Q_WHISPER_URL", "http://127.0.0.1:8178/inference")
WHISPER_MODEL = E("Q_WHISPER_MODEL", f"{HOME}/.local/share/whisper/ggml-base.en.bin")
TTS = E("Q_TTS", "auto")  # auto | elevenlabs | gateway | piper
EL_KEY = E("Q_ELEVENLABS_API_KEY") or E("ELEVENLABS_API_KEY") or ""
EL_VOICE = E("Q_ELEVENLABS_VOICE", "N2lVS1w4EtoT3dr4eOWO")  # Callum: the Q voice (stock ElevenLabs voice)
EL_MODEL = E("Q_ELEVENLABS_MODEL", "eleven_v3")
EL_V3 = EL_MODEL.startswith("eleven_v3")         # v3: audio tags, no previous/next_text, no optimize_streaming_latency
# v3 stability is a 3-way switch (0.0 creative / 0.5 natural / 1.0 robust); natural keeps tags responsive without
# creative's hallucinations and ~3x slower first byte
EL_SETTINGS = {"stability": float(E("Q_ELEVENLABS_STABILITY", "0.5" if EL_V3 else "0.45")), "similarity_boost": 0.8,
               "style": 0.3, "use_speaker_boost": True, "speed": float(E("Q_ELEVENLABS_SPEED", "0.95"))}
SSH_HOST = E("Q_GATEWAY_SSH", "")                 # ssh host running openclaw; required for the gateway TTS relay
GATEWAY_CLI = E("Q_GATEWAY_CLI", "openclaw")      # openclaw binary on that host
PIPER_VOICE = E("Q_PIPER_VOICE", f"{HOME}/.local/share/piper/en_US-lessac-medium.onnx")
PIPER_BIN = E("Q_PIPER_BIN", f"{HOME}/.local/bin/piper")
VAD_MODEL = E("Q_VAD_MODEL", f"{SHARE}/silero_vad.onnx")
VAD_SILENCE_MS = int(E("Q_VAD_SILENCE_MS", "700"))  # trailing silence that ends your turn
VAD_START_TIMEOUT_S = float(E("Q_VAD_START_TIMEOUT_S", "20"))  # first press: wait this long for speech
CONVERSE_TIMEOUT_S = float(E("Q_CONVERSE_TIMEOUT_S", "8"))  # after replying: wait this long for a follow-up
MAX_RECORD_S = float(E("Q_MAX_RECORD_S", "45"))
PAUSE_MEDIA = E("Q_PAUSE_MEDIA", "1") == "1"
SPEAK_MAX_CHARS = int(E("Q_SPEAK_MAX_CHARS", "1200"))
MUTE = E("Q_MUTE", "0") == "1"
DEBUG = E("Q_DEBUG", "0") == "1"

PCM_RATE = 24000  # everything is resampled to s16 mono 24k for the single player
SR = 16000        # mic / whisper / VAD rate

os.makedirs(RUN, exist_ok=True)
os.makedirs(STATE_DIR, exist_ok=True)
os.makedirs(CLIPS_DIR, exist_ok=True)
SESSION = requests.Session()      # whisper + gateway
TTS_SESSION = requests.Session()  # elevenlabs (separate pool; used from the TTS thread)

# ---------------------------------------------------------------- small utils
def log(msg):
    with open(LOGF, "a") as f:
        f.write(f"{time.strftime('%F %T')}  {msg}\n")


def dbg(msg):
    if DEBUG:
        print(f"[{time.time():.3f}] {msg}", file=sys.stderr, flush=True)


def notify(title, icon=None, ms=4000, body=""):
    cmd = ["notify-send", "-r", NID, "-a", NAME, "-t", str(ms)]
    if icon:
        cmd += ["-i", icon]
    cmd += [title, body]
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


EVENTS = os.path.join(RUN, "events.jsonl")         # live feed for the Q chat panel
CHATF = os.path.join(STATE_DIR, "chat.jsonl")       # panel history (last 80 lines shown)
VIA = "voice"          # "text" for typed turns from the panel
QUIET = False          # typed turns: no speech, the reply is read on screen


def emit(ev):
    """Append one event for the chat panel. Best effort: a missing panel never breaks a turn."""
    try:
        os.makedirs(RUN, exist_ok=True)
        with open(EVENTS, "a") as f:
            f.write(json.dumps(dict(ev, ts=int(time.time() * 1000))) + "\n")
    except OSError:
        pass


def remember(role, text):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(CHATF, "a") as f:
            f.write(json.dumps({"role": role, "text": text, "ts": int(time.time())}) + "\n")
    except OSError:
        pass


_state_lock = threading.Lock()
_last_state = {}
_last_speaker = None    # the raw /identify result behind _last_state, so a state refresh can keep it


def set_state(state, text="", reply="", speaker=None):
    """`speaker` is the q-speaker result for the current turn; the bar shows who was recognized (None = unknown)."""
    global _last_state, _last_speaker
    with _state_lock:
        _last_speaker = speaker
        d = {"state": state, "text": text, "reply": reply, "ts": int(time.time()),
             "speaker": SHORT_NAMES.get(speaker["speaker"], speaker["speaker"].title()) if speaker else "",
             "speakers": [SHORT_NAMES.get(s, s.title()) for s in speaker.get("speakers", [])] if speaker else []}
        _last_state = d
        tmp = STATEF + ".tmp"
        with open(tmp, "w") as f:
            json.dump(d, f)
        os.replace(tmp, STATEF)
    emit({"type": "state", "state": state})


_media_paused = False


def pause_media():
    global _media_paused
    if not PAUSE_MEDIA or _media_paused:
        return
    try:
        out = subprocess.run(["playerctl", "status"], capture_output=True, text=True, timeout=2).stdout
        if "Playing" in out:
            subprocess.run(["playerctl", "pause"], timeout=2)
            _media_paused = True
    except Exception:
        pass


def resume_media():
    global _media_paused
    if _media_paused:
        subprocess.run(["playerctl", "play"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
        _media_paused = False


_MD = [
    (re.compile(r"```.*?```", re.S), " "),
    (re.compile(r"`([^`]*)`"), r"\1"),
    (re.compile(r"\[([^\]]*)\]\([^)]*\)"), r"\1"),
    (re.compile(r"https?://\S+"), " link "),
    (re.compile(r"\*\*|__|~~"), ""),
    (re.compile(r"^\s*#+\s*", re.M), ""),
    (re.compile(r"^\s*[-*]\s+", re.M), ""),
    (re.compile(r"[ \t]+"), " "),
]


def clean_text(s):
    for rx, rep in _MD:
        s = rx.sub(rep, s)
    return s.strip()


# ElevenLabs v3 audio tags ([chuckles], [sighs], [short pause] ...) are for the TTS only: stripped from the bar
# indicator, notifications and the log, and from text sent to non-v3 backends (which would read them out loud).
_TAG = re.compile(r"\[[a-z][a-z' -]{1,30}\]")


def strip_tags(s):
    return re.sub(r" {2,}", " ", _TAG.sub("", s)).strip()


# ---------------------------------------------------------------- signals
class Ctl:
    """Shared control flags. toggle = SUGUSR1 seen; cancel = SIGTERM seen."""
    toggle = threading.Event()
    cancel = threading.Event()


def _on_usr1(_sig, _frm):
    Ctl.toggle.set()


def _on_term(_sig, _frm):
    Ctl.cancel.set()
    Ctl.toggle.set()  # wake anything waiting on toggle too


signal.signal(signal.SIGUSR1, _on_usr1)
signal.signal(signal.SIGTERM, _on_term)
signal.signal(signal.SIGINT, _on_term)


# ---------------------------------------------------------------- VAD listen
class Vad:
    def __init__(self, path):
        import onnxruntime as ort
        so = ort.SessionOptions()
        so.intra_op_num_threads = 1
        so.inter_op_num_threads = 1
        self.s = ort.InferenceSession(path, so, providers=["CPUExecutionProvider"])
        self.reset()

    def reset(self):
        self.state = np.zeros((2, 1, 128), dtype=np.float32)
        self.ctx = np.zeros((1, 64), dtype=np.float32)
        self.sr = np.array(SR, dtype=np.int64)

    def prob(self, frame_i16):  # 512 samples
        x = (frame_i16.astype(np.float32) / 32768.0)[None, :]
        inp = np.concatenate([self.ctx, x], axis=1)
        out, self.state = self.s.run(None, {"input": inp, "state": self.state, "sr": self.sr})
        self.ctx = x[:, -64:]
        return float(out[0][0])


_VAD = [None, False]


def get_vad():
    if not _VAD[1]:
        _VAD[1] = True
        try:
            _VAD[0] = Vad(VAD_MODEL)
        except Exception as e:  # noqa
            dbg(f"VAD unavailable ({e}); press-to-send only")
    elif _VAD[0] is not None:
        _VAD[0].reset()
    return _VAD[0]


def _readn(f, n):
    buf = b""
    while len(buf) < n:
        b = f.read(n - len(buf))
        if not b:
            break
        buf += b
    return buf


def listen(start_timeout, hint):
    """Record the mic until end-of-speech (VAD), a toggle press, or timeout.
    Returns wav bytes (16k mono s16) or None (nothing said / cancelled / toggle before any speech)."""
    frame = 512  # 32 ms at 16k
    silence_frames = max(1, VAD_SILENCE_MS // 32)
    preroll = collections.deque(maxlen=12)  # ~380 ms before speech start
    vad = get_vad()
    Ctl.toggle.clear()
    rec = subprocess.Popen(
        ["pw-record", "--rate", str(SR), "--channels", "1", "--format", "s16", "--raw", "--latency", "20ms", "-"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0,
    )
    set_state("listening")
    notify("Listening…", "audio-input-microphone", 0, hint)
    frames, everything = [], []
    started = False
    quiet = 0
    voiced_run = 0
    t0 = time.time()
    reason = "timeout"
    try:
        while True:
            if Ctl.cancel.is_set():
                reason = "cancel"
                break
            if Ctl.toggle.is_set():
                reason = "toggle"
                break
            now = time.time()
            if not started and now - t0 > start_timeout:
                reason = "timeout"
                break
            if now - t0 > MAX_RECORD_S:
                reason = "max"
                break
            buf = _readn(rec.stdout, frame * 2)
            if len(buf) < frame * 2:
                reason = "eof"
                break
            everything.append(buf)
            samples = np.frombuffer(buf, dtype=np.int16)
            if vad is None:
                continue
            p = vad.prob(samples)
            if not started:
                preroll.append(buf)
                voiced_run = voiced_run + 1 if p > 0.5 else 0
                if voiced_run >= 3:  # ~100 ms of speech
                    started = True
                    frames.extend(preroll)
                    quiet = 0
                    dbg("speech start")
            else:
                frames.append(buf)
                if p < 0.35:
                    quiet += 1
                    if quiet >= silence_frames:
                        reason = "vad"
                        break
                else:
                    quiet = 0
    finally:
        try:
            rec.send_signal(signal.SIGINT)
            rec.wait(timeout=1)
        except Exception:
            rec.kill()
    dbg(f"listen end: {reason}, started={started}, {len(everything) * 32} ms")
    if reason in ("cancel",):
        return None
    if reason == "timeout":
        return None
    if not started:
        # No VAD: the press is the send button. With VAD: a press before any speech means "stop listening".
        if vad is None and reason in ("toggle", "max") and len(everything) * 32 >= 500:
            frames = everything
        else:
            return None
    pcm = b"".join(frames)
    if len(pcm) < SR * 2 * 0.3:
        return None
    bio = io.BytesIO()
    with wave.open(bio, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm)
    return bio.getvalue()


# ---------------------------------------------------------------- STT
def transcribe(wav_bytes):
    txt = ""
    try:
        r = SESSION.post(WHISPER_URL, files={"file": ("rec.wav", wav_bytes, "audio/wav")},
                         data={"temperature": "0", "response_format": "text"}, timeout=60)
        if r.ok:
            txt = r.text
    except Exception as e:  # noqa
        dbg(f"whisper-server failed: {e}")
    if not txt.strip():
        p = os.path.join(RUN, "rec.wav")
        with open(p, "wb") as f:
            f.write(wav_bytes)
        try:
            txt = subprocess.run(["whisper-cli", "-m", WHISPER_MODEL, "-f", p, "-np", "-nt"],
                                 capture_output=True, text=True, timeout=60).stdout
        except Exception:
            txt = ""
    txt = re.sub(r"\[[^\]]*\]|\([^)]*\)", "", txt.replace("\n", " "))
    return re.sub(r"\s+", " ", txt).strip()


# ---------------------------------------------------------------- who is talking
# Same q-speaker service other clients can use (Q_SPEAKER_URL), so a voice enrolled anywhere is known
# everywhere. Who the profiles are lives outside the repo in SPEAKERS_FILE (see the docstring at the top).
def _load_speakers():
    try:
        with open(SPEAKERS_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


_SPK = _load_speakers()
SPEAKER_NAMES = _SPK.get("people", {})               # profile name -> how the model hears about them
OWNER = _SPK.get("owner", "")                        # whose machine this is
HOUSEHOLD = _SPK.get("household") or ([OWNER] if OWNER else [])
SHORT_NAMES = {k: v.split(",")[0].strip() for k, v in SPEAKER_NAMES.items()}
SHORT_NAMES.update(guest="Guest", unsure="/".join(SHORT_NAMES.get(n, n.title()) for n in HOUSEHOLD) or "Unsure")
OWNER_NAME = SHORT_NAMES.get(OWNER, OWNER.title()) if OWNER else ""
OWNERS = f"{OWNER_NAME}'s" if OWNER_NAME else "the owner's"
OWNER_BEHALF = f"on {OWNER_NAME}'s behalf" if OWNER_NAME else "on the owner's behalf"


def identify_speaker(wav_bytes):
    """Ask q-speaker who is talking. None if speaker id is off, the service is down, or the clip is too short."""
    if not SPEAKER_URL:
        return None
    try:
        r = SESSION.post(SPEAKER_URL, data=wav_bytes, headers={"Content-Type": "audio/wav"}, timeout=12)
        if not r.ok:
            dbg(f"speaker http {r.status_code}: {r.text[:200]}")
            return None
        res = r.json()
        return res if res.get("speaker") not in (None, "unknown") else None
    except Exception as e:  # noqa
        dbg(f"speaker id failed: {e}")
        return None


def wav_slice(wav_bytes, start_s, end_s):
    """Cut [start, end] seconds out of a 16 kHz mono s16 wav -> wav bytes."""
    with wave.open(io.BytesIO(wav_bytes)) as w:
        rate = w.getframerate()
        w.setpos(min(w.getnframes(), int(start_s * rate)))
        raw = w.readframes(max(0, int((end_s - start_s) * rate)))
    bio = io.BytesIO()
    with wave.open(bio, "wb") as o:
        o.setnchannels(1)
        o.setsampwidth(2)
        o.setframerate(rate)
        o.writeframes(raw)
    return bio.getvalue()


def transcribe_segments(wav_bytes, segments):
    """Who said what, exactly: transcribe each labeled speaker segment on its own (one whisper call per run of the
    same speaker, so only multi-speaker turns pay for it). -> [{"speaker", "text"}] in order, empty runs dropped."""
    turns = []
    for sg in segments:
        try:
            piece = wav_slice(wav_bytes, max(0.0, sg["start"] - 0.15), sg["end"] + 0.15)
        except Exception as e:  # noqa
            dbg(f"wav_slice failed: {e}")
            continue
        t = transcribe(piece) if len(piece) > 44 + SR else ""   # skip < 0.5 s slivers
        if t:
            turns.append({"speaker": sg["speaker"], "text": t})
    return turns


def label_turns(wav_bytes, speaker, text):
    """-> (text, turns). On a mid-turn speaker change the text the model sees becomes 'Alex: ... Sam: ...'."""
    turns = None
    if speaker.get("shift") and len(speaker.get("speakers", [])) > 1:
        turns = transcribe_segments(wav_bytes, speaker.get("segments", [])) or None
        if turns:
            text = " ".join(f"{SHORT_NAMES.get(t['speaker'], t['speaker'].title())}: {t['text']}" for t in turns)
    if not turns:
        turns = [{"speaker": speaker["speaker"], "text": text}]
    for tn in turns:                      # too-close-to-call match shows as "Alex/Sam"
        if tn["speaker"] == "unsure":
            tn["speaker"] = "/".join(speaker.get("candidates") or HOUSEHOLD or ["unsure"])
    return text, turns


def save_clip(wav_bytes):
    """Keep the last KEEP_CLIPS turns' audio so a turn can be enrolled after the fact ('that was Sam')."""
    try:
        p = os.path.join(CLIPS_DIR, time.strftime("%Y%m%d-%H%M%S") + ".wav")
        with open(p, "wb") as f:
            f.write(wav_bytes)
        for q in sorted(glob.glob(os.path.join(CLIPS_DIR, "*.wav")))[:-KEEP_CLIPS]:
            os.remove(q)
        return p
    except Exception as e:  # noqa
        dbg(f"save_clip failed: {e}")
        return None


def speaker_note(spk):
    """Prompt fragment telling the model who is talking."""
    if not spk:
        return ""
    who = spk.get("speaker")
    if who == "unsure":
        c = [SPEAKER_NAMES.get(n, n).split(",")[0] for n in spk.get("candidates") or HOUSEHOLD] or ["one of them"]
        return (f"the person talking is someone from the household, {' or '.join(c)}, but the voice match is too "
                f"close to call; don't guess a name out loud, and don't act on anything that only one of them should "
                f"be able to do")
    if who == "guest":
        known = ", ".join("not " + SHORT_NAMES.get(n, n.title()) for n in HOUSEHOLD)
        return (f"the person talking is NOT a recognized voice{f' ({known})' if known else ''}: treat them as a guest "
                f"at {OWNERS} machine, be friendly and helpful with general questions, but don't share {OWNERS} "
                f"personal details, messages, accounts, files or schedule, and don't take actions {OWNER_BEHALF}")
    if spk.get("shift") and len(spk.get("speakers", [])) > 1:
        people = ["an unrecognized guest" if s == "guest" else SPEAKER_NAMES.get(s, s) for s in spk["speakers"]]
        return ("more than one person spoke during this one turn (" + ", ".join(people) + "); the transcript is "
                "marked with who said what; answer what was actually asked of you, usually by the last speaker, and "
                "if they were mostly talking to each other keep it to one short line; a guest gets friendly general "
                f"help but no personal details, messages, accounts, files or schedule, and no actions {OWNER_BEHALF}")
    return f"the person talking is {SPEAKER_NAMES.get(who, who)} (voice match {spk.get('score', 0):.2f})"


# ---------------------------------------------------------------- LLM (SSE)
def _read1(raw, n=4096):
    """Return bytes as soon as any are available (no waiting to fill n)."""
    if hasattr(raw, "read1"):
        return raw.read1(n)
    return raw.read(1)


def _abort(r):
    """Kill a streaming response from another thread: shut the socket so a blocked read wakes up.
    Client disconnect also cancels the agent run on the gateway."""
    try:
        import socket
        r.raw._connection.sock.shutdown(socket.SHUT_RDWR)
    except Exception:
        pass
    try:
        r.close()
    except Exception:
        pass


def stream_llm(text, on_delta, stop, holder, speaker=None):
    """POST to the gateway with stream:true; call on_delta(str) per chunk. Returns full text."""
    SPEAK = ("write everything as it should be spoken aloud: spell out units, abbreviations and symbols in full words "
             "(gigabytes not GB, percent not %, degrees Fahrenheit not F), and avoid file paths and code unless asked")
    # sound like a person, not a narrator, and with eleven_v3 direct the delivery with audio tags
    # Q speaks like Q: theatrical and dry, never a hesitant narrator
    NATURAL = ("this is spoken aloud in your own voice as Q: flowing, theatrical sentences with dry amusement, "
               "no filler words like um or uh, no lists, and the answer first")
    EXPRESS = ("your voice is rendered by a text to speech model that acts bracketed audio tags, so direct the delivery "
               "instead of just saying the words: put a tag right before the words it applies to, from `[chuckles]`, "
               "`[laughs]`, `[sighs]`, `[exhales]`, `[whispers]`, `[curious]`, `[excited]`, `[thoughtful]`, "
               "`[sarcastic]`, `[surprised]`, `[annoyed]`, `[short pause]`, `[clears throat]` or a similar short "
               "lowercase direction; use them where a real person would actually do that (a chuckle at something "
               "funny, a sigh before bad news, a thoughtful beat before a decision), one or two per reply, up to three "
               "when the moment calls for it, none when you're just confirming; a tag always starts a sentence or "
               "clause and never replaces words, since tags are stripped from the on-screen text; also use `...` for a "
               "hesitation and CAPITALS for one stressed word now and then; never put a tag inside a title")
    style = f"; {NATURAL}" + (f"; {EXPRESS}" if EL_V3 and tts_chain() and tts_chain()[0][0] == "elevenlabs" else "")
    where = f"voice, {DEVICE}" + (f" ({DEVICE_NOTE})" if DEVICE_NOTE else "")
    who = speaker_note(speaker)
    ctx = f"; {who}" if who else ""
    prefix = (f"[{where}; spoken reply: one to three short sentences unless I ask for detail, "
              f"no lists or markdown{ctx}; {SPEAK}{style}] " if BRIEF else f"[{where}{ctx}; {SPEAK}{style}] ")
    body = {"model": f"openclaw/{AGENT}", "user": USER, "stream": True,
            "messages": [{"role": "user", "content": prefix + text}]}
    headers = {"Authorization": f"Bearer {GATEWAY_TOKEN}", "Content-Type": "application/json",
               "Accept": "text/event-stream", "Accept-Encoding": "identity"}
    if MODEL:
        headers["x-openclaw-model"] = MODEL
    r = SESSION.post(f"{GATEWAY_URL}/v1/chat/completions", headers=headers, json=body, stream=True, timeout=(10, 240))
    if r.status_code != 200:
        raise RuntimeError(f"gateway http {r.status_code}: {r.text[:200]}")
    holder["resp"] = r
    full = []
    buf = b""
    try:
        while not stop.is_set():
            chunk = _read1(r.raw)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if not line.startswith(b"data:"):
                    continue
                data = line[5:].strip()
                if data == b"[DONE]":
                    return "".join(full)
                try:
                    obj = json.loads(data)
                except Exception:
                    continue
                if "error" in obj:
                    err = obj["error"]
                    raise RuntimeError(err.get("message", str(err)) if isinstance(err, dict) else str(err))
                for ch in obj.get("choices", []):
                    d = (ch.get("delta") or {}).get("content")
                    if d:
                        full.append(d)
                        on_delta(d)
    finally:
        r.close()
    return "".join(full)


# ---------------------------------------------------------------- sentence splitter
_END = re.compile(r'[.!?…]["”’)\]]*(\s+|$)')
_ABBR = re.compile(r"(?:\b[A-Z]|\b(?i:e\.g|i\.e|vs|etc|dr|mr|mrs|ms|st|approx))\.$")


class Splitter:
    """Feed streamed text; emit(sentence) as soon as a sentence boundary is seen."""

    def __init__(self, emit):
        self.buf = ""
        self.emit = emit
        self.first = True

    def feed(self, s):
        self.buf += s
        while True:
            m = None
            for cand in _END.finditer(self.buf):
                if cand.group(1) == "":
                    break  # punctuation at the very end of what we have: wait for more ("3." + "5")
                head = self.buf[:cand.start() + 1]
                if len(head.strip()) < 12 or _ABBR.search(head.rstrip()):
                    continue
                m = cand
                break
            if m is None:
                # paragraph break is always a boundary
                if "\n\n" in self.buf:
                    head, self.buf = self.buf.split("\n\n", 1)
                    self._out(head)
                    continue
                # first chunk: don't wait forever for a period on a long opening sentence
                if self.first and len(self.buf) > 220:
                    cut = max(self.buf.rfind(", ", 100), self.buf.rfind("; ", 100))
                    if cut > 0:
                        head, self.buf = self.buf[:cut + 1], self.buf[cut + 2:]
                        self._out(head)
                        continue
                return
            head, self.buf = self.buf[:m.end()], self.buf[m.end():]
            self._out(head)

    def flush(self):
        self._out(self.buf)
        self.buf = ""

    def _out(self, s):
        s = clean_text(s)
        if s:
            self.first = False
            self.emit(s)


# ---------------------------------------------------------------- TTS backends -> PCM s16 mono 24k
def _ffmpeg_to_pcm(in_fmt_args, data, stop):
    p = subprocess.Popen(["ffmpeg", "-loglevel", "error"] + in_fmt_args + ["-i", "-", "-f", "s16le",
                          "-ar", str(PCM_RATE), "-ac", "1", "-"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def feed():
        try:
            p.stdin.write(data)
            p.stdin.close()
        except Exception:
            pass

    threading.Thread(target=feed, daemon=True).start()
    while not stop.is_set():
        chunk = p.stdout.read(8192)
        if not chunk:
            break
        yield chunk
    p.stdout.close()
    p.wait(timeout=5)


def open_elevenlabs(text, prev, nxt):
    """Start one ElevenLabs request; returns the streaming response once headers are in (the TTFB wait)."""
    body = {"text": text if EL_V3 else strip_tags(text), "model_id": EL_MODEL, "voice_settings": EL_SETTINGS}
    params = {"output_format": f"pcm_{PCM_RATE}"}
    if not EL_V3:                                 # v3 models 400 on these (unsupported_model)
        params["optimize_streaming_latency"] = "3"
        if prev:
            body["previous_text"] = prev[-300:]
        if nxt:
            body["next_text"] = nxt[:300]
    r = TTS_SESSION.post(f"https://api.elevenlabs.io/v1/text-to-speech/{EL_VOICE}/stream", params=params,
                         headers={"xi-api-key": EL_KEY, "Accept-Encoding": "identity"}, json=body,
                         stream=True, timeout=(5, 30))
    if r.status_code != 200:
        err = r.text[:200]
        r.close()
        raise RuntimeError(f"elevenlabs http {r.status_code}: {err}")
    return r


def drain_elevenlabs(r, stop):
    """Yield PCM as ElevenLabs produces it."""
    try:
        while not stop.is_set():
            chunk = _read1(r.raw, 8192)
            if not chunk:
                break
            yield chunk
    finally:
        r.close()


def synth_elevenlabs(text, prev, nxt, stop):
    yield from drain_elevenlabs(open_elevenlabs(text, prev, nxt), stop)


def _close_el(fut):
    try:
        fut.result().close()
    except Exception:
        pass


def synth_gateway(text, prev, nxt, stop):
    params = json.dumps({"text": strip_tags(text)})
    out = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
                          "-o", "ControlMaster=auto", "-o", f"ControlPath={RUN}/ssh-%C", "-o", "ControlPersist=600",
                          SSH_HOST,
                          f"{GATEWAY_CLI} gateway call tts.speak --params {shlex.quote(params)} --json 2>/dev/null"],
                         capture_output=True, timeout=45)
    data = json.loads(out.stdout or b"{}")
    b64 = (data.get("payload") or data).get("audioBase64")
    if not b64:
        raise RuntimeError("gateway tts.speak returned no audio")
    yield from _ffmpeg_to_pcm([], base64.b64decode(b64), stop)


def synth_piper(text, prev, nxt, stop):
    p = subprocess.run([PIPER_BIN, "-m", PIPER_VOICE, "--output-raw"], input=strip_tags(text).encode(),
                       capture_output=True, timeout=60)
    if not p.stdout:
        raise RuntimeError("piper produced no audio")
    rate = "22050"
    try:
        with open(PIPER_VOICE + ".json") as f:
            rate = str(json.load(f)["audio"]["sample_rate"])
    except Exception:
        pass
    yield from _ffmpeg_to_pcm(["-f", "s16le", "-ar", rate, "-ac", "1"], p.stdout, stop)


def tts_chain():
    """Backends to try in order; a backend is only used when its config is present."""
    if QUIET:
        return []
    have = {"elevenlabs": bool(EL_KEY and EL_VOICE), "gateway": bool(SSH_HOST), "piper": True}
    fns = {"elevenlabs": synth_elevenlabs, "gateway": synth_gateway, "piper": synth_piper}
    order = [TTS, "piper"] if TTS in ("elevenlabs", "gateway") else ["piper"] if TTS == "piper" else ["elevenlabs", "gateway", "piper"]
    return [(name, fns[name]) for name in order if have[name]]


# ---------------------------------------------------------------- player
class Player:
    """One pw-play fed raw PCM. Started lazily on the first chunk."""

    def __init__(self):
        self.p = None
        self.lock = threading.Lock()
        self.first_audio_at = None
        self.bytes = 0

    def write(self, chunk):
        with self.lock:
            if self.p is None:
                if self.first_audio_at is None:
                    self.first_audio_at = time.time()
                if MUTE:
                    self.p = "mute"
                else:
                    self.p = subprocess.Popen(
                        ["pw-play", "--rate", str(PCM_RATE), "--channels", "1", "--format", "s16", "--raw",
                         "--latency", "60ms", "-"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL, bufsize=0)
            self.bytes += len(chunk)
        if self.p == "mute":
            time.sleep(len(chunk) / (PCM_RATE * 2))
            return
        try:
            self.p.stdin.write(chunk)
        except (BrokenPipeError, ValueError):
            pass

    def finish(self):
        """Close the stream and wait for playback to drain."""
        with self.lock:
            p = self.p
        if p is None or p == "mute":
            return
        try:
            p.stdin.close()
        except Exception:
            pass
        try:
            p.wait(timeout=120)
        except Exception:
            p.kill()

    def stop(self):
        with self.lock:
            p, self.p = self.p, None
        if p and p != "mute":
            try:
                p.kill()
            except Exception:
                pass


# ---------------------------------------------------------------- one turn
def run_turn(text, t_speech_end=None, speaker=None):
    """Stream the reply for `text` and speak it. Returns (reply, interrupted).
    `speaker` is a q-speaker /identify result (or None): it labels the log and tells the model who is talking."""
    stop = threading.Event()
    interrupted = threading.Event()
    sentences = []            # cleaned sentences in order (for TTS context)
    q = queue.Queue()  # indexes into `sentences`, in order
    player = Player()
    timing = {"speech_end": t_speech_end or time.time(), "stt_done": time.time()}
    reply_parts = []
    last_state_push = [0.0]
    spoken_chars = [0]
    backend_used = [None]
    llm_err = [None]
    holder = {}

    set_state("thinking", text, speaker=speaker)
    emit({"type": "transcript", "text": text, "via": VIA})
    remember("user", text)
    notify("Thinking…", "system-search", 0, text)
    if speaker and speaker.get("shift"):
        tag = " (" + " -> ".join(f"{s['speaker']} {s['score']:.2f}" for s in speaker.get("segments", [])) + ")"
    else:
        tag = f" ({speaker['speaker']} {speaker.get('score', 0):.2f})" if speaker else ""
    log(f"YOU{tag}: {text}")

    def push_state(force=False):
        now = time.time()
        if force or now - last_state_push[0] > 0.3:
            last_state_push[0] = now
            set_state("speaking" if player.first_audio_at else "thinking", text,
                      strip_tags(clean_text("".join(reply_parts))), speaker)

    def on_sentence(s):
        if spoken_chars[0] == 0:
            timing.setdefault("first_sentence", time.time())
        if spoken_chars[0] < SPEAK_MAX_CHARS:
            spoken_chars[0] += len(s)
            sentences.append(s)
            q.put(len(sentences) - 1)
        elif spoken_chars[0] < SPEAK_MAX_CHARS + 1:
            spoken_chars[0] += 1
            sentences.append("That's the short version, the rest is in the log.")
            q.put(len(sentences) - 1)

    splitter = Splitter(on_sentence)

    def on_delta(d):
        if "ttft" not in timing:
            timing["ttft"] = time.time()
        reply_parts.append(d)
        emit({"type": "delta", "text": d})
        splitter.feed(d)
        push_state()

    def llm_thread():
        try:
            stream_llm(text, on_delta, stop, holder, speaker)
            if not stop.is_set():
                splitter.flush()
        except Exception as e:  # noqa
            if stop.is_set():                   # interrupted: the aborted socket raises; that's not an error
                dbg(f"llm stream aborted by interrupt ({e})")
            else:
                llm_err[0] = str(e)
                dbg(f"llm error: {e}")
        finally:
            q.put(None)

    def tts_thread():
        chain = tts_chain()
        ahead = {}                              # sentence index -> Future(open_elevenlabs), opened while the previous one streams
        pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)

        def ctx_for(i):
            return sentences[i], " ".join(sentences[max(0, i - 2):i]), (sentences[i + 1] if i + 1 < len(sentences) else "")

        def prefetch(i):
            if chain and chain[0][0] == "elevenlabs" and i < len(sentences) and i not in ahead and not stop.is_set():
                ahead[i] = pool.submit(open_elevenlabs, *ctx_for(i))

        try:
            while not stop.is_set():
                try:
                    i = q.get(timeout=0.2)
                except queue.Empty:
                    continue
                if i is None:
                    break
                s, prev, nxt = ctx_for(i)
                ok = False
                for name, fn in chain:
                    if stop.is_set():
                        break
                    try:
                        t = time.time()
                        fut = ahead.pop(i, None) if name == "elevenlabs" else None
                        gen = drain_elevenlabs(fut.result(), stop) if fut else fn(s, prev, nxt, stop)
                        prefetch(i + 1)         # open the next sentence's request while this one streams
                        for chunk in gen:
                            if stop.is_set():
                                break
                            player.write(chunk)
                            push_state()
                        dbg(f"tts[{name}] {len(s)} chars in {time.time() - t:.2f}s{' (prefetched)' if fut else ''}: {s[:100]!r}")
                        backend_used[0] = backend_used[0] or name
                        ok = True
                        break
                    except Exception as e:  # noqa
                        dbg(f"tts[{name}] failed: {e}")
                if not ok and not stop.is_set():
                    dbg("all TTS backends failed")
        finally:
            for f in ahead.values():            # never-drained prefetches (interrupt): close their sockets
                f.add_done_callback(_close_el)
            pool.shutdown(wait=False)
        if not stop.is_set():
            player.finish()

    lt = threading.Thread(target=llm_thread, daemon=True)
    tt = threading.Thread(target=tts_thread, daemon=True)
    Ctl.toggle.clear()
    lt.start()
    tt.start()
    # wait for completion, an interrupt (toggle) or cancel
    while tt.is_alive():
        if Ctl.toggle.is_set() or Ctl.cancel.is_set():
            stop.set()
            interrupted.set()
            player.stop()
            if "resp" in holder:
                _abort(holder["resp"])
            break
        tt.join(0.05)
    lt.join(2)
    tt.join(2)

    reply = strip_tags(clean_text("".join(reply_parts)))
    if llm_err[0] and not reply:
        reply = f"Gateway error: {llm_err[0]}"
        log(f"ERROR: {llm_err[0]}")
        notify(NAME, "dialog-error", 6000, reply)
        emit({"type": "error", "message": reply})
        set_state("error", text, reply, speaker)
        time.sleep(1.5)
        return reply, False
    emit({"type": "done", "reply": reply})
    if reply and reply.strip() not in ("NO_REPLY", "NO_REPLY."):
        remember("q", reply)
    if reply:
        log(f"{NAME.upper()}: {reply}" + (" [interrupted]" if interrupted.is_set() else ""))
        notify(NAME, "audio-speakers", 12000, reply[:400])
    t0 = timing["speech_end"]
    fa = player.first_audio_at
    log("TIMING: stt={:.2f}s ttft={:.2f}s first_sentence={:.2f}s first_audio={:.2f}s total={:.2f}s tts={}".format(
        timing["stt_done"] - t0,
        timing.get("ttft", timing["stt_done"]) - t0,
        timing.get("first_sentence", timing["stt_done"]) - t0,
        (fa - t0) if fa else -1,
        time.time() - t0, backend_used[0] or "none"))
    set_state("idle", text, reply, speaker)
    return reply, interrupted.is_set()


# ---------------------------------------------------------------- main loops
def hear(wav, forced=None):
    """Transcribe and identify the voice at the same time (speaker id is ~60 ms, whisper is the long pole).
    -> (text, speaker or None). Also keeps the clip around for later enrollment."""
    spk = [None]
    ident = threading.Thread(target=lambda: spk.__setitem__(0, identify_speaker(wav)), daemon=True)
    if forced:
        spk[0] = {"speaker": forced, "score": 1.0}          # test hook: --speaker <profile>
    elif SPEAKER_URL:
        ident.start()
    text = transcribe(wav)
    if ident.is_alive():
        ident.join(12)
    speaker = spk[0]
    clip = save_clip(wav) if SPEAKER_URL else None
    if speaker and text:
        text, _turns = label_turns(wav, speaker, text)
        dbg(f"speaker: {speaker} clip={os.path.basename(clip) if clip else None}")
    return text, speaker


def cmd_turn(args):
    pause_media()
    try:
        if args.text:
            run_turn(args.text)
            return
        if args.wav:
            with open(args.wav, "rb") as f:
                wav = f.read()
            set_state("transcribing")
            t_end = time.time()
            text, speaker = hear(wav, getattr(args, "speaker", None))
            if len(text) < 2:
                notify("Didn't catch that", "dialog-warning")
                set_state("error")
                time.sleep(1.5)
                set_state("idle")
                return
            run_turn(text, t_end, speaker)
            return
        # --listen (optionally --converse)
        start_timeout = VAD_START_TIMEOUT_S
        hint = "speak, or press again to send"
        while not Ctl.cancel.is_set():
            wav = listen(start_timeout, hint)
            if wav is None:
                break
            t_end = time.time()
            set_state("transcribing")
            notify("Transcribing…", "audio-input-microphone", 0)
            text, speaker = hear(wav, getattr(args, "speaker", None))
            if len(text) < 2:
                notify("Didn't catch that", "dialog-warning")
                set_state("error")
                time.sleep(1.0)
                if not args.converse:
                    break
                start_timeout, hint = CONVERSE_TIMEOUT_S, "go on…"
                continue
            reply, interrupted = run_turn(text, t_end, speaker)
            if Ctl.cancel.is_set():
                break
            if interrupted:
                start_timeout, hint = VAD_START_TIMEOUT_S, "speak, or press again to send"
                continue
            if not args.converse:
                break
            start_timeout, hint = CONVERSE_TIMEOUT_S, "go on… (or wait to end)"
    finally:
        set_state("idle", _last_state.get("text", ""), _last_state.get("reply", ""), _last_speaker)
        resume_media()


def cmd_say(args):
    pause_media()
    stop = threading.Event()
    player = Player()
    text = clean_text(args.text)
    set_state("speaking", "", text)
    parts = []
    sp = Splitter(parts.append)
    sp.feed(text + " ")
    sp.flush()
    if not parts:
        parts = [text]
    chain = tts_chain()
    try:
        for i, s in enumerate(parts):
            if Ctl.toggle.is_set() or Ctl.cancel.is_set():
                stop.set()
                player.stop()
                break
            for name, fn in chain:
                try:
                    for chunk in fn(s, " ".join(parts[max(0, i - 2):i]), parts[i + 1] if i + 1 < len(parts) else "", stop):
                        player.write(chunk)
                    break
                except Exception as e:  # noqa
                    dbg(f"tts[{name}] failed: {e}")
        if not stop.is_set():
            player.finish()
    finally:
        set_state("idle", "", text)
        resume_media()


def cmd_speakers(args):
    """Enroll / inspect voices on the shared q-speaker service."""
    if not SPEAKER_URL:
        sys.exit("Q_SPEAKER_URL not set (see q_voice.env.example)")
    base = SPEAKER_URL.rsplit("/", 1)[0]
    if not args.name:
        print(json.dumps(SESSION.get(f"{base}/speakers", timeout=10).json(), indent=1))
        return
    wavs = args.wav or sorted(glob.glob(os.path.join(CLIPS_DIR, "*.wav")))[-args.last:]
    if not wavs:
        sys.exit(f"no clips in {CLIPS_DIR} yet (talk to {NAME} first, then enroll)")
    for w in wavs:
        with open(w, "rb") as f:
            r = SESSION.post(f"{base}/enroll", params={"name": args.name}, data=f.read(),
                             headers={"Content-Type": "audio/wav"}, timeout=30)
        print(os.path.basename(w), r.text.strip())


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("turn")
    t.add_argument("--text")
    t.add_argument("--wav")
    t.add_argument("--listen", action="store_true")
    t.add_argument("--converse", action="store_true")
    t.add_argument("--speaker", help="skip voice id and claim this profile name (testing)")
    t.add_argument("--json", action="store_true", help="typed turn from the Q chat panel: quiet, events only")
    t.add_argument("--image", action="append", default=[], help="(accepted from the panel; not sent yet)")
    s = sub.add_parser("say")
    s.add_argument("text")
    e = sub.add_parser("enroll", help="add recent clips to a voice profile (no name = list profiles)")
    e.add_argument("name", nargs="?")
    e.add_argument("--last", type=int, default=1, help="how many of the most recent clips to enroll (default 1)")
    e.add_argument("--wav", nargs="*", help="enroll these wav files instead of recent clips")
    args = ap.parse_args()
    if args.cmd == "enroll":
        return cmd_speakers(args)
    if not GATEWAY_URL or not GATEWAY_TOKEN:
        sys.exit("Q_GATEWAY_URL / Q_GATEWAY_TOKEN not set (see q_voice.env.example; q_voice.sh setup)")
    if args.cmd == "turn":
        if args.json:
            global VIA, QUIET
            VIA, QUIET = "text", True
            pidf = os.path.join(RUN, "typed.pid")
            os.makedirs(RUN, exist_ok=True)
            with open(pidf, "w") as f:
                f.write(str(os.getpid()))
            try:
                cmd_turn(args)
            finally:
                emit({"type": "exit"})
                try:
                    os.remove(pidf)
                except OSError:
                    pass
            return
        cmd_turn(args)
    else:
        cmd_say(args)


if __name__ == "__main__":
    main()
