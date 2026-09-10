#!/usr/bin/env bash
# handoff_ctx_check.sh x the absolute-token gate (issue #119). The 40% default
# was calibrated on 200k windows (~80k tokens); on a correctly detected 1M
# window it became 400k, and the nudge effectively never fired. The hook now
# fires at whichever gate is reached first: HANDOFF_CTX_THRESHOLD_TOKENS
# (default 100000) or THRESHOLD_PCT of the window. These tests drive the 1M
# window explicitly (env pin) and via the model file, and prove the 200k /
# pinned-1000 contracts are unchanged. (tests/test_ctx_check.sh and
# tests/test_ctx_check_statusline.sh passing UNMODIFIED are the other half of
# the acceptance gate.)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CC="$REPO_ROOT/bin/handoff_ctx_check.sh"
command -v jq >/dev/null 2>&1 || { echo "handoff_ctx_check.sh (absolute threshold)"; skip "jq missing: hook parses payload with jq"; finish; exit; }

seed() {  # <repo> <sid> <bytes> [tokens]
  local repo="$1" sid="$2" bytes="$3" tokens="${4:-}"
  local bd="$repo/.claude/handoff_backups"; mkdir -p "$bd"
  printf '%s' "$bytes" > "$bd/.ctx_${sid}"
  [[ -n "$tokens" ]] && printf '%s' "$tokens" > "$bd/.ctx_tokens_${sid}"
}
seed_model() { printf '%s\n' "$3" > "$1/.claude/handoff_backups/.ctx_model_$2"; }
run_cc() {  # <repo> <sid> [ENV=VAL ...]  (window pinned by caller via env)
  local repo="$1" sid="$2"; shift 2
  ( cd "$repo" && env HOME="$repo" "$@" bash "$CC" <<<"{\"session_id\":\"$sid\"}" 2>/dev/null )
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
exists() { [[ -e "$1" ]] && echo yes || echo no; }

echo "handoff_ctx_check.sh: absolute token gate (#119)"

# --- 1M window: 150k measured is 15% (< 40%) but > 100k absolute -> fires ----
repo="$(mk_repo)"; seed "$repo" ABS1 4000 150000
out="$(run_cc "$repo" ABS1 HANDOFF_CTX_WINDOW_TOKENS=1000000)"
check "1M window, 150k tokens -> fires on absolute gate" yes "$(has "$out" "<system-reminder>")"
check "1M window, 150k tokens -> reports 15%"            yes "$(has "$out" "15%")"
check "1M window, 150k tokens -> flag recorded"          yes "$(exists "$repo/.claude/handoff_backups/.ctx_flagged_ABS1")"
rm -rf "$repo"

# --- NEGATIVE CONTROL: same window, 50k measured -> under both gates -> silent
repo="$(mk_repo)"; seed "$repo" ABS0 4000 50000
out="$(run_cc "$repo" ABS0 HANDOFF_CTX_WINDOW_TOKENS=1000000)"
check "1M window, 50k tokens -> silent"          ""  "$out"
check "1M window, 50k tokens -> no flag written" no  "$(exists "$repo/.claude/handoff_backups/.ctx_flagged_ABS0")"
rm -rf "$repo"

# --- Exactly at the absolute gate fires (>=, matching the pct gate) ---------
repo="$(mk_repo)"; seed "$repo" EDGE 4000 100000
out="$(run_cc "$repo" EDGE HANDOFF_CTX_WINDOW_TOKENS=1000000)"
check "1M window, exactly 100k -> fires" yes "$(has "$out" "<system-reminder>")"
rm -rf "$repo"

# --- 1M detected from the model file (the real-world path) -> same outcome --
repo="$(mk_repo)"; seed "$repo" MODEL 4000 150000; seed_model "$repo" MODEL claude-fable-5-1
out="$(run_cc "$repo" MODEL HANDOFF_CTX_WINDOW_TOKENS=)"
check "model-detected 1M window, 150k -> fires"      yes "$(has "$out" "<system-reminder>")"
check "model-detected 1M window -> says 1M window"   yes "$(has "$out" "1000000-token window")"
rm -rf "$repo"

# --- 200k window contract unchanged: pct gate (80k) is the lower one --------
repo="$(mk_repo)"; seed "$repo" K200A 4000 90000
out="$(run_cc "$repo" K200A HANDOFF_CTX_WINDOW_TOKENS=200000)"
check "200k window, 90k -> fires (pct gate 80k, as before)" yes "$(has "$out" "<system-reminder>")"
rm -rf "$repo"
repo="$(mk_repo)"; seed "$repo" K200B 4000 70000
out="$(run_cc "$repo" K200B HANDOFF_CTX_WINDOW_TOKENS=200000)"
check "200k window, 70k -> silent (as before)" "" "$out"
rm -rf "$repo"

# --- Pinned-1000 test contract unchanged: gate stays 400, not 100000 --------
repo="$(mk_repo)"; seed "$repo" PIN 4000 500
out="$(run_cc "$repo" PIN HANDOFF_CTX_WINDOW_TOKENS=1000)"
check "window 1000, 500 tokens -> still fires at 400 gate" yes "$(has "$out" "<system-reminder>")"
rm -rf "$repo"

# --- Env override moves the absolute gate ----------------------------------
repo="$(mk_repo)"; seed "$repo" OVR 4000 150000
out="$(run_cc "$repo" OVR HANDOFF_CTX_WINDOW_TOKENS=1000000 HANDOFF_CTX_THRESHOLD_TOKENS=200000)"
check "THRESHOLD_TOKENS=200000 -> 150k silent" "" "$out"
out="$(run_cc "$repo" OVR HANDOFF_CTX_WINDOW_TOKENS=1000000 HANDOFF_CTX_THRESHOLD_TOKENS=120000)"
check "THRESHOLD_TOKENS=120000 -> 150k fires"  yes "$(has "$out" "<system-reminder>")"
rm -rf "$repo"

# --- 0 disables the absolute gate: pure percentage rule (pre-#119) ----------
repo="$(mk_repo)"; seed "$repo" OFF 4000 150000
out="$(run_cc "$repo" OFF HANDOFF_CTX_WINDOW_TOKENS=1000000 HANDOFF_CTX_THRESHOLD_TOKENS=0)"
check "THRESHOLD_TOKENS=0 -> 150k/1M silent (pct rule only)" "" "$out"
seed "$repo" OFF2 4000 450000
out="$(run_cc "$repo" OFF2 HANDOFF_CTX_WINDOW_TOKENS=1000000 HANDOFF_CTX_THRESHOLD_TOKENS=0)"
check "THRESHOLD_TOKENS=0 -> 450k/1M fires (45%)" yes "$(has "$out" "45%")"
rm -rf "$repo"

# --- Malformed value falls back to the 100000 default -----------------------
repo="$(mk_repo)"; seed "$repo" BAD 4000 150000
out="$(run_cc "$repo" BAD HANDOFF_CTX_WINDOW_TOKENS=1000000 HANDOFF_CTX_THRESHOLD_TOKENS=100k)"
check "THRESHOLD_TOKENS='100k' -> falls back to 100000, fires" yes "$(has "$out" "<system-reminder>")"
seed "$repo" BADNEG 4000 150000
out="$(run_cc "$repo" BADNEG HANDOFF_CTX_WINDOW_TOKENS=1000000 HANDOFF_CTX_THRESHOLD_TOKENS=-1)"
check "THRESHOLD_TOKENS=-1 -> falls back to 100000, fires"     yes "$(has "$out" "<system-reminder>")"
rm -rf "$repo"

# --- Statusline-reported window + tokens: the live path on this bug ---------
# Mirrors the owner's real session: sl says window=1M, tokens=150k. Stop hook
# says 100 (would be silent alone). The sl count drives the absolute gate.
repo="$(mk_repo)"; seed "$repo" SL 4000 100
printf 'window=1000000\ntokens=150000\n' > "$repo/.claude/handoff_backups/.ctx_sl_SL"
out="$(run_cc "$repo" SL HANDOFF_CTX_WINDOW_TOKENS=)"
check "statusline 1M/150k -> fires on absolute gate" yes "$(has "$out" "<system-reminder>")"
check "statusline 1M/150k -> 15%"                     yes "$(has "$out" "15%")"
rm -rf "$repo"

finish
