#!/usr/bin/env bash
# Tests install.sh settings.json robustness:
#   A. empty settings.json is normalized to {} (was: jq emptied it, false rc=0)
#   B. malformed settings.json is refused, not aborted-into / clobbered, no .tmp
#   C. uninstall removes only OUR command, preserving a user command co-located
#      in the same hook group (was: whole group/event deleted)
# Plus: absent file works, valid file is patched + preserves user keys, and the
# install is idempotent. Every run must leave no stray settings.json.tmp.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh settings.json robustness"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — install.sh settings patching is a no-op without it"
  finish
  exit
fi

HOME_DIR=""
# run_install <init|__ABSENT__> [install args...] ; sets RC, HOME_DIR.
run_install() {
  local init="$1"; shift
  local src; src="$(mktemp -d)"; HOME_DIR="$(mktemp -d)"
  cp "$REPO_ROOT/install.sh" "$src/"
  cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/"
  [[ "$init" != "__ABSENT__" ]] && printf '%s' "$init" > "$HOME_DIR/settings.json"
  CLAUDE_HOME="$HOME_DIR" bash "$src/install.sh" "$@" >/dev/null 2>&1
  RC=$?
  rm -rf "$src"
}
has_ss()     { jq -e '.hooks.SessionStart' "$HOME_DIR/settings.json" >/dev/null 2>&1 && echo present || echo absent; }
valid_json() { jq -e . "$HOME_DIR/settings.json" >/dev/null 2>&1 && echo yes || echo no; }
stray_tmp()  { [[ -e "$HOME_DIR/settings.json.tmp" ]] && echo yes || echo no; }
all_cmds()   { jq -r '[.. | objects | .command? // empty] | .[]' "$HOME_DIR/settings.json" 2>/dev/null; }
nonzero()    { [[ "$1" -ne 0 ]] && echo nonzero || echo zero; }

# --- A. empty settings.json ---
run_install ""
check "empty: exit 0"            0        "$RC"
check "empty: hook installed"    present  "$(has_ss)"
check "empty: valid JSON"        yes      "$(valid_json)"
check "empty: no stray .tmp"     no       "$(stray_tmp)"
rm -rf "$HOME_DIR"

# --- B. malformed settings.json ---
run_install '{ "permissions": '
check "malformed: nonzero exit"  nonzero  "$(nonzero "$RC")"
check "malformed: not patched"   absent   "$(has_ss)"
check "malformed: file untouched" '{ "permissions": ' "$(cat "$HOME_DIR/settings.json")"
check "malformed: no stray .tmp" no       "$(stray_tmp)"
rm -rf "$HOME_DIR"

# --- control: absent settings.json ---
run_install __ABSENT__
check "absent: exit 0"           0        "$RC"
check "absent: hook installed"   present  "$(has_ss)"
check "absent: no stray .tmp"    no       "$(stray_tmp)"
rm -rf "$HOME_DIR"

# --- valid settings: patch, preserve user keys, idempotent ---
run_install '{"permissions":{"allow":["Bash(ls:*)"]}}'
check "valid: exit 0"            0        "$RC"
check "valid: hook installed"    present  "$(has_ss)"
check "valid: user perm kept"    yes      "$(jq -e '.permissions.allow | index("Bash(ls:*)")' "$HOME_DIR/settings.json" >/dev/null 2>&1 && echo yes || echo no)"
before="$(cat "$HOME_DIR/settings.json")"
src2="$(mktemp -d)"; cp "$REPO_ROOT/install.sh" "$src2/"; cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src2/"
CLAUDE_HOME="$HOME_DIR" bash "$src2/install.sh" >/dev/null 2>&1
after="$(cat "$HOME_DIR/settings.json")"
check "valid: idempotent re-run" same     "$([[ "$before" == "$after" ]] && echo same || echo changed)"
rm -rf "$HOME_DIR" "$src2"

# --- C. uninstall preserves a co-located user command ---
read -r -d '' COLOCATED <<'JSON' || true
{ "hooks": {
  "SessionStart": [ { "hooks": [
    { "type": "command", "command": "bash $HOME/.claude/bin/handoff_session_start.sh 2>/dev/null || true" },
    { "type": "command", "command": "echo USER_OWN_HOOK" }
  ] } ],
  "Stop": [ { "hooks": [ { "type": "command", "command": "echo USER_STANDALONE" } ] } ]
} }
JSON
run_install "$COLOCATED" --uninstall
cmds="$(all_cmds)"
check "uninstall: co-located user cmd kept" yes "$(grep -q 'USER_OWN_HOOK'    <<<"$cmds" && echo yes || echo no)"
check "uninstall: standalone user cmd kept" yes "$(grep -q 'USER_STANDALONE'  <<<"$cmds" && echo yes || echo no)"
check "uninstall: our cmd removed"          yes "$(grep -q 'handoff_session_start' <<<"$cmds" && echo no || echo yes)"
check "uninstall: valid JSON"               yes "$(valid_json)"
check "uninstall: no stray .tmp"            no  "$(stray_tmp)"
rm -rf "$HOME_DIR"

finish
