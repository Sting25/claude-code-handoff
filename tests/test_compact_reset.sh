#!/usr/bin/env bash
# Behavioral coverage for handoff_compact_reset.sh (the PostCompact hook that
# clears a session's ctx sidecars so the freed window is treated as
# session-start fresh) plus the integration with handoff_ctx_check.sh: after
# a reset the nudge is silent (nothing recorded), and once fresh Stop-style
# files land the once-per-session nudge RE-FIRES (the freed-window goal —
# without the reset, the .ctx_flagged_ ledger would suppress it forever).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CR="$REPO_ROOT/bin/handoff_compact_reset.sh"
CC="$REPO_ROOT/bin/handoff_ctx_check.sh"
command -v jq >/dev/null 2>&1 || { echo "handoff_compact_reset.sh"; skip "jq missing — hook parses payload with jq"; finish; exit; }

run_reset() {  # <repo> <sid>
  ( cd "$1" && bash "$CR" <<<"{\"session_id\":\"$2\"}" 2>/dev/null )
}
run_cc() {  # <repo> <sid>
  ( cd "$1" && env HANDOFF_CTX_WINDOW_TOKENS=1000 \
      bash "$CC" <<<"{\"session_id\":\"$2\"}" 2>/dev/null )
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# Seed the full sidecar family for a session.
seed_all() {  # <repo> <sid>
  local bd="$1/.claude/handoff_backups"; mkdir -p "$bd"
  printf '4000'   > "$bd/.ctx_$2"
  printf '600'    > "$bd/.ctx_tokens_$2"
  printf '4000\n' > "$bd/.ctx_flagged_$2"
  printf 'tokens=600\n' > "$bd/.ctx_sl_$2"
  printf 'claude-fable-5\n' > "$bd/.ctx_model_$2"
}

echo "handoff_compact_reset.sh — sidecar reset + nudge re-arm"

# --- Deletes exactly the four sidecars; .ctx_model_ survives -----------------
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"
seed_all "$repo" A; seed_all "$repo" OTHER
run_reset "$repo" A; rc=$?
check "reset: exit 0"                 0   "$rc"
check "reset: .ctx_ gone"             no  "$([[ -e "$bd/.ctx_A" ]] && echo yes || echo no)"
check "reset: .ctx_tokens_ gone"      no  "$([[ -e "$bd/.ctx_tokens_A" ]] && echo yes || echo no)"
check "reset: .ctx_flagged_ gone"     no  "$([[ -e "$bd/.ctx_flagged_A" ]] && echo yes || echo no)"
check "reset: .ctx_sl_ gone"          no  "$([[ -e "$bd/.ctx_sl_A" ]] && echo yes || echo no)"
check "reset: .ctx_model_ SURVIVES"   yes "$([[ -e "$bd/.ctx_model_A" ]] && echo yes || echo no)"
# NEGATIVE CONTROL: another session's whole family is untouched.
for f in .ctx_OTHER .ctx_tokens_OTHER .ctx_flagged_OTHER .ctx_sl_OTHER .ctx_model_OTHER; do
  check "reset: other session $f kept" yes "$([[ -e "$bd/$f" ]] && echo yes || echo no)"
done
rm -rf "$repo"

# --- Guards: invalid sid / empty payload / missing dir -> exit 0, no effect --
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"
seed_all "$repo" B
run_reset "$repo" "../escape"; rc=$?
check "invalid sid: exit 0"           0   "$rc"
check "invalid sid: sidecars intact"  yes "$([[ -e "$bd/.ctx_B" ]] && echo yes || echo no)"
out="$( cd "$repo" && bash "$CR" </dev/null 2>/dev/null )"; rc=$?
check "empty payload: exit 0"         0   "$rc"
check "empty payload: no output"      ""  "$out"
rm -rf "$repo"
repo="$(mk_repo)"   # no .claude/handoff_backups at all
run_reset "$repo" NODIR; rc=$?
check "missing backup dir: exit 0"    0   "$rc"
rm -rf "$repo"

# --- Integration: over-threshold + already-flagged -> reset -> silent gap ->
#     fresh Stop-style seed -> the nudge RE-FIRES in the freed window ---------
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; mkdir -p "$bd"
# Pre-compact world: 600/1000 over threshold AND already flagged once (the
# suggest-mode cap of 1 would suppress any further nudge forever).
printf '200000' > "$bd/.ctx_INT"
printf '600'    > "$bd/.ctx_tokens_INT"
printf '0\n'    > "$bd/.ctx_flagged_INT"
check "pre-reset: capped session is silent" "" "$(run_cc "$repo" INT)"
run_reset "$repo" INT
# Gap between compaction and the next Stop fire: nothing recorded -> silent
# (the load-bearing .ctx_ delete — no stale-estimate nudge can fire here).
check "post-reset gap: ctx-check silent"    "" "$(run_cc "$repo" INT)"
# Next Stop fire repopulates real post-compact numbers over the threshold.
printf '4000' > "$bd/.ctx_INT"
printf '700'  > "$bd/.ctx_tokens_INT"
out="$(run_cc "$repo" INT)"
check "re-seeded: nudge re-fires"       yes "$(has "$out" "<system-reminder>")"
check "re-seeded: fresh count (700)"    yes "$(has "$out" "700 tokens")"
rm -rf "$repo"

finish
