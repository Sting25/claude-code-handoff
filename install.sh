#!/usr/bin/env bash
# GENERATED FILE — do not edit directly.
#
# This is the concatenation of install.d/*.sh, produced by
# tools/build-install.sh. To change installer behavior, edit the relevant
# module under install.d/, then regenerate with:
#
#   bash tools/build-install.sh
#
# CI's install-drift job rebuilds this file into a temp path and diffs it
# against the committed copy below; a stale install.sh fails that gate.
# SOURCE-SHA256: d774cfc352ea489bcf71e8d742a1c88b28eb5c814d31de0ef9edc104760e92ea
# install.sh — wire this repo's handoff skill into ~/.claude/.
#
# Full behavior/usage summary lives in usage() below — that heredoc is the
# single source of truth for `install.sh --help`, so it stays in sync with
# reality by construction instead of by discipline. Read it there, or just
# run `./install.sh --help`.

set -euo pipefail

# Usage text for --help / -h. A heredoc (not a self-read of this file's
# comments) so it works no matter how the script's bytes arrived: piped in
# via `curl ... | bash -s -- --help`
# — BASH_SOURCE[0] is "bash" (there is no real path to sed), so a self-read
# prints nothing. A heredoc is parsed out of the script text itself and
# needs no path or working stdin.
usage() {
  cat <<'USAGE'
install.sh — wire this repo's handoff skill into ~/.claude/.

What it does:
  1. Symlinks (or copies, where symlinks aren't available — e.g. Git
     Bash on Windows) bin/ scripts + skills/* into ~/.claude/.
  2. Patches ~/.claude/settings.json to add six hooks
     (SessionStart / SessionEnd / PreCompact / PostCompact / Stop /
     UserPromptSubmit), six permission entries, and — only when you
     don't already have one — a statusLine command (never overwrites
     an existing statusLine; prints the manual step instead).
     Requires jq; falls back to printing the snippet if jq is missing.

Idempotent. Existing files at symlink targets are backed up to
<path>.bak.<timestamp> before being replaced. Existing settings.json
is backed up the same way before any patch. Re-runs are safe and only
touch what's actually missing.

Installing from a volatile path (a /tmp worktree, git-archive extract, CI
scratch) auto-switches to copy mode, since symlinks into it would dangle once
it's cleaned up and the hooks would then fail silently. Override with --link.

Usage:
  ./install.sh              # install (symlink from a persistent clone, else copy)
  ./install.sh --copy       # force copy mode (good for ephemeral sources)
  ./install.sh --link       # force symlinks even from a volatile path
  ./install.sh --model 'opus[1m]'  # also pin "model" in settings.json (env: HANDOFF_MODEL)
  ./install.sh --doctor     # report any dangling/missing installed hooks
  ./install.sh --uninstall  # remove symlinks + strip patched entries
  ./install.sh --uninstall --keep-secret  # same, but keep the per-machine HMAC secret
  ./install.sh --help
USAGE
}

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

# Optional model pin (--model / HANDOFF_MODEL, flag wins). Opaque string,
# passed through verbatim — never validated against a model list, and never
# defaulted: this repo is installed by other people too, so the pin is always
# explicit user input. Empty means "no pin requested".
model_pin=""

# Link strategy. "auto" symlinks from a persistent source and copies from a
# volatile one (see is_volatile_path below); --copy / --link force the choice,
# and HANDOFF_FORCE_SYMLINK=1 is an escape hatch for the volatile auto-copy.
link_mode="auto"

# --uninstall --keep-secret (issue #65): preserve the per-machine HMAC secret
# instead of deleting it. Only consulted by remove_secret_if_ours() in
# install mode "uninstall" (harmless, and unused, with any other mode). The
# secret is per-machine identity, not per-install-mode state: a user moving
# from bare-scripts to the plugin (the README's own recommended migration,
# via the dual-mode warning) runs --uninstall first, and without this flag
# that silently invalidates every already-signed handoff_current.md: the
# HANDOFF_BIND_BEGIN/END rules block stops verifying and downgrades to
# reference data with no error, no prompt, nothing in the diff. Default stays
# "delete" (unchanged, opt-in only) because the secret is also genuinely
# uninstall-scoped key material for someone leaving the tool entirely.
keep_secret=0

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
# NOT armed here. A piped `curl | bash` executes top-level statements as they
# parse, and on bash 3.2 a stream that truncates AFTER `trap ... EXIT` is
# armed exits 0 on the resulting syntax error (set -e + EXIT trap swallow the
# parse-error status; the trap sees $? = 0, so re-raising doesn't help).
# Arming instead as the first statement of the dispatch group in 40-main.sh
# means the trap only takes effect once that whole compound has parsed —
# truncation anywhere inside it dies with bash's own rc=2, and no work
# (so nothing needing cleanup) can have run before the trap is live.

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall)   mode=uninstall ;;
    --doctor)      mode=doctor ;;
    --copy)        link_mode=copy ;;
    --link)        link_mode='link' ;;
    --keep-secret) keep_secret=1 ;;
    --model)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "ERROR: --model requires a value (e.g. --model 'opus[1m]')" >&2
        exit 2
      fi
      model_pin="$2"; shift ;;
    --model=*)   model_pin="${1#--model=}" ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# Env fallback for the model pin; an explicit --model flag wins.
if [[ -z "$model_pin" && -n "${HANDOFF_MODEL:-}" ]]; then
  model_pin="$HANDOFF_MODEL"
fi

# Where a model pin WE wrote is recorded, so --uninstall can be an exact
# inverse: the key is removed only when this installer set it AND the value
# is still exactly what it set — a user's later edit always wins.
model_pin_record="$claude_home/handoff-model-pin"

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

# Append a durable record of a symlink we replaced that pointed somewhere the
# user chose, so their original wiring can always be recovered. (#45)
#
# Append-only by contract: if the log already exists we ADD a line and never
# rewrite or truncate it — the file may hold records from earlier installs the
# user still needs, and it is not ours to prune. A fresh file is created 0600
# (it records paths from the user's home). Best-effort throughout: a failure to
# write the log must never abort an install, so every step is guarded and the
# old target is still echoed to stdout as before.
record_replaced_link() {  # <dst> <old_target>
  local dst="$1" old="$2" log="$claude_home/handoff-install.log" existed=1
  [[ -e "$log" ]] || existed=0
  # Never write through a symlinked log (it could point at a file of theirs).
  if [[ -L "$log" ]]; then
    echo "          (note: $log is a symlink; not recording the old target there)"
    return 0
  fi
  if printf '%s\treplaced symlink %s\n\t\twas -> %s\n' \
       "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$dst" "$old" >> "$log" 2>/dev/null; then
    (( existed )) || chmod 600 "$log" 2>/dev/null || true
    echo "          recorded old target in $log"
  else
    echo "          (note: could not write $log; old target above is the only record)"
  fi
  return 0
}

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
    # A symlink pointing SOMEWHERE ELSE is the user's own wiring (a customized
    # fork, a second clone, a dotfiles manager). A regular file in that position
    # gets a .bak.<ts>; a symlink used to be removed with the old target
    # recorded only on stdout — gone the moment that scrolled past, or
    # immediately if the installer ran with output redirected. Append a durable
    # note first so the wiring is always recoverable. Same-target relinks (the
    # ordinary copy-mode case) record nothing. (#45)
    if [[ "$current" != "$src" ]]; then
      record_replaced_link "$dst" "$current"
    fi
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
  # Tidy up now-empty leaf dirs we created. `rmdir` only removes a directory
  # that is ALREADY empty (fails harmlessly otherwise) — never `rm -r` — so
  # this can never touch a dir the user left files in (their own script
  # dropped alongside ours, a co-located skill, etc.). Order matters: each
  # skills/<name>/ dir first, then skills/ itself (which only empties out
  # once its subdirs are gone), then bin/. Best-effort and silent: rmdir's
  # own semantics ("empty or untouched") already say everything worth saying.
  local d
  for d in "$claude_home/skills/handoff" "$claude_home/skills/handoff-more" \
           "$claude_home/skills/handoff-recover" "$claude_home/skills" \
           "$claude_home/bin"; do
    rmdir "$d" 2>/dev/null || true
  done
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
  # The path this run actually reads/writes: HANDOFF_SECRET_FILE if set,
  # otherwise the default. The --keep-secret messages below name THIS path,
  # not the bare default, so a HANDOFF_SECRET_FILE override is reported
  # accurately instead of pointing at a file that was never in play (#82).
  local effective="${HANDOFF_SECRET_FILE:-$secret}"
  # --keep-secret (issue #65): skip the deletion entirely and say so. The
  # secret is per-machine identity, not per-install-mode state, so a user
  # switching from bare-scripts to the plugin (the README's own migration
  # path, via the dual-mode warning) can carry it forward and keep every
  # already-signed handoff_current.md verifying instead of it silently
  # downgrading to reference data. Checked before every other guard below:
  # keeping the file needs none of the shape/ownership proof that deleting
  # it does.
  if (( keep_secret )); then
    # Nothing to keep: don't claim to have preserved a secret that was
    # never generated (#82): a fresh machine or a --keep-secret run before
    # any signed write would otherwise print a misleading "preserving" line
    # for a file that doesn't exist.
    if [[ ! -e "$effective" ]]; then
      echo "  ok      $effective (--keep-secret; no secret file there; nothing to keep)"
      return 0
    fi
    echo "  skip    $effective (--keep-secret; preserving the per-machine HMAC secret)"
    if [[ -n "${HANDOFF_SECRET_FILE:-}" ]]; then
      echo "          Existing signed handoffs keep verifying. HANDOFF_SECRET_FILE points"
      echo "          here, so both install modes will keep reading it from this path."
    else
      echo "          Existing signed handoffs keep verifying. Both install modes read"
      echo "          this same default path, so it needs no copying: it's already"
      echo "          where the plugin install will find it."
    fi
    return 0
  fi
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

# Install $settings.tmp over $settings — the ONE place every maybe_install_*/
# maybe_uninstall_*/migrate_* function below lands its jq output, instead of
# each calling `mv` directly. ensure_settings_json validates $settings once,
# up front, but every one of these functions re-reads whatever the PREVIOUS
# step's `mv` just installed — so that one up-front check does not cover the
# rest of the chain. jq on empty/unreadable input still exits 0 and prints
# nothing (a crashed jq, a disk full mid-write, anything that truncates the
# pipe): a bare `mv` of that nothing would blank settings.json with a
# false-success exit code, and because rc==0 the EXIT trap's rollback (see
# cleanup() near the top of the file) would never fire — the script would
# print "done" over a wiped config. handoff_statusline.sh's write_cache
# already guards precisely this pattern ("never install the tmp unless printf
# succeeded") for a far less valuable file; this is the same discipline
# applied to the one file every hook depends on.
#
# Every call site here runs inside patch_settings() or unpatch_settings(),
# which arm patch_in_progress and take the pre-patch backup BEFORE calling
# any of these — so `exit 1` on a bad tmp both aborts the run AND is the
# rollback: cleanup() sees patch_in_progress=1 and a non-zero rc and restores
# $settings from $settings_backup. No caller needs to check a return value.
commit_settings_tmp() {
  if [[ ! -s "$settings.tmp" ]] || ! jq -e . "$settings.tmp" >/dev/null 2>&1; then
    echo "  ERROR   jq produced empty or invalid JSON while patching $settings — aborting." >&2
    echo "          $settings is unmodified; restoring from the pre-patch backup." >&2
    exit 1
  fi
  mv "$settings.tmp" "$settings"
}

# Install-or-reconcile one hook. Three cases per event:
#   - marker absent            -> append the canonical command (fresh install)
#   - marker present, current  -> ok (idempotent re-run)
#   - marker present, STALE    -> rewrite it in place to the canonical command,
#     printing the old form loudly. The marker matches any release's variant of
#     our command (it is just the script path), so when a release changes the
#     arguments/redirects around that path, the old wiring would otherwise pass
#     the "already present" check forever. Rewriting here makes the install
#     self-healing — no bespoke migrate_* function per argument change (this
#     subsumed the former migrate_legacy_se_hook; migrate_legacy_ss_hook must
#     stay because the pre-0.3.0 inline form does not contain the script path).
#     Never a silent skip and never a silent clobber: the old form is printed
#     and lives in the settings.json backup made at the top of patch_settings.
#     Comparison is against THIS event's canonical $cmd — events may share a
#     marker (SessionEnd/PreCompact both use write_handoff.sh) but each call
#     reconciles only its own event's list against its own command.
maybe_install_hook() {
  local event="$1" marker="$2" cmd="$3"
  if jq -e --arg e "$event" --arg m "$marker" \
       '(.hooks[$e] // []) | any(.. | .command? // "" | contains($m))' \
       "$settings" >/dev/null 2>&1; then
    local stale
    stale="$(jq -r --arg e "$event" --arg m "$marker" --arg c "$cmd" \
      '(.hooks[$e] // []) | [.. | .command? // "" | select(contains($m) and . != $c)] | .[]' \
      "$settings" 2>/dev/null)"
    if [[ -z "$stale" ]]; then
      echo "  ok      hook $event (already present)"
      return
    fi
    # Rewrite every stale marker-match to the canonical command, then drop
    # exact duplicates of the canonical beyond the first (covers a config that
    # somehow held both a stale AND a current entry — rewriting alone would
    # leave two identical hooks firing twice). Groups that empty out are
    # removed; a user's own co-located command in the same group is untouched.
    jq --arg e "$event" --arg m "$marker" --arg c "$cmd" '
      .hooks[$e] |= (
          map(.hooks |= ((. // []) | map(
            if ((.command // "") | contains($m)) then .command = $c else . end)))
        | delpaths([paths(objects and ((.command? // "") == $c))][1:])
        | map(select((.hooks // []) | length > 0))
      )
    ' "$settings" > "$settings.tmp"
    commit_settings_tmp
    echo "  UPDATE  hook $event — stale command from an older install rewritten:"
    while IFS= read -r _old; do
      echo "          old: $_old"
    done <<< "$stale"
    echo "          new: $cmd"
    echo "          (old form also preserved in the settings.json backup above)"
    return
  fi
  jq --arg e "$event" --arg c "$cmd" '
    .hooks //= {}
    | .hooks[$e] = ((.hooks[$e] // []) + [{"hooks": [{"type": "command", "command": $c}]}])
  ' "$settings" > "$settings.tmp"
  commit_settings_tmp
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
  commit_settings_tmp
  echo "  add     permission: $perm"
}

# Optional model pin. Never overwrites an existing "model" key: a machine
# where the user already chose a model keeps that choice, and the differing
# request is reported instead of applied. A write is recorded in
# $model_pin_record (0600 via umask) so --uninstall can undo exactly ours.
maybe_install_model() {
  [[ -n "$model_pin" ]] || return 0
  local cur
  cur="$(jq -r '.model // ""' "$settings" 2>/dev/null)"
  if [[ -z "$cur" ]]; then
    jq --arg m "$model_pin" '.model = $m' "$settings" > "$settings.tmp"
    commit_settings_tmp
    printf '%s\n' "$model_pin" > "$model_pin_record"
    echo "  add     model: $model_pin (recorded for uninstall)"
  elif [[ "$cur" == "$model_pin" ]]; then
    echo "  ok      model already set: $cur"
  else
    echo "  keep    model '$cur' (your existing choice preserved — NOT overwriting"
    echo "          with requested '$model_pin'; edit settings.json yourself to change it)"
  fi
}

maybe_uninstall_model() {
  if [[ ! -f "$model_pin_record" || -L "$model_pin_record" ]]; then
    echo "  ok      model (not pinned by this installer)"
    return 0
  fi
  local rec cur
  rec="$(tr -d '[:space:]' < "$model_pin_record" 2>/dev/null || true)"
  cur="$(jq -r '.model // ""' "$settings" 2>/dev/null)"
  if [[ -n "$rec" && "$cur" == "$rec" ]]; then
    jq 'del(.model)' "$settings" > "$settings.tmp"
    commit_settings_tmp
    echo "  remove  model: $rec (this installer set it, unchanged since)"
  else
    echo "  keep    model '$cur' (differs from the recorded pin '$rec' — you changed"
    echo "          it since install; leaving your value alone)"
  fi
  rm -f "$model_pin_record"
}

# statusLine is a single settings.json slot (unlike hooks, which are lists we
# can append to), so wiring it must never clobber a user's own setting:
#   - absent/null            -> set ours
#   - present, ours, current -> ok (idempotent re-run)
#   - present, ours, STALE   -> rewrite the command to canonical, printing the
#     old form (same self-healing rule as maybe_install_hook: the marker only
#     proves it is our script, not that the args/redirects are this release's).
#     Only .command is replaced so any sibling keys the user added (e.g.
#     "padding") survive.
#   - present and NOT ours   -> untouched; print the documented manual step.
maybe_install_statusline() {
  if jq -e '(.statusLine // null) == null' "$settings" >/dev/null 2>&1; then
    jq --arg c "$sl_cmd" '.statusLine = {"type": "command", "command": $c}' \
      "$settings" > "$settings.tmp"
    commit_settings_tmp
    echo "  add     statusLine"
    return
  fi
  if jq -e --arg m "$sl_marker" '(.statusLine.command // "") | contains($m)' \
       "$settings" >/dev/null 2>&1; then
    local cur_sl
    cur_sl="$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null)"
    if [[ "$cur_sl" == "$sl_cmd" ]]; then
      echo "  ok      statusLine (already ours)"
      return
    fi
    jq --arg c "$sl_cmd" '.statusLine.command = $c' "$settings" > "$settings.tmp"
    commit_settings_tmp
    echo "  UPDATE  statusLine — stale command from an older install rewritten:"
    echo "          old: $cur_sl"
    echo "          new: $sl_cmd"
    echo "          (old form also preserved in the settings.json backup above)"
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
    commit_settings_tmp
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
  commit_settings_tmp
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
  commit_settings_tmp
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
  commit_settings_tmp
  echo "  migrate legacy SessionStart inline command removed (pre-0.3.0)"
}

# (The former migrate_legacy_se_hook — pre-0.5.0 SessionEnd forms missing
# --if-curated — is gone: those commands contain the script-path marker, so
# maybe_install_hook's stale-command reconcile now rewrites them generically.
# migrate_legacy_ss_hook above must stay: the pre-0.3.0 inline form has no
# script path in it, so the marker can't find it.)

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
  maybe_install_model
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
    echo "and, if you used --model, the top-level \"model\" key (the value this"
    echo "installer wrote, if any, is recorded in $model_pin_record)."
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
  maybe_uninstall_model
  patch_in_progress=0   # full sequence succeeded; disarm restore-on-abort
  if cmp -s "$settings" "$settings.bak.$ts"; then
    rm "$settings.bak.$ts"
    echo "  ok      no settings.json changes (backup removed)"
  fi
}

# Locate an installed plugin form of this tool (v0.14.0+ ships one), if any.
# Plugin installs live under $CLAUDE_CONFIG_DIR/plugins/cache/<marketplace>/
# claude-code-handoff/<version>/, falling back to $HOME/.claude when
# CLAUDE_CONFIG_DIR is unset — that's Claude Code's OWN env var for where it
# keeps its config/cache, unrelated to this installer's CLAUDE_HOME
# convention. NOTE: this is never under a CLAUDE_HOME override — the plugin
# loader has no concept of this installer's CLAUDE_HOME convention, only of
# Claude Code's own CLAUDE_CONFIG_DIR. Bash 3.2 has no nullglob, so a
# non-matching glob expands to its own literal (unexpanded) pattern text; the
# `-d` test below simply never passes for that literal string, which is what
# makes this safe without nullglob or an array/compgen dependency. Echoes the
# first matching directory on stdout and returns 0, or returns 1 if none.
find_plugin_cache_dir() {
  local pd
  for pd in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/*/claude-code-handoff; do
    if [[ -d "$pd" ]]; then
      printf '%s\n' "$pd"
      return 0
    fi
  done
  return 1
}

# Single source of truth for "will the next handoff be HMAC-signed" — reused
# by doctor() (detailed per-item report, below) and the installer's
# first-run summary (install.d/40-main.sh). Mirrors the EXACT preconditions
# bin/handoff_provenance.sh's handoff_mac_compute checks, in the same order
# it checks them:
#   1. openssl on PATH — handoff_mac_compute's very first line
#      (`command -v openssl >/dev/null 2>&1 || return 1`); required for every
#      call regardless of secret state, since HMAC-SHA256 is built from two
#      openssl digest passes. No openssl => degraded, full stop.
#   2. the secret file (handoff_secret_path: $HANDOFF_SECRET_FILE, else
#      $claude_home/handoff_secret) must be usable: not a symlink (the
#      signer refuses one outright — handoff_ensure_secret/handoff_mac_compute
#      both `return 1`), and — for an EXISTING path — a regular, non-empty
#      file (handoff_mac_compute's verify branch requires `-f` AND `-s`;
#      `key="$(cat "$sf")"` then `[ -n "$key" ]` guards the empty case again).
#      A path that exists but isn't a regular file can't be read as a key.
#   3. absent entirely is NOT degraded: handoff_ensure_secret mints one
#      lazily on the first signed write (openssl rand, or /dev/urandom via od
#      as fallback) — reported as its own distinct state, not lumped with
#      "active" or "degraded", since nothing has actually signed yet.
# Echoes one of: "active", "degraded: <reason>", or
# "pending: <reason>" (not yet signed, but will self-heal on first write).
# Never touches `broken` — callers decide what (if anything) that means.
signing_status_reason() {
  local secret="${HANDOFF_SECRET_FILE:-$claude_home/handoff_secret}"
  if ! command -v openssl >/dev/null 2>&1; then
    echo "degraded: openssl not found on PATH"
  elif [[ -L "$secret" ]]; then
    echo "degraded: secret file ($secret) is a symlink — the signer refuses it"
  elif [[ -f "$secret" ]]; then
    # Probe with the signer's own load, not -s: handoff_mac_compute requires
    # `cat` to succeed AND the key to be non-empty after $() strips trailing
    # newlines, so an unreadable or newline-only secret passed -f/-s here
    # ("active") while every write silently degraded to unsigned. The probe
    # runs in a subshell and prints nothing — key bytes never reach output
    # or this shell's state.
    if ( k="$(cat "$secret" 2>/dev/null)" && [ -n "$k" ] ); then
      echo "active"
    elif [[ ! -r "$secret" ]]; then
      echo "degraded: secret file ($secret) is not readable by this user"
    else
      echo "degraded: secret file ($secret) is empty"
    fi
  elif [[ -e "$secret" ]]; then
    echo "degraded: secret path ($secret) exists but is not a regular file"
  else
    echo "pending: no secret yet — one is generated on the first signed write"
  fi
}

# Self-check: verify each installed hook script under $claude_home/bin actually
# resolves. A dangling symlink (e.g. installed from a temp checkout that was
# later cleaned up) makes the corresponding hook no-op silently, so surface it
# loudly here. Exit non-zero if anything is broken so CI / a wrapper can detect
# it. (issue #21)
#
# Plugin-mode awareness (issues #64, #70): a plugin-only machine has none of
# this installer's bin/ scripts or settings.json hooks by design (the plugin
# ships its own hooks/hooks.json and runs from its own cache copy), so the
# bare-scripts per-script loop below does not apply there. Reporting those
# eight scripts as MISSING on a healthy plugin-only machine was issue #64: the
# verdict contradicted the diagnosis, and the "re-run ./install.sh" remedy is
# exactly the action that creates a second, parallel bare-scripts install
# alongside the plugin (every hook then fires twice, see the coexistence
# check further down). `plugin_only` below gates both: skip the per-script
# loop and its MISSING lines, and never suggest ./install.sh in the closing
# remedy, when a plugin cache is present and no bare-scripts artifact is.
doctor() {
  local broken=0 dst tgt name mdl secret smode sign_reason
  local plugin_dir bare_wired plugin_only script_hooks_present dangling_list
  local vdir vcount hooks_json missing_scripts events_str expected_events
  local missing_events extra_events ev rest

  # Plugin cache detection lives up front now (used by several sections
  # below), via the `|| true` idiom already used elsewhere in this file so a
  # "not found" result can't trip `set -e` (find_plugin_cache_dir returns 1
  # when there's no cache; that's a normal, expected outcome, not an error).
  plugin_dir="$(find_plugin_cache_dir || true)"

  echo "doctor: checking runtime dependencies"
  # jq is a RUNTIME dependency of the Stop hook (payload parsing), the ctx
  # nudge, and the /handoff-recover tail rescue — a resolving script link is
  # not enough if the tool it needs is missing (they all no-op silently).
  # Mode-neutral: this fires the same way whether the six hooks came from
  # bare-scripts settings.json entries or the plugin's own hooks.json, since
  # both invoke the same scripts under the hood (issue #70's "jq" note).
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
  echo

  # bare_wired: is there a REAL bare-scripts install, not just leftover
  # cruft? Either a hook wired into settings.json, or at least one bin/
  # script that actually resolves. `-e` alone (not `-e || -L`) is
  # deliberate: for a symlink it follows the link and requires the target to
  # exist, so a lone DANGLING symlink does not flip this true on its own.
  # Before this fix, any one of the eight paths existing (dangling or not)
  # was enough, so a plugin-only machine with a single stale dangling
  # `write_handoff.sh` left behind by a hand-removed bare install got
  # dragged into the per-script loop below and reported the other seven as
  # MISSING, restoring issue #64's exact bug. Dangling remnants are real and
  # worth naming, so they're collected separately (dangling_list) and
  # reported as one WARN instead of feeding this check.
  bare_wired=0
  for name in write_handoff handoff_turn_append handoff_ctx_check handoff_session_start handoff_recover_tail handoff_statusline handoff_compact_reset handoff_provenance; do
    dst="$claude_home/bin/$name.sh"
    if [[ -e "$dst" ]]; then
      bare_wired=1
      break
    fi
  done
  if (( ! bare_wired )) && command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]]; then
    if jq -e --arg ss "$ss_marker" --arg se "$se_marker" --arg post "$post_marker" \
           --arg st "$st_marker" --arg up "$up_marker" '
         ( (.hooks.SessionStart // [])     | any(.. | .command? // "" | contains($ss)) ) or
         ( (.hooks.SessionEnd // [])       | any(.. | .command? // "" | contains($se)) ) or
         ( (.hooks.PreCompact // [])       | any(.. | .command? // "" | contains($se)) ) or
         ( (.hooks.PostCompact // [])      | any(.. | .command? // "" | contains($post)) ) or
         ( (.hooks.Stop // [])             | any(.. | .command? // "" | contains($st)) ) or
         ( (.hooks.UserPromptSubmit // []) | any(.. | .command? // "" | contains($up)) )
       ' "$settings" >/dev/null 2>&1; then
      bare_wired=1
    fi
  fi

  # Collect any dangling-only leftovers regardless of bare_wired: a symlink
  # whose target is gone is real breakage worth naming even on a healthy
  # plugin-only machine, just not evidence of a wired bare-scripts install.
  dangling_list=""
  for name in write_handoff handoff_turn_append handoff_ctx_check handoff_session_start handoff_recover_tail handoff_statusline handoff_compact_reset handoff_provenance; do
    dst="$claude_home/bin/$name.sh"
    if [[ -L "$dst" && ! -e "$dst" ]]; then
      dangling_list="$dangling_list $dst"
    fi
  done

  plugin_only=0
  if [[ -n "$plugin_dir" ]] && (( ! bare_wired )); then
    plugin_only=1
  fi

  if (( plugin_only )); then
    echo "doctor: no bare-scripts install found under $claude_home/bin, skipping"
    echo "        the per-script hook checks (this installer's own scripts were"
    echo "        never installed here). See the plugin section below."
    if [[ -n "$dangling_list" ]]; then
      echo "  WARN    stale bare-scripts artifact(s) found, but no bare-scripts"
      echo "          install is actually wired:$dangling_list"
      echo "          Dangling symlink(s) left over from a removed install; they"
      echo "          don't affect the plugin. Safe to remove: rm$dangling_list"
    fi
  else
    echo "doctor: checking installed handoff hooks under $claude_home/bin"
    for name in write_handoff handoff_turn_append handoff_ctx_check handoff_session_start handoff_recover_tail handoff_statusline handoff_compact_reset handoff_provenance; do
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
  fi
  echo
  # Secret-file hygiene. The per-machine HMAC secret is what makes a
  # handoff's rules layer load as BINDING (issue #42): group/other-readable,
  # any local reader can forge the trailer; a symlink at the path could be
  # planted to point key generation somewhere attacker-readable (the signer
  # refuses it, silently degrading to unsigned). Same effective path as the
  # runtime and remove_secret_if_ours: the HANDOFF_SECRET_FILE override wins
  # over the default under $claude_home — doctor is read-only, so unlike
  # uninstall it can safely inspect an overridden location. Absent is NOT an
  # error: the secret is minted lazily on the first signed write.
  secret="${HANDOFF_SECRET_FILE:-$claude_home/handoff_secret}"
  if [[ -L "$secret" ]]; then
    echo "  BROKEN  $secret is a symlink (possibly planted) — the signer refuses it;"
    echo "          remove the link: rm '$secret' (a fresh secret is generated on the next signed write)"
    broken=$((broken + 1))
  elif [[ -f "$secret" ]]; then
    # Portable mode read: GNU stat -c %a with BSD stat -f %Lp fallback.
    smode="$(stat -c %a "$secret" 2>/dev/null || stat -f %Lp "$secret" 2>/dev/null)" || smode=""
    if [[ "$smode" =~ ^[0-7]+$ ]] && (( 8#$smode & 8#77 )); then
      echo "  BROKEN  $secret is group/other-readable (mode $smode) — the HMAC key is"
      echo "          exposed to other local users; run: chmod 600 '$secret'"
      broken=$((broken + 1))
    else
      echo "  ok      $secret (regular file, mode ${smode:-unreadable}, no group/other access)"
    fi
  elif [[ -e "$secret" ]]; then
    # Exists but is not a regular file (directory, fifo, ...): the signer
    # can't use it, so signing is silently disabled — that's breakage.
    echo "  BROKEN  $secret exists but is not a regular file — signing is silently disabled"
    broken=$((broken + 1))
  else
    echo "  note    $secret absent — generated on first signed write (not an error)"
  fi
  # Signing status — one-line summary answering "will the next handoff be
  # HMAC-signed", consolidating the openssl/secret checks above (which say
  # WHY per-artifact) into the single yes/no-and-why question a user actually
  # asks. Never counts toward `broken` itself — the checks above already
  # flip that for cases the signer can't recover from (a symlinked or
  # non-regular secret); this line would just double-count them.
  sign_reason="$(signing_status_reason)"
  case "$sign_reason" in
    active)
      echo "  ok      handoff signing: active"
      ;;
    degraded:*)
      echo "  note    handoff signing: ${sign_reason#degraded: }"
      ;;
    pending:*)
      echo "  note    handoff signing: ${sign_reason#pending: }"
      ;;
  esac
  echo
  # statusLine wiring report — informational only, never counts toward
  # `broken`: an unwired or user-owned statusLine is a legitimate state (we
  # never overwrite a user's own setting), not a fault. Only a dangling
  # SCRIPT (reported by the loop above) is real breakage.
  #
  # A genuinely plugin-only machine (#64, #70) may never have a settings.json
  # at all, this installer never created one and the plugin doesn't need it
  # for anything BUT statusLine. Report "unset" for that case too instead of
  # silently saying nothing: in plugin mode statusLine is the only accurate
  # context signal there is (docs/plugin-mode-context-watching-report.md),
  # so its absence is worth a line even when there's no file to inspect.
  if command -v jq >/dev/null 2>&1 && [[ ! -f "$settings" ]]; then
    if (( plugin_only )); then
      echo "  info    statusLine unset (optional: a plugin install can't wire it"
      echo "          automatically; paste the manual snippet from"
      echo "          docs/reference.md, Status line section, to enable the"
      echo "          context nudge's most accurate signal in plugin mode)"
    else
      echo "  info    statusLine unset (re-run ./install.sh to wire it)"
    fi
    echo
  elif command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]]; then
    if jq -e --arg m "$sl_marker" '(.statusLine.command // "") | contains($m)' \
         "$settings" >/dev/null 2>&1; then
      echo "  ok      statusLine wired (ours)"
    elif [[ -n "$plugin_dir" ]] && jq -e --arg p "$plugin_dir" '
           (.statusLine.command // "") as $c
           | ($c | contains($p)) and ($c | contains("handoff_statusline.sh"))
         ' "$settings" >/dev/null 2>&1; then
      # Second marker (issue #70): a plugin install can't wire statusLine
      # itself (Claude Code has no per-plugin mechanism for it), so the only
      # way this line matches is a user-pasted command pointing at the
      # plugin's own cached script (README's documented manual snippet).
      # Before this check, that command matched neither this branch nor the
      # bare-scripts marker above, and fell through to "user's own" below.
      echo "  ok      statusLine wired (ours, plugin)"
    elif jq -e '(.statusLine // null) != null' "$settings" >/dev/null 2>&1; then
      echo "  info    statusLine present (user's own — manual wiring documented in README)"
    elif (( plugin_only )); then
      # Plugin-only (#64): never suggest ./install.sh here, that's the
      # dual-mode trap. statusLine is optional in every mode, so this stays
      # an info line, not BROKEN, same as the bare-scripts case below.
      echo "  info    statusLine unset (optional: a plugin install can't wire it"
      echo "          automatically; paste the manual snippet from"
      echo "          docs/reference.md, Status line section, to enable the"
      echo "          context nudge's most accurate signal in plugin mode)"
    else
      echo "  info    statusLine unset (re-run ./install.sh to wire it)"
    fi
    # Model context-window check — advisory only, never counts toward broken:
    # a bare 'opus'/'claude-opus-4-8' pin silently runs at a 200k context
    # window; the 1M variant needs the [1m] suffix. Any other value (including
    # absent) is a legitimate choice we stay quiet about.
    mdl="$(jq -r '.model // ""' "$settings" 2>/dev/null)"
    case "$mdl" in
      opus|claude-opus-4-8)
        echo "  WARN    model '$mdl' in settings.json is the 200k-context variant —"
        echo "          for the 1M window set \"model\": \"${mdl}[1m]\" (edit settings.json"
        echo "          or run /model ${mdl}[1m] in a session)."
        ;;
    esac
    echo
  fi
  # Plugin-specific health checks (issue #70). The eight-script loop above
  # only ever looks under $claude_home/bin, this installer's own copy; it has
  # nothing to say about the plugin's own cache copy at $plugin_dir, which
  # has real, checkable failure modes of its own: a partial or stale cache
  # extraction makes every plugin hook a silent no-op, the same class of
  # failure issue #21 fixed for bare-scripts symlinks, just relocated to
  # wherever Claude Code checked the plugin out.
  if [[ -n "$plugin_dir" ]]; then
    echo "doctor: checking plugin cache at $plugin_dir"
    # Cache layout is <plugin_dir>/<version>/{hooks,bin,...}; pick the newest
    # version dir by mtime, same "ls -td | head -1" idiom the README's own
    # manual statusLine snippet uses for the same reason (a cache can hold
    # more than one version, see docs/reference.md's stale-cache note).
    # `|| true` on both substitutions below (same idiom as plugin_dir above):
    # when the glob matches nothing (no version subdirectory at all), `ls`
    # itself exits nonzero even with output suppressed by 2>/dev/null, and
    # under set -e that failure inside a bare assignment aborts doctor
    # entirely, silently, before the "no version subdirectory" BROKEN line a
    # few lines down ever gets a chance to print. `|| true` lets that BROKEN
    # line do its job instead of the whole command dying first.
    # shellcheck disable=SC2012  # ls -t is deliberate: mtime ordering, and BSD find has no -printf (same idiom as bin/handoff_recover_tail.sh's ls -t)
    vdir="$(ls -td "$plugin_dir"/*/ 2>/dev/null | head -1 || true)"
    vdir="${vdir%/}"
    # shellcheck disable=SC2012  # plain dir count, not name-sensitive: any non-empty ls -d line counts as one version regardless of its characters
    vcount="$(ls -d "$plugin_dir"/*/ 2>/dev/null | wc -l | tr -d ' ' || true)"
    if [[ -z "$vdir" || ! -d "$vdir" ]]; then
      echo "  BROKEN  $plugin_dir has no version subdirectory, the plugin cache looks empty or corrupted"
      broken=$((broken + 1))
    else
      if [[ -n "$vcount" ]] && (( vcount > 1 )); then
        echo "  note    $vcount versions cached under $plugin_dir; using the newest by"
        echo "          mtime ($vdir). An older cache touched more recently can shadow"
        echo "          the current version, see docs/reference.md's stale-cache note."
      fi
      hooks_json="$vdir/hooks/hooks.json"
      if [[ ! -f "$hooks_json" ]]; then
        echo "  BROKEN  $hooks_json missing, every plugin hook is silently disabled"
        broken=$((broken + 1))
      elif ! command -v jq >/dev/null 2>&1; then
        echo "  note    $hooks_json present but jq is missing, cannot verify it parses"
      elif ! jq -e . "$hooks_json" >/dev/null 2>&1; then
        echo "  BROKEN  $hooks_json is not valid JSON, every plugin hook is silently disabled"
        broken=$((broken + 1))
      else
        # `.hooks // {}` guards a valid-but-hookless hooks.json (`{}` parses
        # fine but has no "hooks" key, so bare `.hooks` resolves to null, and
        # `keys` on null is a jq runtime error, exit 5, which used to abort
        # doctor entirely under set -e before this BROKEN branch ever ran).
        # `|| true` on the substitution catches that same failure mode for
        # any other malformed shape too, leaving events_str empty so the
        # subset check below reports it as BROKEN (missing all six) instead
        # of taking doctor down with it.
        events_str="$(jq -r '.hooks // {} | keys | sort | join(",")' "$hooks_json" 2>/dev/null || true)"
        expected_events="PostCompact,PreCompact,SessionEnd,SessionStart,Stop,UserPromptSubmit"
        # Subset check, not exact equality: hooks.json only counts as broken
        # if it's missing one of the six events this tool wires. Exact
        # equality used to flag a hooks.json with an EXTRA event (a future
        # Claude Code hook, or a fork's own addition) as "missing" events it
        # never lost, just because the sorted list no longer matched
        # verbatim.
        missing_events=""
        for ev in PostCompact PreCompact SessionEnd SessionStart Stop UserPromptSubmit; do
          case ",$events_str," in
            *",$ev,"*) ;;
            *) missing_events="$missing_events $ev" ;;
          esac
        done
        if [[ -n "$missing_events" ]]; then
          echo "  BROKEN  $hooks_json is missing hook event(s):$missing_events (has [$events_str], need all of [$expected_events])"
          broken=$((broken + 1))
        else
          echo "  ok      $hooks_json has all six hook events"
          extra_events=""
          rest="$events_str"
          while [[ -n "$rest" ]]; do
            ev="${rest%%,*}"
            case "$rest" in
              *,*) rest="${rest#*,}" ;;
              *) rest="" ;;
            esac
            case " $ev " in
              *" PostCompact "*|*" PreCompact "*|*" SessionEnd "*|*" SessionStart "*|*" Stop "*|*" UserPromptSubmit "*) ;;
              *) [[ -n "$ev" ]] && extra_events="$extra_events $ev" ;;
            esac
          done
          if [[ -n "$extra_events" ]]; then
            echo "  note    $hooks_json also declares extra hook event(s), harmless:$extra_events"
          fi
        fi
      fi
      missing_scripts=""
      for name in write_handoff handoff_turn_append handoff_ctx_check handoff_session_start handoff_recover_tail handoff_statusline handoff_compact_reset handoff_provenance; do
        [[ -f "$vdir/bin/$name.sh" ]] || missing_scripts="$missing_scripts $name.sh"
      done
      if [[ -n "$missing_scripts" ]]; then
        echo "  BROKEN  $vdir/bin is missing:$missing_scripts (the plugin's hooks call these directly)"
        broken=$((broken + 1))
      else
        echo "  ok      $vdir/bin has all eight scripts"
      fi
    fi
    echo
  fi
  # Plugin/script coexistence (v0.14.0+ ships a plugin form of this tool).
  # Plugin hooks and these script-install hooks COEXIST — Claude Code fires
  # both, no dedup — so a machine with both installed double-fires every
  # hook. Advisory only: never counts toward `broken`, same as the model and
  # statusLine checks above, since neither installed form is itself faulty.
  # script_hooks_present is deliberately the narrow, SessionStart-marker-only
  # signal (unchanged from before #64/#70): it decides WARN vs. info for
  # the coexistence note specifically, not whether the per-script loop above
  # ran (that's plugin_only/bare_wired, a broader check, see above).
  if [[ -n "$plugin_dir" ]]; then
    script_hooks_present=0
    if command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]] \
       && jq -e --arg m "$ss_marker" \
            '(.hooks.SessionStart // []) | any(.. | .command? // "" | contains($m))' \
            "$settings" >/dev/null 2>&1; then
      script_hooks_present=1
    fi
    if (( script_hooks_present )); then
      echo "  WARN    plugin install detected ($plugin_dir) AND this installer's"
      echo "          script hooks are wired in $settings — every hook fires TWICE"
      echo "          (Claude Code does not dedupe plugin vs. script hooks). Fix: pick"
      echo "          one mode — either '/plugin uninstall claude-code-handoff' or"
      echo "          './install.sh --uninstall'."
    else
      # F5: "nothing to do here" used to follow this, which contradicted the
      # plugin cache checks that just ran a few lines up. Reworded to say
      # what's actually true: doctor reads the plugin's files to verify them,
      # it just never installs, updates, or removes them (that stays
      # Claude Code's own /plugin command).
      echo "  info    plugin install detected ($plugin_dir); this installer's doctor"
      echo "          does not manage plugin installs (install/update/removal is"
      echo "          Claude Code's own /plugin command); the checks above are"
      echo "          read-only verification of the plugin's cache, not management."
    fi
    echo
  fi
  if (( broken )); then
    echo "doctor: $broken issue(s) found." >&2
    if (( plugin_only )); then
      # #64: never point a plugin-only machine at ./install.sh, that is the
      # one action that manufactures the dual-mode state the README warns
      # about (a second, parallel bare-scripts install; every hook then
      # fires twice). Point at the plugin's own update path instead.
      echo "        This is a plugin-only install: do not run ./install.sh." >&2
      echo "        Reinstall the plugin instead: '/plugin uninstall claude-code-handoff'," >&2
      echo "        then '/plugin install claude-code-handoff@claude-code-handoff'." >&2
    else
      echo "        Re-run ./install.sh from a persistent clone (not a /tmp checkout)." >&2
    fi
    return 1
  fi
  echo "doctor: all hooks resolve."
}

# ------------------------------------------------------------------------ main

# The dispatch lives in one brace group with the cleanup trap as its first
# statement. Bash must parse the entire group before executing any of it, so
# on a truncated `curl | bash` stream the trap is never armed and the parse
# error keeps its nonzero exit (armed earlier, bash 3.2 reports rc=0 — see
# the note above cleanup() in 00-preamble.sh). Residual gap, accepted: a
# stream that truncates exactly at a statement boundary before this group
# still exits 0 having installed nothing — no trap arrangement can catch
# that; only checksum verification of the fetched script would.
{
trap cleanup EXIT

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
  if [[ -z "$model_pin" ]] && command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]] \
     && jq -e 'type == "object" and ((.model // null) == null)' "$settings" >/dev/null 2>&1; then
    echo "NOTE: no model pinned in settings.json — a bare 'opus' selection runs at a"
    echo "      200k context window. Re-run  ./install.sh --model 'opus[1m]'  to pin one."
    echo
  fi
  # Plugin/script coexistence heads-up (v0.14.0+ ships a plugin form of this
  # tool) — see find_plugin_cache_dir's comment for why this checks $HOME and
  # not $claude_home. Informational only; the install itself proceeds exactly
  # as it always has.
  plugin_cache_dir=""
  if plugin_cache_dir="$(find_plugin_cache_dir)"; then
    echo "NOTE: a plugin install of this tool was detected ($plugin_cache_dir)."
    echo "      Installing the script mode too will double-fire every hook —"
    echo "      Claude Code runs both plugin and script hooks, no dedup."
    echo
  fi
  echo "done. start a new Claude Code session — /handoff is available now."
  # First-run signing note — one line pointing at --doctor for the detailed
  # per-item report (secret-file hygiene, openssl presence). Uses the same
  # signing_status_reason() doctor() reports from, so the two can never drift.
  sign_reason="$(signing_status_reason)"
  case "$sign_reason" in
    active)
      echo "note: handoff signing is active — new handoffs are HMAC-signed (./install.sh --doctor for detail)."
      ;;
    pending:*)
      echo "note: handoff signing ${sign_reason#pending: } (./install.sh --doctor for detail)."
      ;;
    degraded:*)
      echo "note: handoff signing degraded (${sign_reason#degraded: }) (./install.sh --doctor for detail)."
      ;;
  esac
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
}
