// Base: Three-Row Widget (title | content | footer, 2 separators)

import QtQuick
import QtQuick.Layouts
import "../themes"

Item {
  // Preset entry options (DashboardConfig.qml); unused unless a widget reads them.
  property var options: ({})
  id: root

  visible: bar.state === "dashboard"
  implicitHeight: metrics.dataWidgetHeight

  property string title: "Widget"
  property Component middleContent: null
  property Component footerContent: null
  // Size-adaptive helpers (upstream API, used by CalendarWidget and friends)
  property bool showFooter: true
  property real refWidth: 360
  property real refHeight: 160
  property bool middleFills: false
  readonly property real k: metrics.cardScale(width, height, refWidth, refHeight)
  function fs(px) { return Math.max(Math.round(px * k), Math.min(px, metrics.fontTiny)) }
  readonly property bool compact: width < metrics.s(260) || height < metrics.s(140)
  readonly property bool showTitle: true
  readonly property real middleHeight: middleSlot.height

  QCard {
    anchors.fill: parent

    ColumnLayout {
      anchors {
        fill: parent
        margins: metrics.spacingLarge
      }
      spacing: metrics.spacingSmall

      // Title
      QHeading {
        text: root.title
        font.pixelSize: metrics.fontLarge
        Layout.fillWidth: true
      }

      // Separator
      QRule {
        Layout.fillWidth: true
        implicitHeight: bar.dividerThickness
      }

      // Middle content slot
      Item {
        id: middleSlot
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: root.middleFills
        Loader {
          width: parent.width
          height: parent.height
          sourceComponent: root.middleContent
        }
      }

      // Separator
      QRule {
        visible: root.showFooter
        Layout.fillWidth: true
        implicitHeight: bar.dividerThickness
      }

      // Footer content slot
      Loader {
        visible: root.showFooter
        Layout.fillWidth: true
        sourceComponent: root.footerContent
      }
    }
  }
}
