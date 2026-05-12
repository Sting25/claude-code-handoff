#!/usr/bin/env bash
# handoff_ctx_check.sh — UserPromptSubmit hook companion to the Stop hook.
#
# Each turn, handoff_turn_append.sh records the byte-size of the Claude Code
# transcript JSONL to <repo>/.claude/handoff_backups/.ctx_<session_id>.
# This script runs on the next user prompt, reads that size, and if
# transcript usage has crossed a configurable threshold, emits a
# <system-reminder> instructing the assistant to passively flag a /handoff
# moment.
#
# Configurable via env (set in ~/.bashrc or ~/.zshrc):
#   HANDOFF_CTX_WINDOW_TOKENS   total context budget in tokens (default: 200000)
#   HANDOFF_CTX_THRESHOLD_PCT   percent of window that triggers (default: 50)
#   HANDOFF_CTX_COOLDOWN_KB     transcript growth required between re-flags
#                               (default: 100, i.e. wait ~100KB before
#                               flagging again so we don't nag every turn)
#
# Byte-to-token estimate is fixed at 4:1 (a rough English+JSON proxy).
# Tune the env vars if your sessions are very tool-heavy (lower ratio) or
# very text-heavy (higher).

set -euo pipefail

WINDOW_TOKENS="${HANDOFF_CTX_WINDOW_TOKENS:-200000}"
THRESHOLD_PCT="${HANDOFF_CTX_THRESHOLD_PCT:-50}"
COOLDOWN_KB="${HANDOFF_CTX_COOLDOWN_KB:-100}"

# --- Read hook payload ---
payload="$(cat 2>/dev/null || true)"
[[ -z "$payload" ]] && exit 0

session_id="$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)"
[[ -z "$session_id" ]] && exit 0

# --- Repo scope (matches Stop-hook scoping) ---
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$repo_root" ]] && exit 0

backup_dir="$repo_root/.claude/handoff_backups"
size_file="$backup_dir/.ctx_${session_id}"
flag_file="$backup_dir/.ctx_flagged_${session_id}"

# Nothing recorded yet — first prompt of the session, before any Stop fire.
[[ -f "$size_file" ]] || exit 0

current_bytes="$(cat "$size_file" 2>/dev/null || echo 0)"
[[ "$current_bytes" =~ ^[0-9]+$ ]] || exit 0

# --- Threshold check ---
# ~4 bytes/token is a rough English+JSON estimate.
est_tokens=$((current_bytes / 4))
threshold_tokens=$((WINDOW_TOKENS * THRESHOLD_PCT / 100))
if (( est_tokens < threshold_tokens )); then
  exit 0
fi

# --- Cooldown: only re-flag after meaningful additional growth ---
last_flagged_bytes=0
if [[ -f "$flag_file" ]]; then
  last_flagged_bytes="$(cat "$flag_file" 2>/dev/null || echo 0)"
  [[ "$last_flagged_bytes" =~ ^[0-9]+$ ]] || last_flagged_bytes=0
fi
cooldown_bytes=$((COOLDOWN_KB * 1024))
if (( current_bytes < last_flagged_bytes + cooldown_bytes )); then
  exit 0
fi

# --- Compose and emit the system-reminder ---
pct=$((est_tokens * 100 / WINDOW_TOKENS))
kb=$((current_bytes / 1024))

cat <<EOF
<system-reminder>
Transcript at ${kb}KB (~${pct}% of a ${WINDOW_TOKENS}-token window). This is the documented /handoff window: quality degrades before the meter runs out, so capturing the prose now is more reliable than at 5%. Flag to the user as a passive mention — no question mark, no "want me to?". One line, e.g. "Flagging: ~${pct}% of context used — natural /handoff moment if you want to lock in the prose while I'm still sharp." Don't repeat for at least another ${COOLDOWN_KB}KB of growth.
</system-reminder>
EOF

# --- Record this flag so the cooldown is honored on the next prompt ---
tmp_flag="$(mktemp "${flag_file}.XXXXXX")"
echo "$current_bytes" > "$tmp_flag"
mv -f "$tmp_flag" "$flag_file"

exit 0
