#!/usr/bin/env bash
# Robustness regressions for the Stop hook (handoff_turn_append.sh):
#
#   H3 (perl-absent): perl has no POSIX guarantee. The old bare `perl` call in
#     strip_noise exited 127 on a perl-less host and, under set -euo pipefail,
#     aborted the hook BEFORE the cursor update — so the dump filled with empty
#     `## Turn` headers and never captured content, silently (the hook is wired
#     `... 2>/dev/null || true`). The fix degrades to verbatim capture. This test
#     FORCES a perl-less PATH so it exercises the fallback even where perl exists.
#
#   correctness#1 (array-user-last): when the last new transcript line is a user
#     array-message with text but no tool_result, the `[[ ]] && printf` at the end
#     of that branch returned 1, aborting the append block before the cursor
#     advanced. Next fire re-appended the same turn (duplicate dumps). The fix
#     uses if/fi so the loop body can't end on a falsy `&&`.
#
# NB: deliberately does NOT skip when perl is missing — perl-absence is the
# scenario under test. jq is still required (the hook needs it).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TA="$REPO_ROOT/bin/handoff_turn_append.sh"
command -v jq >/dev/null 2>&1 || { echo "handoff_turn_append.sh (robustness)"; skip "jq missing"; finish; exit; }

# A PATH mirroring the real one but omitting a single tool (copied from
# test_portability.sh — forces a fallback branch).
path_without() {
  local drop="$1" shim d f b
  shim="$(mktemp -d)"
  for d in ${PATH//:/ }; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
      b="$(basename "$f")"
      [[ "$b" == "$drop" ]] && continue
      [[ -e "$shim/$b" ]] || ln -s "$f" "$shim/$b" 2>/dev/null || true
    done
  done
  printf '%s\n' "$shim"
}

run_turn() {  # <repo> <sid> <transcript> [PATH override] ; returns the hook's rc
  local repo="$1" sid="$2" tx="$3" pathov="${4:-$PATH}"
  ( cd "$repo" && PATH="$pathov" printf '{"session_id":"%s","transcript_path":"%s"}' "$sid" "$tx" \
      | PATH="$pathov" bash "$TA" >/dev/null 2>&1 )
}

# ===========================================================================
echo "handoff_turn_append.sh — perl-absent degrades to verbatim capture (H3)"
noperl="$(path_without perl)"
check "perl really absent on shim PATH" absent \
  "$(PATH="$noperl" command -v perl >/dev/null 2>&1 && echo present || echo absent)"

repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; tx="$repo/tx.jsonl"
printf '{"type":"user","message":{"content":"PERL_FALLBACK_CONTENT_marker"}}\n' > "$tx"
run_turn "$repo" PF "$tx" "$noperl"; rc=$?
check "perl-absent: hook exits 0"                 0   "$rc"
check "perl-absent: cursor file written (advanced)" yes "$([[ -f "$bd/.handoff_raw_PF.cursor" ]] && echo yes || echo no)"
check "perl-absent: user content captured verbatim" yes \
  "$([[ -f "$bd/handoff_raw_PF.md" ]] && grep -q 'PERL_FALLBACK_CONTENT_marker' "$bd/handoff_raw_PF.md" && echo yes || echo no)"
rm -rf "$repo" "$noperl"

# ===========================================================================
echo "handoff_turn_append.sh — trailing user array-message doesn't abort (correctness#1)"
command -v perl >/dev/null 2>&1 || skip "perl missing — using fallback path is fine, continuing"

repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; tx="$repo/tx.jsonl"
# Last new line is a user ARRAY message with text but NO tool_result.
cat > "$tx" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"text","text":"prior assistant reply"}],"usage":{"input_tokens":10}}}
{"type":"user","message":{"content":[{"type":"text","text":"ARRAY_USER_NO_TOOLRESULT_marker"}]}}
JSONL
run_turn "$repo" C1 "$tx"; rc=$?
check "array-user-last: hook exits 0"            0   "$rc"
check "array-user-last: cursor advanced to 2"    2   "$(cat "$bd/.handoff_raw_C1.cursor" 2>/dev/null)"
check "array-user-last: user text captured"      yes "$(grep -q 'ARRAY_USER_NO_TOOLRESULT_marker' "$bd/handoff_raw_C1.md" 2>/dev/null && echo yes || echo no)"
# The usage line above carries no .message.model: tokens must still be
# recorded, but the model sidecar must be skipped (empty fails the charset
# guard), not written with junk.
check "array-user-last: tokens recorded (10)"    10  "$(cat "$bd/.ctx_tokens_C1" 2>/dev/null)"
check "no model in usage line -> no .ctx_model_" no  "$([[ -e "$bd/.ctx_model_C1" ]] && echo yes || echo no)"

# Fire again with no new lines: must NOT duplicate the turn block.
run_turn "$repo" C1 "$tx"
check "array-user-last: exactly one turn block (no dup)" 1 \
  "$(grep -c '## Turn at' "$bd/handoff_raw_C1.md" 2>/dev/null)"
rm -rf "$repo"

finish
