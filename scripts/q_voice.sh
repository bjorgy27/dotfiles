#!/usr/bin/env bash
# q_voice.sh — conversational voice chat with your openclaw agent from Hyprland.
# Thin wrapper around q_voice.py; nothing here is machine-specific — all of
# that lives in ~/.config/q-voice/env (see q_voice.env.example).
#
#   q_voice.sh toggle       # keybind (SUPER+T):
#                              #   idle      -> start listening (VAD ends your turn automatically)
#                              #   listening -> send now
#                              #   thinking / speaking -> interrupt and listen again
#   q_voice.sh cancel       # (SUPER+SHIFT+T) stop everything, go idle
#   q_voice.sh ask "text"   # skip the mic: send text, speak the reply
#   q_voice.sh say "text"   # TTS only
#   q_voice.sh enroll alex  # teach the speaker service this voice from the last clip (no name = list profiles)
#   q_voice.sh status       # what is running, what is configured, recent timings
#   q_voice.sh setup        # one-time: venv, Silero VAD model, config file from the example
#   q_voice.sh setup whisper  # also: whisper model + a user service running whisper-server
#
# Pipeline (all overlapped, see q_voice.py): pw-record + Silero VAD -> whisper-server (local)
#   -> gateway /v1/chat/completions stream:true -> sentence chunks -> streaming TTS -> pw-play
# Voice id (optional, Q_SPEAKER_URL): each turn also goes to q-speaker /identify, so the agent is told
#   whether it is you, someone else in the house, or a guest (names: ~/.config/q-voice/speakers.json).
# State for the Quickshell bar indicator: $XDG_RUNTIME_DIR/q-voice/state.json
# Logs: ~/.local/state/q-voice/conversation.log (turns + TIMING lines), engine.log (debug)

set -u
export PATH="$HOME/.local/bin:$PATH"

CONF="${Q_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/q-voice/env}"
[ -f "$CONF" ] && { set -a; . "$CONF"; set +a; }
: "${Q_NAME:=Q}"
: "${Q_CONVERSE:=1}"
: "${Q_SHARE:=${XDG_DATA_HOME:-$HOME/.local/share}/q-voice}"
: "${Q_PY:=$Q_SHARE/venv/bin/python}"
: "${Q_ENGINE:=$(dirname "$(readlink -f "$0")")/q_voice.py}"
: "${Q_WHISPER_URL:=http://127.0.0.1:8178/inference}"
: "${Q_VAD_MODEL:=$Q_SHARE/silero_vad.onnx}"
export Q_VAD_MODEL

RUN="${XDG_RUNTIME_DIR:-/tmp}/q-voice"; mkdir -p "$RUN"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/q-voice"; mkdir -p "$STATE"
PIDF="$RUN/turn.pid"; STATEF="$RUN/state.json"
ELOG="$STATE/engine.log"

need_conf() {
  [ -n "${Q_GATEWAY_URL:-}" ] && [ -n "${Q_GATEWAY_TOKEN:-}" ] && return 0
  notify-send -r 4242 -a "$Q_NAME" -t 5000 "Voice assistant not configured" "run: q_voice.sh setup, then edit $CONF" 2>/dev/null || true
  echo "Q_GATEWAY_URL / Q_GATEWAY_TOKEN not set in $CONF (q_voice.sh setup)" >&2
  return 1
}
engine_pid() { local p; p=$(cat "$PIDF" 2>/dev/null) || return 1; kill -0 "$p" 2>/dev/null && echo "$p"; }
# a typed panel turn (q_voice.py turn --json) that may be reading its reply aloud
typed_pid() { local p; p=$(cat "$RUN/typed.pid" 2>/dev/null) || return 1; kill -0 "$p" 2>/dev/null && echo "$p"; }

start_engine() {  # background conversational turn
  local flags=(turn --listen); [ "$Q_CONVERSE" = 1 ] && flags+=(--converse)
  setsid "$Q_PY" "$Q_ENGINE" "${flags[@]}" >>"$ELOG" 2>&1 < /dev/null &
  echo $! > "$PIDF"
}

setup() {
  mkdir -p "$Q_SHARE" "$(dirname "$CONF")"
  if [ ! -x "$Q_PY" ]; then
    echo "creating venv at $Q_SHARE/venv"
    if command -v uv >/dev/null; then
      uv venv --python 3.12 "$Q_SHARE/venv" && uv pip install --python "$Q_PY" onnxruntime numpy requests
    else
      python3 -m venv "$Q_SHARE/venv" && "$Q_PY" -m pip install --quiet onnxruntime numpy requests
    fi
  fi
  if [ ! -f "$Q_VAD_MODEL" ]; then
    echo "fetching Silero VAD model"
    curl -fsSL -o "$Q_VAD_MODEL" https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx
  fi
  if [ ! -f "$CONF" ]; then
    cp "$(dirname "$(readlink -f "$0")")/q_voice.env.example" "$CONF"
    echo "wrote $CONF — set Q_GATEWAY_URL and Q_GATEWAY_TOKEN"
  fi
  if [ "${1:-}" = whisper ]; then
    local model="${Q_WHISPER_MODEL:-${XDG_DATA_HOME:-$HOME/.local/share}/whisper/ggml-base.en.bin}"
    if [ ! -f "$model" ]; then
      mkdir -p "$(dirname "$model")"
      echo "fetching $(basename "$model") (whisper.cpp model, ~150 MB)"
      curl -fL -o "$model" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$(basename "$model")"
    fi
    local unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/q-whisper.service"
    if [ ! -f "$unit" ]; then
      mkdir -p "$(dirname "$unit")"
      sed "s|ggml-base.en.bin|$(basename "$model")|" "$(dirname "$(readlink -f "$0")")/q-whisper.service.example" > "$unit"
      systemctl --user daemon-reload && systemctl --user enable --now q-whisper.service && echo "whisper-server running as a user service"
    fi
  fi
  echo "also needed on this machine: whisper-server (whisper.cpp) on ${Q_WHISPER_URL%/inference} (q_voice.sh setup whisper),"
  echo "pw-record/pw-play (pipewire), ffmpeg, notify-send; optional: piper + a voice for offline TTS. See: q_voice.sh status"
}

status() {
  if p=$(engine_pid); then echo "engine running (pid $p)"; else echo "engine idle"; fi
  [ -f "$STATEF" ] && { cat "$STATEF"; echo; }
  echo "config: $CONF $([ -f "$CONF" ] && echo present || echo MISSING)"
  echo "gateway: ${Q_GATEWAY_URL:-MISSING (Q_GATEWAY_URL)} token=$([ -n "${Q_GATEWAY_TOKEN:-}" ] && echo set || echo MISSING)"
  echo "venv: $Q_PY $([ -x "$Q_PY" ] && echo ok || echo MISSING — q_voice.sh setup)"
  echo "vad model: $Q_VAD_MODEL $([ -f "$Q_VAD_MODEL" ] && echo ok || echo MISSING — q_voice.sh setup)"
  curl -s -m 2 -o /dev/null -w "whisper-server: http=%{http_code}\n" "${Q_WHISPER_URL%/inference}/" || echo "whisper-server: unreachable"
  local tts="${Q_TTS:-auto}"; local chain=""
  [ -n "${Q_ELEVENLABS_API_KEY:-}" ] && [ -n "${Q_ELEVENLABS_VOICE:-N2lVS1w4EtoT3dr4eOWO}" ] && chain="$chain elevenlabs"
  [ -n "${Q_GATEWAY_SSH:-}" ] && chain="$chain gateway(${Q_GATEWAY_SSH})"
  command -v "${Q_PIPER_BIN:-piper}" >/dev/null && chain="$chain piper" || chain="$chain (piper missing)"
  echo "tts: $tts —$chain"
  grep TIMING "$STATE/conversation.log" 2>/dev/null | tail -3
}

case "${1:-toggle}" in
  toggle)  # while a typed reply is being read aloud: cut it off and listen instead (interrupt)
    if t=$(typed_pid); then kill -TERM "$t"; for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$t" 2>/dev/null || break; sleep 0.1; done; fi
    if p=$(engine_pid); then kill -USR1 "$p"; else need_conf && start_engine; fi ;;
  cancel)
    if p=$(engine_pid); then kill -TERM "$p"; fi
    if t=$(typed_pid); then kill -TERM "$t"; fi
    rm -f "$PIDF"
    notify-send -r 4242 -a "$Q_NAME" -t 1500 "Cancelled" 2>/dev/null || true ;;
  ask)  shift; [ -n "${*:-}" ] || { echo "usage: $0 ask <text>"; exit 2; }
        need_conf && exec "$Q_PY" "$Q_ENGINE" turn --text "$*" ;;
  say)  shift; [ -n "${*:-}" ] || { echo "usage: $0 say <text>"; exit 2; }
        exec "$Q_PY" "$Q_ENGINE" say "$*" ;;
  enroll) shift; exec "$Q_PY" "$Q_ENGINE" enroll "$@" ;;
  status) status ;;
  setup)  shift; setup "${1:-}" ;;
  *) echo "usage: $0 {toggle|cancel|ask <text>|say <text>|enroll [name] [--last N]|status|setup [whisper]}"; exit 2 ;;
esac
