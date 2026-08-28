#!/usr/bin/env bash
# install.sh --keep-secret only changes what --uninstall does
# (remove_secret_if_ours() is the only reader of $keep_secret, and it only
# runs in uninstall mode). The flag stays accepted in every mode so a caller
# that always passes it doesn't have to branch, but issue #82 asked for a
# one-line warning instead of silently accepting a no-op flag in the modes
# where it does nothing, plus --help documenting which mode it applies to.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh --keep-secret scope (warn outside --uninstall)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed: install.sh settings patching is a no-op without it"
  finish
  exit
fi

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
WARNING_TEXT="has no effect"

# mk_sandbox: fresh install.sh + bin/skills copy under a throwaway CLAUDE_HOME.
# Echoes "<src_dir> <home_dir>".
mk_sandbox() {
  local src home
  src="$(mktemp -d)"; home="$(mktemp -d)"
  cp "$REPO_ROOT/install.sh" "$src/"
  cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/"
  printf '%s %s\n' "$src" "$home"
}

# --- A. plain install --keep-secret -> warns, and still installs -------------
read -r src home <<<"$(mk_sandbox)"
out="$(CLAUDE_HOME="$home" bash "$src/install.sh" --copy --keep-secret 2>&1)"; rc=$?
check "install: exit 0"                0   "$rc"
check "install: warns no effect"       yes "$(has "$out" "$WARNING_TEXT")"
check "install: names install mode"    yes "$(has "$out" "install mode")"
check "install: still installed"       yes "$(has "$out" "done. start a new Claude Code session")"
rm -rf "$src" "$home"

# --- B. --doctor --keep-secret -> warns, doctor still runs -------------------
read -r src home <<<"$(mk_sandbox)"
CLAUDE_HOME="$home" bash "$src/install.sh" --copy >/dev/null 2>&1   # something to diagnose
out="$(CLAUDE_HOME="$home" bash "$src/install.sh" --doctor --keep-secret 2>&1)"; rc=$?
check "doctor: exit 0"                 0   "$rc"
check "doctor: warns no effect"        yes "$(has "$out" "$WARNING_TEXT")"
check "doctor: names doctor mode"      yes "$(has "$out" "doctor mode")"
rm -rf "$src" "$home"

# --- C. --uninstall --keep-secret -> no warning (this is the mode it works ---
# --- in) --------------------------------------------------------------------
read -r src home <<<"$(mk_sandbox)"
CLAUDE_HOME="$home" bash "$src/install.sh" --copy >/dev/null 2>&1
out="$(env -u HANDOFF_SECRET_FILE CLAUDE_HOME="$home" bash "$src/install.sh" --uninstall --keep-secret 2>&1)"; rc=$?
check "uninstall: exit 0"              0   "$rc"
check "uninstall: no scope warning"    no  "$(has "$out" "$WARNING_TEXT")"
rm -rf "$src" "$home"

# --- D. plain install, no --keep-secret -> no warning (negative control) ----
read -r src home <<<"$(mk_sandbox)"
out="$(CLAUDE_HOME="$home" bash "$src/install.sh" --copy 2>&1)"; rc=$?
check "no flag: exit 0"                0   "$rc"
check "no flag: no scope warning"      no  "$(has "$out" "$WARNING_TEXT")"
rm -rf "$src" "$home"

# --- E. --help documents which modes the flag applies to --------------------
help_out="$(bash "$REPO_ROOT/install.sh" --help)"
check "help: mentions --uninstall applies" yes "$(has "$help_out" "only changes what --uninstall does")"

finish
