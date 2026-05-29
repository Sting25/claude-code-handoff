#!/usr/bin/env bash
# Security regression guard for the Stop hook's raw transcript dumps
# (handoff_turn_append.sh). The dumps contain verbatim session content,
# including anything sensitive surfaced in tool output, so:
#   1. they must be created owner-only (0600), not 0664/world-readable;
#   2. the backup dir must be created owner-only (0700);
#   3. .claude/handoff_backups/ must be git-ignored BY THIS HOOK, before the
#      first dump exists — the Stop hook fires long before SessionEnd, so the
#      gitignore can't wait for write_handoff.sh (closes the git-add window);
#   4. the opt-out env var still suppresses the .gitignore write;
#   5. a dump left 0664 by a pre-0.8.1 version is tightened to 0600 on append.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TA="$REPO_ROOT/bin/handoff_turn_append.sh"
command -v jq   >/dev/null 2>&1 || { echo "handoff_turn_append.sh (dump security)"; skip "jq missing";  finish; exit; }
command -v perl >/dev/null 2>&1 || { echo "handoff_turn_append.sh (dump security)"; skip "perl missing"; finish; exit; }

# Portable "octal mode of a path" (GNU stat -c, BSD stat -f).
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

run_turn() {  # <cwd> <sid> <transcript> [ENV=VAL ...]
  local cwd="$1" sid="$2" tx="$3"; shift 3
  ( cd "$cwd" && env "$@" printf '{"session_id":"%s","transcript_path":"%s"}' "$sid" "$tx" \
      | ( cd "$cwd" && env "$@" bash "$TA" ) >/dev/null 2>&1 )
}

echo "handoff_turn_append.sh — dump file security (perms + early gitignore)"

# --- 1 & 2: fresh dump is 0600, backup dir is 0700 -------------------------
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; tx="$repo/tx.jsonl"
printf '{"type":"user","message":{"content":"hello"}}\n' > "$tx"
run_turn "$repo" SEC "$tx"
check "dump created owner-only (0600)" 600 "$(file_mode "$bd/handoff_raw_SEC.md")"
check "backup dir owner-only (0700)"   700 "$(file_mode "$bd")"
rm -rf "$repo"

# --- 3: hook git-ignores the backup dir, and the dump is actually ignored ---
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; tx="$repo/tx.jsonl"
printf '{"type":"user","message":{"content":"hello"}}\n' > "$tx"
run_turn "$repo" GI "$tx"
ignored() { ( cd "$repo" && git check-ignore -q "$1" 2>/dev/null ) && echo yes || echo no; }
check ".gitignore lists backups dir" yes "$(grep -qF '.claude/handoff_backups/' "$repo/.gitignore" 2>/dev/null && echo yes || echo no)"
check "dump is git-ignored (no commit window)" yes "$(ignored ".claude/handoff_backups/handoff_raw_GI.md")"
rm -rf "$repo"

# --- 4: opt-out env var suppresses the .gitignore write ---------------------
repo="$(mk_repo)"; tx="$repo/tx.jsonl"
printf '{"type":"user","message":{"content":"hello"}}\n' > "$tx"
run_turn "$repo" NOGI "$tx" HANDOFF_NO_GITIGNORE_BOOTSTRAP=1
check "opt-out -> no .gitignore written" no "$([[ -f "$repo/.gitignore" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- 5: a legacy 0664 dump gets tightened to 0600 on the next append --------
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; mkdir -p "$bd"; tx="$repo/tx.jsonl"
printf '# Raw session dump\n\nold content\n' > "$bd/handoff_raw_UP.md"
chmod 664 "$bd/handoff_raw_UP.md"
check "precondition: legacy dump is 0664" 664 "$(file_mode "$bd/handoff_raw_UP.md")"
printf '{"type":"user","message":{"content":"new turn"}}\n' > "$tx"   # 1 new line, cursor=0 -> appends
run_turn "$repo" UP "$tx"
check "legacy dump tightened to 0600" 600 "$(file_mode "$bd/handoff_raw_UP.md")"
rm -rf "$repo"

finish
