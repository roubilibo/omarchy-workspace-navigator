import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "components"
import "lib/WindowModel.js" as WindowModel
import "lib/WindowGeometry.js" as WindowGeometry

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
  property int contextWorkspaceId: -1
  property bool draggedFromWorkspaceCanvas: false
  property real dragShrinkProgress: 0
  property real contextMenuX: 0
  property real contextMenuY: 0
  property bool workspaceContextOpen: false
  property bool contextRenameMode: false
  property string contextRenameText: ""
  // Bumped after Hyprland events so the workspace/client summaries are
  // rebuilt while the panel is open.
  property int workspaceRevision: 0
  // Set true temporarily while diagnosing overview drag/drop behavior.
  property bool debugDrag:true
  property var dragLogTimes: ({})
  property string dragProbeAddress: ""
  property int dragProbeWorkspaceId: -1
  property int dragGeometryRevision: 0
  property var lastDispatchedDragPosition: null
  property var lastObservedDragPosition: null
  property var draggedToplevel: null
  property var dragGeometryOverrides: ({})
  property var dragWorkspaceToplevelSnapshots: null
  property bool dragPreviewFrozen: false
  // Workspace moves change the toplevel model. Keep the preview delegates
  // stable through a drag so the active DragHandler stays attached.
  property bool refreshAfterDrag: false
  property var dragStartState: null
  property var pendingFloatingDragMove: null
  property var pendingWindowDrop: null
  property var pendingTiledSwap: null
  property int pendingWorkspaceCreateId: -1
  property int pendingWorkspacePersistId: -1
  property int pendingWorkspaceUnpersistId: -1
  property int pendingWorkspaceDeleteId: -1
  property var menuPersistentWorkspaceIds: []
  property var createdWorkspaceIds: []
  property var workspaceScroller: null
  property Item dragOverlayItem: null
  property bool showKeybindHint: false
  property bool settingsMode: false
  property int settingsSelection: 0
  property bool altTabOpen: false
  property bool altTabOverlayVisible: false
  property bool altTabCommitPending: false
  property bool altTabCommitHandled: false
  property bool modalInputModeActive: false
  property int altTabIndex: -1
  property var altTabCandidates: []
  // The candidates are a snapshot of the MRU order for one Alt+Tab session.
  // It may be pruned when a client ceases to be eligible, but it must not be
  // reordered by focus events caused outside the switcher while it is open.
  property var altTabSnapshot: []
  property var altTabFocusHistory: []
  property var altTabClosedAddresses: ({})
  property string altTabDeferredFocusAddress: ""
  property string altTabScope: "workspace"

  onAltTabOpenChanged: {
    root.syncModalInputMode()
    if (root.altTabOpen) {
      altTabOverlayShowTimer.start()
    } else {
      altTabOverlayShowTimer.stop()
      root.altTabOverlayVisible = false
      root.clearPendingAltTabCommit()
      root.altTabCommitHandled = true
    }
  }
  onOpenedChanged: {
    root.syncModalInputMode()
    if (!root.opened) {
      root.closeWorkspaceContext()
      // A close key can dismiss the overview while a delegate is being
      // replaced. Never leave a tiled client floating if the normal
      // DragHandler finish was skipped while the overview was closing.
      if (root.dragStartState && root.dragStartState.temporarilyFloated
          && !root.pendingWindowDrop)
        root.endWindowDrag(root.draggedToplevel)
    }
  }
  onDebugDragChanged: {
    if (root.debugDrag && root.draggedToplevel) dragStateProbeTimer.start()
  }

  readonly property int minimumWorkspaceCount: 5
  // Hyprland workspace IDs are signed integers. Keeping the accepted range
  // explicit also means every value interpolated into a dispatcher is a
  // canonical integer, never caller-controlled command text.
  readonly property int maximumWorkspaceId: 2147483647
  readonly property int cardGap: Style.space(12)
  readonly property real workspaceThumbnailWidth: Style.space(180)
  readonly property var settingsOptions: [
    {
      kind: "altTab",
      label: "Alt+Tab: All Workspaces",
      description: "Include windows from every workspace. Off uses the current workspace."
    }
  ]
  readonly property string settingsPath:
    Quickshell.env("HOME") + "/.local/state/omarchy/settings/workspace-navigator.json"
  readonly property string safeConfigFileHelper:
    Quickshell.env("HOME")
    + "/.config/omarchy/plugins/roubilibo.workspace-navigator/bin/safe-config-file.py"
  readonly property string hyprBindingsPath:
    Quickshell.env("HOME") + "/.config/hypr/bindings.lua"
  property string settingsWriteText: ""
  property bool settingsWriteDirty: false
  property string launcherMenuWriteText: ""
  property bool launcherMenuWriteDirty: false
  property bool windowOpacityModeKnown: false
  property bool glassyWindowMode: false
  property bool windowOpacityProbePending: false
  property bool glassyRuleApplyPending: false
  readonly property string glassyRuleEvalCommand:
    'workspaceNavigatorGlassyRule = workspaceNavigatorGlassyRule or '
    + 'hl.layer_rule({ name = "workspace-navigator-glassy", '
    + 'match = { namespace = "^roubilibo-workspace-navigator$" }, '
    + 'blur = true, ignore_alpha = 0.3 }); '
    + 'workspaceNavigatorGlassyRule:set_enabled('
    + (root.glassyWindowMode ? "true" : "false") + '); '
    + 'workspaceNavigatorAltTabGlassyRule = workspaceNavigatorAltTabGlassyRule or '
    + 'hl.layer_rule({ name = "workspace-navigator-alt-tab-glassy", '
    + 'match = { namespace = "^roubilibo-workspace-navigator-alt-tab$" }, '
    + 'blur = true, ignore_alpha = 0.3 }); '
    + 'workspaceNavigatorAltTabGlassyRule:set_enabled('
    + (root.glassyWindowMode ? "true" : "false") + ')'
  readonly property string launcherMenuDirectory:
    Quickshell.env("HOME") + "/.config/omarchy/extensions"
  readonly property string launcherMenuPath:
    root.launcherMenuDirectory + "/omarchy-menu.jsonc"
  readonly property string launcherMenuEntryText:
    '  "setup.workspace-navigator": {"icon":"󰒓","label":"Workspace Navigator",'
    + '"description":"Configure Alt+Tab scope",'
    + '"action":"omarchy-shell roubilibo.workspace-navigator settings"}'
  function loadSettings(raw) {
    try {
      var settings = JSON.parse(String(raw || "{}"))
      if (settings.altTabScope === "all" || settings.altTabScope === "workspace")
        root.altTabScope = settings.altTabScope
      if (Array.isArray(settings.workspaceIds)) {
        var workspaceIds = []
        for (var i = 0; i < settings.workspaceIds.length; i++) {
          var id = root.positiveWorkspaceId(settings.workspaceIds[i])
          if (id > root.minimumWorkspaceCount && workspaceIds.indexOf(id) < 0)
            workspaceIds.push(id)
        }
        workspaceIds.sort(function(left, right) { return left - right })
        root.createdWorkspaceIds = workspaceIds
        root.workspaceRevision += 1
      }
    } catch (e) {}
  }

  function saveSettings() {
    root.settingsWriteText = JSON.stringify({
      altTabScope: root.altTabScope,
      workspaceIds: root.createdWorkspaceIds
    }, null, 2) + "\n"
    root.settingsWriteDirty = true
    if (!settingsWriteProcess.running) root.startSettingsWrite()
  }

  function startSettingsWrite() {
    if (!root.settingsWriteDirty || settingsWriteProcess.running) return
    root.settingsWriteDirty = false
    settingsWriteProcess.running = true
  }

  function setAltTabScope(value) {
    root.altTabScope = String(value) === "all" ? "all" : "workspace"
    root.settingsSelection = 0
    root.saveSettings()
    return "ok"
  }

  function openSettings() {
    root.open('{"mode":"settings"}')
  }

  function selectSettings(delta) {
    var count = root.settingsOptions.length
    if (count <= 0) return
    root.settingsSelection = (root.settingsSelection + delta + count) % count
  }

  function toggleSettingsOption(index) {
    var option = root.settingsOptions[index]
    if (!option) return
    root.settingsSelection = index
    if (option.kind === "altTab")
      root.setAltTabScope(root.altTabScope === "all"
        ? "workspace" : "all")
  }

  function activateSettingsSelection() {
    root.toggleSettingsOption(root.settingsSelection)
  }

  function stripLauncherMenuComments(raw) {
    return String(raw || "")
      .replace(/^\s*\/\/[^\n]*(\n|$)/gm, "")
      .replace(/,(\s*[}\]])/g, "$1")
  }

  function ensureLauncherMenuEntry(raw) {
    var current = String(raw || "")
    if (/^\s*"setup\.workspace-navigator"\s*:/m.test(current)) {
      // Update only the description previously generated by this plugin,
      // preserving other entries and user edits in the menu extension.
      var updated = current.replace(
        /("setup\.workspace-navigator"\s*:\s*\{[^}]*?"description"\s*:\s*)"Configure (?:swipe behavior, Alt\+Tab scope, and blur|swipe behavior and background blur|Alt\+Tab scope and overview blur|Alt\+Tab scope and background blur)"/,
        '$1"Configure Alt+Tab scope"')
      if (updated !== current) root.writeLauncherMenu(updated)
      return
    }

    if (current.trim() === "") {
      root.writeLauncherMenu("{\n" + root.launcherMenuEntryText + "\n}\n")
      return
    }

    var parsed = null
    try { parsed = JSON.parse(root.stripLauncherMenuComments(current)) } catch (e) {
      console.warn("workspace overview: could not parse omarchy menu extension", e)
      return
    }
    if (!parsed || Array.isArray(parsed) || typeof parsed !== "object"
        || parsed.items !== undefined) {
      console.warn("workspace overview: unsupported omarchy menu extension format")
      return
    }

    var closingBrace = current.lastIndexOf("}")
    if (closingBrace < 0) {
      console.warn("workspace overview: omarchy menu extension has no closing brace")
      return
    }

    var lines = current.split("\n")
    var closingLine = current.slice(0, closingBrace).split("\n").length - 1
    var priorLine = closingLine - 1
    while (priorLine >= 0
           && (lines[priorLine].trim() === ""
               || lines[priorLine].trim().indexOf("//") === 0))
      priorLine -= 1

    if (Object.keys(parsed).length > 0 && priorLine >= 0
        && lines[priorLine].trim() !== "{"
        && !lines[priorLine].trim().endsWith(","))
      lines[priorLine] += ","

    lines.splice(closingLine, 0, root.launcherMenuEntryText)
    root.writeLauncherMenu(lines.join("\n"))
  }

  function writeLauncherMenu(contents) {
    root.launcherMenuWriteText = String(contents)
    root.launcherMenuWriteDirty = true
    if (!launcherMenuWriteProcess.running) root.startLauncherMenuWrite()
  }

  function startLauncherMenuWrite() {
    if (!root.launcherMenuWriteDirty || launcherMenuWriteProcess.running) return
    root.launcherMenuWriteDirty = false
    launcherMenuWriteProcess.running = true
  }

  function refreshWindowOpacityMode() {
    if (windowOpacityModeProbe.running) {
      root.windowOpacityProbePending = true
      return
    }
    root.windowOpacityProbePending = false
    windowOpacityModeProbe.running = true
  }

  function applyWindowOpacityMode() {
    if (!root.windowOpacityModeKnown) return
    if (glassyRuleApplyProcess.running) {
      root.glassyRuleApplyPending = true
      return
    }
    root.glassyRuleApplyPending = false
    glassyRuleApplyProcess.running = true
  }

  Component.onCompleted: {
    settingsReadProcess.running = true
    launcherMenuReadProcess.running = true
    bindingSyncProcess.running = true
    root.rememberAltTabFocus(Hyprland.activeToplevel)
    root.refreshWindowOpacityMode()
  }

  function workspaceById(id, revision) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  function workspaceName(workspace, id) {
    if (!workspace) return ""
    var name = String(workspace.name || "").trim()
    return name !== "" && name !== String(id) ? name : ""
  }

  function positiveWorkspaceId(value) {
    var id = Number(value)
    if (!isFinite(id) || Math.floor(id) !== id || id <= 0
        || id > root.maximumWorkspaceId)
      return -1
    return id
  }

  // Keep five base workspaces visible. Additional workspaces are shown only
  // after the user adds them through the + card.
  function workspaceIds(revision) {
    var ids = []
    for (var i = 1; i <= root.minimumWorkspaceCount; i++) ids.push(i)

    for (var createdIndex = 0; createdIndex < root.createdWorkspaceIds.length; createdIndex++) {
      var createdId = root.positiveWorkspaceId(root.createdWorkspaceIds[createdIndex])
      if (createdId > root.minimumWorkspaceCount
          && ids.indexOf(createdId) === -1)
        ids.push(createdId)
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

  function ensureSelectionVisible() {
    Qt.callLater(function() {
      if (!root.workspaceScroller) return
      var cardWidth = root.workspaceScroller.thumbnailWidth
      var step = cardWidth + root.cardGap
      var left = root.workspaceScroller.cardsOffsetX
        + Math.max(0, root.selectedIndex * step)
      var right = left + cardWidth
      var viewLeft = root.workspaceScroller.contentX
      var viewRight = viewLeft + root.workspaceScroller.width
      if (left < viewLeft)
        root.workspaceScroller.contentX = left
      else if (right > viewRight)
        root.workspaceScroller.contentX = Math.min(
          left, root.workspaceScroller.contentWidth - root.workspaceScroller.width)
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

  function select(delta) {
    var count = root.workspaceEntries(root.workspaceRevision).length
    if (count <= 0) return
    root.selectedIndex = (root.selectedIndex + delta + count) % count
    root.ensureSelectionVisible()
  }

  function selectWorkspacePreview(id) {
    // The selected workspace owns the source WindowPreview in the large
    // canvas. Replacing it while a drag is over the strip destroys the active
    // DragHandler before the destination DropArea can finish the gesture.
    if (root.draggedToplevel) return
    var entries = root.workspaceEntries(root.workspaceRevision)
    for (var i = 0; i < entries.length; i++) {
      if (!entries[i].addWorkspace && Number(entries[i].id) === Number(id)) {
        root.selectedIndex = i
        return
      }
    }
  }

  function selectWorkspacePreviewAfterDrop(id) {
    var workspaceId = root.positiveWorkspaceId(id)
    if (workspaceId < 1) return
    Qt.callLater(function() {
      var entries = root.workspaceEntries(root.workspaceRevision)
      for (var i = 0; i < entries.length; i++) {
        if (!entries[i].addWorkspace && Number(entries[i].id) === workspaceId) {
          root.selectedIndex = i
          root.ensureSelectionVisible()
          return
        }
      }
    })
  }

  function selectRow(delta) {
    root.select(delta)
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
    root.closeWorkspaceContext()
    try {
      if (!root.dispatchFocusWorkspace(id)) return
    } catch (e) {
      console.warn("workspace overview: could not focus workspace", id, e)
    }
    root.dismiss()
  }

  function focusToplevel(toplevel) {
    var address = root.normalizedAddress(toplevel)
    if (!address) return

    root.altTabOpen = false
    var workspace = toplevel && toplevel.workspace ? toplevel.workspace : null
    var workspaceId = workspace ? root.positiveWorkspaceId(workspace.id) : -1
    var focusedWorkspaceId = Hyprland.focusedWorkspace
      ? root.positiveWorkspaceId(Hyprland.focusedWorkspace.id) : -1
    var ipc = toplevel ? toplevel.lastIpcObject : null
    var at = ipc && ipc.at && ipc.at.length >= 2 ? ipc.at : null
    var size = ipc && ipc.size && ipc.size.length >= 2 ? ipc.size : null

    // Hiding the layer surface can restore focus to the previously active
    // client, so close it before sending focus to the selected window.
    root.dismiss()

    Qt.callLater(function() {
      try {
        if (workspaceId > 0 && workspaceId !== focusedWorkspaceId)
          root.dispatchFocusWorkspace(workspaceId)

        if (Hyprland.usingLua) {
          Hyprland.dispatch("hl.dsp.focus({ window = \"address:" + address + "\" })")
        } else {
          Hyprland.dispatch("focuswindow address:" + address)
        }

        if (ipc && ipc.floating === true) {
          if (Hyprland.usingLua) {
            Hyprland.dispatch("hl.dsp.window.alter_zorder({ window = \"address:"
              + address + "\", mode = \"top\" })")
          } else {
            Hyprland.dispatch("alterzorder top,address:" + address)
          }
        }

        // follow_mouse is a global Hyprland input option. It is already enabled
        // on this system, so follow the selected window by moving the pointer to
        // its center instead of changing the user's global input configuration.
        if (at && size) {
          var x = Number(at[0]) + Number(size[0]) / 2
          var y = Number(at[1]) + Number(size[1]) / 2
          if (isFinite(x) && isFinite(y))
            Hyprland.dispatch("hl.dsp.cursor.move({ x = " + String(Math.round(x))
              + ", y = " + String(Math.round(y)) + " })")
        } else if (Hyprland.usingLua) {
          // Keep the follow behavior for clients whose IPC geometry is not yet
          // exposed by Quickshell; corner 0 is only a fallback target.
          Hyprland.dispatch("hl.dsp.cursor.move_to_corner({ window = \"address:"
            + address + "\", corner = 0 })")
        }
        root.selectedToplevel = toplevel
      } catch (e) {
        console.warn("workspace overview: could not focus window", address, e)
      }
    })
  }

  function rememberAltTabFocus(toplevel) {
    var address = root.normalizedAddress(toplevel)
    if (!address) return

    // Highlighting a card is not a real focus change. If an external focus
    // change arrives while the switcher is open, apply it only after the
    // session ends so the MRU order remains stable during selection.
    if (root.altTabOpen) {
      root.altTabDeferredFocusAddress = address
      return
    }

    root.rememberAltTabAddress(address)
  }

  function rememberAltTabAddress(address) {
    var normalized = root.normalizedAddress(address)
    if (!normalized) return
    var history = [normalized]
    for (var i = 0; i < root.altTabFocusHistory.length && history.length < 128; i++) {
      var previous = root.altTabFocusHistory[i]
      if (previous !== normalized) history.push(previous)
    }
    root.altTabFocusHistory = history
  }

  function syncAltTabFocusHistory() {
    // A live switcher owns its snapshot. Do not let model refreshes reorder
    // the real MRU list while the user is cycling through it.
    if (root.altTabOpen) return

    var values = []
    try { values = Hyprland.toplevels.values } catch (e) {}
    var present = {}
    var eligible = []
    for (var i = 0; i < values.length; i++) {
      var address = root.normalizedAddress(values[i])
      var ipc = values[i] ? values[i].lastIpcObject : null
      if (!address || (ipc && ipc.hidden === true) || present[address]) continue
      present[address] = true
      eligible.push(values[i])
    }

    var activeAddress = root.normalizedAddress(Hyprland.activeToplevel)
    var ordered = WindowModel.sortAltTabByRecency(
      eligible, activeAddress, root.altTabFocusHistory)
    var history = []
    var seen = {}
    for (var h = 0; h < root.altTabFocusHistory.length; h++) {
      var remembered = root.altTabFocusHistory[h]
      if (present[remembered] && !seen[remembered]) {
        history.push(remembered)
        seen[remembered] = true
      }
    }
    for (var o = 0; o < ordered.length; o++) {
      var orderedAddress = root.normalizedAddress(ordered[o])
      if (orderedAddress && !seen[orderedAddress]) {
        history.push(orderedAddress)
        seen[orderedAddress] = true
      }
    }

    // The active window is always the head of the real MRU list. This also
    // repairs the initial state when the plugin starts after the first focus
    // event has already happened.
    if (activeAddress && present[activeAddress]) {
      var activeHistory = [activeAddress]
      for (var a = 0; a < history.length && activeHistory.length < 128; a++) {
        if (history[a] !== activeAddress) activeHistory.push(history[a])
      }
      history = activeHistory
    }
    root.altTabFocusHistory = history.slice(0, 128)
  }

  function forgetAltTabWindow(event) {
    var parts = []
    try { parts = event && event.parse ? event.parse(1) : [] } catch (e) {}
    var address = WindowModel.normalizedAddress(parts && parts[0])
    if (!address)
      address = WindowModel.normalizedAddress(
        String(event && event.data ? event.data : "").split(",")[0])
    if (!address) return

    // Keep the real MRU immutable during a switcher session. The closed
    // address is removed from the live snapshot immediately below and from
    // the MRU on the next closed-state sync.
    if (!root.altTabOpen) {
      var history = []
      for (var i = 0; i < root.altTabFocusHistory.length; i++) {
        if (root.altTabFocusHistory[i] !== address)
          history.push(root.altTabFocusHistory[i])
      }
      root.altTabFocusHistory = history
    }

    if (!root.altTabOpen) return
    var closed = Object.assign({}, root.altTabClosedAddresses)
    closed[address] = true
    root.altTabClosedAddresses = closed
    root.reconcileAltTabCandidates()
  }

  function altTabWindowList() {
    root.syncAltTabFocusHistory()
    var values = []
    try { values = Hyprland.toplevels.values } catch (e) {}

    // Keep closed addresses excluded until Quickshell's model has actually
    // dropped them; an immediate refresh can still expose the old object.
    var present = {}
    for (var p = 0; p < values.length; p++) {
      var presentAddress = root.normalizedAddress(values[p])
      if (presentAddress) present[presentAddress] = true
    }
    var closed = {}
    for (var key in root.altTabClosedAddresses) {
      if (present[key]) closed[key] = true
    }
    root.altTabClosedAddresses = closed

    var currentWorkspaceId = Hyprland.focusedWorkspace
      ? root.positiveWorkspaceId(Hyprland.focusedWorkspace.id) : -1
    var result = []
    for (var i = 0; i < values.length; i++) {
      var toplevel = values[i]
      var address = root.normalizedAddress(toplevel)
      var workspace = toplevel && toplevel.workspace ? toplevel.workspace : null
      var workspaceId = workspace ? root.positiveWorkspaceId(workspace.id) : -1
      var ipc = toplevel ? toplevel.lastIpcObject : null
      if (!address || root.altTabClosedAddresses[address] || workspaceId < 1)
        continue
      if (ipc && ipc.hidden === true) continue
      if (root.altTabScope === "workspace" && workspaceId !== currentWorkspaceId)
        continue
      result.push(toplevel)
    }
    return WindowModel.sortAltTabByRecency(result,
      root.normalizedAddress(Hyprland.activeToplevel), root.altTabFocusHistory)
  }

  function refreshAltTabCandidates() {
    root.altTabCandidates = root.altTabWindowList()
  }

  function reconcileAltTabCandidates() {
    if (!root.altTabOpen) return
    var selected = root.altTabCandidates[root.altTabIndex]
    var updated = WindowModel.reconcileAltTabCandidates(
      root.altTabCandidates, root.altTabWindowList(),
      root.normalizedAddress(selected), root.altTabIndex, false)
    if (updated.candidates.length === 0) {
      root.altTabCancel()
      return
    }
    root.altTabCandidates = updated.candidates
    root.altTabSnapshot = updated.candidates.slice()
    root.altTabIndex = updated.index
    root.selectedToplevel = updated.candidates[updated.index]
  }

  function altTabWorkspaceLabel(toplevel) {
    var workspace = toplevel && toplevel.workspace ? toplevel.workspace : null
    var id = workspace ? root.positiveWorkspaceId(workspace.id) : -1
    var name = root.workspaceName(workspace, id)
    if (id < 1) return ""
    return name === "" ? "WS " + String(id) : name
  }

  function altTabStep(reverse) {
    if (!root.altTabOpen) {
      try {
        Hyprland.refreshWorkspaces()
        Hyprland.refreshToplevels()
      } catch (e) {}
      root.syncAltTabFocusHistory()
      var snapshot = root.altTabWindowList()
      root.altTabSnapshot = snapshot.slice()
      root.altTabCandidates = root.altTabSnapshot.slice()
      var count = root.altTabSnapshot.length
      if (count <= 0) return

      var activeAddress = root.normalizedAddress(Hyprland.activeToplevel)
      var activeIndex = -1
      for (var i = 0; i < count; i++) {
        if (root.normalizedAddress(root.altTabSnapshot[i]) === activeAddress) {
          activeIndex = i
          break
        }
      }
      if (activeIndex < 0) activeIndex = 0
      // The real MRU list has the active window at index 0. The first normal
      // Alt+Tab therefore always selects snapshot[1], independent of the
      // compositor's toplevel enumeration order.
      root.altTabIndex = count === 1 ? 0
        : (reverse ? count - 1 : 1)
      if (!root.altTabCommitPending) root.altTabCommitHandled = false
      root.altTabOpen = true
    } else {
      root.reconcileAltTabCandidates()
      if (!root.altTabOpen) return
      var candidateCount = root.altTabCandidates.length
      if (candidateCount <= 0) return
      root.altTabIndex = (root.altTabIndex + (reverse ? -1 : 1) + candidateCount)
        % candidateCount
    }
    root.selectedToplevel = root.altTabCandidates[root.altTabIndex] || null
    if (root.altTabCommitPending) {
      altTabPendingStartTimer.stop()
      // A held Tab key can keep repeating after Alt is released. Do not let
      // those repeats postpone the queued release commit indefinitely.
      if (!altTabPendingCommitTimer.running)
        altTabPendingCommitTimer.start()
    }
  }

  function clearPendingAltTabCommit() {
    root.altTabCommitPending = false
    altTabPendingStartTimer.stop()
    altTabPendingCommitTimer.stop()
  }

  function altTabCommit() {
    if (!root.altTabOpen) {
      if (root.altTabCommitHandled || root.altTabCommitPending) return
      // The release binding can arrive before shell summon has opened the
      // first Alt+Tab step. Keep that release until the session is ready.
      root.altTabCommitPending = true
      altTabPendingStartTimer.restart()
      return
    }
    root.altTabCommitHandled = true
    root.clearPendingAltTabCommit()
    root.reconcileAltTabCandidates()
    if (!root.altTabOpen) return
    var selected = root.altTabCandidates[root.altTabIndex]
    if (!selected) {
      root.altTabCancel()
      return
    }
    // Close the switcher before dispatching focus. This also keeps the
    // release binding reliable if a client disappears between two tabs.
    altTabRefreshTimer.stop()
    root.altTabOpen = false
    root.altTabIndex = -1
    root.altTabCandidates = []
    root.altTabSnapshot = []
    root.altTabDeferredFocusAddress = ""
    root.selectedToplevel = null
    root.focusToplevel(selected)
  }

  function closeAltTabSession(applyDeferredFocus) {
    root.altTabCommitHandled = true
    root.clearPendingAltTabCommit()
    altTabRefreshTimer.stop()
    var deferred = root.altTabDeferredFocusAddress
    root.altTabDeferredFocusAddress = ""
    root.altTabOpen = false
    root.altTabIndex = -1
    root.altTabCandidates = []
    root.altTabSnapshot = []
    root.selectedToplevel = null
    if (applyDeferredFocus && deferred)
      root.rememberAltTabAddress(deferred)
  }

  function altTabCancel() {
    root.closeAltTabSession(true)
  }

  function openWorkspaceContext(id, x, y) {
    var workspaceId = root.positiveWorkspaceId(id)
    if (workspaceId < 1) return
    var workspace = root.workspaceById(workspaceId, root.workspaceRevision)
    root.contextWorkspaceId = workspaceId
    root.contextMenuX = Number(x) || 0
    root.contextMenuY = Number(y) || 0
    root.contextRenameText = root.workspaceName(workspace, workspaceId)
    root.contextRenameMode = false
    root.workspaceContextOpen = true
  }

  function closeWorkspaceContext() {
    root.workspaceContextOpen = false
    root.contextRenameMode = false
    root.contextWorkspaceId = -1
  }

  function contextWorkspace() {
    return root.workspaceById(root.contextWorkspaceId, root.workspaceRevision)
  }

  function contextCanMoveSelectedWindow() {
    var workspace = root.contextWorkspace()
    var selectedWorkspace = root.selectedToplevel && root.selectedToplevel.workspace
      ? root.positiveWorkspaceId(root.selectedToplevel.workspace.id) : -1
    return workspace !== null && root.normalizedAddress(root.selectedToplevel) !== ""
      && selectedWorkspace > 0 && selectedWorkspace !== root.contextWorkspaceId
  }

  function beginWorkspaceRename() {
    if (!root.contextWorkspace()) return
    root.contextRenameText = root.workspaceName(
      root.contextWorkspace(), root.contextWorkspaceId)
    root.contextRenameMode = true
  }

  function cancelWorkspaceRename() {
    root.contextRenameMode = false
    root.contextRenameText = ""
  }

  function luaString(value) {
    return String(value || "")
      .replace(/[\u0000-\u001f\u007f]/g, " ")
      .replace(/\\/g, "\\\\")
      .replace(/\"/g, "\\\"")
      .slice(0, 80)
  }

  function commitWorkspaceRename() {
    var name = root.luaString(root.contextRenameText).trim()
    if (name === "") return
    var id = root.positiveWorkspaceId(root.contextWorkspaceId)
    if (id < 1) return

    try {
      if (Hyprland.usingLua)
        Hyprland.dispatch("hl.dsp.workspace.rename({ workspace = \""
          + String(id) + "\", name = \"" + name + "\" })")
      else
        Hyprland.dispatch("renameworkspace " + String(id) + " " + name)
      root.cancelWorkspaceRename()
      root.closeWorkspaceContext()
      refreshTimer.restart()
    } catch (e) {
      console.warn("workspace overview: could not rename workspace", id, e)
    }
  }

  function makeWorkspacePersistent() {
    var id = root.positiveWorkspaceId(root.contextWorkspaceId)
    if (id < 1 || workspacePersistProcess.running) return
    root.pendingWorkspacePersistId = id
    root.closeWorkspaceContext()
    workspacePersistProcess.running = true
  }

  function toggleWorkspacePersistence() {
    var id = root.positiveWorkspaceId(root.contextWorkspaceId)
    if (id < 1) return
    if (!root.isMenuPersistentWorkspace(id)) {
      root.makeWorkspacePersistent()
      return
    }
    if (workspaceUnpersistProcess.running) return
    root.pendingWorkspaceUnpersistId = id
    root.pendingWorkspaceDeleteId = -1
    root.closeWorkspaceContext()
    workspaceUnpersistProcess.running = true
  }

  function isMenuPersistentWorkspace(id) {
    return root.menuPersistentWorkspaceIds.indexOf(
      root.positiveWorkspaceId(id)) >= 0
  }

  function moveSelectedWindowToContext() {
    if (!root.contextCanMoveSelectedWindow()) return
    var id = root.contextWorkspaceId
    var toplevel = root.selectedToplevel
    root.closeWorkspaceContext()
    root.moveWindowToWorkspace(toplevel, id)
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
    root.saveSettings()
    root.workspaceRevision += 1

    try {
      // Keep the overview open while creating the workspace so its thumbnail
      // becomes visible immediately. The workspace is not followed here.
      root.dispatchFocusWorkspace(id)
      Hyprland.refreshWorkspaces()
      Hyprland.refreshToplevels()
    } catch (e) {
      console.warn("workspace overview: could not create workspace", id, e)
    }

    Qt.callLater(function() {
      root.selectedIndex = root.workspaceEntries(root.workspaceRevision).length - 1
      root.ensureSelectionVisible()
    })
  }

  function normalizedAddress(toplevel) {
    if (!toplevel) return ""
    return WindowModel.normalizedAddress(
      toplevel.address || (toplevel.lastIpcObject && toplevel.lastIpcObject.address))
  }

  function snapshotWorkspacePreviews() {
    var snapshots = {}
    var workspaces = []
    try { workspaces = Hyprland.workspaces.values } catch (e) {}
    var activeAddress = Hyprland.activeToplevel
      ? Hyprland.activeToplevel.address : ""
    for (var i = 0; i < workspaces.length; i++) {
      var workspace = workspaces[i]
      var id = root.positiveWorkspaceId(workspace && workspace.id)
      if (id < 1 || !workspace.toplevels) continue
      try {
        snapshots[String(id)] = WindowModel.resolveWorkspacePreviews(
          workspace.toplevels.values, activeAddress)
      }
      catch (e) { snapshots[String(id)] = [] }
    }
    root.dragWorkspaceToplevelSnapshots = snapshots
  }

  function workspaceToplevelSnapshot(workspaceId) {
    if (!root.draggedToplevel || !root.dragWorkspaceToplevelSnapshots) return null
    var id = root.positiveWorkspaceId(workspaceId)
    return id > 0 && Object.prototype.hasOwnProperty.call(
      root.dragWorkspaceToplevelSnapshots, String(id))
      ? root.dragWorkspaceToplevelSnapshots[String(id)] : null
  }

  function selectWindow(toplevel) {
    var address = root.normalizedAddress(toplevel)
    root.selectedToplevel = address !== "" ? toplevel : null
  }

  function beginWindowDrag(toplevel, fromWorkspaceCanvas) {
    root.refreshAfterDrag = false
    root.dragGeometryOverrides = ({})
    root.dragGeometryRevision += 1
    root.draggedFromWorkspaceCanvas = Boolean(fromWorkspaceCanvas)
    root.dragShrinkProgress = fromWorkspaceCanvas ? 0.28 : 0
    root.dragPreviewFrozen = false
    root.draggedToplevel = toplevel
    root.snapshotWorkspacePreviews()
    var ipc = toplevel && toplevel.lastIpcObject
    var address = root.normalizedAddress(toplevel)
    var workspaceId = toplevel && toplevel.workspace
      ? root.positiveWorkspaceId(toplevel.workspace.id) : -1
    var x = ipc && ipc.at ? Number(ipc.at[0]) : NaN
    var y = ipc && ipc.at ? Number(ipc.at[1]) : NaN
    var width = ipc && ipc.size ? Number(ipc.size[0]) : NaN
    var height = ipc && ipc.size ? Number(ipc.size[1]) : NaN
    root.dragStartState = address && workspaceId > 0
      ? ({ address: address, floating: Boolean(ipc && ipc.floating === true),
           x: x, y: y, hasPosition: isFinite(x) && isFinite(y),
           width: width, height: height,
           hasSize: isFinite(width) && isFinite(height),
           workspaceId: workspaceId, temporarilyFloated: false }) : null
    root.dragProbeAddress = address
    root.dragProbeWorkspaceId = workspaceId
    root.lastDispatchedDragPosition = null
    root.lastObservedDragPosition = null
    // This probe keeps the preview geometry live while preserving the
    // delegate snapshot that owns the active DragHandler.
    dragStateProbeTimer.start()
    root.logDrag("gesture-start", {
      address: address, workspaceId: workspaceId,
      floatingAtStart: Boolean(ipc && ipc.floating === true),
      source: fromWorkspaceCanvas ? "canvas" : "strip",
      startSize: isFinite(width) && isFinite(height) ? [width, height] : null,
      startPosition: isFinite(x) && isFinite(y) ? [x, y] : null
    })

    // DragHandler reports active only after its pickup threshold is crossed.
    // Defer one event-loop turn so it can finish establishing the drag proxy,
    // then reflow the real source workspace just like Hyprland's mouse drag.
    if (root.dragStartState && !root.dragStartState.floating
        && Hyprland.usingLua) {
      dragDetachTimer.restart()
    }
  }

  function detachDraggedTiledWindow() {
    var state = root.dragStartState
    if (!state || !root.draggedToplevel || state.floating
        || state.temporarilyFloated)
      return
    state.temporarilyFloated = root.dispatchWindowFloat(state.address, true)
    if (state.temporarilyFloated && state.hasSize) {
      // Match Hyprland's native SUPER+drag pickup: it remembers a floating
      // size at 84.89% of the tiled size before taking the window out of the
      // layout. Without this, float() restores an old floating size, which
      // can be much larger than the tile that was picked up.
      var floatingSize = [
        Math.max(20, Math.floor(state.width * 0.8489)),
        Math.max(20, Math.floor(state.height * 0.8489))
      ]
      state.nativeFloatingSize = floatingSize
      root.dispatchWindowResize(state.address, floatingSize)

      var ipc = root.draggedToplevel.lastIpcObject
      var previewIpc = Object.assign({}, ipc || {})
      previewIpc.size = floatingSize
      previewIpc.floating = true
      var overrides = Object.assign({}, root.dragGeometryOverrides)
      overrides[state.address] = previewIpc
      root.dragGeometryOverrides = overrides
      root.dragGeometryRevision += 1
    }
    root.logDrag("temporary-float", {
      address: state.address, requested: true,
      dispatched: state.temporarilyFloated,
      nativeFloatingSize: state.nativeFloatingSize || null
    })
  }

  function dispatchWindowResize(address, size) {
    if (!address || !size || size.length < 2
        || !isFinite(Number(size[0])) || !isFinite(Number(size[1]))
        || Number(size[0]) < 1 || Number(size[1]) < 1
        || !Hyprland.usingLua)
      return false
    try {
      root.logDrag("dispatch-native-drag-size", {
        targetAddress: address, size: [Number(size[0]), Number(size[1])]
      })
      Hyprland.dispatch("hl.dsp.window.resize({ x = " + String(size[0])
        + ", y = " + String(size[1])
        + ", relative = false, window = \"address:" + address + "\" })")
      return true
    } catch (e) {
      console.warn("workspace overview: could not apply native drag size",
        address, size, e)
      return false
    }
  }

  function logDrag(eventName, details, throttleMs) {
    if (!root.debugDrag) return
    var now = Date.now()
    var interval = Math.max(0, Number(throttleMs) || 0)
    var key = String(eventName || "unknown")
    if (interval > 0 && now - Number(root.dragLogTimes[key] || 0) < interval)
      return
    if (interval > 0) {
      var times = Object.assign({}, root.dragLogTimes)
      times[key] = now
      root.dragLogTimes = times
    }
    var state = root.dragStartState
    var entry = {
      time: now,
      event: String(eventName || "unknown"),
      address: state ? state.address : "",
      sourceWorkspaceId: state ? state.workspaceId : -1,
      floatingAtStart: state ? state.floating : null,
      temporarilyFloated: state ? state.temporarilyFloated : false
    }
    if (details && typeof details === "object") Object.assign(entry, details)
    console.log("[workspace-navigator][drag] " + JSON.stringify(entry))
  }

  function updateDragShrinkProgress(pointerX, pointerY) {
    if (!root.draggedFromWorkspaceCanvas || !root.workspaceScroller
        || !root.dragOverlayItem
        || !isFinite(Number(pointerX)) || !isFinite(Number(pointerY))) {
      root.dragShrinkProgress = 0
      return
    }
    // Use the cursor's distance to the whole strip in one coordinate space.
    // The large preview and the strip use different local origins, so mixing
    // their local y values makes the thumbnail shrink much too early.
    var stripTopLeft = root.workspaceScroller.mapToItem(
      root.dragOverlayItem, 0, 0)
    var stripRight = stripTopLeft.x + root.workspaceScroller.width
    var stripBottom = stripTopLeft.y + root.workspaceScroller.height
    var dx = Math.max(stripTopLeft.x - Number(pointerX), 0,
      Number(pointerX) - stripRight)
    var dy = Math.max(stripTopLeft.y - Number(pointerY), 0,
      Number(pointerY) - stripBottom)
    var distance = Math.sqrt(dx * dx + dy * dy)
    var proximity = Math.max(1, Style.space(180))
    var approach = Math.max(0, Math.min(1, 1 - distance / proximity))
    approach = approach * approach * (3 - 2 * approach)
    root.dragShrinkProgress = 0.28 + 0.72 * approach
  }

  function endWindowDrag(toplevel) {
    dragDetachTimer.stop()
    floatingDragMoveTimer.stop()
    dragStateProbeTimer.stop()
    root.pendingFloatingDragMove = null
    root.dragShrinkProgress = 0
    root.draggedFromWorkspaceCanvas = false
    root.dragPreviewFrozen = false
    var droppedWorkspaceId = root.pendingWindowDrop
      && root.pendingWindowDrop.address === root.normalizedAddress(toplevel)
      ? root.pendingWindowDrop.workspaceId : -1
    root.logDrag("gesture-finish", {
      address: root.normalizedAddress(toplevel),
      droppedWorkspaceId: droppedWorkspaceId,
      dropPending: Boolean(root.pendingWindowDrop)
    })
    if (root.draggedToplevel === toplevel && root.dragStartState) {
      var dropPending = root.pendingWindowDrop
        && root.pendingWindowDrop.address === root.dragStartState.address
      if (root.dragStartState.temporarilyFloated) {
        // DropArea and DragHandler can finish in either order. Retile only
        // when no drop transaction owns the destination.
        if (!dropPending)
          root.dispatchWindowFloat(root.dragStartState.address, false)
      } else if (!dropPending && root.dragStartState.floating
          && root.dragStartState.hasPosition) {
        root.dispatchWindowPosition(root.dragStartState.address,
          { x: root.dragStartState.x, y: root.dragStartState.y })
      }
      root.refreshAfterDrag = true
    }
    if (!root.draggedToplevel || root.draggedToplevel === toplevel)
      root.draggedToplevel = null
    root.dragStartState = null
    if (root.refreshAfterDrag) {
      root.refreshAfterDrag = false
      dragRefreshTimer.restart()
    }
    if (droppedWorkspaceId > 0)
      root.selectWorkspacePreviewAfterDrop(droppedWorkspaceId)
  }

  function moveWindowToWorkspace(toplevel, workspaceId) {
    var address = root.normalizedAddress(toplevel)
    var id = root.positiveWorkspaceId(workspaceId)
    if (!address || id < 1) return

    try {
      root.dispatchWorkspaceMove(address, id)
      root.refreshAfterWindowAction(toplevel)
    } catch (e) {
      console.warn("workspace overview: could not move window", address, id, e)
    }
  }

  function isFloatingWindow(toplevel) {
    var ipc = toplevel && toplevel.lastIpcObject
    return Boolean(ipc && ipc.floating === true)
  }

  function dispatchWindowFloat(address, floating) {
    if (!address) return false
    try {
      root.logDrag("dispatch-float", {
        targetAddress: address, floating: Boolean(floating),
        backend: Hyprland.usingLua ? "lua" : "legacy"
      })
      if (Hyprland.usingLua) {
        Hyprland.dispatch('hl.dsp.window.float({ action = "'
          + (floating ? "on" : "off") + '", window = "address:'
          + address + '" })')
      } else {
        Hyprland.dispatch("togglefloating,address:" + address)
      }
      return true
    } catch (e) {
      console.warn("workspace overview: could not change window floating state",
        address, floating, e)
      return false
    }
  }

  function wasFloatingAtDragStart(toplevel) {
    var address = root.normalizedAddress(toplevel)
    return root.dragStartState && address === root.dragStartState.address
      ? root.dragStartState.floating : root.isFloatingWindow(toplevel)
  }

  function dispatchWorkspaceMove(address, workspaceId) {
    root.logDrag("dispatch-workspace", {
      targetAddress: address, targetWorkspaceId: Number(workspaceId)
    })
    if (Hyprland.usingLua) {
      Hyprland.dispatch("hl.dsp.window.move({ workspace = \""
        + String(workspaceId) + "\", window = \"address:" + address
        + "\", follow = false })")
    } else {
      Hyprland.dispatch("movetoworkspacesilent " + String(workspaceId)
        + ",address:" + address)
    }
  }

  function swapTiledWindows(sourceToplevel, targetToplevel, dropIntent) {
    var sourceAddress = root.normalizedAddress(sourceToplevel)
    var targetAddress = root.normalizedAddress(targetToplevel)
    root.logDrag("tiled-swap-request", {
      sourceAddress: sourceAddress, targetAddress: targetAddress
    })
    // The source remains on its original workspace while temporarily floating.
    var sourceWorkspaceId = root.dragStartState
      && sourceAddress === root.dragStartState.address
      ? root.dragStartState.workspaceId
      : (sourceToplevel && sourceToplevel.workspace
        ? root.positiveWorkspaceId(sourceToplevel.workspace.id) : -1)
    var targetWorkspaceId = targetToplevel && targetToplevel.workspace
      ? root.positiveWorkspaceId(targetToplevel.workspace.id) : -1
    if (!Hyprland.usingLua || !sourceAddress || !targetAddress
        || sourceAddress === targetAddress || sourceWorkspaceId < 1
        || sourceWorkspaceId !== targetWorkspaceId
        || root.wasFloatingAtDragStart(sourceToplevel)
        || root.isFloatingWindow(targetToplevel)
        || cursorProbe.running || tiledSwapStateProbe.running
        || tiledSwapStateProbeTimer.running || root.pendingTiledSwap)
      return false

    root.pendingTiledSwap = {
      sourceAddress: sourceAddress,
      targetAddress: targetAddress,
      workspaceId: sourceWorkspaceId,
      dropIntent: dropIntent || null,
      attempts: 0
    }
    cursorProbe.running = true
    return true
  }

  function finishTiledWindowSwap(exitCode, cursorPosition) {
    var swap = root.pendingTiledSwap
    if (!swap) return
    if (exitCode !== 0) {
      root.pendingTiledSwap = null
      console.warn("workspace overview: could not read cursor after tiled drop",
        exitCode)
      return
    }

    var match = String(cursorPosition || "").match(
      /^\s*(-?\d+)\s*,\s*(-?\d+)\s*$/)
    if (!match) {
      root.pendingTiledSwap = null
      console.warn("workspace overview: could not parse cursor position",
        cursorPosition)
      return
    }
    var x = Number(match[1])
    var y = Number(match[2])
    if (!isFinite(x) || !isFinite(y) || Math.floor(x) !== x
        || Math.floor(y) !== y || Math.abs(x) > root.maximumWorkspaceId
        || Math.abs(y) > root.maximumWorkspaceId) {
      root.pendingTiledSwap = null
      console.warn("workspace overview: refusing invalid cursor position",
        cursorPosition)
      return
    }

    // The QML toplevel model can lag behind the float-off dispatcher. Check
    // Hyprland's current client list and retry until both windows are tiled
    // again instead of rejecting a valid drop against stale lastIpcObject data.
    swap.cursorX = x
    swap.cursorY = y
    root.pendingTiledSwap = swap
    root.probeTiledWindowSwapState()
  }

  function probeTiledWindowSwapState() {
    if (!root.pendingTiledSwap || tiledSwapStateProbe.running) return
    tiledSwapStateProbe.running = true
  }

  function tiledDropPlacement(source, target, dropIntent) {
    if (!dropIntent || !source || !target
        || !Array.isArray(source.at) || source.at.length < 2
        || !Array.isArray(source.size) || source.size.length < 2
        || !Array.isArray(target.at) || target.at.length < 2
        || !Array.isArray(target.size) || target.size.length < 2)
      return null

    var sx = Number(source.at[0]), sy = Number(source.at[1])
    var sw = Number(source.size[0]), sh = Number(source.size[1])
    var tx = Number(target.at[0]), ty = Number(target.at[1])
    var tw = Number(target.size[0]), th = Number(target.size[1])
    if (![sx, sy, sw, sh, tx, ty, tw, th].every(isFinite)
        || sw <= 0 || sh <= 0 || tw <= 0 || th <= 0)
      return null

    // Determine which dimension Hyprland used for this split from the
    // windows' actual post-retile rectangles. This keeps the placement check
    // independent of Dwindle's current split direction.
    var overlapX = Math.max(0, Math.min(sx + sw, tx + tw) - Math.max(sx, tx))
    var overlapY = Math.max(0, Math.min(sy + sh, ty + th) - Math.max(sy, ty))
    var overlapRatioX = overlapX / Math.min(sw, tw)
    var overlapRatioY = overlapY / Math.min(sh, th)
    var axis = overlapRatioY > overlapRatioX ? "x" : "y"
    var siblingOverlap = axis === "x" ? overlapRatioY : overlapRatioX
    var splitOverlap = axis === "x" ? overlapRatioX : overlapRatioY
    // A floating-sized source can briefly overlap the expanded target tile
    // before Dwindle publishes the settled tiled rectangles. Do not mistake
    // that transient geometry for the result of a real split.
    if (siblingOverlap < 0.75 || splitOverlap > 0.25) return null

    var sourceCenter = axis === "x" ? sx + sw / 2 : sy + sh / 2
    var targetCenter = axis === "x" ? tx + tw / 2 : ty + th / 2
    var separation = sourceCenter - targetCenter
    if (Math.abs(separation) < 1) return null

    var ratio = Number(axis === "x" ? dropIntent.x : dropIntent.y)
    if (!isFinite(ratio)) return null
    var sourceSide = separation > 0 ? "second" : "first"
    var requestedSide = ratio >= 0.5 ? "second" : "first"
    return {
      axis: axis,
      ratio: ratio,
      sourceSide: sourceSide,
      requestedSide: requestedSide,
      alreadyAtRequestedSide: sourceSide === requestedSide,
      sourceRect: [sx, sy, sw, sh],
      targetRect: [tx, ty, tw, th]
    }
  }

  function finishTiledWindowSwapState(exitCode, output) {
    var swap = root.pendingTiledSwap
    if (!swap) return

    var clients = null
    if (exitCode === 0) {
      try { clients = JSON.parse(String(output || "")) } catch (e) {}
    }
    var source = null
    var target = null
    if (Array.isArray(clients)) {
      for (var i = 0; i < clients.length; i++) {
        var client = clients[i]
        var address = root.normalizedAddress(client)
        if (address === swap.sourceAddress) source = client
        if (address === swap.targetAddress) target = client
      }
    }

    var sourceWorkspaceId = source && source.workspace
      && source.workspace.id !== undefined
      ? root.positiveWorkspaceId(source.workspace.id) : -1
    var targetWorkspaceId = target && target.workspace
      && target.workspace.id !== undefined
      ? root.positiveWorkspaceId(target.workspace.id) : -1
    var sourceFloating = Boolean(source && source.floating === true)
    var targetFloating = Boolean(target && target.floating === true)
    var ready = Boolean(source && target && !sourceFloating && !targetFloating
      && sourceWorkspaceId === swap.workspaceId
      && targetWorkspaceId === swap.workspaceId)

    if (!ready) {
      swap.attempts = Number(swap.attempts || 0) + 1
      var reason = !Array.isArray(clients) ? "invalid-client-list"
        : !source ? "source-missing" : !target ? "target-missing"
        : sourceFloating ? "source-still-floating"
        : targetFloating ? "target-floating"
        : sourceWorkspaceId !== swap.workspaceId ? "source-workspace-changed"
        : "target-workspace-changed"
      root.logDrag("tiled-swap-state-pending", {
        sourceAddress: swap.sourceAddress,
        targetAddress: swap.targetAddress,
        attempt: swap.attempts, maxAttempts: 12, reason: reason,
        sourceFloating: source ? sourceFloating : null,
        sourceWorkspaceId: sourceWorkspaceId,
        targetFloating: target ? targetFloating : null,
        targetWorkspaceId: targetWorkspaceId
      })
      if (swap.attempts >= 12) {
        root.pendingTiledSwap = null
        root.logDrag("tiled-swap-state-timeout", {
          sourceAddress: swap.sourceAddress,
          targetAddress: swap.targetAddress,
          reason: reason,
          sourceFloating: source ? sourceFloating : null,
          sourceWorkspaceId: sourceWorkspaceId,
          targetFloating: target ? targetFloating : null,
          targetWorkspaceId: targetWorkspaceId
        })
        console.warn("workspace overview: tiled swap state did not settle",
          swap.sourceAddress, swap.targetAddress, reason)
        return
      }
      root.pendingTiledSwap = swap
      tiledSwapStateProbeTimer.restart()
      return
    }

    root.pendingTiledSwap = null
    root.logDrag("tiled-swap-state-ready", {
      sourceAddress: swap.sourceAddress,
      targetAddress: swap.targetAddress,
      attempt: Number(swap.attempts || 0) + 1,
      sourceFloating: sourceFloating,
      sourceWorkspaceId: sourceWorkspaceId,
      targetFloating: targetFloating,
      targetWorkspaceId: targetWorkspaceId
    })

    var placement = root.tiledDropPlacement(source, target, swap.dropIntent)
    if (placement && placement.alreadyAtRequestedSide) {
      root.logDrag("tiled-swap-skipped-drop-slot-already-matches", {
        sourceAddress: swap.sourceAddress,
        targetAddress: swap.targetAddress,
        axis: placement.axis,
        ratio: placement.ratio,
        sourceSide: placement.sourceSide,
        requestedSide: placement.requestedSide,
        sourceRect: placement.sourceRect,
        targetRect: placement.targetRect
      })
    } else {
      try {
        // Use the window-scoped dispatcher so Hyprland receives both the
        // dragged source and the tile under the drop. The global swap dispatcher
        // acts on the active window, which the overview does not change.
        Hyprland.dispatch("hl.dsp.window.swap({ window = \"address:"
          + swap.sourceAddress + "\", target = \"address:"
          + swap.targetAddress + "\" })")
        root.logDrag("tiled-swap-dispatched", {
          sourceAddress: swap.sourceAddress, targetAddress: swap.targetAddress,
          sourceWorkspaceId: sourceWorkspaceId,
          targetWorkspaceId: targetWorkspaceId,
          placement: placement || null
        })
      } catch (e) {
        console.warn("workspace overview: could not swap tiled windows",
          swap.sourceAddress, swap.targetAddress, e)
        return
      }
    }

    try {
      Hyprland.dispatch("hl.dsp.cursor.move({ x = " + String(swap.cursorX)
        + ", y = " + String(swap.cursorY) + " })")
    } catch (e) {
      console.warn("workspace overview: could not restore cursor after tiled swap", e)
    }
    try { Hyprland.refreshToplevels() } catch (e) {}
    if (root.draggedToplevel !== null) root.refreshAfterDrag = true
    else root.workspaceRevision += 1
  }

  function floatingWindowPosition(toplevel, workspaceId, areaX, areaY,
                                   areaWidth, areaHeight, grabRatioX, grabRatioY,
                                   allowPartial) {
    var address = root.normalizedAddress(toplevel)
    var id = root.positiveWorkspaceId(workspaceId)
    var ipc = toplevel && toplevel.lastIpcObject
    var workspace = root.workspaceById(id, root.workspaceRevision)
    var monitor = workspace && workspace.monitor
      ? workspace.monitor : Hyprland.focusedMonitor
    var screen = null
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++) {
      if (screens[i] && monitor && screens[i].name === monitor.name) {
        screen = screens[i]
        break
      }
    }
    var geometryOverride = address ? root.dragGeometryOverrides[address] : null
    var size = geometryOverride && geometryOverride.size
      ? geometryOverride.size : (ipc && ipc.size ? ipc.size : null)
    if (!address || id < 1 || !monitor || !size || size.length < 2) return null

    var position = WindowGeometry.workspacePosition(monitor, screen,
      areaWidth, areaHeight, areaX, areaY, grabRatioX, grabRatioY,
      size[0], size[1], Boolean(allowPartial))
    return position ? ({ address: address, workspaceId: id, position: position }) : null
  }

  function dispatchWindowPosition(address, position) {
    if (!address || !position) return
    if (root.dragProbeAddress === address)
      root.lastDispatchedDragPosition = [Number(position.x), Number(position.y)]
    root.logDrag("dispatch-position", {
      targetAddress: address, position: [position.x, position.y]
    }, 100)
    if (Hyprland.usingLua) {
      Hyprland.dispatch("hl.dsp.window.move({ x = " + String(position.x)
        + ", y = " + String(position.y)
        + ", relative = false, window = \"address:" + address + "\" })")
    } else {
      Hyprland.dispatch("movewindowpixel exact " + String(position.x) + " "
        + String(position.y) + ",address:" + address)
    }
  }

  function queueFloatingWindowDragMove(toplevel, workspaceId, areaX, areaY,
                                       areaWidth, areaHeight, grabRatioX, grabRatioY) {
    var state = root.dragStartState
    var nativeTiledDrag = state
      && state.address === root.normalizedAddress(toplevel)
      && state.temporarilyFloated
    var moveGrabRatioX = nativeTiledDrag ? 0.5 : grabRatioX
    var moveGrabRatioY = nativeTiledDrag ? 0.5 : grabRatioY
    if (root.draggedToplevel !== toplevel
        || (!root.wasFloatingAtDragStart(toplevel) && !nativeTiledDrag)
        || !root.dragStartState || !root.dragStartState.hasPosition)
      return
    root.logDrag("mapped-pointer", {
      workspaceId: Number(workspaceId), previewPosition: [areaX, areaY],
      grabRatio: [grabRatioX, grabRatioY],
      compositorGrabRatio: [moveGrabRatioX, moveGrabRatioY],
      areaSize: [areaWidth, areaHeight]
    }, 100)
    root.pendingFloatingDragMove = {
      toplevel: toplevel, workspaceId: workspaceId, x: areaX, y: areaY,
      width: areaWidth, height: areaHeight,
      grabRatioX: moveGrabRatioX, grabRatioY: moveGrabRatioY
    }
    // The compositor's IPC model is intentionally held stable during a drag
    // so the active DragHandler survives. Feed transient geometry to both
    // previews through the independent override map.
    if (root.draggedFromWorkspaceCanvas) {
      var position = root.floatingWindowPosition(toplevel, workspaceId,
        areaX, areaY, areaWidth, areaHeight,
        moveGrabRatioX, moveGrabRatioY, true)
      var ipc = toplevel.lastIpcObject
      if (position && ipc) {
        var previewIpc = Object.assign({}, ipc)
        previewIpc.at = [position.position.x, position.position.y]
        var current = root.dragGeometryOverrides[position.address]
        if (current && current.size) previewIpc.size = current.size
        previewIpc.floating = true
        var overrides = Object.assign({}, root.dragGeometryOverrides)
        overrides[position.address] = previewIpc
        root.dragGeometryOverrides = overrides
        root.dragGeometryRevision += 1
      }
    }
    if (!floatingDragMoveTimer.running) floatingDragMoveTimer.start()
  }

  function applyQueuedFloatingWindowDragMove() {
    var pending = root.pendingFloatingDragMove
    root.pendingFloatingDragMove = null
    if (!pending || root.draggedToplevel !== pending.toplevel) return
    var move = root.floatingWindowPosition(pending.toplevel, pending.workspaceId,
      pending.x, pending.y, pending.width, pending.height,
      pending.grabRatioX, pending.grabRatioY, true)
    if (move) root.dispatchWindowPosition(move.address, move.position)
  }

  function recordActualDragPosition(exitCode, output) {
    var address = root.dragProbeAddress
    if (!address) return
    if (exitCode !== 0) {
      root.logDrag("actual-position-probe-failed", {
        targetAddress: address, exitCode: exitCode
      }, 500)
      return
    }

    var clients = null
    try { clients = JSON.parse(String(output || "")) } catch (e) {
      root.logDrag("actual-position-probe-invalid-json", {
        targetAddress: address
      }, 500)
      return
    }
    if (!Array.isArray(clients)) return

    var client = null
    var geometryOverrides = {}
    var workspaceGeometry = []
    for (var i = 0; i < clients.length; i++) {
      var candidate = clients[i]
      var candidateAddress = root.normalizedAddress(candidate)
      var candidateWorkspaceId = candidate && candidate.workspace
        && candidate.workspace.id !== undefined
        ? Number(candidate.workspace.id) : -1
      if (candidateAddress === address) client = candidate
      if (candidateWorkspaceId !== root.dragProbeWorkspaceId
          || !candidateAddress
          || !candidate.at || candidate.at.length < 2
          || !candidate.size || candidate.size.length < 2)
        continue
      var geometry = {
        address: candidateAddress,
        at: [Number(candidate.at[0]), Number(candidate.at[1])],
        size: [Number(candidate.size[0]), Number(candidate.size[1])],
        floating: candidate.floating === true
      }
      workspaceGeometry.push(geometry)
      geometryOverrides[candidateAddress] = {
        at: geometry.at, size: geometry.size,
        floating: geometry.floating
      }
    }
    root.logDrag("workspace-geometry-snapshot", {
      clients: workspaceGeometry
    }, 250)
    root.dragGeometryOverrides = geometryOverrides
    root.dragGeometryRevision += 1
    if (!client || !client.at || client.at.length < 2) {
      root.logDrag("actual-position-not-found", {
        targetAddress: address
      }, 500)
      return
    }

    var actual = [Number(client.at[0]), Number(client.at[1])]
    var actualSize = client.size && client.size.length >= 2
      ? [Number(client.size[0]), Number(client.size[1])] : null
    var requested = root.lastDispatchedDragPosition
    var previous = root.lastObservedDragPosition
    var workspaceId = client.workspace && client.workspace.id !== undefined
      ? Number(client.workspace.id) : -1
    root.lastObservedDragPosition = actual
    root.logDrag("actual-compositor-position", {
      address: address,
      actualPosition: actual,
      actualSize: actualSize,
      startSize: root.dragStartState
        && root.dragStartState.address === address
        && root.dragStartState.hasSize
        ? [root.dragStartState.width, root.dragStartState.height] : null,
      sizeDeltaFromStart: actualSize && root.dragStartState
        && root.dragStartState.address === address
        && root.dragStartState.hasSize
        ? [actualSize[0] - root.dragStartState.width,
          actualSize[1] - root.dragStartState.height] : null,
      requestedPosition: requested,
      actualDeltaFromRequest: requested
        ? [actual[0] - requested[0], actual[1] - requested[1]] : null,
      actualDeltaSincePreviousSample: previous
        ? [actual[0] - previous[0], actual[1] - previous[1]] : null,
      floating: client.floating === true,
      actualWorkspaceId: workspaceId
    }, 80)
  }

  function refreshAfterWindowAction(toplevel) {
    try { Hyprland.refreshWorkspaces(); Hyprland.refreshToplevels() } catch (e) {}
    if (root.draggedToplevel === toplevel) {
      root.refreshAfterDrag = true
      return
    }
    root.workspaceRevision += 1
  }

  function findToplevelByAddress(address) {
    var values = []
    try { values = Hyprland.toplevels.values } catch (e) {}
    for (var i = 0; i < values.length; i++) {
      if (root.normalizedAddress(values[i]) === address) return values[i]
    }
    return null
  }

  function dragStateMatches(toplevel, state, expectedWorkspaceId, expectedPosition) {
    if (!toplevel || !state) return false
    var workspaceId = toplevel.workspace
      ? root.positiveWorkspaceId(toplevel.workspace.id) : -1
    var ipc = toplevel.lastIpcObject
    if (workspaceId !== expectedWorkspaceId
        || Boolean(ipc && ipc.floating === true) !== state.floating)
      return false
    if (!state.floating || !expectedPosition) return true
    var at = ipc && ipc.at
    return Boolean(at && at.length >= 2
      && Math.abs(Number(at[0]) - expectedPosition.x) <= 2
      && Math.abs(Number(at[1]) - expectedPosition.y) <= 2)
  }

  function restoreWindowDropState(state) {
    if (!state || !state.address) return false
    try {
      if (state.workspaceId > 0)
        root.dispatchWorkspaceMove(state.address, state.workspaceId)
      // A drag started tiled may have been floated for reflow before the drop
      // transaction failed. Explicit Lua actions make this rollback repeatable.
      if (root.dragStartState && root.dragStartState.address === state.address
          && root.dragStartState.temporarilyFloated)
        root.dispatchWindowFloat(state.address, state.floating)
      if (state.floating && state.hasPosition)
        root.dispatchWindowPosition(state.address, { x: state.x, y: state.y })
      return true
    } catch (e) {
      console.warn("workspace overview: could not restore window after drop",
        state.address, state.workspaceId, e)
      return false
    }
  }

  function verifyPendingWindowDrop() {
    var transaction = root.pendingWindowDrop
    if (!transaction) return
    try { Hyprland.refreshWorkspaces(); Hyprland.refreshToplevels() } catch (e) {}
    var current = root.findToplevelByAddress(transaction.address)
    var expectedWorkspaceId = transaction.rollingBack
      ? transaction.original.workspaceId : transaction.workspaceId
    var expectedPosition = transaction.rollingBack
      ? (transaction.original.floating && transaction.original.hasPosition
        ? ({ x: transaction.original.x, y: transaction.original.y }) : null)
      : transaction.position
    if (root.dragStateMatches(current, transaction.original,
        expectedWorkspaceId, expectedPosition)) {
      root.pendingWindowDrop = null
      root.workspaceRevision += 1
      return
    }

    transaction.attempts += 1
    if (transaction.rollingBack) {
      if (transaction.attempts < 3) {
        root.restoreWindowDropState(transaction.original)
        windowDropVerifyTimer.restart()
        return
      }
      console.warn("workspace overview: drop verification failed after rollback",
        transaction.address, expectedWorkspaceId)
      root.pendingWindowDrop = null
      root.workspaceRevision += 1
      return
    }
    if (transaction.attempts < 3) {
      windowDropVerifyTimer.restart()
      return
    }

    transaction.rollingBack = true
    transaction.attempts = 0
    root.restoreWindowDropState(transaction.original)
    windowDropVerifyTimer.restart()
  }

  function dropWindowOnWorkspace(toplevel, workspaceId, x, y,
                                 grabRatioX, grabRatioY, areaWidth, areaHeight,
                                 targetToplevel, targetRatioX, targetRatioY) {
    var state = root.draggedToplevel === toplevel ? root.dragStartState : null
    var id = root.positiveWorkspaceId(workspaceId)
    if (!state || state.workspaceId < 1 || id < 1 || root.pendingWindowDrop)
      return false
    root.logDrag("drop-workspace", {
      targetWorkspaceId: id, targetAddress: targetToplevel
        ? root.normalizedAddress(targetToplevel) : "",
      position: [x, y], targetKind: targetToplevel ? "window" : "workspace",
      targetRatio: targetToplevel
        ? [Number(targetRatioX), Number(targetRatioY)] : null
    })
    dragDetachTimer.stop()
    if (state.floating && !state.hasPosition) return false

    // Same-workspace tiled drops target a concrete tile, so retile the source
    // before exchanging layout slots.
    if (!state.floating && state.workspaceId === id) {
      var wasTemporarilyFloated = state.temporarilyFloated
      if (state.temporarilyFloated) {
        root.dispatchWindowFloat(state.address, false)
        state.temporarilyFloated = false
      }
      if (targetToplevel && !root.isFloatingWindow(targetToplevel)) {
        var dropIntent = wasTemporarilyFloated
          && isFinite(Number(targetRatioX)) && isFinite(Number(targetRatioY))
          ? ({ x: Math.max(0, Math.min(1, Number(targetRatioX))),
               y: Math.max(0, Math.min(1, Number(targetRatioY))) }) : null
        root.swapTiledWindows(toplevel, targetToplevel, dropIntent)
      }
      return true
    }

    var position = null
    if (state.floating || state.temporarilyFloated) {
      var moveGrabRatioX = state.temporarilyFloated ? 0.5 : grabRatioX
      var moveGrabRatioY = state.temporarilyFloated ? 0.5 : grabRatioY
      var move = root.floatingWindowPosition(toplevel, id, x, y,
        areaWidth, areaHeight, moveGrabRatioX, moveGrabRatioY)
      if (!move) return false
      position = move.position
    }

    var transaction = {
      address: state.address, original: state,
      workspaceId: id, position: position,
      attempts: 0, rollingBack: false
    }
    root.pendingWindowDrop = transaction
    try {
      if (state.workspaceId !== id)
        root.dispatchWorkspaceMove(state.address, id)
      if (position) root.dispatchWindowPosition(state.address, position)
      if (!state.floating && state.temporarilyFloated) {
        root.dispatchWindowFloat(state.address, false)
        state.temporarilyFloated = false
      }
      root.refreshAfterWindowAction(toplevel)
      windowDropVerifyTimer.start()
      return true
    } catch (e) {
      console.warn("workspace overview: could not dispatch window drop",
        state.address, id, e)
      transaction.rollingBack = true
      root.restoreWindowDropState(state)
      windowDropVerifyTimer.start()
      return false
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
      root.pendingWorkspaceDeleteId = id
      workspaceUnpersistProcess.running = true
    } catch (e) {
      root.pendingWorkspaceUnpersistId = -1
      root.pendingWorkspaceDeleteId = -1
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
    root.saveSettings()
    try { Hyprland.refreshWorkspaces() } catch (e) {}
    root.workspaceRevision += 1
    Qt.callLater(function() {
      root.clampSelection()
      root.ensureSelectionVisible()
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

    root.closeWorkspaceContext()

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

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(String(payloadJson || "{}")) } catch (e) {}
    if (payload.mode === "alt-tab-next") {
      root.altTabStep(false)
      return
    }
    if (payload.mode === "alt-tab-previous") {
      root.altTabStep(true)
      return
    }
    if (payload.mode === "alt-tab-commit") {
      root.altTabCommit()
      return
    }
    if (payload.mode === "alt-tab-cancel") {
      root.altTabCancel()
      return
    }
    root.closeWorkspaceContext()
    root.altTabCancel()
    root.settingsMode = payload.mode === "settings"
    if (root.settingsMode)
      root.settingsSelection = 0
    try { Hyprland.refreshWorkspaces(); Hyprland.refreshToplevels() } catch (e) {}
    root.workspaceRevision += 1
    root.selectedToplevel = null
    root.showKeybindHint = false
    root.selectedIndex = root.focusedIndex()
    root.opened = true
    Qt.callLater(function() {
      root.clampSelection()
      root.ensureSelectionVisible()
    })
  }

  function close() {
    root.closeWorkspaceContext()
    root.opened = false
    root.settingsMode = false
    root.showKeybindHint = false
    root.altTabCancel()
  }

  function syncModalInputMode() {
    var shouldBeActive = root.opened || root.altTabOpen
    if (shouldBeActive === root.modalInputModeActive) return
    if (!Hyprland.usingLua) {
      console.warn("workspace navigator: modal input requires Hyprland Lua")
      return
    }
    try {
      var submap = shouldBeActive ? "workspace_navigator" : "reset"
      Hyprland.dispatch('hl.dsp.submap("' + submap + '")')
      root.modalInputModeActive = shouldBeActive
    } catch (e) {
      console.warn("workspace navigator: could not change modal input mode", e)
    }
  }

  function toggleKeybindHint() {
    root.showKeybindHint = !root.showKeybindHint
  }

  function dismiss() {
    root.closeWorkspaceContext()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "roubilibo.workspace-navigator")
    else
      root.close()
  }

  function toggle() {
    if (root.altTabOpen) root.altTabCancel()
    else if (root.opened) root.dismiss()
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
    id: altTabRefreshTimer
    interval: 100
    repeat: false
    onTriggered: root.reconcileAltTabCandidates()
  }

  Timer {
    id: altTabOverlayShowTimer
    interval: 120
    repeat: false
    onTriggered: {
      if (root.altTabOpen) {
        root.altTabOverlayVisible = true
      }
    }
  }

  Timer {
    id: altTabPendingStartTimer
    interval: 500
    repeat: false
    onTriggered: {
      if (!root.altTabOpen) {
        root.altTabCommitPending = false
        root.altTabCommitHandled = true
      }
    }
  }

  Timer {
    id: altTabPendingCommitTimer
    interval: 40
    repeat: false
    onTriggered: {
      if (root.altTabCommitPending && root.altTabOpen) root.altTabCommit()
    }
  }

  Timer {
    id: floatingDragMoveTimer
    interval: 16
    repeat: false
    onTriggered: root.applyQueuedFloatingWindowDragMove()
  }

  Timer {
    id: dragStateProbeTimer
    interval: 100
    repeat: true
    onTriggered: {
      if (!root.draggedToplevel) {
        stop()
        return
      }
      if (!dragStateProbe.running) dragStateProbe.running = true
    }
  }

  Timer {
    id: dragDetachTimer
    // DragHandler becomes active after the pickup threshold has already been
    // crossed. Let the event finish, then mirror Hyprland's immediate float.
    interval: 0
    repeat: false
    onTriggered: root.detachDraggedTiledWindow()
  }

  Timer {
    id: windowDropVerifyTimer
    interval: 120
    repeat: false
    onTriggered: root.verifyPendingWindowDrop()
  }

  Timer {
    id: tiledSwapStateProbeTimer
    interval: 25
    repeat: false
    onTriggered: root.probeTiledWindowSwapState()
  }

  Timer {
    id: dragRefreshTimer
    interval: 180
    repeat: false
    onTriggered: {
      try { Hyprland.refreshToplevels() } catch (e) {}
      root.workspaceRevision += 1
      Qt.callLater(function() {
        root.dragGeometryOverrides = ({})
        root.dragGeometryRevision += 1
        root.dragWorkspaceToplevelSnapshots = null
      })
    }
  }

  Process {
    id: dragStateProbe
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      id: dragStateProbeOutput
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.recordActualDragPosition(exitCode, dragStateProbeOutput.text)
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
      root.finishTiledWindowSwap(exitCode, cursorProbeOutput.text)
    }
  }

  Process {
    id: tiledSwapStateProbe
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      id: tiledSwapStateProbeOutput
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.finishTiledWindowSwapState(exitCode, tiledSwapStateProbeOutput.text)
    }
  }

  Process {
    id: windowOpacityModeProbe
    command: ["omarchy-hyprland-window-transparency"]
    stdout: StdioCollector { id: windowOpacityModeOutput; waitForEnd: true }
    onExited: function(exitCode) {
      var mode = String(windowOpacityModeOutput.text || "").trim()
      if (exitCode !== 0 || ["opaque", "transparent", "glassy"].indexOf(mode) < 0) {
        console.warn("workspace overview: could not read Omarchy window opacity mode",
          exitCode)
        if (root.windowOpacityProbePending) root.refreshWindowOpacityMode()
        return
      }
      root.windowOpacityModeKnown = true
      root.glassyWindowMode = mode === "glassy"
      root.applyWindowOpacityMode()
      if (root.windowOpacityProbePending) root.refreshWindowOpacityMode()
    }
  }

  Process {
    id: glassyRuleApplyProcess
    command: ["hyprctl", "eval", root.glassyRuleEvalCommand]
    onExited: function(exitCode) {
      if (exitCode !== 0)
        console.warn("workspace overview: could not apply Omarchy glassy layer rules",
          exitCode)
      if (root.glassyRuleApplyPending) root.applyWindowOpacityMode()
    }
  }

  Process {
    id: settingsReadProcess
    command: ["python3", root.safeConfigFileHelper, "read",
      root.settingsPath, "16384"]
    stdout: StdioCollector { id: settingsReadOutput; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.loadSettings(settingsReadOutput.text)
      else if (exitCode !== 3)
        console.warn("workspace overview: could not read settings safely", exitCode)
    }
  }

  Process {
    id: settingsWriteProcess
    command: ["python3", root.safeConfigFileHelper, "write",
      root.settingsPath, "16384", root.settingsWriteText]
    onExited: function(exitCode) {
      if (exitCode !== 0)
        console.warn("workspace overview: could not save settings safely", exitCode)
      if (root.settingsWriteDirty) root.startSettingsWrite()
    }
  }

  Process {
    id: launcherMenuReadProcess
    command: ["python3", root.safeConfigFileHelper, "read",
      root.launcherMenuPath, "65536"]
    stdout: StdioCollector { id: launcherMenuReadOutput; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.ensureLauncherMenuEntry(launcherMenuReadOutput.text)
      else if (exitCode === 3)
        root.writeLauncherMenu("{\n" + root.launcherMenuEntryText + "\n}\n")
      else
        console.warn("workspace overview: could not read omarchy menu extension safely", exitCode)
    }
  }

  Process {
    id: launcherMenuWriteProcess
    command: ["python3", root.safeConfigFileHelper, "write",
      root.launcherMenuPath, "65536", root.launcherMenuWriteText]
    onExited: function(exitCode) {
      if (exitCode !== 0)
        console.warn("workspace overview: could not update omarchy menu extension safely", exitCode)
      if (root.launcherMenuWriteDirty) root.startLauncherMenuWrite()
    }
  }

  Process {
    id: bindingSyncProcess
    command: ["python3", root.safeConfigFileHelper, "sync-loader",
      root.hyprBindingsPath, "65536"]
    stdout: StdioCollector { id: bindingSyncOutput; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        console.warn("workspace overview: could not add Hyprland bindings safely", exitCode)
        return
      }
      if (String(bindingSyncOutput.text || "").trim() === "changed")
        bindingReloadProcess.running = true
    }
  }

  Process {
    id: bindingReloadProcess
    command: ["hyprctl", "reload"]
    onExited: function(exitCode) {
      if (exitCode !== 0)
        console.warn("workspace overview: Hyprland config reload failed", exitCode)
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
    id: workspacePersistProcess
    command: ["hyprctl", "eval",
      "hl.workspace_rule({ workspace = \"" + String(root.pendingWorkspacePersistId)
        + "\", persistent = true })"]
    onExited: function(exitCode) {
      var workspaceId = root.pendingWorkspacePersistId
      root.pendingWorkspacePersistId = -1
      if (exitCode !== 0)
        console.warn("workspace overview: could not make workspace persistent",
          workspaceId, "hyprctl exited with", exitCode)
      else {
        var persistentIds = root.menuPersistentWorkspaceIds.slice()
        if (persistentIds.indexOf(workspaceId) < 0) persistentIds.push(workspaceId)
        root.menuPersistentWorkspaceIds = persistentIds
        root.workspaceRevision += 1
      }
    }
  }

  Process {
    id: workspaceUnpersistProcess
    command: ["hyprctl", "eval",
      "hl.workspace_rule({ workspace = \"" + String(root.pendingWorkspaceUnpersistId)
        + "\", persistent = false })"]
    onExited: function(exitCode) {
      var workspaceId = root.pendingWorkspaceUnpersistId
      var deleteWorkspaceId = root.pendingWorkspaceDeleteId
      root.pendingWorkspaceUnpersistId = -1
      root.pendingWorkspaceDeleteId = -1
      if (exitCode !== 0)
        console.warn("workspace overview: could not clear workspace persistence",
          workspaceId, "hyprctl exited with", exitCode)
      else {
        var persistentIds = root.menuPersistentWorkspaceIds.slice()
        var index = persistentIds.indexOf(workspaceId)
        if (index >= 0) persistentIds.splice(index, 1)
        root.menuPersistentWorkspaceIds = persistentIds
      }
      if (deleteWorkspaceId > 0) root.finishWorkspaceDelete(deleteWorkspaceId)
      else if (exitCode === 0) root.workspaceRevision += 1
    }
  }

  Connections {
    target: Hyprland
    function onActiveToplevelChanged() {
      root.rememberAltTabFocus(Hyprland.activeToplevel)
    }
    function onRawEvent(event) {
      var name = event && event.name ? String(event.name) : ""
      if (name === "configreloaded") root.refreshWindowOpacityMode()
      if (name === "closewindow") root.forgetAltTabWindow(event)
      if (!root.opened && !root.altTabOpen) return

      // Keep the delegate tree stable until the overview drag releases its
      // pointer. The final refresh is scheduled by endWindowDrag().
      if (root.opened && root.draggedToplevel !== null && !root.altTabOpen) {
        root.refreshAfterDrag = true
        return
      }

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
      if (root.altTabOpen && (workspaceChanged || toplevelChanged))
        altTabRefreshTimer.restart()
      if (root.opened) refreshTimer.restart()
    }
  }

  IpcHandler {
    target: "roubilibo.workspace-navigator"

    function open(): string { root.open("{}"); return "ok" }
    function close(): string { root.close(); return "ok" }
    function toggle(): string { root.toggle(); return "ok" }
    function settings(): string { root.openSettings(); return "ok" }
    function setAltTabScope(scope: string): string {
      return root.setAltTabScope(scope)
    }
    function altTabNext(): string { root.altTabStep(false); return "ok" }
    function altTabPrevious(): string { root.altTabStep(true); return "ok" }
    function altTabCommit(): string { root.altTabCommit(); return "ok" }
    function altTabCancel(): string { root.altTabCancel(); return "ok" }
    function focus(id: string): string {
      var workspaceId = root.positiveWorkspaceId(id)
      if (workspaceId < 1) return "invalid workspace"
      root.focusWorkspace(workspaceId)
      return "ok"
    }
    function state(): string {
      return root.altTabOpen ? "alt-tab" : (root.opened ? "open" : "closed")
    }
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
        visible: (root.opened || root.altTabOpen) && (Quickshell.screens.length === 1
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
          visible: root.opened && !root.settingsMode && !root.altTabOpen
          // Use Omarchy's menu scrim so the overview follows the active theme
          // and keeps a consistent amount of desktop context visible.
          color: Color.menu.scrim

          MouseArea {
            anchors.fill: parent
            onClicked: {
              if (root.workspaceContextOpen) root.closeWorkspaceContext()
              else root.dismiss()
            }
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
              if (root.workspaceContextOpen) root.closeWorkspaceContext()
              else if (root.altTabOpen) root.altTabCancel()
              else root.dismiss()
              event.accepted = true
            } else if (event.key === Qt.Key_Tab
                       && (event.modifiers & Qt.MetaModifier)) {
              if (root.altTabOpen) root.altTabCancel()
              if (root.opened || !root.altTabOpen) root.dismiss()
              event.accepted = true
            } else if (root.altTabOpen
                       && !(event.modifiers & Qt.AltModifier)) {
              // The Alt release can arrive before this layer surface receives
              // keyboard focus. A later Tab repeat then commits the session.
              root.altTabCommit()
              event.accepted = true
            } else if (root.opened && !root.altTabOpen
                       && event.key === Qt.Key_Tab
                       && (event.modifiers & Qt.AltModifier)) {
              root.altTabStep(Boolean(event.modifiers & Qt.ShiftModifier))
              event.accepted = true
            } else if (root.altTabOpen) {
              if (event.key === Qt.Key_Left || event.key === Qt.Key_H
                  || (event.key === Qt.Key_Tab
                    && (event.modifiers & Qt.ShiftModifier))) {
                root.altTabStep(true)
                event.accepted = true
              } else if (event.key === Qt.Key_Right || event.key === Qt.Key_L
                         || event.key === Qt.Key_Tab) {
                root.altTabStep(false)
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                         || event.key === Qt.Key_Space) {
                root.altTabCommit()
                event.accepted = true
              }
            } else if (root.workspaceContextOpen && !root.contextRenameMode) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.focusWorkspace(root.contextWorkspaceId)
                event.accepted = true
              } else if (event.key === Qt.Key_R) {
                root.beginWorkspaceRename()
                event.accepted = true
              } else if (event.key === Qt.Key_M) {
                root.moveSelectedWindowToContext()
                event.accepted = true
              }
            } else if (root.settingsMode) {
              if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
                root.selectSettings(-1)
                event.accepted = true
              } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
                root.selectSettings(1)
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                         || event.key === Qt.Key_Space) {
                root.activateSettingsSelection()
                event.accepted = true
              }
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

          Keys.onReleased: function(event) {
            if (root.altTabOpen
                && (event.key === Qt.Key_Alt || event.key === Qt.Key_AltGr)) {
              root.altTabCommit()
              event.accepted = true
            }
          }

          ColumnLayout {
            id: overviewColumn
            visible: root.opened && !root.settingsMode && !root.altTabOpen
            anchors.centerIn: parent
            width: parent.width - Style.space(48)
            height: parent.height - Style.space(48)
            spacing: Style.space(12)

            Text {
              Layout.fillWidth: true
              text: "Workspace overview"
              color: Color.menu.text
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              Layout.fillWidth: true
              text: "Select a workspace to preview it  •  Click a window to open it"
              color: Util.alpha(Color.menu.text, 0.65)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }

            Rectangle {
              visible: root.showKeybindHint
              Layout.fillWidth: true
              Layout.minimumHeight: 0
              Layout.preferredHeight: visible ? Style.space(82) : 0
              Layout.maximumHeight: visible ? Style.space(82) : 0
              radius: Style.cornerRadius
              color: Util.alpha(Color.menu.background, 0.82)
              border.width: 1
              border.color: Util.alpha(Color.menu.border, 0.42)

              Text {
                anchors.fill: parent
                anchors.leftMargin: Style.space(14)
                anchors.rightMargin: Style.space(14)
                text: "Overview: ←/→ or H/L navigate workspaces  •  ↑/↓ or K/J select workspaces  •  Tab/Shift+Tab select  •  Enter/Space open workspace  •  Esc close  •  ?: hints\nSUPER+TAB: toggle overview  •  ALT+TAB: next window  •  ALT+SHIFT+TAB: previous  •  release ALT: focus selected"
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
              readonly property real thumbnailWidth: root.workspaceThumbnailWidth
              readonly property real thumbnailHeight: thumbnailWidth
                / root.cardAspectRatioFor(panelScreen)
              readonly property real cardsContentWidth: Math.max(0,
                root.workspaceEntries(root.workspaceRevision).length
                  * (thumbnailWidth + root.cardGap) - root.cardGap)
              readonly property real cardsOffsetX: Math.max(0,
                (width - cardsContentWidth) / 2)
              property real horizontalWheelAccumulator: 0
              Component.onCompleted: root.workspaceScroller = workspaceFlickable
              Layout.fillWidth: true
              Layout.preferredHeight: thumbnailHeight
              clip: true
              contentWidth: Math.max(width, cardsContentWidth)
              contentHeight: height
              interactive: contentWidth > width
              flickableDirection: Flickable.HorizontalFlick
              boundsBehavior: Flickable.StopAtBounds
              maximumFlickVelocity: 8000
              flickDeceleration: 5000
              onMovementEnded: {
                var step = thumbnailWidth + root.cardGap
                if (step <= 0) return
                var entries = root.workspaceEntries(root.workspaceRevision)
                if (entries.length <= 0) return
                root.selectedIndex = Math.max(0, Math.min(entries.length - 1,
                  Math.round(contentX / step)))
                root.ensureSelectionVisible()
              }

              function handleHorizontalWheel(event) {
                var angle = event.angleDelta
                var pixel = event.pixelDelta
                var angleX = angle ? Number(angle.x) : 0
                var angleY = angle ? Number(angle.y) : 0
                var pixelX = pixel ? Number(pixel.x) : 0
                var pixelY = pixel ? Number(pixel.y) : 0
                var horizontalX = pixelX !== 0 ? pixelX : angleX
                var horizontalY = pixelY !== 0 ? pixelY : angleY
                if (!isFinite(horizontalX) || !isFinite(horizontalY)
                    || horizontalX === 0
                    || Math.abs(horizontalX) <= Math.abs(horizontalY))
                  return

                horizontalWheelAccumulator += pixelX !== 0 ? pixelX : angleX
                var threshold = pixelX !== 0 ? 48 : 120
                if (Math.abs(horizontalWheelAccumulator) < threshold)
                  return
                var direction = horizontalWheelAccumulator > 0 ? -1 : 1
                horizontalWheelAccumulator = 0
                root.select(direction)
                event.accepted = true
              }

              MouseArea {
                anchors.fill: parent
                z: 100
                acceptedButtons: Qt.NoButton
                onWheel: function(event) {
                  workspaceFlickable.handleHorizontalWheel(event)
                }
              }

              Repeater {
                model: root.workspaceEntries(root.workspaceRevision)

                delegate: WorkspaceCard {
                  required property var modelData
                  required property int index
                  readonly property bool addCard: Boolean(modelData.addWorkspace)
                  readonly property int cardWorkspaceId: Number(modelData.id)
                  x: workspaceFlickable.cardsOffsetX
                    + index * (workspaceFlickable.thumbnailWidth + root.cardGap)
                  y: 0
                  width: workspaceFlickable.thumbnailWidth
                  height: workspaceFlickable.height
                  workspaceId: addCard ? 0 : cardWorkspaceId
                  addWorkspace: addCard
                  deletable: !addCard && cardWorkspaceId > root.minimumWorkspaceCount
                  activateOnClick: false
                  selectOnHover: true
                  workspace: addCard ? null
                    : root.workspaceById(cardWorkspaceId, root.workspaceRevision)
                  workspaceName: addCard ? "" : root.workspaceName(
                    root.workspaceById(cardWorkspaceId, root.workspaceRevision),
                    cardWorkspaceId)
                  previewScreen: panelScreen
                  contextTarget: keyCatcher
                  focused: !addCard && Hyprland.focusedWorkspace !== null
                    && Hyprland.focusedWorkspace.id === cardWorkspaceId
                  keyboardSelected: root.selectedIndex === index
                  draggedToplevel: root.draggedToplevel
                  freezeDraggedPreview: root.dragPreviewFrozen
                  draggedSourceWorkspaceIdOverride: root.dragStartState
                    ? root.dragStartState.workspaceId : -1
                  toplevelsOverride: root.workspaceToplevelSnapshot(cardWorkspaceId)
                  geometryOverrides: root.dragGeometryOverrides
                  geometryRevision: root.dragGeometryRevision
                  selectedToplevel: root.selectedToplevel
                  dragOverlay: dragPreviewOverlay
                  draggedFromWorkspaceCanvas: root.draggedFromWorkspaceCanvas
                  dragShrinkProgress: root.dragShrinkProgress
                  dragTargetWidth: root.workspaceThumbnailWidth
                  dragTargetHeight: workspaceFlickable.thumbnailHeight
                  livePreviews: root.opened && panelWindow.visible
                  liveCaptureAll: true
                  toplevelRevision: root.workspaceRevision
                  onWorkspaceHovered: root.selectWorkspacePreview(cardWorkspaceId)
                  onWorkspaceActivated: {
                    if (addCard) root.addWorkspace()
                    else root.selectedIndex = index
                  }
                  onWorkspaceContextRequested: function(x, y) {
                    root.openWorkspaceContext(cardWorkspaceId, x, y)
                  }
                  onAddWorkspaceRequested: root.addWorkspace()
                  onWorkspaceDeleteRequested: root.deleteWorkspace(cardWorkspaceId)
                  onWindowDragStarted: function(toplevel) {
                    root.selectWindow(toplevel)
                    root.beginWindowDrag(toplevel, false)
                  }
                  onWindowDragMoved: function(toplevel, x, y,
                                              grabRatioX, grabRatioY) {
                    root.queueFloatingWindowDragMove(toplevel,
                      cardWorkspaceId, x, y, width, height,
                      grabRatioX, grabRatioY)
                  }
                  onWindowDragFinished: function(toplevel) { root.endWindowDrag(toplevel) }
                  onDragDiagnostic: function(eventName, details) {
                    var motion = eventName.indexOf("position") >= 0
                      || eventName.indexOf("move") >= 0
                      || eventName === "preview-coordinate-map"
                    root.logDrag(eventName, details, motion ? 100 : 0)
                  }
                  onWindowDragEnteredWorkspace: function(workspaceId) {
                    if (root.draggedFromWorkspaceCanvas) {
                      root.dragShrinkProgress = 1
                    }
                  }
                  onWindowSelected: function(toplevel) { root.selectWindow(toplevel) }
                  onWindowActivated: function(toplevel) { root.focusToplevel(toplevel) }
                  onWindowDropped: function(toplevel, x, y, grabRatioX, grabRatioY) {
                    root.dropWindowOnWorkspace(toplevel, cardWorkspaceId,
                      x, y, grabRatioX, grabRatioY, width, height)
                  }
                  onWindowDroppedOn: function(sourceToplevel, targetToplevel,
                                              x, y, grabRatioX, grabRatioY,
                                              targetRatioX, targetRatioY) {
                    root.dropWindowOnWorkspace(sourceToplevel,
                      cardWorkspaceId, x, y, grabRatioX, grabRatioY,
                      width, height, targetToplevel,
                      targetRatioX, targetRatioY)
                  }
                }
              }
            }

            Item {
              id: selectedWorkspaceArea
              Layout.fillWidth: true
              Layout.fillHeight: true
              readonly property var entries: root.workspaceEntries(root.workspaceRevision)
              readonly property var selectedEntry: entries.length > 0
                ? entries[Math.max(0, Math.min(root.selectedIndex, entries.length - 1))]
                : ({ addWorkspace: true, id: 0 })
              readonly property bool addCard: Boolean(selectedEntry.addWorkspace)
              readonly property int cardWorkspaceId: Number(selectedEntry.id)

              WorkspaceCard {
                anchors.fill: parent
                showBorder: false
                showBackground: false
                showSelectionFill: false
                workspaceId: selectedWorkspaceArea.addCard ? 0
                  : selectedWorkspaceArea.cardWorkspaceId
                addWorkspace: selectedWorkspaceArea.addCard
                deletable: !selectedWorkspaceArea.addCard
                  && selectedWorkspaceArea.cardWorkspaceId > root.minimumWorkspaceCount
                workspace: selectedWorkspaceArea.addCard ? null
                  : root.workspaceById(selectedWorkspaceArea.cardWorkspaceId,
                    root.workspaceRevision)
                workspaceName: selectedWorkspaceArea.addCard ? ""
                  : root.workspaceName(
                    root.workspaceById(selectedWorkspaceArea.cardWorkspaceId,
                      root.workspaceRevision), selectedWorkspaceArea.cardWorkspaceId)
                previewScreen: panelScreen
                contextTarget: keyCatcher
                focused: !selectedWorkspaceArea.addCard
                  && Hyprland.focusedWorkspace !== null
                  && Hyprland.focusedWorkspace.id === selectedWorkspaceArea.cardWorkspaceId
                keyboardSelected: true
                draggedToplevel: root.draggedToplevel
                freezeDraggedPreview: root.dragPreviewFrozen
                draggedSourceWorkspaceIdOverride: root.dragStartState
                  ? root.dragStartState.workspaceId : -1
                toplevelsOverride: root.workspaceToplevelSnapshot(
                  selectedWorkspaceArea.cardWorkspaceId)
                geometryOverrides: root.dragGeometryOverrides
                geometryRevision: root.dragGeometryRevision
                selectedToplevel: root.selectedToplevel
                dragOverlay: dragPreviewOverlay
                draggedFromWorkspaceCanvas: root.draggedFromWorkspaceCanvas
                dragShrinkProgress: root.dragShrinkProgress
                dragTargetWidth: root.workspaceThumbnailWidth
                dragTargetHeight: workspaceFlickable.thumbnailHeight
                livePreviews: root.opened && panelWindow.visible
                toplevelRevision: root.workspaceRevision
                onWorkspaceHovered: {}
                onWorkspaceActivated: {
                  if (selectedWorkspaceArea.addCard) root.addWorkspace()
                  else root.focusWorkspace(selectedWorkspaceArea.cardWorkspaceId)
                }
                onWorkspaceContextRequested: function(x, y) {
                  root.openWorkspaceContext(selectedWorkspaceArea.cardWorkspaceId, x, y)
                }
                onAddWorkspaceRequested: root.addWorkspace()
                onWorkspaceDeleteRequested: root.deleteWorkspace(
                  selectedWorkspaceArea.cardWorkspaceId)
                onWindowDragStarted: function(toplevel) {
                  root.selectWindow(toplevel)
                  root.beginWindowDrag(toplevel, true)
                }
                onWindowDragMoved: function(toplevel, x, y,
                                            grabRatioX, grabRatioY,
                                            pointerX, pointerY) {
                  root.queueFloatingWindowDragMove(toplevel,
                    selectedWorkspaceArea.cardWorkspaceId, x, y,
                    width, height, grabRatioX, grabRatioY)
                  root.updateDragShrinkProgress(pointerX, pointerY)
                }
                onWindowDragFinished: function(toplevel) { root.endWindowDrag(toplevel) }
                onDragDiagnostic: function(eventName, details) {
                  var motion = eventName.indexOf("position") >= 0
                    || eventName.indexOf("move") >= 0
                    || eventName === "preview-coordinate-map"
                  root.logDrag(eventName, details, motion ? 100 : 0)
                }
                onWindowSelected: function(toplevel) { root.selectWindow(toplevel) }
                onWindowActivated: function(toplevel) { root.focusToplevel(toplevel) }
                onWindowDropped: function(toplevel, x, y, grabRatioX, grabRatioY) {
                  root.dropWindowOnWorkspace(toplevel,
                    selectedWorkspaceArea.cardWorkspaceId,
                    x, y, grabRatioX, grabRatioY, width, height)
                }
                onWindowDroppedOn: function(sourceToplevel, targetToplevel,
                                            x, y, grabRatioX, grabRatioY,
                                            targetRatioX, targetRatioY) {
                  root.dropWindowOnWorkspace(sourceToplevel,
                    selectedWorkspaceArea.cardWorkspaceId,
                    x, y, grabRatioX, grabRatioY,
                    width, height, targetToplevel,
                    targetRatioX, targetRatioY)
                }
              }
            }

            Text {
              Layout.fillWidth: true
              text: "Click a window to open it  •  Drag a window to another workspace  •  Right-click for actions  •  ?: shortcuts"
              color: Util.alpha(Color.menu.text, 0.58)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }
          }

          SettingsDialog {
            opened: root.settingsMode
            options: root.settingsOptions
            selectedIndex: root.settingsSelection
            altTabScope: root.altTabScope
            onToggleRequested: function(index) { root.toggleSettingsOption(index) }
            onDismissRequested: root.dismiss()
          }

          Rectangle {
            id: workspaceContextMenu
            visible: root.workspaceContextOpen
            z: 100
            width: Style.space(320)
            height: contextMenuColumn.implicitHeight + Style.space(24)
            x: Math.max(Style.space(24), Math.min(root.contextMenuX,
              parent.width - width - Style.space(24)))
            y: Math.max(Style.space(24), Math.min(root.contextMenuY,
              parent.height - height - Style.space(24)))
            radius: Style.cornerRadius
            color: Color.menu.background
            border.width: 1
            border.color: Util.alpha(Color.menu.border, 0.58)

            // Keep clicks inside the menu from reaching the overview scrim.
            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.AllButtons
              onClicked: mouse.accepted = true
            }

            ColumnLayout {
              id: contextMenuColumn
              anchors.fill: parent
              anchors.margins: Style.space(12)
              spacing: Style.space(6)

              Text {
                Layout.fillWidth: true
                text: {
                  var workspace = root.contextWorkspace()
                  var name = root.workspaceName(workspace, root.contextWorkspaceId)
                  return name === "" ? "WS " + String(root.contextWorkspaceId)
                    : name
                }
                color: Color.menu.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                Layout.fillWidth: true
                text: "Workspace actions"
                color: Util.alpha(Color.menu.text, 0.54)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.contextRenameMode ? Style.space(38) : 0
                visible: root.contextRenameMode
                radius: Style.cornerRadius
                color: Util.alpha(Color.menu.text, 0.07)
                border.width: 1
                border.color: Color.accent

                TextInput {
                  id: workspaceRenameInput
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  text: root.contextRenameText
                  onTextEdited: root.contextRenameText = text
                  color: Color.menu.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  verticalAlignment: TextInput.AlignVCenter
                  selectByMouse: true
                  clip: true
                  onVisibleChanged: {
                    if (visible) Qt.callLater(function() {
                      workspaceRenameInput.forceActiveFocus()
                      workspaceRenameInput.selectAll()
                    })
                  }
                  Keys.onReturnPressed: root.commitWorkspaceRename()
                  Keys.onEscapePressed: root.cancelWorkspaceRename()
                }
              }

              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.contextRenameMode ? 0 : Style.space(38)
                visible: !root.contextRenameMode
                radius: Style.cornerRadius
                color: focusWorkspaceMouse.containsMouse
                  ? Util.alpha(Color.accent, 0.20) : "transparent"

                Text {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  text: "Focus workspace"
                  color: Color.menu.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  verticalAlignment: Text.AlignVCenter
                }

                Text {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Enter"
                  color: Util.alpha(Color.menu.text, 0.48)
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  id: focusWorkspaceMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: root.focusWorkspace(root.contextWorkspaceId)
                }
              }

              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.contextRenameMode ? 0 : Style.space(38)
                visible: !root.contextRenameMode
                radius: Style.cornerRadius
                color: renameWorkspaceMouse.containsMouse
                  ? Util.alpha(Color.accent, 0.20) : "transparent"

                Text {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  text: "Rename workspace"
                  color: Color.menu.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  verticalAlignment: Text.AlignVCenter
                }

                Text {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "R"
                  color: Util.alpha(Color.menu.text, 0.48)
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  id: renameWorkspaceMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: root.beginWorkspaceRename()
                }
              }

              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.contextRenameMode ? 0 : Style.space(38)
                visible: !root.contextRenameMode
                radius: Style.cornerRadius
                color: moveWindowMouse.containsMouse && root.contextCanMoveSelectedWindow()
                  ? Util.alpha(Color.accent, 0.20) : "transparent"
                opacity: root.contextCanMoveSelectedWindow() ? 1 : 0.45

                Text {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  text: "Move selected window here"
                  color: Color.menu.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  verticalAlignment: Text.AlignVCenter
                }

                Text {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "M"
                  color: Util.alpha(Color.menu.text, 0.48)
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  id: moveWindowMouse
                  anchors.fill: parent
                  enabled: root.contextCanMoveSelectedWindow()
                  hoverEnabled: true
                  onClicked: root.moveSelectedWindowToContext()
                }
              }

              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.contextRenameMode ? 0 : Style.space(38)
                visible: !root.contextRenameMode
                radius: Style.cornerRadius
                color: persistentWorkspaceMouse.containsMouse
                  ? Util.alpha(Color.accent, 0.20) : "transparent"

                Text {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  text: root.isMenuPersistentWorkspace(root.contextWorkspaceId)
                    ? "Remove persistence" : "Make persistent"
                  color: Color.menu.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  verticalAlignment: Text.AlignVCenter
                }

                MouseArea {
                  id: persistentWorkspaceMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: root.toggleWorkspacePersistence()
                }
              }

              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.contextRenameMode ? 0 : Style.space(38)
                visible: !root.contextRenameMode
                radius: Style.cornerRadius
                color: deleteWorkspaceMouse.containsMouse && root.contextWorkspaceId > root.minimumWorkspaceCount
                  ? Util.alpha(Color.urgent, 0.20) : "transparent"
                opacity: root.contextWorkspaceId > root.minimumWorkspaceCount
                  && root.workspaceWindowCount(root.contextWorkspace(), root.workspaceRevision) === 0
                  ? 1 : 0.42

                Text {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  text: "Delete empty workspace"
                  color: root.contextWorkspaceId > root.minimumWorkspaceCount
                    ? Color.menu.text : Util.alpha(Color.menu.text, 0.58)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  verticalAlignment: Text.AlignVCenter
                }

                MouseArea {
                  id: deleteWorkspaceMouse
                  anchors.fill: parent
                  enabled: root.contextWorkspaceId > root.minimumWorkspaceCount
                    && root.workspaceWindowCount(root.contextWorkspace(), root.workspaceRevision) === 0
                  hoverEnabled: true
                  onClicked: root.deleteWorkspace(root.contextWorkspaceId)
                }
              }

              RowLayout {
                visible: root.contextRenameMode
                Layout.fillWidth: true
                Layout.preferredHeight: Style.space(38)
                spacing: Style.space(6)

                Rectangle {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  radius: Style.cornerRadius
                  color: cancelRenameMouse.containsMouse
                    ? Util.alpha(Color.menu.text, 0.10) : "transparent"

                  Text {
                    anchors.fill: parent
                    text: "Cancel"
                    color: Color.menu.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                  }

                  MouseArea {
                    id: cancelRenameMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.cancelWorkspaceRename()
                  }
                }

                Rectangle {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  radius: Style.cornerRadius
                  color: saveRenameMouse.containsMouse
                    ? Util.alpha(Color.accent, 0.34) : Util.alpha(Color.accent, 0.22)

                  Text {
                    anchors.fill: parent
                    text: "Save"
                    color: Color.menu.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                  }

                  MouseArea {
                    id: saveRenameMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.commitWorkspaceRename()
                  }
                }
              }
            }
          }
        }

        Item {
          id: dragPreviewOverlay
          anchors.fill: parent
          z: 1000000
          Component.onCompleted: root.dragOverlayItem = dragPreviewOverlay
          Component.onDestruction: {
            if (root.dragOverlayItem === dragPreviewOverlay)
              root.dragOverlayItem = null
          }
        }
      }
    }
  }

  // Keep the Alt+Tab surface bounded to the popup. The full-screen
  // PanelWindow above owns exclusive keyboard focus while this one only
  // receives pointer input.
  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        required property var modelData
        id: altTabPanelWindow
        readonly property var panelScreen: modelData

        screen: modelData
        visible: root.altTabOverlayVisible && (Quickshell.screens.length === 1
          || root.isFocusedScreen(modelData))
        width: altTabOverlay.width
        height: altTabOverlay.height
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        WlrLayershell.namespace: "roubilibo-workspace-navigator-alt-tab"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors { top: true; left: true }
        margins {
          left: Math.max(0, Math.round((panelScreen.width - width) / 2))
          top: Math.max(0, Math.round((panelScreen.height - height) / 2))
        }

        AltTabOverlay {
          id: altTabOverlay
          opened: root.altTabOverlayVisible
          availableWidth: panelScreen.width
          availableHeight: panelScreen.height
          glassyMode: root.glassyWindowMode
          scope: root.altTabScope
          candidates: root.altTabCandidates
          selectedIndex: root.altTabIndex
          workspaceLabelFor: root.altTabWorkspaceLabel
          onSelectionRequested: function(index) { root.altTabIndex = index }
          onCommitRequested: root.altTabCommit()
        }
      }
    }
  }
}
