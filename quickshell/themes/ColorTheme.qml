// Interface a theme implements: define a palette, map it onto these roles.
import QtQuick

QtObject {
    property string name: "unnamed"
    property bool isDark: true

    // Accent hues
    property color red
    property color orange
    property color yellow
    property color green
    property color teal
    property color cyan
    property color blue
    property color indigo
    property color violet
    property color lavender
    property color pink

    // Surfaces, deepest to most raised
    property color background
    property color panel
    property color panelDeep
    property color inset
    property color border

    // Text
    property color textPrimary
    property color textSecondary
    property color textMuted

    // Intent
    property color accent: blue
    property color error: red
    property color success: green
    property color warning: yellow
    property color live: blue          // something working right now (scanning, running)
    property color onAccent: panelDeep // text/icons drawn on an accent fill

    // Chrome (templates/Q*.qml, templates/Galaxy*.qml). The defaults keep a flat
    // theme looking as it always has; QGalaxy overrides them.
    property color surface: panel           // a dropdown panel's own backdrop, over the bar's fill
    property color card: panel              // dashboard tiles and other raised cards
    property color cardBorder: "transparent"
    property color field: inset             // text inputs
    property color fieldBorder: "transparent"
    property color fieldFocus: "transparent"
    property color rule: border             // separators
    property bool ruleFades: false          // separators taper off at both ends
    property color heading: textPrimary     // panel titles, the clock
    property color label: textSecondary     // small section labels
    property real headingSpacing: 0         // letter spacing (px at scale 1) for titles and labels
    property bool headingCaps: false

    // The bar and its dropdown
    property color skyTop: panelDeep        // fill, top of the bar -> bottom of a deep dropdown
    property color skyMid: panelDeep
    property color skyBottom: panelDeep
    property color hairline: "transparent"  // traced under the bar and round the dropdown
    property bool nebula: false             // violet/magenta glow inside an open dropdown
}
