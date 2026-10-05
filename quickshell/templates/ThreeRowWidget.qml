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
      Loader {
        Layout.fillWidth: true
        Layout.fillHeight: true
        sourceComponent: root.middleContent
      }

      // Separator
      QRule {
        Layout.fillWidth: true
        implicitHeight: bar.dividerThickness
      }

      // Footer content slot
      Loader {
        Layout.fillWidth: true
        sourceComponent: root.footerContent
      }
    }
  }
}
