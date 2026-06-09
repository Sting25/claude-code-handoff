#!/usr/bin/env bash
# Security regression guard for symlink-following in the two write paths.
#
# Both hooks build files under a repo's .claude/, and a *malicious cloned repo*
# can ship those paths as symlinks pointing at victim files outside the repo:
#
#   write_handoff.sh — the document write is a `>` redirect that FOLLOWS a
#     symlink at .claude/handoff_current.md and truncates the target. Rotation
#     normally moves the link aside first, but that is gated on HISTORY_KEEP>0,
#     so HANDOFF_HISTORY_KEEP=0 (a supported setting) writes straight through and
#     DESTROYS the target (e.g. ~/.bashrc, ~/.claude/settings.json).
#
#   handoff_turn_append.sh — the raw dump is a `>>` append that FOLLOWS a symlink
#     at .claude/handoff_backups (dir) or the dump file, and it carries verbatim
#     secret-bearing transcript content — so a planted symlink EXFILTRATES the
#     session's secrets to an attacker-chosen path on the first Stop fire.
#
# Plus: a symlinked .gitignore must not be appended-through by either bootstrap.
#
# These tests plant each symlink, run the hook, and assert the victim is
# untouched and no secret/content escaped.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
TA="$REPO_ROOT/bin/handoff_turn_append.sh"

# Portable "octal mode of a path" (GNU stat -c, BSD stat -f).
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
is_regular() { [[ -f "$1" && ! -L "$1" ]] && echo yes || echo no; }
dir_empty()  { [[ -z "$(ls -A "$1" 2>/dev/null)" ]] && echo yes || echo no; }

run_turn() {  # <cwd> <sid> <transcript> [ENV=VAL ...]
  local cwd="$1" sid="$2" tx="$3"; shift 3
  ( cd "$cwd" && env "$@" printf '{"session_id":"%s","transcript_path":"%s"}' "$sid" "$tx" \
      | ( cd "$cwd" && env "$@" bash "$TA" ) >/dev/null 2>&1 )
}

# ===========================================================================
echo "write_handoff.sh — symlink-safe document write (paths#1/#4)"

# --- handoff_current.md is a symlink to a victim, HISTORY_KEEP=0 -> no clobber
repo="$(mk_repo)"; mkdir -p "$repo/.claude"
victim="$(mktemp)"; printf 'ORIGINAL_DOTFILE_CONTENT\n' > "$victim"
ln -s "$victim" "$repo/.claude/handoff_current.md"
( cd "$repo" && HANDOFF_HISTORY_KEEP=0 HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 bash "$WH" >/dev/null 2>&1 )
check "KEEP=0: victim file NOT clobbered through symlink" "ORIGINAL_DOTFILE_CONTENT" "$(cat "$victim")"
check "KEEP=0: handoff written as a real file in repo"    yes "$(is_regular "$repo/.claude/handoff_current.md")"
rm -rf "$repo"; rm -f "$victim"

# --- handoff_current.md is a symlink, default HISTORY_KEEP -> link not rotated
#     into history (paths#4) and victim untouched.
repo="$(mk_repo)"; mkdir -p "$repo/.claude"
victim="$(mktemp)"; printf 'ORIGINAL_DOTFILE_CONTENT\n' > "$victim"
ln -s "$victim" "$repo/.claude/handoff_current.md"
( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 bash "$WH" >/dev/null 2>&1 )
check "default KEEP: victim NOT clobbered"        "ORIGINAL_DOTFILE_CONTENT" "$(cat "$victim")"
check "default KEEP: no symlink relocated to history" no \
  "$(find "$repo/.claude/handoff_history" -maxdepth 1 -type l 2>/dev/null | grep -q . && echo yes || echo no)"
rm -rf "$repo"; rm -f "$victim"

# --- .claude itself is a symlink -> refuse outright, write nothing into target
repo="$(mk_repo)"; ext="$(mktemp -d)"
ln -s "$ext" "$repo/.claude"
( cd "$repo" && bash "$WH" >/dev/null 2>&1 ); rc=$?
check ".claude-symlink: write_handoff refuses (exit 1)"   1 "$rc"
check ".claude-symlink: nothing written into link target" yes "$(dir_empty "$ext")"
rm -rf "$repo" "$ext"

# --- symlinked .gitignore is not appended-through (paths#3)
repo="$(mk_repo)"
givictim="$(mktemp)"; printf 'ORIGINAL_GITIGNORE\n' > "$givictim"
ln -s "$givictim" "$repo/.gitignore"
( cd "$repo" && bash "$WH" >/dev/null 2>&1 )   # bootstrap ON (default)
check "gi-symlink: .gitignore target untouched (write_handoff)" "ORIGINAL_GITIGNORE" "$(cat "$givictim")"
rm -rf "$repo"; rm -f "$givictim"

# --- sanity: a normal (non-symlink) write still produces a correct 0600 doc
#     atomically (no leftover temp).
repo="$(mk_repo)"
out="$( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 bash "$WH" 2>/dev/null )"
check "normal write: handoff is a regular file"      yes "$(is_regular "$repo/.claude/handoff_current.md")"
check "normal write: mode 0600"                      600 "$(file_mode "$repo/.claude/handoff_current.md")"
check "normal write: contains generated header"      yes "$(grep -q 'session handoff (auto-generated)' "$repo/.claude/handoff_current.md" && echo yes || echo no)"
check "normal write: no leftover .handoff_current tmp" yes "$([[ -z "$(ls -A "$repo/.claude"/.handoff_current.* 2>/dev/null)" ]] && echo yes || echo no)"
check "normal write: stdout is the handoff path"     "$repo/.claude/handoff_current.md" "$out"
rm -rf "$repo"

# ===========================================================================
echo "handoff_turn_append.sh — symlink-safe raw dump (paths#2/#3)"
if ! command -v jq >/dev/null 2>&1; then skip "jq missing — Stop-hook tests";  finish; exit; fi
if ! command -v perl >/dev/null 2>&1; then skip "perl missing — Stop-hook tests"; finish; exit; fi

SECRET="sk-LEAK-DO-NOT-EXFILTRATE-9f3a"

# --- backup dir is a symlink OUT of the repo -> refuse; secret never escapes
repo="$(mk_repo)"; mkdir -p "$repo/.claude"
evil="$(mktemp -d)"
ln -s "$evil" "$repo/.claude/handoff_backups"
tx="$repo/tx.jsonl"; printf '{"type":"user","message":{"content":"my key is %s"}}\n' "$SECRET" > "$tx"
run_turn "$repo" EXFILDIR "$tx"
check "dir-symlink: attacker dir stays empty"      yes "$(dir_empty "$evil")"
check "dir-symlink: secret NOT exfiltrated"        no  "$(grep -rq "$SECRET" "$evil" 2>/dev/null && echo yes || echo no)"
rm -rf "$repo" "$evil"

# --- the dump FILE itself is a symlink to a victim -> refuse; victim untouched
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; mkdir -p "$bd"
victim="$(mktemp)"; printf 'ORIGINAL_VICTIM\n' > "$victim"
ln -s "$victim" "$bd/handoff_raw_EXFILFILE.md"
tx="$repo/tx.jsonl"; printf '{"type":"user","message":{"content":"my key is %s"}}\n' "$SECRET" > "$tx"
run_turn "$repo" EXFILFILE "$tx"
check "file-symlink: victim content unchanged"     "ORIGINAL_VICTIM" "$(cat "$victim")"
check "file-symlink: secret NOT in victim"         no  "$(grep -q "$SECRET" "$victim" && echo yes || echo no)"
rm -rf "$repo"; rm -f "$victim"

# --- .claude is a symlink -> refuse; nothing written into target
repo="$(mk_repo)"; ext="$(mktemp -d)"
ln -s "$ext" "$repo/.claude"
tx="$repo/tx.jsonl"; printf '{"type":"user","message":{"content":"my key is %s"}}\n' "$SECRET" > "$tx"
run_turn "$repo" EXFILCLAUDE "$tx"
check ".claude-symlink (stop): target stays empty"  yes "$(dir_empty "$ext")"
check ".claude-symlink (stop): secret NOT in target" no "$(grep -rq "$SECRET" "$ext" 2>/dev/null && echo yes || echo no)"
rm -rf "$repo" "$ext"

# --- symlinked .gitignore is not appended-through by the Stop hook (paths#3)
repo="$(mk_repo)"
givictim="$(mktemp)"; printf 'ORIGINAL_GITIGNORE\n' > "$givictim"
ln -s "$givictim" "$repo/.gitignore"
tx="$repo/tx.jsonl"; printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx"
run_turn "$repo" GISYM "$tx"
check "gi-symlink: .gitignore target untouched (stop hook)" "ORIGINAL_GITIGNORE" "$(cat "$givictim")"
check "gi-symlink: dump still written to real backup dir"   yes \
  "$([[ -f "$repo/.claude/handoff_backups/handoff_raw_GISYM.md" ]] && echo yes || echo no)"
rm -rf "$repo"; rm -f "$givictim"

# --- sanity: a normal (non-symlink) Stop fire still captures content + secret
#     IS recorded into the (owner-only, repo-local) dump.
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"
tx="$repo/tx.jsonl"; printf '{"type":"user","message":{"content":"normal turn %s"}}\n' "$SECRET" > "$tx"
run_turn "$repo" OK "$tx"
check "normal stop: dump captured the turn" yes \
  "$([[ -f "$bd/handoff_raw_OK.md" ]] && grep -q "$SECRET" "$bd/handoff_raw_OK.md" && echo yes || echo no)"
check "normal stop: dump is a regular file" yes "$(is_regular "$bd/handoff_raw_OK.md")"
rm -rf "$repo"

finish
