#!/usr/bin/env bash
# Neighbours of #190 that its doctor fix did not cover (#209):
#   U. a project-scope --uninstall whose flags name the project file that
#      carries no hooks while the other one does (a --local install
#      uninstalled without --local, or the reverse) refuses with exit 2,
#      changes nothing, and prints the exact command for the wired file;
#      the cases it must not touch (named file wired, nothing wired, named
#      file corrupt) behave as before
#   S. a user-scope doctor inside a project wired in project scope names the
#      user file its statusLine line read and points at the project doctor
#      (which then reports the statusLine as ours) instead of printing a
#      re-run remedy that changes nothing
#      (U7-U13, review round: a named file with handoff-owned leftovers is
#      stripped as usual with a note naming the other wired file; `[]`, 0-byte,
#      dangling-link and directory named paths are refused; an unreadable
#      other file stops with exit 1)
#   P. the doctor reports a project settings file that fails to parse even
#      when it is not the file being probed, counted once, with the same
#      exit code whichever flag the doctor was run with; a user-scope doctor
#      does so only for a registered or wired project, and a valid non-object,
#      empty or whitespace-only sibling is not reported
# Every run sandboxes HOME and CLAUDE_HOME, so nothing touches ~/.claude.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh --uninstall / --doctor siblings of #190 (#209)"

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
count() { printf '%s\n' "$1" | grep -cF -- "$2"; }
# has_line: <text> is a whole line of the output (leading indentation ignored).
has_line() { printf '%s\n' "$1" | sed 's/^ *//' | grep -Fxq -- "$2" && echo yes || echo no; }
nhooks() { [[ -f "$1" ]] && jq '(.hooks // {}) | length' "$1" 2>/dev/null || echo 0; }
fp() { [[ -e "$1" ]] && cksum < "$1" || echo absent; }
TAB=$'\t'
reg_has() { grep -Fxq -- "$1$TAB$2" "$H/.claude/handoff_projects" 2>/dev/null && echo yes || echo no; }
# state: fingerprints of everything a project-scope uninstall may touch.
state() {
  printf '%s|%s|%s|' "$(fp "$P/.claude/settings.json")" "$(fp "$P/.claude/settings.local.json")" \
    "$(fp "$H/.claude/handoff_projects")"
  find "$H/.claude/handoff_settings_backups" -type f 2>/dev/null | sort | tr '\n' ' '
}
# run_printed: execute the "./install.sh --uninstall ..." line the refusal printed.
run_printed() {
  local line cmd
  line="$(printf '%s\n' "$OUT" | grep -F './install.sh --uninstall --scope project' | head -n 1)"
  cmd="${line#"${line%%./install.sh*}"}"
  cmd="bash \"\$SRC/install.sh\"${cmd#./install.sh}"
  OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" eval "$cmd" 2>&1 </dev/null)"
  RC=$?
}

# --- U1. --local install, --uninstall without --local --------------------------------------------
fresh_sandbox
inst --scope project --project "$P" --local
check "U1: fixture wired settings.local.json" yes "$([[ "$(nhooks "$P/.claude/settings.local.json")" -gt 0 ]] && echo yes || echo no)"
before="$(state)"
inst --uninstall --scope project --project "$P"
check "U1: refuses with exit 2"                     2   "$RC"
check "U1: says settings.json does not exist"       yes "$(has "$OUT" "$P/.claude/settings.json does not exist;")"
check "U1: names the wired file"                    yes "$(has "$OUT" "$P/.claude/settings.local.json carries the handoff hooks.")"
check "U1: prints the exact --local command"        yes "$(has "$OUT" "./install.sh --uninstall --scope project --project '$P' --local")"
check "U1: no 'nothing to strip'"                   no  "$(has "$OUT" "nothing to strip")"
check "U1: nothing changed (files, registry, markers)" "$before" "$(state)"
check "U1: registry line for settings.local.json kept" yes "$(reg_has "$P" settings.local.json)"
run_printed
check "U1: the printed command exits 0"             0   "$RC"
check "U1: it strips settings.local.json"           0   "$(nhooks "$P/.claude/settings.local.json")"
check "U1: and clears its registry line"            no  "$(reg_has "$P" settings.local.json)"

# --- U2. the reverse: settings.json install, --uninstall --local ---------------------------------
fresh_sandbox
inst --scope project --project "$P"
before="$(state)"
inst --uninstall --scope project --project "$P" --local
check "U2: refuses with exit 2"                     2   "$RC"
check "U2: names the wired file"                    yes "$(has "$OUT" "$P/.claude/settings.json carries the handoff hooks.")"
check "U2: prints the command without --local"      yes "$(has_line "$OUT" "./install.sh --uninstall --scope project --project '$P'")"
check "U2: the command has no --local"              no  "$(has "$OUT" "--project '$P' --local")"
check "U2: nothing changed"                         "$before" "$(state)"
run_printed
check "U2: the printed command exits 0"             0   "$RC"
check "U2: it strips settings.json"                 0   "$(nhooks "$P/.claude/settings.json")"

# --- U3. named file present with the user's own content, no hooks --------------------------------
fresh_sandbox
inst --scope project --project "$P" --local
printf '%s\n' '{"model":"mine","permissions":{"allow":["Bash(ls:*)"]}}' > "$P/.claude/settings.json"
before="$(state)"
inst --uninstall --scope project --project "$P"
check "U3: refuses with exit 2"                     2   "$RC"
check "U3: says the named file carries no hooks"    yes "$(has "$OUT" "$P/.claude/settings.json carries no handoff hooks;")"
check "U3: the user's file is byte-identical"       "$before" "$(state)"

# --- U4. both files wired: the named one is stripped, the other left alone -----------------------
fresh_sandbox
inst --scope project --project "$P" --local
inst --scope project --project "$P"
n_local="$(nhooks "$P/.claude/settings.local.json")"
inst --uninstall --scope project --project "$P"
check "U4: uninstall of the wired named file exits 0" 0 "$RC"
check "U4: settings.json stripped"                  0   "$(nhooks "$P/.claude/settings.json")"
check "U4: settings.local.json untouched"           "$n_local" "$(nhooks "$P/.claude/settings.local.json")"

# --- U5. nothing wired anywhere: still a clean no-op ---------------------------------------------
fresh_sandbox
inst --uninstall --scope project --project "$P"
check "U5: exit 0"                                  0   "$RC"
check "U5: nothing to strip"                        yes "$(has "$OUT" "settings.json does not exist; nothing to strip")"

# --- U6. named file corrupt beside a wired other: the existing refusal, unchanged ----------------
fresh_sandbox
inst --scope project --project "$P" --local
printf '{not json' > "$P/.claude/settings.json"
before="$(state)"
inst --uninstall --scope project --project "$P"
check "U6: exit 1 (not valid JSON)"                 1   "$RC"
check "U6: names the invalid file"                  yes "$(has "$OUT" "settings.json is not valid JSON; refusing to edit")"
check "U6: nothing changed"                         "$before" "$(state)"

# --- S. user-scope doctor inside a project-scope install -----------------------------------------
# S1: --local, no user settings file at all.
fresh_sandbox
inst --scope project --project "$P" --local
inst --doctor
check "S1: user doctor exit 0"                      0   "$RC"
check "S1: no re-run remedy on the statusLine line" no  "$(has "$OUT" "statusLine unset (re-run")"
check "S1: names the user file it read"             yes "$(has "$OUT" "statusLine unset in $H/.claude/settings.json (the user file)")"
check "S1: points at the --local project doctor"    yes "$(has "$OUT" "./install.sh --doctor --scope project --project '$P' --local")"
inst --doctor --scope project --project "$P" --local
check "S1: that doctor reads the wired statusLine"  yes "$(has "$OUT" "statusLine wired (ours)")"
# S2: settings.json install, user file present but unwired ({}): the other branch.
fresh_sandbox
inst --scope project --project "$P"
printf '%s' '{}' > "$H/.claude/settings.json"
inst --doctor
check "S2: user doctor exit 0"                      0   "$RC"
check "S2: no re-run remedy on the statusLine line" no  "$(has "$OUT" "statusLine unset (re-run")"
check "S2: points at the project doctor"            yes "$(has "$OUT" "to check that one run: ./install.sh --doctor --scope project --project '$P'")"
check "S2: no --local in it"                        no  "$(has "$OUT" "--project '$P' --local")"
# S3: nothing wired anywhere: the plain remedy is still right.
fresh_sandbox
inst --doctor
check "S3: plain re-run remedy"                     yes "$(has "$OUT" "statusLine unset (re-run ./install.sh to wire it)")"

# --- P. unparseable project file that is not the probed one --------------------------------------
PARSE="could not be parsed"
# P1: --local install, corrupt settings.json, doctor --local.
fresh_sandbox
inst --scope project --project "$P" --local
printf '{not json' > "$P/.claude/settings.json"
inst --doctor --scope project --project "$P" --local
check "P1: doctor --local exits 1"                  1   "$RC"
check "P1: names the corrupt sibling"               yes "$(has "$OUT" "WARN    $P/.claude/settings.json $PARSE")"
check "P1: one parse WARN"                          1   "$(count "$OUT" "WARN    $P/.claude/settings.json $PARSE")"
check "P1: counted once"                            yes "$(has "$OUT" "doctor: 1 issue(s) found.")"
# P2: same files, doctor without --local (the #190 H path): still one report.
inst --doctor --scope project --project "$P"
check "P2: doctor exits 1"                          1   "$RC"
check "P2: one parse WARN, not two"                 1   "$(count "$OUT" "WARN    $P/.claude/settings.json $PARSE")"
check "P2: counted once"                            yes "$(has "$OUT" "doctor: 1 issue(s) found.")"
# P3: same files, user-scope doctor inside the project.
inst --doctor
check "P3: user doctor exits 1"                     1   "$RC"
check "P3: names the corrupt project file"          yes "$(has "$OUT" "WARN    $P/.claude/settings.json $PARSE")"
check "P3: one parse WARN"                          1   "$(count "$OUT" "WARN    $P/.claude/settings.json $PARSE")"
# P4: a valid sibling is not reported.
fresh_sandbox
inst --scope project --project "$P" --local
printf '%s' '{}' > "$P/.claude/settings.json"
inst --doctor --scope project --project "$P" --local
check "P4: valid sibling: exit 0"                   0   "$RC"
check "P4: no parse report"                         no  "$(has "$OUT" "$PARSE")"
# P5: the reverse: settings.json install, corrupt settings.local.json, doctor without --local.
fresh_sandbox
inst --scope project --project "$P"
printf '[1,' > "$P/.claude/settings.local.json"
inst --doctor --scope project --project "$P"
check "P5: doctor exits 1"                          1   "$RC"
check "P5: names the corrupt settings.local.json"   yes "$(has "$OUT" "WARN    $P/.claude/settings.local.json $PARSE")"
# P6: corrupt probed file, nothing wired (no switch): the existing BROKEN line, counted once.
fresh_sandbox
mkdir -p "$P/.claude"
printf '{not json' > "$P/.claude/settings.json"
inst --doctor --scope project --project "$P"
check "P6: BROKEN not valid JSON"                   yes "$(has "$OUT" "BROKEN  $P/.claude/settings.json is not valid JSON")"
check "P6: no second report from the sibling check" no  "$(has "$OUT" "$PARSE")"

# --- U7. named file with leftovers but no hooks: strip as before, note the other file -----------
fresh_sandbox
inst --scope project --project "$P"
inst --scope project --project "$P" --local
must jq 'del(.hooks)' "$P/.claude/settings.json" > "$P/.claude/settings.json.new"
must mv "$P/.claude/settings.json.new" "$P/.claude/settings.json"
n_local="$(nhooks "$P/.claude/settings.local.json")"
inst --uninstall --scope project --project "$P"
check "U7: leftovers are stripped (exit 0)"         0   "$RC"
check "U7: statusLine removed"                      no  "$(jq -e 'has("statusLine")' "$P/.claude/settings.json" >/dev/null 2>&1 && echo yes || echo no)"
check "U7: our permissions removed"                 0   "$(jq '[(.permissions.allow // [])[] | select(contains(".claude/bin/"))] | length' "$P/.claude/settings.json" 2>/dev/null || echo gone)"
check "U7: registry line for settings.json cleared" no  "$(reg_has "$P" settings.json)"
check "U7: settings.local.json untouched"           "$n_local" "$(nhooks "$P/.claude/settings.local.json")"
check "U7: note names the other wired file"         yes "$(has "$OUT" "note: $P/.claude/settings.local.json still carries the handoff hooks")"
check "U7: note carries the --local command"        yes "$(has_line "$OUT" "./install.sh --uninstall --scope project --project '$P' --local")"

# --- U8. named file deleted, its registry line and created marker left: cleared as before --------
fresh_sandbox
inst --scope project --project "$P"
inst --scope project --project "$P" --local
must rm "$P/.claude/settings.json"
mk="$(find "$H/.claude/handoff_settings_backups" -name settings.json.created | head -n 1)"
check "U8: fixture has the settings.json marker"    yes "$([[ -n "$mk" && -e "$mk" ]] && echo yes || echo no)"
inst --uninstall --scope project --project "$P"
check "U8: exit 0"                                  0   "$RC"
check "U8: registry line for settings.json cleared" no  "$(reg_has "$P" settings.json)"
check "U8: created marker cleared"                  no  "$([[ -n "$mk" && -e "$mk" ]] && echo yes || echo no)"
check "U8: settings.local.json registry line kept"  yes "$(reg_has "$P" settings.local.json)"
check "U8: note names the other wired file"         yes "$(has "$OUT" "note: $P/.claude/settings.local.json still carries the handoff hooks")"

# --- U9/U10. named file `[]` (valid JSON, not an object) or 0 bytes: refused ----------------------
for shape in '[]' ''; do
  fresh_sandbox
  inst --scope project --project "$P" --local
  printf '%s' "$shape" > "$P/.claude/settings.json"
  before="$(state)"
  inst --uninstall --scope project --project "$P"
  check "U9: named file '$shape' refused with exit 2" 2 "$RC"
  check "U9: named file '$shape' left as it was"      "$before" "$(state)"
done

# --- U11. named file a dangling symlink: the message names the project path ----------------------
fresh_sandbox
inst --scope project --project "$P" --local
must ln -s "$P/nonexistent/x" "$P/.claude/settings.json"
inst --uninstall --scope project --project "$P"
check "U11: dangling link refused with exit 2"      2   "$RC"
check "U11: names the project path"                 yes "$(has "$OUT" "ERROR   $P/.claude/settings.json is a dangling symlink;")"
check "U11: does not name the link target as the file" no "$(has "$OUT" "ERROR   $P/nonexistent/x")"

# --- U12. other file unreadable, named file absent: exit 1, not "nothing to strip" --------------
if [[ "$(id -u)" -eq 0 ]]; then
  skip "U12: running as root, mode 000 does not block reads"
else
  fresh_sandbox
  inst --scope project --project "$P" --local
  must chmod 000 "$P/.claude/settings.local.json"
  inst --uninstall --scope project --project "$P"
  chmod 600 "$P/.claude/settings.local.json"
  check "U12: exit 1"                               1   "$RC"
  check "U12: says the other file's wiring is unknown" yes "$(has "$OUT" "carries the handoff hooks is unknown")"
  check "U12: no 'nothing to strip'"                no  "$(has "$OUT" "nothing to strip")"
  check "U12: the other file still wired"           yes "$([[ "$(nhooks "$P/.claude/settings.local.json")" -gt 0 ]] && echo yes || echo no)"
fi

# --- U13. named path is a directory beside a wired other: refused -------------------------------
fresh_sandbox
inst --scope project --project "$P" --local
must mkdir "$P/.claude/settings.json"
inst --uninstall --scope project --project "$P"
check "U13: directory named path refused with exit 2" 2 "$RC"
check "U13: says it is not a regular file"          yes "$(has "$OUT" "$P/.claude/settings.json is not a regular file;")"

# --- S4. project scope keeps the plain statusLine remedy -----------------------------------------
fresh_sandbox
mkdir -p "$P/.claude"
printf '%s' '{}' > "$P/.claude/settings.json"
inst --doctor --scope project --project "$P"
check "S4: plain project remedy"                    yes "$(has "$OUT" "statusLine unset (re-run ./install.sh --scope project --project '$P' to wire it)")"
check "S4: no user-file wording in project scope"   no  "$(has "$OUT" "(the user file)")"

# --- S5. user doctor outside the project, wiring found through the registry ----------------------
fresh_sandbox
inst --scope project --project "$P" --local
OTHER_DIR="$(mktemp -d)"; cleanup_on_exit "$OTHER_DIR"
RUN_DIR="$OTHER_DIR" inst --doctor
check "S5: user-file wording"                       yes "$(has "$OUT" "statusLine unset in $H/.claude/settings.json (the user file). The hooks are")"
check "S5: no 'The hooks here'"                     no  "$(has "$OUT" "The hooks here")"
check "S5: points at the registered project"        yes "$(has "$OUT" "./install.sh --doctor --scope project --project '$P' --local")"

# --- P7-P9. valid non-object, empty and whitespace-only siblings are not reported ----------------
for shape in '[]' '' '   '; do
  fresh_sandbox
  inst --scope project --project "$P" --local
  printf '%s' "$shape" > "$P/.claude/settings.json"
  inst --doctor --scope project --project "$P" --local
  check "P7: sibling '$shape': exit 0"              0   "$RC"
  check "P7: sibling '$shape': no parse WARN"       no  "$(has "$OUT" "$PARSE")"
done

# --- P10. user doctor in a directory with no handoff install: a corrupt file there is not ours ---
fresh_sandbox
inst --scope project --project "$P" --local
OTHER_DIR="$(mktemp -d)"; cleanup_on_exit "$OTHER_DIR"
OTHER_DIR="$(cd "$OTHER_DIR" && pwd -P)"
mkdir -p "$OTHER_DIR/.claude"
printf '{not json' > "$OTHER_DIR/.claude/settings.local.json"
RUN_DIR="$OTHER_DIR" inst --doctor
check "P10: unrelated directory: exit 0"            0   "$RC"
check "P10: unrelated directory: no parse WARN"     no  "$(has "$OUT" "$PARSE")"
# P11: a registered project whose only file is corrupt is still checked.
fresh_sandbox
inst --scope project --project "$P"
printf '{not json' > "$P/.claude/settings.json"
inst --doctor
check "P11: registered project: exit 1"             1   "$RC"
check "P11: registered project: parse WARN"         yes "$(has "$OUT" "WARN    $P/.claude/settings.json $PARSE")"

finish
