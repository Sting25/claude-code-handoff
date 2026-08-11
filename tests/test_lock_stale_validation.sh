#!/usr/bin/env bash
# HANDOFF_LOCK_STALE_SECS must be numerically validated before it reaches a
# bash (( )) arithmetic context. Bash arithmetic recursively expands its
# operand, so an array-subscript payload containing command substitution would
# execute — and this var is deliverable via a clone's .claude/settings.json
# `env`, the provenance layer's exact threat model. Found by the v0.13.0
# adversarial re-audit (was the sole unvalidated arithmetic env input).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "HANDOFF_LOCK_STALE_SECS arithmetic-injection guard"

command -v jq >/dev/null 2>&1 || { echo "  SKIP  jq not available"; finish; exit 0; }

# --- turn_append gitignore-lock reclaim path (a (( )) site) ---
proj="$(mk_repo)" || exit 1
cleanup_on_exit "$proj"
must mkdir -p "$proj/.claude/handoff_backups"
# A pre-existing gitignore lock forces the stale-reclaim branch.
must mkdir "$proj/.claude/.handoff_gitignore.lock"
sentinel="$proj/ACE_MARKER"
# shellcheck disable=SC2016  # the $(...) must stay LITERAL — it is the payload
# whose non-expansion by our code is exactly what's under test.
payload='BASH_VERSINFO[$(touch '"$sentinel"')]'
transcript="$proj/t.jsonl"
must bash -c "printf '%s\n%s\n' \
  '{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}' \
  '{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"yo\"}]}}' \
  > '$transcript'"
payload_json="$(jq -nc --arg t "$transcript" --arg c "$proj" \
  '{session_id:"acesid", transcript_path:$t, cwd:$c}')"
CLAUDE_PROJECT_DIR="$proj" HANDOFF_LOCK_STALE_SECS="$payload" \
  bash "$REPO_ROOT/bin/handoff_turn_append.sh" <<<"$payload_json" >/dev/null 2>&1

executed=yes; [ -e "$sentinel" ] || executed=no
check "turn_append: payload did NOT execute" no "$executed"

# --- write_handoff whole-run-lock reclaim path (another (( )) site) ---
proj2="$(mk_repo)" || exit 1
cleanup_on_exit "$proj2"
must mkdir -p "$proj2/.claude"
must mkdir "$proj2/.claude/.handoff_write.lock"
sentinel2="$proj2/ACE_MARKER2"
# shellcheck disable=SC2016  # literal payload, see note above
payload2='BASH_VERSINFO[$(touch '"$sentinel2"')]'
( cd "$proj2" && CLAUDE_PROJECT_DIR="$proj2" HANDOFF_LOCK_STALE_SECS="$payload2" \
    HANDOFF_SECRET_FILE="$proj2/.secret" \
    bash "$REPO_ROOT/bin/write_handoff.sh" >/dev/null 2>&1 </dev/null )

executed2=yes; [ -e "$sentinel2" ] || executed2=no
check "write_handoff: payload did NOT execute" no "$executed2"

# A valid numeric value still works (the reclaim path isn't broken by the guard).
proj3="$(mk_repo)" || exit 1
cleanup_on_exit "$proj3"
( cd "$proj3" && CLAUDE_PROJECT_DIR="$proj3" HANDOFF_LOCK_STALE_SECS=600 \
    HANDOFF_SECRET_FILE="$proj3/.secret" \
    bash "$REPO_ROOT/bin/write_handoff.sh" >/dev/null 2>&1 </dev/null )
wrote=no; [ -f "$proj3/.claude/handoff_current.md" ] && wrote=yes
check "numeric value still writes normally" yes "$wrote"

finish
