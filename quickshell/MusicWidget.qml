import QtQuick
import Quickshell
import Quickshell.Io
import "templates"
import "themes"

Item {
  id: musicWidget
  
  property bool showWidget: bar.state === "normal" || bar.state === "dashboard"
  property bool isDashboard: bar.state === "dashboard"
  // Vertical bar is too thin for the scrolling text; show an icon only there.
  property bool isVertical: false

  visible: showWidget
  implicitWidth: isVertical ? parent.width : (isDashboard ? metrics.s(600) : metrics.s(400))
  implicitHeight: metrics.s(30)
  
  Behavior on implicitWidth {
    NumberAnimation {
      duration: 100
      easing.type: Easing.OutQuint
    }
  }
  
  function resetMusicState() {
    activePlayer = ""
    playbackStatus = ""
    musicText = ""
    hasMusic = false
  }
  
  property string musicFieldSeparator: "<QSMUSIC>"
  
  function updateMusicState(line) {
    let parts = line.split(musicFieldSeparator)
    if (parts.length < 4) {
      resetMusicState()
      return
    }
    
    let player = parts[0].trim()
    let status = parts[1].trim()
    let artist = parts[2].trim()
    let title = parts.slice(3).join(musicFieldSeparator).trim()
    let textParts = []
    
    if (artist) textParts.push(artist)
    if (title) textParts.push(title)
    
    activePlayer = player
    playbackStatus = status
    musicText = textParts.length > 0 ? textParts.join(" // ") : player
    hasMusic = player.length > 0 && (status === "Playing" || status === "Paused")
  }
  
  // Music listener
  Process {
    id: musicProc
    command: ["playerctl", "--follow", "metadata", "--player=spotifyd,%any", "--format", "{{playerName}}<QSMUSIC>{{status}}<QSMUSIC>{{xesam:artist}}<QSMUSIC>{{xesam:title}}"]
    running: true
    
    stdout: SplitParser {
      onRead: data => {
        let lines = data.split('\n').filter(l => l.trim())
        if (lines.length > 0) {
          musicWidget.updateMusicState(lines[lines.length - 1].trim())
        }
      }
    }
    
    onRunningChanged: {
      if (!running) {
        musicWidget.resetMusicState()
      }
    }
    
    onExited: (code, status) => {
      // Restart after delay when playerctl exits
      musicRestartTimer.start()
    }
  }
  
  Timer {
    id: musicRestartTimer
    interval: 3000
    repeat: false
    onTriggered: musicProc.running = true
  }
  
  Process {
    id: togglePlaybackProc
    command: ["playerctl", "--player=" + (musicWidget.activePlayer || "spotifyd,%any"), "play-pause"]
  }
  
  // Launch data poller - uses Launch Library 2 API
  // Filter for Go/TBD/TBC status only (excludes completed launches)
  PollProcess {
    id: launchProc
    command: ["curl", "-s", "https://ll.thespacedevs.com/2.2.0/launch/upcoming/?limit=5&mode=list"]
    interval: 600000 // 10 minutes
    onOutput: text => {
      try {
        let data = JSON.parse(text)
        if (data.results && data.results.length > 0) {
          // Find first launch that hasn't happened yet
          let now = new Date()
          let launch = data.results.find(l => {
            let net = new Date(l.net)
            // Must be in future AND not already successful/failed
            let status = l.status?.id
            return net > now && (status === 1 || status === 2 || status === 5 || status === 8)
          })

          if (!launch) launch = data.results.find(l => new Date(l.net) > now)
          if (!launch) launch = data.results[0]

          musicWidget.launchName = launch.name || "Unknown"
          musicWidget.launchTime = launch.net ? new Date(launch.net) : null
        }
      } catch (e) {
        musicWidget.launchName = "Launch data unavailable"
        musicWidget.launchTime = null
      }
    }
  }
  
  // Countdown update timer
  Timer {
    interval: 1000
    running: musicWidget.launchTime !== null
    repeat: true
    onTriggered: musicWidget.updateCountdown()
  }
  
  property string musicText: ""
  property string activePlayer: ""
  property string playbackStatus: ""
  property bool hasMusic: false
  
  property string launchName: "Loading launch data..."
  property var launchTime: null
  property string countdownText: ""
  
  function updateCountdown() {
    if (!launchTime) {
      countdownText = ""
      return
    }
    
    let now = new Date()
    let diff = launchTime.getTime() - now.getTime()
    
    if (diff <= 0) {
      countdownText = "Launching now!"
      return
    }
    
    let days = Math.floor(diff / (1000 * 60 * 60 * 24))
    let hours = Math.floor((diff % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60))
    let mins = Math.floor((diff % (1000 * 60 * 60)) / (1000 * 60))
    let secs = Math.floor((diff % (1000 * 60)) / 1000)
    
    if (days > 0) {
      countdownText = "T-" + days + "d " + hours + "h " + mins + "m"
    } else if (hours > 0) {
      countdownText = "T-" + hours + "h " + mins + "m " + secs + "s"
    } else {
      countdownText = "T-" + mins + "m " + secs + "s"
    }
  }
  
  Rectangle {
    anchors.fill: parent
    color: "transparent"
    
    MouseArea {
      id: musicMouse
      anchors.fill: parent
      enabled: musicWidget.hasMusic
      hoverEnabled: musicWidget.hasMusic
      acceptedButtons: Qt.LeftButton
      cursorShape: musicWidget.hasMusic ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: togglePlaybackProc.running = true
    }
    
    Text {
      anchors.centerIn: parent
      text: {
        if (musicWidget.hasMusic && musicWidget.musicText) {
          let icon = musicWidget.playbackStatus === "Paused" ? "▶ " : "⏸ "
          return musicWidget.isVertical ? icon.trim() : (icon + musicWidget.musicText)
        } else if (musicWidget.isDashboard && musicWidget.launchName) {
          if (musicWidget.isVertical) return "🚀"
          let display = "🚀 " + musicWidget.countdownText
          let name = musicWidget.launchName
          if (name.length > 40) name = name.substring(0, 37) + "..."
          return display + " • " + name
        }
        return musicWidget.isVertical ? "" : "..."
      }
      color: musicWidget.hasMusic ? (musicMouse.containsMouse ? Theme.colors.yellow : Theme.colors.pink) : Theme.colors.orange
      font.pixelSize: metrics.fontSmall
      font.bold: false
      elide: Text.ElideRight
      width: parent.width - (musicWidget.isVertical ? metrics.s(4) : metrics.s(20))
      horizontalAlignment: Text.AlignHCenter
    }
  }
  
  Component.onCompleted: updateCountdown()
}
