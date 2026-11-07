import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "../lib/WindowModel.js" as WindowModel

// A compositor-backed thumbnail. The tiny Drag source is deliberate: it lets
// a DragHandler keep the thumbnail in place while DropArea receives the drag.
Rectangle {
  id: root

  required property var toplevel
  property bool isGroup: false
  property var groupMembers: []
  property var draggedToplevel: null
  property int draggedSourceWorkspaceIdOverride: -1
  property bool freezeDraggedPreview: false
  property Item homeParent: null
  property Item dragOverlay: null
  property real dragShrinkProgress: 0
  property real dragTargetWidth: 0
  property real dragTargetHeight: 0
  property var selectedToplevel: null
  property bool liveCaptureEnabled: false
  property bool workspaceFocused: false
  property real dragGrabRatioX: 0.5
  property real dragGrabRatioY: 0.5
  property real dragStartX: 0
  property real dragStartY: 0
  property real dragStartWidth: 1
  property real dragStartHeight: 1
  property real dragLastTranslationX: 0
  property real dragLastTranslationY: 0

  readonly property var waylandToplevel: toplevel ? toplevel.wayland : null
  // Some clients (notably GTK/Nautilus) expose the Hyprland address through
  // lastIpcObject instead of the direct toplevel property. Use the same
  // address resolver as window moves so those thumbnails remain draggable.
  readonly property bool movable: toplevel !== null
    && WindowModel.toplevelAddress(toplevel) !== ""
  // Cross-workspace drops belong to the workspace card. Keeping this drop
  // area limited to same-workspace targets prevents a thumbnail from
  // intercepting the card-level move handler.
  readonly property int draggedSourceWorkspaceId:
    root.draggedSourceWorkspaceIdOverride > 0
      ? Number(root.draggedSourceWorkspaceIdOverride)
      : (root.draggedToplevel && root.draggedToplevel.workspace
        ? Number(root.draggedToplevel.workspace.id) : -1)
  readonly property bool sameWorkspace: root.draggedToplevel !== null
    && root.draggedSourceWorkspaceId > 0
    && root.toplevel.workspace !== null
    && root.draggedSourceWorkspaceId === Number(root.toplevel.workspace.id)
  readonly property bool dragging: dragProxy.dragSessionActive
  readonly property real dragTranslationX: root.dragging
    ? root.dragLastTranslationX : 0
  readonly property real dragTranslationY: root.dragging
    ? root.dragLastTranslationY : 0
  readonly property bool selected: root.selectedToplevel !== null
    && root.isSameToplevel(root.selectedToplevel, root.toplevel)
  readonly property string appId: root.appIdFor(toplevel)
  readonly property string title: root.titleFor(toplevel)

  readonly property int maximumTitleLength: 512

  signal dragStarted(var toplevel, real x, real y)
  signal dragMoved(var toplevel, real x, real y,
    real grabRatioX, real grabRatioY)
  signal dragFinished(var toplevel)
  signal windowSelected(var toplevel)
  signal windowActivated(var toplevel)
  signal windowDroppedOn(var sourceToplevel, var targetToplevel,
    real x, real y, real grabRatioX, real grabRatioY)

  function appIdFor(top) {
    if (!top) return ""
    var wayland = top.wayland
    if (wayland && wayland.appId) return String(wayland.appId)
    var ipc = top.lastIpcObject
    if (ipc && ipc.initialClass) return String(ipc.initialClass)
    if (ipc && ipc.class) return String(ipc.class)
    return ""
  }

  function titleFor(top) {
    if (!top) return "Window"
    var title = ""
    if (top.title) title = String(top.title)
    var ipc = top.lastIpcObject
    if (!title && ipc && ipc.title) title = String(ipc.title)
    if (!title) title = appIdFor(top) || "Window"

    // Window titles are compositor-provided input. Keep control and bidi
    // characters from affecting layout or making the displayed title
    // misleading, and cap the amount of text used by TextMetrics/Text.
    title = title.replace(/[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]/g, " ")
    if (title.length > root.maximumTitleLength)
      title = title.slice(0, root.maximumTitleLength - 1) + "…"
    return title
  }

  function isSameToplevel(left, right) {
    if (!left || !right) return false
    if (left === right) return true
    var leftAddress = WindowModel.toplevelAddress(left)
    var rightAddress = WindowModel.toplevelAddress(right)
    return leftAddress !== "" && leftAddress === rightAddress
  }

  TextMetrics {
    id: titleMetrics
    text: root.title
    font.family: Style.font.menuFamily
    font.pixelSize: Style.font.bodySmall
  }

  readonly property real pillHeight: Math.max(Style.space(24),
    titleMetrics.height + Style.space(8))

  radius: Style.cornerRadius
  color: Util.alpha(Color.background, 0.58)
  clip: true
  // The source is hidden while dragging. Keep the live proxy fully opaque so
  // shrinking it does not wash out its corner mask and border.
  opacity: 1

  Item {
    id: previewViewport
    anchors.fill: parent
    clip: true
    layer.enabled: preview.hasContent
    layer.smooth: true
    layer.effect: MultiEffect {
      maskEnabled: true
      maskSource: roundedPreviewMask
      maskThresholdMin: 0.3
      maskSpreadAtMin: 0.3
    }

    // Fill the projected window geometry without distorting the capture.
    // Scale uniformly to cover the viewport and let its clip trim the excess.
    Item {
      id: previewFrame
      width: preview.hasContent && preview.sourceSize.width > 0
        ? preview.sourceSize.width : parent.width
      height: preview.hasContent && preview.sourceSize.height > 0
        ? preview.sourceSize.height : parent.height
      readonly property real coverScale: Math.max(
        previewViewport.width / Math.max(1, width),
        previewViewport.height / Math.max(1, height))
      x: (previewViewport.width - width * coverScale) / 2
      y: (previewViewport.height - height * coverScale) / 2
      transform: Scale {
        origin.x: 0
        origin.y: 0
        xScale: previewFrame.coverScale
        yScale: previewFrame.coverScale
      }

      ScreencopyView {
        id: preview
        anchors.fill: parent
        captureSource: root.waylandToplevel
        live: root.liveCaptureEnabled
        paintCursor: false
        visible: hasContent
      }
    }

    Text {
      visible: !preview.hasContent
      anchors.centerIn: parent
      width: parent.width - Style.space(16)
      text: root.title
      textFormat: Text.PlainText
      color: Util.alpha(Color.menu.text, 0.78)
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
    }
  }

  Item {
    id: roundedPreviewMask
    anchors.fill: previewViewport
    visible: false
    layer.enabled: preview.hasContent

    Rectangle {
      anchors.fill: parent
      radius: root.radius
      color: "white"
      antialiasing: true
    }
  }

  Rectangle {
    id: previewBorder
    anchors.fill: parent
    z: 5
    visible: !root.dragging
    border.width: Math.max(1, Style.normalBorderWidth)
      + (root.workspaceFocused ? Style.space(1) : 0)
    border.color: previewHover.hovered || root.dragging || root.selected
      || windowDropArea.containsDrag
      ? Color.accent
      : Util.alpha(Color.menu.text, 0.62)
    color: root.selected && !root.dragging && !windowDropArea.containsDrag
      ? Util.alpha(Color.accent, 0.22) : "transparent"
    radius: root.radius
  }

  // The parent overview applies the workspace and floating-window drop rules.
  DropArea {
    id: windowDropArea
    anchors.fill: parent
    z: 50
    keys: ["omarchy-window"]
    enabled: root.sameWorkspace
      && !root.isSameToplevel(root.draggedToplevel, root.toplevel)

    onDropped: function(drop) {
      if (!drop.source || !drop.source.toplevel) {
        drop.accepted = false
        return
      }
      drop.acceptProposedAction()
      var point = root.mapToItem(root.parent, drop.x, drop.y)
      root.windowDroppedOn(drop.source.toplevel, root.toplevel,
        point.x, point.y, drop.source.dragGrabRatioX,
        drop.source.dragGrabRatioY)
    }
  }

  // Group tabs stay inside the same thumbnail, as in Mirador. A grouped
  // window is still dragged as one compositor toplevel.
  Rectangle {
    id: groupTabBar
    visible: root.isGroup && root.groupMembers.length > 1
      && root.width >= Style.space(90) && root.height >= Style.space(55)
    z: 10
    anchors.top: parent.top
    anchors.horizontalCenter: parent.horizontalCenter
    width: Math.min(parent.width - Style.space(6), tabRow.implicitWidth + Style.space(8))
    height: Math.max(Style.space(24), titleMetrics.height + Style.space(6))
    radius: height / 2
    color: Util.alpha(Color.menu.background, 0.88)
    border.width: 1
    border.color: Util.alpha(Color.menu.border, 0.22)
    clip: true

    Row {
      id: tabRow
      anchors.fill: parent
      anchors.margins: 1
      spacing: 1

      Repeater {
        model: root.groupMembers

        Rectangle {
          required property var modelData
          readonly property bool current: root.isSameToplevel(modelData, root.toplevel)
          readonly property string tabTitle: root.titleFor(modelData)
          width: Math.max(1, (tabRow.width - tabRow.spacing * (root.groupMembers.length - 1))
            / root.groupMembers.length)
          height: parent.height
          radius: Math.max(2, height / 2 - 1)
          color: current ? Util.alpha(Color.accent, 0.34) : "transparent"

          Text {
            anchors.fill: parent
            anchors.leftMargin: Style.space(5)
            anchors.rightMargin: Style.space(5)
            text: tabTitle
            textFormat: Text.PlainText
            color: Color.menu.text
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: current
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
          }

        }
      }
    }
  }

  Rectangle {
    visible: !groupTabBar.visible && root.width >= Style.space(72)
      && root.height >= root.pillHeight * 1.8
    z: 10
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(4)
    width: Math.min(parent.width - Style.space(8), titleMetrics.width + Style.space(18))
    height: root.pillHeight
    radius: height / 2
    color: Util.alpha(Color.menu.background, 0.86)

    Text {
      anchors.fill: parent
      anchors.leftMargin: Style.space(9)
      anchors.rightMargin: Style.space(9)
      text: root.title
      textFormat: Text.PlainText
      color: Color.menu.text
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: Text.AlignHCenter
    }
  }

  HoverHandler {
    id: previewHover
    cursorShape: root.dragging ? Qt.ClosedHandCursor
      : (root.movable ? Qt.PointingHandCursor : Qt.ArrowCursor)
  }

  // Select only inside the overview. Focusing the compositor window here
  // would switch workspaces and is the source of cursor warps.
  TapHandler {
    acceptedButtons: Qt.LeftButton
    onTapped: {
      root.windowSelected(root.toplevel)
      root.windowActivated(root.toplevel)
    }
  }

  DragHandler {
    id: previewDrag
    acceptedButtons: Qt.LeftButton
    enabled: root.movable
    target: null
    dragThreshold: Style.space(6)

    onActiveChanged: {
      if (active) {
        var start = root.dragOverlay
          ? root.mapToItem(root.dragOverlay, 0, 0) : ({ x: root.x, y: root.y })
        root.dragStartX = start.x
        root.dragStartY = start.y
        root.dragLastTranslationX = 0
        root.dragLastTranslationY = 0
        root.dragStartWidth = root.width
        root.dragStartHeight = root.height
        root.dragGrabRatioX = Math.max(0, Math.min(1,
          previewDrag.centroid.pressPosition.x / Math.max(1, root.width)))
        root.dragGrabRatioY = Math.max(0, Math.min(1,
          previewDrag.centroid.pressPosition.y / Math.max(1, root.height)))
        dragProxy.dragSessionActive = true
        root.dragStarted(root.toplevel,
          root.dragStartX + previewDrag.centroid.pressPosition.x,
          root.dragStartY + previewDrag.centroid.pressPosition.y)
      } else if (dragProxy.dragSessionActive) {
        dragProxy.Drag.drop()
        dragProxy.dragSessionActive = false
        root.dragFinished(root.toplevel)
      }
    }

    onTranslationChanged: {
      if (!active) return
      root.dragLastTranslationX = previewDrag.translation.x
      root.dragLastTranslationY = previewDrag.translation.y
      root.dragMoved(root.toplevel,
        root.dragStartX + previewDrag.centroid.pressPosition.x
          + previewDrag.translation.x,
        root.dragStartY + previewDrag.centroid.pressPosition.y
          + previewDrag.translation.y,
        root.dragGrabRatioX, root.dragGrabRatioY)
    }
  }

  Component.onDestruction: {
    // Moving a tiled client updates Hyprland's model during the gesture. If
    // that update destroys this delegate, DragHandler may never report its
    // usual inactive transition, leaving the client in the private drag
    // workspace. Finish through the same recovery path before this delegate
    // goes away.
    if (dragProxy.dragSessionActive) {
      dragProxy.dragSessionActive = false
      root.dragFinished(root.toplevel)
    }
  }

  Item {
    id: dragProxy
    property bool dragSessionActive: false
    property real lastX: 0
    property real lastY: 0

    x: previewDrag.active ? previewDrag.centroid.position.x : lastX
    y: previewDrag.active ? previewDrag.centroid.position.y : lastY
    width: 1
    height: 1
    onXChanged: if (previewDrag.active) lastX = x
    onYChanged: if (previewDrag.active) lastY = y
    Drag.active: dragSessionActive
    Drag.source: root
    Drag.keys: ["omarchy-window"]
    Drag.supportedActions: Qt.MoveAction
    Drag.proposedAction: Qt.MoveAction
  }

  // Keep the pointer-grabbing item under its original parent for the whole
  // gesture. Reparenting it on drag start cancels DragHandler's pointer grab
  // on some Qt Quick backends. Keep the copy outside the source subtree so its
  // live snapshot cannot recurse back into itself.
  ShaderEffectSource {
    id: dragVisual
    parent: root.dragOverlay
    readonly property real fittedTargetScale: Math.max(0.01, Math.min(1,
      Math.min(root.dragTargetWidth / Math.max(1, root.dragStartWidth),
        root.dragTargetHeight / Math.max(1, root.dragStartHeight))))
    // Interpolate uniformly to the largest size that fits the strip card, so
    // the window keeps its own aspect ratio and ends at thumbnail scale.
    readonly property real targetScale: 1
      - (1 - fittedTargetScale)
        * Math.max(0, Math.min(1, root.dragShrinkProgress))
    width: root.dragging ? root.dragStartWidth * targetScale : root.width
    height: root.dragging ? root.dragStartHeight * targetScale : root.height
    x: root.dragging
      ? root.dragStartX + root.dragTranslationX
        + (root.dragStartWidth - width) * root.dragGrabRatioX : 0
    y: root.dragging
      ? root.dragStartY + root.dragTranslationY
        + (root.dragStartHeight - height) * root.dragGrabRatioY : 0
    z: 1000000
    visible: root.dragging && root.dragOverlay !== null
    sourceItem: root
    live: root.dragging && !root.freezeDraggedPreview
    hideSource: root.dragging

    Behavior on width {
      NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
    }
    Behavior on height {
      NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
    }
  }

  // Draw the accent outline once, at the snapshot's actual animated scale.
  // Leave the snapshot as a direct ShaderEffectSource; applying an effect
  // layer here can make its live texture disappear during a drag.
  Rectangle {
    id: dragVisualBorder
    parent: root.dragOverlay
    readonly property real renderedScale: Math.max(0.01, Math.min(
      width / Math.max(1, root.dragStartWidth),
      height / Math.max(1, root.dragStartHeight)))
    x: dragVisual.x
    y: dragVisual.y
    width: dragVisual.width
    height: dragVisual.height
    z: dragVisual.z + 1
    visible: dragVisual.visible
    color: "transparent"
    radius: Math.min(root.radius * renderedScale,
      Math.min(width, height) / 2)
    border.width: Math.max(1,
      (Style.normalBorderWidth + Style.space(1)) * renderedScale)
    border.color: Color.accent
    antialiasing: true
  }

  parent: root.homeParent
}
