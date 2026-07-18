#!/usr/bin/env bash
# Hardening coverage for write_handoff.sh (issue #16 LOW/INFO):
#   - the handoff doc is created owner-only (umask 077 + defensive chmod), since
#     it captures verbatim session prose that can include secrets;
#   - a configured-but-missing substrate is now surfaced on stderr instead of
#     being silently skipped (which hid HANDOFF_SUBSTRATE_NAME typos).
# Uses lib.sh's portable file_mode (GNU stat -c / BSD stat -f) for mode checks.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

mk_repo_gitignored() {
  local d; d="$(mk_repo)"
  printf '.claude/\n' > "$d/.gitignore"
  git -C "$d" add .gitignore && git -C "$d" commit -qm "ignore .claude"
  printf '%s\n' "$d"
}

echo "write_handoff.sh — hardening (owner-only doc + substrate surfacing)"

# --- Handoff doc is created 0600 --------------------------------------------
repo="$(mk_repo_gitignored)"
path="$( cd "$repo" && HANDOFF_HISTORY_KEEP=0 bash "$WH" 2>/dev/null )"
mode="$(file_mode "$path")"
check "handoff_current.md mode is 600" 600 "$mode"
rm -rf "$repo"

# --- Defensive chmod tightens a doc left world-readable by an older version --
# Pre-seed a 0644 handoff_current.md, then let write_handoff rotate+rewrite it.
repo="$(mk_repo_gitignored)"
mkdir -p "$repo/.claude"
echo "stale" > "$repo/.claude/handoff_current.md"
chmod 644 "$repo/.claude/handoff_current.md"
( cd "$repo" && HANDOFF_HISTORY_KEEP=0 bash "$WH" >/dev/null 2>&1 )
mode="$(file_mode "$repo/.claude/handoff_current.md")"
check "rewritten doc tightened to 600" 600 "$mode"
rm -rf "$repo"

# --- Substrate configured but missing -> surfaced on stderr, no snapshot -----
repo="$(mk_repo_gitignored)"   # no sibling _shared repo exists
err="$( cd "$repo" && HANDOFF_HISTORY_KEEP=0 HANDOFF_SUBSTRATE_NAME=_shared bash "$WH" 2>&1 >/dev/null )"
doc="$(cat "$repo/.claude/handoff_current.md" 2>/dev/null)"
check "missing substrate -> warned on stderr" yes "$(has "$err" "substrate '_shared' not found")"
check "missing substrate -> no snapshot block" no "$(has "$doc" "## Substrate: _shared")"
rm -rf "$repo"

# --- Positive control: substrate present -> snapshot in, no warning ----------
parent="$(mktemp -d)"; main="$parent/main"; sub="$parent/_shared"
for d in "$main" "$sub"; do
  mkdir -p "$d"; git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  echo seed > "$d/seed.txt"; git -C "$d" add seed.txt; git -C "$d" commit -qm seed
done
printf '.claude/\n' > "$main/.gitignore"; git -C "$main" add .gitignore; git -C "$main" commit -qm gi
err="$( cd "$main" && HANDOFF_HISTORY_KEEP=0 HANDOFF_SUBSTRATE_NAME=_shared bash "$WH" 2>&1 >/dev/null )"
doc="$(cat "$main/.claude/handoff_current.md" 2>/dev/null)"
check "present substrate -> snapshot block" yes "$(has "$doc" "## Substrate: _shared")"
check "present substrate -> no warning"     no  "$(has "$err" "not found")"
rm -rf "$parent"

finish
