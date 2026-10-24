// One notification: app icon (or the notification's own image), app name and
// age, summary, body, action buttons and a dismiss button. Used by the
// control center's list.
// Click: the default action if there is one (then dismissed, unless resident);
// right click or the × dismisses. A long body expands on click when there is
// no default action.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import Quickshell.Services.Notifications
import "themes"

Rectangle {
  id: card

  required property var notification
  property var service
  property real now: Date.now()       // age reference, ticked by the owner
  signal activated(bool viaAction)    // default action invoked (true) / plain click (false)
  readonly property bool hovered: hover.hovered

  readonly property var n: notification
  readonly property bool critical: n?.urgency === NotificationUrgency.Critical
  readonly property bool low: n?.urgency === NotificationUrgency.Low
  readonly property bool hasDefault: { for (let a of (n?.actions ?? [])) if (a.identifier === "default") return true; return false }
  readonly property var buttons: { let r = []; for (let a of (n?.actions ?? [])) if (a.identifier !== "default" && a.text !== "") r.push(a); return r }
  property bool expanded: false

  implicitHeight: content.implicitHeight + metrics.spacingNormal * 2
  radius: metrics.radiusNormal
  color: hover.hovered ? Theme.colors.inset : Qt.rgba(Theme.colors.inset.r, Theme.colors.inset.g, Theme.colors.inset.b, 0.55)
  border.width: Theme.bw(1)
  border.color: critical ? Theme.colors.red : Qt.rgba(Theme.colors.border.r, Theme.colors.border.g, Theme.colors.border.b, 0.5)
  Behavior on color { enabled: !Theme.fading; ColorAnimation { duration: 90 } }

  // Urgency stripe on the leading edge
  Rectangle {
    visible: card.critical || card.low
    anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: metrics.spacingSmall }
    width: Math.max(2, metrics.s(3))
    radius: width / 2
    color: card.critical ? Theme.colors.red : Theme.colors.textMuted
  }

  HoverHandler { id: hover }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    cursorShape: Qt.PointingHandCursor
    onClicked: mouse => {
      if (mouse.button !== Qt.LeftButton) { card.service?.dismiss(card.n); return }
      if (card.service?.activate(card.n)) {
        if (card.n && !card.n.resident) card.n.dismiss()
        card.activated(true)
      } else if (body.truncated || card.expanded) {
        card.expanded = !card.expanded
      } else {
        card.activated(false)
      }
    }
  }

  RowLayout {
    id: content
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: metrics.spacingNormal; leftMargin: metrics.spacingLarge }
    spacing: metrics.spacingNormal

    // Icon: the notification's image, else the app icon, else a bell glyph
    Item {
      id: iconBox
      Layout.alignment: Qt.AlignTop
      Layout.preferredWidth: metrics.s(36)
      Layout.preferredHeight: metrics.s(36)

      readonly property string imageSrc: card.n?.image ?? ""
      readonly property string iconSrc: {
        let i = card.n?.appIcon ?? ""
        if (i === "" && card.n?.desktopEntry) i = DesktopEntries.byId(card.n.desktopEntry)?.icon ?? ""
        if (i === "") return ""
        if (i.startsWith("/")) return "file://" + i
        if (i.indexOf("://") >= 0) return i
        return Quickshell.iconPath(i, true)
      }

      // notify-send -i fills both the image hint and the app icon, and either
      // can miss: each layer only shows once it really loaded something.
      readonly property bool imageOk: imageSrc !== "" && picture.status === Image.Ready && picture.implicitWidth > 0
      readonly property bool iconOk: iconSrc !== "" && appIcon.status === Image.Ready && appIcon.backer.implicitWidth > 0

      Image {
        id: picture
        anchors.fill: parent
        visible: iconBox.imageOk
        source: iconBox.imageSrc
        fillMode: Image.PreserveAspectFit
        sourceSize.width: width * 2
        sourceSize.height: height * 2
        asynchronous: true
        smooth: true
        mipmap: true
      }
      IconImage {
        id: appIcon
        anchors.fill: parent
        anchors.margins: metrics.s(2)
        visible: !iconBox.imageOk && iconBox.iconOk
        source: iconBox.iconSrc
        asynchronous: true
      }
      Text {
        anchors.centerIn: parent
        visible: !iconBox.imageOk && !iconBox.iconOk
        text: card.critical ? "󰀦" : "󰂚"
        color: card.critical ? Theme.colors.red : Theme.colors.accent
        font.pixelSize: metrics.fontXL * 0.85
        font.family: Theme.fonts.mono
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: metrics.s(2)

      // app · age                                  ×
      RowLayout {
        Layout.fillWidth: true
        spacing: metrics.spacingSmall
        Text {
          Layout.fillWidth: true
          readonly property string age: card.service?.age(card.n, card.now) ?? ""
          text: (card.n?.appName || "Notification") + (age !== "" ? "  ·  " + age : "")
          elide: Text.ElideRight
          color: Theme.colors.textMuted
          font.pixelSize: metrics.fontTiny
          font.family: Theme.fonts.mono
          font.capitalization: Font.AllUppercase
          font.letterSpacing: 1
        }
        Text {
          id: closeGlyph
          text: "󰅖"
          color: closeMouse.containsMouse ? Theme.colors.red : Theme.colors.textMuted
          font.pixelSize: metrics.fontNormal
          font.family: Theme.fonts.mono
          opacity: card.hovered ? 1 : 0.35
          Behavior on opacity { NumberAnimation { duration: 90 } }
          MouseArea {
            id: closeMouse
            anchors.fill: parent
            anchors.margins: -metrics.spacingTiny
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: card.service?.dismiss(card.n)
          }
        }
      }

      Text {
        Layout.fillWidth: true
        visible: text !== ""
        text: card.n?.summary ?? ""
        color: card.critical ? Theme.colors.red : Theme.colors.textPrimary
        font.pixelSize: metrics.fontNormal
        font.family: Theme.fonts.ui
        font.bold: true
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }

      Text {
        id: body
        Layout.fillWidth: true
        visible: text !== ""
        // Markup is allowed (b/i/u/a); images are not, and newlines are real line breaks.
        text: (card.n?.body ?? "").replace(/<img[^>]*>/gi, "").replace(/\n/g, "<br>")
        textFormat: Text.StyledText
        color: Theme.colors.textSecondary
        linkColor: Theme.colors.accent
        font.pixelSize: metrics.fontSmall
        font.family: Theme.fonts.ui
        wrapMode: Text.Wrap
        maximumLineCount: card.expanded ? 40 : 4
        elide: Text.ElideRight
        onLinkActivated: link => Qt.openUrlExternally(link)
        HoverHandler { enabled: body.hoveredLink !== ""; cursorShape: Qt.PointingHandCursor }
      }

      // Action buttons (the default action is the card click)
      Flow {
        Layout.fillWidth: true
        Layout.topMargin: metrics.spacingTiny
        visible: card.buttons.length > 0
        spacing: metrics.spacingSmall
        Repeater {
          model: card.buttons
          Rectangle {
            required property var modelData
            width: actionLabel.implicitWidth + metrics.spacingLarge * 2
            height: actionLabel.implicitHeight + metrics.spacingSmall * 2
            radius: metrics.radiusSmall
            color: actionMouse.containsMouse ? Theme.colors.accent : Theme.colors.inset
            Behavior on color { enabled: !Theme.fading; ColorAnimation { duration: 90 } }
            Text {
              id: actionLabel
              anchors.centerIn: parent
              text: modelData.text
              color: actionMouse.containsMouse ? Theme.colors.panelDeep : Theme.colors.textPrimary
              font.pixelSize: metrics.fontTiny
              font.family: Theme.fonts.ui
              font.bold: true
            }
            MouseArea {
              id: actionMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                let n = card.n
                modelData.invoke()
                if (n && !n.resident) n.dismiss()
              }
            }
          }
        }
      }
    }
  }
}
