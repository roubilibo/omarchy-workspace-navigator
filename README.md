# Workspace Navigator

Workspace navigation panel for Omarchy Shell with live Hyprland window
thumbnails.

https://github.com/user-attachments/assets/05c1dcf1-332a-4b1e-b2d7-3017d8340ca5

![Workspace Navigator preview](preview.png)


## Features

- 3×3 workspace grid with horizontal pages.
- Live thumbnails showing each window's layout.
- Left-click a workspace to enter it.
- Left-click a window thumbnail to focus it.
- Right-click a workspace for rename, persistence, move, and delete actions.
- Drag windows between workspaces.
- Drag windows within a workspace to reorder them.
- Create and delete empty workspaces above workspace 8.
- Alt+Tab switcher with live window previews.
- Alt+Tab previews preserve each window's original aspect ratio.
- Alt+Tab scope can be limited to the current workspace or include all workspaces.
- Keyboard navigation with arrows, `H/J/K/L`, `Tab`, and `Enter`.

## Swipe settings

After the plugin is enabled, it registers `Workspace Navigator` in
`Omarchy Menu → Setup`. Open it to choose:

- `Kinetic Swipe`: optional; when off, the default is Single Page.
- `Alt+Tab: All Workspaces`: optional; when off, the default is Current Workspace.
- `Overview Background Blur`: blur the desktop behind the navigator on demand.

The settings page is a centered floating card. It does not show the overview
scrim behind it.

Each optional behavior is represented by one toggle. Turning a toggle off
restores its default behavior.

Horizontal two-finger touchpad swipes page through the workspace overview.

### Mouse behavior

- Click a workspace card to focus it.
- Click a window thumbnail to focus that window.
- Drag a thumbnail to another workspace to move it.
- Drop a thumbnail on another thumbnail in the same workspace to swap them.
- Right-click a workspace card to open its action menu.

The setting is saved automatically. It can also be opened directly with:

```bash
omarchy-shell roubilibo.workspace-navigator settings
```

### Alt+Tab

The local Hyprland binding replaces Omarchy's default Alt+Tab actions with the
Workspace Navigator preview switcher. Hold Alt, press Tab to cycle, and release
Alt to focus the highlighted window. Esc cancels the switcher.

## Install

```bash
omarchy plugin add https://github.com/roubilibo/omarchy-workspace-navigator.git --enable --yes
```

### Install keyboard shortcuts

Add this small loader block to the end of
`~/.config/hypr/bindings.lua`:

```lua
-- BEGIN roubilibo.workspace-navigator managed keybindings
do
  local navigator = os.getenv("HOME") .. "/.config/omarchy/plugins/roubilibo.workspace-navigator/hypr/workspace-navigator.lua"
  local file = io.open(navigator, "r")
  if file then
    file:close()
    pcall(dofile, navigator)
  end
end
-- END roubilibo.workspace-navigator managed keybindings
```

The actual bindings live in the plugin at `hypr/workspace-navigator.lua`, while
your Hyprland config contains only this loader. Reload Hyprland after adding the
block or updating the plugin:

```bash
hyprctl reload
```

The plugin can also be opened directly without a keybinding:

```bash
omarchy-shell shell toggle roubilibo.workspace-navigator
```

Update an existing installation with:

```bash
omarchy plugin update roubilibo.workspace-navigator
```

To remove it:

```bash
omarchy plugin remove roubilibo.workspace-navigator --yes
```

The plugin uses compositor-backed previews only. It does not save screenshots,
access the network, or use privilege escalation. Omarchy plugins run as
unsandboxed code inside `omarchy-shell`; only install repositories you trust.

## License

MIT
