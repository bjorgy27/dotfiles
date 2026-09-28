import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"
import "themes"

// Network Manager dropdown: Wi-Fi radio toggle + scan list + connect/disconnect.
Item {
    id: networkWidget

    property string home: Quickshell.env("HOME")

    readonly property bool isOpen: bar.state === "network"
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
    property bool radioEnabled: root.netRadioEnabled
    property var networks: []       // [{active, ssid, signal, secured, saved}]
    property string expandedSsid: ""   // ssid currently showing a password prompt
    property string statusMessage: ""
    property bool statusIsError: false

    onIsOpenChanged: {
        if (isOpen) {
            listProc.running = true
        } else {
            expandedSsid = ""
            passwordField.text = ""
            statusMessage = ""
        }
    }

    Keys.onEscapePressed: bar.state = "normal"
    focus: visible

    function parseNetworks(text) {
        if (!text) return []
        return text.split('\n').filter(l => l.length > 0).map(line => {
            let parts = line.split('|')
            return {
                active: parts[0] === "1",
                ssid: parts[1] ?? "",
                signal: parseInt(parts[2] ?? "0"),
                secured: parts[3] === "1",
                saved: parts[4] === "1"
            }
        })
    }

    function signalIcon(signal) {
        if (signal >= 80) return "󰤨"
        if (signal >= 55) return "󰤥"
        if (signal >= 30) return "󰤢"
        if (signal > 0) return "󰤟"
        return "󰤯"
    }

    function showStatus(message, isError) {
        statusMessage = message
        statusIsError = isError
        statusTimer.restart()
    }

    Timer {
        id: statusTimer
        interval: 4000
        onTriggered: networkWidget.statusMessage = ""
    }

    PollProcess {
        id: listProc
        command: ["bash", networkWidget.home + "/.config/scripts/polls/networklistpoll.sh"]
        interval: 4000
        poll: networkWidget.isOpen && networkWidget.radioEnabled
        onOutput: text => networkWidget.networks = networkWidget.parseNetworks(text)
    }

    Process {
        id: radioToggleProc
        running: false
        onExited: root.forceNetworkStatusRefresh()
    }

    function toggleRadio() {
        radioToggleProc.command = ["nmcli", "radio", "wifi", networkWidget.radioEnabled ? "off" : "on"]
        radioToggleProc.running = true
    }

    Process {
        id: connectProc
        running: false
        property string targetSsid: ""
        stderr: StdioCollector {
            onStreamFinished: {
                if (this.text.trim().length > 0) {
                    networkWidget.showStatus("Couldn't connect to " + connectProc.targetSsid + ": " + this.text.trim(), true)
                } else {
                    networkWidget.showStatus("Connected to " + connectProc.targetSsid, false)
                    networkWidget.expandedSsid = ""
                    passwordField.text = ""
                }
                listProc.running = true
                root.forceNetworkStatusRefresh()
            }
        }
    }

    function connectTo(ssid, password) {
        connectProc.targetSsid = ssid
        if (password && password.length > 0) {
            connectProc.command = ["nmcli", "device", "wifi", "connect", ssid, "password", password]
        } else {
            connectProc.command = ["nmcli", "device", "wifi", "connect", ssid]
        }
        connectProc.running = true
    }

    Process {
        id: disconnectProc
        running: false
        onExited: {
            networkWidget.showStatus("Disconnected", false)
            listProc.running = true
            root.forceNetworkStatusRefresh()
        }
    }

    function disconnect() {
        if (root.netDevice) {
            disconnectProc.command = ["nmcli", "device", "disconnect", root.netDevice]
            disconnectProc.running = true
        }
    }

    function selectNetwork(net) {
        if (net.active) {
            disconnect()
            return
        }
        if (net.secured && !net.saved) {
            expandedSsid = (expandedSsid === net.ssid) ? "" : net.ssid
            passwordField.text = ""
        } else {
            connectTo(net.ssid, "")
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

            // Header: title + radio toggle
            RowLayout {
                Layout.fillWidth: true
                spacing: metrics.spacingSmall

                Text {
                    text: "󰖩  Wi-Fi"
                    color: Theme.colors.textPrimary
                    font.pixelSize: metrics.fontLarge
                    font.bold: true
                    font.family: "monospace"
                    Layout.fillWidth: true
                }

                // Toggle pill
                Rectangle {
                    id: radioPill
                    width: metrics.s(42)
                    height: metrics.s(22)
                    radius: height / 2
                    color: networkWidget.radioEnabled ? Theme.colors.green : Theme.colors.inset
                    border.width: 1
                    border.color: Theme.colors.border

                    Rectangle {
                        width: parent.height - metrics.s(4)
                        height: width
                        radius: width / 2
                        color: Theme.colors.textPrimary
                        anchors.verticalCenter: parent.verticalCenter
                        x: networkWidget.radioEnabled ? (parent.width - width - metrics.s(2)) : metrics.s(2)
                        Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: networkWidget.toggleRadio()
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
                visible: networkWidget.statusMessage.length > 0
                text: networkWidget.statusMessage
                color: networkWidget.statusIsError ? Theme.colors.red : Theme.colors.green
                font.pixelSize: metrics.fontTiny
                font.bold: true
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
            }

            // Disabled state
            Text {
                visible: !networkWidget.radioEnabled
                text: "Wi-Fi is turned off"
                color: Theme.colors.textMuted
                font.pixelSize: metrics.fontSmall
                Layout.fillWidth: true
                Layout.topMargin: metrics.spacingNormal
                horizontalAlignment: Text.AlignHCenter
            }

            // Network list
            ListView {
                visible: networkWidget.radioEnabled
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: metrics.spacingTiny
                model: networkWidget.networks

                delegate: ColumnLayout {
                    id: delegateRoot
                    required property var modelData
                    width: ListView.view.width
                    spacing: metrics.spacingTiny

                    Rectangle {
                        Layout.fillWidth: true
                        height: metrics.s(38)
                        radius: metrics.radiusSmall
                        color: delegateRoot.modelData.active ? Theme.colors.inset : "transparent"

                        RowLayout {
                            anchors {
                                fill: parent
                                leftMargin: metrics.spacingSmall
                                rightMargin: metrics.spacingSmall
                            }
                            spacing: metrics.spacingSmall

                            Text {
                                text: networkWidget.signalIcon(delegateRoot.modelData.signal)
                                color: delegateRoot.modelData.active ? Theme.colors.green : Theme.colors.textSecondary
                                font.pixelSize: metrics.fontNormal
                                font.family: "monospace"
                            }

                            Text {
                                text: delegateRoot.modelData.ssid
                                color: Theme.colors.textPrimary
                                font.pixelSize: metrics.fontSmall
                                font.bold: delegateRoot.modelData.active
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }

                            Text {
                                visible: delegateRoot.modelData.secured
                                text: "󰌾"
                                color: Theme.colors.textMuted
                                font.pixelSize: metrics.fontTiny
                                font.family: "monospace"
                            }

                            Text {
                                visible: delegateRoot.modelData.active
                                text: "Connected"
                                color: Theme.colors.green
                                font.pixelSize: metrics.fontTiny
                                font.bold: true
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: networkWidget.selectNetwork(delegateRoot.modelData)
                        }
                    }

                    // Inline password prompt
                    RowLayout {
                        visible: networkWidget.expandedSsid === delegateRoot.modelData.ssid
                        Layout.fillWidth: true
                        Layout.leftMargin: metrics.spacingNormal
                        Layout.rightMargin: metrics.spacingNormal
                        spacing: metrics.spacingSmall

                        Rectangle {
                            Layout.fillWidth: true
                            height: metrics.s(28)
                            radius: metrics.radiusSmall
                            color: Theme.colors.inset

                            TextInput {
                                id: passwordField
                                anchors {
                                    fill: parent
                                    leftMargin: metrics.spacingSmall
                                    rightMargin: metrics.spacingSmall
                                }
                                verticalAlignment: TextInput.AlignVCenter
                                color: Theme.colors.textPrimary
                                font.pixelSize: metrics.fontSmall
                                echoMode: TextInput.Password
                                clip: true
                                focus: networkWidget.expandedSsid === delegateRoot.modelData.ssid

                                Keys.onReturnPressed: networkWidget.connectTo(delegateRoot.modelData.ssid, text)
                                Keys.onEnterPressed: networkWidget.connectTo(delegateRoot.modelData.ssid, text)
                                Keys.onEscapePressed: {
                                    networkWidget.expandedSsid = ""
                                    text = ""
                                }

                                Text {
                                    visible: passwordField.text.length === 0
                                    text: "Password"
                                    color: Theme.colors.textMuted
                                    font.pixelSize: metrics.fontSmall
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }

                        Rectangle {
                            width: metrics.s(56)
                            height: metrics.s(28)
                            radius: metrics.radiusSmall
                            color: Theme.colors.blue

                            Text {
                                anchors.centerIn: parent
                                text: "Connect"
                                color: Theme.colors.panelDeep
                                font.pixelSize: metrics.fontTiny
                                font.bold: true
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: networkWidget.connectTo(delegateRoot.modelData.ssid, passwordField.text)
                            }
                        }
                    }
                }
            }
        }
    }
}
