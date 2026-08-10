#!/usr/bin/env bash
# Root-resolution coverage (handoff_resolve_root + its adoption): every script
# must resolve the SAME project root from the same inputs, with the precedence
# CLAUDE_PROJECT_DIR -> hook-payload cwd -> $PWD, anchored on that dir's git
# toplevel. Pins the core asymmetry regression (writers anchored on process
# cwd while the SessionStart loader anchored on CLAUDE_PROJECT_DIR — the
# handoff was written where the loader never looked), the worktree opt-in,
# the inside-.git rescue, and the new session_start visibility lines
# (recorded-root mismatch, predates-git, miss-with-evidence).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
SS="$REPO_ROOT/bin/handoff_session_start.sh"

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

echo "root resolution — CLAUDE_PROJECT_DIR beats a git-repo cwd (THE core regression)"

# cwd inside git repo B, CLAUDE_PROJECT_DIR = repo A: the handoff must land
# under A (where the SessionStart loader will look), never under B. Before the
# shared resolver, write_handoff's bare `git rev-parse --show-toplevel` won on
# cwd and put the doc under B — invisible to the loader. Hook-style: payload
# on stdin, carrying B as its cwd, which must ALSO lose to CLAUDE_PROJECT_DIR.
A="$(mk_repo)"; B="$(mk_repo)"
rc=0
( cd "$B" \
  && printf '{"reason":"other","cwd":"%s"}' "$B" \
     | CLAUDE_PROJECT_DIR="$A" bash "$WH" >/dev/null 2>&1 ) || rc=$?
check "write_handoff exits 0"                     0   "$rc"
check "doc lands under A (project dir)"           yes "$([[ -f "$A/.claude/handoff_current.md" ]] && echo yes || echo no)"
check "doc does NOT land under B (cwd repo)"      no  "$([[ -f "$B/.claude/handoff_current.md" ]] && echo yes || echo no)"
check "doc records A as its root"                 yes "$(has "$(cat "$A/.claude/handoff_current.md" 2>/dev/null)" "HANDOFF_ROOT: $A in_git=1")"
# The loader, given the same inputs, reads the same doc.
out="$( cd "$B" && CLAUDE_PROJECT_DIR="$A" bash "$SS" </dev/null 2>/dev/null )"
check "session_start (same inputs) loads A's doc" yes "$(has "$out" "HANDOFF_ROOT: $A")"
rm -rf "$A" "$B"

echo "root resolution — linked worktrees"

# Default: each linked worktree is its own root (files stay where existing
# users expect them). HANDOFF_ANCHOR=common: the main repo root is the shared
# anchor, so handoffs survive `git worktree remove`.
main="$(mk_repo)"
must git -C "$main" worktree add -q "$main.wt" -b wt-test
wt="$main.wt"
( cd "$wt" && env -u CLAUDE_PROJECT_DIR bash "$WH" </dev/null >/dev/null 2>&1 )
check "default: doc lands in the worktree"        yes "$([[ -f "$wt/.claude/handoff_current.md" ]] && echo yes || echo no)"
check "default: main repo untouched"              no  "$([[ -f "$main/.claude/handoff_current.md" ]] && echo yes || echo no)"
( cd "$wt" && env -u CLAUDE_PROJECT_DIR HANDOFF_ANCHOR=common bash "$WH" </dev/null >/dev/null 2>&1 )
check "HANDOFF_ANCHOR=common: doc lands at main"  yes "$([[ -f "$main/.claude/handoff_current.md" ]] && echo yes || echo no)"
git -C "$main" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
rm -rf "$main"

echo "root resolution — cwd inside .git/"

# Anchored inside the .git dir itself, --show-toplevel fails; the rescue must
# resolve the enclosing repo, never .git/.claude.
r="$(mk_repo)"
( cd "$r/.git" && env -u CLAUDE_PROJECT_DIR bash "$WH" </dev/null >/dev/null 2>&1 )
check "doc lands at the repo root"                yes "$([[ -f "$r/.claude/handoff_current.md" ]] && echo yes || echo no)"
check "no .git/.claude created"                   no  "$([[ -e "$r/.git/.claude" ]] && echo yes || echo no)"
rm -rf "$r"

echo "session_start — non-git -> git flip warning"

# A doc written pre-`git init` records in_git=0; once the dir becomes a git
# repo the loader must say so instead of silently loading a stale snapshot.
d="$(mktemp -d)"; d="$(cd "$d" && pwd -P)"
( cd "$d" && env -u CLAUDE_PROJECT_DIR bash "$WH" </dev/null >/dev/null 2>&1 )
check "pre-init doc records in_git=0" yes "$(has "$(cat "$d/.claude/handoff_current.md" 2>/dev/null)" "in_git=0")"
must git -C "$d" init -q
out="$( cd "$d" && CLAUDE_PROJECT_DIR="$d" bash "$SS" </dev/null 2>/dev/null )"
check "flip warning emitted"          yes "$(has "$out" "predates this directory becoming a git repo")"
check "doc content still loads"       yes "$(has "$out" "Auto-loaded handoff")"
rm -rf "$d"

echo "session_start — recorded-root mismatch warning"

# Doc written under path X, tree then moved to Y (mv): the loader must flag
# the relocation. (Physical-path comparison, so symlink aliases of the SAME
# dir — /var vs /private/var — must NOT warn; covered implicitly by every
# quiet load in this suite.)
x="$(mktemp -d)"; x="$(cd "$x" && pwd -P)"
( cd "$x" && env -u CLAUDE_PROJECT_DIR bash "$WH" </dev/null >/dev/null 2>&1 )
y="${x}_moved"
must mv "$x" "$y"
out="$( cd "$y" && CLAUDE_PROJECT_DIR="$y" bash "$SS" </dev/null 2>/dev/null )"
check "mismatch warning emitted"      yes "$(has "$out" "moved or renamed project")"
check "warning names the old root"    yes "$(has "$out" "$x")"
# Same doc loaded at its own recorded root: no warning.
must mv "$y" "$x"
out="$( cd "$x" && CLAUDE_PROJECT_DIR="$x" bash "$SS" </dev/null 2>/dev/null )"
check "matching root: no warning"     no  "$(has "$out" "moved or renamed project")"
rm -rf "$x"

echo "session_start — miss visibility"

# No handoff_current.md but prior artifacts exist: the silent no-op is how
# the asymmetry bug hid, so the loader must name the path it looked at.
d="$(mktemp -d)"
must mkdir -p "$d/.claude/handoff_history"
must cp /dev/null "$d/.claude/handoff_history/handoff_2026-01-01_000000.md"
out="$( cd "$d" && CLAUDE_PROJECT_DIR="$d" bash "$SS" </dev/null 2>/dev/null )"
check "miss+evidence: names the looked-at path" yes "$(has "$out" "$d/.claude/handoff_current.md")"
rm -rf "$d"
# A genuinely fresh project stays completely silent.
d="$(mktemp -d)"
out="$( cd "$d" && CLAUDE_PROJECT_DIR="$d" bash "$SS" </dev/null 2>/dev/null )"
check "fresh project: fully silent"             ""  "$out"
rm -rf "$d"

echo "resolver — HANDOFF_DEBUG trace"

d="$(mk_repo)"
err="$( cd "$d" && CLAUDE_PROJECT_DIR="$d" HANDOFF_DEBUG=1 bash "$SS" </dev/null 2>&1 >/dev/null )"
check "debug line on stderr"          yes "$(has "$err" "handoff: root=$d in_git=1")"
check "debug line names the rung"     yes "$(has "$err" "via=project_dir")"
rm -rf "$d"

echo "history — same-second collision ordering (LC_ALL=C sort)"

# handoff_<stamp>_2.md is the NEWER of a same-second pair; the history
# fallback must pick it first. Plain `sort -r` got this right under C
# collation but flipped under en_US.UTF-8 (measured) — pin the behavior.
d="$(mktemp -d)"
must mkdir -p "$d/.claude/handoff_history"
printf '## Notes from this session\nOLDER_SNAPSHOT_MARK\n' > "$d/.claude/handoff_history/handoff_2026-01-01_000000.md"
printf '## Notes from this session\nNEWER_SNAPSHOT_MARK\n' > "$d/.claude/handoff_history/handoff_2026-01-01_000000_2.md"
# Placeholder-only current doc -> triggers the history fallback.
must mkdir -p "$d/.claude"
cat > "$d/.claude/handoff_current.md" <<'EOF'
# h
## Notes from this session

<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->
EOF
out="$( cd "$d" && env CLAUDE_PROJECT_DIR="$d" LC_ALL=en_US.UTF-8 bash "$SS" </dev/null 2>/dev/null )"
check "fallback picks the _2 (newer) archive under UTF-8 locale" yes "$(has "$out" "NEWER_SNAPSHOT_MARK")"
check "older base archive not chosen"                            no  "$(has "$out" "OLDER_SNAPSHOT_MARK")"
rm -rf "$d"

finish
