# Workspace Overview

Workspace overview panel for Omarchy Shell with live Hyprland window
thumbnails.

![Workspace Overview preview](assets/preview.png)

<video src="assets/demo.mp4" controls width="100%">
  <a href="assets/demo.mp4">▶ Watch the demo video</a>
</video>

## Features

- 3×3 workspace grid with horizontal pages.
- Live thumbnails showing each window's layout.
- Right-click a workspace to enter it.
- Drag windows between workspaces.
- Drag windows within a workspace to reorder them.
- Create and delete empty workspaces above workspace 8.
- Keyboard navigation with arrows, `H/J/K/L`, `Tab`, and `Enter`.

## Install

```bash
omarchy plugin add https://github.com/roubilibo/omarchy-workspace-overview.git --enable --yes
```

To open it with `SUPER+TAB`, add this to `~/.config/hypr/bindings.lua`:

```lua
hl.unbind("SUPER + TAB")
o.bind("SUPER + TAB", "Workspace overview",
  "omarchy-shell shell toggle offmarchy.workspace-overview")
```

You can also open it directly:

```bash
omarchy-shell shell toggle offmarchy.workspace-overview
```

Update an existing installation with:

```bash
omarchy plugin update offmarchy.workspace-overview
```

The plugin uses compositor-backed previews only. It does not save screenshots,
access the network, or use privilege escalation. Omarchy plugins run as
unsandboxed code inside `omarchy-shell`; only install repositories you trust.

## License

MIT
