# Q voice check (q-speaker + q_voice.py)

Spoken turns to Q are matched against Beck's voice profile; anyone else gets one spoken refusal and the turn never
reaches the agent. Typed turns are never checked. The check fails closed: if q-speaker is down, unreachable or not
configured, spoken turns are refused ("type to me instead").

## Locked out? One line

    touch ~/.config/q-voice/speaker-bypass      # skip the voice check on this machine; rm it to re-arm

or run with `Q_SPEAKER_BYPASS=1`. Each machine has its own file. `Q_ONLY_OWNER=0` turns the gate off entirely.

## Teaching it your voice

    q_voice.py enroll beck --last 5                       # the last 5 spoken turns on this machine's mic
    q_voice.py enroll beck --wav memo.m4a --device iphone # voice memos / notes, any audio ffmpeg reads
    q_voice.py speaker-status                             # clips per device, last accept/refuse decisions

Enrol only turns you know were you. Undo a profile: `curl -X DELETE '127.0.0.1:8179/speakers?name=beck'`.

## Where it runs

q-speaker (`q_speaker.py`, user unit `q-speaker`) lives on the desktop at 127.0.0.1:8179; the laptop reaches it at
`http://100.110.137.95:8179/identify` (Q_SPEAKER_URL in `~/.config/q-voice/env`). Profiles, the cohort used for
score normalisation and the decision log are in `~/.local/share/q-speaker/` (mode 600). No audio is stored there and
nothing leaves the tailnet.

Tunables (env on the q-speaker unit): `Q_SPEAKER_THRESHOLD` 0.70, `Q_SPEAKER_COHORT_MARGIN` 0.25,
`Q_SPEAKER_SHORT_THRESHOLD` 0.78 (clips under 3 s), `Q_SPEAKER_MIN_SNR` 15 dB. Calibration notes:
`~/projects/q-speaker-audit.md`.
