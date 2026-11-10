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
#     write_handoff body calling a ta_ helper is drift. The raw bodies are
#     also asserted not to call a function that only the OTHER script defines
#     (`^name() {` there and not here), which covers the three lock names, the
#     ta_ names and any other helper (try_mkdir_lock). What counts as a call:
#     the first word of a simple command, after dropping quoted strings and
#     comments (a `#` starts a comment only at the line start or after
#     whitespace, so ${#var} is kept). Multi-line strings are not tracked.
# Negative controls at the end run compare_pair itself on drifted scratch
# copies of the scripts and assert it reports the failure and prints the diff
# (a gate is proven by defeating it). Each drift is injected generically (a
# line added inside the extracted function range), never by matching current
# body text, so a legitimate edit made to both scripts cannot break the setup.
# The controls' nested output is printed with its failure marker renamed
# "fail(control)" so a log grep for the real marker stays clean on a green run.
# shellcheck disable=SC2016  # literal $ in the injected test lines is intended
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

# code_only: drop quoted strings and comments (see the header comment).
code_only() {
  awk '{
    line = $0; out = ""; q = ""; n = length(line)
    for (i = 1; i <= n; i++) {
      c = substr(line, i, 1)
      if (q == "") {
        if (c == "\\") { out = out c substr(line, i + 1, 1); i++; continue }
        if (c == "\"" || c == "\047") { q = c; continue }
        if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t]/)) break
        out = out c
      } else {
        if (c == "\\" && q == "\"") { i++; continue }
        if (c == q) q = ""
      }
    }
    print out
  }'
}

# cmd_words: the first word of each simple command in code-only text.
cmd_words() {
  tr '&|;(){}`!' '\n' | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^(then|do|else|elif|if|while|until)$/) continue
      if ($i ~ /^[A-Za-z_][A-Za-z0-9_]*$/) print $i
      break
    }
  }'
}

# defined_fns <script>: sorted names of the `name() {` functions it defines.
defined_fns() {
  grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\) \{' "$1" | sed 's/() {//' | sort -u
}

# foreign_calls <body_file> <this_script> <other_script>: commands the body
# runs that only the other script defines.
foreign_calls() {
  comm -12 <(code_only < "$1" | cmd_words | sort -u) \
           <(comm -23 <(defined_fns "$3") <(defined_fns "$2"))
}

# compare_pair <wh_script> <ta_script> <wh_fn> <ta_fn> <label>
compare_pair() {
  local a="$work/$5.wh" b="$work/$5.ta" d foreign_wh foreign_ta
  raw_body "$1" "$3" > "$a"
  raw_body "$2" "$4" > "$b"
  foreign_wh="$(foreign_calls "$a" "$1" "$2" | tr '\n' ' ')"
  foreign_ta="$(foreign_calls "$b" "$2" "$1" | tr '\n' ' ')"
  ta_map < "$b" > "$b.mapped"
  check "$5: $3 found in $(basename "$1")" yes "$([[ -s "$a" ]] && echo yes || echo no)"
  check "$5: $4 found in $(basename "$2")" yes "$([[ -s "$b" ]] && echo yes || echo no)"
  check "$5: $3 body calls nothing only $(basename "$2") defines" "" "$foreign_wh"
  check "$5: $4 body calls nothing only $(basename "$1") defines" "" "$foreign_ta"
  if d="$(diff -u -L wh -L ta "$a" "$b.mapped")"; then
    check "$5: $3 and $4 bodies identical" same same
  else
    printf '%s\n' "$d" | sed 's/^/    /'
    check "$5: $3 and $4 bodies identical" same differ
  fi
}

compare_pair "$WH" "$TA" claim_mkdir_lock ta_claim_lock claim
compare_pair "$WH" "$TA" release_mkdir_lock ta_release_lock release
compare_pair "$WH" "$TA" reclaim_stale_mkdir_lock ta_reclaim_stale_lock reclaim

# inject <script> <function> <second|last> <text>: the script with one line
# added inside the function's range (after its header line, or before its
# closing brace). Independent of the function's current contents.
inject() {
  awk -v fn="$2" -v pos="$3" -v txt="$4" '
    $0 ~ "^" fn "\\(\\) \\{" { inr = 1; print; if (pos == "second") print txt; next }
    inr && /^}/ { if (pos == "last") print txt; inr = 0 }
    { print }' "$1"
}

# Negative controls. Each makes a drifted scratch copy and runs compare_pair
# itself on it in a subshell (its failure lines are the expected outcome and
# its counters die with the subshell, so they do not count against the suite).
# control <name> <expect red|green> <wh> <ta> <wh_fn> <ta_fn> <line-pattern>:
# red needs a failure reported AND a printed line matching the pattern; green
# needs no failure reported.
control() {
  local out
  out="$(compare_pair "$3" "$4" "$5" "$6" "ctl_$1" 2>&1 | sed 's/FAIL  /fail(control)  /')"
  printf '%s\n' "$out" | sed 's/^/    | /'
  if [[ "$2" == red ]]; then
    check "negative control $1: compare_pair reports a failure" yes \
      "$(printf '%s\n' "$out" | grep -q 'fail(control)' && echo yes || echo no)"
    check "negative control $1: compare_pair prints the offending line" yes \
      "$(printf '%s\n' "$out" | grep -Eq "$7" && echo yes || echo no)"
  else
    check "negative control $1: compare_pair stays green" yes \
      "$(printf '%s\n' "$out" | grep -q 'fail(control)' && echo no || echo yes)"
  fi
}

drift="$work/drift_ta.sh"; wdrift="$work/drift_wh.sh"
rel=(release_mkdir_lock ta_release_lock)
rec=(reclaim_stale_mkdir_lock ta_reclaim_stale_lock)

inject "$TA" ta_release_lock second '  : drift' > "$drift"
must grep -q '^  : drift$' "$drift"
control code-drift red "$WH" "$drift" "${rel[@]}" '^ +\+  : drift'

inject "$TA" ta_release_lock second '  # drift' > "$drift"
must grep -q '^  # drift$' "$drift"
control comment-drift red "$WH" "$drift" "${rel[@]}" '^ +\+  # drift'

# Header-line code: rewrite the header by regex, whatever its current comment.
sed -E 's/^(ta_claim_lock\(\) \{).*/\1 return 0;  # x/' "$TA" > "$drift"
must grep -q '^ta_claim_lock() { return 0;  # x$' "$drift"
control header-code red "$WH" "$drift" claim_mkdir_lock ta_claim_lock '^ +\+ return 0;'

# A foreign helper called from the turn-append body (undefined there).
inject "$TA" ta_reclaim_stale_lock last '  claim_mkdir_lock "$lock_dir"' > "$drift"
control foreign-call-ta red "$WH" "$drift" "${rec[@]}" 'fail\(control\).*calls nothing only write_handoff.sh defines'

# A ta_ helper called from the write_handoff body.
inject "$WH" reclaim_stale_mkdir_lock last '  ta_claim_lock "$lock_dir"' > "$wdrift"
control foreign-call-wh red "$wdrift" "$TA" "${rec[@]}" 'fail\(control\).*calls nothing only handoff_turn_append.sh defines'

# A helper that is neither a lock name nor ta_ (try_mkdir_lock).
inject "$TA" ta_reclaim_stale_lock last '  try_mkdir_lock "$lock_dir"' > "$drift"
control foreign-other red "$WH" "$drift" "${rec[@]}" 'fail\(control\).*calls nothing only write_handoff.sh defines'

# A call hidden behind ${#var} must not be masked as a comment.
inject "$TA" ta_reclaim_stale_lock last '  [[ ${#lock_dir} -gt 0 ]] && claim_mkdir_lock "$lock_dir"' > "$drift"
control masked-call red "$WH" "$drift" "${rec[@]}" 'fail\(control\).*calls nothing only write_handoff.sh defines'

# A lock name inside a string, identical in both bodies, stays green.
inject "$TA" ta_release_lock second '  echo "release_mkdir_lock: gave up" >&2' > "$drift"
inject "$WH" release_mkdir_lock second '  echo "release_mkdir_lock: gave up" >&2' > "$wdrift"
control string-mention green "$wdrift" "$drift" "${rel[@]}"

finish
