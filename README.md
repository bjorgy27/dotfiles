# dotfiles

Personal Arch Linux setup: Hyprland + [quickshell](https://quickshell.outfoxxed.me/) (custom
widget bar/shell), Catppuccin theming, kitty, neovim, Zed, and supporting scripts.

## What's in here

- `packages/pacman.txt` - explicitly installed official-repo packages (`pacman -Qqe`)
- `packages/aur.txt` - AUR packages (`pacman -Qqem`), installed via `yay`
- Config folders (`hypr/`, `quickshell/`, `kitty/`, ...) sit at the repo root, matching
  [gagehauptman/dotfiles](https://github.com/gagehauptman/dotfiles) (this repo is a fork);
  `install.sh` symlinks each one into `~/.config/`
  - `hypr/` - Hyprland, hyprlock, hypridle config
  - `quickshell/` - the widget shell (bar, workspaces, wallpaper selector, weather/radar/
    system-stats/Bluetooth/network/music widgets, Catppuccin theme variants)
  - `scripts/` - screen capture/recording, wallpaper shuffling, and the poll scripts
    quickshell widgets read from (weather, battery, network, Bluetooth, Tesla/Tessie,
    Canvas assignments, radar, etc.)
  - `kitty/`, `nvim/`, `zed/`, `xfce4/` (Thunar settings), plus `mimeapps.list` and
    `QtProject.conf`
  - `wallpapers/`, `autostart/`
- `claude/` - Claude Code global `settings.json` and this machine's persistent memory
  (`~/.claude/projects/-home-bjorgy/memory`)
- `install.sh` - bootstraps a fresh Arch install: installs packages (+ yay if missing),
  symlinks each config folder into `~/.config`, clones the `split-monitor-workspaces`
  Lua plugin into `~/.config/hypr/plugins/` (it's `require()`'d directly from
  `hyprland.lua`, not loaded via `hyprpm`), and enables sddm/wireplumber/pipewire.

## Bringing up a new machine

```sh
git clone <this-repo-url> ~/dotfiles
cd ~/dotfiles
./install.sh
```

Then see `SECRETS.md` for the couple of manual, non-synced steps (API keys, Claude login).

## Deliberately NOT tracked

- `~/.config/canvas.key`, `~/.config/tessie.key` - API tokens, never committed (see `SECRETS.md`)
- `~/.claude/.credentials.json`, session history, caches - machine-local, re-auth instead
- The `hypr/plugins/split-monitor-workspaces` source tree - re-cloned by `install.sh`
  instead of vendoring its nested git history (see `.gitignore`)
