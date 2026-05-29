#!/usr/bin/env bash
# Coverage for install.sh's legacy hook-migration functions, previously
# untested:
#   migrate_legacy_ss_hook — removes the pre-0.3.0 inline SessionStart one-liner
#   migrate_legacy_se_hook — removes any SessionEnd write_handoff.sh hook that
#                            predates the --if-curated guard (pre-0.5.0)
# Two failure modes per migrator: (a) coexistence — a legacy command sharing a
# hook group with a user's own command must lose only the legacy entry; (b)
# false-positive — the CURRENT hook form must NOT be mistaken for legacy and
# stripped (which would churn the file and risk duplication).
#
# Observable: the command strings in the patched settings.json after a normal
# (non-uninstall) install, which runs migrate_* then maybe_install_hook.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh — legacy hook migration (coexistence + false-positive)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — install.sh hook patching is a no-op without it"
  finish
  exit
fi

HOME_DIR=""
# run_install <settings-json>; sets RC + HOME_DIR. Always a normal install.
run_install() {
  local init="$1" src
  src="$(mktemp -d)"; HOME_DIR="$(mktemp -d)"
  cp "$REPO_ROOT/install.sh" "$src/"
  cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/"
  printf '%s' "$init" > "$HOME_DIR/settings.json"
  CLAUDE_HOME="$HOME_DIR" bash "$src/install.sh" >/dev/null 2>&1
  RC=$?
  rm -rf "$src"
}
all_cmds()   { jq -r '[.. | objects | .command? // empty] | .[]' "$HOME_DIR/settings.json" 2>/dev/null; }
count_with() { all_cmds | grep -cF -- "$1"; }         # # of command strings containing substr
valid_json() { jq -e . "$HOME_DIR/settings.json" >/dev/null 2>&1 && echo yes || echo no; }
stray_tmp()  { [[ -e "$HOME_DIR/settings.json.tmp" ]] && echo yes || echo no; }
yn()         { [[ "$1" -gt 0 ]] && echo yes || echo no; }

# --- A. Legacy SessionStart inline command co-located with a user command ----
# pre-0.3.0 form carried the marker `if [ -f "$f" ]; then echo`. It shares a
# group with the user's own command. Migration must drop ONLY the legacy entry,
# keep the user's, and the subsequent install must add exactly one current hook.
read -r -d '' SS_LEGACY_COEXIST <<'JSON' || true
{ "hooks": {
  "SessionStart": [ { "hooks": [
    { "type": "command", "command": "f=\"$CLAUDE_PROJECT_DIR/.claude/handoff_current.md\"; if [ -f \"$f\" ]; then echo '## handoff'; cat \"$f\"; fi" },
    { "type": "command", "command": "echo USER_SS_OWN" }
  ] } ]
} }
JSON
run_install "$SS_LEGACY_COEXIST"
check "SS legacy: exit 0"                  0   "$RC"
check "SS legacy: inline one-liner removed" yes "$([[ "$(count_with 'if [ -f "$f" ]; then echo')" -eq 0 ]] && echo yes || echo no)"
check "SS legacy: user command preserved"   yes "$(yn "$(count_with 'USER_SS_OWN')")"
check "SS legacy: current hook added once"   1  "$(count_with '.claude/bin/handoff_session_start.sh')"
check "SS legacy: valid JSON"               yes "$(valid_json)"
check "SS legacy: no stray .tmp"            no  "$(stray_tmp)"
rm -rf "$HOME_DIR"

# --- B. False-positive guard: the CURRENT SessionStart form is not "legacy" --
# A config already holding the script-call hook must survive migration untouched
# and not be duplicated (maybe_install_hook sees it as already present).
read -r -d '' SS_CURRENT <<'JSON' || true
{ "hooks": {
  "SessionStart": [ { "hooks": [
    { "type": "command", "command": "bash $HOME/.claude/bin/handoff_session_start.sh 2>/dev/null || true" }
  ] } ]
} }
JSON
run_install "$SS_CURRENT"
check "SS current: still present exactly once" 1   "$(count_with '.claude/bin/handoff_session_start.sh')"
check "SS current: no legacy marker introduced" 0  "$(count_with 'if [ -f "$f" ]; then echo')"
rm -rf "$HOME_DIR"

# --- C. Legacy SessionEnd command missing --if-curated is migrated -----------
# A pre-0.5.0 SE hook (here the 0.4.1-era --if-stale-by form) calls
# write_handoff.sh without --if-curated. Migration removes it; install then adds
# the current --if-curated command. Net: exactly one SE write_handoff hook, and
# it carries --if-curated. (Without migration, maybe_install_hook would see the
# marker already present and leave the un-guarded legacy in place.)
read -r -d '' SE_LEGACY <<'JSON' || true
{ "hooks": {
  "SessionEnd": [ { "hooks": [
    { "type": "command", "command": "bash $HOME/.claude/bin/write_handoff.sh --if-stale-by 300 >/dev/null 2>&1 || true" }
  ] } ]
} }
JSON
run_install "$SE_LEGACY"
check "SE legacy: exit 0"                    0   "$RC"
check "SE legacy: write_handoff hook once"   1   "$(count_with '.claude/bin/write_handoff.sh')"
check "SE legacy: now carries --if-curated"  yes "$(yn "$(count_with '--if-curated')")"
check "SE legacy: stale-by form removed"     yes "$([[ "$(count_with '--if-stale-by')" -eq 0 ]] && echo yes || echo no)"
check "SE legacy: valid JSON"                yes "$(valid_json)"
rm -rf "$HOME_DIR"

# --- D. False-positive guard: the CURRENT --if-curated SE form is kept --------
read -r -d '' SE_CURRENT <<'JSON' || true
{ "hooks": {
  "SessionEnd": [ { "hooks": [
    { "type": "command", "command": "bash $HOME/.claude/bin/write_handoff.sh --if-curated >/dev/null 2>&1 || true" }
  ] } ]
} }
JSON
run_install "$SE_CURRENT"
check "SE current: write_handoff hook once"  1   "$(count_with '.claude/bin/write_handoff.sh')"
check "SE current: --if-curated retained"    yes "$(yn "$(count_with '--if-curated')")"
rm -rf "$HOME_DIR"

finish
