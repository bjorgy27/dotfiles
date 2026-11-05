import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"
import "themes"

// Month calendar, Outlook-style: Sunday-first grid of 5 or 6 weeks with event chips (all-day ones as bars),
// prev/next/today in the header, the clicked day's agenda in a side panel, the next event in the footer.
// Data: scripts/polls/calendarpoll.sh (Google Calendar via gog, read-only), polled once a minute for the
// visible grid (--from/--to) and refetched on navigation; the next-event line uses its default 7-day mode.
// When the source fails the card says "calendar offline" with the reason and keeps polling quietly.
// Mouse wheel over the grid changes month. Preset options: "fixture": true (or a file path) shows sample
// events instead, for testing.
ThreeRowWidget {
  id: cal

  title: "󰃭  Calendar"
  refWidth: 1100   // the Agenda tab of the tabbed preset gives it the whole page
  refHeight: 640
  middleFills: true

  readonly property string fixture: options.fixture === true ? "default" : (typeof options.fixture === "string" ? options.fixture : "")
  readonly property string script: root.home + "/.config/scripts/polls/calendarpoll.sh"
  readonly property var fixtureArgs: fixture === "" ? [] : fixture === "default" ? ["--fixture"] : ["--fixture", fixture]

  property string state_: "loading"   // loading | ok | offline
  property string reason: ""
  property bool stale: false
  property var events: []             // the visible grid
  property var soon: []               // next 7 days, for the next-event line
  property real now: Date.now()

  // The month on show and the day whose agenda is open
  property int viewYear: new Date().getFullYear()
  property int viewMonth: new Date().getMonth()
  property real selected: dayStart

  Timer { interval: 20000; running: cal.visible; repeat: true; triggeredOnStart: true; onTriggered: cal.now = Date.now() }

  readonly property real dayStart: { let d = new Date(now); d.setHours(0, 0, 0, 0); return d.getTime() }
  readonly property real dayEnd: addDays(dayStart, 1)

  // Grid: the Sunday on or before the 1st through the Saturday on or after the last day
  readonly property date firstOfMonth: new Date(viewYear, viewMonth, 1)
  readonly property int lead: firstOfMonth.getDay()
  readonly property int monthDays: new Date(viewYear, viewMonth + 1, 0).getDate()
  readonly property int weeks: Math.ceil((lead + monthDays) / 7)
  readonly property real gridStart: new Date(viewYear, viewMonth, 1 - lead).getTime()
  readonly property real gridEnd: addDays(gridStart, weeks * 7)
  readonly property var rangeArgs: ["--from", ymd(gridStart), "--to", ymd(addDays(gridEnd, -1))]

  function addDays(ms, n) { let d = new Date(ms); d.setDate(d.getDate() + n); return d.getTime() }
  function ymd(ms) { return Qt.formatDate(new Date(ms), "yyyy-MM-dd") }
  // Date-only strings are local days, not UTC midnight
  function parseWhen(s) {
    if (typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s)) { let p = s.split("-"); return new Date(+p[0], +p[1] - 1, +p[2]).getTime() }
    return new Date(s).getTime()
  }
  function prep(list) {
    return (list || []).map(e => Object.assign({}, e, { s: parseWhen(e.start), e: parseWhen(e.end) }))
      .sort((a, b) => (b.all_day - a.all_day) || (a.s - b.s))
  }
  function apply(text, grid) {
    let d
    try { d = JSON.parse(text) } catch (err) { d = { state: "offline", reason: "no data" } }
    if (grid) {
      state_ = d.state === "ok" ? "ok" : "offline"
      reason = d.reason || ""
      stale = !!d.stale
      events = prep(d.events)
    } else if (d.state === "ok") soon = prep(d.events)
  }
  function shiftMonth(n) {
    let d = new Date(viewYear, viewMonth + n, 1)
    viewYear = d.getFullYear(); viewMonth = d.getMonth()
  }
  function goToday() {
    let d = new Date(now)
    viewYear = d.getFullYear(); viewMonth = d.getMonth(); selected = dayStart
  }

  // Visible grid: once a minute, and again whenever the month changes
  // A fetch already running when the month changes is for the old range: drop its result and run again
  // once that process has exited (its output arrives while it still counts as running).
  property bool refetch: false
  PollProcess {
    id: gridPoll
    command: ["bash", cal.script].concat(cal.fixture === "" ? cal.rangeArgs : cal.fixtureArgs)
    interval: 60000
    poll: cal.visible
    onOutput: text => {
      if (cal.refetch) relaunch.restart()
      else cal.apply(text, true)
    }
  }
  Timer {
    id: relaunch
    interval: 150
    onTriggered: {
      if (gridPoll.running) { restart(); return }
      cal.refetch = false
      gridPoll.running = true
    }
  }
  onRangeArgsChanged: { refetch = true; relaunch.restart() }

  // Next event, whichever month is on show
  PollProcess {
    command: ["bash", cal.script].concat(cal.fixtureArgs)
    interval: 300000
    onOutput: text => cal.apply(text, false)
  }

  // Day start (ms) -> events touching that day, built once per refresh
  readonly property var dayMap: {
    let m = {}
    for (let i = 0; i < weeks * 7; i++) {
      let a = addDays(gridStart, i), b = addDays(gridStart, i + 1)
      m[a] = events.filter(e => e.s < b && (e.e > a || (e.e === e.s && e.s >= a)))
    }
    return m
  }
  readonly property var selectedEvents: dayMap[selected] || []
  readonly property var upcoming: soon.filter(e => !e.all_day && !e.skip && e.e > now)
  readonly property var nextEvent: upcoming.length > 0 ? upcoming[0] : null
  readonly property int todayCount: soon.filter(e => e.s < dayEnd && e.e > dayStart && !e.skip).length

  function hhmm(ms) { return Qt.formatTime(new Date(ms), "HH:mm") }
  function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;") }
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
  // One hue per calendar; holidays always teal
  function hue(e) {
    let c = e.calendar || ""
    if (/holiday/i.test(c)) return Theme.colors.teal
    let p = [Theme.colors.violet, Theme.colors.blue, Theme.colors.pink, Theme.colors.orange, Theme.colors.cyan, Theme.colors.yellow]
    let h = 0
    for (let i = 0; i < c.length; i++) h = (h * 31 + c.charCodeAt(i)) % 997
    return p[h % p.length]
  }

  readonly property real chipH: fs(metrics.fontTiny) + metrics.s(6)

  middleContent: Component {
    RowLayout {
      spacing: metrics.spacingLarge

      // === the month ===
      ColumnLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: metrics.spacingSmall

        // Header: ‹ › Month Year ... Today
        RowLayout {
          Layout.fillWidth: true
          spacing: metrics.spacingSmall
          Repeater {
            model: [{ t: "‹", n: -1 }, { t: "›", n: 1 }]
            delegate: Rectangle {
              required property var modelData
              implicitWidth: cal.fs(metrics.s(30)); implicitHeight: implicitWidth
              radius: metrics.radiusSmall
              color: navMa.containsMouse ? Theme.colors.inset : "transparent"
              border.width: 1; border.color: Theme.colors.border
              Text {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: -metrics.s(1)
                text: modelData.t
                color: Theme.colors.accent
                font.pixelSize: cal.fs(metrics.fontLarge * 1.3)
                font.family: Theme.fonts.ui
              }
              MouseArea { id: navMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: cal.shiftMonth(modelData.n) }
            }
          }
          Text {
            Layout.leftMargin: metrics.spacingSmall
            text: Qt.formatDate(cal.firstOfMonth, "MMMM")
            color: Theme.colors.textPrimary
            font.pixelSize: cal.fs(metrics.s(22))
            font.bold: true
            font.family: Theme.fonts.ui
          }
          Text {
            text: cal.viewYear
            color: Theme.colors.textSecondary
            font.pixelSize: cal.fs(metrics.s(22))
            font.family: Theme.fonts.ui
          }
          Item { Layout.fillWidth: true }
          Text {
            visible: cal.state_ !== "ok"
            text: cal.state_ === "loading" ? "loading…" : "calendar offline"
            color: cal.state_ === "loading" ? Theme.colors.textMuted : Theme.colors.warning
            font.pixelSize: cal.fs(metrics.fontSmall)
            font.family: Theme.fonts.ui
          }
          Rectangle {
            readonly property bool here: cal.viewYear === new Date(cal.now).getFullYear() && cal.viewMonth === new Date(cal.now).getMonth() && cal.selected === cal.dayStart
            implicitWidth: todayTxt.implicitWidth + 2 * metrics.spacingNormal
            implicitHeight: cal.fs(metrics.s(30))
            radius: metrics.radiusSmall
            color: todayMa.containsMouse ? Theme.colors.inset : "transparent"
            border.width: 1; border.color: here ? Theme.colors.border : Theme.colors.accent
            opacity: here ? 0.55 : 1
            Text {
              id: todayTxt
              anchors.centerIn: parent
              text: "Today"
              color: Theme.colors.accent
              font.pixelSize: cal.fs(metrics.fontSmall)
              font.family: Theme.fonts.ui
            }
            MouseArea { id: todayMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: cal.goToday() }
          }
        }

        // Weekday names
        RowLayout {
          Layout.fillWidth: true
          spacing: 0
          Repeater {
            model: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            delegate: Text {
              required property string modelData
              Layout.fillWidth: true
              Layout.preferredWidth: 1
              leftPadding: metrics.spacingSmall
              text: modelData.toUpperCase()
              color: Theme.colors.label
              font.pixelSize: cal.fs(metrics.fontTiny)
              font.letterSpacing: metrics.s(1)
              font.family: Theme.fonts.mono
            }
          }
        }

        // Day cells
        Item {
          id: grid
          Layout.fillWidth: true
          Layout.fillHeight: true
          readonly property real cw: width / 7
          readonly property real ch: height / cal.weeks

          WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: ev => cal.shiftMonth(ev.angleDelta.y > 0 ? -1 : 1)
          }

          Rectangle {   // frame
            anchors.fill: parent
            color: "transparent"
            radius: metrics.radiusSmall
            border.width: 1; border.color: Theme.colors.border
          }

          Repeater {
            model: cal.weeks * 7
            delegate: Item {
              id: cell
              required property int index
              readonly property real day: cal.addDays(cal.gridStart, index)
              readonly property date d: new Date(day)
              readonly property bool inMonth: d.getMonth() === cal.viewMonth
              readonly property bool isToday: day === cal.dayStart
              readonly property bool isSel: day === cal.selected
              readonly property bool weekend: d.getDay() === 0 || d.getDay() === 6
              readonly property var evs: cal.dayMap[day] || []
              readonly property int fit: Math.max(0, Math.floor((height - numRow.height - metrics.s(10)) / (cal.chipH + metrics.s(2))))
              readonly property int shown: evs.length > fit ? Math.max(0, fit - 1) : evs.length
              x: (index % 7) * grid.cw
              y: Math.floor(index / 7) * grid.ch
              width: grid.cw
              height: grid.ch

              Rectangle {   // fill: selected, hover, weekend
                anchors { fill: parent; margins: 1 }
                radius: metrics.radiusSmall
                color: cell.isSel ? Theme.colors.inset
                     : cellMa.containsMouse ? Qt.rgba(1, 1, 1, 0.04)
                     : cell.weekend ? Qt.rgba(0, 0, 0, 0.18) : "transparent"
                border.width: cell.isSel ? 1 : 0
                border.color: Theme.colors.accent
              }
              Rectangle {
                visible: cell.index % 7 !== 6
                anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                width: 1; color: Theme.colors.border; opacity: 0.6
              }
              Rectangle {
                visible: cell.index < (cal.weeks - 1) * 7
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 1; color: Theme.colors.border; opacity: 0.6
              }

              Column {
                anchors { fill: parent; margins: metrics.s(4) }
                spacing: metrics.s(2)
                opacity: cell.inMonth ? 1 : 0.4

                Item {
                  id: numRow
                  width: parent.width
                  height: cal.fs(metrics.fontSmall) + metrics.s(8)
                  Rectangle {
                    visible: cell.isToday
                    width: Math.max(height, numTxt.implicitWidth + metrics.s(12)); height: parent.height
                    radius: height / 2
                    color: Theme.colors.accent
                  }
                  Text {
                    id: numTxt
                    x: cell.isToday ? (Math.max(parent.height, implicitWidth + metrics.s(12)) - implicitWidth) / 2 : metrics.s(3)
                    anchors.verticalCenter: parent.verticalCenter
                    text: cell.d.getDate() === 1 ? Qt.formatDate(cell.d, "MMM d") : cell.d.getDate()
                    color: cell.isToday ? Theme.colors.onAccent : cell.inMonth ? Theme.colors.textPrimary : Theme.colors.textMuted
                    font.pixelSize: cal.fs(metrics.fontSmall)
                    font.bold: cell.isToday || cell.d.getDate() === 1
                    font.family: Theme.fonts.ui
                  }
                }

                Repeater {
                  model: cell.evs.slice(0, cell.shown)
                  delegate: Item {
                    id: chip
                    required property var modelData
                    readonly property color c: cal.hue(modelData)
                    // all-day bars run edge to edge across the days they cover
                    readonly property bool contL: modelData.all_day && modelData.s < cell.day && cell.index % 7 !== 0
                    readonly property bool contR: modelData.all_day && modelData.e > cal.addDays(cell.day, 1) && cell.index % 7 !== 6
                    width: parent.width
                    height: cal.chipH
                    opacity: modelData.e <= cal.now && !modelData.all_day ? 0.5 : 1
                    Rectangle {
                      visible: chip.modelData.all_day
                      x: chip.contL ? -metrics.s(5) : 0
                      width: parent.width - x + (chip.contR ? metrics.s(5) : 0)
                      height: parent.height
                      radius: metrics.s(3)
                      color: Qt.rgba(chip.c.r, chip.c.g, chip.c.b, 0.26)
                      border.width: 1; border.color: Qt.rgba(chip.c.r, chip.c.g, chip.c.b, 0.55)
                    }
                    Rectangle {
                      visible: !chip.modelData.all_day
                      x: metrics.s(3); anchors.verticalCenter: parent.verticalCenter
                      width: metrics.s(6); height: width; radius: width / 2
                      color: chip.c
                    }
                    Text {
                      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: chip.modelData.all_day ? metrics.s(5) : metrics.s(12) }
                      text: (chip.modelData.all_day ? "" : "<font color='" + Theme.colors.blue + "'>" + cal.hhmm(chip.modelData.s) + "</font> ")
                            + cal.esc(chip.modelData.summary)
                      textFormat: Text.StyledText
                      color: chip.modelData.skip ? Theme.colors.textMuted : Theme.colors.textPrimary
                      font.strikeout: chip.modelData.skip
                      font.pixelSize: cal.fs(metrics.fontTiny)
                      font.family: Theme.fonts.ui
                      elide: Text.ElideRight
                    }
                  }
                }
                Text {
                  visible: cell.evs.length > cell.shown
                  leftPadding: metrics.s(4)
                  text: "+" + (cell.evs.length - cell.shown) + " more"
                  color: Theme.colors.accent
                  font.pixelSize: cal.fs(metrics.fontTiny)
                  font.family: Theme.fonts.ui
                }
              }

              MouseArea {
                id: cellMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  cal.selected = cell.day
                  if (!cell.inMonth) cal.shiftMonth(cell.d < cal.firstOfMonth ? -1 : 1)
                }
              }
            }
          }
        }
      }

      // === the selected day ===
      Rectangle {
        Layout.fillHeight: true
        Layout.preferredWidth: Math.max(metrics.s(220), Math.min(metrics.s(320), cal.width * 0.26))
        radius: metrics.radiusNormal
        color: Theme.colors.field
        border.width: 1; border.color: Theme.colors.border

        ColumnLayout {
          anchors { fill: parent; margins: metrics.spacingNormal }
          spacing: metrics.spacingSmall

          Text {
            Layout.fillWidth: true
            text: Qt.formatDate(new Date(cal.selected), "dddd")
                  + (cal.selected === cal.dayStart ? " · today" : cal.selected === cal.dayEnd ? " · tomorrow" : "")
            color: Theme.colors.heading
            font.pixelSize: cal.fs(metrics.fontSmall)
            font.letterSpacing: metrics.s(Theme.colors.headingSpacing)
            font.capitalization: Theme.colors.headingCaps ? Font.AllUppercase : Font.MixedCase
            font.family: "monospace"
            elide: Text.ElideRight
          }
          Text {
            Layout.fillWidth: true
            text: Qt.formatDate(new Date(cal.selected), "d MMMM yyyy")
            color: Theme.colors.textPrimary
            font.pixelSize: cal.fs(metrics.fontLarge)
            font.bold: true
            font.family: Theme.fonts.ui
            elide: Text.ElideRight
          }
          QRule { Layout.fillWidth: true; implicitHeight: bar.dividerThickness }

          ListView {
            id: dayList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: metrics.spacingNormal
            model: cal.selectedEvents
            delegate: RowLayout {
              required property var modelData
              width: ListView.view.width
              spacing: metrics.spacingSmall
              opacity: modelData.e <= cal.now ? 0.5 : 1
              Rectangle {
                Layout.fillHeight: true
                Layout.preferredWidth: metrics.s(3)
                radius: width / 2
                color: cal.hue(modelData)
              }
              ColumnLayout {
                Layout.fillWidth: true
                spacing: metrics.s(1)
                Text {
                  Layout.fillWidth: true
                  text: modelData.all_day ? "all day" : cal.hhmm(modelData.s) + "–" + cal.hhmm(modelData.e)
                  color: Theme.colors.blue
                  font.pixelSize: cal.fs(metrics.fontTiny)
                  font.family: Theme.fonts.mono
                }
                Text {
                  Layout.fillWidth: true
                  text: modelData.summary + (modelData.verified === false ? " ⚠" : "")
                  color: modelData.skip ? Theme.colors.textMuted : Theme.colors.textPrimary
                  font.strikeout: modelData.skip
                  font.pixelSize: cal.fs(metrics.fontSmall)
                  font.family: Theme.fonts.ui
                  wrapMode: Text.Wrap
                  maximumLineCount: 2
                  elide: Text.ElideRight
                }
                Text {
                  Layout.fillWidth: true
                  visible: text !== ""
                  text: [modelData.location, modelData.calendar].filter(x => x).join(" · ")
                  color: Theme.colors.textSecondary
                  font.pixelSize: cal.fs(metrics.fontTiny)
                  font.family: Theme.fonts.ui
                  elide: Text.ElideRight
                }
              }
            }
            Text {
              visible: dayList.count === 0
              width: dayList.width
              wrapMode: Text.Wrap
              text: cal.state_ === "ok" ? "Nothing on this day" : cal.state_ === "loading" ? "…" : "calendar offline"
              color: Theme.colors.textMuted
              font.pixelSize: cal.fs(metrics.fontSmall)
              font.family: Theme.fonts.ui
            }
          }
        }
      }
    }
  }

  footerContent: Component {
    RowLayout {
      spacing: metrics.spacingNormal
      Text {
        visible: cal.state_ !== "offline"
        text: "NEXT"
        color: Theme.colors.label
        font.pixelSize: cal.fs(metrics.fontTiny)
        font.letterSpacing: metrics.s(1)
        font.family: Theme.fonts.mono
      }
      Text {
        Layout.fillWidth: true
        textFormat: Text.StyledText
        text: cal.state_ === "offline" ? "calendar offline · " + cal.esc(cal.reason || "no source")
            : cal.state_ === "loading" ? "…"
            : cal.nextEvent ? cal.esc(cal.nextEvent.summary) + "  <font color='" + cal.whenColor(cal.nextEvent) + "'>" + cal.when(cal.nextEvent) + "</font>"
            : "Nothing coming up"
        color: cal.state_ === "offline" ? Theme.colors.warning : Theme.colors.textPrimary
        font.pixelSize: cal.fs(metrics.fontSmall)
        font.family: Theme.fonts.ui
        elide: Text.ElideRight
      }
      Text {
        visible: cal.state_ === "ok"
        text: cal.todayCount + " today"
        color: Theme.colors.textSecondary
        font.pixelSize: cal.fs(metrics.fontTiny)
        font.family: Theme.fonts.ui
      }
      Text {
        visible: cal.stale || cal.fixture !== ""
        text: cal.fixture !== "" ? "sample" : "stale"
        color: Theme.colors.warning
        font.pixelSize: cal.fs(metrics.fontTiny)
        font.family: Theme.fonts.ui
      }
    }
  }
}
