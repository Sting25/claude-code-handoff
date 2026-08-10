#!/usr/bin/env bash
# Run the handoff test suite: every tests/test_*.sh, tallied. Exits non-zero if
# any test file reports a failure. Dependency-free (bash + git; some tests need
# jq and self-skip without it).
#
#   ./tests/run.sh
#   HANDOFF_TESTS_NO_SKIP=1 ./tests/run.sh    # a skip is a failure (CI)
#
# Why skips are counted and reported: `skip` in lib.sh only PRINTS, and this
# runner used to key purely on exit status — so a host missing jq, perl, or
# openssl could skip ten whole files and still see "ALL TESTS PASSED". The
# worst case is not hypothetical: without perl, test_symlink_safety.sh skips
# every Stop-hook exfiltration test, i.e. the entire secret-leak class, and the
# suite still reports success. Skips are legitimate on a developer's machine;
# what was wrong was that they were invisible. CI sets HANDOFF_TESTS_NO_SKIP=1,
# where every dependency IS present and a skip therefore means the environment
# is not what we think it is.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
skipped_files=0
skipped_names=""
out="$(mktemp)"
trap 'rm -f "$out"' EXIT

for t in "$dir"/test_*.sh; do
  [[ -e "$t" ]] || continue
  echo "== $(basename "$t") =="
  # tee so output still streams live while we inspect it for SKIP lines;
  # PIPESTATUS[0] is the test's own status, not tee's.
  bash "$t" 2>&1 | tee "$out"
  if [[ "${PIPESTATUS[0]}" -ne 0 ]]; then
    failed=$((failed + 1))
  fi
  if LC_ALL=C grep -q '^  SKIP  ' "$out"; then
    skipped_files=$((skipped_files + 1))
    skipped_names="${skipped_names}    $(basename "$t"): $(LC_ALL=C grep -c '^  SKIP  ' "$out") skip(s)
"
  fi
  echo
done

if [[ $skipped_files -gt 0 ]]; then
  echo "$skipped_files test file(s) SKIPPED at least one check:"
  printf '%s' "$skipped_names"
  if [[ "${HANDOFF_TESTS_NO_SKIP:-0}" = "1" ]]; then
    echo "HANDOFF_TESTS_NO_SKIP=1 — a skipped check is a failure here (every"
    echo "dependency is expected to be present). Install the missing tool or"
    echo "fix the guard; do not lower the bar."
    exit 1
  fi
  echo
fi

if [[ $failed -eq 0 ]]; then
  echo "ALL TESTS PASSED"
else
  echo "$failed test file(s) FAILED"
  exit 1
fi
