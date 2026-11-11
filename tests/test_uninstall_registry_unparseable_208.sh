#!/usr/bin/env bash
# #208 (comment): a registered project whose settings file is unparseable is
# UNKNOWN, not stale. User-scope --uninstall must keep the shared HMAC secret
# and the registry and exit 1 (as for a jq failure), not delete the secret
# with exit 0. An empty or non-object file stays a plain stale entry.
# Every run sandboxes HOME and CLAUDE_HOME, so nothing touches ~/.claude.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "user-scope --uninstall, unparseable registered project (#208)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed; install.sh refuses to install without it"
  finish
  exit
fi

unset HANDOFF_SECRET_FILE CLAUDE_CONFIG_DIR CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_DESKTOP_APP_VERSION

SRC="$(mktemp -d)"
cleanup_on_exit "$SRC"
must cp "$REPO_ROOT/install.sh" "$SRC/"
must cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$SRC/"

H=""; P=""
fresh_sandbox() {
  H="$(mktemp -d)"; P="$(mktemp -d)"
  cleanup_on_exit "$H" "$P"
  P="$(cd "$P" && pwd -P)"
  mkdir -p "$H/.claude"
}
inst() {
  OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" "$@" 2>&1 </dev/null)"
  RC=$?
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
mk_secret() { printf '%064d\n' 0 | tr 0 a > "$H/.claude/handoff_secret"; chmod 600 "$H/.claude/handoff_secret"; }

# --- A. unparseable registered file ---------------------------------------------
fresh_sandbox
inst --scope project --project "$P"
inst
mk_secret
sum="$(cksum < "$H/.claude/handoff_secret")"
printf '{"hooks":{' > "$P/.claude/settings.json"
inst --uninstall
check "A: exit 1" 1 "$RC"
check "A: names the project file" yes "$(has "$OUT" "$P/.claude/settings.json")"
check "A: secret kept" "$sum" "$(cksum < "$H/.claude/handoff_secret" 2>/dev/null)"
check "A: registry kept" 1 "$(grep -c . "$H/.claude/handoff_projects" 2>/dev/null)"

# --- B. empty registered file stays a plain stale entry ---------------------------
fresh_sandbox
inst --scope project --project "$P"
inst
mk_secret
: > "$P/.claude/settings.json"
inst --uninstall
check "B: exit 0" 0 "$RC"
check "B: secret removed (stale project)" no "$([[ -e "$H/.claude/handoff_secret" ]] && echo yes || echo no)"

finish
