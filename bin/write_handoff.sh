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
#   --if-curated           Skip (no rotation, no write) if handoff_current.md
#                          already contains curated Notes content (i.e. the
#                          /handoff skill ran and replaced the placeholder
#                          block). The SessionEnd hook passes this so the
#                          safety-net write only fires when there's no real
#                          curated content to preserve. Detection is by the
#                          presence/absence of the HANDOFF_PLACEHOLDER
#                          sentinel; an unedited handoff carries the
#                          sentinel, a curated one does not.
#   --if-stale-by SECONDS  DEPRECATED (since v0.5.0). The numeric argument
#                          is ignored; this is now treated as an alias for
#                          --if-curated. Slated for removal in a future
#                          release (the original v0.6.0 target slipped).

set -euo pipefail

# The handoff document and its rotated history capture verbatim session prose,
# which can include anything sensitive surfaced during the session — so every
# file this script writes under .claude/ should be owner-only. umask 077 makes
# the handoff doc, history snapshots, and history dir 0600/0700 at creation
# time (matching the Stop hook's handling of the raw dumps). The defensive
# chmod after the final write also tightens a doc left readable by a pre-0.8.2
# version on upgrade.
umask 077

IF_CURATED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --if-curated)
      IF_CURATED=1
      shift
      ;;
    --if-stale-by)
      echo "write_handoff.sh: --if-stale-by is deprecated since v0.5.0; behaving as --if-curated. Update your settings.json to use --if-curated; --if-stale-by will be removed in a future release." >&2
      IF_CURATED=1
      # Tolerate (and ignore) the now-meaningless numeric arg if present.
      if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        shift 2
      else
        shift
      fi
      ;;
    --if-stale-by=*)
      echo "write_handoff.sh: --if-stale-by is deprecated since v0.5.0; behaving as --if-curated. Update your settings.json to use --if-curated; --if-stale-by will be removed in a future release." >&2
      IF_CURATED=1
      shift
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Sentinel embedded in the auto-generated placeholder block; presence means
# the placeholder is still in place, absence means the /handoff skill (or a
# human editor) has replaced the placeholder with curated Notes.
HANDOFF_PLACEHOLDER_SENTINEL="<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->"

# Is handoff_current.md still the *unedited* placeholder?
#
# The placeholder builder (see the end of this file) writes the sentinel as the
# first non-blank line of the "## Notes from this session" section. We scope the
# check to exactly that position rather than grepping the whole file, because the
# sentinel string can legitimately appear ELSEWHERE in a curated file:
#   - the snapshot embeds verbatim commit subjects (a commit whose subject
#     contains the sentinel would match a whole-file grep), and
#   - curated Notes may quote the sentinel in prose (as this very change does).
# A whole-file match would let the SessionEnd safety-net mistake a curated file
# for a placeholder and clobber it — silent loss of the session's notes.
#
# Returns 0 (true) only when the first non-blank line under the Notes header is
# exactly the sentinel. Anything else — curated content, a malformed/headerless
# file, or a missing file — returns non-zero, i.e. "preserve, don't clobber."
handoff_is_unedited_placeholder() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  awk -v sentinel="$HANDOFF_PLACEHOLDER_SENTINEL" '
    # Skip everything until the Notes header (the snapshot lives above it).
    !seen { if ($0 == "## Notes from this session") seen = 1; next }
    /^[[:space:]]*$/ { next }                     # skip blank lines after header
    { result = ($0 == sentinel) ? 0 : 1; found = 1; exit }  # first content line decides
    # exit jumps here; END owns the final status so the rule-level exit code
    # is not clobbered. No content line (header-only or no header) => not placeholder.
    END { exit found ? result : 1 }
  ' "$path"
}

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
# HANDOFF_PINNED_FILE — path to a pinned-context file injected verbatim into
#   every handoff (read-only; survives rotation). Default:
#   .claude/handoff_pinned.md. Inert when the file is absent.
# HANDOFF_SYSTEMLOG_FILE — path to a system log the handoff-time nudge
#   watches; flags system-level sessions that didn't touch it. Default:
#   SYSTEM_LOG.md at repo root. Inert when the file is absent.
#
# Example for someone with a `_shared/` sibling that holds RFCs + ASKs:
#   export HANDOFF_INFLIGHT_DIRS="docs design"
#   export HANDOFF_SUBSTRATE_NAME="_shared"
#   export HANDOFF_SUBSTRATE_INFLIGHT_DIRS="rfcs ASKS"
INFLIGHT_DIRS="${HANDOFF_INFLIGHT_DIRS:-docs}"
SUBSTRATE_NAME="${HANDOFF_SUBSTRATE_NAME:-}"
SUBSTRATE_INFLIGHT_DIRS="${HANDOFF_SUBSTRATE_INFLIGHT_DIRS:-}"
HISTORY_KEEP="${HANDOFF_HISTORY_KEEP:-5}"
# Guard against a negative or non-numeric value. The rotation guard skips on
# KEEP<=0, but prune_history would still run `tail -n +$((KEEP+1))`: with KEEP=-1
# that is `tail -n +0`, which on GNU means "from the start" — i.e. it lists and
# deletes EVERY history file (silent data loss), and on BSD it errors. Anything
# that isn't a non-negative integer falls back to the default 5.
if ! [[ "$HISTORY_KEEP" =~ ^[0-9]+$ ]]; then
  echo "write_handoff.sh: HANDOFF_HISTORY_KEEP='$HISTORY_KEEP' is not a non-negative integer; using default 5." >&2
  HISTORY_KEEP=5
fi

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

# Pinned-context file: read verbatim into every handoff and never written
# by this script, so it survives rotation untouched (edit it to change what
# carries forward). System-log file: watched by the handoff-time nudge.
# Both default to per-repo paths and are INERT when the file is absent —
# repos without them are entirely unaffected. Override via
# HANDOFF_PINNED_FILE / HANDOFF_SYSTEMLOG_FILE.
pinned_file="${HANDOFF_PINNED_FILE:-$handoff_dir/handoff_pinned.md}"
pinned_relpath="${pinned_file#"$repo_root"/}"
systemlog_file="${HANDOFF_SYSTEMLOG_FILE:-$repo_root/SYSTEM_LOG.md}"
systemlog_relpath="${systemlog_file#"$repo_root"/}"

# Symlink-safety. The final document write is a `>` redirect (and rotation does
# `mv "$handoff_path" -> history`); `>` FOLLOWS a symlink and truncates its
# target. A malicious repo can ship `.claude/handoff_current.md` (or `.claude`
# itself) as a symlink to a victim file (~/.bashrc, ~/.claude/settings.json, a CI
# key). On the default path rotation moves the link out of the way first, but
# that is gated on HISTORY_KEEP>0 — so HANDOFF_HISTORY_KEEP=0 (a supported
# setting, and what the test suite uses) would write straight through and destroy
# the target. Refuse a symlinked .claude, and drop any symlink planted at the
# handoff path so we always create a fresh real file in this repo and never write
# through to the link target (this also stops rotation from relocating a planted
# symlink into handoff_history/, where SessionStart would later cat through it).
if [[ -L "$handoff_dir" ]]; then
  echo "write_handoff.sh: $handoff_dir is a symlink; refusing to operate through it." >&2
  exit 1
fi
mkdir -p "$handoff_dir"
if [[ -L "$handoff_path" ]]; then
  echo "write_handoff.sh: dropping planted symlink at $handoff_relpath (refusing to write through it)." >&2
  rm -f "$handoff_path"
fi

# --if-curated guard: when the SessionEnd safety-net fires after a curated
# /handoff write, we want to preserve the curated content rather than
# clobber it with a mechanical snapshot. The check is by content (placeholder
# presence) rather than by mtime, so post-/handoff work in the same
# session doesn't trigger a false skip: any session that didn't replace
# the placeholder is still considered "no curated content to preserve."
if (( IF_CURATED )) && [[ -f "$handoff_path" ]]; then
  if ! handoff_is_unedited_placeholder "$handoff_path"; then
    # The placeholder is gone → /handoff (or a human) replaced it with curated
    # Notes (or the file is otherwise non-placeholder). Preserve it.
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
  # Don't append through a symlinked .gitignore (a malicious repo could point it
  # at a victim file). Skip the bootstrap for this entry if it's a symlink.
  if [[ -L "$gi" ]]; then
    echo "write_handoff.sh: $gi is a symlink; skipping .gitignore bootstrap for '$entry'." >&2
    return
  fi
  if [[ -s "$gi" ]] && [[ "$(tail -c1 "$gi" | wc -l)" -eq 0 ]]; then
    printf '\n' >> "$gi"
  fi
  echo "$entry" >> "$gi"
  echo "write_handoff.sh: added '$entry' to $gi (set HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 to skip)" >&2
}
if [[ "${HANDOFF_NO_GITIGNORE_BOOTSTRAP:-0}" != "1" ]]; then
  bootstrap_gitignore "$handoff_relpath"
  bootstrap_gitignore "$history_relpath"
  # Raw per-turn transcript dumps (written by the Stop hook) contain
  # verbatim session content — including anything sensitive surfaced in
  # tool output — so they must never be committable.
  bootstrap_gitignore ".claude/handoff_backups/"
  # The pin is local operational state, same class as the handoff itself.
  # Only auto-ignore when it sits inside the repo (the default and the
  # common override); an out-of-tree override is the user's to manage.
  if [[ "$pinned_relpath" != /* && "$pinned_relpath" != "$pinned_file" ]]; then
    bootstrap_gitignore "$pinned_relpath"
  fi
fi

# Rotate the existing handoff (if any) into handoff_history/ before we
# overwrite it. The rotated file's name reflects its original generation
# time (file mtime), not the rotation time, so the history reads as a
# chronological log of session endings. Then prune to HISTORY_KEEP newest.
# Portable file-mtime as YYYY-mm-dd_HHMMSS in UTC. GNU and BSD/macOS differ on
# both halves: `stat -c %Y` (GNU) vs `stat -f %m` (BSD) for the mtime epoch, and
# `date -d @EPOCH` (GNU) vs `date -r EPOCH` (BSD) to format it. (The old
# `date -u -r FILE` worked on GNU only; on BSD `-r` takes an epoch, not a path,
# so it silently fell back to the current time and mis-stamped the rotation.)
file_mtime_stamp() {
  local f="$1" epoch
  epoch="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || true)"
  if [[ "$epoch" =~ ^[0-9]+$ ]]; then
    date -u -d "@$epoch" +'%Y-%m-%d_%H%M%S' 2>/dev/null \
      || date -u -r "$epoch" +'%Y-%m-%d_%H%M%S' 2>/dev/null \
      || date -u +'%Y-%m-%d_%H%M%S'
  else
    date -u +'%Y-%m-%d_%H%M%S'
  fi
}

rotate_existing_handoff() {
  [[ -f "$handoff_path" ]] || return 0
  [[ "$HISTORY_KEEP" -gt 0 ]] || return 0
  mkdir -p "$history_dir"
  local ts archived
  ts="$(file_mtime_stamp "$handoff_path")"
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
# Capture the HEAD recorded in the previous handoff BEFORE rotation moves
# it away. The rotation boundary is a usable proxy for "since last session,"
# letting the system-log nudge diff this session's commits. Empty (→ nudge
# skipped) on first run or if the prior handoff had no parseable HEAD.
prev_head=""
if [[ -f "$handoff_path" ]]; then
  prev_head="$(grep -m1 '^\*\*HEAD:\*\*' "$handoff_path" 2>/dev/null \
    | sed -E 's/.*`([0-9a-fA-F]+)`.*/\1/' | grep -Ei '^[0-9a-f]+$' || true)"
fi

rotate_existing_handoff
prune_history

# Optional substrate detection — sibling repo at $HANDOFF_SUBSTRATE_NAME
substrate_root=""
if [[ -n "$SUBSTRATE_NAME" ]]; then
  candidate="$(cd "$repo_root/.." && pwd)/$SUBSTRATE_NAME"
  if [[ -d "$candidate/.git" ]]; then
    substrate_root="$candidate"
  else
    # Configured but not found / not a git repo. Silently skipping hid typos in
    # HANDOFF_SUBSTRATE_NAME and renamed/missing siblings; surface it so the
    # user knows the substrate snapshot was intentionally omitted, not lost.
    echo "write_handoff.sh: substrate '$SUBSTRATE_NAME' not found as a git repo at '$candidate'; skipping substrate snapshot." >&2
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
  # Untracked OR modified .md files under a given subdir of a given repo.
  #
  # Uses --porcelain -z: NUL-terminated records with paths emitted VERBATIM.
  # Plain --porcelain splits status from path on a single space and C-quotes
  # any path containing spaces (e.g. `"docs/my notes.md"`), so the old
  # `awk '{print $2}'` truncated such a path at the first space and the `.md`
  # filter then dropped it entirely — spaced filenames silently vanished.
  local root="$1"
  local subdir="$2"
  local xy path src
  git -C "$root" status --porcelain -z "$subdir" 2>/dev/null \
    | while IFS= read -r -d '' entry; do
        xy="${entry:0:2}"      # two-char status field
        path="${entry:3}"      # path begins after "XY " (status + one space)
        # Rename/copy entries are followed by a second NUL-terminated field
        # (the source path); consume it so it isn't read as the next entry.
        case "$xy" in
          R*|C*) IFS= read -r -d '' src || true ;;
        esac
        case "$xy" in
          '??'|' M'|'M '|'MM'|'AM') ;;   # untracked or modified (staged/unstaged)
          *) continue ;;
        esac
        [[ "$path" == *.md ]] && printf '%s\n' "$path"
      done || true
}

# Build the document in a temp file in $handoff_dir (same filesystem → the mv
# below is an atomic rename). umask 077 makes it 0600 at creation; the trap
# removes it if anything aborts before the final publish.
handoff_tmp="$(mktemp "$handoff_dir/.handoff_current.XXXXXX")"
trap 'rm -f "$handoff_tmp"' EXIT

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

  # Pinned context — read verbatim from $pinned_file if present. Never
  # regenerated; edit that file to change what carries forward. Placed
  # first so durable context + guardrails are the first thing the next
  # session reads, before the git snapshot.
  if [[ -s "$pinned_file" ]]; then
    printf '## 📌 Pinned — carried forward every handoff\n\n'
    printf '_Source: `%s` — edit that file to change this; `write_handoff.sh`\n' "$pinned_relpath"
    printf 'only reads it, so it survives rotation. This is the durable-but-\n'
    printf 'temporary layer: context + guardrails that outlive a session but\n'
    printf 'expire when the underlying state resolves. Permanent rules go in\n'
    printf 'AGENTS.md; this-session intent goes in Notes below._\n\n'
    cat "$pinned_file"
    printf '\n\n'
    echo '---'
    echo
  fi

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

  # System-log nudge (handoff-time only). Fires only when this session's
  # commits look system-level (changed shape) AND none of them touched the
  # system log. A nudge, not a gate — false positives just prompt a second
  # look. Inert when the log file is absent or there's no prior HEAD.
  # Tune the path / subject heuristics below per project if it over-fires.
  if [[ -f "$systemlog_file" && -n "$prev_head" ]]; then
    range_commits="$(git -C "$repo_root" log --oneline "${prev_head}..HEAD" 2>/dev/null || true)"
    if [[ -n "$range_commits" ]]; then
      changed_files="$(git -C "$repo_root" log --name-only --pretty=format: "${prev_head}..HEAD" 2>/dev/null || true)"
      subjects="$(git -C "$repo_root" log --pretty=%s "${prev_head}..HEAD" 2>/dev/null || true)"
      touched_log="$(printf '%s\n' "$changed_files" | grep -Fx "$systemlog_relpath" || true)"
      sys_paths="$(printf '%s\n' "$changed_files" | grep -E '(^|/)(AGENTS\.md|.*-rules\.md|db-bootstrap\.sh|install\.sh)$|^\.github/workflows/' || true)"
      sys_subj="$(printf '%s\n' "$subjects" | grep -iE 'secur|migrat|scaffold|topolog|isolat|\brole\b|\bauth\b|\bdb\b' || true)"
      if [[ -z "$touched_log" && ( -n "$sys_paths" || -n "$sys_subj" ) ]]; then
        printf '## ⚠️ System-log nudge\n\n'
        printf 'This session has commits that look **system-level** (security, '
        printf 'scaffold, topology, migration, roles) but `%s` was **not touched**.\n' "$systemlog_relpath"
        printf 'If any of these changed the system'\''s shape, add a What/Why/Fix/Where '
        printf 'entry before handing off:\n\n'
        printf '```\n%s\n```\n\n' "$range_commits"
      fi
    fi
  fi

  echo '---'
  echo
  printf '## Notes from this session\n\n'
  printf '%s\n' "$HANDOFF_PLACEHOLDER_SENTINEL"
  printf '\n'
  printf '_The /handoff skill should replace this entire block (sentinel\n'
  printf 'comment included) with curated decisions, in-flight tracks, open\n'
  printf 'questions, and "next session should start with X" notes. The auto-\n'
  printf 'snapshot above captures git state; the prose below captures intent\n'
  printf 'that only the conversation knows. The sentinel above is how the\n'
  printf 'SessionEnd safety-net detects whether curation has happened._\n'
} > "$handoff_tmp"

# Tighten before publishing (umask already makes it 0600 at creation; this also
# covers a tmp produced under an unusual umask). The prose may include secrets.
chmod 600 "$handoff_tmp" 2>/dev/null || true

# Atomic, symlink-safe publish: mv replaces the destination NAME, so it can't be
# made to write through a symlink that reappears after the guard above (TOCTOU),
# and a crash mid-write can't leave a half-written handoff_current.md.
mv -f "$handoff_tmp" "$handoff_path"

echo "$handoff_path"
