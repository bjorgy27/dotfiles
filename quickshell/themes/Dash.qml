// Dashboard "instrument panel" tunables, in one place. Every major feature of
// the mission-control pass has an on/off flag here; durations come from Motion.
//
//   ripple     open choreography: cards power up outward from the focal card
//   standby    after standbyMs without pointer movement the panel settles into
//              a low-contrast standby; any movement wakes it
//   traces     sparkline history traces (CPU/RAM gauges, network scope)
pragma Singleton
import QtQuick
import Quickshell

Singleton {
    // ---- feature flags
    readonly property bool rippleEnabled: true
    readonly property bool standbyEnabled: true
    readonly property bool tracesEnabled: true

    // ---- open choreography (focal ripple)
    // Delay of a card = revealBase + (distance from the focal card / farthest) * revealSpread.
    readonly property int revealBase: 60          // ms after the pocket starts morphing
    readonly property int revealSpread: 260       // ms between the focal card and the farthest one
    readonly property real revealSlide: 10        // unscaled px a card travels outward while it fades in

    // ---- standby
    readonly property int standbyMs: 45000
    readonly property real standbyVeil: 0.42      // opacity of the panel-coloured veil in standby
    readonly property int standbyFade: 1600       // ms to settle (InOutSine); waking uses Motion.enter

    // ---- traces
    readonly property int traceSamples: 60
    readonly property real traceOpacity: 0.55
    readonly property real traceFill: 0.08
}
