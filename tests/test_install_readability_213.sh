#!/usr/bin/env bash
# Settings readability misreports (#213):
#   1. a settings file under a directory the process cannot search is
#      "unknown" (WARN, sh_jq_failed, doctor non-zero), never "does not exist";
#   2. the install-time ensure_settings_json names the real cause: unreadable,
#      jq failure, not an object (null root), or not valid JSON.
# Every run sandboxes HOME and CLAUDE_HOME. Permission cases are skipped as
# root, where mode 000 stays readable.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh settings readability (#213)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed; install.sh refuses to install without it"
  finish
  exit
fi

unset CLAUDE_CONFIG_DIR
REAL_JQ="$(command -v jq)"
SHIM="$(mktemp -d)"
cat > "$SHIM/jq" <<SH
#!/usr/bin/env bash
if [[ -n "\${FAIL_JQ_MATCH:-}" && "\$*" == *"\$FAIL_JQ_MATCH"* ]]; then exit 5; fi
exec "$REAL_JQ" "\$@"
SH
chmod +x "$SHIM/jq"

SRC="$(mktemp -d)"
cleanup_on_exit "$SHIM" "$SRC"
must cp "$REPO_ROOT/install.sh" "$SRC/"
must cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$SRC/"

H=""; P=""
fresh_sandbox() {
  H="$(mktemp -d)"; P="$(mktemp -d)"
  cleanup_on_exit "$H" "$P"
  P="$(cd "$P" && pwd -P)"
  mkdir -p "$H/.claude" "$P/.claude"
}
inst() {
  OUT="$(cd "$P" && FAIL_JQ_MATCH="${FJ:-}" PATH="$SHIM:$PATH" HOME="$H" CLAUDE_HOME="$H/.claude" \
    bash "$SRC/install.sh" "$@" 2>&1 </dev/null)"
  RC=$?
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
nz() { [[ $1 -ne 0 ]] && echo yes || echo no; }
S() { echo "$P/.claude/settings.json"; }

# A. null root: valid JSON, not an object. Named as such, not "not valid JSON".
fresh_sandbox
echo null > "$(S)"
inst --scope project --project "$P"
check "A: null root exits 1"               1   "$RC"
check "A: names not a JSON object"         yes "$(has "$OUT" "not a JSON object (got: null)")"
check "A: not labelled 'not valid JSON'"   no  "$(has "$OUT" "is not valid JSON")"
check "A: file untouched"                  null "$(cat "$(S)")"

# B. genuinely invalid JSON keeps its label.
fresh_sandbox
echo '{ nope' > "$(S)"
inst --scope project --project "$P"
check "B: invalid JSON exits 1"            1   "$RC"
check "B: says not valid JSON"             yes "$(has "$OUT" "is not valid JSON")"

# C. jq itself failing is a jq failure, not "not valid JSON".
fresh_sandbox
echo '{}' > "$(S)"
FJ='try (fromjson' inst --scope project --project "$P"
check "C: jq failure exits 1"              1   "$RC"
check "C: names the jq failure"            yes "$(has "$OUT" "jq failed (exit 5)")"
check "C: not labelled 'not valid JSON'"   no  "$(has "$OUT" "is not valid JSON")"
check "C: file untouched"                  '{}' "$(cat "$(S)")"

if [[ -n "$(find "$SRC" -maxdepth 0 -user root 2>/dev/null)" ]] || [[ "$(id -u)" == 0 ]]; then
  skip "running as root: mode 000 is still readable, permission cases skipped"
  finish
  exit
fi

# D. unreadable settings file on the install path.
fresh_sandbox
echo '{}' > "$(S)"; chmod 000 "$(S)"
inst --scope project --project "$P"
chmod 600 "$(S)"
check "D: unreadable exits 1"              1   "$RC"
check "D: says cannot be read"             yes "$(has "$OUT" "cannot be read (check its permissions)")"
check "D: not labelled 'not valid JSON'"   no  "$(has "$OUT" "not valid JSON")"
check "D: file untouched"                  '{}' "$(cat "$(S)")"

# E. settings file under a .claude/ the process cannot search: unknown, not
#    "does not exist". The project doctor must say so and exit non-zero.
fresh_sandbox
inst --scope project --project "$P"
chmod 000 "$P/.claude"
inst --doctor --scope project --project "$P"
chmod 755 "$P/.claude"
check "E: doctor exits non-zero"           yes "$(nz $RC)"
check "E: doctor says cannot be read"      yes "$(has "$OUT" "cannot be read (check its permissions)")"
check "E: not called 'does not exist'"     no  "$(has "$OUT" "settings.json does not exist")"

finish
