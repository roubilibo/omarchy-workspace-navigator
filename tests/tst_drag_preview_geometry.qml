import QtQuick
import QtTest
import "../src/lib/WindowGeometry.js" as WindowGeometry

TestCase {
  name: "DragPreviewGeometry"

  function verifyRatio(geometry, expected) {
    verify(Math.abs(geometry.width / geometry.height - expected) < 0.000001,
      "drag preview should preserve its starting aspect ratio")
  }

  function test_landscapeShrinksUniformly() {
    var ratio = 16 / 9
    var start = WindowGeometry.dragPreviewGeometry(1600, 900, 180, 101, 0)
    compare(start.width, 1600)
    compare(start.height, 900)
    verifyRatio(start, ratio)

    var midway = WindowGeometry.dragPreviewGeometry(1600, 900, 180, 101, 0.5)
    verifyRatio(midway, ratio)
    verify(midway.width < start.width)
    verify(midway.height < start.height)

    var fitted = WindowGeometry.dragPreviewGeometry(1600, 900, 180, 101, 1)
    verifyRatio(fitted, ratio)
    verify(fitted.width <= 180)
    verify(fitted.height <= 101)
  }

  function test_portraitAndSquareKeepTheirRatios() {
    var portrait = WindowGeometry.dragPreviewGeometry(900, 1600, 180, 101, 1)
    verifyRatio(portrait, 900 / 1600)
    verify(portrait.width <= 180)
    verify(portrait.height <= 101)

    var square = WindowGeometry.dragPreviewGeometry(720, 720, 180, 101, 1)
    verifyRatio(square, 1)
    verify(square.width <= 180)
    verify(square.height <= 101)
  }

  function test_targetChangesDoNotChangeStartingRatio() {
    var firstTarget = WindowGeometry.dragPreviewGeometry(1200, 800, 180, 101, 1)
    var nextTarget = WindowGeometry.dragPreviewGeometry(1200, 800, 180, 101, 1)
    compare(firstTarget.width, nextTarget.width)
    compare(firstTarget.height, nextTarget.height)
    verifyRatio(nextTarget, 1200 / 800)
  }

  function test_smallWindowsAreNotUpscaled() {
    var geometry = WindowGeometry.dragPreviewGeometry(80, 45, 180, 101, 1)
    compare(geometry.scale, 1)
    compare(geometry.width, 80)
    compare(geometry.height, 45)
  }

  function test_invalidValuesRemainFinite() {
    var geometry = WindowGeometry.dragPreviewGeometry(0, NaN, -1, 0, NaN)
    compare(geometry.width, 1)
    compare(geometry.height, 1)
    compare(geometry.scale, 1)
  }
}
