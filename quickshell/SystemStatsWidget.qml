import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"
import "themes"

DataWidget {
  id: systemWidget

  title: "󰻠  System Resources"
  implicitHeight: metrics.systemWidgetHeight

  property real cpuUsage: 0
  property real ramUsed: 0
  property real ramTotal: 0
  property real ramPercent: 0
  property string diskUsed: "0G"
  property string diskTotal: "0G"
  property real diskPercent: 0

  // Bluetooth summary (one connected device, else first paired, else state)
  property string btPower: "off"
  property string btDeviceMac: ""
  property string btDeviceName: ""
  property bool btDeviceConnected: false
  property string btDeviceBattery: "NA"

  // Days since last `pacman -Syu` ("NA" if unknown)
  property string daysSinceUpgrade: "NA"

  PollProcess {
    id: systemProc
    command: ["bash", root.home + "/.config/scripts/polls/systempoll.sh"]
    interval: 3000
    onOutput: text => {
      let parts = text.split('|')
      if (parts.length >= 7) {
        systemWidget.cpuUsage = parseFloat(parts[0])
        systemWidget.ramUsed = parseFloat(parts[1])
        systemWidget.ramTotal = parseFloat(parts[2])
        systemWidget.ramPercent = parseFloat(parts[3])
        systemWidget.diskUsed = parts[4]
        systemWidget.diskTotal = parts[5]
        systemWidget.diskPercent = parseFloat(parts[6])
      }
    }
  }

  PollProcess {
    id: btProc
    command: ["bash", root.home + "/.config/scripts/polls/bluetoothpoll.sh"]
    interval: 5000
    onOutput: text => {
        let lines = text.split('\n').filter(l => l.trim())
        let pwr = "off"
        let pickMac = ""
        let pickName = ""
        let pickConnected = false
        let pickBattery = "NA"
        for (let i = 0; i < lines.length; i++) {
          let parts = lines[i].split('|')
          if (parts[0] === "power") {
            pwr = parts[1]
          } else if (parts[0] === "device" && parts.length >= 7) {
            let connected = parts[3] === "1"
            // Prefer first connected; otherwise fall back to first paired.
            if (connected && !pickConnected) {
              pickMac = parts[1]
              pickName = parts[2]
              pickConnected = true
              pickBattery = parts[5]
            } else if (!pickConnected && pickName === "") {
              pickMac = parts[1]
              pickName = parts[2]
              pickBattery = parts[5]
            }
          }
        }
        systemWidget.btPower = pwr
        systemWidget.btDeviceMac = pickMac
        systemWidget.btDeviceName = pickName
        systemWidget.btDeviceConnected = pickConnected
        systemWidget.btDeviceBattery = pickBattery
    }
  }

  Process {
    id: btToggleProc
    property string mac: ""
    property bool doConnect: false
    command: ["bluetoothctl", doConnect ? "connect" : "disconnect", mac]
    onExited: btProc.running = true
  }

  PollProcess {
    id: updatesProc
    command: ["bash", root.home + "/.config/scripts/polls/updatespoll.sh"]
    interval: 300000
    onOutput: text => systemWidget.daysSinceUpgrade = text || "NA"
  }

  dataContent: [
    ColumnLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: metrics.spacingSmall

      StatBar {
        label: "󰘚 CPU"
        valueText: systemWidget.cpuUsage.toFixed(1) + "%"
        percent: systemWidget.cpuUsage
        accentColor: Theme.colors.blue
      }

      StatBar {
        label: "󰍛 RAM"
        valueText: systemWidget.ramUsed.toFixed(1) + " / " + systemWidget.ramTotal.toFixed(1) + " GB (" + systemWidget.ramPercent.toFixed(0) + "%)"
        percent: systemWidget.ramPercent
        accentColor: Theme.colors.green
      }

      StatBar {
        label: "󰋊 Disk"
        valueText: systemWidget.diskUsed + " / " + systemWidget.diskTotal + " (" + systemWidget.diskPercent.toFixed(0) + "%)"
        percent: systemWidget.diskPercent
        accentColor: Theme.colors.pink
      }

      // Separator
      Rectangle {
        Layout.fillWidth: true
        height: 1
        color: Theme.colors.inset
      }

      // Bluetooth status row
      Rectangle {
        Layout.fillWidth: true
        implicitHeight: btRow.implicitHeight
        color: "transparent"

        RowLayout {
          id: btRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: metrics.spacingNormal

          Rectangle {
            width: metrics.s(10); height: metrics.s(10); radius: metrics.s(5)
            color: systemWidget.btPower === "unavailable" ? Theme.colors.red
                 : systemWidget.btDeviceConnected ? Theme.colors.green
                 : systemWidget.btPower === "on" ? Theme.colors.blue
                 : Theme.colors.textMuted
            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Text {
            text: "󰂯 Bluetooth"
            color: Theme.colors.textPrimary
            font.pixelSize: metrics.fontSmall
            font.bold: true
            font.family: "monospace"
            Layout.fillWidth: true
          }

          Text {
            text: {
              if (systemWidget.btPower === "unavailable") return "unavailable"
              if (systemWidget.btPower === "off") return "off"
              if (!systemWidget.btDeviceName) return "ready"
              let s = systemWidget.btDeviceName
              if (systemWidget.btDeviceConnected) {
                if (systemWidget.btDeviceBattery !== "NA") {
                  s += " · " + systemWidget.btDeviceBattery + "%"
                }
              } else {
                s += " (paired)"
              }
              return s
            }
            color: systemWidget.btPower === "unavailable" ? Theme.colors.red
                 : systemWidget.btDeviceConnected ? Theme.colors.green
                 : systemWidget.btPower === "on" ? Theme.colors.blue
                 : Theme.colors.textMuted
            font.pixelSize: metrics.fontSmall
            font.italic: true
            font.family: "monospace"

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        MouseArea {
          anchors.fill: parent
          enabled: systemWidget.btPower === "on" && systemWidget.btDeviceMac !== ""
          hoverEnabled: enabled
          acceptedButtons: Qt.LeftButton
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: {
            btToggleProc.mac = systemWidget.btDeviceMac
            btToggleProc.doConnect = !systemWidget.btDeviceConnected
            btToggleProc.running = true
          }
        }
      }

      // Last upgrade row (days since `pacman -Syu`)
      RowLayout {
        Layout.fillWidth: true
        spacing: metrics.spacingNormal

        Rectangle {
          width: metrics.s(10); height: metrics.s(10); radius: metrics.s(5)
          color: {
            let d = parseInt(systemWidget.daysSinceUpgrade)
            if (isNaN(d)) return Theme.colors.textMuted
            if (d <= 7) return Theme.colors.green
            if (d <= 30) return Theme.colors.yellow
            return Theme.colors.red
          }
          Behavior on color { ColorAnimation { duration: 200 } }
        }

        Text {
          text: "󰚰 Last Upgrade"
          color: Theme.colors.textPrimary
          font.pixelSize: metrics.fontSmall
          font.bold: true
          font.family: "monospace"
          Layout.fillWidth: true
        }

        Text {
          text: {
            let d = parseInt(systemWidget.daysSinceUpgrade)
            if (isNaN(d)) return "unknown"
            if (d === 0) return "today"
            if (d === 1) return "1 day ago"
            return d + " days ago"
          }
          color: {
            let d = parseInt(systemWidget.daysSinceUpgrade)
            if (isNaN(d)) return Theme.colors.textMuted
            if (d <= 7) return Theme.colors.green
            if (d <= 30) return Theme.colors.yellow
            return Theme.colors.red
          }
          font.pixelSize: metrics.fontSmall
          font.italic: true
          font.family: "monospace"

          Behavior on color { ColorAnimation { duration: 200 } }
        }
      }
    }
  ]
}
