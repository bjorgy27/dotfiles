pragma ComponentBehavior: Bound
import QtQuick
import "themes"

// Q's portrait at the top of the chat panel (QChatWidget), and the corner lion (shell.qml). Pose follows the voice
// engine: root.voiceState (scripts/q_voice.py state.json) and root.voiceMood, the [lion:<mood>] tag the agent opens
// each reply with (stripped before anything is shown or spoken). Images: Beck's portraits, matted, all in one framing:
// assets/lion/<pose>.png are 512px discs on a deep-space backdrop; assets/lion/clear/<pose>.png are the same lion on
// transparent (framed: false), with the drawing's canvas left of and above the disc's square kept.
//   listening -> default (looking at you)        transcribing / thinking -> default + sweeping ring
//   reply streaming / speaking -> the mood pose, default for talk or no tag   error -> shrug
//   after the turn the mood pose stays for restSecs, then back to restPose (default; it was side_default)
// Only default moves, through assets/lion/shaders/face2.frag, warps of the drawing itself (maps in assets/lion/jaw/):
// while Q speaks its mouth opens (the chin drops, both corners stay joined, the cheeks and muzzle stretch with it)
// on the teeth from Beck's front_talk and laugh drawings and the tongue from front_talk, and its eyes and brows work
// with the speech; all the time it is up, it blinks and glances and its ears flick; at rest it plays a little on its
// own (see "the face" and "the ears").
Item {
  id: lion

  property real restSecs: 60
  // the pose at rest, where the face's idle play shows. "side_default" (the aloof profile) was the rest pose until
  // 2026-10-05; set it back here to have it again.
  property string restPose: "default"
  readonly property string st: root.voiceState
  readonly property string mood: root.voiceMood
  readonly property bool working: st === "transcribing" || (st === "thinking" && mood === "")

  readonly property var moodPose: ({ laugh: "laugh", point: "point", shrug: "shrug", yawn: "yawn", talk: "default" })
  property bool resting: true
  readonly property string pose: {
    if (st === "error") return "shrug"
    if (st === "listening" || working) return "default"
    if (st === "thinking" || st === "speaking") return moodPose[mood] || "default"
    if (resting || mood === "") return restPose
    return moodPose[mood] || "default"
  }

  Timer { id: restTimer; interval: lion.restSecs * 1000; onTriggered: lion.resting = true }
  onStChanged: {
    if (st === "idle") restTimer.restart()
    else { restTimer.stop(); resting = false }
  }

  // framed: false (the corner lion) drops the ring, the comet and the margins and shows the lion cut out on transparent
  property bool framed: true
  property color restColor: Theme.colors.border   // ring colour while idle (the chat drawer makes it gold)
  property real restOpacity: 0.6
  readonly property color ringColor: {
    switch (st) {
    case "listening":    return Theme.colors.teal;
    case "transcribing": return Theme.colors.lavender;
    case "thinking":     return Theme.colors.violet;
    case "speaking":     return Theme.colors.blue;
    case "error":        return Theme.colors.red;
    default:             return lion.restColor;
    }
  }
  readonly property real ringW: Math.max(2, Math.round(width * 0.03))
  readonly property bool active: visible && width > 0 && (!Window.window || Window.window.visible)

  // ---- the jaw (default only): one springy opening, 0 shut .. 1 wide, may overshoot. Target = speech level x a
  // syllable "chew" (3.8-6 Hz while the voice holds, restarted on every onset): each syllable opens and shuts again
  // before the next, so the jaw works through words even when the meter sits pinned at 1. Fast attack, a slightly
  // faster close, a little overshoot; each syllable picks a mouth shape between wide and round, and where the tongue
  // goes. The same pass drives the face while Q talks (stepTalkFace) and the ears' share of the speech.
  readonly property bool talking: st === "speaking" && root.voiceLive && front.pose === "default"
  property real jaw: 0
  property real jawVel: 0
  property real chew: 0          // phase, radians
  property real chewHz: 4.6
  property real lvlPrev: 0
  property real shape: 0         // -1 wide .. +1 round, eased towards shapeTo
  property real shapeTo: 0
  property real tongue: 0.4      // the tongue's top, as a share of the opening (low ~0.4, up at the teeth ~0.72)
  property real tongueTo: 0.4
  property real emph: 0          // emphasis, 0 .. 1: eyes a touch wider, brows up
  property real emphTo: 0
  property real hush: 0          // a pause in the speech, 0 .. 1: the pleased narrowing
  property real quiet: 0         // how long the voice has been quiet, s
  property real sinceEmph: 9     // s
  function syllable() {
    shapeTo = Math.random() * 1.7 - 0.7
    let r = Math.random()       // a wide, open vowel lies low; otherwise mostly low, some up at the teeth, some the tip
    tongueTo = shapeTo < -0.35 ? 0.34 + 0.05 * r : r < 0.3 ? 0.66 + 0.1 * Math.random() : r < 0.45 ? 0.52 : 0.38 + 0.08 * Math.random()
  }
  function stepJaw(dt) {
    let v = talking ? Math.min(1, root.voiceLevel) : 0
    let target = 0
    sinceEmph += dt
    if (talking) {
      if (v > 0.1) {
        if (v - lvlPrev > 0.22 || chew === 0) {                                                   // onset: open now
          if (v - lvlPrev > 0.35 && v > 0.7 && sinceEmph > 1.2 && Math.random() < 0.5) { emphTo = 1; sinceEmph = 0 }
          talkOnset(v, v - lvlPrev)
          chew = 0.25; syllable()
        }
        chew += dt * 2 * Math.PI * chewHz
        if (chew > 2 * Math.PI) { chew -= 2 * Math.PI; chewHz = 3.8 + Math.random() * 2.2; syllable() }
      } else chew = 0
      let ph = chew / (2 * Math.PI)      // open over the first 60% of the cycle, shut for the rest
      let c = ph < 0.6 ? Math.pow(Math.sin(Math.PI * ph / 0.6), 0.8) : 0
      target = Math.pow(v, 0.7) * (0.04 + 0.96 * c)
    } else shapeTo = 0
    let wasQuiet = quiet
    quiet = talking && v < 0.08 ? quiet + dt : 0
    lvlPrev = v
    if (talking) stepTalkFace(dt, v, wasQuiet)
    else stress = Math.max(0, stress - dt * 4)
    // the ears' share of the speech: up with emphasis and stress, the near ear quick, the far one lagging
    let kick = Math.min(1, emph + 0.5 * stress)
    kickL += (kick - kickL) * Math.min(1, dt * (kick > kickL ? 12 : 3.5))
    kickR += (kick - kickR) * Math.min(1, dt * (kick > kickR ? 5 : 2.2))
    shape += (shapeTo - shape) * Math.min(1, dt * 14)
    tongue += (tongueTo - tongue) * Math.min(1, dt * 16)
    emphTo = Math.max(0, emphTo - dt * 2.2)
    emph += (emphTo - emph) * Math.min(1, dt * (emphTo > emph ? 14 : 4))
    hush += ((quiet > 0.22 ? 1 : 0) - hush) * Math.min(1, dt * (quiet > 0.22 ? 2.5 : 8))
    for (let i = 0; i < 2; i++) {        // semi-implicit spring, two substeps
      let h = dt / 2, w = target > jaw ? 40 : 46, z = 0.55
      jawVel += (w * w * (target - jaw) - 2 * z * w * jawVel) * h
      jaw = Math.max(-0.2, Math.min(1.35, jaw + jawVel * h))
    }
  }

  // ---- the face while Q talks: its eyes and brows follow the speech, something under way most of the time and never
  // on a loop. Stressed syllables lift the brows, peaks widen the eyes (emph, above); mid-phrase it glances away as if
  // choosing a word and comes back on the point; phrase ends get a blink and a pleased squint, a lifted brow or a
  // skeptical one; a stretch with nothing gets a small move. It owns lookX .. smirk while Q talks (the idle play stops).
  property real stress: 0        // a stressed syllable's brow lift, 0 .. 1
  property real kickL: 0         // the ears' share of the speech, 0 .. 1: the near ear
  property real kickR: 0         // the far ear
  property var tf: ({})          // the talking face's state (plain JS: nothing binds to it)
  function tfChan(name, to, hold) { tf[name + "To"] = to; tf[name + "T"] = hold; tf.since = 0 }
  function tfReset() {
    tf = { stressTo: 0, stressT: 0, lookTo: 0, lookYTo: 0, lookT: 0, smugTo: 0, smugT: 0, smirkTo: 0, smirkT: 0,
           browTo: 0, browT: 0, skepTo: 0, skepT: 0, since: 0, phrase: 0, glanceAt: 0.6, glancing: false, glanceT: 0,
           lastEnd: "", sinceSkep: 9, sinceBrow: 9 }
  }
  function talkBlink(p) { if (!blinkAnim.running && Date.now() - lastBlinkAt > 700 && Math.random() < p) doBlink(Math.random() < 0.12) }
  function talkOnset(v, rise) {
    if (!faceOn || tf.since === undefined) return
    let r = Math.random()
    if (tf.glancing && tf.glanceT > 0.35 && (rise > 0.3 || tf.glanceT > 1.3)) {      // back on the point
      tf.glancing = false; tfChan("look", 0, 0); tf.lookYTo = 0
      if (r < 0.55) { tfChan("stress", 0.55 + 0.35 * Math.random(), 0.16); tf.sinceBrow = 0 }
      else talkBlink(0.35)
      return
    }
    if (rise > 0.3 && v > 0.6 && tf.sinceBrow > 0.45 && r < 0.55) {                    // a stressed syllable
      tfChan("stress", 0.3 + 0.5 * Math.random() * v, 0.1 + 0.15 * Math.random()); tf.sinceBrow = 0
    } else if (rise > 0.35 && tf.sinceSkep > 4 && r > 0.93) {                          // now and then: really?
      tfChan("skep", (Math.random() < 0.65 ? 1 : -1) * (0.55 + 0.35 * Math.random()), 0.6 + 0.6 * Math.random())
      tf.sinceSkep = 0
    }
  }
  function stepTalkFace(dt, v, wasQuiet) {
    if (!faceOn) return
    if (tf.since === undefined) tfReset()
    tf.since += dt; tf.sinceSkep += dt; tf.sinceBrow += dt
    for (let c of ["stress", "look", "smug", "smirk", "brow", "skep"])
      if (tf[c + "T"] > 0 && (tf[c + "T"] -= dt) <= 0) { tf[c + "To"] = 0; if (c === "look") tf.lookYTo = 0 }
    if (v >= 0.08 && wasQuiet > 0.22) {                                                   // a new phrase
      tf.phrase = 0
      tf.glanceAt = Math.random() < 0.7 ? 0.5 + 1.3 * Math.random() : 99
      talkBlink(0.2)
    }
    if (v >= 0.08) tf.phrase += dt
    if (quiet > 0.16 && wasQuiet <= 0.16) {                                               // the phrase ends
      tf.glancing = false; tf.lookTo = 0; tf.lookYTo = 0
      talkBlink(0.6)
      let r = Math.random(), m = r < 0.42 ? "smug" : r < 0.62 ? "skep" : r < 0.78 ? "brow" : "none"
      if (m === tf.lastEnd && m !== "none") m = m === "smug" ? "brow" : "smug"
      tf.lastEnd = m
      let hold = 0.45 + 0.6 * Math.random()
      if (m === "smug") { tfChan("smug", 0.5 + 0.35 * Math.random(), hold); tfChan("smirk", 0.3 + 0.4 * Math.random(), hold) }
      else if (m === "skep" && tf.sinceSkep > 2.5) {
        tfChan("skep", (Math.random() < 0.65 ? 1 : -1) * (0.6 + 0.35 * Math.random()), hold + 0.2); tf.sinceSkep = 0
      } else if (m === "brow") { tfChan("brow", 0.55 + 0.3 * Math.random(), 0.3 + 0.3 * Math.random()); tfChan("smug", 0.3, 0.6) }
    }
    if (v >= 0.08 && !tf.glancing && tf.phrase > tf.glanceAt) {                           // choosing a word
      tf.glancing = true; tf.glanceT = 0; tf.glanceAt = 99
      tfChan("look", (Math.random() < 0.55 ? 1 : -1) * (0.45 + 0.4 * Math.random()), 1.6)
      tf.lookYTo = Math.random() < 0.75 ? -(0.2 + 0.4 * Math.random()) : 0.35
    }
    if (tf.glancing && (tf.glanceT += dt) > 1.6) tf.glancing = false
    if (tf.since > 1.5 && v >= 0.08) {                                                    // nothing for a while
      let r = Math.random()
      if (r < 0.3) { tfChan("look", (Math.random() < 0.5 ? -1 : 1) * (0.2 + 0.15 * Math.random()), 0.5); tf.lookYTo = -0.15 }
      else if (r < 0.6) tfChan("stress", 0.35 + 0.25 * Math.random(), 0.2)
      else if (r < 0.85) tfChan("smug", 0.3 + 0.2 * Math.random(), 0.6)
      else talkBlink(1)
      tf.since = 0
    }
    let ease = (cur, to, up, down) => cur + (to - cur) * Math.min(1, dt * (Math.abs(to) > Math.abs(cur) ? up : down))
    stress = ease(stress, tf.stressTo, 18, 5)
    lookX = ease(lookX, tf.lookTo, 13, 9)
    lookY = ease(lookY, tf.lookYTo, 13, 9)
    smug = ease(smug, tf.smugTo, 7, 3.5)
    smirk = ease(smirk, tf.smirkTo, 7, 3.5)
    browUp = ease(browUp, tf.browTo, 14, 4)
    skeptic = ease(skeptic, tf.skepTo, 9, 3.5)
  }
  FrameAnimation {
    running: lion.active && (lion.talking || Math.abs(lion.jaw) > 0.002 || Math.abs(lion.jawVel) > 0.02
                             || Math.abs(lion.shape) > 0.01 || lion.emph > 0.002 || lion.hush > 0.002
                             || lion.stress > 0.002 || lion.kickL > 0.002 || lion.kickR > 0.002)
    onTriggered: lion.stepJaw(Math.min(frameTime, 0.05))
  }
  // the warp's field maps (256px data; a visible Image is what keeps its texture fed to the shader)
  component JawMap: Image {
    property string part
    width: 1; height: 1; opacity: 0
    smooth: true; mipmap: false
    source: Qt.resolvedUrl("assets/lion/jaw/default-" + part + ".png")
  }
  JawMap { id: jawLow; part: "low" }
  JawMap { id: jawUp; part: "up" }
  JawMap { id: jawShape; part: "shape" }
  JawMap { id: jawMask; part: "mask" }
  // the teeth and the tongue, lifted from the drawings and laid along the mouth line: the upper row hangs below it,
  // the lower row and the tongue stand above it (4 px per frame px over the effect's teethRect, so mipmapped)
  JawMap { id: teethUpMap; part: "teeth-up"; mipmap: true }
  JawMap { id: teethLowMap; part: "teeth-low"; mipmap: true }
  JawMap { id: tongueImg; part: "tongue"; mipmap: true }
  // the eyes' lid lines, measured off the drawing: one row per eye, 128 steps corner to corner
  JawMap { id: lidsImg; part: "lids" }
  readonly property bool mapsReady: [jawLow, jawUp, jawShape, jawMask, teethUpMap, teethLowMap, tongueImg, lidsImg]
                                    .every(m => m.status === Image.Ready)

  // ---- the face (default only), all of it the drawing's own pixels moved by face.frag: blinks every 3-6 s (now and
  // then a double) and, while Q isn't talking, an idle play of small moves 2.5-7.5 s apart, one at a time: a glance
  // away and back, a skeptical brow, a slow pleased narrowing, a faint smirk at the far corner of the mouth, the brows
  // lifted as if amused, a double blink. While Q talks the talking face above has the eyes and brows, beside the
  // blinks. Both lions (the panel's and the corner's) take their idle moments from a hash of the wall clock, so they
  // move as one. Timers run only while the default is on screen.
  readonly property bool faceOn: active && front.pose === "default" && mapsReady
  property real blink: 0         // 0 open .. 1 shut
  property real lookX: 0         // glance along the eyes, -1 .. 1
  property real lookY: 0         // and across them (+ down)
  property real smug: 0          // the pleased narrowing, 0 .. 1
  property real browUp: 0        // both brows, 0 .. 1 (may dip below 0 settling)
  property real skeptic: 0       // one brow up and arched: +1 the far one, -1 the near one
  property real smirk: 0         // the far corner of the mouth, 0 .. 1
  property real idleNone: 0      // an unused channel's target

  function hash(n) { let x = Math.sin((n % 1000003) * 91.3458 + 47.853) * 43758.5453; return x - Math.floor(x) }
  // the first event after now in a schedule of one per `len` ms slot, `spread` ms into it at most
  function nextSlot(now, len, spread, salt) {
    for (let k = Math.floor(now / len); ; k++) {
      let t = k * len + hash(k * 7 + salt) * spread
      if (t > now + 40) return { k: k, t: t }
    }
  }

  SequentialAnimation {
    id: blinkAnim
    NumberAnimation { target: lion; property: "blink"; to: 1; duration: 75; easing.type: Easing.InQuad }
    PauseAnimation { duration: 35 }
    NumberAnimation { target: lion; property: "blink"; to: 0; duration: 150; easing.type: Easing.OutQuad }
    PauseAnimation { duration: 80 }
  }
  property real lastBlinkAt: 0
  function doBlink(twice) { blinkAnim.loops = twice ? 2 : 1; blinkAnim.restart(); lastBlinkAt = Date.now() }
  Timer {
    id: blinkClock
    property int k: 0
    function arm() { let n = lion.nextSlot(Date.now(), 4500, 1500, 1); k = n.k; interval = Math.max(40, n.t - Date.now()); restart() }
    onTriggered: { if (Date.now() - lion.lastBlinkAt > 1200) lion.doBlink(lion.hash(k * 7 + 2) < 0.17); arm() }
  }

  // one channel of a move: ease to a value, hold it, ease back to rest
  component Swell: SequentialAnimation {
    id: sw
    property string prop: "idleNone"
    property real to: 0
    property int rise: 300
    property int hold: 1000
    property int fall: 500
    property int fallEasing: Easing.InOutSine
    NumberAnimation { target: lion; property: sw.prop; to: sw.to; duration: sw.rise; easing.type: Easing.InOutSine }
    PauseAnimation { duration: sw.hold }
    NumberAnimation { target: lion; property: sw.prop; to: 0; duration: sw.fall; easing.type: sw.fallEasing }
  }
  ParallelAnimation {
    id: move
    Swell { id: chA }
    Swell { id: chB }
  }
  function play(a, b) {           // a, b: [prop, to, rise, hold, fall, fallEasing?]; b may be null
    for (let [ch, m] of [[chA, a], [chB, b || ["idleNone", 0, 10, 10, 10]]]) {
      ch.prop = m[0]; ch.to = m[1]; ch.rise = m[2]; ch.hold = m[3]; ch.fall = m[4]
      ch.fallEasing = m[5] === undefined ? Easing.InOutSine : m[5]
    }
    move.restart()
  }
  readonly property var moves: ["glance", "glance", "glance", "smug", "smug", "skeptic", "skeptic", "smirk", "smirk",
                                "amused", "amused", "double", "rest"]
  function moveAt(k) {
    let i = Math.floor(hash(k * 7 + 3) * moves.length)
    if (moves[i] === moves[Math.floor(hash((k - 1) * 7 + 3) * moves.length)]) i = (i + 3) % moves.length
    return moves[i]
  }
  function idleMove(k) {
    let r = i => hash(k * 7 + 4 + i)           // this move's own dice
    let m = moveAt(k)
    if (talking || move.running) return       // talking: the talking face has it; and never two at once
    switch (m) {
    case "glance":   // away along the eyes, a hair up or down, and back; now and then a blink on the way back
      play(["lookX", (r(1) < 0.5 ? -1 : 1) * (0.55 + 0.45 * r(2)), 340, 700 + 900 * r(3), 450],
           ["lookY", (r(4) - 0.5) * 0.9, 340, 700 + 900 * r(3), 450])
      if (r(5) < 0.3) { blinkLater.interval = 340 + 700 + 900 * r(3); blinkLater.restart() }
      break
    case "smug":     // a slow, pleased narrowing, with a hint of the smirk
      play(["smug", 0.8 + 0.2 * r(1), 650, 900 + 500 * r(2), 700], ["smirk", 0.35 * r(3), 650, 900 + 500 * r(2), 700])
      break
    case "skeptic":  // one brow up, arched; mostly the far one
      play(["skeptic", r(1) < 0.65 ? 1 : -1, 300, 900 + 400 * r(2), 520], null)
      break
    case "smirk":    // the far corner of the mouth, and the eyes a touch pleased
      play(["smirk", 0.8 + 0.2 * r(1), 420, 1000 + 500 * r(2), 600], ["smug", 0.3, 420, 1000 + 500 * r(2), 600])
      break
    case "amused":   // the brows up as if at a thought, settling with a little dip
      play(["browUp", 0.75 + 0.25 * r(1), 260, 450 + 300 * r(2), 650, Easing.OutBack], ["smug", 0.25, 260, 450 + 300 * r(2), 650])
      break
    case "double":
      doBlink(true)
      break
    }
  }
  Timer { id: blinkLater; onTriggered: lion.doBlink(false) }
  Timer {
    id: idleClock
    property int k: 0
    function arm() { let n = lion.nextSlot(Date.now(), 5000, 2500, 5); k = n.k; interval = Math.max(40, n.t - Date.now()); restart() }
    onTriggered: { lion.idleMove(k); arm() }
  }
  NumberAnimation { id: settleAnim; target: lion; properties: "lookX,lookY,smug,browUp,skeptic,smirk"; to: 0; duration: 420; easing.type: Easing.InOutSine }
  onTalkingChanged: {
    if (talking) { move.stop(); settleAnim.stop(); tfReset() }
    else settleAnim.restart()
  }
  onFaceOnChanged: {
    if (faceOn) { blinkClock.arm(); idleClock.arm(); earClockL.arm(); earClockR.arm(); return }
    blinkClock.stop(); idleClock.stop(); blinkLater.stop(); blinkAnim.stop(); move.stop(); settleAnim.stop()
    earClockL.stop(); earClockR.stop(); flickL.stop(); flickR.stop()
    blink = 0; lookX = 0; lookY = 0; smug = 0; browUp = 0; skeptic = 0; smirk = 0; earFlickL = 0; earFlickR = 0
  }

  // ---- the ears (default only): each turns a few degrees about its base, the drawing's own ear moved (face2.frag).
  // Perked (up and forward) while Q listens to Beck, a little while it thinks, with the emphasis while it talks; at
  // rest they settle back, relaxed. Each ear flicks or twitches on its own clock, idle or talking; both lions share
  // the clocks (the wall clock's hash, like the face's).
  readonly property real earPose: st === "listening" ? 1
                                  : working || st === "thinking" ? 0.35 : st === "speaking" ? 0.15 : -0.55
  property real earBaseL: earPose
  property real earBaseR: earPose
  Behavior on earBaseL { NumberAnimation { duration: lion.earPose > lion.earBaseL ? 320 : 1500; easing.type: Easing.InOutSine } }
  Behavior on earBaseR { NumberAnimation { duration: lion.earPose > lion.earBaseR ? 520 : 2100; easing.type: Easing.InOutSine } }
  property real earFlickL: 0     // a tip flick, rad (+ clockwise on screen)
  property real earFlickR: 0
  component Flick: SequentialAnimation {
    id: fl
    property string prop: "earFlickL"
    property real amp: 0.1
    NumberAnimation { target: lion; property: fl.prop; to: fl.amp; duration: 60; easing.type: Easing.OutQuad }
    NumberAnimation { target: lion; property: fl.prop; to: -0.3 * fl.amp; duration: 140; easing.type: Easing.InOutSine }
    NumberAnimation { target: lion; property: fl.prop; to: 0; duration: 230; easing.type: Easing.InOutSine }
  }
  Flick { id: flickL; prop: "earFlickL" }
  Flick { id: flickR; prop: "earFlickR" }
  // a flick (mostly back and out, now and then twice) or a smaller twitch; out is anticlockwise for the near ear
  // (it points up) and clockwise for the far one (it points out to the right, so out is its tip dipping)
  function earFlick(fl, k, salt, out) {
    let r = i => hash(k * 7 + salt + i)
    fl.amp = out * (r(0) < 0.75 ? 1 : -0.7) * (r(1) < 0.35 ? 0.07 + 0.04 * r(2) : 0.15 + 0.08 * r(2))
    fl.loops = r(3) < 0.2 ? 2 : 1
    fl.restart()
  }
  Timer {
    id: earClockL
    property int k: 0
    function arm() { let n = lion.nextSlot(Date.now(), 4100, 3600, 11); k = n.k; interval = Math.max(40, n.t - Date.now()); restart() }
    onTriggered: { lion.earFlick(flickL, k, 12, -1); arm() }
  }
  Timer {
    id: earClockR
    property int k: 0
    function arm() { let n = lion.nextSlot(Date.now(), 5700, 5000, 17); k = n.k; interval = Math.max(40, n.t - Date.now()); restart() }
    onTriggered: { lion.earFlick(flickR, k, 18, 1); arm() }
  }

  // ---- crossfade: the new pose fades in over the old one, then the old one goes (on the discs it is already hidden
  // under the new one; the cut-outs differ in outline, so it has to fade from behind too)
  function src(p) { return Qt.resolvedUrl("assets/lion/" + (framed ? "" : "clear/") + p + ".png") }
  property Pose front: poseA
  function show(p) {
    if (front.pose === p) return
    fade.stop()
    let under = front, over = front === poseA ? poseB : poseA
    under.opacity = 1; under.z = 0
    over.pose = p; over.opacity = 0; over.z = 1
    front = over
    fade.over = over; fade.under = under
    fade.start()
  }
  // shell.qml sets voiceMood and voiceState one after the other: settle before fading, so the
  // in-between pose never flashes
  onPoseChanged: settle.restart()
  Timer { id: settle; interval: 40; onTriggered: lion.show(lion.pose) }
  Component.onCompleted: { poseA.pose = pose; poseA.opacity = 1 }
  SequentialAnimation {
    id: fade
    property Item over: null
    property Item under: null
    NumberAnimation { target: fade.over; property: "opacity"; from: 0; to: 1; duration: 320; easing.type: Easing.InOutQuad }
    NumberAnimation { target: fade.under; property: "opacity"; to: 0; duration: 160; easing.type: Easing.InOutQuad }
  }

  Item {
    id: portrait
    anchors.fill: parent
    anchors.margins: lion.framed ? lion.ringW * 2 : 0
    // breathes with the mic level while listening; while Q talks only the face moves
    scale: 1 + (lion.st === "listening" ? root.voiceLevel * 0.035 : 0)
    Behavior on scale { NumberAnimation { duration: 90 } }
    Pose { id: poseA }
    Pose { id: poseB }
  }

  // one pose's image, in the 512 frame of the discs; a cut-out also spills left and up by its pads (its size - 512).
  // The default is drawn through the face shader while it shows.
  component Pose: Image {
    id: img
    property string pose: ""
    readonly property real k: portrait.width / 512
    readonly property real padX: status === Image.Ready ? implicitWidth - 512 : 0
    readonly property real padY: status === Image.Ready ? implicitHeight - 512 : 0
    x: -padX * k; y: -padY * k
    width: (512 + padX) * k; height: (512 + padY) * k
    source: pose ? lion.src(pose) : ""
    smooth: true; mipmap: true
    opacity: 0
    visible: opacity > 0

    layer.enabled: pose === "default" && visible && lion.mapsReady
    layer.smooth: true
    layer.textureSize: Qt.size(Math.ceil(width * 1.5), Math.ceil(height * 1.5))
    layer.effect: ShaderEffect {
      readonly property real jaw: Math.max(0, lion.jaw)
      readonly property real shape: Math.max(-1, Math.min(1, 0.6 * lion.shape))
      readonly property real aa: 0.8 * 512 / Math.max(64, portrait.width)
      readonly property vector4d pullRound: Qt.vector4d(3.34, 1.04, -2.52, 7.56)    // from the jaw maps' build
      readonly property vector4d frame: Qt.vector4d(img.padX, img.padY, 512 + img.padX, 512 + img.padY)
      readonly property color cavTop: "#2a0610"
      readonly property color cavDeep: "#4a0f1f"
      readonly property var mapLow: jawLow
      readonly property var mapUp: jawUp
      readonly property var mapShape: jawShape
      readonly property var mapMask: jawMask
      readonly property vector4d teethRect: Qt.vector4d(212, 222, 136, 92)          // from the teeth maps' build
      readonly property vector2d drop: Qt.vector2d(-0.3162, 0.9487)
      readonly property var teethUp: teethUpMap
      readonly property var teethLow: teethLowMap
      // the tongue: its top this many px above the lower lip (the opening is ~21 px at jaw 1; past 14.5 the upper
      // teeth hide it anyway); lying low it shows its light front over the teeth and its back foreshortened, raised
      // more of its back and less of its front
      readonly property vector4d tongue: Qt.vector4d(Math.max(0.5, Math.min(14.5, lion.tongue * jaw * 21)),
                                                     -5 - 8 * Math.max(0, lion.tongue - 0.45), 0.55 + 0.5 * lion.tongue, 0)
      readonly property var tongueMap: tongueImg
      // the eyes and brows, from the face maps' build (build_face.py): centres and axes in the 512 frame
      readonly property vector4d eyeL: Qt.vector4d(257.71, 177.50, 0.8785, 0.4777)
      readonly property vector4d eyeR: Qt.vector4d(341.80, 204.14, 0.9870, 0.1605)
      readonly property vector4d eyeSpan: Qt.vector4d(-19.40, 24.40, -13.15, 14.15)
      readonly property vector4d lookWinL: Qt.vector4d(0.07, 0.17, 0.62, 0.78)
      readonly property vector4d lookWinR: Qt.vector4d(0.05, 0.14, 0.60, 0.82)
      readonly property vector2d lidsDec: Qt.vector2d(-6.708, 14.431)
      readonly property var lids: lidsImg
      readonly property vector4d browL: Qt.vector4d(280.9, 155.0, 0.6115, 0.7912)
      readonly property vector4d browR: Qt.vector4d(349.1, 180.0, 0.9212, -0.3891)
      readonly property vector4d browSize: Qt.vector4d(37, 19, 24, 13)
      readonly property vector2d smirkDir: Qt.vector2d(0.575, -0.818)
      // the ears, measured off the drawing: pivot (the middle of the base, where the mane covers it), axis to the tip;
      // a turn of 1 is ~6 degrees, perked: the near ear (pointing up) clockwise, the far one (pointing out) its tip up
      readonly property vector4d earL: Qt.vector4d(198, 110, -0.272, -0.962)
      readonly property vector4d earR: Qt.vector4d(398, 182, 0.963, -0.267)
      readonly property vector4d earSize: Qt.vector4d(55, 37, 56, 32)
      readonly property vector4d ears: Qt.vector4d(0.1 * (lion.earBaseL + 0.8 * lion.kickL), -0.1 * (lion.earBaseR + 0.8 * lion.kickR),
                                                   lion.earFlickL, lion.earFlickR)
      // what the moves add up to: narrowing (pleased), widening (emphasis, a lifted brow), the skeptical brow's eye
      // a touch wider and the other a touch narrower
      readonly property real narrow: Math.min(1, lion.smug + 0.75 * lion.hush)
      readonly property real widen: Math.min(1, lion.emph + 0.4 * Math.max(0, lion.browUp))
      readonly property real skFar: Math.max(0, lion.skeptic)
      readonly property real skNear: Math.max(0, -lion.skeptic)
      readonly property real lift: lion.browUp + 0.7 * lion.emph + 0.6 * lion.stress - 0.25 * narrow
      readonly property vector4d lidL: Qt.vector4d(0.84 * lion.blink + 0.26 * narrow - 0.12 * widen - 0.1 * skNear + 0.08 * skFar,
                                                   0.16 * lion.blink + 0.12 * narrow, 2.6 * lion.lookX, 0.7 * lion.lookY)
      readonly property vector4d lidR: Qt.vector4d(0.84 * lion.blink + 0.26 * narrow - 0.12 * widen - 0.1 * skFar + 0.08 * skNear + 0.06 * lion.smirk,
                                                   0.16 * lion.blink + 0.12 * narrow, 1.7 * lion.lookX, 0.5 * lion.lookY)
      readonly property vector4d brows: Qt.vector4d(3.0 * lift + 3.4 * skNear, 2.5 * lift + 2.9 * skFar, -1.4 * skNear, 1.3 * skFar)
      readonly property vector4d smirk: Qt.vector4d(326.5, 288.5, 14, 3.4 * lion.smirk)
      fragmentShader: Qt.resolvedUrl("assets/lion/shaders/face2.frag.qsb")
    }
  }

  // state ring: thin track in the state colour, brighter with the voice level
  Rectangle {
    visible: lion.framed
    anchors.fill: parent
    anchors.margins: lion.ringW / 2
    radius: width / 2
    color: "transparent"
    border.width: lion.ringW
    border.color: lion.ringColor
    opacity: lion.st === "idle" ? lion.restOpacity : sweep.visible ? 0.25 : 0.45 + (root.voiceLive ? root.voiceLevel * 0.55 : 0.2)
    Behavior on border.color { ColorAnimation { duration: 250 } }
  }

  // thinking / transcribing: a galaxy comet sweeping round the ring, tail deep indigo through violet and
  // magenta to a pink-white head, soft glow under it, star specks along it (painted once, rotated on the render thread)
  Canvas {
    id: sweep
    anchors.fill: parent
    opacity: lion.framed && (lion.working || lion.st === "thinking") ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 300 } }
    onWidthChanged: requestPaint()
    // the mane's palette, tail -> head: [t, r, g, b]
    readonly property var stops: [[0.00, 0.10, 0.06, 0.35], [0.30, 0.25, 0.12, 0.70], [0.55, 0.50, 0.20, 0.95],
                                  [0.78, 0.82, 0.25, 0.85], [0.92, 1.00, 0.50, 0.85], [1.00, 1.00, 0.88, 0.97]]
    function galaxy(t) {
      for (let k = 1; k < stops.length; k++) {
        let a = stops[k - 1], b = stops[k]
        if (t <= b[0]) {
          let u = (t - a[0]) / (b[0] - a[0])
          return [a[1] + (b[1] - a[1]) * u, a[2] + (b[2] - a[2]) * u, a[3] + (b[3] - a[3]) * u]
        }
      }
      return stops[stops.length - 1].slice(1)
    }
    onPaint: {
      let ctx = getContext("2d")
      ctx.reset()
      if (width < lion.ringW * 6) return       // not laid out yet (panel closed): nothing to draw
      let r = width / 2 - lion.ringW, cx = width / 2, cy = height / 2, n = 96, span = Math.PI * 1.35
      ctx.lineCap = "butt"
      for (let pass = 0; pass < 2; pass++) {    // pass 0: soft wide glow, pass 1: the arc itself
        for (let i = 0; i < n; i++) {           // tail fades in towards the head; slight overlap hides the seams
          let t = (i + 1) / n, c = galaxy(t)
          let a0 = -Math.PI / 2 + span * i / n, a1 = -Math.PI / 2 + span * (i + 1.4) / n
          ctx.strokeStyle = Qt.rgba(c[0], c[1], c[2], pass ? 0.15 + 0.85 * Math.pow(t, 1.2) : Math.pow(t, 2) * 0.3)
          ctx.lineWidth = lion.ringW * (pass ? 1.4 : 2.0)
          ctx.beginPath(); ctx.arc(cx, cy, r, a0, a1, false); ctx.stroke()
        }
      }
      // star specks along the arc, denser and brighter towards the head (fixed seed: identical every paint)
      let seed = 7
      function rnd() { seed = (seed * 16807) % 2147483647; return seed / 2147483647 }
      for (let s = 0; s < 22; s++) {
        let t = Math.pow(rnd(), 0.6), a = -Math.PI / 2 + span * t
        let rr = r + (rnd() - 0.5) * lion.ringW * 1.6, sz = lion.ringW * (0.15 + rnd() * 0.25)
        ctx.fillStyle = Qt.rgba(1, 0.96, 1, 0.35 + 0.65 * t * rnd())
        ctx.beginPath(); ctx.arc(cx + rr * Math.cos(a), cy + rr * Math.sin(a), sz, 0, 2 * Math.PI); ctx.fill()
      }
      let head = -Math.PI / 2 + span, hx = cx + r * Math.cos(head), hy = cy + r * Math.sin(head)
      ctx.fillStyle = Qt.rgba(1, 0.75, 0.95, 0.35)
      ctx.beginPath(); ctx.arc(hx, hy, lion.ringW * 1.5, 0, 2 * Math.PI); ctx.fill()
      ctx.fillStyle = Qt.rgba(1, 1, 1, 0.95)
      ctx.beginPath(); ctx.arc(hx, hy, lion.ringW * 0.85, 0, 2 * Math.PI); ctx.fill()
    }
    RotationAnimator on rotation {
      running: sweep.visible && lion.visible
      from: 0; to: 360; duration: 1300; loops: Animation.Infinite
    }
  }
}
