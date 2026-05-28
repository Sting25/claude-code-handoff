#!/usr/bin/env bash
# Run the handoff test suite: every tests/test_*.sh, tallied. Exits non-zero if
# any test file reports a failure. Dependency-free (bash + git; some tests need
# jq and self-skip without it).
#
#   ./tests/run.sh
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0

for t in "$dir"/test_*.sh; do
  [[ -e "$t" ]] || continue
  echo "== $(basename "$t") =="
  if ! bash "$t"; then
    failed=$((failed + 1))
  fi
  echo
done

if [[ $failed -eq 0 ]]; then
  echo "ALL TESTS PASSED"
else
  echo "$failed test file(s) FAILED"
  exit 1
fi
