import QtQuick
import QtQuick.Layouts
import "themes"

// Radar settings dropdown: weather product picker, aircraft/animation toggles
// and a view reset. Everything writes through root.setMapSettings /
// root.setMapView (see shell.qml) so every Radar dashboard tile stays in sync
// and the choice is persisted via radarstate.sh.
Item {
    id: radarSettingsWidget

    readonly property bool isOpen: bar.state === "radar_settings"
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

    readonly property var products: [
        { id: "rainviewer", name: "Radar",                 hint: "global composite · RainViewer" },
        { id: "nws_bref",   name: "NWS MRMS Reflectivity", hint: "CONUS · 1 km base reflectivity" },
        { id: "none",       name: "Off",                   hint: "basemap + aircraft only" }
    ]

    function selectProduct(id) {
        root.setMapSettings(id, root.mapPlanes, root.mapAnimate)
    }

    function togglePlanes() {
        root.setMapSettings(root.mapProduct, !root.mapPlanes, root.mapAnimate)
    }

    function toggleAnimate() {
        root.setMapSettings(root.mapProduct, root.mapPlanes, !root.mapAnimate)
    }

    function resetView() {
        root.setMapView(root.homeLat, root.homeLon, 6)
        bar.state = "dashboard"
    }

    onIsOpenChanged: if (isOpen) radarSettingsWidget.forceActiveFocus()

    Keys.onEscapePressed: bar.state = "dashboard"
    focus: visible

    // A pill switch matching the Network/Bluetooth dropdown toggles.
    component TogglePill: Rectangle {
        id: pill
        property bool checked: false
        signal toggled()

        implicitWidth: metrics.s(42)
        implicitHeight: metrics.s(22)
        radius: height / 2
        color: checked ? Theme.colors.accent : Theme.colors.inset
        border.width: 1
        border.color: Theme.colors.border
        Behavior on color { ColorAnimation { duration: 120 } }

        Rectangle {
            width: parent.height - metrics.s(4)
            height: width
            radius: width / 2
            color: pill.checked ? Theme.colors.panelDeep : Theme.colors.textPrimary
            anchors.verticalCenter: parent.verticalCenter
            x: pill.checked ? (parent.width - width - metrics.s(2)) : metrics.s(2)
            Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: pill.toggled()
        }
    }

    // Label + description + pill on one row.
    component ToggleRow: Item {
        id: row
        property string label: ""
        property string hint: ""
        property bool checked: false
        signal toggled()

        Layout.fillWidth: true
        implicitHeight: metrics.s(36)

        RowLayout {
            anchors.fill: parent
            spacing: metrics.spacingNormal

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                Text {
                    text: row.label
                    color: Theme.colors.textPrimary
                    font.pixelSize: metrics.fontSmall
                    font.family: "monospace"
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                Text {
                    text: row.hint
                    color: Theme.colors.textMuted
                    font.pixelSize: metrics.fontTiny
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
            }

            TogglePill {
                checked: row.checked
                onToggled: row.toggled()
            }
        }

        MouseArea {
            anchors.fill: parent
            z: -1
            cursorShape: Qt.PointingHandCursor
            onClicked: row.toggled()
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

            Text {
                text: "  Radar Settings"
                color: Theme.colors.textPrimary
                font.pixelSize: metrics.fontLarge
                font.bold: true
                font.family: "monospace"
                Layout.fillWidth: true
                elide: Text.ElideRight
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: bar.dividerThickness
                color: Theme.colors.border
            }

            Text {
                text: "Weather product"
                color: Theme.colors.textSecondary
                font.pixelSize: metrics.fontTiny
                font.bold: true
                Layout.topMargin: metrics.spacingTiny
            }

            // Product radio list
            ColumnLayout {
                Layout.fillWidth: true
                spacing: metrics.spacingTiny

                Repeater {
                    model: radarSettingsWidget.products

                    delegate: Rectangle {
                        id: productRow
                        required property var modelData
                        readonly property bool selected: modelData.id === root.mapProduct

                        Layout.fillWidth: true
                        Layout.preferredHeight: metrics.s(32)
                        radius: metrics.radiusSmall
                        color: selected ? Theme.colors.accent
                             : (productMouse.containsMouse ? Theme.colors.inset : "transparent")
                        Behavior on color { ColorAnimation { duration: 100 } }

                        RowLayout {
                            anchors {
                                fill: parent
                                leftMargin: metrics.spacingNormal
                                rightMargin: metrics.spacingNormal
                            }
                            spacing: metrics.spacingSmall

                            // Radio dot
                            Rectangle {
                                implicitWidth: metrics.s(12)
                                implicitHeight: metrics.s(12)
                                radius: width / 2
                                color: "transparent"
                                border.width: metrics.s(2)
                                border.color: productRow.selected ? Theme.colors.panelDeep : Theme.colors.textMuted

                                Rectangle {
                                    anchors.centerIn: parent
                                    width: metrics.s(6)
                                    height: width
                                    radius: width / 2
                                    color: Theme.colors.panelDeep
                                    visible: productRow.selected
                                }
                            }

                            Text {
                                text: productRow.modelData.name
                                color: productRow.selected ? Theme.colors.panelDeep : Theme.colors.textPrimary
                                font.pixelSize: metrics.fontSmall
                                font.bold: productRow.selected
                                font.family: "monospace"
                            }

                            Text {
                                text: productRow.modelData.hint
                                color: productRow.selected ? Theme.colors.panelDeep : Theme.colors.textMuted
                                opacity: productRow.selected ? 0.8 : 1
                                font.pixelSize: metrics.fontTiny
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignRight
                                elide: Text.ElideLeft
                            }
                        }

                        MouseArea {
                            id: productMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: radarSettingsWidget.selectProduct(productRow.modelData.id)
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: metrics.spacingTiny
                Layout.preferredHeight: bar.dividerThickness
                color: Theme.colors.border
            }

            Text {
                text: "Overlays"
                color: Theme.colors.textSecondary
                font.pixelSize: metrics.fontTiny
                font.bold: true
                Layout.topMargin: metrics.spacingTiny
            }

            ToggleRow {
                label: "Show aircraft"
                hint: "live ADS-B traffic · click a plane for its route"
                checked: root.mapPlanes
                onToggled: radarSettingsWidget.togglePlanes()
            }

            ToggleRow {
                label: "Animate radar loop"
                hint: "loop the latest RainViewer frames"
                checked: root.mapAnimate
                onToggled: radarSettingsWidget.toggleAnimate()
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: metrics.spacingTiny
                Layout.preferredHeight: bar.dividerThickness
                color: Theme.colors.border
            }

            // Reset view button
            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: metrics.spacingSmall
                Layout.preferredHeight: metrics.s(32)
                radius: metrics.radiusNormal
                color: resetMouse.containsMouse ? Theme.colors.border : Theme.colors.inset
                Behavior on color { ColorAnimation { duration: 100 } }

                Text {
                    anchors.centerIn: parent
                    text: "󰋜  Reset view to home"
                    color: Theme.colors.textPrimary
                    font.pixelSize: metrics.fontSmall
                    font.family: "monospace"
                }

                MouseArea {
                    id: resetMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: radarSettingsWidget.resetView()
                }
            }

            Item { Layout.fillHeight: true }

            Text {
                text: "Data: © Esri · RainViewer · NOAA / NWS · adsb.lol · adsbdb"
                color: Theme.colors.textMuted
                font.pixelSize: metrics.fontTiny
                font.italic: true
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
        }
    }
}
