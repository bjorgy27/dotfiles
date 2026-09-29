#!/usr/bin/env bash
# Next-track key router, so the double press on a Bluetooth headset starts a voice turn.
#
#   headset connected -> talk to Q (q_voice.sh toggle), even while music is playing
#   no headset        -> skip to the next track, as always
#
# The headset is matched by name against Q_VOICE_HEADSET (default "Sonos Ace"); set it in
# ~/.config/q-voice/env. Bound to XF86AudioNext in hyprland.lua. On the Sonos Ace the
# content key sends next-track on a double press.

CONF="${Q_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/q-voice/env}"
[ -r "$CONF" ] && . "$CONF"
: "${Q_VOICE_HEADSET:=Sonos Ace}"

if [ -n "$Q_VOICE_HEADSET" ] && command -v bluetoothctl >/dev/null 2>&1 &&
   timeout 2 bluetoothctl devices Connected 2>/dev/null | grep -qiF "$Q_VOICE_HEADSET"; then
  exec "$(dirname "$(readlink -f "$0")")/q_voice.sh" toggle
fi

exec playerctl --player spotifyd,%any next
