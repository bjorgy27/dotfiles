local mainMod = "SUPER"

-- Per-device knobs (monitors, cursor, workspace ownership) live in the
-- gitignored ~/.config/hypr/perdevice.lua; see perdevice.example.lua.
DEVICE = { mainMod = mainMod, monitor_priority = {} }

-- Catch-all: any screen perdevice.lua doesn't name gets its preferred mode.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

hl.config({
    general = {
        gaps_in     = 5,
        gaps_out    = 12,
        border_size = 2,
        col = {
            active_border   = { colors = { "0xFFcba6f7", "0xFF89b4fa" }, angle = 45 },
            inactive_border = "0xFF45475a",
        },
    },

    decoration = {
        rounding = 15,
        blur = {
            enabled = false,
            size    = 1,
            passes  = 1,
        },
    },

    xwayland = {
        force_zero_scaling = true,
    },

    debug = {
        damage_tracking = 0,
    },

    render = {
        cm_enabled = false,
    },

})

hl.config({
    input = {
        kb_layout  = "us",
        kb_variant = "altgr-intl",
        kb_model   = "",
        kb_options = "",
        kb_rules   = "",

        follow_mouse = 1,

        touchpad = {
            disable_while_typing = false,
            clickfinger_behavior = true,
            natural_scroll       = true,
        },
    },
})

hl.config({ animations = { enabled = true } })

hl.curve("UWU1", { type = "bezier", points = { {0.22, 1}, {0.36, 1} } })

hl.animation({ leaf = "windows",    enabled = true, speed = 5, bezier = "UWU1",    style = "slide" })
hl.animation({ leaf = "fade",       enabled = true, speed = 3, bezier = "default" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 4, bezier = "UWU1",    style = "slidevert" })

-- Never idle (lock / dpms off) while any window is fullscreen, e.g. video
hl.window_rule({
    name  = "idle-inhibit-fullscreen",
    match = { class = ".*" },

    idle_inhibit = "fullscreen",
})

hl.on("hyprland.start", function()
    hl.exec_cmd("hyprpm reload -n")
    hl.exec_cmd("hypridle")
    hl.exec_cmd("QT_QPA_PLATFORMTHEME=qt6ct quickshell")
    hl.exec_cmd("~/.config/scripts/init/wallpaper.sh")
    hl.exec_cmd("~/.config/scripts/init/dark_mode.sh")
    hl.exec_cmd("nm-applet")
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP")
end)

hl.env("GTK_THEME",                "Material-DeepOcean-Borderless")
hl.env("MOZ_ENABLE_WAYLAND",       "1")
hl.env("LIBVA_DRIVER_NAME",        "radeonsi")
hl.env("XDG_SESSION_TYPE",         "wayland")
hl.env("__GLX_VENDOR_LIBRARY_NAME","radeonsi")
hl.env("WLR_NO_HARDWARE_CURSORS",  "1")
hl.env("GDK_BACKEND",              "wayland,x11")
hl.env("QT_QPA_PLATFORM",          "wayland;xcb")

hl.bind(mainMod .. " + RETURN",       hl.dsp.exec_cmd("kitty"))
hl.bind(mainMod .. " + X",            hl.dsp.window.close())
hl.bind(mainMod .. " + SHIFT + X",    hl.dsp.exec_cmd("hyprctl kill"))
hl.bind(mainMod .. " + V",            hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + Z",            hl.dsp.global("quickshell:togglePowerMenu"))
hl.bind(mainMod .. " + B",            hl.dsp.exec_cmd("firefox"))
hl.bind(mainMod .. " + D",            hl.dsp.exec_cmd("discord"))
hl.bind(mainMod .. " + F",            hl.dsp.window.fullscreen({ mode = "fullscreen" }))
hl.bind(mainMod .. " + SHIFT + F",    hl.dsp.window.fullscreen({ mode = "maximized" }))
hl.bind(mainMod .. " + Q",            hl.dsp.exec_cmd("~/.config/scripts/bar_toggle.sh"))
hl.bind(mainMod .. " + SHIFT + Q",    hl.dsp.exec_cmd("hyprctl reload"))
hl.bind(mainMod .. " + SHIFT + E",    hl.dsp.exit())
hl.bind(mainMod .. " + L",            hl.dsp.exec_cmd("hyprlock"))

hl.bind(mainMod .. " + PERIOD",       hl.dsp.focus({ monitor = "+1" }))
hl.bind(mainMod .. " + COMMA",        hl.dsp.focus({ monitor = "-1" }))
hl.bind(mainMod .. " + SHIFT + PERIOD", hl.dsp.window.move({ monitor = "+1" }))
hl.bind(mainMod .. " + SHIFT + COMMA",  hl.dsp.window.move({ monitor = "-1" }))

hl.bind(mainMod .. " + code:60",      hl.dsp.exec_cmd("playerctl --player spotifyd,%any next"))
hl.bind(mainMod .. " + code:59",      hl.dsp.exec_cmd("playerctl --player spotifyd,%any previous"))
hl.bind(mainMod .. " + space",        hl.dsp.exec_cmd("playerctl --player spotifyd,%any play-pause"))

-- Keyboard media and volume keys (standard XF86Audio* keysyms, so they work
-- on any keyboard; locked = also on the lock screen). Cider shows up on MPRIS
-- as chromium.instanceN. wpctl -l 1 caps the volume at 100%.
hl.bind("XF86AudioPlay",        hl.dsp.exec_cmd("playerctl --player spotifyd,%any play-pause"), { locked = true })
hl.bind("XF86AudioPause",       hl.dsp.exec_cmd("playerctl --player spotifyd,%any play-pause"), { locked = true })
hl.bind("XF86AudioStop",        hl.dsp.exec_cmd("playerctl --player spotifyd,%any stop"),       { locked = true })
hl.bind("XF86AudioNext",        hl.dsp.exec_cmd("playerctl --player spotifyd,%any next"),       { locked = true })
hl.bind("XF86AudioPrev",        hl.dsp.exec_cmd("playerctl --player spotifyd,%any previous"),   { locked = true })
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 2%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 2%-"),      { locked = true, repeating = true })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true })

hl.bind("F12",                        hl.dsp.exec_cmd("~/.config/scripts/hyprland_capture_full.sh"))
hl.bind(mainMod .. " + F12",          hl.dsp.exec_cmd("~/.config/scripts/hyprland_capture_partial.sh"))
hl.bind("SHIFT + F12",                hl.dsp.exec_cmd("bash -c 'pgrep -x wf-recorder && bash /storage/git/dotfiles/scripts/hyprland_record_stop.sh || bash /storage/git/dotfiles/scripts/hyprland_record_full.sh'"))
hl.bind(mainMod .. " + SHIFT + F12",  hl.dsp.exec_cmd("bash -c 'pgrep -x wf-recorder && bash /storage/git/dotfiles/scripts/hyprland_record_stop.sh || bash /storage/git/dotfiles/scripts/hyprland_record_region.sh'"))

hl.bind(mainMod .. " + left",         hl.dsp.focus({ direction = "left"  }))
hl.bind(mainMod .. " + right",        hl.dsp.focus({ direction = "right" }))
hl.bind(mainMod .. " + up",           hl.dsp.focus({ direction = "up"    }))
hl.bind(mainMod .. " + down",         hl.dsp.focus({ direction = "down"  }))

-- Push-to-talk: hold F4 to unmute mic, release to mute
hl.bind("F4",                         hl.dsp.exec_cmd("pactl set-source-mute @DEFAULT_SOURCE@ 0"))
hl.bind("F4",                         hl.dsp.exec_cmd("pactl set-source-mute @DEFAULT_SOURCE@ 1"), { release = true })
hl.bind(mainMod .. " + M",            hl.dsp.exec_cmd("pactl set-source-mute @DEFAULT_SOURCE@ 0"))

hl.bind("F1",                         hl.dsp.exec_cmd("pactl set-sink-mute   @DEFAULT_SINK@ toggle"))
hl.bind("F2",                         hl.dsp.exec_cmd("pactl set-sink-volume @DEFAULT_SINK@ -5%"))
hl.bind("F3",                         hl.dsp.exec_cmd("pactl set-sink-volume @DEFAULT_SINK@ +5%"))
hl.bind(mainMod .. " + F4",           hl.dsp.exec_cmd("pactl set-source-mute @DEFAULT_SOURCE@ toggle"))

hl.bind("F5",                         hl.dsp.exec_cmd("brightnessctl set 5%-"))
hl.bind("F6",                         hl.dsp.exec_cmd("brightnessctl set 5%+"))
hl.bind("F7",                         hl.dsp.exec_cmd("brightnessctl --device='platform::kbd_backlight' set 1-"))
hl.bind("F8",                         hl.dsp.exec_cmd("brightnessctl --device='platform::kbd_backlight' set 1+"))

hl.bind(mainMod .. " + N",            hl.dsp.global("quickshell:toggleDashboard"))
hl.bind(mainMod .. " + SHIFT + N",    hl.dsp.global("quickshell:dashboardNextPreset"))

-- Voice chat with Q (scripts/q_voice.sh; needs ~/.config/q-voice/env, see q_voice.env.example)
hl.bind(mainMod .. " + T",            hl.dsp.exec_cmd("~/.config/scripts/q_voice.sh toggle"))
hl.bind(mainMod .. " + SHIFT + T",    hl.dsp.exec_cmd("~/.config/scripts/q_voice.sh cancel"))
hl.bind(mainMod .. " + A",            hl.dsp.global("quickshell:toggleQChat"))
hl.bind(mainMod .. " + W",            hl.dsp.global("quickshell:toggleWallpaperSelector"))
hl.bind(mainMod .. " + SHIFT + W",    hl.dsp.exec_cmd("~/.config/scripts/wallpaper/wallpaper_shuffle.sh"))
hl.bind(mainMod .. " + R",            hl.dsp.global("quickshell:toggleAppSelector"))

hl.bind(mainMod .. " + mouse:272",    hl.dsp.window.drag(),   { mouse = true })
hl.bind(mainMod .. " + mouse:273",    hl.dsp.window.resize(), { mouse = true })

-- Loaded before split-monitor-workspaces so DEVICE.monitor_priority is known.
local perdevice = os.getenv("HOME") .. "/.config/hypr/perdevice.lua"
if io.open(perdevice, "r") then dofile(perdevice) end

package.path = package.path .. ";./?.lua;./?/init.lua"
local smw = require("plugins.split-monitor-workspaces")

WORKSPACE_COUNT = 10 -- per monitor; also used by the power-off restore below

smw.setup({
    workspace_count = WORKSPACE_COUNT,
    keep_focused = true,
    enable_persistent_workspaces = true,
    monitor_priority = DEVICE.monitor_priority,
})

for i = 1, smw.get_amount_of_workspaces() do
    local ws = tostring(i)
    local key = ws == "10" and "0" or ws -- workspace 10 on SUPER + 0
    -- Switch to / silently move the active window to the Nth workspace on the focused monitor
    hl.bind(mainMod .. " + " .. key,            smw.workspace(ws))
    hl.bind(mainMod .. " + SHIFT + " .. key,    smw.move_to_workspace_silent(ws))
    -- Move the active window to the Nth workspace and follow it there
    hl.bind("ALT + " .. key,                    smw.move_to_workspace(ws))
end


-- Surviving the monitors being switched off ---------------------------------
-- These panels drop the DP/HDMI link when they power down (DPMS off does it
-- too), so Hyprland sees a real hotplug disconnect: it parks the workspaces on
-- whatever output is left -- a 1080p headless fallback once both are gone --
-- and hands the ranges back out on reconnect. monitor_priority above keeps the
-- ranges themselves pinned; this puts each monitor back on the workspace it
-- was showing, so a night with the screens off leaves the session as it was.
local saved_workspace = {}   -- monitor name -> workspace it was showing
local saved_focus            -- monitor name that had focus
local settled         = {}   -- last poll's reading, to spot a stable one
local absent          = {}   -- monitor names currently disconnected
local pause_gen, restore_gen = 0, 0
local paused = false

--- Position of a monitor in DEVICE.monitor_priority, by port name or by the
--- "desc:" prefix of its description. nil when the monitor isn't pinned.
local function priority_index(monitor)
    for index, identifier in ipairs(DEVICE.monitor_priority) do
        local description = identifier:match("^desc:%s*(.-)%s*$")
        if description then
            if monitor.description:sub(1, #description) == description then return index end
        elseif identifier == monitor.name then
            return index
        end
    end
end

--- Whether a workspace belongs to this monitor's own range. Anything else is a
--- workspace mid-flight between monitors, not somewhere the user put it.
local function owns_workspace(monitor, ws_name)
    local index  = priority_index(monitor)
    local number = tonumber(ws_name)
    if not index or not number then return true end -- unpinned monitor, take its word
    local first = (index - 1) * WORKSPACE_COUNT + 1
    return number >= first and number < first + WORKSPACE_COUNT
end

--- Poll rather than follow workspace.active: a disconnect drags workspaces
--- across monitors *before* monitor.removed fires, and that burst of events
--- would otherwise overwrite the state we are trying to preserve. A reading
--- only counts once it has survived two consecutive ticks, which the burst
--- never does.
hl.timer(function()
    if paused then return end
    for _, monitor in ipairs(hl.get_monitors()) do
        local ws   = hl.get_active_workspace(monitor)
        local name = ws and ws.name
        if name and owns_workspace(monitor, name) then
            if settled[monitor.name] == name then saved_workspace[monitor.name] = name end
            settled[monitor.name] = name
        end
    end
    local active = hl.get_active_monitor()
    if active then
        if settled.focus == active.name then saved_focus = active.name end
        settled.focus = active.name
    end
end, { timeout = 1000, type = "repeat" })

--- Stop polling for a moment: right after a disconnect every reading describes
--- the collapsed layout, not the one worth remembering.
local function pause_polling()
    paused    = true
    pause_gen = pause_gen + 1
    local mine = pause_gen
    hl.timer(function()
        if mine == pause_gen then
            paused  = false
            settled = {} -- force a fresh pair of stable readings
        end
    end, { timeout = 4000, type = "oneshot" })
end

--- Put the monitors that just came back on the workspace they left off on.
--- Only monitors that were actually absent are touched, so turning one screen
--- off for the afternoon doesn't rewind the one you kept working on.
local function restore()
    ---@type string|nil
    local focus_ws
    for _, monitor in ipairs(hl.get_monitors()) do
        if absent[monitor.name] then
            local want = saved_workspace[monitor.name]
            local ws   = want and hl.get_workspace(want)
            -- Skip anything split-monitor-workspaces has since reassigned
            -- elsewhere, rather than fighting it over the workspace.
            if ws and ws.monitor and ws.monitor.name == monitor.name then
                if monitor.name == saved_focus then
                    focus_ws = want -- the focused monitor goes last, see below
                else
                    monitor:set_workspace({ workspace = want })
                end
            end
            absent[monitor.name] = nil
        end
    end
    -- set_workspace leaves focus alone, so the focused monitor is restored
    -- last with focus() and the session ends up on the screen it started on.
    if focus_ws then hl.dispatch(hl.dsp.focus({ workspace = focus_ws })) end
end

hl.on("monitor.removed", function(monitor)
    absent[monitor.name] = true
    pause_polling()
end)

hl.on("monitor.added", function(monitor)
    if not absent[monitor.name] then return end
    -- Wait for the dust to settle: the second monitor usually wakes a beat
    -- after the first and split-monitor-workspaces remaps on every add, so
    -- only the last timer scheduled gets to do the restore.
    restore_gen = restore_gen + 1
    local mine = restore_gen
    hl.timer(function()
        if mine == restore_gen then restore() end
    end, { timeout = 2500, type = "oneshot" })
end)
