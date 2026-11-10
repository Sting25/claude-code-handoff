#!/usr/bin/env bash
# #155: the stale-lock reclaim must have exactly one winner. The old chain
# (`stat -> stale? -> rm -f owner; rmdir -> mkdir -> claim`) checked the age
# and removed the token in separate steps, so a second reclaimer that had
# also seen the dead holder's lock as stale could delete the FIRST
# reclaimer's fresh token and take the lock too: both owned it. An `owner`
# that was a directory also wedged the lock forever (`rm -f` fails silently,
# `rmdir` refuses a non-empty dir).
#
# This file drives the reclaim code itself, extracted from both scripts, for
# all three sites: write_handoff.sh's try_mkdir_lock (write lock and its
# gitignore lock) and handoff_turn_append.sh's gitignore lock and flock-less
# session lock, which share ta_reclaim_stale_lock behind the same
# `mkdir && claim || reclaim` shape.
#   1. Barrier race: two separate processes against a lock pre-aged with
#      `touch -t`, released together, looped. Exactly one may return 0, and
#      the token left behind must be the winner's.
#   2. Deterministic interleave: a `date` shim parks reclaimer B right after
#      its age check while A reclaims to completion, which is the exact
#      window #155 describes. B must miss and A's token must survive.
#   3. A non-empty `owner/` directory is reclaimed (the wedge).
#   4. Orphaned owner.reap.* entries older than the window are swept.
#   5. Three reclaimers, deterministic: B captures the token A just won while
#      C, holding the same stale view, finds nothing to capture. C must not
#      go on to claim (that made A and C both owners in review).
#   6. A releases while B holds a capture of A's token: the release must
#      still remove the lock, and B must not leave A's token behind.
#   7. A hand-back blocked by a token that appeared meanwhile is reported on
#      stderr and never replaces that token.
#   8. (#170) A release by a process that does not own the token leaves the
#      owner's lock, and captures of other owners' tokens, untouched.
#   9. (#170) The residual window of #168: A's release fails its first rmdir on
#      B's capture, B hands the token back, A sweeps the capture. A's second
#      pass must remove its own handed-back token and free the lock.
#  10. (#170 review) Two reapers in turn: B hands back, then C captures the
#      handed-back token while A sweeps. A fixed two-pass release returned
#      with C's capture in the dir, and C's hand-back then left an ownerless
#      token; the release must keep going until the lock is free.
#  11. (#183 review) A release that cannot finish (a shim re-creates the token
#      every pass) gives up at its pass cap: one stderr line, rc 0, and the
#      statement after it still runs under `set -e`.
#  12. (#183 review) A hand-back that lands between the release's owner check
#      and its capture sweep (the capture is removed by the reclaimer) is
#      caught by the re-check of owner.
#  13. (#188) No hard links: every racer (A, B and a third acquirer) runs
#      with an `ln` that fails with "Operation not supported", as macOS ln
#      does on exFAT and FAT32. B captures the token A just won; the
#      hand-back must still put A's token back (no lost token), a third
#      acquirer must miss (one winner), and A's release must free the lock.
#  14. (#188) No hard links and a token that appeared meanwhile: B's
#      fallback hand-back never replaces it and says so on stderr. Only B
#      runs with the ln stub; the test asserts the stub was called.
#  15. (#199 review) The fallback's own windows, driven by a DEBUG-trap park
#      inside B: (a) the holder releases and a new acquirer makes the dir
#      after B's read, before its re-check: no stray token in the new dir;
#      (b) an owner appears after B's read, before its create: it is not
#      replaced and B warns once (an mv shim modelling BSD `mv -n`'s
#      check-then-rename parks at the same point, so the rejected rename-back
#      goes red here); (c) the holder releases before B's create: the lock
#      is gone, B says nothing; (d) an empty capture that stays empty is not
#      handed back (owner stays absent, a third acquirer still misses, the
#      holder's release frees the lock), and one filled during the pause is.
#  16. (#188) Group 1's barrier race with the ln stub on every racer and a
#      `date` that sleeps a random 0 to 90 ms, so unordered racers go through
#      the fallback (HANDOFF_RACE_N / 4, at least 5 iterations per site; the
#      number of stub calls is printed).
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
WH="$REPO_ROOT/bin/write_handoff.sh"
TA="$REPO_ROOT/bin/handoff_turn_append.sh"
N="${HANDOFF_RACE_N:-60}"
[[ "$N" =~ ^[0-9]+$ ]] || N=60

echo "stale-lock reclaim is single-winner (#155)"

work="$(mktemp -d)"; cleanup_on_exit "$work"
work="$(cd "$work" && pwd -P)"
funcs="$work/funcs.sh"
: > "$funcs"
for fn in claim_mkdir_lock release_mkdir_lock reclaim_stale_mkdir_lock try_mkdir_lock; do
  sed -n "/^$fn() {/,/^}/p" "$WH" >> "$funcs"
done
for fn in ta_claim_lock ta_release_lock ta_reclaim_stale_lock; do
  sed -n "/^$fn() {/,/^}/p" "$TA" >> "$funcs"
done
defined="$(bash -c 'source "$1"; for f in claim_mkdir_lock release_mkdir_lock reclaim_stale_mkdir_lock try_mkdir_lock ta_claim_lock ta_release_lock ta_reclaim_stale_lock; do declare -F "$f" >/dev/null || echo "$f"; done' _ "$funcs" </dev/null)"
check "every reclaim function extracted from the scripts" "" "$defined"

# One racer = one bash process (distinct $$, as two hook fires would be).
# Args: <site> <lock> <go-file|""> <ready-file|""> <done-file|"">
# Prints "<rc> <pid>".
drv="$work/racer.sh"
cat > "$drv" <<'DRV'
set -u
source "$1"; site="$2"; lock="$3"; go="$4"; ready="$5"; fin="$6"
# RACE_DBG_HOLD parks this racer once, right before the first command whose
# text contains RACE_DBG_MATCH, until that file exists (a DEBUG trap; -T
# carries it into functions and subshells). `>|` because the park can fire
# inside a noclobber subshell.
race_dbg() {
  [[ -e "$RACE_DBG_HOLD.passed" ]] && return 0
  [[ "$BASH_COMMAND" == *"$RACE_DBG_MATCH"* ]] || return 0
  : >| "$RACE_DBG_HOLD.parked"
  local n=0
  while [[ ! -e "$RACE_DBG_HOLD" ]] && (( n < 1000 )); do
    sleep 0.01 2>/dev/null || sleep 1; n=$((n + 1))
  done
  : >| "$RACE_DBG_HOLD.passed"
}
if [[ -n "${RACE_DBG_HOLD:-}" ]]; then set -T; trap race_dbg DEBUG; fi
if [[ -n "$ready" ]]; then : > "$ready"; fi
if [[ -n "$go" ]]; then
  spins=0
  until [[ -e "$go" ]]; do
    spins=$((spins + 1)); (( spins > 3000000 )) && break
  done
fi
case "$site" in
  wh) try_mkdir_lock "$lock"; rc=$? ;;
  ta) { mkdir "$lock" 2>/dev/null && ta_claim_lock "$lock"; } || ta_reclaim_stale_lock "$lock"; rc=$? ;;
  wh-hold|ta-hold)
    # Acquire (by reclaim if stale), announce, wait, then release, all in
    # THIS process: the token is the pid, so only the process that took the
    # lock can prove it owns it (#170).
    if [[ "$site" == wh-hold ]]; then try_mkdir_lock "$lock"
    else { mkdir "$lock" 2>/dev/null && ta_claim_lock "$lock"; } || ta_reclaim_stale_lock "$lock"; fi
    rc=$?
    : > "$HOLD_WON"
    n=0; until [[ -e "$HOLD_REL" ]] || (( n > 1000 )); do sleep 0.01 2>/dev/null || sleep 1; n=$((n + 1)); done
    if [[ "$site" == wh-hold ]]; then release_mkdir_lock "$lock"; else ta_release_lock "$lock"; fi
    if [[ -n "${HOLD_AFTER:-}" ]]; then : > "$HOLD_AFTER"; fi
    ;;
  wh-release) release_mkdir_lock "$lock"; rc=$? ;;
  ta-release) ta_release_lock "$lock"; rc=$? ;;
  *)  rc=99 ;;
esac
if [[ -n "$fin" ]]; then : > "$fin"; fi
echo "$rc $$"
DRV

age_lock() {  # <lock>: a dead holder's lock, token and dir both old
  rm -rf "$1"
  mkdir "$1" && echo 424242 > "$1/owner" \
    && touch -t 202001010000 "$1/owner" && touch -t 202001010000 "$1"
}
entries() {  # <dir>: its entry names, sorted, space-separated
  ( cd "$1" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | sort | tr '\n' ' ' | sed 's/ $//' )
}
wait_for() {  # <file>...: up to ~10s
  local i=0 f all
  while (( i < 1000 )); do
    all=1
    for f in "$@"; do [[ -e "$f" ]] || all=0; done
    (( all )) && return 0
    sleep 0.01 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  return 1
}

# --- 1. barrier race, looped ------------------------------------------------
for site in wh ta; do
  bad=0; tokbad=0; first_bad=""
  for i in $(seq 1 "$N"); do
    d="$work/race.$site.$i"; mkdir -p "$d"; lock="$d/the.lock"
    age_lock "$lock" || { bad=$((bad + 1)); continue; }
    bash "$drv" "$funcs" "$site" "$lock" "$d/go" "$d/r1" "" > "$d/o1" 2>/dev/null </dev/null & p1=$!
    bash "$drv" "$funcs" "$site" "$lock" "$d/go" "$d/r2" "" > "$d/o2" 2>/dev/null </dev/null & p2=$!
    wait_for "$d/r1" "$d/r2"
    : > "$d/go"
    wait "$p1"; wait "$p2"
    read -r rc1 pid1 < "$d/o1"; read -r rc2 pid2 < "$d/o2"
    wins=0; winner=""
    if [[ "$rc1" == 0 ]]; then wins=$((wins + 1)); winner="$pid1"; fi
    if [[ "$rc2" == 0 ]]; then wins=$((wins + 1)); winner="$pid2"; fi
    if (( wins != 1 )); then
      bad=$((bad + 1)); [[ -n "$first_bad" ]] || first_bad="$i"
    elif [[ "$(cat "$lock/owner" 2>/dev/null)" != "$winner" ]]; then
      tokbad=$((tokbad + 1)); [[ -n "$first_bad" ]] || first_bad="$i"
    fi
    rm -rf "$d"
  done
  [[ -n "$first_bad" ]] && echo "  (site $site: first bad iteration $first_bad of $N)"
  check "$site barrier race x$N: iterations without exactly one winner" 0 "$bad"
  check "$site barrier race x$N: iterations where the token is not the winner's" 0 "$tokbad"
done

# --- 2. deterministic interleave via a date shim ------------------------------
# The shim parks a racer that has RACE_HOLD_UNTIL set at its first `date`
# (the age check reads the lock's mtime, then the clock) until that file
# exists, then behaves like date. Everything else is the real tool.
shim="$work/shim"; mkdir -p "$shim"
real_date="$(command -v date)"
cat > "$shim/date" <<SHIM
#!/usr/bin/env bash
if [[ -n "\${RACE_HOLD_UNTIL:-}" && ! -e "\${RACE_HOLD_UNTIL}.passed" ]]; then
  : > "\${RACE_HOLD_UNTIL}.parked"
  n=0
  while [[ ! -e "\$RACE_HOLD_UNTIL" ]] && (( n < 1000 )); do
    sleep 0.01 2>/dev/null || sleep 1; n=\$((n + 1))
  done
  : > "\${RACE_HOLD_UNTIL}.passed"
fi
exec "$real_date" "\$@"
SHIM
chmod +x "$shim/date"
# The mv shim runs the real mv, then parks a racer that has RACE_MV_HOLD set
# (first call only) until that file exists, keeping B between its capture
# and its hand-back.
real_mv="$(command -v mv)"
cat > "$shim/mv" <<SHIM
#!/usr/bin/env bash
"$real_mv" "\$@"; r=\$?
if [[ -n "\${RACE_MV_HOLD:-}" && ! -e "\${RACE_MV_HOLD}.passed" ]]; then
  : > "\${RACE_MV_HOLD}.parked"
  n=0
  while [[ ! -e "\$RACE_MV_HOLD" ]] && (( n < 1000 )); do
    sleep 0.01 2>/dev/null || sleep 1; n=\$((n + 1))
  done
  : > "\${RACE_MV_HOLD}.passed"
fi
exit \$r
SHIM
chmod +x "$shim/mv"
for site in wh ta; do
  d="$work/inter.$site"; mkdir -p "$d"; lock="$d/the.lock"
  must age_lock "$lock"
  PATH="$shim:$PATH" RACE_HOLD_UNTIL="$d/a_done" \
    bash "$drv" "$funcs" "$site" "$lock" "" "" "" > "$d/ob" 2>/dev/null </dev/null & pb=$!
  parked=no; wait_for "$d/a_done.parked" && parked=yes
  check "$site interleave: B parked after its age check" yes "$parked"
  bash "$drv" "$funcs" "$site" "$lock" "" "" "$d/a_done" > "$d/oa" 2>/dev/null </dev/null
  wait "$pb"
  read -r rca pida < "$d/oa"; read -r rcb _ < "$d/ob"
  check "$site interleave: A reclaims (0) and B, stale view in hand, misses (1)" "0 1" "$rca $rcb"
  check "$site interleave: A's token survives B" "$pida" "$(cat "$lock/owner" 2>/dev/null)"
  check "$site interleave: no captured token left behind" 0 \
    "$(find "$lock" -name 'owner.reap.*' 2>/dev/null | wc -l | tr -d ' ')"
done

# --- 3. non-empty owner/ directory: reclaimed, not wedged ---------------------
for site in wh ta; do
  d="$work/ownerdir.$site"; mkdir -p "$d"; lock="$d/the.lock"
  must mkdir -p "$lock/owner/nested"
  must touch "$lock/owner/nested/f"
  # Only the lock dir is old: the junk inside it is fresh, and a non-file
  # owner must still never be mistaken for a live token and handed back.
  must touch -t 202001010000 "$lock"
  read -r rc pid < <(bash "$drv" "$funcs" "$site" "$lock" "" "" "" 2>/dev/null </dev/null)
  check "$site owner/ dir: reclaimed" 0 "$rc"
  check "$site owner/ dir: token is now this process's file" "$pid" \
    "$([[ -f "$lock/owner" ]] && cat "$lock/owner")"
  check "$site owner/ dir: nothing else left in the lock dir" "owner" "$(entries "$lock")"
done
# End to end: write_handoff.sh with its write lock wedged that way.
repo="$(mk_repo)"
must mkdir -p "$repo/.claude/.handoff_write.lock/owner/x"
must touch -t 202001010000 "$repo/.claude/.handoff_write.lock/owner/x" \
  "$repo/.claude/.handoff_write.lock/owner" "$repo/.claude/.handoff_write.lock"
( cd "$repo" && HANDOFF_LOCK_STALE_SECS=1 bash "$WH" --if-curated >/dev/null 2>&1 </dev/null ); rc=$?
check "write_handoff owner/ dir lock: exit 0"          0   "$rc"
check "write_handoff owner/ dir lock: handoff written" yes "$([[ -f "$repo/.claude/handoff_current.md" ]] && echo yes || echo no)"
check "write_handoff owner/ dir lock: released after"  no  "$([[ -e "$repo/.claude/.handoff_write.lock" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- 4. orphan sweep, live lock untouched, symlink refused --------------------
for site in wh ta; do
  d="$work/sweep.$site"; mkdir -p "$d"; lock="$d/the.lock"
  must age_lock "$lock"
  must touch "$lock/owner.reap.1.1" "$lock/owner.reap.2.2"
  must touch -t 202001010000 "$lock/owner.reap.1.1" "$lock"
  read -r rc _ < <(bash "$drv" "$funcs" "$site" "$lock" "" "" "" 2>/dev/null </dev/null)
  check "$site sweep: reclaimed" 0 "$rc"
  check "$site sweep: old orphan removed, fresh one kept" "owner owner.reap.2.2" \
    "$(entries "$lock")"
  # A live holder (fresh dir, fresh token) is a plain miss with no side effect.
  d="$work/live.$site"; mkdir -p "$d"; lock="$d/the.lock"
  must mkdir "$lock"; echo 424242 > "$lock/owner"
  read -r rc _ < <(bash "$drv" "$funcs" "$site" "$lock" "" "" "" 2>/dev/null </dev/null)
  check "$site live lock: miss" 1 "$rc"
  check "$site live lock: token untouched" 424242 "$(cat "$lock/owner")"
  # A symlink at the lock path, however old, is never reclaimed through.
  d="$work/link.$site"; mkdir -p "$d/target"; echo 424242 > "$d/target/owner"
  must touch -t 202001010000 "$d/target/owner" "$d/target"
  ln -s "$d/target" "$d/the.lock"
  read -r rc _ < <(bash "$drv" "$funcs" "$site" "$d/the.lock" "" "" "" 2>/dev/null </dev/null)
  check "$site symlinked lock: miss" 1 "$rc"
  check "$site symlinked lock: target's token untouched" 424242 "$(cat "$d/target/owner")"
done

# --- 5. three reclaimers: the capture-less one must not claim ---------------
# B and C both read the stale age and park at `date`. A reclaims to
# completion. B resumes, captures A's fresh token and parks after its mv.
# C resumes: nothing to capture. Without a re-check C went straight to the
# O_EXCL claim, won it, and A and C both owned the lock. Then B resumes and
# hands A's token back.
for site in wh ta; do
  d="$work/three.$site"; mkdir -p "$d"; lock="$d/the.lock"
  must age_lock "$lock"
  PATH="$shim:$PATH" RACE_HOLD_UNTIL="$d/b_go" RACE_MV_HOLD="$d/b_mv" \
    bash "$drv" "$funcs" "$site" "$lock" "" "" "" > "$d/ob" 2>/dev/null </dev/null & pb=$!
  PATH="$shim:$PATH" RACE_HOLD_UNTIL="$d/c_go" \
    bash "$drv" "$funcs" "$site" "$lock" "" "" "" > "$d/oc" 2>/dev/null </dev/null & pc=$!
  parked=no; wait_for "$d/b_go.parked" "$d/c_go.parked" && parked=yes
  check "$site three: B and C parked after their age checks" yes "$parked"
  bash "$drv" "$funcs" "$site" "$lock" "" "" "" > "$d/oa" 2>/dev/null </dev/null
  : > "$d/b_go"
  parked=no; wait_for "$d/b_mv.parked" && parked=yes
  check "$site three: B parked holding its capture" yes "$parked"
  : > "$d/c_go"; wait "$pc"
  : > "$d/b_mv"; wait "$pb"
  read -r rca pida < "$d/oa"; read -r rcb _ < "$d/ob"; read -r rcc _ < "$d/oc"
  check "$site three: only A owns (A B C)" "0 1 1" "$rca $rcb $rcc"
  check "$site three: A's token is back in place" "$pida" "$(cat "$lock/owner" 2>/dev/null)"
  check "$site three: no captured token left behind" 0 \
    "$(find "$lock" -name 'owner.reap.*' 2>/dev/null | wc -l | tr -d ' ')"
done

# --- 6. A releases while B holds a capture of A's token ---------------------
# B parks at `date` with the stale view, A reclaims, B captures A's token
# and parks. A now releases: its token is not at owner (B has it), so the
# old release's rmdir failed on B's capture and B then put A's token back,
# leaving an ownerless lock for a whole staleness window.
for site in wh ta; do
  d="$work/rel.$site"; mkdir -p "$d"; lock="$d/the.lock"
  must age_lock "$lock"
  PATH="$shim:$PATH" RACE_HOLD_UNTIL="$d/b_go" RACE_MV_HOLD="$d/b_mv" \
    bash "$drv" "$funcs" "$site" "$lock" "" "" "" > "$d/ob" 2>"$d/eb" </dev/null & pb=$!
  wait_for "$d/b_go.parked"
  HOLD_WON="$d/a_won" HOLD_REL="$d/a_rel" \
    bash "$drv" "$funcs" "$site-hold" "$lock" "" "" "" > "$d/oa" 2>/dev/null </dev/null & pa=$!
  wait_for "$d/a_won"
  : > "$d/b_go"
  parked=no; wait_for "$d/b_mv.parked" && parked=yes
  check "$site release: B parked holding A's token" yes "$parked"
  : > "$d/a_rel"; wait "$pa"
  : > "$d/b_mv"; wait "$pb"
  read -r rca _ < "$d/oa"; read -r rcb _ < "$d/ob"
  check "$site release: A won, B missed" "0 1" "$rca $rcb"
  check "$site release: lock gone after A's release" no \
    "$([[ -e "$lock" || -L "$lock" ]] && echo yes || echo no)"
  check "$site release: B printed nothing (a vanished capture is normal)" "" "$(cat "$d/eb")"
done

# --- 7. hand-back blocked by a token that appeared meanwhile: say so --------
for site in wh ta; do
  d="$work/blocked.$site"; mkdir -p "$d"; lock="$d/the.lock"
  must age_lock "$lock"
  PATH="$shim:$PATH" RACE_HOLD_UNTIL="$d/b_go" RACE_MV_HOLD="$d/b_mv" \
    bash "$drv" "$funcs" "$site" "$lock" "" "" "" > "$d/ob" 2>"$d/eb" </dev/null & pb=$!
  wait_for "$d/b_go.parked"
  bash "$drv" "$funcs" "$site" "$lock" "" "" "" > /dev/null 2>&1 </dev/null
  : > "$d/b_go"; wait_for "$d/b_mv.parked"
  echo 777 > "$lock/owner"            # someone else's token, in the gap
  : > "$d/b_mv"; wait "$pb"
  read -r rcb _ < "$d/ob"
  check "$site blocked hand-back: B misses" 1 "$rcb"
  check "$site blocked hand-back: the newer token is not replaced" 777 "$(cat "$lock/owner")"
  check "$site blocked hand-back: one stderr line" 1 \
    "$(grep -c 'could not hand a live holder' "$d/eb")"
done

# --- 8. a release by a non-owner leaves the owner's lock alone (#170) ----------
for site in wh ta; do
  d="$work/nonowner.$site"; mkdir -p "$d"; lock="$d/the.lock"
  mkdir "$lock" && echo 777 > "$lock/owner" && echo 555 > "$lock/owner.reap.other"
  bash "$drv" "$funcs" "$site-release" "$lock" "" "" "" > "$d/o" 2>"$d/e" </dev/null
  check "$site non-owner release: owner's token intact" 777 "$(cat "$lock/owner" 2>/dev/null)"
  check "$site non-owner release: other owner's capture intact" 555 "$(cat "$lock/owner.reap.other" 2>/dev/null)"
  check "$site non-owner release: lock dir still there" yes \
    "$([[ -d "$lock" ]] && echo yes || echo no)"
  check "$site non-owner release: silent" "" "$(cat "$d/e")"
done

# --- 9. residual window of #168: hand-back after the release's first rmdir ---
# A holds the lock; B has captured A's token (owner.reap.*) and is about to
# hand it back. A's release runs its first rmdir (fails on the capture) and
# parks; the hand-back lands (hard link, as the reclaim does); A then sweeps
# the capture and its rmdir fails on the handed-back token. The lock must
# still be freed, which needs a second pass that removes A's OWN token.
# An rmdir shim parks the release right after its first failing rmdir.
cat > "$shim/rmdir" <<SHIM
#!/usr/bin/env bash
"$(command -v rmdir)" "\$@"; rc=\$?
if [[ -n "\${RACE_RMDIR_HOLD:-}" && \$rc -ne 0 && ! -e "\${RACE_RMDIR_HOLD}.passed" ]]; then
  : > "\${RACE_RMDIR_HOLD}.parked"
  n=0
  while [[ ! -e "\$RACE_RMDIR_HOLD" ]] && (( n < 1000 )); do
    sleep 0.01 2>/dev/null || sleep 1; n=\$((n + 1))
  done
  : > "\${RACE_RMDIR_HOLD}.passed"
fi
exit \$rc
SHIM
chmod +x "$shim/rmdir"
for site in wh ta; do
  d="$work/handback.$site"; mkdir -p "$d"; lock="$d/the.lock"
  PATH="$shim:$PATH" RACE_RMDIR_HOLD="$d/r_go" HOLD_WON="$d/a_won" HOLD_REL="$d/a_rel" \
    bash "$drv" "$funcs" "$site-hold" "$lock" "" "" "" > "$d/oa" 2>/dev/null </dev/null & pa=$!
  wait_for "$d/a_won"
  atok="$(cat "$lock/owner")"
  # B's capture of A's token, as the reclaim leaves it mid-flight.
  mv "$lock/owner" "$lock/owner.reap.B.1"
  : > "$d/a_rel"
  parked=no; wait_for "$d/r_go.parked" && parked=yes
  check "$site hand-back window: release parked after its first rmdir" yes "$parked"
  ln "$lock/owner.reap.B.1" "$lock/owner"          # B's hand-back lands
  : > "$d/r_go"; wait "$pa"
  check "$site hand-back window: the token handed back was A's" "$atok" \
    "$(cat "$d/oa" | awk 'NR==1{print $2}')"
  check "$site hand-back window: lock freed by A's release" no \
    "$([[ -e "$lock" || -L "$lock" ]] && echo yes || echo no)"
done

# --- 10. two reapers in turn (the reviewer's sim) -----------------------------
# A's release parks after its first failing rmdir (B holds a capture). B's
# hand-back lands, A's sweep removes the capture and parks right after that
# rm; C then captures the handed-back token. The release must still free the
# lock; C's hand-back afterwards must find nothing to hand back.
cat > "$shim/rm" <<SHIM
#!/usr/bin/env bash
"$(command -v rm)" "\$@"; rc=\$?
if [[ -n "\${RACE_RM_REMAT:-}" ]]; then
  for a in "\$@"; do case "\$a" in */owner) echo "\$PPID" > "\$a" ;; esac; done
fi
case "\$*" in
  *owner.reap.*)
    if [[ -n "\${RACE_RM_HOLD:-}" && ! -e "\${RACE_RM_HOLD}.passed" ]]; then
      : > "\${RACE_RM_HOLD}.parked"
      n=0
      while [[ ! -e "\$RACE_RM_HOLD" ]] && (( n < 1000 )); do
        sleep 0.01 2>/dev/null || sleep 1; n=\$((n + 1))
      done
      : > "\${RACE_RM_HOLD}.passed"
    fi ;;
esac
exit \$rc
SHIM
chmod +x "$shim/rm"
for site in wh ta; do
  d="$work/two.$site"; mkdir -p "$d"; lock="$d/the.lock"
  PATH="$shim:$PATH" RACE_RMDIR_HOLD="$d/r_go" RACE_RM_HOLD="$d/m_go" HOLD_WON="$d/a_won" HOLD_REL="$d/a_rel" \
    bash "$drv" "$funcs" "$site-hold" "$lock" "" "" "" > "$d/oa" 2>/dev/null </dev/null & pa=$!
  wait_for "$d/a_won"
  mv "$lock/owner" "$lock/owner.reap.B"             # B captures A's token
  : > "$d/a_rel"
  parked=no; wait_for "$d/r_go.parked" && parked=yes
  check "$site two reapers: release parked after its first rmdir" yes "$parked"
  ln "$lock/owner.reap.B" "$lock/owner"              # B hands back
  : > "$d/r_go"
  parked=no; wait_for "$d/m_go.parked" && parked=yes
  check "$site two reapers: release parked after sweeping B's capture" yes "$parked"
  [[ -e "$lock/owner" ]] && mv "$lock/owner" "$lock/owner.reap.C"   # C captures it
  : > "$d/m_go"; wait "$pa"
  # C's hand-back: only possible if its capture survived the release.
  if [[ -e "$lock/owner.reap.C" ]]; then
    ln "$lock/owner.reap.C" "$lock/owner" 2>/dev/null && rm -f "$lock/owner.reap.C"
  fi
  check "$site two reapers: lock freed, no ownerless token left" no \
    "$([[ -e "$lock" || -L "$lock" ]] && echo yes || echo no)"
done

# --- 11. the pass cap: no failure out of a release, one stderr line ----------
# The rm shim re-creates the releaser's token every time the release removes
# it, so the loop can never finish. Run under -e like the hooks' call sites.
for site in wh ta; do
  d="$work/cap.$site"; mkdir -p "$d"; lock="$d/the.lock"
  PATH="$shim:$PATH" RACE_RM_REMAT=1 HOLD_WON="$d/a_won" HOLD_REL="$d/a_rel" HOLD_AFTER="$d/after" \
    bash -e "$drv" "$funcs" "$site-hold" "$lock" "" "" "" > "$d/oa" 2>"$d/ea" </dev/null & pa=$!
  wait_for "$d/a_won"; : > "$d/a_rel"; wait "$pa"; rcp=$?
  check "$site pass cap: process exit status" 0 "$rcp"
  check "$site pass cap: the statement after the release ran" yes \
    "$([[ -e "$d/after" ]] && echo yes || echo no)"
  check "$site pass cap: exactly one stderr line" 1 "$(grep -c 'release gave up after 16 passes' "$d/ea")"
  check "$site pass cap: nothing else on stderr" 1 "$(wc -l < "$d/ea" | tr -d ' ')"
done

# --- 12. hand-back between the owner check and the capture sweep ---------------
# A's token sits in a capture (owner absent). The release's first rmdir fails
# and parks; the reclaimer then hands the token back and removes its capture,
# so the sweep finds nothing and removed stays 0. Only a re-check of owner
# sees the token that is ours again.
for site in wh ta; do
  d="$work/recheck.$site"; mkdir -p "$d"; lock="$d/the.lock"
  PATH="$shim:$PATH" RACE_RMDIR_HOLD="$d/r_go" HOLD_WON="$d/a_won" HOLD_REL="$d/a_rel" \
    bash "$drv" "$funcs" "$site-hold" "$lock" "" "" "" > "$d/oa" 2>/dev/null </dev/null & pa=$!
  wait_for "$d/a_won"
  mv "$lock/owner" "$lock/owner.reap.B"
  : > "$d/a_rel"
  parked=no; wait_for "$d/r_go.parked" && parked=yes
  check "$site re-check: release parked after its first rmdir" yes "$parked"
  ln "$lock/owner.reap.B" "$lock/owner" && rm -f "$lock/owner.reap.B"
  : > "$d/r_go"; wait "$pa"
  check "$site re-check: lock freed, no token of ours left behind" no \
    "$([[ -e "$lock" || -L "$lock" ]] && echo yes || echo no)"
done


# --- 13. no hard links: the hand-back keeps the token (#188) -----------------
# An `ln` on PATH that always fails the way link(2) does on a filesystem
# without hard links. It logs each call so the test can show it was used.
nolink="$work/nolink"; mkdir -p "$nolink"
cat > "$nolink/ln" <<SHIM
#!/usr/bin/env bash
echo x >> "$nolink/calls"
echo "ln: \${2:-?}: Operation not supported" >&2
exit 1
SHIM
chmod +x "$nolink/ln"
for site in wh ta; do
  d="$work/nolink.$site"; mkdir -p "$d"; lock="$d/the.lock"
  must age_lock "$lock"
  rm -f "$nolink/calls"
  PATH="$nolink:$shim:$PATH" RACE_HOLD_UNTIL="$d/b_go" \
    bash "$drv" "$funcs" "$site" "$lock" "" "" "" > "$d/ob" 2>"$d/eb" </dev/null & pb=$!
  parked=no; wait_for "$d/b_go.parked" && parked=yes
  check "$site no hard links: B parked after its age check" yes "$parked"
  PATH="$nolink:$PATH" HOLD_WON="$d/a_won" HOLD_REL="$d/a_rel" \
    bash "$drv" "$funcs" "$site-hold" "$lock" "" "" "" > "$d/oa" 2>/dev/null </dev/null & pa=$!
  wait_for "$d/a_won"
  toka="$(cat "$lock/owner" 2>/dev/null)"
  : > "$d/b_go"; wait "$pb"
  read -r rcb _ < "$d/ob"
  check "$site no hard links: the ln stub was called" yes \
    "$([[ -s "$nolink/calls" ]] && echo yes || echo no)"
  check "$site no hard links: B misses" 1 "$rcb"
  check "$site no hard links: A's token is back at owner" "$toka" \
    "$([[ -n "$toka" && -f "$lock/owner" ]] && cat "$lock/owner")"
  check "$site no hard links: no captured token left behind" 0 \
    "$(find "$lock" -name 'owner.reap.*' 2>/dev/null | wc -l | tr -d ' ')"
  check "$site no hard links: B printed nothing" "" "$(cat "$d/eb")"
  read -r rcc _ < <(PATH="$nolink:$PATH" bash "$drv" "$funcs" "$site" "$lock" "" "" "" 2>/dev/null </dev/null)
  check "$site no hard links: a third acquirer misses" 1 "$rcc"
  check "$site no hard links: A's token survives the third acquirer" "$toka" \
    "$(cat "$lock/owner" 2>/dev/null)"
  : > "$d/a_rel"; wait "$pa"
  read -r rca _ < "$d/oa"
  check "$site no hard links: A won" 0 "$rca"
  check "$site no hard links: A's release frees the lock" no \
    "$([[ -e "$lock" || -L "$lock" ]] && echo yes || echo no)"
done

# --- 14. no hard links, a token appeared meanwhile: never replaced ----------
for site in wh ta; do
  d="$work/nolinkblocked.$site"; mkdir -p "$d"; lock="$d/the.lock"
  must age_lock "$lock"
  rm -f "$nolink/calls"
  PATH="$nolink:$shim:$PATH" RACE_HOLD_UNTIL="$d/b_go" RACE_MV_HOLD="$d/b_mv" \
    bash "$drv" "$funcs" "$site" "$lock" "" "" "" > "$d/ob" 2>"$d/eb" </dev/null & pb=$!
  wait_for "$d/b_go.parked"
  bash "$drv" "$funcs" "$site" "$lock" "" "" "" > /dev/null 2>&1 </dev/null
  : > "$d/b_go"
  parked=no; wait_for "$d/b_mv.parked" && parked=yes
  check "$site no hard links, blocked: B parked holding its capture" yes "$parked"
  echo 777 > "$lock/owner"            # someone else's token, in the gap
  : > "$d/b_mv"; wait "$pb"
  read -r rcb _ < "$d/ob"
  check "$site no hard links, blocked: the ln stub was called" yes \
    "$([[ -s "$nolink/calls" ]] && echo yes || echo no)"
  check "$site no hard links, blocked: B misses" 1 "$rcb"
  check "$site no hard links, blocked: the newer token is not replaced" 777 "$(cat "$lock/owner")"
  check "$site no hard links, blocked: one stderr line" 1 \
    "$(grep -c 'could not hand a live holder' "$d/eb")"
done

# --- 15. the fallback's own windows, parked inside B (#199 review) ----------
# B parks after its age check (date shim), A reclaims and holds, B captures
# A's token, its ln fails, and a DEBUG trap parks it at the named command.
# mvn/mv models BSD `mv -n` (check, then rename(2), which replaces): it parks
# between the check and the rename at the same hold file, so the rename-back
# the PR rejects meets the same interleaving. The reclaim itself never runs
# `mv -n`, so for this code that branch is inert.
mvn="$work/mvn"; mkdir -p "$mvn"
cat > "$mvn/mv" <<SHIM
#!/usr/bin/env bash
if [[ "\${1:-}" == -n && -n "\${RACE_DBG_HOLD:-}" ]]; then
  shift
  [[ -e "\$2" ]] && exit 0
  : > "\${RACE_DBG_HOLD}.parked"
  n=0
  while [[ ! -e "\$RACE_DBG_HOLD" ]] && (( n < 1000 )); do
    sleep 0.01 2>/dev/null || sleep 1; n=\$((n + 1))
  done
  : > "\${RACE_DBG_HOLD}.passed"
fi
exec "$real_mv" "\$@"
SHIM
chmod +x "$mvn/mv"
# fb_start <dir> <lock> <match>: age the lock, start B (parks at date) and
# A (reclaims and holds). The caller then touches $d/b_go to send B on to its
# capture and the park at <match>. Sets pa pb.
fb_start() {
  local d="$1" lock="$2" match="$3"
  must age_lock "$lock"
  PATH="$mvn:$nolink:$shim:$PATH" RACE_HOLD_UNTIL="$d/b_go" \
    RACE_DBG_HOLD="$d/b_dbg" RACE_DBG_MATCH="$match" \
    bash "$drv" "$funcs" "$site" "$lock" "" "" "" > "$d/ob" 2>"$d/eb" </dev/null & pb=$!
  wait_for "$d/b_go.parked"
  HOLD_WON="$d/a_won" HOLD_REL="$d/a_rel" HOLD_AFTER="$d/a_after" \
    bash "$drv" "$funcs" "$site-hold" "$lock" "" "" "" > "$d/oa" 2>/dev/null </dev/null & pa=$!
  wait_for "$d/a_won"
}
for site in wh ta; do
  # (a) release + new dir between B's read and its re-check.
  d="$work/fb_recheck.$site"; mkdir -p "$d"; lock="$d/the.lock"
  fb_start "$d" "$lock" "[[ -z \"\$tok\" ]]"; : > "$d/b_go"
  parked=no; wait_for "$d/b_dbg.parked" && parked=yes
  check "$site fallback re-check: B parked after its read" yes "$parked"
  : > "$d/a_rel"; wait "$pa"
  gone=no; [[ -e "$lock" ]] || gone=yes
  check "$site fallback re-check: A's release removed B's capture and the dir" yes "$gone"
  mkdir "$lock"                                  # a new acquirer, not yet claimed
  : > "$d/b_dbg"; wait "$pb"
  read -r rcb _ < "$d/ob"
  check "$site fallback re-check: B misses" 1 "$rcb"
  check "$site fallback re-check: no stray token in the new dir" "" "$(entries "$lock")"
  check "$site fallback re-check: B printed nothing" "" "$(cat "$d/eb")"

  # (b) an owner appears between B's read and its create.
  d="$work/fb_excl.$site"; mkdir -p "$d"; lock="$d/the.lock"
  fb_start "$d" "$lock" "printf '%s\n' \"\$tok\""; : > "$d/b_go"
  parked=no; wait_for "$d/b_dbg.parked" && parked=yes
  check "$site fallback O_EXCL: B parked before its create" yes "$parked"
  echo 777 > "$lock/owner"                       # someone else's token, in the gap
  : > "$d/b_dbg"; wait "$pb"
  read -r rcb _ < "$d/ob"
  check "$site fallback O_EXCL: B misses" 1 "$rcb"
  check "$site fallback O_EXCL: the newer token is not replaced" 777 "$(cat "$lock/owner" 2>/dev/null)"
  check "$site fallback O_EXCL: one stderr line" 1 \
    "$(grep -c 'could not hand a live holder' "$d/eb")"
  : > "$d/a_rel"; wait "$pa"

  # (c) the holder releases between B's re-check and its create.
  d="$work/fb_gone.$site"; mkdir -p "$d"; lock="$d/the.lock"
  fb_start "$d" "$lock" "printf '%s\n' \"\$tok\""; : > "$d/b_go"
  wait_for "$d/b_dbg.parked"
  : > "$d/a_rel"; wait "$pa"
  : > "$d/b_dbg"; wait "$pb"
  read -r rcb _ < "$d/ob"
  check "$site fallback lock gone: B misses" 1 "$rcb"
  check "$site fallback lock gone: lock dir not re-created" no \
    "$([[ -e "$lock" ]] && echo yes || echo no)"
  check "$site fallback lock gone: B printed nothing" "" "$(cat "$d/eb")"

  # (d) an empty capture (a claim captured between its create and its
  # write) that stays empty: not handed back, owner stays absent.
  d="$work/fb_empty.$site"; mkdir -p "$d"; lock="$d/the.lock"
  fb_start "$d" "$lock" "no park"
  : > "$lock/owner"                              # fresh and empty
  : > "$d/b_go"; wait "$pb"
  read -r rcb _ < "$d/ob"
  check "$site fallback empty token: B misses" 1 "$rcb"
  check "$site fallback empty token: no empty owner, no capture left" "" "$(entries "$lock")"
  check "$site fallback empty token: one stderr line" 1 \
    "$(grep -c 'captured an empty token' "$d/eb")"
  read -r rcc _ < <(PATH="$nolink:$PATH" bash "$drv" "$funcs" "$site" "$lock" "" "" "" 2>/dev/null </dev/null)
  check "$site fallback empty token: a third acquirer misses" 1 "$rcc"
  : > "$d/a_rel"; wait "$pa"
  check "$site fallback empty token: A's release frees the lock" no \
    "$([[ -e "$lock" ]] && echo yes || echo no)"

  # (d') an empty capture filled during the pause (the claim's write lands
  # in the capture): the re-read hands it back.
  d="$work/fb_fill.$site"; mkdir -p "$d"; lock="$d/the.lock"
  fb_start "$d" "$lock" "sleep 0.1"
  toka="$(cat "$lock/owner")"
  : > "$lock/owner"
  : > "$d/b_go"
  parked=no; wait_for "$d/b_dbg.parked" && parked=yes
  check "$site fallback re-read: B parked in its pause" yes "$parked"
  for g in "$lock"/owner.reap.*; do echo "$toka" > "$g"; done
  : > "$d/b_dbg"; wait "$pb"
  check "$site fallback re-read: A's token is back at owner" "$toka" "$(cat "$lock/owner" 2>/dev/null)"
  check "$site fallback re-read: B printed nothing" "" "$(cat "$d/eb")"
  : > "$d/a_rel"; wait "$pa"
  check "$site fallback re-read: A's release frees the lock" no \
    "$([[ -e "$lock" ]] && echo yes || echo no)"
done

# --- 16. the barrier race of group 1, with no hard links (#188) -------------
# Without help two free-running racers essentially never reach the hand-back
# (measured: 0 ln calls in 40 iterations, and 0 across a sweep of fixed start
# offsets): the loser captures a live token only if its stretch from age
# check to capture (one `date`, then `mv`) outlasts the winner's from capture
# to claim (`mv`, two `stat`s, `rm -rf`, the claim), so it needs to be
# descheduled there. A `date` that sleeps 0 to 90 ms at random, called by
# every racer between its age check and its capture, supplies that without
# ordering anyone (measured: 15 hand-backs in 20 iterations).
jitter="$work/jitter"; mkdir -p "$jitter"
cat > "$jitter/date" <<SHIM
#!/usr/bin/env bash
sleep "0.0\$(( RANDOM % 10 ))" 2>/dev/null || true
exec "$real_date" "\$@"
SHIM
chmod +x "$jitter/date"
NL_N=$(( N / 4 )); (( NL_N < 5 )) && NL_N=5
for site in wh ta; do
  bad=0; tokbad=0; first_bad=""
  rm -f "$nolink/calls"
  for i in $(seq 1 "$NL_N"); do
    d="$work/nlrace.$site.$i"; mkdir -p "$d"; lock="$d/the.lock"
    age_lock "$lock" || { bad=$((bad + 1)); continue; }
    PATH="$jitter:$nolink:$PATH" \
      bash "$drv" "$funcs" "$site" "$lock" "$d/go" "$d/r1" "" > "$d/o1" 2>/dev/null </dev/null & p1=$!
    PATH="$jitter:$nolink:$PATH" \
      bash "$drv" "$funcs" "$site" "$lock" "$d/go" "$d/r2" "" > "$d/o2" 2>/dev/null </dev/null & p2=$!
    wait_for "$d/r1" "$d/r2"
    : > "$d/go"
    wait "$p1"; wait "$p2"
    read -r rc1 pid1 < "$d/o1"; read -r rc2 pid2 < "$d/o2"
    wins=0; winner=""
    if [[ "$rc1" == 0 ]]; then wins=$((wins + 1)); winner="$pid1"; fi
    if [[ "$rc2" == 0 ]]; then wins=$((wins + 1)); winner="$pid2"; fi
    if (( wins != 1 )); then
      bad=$((bad + 1)); [[ -n "$first_bad" ]] || first_bad="$i"
    elif [[ "$(cat "$lock/owner" 2>/dev/null)" != "$winner" ]]; then
      tokbad=$((tokbad + 1)); [[ -n "$first_bad" ]] || first_bad="$i"
    fi
    rm -rf "$d"
  done
  [[ -n "$first_bad" ]] && echo "  (site $site, no hard links: first bad iteration $first_bad of $NL_N)"
  echo "  (site $site, no hard links: the ln stub ran $( [[ -f "$nolink/calls" ]] && wc -l < "$nolink/calls" | tr -d ' ' || echo 0) times in $NL_N iterations)"
  check "$site no-link barrier race x$NL_N: iterations without exactly one winner" 0 "$bad"
  check "$site no-link barrier race x$NL_N: iterations where the token is not the winner's" 0 "$tokbad"
done

finish
