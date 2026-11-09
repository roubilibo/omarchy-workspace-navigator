import QtQuick
import QtQuick.Layouts
import qs.Commons as Commons

Rectangle {
  id: root

  property int workspaceId: -1
  property string workspaceName: ""
  property real menuX: 0
  property real menuY: 0
  property bool renameMode: false
  property string renameText: ""
  property bool canMoveSelectedWindow: false
  property bool persistent: false
  property bool deletable: false
  property bool deleteEnabled: false

  signal focusRequested()
  signal renameRequested()
  signal renameTextEdited(string text)
  signal renameCommitted()
  signal renameCancelled()
  signal moveSelectedWindowRequested()
  signal persistenceToggled()
  signal deleteRequested()

  objectName: "workspaceContextMenu"
  visible: false
  z: 100
  width: Commons.Style.space(320)
  height: contextMenuColumn.implicitHeight + Commons.Style.space(24)
  x: Math.max(Commons.Style.space(24), Math.min(root.menuX,
    parent ? parent.width - width - Commons.Style.space(24) : root.menuX))
  y: Math.max(Commons.Style.space(24), Math.min(root.menuY,
    parent ? parent.height - height - Commons.Style.space(24) : root.menuY))
  radius: Commons.Style.cornerRadius
  color: Commons.Color.menu.background
  border.width: 1
  border.color: Commons.Util.alpha(Commons.Color.menu.border, 0.58)

  // Keep clicks inside the menu from reaching the overview scrim.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
    onClicked: function(mouse) { mouse.accepted = true }
  }

  ColumnLayout {
    id: contextMenuColumn
    anchors.fill: parent
    anchors.margins: Commons.Style.space(12)
    spacing: Commons.Style.space(6)

    Text {
      objectName: "workspaceContextTitle"
      Layout.fillWidth: true
      text: root.workspaceName === ""
        ? "WS " + String(root.workspaceId) : root.workspaceName
      textFormat: Text.PlainText
      color: Commons.Color.menu.text
      font.family: Commons.Style.font.family
      font.pixelSize: Commons.Style.font.body
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      Layout.fillWidth: true
      text: "Workspace actions"
      color: Commons.Util.alpha(Commons.Color.menu.text, 0.54)
      font.family: Commons.Style.font.family
      font.pixelSize: Commons.Style.font.bodySmall
    }

    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: root.renameMode ? Commons.Style.space(38) : 0
      visible: root.renameMode
      radius: Commons.Style.cornerRadius
      color: Commons.Util.alpha(Commons.Color.menu.text, 0.07)
      border.width: 1
      border.color: Commons.Color.accent

      TextInput {
        id: workspaceRenameInput
        objectName: "workspaceRenameInput"
        anchors.fill: parent
        anchors.leftMargin: Commons.Style.space(10)
        anchors.rightMargin: Commons.Style.space(10)
        text: root.renameText
        onTextEdited: root.renameTextEdited(text)
        color: Commons.Color.menu.text
        font.family: Commons.Style.font.family
        font.pixelSize: Commons.Style.font.body
        verticalAlignment: TextInput.AlignVCenter
        selectByMouse: true
        clip: true
        onVisibleChanged: {
          if (visible) Qt.callLater(function() {
            workspaceRenameInput.forceActiveFocus()
            workspaceRenameInput.selectAll()
          })
        }
        Keys.onReturnPressed: root.renameCommitted()
        Keys.onEscapePressed: root.renameCancelled()
      }
    }

    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: root.renameMode ? 0 : Commons.Style.space(38)
      visible: !root.renameMode
      radius: Commons.Style.cornerRadius
      color: focusWorkspaceMouse.containsMouse
        ? Commons.Util.alpha(Commons.Color.accent, 0.20) : "transparent"

      Text {
        anchors.fill: parent
        anchors.leftMargin: Commons.Style.space(10)
        text: "Focus workspace"
        color: Commons.Color.menu.text
        font.family: Commons.Style.font.family
        font.pixelSize: Commons.Style.font.body
        verticalAlignment: Text.AlignVCenter
      }

      Text {
        anchors.right: parent.right
        anchors.rightMargin: Commons.Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: "Enter"
        color: Commons.Util.alpha(Commons.Color.menu.text, 0.48)
        font.family: Commons.Style.font.menuFamily
        font.pixelSize: Commons.Style.font.bodySmall
      }

      MouseArea {
        id: focusWorkspaceMouse
        objectName: "focusWorkspaceAction"
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.focusRequested()
      }
    }

    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: root.renameMode ? 0 : Commons.Style.space(38)
      visible: !root.renameMode
      radius: Commons.Style.cornerRadius
      color: renameWorkspaceMouse.containsMouse
        ? Commons.Util.alpha(Commons.Color.accent, 0.20) : "transparent"

      Text {
        anchors.fill: parent
        anchors.leftMargin: Commons.Style.space(10)
        text: "Rename workspace"
        color: Commons.Color.menu.text
        font.family: Commons.Style.font.family
        font.pixelSize: Commons.Style.font.body
        verticalAlignment: Text.AlignVCenter
      }

      Text {
        anchors.right: parent.right
        anchors.rightMargin: Commons.Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: "R"
        color: Commons.Util.alpha(Commons.Color.menu.text, 0.48)
        font.family: Commons.Style.font.menuFamily
        font.pixelSize: Commons.Style.font.bodySmall
      }

      MouseArea {
        id: renameWorkspaceMouse
        objectName: "renameWorkspaceAction"
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.renameRequested()
      }
    }

    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: root.renameMode ? 0 : Commons.Style.space(38)
      visible: !root.renameMode
      radius: Commons.Style.cornerRadius
      color: moveWindowMouse.containsMouse && root.canMoveSelectedWindow
        ? Commons.Util.alpha(Commons.Color.accent, 0.20) : "transparent"
      opacity: root.canMoveSelectedWindow ? 1 : 0.45

      Text {
        anchors.fill: parent
        anchors.leftMargin: Commons.Style.space(10)
        text: "Move selected window here"
        color: Commons.Color.menu.text
        font.family: Commons.Style.font.family
        font.pixelSize: Commons.Style.font.body
        verticalAlignment: Text.AlignVCenter
      }

      Text {
        anchors.right: parent.right
        anchors.rightMargin: Commons.Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: "M"
        color: Commons.Util.alpha(Commons.Color.menu.text, 0.48)
        font.family: Commons.Style.font.menuFamily
        font.pixelSize: Commons.Style.font.bodySmall
      }

      MouseArea {
        id: moveWindowMouse
        objectName: "moveWindowAction"
        anchors.fill: parent
        enabled: root.canMoveSelectedWindow
        hoverEnabled: true
        onClicked: root.moveSelectedWindowRequested()
      }
    }

    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: root.renameMode ? 0 : Commons.Style.space(38)
      visible: !root.renameMode
      radius: Commons.Style.cornerRadius
      color: persistentWorkspaceMouse.containsMouse
        ? Commons.Util.alpha(Commons.Color.accent, 0.20) : "transparent"

      Text {
        anchors.fill: parent
        anchors.leftMargin: Commons.Style.space(10)
        text: root.persistent ? "Remove persistence" : "Make persistent"
        color: Commons.Color.menu.text
        font.family: Commons.Style.font.family
        font.pixelSize: Commons.Style.font.body
        verticalAlignment: Text.AlignVCenter
      }

      MouseArea {
        id: persistentWorkspaceMouse
        objectName: "persistenceAction"
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.persistenceToggled()
      }
    }

    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: root.renameMode ? 0 : Commons.Style.space(38)
      visible: !root.renameMode
      radius: Commons.Style.cornerRadius
      color: deleteWorkspaceMouse.containsMouse && root.deletable
        ? Commons.Util.alpha(Commons.Color.urgent, 0.20) : "transparent"
      opacity: root.deleteEnabled ? 1 : 0.42

      Text {
        anchors.fill: parent
        anchors.leftMargin: Commons.Style.space(10)
        text: "Delete empty workspace"
        color: root.deletable
          ? Commons.Color.menu.text : Commons.Util.alpha(Commons.Color.menu.text, 0.58)
        font.family: Commons.Style.font.family
        font.pixelSize: Commons.Style.font.body
        verticalAlignment: Text.AlignVCenter
      }

      MouseArea {
        id: deleteWorkspaceMouse
        objectName: "deleteWorkspaceAction"
        anchors.fill: parent
        enabled: root.deleteEnabled
        hoverEnabled: true
        onClicked: root.deleteRequested()
      }
    }

    RowLayout {
      visible: root.renameMode
      Layout.fillWidth: true
      Layout.preferredHeight: Commons.Style.space(38)
      Layout.minimumHeight: Commons.Style.space(38)
      spacing: Commons.Style.space(6)

      Rectangle {
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.minimumWidth: Commons.Style.space(80)
        Layout.minimumHeight: Commons.Style.space(38)
        radius: Commons.Style.cornerRadius
        color: cancelRenameMouse.containsMouse
          ? Commons.Util.alpha(Commons.Color.menu.text, 0.10) : "transparent"

        Text {
          anchors.fill: parent
          text: "Cancel"
          color: Commons.Color.menu.text
          font.family: Commons.Style.font.family
          font.pixelSize: Commons.Style.font.body
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }

        MouseArea {
          id: cancelRenameMouse
          objectName: "cancelRenameAction"
          anchors.fill: parent
          hoverEnabled: true
          onClicked: root.renameCancelled()
        }
      }

      Rectangle {
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.minimumWidth: Commons.Style.space(80)
        Layout.minimumHeight: Commons.Style.space(38)
        radius: Commons.Style.cornerRadius
        color: saveRenameMouse.containsMouse
          ? Commons.Util.alpha(Commons.Color.accent, 0.34) : Commons.Util.alpha(Commons.Color.accent, 0.22)

        Text {
          anchors.fill: parent
          text: "Save"
          color: Commons.Color.menu.text
          font.family: Commons.Style.font.family
          font.pixelSize: Commons.Style.font.body
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }

        MouseArea {
          id: saveRenameMouse
          objectName: "saveRenameAction"
          anchors.fill: parent
          hoverEnabled: true
          onClicked: root.renameCommitted()
        }
      }
    }
  }
}
