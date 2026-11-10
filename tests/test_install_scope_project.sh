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
#   H. --doctor WARNs on user-scope wiring next to a project layout (both
#      scopes, and from a subdirectory via the git toplevel), lists exactly
#      the wired files, gives --uninstall --keep-secret; and not when only
#      the project is wired. Claude Code runs identical handlers once, so
#      this is about scope, not double firing.
#   I. a mid-patch abort restores the PROJECT file from its backup under
#      CLAUDE_HOME, and undoes a seed when there was no file before
#   J. a symlinked project settings.json is patched through, link intact
#   K. the project registry: append (no duplicates), remove on project
#      uninstall, user-scope uninstall warns about wired projects, the
#      user-scope doctor lists stale entries
#   L. both project files wired: the NOTE/WARN names the extra one
#   M. review round: a user-scope uninstall keeps the shared secret while a
#      project is wired (--remove-secret deletes it); the doctor remedy on a
#      fresh machine with a wired project file names the project command;
#      a project uninstall of a vanished dir clears its registry line; no
#      --project inside a repo uses the git toplevel; printed commands
#      quote paths (a path with a space pastes and runs)
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
# Where project-scope backups go: $CLAUDE_HOME/handoff_settings_backups/<cksum of project path>.
bdir() { printf '%s/.claude/handoff_settings_backups/%s' "$H" "$(printf '%s' "$(cd "$P" && pwd -P)" | cksum | awk '{print $1}')"; }

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
check "A: no backup inside the project" 0 "$(backups "$P/.claude")"
check "A: no backup of a just-seeded file" 0 "$(backups "$(bdir)")"
check "A: seed reported as needing no backup" yes "$(has "$OUT" "no backup needed")"

# --- B. idempotent second run ----------------------------------------------------
rm -f "$P"/.claude/settings.json.bak.*
before="$(cat "$P/.claude/settings.json")"
inst --scope project --project "$P"
check "B: exit 0" 0 "$RC"
check "B: project file unchanged" same "$([[ "$before" == "$(cat "$P/.claude/settings.json")" ]] && echo same || echo changed)"
check "B: no backup left behind" 0 "$(backups "$P/.claude")"
check "B: no backup left in CLAUDE_HOME" 0 "$(backups "$(bdir)")"
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
check "E: source clone message" yes "$(has "$OUT" "or inside it (the install source); refusing.")"
check "E: source clone gets no .claude/" no "$([[ -e "$SRC/.claude" ]] && echo yes || echo no)"
check "E: nothing installed into CLAUDE_HOME" no "$([[ -e "$H/.claude/bin" ]] && echo yes || echo no)"
RUN_DIR="$SRC" inst --scope project
check "E: source clone via \$PWD refused, exit 2" 2 "$RC"
check "E: source clone via \$PWD message" yes "$(has "$OUT" "or inside it (the install source)")"
inst --scope project --project "$SRC/bin"
check "E: dir inside the source clone refused" 2 "$RC"
check "E: dir inside the source clone message" yes "$(has "$OUT" "or inside it (the install source); refusing.")"
check "E: dir inside the clone gets no .claude/" no "$([[ -e "$SRC/bin/.claude" ]] && echo yes || echo no)"
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
check "E: bad --scope value message" yes "$(has "$OUT" "--scope must be 'user' or 'project' (got 'global').")"
inst --project
check "E: --project with no value refused" 2 "$RC"
check "E: --project with no value message" yes "$(has "$OUT" "--project requires a directory")"
check "E: refusals left the project alone" no "$([[ -e "$P/.claude" ]] && echo yes || echo no)"
fresh_sandbox
sib="${SRC}-sibling"; mkdir -p "$sib"; cleanup_on_exit "$sib"
inst --scope project --project "$sib"
check "E: sibling sharing the clone's name prefix is allowed" 0 "$RC"

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
rm -f "$(bdir)"/settings.json.bak.*
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
check "F: no backup inside the project" 0 "$(backups "$P/.claude")"
check "F: backup kept under CLAUDE_HOME" 1 "$(backups "$(bdir)")"
check "F: backup path printed" yes "$(has "$OUT" "-> $(bdir)/settings.json.bak.")"
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
# The file was created by this install, so after the strip only the empty
# skeleton is left and the uninstall removes it (issue #178).
check "G: uninstall removes the project pin (and the file it created)" no "$([[ -e "$P/.claude/settings.json" ]] && echo yes || echo no)"
check "G: project pin record consumed" 0 "$(find "$H/.claude" -maxdepth 1 -name 'handoff-model-pin.project.*' | wc -l | tr -d ' ')"

# G2: the same pin on a file that existed before the install: the pin and our
# hooks are stripped, the file survives with the user's key.
fresh_sandbox
mkdir -p "$P/.claude"; printf '%s' '{"theme":"dark"}' > "$P/.claude/settings.json"
inst --project "$P" --model 'opus[1m]'
check "G2: model pinned in the existing file" 'opus[1m]' "$(pj '.model')"
inst --uninstall --project "$P"
check "G2: pre-existing file survives" yes "$([[ -e "$P/.claude/settings.json" ]] && echo yes || echo no)"
check "G2: model pin stripped" null "$(pj '.model // "null"')"
check "G2: hooks stripped" 0 "$(pj '.hooks | length')"
check "G2: user key kept" dark "$(pj '.theme')"

# --- H. doctor: user-scope wiring next to a project layout ------------------------
WIRED_MSG="User-scope wiring present: these hooks fire in every project"
fresh_sandbox
inst --project "$P"
inst --doctor --project "$P"
check "H: project-only doctor has no wiring WARN" no "$(has "$OUT" "$WIRED_MSG")"
check "H: project doctor names the project file" yes "$(has "$OUT" "doctor: project scope, checking")"
check "H: no double-fire wording anywhere" no "$(has "$OUT" "fires twice")"
inst
check "H: user-scope install exit 0" 0 "$RC"
inst --doctor --project "$P"
check "H: project-scope doctor WARNs on user-scope wiring" yes "$(has "$OUT" "$WIRED_MSG")"
check "H: WARN lists the user file" yes "$(has "$OUT" "$H/.claude/settings.json (user scope)")"
check "H: WARN lists the project file" yes "$(has "$OUT" "/.claude/settings.json (project)")"
check "H: WARN does not list an unwired local file" no "$(has "$OUT" "(project, local)")"
check "H: remedy keeps the secret" yes "$(has "$OUT" "./install.sh --uninstall --keep-secret")"
check "H: remedy explains the shared secret" yes "$(has "$OUT" "HMAC secret is shared by project-scope installs")"
check "H: remedy re-wires the project afterwards" yes "$(has "$OUT" "./install.sh --scope project --project '$(cd "$P" && pwd -P)'")"
check "H: no double-fire wording in the WARN" no "$(has "$OUT" "fires once per file")"
RUN_DIR="$P" inst --doctor
check "H: user-scope doctor in the project WARNs too" yes "$(has "$OUT" "$WIRED_MSG")"
RUN_DIR="$H" inst --doctor
check "H: user-scope doctor elsewhere has no WARN" no "$(has "$OUT" "$WIRED_MSG")"
must git -C "$P" init -q
mkdir -p "$P/sub/dir"
RUN_DIR="$P/sub/dir" inst --doctor
check "H: user-scope doctor from a subdirectory finds the project" yes "$(has "$OUT" "$WIRED_MSG")"
inst --scope project --project "$P"
check "H: install NOTE when the user file is also wired" yes "$(has "$OUT" "NOTE: this installer's hooks are wired in")"
check "H: install NOTE carries the keep-secret remedy" yes "$(has "$OUT" "--uninstall --keep-secret")"

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
check "I: restore message names the CLAUDE_HOME backup" yes "$(has "$OUT" "from $(bdir)/settings.json.bak.")"
check "I: no stray .tmp" no "$([[ -e "$P/.claude/settings.json.tmp" ]] && echo yes || echo no)"
# Seeded case: no file before, so no backup; the abort removes the seed.
fresh_sandbox
OUT="$(cd "$P" && PATH="$shim:$PATH" HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --project "$P" 2>&1)"; RC=$?
check "I: seeded abort exits nonzero" yes "$([[ "$RC" -ne 0 ]] && echo yes || echo no)"
check "I: seeded abort leaves no settings file" no "$([[ -e "$P/.claude/settings.json" ]] && echo yes || echo no)"
check "I: seeded abort message" yes "$(has "$OUT" "removed again; this run created it")"
check "I: seeded abort made no backup" 0 "$(backups "$(bdir)")"

# --- J. symlinked project settings.json ---------------------------------------------
fresh_sandbox
mkdir -p "$P/.claude" "$P/dotfiles"
printf '{}' > "$P/dotfiles/settings.json"
ln -s "$P/dotfiles/settings.json" "$P/.claude/settings.json"
inst --project "$P"
check "J: exit 0" 0 "$RC"
check "J: symlink left intact" yes "$([[ -L "$P/.claude/settings.json" ]] && echo yes || echo no)"
check "J: target patched" 1 "$(jq -r '.hooks.Stop | length' "$P/dotfiles/settings.json" 2>/dev/null)"

# --- K. project registry ---------------------------------------------------------------
fresh_sandbox
REG="$H/.claude/handoff_projects"
PP="$(cd "$P" && pwd -P)"
inst --project "$P"
check "K: install appends the project" 1 "$(grep -cFx "$PP	settings.json" "$REG" 2>/dev/null)"
inst --project "$P"
check "K: re-install adds no duplicate" 1 "$(wc -l < "$REG" | tr -d ' ')"
inst --project "$P" --local
check "K: --local install adds its own line" 1 "$(grep -cFx "$PP	settings.local.json" "$REG" 2>/dev/null)"
check "K: two lines now" 2 "$(wc -l < "$REG" | tr -d ' ')"
inst --uninstall --project "$P" --local
check "K: project uninstall removes its line" 0 "$(grep -cFx "$PP	settings.local.json" "$REG" 2>/dev/null)"
check "K: the other line survives" 1 "$(grep -cFx "$PP	settings.json" "$REG" 2>/dev/null)"
check "K: uninstall reports the removal" yes "$(has "$OUT" "remove  registry: $PP (settings.local.json)")"
inst --uninstall
check "K: user-scope uninstall exit 0" 0 "$RC"
check "K: user-scope uninstall warns about wired projects" yes "$(has "$OUT" "project-scope installs still wired")"
check "K: warning names the project" yes "$(has "$OUT" "$PP (settings.json)")"
check "K: warning says the hooks will no-op" yes "$(has "$OUT" "silently no-op")"
inst --project "$P"
printf '{}' > "$P/.claude/settings.json"
RUN_DIR="$H" inst --doctor
check "K: user-scope doctor lists the stale entry" yes "$(has "$OUT" "stale project registry entries")"
check "K: stale entry names the project" yes "$(has "$OUT" "$PP (settings.json)")"
inst --uninstall --project "$P"
check "K: last entry removed, registry file gone" no "$([[ -e "$REG" ]] && echo yes || echo no)"
inst --uninstall
check "K: no warning once nothing is registered" no "$(has "$OUT" "project-scope installs still wired")"

# --- L. both project files wired --------------------------------------------------------
fresh_sandbox
inst --project "$P"
inst --project "$P" --local
check "L: --local on a wired settings.json prints the NOTE" yes "$(has "$OUT" "NOTE: this installer's hooks are wired in")"
check "L: NOTE lists the local file" yes "$(has "$OUT" "settings.local.json (project, local)")"
check "L: NOTE says it is redundant" yes "$(has "$OUT" "Both project files carry the hooks")"
check "L: NOTE gives the command for the extra file" yes "$(has "$OUT" "./install.sh --uninstall --scope project --project '$(cd "$P" && pwd -P)'")"
check "L: no user-scope complaint when the user file is clean" no "$(has "$OUT" "User-scope wiring present")"


# --- M. review round ------------------------------------------------------------------
SECRET_HEX="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
# uninst_nojail [args...]: like inst, but without the suite's secret jail,
# so the default $CLAUDE_HOME/handoff_secret path is the one in play.
uninst_nojail() {
  OUT="$(cd "${RUN_DIR:-$P}" && env -u HANDOFF_SECRET_FILE HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" "$@" 2>&1)"
  RC=$?
}
# M1: secret kept while a project is wired; --remove-secret deletes it.
fresh_sandbox
inst --project "$P"
printf '%s\n' "$SECRET_HEX" > "$H/.claude/handoff_secret"; chmod 600 "$H/.claude/handoff_secret"
uninst_nojail --uninstall
check "M1: user uninstall exit 0" 0 "$RC"
check "M1: secret kept while a project is wired" yes "$([[ -f "$H/.claude/handoff_secret" ]] && echo yes || echo no)"
check "M1: keep message" yes "$(has "$OUT" "kept: 1 project-scope install(s) still sign with")"
check "M1: keep message names the flag" yes "$(has "$OUT" "pass --remove-secret to delete it anyway")"
check "M1: WARN names the secret" yes "$(has "$OUT" "The HMAC secret $H/.claude/handoff_secret was kept for them.")"
inst --project "$P"
uninst_nojail --uninstall --remove-secret
check "M1: --remove-secret exit 0" 0 "$RC"
check "M1: --remove-secret deletes the secret" no "$([[ -e "$H/.claude/handoff_secret" ]] && echo yes || echo no)"
check "M1: WARN says the secret is gone" yes "$(has "$OUT" "is gone, so their signed handoffs no longer verify")"
inst --uninstall --keep-secret --remove-secret
check "M1: --keep-secret with --remove-secret refused" 2 "$RC"
check "M1: contradiction message" yes "$(has "$OUT" "--keep-secret and --remove-secret contradict each other")"

# M2: teammate clone / new Mac: the project file is wired, the scripts are not.
fresh_sandbox
inst --project "$P"
H_OLD="$H"; H="$(mktemp -d)"; cleanup_on_exit "$H"; mkdir -p "$H/.claude"
RUN_DIR="$P" inst --doctor
check "M2: doctor reports the missing scripts" 1 "$RC"
check "M2: remedy is the project command" yes "$(has "$OUT" "Re-run ./install.sh --scope project --project '$(cd "$P" && pwd -P)' from")"
check "M2: remedy is not a bare user-scope install" no "$(has "$OUT" "Re-run ./install.sh from")"
H="$H_OLD"

# M3: project uninstall of a directory that is gone clears its registry line.
fresh_sandbox
mkdir -p "$P/wt"
WT="$(cd "$P/wt" && pwd -P)"
inst --project "$WT"
check "M3: registered" 1 "$(grep -cFx "$WT	settings.json" "$H/.claude/handoff_projects" 2>/dev/null)"
rm -rf "$P/wt"
RUN_DIR="$H" inst --doctor
check "M3: doctor lists the vanished dir as stale" yes "$(has "$OUT" "$WT (settings.json)")"
inst --uninstall --scope project --project "$WT"
check "M3: uninstall of a gone dir exits 0" 0 "$RC"
check "M3: says the dir is gone" yes "$(has "$OUT" "$WT no longer exists; nothing to unpatch")"
check "M3: registry line removed" no "$([[ -e "$H/.claude/handoff_projects" ]] && echo yes || echo no)"
check "M3: dir not recreated" no "$([[ -e "$WT" ]] && echo yes || echo no)"
inst --scope project --project "$WT"
check "M3: install into a gone dir still refused" 2 "$RC"

# M4: no --project from a repo subdirectory wires the git toplevel.
fresh_sandbox
must git -C "$P" init -q
mkdir -p "$P/sub/deeper"
RUN_DIR="$P/sub/deeper" inst --scope project
check "M4: exit 0" 0 "$RC"
check "M4: toplevel file wired" 1 "$(pj '.hooks.Stop | length')"
check "M4: subdirectory not wired" no "$([[ -e "$P/sub/deeper/.claude" ]] && echo yes || echo no)"
check "M4: chosen directory printed" yes "$(has "$OUT" "(the git toplevel of the current directory)")"
fresh_sandbox
RUN_DIR="$P" inst --scope project
check "M4: outside a repo the current directory is used and said" yes "$(has "$OUT" "(the current directory).")"

# M5: paths with a space are quoted in printed commands and paste cleanly.
fresh_sandbox
mkdir -p "$P/my proj"
Q="$(cd "$P/my proj" && pwd -P)"
inst --project "$Q"
check "M5: install into a path with a space" 0 "$RC"
inst
inst --doctor --project "$Q"
check "M5: doctor command quotes the path" yes "$(has "$OUT" "--project '$Q'")"
inst --uninstall
check "M5: registry warning quotes the path" yes "$(has "$OUT" "./install.sh --uninstall --scope project --project '$Q'")"
cmd_line="$(printf '%s\n' "$OUT" | grep -m1 "\./install.sh --uninstall --scope project --project '" | sed 's/^ *//')"
OUT="$(cd "$P" && eval "HOME=\"\$H\" CLAUDE_HOME=\"\$H/.claude\" bash \"\$SRC/install.sh\" ${cmd_line#./install.sh }" 2>&1)"; RC=$?
check "M5: the printed command pastes and runs" 0 "$RC"
check "M5: and unwires that project" no "$([[ -e "$Q/.claude/settings.json" ]] && echo yes || echo no)"

finish
