// Color singleton. Set `flavor` to reskin; a machine can pick its own in the
// gitignored local.js (var themeFlavor = "mocha").
pragma Singleton
import QtQuick
import Quickshell
import "../local.js" as Local

Singleton {
    id: root

    // "galaxy" | "mocha" | "latte" | "frappe" | "macchiato"
    property string flavor: (typeof Local.themeFlavor === "string" && Local.themeFlavor) ? Local.themeFlavor : "galaxy"

    readonly property ColorTheme colors: {
        switch (flavor) {
        case "mocha":     return mocha;
        case "latte":     return latte;
        case "frappe":    return frappe;
        case "macchiato": return macchiato;
        case "galaxy":
        default:          return galaxy;
        }
    }

    readonly property QGalaxy galaxy: QGalaxy {}
    readonly property CatppuccinMocha mocha: CatppuccinMocha {}
    readonly property CatppuccinLatte latte: CatppuccinLatte {}
    readonly property CatppuccinFrappe frappe: CatppuccinFrappe {}
    readonly property CatppuccinMacchiato macchiato: CatppuccinMacchiato {}

    // Compat with upstream widgets (control center, dash tabs, calendar, Q markdown):
    // the per-wallpaper theme restructure is not pulled, so these are fixed values.
    readonly property bool isDark: colors.isDark
    property bool fading: false
    readonly property QtObject fonts: QtObject {
        property string ui: "Noto Sans"
        property string mono: "JetBrainsMono Nerd Font"
        property string display: "Noto Sans"
        readonly property string icon: "Symbols Nerd Font"
    }
    property real radiusScale: 1
    property real borderScale: 1
    function rs(n) { return n <= 0 ? 0 : Math.max(0, Math.round(n * radiusScale)); }
    function bw(n) { return n <= 0 ? 0 : (borderScale <= 0 ? 0 : Math.max(1, Math.round(n * borderScale))); }
    property real cardFrameOpacity: 0.5
    readonly property color cardFrame: Qt.rgba(colors.border.r, colors.border.g, colors.border.b, cardFrameOpacity)
    property real titleTracking: 1.5
}
