import QtQuick
import Qt5Compat.GraphicalEffects
import "../themes"
import "MapMath.js" as MapMath

// Pure-QtQuick slippy map (Web Mercator, 256 px tiles). No QtLocation needed.
//
//   MapView {
//     centerLat: 40.0; centerLon: -100.0; zoom: 6
//     overlayLayers: [ someTileSource ]          // drawn above the basemap
//     SomeOverlay { anchors.fill: parent }       // default children: MapView-local px coords
//   }
//
// Coordinates: lonLatToXY()/xyToLonLat() convert between lon/lat and MapView-local
// pixels. Overlays should reproject on viewChanged() and fetch data on viewSettled().
//
// Tiles: each TileSource gets a TileLayer holding two TileGrids. When the integer
// tile zoom (or the source's nonce) changes, the grid that was showing is frozen
// and kept underneath until the new grid's tiles have loaded, so zooming never
// shows gaps. Tiles fade in on load. Tile models are diffed by key, so panning
// only appends/removes the tiles that entered/left the view (+1 ring).
//
// Globe: below `globeMaxZoom` the same tile stack is rendered for the whole
// world into a texture (ShaderEffectSource) and drawn as an orthographic globe
// by globe.frag. The globe's radius is chosen so the scale at the view centre
// equals the flat map's, so crossing the threshold only curls the edges away;
// a short crossfade covers the switch. Dragging rotates the globe.
Item {
  id: map
  clip: true

  property real centerLat: 0.0
  property real centerLon: 0.0
  property real zoom: 6.0
  property real minZoom: 1.2
  property real maxZoom: 12.0

  // Below this zoom the map is drawn as a globe.
  property real globeMaxZoom: 3.0
  readonly property bool globe: zoom < globeMaxZoom
  // Globe radius in px (scale at the centre matches the flat map).
  readonly property real globeR: MapMath.globeRadius(zoom, centerLat)
  // 0 = flat, 1 = globe; animated so the switch crossfades.
  property real globeMix: globe ? 1 : 0
  Behavior on globeMix { NumberAnimation { duration: 200 } }
  readonly property bool blending: globeMix > 0.001 && globeMix < 0.999
  // While the globe (or the crossfade) is showing, the flat stack is rendered
  // to a texture instead of the scene.
  readonly property bool useTexture: globeMix > 0.001
  // Near and below the threshold the tile grids cover the whole world so the
  // globe texture is complete before it is needed (small hysteresis).
  readonly property bool worldTiles: zoom < globeMaxZoom + 0.35
  // Look of the globe.
  property color rimColor: Theme.colors.accent
  property real rimStrength: 0.35
  property real limbDarkening: 0.45

  // Esri's legacy Canvas tiles are key-free and clean (CARTO's free tiles are
  // watermarked "API KEY REQUIRED" as of 2026). Note Esri's {z}/{y}/{x} order.
  property TileSource baseLayer: TileSource {
    key: "esri-gray-base"
    maxZoom: 16
    attribution: "© Esri"
    urlFor: function(z, x, y) {
      return "https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/"
        + (Theme.colors.isDark ? "World_Dark_Gray_Base" : "World_Light_Gray_Base")
        + "/MapServer/tile/" + z + "/" + y + "/" + x
    }
  }
  property var overlayLayers: []
  property TileSource labelLayer: TileSource {
    key: "esri-gray-labels"
    maxZoom: 16
    opacity: 0.6
    urlFor: function(z, x, y) {
      return "https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/"
        + (Theme.colors.isDark ? "World_Dark_Gray_Reference" : "World_Light_Gray_Reference")
        + "/MapServer/tile/" + z + "/" + y + "/" + x
    }
  }

  // Where the centre lat/lon is drawn, in px from the middle of the item.
  // Lets a host slide the map aside (animated) while something like the
  // aircraft card covers one edge, without touching the logical centre that
  // is shared and persisted. cx/cy are the resulting on-screen centre.
  property real viewOffsetX: 0
  property real viewOffsetY: 0
  Behavior on viewOffsetX { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
  Behavior on viewOffsetY { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
  readonly property real cx: width / 2 + viewOffsetX
  readonly property real cy: height / 2 + viewOffsetY

  property bool interactive: true
  // False while the widget is hidden (e.g. the dashboard is closed on this
  // screen): tiles already loaded stay, but no new tiles are requested until
  // the map is active again. Keeps a hidden screen from doubling tile traffic.
  property bool active: true
  property color backgroundColor: Theme.colors.panelDeep
  property color tint: Theme.colors.panel
  // 0 = raw basemap colours, 1 = fully recoloured to `tint`'s hue/saturation.
  property real tintStrength: 0.85

  // Whole-world grids are capped at z3 (64 tiles) and floored at z2 so the
  // globe texture keeps enough detail at the smallest zooms.
  readonly property int tileZoom: worldTiles ? Math.max(2, Math.min(3, Math.round(zoom)))
                                             : Math.max(0, Math.round(zoom))
  readonly property bool dragging: mouse.isDragging

  signal viewChanged()
  signal viewSettled()
  signal clicked(real lat, real lon)

  default property alias overlays: overlayItem.data

  // ---- world-pixel helpers (continuous zoom) ----
  readonly property real worldSize: MapMath.worldSize(zoom)
  readonly property real centerX: MapMath.lonToX(centerLon, zoom)
  readonly property real centerY: MapMath.latToY(centerLat, zoom)
  // The world square in MapView-local px (where the tile grids draw it).
  readonly property rect worldRect: Qt.rect(cx - centerX, cy - centerY, worldSize, worldSize)

  function lonLatToXY(lon, lat) {
    if (globe) {
      var p = MapMath.orthoProject(lat, lon, centerLat, centerLon)
      if (p.z < 0) return Qt.point(-1e6, -1e6)   // far side of the globe
      return Qt.point(cx + p.x * globeR, cy - p.y * globeR)
    }
    var wx = MapMath.lonToX(lon, zoom)
    var k = Math.round((centerX - wx) / worldSize)
    wx += k * worldSize
    return Qt.point(cx + wx - centerX, cy + MapMath.latToY(lat, zoom) - centerY)
  }

  function xyToLonLat(x, y) {
    if (globe) {
      var gx = (x - cx) / globeR, gy = (cy - y) / globeR
      var r = Math.sqrt(gx * gx + gy * gy)
      if (r > 1) { gx /= r * 1.000001; gy /= r * 1.000001 }   // clamp to the rim
      var ll = MapMath.orthoUnproject(gx, gy, centerLat, centerLon)
      return ll ? ll : { lat: centerLat, lon: centerLon }
    }
    var wx = centerX + x - cx
    var wy = Math.max(0, Math.min(worldSize, centerY + y - cy))
    return { lat: MapMath.yToLat(wy, zoom), lon: MapMath.wrapLon(MapMath.xToLon(wx, zoom)) }
  }

  function viewRadiusNm() {
    if (globe) return 5400   // a hemisphere: 90 deg of arc
    var c1 = xyToLonLat(0, 0), c2 = xyToLonLat(width, 0)
    var c3 = xyToLonLat(0, height), c4 = xyToLonLat(width, height)
    return Math.max(
      MapMath.haversineNm(centerLat, centerLon, c1.lat, c1.lon),
      MapMath.haversineNm(centerLat, centerLon, c2.lat, c2.lon),
      MapMath.haversineNm(centerLat, centerLon, c3.lat, c3.lon),
      MapMath.haversineNm(centerLat, centerLon, c4.lat, c4.lon))
  }

  function setView(lat, lon, z, animate) {
    viewAnim.stop()
    z = Math.max(minZoom, Math.min(maxZoom, z))
    lat = MapMath.clampLat(lat)
    lon = MapMath.wrapLon(lon)
    if (animate) {
      // Take the short way round the antimeridian; wrap back once the animation ends.
      var from = MapMath.wrapLon(centerLon)
      centerLon = from
      var d = lon - from
      if (d > 180) lon -= 360
      else if (d < -180) lon += 360
      animLat.to = lat
      animLon.to = lon
      animZoom.to = z
      viewAnim.start()
    } else {
      zoom = z
      centerLat = lat
      centerLon = lon
      clampCenter()
    }
  }

  function zoomTo(z, animate) { setView(centerLat, centerLon, z, animate) }
  function zoomBy(factor, animate) { zoomTo(zoom + Math.log2(factor), animate) }

  function panBy(dx, dy) {
    viewAnim.stop()
    setCenterWorld(centerX - dx, centerY - dy)
  }

  // Zoom at which the whole globe fits the shorter side with an 8% margin,
  // keeping the current centre.
  function worldZoom() {
    var r = 0.46 * Math.max(1, Math.min(width, height))
    var lat = Math.max(-MapMath.GLOBE_MAX_LAT, Math.min(MapMath.GLOBE_MAX_LAT, centerLat))
    return Math.max(minZoom, Math.min(globeMaxZoom - 0.05, MapMath.globeZoomForRadius(r, lat)))
  }

  function fitWorld(animate) {
    setView(centerLat, centerLon, worldZoom(), animate)
  }

  // Zoom keeping the point under (px, py) fixed (flat map); the globe zooms
  // about its centre.
  function zoomAround(z, px, py, animate) {
    z = Math.max(minZoom, Math.min(maxZoom, z))
    if (Math.abs(z - zoom) < 1e-6) return
    if (globe || z < globeMaxZoom) { setView(centerLat, centerLon, z, animate); return }
    var ll = xyToLonLat(px, py)
    var wx = MapMath.lonToX(ll.lon, z) - (px - cx)
    var wy = MapMath.latToY(ll.lat, z) - (py - cy)
    setView(MapMath.yToLat(wy, z), MapMath.xToLon(wx, z), z, animate)
  }

  function setCenterWorld(wx, wy) {
    centerLon = MapMath.wrapLon(MapMath.xToLon(wx, zoom))
    centerLat = MapMath.yToLat(Math.max(0, Math.min(worldSize, wy)), zoom)
    clampCenter()
  }

  // Keep the visible area inside ±85°: centre vertically when the world is
  // shorter than the view, otherwise stop the edge at the poles.
  function clampCenter() {
    if (globe) {
      var l = Math.max(-MapMath.GLOBE_MAX_LAT, Math.min(MapMath.GLOBE_MAX_LAT, centerLat))
      if (Math.abs(l - centerLat) > 1e-9) centerLat = l
      return
    }
    var wy = centerY
    var target
    if (worldSize <= height) target = worldSize / 2
    else target = Math.max(cy, Math.min(worldSize - (height - cy), wy))
    if (Math.abs(target - wy) > 1e-6) centerLat = MapMath.yToLat(target, zoom)
  }

  onZoomChanged: { clampCenter(); scheduleViewChanged() }
  onViewOffsetXChanged: scheduleViewChanged()
  onViewOffsetYChanged: { clampCenter(); scheduleViewChanged() }
  onGlobeChanged: { clampCenter(); scheduleViewChanged() }
  onHeightChanged: { clampCenter(); scheduleViewChanged() }
  onWidthChanged: scheduleViewChanged()
  onCenterLatChanged: scheduleViewChanged()
  onCenterLonChanged: scheduleViewChanged()

  // Coalesce the several property changes of one pan/zoom step into a single
  // viewChanged (Qt.callLater collapses repeated calls of the same function).
  function scheduleViewChanged() { Qt.callLater(map.emitViewChanged) }
  function emitViewChanged() { map.viewChanged(); settleTimer.restart() }

  Timer {
    id: settleTimer
    interval: 250
    onTriggered: map.viewSettled()
  }

  ParallelAnimation {
    id: viewAnim
    NumberAnimation { id: animLat; target: map; property: "centerLat"; duration: 300; easing.type: Easing.OutCubic }
    NumberAnimation { id: animLon; target: map; property: "centerLon"; duration: 300; easing.type: Easing.OutCubic }
    NumberAnimation { id: animZoom; target: map; property: "zoom"; duration: 300; easing.type: Easing.OutCubic }
    onFinished: { map.centerLon = MapMath.wrapLon(map.centerLon); map.clampCenter() }
  }

  Rectangle {
    anchors.fill: parent
    color: map.backgroundColor
  }

  // ---- interaction (first child = bottom of the stack, so overlay MouseAreas win) ----
  MouseArea {
    id: mouse
    anchors.fill: parent
    enabled: map.interactive
    acceptedButtons: Qt.LeftButton
    cursorShape: isDragging ? Qt.ClosedHandCursor : Qt.ArrowCursor

    property bool isDragging: false
    property real pressX: 0
    property real pressY: 0
    property real startCX: 0
    property real startCY: 0
    property real startLat: 0
    property real startLon: 0
    property real startR: 1

    onPressed: (m) => {
      viewAnim.stop()
      pressX = m.x; pressY = m.y
      startCX = map.centerX; startCY = map.centerY
      startLat = map.centerLat; startLon = map.centerLon; startR = map.globeR
      isDragging = false
    }
    onPositionChanged: (m) => {
      if (!pressed) return
      var dx = m.x - pressX, dy = m.y - pressY
      if (!isDragging && (dx * dx + dy * dy) < 16) return
      isDragging = true
      if (map.globe) {
        // Rotate: one radius of drag turns the globe one radian.
        var k = 180 / Math.PI / startR
        map.centerLon = MapMath.wrapLon(startLon - dx * k)
        map.centerLat = Math.max(-MapMath.GLOBE_MAX_LAT, Math.min(MapMath.GLOBE_MAX_LAT, startLat + dy * k))
      } else {
        map.setCenterWorld(startCX - dx, startCY - dy)
      }
    }
    onReleased: (m) => {
      if (!isDragging) {
        var ll = map.xyToLonLat(m.x, m.y)
        map.clicked(ll.lat, ll.lon)
      }
      isDragging = false
    }
    onCanceled: isDragging = false
    onDoubleClicked: (m) => map.zoomAround(map.zoom + 1, m.x, m.y, true)
    onWheel: (wheel) => {
      // Touchpads / hi-res mice under Wayland report angleDelta (0,0) and only
      // fill pixelDelta, so fall back to it (scaled to roughly one notch per 100 px).
      var dz = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y / 120 * 0.5 : wheel.pixelDelta.y / 100
      if (dz === 0) return
      viewAnim.stop()
      map.zoomAround(map.zoom + dz, wheel.x, wheel.y, false)
    }
  }

  // ---- tile machinery ----
  component TileGrid: Item {
    id: grid
    property var source: null
    property int tileZ: 0
    // Nonce captured when the grid was (re)built. The tile URLs use this, not
    // the live source nonce, so a frozen previous grid keeps showing its old
    // tiles instead of re-fetching the new ones alongside the current grid.
    property int builtNonce: 0
    property bool frozen: false
    property int readyCount: 0
    readonly property int count: tileModel.count
    readonly property bool loaded: tileModel.count > 0 && readyCount >= tileModel.count
    readonly property real tileScreen: MapMath.TILE * Math.pow(2, map.zoom - tileZ)
    property int rx0: 0
    property int rx1: -1
    property int ry0: 0
    property int ry1: -1
    // Position of the grid's parent layer in map coords (baseHolder moves to
    // the world origin while the world grids are active — see below).
    property real originX: 0
    property real originY: 0

    x: Math.round(map.cx - map.centerX) - originX
    y: Math.round(map.cy - map.centerY) - originY

    ListModel { id: tileModel }

    function clear() {
      tileModel.clear()
      rx0 = 0; rx1 = -1; ry0 = 0; ry1 = -1
    }

    function updateRange() {
      if (frozen || !source || !map.active) return
      var n = Math.pow(2, tileZ)
      var ts = tileScreen
      var x0 = Math.floor((map.centerX - map.cx) / ts) - 1
      var x1 = Math.floor((map.centerX + (map.width - map.cx)) / ts) + 1
      var y0 = Math.max(0, Math.floor((map.centerY - map.cy) / ts) - 1)
      var y1 = Math.min(n - 1, Math.floor((map.centerY + (map.height - map.cy)) / ts) + 1)
      if (map.worldTiles) {
        // Globe (and just above it): the whole world as well, so the globe
        // texture is complete. Bounded by tileZoom <= 3 (64 tiles + the
        // viewport's wrapped columns).
        x0 = Math.min(0, x0); x1 = Math.max(n - 1, x1); y0 = 0; y1 = n - 1
      }
      if (x0 === rx0 && x1 === rx1 && y0 === ry0 && y1 === ry1) return
      rx0 = x0; rx1 = x1; ry0 = y0; ry1 = y1

      var wanted = {}
      for (var tx = x0; tx <= x1; tx++)
        for (var ty = y0; ty <= y1; ty++)
          wanted[tx + "," + ty] = true

      for (var i = tileModel.count - 1; i >= 0; i--) {
        var k = tileModel.get(i).key
        if (wanted[k]) delete wanted[k]
        else tileModel.remove(i)
      }
      for (var key in wanted) {
        var p = key.split(",")
        var ttx = parseInt(p[0]), tty = parseInt(p[1])
        tileModel.append({ key: key, tx: ttx, ty: tty, wx: ((ttx % n) + n) % n })
      }
    }

    Repeater {
      model: tileModel
      delegate: Image {
        id: tile
        required property int tx
        required property int ty
        required property int wx
        property bool counted: false

        x: Math.round(tx * grid.tileScreen)
        y: Math.round(ty * grid.tileScreen)
        width: Math.round((tx + 1) * grid.tileScreen) - x
        height: Math.round((ty + 1) * grid.tileScreen) - y

        source: grid.source
          ? grid.source.urlFor(grid.tileZ, wx, ty) + (grid.builtNonce ? "#" + grid.builtNonce : "")
          : ""
        sourceSize: {
          var ts = grid.source && grid.source.tileSize > 0 ? grid.source.tileSize : MapMath.TILE
          return Qt.size(ts, ts)
        }
        asynchronous: true
        cache: true
        smooth: grid.source ? grid.source.smooth : true
        fillMode: Image.Stretch

        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 180 } }

        onStatusChanged: {
          if ((status === Image.Ready || status === Image.Error) && !counted) {
            counted = true
            grid.readyCount++
          }
        }
        Component.onDestruction: if (counted) grid.readyCount--
      }
    }
  }

  component TileLayer: Item {
    id: layer
    property var source: null
    // Keep the outgoing zoom level's tiles underneath until the new ones load.
    // Off for the label layer: stale scaled labels look worse than a brief gap.
    property bool keepPrevious: true
    property real originX: 0
    property real originY: 0
    anchors.fill: parent
    visible: !!source && source.visible && map.tileZoom >= source.minZoom
    opacity: source ? source.opacity : 1

    readonly property int zEff: source ? Math.max(source.minZoom, Math.min(source.maxZoom, map.tileZoom)) : 0
    property TileGrid cur: gridA
    property TileGrid prev: null

    TileGrid { id: gridA; source: layer.source; originX: layer.originX; originY: layer.originY }
    TileGrid { id: gridB; source: layer.source; originX: layer.originX; originY: layer.originY }

    // Bring a fresh grid in at `newZ` and keep the old one underneath until the
    // new tiles are in. Also used for nonce refreshes (same z, new URLs).
    function switchGrid(newZ) {
      var nonce = source ? source.nonce : 0
      // Keep whichever grid has the most tiles on screen. If the user zooms
      // through several levels quickly, the half-loaded intermediate grid is
      // recycled and the fully loaded older one stays underneath instead.
      var keep = cur
      if (prev && prev !== cur && !cur.loaded && prev.readyCount > cur.readyCount) keep = prev
      var reuse = (keep === gridA) ? gridB : gridA

      // Zooming back to a level a grid still holds (e.g. 7 -> 6 -> 7 within a
      // moment): just promote that grid instead of rebuilding it — no refetch,
      // no fade-in.
      if (keep.tileZ === newZ && keep.builtNonce === nonce && keep.count > 0) {
        reuse.clear()
        reuse.frozen = false
        keep.frozen = false
        prev = null
        cur = keep
        gridA.z = (cur === gridA) ? 1 : 0
        gridB.z = (cur === gridB) ? 1 : 0
        cur.updateRange()
        dropSafety.stop()
        return
      }

      reuse.clear()
      reuse.tileZ = newZ
      reuse.builtNonce = nonce
      reuse.frozen = false
      if (keepPrevious && keep.count > 0) {
        keep.frozen = true
        prev = keep
      } else {
        keep.clear()
        prev = null
      }
      cur = reuse
      gridA.z = (cur === gridA) ? 1 : 0   // stacking order: current grid on top
      gridB.z = (cur === gridB) ? 1 : 0
      cur.updateRange()
      dropSafety.restart()
    }

    onZEffChanged: switchGrid(zEff)
    onSourceChanged: {
      gridA.clear(); gridB.clear(); prev = null
      switchGrid(zEff)
    }
    Component.onCompleted: switchGrid(zEff)

    Connections {
      target: layer.source
      function onNonceChanged() { layer.switchGrid(layer.zEff) }
    }
    Connections {
      target: map
      function onViewChanged() { layer.cur.updateRange() }
      function onActiveChanged() { if (map.active) layer.cur.updateRange() }
      function onWorldTilesChanged() { layer.cur.updateRange() }
    }
    Connections {
      target: layer.cur
      function onLoadedChanged() { if (layer.cur.loaded) dropPrev.restart() }
    }
    Timer {
      id: dropPrev
      interval: 260
      onTriggered: layer.dropPrevious()
    }
    Timer {
      id: dropSafety
      interval: 3000
      // While the map is inactive (hidden screen) nothing new loads, so keep
      // the old tiles until it is shown again and the new grid can fill in.
      onTriggered: map.active ? layer.dropPrevious() : dropSafety.restart()
    }
    function dropPrevious() {
      if (prev && prev !== cur) { prev.clear(); prev.frozen = false }
      prev = null
    }
  }

  // ---- the flat tile stack (basemap, overlays, labels) ----
  // In globe mode this is hidden from the scene and rendered into
  // `worldSource` instead (covering the whole world square).
  Item {
    id: worldStack
    anchors.fill: parent

  // Basemap, recoloured toward `tint` so it reads as part of the panel.
  // The Colorize layer only renders the item's own bounds, so while the world
  // grids are active the holder is moved and sized to the whole world square
  // plus a viewport's width either side for the wrapped columns (its grid
  // compensates via originX/Y), so the globe texture is complete.
  Item {
    id: baseHolder
    x: map.worldTiles ? Math.round(map.worldRect.x - map.width) : 0
    y: map.worldTiles ? Math.round(map.worldRect.y) : 0
    width: map.worldTiles ? Math.ceil(map.worldSize + 2 * map.width) : map.width
    height: map.worldTiles ? Math.ceil(map.worldSize) : map.height
    TileLayer { source: map.baseLayer; originX: baseHolder.x; originY: baseHolder.y }
    layer.enabled: map.tintStrength > 0
    layer.effect: Colorize {
      hue: map.tint.hslHue
      saturation: Math.max(0, Math.min(1, map.tint.hslSaturation * map.tintStrength))
      lightness: 0
    }
  }

  // Overlay tile layers, diffed against the incoming array by TileSource
  // identity. A Repeater over a JS array would tear down and recreate every
  // layer each time the array is republished (WeatherLayer does that as loop
  // frames warm up), refetching tiles and fading the whole overlay in again.
  Item {
    id: overlayHolder
    anchors.fill: parent
    property var layerItems: []   // [{source, item}] in draw order

    function sync() {
      var list = map.overlayLayers || []
      var next = []
      var keepItems = []
      for (var i = 0; i < list.length; i++) {
        var src = list[i]
        if (!src) continue
        var item = null
        for (var j = 0; j < layerItems.length; j++) {
          if (layerItems[j].source === src) { item = layerItems[j].item; break }
        }
        if (!item) item = overlayLayerComponent.createObject(overlayHolder, { source: src })
        item.z = i
        next.push({ source: src, item: item })
        keepItems.push(item)
      }
      for (var k = 0; k < layerItems.length; k++) {
        if (keepItems.indexOf(layerItems[k].item) < 0) layerItems[k].item.destroy()
      }
      layerItems = next
    }

    Component {
      id: overlayLayerComponent
      TileLayer {}
    }

    Connections {
      target: map
      function onOverlayLayersChanged() { overlayHolder.sync() }
    }
    Component.onCompleted: sync()
  }

  TileLayer { source: map.labelLayer; keepPrevious: false }
  }   // worldStack

  // ---- globe rendering ----
  // The whole world square of the flat stack, as a texture. Zero-sized so it
  // draws nothing itself; the two ShaderEffects below sample it.
  ShaderEffectSource {
    id: worldSource
    width: 0
    height: 0
    // Detached while flat: at street zooms the world square outgrows the GPU's
    // max texture size and the layer warns on every pan.
    sourceItem: map.useTexture ? worldStack : null
    sourceRect: map.worldRect
    live: map.useTexture
    hideSource: map.useTexture
    mipmap: true
    smooth: true
    wrapMode: ShaderEffectSource.Repeat
  }

  // Flat copy of the texture (three world copies for the wrap-around),
  // pixel-identical to the hidden stack; only shown while crossfading so both
  // projections can blend.
  Repeater {
    model: 3
    ShaderEffect {
      required property int index
      visible: map.blending
      opacity: 1 - map.globeMix
      x: map.worldRect.x + (index - 1) * map.worldSize
      y: map.worldRect.y
      width: map.worldSize
      height: map.worldSize
      property var source: worldSource
    }
  }

  ShaderEffect {
    id: globeFx
    visible: map.useTexture
    opacity: map.globeMix
    // The item is a little larger than the globe so the atmosphere rim fits.
    readonly property real discFrac: 0.94
    readonly property real size: 2 * map.globeR / discFrac
    width: size
    height: size
    x: map.cx - size / 2
    y: map.cy - size / 2

    property var src: worldSource
    property color rimColor: Qt.rgba(map.rimColor.r, map.rimColor.g, map.rimColor.b, map.rimStrength)
    property real cLat: map.centerLat * Math.PI / 180
    property real cLon: map.centerLon * Math.PI / 180
    property real edge: 1.5 / Math.max(1, map.globeR)
    property real limb: map.limbDarkening
    fragmentShader: Qt.resolvedUrl("globe.frag.qsb")
  }

  Item {
    id: overlayItem
    anchors.fill: parent
  }
}
