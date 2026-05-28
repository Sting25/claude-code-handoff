#!/usr/bin/env bash
# Regression guard for the install.sh chmod fix: a failing `chmod +x` on the
# source scripts (e.g. a non-owner running the installer) must NOT abort the
# install before settings.json is patched.
#
# We can't chown files to another user without root, so we simulate the failure
# with a PATH-shimmed `chmod` that always exits 1, run the installer fully
# sandboxed (copied payload + temp CLAUDE_HOME), and assert it still wired the
# hooks into settings.json.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh (chmod failure is non-fatal)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — install.sh can't auto-patch settings.json"
  finish
  exit
fi

# Sandbox the payload so repo_root (and the chmod target) is a temp copy, never
# the real checkout.
src="$(mktemp -d)"
cp "$REPO_ROOT/install.sh" "$src/"
cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/"

# A chmod that always fails — stands in for "user doesn't own these files".
shim="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 1\n' > "$shim/chmod"
chmod +x "$shim/chmod"   # real chmod, before the shim joins PATH

home="$(mktemp -d)"
PATH="$shim:$PATH" CLAUDE_HOME="$home" bash "$src/install.sh" >/dev/null 2>&1
rc=$?

check "exit 0 despite failing chmod" 0 "$rc"

if jq -e '.hooks.SessionStart' "$home/settings.json" >/dev/null 2>&1; then
  hooks=present
else
  hooks=absent
fi
check "settings.json patched past the chmod" present "$hooks"

rm -rf "$src" "$shim" "$home"
finish
