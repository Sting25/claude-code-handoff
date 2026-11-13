#!/usr/bin/env bash
# install.sh must survive being run as `sh install.sh`. On macOS `sh` is
# bash 3.2 in POSIX mode, where process substitution `<(...)` is a syntax
# error: a `same_content <(printf ...)` in project_key_check made every
# `sh install.sh` die at parse time with rc 2 (review of #226). Checked
# two ways:
#   A. `bash --posix -n install.sh` parses (on any bash; bash 5.1 and later
#      accept `<(...)` in POSIX mode, so this one is red only on older bash);
#   B. where `sh` is bash (macOS), `sh install.sh --help`, a project-scope
#      install and its --uninstall all exit 0.
# Where `sh` is not bash (dash on Linux), B does not apply: install.sh is a
# bash script and dash cannot run it at all, on main or here.
# Every run sandboxes HOME and CLAUDE_HOME.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh under sh / bash --posix"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed; install.sh refuses to install without it"
  finish
  exit
fi

unset CLAUDE_CONFIG_DIR
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
SRC="$(mktemp -d)"; cleanup_on_exit "$SRC"
must cp "$REPO_ROOT/install.sh" "$SRC/"
must cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$SRC/"

OUT="$(bash --posix -n "$SRC/install.sh" 2>&1)"; RC=$?
check "A: bash --posix -n parses install.sh" 0 "$RC"
check "A: no syntax error" "" "$OUT"

if [[ -n "$(sh -c 'printf %s "${BASH_VERSION:-}"' 2>/dev/null)" ]]; then
  H="$(mktemp -d)"; P="$(mktemp -d)"; cleanup_on_exit "$H" "$P"
  P="$(cd "$P" && pwd -P)"; mkdir -p "$H/.claude"
  run_sh() {
    OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" sh "$SRC/install.sh" "$@" 2>&1 </dev/null)"
    RC=$?
  }
  run_sh --help
  check "B: sh install.sh --help exits 0" 0 "$RC"
  check "B: no syntax error (--help)" no "$(has "$OUT" "syntax error")"
  run_sh --scope project --project "$P"
  check "B: sh project install exits 0" 0 "$RC"
  run_sh --uninstall --scope project --project "$P"
  check "B: sh project uninstall exits 0" 0 "$RC"
  check "B: no syntax error (uninstall)" no "$(has "$OUT" "syntax error")"
  check "B: the registry line was cleared" no "$(has "$(cat "$H/.claude/handoff_projects" 2>/dev/null)" "$P")"
else
  echo "  note  sh is not bash here; part B (sh install.sh) applies only where it is"
fi

finish
