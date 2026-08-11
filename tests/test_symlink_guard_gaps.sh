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

# ===========================================================================
echo "L-10 — ctx_check and compact_reset refuse symlinked parents too"

# These two were the holdouts in the guard sweep: handoff_turn_append.sh and
# handoff_statusline.sh have always refused a symlinked `.claude` or
# `handoff_backups`, ctx_check guarded only its individual flag writes, and
# compact_reset — whose entire job is deleting files — guarded nothing. Added
# in the v0.13.0 LOW cluster, and initially with NO coverage anywhere in the
# suite: a mutation pass that disabled both guards left every test green.
# compact_reset is the one that can destroy data through the link, so it gets
# the destructive fixture.
if command -v jq >/dev/null 2>&1; then
  CC="$REPO_ROOT/bin/handoff_ctx_check.sh"
  CR="$REPO_ROOT/bin/handoff_compact_reset.sh"
  sid="symguard1"

  # --- compact_reset: must not delete through a symlinked .claude ---
  cr_victim="$(mktemp -d)"; cleanup_on_exit "$cr_victim"
  must mkdir -p "$cr_victim/handoff_backups"
  # Names the hook deletes verbatim, planted in the victim directory.
  for n in ".ctx_$sid" ".ctx_tokens_$sid" ".ctx_flagged_$sid" ".ctx_sl_$sid"; do
    must bash -c "printf 'VICTIM\n' > '$cr_victim/handoff_backups/$n'"
  done
  before="$(find "$cr_victim/handoff_backups" -type f | wc -l | tr -d ' ')"
  check "fixture planted 4 victim sidecars" 4 "$before"
  crp="$(mk_repo)" || exit 1
  cleanup_on_exit "$crp"
  must ln -s "$cr_victim" "$crp/.claude"
  ( cd "$crp" && bash "$CR" <<<"{\"session_id\":\"$sid\"}" >/dev/null 2>&1 ); rc=$?
  after="$(find "$cr_victim/handoff_backups" -type f | wc -l | tr -d ' ')"
  check "compact_reset: victim files NOT deleted through the link" 4 "$after"
  check "compact_reset: still exits 0 (hook discipline)"           0 "$rc"

  # --- ctx_check: must not write sidecars or nudge through a symlinked
  #     .claude. The fixture has to be one the hook actually REACHES: it
  #     exits at `[[ -f "$size_file" ]] || exit 0` when no prior .ctx_<sid>
  #     exists, so an empty victim directory proves nothing (an earlier
  #     version of this test made exactly that mistake and passed against
  #     the unguarded code). Seed a tiny prior size against a large
  #     transcript so the threshold is crossed and the nudge fires.
  cc_victim="$(mktemp -d)"; cleanup_on_exit "$cc_victim"
  must mkdir -p "$cc_victim/handoff_backups"
  must bash -c "printf '10' > '$cc_victim/handoff_backups/.ctx_$sid'"
  must bash -c "printf 'tokens=900\n' > '$cc_victim/handoff_backups/.ctx_sl_$sid'"
  ccp="$(mk_repo)" || exit 1
  cleanup_on_exit "$ccp"
  must bash -c "head -c 200000 /dev/zero | tr '\\0' 'x' > '$ccp/tx.jsonl'"
  must ln -s "$cc_victim" "$ccp/.claude"
  out_cc="$( cd "$ccp" && env HANDOFF_CTX_WINDOW_TOKENS=1000 bash "$CC" \
      <<<"{\"session_id\":\"$sid\",\"transcript_path\":\"$ccp/tx.jsonl\"}" \
      2>/dev/null )"; rc2=$?
  # Unguarded this lands a new .ctx_flagged_<sid> in the victim directory and
  # emits a nudge built from the victim's cached numbers.
  wrote="$(find "$cc_victim" -type f 2>/dev/null | wc -l | tr -d ' ')"
  check "ctx_check: no new sidecar written through the link"       2 "$wrote"
  check "ctx_check: no flag file in the victim dir"                no \
    "$([[ -f "$cc_victim/handoff_backups/.ctx_flagged_$sid" ]] && echo yes || echo no)"
  check "ctx_check: emits nothing off the victim's data"           ""  "$out_cc"
  check "ctx_check: still exits 0 (hook discipline)"               0 "$rc2"

  # --- Control: with a REAL .claude, both still do their jobs ---
  ok="$(mk_repo)" || exit 1
  cleanup_on_exit "$ok"
  okbd="$ok/.claude/handoff_backups"
  must mkdir -p "$okbd"
  must bash -c "printf '4000' > '$okbd/.ctx_$sid'"
  must bash -c "printf '4000\n' > '$okbd/.ctx_flagged_$sid'"
  ( cd "$ok" && bash "$CR" <<<"{\"session_id\":\"$sid\"}" >/dev/null 2>&1 )
  check "control: compact_reset still clears the real sidecar"     no \
    "$([[ -f "$okbd/.ctx_$sid" ]] && echo yes || echo no)"
else
  skip "jq missing — both hooks parse their payload with jq"
fi

finish
