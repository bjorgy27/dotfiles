import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import "templates"
import "themes"
import "radar"

// Radar dashboard tile: a theme-tinted slippy map (radar/MapView.qml) with
// weather tiles (radar/WeatherLayer.qml — RainViewer global composite or NWS
// WMS products) and live aircraft (radar/AircraftLayer.qml) layered on top.
//
// All state is shared app-wide on the shell root (see shell.qml: mapLat/
// mapLon/mapZoom, mapProduct, mapPlanes, mapAnimate, weatherFrames, aircraft,
// selectedAircraftHex, selectedRoute) so every screen's tile shows the same
// view and only one set of polls runs. The gear button opens
// RadarSettingsWidget (bar.state = "radar_settings").
//
// The root.* values are mirrored onto radarWidget properties up here: this
// file is wrapped by ThreeRowWidget whose own top-level item is also
// "id: root", and middleContent/footerContent are Loader-instantiated into
// that item, so inside them only "radarWidget" is unambiguous.
ThreeRowWidget {
  id: radarWidget

  title: "  Radar"

  // ---- mirrored shared state -------------------------------------------
  property real sharedLat: root.mapLat
  property real sharedLon: root.mapLon
  property real sharedZoom: root.mapZoom
  property string product: root.mapProduct
  property bool planes: root.mapPlanes
  property bool animate: root.mapAnimate
  property var weatherFrames: root.weatherFrames
  property int weatherFramesNonce: root.weatherFramesNonce
  property int nwsNonce: root.nwsNonce
  property string weatherError: root.weatherError
  property var aircraft: root.aircraft
  property real aircraftFetchedAt: root.aircraftFetchedAt
  property string aircraftError: root.aircraftError
  property string selectedHex: root.selectedAircraftHex
  property var selectedRoute: root.selectedRoute
  property real homeLat: root.homeLat
  property real homeLon: root.homeLon

  readonly property real planesMinZoom: 4.0
  readonly property real homeZoom: 8.0

  // The MapView living inside middleContent registers itself here so the
  // shared-view sync below can drive it.
  property var mapItem: null
  readonly property real currentZoom: mapItem ? mapItem.zoom : sharedZoom
  readonly property bool planesActive: planes && currentZoom >= planesMinZoom
  readonly property int aircraftCount: aircraft ? aircraft.length : 0

  // ---- shell -> map: follow the shared view (other screen panned, settings
  // reset, persisted state loaded). Skipped mid-drag so the local gesture wins.
  // root.setMapView assigns lat, lon and zoom one after another, so the three
  // change signals arrive with a half-updated view; Qt.callLater coalesces them
  // into a single sync once all three have landed (otherwise the first signal
  // would push the map to a stale lon/zoom and bounce it straight back).
  onSharedLatChanged: Qt.callLater(radarWidget.syncMapFromShared)
  onSharedLonChanged: Qt.callLater(radarWidget.syncMapFromShared)
  onSharedZoomChanged: Qt.callLater(radarWidget.syncMapFromShared)

  function syncMapFromShared() {
    const m = radarWidget.mapItem
    if (!m || m.dragging) return
    const eps = 1e-6
    if (Math.abs(m.centerLat - radarWidget.sharedLat) < eps
        && Math.abs(m.centerLon - radarWidget.sharedLon) < eps
        && Math.abs(m.zoom - radarWidget.sharedZoom) < eps) return
    m.setView(radarWidget.sharedLat, radarWidget.sharedLon, radarWidget.sharedZoom, false)
  }

  // ---- map -> shell: publish once a gesture has settled.
  function publishView(lat, lon, zoom) {
    root.setMapView(lat, lon, zoom)
  }

  function selectAircraft(hex, callsign) {
    root.selectAircraft(hex, callsign)
  }

  function openSettings() {
    bar.state = "radar_settings"
  }

  function goHome(zoom) {
    if (radarWidget.mapItem)
      radarWidget.mapItem.setView(radarWidget.homeLat, radarWidget.homeLon, zoom, true)
  }

  // Weather product -> tile sources. Non-visual; lives at the top level so
  // both the map (middleContent) and the footer can read it.
  WeatherLayer {
    id: weatherLayer
    product: radarWidget.product
    frames: radarWidget.weatherFrames
    framesNonce: radarWidget.weatherFramesNonce
    nwsNonce: radarWidget.nwsNonce
    // Only run the loop (and its frame preloads) on a screen that is showing it.
    animate: radarWidget.animate && radarWidget.visible
  }

  readonly property string attributionText: {
    const m = radarWidget.mapItem
    const base = (m && m.baseLayer && m.baseLayer.attribution && m.baseLayer.attribution.length > 0)
                 ? m.baseLayer.attribution : "© Esri"
    let parts = [base]
    if (weatherLayer.attribution && weatherLayer.attribution.length > 0)
      parts.push(weatherLayer.attribution)
    if (radarWidget.planes) parts.push("adsb.lol")
    return parts.join(" · ")
  }

  // Round overlay button, matching the old widget's gear/zoom-reset style.
  component MapButton: Rectangle {
    id: btn
    property string glyph: ""
    property real glyphSize: metrics.fontLarge
    property bool active: false
    signal clicked()
    width: metrics.s(32)
    height: metrics.s(32)
    radius: width / 2
    color: btnMouse.containsMouse ? Theme.colors.inset : Qt.rgba(Theme.colors.panel.r, Theme.colors.panel.g, Theme.colors.panel.b, 0.72)
    border.width: 1
    border.color: Qt.rgba(Theme.colors.border.r, Theme.colors.border.g, Theme.colors.border.b, 0.6)

    Text {
      anchors.centerIn: parent
      text: btn.glyph
      color: btn.active ? Theme.colors.accent : (btnMouse.containsMouse ? Theme.colors.textPrimary : Theme.colors.textSecondary)
      font.pixelSize: btn.glyphSize
      font.family: "monospace"
    }

    MouseArea {
      id: btnMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: btn.clicked()
    }
  }

  // Small translucent status pill (loading / errors) — informational, not alarming.
  component StatusPill: Rectangle {
    id: pill
    property string text: ""
    property color textColor: Theme.colors.textMuted
    // Widest the pill may grow before its text elides (set by the container;
    // the Column it lives in has no width of its own to derive this from).
    property real maxWidth: metrics.s(320)
    visible: text.length > 0
    implicitWidth: pillLabel.width + metrics.spacingNormal * 2
    implicitHeight: metrics.s(22)
    radius: height / 2
    color: Qt.rgba(Theme.colors.panel.r, Theme.colors.panel.g, Theme.colors.panel.b, 0.85)
    border.width: 1
    border.color: Theme.colors.border

    Text {
      id: pillLabel
      anchors.centerIn: parent
      text: pill.text
      color: pill.textColor
      font.pixelSize: metrics.fontTiny
      font.italic: true
      elide: Text.ElideRight
      width: Math.min(implicitWidth, Math.max(metrics.s(40), pill.maxWidth - metrics.spacingNormal * 2))
    }
  }

  middleContent: Component {
    Item {
      id: mapSlot

      // Rounded-corner clip for the whole map stack.
      Item {
        id: mapFrame
        anchors.fill: parent
        layer.enabled: true
        layer.effect: OpacityMask {
          maskSource: Rectangle {
            width: mapFrame.width
            height: mapFrame.height
            radius: metrics.radiusNormal
          }
        }

        MapView {
          id: map
          anchors.fill: parent
          clip: true
          centerLat: radarWidget.sharedLat
          centerLon: radarWidget.sharedLon
          zoom: radarWidget.sharedZoom
          overlayLayers: weatherLayer.tileSources
          // Hidden screens keep their loaded tiles but stop fetching new ones.
          active: radarWidget.visible
          // Slide the view aside while the aircraft card covers the right edge,
          // so the centre sits in the uncovered part; slides back when it closes.
          viewOffsetX: -aircraftLayer.occludedRight / 2

          Component.onCompleted: {
            radarWidget.mapItem = map
            radarWidget.syncMapFromShared()
          }
          Component.onDestruction: {
            if (radarWidget.mapItem === map) radarWidget.mapItem = null
          }

          onViewSettled: radarWidget.publishView(map.centerLat, map.centerLon, map.zoom)
          onClicked: (lat, lon) => radarWidget.selectAircraft("", "")

          // ---- overlays (MapView-local coordinates) ----

          AircraftLayer {
            id: aircraftLayer
            anchors.fill: parent
            visible: radarWidget.planesActive
            map: map
            aircraft: radarWidget.aircraft
            fetchedAt: radarWidget.aircraftFetchedAt
            selectedHex: radarWidget.selectedHex
            route: radarWidget.selectedRoute
            homeLat: radarWidget.homeLat
            homeLon: radarWidget.homeLon
            onAircraftClicked: (hex, callsign) => radarWidget.selectAircraft(hex, callsign)
            onDeselectRequested: radarWidget.selectAircraft("", "")
          }

          // "You are here" marker. Double-click zooms in on home.
          Item {
            id: homeMarker
            anchors.fill: parent
            property point p: Qt.point(-100, -100)

            function reproject() {
              p = map.lonLatToXY(radarWidget.homeLon, radarWidget.homeLat)
            }
            Component.onCompleted: reproject()
            Connections {
              target: map
              function onViewChanged() { homeMarker.reproject() }
            }
            Connections {
              target: radarWidget
              function onHomeLatChanged() { homeMarker.reproject() }
              function onHomeLonChanged() { homeMarker.reproject() }
            }

            Rectangle {
              id: homeDot
              visible: homeMarker.p.x >= 0 && homeMarker.p.x <= homeMarker.width
                    && homeMarker.p.y >= 0 && homeMarker.p.y <= homeMarker.height
              width: metrics.s(10)
              height: width
              radius: width / 2
              x: homeMarker.p.x - width / 2
              y: homeMarker.p.y - height / 2
              color: Theme.colors.red
              border.color: "white"
              border.width: metrics.s(1.5)

              // Soft halo so the dot reads over busy radar returns.
              Rectangle {
                anchors.centerIn: parent
                width: parent.width * 2.2
                height: width
                radius: width / 2
                z: -1
                color: Qt.rgba(Theme.colors.red.r, Theme.colors.red.g, Theme.colors.red.b, 0.22)
              }

              MouseArea {
                anchors.fill: parent
                anchors.margins: -metrics.s(6)
                cursorShape: Qt.PointingHandCursor
                onDoubleClicked: radarWidget.goHome(radarWidget.homeZoom)
              }
            }
          }
        }
      }

      // ---- controls: stacked top-left (top-right is reserved for the
      // aircraft info card drawn by AircraftLayer) ----
      Column {
        id: controls
        anchors {
          top: parent.top
          left: parent.left
          margins: metrics.spacingSmall
        }
        spacing: metrics.spacingTiny

        MapButton { glyph: "⚙"; onClicked: radarWidget.openSettings() }
        MapButton { glyph: "+"; onClicked: map.zoomBy(2.0, true) }
        MapButton { glyph: "−"; onClicked: map.zoomBy(0.5, true) }
        MapButton { glyph: "󰋜"; glyphSize: metrics.fontNormal; onClicked: radarWidget.goHome(7) }
        MapButton { glyph: "󰇧"; glyphSize: metrics.fontNormal; active: map.globe; onClicked: map.fitWorld(true) }
      }

      // ---- status pills: beside the controls ----
      Column {
        id: statusPills
        anchors {
          top: parent.top
          left: controls.right
          margins: metrics.spacingSmall
        }
        spacing: metrics.spacingTiny
        // Leave room for the aircraft info card on the right.
        readonly property real pillMax: Math.max(metrics.s(60), mapSlot.width * 0.5 - controls.width)

        StatusPill {
          maxWidth: statusPills.pillMax
          text: radarWidget.product === "rainviewer"
                && radarWidget.weatherError.length === 0
                && (!radarWidget.weatherFrames || radarWidget.weatherFrames.length === 0)
                ? "Loading radar…" : ""
        }
        StatusPill {
          maxWidth: statusPills.pillMax
          text: radarWidget.product !== "none" && radarWidget.weatherError.length > 0
                ? "Weather: " + radarWidget.weatherError : ""
        }
        StatusPill {
          maxWidth: statusPills.pillMax
          text: radarWidget.planesActive && radarWidget.aircraftError.length > 0
                ? "Aircraft: " + radarWidget.aircraftError : ""
        }
      }

      // ---- frame scrubber: bottom-left (RainViewer loop only) ----
      FrameScrubber {
        id: scrubber
        visible: radarWidget.product === "rainviewer" && weatherLayer.frames && weatherLayer.frames.length > 0
        anchors {
          left: parent.left
          bottom: parent.bottom
          margins: metrics.spacingSmall
        }
        frames: weatherLayer.frames
        frameIndex: weatherLayer.frameIndex
        playing: weatherLayer.playing
        label: weatherLayer.frameLabel
        onPlayToggled: weatherLayer.playing ? weatherLayer.pause() : weatherLayer.play()
        onFrameSelected: index => weatherLayer.goTo(index)
      }

    }
  }

  footerContent: Component {
    RowLayout {
      spacing: metrics.spacingLarge

      RowLayout {
        spacing: metrics.spacingTiny
        Rectangle {
          implicitWidth: metrics.s(8); implicitHeight: metrics.s(8); radius: metrics.s(4)
          color: radarWidget.product === "none" ? Theme.colors.textMuted : Theme.colors.blue
        }
        Text {
          text: weatherLayer.productName
          color: Theme.colors.textSecondary
          font.pixelSize: metrics.fontTiny
          font.bold: true
        }
      }

      Text {
        visible: weatherLayer.frameLabel.length > 0
        text: weatherLayer.frameLabel
        color: Theme.colors.textSecondary
        font.pixelSize: metrics.fontTiny
        font.family: "monospace"
      }

      RowLayout {
        spacing: metrics.spacingTiny
        visible: radarWidget.planes
        Rectangle {
          implicitWidth: metrics.s(8); implicitHeight: metrics.s(8); radius: metrics.s(4)
          color: radarWidget.planesActive ? Theme.colors.yellow : Theme.colors.textMuted
        }
        Text {
          text: radarWidget.planesActive
                ? (radarWidget.aircraftCount + " aircraft")
                : "zoom in for aircraft"
          color: Theme.colors.textSecondary
          font.pixelSize: metrics.fontTiny
        }
      }

      Item { Layout.fillWidth: true }

      Text {
        text: radarWidget.attributionText
        color: Theme.colors.textMuted
        font.pixelSize: metrics.fontTiny
        font.italic: true
        elide: Text.ElideRight
        Layout.maximumWidth: metrics.s(260)
      }
    }
  }
}
