-- Per-device Hyprland settings. install.sh copies this to perdevice.lua
-- (gitignored) if it doesn't exist; edit that copy. hyprland.lua loads it
-- before the workspace plugin. Same pattern as gagehauptman/dotfiles.

-- Monitor layout, one hl.monitor per output (see `hyprctl monitors`).
-- Without any, hyprland.lua's catch-all gives every screen its preferred mode.
-- hl.monitor({ output = "eDP-1", mode = "preferred", position = "0x0", scale = "1" })

-- Where the cursor starts.
-- hl.config({ cursor = { default_monitor = "eDP-1" } })

-- Workspace ownership, highest priority first: the first monitor listed gets
-- workspaces 1-10, the second 11-20, and so on.
-- DEVICE.monitor_priority = { "eDP-1" }
