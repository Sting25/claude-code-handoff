#!/usr/bin/env bash
# handoff_ctx_check.sh x the statusline cache (.ctx_sl_<sid>, written by
# handoff_statusline.sh): the hook must PREFER Claude Code's own numbers when
# the cache is present and fresh, while (a) the HANDOFF_CTX_WINDOW_TOKENS env
# pin still beats everything (the tested contract), (b) malformed/stale cache
# values degrade to the pre-statusline chain exactly, and (c) the opt-out
# HANDOFF_CTX_NO_STATUSLINE=1 restores today's behavior verbatim.
# (tests/test_ctx_check.sh passing UNMODIFIED is the other half of the
# acceptance gate — the sl-absent chain is byte-for-byte unchanged.)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CC="$REPO_ROOT/bin/handoff_ctx_check.sh"
command -v jq >/dev/null 2>&1 || { echo "handoff_ctx_check.sh (statusline)"; skip "jq missing — hook parses payload with jq"; finish; exit; }

# Seed a session's Stop-hook sidecars. Args: <repo> <sid> <bytes> [tokens]
seed() {
  local repo="$1" sid="$2" bytes="$3" tokens="${4:-}"
  local bd="$repo/.claude/handoff_backups"; mkdir -p "$bd"
  printf '%s' "$bytes" > "$bd/.ctx_${sid}"
  [[ -n "$tokens" ]] && printf '%s' "$tokens" > "$bd/.ctx_tokens_${sid}"
}
# Seed the statusline cache. Args: <repo> <sid> <content...>
seed_sl() {
  local repo="$1" sid="$2"; shift 2
  printf '%s\n' "$@" > "$repo/.claude/handoff_backups/.ctx_sl_${sid}"
}

# Run the hook with the window pinned to 1000 (mirrors test_ctx_check.sh).
run_cc() {  # <repo> <sid> [ENV=VAL ...]
  local repo="$1" sid="$2"; shift 2
  ( cd "$repo" && env HANDOFF_CTX_WINDOW_TOKENS=1000 "$@" \
      bash "$CC" <<<"{\"session_id\":\"$sid\"}" 2>/dev/null )
}
# Run with the window UN-pinned (auto-detect) and HOME jailed to the repo so
# the host's real ~/.claude.json can't leak into the fallback probes.
run_cc_auto() {  # <repo> <sid> [ENV=VAL ...]
  local repo="$1" sid="$2"; shift 2
  ( cd "$repo" && env HANDOFF_CTX_WINDOW_TOKENS= HOME="$repo" "$@" \
      bash "$CC" <<<"{\"session_id\":\"$sid\"}" 2>/dev/null )
}

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

echo "handoff_ctx_check.sh — statusline cache preference"

# --- sl tokens over threshold, Stop tokens under -> sl wins, fires -----------
# Window pinned 1000, threshold 40% -> 400. Stop says 100 (silent on its own);
# sl says 600. The sl file is written AFTER the tokens file, so it is fresh.
repo="$(mk_repo)"; seed "$repo" SLW 4000 100; seed_sl "$repo" SLW "tokens=600"
out="$(run_cc "$repo" SLW)"
check "sl tokens preferred -> fires"      yes "$(has "$out" "<system-reminder>")"
check "sl tokens preferred -> 600 tokens" yes "$(has "$out" "600 tokens")"
check "sl tokens preferred -> 60%"        yes "$(has "$out" "60%")"
rm -rf "$repo"

# --- NEGATIVE CONTROL: sl under threshold, Stop over, sl fresher -> silent ---
# Proves the sl count REPLACES the Stop count (not max-of-both): Stop alone
# would fire at 600/1000.
repo="$(mk_repo)"; seed "$repo" SLU 4000 600; seed_sl "$repo" SLU "tokens=100"
out="$(run_cc "$repo" SLU)"
check "sl under + stop over -> silent" "" "$out"
rm -rf "$repo"

# --- Env-pin regression contract: HANDOFF_CTX_WINDOW_TOKENS beats sl window --
# Pin 1000; sl reports CC's window as 1M and 600 tokens used. If the sl window
# ever won over the pin, 600/1000000 would be far below threshold -> silent.
# The contract: fires at 60% of the PINNED 1000-token window.
repo="$(mk_repo)"; seed "$repo" PIN 4000 100
seed_sl "$repo" PIN "window=1000000" "tokens=600"
out="$(run_cc "$repo" PIN)"
check "env pin beats sl window -> fires"      yes "$(has "$out" "<system-reminder>")"
check "env pin beats sl window -> 1000-token" yes "$(has "$out" "a 1000-token window")"
check "env pin beats sl window -> 60%"        yes "$(has "$out" "60%")"
rm -rf "$repo"

# --- Malformed sl values -> pre-statusline chain (Stop tokens) ---------------
repo="$(mk_repo)"; seed "$repo" MAL 4000 600
seed_sl "$repo" MAL "window=notanumber" "tokens=12xy" "garbage line"
out="$(run_cc "$repo" MAL)"
check "malformed sl -> stop tokens fire (600)" yes "$(has "$out" "600 tokens")"
rm -rf "$repo"

# --- Stale sl cache (statusline unwired mid-session) -> Stop tokens win ------
# sl says 600 (would fire) but its mtime is forced OLDER than the tokens
# file; the freshness guard must drop it -> Stop's 100 -> silent.
repo="$(mk_repo)"; seed "$repo" STALE 4000 100
seed_sl "$repo" STALE "tokens=600"
must touch -t 202001010000 "$repo/.claude/handoff_backups/.ctx_sl_STALE"
must touch "$repo/.claude/handoff_backups/.ctx_tokens_STALE"
out="$(run_cc "$repo" STALE)"
check "stale sl -> stop tokens win -> silent" "" "$out"
rm -rf "$repo"

# --- HANDOFF_CTX_NO_STATUSLINE=1 -> sl cache ignored entirely ----------------
repo="$(mk_repo)"; seed "$repo" OPTOUT 4000 100; seed_sl "$repo" OPTOUT "tokens=600"
out="$(run_cc "$repo" OPTOUT HANDOFF_CTX_NO_STATUSLINE=1)"
check "NO_STATUSLINE=1 -> sl ignored -> silent" "" "$out"
rm -rf "$repo"

# --- Window adoption: sl window replaces the model-regex guesswork -----------
# Auto mode, no model file, no .claude.json (HOME jailed). Stop measured 90k
# tokens. With sl window=1M: 90k/1M = 9% < 40% -> silent. Same seed WITHOUT
# the sl file: auto-detect falls to 200k -> 90k/200k = 45% -> fires. The pair
# proves the sl window (not the tokens) is what changed the outcome.
repo="$(mk_repo)"; seed "$repo" WIN 4000 90000; seed_sl "$repo" WIN "window=1000000"
out="$(run_cc_auto "$repo" WIN)"
check "sl window 1M adopted -> 90k silent" "" "$out"
rm -rf "$repo"
repo="$(mk_repo)"; seed "$repo" WIN2 4000 90000
out="$(run_cc_auto "$repo" WIN2)"
check "no sl -> 200k window -> 90k fires" yes "$(has "$out" "200000-token window")"
rm -rf "$repo"

# --- Ratchet never applies against a statusline-reported window --------------
# sl reports window=500000 and a MEASURED 250000 tokens (>200k). The auto
# ratchet would widen a guessed window to 1M; CC's own 500k report must stand:
# 250k/500k = 50% of a 500000-token window.
repo="$(mk_repo)"; seed "$repo" NORAT 4000 100
seed_sl "$repo" NORAT "window=500000" "tokens=250000"
out="$(run_cc_auto "$repo" NORAT)"
check "sl window not ratcheted -> 500000 window" yes "$(has "$out" "500000-token window")"
check "sl window not ratcheted -> 50%"           yes "$(has "$out" "50%")"
check "sl window not ratcheted -> no 1M"         no  "$(has "$out" "1000000-token window")"
rm -rf "$repo"

# --- Claude Code's own used_percentage is what gets reported -----------------
# sl reports window=1000, tokens=600, pct=73. Our math would say 60%; CC's
# figure is ground truth, so the reminder must say 73% (deliberately
# different numbers, so the assertion can tell the two sources apart).
repo="$(mk_repo)"; seed "$repo" CCPCT 4000 100
seed_sl "$repo" CCPCT "window=1000" "tokens=600" "pct=73.4"
out="$(run_cc_auto "$repo" CCPCT)"
check "sl pct reported -> 73%"          yes "$(has "$out" "~73% of a 1000-token window")"
check "sl pct reported -> not our 60%"  no  "$(has "$out" "60%")"
check "sl pct reported -> no estimate"  no  "$(has "$out" "estimated")"
rm -rf "$repo"

# Env pin beats CC's pct: the user chose a different budget, so report the
# pinned-window math (600/1000 = 60%), not CC's 73.
repo="$(mk_repo)"; seed "$repo" PINPCT 4000 100
seed_sl "$repo" PINPCT "window=500000" "tokens=600" "pct=73"
out="$(run_cc "$repo" PINPCT)"
check "env pin -> computed 60%"         yes "$(has "$out" "~60% of a 1000-token window")"
check "env pin -> CC pct not used"      no  "$(has "$out" "73%")"
rm -rf "$repo"

# A stale sl cache's pct is dropped with its tokens (same payload snapshot).
repo="$(mk_repo)"; seed "$repo" STPCT 4000 600
seed_sl "$repo" STPCT "window=1000" "tokens=600" "pct=73"
must touch -t 202001010000 "$repo/.claude/handoff_backups/.ctx_sl_STPCT"
must touch "$repo/.claude/handoff_backups/.ctx_tokens_STPCT"
out="$(run_cc_auto "$repo" STPCT)"
check "stale sl pct dropped -> 60%"     yes "$(has "$out" "~60% of a 1000-token window")"
check "stale sl pct dropped -> not 73"  no  "$(has "$out" "73%")"
rm -rf "$repo"

# --- No CC figure + window guessed from the model id -> labelled estimate ---
# The desktop-app case: no sl cache, auto window from .ctx_model_. The pct is
# still reported but must say it is an estimate and name the model it came from.
repo="$(mk_repo)"; seed "$repo" GUESS 4000 150000
printf 'claude-opus-5-5\n' > "$repo/.claude/handoff_backups/.ctx_model_GUESS"
out="$(run_cc_auto "$repo" GUESS HANDOFF_CTX_THRESHOLD_PCT=10)"
check "guessed window -> labelled estimated" yes "$(has "$out" "~15% (estimated) of a 1000000-token window")"
check "guessed window -> names the model"    yes "$(has "$out" "inferred from the model id (claude-opus-5-5)")"
check "guessed window -> flag line labelled" yes "$(has "$out" "15% (estimated) of context used")"
rm -rf "$repo"
# An env-pinned window is the user's own number, not a guess: no label.
repo="$(mk_repo)"; seed "$repo" PINNED 4000 600
out="$(run_cc "$repo" PINNED)"
check "env-pinned window -> no estimate label" no "$(has "$out" "estimated")"
rm -rf "$repo"

finish
