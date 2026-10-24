import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"
import "themes"

// Proton Calendar card: the next event with a countdown; click for today's agenda.
// Data comes from calro (read-only, end-to-end encrypted) via scripts/polls/calendarpoll.sh.
// Without calro it shows "calendar offline" and keeps polling quietly.
// Preset options: "agenda": true starts on the agenda; "fixture": true (or a file path) shows sample
// events instead of calro's, for testing.
ThreeRowWidget {
  id: calendarWidget

  title: "󰃭  Calendar"
  refWidth: 742    // two columns x two rows in the calendar preset
  refHeight: 330
  // The agenda list scrolls inside the whole middle slot; the next-event view is centred in it.
  middleFills: showAgenda
  // Bigger next-event text when the card has the height for it
  readonly property bool roomy: middleHeight >= metrics.s(140)

  readonly property string fixture: options.fixture === true ? "default" : (typeof options.fixture === "string" ? options.fixture : "")

  property string state_: "loading"   // loading | ok | offline
  property string reason: ""
  property bool stale: false
  property var events: []
  property bool showAgenda: options.agenda === true
  property real now: Date.now()

  Timer { interval: 20000; running: calendarWidget.visible; repeat: true; triggeredOnStart: true; onTriggered: calendarWidget.now = Date.now() }

  PollProcess {
    command: calendarWidget.fixture === "" ? ["bash", root.home + "/.config/scripts/polls/calendarpoll.sh"]
           : calendarWidget.fixture === "default" ? ["bash", root.home + "/.config/scripts/polls/calendarpoll.sh", "--fixture"]
           : ["bash", root.home + "/.config/scripts/polls/calendarpoll.sh", "--fixture", calendarWidget.fixture]
    interval: 60000
    onOutput: text => {
      let d
      try { d = JSON.parse(text) } catch (e) { d = { state: "offline", reason: "no data" } }
      calendarWidget.state_ = d.state === "ok" ? "ok" : "offline"
      calendarWidget.reason = d.reason || ""
      calendarWidget.stale = !!d.stale
      calendarWidget.events = (d.events || []).map(e => Object.assign({}, e, { s: new Date(e.start).getTime(), e: new Date(e.end).getTime() }))
    }
  }

  TapHandler { onTapped: calendarWidget.showAgenda = !calendarWidget.showAgenda }

  readonly property real dayStart: { let d = new Date(now); d.setHours(0, 0, 0, 0); return d.getTime() }
  readonly property real dayEnd: dayStart + 86400000
  // Timed events still running or ahead; declined/cancelled ones don't count.
  readonly property var upcoming: events.filter(e => !e.all_day && !e.skip && e.e > now)
  readonly property var nextEvent: upcoming.length > 0 ? upcoming[0] : null
  readonly property var today: events.filter(e => e.s < dayEnd && e.e > dayStart)

  function hhmm(ms) { return Qt.formatTime(new Date(ms), "HH:mm") }
  function span(ms) {
    let m = Math.max(0, Math.round(ms / 60000))
    if (m < 60) return m + "m"
    let h = Math.floor(m / 60)
    if (h < 24) return h + "h " + (m % 60 ? (m % 60) + "m" : "")
    return Math.floor(h / 24) + "d " + (h % 24) + "h"
  }
  function when(e) {
    if (!e) return ""
    if (e.s <= now) return "now · ends in " + span(e.e - now)
    let day = e.s >= dayEnd + 86400000 ? Qt.formatDate(new Date(e.s), "ddd ") : e.s >= dayEnd ? "tomorrow " : ""
    return day + hhmm(e.s) + "–" + hhmm(e.e) + " · in " + span(e.s - now)
  }
  function whenColor(e) {
    if (!e) return Theme.colors.textMuted
    if (e.s <= now) return Theme.colors.green
    if (e.s - now < 15 * 60000) return Theme.colors.orange
    return Theme.colors.blue
  }

  middleContent: Component {
    Item {
      implicitHeight: calendarWidget.showAgenda ? agenda.contentHeight : nextCol.implicitHeight

      ColumnLayout {
        id: nextCol
        visible: !calendarWidget.showAgenda
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
        spacing: metrics.spacingTiny

        Text {
          Layout.fillWidth: true
          text: calendarWidget.state_ === "offline" ? "calendar offline"
              : calendarWidget.state_ === "loading" ? "…"
              : calendarWidget.nextEvent ? calendarWidget.nextEvent.summary : "Nothing coming up"
          color: calendarWidget.nextEvent && calendarWidget.state_ === "ok" ? Theme.colors.textPrimary : Theme.colors.textMuted
          font.pixelSize: calendarWidget.fs(calendarWidget.roomy ? metrics.fontXL : metrics.fontLarge)
          font.bold: calendarWidget.nextEvent !== null
          font.family: Theme.fonts.ui
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          visible: text !== ""
          text: calendarWidget.state_ === "ok" ? calendarWidget.when(calendarWidget.nextEvent) : ""
          color: calendarWidget.whenColor(calendarWidget.nextEvent)
          font.pixelSize: calendarWidget.fs(calendarWidget.roomy ? metrics.fontNormal : metrics.fontSmall)
          font.family: Theme.fonts.mono
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          // Location/calendar line is dropped first when the card is short
          visible: text !== "" && calendarWidget.middleHeight >= (calendarWidget.fs(metrics.fontLarge) + calendarWidget.fs(metrics.fontSmall) + calendarWidget.fs(metrics.fontTiny)) * 1.45 + 2 * metrics.spacingTiny
          text: calendarWidget.nextEvent && calendarWidget.state_ === "ok"
                ? [calendarWidget.nextEvent.location, calendarWidget.nextEvent.calendar].filter(x => x).join(" · ") : ""
          color: Theme.colors.textSecondary
          font.pixelSize: calendarWidget.fs(metrics.fontTiny)
          font.family: Theme.fonts.ui
          elide: Text.ElideRight
        }
      }

      ListView {
        id: agenda
        visible: calendarWidget.showAgenda
        anchors.fill: parent
        clip: true
        spacing: metrics.spacingTiny
        model: calendarWidget.today
        delegate: RowLayout {
          required property var modelData
          width: ListView.view.width
          spacing: metrics.spacingSmall
          readonly property bool past: modelData.e <= calendarWidget.now
          Text {
            text: modelData.all_day ? "all day" : calendarWidget.hhmm(modelData.s)
            color: Theme.colors.blue
            opacity: parent.past ? 0.5 : 1
            font.pixelSize: calendarWidget.fs(metrics.fontTiny)
            font.family: Theme.fonts.mono
            Layout.preferredWidth: Math.max(implicitWidth, calendarWidget.fs(metrics.s(44)))
          }
          Text {
            Layout.fillWidth: true
            text: modelData.summary + (modelData.verified === false ? " ⚠" : "")
            color: modelData.skip ? Theme.colors.textMuted : Theme.colors.textPrimary
            opacity: parent.past ? 0.5 : 1
            font.strikeout: modelData.skip
            font.pixelSize: calendarWidget.fs(metrics.fontSmall)
            font.family: Theme.fonts.ui
            elide: Text.ElideRight
          }
        }
        Text {
          visible: agenda.count === 0
          text: calendarWidget.state_ === "ok" ? "Nothing today" : "calendar offline"
          color: Theme.colors.textMuted
          font.pixelSize: calendarWidget.fs(metrics.fontSmall)
          font.family: Theme.fonts.ui
        }
      }
    }
  }

  footerContent: Component {
    RowLayout {
      spacing: metrics.spacingNormal
      Text {
        Layout.fillWidth: true
        text: calendarWidget.state_ === "offline" ? (calendarWidget.reason || "calro not running")
            : calendarWidget.showAgenda ? (calendarWidget.compact ? "today" : "today · click for next")
            : calendarWidget.today.length + (calendarWidget.compact ? " today" : " today · click for agenda")
        color: Theme.colors.textSecondary
        font.pixelSize: calendarWidget.fs(metrics.fontTiny)
        font.family: Theme.fonts.ui
        elide: Text.ElideRight
      }
      Text {
        visible: calendarWidget.stale || calendarWidget.fixture !== ""
        text: calendarWidget.fixture !== "" ? "sample" : "stale"
        color: Theme.colors.warning
        font.pixelSize: calendarWidget.fs(metrics.fontTiny)
        font.family: Theme.fonts.ui
      }
    }
  }
}
