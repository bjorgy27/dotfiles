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

  Rectangle {
    anchors.fill: parent
    color: Theme.colors.panel
    radius: metrics.radiusLarge

    ColumnLayout {
      anchors {
        top: parent.top
        left: parent.left
        right: parent.right
        margins: metrics.spacingLarge
      }
      spacing: metrics.spacingSmall

      // Title
      Text {
        text: root.title
        color: Theme.colors.textPrimary
        font.pixelSize: root.titleSize
        font.bold: true
        font.family: "monospace"
        Layout.fillWidth: true
        elide: Text.ElideRight
      }

      // Separator
      Rectangle {
        Layout.fillWidth: true
        height: bar.dividerThickness
        color: Theme.colors.border
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
