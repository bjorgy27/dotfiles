# Dotfiles

Personal Hyprland setup on Arch Linux: [quickshell](https://quickshell.outfoxxed.me/)
widget bar, Catppuccin theming, kitty, neovim, Zed, and the poll scripts that feed the
widgets. Forked from [gagehauptman/dotfiles](https://github.com/gagehauptman/dotfiles)
and kept in the same root layout, so upstream changes still cherry-pick cleanly.

Runs on two machines (a desktop and a laptop) off the same branch; everything
machine-specific is isolated in gitignored files (see [Per-machine settings](#per-machine-settings)).

## Overview

```
dotfiles/
├── autostart/      # .desktop entries linked into ~/.config/autostart
├── claude/         # Claude Code settings.json
├── home/           # ~ dotfiles (.zshrc, .bashrc, .bash_profile, .gitconfig)
├── hypr/           # Hyprland (Lua config), hyprlock, hypridle
├── kitty/          # Kitty terminal
├── nvim/           # Neovim (lazy.nvim)
├── packages/       # pacman + AUR package lists
├── quickshell/     # Bar and widgets (QML)
├── scripts/        # Capture/record, wallpaper, voice, and widget poll scripts
├── wallpapers/     # Wallpaper collection
├── xfce4/          # Thunar settings
└── zed/            # Zed editor
```

`install.sh` symlinks each config folder into `~/.config` and each `home/` file into `~`.

### quickshell

The bar and its widgets, all QML: workspaces, volume, music, network manager, network and
system stats, Bluetooth, weather, an interactive radar/globe with aircraft overlay, Canvas
assignments, Bambu print progress, wallpaper selector with live preview, screen capture,
app selector, power menu, a chat panel and a voice bar. `templates/` holds the shared
widget scaffolding, `themes/` the four Catppuccin variants, `presets.json` the dashboard
layouts.

### scripts

- `polls/` - the background pollers each widget reads from (weather, radar frames,
  aircraft, CPU/temps/system, battery, network, Bluetooth, Canvas, Tessie, Bambu, updates)
- `wallpaper/` - selector and shuffler, plus the spinning-globe wallpaper generator
- `init/` - session startup (quickshell, wallpaper, dark mode)
- `lock/`, `listeners/` - lock screen message and audio listener
- `hyprland_capture_*.sh`, `hyprland_record_*.sh` - screenshots and screen recording
- `q_voice.*`, `q-whisper.service.example` - local speech-to-text voice assistant plumbing

## Dependencies

### Core

| Package | Description |
|---------|-------------|
| [hyprland](https://hyprland.org/) | Tiling Wayland compositor |
| [quickshell-git](https://quickshell.outfoxxed.me/) (AUR) | Qt6/QML shell toolkit |
| [hyprlock](https://github.com/hyprwm/hyprlock) | Lock screen |
| [hypridle](https://github.com/hyprwm/hypridle) | Idle daemon (lock and screen blanking) |
| [kitty](https://sw.kovidgoyal.net/kitty/) | GPU-accelerated terminal |
| [awww](https://github.com/LGFae/awww) | Wallpaper daemon |
| [sddm](https://github.com/sddm/sddm) | Display manager |

### Utilities

| Package | Description |
|---------|-------------|
| [grim](https://sr.ht/~emersion/grim/) / [slurp](https://github.com/emersion/slurp) | Screenshots and region selection |
| [wl-clipboard](https://github.com/bugaevc/wl-clipboard) | Clipboard utilities |
| [playerctl](https://github.com/altdesktop/playerctl) | Media player control |
| [brightnessctl](https://github.com/Hummer12007/brightnessctl) | Brightness control |
| [pipewire](https://pipewire.org/) + wireplumber | Audio |
| [networkmanager](https://networkmanager.dev/) / [bluez](http://www.bluez.org/) | Network and Bluetooth |
| jq, socat | Poll script plumbing |
| [tailscale](https://tailscale.com/) | Tailnet, used to reach the other machine |
| [neovim](https://neovim.io/) / [zed](https://zed.dev/) | Editors |
| texlive-basic, texlive-latexrecommended | LaTeX for coursework |

Full lists live in `packages/pacman.txt` (`pacman -Qqe`) and `packages/aur.txt`
(`pacman -Qqem`); `install.sh` installs straight from them.

## Installation

```bash
git clone https://github.com/bjorgy27/dotfiles.git ~/dotfiles
cd ~/dotfiles
./install.sh
```

`install.sh` installs both package lists (bootstrapping `yay` if missing), symlinks the
config folders and home dotfiles (backing up anything real it finds first), seeds the
gitignored machine-local files from their examples, clones Oh My Zsh and the
split-monitor-workspaces plugin, enables sddm/tailscaled/pipewire, and copies the Claude
Code settings into place.

It then prints the manual steps it deliberately won't do: API keys, `sudo tailscale up`,
the Claude Code login, monitor layout, and the radar home location. `SECRETS.md` has the
details.

### Hyprland plugins

**[split-monitor-workspaces](https://github.com/zjeffer/split-monitor-workspaces)** gives
each monitor its own workspace namespace (1-10 per monitor instead of shared global
workspaces). It's a Lua package that `hyprland.lua` requires from `hypr/plugins/`, so it
is cloned there rather than loaded through `hyprpm`; `install.sh` does this and pulls it
on later runs. Requires Hyprland >= 0.55.0 with the Lua config.

> On a Hyprland release build, check out the matching `release/0.XX.x` branch in the
> plugin repo after major Hyprland updates. Stay on `main` if you run `hyprland-git`.

## Per-machine settings

Both machines run the same branch, so anything that differs is gitignored and seeded from
an example file:

| File | Holds |
|------|-------|
| `hypr/perdevice.lua` | Monitors, cursor size, workspace priority (see `perdevice.example.lua`) |
| `quickshell/local.js` | Radar home location (see `local.example.js`) |
| `quickshell/presets.local.json` | Dashboard layout for this machine |

`perdevice.lua` matters most on multi-monitor setups: without `DEVICE.monitor_priority`
the plugin hands out workspace ranges in the order monitors *connect*, so whichever screen
wakes first after being powered off takes over workspaces 1-10. `hyprland.lua` also
remembers what each monitor was showing and restores it when the monitor returns, since
powering a monitor off drops its link and reads to the compositor as an unplug.

## Deliberately not tracked

- `~/.config/canvas.key`, `~/.config/tessie.key`, `~/.config/bambu.conf` - API tokens and
  the printer's LAN credentials (see `SECRETS.md`)
- `~/.claude/.credentials.json`, session history, caches - machine-local, re-auth instead
- `hypr/plugins/` - re-cloned by `install.sh` instead of vendoring nested git history
- Machine-local config and generated wallpaper/build artifacts (see `.gitignore`)

## Upstream

`upstream` points at [gagehauptman/dotfiles](https://github.com/gagehauptman/dotfiles),
where this started. The `beck` branch carries the changes from here; pull upstream work
in selectively rather than merging wholesale, since the quickshell side has diverged.
