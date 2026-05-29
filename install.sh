#!/usr/bin/env bash
# install.sh — wire this repo's handoff skill into ~/.claude/.
#
# What it does:
#   1. Symlinks (or copies, where symlinks aren't available — e.g. Git
#      Bash on Windows) bin/ scripts + skills/* into ~/.claude/.
#   2. Patches ~/.claude/settings.json to add four hooks
#      (SessionStart / SessionEnd / Stop / UserPromptSubmit) and four
#      permission entries.
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

# Everything this installer creates under $claude_home — settings.json and its
# backups, the bin/skills copies (copy-mode installs), and the dirs themselves —
# is per-user state that can carry secrets (settings.json may hold env tokens).
# umask 077 makes all of it owner-only at creation; symlink *targets* are
# unaffected, and hooks run via `bash <path>` so the copies need no exec bit.
umask 077

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
claude_home="${CLAUDE_HOME:-$HOME/.claude}"
settings="$claude_home/settings.json"
ts="$(date +%Y%m%d_%H%M%S)"
mode=install

# Validate $claude_home before creating or patching anything under it: an empty,
# root, or relative value would scatter symlinks and a patched settings.json
# into unintended places. Require an absolute path other than '/'. A path
# outside $HOME is permitted (the test suite and some shared setups point it at
# a temp dir) but warned about, since it's unusual and easy to mistype.
case "$claude_home" in
  "" | "/")
    echo "ERROR: CLAUDE_HOME='$claude_home' is empty or root — refusing to operate there." >&2
    exit 2 ;;
  /*) : ;;
  *)
    echo "ERROR: CLAUDE_HOME='$claude_home' is not an absolute path — refusing." >&2
    exit 2 ;;
esac
if [[ -n "${HOME:-}" && "$claude_home" != "$HOME" && "$claude_home" != "$HOME"/* ]]; then
  echo "warning: CLAUDE_HOME='$claude_home' is outside \$HOME ($HOME); proceeding." >&2
fi

# Recovery state for the settings.json patch/unpatch sequence. The edits are a
# series of separate jq writes; if the script aborts (set -e) partway through,
# the EXIT trap both removes any half-written temp AND restores settings.json
# from the backup taken before the first edit — so a mid-sequence failure can't
# leave a half-patched (or corrupted) settings.json behind. patch_in_progress is
# armed only between the backup and the successful end of the sequence.
settings_backup=""
patch_in_progress=0
cleanup() {
  local rc=$?
  rm -f "$settings.tmp" 2>/dev/null || true
  if (( patch_in_progress )) && (( rc != 0 )) \
     && [[ -n "$settings_backup" && -f "$settings_backup" ]]; then
    cp -f "$settings_backup" "$settings" 2>/dev/null || true
    echo "  restore $settings from $settings_backup (aborted mid-patch, rc=$rc)" >&2
  fi
}
trap cleanup EXIT

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
ss_cmd='bash $HOME/.claude/bin/handoff_session_start.sh 2>/dev/null || true'
se_cmd='bash $HOME/.claude/bin/write_handoff.sh --if-curated >/dev/null 2>&1 || true'
st_cmd='bash $HOME/.claude/bin/handoff_turn_append.sh 2>/dev/null || true'
up_cmd='bash $HOME/.claude/bin/handoff_ctx_check.sh 2>/dev/null || true'
perm_write="Bash(bash $HOME/.claude/bin/write_handoff.sh)"
perm_stop="Bash(bash $HOME/.claude/bin/handoff_turn_append.sh)"
perm_ctx="Bash(bash $HOME/.claude/bin/handoff_ctx_check.sh)"
perm_ss="Bash(bash $HOME/.claude/bin/handoff_session_start.sh)"

# Marker substrings used to detect prior installs (and to remove on uninstall).
# These are the full installed command path (literal $HOME, exactly as stored in
# the command string) — NOT the bare filename — so detection and removal can't
# false-match a user's own unrelated hook that merely mentions the script name
# (e.g. a wrapper called "my_handoff_turn_append.sh"). Every version of this
# installer wrote the command with this path, so the match stays backward-
# compatible. The permission entries already match by exact string.
ss_marker='$HOME/.claude/bin/handoff_session_start.sh'
# Legacy marker — pre-0.3.0 SessionStart was an inline bash one-liner that
# cat'd handoff_current.md directly. We detect it (substring unique to the
# inline form, not present in the new script-call form) and migrate it out
# on re-install so users don't end up with both hooks firing.
ss_legacy_marker='if [ -f "$f" ]; then echo'
se_marker='$HOME/.claude/bin/write_handoff.sh'
st_marker='$HOME/.claude/bin/handoff_turn_append.sh'
up_marker='$HOME/.claude/bin/handoff_ctx_check.sh'

# -------------------------------------------------------------------- symlinks

# Set when symlinks aren't available and we fall back to copying, so the
# installer can remind the user that copies don't auto-update on git pull.
COPIED_ANY=0

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
    # A regular file identical to src is our own copy-mode install from a
    # prior run — treat as up to date rather than backing it up each time.
    if [[ -f "$dst" && ! -L "$dst" ]] && cmp -s "$src" "$dst"; then
      echo "  ok      $dst (copy)"
      return
    fi
    echo "  backup  $dst -> $dst.bak.$ts"
    mv "$dst" "$dst.bak.$ts"
  else
    echo "  new     $dst"
  fi
  # Prefer a real symlink; fall back to copying when the platform can't make
  # one. Git Bash on Windows without Developer Mode either errors on ln -s or
  # silently copies — the -L check catches the silent-copy case too.
  if ln -s "$src" "$dst" 2>/dev/null && [[ -L "$dst" ]]; then
    return
  fi
  rm -f "$dst"
  cp "$src" "$dst"
  COPIED_ANY=1
  echo "  copy    $dst (symlinks unavailable — re-run install.sh after updates)"
}

unlink_if_ours() {
  local dst="$1" src="$2"
  if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then
    rm "$dst"
    echo "  remove  $dst"
  elif [[ -f "$dst" && ! -L "$dst" ]] && cmp -s "$src" "$dst"; then
    # Copy-mode install (identical content) — ours to remove.
    rm "$dst"
    echo "  remove  $dst (copy)"
  elif [[ -e "$dst" ]]; then
    echo "  skip    $dst (not ours; leaving alone)"
  else
    echo "  ok      $dst (already absent)"
  fi
}

install_symlinks() {
  link "$repo_root/bin/write_handoff.sh"          "$claude_home/bin/write_handoff.sh"
  link "$repo_root/bin/handoff_turn_append.sh"    "$claude_home/bin/handoff_turn_append.sh"
  link "$repo_root/bin/handoff_ctx_check.sh"      "$claude_home/bin/handoff_ctx_check.sh"
  link "$repo_root/bin/handoff_session_start.sh"  "$claude_home/bin/handoff_session_start.sh"
  link "$repo_root/skills/handoff/SKILL.md"          "$claude_home/skills/handoff/SKILL.md"
  link "$repo_root/skills/handoff/README.md"         "$claude_home/skills/handoff/README.md"
  link "$repo_root/skills/handoff-more/SKILL.md"     "$claude_home/skills/handoff-more/SKILL.md"
  link "$repo_root/skills/handoff-recover/SKILL.md"  "$claude_home/skills/handoff-recover/SKILL.md"
  # Best-effort: the scripts are committed mode 0755, so a normal checkout is
  # already executable. This rescues filesystems that don't preserve the exec
  # bit (e.g. NTFS). It must never abort the install — under set -e a chmod on
  # source files the running user doesn't own (e.g. a forge user installing
  # from chris-owned files) would otherwise fail and skip patch_settings.
  chmod +x "$repo_root/bin/write_handoff.sh" \
           "$repo_root/bin/handoff_turn_append.sh" \
           "$repo_root/bin/handoff_ctx_check.sh" \
           "$repo_root/bin/handoff_session_start.sh" 2>/dev/null || true
}

uninstall_symlinks() {
  unlink_if_ours "$claude_home/bin/write_handoff.sh"          "$repo_root/bin/write_handoff.sh"
  unlink_if_ours "$claude_home/bin/handoff_turn_append.sh"    "$repo_root/bin/handoff_turn_append.sh"
  unlink_if_ours "$claude_home/bin/handoff_ctx_check.sh"      "$repo_root/bin/handoff_ctx_check.sh"
  unlink_if_ours "$claude_home/bin/handoff_session_start.sh"  "$repo_root/bin/handoff_session_start.sh"
  unlink_if_ours "$claude_home/skills/handoff/SKILL.md"          "$repo_root/skills/handoff/SKILL.md"
  unlink_if_ours "$claude_home/skills/handoff/README.md"         "$repo_root/skills/handoff/README.md"
  unlink_if_ours "$claude_home/skills/handoff-more/SKILL.md"     "$repo_root/skills/handoff-more/SKILL.md"
  unlink_if_ours "$claude_home/skills/handoff-recover/SKILL.md"  "$repo_root/skills/handoff-recover/SKILL.md"
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
      "$perm_ctx",
      "$perm_ss"
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
  # Remove only the matching command(s), not the whole hook group: a group may
  # hold a user's own co-located command alongside ours. Strip matching commands
  # from each group's inner list, then drop groups that became empty, then drop
  # the event if no groups remain.
  jq --arg e "$event" --arg m "$marker" '
    .hooks[$e] |= (
        map(.hooks |= ((. // []) | map(select(((.command // "") | contains($m)) | not))))
      | map(select((.hooks // []) | length > 0))
    )
    | if ((.hooks[$e] // []) | length) == 0 then del(.hooks[$e]) else . end
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

# Migration: pre-0.3.0 SessionStart was an inline bash one-liner that
# cat'd handoff_current.md directly. We detect that legacy form (by a
# substring unique to the inline command, not present in the new
# script-call form) and remove it so re-install replaces — not duplicates —
# the hook.
migrate_legacy_ss_hook() {
  local marker="$ss_legacy_marker"
  if ! jq -e --arg m "$marker" \
         '(.hooks.SessionStart // []) | any(.. | .command? // "" | contains($m))' \
         "$settings" >/dev/null 2>&1; then
    return
  fi
  jq --arg m "$marker" '
    .hooks.SessionStart |= (
        map(.hooks |= ((. // []) | map(select(((.command // "") | contains($m)) | not))))
      | map(select((.hooks // []) | length > 0))
    )
    | if ((.hooks.SessionStart // []) | length) == 0 then del(.hooks.SessionStart) else . end
  ' "$settings" > "$settings.tmp"
  mv "$settings.tmp" "$settings"
  echo "  migrate legacy SessionStart inline command removed (pre-0.3.0)"
}

# Pre-0.5.0 the SessionEnd hook called write_handoff.sh with either no
# guard (pre-0.4.1) or with --if-stale-by N (0.4.1 through 0.4.2). Both
# forms are legacy: the new content-check guard is --if-curated. Detect
# any write_handoff.sh hook missing --if-curated and remove it so the
# subsequent maybe_install_hook adds the current command. This single
# detector covers both pre-0.4.1 and pre-0.5.0 forms.
migrate_legacy_se_hook() {
  if ! jq -e \
         '(.hooks.SessionEnd // []) | any(.. | .command? // "" |
            (contains("write_handoff.sh") and (contains("--if-curated") | not)))' \
         "$settings" >/dev/null 2>&1; then
    return
  fi
  jq '
    .hooks.SessionEnd |= (
        map(.hooks |= ((. // []) | map(select(((.command // "") |
            (contains("write_handoff.sh") and (contains("--if-curated") | not))) | not))))
      | map(select((.hooks // []) | length > 0))
    )
    | if ((.hooks.SessionEnd // []) | length) == 0 then del(.hooks.SessionEnd) else . end
  ' "$settings" > "$settings.tmp"
  mv "$settings.tmp" "$settings"
  echo "  migrate legacy SessionEnd command without --if-curated removed (pre-0.5.0)"
}

# Make settings.json safe to patch. Absent or empty -> seed `{}` (jq on empty
# input silently emits nothing, which would blank the file with a false-success
# exit 0). Non-empty but invalid JSON -> refuse to touch it rather than abort
# mid-run or clobber recoverable user config; print the manual snippet instead.
# Returns 0 when the file is valid JSON and safe to patch, 1 to skip patching.
ensure_settings_json() {
  if [[ ! -f "$settings" ]]; then
    echo '{}' > "$settings"
    echo "  new     $settings (created with {})"
    return 0
  fi
  if [[ ! -s "$settings" ]]; then
    echo '{}' > "$settings"
    echo "  init    $settings was empty; set to {}"
    return 0
  fi
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    echo
    echo "  ERROR   $settings is not valid JSON — refusing to auto-patch (left untouched)."
    echo "          Fix or remove it and re-run, or patch settings.json by hand:"
    print_manual_snippet
    return 1
  fi
  return 0
}

patch_settings() {
  if ! command -v jq >/dev/null 2>&1; then
    echo
    echo "jq not found — can't auto-patch $settings."
    print_manual_snippet
    return
  fi
  ensure_settings_json || return
  cp "$settings" "$settings.bak.$ts"
  echo "  backup  $settings -> $settings.bak.$ts"
  # Arm restore-on-abort: from here until the sequence completes, any abort
  # rolls settings.json back to this backup (see cleanup() / the EXIT trap).
  settings_backup="$settings.bak.$ts"
  patch_in_progress=1
  migrate_legacy_ss_hook
  migrate_legacy_se_hook
  maybe_install_hook SessionStart     "$ss_marker" "$ss_cmd"
  maybe_install_hook SessionEnd       "$se_marker" "$se_cmd"
  maybe_install_hook Stop             "$st_marker" "$st_cmd"
  maybe_install_hook UserPromptSubmit "$up_marker" "$up_cmd"
  maybe_install_perm "$perm_write"
  maybe_install_perm "$perm_stop"
  maybe_install_perm "$perm_ctx"
  maybe_install_perm "$perm_ss"
  patch_in_progress=0   # full sequence succeeded; disarm restore-on-abort
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
  if [[ ! -s "$settings" ]]; then
    echo "  ok      $settings is empty; nothing to strip"
    return
  fi
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    echo "  ERROR   $settings is not valid JSON — refusing to edit (left untouched)."
    return
  fi
  cp "$settings" "$settings.bak.$ts"
  echo "  backup  $settings -> $settings.bak.$ts"
  settings_backup="$settings.bak.$ts"
  patch_in_progress=1
  maybe_uninstall_hook SessionStart     "$ss_marker"
  maybe_uninstall_hook SessionStart     "$ss_legacy_marker"
  maybe_uninstall_hook SessionEnd       "$se_marker"
  maybe_uninstall_hook Stop             "$st_marker"
  maybe_uninstall_hook UserPromptSubmit "$up_marker"
  maybe_uninstall_perm "$perm_write"
  maybe_uninstall_perm "$perm_stop"
  maybe_uninstall_perm "$perm_ctx"
  maybe_uninstall_perm "$perm_ss"
  patch_in_progress=0   # full sequence succeeded; disarm restore-on-abort
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
  if [[ "$COPIED_ANY" == "1" ]]; then
    echo
    echo "note: real symlinks weren't available, so files were COPIED into"
    echo "      $claude_home. After a future 'git pull' in this repo, re-run"
    echo "      ./install.sh to refresh the copies — symlinked installs update"
    echo "      automatically, copies do not."
  fi
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
