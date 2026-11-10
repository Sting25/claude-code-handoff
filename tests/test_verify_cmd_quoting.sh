#!/usr/bin/env bash
# #167: the "Verify state matches reality" commands are meant to be pasted into
# a shell, so a project path containing spaces, quotes, non-ASCII or a newline
# must be shell-quoted in every emitted line (git, worktree, substrate and
# non-git forms). Each emitted line is also executed to prove it runs, not just
# that it looks quoted.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# Run every command line of the verify block in a subshell. Echo "ok N" when N
# (> 0) lines ran and all exited 0; "fail: <line>" on the first failure; and
# "no command lines" when none matched, so an empty match never passes.
run_block() {
  local doc="$1" line n=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    n=$((n + 1))
    ( eval "$line" ) >/dev/null 2>&1 || { echo "fail: $line"; return; }
  done < <(awk '/^```bash$/{f=1;next} /^```$/{f=0} f' <<<"$doc" | grep -E '^(git -C|ls -la) ')
  if (( n == 0 )); then echo "no command lines"; else echo "ok $n"; fi
}

# Build the expected quoted form by the contract: single quotes, ' -> '\''.
sq() {
  local sqc="'" rep p="$1"
  rep="$sqc"'\'"$sqc$sqc"
  printf "'%s'" "${p//$sqc/$rep}"
}

mkgit() {  # <dir>
  mkdir -p "$1" \
    && git -C "$1" init -q && git -C "$1" config user.email t@t && git -C "$1" config user.name t \
    && git -C "$1" commit -q --allow-empty -m init
}

base="$(mktemp -d)" && base="$(cd "$base" && pwd -P)"
cleanup_on_exit "$base"

echo "verify command quoting: git project, spaces and an apostrophe"
proj="$base/my proj it's"
mkgit "$proj"
( cd "$proj" && env -u CLAUDE_PROJECT_DIR bash "$WH" </dev/null >/dev/null 2>&1 )
doc="$(cat "$proj/.claude/handoff_current.md" 2>/dev/null)"
q="$(sq "$proj")"
check "doc written"                       yes "$([[ -n "$doc" ]] && echo yes || echo no)"
check "path is shell-quoted"              yes "$(has "$doc" "git -C $q status && git -C $q log --oneline -5")"
check "no unquoted spaced path"           no  "$(has "$doc" "git -C $proj status")"
check "emitted command runs"              "ok 1" "$(run_block "$doc")"

echo "verify command quoting: non-ASCII path stays readable"
uni="$base/café, proj"
mkgit "$uni"
( cd "$uni" && env -u CLAUDE_PROJECT_DIR bash "$WH" </dev/null >/dev/null 2>&1 )
doc="$(cat "$uni/.claude/handoff_current.md" 2>/dev/null)"
check "doc written"                       yes "$([[ -n "$doc" ]] && echo yes || echo no)"
check "path appears unescaped in quotes"  yes "$(has "$doc" "git -C '$uni' status && git -C '$uni' log --oneline -5")"
check "no octal escapes"                  no  "$(has "$doc" '\303')"
check "emitted command runs"              "ok 1" "$(run_block "$doc")"

echo "verify command quoting: path with a newline falls back to \$'...'"
nl="$base/line"$'\n'"break"
mkgit "$nl"
( cd "$nl" && env -u CLAUDE_PROJECT_DIR bash "$WH" </dev/null >/dev/null 2>&1 )
doc="$(cat "$nl/.claude/handoff_current.md" 2>/dev/null)"
check "doc written"                       yes "$([[ -n "$doc" ]] && echo yes || echo no)"
check "newline path is \$'...' quoted"    yes "$(has "$doc" "git -C \$'")"
check "emitted command runs"              "ok 1" "$(run_block "$doc")"

echo "verify command quoting: linked worktree (two lines) and substrate line"
mkdir -p "$base/pair dir"
main="$base/pair dir/main repo"
mkgit "$main"
mkgit "$base/pair dir/sub repo"
wt="$base/pair dir/wt tree"
must git -C "$main" worktree add -q "$wt" -b wt-q167
wt="$(cd "$wt" && pwd -P)"
( cd "$wt" && env -u CLAUDE_PROJECT_DIR HANDOFF_ANCHOR=common HANDOFF_SUBSTRATE_NAME="sub repo" bash "$WH" </dev/null >/dev/null 2>&1 )
doc="$(cat "$main/.claude/handoff_current.md" 2>/dev/null)"
qwt="$(sq "$wt")"; qmain="$(sq "$main")"; qsub="$(sq "$base/pair dir/sub repo")"
check "doc landed at main checkout"       yes "$([[ -n "$doc" ]] && echo yes || echo no)"
check "worktree line quoted"              yes "$(has "$doc" "git -C $qwt status && git -C $qwt log --oneline -5")"
check "main line quoted"                  yes "$(has "$doc" "git -C $qmain status && git -C $qmain log --oneline -5")"
check "substrate line quoted"             yes "$(has "$doc" "git -C $qsub log --oneline -5")"
check "all three emitted commands run"    "ok 3" "$(run_block "$doc")"

echo "verify command quoting: non-git project, spaces"
ng="$base/no git dir"
mkdir -p "$ng"
( cd "$ng" && env -u CLAUDE_PROJECT_DIR bash "$WH" </dev/null >/dev/null 2>&1 )
doc="$(cat "$ng/.claude/handoff_current.md" 2>/dev/null)"
check "doc written"                       yes "$([[ -n "$doc" ]] && echo yes || echo no)"
check "ls path is shell-quoted"           yes "$(has "$doc" "ls -la $(sq "$ng/.claude/")")"
check "emitted command runs"              "ok 1" "$(run_block "$doc")"

echo "verify command quoting: run_block fails when nothing matches"
check "empty block is not a pass"         "no command lines" "$(run_block 'no block here')"

finish
