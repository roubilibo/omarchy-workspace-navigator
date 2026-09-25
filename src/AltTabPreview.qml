import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "WindowModel.js" as WindowModel

Rectangle {
  id: root

  required property var toplevel
  property bool selected: false
  property string workspaceLabel: ""
  signal activated()

  // Keep the caption area stable while the preview itself follows the
  // compositor window ratio. A variable caption height made short cards look
  // as if the screenshot was clipped at the top and bottom.
  readonly property real metadataHeight: Math.min(Style.space(64), Math.max(1, height))
  readonly property var waylandToplevel: toplevel ? toplevel.wayland : null
  readonly property real sourceWidth: root.sourceDimension(0)
  readonly property real sourceHeight: root.sourceDimension(1)
  readonly property string appId: root.appIdFor(root.toplevel)
  readonly property string title: root.titleFor(root.toplevel)
  readonly property string iconSource: root.iconFor(root.toplevel)

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
    var title = top.title ? String(top.title) : ""
    var ipc = top.lastIpcObject
    if (!title && ipc && ipc.title) title = String(ipc.title)
    if (!title) title = root.appIdFor(top) || "Window"
    title = title.replace(/[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]/g, " ")
    return title.length > 256 ? title.slice(0, 255) + "…" : title
  }

  function iconFor(top) {
    var id = root.appIdFor(top)
    if (!id) return ""
    var entry = DesktopEntries.byId(id) || DesktopEntries.heuristicLookup(id)
    if (!entry || !entry.icon) return ""
    return Quickshell.iconPath(entry.icon, true)
  }

  function sourceDimension(axis) {
    // The capture buffer is authoritative for the pixels we paint. Using it
    // first avoids a fractional-scale mismatch where the IPC geometry and
    // the screencopy buffer differ by a few pixels and the frame gets clipped.
    if (preview && preview.hasContent && preview.sourceSize) {
      var captureValue = Number(axis === 0
        ? preview.sourceSize.width : preview.sourceSize.height)
      if (isFinite(captureValue) && captureValue > 0) return captureValue
    }
    var ipc = root.toplevel ? root.toplevel.lastIpcObject : null
    var size = ipc && ipc.size && ipc.size.length >= 2 ? ipc.size : null
    if (size) {
      var ipcValue = Number(size[axis])
      if (isFinite(ipcValue) && ipcValue > 0) return ipcValue
    }
    return 1
  }

  radius: Style.cornerRadius
  color: Util.alpha(Color.menu.background, 0.82)
  // Windows-style Alt+Tab selection: a clear accent outline kept inside the
  // card, so it remains visible without scaling beyond the clipped viewport.
  border.width: root.selected ? Math.max(2, Style.focusBorderWidth) : Style.normalBorderWidth
  border.color: root.selected ? Color.accent : Util.alpha(Color.menu.border, 0.42)
  clip: true

  Item {
    id: previewViewport
    anchors.fill: parent
    clip: true

    Item {
      id: previewFrame
      width: root.sourceWidth
      height: root.sourceHeight
      readonly property real fitScale: Math.min(
        parent.width / Math.max(1, width),
        Math.max(1, parent.height - root.metadataHeight)
          / Math.max(1, height))
      x: (parent.width - width * fitScale) / 2
      y: (parent.height - root.metadataHeight - height * fitScale) / 2
      transform: Scale {
        origin.x: 0
        origin.y: 0
        xScale: previewFrame.fitScale
        yScale: previewFrame.fitScale
      }

      ScreencopyView {
        id: preview
        anchors.fill: parent
        captureSource: root.waylandToplevel
        live: root.selected
        paintCursor: false
        visible: hasContent
      }
    }

    Rectangle {
      id: metadataPanel
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: root.metadataHeight
      color: root.selected
        ? Style.selectedFillFor(Color.menu.text, Color.accent)
        : Util.alpha(Color.menu.background, 0.96)

      Image {
        id: appIcon
        visible: root.iconSource !== ""
        anchors.left: parent.left
        anchors.leftMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(26)
        height: width
        source: root.iconSource
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
      }

      Text {
        anchors.left: appIcon.visible ? appIcon.right : parent.left
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.top: parent.top
        anchors.topMargin: Style.space(10)
        text: root.title
        color: Color.menu.text
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        anchors.left: appIcon.visible ? appIcon.right : parent.left
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.space(10)
        text: root.workspaceLabel
        color: Util.alpha(Color.menu.text, 0.62)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
    }
  }

  TapHandler {
    onTapped: root.activated()
  }
}
