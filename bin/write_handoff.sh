#!/usr/bin/env bash
# write_handoff.sh — snapshot the current repo's session state into a handoff doc
# Writes <repo>/.claude/handoff_current.md (overwriting in place, with the
# previous one rotated to .claude/handoff_history/handoff_<ts>.md first;
# last HANDOFF_HISTORY_KEEP retained — default 5, override via env).
# Prints the absolute path of the written handoff to stdout.
#
# Triggers: /handoff skill, SessionEnd hook, or manual invocation.
# Auto-loaded by the next session via the SessionStart hook in
# ~/.claude/settings.json.
#
# Flags:
#   --if-stale-by SECONDS  Skip (no rotation, no write) if handoff_current.md
#                          already exists and was modified within SECONDS.
#                          The SessionEnd hook passes this so that a curated
#                          /handoff write isn't clobbered by the safety-net
#                          run that fires moments later.

set -euo pipefail

IF_STALE_BY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --if-stale-by)
      IF_STALE_BY="${2:-}"
      shift 2
      ;;
    --if-stale-by=*)
      IF_STALE_BY="${1#*=}"
      shift
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done
if [[ -n "$IF_STALE_BY" ]] && ! [[ "$IF_STALE_BY" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --if-stale-by expects a non-negative integer (got: $IF_STALE_BY)" >&2
  exit 2
fi

# ----- Config (override via env in your shell rc) -----
#
# HANDOFF_INFLIGHT_DIRS — space-separated subdirs to scan for untracked /
#   modified .md files. Default: "docs". Add e.g. "docs design rfcs proposals".
# HANDOFF_SUBSTRATE_NAME — name of a sibling git repo to also snapshot
#   (e.g. a shared decisions / configs repo). Default: empty (skip substrate).
# HANDOFF_SUBSTRATE_INFLIGHT_DIRS — space-separated subdirs in the substrate
#   to scan. Default: empty. Only used if HANDOFF_SUBSTRATE_NAME is set.
# HANDOFF_HISTORY_KEEP — number of older handoffs to retain under
#   .claude/handoff_history/ (rotated in before each new write). Default: 5.
#   Set to 0 to disable retention entirely.
# HANDOFF_NO_GITIGNORE_BOOTSTRAP — set to 1 to skip the auto-add of
#   .claude/handoff_current.md and .claude/handoff_history/ into the project
#   .gitignore.
#
# Example for someone with a `_shared/` sibling that holds RFCs + ASKs:
#   export HANDOFF_INFLIGHT_DIRS="docs design"
#   export HANDOFF_SUBSTRATE_NAME="_shared"
#   export HANDOFF_SUBSTRATE_INFLIGHT_DIRS="rfcs ASKS"
INFLIGHT_DIRS="${HANDOFF_INFLIGHT_DIRS:-docs}"
SUBSTRATE_NAME="${HANDOFF_SUBSTRATE_NAME:-}"
SUBSTRATE_INFLIGHT_DIRS="${HANDOFF_SUBSTRATE_INFLIGHT_DIRS:-}"
HISTORY_KEEP="${HANDOFF_HISTORY_KEEP:-5}"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  echo "ERROR: not in a git repo (cwd=$PWD)" >&2
  exit 1
fi

repo_name="$(basename "$repo_root")"
handoff_dir="$repo_root/.claude"
handoff_path="$handoff_dir/handoff_current.md"
handoff_relpath=".claude/handoff_current.md"
history_dir="$handoff_dir/handoff_history"
history_relpath=".claude/handoff_history/"
mkdir -p "$handoff_dir"

# --if-stale-by guard: when a curated /handoff write happened moments ago
# and the SessionEnd safety-net then fires, this preserves the curated
# content instead of clobbering it with a mechanical snapshot.
if [[ -n "$IF_STALE_BY" ]] && [[ -f "$handoff_path" ]]; then
  now_s="$(date +%s)"
  file_s="$(date -r "$handoff_path" +%s 2>/dev/null || echo 0)"
  age_s=$(( now_s - file_s ))
  if (( age_s < IF_STALE_BY )); then
    echo "$handoff_path"
    exit 0
  fi
fi

# Self-bootstrap: ensure the handoff artifacts are git-ignored so they don't
# pollute `git status`. Skip if HANDOFF_NO_GITIGNORE_BOOTSTRAP=1.
bootstrap_gitignore() {
  local entry="$1"
  if git -C "$repo_root" check-ignore -q "$entry" 2>/dev/null; then
    return
  fi
  local gi="$repo_root/.gitignore"
  if [[ -s "$gi" ]] && [[ "$(tail -c1 "$gi" | wc -l)" -eq 0 ]]; then
    printf '\n' >> "$gi"
  fi
  echo "$entry" >> "$gi"
  echo "write_handoff.sh: added '$entry' to $gi (set HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 to skip)" >&2
}
if [[ "${HANDOFF_NO_GITIGNORE_BOOTSTRAP:-0}" != "1" ]]; then
  bootstrap_gitignore "$handoff_relpath"
  bootstrap_gitignore "$history_relpath"
fi

# Rotate the existing handoff (if any) into handoff_history/ before we
# overwrite it. The rotated file's name reflects its original generation
# time (file mtime), not the rotation time, so the history reads as a
# chronological log of session endings. Then prune to HISTORY_KEEP newest.
rotate_existing_handoff() {
  [[ -f "$handoff_path" ]] || return 0
  [[ "$HISTORY_KEEP" -gt 0 ]] || return 0
  mkdir -p "$history_dir"
  local ts archived
  ts="$(date -u -r "$handoff_path" +'%Y-%m-%d_%H%M%S' 2>/dev/null || date -u +'%Y-%m-%d_%H%M%S')"
  archived="$history_dir/handoff_${ts}.md"
  # If a file with the same timestamp already exists, append a counter
  # so we don't clobber. Only happens if two rotations land in the same
  # second, which is rare but possible.
  if [[ -e "$archived" ]]; then
    local n=2
    while [[ -e "${archived%.md}_${n}.md" ]]; do n=$((n+1)); done
    archived="${archived%.md}_${n}.md"
  fi
  mv "$handoff_path" "$archived"
}
prune_history() {
  [[ -d "$history_dir" ]] || return 0
  # List newest-first by filename (timestamps are sortable), skip the
  # first HISTORY_KEEP, delete the rest.
  ls -1 "$history_dir"/handoff_*.md 2>/dev/null \
    | sort -r \
    | tail -n +$((HISTORY_KEEP + 1)) \
    | xargs -r rm -f
}
rotate_existing_handoff
prune_history

# Optional substrate detection — sibling repo at $HANDOFF_SUBSTRATE_NAME
substrate_root=""
if [[ -n "$SUBSTRATE_NAME" ]]; then
  candidate="$(cd "$repo_root/.." && pwd)/$SUBSTRATE_NAME"
  if [[ -d "$candidate/.git" ]]; then
    substrate_root="$candidate"
  fi
fi

ts_utc="$(date -u +'%Y-%m-%d %H:%M UTC')"

git_short() { git -C "$1" rev-parse --short HEAD 2>/dev/null || echo "?"; }
git_subj()  { git -C "$1" log -1 --pretty=%s 2>/dev/null || echo "?"; }
git_branch() { git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?"; }

snapshot_repo() {
  local root="$1"
  local label="$2"
  local upstream
  upstream="$(git -C "$root" status -sb 2>/dev/null | head -1 | sed 's/^## //')"

  printf '## %s\n\n' "$label"
  printf '**HEAD:** `%s` — %s\n\n' "$(git_short "$root")" "$(git_subj "$root")"
  printf '**Branch:** `%s` (%s)\n\n' "$(git_branch "$root")" "$upstream"

  printf '### Recent commits\n\n'
  printf '```\n'
  git -C "$root" log --oneline -10 2>/dev/null || echo "(no log)"
  printf '```\n\n'

  printf '### Working tree\n\n'
  if [[ -z "$(git -C "$root" status --porcelain 2>/dev/null)" ]]; then
    printf '_clean_\n\n'
  else
    printf '```\n'
    git -C "$root" status -s
    printf '```\n\n'
  fi
}

list_inflight_md() {
  # Untracked OR modified .md files under a given subdir of a given repo
  local root="$1"
  local subdir="$2"
  git -C "$root" status --porcelain "$subdir" 2>/dev/null \
    | awk '{print $1, $2}' \
    | awk '$1 == "??" || $1 == "M" || $1 == "AM" || $1 == "MM" {print $2}' \
    | grep -E '\.md$' || true
}

{
  printf '# %s — session handoff (auto-generated)\n\n' "$repo_name"
  printf '**Generated:** %s\n\n' "$ts_utc"

  cat <<EOF
Auto-written by \`~/.claude/bin/write_handoff.sh\` (called from the
\`/handoff\` skill + the \`SessionEnd\` hook in \`~/.claude/settings.json\`).
Auto-loaded into the next session by the \`SessionStart\` hook in the
same settings file. Always lives at \`<repo>/.claude/handoff_current.md\`;
the previous handoff is rotated to \`.claude/handoff_history/\` before
overwrite (last $HISTORY_KEEP retained; override via \`HANDOFF_HISTORY_KEEP\`).
Run \`/handoff-more\` in a fresh session to pull older handoffs into context.

EOF

  echo '---'
  echo

  snapshot_repo "$repo_root" "Repo: $repo_name"

  if [[ -n "$substrate_root" ]]; then
    snapshot_repo "$substrate_root" "Substrate: $SUBSTRATE_NAME"
  fi

  # In-flight markdown across configured paths in the main repo
  for d in $INFLIGHT_DIRS; do
    [[ -d "$repo_root/$d" ]] || continue
    printf '## In-flight (untracked or modified .md under `%s/`)\n\n' "$d"
    found="$(list_inflight_md "$repo_root" "$d/")"
    if [[ -z "$found" ]]; then
      printf '_none_\n\n'
    else
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        echo "- \`$f\`"
      done <<< "$found"
      printf '\n'
    fi
  done

  # Same for the substrate, if configured
  if [[ -n "$substrate_root" ]]; then
    for d in $SUBSTRATE_INFLIGHT_DIRS; do
      [[ -d "$substrate_root/$d" ]] || continue
      printf '## In-flight (untracked or modified .md under `%s/%s/`)\n\n' "$SUBSTRATE_NAME" "$d"
      found="$(list_inflight_md "$substrate_root" "$d/")"
      if [[ -z "$found" ]]; then
        printf '_none_\n\n'
      else
        while IFS= read -r f; do
          [[ -z "$f" ]] && continue
          echo "- \`$SUBSTRATE_NAME/$f\`"
        done <<< "$found"
        printf '\n'
      fi
    done
  fi

  printf '## Verify state matches reality\n\n'
  printf '```bash\n'
  printf 'git -C %s status && git -C %s log --oneline -5\n' "$repo_root" "$repo_root"
  if [[ -n "$substrate_root" ]]; then
    printf 'git -C %s log --oneline -5\n' "$substrate_root"
  fi
  printf '```\n\n'

  echo '---'
  echo
  printf '## Notes from this session\n\n'
  printf '_The /handoff skill should append decisions, in-flight tracks, open\n'
  printf 'questions, and "next session should start with X" notes here. The\n'
  printf 'auto-snapshot above captures git state; the prose below captures\n'
  printf 'intent that only the conversation knows._\n'
} > "$handoff_path"

echo "$handoff_path"
