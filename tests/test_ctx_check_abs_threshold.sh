#!/usr/bin/env bash
# handoff_ctx_check.sh x the absolute-token gate. Issue #119 made
# HANDOFF_CTX_THRESHOLD_TOKENS (default 100000) fire at whichever of it or
# THRESHOLD_PCT came first, so a 1M window nudged at 10%. Issue #173 narrows
# it: when the window is known (env pin, statusline, model table) only the
# percentage applies (default 30%); the absolute gate is the fallback for an
# UNKNOWN window, where no percentage exists. These tests prove both halves.
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

echo "handoff_ctx_check.sh: absolute token gate, unknown window only (#119, #173)"

# --- Known 1M window: 150k / 100k measured is 15% / 10%, under 30% -> silent.
#     On main (#119) both fired on the absolute gate. ---------------------------
repo="$(mk_repo)"; seed "$repo" ABS1 4000 150000
out="$(run_cc "$repo" ABS1 HANDOFF_CTX_WINDOW_TOKENS=1000000)"
check "1M window, 150k tokens -> silent (abs gate off)" ""  "$out"
check "1M window, 150k tokens -> no flag written"       no  "$(exists "$repo/.claude/handoff_backups/.ctx_flagged_ABS1")"
rm -rf "$repo"
repo="$(mk_repo)"; seed "$repo" EDGE 4000 100000
out="$(run_cc "$repo" EDGE HANDOFF_CTX_WINDOW_TOKENS=1000000)"
check "1M window, exactly 100k -> silent" "" "$out"
rm -rf "$repo"

# --- Known 1M window: first nudge at 30% -------------------------------------
repo="$(mk_repo)"; seed "$repo" P30 4000 300000
out="$(run_cc "$repo" P30 HANDOFF_CTX_WINDOW_TOKENS=1000000)"
check "1M window, 300k -> fires at 30%" yes "$(has "$out" "~30% of a 1000000-token window")"
rm -rf "$repo"

# --- Model-table 1M window (the real desktop-app path): 150k silent ---------
repo="$(mk_repo)"; seed "$repo" MODEL 4000 150000; seed_model "$repo" MODEL claude-fable-5-1
out="$(run_cc "$repo" MODEL HANDOFF_CTX_WINDOW_TOKENS=)"
check "model-table 1M window, 150k -> silent" "" "$out"
rm -rf "$repo"

# --- 200k window: pct gate at 30% = 60k --------------------------------------
repo="$(mk_repo)"; seed "$repo" K200A 4000 70000
out="$(run_cc "$repo" K200A HANDOFF_CTX_WINDOW_TOKENS=200000)"
check "200k window, 70k -> fires (35%)" yes "$(has "$out" "~35% of a 200000-token window")"
rm -rf "$repo"
repo="$(mk_repo)"; seed "$repo" K200B 4000 50000
out="$(run_cc "$repo" K200B HANDOFF_CTX_WINDOW_TOKENS=200000)"
check "200k window, 50k -> silent (25%)" "" "$out"
rm -rf "$repo"

# --- Unknown window: the absolute gate is what fires -------------------------
# No env pin, no statusline, no model recorded -> window unknown.
repo="$(mk_repo)"; seed "$repo" UNK 4000 150000
out="$(run_cc "$repo" UNK HANDOFF_CTX_WINDOW_TOKENS=)"
check "unknown window, 150k -> fires on absolute gate" yes "$(has "$out" "<system-reminder>")"
check "unknown window -> says window unknown"          yes "$(has "$out" "window unknown")"
check "unknown window -> no percentage anywhere"       no  "$(has "$out" "%")"
check "unknown window -> flag recorded"                yes "$(exists "$repo/.claude/handoff_backups/.ctx_flagged_UNK")"
rm -rf "$repo"
repo="$(mk_repo)"; seed "$repo" UNK0 4000 50000
out="$(run_cc "$repo" UNK0 HANDOFF_CTX_WINDOW_TOKENS=)"
check "unknown window, 50k -> silent" "" "$out"
rm -rf "$repo"
repo="$(mk_repo)"; seed "$repo" UNKE 4000 100000
out="$(run_cc "$repo" UNKE HANDOFF_CTX_WINDOW_TOKENS=)"
check "unknown window, exactly 100k -> fires (>=)" yes "$(has "$out" "<system-reminder>")"
rm -rf "$repo"

# --- Env override moves the absolute gate (unknown window) ------------------
repo="$(mk_repo)"; seed "$repo" OVR 4000 150000
out="$(run_cc "$repo" OVR HANDOFF_CTX_WINDOW_TOKENS= HANDOFF_CTX_THRESHOLD_TOKENS=200000)"
check "THRESHOLD_TOKENS=200000 -> 150k silent" "" "$out"
out="$(run_cc "$repo" OVR HANDOFF_CTX_WINDOW_TOKENS= HANDOFF_CTX_THRESHOLD_TOKENS=120000)"
check "THRESHOLD_TOKENS=120000 -> 150k fires"  yes "$(has "$out" "<system-reminder>")"
rm -rf "$repo"

# --- 0 disables the absolute gate: an unknown window then never nudges -----
repo="$(mk_repo)"; seed "$repo" OFF 4000 900000
out="$(run_cc "$repo" OFF HANDOFF_CTX_WINDOW_TOKENS= HANDOFF_CTX_THRESHOLD_TOKENS=0)"
check "THRESHOLD_TOKENS=0 + unknown window -> silent" "" "$out"
rm -rf "$repo"

# --- Malformed value falls back to the 100000 default -----------------------
repo="$(mk_repo)"; seed "$repo" BAD 4000 150000
out="$(run_cc "$repo" BAD HANDOFF_CTX_WINDOW_TOKENS= HANDOFF_CTX_THRESHOLD_TOKENS=100k)"
check "THRESHOLD_TOKENS='100k' -> falls back to 100000, fires" yes "$(has "$out" "<system-reminder>")"
seed "$repo" BADNEG 4000 150000
out="$(run_cc "$repo" BADNEG HANDOFF_CTX_WINDOW_TOKENS= HANDOFF_CTX_THRESHOLD_TOKENS=-1)"
check "THRESHOLD_TOKENS=-1 -> falls back to 100000, fires"     yes "$(has "$out" "<system-reminder>")"
rm -rf "$repo"

# --- Statusline-reported window: known, so 150k of 1M is silent -------------
# Mirrors the owner's 2026-11-09 session ("~10% ... natural /handoff moment"):
# on main the absolute gate fired here.
repo="$(mk_repo)"; seed "$repo" SL 4000 100
printf 'window=1000000\ntokens=150000\n' > "$repo/.claude/handoff_backups/.ctx_sl_SL"
out="$(run_cc "$repo" SL HANDOFF_CTX_WINDOW_TOKENS=)"
check "statusline 1M/150k -> silent" "" "$out"
rm -rf "$repo"

finish
