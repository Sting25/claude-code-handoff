#!/usr/bin/env bash
# install.sh --doctor / --uninstall run from a volatile path install nothing, so
# they print no "volatile path ... COPY mode" warning; a plain install still
# does (#205 item 2). Also pins the other two items of #205 as already fixed:
# the user-scope doctor leaks no "Broken pipe" with several registered projects
# (item 1), and a jq failure in the doctor's registry scan makes it exit
# non-zero (item 3, shim fails the wired-hooks read of one project file).
# Sandboxed HOME and CLAUDE_HOME. The source copy lives under mktemp, which is
# a volatile path on every platform the suite runs on.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh --doctor: no volatile-path warning, no stderr noise (#205)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed; install.sh refuses to install without it"
  finish
  exit
fi

unset CLAUDE_CONFIG_DIR HANDOFF_FORCE_SYMLINK
REAL_JQ="$(command -v jq)"
SHIM="$(mktemp -d)"
cat > "$SHIM/jq" <<SH
#!/usr/bin/env bash
if [[ -n "\${FAIL_JQ_MATCH:-}" && "\$*" == *"\$FAIL_JQ_MATCH"* && "\$*" == *"\${FAIL_JQ_MATCH2:-}"* ]]; then exit 5; fi
exec "$REAL_JQ" "\$@"
SH
chmod +x "$SHIM/jq"
SRC="$(mktemp -d)"; H="$(mktemp -d)"
cleanup_on_exit "$SHIM" "$SRC" "$H"
must cp "$REPO_ROOT/install.sh" "$SRC/"
must cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$SRC/"
mkdir -p "$H/.claude"
run() {
  OUT="$(cd "$H" && PATH="$SHIM:$PATH" HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" "$@" 2>"$H/err" </dev/null)"
  RC=$?
  ERR="$(cat "$H/err")"
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# Install four project-scope wirings (registers them), user file stays unwired.
PROJS=()
for i in 1 2 3 4; do
  p="$(mktemp -d)"; cleanup_on_exit "$p"; p="$(cd "$p" && pwd -P)"; PROJS+=("$p")
  run --scope project --project "$p"
done
check "install from a volatile path still warns" yes "$(has "$ERR" "installing from a volatile path")"

run --doctor
check "doctor: exit 0"                           0   "$RC"
check "doctor: no volatile-path warning"         no  "$(has "$ERR" "volatile path")"
check "doctor: no COPY mode warning"             no  "$(has "$ERR$OUT" "COPY mode")"
check "doctor: no Broken pipe on stderr"         no  "$(has "$ERR" "Broken pipe")"

run --doctor --scope project --project "${PROJS[0]}"
check "project doctor: no volatile-path warning" no  "$(has "$ERR" "volatile path")"

run --uninstall --scope project --project "${PROJS[0]}"
check "project uninstall: no volatile warning"   no  "$(has "$ERR" "volatile path")"

# Item 3: a jq failure reading one registered project makes the doctor fail.
FAIL_JQ_MATCH="def wired" FAIL_JQ_MATCH2="${PROJS[1]}/.claude/settings.json" run --doctor
check "doctor registry jq failure: WARN"         yes "$(has "$ERR" "jq failed (exit 5)")"
check "doctor registry jq failure: exit non-zero" 1  "$RC"

finish
