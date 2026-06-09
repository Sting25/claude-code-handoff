#!/usr/bin/env bash
# Behavioral coverage for handoff_ctx_check.sh (the UserPromptSubmit hook that
# flags a /handoff moment once context crosses a threshold). This script had no
# tests. We pin the window via HANDOFF_CTX_WINDOW_TOKENS so the ~/.claude.json
# auto-detect path never participates, then drive the threshold / fallback /
# mode / cooldown branches directly.
#
# Observable: stdout (a <system-reminder> or nothing) + the .ctx_flagged_* file
# the cooldown is recorded in.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CC="$REPO_ROOT/bin/handoff_ctx_check.sh"
command -v jq >/dev/null 2>&1 || { echo "handoff_ctx_check.sh"; skip "jq missing — hook parses payload with jq"; finish; exit; }

# Seed a session's backup dir. Args: <repo> <sid> <bytes> [tokens] [flagged_bytes]
seed() {
  local repo="$1" sid="$2" bytes="$3" tokens="${4:-}" flagged="${5:-}"
  local bd="$repo/.claude/handoff_backups"; mkdir -p "$bd"
  printf '%s' "$bytes" > "$bd/.ctx_${sid}"
  [[ -n "$tokens"  ]] && printf '%s' "$tokens"  > "$bd/.ctx_tokens_${sid}"
  [[ -n "$flagged" ]] && printf '%s' "$flagged" > "$bd/.ctx_flagged_${sid}"
}

# Run the hook for a session. Trailing args are ENV=VAL overrides.
run_cc() {  # <repo> <sid> [ENV=VAL ...]
  local repo="$1" sid="$2"; shift 2
  ( cd "$repo" && env HANDOFF_CTX_WINDOW_TOKENS=1000 "$@" \
      bash "$CC" <<<"{\"session_id\":\"$sid\"}" 2>/dev/null )
}

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

echo "handoff_ctx_check.sh — threshold / fallback / mode / cooldown"

# --- Empty payload -> silent exit 0 -----------------------------------------
repo="$(mk_repo)"
out="$( cd "$repo" && bash "$CC" </dev/null 2>/dev/null )"; rc=$?
check "empty payload -> exit 0"    0  "$rc"
check "empty payload -> no output" "" "$out"
rm -rf "$repo"

# --- No recorded size file (first prompt) -> silent --------------------------
repo="$(mk_repo)"
out="$(run_cc "$repo" NOFILE)"
check "no .ctx file -> no output" "" "$out"
rm -rf "$repo"

# --- Below threshold -> no reminder -----------------------------------------
# window 1000, pct 50 -> threshold 500 tokens; 100 tokens is well under.
repo="$(mk_repo)"; seed "$repo" LOW 4000 100
out="$(run_cc "$repo" LOW)"
check "below threshold -> no output" "" "$out"
rm -rf "$repo"

# --- Above threshold via real token count -> reminder w/ pct -----------------
repo="$(mk_repo)"; seed "$repo" HIGH 4000 600   # 600/1000 = 60%
out="$(run_cc "$repo" HIGH)"
check "above threshold -> system-reminder" yes "$(has "$out" "<system-reminder>")"
check "above threshold -> pct shown (60%)" yes "$(has "$out" "60%")"
check "above threshold -> uses token cnt"  yes "$(has "$out" "600 tokens")"
check "above threshold -> flag recorded"   yes "$([[ -f "$repo/.claude/handoff_backups/.ctx_flagged_HIGH" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- No tokens file -> bytes/4 fallback crosses threshold --------------------
# 4,000,000 bytes / 4 = 1,000,000 est tokens, far above the 500 threshold.
repo="$(mk_repo)"; seed "$repo" BYTES 4000000
out="$(run_cc "$repo" BYTES)"
check "bytes/4 fallback -> fires" yes "$(has "$out" "<system-reminder>")"
rm -rf "$repo"

# --- suggest (default) vs act mode wording ----------------------------------
repo="$(mk_repo)"; seed "$repo" SUG 4000 600
out="$(run_cc "$repo" SUG)"
check "suggest mode -> passive-mention copy" yes "$(has "$out" "passive mention")"
check "suggest mode -> not self-invoke copy" no  "$(has "$out" "invoke /handoff yourself")"
rm -rf "$repo"

repo="$(mk_repo)"; seed "$repo" ACT 4000 600
out="$(run_cc "$repo" ACT HANDOFF_CTX_REMINDER_MODE=act)"
check "act mode -> self-invoke copy"      yes "$(has "$out" "invoke /handoff yourself")"
check "act mode -> not passive-mention"   no  "$(has "$out" "passive mention")"
rm -rf "$repo"

# --- Cooldown: a recent flag within COOLDOWN_KB suppresses re-flag -----------
# current_bytes 200000, flagged at 200000, cooldown 100KB(=102400):
# 200000 < 200000+102400 -> suppressed.
repo="$(mk_repo)"; seed "$repo" CD 200000 600 200000
out="$(run_cc "$repo" CD)"
check "within cooldown -> suppressed" "" "$out"
rm -rf "$repo"

# Beyond cooldown: flagged long ago (0) -> 200000 >= 0+102400 -> re-fires.
repo="$(mk_repo)"; seed "$repo" CD2 200000 600 0
out="$(run_cc "$repo" CD2)"
check "beyond cooldown -> re-fires" yes "$(has "$out" "<system-reminder>")"
rm -rf "$repo"

# First crossing always fires regardless of byte size (no flag file yet).
repo="$(mk_repo)"; seed "$repo" FIRST 10 600
out="$(run_cc "$repo" FIRST)"
check "first crossing -> fires despite tiny bytes" yes "$(has "$out" "<system-reminder>")"
rm -rf "$repo"

# --- THRESHOLD_PCT override changes the gate --------------------------------
# 600 tokens / 1000 window = 60%. With threshold 70% it should NOT fire.
repo="$(mk_repo)"; seed "$repo" PCT 4000 600
out="$(run_cc "$repo" PCT HANDOFF_CTX_THRESHOLD_PCT=70)"
check "threshold 70% -> 60% does not fire" "" "$out"
rm -rf "$repo"

# --- WINDOW_TOKENS=0 must not divide-by-zero --------------------------------
# A bogus HANDOFF_CTX_WINDOW_TOKENS=0 override would make the threshold/pct
# arithmetic divide by zero, which aborts the script under `set -e` *before*
# any reminder is emitted (so the negative control is empty output). The fix
# ignores a non-positive override and falls through to auto-detection (200k or
# 1M). 600k tokens crosses 50% of either, so a reminder must fire regardless of
# this host's ~/.claude.json. Proves: no crash + valid pct computed.
repo="$(mk_repo)"; seed "$repo" ZEROWIN 4000 600000
out="$(run_cc "$repo" ZEROWIN HANDOFF_CTX_WINDOW_TOKENS=0)"
check "WINDOW=0 -> no crash, reminder fires" yes "$(has "$out" "<system-reminder>")"
rm -rf "$repo"

# Non-numeric override is treated the same way (ignored, auto-detect).
repo="$(mk_repo)"; seed "$repo" GARBAGEWIN 4000 600000
out="$(run_cc "$repo" GARBAGEWIN HANDOFF_CTX_WINDOW_TOKENS=notanumber)"
check "WINDOW=garbage -> no crash, fires"    yes "$(has "$out" "<system-reminder>")"
rm -rf "$repo"

# --- session_id validation (critic) -----------------------------------------
# session_id is interpolated into the .ctx_/.ctx_tokens_/.ctx_flagged_ paths, so
# a non-conforming value must be rejected BEFORE any path use — mirroring the
# Stop hook's guard. Non-vacuous: for sid 'sub/evil' the size_file resolves to a
# real over-threshold file, so the UNGUARDED hook would emit a reminder; the
# guard makes it exit silently.
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; mkdir -p "$bd/.ctx_sub"
printf '4000' > "$bd/.ctx_sub/evil"   # = $bd/.ctx_<sid> for sid 'sub/evil'; 4000B/4 > 500
out="$(run_cc "$repo" "sub/evil")"; rc=$?
check "bad session_id (slash) -> exit 0"      0  "$rc"
check "bad session_id (slash) -> no reminder" "" "$out"
rm -rf "$repo"

# A '..'-bearing id is rejected too; and a valid neighbor still fires (the guard
# must not over-reject real UUIDs).
repo="$(mk_repo)"; seed "$repo" GOODSID 4000 600
check "bad session_id (..) -> no reminder"    "" "$(run_cc "$repo" "../escape")"
check "valid session_id still flags"          yes "$(has "$(run_cc "$repo" GOODSID)" "<system-reminder>")"
rm -rf "$repo"

finish
