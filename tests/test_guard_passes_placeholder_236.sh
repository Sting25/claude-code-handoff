#!/usr/bin/env bash
# Coverage for issue #236: the cross-session overwrite guard (#63) refused a
# parent session's /handoff (exit 3) after a child session had ended and left
# a safety-net placeholder.
#
# Why this changed: the guard protects a LATER session's curated handoff from
# an older, resumed session. A desktop sub-session or /btw fork opened from a
# long-running session is a later session too, and when it ends without
# /handoff its SessionEnd writes a placeholder under its own id. The parent,
# which holds the real context, was then the one refused, with --takeover as
# the only way through. A placeholder has no curated content to protect, so
# the guard no longer fires for one. It still fires for curated Notes, for
# Rules curated in that later doc itself, and for carried-forward Rules when
# history is off (nothing would archive them).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
SENTINEL="<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->"
GUARD="CROSS-SESSION OVERWRITE GUARD"
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
plant_doc() {  # <repo> <sid> <t> <notes_body>
  mkdir -p "$1/.claude"
  {
    printf '# handoff\n\n'
    printf '<!-- HANDOFF_WRITER: sid=%s t=%s -->\n\n' "$2" "$3"
    printf '## Notes from this session\n\n%s\n' "$4"
  } > "$1/.claude/handoff_current.md"
}
sub_line() { sed "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
writer_of() { sed -nE 's/^<!-- HANDOFF_WRITER: sid=([A-Za-z0-9_-]+) t=[0-9]+ -->$/\1/p' "$1/.claude/handoff_current.md" 2>/dev/null | tail -n 1; }
hist_count() { find "$1/.claude/handoff_history" -maxdepth 1 -name 'handoff_*.md' -type f 2>/dev/null | wc -l | tr -d ' '; }
hist_has() { grep -rqF "$2" "$1/.claude/handoff_history" 2>/dev/null && echo yes || echo no; }
# run <repo> [env...] -- <write_handoff args>: stderr on stdout, rc in $rc.
run() {
  local d="$1"; shift
  local envs=()
  while [[ "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  rc=0
  err="$( cd "$d" && env HANDOFF_SECRET_FILE="$d/.secret" ${envs[@]+"${envs[@]}"} bash "$WH" "$@" 2>&1 >/dev/null )" || rc=$?
}

echo "write_handoff.sh: the overwrite guard does not fire for a later session's uncurated placeholder (issue #236)"

# --- 1: the issue's scenario, through real writes. Parent A starts, child B
#        starts later and ends without /handoff, then A runs /handoff. -------
repo="$(mk_repo_gitignored)"
plant_origin "$repo" sidA 500
plant_origin "$repo" sidB 600
run "$repo" -- --if-curated --session-id sidB
check "1: child's safety net -> exit 0" 0 "$rc"
check "1: child's safety net -> placeholder authored by the child" sidB "$(writer_of "$repo")"
check "1: fixture really is a placeholder" yes "$(has "$(cat "$repo/.claude/handoff_current.md")" "$SENTINEL")"
run "$repo" -- --session-id sidA
check "1: parent's write -> exit 0 (was 3)" 0 "$rc"
check "1: parent's write -> no guard block" no "$(has "$err" "$GUARD")"
check "1: parent's write -> one-line note names the child" yes "$(has "$err" "later session (sidB) but holds only an uncurated placeholder")"
check "1: parent's write -> doc now authored by the parent" sidA "$(writer_of "$repo")"
check "1: parent's write -> the placeholder is not archived" 0 "$(hist_count "$repo")"
rm -rf "$repo"

# --- 2: the parent's own placeholder (its PreCompact) is replaced by the
#        child's, then the parent writes. --------------------------------------
repo="$(mk_repo_gitignored)"
plant_origin "$repo" sidA 500
run "$repo" -- --if-curated --session-id sidA
check "2: parent's own placeholder first" sidA "$(writer_of "$repo")"
t="$(sed -nE 's/^<!-- HANDOFF_WRITER: sid=sidA t=([0-9]+) -->$/\1/p' "$repo/.claude/handoff_current.md" | tail -n 1)"
plant_origin "$repo" sidB "$(( ${t:-0} + 1000 ))"
run "$repo" -- --if-curated --session-id sidB
check "2: child's safety net takes the doc over" sidB "$(writer_of "$repo")"
run "$repo" -- --session-id sidA
check "2: parent's write -> exit 0 (was 3)" 0 "$rc"
check "2: parent's write -> doc authored by the parent" sidA "$(writer_of "$repo")"
rm -rf "$repo"

# --- 3: the guard still fires for a later session's CURATED Notes. ----------
repo="$(mk_repo_gitignored)"
plant_doc "$repo" sidB 3000 "curated notes KEEPME3"
plant_origin "$repo" sidA 500
run "$repo" -- --session-id sidA
check "3: later curated Notes -> exit 3" 3 "$rc"
check "3: later curated Notes -> guard block printed" yes "$(has "$err" "$GUARD")"
check "3: later curated Notes -> doc untouched" yes "$(has "$(cat "$repo/.claude/handoff_current.md")" KEEPME3)"
rm -rf "$repo"

# --- 4: curated Notes that QUOTE the placeholder sentinel are still curated:
#        the check is by position under the heading, not by substring. -------
repo="$(mk_repo_gitignored)"
plant_doc "$repo" sidB 3000 "$(printf 'curated notes KEEPME4\n\n%s' "$SENTINEL")"
plant_origin "$repo" sidA 500
run "$repo" -- --session-id sidA
check "4: curated Notes quoting the sentinel -> exit 3" 3 "$rc"
check "4: curated Notes quoting the sentinel -> doc untouched" yes "$(has "$(cat "$repo/.claude/handoff_current.md")" KEEPME4)"
rm -rf "$repo"

# --- 5: placeholder Notes but Rules curated IN that later doc -> still fires:
#        those fences exist nowhere else. ------------------------------------
repo="$(mk_repo_gitignored)"
plant_origin "$repo" sidA 500
run "$repo" -- --session-id sidB
sub_line "$repo/.claude/handoff_current.md" "s/<!-- HANDOFF_RULES_PLACEHOLDER.*-->/- Do NOT touch prod. OWNFENCE5/"
run "$repo" -- --restamp
check "5: fixture -> Notes still the placeholder" yes "$(has "$(cat "$repo/.claude/handoff_current.md")" "$SENTINEL")"
run "$repo" -- --session-id sidA
check "5: later doc with its own curated Rules -> exit 3" 3 "$rc"
check "5: later doc with its own curated Rules -> fence untouched" yes "$(has "$(cat "$repo/.claude/handoff_current.md")" OWNFENCE5)"
rm -rf "$repo"

# Build the shape a fenced project is left in after a child ends: an earlier
# session C curated a fence (signed), then child B's safety net took the
# stale-refresh path (#125) and wrote placeholder Notes with C's fence CARRIED.
mk_carried_only() {  # <repo> <fence_text>
  local d="$1" doc="$1/.claude/handoff_current.md" t
  run "$d" -- --session-id sidC
  sub_line "$doc" "s/<!-- HANDOFF_RULES_PLACEHOLDER.*-->/- $2/"
  run "$d" -- --restamp
  t="$(sed -nE 's/^<!-- HANDOFF_WRITER: sid=sidC t=([0-9]+) -->$/\1/p' "$doc" | tail -n 1)"
  plant_origin "$d" sidB "$(( ${t:-0} + 1000 ))"
  run "$d" -- --if-curated --session-id sidB
}

# --- 6: carried-only doc by the child, history kept -> parent's write passes
#        and the carried fence is archived, not lost. ------------------------
repo="$(mk_repo_gitignored)"
plant_origin "$repo" sidA 500
mk_carried_only "$repo" "Do NOT touch prod. CARRYFENCE6"
cur="$(cat "$repo/.claude/handoff_current.md")"
check "6: fixture -> authored by the child" sidB "$(writer_of "$repo")"
check "6: fixture -> carries the fence with the carried marker" yes "$(has "$cur" "HANDOFF_RULES_CARRIED")"
check "6: fixture -> fence text present" yes "$(has "$cur" CARRYFENCE6)"
check "6: fixture -> Notes are the placeholder" yes "$(has "$cur" "$SENTINEL")"
before="$(hist_count "$repo")"
run "$repo" -- --session-id sidA
check "6: parent's write -> exit 0 (was 3)" 0 "$rc"
check "6: parent's write -> no guard block" no "$(has "$err" "$GUARD")"
check "6: parent's write -> note says archived" yes "$(has "$err" "carried-forward Rules; archiving it")"
check "6: parent's write -> doc authored by the parent" sidA "$(writer_of "$repo")"
check "6: parent's write -> one more file in history" "$(( before + 1 ))" "$(hist_count "$repo")"
check "6: parent's write -> the child's carried doc is in history" yes \
  "$(grep -rlF 'HANDOFF_WRITER: sid=sidB ' "$repo/.claude/handoff_history" 2>/dev/null | xargs grep -lF CARRYFENCE6 2>/dev/null | grep -q . && echo yes || echo no)"
rm -rf "$repo"

# --- 7: same doc, HANDOFF_HISTORY_KEEP=0 on the parent's write -> still
#        refused: nothing would archive the carried fence. -------------------
repo="$(mk_repo_gitignored)"
plant_origin "$repo" sidA 500
mk_carried_only "$repo" "Do NOT touch prod. CARRYFENCE7"
run "$repo" HANDOFF_HISTORY_KEEP=0 -- --session-id sidA
check "7: carried-only + KEEP=0 -> exit 3" 3 "$rc"
check "7: carried-only + KEEP=0 -> guard block printed" yes "$(has "$err" "$GUARD")"
check "7: carried-only + KEEP=0 -> doc untouched" yes "$(has "$(cat "$repo/.claude/handoff_current.md")" CARRYFENCE7)"
check "7: carried-only + KEEP=0 -> still authored by the child" sidB "$(writer_of "$repo")"
rm -rf "$repo"

# --- 8: HANDOFF_OVERWRITE_GUARD modes are unchanged for a curated later doc,
#        and a placeholder prints no guard block in warn mode either. --------
repo="$(mk_repo_gitignored)"
plant_doc "$repo" sidB 3000 "$SENTINEL"
plant_origin "$repo" sidA 500
run "$repo" HANDOFF_OVERWRITE_GUARD=warn -- --session-id sidA
check "8: warn + placeholder -> exit 0" 0 "$rc"
check "8: warn + placeholder -> no guard block" no "$(has "$err" "$GUARD")"
rm -rf "$repo"

# --- 9: a normal succession over a placeholder (doc OLDER than this
#        session's start) stays silent: no note, as before. ------------------
repo="$(mk_repo_gitignored)"
plant_doc "$repo" sidB 1000 "$SENTINEL"
plant_origin "$repo" sidA 2000
run "$repo" -- --session-id sidA
check "9: normal succession over a placeholder -> exit 0" 0 "$rc"
check "9: normal succession over a placeholder -> no overwrite-guard line" no "$(has "$err" "overwrite guard")"
rm -rf "$repo"

finish
