// Live preview of a dynamic wallpaper in the selector: a BevyView on the
// Bevy app of the same name (bevy/apps/<stem>), which renders the wallpaper's
// own scene. Loaded indirectly (see WallpaperSelectorWidget.qml) because the
// `Bevy` module only exists where bevy/build.sh ran. Renders only while
// visible; no pointer input.
import QtQuick
import Quickshell
import Bevy

BevyView {
  property string app: ""
  library: app === "" ? "" : Quickshell.env("HOME") + "/.config/quickshell/modules/Bevy/apps/" + app + "/lib" + app + ".so"
}
