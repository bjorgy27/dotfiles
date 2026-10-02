// Offscreen preview of the lock screen (preview.sh): one window per screen in
// $LOCK_CONFIG, rendered with QT_QPA_PLATFORM=offscreen, saved as PNGs to
// $LOCK_PREVIEW_OUT/<screen>.png, then quits. Never locks, never shows a window
// on the real monitors, no PAM.
import QtQuick
import Quickshell
import Quickshell.Io
// LockSurface.qml sits next to this file

ShellRoot {
  id: root
  readonly property string mode: "test"
  readonly property string user: Quickshell.env("USER") || ""
  property string buffer: Quickshell.env("LOCK_PREVIEW_TYPED") || ""
  property string status: "idle"
  property bool unlocking: false
  property bool capsLock: false
  function handleKey(e) {}

  property var config: ({ screens: [] })
  FileView {
    path: Quickshell.env("LOCK_CONFIG")
    blockLoading: true
    onLoaded: root.config = JSON.parse(text())
  }
  property int pending: (root.config.screens ?? []).length
  onPendingChanged: if (pending === 0) Qt.quit()

  Variants {
    model: root.config.screens ?? []
    FloatingWindow {
      id: win
      required property var modelData
      implicitWidth: modelData.width
      implicitHeight: modelData.height
      color: "black"
      LockSurface { id: surf; anchors.fill: parent; shell: root; screenData: win.modelData; preview: true }
      Timer {
        interval: Number(Quickshell.env("LOCK_PREVIEW_DELAY_MS") || 2500); running: true
        onTriggered: surf.grabToImage(r => {
          r.saveToFile(Quickshell.env("LOCK_PREVIEW_OUT") + "/" + (win.modelData.name || "screen") + ".png")
          root.pending--
        })
      }
    }
  }
}
