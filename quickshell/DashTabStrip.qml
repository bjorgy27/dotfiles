// Slim strip along the top of a tabbed dashboard: tab switcher on the left,
// health and clock on the right, so the basics stay in view on every tab. (No
// now-playing line here: the bar's MusicWidget above already shows it.) The
// mouse wheel over the strip steps through the tabs too.

import QtQuick
import "templates"
import "themes"

Item {
  id: strip

  property var tabs: []             // [{ name, label, icon }]
  property int current: 0
  property real fontPx: metrics.fontSmall
  signal picked(int index)

  WheelHandler {
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    property real acc: 0
    onWheel: event => {
      acc += event.angleDelta.y + event.angleDelta.x
      if (Math.abs(acc) < 120 || strip.tabs.length < 2) return
      let n = strip.tabs.length
      strip.picked((strip.current + (acc < 0 ? 1 : -1) + n) % n)
      acc = 0
    }
  }

  // Hairline under the whole strip; the active tab's segment lights up on it.
  Rectangle {
    anchors.bottom: parent.bottom
    width: parent.width
    height: 1
    color: Theme.cardFrame
  }

  Row {
    id: tabRow
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    spacing: metrics.spacingSmall

    Repeater {
      id: tabRep
      model: strip.tabs
      Item {
        id: tab
        required property int index
        required property var modelData
        readonly property bool isCurrent: index === strip.current
        width: tabLabel.implicitWidth + metrics.spacingLarge * 2
        height: tabRow.height

        Row {
          id: tabLabel
          anchors.centerIn: parent
          spacing: metrics.spacingSmall
          Text {
            anchors.baseline: tabName.baseline
            text: (tab.index + 1 < 10 ? "0" : "") + (tab.index + 1)
            color: tab.isCurrent ? Theme.colors.accent : Theme.colors.textMuted
            font.pixelSize: Math.round(strip.fontPx * 0.78)
            font.family: Theme.fonts.mono
            font.features: { "tnum": 1, "lnum": 1 }
          }
          Text {
            id: tabName
            text: (tab.modelData.icon ? tab.modelData.icon + "  " : "") + tab.modelData.label
            color: tab.isCurrent ? Theme.colors.textPrimary : tabMouse.containsMouse ? Theme.colors.textSecondary : Theme.colors.textMuted
            font.pixelSize: strip.fontPx
            font.family: Theme.fonts.mono
            font.capitalization: Font.AllUppercase
            font.letterSpacing: Theme.titleTracking
            Behavior on color { enabled: !Theme.fading; ColorAnimation { duration: Motion.std } }
          }
        }
        MouseArea {
          id: tabMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: strip.picked(tab.index)
        }
      }
    }
  }

  // Sliding indicator under the current tab
  Rectangle {
    id: indicator
    readonly property Item target: { tabRep.count; tabRow.width; return tabRep.itemAt(strip.current) }
    visible: target !== null
    anchors.bottom: parent.bottom
    height: Math.max(2, metrics.s(2))
    radius: height / 2
    color: Theme.colors.accent
    x: target ? tabRow.x + target.x + metrics.spacingNormal : 0
    width: target ? target.width - metrics.spacingNormal * 2 : 0
    Behavior on x { NumberAnimation { duration: Motion.enter; easing.type: Motion.easeIn } }
    Behavior on width { NumberAnimation { duration: Motion.enter; easing.type: Motion.easeIn } }
  }

  // Health word (worst subsystem level reported by the cards) + clock
  Row {
    id: statusRow
    anchors.right: parent.right
    anchors.rightMargin: metrics.spacingNormal
    anchors.verticalCenter: parent.verticalCenter
    spacing: metrics.spacingLarge

    Row {
      anchors.verticalCenter: parent.verticalCenter
      spacing: metrics.spacingSmall
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Math.round(strip.fontPx * 0.5); height: width; radius: width / 2
        color: Status.color(dashState.healthLevel)
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: dashState.healthLevel > 0 && dashState.healthDetail !== "" ? dashState.healthDetail.toUpperCase() : Status.word(dashState.healthLevel)
        color: Status.color(dashState.healthLevel)
        font.pixelSize: Math.round(strip.fontPx * 0.85)
        font.family: Theme.fonts.mono
        font.letterSpacing: Theme.titleTracking
      }
    }

    Text {
      id: clock
      anchors.verticalCenter: parent.verticalCenter
      color: Theme.colors.textSecondary
      font.pixelSize: strip.fontPx
      font.family: Theme.fonts.mono
      font.features: { "tnum": 1, "lnum": 1 }
      function update() { text = Qt.formatDateTime(new Date(), "ddd dd MMM  hh:mm:ss").toUpperCase() }
      Component.onCompleted: update()
      Connections { target: dashState; function onTicked() { clock.update() } }
    }
  }
}
