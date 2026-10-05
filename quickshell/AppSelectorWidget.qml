import QtQuick
import QtQuick.Layouts
import Quickshell
import QtQml.Models
import "themes"
import "templates"

Item {
    id: appSelectorWidget
    visible: bar.state === "app_selector"
    
    anchors {
        top: metrics.isVertical ? undefined : parent.top
        left: metrics.isVertical ? parent.left : undefined
        topMargin: metrics.isVertical ? 0 : bar.dropdownWidgetPadding
        leftMargin: metrics.isVertical ? bar.dropdownWidgetPadding : 0
        horizontalCenter: metrics.isVertical ? undefined : parent.horizontalCenter
        verticalCenter: metrics.isVertical ? parent.verticalCenter : undefined
    }

    width: parent.width - (bar.dropdownWidgetPadding * 2)
    height: totalHeight

    // Layout constants
    readonly property int edgePadding: metrics.marginBar
    readonly property int searchBarHeight: metrics.s(32)
    readonly property int separatorY: edgePadding + searchBarHeight + metrics.spacingSmall  // 8px below search bar
    readonly property int gridY: separatorY + metrics.s(2) + metrics.spacingSmall  // 8px below separator
    readonly property int gridHeight: bar.appSelectorRowsPerPage * bar.appSelectorCellHeightConst
    readonly property int totalHeight: gridHeight + gridY + edgePadding*2

    onVisibleChanged: {
        currentPage = 0;
        resultsGrid.currentIndex = 0;
        resultsGrid.contentY = 0; 
        searchBox.text = "";
        searchBox.forceActiveFocus();
        filteredAppModel.search("");
    }

    DelegateModel {
        id: filteredAppModel
        model: DesktopEntries.applications

        groups: [
            DelegateModelGroup {
                id: visibleItems
                name: "visible"
                includeByDefault: true
            }
        ]

        filterOnGroup: "visible"

        function search(text) {
            var lowerText = text.toLowerCase();
            
            for (var i = 0; i < items.count; ++i) {
                var item = items.get(i);
                var data = item.model.modelData
                var appName = data.name ? data.name : "";
                
                if (text === "" || appName.toLowerCase().includes(lowerText) || data.command.some(element => element.toLowerCase().includes(lowerText)) || data.categories.some(element => element.toLowerCase().includes(lowerText))) {
                    item.inVisible = true;
                } else {
                    item.inVisible = false;
                }
            }
            
            appSelectorWidget.currentPage = 0;
        }
    }

    property int currentPage: 0
    property int columns: 3
    property int itemsPerPage: columns * bar.appSelectorRowsPerPage
    property var appModel: filteredAppModel 
    property int totalPages: Math.ceil(appModel.count / itemsPerPage)

    onTotalPagesChanged: if (currentPage >= totalPages) currentPage = 0

    // Background
    Rectangle {
        anchors.fill: parent
        color: Theme.colors.surface
        radius: metrics.radiusLarge
    }

    // Search bar
    Rectangle {
        id: searchBar
        x: metrics.marginBar
        y: metrics.marginBar
        width: parent.width - metrics.s(30)
        height: appSelectorWidget.searchBarHeight
        color: Theme.colors.field
        radius: Theme.colors.nebula ? height / 2 : metrics.radiusNormal
        border.width: 1
        border.color: searchBox.activeFocus ? Theme.colors.fieldFocus : Theme.colors.fieldBorder
        Behavior on border.color { ColorAnimation { duration: 200 } }

        Text {
            id: searchIcon
            x: metrics.s(12)
            anchors.verticalCenter: parent.verticalCenter
            text: "󰍉"
            color: Theme.colors.accent
            font.pixelSize: metrics.fontNormal
            font.family: "monospace"
        }

        Text {
            x: searchIcon.x + searchIcon.width + metrics.spacingSmall
            anchors.verticalCenter: parent.verticalCenter
            text: "Search applications..."
            color: Theme.colors.textMuted
            font.pixelSize: metrics.fontNormal
            font.family: "monospace"
            visible: !searchBox.text && !searchBox.activeFocus
        }

        TextInput {
            id: searchBox
            x: searchIcon.x + searchIcon.width + metrics.spacingSmall
            width: parent.width - x - metrics.s(12)
            anchors.verticalCenter: parent.verticalCenter

            color: Theme.colors.textPrimary
            font.pixelSize: metrics.fontNormal
            font.family: "monospace"
            clip: true
            
            onTextChanged: {
                filteredAppModel.search(text)
                resultsGrid.currentIndex = 0
                resultsGrid.contentY = 0
            }

            focus: true 

            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Up) {
                    resultsGrid.moveCurrentIndexUp();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Down) {
                    resultsGrid.moveCurrentIndexDown();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Left) {
                    resultsGrid.moveCurrentIndexLeft();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Right) {
                    resultsGrid.moveCurrentIndexRight();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Escape) {
                    bar.state = "normal";
                    event.accepted = true;
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    if (resultsGrid.currentItem) {
                        var item = visibleItems.get(resultsGrid.currentIndex);
                        var app = item.model.modelData || item.model;
                        if (app.execute) app.execute();
                        bar.state = "normal";
                    }
                    event.accepted = true;
                }
            }
        }
    }

    // Separator
    QRule {
        x: appSelectorWidget.edgePadding
        y: appSelectorWidget.separatorY
        width: parent.width - (appSelectorWidget.edgePadding*2)
        height: Theme.colors.ruleFades ? 1 : metrics.s(2)
    }

    // Grid
    GridView {
        id: resultsGrid
        x: appSelectorWidget.edgePadding
        y: appSelectorWidget.gridY
        width: parent.width - (appSelectorWidget.edgePadding*2)
        height: appSelectorWidget.gridHeight

        cellWidth: width / appSelectorWidget.columns
        cellHeight: bar.appSelectorCellHeightConst

        model: appSelectorWidget.appModel
        
        interactive: false 
        clip: true
        keyNavigationEnabled: true 

        Behavior on contentY {
            NumberAnimation { duration: 300; easing.type: Easing.InOutQuad }
        }

        onCurrentIndexChanged: {
            if (appSelectorWidget.itemsPerPage > 0) {
                var newPage = Math.floor(currentIndex / appSelectorWidget.itemsPerPage)
                if (newPage !== appSelectorWidget.currentPage) {
                    appSelectorWidget.currentPage = newPage
                    appSelectorWidget.updateGridPosition()
                }
            }
        }

        highlight: Rectangle {
            color: Theme.colors.inset
            radius: metrics.radiusNormal
            border.width: Theme.colors.nebula ? 1 : 2
            border.color: Theme.colors.accent
        }
        highlightFollowsCurrentItem: true

        delegate: Item {
            width: resultsGrid.cellWidth
            height: resultsGrid.cellHeight

            property var appData: model.modelData || model 
            property bool isSelected: GridView.isCurrentItem

            Column {
                anchors.centerIn: parent
                spacing: metrics.spacingSmall

                Image {
                    width: metrics.s(32)
                    height: metrics.s(32)
                    anchors.horizontalCenter: parent.horizontalCenter
                    source: {
                        var icon = appData.icon || "";
                        var name = appData.name || "";

                        if (!icon) return "image://icon/application-x-executable";
                        if (name === "JetBrains Toolbox") return "image://icon/jetbrains-toolbox"; 
                        
                        if (icon.startsWith("/") || icon.startsWith("file://")) {
                            var fileName = icon.split("/").pop(); 
                            var iconName = fileName.replace(/\.[^/.]+$/, ""); 
                            return "image://icon/" + iconName;
                        }
                        return "image://icon/" + icon;
                    }

                    sourceSize.width: width
                    sourceSize.height: height
                    mipmap: true
                    smooth: true
                }

                Text {
                    text: appData.name
                    color: isSelected || !Theme.colors.nebula ? Theme.colors.textPrimary : Theme.colors.textSecondary
                    font.pixelSize: metrics.fontTiny
                    font.bold: isSelected
                    font.family: "monospace"
                    anchors.horizontalCenter: parent.horizontalCenter
                    elide: Text.ElideRight
                    width: resultsGrid.cellWidth - metrics.s(16)
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (resultsGrid.currentIndex === index) {
                        appData.execute();
                        bar.state = "normal"
                    } else {
                        resultsGrid.currentIndex = index;
                        searchBox.forceActiveFocus();
                    }
                }

                onDoubleClicked: {
                    appData.execute();
                    bar.state = "normal"
                }
            }
        }
    }

    // Page indicator
    Text {
        anchors {
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
            bottomMargin: (appSelectorWidget.edgePadding/2)
        }
        text: (appSelectorWidget.currentPage + 1) + " / " + appSelectorWidget.totalPages
        color: Theme.colors.textMuted
        font.pixelSize: metrics.fontTiny
        font.family: "monospace"
        visible: appSelectorWidget.totalPages > 1
    }

    function nextPage() {
        var nextIndex = (currentPage + 1) * itemsPerPage;
        if (nextIndex < appModel.count) {
            resultsGrid.currentIndex = nextIndex;
        } else if (currentPage < totalPages - 1) {
            resultsGrid.currentIndex = appModel.count - 1;
        }
    }

    function prevPage() {
        var prevIndex = (currentPage - 1) * itemsPerPage;
        if (prevIndex >= 0) {
            resultsGrid.currentIndex = prevIndex;
        } else {
            resultsGrid.currentIndex = 0;
        }
    }

    function updateGridPosition() {
        var startRow = Math.floor((currentPage * itemsPerPage) / columns);
        resultsGrid.contentY = startRow * resultsGrid.cellHeight - resultsGrid.topMargin;
    }
}
