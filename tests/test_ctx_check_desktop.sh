#!/usr/bin/env bash
# handoff_ctx_check.sh x desktop mode (issue #144): inside the Claude desktop
# app the hook environment carries CLAUDE_CODE_ENTRYPOINT=claude-desktop, the
# status line does not run, and the app shows the real context figure in its
# own meter. With no fresh cached pct and no HANDOFF_CTX_WINDOW_TOKENS pin, the
# reminder must report the token count only, point at the app's meter, and
# drop the inferred percentage and its window NOTE. Every escape (statusline
# pct, env pin, HANDOFF_CTX_NO_DESKTOP_MODE=1, a non-desktop entrypoint) must
# restore the percentage path, and terminal sessions must be byte-identical.
#
# lib.sh unsets CLAUDE_CODE_ENTRYPOINT and CLAUDE_CODE_DESKTOP_APP_VERSION, so
# every case here sets the entrypoint explicitly; nothing leaks in from a
# suite run inside the app itself.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CC="$REPO_ROOT/bin/handoff_ctx_check.sh"
command -v jq >/dev/null 2>&1 || { echo "handoff_ctx_check.sh (desktop)"; skip "jq missing: hook parses payload with jq"; finish; exit; }

# Seed a session's Stop-hook sidecars. Args: <repo> <sid> <bytes> [tokens] [model]
seed() {
  local repo="$1" sid="$2" bytes="$3" tokens="${4:-}" model="${5:-}"
  local bd="$repo/.claude/handoff_backups"
  must mkdir -p "$bd"
  must printf '%s' "$bytes" > "$bd/.ctx_${sid}"
  if [[ -n "$tokens" ]]; then must printf '%s' "$tokens" > "$bd/.ctx_tokens_${sid}"; fi
  if [[ -n "$model" ]]; then must printf '%s\n' "$model" > "$bd/.ctx_model_${sid}"; fi
}
# Seed the statusline cache. Args: <repo> <sid> <content...>
seed_sl() {
  local repo="$1" sid="$2"; shift 2
  must printf '%s\n' "$@" > "$repo/.claude/handoff_backups/.ctx_sl_${sid}"
}

# Run with the window UN-pinned (auto-detect) and HOME jailed to the repo so
# the host's real ~/.claude.json can't leak into the fallback probes. Trailing
# args are ENV=VAL overrides; the caller passes the entrypoint explicitly.
run_auto() {  # <repo> <sid> [ENV=VAL ...]
  local repo="$1" sid="$2"; shift 2
  ( cd "$repo" && env HANDOFF_CTX_WINDOW_TOKENS= HOME="$repo" "$@" \
      bash "$CC" <<<"{\"session_id\":\"$sid\"}" 2>/dev/null )
}
# Run with the window pinned to 1000 (mirrors test_ctx_check.sh).
run_pinned() {  # <repo> <sid> [ENV=VAL ...]
  local repo="$1" sid="$2"; shift 2
  ( cd "$repo" && env HANDOFF_CTX_WINDOW_TOKENS=1000 HOME="$repo" "$@" \
      bash "$CC" <<<"{\"session_id\":\"$sid\"}" 2>/dev/null )
}

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

DESK=CLAUDE_CODE_ENTRYPOINT=claude-desktop

echo "handoff_ctx_check.sh: desktop mode (issue #144)"

# --- Desktop, measured tokens, auto window -> token count only --------------
# Model claude-opus-5-5 -> 1M window; 150000 tokens crosses the 100k absolute
# gate. In a terminal this prints "~15% (estimated) of a 1000000-token window"
# plus the window NOTE; in the app it must print neither.
repo="$(mk_repo)"; cleanup_on_exit "$repo"
seed "$repo" DESK 4000 150000 claude-opus-5-5
out="$(run_auto "$repo" DESK "$DESK")"
check "desktop -> fires"                         yes "$(has "$out" "<system-reminder>")"
check "desktop -> keeps 'Context at ~'"          yes "$(has "$out" "Context at ~150000 tokens")"
check "desktop -> no percent sign anywhere"      no  "$(has "$out" "%")"
check "desktop -> names the app's context meter" yes "$(has "$out" "context meter")"
check "desktop -> no '(estimated)' label"        no  "$(has "$out" "(estimated)")"
check "desktop -> no window NOTE"                no  "$(has "$out" "NOTE: this percentage")"
check "desktop -> no window size"                no  "$(has "$out" "1000000-token window")"
check "desktop -> flag line has no pct"          yes "$(has "$out" "Flagging: about 150000 tokens of context used (see the app's context meter)")"
check "desktop -> still passive-mention copy"    yes "$(has "$out" "passive mention")"
check "desktop -> flag recorded"                 yes "$([[ -f "$repo/.claude/handoff_backups/.ctx_flagged_DESK" ]] && echo yes || echo no)"
# Cap logic unchanged: suggest mode flags once, then stays silent.
out="$(run_auto "$repo" DESK "$DESK")"
check "desktop -> second prompt capped (silent)" "" "$out"

# --- Desktop, below threshold -> silent (threshold logic unchanged) ---------
repo="$(mk_repo)"; cleanup_on_exit "$repo"
seed "$repo" DESKLOW 4000 50000 claude-opus-5-5
out="$(run_auto "$repo" DESKLOW "$DESK")"
check "desktop below threshold -> silent" "" "$out"

# --- Desktop, bytes/4 estimate -> one-sentence est_note, still no pct -------
# 4,000,000 bytes / 4 = 1,000,000 est tokens; no tokens file, no model file.
repo="$(mk_repo)"; cleanup_on_exit "$repo"
seed "$repo" DESKEST 4000000
out="$(run_auto "$repo" DESKEST "$DESK")"
check "desktop estimate -> fires"                 yes "$(has "$out" "<system-reminder>")"
check "desktop estimate -> bytes/4 note kept"     yes "$(has "$out" "ESTIMATED from transcript byte size (bytes/4)")"
check "desktop estimate -> short note (no 'rough upper bound')" no "$(has "$out" "rough upper bound")"
check "desktop estimate -> no percent sign"       no  "$(has "$out" "%")"
check "desktop estimate -> names the meter"       yes "$(has "$out" "context meter")"

# --- HANDOFF_CTX_NO_DESKTOP_MODE=1 -> percentage path returns ---------------
repo="$(mk_repo)"; cleanup_on_exit "$repo"
seed "$repo" OPTOUT 4000 150000 claude-opus-5-5
out="$(run_auto "$repo" OPTOUT "$DESK" HANDOFF_CTX_NO_DESKTOP_MODE=1)"
check "NO_DESKTOP_MODE=1 -> pct printed"        yes "$(has "$out" "~15% (estimated) of a 1000000-token window")"
check "NO_DESKTOP_MODE=1 -> window NOTE back"   yes "$(has "$out" "inferred from the model id (claude-opus-5-5)")"
check "NO_DESKTOP_MODE=1 -> no meter wording"   no  "$(has "$out" "context meter")"

# --- Fresh statusline cache with pct -> CC's own pct wins even in the app ---
# sl written after the tokens file (fresh); pct=42 must be reported verbatim.
repo="$(mk_repo)"; cleanup_on_exit "$repo"
seed "$repo" DESKSL 4000 150000 claude-opus-5-5
seed_sl "$repo" DESKSL "tokens=150000" "pct=42"
out="$(run_auto "$repo" DESKSL "$DESK")"
check "desktop + fresh sl pct -> ~42% printed"  yes "$(has "$out" "~42%")"
check "desktop + fresh sl pct -> no meter wording" no "$(has "$out" "context meter")"

# --- Stale statusline cache (older than tokens file) -> desktop mode --------
repo="$(mk_repo)"; cleanup_on_exit "$repo"
seed "$repo" DESKSTALE 4000 150000 claude-opus-5-5
seed_sl "$repo" DESKSTALE "tokens=150000" "pct=42"
must touch -t 202001010000 "$repo/.claude/handoff_backups/.ctx_sl_DESKSTALE"
must touch "$repo/.claude/handoff_backups/.ctx_tokens_DESKSTALE"
out="$(run_auto "$repo" DESKSTALE "$DESK")"
check "desktop + stale sl pct -> no percent sign" no  "$(has "$out" "%")"
check "desktop + stale sl pct -> meter wording"   yes "$(has "$out" "context meter")"

# --- HANDOFF_CTX_WINDOW_TOKENS pinned -> percentage against the pin --------
repo="$(mk_repo)"; cleanup_on_exit "$repo"
seed "$repo" DESKPIN 4000 600
out="$(run_pinned "$repo" DESKPIN "$DESK")"
check "desktop + env pin -> 60% printed"        yes "$(has "$out" "~60% of a 1000-token window")"
check "desktop + env pin -> no meter wording"   no  "$(has "$out" "context meter")"

# --- act mode variant -> self-invoke copy, no percent sign ------------------
repo="$(mk_repo)"; cleanup_on_exit "$repo"
seed "$repo" DESKACT 4000 150000 claude-opus-5-5
out="$(run_auto "$repo" DESKACT "$DESK" HANDOFF_CTX_REMINDER_MODE=act)"
check "desktop act -> fires"                yes "$(has "$out" "<system-reminder>")"
check "desktop act -> self-invoke copy"     yes "$(has "$out" "invoke /handoff yourself")"
check "desktop act -> no percent sign"      no  "$(has "$out" "%")"
check "desktop act -> names the meter"      yes "$(has "$out" "context meter")"
check "desktop act -> keeps 'Context at ~'" yes "$(has "$out" "Context at ~150000 tokens")"

# --- Terminal sessions byte-identical: unset, other value, version-only -----
# The same fixture run three ways must produce the same bytes as a plain run
# with no desktop variables at all. Only the entrypoint value "claude-desktop"
# selects desktop mode; CLAUDE_CODE_DESKTOP_APP_VERSION alone does nothing.
repo="$(mk_repo)"; cleanup_on_exit "$repo"
seed "$repo" TERM 4000 150000 claude-opus-5-5
base="$(run_auto "$repo" TERM HANDOFF_CTX_MAX_FLAGS=0 HANDOFF_CTX_COOLDOWN_KB=0)"
check "terminal baseline -> pct printed" yes "$(has "$base" "~15% (estimated) of a 1000000-token window")"
other="$(run_auto "$repo" TERM HANDOFF_CTX_MAX_FLAGS=0 HANDOFF_CTX_COOLDOWN_KB=0 CLAUDE_CODE_ENTRYPOINT=cli)"
check "ENTRYPOINT=cli -> identical to baseline" yes "$([[ "$base" == "$other" ]] && echo yes || echo no)"
veronly="$(run_auto "$repo" TERM HANDOFF_CTX_MAX_FLAGS=0 HANDOFF_CTX_COOLDOWN_KB=0 CLAUDE_CODE_DESKTOP_APP_VERSION=3.0.0)"
check "DESKTOP_APP_VERSION alone -> identical to baseline" yes "$([[ "$base" == "$veronly" ]] && echo yes || echo no)"
desk="$(run_auto "$repo" TERM HANDOFF_CTX_MAX_FLAGS=0 HANDOFF_CTX_COOLDOWN_KB=0 "$DESK")"
check "ENTRYPOINT=claude-desktop -> differs from baseline" no "$([[ "$base" == "$desk" ]] && echo yes || echo no)"

finish
