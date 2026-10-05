// Color singleton. Set `flavor` to reskin; a machine can pick its own in the
// gitignored local.js (var themeFlavor = "mocha").
pragma Singleton
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
}
