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

# --- Not a git repo -> git-optional: still dumps, anchored on cwd/CLAUDE_PROJECT_DIR.
#     env -u CLAUDE_PROJECT_DIR makes the cwd ($PWD after cd) the anchor so the
#     test is deterministic regardless of the outer environment. ------------
notrepo="$(mktemp -d)"; tx="$notrepo/tx.jsonl"
printf '{"type":"user","message":{"content":"hi NONGITMARK"}}\n' > "$tx"
rc=0
( cd "$notrepo" && printf '{"session_id":"NR","transcript_path":"%s"}' "$tx" \
    | env -u CLAUDE_PROJECT_DIR bash "$TA" >/dev/null 2>&1 ) || rc=$?
ndump="$notrepo/.claude/handoff_backups/handoff_raw_NR.md"
check "non-repo -> exit 0"                       0   "$rc"
check "non-repo (git-optional) -> dump written"  yes "$([[ -f "$ndump" ]] && echo yes || echo no)"
check "non-repo -> dump has content"             yes "$(has "$(cat "$ndump" 2>/dev/null)" "NONGITMARK")"
check "non-repo -> no .gitignore bootstrap"      no  "$([[ -f "$notrepo/.gitignore" ]] && echo yes || echo no)"
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
check "newline session_id -> no dumps"   0  "$(find "$bd" -maxdepth 1 -name 'handoff_raw_*.md' 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$repo"

# Path-traversal: a slash / ".." must not write outside the backup dir.
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; tx="$repo/tx.jsonl"
printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx"
run_turn "$repo" "../../escape" "$tx"; rc=$?
check "traversal session_id -> exit 0"   0  "$rc"
check "traversal session_id -> no escape" no "$([[ -e "$repo/escape.md" || -e "$repo/.claude/escape.md" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- Prune removes the statusline cache sidecar of an evicted session -------
# Three pre-existing sessions with .ctx_sl_ sidecars + one new fire = 4 dumps;
# prune keeps the 3 newest, so OLD1 (oldest) is evicted WITH its sl sidecar.
# OLD3 survives the prune, so its sidecar must too (negative control).
#
# Each fixture dump also gets the companion `.handoff_raw_<id>.cursor` that the
# hook writes beside every dump it creates: since #46 that cursor is the proof
# a dump is OURS to prune, so a cursor-less fixture would model a file the user
# dropped in (correctly preserved) rather than a real session. See
# tests/test_prune_ownership.sh for the negative control on that path.
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; mkdir -p "$bd"; tx="$repo/tx.jsonl"
printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx"
for i in 1 2 3; do
  must eval "echo d > '$bd/handoff_raw_OLD$i.md'; echo s > '$bd/.ctx_sl_OLD$i'; echo 0 > '$bd/.handoff_raw_OLD$i.cursor'"
  # The token-ledger sidecars added by issue #69/#72 (.ctx_flagged_tok_,
  # .fences_tok_) and the jq-missing marker (.ctx_nojq_) previously had no
  # prune coverage at all and accumulated one per session forever.
  must eval "echo f > '$bd/.ctx_flagged_tok_OLD$i'; echo f > '$bd/.fences_tok_OLD$i'; echo n > '$bd/.ctx_nojq_OLD$i'"
  must touch -t "20200101000$i" "$bd/handoff_raw_OLD$i.md"
done
run_turn "$repo" NEWSL "$tx"
check "prune: oldest dump evicted"        no  "$([[ -f "$bd/handoff_raw_OLD1.md" ]] && echo yes || echo no)"
check "prune: evicted .ctx_sl_ removed"   no  "$([[ -f "$bd/.ctx_sl_OLD1" ]] && echo yes || echo no)"
check "prune: surviving .ctx_sl_ kept"    yes "$([[ -f "$bd/.ctx_sl_OLD3" ]] && echo yes || echo no)"
check "prune: evicted .ctx_flagged_tok_ removed" no  "$([[ -f "$bd/.ctx_flagged_tok_OLD1" ]] && echo yes || echo no)"
check "prune: surviving .ctx_flagged_tok_ kept"  yes "$([[ -f "$bd/.ctx_flagged_tok_OLD3" ]] && echo yes || echo no)"
check "prune: evicted .fences_tok_ removed"      no  "$([[ -f "$bd/.fences_tok_OLD1" ]] && echo yes || echo no)"
check "prune: surviving .fences_tok_ kept"       yes "$([[ -f "$bd/.fences_tok_OLD3" ]] && echo yes || echo no)"
check "prune: evicted .ctx_nojq_ removed"        no  "$([[ -f "$bd/.ctx_nojq_OLD1" ]] && echo yes || echo no)"
check "prune: surviving .ctx_nojq_ kept"         yes "$([[ -f "$bd/.ctx_nojq_OLD3" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- REGRESSION (issue #89): embedded-newline dump filename must not redirect
#     the prune loop's deletion to an unintended session's sidecars.
#
#     list_our_dumps() used to consume `LC_ALL=C ls -t ... | while IFS= read
#     -r f`. A single directory entry whose NAME carries a real embedded
#     newline byte prints as two lines of that stream, and each half is
#     re-validated on its own: the first half regains a clean "<dir>/
#     handoff_raw_<id>.md" shape by itself, and the second half (whatever
#     text follows the embedded newline, no directory prefix) is validated
#     purely as a STRING: if it happens to read as "handoff_raw_<some real
#     id>.md" and that id has a real cursor file, it is accepted as an extra,
#     phantom prune candidate for that id, even though the crafted file
#     itself has nothing to do with that id, and even though the real id's
#     own dump is nowhere near its retention cutoff.
#
#     VICTIM here is deliberately the 2nd-newest dump, comfortably inside the
#     keep-3 window on its own merits. The crafted file
#     "handoff_raw_ATTACKER.md\nhandoff_raw_VICTIM.md" (one filename, one
#     embedded newline) is the OLDEST dump present, so under the old code
#     both halves of its split land in the "tail -n +4" prune tail regardless
#     of this defect (same as D2, a legitimate 4th-newest eviction once the
#     live fire below adds a 5th, newer real dump). The defect is what gets
#     destroyed alongside that expected D2 eviction: VICTIM's own cursor and
#     sidecar, via a phantom "handoff_raw_VICTIM.md" line that is bare text,
#     not a real path: `rm -f` on the dump itself silently no-ops (wrong
#     cwd), but the 12 companion-sidecar `rm -f`s that follow are always
#     built from `$backup_dir` plus the id string alone, so they hit
#     VICTIM's REAL sidecars regardless. Confirmed against the pre-fix code
#     (`git show fea99546aa24ce39f2ffe19f9535454120f52cfb:bin/handoff_turn_append.sh`):
#     VICTIM's dump survives that no-op rm, but its cursor and every sidecar
#     are wiped. `find -print0` / `read -rd ''` reads the crafted name as one
#     opaque field instead, so its own id-charset check (which requires the
#     WHOLE string, embedded newline included, to match `^[A-Za-z0-9_-]+$`)
#     rejects it outright: it never contributes any entry, phantom or real.
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; mkdir -p "$bd"; tx="$repo/tx.jsonl"
printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx"

must eval "echo d > '$bd/handoff_raw_VICTIM.md'; echo 0 > '$bd/.handoff_raw_VICTIM.cursor'; echo t > '$bd/.ctx_tokens_VICTIM'"
must touch -t 202506010000 "$bd/handoff_raw_VICTIM.md" "$bd/.handoff_raw_VICTIM.cursor" "$bd/.ctx_tokens_VICTIM"

must eval "echo d > '$bd/handoff_raw_D1.md'; echo 0 > '$bd/.handoff_raw_D1.cursor'"
must touch -t 202505010000 "$bd/handoff_raw_D1.md" "$bd/.handoff_raw_D1.cursor"

must eval "echo d > '$bd/handoff_raw_D2.md'; echo 0 > '$bd/.handoff_raw_D2.cursor'"
must touch -t 202504010000 "$bd/handoff_raw_D2.md" "$bd/.handoff_raw_D2.cursor"

# The crafted file. No cursor of its own: its own id ("ATTACKER") never
# needs to pass ownership, only the phantom second-line reuse of VICTIM's id
# matters here.
craft="$bd/handoff_raw_ATTACKER.md
handoff_raw_VICTIM.md"
must printf '' > "$craft"
must touch -t 202001010000 "$craft"

run_turn "$repo" NEWCRAFT "$tx"; rc=$?
check "newline-in-dump-name: hook still exits 0"              0   "$rc"
check "newline-in-dump-name: VICTIM dump survives"             yes "$([[ -f "$bd/handoff_raw_VICTIM.md" ]] && echo yes || echo no)"
check "newline-in-dump-name: VICTIM cursor survives (pre-fix: deleted)" \
  yes "$([[ -f "$bd/.handoff_raw_VICTIM.cursor" ]] && echo yes || echo no)"
check "newline-in-dump-name: VICTIM sidecar survives (pre-fix: deleted)" \
  yes "$([[ -f "$bd/.ctx_tokens_VICTIM" ]] && echo yes || echo no)"
# Normal retention is unaffected by the fix: D2 (legitimately 4th-newest once
# the live NEWCRAFT fire adds a 5th, newer real dump) is still correctly
# pruned, same as it would be with no crafted file present at all.
check "newline-in-dump-name: normal retention unaffected (D2 still pruned)" \
  no "$([[ -f "$bd/handoff_raw_D2.md" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- .gitignore bootstrap lock (shared with write_handoff.sh) ----------------
# The check-ignore-then-append bootstrap is serialized against write_handoff.sh
# via the shared mkdir lock at .claude/.handoff_gitignore.lock. A held (fresh)
# lock means the peer is mid-bootstrap: this hook must skip the append silently
# and still write the dump. A released lock proceeds, and repeat runs add no
# duplicate line (the check-ignore is re-run under the lock).
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; tx="$repo/tx.jsonl"
printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx"
must mkdir -p "$repo/.claude/.handoff_gitignore.lock"   # fresh mtime = live peer
run_turn "$repo" GILOCK "$tx"
check "held gi-lock: dump still written"    yes "$([[ -f "$bd/handoff_raw_GILOCK.md" ]] && echo yes || echo no)"
check "held gi-lock: bootstrap skipped"     no  "$([[ -f "$repo/.gitignore" ]] && grep -q handoff_backups "$repo/.gitignore" && echo yes || echo no)"
check "held gi-lock: peer's lock left held" yes "$([[ -d "$repo/.claude/.handoff_gitignore.lock" ]] && echo yes || echo no)"
# Peer releases: the next fire bootstraps; further fires add no duplicate.
must rmdir "$repo/.claude/.handoff_gitignore.lock"
printf '{"type":"user","message":{"content":"turn two"}}\n' >> "$tx"
run_turn "$repo" GILOCK "$tx"
check "released gi-lock: bootstrap proceeds"  1  "$(grep -c '^\.claude/handoff_backups/$' "$repo/.gitignore" 2>/dev/null)"
check "released gi-lock: lock released after" no "$([[ -d "$repo/.claude/.handoff_gitignore.lock" ]] && echo yes || echo no)"
printf '{"type":"user","message":{"content":"turn three"}}\n' >> "$tx"
run_turn "$repo" GILOCK "$tx"
check "repeat run: no duplicate .gitignore line" 1 "$(grep -c '^\.claude/handoff_backups/$' "$repo/.gitignore" 2>/dev/null)"
rm -rf "$repo"

# A STALE gi-lock (holder hard-killed mid-append; mtime past the generous
# window) is reclaimed so the bootstrap can't be wedged forever.
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; tx="$repo/tx.jsonl"
printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx"
must mkdir -p "$repo/.claude/.handoff_gitignore.lock"
must touch -t 202001010000 "$repo/.claude/.handoff_gitignore.lock"   # ancient
run_turn "$repo" GISTALE "$tx"
check "stale gi-lock: reclaimed, bootstrap ran" 1  "$(grep -c '^\.claude/handoff_backups/$' "$repo/.gitignore" 2>/dev/null)"
check "stale gi-lock: released after run"       no "$([[ -d "$repo/.claude/.handoff_gitignore.lock" ]] && echo yes || echo no)"
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
