#!/usr/bin/env bash
# handoff_session_start.sh — SessionStart hook output.
#
# Cats <repo>/.claude/handoff_current.md so the new session starts with
# the previous session's snapshot in context. Two extras over the
# original one-liner:
#
#   1. If the curated Notes block in handoff_current.md is the unedited
#      placeholder (i.e. SessionEnd auto-wrote the snapshot but no model
#      was in the loop to fill in prose), also cat the most recent file
#      from .claude/handoff_history/. The previous session's curated
#      prose is more useful than git-state-only.
#   2. If handoff_history/ has any entries, append a one-line pointer
#      so the assistant knows older snapshots exist and can run
#      /handoff-more to pull them in.
#
# Env overrides (rare):
#   HANDOFF_SS_DISABLE_FALLBACK=1  — never auto-include the previous
#       handoff, even if current is placeholder-only.

set -eu

repo="${CLAUDE_PROJECT_DIR:-$PWD}"
current="$repo/.claude/handoff_current.md"
history_dir="$repo/.claude/handoff_history"

[ -f "$current" ] || exit 0

echo "## Auto-loaded handoff from previous session"
echo
cat "$current"

# "Placeholder-only" detection: the SessionEnd auto-write leaves a
# specific sentence in the Notes block. If we find it, the previous
# session ended without a curated /handoff, so the current snapshot is
# git-state-only — fall through to the previous handoff if one exists.
placeholder_marker='The /handoff skill should append decisions'
if [ "${HANDOFF_SS_DISABLE_FALLBACK:-0}" != "1" ] \
   && grep -qF "$placeholder_marker" "$current" 2>/dev/null; then
  prev="$(ls -1 "$history_dir"/handoff_*.md 2>/dev/null | sort -r | head -1 || true)"
  if [ -n "$prev" ] && [ -f "$prev" ]; then
    echo
    echo "---"
    echo
    echo "## Also loaded: previous handoff (current one had no curated Notes)"
    echo
    echo "_From \`$(basename "$prev")\` — the most recent handoff with potentially curated prose._"
    echo
    cat "$prev"
  fi
fi

# Pointer to the history dir so the assistant knows older snapshots
# exist and can run /handoff-more to pull them in deliberately.
if [ -d "$history_dir" ]; then
  count="$(ls -1 "$history_dir"/handoff_*.md 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${count:-0}" -gt 0 ]; then
    echo
    echo "---"
    echo
    echo "_$count older handoff(s) in \`.claude/handoff_history/\`. Run \`/handoff-more\` to pull them into context if the current one is thin._"
  fi
fi
