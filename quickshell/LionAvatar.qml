import QtQuick
import "themes"

// Q's portrait at the top of the chat panel (QChatWidget). Pose follows the voice engine:
// root.voiceState (scripts/q_voice.py state.json) and root.voiceMood, the [lion:<mood>] tag the agent opens each
// reply with (stripped before anything is shown or spoken). Images: assets/lion/*.png, 512px discs, same framing.
//   listening -> default (looking at you)        transcribing / thinking -> default + sweeping ring
//   reply streaming / speaking -> the mood pose  error -> shrug
//   after the turn the mood pose stays for restSecs, then back to side_default
Item {
  id: lion

  property real restSecs: 60
  readonly property string st: root.voiceState
  readonly property string mood: root.voiceMood
  readonly property bool working: st === "transcribing" || (st === "thinking" && mood === "")

  readonly property var moodPose: ({ laugh: "laugh", point: "point", shrug: "shrug", yawn: "yawn", talk: "front_talk" })
  property bool resting: true
  readonly property string pose: {
    if (st === "error") return "shrug"
    if (st === "listening" || working) return "default"
    if (st === "thinking" || st === "speaking") return moodPose[mood] || "front_talk"
    if (resting || mood === "") return "side_default"
    return mood === "talk" ? "default" : (moodPose[mood] || "default")   // done talking: mouth closed, still facing you
  }

  Timer { id: restTimer; interval: lion.restSecs * 1000; onTriggered: lion.resting = true }
  onStChanged: {
    if (st === "idle") restTimer.restart()
    else { restTimer.stop(); resting = false }
  }

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
  readonly property int srcPx: width > 180 ? 512 : 256     // the poses are 512px: full size when shown large
  readonly property real ringW: Math.max(2, Math.round(width * 0.03))

  // ---- crossfade: the new pose fades in over the old one (same disc backdrop, so no see-through dip)
  function src(p) { return Qt.resolvedUrl("assets/lion/" + p + ".png") }
  property Image front: imgA
  function show(p) {
    let url = src(p)
    if (front.source.toString() === url.toString()) return
    fade.stop()
    let under = front, over = front === imgA ? imgB : imgA
    under.opacity = 1; under.z = 0
    over.source = url; over.opacity = 0; over.z = 1
    front = over
    fade.target = over
    fade.start()
  }
  // shell.qml sets voiceMood and voiceState one after the other: settle before fading, so the
  // in-between pose never flashes
  onPoseChanged: settle.restart()
  Timer { id: settle; interval: 40; onTriggered: lion.show(lion.pose) }
  Component.onCompleted: { imgA.source = src(pose); imgA.opacity = 1 }
  NumberAnimation { id: fade; property: "opacity"; from: 0; to: 1; duration: 320; easing.type: Easing.InOutQuad }

  Item {
    id: portrait
    anchors.fill: parent
    anchors.margins: lion.ringW * 2
    // breathes with the voice level while talking or listening
    scale: 1 + (root.voiceLive ? root.voiceLevel * 0.035 : 0)
    Behavior on scale { NumberAnimation { duration: 90 } }
    Image {
      id: imgA
      anchors.fill: parent
      sourceSize.width: lion.srcPx; sourceSize.height: lion.srcPx
      smooth: true; mipmap: true
      opacity: 0
    }
    Image {
      id: imgB
      anchors.fill: parent
      sourceSize.width: lion.srcPx; sourceSize.height: lion.srcPx
      smooth: true; mipmap: true
      opacity: 0
    }
  }

  // state ring: thin track in the state colour, brighter with the voice level
  Rectangle {
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
    opacity: lion.working || lion.st === "thinking" ? 1 : 0
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
