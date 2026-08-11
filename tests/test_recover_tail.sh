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
# shellcheck disable=SC2016  # backticks are the literal markdown code span being asserted on, not command substitution
check "tail tool call rendered" yes "$(has "$out" '`Bash`')"
rm -rf "$work"

# --- M-7: dump present but cursor missing -> WARNING, not a silent cursor=0 -
# Distinguishes "no Stop hook has EVER fired" (legitimate cursor=0, covered
# above) from "the Stop hook fired and wrote a dump, but this script is
# reading the WRONG backup dir for the cursor" (the documented failure mode:
# HANDOFF_BACKUP_DIR pointing somewhere other than where the writers actually
# wrote). Both look identical at the cursor-file level (missing), but only the
# second one has a dump sitting right next to where the cursor should be —
# and treating them the same means the whole session gets silently re-emitted
# as "recovered tail" over an already-captured session.
work="$(mktemp -d)"; mk_fixture "$work"
bd="$work/bd"; tx="$work/tx.jsonl"
must bash -c "cat > '$tx'" <<'EOF'
{"type":"user","message":{"content":"already captured elsewhere"}}
EOF
: > "$bd/handoff_raw_SID.md"   # dump exists; its cursor does not
err="$(HANDOFF_BACKUP_DIR="$bd" HANDOFF_RECOVER_TRANSCRIPT="$tx" bash "$RT" SID 2>&1 1>/dev/null)"
check "dump-without-cursor -> warns"           yes "$(has "$err" "WARNING")"
check "dump-without-cursor -> names dump file" yes "$(has "$err" "handoff_raw_SID.md")"
rm -rf "$work"

# --- M-7 (negative control): dump absent too -> the ordinary no-cursor path,
#     no anomaly warning (this is the "sole prompt NEVERCAPTURED" case above,
#     re-asserted here specifically for stderr silence on the warning text) --
work="$(mktemp -d)"; mk_fixture "$work"
bd="$work/bd"; tx="$work/tx.jsonl"
must bash -c "cat > '$tx'" <<'EOF'
{"type":"user","message":{"content":"first run, nothing captured yet"}}
EOF
err="$(HANDOFF_BACKUP_DIR="$bd" HANDOFF_RECOVER_TRANSCRIPT="$tx" bash "$RT" SID 2>&1 1>/dev/null)"
check "no dump, no cursor -> no anomaly warning" no "$(has "$err" "WARNING")"
rm -rf "$work"

# --- M-8: same session id under two project-slug dirs -> newest by mtime
#     wins, not glob/lexical order; stderr warns and names both -------------
# Claude Code mints a new project-slug directory when a project is renamed,
# moved, or resumed from a different cwd, so the same <id>.jsonl can exist
# under two slugs at once. The lexically-EARLIER slug ("aaa-slug") holds a
# deliberately STALE, shorter transcript with an older mtime; the lexically-
# LATER slug ("zzz-slug") holds the real, current, longer transcript with a
# newer mtime. The old first-match-wins glob loop would have picked the stale
# one purely because "aaa" sorts before "zzz" — this asserts the newest one
# (by mtime) is picked instead, regardless of name order.
work="$(mktemp -d)"; mk_fixture "$work"
bd="$work/bd"
proj_root="$work/projects"
must mkdir -p "$proj_root/aaa-slug" "$proj_root/zzz-slug"
printf '{"type":"user","message":{"content":"STALE_MARKER"}}\n' > "$proj_root/aaa-slug/DUPSID.jsonl"
touch -t 202001010000 "$proj_root/aaa-slug/DUPSID.jsonl"   # old mtime
printf '{"type":"user","message":{"content":"LIVE_MARKER"}}\n' > "$proj_root/zzz-slug/DUPSID.jsonl"
touch -t 202601010000 "$proj_root/zzz-slug/DUPSID.jsonl"   # newer mtime
out="$(HANDOFF_BACKUP_DIR="$bd" HANDOFF_PROJECTS_DIR="$proj_root" bash "$RT" DUPSID 2>"$work/err.log")"
err="$(cat "$work/err.log")"
check "dup session id -> newest transcript wins" yes "$(has "$out" "LIVE_MARKER")"
check "dup session id -> stale copy not used"    no  "$(has "$out" "STALE_MARKER")"
check "dup session id -> warns on stderr"        yes "$(has "$err" "WARNING")"
check "dup session id -> names aaa-slug copy"    yes "$(has "$err" "aaa-slug")"
check "dup session id -> names zzz-slug copy"    yes "$(has "$err" "zzz-slug")"
rm -rf "$work"

finish
