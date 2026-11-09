#!/usr/bin/env bash
# handoff_ctx_check.sh x issue #173: nudge cadence, live usage from the
# transcript, and a window that is never guessed.
#   * first nudge at HANDOFF_CTX_THRESHOLD_PCT (default 30), then one more at
#     every HANDOFF_CTX_STEP_PCT (default 5) step: 30, 35, 40, never 33;
#   * uncapped by default, HANDOFF_CTX_MAX_FLAGS=1 restores once-only;
#   * usage from the transcript's last main-chain usage record of THIS
#     session (resumed-session, sidechain and <synthetic> lines ignored);
#   * window: status line, then the model table, else "window unknown" with no
#     percentage, and only then does the absolute token gate apply.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CC="$REPO_ROOT/bin/handoff_ctx_check.sh"
command -v jq >/dev/null 2>&1 || { echo "handoff_ctx_check.sh (cadence)"; skip "jq missing: hook parses payload with jq"; finish; exit; }

bd() { printf '%s/.claude/handoff_backups' "$1"; }
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
# Stop-hook token record only (bytes ledger). Args: <repo> <sid> <tokens>
seed_tok() {
  local d; d="$(bd "$1")"; must mkdir -p "$d"
  must printf '4000' > "$d/.ctx_$2"
  must printf '%s' "$3" > "$d/.ctx_tokens_$2"
}
# Run with the window pinned (env) or un-pinned (pass HANDOFF_CTX_WINDOW_TOKENS=).
# HOME is jailed to the repo so no host file participates.
run_cc() {  # <repo> <sid> [ENV=VAL ...]
  local repo="$1" sid="$2"; shift 2
  ( cd "$repo" && env HOME="$repo" HANDOFF_CTX_WINDOW_TOKENS= "$@" \
      bash "$CC" <<<"{\"session_id\":\"$sid\"}" 2>/dev/null )
}
# Same, with a transcript_path in the payload.
run_tx() {  # <repo> <sid> <transcript> [ENV=VAL ...]
  local repo="$1" sid="$2" tx="$3"; shift 3
  ( cd "$repo" && env HOME="$repo" HANDOFF_CTX_WINDOW_TOKENS= "$@" \
      bash "$CC" <<<"{\"session_id\":\"$sid\",\"transcript_path\":\"$tx\"}" 2>/dev/null )
}
# One assistant transcript line. Args: <sid> <sidechain> <model> <in> <cache_read> <cache_create>
tx_line() {
  printf '{"type":"assistant","sessionId":"%s","isSidechain":%s,"message":{"model":"%s","usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"output_tokens":77777}}}\n' "$@"
}

echo "handoff_ctx_check.sh: cadence 30% then every 5% (#173)"

PIN=HANDOFF_CTX_WINDOW_TOKENS=1000000

# --- First nudge at 30%, not 10%, on a 1M window ------------------------------
repo="$(mk_repo)"; cleanup_on_exit "$repo"; seed_tok "$repo" F10 100000
check "1M window, 100k (10%) -> silent"  "" "$(run_cc "$repo" F10 "$PIN")"
seed_tok "$repo" F10 290000
check "1M window, 290k (29%) -> silent"  "" "$(run_cc "$repo" F10 "$PIN")"
seed_tok "$repo" F10 300000
out="$(run_cc "$repo" F10 "$PIN")"
check "1M window, 300k -> first nudge at 30%" yes "$(has "$out" "~30% of a 1000000-token window")"
check "first nudge names the next step"       yes "$(has "$out" "Next reminder at 30% + 5 = 35%")"

# --- Re-flag at 35 and 40, not at 33 or 38 (same session, uncapped default) --
seed_tok "$repo" F10 330000
check "33% after a 30% nudge -> silent"  "" "$(run_cc "$repo" F10 "$PIN")"
seed_tok "$repo" F10 350000
check "35% -> re-flags"                  yes "$(has "$(run_cc "$repo" F10 "$PIN")" "~35% of a")"
seed_tok "$repo" F10 380000
check "38% after a 35% nudge -> silent"  "" "$(run_cc "$repo" F10 "$PIN")"
seed_tok "$repo" F10 400000
check "40% -> re-flags"                  yes "$(has "$(run_cc "$repo" F10 "$PIN")" "~40% of a")"
# A jump over several steps fires once, on the step it lands on.
seed_tok "$repo" F10 570000
check "jump to 57% -> one nudge"         yes "$(has "$(run_cc "$repo" F10 "$PIN")" "Next reminder at 55% + 5 = 60%")"
check "57% again -> silent"              "" "$(run_cc "$repo" F10 "$PIN")"
check "flag file: one line per nudge (30,35,40,55)" 4 "$(grep -c '' "$(bd "$repo")/.ctx_flagged_F10")"
check "flag file: step recorded with progress" "4000 55" "$(tail -n 1 "$(bd "$repo")/.ctx_flagged_F10")"

# --- Uncapped by default, capped with HANDOFF_CTX_MAX_FLAGS=1 ----------------
repo="$(mk_repo)"; cleanup_on_exit "$repo"; seed_tok "$repo" CAP 300000
run_cc "$repo" CAP "$PIN" HANDOFF_CTX_MAX_FLAGS=1 >/dev/null
seed_tok "$repo" CAP 350000
check "MAX_FLAGS=1 -> 35% silent"        "" "$(run_cc "$repo" CAP "$PIN" HANDOFF_CTX_MAX_FLAGS=1)"
check "default (uncapped) -> 35% fires"  yes "$(has "$(run_cc "$repo" CAP "$PIN")" "<system-reminder>")"
repo="$(mk_repo)"; cleanup_on_exit "$repo"; seed_tok "$repo" CAPW 300000
check "MAX_FLAGS=1 -> says it will not re-fire" yes \
  "$(has "$(run_cc "$repo" CAPW "$PIN" HANDOFF_CTX_MAX_FLAGS=1)" "will not re-fire this session")"

# --- Knobs: threshold and step move the grid ---------------------------------
repo="$(mk_repo)"; cleanup_on_exit "$repo"; seed_tok "$repo" KN 200000
check "THRESHOLD_PCT=20 -> 20% fires" yes "$(has "$(run_cc "$repo" KN "$PIN" HANDOFF_CTX_THRESHOLD_PCT=20)" "~20% of a")"
seed_tok "$repo" KN 290000
check "STEP_PCT=10 -> 29% silent after 20" "" "$(run_cc "$repo" KN "$PIN" HANDOFF_CTX_THRESHOLD_PCT=20 HANDOFF_CTX_STEP_PCT=10)"
seed_tok "$repo" KN 300000
check "STEP_PCT=10 -> 30% fires after 20" yes "$(has "$(run_cc "$repo" KN "$PIN" HANDOFF_CTX_THRESHOLD_PCT=20 HANDOFF_CTX_STEP_PCT=10)" "<system-reminder>")"
repo="$(mk_repo)"; cleanup_on_exit "$repo"; seed_tok "$repo" KB 300000
check "STEP_PCT=bogus -> falls back to 5" yes \
  "$(has "$(run_cc "$repo" KB "$PIN" HANDOFF_CTX_STEP_PCT=5x)" "Next reminder at 30% + 5 = 35%")"

# --- A drop below the last step (compaction) is a fresh crossing -------------
repo="$(mk_repo)"; cleanup_on_exit "$repo"; seed_tok "$repo" DROP 320000
must printf '4000 50\n' > "$(bd "$repo")/.ctx_flagged_DROP"
check "dropped from step 50 to 32% -> fires" yes "$(has "$(run_cc "$repo" DROP "$PIN")" "~32% of a")"

echo "handoff_ctx_check.sh: usage measured from the transcript (#173)"

# --- Fixture: an earlier session's line (resumed transcript), this session's
#     real usage, then a later sidechain line and a <synthetic> placeholder,
#     both of which must be ignored. 100 + 250000 + 49900 = 300000 (30% of 1M);
#     output_tokens (77777) is not context and must not be added. ------------
repo="$(mk_repo)"; cleanup_on_exit "$repo"; must mkdir -p "$(bd "$repo")"
tx="$repo/transcript.jsonl"
{
  tx_line OLDSESS false claude-opus-5-5 10 800000 90000
  printf '{"type":"user","sessionId":"TX","message":{"content":"usage"}}\n'
  tx_line TX false claude-opus-5-5 100 250000 49900
  tx_line TX true  claude-haiku-4-5 5 4000 1000
  tx_line TX false '<synthetic>' 0 0 0
  tx_line OLDSESS false claude-opus-5-5 10 900000 0
} > "$tx"
out="$(run_tx "$repo" TX "$tx")"
check "transcript usage -> fires with no Stop-hook files" yes "$(has "$out" "<system-reminder>")"
check "transcript usage -> this session's sum (300000)"   yes "$(has "$out" "~300000 tokens (measured from the transcript's last usage record)")"
check "transcript usage -> window from transcript model"  yes "$(has "$out" "1000000-token window (from this hook's model table for claude-opus-5-5")"
check "transcript usage -> 30%"                           yes "$(has "$out" "~30% of a")"
check "transcript usage -> output_tokens not added"       no  "$(has "$out" "377777")"
check "transcript usage -> no bytes/4 estimate"           no  "$(has "$out" "ESTIMATED")"
check "transcript usage -> token ledger flag file"        yes "$([[ -f "$(bd "$repo")/.ctx_flagged_tok_TX" ]] && echo yes || echo no)"

# Transcript beats a stale Stop-hook record (which alone would be silent).
repo="$(mk_repo)"; cleanup_on_exit "$repo"; seed_tok "$repo" TX 1000
out="$(run_tx "$repo" TX "$tx")"
check "transcript beats stale .ctx_tokens_" yes "$(has "$out" "~300000 tokens (measured from the transcript")"

# Byte heuristic is the last fallback and labeled so (no usage anywhere).
repo="$(mk_repo)"; cleanup_on_exit "$repo"; must mkdir -p "$(bd "$repo")"
must printf '800000' > "$(bd "$repo")/.ctx_EST"
printf '{"type":"user","sessionId":"EST","message":{"content":"hi"}}\n' > "$repo/t.jsonl"
out="$(run_tx "$repo" EST "$repo/t.jsonl")"
check "no usage record -> bytes/4 labeled last fallback" yes "$(has "$out" "ESTIMATED from transcript byte size (bytes/4), the last fallback")"

echo "handoff_ctx_check.sh: window source order, never guessed (#173)"

# Status line window beats the model table: sl says 500k, model says 1M.
repo="$(mk_repo)"; cleanup_on_exit "$repo"; must mkdir -p "$(bd "$repo")"
must printf 'window=500000\n' > "$(bd "$repo")/.ctx_sl_TX"
out="$(run_tx "$repo" TX "$tx")"
check "sl window beats model table -> 60% of 500000" yes "$(has "$out" "~60% of a 500000-token window (from the status line's context_window_size")"
# A status line cache past the age horizon is not live: the table applies.
must touch -t 202001010000 "$(bd "$repo")/.ctx_sl_TX"
must rm -f "$(bd "$repo")/.ctx_flagged_tok_TX"
out="$(run_tx "$repo" TX "$tx")"
check "stale sl window -> model table instead" yes "$(has "$out" "~30% of a 1000000-token window (from this hook's model table")"

# Model not in the table -> window unknown: no percentage anywhere.
repo="$(mk_repo)"; cleanup_on_exit "$repo"; must mkdir -p "$(bd "$repo")"
tx_line UNK false claude-opus-9-9 100 250000 49900 > "$repo/u.jsonl"
out="$(run_tx "$repo" UNK "$repo/u.jsonl")"
check "unlisted model -> window unknown"           yes "$(has "$out" "window unknown (model id claude-opus-9-9 is not in this hook's model table)")"
check "unknown window -> no percentage anywhere"   no  "$(has "$out" "%")"
check "unknown window -> fires on the token gate"  yes "$(has "$out" "<system-reminder>")"
check "unknown window -> cooldown promise, no step" yes "$(has "$out" "tokens of context growth")"

# The absolute token gate fires only when the window is unknown.
repo="$(mk_repo)"; cleanup_on_exit "$repo"; must mkdir -p "$(bd "$repo")"
tx_line AB false claude-opus-5-5 100 150000 0 > "$repo/a.jsonl"
check "known window, 150k (15%) -> token gate does not fire" "" "$(run_tx "$repo" AB "$repo/a.jsonl")"
tx_line AB false claude-opus-9-9 100 150000 0 > "$repo/a.jsonl"
check "unknown window, 150k -> token gate fires" yes "$(has "$(run_tx "$repo" AB "$repo/a.jsonl")" "window unknown")"

finish
