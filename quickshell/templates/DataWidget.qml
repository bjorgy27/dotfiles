// Base: Data Widget (title + separator + data, 1 separator)
// Props: title, dataContent (Component)

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
  property int titleSize: metrics.fontNormal
  property alias dataContent: dataPlaceholder.children

  QCard {
    anchors.fill: parent

    ColumnLayout {
      anchors {
        top: parent.top
        left: parent.left
        right: parent.right
        margins: metrics.spacingLarge
      }
      spacing: metrics.spacingSmall

      // Title
      QHeading {
        text: root.title
        font.pixelSize: root.titleSize
        Layout.fillWidth: true
      }

      // Separator
      QRule {
        Layout.fillWidth: true
        implicitHeight: bar.dividerThickness
      }

      // Data content slot
      Item {
        id: dataPlaceholder
        Layout.fillWidth: true
        implicitHeight: childrenRect.height
      }
    }
  }
}
