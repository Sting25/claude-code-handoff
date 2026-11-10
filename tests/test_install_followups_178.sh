#!/usr/bin/env bash
# install.sh small follow-ups from the #171 reviews (issue #178):
#   1. docs/reference.md says a user-scope --uninstall keeps handoff_projects
#      and handoff_settings_backups/
#   2. a fresh USER-scope install does not back up the {} it just seeded (a
#      pre-existing file still gets its backup)
#   3. `bash -s -- --help < install.sh` prints nothing on stderr
#   4. several wired projects + missing scripts: the doctor's closing remedy
#      prints one command per wired project
#   5. a project rooted at $HOME is refused with a --project hint
#   7. a project-scope --uninstall removes a settings file the installer
#      created once only the empty skeleton is left; a pre-existing file, and
#      a created file the user added to, are kept
#   8. the install-time model note no longer claims 200k, and names the file
# Every run sandboxes HOME and CLAUDE_HOME, so nothing touches ~/.claude.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh follow-ups (issue #178)"

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

H=""; P=""; RUN_DIR=""
fresh_sandbox() {
  H="$(mktemp -d)"; P="$(mktemp -d)"
  cleanup_on_exit "$H" "$P"
  mkdir -p "$H/.claude"
}
inst() {
  OUT="$(cd "${RUN_DIR:-$P}" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" "$@" 2>&1)"
  RC=$?
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
exists() { [[ -e "$1" ]] && echo yes || echo no; }
backups() { find "$1" -maxdepth 1 -name '*.bak.*' 2>/dev/null | wc -l | tr -d ' '; }

# --- 1. the docs name the kept state ------------------------------------------------
ref="$(cat "$REPO_ROOT/docs/reference.md")"
# shellcheck disable=SC2016  # the backticks are literal markdown, not a command substitution
check "1: reference.md names handoff_projects as kept" yes "$(has "$ref" 'It leaves `~/.claude/handoff_projects`')"
# shellcheck disable=SC2016  # literal markdown backticks
check "1: reference.md names handoff_settings_backups as kept" yes "$(has "$ref" '`~/.claude/handoff_settings_backups/`')"

# --- 2. user scope: no backup of a just-seeded {} -------------------------------------
fresh_sandbox
inst
check "2: fresh user install exit 0" 0 "$RC"
check "2: no backup of the seeded {}" 0 "$(backups "$H/.claude")"
check "2: says no backup needed" yes "$(has "$OUT" "no backup needed")"
check "2: hooks still wired" yes "$(jq -e '.hooks.Stop | length > 0' "$H/.claude/settings.json" >/dev/null 2>&1 && echo yes || echo no)"
# An empty pre-existing file is seeded too: still no backup.
fresh_sandbox
: > "$H/.claude/settings.json"
inst
check "2: empty file seeded, no backup" 0 "$(backups "$H/.claude")"
# A real pre-existing file keeps its backup.
fresh_sandbox
printf '%s' '{"theme":"dark"}' > "$H/.claude/settings.json"
inst
check "2: pre-existing file still backed up" 1 "$(backups "$H/.claude")"

# --- 3. piped --help is silent on stderr ------------------------------------------------
err="$(bash -s -- --help < "$REPO_ROOT/install.sh" 2>&1 >/dev/null)"
check "3: piped --help writes nothing to stderr" "" "$err"
check "3: piped --help still exits 0" 0 "$(bash -s -- --help < "$REPO_ROOT/install.sh" >/dev/null 2>&1; echo $?)"

# --- 4. closing remedy: one command per wired project ------------------------------------
fresh_sandbox
P2="$(mktemp -d)"; NEUTRAL="$(mktemp -d)"
cleanup_on_exit "$P2" "$NEUTRAL"
inst --project "$P"
inst --project "$P2"
rm -rf "$H/.claude/bin"
RUN_DIR="$NEUTRAL" inst --doctor
RUN_DIR=""
check "4: doctor reports the missing scripts" 1 "$RC"
check "4: remedy names the first project" yes "$(has "$OUT" "./install.sh --scope project --project '$(cd "$P" && pwd -P)'")"
check "4: remedy names the second project" yes "$(has "$OUT" "./install.sh --scope project --project '$(cd "$P2" && pwd -P)'")"
check "4: remedy says one per project" yes "$(has "$OUT" "Re-run one command per wired project")"
# One wired project keeps the single-line form.
fresh_sandbox
inst --project "$P"
rm -rf "$H/.claude/bin"
RUN_DIR="$NEUTRAL" inst --doctor
RUN_DIR=""
check "4: single project keeps the one-line remedy" yes "$(has "$OUT" "Re-run ./install.sh --scope project --project '$(cd "$P" && pwd -P)' from")"

# --- 5. a project rooted at $HOME gets a --project hint ----------------------------------
fresh_sandbox
must git -C "$H" init -q
RUN_DIR="$H" inst --scope project
RUN_DIR=""
check "5: refused with exit 2" 2 "$RC"
check "5: still names the user-scope config" yes "$(has "$OUT" "which is the user-scope config; refusing")"
check "5: suggests --project <dir>" yes "$(has "$OUT" "pass --project <dir>")"

# --- 7. project uninstall removes a file the installer created ----------------------------
fresh_sandbox
inst --project "$P"
check "7: install created the project file" yes "$(exists "$P/.claude/settings.json")"
inst --uninstall --project "$P"
check "7: uninstall exit 0" 0 "$RC"
check "7: created file removed" no "$(exists "$P/.claude/settings.json")"
check "7: output says why" yes "$(has "$OUT" "this installer created it")"
# Pre-existing file (even `{}`) is kept, as the bare skeleton.
fresh_sandbox
mkdir -p "$P/.claude"; printf '%s' '{}' > "$P/.claude/settings.json"
inst --project "$P"
inst --uninstall --project "$P"
check "7: pre-existing file kept" yes "$(exists "$P/.claude/settings.json")"
# Created, then the user added a key: kept.
fresh_sandbox
inst --project "$P"
jq '.theme = "dark"' "$P/.claude/settings.json" > "$P/.claude/settings.json.new" && mv "$P/.claude/settings.json.new" "$P/.claude/settings.json"
inst --uninstall --project "$P"
check "7: created file the user added to is kept" dark "$(jq -r '.theme' "$P/.claude/settings.json")"
# The consumed marker means a later empty skeleton is not removed.
printf '%s' '{"hooks":{},"permissions":{"allow":[]}}' > "$P/.claude/settings.json"
inst --uninstall --project "$P"
check "7: marker consumed, later skeleton kept" yes "$(exists "$P/.claude/settings.json")"
# --local follows the same rule.
fresh_sandbox
inst --project "$P" --local
check "7: --local created settings.local.json" yes "$(exists "$P/.claude/settings.local.json")"
inst --uninstall --project "$P" --local
check "7: --local created file removed" no "$(exists "$P/.claude/settings.local.json")"

# --- 8. install-time model note --------------------------------------------------------
fresh_sandbox
inst --project "$P"
check "8: note no longer claims 200k" no "$(has "$OUT" "200k")"
check "8: note names the project file" yes "$(has "$OUT" "NOTE: no model pinned in $(cd "$P" && pwd -P)/.claude/settings.json")"
check "8: note gives the project --model command" yes "$(has "$OUT" "--scope project --project '$(cd "$P" && pwd -P)' --model '<model>'")"
fresh_sandbox
inst
check "8: user scope note names the user file" yes "$(has "$OUT" "NOTE: no model pinned in $H/.claude/settings.json")"

finish
