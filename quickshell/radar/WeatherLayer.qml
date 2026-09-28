import QtQuick
import "MapMath.js" as MapMath

// Non-visual: turns the shared weather state (product + RainViewer frame index)
// into TileSource objects for MapView.overlayLayers, and owns the frame-loop
// animation. Sources are only rebuilt when the *set* of needed frames changes;
// stepping through frames just flips opacity on already-created sources, so
// the tiles stay loaded and the loop never flickers.
//
//   WeatherLayer {
//     id: weatherLayer
//     product: root.mapProduct;  frames: root.weatherFrames;  framesNonce: root.weatherFramesNonce
//     nwsNonce: root.nwsNonce;   animate: root.mapAnimate
//   }
//   MapView { overlayLayers: weatherLayer.tileSources }
Item {
  id: layer
  visible: false
  width: 0
  height: 0

  // ---- inputs ----
  property string product: "rainviewer"   // rainviewer | nws_bref | none
  property var frames: []                 // [{time, kind: "past"|"nowcast", url}]
  property int framesNonce: 0
  property int nwsNonce: 0
  property bool animate: false
  // Index into `frames` of the frame being shown. Defaults to the newest
  // "past" frame; stays on the newest past frame across refreshes while paused.
  property int frameIndex: -1

  // ---- outputs ----
  readonly property var tileSources: internal.sources
  // `animate` (the persisted setting) is the default; play()/pause()/goTo()
  // override it for this session so the scrubber's button always works, even
  // with the loop setting off. Re-syncs to `animate` whenever that changes.
  readonly property bool playing: layer.product === "rainviewer" && layer.frames.length > 1
                                  && internal.wantPlay
  // Loop frames stay preloaded while the loop is on in settings or the user
  // pressed play, so pausing/resuming never refetches tiles.
  readonly property bool loopArmed: layer.product === "rainviewer" && (layer.animate || internal.wantPlay)
  readonly property string frameLabel: {
    if (layer.product !== "rainviewer") return ""
    const f = internal.frameAt(layer.frameIndex)
    if (!f) return ""
    return MapMath.formatTime(f.time) + (f.kind === "nowcast" ? " ▸" : "")
  }
  readonly property string productName: {
    switch (layer.product) {
    case "rainviewer": return "Radar"
    case "nws_bref":   return "NWS MRMS Reflectivity"
    case "none":       return "Off"
    default:           return layer.product
    }
  }
  readonly property string attribution: {
    if (layer.product === "rainviewer") return "RainViewer"
    if (layer.product.indexOf("nws_") === 0) return "NOAA / NWS"
    return ""
  }

  // ---- controls ----
  function play() { internal.wantPlay = true }
  function pause() { internal.wantPlay = false }
  function step(delta) {
    if (layer.frames.length === 0) return
    const n = layer.frames.length
    layer.frameIndex = (((layer.frameIndex + delta) % n) + n) % n
  }
  // Scrubbing to a frame pauses on it (otherwise the loop would jump away
  // half a second later); press play to resume.
  function goTo(index) {
    if (index < 0 || index >= layer.frames.length) return
    internal.wantPlay = false
    layer.frameIndex = index
  }

  // ---- tuning ----
  readonly property int rainviewerColor: 4     // TWC palette
  readonly property int rainviewerSmooth: 1
  readonly property int rainviewerSnow: 1
  readonly property real rainviewerOpacity: 0.85
  readonly property int rainviewerMaxZoom: 7       // free tile endpoint serves a "zoom not supported" placeholder above z7 (verified z8-11, 256 and 512)
  readonly property int rainviewerTileSize: 512    // 512 px tiles at z7 give z8-equivalent detail when MapView scales them up
  readonly property int loopPastFrames: 5      // newest past frames kept in the loop (+ nowcast, <= 6 total; RainViewer 429s on bursts)
  readonly property int warmupMs: 600          // gap between admitting loop frames
  readonly property int frameMs: 500
  readonly property int lastFrameDwellMs: 1500

  QtObject {
    id: internal
    property var sources: []
    property var byKey: ({})          // key -> TileSource
    property var sourceKeys: []       // keys of `sources`, in order (for change detection)
    property bool wantPlay: false     // session play state (seeded from `animate`)
    // Loop warm-up: frames are admitted one at a time (newest first) so
    // enabling the loop doesn't fire N frames x M tiles of requests at once —
    // RainViewer answers bursts with 429s. Grows to loopIndices().length.
    property int allowedFrames: 1

    function frameAt(i) {
      return (i >= 0 && i < layer.frames.length) ? layer.frames[i] : null
    }

    function newestPastIndex() {
      let idx = -1
      for (let i = 0; i < layer.frames.length; i++) {
        if (layer.frames[i].kind !== "nowcast") idx = i
      }
      return idx >= 0 ? idx : layer.frames.length - 1
    }

    // Indices in `frames` that take part in the loop: last N past + all nowcast.
    function loopIndices() {
      const past = [], now = []
      for (let i = 0; i < layer.frames.length; i++) {
        (layer.frames[i].kind === "nowcast" ? now : past).push(i)
      }
      return past.slice(Math.max(0, past.length - layer.loopPastFrames)).concat(now)
    }

    // The loop frames that currently have sources (newest `allowedFrames`).
    function activeLoop() {
      const all = loopIndices()
      return all.slice(Math.max(0, all.length - allowedFrames))
    }

    function frameKey(f) { return "rv:" + f.time + ":" + f.url }

    function rainviewerSource(f) {
      const base = f.url + "/" + layer.rainviewerTileSize + "/"
      const tail = "/" + layer.rainviewerColor + "/" + layer.rainviewerSmooth + "_" + layer.rainviewerSnow + ".png"
      return sourceComponent.createObject(layer, {
        key: frameKey(f),
        urlFor: function(z, x, y) { return base + z + "/" + x + "/" + y + tail },
        minZoom: 0,
        maxZoom: layer.rainviewerMaxZoom,
        tileSize: layer.rainviewerTileSize,
        opacity: 0,
        visible: true,
        smooth: false,
        attribution: "RainViewer"
      })
    }

    function nwsLayerName(product) {
      // Only MRMS base reflectivity is served by NWS's ArcGIS radar service.
      // (The opengeo.ncep.noaa.gov WMS composite/echo-top/precip-type layers
      // return fully transparent rasters as of Sep 2026, so they were dropped.)
      return product === "nws_bref" ? "radar_base_reflectivity" : ""
    }

    function nwsSource(product) {
      const name = nwsLayerName(product)
      // ArcGIS MapServer "export" rendered straight into the tile's Web-Mercator
      // bbox — behaves exactly like a 256 px tile server.
      const prefix = "https://mapservices.weather.noaa.gov/eventdriven/rest/services/radar/"
        + name + "/MapServer/export?bbox="
      const suffix = "&bboxSR=3857&imageSR=3857&size=256,256&format=png32&transparent=true&f=image&_="
      return sourceComponent.createObject(layer, {
        key: "nws:" + name,
        urlFor: function(z, x, y) {
          const b = MapMath.tileBounds3857(z, x, y)
          // Fixed decimals keep the URL stable for identical tiles (cache hits).
          return prefix + b.minx.toFixed(2) + "," + b.miny.toFixed(2) + ","
                 + b.maxx.toFixed(2) + "," + b.maxy.toFixed(2) + suffix + layer.nwsNonce
        },
        minZoom: 0,
        maxZoom: 12,
        opacity: 0.85,
        visible: true,
        smooth: true,
        nonce: layer.nwsNonce,
        attribution: "NOAA / NWS"
      })
    }

    // Which sources should exist right now, as [{key, build}] in draw order.
    function desired() {
      const out = []
      if (layer.product === "rainviewer") {
        let idx = []
        if (layer.loopArmed) idx = activeLoop()
        if (layer.frameIndex >= 0 && idx.indexOf(layer.frameIndex) < 0) idx.push(layer.frameIndex)
        idx.sort((a, b) => a - b)
        for (const i of idx) {
          const f = layer.frames[i]
          if (f) out.push({ key: frameKey(f), build: () => rainviewerSource(f) })
        }
      } else if (nwsLayerName(layer.product) !== "") {
        const p = layer.product
        out.push({ key: "nws:" + nwsLayerName(p), build: () => nwsSource(p) })
      }
      return out
    }

    function sameKeys(a, b) {
      if (a.length !== b.length) return false
      for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
      return true
    }

    // Rebuild the source set if membership changed, then apply per-frame
    // opacity. Reuses existing TileSource objects so tiles never reload.
    function sync() {
      const want = desired()
      const wantKeys = want.map(w => w.key)
      if (!sameKeys(wantKeys, sourceKeys)) {
        const next = {}
        const list = []
        for (const w of want) {
          const existing = byKey[w.key]
          const src = existing ? existing : w.build()
          next[w.key] = src
          list.push(src)
        }
        for (const k in byKey) {
          if (!next[k]) byKey[k].destroy()
        }
        byKey = next
        sourceKeys = wantKeys
        applyOpacity()      // set before publishing so consumers never see a stale frame lit
        sources = list
        return
      }
      applyOpacity()
    }

    function applyOpacity() {
      if (layer.product !== "rainviewer") return
      const f = frameAt(layer.frameIndex)
      const cur = f ? frameKey(f) : ""
      for (const k in byKey) {
        byKey[k].opacity = (k === cur) ? layer.rainviewerOpacity : 0
      }
    }
  }

  Component {
    id: sourceComponent
    TileSource {}
  }

  // ---- reactions ----
  onFramesChanged: internal.sync()
  onFramesNonceChanged: {
    // New index arrived. Paused: snap to the newest past frame. Playing: keep
    // going, just make sure the index is still in range.
    if (!layer.playing || layer.frameIndex < 0 || layer.frameIndex >= layer.frames.length) {
      layer.frameIndex = internal.newestPastIndex()
    }
    // A refresh usually swaps just one frame; keep whatever is already warm.
    internal.allowedFrames = Math.max(1, Math.min(internal.allowedFrames, internal.loopIndices().length))
    internal.sync()
  }
  onProductChanged: {
    if (layer.product === "rainviewer" && layer.frameIndex < 0) {
      layer.frameIndex = internal.newestPastIndex()
    }
    internal.sync()
  }
  onAnimateChanged: {
    internal.wantPlay = layer.animate
    internal.allowedFrames = 1
    if (!layer.animate) layer.frameIndex = internal.newestPastIndex()
    internal.sync()
  }
  onFrameIndexChanged: internal.sync()
  onNwsNonceChanged: {
    for (const k in internal.byKey) {
      if (k.indexOf("nws:") === 0) internal.byKey[k].nonce = layer.nwsNonce
    }
  }

  Component.onCompleted: {
    internal.wantPlay = layer.animate
    if (layer.frameIndex < 0) layer.frameIndex = internal.newestPastIndex()
    internal.sync()
  }
  Component.onDestruction: {
    for (const k in internal.byKey) internal.byKey[k].destroy()
  }

  Timer {
    id: warmupTimer
    running: layer.loopArmed && internal.allowedFrames < internal.loopIndices().length
    repeat: true
    interval: layer.warmupMs
    onTriggered: {
      internal.allowedFrames++
      internal.sync()
    }
  }

  Timer {
    id: loopTimer
    running: layer.playing
    repeat: true
    interval: {
      const loop = internal.activeLoop()
      const last = loop.length > 0 ? loop[loop.length - 1] : -1
      return layer.frameIndex === last ? layer.lastFrameDwellMs : layer.frameMs
    }
    onTriggered: {
      const loop = internal.activeLoop()
      if (loop.length === 0) return
      const pos = loop.indexOf(layer.frameIndex)
      layer.frameIndex = loop[(pos + 1) % loop.length]   // pos -1 -> loop[0]
    }
  }
}
