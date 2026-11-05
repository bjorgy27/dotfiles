import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"
import "themes"

// Tailscale health: one row per tailnet device (online dot, name, this-machine
// marker, OS, direct/relayed path with DERP region, last seen, key-expiry
// warning under 14 days) under a header with this node's backend state and
// any Health warnings. Data: scripts/polls/tailscalepoll.sh ("q.tailscale/1").
//
// Preset options: interval (poll ms, default 30000).
DataWidget {
  id: tsWidget

  title: "󰖂  Tailscale"

  property var doc: null
  property string error: ""
  readonly property var devices: doc ? doc.devices : []
  readonly property int onlineCount: devices.filter(d => d.online).length
  readonly property var health: doc ? doc.health : []

  function ago(iso) {
    if (!iso) return ""
    const s = (Date.now() - Date.parse(iso)) / 1000
    if (isNaN(s)) return ""
    if (s < 120) return "now"
    if (s < 3600) return Math.round(s / 60) + "m ago"
    if (s < 86400) return Math.round(s / 3600) + "h ago"
    return Math.round(s / 86400) + "d ago"
  }

  function connText(d) {
    switch (d.conn) {
      case "self": return "this machine"
      case "direct": return "direct"
      case "relayed": return "relay " + (d.relay || "?")
      case "idle": return "idle" + (d.relay ? " · " + d.relay : "")
      default: return "offline"
    }
  }

  function connColor(c) {
    if (c === "direct" || c === "self") return Theme.colors.green
    if (c === "relayed") return Theme.colors.yellow
    return Theme.colors.textMuted
  }

  PollProcess {
    command: ["bash", root.home + "/.config/scripts/polls/tailscalepoll.sh"]
    interval: tsWidget.options.interval || 30000
    poll: tsWidget.visible
    onOutput: text => {
      try {
        const d = JSON.parse(text)
        if (d.schema !== "q.tailscale/1") throw new Error("unknown schema " + d.schema)
        tsWidget.doc = d
        tsWidget.error = d.ok ? "" : (d.error || "down")
      } catch (e) {
        tsWidget.error = "poll: " + e.message
      }
    }
  }

  dataContent: [
    ColumnLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: metrics.spacingSmall

      // Header: backend state, online count, health warnings.
      RowLayout {
        Layout.fillWidth: true
        spacing: metrics.spacingSmall
        Text {
          text: tsWidget.doc ? (tsWidget.doc.backendState || "?") : "…"
          color: tsWidget.doc && tsWidget.doc.ok ? Theme.colors.green : Theme.colors.red
          font.pixelSize: metrics.fontSmall; font.bold: true; font.family: "monospace"
        }
        Text {
          text: tsWidget.onlineCount + "/" + tsWidget.devices.length + " online"
          color: Theme.colors.textSecondary; font.pixelSize: metrics.fontTiny
        }
        Text {
          Layout.fillWidth: true
          horizontalAlignment: Text.AlignRight
          elide: Text.ElideRight
          text: tsWidget.error !== "" ? tsWidget.error
              : tsWidget.health.length > 0 ? "󰀦 " + tsWidget.health.join(" · ")
              : "healthy"
          color: tsWidget.error !== "" ? Theme.colors.red
               : tsWidget.health.length > 0 ? Theme.colors.yellow : Theme.colors.textMuted
          font.pixelSize: metrics.fontTiny
        }
      }

      Repeater {
        model: tsWidget.devices
        delegate: RowLayout {
          required property var modelData
          readonly property var d: modelData
          readonly property bool expiring: d.keyExpiryDays !== null && d.keyExpiryDays !== undefined && d.keyExpiryDays < 14
          Layout.fillWidth: true
          spacing: metrics.spacingSmall

          Rectangle {
            implicitWidth: metrics.s(8); implicitHeight: implicitWidth; radius: width / 2
            color: d.online ? Theme.colors.green : Theme.colors.red
            opacity: d.online ? 1 : 0.7
          }
          Text {
            text: d.name
            color: d.online ? Theme.colors.textPrimary : Theme.colors.textMuted
            font.pixelSize: metrics.fontSmall; font.bold: true; font.family: "monospace"
            elide: Text.ElideRight
            Layout.maximumWidth: metrics.s(150)
          }
          Text {
            visible: d.self
            text: "◆"
            color: Theme.colors.accent
            font.pixelSize: metrics.fontTiny
          }
          Text {
            text: d.os
            color: Theme.colors.textMuted; font.pixelSize: metrics.fontTiny
          }
          Item { Layout.fillWidth: true }
          Text {
            visible: expiring
            text: "󰌆 " + (d.keyExpiryDays <= 0 ? "key expired" : "key " + Math.ceil(d.keyExpiryDays) + "d")
            color: d.keyExpiryDays <= 3 ? Theme.colors.red : Theme.colors.orange
            font.pixelSize: metrics.fontTiny; font.bold: true
          }
          Text {
            text: tsWidget.connText(d)
            color: tsWidget.connColor(d.conn)
            font.pixelSize: metrics.fontTiny
          }
          Text {
            visible: !d.self
            text: d.online ? "now" : (tsWidget.ago(d.lastSeen) || "never")
            color: Theme.colors.textSecondary
            font.pixelSize: metrics.fontTiny
            horizontalAlignment: Text.AlignRight
            Layout.minimumWidth: metrics.s(44)
          }
        }
      }
    }
  ]
}
