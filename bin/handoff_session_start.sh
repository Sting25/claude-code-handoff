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
#   HANDOFF_SS_DISABLE_RECOVER=1   — never emit the /handoff-recover
#       sentinel block. Use if the user does not have the
#       handoff-recover skill installed and wants the silent
#       fallback-only behavior.

set -eu

repo="${CLAUDE_PROJECT_DIR:-$PWD}"
current="$repo/.claude/handoff_current.md"
history_dir="$repo/.claude/handoff_history"

[ -f "$current" ] || exit 0

echo "## Auto-loaded handoff from previous session"
echo
cat "$current"

# "Placeholder-only" detection: the SessionEnd auto-write leaves the
# HANDOFF_PLACEHOLDER sentinel (or, for pre-0.5.0 installs, a specific
# instruction sentence) in the Notes block. If we find either, the
# previous session ended without a curated /handoff and the current
# snapshot is git-state-only.
#
# When placeholder-only is detected, do two things:
#   1. Cat the most recent file from .claude/handoff_history/ so the
#      next session at least has the previous session's curated prose.
#   2. Emit an ACTION sentinel telling the model to invoke
#      /handoff-recover before starting new work. The fallback above
#      is "what we know"; the recover skill is "compose what we can
#      reconstruct" from the raw dump plus history.
placeholder_marker_legacy='The /handoff skill should append decisions'
placeholder_sentinel='<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->'
is_placeholder=0
if grep -qF "$placeholder_sentinel" "$current" 2>/dev/null \
   || grep -qF "$placeholder_marker_legacy" "$current" 2>/dev/null; then
  is_placeholder=1
fi

prev=""
if [ "$is_placeholder" = "1" ] \
   && [ "${HANDOFF_SS_DISABLE_FALLBACK:-0}" != "1" ]; then
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

if [ "$is_placeholder" = "1" ] \
   && [ "${HANDOFF_SS_DISABLE_RECOVER:-0}" != "1" ]; then
  echo
  echo "---"
  echo
  echo "-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-"
  echo "                 ACTION: RUN /handoff-recover"
  echo "-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-"
  echo
  echo "The previous session ended without invoking /handoff —"
  echo "handoff_current.md contains only mechanical git state, no"
  echo "curated Notes from the previous session's conversation."
  if [ -n "$prev" ]; then
    echo
    echo "A fallback (the previous curated handoff from history) has"
    echo "been loaded above to fill the gap, but the more recent"
    echo "session's intent is still missing. Invoke /handoff-recover"
    echo "before starting new work — it composes a retroactive curated"
    echo "Notes block from the raw per-turn dump under"
    echo ".claude/handoff_backups/ and writes it back into"
    echo "handoff_current.md so this and future sessions can see it."
  else
    echo
    echo "There is no previous handoff in .claude/handoff_history/"
    echo "either, so this session has only git state to work from."
    echo "Invoke /handoff-recover before starting new work — it will"
    echo "reconstruct what it can from the raw per-turn dump under"
    echo ".claude/handoff_backups/ if one exists."
  fi
  echo
  echo "-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-"
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
