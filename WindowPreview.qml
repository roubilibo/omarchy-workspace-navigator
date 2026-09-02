import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "WindowModel.js" as WindowModel

// A compositor-backed thumbnail. The tiny Drag source is deliberate: it lets
// a DragHandler keep the thumbnail in place while DropArea receives the drag.
Rectangle {
  id: root

  required property var toplevel
  property bool isGroup: false
  property var groupMembers: []
  property var draggedToplevel: null
  property var selectedToplevel: null
  property bool liveCaptureEnabled: false

  readonly property var waylandToplevel: toplevel ? toplevel.wayland : null
  // Some clients (notably GTK/Nautilus) expose the Hyprland address through
  // lastIpcObject instead of the direct toplevel property. Use the same
  // resolver as move/swap so those thumbnails are draggable too.
  readonly property bool movable: toplevel !== null
    && WindowModel.toplevelAddress(toplevel) !== ""
  // Cross-workspace drops belong to the workspace card. Keeping this drop
  // area limited to same-workspace targets prevents a thumbnail from
  // intercepting the card-level move handler.
  readonly property bool sameWorkspace: root.draggedToplevel !== null
    && root.draggedToplevel.workspace !== null
    && root.toplevel.workspace !== null
    && Number(root.draggedToplevel.workspace.id)
      === Number(root.toplevel.workspace.id)
  readonly property bool dragging: dragProxy.dragSessionActive
  readonly property bool selected: root.selectedToplevel !== null
    && root.isSameToplevel(root.selectedToplevel, root.toplevel)
  readonly property string appId: root.appIdFor(toplevel)
  readonly property string title: root.titleFor(toplevel)
  readonly property string iconSource: root.iconFor(toplevel)

  signal dragStarted(var toplevel)
  signal dragFinished(var toplevel)
  signal windowSelected(var toplevel)
  signal windowDroppedOn(var sourceToplevel, var targetToplevel)

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
    if (top.title) return String(top.title)
    var ipc = top.lastIpcObject
    if (ipc && ipc.title) return String(ipc.title)
    return appIdFor(top) || "Window"
  }

  function iconFor(top) {
    var id = appIdFor(top)
    if (!id) return ""
    var entry = DesktopEntries.byId(id) || DesktopEntries.heuristicLookup(id)
    if (!entry || !entry.icon) return ""
    return Quickshell.iconPath(entry.icon, true)
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
  opacity: root.dragging ? 0.58 : 1

  Item {
    id: previewViewport
    anchors.fill: parent
    clip: true

    // ScreencopyView preserves the source aspect ratio while painting. Keep
    // its own frame at the native source ratio, then stretch that frame to
    // the projected workspace rectangle so the card has no letterbox gaps.
    Item {
      id: previewFrame
      width: preview.hasContent && preview.sourceSize.width > 0
        ? preview.sourceSize.width : parent.width
      height: preview.hasContent && preview.sourceSize.height > 0
        ? preview.sourceSize.height : parent.height
      transform: Scale {
        origin.x: 0
        origin.y: 0
        xScale: previewViewport.width / Math.max(1, previewFrame.width)
        yScale: previewViewport.height / Math.max(1, previewFrame.height)
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

    Image {
      visible: !preview.hasContent && root.iconSource !== ""
      anchors.centerIn: parent
      width: Math.min(parent.width, parent.height) * 0.34
      height: width
      source: root.iconSource
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      smooth: true
      opacity: 0.72
    }

    Text {
      visible: !preview.hasContent && root.iconSource === ""
      anchors.centerIn: parent
      width: parent.width - Style.space(16)
      text: root.title
      color: Util.alpha(Color.menu.text, 0.78)
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
    }
  }

  Rectangle {
    anchors.fill: parent
    z: 5
    border.width: previewHover.hovered || root.dragging || root.selected
      || windowDropArea.containsDrag
      ? Math.max(1, Style.normalBorderWidth) : 0
    border.color: root.dragging || windowDropArea.containsDrag
      ? Color.accent : (root.selected ? Color.accent
        : Util.alpha(Color.menu.text, 0.62))
    color: root.selected && !root.dragging && !windowDropArea.containsDrag
      ? Util.alpha(Color.accent, 0.22) : "transparent"
    radius: root.radius
  }

  // A drop on another thumbnail is an in-workspace layout operation. The
  // parent overview decides whether it means a swap or a workspace move.
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
      root.windowDroppedOn(drop.source.toplevel, root.toplevel)
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
    onTapped: root.windowSelected(root.toplevel)
  }

  DragHandler {
    id: previewDrag
    acceptedButtons: Qt.LeftButton
    enabled: root.movable
    target: null
    dragThreshold: Style.space(6)

    onActiveChanged: {
      if (active) {
        dragProxy.dragSessionActive = true
        root.dragStarted(root.toplevel)
      } else if (dragProxy.dragSessionActive) {
        dragProxy.Drag.drop()
        dragProxy.dragSessionActive = false
        root.dragFinished(root.toplevel)
      }
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
}
