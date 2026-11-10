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
#   - the `name() {` line, after stripping the function name and any
#     trailing `#` comment (so code written on the header line is compared,
#     while the per-script one-line comment is allowed to differ);
#   - every following line, comments included (the issue: comments inside the
#     bodies are part of the diff), byte for byte;
#   - after one normalization applied to the TURN-APPEND side only: its names
#     are mapped to the write_handoff names (ta_claim_lock ->
#     claim_mkdir_lock and so on), so a body that calls its own script's
#     helper still compares equal. Because the map is one-sided, a turn-append
#     body calling a write_handoff helper (undefined there, rc 127) or a
#     write_handoff body calling a ta_ helper is drift, and the raw bodies are
#     also asserted to contain no foreign identifiers in code (comments are
#     skipped for that check).
# Negative controls at the end run compare_pair itself on drifted scratch
# copies of the scripts and assert it reports the failure and prints the diff
# (a gate is proven by defeating it).
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
WH="$REPO_ROOT/bin/write_handoff.sh"
TA="$REPO_ROOT/bin/handoff_turn_append.sh"

echo "lock function bodies are identical in both scripts (#189)"

work="$(mktemp -d)"; cleanup_on_exit "$work"

# raw_body <script> <function>: the function's header line reduced to what
# follows `name() {` minus any trailing `#` comment and trailing blanks, then
# the remaining lines unchanged. Empty when the function is missing.
raw_body() {
  sed -n "/^$2() {/,/^}/p" "$1" \
    | sed -e '1s/^[A-Za-z_][A-Za-z0-9_]*() {//' -e '1s/#.*$//' -e '1s/[[:space:]]*$//'
}

# ta_map: map the turn-append helper names to the write_handoff names.
ta_map() {
  sed -e 's/ta_reclaim_stale_lock/reclaim_stale_mkdir_lock/g' \
      -e 's/ta_release_lock/release_mkdir_lock/g' \
      -e 's/ta_claim_lock/claim_mkdir_lock/g'
}

# code_only: raw body with comments dropped, for the foreign-identifier check.
code_only() { sed 's/#.*$//'; }

# compare_pair <wh_script> <ta_script> <wh_fn> <ta_fn> <label>
compare_pair() {
  local a="$work/$5.wh" b="$work/$5.ta" d foreign_wh foreign_ta
  raw_body "$1" "$3" > "$a"
  raw_body "$2" "$4" > "$b"
  foreign_wh="$(code_only < "$a" | grep -E '(^|[^A-Za-z0-9_])ta_[A-Za-z_]+' || true)"
  foreign_ta="$(code_only < "$b" | grep -E '(claim|release|reclaim_stale)_mkdir_lock' || true)"
  ta_map < "$b" > "$b.mapped"
  check "$5: $3 found in $(basename "$1")" yes "$([[ -s "$a" ]] && echo yes || echo no)"
  check "$5: $4 found in $(basename "$2")" yes "$([[ -s "$b" ]] && echo yes || echo no)"
  check "$5: $3 body calls no ta_ helper" "" "$foreign_wh"
  check "$5: $4 body calls no write_handoff lock helper" "" "$foreign_ta"
  if d="$(diff -u "$a" "$b.mapped")"; then
    check "$5: $3 and $4 bodies identical" same same
  else
    printf '%s\n' "$d" | sed 's/^/    /'
    check "$5: $3 and $4 bodies identical" same differ
  fi
}

compare_pair "$WH" "$TA" claim_mkdir_lock ta_claim_lock claim
compare_pair "$WH" "$TA" release_mkdir_lock ta_release_lock release
compare_pair "$WH" "$TA" reclaim_stale_mkdir_lock ta_reclaim_stale_lock reclaim

# Negative controls. Each makes a drifted scratch copy of one script and runs
# compare_pair itself on it in a subshell (its FAIL lines are the expected
# outcome and its counters die with the subshell, so they do not count against
# the suite). The control passes only if compare_pair reported the failure AND
# printed a unified diff containing the changed line.
control() {  # <name> <wh_script> <ta_script> <wh_fn> <ta_fn> <diff-pattern>
  local out
  out="$(compare_pair "$2" "$3" "$4" "$5" "ctl_$1" 2>&1)"
  printf '%s\n' "$out" | sed 's/^/    | /'
  check "negative control $1: compare_pair reports a FAIL" yes \
    "$(printf '%s\n' "$out" | grep -q 'FAIL' && echo yes || echo no)"
  check "negative control $1: compare_pair prints the diff line" yes \
    "$(printf '%s\n' "$out" | grep -Eq "$6" && echo yes || echo no)"
}

drift="$work/drift_ta.sh"
sed '/^ta_release_lock() {/,/^}/ s/pass < 16/pass < 17/' "$TA" > "$drift"
must grep -q 'pass < 17' "$drift"
control code-drift "$WH" "$drift" release_mkdir_lock ta_release_lock '^ +\+.*pass < 17'

sed '/^ta_reclaim_stale_lock() {/,/^}/ s/# Age via GNU/# Age, via GNU/' "$TA" > "$drift"
must grep -q '# Age, via GNU' "$drift"
control comment-drift "$WH" "$drift" reclaim_stale_mkdir_lock ta_reclaim_stale_lock '^ +\+.*# Age, via GNU'

# D1: a turn-append body calling the write_handoff helper (undefined there).
# shellcheck disable=SC2016  # literal $lock_dir is the text being matched
sed '/^ta_reclaim_stale_lock() {/,/^}/ s/ta_claim_lock "\$lock_dir"/claim_mkdir_lock "$lock_dir"/' "$TA" > "$drift"
# shellcheck disable=SC2016  # literal $lock_dir is the text being matched
must grep -q '^  claim_mkdir_lock "\$lock_dir" || return 1' "$drift"
control foreign-call-ta "$WH" "$drift" reclaim_stale_mkdir_lock ta_reclaim_stale_lock 'calls no write_handoff lock helper.*FAIL|FAIL.*calls no write_handoff lock helper'

# D1 reverse: a write_handoff body calling the ta_ helper.
wdrift="$work/drift_wh.sh"
# shellcheck disable=SC2016  # literal $lock_dir is the text being matched
sed '/^reclaim_stale_mkdir_lock() {/,/^}/ s/^  claim_mkdir_lock "\$lock_dir"/  ta_claim_lock "$lock_dir"/' "$WH" > "$wdrift"
# shellcheck disable=SC2016  # literal $lock_dir is the text being matched
must grep -q '^  ta_claim_lock "\$lock_dir" || return 1' "$wdrift"
control foreign-call-wh "$wdrift" "$TA" reclaim_stale_mkdir_lock ta_reclaim_stale_lock 'calls no ta_ helper.*FAIL|FAIL.*calls no ta_ helper'

# D3: code on the header line is compared (the name and trailing comment are not).
sed 's/^ta_claim_lock() {  # .*$/ta_claim_lock() { return 0;  # x/' "$TA" > "$drift"
must grep -q '^ta_claim_lock() { return 0;  # x' "$drift"
control header-code "$WH" "$drift" claim_mkdir_lock ta_claim_lock '^ +\+.*return 0;'

finish
