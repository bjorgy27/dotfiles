// Dashboard preset loader. One instance lives in the root Scope and is shared
// by every screen (like the polling processes). It reads:
//
//   presets.json        committed defaults (schema documented in README.md)
//   presets.local.json  optional, gitignored per-device overrides — the
//                       quickshell counterpart of hypr/perdevice.lua. Presets
//                       in it replace/extend the committed ones by name.
//   $XDG_STATE_HOME/quickshell/dashboard.json
//                       remembers the preset last chosen over IPC.
//
// Both preset files are watched, so editing them updates the dashboard live.
// A missing or invalid presets.json logs an error and falls back to the
// built-in copy of "default" below, so the dashboard never comes up empty.
//
// IPC (see `qs ipc show`):
//   qs ipc call dashboard setPreset <name> | nextPreset | getPreset | listPresets | reload

import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: config

  // === WIDGET REGISTRY: preset "type" -> QML file (+ fixed initial props) ===
  // Adding a widget file needs exactly one line here. Widgets receive the
  // preset entry's `options` object as an initial property, so they should
  // declare `property var options: ({})` (DataWidget/ThreeRowWidget already do).
  // `service` (optional) is a command run once per shell — shared by every
  // screen — while a widget of that type is in the active preset; see below.
  readonly property var registry: ({
    "canvas":      { file: "CanvasWidget.qml" },
    "systemstats": { file: "SystemStatsWidget.qml" },
    "miscstats":   { file: "MiscStatsWidget.qml" },
    "radar":       { file: "RadarWidget.qml" },
    "weather":     { file: "WeatherWidget.qml" },
    "network":     { file: "NetworkStatsWidget.qml" },
    "music":       { file: "MusicWidget.qml" },
    "bambu":       { file: "BambuWidget.qml" }
  })

  readonly property string configDir: root.home + "/.config/quickshell"
  readonly property string presetsPath: configDir + "/presets.json"
  readonly property string localPath: configDir + "/presets.local.json"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (root.home + "/.local/state")) + "/quickshell"
  readonly property string statePath: stateDir + "/dashboard.json"

  // Mirror of the "default" preset in presets.json, already in normalized
  // form. Used when that file is missing or invalid.
  readonly property var builtinDefault: ({
    name: "default", columns: 6, portraitColumns: 2, widthPercent: 60,
    widgets: [
      { type: "canvas",      col: 0, row: 0,   colSpan: 2, rowSpan: 3.8, options: {} },
      { type: "systemstats", col: 0, row: 3.8, colSpan: 1, rowSpan: 1.6, options: {} },
      { type: "miscstats",   col: 1, row: 3.8, colSpan: 1, rowSpan: 1.6, options: {} },
      { type: "radar",       col: 2, row: 0,   colSpan: 4, rowSpan: 4.2, options: {} },
      { type: "weather",     col: 2, row: 4.2, colSpan: 2, rowSpan: 1.2, options: {} },
      { type: "network",     col: 4, row: 4.2, colSpan: 2, rowSpan: 1.2, options: {} }
    ],
    portrait: {
      columns: 2,
      widgets: [
        { type: "canvas",      col: 0, row: 0,   colSpan: 2, rowSpan: 3.0, options: {} },
        { type: "systemstats", col: 0, row: 3.0, colSpan: 1, rowSpan: 1.6, options: {} },
        { type: "miscstats",   col: 1, row: 3.0, colSpan: 1, rowSpan: 1.6, options: {} },
        { type: "radar",       col: 0, row: 4.6, colSpan: 2, rowSpan: 4.2, options: {} },
        { type: "weather",     col: 0, row: 8.8, colSpan: 1, rowSpan: 1.2, options: {} },
        { type: "network",     col: 1, row: 8.8, colSpan: 1, rowSpan: 1.2, options: {} }
      ]
    }
  })

  // Merged, validated presets (name -> preset) in file order.
  property var presets: ({})
  property var presetNames: []
  // "active" keys from the two files, and the name remembered in the state file.
  property string fileActive: ""
  property string localActive: ""
  property string savedName: ""
  property string activeName: ""
  // False until the first rebuild so screens don't instantiate the built-in
  // default and then immediately rebuild once presets.json arrives.
  property bool ready: false
  readonly property var activePreset: ready ? (presets[activeName] ?? builtinDefault) : null

  property bool presetsFileOk: false
  property bool localFileOk: false

  // === WIDGET SERVICES ===
  // One background process per registry entry with a `service`, alive while
  // the active preset uses that type. A service prints "ready" on stdout once
  // it accepts requests; widgets read `dashboardConfig.serviceReady[type]`.
  property var serviceReady: ({})
  readonly property var activeServices: {
    if (!activePreset) return []
    let types = {}
    for (let w of activePreset.widgets) types[w.type] = true
    if (activePreset.portrait) for (let w of activePreset.portrait.widgets) types[w.type] = true
    return Object.keys(types).filter(t => registry[t] && registry[t].service)
  }
  function setServiceReady(type, ready) {
    let r = Object.assign({}, serviceReady)
    r[type] = ready
    serviceReady = r
  }
  Instantiator {
    id: services
    model: config.activeServices
    delegate: Process {
      readonly property string type: modelData
      command: config.registry[type].service
      running: true
      stdout: SplitParser {
        onRead: line => { if (line.trim() === "ready") config.setServiceReady(type, true) }
      }
      // Services log status on stderr; only lines that look like failures are warnings.
      stderr: SplitParser {
        onRead: line => {
          let l = line.trim()
          if (l === "") return
          if (/error|fail|traceback|exception/i.test(l)) console.warn("service " + type + ": " + l)
          else console.info("service " + type + ": " + l)
        }
      }
      onExited: (code, status) => {
        config.setServiceReady(type, false)
        console.warn("service " + type + " exited with code " + code + "; the supervisor will restart it")
      }
      Component.onDestruction: config.setServiceReady(type, false)
    }
  }
  // Supervisor: restart any service that has exited.
  Timer {
    interval: 3000
    repeat: true
    running: config.activeServices.length > 0
    onTriggered: {
      for (let i = 0; i < services.count; i++) {
        let p = services.objectAt(i)
        if (p && !p.running) p.running = true
      }
    }
  }

  FileView {
    id: presetsFile
    path: config.presetsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { config.presetsFileOk = true; config.rebuild() }
    onLoadFailed: error => {
      config.presetsFileOk = false
      console.error("dashboard: cannot read " + config.presetsPath + " (FileViewError " + error + "); using built-in default preset")
      config.rebuild()
    }
  }

  FileView {
    id: localFile
    path: config.localPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { config.localFileOk = true; config.rebuild() }
    // A missing local file is the normal case; only rebuild if it went away.
    onLoadFailed: { let had = config.localFileOk; config.localFileOk = false; if (had) config.rebuild() }
  }

  FileView {
    id: stateFile
    path: config.statePath
    printErrors: false
    onLoaded: {
      try {
        let s = JSON.parse(text())
        if (typeof s.preset === "string") config.savedName = s.preset
      } catch (e) {
        console.warn("dashboard: ignoring invalid state file " + config.statePath + ": " + e.message)
      }
      if (config.ready) config.resolveActive()
    }
    onSaveFailed: error => console.error("dashboard: could not write " + config.statePath + " (FileViewError " + error + ")")
  }

  // The state dir may not exist yet on a fresh device.
  Process {
    command: ["mkdir", "-p", config.stateDir]
    running: true
  }

  IpcHandler {
    target: "dashboard"

    function setPreset(name: string): string {
      if (!(name in config.presets)) {
        return "unknown preset \"" + name + "\" (available: " + config.presetNames.join(", ") + ")"
      }
      config.select(name)
      return "active preset: " + name
    }

    function nextPreset(): string {
      let names = config.presetNames
      if (names.length === 0) return "no presets loaded"
      let next = names[(names.indexOf(config.activeName) + 1) % names.length]
      config.select(next)
      return "active preset: " + next
    }

    function getPreset(): string { return config.activeName }

    function listPresets(): string {
      return config.presetNames.map(n => (n === config.activeName ? "* " : "  ") + n).join("\n")
    }

    function reload(): void {
      presetsFile.reload()
      localFile.reload()
    }

  }

  // Next preset in file order (SUPER+SHIFT+N and the nextPreset IPC call).
  function cycle() {
    let names = presetNames
    if (names.length === 0) return ""
    let next = names[(names.indexOf(activeName) + 1) % names.length]
    select(next)
    return next
  }

  function select(name) {
    savedName = name
    activeName = name
    stateFile.setText(JSON.stringify({ preset: name }) + "\n")
    console.info("dashboard: switched to preset \"" + name + "\"")
  }

  // === PARSING / VALIDATION ===
  function num(v, fallback) {
    return (typeof v === "number" && isFinite(v)) ? v : fallback
  }

  function normalizeWidget(raw, where) {
    if (typeof raw !== "object" || raw === null || typeof raw.type !== "string") {
      console.warn("dashboard: " + where + ": entry needs a string \"type\"; skipped")
      return null
    }
    if (!(raw.type in registry)) {
      console.warn("dashboard: " + where + ": unknown widget type \"" + raw.type + "\" (known: " + Object.keys(registry).join(", ") + "); skipped")
      return null
    }
    let w = {
      type: raw.type,
      colSpan: Math.max(1, Math.floor(num(raw.colSpan, 1))),
      rowSpan: Math.max(0.25, num(raw.rowSpan, 1)),
      options: (typeof raw.options === "object" && raw.options !== null) ? raw.options : {}
    }
    if (raw.col !== undefined) w.col = Math.max(0, Math.floor(num(raw.col, 0)))
    if (raw.row !== undefined) w.row = Math.max(0, num(raw.row, 0))
    return w
  }

  function normalizeWidgets(list, where) {
    if (!Array.isArray(list)) {
      console.error("dashboard: " + where + ": \"widgets\" must be an array")
      return null
    }
    let out = []
    for (let i = 0; i < list.length; i++) {
      let w = normalizeWidget(list[i], where + " widgets[" + i + "]")
      if (w) out.push(w)
    }
    return out
  }

  function normalizePreset(name, raw, where) {
    if (typeof raw !== "object" || raw === null) {
      console.error("dashboard: " + where + ": preset must be an object; skipped")
      return null
    }
    let widgets = normalizeWidgets(raw.widgets, where)
    if (!widgets) return null
    let p = {
      name: name,
      columns: Math.max(1, Math.floor(num(raw.columns, 4))),
      portraitColumns: Math.max(1, Math.floor(num(raw.portraitColumns, 2))),
      widthPercent: Math.min(100, Math.max(10, num(raw.widthPercent, 60))),
      widgets: widgets,
      portrait: null
    }
    if (raw.portrait !== undefined) {
      if (typeof raw.portrait === "object" && raw.portrait !== null) {
        let pw = normalizeWidgets(raw.portrait.widgets, where + " portrait")
        if (pw) p.portrait = { columns: Math.max(1, Math.floor(num(raw.portrait.columns, p.portraitColumns))), widgets: pw }
      } else {
        console.warn("dashboard: " + where + ": \"portrait\" must be an object; using automatic reflow")
      }
    }
    return p
  }

  // Returns { presets, order, active } or null (errors already logged).
  function parseFile(view, label) {
    let data
    try {
      data = JSON.parse(view.text())
    } catch (e) {
      console.error("dashboard: " + label + " is not valid JSON: " + e.message)
      return null
    }
    if (typeof data !== "object" || data === null || typeof data.presets !== "object" || data.presets === null || Array.isArray(data.presets)) {
      console.error("dashboard: " + label + ": expected a top-level \"presets\" object")
      return null
    }
    let presets = {}
    let order = []
    for (let name in data.presets) {
      let p = normalizePreset(name, data.presets[name], label + " preset \"" + name + "\"")
      if (p) { presets[name] = p; order.push(name) }
    }
    if (order.length === 0) {
      console.error("dashboard: " + label + " defines no usable presets")
      return null
    }
    return { presets: presets, order: order, active: typeof data.active === "string" ? data.active : "" }
  }

  function rebuild() {
    let merged, order, source
    let base = presetsFileOk ? parseFile(presetsFile, "presets.json") : null
    if (base) {
      merged = base.presets
      order = base.order
      fileActive = base.active
      source = "presets.json"
    } else {
      merged = { "default": builtinDefault }
      order = ["default"]
      fileActive = ""
      source = "built-in default"
    }
    localActive = ""
    if (localFileOk) {
      let local = parseFile(localFile, "presets.local.json")
      if (local) {
        for (let name of local.order) {
          if (!(name in merged)) order.push(name)
          merged[name] = local.presets[name]
        }
        localActive = local.active
        source += " + presets.local.json"
      }
    }
    presets = merged
    presetNames = order
    ready = true
    resolveActive()
    console.info("dashboard: loaded presets [" + order.join(", ") + "] from " + source + "; active: " + activeName)
  }

  // Priority: remembered (IPC) > presets.local.json "active" > presets.json
  // "active" > "default" > first preset.
  function resolveActive() {
    let pick = ""
    let candidates = [savedName, localActive, fileActive, "default", presetNames.length > 0 ? presetNames[0] : ""]
    for (let c of candidates) {
      if (c && (c in presets)) { pick = c; break }
    }
    if (savedName && pick !== savedName) {
      console.warn("dashboard: remembered preset \"" + savedName + "\" not found; using \"" + pick + "\"")
    }
    activeName = pick
  }

  // === LAYOUT RESOLUTION ===
  // Resolve a preset into absolute cells for one orientation. Portrait uses
  // the preset's explicit `portrait` block when present; otherwise the
  // landscape widget list is re-packed in order into `portraitColumns`
  // (spans clamped, col/row ignored) — the automatic reflow.
  function layoutFor(preset, vertical) {
    if (!preset) return { columns: 1, rows: 0, widgets: [] }
    if (vertical) {
      if (preset.portrait) return pack(preset.portrait.widgets, preset.portrait.columns, true)
      return pack(preset.widgets, preset.portraitColumns, false)
    }
    return pack(preset.widgets, preset.columns, true)
  }

  // Skyline packer. Entries with explicit col+row reserve their cells first;
  // the rest flow in preset order into the lowest free spot (an explicit
  // `col` alone pins the column). Rows may be fractional.
  function pack(widgets, columns, keepPlacement) {
    let heights = []
    for (let c = 0; c < columns; c++) heights.push(0)
    let ceiling = (col, span) => {
      let h = 0
      for (let c = col; c < col + span; c++) h = Math.max(h, heights[c])
      return h
    }
    let reserve = (col, span, bottom) => {
      for (let c = col; c < col + span; c++) heights[c] = Math.max(heights[c], bottom)
    }

    let placed = []
    let flow = []
    for (let w of widgets) {
      let span = Math.min(w.colSpan, columns)
      if (keepPlacement && w.col !== undefined && w.row !== undefined) {
        let col = Math.min(w.col, columns - span)
        placed.push(Object.assign({}, w, { col: col, row: w.row, colSpan: span }))
        reserve(col, span, w.row + w.rowSpan)
      } else {
        flow.push(Object.assign({}, w, { colSpan: span }))
      }
    }
    for (let w of flow) {
      let lo = 0
      let hi = columns - w.colSpan
      if (keepPlacement && w.col !== undefined) lo = hi = Math.min(w.col, hi)
      let best = lo
      let bestH = Infinity
      for (let c = lo; c <= hi; c++) {
        let h = ceiling(c, w.colSpan)
        if (h < bestH) { bestH = h; best = c }
      }
      placed.push(Object.assign({}, w, { col: best, row: bestH }))
      reserve(best, w.colSpan, bestH + w.rowSpan)
    }

    let rows = 0
    for (let h of heights) rows = Math.max(rows, h)
    return { columns: columns, rows: rows, widgets: placed }
  }
}
