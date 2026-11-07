# Workspace Navigator

Workspace navigation panel for Omarchy Shell with live Hyprland window
thumbnails.



https://github.com/user-attachments/assets/0df6a9ee-ff00-40c7-9eb1-ff119a4b6a82





## Features

- Mission Control overview with a horizontal workspace strip and one large preview of the selected workspace.
- The strip starts with five workspaces; use `Add workspace` to show more. Workspace previews update live while the overview is open.
- Live thumbnails showing each window's layout.
- Left-click a workspace to enter it.
- Left-click a window thumbnail to focus it.
- Right-click a workspace for rename, persistence, move, and delete actions.
- Drag windows between workspaces while preserving their floating or tiled state. A tiled window leaves the source layout during the drag without changing its floating state, so the remaining tiles can reflow; it returns to tiling when released.
- Dragging a window from the large preview starts shrinking on pickup, continues as it approaches the strip, and fits the destination thumbnail on entry. Drags between strip thumbnails keep their size.
- Drop a tiled window on another tiled window in the same workspace to swap their layout positions.
- Delete empty workspaces added beyond the first five.
- Alt+Tab switcher with live window previews.
- Alt+Tab previews preserve each window's original aspect ratio.
- Alt+Tab cards adapt to the display, with the bottom row holding the larger share up to 10 windows; larger sets wrap into a vertically scrollable grid.
- Alt+Tab scope can be limited to the current workspace or include all workspaces.
- Keyboard navigation with arrows, `H/J/K/L`, `Tab`, and `Enter`.

## Settings

After the plugin is enabled, it registers `Workspace Navigator` in
`Omarchy Menu → Setup`. Open it to choose:

- `Alt+Tab: All Workspaces`: optional; when off, the default is Current Workspace.

The overview follows `Appearance → Windows → Window Opacity`: backdrop blur is
enabled only in Glassy mode, and disabled in Opaque or Transparent mode.

The settings page is a centered floating card. It does not show the overview
scrim behind it.

Each optional behavior is represented by one toggle. Turning a toggle off
restores its default behavior.

Horizontal two-finger touchpad swipes move through the workspace strip.

### Mouse behavior

- Click a workspace card to focus it.
- Click a window thumbnail to focus that window.
- Drag a floating thumbnail to reposition it, or drag any thumbnail to another workspace to move it.
- Tiled windows leave the source layout during a drag without becoming floating, then return to tiling when released. Drop one on another tiled thumbnail in the same workspace to swap their layout positions.
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
install -Dm755 ~/.config/omarchy/plugins/roubilibo.workspace-navigator/bin/omarchy ~/.local/bin/omarchy
```

The second command installs a user-level dispatcher wrapper. It forwards all
Omarchy commands unchanged, and removes this plugin's Setup menu entry after a
successful uninstall. The wrapper removes itself after uninstalling this
plugin, so the packaged Omarchy dispatcher is used normally afterward.

When enabled, the plugin adds its managed loader block to
`~/.config/hypr/bindings.lua` and reloads Hyprland if the file changes. It
backs up an existing bindings file before editing it. The loader checks
`shell.json`, so the shortcuts are inactive while the plugin is disabled or
removed.

The source is organized by responsibility: `src/Panel.qml` coordinates plugin
state, reusable QML UI lives in `src/components/`, and shared JavaScript logic
lives in `src/lib/`. The Hyprland binding source is in `hypr/`; only its small
loader block is added to `bindings.lua`. The bounded, no-follow config-file
helper is in `bin/`. The plugin reloads Hyprland automatically when it adds or
repairs the block.

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
