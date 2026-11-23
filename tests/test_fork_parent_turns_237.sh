#!/usr/bin/env bash
# #237: a forked session (desktop /btw side chat, or a sub-session started with
# fork context) gets a NEW session id and a transcript that begins with a copy
# of the parent's records. Those copied records keep the PARENT's sessionId
# (measured live 2026-11-20 and 2026-11-23, see #239). Without a filter the
# fork's raw dump opened with the parent's turns, attributed to the fork.
#
# Owner decision 2026-11-23: drop them. A record whose sessionId differs from
# the session the hook is running for is not folded into the dump, nor into the
# /handoff-recover tail. A record with NO sessionId still counts as the
# session's own (same rule as handoff_ctx_check.sh), so older or synthetic
# transcripts keep working.
#
# Each "dropped" assertion is paired with a "kept" one on the same fixture, so
# the test cannot pass by the hook dumping nothing at all.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TA="$REPO_ROOT/bin/handoff_turn_append.sh"
RT="$REPO_ROOT/bin/handoff_recover_tail.sh"
command -v jq >/dev/null 2>&1 || { echo "fork parent turns (#237)"; skip "jq missing"; finish; exit; }

run_turn() {  # <cwd> <sid> <transcript>
  ( cd "$1" && printf '{"session_id":"%s","transcript_path":"%s"}' "$2" "$3" \
      | bash "$TA" >/dev/null 2>&1 )
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# A fork transcript shaped like the measured ones: the parent's records first
# (parent sessionId, every record type the dump formats), then non-message
# bookkeeping, then the fork's own records.
write_fork_tx() {  # <path>
  cat > "$1" <<'EOF'
{"type":"user","sessionId":"PARENT","message":{"content":"PARENT_STRING_PROMPT"}}
{"type":"assistant","sessionId":"PARENT","message":{"content":[{"type":"text","text":"PARENT_ANSWER"},{"type":"tool_use","name":"Bash","input":{"command":"PARENT_TOOL_CALL"}}]}}
{"type":"user","sessionId":"PARENT","message":{"content":[{"type":"text","text":"PARENT_ARRAY_PROMPT"},{"type":"tool_result","tool_use_id":"t1","content":"PARENT_TOOL_RESULT"}]}}
{"type":"derived-from","v":1,"sessionId":"FORK","sessions":[{"type":"claude_code_session","id":"PARENT","via":"fork"}]}
{"type":"user","sessionId":"FORK","message":{"content":"FORK_STRING_PROMPT"}}
{"type":"assistant","sessionId":"FORK","message":{"content":[{"type":"text","text":"FORK_ANSWER"},{"type":"tool_use","name":"Bash","input":{"command":"FORK_TOOL_CALL"}}]}}
{"type":"user","sessionId":"FORK","message":{"content":[{"type":"text","text":"FORK_ARRAY_PROMPT"},{"type":"tool_result","tool_use_id":"t2","content":"FORK_TOOL_RESULT"}]}}
{"type":"user","message":{"content":"NO_SESSION_ID_PROMPT"}}
EOF
}

echo "fork parent turns are not folded into the fork's raw dump (#237)"

# --- Stop hook: the fork's dump holds only the fork's own turns -------------
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; tx="$repo/tx.jsonl"
write_fork_tx "$tx"
run_turn "$repo" FORK "$tx"
dump="$bd/handoff_raw_FORK.md"
check "fork dump created" yes "$([[ -f "$dump" ]] && echo yes || echo no)"
body="$(cat "$dump" 2>/dev/null || true)"
for marker in PARENT_STRING_PROMPT PARENT_ANSWER PARENT_TOOL_CALL PARENT_ARRAY_PROMPT PARENT_TOOL_RESULT; do
  check "dump drops $marker" no "$(has "$body" "$marker")"
done
for marker in FORK_STRING_PROMPT FORK_ANSWER FORK_TOOL_CALL FORK_ARRAY_PROMPT FORK_TOOL_RESULT; do
  check "dump keeps $marker" yes "$(has "$body" "$marker")"
done
check "record without a sessionId still counts as own" yes "$(has "$body" "NO_SESSION_ID_PROMPT")"
# The cursor still covers the skipped lines, so they are not re-read next turn.
check "cursor advanced past the copied parent lines" 8 "$(cat "$bd/.handoff_raw_FORK.cursor" 2>/dev/null || echo missing)"

# A later turn of the fork is appended as before.
printf '%s\n' '{"type":"user","sessionId":"FORK","message":{"content":"FORK_SECOND_TURN"}}' >> "$tx"
run_turn "$repo" FORK "$tx"
body="$(cat "$dump" 2>/dev/null || true)"
check "later fork turn appended"           yes "$(has "$body" "FORK_SECOND_TURN")"
check "parent turns still absent after it" no  "$(has "$body" "PARENT_")"
rm -rf "$repo"

# --- Stop hook: the PARENT's own dump is unaffected -------------------------
# The same records under the parent's session id are that session's own turns.
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; tx="$repo/tx.jsonl"
write_fork_tx "$tx"
run_turn "$repo" PARENT "$tx"
body="$(cat "$bd/handoff_raw_PARENT.md" 2>/dev/null || true)"
check "parent session keeps its own prompt" yes "$(has "$body" "PARENT_STRING_PROMPT")"
check "parent session keeps its own answer" yes "$(has "$body" "PARENT_ANSWER")"
check "parent session drops the other id's turns" no "$(has "$body" "FORK_STRING_PROMPT")"
rm -rf "$repo"

# --- /handoff-recover tail: same rule ----------------------------------------
work="$(mktemp -d)"; cleanup_on_exit "$work"; mkdir -p "$work/bd"
tx="$work/tx.jsonl"; write_fork_tx "$tx"
echo 0 > "$work/bd/.handoff_raw_FORK.cursor"
: > "$work/bd/handoff_raw_FORK.md"
out="$(HANDOFF_BACKUP_DIR="$work/bd" HANDOFF_RECOVER_TRANSCRIPT="$tx" bash "$RT" FORK 2>/dev/null)"
for marker in PARENT_STRING_PROMPT PARENT_ANSWER PARENT_TOOL_CALL PARENT_ARRAY_PROMPT PARENT_TOOL_RESULT; do
  check "recovered tail drops $marker" no "$(has "$out" "$marker")"
done
for marker in FORK_STRING_PROMPT FORK_ANSWER FORK_TOOL_CALL FORK_ARRAY_PROMPT FORK_TOOL_RESULT NO_SESSION_ID_PROMPT; do
  check "recovered tail keeps $marker" yes "$(has "$out" "$marker")"
done

finish
