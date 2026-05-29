#!/usr/bin/env bash
# Core behavioral coverage for handoff_turn_append.sh (the Stop hook) beyond
# what test_portability.sh exercises (flock fallback, prune, token extraction).
# Focus here: cursor-based dedup, incremental append, transcript-reset skip,
# noise-tag stripping, and the not-a-git-repo / missing-transcript guards.
#
# Observable: the dump file at .claude/handoff_backups/handoff_raw_<sid>.md.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TA="$REPO_ROOT/bin/handoff_turn_append.sh"
command -v jq   >/dev/null 2>&1 || { echo "handoff_turn_append.sh"; skip "jq missing";  finish; exit; }
command -v perl >/dev/null 2>&1 || { echo "handoff_turn_append.sh"; skip "perl missing — noise strip needs it"; finish; exit; }

# Fire the Stop hook for a session/transcript. cwd defaults to the repo.
run_turn() {  # <cwd> <sid> <transcript>
  ( cd "$1" && printf '{"session_id":"%s","transcript_path":"%s"}' "$2" "$3" \
      | bash "$TA" >/dev/null 2>&1 )
}
count_turns() { grep -c '^## Turn at ' "$1" 2>/dev/null || echo 0; }
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

echo "handoff_turn_append.sh — cursor dedup / incremental / strip / guards"

# --- Cursor dedup: re-firing with no new lines appends nothing --------------
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; tx="$repo/tx.jsonl"
printf '{"type":"user","message":{"content":"hello"}}\n' > "$tx"
run_turn "$repo" DUP "$tx"
run_turn "$repo" DUP "$tx"          # identical transcript, no growth
dump="$bd/handoff_raw_DUP.md"
check "first fire created dump"        yes "$([[ -f "$dump" ]] && echo yes || echo no)"
check "no new lines -> single turn"    1   "$(count_turns "$dump")"
rm -rf "$repo"

# --- Incremental append: a second turn appears only after growth ------------
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; tx="$repo/tx.jsonl"
printf '{"type":"user","message":{"content":"first prompt FOO"}}\n' > "$tx"
run_turn "$repo" INC "$tx"
printf '{"type":"user","message":{"content":"second prompt BAR"}}\n' >> "$tx"
run_turn "$repo" INC "$tx"
dump="$bd/handoff_raw_INC.md"
check "two turns recorded"        2   "$(count_turns "$dump")"
check "first turn content kept"   yes "$(has "$(cat "$dump")" "first prompt FOO")"
check "second turn content added" yes "$(has "$(cat "$dump")" "second prompt BAR")"
# Header block (its title line) is written exactly once.
check "dump header written once"  1   "$(grep -c '^# Raw session dump' "$dump")"
rm -rf "$repo"

# --- Transcript shorter than cursor (reset/rotation) -> skip ----------------
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; mkdir -p "$bd"; tx="$repo/tx.jsonl"
printf '{"type":"user","message":{"content":"only line"}}\n' > "$tx"   # 1 line
printf '99' > "$bd/.handoff_raw_RST.cursor"                            # pretend we saw 99
run_turn "$repo" RST "$tx"
check "transcript<cursor -> no dump created" no "$([[ -f "$bd/handoff_raw_RST.md" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- Noise stripping: re-injected Claude Code tags removed from user text ----
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; tx="$repo/tx.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"<system-reminder>IGNORE_ME noise</system-reminder>KEEP_ME real text"}}' > "$tx"
run_turn "$repo" NZ "$tx"
body="$(cat "$bd/handoff_raw_NZ.md")"
check "noise tag content stripped" no  "$(has "$body" "IGNORE_ME")"
check "real user text retained"    yes "$(has "$body" "KEEP_ME")"
rm -rf "$repo"

# --- Tool result truncation (.[0:800]) --------------------------------------
# content = HEADMARK + 900 filler + TAILMARK (len 916). After the .[0:800]
# slice, HEADMARK (at the front) survives and TAILMARK (at the end) is dropped.
# Position markers avoid counting chars that also appear in the mktemp path.
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; tx="$repo/tx.jsonl"
fill="$(printf 'a%.0s' $(seq 1 900))"
content="HEADMARK${fill}TAILMARK"
printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"%s"}]}}\n' "$content" > "$tx"
run_turn "$repo" TR "$tx"
body="$(cat "$bd/handoff_raw_TR.md")"
check "tool result head kept"           yes "$(has "$body" "HEADMARK")"
check "tool result tail truncated off"  no  "$(has "$body" "TAILMARK")"
rm -rf "$repo"

# --- Not a git repo -> exit 0, no backups -----------------------------------
notrepo="$(mktemp -d)"; tx="$notrepo/tx.jsonl"
printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx"
run_turn "$notrepo" NR "$tx"; rc=$?
check "non-repo -> exit 0"            0  "$rc"
check "non-repo -> no backups dir"    no "$([[ -d "$notrepo/.claude/handoff_backups" ]] && echo yes || echo no)"
rm -rf "$notrepo"

# --- Missing transcript file -> exit 0, no dump -----------------------------
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"
run_turn "$repo" MISS "$repo/does-not-exist.jsonl"; rc=$?
check "missing transcript -> exit 0"     0  "$rc"
check "missing transcript -> no dump"    no "$([[ -f "$bd/handoff_raw_MISS.md" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- session_id validation: malformed IDs are rejected, never path-injected --
# session_id is interpolated into dump/cursor/lock/ctx file paths, so a value
# with a newline, slash, or ".." must be refused before any file is touched.
# run_turn uses printf "%s" so these reach the hook verbatim.

# Newline-injection: the realistic vector is VALID JSON whose session_id value
# carries an escaped \n that jq decodes into a real newline. Single-quoted here,
# so run_turn's printf emits a literal backslash-n into the JSON; jq turns it
# into a newline-bearing value our regex guard must reject. Exit clean, no file.
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; tx="$repo/tx.jsonl"
printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx"
run_turn "$repo" 'EVIL\nINJECT' "$tx"; rc=$?
check "newline session_id -> exit 0"     0  "$rc"
check "newline session_id -> no dumps"   0  "$(ls "$bd"/handoff_raw_*.md 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$repo"

# Path-traversal: a slash / ".." must not write outside the backup dir.
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; tx="$repo/tx.jsonl"
printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx"
run_turn "$repo" "../../escape" "$tx"; rc=$?
check "traversal session_id -> exit 0"   0  "$rc"
check "traversal session_id -> no escape" no "$([[ -e "$repo/escape.md" || -e "$repo/.claude/escape.md" ]] && echo yes || echo no)"
rm -rf "$repo"

# Positive control: a real UUID-style id (hex + dashes) still produces a dump.
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; tx="$repo/tx.jsonl"
sid="0a1b2c3d-4e5f-6789-abcd-ef0123456789"
printf '{"type":"user","message":{"content":"valid uuid turn"}}\n' > "$tx"
run_turn "$repo" "$sid" "$tx"; rc=$?
check "uuid session_id -> exit 0"        0  "$rc"
check "uuid session_id -> dump created"  yes "$([[ -f "$bd/handoff_raw_${sid}.md" ]] && echo yes || echo no)"
rm -rf "$repo"

finish
