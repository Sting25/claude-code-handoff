#!/usr/bin/env bash
# handoff_ctx_check.sh — progress ledger selection (issue #69).
#
# The nudge used to exit outright when the Stop hook's .ctx_<sid> byte count
# was absent:
#
#     [[ -f "$size_file" ]] || exit 0
#
# so a dead Stop hook did not degrade context watching, it deleted it — even
# at 90% context, even with Claude Code's own numbers sitting in .ctx_sl_<sid>.
# The hook now picks a ledger instead of assuming one: bytes when .ctx_<sid>
# exists (unchanged in every respect), tokens when it does not but the
# statusline cache is present and fresh.
#
# The acceptance gate is two-sided. These checks cover the new token ledger;
# tests/test_ctx_check.sh and tests/test_ctx_check_statusline.sh passing
# UNMODIFIED cover the promise that the byte path did not move.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CC="$REPO_ROOT/bin/handoff_ctx_check.sh"
command -v jq >/dev/null 2>&1 || { echo "handoff_ctx_check.sh (ledger)"; skip "jq missing — hook parses payload with jq"; finish; exit; }

bd() { printf '%s/.claude/handoff_backups' "$1"; }
# Statusline cache only — the shape a session has when the Stop hook is dead
# but the statusLine is wired.
seed_sl_only() {  # <repo> <sid> <tokens>
  local d; d="$(bd "$1")"; mkdir -p "$d"
  printf 'window=1000\ntokens=%s\n' "$3" > "$d/.ctx_sl_$2"
}
run_cc() {  # <repo> <sid> [ENV=VAL ...]
  local repo="$1" sid="$2"; shift 2
  ( cd "$repo" && env HANDOFF_CTX_WINDOW_TOKENS=1000 HOME="$repo" "$@" \
      bash "$CC" <<<"{\"session_id\":\"$sid\"}" 2>/dev/null )
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
exists() { [[ -e "$1" ]] && echo yes || echo no; }

echo "handoff_ctx_check.sh — progress ledger (Stop hook absent)"

# --- the headline case: no Stop data, fresh statusline over threshold --------
# Window pinned 1000, threshold 40% -> 400. sl says 600.
repo="$(mk_repo)"; cleanup_on_exit "$repo"; seed_sl_only "$repo" TOKA 600
out="$(run_cc "$repo" TOKA)"
check "sl-only over threshold -> fires"        yes "$(has "$out" "<system-reminder>")"
check "sl-only -> reports the sl token count"  yes "$(has "$out" "600 tokens")"
check "sl-only -> 60%"                         yes "$(has "$out" "60%")"
check "sl-only -> not marked ESTIMATED"        no  "$(has "$out" "ESTIMATED")"
check "sl-only -> token-denominated flag file" yes "$(exists "$(bd "$repo")/.ctx_flagged_tok_TOKA")"
check "sl-only -> no byte flag file"           no  "$(exists "$(bd "$repo")/.ctx_flagged_TOKA")"

# --- NEGATIVE CONTROL: same shape, under threshold -> silent ----------------
repo="$(mk_repo)"; cleanup_on_exit "$repo"; seed_sl_only "$repo" TOKU 100
check "sl-only under threshold -> silent" no "$(has "$(run_cc "$repo" TOKU)" "<system-reminder>")"

# --- a cache with no usable token count is not a ledger ---------------------
repo="$(mk_repo)"; cleanup_on_exit "$repo"
must mkdir -p "$(bd "$repo")"
must printf 'window=1000\npct=90.0\n' > "$(bd "$repo")/.ctx_sl_TOKN"
check "sl without tokens= -> silent" no "$(has "$(run_cc "$repo" TOKN)" "<system-reminder>")"

# --- staleness horizon: a statusLine that stopped rendering ------------------
# With no Stop-hook tokens file to cross-check against, a frozen cache would
# otherwise nudge off a number that can no longer change.
repo="$(mk_repo)"; cleanup_on_exit "$repo"; seed_sl_only "$repo" TOKS 600
must touch -t 200001010000 "$(bd "$repo")/.ctx_sl_TOKS"
check "stale sl cache -> silent"              no  "$(has "$(run_cc "$repo" TOKS)" "<system-reminder>")"
check "stale sl cache honored via env widen"  yes \
  "$(has "$(run_cc "$repo" TOKS HANDOFF_CTX_SL_MAX_AGE_SECS=99999999999)" "<system-reminder>")"

# --- the two documented escape hatches restore pre-#69 behavior exactly -----
repo="$(mk_repo)"; cleanup_on_exit "$repo"; seed_sl_only "$repo" TOKE 600
check "SL_MAX_AGE_SECS=0 disables token ledger" no \
  "$(has "$(run_cc "$repo" TOKE HANDOFF_CTX_SL_MAX_AGE_SECS=0)" "<system-reminder>")"
check "NO_STATUSLINE=1 disables token ledger"   no \
  "$(has "$(run_cc "$repo" TOKE HANDOFF_CTX_NO_STATUSLINE=1)" "<system-reminder>")"

echo "handoff_ctx_check.sh — token cooldown + ledger isolation"

# --- cooldown is denominated in tokens, not bytes ---------------------------
# MAX_FLAGS=0 (uncapped) so the cooldown is what actually gates the re-fire.
# Default token cooldown = COOLDOWN_KB(100) * 1024 / 4 = 25600.
repo="$(mk_repo)"; cleanup_on_exit "$repo"; seed_sl_only "$repo" TOKC 600
out="$(run_cc "$repo" TOKC HANDOFF_CTX_MAX_FLAGS=0)"
check "token cooldown: first crossing fires"   yes "$(has "$out" "<system-reminder>")"
check "token cooldown: repeat_note in tokens"  yes "$(has "$out" "tokens of context growth")"
check "token cooldown: repeat_note not in KB"  no  "$(has "$out" "KB of transcript growth")"
seed_sl_only "$repo" TOKC 700   # +100 tokens — far inside the cooldown
check "token cooldown: small growth -> silent" no \
  "$(has "$(run_cc "$repo" TOKC HANDOFF_CTX_MAX_FLAGS=0)" "<system-reminder>")"
seed_sl_only "$repo" TOKC 900   # still inside 600+25600
check "token cooldown: still inside -> silent" no \
  "$(has "$(run_cc "$repo" TOKC HANDOFF_CTX_MAX_FLAGS=0)" "<system-reminder>")"
check "token cooldown: override lets it re-fire" yes \
  "$(has "$(run_cc "$repo" TOKC HANDOFF_CTX_MAX_FLAGS=0 HANDOFF_CTX_COOLDOWN_TOKENS=100)" "<system-reminder>")"

# --- a byte ledger left over from a working session cannot gate the token one
# The two ledgers must never be read as one number: 600 tokens is not "less
# than" a 4000-byte high-water mark, it is a different quantity entirely.
repo="$(mk_repo)"; cleanup_on_exit "$repo"; seed_sl_only "$repo" TOKX 600
must printf '4000\n' > "$(bd "$repo")/.ctx_flagged_TOKX"
check "stale byte flag does not gate tokens" yes \
  "$(has "$(run_cc "$repo" TOKX HANDOFF_CTX_MAX_FLAGS=0)" "<system-reminder>")"

# --- POSITIVE CONTROL: .ctx_ present -> byte ledger, byte flag file ---------
# Proves selection is real rather than the token path having simply replaced
# the old one.
repo="$(mk_repo)"; cleanup_on_exit "$repo"; seed_sl_only "$repo" BYTA 600
must printf '4000\n' > "$(bd "$repo")/.ctx_BYTA"
out="$(run_cc "$repo" BYTA)"
check "ctx_ present -> fires"                  yes "$(has "$out" "<system-reminder>")"
check "ctx_ present -> byte flag file"         yes "$(exists "$(bd "$repo")/.ctx_flagged_BYTA")"
check "ctx_ present -> no token flag file"     no  "$(exists "$(bd "$repo")/.ctx_flagged_tok_BYTA")"

# --- neither ledger available -> silent, exactly as before ------------------
repo="$(mk_repo)"; cleanup_on_exit "$repo"; must mkdir -p "$(bd "$repo")"
out="$(run_cc "$repo" NONE)"; rc=$?
check "no ctx_ and no sl cache -> exit 0"      0   "$rc"
check "no ctx_ and no sl cache -> silent"      ""  "$out"

echo "handoff_ctx_check.sh — token ledger survives a context DROP (F3)"

# --- context occupancy drops on compaction/eviction; the ledger must not
#     stall reading a smaller "now" against a stale high-water mark forever.
#     Seed a tok flag recorded at a HIGH count, then present a LOWER current
#     count that is still over threshold: without the staleness reset the
#     cooldown math (progress < last_flagged + cooldown_units) stays true
#     forever and the ledger never fires again.
repo="$(mk_repo)"; cleanup_on_exit "$repo"; seed_sl_only "$repo" TOKDROP 900
must printf '900\n' > "$(bd "$repo")/.ctx_flagged_tok_TOKDROP"
seed_sl_only "$repo" TOKDROP 600   # drop: 900 -> 600, still over the 400 threshold
out="$(run_cc "$repo" TOKDROP HANDOFF_CTX_MAX_FLAGS=0)"
check "token drop below last-flagged -> nudge fires" yes "$(has "$out" "<system-reminder>")"
check "token drop -> reports the new (lower) count"  yes "$(has "$out" "600 tokens")"

echo "handoff_ctx_check.sh — byte-path est_tokens==0 guard (F4)"

# --- Regression: the shared `est_tokens > 0` guard the token ledger needs
#     must NOT apply to the byte path. On main, a tiny/empty .ctx_<sid> with
#     THRESHOLD_PCT=0 still emits (est_tokens=0, threshold_tokens=0, 0<0 is
#     false, so the hook proceeds); the branch's fix must restore that exactly.
repo="$(mk_repo)"; cleanup_on_exit "$repo"; must mkdir -p "$(bd "$repo")"
must printf '0' > "$(bd "$repo")/.ctx_BYTZ"
out="$(cd "$repo" && env HANDOFF_CTX_WINDOW_TOKENS=1000 HANDOFF_CTX_THRESHOLD_PCT=0 \
    bash "$CC" <<<'{"session_id":"BYTZ"}' 2>/dev/null)"
check "byte ledger, tiny .ctx_, threshold 0 -> still emits" yes "$(has "$out" "<system-reminder>")"

finish
