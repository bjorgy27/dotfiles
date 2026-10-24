#!/usr/bin/env bash
# dotlocal.sh: keep the local (untracked) overlay files in step between the
# live config and an overlay store, and between machines.
#
# The repo itself is generic. Personal and per-machine files (perdevice.lua,
# personal.lua, keys, the voice assistant's env...) are listed in
# scripts/dotlocal.manifest and live outside git. Their canonical copies sit in
# the store, ~/.config/dotlocal (override with DOTLOCAL_DIR):
#   shared/<name>         the same on all of your machines
#   hosts/<host>/<name>   one machine only (<host> = `uname -n`)
#
# Usage: dotlocal.sh [--dry-run] <command>
#   status         compare store and live files on this machine
#   capture        live -> store (after editing a live file)
#   apply          store -> live (old live file kept as <file>.bak-dotlocal-<time>)
#   push <host>    store -> <host>'s store: shared/ and hosts/<host>/
#   pull <host>    <host>'s store -> store: shared/ and hosts/<host>/
#   sync <host>    pull, then push; the newer copy of each file wins
# push/pull/sync never touch the other machine's live files; run
# `ssh <host> ~/.config/scripts/dotlocal.sh apply` (dry run first) for that.
# --dry-run (-n) changes nothing and lists what would change. Contents of
# files flagged "secret" are never printed.
set -euo pipefail

self=$(readlink -f "${BASH_SOURCE[0]}")
DOTFILES=$(dirname "$(dirname "$self")")
MANIFEST=${DOTLOCAL_MANIFEST:-$DOTFILES/scripts/dotlocal.manifest}
STORE=${DOTLOCAL_DIR:-$HOME/.config/dotlocal}
HOST=$(uname -n)
DRY=0

die() { echo "dotlocal: $*" >&2; exit 1; }
say() { echo "$*"; }

# manifest rows as "scope|name|live|flags"
rows() {
  local scope name live flags
  while read -r scope name live flags; do
    [[ -z "${scope:-}" || "$scope" == \#* ]] && continue
    live=${live/#\$DOTFILES/$DOTFILES}
    live=${live/#\~/$HOME}
    echo "$scope|$name|$live|${flags:-}"
  done < "$MANIFEST"
}

store_path() {  # scope name
  case "$1" in
    shared) echo "$STORE/shared/$2" ;;
    host)   echo "$STORE/hosts/$HOST/$2" ;;
    *)      die "bad scope '$1' in $MANIFEST" ;;
  esac
}

show_diff() {  # from to flags
  if [[ "$3" == *secret* ]]; then say "    (secret: contents not shown)"
  else diff -u "$1" "$2" | sed 's/^/    /' || true; fi
}

# copy src over dst only when they differ; keep mode and mtime
copy() {  # src dst flags backup(0|1)
  local src=$1 dst=$2 flags=$3 backup=$4
  if [[ -e "$dst" ]] && cmp -s "$src" "$dst"; then return 1; fi
  if (( DRY )); then
    if [[ -e "$dst" ]]; then say "  would update $dst"; show_diff "$dst" "$src" "$flags"
    else say "  would create $dst"; fi
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  if (( backup )) && [[ -e "$dst" ]]; then cp -p "$dst" "$dst.bak-dotlocal-$(date +%Y%m%d-%H%M%S)"; fi
  local tmp; tmp=$(mktemp "$(dirname "$dst")/.dotlocal.XXXXXX")
  cp -p "$src" "$tmp" && mv -f "$tmp" "$dst"
  say "  wrote $dst"
}

cmd_status() {
  say "host $HOST, store $STORE"
  local scope name live flags s state
  while IFS='|' read -r scope name live flags; do
    s=$(store_path "$scope" "$name")
    if   [[ ! -e "$s" && ! -e "$live" ]]; then state="-        (not used here)"
    elif [[ ! -e "$s" ]];  then state="LIVE ONLY (run capture)"
    elif [[ ! -e "$live" ]]; then state="STORE ONLY (run apply)"
    elif cmp -s "$s" "$live"; then state="same"
    elif [[ "$s" -nt "$live" ]]; then state="DIFFERS, store newer"
    else state="DIFFERS, live newer"; fi
    printf '  %-6s %-30s %s\n' "$scope" "$name" "$state"
  done < <(rows)
}

cmd_capture() {
  local scope name live flags n=0
  while IFS='|' read -r scope name live flags; do
    [[ -e "$live" ]] || continue
    copy "$live" "$(store_path "$scope" "$name")" "$flags" 0 && n=$((n + 1))
  done < <(rows)
  say "capture: $n file(s) $( ((DRY)) && echo would change || echo changed)"
}

cmd_apply() {
  local scope name live flags n=0 s
  while IFS='|' read -r scope name live flags; do
    s=$(store_path "$scope" "$name")
    [[ -e "$s" ]] || continue
    copy "$s" "$live" "$flags" 1 && n=$((n + 1))
  done < <(rows)
  say "apply: $n file(s) $( ((DRY)) && echo would change || echo changed)"
}

remote_name() {  # ssh alias -> that machine's uname -n
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$1" uname -n || die "cannot reach $1 over ssh"
}

has_dir() {  # [host:]dir subdir
  if [[ "$1" == *:* ]]; then ssh -o BatchMode=yes "${1%%:*}" "test -d '${1#*:}/$2'"
  else [[ -d "$1/$2" ]]; fi
}

# rsync shared/ and hosts/<remote>/ in one direction; -u: never replace a newer file
xfer() {  # from to remote_host_name
  local opts=(-a -u -i --mkpath --chmod=Du=rwx,Dgo=,Fgo=) sub
  (( DRY )) && opts+=(-n)
  for sub in shared "hosts/$3"; do
    if has_dir "$1" "$sub"; then rsync "${opts[@]}" "$1/$sub/" "$2/$sub/" | sed 's/^/  /'
    else say "  ($1/$sub: nothing there yet)"; fi
  done
}

cmd_push() {
  local alias=$1 rname; rname=$(remote_name "$alias")
  [[ "$rname" != "$HOST" ]] || die "$alias is this machine"
  (( DRY )) || ssh "$alias" 'mkdir -p ~/.config/dotlocal/shared ~/.config/dotlocal/hosts && chmod 700 ~/.config/dotlocal'
  say "push $STORE -> $alias:.config/dotlocal (shared/, hosts/$rname/)$( ((DRY)) && echo ' [dry run]')"
  xfer "$STORE" "$alias:.config/dotlocal" "$rname"
}

cmd_pull() {
  local alias=$1 rname; rname=$(remote_name "$alias")
  [[ "$rname" != "$HOST" ]] || die "$alias is this machine"
  say "pull $alias:.config/dotlocal -> $STORE (shared/, hosts/$rname/)$( ((DRY)) && echo ' [dry run]')"
  xfer "$alias:.config/dotlocal" "$STORE" "$rname"
}

args=()
for a in "$@"; do
  case "$a" in
    -n|--dry-run) DRY=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$self" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) args+=("$a") ;;
  esac
done
set -- "${args[@]}"
[[ -f "$MANIFEST" ]] || die "no manifest at $MANIFEST"
mkdir -p "$STORE" && chmod 700 "$STORE"
case "${1:-status}" in
  status)  cmd_status ;;
  capture) cmd_capture ;;
  apply)   cmd_apply ;;
  push)    [[ -n "${2:-}" ]] || die "push <host>"; cmd_push "$2" ;;
  pull)    [[ -n "${2:-}" ]] || die "pull <host>"; cmd_pull "$2" ;;
  sync)    [[ -n "${2:-}" ]] || die "sync <host>"; cmd_pull "$2"; cmd_push "$2" ;;
  *) die "unknown command '$1' (try --help)" ;;
esac
