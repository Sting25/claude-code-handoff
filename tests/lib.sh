# Shared helpers for the handoff test suite. Source this from a test_*.sh file.
# Dependency-free: bash + git + (for some tests) jq, all already required by the
# shipped scripts.
#
# Why no `set -e`: many tests run a hook EXPECTING it to fail and assert on the
# captured exit code (`cmd; rc=$?`); `set -e` would abort the test the moment
# such a command returned non-zero. (`-u` and `pipefail` are kept — they catch
# unset vars and broken pipes without that conflict.) The trade-off is that a
# broken *setup* command (a failed mk_repo / mkdir / cat-redirect) is otherwise
# silent, which can make a later assertion pass VACUOUSLY — e.g. "secret not in
# file" is trivially true if the file was never written. Guard fixture setup with
# `must` (below) so such failures surface loudly instead.
# shellcheck shell=bash
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # not used here; consumed by the sourcing test files ("$REPO_ROOT/bin/...")
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# --- exit-time cleanup -------------------------------------------------------
# One suite-owned EXIT trap per test process. Register throwaway paths with
# `cleanup_on_exit <path>...`; they are rm -rf'd when the test exits by ANY
# route (success, failed assertion, `set -u` abort, early `exit`). EXIT traps
# do not fire in subshells or command substitutions, so `$(mk_repo)` and
# `( cd ... )` blocks cannot trigger an early cleanup. Test files must call
# cleanup_on_exit instead of writing their own `trap ... EXIT` — a later raw
# trap silently REPLACES this one and re-opens the secret-jail leak below.
_lib_cleanup_paths=()
cleanup_on_exit() { _lib_cleanup_paths+=("$@"); }
_lib_run_cleanup() {
  local p
  # ${arr[@]+...} guard: bash 3.2 under `set -u` errors on expanding an
  # empty array with a bare "${arr[@]}".
  for p in ${_lib_cleanup_paths[@]+"${_lib_cleanup_paths[@]}"}; do
    rm -rf "$p"
  done
}
# shellcheck disable=SC2120  # false positive: $1 is filled by `set --` below, not by callers
_lib_arm_exit_trap() {
  # Chain, don't clobber: if an EXIT trap already exists when lib.sh is
  # sourced, keep it — run its body first (it may reference paths we are
  # about to delete), then our cleanup. `trap -p EXIT` prints a re-evalable
  # `trap -- '<body>' EXIT`; parsing uses this function's own positional
  # params so the sourcing test file's "$@" is untouched.
  local prev
  prev="$(trap -p EXIT)"
  if [[ -n "$prev" ]]; then
    eval "set -- ${prev#trap -- }"   # $1 = previous trap body, $2 = EXIT
    trap -- "$1; _lib_run_cleanup" EXIT
  else
    trap -- '_lib_run_cleanup' EXIT
  fi
}
# shellcheck disable=SC2119  # companion to the SC2120 disable above
_lib_arm_exit_trap

# Keep signing side effects inside the test sandbox (issue #49):
# write_handoff.sh generates the per-machine HMAC secret on first signed write
# (handoff_ensure_secret), defaulting to $HOME/.claude/handoff_secret — so any
# test that invokes it without jailing this variable would materialize key
# material in the developer's REAL home. The jail is created only to fill an
# unset/empty value: test files that jail a per-fixture path via
# `env HANDOFF_SECRET_FILE=...` keep their own, and a path deliberately
# exported by the caller wins too (and is never cleaned up here). When lib.sh
# DID create the dir it registers it for exit-time removal — previously every
# test file sourcing this file stranded one mktemp dir per invocation
# (40 per full run). test_uninstall_secret.sh must strip this with `env -u`
# for its default-path cases — install.sh --uninstall skips the secret
# whenever the override is set.
if [[ -z "${HANDOFF_SECRET_FILE:-}" ]]; then
  _lib_secret_jail="$(mktemp -d)" \
    || { echo "lib.sh: mktemp -d failed for the secret jail" >&2; exit 1; }
  HANDOFF_SECRET_FILE="$_lib_secret_jail/handoff_secret"
  cleanup_on_exit "$_lib_secret_jail"
fi
export HANDOFF_SECRET_FILE

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

# Portable "octal mode of a path" (GNU stat -c first, BSD stat -f fallback).
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# must <cmd...> — run a SETUP command that is expected to succeed. On failure,
# record a failure + print a loud diagnostic, so a broken fixture can't make a
# later assertion pass vacuously. Use for fixture setup (mkdir, cp, cat-redirect,
# etc.); do NOT use it for the command under test when asserting on its exit code
# (capture that with `cmd; rc=$?` as usual). Redirections bind to the whole call,
# so `must cat > "$f" <<EOF ... EOF` works.
must() {
  if "$@"; then
    return 0
  else
    # First statement in the else branch: $? is still the failed command's rc.
    # (Reading $? AFTER `fi` would yield 0 — a not-taken if returns success.)
    local rc=$?
    printf '  FAIL  setup command failed (rc=%d): %s\n' "$rc" "$*"
    _fail=$((_fail + 1))
    return "$rc"
  fi
}

# Print the tally and return non-zero if anything failed (drives run.sh).
finish() {
  printf '  --- %d passed, %d failed ---\n' "$_pass" "$_fail"
  [[ $_fail -eq 0 ]]
}

# Make a throwaway git repo with one commit. Echoes its path on success; on any
# setup failure (e.g. mktemp can't create under a bad TMPDIR, git unavailable) it
# warns on stderr and returns non-zero rather than echoing an empty/half-built
# path that a caller would then build vacuous assertions on.
mk_repo() {
  local d
  d="$(mktemp -d)" || { echo "mk_repo: mktemp -d failed" >&2; return 1; }
  # Canonicalize (pwd -P): macOS mktemp returns /var/..., a symlink to
  # /private/var/..., while git rev-parse --show-toplevel reports the physical
  # path; exact-path assertions need the two to match. No-op on GNU/ubuntu.
  d="$(cd "$d" && pwd -P)" || { echo "mk_repo: cannot canonicalize $d" >&2; return 1; }
  if ! { git -C "$d" init -q \
      && git -C "$d" config user.email t@t \
      && git -C "$d" config user.name t \
      && echo seed > "$d/seed.txt" \
      && git -C "$d" add seed.txt \
      && git -C "$d" commit -qm "seed commit"; }; then
    echo "mk_repo: failed to build repo in $d" >&2
    return 1
  fi
  printf '%s\n' "$d"
}
