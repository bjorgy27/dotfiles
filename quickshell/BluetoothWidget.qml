import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"
import "themes"

// Bluetooth dropdown: power toggle + scan + device list w/ connect/pair.
Item {
    id: btWidget

    property string home: Quickshell.env("HOME")

    readonly property bool isOpen: bar.state === "bluetooth"
    visible: isOpen

    anchors {
        top: metrics.isVertical ? undefined : parent.top
        left: metrics.isVertical ? parent.left : undefined
        topMargin: metrics.isVertical ? 0 : bar.dropdownWidgetPadding
        leftMargin: metrics.isVertical ? bar.dropdownWidgetPadding : 0
        horizontalCenter: metrics.isVertical ? undefined : parent.horizontalCenter
        verticalCenter: metrics.isVertical ? parent.verticalCenter : undefined
    }

    width: parent.width - (bar.dropdownWidgetPadding * 2)
    height: parent.height - (bar.dropdownWidgetPadding * 2)

    // === STATE ===
    property bool powerEnabled: root.btPower === "on"
    property bool unavailable: root.btPower === "unavailable"
    property var devices: []   // [{mac, name, connected, paired, battery, icon}]
    property bool scanning: false
    property string statusMessage: ""
    property bool statusIsError: false

    onIsOpenChanged: {
        if (isOpen) {
            listProc.running = true
        } else {
            statusMessage = ""
            if (scanning) {
                scanning = false
                scanProc.running = false
            }
        }
    }

    Keys.onEscapePressed: bar.state = "normal"
    focus: visible

    function parseDevices(text) {
        if (!text) return []
        let out = []
        text.split('\n').forEach(line => {
            if (!line.startsWith("device|")) return
            let parts = line.split('|')
            if (parts.length < 7) return
            out.push({
                mac: parts[1],
                name: parts[2] || parts[1],
                connected: parts[3] === "1",
                paired: parts[4] === "1",
                battery: parts[5],
                icon: parts[6]
            })
        })
        // Connected first, then paired, then everything else, alphabetical within each.
        out.sort((a, b) => {
            if (a.connected !== b.connected) return a.connected ? -1 : 1
            if (a.paired !== b.paired) return a.paired ? -1 : 1
            return a.name.localeCompare(b.name)
        })
        return out
    }

    function deviceIcon(dev) {
        let ic = (dev.icon || "").toLowerCase()
        if (ic.includes("headset") || ic.includes("headphone")) return "󰋋"
        if (ic.includes("audio") || ic.includes("speaker")) return "󰓃"
        if (ic.includes("mouse")) return "󰍽"
        if (ic.includes("keyboard")) return "󰌌"
        if (ic.includes("phone")) return "󰄜"
        if (ic.includes("computer") || ic.includes("laptop")) return "󰟀"
        if (ic.includes("gaming") || ic.includes("joystick") || ic.includes("controller")) return "󰊴"
        if (ic.includes("printer")) return "󰐪"
        return dev.connected ? "󰂱" : "󰂯"
    }

    function showStatus(message, isError) {
        statusMessage = message
        statusIsError = isError
        statusTimer.restart()
    }

    Timer {
        id: statusTimer
        interval: 4000
        onTriggered: btWidget.statusMessage = ""
    }

    PollProcess {
        id: listProc
        command: ["bash", btWidget.home + "/.config/scripts/polls/bluetoothpoll.sh"]
        interval: 4000
        poll: btWidget.isOpen && btWidget.powerEnabled
        onOutput: text => btWidget.devices = btWidget.parseDevices(text)
    }

    Process {
        id: powerToggleProc
        running: false
        onExited: {
            root.forceBluetoothStatusRefresh()
            listProc.running = true
        }
    }

    function togglePower() {
        powerToggleProc.command = ["bluetoothctl", "power", btWidget.powerEnabled ? "off" : "on"]
        powerToggleProc.running = true
    }

    Process {
        id: scanProc
        running: false
        command: ["bluetoothctl", "--timeout", "8", "scan", "on"]
        onExited: {
            btWidget.scanning = false
            listProc.running = true
        }
    }

    function toggleScan() {
        if (btWidget.scanning) {
            scanProc.running = false
            btWidget.scanning = false
            return
        }
        btWidget.scanning = true
        scanProc.running = true
    }

    Process {
        id: connectProc
        running: false
        property string targetName: ""
        stderr: StdioCollector {
            onStreamFinished: {
                if (this.text.trim().length > 0) {
                    btWidget.showStatus("Couldn't connect to " + connectProc.targetName + ": " + this.text.trim(), true)
                } else {
                    btWidget.showStatus("Connected to " + connectProc.targetName, false)
                }
                listProc.running = true
                root.forceBluetoothStatusRefresh()
            }
        }
    }

    function connectTo(dev) {
        connectProc.targetName = dev.name
        connectProc.command = ["bluetoothctl", "connect", dev.mac]
        connectProc.running = true
    }

    Process {
        id: disconnectProc
        running: false
        onExited: {
            btWidget.showStatus("Disconnected", false)
            listProc.running = true
            root.forceBluetoothStatusRefresh()
        }
    }

    function disconnect(dev) {
        disconnectProc.command = ["bluetoothctl", "disconnect", dev.mac]
        disconnectProc.running = true
    }

    Process {
        id: pairProc
        running: false
        property string targetName: ""
        stderr: StdioCollector {
            onStreamFinished: {
                if (this.text.trim().length > 0) {
                    btWidget.showStatus("Couldn't pair " + pairProc.targetName + ": " + this.text.trim(), true)
                } else {
                    btWidget.showStatus("Paired " + pairProc.targetName, false)
                }
                listProc.running = true
                root.forceBluetoothStatusRefresh()
            }
        }
    }

    function pairAndConnect(dev) {
        pairProc.targetName = dev.name
        pairProc.command = ["bash", "-c", "bluetoothctl pair " + dev.mac + " && bluetoothctl trust " + dev.mac + " && bluetoothctl connect " + dev.mac]
        pairProc.running = true
    }

    function selectDevice(dev) {
        if (dev.connected) {
            disconnect(dev)
        } else if (dev.paired) {
            connectTo(dev)
        } else {
            pairAndConnect(dev)
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.colors.panel
        radius: metrics.radiusLarge

        ColumnLayout {
            anchors {
                fill: parent
                margins: metrics.marginBar
            }
            spacing: metrics.spacingSmall

            // Header: title + power toggle
            RowLayout {
                Layout.fillWidth: true
                spacing: metrics.spacingSmall

                Text {
                    text: "󰂯  Bluetooth"
                    color: Theme.colors.textPrimary
                    font.pixelSize: metrics.fontLarge
                    font.bold: true
                    font.family: "monospace"
                    Layout.fillWidth: true
                }

                // Scan button
                Rectangle {
                    visible: btWidget.powerEnabled
                    width: scanText.implicitWidth + metrics.spacingNormal * 2
                    height: metrics.s(22)
                    radius: metrics.radiusSmall
                    color: btWidget.scanning ? Theme.colors.blue : Theme.colors.inset
                    border.width: 1
                    border.color: Theme.colors.border

                    Text {
                        id: scanText
                        anchors.centerIn: parent
                        text: btWidget.scanning ? "Scanning…" : "Scan"
                        color: btWidget.scanning ? Theme.colors.panelDeep : Theme.colors.textSecondary
                        font.pixelSize: metrics.fontTiny
                        font.bold: true
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: btWidget.toggleScan()
                    }
                }

                // Power toggle pill
                Rectangle {
                    id: powerPill
                    enabled: !btWidget.unavailable
                    opacity: enabled ? 1 : 0.4
                    width: metrics.s(42)
                    height: metrics.s(22)
                    radius: height / 2
                    color: btWidget.powerEnabled ? Theme.colors.green : Theme.colors.inset
                    border.width: 1
                    border.color: Theme.colors.border

                    Rectangle {
                        width: parent.height - metrics.s(4)
                        height: width
                        radius: width / 2
                        color: Theme.colors.textPrimary
                        anchors.verticalCenter: parent.verticalCenter
                        x: btWidget.powerEnabled ? (parent.width - width - metrics.s(2)) : metrics.s(2)
                        Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: !btWidget.unavailable
                        cursorShape: Qt.PointingHandCursor
                        onClicked: btWidget.togglePower()
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                height: bar.dividerThickness
                color: Theme.colors.border
            }

            // Status message
            Text {
                visible: btWidget.statusMessage.length > 0
                text: btWidget.statusMessage
                color: btWidget.statusIsError ? Theme.colors.red : Theme.colors.green
                font.pixelSize: metrics.fontTiny
                font.bold: true
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
            }

            // Unavailable state
            Text {
                visible: btWidget.unavailable
                text: "bluez not installed — run: sudo pacman -S bluez bluez-utils"
                color: Theme.colors.red
                font.pixelSize: metrics.fontSmall
                Layout.fillWidth: true
                Layout.topMargin: metrics.spacingNormal
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            // Disabled state
            Text {
                visible: !btWidget.unavailable && !btWidget.powerEnabled
                text: "Bluetooth is turned off"
                color: Theme.colors.textMuted
                font.pixelSize: metrics.fontSmall
                Layout.fillWidth: true
                Layout.topMargin: metrics.spacingNormal
                horizontalAlignment: Text.AlignHCenter
            }

            // Device list
            Item {
                visible: btWidget.powerEnabled
                Layout.fillWidth: true
                Layout.fillHeight: true

            ListView {
                anchors.fill: parent
                clip: true
                spacing: metrics.spacingTiny
                model: btWidget.devices

                delegate: Rectangle {
                    id: delegateRoot
                    required property var modelData
                    width: ListView.view.width
                    height: metrics.s(38)
                    radius: metrics.radiusSmall
                    color: delegateRoot.modelData.connected ? Theme.colors.inset : "transparent"

                    RowLayout {
                        anchors {
                            fill: parent
                            leftMargin: metrics.spacingSmall
                            rightMargin: metrics.spacingSmall
                        }
                        spacing: metrics.spacingSmall

                        Text {
                            text: btWidget.deviceIcon(delegateRoot.modelData)
                            color: delegateRoot.modelData.connected ? Theme.colors.green : Theme.colors.textSecondary
                            font.pixelSize: metrics.fontNormal
                            font.family: "monospace"
                        }

                        Text {
                            text: delegateRoot.modelData.name
                            color: Theme.colors.textPrimary
                            font.pixelSize: metrics.fontSmall
                            font.bold: delegateRoot.modelData.connected
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }

                        Text {
                            visible: delegateRoot.modelData.connected && delegateRoot.modelData.battery !== "NA"
                            text: delegateRoot.modelData.battery + "%"
                            color: Theme.colors.textMuted
                            font.pixelSize: metrics.fontTiny
                        }

                        Text {
                            visible: !delegateRoot.modelData.connected && delegateRoot.modelData.paired
                            text: "Paired"
                            color: Theme.colors.textMuted
                            font.pixelSize: metrics.fontTiny
                        }

                        Text {
                            visible: delegateRoot.modelData.connected
                            text: "Connected"
                            color: Theme.colors.green
                            font.pixelSize: metrics.fontTiny
                            font.bold: true
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: btWidget.selectDevice(delegateRoot.modelData)
                    }
                }
            }

            // Empty state, centered over the (empty) list
            Text {
                anchors.centerIn: parent
                visible: btWidget.devices.length === 0
                text: btWidget.scanning ? "Scanning for devices…" : "No devices found — tap Scan"
                color: Theme.colors.textMuted
                font.pixelSize: metrics.fontSmall
                horizontalAlignment: Text.AlignHCenter
            }
            } // Item (list container)
        }
    }
}
