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
for fn in claim_mkdir_lock reclaim_stale_mkdir_lock try_mkdir_lock; do
  sed -n "/^$fn() {/,/^}/p" "$WH" >> "$funcs"
done
for fn in ta_claim_lock ta_reclaim_stale_lock; do
  sed -n "/^$fn() {/,/^}/p" "$TA" >> "$funcs"
done
defined="$(bash -c 'source "$1"; for f in claim_mkdir_lock reclaim_stale_mkdir_lock try_mkdir_lock ta_claim_lock ta_reclaim_stale_lock; do declare -F "$f" >/dev/null || echo "$f"; done' _ "$funcs" </dev/null)"
check "every reclaim function extracted from the scripts" "" "$defined"

# One racer = one bash process (distinct $$, as two hook fires would be).
# Args: <site> <lock> <go-file|""> <ready-file|""> <done-file|"">
# Prints "<rc> <pid>".
drv="$work/racer.sh"
cat > "$drv" <<'DRV'
set -u
source "$1"; site="$2"; lock="$3"; go="$4"; ready="$5"; fin="$6"
if [[ -n "$ready" ]]; then : > "$ready"; fi
if [[ -n "$go" ]]; then
  spins=0
  until [[ -e "$go" ]]; do
    spins=$((spins + 1)); (( spins > 3000000 )) && break
  done
fi
case "$site" in
  wh) try_mkdir_lock "$lock" 2>/dev/null; rc=$? ;;
  ta) { mkdir "$lock" 2>/dev/null && ta_claim_lock "$lock"; } || ta_reclaim_stale_lock "$lock"; rc=$? ;;
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

finish
