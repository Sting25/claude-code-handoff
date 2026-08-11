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

# --- D. uninstall preserves a user hook that only MENTIONS our script name ---
# Exact-path markers: a user command containing the bare filename but NOT our
# installed $HOME/.claude/bin/ path must survive uninstall. (With the old bare-
# filename marker this user wrapper was wrongly removed.)
read -r -d '' NAMECLASH <<'JSON' || true
{ "hooks": {
  "Stop": [ { "hooks": [
    { "type": "command", "command": "bash $HOME/.claude/bin/handoff_turn_append.sh 2>/dev/null || true" },
    { "type": "command", "command": "echo my own handoff_turn_append.sh wrapper" }
  ] } ]
} }
JSON
run_install "$NAMECLASH" --uninstall
cmds="$(all_cmds)"
check "uninstall: ours removed (exact path)"     yes "$(grep -q '\.claude/bin/handoff_turn_append.sh' <<<"$cmds" && echo no || echo yes)"
check "uninstall: name-clash user cmd preserved" yes "$(grep -q 'my own handoff_turn_append.sh wrapper' <<<"$cmds" && echo yes || echo no)"
check "uninstall: name-clash valid JSON"         yes "$(valid_json)"
rm -rf "$HOME_DIR"

# --- E. a mid-patch jq failure restores settings.json from the backup --------
# Shim jq to fail the UserPromptSubmit hook WRITE (a non -e call) AFTER the
# SessionStart/End/Stop writes have already modified the file. The EXIT trap
# must roll settings.json back to its pre-patch contents, not leave it partial.
src="$(mktemp -d)"; HOME_DIR="$(mktemp -d)"
cp "$REPO_ROOT/install.sh" "$src/"; cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/"
orig='{"permissions":{"allow":["Bash(ls:*)"]},"_sentinel":"KEEPME"}'
printf '%s' "$orig" > "$HOME_DIR/settings.json"
shim="$(mktemp -d)"; REAL_JQ="$(command -v jq)"
cat > "$shim/jq" <<EOF
#!/usr/bin/env bash
# Detection/validation calls carry -e -> pass straight through.
for a in "\$@"; do [[ "\$a" == "-e" ]] && exec "$REAL_JQ" "\$@"; done
# The UserPromptSubmit WRITE carries the event name but no -e -> fail it.
case " \$* " in *" UserPromptSubmit "*) exit 1 ;; esac
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$shim/jq"
( cd "$src" && PATH="$shim:$PATH" CLAUDE_HOME="$HOME_DIR" bash install.sh >/dev/null 2>&1 ); rc=$?
restored="$(cat "$HOME_DIR/settings.json")"
check "mid-patch fail: nonzero exit"      nonzero "$(nonzero "$rc")"
check "mid-patch fail: settings restored" yes     "$([[ "$restored" == "$orig" ]] && echo yes || echo no)"
check "mid-patch fail: valid JSON"        yes     "$(valid_json)"
check "mid-patch fail: backup retained"   yes     "$(ls "$HOME_DIR"/settings.json.bak.* >/dev/null 2>&1 && echo yes || echo no)"
check "mid-patch fail: no stray .tmp"     no      "$(stray_tmp)"
rm -rf "$src" "$shim" "$HOME_DIR"

# --- F. a jq call that exits 0 with EMPTY output must also roll back (M-6) ---
# jq on empty/unreadable input prints nothing and still exits 0 — a real crash
# mode, not just a hypothetical (see ensure_settings_json's own comment on the
# hazard). Unlike case E (nonzero rc), THIS jq claims success. Before
# commit_settings_tmp existed, `mv "$settings.tmp" "$settings"` would install
# the empty file unconditionally, blank settings.json, and — because rc==0 —
# the EXIT trap's rollback would never arm: the script would print "done" over
# a wiped config. Shim jq to go silent (rc 0, no stdout) for the
# UserPromptSubmit hook write, same call site as case E, so the two tests
# isolate exit-code-failure vs silent-empty-success as separate hazards.
src="$(mktemp -d)"; HOME_DIR="$(mktemp -d)"
cp "$REPO_ROOT/install.sh" "$src/"; cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/"
orig='{"permissions":{"allow":["Bash(ls:*)"]},"_sentinel":"KEEPME"}'
printf '%s' "$orig" > "$HOME_DIR/settings.json"
shim="$(mktemp -d)"; REAL_JQ="$(command -v jq)"
cat > "$shim/jq" <<EOF
#!/usr/bin/env bash
# Detection/validation calls carry -e -> pass straight through.
for a in "\$@"; do [[ "\$a" == "-e" ]] && exec "$REAL_JQ" "\$@"; done
# The UserPromptSubmit WRITE carries the event name but no -e -> "succeed"
# with rc 0 and zero bytes of output, exactly what jq on empty input does.
case " \$* " in *" UserPromptSubmit "*) exit 0 ;; esac
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$shim/jq"
( cd "$src" && PATH="$shim:$PATH" CLAUDE_HOME="$HOME_DIR" bash install.sh >/dev/null 2>&1 ); rc=$?
restored="$(cat "$HOME_DIR/settings.json")"
check "silent-empty jq: nonzero exit"      nonzero "$(nonzero "$rc")"
check "silent-empty jq: settings restored" yes     "$([[ "$restored" == "$orig" ]] && echo yes || echo no)"
check "silent-empty jq: not blanked"       yes     "$([[ -n "$restored" ]] && echo yes || echo no)"
check "silent-empty jq: valid JSON"        yes     "$(valid_json)"
check "silent-empty jq: backup retained"   yes     "$(ls "$HOME_DIR"/settings.json.bak.* >/dev/null 2>&1 && echo yes || echo no)"
check "silent-empty jq: no stray .tmp"     no      "$(stray_tmp)"
rm -rf "$src" "$shim" "$HOME_DIR"

finish
