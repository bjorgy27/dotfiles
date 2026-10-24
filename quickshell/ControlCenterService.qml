// Control center back end, one per shell (not per screen): the notification
// daemon (Quickshell's NotificationServer owns org.freedesktop.Notifications),
// do-not-disturb, the current panel class and the IPC.
//
// The panel itself is ControlCenterWidget.qml (in the bar's pocket, top right
// under the clock). There are no pop-ups (Vic, 2026-10-11): notifications only
// show in the panel and as the bar bell's badge, and stay until dismissed.
//
//   qs ipc call controlcenter toggle                  # focused monitor
//   qs ipc call controlcenter open notifications      # or "settings", or 1/2
//   qs ipc call controlcenter close
//   qs ipc call controlcenter toggleDnd               # prints on/off
//   qs ipc call controlcenter clear                   # dismiss every notification
//   qs ipc call controlcenter count

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications

Scope {
  id: svc

  // Panel commands for the bars: op = "toggle" | "open" | "close", tab = class name or "".
  signal command(string op, string tab)

  // === CLASSES (tabs of the panel) ===
  readonly property var classes: [
    { name: "notifications", label: "Notifications", icon: "󰂚" },
    { name: "settings", label: "Quick settings", icon: "󰒓" }
  ]
  property string tab: "notifications"
  readonly property int tabIndex: Math.max(0, classes.findIndex(c => c.name === tab))
  // Name or 1-based number -> class name ("" if unknown).
  function className(arg) {
    let n = parseInt(arg)
    if (!isNaN(n) && n >= 1 && n <= classes.length) return classes[n - 1].name
    let c = classes.find(c => c.name === String(arg).toLowerCase())
    return c ? c.name : ""
  }

  // === NOTIFICATIONS ===
  // Status chatter the bar already shows: the voice assistant's (q_voice.py)
  // Listening…/Thinking…/Transcribing…/Cancelled, all sent as app "Q" and
  // replaced in place via -r. Not kept. Only these summaries
  // are dropped; anything else from Q (replies, errors, a notify-send test)
  // is a normal notification.
  property var quietApps: ["Q"]
  property var quietSummaries: ["Listening…", "Thinking…", "Transcribing…", "Cancelled"]
  function isChatter(n) { return quietApps.indexOf(n.appName) >= 0 && quietSummaries.indexOf(n.summary) >= 0 }

  // Newest first. Tracked notifications survive a shell reload (keepOnReload).
  readonly property var list: Array.from(server.trackedNotifications.values).reverse()
  readonly property int count: list.length
  // Arrivals since the notifications class was last looked at (the bar's bell).
  // Do not disturb keeps counting; the bell just shows the badge greyed out.
  property int unread: 0
  // What the bell's badge shows: unread, minus any dismissed meanwhile.
  readonly property int waiting: Math.min(unread, count)
  // id -> arrival time (ms). Not kept across reloads; those show no age.
  property var times: ({})

  NotificationServer {
    id: server
    keepOnReload: true
    persistenceSupported: true
    bodySupported: true
    bodyMarkupSupported: true
    bodyHyperlinksSupported: true
    bodyImagesSupported: false
    actionsSupported: true
    actionIconsSupported: false
    imageSupported: true
    inlineReplySupported: false

    onNotification: n => {
      if (svc.isChatter(n)) return   // untracked = dropped
      n.tracked = true
      svc.times[n.id] = Date.now()
      // A kept Q reply that the next turn's Listening… replaces in place
      // (same -r id, so no new onNotification): drop it rather than show chatter.
      if (svc.quietApps.indexOf(n.appName) >= 0)
        n.summaryChanged.connect(() => { if (svc.isChatter(n)) Qt.callLater(() => n.dismiss()) })
      if (!svc.lookingAtList) svc.unread++
    }
  }

  // True while some monitor shows the notifications class (set by the bars).
  property bool lookingAtList: false
  onLookingAtListChanged: if (lookingAtList) unread = 0

  function dismiss(n) { if (n) n.dismiss() }
  function clearAll() {
    for (let n of list.slice()) if (n) n.dismiss()
    unread = 0
  }
  // Click on a notification: its default action if it has one.
  function activate(n) {
    if (!n) return false
    for (let a of n.actions) if (a.identifier === "default") { a.invoke(); return true }
    return false
  }
  function age(n, now) {
    let t = n ? times[n.id] : undefined
    if (!t) return ""
    let s = Math.max(0, Math.round((now - t) / 1000))
    if (s < 60) return "now"
    if (s < 3600) return Math.floor(s / 60) + "m"
    if (s < 86400) return Math.floor(s / 3600) + "h"
    return Qt.formatDateTime(new Date(t), "ddd hh:mm")
  }

  // === DO NOT DISTURB (remembered across restarts) ===
  // Only greys out the bell's badge; notifications still land in the list.
  property bool dnd: false
  function setDnd(on) {
    dnd = on
    stateFile.setText(JSON.stringify({ dnd: on }) + "\n")
  }

  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/quickshell"
  FileView {
    id: stateFile
    path: svc.stateDir + "/notifications.json"
    printErrors: false
    onLoaded: {
      try { svc.dnd = JSON.parse(text()).dnd === true } catch (e) {}
    }
    onSaveFailed: error => console.error("controlcenter: could not write " + path + " (FileViewError " + error + ")")
  }
  Process {
    command: ["mkdir", "-p", svc.stateDir]
    running: true
  }

  // === IPC ===
  IpcHandler {
    target: "controlcenter"
    function toggle(): void { svc.command("toggle", "") }
    function open(tab: string): string {
      let name = tab === "" ? "" : svc.className(tab)
      if (tab !== "" && name === "") return "unknown class: " + tab + " (" + svc.classes.map(c => c.name).join(", ") + ")"
      svc.command("open", name)
      return name || svc.tab
    }
    function close(): void { svc.command("close", "") }
    function toggleDnd(): string { svc.setDnd(!svc.dnd); return svc.dnd ? "on" : "off" }
    function clear(): void { svc.clearAll() }
    function count(): int { return svc.count }
  }
}
