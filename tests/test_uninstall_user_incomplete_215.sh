#!/usr/bin/env bash
# #215 (and #208 item 1): a user-scope --uninstall that could not unpatch
# settings.json (invalid JSON, or jq absent) must keep the bin/ links the
# still-wired hooks call, say it is NOT done, and exit 1, as project scope
# does after #194. A re-run after fixing the file then completes.
# Every run sandboxes HOME and CLAUDE_HOME, so nothing touches ~/.claude.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "user-scope --uninstall incomplete (#215, #208)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed; install.sh refuses to install without it"
  finish
  exit
fi

unset CLAUDE_CONFIG_DIR CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_DESKTOP_APP_VERSION

SRC="$(mktemp -d)"
cleanup_on_exit "$SRC"
must cp "$REPO_ROOT/install.sh" "$SRC/"
must cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$SRC/"

H=""; P=""
fresh_sandbox() {
  H="$(mktemp -d)"; P="$(mktemp -d)"
  cleanup_on_exit "$H" "$P"
  mkdir -p "$H/.claude"
}
inst() {
  OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" "$@" 2>&1 </dev/null)"
  RC=$?
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
nlinks() { find "$H/.claude/bin" -maxdepth 1 \( -type l -o -type f \) 2>/dev/null | wc -l | tr -d ' '; }

# --- A. invalid JSON ----------------------------------------------------------
fresh_sandbox
inst
n0="$(nlinks)"
check "A: install put scripts in bin/" yes "$([[ "$n0" -gt 0 ]] && echo yes || echo no)"
printf '{"hooks":{' > "$H/.claude/settings.json"
inst --uninstall
check "A: exit 1" 1 "$RC"
check "A: says NOT done" yes "$(has "$OUT" "NOT done")"
check "A: bin/ links kept" "$n0" "$(nlinks)"
check "A: settings.json left untouched" '{"hooks":{' "$(cat "$H/.claude/settings.json")"
check "A: no 'done. the repo' line" no "$(has "$OUT" "done. the repo")"
# Re-run after fixing the file completes.
printf '{}' > "$H/.claude/settings.json"
inst --uninstall
check "A: re-run after the fix exits 0" 0 "$RC"
check "A: re-run removes the links" 0 "$(nlinks)"

# --- B. jq absent (#208 item 1) -------------------------------------------------
fresh_sandbox
inst
n0="$(nlinks)"
nojq="$(path_without jq)"; cleanup_on_exit "$nojq"
OUT="$(cd "$P" && PATH="$nojq" HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --uninstall 2>&1 </dev/null)"
RC=$?
check "B: no jq: exit non-zero" yes "$([[ $RC -ne 0 ]] && echo yes || echo no)"
check "B: no jq: says NOT done" yes "$(has "$OUT" "NOT done")"
check "B: no jq: bin/ links kept" "$n0" "$(nlinks)"
check "B: no jq: hooks still wired (nothing half-uninstalled)" 7 \
  "$(jq '.hooks | length' "$H/.claude/settings.json" 2>/dev/null)"

finish
