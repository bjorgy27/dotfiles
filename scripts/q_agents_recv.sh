#!/bin/sh
# Receiving end of q_agents.py's Q_AGENTS_MIRROR, for a machine without the
# openclaw CLI: agents.json arrives on stdin and replaces the local copy
# atomically, so QChatWidget.qml's file watch sees one clean change.
#
#   Q_AGENTS_MIRROR="ssh laptop .config/scripts/q_agents_recv.sh"
set -e
dir=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/q-voice
mkdir -p "$dir"
tmp=$dir/agents.json.tmp.$$
cat >"$tmp"
mv -f "$tmp" "$dir/agents.json"
