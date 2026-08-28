#!/usr/bin/env bash
# Behavioral coverage for handoff_session_start.sh's same-sid sidecar mtime
# refresh (issue #86).
#
# The overwrite guard's .session_started_<sid> origin marker (issue #63) can
# legitimately age past the marker-sweep's 7-day horizon (issue #76/#85)
# while its owning session is merely dormant, not dead. Another session's
# SessionStart fire then reaps it as an orphan (that reaper only excludes
# ITS OWN current session id, not every live one). When the dormant session
# later resumes, the create-once block sees no sidecar and recreates one
# stamped with TODAY's epoch, silently moving the origin forward and
# reopening the exact stale-overwrite hole issue #63 closes.
#
# Mitigation: when the create-once block fires for a session id whose
# sidecar ALREADY exists (a same-sid re-fire), refresh only its mtime, never
# its content. The recorded origin epoch stays pinned (guard correctness),
# but the fresher mtime keeps the marker outside every OTHER session's 7-day
# sweep window until this session actually goes dormant for real.
#
# Three things this file proves:
#   1. a same-sid re-fire advances the sidecar's mtime and leaves its content
#      byte-identical.
#   2. that refresh is what saves the marker end to end: a refreshed sidecar
#      survives a later, unrelated session's sweep, while an unrefreshed
#      aged sidecar of the same age does not.
#   3. write_handoff.sh's overwrite guard still fires using the ORIGINAL
#      (pinned) epoch after a refresh: the mtime-only touch cannot be read
#      as a new origin, because the guard prefers sidecar CONTENT whenever
#      that content is a plain integer.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SS="$REPO_ROOT/bin/handoff_session_start.sh"
WH="$REPO_ROOT/bin/write_handoff.sh"
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

mk_project() {  # echoes a fresh project dir with a .claude/handoff_backups/
  local d; d="$(mktemp -d)"; mkdir -p "$d/.claude/handoff_backups"; printf '%s\n' "$d"
}

fire_ss() {  # <project_dir> <session_id>
  ( cd "$1" && env CLAUDE_PROJECT_DIR="$1" bash "$SS" <<<"{\"session_id\":\"$2\"}" >/dev/null 2>/dev/null )
}

# Portable epoch mtime of a path (GNU stat -c first, BSD stat -f fallback),
# same idiom write_handoff.sh itself uses for its own mtime fallback.
mtime_of() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null; }

mk_repo_gitignored() {
  local d; d="$(mk_repo)"
  printf '.claude/\n' > "$d/.gitignore"
  git -C "$d" add .gitignore
  git -C "$d" commit -qm "ignore .claude"
  printf '%s\n' "$d"
}

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
      printf '%s\n' "<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->"
    fi
  } > "$repo/.claude/handoff_current.md"
}

writer_marker() { printf '<!-- HANDOFF_WRITER: sid=%s t=%s -->' "$1" "$2"; }

echo "handoff_session_start.sh: same-sid sidecar mtime refresh (issue #86)"

# --- 1: same-sid re-fire refreshes mtime, content byte-identical -----------
#     Backdate first (a filesystem-granularity-safe method: years apart, not
#     seconds), so the "advanced" check can't pass on coincidence.
proj="$(mk_project)"; bd="$proj/.claude/handoff_backups"
sid="REFIRE1"
must printf '1600000000\n' > "$bd/.session_started_${sid}"
must touch -t 202001010000 "$bd/.session_started_${sid}"
before_mtime="$(mtime_of "$bd/.session_started_${sid}")"
before_bytes="$(cksum "$bd/.session_started_${sid}")"
fire_ss "$proj" "$sid"
after_mtime="$(mtime_of "$bd/.session_started_${sid}")"
after_bytes="$(cksum "$bd/.session_started_${sid}")"
check "1: same-sid re-fire advances mtime" yes \
  "$([[ "$after_mtime" -gt "$before_mtime" ]] && echo yes || echo no)"
check "1: same-sid re-fire leaves content byte-identical" "$before_bytes" "$after_bytes"
rm -rf "$proj"

# --- 2: end to end, the refresh is what saves the marker from a LATER,
#        unrelated session's sweep; an unrefreshed same-age marker is reaped
#        by that same sweep pass. --------------------------------------------
proj="$(mk_project)"; bd="$proj/.claude/handoff_backups"
sidA="ENDTOEND_A"
must printf '1600000000\n' > "$bd/.session_started_${sidA}"
must touch -t 202001010000 "$bd/.session_started_${sidA}"
# Session A resumes past the 7-day horizon: same-sid re-fire refreshes ONLY
# A's mtime (case 1 above, exercised again here to set up the scenario).
fire_ss "$proj" "$sidA"
# A second session that started around the same real time as A originally
# did, but was never resumed again: its marker is still 2020-dated.
sidB="ENDTOEND_B"
must printf '1600000001\n' > "$bd/.session_started_${sidB}"
must touch -t 202001010000 "$bd/.session_started_${sidB}"
# A wholly separate THIRD session starts now and runs the sweep. Neither A
# nor B is its own current-session id, so both are sweep candidates; only
# age (mtime) decides which survives.
fire_ss "$proj" "ENDTOEND_C"
check "2: refreshed marker survives a later, unrelated session's sweep" yes \
  "$([[ -e "$bd/.session_started_${sidA}" ]] && echo yes || echo no)"
check "2: unrefreshed aged marker IS reaped by that same sweep" no \
  "$([[ -e "$bd/.session_started_${sidB}" ]] && echo yes || echo no)"
check "2: survivor's content stays pinned to its original epoch" "1600000000" \
  "$(cat "$bd/.session_started_${sidA}" 2>/dev/null)"
rm -rf "$proj"

# --- 3: write_handoff.sh's overwrite guard still fires with the ORIGINAL
#        (pinned) epoch after a same-sid mtime refresh. The guard reads the
#        sidecar's CONTENT whenever it is a plain integer (its mtime is only
#        a fallback for content that isn't), so a mtime-only touch must not
#        move the effective origin forward. --------------------------------
repo="$(mk_repo_gitignored)"
mkdir -p "$repo/.claude/handoff_backups"
sidA="sidA86"
must printf '500\n' > "$repo/.claude/handoff_backups/.session_started_${sidA}"
must touch -t 202001010000 "$repo/.claude/handoff_backups/.session_started_${sidA}"
# Session A resumes: same-sid re-fire, mtime-only refresh.
fire_ss "$repo" "$sidA"
check "3: refresh left the origin epoch pinned at 500" "500" \
  "$(cat "$repo/.claude/handoff_backups/.session_started_${sidA}" 2>/dev/null)"
# A later session (sidB) wrote a fresher curated doc (t=3000 > origin 500).
plant_doc "$repo" "$(writer_marker sidB 3000)" yes MARKER86
before_cksum="$(cksum "$repo/.claude/handoff_current.md")"
rc=0
err="$( cd "$repo" && bash "$WH" --session-id "$sidA" 2>&1 >/dev/null )"; rc=$?
check "3: guard still fires after mtime-only refresh -> exit 3" 3 "$rc"
check "3: stderr names this session (A)" yes "$(has "$err" "$sidA")"
check "3: stderr names the doc author (B)" yes "$(has "$err" "sidB")"
check "3: handoff_current.md untouched by the refused write" "$before_cksum" \
  "$(cksum "$repo/.claude/handoff_current.md")"
rm -rf "$repo"

finish
