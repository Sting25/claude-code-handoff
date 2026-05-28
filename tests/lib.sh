# Shared helpers for the handoff test suite. Source this from a test_*.sh file.
# Dependency-free: bash + git + (for some tests) jq, all already required by the
# shipped scripts. No -e: tests assert on exit codes and must not abort early.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

_pass=0
_fail=0

# check <description> <expected> <actual>
check() {
  if [[ "$2" == "$3" ]]; then
    printf '  PASS  %s [%s]\n' "$1" "$2"
    _pass=$((_pass + 1))
  else
    printf '  FAIL  %s — expected [%s] got [%s]\n' "$1" "$2" "$3"
    _fail=$((_fail + 1))
  fi
}

skip() { printf '  SKIP  %s\n' "$1"; }

# Print the tally and return non-zero if anything failed (drives run.sh).
finish() {
  printf '  --- %d passed, %d failed ---\n' "$_pass" "$_fail"
  [[ $_fail -eq 0 ]]
}

# Make a throwaway git repo with one commit. Echoes its path.
mk_repo() {
  local d
  d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t
  git -C "$d" config user.name t
  echo seed > "$d/seed.txt"
  git -C "$d" add seed.txt
  git -C "$d" commit -qm "seed commit"
  printf '%s\n' "$d"
}
