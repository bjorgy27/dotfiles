// One status language for the whole dashboard ("dark cockpit": nominal is
// quiet, colour is spent only on deviation). Levels:
//   -1 OFFLINE / STALE   0 NOMINAL   1 ADVISORY   2 CAUTION   3 WARNING
// Thresholds for every metric that reports a level live here, so cards and the
// mission strip agree on what "caution" means.
pragma Singleton
import QtQuick
import Quickshell

Singleton {
    readonly property int offline: -1
    readonly property int nominal: 0
    readonly property int advisory: 1
    readonly property int caution: 2
    readonly property int warning: 3

    // metric -> [advisory, caution, warning] lower bounds (higher is worse)
    readonly property var thresholds: ({
        cpu:  [70, 85, 95],
        ram:  [75, 85, 93],
        disk: [85, 92, 97],
        temp: [70, 80, 90],     // °C
        ping: [60, 150, 400]    // ms
    })

    function level(metric, value) {
        let t = thresholds[metric]
        if (!t || value === undefined || isNaN(value)) return nominal
        if (value >= t[2]) return warning
        if (value >= t[1]) return caution
        if (value >= t[0]) return advisory
        return nominal
    }

    function word(l) {
        return l >= 3 ? "WARNING" : l === 2 ? "CAUTION" : l === 1 ? "ADVISORY" : l === 0 ? "NOMINAL" : "NO DATA"
    }

    // Nominal stays secondary/muted text; only deviations get a hue.
    function color(l) {
        return l >= 3 ? Theme.colors.red : l === 2 ? Theme.colors.yellow : l === 1 ? Theme.colors.blue
             : l === 0 ? Theme.colors.textSecondary : Theme.colors.textMuted
    }
}
