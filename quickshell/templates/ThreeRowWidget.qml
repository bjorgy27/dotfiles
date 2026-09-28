// Base: Three-Row Widget (title | content | footer, 2 separators)

import QtQuick
import QtQuick.Layouts
import "../themes"

Item {
  id: root

  visible: bar.state === "dashboard"
  implicitHeight: metrics.dataWidgetHeight

  property string title: "Widget"
  property Component middleContent: null
  property Component footerContent: null

  Rectangle {
    anchors.fill: parent
    color: Theme.colors.panel
    radius: metrics.radiusLarge

    ColumnLayout {
      anchors {
        fill: parent
        margins: metrics.spacingLarge
      }
      spacing: metrics.spacingSmall

      // Title
      Text {
        text: root.title
        color: Theme.colors.textPrimary
        font.pixelSize: metrics.fontLarge
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

      // Middle content slot
      Loader {
        Layout.fillWidth: true
        Layout.fillHeight: true
        sourceComponent: root.middleContent
      }

      // Separator
      Rectangle {
        Layout.fillWidth: true
        height: bar.dividerThickness
        color: Theme.colors.border
      }

      // Footer content slot
      Loader {
        Layout.fillWidth: true
        sourceComponent: root.footerContent
      }
    }
  }
}
