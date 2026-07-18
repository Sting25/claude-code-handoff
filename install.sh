#!/usr/bin/env bash
# install.sh — wire this repo's handoff skill into ~/.claude/.
#
# What it does:
#   1. Symlinks (or copies, where symlinks aren't available — e.g. Git
#      Bash on Windows) bin/ scripts + skills/* into ~/.claude/.
#   2. Patches ~/.claude/settings.json to add six hooks
#      (SessionStart / SessionEnd / PreCompact / PostCompact / Stop /
#      UserPromptSubmit), six permission entries, and — only when you
#      don't already have one — a statusLine command (never overwrites
#      an existing statusLine; prints the manual step instead).
#      Requires jq; falls back to printing the snippet if jq is missing.
#
# Idempotent. Existing files at symlink targets are backed up to
# <path>.bak.<timestamp> before being replaced. Existing settings.json
# is backed up the same way before any patch. Re-runs are safe and only
# touch what's actually missing.
#
# Installing from a volatile path (a /tmp worktree, git-archive extract, CI
# scratch) auto-switches to copy mode, since symlinks into it would dangle once
# it's cleaned up and the hooks would then fail silently. Override with --link.
#
# Usage:
#   ./install.sh              # install (symlink from a persistent clone, else copy)
#   ./install.sh --copy       # force copy mode (good for ephemeral sources)
#   ./install.sh --link       # force symlinks even from a volatile path
#   ./install.sh --doctor     # report any dangling/missing installed hooks
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
# Include the PID so two installs in the same clock second don't collide on the
# same .bak.<ts> name — without it, the second run's `cp` would overwrite the
# first run's pre-patch settings.json backup, destroying the only safe copy.
ts="$(date +%Y%m%d_%H%M%S)_$$"
mode=install

# Link strategy. "auto" symlinks from a persistent source and copies from a
# volatile one (see is_volatile_path below); --copy / --link force the choice,
# and HANDOFF_FORCE_SYMLINK=1 is an escape hatch for the volatile auto-copy.
link_mode="auto"

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

# If settings.json is a symlink (a common dotfiles pattern — stow/chezmoi/etc.
# point ~/.claude/settings.json at a tracked file), operate on its TARGET. The
# patch writes via tmp+mv, and `mv` onto a symlink replaces the LINK with a plain
# file — silently disconnecting the user's source-of-truth. Resolving to the real
# path keeps tmp+mv atomic AND leaves the symlink intact (Claude Code follows it
# to read). Portable manual resolve (readlink -f is GNU-only), capped against
# loops, falling back to the link path itself.
resolve_symlink() {  # <path> -> physical path on stdout
  local p="$1" n=0 t
  while [[ -L "$p" ]] && (( n++ < 40 )); do
    t="$(readlink "$p")" || break
    case "$t" in
      /*) p="$t" ;;
      *)  p="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)/$t" ;;
    esac
  done
  printf '%s\n' "$p"
}
if [[ -L "$settings" ]]; then
  settings_resolved="$(resolve_symlink "$settings")"
  echo "note: $settings is a symlink -> $settings_resolved; patching the target (symlink left intact)." >&2
  settings="$settings_resolved"
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
    --doctor)    mode=doctor ;;
    --copy)      link_mode=copy ;;
    --link)      link_mode='link' ;;
    --help|-h)
      sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# Canonical hook commands and permissions. Edit these together with
# CHANGELOG.md if you ever change the snippet shape.
# shellcheck disable=SC2016  # $HOME is intentionally literal: the string is stored verbatim in settings.json and expanded when the hook fires, not at install time
{
  ss_cmd='bash $HOME/.claude/bin/handoff_session_start.sh 2>/dev/null || true'
  se_cmd='bash $HOME/.claude/bin/write_handoff.sh --if-curated >/dev/null 2>&1 || true'
  st_cmd='bash $HOME/.claude/bin/handoff_turn_append.sh 2>/dev/null || true'
  up_cmd='bash $HOME/.claude/bin/handoff_ctx_check.sh 2>/dev/null || true'
  # PreCompact reuses the SessionEnd command verbatim (same safety net, same
  # marker for detection/removal): compaction destroys conversational context
  # just like a session ending does — and SessionEnd hooks are skipped on a
  # crash, so the pre-compact checkpoint matters. Installed with NO matcher so
  # it fires on both auto and manual compaction: the matcher field's payload
  # semantics on older CC builds are unverified, and an entry without one is
  # the only shape guaranteed to behave identically everywhere (worst case is
  # firing on both — which is what we want anyway; --if-curated makes it a
  # no-op when curated content exists).
  pc_cmd="$se_cmd"
  # PostCompact: clear the per-session ctx sidecars so the freed window is
  # treated as session-start fresh (stale-high numbers can't nudge, and the
  # once-per-session nudge cap re-arms). Only fires on CC >= 2.1.76.
  post_cmd='bash $HOME/.claude/bin/handoff_compact_reset.sh 2>/dev/null || true'
  # statusLine command. No `|| true` here, unlike the hooks: stdout IS the
  # product (the rendered line), and a nonzero exit just blanks the line — there
  # is no hook pipeline to poison.
  sl_cmd='bash $HOME/.claude/bin/handoff_statusline.sh 2>/dev/null'
}
perm_write="Bash(bash $HOME/.claude/bin/write_handoff.sh)"
perm_stop="Bash(bash $HOME/.claude/bin/handoff_turn_append.sh)"
perm_ctx="Bash(bash $HOME/.claude/bin/handoff_ctx_check.sh)"
perm_ss="Bash(bash $HOME/.claude/bin/handoff_session_start.sh)"
# Consistency with the four above (handoff_session_start already set the
# precedent of allowlisting a hook-only script): harmless if never used.
perm_sl="Bash(bash $HOME/.claude/bin/handoff_statusline.sh)"
perm_reset="Bash(bash $HOME/.claude/bin/handoff_compact_reset.sh)"

# Marker substrings used to detect prior installs (and to remove on uninstall).
# These are the full installed command path (literal $HOME, exactly as stored in
# the command string) — NOT the bare filename — so detection and removal can't
# false-match a user's own unrelated hook that merely mentions the script name
# (e.g. a wrapper called "my_handoff_turn_append.sh"). Every version of this
# installer wrote the command with this path, so the match stays backward-
# compatible. The permission entries already match by exact string.
# shellcheck disable=SC2016  # $HOME / $f are intentionally literal: markers must match the exact stored hook strings, no expansion wanted
{
  ss_marker='$HOME/.claude/bin/handoff_session_start.sh'
  # Legacy marker — pre-0.3.0 SessionStart was an inline bash one-liner that
  # cat'd handoff_current.md directly. We detect it (substring unique to the
  # inline form, not present in the new script-call form) and migrate it out
  # on re-install so users don't end up with both hooks firing.
  ss_legacy_marker='if [ -f "$f" ]; then echo'
  se_marker='$HOME/.claude/bin/write_handoff.sh'
  st_marker='$HOME/.claude/bin/handoff_turn_append.sh'
  up_marker='$HOME/.claude/bin/handoff_ctx_check.sh'
  sl_marker='$HOME/.claude/bin/handoff_statusline.sh'
  post_marker='$HOME/.claude/bin/handoff_compact_reset.sh'
}

# -------------------------------------------------------------------- symlinks

# Set when symlinks aren't available and we fall back to copying, so the
# installer can remind the user that copies don't auto-update on git pull.
COPIED_ANY=0

# A "volatile" repo_root is one likely to be deleted out from under us — a
# /tmp worktree, a `git archive` extract, a CI scratch dir. Symlinking from
# there leaves every ~/.claude/bin/*.sh dangling once it's cleaned up, and the
# hooks then no-op silently (issue #21). Heuristics: under /tmp, /var/tmp,
# /dev/shm, or $TMPDIR; or any path component that looks like an mktemp dir
# (tmp.XXXX). A persistent clone like /mnt/ddrive/handoff matches none of these.
#
# Both the LOGICAL path and its physical (`pwd -P`) form are matched: on macOS
# /tmp and /var are symlinks to /private/tmp and /private/var, so an installer
# invoked via the canonical path (`bash /private/tmp/handoff/install.sh`, or
# any caller that ran the path through realpath) used to sail past the literal
# patterns and get symlink mode — reintroducing the dangling-link failure this
# guard exists to prevent. The /private/* and /var/folders/* spellings (macOS
# per-user temp, i.e. $TMPDIR's real location) are also matched explicitly so
# detection works even when TMPDIR is unset (launchd/cron/CI contexts), and
# TMPDIR itself is compared in both its logical and physical forms.
is_volatile_path() {
  local p="$1" phys cand
  phys="$(cd "$p" 2>/dev/null && pwd -P)" || phys=""
  for cand in "$p" "$phys"; do
    [[ -n "$cand" ]] || continue
    case "$cand" in
      /tmp|/tmp/*|/var/tmp|/var/tmp/*|/dev/shm/*) return 0 ;;
      /private/tmp|/private/tmp/*|/private/var/tmp|/private/var/tmp/*) return 0 ;;
      /var/folders/*|/private/var/folders/*) return 0 ;;
      */tmp.*) return 0 ;;
    esac
  done
  if [[ -n "${TMPDIR:-}" ]]; then
    local t="${TMPDIR%/}" tphys
    tphys="$(cd "$t" 2>/dev/null && pwd -P)" || tphys=""
    for cand in "$t" "$tphys"; do
      [[ -n "$cand" ]] || continue
      if [[ "$p" == "$cand" || "$p" == "$cand"/* \
            || ( -n "$phys" && ( "$phys" == "$cand" || "$phys" == "$cand"/* ) ) ]]; then
        return 0
      fi
    done
  fi
  return 1
}

# Decide symlink vs copy. --copy/--link are explicit; "auto" copies from a
# volatile source (copies survive its cleanup) and symlinks otherwise. The
# volatile auto-copy can be overridden with HANDOFF_FORCE_SYMLINK=1 (or --link).
force_copy=0
case "$link_mode" in
  copy) force_copy=1 ;;
  link) force_copy=0 ;;
  auto)
    if is_volatile_path "$repo_root" && [[ "${HANDOFF_FORCE_SYMLINK:-0}" != "1" ]]; then
      force_copy=1
      echo "warning: installing from a volatile path ($repo_root)." >&2
      echo "         Symlinks would dangle when it's cleaned up and the hooks would" >&2
      echo "         then fail silently — using COPY mode instead (the copies survive)." >&2
      echo "         Re-run from a persistent clone for auto-updating symlinks, or pass" >&2
      echo "         --link / HANDOFF_FORCE_SYMLINK=1 to force symlinks anyway." >&2
    fi
    ;;
esac

link() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [[ -L "$dst" ]]; then
    local current
    current="$(readlink "$dst")"
    if [[ "$current" == "$src" ]] && (( ! force_copy )); then
      echo "  ok      $dst -> $src"
      return
    fi
    # In copy mode, an existing symlink (even one pointing at src) must be
    # replaced by a real copy, so don't early-return above.
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
  # Prefer a real symlink unless copy mode was chosen (volatile source or
  # --copy). Otherwise fall back to copying when the platform can't make one:
  # Git Bash on Windows without Developer Mode either errors on ln -s or
  # silently copies — the -L check catches the silent-copy case too.
  if (( ! force_copy )) && ln -s "$src" "$dst" 2>/dev/null && [[ -L "$dst" ]]; then
    return
  fi
  rm -f "$dst"
  cp "$src" "$dst"
  COPIED_ANY=1
  if (( force_copy )); then
    echo "  copy    $dst (copy mode — re-run install.sh after updates)"
  else
    echo "  copy    $dst (symlinks unavailable — re-run install.sh after updates)"
  fi
}

unlink_if_ours() {
  local dst="$1" src="$2"
  if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then
    rm "$dst"
    echo "  remove  $dst"
  elif [[ -L "$dst" && ! -e "$dst" ]]; then
    # Dangling symlink at our canonical install path — a stale install from a
    # clone that was moved/removed, so its target no longer exists (and may point
    # at a DIFFERENT path than this run's $src, which is why the exact-match
    # branch above misses it). Safe to remove: nothing live sits behind a broken
    # link, and a user would not place their own link here. Without this it was
    # reported "already absent" and left behind. (install#1)
    echo "  remove  $dst (stale dangling link -> $(readlink "$dst"))"
    rm "$dst"
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
  link "$repo_root/bin/handoff_recover_tail.sh"   "$claude_home/bin/handoff_recover_tail.sh"
  link "$repo_root/bin/handoff_statusline.sh"     "$claude_home/bin/handoff_statusline.sh"
  link "$repo_root/bin/handoff_compact_reset.sh"  "$claude_home/bin/handoff_compact_reset.sh"
  link "$repo_root/bin/handoff_provenance.sh"     "$claude_home/bin/handoff_provenance.sh"
  link "$repo_root/skills/handoff/SKILL.md"          "$claude_home/skills/handoff/SKILL.md"
  link "$repo_root/skills/handoff/README.md"         "$claude_home/skills/handoff/README.md"
  link "$repo_root/skills/handoff-more/SKILL.md"     "$claude_home/skills/handoff-more/SKILL.md"
  link "$repo_root/skills/handoff-recover/SKILL.md"  "$claude_home/skills/handoff-recover/SKILL.md"
  # Best-effort: the scripts are committed mode 0755, so a normal checkout is
  # already executable. This rescues filesystems that don't preserve the exec
  # bit (e.g. NTFS). It must never abort the install — under set -e a chmod on
  # source files the running user doesn't own (e.g. a forge user installing
  # from chris-owned files) would otherwise fail and skip patch_settings.
  # (handoff_provenance.sh is deliberately NOT in this list: it is a sourced
  # library, never executed, so it needs no exec bit.)
  chmod +x "$repo_root/bin/write_handoff.sh" \
           "$repo_root/bin/handoff_turn_append.sh" \
           "$repo_root/bin/handoff_ctx_check.sh" \
           "$repo_root/bin/handoff_session_start.sh" \
           "$repo_root/bin/handoff_recover_tail.sh" \
           "$repo_root/bin/handoff_statusline.sh" \
           "$repo_root/bin/handoff_compact_reset.sh" 2>/dev/null || true
}

uninstall_symlinks() {
  unlink_if_ours "$claude_home/bin/write_handoff.sh"          "$repo_root/bin/write_handoff.sh"
  unlink_if_ours "$claude_home/bin/handoff_turn_append.sh"    "$repo_root/bin/handoff_turn_append.sh"
  unlink_if_ours "$claude_home/bin/handoff_ctx_check.sh"      "$repo_root/bin/handoff_ctx_check.sh"
  unlink_if_ours "$claude_home/bin/handoff_session_start.sh"  "$repo_root/bin/handoff_session_start.sh"
  unlink_if_ours "$claude_home/bin/handoff_recover_tail.sh"   "$repo_root/bin/handoff_recover_tail.sh"
  unlink_if_ours "$claude_home/bin/handoff_statusline.sh"     "$repo_root/bin/handoff_statusline.sh"
  unlink_if_ours "$claude_home/bin/handoff_compact_reset.sh"  "$repo_root/bin/handoff_compact_reset.sh"
  unlink_if_ours "$claude_home/bin/handoff_provenance.sh"     "$repo_root/bin/handoff_provenance.sh"
  unlink_if_ours "$claude_home/skills/handoff/SKILL.md"          "$repo_root/skills/handoff/SKILL.md"
  unlink_if_ours "$claude_home/skills/handoff/README.md"         "$repo_root/skills/handoff/README.md"
  unlink_if_ours "$claude_home/skills/handoff-more/SKILL.md"     "$repo_root/skills/handoff-more/SKILL.md"
  unlink_if_ours "$claude_home/skills/handoff-recover/SKILL.md"  "$repo_root/skills/handoff-recover/SKILL.md"
}

# Remove the per-machine HMAC secret that write_handoff.sh generates on first
# signed write (issue #42), so --uninstall is a true inverse and no key
# material is left behind by a tool the user believes they removed.
#
# Deliberately conservative — this is the ONE path where uninstall deletes a
# file the installer never created itself, so it must prove the file is ours
# before touching it. Any doubt => leave it and say so:
#   - only the DEFAULT path under $claude_home. A HANDOFF_SECRET_FILE override
#     may point at a shared/managed location that is not ours to delete.
#   - never a symlink (don't follow it, don't remove it — the target could be
#     anything the user cares about).
#   - only a regular file whose entire content is the exact 64-hex digest we
#     generate. Anything else is someone else's file that happens to sit at
#     that name, and it survives untouched.
# The content is shape-checked, never printed (it is secret material).
remove_secret_if_ours() {
  local secret="$claude_home/handoff_secret" body
  if [[ -n "${HANDOFF_SECRET_FILE:-}" ]]; then
    echo "  skip    handoff secret (HANDOFF_SECRET_FILE override set; leaving '$HANDOFF_SECRET_FILE' alone)"
    return 0
  fi
  if [[ -L "$secret" ]]; then
    echo "  skip    $secret (symlink — not ours to remove; leaving it and its target alone)"
    return 0
  fi
  if [[ ! -e "$secret" ]]; then
    echo "  ok      $secret (already absent)"
    return 0
  fi
  if [[ ! -f "$secret" ]]; then
    echo "  skip    $secret (not a regular file; leaving alone)"
    return 0
  fi
  # Shape check only — 64 lowercase hex, optional trailing newline. Read with
  # tr -d to tolerate the newline our two generators differ on.
  body="$(tr -d '[:space:]' < "$secret" 2>/dev/null || true)"
  if [[ ! "$body" =~ ^[0-9a-f]{64}$ ]]; then
    echo "  skip    $secret (not the shape this tool generates; leaving alone)"
    return 0
  fi
  rm -f "$secret"
  echo "  remove  $secret (per-machine HMAC secret)"
  echo "          Any existing signed handoffs now load as reference data"
  echo "          instead of binding rules — nothing breaks; re-installing"
  echo "          and running /handoff re-signs them with a fresh secret."
}

# ------------------------------------------------------------------ settings.json

print_manual_snippet() {
  cat <<EOF

Paste this into $settings under "hooks" and "permissions":

{
  "hooks": {
    "SessionStart":      [{ "hooks": [{ "type": "command", "command": "$ss_cmd" }] }],
    "SessionEnd":        [{ "hooks": [{ "type": "command", "command": "$se_cmd" }] }],
    "PreCompact":        [{ "hooks": [{ "type": "command", "command": "$pc_cmd" }] }],
    "PostCompact":       [{ "hooks": [{ "type": "command", "command": "$post_cmd" }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "$st_cmd" }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "$up_cmd" }] }]
  },
  "permissions": {
    "allow": [
      "$perm_write",
      "$perm_stop",
      "$perm_ctx",
      "$perm_ss",
      "$perm_sl",
      "$perm_reset"
    ]
  },
  "statusLine": { "type": "command", "command": "$sl_cmd" }
}

NOTE: only add the "statusLine" key if you don't already have a statusLine
set — it is a single slot (not a list like hooks), so pasting it would
replace your existing status line. To keep yours AND get handoff's context
numbers, call our script from your existing statusline command instead.
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

# statusLine is a single settings.json slot (unlike hooks, which are lists we
# can append to), so wiring it must never clobber a user's own setting:
#   - absent/null           -> set ours
#   - present and ours      -> ok (idempotent re-run)
#   - present and NOT ours  -> untouched; print the documented manual step.
maybe_install_statusline() {
  if jq -e '(.statusLine // null) == null' "$settings" >/dev/null 2>&1; then
    jq --arg c "$sl_cmd" '.statusLine = {"type": "command", "command": $c}' \
      "$settings" > "$settings.tmp"
    mv "$settings.tmp" "$settings"
    echo "  add     statusLine"
    return
  fi
  if jq -e --arg m "$sl_marker" '(.statusLine.command // "") | contains($m)' \
       "$settings" >/dev/null 2>&1; then
    echo "  ok      statusLine (already ours)"
    return
  fi
  echo "  skip    statusLine (you already have one — to use handoff's instead, set"
  echo "          \"statusLine\": {\"type\": \"command\", \"command\": \"$sl_cmd\"}"
  echo "          yourself, or call our script from your existing statusline command)"
}

maybe_uninstall_statusline() {
  if jq -e --arg m "$sl_marker" '(.statusLine.command // "") | contains($m)' \
       "$settings" >/dev/null 2>&1; then
    jq 'del(.statusLine)' "$settings" > "$settings.tmp"
    mv "$settings.tmp" "$settings"
    echo "  remove  statusLine"
  elif jq -e '(.statusLine // null) != null' "$settings" >/dev/null 2>&1; then
    echo "  ok      statusLine (not ours; leaving alone)"
  else
    echo "  ok      statusLine (not present)"
  fi
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
  # Valid JSON, but the patch jq programs index it as an object (.hooks //= {},
  # .permissions.allow, …). A valid non-object root ([], 42, "x", true) would
  # otherwise sail past the check above and hit a raw jq runtime error mid-patch
  # (caught by the rollback trap, but ugly and confusing). Refuse it cleanly up
  # front instead. (settings#3)
  if ! jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then
    echo
    echo "  ERROR   $settings is valid JSON but not a JSON object (got: $(jq -r 'type' "$settings" 2>/dev/null))."
    echo "          settings.json must be an object — refusing to auto-patch (left untouched)."
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
  # Marker detection is event-scoped, so PreCompact can safely reuse the
  # SessionEnd marker: each event's hook list is checked independently.
  maybe_install_hook PreCompact       "$se_marker" "$pc_cmd"
  maybe_install_hook PostCompact      "$post_marker" "$post_cmd"
  maybe_install_hook Stop             "$st_marker" "$st_cmd"
  maybe_install_hook UserPromptSubmit "$up_marker" "$up_cmd"
  maybe_install_statusline
  maybe_install_perm "$perm_write"
  maybe_install_perm "$perm_stop"
  maybe_install_perm "$perm_ctx"
  maybe_install_perm "$perm_ss"
  maybe_install_perm "$perm_sl"
  maybe_install_perm "$perm_reset"
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
    echo "  - $se_marker  (both the SessionEnd and PreCompact entries)"
    echo "  - $post_marker"
    echo "  - $st_marker"
    echo "  - $up_marker"
    echo "the \"statusLine\" entry if its command contains:"
    echo "  - $sl_marker"
    echo "and the permission entries:"
    echo "  - $perm_write"
    echo "  - $perm_stop"
    echo "  - $perm_ctx"
    echo "  - $perm_ss"
    echo "  - $perm_sl"
    echo "  - $perm_reset"
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
  maybe_uninstall_hook PreCompact       "$se_marker"
  maybe_uninstall_hook PostCompact      "$post_marker"
  maybe_uninstall_hook Stop             "$st_marker"
  maybe_uninstall_hook UserPromptSubmit "$up_marker"
  maybe_uninstall_statusline
  maybe_uninstall_perm "$perm_write"
  maybe_uninstall_perm "$perm_stop"
  maybe_uninstall_perm "$perm_ctx"
  maybe_uninstall_perm "$perm_ss"
  maybe_uninstall_perm "$perm_sl"
  maybe_uninstall_perm "$perm_reset"
  patch_in_progress=0   # full sequence succeeded; disarm restore-on-abort
  if cmp -s "$settings" "$settings.bak.$ts"; then
    rm "$settings.bak.$ts"
    echo "  ok      no settings.json changes (backup removed)"
  fi
}

# Self-check: verify each installed hook script under $claude_home/bin actually
# resolves. A dangling symlink (e.g. installed from a temp checkout that was
# later cleaned up) makes the corresponding hook no-op silently, so surface it
# loudly here. Exit non-zero if anything is broken so CI / a wrapper can detect
# it. (issue #21)
doctor() {
  local broken=0 dst tgt name
  echo "doctor: checking installed handoff hooks under $claude_home/bin"
  # jq is a RUNTIME dependency of the Stop hook (payload parsing), the ctx
  # nudge, and the /handoff-recover tail rescue — a resolving script link is
  # not enough if the tool it needs is missing (they all no-op silently).
  if ! command -v jq >/dev/null 2>&1; then
    echo "  BROKEN  jq not found on PATH (Stop hook, ctx nudge, and /handoff-recover tail rescue are silently disabled)"
    broken=$((broken + 1))
  fi
  # openssl is an OPTIONAL runtime dependency (HMAC-signing the handoff so its
  # rules layer can load as binding — issue #42). Its absence is a designed
  # degradation, not breakage: everything still works, the rules just load as
  # reference data. Advisory note only; never counts toward broken.
  if ! command -v openssl >/dev/null 2>&1; then
    echo "  note    openssl not found on PATH (optional): handoffs won't be"
    echo "          HMAC-signed, so the rules/pinned layer loads as reference"
    echo "          data instead of binding rules. Install openssl to enable."
  fi
  for name in write_handoff handoff_turn_append handoff_ctx_check handoff_session_start handoff_statusline handoff_compact_reset handoff_provenance; do
    dst="$claude_home/bin/$name.sh"
    if [[ -e "$dst" ]]; then
      if [[ -L "$dst" ]]; then
        echo "  ok      $dst -> $(readlink "$dst")"
      else
        echo "  ok      $dst (copy)"
      fi
    elif [[ -L "$dst" ]]; then
      tgt="$(readlink "$dst" 2>/dev/null || true)"
      echo "  BROKEN  $dst -> $tgt (dangling symlink — hook is silently disabled)"
      broken=$((broken + 1))
    else
      echo "  MISSING $dst (not installed)"
      broken=$((broken + 1))
    fi
  done
  echo
  # statusLine wiring report — informational only, never counts toward
  # `broken`: an unwired or user-owned statusLine is a legitimate state (we
  # never overwrite a user's own setting), not a fault. Only a dangling
  # SCRIPT (reported by the loop above) is real breakage.
  if command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]]; then
    if jq -e --arg m "$sl_marker" '(.statusLine.command // "") | contains($m)' \
         "$settings" >/dev/null 2>&1; then
      echo "  ok      statusLine wired (ours)"
    elif jq -e '(.statusLine // null) != null' "$settings" >/dev/null 2>&1; then
      echo "  info    statusLine present (user's own — manual wiring documented in README)"
    else
      echo "  info    statusLine unset (re-run ./install.sh to wire it)"
    fi
    echo
  fi
  if (( broken )); then
    echo "doctor: $broken hook(s) broken or missing." >&2
    echo "        Re-run ./install.sh from a persistent clone (not a /tmp checkout)." >&2
    return 1
  fi
  echo "doctor: all hooks resolve."
}

# ------------------------------------------------------------------------ main

if [[ "$mode" == doctor ]]; then
  doctor
elif [[ "$mode" == install ]]; then
  # jq is a hard RUNTIME dependency, not just an install-time convenience:
  # without it the Stop hook exits before writing anything (no raw dumps, no
  # ctx measurements), the ctx nudge never fires, and /handoff-recover's tail
  # rescue can't parse the transcript — all silently, because the hooks are
  # wired '... || true'. Installing anyway would print "done" and ship a
  # system that never runs. Refuse up front instead. (--uninstall and --doctor
  # still work without jq.)
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq not found on PATH — refusing to install." >&2
    echo "  jq is required at runtime by the Stop hook (raw per-turn dumps)," >&2
    echo "  the context nudge, and /handoff-recover; without it they all no-op" >&2
    echo "  silently. Install jq (e.g. 'apt install jq' / 'brew install jq')" >&2
    echo "  and re-run ./install.sh." >&2
    exit 1
  fi
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
    echo "note: files were COPIED into $claude_home (copy mode or symlinks"
    echo "      unavailable). After a future 'git pull' in this repo, re-run"
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
  echo "local state:"
  remove_secret_if_ours
  echo
  echo "done. the repo at $repo_root is untouched."
fi
