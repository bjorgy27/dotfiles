// Backdrop for a free-standing surface (the low-battery popup): the Q drawer's
// gradient, a nebula glow painted once per size, and a hairline edge.
import QtQuick
import "../themes"

Item {
  id: sky
  property real radius: metrics.radiusXL
  property color borderColor: Theme.colors.hairline
  property real borderWidth: 1

  Rectangle {
    anchors.fill: parent
    radius: sky.radius
    color: Theme.colors.background
    gradient: Theme.colors.nebula ? skyGrad : null
    Gradient {
      id: skyGrad
      GradientStop { position: 0.0; color: Theme.colors.skyTop }
      GradientStop { position: 0.35; color: Theme.colors.skyMid }
      GradientStop { position: 1.0; color: Theme.colors.skyBottom }
    }
  }
  Canvas {
    anchors.fill: parent
    visible: Theme.colors.nebula
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
      let ctx = getContext("2d")
      ctx.reset()
      if (width < 20 || height < 20) return
      ctx.beginPath(); ctx.roundedRect(0, 0, width, height, sky.radius, sky.radius); ctx.clip()
      let u = (width + height) / 2
      function glow(x, y, r, c) {
        let g = ctx.createRadialGradient(x, y, 0, x, y, r)
        g.addColorStop(0, c); g.addColorStop(1, "rgba(0,0,0,0)")
        ctx.fillStyle = g; ctx.fillRect(0, 0, width, height)
      }
      glow(width * 0.30, height * 0.30, u * 0.55, "rgba(120,50,220,0.42)")
      glow(width * 0.62, height * 0.10, u * 0.40, "rgba(220,60,170,0.22)")
      glow(width * 0.12, height * 0.80, u * 0.35, "rgba(60,70,230,0.20)")
      glow(width * 0.82, height * 0.90, u * 0.50, "rgba(90,30,160,0.18)")
    }
  }
  Rectangle {
    anchors.fill: parent
    radius: sky.radius
    color: "transparent"
    border.width: sky.borderWidth
    border.color: sky.borderColor
  }
}
