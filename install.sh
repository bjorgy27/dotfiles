#!/usr/bin/env bash
# Bootstraps this dotfiles repo onto a fresh Arch Linux install.
# Run from inside the cloned repo: ./install.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config"

if [ ! -f /etc/arch-release ]; then
  echo "This script targets Arch Linux. Aborting." >&2
  exit 1
fi

echo "==> Installing official packages"
sudo pacman -S --needed --noconfirm - < "$REPO_DIR/packages/pacman.txt"

if ! command -v yay >/dev/null; then
  echo "==> Bootstrapping yay (AUR helper)"
  sudo pacman -S --needed --noconfirm base-devel git
  tmpdir=$(mktemp -d)
  git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
  (cd "$tmpdir/yay" && makepkg -si --noconfirm)
  rm -rf "$tmpdir"
fi

echo "==> Installing AUR packages"
# yay is itself in aur.txt; skip re-installing it since it's already present
grep -vx 'yay' "$REPO_DIR/packages/aur.txt" | yay -S --needed --noconfirm -

echo "==> Linking config directories"
# Layout follows gagehauptman/dotfiles: config folders live at the repo root.
CONFIG_ENTRIES=(autostart hypr kitty mimeapps.list nvim QtProject.conf quickshell scripts wallpapers xfce4 zed)
mkdir -p "$CONFIG_DIR"
for name in "${CONFIG_ENTRIES[@]}"; do
  entry="$REPO_DIR/$name"
  dest="$CONFIG_DIR/$name"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    echo "    backing up existing $dest -> $dest.bak"
    mv "$dest" "$dest.bak"
  fi
  ln -sfn "$entry" "$dest"
  echo "    $dest -> $entry"
done

# Machine-local settings (home location etc.) are gitignored; seed from the example.
cp -n "$REPO_DIR/quickshell/local.example.js" "$REPO_DIR/quickshell/local.js"

chmod +x "$CONFIG_DIR"/scripts/*.sh "$CONFIG_DIR"/scripts/**/*.sh 2>/dev/null || true

echo "==> Hyprland plugin: split-monitor-workspaces"
plugin_dir="$CONFIG_DIR/hypr/plugins/split-monitor-workspaces"
if [ -d "$plugin_dir/.git" ]; then
  git -C "$plugin_dir" pull --ff-only
else
  mkdir -p "$CONFIG_DIR/hypr/plugins"
  git clone https://github.com/zjeffer/split-monitor-workspaces "$plugin_dir"
fi

echo "==> Enabling services"
sudo systemctl enable sddm.service
systemctl --user enable wireplumber.service pipewire.socket pipewire-pulse.socket

echo "==> Claude Code config"
claude_project_dir="$(echo "$HOME" | tr '/' '-')"
mkdir -p "$HOME/.claude/projects/$claude_project_dir/memory"
cp -n "$REPO_DIR/claude/settings.json" "$HOME/.claude/settings.json"
cp -r "$REPO_DIR/claude/memory/." "$HOME/.claude/projects/$claude_project_dir/memory/"

cat <<'EOF'

==> Done. Manual steps still required:

1. Secrets (never stored in this repo):
   - $HOME/.config/canvas.key   -- your Canvas LMS API token (chmod 600)
   - $HOME/.config/tessie.key   -- your Tessie/Tesla API token (chmod 600)

2. Claude Code login:
   Run `claude` and complete the login flow - credentials are per-machine
   and intentionally not synced.

3. Log out and select Hyprland at the SDDM login screen.

EOF
