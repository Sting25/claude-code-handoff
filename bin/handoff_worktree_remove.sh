#!/usr/bin/env bash
# handoff_worktree_remove.sh — WorktreeRemove hook (#142).
#
# Claude Code fires WorktreeRemove (plugin hooks since 2.1.300, only for the
# worktrees Claude Code itself created, which covers desktop worktree
# sessions) with a payload naming the worktree about to go:
#   {"session_id": "...", "cwd": "...", "worktree_path": "/path/to/worktree"}
# Everything a worktree session left under <worktree>/.claude/ goes with it:
# its handoff_current.md (curated or not) and its per-turn raw dumps. The
# SessionEnd / PreCompact safety net already salvages the CURRENT session's
# dump (write_handoff.sh --if-curated), but a session killed before
# SessionEnd, or a worktree removed later, never reaches it. This hook is the
# last chance: it saves the worktree's handoff_current.md (when it is not an
# unedited placeholder) with handoff_worktree_copy and every
# handoff_backups/handoff_raw_*.md with handoff_worktree_salvage_dump, both
# into <main>/.claude/handoff_history/worktrees/ (dated, never overwritten,
# deduplicated). The main checkout's SessionStart then lists them.
#
# Validation: worktree_path must be an existing directory and a LINKED
# worktree (handoff_linked_worktree_main says which main checkout). When the
# resolved project root (CLAUDE_PROJECT_DIR / payload cwd / $PWD) is a
# different checkout, this still salvages into the worktree's OWN main
# checkout (its git metadata is authoritative) and says so on stderr.
#
# Hook discipline: prints nothing on stdout, warns on stderr, exits 0 always
# (no set -e: nothing here may fail the removal). jq optional: the same
# no-jq sed extraction as handoff_session_start.sh.

set -uo pipefail
umask 077

payload="$(cat 2>/dev/null || true)"
[[ -n "$payload" ]] || exit 0

json_field() {  # <name> -> value of a top-level string field, or empty
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$1" '.[$k] // empty' <<<"$payload" 2>/dev/null || true
  else
    printf '%s' "$payload" \
      | LC_ALL=C sed -nE "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\\1/p" \
      | head -n 1 || true
  fi
}

worktree_path="$(json_field worktree_path)"
if [[ -z "$worktree_path" ]]; then
  echo "handoff: WorktreeRemove payload has no worktree_path; nothing to salvage." >&2
  exit 0
fi
if [[ ! -d "$worktree_path" ]]; then
  echo "handoff: WorktreeRemove: $worktree_path is not a directory; nothing to salvage." >&2
  exit 0
fi
payload_cwd="$(json_field cwd)"
[[ -n "$payload_cwd" && -d "$payload_cwd" ]] || payload_cwd=""

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || self_dir=""
if [[ -n "$self_dir" && -f "$self_dir/handoff_provenance.sh" ]]; then
  # shellcheck source=bin/handoff_provenance.sh
  . "$self_dir/handoff_provenance.sh"
fi
if ! type handoff_worktree_salvage_dump >/dev/null 2>&1 \
   || ! type handoff_worktree_copy >/dev/null 2>&1; then
  echo "handoff: WorktreeRemove: bin/handoff_provenance.sh is missing or stale; nothing salvaged from $worktree_path." >&2
  exit 0
fi

wt="$(cd "$worktree_path" 2>/dev/null && pwd -P)" || exit 0
main="$(handoff_linked_worktree_main "$wt")" || {
  echo "handoff: WorktreeRemove: $wt is not a linked git worktree; nothing to salvage." >&2
  exit 0
}
if type handoff_resolve_root >/dev/null 2>&1; then
  # Informational only: the worktree's own git metadata picks the target.
  HANDOFF_HOOKS_FOLLOW_WORKTREE=0 handoff_resolve_root "$payload_cwd"
  if [[ "$HANDOFF_ROOT_IN_GIT" = "1" && "$HANDOFF_ROOT" != "$main" ]]; then
    echo "handoff: WorktreeRemove: $wt belongs to $main, not to the resolved project root $HANDOFF_ROOT; salvaging into $main." >&2
  fi
fi

claude_dir="$wt/.claude"
if [[ -L "$claude_dir" ]]; then
  echo "handoff: WorktreeRemove: $claude_dir is a symlink; nothing salvaged." >&2
  exit 0
fi
[[ -d "$claude_dir" ]] || exit 0

doc="$claude_dir/handoff_current.md"
if [[ -f "$doc" && ! -L "$doc" ]]; then
  if handoff_is_unedited_placeholder "$doc"; then
    echo "handoff: WorktreeRemove: $doc is an unedited placeholder; not copied (its raw dumps are salvaged below)." >&2
  else
    handoff_worktree_copy "$doc" "$wt" || true
  fi
fi

backup_dir="$claude_dir/handoff_backups"
if [[ -d "$backup_dir" && ! -L "$backup_dir" ]]; then
  # -type f skips symlinks; the salvage helper re-checks and validates the name.
  while IFS= read -r dump; do
    [[ -n "$dump" ]] || continue
    handoff_worktree_salvage_dump "$dump" "$wt" || true
  done < <(find "$backup_dir" -maxdepth 1 -type f -name 'handoff_raw_*.md' 2>/dev/null | LC_ALL=C sort)
fi
exit 0
