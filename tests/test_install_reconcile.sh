#!/usr/bin/env bash
# Coverage for install.sh's self-healing hook/statusLine reconcile:
# maybe_install_hook and maybe_install_statusline detect prior installs by a
# marker substring (the script path), which matches ANY release's variant of
# our command. When the matched command differs from the canonical form for
# that event, the installer must rewrite it in place — loudly (old and new
# printed, backup retained), never silently skipping the stale wiring and
# never silently clobbering it.
#
# Observable: command strings in the patched settings.json AND the installer's
# stdout (the loud UPDATE lines are part of the contract — they plus the
# settings.json backup are the user's recovery path).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh — stale-command reconcile (hooks + statusLine)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — install.sh hook patching is a no-op without it"
  finish
  exit
fi

# Canonical command strings, verbatim from install.sh. If a release changes
# them there, update here too — that mismatch failing IS this test working.
# shellcheck disable=SC2016  # $HOME is literal in the stored strings
{
  CANON_SE='bash $HOME/.claude/bin/write_handoff.sh --if-curated >/dev/null 2>&1 || true'
  CANON_SL='bash $HOME/.claude/bin/handoff_statusline.sh 2>/dev/null'
}

SRC_DIR="$(mktemp -d)"
must cp "$REPO_ROOT/install.sh" "$SRC_DIR/"
must cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$SRC_DIR/"

HOME_DIR=""
OUT=""
RC=0
# run_install <settings-json>; fresh HOME_DIR, sets OUT + RC.
run_install() {
  HOME_DIR="$(mktemp -d)"
  printf '%s' "$1" > "$HOME_DIR/settings.json"
  OUT="$(CLAUDE_HOME="$HOME_DIR" bash "$SRC_DIR/install.sh" 2>&1)"
  RC=$?
}
# rerun_install: same HOME_DIR again (idempotence), sets OUT + RC.
rerun_install() {
  OUT="$(CLAUDE_HOME="$HOME_DIR" bash "$SRC_DIR/install.sh" 2>&1)"
  RC=$?
}
out_has()    { printf '%s\n' "$OUT" | grep -qF -- "$1" && echo yes || echo no; }
valid_json() { jq -e . "$HOME_DIR/settings.json" >/dev/null 2>&1 && echo yes || echo no; }
# Count of command strings under one event containing a substring.
count_in()   { jq -r --arg e "$1" '[.hooks[$e] // [] | .. | objects | .command? // empty] | .[]' "$HOME_DIR/settings.json" 2>/dev/null | grep -cF -- "$2"; }
# yes/no: does event $1 hold a command EXACTLY equal to $2?
exact_in()   { jq -e --arg e "$1" --arg c "$2" '(.hooks[$e] // []) | any(.. | .command? // "" | . == $c)' "$HOME_DIR/settings.json" >/dev/null 2>&1 && echo yes || echo no; }
group_count(){ jq -r --arg e "$1" '(.hooks[$e] // []) | length' "$HOME_DIR/settings.json" 2>/dev/null; }
backups()    { local n=0 f; for f in "$HOME_DIR"/settings.json.bak.*; do [[ -e "$f" ]] && n=$((n+1)); done; echo "$n"; }

# --- A. Stale hook command is rewritten in place, loudly ---------------------
# A hypothetical older-release SessionEnd form: same script path (marker
# matches), different arguments. Reconcile must rewrite it to canonical and
# print old + new; the settings backup must survive (it holds the old form).
read -r -d '' STALE_SE <<'JSON' || true
{ "hooks": {
  "SessionEnd": [ { "hooks": [
    { "type": "command", "command": "bash $HOME/.claude/bin/write_handoff.sh --if-stale-by 300 >/dev/null 2>&1 || true" },
    { "type": "command", "command": "echo USER_SE_OWN" }
  ] } ]
} }
JSON
run_install "$STALE_SE"
check "stale SE: exit 0"                       0   "$RC"
check "stale SE: canonical form now present"   yes "$(exact_in SessionEnd "$CANON_SE")"
check "stale SE: exactly one write_handoff"    1   "$(count_in SessionEnd '.claude/bin/write_handoff.sh')"
check "stale SE: stale args gone"              0   "$(count_in SessionEnd '--if-stale-by')"
check "stale SE: user command preserved"       1   "$(count_in SessionEnd 'USER_SE_OWN')"
check "stale SE: rewrite was in place (1 group)" 1 "$(group_count SessionEnd)"
check "stale SE: loud UPDATE line printed"     yes "$(out_has 'UPDATE  hook SessionEnd')"
# shellcheck disable=SC2016  # $HOME is part of the literal stored command being asserted on, not a variable to expand
check "stale SE: old form printed"             yes "$(out_has 'old: bash $HOME/.claude/bin/write_handoff.sh --if-stale-by 300')"
check "stale SE: new form printed"             yes "$(out_has "new: $CANON_SE")"
check "stale SE: settings backup retained"     1   "$(backups)"
check "stale SE: valid JSON"                   yes "$(valid_json)"

# --- B. Idempotence: a second run reports ok and changes nothing -------------
before="$(cat "$HOME_DIR/settings.json")"
rerun_install
check "rerun: exit 0"                          0   "$RC"
check "rerun: no UPDATE lines"                 no  "$(out_has 'UPDATE')"
check "rerun: SessionEnd reported present"     yes "$(out_has 'ok      hook SessionEnd (already present)')"
check "rerun: settings unchanged"              yes "$([[ "$before" == "$(cat "$HOME_DIR/settings.json")" ]] && echo yes || echo no)"
check "rerun: no-change backup dropped"        1   "$(backups)"
rm -rf "$HOME_DIR"

# --- C. Per-event scoping: stale PreCompact, current SessionEnd --------------
# SessionEnd and PreCompact share the write_handoff.sh marker; each event must
# be reconciled only against ITS canonical command. Here SE is already current
# (must be left alone, reported ok) while PC carries an older argument-less
# form (must be rewritten).
read -r -d '' STALE_PC <<'JSON' || true
{ "hooks": {
  "SessionEnd": [ { "hooks": [
    { "type": "command", "command": "bash $HOME/.claude/bin/write_handoff.sh --if-curated >/dev/null 2>&1 || true" }
  ] } ],
  "PreCompact": [ { "hooks": [
    { "type": "command", "command": "bash $HOME/.claude/bin/write_handoff.sh >/dev/null 2>&1 || true" }
  ] } ]
} }
JSON
run_install "$STALE_PC"
check "scoping: SessionEnd reported ok"        yes "$(out_has 'ok      hook SessionEnd (already present)')"
check "scoping: no SessionEnd UPDATE"          no  "$(out_has 'UPDATE  hook SessionEnd')"
check "scoping: PreCompact UPDATE printed"     yes "$(out_has 'UPDATE  hook PreCompact')"
check "scoping: PreCompact now canonical"      yes "$(exact_in PreCompact "$CANON_SE")"
check "scoping: one PC write_handoff"          1   "$(count_in PreCompact '.claude/bin/write_handoff.sh')"
check "scoping: one SE write_handoff"          1   "$(count_in SessionEnd '.claude/bin/write_handoff.sh')"
check "scoping: valid JSON"                    yes "$(valid_json)"
rm -rf "$HOME_DIR"

# --- D. Stale AND canonical both present: dedupe to one canonical ------------
# Rewriting the stale entry alone would leave two identical hooks firing
# twice; the reconcile must collapse them to one and drop the emptied group.
read -r -d '' STALE_PLUS_CURRENT <<'JSON' || true
{ "hooks": {
  "SessionEnd": [
    { "hooks": [ { "type": "command", "command": "bash $HOME/.claude/bin/write_handoff.sh >/dev/null 2>&1 || true" } ] },
    { "hooks": [ { "type": "command", "command": "bash $HOME/.claude/bin/write_handoff.sh --if-curated >/dev/null 2>&1 || true" } ] }
  ]
} }
JSON
run_install "$STALE_PLUS_CURRENT"
check "dedupe: exactly one write_handoff"      1   "$(count_in SessionEnd '.claude/bin/write_handoff.sh')"
check "dedupe: it is the canonical form"       yes "$(exact_in SessionEnd "$CANON_SE")"
check "dedupe: emptied group dropped"          1   "$(group_count SessionEnd)"
check "dedupe: valid JSON"                     yes "$(valid_json)"
rm -rf "$HOME_DIR"

# --- E. statusLine: ours-but-stale is rewritten; sibling keys survive --------
read -r -d '' STALE_SL <<'JSON' || true
{ "statusLine": { "type": "command",
  "command": "bash $HOME/.claude/bin/handoff_statusline.sh --old-flag 2>/dev/null",
  "padding": 0 } }
JSON
run_install "$STALE_SL"
check "statusLine stale: exit 0"               0   "$RC"
check "statusLine stale: command now canonical" yes "$([[ "$(jq -r '.statusLine.command' "$HOME_DIR/settings.json")" == "$CANON_SL" ]] && echo yes || echo no)"
check "statusLine stale: sibling key kept"     0   "$(jq -r '.statusLine.padding' "$HOME_DIR/settings.json")"
check "statusLine stale: UPDATE line printed"  yes "$(out_has 'UPDATE  statusLine')"
# shellcheck disable=SC2016  # $HOME is part of the literal stored command being asserted on, not a variable to expand
check "statusLine stale: old form printed"     yes "$(out_has 'old: bash $HOME/.claude/bin/handoff_statusline.sh --old-flag')"
check "statusLine stale: valid JSON"           yes "$(valid_json)"
rerun_install
check "statusLine rerun: reported ours"        yes "$(out_has 'ok      statusLine (already ours)')"
check "statusLine rerun: no UPDATE"            no  "$(out_has 'UPDATE  statusLine')"
rm -rf "$HOME_DIR"

# --- F. statusLine: NOT ours stays untouched (no reconcile overreach) --------
read -r -d '' FOREIGN_SL <<'JSON' || true
{ "statusLine": { "type": "command", "command": "echo my-own-statusline" } }
JSON
run_install "$FOREIGN_SL"
check "statusLine foreign: untouched"          yes "$([[ "$(jq -r '.statusLine.command' "$HOME_DIR/settings.json")" == "echo my-own-statusline" ]] && echo yes || echo no)"
check "statusLine foreign: skip printed"       yes "$(out_has 'skip    statusLine')"
check "statusLine foreign: no UPDATE"          no  "$(out_has 'UPDATE  statusLine')"
rm -rf "$HOME_DIR"

rm -rf "$SRC_DIR"
finish
