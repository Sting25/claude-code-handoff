#!/usr/bin/env bash
# install.sh — wire this repo's handoff skill into ~/.claude/.
#
# What it does:
#   1. Symlinks bin/ scripts + skills/handoff/* into ~/.claude/.
#   2. Patches ~/.claude/settings.json to add three hooks
#      (SessionStart / SessionEnd / Stop) and two permission entries.
#      Requires jq; falls back to printing the snippet if jq is missing.
#
# Idempotent. Existing files at symlink targets are backed up to
# <path>.bak.<timestamp> before being replaced. Existing settings.json
# is backed up the same way before any patch. Re-runs are safe and only
# touch what's actually missing.
#
# Usage:
#   ./install.sh              # install (symlink + patch)
#   ./install.sh --uninstall  # remove symlinks + strip patched entries
#   ./install.sh --help

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
claude_home="${CLAUDE_HOME:-$HOME/.claude}"
settings="$claude_home/settings.json"
ts="$(date +%Y%m%d_%H%M%S)"
mode=install

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) mode=uninstall ;;
    --help|-h)
      sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# Canonical hook commands and permissions. Edit these together with
# CHANGELOG.md if you ever change the snippet shape.
ss_cmd='f="$CLAUDE_PROJECT_DIR/.claude/handoff_current.md"; if [ -f "$f" ]; then echo '"'"'## Auto-loaded handoff from previous session'"'"'; echo; cat "$f"; fi'
se_cmd='bash $HOME/.claude/bin/write_handoff.sh >/dev/null 2>&1 || true'
st_cmd='bash $HOME/.claude/bin/handoff_turn_append.sh 2>/dev/null || true'
up_cmd='bash $HOME/.claude/bin/handoff_ctx_check.sh 2>/dev/null || true'
perm_write="Bash(bash $HOME/.claude/bin/write_handoff.sh)"
perm_stop="Bash(bash $HOME/.claude/bin/handoff_turn_append.sh)"
perm_ctx="Bash(bash $HOME/.claude/bin/handoff_ctx_check.sh)"

# Marker substrings used to detect prior installs (and to remove on uninstall).
ss_marker="handoff_current.md"
se_marker="write_handoff.sh"
st_marker="handoff_turn_append.sh"
up_marker="handoff_ctx_check.sh"

# -------------------------------------------------------------------- symlinks

link() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [[ -L "$dst" ]]; then
    local current
    current="$(readlink "$dst")"
    if [[ "$current" == "$src" ]]; then
      echo "  ok      $dst -> $src"
      return
    fi
    echo "  relink  $dst (was -> $current)"
    rm "$dst"
  elif [[ -e "$dst" ]]; then
    echo "  backup  $dst -> $dst.bak.$ts"
    mv "$dst" "$dst.bak.$ts"
  else
    echo "  new     $dst"
  fi
  ln -s "$src" "$dst"
}

unlink_if_ours() {
  local dst="$1" src="$2"
  if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then
    rm "$dst"
    echo "  remove  $dst"
  elif [[ -e "$dst" ]]; then
    echo "  skip    $dst (not our symlink; leaving alone)"
  else
    echo "  ok      $dst (already absent)"
  fi
}

install_symlinks() {
  link "$repo_root/bin/write_handoff.sh"        "$claude_home/bin/write_handoff.sh"
  link "$repo_root/bin/handoff_turn_append.sh"  "$claude_home/bin/handoff_turn_append.sh"
  link "$repo_root/bin/handoff_ctx_check.sh"    "$claude_home/bin/handoff_ctx_check.sh"
  link "$repo_root/skills/handoff/SKILL.md"     "$claude_home/skills/handoff/SKILL.md"
  link "$repo_root/skills/handoff/README.md"    "$claude_home/skills/handoff/README.md"
  chmod +x "$repo_root/bin/write_handoff.sh" \
           "$repo_root/bin/handoff_turn_append.sh" \
           "$repo_root/bin/handoff_ctx_check.sh"
}

uninstall_symlinks() {
  unlink_if_ours "$claude_home/bin/write_handoff.sh"        "$repo_root/bin/write_handoff.sh"
  unlink_if_ours "$claude_home/bin/handoff_turn_append.sh"  "$repo_root/bin/handoff_turn_append.sh"
  unlink_if_ours "$claude_home/bin/handoff_ctx_check.sh"    "$repo_root/bin/handoff_ctx_check.sh"
  unlink_if_ours "$claude_home/skills/handoff/SKILL.md"     "$repo_root/skills/handoff/SKILL.md"
  unlink_if_ours "$claude_home/skills/handoff/README.md"    "$repo_root/skills/handoff/README.md"
}

# ------------------------------------------------------------------ settings.json

print_manual_snippet() {
  cat <<EOF

Paste this into $settings under "hooks" and "permissions":

{
  "hooks": {
    "SessionStart":      [{ "hooks": [{ "type": "command", "command": "$ss_cmd" }] }],
    "SessionEnd":        [{ "hooks": [{ "type": "command", "command": "$se_cmd" }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "$st_cmd" }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "$up_cmd" }] }]
  },
  "permissions": {
    "allow": [
      "$perm_write",
      "$perm_stop",
      "$perm_ctx"
    ]
  }
}
EOF
}

maybe_install_hook() {
  local event="$1" marker="$2" cmd="$3"
  if jq -e --arg e "$event" --arg m "$marker" \
       '(.hooks[$e] // []) | any(.. | .command? // "" | contains($m))' \
       "$settings" >/dev/null 2>&1; then
    echo "  ok      hook $event (already present)"
    return
  fi
  jq --arg e "$event" --arg c "$cmd" '
    .hooks //= {}
    | .hooks[$e] = ((.hooks[$e] // []) + [{"hooks": [{"type": "command", "command": $c}]}])
  ' "$settings" > "$settings.tmp"
  mv "$settings.tmp" "$settings"
  echo "  add     hook $event"
}

maybe_install_perm() {
  local perm="$1"
  if jq -e --arg p "$perm" '(.permissions.allow // []) | index($p)' \
       "$settings" >/dev/null 2>&1; then
    echo "  ok      permission already present: $perm"
    return
  fi
  jq --arg p "$perm" '
    .permissions //= {}
    | .permissions.allow = ((.permissions.allow // []) + [$p])
  ' "$settings" > "$settings.tmp"
  mv "$settings.tmp" "$settings"
  echo "  add     permission: $perm"
}

maybe_uninstall_hook() {
  local event="$1" marker="$2"
  if ! jq -e --arg e "$event" --arg m "$marker" \
         '(.hooks[$e] // []) | any(.. | .command? // "" | contains($m))' \
         "$settings" >/dev/null 2>&1; then
    echo "  ok      hook $event (not present)"
    return
  fi
  jq --arg e "$event" --arg m "$marker" '
    .hooks[$e] |= (map(select(
      (.hooks // []) | all((.command // "") | contains($m) | not)
    )))
    | if (.hooks[$e] | length) == 0 then del(.hooks[$e]) else . end
  ' "$settings" > "$settings.tmp"
  mv "$settings.tmp" "$settings"
  echo "  remove  hook $event"
}

maybe_uninstall_perm() {
  local perm="$1"
  if ! jq -e --arg p "$perm" '(.permissions.allow // []) | index($p)' \
         "$settings" >/dev/null 2>&1; then
    echo "  ok      permission not present: $perm"
    return
  fi
  jq --arg p "$perm" '
    .permissions.allow |= (map(select(. != $p)))
  ' "$settings" > "$settings.tmp"
  mv "$settings.tmp" "$settings"
  echo "  remove  permission: $perm"
}

patch_settings() {
  if ! command -v jq >/dev/null 2>&1; then
    echo
    echo "jq not found — can't auto-patch $settings."
    print_manual_snippet
    return
  fi
  if [[ ! -f "$settings" ]]; then
    echo '{}' > "$settings"
    echo "  new     $settings (created empty)"
  fi
  cp "$settings" "$settings.bak.$ts"
  echo "  backup  $settings -> $settings.bak.$ts"
  maybe_install_hook SessionStart     "$ss_marker" "$ss_cmd"
  maybe_install_hook SessionEnd       "$se_marker" "$se_cmd"
  maybe_install_hook Stop             "$st_marker" "$st_cmd"
  maybe_install_hook UserPromptSubmit "$up_marker" "$up_cmd"
  maybe_install_perm "$perm_write"
  maybe_install_perm "$perm_stop"
  maybe_install_perm "$perm_ctx"
  # If no change vs backup, drop the redundant backup.
  if cmp -s "$settings" "$settings.bak.$ts"; then
    rm "$settings.bak.$ts"
    echo "  ok      no settings.json changes (backup removed)"
  fi
}

unpatch_settings() {
  if ! command -v jq >/dev/null 2>&1; then
    echo
    echo "jq not found — can't auto-strip entries from $settings."
    echo "Manually remove any hook commands containing:"
    echo "  - $ss_marker"
    echo "  - $se_marker"
    echo "  - $st_marker"
    echo "  - $up_marker"
    echo "and the permission entries:"
    echo "  - $perm_write"
    echo "  - $perm_stop"
    echo "  - $perm_ctx"
    return
  fi
  if [[ ! -f "$settings" ]]; then
    echo "  ok      $settings does not exist; nothing to strip"
    return
  fi
  cp "$settings" "$settings.bak.$ts"
  echo "  backup  $settings -> $settings.bak.$ts"
  maybe_uninstall_hook SessionStart     "$ss_marker"
  maybe_uninstall_hook SessionEnd       "$se_marker"
  maybe_uninstall_hook Stop             "$st_marker"
  maybe_uninstall_hook UserPromptSubmit "$up_marker"
  maybe_uninstall_perm "$perm_write"
  maybe_uninstall_perm "$perm_stop"
  maybe_uninstall_perm "$perm_ctx"
  if cmp -s "$settings" "$settings.bak.$ts"; then
    rm "$settings.bak.$ts"
    echo "  ok      no settings.json changes (backup removed)"
  fi
}

# ------------------------------------------------------------------------ main

if [[ "$mode" == install ]]; then
  echo "installing handoff skill from $repo_root into $claude_home"
  echo
  echo "symlinks:"
  install_symlinks
  echo
  echo "settings.json:"
  patch_settings
  echo
  echo "done. start a new Claude Code session — /handoff is available now."
else
  echo "uninstalling handoff skill from $claude_home"
  echo
  echo "symlinks:"
  uninstall_symlinks
  echo
  echo "settings.json:"
  unpatch_settings
  echo
  echo "done. the repo at $repo_root is untouched."
fi
