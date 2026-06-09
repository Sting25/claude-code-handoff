#!/usr/bin/env bash
# handoff_ctx_check.sh — UserPromptSubmit hook companion to the Stop hook.
#
# Each turn, handoff_turn_append.sh records context measurements for the
# Claude Code transcript JSONL to <repo>/.claude/handoff_backups/:
#   .ctx_<session_id>         — transcript byte size (legacy/fallback)
#   .ctx_tokens_<session_id>  — actual token count from the latest assistant
#                               turn's usage (input + cache_read + cache_creation)
# This script runs on the next user prompt and, if usage has crossed a
# configurable threshold, emits a <system-reminder> instructing the assistant
# to passively flag a /handoff moment.
#
# Configurable via env (set in ~/.bashrc or ~/.zshrc):
#   HANDOFF_CTX_WINDOW_TOKENS   total context budget in tokens. When unset,
#                               auto-detected from ~/.claude.json — if this
#                               project's lastModelUsage records a model
#                               with a `[1m]` suffix, defaults to 1000000;
#                               otherwise 200000.
#   HANDOFF_CTX_THRESHOLD_PCT   percent of window that triggers (default: 50).
#                               Lower (e.g. 30) is recommended for projects
#                               that opt into REMINDER_MODE=act below — the
#                               model needs runway to find a clean boundary
#                               before context quality degrades.
#   HANDOFF_CTX_REMINDER_MODE   "suggest" (default) emits a reminder that
#                               instructs the assistant to surface a passive
#                               mention to the user, who decides whether to
#                               /handoff. "act" emits a reminder that
#                               instructs the assistant to wrap up the
#                               current logical step and invoke /handoff
#                               itself, without asking. Set "act" only on
#                               projects where the assistant should
#                               autonomously refresh its context (e.g. the
#                               forge orchestration family). Default stays
#                               "suggest" so non-opted-in projects keep the
#                               gentler behavior.
#   HANDOFF_CTX_COOLDOWN_KB     transcript growth required between re-flags
#                               (default: 100, i.e. wait ~100KB before
#                               flagging again so we don't nag every turn)
#
# Token count comes from the latest assistant turn's `usage` — the same
# number Claude Code's /context shows. When that file is absent (first
# prompt of a fresh session, or an older install that hasn't refreshed
# the Stop hook yet) we fall back to a 4:1 bytes-per-token estimate
# against the transcript JSONL size.

set -euo pipefail

THRESHOLD_PCT="${HANDOFF_CTX_THRESHOLD_PCT:-50}"
COOLDOWN_KB="${HANDOFF_CTX_COOLDOWN_KB:-100}"
REMINDER_MODE="${HANDOFF_CTX_REMINDER_MODE:-suggest}"

# --- Read hook payload ---
payload="$(cat 2>/dev/null || true)"
[[ -z "$payload" ]] && exit 0

session_id="$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)"
[[ -z "$session_id" ]] && exit 0
# session_id is interpolated into the .ctx_/.ctx_tokens_/.ctx_flagged_ paths
# below, so a value carrying a slash, newline, or ".." could escape backup_dir.
# Mirror handoff_turn_append.sh's guard (its comment, and the CHANGELOG, describe
# this validation — but it had only ever been applied to the Stop hook, not to
# this companion that interpolates the same value into the same path family).
# Real Claude Code session IDs are UUIDs; accept only [A-Za-z0-9_-] and exit
# clean otherwise.
[[ "$session_id" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0

# --- Repo scope (matches Stop-hook scoping) ---
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$repo_root" ]] && exit 0

backup_dir="$repo_root/.claude/handoff_backups"
size_file="$backup_dir/.ctx_${session_id}"
tokens_file="$backup_dir/.ctx_tokens_${session_id}"
flag_file="$backup_dir/.ctx_flagged_${session_id}"

# Nothing recorded yet — first prompt of the session, before any Stop fire.
[[ -f "$size_file" ]] || exit 0

current_bytes="$(cat "$size_file" 2>/dev/null || echo 0)"
[[ "$current_bytes" =~ ^[0-9]+$ ]] || exit 0

# --- Window: explicit env wins; otherwise auto-detect from ~/.claude.json.
#     Claude Code stamps the active model (e.g. "claude-opus-4-7[1m]") into
#     .projects[<cwd>].lastModelUsage; presence of the [1m] suffix is our
#     1M-context signal.
#
#     Detection order:
#       1. This project's lastModelUsage has any [1m] entry → 1M
#       2. This project's lastModelUsage exists but no [1m]  → 200k
#          (explicit signal that this project does NOT use 1M)
#       3. This project's lastModelUsage missing/empty       → check globally:
#          if ANY project has [1m] usage, treat the user as a 1M user → 1M;
#          else → 200k. Handles renames (cwd changed, no usage yet) and
#          fresh projects where the user is a 1M user but hasn't typed
#          here yet.
window_tokens="${HANDOFF_CTX_WINDOW_TOKENS:-}"
# A non-positive-integer override (0, negative, or garbage) would make the
# threshold/pct arithmetic below divide by zero — fatal under `set -e`. Treat
# any such value as unset and fall through to auto-detection. The regex test
# short-circuits the `(( ))` so a non-numeric value never reaches arithmetic.
if [[ ! "$window_tokens" =~ ^[0-9]+$ ]] || (( window_tokens == 0 )); then
  window_tokens=200000
  if [[ -f "$HOME/.claude.json" ]]; then
    # Step 1: per-project has [1m].
    if jq -e --arg cwd "$repo_root" '
          (.projects[$cwd].lastModelUsage // {})
          | keys
          | map(select(test("\\[1m\\]")))
          | length > 0
        ' "$HOME/.claude.json" >/dev/null 2>&1; then
      window_tokens=1000000
    # Step 2/3: per-project missing or empty → fall back to global.
    #          (jq returns true when lastModelUsage is null OR keys array is empty.)
    elif jq -e --arg cwd "$repo_root" '
          ((.projects[$cwd].lastModelUsage // {}) | keys | length) == 0
          and
          ([.projects[]?.lastModelUsage // {} | keys[]] | map(select(test("\\[1m\\]"))) | length > 0)
        ' "$HOME/.claude.json" >/dev/null 2>&1; then
      window_tokens=1000000
    fi
  fi
fi
WINDOW_TOKENS="$window_tokens"

# --- Tokens: prefer the real measurement; fall back to bytes/4. ---
est_tokens=0
if [[ -f "$tokens_file" ]]; then
  est_tokens="$(cat "$tokens_file" 2>/dev/null || echo 0)"
  [[ "$est_tokens" =~ ^[0-9]+$ ]] || est_tokens=0
fi
if (( est_tokens == 0 )); then
  est_tokens=$((current_bytes / 4))
fi

# --- Threshold check ---
threshold_tokens=$((WINDOW_TOKENS * THRESHOLD_PCT / 100))
if (( est_tokens < threshold_tokens )); then
  exit 0
fi

# --- Cooldown: only re-flag after meaningful additional growth.
#     Gate applies only to re-flags — the first time a session crosses
#     the threshold, the reminder always fires regardless of transcript
#     byte size. (Otherwise a token-heavy / byte-light session could be
#     gated on the byte minimum even on its first crossing.)
if [[ -f "$flag_file" ]]; then
  last_flagged_bytes="$(cat "$flag_file" 2>/dev/null || echo 0)"
  [[ "$last_flagged_bytes" =~ ^[0-9]+$ ]] || last_flagged_bytes=0
  cooldown_bytes=$((COOLDOWN_KB * 1024))
  if (( current_bytes < last_flagged_bytes + cooldown_bytes )); then
    exit 0
  fi
fi

# --- Compose and emit the system-reminder ---
pct=$((est_tokens * 100 / WINDOW_TOKENS))

case "$REMINDER_MODE" in
  act)
    cat <<EOF
<system-reminder>
Context at ~${est_tokens} tokens (~${pct}% of a ${WINDOW_TOKENS}-token window). This is your /handoff window: quality degrades before the meter runs out, so capturing the prose now is more reliable than waiting. Action: finish the current logical step (in-flight edit, tool sequence, pending commit) and then invoke /handoff yourself — do not ask the user "want me to?" and do not pause to discuss. The model acts on this signal directly. If you are already at a clean boundary, /handoff now. If the user's most recent prompt is genuinely a new track that needs an answer first, answer it briefly and then /handoff at the next boundary; do not start a long new track at this context level. Cooldown: this reminder will not re-fire for ~${COOLDOWN_KB}KB of further transcript growth.
</system-reminder>
EOF
    ;;
  *)
    cat <<EOF
<system-reminder>
Context at ~${est_tokens} tokens (~${pct}% of a ${WINDOW_TOKENS}-token window). This is the documented /handoff window: quality degrades before the meter runs out, so capturing the prose now is more reliable than at 5%. Flag to the user as a passive mention — no question mark, no "want me to?". One line, e.g. "Flagging: ~${pct}% of context used — natural /handoff moment if you want to lock in the prose while I'm still sharp." Don't repeat for at least another ${COOLDOWN_KB}KB of growth.
</system-reminder>
EOF
    ;;
esac

# --- Record this flag so the cooldown is honored on the next prompt ---
tmp_flag="$(mktemp "${flag_file}.XXXXXX")"
echo "$current_bytes" > "$tmp_flag"
mv -f "$tmp_flag" "$flag_file"

exit 0
