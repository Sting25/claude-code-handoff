#!/usr/bin/env bash
# handoff_ctx_check.sh — UserPromptSubmit hook companion to the Stop hook.
#
# Each turn, handoff_turn_append.sh records context measurements for the
# Claude Code transcript JSONL to <repo>/.claude/handoff_backups/:
#   .ctx_<session_id>         — transcript byte size (legacy/fallback)
#   .ctx_tokens_<session_id>  — actual token count from the latest assistant
#                               turn's usage (input + cache_read + cache_creation)
#   .ctx_model_<session_id>   — model id from that same assistant turn (the
#                               session's OWN model — the most reliable window
#                               signal we have)
# This script runs on the next user prompt and, if usage has crossed a
# configurable threshold, emits a <system-reminder> instructing the assistant
# to passively flag a /handoff moment.
#
# Configurable via env (set in ~/.bashrc or ~/.zshrc):
#   HANDOFF_CTX_WINDOW_TOKENS   total context budget in tokens. When unset,
#                               auto-detected: if the session's recorded model
#                               (.ctx_model_*) matches the 1M-model regex
#                               below, defaults to 1000000; a recorded
#                               non-matching model means 200000; with no
#                               recorded model, falls back to probing
#                               ~/.claude.json lastModelUsage against the
#                               same regex.
#   HANDOFF_CTX_1M_MODEL_REGEX  POSIX ERE matching model ids known to run a
#                               1M-token context window. Default:
#                                 \[1m\]|claude-(fable|mythos)-
#                               i.e. the `[1m]` beta suffix, plus Claude 5
#                               family ids which are 1M-native WITHOUT any
#                               suffix (the pre-regex detection assumed
#                               [1m]-or-200k and over-reported usage 5x on
#                               those models). Extend it when new 1M models
#                               ship.
#   HANDOFF_CTX_THRESHOLD_PCT   percent of window that triggers (default: 40).
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
#                               flagging again so we don't nag every turn).
#                               Only relevant once re-flags are allowed —
#                               see HANDOFF_CTX_MAX_FLAGS.
#   HANDOFF_CTX_MAX_FLAGS       hard cap on how many times a single session
#                               flags, regardless of growth. Defaults: 1 in
#                               "suggest" mode (one gentle nudge per session,
#                               then silence — a session left idle or running
#                               long won't keep nagging), 0 (= unlimited, gated
#                               only by the cooldown) in "act" mode, where the
#                               assistant is expected to keep refreshing its own
#                               context as it fills. Set 0 to restore the old
#                               always-cooldown-gated behavior; set N>1 to allow
#                               up to N nudges spaced by the cooldown.
#
# Token count comes from the latest assistant turn's `usage` — the same
# number Claude Code's /context shows. When that file is absent (first
# prompt of a fresh session, or an older install that hasn't refreshed
# the Stop hook yet) we fall back to a 4:1 bytes-per-token estimate
# against the transcript JSONL size.

set -euo pipefail

THRESHOLD_PCT="${HANDOFF_CTX_THRESHOLD_PCT:-40}"
COOLDOWN_KB="${HANDOFF_CTX_COOLDOWN_KB:-100}"
# Validate both numerically, mirroring the MAX_FLAGS guard below. A slightly-
# wrong override ("40%", "100KB", a negative) previously reached the $((...))
# arithmetic raw: bash errored, set -e killed the hook before the emit, and the
# `2>/dev/null || true` hook wiring made the nudge silently disappear for every
# session. Fall back to the defaults instead (a negative THRESHOLD_PCT would
# otherwise also pass and make the threshold always-fire).
[[ "$THRESHOLD_PCT" =~ ^[0-9]+$ ]] || THRESHOLD_PCT=40
[[ "$COOLDOWN_KB"   =~ ^[0-9]+$ ]] || COOLDOWN_KB=100
REMINDER_MODE="${HANDOFF_CTX_REMINDER_MODE:-suggest}"
# Per-session flag cap. Default depends on mode: "suggest" nudges once and then
# stays quiet (the common complaint is over-nagging on long/idle sessions);
# "act" leaves it uncapped so an autonomous project keeps self-refreshing.
if [[ -n "${HANDOFF_CTX_MAX_FLAGS:-}" ]]; then
  MAX_FLAGS="$HANDOFF_CTX_MAX_FLAGS"
elif [[ "$REMINDER_MODE" == "act" ]]; then
  MAX_FLAGS=0
else
  MAX_FLAGS=1
fi
# Non-numeric override -> treat as the safe "uncapped" sentinel rather than abort.
[[ "$MAX_FLAGS" =~ ^[0-9]+$ ]] || MAX_FLAGS=0

# --- Read hook payload ---
payload="$(cat 2>/dev/null || true)"
[[ -z "$payload" ]] && exit 0

session_id="$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)"
[[ -z "$session_id" ]] && exit 0
# session_id is interpolated into the .ctx_/.ctx_tokens_/.ctx_model_/.ctx_flagged_ paths
# below, so a value carrying a slash, newline, or ".." could escape backup_dir.
# Mirror handoff_turn_append.sh's guard (its comment, and the CHANGELOG, describe
# this validation — but it had only ever been applied to the Stop hook, not to
# this companion that interpolates the same value into the same path family).
# Real Claude Code session IDs are UUIDs; accept only [A-Za-z0-9_-] and exit
# clean otherwise.
[[ "$session_id" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0

# --- Project scope (matches Stop-hook scoping): git worktree top, else the
#     Claude Code project dir / cwd so non-git projects work too. ---
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || repo_root="${CLAUDE_PROJECT_DIR:-$PWD}"
[[ -z "$repo_root" ]] && exit 0

backup_dir="$repo_root/.claude/handoff_backups"
size_file="$backup_dir/.ctx_${session_id}"
tokens_file="$backup_dir/.ctx_tokens_${session_id}"
model_file="$backup_dir/.ctx_model_${session_id}"
flag_file="$backup_dir/.ctx_flagged_${session_id}"

# Nothing recorded yet — first prompt of the session, before any Stop fire.
[[ -f "$size_file" ]] || exit 0

current_bytes="$(cat "$size_file" 2>/dev/null || echo 0)"
[[ "$current_bytes" =~ ^[0-9]+$ ]] || exit 0

# --- Window: explicit env wins; otherwise auto-detect.
#
#     Detection order:
#       1. HANDOFF_CTX_WINDOW_TOKENS override (positive integer)   → as given
#       2. .ctx_model_<session_id> recorded by the Stop hook — the session's
#          OWN model, strictly better evidence than lastModelUsage:
#          matches the 1M regex → 1M; valid but no match → 200k (still
#          subject to the measured-tokens ratchet below).
#       3. No model file (first prompt, or a stale Stop hook) — probe
#          ~/.claude.json, where Claude Code stamps the active model
#          (e.g. "claude-opus-4-7[1m]") into .projects[<cwd>].lastModelUsage:
#          a. This project's lastModelUsage has a 1M-regex match → 1M
#          b. This project's lastModelUsage exists but no match  → 200k
#             (explicit signal that this project does NOT use 1M)
#          c. This project's lastModelUsage missing/empty        → check
#             globally: if ANY project has a matching model, treat the user
#             as a 1M user → 1M; else → 200k. Handles renames (cwd changed,
#             no usage yet) and fresh projects where the user is a 1M user
#             but hasn't typed here yet.
#
# The regex is a POSIX ERE, used both with bash `=~` and jq `test()`; the
# bash-escaped default passes through --arg with single backslashes, which is
# exactly the ERE jq expects. See the header for what the default matches.
ONE_M_MODEL_RE="${HANDOFF_CTX_1M_MODEL_REGEX:-\[1m\]|claude-(fable|mythos)-}"
window_tokens="${HANDOFF_CTX_WINDOW_TOKENS:-}"
window_source="env"
# A non-positive-integer override (0, negative, or garbage) would make the
# threshold/pct arithmetic below divide by zero — fatal under `set -e`. Treat
# any such value as unset and fall through to auto-detection. The regex test
# short-circuits the `(( ))` so a non-numeric value never reaches arithmetic.
if [[ ! "$window_tokens" =~ ^[0-9]+$ ]] || (( window_tokens == 0 )); then
  window_source="auto"
  window_tokens=200000
  # Step 2: the session's own recorded model. Charset-validated with the same
  # guard the Stop hook applies before writing (ids can carry "[1m]"), so a
  # tampered file degrades to "no model recorded" rather than being trusted.
  session_model=""
  model_charset_re='^[]A-Za-z0-9._[-]+$'
  if [[ -f "$model_file" ]]; then
    session_model="$(cat "$model_file" 2>/dev/null || true)"
    [[ "$session_model" =~ $model_charset_re ]] || session_model=""
  fi
  if [[ -n "$session_model" ]]; then
    if [[ "$session_model" =~ $ONE_M_MODEL_RE ]]; then
      window_tokens=1000000
    fi
  elif [[ -f "$HOME/.claude.json" ]]; then
    # Step 3a: per-project has a 1M-regex match.
    if jq -e --arg cwd "$repo_root" --arg re "$ONE_M_MODEL_RE" '
          (.projects[$cwd].lastModelUsage // {})
          | keys
          | map(select(test($re)))
          | length > 0
        ' "$HOME/.claude.json" >/dev/null 2>&1; then
      window_tokens=1000000
    # Step 3b/3c: per-project missing or empty → fall back to global.
    #          (jq returns true when lastModelUsage is null OR keys array is empty.)
    elif jq -e --arg cwd "$repo_root" --arg re "$ONE_M_MODEL_RE" '
          ((.projects[$cwd].lastModelUsage // {}) | keys | length) == 0
          and
          ([.projects[]?.lastModelUsage // {} | keys[]] | map(select(test($re))) | length > 0)
        ' "$HOME/.claude.json" >/dev/null 2>&1; then
      window_tokens=1000000
    fi
  fi
fi
WINDOW_TOKENS="$window_tokens"

# --- Tokens: prefer the real measurement; fall back to bytes/4. ---
# token_source records which path won so the emitted reminder can say so. A
# bytes/4 estimate runs high — transcript bytes include tool results, thinking
# blocks, and reminder injections that aren't in the real context window — so a
# reader must not treat an estimated pct as ground truth (this is the "reports
# ~40% when /context shows ~9%" surprise). When the Stop hook has recorded real
# usage (.ctx_tokens_*), the source stays "measured" and the note is empty, so
# normal reminders are byte-for-byte unchanged.
est_tokens=0
token_source="measured"
if [[ -f "$tokens_file" ]]; then
  est_tokens="$(cat "$tokens_file" 2>/dev/null || echo 0)"
  [[ "$est_tokens" =~ ^[0-9]+$ ]] || est_tokens=0
fi
if (( est_tokens == 0 )); then
  est_tokens=$((current_bytes / 4))
  token_source="estimated"
fi

# --- Ratchet: a MEASURED count above 200k tokens cannot fit a 200k window, so
#     a smaller AUTO-DETECTED window is provably wrong (e.g. a 1M-native model
#     the regex doesn't know yet). Widen to 1M; never narrow, never ratchet on
#     the bytes/4 estimate (it routinely overshoots the real count), and never
#     second-guess an explicit HANDOFF_CTX_WINDOW_TOKENS — a user may pin a
#     sub-1M budget on purpose (e.g. to rehearse 200k behavior on a 1M tier),
#     and the documented contract is that the env override always wins.
if [[ "$window_source" == "auto" && "$token_source" == "measured" ]] \
   && (( est_tokens > 200000 && WINDOW_TOKENS < 1000000 )); then
  WINDOW_TOKENS=1000000
fi

# --- Threshold check ---
threshold_tokens=$((WINDOW_TOKENS * THRESHOLD_PCT / 100))
if (( est_tokens < threshold_tokens )); then
  exit 0
fi

# --- Per-session cap + cooldown.
#     flag_file holds one line per flag emitted this session: its line count is
#     how many times we've flagged, its last line is the byte size at the most
#     recent flag. The first crossing always fires (no prior flag); subsequent
#     ones are gated by (a) the MAX_FLAGS cap and (b) the cooldown growth.
if [[ -f "$flag_file" ]]; then
  flag_count="$(grep -c '' "$flag_file" 2>/dev/null || echo 0)"
  [[ "$flag_count" =~ ^[0-9]+$ ]] || flag_count=0
  # Cap: 0 means uncapped; otherwise stop once we've flagged MAX_FLAGS times.
  if (( MAX_FLAGS > 0 && flag_count >= MAX_FLAGS )); then
    exit 0
  fi
  last_flagged_bytes="$(tail -n 1 "$flag_file" 2>/dev/null || echo 0)"
  [[ "$last_flagged_bytes" =~ ^[0-9]+$ ]] || last_flagged_bytes=0
  cooldown_bytes=$((COOLDOWN_KB * 1024))
  if (( current_bytes < last_flagged_bytes + cooldown_bytes )); then
    exit 0
  fi
fi

# --- Compose and emit the system-reminder ---
pct=$((est_tokens * 100 / WINDOW_TOKENS))

# On the bytes/4 fallback, mark the figure as an estimate so a reader (and the
# model acting on this reminder) knows the pct is a rough upper bound, not the
# measured /context value. Empty in the measured path -> reminders unchanged.
if [[ "$token_source" == "estimated" ]]; then
  est_note=' NOTE: this figure is ESTIMATED from transcript byte size (bytes/4), not a measured token count — the per-turn Stop hook has not recorded real usage for this session (it may be uninstalled, stale from an upgrade, or this is the first turn). The byte estimate typically runs high, so the true percentage is likely lower; treat it as a rough upper bound.'
else
  est_note=''
fi

case "$REMINDER_MODE" in
  act)
    cat <<EOF
<system-reminder>
Context at ~${est_tokens} tokens (~${pct}% of a ${WINDOW_TOKENS}-token window).${est_note} This is your /handoff window: quality degrades before the meter runs out, so capturing the prose now is more reliable than waiting. Action: finish the current logical step (in-flight edit, tool sequence, pending commit) and then invoke /handoff yourself — do not ask the user "want me to?" and do not pause to discuss. The model acts on this signal directly. If you are already at a clean boundary, /handoff now. If the user's most recent prompt is genuinely a new track that needs an answer first, answer it briefly and then /handoff at the next boundary; do not start a long new track at this context level. Cooldown: this reminder will not re-fire for ~${COOLDOWN_KB}KB of further transcript growth.
</system-reminder>
EOF
    ;;
  *)
    cat <<EOF
<system-reminder>
Context at ~${est_tokens} tokens (~${pct}% of a ${WINDOW_TOKENS}-token window).${est_note} This is the documented /handoff window: quality degrades before the meter runs out, so capturing the prose now is more reliable than at 5%. Flag to the user as a passive mention — no question mark, no "want me to?". One line, e.g. "Flagging: ~${pct}% of context used — natural /handoff moment if you want to lock in the prose while I'm still sharp." Don't repeat for at least another ${COOLDOWN_KB}KB of growth.
</system-reminder>
EOF
    ;;
esac

# --- Record this flag (append one line) so the cap + cooldown see it next
#     prompt. UserPromptSubmit hooks run serially per session, so a plain append
#     is safe here (no concurrent writers like the Stop hook). Refuse a planted
#     symlink at the flag path, matching the Stop hook's dump guard.
if [[ ! -L "$flag_file" ]]; then
  # If a pre-existing flag file (e.g. a single value written by a pre-cap
  # version, or a hand-edited one) lacks a trailing newline, our append would
  # fuse onto its last line and undercount. Normalize first, like the Stop
  # hook does for .gitignore.
  if [[ -s "$flag_file" ]] && [[ "$(tail -c1 "$flag_file" | wc -l)" -eq 0 ]]; then
    printf '\n' >> "$flag_file"
  fi
  printf '%s\n' "$current_bytes" >> "$flag_file"
fi

exit 0
