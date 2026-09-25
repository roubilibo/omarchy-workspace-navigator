-- Workspace Navigator keybindings for Hyprland configured in Lua.
--
-- Load this file from ~/.config/hypr/bindings.lua with the small loader block
-- documented in README.md. The loader intentionally points into this plugin
-- directory so the binding implementation can be updated with the plugin.
--
-- Loading it twice in one Lua state is a no-op. The snippet does not retain
-- Hyprland objects or tear them down; a fresh Hyprland Lua state picks up an
-- updated plugin file on the next config reload.

if rawget(_G, "__workspace_navigator") then
  return true
end

-- Omarchy installs plugins under ~/.config/omarchy/plugins. If the plugin is
-- disabled or removed from shell.json, leave Omarchy's default bindings alone.
local function enabled()
  local file = io.open((os.getenv("HOME") or "") .. "/.config/omarchy/shell.json", "r")
  if not file then
    return true
  end
  local text = file:read("a") or ""
  file:close()
  return text:find('"roubilibo.workspace-navigator"', 1, true) ~= nil
end

if not enabled() then
  return false
end

_G.__workspace_navigator = true

hl.define_submap("workspace_navigator", function()
  hl.bind("CTRL + ALT + ESCAPE", function()
    hl.dispatch(hl.dsp.submap("reset"))
    hl.exec_cmd("omarchy-shell shell toggle roubilibo.workspace-navigator")
  end, {
    description = "Workspace Navigator: emergency exit modal input",
  })
  hl.bind("catchall", function() end, { non_consuming = true })
end)

hl.unbind("SUPER + TAB")
o.bind("SUPER + TAB", "Workspace Navigator",
  "omarchy-shell shell toggle roubilibo.workspace-navigator")

hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")
o.bind("ALT + TAB", "Workspace Navigator: next window",
  [[omarchy-shell shell summon roubilibo.workspace-navigator '{"mode":"alt-tab-next"}']])
o.bind("ALT + SHIFT + TAB", "Workspace Navigator: previous window",
  [[omarchy-shell shell summon roubilibo.workspace-navigator '{"mode":"alt-tab-previous"}']])

hl.unbind("ALT")
o.bind("ALT", "Workspace Navigator: focus selected window",
  [[omarchy-shell roubilibo.workspace-navigator altTabCommit]],
  { release = true, submap_universal = true })

return true
