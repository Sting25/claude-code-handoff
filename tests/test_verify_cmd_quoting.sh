#!/usr/bin/env bash
# #167: the "Verify state matches reality" commands are meant to be pasted into
# a shell, so a project path containing spaces (or a quote) must be shell-quoted
# in every emitted line (git and non-git branches). Each emitted line is also
# executed to prove it runs, not just that it looks quoted.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"

# Run every command line of the verify block in a subshell; echo "ok" if all exit 0.
run_block() {
  local doc="$1" line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ( eval "$line" ) >/dev/null 2>&1 || { echo "fail: $line"; return; }
  done < <(awk '/^```bash$/{f=1;next} /^```$/{f=0} f' <<<"$doc" | grep -E '^(git -C|ls -la) ')
  echo ok
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

echo "verify command quoting: git project, path with spaces and a quote"
base="$(mktemp -d)" && base="$(cd "$base" && pwd -P)"
cleanup_on_exit "$base"
proj="$base/my proj it's"
mkdir -p "$proj"
git -C "$proj" init -q && git -C "$proj" config user.email t@t && git -C "$proj" config user.name t
git -C "$proj" commit -q --allow-empty -m init
( cd "$proj" && env -u CLAUDE_PROJECT_DIR bash "$WH" </dev/null >/dev/null 2>&1 )
doc="$(cat "$proj/.claude/handoff_current.md" 2>/dev/null)"
q="$(printf '%q' "$proj")"
check "doc written"                       yes "$([[ -n "$doc" ]] && echo yes || echo no)"
check "path is shell-quoted"              yes "$(has "$doc" "git -C $q status && git -C $q log --oneline -5")"
check "no unquoted spaced path"           no  "$(has "$doc" "git -C $proj status")"
check "emitted command runs"              ok  "$(run_block "$doc")"

echo "verify command quoting: non-git project, path with spaces"
ng="$base/no git dir"
mkdir -p "$ng"
( cd "$ng" && env -u CLAUDE_PROJECT_DIR bash "$WH" </dev/null >/dev/null 2>&1 )
doc="$(cat "$ng/.claude/handoff_current.md" 2>/dev/null)"
q="$(printf '%q' "$ng/.claude/")"
check "doc written"                       yes "$([[ -n "$doc" ]] && echo yes || echo no)"
check "ls path is shell-quoted"           yes "$(has "$doc" "ls -la $q")"
check "emitted command runs"              ok  "$(run_block "$doc")"

finish
