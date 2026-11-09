import QtQuick
import QtTest
import "../src/components"

TestCase {
  id: testCase
  name: "WorkspaceContextMenu"
  when: windowShown
  visible: true
  width: 800
  height: 600

  property var menuInstance: null

  Component {
    id: menuFactory
    WorkspaceContextMenu {
      width: 320
      workspaceId: 7
      workspaceName: "<img src=\"https://example.invalid/pixel\">"
      menuX: 40
      menuY: 40
      visible: true
      canMoveSelectedWindow: false
      deletable: true
      deleteEnabled: false
    }
  }

  SignalSpy {
    id: focusSpy
    target: testCase.menuInstance
    signalName: "focusRequested"
  }

  SignalSpy {
    id: renameSpy
    target: testCase.menuInstance
    signalName: "renameRequested"
  }

  SignalSpy {
    id: renameCommitSpy
    target: testCase.menuInstance
    signalName: "renameCommitted"
  }

  SignalSpy {
    id: renameCancelSpy
    target: testCase.menuInstance
    signalName: "renameCancelled"
  }

  SignalSpy {
    id: renameTextSpy
    target: testCase.menuInstance
    signalName: "renameTextEdited"
  }

  SignalSpy {
    id: moveSpy
    target: testCase.menuInstance
    signalName: "moveSelectedWindowRequested"
  }

  SignalSpy {
    id: deleteSpy
    target: testCase.menuInstance
    signalName: "deleteRequested"
  }

  function init() {
    menuInstance = createTemporaryObject(menuFactory, testCase)
    verify(menuInstance !== null, "menu component should load")
    focusSpy.clear()
    renameSpy.clear()
    renameCommitSpy.clear()
    renameCancelSpy.clear()
    renameTextSpy.clear()
    moveSpy.clear()
    deleteSpy.clear()
  }

  function cleanup() {
    menuInstance = null
  }

  function test_workspaceNameIsPlainText() {
    var title = findChild(menuInstance, "workspaceContextTitle")
    verify(title !== null, "workspace title should exist")
    compare(title.textFormat, Text.PlainText)
    compare(title.text, "<img src=\"https://example.invalid/pixel\">")
  }

  function test_workspaceActionsEmitRequests() {
    var focusAction = findChild(menuInstance, "focusWorkspaceAction")
    verify(focusAction !== null)
    mouseClick(focusAction)
    compare(focusSpy.count, 1)

    mouseClick(findChild(menuInstance, "renameWorkspaceAction"))
    compare(renameSpy.count, 1)

    menuInstance.renameMode = true
    var renameInput = findChild(menuInstance, "workspaceRenameInput")
    verify(renameInput !== null)
    renameInput.text = "Renamed workspace"
    renameInput.textEdited()
    verify(renameTextSpy.count > 0, "typing should update the rename draft")
    var saveAction = findChild(menuInstance, "saveRenameAction")
    mouseClick(saveAction)
    compare(renameCommitSpy.count, 1)
    mouseClick(findChild(menuInstance, "cancelRenameAction"))
    compare(renameCancelSpy.count, 1)

    mouseClick(findChild(menuInstance, "moveWindowAction"))
    compare(moveSpy.count, 0, "moving is disabled without a selected window")

    mouseClick(findChild(menuInstance, "deleteWorkspaceAction"))
    compare(deleteSpy.count, 0, "deleting is disabled for a non-empty workspace")
  }
}
