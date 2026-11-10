#!/usr/bin/env bash
# #171 migration check: a plugin install of this tool left behind after the
# move to install.sh runs its own hook commands (under the plugin root) next
# to these scripts. Those commands differ from ours, so Claude Code's
# identical-handler dedupe does not apply and every hook runs twice. The
# installer's NOTE and --doctor's WARN must name it with the finishing
# commands, and stay silent on a clean machine.
#   A. clean CLAUDE_CONFIG_DIR: neither NOTE nor WARN
#   B. registry entry (project scope) + cache dir: NOTE and WARN, scope named
#   C. cache dir only, no registry file: fires, generic <project|user> scope
#   D. cache dir left over but the registry no longer lists it: silent
#   E. CLAUDE_CONFIG_DIR unset: falls back to CLAUDE_HOME
# Every run sandboxes HOME, CLAUDE_HOME and CLAUDE_CONFIG_DIR.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh: leftover plugin install detection (#171)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed; install.sh refuses to install without it"
  finish
  exit
fi

SRC="$(mktemp -d)"
cleanup_on_exit "$SRC"
must cp "$REPO_ROOT/install.sh" "$SRC/"
must cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$SRC/"

MSG="A plugin install of this tool is still present at"
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

H=""; P=""; C=""
fresh() {
  H="$(mktemp -d)"; P="$(mktemp -d)"; C="$(mktemp -d)"
  cleanup_on_exit "$H" "$P" "$C"
  mkdir -p "$H/.claude"
}
# run <args...>: installer in the sandbox with CLAUDE_CONFIG_DIR=$C.
run() {
  OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" CLAUDE_CONFIG_DIR="$C" \
          bash "$SRC/install.sh" "$@" 2>&1)"
  RC=$?
}
mk_cache() {  # <config dir>
  must mkdir -p "$1/plugins/cache/claude-code-handoff/claude-code-handoff/0.19.0/bin"
}
mk_registry() {  # <config dir> <scope>
  must mkdir -p "$1/plugins"
  printf '{"version":2,"plugins":{"claude-code-handoff@claude-code-handoff":[{"scope":"%s","installPath":"x","version":"0.19.0"}]}}\n' \
    "$2" > "$1/plugins/installed_plugins.json"
}

# --- A. clean -------------------------------------------------------------------
fresh
run --copy --scope project --project "$P"
check "A clean: install exit 0" 0 "$RC"
check "A clean: no NOTE" no "$(has "$OUT" "$MSG")"
run --doctor --scope project --project "$P"
check "A clean: doctor exit 0" 0 "$RC"
check "A clean: no WARN" no "$(has "$OUT" "$MSG")"

# --- B. registry + cache ---------------------------------------------------------
fresh
mk_cache "$C"; mk_registry "$C" project
run --copy --scope project --project "$P"
check "B install: exit 0 (advisory)" 0 "$RC"
check "B install: NOTE fires" yes "$(has "$OUT" "NOTE:   $MSG $C/plugins/cache/claude-code-handoff/claude-code-handoff;")"
check "B install: names project scope" yes "$(has "$OUT" "--scope project'")"
check "B install: marketplace step" yes "$(has "$OUT" "then 'claude plugin marketplace remove claude-code-handoff'")"
run --doctor --scope project --project "$P"
check "B doctor: exit 0 (advisory)" 0 "$RC"
check "B doctor: WARN fires" yes "$(has "$OUT" "  WARN  $MSG")"
check "B doctor: names project scope" yes "$(has "$OUT" "--scope project'")"

# --- C. cache only, no registry --------------------------------------------------
fresh
mk_cache "$C"
run --doctor
check "C cache only: WARN fires" yes "$(has "$OUT" "  WARN  $MSG")"
check "C cache only: generic scope" yes "$(has "$OUT" "--scope <project|user>'")"

# --- D. cache left over, registry without the entry ------------------------------
fresh
mk_cache "$C"
must mkdir -p "$C/plugins"
printf '{"version":2,"plugins":{}}\n' > "$C/plugins/installed_plugins.json"
run --doctor
check "D uninstalled (stale cache): no WARN" no "$(has "$OUT" "$MSG")"

# --- E. CLAUDE_CONFIG_DIR unset -> CLAUDE_HOME -----------------------------------
fresh
mk_registry "$H/.claude" user
OUT="$(cd "$P" && env -u CLAUDE_CONFIG_DIR HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --doctor 2>&1)"
check "E fallback to CLAUDE_HOME: WARN fires" yes "$(has "$OUT" "  WARN  $MSG $H/.claude/plugins/installed_plugins.json;")"
check "E fallback: names user scope" yes "$(has "$OUT" "--scope user'")"

finish
