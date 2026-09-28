import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"
import "themes"

ThreeRowWidget {
  id: canvasWidget

  title: "󰑴  Assignments"

  property var assignments: []
  property bool loaded: false
  property string errorText: ""

  PollProcess {
    id: canvasProc
    command: ["bash", root.home + "/.config/scripts/polls/canvaspoll.sh"]
    interval: 600000
    onOutput: text => {
      canvasWidget.loaded = true

      if (!text) {
        canvasWidget.assignments = []
        canvasWidget.errorText = ""
        return
      }

      let lines = text.split('\n').filter(l => l.trim().length > 0)

      if (lines.length === 1 && lines[0].startsWith("error|")) {
        canvasWidget.assignments = []
        canvasWidget.errorText = lines[0].slice(lines[0].indexOf('|') + 1)
        return
      }

      let list = []
      for (let line of lines) {
        let parts = line.split('|')
        if (parts.length < 6) continue
        list.push({
          course: parts[0],
          title: parts[1],
          due: parts[2],
          missing: parts[3] === "true",
          submitted: parts[4] === "true",
          url: parts.slice(5).join('|')
        })
      }
      canvasWidget.errorText = ""
      canvasWidget.assignments = list
    }
  }

  function dueLabel(iso) {
    let diffH = (new Date(iso) - new Date()) / 3600000
    if (diffH < 0) return "Overdue"
    if (diffH < 24) return Math.max(1, Math.round(diffH)) + "h"
    return Math.round(diffH / 24) + "d"
  }

  function dueColor(iso, submitted) {
    if (submitted) return Theme.colors.green
    let diffH = (new Date(iso) - new Date()) / 3600000
    if (diffH < 24) return Theme.colors.red
    if (diffH < 72) return Theme.colors.yellow
    return Theme.colors.textSecondary
  }

  middleContent: Component {
    ColumnLayout {
      spacing: metrics.spacingSmall

      Repeater {
        model: canvasWidget.assignments.slice(0, 5)

        RowLayout {
          Layout.fillWidth: true
          spacing: metrics.spacingNormal

          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Text {
              text: modelData.title
              color: Theme.colors.textPrimary
              font.pixelSize: metrics.fontLarge
              font.bold: true
              elide: Text.ElideRight
              Layout.fillWidth: true
            }

            Text {
              text: modelData.course
              color: Theme.colors.textMuted
              font.pixelSize: metrics.fontSmall
              elide: Text.ElideRight
              Layout.fillWidth: true
            }
          }

          Text {
            text: canvasWidget.dueLabel(modelData.due)
            color: canvasWidget.dueColor(modelData.due, modelData.submitted)
            font.pixelSize: metrics.fontNormal
            font.bold: true
          }
        }
      }

      Text {
        visible: canvasWidget.loaded && canvasWidget.errorText === "" && canvasWidget.assignments.length === 0
        text: "No upcoming assignments"
        color: Theme.colors.textMuted
        font.pixelSize: metrics.fontSmall
        font.italic: true
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        visible: !canvasWidget.loaded
        text: "Loading assignments..."
        color: Theme.colors.textMuted
        font.pixelSize: metrics.fontSmall
        font.italic: true
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        visible: canvasWidget.errorText !== ""
        text: canvasWidget.errorText
        color: Theme.colors.red
        font.pixelSize: metrics.fontSmall
        font.italic: true
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }

  footerContent: Component {
    RowLayout {
      spacing: metrics.spacingLarge

      RowLayout {
        spacing: metrics.spacingTiny
        Text { text: "󰀪"; color: Theme.colors.red; font.pixelSize: metrics.fontSmall; font.family: "monospace"; font.bold: true }
        Text {
          text: canvasWidget.assignments.filter(a => a.missing).length + " missing"
          color: Theme.colors.textSecondary
          font.pixelSize: metrics.fontTiny
        }
      }

      RowLayout {
        spacing: metrics.spacingTiny
        Text { text: "󰃭"; color: Theme.colors.blue; font.pixelSize: metrics.fontSmall; font.family: "monospace"; font.bold: true }
        Text {
          text: canvasWidget.assignments.length + " upcoming"
          color: Theme.colors.textSecondary
          font.pixelSize: metrics.fontTiny
        }
      }
    }
  }
}
