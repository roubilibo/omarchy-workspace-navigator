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

  readonly property real maxPopupWidth: Math.max(1, parent.width - Style.space(48))
  readonly property real maxPopupHeight: Math.max(1, parent.height - Style.space(48))
  readonly property real cardGap: Style.space(12)
  readonly property real minCellWidth: Style.space(144)
  readonly property real maxCellWidth: Style.space(240)
  readonly property real cellHeight: Style.space(220)
  readonly property int maxVisibleRows: 2
  readonly property int candidateCount: root.candidates ? root.candidates.length : 0
  // Keep the bottom row larger for up to 10 windows (5 -> 2/3, 6 -> 2/4).
  // Larger sets wrap into balanced rows, with any remainder placed below.
  readonly property int topRowCount: Math.max(0,
    root.candidateCount - (Math.floor(root.candidateCount / 2) + 1))
  readonly property int bottomRowCount: root.candidateCount - root.topRowCount
  readonly property int overflowColumnLimit: Math.max(1, Math.min(5, Math.floor(
    (root.maxPopupWidth - Style.space(48) + root.cardGap)
      / (root.minCellWidth + root.cardGap))))
  readonly property int rowCount: root.candidateCount > 10
    ? Math.ceil(root.candidateCount / root.overflowColumnLimit)
    : (root.topRowCount > 0 ? 2 : 1)
  readonly property int columnCount: root.candidateCount > 10
    ? Math.ceil(root.candidateCount / root.rowCount)
    : Math.max(1, Math.max(root.topRowCount, root.bottomRowCount))
  readonly property real cellWidth: Math.min(root.maxCellWidth,
    Math.max(1, (root.maxPopupWidth - Style.space(48)
      - root.cardGap * (root.columnCount - 1)) / root.columnCount))
  readonly property real gridWidth: root.columnCount * root.cellWidth
    + root.cardGap * (root.columnCount - 1)
  readonly property real gridHeight: root.rowCount * root.cellHeight
    + root.cardGap * (root.rowCount - 1)
  readonly property int visibleRowCount: Math.min(root.rowCount, root.maxVisibleRows)
  readonly property real visibleGridHeight: root.visibleRowCount * root.cellHeight
    + root.cardGap * (root.visibleRowCount - 1)

  visible: root.opened
  z: 20
  anchors.centerIn: parent
  width: Math.min(root.maxPopupWidth, Math.max(
    Math.min(Style.space(420), root.maxPopupWidth),
    root.gridWidth + Style.space(48)))
  height: Math.min(root.maxPopupHeight,
    root.visibleGridHeight + Style.space(84))
  radius: Style.cornerRadius
  color: Color.menu.background
  border.width: 1
  border.color: Util.alpha(Color.menu.border, 0.62)

  function rowLength(row) {
    if (root.candidateCount <= 10) {
      if (root.rowCount === 1) return root.bottomRowCount
      return row === 0 ? root.topRowCount : root.bottomRowCount
    }

    var baseLength = Math.floor(root.candidateCount / root.rowCount)
    var remainder = root.candidateCount % root.rowCount
    var regularRows = root.rowCount - remainder
    return baseLength + (row >= regularRows ? 1 : 0)
  }

  function rowStart(row) {
    if (root.candidateCount <= 10) {
      if (root.rowCount === 1 || row === 0) return 0
      return root.topRowCount
    }

    var baseLength = Math.floor(root.candidateCount / root.rowCount)
    var remainder = root.candidateCount % root.rowCount
    var regularRows = root.rowCount - remainder
    if (row < regularRows) return row * baseLength
    return regularRows * baseLength
      + (row - regularRows) * (baseLength + 1)
  }

  function cardRow(index) {
    if (root.candidateCount <= 10)
      return root.topRowCount > 0 && index >= root.topRowCount ? 1 : 0

    var baseLength = Math.floor(root.candidateCount / root.rowCount)
    var remainder = root.candidateCount % root.rowCount
    var regularRows = root.rowCount - remainder
    var regularItems = regularRows * baseLength
    if (index < regularItems) return Math.floor(index / baseLength)
    return regularRows + Math.floor((index - regularItems) / (baseLength + 1))
  }

  function cardX(index) {
    var row = root.cardRow(index)
    var rowLength = root.rowLength(row)
    var column = index - root.rowStart(row)
    var rowWidth = rowLength * root.cellWidth
      + root.cardGap * Math.max(0, rowLength - 1)
    return Math.max(0, (root.gridWidth - rowWidth) / 2)
      + column * (root.cellWidth + root.cardGap)
  }

  function cardY(index) {
    return root.cardRow(index) * (root.cellHeight + root.cardGap)
  }

  function ensureSelectionVisible(index) {
    if (!root.opened || index < 0) return
    var item = previewRepeater.itemAt(index)
    if (!item) {
      Qt.callLater(function() { root.ensureSelectionVisible(index) })
      return
    }

    var top = item.mapToItem(previewScroller.contentItem, 0, 0).y
    var bottom = top + item.height
    var viewTop = previewScroller.contentY
    var viewBottom = viewTop + previewScroller.height
    if (top < viewTop) {
      previewScroller.contentY = Math.max(0, top)
    } else if (bottom > viewBottom) {
      previewScroller.contentY = Math.min(
        Math.max(0, previewScroller.contentHeight - previewScroller.height),
        bottom - previewScroller.height)
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
      contentWidth: width
      contentHeight: previewGrid.height
      flickableDirection: Flickable.VerticalFlick
      boundsBehavior: Flickable.StopAtBounds

      Item {
        id: previewGrid
        width: root.gridWidth
        height: root.gridHeight
        x: Math.max(0, (previewScroller.width - width) / 2)

        Repeater {
          id: previewRepeater
          model: root.candidates

          delegate: Item {
            required property var modelData
            required property int index
            width: root.cellWidth
            height: root.cellHeight
            x: root.cardX(index)
            y: root.cardY(index)

            AltTabPreview {
              anchors.centerIn: parent
              readonly property real aspectRatio:
                sourceWidth / Math.max(1, sourceHeight)
              width: Math.min(parent.width,
                Math.max(1, parent.height - Style.space(64)) * aspectRatio)
              height: width / Math.max(0.01, aspectRatio) + Style.space(64)
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
}
