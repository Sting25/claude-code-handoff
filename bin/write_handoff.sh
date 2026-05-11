#!/usr/bin/env bash
# write_handoff.sh — snapshot the current repo's session state into a handoff doc
# Writes <repo>/.claude/handoff_current.md (overwritten each call)
# Prints the absolute path of the written handoff to stdout.
#
# Triggers: /handoff skill, SessionEnd hook, or manual invocation.
# Auto-loaded by the next session via the SessionStart hook in
# ~/.claude/settings.json.

set -euo pipefail

# ----- Config (override via env in your shell rc) -----
#
# HANDOFF_INFLIGHT_DIRS — space-separated subdirs to scan for untracked /
#   modified .md files. Default: "docs". Add e.g. "docs design rfcs proposals".
# HANDOFF_SUBSTRATE_NAME — name of a sibling git repo to also snapshot
#   (e.g. a shared decisions / configs repo). Default: empty (skip substrate).
# HANDOFF_SUBSTRATE_INFLIGHT_DIRS — space-separated subdirs in the substrate
#   to scan. Default: empty. Only used if HANDOFF_SUBSTRATE_NAME is set.
# HANDOFF_NO_GITIGNORE_BOOTSTRAP — set to 1 to skip the auto-add of
#   .claude/handoff_current.md into the project .gitignore.
#
# Example for someone with a `_shared/` sibling that holds RFCs + ASKs:
#   export HANDOFF_INFLIGHT_DIRS="docs design"
#   export HANDOFF_SUBSTRATE_NAME="_shared"
#   export HANDOFF_SUBSTRATE_INFLIGHT_DIRS="rfcs ASKS"
INFLIGHT_DIRS="${HANDOFF_INFLIGHT_DIRS:-docs}"
SUBSTRATE_NAME="${HANDOFF_SUBSTRATE_NAME:-}"
SUBSTRATE_INFLIGHT_DIRS="${HANDOFF_SUBSTRATE_INFLIGHT_DIRS:-}"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  echo "ERROR: not in a git repo (cwd=$PWD)" >&2
  exit 1
fi

repo_name="$(basename "$repo_root")"
handoff_dir="$repo_root/.claude"
handoff_path="$handoff_dir/handoff_current.md"
handoff_relpath=".claude/handoff_current.md"
mkdir -p "$handoff_dir"

# Self-bootstrap: ensure the handoff is git-ignored so it doesn't pollute
# `git status` as a regenerated artifact. Skip if HANDOFF_NO_GITIGNORE_BOOTSTRAP=1.
if [[ "${HANDOFF_NO_GITIGNORE_BOOTSTRAP:-0}" != "1" ]]; then
  if ! git -C "$repo_root" check-ignore -q "$handoff_relpath" 2>/dev/null; then
    gi="$repo_root/.gitignore"
    # Append a trailing newline first if the file lacks one, to keep formatting clean.
    if [[ -s "$gi" ]] && [[ "$(tail -c1 "$gi" | wc -l)" -eq 0 ]]; then
      printf '\n' >> "$gi"
    fi
    echo "$handoff_relpath" >> "$gi"
    echo "write_handoff.sh: added '$handoff_relpath' to $gi (set HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 to skip)" >&2
  fi
fi

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

  cat <<'EOF'
Auto-written by `~/.claude/bin/write_handoff.sh` (called from the
`/handoff` skill + the `SessionEnd` hook in `~/.claude/settings.json`).
Auto-loaded into the next session by the `SessionStart` hook in the
same settings file. Always lives at `<repo>/.claude/handoff_current.md`;
overwritten on every handoff. Older snapshots are not retained — use
git history of this file for archaeology.

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
