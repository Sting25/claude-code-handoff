#!/usr/bin/env bash
# Coverage for the ephemeral-source guard + doctor (issue #21):
#   Bug A — installing from a volatile path (a /tmp checkout) must not leave
#           symlinks that dangle on cleanup; it auto-switches to copy mode.
#   Bug B — `install.sh --doctor` detects dangling/missing installed hooks
#           (which otherwise no-op silently) and exits non-zero.
# Also guards the negative: a persistent source still symlinks (no false
# positive), and --link / HANDOFF_FORCE_SYMLINK=1 override the auto-copy.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh — ephemeral-source guard (copy mode) + --doctor"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — install.sh can't auto-patch settings.json"
  finish
  exit
fi

is_symlink() { [[ -L "$1" ]] && echo yes || echo no; }
is_copy()    { [[ -f "$1" && ! -L "$1" ]] && echo yes || echo no; }
has()        { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
SS="handoff_session_start.sh"   # representative installed hook

# --- A. Volatile source (/tmp) -> copy mode + warning -----------------------
src="$(mktemp -d)"   # mktemp -> /tmp/tmp.XXXX (volatile)
cp "$REPO_ROOT/install.sh" "$src/"; cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/"
home="$(mktemp -d)"
out="$(CLAUDE_HOME="$home" bash "$src/install.sh" 2>&1)"; rc=$?
check "volatile: exit 0"                0   "$rc"
check "volatile: warns about volatile"  yes "$(has "$out" "volatile path")"
check "volatile: installed as a copy"   yes "$(is_copy "$home/bin/$SS")"
check "volatile: NOT a symlink"         no  "$(is_symlink "$home/bin/$SS")"
# The copy must survive the source being cleaned up (the whole point).
rm -rf "$src"
check "volatile: copy survives src cleanup" yes "$([[ -e "$home/bin/$SS" ]] && echo yes || echo no)"
check "volatile: settings still patched" present "$(jq -e '.hooks.SessionStart' "$home/settings.json" >/dev/null 2>&1 && echo present || echo absent)"
rm -rf "$home"

# --- B. Volatile source + --link -> symlinks (override) ---------------------
src="$(mktemp -d)"
cp "$REPO_ROOT/install.sh" "$src/"; cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/"
home="$(mktemp -d)"
CLAUDE_HOME="$home" bash "$src/install.sh" --link >/dev/null 2>&1
check "volatile + --link: symlink made" yes "$(is_symlink "$home/bin/$SS")"
rm -rf "$src" "$home"

# --- C. Volatile source + HANDOFF_FORCE_SYMLINK=1 -> symlinks ----------------
src="$(mktemp -d)"
cp "$REPO_ROOT/install.sh" "$src/"; cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/"
home="$(mktemp -d)"
HANDOFF_FORCE_SYMLINK=1 CLAUDE_HOME="$home" bash "$src/install.sh" >/dev/null 2>&1
check "volatile + FORCE_SYMLINK: symlink" yes "$(is_symlink "$home/bin/$SS")"
rm -rf "$src" "$home"

# --- D. Persistent source -> symlinks, no volatile warning (no false-positive)
# A source path that is neither under /tmp nor named like an mktemp dir.
persist="$(mktemp -d "$HOME/.handoff_test_persist.XXXXXX")"
cp "$REPO_ROOT/install.sh" "$persist/"; cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$persist/"
home="$(mktemp -d)"
out="$(CLAUDE_HOME="$home" bash "$persist/install.sh" 2>&1)"
check "persistent: symlink made"        yes "$(is_symlink "$home/bin/$SS")"
check "persistent: no volatile warning" no  "$(has "$out" "volatile path")"
rm -rf "$persist" "$home"

# --- E. --doctor: healthy install -> exit 0; dangling link -> exit 1 ---------
src="$(mktemp -d)"
cp "$REPO_ROOT/install.sh" "$src/"; cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/"
home="$(mktemp -d)"
CLAUDE_HOME="$home" bash "$src/install.sh" --copy >/dev/null 2>&1   # copies all 4 hooks
out="$(CLAUDE_HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; rc=$?
check "doctor healthy: exit 0"          0   "$rc"
check "doctor healthy: all resolve"     yes "$(has "$out" "all hooks resolve")"

# Break one hook: point it at a target that never existed (dangling). The
# install.sh under $src stays in place so --doctor can still run.
rm -f "$home/bin/$SS"
ln -s "/no/such/DELETED_TARGET.sh" "$home/bin/$SS"
out="$(CLAUDE_HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; rc2=$?
check "doctor dangling: nonzero exit"   nonzero "$([[ "$rc2" -ne 0 ]] && echo nonzero || echo zero)"
check "doctor dangling: reports BROKEN" yes "$(has "$out" "BROKEN")"
rm -rf "$src" "$home"

finish
