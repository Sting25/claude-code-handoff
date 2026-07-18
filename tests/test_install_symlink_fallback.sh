#!/usr/bin/env bash
# Coverage for install.sh's symlink->copy fallback (the link() function,
# ~L119-128), previously untested. On platforms that can't make symlinks (Git
# Bash on Windows without Developer Mode), `ln -s` either errors or silently
# copies; the installer must fall back to a real copy, mark COPIED_ANY, and warn
# the user that copies don't auto-update on git pull.
#
# We force the no-symlink platform on this (POSIX) host with a PATH-shimmed `ln`
# that always fails, run the installer fully sandboxed (copied payload + temp
# CLAUDE_HOME), and assert the bin scripts landed as real copies, not symlinks.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh — symlink-unavailable copy fallback"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — install.sh can't auto-patch settings.json"
  finish
  exit
fi

# Sandbox the payload so the install targets a temp copy, never the real checkout.
src="$(mktemp -d)"
cp "$REPO_ROOT/install.sh" "$src/"
cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/"

# An `ln` that always fails — stands in for "this platform can't symlink".
shim="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 1\n' > "$shim/ln"
chmod +x "$shim/ln"

home="$(mktemp -d)"
out="$(PATH="$shim:$PATH" CLAUDE_HOME="$home" bash "$src/install.sh" 2>&1)"; rc=$?

check "exit 0 with ln unavailable" 0 "$rc"

dst="$home/bin/handoff_session_start.sh"
check "target exists"          yes "$([[ -e "$dst" ]] && echo yes || echo no)"
check "target is NOT a symlink" yes "$([[ ! -L "$dst" ]] && echo yes || echo no)"
check "target is a real copy"   yes "$([[ -f "$dst" ]] && cmp -s "$src/bin/handoff_session_start.sh" "$dst" && echo yes || echo no)"
# All bin scripts should have copied, not just one.
copied=0
for f in write_handoff.sh handoff_turn_append.sh handoff_ctx_check.sh \
         handoff_session_start.sh handoff_recover_tail.sh; do
  [[ -f "$home/bin/$f" && ! -L "$home/bin/$f" ]] && copied=$((copied + 1))
done
check "all five bin scripts copied" 5 "$copied"
# The installer must surface the "copies don't auto-update" warning (COPIED_ANY).
check "warns about copy mode" yes "$(case "$out" in (*"COPIED"*|*"copy"*) echo yes ;; (*) echo no ;; esac)"
# settings.json still patched (fallback must not abort the run).
check "settings.json patched" present "$(jq -e '.hooks.SessionStart' "$home/settings.json" >/dev/null 2>&1 && echo present || echo absent)"

rm -rf "$src" "$shim" "$home"
finish
