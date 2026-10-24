// Control center → Quick settings: toggles (Wi-Fi, Bluetooth, do not
// disturb, microphone), output and input volume with a device picker, paired
// Bluetooth devices and nearby Wi-Fi networks. Audio and Bluetooth come from
// Quickshell's services; Wi-Fi from nmcli (scripts/polls/wifipoll.sh), polled
// only while this page is showing.
//
// Turning Wi-Fi off takes a second click within 3 s (on a Wi-Fi-only machine
// it drops the network, remote sessions included). The connected network is
// not clickable for the same reason; known networks connect with their saved
// profile, open ones directly, and secured unknown ones need nm-applet.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Bluetooth
import "themes"

Item {
  id: qs
  anchors.fill: parent

  property var service
  property bool active: false     // page showing: polls Wi-Fi, tracks every audio device

  // === AUDIO ===
  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var source: Pipewire.defaultAudioSource
  readonly property var sinks: Pipewire.nodes.values.filter(n => n.audio && n.isSink && !n.isStream)
  readonly property var sources: Pipewire.nodes.values.filter(n => n.audio && !n.isSink && !n.isStream && !(n.name ?? "").endsWith(".monitor"))
  PwObjectTracker { objects: qs.active ? qs.sinks.concat(qs.sources) : [qs.sink, qs.source] }
  function nodeLabel(n) { return n ? (n.nickname || n.description || n.name || "Unknown") : "None" }

  // === BLUETOOTH ===
  readonly property var adapter: Bluetooth.defaultAdapter
  readonly property var btDevices: adapter ? adapter.devices.values.filter(d => d.paired || d.connected)
      .sort((a, b) => (b.connected - a.connected) || a.name.localeCompare(b.name)) : []
  readonly property int btConnected: btDevices.filter(d => d.connected).length

  // === WI-FI (nmcli) ===
  property string wifiRadio: ""   // "enabled" | "disabled" | "missing" | "" (not read yet)
  property var networks: []       // [{ ssid, inUse, signal, known, security }]
  readonly property var activeNet: networks.find(n => n.inUse) ?? null
  readonly property bool wifiOn: wifiRadio === "enabled"
  property bool wifiConfirm: false
  Timer { id: wifiConfirmTimer; interval: 3000; onTriggered: qs.wifiConfirm = false }

  Process {
    id: wifiPoll
    command: ["bash", Quickshell.env("HOME") + "/.config/scripts/polls/wifipoll.sh"]
    running: qs.active
    stdout: StdioCollector {
      onStreamFinished: {
        let radio = "", nets = []
        for (let line of this.text.split("\n")) {
          let f = line.split("\t")
          if (f[0] === "radio") radio = f[1]
          else if (f[0] === "net" && f.length >= 6)
            nets.push({ inUse: f[1] === "1", signal: parseInt(f[2]) || 0, known: f[3] === "1", security: f[4], ssid: f.slice(5).join("\t") })
        }
        nets.sort((a, b) => (b.inUse - a.inUse) || (b.known - a.known) || (b.signal - a.signal))
        qs.wifiRadio = radio
        qs.networks = nets
      }
    }
  }
  Timer { interval: 8000; repeat: true; running: qs.active; onTriggered: wifiPoll.running = true }
  // nmcli actions; re-read right after.
  Process {
    id: nmAction
    stdout: StdioCollector { onStreamFinished: wifiPoll.running = true }
    stderr: StdioCollector { onStreamFinished: if (this.text.trim() !== "") console.warn("controlcenter: nmcli: " + this.text.trim()) }
  }
  function nm(args) { nmAction.command = ["nmcli"].concat(args); nmAction.running = true }
  function wifiIcon(signal) { return signal > 75 ? "󰤨" : signal > 50 ? "󰤥" : signal > 25 ? "󰤢" : "󰤟" }

  Flickable {
    id: flick
    anchors.fill: parent
    contentHeight: col.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    ColumnLayout {
      id: col
      width: flick.width
      spacing: metrics.spacingNormal

      // --- Toggle tiles ---
      GridLayout {
        Layout.fillWidth: true
        columns: 2
        rowSpacing: metrics.spacingSmall
        columnSpacing: metrics.spacingSmall

        Tile {
          icon: !qs.wifiOn ? "󰤮" : qs.activeNet ? qs.wifiIcon(qs.activeNet.signal) : "󰤯"
          label: "Wi-Fi"
          detail: qs.wifiConfirm ? "Click again to turn off" : qs.wifiRadio === "missing" ? "nmcli not found" : !qs.wifiOn ? "Off" : qs.activeNet ? qs.activeNet.ssid : "Not connected"
          on: qs.wifiOn
          warn: qs.wifiConfirm
          enabled: qs.wifiRadio === "enabled" || qs.wifiRadio === "disabled"
          onClicked: {
            if (!qs.wifiOn) { qs.nm(["radio", "wifi", "on"]); return }
            if (!qs.wifiConfirm) { qs.wifiConfirm = true; wifiConfirmTimer.restart(); return }
            qs.wifiConfirm = false
            qs.nm(["radio", "wifi", "off"])
          }
        }
        Tile {
          icon: !qs.adapter ? "󰂲" : !qs.adapter.enabled ? "󰂲" : qs.btConnected > 0 ? "󰂱" : "󰂯"
          label: "Bluetooth"
          detail: !qs.adapter ? "No adapter" : !qs.adapter.enabled ? "Off" : qs.btConnected > 0 ? (qs.btConnected === 1 ? qs.btDevices[0].name : qs.btConnected + " connected") : "On"
          on: qs.adapter?.enabled ?? false
          enabled: qs.adapter !== null
          onClicked: qs.adapter.enabled = !qs.adapter.enabled
        }
        Tile {
          icon: qs.service.dnd ? "󰂛" : "󰂚"
          label: "Do not disturb"
          detail: qs.service.dnd ? "Bell badge muted" : "Off"
          on: qs.service.dnd
          onClicked: qs.service.setDnd(!qs.service.dnd)
        }
        Tile {
          readonly property bool muted: qs.source?.audio?.muted ?? false
          icon: muted ? "󰍭" : "󰍬"
          label: "Microphone"
          detail: !qs.source ? "No input" : muted ? "Muted" : "Live"
          on: qs.source !== null && !muted
          enabled: qs.source?.audio !== undefined && qs.source?.audio !== null
          onClicked: qs.source.audio.muted = !qs.source.audio.muted
        }
      }

      // --- Audio ---
      Section { title: "Output"; detail: qs.nodeLabel(qs.sink) }
      VolumeRow { node: qs.sink; icon: (qs.sink?.audio?.muted ?? false) ? "󰖁" : "󰕾"; accent: Theme.colors.violet }
      DeviceList { nodes: qs.sinks; current: qs.sink; onPicked: node => Pipewire.preferredDefaultAudioSink = node }

      Section { title: "Input"; detail: qs.nodeLabel(qs.source) }
      VolumeRow { node: qs.source; icon: (qs.source?.audio?.muted ?? false) ? "󰍭" : "󰍬"; accent: Theme.colors.teal }
      DeviceList { nodes: qs.sources; current: qs.source; onPicked: node => Pipewire.preferredDefaultAudioSource = node }

      // --- Bluetooth devices ---
      Section {
        visible: (qs.adapter?.enabled ?? false) && qs.btDevices.length > 0
        title: "Bluetooth"
        detail: qs.btDevices.length + " paired"
      }
      Repeater {
        model: (qs.adapter?.enabled ?? false) ? qs.btDevices : []
        ListRow {
          required property var modelData
          readonly property bool busy: modelData.state === BluetoothDeviceState.Connecting || modelData.state === BluetoothDeviceState.Disconnecting
          icon: modelData.connected ? "󰂱" : "󰂯"
          label: modelData.name || modelData.address
          detail: busy ? (modelData.state === BluetoothDeviceState.Connecting ? "connecting…" : "disconnecting…")
              : (modelData.connected ? "connected" : "") + (modelData.batteryAvailable ? (modelData.connected ? "  ·  " : "") + "󰁹 " + Math.round(modelData.battery * 100) + "%" : "")
          on: modelData.connected
          onClicked: if (!busy) { if (modelData.connected) modelData.disconnect(); else modelData.connect() }
        }
      }

      // --- Wi-Fi networks ---
      Section {
        visible: qs.wifiOn && qs.networks.length > 0
        title: "Wi-Fi"
        detail: qs.networks.length + " nearby"
      }
      Repeater {
        model: qs.wifiOn ? qs.networks.slice(0, 8) : []
        ListRow {
          required property var modelData
          readonly property bool open: modelData.security === "" || modelData.security === "--"
          icon: qs.wifiIcon(modelData.signal)
          label: modelData.ssid
          detail: modelData.inUse ? "connected" : modelData.known ? "saved" : open ? "open" : "󰌾 " + modelData.security
          on: modelData.inUse
          dim: !modelData.inUse && !modelData.known && !open
          clickable: !modelData.inUse && (modelData.known || open)
          onClicked: qs.nm(modelData.known ? ["connection", "up", "id", modelData.ssid] : ["device", "wifi", "connect", modelData.ssid])
        }
      }

      Item { Layout.preferredHeight: metrics.spacingSmall }
    }
  }

  // ===================== pieces =====================

  component Tile: Rectangle {
    id: tile
    property string icon: ""
    property string label: ""
    property string detail: ""
    property bool on: false
    property bool warn: false
    signal clicked()
    Layout.fillWidth: true
    Layout.preferredHeight: metrics.s(58)
    radius: metrics.radiusNormal
    opacity: enabled ? 1 : 0.45
    color: warn ? Qt.rgba(Theme.colors.red.r, Theme.colors.red.g, Theme.colors.red.b, 0.22)
        : on ? Qt.rgba(Theme.colors.accent.r, Theme.colors.accent.g, Theme.colors.accent.b, tileMouse.containsMouse ? 0.3 : 0.2)
        : tileMouse.containsMouse ? Theme.colors.inset : Qt.rgba(Theme.colors.inset.r, Theme.colors.inset.g, Theme.colors.inset.b, 0.55)
    border.width: Theme.bw(1)
    border.color: warn ? Theme.colors.red : on ? Theme.colors.accent : Qt.rgba(Theme.colors.border.r, Theme.colors.border.g, Theme.colors.border.b, 0.5)
    Behavior on color { enabled: !Theme.fading; ColorAnimation { duration: 180 } }

    RowLayout {
      anchors { fill: parent; leftMargin: metrics.spacingLarge; rightMargin: metrics.spacingNormal }
      spacing: metrics.spacingNormal
      Text {
        text: tile.icon
        color: tile.warn ? Theme.colors.red : tile.on ? Theme.colors.accent : Theme.colors.textSecondary
        font.pixelSize: metrics.fontXL * 0.75
        font.family: Theme.fonts.mono
      }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0
        Text {
          Layout.fillWidth: true
          text: tile.label
          color: Theme.colors.textPrimary
          font.pixelSize: metrics.fontSmall
          font.family: Theme.fonts.ui
          font.bold: true
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          text: tile.detail
          color: tile.warn ? Theme.colors.red : Theme.colors.textMuted
          font.pixelSize: metrics.fontTiny
          font.family: Theme.fonts.ui
          elide: Text.ElideRight
        }
      }
    }
    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: tile.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: tile.clicked()
    }
  }

  component Section: RowLayout {
    property string title: ""
    property string detail: ""
    Layout.fillWidth: true
    Layout.topMargin: metrics.spacingSmall
    spacing: metrics.spacingNormal
    Text {
      text: parent.title
      color: Theme.colors.textMuted
      font.pixelSize: metrics.fontTiny
      font.family: Theme.fonts.mono
      font.capitalization: Font.AllUppercase
      font.letterSpacing: 1.5
    }
    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Qt.rgba(Theme.colors.border.r, Theme.colors.border.g, Theme.colors.border.b, 0.5) }
    Text {
      Layout.maximumWidth: col.width * 0.55
      text: parent.detail
      color: Theme.colors.textSecondary
      font.pixelSize: metrics.fontTiny
      font.family: Theme.fonts.ui
      elide: Text.ElideRight
    }
  }

  // Mute button + slider + percent for one audio node (0-100 %, wheel steps 5 %).
  component VolumeRow: RowLayout {
    id: vrow
    property var node: null
    property string icon: ""
    property color accent: Theme.colors.accent
    readonly property var audio: node?.audio ?? null
    readonly property real value: audio?.volume ?? 0
    function set(v) { if (audio) { audio.volume = Math.max(0, Math.min(1, v)); if (audio.muted && v > 0) audio.muted = false } }
    Layout.fillWidth: true
    spacing: metrics.spacingNormal
    enabled: audio !== null
    opacity: enabled ? 1 : 0.45

    Text {
      text: vrow.icon
      color: vrow.audio?.muted ? Theme.colors.textMuted : vrow.accent
      font.pixelSize: metrics.fontLarge
      font.family: Theme.fonts.mono
      Layout.preferredWidth: metrics.s(22)
      MouseArea {
        anchors.fill: parent
        anchors.margins: -metrics.spacingTiny
        cursorShape: Qt.PointingHandCursor
        onClicked: if (vrow.audio) vrow.audio.muted = !vrow.audio.muted
      }
    }
    Item {
      id: track
      Layout.fillWidth: true
      Layout.preferredHeight: metrics.s(22)
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: metrics.s(6)
        radius: height / 2
        color: Theme.colors.inset
        Rectangle {
          width: Math.max(height, parent.width * Math.min(1, vrow.value))
          height: parent.height
          radius: height / 2
          color: vrow.audio?.muted ? Theme.colors.textMuted : vrow.accent
          Behavior on width { enabled: !drag.pressed; NumberAnimation { duration: 90 } }
        }
      }
      Rectangle {
        x: Math.min(1, vrow.value) * (parent.width - width)
        anchors.verticalCenter: parent.verticalCenter
        width: metrics.s(14)
        height: width
        radius: width / 2
        color: Theme.colors.textPrimary
        scale: drag.pressed || drag.containsMouse ? 1.15 : 1
        Behavior on scale { NumberAnimation { duration: 90 } }
      }
      MouseArea {
        id: drag
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        function apply(mx) { vrow.set(mx / width) }
        onPressed: mouse => apply(mouse.x)
        onPositionChanged: mouse => { if (pressed) apply(mouse.x) }
        onWheel: wheel => vrow.set(vrow.value + (wheel.angleDelta.y > 0 ? 0.05 : -0.05))
      }
    }
    Text {
      Layout.preferredWidth: metrics.s(40)
      horizontalAlignment: Text.AlignRight
      text: Math.round(vrow.value * 100) + "%"
      color: Theme.colors.textSecondary
      font.pixelSize: metrics.fontSmall
      font.family: Theme.fonts.mono
      font.features: { "tnum": 1, "lnum": 1 }
    }
  }

  // Device choice, only when there is more than one.
  component DeviceList: ColumnLayout {
    id: dlist
    property var nodes: []
    property var current: null
    signal picked(var node)
    Layout.fillWidth: true
    visible: nodes.length > 1
    spacing: metrics.s(2)
    Repeater {
      model: dlist.nodes
      ListRow {
        required property var modelData
        icon: modelData === dlist.current ? "󰄴" : "󰄰"
        label: qs.nodeLabel(modelData)
        on: modelData === dlist.current
        clickable: modelData !== dlist.current
        compact: true
        onClicked: dlist.picked(modelData)
      }
    }
  }

  component ListRow: Rectangle {
    id: lrow
    property string icon: ""
    property string label: ""
    property string detail: ""
    property bool on: false
    property bool dim: false
    property bool clickable: true
    property bool compact: false
    signal clicked()
    Layout.fillWidth: true
    Layout.preferredHeight: compact ? metrics.s(28) : metrics.s(36)
    radius: metrics.radiusSmall
    color: rowMouse.containsMouse && clickable ? Theme.colors.inset : "transparent"
    opacity: dim ? 0.5 : 1
    Behavior on color { enabled: !Theme.fading; ColorAnimation { duration: 90 } }
    RowLayout {
      anchors { fill: parent; leftMargin: metrics.spacingSmall; rightMargin: metrics.spacingNormal }
      spacing: metrics.spacingNormal
      Text {
        Layout.preferredWidth: metrics.s(22)
        text: lrow.icon
        color: lrow.on ? Theme.colors.accent : Theme.colors.textSecondary
        font.pixelSize: lrow.compact ? metrics.fontNormal : metrics.fontLarge
        font.family: Theme.fonts.mono
      }
      Text {
        Layout.fillWidth: true
        text: lrow.label
        color: lrow.on ? Theme.colors.textPrimary : Theme.colors.textSecondary
        font.pixelSize: lrow.compact ? metrics.fontTiny : metrics.fontSmall
        font.family: Theme.fonts.ui
        font.bold: lrow.on
        elide: Text.ElideRight
      }
      Text {
        visible: text !== ""
        text: lrow.detail
        color: lrow.on ? Theme.colors.accent : Theme.colors.textMuted
        font.pixelSize: metrics.fontTiny
        font.family: Theme.fonts.ui
      }
    }
    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: lrow.clickable
      cursorShape: Qt.PointingHandCursor
      onClicked: lrow.clicked()
    }
  }
}
