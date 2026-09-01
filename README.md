# Workspace Overview

An Omarchy Shell/Quickshell panel inspired by `hyprtasking`.

It provides a deterministic numeric workspace grid with compositor-backed live
window thumbnails. The first page contains eight default workspaces and a ninth
`+` card. Additional workspaces are placed on horizontally scrollable 3×3 pages
instead of growing the overview vertically. Each thumbnail is projected from
Hyprland's actual window position and size, so the card shows the spatial layout
inside that workspace.
Window creation, closing, moving, resizing, and focus changes are refreshed from
Hyprland events while the panel is open.

Interactions:

- Clicking a thumbnail selects it inside the overview. This is an overview
  selection, not compositor focus, so selecting an inactive window does not
  switch workspace or move the cursor.
- Left-drag is used only for moving or reordering windows.
- Left-drag a thumbnail onto another card to move it silently to that workspace.
- Left-drag a thumbnail onto another thumbnail in the same workspace to swap
  it with the nearest tiled window in the direction of the drop.
- Right-click a workspace card to enter that workspace.
- Click the `+` card to create the next workspace and move to its page.
- Added empty workspaces expose a floating `×` button for deletion.
- Press `?` to show or hide the keyboard shortcut hint.
- `SUPER+TAB` toggles the overview; keyboard navigation remains available.

The plugin uses Omarchy Shell's public plugin surface, Quickshell's
`ScreencopyView`, and Hyprland IPC data. It does not replace the Hyprland
compositor and does not write screenshot files; thumbnails are rendered from
the compositor while the overview is visible.

Limitations:

- Same-workspace reordering requires Omarchy's Hyprland Lua dispatcher. It
  uses an explicit source and target selector, so it swaps exactly the two
  dropped thumbnails without changing workspace or focus.
- Grouped windows are represented by one thumbnail with tabs; dragging the
  thumbnail moves the compositor group as one unit.
- Workspace deletion is limited to empty workspaces created above the eight
  default cards.
