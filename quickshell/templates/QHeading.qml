// Panel title in the shell's chrome: gold, spaced small caps under Q Galaxy;
// plain bold text under a flat theme.
import QtQuick
import "../themes"

Text {
  color: Theme.colors.heading
  font.pixelSize: metrics.fontLarge
  font.weight: Theme.colors.headingCaps ? Font.DemiBold : Font.Bold
  font.family: "monospace"
  font.letterSpacing: metrics.s(Theme.colors.headingSpacing)
  font.capitalization: Theme.colors.headingCaps ? Font.AllUppercase : Font.MixedCase
  elide: Text.ElideRight
}
