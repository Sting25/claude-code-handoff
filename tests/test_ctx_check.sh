#!/usr/bin/env bash
# Behavioral coverage for handoff_ctx_check.sh (the UserPromptSubmit hook that
# flags a /handoff moment once context crosses a threshold). This script had no
# tests. We pin the window via HANDOFF_CTX_WINDOW_TOKENS so the auto-detect
# path never participates, then drive the threshold / fallback / mode /
# cooldown branches directly. A final section un-pins the window (empty
# override + HOME jailed to the fixture repo) to drive the model-table
# window-detection branches (issue #173) hermetically.
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
# window 1000, pct 40 -> threshold 400 tokens; 100 tokens is well under.
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

# --- Cooldown (uncapped via MAX_FLAGS=0 so the cooldown, not the cap, is what
#     we're exercising here) -----------------------------------------------
# current_bytes 200000, flagged at 200000, cooldown 100KB(=102400):
# 200000 < 200000+102400 -> suppressed.
repo="$(mk_repo)"; seed "$repo" CD 200000 600 200000
out="$(run_cc "$repo" CD HANDOFF_CTX_MAX_FLAGS=0)"
check "within cooldown -> suppressed" "" "$out"
rm -rf "$repo"

# Beyond cooldown: flagged long ago (0) -> 200000 >= 0+102400 -> re-fires.
repo="$(mk_repo)"; seed "$repo" CD2 200000 600 0
out="$(run_cc "$repo" CD2 HANDOFF_CTX_MAX_FLAGS=0)"
check "beyond cooldown -> re-fires (uncapped)" yes "$(has "$out" "<system-reminder>")"
rm -rf "$repo"

# --- Per-session cap --------------------------------------------------------
# Issue #173: suggest mode is uncapped by default (the 5-point step spaces the
# nudges instead). HANDOFF_CTX_MAX_FLAGS=1 restores the old once-only cap: a
# session that has already flagged once stays silent, even far past the
# cooldown.
repo="$(mk_repo)"; seed "$repo" CAP1 200000 600 0   # one prior flag, way past cooldown
out="$(run_cc "$repo" CAP1)"
check "suggest default uncapped -> re-fires" yes "$(has "$out" "<system-reminder>")"
seed "$repo" CAP1 200000 600 0
out="$(run_cc "$repo" CAP1 HANDOFF_CTX_MAX_FLAGS=1)"
check "MAX_FLAGS=1 caps at one flag" "" "$out"
rm -rf "$repo"

# act mode is uncapped by default: same setup re-fires (autonomous self-refresh).
repo="$(mk_repo)"; seed "$repo" CAPACT 200000 600 0
out="$(run_cc "$repo" CAPACT HANDOFF_CTX_REMINDER_MODE=act)"
check "act mode uncapped -> re-fires" yes "$(has "$out" "<system-reminder>")"
rm -rf "$repo"

# Explicit MAX_FLAGS=2 allows a second flag but not a third. Two prior flags
# (two lines) past the cooldown -> capped.
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"
seed "$repo" CAP2 200000 600
printf '0\n0\n' > "$bd/.ctx_flagged_CAP2"            # two prior flags
out="$(run_cc "$repo" CAP2 HANDOFF_CTX_MAX_FLAGS=2)"
check "MAX_FLAGS=2 with 2 prior -> capped" "" "$out"
# One prior flag, MAX_FLAGS=2, past cooldown -> still allowed.
printf '0\n' > "$bd/.ctx_flagged_CAP2"
out="$(run_cc "$repo" CAP2 HANDOFF_CTX_MAX_FLAGS=2)"
check "MAX_FLAGS=2 with 1 prior -> fires" yes "$(has "$out" "<system-reminder>")"
rm -rf "$repo"

# The flag file accumulates one line per flag (so the cap can count them).
repo="$(mk_repo)"; seed "$repo" ACCUM 200000 600 0
run_cc "$repo" ACCUM HANDOFF_CTX_MAX_FLAGS=0 >/dev/null    # was 1 line, fires -> 2 lines
lines="$(grep -c '' "$repo/.claude/handoff_backups/.ctx_flagged_ACCUM" 2>/dev/null || echo 0)"
check "flag file appends (1 prior + 1 new = 2 lines)" 2 "$lines"
rm -rf "$repo"

# First crossing always fires regardless of byte size (no flag file yet).
repo="$(mk_repo)"; seed "$repo" FIRST 10 600
out="$(run_cc "$repo" FIRST)"
check "first crossing -> fires despite tiny bytes" yes "$(has "$out" "<system-reminder>")"
rm -rf "$repo"

# --- Re-fire wording matches the cap (audit 2026-07-17) ----------------------
# MAX_FLAGS=1: the first nudge is also the last, so it must say so, not
# promise a repeat that will never come.
repo="$(mk_repo)"; seed "$repo" WORD1 4000 600
out="$(run_cc "$repo" WORD1 HANDOFF_CTX_MAX_FLAGS=1)"
check "capped final nudge says it won't re-fire"   yes "$(has "$out" "will not re-fire this session")"
check "capped final nudge drops cooldown promise"  no  "$(has "$out" "KB of transcript growth")"
rm -rf "$repo"
# Uncapped (MAX_FLAGS=0) with a known window: the next 5-point step is the
# real promise (60% sits on step 60, next 65). The KB cooldown promise is for
# an unknown window only (see test_ctx_check_cadence.sh).
repo="$(mk_repo)"; seed "$repo" WORD0 4000 600
out="$(run_cc "$repo" WORD0 HANDOFF_CTX_MAX_FLAGS=0)"
check "uncapped nudge states the next step"        yes "$(has "$out" "Next reminder at 60% + 5 = 65%")"
check "known window -> no KB cooldown promise"     no  "$(has "$out" "KB of transcript growth")"
check "uncapped nudge has no cap-reached text"     no  "$(has "$out" "will not re-fire this session")"
rm -rf "$repo"
# MAX_FLAGS=2, one prior flag: this (second) nudge reaches the cap -> final.
repo="$(mk_repo)"; seed "$repo" WORD2 200000 600 0
out="$(run_cc "$repo" WORD2 HANDOFF_CTX_MAX_FLAGS=2)"
check "last-of-N nudge announces the cap"          yes "$(has "$out" "will not re-fire this session")"
rm -rf "$repo"

# --- THRESHOLD_PCT override changes the gate --------------------------------
# 600 tokens / 1000 window = 60%. With threshold 70% it should NOT fire.
repo="$(mk_repo)"; seed "$repo" PCT 4000 600
out="$(run_cc "$repo" PCT HANDOFF_CTX_THRESHOLD_PCT=70)"
check "threshold 70% -> 60% does not fire" "" "$out"
rm -rf "$repo"

# --- Malformed THRESHOLD_PCT / COOLDOWN_KB fall back to defaults -------------
# (audit 2026-07-17) A '%'-suffixed threshold previously aborted the hook at
# the $((...)) arithmetic under set -e — nudge silently disabled every session.
# With the fallback to the default 30, 600/1000 = 60% must still fire.
repo="$(mk_repo)"; seed "$repo" BADPCT 4000 600
out="$(run_cc "$repo" BADPCT HANDOFF_CTX_THRESHOLD_PCT=40%)"
check "THRESHOLD_PCT='40%' -> falls back to 30, fires" yes "$(has "$out" "<system-reminder>")"
rm -rf "$repo"

# A negative threshold previously passed straight through and made the gate
# always-fire. It now falls back to 30: 100/1000 = 10% must NOT fire.
repo="$(mk_repo)"; seed "$repo" NEGPCT 4000 100
out="$(run_cc "$repo" NEGPCT HANDOFF_CTX_THRESHOLD_PCT=-40)"
check "THRESHOLD_PCT=-40 -> falls back to 30, no fire" "" "$out"
rm -rf "$repo"

# Malformed COOLDOWN_KB ("100KB"): with a prior flag far in the past and the
# cap lifted, the re-fire must go through the default 100KB cooldown — neither
# aborting nor emitting a garbled "...100KBKB of growth" reminder.
repo="$(mk_repo)"; seed "$repo" BADCD 200000 600 0
out="$(run_cc "$repo" BADCD HANDOFF_CTX_MAX_FLAGS=0 HANDOFF_CTX_COOLDOWN_KB=100KB)"
check "COOLDOWN_KB='100KB' -> falls back, fires"     yes "$(has "$out" "<system-reminder>")"
check "COOLDOWN_KB='100KB' -> reminder not garbled"  no  "$(has "$out" "100KBKB")"
rm -rf "$repo"

# ...and the fallback cooldown still gates: flagged at the current byte size
# means we are inside the default 100KB window -> suppressed.
repo="$(mk_repo)"; seed "$repo" BADCD2 200000 600 200000
out="$(run_cc "$repo" BADCD2 HANDOFF_CTX_MAX_FLAGS=0 HANDOFF_CTX_COOLDOWN_KB=100KB)"
check "COOLDOWN_KB='100KB' -> default cooldown still gates" "" "$out"
rm -rf "$repo"

# --- WINDOW_TOKENS=0 must not divide-by-zero --------------------------------
# A bogus HANDOFF_CTX_WINDOW_TOKENS=0 override would make the threshold/pct
# arithmetic divide by zero, which aborts the script under `set -e` *before*
# any reminder is emitted (so the negative control is empty output). The fix
# ignores a non-positive override and falls through to auto-detection (200k or
# 1M). 600k tokens crosses 40% of either, so a reminder must fire regardless of
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

# --- Window auto-detect from the session's recorded model (.ctx_model_) ------
# run_cc pins the window; these tests need auto-detection, so pass an EMPTY
# override (the non-positive-integer guard treats it as unset -> auto-detect)
# and pin HOME to the repo (which has no .claude.json) so the host's real
# ~/.claude.json can never leak into the lastModelUsage fallback.
run_cc_auto() {  # <repo> <sid> [ENV=VAL ...]
  local repo="$1" sid="$2"; shift 2
  ( cd "$repo" && env HANDOFF_CTX_WINDOW_TOKENS= HOME="$repo" "$@" \
      bash "$CC" <<<"{\"session_id\":\"$sid\"}" 2>/dev/null )
}
# Seed the model sidecar the Stop hook writes. Args: <repo> <sid> <model>
seed_model() { printf '%s\n' "$3" > "$1/.claude/handoff_backups/.ctx_model_$2"; }

# 1M-native Claude 5 id (no [1m] suffix) -> 1M window. Tokens are kept BELOW
# 200k (with a lowered threshold) so the measured-tokens ratchet can't mask a
# broken model-file path: matched -> "15% of 1000000", broken -> "75% of 200000".
repo="$(mk_repo)"; seed "$repo" M1M 4000 150000; seed_model "$repo" M1M claude-fable-5
out="$(run_cc_auto "$repo" M1M HANDOFF_CTX_THRESHOLD_PCT=10)"
check "1M-native model file -> 1000000-token window" yes "$(has "$out" "1000000-token window")"
check "1M-native model file -> pct against 1M (15%)" yes "$(has "$out" "15%")"
rm -rf "$repo"

# Issue #173: the window comes from a model table checked against the model
# docs, never from a broad regex. Listed 1M ids (Opus 4.8 included: "Opus 4.7
# and later run with the 1M window by default"); 4.5-family ids are 200k; an
# id the table does not list (claude-opus-6, a future release) is UNKNOWN,
# not assumed.
for m in claude-opus-5-5 claude-sonnet-5 claude-opus-4-8 anthropic.claude-haiku-5-5; do
  repo="$(mk_repo)"; seed "$repo" C5 4000 400000; seed_model "$repo" C5 "$m"
  out="$(run_cc_auto "$repo" C5)"
  check "$m -> 1000000-token window (table)" yes "$(has "$out" "1000000-token window (from this hook's model table for $m")"
  rm -rf "$repo"
done
for m in claude-sonnet-4-5-20250929 claude-opus-4-5; do
  repo="$(mk_repo)"; seed "$repo" C4 4000 100000; seed_model "$repo" C4 "$m"
  out="$(run_cc_auto "$repo" C4)"
  check "$m -> 200000-token window" yes "$(has "$out" "200000-token window")"
  rm -rf "$repo"
done
for m in claude-opus-6 claude-sonnet-4-6 claude-opus-4-6; do
  repo="$(mk_repo)"; seed "$repo" CUNK 4000 150000; seed_model "$repo" CUNK "$m"
  out="$(run_cc_auto "$repo" CUNK)"
  check "$m -> window unknown"       yes "$(has "$out" "window unknown")"
  check "$m -> no percentage"        no  "$(has "$out" "%")"
  rm -rf "$repo"
done
# A [1m] suffix means 1M whatever the base id (Opus 4.6 [1m] variant).
repo="$(mk_repo)"; seed "$repo" M1MSUF 4000 400000; seed_model "$repo" M1MSUF 'claude-opus-4-6[1m]'
out="$(run_cc_auto "$repo" M1MSUF)"
check "[1m] suffix -> 1M window, names the suffix" yes "$(has "$out" "1000000-token window (from the [1m] suffix")"
rm -rf "$repo"
# CLAUDE_CODE_DISABLE_1M_CONTEXT=1 makes Claude Code run 1M-default models at
# 200k, so the table follows it.
repo="$(mk_repo)"; seed "$repo" NO1M 4000 100000; seed_model "$repo" NO1M claude-opus-5-5
out="$(run_cc_auto "$repo" NO1M CLAUDE_CODE_DISABLE_1M_CONTEXT=1)"
check "DISABLE_1M_CONTEXT -> 200000-token window" yes "$(has "$out" "200000-token window")"
rm -rf "$repo"

# A MEASURED 250k count cannot fit the 200k window the table lists: the table
# is wrong for this session, so the window is unknown (the old code
# "ratcheted" to 1M, which was another guess).
repo="$(mk_repo)"; seed "$repo" RAT 4000 250000
seed_model "$repo" RAT claude-haiku-4-5-20251001
out="$(run_cc_auto "$repo" RAT)"
check "measured 250k vs 200k table window -> unknown" yes "$(has "$out" "window unknown (measured 250000 tokens exceed")"
check "contradicted table window -> no percentage"    no  "$(has "$out" "%")"
rm -rf "$repo"

# Negative control: the bytes/4 ESTIMATE never overrides the table (it
# routinely overshoots): 4MB/4 = 1M est tokens still reports the 200k window.
repo="$(mk_repo)"; seed "$repo" NORAT 4000000
seed_model "$repo" NORAT claude-haiku-4-5-20251001
out="$(run_cc_auto "$repo" NORAT)"
check "estimated tokens never override -> 200000 window" yes "$(has "$out" "200000-token window")"
rm -rf "$repo"

# An EXPLICIT env window is never second-guessed: the documented contract is
# that HANDOFF_CTX_WINDOW_TOKENS always wins (a user may pin a sub-1M budget on
# purpose), so a measured 250k against a pinned 500k window reports 50%.
repo="$(mk_repo)"; seed "$repo" ENVRAT 4000 250000
out="$(run_cc_auto "$repo" ENVRAT HANDOFF_CTX_WINDOW_TOKENS=500000)"
check "explicit env window -> 500000 window"       yes "$(has "$out" "500000-token window (from HANDOFF_CTX_WINDOW_TOKENS")"
check "explicit env window pct against 500k (50%)" yes "$(has "$out" "50%")"
rm -rf "$repo"

# HANDOFF_CTX_1M_MODEL_REGEX override: a custom id matches the user's regex ->
# 1M; the same id without the override is not in the table -> unknown.
repo="$(mk_repo)"; seed "$repo" REOVR 4000 400000
seed_model "$repo" REOVR my-custom-1m-model
out="$(run_cc_auto "$repo" REOVR HANDOFF_CTX_1M_MODEL_REGEX=custom-1m)"
check "regex override matches custom id -> 1M window" yes "$(has "$out" "1000000-token window (model id my-custom-1m-model matches")"
seed "$repo" REDEF 4000 150000; seed_model "$repo" REDEF my-custom-1m-model
out="$(run_cc_auto "$repo" REDEF)"
check "custom id w/o override -> window unknown" yes "$(has "$out" "not in this hook's model table")"
rm -rf "$repo"

# A model file failing the charset guard is never trusted or printed, but it
# is present, so the reason says so (PR #177 review: it used to claim "no
# model id recorded"). Window unknown, absolute gate (150k >= 100k) fires.
repo="$(mk_repo)"; seed "$repo" BADMODEL 4000 150000
seed_model "$repo" BADMODEL 'evil;model/../id'
out="$(run_cc_auto "$repo" BADMODEL)"
check "invalid model file -> window unknown, id present" yes "$(has "$out" "the recorded model id is not in this hook's model table")"
check "invalid model file -> not 'no model id recorded'" no  "$(has "$out" "no model id recorded")"
check "invalid model file -> id never printed"           no  "$(has "$out" "evil;model")"
rm -rf "$repo"

# ~/.claude.json lastModelUsage is no longer consulted (another session's or
# project's model is a guess, issue #173): no model recorded -> unknown.
repo="$(mk_repo)"; seed "$repo" JQ1M 4000 150000
printf '{"projects":{"/elsewhere":{"lastModelUsage":{"claude-fable-5":{"count":1}}}}}' > "$repo/.claude.json"
out="$(run_cc_auto "$repo" JQ1M)"
check "no model file, .claude.json ignored -> unknown" yes "$(has "$out" "window unknown")"
rm -rf "$repo"

finish
