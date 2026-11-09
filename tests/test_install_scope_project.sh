#!/usr/bin/env bash
# install.sh --scope project (issue #171): wire the hooks into ONE project's
# .claude/settings.json (or settings.local.json with --local) while the
# scripts and skills still go into $CLAUDE_HOME.
#   A. fresh project install: seven hooks + statusLine + perms land in the
#      project file; the user-scope settings.json is byte-for-byte untouched
#   B. idempotent second run: no change, no backup left, no duplicate hooks
#   C. --local targets settings.local.json (and leaves settings.json alone)
#   D. --project implies project scope; no --project means $PWD
#   E. refusals: the source clone (by flag and by $PWD), a missing dir, and
#      contradictory flags; each exits 2 and creates nothing
#   F. --uninstall --scope project removes exactly our entries, keeps the
#      user's own keys, and leaves bin/, skills/, and the secret in place
#   G. --model in project scope pins the project file and its uninstall
#      removes only that pin (the user-scope record is never touched)
#   H. --doctor WARNs on double fire when both the user file and the
#      project file are wired (both scopes), and not when only one is
#   I. a mid-patch abort restores the PROJECT file from its own backup
#   J. a symlinked project settings.json is patched through, link intact
# Every run sandboxes HOME and CLAUDE_HOME, so nothing touches ~/.claude.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh --scope project (issue #171)"

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
# fresh_sandbox: new HOME (with .claude) and a new project dir.
fresh_sandbox() {
  H="$(mktemp -d)"; P="$(mktemp -d)"
  cleanup_on_exit "$H" "$P"
  mkdir -p "$H/.claude"
}
# inst [args...]: run the installer in the sandbox; sets RC and OUT. Runs
# from $RUN_DIR (default $P) so the $PWD default is under test control.
RUN_DIR=""
inst() {
  OUT="$(cd "${RUN_DIR:-$P}" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" "$@" 2>&1)"
  RC=$?
}
pj()  { jq -r "$1" "$P/.claude/settings.json" 2>/dev/null; }
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
backups() { find "$1" -maxdepth 1 -name '*.bak.*' 2>/dev/null | wc -l | tr -d ' '; }

events="SessionStart SessionEnd PreCompact PostCompact WorktreeRemove Stop UserPromptSubmit"

# --- A. fresh project install --------------------------------------------------
fresh_sandbox
user_orig='{"theme":"dark","_sentinel":"USER"}'
printf '%s' "$user_orig" > "$H/.claude/settings.json"
inst --scope project --project "$P"
check "A: exit 0" 0 "$RC"
check "A: project settings.json created" yes "$([[ -f "$P/.claude/settings.json" ]] && echo yes || echo no)"
for ev in $events; do
  check "A: hook $ev in project file" 1 "$(pj ".hooks.$ev | length")"
done
# shellcheck disable=SC2016  # $HOME is literal: the stored hook command keeps it unexpanded
check "A: SessionStart command is ours" yes "$(has "$(pj '.hooks.SessionStart[0].hooks[0].command')" '$HOME/.claude/bin/handoff_session_start.sh')"
check "A: statusLine wired" yes "$(has "$(pj '.statusLine.command')" 'handoff_statusline.sh')"
check "A: seven permissions" 7 "$(pj '.permissions.allow | length')"
check "A: user settings.json untouched" "$user_orig" "$(cat "$H/.claude/settings.json")"
check "A: no backup next to user file" 0 "$(backups "$H/.claude")"
check "A: scripts installed in CLAUDE_HOME" yes "$([[ -e "$H/.claude/bin/write_handoff.sh" ]] && echo yes || echo no)"
check "A: skills installed in CLAUDE_HOME" yes "$([[ -e "$H/.claude/skills/handoff/SKILL.md" ]] && echo yes || echo no)"
check "A: output names the project file" yes "$(has "$OUT" "hooks are wired for $(cd "$P" && pwd -P) only")"
check "A: backup sits next to the project file" 1 "$(backups "$P/.claude")"

# --- B. idempotent second run ----------------------------------------------------
rm -f "$P"/.claude/settings.json.bak.*
before="$(cat "$P/.claude/settings.json")"
inst --scope project --project "$P"
check "B: exit 0" 0 "$RC"
check "B: project file unchanged" same "$([[ "$before" == "$(cat "$P/.claude/settings.json")" ]] && echo same || echo changed)"
check "B: no backup left behind" 0 "$(backups "$P/.claude")"
check "B: no-change message" yes "$(has "$OUT" "no settings.json changes (backup removed)")"
check "B: still one Stop hook" 1 "$(pj '.hooks.Stop | length')"
check "B: still seven permissions" 7 "$(pj '.permissions.allow | length')"
check "B: user settings.json untouched" "$user_orig" "$(cat "$H/.claude/settings.json")"

# --- C. --local ---------------------------------------------------------------
fresh_sandbox
inst --project "$P" --local
check "C: exit 0" 0 "$RC"
check "C: settings.local.json wired" 1 "$(jq -r '.hooks.SessionStart | length' "$P/.claude/settings.local.json" 2>/dev/null)"
check "C: settings.json not created" no "$([[ -e "$P/.claude/settings.json" ]] && echo yes || echo no)"
check "C: user settings.json not created" no "$([[ -e "$H/.claude/settings.json" ]] && echo yes || echo no)"

# --- D. --project implies project scope; default is $PWD ------------------------
fresh_sandbox
inst --project "$P"
check "D: --project alone exits 0" 0 "$RC"
check "D: --project alone wires the project" 1 "$(pj '.hooks.Stop | length')"
check "D: --project alone leaves user scope alone" no "$([[ -e "$H/.claude/settings.json" ]] && echo yes || echo no)"
fresh_sandbox
RUN_DIR="$P" inst --scope project
check "D: --scope project from \$PWD exits 0" 0 "$RC"
check "D: --scope project from \$PWD wires it" 1 "$(pj '.hooks.Stop | length')"
fresh_sandbox
inst
check "D: no flags is still user scope" 1 "$(jq -r '.hooks.Stop | length' "$H/.claude/settings.json" 2>/dev/null)"
check "D: no flags leaves the project alone" no "$([[ -e "$P/.claude" ]] && echo yes || echo no)"

# --- E. refusals ----------------------------------------------------------------
fresh_sandbox
inst --scope project --project "$SRC"
check "E: source clone refused, exit 2" 2 "$RC"
check "E: source clone message" yes "$(has "$OUT" "is this handoff clone (the install source); refusing.")"
check "E: source clone gets no .claude/" no "$([[ -e "$SRC/.claude" ]] && echo yes || echo no)"
check "E: nothing installed into CLAUDE_HOME" no "$([[ -e "$H/.claude/bin" ]] && echo yes || echo no)"
RUN_DIR="$SRC" inst --scope project
check "E: source clone via \$PWD refused, exit 2" 2 "$RC"
check "E: source clone via \$PWD message" yes "$(has "$OUT" "is this handoff clone")"
inst --scope project --project "$P/does-not-exist"
check "E: missing dir refused, exit 2" 2 "$RC"
check "E: missing dir message" yes "$(has "$OUT" "does not exist or is not a directory; refusing.")"
check "E: missing dir not created" no "$([[ -e "$P/does-not-exist" ]] && echo yes || echo no)"
check "E: missing dir installs nothing" no "$([[ -e "$H/.claude/bin" ]] && echo yes || echo no)"
inst --scope user --project "$P"
check "E: --scope user + --project refused" 2 "$RC"
check "E: --scope user + --project message" yes "$(has "$OUT" "--project implies --scope project")"
inst --local
check "E: --local without project scope refused" 2 "$RC"
check "E: --local message" yes "$(has "$OUT" "--local only applies to project scope")"
OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --project "$H" 2>&1)"; RC=$?
check "E: project rooted at HOME refused" 2 "$RC"
check "E: project rooted at HOME message" yes "$(has "$OUT" "which is the user-scope config; refusing.")"
inst --scope global
check "E: bad --scope value refused" 2 "$RC"
inst --project
check "E: --project with no value refused" 2 "$RC"
check "E: refusals left the project alone" no "$([[ -e "$P/.claude" ]] && echo yes || echo no)"

# --- F. --uninstall --scope project ---------------------------------------------
fresh_sandbox
mkdir -p "$P/.claude"
cat > "$P/.claude/settings.json" <<'EOF'
{"env":{"KEEP":"1"},"permissions":{"allow":["Bash(ls:*)"]},
 "hooks":{"Stop":[{"hooks":[{"type":"command","command":"my-own-stop.sh"}]}]}}
EOF
inst --scope project --project "$P"
check "F: install exit 0" 0 "$RC"
check "F: our Stop hook added beside the user's" 2 "$(pj '.hooks.Stop | length')"
# shellcheck disable=SC2016  # $HOME is literal, exactly as install.sh stores the hook command
user_wired='{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash $HOME/.claude/bin/handoff_turn_append.sh 2>/dev/null || true"}]}]}}'
printf '%s' "$user_wired" > "$H/.claude/settings.json"
printf 'k3y\n' > "$H/.claude/handoff_secret"; chmod 600 "$H/.claude/handoff_secret"
rm -f "$P"/.claude/settings.json.bak.*
OUT="$(cd "$P" && env -u HANDOFF_SECRET_FILE HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --uninstall --scope project --project "$P" 2>&1)"; RC=$?
check "F: uninstall exit 0" 0 "$RC"
for ev in SessionStart SessionEnd PreCompact PostCompact WorktreeRemove UserPromptSubmit; do
  check "F: hook $ev removed" null "$(pj ".hooks.$ev // \"null\"")"
done
check "F: user's own Stop hook kept" "my-own-stop.sh" "$(pj '.hooks.Stop[0].hooks[0].command')"
check "F: only the user's Stop group remains" 1 "$(pj '.hooks.Stop | length')"
check "F: statusLine removed" null "$(pj '.statusLine // "null"')"
check "F: only the user's permission remains" 'Bash(ls:*)' "$(pj '.permissions.allow | join(",")')"
check "F: user's env key kept" 1 "$(pj '.env.KEEP')"
check "F: bin scripts kept" yes "$([[ -e "$H/.claude/bin/write_handoff.sh" ]] && echo yes || echo no)"
check "F: skills kept" yes "$([[ -e "$H/.claude/skills/handoff/SKILL.md" ]] && echo yes || echo no)"
check "F: secret kept" yes "$([[ -f "$H/.claude/handoff_secret" ]] && echo yes || echo no)"
check "F: user settings.json untouched" "$user_wired" "$(cat "$H/.claude/settings.json")"
check "F: output says what was kept" yes "$(has "$OUT" "kept (project scope)")"
check "F: backup sits next to the project file" 1 "$(backups "$P/.claude")"
inst --uninstall --scope project --project "$P"
check "F: second uninstall exit 0" 0 "$RC"
check "F: second uninstall is a no-op" yes "$(has "$OUT" "no settings.json changes (backup removed)")"

# --- G. model pin in project scope ------------------------------------------------
fresh_sandbox
inst --project "$P" --model 'opus[1m]'
check "G: model pinned in project file" 'opus[1m]' "$(pj '.model')"
check "G: no user-scope pin record" no "$([[ -e "$H/.claude/handoff-model-pin" ]] && echo yes || echo no)"
check "G: one project pin record" 1 "$(find "$H/.claude" -maxdepth 1 -name 'handoff-model-pin.project.*' | wc -l | tr -d ' ')"
inst --uninstall --project "$P"
check "G: uninstall removes the project pin" null "$(pj '.model // "null"')"
check "G: project pin record consumed" 0 "$(find "$H/.claude" -maxdepth 1 -name 'handoff-model-pin.project.*' | wc -l | tr -d ' ')"

# --- H. doctor double-fire WARN ---------------------------------------------------
fresh_sandbox
inst --project "$P"
inst --doctor --project "$P"
check "H: project-only doctor has no double-fire WARN" no "$(has "$OUT" "fires once per file")"
check "H: project doctor names the project file" yes "$(has "$OUT" "doctor: project scope, checking")"
inst
check "H: user-scope install exit 0" 0 "$RC"
inst --doctor --project "$P"
check "H: project-scope doctor WARNs on double fire" yes "$(has "$OUT" "fires once per file")"
check "H: WARN gives the project uninstall remedy" yes "$(has "$OUT" "--uninstall --scope project --project")"
RUN_DIR="$P" inst --doctor
check "H: user-scope doctor in the project WARNs too" yes "$(has "$OUT" "fires once per file")"
RUN_DIR="$H" inst --doctor
check "H: user-scope doctor elsewhere has no WARN" no "$(has "$OUT" "fires once per file")"
inst --scope project --project "$P"
check "H: install NOTE when the user file is also wired" yes "$(has "$OUT" "every hook fires twice")"

# --- I. mid-patch abort restores the project file ----------------------------------
fresh_sandbox
mkdir -p "$P/.claude"
orig='{"permissions":{"allow":["Bash(ls:*)"]},"_sentinel":"KEEPME"}'
printf '%s' "$orig" > "$P/.claude/settings.json"
shim="$(mktemp -d)"; cleanup_on_exit "$shim"; REAL_JQ="$(command -v jq)"
cat > "$shim/jq" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == "-e" ]] && exec "$REAL_JQ" "\$@"; done
case " \$* " in *" UserPromptSubmit "*) exit 1 ;; esac
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$shim/jq"
OUT="$(cd "$P" && PATH="$shim:$PATH" HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --project "$P" 2>&1)"; RC=$?
check "I: abort exits nonzero" yes "$([[ "$RC" -ne 0 ]] && echo yes || echo no)"
check "I: project file restored" "$orig" "$(cat "$P/.claude/settings.json")"
check "I: restore message names the project file" yes "$(has "$OUT" "restore $(cd "$P" && pwd -P)/.claude/settings.json")"
check "I: no stray .tmp" no "$([[ -e "$P/.claude/settings.json.tmp" ]] && echo yes || echo no)"

# --- J. symlinked project settings.json ---------------------------------------------
fresh_sandbox
mkdir -p "$P/.claude" "$P/dotfiles"
printf '{}' > "$P/dotfiles/settings.json"
ln -s "$P/dotfiles/settings.json" "$P/.claude/settings.json"
inst --project "$P"
check "J: exit 0" 0 "$RC"
check "J: symlink left intact" yes "$([[ -L "$P/.claude/settings.json" ]] && echo yes || echo no)"
check "J: target patched" 1 "$(jq -r '.hooks.Stop | length' "$P/dotfiles/settings.json" 2>/dev/null)"

finish
