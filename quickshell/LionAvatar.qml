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
//   after the turn the mood pose stays for restSecs, then back to side_default
// Only default talks: while Q speaks, its mouth opens through assets/lion/shaders/jaw.frag, a warp of the drawing
// itself (maps in assets/lion/jaw/): the chin drops, both corners stay joined, the cheeks and muzzle stretch with it.
// Nothing else moves while talking.
Item {
  id: lion

  property real restSecs: 60
  readonly property string st: root.voiceState
  readonly property string mood: root.voiceMood
  readonly property bool working: st === "transcribing" || (st === "thinking" && mood === "")

  readonly property var moodPose: ({ laugh: "laugh", point: "point", shrug: "shrug", yawn: "yawn", talk: "default" })
  property bool resting: true
  readonly property string pose: {
    if (st === "error") return "shrug"
    if (st === "listening" || working) return "default"
    if (st === "thinking" || st === "speaking") return moodPose[mood] || "default"
    if (resting || mood === "") return "side_default"
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
  // faster close, a little overshoot; each syllable picks a mouth shape between wide and round.
  readonly property bool talking: st === "speaking" && root.voiceLive && front.pose === "default"
  property real jaw: 0
  property real jawVel: 0
  property real chew: 0          // phase, radians
  property real chewHz: 4.6
  property real lvlPrev: 0
  property real shape: 0         // -1 wide .. +1 round, eased towards shapeTo
  property real shapeTo: 0
  function stepJaw(dt) {
    let v = talking ? Math.min(1, root.voiceLevel) : 0
    let target = 0
    if (talking) {
      if (v > 0.1) {
        if (v - lvlPrev > 0.22 || chew === 0) { chew = 0.25; shapeTo = Math.random() * 1.7 - 0.7 }   // onset: open now
        chew += dt * 2 * Math.PI * chewHz
        if (chew > 2 * Math.PI) { chew -= 2 * Math.PI; chewHz = 3.8 + Math.random() * 2.2; shapeTo = Math.random() * 1.7 - 0.7 }
      } else chew = 0
      let ph = chew / (2 * Math.PI)      // open over the first 60% of the cycle, shut for the rest
      let c = ph < 0.6 ? Math.pow(Math.sin(Math.PI * ph / 0.6), 0.8) : 0
      target = Math.pow(v, 0.7) * (0.04 + 0.96 * c)
    } else shapeTo = 0
    lvlPrev = v
    shape += (shapeTo - shape) * Math.min(1, dt * 14)
    for (let i = 0; i < 2; i++) {        // semi-implicit spring, two substeps
      let h = dt / 2, w = target > jaw ? 40 : 46, z = 0.55
      jawVel += (w * w * (target - jaw) - 2 * z * w * jawVel) * h
      jaw = Math.max(-0.2, Math.min(1.35, jaw + jawVel * h))
    }
  }
  FrameAnimation {
    running: lion.active && (lion.talking || Math.abs(lion.jaw) > 0.002 || Math.abs(lion.jawVel) > 0.02 || Math.abs(lion.shape) > 0.01)
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
  readonly property bool mapsReady: [jawLow, jawUp, jawShape, jawMask].every(m => m.status === Image.Ready)

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
    // breathes with the mic level while listening; while Q talks only the jaw moves
    scale: 1 + (lion.st === "listening" ? root.voiceLevel * 0.035 : 0)
    Behavior on scale { NumberAnimation { duration: 90 } }
    Pose { id: poseA }
    Pose { id: poseB }
  }

  // one pose's image, in the 512 frame of the discs; a cut-out also spills left and up by its pads (its size - 512).
  // The talking default is drawn through the jaw warp.
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

    layer.enabled: pose === "default" && lion.front === img && lion.mapsReady
                   && (lion.st === "speaking" || lion.jaw > 0.002 || Math.abs(lion.jawVel) > 0.02)
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
      fragmentShader: Qt.resolvedUrl("assets/lion/shaders/jaw.frag.qsb")
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
