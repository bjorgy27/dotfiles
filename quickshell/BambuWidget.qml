import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"
import "themes"

// Bambu Lab print progress, read straight off the printer over LAN MQTT.
// Needs ~/.config/bambu.conf; without it the widget shows the setup hint.
ThreeRowWidget {
  id: printer

  property string printState: "..."
  property string jobName: ""
  property string errorText: ""
  property int percent: 0
  property int remainingMin: 0
  property int layerNum: 0
  property int totalLayers: 0
  property int nozzle: 0
  property int nozzleTarget: 0
  property int bed: 0
  property int bedTarget: 0

  readonly property bool printing: printState === "RUNNING" || printState === "PAUSE"

  title: "PRINTER  " + stateLabel(printState)

  function stateLabel(s) {
    if (s === "RUNNING") return "printing"
    if (s === "PAUSE") return "paused"
    if (s === "FINISH") return "done"
    if (s === "FAILED") return "failed"
    if (s === "IDLE") return "idle"
    if (s === "PREPARE" || s === "SLICING") return "preparing"
    return s.toLowerCase()
  }

  function stateColor(s) {
    if (s === "RUNNING") return Theme.colors.green
    if (s === "PAUSE") return Theme.colors.yellow
    if (s === "FINISH") return Theme.colors.teal
    if (s === "FAILED") return Theme.colors.red
    return Theme.colors.textMuted
  }

  // "3h 12m" / "45m", from the printer's own estimate in minutes.
  function eta(minutes) {
    if (minutes <= 0) return "--"
    if (minutes < 60) return minutes + "m"
    return Math.floor(minutes / 60) + "h " + (minutes % 60) + "m"
  }

  PollProcess {
    command: ["bash", root.home + "/.config/scripts/polls/bambupoll.sh"]
    interval: 10000
    onOutput: text => {
      const parts = text.split('|')
      if (parts[0] === "ok" && parts.length >= 11) {
        printer.errorText = ""
        printer.printState = parts[1]
        printer.percent = parseInt(parts[2])
        printer.remainingMin = parseInt(parts[3])
        printer.layerNum = parseInt(parts[4])
        printer.totalLayers = parseInt(parts[5])
        printer.nozzle = parseInt(parts[6])
        printer.nozzleTarget = parseInt(parts[7])
        printer.bed = parseInt(parts[8])
        printer.bedTarget = parseInt(parts[9])
        printer.jobName = parts.slice(10).join('|')
      } else {
        printer.printState = "offline"
        printer.errorText = parts.length > 1 ? parts[1] : "no data"
      }
    }
  }

  middleContent: Component {
    ColumnLayout {
      spacing: metrics.spacingSmall

      Text {
        Layout.fillWidth: true
        text: printer.errorText !== "" ? printer.errorText
            : (printer.jobName !== "" ? printer.jobName : "no job")
        color: printer.errorText !== "" ? Theme.colors.red : Theme.colors.textSecondary
        font.pixelSize: metrics.fontSmall
        font.family: "Noto Sans"
        elide: Text.ElideRight
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: metrics.spacingNormal

        Text {
          text: printer.percent + "%"
          color: printer.stateColor(printer.printState)
          font.pixelSize: metrics.fontHuge
          font.bold: true
          font.family: "Noto Sans"
          Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          spacing: metrics.spacingTiny

          // Progress fills toward the state colour rather than warning red:
          // a print at 95% is good news, unlike a disk at 95%.
          Rectangle {
            Layout.fillWidth: true
            height: metrics.s(8)
            radius: metrics.s(4)
            color: Theme.colors.inset
            Rectangle {
              width: parent.width * Math.max(0, Math.min(1, printer.percent / 100))
              height: parent.height
              radius: metrics.s(4)
              color: printer.stateColor(printer.printState)
              Behavior on width { NumberAnimation { duration: 200 } }
            }
          }

          Text {
            text: printer.printing ? printer.eta(printer.remainingMin) + " left" : ""
            color: Theme.colors.textSecondary
            font.pixelSize: metrics.fontTiny
            font.family: "Noto Sans"
          }
        }
      }
    }
  }

  footerContent: Component {
    RowLayout {
      spacing: metrics.spacingLarge

      RowLayout {
        spacing: metrics.spacingTiny
        Text { text: "LAYER"; color: Theme.colors.lavender; font.pixelSize: metrics.fontTiny; font.bold: true; font.family: "monospace" }
        Text {
          text: printer.totalLayers > 0 ? printer.layerNum + "/" + printer.totalLayers : "--"
          color: Theme.colors.textSecondary
          font.pixelSize: metrics.fontTiny
        }
      }

      RowLayout {
        spacing: metrics.spacingTiny
        Text { text: "NOZ"; color: Theme.colors.orange; font.pixelSize: metrics.fontTiny; font.bold: true; font.family: "monospace" }
        Text {
          text: printer.nozzle + "°" + (printer.nozzleTarget > 0 ? "/" + printer.nozzleTarget + "°" : "")
          color: Theme.colors.textSecondary
          font.pixelSize: metrics.fontTiny
        }
      }

      RowLayout {
        spacing: metrics.spacingTiny
        Text { text: "BED"; color: Theme.colors.blue; font.pixelSize: metrics.fontTiny; font.bold: true; font.family: "monospace" }
        Text {
          text: printer.bed + "°" + (printer.bedTarget > 0 ? "/" + printer.bedTarget + "°" : "")
          color: Theme.colors.textSecondary
          font.pixelSize: metrics.fontTiny
        }
      }
    }
  }
}
