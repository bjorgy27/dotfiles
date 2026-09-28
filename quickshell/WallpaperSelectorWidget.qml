import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell
import Quickshell.Services.Pipewire
import Quickshell.Widgets
import Quickshell.Hyprland
import Quickshell.Wayland
import Qt.labs.folderlistmodel
import Qt5Compat.GraphicalEffects
import Quickshell.Io
import "themes"

// Wallpaper Selector
Item {
    id: wallpaperSelectorWidget

    readonly property bool isOpen: bar.state === "wallpaper_selector"

    // Key navigation is broadcast from root; only the leader (first-opened
    // window) applies the step. Its index changes publish to
    // root.wallpaperSharedIndex, which the other open selectors adopt below —
    // absolute positions, so they can't drift apart. Only the leader queues
    // the wallpaper script.
    Connections {
        target: root
        function onWallpaperNavCounterChanged() {
            if (!wallpaperSelectorWidget.isOpen || carousel.count === 0)
                return;
            if (root.selectorWindows[0] !== barWindow)
                return;

            if (root.wallpaperNavDir < 0)
                carousel.decrementCurrentIndex();
            else
                carousel.incrementCurrentIndex();
        }

        function onWallpaperSharedIndexChanged() {
            if (!wallpaperSelectorWidget.isOpen || carousel.count === 0)
                return;

            let idx = root.wallpaperSharedIndex;
            if (idx < 0 || idx >= carousel.count || idx === carousel.currentIndex)
                return;

            if (root.selectorWindows[0] === barWindow) {
                // Another monitor drove the selection (e.g. by mouse); adopt it
                // unsuppressed so this instance queues the wallpaper change.
                carousel.positionViewAtIndex(idx, PathView.Center);
                carousel.currentIndex = idx;
                return;
            }

            restoringSelection = true;
            carousel.positionViewAtIndex(idx, PathView.Center);
            carousel.currentIndex = idx;
            Qt.callLater(() => restoringSelection = false);
        }
    }

    visible: isOpen

    anchors.fill: parent

    FolderListModel {
        id: wallpaperModel
        folder: "file://" + Quickshell.env("HOME") + "/.config/wallpapers"
        // *.live: a dynamic wallpaper (scripts/wallpaper/bins/<stem>) with no
        // still of its own; the carousel shows it running (see the delegate).
        nameFilters: ["*.jpg", "*.png", "*.jpeg", "*.webp", "*.live"]
        showDirs: false
    }

    property int selectedIndex: 0
    property bool restoringSelection: false
    property string savedWallpaperPath: ""
    property string pendingWallpaperPath: ""
    // Last previewed path, applied for real once the selection settles or
    // the selector closes.
    property string commitWallpaperPath: ""

    readonly property string wallpaperScript: Quickshell.env("HOME") + "/.config/scripts/wallpaper/wallpaper_select.sh"

    function normalizedPath(path) {
        return String(path || "").replace(/[\r\n]+/gm, "");
    }

    // A dynamic wallpaper saved under another extension (the globe used to
    // be spinning_globe.png) still selects its .live entry.
    function sameWallpaper(itemPath, saved) {
        itemPath = normalizedPath(itemPath);
        if (itemPath === saved)
            return true;
        let stem = p => p.replace(/\.[^./]*$/, "");
        return itemPath.endsWith(".live") && stem(itemPath) === stem(saved);
    }

    function queueWallpaper(path) {
        let cleanPath = normalizedPath(path);
        if (cleanPath.length === 0 || cleanPath === savedWallpaperPath)
            return;

        pendingWallpaperPath = cleanPath;
        wallpaperDebounce.restart();
    }

    function runPendingWallpaper() {
        if (pendingWallpaperPath.length === 0)
            return;

        let cleanPath = pendingWallpaperPath;
        pendingWallpaperPath = "";
        savedWallpaperPath = cleanPath;
        commitWallpaperPath = cleanPath;
        // The preview already switches for real (static images from a RAM
        // cache, the globe is kept running and just shown/hidden, no layer
        // maps/unmaps); the commit after the selection settles only saves it.
        // Fire-and-forget: the script serializes concurrent runs via flock and
        // drops previews superseded by a newer request.
        Quickshell.execDetached([wallpaperScript, "--preview", cleanPath]);
        wallpaperSettle.restart();
    }

    function applyWallpaper() {
        wallpaperSettle.stop();
        if (commitWallpaperPath.length === 0)
            return;

        let cleanPath = commitWallpaperPath;
        commitWallpaperPath = "";
        // Safety net: a cold start of a dynamic wallpaper (not yet warm) maps
        // layers, which can steal the keyboard; root takes it back while the
        // selector is open.
        root.guardSelectorFocus(1000);
        Quickshell.execDetached([wallpaperScript, cleanPath]);
    }

    function commitWallpaper() {
        if (wallpaperDebounce.running) {
            wallpaperDebounce.stop();
            if (pendingWallpaperPath.length > 0) {
                savedWallpaperPath = pendingWallpaperPath;
                commitWallpaperPath = pendingWallpaperPath;
            }
            pendingWallpaperPath = "";
        }

        applyWallpaper();
    }

    onIsOpenChanged: {
        if (!isOpen)
            commitWallpaper();
    }

    FileView {
        id: savedWallpaperReader
        path: Quickshell.env("HOME") + "/.config/scripts/wallpaper/wpsave.txt"
        // reload() is async otherwise, so text() on open would return the file
        // as of the previous open and the carousel would start on a stale item.
        blockLoading: true
    }

    // While a drag/flick is in progress, StrictlyEnforceRange keeps rewriting
    // currentIndex from the view position, so re-arm until it ends. Key and
    // click selection set the final index up front, so they fire 60 ms after
    // the last step without waiting for the slide animation (still enough to
    // coalesce a held arrow key's repeats).
    Timer {
        id: wallpaperDebounce
        interval: 60
        repeat: false
        onTriggered: {
            if (carousel.dragging || carousel.flicking) {
                restart();
                return;
            }
            runPendingWallpaper();
        }
    }

    // Saves the previewed selection once navigation pauses (it's already on
    // screen, so this doesn't affect how fast switching feels).
    Timer {
        id: wallpaperSettle
        interval: 250
        repeat: false
        onTriggered: {
            if (wallpaperDebounce.running || carousel.dragging || carousel.flicking) {
                restart();
                return;
            }
            applyWallpaper();
        }
    }

    onVisibleChanged: {
        savedWallpaperReader.reload();

        if (visible) {
            // Make sure the globe is running (hidden) and the scaled copies
            // are cached; a no-op when they already are.
            Quickshell.execDetached(["nice", "-n", "19", wallpaperScript, "--warm"]);
            savedWallpaperPath = normalizedPath(savedWallpaperReader.text());
            
            let applySelection = () => {
                restoringSelection = true;
                let found = false;

                // A selector already open on another monitor wins over the save
                // file — its position can be ahead of the last completed script.
                let shared = root.wallpaperSharedIndex;
                if (root.selectorWindows[0] !== barWindow && shared >= 0 && shared < wallpaperModel.count) {
                    carousel.positionViewAtIndex(shared, PathView.Center);
                    carousel.currentIndex = shared;
                    found = true;
                } else {
                    for (let i = 0; i < wallpaperModel.count; i++) {
                        if (sameWallpaper(wallpaperModel.get(i, "filePath"), savedWallpaperPath)) {
                            carousel.positionViewAtIndex(i, PathView.Center);
                            carousel.currentIndex = i;
                            found = true;
                            break;
                        }
                    }
                }

                if (found)
                    Qt.callLater(() => restoringSelection = false);
                else
                    restoringSelection = false;
            };

            // Deferred so the window registry (leader order) settles before the
            // leader-vs-follower decision — both react to the same state change.
            let findIndex = () => Qt.callLater(applySelection);

            if (wallpaperModel.status === FolderListModel.Ready) {
                findIndex();
            } else {
                const onReady = () => {
                    if (wallpaperModel.status === FolderListModel.Ready) {
                        findIndex();
                        wallpaperModel.statusChanged.disconnect(onReady);
                    }
                };
                wallpaperModel.statusChanged.connect(onReady);
            }
        }
    }

    PathView {
        id: carousel
        width: parent.width * 0.99
        height: parent.height
        anchors {
            horizontalCenter: parent.horizontalCenter
            verticalCenter: parent.verticalCenter
        }

        focus: visible
        onActiveFocusChanged: root.setSelectorFocused(barWindow, activeFocus)

        Keys.onLeftPressed: root.wallpaperNav(-1)
        Keys.onRightPressed: root.wallpaperNav(1)
        Keys.onUpPressed: root.wallpaperNav(-1)
        Keys.onDownPressed: root.wallpaperNav(1)
        Keys.onReturnPressed: root.closeWallpaperSelectors()
        Keys.onEnterPressed: root.closeWallpaperSelectors()
        Keys.onEscapePressed: root.closeWallpaperSelectors()

        model: wallpaperModel
        
        pathItemCount: 5
        cacheItemCount: 25
        
        preferredHighlightBegin: 0.5
        preferredHighlightEnd: 0.5
        highlightRangeMode: PathView.StrictlyEnforceRange
        
        snapMode: PathView.SnapToItem
        dragMargin: metrics.s(200)

        clip: true

        onCurrentIndexChanged: {
            if (currentIndex < 0 || currentIndex >= model.count)
                return;

            // Publish even suppressed changes: followers re-publish the value
            // they were told (a no-op), while restores seed the shared state.
            if (wallpaperSelectorWidget.isOpen)
                root.wallpaperSharedIndex = currentIndex;

            if (restoringSelection || root.selectorWindows[0] !== barWindow)
                return;

            queueWallpaper(model.get(currentIndex, "filePath"));
        }

        delegate: Rectangle {
            id: wallpaperDelegate
            width: metrics.isVertical ? carousel.width * 0.6 : carousel.width / 6
            height: width * 9/16 + metrics.s(30)
            
            scale: PathView.iconScale 
            z: PathView.iconZ
            property bool isCurrentItem: PathView.isCurrentItem
            opacity: isCurrentItem ? 1 : 0.5

            Behavior on opacity {
                NumberAnimation {
                    duration: 100 // adjust speed in milliseconds
                    easing.type: Easing.OutQuad
                }
            }
            
            color: "transparent"

            readonly property bool isLive: fileSuffix === "live"
            // Live previews start the first time they come onto the visible
            // part of the path and then stay alive: a hidden BevyView renders
            // nothing (zero cost closed), while creating the Bevy app blocks
            // the render thread for ~50 ms per app, so tearing it down on close
            // made every open stall. The first start waits for the open
            // animation to finish so that one-time stall doesn't freeze it.
            property bool liveStarted: false
            readonly property bool onPath: PathView.onPath
            function updateLive() {
                if (liveStarted || !isLive || !onPath || !wallpaperSelectorWidget.isOpen)
                    liveStartDelay.stop();
                else
                    liveStartDelay.start();
            }
            Timer {
                id: liveStartDelay
                interval: 150
                onTriggered: wallpaperDelegate.liveStarted = true
            }
            onOnPathChanged: updateLive()
            Component.onCompleted: updateLive()
            Connections {
                target: wallpaperSelectorWidget
                function onIsOpenChanged() { wallpaperDelegate.updateLive() }
            }

            Item {
                id: img
                width: parent.width
                height: width * 9/16

                Image {
                    anchors.fill: parent
                    visible: !wallpaperDelegate.isLive
                    // source is static per delegate! It never changes, so no reloading.
                    source: wallpaperDelegate.isLive ? "" : fileUrl

                    // Keep the optimization to ensure initial load is fast
                    sourceSize.width: 0
                    sourceSize.height: 400

                    asynchronous: true
                    cache: true
                    clip: true
                    fillMode: Image.PreserveAspectCrop
                }

                // The wallpaper's background, under the live view until its
                // first frame (or if the Bevy module/app isn't built).
                Rectangle {
                    anchors.fill: parent
                    visible: wallpaperDelegate.isLive
                    color: "#1e1e2e"
                }

                // The dynamic wallpaper itself, rendered in-process by the Bevy
                // app of the same name at this monitor's size, box-filtered
                // down. Renders only while on the visible part of the path.
                Loader {
                    anchors.fill: parent
                    active: wallpaperDelegate.isLive && wallpaperDelegate.liveStarted
                    visible: wallpaperSelectorWidget.isOpen && wallpaperDelegate.onPath
                    onActiveChanged: if (active) setSource("WallpaperLivePreview.qml", {
                        app: fileBaseName,
                        options: JSON.stringify({ output: [barWindow.screen?.width ?? 2560, barWindow.screen?.height ?? 1440] })
                    })
                }

                layer.enabled: true
                layer.effect: OpacityMask {
                    maskSource: Rectangle {
                        width: img.width
                        height: img.height
                        radius: wallpaperDelegate.isCurrentItem ? metrics.radiusNormal : metrics.radiusSmall
                        visible: false 
                        Behavior on radius {
                            NumberAnimation {
                                duration: 150 // adjust speed in milliseconds
                                easing.type: Easing.OutQuad
                            }
                        }
                    }
                }
            }

            Text {
                anchors.top: img.bottom
                anchors.topMargin: metrics.spacingSmall
                anchors.left: parent.left
                anchors.right: parent.right
                text: fileBaseName
                color: Theme.colors.textSecondary
                font.family: "Noto Sans"
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
            }
            
            // Click to select
            MouseArea {
                anchors.fill: parent
                onClicked: carousel.currentIndex = index
            }
        }

        // 6. The Path the items float along: horizontal on a top bar, vertical on
        //    a side bar (start/end swap axes; the middle point is the same center).
        path: Path {
            startX: metrics.isVertical ? carousel.width / 2 : 0
            startY: metrics.isVertical ? 0 : carousel.height / 2

            // Start of path (Scale 0.95)
            PathAttribute { name: "iconScale"; value: 0.95 }
            PathAttribute { name: "iconZ"; value: 0 }

            // Middle of screen (Scale 1.1, Z-index 100 to stay on top)
            PathLine { x: carousel.width / 2; y: carousel.height / 2 }
            PathAttribute { name: "iconScale"; value: 1.1 }
            PathAttribute { name: "iconZ"; value: 100 }

            // End of path (Scale 0.95)
            PathLine {
                x: metrics.isVertical ? carousel.width / 2 : carousel.width
                y: metrics.isVertical ? carousel.height : carousel.height / 2
            }
            PathAttribute { name: "iconScale"; value: 0.95 }
            PathAttribute { name: "iconZ"; value: 0 }
        }
    }
}