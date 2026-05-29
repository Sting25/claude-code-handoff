#!/usr/bin/env bash
# handoff_turn_append.sh — Stop hook companion to /handoff.
#
# Fires after every assistant turn. Reads the new lines that landed in the
# Claude Code transcript JSONL since the previous Stop, formats them into a
# human-readable turn block, and appends to:
#
#   <repo>/.claude/handoff_backups/handoff_raw_<session_id>.md
#
# This makes the raw-dump backup incremental rather than written-all-at-once
# at /handoff time, which is the failure mode this hook hardens against
# (when context is saturated, generating the dump in one shot truncates).
#
# Guards against duplication:
#   - A per-session lockfile (flock) serializes concurrent Stop hook fires.
#   - A cursor file tracks how many transcript lines we've already processed,
#     so the same turn never gets appended twice.
#   - Recurring noise tags Claude Code re-injects each turn (system-reminder,
#     command-name, command-message, command-args, local-command-stdout) are
#     stripped from user-message content before appending.
#
# Keeps only the 3 newest handoff_raw_*.md files in the backup dir (plus
# their cursor files). Pruning is per-repo.

set -euo pipefail

# Raw transcript dumps contain verbatim session content — including anything
# sensitive surfaced in tool output — so every file this hook creates must be
# owner-only. umask 077 makes the backup dir 0700 and the dump 0600 at creation
# time (the mktemp sidecars were already 0600); the defensive chmod below also
# tightens a dump left 0664 by a pre-0.8.1 version on upgrade.
umask 077

# --- Read hook payload ---
payload="$(cat)"
session_id="$(jq -r '.session_id // empty'      <<<"$payload")"
transcript_path="$(jq -r '.transcript_path // empty' <<<"$payload")"

[[ -z "$session_id"        ]] && exit 0
[[ -z "$transcript_path"   ]] && exit 0
[[ ! -f "$transcript_path" ]] && exit 0

# session_id is interpolated into filesystem paths (dump/cursor/lock/ctx files
# below), so a value carrying a newline, slash, or ".." could break path
# construction or escape the backup dir. Real Claude Code session IDs are UUIDs
# (hex + dashes); accept only [A-Za-z0-9_-] and exit clean on anything else.
[[ "$session_id" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0

# --- Repo scope: only run inside git worktrees ---
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$repo_root" ]] && exit 0

backup_dir="$repo_root/.claude/handoff_backups"
mkdir -p "$backup_dir"

# Ensure the backup dir is git-ignored BEFORE we write any dump into it. The
# dumps can carry secrets, and this Stop hook fires on the first prompt — long
# before write_handoff.sh (SessionEnd) bootstraps the .gitignore — so without
# this there is a window where a `git add` could stage a dump into history.
# Mirrors write_handoff.sh's bootstrap and honors the same opt-out env var.
if [[ "${HANDOFF_NO_GITIGNORE_BOOTSTRAP:-0}" != "1" ]] \
   && ! git -C "$repo_root" check-ignore -q ".claude/handoff_backups/" 2>/dev/null; then
  gi="$repo_root/.gitignore"
  if [[ -s "$gi" ]] && [[ "$(tail -c1 "$gi" | wc -l)" -eq 0 ]]; then
    printf '\n' >> "$gi"
  fi
  echo ".claude/handoff_backups/" >> "$gi"
fi

dump_file="$backup_dir/handoff_raw_${session_id}.md"
cursor_file="$backup_dir/.handoff_raw_${session_id}.cursor"
lock_file="$backup_dir/.handoff_raw_${session_id}.lock"

# --- Serialize concurrent invocations: only one Stop hook may process
#     this session at a time. If another instance is already running,
#     we exit cleanly — it will pick up our turn.
#     flock (util-linux) ships on Linux and Git Bash but not macOS; there we
#     fall back to an atomic mkdir lock released by an EXIT trap.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$lock_file"
  if ! flock -n 9; then
    exit 0
  fi
else
  lock_mkdir="${lock_file}.d"
  if ! mkdir "$lock_mkdir" 2>/dev/null; then
    # The mkdir lock is released by the EXIT trap below, but a hard kill
    # (SIGKILL, OOM, power loss) skips traps and leaves the dir behind —
    # which would freeze appends for this session forever. If the existing
    # lock dir is older than the staleness window, the holder is gone:
    # reclaim it and retry once. A live Stop hook finishes in well under a
    # second, so the default 60s window won't steal a lock from a slow-but-
    # alive run. Age via GNU `stat -c` with a BSD `stat -f` fallback (this
    # branch only runs where flock is absent — typically macOS/BSD).
    stale_secs="${HANDOFF_LOCK_STALE_SECS:-60}"
    lock_mtime="$(stat -c %Y "$lock_mkdir" 2>/dev/null \
                  || stat -f %m "$lock_mkdir" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    if [[ "$lock_mtime" =~ ^[0-9]+$ ]] \
       && (( now - lock_mtime >= stale_secs )) \
       && rmdir "$lock_mkdir" 2>/dev/null \
       && mkdir "$lock_mkdir" 2>/dev/null; then
      :   # reclaimed a stale lock; proceed under the trap below
    else
      exit 0
    fi
  fi
  trap 'rmdir "$lock_mkdir" 2>/dev/null || true' EXIT
fi

# --- Cursor: how many transcript lines we've already processed ---
prev_count=0
if [[ -f "$cursor_file" ]]; then
  prev_count="$(cat "$cursor_file" 2>/dev/null || echo 0)"
  # Defend against a non-numeric cursor (corruption); reset to 0.
  [[ "$prev_count" =~ ^[0-9]+$ ]] || prev_count=0
fi
curr_count="$(wc -l < "$transcript_path" | tr -d ' ')"

# Transcript shorter than cursor -> rotated/reset; skip this turn rather
# than risk duplicating prior content. Next turn re-evaluates.
if (( curr_count < prev_count )); then
  exit 0
fi
# Nothing new -> exit clean.
if (( curr_count == prev_count )); then
  exit 0
fi

# --- Strip Claude Code noise tags that get re-injected each turn ---
strip_noise() {
  perl -0pe '
    s{<system-reminder>.*?</system-reminder>\s*}{}gs;
    s{<command-name>.*?</command-name>\s*}{}gs;
    s{<command-message>.*?</command-message>\s*}{}gs;
    s{<command-args>.*?</command-args>\s*}{}gs;
    s{<local-command-stdout>.*?</local-command-stdout>\s*}{}gs;
    s{\n{3,}}{\n\n}g;
  '
}

# --- Initialize dump file on first append ---
if [[ ! -f "$dump_file" ]]; then
  {
    printf '# Raw session dump\n\n'
    printf '**Session ID:** `%s`\n' "$session_id"
    printf '**Started:** %s\n\n' "$(date -u +'%Y-%m-%d %H:%M UTC')"
    printf '_Auto-appended turn-by-turn by the Stop hook (`handoff_turn_append.sh`).\n'
    printf 'Each block below is one user message + the assistant response that\n'
    printf 'followed. Tool outputs are truncated to keep the file readable; the\n'
    printf 'full transcript lives at `%s`. Recurring system-reminder /\n' "$transcript_path"
    printf 'command-* noise has been stripped._\n\n'
    printf -- '---\n'
  } > "$dump_file"
fi
# Tighten perms even on a dump created by a pre-0.8.1 version (umask only
# governs files created during *this* run); the contents may include secrets.
chmod 600 "$dump_file" 2>/dev/null || true

# --- Append new turn block ---
{
  printf '\n## Turn at %s\n\n' "$(date -u +'%Y-%m-%d %H:%M:%S UTC')"

  # Process only the new JSONL lines (prev_count+1 .. curr_count)
  sed -n "$((prev_count + 1)),${curr_count}p" "$transcript_path" \
  | while IFS= read -r line; do
      [[ -z "$line" ]] && continue

      entry_type="$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)"

      case "$entry_type" in
        user)
          content_kind="$(jq -r '.message.content | type' <<<"$line" 2>/dev/null || echo null)"
          if [[ "$content_kind" == "string" ]]; then
            text="$(jq -r '.message.content' <<<"$line" | strip_noise)"
            # Skip if everything was noise
            if [[ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ]]; then
              printf '**User:**\n\n%s\n\n' "$text"
            fi
          elif [[ "$content_kind" == "array" ]]; then
            user_text="$(jq -r '.message.content[]? | select(.type == "text") | .text' <<<"$line" 2>/dev/null | strip_noise || true)"
            if [[ -n "$(printf '%s' "$user_text" | tr -d '[:space:]')" ]]; then
              printf '**User:**\n\n%s\n\n' "$user_text"
            fi
            # Tool results — keep, but truncate. Don't strip noise tags from
            # tool output (it's content, not Claude Code injection).
            tool_results="$(jq -r '
              .message.content[]?
              | select(.type == "tool_result")
              | "**Tool result** (`\(.tool_use_id // "?")`):\n\n```\n" +
                ( (.content
                    | if type == "string" then .
                      elif type == "array" then
                        (map(select(.type == "text") | .text) | join("\n"))
                      else tostring end
                  ) | .[0:800]
                ) + "\n```\n"
            ' <<<"$line" 2>/dev/null || true)"
            [[ -n "$tool_results" ]] && printf '%s\n' "$tool_results"
          fi
          ;;
        assistant)
          asst_text="$(jq -r '.message.content[]? | select(.type == "text") | .text' <<<"$line" 2>/dev/null || true)"
          [[ -n "$asst_text" ]] && printf '**Assistant:**\n\n%s\n\n' "$asst_text"

          tool_calls="$(jq -r '
            .message.content[]?
            | select(.type == "tool_use")
            | "- `\(.name)` — " +
              ( (.input | tostring) | .[0:300]
                | gsub("\n"; " ")
              )
          ' <<<"$line" 2>/dev/null || true)"
          if [[ -n "$tool_calls" ]]; then
            printf '**Tool calls:**\n\n%s\n\n' "$tool_calls"
          fi
          ;;
      esac
    done
} >> "$dump_file"

# --- Update cursor atomically (tmp + mv) ---
tmp_cursor="$(mktemp "${cursor_file}.XXXXXX")"
echo "$curr_count" > "$tmp_cursor"
mv -f "$tmp_cursor" "$cursor_file"

# --- Record context measurements for the ctx-check UserPromptSubmit hook.
#     Companion script handoff_ctx_check.sh reads these on the next prompt
#     and decides whether to flag a /handoff moment to the model.
#
#     Byte size is the legacy/fallback signal. Token count (sum of input +
#     cache_read + cache_creation from the latest assistant turn's usage)
#     is the real measurement Claude Code's /context uses, and is far more
#     accurate than the 4-bytes-per-token estimate.
ctx_file="$backup_dir/.ctx_${session_id}"
tmp_ctx="$(mktemp "${ctx_file}.XXXXXX")"
wc -c < "$transcript_path" | tr -d ' ' > "$tmp_ctx"
mv -f "$tmp_ctx" "$ctx_file"

last_tokens="$(
  grep '"type":"assistant"' "$transcript_path" 2>/dev/null \
    | tail -n 1 \
    | jq -r '
        (.message.usage.input_tokens // 0) +
        (.message.usage.cache_read_input_tokens // 0) +
        (.message.usage.cache_creation_input_tokens // 0)
      ' 2>/dev/null || true
)"
if [[ "$last_tokens" =~ ^[0-9]+$ ]] && (( last_tokens > 0 )); then
  tokens_file="$backup_dir/.ctx_tokens_${session_id}"
  tmp_tokens="$(mktemp "${tokens_file}.XXXXXX")"
  echo "$last_tokens" > "$tmp_tokens"
  mv -f "$tmp_tokens" "$tokens_file"
fi

# --- Prune to 3 newest dump files (plus their cursor / ctx / flag files) ---
# `mapfile` is a bash 4 builtin (absent from macOS's stock bash 3.2); read the
# list with a while loop over a process substitution instead. The process-sub
# exit status isn't checked, so a failing glob won't trip `set -e` (same safety
# the mapfile form had).
while IFS= read -r old; do
  [[ -z "$old" ]] && continue
  rm -f  -- "$old"
  base="$(basename "$old" .md)"      # handoff_raw_<id>
  id="${base#handoff_raw_}"
  rm -f  -- "$backup_dir/.handoff_raw_${id}.cursor"
  rm -f  -- "$backup_dir/.handoff_raw_${id}.lock"
  rm -rf -- "$backup_dir/.handoff_raw_${id}.lock.d"   # mkdir-lock fallback dir
  rm -f  -- "$backup_dir/.ctx_${id}"
  rm -f  -- "$backup_dir/.ctx_tokens_${id}"
  rm -f  -- "$backup_dir/.ctx_flagged_${id}"
done < <(ls -t "$backup_dir"/handoff_raw_*.md 2>/dev/null | tail -n +4)

exit 0
