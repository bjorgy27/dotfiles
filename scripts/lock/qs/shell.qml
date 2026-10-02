// Lock screen: an ext-session-lock-v1 client (Quickshell's WlSessionLock) that
// draws the current wallpaper itself, so nothing needs to show through it.
// Started by lock.sh in its own Quickshell instance (not the bar's), with the
// settings lockgen.py resolved from meta/*.toml in $LOCK_CONFIG. Ported from
// gagehauptman/dotfiles e6f2eee (+ bc567de, 73b8c23).
//
//   LOCK_MODE=lock   the real session lock. LOCK_SECONDS>0 unlocks by itself
//                    after that long (lock.sh --try).
//   LOCK_MODE=test   NO session lock: the same screens as overlay layer
//                    surfaces, closed after LOCK_SECONDS (lock.sh --test). Only
//                    here may LOCK_PAM_DIR/LOCK_PAM_CONFIG swap the PAM
//                    service, LOCK_TEST_PASSWORD auto-type a password.
//
// Unlock is only ever done after PAM says yes, by the timer above, or by
// `lock.sh --unlock` (IPC) from a TTY.
import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam

ShellRoot {
  id: root

  readonly property string mode: Quickshell.env("LOCK_MODE") === "test" ? "test" : "lock"
  readonly property real seconds: Number(Quickshell.env("LOCK_SECONDS") || 0)
  readonly property string user: Quickshell.env("USER") || ""

  // ---- settings (lockgen.py's JSON)
  property var config: ({ screens: [] })
  FileView {
    path: Quickshell.env("LOCK_CONFIG")
    blockLoading: true
    onLoaded: {
      try { root.config = JSON.parse(text()) }
      catch (e) { console.error("lock: bad config " + path + ": " + e.message) }
    }
    onLoadFailed: err => console.error("lock: cannot read " + path + " (" + err + "); using defaults")
  }
  function screenConfig(screen) {
    let list = root.config.screens ?? []
    return list.find(s => s.name === screen.name) ?? list[0] ?? ({ background: { kind: "color", color: "#ff1b1923", brightness: 1, blur: 0 }, elements: {} })
  }

  // ---- password entry, shared by all screens
  property string buffer: ""
  property string status: "idle"        // idle | checking | failed
  property bool unlocking: false

  PamContext {
    id: pam
    // The service hyprlock already uses (auth include login), so a password that
    // unlocked hyprlock unlocks this. Test mode may point at the fixtures in pam/.
    config: root.mode === "test" && Quickshell.env("LOCK_PAM_CONFIG") ? Quickshell.env("LOCK_PAM_CONFIG") : (Quickshell.env("LOCK_PAM_SERVICE") || "hyprlock")
    configDirectory: root.mode === "test" && Quickshell.env("LOCK_PAM_DIR") ? Quickshell.env("LOCK_PAM_DIR") : "/etc/pam.d"
    user: root.user
    onPamMessage: {
      if (responseRequired) respond(root.buffer)
    }
    onCompleted: result => {
      root.buffer = ""
      if (result === PamResult.Success) root.unlock()
      else root.status = "failed"
    }
    onError: err => {
      console.error("lock: PAM error " + err)
      root.buffer = ""
      root.status = "failed"
    }
  }

  function submit() {
    if (root.status === "checking" || root.buffer === "" || root.unlocking) return
    root.status = "checking"
    pam.start()
  }

  function handleKey(e) {
    if (root.unlocking) return
    if (root.status === "checking") return
    const ctrl = (e.modifiers & Qt.ControlModifier) !== 0
    if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { root.submit(); e.accepted = true; return }
    if (e.key === Qt.Key_Backspace) {
      root.buffer = ctrl ? "" : root.buffer.slice(0, -1)
      root.status = "idle"; e.accepted = true; return
    }
    if (e.key === Qt.Key_Escape || (ctrl && e.key === Qt.Key_U)) { root.buffer = ""; root.status = "idle"; e.accepted = true; return }
    if (!ctrl && (e.modifiers & Qt.AltModifier) === 0 && e.text.length > 0 && e.text.charCodeAt(0) >= 32 && e.text.charCodeAt(0) !== 127) {
      if (root.status === "failed") root.status = "idle"
      root.buffer += e.text
      e.accepted = true
    }
  }

  // ---- lock / unlock
  // The screens play a short success/fade-out (LockSurface, `unlocking`), then
  // the lock is released.
  function unlock() {
    if (root.unlocking) return
    root.unlocking = true
    root.buffer = ""
    releaseTimer.start()
  }
  Timer {
    id: releaseTimer
    interval: 520
    onTriggered: {
      if (root.mode === "lock") lock.locked = false
      // Give the compositor its unlock request before the process goes away:
      // exiting while locked would leave it on the "lock died" screen.
      quitTimer.start()
    }
  }
  Timer { id: quitTimer; interval: 1200; onTriggered: Qt.quit() }

  // ---- caps lock: the keyboards' LEDs (lock.sh lists their sysfs paths); the
  // key events carry no lock state.
  property bool capsLock: false
  readonly property var capsPaths: (Quickshell.env("LOCK_CAPS_LEDS") || "").split("|").filter(p => p !== "")
  property var capsStates: ({})
  Instantiator {
    model: root.capsPaths
    delegate: QtObject {
      id: led
      required property string modelData
      property FileView file: FileView { path: led.modelData; blockLoading: true }
      property Timer poll: Timer {
        interval: 250; repeat: true; running: true; triggeredOnStart: true
        onTriggered: {
          led.file.reload()
          let on = led.file.text().trim() === "1"
          if (root.capsStates[led.modelData] !== on) {
            let st = Object.assign({}, root.capsStates)
            st[led.modelData] = on
            root.capsStates = st
          }
        }
      }
    }
  }
  onCapsStatesChanged: root.capsLock = Object.values(root.capsStates).some(v => v)

  Timer {
    running: root.seconds > 0
    interval: root.seconds * 1000
    onTriggered: { console.warn("lock: timeout (" + root.seconds + "s), unlocking"); root.unlock() }
  }

  IpcHandler {
    target: "lock"
    function unlock(): void { root.unlock() }
  }

  // Test hook (test mode only): type a password once the surfaces are up.
  Timer {
    running: root.mode === "test" && Quickshell.env("LOCK_TEST_PASSWORD") !== ""
    interval: 2500
    onTriggered: { root.buffer = Quickshell.env("LOCK_TEST_PASSWORD"); root.status = "idle"; root.submit() }
  }

  // Test hook (test mode only): LOCK_TEST_KEYS="hello<<x" types one character
  // per LOCK_TEST_KEY_MS (default 250), "<" = backspace, "!" = enter; starts after 2 s.
  property int keyIndex: 0
  Timer {
    running: root.mode === "test" && (Quickshell.env("LOCK_TEST_KEYS") || "") !== ""
    interval: 2000
    onTriggered: keyTimer.start()
  }
  Timer {
    id: keyTimer
    interval: Number(Quickshell.env("LOCK_TEST_KEY_MS") || 250)
    repeat: true
    onTriggered: {
      const keys = Quickshell.env("LOCK_TEST_KEYS") || ""
      if (root.keyIndex >= keys.length) { stop(); return }
      const c = keys[root.keyIndex++]
      if (c === "<") root.buffer = root.buffer.slice(0, -1)
      else if (c === "!") root.submit()
      else { if (root.status === "failed") root.status = "idle"; root.buffer += c }
    }
  }

  WlSessionLock {
    id: lock
    locked: false
    WlSessionLockSurface {
      id: lockSurface
      color: "#ff000000"
      LockSurface { anchors.fill: parent; shell: root; screenData: root.screenConfig(lockSurface.screen) }
    }
    onLockedChanged: {
      if (!locked && !root.unlocking) { console.error("lock: compositor refused or ended the lock"); Qt.exit(3) }
    }
    onSecureChanged: if (!secure && root.unlocking) Qt.quit()
  }

  // Test mode: overlay layer surfaces, not a lock.
  Variants {
    model: root.mode === "test" ? Quickshell.screens : []
    PanelWindow {
      required property var modelData
      screen: modelData
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
      WlrLayershell.namespace: "lockscreen-test"
      color: "#ff000000"
      LockSurface { anchors.fill: parent; shell: root; screenData: root.screenConfig(modelData) }
    }
  }

  Component.onCompleted: {
    if (root.mode === "lock") lock.locked = true
  }
}
