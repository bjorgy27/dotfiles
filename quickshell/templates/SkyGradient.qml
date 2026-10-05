// The bar's fill: deep space, lighter at the bar and darkening down the dropdown.
// Spans a fixed depth so the bar's own colour never shifts while a dropdown opens.
import QtQuick
import QtQuick.Shapes
import "../themes"

LinearGradient {
  property bool vertical: false
  property real depth: 600
  x1: 0; y1: 0
  x2: vertical ? depth : 0
  y2: vertical ? 0 : depth
  GradientStop { position: 0.0; color: Theme.colors.skyTop }
  GradientStop { position: 0.35; color: Theme.colors.skyMid }
  GradientStop { position: 1.0; color: Theme.colors.skyBottom }
}
