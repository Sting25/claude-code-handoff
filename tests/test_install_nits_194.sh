#!/usr/bin/env bash
# Installer nits from the review of PR 192 (#194):
#   A. a project --uninstall removes the empty .claude/ the install created,
#      and only that one (a pre-existing dir, or one with other files, stays)
#   B. a piped no-arg install says why it cannot run (exit 2, nothing written)
#   C. the "no backup needed" line says what an abort does for the seed state
#      (absent: removed; empty: emptied again)
#   D. a gone-project uninstall reached through a symlink (a dangling link to
#      the project, or a link above it) clears the registry line and markers
# Every run sandboxes HOME and CLAUDE_HOME, so nothing touches ~/.claude.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh nits (#194)"

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
  P="$(cd "$P" && pwd -P)"
  mkdir -p "$H/.claude"
}
inst() {
  OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" "$@" 2>&1 </dev/null)"
  RC=$?
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
exists() { [[ -e "$1" ]] && echo yes || echo no; }
nmarkers() { find "$H/.claude/handoff_settings_backups" -type f \( -name '*.created' -o -name '*.mkdir' \) 2>/dev/null | wc -l | tr -d ' '; }

# --- A. the empty .claude/ ---------------------------------------------------------------
fresh_sandbox
rmdir "$P" 2>/dev/null; mkdir -p "$P"            # P exists, has no .claude
inst --scope project --project "$P"
check "A1: install created .claude" yes "$(exists "$P/.claude")"
inst --uninstall --scope project --project "$P"
check "A1: uninstall exit 0" 0 "$RC"
check "A1: settings file gone" no "$(exists "$P/.claude/settings.json")"
check "A1: empty .claude removed" no "$(exists "$P/.claude")"
check "A1: output says so" yes "$(has "$OUT" "this installer created it; it is empty")"
check "A1: no marker left behind" 0 "$(nmarkers)"

fresh_sandbox
inst --scope project --project "$P" --local
inst --uninstall --scope project --project "$P" --local
check "A2 (--local): empty .claude removed" no "$(exists "$P/.claude")"

fresh_sandbox
mkdir -p "$P/.claude"                              # pre-existing, empty
inst --scope project --project "$P"
inst --uninstall --scope project --project "$P"
check "A3: pre-existing .claude kept" yes "$(exists "$P/.claude")"
check "A3: settings file still removed" no "$(exists "$P/.claude/settings.json")"

fresh_sandbox
inst --scope project --project "$P"
printf 'mine\n' > "$P/.claude/notes.txt"
inst --uninstall --scope project --project "$P"
check "A4: .claude with a user file kept" yes "$(exists "$P/.claude/notes.txt")"
check "A4: no rmdir message" no "$(has "$OUT" "it is empty")"

# --- B. piped no-arg install -----------------------------------------------------------------
fresh_sandbox
OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash -s < "$SRC/install.sh" 2>&1)"
RC=$?
check "B: piped no-arg install exits 2" 2 "$RC"
check "B: says there is no clone" yes "$(has "$OUT" "ERROR: install.sh was read from a pipe, so there is no clone to install from.")"
check "B: no 'installing ... from  into'" no "$(has "$OUT" "installing handoff skill from")"
check "B: no cp error" no "$(has "$OUT" "cp:")"
check "B: nothing written to claude home" 0 "$(find "$H/.claude" -type f | wc -l | tr -d ' ')"

# --- C. seed-state wording -----------------------------------------------------------------------
fresh_sandbox
inst
check "C: absent seed: 'just created'" yes "$(has "$OUT" "was just created; an abort undoes that")"
fresh_sandbox
: > "$H/.claude/settings.json"
inst
check "C: empty seed: no 'just created'" no "$(has "$OUT" "was just created")"
check "C: empty seed: says an abort empties it" yes "$(has "$OUT" "was empty; an abort empties it again")"

# --- D. gone project reached through a symlink ----------------------------------------------------
# D1: a dangling link to the removed project.
fresh_sandbox
LNK_DIR="$(mktemp -d)"; cleanup_on_exit "$LNK_DIR"
ln -s "$P" "$LNK_DIR/p"
inst --scope project --project "$LNK_DIR/p"
check "D1: install registered the project" yes "$(has "$(cat "$H/.claude/handoff_projects" 2>/dev/null)" "$P")"
rm -rf "$P"
OUT="$(cd "$LNK_DIR" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --uninstall --scope project --project "$LNK_DIR/p" 2>&1 </dev/null)"
RC=$?
check "D1: gone uninstall exit 0" 0 "$RC"
check "D1: registry line cleared" "" "$(cat "$H/.claude/handoff_projects" 2>/dev/null)"
check "D1: no marker left behind" 0 "$(nmarkers)"

# D2: a link above the removed project.
fresh_sandbox
LNK_DIR="$(mktemp -d)"; cleanup_on_exit "$LNK_DIR"
mkdir -p "$P/work/proj"
ln -s "$P/work" "$LNK_DIR/w"
inst --scope project --project "$LNK_DIR/w/proj"
check "D2: install registered the project" yes "$(has "$(cat "$H/.claude/handoff_projects" 2>/dev/null)" "$P/work/proj")"
rm -rf "$P/work/proj"
OUT="$(cd "$LNK_DIR" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --uninstall --scope project --project "$LNK_DIR/w/proj" 2>&1 </dev/null)"
RC=$?
check "D2: gone uninstall exit 0" 0 "$RC"
check "D2: registry line cleared" "" "$(cat "$H/.claude/handoff_projects" 2>/dev/null)"
check "D2: no marker left behind" 0 "$(nmarkers)"

finish
