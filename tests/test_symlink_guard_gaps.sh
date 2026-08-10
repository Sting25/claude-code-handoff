#!/usr/bin/env bash
# The three components the symlink sweep left uncovered, all found by the
# v0.13.0 adversarial re-audit. Each is git-clonable (git stores symlinks as
# mode 120000), so each is deliverable by a repo you merely check out:
#
#   SEC-1  `.claude` committed as a symlink bypasses the READ guards entirely —
#          they tested the leaf (`-L handoff_current.md`), which is false when
#          the leaf is a real file at the link target.
#   SEC-2  `.claude/handoff_pinned.md` as a symlink was read UNGUARDED on the
#          write path, and the pin body is copied verbatim into the generated
#          handoff — so the target's content is persisted into a repo file and
#          replayed into the next session.
#   H-3    `.claude/handoff_history` as a symlink sent every rotated snapshot
#          (verbatim session prose) outside the repo, silently, and disabled
#          retention along the way (`find -P` won't descend a symlinked start).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SS="$REPO_ROOT/bin/handoff_session_start.sh"
SL="$REPO_ROOT/bin/handoff_statusline.sh"
WH="$REPO_ROOT/bin/write_handoff.sh"

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

SECRET="VICTIM_SECRET_MUST_NOT_ESCAPE_4f2a"

# ===========================================================================
echo "SEC-1 — .claude itself as a symlink (read guards must be directory-aware)"

victim_dir="$(mktemp -d)"; cleanup_on_exit "$victim_dir"
must bash -c "printf '%s\n' '$SECRET' > '$victim_dir/handoff_current.md'"
proj="$(mk_repo)" || exit 1
cleanup_on_exit "$proj"
must ln -s "$victim_dir" "$proj/.claude"

out="$( cd "$proj" && CLAUDE_PROJECT_DIR="$proj" bash "$SS" </dev/null 2>/dev/null )"; rc=$?
check "session_start: exit 0"                        0   "$rc"
check "session_start: victim content NOT loaded"     no  "$(has "$out" "$SECRET")"
check "session_start: warning names .claude"         yes "$(has "$out" ".claude is a symlink")"
check "session_start: no handoff header emitted"     no  "$(has "$out" "Auto-loaded handoff from previous session")"

sl_payload="{\"session_id\":\"symsid\",\"cwd\":\"$proj\"}"
sl_out="$( cd "$proj" && CLAUDE_PROJECT_DIR="$proj" bash "$SL" <<<"$sl_payload" 2>/dev/null )"
check "statusline: reports none, not curated"        yes "$(has "$sl_out" "handoff: none")"

# ===========================================================================
echo "SEC-2 — .claude/handoff_pinned.md as a symlink (write path)"

pin_victim="$(mktemp)"; cleanup_on_exit "$pin_victim"
must bash -c "printf '%s\n' 'PIN_$SECRET' > '$pin_victim'"
proj2="$(mk_repo)" || exit 1
cleanup_on_exit "$proj2"
must mkdir -p "$proj2/.claude"
must ln -s "$pin_victim" "$proj2/.claude/handoff_pinned.md"

( cd "$proj2" && CLAUDE_PROJECT_DIR="$proj2" bash "$WH" >/dev/null 2>&1 </dev/null )
doc2="$proj2/.claude/handoff_current.md"
check "pin symlink: handoff still written"           yes "$( [ -f "$doc2" ] && echo yes || echo no )"
leaked=no
grep -qF "PIN_$SECRET" "$doc2" 2>/dev/null && leaked=yes
check "pin symlink: target content NOT in the doc"   no  "$leaked"
check "pin symlink: victim file untouched"           yes "$(has "$(cat "$pin_victim")" "PIN_$SECRET")"

# A REAL pin file still carries forward (the guard must not break the feature).
proj3="$(mk_repo)" || exit 1
cleanup_on_exit "$proj3"
must mkdir -p "$proj3/.claude"
must bash -c "printf '%s\n' 'REAL_PIN_CONTENT' > '$proj3/.claude/handoff_pinned.md'"
( cd "$proj3" && CLAUDE_PROJECT_DIR="$proj3" bash "$WH" >/dev/null 2>&1 </dev/null )
carried=no
grep -qF "REAL_PIN_CONTENT" "$proj3/.claude/handoff_current.md" 2>/dev/null && carried=yes
check "real pin still carried into the handoff"      yes "$carried"

# ===========================================================================
echo "M-5 — a RELATIVE pin override resolves against the repo root, not cwd"

proj4="$(mk_repo)" || exit 1
cleanup_on_exit "$proj4"
must mkdir -p "$proj4/.claude" "$proj4/sub"
must bash -c "printf '%s\n' 'RELATIVE_PIN_CONTENT' > '$proj4/.claude/mypin.md'"
# Run from a SUBDIRECTORY — the normal hook condition. Before the fix the read
# resolved against the process cwd and the pin silently vanished.
( cd "$proj4/sub" && CLAUDE_PROJECT_DIR="$proj4" HANDOFF_PINNED_FILE=".claude/mypin.md" \
    bash "$WH" >/dev/null 2>&1 </dev/null )
rel_carried=no
grep -qF "RELATIVE_PIN_CONTENT" "$proj4/.claude/handoff_current.md" 2>/dev/null && rel_carried=yes
check "relative pin carried when cwd != repo root"   yes "$rel_carried"

# ===========================================================================
echo "H-3 — .claude/handoff_history as a symlink"

hist_victim="$(mktemp -d)"; cleanup_on_exit "$hist_victim"
proj5="$(mk_repo)" || exit 1
cleanup_on_exit "$proj5"
must mkdir -p "$proj5/.claude"
# Seed a CURATED handoff so the next write has something worth rotating.
must bash -c "printf '%s\n' '# curated' 'SESSION_PROSE_$SECRET' > '$proj5/.claude/handoff_current.md'"
must ln -s "$hist_victim" "$proj5/.claude/handoff_history"

( cd "$proj5" && CLAUDE_PROJECT_DIR="$proj5" bash "$WH" >/dev/null 2>&1 </dev/null )
rc5=$?
check "history symlink: run refused (non-zero exit)" yes "$( [ "$rc5" -ne 0 ] && echo yes || echo no )"
escaped="$(find "$hist_victim" -type f 2>/dev/null | head -n 1)"
check "history symlink: nothing landed outside repo" ""  "$escaped"
preserved=no
grep -qF "SESSION_PROSE_$SECRET" "$proj5/.claude/handoff_current.md" 2>/dev/null && preserved=yes
check "history symlink: curated doc not destroyed"   yes "$preserved"

# A real history directory still rotates normally.
proj6="$(mk_repo)" || exit 1
cleanup_on_exit "$proj6"
must mkdir -p "$proj6/.claude"
must bash -c "printf '%s\n' '# curated' 'ROTATE_ME' > '$proj6/.claude/handoff_current.md'"
( cd "$proj6" && CLAUDE_PROJECT_DIR="$proj6" bash "$WH" >/dev/null 2>&1 </dev/null )
rotated="$(find "$proj6/.claude/handoff_history" -maxdepth 1 -name 'handoff_*.md' -type f 2>/dev/null | wc -l | tr -d ' ')"
check "real history dir: snapshot archived"          1   "$rotated"

finish
