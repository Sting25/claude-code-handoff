#!/usr/bin/env bash
# Self-test for the test harness itself (tests/lib.sh): the `must` setup guard
# and mk_repo's loud-failure behavior. Without these, a broken fixture is silent
# and can make a later assertion pass VACUOUSLY (audit finding tests#1). These
# assertions inherently require the fix — `must` does not exist without it, and
# unpatched mk_repo returns 0 even when its fixture could not be built.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "lib.sh — must() setup guard + mk_repo loud failure (tests#1)"

# must <success>: returns 0, records nothing.
must true; rc=$?
check "must <ok> -> rc 0" 0 "$rc"

# must <failure>: prints a FAIL diagnostic and returns the failing rc. Run inside
# a command substitution / suppressed subshell so the demo failure does not
# pollute THIS file's tally or terminal output.
out="$(must false 2>&1)"
check "must <fail> -> prints FAIL diagnostic" yes \
  "$(case "$out" in *'setup command failed'*) echo yes ;; *) echo no ;; esac)"
( must false >/dev/null 2>&1 ); rc=$?
check "must <fail> -> returns failing rc" 1 "$rc"

# mk_repo success path still produces a usable repo and returns 0.
repo="$(mk_repo)"; rc=$?
check "mk_repo -> rc 0"          0   "$rc"
check "mk_repo -> repo has .git" yes "$([[ -d "$repo/.git" ]] && echo yes || echo no)"
[[ -n "$repo" ]] && rm -rf "$repo"

# mk_repo fails LOUDLY (non-zero, nothing echoed) when its fixture can't be built
# — simulated with a TMPDIR pointing at a non-creatable path so `mktemp -d` fails.
# Unpatched mk_repo swallowed this and returned 0 with an empty path.
out="$( TMPDIR=/no/such/dir/handoff_$$ mk_repo 2>/dev/null )"; rc=$?
check "mk_repo broken fixture -> non-zero rc"    yes "$([[ $rc -ne 0 ]] && echo yes || echo no)"
check "mk_repo broken fixture -> no path echoed" ""  "$out"

finish
