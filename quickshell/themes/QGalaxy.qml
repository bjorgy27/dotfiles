// Q Galaxy: the Q chat drawer's palette (QChatWidget.qml) for the whole shell.
// Deep-space violet, gold hairlines and headings, crimson and violet accents.
import QtQuick

ColorTheme {
    name: "Q Galaxy"
    isDark: true

    // palette, from the lion portrait: deep space, the robe's crimson and gold
    readonly property QtObject q: QtObject {
        readonly property color gold:      "#d4af61"
        readonly property color goldDim:   "#8a7442"
        readonly property color crimson:   "#8e1f33"
        readonly property color crimsonHi: "#b8304a"
        readonly property color violet:    "#c58cff"
        readonly property color ink:       "#e9e4f5"
        readonly property color inkDim:    "#a49cbc"
        readonly property color inkMute:   "#6d6589"
        readonly property color sky0:      "#150b33"
        readonly property color sky1:      "#0d0822"
        readonly property color sky2:      "#08061a"
        readonly property color glass:     Qt.rgba(0.10, 0.07, 0.20, 0.85)   // the agent tiles
        readonly property color glassHi:   Qt.rgba(0.17, 0.10, 0.32, 0.95)   // an open tile
        readonly property color well:      Qt.rgba(0.06, 0.04, 0.13, 0.95)   // the input box
        readonly property color mist:      Qt.rgba(0.6, 0.45, 0.9, 0.25)     // Q's bubble border
    }

    // → roles (status hues are the chat's: listening, decoding, speaking, done, error)
    red:           "#ff7a8e"
    orange:        "#f0a36b"
    yellow:        "#ecc879"
    green:         "#8fd19e"
    teal:          "#7fdcc9"
    cyan:          "#86d3f0"
    blue:          "#8fb4ff"
    indigo:        "#9d8cff"
    violet:        q.violet
    lavender:      "#b9b4f5"
    pink:          "#f08cd6"

    background:    q.sky1
    panel:         q.glass
    panelDeep:     "#0b0720"
    inset:         q.glassHi
    border:        "#3a2b62"

    textPrimary:   q.ink
    textSecondary: q.inkDim
    textMuted:     q.inkMute

    accent:        q.gold
    live:          q.violet
    onAccent:      "#1a1030"

    surface:       "transparent"
    card:          q.glass
    cardBorder:    q.mist
    field:         q.well
    fieldBorder:   q.goldDim
    fieldFocus:    q.gold
    rule:          q.goldDim
    ruleFades:     true
    heading:       q.gold
    label:         q.goldDim
    headingSpacing: 2
    headingCaps:   true

    skyTop:        q.sky0
    skyMid:        q.sky1
    skyBottom:     q.sky2
    hairline:      Qt.rgba(0.54, 0.45, 0.26, 0.75)   // goldDim, a touch see-through along the bar
    nebula:        true
}
