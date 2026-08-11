#!/usr/bin/env bash
# install.sh plugin/script coexistence detection (v0.14.0+ ships a plugin
# form of this tool; plugin hooks and these script-install hooks COEXIST —
# Claude Code fires both, no dedup):
#   A. --doctor: plugin cache present + script hooks wired -> double-fire WARN
#   B. --doctor: plugin cache present, no script hooks -> informational note
#   C. --doctor: no plugin cache -> no plugin mention at all (negative control)
#   D. plain install: plugin cache present -> a heads-up note before "done."
#
# Plugin installs live under $HOME/.claude/plugins/cache/<marketplace>/
# claude-code-handoff/<version>/ — ALWAYS under real $HOME, never under a
# CLAUDE_HOME override (install.sh's find_plugin_cache_dir uses $HOME
# directly). So unlike most install.sh tests, which only sandbox CLAUDE_HOME,
# this file sandboxes HOME too and lets CLAUDE_HOME default from it
# ($HOME/.claude) — never touching the real $HOME.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh plugin/script coexistence detection"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — install.sh settings patching is a no-op without it"
  finish
  exit
fi

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# mk_sandbox: fresh install.sh + bin/skills copy under a throwaway $HOME.
# Echoes "<src_dir> <home_dir>".
mk_sandbox() {
  local src home
  src="$(mktemp -d)"; home="$(mktemp -d)"
  cp "$REPO_ROOT/install.sh" "$src/"
  cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/"
  printf '%s %s\n' "$src" "$home"
}

mk_plugin_cache() {  # <home_dir>
  must mkdir -p "$1/.claude/plugins/cache/somemkt/claude-code-handoff/0.14.0"
}

# --- A. plugin present + script hooks wired -> double-fire WARN -------------
read -r src home <<<"$(mk_sandbox)"
HOME="$home" bash "$src/install.sh" >/dev/null 2>&1   # wires script hooks first
mk_plugin_cache "$home"
dout="$(HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "both installed: doctor exit 0"             0   "$drc"
check "both installed: double-fire warning"       yes "$(has "$dout" "fires TWICE")"
check "both installed: names plugin uninstall"    yes "$(has "$dout" "/plugin uninstall")"
check "both installed: names --uninstall"         yes "$(has "$dout" "install.sh --uninstall")"
rm -rf "$src" "$home"

# "no script hooks" for the plugin-note check below still means the script's
# OWN hook scripts/settings entries are installed (so doctor's unrelated
# hook-resolution check reports healthy) but with settings.json's
# SessionStart hook stripped back out — that's what "script hooks NOT wired"
# means for the coexistence check (see find_plugin_cache_dir's caller in
# install.sh, which keys off the SessionStart marker).
strip_session_start_hook() {  # <home_dir>
  local s="$1/.claude/settings.json"
  jq 'del(.hooks.SessionStart)' "$s" > "$s.tmp" && mv "$s.tmp" "$s"
}

# --- B. plugin present, no script hooks -> informational note only ---------
read -r src home <<<"$(mk_sandbox)"
HOME="$home" bash "$src/install.sh" >/dev/null 2>&1
strip_session_start_hook "$home"
mk_plugin_cache "$home"
dout="$(HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "plugin only: doctor exit 0"                0   "$drc"
check "plugin only: informational note"           yes "$(has "$dout" "plugin install detected")"
check "plugin only: does not manage plugin note"  yes "$(has "$dout" "does not manage plugin installs")"
check "plugin only: no double-fire warning"       no  "$(has "$dout" "fires TWICE")"
rm -rf "$src" "$home"

# --- C. no plugin cache -> no plugin mention at all (negative control) -----
read -r src home <<<"$(mk_sandbox)"
HOME="$home" bash "$src/install.sh" >/dev/null 2>&1
dout="$(HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "no plugin: doctor exit 0"                  0   "$drc"
check "no plugin: no plugin mention"              no  "$(has "$dout" "plugin install")"
rm -rf "$src" "$home"

# --- D. plain install prints a heads-up when a plugin cache is present -----
read -r src home <<<"$(mk_sandbox)"
mk_plugin_cache "$home"
iout="$(HOME="$home" bash "$src/install.sh" 2>&1)"; irc=$?
check "install: exit 0"                           0   "$irc"
check "install: plugin coexistence note"          yes "$(has "$iout" "plugin install of this tool was detected")"
check "install: double-fire mention"              yes "$(has "$iout" "double-fire")"
check "install: still completes"                  yes "$(has "$iout" "done. start a new Claude Code session")"
rm -rf "$src" "$home"

# --- E. plain install, no plugin cache -> no note (negative control) -------
read -r src home <<<"$(mk_sandbox)"
iout="$(HOME="$home" bash "$src/install.sh" 2>&1)"; irc=$?
check "install no plugin: exit 0"                 0   "$irc"
check "install no plugin: no plugin note"         no  "$(has "$iout" "plugin install")"
rm -rf "$src" "$home"

finish
