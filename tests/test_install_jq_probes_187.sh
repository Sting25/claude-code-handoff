#!/usr/bin/env bash
# Tests that install.sh --install/--uninstall/--doctor never read a jq failure
# (exit >= 2) as "absent" or "not ours" in the hook, permission and statusLine
# probes (#187; the install-time statusLine probe is #174, see
# test_install_statusline_probe.sh). A jq shim fails only the probe under test
# (matched by a fragment of its filter text) and passes everything else through
# to the real jq. Each failing run must exit nonzero and leave the settings
# file byte-identical to what it was before the run.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh jq probes: a jq failure is an error, never 'absent'"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed, so install.sh settings patching is a no-op without it"
  finish
  exit
fi

REAL_JQ="$(command -v jq)"
SHIM="$(mktemp -d)"
cat > "$SHIM/jq" <<SH
#!/usr/bin/env bash
# FAIL_JQ_MATCH2, when set, must also match (two fragments, e.g. a filter and a path).
if [[ -n "\${FAIL_JQ_MATCH:-}" && "\$*" == *"\$FAIL_JQ_MATCH"* \
      && "\$*" == *"\${FAIL_JQ_MATCH2:-}"* ]]; then exit 5; fi
exec "$REAL_JQ" "\$@"
SH
chmod +x "$SHIM/jq"

SRC="$(mktemp -d)"
cp "$REPO_ROOT/install.sh" "$SRC/"
cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$SRC/"
cleanup_on_exit "$SHIM" "$SRC"

HOME_DIR=""
# run_sh <fail-match|""> <args...> ; runs install.sh in $HOME_DIR; sets RC, OUT, ERR.
run_sh() {
  local m="$1"; shift
  OUT="$(FAIL_JQ_MATCH="$m" HANDOFF_MODEL="" PATH="$SHIM:$PATH" HOME="$HOME_DIR" CLAUDE_HOME="$HOME_DIR" \
    bash "$SRC/install.sh" "$@" 2>"$HOME_DIR/err" </dev/null)"
  RC=$?
  ERR="$(cat "$HOME_DIR/err")"
}
fresh_home() { HOME_DIR="$(mktemp -d)"; cleanup_on_exit "$HOME_DIR"; }
has() { [[ "$1" == *"$2"* ]] && echo yes || echo no; }
nz() { [[ $1 -ne 0 ]] && echo yes || echo no; }
snap() { cksum < "$HOME_DIR/settings.json"; }
nbin() { find "$HOME_DIR/bin" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '; }

# A healthy install first, so every later run starts from a fully wired file.
fresh_home
run_sh ""
check "healthy install: exit 0" 0 "$RC"
BASE_HOOKS="$(jq -c '.hooks' "$HOME_DIR/settings.json")"
BASE_PERMS="$(jq -c '.permissions.allow' "$HOME_DIR/settings.json")"
BASE_SUM="$(snap)"
BASE_NBIN="$(nbin)"
check "healthy install: bin/ scripts linked"    yes "$([[ $BASE_NBIN -gt 0 ]] && echo yes || echo no)"

# Failing-probe fragments: hooks `.hooks?`, permissions `index($p)`,
# statusLine `.statusLine.command?`.
# 1. Second install, the maybe_install_hook probe fails. The fragment names
#    the PreCompact event, which only maybe_install_hook probes in install mode
#    (the legacy SessionStart migrate probe runs first with `--arg e SessionStart`).
run_sh '--arg e PreCompact'
check "install hook probe: exit nonzero"        yes "$(nz $RC)"
check "install hook probe: ERROR names hook"    yes "$(has "$ERR" 'jq failed (exit 5) while probing hook')"
check "install hook probe: settings identical"  "$BASE_SUM" "$(snap)"
check "install hook probe: hooks not doubled"   "$BASE_HOOKS" "$(jq -c '.hooks' "$HOME_DIR/settings.json")"
check "install hook probe: names PreCompact"    yes "$(has "$ERR" 'probing hook PreCompact')"
check "install hook probe: install re-run hint" yes "$(has "$ERR" 're-run ./install.sh.')"

# 1b. The legacy SessionStart migrate probe (runs first in patch_settings).
run_sh '--arg e SessionStart'
check "install legacy-migrate probe: exit nonzero"   yes "$(nz $RC)"
check "install legacy-migrate probe: ERROR names it" yes "$(has "$ERR" 'probing hook SessionStart')"
check "install legacy-migrate probe: settings identical" "$BASE_SUM" "$(snap)"

# 2. Second install, permission probe fails: allow list must not double.
run_sh "index(\$p)"
check "install perm probe: exit nonzero"        yes "$(nz $RC)"
check "install perm probe: ERROR names perm"    yes "$(has "$ERR" 'jq failed (exit 5) while probing permission')"
check "install perm probe: settings identical"  "$BASE_SUM" "$(snap)"
check "install perm probe: allow list intact"   "$BASE_PERMS" "$(jq -c '.permissions.allow' "$HOME_DIR/settings.json")"

# 3. Healthy second install is still a no-op (the totalised filters agree).
run_sh ""
check "healthy reinstall: exit 0"               0   "$RC"
check "healthy reinstall: settings identical"   "$BASE_SUM" "$(snap)"

# 4. Uninstall, statusLine probe fails: must not report 'not ours' and leave
#    a dangling statusLine; the run aborts and restores the file.
run_sh 'objects | .command?' --uninstall
check "uninstall statusLine probe: exit nonzero"     yes "$(nz $RC)"
check "uninstall statusLine probe: no 'not ours'"    no  "$(has "$OUT" 'not ours')"
check "uninstall statusLine probe: ERROR on stderr"  yes "$(has "$ERR" 'jq failed (exit 5) while probing statusLine')"
check "uninstall statusLine probe: settings identical" "$BASE_SUM" "$(snap)"
check "uninstall statusLine probe: bin/ scripts still present" "$BASE_NBIN" "$(nbin)"
check "uninstall statusLine probe: ERROR names --uninstall" yes "$(has "$ERR" 're-run ./install.sh --uninstall')"

# 5. Uninstall, hook probe fails.
run_sh '.hooks? | objects' --uninstall
check "uninstall hook probe: exit nonzero"      yes "$(nz $RC)"
check "uninstall hook probe: no 'not present'"  no  "$(has "$OUT" 'hook SessionStart (not present)')"
check "uninstall hook probe: ERROR on stderr"   yes "$(has "$ERR" 'jq failed (exit 5) while probing hook')"
check "uninstall hook probe: settings identical" "$BASE_SUM" "$(snap)"

# 6. Uninstall, permission probe fails (hooks were already stripped in this
#    run, so this also proves the rollback restores them).
run_sh "index(\$p)" --uninstall
check "uninstall perm probe: exit nonzero"      yes "$(nz $RC)"
check "uninstall perm probe: no 'not present'"  no  "$(has "$OUT" 'permission not present')"
check "uninstall perm probe: ERROR on stderr"   yes "$(has "$ERR" 'jq failed (exit 5) while probing permission')"
check "uninstall perm probe: settings identical" "$BASE_SUM" "$(snap)"

# 7. --doctor, statusLine probe fails: a WARN, never "user's own".
run_sh 'objects | .command?' --doctor
check "doctor statusLine probe: WARN printed"   yes "$(has "$OUT" 'jq failed (exit 5) while probing statusLine')"
check "doctor statusLine probe: not 'user's own'" no "$(has "$OUT" "user's own")"
check "doctor statusLine probe: settings identical" "$BASE_SUM" "$(snap)"
run_sh "" --doctor
check "doctor healthy: statusLine wired (ours)" yes "$(has "$OUT" 'statusLine wired (ours)')"

# 8. Odd shapes of the probed keys are plain answers, not jq errors: with a
#    healthy jq each of these installs (exit 0) and wires the hooks.
for shape in '{"permissions":{}}' '{"statusLine":"s"}' '{"hooks":{}}' \
             '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":42}]}]}}'; do
  fresh_home
  printf '%s' "$shape" > "$HOME_DIR/settings.json"
  run_sh ""
  check "odd shape $shape: exit 0"       0   "$RC"
  check "odd shape $shape: no probe abort" no "$(has "$ERR" 'while probing')"
  check "odd shape $shape: SessionStart wired" yes \
    "$(jq -e '.hooks.SessionStart | length > 0' "$HOME_DIR/settings.json" >/dev/null 2>&1 && echo yes || echo no)"
done

# 8b. A string where the installer APPENDS to a list ("allow":"x", "Stop":"s",
#     "hooks":"s") fails in the append itself, not in a probe (pre-existing
#     behaviour, out of scope for #187). The abort must be explicit (nonzero,
#     the jq error and "aborted mid-patch" on stderr) and leave the file as it was.
for shape in '{"permissions":{"allow":"x"}}' '{"hooks":{"Stop":"s"}}' '{"hooks":"s"}'; do
  fresh_home
  printf '%s' "$shape" > "$HOME_DIR/settings.json"
  BEFORE="$(snap)"
  run_sh ""
  check "append onto $shape: exit nonzero"       yes "$(nz $RC)"
  check "append onto $shape: explicit abort text" yes "$(has "$ERR$OUT" 'aborted mid-patch')"
  check "append onto $shape: settings restored"  "$BEFORE" "$(snap)"
done

# 9. D1: a non-object root (valid JSON, so the unpatch/doctor gates let it
#    through) must not make the statusLine filters fail.
for root in '[]' '42' '"x"'; do
  fresh_home
  printf '%s' "$root" > "$HOME_DIR/settings.json"
  run_sh "" --uninstall
  check "uninstall root $root: exit 0"         0   "$RC"
  check "uninstall root $root: no jq failed"   no  "$(has "$ERR$OUT" 'jq failed')"
  fresh_home
  run_sh ""                       # healthy bin/ so doctor has no other fault
  printf '%s' "$root" > "$HOME_DIR/settings.json"
  # A non-object root is reported once as broken (settings_usable), never as
  # a jq failure.
  run_sh "" --doctor
  check "doctor root $root: exit nonzero (broken)" yes "$(nz $RC)"
  check "doctor root $root: BROKEN not an object" yes "$(has "$OUT" 'is empty or not a JSON object')"
  check "doctor root $root: no jq failed"      no  "$(has "$ERR$OUT" 'jq failed')"
done

# 10. D6: the second statusLine probe (a statusLine that is not ours).
fresh_home
run_sh ""
printf '%s' '{"statusLine":{"type":"command","command":"/x/own.sh"}}' > "$HOME_DIR/settings.json"
OWN_SUM="$(snap)"
run_sh "" --doctor
check "doctor own statusLine: info, exit 0"    0   "$RC"
run_sh '// null) != null' --uninstall
check "uninstall 2nd statusLine probe: exit nonzero" yes "$(nz $RC)"
check "uninstall 2nd statusLine probe: ERROR"  yes "$(has "$ERR" 'jq failed (exit 5) while probing statusLine')"
check "uninstall 2nd statusLine probe: settings identical" "$OWN_SUM" "$(snap)"
run_sh '// null) != null' --doctor
check "doctor 2nd statusLine probe: WARN"      yes "$(has "$OUT" 'jq failed (exit 5) while probing statusLine')"
check "doctor 2nd statusLine probe: exit nonzero (D7)" yes "$(nz $RC)"

# 11. D7: any doctor jq failure makes doctor exit nonzero.
fresh_home
run_sh ""
run_sh 'objects | .command?' --doctor
check "doctor jq failure: exit nonzero"        yes "$(nz $RC)"
run_sh 'objects | .command?' --doctor
check "doctor jq failure: stderr says so"      yes "$(has "$ERR" 'jq failed while reading settings')"
# settings_has_our_hooks (wired(...) helper) failing.
run_sh 'def wired' --doctor
check "doctor wiring check failure: WARN"      yes "$(has "$ERR" 'jq failed (exit 5) while checking')"
check "doctor wiring check failure: exit nonzero" yes "$(nz $RC)"

# 12. D3: the stale-command extraction. A stale marker-matching command is
#     rewritten by a healthy run; with the extraction failing, the run aborts
#     and leaves the file untouched instead of reading "no stale command".
fresh_home
run_sh ""
jq '.hooks.Stop[0].hooks[0].command = (.hooks.Stop[0].hooks[0].command + " --old-flag")' \
  "$HOME_DIR/settings.json" > "$HOME_DIR/s.new" && mv "$HOME_DIR/s.new" "$HOME_DIR/settings.json"
STALE_SUM="$(snap)"
# shellcheck disable=SC2016  # jq filter text, matched literally by the shim
run_sh '. != $c)]'
check "stale extraction: exit nonzero"         yes "$(nz $RC)"
check "stale extraction: ERROR names it"       yes "$(has "$ERR" 'stale command of hook')"
check "stale extraction: settings identical"   "$STALE_SUM" "$(snap)"
run_sh ""
check "stale extraction healthy: exit 0"       0   "$RC"
check "stale extraction healthy: rewritten"    yes "$(has "$OUT" 'UPDATE  hook Stop')"

# 13. D4: the model reads. An unreadable model must not become "no model".
fresh_home
printf '%s' '{"model":"mine"}' > "$HOME_DIR/settings.json"
M_SUM="$(snap)"
run_sh '.model? //' --model 'opus[1m]'
check "install --model, read fails: exit nonzero"   yes "$(nz $RC)"
check "install --model, read fails: user model kept" mine "$(jq -r .model "$HOME_DIR/settings.json")"
check "install --model, read fails: settings identical" "$M_SUM" "$(snap)"
run_sh "" --model 'opus[1m]'
check "install --model healthy: keeps user model" mine "$(jq -r .model "$HOME_DIR/settings.json")"
fresh_home
run_sh "" --model 'opus[1m]'
M2_SUM="$(snap)"
run_sh '.model? //' --uninstall
check "uninstall model, read fails: exit nonzero"   yes "$(nz $RC)"
check "uninstall model, read fails: settings identical" "$M2_SUM" "$(snap)"
check "uninstall model, read fails: pin record kept" yes "$([[ -f "$HOME_DIR/handoff-model-pin" ]] && echo yes || echo no)"
check "uninstall model, read fails: bin/ scripts present" "$BASE_NBIN" "$(nbin)"
run_sh '.model? //' --doctor
check "doctor model read fails: WARN"          yes "$(has "$OUT" 'while reading model')"
check "doctor model read fails: exit nonzero"  yes "$(nz $RC)"

# 14. settings_has_our_hooks' wired() is total: a healthy jq never exits 2 or
#     more on any shape (a jq error there would read as "jq failed"). Matrix:
#     the root itself, then each value shape at .hooks, .hooks.<event>,
#     .hooks.<event>[].hooks and .hooks.<event>[].hooks[].command. The filter
#     is read out of the built install.sh, so the test runs what ships.
WIRED_F="$(awk '/def wired\(\$k; \$m\)/{f=1} f&&/^    '"'"' "\$f"/{exit} f{print}' "$SRC/install.sh")"
check "wired matrix: filter extracted"         yes "$(has "$WIRED_F" 'UserPromptSubmit')"
MX="$(mktemp -d)"; cleanup_on_exit "$MX"
cells=0; bad=0; bad_list=""
mx_cell() {  # <json>
  local rc=0
  printf '%s' "$1" > "$MX/s.json"
  # shellcheck disable=SC2016  # jq filter text from install.sh
  "$REAL_JQ" -e --arg ss m1 --arg se m2 --arg post m3 --arg wr m4 --arg st m5 --arg up m6 \
    "$WIRED_F" "$MX/s.json" >/dev/null 2>&1 || rc=$?
  cells=$((cells + 1))
  if [[ $rc -ge 2 ]]; then bad=$((bad + 1)); bad_list="$bad_list $1"; fi
}
for v in '{}' '[]' '42' '"x"' 'null' 'true' 'false'; do mx_cell "$v"; done
for v in 'null' '"s"' '42' '[]' '[1,"s",null]' '{}' 'true' 'false'; do
  mx_cell "{\"hooks\":$v}"
  mx_cell "{\"hooks\":{\"Stop\":$v}}"
  mx_cell "{\"hooks\":{\"Stop\":[{\"hooks\":$v}]}}"
  mx_cell "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":$v}]}]}}"
done
check "wired matrix: 39 cells run"             39  "$cells"
check "wired matrix: cells with jq exit >= 2 ($bad_list )" 0 "$bad"
# The marker still matches at the canonical depth.
printf '%s' '{"hooks":{"Stop":[{"hooks":[{"command":"bash x/m5.sh"}]}]}}' > "$MX/s.json"
check "wired matrix: canonical command found"  0 "$("$REAL_JQ" -e --arg ss m1 --arg se m2 --arg post m3 \
  --arg wr m4 --arg st m5 --arg up m6 "$WIRED_F" "$MX/s.json" >/dev/null 2>&1; echo $?)"
# End to end, the review's case: a string event value is a quiet "not wired".
fresh_home
run_sh ""
printf '%s' '{"hooks":{"Stop":"s"}}' > "$HOME_DIR/settings.json"
run_sh "" --doctor
check "doctor Stop string: exit 0"             0   "$RC"
check "doctor Stop string: no jq failed"       no  "$(has "$ERR$OUT" 'jq failed')"

# 15. User-scope --uninstall with the registry scan's wiring read failing:
#     every registered project would read as stale, so the shared secret must
#     survive and the run must fail, not delete it and exit 0.
fresh_home
run_sh ""
mkdir -p "$HOME_DIR/proj"
run_sh "" --scope project --project "$HOME_DIR/proj"
check "registry scan: project install exit 0"  0   "$RC"
check "registry scan: project registered"      yes "$(grep -q proj "$HOME_DIR/handoff_projects" 2>/dev/null && echo yes || echo no)"
printf '%064d\n' 0 | tr 0 a > "$HOME_DIR/handoff_secret"; chmod 600 "$HOME_DIR/handoff_secret"
SECRET_SUM="$(cksum < "$HOME_DIR/handoff_secret")"
REG_SUM="$(cksum < "$HOME_DIR/handoff_projects")"
run_sh 'def wired' --uninstall --keep-secret
check "registry scan fails: re-run repeats --keep-secret" yes "$(has "$ERR" 're-run ./install.sh --uninstall --keep-secret.')"
check "registry scan fails: names the file as a cause" yes "$(has "$ERR" 'Fix jq, or fix the file named above')"
run_sh 'def wired' --uninstall
check "registry scan fails: exit nonzero"      yes "$(nz $RC)"
check "registry scan fails: secret kept"       "$SECRET_SUM" "$(cksum < "$HOME_DIR/handoff_secret" 2>/dev/null)"
check "registry scan fails: registry intact"   "$REG_SUM" "$(cksum < "$HOME_DIR/handoff_projects" 2>/dev/null)"
check "registry scan fails: no 'remove' secret" no "$(has "$OUT" 'per-machine HMAC secret')"
check "registry scan fails: ERROR on stderr"   yes "$(has "$ERR" 'ERROR   jq failed while reading ')"
check "registry scan fails: ERROR names file"  yes "$(has "$ERR" 'proj/.claude/settings.json from the project registry')"
run_sh "" --uninstall
check "registry scan healthy re-run: exit 0"   0   "$RC"
check "registry scan healthy re-run: secret kept for wired project" yes "$(has "$OUT" 'still sign with')"

# 16. --doctor on a settings file that is not valid JSON: one BROKEN line,
#     counted as broken, and none of the jq-failure WARNs.
fresh_home
run_sh ""
printf '%s' '{"hooks": trailing,}' > "$HOME_DIR/settings.json"
run_sh "" --doctor
check "doctor invalid JSON: exit nonzero"      yes "$(nz $RC)"
check "doctor invalid JSON: BROKEN line"       yes "$(has "$OUT" "BROKEN  $HOME_DIR/settings.json is not valid JSON")"
check "doctor invalid JSON: counted"           yes "$(has "$ERR" 'doctor: 1 issue(s) found.')"
check "doctor invalid JSON: no jq failed WARN" no  "$(has "$ERR$OUT" 'jq failed')"

# 17. A registered project whose settings.json is 0 bytes or whitespace only
#     is a stale entry (settings_usable), never a jq failure: user-scope
#     --uninstall exits 0 and handles the secret as for a stale project
#     (deleted, nothing still signs with it), project-scope --uninstall clears
#     the registry line, --doctor lists it as stale and exits 0. The user's own
#     settings.json in that state is one BROKEN line, never "fix jq".
for content in '' $'  \n\t\n'; do
  label="$([[ -z "$content" ]] && echo 0-byte || echo whitespace)"
  for step in user project doctor; do
    fresh_home
    run_sh ""
    mkdir -p "$HOME_DIR/proj"
    run_sh "" --scope project --project "$HOME_DIR/proj"
    printf '%064d\n' 0 | tr 0 a > "$HOME_DIR/handoff_secret"; chmod 600 "$HOME_DIR/handoff_secret"
    printf '%s' "$content" > "$HOME_DIR/proj/.claude/settings.json"
    case "$step" in
      user)
        run_sh "" --uninstall
        check "$label project file, user --uninstall: exit 0"       0  "$RC"
        check "$label project file, user --uninstall: no jq failed" no "$(has "$ERR$OUT" 'jq failed')"
        # lib.sh jails HANDOFF_SECRET_FILE, so the removal itself is skipped;
        # what matters is that no project is counted as still signing.
        check "$label project file, user --uninstall: secret not kept for it" no \
          "$(has "$OUT" 'still sign with')"
        check "$label project file, user --uninstall: reached secret removal" yes \
          "$(has "$OUT" 'handoff secret (HANDOFF_SECRET_FILE override set')"
        ;;
      project)
        run_sh "" --uninstall --scope project --project "$HOME_DIR/proj"
        check "$label project file, project --uninstall: exit 0"       0  "$RC"
        check "$label project file, project --uninstall: no jq failed" no "$(has "$ERR$OUT" 'jq failed')"
        check "$label project file, project --uninstall: registry line gone" no \
          "$(grep -q proj "$HOME_DIR/handoff_projects" 2>/dev/null && echo yes || echo no)"
        ;;
      doctor)
        run_sh "" --doctor
        check "$label project file, doctor: exit 0"       0   "$RC"
        check "$label project file, doctor: no jq failed" no  "$(has "$ERR$OUT" 'jq failed')"
        check "$label project file, doctor: listed stale" yes "$(has "$OUT" 'stale project registry entries')"
        ;;
    esac
  done
  fresh_home
  run_sh ""
  printf '%s' "$content" > "$HOME_DIR/settings.json"
  run_sh "" --doctor
  check "$label user file, doctor: exit nonzero"   yes "$(nz $RC)"
  check "$label user file, doctor: BROKEN line"    yes "$(has "$OUT" "BROKEN  $HOME_DIR/settings.json is empty or not a JSON object")"
  check "$label user file, doctor: no jq failed"   no  "$(has "$ERR$OUT" 'jq failed')"
done

# 18. The doctor's registry scans run in its own shell (registry_collect), so
#     a jq failure reading a registered project makes doctor exit non-zero.
fresh_home
run_sh ""
mkdir -p "$HOME_DIR/proj"
run_sh "" --scope project --project "$HOME_DIR/proj"
run_sh "" --doctor
check "doctor registry healthy: exit 0"          0   "$RC"
# Fail only the read of the project file: the shim matches its path.
FAIL_JQ_MATCH2="$HOME_DIR/proj/.claude/settings.json"
export FAIL_JQ_MATCH2
run_sh 'def wired' --doctor
unset FAIL_JQ_MATCH2
check "doctor registry read fails: WARN"         yes "$(has "$ERR" 'jq failed (exit 5) while checking')"
check "doctor registry read fails: exit nonzero" yes "$(nz $RC)"

# 19. A settings file doctor cannot open is "cannot be read", not "not valid
#     JSON". Skipped as root, where mode 000 is still readable.
fresh_home
run_sh ""
chmod 000 "$HOME_DIR/settings.json"
if [[ -r "$HOME_DIR/settings.json" ]]; then
  chmod 600 "$HOME_DIR/settings.json"
  skip "mode 000 is readable here (running as root)"
else
  run_sh "" --doctor
  chmod 600 "$HOME_DIR/settings.json"
  check "doctor unreadable: BROKEN cannot be read" yes "$(has "$OUT" 'cannot be read (check its permissions)')"
  check "doctor unreadable: not 'not valid JSON'"  no  "$(has "$OUT" 'not valid JSON')"
  check "doctor unreadable: exit nonzero"          yes "$(nz $RC)"
fi

# 19. The usability check itself (settings_usable: the read that tells an
#     empty, non-object or invalid file from a usable one) failing in jq. It
#     used to collapse into "not usable": --uninstall printed `ok ... empty or
#     not a JSON object; nothing to strip` and exited 0 with the hooks still
#     wired, the registry scan read the project as stale (and a user-scope
#     --uninstall deleted the shared secret), --doctor called the file BROKEN.
#     The fragment is the predicate's own text, so the known-good re-run on
#     stdin fails too and the failure is jq's, not the file's.
USABLE='length == 1 and (.[0] | type)'
# 19a. --uninstall stops before editing: settings byte-identical, links kept.
fresh_home
run_sh ""
SNAP="$(snap)"; NB="$(nbin)"
run_sh "$USABLE" --uninstall
check "usable check fails, uninstall: exit nonzero"       yes "$(nz $RC)"
check "usable check fails, uninstall: ERROR on stderr"    yes "$(has "$ERR" 'jq failed (exit 5) while reading')"
check "usable check fails, uninstall: no 'nothing to strip'" no "$(has "$OUT" 'nothing to strip')"
check "usable check fails, uninstall: no 'not valid JSON'" no  "$(has "$OUT$ERR" 'not valid JSON')"
check "usable check fails, uninstall: settings untouched" "$SNAP" "$(snap)"
check "usable check fails, uninstall: bin links kept"     "$NB" "$(nbin)"
run_sh "" --uninstall
check "usable check healthy re-run: exit 0"               0   "$RC"
# 19b. --doctor: a WARN and a non-zero exit, never a BROKEN file.
fresh_home
run_sh ""
run_sh "$USABLE" --doctor
check "usable check fails, doctor: exit nonzero"          yes "$(nz $RC)"
check "usable check fails, doctor: WARN names the exit"   yes "$(has "$OUT" 'WARN    jq failed (exit 5) while reading')"
check "usable check fails, doctor: closing line"          yes "$(has "$ERR" 'doctor: jq failed while reading settings')"
check "usable check fails, doctor: no BROKEN"             no  "$(has "$OUT" 'BROKEN')"
check "usable check fails, doctor: no 'empty or not a JSON object'" no "$(has "$OUT" 'empty or not a JSON object')"
# 19c. Project-scope install: the wiring check after the patch cannot tell,
#      so the project is not registered and the run fails.
fresh_home
mkdir -p "$HOME_DIR/proj"
run_sh "$USABLE" --scope project --project "$HOME_DIR/proj"
check "usable check fails, project install: exit nonzero" yes "$(nz $RC)"
check "usable check fails, project install: NOT registered" yes "$(has "$ERR" 'the project was NOT registered')"
check "usable check fails, project install: no registry line" no "$(grep -q proj "$HOME_DIR/handoff_projects" 2>/dev/null && echo yes || echo no)"
# 19d. User-scope --uninstall whose registry scan hits the failure on the
#      registered project's file (the user file is empty, so its own unpatch
#      never reaches the check): the project would read as stale and the
#      shared secret would go. It must survive and the run must fail.
fresh_home
run_sh ""
mkdir -p "$HOME_DIR/proj"
run_sh "" --scope project --project "$HOME_DIR/proj"
printf '%064d\n' 0 | tr 0 a > "$HOME_DIR/handoff_secret"; chmod 600 "$HOME_DIR/handoff_secret"
SECRET_SUM="$(cksum < "$HOME_DIR/handoff_secret")"
REG_SUM="$(cksum < "$HOME_DIR/handoff_projects")"
: > "$HOME_DIR/settings.json"
run_sh "$USABLE" --uninstall
check "usable check fails in registry scan: exit nonzero" yes "$(nz $RC)"
check "usable check fails in registry scan: secret kept"  "$SECRET_SUM" "$(cksum < "$HOME_DIR/handoff_secret" 2>/dev/null)"
check "usable check fails in registry scan: registry intact" "$REG_SUM" "$(cksum < "$HOME_DIR/handoff_projects" 2>/dev/null)"
check "usable check fails in registry scan: ERROR names file" yes "$(has "$ERR" 'proj/.claude/settings.json from the project registry')"
check "usable check fails in registry scan: WARN names the check" yes "$(has "$ERR" 'while checking whether')"
check "usable check fails in registry scan: no 'remove' secret" no "$(has "$OUT" 'per-machine HMAC secret')"
# 19e. --uninstall on a settings file it cannot read: named as such, never
#      as "not valid JSON", and left alone.
fresh_home
run_sh ""
chmod 000 "$HOME_DIR/settings.json"
if [[ -r "$HOME_DIR/settings.json" ]]; then
  chmod 600 "$HOME_DIR/settings.json"
  skip "mode 000 is readable here (running as root)"
else
  run_sh "" --uninstall
  chmod 600 "$HOME_DIR/settings.json"
  check "uninstall unreadable: ERROR cannot be read"       yes "$(has "$OUT" 'cannot be read (check its permissions)')"
  check "uninstall unreadable: no 'not valid JSON'"        no  "$(has "$OUT$ERR" 'not valid JSON')"
fi

finish
