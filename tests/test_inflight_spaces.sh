#!/usr/bin/env bash
# Tests list_inflight_md in write_handoff.sh: untracked/modified .md files under
# the in-flight dirs must be listed even when their paths contain spaces.
# Regression guard for the --porcelain -z fix (plain --porcelain quoted/split
# spaced paths, so the old awk '{print $2}' truncated them and the .md filter
# dropped them silently).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
echo "write_handoff.sh in-flight .md listing (spaced filenames)"

repo="$(mk_repo)"
mkdir -p "$repo/docs"
# A tracked .md (so docs/ isn't a collapsed untracked dir), which we then modify.
printf 'orig\n' > "$repo/docs/tracked spaced.md"
git -C "$repo" add "docs/tracked spaced.md"
git -C "$repo" commit -qm "add tracked md"
printf 'more\n' >> "$repo/docs/tracked spaced.md"          # now modified (spaced)
# Untracked files: normal, spaced, and a non-.md that must be excluded.
printf 'x\n' > "$repo/docs/plain.md"
printf 'x\n' > "$repo/docs/with two spaces.md"
printf 'x\n' > "$repo/docs/notes.txt"

( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 HANDOFF_HISTORY_KEEP=0 bash "$WH" >/dev/null 2>&1 )
hf="$repo/.claude/handoff_current.md"

# Assert against the in-flight BULLET lines specifically (the Working-tree
# snapshot lists everything too, so scope to "- `docs/...`").
listed() { grep -qF -- "- \`docs/$1\`" "$hf" && echo yes || echo no; }

check "modified spaced .md listed"   yes "$(listed 'tracked spaced.md')"
check "untracked plain .md listed"   yes "$(listed 'plain.md')"
check "untracked spaced .md listed"  yes "$(listed 'with two spaces.md')"
check "non-.md excluded"             no  "$(listed 'notes.txt')"

rm -rf "$repo"
finish
