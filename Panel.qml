import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "WindowModel.js" as WindowModel

// Omarchy Shell workspace overview.
//
// This intentionally owns only the overview UI. Workspace state comes from
// Quickshell.Hyprland, so the ordering is rebuilt from numeric workspace IDs
// instead of relying on Hyprland's event/list order.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property int selectedIndex: 0
  // Selection belongs to the overview only. Do not focus the real compositor
  // window here: focusing it can switch workspaces and warp the cursor.
  property var selectedToplevel: null
  // Bumped after Hyprland events so the workspace/client summaries are
  // rebuilt while the panel is open.
  property int workspaceRevision: 0
  property var draggedToplevel: null
  // A compositor reorder changes the toplevel model. Do not rebuild the
  // thumbnail Repeater while Qt's native drag session is still being torn
  // down; doing so can make the pointer appear to jump to the new thumbnail
  // geometry.
  property bool refreshAfterDrag: false
  property string pendingReorderSourceAddress: ""
  property string pendingReorderTargetAddress: ""
  property int pendingWorkspaceCreateId: -1
  property int pendingWorkspaceUnpersistId: -1
  property var createdWorkspaceIds: []
  property int currentPage: 0
  property var workspaceScroller: null
  property bool showKeybindHint: false

  readonly property int minimumWorkspaceCount: 8
  // Hyprland workspace IDs are signed integers. Keeping the accepted range
  // explicit also means every value interpolated into a dispatcher is a
  // canonical integer, never caller-controlled command text.
  readonly property int maximumWorkspaceId: 2147483647
  readonly property int overviewColumns: 3
  readonly property int cardsPerPage: 9
  readonly property int cardGap: Style.space(12)
  // Swipe behavior: "kinetic" follows momentum across multiple pages;
  // "single-page" limits each swipe to the next or previous page.
  property string flickBehavior: "kinetic"
  readonly property string flickSettingsPath:
    Quickshell.env("HOME") + "/.local/state/omarchy/settings/workspace-navigator.json"
  readonly property string flickSettingsTempPath: flickSettingsPath + ".tmp"
  property FileView flickSettingsFile: FileView {
    path: root.flickSettingsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadFlickSettings(text())
  }
  property FileView flickSettingsTempFile: FileView {
    path: root.flickSettingsTempPath
    printErrors: false
  }

  function loadFlickSettings(raw) {
    try {
      var settings = JSON.parse(String(raw || "{}"))
      if (settings.flickBehavior === "single-page"
          || settings.flickBehavior === "kinetic")
        root.flickBehavior = settings.flickBehavior
    } catch (e) {}
  }

  function setFlickBehavior(value) {
    var mode = String(value) === "single-page" ? "single-page" : "kinetic"
    root.flickBehavior = mode
    flickSettingsTempFile.setText(JSON.stringify({ flickBehavior: mode }, null, 2) + "\n")
    flickSettingsCommitProcess.running = true
    return "ok"
  }

  function workspaceById(id, revision) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  function positiveWorkspaceId(value) {
    var id = Number(value)
    if (!isFinite(id) || Math.floor(id) !== id || id <= 0
        || id > root.maximumWorkspaceId)
      return -1
    return id
  }

  // Keep exactly eight default workspaces visible. Extra workspaces are shown
  // only once they exist in Hyprland or have been created through the + card.
  function workspaceIds(revision) {
    var ids = []
    for (var i = 1; i <= root.minimumWorkspaceCount; i++) ids.push(i)

    for (var createdIndex = 0; createdIndex < root.createdWorkspaceIds.length; createdIndex++) {
      var createdId = root.positiveWorkspaceId(root.createdWorkspaceIds[createdIndex])
      if (createdId > root.minimumWorkspaceCount
          && ids.indexOf(createdId) === -1)
        ids.push(createdId)
    }

    var values = Hyprland.workspaces.values
    for (var j = 0; j < values.length; j++) {
      var id = root.positiveWorkspaceId(values[j].id)
      if (id > root.minimumWorkspaceCount && ids.indexOf(id) === -1)
        ids.push(id)
    }

    ids.sort(function(left, right) { return left - right })
    return ids
  }

  function workspaceEntries(revision) {
    var entries = []
    var ids = root.workspaceIds(revision)
    for (var i = 0; i < ids.length; i++)
      entries.push({ addWorkspace: false, id: ids[i] })
    entries.push({ addWorkspace: true, id: 0 })
    return entries
  }

  function pageCountFor(entryCount) {
    return Math.max(1, Math.ceil(Math.max(1, Number(entryCount) || 1) / root.cardsPerPage))
  }

  function pageForIndex(index) {
    return Math.floor(Math.max(0, Number(index) || 0) / root.cardsPerPage)
  }

  function ensureSelectionVisible() {
    Qt.callLater(function() {
      root.scrollToPage(root.pageForIndex(root.selectedIndex))
    })
  }

  function workspaceWindowCount(workspace, revision) {
    if (!workspace || !workspace.toplevels) return 0
    try { return workspace.toplevels.values.length } catch (e) { return 0 }
  }

  function workspaceWindowTitles(workspace, revision) {
    var titles = []
    if (!workspace || !workspace.toplevels) return titles

    try {
      var values = workspace.toplevels.values
      for (var i = 0; i < values.length; i++) {
        var title = String(values[i].title || "").trim()
        if (title !== "") titles.push(title)
      }
    } catch (e) {}
    return titles
  }

  function focusedIndex() {
    var focused = Hyprland.focusedWorkspace
    var ids = root.workspaceIds(root.workspaceRevision)
    if (!focused) return 0
    var index = ids.indexOf(focused.id)
    return index >= 0 ? index : 0
  }

  function clampSelection() {
    var count = root.workspaceEntries(root.workspaceRevision).length
    if (count <= 0) {
      root.selectedIndex = 0
      return
    }
    if (root.selectedIndex < 0) root.selectedIndex = count - 1
    if (root.selectedIndex >= count) root.selectedIndex = 0
  }

  function cardAspectRatioFor(screen) {
    var monitor = null
    try { monitor = screen ? Hyprland.monitorFor(screen) : Hyprland.focusedMonitor } catch (e) {}
    var width = monitor ? Number(monitor.width) : 0
    var height = monitor ? Number(monitor.height) : 0
    var reserved = monitor && (monitor.reserved
      || (monitor.lastIpcObject ? monitor.lastIpcObject.reserved : null))
    var left = reserved && typeof reserved.length === "number"
      ? Number(reserved[0]) : Number(reserved && reserved.left) || 0
    var top = reserved && typeof reserved.length === "number"
      ? Number(reserved[1]) : Number(reserved && reserved.top) || 0
    var right = reserved && typeof reserved.length === "number"
      ? Number(reserved[2]) : Number(reserved && reserved.right) || 0
    var bottom = reserved && typeof reserved.length === "number"
      ? Number(reserved[3]) : Number(reserved && reserved.bottom) || 0
    width -= left + right
    height -= top + bottom
    if (!isFinite(width) || !isFinite(height) || width <= 0 || height <= 0)
      return 16 / 9
    return width / height
  }

  function cardWidthFor(width, height, aspectRatio) {
    var availableWidth = Math.max(1,
      (width - (root.overviewColumns - 1) * root.cardGap) / root.overviewColumns)
    var availableHeight = Math.max(1,
      (height - (root.overviewColumns - 1) * root.cardGap) / root.overviewColumns)
    var aspect = isFinite(Number(aspectRatio)) && Number(aspectRatio) > 0
      ? Number(aspectRatio) : 16 / 9
    return Math.max(1, Math.floor(Math.min(availableWidth, availableHeight * aspect)))
  }

  function cardHeightFor(width, height, aspectRatio) {
    var aspect = isFinite(Number(aspectRatio)) && Number(aspectRatio) > 0
      ? Number(aspectRatio) : 16 / 9
    var cardWidth = root.cardWidthFor(width, height, aspect)
    return Math.max(1, Math.floor(cardWidth / aspect))
  }

  function select(delta) {
    var count = root.workspaceEntries(root.workspaceRevision).length
    if (count <= 0) return
    root.selectedIndex = (root.selectedIndex + delta + count) % count
    root.ensureSelectionVisible()
  }

  function selectRow(delta) {
    var count = root.workspaceEntries(root.workspaceRevision).length
    if (count <= 0) return
    var next = root.selectedIndex + delta * root.overviewColumns
    if (next < 0) next = 0
    if (next >= count) next = count - 1
    root.selectedIndex = next
    root.ensureSelectionVisible()
  }

  function activateSelected() {
    var entries = root.workspaceEntries(root.workspaceRevision)
    if (root.selectedIndex < 0 || root.selectedIndex >= entries.length) return
    var entry = entries[root.selectedIndex]
    if (entry.addWorkspace) root.addWorkspace()
    else root.focusWorkspace(entry.id)
  }

  function dispatchFocusWorkspace(id) {
    var workspaceId = root.positiveWorkspaceId(id)
    if (workspaceId < 1) return false
    if (Hyprland.usingLua)
      Hyprland.dispatch("hl.dsp.focus({ workspace = \"" + String(workspaceId) + "\" })")
    else
      Hyprland.dispatch("workspace " + String(workspaceId))
    return true
  }

  function focusWorkspace(id) {
    try {
      if (!root.dispatchFocusWorkspace(id)) return
    } catch (e) {
      console.warn("workspace overview: could not focus workspace", id, e)
    }
    root.dismiss()
  }

  function scrollToPage(page) {
    var count = root.pageCountFor(root.workspaceEntries(root.workspaceRevision).length)
    var targetPage = Math.max(0, Math.min(Number(page) || 0, count - 1))
    root.currentPage = targetPage
    if (root.workspaceScroller)
      root.workspaceScroller.contentX = targetPage * root.workspaceScroller.width
  }

  function addWorkspace() {
    if (workspaceCreateProcess.running) return
    var ids = root.workspaceIds(root.workspaceRevision)
    var nextId = root.minimumWorkspaceCount
    for (var i = 0; i < ids.length; i++)
      nextId = Math.max(nextId, Number(ids[i]))
    nextId += 1

    root.pendingWorkspaceCreateId = nextId
    workspaceCreateProcess.running = true
  }

  function finishWorkspaceCreate(id) {
    var created = root.createdWorkspaceIds.slice(0)
    if (created.indexOf(id) === -1) created.push(id)
    root.createdWorkspaceIds = created
    root.workspaceRevision += 1

    try {
      // Keep the overview open while creating the workspace so the new page
      // becomes visible immediately. The workspace is not followed here.
      root.dispatchFocusWorkspace(id)
      Hyprland.refreshWorkspaces()
      Hyprland.refreshToplevels()
    } catch (e) {
      console.warn("workspace overview: could not create workspace", id, e)
    }

    Qt.callLater(function() {
      root.scrollToPage(root.pageCountFor(root.workspaceEntries(root.workspaceRevision).length) - 1)
    })
  }

  function normalizedAddress(toplevel) {
    if (!toplevel) return ""
    return WindowModel.normalizedAddress(
      toplevel.address || (toplevel.lastIpcObject && toplevel.lastIpcObject.address))
  }

  function selectWindow(toplevel) {
    var address = root.normalizedAddress(toplevel)
    root.selectedToplevel = address !== "" ? toplevel : null
  }

  function beginWindowDrag(toplevel) {
    root.refreshAfterDrag = false
    root.draggedToplevel = toplevel
  }

  function endWindowDrag(toplevel) {
    if (!root.draggedToplevel || root.draggedToplevel === toplevel)
      root.draggedToplevel = null
    if (root.refreshAfterDrag) {
      root.refreshAfterDrag = false
      reorderRefreshTimer.restart()
    }
  }

  function moveWindowToWorkspace(toplevel, workspaceId) {
    var address = root.normalizedAddress(toplevel)
    var id = root.positiveWorkspaceId(workspaceId)
    if (!address || id < 1) return

    try {
      if (Hyprland.usingLua) {
        Hyprland.dispatch("hl.dsp.window.move({ workspace = \"" + String(id)
          + "\", window = \"address:" + address + "\", follow = false })")
      } else {
        Hyprland.dispatch("movetoworkspacesilent " + String(id) + ",address:" + address)
      }
      // Refresh immediately, then once more after Hyprland updates its object
      // model. This keeps the source and destination cards visually in sync.
      try { Hyprland.refreshWorkspaces(); Hyprland.refreshToplevels() } catch (e) {}
      root.workspaceRevision += 1
    } catch (e) {
      console.warn("workspace overview: could not move window", address, id, e)
    }
  }

  function performWorkspaceDelete(workspaceId) {
    var id = root.positiveWorkspaceId(workspaceId)
    if (id < 1) return
    if (workspaceUnpersistProcess.running) return

    // Hyprland's QML dispatcher sends the dispatcher directly over IPC. This
    // avoids the non-legacy hyprctl parser and does not use raw Lua eval.
    try {
      Hyprland.dispatch("destroyworkspace " + String(id))
      root.pendingWorkspaceUnpersistId = id
      workspaceUnpersistProcess.running = true
    } catch (e) {
      root.pendingWorkspaceUnpersistId = -1
      console.warn("workspace overview: could not delete workspace", workspaceId, e)
    }
  }

  function finishWorkspaceDelete(id) {
    if (id < 1) return
    var remaining = []
    for (var i = 0; i < root.createdWorkspaceIds.length; i++) {
      if (root.positiveWorkspaceId(root.createdWorkspaceIds[i]) !== id)
        remaining.push(root.createdWorkspaceIds[i])
    }
    root.createdWorkspaceIds = remaining
    try { Hyprland.refreshWorkspaces() } catch (e) {}
    root.workspaceRevision += 1
    Qt.callLater(function() {
      root.clampSelection()
      root.scrollToPage(Math.min(root.currentPage,
        root.pageCountFor(root.workspaceEntries(root.workspaceRevision).length) - 1))
    })
  }

  function deleteWorkspace(id) {
    var workspaceId = root.positiveWorkspaceId(id)
    if (workspaceId <= root.minimumWorkspaceCount) return

    var workspace = root.workspaceById(workspaceId, root.workspaceRevision)
    if (root.workspaceWindowCount(workspace, root.workspaceRevision) > 0) {
      console.warn("workspace overview: workspace is not empty", workspaceId)
      return
    }

    // Hyprland cannot destroy the currently active workspace. Move to the
    // first default workspace and defer the destroy until its event arrives.
    var focusedWorkspace = Hyprland.focusedWorkspace
    if (focusedWorkspace
        && root.positiveWorkspaceId(focusedWorkspace.id) === workspaceId) {
      try { root.dispatchFocusWorkspace(1) } catch (e) {}
      pendingWorkspaceDelete.workspaceId = workspaceId
      pendingWorkspaceDelete.attempts = 0
      pendingWorkspaceDelete.restart()
      return
    }

    root.performWorkspaceDelete(workspaceId)
  }

  Timer {
    id: pendingWorkspaceDelete
    property int workspaceId: -1
    property int attempts: 0
    interval: 120
    repeat: false
    onTriggered: {
      if (workspaceId <= root.minimumWorkspaceCount) {
        workspaceId = -1
        attempts = 0
        return
      }

      var focused = Hyprland.focusedWorkspace
      if (focused && root.positiveWorkspaceId(focused.id) === workspaceId
          && attempts < 10) {
        attempts += 1
        restart()
        return
      }

      if (focused && root.positiveWorkspaceId(focused.id) === workspaceId) {
        console.warn("workspace overview: workspace remained active; refusing to delete", workspaceId)
        workspaceId = -1
        attempts = 0
        return
      }

      root.performWorkspaceDelete(workspaceId)
      workspaceId = -1
      attempts = 0
    }
  }

  function reorderWindowTowards(sourceToplevel, targetToplevel) {
    var sourceAddress = root.normalizedAddress(sourceToplevel)
    var targetAddress = root.normalizedAddress(targetToplevel)
    if (!sourceAddress || !targetAddress) return
    if (sourceAddress === targetAddress) return

    var sourceWorkspaceId = sourceToplevel && sourceToplevel.workspace
      ? root.positiveWorkspaceId(sourceToplevel.workspace.id) : -1
    var targetWorkspaceId = targetToplevel && targetToplevel.workspace
      ? root.positiveWorkspaceId(targetToplevel.workspace.id) : -1
    if (sourceWorkspaceId < 1
        || sourceWorkspaceId !== targetWorkspaceId) {
      console.warn("workspace overview: refusing cross-workspace window reorder",
        sourceAddress, targetAddress, sourceWorkspaceId, targetWorkspaceId)
      return
    }

    try {
      if (!Hyprland.usingLua) {
        console.warn("workspace overview: window reorder requires Hyprland Lua")
        return
      }

      // Select both windows explicitly. This works for inactive workspaces
      // and swaps the exact thumbnails involved in the drop.
      // Hyprland's window.swap intentionally warps the cursor to the source
      // window after switching layout targets. Capture the real pointer
      // location first so it can be restored exactly once after the swap.
      if (cursorProbe.running) return
      root.pendingReorderSourceAddress = sourceAddress
      root.pendingReorderTargetAddress = targetAddress
      cursorProbe.running = true
    } catch (e) {
      console.warn("workspace overview: could not reorder windows",
        sourceAddress, targetAddress, e)
    }
  }

  function handleWindowDrop(sourceToplevel, targetToplevel, destinationWorkspaceId) {
    var sourceWorkspaceId = sourceToplevel && sourceToplevel.workspace
      ? root.positiveWorkspaceId(sourceToplevel.workspace.id) : -1
    var targetWorkspaceId = targetToplevel && targetToplevel.workspace
      ? root.positiveWorkspaceId(targetToplevel.workspace.id)
      : root.positiveWorkspaceId(destinationWorkspaceId)

    if (targetToplevel && sourceWorkspaceId === targetWorkspaceId) {
      root.reorderWindowTowards(sourceToplevel, targetToplevel)
      return
    }
    root.moveWindowToWorkspace(sourceToplevel, destinationWorkspaceId)
  }

  function open(payloadJson) {
    try { Hyprland.refreshWorkspaces(); Hyprland.refreshToplevels() } catch (e) {}
    root.workspaceRevision += 1
    root.selectedToplevel = null
    root.showKeybindHint = false
    root.selectedIndex = root.focusedIndex()
    root.opened = true
    root.currentPage = root.pageForIndex(root.selectedIndex)
    Qt.callLater(function() {
      root.clampSelection()
      root.scrollToPage(root.currentPage)
    })
  }

  function close() {
    root.opened = false
    root.showKeybindHint = false
  }

  function toggleKeybindHint() {
    root.showKeybindHint = !root.showKeybindHint
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "roubilibo.workspace-navigator")
    else
      root.close()
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function isFocusedScreen(screen) {
    var focusedMonitor = Hyprland.focusedMonitor
    if (!focusedMonitor) return screen === Quickshell.screens[0]

    var monitor = null
    try { monitor = Hyprland.monitorFor(screen) } catch (e) {}
    return monitor && monitor.name === focusedMonitor.name
  }

  Timer {
    id: refreshTimer
    interval: 75
    repeat: false
    onTriggered: root.workspaceRevision += 1
  }

  Timer {
    id: reorderRefreshTimer
    interval: 180
    repeat: false
    onTriggered: {
      try { Hyprland.refreshToplevels() } catch (e) {}
      root.workspaceRevision += 1
    }
  }

  Process {
    id: cursorProbe
    command: ["hyprctl", "cursorpos"]
    stdout: StdioCollector {
      id: cursorProbeOutput
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var sourceAddress = root.pendingReorderSourceAddress
      var targetAddress = root.pendingReorderTargetAddress
      root.pendingReorderSourceAddress = ""
      root.pendingReorderTargetAddress = ""

      if (exitCode !== 0 || !sourceAddress || !targetAddress) return

      var match = String(cursorProbeOutput.text || "").match(
        /^\s*(-?\d+)\s*,\s*(-?\d+)\s*$/)
      if (!match) {
        console.warn("workspace overview: could not parse cursor position",
          cursorProbeOutput.text)
        return
      }

      var x = Number(match[1])
      var y = Number(match[2])
      if (!isFinite(x) || !isFinite(y) || Math.floor(x) !== x
          || Math.floor(y) !== y || Math.abs(x) > root.maximumWorkspaceId
          || Math.abs(y) > root.maximumWorkspaceId) {
        console.warn("workspace overview: refusing invalid cursor position",
          cursorProbeOutput.text)
        return
      }
      try {
        Hyprland.dispatch("hl.dsp.window.swap({ window = \"address:" + sourceAddress
          + "\", target = \"address:" + targetAddress + "\" })")
        // swap() warps the cursor. Restore only this one saved position; do
        // not run a repeating restore timer, which fights normal input.
        Hyprland.dispatch("hl.dsp.cursor.move({ x = " + String(x)
          + ", y = " + String(y) + " })")
        root.refreshAfterDrag = true
        reorderRefreshTimer.restart()
      } catch (e) {
        console.warn("workspace overview: could not reorder windows",
          sourceAddress, targetAddress, e)
      }
    }
  }

  Process {
    id: flickSettingsCommitProcess
    command: ["mv", root.flickSettingsTempPath, root.flickSettingsPath]
    onExited: function(exitCode) {
      if (exitCode !== 0)
        console.warn("workspace overview: could not save flick settings", exitCode)
    }
  }

  Process {
    id: workspaceCreateProcess
    // Hyprland's non-legacy parser rejects `keyword workspace`.  Use the
    // native workspace_rule Lua API through `hyprctl eval`; the ID is a
    // canonical integer, so this remains a fixed, non-shell command.
    command: ["hyprctl", "eval",
      "hl.workspace_rule({ workspace = \"" + String(root.pendingWorkspaceCreateId)
        + "\", persistent = true })"]
    onExited: function(exitCode) {
      var workspaceId = root.pendingWorkspaceCreateId
      root.pendingWorkspaceCreateId = -1
      if (exitCode !== 0) {
        console.warn("workspace overview: could not make workspace persistent",
          workspaceId, "hyprctl exited with", exitCode)
        return
      }
      root.finishWorkspaceCreate(workspaceId)
    }
  }

  Process {
    id: workspaceUnpersistProcess
    command: ["hyprctl", "eval",
      "hl.workspace_rule({ workspace = \"" + String(root.pendingWorkspaceUnpersistId)
        + "\", persistent = false })"]
    onExited: function(exitCode) {
      var workspaceId = root.pendingWorkspaceUnpersistId
      root.pendingWorkspaceUnpersistId = -1
      if (exitCode !== 0)
        console.warn("workspace overview: could not clear workspace persistence",
          workspaceId, "hyprctl exited with", exitCode)
      root.finishWorkspaceDelete(workspaceId)
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!root.opened) return

      // Keep the delegate tree stable until the native drag session has
      // released the pointer. The final refresh is scheduled by
      // endWindowDrag().
      if (root.draggedToplevel !== null) {
        root.refreshAfterDrag = true
        return
      }

      var name = event && event.name ? String(event.name) : ""
      var workspaceChanged = name.indexOf("monitor") !== -1
        || name.indexOf("moveworkspace") === 0
        || name.indexOf("workspace") !== -1
      var toplevelChanged = name.indexOf("window") !== -1
        || name.indexOf("group") !== -1
        || name === "fullscreen"
        || name === "changefloatingmode"
        || name.indexOf("workspace") !== -1

      if (workspaceChanged)
        Hyprland.refreshWorkspaces()
      if (toplevelChanged)
        Hyprland.refreshToplevels()
      refreshTimer.restart()
    }
  }

  IpcHandler {
    target: "roubilibo.workspace-navigator"

    function open(): string { root.open("{}"); return "ok" }
    function close(): string { root.close(); return "ok" }
    function toggle(): string { root.toggle(); return "ok" }
    function setFlickBehavior(mode: string): string {
      return root.setFlickBehavior(mode)
    }
    function focus(id: string): string {
      var workspaceId = root.positiveWorkspaceId(id)
      if (workspaceId < 1) return "invalid workspace"
      root.focusWorkspace(workspaceId)
      return "ok"
    }
    function state(): string { return root.opened ? "open" : "closed" }
  }

  // A surface is created for every output, but only the output currently
  // focused by Hyprland displays the overview. This matches the cursor/focus
  // behavior users generally expect from SUPER+TAB on multi-monitor setups.
  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        required property var modelData
        id: panelWindow
        readonly property var panelScreen: modelData

        screen: modelData
        visible: root.opened && (Quickshell.screens.length === 1
          || root.isFocusedScreen(modelData))
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        WlrLayershell.namespace: "roubilibo-workspace-navigator"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: panelWindow.visible
          ? WlrKeyboardFocus.Exclusive
          : WlrKeyboardFocus.None

        anchors { top: true; bottom: true; left: true; right: true }

        Rectangle {
          anchors.fill: parent
          color: Util.alpha(Color.background, 0.92)

          MouseArea {
            anchors.fill: parent
            onClicked: root.dismiss()
          }
        }

        FocusScope {
          id: keyCatcher
          anchors.fill: parent
          focus: panelWindow.visible
          Keys.priority: Keys.BeforeItem

          function refocus() {
            if (panelWindow.visible) Qt.callLater(function() {
              if (panelWindow.visible) keyCatcher.forceActiveFocus()
            })
          }

          Component.onCompleted: refocus()
          onVisibleChanged: refocus()

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              root.dismiss()
              event.accepted = true
            } else if (event.text === "?" || event.key === Qt.Key_Question
                       || event.key === Qt.Key_Slash) {
              root.toggleKeybindHint()
              event.accepted = true
            } else if (event.key === Qt.Key_Left || event.key === Qt.Key_H) {
              root.select(-1)
              event.accepted = true
            } else if (event.key === Qt.Key_Right || event.key === Qt.Key_L) {
              root.select(1)
              event.accepted = true
            } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
              root.selectRow(-1)
              event.accepted = true
            } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
              root.selectRow(1)
              event.accepted = true
            } else if (event.key === Qt.Key_Tab) {
              root.select(event.modifiers & Qt.ShiftModifier ? -1 : 1)
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                       || event.key === Qt.Key_Space) {
              root.activateSelected()
              event.accepted = true
            }
          }

          ColumnLayout {
            id: overviewColumn
            anchors.centerIn: parent
            width: parent.width - Style.space(48)
            height: parent.height - Style.space(48)
            spacing: Style.space(12)

            Text {
              Layout.fillWidth: true
              text: "Workspace overview"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              Layout.fillWidth: true
              text: root.pageCountFor(root.workspaceEntries(root.workspaceRevision).length) > 1
                ? "Swipe horizontally for additional workspaces  •  Right-click a card to enter"
                : "Right-click a card to enter  •  Left-drag thumbnails to move or reorder"
              color: Util.alpha(Color.foreground, 0.65)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }

            Rectangle {
              visible: root.showKeybindHint
              Layout.fillWidth: true
              Layout.minimumHeight: 0
              Layout.preferredHeight: visible ? Style.space(58) : 0
              Layout.maximumHeight: visible ? Style.space(58) : 0
              radius: Style.cornerRadius
              color: Util.alpha(Color.menu.background, 0.82)
              border.width: 1
              border.color: Util.alpha(Color.menu.border, 0.28)

              Text {
                anchors.fill: parent
                anchors.leftMargin: Style.space(14)
                anchors.rightMargin: Style.space(14)
                text: "Keyboard shortcuts  •  Esc: close  •  ←/→ or H/L: navigate  •  ↑/↓ or K/J: move  •  Tab/Shift+Tab: select  •  Enter/Space: activate  •  ?: toggle hints"
                color: Util.alpha(Color.menu.text, 0.82)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignHCenter
              }
            }

            Flickable {
              id: workspaceFlickable
              property real swipeStartX: 0
              property int swipeStartPage: 0
              Component.onCompleted: root.workspaceScroller = workspaceFlickable
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              contentWidth: width * root.pageCountFor(
                root.workspaceEntries(root.workspaceRevision).length)
              contentHeight: height
              interactive: root.pageCountFor(
                root.workspaceEntries(root.workspaceRevision).length) > 1
              flickableDirection: Flickable.HorizontalFlick
              boundsBehavior: Flickable.StopAtBounds
              // Make page swipes feel snappier by increasing the travel speed
              // and letting the flick settle sooner.
              maximumFlickVelocity: 8000
              flickDeceleration: 5000
              onMovementStarted: {
                swipeStartX = contentX
                swipeStartPage = root.currentPage
              }
              onMovementEnded: {
                if (width <= 0) return
                var delta = contentX - swipeStartX
                var threshold = width * 0.50
                var targetPage = swipeStartPage
                if (Math.abs(delta) >= threshold) {
                  if (root.flickBehavior === "single-page") {
                    targetPage += delta > 0 ? 1 : -1
                  } else {
                    // Kinetic mode keeps every page reached by a fast flick.
                    targetPage = Math.round(contentX / width)
                    if (targetPage === swipeStartPage)
                      targetPage += delta > 0 ? 1 : -1
                  }
                } else {
                  targetPage = Math.round(contentX / width)
                }
                root.scrollToPage(targetPage)
              }
              onContentXChanged: {
                if (root.flickBehavior === "single-page" && width > 0
                    && (dragging || flicking)) {
                  // Preserve native kinetic motion, but keep it inside the
                  // adjacent-page interval for single-page mode.
                  var startX = swipeStartPage * width
                  var lowerBound = Math.max(0, startX - width)
                  var upperBound = Math.min(contentWidth - width, startX + width)
                  if (contentX < lowerBound) contentX = lowerBound
                  else if (contentX > upperBound) contentX = upperBound
                }
                if (width > 0)
                  root.currentPage = Math.round(contentX / width)
              }

              Behavior on contentX {
                // Animate only the final page snap, not pointer tracking.
                enabled: !workspaceFlickable.dragging
                  && !workspaceFlickable.flicking
                NumberAnimation {
                  duration: 180
                  easing.type: Easing.OutCubic
                }
              }

              Row {
                id: workspacePages
                width: workspaceFlickable.contentWidth
                height: workspaceFlickable.height

                Repeater {
                  model: root.pageCountFor(
                    root.workspaceEntries(root.workspaceRevision).length)

                  delegate: Item {
                    id: pageItem
                    required property int modelData
                    readonly property int pageNumber: modelData
                    readonly property var pageEntries: root.workspaceEntries(
                      root.workspaceRevision).slice(
                        modelData * root.cardsPerPage,
                        (modelData + 1) * root.cardsPerPage)

                    width: workspaceFlickable.width
                    height: workspaceFlickable.height

                    Item {
                      readonly property real cardAspectRatio: root.cardAspectRatioFor(panelScreen)
                      readonly property int cardWidth: root.cardWidthFor(
                        workspaceFlickable.width, workspaceFlickable.height, cardAspectRatio)
                      readonly property int cardHeight: root.cardHeightFor(
                        workspaceFlickable.width, workspaceFlickable.height, cardAspectRatio)
                      anchors.centerIn: parent
                      width: cardWidth * root.overviewColumns
                        + root.cardGap * (root.overviewColumns - 1)
                      height: cardHeight * root.overviewColumns
                        + root.cardGap * (root.overviewColumns - 1)
                      Repeater {
                        model: pageEntries

                        delegate: WorkspaceCard {
                          required property var modelData
                          required property int index

                          readonly property bool addCard: Boolean(modelData.addWorkspace)
                          readonly property int cardWorkspaceId: Number(modelData.id)
                          readonly property int absoluteIndex: pageItem.pageNumber
                            * root.cardsPerPage + index

                          width: parent.cardWidth
                          height: parent.cardHeight
                          // Use fixed slots instead of GridLayout's implicit
                          // column sizing, which moved the add card when a
                          // page was only partially filled.
                          x: (index % root.overviewColumns)
                            * (parent.cardWidth + root.cardGap)
                          y: Math.floor(index / root.overviewColumns)
                            * (parent.cardHeight + root.cardGap)
                          workspaceId: addCard ? 0 : cardWorkspaceId
                          addWorkspace: addCard
                          deletable: !addCard && cardWorkspaceId > root.minimumWorkspaceCount
                          workspace: addCard ? null
                            : root.workspaceById(cardWorkspaceId, root.workspaceRevision)
                          previewScreen: panelScreen
                          focused: !addCard && Hyprland.focusedWorkspace !== null
                            && Hyprland.focusedWorkspace.id === cardWorkspaceId
                          keyboardSelected: root.selectedIndex === absoluteIndex
                          draggedToplevel: root.draggedToplevel
                          selectedToplevel: root.selectedToplevel
                          livePreviews: root.opened && panelWindow.visible
                          toplevelRevision: root.workspaceRevision
                          onWorkspaceHovered: root.selectedIndex = absoluteIndex
                          onWorkspaceActivated: {
                            if (addCard) root.addWorkspace()
                            else root.focusWorkspace(cardWorkspaceId)
                          }
                          onAddWorkspaceRequested: root.addWorkspace()
                          onWorkspaceDeleteRequested: root.deleteWorkspace(cardWorkspaceId)
                          onWindowDragStarted: function(toplevel) {
                            root.selectWindow(toplevel)
                            root.beginWindowDrag(toplevel)
                          }
                          onWindowDragFinished: function(toplevel) { root.endWindowDrag(toplevel) }
                          onWindowSelected: function(toplevel) { root.selectWindow(toplevel) }
                          onWindowDropped: function(toplevel) {
                            root.moveWindowToWorkspace(toplevel, cardWorkspaceId)
                          }
                          onWindowDroppedOn: function(sourceToplevel, targetToplevel) {
                            root.handleWindowDrop(sourceToplevel, targetToplevel, cardWorkspaceId)
                          }
                        }
                      }
                    }
                  }
                }
              }
            }

            Text {
              Layout.fillWidth: true
              text: root.pageCountFor(root.workspaceEntries(root.workspaceRevision).length) > 1
                ? "← swipe for previous page    page "
                  + String(root.currentPage + 1) + "/"
                  + String(root.pageCountFor(root.workspaceEntries(root.workspaceRevision).length))
                  + "    swipe right for next page →    ?: show/hide shortcuts"
                : "8 workspaces +    Left-drag thumbnail: move/reorder    Right-click card: enter    ?: show/hide shortcuts"
              color: Util.alpha(Color.foreground, 0.50)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }
    }
  }
}
