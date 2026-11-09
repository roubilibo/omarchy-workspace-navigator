pragma Singleton
import QtQuick

QtObject {
  readonly property int cornerRadius: 8
  readonly property var font: ({
    family: "sans-serif",
    menuFamily: "sans-serif",
    body: 14,
    bodySmall: 12
  })

  function space(value) { return value }
}
