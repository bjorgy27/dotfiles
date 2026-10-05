import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "themes"
import "templates"

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
        color: Theme.colors.surface
        radius: metrics.radiusLarge

        ColumnLayout {
            anchors {
                fill: parent
                margins: metrics.marginBar
            }
            spacing: metrics.spacingSmall

            QHeading {
                text: "Power Options"
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
            }

            QRule {
                Layout.fillWidth: true
                implicitHeight: Theme.colors.ruleFades ? 1 : metrics.s(2)
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: metrics.spacingNormal

                Repeater {
                    model: powerMenuWidget.powerActions

                    // One option: a round glass tile with its icon, the label under it.
                    delegate: Rectangle {
                        id: option
                        required property int index
                        required property var modelData
                        readonly property bool selected: powerMenuWidget.selectedIndex === index

                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        color: selected && !Theme.colors.nebula ? Theme.colors.inset : "transparent"
                        radius: metrics.radiusNormal
                        border.width: selected && !Theme.colors.nebula ? 2 : 0
                        border.color: modelData.color

                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: metrics.spacingTiny

                            Rectangle {
                                Layout.alignment: Qt.AlignHCenter
                                implicitWidth: metrics.s(44)
                                implicitHeight: implicitWidth
                                radius: width / 2
                                color: option.selected ? Theme.colors.inset : Theme.colors.card
                                border.width: option.selected ? 2 : 1
                                border.color: option.selected ? option.modelData.color : Theme.colors.cardBorder
                                scale: option.selected ? 1.06 : 1
                                Behavior on scale { NumberAnimation { duration: 120 } }
                                Behavior on color { ColorAnimation { duration: 150 } }

                                Text {
                                    anchors.centerIn: parent
                                    text: option.modelData.icon
                                    color: option.modelData.color
                                    font.pixelSize: metrics.s(22)
                                    font.family: "monospace"
                                }
                            }

                            QLabel {
                                text: option.modelData.label
                                color: option.selected ? Theme.colors.textPrimary : Theme.colors.textSecondary
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
