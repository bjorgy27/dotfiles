import QtQuick
import Quickshell
import "themes"
import "QHl.js" as Hl

// One part of a Q reply as rendered by QMd.js: rich-text blocks (prose, lists, tables...) and fenced code
// blocks, each in its own item. The blocks sit in a ListModel that is updated in place, so a streaming reply only
// re-lays out the block that grew (no flicker, a selection in an earlier block survives). Code cards are syntax
// highlighted by QHl.js (rich-text spans; the copy button still copies the raw code).
Column {
  id: view
  property var blocks: []
  property bool pending: false          // still streaming: cursor at the end
  property string lead: ""              // glyph before the first block (the dimmed, unspoken part)
  property color textColor: Theme.colors.textSecondary
  property real fontPx: metrics.fontNormal
  spacing: metrics.s(6)

  readonly property var shown: (blocks && blocks.length) ? blocks
                               : (pending || lead !== "" ? [{ kind: "rich", html: "", code: "", lang: "", open: false }] : [])
  onShownChanged: sync()
  Component.onCompleted: { hlColors = Hl.palette(Theme.colors); sync() }

  // syntax colours from the live theme roles (Hl.palette fits each to 4.5:1 on the card), re-read 250 ms after a
  // change (a theme fade animates every colour)
  property var hlColors: null
  readonly property string hlKey: "" + Theme.colors.violet + Theme.colors.green + Theme.colors.orange + Theme.colors.blue + Theme.colors.yellow
                                  + Theme.colors.cyan + Theme.colors.red + Theme.colors.pink + Theme.colors.lavender + Theme.colors.textMuted
                                  + Theme.colors.textSecondary + Theme.colors.textPrimary + Theme.colors.inset + Theme.colors.panel
  onHlKeyChanged: hlTimer.restart()
  Timer { id: hlTimer; interval: 250; onTriggered: view.hlColors = Hl.palette(Theme.colors) }
  function sync() {
    let b = shown
    for (let i = 0; i < b.length; i++) {
      let e = { kind: b[i].kind, html: b[i].html, code: b[i].code, lang: b[i].lang, open: b[i].open }
      if (i >= blockModel.count) { blockModel.append(e); continue }
      let cur = blockModel.get(i)
      if (cur.kind !== e.kind) { blockModel.set(i, e); continue }
      for (let k of ["html", "code", "lang", "open"]) if (cur[k] !== e[k]) blockModel.setProperty(i, k, e[k])
    }
    while (blockModel.count > b.length) blockModel.remove(blockModel.count - 1)
  }
  ListModel { id: blockModel }

  Repeater {
    model: blockModel
    Loader {
      id: blk
      required property int index
      required property string kind
      required property string html
      required property string code
      required property string lang
      required property bool open
      readonly property bool last: index === blockModel.count - 1
      width: view.width
      sourceComponent: kind === "code" ? codeComp : kind === "rule" ? ruleComp : richComp

      Component {
        id: ruleComp
        Item {
          width: blk.width
          height: metrics.s(9)
          Rectangle { y: Math.floor(parent.height / 2); width: parent.width; height: 1; color: Theme.colors.border }
        }
      }

      Component {
        id: richComp
        TextEdit {
          width: blk.width
          // lead goes inside the first paragraph, the cursor inside the last one
          text: {
            let h = blk.html
            if (blk.index === 0 && view.lead !== "") h = h === "" ? view.lead : h.replace(/^((?:<[^>]+>)*)/, "$1" + view.lead)
            if (blk.last && view.pending) h = h === "" ? "▍" : h.replace(/((?:<\/[a-z]+>)*)$/, " ▍$1")
            return h
          }
          readOnly: true
          selectByMouse: true
          wrapMode: TextEdit.Wrap
          textFormat: TextEdit.RichText
          color: view.textColor
          selectionColor: Theme.colors.blue
          selectedTextColor: Theme.colors.panelDeep
          font.pixelSize: view.fontPx
          font.family: Theme.fonts.mono
          onLinkActivated: link => { if (/^(https?:\/\/|mailto:)/i.test(link)) Qt.openUrlExternally(link) }
          HoverHandler { cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.IBeamCursor }
        }
      }

      Component {
        id: codeComp
        Rectangle {
          id: card
          width: blk.width
          height: head.height + codeText.implicitHeight + metrics.s(12)
          radius: metrics.radiusNormal * 0.7
          color: Qt.rgba(Theme.colors.inset.r, Theme.colors.inset.g, Theme.colors.inset.b, 0.45)
          border.width: 1
          border.color: Theme.colors.border
          clip: true
          property bool copied: false
          Timer { id: copiedTimer; interval: 1500; onTriggered: card.copied = false }

          // highlighted HTML ("" = unknown language / too long: escaped plain text). A big block that is still
          // streaming is re-highlighted at most every 150 ms instead of on every token.
          property string hl: ""
          function rehl() { hl = Hl.html(blk.code, blk.lang, view.hlColors) }
          Component.onCompleted: rehl()
          Timer { id: hlThrottle; interval: 150; onTriggered: card.rehl() }
          Connections {
            target: blk
            function onCodeChanged() { if (blk.open && view.pending && blk.code.length > 3000) { if (!hlThrottle.running) hlThrottle.start() } else card.rehl() }
            function onLangChanged() { card.rehl() }
            function onOpenChanged() { card.rehl() }
          }
          Connections { target: view; function onHlColorsChanged() { card.rehl() } }

          Item {
            id: head
            width: parent.width
            height: metrics.s(22)
            Rectangle { anchors.fill: parent; anchors.margins: 1; radius: card.radius; color: Theme.colors.inset; opacity: 0.6 }
            Text {
              x: metrics.s(10)
              anchors.verticalCenter: parent.verticalCenter
              text: (blk.lang || "code") + (blk.open && view.pending ? "  ·  …" : "")
              color: view.hlColors ? view.hlColors.label : Theme.colors.textMuted
              font.pixelSize: metrics.fontTiny
              font.family: Theme.fonts.mono
            }
            Text {
              id: copyBtn
              anchors.right: parent.right
              anchors.rightMargin: metrics.s(10)
              anchors.verticalCenter: parent.verticalCenter
              text: card.copied ? "󰄬 copied" : "󰆏 copy"
              color: !view.hlColors ? (card.copied ? Theme.colors.green : copyArea.containsMouse ? Theme.colors.textPrimary : Theme.colors.textMuted)
                     : card.copied ? view.hlColors.add : copyArea.containsMouse ? view.hlColors.fg : view.hlColors.label
              font.pixelSize: metrics.fontTiny
              font.family: Theme.fonts.mono
              MouseArea {
                id: copyArea
                anchors.fill: parent
                anchors.margins: -metrics.s(4)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  Quickshell.execDetached(["wl-copy", "--", blk.code])
                  card.copied = true
                  copiedTimer.restart()
                }
              }
            }
          }
          TextEdit {
            id: codeText
            x: metrics.s(10)
            y: head.height + metrics.s(6)
            width: parent.width - metrics.s(20)
            // always rich text (pre-wrap keeps spaces, tabs and newlines and still wraps), so a block that turns
            // highlighted or plain never switches format under the layout
            text: '<div style="white-space:pre-wrap">' + (card.hl !== "" ? card.hl : Hl.esc(blk.code))
                  + (blk.last && view.pending ? " ▍" : "") + "</div>"
            textFormat: TextEdit.RichText
            readOnly: true
            selectByMouse: true
            wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
            color: view.hlColors ? view.hlColors.fg : Theme.colors.textPrimary
            selectionColor: Theme.colors.blue
            selectedTextColor: Theme.colors.panelDeep
            font.pixelSize: metrics.fontSmall
            font.family: Theme.fonts.mono
            tabStopDistance: font.pixelSize * 2.4
          }
        }
      }
    }
  }
}
