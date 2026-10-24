// Shared runner for PollProcess (templates/PollProcess.qml). Every PollProcess
// with the same command (and shared: true, the default) is served by one
// process and one timer here instead of running its own copy, so the second
// monitor's bar no longer doubles every poll (systempoll, tailscale, tessie,
// bluetooth, network, pgrep wf-recorder, ...). Output is handed to every
// subscriber, so each widget keeps its own state and handlers unchanged.
//
// Rules, kept the same as a private PollProcess as far as a widget can tell:
//   - a new subscriber gets the last output at once (if there is one), the
//     same as its own first run would have given it a moment later;
//   - the timer runs at the shortest interval any subscriber asks for, and
//     only while at least one subscriber has `poll` set;
//   - `running = true` on any subscriber reruns the command now;
//   - the runner goes away with its last subscriber.
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
  id: hub

  // key (JSON of the command) -> runner object
  property var runners: ({})

  function keyOf(sub) { return JSON.stringify(sub.command) }

  function subscribe(sub) {
    let key = keyOf(sub)
    let r = runners[key]
    if (!r) {
      r = runnerComp.createObject(hub, { key: key, command: sub.command })
      runners[key] = r
    }
    if (r.subs.indexOf(sub) < 0) r.subs.push(sub)
    sub.hubKey = key
    r.recompute()
    if (r.last !== null) {
      // after the subscriber's own creation has finished, like an async result
      Qt.callLater(() => { if (r.subs.indexOf(sub) >= 0) sub.output(r.last) })
    } else if (!r.proc.running) {
      r.proc.running = true
    }
  }

  function unsubscribe(sub) {
    let r = runners[sub.hubKey]
    sub.hubKey = ""
    if (!r) return
    let i = r.subs.indexOf(sub)
    if (i >= 0) r.subs.splice(i, 1)
    if (r.subs.length === 0) {
      delete runners[r.key]
      r.timer.running = false
      r.destroy()
    } else {
      r.recompute()
    }
  }

  // interval / poll changed on a subscriber
  function update(sub) {
    let r = runners[sub.hubKey]
    if (r) r.recompute()
  }

  // command changed on a subscriber: move it to the runner for the new command
  function resubscribe(sub) {
    if (sub.hubKey === "" || sub.hubKey === keyOf(sub)) return
    unsubscribe(sub)
    subscribe(sub)
  }

  // run the command now for everyone sharing it
  function run(sub) {
    let r = runners[sub.hubKey]
    if (r) r.proc.running = true
  }

  Component {
    id: runnerComp
    QtObject {
      id: runner
      property string key: ""
      property var command: []
      property var subs: []
      property var last: null

      function recompute() {
        let iv = -1, poll = false
        for (let s of subs) {
          if (iv < 0 || s.interval < iv) iv = s.interval
          if (s.poll) poll = true
        }
        timer.interval = iv > 0 ? iv : 3000
        timer.running = poll
      }

      function deliver(text) {
        last = text
        for (let s of subs.slice()) s.output(text)
      }

      property Process proc: Process {
        command: runner.command
        running: false
        stdout: StdioCollector {
          onStreamFinished: runner.deliver(this.text.trim())
        }
      }

      property Timer timer: Timer {
        interval: 3000
        running: false
        repeat: true
        onTriggered: runner.proc.running = true
      }
    }
  }
}
