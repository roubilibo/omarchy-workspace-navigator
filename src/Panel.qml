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
  property real contextMenuX: 0
  property real contextMenuY: 0
  property bool workspaceContextOpen: false
  property bool contextRenameMode: false
  property string contextRenameText: ""
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
  property int pendingWorkspacePersistId: -1
  property int pendingWorkspaceUnpersistId: -1
  property int pendingWorkspaceDeleteId: -1
  property var menuPersistentWorkspaceIds: []
  property var createdWorkspaceIds: []
  property int currentPage: 0
  property var workspaceScroller: null
  property bool showKeybindHint: false
  property bool settingsMode: false
  property int settingsSelection: 0
  property bool altTabOpen: false
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
    if (root.altTabOpen) Qt.callLater(root.ensureAltTabSelectionVisible)
  }
  onOpenedChanged: {
    root.syncModalInputMode()
    if (!root.opened) root.closeWorkspaceContext()
  }
  onAltTabIndexChanged: {
    if (root.altTabOpen) Qt.callLater(root.ensureAltTabSelectionVisible)
  }

  readonly property int minimumWorkspaceCount: 8
  // Hyprland workspace IDs are signed integers. Keeping the accepted range
  // explicit also means every value interpolated into a dispatcher is a
  // canonical integer, never caller-controlled command text.
  readonly property int maximumWorkspaceId: 2147483647
  readonly property int overviewColumns: 3
  readonly property int cardsPerPage: 9
  readonly property int cardGap: Style.space(12)
  // Keep the sampling radius modest and spend more passes on a smoother
  // result; a large radius with too few passes can expose blocky artifacts.
  readonly property int micaBlurSize: 6
  readonly property int micaBlurPasses: 4
  // Swipe behavior defaults to one page at a time. Kinetic is an optional
  // enhancement exposed by the single "Kinetic Swipe" toggle.
  property string flickBehavior: "single-page"
  property bool blurEnabled: false
  property bool blurBaseEnabled: true
  property int blurBaseSize: 8
  property int blurBasePasses: 1
  property bool blurBaseStateKnown: false
  property bool blurApplyPending: false
  readonly property bool blurRequested: root.blurEnabled && root.opened
    && !root.settingsMode && !root.altTabOpen
  readonly property var settingsOptions: [
    {
      kind: "flick",
      label: "Kinetic Swipe",
      description: "Enable momentum to move across multiple workspace pages. Off uses Single Page."
    },
    {
      kind: "altTab",
      label: "Alt+Tab: All Workspaces",
      description: "Include windows from every workspace. Off uses the current workspace."
    },
    {
      kind: "blur",
      label: "Overview Background Blur",
      description: "Use a softly blurred, theme-tinted Mica-like backdrop."
    }
  ]
  readonly property string flickSettingsPath:
    Quickshell.env("HOME") + "/.local/state/omarchy/settings/workspace-navigator.json"
  readonly property string blurEvalCommand:
    'workspaceNavigatorBlurRule = workspaceNavigatorBlurRule or '
    + 'hl.layer_rule({ name = "workspace-navigator-blur", '
    + 'match = { namespace = "^roubilibo-workspace-navigator$" }, blur = true }); '
    + 'workspaceNavigatorBlurRule:set_enabled('
    + (root.blurRequested ? "true" : "false") + '); '
    + 'hl.config({ decoration = { blur = { enabled = '
    + (root.blurRequested || root.blurBaseEnabled ? "true" : "false")
    + ', size = ' + String(root.blurRequested
      ? root.micaBlurSize : root.blurBaseSize)
    + ', passes = ' + String(root.blurRequested
      ? root.micaBlurPasses : root.blurBasePasses)
    + ' } } })'
  readonly property string launcherMenuDirectory:
    Quickshell.env("HOME") + "/.config/omarchy/extensions"
  readonly property string launcherMenuPath:
    root.launcherMenuDirectory + "/omarchy-menu.jsonc"
  readonly property string launcherMenuEntryText:
    '  "setup.workspace-navigator": {"icon":"󰒓","label":"Workspace Navigator",'
    + '"description":"Configure swipe behavior, Alt+Tab scope, and blur",'
    + '"action":"omarchy-shell roubilibo.workspace-navigator settings"}'
  property bool launcherMenuRegistrationReady: false
  property FileView flickSettingsFile: FileView {
    path: root.flickSettingsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadFlickSettings(text())
  }

  function loadFlickSettings(raw) {
    try {
      var settings = JSON.parse(String(raw || "{}"))
      if (settings.flickBehavior === "single-page"
          || settings.flickBehavior === "kinetic")
        root.flickBehavior = settings.flickBehavior
      if (settings.altTabScope === "all" || settings.altTabScope === "workspace")
        root.altTabScope = settings.altTabScope
      root.blurEnabled = settings.blurEnabled === true
      root.applyBlurState()
    } catch (e) {}
  }

  function saveSettings() {
    flickSettingsFile.setText(JSON.stringify({
      flickBehavior: root.flickBehavior,
      altTabScope: root.altTabScope,
      blurEnabled: root.blurEnabled
    }, null, 2) + "\n")
  }

  function setFlickBehavior(value) {
    var mode = String(value) === "single-page" ? "single-page" : "kinetic"
    root.flickBehavior = mode
    root.settingsSelection = 0
    root.saveSettings()
    return "ok"
  }

  function setAltTabScope(value) {
    root.altTabScope = String(value) === "all" ? "all" : "workspace"
    root.settingsSelection = 1
    root.saveSettings()
    return "ok"
  }

  function setBlurEnabled(value) {
    root.blurEnabled = Boolean(value)
    root.settingsSelection = 2
    root.saveSettings()
    root.applyBlurState()
    return "ok"
  }

  function applyBlurState() {
    if (!root.blurBaseStateKnown) {
      root.blurApplyPending = true
      if (!blurBaseProbe.running) blurBaseProbe.running = true
      return
    }
    if (blurApplyProcess.running) {
      root.blurApplyPending = true
      return
    }
    root.blurApplyPending = false
    blurApplyProcess.running = true
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
    if (option.kind === "flick")
      root.setFlickBehavior(root.flickBehavior === "kinetic"
        ? "single-page" : "kinetic")
    else if (option.kind === "altTab")
      root.setAltTabScope(root.altTabScope === "all"
        ? "workspace" : "all")
    else if (option.kind === "blur")
      root.setBlurEnabled(!root.blurEnabled)
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
    if (!root.launcherMenuRegistrationReady) return
    var current = String(raw || "")
    if (/^\s*"setup\.workspace-navigator"\s*:/m.test(current)) return

    if (current.trim() === "") {
      launcherMenuFile.setText("{\n" + root.launcherMenuEntryText + "\n}\n")
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
    launcherMenuFile.setText(lines.join("\n"))
  }

  Component.onCompleted: {
    launcherMenuDirectoryProcess.running = true
    root.rememberAltTabFocus(Hyprland.activeToplevel)
    root.applyBlurState()
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

    try {
      var workspace = toplevel && toplevel.workspace ? toplevel.workspace : null
      var workspaceId = workspace ? root.positiveWorkspaceId(workspace.id) : -1
      if (workspaceId > 0) root.dispatchFocusWorkspace(workspaceId)

      if (Hyprland.usingLua) {
        Hyprland.dispatch("hl.dsp.focus({ window = \"address:" + address + "\" })")
      } else {
        Hyprland.dispatch("focuswindow address:" + address)
      }

      // follow_mouse is a global Hyprland input option. It is already enabled
      // on this system, so follow the selected window by moving the pointer to
      // its center instead of changing the user's global input configuration.
      var ipc = toplevel ? toplevel.lastIpcObject : null
      var at = ipc && ipc.at && ipc.at.length >= 2 ? ipc.at : null
      var size = ipc && ipc.size && ipc.size.length >= 2 ? ipc.size : null
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
    root.dismiss()
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

  function ensureAltTabSelectionVisible() {
    altTabOverlay.ensureSelectionVisible(root.altTabIndex)
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
    root.applyBlurState()
  }

  function altTabCommit() {
    if (!root.altTabOpen) return
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
    root.applyBlurState()
    root.focusToplevel(selected)
  }

  function closeAltTabSession(applyDeferredFocus) {
    altTabRefreshTimer.stop()
    var deferred = root.altTabDeferredFocusAddress
    root.altTabDeferredFocusAddress = ""
    root.altTabOpen = false
    root.altTabIndex = -1
    root.altTabCandidates = []
    root.altTabSnapshot = []
    root.selectedToplevel = null
    root.applyBlurState()
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
    root.applyBlurState()
    root.currentPage = root.pageForIndex(root.selectedIndex)
    Qt.callLater(function() {
      root.clampSelection()
      root.scrollToPage(root.currentPage)
    })
  }

  function close() {
    root.closeWorkspaceContext()
    root.opened = false
    root.settingsMode = false
    root.showKeybindHint = false
    root.altTabCancel()
    root.applyBlurState()
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
    id: blurApplyProcess
    command: ["hyprctl", "eval", root.blurEvalCommand]
    onExited: function(exitCode) {
      if (exitCode !== 0)
        console.warn("workspace overview: could not apply blur state", exitCode)
      if (root.blurApplyPending) root.applyBlurState()
    }
  }

  Process {
    id: blurBaseProbe
    command: ["sh", "-c",
      "set -e; hyprctl -j getoption decoration:blur:enabled; "
        + "hyprctl -j getoption decoration:blur:size; "
        + "hyprctl -j getoption decoration:blur:passes"]
    stdout: StdioCollector {
      id: blurBaseProbeOutput
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var options = String(blurBaseProbeOutput.text || "").trim().split(/\r?\n/)
      try {
        if (exitCode !== 0 || options.length !== 3)
          throw new Error("incomplete Hyprland blur options")
        var enabled = JSON.parse(options[0])
        var size = JSON.parse(options[1])
        var passes = JSON.parse(options[2])
        if (typeof enabled.bool !== "boolean"
            || !isFinite(Number(size.int)) || !isFinite(Number(passes.int)))
          throw new Error("invalid Hyprland blur options")
        root.blurBaseEnabled = enabled.bool
        root.blurBaseSize = Number(size.int)
        root.blurBasePasses = Number(passes.int)
      } catch (e) {
        // Do not overwrite compositor-wide blur settings if we failed to
        // capture their original values.
        console.warn("workspace overview: could not read existing blur options", e)
        root.blurBaseStateKnown = false
        root.blurApplyPending = false
        return
      }
      root.blurBaseStateKnown = true
      if (root.blurApplyPending) root.applyBlurState()
    }
  }

  Process {
    id: launcherMenuDirectoryProcess
    command: ["mkdir", "-p", root.launcherMenuDirectory]
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        console.warn("workspace overview: could not prepare omarchy menu extension", exitCode)
        return
      }
      root.launcherMenuRegistrationReady = true
      launcherMenuFile.reload()
    }
  }

  FileView {
    id: launcherMenuFile
    path: root.launcherMenuPath
    printErrors: false
    onLoaded: root.ensureLauncherMenuEntry(text())
    onLoadFailed: {
      if (root.launcherMenuRegistrationReady)
        setText("{\n" + root.launcherMenuEntryText + "\n}\n")
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
      if (name === "closewindow") root.forgetAltTabWindow(event)
      if (!root.opened && !root.altTabOpen) return

      // Keep the delegate tree stable until the native drag session has
      // released the pointer. The final refresh is scheduled by
      // endWindowDrag().
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
    function setFlickBehavior(mode: string): string {
      return root.setFlickBehavior(mode)
    }
    function setAltTabScope(scope: string): string {
      return root.setAltTabScope(scope)
    }
    function setBlurEnabled(value: string): string {
      var enabled = value === "true" || value === "1" || value === "on"
      return root.setBlurEnabled(enabled)
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
              text: root.pageCountFor(root.workspaceEntries(root.workspaceRevision).length) > 1
                ? "Swipe horizontally for additional workspaces  •  Click a card to enter"
                : "Click a card to enter  •  Click a thumbnail to focus  •  Right-click for actions"
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
                text: "Overview: ←/→ or H/L navigate  •  ↑/↓ or K/J move rows  •  Tab/Shift+Tab select  •  Enter/Space activate  •  Esc close  •  ?: hints\nSUPER+TAB: toggle overview  •  ALT+TAB: next window  •  ALT+SHIFT+TAB: previous  •  release ALT: focus selected"
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
              property real horizontalWheelAccumulator: 0
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

              // Wayland touchpads expose a two-finger horizontal swipe as
              // wheel/axis events rather than as a single-pointer drag.
              // Flickable does not page on those events by itself, so bridge
              // the horizontal delta to the same page snap used by dragging.
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

                var delta = pixelX !== 0 ? pixelX : angleX
                horizontalWheelAccumulator += delta

                var threshold = pixelX !== 0 ? 48 : 120
                if (Math.abs(horizontalWheelAccumulator) < threshold)
                  return

                // Qt's horizontal wheel delta describes content scrolling,
                // which is opposite to the physical finger direction. Match
                // Flickable's direct-drag behavior: swipe left advances pages.
                var direction = horizontalWheelAccumulator > 0 ? -1 : 1
                horizontalWheelAccumulator = 0
                root.scrollToPage(root.currentPage + direction)
                event.accepted = true
              }

              // MouseArea.onWheel is the reliable path for libinput axis
              // events in Quickshell, including two-finger touchpad swipes.
              MouseArea {
                anchors.fill: parent
                z: 100
                acceptedButtons: Qt.NoButton
                onWheel: function(event) {
                  workspaceFlickable.handleHorizontalWheel(event)
                }
              }

              // Make page swipes feel snappier by increasing the travel speed
              // and letting the flick settle sooner.
              maximumFlickVelocity: 8000
              flickDeceleration: 5000
              onMovementStarted: {
                horizontalWheelAccumulator = 0
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
                          workspaceName: addCard ? "" : root.workspaceName(
                            root.workspaceById(cardWorkspaceId, root.workspaceRevision),
                            cardWorkspaceId)
                          previewScreen: panelScreen
                          contextTarget: keyCatcher
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
                          onWorkspaceContextRequested: function(x, y) {
                            root.openWorkspaceContext(cardWorkspaceId, x, y)
                          }
                          onAddWorkspaceRequested: root.addWorkspace()
                          onWorkspaceDeleteRequested: root.deleteWorkspace(cardWorkspaceId)
                          onWindowDragStarted: function(toplevel) {
                            root.selectWindow(toplevel)
                            root.beginWindowDrag(toplevel)
                          }
                          onWindowDragFinished: function(toplevel) { root.endWindowDrag(toplevel) }
                          onWindowSelected: function(toplevel) { root.selectWindow(toplevel) }
                          onWindowActivated: function(toplevel) { root.focusToplevel(toplevel) }
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
                ? "Swipe left for next page    •    page "
                  + String(root.currentPage + 1) + "/"
                  + String(root.pageCountFor(root.workspaceEntries(root.workspaceRevision).length))
                  + "    •    swipe right for previous page    •    ?: show/hide shortcuts"
                : "Click card: enter    Click thumbnail: focus    Left-drag: move/swap    Right-click: actions    ?: shortcuts"
              color: Util.alpha(Color.menu.text, 0.58)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }
          }

          AltTabOverlay {
            id: altTabOverlay
            opened: root.altTabOpen
            scope: root.altTabScope
            candidates: root.altTabCandidates
            selectedIndex: root.altTabIndex
            workspaceLabelFor: root.altTabWorkspaceLabel
            onSelectionRequested: function(index) { root.altTabIndex = index }
            onCommitRequested: root.altTabCommit()
          }

          SettingsDialog {
            opened: root.settingsMode
            options: root.settingsOptions
            selectedIndex: root.settingsSelection
            flickBehavior: root.flickBehavior
            altTabScope: root.altTabScope
            blurEnabled: root.blurEnabled
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
      }
    }
  }
}
