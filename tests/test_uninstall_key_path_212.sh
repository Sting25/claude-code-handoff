#!/usr/bin/env bash
# #212: a project-scope --uninstall that has consumed the created-file marker
# and has nothing else keyed to the project also removes the key directory's
# own-vs-foreign `path` record. Backups (*.bak.*) are kept on purpose and do
# not refer to the record; the record stays while a marker or the other
# settings file's wiring still needs it, and for a directory keyed to
# another project.
# Every run sandboxes HOME and CLAUDE_HOME, so nothing touches ~/.claude.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "project --uninstall releases the key path record (#212)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed; install.sh refuses to install without it"
  finish
  exit
fi

unset HANDOFF_SECRET_FILE CLAUDE_CONFIG_DIR CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_DESKTOP_APP_VERSION

SRC="$(mktemp -d)"
cleanup_on_exit "$SRC"
must cp "$REPO_ROOT/install.sh" "$SRC/"
must cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$SRC/"

H=""; P=""
fresh_sandbox() {
  H="$(mktemp -d)"; P="$(mktemp -d)"
  cleanup_on_exit "$H" "$P"
  P="$(cd "$P" && pwd -P)"
  mkdir -p "$H/.claude"
}
inst() {
  OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" "$@" 2>&1 </dev/null)"
  RC=$?
}
B() { echo "$H/.claude/handoff_settings_backups"; }
# files other than the settings backups, which uninstall keeps by design
nfiles() { find "$(B)" -type f ! -name '*.bak.*' 2>/dev/null | wc -l | tr -d ' '; }
keydir() { find "$(B)" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1; }

# A. plain install + uninstall: nothing left under the backups dir
fresh_sandbox
inst --scope project --project "$P"
check "A: install wrote the path record" 2 "$(nfiles)"   # path + .created
inst --uninstall --scope project --project "$P"
check "A: exit 0" 0 "$RC"
check "A: no file left under handoff_settings_backups" 0 "$(nfiles)"
check "A: the settings backup is kept" 1 "$(find "$(B)" -type f -name '*.bak.*' | wc -l | tr -d ' ')"

# B. a gone project
fresh_sandbox
inst --scope project --project "$P"
rm -rf "$P"
OUT="$(cd "$H" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --uninstall --scope project --project "$P" 2>&1 </dev/null)"; RC=$?
: --scope project --project "$P"
check "B: gone project: exit 0" 0 "$RC"
check "B: gone project: no file left" 0 "$(nfiles)"

# C. both settings files installed: path stays until the last one goes
fresh_sandbox
inst --scope project --project "$P"
inst --scope project --project "$P" --local
inst --uninstall --scope project --project "$P"
check "C: after the first uninstall the path record stays" yes "$([[ -f "$(keydir)/path" ]] && echo yes || echo no)"
inst --uninstall --scope project --project "$P" --local
check "C: after the last uninstall nothing is left" 0 "$(nfiles)"

# D. a user file in the key directory is never touched
fresh_sandbox
inst --scope project --project "$P"
printf 'x\n' > "$(keydir)/notes.txt"
inst --uninstall --scope project --project "$P"
check "D: user file kept" yes "$([[ -f "$(keydir)/notes.txt" ]] && echo yes || echo no)"
check "D: path record removed" no "$([[ -f "$(keydir)/path" ]] && echo yes || echo no)"

# E. a key directory keyed to another project is left alone
fresh_sandbox
inst --scope project --project "$P"
printf '/some/other/project\n' > "$(keydir)/path"
inst --uninstall --scope project --project "$P"
check "E: foreign path record untouched" "/some/other/project" "$(cat "$(keydir)/path" 2>/dev/null)"

# F. an incomplete uninstall (invalid JSON) keeps everything
fresh_sandbox
inst --scope project --project "$P"
printf '{"hooks":{' > "$P/.claude/settings.json"
inst --uninstall --scope project --project "$P"
check "F: exit 1" 1 "$RC"
check "F: path record and marker kept" 2 "$(nfiles)"

finish
