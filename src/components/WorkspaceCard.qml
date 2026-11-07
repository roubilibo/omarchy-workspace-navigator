import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "../lib/WindowGeometry.js" as WindowGeometry
import "../lib/WindowModel.js" as WindowModel

BorderSurface {
  id: root

  required property int workspaceId
  property var workspace: null
  property string workspaceName: ""
  property var previewScreen: null
  property Item contextTarget: null
  property bool focused: false
  property bool showBorder: true
  property bool showBackground: true
  property bool showSelectionFill: true
  property bool addWorkspace: false
  property bool deletable: false
  property bool keyboardSelected: false
  property bool activateOnClick: true
  property bool selectOnHover: true
  property var draggedToplevel: null
  property bool freezeDraggedPreview: false
  property var geometryOverrides: ({})
  property int geometryRevision: 0
  property Item dragOverlay: null
  property bool draggedFromWorkspaceCanvas: false
  property real dragShrinkProgress: 0
  property real dragTargetWidth: 0
  property real dragTargetHeight: 0
  property var selectedToplevel: null
  property bool livePreviews: false
  property bool liveCaptureAll: false
  property int toplevelRevision: 0
  property var toplevelsOverride: null
  property int draggedSourceWorkspaceIdOverride: -1
  signal dragDiagnostic(string eventName, var details)

  readonly property var effectiveToplevels: {
    if (root.toplevelsOverride !== null) return root.toplevelsOverride
    var revision = root.toplevelRevision
    var activeAddress = Hyprland.activeToplevel ? Hyprland.activeToplevel.address : ""
    return WindowModel.resolveWorkspacePreviews(
      root.workspace ? root.workspace.toplevels.values : [], activeAddress)
  }
  readonly property int windowCount: root.effectiveToplevels.length
  readonly property bool occupied: root.windowCount > 0
  readonly property bool hovered: cardHover.hovered
  // The workspace number is an overlay; it must not reserve preview space.
  readonly property real previewInset: 0
  readonly property real previewSpacing: Math.max(1, Number(Style.spacing.xs) || 2)
  readonly property var previewCanvas: WindowGeometry.insetGeometry(
    root.width, root.height, root.previewInset)
  readonly property var workspaceMonitor: root.workspace && root.workspace.monitor
    ? root.workspace.monitor : Hyprland.focusedMonitor
  readonly property var draggedWorkspace: root.draggedToplevel
    ? root.draggedToplevel.workspace : null
  readonly property string draggedToplevelAddress: WindowModel.toplevelAddress(
    root.draggedToplevel)
  readonly property int draggedSourceWorkspaceId:
    root.draggedSourceWorkspaceIdOverride > 0
      ? Number(root.draggedSourceWorkspaceIdOverride)
      : (root.draggedWorkspace ? Number(root.draggedWorkspace.id) : -1)
  readonly property bool validDropTarget: root.draggedToplevel !== null
    && root.draggedToplevelAddress !== ""
    && root.workspaceId > 0
    && root.draggedSourceWorkspaceId !== root.workspaceId
  readonly property bool dropHovered: root.validDropTarget && dropArea.containsDrag
  readonly property bool draggedFloating: root.draggedToplevel
    && root.draggedToplevel.lastIpcObject
    && root.draggedToplevel.lastIpcObject.floating === true

  readonly property int activeBorderWidth: Math.max(Style.space(2), Style.focusBorderWidth)
  readonly property int normalBorderWidth: Math.max(1, Style.normalBorderWidth)
  readonly property var cardBorderSpec: {
    if (root.dropHovered)
      return Border.withWidth(Border.flat(Color.accent, root.activeBorderWidth), root.activeBorderWidth)
    if (root.validDropTarget)
      return Border.withWidth(Border.flat(Util.alpha(Color.accent, 0.55), root.normalBorderWidth), root.normalBorderWidth)
    if (root.focused)
      return Border.flat(Color.accent, root.activeBorderWidth)
    if (root.keyboardSelected)
      return Border.flat(Util.alpha(Color.accent, 0.45), root.normalBorderWidth)
    return Border.flat(Util.alpha(Color.menu.border, 0.34), root.normalBorderWidth)
  }

  signal workspaceActivated()
  signal workspaceContextRequested(real x, real y)
  signal workspaceHovered()
  signal addWorkspaceRequested()
  signal workspaceDeleteRequested()
  signal windowDragStarted(var toplevel, real x, real y)
  signal windowDragMoved(var toplevel, real x, real y,
    real grabRatioX, real grabRatioY, real pointerX, real pointerY)
  signal windowDragFinished(var toplevel)
  signal windowDragEnteredWorkspace(int workspaceId)
  signal windowSelected(var toplevel)
  signal windowActivated(var toplevel)
  signal windowDropped(var toplevel, real x, real y,
    real grabRatioX, real grabRatioY)
  signal windowDroppedOn(var sourceToplevel, var targetToplevel,
    real x, real y, real grabRatioX, real grabRatioY,
    real targetRatioX, real targetRatioY)

  function reportDragDiagnostic(eventName, details) {
    var payload = Object.assign({
      workspaceId: root.workspaceId,
      sourceWorkspaceId: root.draggedSourceWorkspaceId,
      sourceAddress: root.draggedToplevelAddress
    }, details || {})
    root.dragDiagnostic(eventName, payload)
  }

  function isSameToplevel(left, right) {
    if (!left || !right) return false
    if (left === right) return true
    var leftAddress = WindowModel.toplevelAddress(left)
    var rightAddress = WindowModel.toplevelAddress(right)
    return leftAddress !== "" && leftAddress === rightAddress
  }

  function screenForMonitor(monitor) {
    if (!monitor) return root.previewScreen
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++) {
      if (screens[i] && screens[i].name === monitor.name) return screens[i]
    }
    return root.previewScreen
  }

  radius: Style.cornerRadius
  color: root.showBackground
    ? (root.occupied || root.focused
      ? Color.menu.background : (root.addWorkspace
        ? Util.alpha(Color.accent, 0.10)
        : Util.alpha(Color.menu.background, 0.90)))
    : "transparent"
  borderSpec: root.showBorder ? root.cardBorderSpec : Border.none()
  clip: true

  // Left-clicking the card enters the workspace. Window thumbnails sit above
  // this area and own their own left-click/drag behavior; right-click opens
  // the workspace action menu.
  MouseArea {
    anchors.fill: parent
    z: 1
    acceptedButtons: root.addWorkspace
      ? (Qt.LeftButton | Qt.RightButton) : (Qt.LeftButton | Qt.RightButton)
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: if (root.selectOnHover) root.workspaceHovered()
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton && !root.addWorkspace) {
        var point = root.contextTarget
          ? root.mapToItem(root.contextTarget, mouse.x, mouse.y)
          : ({ x: mouse.x, y: mouse.y })
        root.workspaceContextRequested(point.x, point.y)
      } else if (root.addWorkspace) {
        root.addWorkspaceRequested()
      } else if (!root.activateOnClick) {
        root.workspaceHovered()
      } else {
        root.workspaceActivated()
      }
    }
  }

  // An empty card must consume left clicks locally so the click enters the
  // empty workspace instead of bubbling to the overview scrim.
  MouseArea {
    anchors.fill: parent
    z: 15
    visible: !root.occupied && !root.addWorkspace
    acceptedButtons: Qt.LeftButton
    hoverEnabled: true
    cursorShape: Qt.ArrowCursor
    onEntered: if (root.selectOnHover) root.workspaceHovered()
    onClicked: function(mouse) {
      if (mouse.button === Qt.LeftButton) {
        if (root.activateOnClick) root.workspaceActivated()
        else root.workspaceHovered()
      }
      else mouse.accepted = true
    }
  }

  Rectangle {
    anchors.fill: parent
    z: 2
    color: root.dropHovered
      ? Style.selectedFillFor(Color.menu.text, Color.accent)
      : (root.validDropTarget || (root.showSelectionFill && root.keyboardSelected)
        ? Style.hoverFillFor(Color.menu.text, Color.accent) : "transparent")
    Behavior on color { ColorAnimation { duration: 80 } }
  }

  Text {
    visible: !root.addWorkspace && root.workspaceName !== ""
    z: 50
    anchors.left: badge.right
    anchors.leftMargin: Style.space(8)
    anchors.top: parent.top
    anchors.topMargin: Style.space(11)
    width: Math.max(1, root.width - badge.width - Style.space(46))
    text: root.workspaceName
    color: root.focused ? Color.menu.text : Util.alpha(Color.menu.text, 0.82)
    font.family: Style.font.menuFamily
    font.pixelSize: Style.font.bodySmall
    font.bold: root.focused
    elide: Text.ElideRight
  }

  Item {
    id: previewArea
    visible: !root.addWorkspace
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: root.previewInset
    z: 25
    clip: true

    Text {
    visible: !root.occupied && !root.addWorkspace
      anchors.centerIn: parent
      text: "·"
      color: Color.menu.text
      opacity: root.focused ? 0.50 : 0.22
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.displayLarge
    }

    Item {
      id: spatialPreview
      anchors.fill: parent

      Repeater {
        model: root.effectiveToplevels

        WindowPreview {
          required property var modelData
          required property int index

          readonly property var previewToplevel: modelData && modelData.toplevel
            ? modelData.toplevel : modelData
          readonly property var previewGeometryOverride: {
            var revision = root.geometryRevision
            var address = WindowModel.toplevelAddress(previewToplevel)
            return revision >= 0 && address
              ? root.geometryOverrides[address] : null
          }
          readonly property var previewIpc: {
            var override = previewGeometryOverride
            return override || (modelData && modelData.lastIpcObject
              ? modelData.lastIpcObject
              : (previewToplevel ? previewToplevel.lastIpcObject : null))
          }
          readonly property bool previewFloating: previewIpc
            && previewIpc.floating === true
          readonly property var targetMonitor: root.workspaceMonitor
            || (previewToplevel && previewToplevel.monitor
              ? previewToplevel.monitor : Hyprland.focusedMonitor)
          readonly property var targetScreen: root.screenForMonitor(targetMonitor)
          readonly property var measuredGeometry: WindowGeometry.previewGeometry(
            previewIpc, targetMonitor, targetScreen,
            spatialPreview.width, spatialPreview.height,
            Math.min(spatialPreview.width, Math.max(Style.space(50), spatialPreview.width * 0.13)),
            Math.min(spatialPreview.height, Math.max(Style.space(34), spatialPreview.height * 0.18)))
          readonly property var displayGeometry: measuredGeometry.valid
            ? measuredGeometry
            : WindowGeometry.fallbackGeometry(index, root.windowCount,
              spatialPreview.width, spatialPreview.height, root.previewSpacing)

          x: displayGeometry.x
          y: displayGeometry.y
          width: Math.max(1, displayGeometry.width)
          height: Math.max(1, displayGeometry.height)
          // Hyprland paints floating clients above tiled clients. Keep the
          // navigator's stacking order consistent even when the IPC model
          // lists a floating client before a fullscreen-sized tiled client.
          z: (dragging ? 2000 : (previewFloating ? 1000 : 0)) + index + 3
          toplevel: previewToplevel
          homeParent: spatialPreview
          dragOverlay: root.dragOverlay
          dragShrinkProgress: root.draggedFromWorkspaceCanvas
            && root.isSameToplevel(root.draggedToplevel, previewToplevel)
            ? root.dragShrinkProgress : 0
          dragTargetWidth: root.dragTargetWidth
          dragTargetHeight: root.dragTargetHeight
          isGroup: Boolean(modelData && modelData.isGroup)
          groupMembers: modelData && modelData.members ? modelData.members : []
          liveCaptureEnabled: root.livePreviews && root.visible
            && (root.liveCaptureAll || root.hovered
              || root.isSameToplevel(root.draggedToplevel, previewToplevel))
          workspaceFocused: root.focused
          draggedToplevel: root.draggedToplevel
          draggedSourceWorkspaceIdOverride: root.draggedSourceWorkspaceId
          freezeDraggedPreview: root.freezeDraggedPreview
          selectedToplevel: root.selectedToplevel
          onDragStarted: function(toplevel, x, y) {
            root.windowDragStarted(previewToplevel, x, y)
          }
          onDragMoved: function(toplevel, x, y, grabRatioX, grabRatioY) {
            var point = root.dragOverlay
              ? spatialPreview.mapFromItem(root.dragOverlay, x, y)
              : ({ x: x, y: y })
            root.reportDragDiagnostic("preview-coordinate-map", {
              address: WindowModel.toplevelAddress(toplevel),
              overlayPosition: [x, y],
              previewPosition: [point.x, point.y],
              previewSize: [spatialPreview.width, spatialPreview.height]
            })
            root.windowDragMoved(toplevel, point.x, point.y,
              grabRatioX, grabRatioY, x, y)
          }
          onDragFinished: root.windowDragFinished(previewToplevel)
          onDragDiagnostic: function(eventName, details) {
            root.dragDiagnostic(eventName, details)
          }
          onWindowSelected: root.windowSelected(previewToplevel)
          onWindowActivated: root.windowActivated(previewToplevel)
          onWindowDroppedOn: function(sourceToplevel, targetToplevel,
                                      x, y, grabRatioX, grabRatioY,
                                      targetRatioX, targetRatioY) {
            root.windowDroppedOn(sourceToplevel, targetToplevel,
              x, y, grabRatioX, grabRatioY, targetRatioX, targetRatioY)
          }
        }
      }
    }
  }

  // Floating workspace number: this never changes the thumbnail geometry.
  Rectangle {
    id: badge
    visible: !root.addWorkspace
    z: 50
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.topMargin: Style.space(7)
    anchors.leftMargin: Style.space(7)
    width: badgeLabel.implicitWidth + Style.space(16)
    height: badgeLabel.implicitHeight + Style.space(8)
    radius: height / 2
    color: root.focused ? Color.accent
      : (root.keyboardSelected ? Style.selectedFillFor(Color.menu.text, Color.accent)
        : Util.alpha(Color.menu.background, 0.72))

    Text {
      id: badgeLabel
      anchors.centerIn: parent
      text: String(root.workspaceId)
      color: root.focused ? Color.menu.scrim : Color.menu.text
      opacity: root.focused || root.occupied || root.keyboardSelected ? 0.92 : 0.58
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }
  }

  // Added workspaces can be deleted only when empty. This mirrors Hyprland's
  // destroyworkspace safety rule and prevents accidental window removal.
  Rectangle {
    id: deleteButton
    visible: root.deletable
    enabled: root.windowCount === 0
    z: 50
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.topMargin: Style.space(7)
    anchors.rightMargin: Style.space(7)
    width: Style.space(26)
    height: width
    radius: height / 2
    color: deleteMouse.containsMouse
      ? Util.alpha(Color.urgent, 0.92)
      : Util.alpha(Color.menu.background, enabled ? 0.78 : 0.42)
    opacity: enabled ? 1 : 0.5

    Text {
      anchors.centerIn: parent
      text: "×"
      color: enabled ? Color.menu.text : Util.alpha(Color.menu.text, 0.62)
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }

    MouseArea {
      id: deleteMouse
      anchors.fill: parent
      enabled: parent.enabled
      acceptedButtons: Qt.LeftButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.workspaceDeleteRequested()
    }
  }

  Text {
    visible: root.addWorkspace
    anchors.centerIn: parent
    z: 10
    text: "+"
    color: Color.accent
    font.family: Style.font.menuFamily
    font.pixelSize: Style.font.displayLarge
    font.bold: true
  }

  Text {
    visible: root.addWorkspace
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(24)
    z: 10
    text: "Add workspace"
    color: Util.alpha(Color.menu.text, 0.72)
    font.family: Style.font.menuFamily
    font.pixelSize: Style.font.bodySmall
  }

  Text {
    visible: root.validDropTarget && root.dropHovered
    anchors.centerIn: parent
    z: 31
    text: "Drop here"
    color: Color.menu.text
    font.family: Style.font.menuFamily
    font.pixelSize: Style.font.body
    font.bold: true
    style: Text.Outline
    styleColor: Util.alpha(Color.menu.background, 0.88)
  }

  DropArea {
    id: dropArea
    anchors.fill: parent
    // Thumbnail drop targets stay above this area; it handles workspace moves
    // and floating-window drops on otherwise empty parts of the card.
    // Cross-workspace drops cover the card contents. For a same-workspace
    // floating drag, keep this beneath previewArea so thumbnail targets can
    // receive drops (the selected workspace becomes temporarily floating).
    z: root.validDropTarget ? 60 : 24
    keys: ["omarchy-window"]
    enabled: !root.addWorkspace && (root.validDropTarget
      || (root.draggedFloating && root.draggedSourceWorkspaceId === root.workspaceId))

    onEntered: function(drag) {
      root.reportDragDiagnostic("workspace-target-enter", {
        targetKind: "workspace",
        sourceAddress: drag.source && drag.source.toplevel
          ? WindowModel.toplevelAddress(drag.source.toplevel) : ""
      })
      if (root.validDropTarget) root.windowDragEnteredWorkspace(root.workspaceId)
    }

    onExited: root.reportDragDiagnostic("workspace-target-exit", {
      targetKind: "workspace"
    })

    onPositionChanged: function(drag) {
      root.reportDragDiagnostic("workspace-target-position", {
        targetKind: "workspace", localPosition: [drag.x, drag.y],
        containsDrag: dropArea.containsDrag
      })
    }

    onDropped: function(drop) {
      var sameWorkspaceFloating = root.draggedFloating
        && root.draggedSourceWorkspaceId === root.workspaceId
      if ((!root.validDropTarget && !sameWorkspaceFloating)
          || !drop.source || !drop.source.toplevel) {
        root.reportDragDiagnostic("workspace-target-drop-rejected", {
          targetKind: "workspace",
          hasSource: Boolean(drop.source),
          hasToplevel: Boolean(drop.source && drop.source.toplevel),
          validDropTarget: root.validDropTarget,
          sameWorkspaceFloating: sameWorkspaceFloating
        })
        drop.accepted = false
        return
      }
      drop.acceptProposedAction()
      root.reportDragDiagnostic("workspace-target-drop", {
        targetKind: "workspace", localPosition: [drop.x, drop.y],
        floating: root.draggedFloating
      })
      root.windowDropped(drop.source.toplevel, drop.x, drop.y,
        drop.source.dragGrabRatioX, drop.source.dragGrabRatioY)
    }
  }

  HoverHandler {
    id: cardHover
    onHoveredChanged: if (hovered && root.selectOnHover) root.workspaceHovered()
  }

  // Window previews can reach the card edges in a no-gaps workspace and are
  // stacked above BorderSurface's native border. Redraw the focused outline
  // last so thumbnails cannot cover its top (or other) edges.
  Rectangle {
    anchors.fill: parent
    z: 100000
    visible: root.showBorder && root.focused
    color: "transparent"
    radius: root.radius
    border.color: Color.accent
    border.width: root.activeBorderWidth
    antialiasing: true
  }
}
