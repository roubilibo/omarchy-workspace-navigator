#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="roubilibo.workspace-navigator"
BEGIN_MARKER="-- BEGIN $PLUGIN_ID managed keybindings"
END_MARKER="-- END $PLUGIN_ID managed keybindings"
CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_FILE="$CONFIG_ROOT/hypr/bindings.lua"
MODE="install"

fail() {
  printf 'workspace-navigator: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: %s [--remove]\n' "${0##*/}"
}

case "${1:-}" in
  "") ;;
  --remove) MODE="remove" ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }

[[ -f "$CONFIG_FILE" ]] || fail "Hyprland bindings file not found: $CONFIG_FILE"
CONFIG_FILE="$(realpath -e -- "$CONFIG_FILE")"
CONFIG_DIR="${CONFIG_FILE%/*}"

base_tmp="$(mktemp "$CONFIG_DIR/.workspace-navigator-base.XXXXXX")"
new_tmp="$(mktemp "$CONFIG_DIR/.workspace-navigator-new.XXXXXX")"
trap 'rm -f -- "$base_tmp" "$new_tmp"' EXIT

begin_count="$(grep -Fxc -- "$BEGIN_MARKER" "$CONFIG_FILE" || true)"
end_count="$(grep -Fxc -- "$END_MARKER" "$CONFIG_FILE" || true)"

if [[ "$begin_count" != "$end_count" ]] || (( begin_count > 1 )); then
  fail "managed block markers are incomplete or duplicated; left $CONFIG_FILE unchanged"
fi

if (( begin_count == 1 )); then
  awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    $0 == begin {
      if (inside || seen_begin) bad = 1
      inside = 1
      seen_begin = 1
      next
    }
    $0 == end {
      if (!inside || seen_end) bad = 1
      inside = 0
      seen_end = 1
      next
    }
    !inside { print }
    END {
      if (inside || bad || seen_begin != seen_end) exit 2
    }
  ' "$CONFIG_FILE" > "$base_tmp" ||
    fail "managed block is malformed; left $CONFIG_FILE unchanged"
else
  cp -- "$CONFIG_FILE" "$base_tmp"
fi

if [[ "$MODE" == "remove" ]]; then
  (( begin_count == 1 )) || {
    printf 'workspace-navigator: no managed keybinding block to remove\n'
    exit 0
  }
else
  if ! awk '
    function is_target_bind(line, call, key) {
      if (!match(line, /^[[:space:]]*(hl|o)\.bind[[:space:]]*\([[:space:]]*"[^"]+"/))
        return 0
      call = substr(line, RSTART, RLENGTH)
      sub(/^[^(]*\([[:space:]]*"/, "", call)
      sub(/".*$/, "", call)
      gsub(/[[:space:]]/, "", call)
      return call == "SUPER+TAB" || call == "ALT+TAB" || call == "ALT+SHIFT+TAB" || call == "ALT"
    }
    is_target_bind($0) {
      if ($0 ~ /Workspace Navigator/ || $0 ~ /roubilibo\.workspace-navigator/)
        next
      printf "  line %d: %s\n", NR, $0 > "/dev/stderr"
      conflict = 1
    }
    END { if (conflict) exit 1 }
  ' "$base_tmp"; then
    fail "a non-plugin binding uses SUPER+TAB or Alt+Tab; resolve that key conflict first (file unchanged)"
  fi

  if grep -Fq 'hl.define_submap("workspace_navigator"' "$base_tmp"; then
    if ! grep -Fq 'Workspace Navigator: emergency exit modal input' "$base_tmp" \
      || ! grep -Fq 'omarchy-shell shell toggle roubilibo.workspace-navigator' "$base_tmp"; then
      fail "workspace_navigator is already defined by unrelated config; left $CONFIG_FILE unchanged"
    fi
    define_submap=0
  else
    define_submap=1
  fi

  {
    cat -- "$base_tmp"
    printf '\n%s\n' "$BEGIN_MARKER"
    if (( define_submap )); then
      cat <<'LUA'
hl.define_submap("workspace_navigator", function()
    hl.bind("CTRL + ALT + ESCAPE", function()
      hl.dispatch(hl.dsp.submap("reset"))
      hl.exec_cmd("omarchy-shell shell toggle roubilibo.workspace-navigator")
    end, {
      description = "Workspace Navigator: emergency exit modal input",
    })
    hl.bind("catchall", function() end, { non_consuming = true })
  end)
LUA
    fi

    cat <<'LUA'
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
LUA
    printf '%s\n' "$END_MARKER"
  } > "$new_tmp"
fi

if cmp -s -- "$CONFIG_FILE" "$new_tmp"; then
  printf 'workspace-navigator: keybindings are already up to date\n'
  exit 0
fi

backup_file="$CONFIG_FILE.bak.$(date +%Y%m%d-%H%M%S).$$"
cp -p -- "$CONFIG_FILE" "$backup_file"
chmod --reference="$CONFIG_FILE" "$new_tmp"

errors_before=""
can_reload=0
if command -v hyprctl >/dev/null 2>&1 \
  && hyprctl configerrors >/dev/null 2>&1; then
  can_reload=1
  errors_before="$(hyprctl configerrors 2>&1 || true)"
fi

mv -f -- "$new_tmp" "$CONFIG_FILE"

restore_backup() {
  local restore_tmp
  restore_tmp="$(mktemp "$CONFIG_DIR/.workspace-navigator-restore.XXXXXX")"
  cp -p -- "$backup_file" "$restore_tmp"
  mv -f -- "$restore_tmp" "$CONFIG_FILE"
  hyprctl reload >/dev/null 2>&1 || true
}

if (( can_reload )); then
  if ! hyprctl reload >/dev/null 2>&1; then
    restore_backup
    fail "Hyprland rejected the reload; restored the original file from $backup_file"
  fi

  errors_after="$(hyprctl configerrors 2>&1 || true)"
  if [[ "$errors_after" != "$errors_before" ]]; then
    restore_backup
    fail "Hyprland reported new config errors; restored the original file from $backup_file"
  fi
else
  printf 'workspace-navigator: saved atomically; run "hyprctl reload" in a Hyprland session to apply it\n'
fi

if [[ "$MODE" == "remove" ]]; then
  printf 'workspace-navigator: removed its managed bindings; previous config backed up at %s\n' "$backup_file"
else
  printf 'workspace-navigator: installed Super+Tab and Alt+Tab bindings; previous config backed up at %s\n' "$backup_file"
fi
