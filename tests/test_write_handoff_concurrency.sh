#!/usr/bin/env bash
# Concurrency coverage for write_handoff.sh (issue: SessionEnd + PreCompact
# firing together, or two sessions open in one repo):
#   - whole-run write lock (.claude/.handoff_write.lock): --if-curated runs
#     yield silently when it's held; explicit runs wait briefly then proceed
#     with a warning (never deadlock); stale locks are reclaimed.
#   - --restamp takes that SAME write lock (M-4): its read→guard→sign→publish
#     sequence is atomic only in isolation, so an unserialized restamp could
#     land pre-rotation bytes on top of a concurrent writer's fresh publish.
#     A miss skips the restamp loudly (a stale signature is recoverable; a
#     clobbered document is not).
#   - .gitignore bootstrap lock (.claude/.handoff_gitignore.lock, shared by
#     name/idiom with handoff_turn_append.sh): a miss skips the bootstrap
#     silently; concurrent runs never duplicate the bootstrap lines.
#   - concurrent smoke: two near-simultaneous runs leave exactly one complete
#     handoff_current.md (HMAC verifies when openssl is present), no leftover
#     tmp files, and no leftover lock dirs.
# Pure bash + git; the HMAC check self-skips without openssl.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
SENTINEL="<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->"
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# A repo that already ignores .claude/ (committed), so the bootstrap-focused
# assertions can opt in with a plain mk_repo instead.
mk_repo_gitignored() {
  local d; d="$(mk_repo)"
  printf '.claude/\n' > "$d/.gitignore"
  git -C "$d" add .gitignore
  git -C "$d" commit -qm "ignore .claude"
  printf '%s\n' "$d"
}

echo "write_handoff.sh — write lock / gitignore lock / concurrent smoke"

# --- Held write lock: --if-curated (hook) run yields, but VISIBLY (DATA-2) --
# A FRESH lock dir means another writer is mid-rotation/publish; the safety
# net's mechanical snapshot adds nothing, so it must exit 0 without writing.
# It must NOT look like a successful write while doing so: the lock is a bare
# directory with no owner, so one left behind by a SIGKILL'd/OOM'd writer or a
# reboot mid-write makes every SessionEnd and PreCompact fire in the repo
# no-op for up to HANDOFF_LOCK_STALE_SECS — and with the path on stdout and
# rc=0 that was byte-for-byte identical to success.
repo="$(mk_repo_gitignored)"
must mkdir -p "$repo/.claude/.handoff_write.lock"
out="$( cd "$repo" && bash "$WH" --if-curated 2>/dev/null )"; rc=$?
err="$( cd "$repo" && bash "$WH" --if-curated 2>&1 >/dev/null )"
check "held lock + --if-curated -> exit 0"        0   "$rc"
check "held lock + --if-curated -> warns on stderr" yes "$(has "$err" "SKIPPING this safety-net write")"
check "held lock + --if-curated -> names the lock path" yes \
  "$(has "$err" ".claude/.handoff_write.lock")"
check "held lock + --if-curated -> no path on stdout" "" "$out"
check "held lock + --if-curated -> nothing published" no \
  "$([[ -f "$repo/.claude/handoff_current.md" ]] && echo yes || echo no)"
check "held lock + --if-curated -> no tmp leftover" 0 \
  "$(find "$repo/.claude" -maxdepth 1 -name '.handoff_current.*' 2>/dev/null | wc -l | tr -d ' ')"
check "held lock left for its holder" yes \
  "$([[ -d "$repo/.claude/.handoff_write.lock" ]] && echo yes || echo no)"
rm -rf "$repo"

# The reported repro, end to end: a real session's document plus a LEFTOVER
# lock, driven exactly as the SessionEnd hook drives it (JSON payload on
# stdin). The write is skipped either way — the fix is that the skip is now
# announced instead of being reported as a completed write.
repo="$(mk_repo_gitignored)"
( cd "$repo" && bash "$WH" >/dev/null 2>&1 </dev/null )   # a document to protect
doc="$repo/.claude/handoff_current.md"
must test -f "$doc"
before="$(cat "$doc")"
must mkdir -p "$repo/.claude/.handoff_write.lock"         # writer died here
out="$( cd "$repo" && printf '{"reason":"clear"}' | bash "$WH" --if-curated 2>/dev/null )"; rc=$?
err="$( cd "$repo" && printf '{"reason":"clear"}' | bash "$WH" --if-curated 2>&1 >/dev/null )"
check "leftover lock: exit 0 (a hook never fails the session)" 0 "$rc"
check "leftover lock: document byte-identical (write skipped)" yes \
  "$([[ "$before" == "$(cat "$doc")" ]] && echo yes || echo no)"
check "leftover lock: nothing rotated into history" 0 \
  "$(find "$repo/.claude/handoff_history" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
check "leftover lock: the miss is visible on stderr" yes "$(has "$err" "may be stale")"
check "leftover lock: not reported as a write" "" "$out"
check "leftover lock: message points at the remedy" yes "$(has "$err" "rmdir")"
rm -rf "$repo"

# --- Held write lock: explicit run waits, warns, and still writes -----------
# A user-invoked /handoff must never deadlock: after brief retries it
# proceeds without the lock, loudly.
repo="$(mk_repo_gitignored)"
must mkdir -p "$repo/.claude/.handoff_write.lock"
err="$( cd "$repo" && bash "$WH" 2>&1 >/dev/null )"; rc=$?
check "held lock + explicit -> exit 0"          0   "$rc"
check "held lock + explicit -> warns"           yes "$(has "$err" "proceeding without it")"
check "held lock + explicit -> handoff written" yes \
  "$([[ -f "$repo/.claude/handoff_current.md" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- Stale write lock (holder hard-killed) is reclaimed ----------------------
# Mirrors turn_append's staleness reclaim: an EXIT trap never fired (SIGKILL,
# power loss), so an mtime older than HANDOFF_LOCK_STALE_SECS means the
# holder is gone; the run reclaims, writes, and releases.
repo="$(mk_repo_gitignored)"
must mkdir -p "$repo/.claude/.handoff_write.lock"
touch -t 202001010000 "$repo/.claude/.handoff_write.lock"   # POSIX touch -t: GNU + BSD
( cd "$repo" && HANDOFF_LOCK_STALE_SECS=1 bash "$WH" --if-curated >/dev/null 2>&1 ); rc=$?
check "stale lock + --if-curated -> exit 0"      0   "$rc"
check "stale lock reclaimed -> handoff written"  yes \
  "$([[ -f "$repo/.claude/handoff_current.md" ]] && echo yes || echo no)"
check "stale lock released after run" no \
  "$([[ -d "$repo/.claude/.handoff_write.lock" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- Symlink planted at the write-lock path: refused, run degrades ----------
# mkdir at a symlink fails with EEXIST forever and rmdir can't reclaim it, so
# the lock helper refuses symlinks outright; an explicit run then proceeds
# unlocked (same degradation as a held lock) rather than wedging.
repo="$(mk_repo_gitignored)"
must mkdir -p "$repo/.claude"
must ln -s /nonexistent "$repo/.claude/.handoff_write.lock"
err="$( cd "$repo" && bash "$WH" 2>&1 >/dev/null )"; rc=$?
check "symlink lock -> exit 0"           0   "$rc"
check "symlink lock -> refusal warning"  yes "$(has "$err" "refusing to use it as a lock")"
check "symlink lock -> handoff written"  yes \
  "$([[ -f "$repo/.claude/handoff_current.md" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- Held write lock: --restamp skips instead of clobbering (M-4) -----------
# A restamp reads the document, guards it, signs it, and publishes with `mv` —
# atomic per step, but NOT as a sequence. Unserialized, a concurrent writer can
# rotate the document into history and publish a fresh one inside that gap, and
# the restamp's mv then puts the PRE-rotation bytes back on top, re-signed so
# the substitution verifies and is invisible downstream. The fixture edits the
# document so its stored trailer goes stale: a restamp that ran would re-sign
# it (MAC verifies again), so "MAC still stale" is the proof it stood down.
if command -v openssl >/dev/null 2>&1; then
  # shellcheck source=../bin/handoff_provenance.sh
  . "$REPO_ROOT/bin/handoff_provenance.sh"

  # Positive control FIRST — with no lock held, this exact fixture must restamp
  # successfully. Without it, the skip assertions below could pass vacuously
  # (e.g. if restamp were broken outright for edited documents).
  repo="$(mk_repo_gitignored)"
  ( cd "$repo" && bash "$WH" >/dev/null 2>&1 </dev/null )
  doc="$repo/.claude/handoff_current.md"
  must test -f "$doc"
  must bash -c "printf 'EDITED AFTER SIGNING\n' >> '$doc'"
  check "control: edit made the stored MAC stale" no \
    "$(handoff_mac_verify "$doc" && echo verified || echo no)"
  out="$( cd "$repo" && bash "$WH" --restamp 2>/dev/null </dev/null )"; rc=$?
  check "free lock + --restamp -> exit 0"       0   "$rc"
  check "free lock + --restamp -> path printed" yes "$(has "$out" ".claude/handoff_current.md")"
  check "free lock + --restamp -> re-signed"    verified \
    "$(handoff_mac_verify "$doc" && echo verified || echo no)"
  check "free lock + --restamp -> lock released" no \
    "$([[ -d "$repo/.claude/.handoff_write.lock" ]] && echo yes || echo no)"
  rm -rf "$repo"

  # Same fixture, but a FRESH lock dir stands in for a writer mid-sequence.
  repo="$(mk_repo_gitignored)"
  ( cd "$repo" && bash "$WH" >/dev/null 2>&1 </dev/null )
  doc="$repo/.claude/handoff_current.md"
  must test -f "$doc"
  must bash -c "printf 'EDITED AFTER SIGNING\n' >> '$doc'"
  before="$(cat "$doc")"
  must mkdir -p "$repo/.claude/.handoff_write.lock"
  out="$( cd "$repo" && bash "$WH" --restamp 2>/dev/null </dev/null )"; rc=$?
  err="$( cd "$repo" && bash "$WH" --restamp 2>&1 >/dev/null </dev/null )"
  check "held lock + --restamp -> exit 0"           0  "$rc"
  check "held lock + --restamp -> warns loudly"     yes "$(has "$err" "SKIPPING the restamp")"
  check "held lock + --restamp -> names the lock"   yes "$(has "$err" ".handoff_write.lock")"
  # The load-bearing assertion: unserialized, the restamp would have re-signed
  # (and in the real race, republished stale bytes over a fresh publish).
  check "held lock + --restamp -> NOT re-signed"    no \
    "$(handoff_mac_verify "$doc" && echo verified || echo no)"
  check "held lock + --restamp -> document byte-identical" yes \
    "$([[ "$before" == "$(cat "$doc")" ]] && echo yes || echo no)"
  # stdout is the "job done" signal; a skip must not fake it.
  check "held lock + --restamp -> no path on stdout" "" "$out"
  check "held lock + --restamp -> no tmp leftover"   0 \
    "$(find "$repo/.claude" -maxdepth 1 -name '.handoff_current.*' 2>/dev/null | wc -l | tr -d ' ')"
  check "held lock + --restamp -> lock left for its holder" yes \
    "$([[ -d "$repo/.claude/.handoff_write.lock" ]] && echo yes || echo no)"
  rm -rf "$repo"

  # A STALE lock (holder hard-killed) must not block a restamp forever.
  repo="$(mk_repo_gitignored)"
  ( cd "$repo" && bash "$WH" >/dev/null 2>&1 </dev/null )
  doc="$repo/.claude/handoff_current.md"
  must test -f "$doc"
  must bash -c "printf 'EDITED AFTER SIGNING\n' >> '$doc'"
  must mkdir -p "$repo/.claude/.handoff_write.lock"
  must touch -t 202001010000 "$repo/.claude/.handoff_write.lock"
  ( cd "$repo" && HANDOFF_LOCK_STALE_SECS=1 bash "$WH" --restamp >/dev/null 2>&1 </dev/null ); rc=$?
  check "stale lock + --restamp -> exit 0"        0 "$rc"
  check "stale lock + --restamp -> re-signed"     verified \
    "$(handoff_mac_verify "$doc" && echo verified || echo no)"
  check "stale lock + --restamp -> lock released" no \
    "$([[ -d "$repo/.claude/.handoff_write.lock" ]] && echo yes || echo no)"
  rm -rf "$repo"
else
  skip "openssl missing — --restamp write-lock coverage"
fi

# --- Held gitignore lock: bootstrap skipped silently, write proceeds --------
# The holder (this script or handoff_turn_append.sh — same lock name) is
# appending the very same entries; a miss must skip the bootstrap without
# blocking the handoff write itself.
repo="$(mk_repo)"                          # no .gitignore in this repo
must mkdir -p "$repo/.claude/.handoff_gitignore.lock"
( cd "$repo" && bash "$WH" >/dev/null 2>&1 ); rc=$?
check "held gitignore lock -> exit 0"           0  "$rc"
check "held gitignore lock -> bootstrap skipped" no \
  "$([[ -f "$repo/.gitignore" ]] && echo yes || echo no)"
check "held gitignore lock -> handoff written"  yes \
  "$([[ -f "$repo/.claude/handoff_current.md" ]] && echo yes || echo no)"
check "held gitignore lock left for its holder" yes \
  "$([[ -d "$repo/.claude/.handoff_gitignore.lock" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- Normal run: both locks taken and released (no leftovers) ---------------
repo="$(mk_repo)"
( cd "$repo" && bash "$WH" >/dev/null 2>&1 )
check "normal run -> gitignore bootstrapped" yes \
  "$(has "$(cat "$repo/.gitignore" 2>/dev/null)" ".claude/handoff_current.md")"
check "normal run -> write lock released" no \
  "$([[ -d "$repo/.claude/.handoff_write.lock" ]] && echo yes || echo no)"
check "normal run -> gitignore lock released" no \
  "$([[ -d "$repo/.claude/.handoff_gitignore.lock" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- Concurrent smoke: two near-simultaneous runs ---------------------------
# The interleaving isn't deterministic, but every outcome the lock permits
# must hold: exactly one complete handoff_current.md (signed, when openssl
# exists), no half-written tmp files, no leftover locks, and a .gitignore
# with no duplicated bootstrap lines (the check-ignore→append race).
repo="$(mk_repo)"                          # no .gitignore: exercise the bootstrap race
( cd "$repo" && bash "$WH" >/dev/null 2>&1 ) &
p1=$!
( cd "$repo" && bash "$WH" >/dev/null 2>&1 ) &
p2=$!
wait "$p1"; rc1=$?
wait "$p2"; rc2=$?
check "concurrent: run 1 exit 0" 0 "$rc1"
check "concurrent: run 2 exit 0" 0 "$rc2"
check "concurrent: exactly one handoff_current.md" 1 \
  "$(find "$repo/.claude" -maxdepth 1 -name 'handoff_current.md' 2>/dev/null | wc -l | tr -d ' ')"
doc="$(cat "$repo/.claude/handoff_current.md" 2>/dev/null)"
check "concurrent: doc is complete (sentinel present)" yes "$(has "$doc" "$SENTINEL")"
check "concurrent: no tmp leftovers" 0 \
  "$(find "$repo/.claude" -maxdepth 1 -name '.handoff_current.*' 2>/dev/null | wc -l | tr -d ' ')"
check "concurrent: write lock released"    no "$([[ -d "$repo/.claude/.handoff_write.lock" ]] && echo yes || echo no)"
check "concurrent: gitignore lock released" no "$([[ -d "$repo/.claude/.handoff_gitignore.lock" ]] && echo yes || echo no)"
check "concurrent: no duplicated .gitignore lines" "" \
  "$(sort "$repo/.gitignore" 2>/dev/null | uniq -d)"
# Published doc integrity: the HMAC trailer must verify over the final
# content — a doc corrupted by interleaved writes would fail the digest.
if command -v openssl >/dev/null 2>&1; then
  # shellcheck source=../bin/handoff_provenance.sh
  . "$REPO_ROOT/bin/handoff_provenance.sh"
  check "concurrent: HMAC verifies over published doc" verified \
    "$(handoff_mac_verify "$repo/.claude/handoff_current.md" && echo verified || echo no)"
else
  skip "openssl missing — HMAC verification"
fi
rm -rf "$repo"


# ---------------------------------------------------------------------------
echo "session_start — leftover write lock is reported to the user"

# write_handoff.sh warns on stderr when a held lock makes it skip a safety-net
# write, but the INSTALLED SessionEnd/PreCompact hooks are wired
# `… >/dev/null 2>&1 || true`, so in the default configuration that warning
# reaches nobody — and a session ending without a write is exactly when no one
# is watching. SessionStart is where the user does look, so the cause has to be
# reported there or the DATA-2 fix has no real-world reach.
SS="$REPO_ROOT/bin/handoff_session_start.sh"
lk="$(mk_repo)" || exit 1
cleanup_on_exit "$lk"
must mkdir -p "$lk/.claude"
must mkdir "$lk/.claude/.handoff_write.lock"
out="$( cd "$lk" && CLAUDE_PROJECT_DIR="$lk" bash "$SS" </dev/null 2>/dev/null )"; rc=$?
named=no
printf '%s' "$out" | grep -q 'write lock is left over' \
  && printf '%s' "$out" | grep -q 'handoff_write.lock' && named=yes
check "leftover lock reported at SessionStart" yes "$named"
check "and says how to clear it"               yes \
  "$(printf '%s' "$out" | grep -q 'rmdir' && echo yes || echo no)"
check "SessionStart still exits 0"             0   "$rc"
# No lock, no noise — this must not fire on a normal project.
must rmdir "$lk/.claude/.handoff_write.lock"
out2="$( cd "$lk" && CLAUDE_PROJECT_DIR="$lk" bash "$SS" </dev/null 2>/dev/null )"
check "silent when no lock is present"         no  \
  "$(printf '%s' "$out2" | grep -q 'write lock is left over' && echo yes || echo no)"

finish
