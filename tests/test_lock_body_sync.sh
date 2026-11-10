#!/usr/bin/env bash
# #189: the mkdir-lock functions exist twice, in bin/write_handoff.sh and in
# bin/handoff_turn_append.sh, and the comments ask that the two copies be
# kept in sync. Until this test nothing checked it: PR #183 (#170) edited
# both release bodies by hand and compared them by eye. This test extracts
# each pair by name and diffs the bodies against EACH OTHER (never against a
# fixture), so it passes for any lock change made to both scripts alike and
# fails, printing the diff, for a change made to one of them only.
#
# Pairs: claim_mkdir_lock / ta_claim_lock, release_mkdir_lock /
# ta_release_lock, reclaim_stale_mkdir_lock / ta_reclaim_stale_lock.
# Extraction is the same `sed -n '/^name() {/,/^}/p'` that
# tests/test_lock_reclaim_single_winner.sh uses (each function ends at the
# first `}` in column 0). What is compared:
#   - every line after the `name() {` line, comments included (the issue:
#     comments inside the bodies are part of the diff), byte for byte;
#   - after one normalization: the turn-append names are mapped to the
#     write_handoff names (ta_claim_lock -> claim_mkdir_lock and so on), so a
#     body that calls its own script's claim helper still compares equal.
# The `name() {` line itself is left out: it carries the name and a one-line
# trailing comment that is allowed to differ per script.
# A negative control at the end proves the comparison goes red on a one-line
# drift (a gate is proven by defeating it).
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
WH="$REPO_ROOT/bin/write_handoff.sh"
TA="$REPO_ROOT/bin/handoff_turn_append.sh"

echo "lock function bodies are identical in both scripts (#189)"

work="$(mktemp -d)"; cleanup_on_exit "$work"

# body <script> <function>: the function's lines after its `name() {` line,
# with the ta_ names mapped to the write_handoff names. Empty when the
# function is missing.
body() {
  sed -n "/^$2() {/,/^}/p" "$1" | sed 1d \
    | sed -e 's/ta_reclaim_stale_lock/reclaim_stale_mkdir_lock/g' \
          -e 's/ta_release_lock/release_mkdir_lock/g' \
          -e 's/ta_claim_lock/claim_mkdir_lock/g'
}

# compare_pair <wh_script> <ta_script> <wh_fn> <ta_fn> <label>
compare_pair() {
  local a="$work/$5.wh" b="$work/$5.ta" d
  body "$1" "$3" > "$a"
  body "$2" "$4" > "$b"
  check "$5: $3 found in $(basename "$1")" yes "$([[ -s "$a" ]] && echo yes || echo no)"
  check "$5: $4 found in $(basename "$2")" yes "$([[ -s "$b" ]] && echo yes || echo no)"
  if d="$(diff -u "$a" "$b")"; then
    check "$5: $3 and $4 bodies identical" same same
  else
    printf '%s\n' "$d" | sed 's/^/    /'
    check "$5: $3 and $4 bodies identical" same differ
  fi
}

compare_pair "$WH" "$TA" claim_mkdir_lock ta_claim_lock claim
compare_pair "$WH" "$TA" release_mkdir_lock ta_release_lock release
compare_pair "$WH" "$TA" reclaim_stale_mkdir_lock ta_reclaim_stale_lock reclaim

# Negative control: a copy of handoff_turn_append.sh with one line of
# ta_release_lock changed (the pass cap) must make the comparison differ, and
# with one comment line changed as well (comments are compared too).
drift="$work/drift_ta.sh"
sed '/^ta_release_lock() {/,/^}/ s/pass < 16/pass < 17/' "$TA" > "$drift"
must grep -q 'pass < 17' "$drift"
if diff -q <(body "$WH" release_mkdir_lock) <(body "$drift" ta_release_lock) >/dev/null; then
  r=same; else r=differ; fi
check "negative control: a one-line code drift is caught" differ "$r"
sed '/^ta_reclaim_stale_lock() {/,/^}/ s/# Age via GNU/# Age, via GNU/' "$TA" > "$drift"
must grep -q '# Age, via GNU' "$drift"
if diff -q <(body "$WH" reclaim_stale_mkdir_lock) <(body "$drift" ta_reclaim_stale_lock) >/dev/null; then
  r=same; else r=differ; fi
check "negative control: a one-line comment drift is caught" differ "$r"

finish
