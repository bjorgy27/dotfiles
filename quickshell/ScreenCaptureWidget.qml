import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"
import "themes"

Item {
  id: root

  property string home: Quickshell.env("HOME")
  property string monitorName: ""
  property bool isRecording: false
  property bool isVertical: false

  // Poll wf-recorder process to sync state (catches keybind-triggered recordings)
  PollProcess {
    id: recordingPollProc
    command: ["pgrep", "-x", "wf-recorder"]
    interval: 1000
    onOutput: text => root.isRecording = (text.length > 0)
  }

  implicitWidth: row.implicitWidth
  implicitHeight: isVertical ? row.implicitHeight : (parent ? parent.height : 30)

  property string screenshotDir: root.home + "/Pictures/Screenshots"
  property string recordingDir: root.home + "/Videos/Recordings"

  Process {
    id: screenshotProc
    command: ["bash", root.home + "/.config/scripts/hyprland_capture_full.sh"]
    running: false
  }

  Process {
    id: screenshotRegionProc
    command: ["hyprctl", "dispatch", 'hl.dsp.exec_cmd("bash ' + root.home + '/.config/scripts/hyprland_capture_partial.sh")']
    running: false
  }

  Process {
    id: recordStartFullProc
    command: ["hyprctl", "dispatch", 'hl.dsp.exec_cmd("bash ' + root.home + '/.config/scripts/hyprland_record_full.sh")']
    running: false
  }

  Process {
    id: recordStartRegionProc
    command: ["hyprctl", "dispatch", 'hl.dsp.exec_cmd("bash ' + root.home + '/.config/scripts/hyprland_record_region.sh")']
    running: false
  }

  Process {
    id: recordStopProc
    command: ["bash", root.home + "/.config/scripts/hyprland_record_stop.sh"]
    running: false
    onRunningChanged: {
      if (!running) {
        root.isRecording = false
      }
    }
  }

  Grid {
    id: row
    anchors.centerIn: parent
    columns: root.isVertical ? 1 : 99
    rowSpacing: metrics.spacingSmall
    columnSpacing: metrics.spacingSmall
    horizontalItemAlignment: Grid.AlignHCenter
    verticalItemAlignment: Grid.AlignVCenter

    Text {
      id: screenshotBtn
      text: "\uf030"
      color: screenshotMouse.containsMouse ? Theme.colors.cyan : Theme.colors.textSecondary
      font.pixelSize: metrics.fontNormal
      font.family: "monospace"
      font.bold: true

      Behavior on color { ColorAnimation { duration: 100 } }

      MouseArea {
        id: screenshotMouse
        anchors.fill: parent
        anchors.margins: -metrics.s(4)
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor

        onClicked: (mouse) => {
          if (mouse.button === Qt.RightButton) {
            screenshotRegionProc.running = true
          } else {
            screenshotProc.running = true
          }
        }
      }
    }

    Text {
      id: recordBtn
      text: root.isRecording ? "\uf04d" : "\uf111"
      color: {
        if (root.isRecording) return pulseAnim.pulseColor
        return recordMouse.containsMouse ? Theme.colors.red : Theme.colors.textSecondary
      }
      font.pixelSize: root.isRecording ? metrics.fontNormal : metrics.s(10)
      font.family: "monospace"
      font.bold: true

      Timer {
        id: pulseAnim
        property color pulseColor: Theme.colors.red
        property bool bright: true
        interval: 700
        running: root.isRecording
        repeat: true
        onTriggered: {
          bright = !bright
          pulseColor = bright ? Theme.colors.red : Qt.darker(Theme.colors.red, 2.0)
        }
        onRunningChanged: {
          if (running) { bright = true; pulseColor = Theme.colors.red }
        }
      }

      Behavior on color { ColorAnimation { duration: 200 } }

      MouseArea {
        id: recordMouse
        anchors.fill: parent
        anchors.margins: -metrics.s(4)
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor

        onClicked: (mouse) => {
          if (root.isRecording) {
            recordStopProc.running = true
          } else {
            root.isRecording = true
            if (mouse.button === Qt.RightButton) {
              recordStartRegionProc.running = true
            } else {
              recordStartFullProc.running = true
            }
          }
        }
      }
    }
  }
}
