#!/usr/bin/env bash
# handoff_ctx_check.sh x the statusline cache (.ctx_sl_<sid>, written by
# handoff_statusline.sh): the hook must PREFER Claude Code's own numbers when
# the cache is present and fresh, while (a) the HANDOFF_CTX_WINDOW_TOKENS env
# pin still beats everything (the tested contract), (b) malformed/stale cache
# values degrade to the pre-statusline chain exactly, and (c) the opt-out
# HANDOFF_CTX_NO_STATUSLINE=1 restores today's behavior verbatim.
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
# Window pinned 1000, threshold 30% -> 300. Stop says 100 (silent on its own);
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
# Auto mode, HOME jailed. The session's model (claude-sonnet-4-5) is a 200k
# model in the table; Stop measured 90k tokens. With sl window=1M: 90k/1M =
# 9% < 30% -> silent. Same seed WITHOUT the sl file: the table's 200k ->
# 90k/200k = 45% -> fires. The pair proves the sl window beats the table.
repo="$(mk_repo)"; seed "$repo" WIN 4000 90000; seed_sl "$repo" WIN "window=1000000"
printf 'claude-sonnet-4-5\n' > "$repo/.claude/handoff_backups/.ctx_model_WIN"
out="$(run_cc_auto "$repo" WIN)"
check "sl window 1M beats model table -> 90k silent" "" "$out"
rm -rf "$repo"
repo="$(mk_repo)"; seed "$repo" WIN2 4000 90000
printf 'claude-sonnet-4-5\n' > "$repo/.claude/handoff_backups/.ctx_model_WIN2"
out="$(run_cc_auto "$repo" WIN2)"
check "no sl -> model table 200k -> 90k fires" yes "$(has "$out" "~45% of a 200000-token window (from this hook's model table")"
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

# A stale sl cache's pct AND window are dropped with its tokens (same payload
# snapshot; PR #177 review: a kept window against a newer count printed
# 125%). "Stale" here is the older-than-the-tokens-file guard, so the age
# horizon is lifted. The Stop hook's 150000 with no model -> window unknown.
repo="$(mk_repo)"; seed "$repo" STPCT 4000 150000
seed_sl "$repo" STPCT "window=100000" "tokens=600" "pct=73"
must touch -t 202001010000 "$repo/.claude/handoff_backups/.ctx_sl_STPCT"
must touch "$repo/.claude/handoff_backups/.ctx_tokens_STPCT"
out="$(run_cc_auto "$repo" STPCT HANDOFF_CTX_SL_MAX_AGE_SECS=2000000000)"
check "stale sl -> its window dropped too (unknown)" yes "$(has "$out" "window unknown")"
check "stale sl -> no 150% against its old window"   no  "$(has "$out" "%")"
rm -rf "$repo"

# --- No CC figure + window from the model table -> source named --------------
# The desktop-app case: no sl cache, window from .ctx_model_ via the table.
# The pct is reported with where the window came from and what was measured.
repo="$(mk_repo)"; seed "$repo" GUESS 4000 150000
printf 'claude-opus-5-5\n' > "$repo/.claude/handoff_backups/.ctx_model_GUESS"
out="$(run_cc_auto "$repo" GUESS HANDOFF_CTX_THRESHOLD_PCT=10)"
check "table window -> pct of 1M"           yes "$(has "$out" "~15% of a 1000000-token window")"
check "table window -> names table + model" yes "$(has "$out" "from this hook's model table for claude-opus-5-5")"
check "table window -> names token source"  yes "$(has "$out" "measured by the Stop hook")"
check "table window -> flag line has pct"   yes "$(has "$out" "15% of context used")"
rm -rf "$repo"
# An env-pinned window is the user's own number, not a guess: no label.
repo="$(mk_repo)"; seed "$repo" PINNED 4000 600
out="$(run_cc "$repo" PINNED)"
check "env-pinned window -> no estimate label" no "$(has "$out" "estimated")"
rm -rf "$repo"

# --- F4: a used_percentage above 100 is not a real reading -> rejected ------
# The cache can carry a stale/malformed pct (e.g. pct=150.9); it must be
# treated as absent so the computed fallback takes over, instead of reporting
# an impossible ~150%.
repo="$(mk_repo)"; seed "$repo" PCTOVER 4000 600
seed_sl "$repo" PCTOVER "window=1000" "tokens=600" "pct=150.9"
out="$(run_cc_auto "$repo" PCTOVER)"
check "pct>100 rejected -> falls back to computed 60%" yes "$(has "$out" "~60% of a 1000-token window")"
check "pct>100 rejected -> no impossible 150% shown"   no  "$(has "$out" "150")"
rm -rf "$repo"

# Boundary: pct exactly 100 (any zero-padded decimal form) is still valid.
repo="$(mk_repo)"; seed "$repo" PCT100 4000 600
seed_sl "$repo" PCT100 "window=1000" "tokens=600" "pct=100.00"
out="$(run_cc_auto "$repo" PCT100)"
check "pct=100.00 accepted" yes "$(has "$out" "~100% of a 1000-token window")"
rm -rf "$repo"

# --- F5 / #173: no guessed window is ever printed ---------------------------
# (a) No model file, no ~/.claude.json, measured usage above 200k. The old
#     chain "ratcheted" a guessed 200k to 1M; now the window is unknown and
#     the absolute gate (250k >= 100k) fires with no percentage.
repo="$(mk_repo)"; seed "$repo" RATCHNOTE 4000 250000
out="$(run_cc_auto "$repo" RATCHNOTE)"
check "no evidence -> window unknown"   yes "$(has "$out" "window unknown (no status line, no HANDOFF_CTX_WINDOW_TOKENS, no model id recorded)")"
check "no evidence -> no percentage"    no  "$(has "$out" "%")"
rm -rf "$repo"

# (b) ~/.claude.json lastModelUsage is not consulted (another project's model).
repo="$(mk_repo)"; seed "$repo" CJSONNOTE 4000 150000
must printf '%s' '{"projects":{"/elsewhere":{"lastModelUsage":{"claude-fable-5":{"count":1}}}}}' \
  > "$repo/.claude.json"
out="$(run_cc_auto "$repo" CJSONNOTE)"
check "claude.json ignored -> window unknown" yes "$(has "$out" "window unknown")"
check "claude.json ignored -> no 1M window"   no  "$(has "$out" "1000000-token window")"
rm -rf "$repo"

# (c) Measured usage contradicts the table (claude-sonnet-4-5 is 200k, 250k
#     measured): unknown, never widened.
repo="$(mk_repo)"; seed "$repo" RATCHMODEL 4000 250000
printf 'claude-sonnet-4-5\n' > "$repo/.claude/handoff_backups/.ctx_model_RATCHMODEL"
out="$(run_cc_auto "$repo" RATCHMODEL)"
check "contradicted table -> window unknown" yes "$(has "$out" "exceed the 200000-token window listed for claude-sonnet-4-5")"
check "contradicted table -> no 1M"          no  "$(has "$out" "1000000-token window")"
rm -rf "$repo"

# (d) Cache has pct= but no window=: the cached pct must still be used (no
# "~0% (estimated)" and no false claim that used_percentage has not reached
# the hook, since it plainly has).
repo="$(mk_repo)"; seed "$repo" PCTNOWIN 4000 100
seed_sl "$repo" PCTNOWIN "tokens=90000" "pct=42"
out="$(run_cc_auto "$repo" PCTNOWIN HANDOFF_CTX_THRESHOLD_PCT=10)"
check "pct without window -> uses cached 42%" yes "$(has "$out" "~42% used (Claude Code's own used_percentage; the window size was not reported)")"
check "pct without window -> not labelled estimated" no "$(has "$out" "estimated")"
check "pct without window -> not the bogus ~0%" no "$(has "$out" "~0%")"
rm -rf "$repo"

finish
