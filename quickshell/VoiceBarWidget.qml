import QtQuick
import Quickshell
import Quickshell.Io
import "themes"

// Voice assistant indicator (scripts/q_voice.sh, SUPER+T): lives in the bar's
// center slot (where the music player sits) while a voice turn is in flight, then
// hands the slot back. State comes from $XDG_RUNTIME_DIR/q-voice/state.json
// via root.voiceState/voiceText/voiceReply.
Item {
  id: voiceBar

  property bool isVertical: false
  // shown during a voice turn, and always while the chat panel is open (the panel keeps its status here)
  property bool showWidget: root.voiceEnabled && ((root.voiceActive && (bar.state === "normal" || bar.state === "dashboard"))
                                                || bar.state === "q_chat")
  visible: showWidget
  implicitWidth: isVertical ? parent.width : metrics.s(400)
  implicitHeight: metrics.s(30)

  readonly property string st: root.voiceState
  readonly property bool live: st === "listening" || st === "speaking"
  readonly property color stateColor: {
    switch (st) {
    case "listening":    return Theme.colors.teal;
    case "transcribing": return Theme.colors.lavender;
    case "thinking":     return Theme.colors.violet;
    case "speaking":     return Theme.colors.blue;
    case "error":        return Theme.colors.red;
    default:             return Theme.colors.textMuted;
    }
  }
  readonly property string icon: {
    switch (st) {
    case "listening":    return "󰍬";
    case "transcribing": return "󰦨";
    case "thinking":     return "󰧑";
    case "speaking":     return "󰕾";
    case "error":        return "󰍭";
    default:             return "󰚩";
    }
  }
  // Also shown while the chat panel (q_chat) is open: the panel starts below the bar strip and
  // leaves status to this indicator.
  // Status only: what was said and the reply live in the chat log (QChatWidget, SUPER+A).
  readonly property string line: {
    switch (st) {
    case "listening":    return "listening";
    case "transcribing": return "decoding";
    case "thinking":     return "thinking";
    case "speaking":     return "speaking";
    case "error":        return "didn't catch that";
    default:             return bar.state === "q_chat" ? "ready" : "";
    }
  }

  // level history comes from root (shared with the chat panel header, see shell.qml)
  readonly property var history: root.voiceLevels
  readonly property int barCount: root.voiceLevels.length

  Row {
    anchors.centerIn: parent
    spacing: metrics.s(8)
    width: Math.min(implicitWidth, voiceBar.width - metrics.s(20))

    Text {
      id: iconText
      anchors.verticalCenter: parent.verticalCenter
      text: voiceBar.icon
      color: voiceBar.stateColor
      font.family: "monospace"
      font.pixelSize: metrics.fontSmall
      Behavior on color { ColorAnimation { duration: 250 } }
      SequentialAnimation on opacity {
        running: voiceBar.st === "listening" && voiceBar.visible
        loops: Animation.Infinite
        NumberAnimation { to: 0.35; duration: 800; easing.type: Easing.InOutSine }
        NumberAnimation { to: 1.0; duration: 800; easing.type: Easing.InOutSine }
      }
    }

    // tiny inline level bars
    Row {
      anchors.verticalCenter: parent.verticalCenter
      spacing: metrics.s(2)
      visible: !voiceBar.isVertical
      Repeater {
        model: voiceBar.barCount
        Rectangle {
          required property int index
          readonly property real amp: voiceBar.history[index] || 0
          anchors.verticalCenter: parent.verticalCenter
          width: metrics.s(2)
          height: metrics.s(2) + amp * metrics.s(12)
          radius: 1
          color: voiceBar.stateColor
          opacity: 0.25 + amp * 0.65
          Behavior on height { NumberAnimation { duration: 70 } }
        }
      }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: !voiceBar.isVertical
      text: voiceBar.line
      color: voiceBar.st === "speaking" || voiceBar.st === "idle" ? Theme.colors.textSecondary : voiceBar.stateColor
      font.pixelSize: metrics.fontSmall
      elide: Text.ElideRight
      width: Math.min(implicitWidth, voiceBar.width - metrics.s(20) - iconText.width - metrics.s(8) - (voiceBar.barCount * metrics.s(4)) - metrics.s(8))
      Behavior on color { ColorAnimation { duration: 250 } }
    }
  }
}
