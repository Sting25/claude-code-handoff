#!/usr/bin/env bash
# Coverage for issue #125: a curated handoff_current.md went stale forever.
#
# Root cause: SessionEnd/PreCompact run `write_handoff.sh --if-curated`, and
# once ANY session ran /handoff and left curated Notes (or curated Rules) in
# handoff_current.md, every LATER session that ended WITHOUT running
# /handoff hit the --if-curated "curated -> preserve, don't overwrite" branch
# forever: the doc was curated, so it was always preserved, no matter how
# many sessions passed or how old it got. Measured on a real repo: 7
# sessions, 0 refreshes, an 11-day-old handoff still loaded as "current".
#
# The fix (see write_handoff.sh's --if-curated block and prune_history, and
# handoff_session_start.sh's placeholder fallback) is three-part:
#   1. --if-curated now falls through to a normal write (rotating the
#      curated doc into handoff_history/) when the doc's HANDOFF_WRITER
#      marker names an EARLIER session than the one running now (i.e. THIS
#      session never curated it, so there is nothing of this session's own
#      to lose by refreshing). A doc newer than this session's origin
#      (concurrent curation) is still preserved untouched, same as before.
#   2. prune_history() never deletes the newest CURATED history snapshot,
#      so a run of uncurated safety-net rotations after the stale-refresh
#      can't prune away the one curated snapshot worth keeping.
#   3. handoff_session_start.sh's placeholder fallback now walks history for
#      the newest CURATED snapshot, not just the newest file, so it can find
#      real curated prose behind any number of uncurated rotations.
#
# This file does not re-test the #63 overwrite guard itself (a different
# guard, over a different predicate): see test_write_handoff_overwrite_
# guard.sh, whose case 7a is the regression pin for "concurrent curation
# stays preserved" and must keep passing unchanged.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
SS="$REPO_ROOT/bin/handoff_session_start.sh"
SENTINEL="<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->"

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

mk_repo_gitignored() {
  local d; d="$(mk_repo)"
  printf '.claude/\n' > "$d/.gitignore"
  git -C "$d" add .gitignore
  git -C "$d" commit -qm "ignore .claude"
  printf '%s\n' "$d"
}

# Hand-plant a handoff_current.md carrying a specific HANDOFF_WRITER marker,
# mirroring test_write_handoff_overwrite_guard.sh's plant_doc so the two
# suites read the same way. curated=yes writes non-placeholder Notes AND a
# curated (non-placeholder) Rules bind region, so the doc reads as curated
# on BOTH axes --if-curated checks.
plant_doc() {  # <repo> <marker_line> <curated:yes|no> [unique_text]
  local repo="$1" marker="$2" curated="$3" uniq="${4:-}"
  mkdir -p "$repo/.claude"
  {
    printf '# handoff\n\n'
    printf '%s\n\n' "$marker"
    printf '## Notes from this session\n\n'
    if [[ "$curated" == yes ]]; then
      printf 'curated notes %s\n' "$uniq"
    else
      printf '%s\n' "$SENTINEL"
    fi
  } > "$repo/.claude/handoff_current.md"
}

writer_marker() { printf '<!-- HANDOFF_WRITER: sid=%s t=%s -->' "$1" "$2"; }

plant_origin() {  # <repo> <sid> <epoch>
  mkdir -p "$1/.claude/handoff_backups"
  printf '%s\n' "$3" > "$1/.claude/handoff_backups/.session_started_${2}"
}

hist_count() { find "$1/.claude/handoff_history" -maxdepth 1 -name 'handoff_*.md' -type f 2>/dev/null | wc -l | tr -d ' '; }

# A plain non-placeholder history/current fixture (no HANDOFF_WRITER marker
# needed for these: the placeholder check only looks at the Notes header).
curated_body() { printf '# handoff\n\n## Notes from this session\n\ncurated notes %s\n' "$1"; }
placeholder_body() { printf '# handoff\n\n## Notes from this session\n\n%s\n' "$SENTINEL"; }

echo "write_handoff.sh / handoff_session_start.sh: curated staleness (issue #125)"

# --- 1: stale curated (doc t < this session's origin, different sid) -------
#        refreshed: falls through to a normal write, old curated doc rotated
#        into handoff_history/ rather than preserved forever. -------------
repo="$(mk_repo_gitignored)"
plant_doc "$repo" "$(writer_marker sidB 100)" yes MARKERSTALE1
plant_origin "$repo" sidA 5000     # sidA's origin (5000) is AFTER the doc's write (100)
before_hist="$(hist_count "$repo")"
rc=0
out="$( cd "$repo" && bash "$WH" --if-curated --session-id sidA 2>/dev/null )"; rc=$?
check "1: stale refresh -> exit 0" 0 "$rc"
check "1: stale refresh -> stdout is the path" yes "$(has "$out" "handoff_current.md")"
check "1: stale refresh -> current no longer carries the stale curated marker" no \
  "$(has "$(cat "$repo/.claude/handoff_current.md")" "MARKERSTALE1")"
check "1: stale refresh -> current is a fresh placeholder" yes \
  "$(has "$(cat "$repo/.claude/handoff_current.md")" "$SENTINEL")"
check "1: stale refresh -> old curated doc archived to history" yes \
  "$(grep -rq 'MARKERSTALE1' "$repo/.claude/handoff_history" 2>/dev/null && echo yes || echo no)"
check "1: stale refresh -> history grew by one" $((before_hist + 1)) "$(hist_count "$repo")"
rm -rf "$repo"

# --- 2: concurrent (doc t > this session's origin) preserved byte-for-byte -
#        a session that curated DURING this session's lifetime must never
#        be clobbered by this session's own safety-net write. --------------
repo="$(mk_repo_gitignored)"
plant_doc "$repo" "$(writer_marker sidB 9000)" yes MARKERCONCURRENT
plant_origin "$repo" sidA 500      # sidA's origin (500) is BEFORE the doc's write (9000)
before="$(cat "$repo/.claude/handoff_current.md")"
before_hist="$(hist_count "$repo")"
rc=0
out="$( cd "$repo" && bash "$WH" --if-curated --session-id sidA 2>/dev/null )"; rc=$?
check "2: concurrent -> exit 0" 0 "$rc"
check "2: concurrent -> doc untouched (byte-for-byte)" "$before" "$(cat "$repo/.claude/handoff_current.md")"
check "2: concurrent -> no rotation happened" "$before_hist" "$(hist_count "$repo")"
rm -rf "$repo"

# --- 3: same-sid (this session IS the doc's author) preserved --------------
#        the doc's author == writer_session_id, so it can never be "another
#        session's" stale content: preserve exactly as before #125. -------
repo="$(mk_repo_gitignored)"
plant_doc "$repo" "$(writer_marker sidA 100)" yes MARKERSAMESID
plant_origin "$repo" sidA 5000
before="$(cat "$repo/.claude/handoff_current.md")"
rc=0
out="$( cd "$repo" && bash "$WH" --if-curated --session-id sidA 2>/dev/null )"; rc=$?
check "3: same-sid -> exit 0" 0 "$rc"
check "3: same-sid -> doc untouched (byte-for-byte)" "$before" "$(cat "$repo/.claude/handoff_current.md")"
rm -rf "$repo"

# --- 4: missing origin sidecar -> preserved (fail open) --------------------
repo="$(mk_repo_gitignored)"
plant_doc "$repo" "$(writer_marker sidB 100)" yes MARKERNOORIGIN
before="$(cat "$repo/.claude/handoff_current.md")"
rc=0
out="$( cd "$repo" && bash "$WH" --if-curated --session-id sidA 2>/dev/null )"; rc=$?
check "4: missing origin -> exit 0" 0 "$rc"
check "4: missing origin -> doc untouched (byte-for-byte)" "$before" "$(cat "$repo/.claude/handoff_current.md")"
rm -rf "$repo"

# --- 5: missing/malformed HANDOFF_WRITER marker -> preserved (fail open) ---
repo="$(mk_repo_gitignored)"
mkdir -p "$repo/.claude"
curated_body MARKERNOMARKER > "$repo/.claude/handoff_current.md"   # no marker line at all
plant_origin "$repo" sidA 5000
before="$(cat "$repo/.claude/handoff_current.md")"
rc=0
out="$( cd "$repo" && bash "$WH" --if-curated --session-id sidA 2>/dev/null )"; rc=$?
check "5: missing marker -> exit 0" 0 "$rc"
check "5: missing marker -> doc untouched (byte-for-byte)" "$before" "$(cat "$repo/.claude/handoff_current.md")"
rm -rf "$repo"

# --- 6: SessionStart loader still finds curated Notes behind two uncurated -
#        foreign-session rotations, and still shows the recover banner ----
#        (handoff_session_start.sh's placeholder fallback must pick the
#        newest CURATED history snapshot, not just the newest file). -------
proj="$(mk_repo_gitignored)"
mkdir -p "$proj/.claude/handoff_history"
placeholder_body > "$proj/.claude/handoff_current.md"    # current: uncurated placeholder
curated_body MARKERCURATEDHIST      > "$proj/.claude/handoff_history/handoff_2026-01-01_000000.md"
placeholder_body                    > "$proj/.claude/handoff_history/handoff_2026-01-02_000000.md"
placeholder_body                    > "$proj/.claude/handoff_history/handoff_2026-01-03_000000.md"
out="$( cd "$proj" && env CLAUDE_PROJECT_DIR="$proj" bash "$SS" </dev/null 2>/dev/null )"; rc=$?
check "6: session start -> exit 0" 0 "$rc"
check "6: session start -> recover banner shown" yes "$(has "$out" "ACTION: RUN /handoff-recover")"
check "6: session start -> loads the curated snapshot" yes "$(has "$out" "MARKERCURATEDHIST")"
rm -rf "$proj"

# --- 7: prune_history with HANDOFF_HISTORY_KEEP=2 and 4 uncurated rotations
#        keeps the curated snapshot even though it's the OLDEST file --------
repo="$(mk_repo_gitignored)"
mkdir -p "$repo/.claude/handoff_history"
curated_body     MARKERKEEPME > "$repo/.claude/handoff_history/handoff_2026-01-01_000000.md"
placeholder_body               > "$repo/.claude/handoff_history/handoff_2026-01-02_000000.md"
placeholder_body               > "$repo/.claude/handoff_history/handoff_2026-01-03_000000.md"
placeholder_body               > "$repo/.claude/handoff_history/handoff_2026-01-04_000000.md"
placeholder_body               > "$repo/.claude/handoff_history/handoff_2026-01-05_000000.md"
# No handoff_current.md: rotate_existing_handoff is then a no-op, isolating
# this case to prune_history()'s own behavior. A plain (non --if-curated)
# run always calls prune_history() at the end.
rc=0
out="$( cd "$repo" && env HANDOFF_HISTORY_KEEP=2 bash "$WH" --session-id sidPrune 2>/dev/null )"; rc=$?
check "7: prune -> exit 0" 0 "$rc"
check "7: prune -> curated snapshot survives despite being oldest" yes \
  "$([[ -f "$repo/.claude/handoff_history/handoff_2026-01-01_000000.md" ]] && echo yes || echo no)"
check "7: prune -> the 2 newest survive" yes \
  "$([[ -f "$repo/.claude/handoff_history/handoff_2026-01-04_000000.md" && -f "$repo/.claude/handoff_history/handoff_2026-01-05_000000.md" ]] && echo yes || echo no)"
check "7: prune -> non-curated middle files pruned" yes \
  "$([[ ! -f "$repo/.claude/handoff_history/handoff_2026-01-02_000000.md" && ! -f "$repo/.claude/handoff_history/handoff_2026-01-03_000000.md" ]] && echo yes || echo no)"
check "7: prune -> exactly 3 files kept (2 + curated)" 3 "$(hist_count "$repo")"
rm -rf "$repo"

finish
