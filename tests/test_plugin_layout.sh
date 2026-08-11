#!/usr/bin/env bash
# Plugin-packaging layout (v0.14.0): .claude-plugin/plugin.json,
# hooks/hooks.json, and .claude-plugin/marketplace.json.
#
# Two halves:
#   1. Static jq shape assertions against the committed files — name/version
#      fields, version == VERSION, all six hook events present, every hook
#      command references ${CLAUDE_PLUGIN_ROOT}, SessionEnd/PreCompact carry
#      timeout >= 60, PreCompact has no matcher, marketplace.json lists the
#      plugin with source "./".
#   2. A relocation-safety run: copy bin/ into a scratch dir standing in for
#      a plugin install root (Claude Code sets CLAUDE_PLUGIN_ROOT to wherever
#      it checked the plugin out — never this repo's own bin/), then invoke
#      handoff_session_start.sh and write_handoff.sh from there to prove the
#      BASH_SOURCE-based sibling resolution the scripts already rely on
#      (bin/handoff_session_start.sh:64,222; bin/write_handoff.sh:90) also
#      holds when bin/ is not at its normal repo-relative path.
#
# Sandbox rules (past incident): CLAUDE_PROJECT_DIR alone does not sandbox
# the writer — it only affects root RESOLUTION. HOME and CLAUDE_HOME must
# also be repointed (secret-file default path), and every writer call must
# run inside `( cd "$sandbox_project" && ... )` with git rev-parse
# --show-toplevel asserted equal to the sandbox project, or the writer can
# silently read/write against the real repo.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
MARKET_JSON="$REPO_ROOT/.claude-plugin/marketplace.json"

echo "plugin layout — manifest files"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — plugin manifest shape checks require jq"
  finish
  exit
fi

version_file="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"

# --- plugin.json --------------------------------------------------------
check "plugin.json parses"        yes "$(jq -e . "$PLUGIN_JSON" >/dev/null 2>&1 && echo yes || echo no)"
check "plugin.json name"          claude-code-handoff "$(jq -r '.name' "$PLUGIN_JSON")"
check "plugin.json version == VERSION" "$version_file" "$(jq -r '.version' "$PLUGIN_JSON")"
check "plugin.json hooks path"    "./hooks/hooks.json" "$(jq -r '.hooks' "$PLUGIN_JSON")"

# --- hooks.json: all six events present ----------------------------------
check "hooks.json parses" yes "$(jq -e . "$HOOKS_JSON" >/dev/null 2>&1 && echo yes || echo no)"
events="$(jq -r '.hooks | keys | sort | join(",")' "$HOOKS_JSON")"
expected="PostCompact,PreCompact,SessionEnd,SessionStart,Stop,UserPromptSubmit"
check "hooks.json has all six events" "$expected" "$events"

# --- every hook command references ${CLAUDE_PLUGIN_ROOT} ------------------
commands="$(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$HOOKS_JSON")"
# shellcheck disable=SC2016  # ${CLAUDE_PLUGIN_ROOT} is a literal substring to grep for, not meant to expand
missing="$(printf '%s\n' "$commands" | grep -vc '\${CLAUDE_PLUGIN_ROOT}' || true)"
check "every hook command uses \${CLAUDE_PLUGIN_ROOT}" 0 "$missing"

# --- SessionEnd + PreCompact carry timeout >= 60 ---------------------------
se_timeout="$(jq -r '.hooks.SessionEnd[0].hooks[0].timeout' "$HOOKS_JSON")"
pc_timeout="$(jq -r '.hooks.PreCompact[0].hooks[0].timeout' "$HOOKS_JSON")"
check "SessionEnd timeout >= 60" yes "$([[ "$se_timeout" -ge 60 ]] && echo yes || echo no)"
check "PreCompact timeout >= 60" yes "$([[ "$pc_timeout" -ge 60 ]] && echo yes || echo no)"

# --- PreCompact carries no matcher (fires on both auto and manual compaction) --
check "PreCompact entry group has no matcher" no \
  "$(jq -e '.hooks.PreCompact[0] | has("matcher")' "$HOOKS_JSON" >/dev/null 2>&1 && echo yes || echo no)"
check "PreCompact hook itself has no matcher" no \
  "$(jq -e '.hooks.PreCompact[0].hooks[0] | has("matcher")' "$HOOKS_JSON" >/dev/null 2>&1 && echo yes || echo no)"

# --- marketplace.json -------------------------------------------------------
check "marketplace.json parses" yes "$(jq -e . "$MARKET_JSON" >/dev/null 2>&1 && echo yes || echo no)"
check "marketplace.json has plugin entry" claude-code-handoff \
  "$(jq -r '.plugins[] | select(.name == "claude-code-handoff") | .name' "$MARKET_JSON")"
check "marketplace.json plugin source is ./" "./" \
  "$(jq -r '.plugins[] | select(.name == "claude-code-handoff") | .source' "$MARKET_JSON")"

echo "plugin layout — relocation safety (simulated plugin root)"

# A scratch dir standing in for wherever Claude Code checks the plugin out —
# deliberately NOT $REPO_ROOT/bin, so a script that (re)hardcoded a
# repo-relative path instead of resolving siblings via BASH_SOURCE would fail
# here even though it passes every other test.
plugin_root="$(mktemp -d)" || { echo "mktemp -d failed"; exit 1; }
must cp -r "$REPO_ROOT/bin" "$plugin_root/bin"
cleanup_on_exit "$plugin_root"

sandbox_home="$(mktemp -d)" || { echo "mktemp -d failed"; exit 1; }
cleanup_on_exit "$sandbox_home"
sandbox_claude_home="$sandbox_home/.claude"
must mkdir -p "$sandbox_claude_home"

sandbox_project="$(mk_repo)"
cleanup_on_exit "$sandbox_project"

# Confirm the sandbox project really is its own git toplevel from inside the
# sandboxed env — CLAUDE_PROJECT_DIR alone does not prove this; the writer
# resolves root via git, so this is what actually gates isolation.
toplevel="$(cd "$sandbox_project" \
  && HOME="$sandbox_home" CLAUDE_HOME="$sandbox_claude_home" \
     git rev-parse --show-toplevel)"
check "sandbox project is its own git toplevel" "$sandbox_project" "$toplevel"

# SessionStart hook, run from the relocated plugin root, against the
# sandboxed project/home.
ss_rc=0
( cd "$sandbox_project" \
  && HOME="$sandbox_home" CLAUDE_HOME="$sandbox_claude_home" \
     CLAUDE_PROJECT_DIR="$sandbox_project" \
     bash "$plugin_root/bin/handoff_session_start.sh" </dev/null >/dev/null 2>&1 ) || ss_rc=$?
check "session_start from relocated plugin root -> exit 0" 0 "$ss_rc"

# Writer hook (SessionEnd command shape), same relocation + sandbox.
wh_rc=0
( cd "$sandbox_project" \
  && HOME="$sandbox_home" CLAUDE_HOME="$sandbox_claude_home" \
     CLAUDE_PROJECT_DIR="$sandbox_project" \
     bash "$plugin_root/bin/write_handoff.sh" --if-curated >/dev/null 2>&1 ) || wh_rc=$?
check "writer from relocated plugin root -> exit 0" 0 "$wh_rc"
check "handoff doc written under sandbox project (not real repo)" yes \
  "$([[ -f "$sandbox_project/.claude/handoff_current.md" ]] && echo yes || echo no)"
check "real repo's own .claude/ untouched by relocated writer" no \
  "$([[ -f "$REPO_ROOT/.claude/handoff_current.md" ]] && echo yes || echo no)"

finish
