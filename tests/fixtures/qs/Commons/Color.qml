pragma Singleton
import QtQuick

QtObject {
  readonly property var menu: ({
    background: "#111111",
    border: "#333333",
    text: "#eeeeee"
  })
  readonly property color accent: "#6688ff"
  readonly property color urgent: "#ff5555"
}
