#!/usr/bin/env bash
# Coverage for issue #235: a later session that ended without /handoff
# replaced the curated handoff_current.md with a placeholder.
#
# Why this changed: the #125 stale refresh rotated a curated doc into
# handoff_history/ whenever a session born after it ended without running
# /handoff. Desktop sub-sessions and /btw forks are such sessions, and they
# carry no marker that tells them apart from an ordinary new session
# (measured in #239), so the next real session auto-loaded a placeholder
# where the curated Notes had been.
#
# Owner decision 2026-11-20: curated Notes are never displaced by a
# placeholder. The --if-curated safety net now leaves the document in place
# and inserts one pointer line under the Notes heading naming the later
# session and its raw dump, so that session's work is still discoverable
# (what #125 wanted) without losing the curated Notes. A document whose Notes
# are the placeholder and whose only curated content is Rules keeps the
# #125 behavior (fresh snapshot, Rules carried): see test_curated_staleness.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
SS="$REPO_ROOT/bin/handoff_session_start.sh"
NOTES_H="## Notes from this session"
PTR="HANDOFF_LATER_SESSION"

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

mk_repo_gitignored() {
  local d; d="$(mk_repo)"
  printf '.claude/\n' > "$d/.gitignore"
  git -C "$d" add .gitignore
  git -C "$d" commit -qm "ignore .claude"
  printf '%s\n' "$d"
}
plant_origin() {  # <repo> <sid> <epoch>
  mkdir -p "$1/.claude/handoff_backups"
  printf '%s\n' "$3" > "$1/.claude/handoff_backups/.session_started_${2}"
}
plant_unsigned() {  # <repo> <sid> <t> <notes_text>
  mkdir -p "$1/.claude"
  {
    printf '# handoff\n\n'
    printf '<!-- HANDOFF_WRITER: sid=%s t=%s -->\n\n' "$2" "$3"
    printf '%s\n\n%s\n' "$NOTES_H" "$4"
  } > "$1/.claude/handoff_current.md"
}
hist_count() { find "$1/.claude/handoff_history" -maxdepth 1 -name 'handoff_*.md' -type f 2>/dev/null | wc -l | tr -d ' '; }
ptr_count() { LC_ALL=C grep -c "$PTR" "$1/.claude/handoff_current.md" 2>/dev/null || true; }
# First non-blank line under the Notes heading.
first_notes_line() {
  awk -v h="$NOTES_H" '!s { if ($0 == h) s = 1; next } /^[[:space:]]*$/ { next } { print; exit }' \
    "$1/.claude/handoff_current.md"
}
run_end() {  # <repo> <sid> [env...]
  local d="$1" sid="$2"; shift 2
  ( cd "$d" && env HANDOFF_SECRET_FILE="$d/.secret" "$@" bash "$WH" --if-curated --session-id "$sid" 2>/dev/null )
}

echo "write_handoff.sh: a later uncurated session keeps curated Notes and adds a pointer (issue #235)"

# --- 1: unsigned curated doc, later session ends without /handoff ----------
repo="$(mk_repo_gitignored)"
plant_unsigned "$repo" sidB 100 "curated notes KEEPME1"
plant_origin "$repo" sidA 5000
printf 'raw\n' > "$repo/.claude/handoff_backups/handoff_raw_sidA.md"
rc=0; out="$(run_end "$repo" sidA)" || rc=$?
cur="$(cat "$repo/.claude/handoff_current.md")"
check "1: exit 0" 0 "$rc"
check "1: stdout is the path" yes "$(has "$out" "handoff_current.md")"
check "1: curated Notes still in the current doc" yes "$(has "$cur" KEEPME1)"
check "1: doc still authored by sidB" yes "$(has "$cur" "HANDOFF_WRITER: sid=sidB t=100")"
check "1: nothing rotated into history" 0 "$(hist_count "$repo")"
check "1: one pointer line" 1 "$(ptr_count "$repo")"
check "1: pointer names the later session" yes "$(has "$cur" "sid=sidA")"
check "1: pointer names its raw dump" yes "$(has "$cur" ".claude/handoff_backups/handoff_raw_sidA.md")"
check "1: pointer is the first line under the Notes heading" yes "$(has "$(first_notes_line "$repo")" "sid=sidA")"

# --- 2: same session fires again (PreCompact then SessionEnd) -> no dup -----
run_end "$repo" sidA >/dev/null
check "2: second fire by the same session adds nothing" 1 "$(ptr_count "$repo")"

# --- 3: a second later session adds its own line, Notes still kept ---------
plant_origin "$repo" sidC 6000
run_end "$repo" sidC >/dev/null
cur="$(cat "$repo/.claude/handoff_current.md")"
check "3: second later session -> two pointer lines" 2 "$(ptr_count "$repo")"
check "3: second later session -> Notes still kept" yes "$(has "$cur" KEEPME1)"
check "3: second later session -> still nothing in history" 0 "$(hist_count "$repo")"
check "3: no raw dump on disk -> pointer says so" yes "$(has "$cur" "sid=sidC t=")"
rm -rf "$repo"

# --- 4: concurrent curation (doc newer than this session) is untouched -----
repo="$(mk_repo_gitignored)"
plant_unsigned "$repo" sidB 9000 "curated notes KEEPME4"
plant_origin "$repo" sidA 5000
before="$(cksum < "$repo/.claude/handoff_current.md")"
run_end "$repo" sidA >/dev/null
check "4: doc written during this session's lifetime -> byte-identical" "$before" \
  "$(cksum < "$repo/.claude/handoff_current.md")"
rm -rf "$repo"

# --- 5: the author's own safety net never points at itself -----------------
repo="$(mk_repo_gitignored)"
plant_unsigned "$repo" sidB 100 "curated notes KEEPME5"
plant_origin "$repo" sidB 50
run_end "$repo" sidB >/dev/null
check "5: author's own SessionEnd -> no pointer" 0 "$(ptr_count "$repo")"
rm -rf "$repo"

if ! command -v openssl >/dev/null 2>&1; then
  skip "6-8: openssl not installed, cannot build a signed handoff"
  finish
  exit
fi
BOUND_HDR="Standing rules from your previous session"
sub_line() { sed "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
mk_signed_stale() {  # <repo> <fence_text> <notes_text>
  local d="$1" doc="$1/.claude/handoff_current.md" t
  ( cd "$d" && env HANDOFF_SECRET_FILE="$d/.secret" bash "$WH" --session-id sidB >/dev/null 2>&1 )
  sub_line "$doc" "s/<!-- HANDOFF_RULES_PLACEHOLDER.*-->/- $2/"
  sub_line "$doc" "s/^<!-- HANDOFF_PLACEHOLDER: .*-->\$/$3/"
  ( cd "$d" && env HANDOFF_SECRET_FILE="$d/.secret" bash "$WH" --restamp >/dev/null 2>&1 )
  t="$(sed -nE 's/^<!-- HANDOFF_WRITER: sid=sidB t=([0-9]+) -->$/\1/p' "$doc" | tail -n 1)"
  plant_origin "$d" sidA "$(( ${t:-0} + 1000 ))"
}
run_ss_in() {  # <dir>
  ( cd "$1" && env CLAUDE_PROJECT_DIR="$1" HANDOFF_SECRET_FILE="$1/.secret" \
      bash "$SS" </dev/null 2>/dev/null )
}
binding_has() {  # <ss_output> <needle>
  case "$1" in *"$BOUND_HDR"*) has "${1#*"$BOUND_HDR"}" "$2" ;; *) echo no ;; esac
}

# --- 6: signed curated doc -> Notes kept, pointer added, still binding -----
repo="$(mk_repo_gitignored)"
mk_signed_stale "$repo" "Do NOT touch prod. FENCE6" "KEEPME6"
check "6: fixture -> fence binding before" yes "$(binding_has "$(run_ss_in "$repo")" FENCE6)"
rc=0; run_end "$repo" sidA >/dev/null || rc=$?
cur="$(cat "$repo/.claude/handoff_current.md")"
check "6: exit 0" 0 "$rc"
check "6: curated Notes kept" yes "$(has "$cur" KEEPME6)"
check "6: pointer added" 1 "$(ptr_count "$repo")"
check "6: still authored by sidB" yes "$(has "$cur" "HANDOFF_WRITER: sid=sidB")"
check "6: nothing rotated into history" 0 "$(hist_count "$repo")"
out="$(run_ss_in "$repo")"
check "6: fence still binding after the pointer" yes "$(binding_has "$out" FENCE6)"
check "6: next session loads the curated Notes" yes "$(has "$out" KEEPME6)"
check "6: next session sees the pointer" yes "$(has "$out" "sid=sidA")"
check "6: next session is not told to run /handoff-recover over curated Notes" no \
  "$(has "$out" "ACTION: RUN /handoff-recover")"
rs_err="$( cd "$repo" && env HANDOFF_SECRET_FILE="$repo/.secret" bash "$WH" --restamp 2>&1 >/dev/null )"
check "6: doc passes the restamp skeleton guard" no "$(has "$rs_err" "refusing")"

# --- 7: the author can still run /handoff afterwards (#236 half) ----------
rc=0
( cd "$repo" && env HANDOFF_SECRET_FILE="$repo/.secret" bash "$WH" --session-id sidB >/dev/null 2>&1 ) || rc=$?
check "7: author's later /handoff is not refused" 0 "$rc"
rm -rf "$repo"

# --- 8: signature present but NOT verifiable -> document left untouched ----
#        (inserting a line would turn "tampered" into "tampered plus edited";
#        the curated Notes are preserved either way).
repo="$(mk_repo_gitignored)"
mk_signed_stale "$repo" "Do NOT touch prod. FENCE8" "KEEPME8"
sub_line "$repo/.claude/handoff_current.md" "s/FENCE8/FENCE8 edited/"
before="$(cksum < "$repo/.claude/handoff_current.md")"
rc=0; run_end "$repo" sidA >/dev/null || rc=$?
check "8: exit 0" 0 "$rc"
check "8: unverifiable signed doc -> byte-identical" "$before" "$(cksum < "$repo/.claude/handoff_current.md")"
rm -rf "$repo"

finish
