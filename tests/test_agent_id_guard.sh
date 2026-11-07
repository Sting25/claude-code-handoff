#!/usr/bin/env bash
# Subagent guard (issue #145). Hook payloads fired from inside a subagent carry
# a non-empty `agent_id`; every hook script must then exit 0 without acting:
# no file created or modified, nothing on stdout. A payload with only
# `agent_type` (set for main sessions started with `--agent`) is a MAIN
# session and must be handled normally. HANDOFF_HOOKS_ALLOW_AGENTS=1 opts the
# agent payload back in.
#
# Per script: (1) agent_id payload -> tree snapshot identical + stdout empty,
# (2) agent_type-only payload -> one observable of the normal behaviour,
# (3) the same agent_id payload with the knob -> the normal behaviour again
# (proves (1) is the guard and not a fixture that cannot act).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "agent_id guard"; skip "jq missing"; finish; exit; }
command -v perl >/dev/null 2>&1 || { echo "agent_id guard"; skip "perl missing"; finish; exit; }

SS="$REPO_ROOT/bin/handoff_session_start.sh"
WH="$REPO_ROOT/bin/write_handoff.sh"
CR="$REPO_ROOT/bin/handoff_compact_reset.sh"
TA="$REPO_ROOT/bin/handoff_turn_append.sh"
CC="$REPO_ROOT/bin/handoff_ctx_check.sh"
WR="$REPO_ROOT/bin/handoff_worktree_remove.sh"

exists() { if [[ -e "$1" ]]; then echo yes; else echo no; fi; }
nonempty() { if [[ -n "$1" ]]; then echo yes; else echo no; fi; }
# One checksum over the names and contents of everything under <dir>.
snap() {
  ( cd "$1" && { find . -not -path './.git/*' -not -name .git | LC_ALL=C sort
                 find . -type f -not -path './.git/*' -exec cksum {} + | LC_ALL=C sort; } | cksum )
}
# fire <script> <repo> <payload> [env...]: stdout of the hook (stderr dropped).
fire() {
  local s="$1" r="$2" p="$3"; shift 3
  ( cd "$r" && env CLAUDE_PROJECT_DIR="$r" "$@" bash "$s" <<<"$p" 2>/dev/null )
}

AGENT_FIELDS='"agent_id":"agent-abc123","agent_type":"Explore"'
TYPE_ONLY_FIELDS='"agent_type":"my-agent"'

echo "agent_id guard: handoff_session_start.sh"
# A fresh repo prints nothing at SessionStart, so seed a handoff to load.
mk_loaded() { local d; d="$(mk_repo)" || return 1; ( cd "$d" && env CLAUDE_PROJECT_DIR="$d" bash "$WH" </dev/null >/dev/null 2>&1 ); printf '%s\n' "$d"; }
r="$(mk_loaded)"; cleanup_on_exit "$r"; must test -f "$r/.claude/handoff_current.md"
pay() { printf '{"session_id":"SSA1","cwd":"%s","source":"startup",%s}' "$r" "$1"; }
before="$(snap "$r")"
out="$(fire "$SS" "$r" "$(pay "$AGENT_FIELDS")")"
check "session_start: agent_id -> no stdout"        no  "$(nonempty "$out")"
check "session_start: agent_id -> tree unchanged"   "$before" "$(snap "$r")"
out="$(fire "$SS" "$r" "$(pay "$TYPE_ONLY_FIELDS")")"
check "session_start: agent_type only -> output"    yes "$(nonempty "$out")"
r2="$(mk_loaded)"; cleanup_on_exit "$r2"
out="$(fire "$SS" "$r2" "$(printf '{"session_id":"SSA2","cwd":"%s","source":"startup",%s}' "$r2" "$AGENT_FIELDS")" HANDOFF_HOOKS_ALLOW_AGENTS=1)"
check "session_start: ALLOW_AGENTS=1 -> output"     yes "$(nonempty "$out")"

echo "agent_id guard: write_handoff.sh"
r="$(mk_repo)"; cleanup_on_exit "$r"
pay='{"session_id":"WHA1","reason":"other","cwd":"'"$r"'",'
before="$(snap "$r")"
out="$(fire "$WH" "$r" "${pay}${AGENT_FIELDS}}")"
check "write_handoff: agent_id -> no stdout"        no  "$(nonempty "$out")"
check "write_handoff: agent_id -> tree unchanged"   "$before" "$(snap "$r")"
check "write_handoff: agent_id -> no handoff doc"   no  "$(exists "$r/.claude/handoff_current.md")"
fire "$WH" "$r" "${pay}${TYPE_ONLY_FIELDS}}" >/dev/null
check "write_handoff: agent_type only -> doc"       yes "$(exists "$r/.claude/handoff_current.md")"
r2="$(mk_repo)"; cleanup_on_exit "$r2"
fire "$WH" "$r2" '{"session_id":"WHA2","reason":"other","cwd":"'"$r2"'",'"$AGENT_FIELDS}" HANDOFF_HOOKS_ALLOW_AGENTS=1 >/dev/null
check "write_handoff: ALLOW_AGENTS=1 -> doc"        yes "$(exists "$r2/.claude/handoff_current.md")"

echo "agent_id guard: handoff_compact_reset.sh"
seed() { mkdir -p "$1/.claude/handoff_backups" && printf '4000' > "$1/.claude/handoff_backups/.ctx_CRA1"; }
r="$(mk_repo)"; cleanup_on_exit "$r"; must seed "$r"
pay='{"session_id":"CRA1","cwd":"'"$r"'",'
before="$(snap "$r")"
out="$(fire "$CR" "$r" "${pay}${AGENT_FIELDS}}")"
check "compact_reset: agent_id -> no stdout"        no  "$(nonempty "$out")"
check "compact_reset: agent_id -> tree unchanged"   "$before" "$(snap "$r")"
fire "$CR" "$r" "${pay}${TYPE_ONLY_FIELDS}}" >/dev/null
check "compact_reset: agent_type only -> reset"     no  "$(exists "$r/.claude/handoff_backups/.ctx_CRA1")"
r2="$(mk_repo)"; cleanup_on_exit "$r2"; must seed "$r2"
fire "$CR" "$r2" '{"session_id":"CRA1","cwd":"'"$r2"'",'"$AGENT_FIELDS}" HANDOFF_HOOKS_ALLOW_AGENTS=1 >/dev/null
check "compact_reset: ALLOW_AGENTS=1 -> reset"      no  "$(exists "$r2/.claude/handoff_backups/.ctx_CRA1")"

echo "agent_id guard: handoff_turn_append.sh"
r="$(mk_repo)"; cleanup_on_exit "$r"
printf '{"type":"user","message":{"content":"guard prompt"}}\n' > "$r/tx.jsonl"
pay='{"session_id":"TAA1","transcript_path":"'"$r"'/tx.jsonl","cwd":"'"$r"'",'
before="$(snap "$r")"
out="$(fire "$TA" "$r" "${pay}${AGENT_FIELDS}}")"
check "turn_append: agent_id -> no stdout"          no  "$(nonempty "$out")"
check "turn_append: agent_id -> tree unchanged"     "$before" "$(snap "$r")"
check "turn_append: agent_id -> no dump"            no  "$(exists "$r/.claude/handoff_backups/handoff_raw_TAA1.md")"
fire "$TA" "$r" "${pay}${TYPE_ONLY_FIELDS}}" >/dev/null
check "turn_append: agent_type only -> dump"        yes "$(exists "$r/.claude/handoff_backups/handoff_raw_TAA1.md")"
r2="$(mk_repo)"; cleanup_on_exit "$r2"
printf '{"type":"user","message":{"content":"guard prompt"}}\n' > "$r2/tx.jsonl"
fire "$TA" "$r2" '{"session_id":"TAA1","transcript_path":"'"$r2"'/tx.jsonl","cwd":"'"$r2"'",'"$AGENT_FIELDS}" HANDOFF_HOOKS_ALLOW_AGENTS=1 >/dev/null
check "turn_append: ALLOW_AGENTS=1 -> dump"         yes "$(exists "$r2/.claude/handoff_backups/handoff_raw_TAA1.md")"

echo "agent_id guard: handoff_ctx_check.sh"
# Observable: with jq absent the hook prints a once-per-session warning and
# drops a marker; that path runs before any parse, so it exercises the guard
# placement (the guard must precede it) without a token fixture.
shim="$(path_without jq)"; cleanup_on_exit "$shim"
r="$(mk_repo)"; cleanup_on_exit "$r"
pay='{"session_id":"CCA1","cwd":"'"$r"'","prompt":"hi",'
before="$(snap "$r")"
out="$(fire "$CC" "$r" "${pay}${AGENT_FIELDS}}" PATH="$shim")"
check "ctx_check: agent_id (no jq) -> no stdout"    no  "$(nonempty "$out")"
check "ctx_check: agent_id (no jq) -> unchanged"    "$before" "$(snap "$r")"
out="$(fire "$CC" "$r" "${pay}${TYPE_ONLY_FIELDS}}" PATH="$shim")"
check "ctx_check: agent_type only (no jq) -> warns" yes "$(nonempty "$out")"
# With jq: agent payload leaves a seeded session untouched and silent.
r3="$(mk_repo)"; cleanup_on_exit "$r3"
mkdir -p "$r3/.claude/handoff_backups"
printf 'window=1000\ntokens=990\n' > "$r3/.claude/handoff_backups/.ctx_sl_CCA3"
before="$(snap "$r3")"
out="$(fire "$CC" "$r3" '{"session_id":"CCA3","cwd":"'"$r3"'","prompt":"hi",'"$AGENT_FIELDS}" HANDOFF_CTX_WINDOW_TOKENS=1000)"
check "ctx_check: agent_id (jq) -> no stdout"       no  "$(nonempty "$out")"
check "ctx_check: agent_id (jq) -> unchanged"       "$before" "$(snap "$r3")"
out="$(fire "$CC" "$r3" '{"session_id":"CCA3","cwd":"'"$r3"'","prompt":"hi",'"$TYPE_ONLY_FIELDS}" HANDOFF_CTX_WINDOW_TOKENS=1000)"
check "ctx_check: agent_type only (jq) -> nudge"    yes "$(nonempty "$out")"

echo "agent_id guard: handoff_worktree_remove.sh"
mk_main() {
  local m; m="$(mk_repo)" || return 1
  printf '.claude/\n' > "$m/.gitignore"
  git -C "$m" add .gitignore && git -C "$m" commit -qm "ignore .claude" || return 1
  mkdir -p "$m/.claude/worktrees" || return 1
  git -C "$m" worktree add -q "$m/.claude/worktrees/wt-g" -b feat/wt-g >/dev/null 2>&1 || return 1
  mkdir -p "$m/.claude/worktrees/wt-g/.claude/handoff_backups" || return 1
  printf '# Raw session dump (session WRA1)\n\n## Turn at 2026-11-07 10:00:00\n\nGUARD NOTE\n' \
    > "$m/.claude/worktrees/wt-g/.claude/handoff_backups/handoff_raw_WRA1.md" || return 1
  printf '%s\n' "$m"
}
raws() { find "$1/.claude/handoff_history/worktrees" -maxdepth 1 -type f -name 'raw_*.md' 2>/dev/null | grep -c . || true; }
wr_pay() { printf '{"session_id":"WRA1","cwd":"%s","worktree_path":"%s/.claude/worktrees/wt-g",%s}' "$1" "$1" "$2"; }
m="$(mk_main)"; cleanup_on_exit "$m"
before="$(snap "$m")"
out="$(fire "$WR" "$m" "$(wr_pay "$m" "$AGENT_FIELDS")")"
check "worktree_remove: agent_id -> no stdout"      no  "$(nonempty "$out")"
check "worktree_remove: agent_id -> unchanged"      "$before" "$(snap "$m")"
check "worktree_remove: agent_id -> no salvage"     0   "$(raws "$m")"
fire "$WR" "$m" "$(wr_pay "$m" "$TYPE_ONLY_FIELDS")" >/dev/null
check "worktree_remove: agent_type only -> salvage" 1   "$(raws "$m")"
m2="$(mk_main)"; cleanup_on_exit "$m2"
fire "$WR" "$m2" "$(wr_pay "$m2" "$AGENT_FIELDS")" HANDOFF_HOOKS_ALLOW_AGENTS=1 >/dev/null
check "worktree_remove: ALLOW_AGENTS=1 -> salvage"  1   "$(raws "$m2")"

finish
