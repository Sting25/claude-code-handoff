#!/usr/bin/env bash
# The doctor prints the "cannot be read" WARN once per unreadable settings file
# per run, not once per read of it (#214): the project pre-check and the
# wired-files listing both read the same file. Skipped as root (mode 000 stays
# readable there). Sandboxed HOME and CLAUDE_HOME.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh --doctor: one WARN per unreadable file (#214)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed; install.sh refuses to install without it"
  finish
  exit
fi
if [[ "$(id -u)" == 0 ]]; then
  skip "running as root: mode 000 is still readable"
  finish
  exit
fi

unset CLAUDE_CONFIG_DIR
SRC="$(mktemp -d)"; H="$(mktemp -d)"; P="$(mktemp -d)"
cleanup_on_exit "$SRC" "$H" "$P"
P="$(cd "$P" && pwd -P)"
must cp "$REPO_ROOT/install.sh" "$SRC/"
must cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$SRC/"
mkdir -p "$H/.claude"
inst() {
  OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" "$@" 2>&1 </dev/null)"
  RC=$?
}
count() { printf '%s\n' "$1" | grep -cF -- "$2" || true; }

inst --scope project --project "$P" --local
echo '{}' > "$P/.claude/settings.json"
chmod 000 "$P/.claude/settings.json"
inst --doctor --scope project --project "$P"
chmod 600 "$P/.claude/settings.json"

check "doctor exits non-zero"                 1 "$RC"
check "the file is named as unreadable"       1 "$(count "$OUT" "settings.json cannot be read (check its permissions);")"
check "the other file still carries the hooks" 1 "$(count "$OUT" "settings.local.json carries the handoff hooks")"
check "closing line names permission denied"  1 "$(count "$OUT" "doctor: permission denied while reading settings")"

finish
