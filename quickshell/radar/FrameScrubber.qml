import QtQuick
import QtQuick.Shapes
import "../themes"

// Compact timeline pill for the radar frame loop: play/pause button, one
// clickable tick per frame (current = accent, nowcast = dimmer), time label.
//
//   FrameScrubber {
//     frames: weatherLayer.frames;  frameIndex: weatherLayer.frameIndex
//     playing: weatherLayer.playing;  label: weatherLayer.frameLabel
//     onPlayToggled: weatherLayer.playing ? weatherLayer.pause() : weatherLayer.play()
//     onFrameSelected: index => weatherLayer.goTo(index)
//   }
Item {
  id: scrubber

  property var frames: []
  property int frameIndex: -1
  property bool playing: false
  property string label: ""

  signal playToggled()
  signal frameSelected(int index)

  readonly property int pillHeight: metrics.s(28)
  readonly property int tickWidth: metrics.s(4)
  readonly property int tickGap: metrics.s(3)
  readonly property int tickCount: Array.isArray(frames) ? frames.length : 0

  implicitHeight: pillHeight
  implicitWidth: row.implicitWidth + metrics.spacingSmall * 2
  width: implicitWidth
  height: implicitHeight

  Rectangle {
    id: pill
    anchors.fill: parent
    radius: height / 2
    color: Theme.colors.panel
    opacity: 0.85
    border.color: Theme.colors.border
    border.width: 1
  }

  Row {
    id: row
    anchors {
      verticalCenter: parent.verticalCenter
      left: parent.left
      leftMargin: metrics.spacingSmall
    }
    spacing: metrics.spacingSmall

    // Play / pause
    Rectangle {
      id: playBtn
      width: scrubber.pillHeight - metrics.s(6)
      height: width
      radius: width / 2
      anchors.verticalCenter: parent.verticalCenter
      color: playMouse.containsMouse ? Theme.colors.inset : "transparent"

      // Play triangle (drawn, not a font glyph, so it renders on any font).
      Shape {
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: metrics.s(1)   // optical centring
        width: metrics.s(9)
        height: metrics.s(10)
        visible: !scrubber.playing
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          strokeWidth: -1
          fillColor: Theme.colors.textPrimary
          startX: 0; startY: 0
          PathLine { x: metrics.s(9); y: metrics.s(5) }
          PathLine { x: 0; y: metrics.s(10) }
          PathLine { x: 0; y: 0 }
        }
      }

      // Pause bars
      Row {
        anchors.centerIn: parent
        spacing: metrics.s(2)
        visible: scrubber.playing
        Repeater {
          model: 2
          Rectangle {
            width: metrics.s(3)
            height: metrics.s(10)
            radius: 1
            color: Theme.colors.textPrimary
          }
        }
      }

      MouseArea {
        id: playMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: scrubber.playToggled()
      }
    }

    // Ticks
    Row {
      id: ticks
      spacing: scrubber.tickGap
      anchors.verticalCenter: parent.verticalCenter

      Repeater {
        model: scrubber.tickCount

        delegate: Item {
          id: tick
          required property int index
          readonly property bool current: index === scrubber.frameIndex
          readonly property bool nowcast: scrubber.frames[index] !== undefined
                                          && scrubber.frames[index].kind === "nowcast"

          width: scrubber.tickWidth
          height: scrubber.pillHeight - metrics.s(8)

          Rectangle {
            anchors.centerIn: parent
            width: parent.width
            height: tick.current ? metrics.s(14) : (tickMouse.containsMouse ? metrics.s(11) : metrics.s(8))
            radius: width / 2
            color: tick.current
              ? Theme.colors.accent
              : (tick.nowcast ? Theme.colors.border : Theme.colors.textMuted)
            opacity: tick.current ? 1.0 : (tick.nowcast ? 0.9 : 0.7)
            Behavior on height { NumberAnimation { duration: 90 } }
          }

          MouseArea {
            id: tickMouse
            anchors.fill: parent
            anchors.leftMargin: -scrubber.tickGap / 2
            anchors.rightMargin: -scrubber.tickGap / 2
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: scrubber.frameSelected(tick.index)
          }
        }
      }
    }

    // Time label
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: scrubber.label.length > 0
      text: scrubber.label
      color: Theme.colors.textSecondary
      font.pixelSize: metrics.fontTiny
      font.family: "monospace"
      font.bold: true
      rightPadding: metrics.spacingTiny
    }
  }
}
