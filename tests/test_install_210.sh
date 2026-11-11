#!/usr/bin/env bash
# Installer defects from #210:
#   A. a project path with a control character is refused (exit 2) before
#      anything is copied. Every `$(...)` that resolves the path strips a
#      trailing newline, so `my proj<LF>` used to resolve to a SIBLING `my
#      proj`: the sibling was wired and registered, or, with no sibling, the
#      install copied every script and then died on a raw mkdir error. The
#      refusal covers each way the path arrives: --project, --project=, the
#      current directory, the git toplevel, a symlink to such a directory,
#      and a project-scope --uninstall of a gone path (which used to clear
#      the SIBLING's registry line). A non-ASCII name still installs.
#   B. a dangling <project>/.claude link is refused before anything is
#      copied into CLAUDE_HOME (already true on main when #210 was fixed;
#      pinned here because the issue reported a copy-then-die)
#   C. `bash -s -- --uninstall < install.sh` (no clone) closes with a line
#      that names no empty repo path
# Every run sandboxes HOME and CLAUDE_HOME, so nothing touches ~/.claude.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh control-character paths, dangling .claude, piped uninstall (#210)"

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

NL=$'\n'
H=""; P=""
fresh_sandbox() {
  H="$(mktemp -d)"; P="$(mktemp -d)"
  cleanup_on_exit "$H" "$P"
  P="$(cd "$P" && pwd -P)"
  must mkdir -p "$H/.claude"
}
# inst <cwd> <args...>
inst() {
  local cwd="$1"; shift
  OUT="$(cd "$cwd" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" "$@" 2>&1 </dev/null)"
  RC=$?
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
exists() { [[ -e "$1" ]] && echo yes || echo no; }
ncopied() { find "$H/.claude" -mindepth 1 | wc -l | tr -d ' '; }
CTRL_ERR="contains a control character (newline, tab, ...); refusing."

# --- A. control characters in the project path -------------------------------------------------
# A1: --project 'my proj<LF>' next to an existing sibling 'my proj'.
fresh_sandbox
must mkdir "$P/my proj$NL" "$P/my proj"
inst "$P" --project "$P/my proj$NL"
check "A1: refused (exit 2)" 2 "$RC"
check "A1: ERROR names the control character" yes "$(has "$OUT" "ERROR: project directory $(printf '%q' "$P/my proj$NL") $CTRL_ERR")"
check "A1: the sibling is not wired" no "$(exists "$P/my proj/.claude")"
check "A1: the real directory is not wired" no "$(exists "$P/my proj$NL/.claude")"
check "A1: nothing copied into the jailed home" 0 "$(ncopied)"

# A2: --project=<path> form, no sibling (used to copy every script, then die on a raw mkdir).
fresh_sandbox
must mkdir "$P/my proj$NL"
inst "$P" "--project=$P/my proj$NL"
check "A2: --project= refused (exit 2)" 2 "$RC"
check "A2: ERROR line" yes "$(has "$OUT" "$CTRL_ERR")"
check "A2: no raw mkdir error" no "$(has "$OUT" "mkdir:")"
check "A2: nothing copied into the jailed home" 0 "$(ncopied)"

# A3: a tab in the middle of the name.
fresh_sandbox
TABP="$P/my"$'\t'"proj"; must mkdir -p "$TABP"
inst "$P" --project "$TABP"
check "A3: tab refused (exit 2)" 2 "$RC"
check "A3: nothing copied" 0 "$(ncopied)"
check "A3: not wired" no "$(exists "$TABP/.claude")"

# A4: no --project, the current directory (not a git repo) ends in a newline.
fresh_sandbox
must mkdir "$P/my proj$NL" "$P/my proj"
inst "$P/my proj$NL" --scope project
check "A4: cwd with a newline refused (exit 2)" 2 "$RC"
check "A4: ERROR line" yes "$(has "$OUT" "$CTRL_ERR")"
check "A4: the sibling is not wired" no "$(exists "$P/my proj/.claude")"
check "A4: nothing copied" 0 "$(ncopied)"

# A5: no --project, run from a subdirectory of a git repo whose toplevel ends in a newline.
if command -v git >/dev/null 2>&1; then
  fresh_sandbox
  must mkdir -p "$P/my proj$NL/sub" "$P/my proj"
  must git -C "$P/my proj$NL" init -q
  inst "$P/my proj$NL/sub" --scope project
  check "A5: git toplevel with a newline refused (exit 2)" 2 "$RC"
  check "A5: ERROR line" yes "$(has "$OUT" "$CTRL_ERR")"
  check "A5: the sibling is not wired" no "$(exists "$P/my proj/.claude")"
  check "A5: nothing copied" 0 "$(ncopied)"
else
  skip "A5: git not installed"
fi

# A6: a clean --project that is a symlink to a directory whose name ends in a newline.
fresh_sandbox
must mkdir "$P/my proj$NL" "$P/my proj"
must ln -s "$P/my proj$NL" "$P/link"
inst "$P" --project "$P/link"
check "A6: symlink to a newline path refused (exit 2)" 2 "$RC"
check "A6: ERROR names the resolved path" yes "$(has "$OUT" "ERROR: project directory (resolved) $(printf '%q' "$P/my proj$NL") $CTRL_ERR")"
check "A6: the sibling is not wired" no "$(exists "$P/my proj/.claude")"
check "A6: nothing copied" 0 "$(ncopied)"

# A7: a project-scope --uninstall of a gone 'my proj<LF>' must not clear the
# registry line of the installed sibling 'my proj'.
fresh_sandbox
must mkdir "$P/my proj"
inst "$P" --project "$P/my proj"
check "A7: the sibling installs (exit 0)" 0 "$RC"
REG_BEFORE="$(cat "$H/.claude/handoff_projects" 2>/dev/null)"
check "A7: the sibling is registered" yes "$(has "$REG_BEFORE" "$P/my proj")"
inst "$P" --uninstall --project "$P/my proj$NL"
check "A7: gone newline path refused (exit 2)" 2 "$RC"
check "A7: ERROR line" yes "$(has "$OUT" "$CTRL_ERR")"
check "A7: the sibling's registry line is kept" "$REG_BEFORE" "$(cat "$H/.claude/handoff_projects" 2>/dev/null)"
check "A7: the sibling's wiring is kept" yes "$(exists "$P/my proj/.claude/settings.json")"

# A8: a non-ASCII name is not a control character and still installs.
fresh_sandbox
must mkdir "$P/café proj"
inst "$P" --project "$P/café proj"
check "A8: non-ASCII name installs (exit 0)" 0 "$RC"
check "A8: wired" yes "$(exists "$P/café proj/.claude/settings.json")"

# --- B. dangling <project>/.claude: refused before anything is copied ---------------------------
fresh_sandbox
NOWHERE="$(mktemp -d)"; cleanup_on_exit "$NOWHERE"; must rmdir "$NOWHERE"
must ln -s "$NOWHERE" "$P/.claude"
inst "$P" --project "$P"
check "B: dangling .claude refused (exit 2)" 2 "$RC"
check "B: ERROR names the link" yes "$(has "$OUT" "ERROR: $P/.claude is a dangling symlink (-> $NOWHERE)")"
check "B: nothing copied into the jailed home" 0 "$(ncopied)"
check "B: link target not created" no "$(exists "$NOWHERE")"

# --- C. piped --uninstall names no empty repo path ------------------------------------------------
fresh_sandbox
OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash -s -- --uninstall < "$SRC/install.sh" 2>&1)"
RC=$?
check "C1: piped user-scope uninstall exits 0" 0 "$RC"
check "C1: no empty repo path" no "$(has "$OUT" "the repo at  is")"
check "C1: says no clone was used" yes "$(has "$OUT" "done. no clone was used (install.sh was read from a pipe).")"
fresh_sandbox
OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash -s -- --uninstall --project "$P" < "$SRC/install.sh" 2>&1)"
RC=$?
check "C2: piped project-scope uninstall exits 0" 0 "$RC"
check "C2: no empty repo path" no "$(has "$OUT" "the repo at  is")"
check "C2: says no clone was used" yes "$(has "$OUT" "done. no clone was used (install.sh was read from a pipe).")"
# A clone run still names its repo.
inst "$P" --uninstall
check "C3: clone uninstall still names the repo" yes "$(has "$OUT" "done. the repo at $SRC is untouched.")"

finish
