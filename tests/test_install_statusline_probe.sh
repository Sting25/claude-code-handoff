#!/usr/bin/env bash
# Tests that install.sh tells "a foreign statusLine exists, skip" (jq -e exit 1)
# apart from "jq itself failed" (exit >= 2) in the statusLine probes (#174).
# Before the fix any non-zero probe exit printed `skip statusLine` and exited 0
# with nothing wired. A jq shim fails only the probe under test (matched by
# its filter text) and passes every other call through to the real jq.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh statusLine probe: jq failure vs foreign statusLine"

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
HOMES=()
trap 'rm -rf "$SHIM" "$SRC" ${HOMES[@]+"${HOMES[@]}"}' EXIT

HOME_DIR=""
# run_install <init-settings-json> <fail-match|""> ; sets RC, OUT, ERR, HOME_DIR.
run_install() {
  HOME_DIR="$(mktemp -d)"; HOMES+=("$HOME_DIR")
  printf '%s' "$1" > "$HOME_DIR/settings.json"
  OUT="$(FAIL_JQ_MATCH="$2" PATH="$SHIM:$PATH" CLAUDE_HOME="$HOME_DIR" \
    bash "$SRC/install.sh" 2>"$HOME_DIR/err" </dev/null)"
  RC=$?
  ERR="$(cat "$HOME_DIR/err")"
}
sl() { jq -c '.statusLine // null' "$HOME_DIR/settings.json"; }
has() { [[ "$1" == *"$2"* ]] && echo yes || echo no; }

# 1. probe 1 (absent/null?) fails: install must fail loudly, not skip.
run_install '{}' '(.statusLine? // null) == null'
check "probe1 jq failure: exit nonzero"        yes "$([[ $RC -ne 0 ]] && echo yes || echo no)"
check "probe1 jq failure: no 'skip statusLine'" no  "$(has "$OUT" 'skip    statusLine')"
check "probe1 jq failure: ERROR on stderr"      yes "$(has "$ERR" 'jq failed (exit 5) while probing statusLine')"
check "probe1 jq failure: statusLine not wired" null "$(sl)"

# 2. probe 2 (ours?) fails on a foreign statusLine: same.
FOREIGN='{"statusLine":{"type":"command","command":"echo mine"}}'
run_install "$FOREIGN" "contains(\$m)"
check "probe2 jq failure: exit nonzero"        yes "$([[ $RC -ne 0 ]] && echo yes || echo no)"
check "probe2 jq failure: no 'skip statusLine'" no  "$(has "$OUT" 'skip    statusLine')"
check "probe2 jq failure: ERROR on stderr"      yes "$(has "$ERR" 'jq failed (exit 5) while probing statusLine')"
check "probe2 jq failure: foreign untouched"   '{"type":"command","command":"echo mine"}' "$(sl)"
check "probe2 jq failure: hooks rolled back"   null "$(jq -c '.hooks // null' "$HOME_DIR/settings.json")"
check "probe2 jq failure: backup left behind"  yes "$([[ -n "$(ls "$HOME_DIR"/settings.json.bak* "$HOME_DIR"/*backup* 2>/dev/null)" ]] && echo yes || echo no)"

# 3. genuine foreign statusLine, healthy jq: still a skip, exit 0, untouched.
run_install "$FOREIGN" ""
check "foreign statusLine: exit 0"             0   "$RC"
check "foreign statusLine: prints skip"        yes "$(has "$OUT" 'skip    statusLine')"
check "foreign statusLine: untouched"          '{"type":"command","command":"echo mine"}' "$(sl)"

# 3b. non-string statusLine shapes are foreign too (probe must not error).
for shape in '"x"' '{"command":42}' '[]'; do
  run_install "{\"statusLine\":$shape}" ""
  check "shape $shape: exit 0"        0   "$RC"
  check "shape $shape: prints skip"   yes "$(has "$OUT" 'skip    statusLine')"
  check "shape $shape: untouched"     "$shape" "$(sl)"
  check "shape $shape: hooks wired"   7   "$(jq '[.hooks[]] | length' "$HOME_DIR/settings.json")"
done

# 4. healthy jq, no statusLine: wired.
run_install '{}' ""
check "no statusLine: exit 0"                  0   "$RC"
check "no statusLine: wired"                   yes "$(has "$(sl)" 'statusline')"

finish
