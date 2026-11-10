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
if [[ -n "\${FAIL_JQ_MATCH:-}" && "\$*" == *"\$FAIL_JQ_MATCH"* ]]; then exit 5; fi
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
  OUT="$(FAIL_JQ_MATCH="$m" PATH="$SHIM:$PATH" CLAUDE_HOME="$HOME_DIR" \
    bash "$SRC/install.sh" "$@" 2>"$HOME_DIR/err" </dev/null)"
  RC=$?
  ERR="$(cat "$HOME_DIR/err")"
}
fresh_home() { HOME_DIR="$(mktemp -d)"; cleanup_on_exit "$HOME_DIR"; }
has() { [[ "$1" == *"$2"* ]] && echo yes || echo no; }
nz() { [[ $1 -ne 0 ]] && echo yes || echo no; }
snap() { cksum < "$HOME_DIR/settings.json"; }

# A healthy install first, so every later run starts from a fully wired file.
fresh_home
run_sh ""
check "healthy install: exit 0" 0 "$RC"
BASE_HOOKS="$(jq -c '.hooks' "$HOME_DIR/settings.json")"
BASE_PERMS="$(jq -c '.permissions.allow' "$HOME_DIR/settings.json")"
BASE_SUM="$(snap)"

# Failing-probe fragments: hooks `.hooks?`, permissions `index($p)`,
# statusLine `.statusLine.command?`.
# 1. Second install, hook probe fails: must not append a second Stop group.
run_sh '.hooks? | objects'
check "install hook probe: exit nonzero"        yes "$(nz $RC)"
check "install hook probe: ERROR names hook"    yes "$(has "$ERR" 'jq failed (exit 5) while probing hook')"
check "install hook probe: settings identical"  "$BASE_SUM" "$(snap)"
check "install hook probe: hooks not doubled"   "$BASE_HOOKS" "$(jq -c '.hooks' "$HOME_DIR/settings.json")"

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
run_sh '.statusLine.command?' --uninstall
check "uninstall statusLine probe: exit nonzero"     yes "$(nz $RC)"
check "uninstall statusLine probe: no 'not ours'"    no  "$(has "$OUT" 'not ours')"
check "uninstall statusLine probe: ERROR on stderr"  yes "$(has "$ERR" 'jq failed (exit 5) while probing statusLine')"
check "uninstall statusLine probe: settings identical" "$BASE_SUM" "$(snap)"

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
run_sh '.statusLine.command?' --doctor
check "doctor statusLine probe: WARN printed"   yes "$(has "$OUT" 'jq failed (exit 5) while probing statusLine')"
check "doctor statusLine probe: not 'user's own'" no "$(has "$OUT" "user's own")"
check "doctor statusLine probe: settings identical" "$BASE_SUM" "$(snap)"
run_sh "" --doctor
check "doctor healthy: statusLine wired (ours)" yes "$(has "$OUT" 'statusLine wired (ours)')"

# 8. Odd shapes of the probed keys are plain answers, not jq errors: install
#    must not abort on a non-string hook command or a non-object .hooks.
fresh_home
printf '%s' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":42}]}]},"permissions":{"allow":"x"}}' > "$HOME_DIR/settings.json"
run_sh ""
check "odd shapes: no jq-probe abort"           no  "$(has "$ERR" 'while probing')"

finish
