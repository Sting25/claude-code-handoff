#!/usr/bin/env bash
# Git-optional behavior: the hooks must work in a project NOT under git, anchored
# on CLAUDE_PROJECT_DIR (or cwd) instead of the git worktree top. Existing tests
# pin the in-git behavior; this file pins the off-git path end to end across all
# five scripts so a future change can't silently re-break it.
#
# Determinism: every invocation runs with `env -u CLAUDE_PROJECT_DIR` and an
# explicit cwd, so $PWD is the anchor regardless of the outer environment.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
TA="$REPO_ROOT/bin/handoff_turn_append.sh"
CC="$REPO_ROOT/bin/handoff_ctx_check.sh"
RT="$REPO_ROOT/bin/handoff_recover_tail.sh"
SS="$REPO_ROOT/bin/handoff_session_start.sh"
command -v jq >/dev/null 2>&1 || { echo "git-optional"; skip "jq missing"; finish; exit; }

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
# A throwaway NON-git dir (deliberately not mk_repo).
mk_nogit() { mktemp -d; }

echo "git-optional — hooks work off-git, anchored on cwd/CLAUDE_PROJECT_DIR"

# --- write_handoff.sh: writes a handoff with a non-git snapshot note ---------
d="$(mk_nogit)"
rc=0
out="$( cd "$d" && env -u CLAUDE_PROJECT_DIR bash "$WH" 2>/dev/null )" || rc=$?
doc="$(cat "$d/.claude/handoff_current.md" 2>/dev/null)"
check "write_handoff off-git -> exit 0"        0   "$rc"
check "write_handoff off-git -> file written"  yes "$([[ -f "$d/.claude/handoff_current.md" ]] && echo yes || echo no)"
check "write_handoff off-git -> not-a-git note" yes "$(has "$doc" "Not a git repository")"
check "write_handoff off-git -> ls verify"     yes "$(has "$doc" "ls -la")"
check "write_handoff off-git -> no .gitignore" no  "$([[ -f "$d/.gitignore" ]] && echo yes || echo no)"
rm -rf "$d"

# --- CLAUDE_PROJECT_DIR anchor (cwd elsewhere) ------------------------------
# When CLAUDE_PROJECT_DIR is set to a non-git dir but cwd is somewhere else,
# the handoff must land under CLAUDE_PROJECT_DIR, mirroring session_start.
d="$(mk_nogit)"
( cd /tmp && CLAUDE_PROJECT_DIR="$d" bash "$WH" >/dev/null 2>&1 )
check "write_handoff anchors on CLAUDE_PROJECT_DIR" yes \
  "$([[ -f "$d/.claude/handoff_current.md" ]] && echo yes || echo no)"
rm -rf "$d"

# --- turn_append.sh: dumps off-git, skips .gitignore bootstrap --------------
d="$(mk_nogit)"; tx="$d/tx.jsonl"
printf '{"type":"user","message":{"content":"off-git DUMPMARK"}}\n' > "$tx"
( cd "$d" && printf '{"session_id":"NG","transcript_path":"%s"}' "$tx" \
    | env -u CLAUDE_PROJECT_DIR bash "$TA" >/dev/null 2>&1 )
dump="$d/.claude/handoff_backups/handoff_raw_NG.md"
check "turn_append off-git -> dump written"   yes "$([[ -f "$dump" ]] && echo yes || echo no)"
check "turn_append off-git -> has content"    yes "$(has "$(cat "$dump" 2>/dev/null)" "DUMPMARK")"
check "turn_append off-git -> no .gitignore"  no  "$([[ -f "$d/.gitignore" ]] && echo yes || echo no)"
rm -rf "$d"

# --- ctx_check.sh: flags off-git --------------------------------------------
d="$(mk_nogit)"; bd="$d/.claude/handoff_backups"; mkdir -p "$bd"
printf '4000000' > "$bd/.ctx_NG"   # 4M/4 = 1M est tokens, over any threshold
out="$( cd "$d" && env -u CLAUDE_PROJECT_DIR HANDOFF_CTX_WINDOW_TOKENS=1000 \
        bash "$CC" <<<'{"session_id":"NG"}' 2>/dev/null )"
check "ctx_check off-git -> fires" yes "$(has "$out" "<system-reminder>")"
rm -rf "$d"

# --- recover_tail.sh: cwd-anchored backup dir off-git -----------------------
# cursor at 1, transcript has 2 lines -> line 2 is the un-captured tail.
d="$(mk_nogit)"; bd="$d/.claude/handoff_backups"; mkdir -p "$bd"
tx="$d/sess.jsonl"
printf '{"type":"user","message":{"content":"captured"}}\n'         > "$tx"
printf '{"type":"user","message":{"content":"TAILMARK off-git"}}\n' >> "$tx"
echo 1 > "$bd/.handoff_raw_NG.cursor"
out="$( cd "$d" && env -u CLAUDE_PROJECT_DIR \
        HANDOFF_RECOVER_TRANSCRIPT="$tx" bash "$RT" NG 2>/dev/null )"
check "recover_tail off-git -> recovers tail" yes "$(has "$out" "TAILMARK off-git")"
rm -rf "$d"

# --- session_start.sh: loads a handoff from a non-git project ---------------
d="$(mk_nogit)"; mkdir -p "$d/.claude"
printf '## Notes from this session\n\nSOMEMARK off-git notes\n' > "$d/.claude/handoff_current.md"
out="$( cd "$d" && CLAUDE_PROJECT_DIR="$d" bash "$SS" 2>/dev/null )"
check "session_start off-git -> loads handoff" yes "$(has "$out" "SOMEMARK off-git notes")"
rm -rf "$d"

finish
