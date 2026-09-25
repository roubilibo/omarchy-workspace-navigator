import QtQuick
import QtQuick.Layouts
import qs.Commons
import "."

Rectangle {
  id: root

  property bool opened: false
  property string scope: "workspace"
  property var candidates: []
  property int selectedIndex: -1
  property var workspaceLabelFor: null
  signal selectionRequested(int index)
  signal commitRequested()

  visible: root.opened
  z: 20
  anchors.centerIn: parent
  width: Math.min(parent.width - Style.space(48),
    Math.max(Style.space(420), previewRow.implicitWidth + Style.space(48)))
  height: Math.min(parent.height - Style.space(48), Style.space(320))
  radius: Style.cornerRadius
  color: Color.menu.background
  border.width: 1
  border.color: Util.alpha(Color.menu.border, 0.62)

  readonly property real previewWidth: Style.space(240)

  function previewHeight() {
    return Math.max(1, Math.min(Style.space(190),
      previewScroller.height - Style.space(64)))
  }

  function ensureSelectionVisible(index) {
    if (!root.opened || index < 0) return
    var item = previewRepeater.itemAt(index)
    if (!item) {
      Qt.callLater(function() { root.ensureSelectionVisible(index) })
      return
    }

    var left = item.mapToItem(previewScroller.contentItem, 0, 0).x
    var right = left + item.width
    var viewLeft = previewScroller.contentX
    var viewRight = viewLeft + previewScroller.width
    if (left < viewLeft) {
      previewScroller.contentX = Math.max(0, left)
    } else if (right > viewRight) {
      previewScroller.contentX = Math.min(
        Math.max(0, previewScroller.contentWidth - previewScroller.width),
        right - previewScroller.width)
    }
  }

  onOpenedChanged: {
    if (root.opened) Qt.callLater(function() {
      root.ensureSelectionVisible(root.selectedIndex)
    })
  }
  onSelectedIndexChanged: {
    if (root.opened) Qt.callLater(function() {
      root.ensureSelectionVisible(root.selectedIndex)
    })
  }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: Style.space(24)
    spacing: Style.space(12)

    RowLayout {
      Layout.fillWidth: true

      Text {
        Layout.fillWidth: true
        text: "Alt+Tab"
        color: Color.menu.text
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Text {
        text: root.scope === "all" ? "All workspaces" : "Current workspace"
        color: Util.alpha(Color.menu.text, 0.68)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }

    Flickable {
      id: previewScroller
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      contentWidth: Math.max(width, previewRow.width)
      contentHeight: height
      flickableDirection: Flickable.HorizontalFlick
      boundsBehavior: Flickable.StopAtBounds

      Row {
        id: previewRow
        x: Math.max(0, (previewScroller.width - width) / 2)
        height: previewScroller.height
        spacing: Style.space(10)

        Repeater {
          id: previewRepeater
          model: root.candidates

          delegate: AltTabPreview {
            required property var modelData
            required property int index
            readonly property real maxPreviewHeight: root.previewHeight()
            width: Math.min(root.previewWidth,
              maxPreviewHeight * sourceWidth / Math.max(1, sourceHeight))
            height: width * sourceHeight / Math.max(1, sourceWidth)
              + Style.space(64)
            y: (previewScroller.height - height) / 2
            toplevel: modelData
            selected: index === root.selectedIndex
            workspaceLabel: root.workspaceLabelFor
              ? root.workspaceLabelFor(modelData) : ""
            onActivated: {
              root.selectionRequested(index)
              root.commitRequested()
            }
          }
        }
      }
    }
  }
}
