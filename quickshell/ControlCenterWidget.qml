// Control center: the bar's pocket opened at the far end (top right, under
// the clock) instead of the middle. One page per class from
// ControlCenterService.classes, switched with the strip on top (click, mouse
// wheel, or `qs ipc call controlcenter open <class>`):
//   Notifications  - the notification list, do not disturb, clear all
//   Quick settings - audio out/in, Wi-Fi, Bluetooth (QuickSettings.qml)
// Toggle: quickshell:toggleControlCenter / toggleNotifications, or a click on
// the bar's clock or bell. Escape closes it once it has keyboard focus.

import QtQuick
import QtQuick.Layouts
import "themes"

Item {
  id: cc

  required property var service
  readonly property bool isOpen: bar.state === "control_center"
  visible: isOpen

  // Pocket size (read by the bar's "control_center" state in shell.qml).
  readonly property real panelWidth: metrics.s(460)
  readonly property real panelHeight: Math.min(metrics.s(660), metrics.isVertical ? metrics.longPct(70) : metrics.crossPct(72))
  readonly property real topPad: metrics.s(5)

  anchors {
    top: metrics.isVertical ? undefined : parent.top
    left: metrics.isVertical ? parent.left : undefined
    topMargin: metrics.isVertical ? 0 : bar.barThickness + topPad
    leftMargin: metrics.isVertical ? bar.barThickness + topPad : 0
    horizontalCenter: metrics.isVertical ? undefined : parent.horizontalCenter
    verticalCenter: metrics.isVertical ? parent.verticalCenter : undefined
  }
  width: metrics.isVertical ? parent.width - bar.barThickness - topPad - bar.dropdownWidgetPadding : parent.width - bar.dropdownWidgetPadding * 2
  height: metrics.isVertical ? parent.height - bar.dropdownWidgetPadding * 2 : parent.height - bar.barThickness - topPad - bar.dropdownWidgetPadding

  // Contents fade in behind the pocket morph (same timing as the dashboard cards).
  opacity: 0
  onIsOpenChanged: {
    if (isOpen) { opacity = 0; fadeIn.restart(); forceActiveFocus() }
    cc.now = Date.now()
  }
  NumberAnimation { id: fadeIn; target: cc; property: "opacity"; to: 1; duration: 240; easing.type: Easing.OutCubic }

  focus: isOpen
  Keys.onEscapePressed: bar.state = "normal"
  Keys.onTabPressed: cc.step(1)
  Keys.onBacktabPressed: cc.step(-1)

  // Age labels tick while open.
  property real now: Date.now()
  Timer { interval: 15000; repeat: true; running: cc.isOpen; onTriggered: cc.now = Date.now() }

  property int dir: 1
  function pick(i) {
    if (i === service.tabIndex || i < 0 || i >= service.classes.length) return
    dir = i > service.tabIndex ? 1 : -1
    service.tab = service.classes[i].name
  }
  function step(d) {
    let n = service.classes.length
    pick((service.tabIndex + d + n) % n)
  }

  // === CLASS STRIP ===
  Item {
    id: strip
    width: parent.width
    height: metrics.s(30)

    WheelHandler {
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      property real acc: 0
      onWheel: event => {
        acc += event.angleDelta.y + event.angleDelta.x
        if (Math.abs(acc) < 120) return
        cc.step(acc < 0 ? 1 : -1)
        acc = 0
      }
    }

    Rectangle {
      anchors.bottom: parent.bottom
      width: parent.width
      height: 1
      color: Qt.rgba(Theme.colors.border.r, Theme.colors.border.g, Theme.colors.border.b, 0.5)
    }

    Row {
      id: tabRow
      anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
      spacing: metrics.spacingSmall
      Repeater {
        id: tabRep
        model: cc.service.classes
        Item {
          id: tabItem
          required property int index
          required property var modelData
          readonly property bool isCurrent: index === cc.service.tabIndex
          width: tabLabel.implicitWidth + metrics.spacingLarge * 2
          height: tabRow.height
          Row {
            id: tabLabel
            anchors.centerIn: parent
            spacing: metrics.spacingSmall
            Text {
              anchors.baseline: tabName.baseline
              text: "0" + (tabItem.index + 1)
              color: tabItem.isCurrent ? Theme.colors.accent : Theme.colors.textMuted
              font.pixelSize: Math.round(metrics.fontSmall * 0.78)
              font.family: Theme.fonts.mono
              font.features: { "tnum": 1, "lnum": 1 }
            }
            Text {
              id: tabName
              text: tabItem.modelData.icon + "  " + tabItem.modelData.label
              color: tabItem.isCurrent ? Theme.colors.textPrimary : tabMouse.containsMouse ? Theme.colors.textSecondary : Theme.colors.textMuted
              font.pixelSize: metrics.fontSmall
              font.family: Theme.fonts.mono
              font.capitalization: Font.AllUppercase
              font.letterSpacing: 1.5
              Behavior on color { enabled: !Theme.fading; ColorAnimation { duration: 180 } }
            }
            // unread badge on the notifications tab
            Rectangle {
              visible: tabItem.modelData.name === "notifications" && cc.service.count > 0
              anchors.verticalCenter: tabName.verticalCenter
              width: Math.max(height, badgeText.implicitWidth + metrics.spacingSmall * 2)
              height: badgeText.implicitHeight + metrics.s(2)
              radius: height / 2
              color: cc.service.dnd ? Theme.colors.inset : Theme.colors.accent
              Text {
                id: badgeText
                anchors.centerIn: parent
                text: cc.service.count
                color: cc.service.dnd ? Theme.colors.textSecondary : Theme.colors.panelDeep
                font.pixelSize: metrics.fontTiny * 0.9
                font.family: Theme.fonts.mono
                font.bold: true
              }
            }
          }
          MouseArea {
            id: tabMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: cc.pick(tabItem.index)
          }
        }
      }
    }

    Rectangle {
      readonly property Item target: { tabRep.count; tabRow.width; return tabRep.itemAt(cc.service.tabIndex) }
      visible: target !== null
      anchors.bottom: parent.bottom
      height: Math.max(2, metrics.s(2))
      radius: height / 2
      color: Theme.colors.accent
      x: target ? tabRow.x + target.x + metrics.spacingNormal : 0
      width: target ? target.width - metrics.spacingNormal * 2 : 0
      Behavior on x { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
      Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
    }
  }

  // === PAGES ===
  Item {
    id: pages
    anchors { left: parent.left; right: parent.right; top: strip.bottom; bottom: parent.bottom; topMargin: metrics.spacingNormal }
    clip: true

    Page { index: 0; NotificationsPage {} }
    Page { index: 1; QuickSettings { active: cc.isOpen && cc.service.tab === "settings"; service: cc.service } }
  }

  // A page slides in from the side it comes from, like the dashboard's tabs.
  component Page: Item {
    id: page
    required property int index
    default property alias content: holder.data
    readonly property bool current: index === cc.service.tabIndex
    width: pages.width
    height: pages.height
    visible: current || slide.running || fade.running
    opacity: current ? 1 : 0
    x: current ? 0 : (index < cc.service.tabIndex ? -1 : 1) * metrics.s(24)
    Behavior on opacity { NumberAnimation { id: fade; duration: page.current ? 240 : 120; easing.type: page.current ? Easing.OutCubic : Easing.InCubic } }
    Behavior on x { NumberAnimation { id: slide; duration: 240; easing.type: Easing.OutCubic } }
    Item { id: holder; anchors.fill: parent }
  }

  // === NOTIFICATIONS ===
  component NotificationsPage: Item {
    anchors.fill: parent

    RowLayout {
      id: listHeader
      width: parent.width
      spacing: metrics.spacingSmall

      Text {
        Layout.fillWidth: true
        text: cc.service.count === 0 ? "No notifications" : cc.service.count + (cc.service.count === 1 ? " notification" : " notifications")
        color: Theme.colors.textSecondary
        font.pixelSize: metrics.fontSmall
        font.family: Theme.fonts.ui
        elide: Text.ElideRight
      }
      Pill {
        icon: cc.service.dnd ? "󰂛" : "󰂚"
        label: "Do not disturb"
        on: cc.service.dnd
        onClicked: cc.service.setDnd(!cc.service.dnd)
      }
      Pill {
        icon: "󰎟"
        label: "Clear all"
        visible: cc.service.count > 0
        danger: true
        onClicked: cc.service.clearAll()
      }
    }

    ListView {
      id: list
      anchors { left: parent.left; right: parent.right; top: listHeader.bottom; bottom: parent.bottom; topMargin: metrics.spacingNormal }
      clip: true
      spacing: metrics.spacingSmall
      boundsBehavior: Flickable.StopAtBounds
      model: cc.service.list
      delegate: NotificationCard {
        required property var modelData
        width: ListView.view.width
        notification: modelData
        service: cc.service
        now: cc.now
      }
      // Narrow scroll indicator, only while there is something to scroll.
      Rectangle {
        visible: list.contentHeight > list.height
        anchors.right: parent.right
        width: Math.max(2, metrics.s(3))
        radius: width / 2
        color: Theme.colors.textMuted
        opacity: list.moving ? 0.8 : 0.3
        y: list.visibleArea.yPosition * list.height
        height: list.visibleArea.heightRatio * list.height
        Behavior on opacity { NumberAnimation { duration: 180 } }
      }
    }

    // Empty state
    Column {
      anchors.centerIn: list
      visible: cc.service.count === 0
      spacing: metrics.spacingSmall
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: cc.service.dnd ? "󰂛" : "󰂜"
        color: Theme.colors.textMuted
        font.pixelSize: metrics.fontHuge * 1.4
        font.family: Theme.fonts.mono
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "All caught up"
        color: Theme.colors.textSecondary
        font.pixelSize: metrics.fontNormal
        font.family: Theme.fonts.ui
        font.bold: true
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: cc.service.dnd ? "Do not disturb is on: new notifications still land here" : "New notifications land here"
        color: Theme.colors.textMuted
        font.pixelSize: metrics.fontTiny
        font.family: Theme.fonts.ui
      }
    }
  }

  // Small rounded toggle/button used in page headers.
  component Pill: Rectangle {
    id: pill
    property string icon: ""
    property string label: ""
    property bool on: false
    property bool danger: false
    signal clicked()
    implicitWidth: pillRow.implicitWidth + metrics.spacingNormal * 2
    implicitHeight: pillRow.implicitHeight + metrics.spacingSmall * 2
    radius: height / 2
    color: on ? Theme.colors.accent : pillMouse.containsMouse ? Theme.colors.inset : "transparent"
    border.width: Theme.bw(1)
    border.color: on ? Theme.colors.accent : (danger && pillMouse.containsMouse ? Theme.colors.red : Theme.colors.border)
    Behavior on color { enabled: !Theme.fading; ColorAnimation { duration: 90 } }
    Row {
      id: pillRow
      anchors.centerIn: parent
      spacing: metrics.spacingSmall
      Text {
        text: pill.icon
        color: pill.on ? Theme.colors.panelDeep : (pill.danger && pillMouse.containsMouse ? Theme.colors.red : Theme.colors.textSecondary)
        font.pixelSize: metrics.fontSmall
        font.family: Theme.fonts.mono
      }
      Text {
        text: pill.label
        color: pill.on ? Theme.colors.panelDeep : (pill.danger && pillMouse.containsMouse ? Theme.colors.red : Theme.colors.textSecondary)
        font.pixelSize: metrics.fontTiny
        font.family: Theme.fonts.ui
        font.bold: true
      }
    }
    MouseArea {
      id: pillMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: pill.clicked()
    }
  }
}
