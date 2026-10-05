// Small section label ("WEATHER PRODUCT", "OVERLAYS"): tiny spaced caps.
import QtQuick
import "../themes"

Text {
  color: Theme.colors.label
  font.pixelSize: metrics.fontTiny
  font.bold: true
  font.family: "monospace"
  font.letterSpacing: metrics.s(Theme.colors.headingSpacing) / 2
  font.capitalization: Theme.colors.headingCaps ? Font.AllUppercase : Font.MixedCase
}
