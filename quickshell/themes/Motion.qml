// Shared motion vocabulary: every animation in the shell picks one of these
// durations and curves so things that move settle the same way. Tweak here.
pragma Singleton
import QtQuick
import Quickshell

Singleton {
    // Durations (ms)
    readonly property int fast: 90       // hover, press
    readonly property int std: 180       // value and colour changes, gauge fills, number tweens
    readonly property int enter: 240     // cards and the pocket coming in
    readonly property int exit: 120      // things leaving (no stagger)
    readonly property int slow: 600      // rare: state-change pulses
    readonly property int pocket: 100    // bar pocket morph between states (kept snappy, OutQuint)

    // Curves: OutCubic to enter/settle, InCubic to leave, InOutSine for ambient only.
    readonly property int easeIn: Easing.OutCubic
    readonly property int easeOut: Easing.InCubic
    readonly property int easeAmbient: Easing.InOutSine

    // Dashboard card reveal: per-card delay in reading order and slide distance (unscaled px).
    // revealStep 0 turns the stagger off (cards still fade); revealEnabled false skips it entirely.
    readonly property bool revealEnabled: true
    readonly property int revealStep: 30
    readonly property real revealSlide: 8
}
