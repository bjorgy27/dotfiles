import QtQuick
import Quickshell
import Quickshell.Io
import "themes"

// Q chat panel (SUPER+A): type or talk to Q from the bar, voice and text in one log.
// Backend: scripts/q_voice.py (the same engine as SUPER+T); typed turns run `q_voice.py turn --text`.
// Every client process appends its events to $XDG_RUNTIME_DIR/q-voice/events.jsonl and shell.qml tails
// that into root.qEvent, so turns show up here live (your words while you talk, then the reply) whether
// they came from SUPER+T, the mic button or the text box. Voice goes through q_voice.sh (same engine and
// pid as SUPER+T); typed turns run the client directly. History: ~/.local/state/q-voice/chat.jsonl.
Item {
  id: chat

  readonly property bool isOpen: bar.state === "q_chat"
  visible: isOpen

  anchors {
    top: metrics.isVertical ? undefined : parent.top
    left: metrics.isVertical ? parent.left : undefined
    // top edge flush with the bottom of the bar strip, so the bar's voice indicator stays visible above the log
    topMargin: metrics.isVertical ? 0 : bar.barThickness
    leftMargin: metrics.isVertical ? bar.dropdownWidgetPadding : 0
    horizontalCenter: metrics.isVertical ? undefined : parent.horizontalCenter
    verticalCenter: metrics.isVertical ? parent.verticalCenter : undefined
  }
  width: parent.width - (bar.dropdownWidgetPadding * 2)
  height: parent.height - (bar.dropdownWidgetPadding * 2) + (metrics.isVertical ? 0 : bar.dropdownWidgetPadding - bar.barThickness)

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
  property bool agentsOpen: false
  property string openAgent: ""         // id of the agent whose task/result is expanded
  property string openRuns: ""          // id of the agent whose earlier runs are listed
  property real now: Date.now()
  // One row per agent session, showing its latest run. A finished agent that gets a follow-up comes back as
  // "queued" (follow-up accepted, not started) then "running" with run > 1; earlier runs sit in a.runs.
  function agentActive(a) { return a.status === "running" || a.status === "queued" }
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
  readonly property bool voiceBusy: root.voiceState !== "idle"      // SUPER+T / mic engine running a turn
  // typed turns run detached (a shell reload must not kill them); typedPending tracks ours until the client exits
  property bool typedPending: false
  readonly property bool busy: typedPending || voiceBusy
  readonly property string mode: typedPending ? "text" : voiceBusy ? "voice" : ""
  readonly property string typedPid: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/q-voice/typed.pid"

  readonly property color statusColor: {
    switch (status) {
    case "listening":    return Theme.colors.teal;
    case "transcribing": return Theme.colors.lavender;
    case "thinking":     return Theme.colors.violet;
    case "speaking":     return Theme.colors.blue;
    case "error":        return Theme.colors.red;
    default:             return Theme.colors.textMuted;
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

  // ---- one turn = one client process
  // ---- images: Ctrl+V from the clipboard (wl-paste) or dropped files, sent with the next message
  property var attachments: []
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
        if (/\.(png|jpe?g|webp|gif)$/i.test(p)) chat.attach(p)
      }
    }
  }

  function send() {
    let t = input.text.trim()
    if ((t === "" && attachments.length === 0) || busy) return
    lastTyped = t
    input.text = ""
    follow = true
    let cmd = [python, client, "turn", "--json", "--text", t]   // typed turns stay quiet; the reply shows here
    for (let a of attachments) cmd.push("--image", a)
    attachments = []
    typedPending = true
    Quickshell.execDetached(cmd)
  }

  // same as SUPER+T: starts listening, or while a voice turn runs: send now / interrupt and listen again
  function micPressed() { if (!typedPending) Quickshell.execDetached([voiceSh, "toggle"]) }

  function stop() {
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
      let toks = messages.get(m).text.split(/\s+/).filter(t => t !== "")
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

  // ---- layout
  Rectangle {
    anchors.fill: parent
    color: Theme.colors.panel
    radius: metrics.radiusLarge
  }

  // header: title, status, speak toggle
  Item {
    id: header
    x: metrics.marginBar
    y: metrics.marginBar
    width: parent.width - metrics.marginBar * 2
    height: metrics.s(28)

    Rectangle {
      id: dot
      width: metrics.s(10); height: width; radius: width / 2
      anchors.verticalCenter: parent.verticalCenter
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
      id: title
      x: dot.width + metrics.spacingNormal
      anchors.verticalCenter: parent.verticalCenter
      text: "Q"
      color: Theme.colors.textPrimary
      font.pixelSize: metrics.fontLarge
      font.family: "monospace"
    }
  }

  // background agents: collapsible strip under the header (agents from the last day; "none" when empty)
  Column {
    id: agentsBox
    visible: true
    x: metrics.marginBar
    y: header.y + header.height + metrics.spacingSmall
    width: parent.width - metrics.marginBar * 2
    spacing: metrics.spacingSmall

    Rectangle {
      width: parent.width
      height: metrics.s(30)
      radius: metrics.radiusNormal
      color: Theme.colors.inset
      Text {
        x: metrics.s(12)
        anchors.verticalCenter: parent.verticalCenter
        text: "󰚩  Agents" + (chat.shownAgents.length === 0 ? "  ·  none" : "")
              + (chat.agentsRunning ? "  ·  " + chat.agentsRunning + " running" : "")
              + (chat.agentsQueued ? "  ·  " + chat.agentsQueued + " queued" : "")
              + ((chat.shownAgents.length - chat.agentsRunning - chat.agentsQueued - chat.agentsFailed) ? "  ·  " + (chat.shownAgents.length - chat.agentsRunning - chat.agentsQueued - chat.agentsFailed) + " done" : "")
              + (chat.agentsFailed ? "  ·  " + chat.agentsFailed + " failed" : "")
        color: chat.agentsRunning ? Theme.colors.teal : chat.agentsQueued ? Theme.colors.yellow
               : chat.shownAgents.length ? Theme.colors.textSecondary : Theme.colors.textMuted
        font.pixelSize: metrics.fontSmall
        font.family: "monospace"
      }
      Text {
        anchors.right: parent.right
        anchors.rightMargin: metrics.s(12)
        anchors.verticalCenter: parent.verticalCenter
        text: chat.agentsOpen ? "󰅀" : "󰅂"
        color: Theme.colors.textMuted
        font.pixelSize: metrics.fontSmall
        font.family: "monospace"
      }
      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: chat.agentsOpen = !chat.agentsOpen }
    }

    Flickable {
      visible: chat.agentsOpen
      width: parent.width
      height: Math.min(agentList.implicitHeight, chat.height * 0.4)
      contentHeight: agentList.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      Column {
        id: agentList
        width: parent.width
        spacing: metrics.s(4)
        Text {
          visible: chat.shownAgents.length === 0
          width: parent.width
          wrapMode: Text.Wrap
          text: "Nothing running. When you ask for something long, Q hands it to a background agent and it shows up here."
          color: Theme.colors.textMuted
          font.pixelSize: metrics.fontSmall
          font.family: "monospace"
        }
        Repeater {
          model: chat.shownAgents
          Rectangle {
            id: arow
            required property var modelData
            readonly property bool open: chat.openAgent === modelData.id
            readonly property color tint: modelData.status === "running" ? Theme.colors.teal
                                          : modelData.status === "queued" ? Theme.colors.yellow
                                          : modelData.status === "done" ? Theme.colors.green : Theme.colors.red
            readonly property int run: modelData.run || 1
            readonly property var earlier: modelData.runs || []
            width: agentList.width
            height: arowCol.implicitHeight + metrics.s(12)
            radius: metrics.radiusNormal
            color: arow.open ? Theme.colors.panelDeep : "transparent"
            border.width: 1
            border.color: Theme.colors.border
            Column {
              id: arowCol
              x: metrics.s(10); y: metrics.s(6)
              width: parent.width - metrics.s(20)
              spacing: metrics.s(4)
              Item {
                width: parent.width
                height: metrics.s(20)
                Text {
                  id: aicon
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
                  width: Math.min(implicitWidth, parent.width - x - awhen.width - abadges.width - metrics.spacingNormal * 2)
                  elide: Text.ElideRight
                  text: arow.modelData.label
                  color: Theme.colors.textPrimary
                  font.pixelSize: metrics.fontSmall
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
                      border.color: modelData.startsWith("+") ? Theme.colors.yellow : arow.tint
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
                  onClicked: chat.openAgent = arow.open ? "" : arow.modelData.id
                }
                Text {
                  id: awhen
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: chat.agentWhen(arow.modelData)
                  color: Theme.colors.textMuted
                  font.pixelSize: metrics.fontTiny
                  font.family: "monospace"
                }
              }
              TextEdit {
                visible: arow.open && arow.modelData.task !== ""
                width: parent.width
                text: "Task: " + arow.modelData.task
                readOnly: true; selectByMouse: true
                wrapMode: TextEdit.Wrap
                color: Theme.colors.textMuted
                font.pixelSize: metrics.fontTiny
                font.family: "monospace"
              }
              TextEdit {                   // what this run was asked (a resumed agent's follow-up message)
                visible: arow.open && !!arow.modelData.followup
                width: parent.width
                text: "Follow-up (run " + arow.run + "): " + (arow.modelData.followup || "")
                readOnly: true; selectByMouse: true
                wrapMode: TextEdit.Wrap
                color: Theme.colors.textMuted
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
                color: Theme.colors.textSecondary
                font.pixelSize: metrics.fontSmall
                font.family: "monospace"
              }
              Text {                       // earlier runs of a resumed agent, collapsed so they don't read as the current one
                visible: arow.open && arow.earlier.length > 0
                text: (chat.openRuns === arow.modelData.id ? "󰅀 " : "󰅂 ") + "Earlier runs (" + arow.earlier.length + ")"
                color: Theme.colors.textMuted
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
                  color: Theme.colors.textMuted
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

  // conversation
  ListView {
    id: log
    x: metrics.marginBar
    y: (agentsBox.visible ? agentsBox.y + agentsBox.height : header.y + header.height) + metrics.spacingNormal
    width: parent.width - metrics.marginBar * 2
    height: (attachRow.visible ? attachRow.y : inputBar.y) - y - metrics.spacingNormal
    clip: true
    spacing: metrics.spacingSmall
    model: messages
    boundsBehavior: Flickable.StopAtBounds
    onMovementEnded: chat.follow = atYEnd
    onContentHeightChanged: if (chat.follow) Qt.callLater(positionViewAtEnd)   // bubbles size in after the jump; streaming replies grow

    delegate: Item {
      id: row
      required property string role
      required property string text
      required property string speaker
      required property bool pending
      required property int hl
      required property int spoken      // chars of text that were read aloud; -1 = not a spoken turn (or all spoken)
      // Always RichText (escaped): switching textFormat back to PlainText after reading made the TextEdit show its own
      // generated HTML. The word being read aloud (hl) gets <i>.
      // Spoken turns: whatever wasn't read aloud (after [quiet], a late answer, a long pause) is dimmed behind a
      // muted-speaker glyph, so it's clear what you heard vs what only landed here.
      readonly property int cut: (row.role === "q" && row.spoken >= 0 && row.spoken < row.text.length) ? row.spoken : -1
      function richText() {
        let out = "", n = -1, off = 0, dim = false
        for (let part of row.text.split(/(\s+)/)) {
          if (part === "") continue
          if (row.cut >= 0 && !dim && off >= row.cut && !/^\s+$/.test(part)) {
            dim = true
            out += "<span style=\"color:" + Theme.colors.textMuted + "\">" + "󰖁 "
          }
          off += part.length
          if (/^\s+$/.test(part)) { out += part.replace(/\n/g, "<br>"); continue }
          n++
          let e = part.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
          out += n === row.hl ? "<i>" + e + "</i>" : e
        }
        if (dim) out += "</span>"
        return out + (row.pending ? " ▍" : "")
      }
      required property string imgs
      readonly property var pics: imgs ? imgs.split("\n") : []
      readonly property bool mine: role === "user"
      readonly property real maxW: (log.width - chat.gutter) * 0.82
      width: log.width - chat.gutter
      height: (who.visible ? who.height : 0) + (picRow.visible ? picRow.height + metrics.s(4) : 0)
              + (bubble.visible ? bubble.height : 0)

      Row {
        id: picRow
        visible: row.pics.length > 0
        y: who.visible ? who.height : 0
        anchors.right: row.mine ? parent.right : undefined
        spacing: metrics.s(4)
        Repeater {
          model: row.pics
          Image {
            required property string modelData
            source: "file://" + modelData
            height: metrics.s(120)
            width: Math.min(implicitWidth * height / Math.max(1, implicitHeight), row.maxW)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            sourceSize.height: metrics.s(240)
          }
        }
      }

      Text {
        id: who
        visible: row.mine && row.speaker !== "" && row.speaker.toLowerCase() !== chat.owner
        anchors.right: parent.right
        text: row.speaker.charAt(0).toUpperCase() + row.speaker.slice(1)
        color: Theme.colors.textMuted
        font.pixelSize: metrics.fontTiny
        font.family: "monospace"
      }
      TextMetrics { id: tm; font: body.font; text: row.text }
      Rectangle {
        id: bubble
        visible: row.text !== ""
        y: (who.visible ? who.height : 0) + (picRow.visible ? picRow.height + metrics.s(4) : 0)
        anchors.right: row.mine ? parent.right : undefined
        anchors.left: row.mine ? undefined : parent.left
        width: Math.min(tm.advanceWidth + metrics.s(24), row.maxW)
        height: body.implicitHeight + metrics.s(14)
        radius: metrics.radiusNormal
        color: row.role === "error" ? Qt.rgba(Theme.colors.red.r, Theme.colors.red.g, Theme.colors.red.b, 0.15)
             : row.mine ? Theme.colors.inset : Theme.colors.panelDeep
        border.width: row.mine ? 0 : 1
        border.color: row.role === "error" ? Theme.colors.red : Theme.colors.border
        TextEdit {
          id: body
          x: metrics.s(12)
          y: metrics.s(7)
          width: parent.width - metrics.s(24)
          text: row.richText()
          readOnly: true
          selectByMouse: true
          wrapMode: TextEdit.Wrap
          textFormat: TextEdit.RichText
          color: row.role === "error" ? Theme.colors.red : row.mine ? Theme.colors.textPrimary : Theme.colors.textSecondary
          selectionColor: Theme.colors.blue
          font.pixelSize: metrics.fontNormal
          font.family: "monospace"
        }
      }
    }

    Text {
      anchors.centerIn: parent
      visible: messages.count === 0
      text: "Type below, or press 󰍬 (or SUPER+T) to talk."
      color: Theme.colors.textMuted
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
    width: metrics.s(6)
    height: log.height
    Rectangle { anchors.fill: parent; radius: width / 2; color: Theme.colors.inset; opacity: 0.6 }
    Rectangle {
      id: handle
      width: parent.width
      radius: width / 2
      height: Math.max(metrics.s(28), log.visibleArea.heightRatio * scrollTrack.height)
      y: Math.min(scrollTrack.height - height, Math.max(0, log.visibleArea.yPosition * scrollTrack.height))
      color: dragArea.pressed || dragArea.containsMouse ? Theme.colors.textSecondary : Theme.colors.textMuted
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
    width: metrics.s(30); height: width; radius: width / 2
    x: log.x + log.width - chat.gutter - width - metrics.spacingSmall
    y: log.y + log.height - height - metrics.spacingSmall
    color: Theme.colors.inset
    border.width: 1
    border.color: Theme.colors.border
    Text { anchors.centerIn: parent; text: "󰁅"; color: Theme.colors.blue; font.pixelSize: metrics.fontNormal; font.family: "monospace" }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: chat.scrollDown(true) }
  }

  // pending attachments (Ctrl+V / drop): thumbnails with a remove button, sent with the next message
  Row {
    id: attachRow
    visible: chat.attachments.length > 0
    x: metrics.marginBar
    y: inputBar.y - height - metrics.spacingSmall
    spacing: metrics.spacingSmall
    Repeater {
      model: chat.attachments
      Rectangle {
        required property string modelData
        required property int index
        width: metrics.s(64); height: metrics.s(64)
        radius: metrics.radiusNormal
        color: Theme.colors.inset
        clip: true
        Image {
          anchors.fill: parent; anchors.margins: metrics.s(3)
          source: "file://" + parent.modelData
          fillMode: Image.PreserveAspectCrop
          sourceSize.height: metrics.s(128)
          asynchronous: true
        }
        Rectangle {
          anchors.right: parent.right; anchors.top: parent.top; anchors.margins: metrics.s(2)
          width: metrics.s(18); height: width; radius: width / 2
          color: Theme.colors.panelDeep
          Text { anchors.centerIn: parent; text: "󰅖"; color: Theme.colors.red; font.pixelSize: metrics.fontTiny; font.family: "monospace" }
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: chat.unattach(parent.parent.index) }
        }
      }
    }
  }

  // input row: text box, mic, stop/send
  Item {
    id: inputBar
    x: metrics.marginBar
    width: parent.width - metrics.marginBar * 2
    height: metrics.s(36)
    y: parent.height - height - metrics.marginBar

    Rectangle {
      id: box
      anchors.left: parent.left
      anchors.right: micBtn.left
      anchors.rightMargin: metrics.spacingSmall
      height: parent.height
      radius: metrics.radiusNormal
      color: Theme.colors.inset

      Text {
        x: metrics.s(12)
        anchors.verticalCenter: parent.verticalCenter
        text: chat.busy && chat.mode === "text" ? "Q is answering…" : "Message Q…"
        color: Theme.colors.textMuted
        font.pixelSize: metrics.fontNormal
        font.family: "monospace"
        visible: !input.text
      }
      TextInput {
        id: input
        x: metrics.s(12)
        width: parent.width - metrics.s(24)
        anchors.verticalCenter: parent.verticalCenter
        color: Theme.colors.textPrimary
        font.pixelSize: metrics.fontNormal
        font.family: "monospace"
        clip: true
        focus: true
        Keys.onPressed: event => {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            chat.send(); event.accepted = true
          } else if (event.key === Qt.Key_Escape) {
            if (chat.busy) chat.stop(); else bar.state = "normal"
            event.accepted = true
          } else if (event.key === Qt.Key_V && (event.modifiers & Qt.ControlModifier)) {
            chat.pasteImage(); event.accepted = true      // image if the clipboard has one, else plain text
          } else if (event.key === Qt.Key_Up && input.text === "") {
            input.text = chat.lastTyped; event.accepted = true
          } else if (event.key === Qt.Key_Space && (event.modifiers & Qt.ControlModifier)) {
            chat.micPressed(); event.accepted = true
          }
        }
      }
    }

    Rectangle {
      id: micBtn
      anchors.right: actBtn.left
      anchors.rightMargin: metrics.spacingSmall
      width: parent.height; height: parent.height
      radius: metrics.radiusNormal
      color: chat.mode === "voice" ? chat.statusColor : Theme.colors.inset
      opacity: chat.busy && chat.mode === "text" ? 0.4 : 1
      Text {
        anchors.centerIn: parent
        text: "󰍬"
        color: chat.mode === "voice" ? Theme.colors.background : Theme.colors.teal
        font.pixelSize: metrics.fontLarge
        font.family: "monospace"
      }
      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: chat.micPressed() }
    }

    Rectangle {
      id: actBtn
      anchors.right: parent.right
      width: parent.height; height: parent.height
      radius: metrics.radiusNormal
      color: Theme.colors.inset
      Text {
        anchors.centerIn: parent
        text: chat.busy ? "󰓛" : "󰒊"
        color: chat.busy ? Theme.colors.red : Theme.colors.blue
        font.pixelSize: metrics.fontLarge
        font.family: "monospace"
      }
      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: chat.busy ? chat.stop() : chat.send() }
    }
  }
}
