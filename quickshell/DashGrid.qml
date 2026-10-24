// One dashboard page: a resolved preset layout (DashboardConfig.layoutFor) laid
// out as cards on a grid that fills this item. shell.qml stacks one per tab and
// switches with a short fade + slide (`current`, `dir`); the open ripple lives here.

import QtQuick
import "themes"

Item {
  id: grid

  property var layout: ({ columns: 1, rows: 0, widgets: [] })
  // The tab on screen; `dir` (+1/-1) is the direction the tabs are moving in.
  property bool current: true
  property int dir: 1
  property real colSpacing: metrics.spacingNormal
  property real rowSpacing: metrics.spacingNormal

  readonly property int columns: Math.max(1, layout.columns)
  readonly property real colWidth: (width - colSpacing * (columns - 1)) / columns
  // Row pitch solved from the height, so every tab's rows fill the same pocket.
  readonly property real widgetHeight: Math.max(metrics.s(60), (height - rowSpacing * Math.max(0, layout.rows - 1)) / Math.max(1, layout.rows))

  // Tab switch: the old page fades out sliding away, the new one follows it in.
  property real shown: current ? 1 : 0
  Behavior on shown {
    SequentialAnimation {
      PauseAnimation { duration: grid.current ? Motion.exit / 2 : 0 }
      NumberAnimation { duration: grid.current ? Motion.enter : Motion.exit; easing.type: grid.current ? Motion.easeIn : Motion.easeOut }
    }
  }
  opacity: shown
  visible: shown > 0.001
  transform: Translate { x: (1 - grid.shown) * metrics.s(28) * (grid.current ? grid.dir : -grid.dir) }

  // Row r starts r pitches down; a span of s rows is s widgets + (s-1) gaps.
  // Same for columns. Rows may be fractional (Services is 1.5 rows tall).
  function rowY(row) { return row * (widgetHeight + rowSpacing) }
  function rowH(span) { return span * widgetHeight + (span - 1) * rowSpacing }
  function colX(col) { return col * (colWidth + colSpacing) }
  function colW(span) { return span * colWidth + (span - 1) * colSpacing }
  // Focal card: the centrepiece the open choreography radiates from and the
  // one the ripple starts from. A preset entry opts in with
  // "options": { "focal": true }; otherwise the largest card is focal.
  readonly property int focalIndex: {
    let ws = layout.widgets, best = -1, bestA = -1
    for (let i = 0; i < ws.length; i++) {
      if (ws[i].options && ws[i].options.focal === true) return i
      let a = ws[i].colSpan * ws[i].rowSpan
      if (a > bestA) { bestA = a; best = i }
    }
    return best
  }
  // Cell centre in grid units (column widths / row pitches), for the ripple.
  function cellCenter(w) { return { x: w.col + w.colSpan / 2, y: w.row + w.rowSpan / 2 } }
  // Ripple geometry for card i: { delay (ms), dx, dy (unit vector away from the focal card) }.
  function ripple(i) {
    let ws = layout.widgets
    if (focalIndex < 0 || !ws[i]) return { delay: Dash.revealBase, dx: 0, dy: 0 }
    let f = cellCenter(ws[focalIndex]), far = 0.0001
    let aspect = widgetHeight / Math.max(1, colWidth)   // rows are shorter than columns are wide
    let dist = w => { let c = cellCenter(w); return Math.hypot(c.x - f.x, (c.y - f.y) * aspect) }
    for (let w of ws) far = Math.max(far, dist(w))
    let c = cellCenter(ws[i]), d = dist(ws[i])
    let vx = c.x - f.x, vy = (c.y - f.y) * aspect, n = Math.hypot(vx, vy)
    return { delay: Dash.revealBase + Math.round(d / far * Dash.revealSpread),
             dx: n > 0 ? vx / n : 0, dy: n > 0 ? vy / n : 0 }
  }

  Repeater {
    model: grid.layout.widgets

    // One Loader per preset entry; the registry maps `type` to a file.
    // The Loader's size drives the widget's size. `options` is read
    // from the layout object by index rather than from modelData:
    // the model conversion turns JS arrays into Qt sequences, which
    // would fail Array.isArray inside the widgets.
    Loader {
      id: cardLoader
      required property int index
      required property var modelData
      x: grid.colX(modelData.col)
      y: grid.rowY(modelData.row)
      width: grid.colW(modelData.colSpan)
      height: grid.rowH(modelData.rowSpan)

      // Open choreography: cards power up outward from the focal card,
      // each fading in while it travels a few px away from it (delay
      // grows with distance).
      // Only the tab on screen plays it. 1 = fully shown (the default, so a
      // preset hot reload or a fullscreen toggle shows cards as-is). Tunables:
      // themes/Dash.qml (rippleEnabled, reveal*);
      // Motion.revealEnabled=false also turns it off.
      readonly property bool focal: index === grid.focalIndex
      property var rip: ({ delay: 0, dx: 0, dy: 0 })
      property real reveal: 1
      opacity: reveal
      transform: Translate {
        readonly property real d: (1 - cardLoader.reveal) * metrics.s(Dash.revealSlide)
        x: -cardLoader.rip.dx * d
        y: -cardLoader.rip.dy * d
      }
      SequentialAnimation {
        id: revealAnim
        PauseAnimation { duration: cardLoader.rip.delay }
        NumberAnimation { target: cardLoader; property: "reveal"; to: 1; duration: Motion.enter; easing.type: Motion.easeIn }
      }
      Connections {
        target: bar
        function onStateChanged() {
          revealAnim.stop()
          if (bar.state === "dashboard" && grid.current && Dash.rippleEnabled && Motion.revealEnabled) {
            cardLoader.rip = grid.ripple(cardLoader.index)
            cardLoader.reveal = 0
            revealAnim.start()
          } else {
            cardLoader.reveal = 1
          }
        }
      }

      Component.onCompleted: {
        let cell = grid.layout.widgets[index]
        let entry = dashboardConfig.registry[cell.type]
        setSource(Qt.resolvedUrl(entry.file), Object.assign({ options: cell.options }, entry.props ?? {}))
      }
    }
  }
}
