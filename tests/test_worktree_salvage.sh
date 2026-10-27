#!/usr/bin/env bash
# Worktree salvage (#142). Under the desktop-app environment (CLAUDE_PROJECT_DIR
# = main checkout, payload cwd = linked worktree, process cwd = main) the hooks
# must follow the worktree, and the SessionEnd/PreCompact safety net plus the
# WorktreeRemove hook must salvage an uncurated worktree session's raw dump
# (and a curated doc) into the main checkout's .claude/handoff_history/worktrees/
# as never-overwritten, deduplicated reference data that the main checkout's
# SessionStart then lists with a pointer to /handoff-recover.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
SS="$REPO_ROOT/bin/handoff_session_start.sh"
WR="$REPO_ROOT/bin/handoff_worktree_remove.sh"
TA="$REPO_ROOT/bin/handoff_turn_append.sh"
SENTINEL="<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->"
RAW_RE='^raw_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}(_[0-9]+)?__[A-Za-z0-9.-]+__[A-Za-z0-9.-]+__[A-Za-z0-9_-]{1,8}\.md$'

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
yn() { if "$@"; then echo yes; else echo no; fi; }
fsum() { cksum < "$1" 2>/dev/null; }
exists() { if [[ -e "$1" ]]; then echo yes; else echo no; fi; }

# Skill-style write (no CLAUDE_PROJECT_DIR, anchored on the cwd) and restamp.
write() { ( cd "$1" && env -u CLAUDE_PROJECT_DIR bash "$WH" </dev/null >/dev/null 2>&1 ); }
restamp() { ( cd "$1" && env -u CLAUDE_PROJECT_DIR bash "$WH" --restamp </dev/null >/dev/null 2>&1 ); }
curate() {  # <doc> <note>
  # shellcheck disable=SC2016  # awk program: $0 is awk's
  must awk -v s="$SENTINEL" -v n="$2" '
    $0 == s { print n; next }
    index($0, "<!-- HANDOFF_RULES_PLACEHOLDER") == 1 { print "- RULE: fence from " n; next }
    { print }' "$1" > "$1.tmp"
  must mv "$1.tmp" "$1"
}
# Desktop-shaped SessionEnd / PreCompact fire: process cwd = main, payload cwd
# = worktree, CLAUDE_PROJECT_DIR = main. Echoes the hook's stderr.
session_end() {  # <main> <worktree> <sid> [reason]
  # shellcheck disable=SC2069  # deliberate: stderr is the product, the doc path on stdout is dropped
  ( cd "$1" && printf '{"session_id":"%s","reason":"%s","cwd":"%s"}' "$3" "${4:-other}" "$2" \
      | env CLAUDE_PROJECT_DIR="$1" bash "$WH" --if-curated 2>&1 >/dev/null )
}
worktree_remove() {  # <main> <worktree_path> [extra env...]; stdout+stderr separated by a marker
  local m="$1" w="$2"; shift 2
  ( cd "$m" && printf '{"session_id":"removed","cwd":"%s","worktree_path":"%s"}' "$m" "$w" \
      | env CLAUDE_PROJECT_DIR="$m" "$@" bash "$WR" 2>"$m/.wr_err" )
}
run_ss() { ( cd "$1" && env CLAUDE_PROJECT_DIR="$1" bash "$SS" </dev/null 2>/dev/null ); }
raws() { find "$1/.claude/handoff_history/worktrees" -maxdepth 1 -type f -name 'raw_*.md' 2>/dev/null | LC_ALL=C sort; }
raw_count() { raws "$1" | grep -c . || true; }
copy_count() { find "$1/.claude/handoff_history/worktrees" -maxdepth 1 -type f -name 'handoff_*.md' 2>/dev/null | grep -c . || true; }
mk_dump() {  # <worktree> <sid> <text>
  must mkdir -p "$1/.claude/handoff_backups"
  must printf '# Raw session dump (session %s)\n\n## Turn at 2026-10-27 10:00:00\n\n%s\n' "$2" "$3" \
    > "$1/.claude/handoff_backups/handoff_raw_$2.md"
}

# A main checkout that ignores .claude/ with its own curated, signed handoff,
# and a linked worktree in the desktop app's place (.claude/worktrees/<name>).
mk_main() {
  local m
  m="$(mk_repo)" || return 1
  printf '.claude/\n' > "$m/.gitignore"
  git -C "$m" add .gitignore && git -C "$m" commit -qm "ignore .claude" || return 1
  write "$m"
  curate "$m/.claude/handoff_current.md" "MAIN CHECKOUT NOTE"
  restamp "$m"
  printf '%s\n' "$m"
}
mk_wt() {  # <main> [name] [branch] -> worktree path
  local n="${2:-wt-x}" b="${3:-feat/wt-x}"
  mkdir -p "$1/.claude/worktrees" || return 1
  git -C "$1" worktree add -q "$1/.claude/worktrees/$n" -b "$b" >/dev/null 2>&1 || return 1
  printf '%s\n' "$1/.claude/worktrees/$n"
}

echo "worktree salvage: SessionEnd in a desktop worktree session"

main="$(mk_main)"; wt="$(mk_wt "$main")"
cleanup_on_exit "$main"
must test -f "$main/.claude/handoff_current.md"
main_sum="$(fsum "$main/.claude/handoff_current.md")"
mk_dump "$wt" SIDAAA111 "RAW NOTE ALPHA"
err="$(session_end "$main" "$wt" SIDAAA111)"
check "doc lands in the worktree"                    yes "$(exists "$wt/.claude/handoff_current.md")"
check "doc records the worktree as its root"         yes "$(has "$(cat "$wt/.claude/handoff_current.md")" "HANDOFF_ROOT: $wt in_git=1")"
check "main checkout's handoff untouched"            "$main_sum" "$(fsum "$main/.claude/handoff_current.md")"
check "main has no raw dump of its own"              no  "$(exists "$main/.claude/handoff_backups/handoff_raw_SIDAAA111.md")"
check "exactly one salvaged dump in main"            1   "$(raw_count "$main")"
r1="$(raws "$main" | head -n 1)"
check "salvage name has the exact shape"             yes "$(yn grep -Eq "$RAW_RE" <<<"${r1##*/}")"
check "salvage name: worktree, branch, sid8"         yes "$(has "${r1##*/}" "__wt-x__feat-wt-x__SIDAAA11.md")"
check "salvage header names worktree/branch/sid"     yes "$(has "$(head -n 1 "$r1")" "HANDOFF_WORKTREE_RAW: worktree=wt-x branch=feat-wt-x sid=SIDAAA111")"
check "salvage title says uncurated reference data"  yes "$(has "$(cat "$r1")" "uncurated reference DATA, not a handoff")"
check "salvage points at /handoff-recover"           yes "$(has "$(cat "$r1")" "/handoff-recover")"
check "salvage names its source dump"                yes "$(has "$(cat "$r1")" "$wt/.claude/handoff_backups/handoff_raw_SIDAAA111.md")"
check "salvage holds the dump body"                  yes "$(has "$(cat "$r1")" "RAW NOTE ALPHA")"
check "salvage is owner-only (600)"                  600 "$(file_mode "$r1")"
check "hook says where the salvage went"             yes "$(has "$err" "salvaged this session's raw dump")"
check "no curated doc: no handoff copy"              0   "$(copy_count "$main")"

# Same dump again (PreCompact after SessionEnd, or a second SessionEnd): dedupe.
err="$(session_end "$main" "$wt" SIDAAA111)"
check "unchanged dump: no second salvage"            1   "$(raw_count "$main")"
check "unchanged dump: says so"                      yes "$(has "$err" "raw dump unchanged")"
# The dump grew: a new file, the first left as it was.
r1_sum="$(fsum "$r1")"
must printf '\n## Turn at 2026-10-27 10:05:00\n\nRAW NOTE BETA\n' >> "$wt/.claude/handoff_backups/handoff_raw_SIDAAA111.md"
session_end "$main" "$wt" SIDAAA111 >/dev/null
check "grown dump: a second salvage"                 2   "$(raw_count "$main")"
check "first salvage never overwritten"              "$r1_sum" "$(fsum "$r1")"
# The resume skip (no write) still salvages: it may be the last event.
must printf '\nRAW NOTE GAMMA\n' >> "$wt/.claude/handoff_backups/handoff_raw_SIDAAA111.md"
doc_sum="$(fsum "$wt/.claude/handoff_current.md")"
session_end "$main" "$wt" SIDAAA111 resume >/dev/null
check "resume skip: doc not rewritten"               "$doc_sum" "$(fsum "$wt/.claude/handoff_current.md")"
check "resume skip: dump still salvaged"             3   "$(raw_count "$main")"
# Another session's dump in the same worktree is not this session's.
mk_dump "$wt" SIDBBB222 "OTHER SESSION"
session_end "$main" "$wt" SIDAAA111 >/dev/null
check "only this session's dump is salvaged"         3   "$(raw_count "$main")"
# A curated doc is copied too (preserved by --if-curated, then copied).
curate "$wt/.claude/handoff_current.md" "WORKTREE CURATED NOTE"
err="$(session_end "$main" "$wt" SIDAAA111)"
check "curated doc preserved"                        yes "$(has "$(cat "$wt/.claude/handoff_current.md")" "WORKTREE CURATED NOTE")"
check "curated doc copied to main"                   1   "$(copy_count "$main")"
check "hook says where the copy went"                yes "$(has "$err" "also saved a copy for sessions in the main checkout")"
check "main checkout's handoff still untouched"      "$main_sum" "$(fsum "$main/.claude/handoff_current.md")"

echo "worktree salvage: never on the skill path, never in the main checkout"

m2="$(mk_main)"; w2="$(mk_wt "$m2" wt-skill feat/skill)"
cleanup_on_exit "$m2"
mk_dump "$w2" SIDSKILL1 "SKILL PATH DUMP"
( cd "$w2" && env -u CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID=SIDSKILL1 bash "$WH" </dev/null >/dev/null 2>&1 )
check "skill-path write: no salvage"                 0   "$(raw_count "$m2")"
restamp "$w2"
check "skill-path restamp: no salvage"               0   "$(raw_count "$m2")"
mk_dump "$m2" SIDMAIN01 "MAIN DUMP"
( cd "$m2" && printf '{"session_id":"SIDMAIN01","reason":"other","cwd":"%s"}' "$m2" \
    | env CLAUDE_PROJECT_DIR="$m2" bash "$WH" --if-curated >/dev/null 2>&1 )
check "main-checkout SessionEnd: no salvage"         0   "$(raw_count "$m2")"
# HANDOFF_HOOKS_FOLLOW_WORKTREE=0: the old order, the hook resolves main
# (whose curated doc it preserves) and writes nothing into a fresh worktree.
w2b="$(mk_wt "$m2" wt-old feat/old)"
mk_dump "$w2b" SIDOLD001 "OLD ORDER DUMP"
err="$( cd "$m2" && printf '{"session_id":"SIDOLD001","reason":"other","cwd":"%s"}' "$w2b" \
    | env CLAUDE_PROJECT_DIR="$m2" HANDOFF_HOOKS_FOLLOW_WORKTREE=0 HANDOFF_DEBUG=1 bash "$WH" --if-curated 2>&1 >/dev/null )"
check "FOLLOW_WORKTREE=0: resolves the project dir"  yes "$(has "$err" "root=$m2 in_git=1 anchor=$m2 via=project_dir")"
check "FOLLOW_WORKTREE=0: no doc in the worktree"    no  "$(exists "$w2b/.claude/handoff_current.md")"
check "FOLLOW_WORKTREE=0: no salvage"                0   "$(raw_count "$m2")"

echo "worktree salvage: WorktreeRemove hook"

m3="$(mk_main)"; w3="$(mk_wt "$m3" wt-rm feat/rm)"
cleanup_on_exit "$m3"
write "$w3"; curate "$w3/.claude/handoff_current.md" "REMOVED WORKTREE NOTE"
mk_dump "$w3" SIDRM0001 "RM DUMP ONE"
mk_dump "$w3" SIDRM0002 "RM DUMP TWO"
must ln -s "$m3/seed.txt" "$w3/.claude/handoff_backups/handoff_raw_SIDLINK.md"
must touch "$w3/.claude/handoff_backups/handoff_raw_bad name.md"
m3_sum="$(fsum "$m3/.claude/handoff_current.md")"
out="$(worktree_remove "$m3" "$w3")"; rc=$?
err="$(cat "$m3/.wr_err")"
check "remove: exit 0"                               0   "$rc"
check "remove: stdout empty"                         ""  "$out"
check "remove: curated doc copied"                   1   "$(copy_count "$m3")"
check "remove: copy holds the note"                  yes "$(has "$(cat "$m3"/.claude/handoff_history/worktrees/handoff_*.md)" "REMOVED WORKTREE NOTE")"
check "remove: both dumps salvaged"                  2   "$(raw_count "$m3")"
check "remove: dump one"                             yes "$(has "$(cat "$m3"/.claude/handoff_history/worktrees/raw_*__SIDRM000.md)" "RM DUMP ONE")"
check "remove: symlinked dump not salvaged"          no  "$(has "$(ls "$m3/.claude/handoff_history/worktrees")" "SIDLINK")"
check "remove: badly named dump refused"             yes "$(has "$err" "has no usable session id")"
check "remove: main's handoff untouched"             "$m3_sum" "$(fsum "$m3/.claude/handoff_current.md")"
worktree_remove "$m3" "$w3" >/dev/null; rc=$?
check "remove twice: exit 0"                         0   "$rc"
check "remove twice: no duplicate copy"              1   "$(copy_count "$m3")"
check "remove twice: no duplicate dumps"             2   "$(raw_count "$m3")"
# Placeholder doc: not copied, dumps still salvaged.
w3b="$(mk_wt "$m3" wt-ph feat/ph)"
write "$w3b"; mk_dump "$w3b" SIDPH0001 "PH DUMP"
worktree_remove "$m3" "$w3b" >/dev/null
err="$(cat "$m3/.wr_err")"
check "placeholder doc: not copied"                  1   "$(copy_count "$m3")"
check "placeholder doc: says so"                     yes "$(has "$err" "unedited placeholder")"
check "placeholder doc: dump salvaged"               3   "$(raw_count "$m3")"
# jq absent: the no-jq extraction salvages the same way.
if command -v jq >/dev/null 2>&1; then
  shim="$(path_without jq)"; cleanup_on_exit "$shim"
  w3c="$(mk_wt "$m3" wt-nojq feat/nojq)"
  mk_dump "$w3c" SIDNOJQ01 "NOJQ DUMP"
  worktree_remove "$m3" "$w3c" PATH="$shim" >/dev/null; rc=$?
  check "no jq: exit 0"                              0   "$rc"
  check "no jq: dump salvaged"                       4   "$(raw_count "$m3")"
else
  skip "jq already absent; no-jq WorktreeRemove case not isolated"
fi
# Missing path, a non-worktree path, the main checkout itself, no payload.
for bad in "$m3/does-not-exist" "$m3/seed.txt" "$m3" "$(mktemp -d)"; do
  out="$(worktree_remove "$m3" "$bad")"; rc=$?
  check "bad path ($(basename "$bad")): exit 0, silent stdout" "0 " "$rc $out"
done
out="$(printf '' | bash "$WR" 2>/dev/null)"; rc=$?
check "empty payload: exit 0, silent"                "0 " "$rc $out"
out="$(printf '{"session_id":"x"}' | bash "$WR" 2>/dev/null)"; rc=$?
check "no worktree_path: exit 0, silent"             "0 " "$rc $out"
check "bad paths wrote nothing"                      "1 4" "$(copy_count "$m3") $(raw_count "$m3")"
# Refusal: the main checkout does not ignore the folder.
m4="$(mk_repo)"; cleanup_on_exit "$m4"
must mkdir -p "$m4/.claude/worktrees"
must git -C "$m4" worktree add -q "$m4/.claude/worktrees/wt-u" -b wt-u
w4="$m4/.claude/worktrees/wt-u"
write "$w4"; curate "$w4/.claude/handoff_current.md" "UNIGNORED NOTE"; mk_dump "$w4" SIDUN0001 "UNIGNORED DUMP"
out="$(worktree_remove "$m4" "$w4")"; rc=$?
err="$(cat "$m4/.wr_err")"
check "unignored main: exit 0"                       0   "$rc"
check "unignored main: nothing written"              "0 0" "$(copy_count "$m4") $(raw_count "$m4")"
check "unignored main: warns NOT copied"             yes "$(has "$err" "was NOT copied")"
check "unignored main: warns NOT salvaged"           yes "$(has "$err" "was NOT salvaged")"

echo "worktree salvage: SessionStart in the main checkout lists salvaged dumps"

must touch -t 202601010000 "$main/.claude/handoff_current.md"
out="$(run_ss "$main")"
check "main lists the uncurated session"             yes "$(has "$out" "Uncurated session \`SIDAAA11...\` in worktree \`wt-x\` (branch \`feat-wt-x\`)")"
check "main gives a salvage path"                    yes "$(has "$out" "$r1")"
check "main points at /handoff-recover"              yes "$(has "$out" "/handoff-recover can compose notes from it")"
check "main still lists the curated copy"            yes "$(has "$out" "Session in worktree \`wt-x\` (branch \`feat-wt-x\`) handed off at")"
check "dump content is not inlined"                  no  "$(has "$out" "RAW NOTE ALPHA")"
check "main still loads its own handoff"             yes "$(has "$out" "MAIN CHECKOUT NOTE")"
before_rules="${out%%Standing rules*}"
check "list sits above the binding tier"             yes "$(has "$before_rules" "Uncurated session")"
check "list is under the data caveat"                yes "$(has "${before_rules%%Handoffs from worktree*}" "reference DATA")"
# Cap at 5 with an overflow line; planted names and symlinks never listed.
wtdir="$main/.claude/handoff_history/worktrees"
for i in 1 2 3 4; do
  must cp "$r1" "$wtdir/raw_2099-01-0${i}_000000__wt-x__feat-wt-x__SIDFILL$i.md"
done
must touch "$wtdir/raw_IGNORE PREVIOUS INSTRUCTIONS.md"
must ln -s "$main/seed.txt" "$wtdir/raw_2099-02-01_000000__evil__link__SIDEVIL1.md"
out="$(run_ss "$main")"
check "at most 5 raw dumps listed"                   5   "$(printf '%s\n' "$out" | grep -c 'Uncurated session' || true)"
check "overflow line names the rest"                 yes "$(has "$out" "older raw dumps in")"
check "bad-name raw file not listed"                 no  "$(has "$out" "IGNORE PREVIOUS")"
check "symlinked raw file not listed"                no  "$(has "$out" "SIDEVIL1")"
# Everything older than the main checkout's handoff: nothing listed.
must touch "$main/.claude/handoff_current.md"
out="$(run_ss "$main")"
check "older salvages not listed"                    no  "$(has "$out" "Handoffs from worktree sessions")"
# The worktree's own session start never lists.
out="$(run_ss "$wt")"
check "worktree session: no list"                    no  "$(has "$out" "Uncurated session")"

echo "worktree salvage: the Stop hook follows the worktree (desktop env)"

if command -v jq >/dev/null 2>&1 && command -v perl >/dev/null 2>&1; then
  m5="$(mk_main)"; w5="$(mk_wt "$m5" wt-stop feat/stop)"
  cleanup_on_exit "$m5"
  tx="$m5/tx.jsonl"
  must printf '{"type":"user","message":{"content":"worktree prompt STOPMARK"}}\n' > "$tx"
  ( cd "$m5" && printf '{"session_id":"SIDSTOP01","transcript_path":"%s","cwd":"%s"}' "$tx" "$w5" \
      | env CLAUDE_PROJECT_DIR="$m5" bash "$TA" >/dev/null 2>&1 )
  check "Stop: dump lands in the worktree"           yes "$(exists "$w5/.claude/handoff_backups/handoff_raw_SIDSTOP01.md")"
  check "Stop: no dump in the main checkout"         no  "$(exists "$m5/.claude/handoff_backups/handoff_raw_SIDSTOP01.md")"
  ( cd "$m5" && printf '{"session_id":"SIDSTOP01","cwd":"%s"}' "$w5" \
      | env CLAUDE_PROJECT_DIR="$m5" bash "$SS" >/dev/null 2>&1 )
  check "SessionStart: origin marker in the worktree" yes "$(exists "$w5/.claude/handoff_backups/.session_started_SIDSTOP01")"
  check "SessionStart: none in the main checkout"     no  "$(exists "$m5/.claude/handoff_backups/.session_started_SIDSTOP01")"
  session_end "$m5" "$w5" SIDSTOP01 >/dev/null
  check "SessionEnd: the Stop dump is salvaged"      yes "$(has "$(cat "$m5"/.claude/handoff_history/worktrees/raw_*__SIDSTOP0.md)" "STOPMARK")"
else
  skip "jq or perl missing; Stop-hook end-to-end case not run"
fi

finish
