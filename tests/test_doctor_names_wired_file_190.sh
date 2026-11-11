#!/usr/bin/env bash
# install.sh --doctor names the settings file(s) that carry the hooks in every
# layout (#190), not only when it finds a conflict:
#   A. clean project install (settings.json): the doctor lists that file
#   B. clean --local install: the doctor lists settings.local.json, and a
#      doctor run WITHOUT --local says the file it checked carries no hooks
#      and the other one does
#   C. clean user-scope install: the doctor lists the user settings.json
#   D. nothing wired: no listing at all
#   E. both project files present, hooks in only one (each direction): the
#      doctor switches to the wired file for its statusLine check
#   R. the remedy carries --local exactly when the wired file is
#      settings.local.json, and running it wires no second file
#   F. a registered project whose directory is gone: project doctor refuses
#      (rc 2), user doctor reports the stale registry entry
#   G. user-scope doctor run outside any wired project names no wired file
#   H. a corrupt flag-named file beside a wired --local install is named,
#      the doctor still switches, and exits non-zero
#   M. the model WARN names the file the doctor switched to
# Every run sandboxes HOME and CLAUDE_HOME, so nothing touches ~/.claude.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh --doctor names the wired settings file (#190)"

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
  P="$(cd "$P" && pwd -P)"   # the installer prints physical paths
  mkdir -p "$H/.claude"
}
RUN_DIR=""
inst() {
  OUT="$(cd "${RUN_DIR:-$P}" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" "$@" 2>&1 </dev/null)"
  RC=$?
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
LIST="hooks are wired in these settings files"

# A. clean project install.
fresh_sandbox
inst --scope project --project "$P"
inst --doctor --scope project --project "$P"
check "A: doctor exit 0"                       0   "$RC"
check "A: lists the wired file"                yes "$(has "$OUT" "$LIST")"
check "A: names project settings.json"         yes "$(has "$OUT" "$P/.claude/settings.json (project)")"
check "A: does not name settings.local.json"   no  "$(has "$OUT" "settings.local.json")"
check "A: still says all hooks resolve"        yes "$(has "$OUT" "doctor: all hooks resolve.")"
check "A: no conflict WARN"                    no  "$(has "$OUT" "WARN    this installer")"

# B. clean --local install.
fresh_sandbox
inst --scope project --project "$P" --local
inst --doctor --scope project --project "$P" --local
check "B: doctor --local exit 0"               0   "$RC"
check "B: lists settings.local.json"           yes "$(has "$OUT" "$P/.claude/settings.local.json (project, local)")"
check "B: does not name settings.json"         no  "$(has "$OUT" "$P/.claude/settings.json")"
inst --doctor --scope project --project "$P"
check "B: doctor without --local exit 0"       0   "$RC"
check "B: still lists settings.local.json"     yes "$(has "$OUT" "$P/.claude/settings.local.json (project, local)")"
check "B: says the checked file is absent"  yes "$(has "$OUT" "$P/.claude/settings.json does not exist; $P/.claude/settings.local.json carries the handoff hooks,")"
check "B: says it checks settings.local.json"  yes "$(has "$OUT" "this doctor run checks settings.local.json instead")"
check "B: statusLine read from the wired file" yes "$(has "$OUT" "statusLine wired (ours)")"
check "B: no 'statusLine unset'"               no  "$(has "$OUT" "statusLine unset")"

# B2. the reverse: settings.json install checked with --local.
fresh_sandbox
inst --scope project --project "$P"
inst --doctor --scope project --project "$P" --local
check "B2: says it checks settings.json"       yes "$(has "$OUT" "this doctor run checks settings.json instead")"
check "B2: statusLine read from the wired file" yes "$(has "$OUT" "statusLine wired (ours)")"

# C. clean user-scope install.
fresh_sandbox
inst
inst --doctor
check "C: user doctor exit 0"                  0   "$RC"
check "C: lists the user settings.json"        yes "$(has "$OUT" "$H/.claude/settings.json (user scope)")"
check "C: no conflict WARN"                    no  "$(has "$OUT" "WARN    this installer")"

# D. nothing wired: no listing.
fresh_sandbox
inst --doctor --scope project --project "$P"
check "D: no listing when nothing is wired"    no  "$(has "$OUT" "$LIST")"

# --- helpers for E, F, G, R --------------------------------------------------------------------
nhooks() { [[ -f "$1" ]] && jq '(.hooks // {}) | length' "$1" 2>/dev/null || echo 0; }
# wired_files: how many of the two project files carry hooks.
wired_files() {
  local n=0
  [[ "$(nhooks "$P/.claude/settings.json")" -gt 0 ]] && n=$((n + 1))
  [[ "$(nhooks "$P/.claude/settings.local.json")" -gt 0 ]] && n=$((n + 1))
  echo "$n"
}
# run_remedy: execute the "Re-run <cmd> from a persistent clone" line of $OUT.
run_remedy() {
  local line cmd
  line="$(printf '%s\n' "$OUT" | grep 'Re-run ./install.sh' | head -n 1)"
  cmd="${line#*Re-run }"; cmd="${cmd%% from a persistent*}"
  cmd="bash \"\$SRC/install.sh\"${cmd#./install.sh}"
  OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" eval "$cmd" 2>&1 </dev/null)"
  RC=$?
}

# --- E. both files present, hooks in only one --------------------------------------------------
# E1: hooks only in settings.local.json; settings.json holds the user's own statusLine.
fresh_sandbox
inst --scope project --project "$P" --local
printf '%s' '{"statusLine":{"type":"command","command":"mine"}}' > "$P/.claude/settings.json"
inst --doctor --scope project --project "$P"
check "E1: doctor exit 0" 0 "$RC"
check "E1: lists settings.local.json" yes "$(has "$OUT" "$P/.claude/settings.local.json (project, local)")"
check "E1: switches to settings.local.json" yes "$(has "$OUT" "this doctor run checks settings.local.json instead")"
check "E1: statusLine from the wired file" yes "$(has "$OUT" "statusLine wired (ours)")"
check "E1: not the other file's 'user's own'" no "$(has "$OUT" "user's own")"
check "E1: no conflict WARN" no "$(has "$OUT" "WARN    this installer")"
# E2: the reverse, hooks only in settings.json, doctor passed --local.
fresh_sandbox
inst --scope project --project "$P"
printf '%s' '{"statusLine":{"type":"command","command":"mine"}}' > "$P/.claude/settings.local.json"
inst --doctor --scope project --project "$P" --local
check "E2: doctor exit 0" 0 "$RC"
check "E2: switches to settings.json" yes "$(has "$OUT" "this doctor run checks settings.json instead")"
check "E2: statusLine from the wired file" yes "$(has "$OUT" "statusLine wired (ours)")"
check "E2: not the other file's 'user's own'" no "$(has "$OUT" "user's own")"

# --- R. remedy lines ---------------------------------------------------------------------------
# R1: settings.json install, scripts removed: no --local, and following the
# remedy leaves exactly one wired file.
fresh_sandbox
inst --scope project --project "$P"
rm -rf "$H/.claude/bin"
inst --doctor --scope project --project "$P"
check "R1: doctor reports the missing scripts" 1 "$RC"
check "R1: remedy names the project" yes "$(has "$OUT" "Re-run ./install.sh --scope project --project '$P' from")"
check "R1: remedy has no --local" no "$(has "$OUT" "--project '$P' --local")"
run_remedy
check "R1: remedy exit 0" 0 "$RC"
check "R1: exactly one wired file after the remedy" 1 "$(wired_files)"
# R2: --local install checked WITHOUT --local: the remedy carries --local.
fresh_sandbox
inst --scope project --project "$P" --local
rm -rf "$H/.claude/bin"
inst --doctor --scope project --project "$P"
check "R2: doctor reports the missing scripts" 1 "$RC"
check "R2: no 'statusLine unset' hint" no "$(has "$OUT" "statusLine unset")"
check "R2: remedy carries --local" yes "$(has "$OUT" "Re-run ./install.sh --scope project --project '$P' --local from")"
run_remedy
check "R2: remedy exit 0" 0 "$RC"
check "R2: exactly one wired file after the remedy" 1 "$(wired_files)"
check "R2: settings.json not wired" 0 "$(nhooks "$P/.claude/settings.json")"
inst --doctor --scope project --project "$P"
check "R2: next doctor has no 'Both project files' WARN" no "$(has "$OUT" "Both project files carry the hooks")"
# R3: both files present, hooks only in settings.local.json, doctor without --local.
fresh_sandbox
inst --scope project --project "$P" --local
printf '%s' '{}' > "$P/.claude/settings.json"
rm -rf "$H/.claude/bin"
inst --doctor --scope project --project "$P"
check "R3: remedy carries --local" yes "$(has "$OUT" "--project '$P' --local from")"
run_remedy
check "R3: exactly one wired file after the remedy" 1 "$(wired_files)"

# --- F. registered project whose directory is gone ---------------------------------------------
fresh_sandbox
inst --scope project --project "$P"
P2="$(mktemp -d)"; cleanup_on_exit "$P2"
GONE="$P"
rm -rf "$GONE"
OUT="$(cd "$P2" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --doctor --scope project --project "$GONE" 2>&1 </dev/null)"; RC=$?
check "F: project doctor on a gone dir exits 2" 2 "$RC"
check "F: project doctor says it does not exist" yes "$(has "$OUT" "does not exist or is not a directory")"
OUT="$(cd "$P2" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --doctor 2>&1 </dev/null)"; RC=$?
check "F: user doctor exit 0" 0 "$RC"
check "F: user doctor notes the stale registry entry" yes "$(has "$OUT" "stale project registry entries")"
check "F: user doctor lists no wired file" no "$(has "$OUT" "$LIST")"

# --- G. user-scope doctor outside any wired project --------------------------------------------
fresh_sandbox
inst --scope project --project "$P"
P2="$(mktemp -d)"; cleanup_on_exit "$P2"
OUT="$(cd "$P2" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --doctor 2>&1 </dev/null)"; RC=$?
check "G: user doctor exit 0" 0 "$RC"
check "G: names no wired file outside a wired project" no "$(has "$OUT" "$LIST")"

# --- H. corrupt flag-named file ----------------------------------------------------------------
fresh_sandbox
inst --scope project --project "$P" --local
printf '{"hooks":{' > "$P/.claude/settings.json"
inst --doctor --scope project --project "$P"
check "H: doctor exits non-zero" 1 "$RC"
check "H: names the unparseable file" yes "$(has "$OUT" "$P/.claude/settings.json could not be parsed (jq exit ")"
check "H: still switches to the wired file" yes "$(has "$OUT" "this doctor run checks settings.local.json instead")"
check "H: not reported as merely unwired" no "$(has "$OUT" "carries no handoff hooks")"

# --- H2. corrupt flag-named file, no other file wired: one fault, counted once ------------------
# The doctor does not switch, so the statusLine check names the file (BROKEN);
# the pre-check must not name and count it a second time (#187 + #190 merge).
fresh_sandbox
inst --scope project --project "$P"
printf '{"hooks":{' > "$P/.claude/settings.json"
inst --doctor --scope project --project "$P"
check "H2: doctor exits non-zero" 1 "$RC"
check "H2: BROKEN names the file as not valid JSON" yes "$(has "$OUT" "BROKEN  $P/.claude/settings.json is not valid JSON")"
check "H2: no second WARN for the same file" no "$(has "$OUT" "could not be parsed")"
check "H2: counted once" yes "$(has "$OUT" "doctor: 1 issue(s) found.")"

# --- H3. unreadable flag-named file: "cannot be read", never "could not be parsed" --------------
# Skipped as root, where mode 000 is still readable.
fresh_sandbox
inst --scope project --project "$P" --local
echo '{}' > "$P/.claude/settings.json"
chmod 000 "$P/.claude/settings.json"
if [[ -r "$P/.claude/settings.json" ]]; then
  chmod 600 "$P/.claude/settings.json"
  skip "H3: mode 000 is readable here (running as root)"
else
  inst --doctor --scope project --project "$P"
  chmod 600 "$P/.claude/settings.json"
  check "H3: doctor exits non-zero" 1 "$RC"
  check "H3: note says cannot be read" yes "$(has "$OUT" "$P/.claude/settings.json cannot be read; ")"
  check "H3: not mislabelled as a parse failure" no "$(has "$OUT" "could not be parsed")"
  check "H3: still switches to the wired file" yes "$(has "$OUT" "this doctor run checks settings.local.json instead")"
  check "H3: closing line names the cause" yes "$(has "$OUT" "doctor: permission denied while reading settings")"
fi

# --- H4. empty / non-object / multi-document flag-named file next to a wired one ----------------
# Unusable like invalid JSON (settings_usable, #187): named and counted once
# when the doctor switches away from it, never "carries no handoff hooks".
for content in '' '[]' '42' '{}{}'; do
  fresh_sandbox
  inst --scope project --project "$P" --local
  printf '%s' "$content" > "$P/.claude/settings.json"
  inst --doctor --scope project --project "$P"
  check "H4 <$content>: doctor exits non-zero" 1 "$RC"
  check "H4 <$content>: names the file as unusable" yes "$(has "$OUT" "WARN    $P/.claude/settings.json is empty or not a JSON object")"
  check "H4 <$content>: not reported as merely unwired" no "$(has "$OUT" "carries no handoff hooks")"
  check "H4 <$content>: counted once" yes "$(has "$OUT" "doctor: 1 issue(s) found.")"
done

# --- H5. jq fails on the wiring read of the flag-named file: unknown, not "no hooks" ------------
fresh_sandbox
inst --scope project --project "$P" --local
echo '{}' > "$P/.claude/settings.json"
SHIM="$(mktemp -d)"; cleanup_on_exit "$SHIM"
REAL_JQ="$(command -v jq)"
cat > "$SHIM/jq" <<EOF
#!/usr/bin/env bash
# Fail (exit 3) only the wiring read of settings.json; every other call is real jq.
for a in "\$@"; do case "\$a" in *'def wired'*) w=1 ;; esac; done
if [[ -n "\${w:-}" && "\${*: -1}" == */settings.json ]]; then exit 3; fi
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$SHIM/jq"
OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" PATH="$SHIM:$PATH" bash "$SRC/install.sh" --doctor --scope project --project "$P" 2>&1 </dev/null)"; RC=$?
check "H5: doctor exits non-zero" 1 "$RC"
check "H5: note names the jq failure" yes "$(has "$OUT" "$P/.claude/settings.json could not be checked (jq failed); ")"
check "H5: not reported as merely unwired" no "$(has "$OUT" "carries no handoff hooks")"
check "H5: closing line names the jq failure" yes "$(has "$OUT" "doctor: jq failed while reading settings")"

# --- M. model WARN names the checked file ------------------------------------------------------
fresh_sandbox
inst --scope project --project "$P" --local --model claude-opus-4-6
inst --doctor --scope project --project "$P"
check "M: WARN names settings.local.json" yes "$(has "$OUT" "model 'claude-opus-4-6' in settings.local.json")"
check "M: WARN does not name settings.json" no "$(has "$OUT" "model 'claude-opus-4-6' in settings.json")"

finish
