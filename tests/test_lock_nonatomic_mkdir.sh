#!/usr/bin/env bash
# #153: the mkdir try-lock is not atomic under uutils coreutils (Ubuntu
# 25.10+/26.04, GitHub's ubuntu-latest runner): two racing callers can BOTH get
# exit 0 from `mkdir` on the same directory (measured 151 of 1000 pairs, same
# inode). Ownership is therefore settled by a token the shell creates inside
# the lock dir with noclobber (claim_mkdir_lock / ta_claim_lock). This file
# makes the race deterministic with a `mkdir` shim that always reports
# success, which is exactly what uutils tells the loser, and asserts that
# exclusion still holds for every mkdir lock in write_handoff.sh and
# handoff_turn_append.sh. The nondeterministic concurrent smoke in
# test_write_handoff_concurrency.sh stays as the end-to-end check.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
WH="$REPO_ROOT/bin/write_handoff.sh"
TA="$REPO_ROOT/bin/handoff_turn_append.sh"
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

echo "mkdir locks: ownership survives a non-atomic mkdir (#153)"

# PATH shim: a `mkdir` that creates what it can and ALWAYS exits 0. Every
# other tool resolves to the real one further down PATH.
shim="$(mktemp -d)"; cleanup_on_exit "$shim"
real_mkdir="$(command -v mkdir)"
printf '#!/usr/bin/env bash\n"%s" "$@" 2>/dev/null\nexit 0\n' "$real_mkdir" > "$shim/mkdir"
chmod +x "$shim/mkdir"
SHIMPATH="$shim:$PATH"
probe="$(mktemp -d)"
check "shim: mkdir on an existing dir still exits 0" 0 \
  "$(PATH="$SHIMPATH" mkdir "$probe" >/dev/null 2>&1; echo $?)"
rm -rf "$probe"

# --- write lock held by a LIVE peer (dir + owner token): hook run yields -----
# Under GNU mkdir the loser fails at mkdir; under the shim it "succeeds" and
# must lose at the token instead. Same observable outcome either way.
repo="$(mk_repo)"
must mkdir -p "$repo/.claude/.handoff_write.lock"
echo 424242 > "$repo/.claude/.handoff_write.lock/owner"
err="$( cd "$repo" && PATH="$SHIMPATH" bash "$WH" --if-curated 2>&1 >/dev/null )"; rc=$?
check "held write lock + shim: exit 0"                 0   "$rc"
check "held write lock + shim: skip is reported"       yes "$(has "$err" "SKIPPING this safety-net write")"
check "held write lock + shim: nothing published"      no \
  "$([[ -f "$repo/.claude/handoff_current.md" ]] && echo yes || echo no)"
check "held write lock + shim: peer's dir left"        yes \
  "$([[ -d "$repo/.claude/.handoff_write.lock" ]] && echo yes || echo no)"
check "held write lock + shim: peer's token untouched" 424242 \
  "$(cat "$repo/.claude/.handoff_write.lock/owner" 2>/dev/null)"
rm -rf "$repo"

# --- gitignore lock held by a LIVE peer: bootstrap skipped, write proceeds ----
repo="$(mk_repo)"                          # no .gitignore
must mkdir -p "$repo/.claude/.handoff_gitignore.lock"
echo 424242 > "$repo/.claude/.handoff_gitignore.lock/owner"
( cd "$repo" && PATH="$SHIMPATH" bash "$WH" >/dev/null 2>&1 </dev/null ); rc=$?
check "held gi lock + shim: exit 0"              0   "$rc"
check "held gi lock + shim: bootstrap skipped"   no  "$([[ -f "$repo/.gitignore" ]] && echo yes || echo no)"
check "held gi lock + shim: handoff written"     yes "$([[ -f "$repo/.claude/handoff_current.md" ]] && echo yes || echo no)"
check "held gi lock + shim: peer's token untouched" 424242 \
  "$(cat "$repo/.claude/.handoff_gitignore.lock/owner" 2>/dev/null)"
rm -rf "$repo"

# --- STALE write lock WITH a dead holder's token: reclaimed and released ------
# The token makes the dir non-empty, so a reclaim that only rmdir'd would wedge.
repo="$(mk_repo)"
must mkdir -p "$repo/.claude/.handoff_write.lock"
echo 424242 > "$repo/.claude/.handoff_write.lock/owner"
# Age the token as well as the dir, as a real dead holder's would be: writing
# the token updates the dir's mtime, so a token newer than its dir only
# happens when a reclaimer won after another's age check, and the #155
# reclaim then hands it back instead of taking it.
touch -t 202001010000 "$repo/.claude/.handoff_write.lock/owner"
touch -t 202001010000 "$repo/.claude/.handoff_write.lock"   # POSIX touch -t
( cd "$repo" && PATH="$SHIMPATH" HANDOFF_LOCK_STALE_SECS=1 bash "$WH" --if-curated >/dev/null 2>&1 ); rc=$?
check "stale write lock with token: exit 0"          0   "$rc"
check "stale write lock with token: handoff written" yes "$([[ -f "$repo/.claude/handoff_current.md" ]] && echo yes || echo no)"
check "stale write lock with token: released after"  no  "$([[ -e "$repo/.claude/.handoff_write.lock" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- Normal run under the shim: both locks taken, released, no token litter --
repo="$(mk_repo)"
( cd "$repo" && PATH="$SHIMPATH" bash "$WH" >/dev/null 2>&1 </dev/null ); rc=$?
check "normal run + shim: exit 0"                  0   "$rc"
check "normal run + shim: gitignore bootstrapped"  1   "$(grep -c '^\.claude/handoff_current\.md$' "$repo/.gitignore" 2>/dev/null)"
check "normal run + shim: no lock dirs left"       0 \
  "$(find "$repo/.claude" -maxdepth 1 -name '.handoff_*.lock' 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$repo"

# --- Two simultaneous runs under the shim: exclusion must hold every time ----
# With mkdir always "succeeding" for both, the token is the ONLY thing standing
# between the two bootstraps, so this is the deterministic form of the smoke in
# test_write_handoff_concurrency.sh. Repeated to cover both win orders.
for round in 1 2 3; do
  repo="$(mk_repo)"
  ( cd "$repo" && PATH="$SHIMPATH" bash "$WH" >/dev/null 2>&1 </dev/null ) & p1=$!
  ( cd "$repo" && PATH="$SHIMPATH" bash "$WH" >/dev/null 2>&1 </dev/null ) & p2=$!
  wait "$p1"; rc1=$?; wait "$p2"; rc2=$?
  check "pair $round + shim: both exit 0"            "0 0" "$rc1 $rc2"
  check "pair $round + shim: no duplicated .gitignore lines" "" \
    "$(sort "$repo/.gitignore" 2>/dev/null | uniq -d)"
  check "pair $round + shim: exactly one handoff_current.md" 1 \
    "$(find "$repo/.claude" -maxdepth 1 -name 'handoff_current.md' 2>/dev/null | wc -l | tr -d ' ')"
  check "pair $round + shim: no lock dirs left" 0 \
    "$(find "$repo/.claude" -maxdepth 1 -name '.handoff_*.lock' 2>/dev/null | wc -l | tr -d ' ')"
  rm -rf "$repo"
done

# --- handoff_turn_append.sh: the same tie-break on its two locks -------------
if command -v jq >/dev/null 2>&1 && command -v perl >/dev/null 2>&1; then
  run_turn() {  # <cwd> <sid> <transcript> <PATH>
    ( cd "$1" && PATH="$4" printf '{"session_id":"%s","transcript_path":"%s"}' "$2" "$3" \
        | PATH="$4" bash "$TA" >/dev/null 2>&1 )
  }
  # gitignore lock held by a live peer (with token): dump written, append skipped.
  repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; tx="$repo/tx.jsonl"
  printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx"
  must mkdir -p "$repo/.claude/.handoff_gitignore.lock"
  echo 424242 > "$repo/.claude/.handoff_gitignore.lock/owner"
  run_turn "$repo" GIHELD "$tx" "$SHIMPATH"
  check "turn_append held gi lock + shim: dump written"    yes "$([[ -f "$bd/handoff_raw_GIHELD.md" ]] && echo yes || echo no)"
  check "turn_append held gi lock + shim: append skipped"  no \
    "$([[ -f "$repo/.gitignore" ]] && grep -q handoff_backups "$repo/.gitignore" && echo yes || echo no)"
  check "turn_append held gi lock + shim: peer's token untouched" 424242 \
    "$(cat "$repo/.claude/.handoff_gitignore.lock/owner" 2>/dev/null)"
  rm -rf "$repo"
  # Normal fire under the shim: bootstraps once, releases, no token litter.
  repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; tx="$repo/tx.jsonl"
  printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx"
  run_turn "$repo" GIOK "$tx" "$SHIMPATH"
  check "turn_append + shim: bootstrapped once" 1 "$(grep -c '^\.claude/handoff_backups/$' "$repo/.gitignore" 2>/dev/null)"
  check "turn_append + shim: gi lock released"  no "$([[ -e "$repo/.claude/.handoff_gitignore.lock" ]] && echo yes || echo no)"
  rm -rf "$repo"
  # flock-less session lock (the macOS branch): held WITH token blocks; a
  # normal run appends and leaves no lock dir behind.
  noflock="$(path_without flock)"; cleanup_on_exit "$noflock"
  repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; must mkdir -p "$bd"
  must mkdir "$bd/.handoff_raw_HELD.lock.d"
  echo 424242 > "$bd/.handoff_raw_HELD.lock.d/owner"
  tx="$repo/tx.jsonl"; printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx"
  run_turn "$repo" HELD "$tx" "$shim:$noflock"
  check "turn_append no-flock held lock + shim: no append" no "$([[ -f "$bd/handoff_raw_HELD.md" ]] && echo yes || echo no)"
  check "turn_append no-flock held lock + shim: peer's token untouched" 424242 \
    "$(cat "$bd/.handoff_raw_HELD.lock.d/owner" 2>/dev/null)"
  rm -rf "$repo"
  repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"
  tx="$repo/tx.jsonl"; printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx"
  run_turn "$repo" FREE "$tx" "$shim:$noflock"
  check "turn_append no-flock + shim: appends"           yes "$([[ -f "$bd/handoff_raw_FREE.md" ]] && echo yes || echo no)"
  check "turn_append no-flock + shim: lock dir released" no  "$([[ -e "$bd/.handoff_raw_FREE.lock.d" ]] && echo yes || echo no)"
  rm -rf "$repo"
else
  skip "handoff_turn_append.sh checks: jq or perl missing"
fi

finish
