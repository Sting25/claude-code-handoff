#!/usr/bin/env bash
# #139 (H2): the "Verify state matches reality" command must be valid from
# wherever the next session starts. Under HANDOFF_ANCHOR=common the handoff's
# root (repo_root) is the MAIN checkout even when the session ran in a linked
# worktree, so `git -C <repo_root>` verified the wrong checkout. The command
# must name the worktree's own toplevel (and keep the main line as a second one).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

echo "verify command: linked worktree, HANDOFF_ANCHOR=common"
main="$(mk_repo)"
must git -C "$main" worktree add -q "$main.wt" -b wt-verify
wt="$(cd "$main.wt" && pwd -P)"
( cd "$wt" && env -u CLAUDE_PROJECT_DIR HANDOFF_ANCHOR=common bash "$WH" </dev/null >/dev/null 2>&1 )
doc="$(cat "$main/.claude/handoff_current.md" 2>/dev/null)"
check "doc landed at the main checkout"          yes "$([[ -n "$doc" ]] && echo yes || echo no)"
check "verify cmd names the worktree path"       yes "$(has "$doc" "git -C $wt status && git -C $wt log --oneline -5")"
check "verify cmd also keeps the main path"      yes "$(has "$doc" "git -C $main status && git -C $main log --oneline -5")"
first="$(grep -m1 -n 'git -C .* status &&' <<<"$doc")"
check "worktree line comes first"                yes "$(has "$first" "git -C $wt status")"

echo "verify command: linked worktree, default anchor (one line)"
rm -rf "$main/.claude"
( cd "$wt" && env -u CLAUDE_PROJECT_DIR bash "$WH" </dev/null >/dev/null 2>&1 )
doc="$(cat "$wt/.claude/handoff_current.md" 2>/dev/null)"
check "verify cmd names the worktree path"       yes "$(has "$doc" "git -C $wt status && git -C $wt log --oneline -5")"
check "no main-checkout verify line"             no  "$(has "$doc" "git -C $main status")"

git -C "$main" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
rm -rf "$main"

finish
