import QtQuick
import QtQuick.Layouts
import "../themes"

// Live aircraft overlay for MapView. Drop it in as a MapView overlay child
// (anchors.fill) and feed it the shared root.aircraft array from aircraftpoll.sh.
//
// Rendering strategy: ONE Canvas draws every glyph and the selected route in a
// single pass (a few ms for 400 aircraft), and hit-testing is a nearest-point
// scan over a precomputed screen-space list — so there is no per-aircraft Item
// tree to build or reposition. Only the labels (tooltip, selected callsign,
// airport codes) and the info card are real Items.
//
// Input handling deliberately never blocks the map underneath: hover uses a
// non-blocking HoverHandler, and the only press this layer ever takes is a tap
// that starts over a glyph (exclusive grab, so the map does not also treat it
// as a click). Presses on empty map are not touched at all — even a passive
// TapHandler here was found to stop MapView's MouseArea from panning — so the
// host MUST wire map.clicked -> deselect itself (RadarWidget does:
// map.onClicked -> root.selectAircraft("", "")). deselectRequested() is only
// emitted by the info card's close button.
Item {
  id: layer

  // --- contract API -------------------------------------------------------
  property var map: null            // the MapView: lonLatToXY(lon, lat), viewChanged
  property var aircraft: []         // root.aircraft (parsed aircraftpoll.sh "ac" array)
  property real fetchedAt: 0        // root.aircraftFetchedAt (Date.now() ms at poll completion)
  property string selectedHex: ""
  property var route: null          // routepoll.sh JSON ({origin, dest} or {error}) or null
  property real homeLat: 0          // optional, unused by the planes themselves
  property real homeLon: 0

  signal aircraftClicked(string hex, string callsign)
  signal deselectRequested()

  // --- read-only extras (handy for footers) --------------------------------
  readonly property int visibleCount: visibleList.length
  readonly property string hoveredHex: internal.hoveredHex

  // --- internals -----------------------------------------------------------
  property var visibleList: []      // [{hex, callsign, x, y, track, ground, selected, ac}]
  property var selectedInfo: null   // last-known record of the selected aircraft
  property bool selectedLive: false // selected aircraft present in the current poll
  property real selectedX: 0
  property real selectedY: 0
  property var routePts: null       // {toPlane: [[x,y]...], toDest: [[x,y]...], o: [x,y], d: [x,y]}

  readonly property real glyphSize: metrics.s(14)
  readonly property real hitRadius: metrics.s(11)
  readonly property int extrapolationCapS: 60

  QtObject {
    id: internal
    property string hoveredHex: ""
    property real hoverX: 0
    property real hoverY: 0
    property string hoverLabel: ""
  }

  // ---- geodesy (self-contained so the layer has no load-order dependency) ----
  function toRad(d) { return d * Math.PI / 180 }
  function toDeg(r) { return r * 180 / Math.PI }

  // Point reached from (lat, lon) heading `bearing` degrees for `distNm`.
  function destinationPoint(lat, lon, bearing, distNm) {
    const R = 3440.065   // earth radius, nm
    const d = distNm / R
    const b = toRad(bearing)
    const p1 = toRad(lat), l1 = toRad(lon)
    const sp1 = Math.sin(p1), cp1 = Math.cos(p1)
    const p2 = Math.asin(sp1 * Math.cos(d) + cp1 * Math.sin(d) * Math.cos(b))
    const l2 = l1 + Math.atan2(Math.sin(b) * Math.sin(d) * cp1, Math.cos(d) - sp1 * Math.sin(p2))
    let lonOut = toDeg(l2)
    lonOut = ((lonOut + 540) % 360) - 180
    return { lat: toDeg(p2), lon: lonOut }
  }

  // n+1 points along the great circle from a to b, as [[lat, lon], ...].
  function greatCirclePoints(lat1, lon1, lat2, lon2, n) {
    const p1 = toRad(lat1), l1 = toRad(lon1), p2 = toRad(lat2), l2 = toRad(lon2)
    const dl = l2 - l1
    const a = Math.sin((p2 - p1) / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) ** 2
    const delta = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
    const out = []
    if (delta < 1e-9) { out.push([lat1, lon1], [lat2, lon2]); return out }
    const sd = Math.sin(delta)
    for (let i = 0; i <= n; i++) {
      const f = i / n
      const A = Math.sin((1 - f) * delta) / sd
      const B = Math.sin(f * delta) / sd
      const x = A * Math.cos(p1) * Math.cos(l1) + B * Math.cos(p2) * Math.cos(l2)
      const y = A * Math.cos(p1) * Math.sin(l1) + B * Math.cos(p2) * Math.sin(l2)
      const z = A * Math.sin(p1) + B * Math.sin(p2)
      out.push([toDeg(Math.atan2(z, Math.sqrt(x * x + y * y))), toDeg(Math.atan2(y, x))])
    }
    return out
  }

  // ---- formatting ----------------------------------------------------------
  function fmtInt(n) {
    const s = Math.round(Math.abs(n)).toString()
    return (n < 0 ? "-" : "") + s.replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  }

  function altText(ac) {
    if (!ac) return ""
    if (ac.ground) return "on ground"
    const alt = ac.alt || 0
    if (alt >= 18000) return "FL" + Math.round(alt / 100) + " / " + fmtInt(alt) + " ft"
    return fmtInt(alt) + " ft"
  }

  function vrText(ac) {
    if (!ac || ac.ground) return ""
    const vr = ac.vr || 0
    if (Math.abs(vr) < 64) return "level"
    return (vr > 0 ? "↑ " : "↓ ") + fmtInt(Math.abs(vr)) + " ft/min"
  }

  function callsignOf(ac) {
    return (ac && ac.flight && ac.flight.length > 0) ? ac.flight : (ac ? ac.hex : "")
  }

  // ---- projection / model rebuild -----------------------------------------
  // Recomputes screen positions for every aircraft (dead-reckoned from the
  // poll timestamp), filters to what is on screen, and repaints. Called on
  // data change, map view change, selection change, and every tick.
  function rebuild() {
    if (!map || width <= 0 || height <= 0) { visibleList = []; canvas.requestPaint(); return }

    const now = Date.now()
    const elapsed = fetchedAt > 0 ? Math.max(0, (now - fetchedAt) / 1000) : 0
    const margin = glyphSize * 2
    const list = []
    let sel = null, selX = 0, selY = 0

    const acs = aircraft || []
    for (let i = 0; i < acs.length; i++) {
      const ac = acs[i]
      if (!ac || ac.lat === undefined || ac.lon === undefined) continue

      let lat = ac.lat, lon = ac.lon
      const hasTrack = ac.track !== undefined && ac.track !== null && ac.track >= 0
      if (!ac.ground && hasTrack && ac.gs > 0) {
        const dt = Math.min(extrapolationCapS, elapsed + (ac.seen || 0))
        if (dt > 0) {
          const p = destinationPoint(lat, lon, ac.track, ac.gs * dt / 3600)
          lat = p.lat; lon = p.lon
        }
      }

      const pt = map.lonLatToXY(lon, lat)
      const x = pt.x, y = pt.y
      const selected = ac.hex === selectedHex
      const onScreen = x >= -margin && x <= width + margin && y >= -margin && y <= height + margin

      if (selected) { sel = ac; selX = x; selY = y }
      if (!onScreen && !selected) continue

      list.push({ hex: ac.hex, callsign: callsignOf(ac), x: x, y: y,
                  track: hasTrack ? ac.track : -1, ground: !!ac.ground,
                  selected: selected, ac: ac })
    }

    visibleList = list
    if (sel) { selectedInfo = sel; selectedLive = true; selectedX = selX; selectedY = selY }
    else if (selectedHex === "") { selectedInfo = null; selectedLive = false }
    else { selectedLive = false }

    rebuildRoute()
    updateHover(internal.hoverX, internal.hoverY, false)
    canvas.requestPaint()
  }

  function projectPath(pts) {
    const out = []
    for (let i = 0; i < pts.length; i++) {
      const p = map.lonLatToXY(pts[i][1], pts[i][0])
      out.push([p.x, p.y])
    }
    return out
  }

  function rebuildRoute() {
    const r = route
    if (!map || !r || !r.origin || !r.dest || selectedHex === "" || !selectedLive
        || r.origin.lat === undefined || r.dest.lat === undefined) {
      routePts = null
      return
    }
    const plane = selectedInfo
    // Use the dead-reckoned screen position for the plane vertex so the line
    // stays attached to the glyph between polls.
    const here = map.xyToLonLat ? map.xyToLonLat(selectedX, selectedY) : { lat: plane.lat, lon: plane.lon }
    const toPlane = projectPath(greatCirclePoints(r.origin.lat, r.origin.lon, here.lat, here.lon, 48))
    const toDest = projectPath(greatCirclePoints(here.lat, here.lon, r.dest.lat, r.dest.lon, 48))
    const o = map.lonLatToXY(r.origin.lon, r.origin.lat)
    const d = map.lonLatToXY(r.dest.lon, r.dest.lat)
    routePts = { toPlane: toPlane, toDest: toDest, o: [o.x, o.y], d: [d.x, d.y] }
  }

  // Nearest aircraft to (x, y) within hitRadius, or null.
  function hitTest(x, y) {
    let best = null, bestD = hitRadius * hitRadius
    const list = visibleList
    for (let i = 0; i < list.length; i++) {
      const e = list[i]
      const dx = e.x - x, dy = e.y - y
      const d = dx * dx + dy * dy
      if (d <= bestD) { bestD = d; best = e }
    }
    return best
  }

  function updateHover(x, y, fromPointer) {
    if (fromPointer) { internal.hoverX = x; internal.hoverY = y }
    const hit = hoverTracker.hovered ? hitTest(x, y) : null
    if (hit) {
      internal.hoveredHex = hit.hex
      internal.hoverLabel = hit.callsign
      // Prefer above-right of the glyph; flip/clamp so it stays inside the map.
      let tx = hit.x + glyphSize * 0.8
      let ty = hit.y - tooltip.height - glyphSize * 0.6
      if (tx + tooltip.width > width) tx = hit.x - glyphSize * 0.8 - tooltip.width
      if (ty < 0) ty = hit.y + glyphSize * 0.6
      tooltip.x = Math.round(Math.max(0, Math.min(width - tooltip.width, tx)))
      tooltip.y = Math.round(Math.max(0, Math.min(height - tooltip.height, ty)))
    } else {
      internal.hoveredHex = ""
    }
  }

  onAircraftChanged: rebuild()
  onFetchedAtChanged: rebuild()
  onSelectedHexChanged: rebuild()
  onRouteChanged: { rebuildRoute(); canvas.requestPaint() }
  onWidthChanged: rebuild()
  onHeightChanged: rebuild()
  onMapChanged: rebuild()
  Component.onCompleted: rebuild()

  Connections {
    target: layer.map
    ignoreUnknownSignals: true
    function onViewChanged() { layer.rebuild() }
  }

  // Dead-reckoning tick: glide the glyphs between polls.
  Timer {
    interval: 1000
    repeat: true
    running: layer.visible && layer.fetchedAt > 0 && (layer.aircraft || []).length > 0
    onTriggered: layer.rebuild()
  }

  // ---- drawing -------------------------------------------------------------
  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    // Airliner silhouette, nose up (−y), in units of glyphSize / 14.
    readonly property var glyph: [
      [0, -7], [1.1, -5], [1.2, -1.5], [7, 2.6], [7, 3.8], [1.2, 2.2], [1, 4.6],
      [2.8, 5.8], [2.8, 6.6], [0, 6], [-2.8, 6.6], [-2.8, 5.8], [-1, 4.6],
      [-1.2, 2.2], [-7, 3.8], [-7, 2.6], [-1.2, -1.5], [-1.1, -5]
    ]

    function tracePath(ctx, pts) {
      let started = false
      const jump = width * 0.5
      for (let i = 0; i < pts.length; i++) {
        const p = pts[i]
        // Break the line where the projection wrapped around the antimeridian.
        if (started && i > 0 && Math.abs(p[0] - pts[i - 1][0]) > jump) started = false
        if (!started) { ctx.moveTo(p[0], p[1]); started = true } else ctx.lineTo(p[0], p[1])
      }
    }

    function drawGlyph(ctx, x, y, track, fill, outline, scale) {
      ctx.save()
      ctx.translate(x, y)
      ctx.rotate(track * Math.PI / 180)
      const k = layer.glyphSize / 14 * scale
      ctx.beginPath()
      for (let i = 0; i < glyph.length; i++) {
        const p = glyph[i]
        if (i === 0) ctx.moveTo(p[0] * k, p[1] * k); else ctx.lineTo(p[0] * k, p[1] * k)
      }
      ctx.closePath()
      ctx.fillStyle = fill
      ctx.strokeStyle = outline
      ctx.lineWidth = 1
      ctx.lineJoin = "round"
      ctx.fill()
      ctx.stroke()
      ctx.restore()
    }

    onPaint: {
      const ctx = getContext("2d")
      ctx.reset()
      ctx.clearRect(0, 0, width, height)

      const accent = Theme.colors.accent.toString()
      const primary = Theme.colors.textPrimary.toString()
      const muted = Theme.colors.textMuted.toString()
      const outline = Theme.colors.panelDeep.toString()

      // Route under everything else.
      const rp = layer.routePts
      if (rp) {
        ctx.lineCap = "round"
        ctx.lineJoin = "round"
        ctx.strokeStyle = accent
        ctx.lineWidth = 2

        ctx.setLineDash([])
        ctx.beginPath(); tracePath(ctx, rp.toPlane); ctx.stroke()

        ctx.setLineDash([6, 5])
        ctx.beginPath(); tracePath(ctx, rp.toDest); ctx.stroke()
        ctx.setLineDash([])

        for (const a of [rp.o, rp.d]) {
          ctx.beginPath()
          ctx.arc(a[0], a[1], metrics.s(4), 0, Math.PI * 2)
          ctx.fillStyle = accent
          ctx.strokeStyle = outline
          ctx.lineWidth = 1.5
          ctx.fill(); ctx.stroke()
        }
      }

      // Glyphs: everything unselected first, selected on top.
      const list = layer.visibleList
      let sel = null
      for (let i = 0; i < list.length; i++) {
        const e = list[i]
        if (e.selected) { sel = e; continue }
        const dim = e.ground || e.track < 0
        drawGlyph(ctx, e.x, e.y, e.track < 0 ? 0 : e.track, dim ? muted : primary, outline, 1.0)
      }
      if (sel) {
        // Soft halo so the selection reads even over bright radar returns.
        ctx.beginPath()
        ctx.arc(sel.x, sel.y, layer.glyphSize * 0.95, 0, Math.PI * 2)
        ctx.fillStyle = Qt.rgba(Theme.colors.accent.r, Theme.colors.accent.g, Theme.colors.accent.b, 0.22).toString()
        ctx.fill()
        drawGlyph(ctx, sel.x, sel.y, sel.track < 0 ? 0 : sel.track, accent, outline, 1.25)
      }
    }
  }

  // ---- labels --------------------------------------------------------------
  // Callsign pinned beside the selected glyph.
  Rectangle {
    id: selectedLabel
    visible: layer.selectedHex !== "" && layer.selectedLive
    x: Math.round(layer.selectedX + layer.glyphSize * 0.9 + width > layer.width
                  ? layer.selectedX - layer.glyphSize * 0.9 - width
                  : layer.selectedX + layer.glyphSize * 0.9)
    y: Math.round(Math.max(0, Math.min(layer.height - height, layer.selectedY - height / 2)))
    width: selectedLabelText.implicitWidth + metrics.spacingSmall * 2
    height: selectedLabelText.implicitHeight + metrics.spacingTiny
    radius: metrics.radiusSmall
    color: Theme.colors.accent
    Text {
      id: selectedLabelText
      anchors.centerIn: parent
      text: layer.selectedInfo ? layer.callsignOf(layer.selectedInfo) : ""
      color: Theme.colors.panelDeep
      font.pixelSize: metrics.fontTiny
      font.bold: true
      font.family: "monospace"
    }
  }

  // Airport code labels at each end of the route.
  Repeater {
    model: layer.routePts ? [
      { pt: layer.routePts.o, code: layer.route.origin.icao || layer.route.origin.iata || "ORIG" },
      { pt: layer.routePts.d, code: layer.route.dest.icao || layer.route.dest.iata || "DEST" }
    ] : []
    delegate: Rectangle {
      required property var modelData
      x: Math.round(modelData.pt[0] + metrics.s(7))
      y: Math.round(modelData.pt[1] - height / 2)
      width: airportText.implicitWidth + metrics.spacingSmall * 2
      height: airportText.implicitHeight + metrics.spacingTiny
      radius: metrics.radiusSmall
      color: Theme.colors.panel
      opacity: 0.92
      border.color: Theme.colors.accent
      border.width: 1
      Text {
        id: airportText
        anchors.centerIn: parent
        text: modelData.code
        color: Theme.colors.textPrimary
        font.pixelSize: metrics.fontTiny
        font.bold: true
        font.family: "monospace"
      }
    }
  }

  // Hover tooltip.
  Rectangle {
    id: tooltip
    visible: internal.hoveredHex !== "" && internal.hoveredHex !== layer.selectedHex
    width: tooltipText.implicitWidth + metrics.spacingSmall * 2
    height: tooltipText.implicitHeight + metrics.spacingTiny
    radius: metrics.radiusSmall
    color: Theme.colors.panel
    opacity: 0.94
    border.color: Theme.colors.border
    border.width: 1
    Text {
      id: tooltipText
      anchors.centerIn: parent
      text: internal.hoverLabel
      color: Theme.colors.textPrimary
      font.pixelSize: metrics.fontTiny
      font.family: "monospace"
    }
  }

  // Width of the right edge the info card covers (0 when hidden), so the host
  // can slide the map aside while it is open.
  readonly property real occludedRight: infoCard.visible ? infoCard.width + metrics.spacingSmall * 2 : 0

  // ---- info card -----------------------------------------------------------
  Rectangle {
    id: infoCard
    visible: layer.selectedHex !== "" && layer.selectedInfo !== null
    anchors {
      top: parent.top
      right: parent.right
      margins: metrics.spacingSmall
    }
    width: infoColumn.implicitWidth + metrics.spacingNormal * 2
    height: infoColumn.implicitHeight + metrics.spacingNormal * 2
    radius: metrics.radiusNormal
    color: Theme.colors.panel
    opacity: 0.92
    border.color: Theme.colors.border
    border.width: 1

    readonly property var ac: layer.selectedInfo
    readonly property string subtitle: {
      const a = ac
      if (!a) return ""
      const parts = []
      if (a.reg && a.reg !== a.flight) parts.push(a.reg)
      if (a.type) parts.push(a.type)
      return parts.join(" · ")
    }
    readonly property string routeText: {
      const r = layer.route
      if (!r) return "looking up route…"
      if (r.error || !r.origin || !r.dest) return "route unknown"
      const o = r.origin.icao || r.origin.iata || "?"
      const d = r.dest.icao || r.dest.iata || "?"
      return o + " → " + d
    }
    readonly property string routeDetail: {
      const r = layer.route
      if (!r || r.error || !r.origin || !r.dest) return ""
      const o = r.origin.city || r.origin.name || ""
      const d = r.dest.city || r.dest.name || ""
      return (o && d) ? (o + " → " + d) : ""
    }

    ColumnLayout {
      id: infoColumn
      anchors {
        fill: parent
        margins: metrics.spacingNormal
      }
      spacing: metrics.spacingTiny

      Text {
        text: infoCard.ac ? layer.callsignOf(infoCard.ac) : ""
        color: Theme.colors.accent
        font.pixelSize: metrics.fontNormal
        font.bold: true
        font.family: "monospace"
      }

      Text {
        visible: infoCard.subtitle.length > 0
        text: infoCard.subtitle
        color: Theme.colors.textSecondary
        font.pixelSize: metrics.fontTiny
        font.family: "monospace"
      }

      Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.colors.border }

      GridLayout {
        columns: 2
        columnSpacing: metrics.spacingNormal
        rowSpacing: metrics.spacingTiny / 2

        Text { text: "ALT"; color: Theme.colors.textMuted; font.pixelSize: metrics.fontTiny; font.bold: true; font.family: "monospace" }
        Text { text: layer.altText(infoCard.ac); color: Theme.colors.textPrimary; font.pixelSize: metrics.fontTiny; font.family: "monospace" }

        Text { text: "GS"; color: Theme.colors.textMuted; font.pixelSize: metrics.fontTiny; font.bold: true; font.family: "monospace" }
        Text { text: infoCard.ac ? Math.round(infoCard.ac.gs || 0) + " kt" : ""; color: Theme.colors.textPrimary; font.pixelSize: metrics.fontTiny; font.family: "monospace" }

        Text { text: "TRK"; color: Theme.colors.textMuted; font.pixelSize: metrics.fontTiny; font.bold: true; font.family: "monospace" }
        Text { text: (infoCard.ac && infoCard.ac.track >= 0) ? Math.round(infoCard.ac.track) + "°" : "—"; color: Theme.colors.textPrimary; font.pixelSize: metrics.fontTiny; font.family: "monospace" }

        Text { visible: layer.vrText(infoCard.ac).length > 0; text: "V/S"; color: Theme.colors.textMuted; font.pixelSize: metrics.fontTiny; font.bold: true; font.family: "monospace" }
        Text { visible: layer.vrText(infoCard.ac).length > 0; text: layer.vrText(infoCard.ac); color: Theme.colors.textPrimary; font.pixelSize: metrics.fontTiny; font.family: "monospace" }
      }

      Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.colors.border }

      Text {
        text: infoCard.routeText
        color: infoCard.routeText === "route unknown" ? Theme.colors.textMuted : Theme.colors.textPrimary
        font.pixelSize: metrics.fontTiny
        font.bold: infoCard.routeText !== "route unknown"
        font.italic: infoCard.routeText === "route unknown" || infoCard.routeText === "looking up route…"
        font.family: "monospace"
      }

      Text {
        visible: infoCard.routeDetail.length > 0
        text: infoCard.routeDetail
        color: Theme.colors.textSecondary
        font.pixelSize: metrics.fontTiny
        elide: Text.ElideRight
        Layout.maximumWidth: metrics.s(220)
      }

      Text {
        visible: !layer.selectedLive
        text: "signal lost"
        color: Theme.colors.red
        font.pixelSize: metrics.fontTiny
        font.italic: true
      }
    }

    // Close button.
    Rectangle {
      width: metrics.s(18)
      height: width
      radius: width / 2
      anchors {
        top: parent.top
        right: parent.right
        margins: metrics.spacingTiny
      }
      color: closeMouse.containsMouse ? Theme.colors.inset : "transparent"
      Text {
        anchors.centerIn: parent
        text: "×"
        color: Theme.colors.textMuted
        font.pixelSize: metrics.fontSmall
        font.family: "monospace"
      }
      MouseArea {
        id: closeMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: layer.deselectRequested()
      }
    }
  }

  // ---- input ---------------------------------------------------------------
  // Non-blocking hover tracking (the map beneath still sees hover).
  HoverHandler {
    id: hoverTracker
    onPointChanged: layer.updateHover(point.position.x, point.position.y, true)
    onHoveredChanged: if (!hovered) internal.hoveredHex = ""
  }

  // Pointer cursor only while over a glyph; otherwise leave the cursor alone.
  HoverHandler {
    enabled: internal.hoveredHex !== ""
    cursorShape: Qt.PointingHandCursor
  }

  // Tap ON a glyph: only enabled while a glyph is hovered, so a press anywhere
  // else never reaches this handler. ReleaseWithinBounds keeps the exclusive
  // grab for the whole press so the map beneath sees neither a click nor a
  // drag; hitTest at release decides whether it was really a tap on the glyph.
  TapHandler {
    id: glyphTap
    enabled: internal.hoveredHex !== ""
    gesturePolicy: TapHandler.ReleaseWithinBounds
    acceptedButtons: Qt.LeftButton
    onTapped: (eventPoint) => {
      const hit = layer.hitTest(eventPoint.position.x, eventPoint.position.y)
      if (hit) layer.aircraftClicked(hit.hex, hit.callsign)
    }
  }
}
