#!/usr/bin/env bash
# install.sh --doctor names the settings file(s) that carry the hooks in every
# layout (#190), not only when it finds a conflict:
#   A. clean project install (settings.json): the doctor lists that file
#   B. clean --local install: the doctor lists settings.local.json, and a
#      doctor run WITHOUT --local says the file it checked carries no hooks
#      and the other one does
#   C. clean user-scope install: the doctor lists the user settings.json
#   D. nothing wired: no listing at all
# Every run sandboxes HOME and CLAUDE_HOME, so nothing touches ~/.claude.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh --doctor names the wired settings file (#190)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed; install.sh refuses to install without it"
  finish
  exit
fi

unset CLAUDE_CONFIG_DIR

SRC="$(mktemp -d)"
cleanup_on_exit "$SRC"
must cp "$REPO_ROOT/install.sh" "$SRC/"
must cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$SRC/"

H=""; P=""
fresh_sandbox() {
  H="$(mktemp -d)"; P="$(mktemp -d)"
  cleanup_on_exit "$H" "$P"
  P="$(cd "$P" && pwd -P)"   # the installer prints physical paths
  mkdir -p "$H/.claude"
}
inst() {
  OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" "$@" 2>&1 </dev/null)"
  RC=$?
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
LIST="hooks are wired in these settings files"

# A. clean project install.
fresh_sandbox
inst --scope project --project "$P"
inst --doctor --scope project --project "$P"
check "A: doctor exit 0"                       0   "$RC"
check "A: lists the wired file"                yes "$(has "$OUT" "$LIST")"
check "A: names project settings.json"         yes "$(has "$OUT" "$P/.claude/settings.json (project)")"
check "A: does not name settings.local.json"   no  "$(has "$OUT" "settings.local.json")"
check "A: still says all hooks resolve"        yes "$(has "$OUT" "doctor: all hooks resolve.")"
check "A: no conflict WARN"                    no  "$(has "$OUT" "WARN    this installer")"

# B. clean --local install.
fresh_sandbox
inst --scope project --project "$P" --local
inst --doctor --scope project --project "$P" --local
check "B: doctor --local exit 0"               0   "$RC"
check "B: lists settings.local.json"           yes "$(has "$OUT" "$P/.claude/settings.local.json (project, local)")"
check "B: does not name settings.json"         no  "$(has "$OUT" "$P/.claude/settings.json")"
inst --doctor --scope project --project "$P"
check "B: doctor without --local exit 0"       0   "$RC"
check "B: still lists settings.local.json"     yes "$(has "$OUT" "$P/.claude/settings.local.json (project, local)")"
check "B: says the checked file has no hooks"  yes "$(has "$OUT" "$P/.claude/settings.json carries no handoff hooks; $P/.claude/settings.local.json does")"
check "B: says to add --local"                 yes "$(has "$OUT" "(add --local to check that file)")"

# B2. the reverse: settings.json install checked with --local.
fresh_sandbox
inst --scope project --project "$P"
inst --doctor --scope project --project "$P" --local
check "B2: says to drop --local"               yes "$(has "$OUT" "(drop --local to check that file)")"

# C. clean user-scope install.
fresh_sandbox
inst
inst --doctor
check "C: user doctor exit 0"                  0   "$RC"
check "C: lists the user settings.json"        yes "$(has "$OUT" "$H/.claude/settings.json (user scope)")"
check "C: no conflict WARN"                    no  "$(has "$OUT" "WARN    this installer")"

# D. nothing wired: no listing.
fresh_sandbox
inst --doctor --scope project --project "$P"
check "D: no listing when nothing is wired"    no  "$(has "$OUT" "$LIST")"

finish
