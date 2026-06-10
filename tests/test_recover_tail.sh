#!/usr/bin/env bash
# Behavioral coverage for handoff_recover_tail.sh — the /handoff-recover helper
# that rescues the final turn(s) a crash dropped from the raw dump.
#
# The gap it closes: the Stop hook folds JSONL lines into the dump and records a
# cursor; a session killed before its final Stop leaves lines past the cursor
# that the dump never captured. This helper emits exactly those lines.
#
# Each assertion here is paired with its non-vacuous counterpart: the tail
# content must appear when the cursor is behind, and must NOT appear when the
# cursor is caught up (proving the helper keys on the cursor, not "dump
# everything always").
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RT="$REPO_ROOT/bin/handoff_recover_tail.sh"
command -v jq >/dev/null 2>&1 || { echo "handoff_recover_tail.sh"; skip "jq missing"; finish; exit; }

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

echo "handoff_recover_tail.sh — cursor-gated tail recovery"

# Fixtures: backup dir with a cursor, plus a transcript JSONL. We override both
# locations via env so the helper never touches the real ~/.claude tree.
mk_fixture() {  # <dir>
  mkdir -p "$1/bd"
}

# --- Tail past the cursor is recovered --------------------------------------
work="$(mktemp -d)"; mk_fixture "$work"
bd="$work/bd"; tx="$work/tx.jsonl"
must bash -c "cat > '$tx'" <<'EOF'
{"type":"user","message":{"content":"old prompt CAPTURED"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"old answer CAPTURED"}]}}
{"type":"user","message":{"content":"final prompt DROPPED"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"final answer DROPPED"}]}}
EOF
echo 2 > "$bd/.handoff_raw_SID.cursor"   # dump captured first 2 lines only
out="$(HANDOFF_BACKUP_DIR="$bd" HANDOFF_RECOVER_TRANSCRIPT="$tx" bash "$RT" SID 2>/dev/null)"
check "dropped final prompt recovered"     yes "$(has "$out" "final prompt DROPPED")"
check "dropped final answer recovered"     yes "$(has "$out" "final answer DROPPED")"
# Non-vacuous: the already-captured lines must NOT be re-emitted (else the test
# would pass even if the helper ignored the cursor and dumped the whole file).
check "captured lines not re-emitted (1)"  no  "$(has "$out" "old prompt CAPTURED")"
check "captured lines not re-emitted (2)"  no  "$(has "$out" "old answer CAPTURED")"
check "tail count reported (2 lines)"      yes "$(has "$out" "2 JSONL line(s) past")"
rm -rf "$work"

# --- Dump already complete -> empty output (the clean-exit case) ------------
work="$(mktemp -d)"; mk_fixture "$work"
bd="$work/bd"; tx="$work/tx.jsonl"
must bash -c "cat > '$tx'" <<'EOF'
{"type":"user","message":{"content":"only prompt"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"only answer"}]}}
EOF
echo 2 > "$bd/.handoff_raw_SID.cursor"   # cursor == line count
rc=0
out="$(HANDOFF_BACKUP_DIR="$bd" HANDOFF_RECOVER_TRANSCRIPT="$tx" bash "$RT" SID 2>/dev/null)" || rc=$?
check "complete dump -> empty stdout"  ""  "$out"
check "complete dump -> exit 0"        0   "$rc"
rm -rf "$work"

# --- Missing cursor treated as 0 -> whole transcript is the tail ------------
# A session that crashed before ANY Stop fired has a transcript but no cursor.
work="$(mktemp -d)"; mk_fixture "$work"
bd="$work/bd"; tx="$work/tx.jsonl"
must bash -c "cat > '$tx'" <<'EOF'
{"type":"user","message":{"content":"sole prompt NEVERCAPTURED"}}
EOF
out="$(HANDOFF_BACKUP_DIR="$bd" HANDOFF_RECOVER_TRANSCRIPT="$tx" bash "$RT" SID 2>/dev/null)"
check "no cursor -> full transcript recovered" yes "$(has "$out" "sole prompt NEVERCAPTURED")"
rm -rf "$work"

# --- Crash-truncated final line (no trailing newline) is still recovered ----
# This is the core crash case: the last JSONL line was written without a closing
# newline. `wc -l` would undercount and drop it; the helper uses awk NR so it
# survives. Without this, the most important turn (the last one) is lost.
work="$(mktemp -d)"; mk_fixture "$work"
bd="$work/bd"; tx="$work/tx.jsonl"
printf '{"type":"user","message":{"content":"line one"}}\n'        > "$tx"
printf '{"type":"user","message":{"content":"truncated TAILLINE"}}' >> "$tx"   # NO trailing newline
echo 1 > "$bd/.handoff_raw_SID.cursor"
out="$(HANDOFF_BACKUP_DIR="$bd" HANDOFF_RECOVER_TRANSCRIPT="$tx" bash "$RT" SID 2>/dev/null)"
check "unterminated final line recovered" yes "$(has "$out" "truncated TAILLINE")"
rm -rf "$work"

# --- Missing transcript -> clean no-op (exit 0, nothing to recover) ---------
work="$(mktemp -d)"; mk_fixture "$work"; bd="$work/bd"
rc=0
out="$(HANDOFF_BACKUP_DIR="$bd" HANDOFF_RECOVER_TRANSCRIPT="$work/nope.jsonl" bash "$RT" SID 2>/dev/null)" || rc=$?
check "missing transcript -> empty stdout" ""  "$out"
check "missing transcript -> exit 0"       0   "$rc"
rm -rf "$work"

# --- Invalid session id is rejected (path-injection guard) ------------------
rc=0
HANDOFF_BACKUP_DIR=/tmp bash "$RT" "../../etc/passwd" >/dev/null 2>&1 || rc=$?
check "invalid session id rejected" 2 "$rc"

# --- Tool calls in the tail are formatted (matches dump shape) --------------
work="$(mktemp -d)"; mk_fixture "$work"
bd="$work/bd"; tx="$work/tx.jsonl"
must bash -c "cat > '$tx'" <<'EOF'
{"type":"user","message":{"content":"captured"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}
EOF
echo 1 > "$bd/.handoff_raw_SID.cursor"
out="$(HANDOFF_BACKUP_DIR="$bd" HANDOFF_RECOVER_TRANSCRIPT="$tx" bash "$RT" SID 2>/dev/null)"
check "tail tool call rendered" yes "$(has "$out" '`Bash`')"
rm -rf "$work"

finish
