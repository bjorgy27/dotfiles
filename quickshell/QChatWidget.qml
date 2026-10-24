import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import "QMd.js" as Md
import "QHl.js" as Hl

// Q chat panel (SUPER+A): type or talk to Q from the bar, voice and text in one log. Lives in the right-edge
// drawer in shell.qml (qDrawer), which sizes it and slides it in while bar.state is "q_chat".
// Backend: scripts/q_voice.py (the same engine as SUPER+T); typed turns run `q_voice.py turn --text`.
// Every client process appends its events to $XDG_RUNTIME_DIR/q-voice/events.jsonl and shell.qml tails
// that into root.qEvent, so turns show up here live (your words while you talk, then the reply) whether
// they came from SUPER+T, the mic button or the text box. Voice goes through q_voice.sh (same engine and
// pid as SUPER+T); typed turns run the client directly. History: ~/.local/state/q-voice/chat.jsonl.
Item {
  id: chat

  readonly property bool isOpen: bar.state === "q_chat"

  // the drawer's palette, from the portrait: deep space, the robe's crimson and gold
  readonly property real radius: metrics.s(22)
  readonly property color gold: "#d4af61"
  readonly property color goldDim: "#8a7442"
  readonly property color crimson: "#8e1f33"
  readonly property color crimsonHi: "#b8304a"
  readonly property color violet: "#c58cff"
  readonly property color ink: "#e9e4f5"
  readonly property color inkDim: "#a49cbc"
  readonly property color inkMute: "#6d6589"
  readonly property color glass: Qt.rgba(0.08, 0.06, 0.16, 0.78)
  // Markdown in Q's replies (QMd.js -> QMdView blocks, code highlighted by QHl.js), in the Q Galaxy inks
  readonly property var mdColors: ({ text: "" + ink, strong: "#ffffff", muted: "" + inkMute, code: "" + gold,
                                     codeBg: "#1d1733", link: "#9db8ff",
                                     border: "" + Qt.rgba(0.6, 0.45, 0.9, 0.35), th: "#1d1733", quote: "#c9a7ff" })

  readonly property string python: root.home + "/.local/share/q-voice/venv/bin/python"
  readonly property string client: root.home + "/.config/scripts/q_voice.py"
  readonly property string historyPath: (Quickshell.env("XDG_STATE_HOME") || (root.home + "/.local/state")) + "/q-voice/chat.jsonl"
  readonly property string voiceSh: root.home + "/.config/scripts/q_voice.sh"

  // whose machine this is (profile name), from the local ~/.config/q-voice/speakers.json: their turns get no name tag
  property string owner: ""
  FileView {
    path: (Quickshell.env("Q_SPEAKERS") || (root.home + "/.config/q-voice/speakers.json"))
    printErrors: false
    onLoaded: { try { chat.owner = (JSON.parse(text()).owner || "").toLowerCase() } catch (e) {} }
  }

  property string status: ""            // listening / thinking / speaking ...
  property string lastTyped: ""
  property int wordPtr: -1              // token index of the word being read aloud in the latest reply

  // ---- background agents (bridge -> q-inbox.service -> $XDG_RUNTIME_DIR/q-voice/agents.json)
  property var agents: []
  property string openAgent: ""         // id of the agent whose task/result is expanded
  property string openRuns: ""          // id of the agent whose earlier runs are listed
  property real now: Date.now()
  // One row per agent session, showing its latest run. A finished agent that gets a follow-up comes back as
  // "queued" (follow-up accepted, not started) then "running" with run > 1; earlier runs sit in a.runs.
  function agentActive(a) { return a.status === "running" || a.status === "queued" }
  // cancel: the X arms on the first click and cancels on the second (within 3 s), so a stray click can't kill one
  property string armedCancel: ""
  property var cancelling: ({})
  Timer { id: disarm; interval: 3000; onTriggered: chat.armedCancel = "" }
  function cancelAgent(a) {
    if (armedCancel !== a.id) { armedCancel = a.id; disarm.restart(); return }
    armedCancel = ""
    let c = Object.assign({}, cancelling); c[a.id] = true; cancelling = c
    Quickshell.execDetached([root.home + "/.local/bin/openclaw", "tasks", "cancel", a.taskId || a.id])
  }
  // the latest thing a running agent said about its progress: the last sentence of its running summary
  function agentLatest(a) {
    let r = (a.result || "").trim()
    if (!r) return ""
    let m = r.match(/[^.!?]+[.!?]*$/)
    return m ? m[0].trim() : r
  }
  // finished agents drop off 30 min after they end; running/queued ones always show
  readonly property var shownAgents: agents.filter(a => agentActive(a) || !a.endedAt || now - a.endedAt < 30 * 60 * 1000)
  readonly property int agentsRunning: shownAgents.filter(a => a.status === "running").length
  readonly property int agentsQueued: shownAgents.filter(a => a.status === "queued").length
  readonly property int agentsFailed: shownAgents.filter(a => !agentActive(a) && a.status !== "done").length
  FileView {
    id: agentsFile
    path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/q-voice/agents.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { chat.agents = JSON.parse(text()).agents || [] } catch (e) {} }
  }
  Timer { interval: 1000; repeat: true; running: chat.isOpen && chat.agentsRunning + chat.agentsQueued > 0; onTriggered: chat.now = Date.now() }
  Timer { interval: 60000; repeat: true; running: chat.isOpen; triggeredOnStart: true; onTriggered: chat.now = Date.now() }
  function fmtDur(ms) {
    let s = Math.max(0, Math.round(ms / 1000))
    if (s < 60) return s + "s"
    let m = Math.floor(s / 60)
    if (m < 60) return m + "m " + (s % 60) + "s"
    return Math.floor(m / 60) + "h " + (m % 60) + "m"
  }
  function agentWhen(a) {
    if (a.status === "queued") return "queued " + fmtDur(now - (a.startedAt || now))
    if (a.status === "running") return "running " + fmtDur(now - (a.startedAt || now))
    let took = (a.endedAt && a.startedAt) ? "took " + fmtDur(a.endedAt - a.startedAt) : ""
    let ago = a.endedAt ? fmtDur(Date.now() - a.endedAt) + " ago" : ""
    return [took, ago].filter(x => x).join(" · ")
  }
  // a little icon per agent, picked from its label (then its task): Symbols Nerd Font, Material Design set
  readonly property var agentIcons: [
    [/lion|avatar|portrait|svg|icon|draw|art\b|paint|sprite|image/, 0xf03d8],            // palette
    [/\bgit\b|commit|push|branch|merge|rebase/, 0xf02a2],                               // git
    [/review|audit|verify/, 0xf08a8],                                                   // clipboard check
    [/\btest|benchmark|spike|prototype/, 0xf0096],                                      // flask
    [/\bbug|\bfix|debug|crash|broke/, 0xf0a30],                                         // bug
    [/satellite|goes|orbit|perigee|starlink|cubesat|sentinel/, 0xf0471],                // satellite
    [/dish|antenna|\bsdr|radio|\brf\b|hrit|satdump/, 0xf1119],                          // antenna
    [/voice|audio|tts|speak|speech|\bmic\b|sound/, 0xf147d],                            // waveform
    [/rocket|launch|space ?job/, 0xf14df],                                              // rocket
    [/homework|aero ?\d|controls|latex|math|equation|derive/, 0xf0871],                 // function
    [/\bcad\b|freecad|mount|gimbal|\bprint|\b3d\b|mesh|\bfea\b/, 0xf01a7],              // cube
    [/research|search|look up|\bfind|\bweb\b|compare/, 0xf0349],                        // magnify
    [/resume|cover letter|write|draft|\bdoc|essay|letter|notes/, 0xf0cb6],              // pencil
    [/\bmail|inbox/, 0xf01f0],                                                          // envelope
    [/calendar|schedule|remind/, 0xf0e18],                                              // calendar
    [/music|song|playlist/, 0xf0387],                                                   // note
    [/chart|plot|graph|\bdata\b|stats/, 0xf012a],                                       // chart
    [/build|compile|cargo|rust|install|package/, 0xf1323],                              // hammer & wrench
    [/panel|quickshell|\bui\b|layout|theme|\bbar\b|widget|hyprland/, 0xf0a07],          // monitor
    [/config|setup|service|systemd|gateway|automation/, 0xf08bb],                       // cog
    [/clean|tidy|prune|trash/, 0xf00e2],                                                // broom
    [/security|harden|firewall/, 0xf0cc8],                                              // shield
  ]
  function agentIcon(a) {
    for (let s of [a.label || "", a.task || ""]) {
      let t = s.toLowerCase()
      for (let [re, cp] of agentIcons) if (re.test(t)) return String.fromCodePoint(cp)
    }
    return String.fromCodePoint(0xf06a9)                                                // robot
  }
  function agentTint(a) {
    return a.status === "running" ? chat.violet : a.status === "queued" ? chat.gold
         : a.status === "done" ? "#8fd19e" : "#ff7a8e"
  }
  readonly property bool voiceBusy: root.voiceState !== "idle"      // SUPER+T / mic engine running a turn
  // typed turns run detached (a shell reload must not kill them); typedPending tracks ours until the client exits
  property bool typedPending: false
  readonly property bool busy: typedPending || voiceBusy
  readonly property string mode: typedPending ? "text" : voiceBusy ? "voice" : ""
  readonly property string typedPid: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/q-voice/typed.pid"

  readonly property color statusColor: {
    switch (status) {
    case "listening":    return "#7fdcc9";
    case "transcribing": return "#b9b4f5";
    case "thinking":     return violet;
    case "speaking":     return "#8fb4ff";
    case "error":        return "#ff7a8e";
    default:             return typedPending ? violet : goldDim;
    }
  }

  ListModel { id: messages }   // role: user | q | error; text; speaker; pending

  onIsOpenChanged: {
    if (isOpen) {
      if (!busy) loadHistory()
      input.forceActiveFocus()
    }
  }

  // ---- history (chat.jsonl, newest last)
  FileView {
    id: historyFile
    path: chat.historyPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: if (!chat.busy) chat.loadHistory()
  }

  function loadHistory() {
    let lines = (historyFile.text() || "").split("\n").filter(l => l.trim() !== "").slice(-80)
    messages.clear()
    for (let l of lines) {
      try {
        let e = JSON.parse(l)
        messages.append({ role: e.role, text: e.text, speaker: e.speaker || "", pending: false, hl: -1,
                          spoken: (typeof e.spoken === "number") ? e.spoken : -1, imgs: (e.images || []).join("\n") })
      } catch (err) {}
    }
    scrollDown(true)
  }

  // follow new messages only while the log is at the bottom; reading back up isn't interrupted
  property bool follow: true
  readonly property real gutter: metrics.s(12)            // room on the right for the scrollbar
  function scrollDown(force) {
    if (force) follow = true
    if (follow) Qt.callLater(() => log.positionViewAtEnd())
  }

  function liveUser() {
    for (let i = messages.count - 1; i >= 0 && i >= messages.count - 3; i--)
      if (messages.get(i).role === "user" && messages.get(i).pending) return i
    return -1
  }
  function dropLiveUser() { let i = liveUser(); if (i >= 0) messages.remove(i) }

  function lastQ() {
    let n = messages.count
    return n > 0 && messages.get(n - 1).role === "q" && messages.get(n - 1).pending ? n - 1 : -1
  }

  // ---- LaTeX in Q's replies ($...$ or \(...\) inline, $$...$$ or \[...\] on its own line): typeset by
  //      scripts/q_eq.py into transparent PNGs in ink colour, cached by a hash of the source, shown as inline images.
  //      Until a picture is ready (or if it can't be typeset) the source shows as text. q_voice.py never speaks it.
  readonly property string eqDir: (Quickshell.env("XDG_CACHE_HOME") || (root.home + "/.cache")) + "/q-voice/eq"
  readonly property int eqDpi: Math.round(metrics.s(15) * 6.4 * 2)   // 12pt = the body's 15px, drawn at 2x for sharpness
  property var eqSizes: ({})        // key -> [w, h] in logical px, or false when it failed
  property var eqWant: []           // queued {key, tex, display}; plain JS list, changing it notifies nothing
  function eqParts(s) {             // [{text}, {text, tex, display}, ...]; a lone $ (prices) stays text
    let out = [], last = 0, m
    let rx = /\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\\\(([\s\S]+?)\\\)|(^|[^\\$\w])\$(?=\S)([^$\n]*?[^\s\\])\$(?![\w$])/g
    while ((m = rx.exec(s)) !== null) {
      let at = m.index + (m[4] || "").length
      if (at > last) out.push({ text: s.slice(last, at) })
      out.push({ text: s.slice(at, rx.lastIndex), tex: (m[1] || m[2] || m[3] || m[5]).trim(), display: !!(m[1] || m[2]) })
      last = rx.lastIndex
    }
    if (last < s.length) out.push({ text: s.slice(last) })
    return out
  }
  function eqHtml(p, maxW) {        // the <img> for a math part, or "" while it's not ready
    let key = Qt.md5((p.display ? "D|" : "I|") + chat.ink + "|" + chat.eqDpi + "|" + p.tex)
    let sz = chat.eqSizes[key]
    if (sz === undefined) {
      if (!chat.eqWant.some(q => q.key === key)) chat.eqWant.push({ key: key, tex: p.tex, display: p.display })
      Qt.callLater(chat.eqNext)
    }
    if (!sz) return ""
    let k = Math.min(1, maxW / sz[0])
    return "<img src=\"file://" + chat.eqDir + "/" + key + ".png\" width=\"" + Math.round(sz[0] * k)
           + "\" height=\"" + Math.round(sz[1] * k) + "\" style=\"vertical-align: middle\">"
  }
  function eqNext() {
    if (eqProc.running || chat.eqWant.length === 0) return
    let q = chat.eqWant[0]
    eqProc.job = q
    eqProc.command = ["python3", root.home + "/.config/scripts/q_eq.py", chat.eqDir + "/" + q.key + ".png",
                      chat.ink.toString(), q.display ? "1" : "0", String(chat.eqDpi), q.tex]
    eqProc.running = true
  }
  Process {
    id: eqProc
    property var job: null
    stdout: StdioCollector {
      onStreamFinished: {
        let wh = text.trim().split(/\s+/).map(Number), s = Object.assign({}, chat.eqSizes)
        s[eqProc.job.key] = wh.length === 2 && wh[0] > 0 ? [wh[0] / 2, wh[1] / 2] : false
        chat.eqSizes = s
        chat.eqWant = chat.eqWant.filter(q => q.key !== eqProc.job.key)
        Qt.callLater(chat.eqNext)
      }
    }
    onExited: Qt.callLater(chat.eqNext)
  }

  // ---- one turn = one client process
  // ---- attachments: Ctrl+V images from the clipboard (wl-paste), dropped files, or the paperclip picker,
  //      sent with the next message
  property var attachments: []
  property string preview: ""            // image path shown enlarged over the panel (click a picture)
  function isImage(p) { return /\.(png|jpe?g|webp|gif|bmp)$/i.test(p) }
  function attach(path) { if (path && attachments.length < 8) attachments = attachments.concat([path]) }
  function unattach(i) { let a = attachments.slice(); a.splice(i, 1); attachments = a }
  Process {
    id: pasteProc
    property bool gotImage: false
    command: ["bash", "-c", "d=\"$HOME/.local/state/q-voice/images\"; mkdir -p \"$d\"; " +
              "t=$(wl-paste -l 2>/dev/null | grep -m1 '^image/'); [ -n \"$t\" ] || exit 0; " +
              "f=\"$d/paste-$(date +%s%3N).${t#image/}\"; wl-paste -t \"$t\" > \"$f\" && echo \"$f\""]
    stdout: SplitParser { onRead: data => { if (data.trim()) { pasteProc.gotImage = true; chat.attach(data.trim()) } } }
    onExited: (code, st) => { if (!gotImage) input.paste() }   // no image on the clipboard: normal text paste
  }
  function pasteImage() { pasteProc.gotImage = false; pasteProc.running = true }
  DropArea {
    anchors.fill: parent
    keys: ["text/uri-list"]
    onDropped: drop => {
      for (let u of drop.urls) {
        let p = decodeURIComponent(u.toString().replace(/^file:\/\//, ""))
        chat.attach(p)
      }
    }
  }

  function send() {
    let t = input.text.trim()
    if ((t === "" && attachments.length === 0) || busy) return
    lastTyped = t
    input.text = ""
    follow = true
    // q_voice.py doesn't upload attachments, and Q runs on this machine: hand over the paths and Q reads them
    if (attachments.length) t = (t ? t + "\n\n" : "") + "[attached: " + attachments.join(", ") + "]"
    let cmd = [python, client, "turn", "--json", "--text", t]   // typed turns stay quiet; the reply shows here
    for (let a of attachments) if (chat.isImage(a)) cmd.push("--image", a)
    attachments = []
    typedPending = true
    Quickshell.execDetached(cmd)
  }

  // pencil on one of your messages: interrupt whatever is running and load that message into the box
  function editMessage(t) {
    if (busy) { input.text = ""; stop() }
    input.text = t
    input.cursorPosition = t.length
    input.forceActiveFocus()
  }

  // same as SUPER+T: starts listening, or while a voice turn runs: send now / interrupt and listen again
  function micPressed() { if (!typedPending) Quickshell.execDetached([voiceSh, "toggle"]) }

  // interrupt and edit (like Claude Code): stopping a typed turn puts what you sent back in the box to fix and resend
  function stop() {
    if (typedPending && input.text === "") { input.text = lastTyped; input.cursorPosition = input.text.length }
    if (typedPending) Quickshell.execDetached(["bash", "-c", "kill -TERM $(cat '" + typedPid + "') 2>/dev/null"])
    if (voiceBusy) Quickshell.execDetached([voiceSh, "cancel"])
  }

  Connections {
    target: root
    function onQEvent(ev) { chat.onEvent(ev) }
    function onVoiceStateChanged() {
      if (root.voiceState === "idle") { chat.typedPending = false; chat.settle() }
    }
  }

  function settle() {
    status = ""
    dropLiveUser()
    for (let i = 0; i < messages.count; i++) if (messages.get(i).pending) messages.setProperty(i, "pending", false)
    historyFile.reload()
  }

  function onEvent(ev) {
    switch (ev.type) {
    case "state":
      status = ev.state === "idle" ? "" : ev.state
      if (ev.state === "listening") dropLiveUser()      // new listen round: nothing heard yet
      break
    case "speech_start":                 // live bubble for what you're saying, filled in by partials
      status = "listening"
      if (liveUser() < 0) messages.append({ role: "user", text: "…", speaker: "", pending: true, hl: -1, spoken: -1, imgs: "" })
      break
    case "partial": {
      let i = liveUser()
      if (i < 0) messages.append({ role: "user", text: ev.text, speaker: "", pending: true, hl: -1, spoken: -1, imgs: "" })
      else messages.setProperty(i, "text", ev.text)
      break
    }
    case "transcript": {
      let i = ev.via === "voice" ? liveUser() : -1
      if (i >= 0) {
        messages.setProperty(i, "text", ev.text)
        messages.setProperty(i, "speaker", ev.speaker || "")
        messages.setProperty(i, "pending", false)
      } else {
        messages.append({ role: "user", text: ev.text, speaker: ev.speaker || "", pending: false, hl: -1, spoken: -1,
                          imgs: (ev.images || []).join("\n") })
      }
      break
    }
    case "word": {                       // the word being spoken right now (-1 = done reading)
      let m = -1
      for (let k = messages.count - 1; k >= 0 && k >= messages.count - 4; k--)
        if (messages.get(k).role === "q") { m = k; break }
      if (m < 0) break
      if (ev.i < 0) { messages.setProperty(m, "hl", -1); wordPtr = -1; break }
      let norm = w => (w || "").toLowerCase().replace(/[^a-z0-9']/g, "")
      let toks = chat.eqParts(chat.stripTags(messages.get(m).text)).filter(p => p.tex === undefined)   // equations aren't spoken
                   .map(p => p.text).join(" ").split(/\s+/).filter(t => t !== "")
      let want = norm(ev.w), hit = -1
      for (let k = wordPtr + 1; k < toks.length && k <= wordPtr + 8; k++)
        if (norm(toks[k]) === want) { hit = k; break }
      if (hit < 0) hit = Math.min(wordPtr + 1, toks.length - 1)   // no exact match (numbers, contractions): step on
      wordPtr = hit
      messages.setProperty(m, "hl", hit)
      break
    }
    case "delta": {
      let i = lastQ()
      if (i < 0) { messages.append({ role: "q", text: ev.text, speaker: "", pending: true, hl: -1, spoken: -1, imgs: "" }); wordPtr = -1 }
      else messages.setProperty(i, "text", messages.get(i).text + ev.text)
      break
    }
    case "done": {
      let i = lastQ()
      if (i >= 0 && !ev.reply && /^NO_REPLY\.?$/.test(messages.get(i).text.trim())) {
        messages.remove(i)                 // gateway's silent-turn token streamed in: nothing to show
        break
      }
      if (i >= 0) {
        if (ev.reply) messages.setProperty(i, "text", ev.reply)
        messages.setProperty(i, "pending", false)
        messages.setProperty(i, "spoken", (typeof ev.spoken === "number") ? ev.spoken : -1)
      } else if (ev.reply) {
        messages.append({ role: "q", text: ev.reply, speaker: "", pending: false, hl: -1, spoken: -1, imgs: "" })
      }
      break
    }
    case "report":                       // a background agent finished (q-inbox.service)
      messages.append({ role: "q", text: ev.text, speaker: "", pending: false, hl: -1,
                        spoken: (typeof ev.spoken === "number") ? ev.spoken : -1, imgs: "" })
      break
    case "error":
      dropLiveUser()
      messages.append({ role: "error", text: ev.message || "error", speaker: "", pending: false, hl: -1, spoken: -1, imgs: "" })
      break
    case "exit":
      typedPending = false
      if (!voiceBusy) dropLiveUser()
      break
    }
    scrollDown()
  }

  // ---- layout: a deep-space drawer. Portrait, name and status up top against a nebula, the conversation under
  //      that, then the agents tray, pending attachments and the input at the bottom.
  readonly property real pad: metrics.s(20)

  // ElevenLabs audio tags ([chuckles], [low, sultry] ...) are for the voice only, never shown; while a reply streams,
  // a half-arrived tag at the end is hidden too. Same pattern as _TAG in q_voice.py.
  function stripTags(s) {
    return (s || "").replace(/\[[a-z][a-z' ,-]{1,40}\]/g, "").replace(/\[[a-z][a-z' ,-]{0,40}$/, "").replace(/ {2,}/g, " ").replace(/^ +/gm, "")
  }

  // body: gradient, nebula glow behind the portrait (painted once per size), gold hairline
  Rectangle {
    anchors.fill: parent
    radius: chat.radius
    gradient: Gradient {
      GradientStop { position: 0.0; color: "#150b33" }
      GradientStop { position: 0.35; color: "#0d0822" }
      GradientStop { position: 1.0; color: "#08061a" }
    }
  }
  Canvas {
    id: sky
    anchors.fill: parent
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
      let ctx = getContext("2d")
      ctx.reset()
      if (width < 50 || height < 50) return
      ctx.beginPath(); ctx.roundedRect(0, 0, width, height, chat.radius, chat.radius); ctx.clip()
      let k = width / 600, cx = avatar.x + avatar.width / 2 + 60 * k, cy = avatar.y + avatar.height / 2
      function glow(x, y, r, c) {
        let g = ctx.createRadialGradient(x, y, 0, x, y, r)
        g.addColorStop(0, c); g.addColorStop(1, "rgba(0,0,0,0)")
        ctx.fillStyle = g; ctx.fillRect(0, 0, width, height)
      }
      glow(cx, cy + 20 * k, 330 * k, "rgba(120,50,220,0.42)")
      glow(cx + 120 * k, cy - 50 * k, 220 * k, "rgba(220,60,170,0.22)")
      glow(cx - 150 * k, cy + 130 * k, 200 * k, "rgba(60,70,230,0.20)")
      glow(cx + 200 * k, height - 120 * k, 300 * k, "rgba(90,30,160,0.18)")
    }
  }
  Rectangle {
    anchors.fill: parent
    radius: chat.radius
    color: "transparent"
    border.width: 1
    border.color: chat.goldDim
  }

  // header: big portrait with the galaxy ring on the left, the name and status line beside it
  // root.showLion false (local.js): no portrait, a zero-width avatar keeps the header compact and its timers stopped
  LionAvatar {
    id: avatar
    visible: root.showLion
    width: root.showLion ? Math.round(Math.min(metrics.s(290), chat.height * 0.23)) : 0
    height: root.showLion ? width : metrics.s(110)
    x: chat.pad
    y: metrics.s(24)
    restColor: chat.gold
    restOpacity: 0.8
    // the idle yawn: every 20 s while the panel is open and no typed turn is in flight, for as long as no message
    // comes (Beck, 2026-10-06); only a message, sent or received, starts the wait over
    idleYawn: chat.isOpen && !chat.busy
    idleYawnSecs: 20
    Connections {
      target: messages
      function onRowsInserted() { avatar.poke() }
      function onDataChanged() { avatar.poke() }
    }
    // click: show / hide the corner lion (shell.qml) on this screen; it outlives the panel
    HoverHandler { cursorShape: Qt.PointingHandCursor }
    TapHandler {
      onTapped: {
        let here = barWindow.modelData.name
        if (root.qCorner && root.qCornerScreen === here) root.qCorner = false
        else { root.qCornerScreen = here; root.qCorner = true }
      }
    }
  }
  Text {
    id: title
    x: avatar.x + avatar.width + metrics.spacingLarge
    y: avatar.y + (avatar.height - height - statusRow.height) / 2
    text: "Q"
    color: chat.gold
    font.family: "Noto Sans"
    font.weight: Font.DemiBold
    font.pixelSize: metrics.s(36)
    font.letterSpacing: metrics.s(4)
  }
  Row {
    id: statusRow
    x: title.x
    y: title.y + title.height
    spacing: metrics.s(8)
    Rectangle {
      id: dot
      anchors.verticalCenter: parent.verticalCenter
      width: metrics.s(7); height: width; radius: width / 2
      color: chat.statusColor
      SequentialAnimation on opacity {
        running: chat.status === "listening" || chat.status === "speaking"
        loops: Animation.Infinite
        NumberAnimation { to: 0.35; duration: 600 }
        NumberAnimation { to: 1.0; duration: 600 }
        onRunningChanged: if (!running) dot.opacity = 1
      }
    }
    Text {
      text: chat.status === "transcribing" ? "decoding" : chat.status || (chat.typedPending ? "thinking" : "idle")
      color: chat.inkDim
      font.family: "monospace"
      font.pixelSize: metrics.s(12)
      font.letterSpacing: metrics.s(3)
      font.capitalization: Font.AllUppercase
    }
    // voice switch: off = replies arrive as text only, nothing is synthesized or played (q_voice.py voice_on)
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: voiceLbl.implicitWidth + metrics.s(14); height: voiceLbl.implicitHeight + metrics.s(4)
      radius: height / 2
      color: voiceHover.containsMouse ? Qt.rgba(0.83, 0.69, 0.38, 0.14) : "transparent"
      border.width: 1; border.color: chat.voiceOn ? chat.gold : chat.goldDim
      Text {
        id: voiceLbl
        anchors.centerIn: parent
        text: chat.voiceOn ? "󰕾 VOICE" : "󰖁 TEXT"
        color: chat.voiceOn ? chat.gold : chat.inkMute
        font.family: "monospace"; font.pixelSize: metrics.s(11); font.letterSpacing: metrics.s(1)
      }
      MouseArea { id: voiceHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
        onClicked: chat.setVoice(!chat.voiceOn) }
    }
  }
  property bool voiceOn: true
  readonly property string voiceFile: root.home + "/.config/q-voice/voice"
  function setVoice(on) {
    voiceOn = on
    voiceWrite.command = ["bash", "-c", "mkdir -p \"$(dirname \"$1\")\" && echo \"$2\" > \"$1\"", "_", voiceFile, on ? "on" : "off"]
    voiceWrite.running = true
  }
  Process { id: voiceWrite }
  Process {
    running: true
    command: ["cat", chat.voiceFile]
    stdout: StdioCollector { onStreamFinished: chat.voiceOn = text.trim().toLowerCase() !== "off" }
  }
  // background agents: a little round icon each in the header's top right, beside the name. Hover one for what
  // it is, click it for its card under the header; a working agent gets the comet ring like the portrait.
  readonly property real agentTile: metrics.s(56)
  property var hoverAgent: null
  Item {
    id: agentDock
    visible: chat.shownAgents.length > 0
    x: Math.max(title.x + title.width, statusRow.x + statusRow.width) + metrics.spacingLarge
    y: avatar.y + metrics.s(6)
    width: parent.width - chat.pad - x
    height: avatar.height - metrics.s(6)

    Text {
      id: dockHead
      anchors.right: parent.right
      width: Math.min(implicitWidth, parent.width)
      elide: Text.ElideLeft
      text: chat.hoverAgent ? chat.hoverAgent.label + " · " + chat.agentWhen(chat.hoverAgent)
          : "AGENTS  " + [chat.agentsRunning ? chat.agentsRunning + " running" : "",
                          chat.agentsQueued ? chat.agentsQueued + " queued" : "",
                          (chat.shownAgents.length - chat.agentsRunning - chat.agentsQueued - chat.agentsFailed) ? (chat.shownAgents.length - chat.agentsRunning - chat.agentsQueued - chat.agentsFailed) + " done" : "",
                          chat.agentsFailed ? chat.agentsFailed + " failed" : ""].filter(x => x).join(" · ")
      color: chat.hoverAgent ? chat.inkDim : chat.goldDim
      font.family: "monospace"; font.pixelSize: metrics.fontTiny; font.letterSpacing: chat.hoverAgent ? 0 : metrics.s(1)
    }

    Flickable {
      y: dockHead.height + metrics.s(10)
      width: parent.width
      height: parent.height - y
      contentHeight: dockFlow.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      Flow {
        id: dockFlow
        width: parent.width
        layoutDirection: Qt.RightToLeft
        spacing: metrics.s(6)
        Repeater {
          model: chat.shownAgents
          Item {
            id: tileItem
            required property var modelData
            readonly property bool open: chat.openAgent === modelData.id
            readonly property bool live: modelData.status === "running"
            readonly property color tint: chat.agentTint(modelData)
            width: chat.agentTile + metrics.s(14)
            height: chat.agentTile + tileCap.height + metrics.s(6)

            Rectangle {
              id: face
              anchors.horizontalCenter: parent.horizontalCenter
              width: chat.agentTile; height: width; radius: width / 2
              color: tileItem.open ? Qt.rgba(0.17, 0.10, 0.32, 0.95)
                   : tileHover.hovered ? Qt.rgba(0.14, 0.09, 0.27, 0.92) : Qt.rgba(0.10, 0.07, 0.20, 0.85)
              border.width: tileItem.open ? 2 : 1
              border.color: tileItem.open ? chat.gold : Qt.rgba(tileItem.tint.r, tileItem.tint.g, tileItem.tint.b, tileItem.live ? 0.25 : 0.55)
              scale: tileHover.hovered ? 1.06 : 1
              Behavior on scale { NumberAnimation { duration: 120 } }
              Behavior on color { ColorAnimation { duration: 150 } }
              Text {
                anchors.centerIn: parent
                text: chat.agentIcon(tileItem.modelData)
                color: tileItem.live || tileItem.open ? chat.gold : chat.goldDim
                font.family: "Symbols Nerd Font"
                font.pixelSize: Math.round(chat.agentTile * 0.46)
              }
              // working: a small violet-to-pink comet round the rim (painted once, spun on the render thread)
              Canvas {
                id: tileSweep
                anchors.fill: parent
                anchors.margins: -metrics.s(2)
                visible: tileItem.live
                onWidthChanged: requestPaint()
                onPaint: {
                  let ctx = getContext("2d")
                  ctx.reset()
                  if (width < 8) return
                  let lw = metrics.s(2.5), r = width / 2 - lw, c = width / 2, n = 48, span = Math.PI * 1.2
                  for (let i = 0; i < n; i++) {
                    let t = (i + 1) / n
                    ctx.strokeStyle = Qt.rgba(0.35 + 0.65 * t, 0.2 + 0.35 * t * t, 0.95 - 0.1 * t, 0.1 + 0.9 * Math.pow(t, 1.3))
                    ctx.lineWidth = lw
                    ctx.beginPath(); ctx.arc(c, c, r, -Math.PI / 2 + span * i / n, -Math.PI / 2 + span * (i + 1.4) / n, false); ctx.stroke()
                  }
                }
                RotationAnimator on rotation {
                  running: tileSweep.visible && chat.isOpen
                  from: 0; to: 360; duration: 1600; loops: Animation.Infinite
                }
              }
              Rectangle {                // status dot, bottom right
                x: parent.width * 0.78 - width / 2; y: parent.height * 0.78 - height / 2
                width: metrics.s(11); height: width; radius: width / 2
                color: tileItem.tint
                border.width: metrics.s(2); border.color: "#0d0822"
                SequentialAnimation on opacity {
                  running: tileItem.live && chat.isOpen
                  loops: Animation.Infinite
                  NumberAnimation { to: 0.4; duration: 700 }
                  NumberAnimation { to: 1.0; duration: 700 }
                }
              }
            }
            Text {
              id: tileCap
              anchors.top: face.bottom; anchors.topMargin: metrics.s(4)
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: (tileItem.modelData.label || "").split(/[:—-]/)[0].trim()
              color: tileItem.open ? chat.ink : chat.inkMute
              font.family: "monospace"; font.pixelSize: metrics.s(10)
            }
            HoverHandler {
              id: tileHover
              cursorShape: Qt.PointingHandCursor
              onHoveredChanged: {
                if (hovered) chat.hoverAgent = tileItem.modelData
                else if (chat.hoverAgent && chat.hoverAgent.id === tileItem.modelData.id) chat.hoverAgent = null
              }
            }
            TapHandler { onTapped: chat.openAgent = tileItem.open ? "" : tileItem.modelData.id }
          }
        }
      }
    }
  }

  Item {                                        // invisible spacer: where the header ends and the log begins
    id: divider
    y: avatar.y + avatar.height + metrics.s(14)
    width: parent.width; height: 1
  }

  // where the log ends: above the attachments, else the input; it starts under the open agent's card, if any
  readonly property real dockTop: attachRow.visible ? attachRow.y : inputBar.y
  readonly property real logBottom: dockTop - metrics.s(12)

  // conversation
  ListView {
    id: log
    x: metrics.s(22)
    y: tray.visible ? tray.y + tray.height + metrics.s(14) : divider.y + metrics.s(18)
    width: parent.width - metrics.s(44)
    height: chat.logBottom - y
    clip: true
    spacing: metrics.s(12)
    model: messages
    boundsBehavior: Flickable.StopAtBounds
    onMovementEnded: chat.follow = atYEnd
    onContentHeightChanged: if (chat.follow) Qt.callLater(positionViewAtEnd)   // bubbles size in after the jump; streaming replies grow
    onHeightChanged: if (chat.follow) Qt.callLater(positionViewAtEnd)          // the agents tray or attachments grew under it

    delegate: Item {
      id: row
      required property string role
      required property string text
      required property string speaker
      required property bool pending
      required property int hl
      required property int spoken      // chars of text that were read aloud; -1 = not a spoken turn (or all spoken)
      // Always RichText (escaped): switching textFormat back to PlainText after reading made the TextEdit show its own
      // generated HTML. The word being read aloud (hl) gets <i> in gold.
      // Spoken turns: whatever wasn't read aloud (after [quiet], a late answer, a long pause) is dimmed behind a
      // muted-speaker glyph, so it's clear what you heard vs what only landed here.
      readonly property int cut: (row.role === "q" && row.spoken >= 0 && row.spoken < row.text.length) ? row.spoken : -1
      // Equations (chat.eqParts) show as typeset pictures on their own line ($$, \[) or in the line ($, \(); they
      // aren't spoken, so they don't count as words for hl.
      function richText() {
        let out = "", n = -1, off = 0, dim = false, eatNl = false
        let esc = s => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        for (let eq of chat.eqParts(row.shown)) {
          if (eq.tex !== undefined) {
            if (row.cut >= 0 && !dim && off >= row.cut) { dim = true; out += "<span style=\"color:" + chat.inkMute + "\">󰖁 " }
            off += eq.text.length
            let img = chat.eqHtml(eq, body.width)
            if (!img) { out += esc(eq.text); continue }
            if (eq.display) {                // its own indented block, which takes the place of the line breaks around it
              out = out.replace(/<br>$/, "") + "<p style=\"margin: 0 0 0 " + metrics.s(18) + "px\">" + img + "</p>"
              eatNl = true
            } else out += img
            continue
          }
          for (let part of eq.text.split(/(\s+)/)) {
            if (part === "") continue
            if (eatNl) {                     // the block already ends the line after a display equation
              eatNl = false
              if (/^\s*\n/.test(part)) {
                let rest = part.replace(/^[^\n]*\n/, "")
                off += part.length - rest.length
                part = rest
                if (part === "") continue
              }
            }
            if (row.cut >= 0 && !dim && off >= row.cut && !/^\s+$/.test(part)) {
              dim = true
              out += "<span style=\"color:" + chat.inkMute + "\">" + "󰖁 "
            }
            off += part.length
            if (/^\s+$/.test(part)) { out += part.replace(/\n/g, "<br>"); continue }
            n++
            let e = esc(part)
            out += n === row.hl ? "<i><span style=\"color:" + chat.gold + "\">" + e + "</span></i>" : e
          }
        }
        if (dim) out += "</span>"
        return out + (row.pending ? " ▍" : "")
      }
      required property string imgs
      readonly property bool mine: role === "user"
      // Q's replies carry files as "MEDIA:<path>" lines: images show inline under the text, other files as
      // chips; the lines themselves are hidden (and never spoken, see q_voice.py _MD)
      readonly property var media: mine ? [] : (text.match(/^[ \t]*MEDIA:\S.*$/gm) || []).map(l => l.trim().slice(6).trim())
      readonly property string shown: mine ? text : chat.stripTags(text.replace(/^[ \t]*MEDIA:\S.*$\n?/gm, "")).replace(/\s+$/, "")
      readonly property var pics: (imgs ? imgs.split("\n") : []).concat(media.filter(p => chat.isImage(p)))
      // Q's replies render as markdown, except while a word is being read aloud (the gold hl needs the plain path)
      readonly property bool md: row.role === "q" && row.hl < 0
      readonly property int mdCut: (row.md && row.cut >= 0) ? Md.safeCut(row.shown, Math.min(row.cut, row.shown.length)) : -1
      readonly property string mdMain: row.md ? (row.mdCut >= 0 ? row.shown.slice(0, row.mdCut) : row.shown) : ""
      readonly property string mdDim: row.mdCut >= 0 ? row.shown.slice(row.mdCut) : ""
      readonly property var mainR: row.md ? Md.render(row.mdMain, { c: chat.mdColors, px: metrics.s(15), pending: row.pending && row.mdDim.trim() === "" })
                                          : ({ blocks: [], plain: "", wide: false })
      readonly property var dimR: row.mdDim.trim() !== "" ? Md.render(row.mdDim, { c: chat.mdColors, px: metrics.s(15), pending: row.pending })
                                                         : ({ blocks: [], plain: "", wide: false })
      readonly property var files: media.filter(p => !chat.isImage(p))
      readonly property real maxW: (log.width - chat.gutter) * (mine ? 0.8 : 0.86)
      width: log.width - chat.gutter
      height: (who.visible ? who.height : 0) + (picRow.visible ? picRow.height + metrics.s(6) : 0)
              + (bubble.visible ? bubble.height : 0) + (fileRow.visible ? fileRow.height + metrics.s(6) : 0)

      // your pictures sit above your text; Q's below its text. Click any picture to enlarge it.
      Flow {
        id: picRow
        visible: row.pics.length > 0
        y: row.mine ? (who.visible ? who.height : 0) : (bubble.visible ? bubble.y + bubble.height + metrics.s(6) : 0)
        anchors.right: row.mine ? parent.right : undefined
        width: row.maxW
        layoutDirection: row.mine ? Qt.RightToLeft : Qt.LeftToRight
        spacing: metrics.s(6)
        Repeater {
          model: row.pics
          ClippingRectangle {                      // rounded frame that clips the picture to its corners
            id: pic
            required property string modelData
            height: row.mine ? metrics.s(120) : metrics.s(180)
            width: Math.max(height * 0.5, Math.min(picImg.implicitWidth * (height - 2) / Math.max(1, picImg.implicitHeight) + 2, row.maxW))
            radius: metrics.s(12)
            color: "#120c2a"
            border.width: 1
            border.color: picHover.containsMouse ? chat.gold : chat.goldDim
            Image {
              id: picImg
              anchors.fill: parent
              source: "file://" + pic.modelData
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              sourceSize.height: pic.height * 2
            }
            Rectangle {                            // enlarge hint
              visible: !row.mine
              anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: metrics.s(8)
              width: metrics.s(26); height: width; radius: metrics.s(8)
              color: Qt.rgba(0, 0, 0, 0.55)
              Text { anchors.centerIn: parent; text: "󰁌"; color: chat.ink; font.pixelSize: metrics.s(14); font.family: "monospace" }
            }
            MouseArea { id: picHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: chat.preview = pic.modelData }
          }
        }
      }
      Flow {                       // non-image files from Q: chips that open in their default app
        id: fileRow
        visible: row.files.length > 0
        y: (picRow.visible ? picRow.y + picRow.height : bubble.y + bubble.height) + metrics.s(6)
        width: row.maxW
        spacing: metrics.s(6)
        Repeater {
          model: row.files
          Rectangle {
            required property string modelData
            width: fchip.implicitWidth + metrics.s(20); height: metrics.s(28)
            radius: metrics.s(10)
            color: fhover.containsMouse ? Qt.rgba(0.83, 0.69, 0.38, 0.14) : chat.glass
            border.width: 1; border.color: fhover.containsMouse ? chat.gold : chat.goldDim
            Text {
              id: fchip
              anchors.centerIn: parent
              text: (/\.pdf$/i.test(parent.modelData) ? "󰈦 " : "󰈔 ") + parent.modelData.replace(/^.*\//, "")
              color: chat.ink
              font.pixelSize: metrics.fontSmall; font.family: "monospace"
            }
            MouseArea { id: fhover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: Quickshell.execDetached(["xdg-open", parent.modelData]) }
          }
        }
      }

      Text {
        id: who
        visible: row.mine && row.speaker !== "" && row.speaker.toLowerCase() !== chat.owner
        anchors.right: parent.right
        text: row.speaker.charAt(0).toUpperCase() + row.speaker.slice(1)
        color: chat.inkMute
        font.pixelSize: metrics.fontTiny
        font.family: "monospace"
      }
      TextMetrics { id: tm; font: body.font; text: row.shown + (row.pending ? " ▍" : "") }
      HoverHandler { id: rowHover }
      Rectangle {                  // your messages: pencil on hover, sends the text back to the box for editing
        visible: row.mine && row.text !== "" && (rowHover.hovered || editHover.containsMouse)
        anchors.right: bubble.left; anchors.rightMargin: metrics.s(6)
        anchors.verticalCenter: bubble.verticalCenter
        width: metrics.s(24); height: width; radius: width / 2
        color: editHover.containsMouse ? Qt.rgba(0.83, 0.69, 0.38, 0.18) : "transparent"
        Text { anchors.centerIn: parent; text: "󰏫"; color: chat.gold; font.pixelSize: metrics.fontSmall; font.family: "monospace" }
        MouseArea { id: editHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: chat.editMessage(row.text) }
      }
      // Q: dark glass with a gold accent bar on the left; you: crimson; errors: red-tinted glass
      Rectangle {
        id: bubble
        visible: row.shown !== ""
        readonly property real padL: row.mine ? metrics.s(15) : metrics.s(18)
        readonly property real padR: row.mine ? metrics.s(15) : metrics.s(16)
        y: (who.visible ? who.height : 0) + (row.mine && picRow.visible ? picRow.height + metrics.s(6) : 0)
        anchors.right: row.mine ? parent.right : undefined
        anchors.left: row.mine ? undefined : parent.left
        width: (row.md && (row.mainR.wide || row.dimR.wide)) ? row.maxW : Math.min(tm.advanceWidth + padL + padR + metrics.s(2), row.maxW)
        height: (row.md ? mdCol.implicitHeight : body.implicitHeight) + metrics.s(22)
        radius: metrics.s(14)
        color: row.role === "error" ? Qt.rgba(0.55, 0.08, 0.16, 0.35) : row.mine ? "transparent" : chat.glass
        border.width: row.mine ? 0 : 1
        border.color: row.role === "error" ? "#ff7a8e" : Qt.rgba(0.6, 0.45, 0.9, 0.25)
        Rectangle {
          visible: row.mine
          anchors.fill: parent
          radius: parent.radius
          gradient: Gradient {
            GradientStop { position: 0; color: "#5a1830" }
            GradientStop { position: 1; color: "#3d1024" }
          }
          border.width: 1
          border.color: Qt.rgba(0.85, 0.3, 0.45, 0.35)
        }
        Rectangle {
          visible: !row.mine
          x: 0; y: metrics.s(10)
          width: metrics.s(3); height: parent.height - metrics.s(20)
          radius: width / 2
          color: row.role === "error" ? "#ff7a8e" : chat.gold
        }
        Column {
          id: mdCol
          visible: row.md
          x: bubble.padL
          y: metrics.s(11)
          width: parent.width - bubble.padL - bubble.padR
          spacing: metrics.s(4)
          QMdView {
            visible: row.mainR.blocks.length > 0 || (row.pending && row.mdDim.trim() === "")
            width: parent.width
            blocks: row.mainR.blocks
            pending: row.pending && row.mdDim.trim() === ""
            textColor: chat.ink
            fontPx: metrics.s(15)
          }
          QMdView {
            visible: row.dimR.blocks.length > 0
            width: parent.width
            blocks: row.dimR.blocks
            pending: row.pending
            lead: "󰖁 "
            textColor: chat.inkMute
            fontPx: metrics.s(15)
          }
        }
        TextEdit {
          id: body
          visible: !row.md
          x: bubble.padL
          y: metrics.s(11)
          width: parent.width - bubble.padL - bubble.padR
          text: row.md ? "" : row.richText()
          readOnly: true
          selectByMouse: true
          wrapMode: TextEdit.Wrap
          textFormat: TextEdit.RichText
          color: row.role === "error" ? "#ffb3c0" : row.mine ? "#f6e9ee" : chat.ink
          selectionColor: chat.crimsonHi
          selectedTextColor: "#ffffff"
          font.pixelSize: metrics.s(15)
          font.family: "monospace"
        }
      }
    }

    Text {
      anchors.centerIn: parent
      visible: messages.count === 0
      text: "Type below, or press 󰍬 (or SUPER+T) to talk."
      color: chat.inkMute
      font.pixelSize: metrics.fontNormal
      font.family: "monospace"
    }
  }

  // log scrollbar: drag the handle or click the track to jump; hidden when everything fits
  Item {
    id: scrollTrack
    visible: log.contentHeight > log.height + 1
    x: log.x + log.width - width
    y: log.y
    width: metrics.s(5)
    height: log.height
    Rectangle { anchors.fill: parent; radius: width / 2; color: Qt.rgba(1, 1, 1, 0.05) }
    Rectangle {
      id: handle
      width: parent.width
      radius: width / 2
      height: Math.max(metrics.s(28), log.visibleArea.heightRatio * scrollTrack.height)
      y: Math.min(scrollTrack.height - height, Math.max(0, log.visibleArea.yPosition * scrollTrack.height))
      color: dragArea.pressed || dragArea.containsMouse ? chat.gold : chat.goldDim
      opacity: 0.8
    }
    MouseArea {
      id: dragArea
      anchors.fill: parent
      anchors.leftMargin: -metrics.s(6)                     // easier to grab
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      property real grab: 0
      function scrollTo(my) {
        let span = scrollTrack.height - handle.height
        let f = span > 0 ? Math.min(1, Math.max(0, (my - grab) / span)) : 0
        log.contentY = log.originY + f * Math.max(0, log.contentHeight - log.height)
        chat.follow = f >= 0.999
      }
      onPressed: mouse => {
        let onHandle = mouse.y >= handle.y && mouse.y <= handle.y + handle.height
        grab = onHandle ? mouse.y - handle.y : handle.height / 2
        scrollTo(mouse.y)
      }
      onPositionChanged: mouse => { if (pressed) scrollTo(mouse.y) }
    }
  }

  // jump back to the latest message when scrolled up
  Rectangle {
    visible: scrollTrack.visible && !log.atYEnd
    width: metrics.s(32); height: width; radius: width / 2
    x: log.x + log.width - chat.gutter - width - metrics.spacingSmall
    y: log.y + log.height - height - metrics.spacingSmall
    color: Qt.rgba(0.08, 0.06, 0.16, 0.92)
    border.width: 1
    border.color: chat.goldDim
    Text { anchors.centerIn: parent; text: "󰁅"; color: chat.gold; font.pixelSize: metrics.fontNormal; font.family: "monospace" }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: chat.scrollDown(true) }
  }

  // the agent picked in the header: its card (task, live progress, result, cancel) sits under the header and
  // pushes the conversation down. Click its title line or its icon again to close it.
  readonly property var openAgentData: shownAgents.find(a => a.id === openAgent) || null
  Column {
    id: tray
    visible: chat.openAgentData !== null
    x: chat.pad
    width: parent.width - chat.pad * 2
    y: divider.y + metrics.s(6)
    spacing: metrics.s(8)

    Flickable {
      width: parent.width
      height: Math.min(agentList.implicitHeight, chat.height * 0.3)
      contentHeight: agentList.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      Column {
        id: agentList
        width: parent.width
        spacing: metrics.s(6)
        Repeater {
          model: chat.openAgentData ? [chat.openAgentData] : []
          Rectangle {
            id: arow
            required property var modelData
            readonly property bool open: true
            readonly property bool live: modelData.status === "running"
            readonly property color tint: modelData.status === "running" ? chat.violet
                                          : modelData.status === "queued" ? chat.gold
                                          : modelData.status === "done" ? "#8fd19e" : "#ff7a8e"
            readonly property int run: modelData.run || 1
            readonly property var earlier: modelData.runs || []
            width: agentList.width
            height: arowCol.implicitHeight + metrics.s(16)
            radius: metrics.s(10)
            color: arow.open ? Qt.rgba(0.13, 0.09, 0.25, 0.92) : Qt.rgba(0.10, 0.07, 0.20, 0.85)
            border.width: 1
            border.color: arow.live ? Qt.rgba(0.77, 0.55, 1, 0.45) : arow.open ? chat.goldDim : Qt.rgba(1, 1, 1, 0.07)
            Column {
              id: arowCol
              x: metrics.s(12); y: metrics.s(8)
              width: parent.width - metrics.s(24)
              spacing: metrics.s(5)
              Item {
                width: parent.width
                height: metrics.s(20)
                Text {
                  id: aicon
                  width: metrics.s(16)
                  anchors.verticalCenter: parent.verticalCenter
                  text: arow.modelData.status === "running" ? "󰑮" : arow.modelData.status === "queued" ? "󰔟"
                        : arow.modelData.status === "done" ? "󰄬" : "󰅖"
                  color: arow.tint
                  font.pixelSize: metrics.fontNormal
                  font.family: "monospace"
                  SequentialAnimation on opacity {
                    running: arow.modelData.status === "running" && chat.isOpen
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.35; duration: 700 }
                    NumberAnimation { to: 1.0; duration: 700 }
                  }
                }
                Text {
                  id: alabel
                  x: aicon.width + metrics.spacingSmall
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.min(implicitWidth, parent.width - x - awhen.width - (akill.visible ? akill.width + metrics.spacingSmall : 0) - abadges.width - metrics.spacingNormal * 2)
                  elide: Text.ElideRight
                  text: arow.modelData.label
                  color: chat.ink
                  font.pixelSize: metrics.s(13)
                  font.family: "monospace"
                }
                Row {                      // resumed agents: which run this is, and follow-ups waiting behind it
                  id: abadges
                  x: alabel.x + alabel.width + metrics.spacingSmall
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: metrics.s(4)
                  Repeater {
                    model: [arow.run > 1 ? "↻ run " + arow.run : "",
                            arow.modelData.pending ? "+" + arow.modelData.pending + " queued" : ""].filter(x => x)
                    Rectangle {
                      required property string modelData
                      width: abadge.implicitWidth + metrics.s(10)
                      height: abadge.implicitHeight + metrics.s(2)
                      radius: height / 2
                      color: "transparent"
                      border.width: 1
                      border.color: modelData.startsWith("+") ? chat.gold : arow.tint
                      Text {
                        id: abadge
                        anchors.centerIn: parent
                        text: parent.modelData
                        color: parent.border.color
                        font.pixelSize: metrics.fontTiny
                        font.family: "monospace"
                      }
                    }
                  }
                }
                MouseArea {                // title line toggles the details; the text below stays selectable
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: chat.openAgent = ""
                }
                Rectangle {               // cancel: click once to arm (turns red), again to cancel
                  id: akill
                  readonly property bool live: chat.agentActive(arow.modelData) && !chat.cancelling[arow.modelData.id]
                  readonly property bool armed: chat.armedCancel === arow.modelData.id
                  visible: live
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: armed ? akillText.implicitWidth + metrics.s(14) : metrics.s(22)
                  height: metrics.s(22)
                  radius: height / 2
                  color: armed ? chat.crimsonHi : killHover.containsMouse ? Qt.rgba(0.72, 0.19, 0.29, 0.75) : Qt.rgba(0.56, 0.12, 0.2, 0.5)
                  Text {
                    id: akillText
                    anchors.centerIn: parent
                    text: akill.armed ? "cancel?" : "󰅖"
                    color: akill.armed ? "#ffffff" : "#ff9fb2"
                    font.pixelSize: akill.armed ? metrics.fontTiny : metrics.fontSmall
                    font.family: "monospace"
                  }
                  MouseArea {
                    id: killHover
                    anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: chat.cancelAgent(arow.modelData)
                  }
                }
                Text {
                  id: awhen
                  anchors.right: akill.visible ? akill.left : parent.right
                  anchors.rightMargin: akill.visible ? metrics.spacingSmall : 0
                  anchors.verticalCenter: parent.verticalCenter
                  text: chat.cancelling[arow.modelData.id] && chat.agentActive(arow.modelData) ? "cancelling…"
                        : chat.agentWhen(arow.modelData)
                  color: chat.inkMute
                  font.pixelSize: metrics.fontTiny
                  font.family: "monospace"
                }
              }
              Column {                     // live progress: activity bar, then the latest note and step count
                visible: arow.live
                x: aicon.width + metrics.spacingSmall
                width: parent.width - x
                spacing: metrics.s(4)
                Rectangle {
                  id: abar
                  width: parent.width; height: metrics.s(4)
                  radius: height / 2
                  color: Qt.rgba(1, 1, 1, 0.07)
                  clip: true
                  // no agent reports a total, so this shows activity, not a percentage: a sweep while it
                  // works, dimmed when it hasn't done anything for a minute
                  readonly property bool fresh: chat.now - (arow.modelData.lastEventAt || chat.now) < 60000
                  Rectangle {
                    id: asweep
                    width: parent.width * 0.3; height: parent.height
                    radius: height / 2
                    opacity: abar.fresh ? 1 : 0.35
                    gradient: Gradient {
                      orientation: Gradient.Horizontal
                      GradientStop { position: 0.0; color: "transparent" }
                      GradientStop { position: 0.6; color: "#9b5cff" }
                      GradientStop { position: 1.0; color: "#ff7ad9" }
                    }
                    NumberAnimation on x {
                      running: arow.live && chat.isOpen
                      from: -asweep.width; to: abar.width
                      duration: 1600; loops: Animation.Infinite
                    }
                  }
                }
                Item {
                  width: parent.width
                  height: asteps.implicitHeight
                  Text {
                    visible: !arow.open
                    anchors.left: parent.left
                    anchors.right: asteps.left; anchors.rightMargin: metrics.spacingNormal
                    elide: Text.ElideRight
                    text: chat.agentLatest(arow.modelData)
                    color: chat.inkDim
                    font.pixelSize: metrics.fontTiny
                    font.family: "monospace"
                  }
                  Text {
                    id: asteps
                    anchors.right: parent.right
                    width: Math.min(implicitWidth, parent.width * 0.6)
                    elide: Text.ElideLeft
                    text: (arow.modelData.tools || 0) + " steps"
                          + (arow.modelData.lastTool ? " · " + arow.modelData.lastTool : "")
                          + (arow.modelData.lastEventAt ? " · " + chat.fmtDur(chat.now - arow.modelData.lastEventAt) + " ago" : "")
                    color: chat.inkMute
                    font.pixelSize: metrics.s(10)
                    font.family: "monospace"
                  }
                }
              }
              TextEdit {
                visible: arow.open && arow.modelData.task !== ""
                width: parent.width
                text: "Task: " + arow.modelData.task
                readOnly: true; selectByMouse: true
                wrapMode: TextEdit.Wrap
                color: chat.inkMute
                selectionColor: chat.crimsonHi
                font.pixelSize: metrics.fontTiny
                font.family: "monospace"
              }
              TextEdit {                   // what this run was asked (a resumed agent's follow-up message)
                visible: arow.open && !!arow.modelData.followup
                width: parent.width
                text: "Follow-up (run " + arow.run + "): " + (arow.modelData.followup || "")
                readOnly: true; selectByMouse: true
                wrapMode: TextEdit.Wrap
                color: chat.inkMute
                selectionColor: chat.crimsonHi
                font.pixelSize: metrics.fontTiny
                font.family: "monospace"
              }
              TextEdit {
                visible: arow.open
                width: parent.width
                text: arow.modelData.result ? (arow.run > 1 ? "Run " + arow.run + ": " : "") + arow.modelData.result
                      : arow.modelData.status === "running" ? (arow.run > 1 ? "Run " + arow.run + " still working…" : "Still working…")
                      : arow.modelData.status === "queued" ? "Follow-up accepted, run " + arow.run + " hasn't started yet."
                      : "(no result text)"
                readOnly: true; selectByMouse: true
                wrapMode: TextEdit.Wrap
                color: chat.inkDim
                selectionColor: chat.crimsonHi
                font.pixelSize: metrics.fontSmall
                font.family: "monospace"
              }
              Text {                       // earlier runs of a resumed agent, collapsed so they don't read as the current one
                visible: arow.open && arow.earlier.length > 0
                text: (chat.openRuns === arow.modelData.id ? "󰅀 " : "󰅂 ") + "Earlier runs (" + arow.earlier.length + ")"
                color: chat.inkMute
                font.pixelSize: metrics.fontTiny
                font.family: "monospace"
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: chat.openRuns = chat.openRuns === arow.modelData.id ? "" : arow.modelData.id
                }
              }
              Repeater {
                model: arow.open && chat.openRuns === arow.modelData.id ? arow.earlier.slice().reverse() : []
                TextEdit {
                  required property var modelData
                  width: arowCol.width
                  leftPadding: metrics.s(10)
                  text: "Run " + modelData.run + " · " + modelData.status
                        + (modelData.endedAt && modelData.startedAt ? " · took " + chat.fmtDur(modelData.endedAt - modelData.startedAt) : "")
                        + (modelData.endedAt ? " · " + chat.fmtDur(chat.now - modelData.endedAt) + " ago" : "")
                        + (modelData.task ? "\nFollow-up: " + modelData.task : "")
                        + "\n" + (modelData.result || "(no result text)")
                  readOnly: true; selectByMouse: true
                  wrapMode: TextEdit.Wrap
                  color: chat.inkMute
                  selectionColor: chat.crimsonHi
                  font.pixelSize: metrics.fontTiny
                  font.family: "monospace"
                }
              }
            }
          }
        }
      }
    }
  }

  // pending attachments (Ctrl+V / drop / paperclip): thumbnails with a remove button, sent with the next message
  Row {
    id: attachRow
    visible: chat.attachments.length > 0
    x: chat.pad
    y: inputBar.y - height - metrics.s(10)
    spacing: metrics.spacingSmall
    Repeater {
      model: chat.attachments
      Rectangle {
        required property string modelData
        required property int index
        width: metrics.s(64); height: metrics.s(64)
        radius: metrics.s(10)
        color: chat.glass
        border.width: 1
        border.color: chat.goldDim
        clip: true
        Image {
          visible: chat.isImage(parent.modelData)
          anchors.fill: parent; anchors.margins: metrics.s(3)
          source: visible ? "file://" + parent.modelData : ""
          fillMode: Image.PreserveAspectCrop
          sourceSize.height: metrics.s(128)
          asynchronous: true
        }
        Column {                                   // any other file: icon and name
          visible: !chat.isImage(parent.modelData)
          anchors.centerIn: parent
          width: parent.width - metrics.s(6)
          spacing: metrics.s(2)
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: /\.pdf$/i.test(parent.parent.modelData) ? "󰈦" : "󰈔"
            color: chat.gold
            font.pixelSize: metrics.fontLarge; font.family: "monospace"
          }
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: parent.parent.modelData.replace(/^.*\//, "")
            elide: Text.ElideMiddle
            color: chat.inkDim
            font.pixelSize: metrics.fontTiny; font.family: "monospace"
          }
        }
        Rectangle {
          anchors.right: parent.right; anchors.top: parent.top; anchors.margins: metrics.s(2)
          width: metrics.s(18); height: width; radius: width / 2
          color: Qt.rgba(0.05, 0.03, 0.1, 0.85)
          Text { anchors.centerIn: parent; text: "󰅖"; color: "#ff9fb2"; font.pixelSize: metrics.fontTiny; font.family: "monospace" }
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: chat.unattach(parent.parent.index) }
        }
      }
    }
  }

  // paperclip / Ctrl+O: browse for files to attach; covers the log and the tray while open
  QFilePicker {
    id: filePicker
    objectName: "filePicker"
    x: chat.pad
    y: divider.y + metrics.s(12)
    width: parent.width - chat.pad * 2
    height: chat.dockTop - y - metrics.s(12)
    z: 10
    radius: metrics.s(16)
    color: Qt.rgba(0.05, 0.035, 0.12, 0.97)
    border.color: chat.goldDim
    insetColor: Qt.rgba(1, 1, 1, 0.06)
    accentColor: chat.gold
    onAccentColor: "#1a1030"
    textColor: chat.ink
    subTextColor: chat.inkDim
    mutedColor: chat.inkMute
    onPicked: path => chat.attach(path)
    onClosed: input.forceActiveFocus()
  }

  // input: gold-bordered box with the paperclip, mic and send/stop buttons inside it
  Rectangle {
    id: inputBar
    x: chat.pad
    width: parent.width - chat.pad * 2
    height: metrics.s(54)
    y: parent.height - height - chat.pad
    radius: metrics.s(16)
    color: Qt.rgba(0.06, 0.04, 0.13, 0.95)
    border.width: 1
    border.color: input.activeFocus ? chat.gold : chat.goldDim
    Behavior on border.color { ColorAnimation { duration: 200 } }

    Text {
      x: metrics.s(18)
      anchors.verticalCenter: parent.verticalCenter
      text: chat.busy && chat.mode === "text" ? "Q is answering…" : "Speak, mortal…"
      color: chat.inkMute
      font.pixelSize: metrics.s(15)
      font.family: "monospace"
      visible: !input.text
    }
    TextInput {
      id: input
      x: metrics.s(18)
      width: buttons.x - x - metrics.s(10)
      anchors.verticalCenter: parent.verticalCenter
      color: chat.ink
      selectionColor: chat.crimsonHi
      selectedTextColor: "#ffffff"
      font.pixelSize: metrics.s(15)
      font.family: "monospace"
      clip: true
      focus: true
      Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          chat.send(); event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          if (chat.preview) chat.preview = ""; else if (chat.busy) chat.stop(); else bar.state = "normal"
          event.accepted = true
        } else if (event.key === Qt.Key_V && (event.modifiers & Qt.ControlModifier)) {
          chat.pasteImage(); event.accepted = true      // image if the clipboard has one, else plain text
        } else if (event.key === Qt.Key_Up && input.text === "") {
          input.text = chat.lastTyped; event.accepted = true
        } else if (event.key === Qt.Key_O && (event.modifiers & Qt.ControlModifier)) {
          filePicker.open(); event.accepted = true
        } else if (event.key === Qt.Key_Space && (event.modifiers & Qt.ControlModifier)) {
          chat.micPressed(); event.accepted = true
        }
      }
    }

    Row {
      id: buttons
      anchors.right: parent.right
      anchors.rightMargin: metrics.s(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: metrics.s(6)

      Rectangle {
        id: clipBtn
        width: metrics.s(38); height: width
        radius: metrics.s(11)
        color: filePicker.visible ? chat.gold : clipHover.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.05)
        Text {
          anchors.centerIn: parent
          text: "󰏢"
          color: filePicker.visible ? "#1a1030" : chat.gold
          font.pixelSize: metrics.s(17)
          font.family: "monospace"
        }
        MouseArea {
          id: clipHover
          anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
          onClicked: filePicker.visible ? filePicker.close() : filePicker.open()
        }
      }

      Rectangle {
        id: micBtn
        width: metrics.s(38); height: width
        radius: metrics.s(11)
        color: chat.mode === "voice" ? chat.statusColor : micHover.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.05)
        opacity: chat.busy && chat.mode === "text" ? 0.4 : 1
        Text {
          anchors.centerIn: parent
          text: "󰍬"
          color: chat.mode === "voice" ? "#1a1030" : chat.gold
          font.pixelSize: metrics.s(17)
          font.family: "monospace"
        }
        MouseArea { id: micHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: chat.micPressed() }
      }

      Rectangle {
        id: actBtn
        width: metrics.s(38); height: width
        radius: metrics.s(11)
        color: actHover.containsMouse ? chat.crimsonHi : chat.crimson
        border.width: 1
        border.color: chat.crimsonHi
        Text {
          anchors.centerIn: parent
          text: chat.busy ? "󰓛" : "󰒊"
          color: "#ffe8ee"
          font.pixelSize: metrics.s(17)
          font.family: "monospace"
        }
        MouseArea { id: actHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: chat.busy ? chat.stop() : chat.send() }
      }
    }
  }

  // enlarged picture: click anywhere or press Esc to close, the button opens it in the image viewer
  Rectangle {
    visible: chat.preview !== ""
    anchors.fill: parent
    z: 50
    radius: chat.radius
    color: Qt.rgba(0.02, 0.01, 0.06, 0.9)
    border.width: 1
    border.color: chat.goldDim
    MouseArea { anchors.fill: parent; onClicked: chat.preview = "" }
    Image {
      anchors.fill: parent
      anchors.margins: chat.pad * 2
      source: chat.preview ? "file://" + chat.preview : ""
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      smooth: true; mipmap: true
    }
    Row {
      anchors.right: parent.right; anchors.top: parent.top; anchors.margins: chat.pad
      spacing: metrics.spacingSmall
      Repeater {
        model: [["󰏌", "open"], ["󰅖", "close"]]
        Rectangle {
          required property var modelData
          width: metrics.s(34); height: width; radius: metrics.s(10)
          color: Qt.rgba(1, 1, 1, 0.07)
          border.width: 1; border.color: chat.goldDim
          Text { anchors.centerIn: parent; text: parent.modelData[0]; font.pixelSize: metrics.fontLarge; font.family: "monospace"
                 color: parent.modelData[1] === "close" ? "#ff9fb2" : chat.gold }
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                      onClicked: { if (parent.modelData[1] === "open") Quickshell.execDetached(["xdg-open", chat.preview]); chat.preview = "" } }
        }
      }
    }
  }
}
