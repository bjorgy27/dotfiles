import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "themes"

// Power Menu
Item {
    id: powerMenuWidget

    readonly property bool isOpen: bar.state === "power_menu"
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

    property int selectedIndex: 0
    property var powerActions: [
        {
            label: "Shutdown",
            icon: "󰐥",
            color: Theme.colors.red,
            command: ["systemctl", "poweroff"]
        },
        {
            label: "Reboot",
            icon: "󰜉",
            color: Theme.colors.orange,
            command: ["systemctl", "reboot"]
        },
        {
            label: "Lock",
            icon: "󰌾",
            color: Theme.colors.blue,
            // through Hyprland like Super+L, so the lock is not a child of the bar
            command: ["hyprctl", "dispatch", "hl.dsp.exec_cmd(\"~/.config/scripts/lock/lock.sh\")"]
        },
        {
            label: "Logout",
            icon: "󰍃",
            color: Theme.colors.yellow,
            command: ["hyprctl", "dispatch", "hl.dsp.exit()"]
        }
    ]

    focus: visible

    Keys.onLeftPressed: selectedIndex = Math.max(0, selectedIndex - 1)
    Keys.onRightPressed: selectedIndex = Math.min(powerActions.length - 1, selectedIndex + 1)
    Keys.onReturnPressed: activateSelected()
    Keys.onEnterPressed: activateSelected()
    Keys.onEscapePressed: bar.state = "normal"

    function activateSelected() {
        actionProc.command = powerActions[selectedIndex].command
        actionProc.running = true
        bar.state = "normal"
    }

    Process {
        id: actionProc
        running: false
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

            Text {
                text: "Power Options"
                color: Theme.colors.textPrimary
                font.pixelSize: metrics.fontLarge
                font.bold: true
                font.family: "monospace"
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
            }

            Rectangle {
                Layout.fillWidth: true
                height: metrics.s(2)
                color: Theme.colors.border
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: metrics.spacingNormal

                Repeater {
                    model: powerMenuWidget.powerActions

                    delegate: Rectangle {
                        required property int index
                        required property var modelData

                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        color: powerMenuWidget.selectedIndex === index ? Theme.colors.inset : "transparent"
                        radius: metrics.radiusNormal
                        border.width: powerMenuWidget.selectedIndex === index ? 2 : 0
                        border.color: modelData.color

                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: metrics.spacingSmall

                            Text {
                                text: modelData.icon
                                color: modelData.color
                                font.pixelSize: metrics.fontXL
                                font.family: "monospace"
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Text {
                                text: modelData.label
                                color: Theme.colors.textPrimary
                                font.pixelSize: metrics.fontTiny
                                font.bold: true
                                Layout.alignment: Qt.AlignHCenter
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: powerMenuWidget.selectedIndex = index
                            onClicked: {
                                powerMenuWidget.selectedIndex = index
                                powerMenuWidget.activateSelected()
                            }
                        }
                    }
                }
            }
        }
    }
}
