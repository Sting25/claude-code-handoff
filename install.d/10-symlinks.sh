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

