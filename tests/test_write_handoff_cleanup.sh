#!/usr/bin/env bash
# Audit-tail hardening for the handoff write paths:
#   tests#2     — a rotated history snapshot must be 0600 even if the live doc
#                 was 0644 (pre-0.8.2): `mv` preserves source mode, so a
#                 world-readable handoff would otherwise stay readable in history.
#   injection#1 — prune_history must tolerate a crafted history filename (space /
#                 quote) and not abort the whole handoff write (bare xargs did).
#   tests#3     — write_handoff git-ignores the handoff doc (coverage for the
#                 gitignore-before-write ordering; only the Stop hook's was tested).
#   perms#1     — a .gitignore created by the umask-077 hooks must be 0644 (not
#                 secret), but an EXISTING .gitignore's mode must be left alone.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
TA="$REPO_ROOT/bin/handoff_turn_append.sh"
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

echo "write_handoff.sh — rotated history perms (tests#2)"
repo="$(mk_repo)"; mkdir -p "$repo/.claude"
# A pre-0.8.2-style world-readable live handoff.
cat > "$repo/.claude/handoff_current.md" <<'EOF'
# old handoff
## Notes from this session
secret prose from a prior session
EOF
chmod 644 "$repo/.claude/handoff_current.md"
( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 bash "$WH" >/dev/null 2>&1 )
rotated="$(find "$repo/.claude/handoff_history" -maxdepth 1 -name 'handoff_*.md' 2>/dev/null | sort | head -1)"
check "rotated history snapshot exists" yes "$([[ -n "$rotated" ]] && echo yes || echo no)"
check "rotated history snapshot is 0600 (was 0644)" 600 "$(file_mode "$rotated")"
rm -rf "$repo"

echo "write_handoff.sh — prune tolerates a crafted history filename (injection#1)"
repo="$(mk_repo)"; hist="$repo/.claude/handoff_history"; mkdir -p "$hist"
for i in 1 2 3 4 5 6; do : > "$hist/handoff_2026-01-0${i}_000000.md"; done
weird="$hist/handoff_2000-01-01_000000 weird'name.md"   # oldest -> in the prune set
: > "$weird"
cat > "$repo/.claude/handoff_current.md" <<'EOF'
# cur
## Notes from this session
x
EOF
( cd "$repo" && HANDOFF_HISTORY_KEEP=5 HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 bash "$WH" >/dev/null 2>&1 ); rc=$?
check "crafted history name: write still succeeds (rc 0)" 0 "$rc"
check "crafted history name: handoff doc written"         yes \
  "$([[ -f "$repo/.claude/handoff_current.md" ]] && grep -q 'auto-generated' "$repo/.claude/handoff_current.md" && echo yes || echo no)"
check "crafted history name: oldest weird file pruned"    no  "$([[ -e "$weird" ]] && echo yes || echo no)"
rm -rf "$repo"

echo "write_handoff.sh — gitignore before write + .gitignore perms (tests#3 / perms#1)"
repo="$(mk_repo)"   # mk_repo leaves no .gitignore
( cd "$repo" && bash "$WH" >/dev/null 2>&1 )   # bootstrap ON
check "tests#3: .gitignore lists the handoff doc" yes \
  "$(grep -qF '.claude/handoff_current.md' "$repo/.gitignore" 2>/dev/null && echo yes || echo no)"
check "tests#3: handoff_current.md is git-ignored" yes \
  "$( ( cd "$repo" && git check-ignore -q '.claude/handoff_current.md' ) && echo yes || echo no)"
check "perms#1: bootstrapped .gitignore is 0644"  644 "$(file_mode "$repo/.gitignore")"
rm -rf "$repo"

# An EXISTING .gitignore must keep its own mode (we only normalize ones we create).
repo="$(mk_repo)"
cat > "$repo/.gitignore" <<'EOF'
node_modules
EOF
chmod 600 "$repo/.gitignore"
( cd "$repo" && bash "$WH" >/dev/null 2>&1 )
check "perms#1: pre-existing .gitignore mode untouched" 600 "$(file_mode "$repo/.gitignore")"
rm -rf "$repo"

echo "write_handoff.sh — mid-build abort must not consume handoff_current.md (audit 2026-07-17)"
# Rotation used to run BEFORE the new doc was built, so an abort during the
# build (ENOSPC, a git failure) moved the old handoff into history and
# published nothing — the next SessionStart silently loaded no context. Force
# a mid-build failure by pointing HANDOFF_PINNED_FILE at a DIRECTORY: it
# passes the `-s` gate, then `cat` on it fails inside the doc-build group and
# set -e aborts the script exactly in the old danger window.
repo="$(mk_repo)"; must mkdir -p "$repo/.claude" "$repo/pinned_is_a_dir"
must cat > "$repo/.claude/handoff_current.md" <<'EOF'
# old handoff
## Notes from this session
PRIOR_SESSION_PROSE_MARKER
EOF
( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 \
    HANDOFF_PINNED_FILE="$repo/pinned_is_a_dir" bash "$WH" >/dev/null 2>&1 ); rc=$?
check "mid-build abort: nonzero exit"              nonzero "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)"
check "mid-build abort: handoff_current.md intact" yes \
  "$(grep -q 'PRIOR_SESSION_PROSE_MARKER' "$repo/.claude/handoff_current.md" 2>/dev/null && echo yes || echo no)"
check "mid-build abort: nothing rotated to history" 0 \
  "$(ls -1 "$repo/.claude/handoff_history"/handoff_*.md 2>/dev/null | wc -l | tr -d ' ')"
check "mid-build abort: no stray tmp left behind"   0 \
  "$(ls -1 "$repo/.claude"/.handoff_current.* 2>/dev/null | wc -l | tr -d ' ')"
# Control: the same repo without the poisoned pin succeeds — the old doc is
# rotated into history and a fresh one published.
( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 bash "$WH" >/dev/null 2>&1 ); rc=$?
check "control: write succeeds after abort"        0 "$rc"
check "control: old handoff rotated into history"  yes \
  "$(grep -q 'PRIOR_SESSION_PROSE_MARKER' "$repo/.claude/handoff_history"/handoff_*.md 2>/dev/null && echo yes || echo no)"
check "control: new handoff published"             yes \
  "$(grep -q 'auto-generated' "$repo/.claude/handoff_current.md" 2>/dev/null && echo yes || echo no)"
rm -rf "$repo"

echo "handoff_turn_append.sh — bootstrapped .gitignore perms (perms#1)"
if command -v jq >/dev/null 2>&1; then
  repo="$(mk_repo)"; tx="$repo/tx.jsonl"
  printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx"
  ( cd "$repo" && printf '{"session_id":"GIP","transcript_path":"%s"}' "$tx" \
      | bash "$TA" >/dev/null 2>&1 )
  check "perms#1 (stop hook): bootstrapped .gitignore is 0644" 644 "$(file_mode "$repo/.gitignore")"
  rm -rf "$repo"
else
  skip "jq missing — stop-hook .gitignore perms"
fi

finish
