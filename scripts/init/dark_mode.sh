#!/bin/sh
# Force GTK/GNOME apps (Thunar, gnome-text-editor, Firefox chrome, libadwaita
# apps) into dark mode. dconf/gsettings values are machine-local and not
# synced by this repo, so this needs to re-run on every login.

set -u

gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
gsettings set org.gnome.desktop.interface gtk-theme 'Material-DeepOcean-Borderless'
gsettings set org.gnome.desktop.interface icon-theme 'Papirus-Dark'
