import QtQuick
import Qt.labs.folderlistmodel
import "themes"

// In-panel file browser for the Q chat (paperclip button). It lives inside the panel rather than opening a
// separate dialog: the panel holds keyboard focus exclusively and sits on the top layer, so a normal window
// would open behind it and never get typed into.
//   click a folder: open it    click a file: attach it and close    shift+click: attach and stay open
//   type: filter this folder    Backspace on an empty filter: up a level    Esc: close
Rectangle {
  id: picker

  signal picked(string path)
  signal closed()

  property string folderPath: root.home
  function open(path) {
    folderPath = path || folderPath
    filter.text = ""
    visible = true
    filter.forceActiveFocus()
  }
  function close() { visible = false; closed() }
  function up() {
    if (folderPath === "/") return
    let p = folderPath.replace(/\/[^\/]*$/, "")
    folderPath = p === "" ? "/" : p
    filter.text = ""
  }
  function enter(path) { folderPath = path; filter.text = ""; list.positionViewAtBeginning() }
  function prettyPath(p) { return p.startsWith(root.home) ? "~" + p.slice(root.home.length) : p }
  function sizeText(b) {
    if (b < 1024) return b + " B"
    if (b < 1048576) return (b / 1024).toFixed(0) + " KB"
    if (b < 1073741824) return (b / 1048576).toFixed(1) + " MB"
    return (b / 1073741824).toFixed(1) + " GB"
  }

  // palette: Theme by default, the chat drawer passes its own
  property color insetColor: Theme.colors.inset
  property color accentColor: Theme.colors.violet
  property color onAccentColor: Theme.colors.background
  property color textColor: Theme.colors.textPrimary
  property color subTextColor: Theme.colors.textSecondary
  property color mutedColor: Theme.colors.textMuted

  visible: false
  radius: metrics.radiusLarge
  color: Theme.colors.panelDeep
  border.width: 1
  border.color: Theme.colors.border

  // swallow clicks so nothing underneath reacts
  MouseArea { anchors.fill: parent }

  FolderListModel {
    id: folder
    folder: "file://" + picker.folderPath
    showDirsFirst: true
    showDotAndDotDot: false
    showHidden: false
    sortField: FolderListModel.Time          // newest first: the file you just saved is at the top
    caseSensitive: false
    nameFilters: filter.text ? ["*" + filter.text + "*"] : []
  }

  // ---- top row: up, path, close
  Item {
    id: top
    x: metrics.spacingNormal; y: metrics.spacingNormal
    width: parent.width - metrics.spacingNormal * 2
    height: metrics.s(30)

    Rectangle {
      id: upBtn
      width: parent.height; height: parent.height
      radius: metrics.radiusNormal
      color: picker.insetColor
      opacity: picker.folderPath === "/" ? 0.4 : 1
      Text { anchors.centerIn: parent; text: "󰁝"; color: Theme.colors.blue; font.pixelSize: metrics.fontNormal; font.family: "monospace" }
      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: picker.up() }
    }
    Text {
      anchors.left: upBtn.right; anchors.leftMargin: metrics.spacingNormal
      anchors.right: closeBtn.left; anchors.rightMargin: metrics.spacingNormal
      anchors.verticalCenter: parent.verticalCenter
      text: picker.prettyPath(picker.folderPath)
      elide: Text.ElideLeft
      color: picker.textColor
      font.pixelSize: metrics.fontNormal
      font.family: "monospace"
    }
    Rectangle {
      id: closeBtn
      anchors.right: parent.right
      width: parent.height; height: parent.height
      radius: metrics.radiusNormal
      color: picker.insetColor
      Text { anchors.centerIn: parent; text: "󰅖"; color: Theme.colors.red; font.pixelSize: metrics.fontNormal; font.family: "monospace" }
      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: picker.close() }
    }
  }

  // ---- places
  Flow {
    id: places
    x: top.x; y: top.y + top.height + metrics.spacingSmall
    width: top.width
    spacing: metrics.spacingSmall
    Repeater {
      model: [["󰋜", "Home", ""], ["󰉍", "Downloads", "/Downloads"], ["󰔁", "Telegram", "/Downloads/Telegram Desktop"],
              ["󰉏", "Pictures", "/Pictures"], ["󰲋", "Projects", "/projects"], ["󰑴", "Classes", "/classes"],
              ["󰈙", "Documents", "/Documents"]]
      Rectangle {
        required property var modelData
        readonly property string path: root.home + modelData[2]
        readonly property bool here: picker.folderPath === path
        width: chipText.implicitWidth + metrics.s(16); height: metrics.s(24)
        radius: height / 2
        color: here ? picker.accentColor : picker.insetColor
        Text {
          id: chipText
          anchors.centerIn: parent
          text: parent.modelData[0] + " " + parent.modelData[1]
          color: parent.here ? picker.onAccentColor : picker.subTextColor
          font.pixelSize: metrics.fontSmall
          font.family: "monospace"
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: picker.enter(parent.path) }
      }
    }
  }

  // ---- filter
  Rectangle {
    id: filterBox
    x: top.x; y: places.y + places.height + metrics.spacingSmall
    width: top.width; height: metrics.s(30)
    radius: metrics.radiusNormal
    color: picker.insetColor
    Text {
      x: metrics.s(10); anchors.verticalCenter: parent.verticalCenter
      visible: !filter.text
      text: "Type to filter…"
      color: picker.mutedColor
      font.pixelSize: metrics.fontNormal; font.family: "monospace"
    }
    TextInput {
      id: filter
      x: metrics.s(10); width: parent.width - metrics.s(20)
      anchors.verticalCenter: parent.verticalCenter
      color: picker.textColor
      font.pixelSize: metrics.fontNormal; font.family: "monospace"
      clip: true
      Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) { picker.close(); event.accepted = true }
        else if (event.key === Qt.Key_Backspace && filter.text === "") { picker.up(); event.accepted = true }
        else if (event.key === Qt.Key_Down) { list.incrementCurrentIndex(); event.accepted = true }
        else if (event.key === Qt.Key_Up) { list.decrementCurrentIndex(); event.accepted = true }
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          if (list.currentIndex >= 0 && list.currentIndex < folder.count) list.activate(list.currentIndex, event.modifiers & Qt.ShiftModifier)
          event.accepted = true
        }
      }
    }
  }

  // ---- listing
  ListView {
    id: list
    x: top.x; y: filterBox.y + filterBox.height + metrics.spacingSmall
    width: top.width
    height: parent.height - y - metrics.spacingNormal
    clip: true
    model: folder
    currentIndex: 0
    boundsBehavior: Flickable.StopAtBounds
    highlightMoveDuration: 0
    function activate(i, stay) {
      let p = folder.get(i, "filePath")
      if (folder.get(i, "fileIsDir")) { picker.enter(p); return }
      picker.picked(p)
      if (!stay) picker.close()
    }

    delegate: Rectangle {
      required property int index
      required property string fileName
      required property string filePath
      required property bool fileIsDir
      required property var fileSize
      required property var fileModified
      readonly property bool isImage: /\.(png|jpe?g|webp|gif|bmp|svg)$/i.test(fileName)
      width: list.width; height: metrics.s(30)
      radius: metrics.radiusSmall
      color: ListView.isCurrentItem || hover.containsMouse ? picker.insetColor : "transparent"
      Text {
        id: icon
        x: metrics.s(8); anchors.verticalCenter: parent.verticalCenter
        text: parent.fileIsDir ? "󰉋" : parent.isImage ? "󰋩" : /\.pdf$/i.test(parent.fileName) ? "󰈦" : "󰈔"
        color: parent.fileIsDir ? Theme.colors.yellow : parent.isImage ? Theme.colors.teal : Theme.colors.lavender
        font.pixelSize: metrics.fontNormal; font.family: "monospace"
      }
      Text {
        anchors.left: icon.right; anchors.leftMargin: metrics.s(8)
        anchors.right: meta.left; anchors.rightMargin: metrics.s(8)
        anchors.verticalCenter: parent.verticalCenter
        text: parent.fileName
        elide: Text.ElideMiddle
        color: picker.textColor
        font.pixelSize: metrics.fontNormal; font.family: "monospace"
      }
      Text {
        id: meta
        anchors.right: parent.right; anchors.rightMargin: metrics.s(8)
        anchors.verticalCenter: parent.verticalCenter
        text: (parent.fileIsDir ? "" : picker.sizeText(parent.fileSize) + "  ") + Qt.formatDate(parent.fileModified, "MMM d")
        color: picker.mutedColor
        font.pixelSize: metrics.fontSmall; font.family: "monospace"
      }
      MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: mouse => list.activate(parent.index, mouse.modifiers & Qt.ShiftModifier)
      }
    }

    Text {
      anchors.centerIn: parent
      visible: folder.count === 0 && folder.status === FolderListModel.Ready
      text: filter.text ? "Nothing matches" : "Empty folder"
      color: picker.mutedColor
      font.pixelSize: metrics.fontNormal; font.family: "monospace"
    }
  }
}
