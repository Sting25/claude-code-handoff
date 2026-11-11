#!/usr/bin/env bash
# A directory at the project settings path is "not a regular file", a fault
# the doctor counts, never "does not exist" (#216). Checked with a --local
# install (the other file carries the hooks, so the doctor switches to it) and
# with a plain install. Sandboxed HOME and CLAUDE_HOME.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh --doctor: non-regular settings path (#216)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed; install.sh refuses to install without it"
  finish
  exit
fi

unset CLAUDE_CONFIG_DIR
SRC="$(mktemp -d)"; H="$(mktemp -d)"
cleanup_on_exit "$SRC" "$H"
must cp "$REPO_ROOT/install.sh" "$SRC/"
must cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$SRC/"
mkdir -p "$H/.claude"
P=""
inst() {
  OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" "$@" 2>&1 </dev/null)"
  RC=$?
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
fresh_project() { P="$(mktemp -d)"; cleanup_on_exit "$P"; P="$(cd "$P" && pwd -P)"; }

# A. --local install, directory at settings.json.
fresh_project
inst --scope project --project "$P" --local
must mkdir "$P/.claude/settings.json"
inst --doctor --scope project --project "$P"
check "A: doctor exits non-zero"            1   "$RC"
check "A: names it a non-regular file"      yes "$(has "$OUT" "settings.json is not a regular file")"
check "A: not called 'does not exist'"      no  "$(has "$OUT" "settings.json does not exist")"
check "A: still switches to the local file" yes "$(has "$OUT" "settings.local.json carries the handoff hooks")"

# B. plain install, directory replaces the wired settings.json.
fresh_project
inst --scope project --project "$P"
must rm "$P/.claude/settings.json"
must mkdir "$P/.claude/settings.json"
inst --doctor --scope project --project "$P"
check "B: doctor exits non-zero"            1   "$RC"
check "B: names it a non-regular file"      yes "$(has "$OUT" "settings.json is not a regular file")"

# C. a genuinely absent file is still just absent (rc 0 with the local install).
fresh_project
inst --scope project --project "$P" --local
inst --doctor --scope project --project "$P"
check "C: absent file still exits 0"        0   "$RC"
check "C: absent file says does not exist"  yes "$(has "$OUT" "settings.json does not exist")"

finish
