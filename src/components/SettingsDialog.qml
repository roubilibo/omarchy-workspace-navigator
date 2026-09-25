import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Rectangle {
  id: root

  property bool opened: false
  property var options: []
  property int selectedIndex: 0
  property string flickBehavior: "single-page"
  property string altTabScope: "workspace"
  property bool blurEnabled: false
  signal toggleRequested(int index)
  signal dismissRequested()

  visible: root.opened
  z: 10
  anchors.centerIn: parent
  width: Math.min(parent.width - Style.space(48), Style.space(560))
  height: settingsColumn.implicitHeight + Style.space(48)
  radius: Style.cornerRadius
  color: Color.menu.background
  border.width: 1
  border.color: Util.alpha(Color.menu.border, 0.52)

  ColumnLayout {
    id: settingsColumn
    anchors.fill: parent
    anchors.margins: Style.space(24)
    spacing: Style.space(12)

    Text {
      Layout.fillWidth: true
      text: "Workspace Navigator Settings"
      color: Color.menu.text
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
    }

    Text {
      Layout.fillWidth: true
      text: "Enable optional workspace navigation behaviors."
      color: Util.alpha(Color.menu.text, 0.70)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    Repeater {
      model: root.options

      delegate: Toggle {
        required property var modelData
        required property int index
        Layout.fillWidth: true
        label: modelData.label
        description: modelData.description
        hasCursor: root.selectedIndex === index
        checked: modelData.kind === "flick"
          ? root.flickBehavior === "kinetic"
          : (modelData.kind === "altTab"
            ? root.altTabScope === "all" : root.blurEnabled)
        onClicked: root.toggleRequested(index)
      }
    }

    Text {
      Layout.fillWidth: true
      text: "Changes are saved automatically. Press Esc to close."
      color: Util.alpha(Color.menu.text, 0.52)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
    }

    Rectangle {
      Layout.alignment: Qt.AlignHCenter
      implicitWidth: Style.space(110)
      implicitHeight: Style.space(36)
      radius: height / 2
      color: Util.alpha(Color.accent, 0.22)
      border.width: 1
      border.color: Util.alpha(Color.accent, 0.70)

      Text {
        anchors.fill: parent
        text: "Close"
        color: Color.menu.text
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }

      TapHandler { onTapped: root.dismissRequested() }
    }
  }
}
