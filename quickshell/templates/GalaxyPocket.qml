// Galaxy chrome for the bar's dropdown (shell.qml `bar`): the nebula glow
// inside the open pocket and a gold hairline under the bar and round the
// pocket. Bound to the bar's animated geometry, so it opens and closes with
// the dropdown. Draws nothing under a flat theme.
import QtQuick
import QtQuick.Shapes
import "../themes"

Shape {
  id: pocket
  required property Item target            // the bar Shape
  property bool vertical: false

  readonly property real span: target.barLong
  readonly property real edge0: target.barThickness
  readonly property real edge1: target.barCross
  readonly property real lo: target.pocketLo
  readonly property real hi: target.pocketHi
  readonly property real fillet: target.dropdownFilletRadius
  readonly property real corner: target.dropdownCornerRadius
  readonly property real w: hi - lo
  readonly property real h: Math.max(0, edge1 - edge0)
  // glows fade in over the first ~80 px of the opening
  readonly property real glowK: Math.max(0, Math.min(1, h / metrics.s(80)))
  readonly property real unit: (w + h) / 2

  visible: Theme.colors.nebula || Theme.colors.hairline.a > 0
  layer.enabled: true
  layer.samples: 4

  // (a, b) = (along the bar, across it) -> screen
  function pt(a, b) { return vertical ? (b.toFixed(2) + " " + a.toFixed(2)) : (a.toFixed(2) + " " + b.toFixed(2)) }
  // SVG arc; sweep 1 is clockwise on screen, mirrored when the bar is vertical
  function arc(r, cw, a, b) {
    if (r < 0.5) return " L " + pt(a, b)
    return " A " + r.toFixed(2) + " " + r.toFixed(2) + " 0 0 " + ((cw !== vertical) ? 1 : 0) + " " + pt(a, b)
  }

  // the pocket's own area (glows are clipped to it)
  readonly property string pocketPath: h < 1 ? "" :
      "M " + pt(lo, edge0) + " L " + pt(hi, edge0) + " L " + pt(hi, edge1 - corner)
      + arc(corner, true, hi - corner, edge1) + " L " + pt(lo + corner, edge1)
      + arc(corner, true, lo, edge1 - corner) + " Z"
  // the bar's lower edge, dipping round the pocket (half a pixel inside, so it lands on whole pixels)
  readonly property real e0: edge0 - 0.5
  readonly property real e1: edge1 - 0.5
  readonly property real l0: lo + 0.5
  readonly property real h0: hi - 0.5
  readonly property string edgePath:
      "M " + pt(0, e0) + " L " + pt(l0 - fillet, e0)
      + arc(fillet, true, l0, e0 + fillet) + " L " + pt(l0, e1 - corner)
      + arc(corner, false, l0 + corner, e1) + " L " + pt(h0 - corner, e1)
      + arc(corner, false, h0, e1 - corner) + " L " + pt(h0, e0 + fillet)
      + arc(fillet, true, h0 + fillet, e0) + " L " + pt(span, e0)

  component Glow: ShapePath {
    id: glow
    property real fa: 0.5        // centre, as a fraction of the pocket (along, across)
    property real fb: 0.5
    property real size: 0.5      // radius, as a fraction of the pocket's mean side
    property color tint
    readonly property real ca: pocket.lo + pocket.w * fa
    readonly property real cb: pocket.edge0 + pocket.h * fb
    strokeColor: "transparent"
    fillGradient: RadialGradient {
      centerX: pocket.vertical ? glow.cb : glow.ca
      centerY: pocket.vertical ? glow.ca : glow.cb
      focalX: centerX; focalY: centerY
      centerRadius: Math.max(1, pocket.unit * glow.size)
      GradientStop { position: 0; color: Qt.rgba(glow.tint.r, glow.tint.g, glow.tint.b, glow.tint.a * pocket.glowK) }
      GradientStop { position: 1; color: Qt.rgba(glow.tint.r, glow.tint.g, glow.tint.b, 0) }
    }
    PathSvg { path: Theme.colors.nebula ? pocket.pocketPath : "" }
  }

  // the Q drawer's four glows: violet core, magenta, indigo, deep purple
  Glow { fa: 0.30; fb: 0.25; size: 0.55; tint: Qt.rgba(120 / 255, 50 / 255, 220 / 255, 0.42) }
  Glow { fa: 0.62; fb: 0.10; size: 0.40; tint: Qt.rgba(220 / 255, 60 / 255, 170 / 255, 0.22) }
  Glow { fa: 0.12; fb: 0.75; size: 0.35; tint: Qt.rgba(60 / 255, 70 / 255, 230 / 255, 0.20) }
  Glow { fa: 0.80; fb: 0.85; size: 0.50; tint: Qt.rgba(90 / 255, 30 / 255, 160 / 255, 0.18) }

  // veil: the pocket's top blends into the bar before the glow shows, so there is no seam
  ShapePath {
    strokeColor: "transparent"
    fillGradient: LinearGradient {
      x1: pocket.vertical ? pocket.edge0 : 0
      y1: pocket.vertical ? 0 : pocket.edge0
      x2: pocket.vertical ? pocket.edge0 + metrics.s(56) : 0
      y2: pocket.vertical ? 0 : pocket.edge0 + metrics.s(56)
      GradientStop { position: 0; color: Theme.colors.skyTop }
      GradientStop { position: 1; color: Qt.rgba(Theme.colors.skyTop.r, Theme.colors.skyTop.g, Theme.colors.skyTop.b, 0) }
    }
    PathSvg { path: Theme.colors.nebula ? pocket.pocketPath : "" }
  }

  ShapePath {
    fillColor: "transparent"
    strokeColor: Theme.colors.hairline
    strokeWidth: 1
    capStyle: ShapePath.FlatCap
    PathSvg { path: pocket.edgePath }
  }
}
