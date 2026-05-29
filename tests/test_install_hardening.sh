#!/usr/bin/env bash
# Hardening coverage for install.sh (issue #16 LOW/INFO):
#   - settings.json is created/patched owner-only (umask 077), since it can hold
#     env tokens;
#   - $CLAUDE_HOME is validated: empty/root/relative is refused; a path outside
#     $HOME is allowed (tests + shared setups use one) but warned about.
# Uses GNU `stat -c %a` for the mode check.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh — hardening (settings.json perms + CLAUDE_HOME validation)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — install.sh can't auto-patch settings.json"
  finish
  exit
fi

# Sandbox the payload once; reuse for each run by pointing CLAUDE_HOME elsewhere.
src="$(mktemp -d)"
cp "$REPO_ROOT/install.sh" "$src/"
cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/"

# --- settings.json created owner-only (0600) --------------------------------
home="$(mktemp -d)"
CLAUDE_HOME="$home" bash "$src/install.sh" >/dev/null 2>&1; rc=$?
check "install: exit 0"                 0   "$rc"
check "settings.json mode is 600"       600 "$(stat -c %a "$home/settings.json" 2>/dev/null)"
rm -rf "$home"

# NOTE: an *empty* CLAUDE_HOME can't be tested via the env var — `${CLAUDE_HOME
# :-default}` collapses "" to the default $HOME/.claude, so it never reaches the
# guard (and testing it would dangerously target the real home). The ""|"/" case
# arm stays as cheap defense; only the reachable refusals are asserted below.

# --- CLAUDE_HOME='/' (root) -> refused, before any file op -------------------
out="$(CLAUDE_HOME="/" bash "$src/install.sh" 2>&1)"; rc=$?
check "root CLAUDE_HOME -> exit 2"      2   "$rc"
check "root CLAUDE_HOME -> error msg"   yes "$(case "$out" in *"empty or root"*) echo yes ;; *) echo no ;; esac)"

# --- CLAUDE_HOME relative -> refused -----------------------------------------
out="$(CLAUDE_HOME="relative/dir" bash "$src/install.sh" 2>&1)"; rc=$?
check "relative CLAUDE_HOME -> exit 2"  2   "$rc"
check "relative -> 'not an absolute' msg" yes "$(case "$out" in *"not an absolute path"*) echo yes ;; *) echo no ;; esac)"

# --- CLAUDE_HOME outside $HOME -> warns but proceeds -------------------------
# A temp dir under /tmp is (almost always) outside $HOME, so this exercises the
# warn-not-refuse branch. The install must still succeed and patch settings.
home="$(mktemp -d)"   # outside $HOME
out="$(HOME="$(mktemp -d)" CLAUDE_HOME="$home" bash "$src/install.sh" 2>&1)"; rc=$?
check "outside-HOME -> exit 0 (proceeds)" 0   "$rc"
check "outside-HOME -> warns on stderr"   yes "$(case "$out" in *"outside \$HOME"*) echo yes ;; *) echo no ;; esac)"
check "outside-HOME -> settings patched"  present "$(jq -e '.hooks.SessionStart' "$home/settings.json" >/dev/null 2>&1 && echo present || echo absent)"
rm -rf "$home"

rm -rf "$src"
finish
