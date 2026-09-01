import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "WindowGeometry.js" as WindowGeometry
import "WindowModel.js" as WindowModel

BorderSurface {
  id: root

  required property int workspaceId
  property var workspace: null
  property var previewScreen: null
  property bool focused: false
  property bool addWorkspace: false
  property bool deletable: false
  property bool keyboardSelected: false
  property var draggedToplevel: null
  property var selectedToplevel: null
  property bool livePreviews: false
  property int toplevelRevision: 0

  readonly property var effectiveToplevels: {
    var revision = root.toplevelRevision
    var activeAddress = Hyprland.activeToplevel ? Hyprland.activeToplevel.address : ""
    return WindowModel.resolveWorkspacePreviews(
      root.workspace ? root.workspace.toplevels.values : [], activeAddress)
  }
  readonly property int windowCount: root.effectiveToplevels.length
  readonly property bool occupied: root.windowCount > 0
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
  readonly property int draggedSourceWorkspaceId: root.draggedWorkspace
    ? Number(root.draggedWorkspace.id) : -1
  readonly property bool validDropTarget: root.draggedToplevel !== null
    && root.draggedToplevelAddress !== ""
    && root.workspaceId > 0
    && root.draggedSourceWorkspaceId !== root.workspaceId
  readonly property bool dropHovered: root.validDropTarget && dropArea.containsDrag

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
    return Border.flat(Util.alpha(Color.menu.border, 0.14), root.normalBorderWidth)
  }

  signal workspaceActivated()
  signal workspaceHovered()
  signal addWorkspaceRequested()
  signal workspaceDeleteRequested()
  signal windowDragStarted(var toplevel)
  signal windowDragFinished(var toplevel)
  signal windowSelected(var toplevel)
  signal windowDropped(var toplevel)
  signal windowDroppedOn(var sourceToplevel, var targetToplevel)

  function screenForMonitor(monitor) {
    if (!monitor) return root.previewScreen
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++) {
      if (screens[i] && screens[i].name === monitor.name) return screens[i]
    }
    return root.previewScreen
  }

  radius: Style.cornerRadius
  color: root.occupied || root.focused
    ? Color.menu.background : (root.addWorkspace
      ? Util.alpha(Color.accent, 0.10)
      : Util.alpha(Color.menu.background, 0.72))
  borderSpec: root.cardBorderSpec
  clip: true

  // Workspace entry is intentionally right-click only. Left-drag belongs to
  // the window thumbnails; left-clicking an empty area is a no-op.
  MouseArea {
    anchors.fill: parent
    z: 1
    acceptedButtons: root.addWorkspace
      ? (Qt.LeftButton | Qt.RightButton) : Qt.RightButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: root.workspaceHovered()
    onClicked: {
      if (root.addWorkspace) root.addWorkspaceRequested()
      else root.workspaceActivated()
    }
  }

  // An empty card must consume left clicks locally. Otherwise the click
  // bubbles to the overview scrim, which dismisses the panel and leaves the
  // compositor on the previously active workspace.
  MouseArea {
    anchors.fill: parent
    z: 15
    visible: !root.occupied && !root.addWorkspace
    acceptedButtons: Qt.LeftButton
    hoverEnabled: true
    cursorShape: Qt.ArrowCursor
    onEntered: root.workspaceHovered()
    onClicked: function(mouse) { mouse.accepted = true }
  }

  Rectangle {
    anchors.fill: parent
    z: 2
    color: root.dropHovered
      ? Style.selectedFillFor(Color.menu.text, Color.accent)
      : (root.validDropTarget || root.keyboardSelected
        ? Style.hoverFillFor(Color.menu.text, Color.accent) : "transparent")
    Behavior on color { ColorAnimation { duration: 80 } }
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
          readonly property var previewIpc: modelData && modelData.lastIpcObject
            ? modelData.lastIpcObject
            : (previewToplevel ? previewToplevel.lastIpcObject : null)
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
          z: index + 3
          toplevel: previewToplevel
          isGroup: Boolean(modelData && modelData.isGroup)
          groupMembers: modelData && modelData.members ? modelData.members : []
          liveCaptureEnabled: root.livePreviews && root.visible
          draggedToplevel: root.draggedToplevel
          selectedToplevel: root.selectedToplevel
          onDragStarted: root.windowDragStarted(previewToplevel)
          onDragFinished: root.windowDragFinished(previewToplevel)
          onWindowSelected: root.windowSelected(previewToplevel)
          onWindowDroppedOn: function(sourceToplevel, targetToplevel) {
            root.windowDroppedOn(sourceToplevel, targetToplevel)
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
      : (root.keyboardSelected ? Util.alpha(Color.menu.text, 0.18)
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
    z: 20
    keys: ["omarchy-window"]
    enabled: root.validDropTarget && !root.addWorkspace

    onDropped: function(drop) {
      if (!root.validDropTarget || !drop.source || !drop.source.toplevel) {
        drop.accepted = false
        return
      }
      drop.acceptProposedAction()
      root.windowDropped(drop.source.toplevel)
    }
  }
}
