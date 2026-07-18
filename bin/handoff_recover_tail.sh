#!/usr/bin/env bash
# handoff_recover_tail.sh — recover the final turn(s) a crash dropped from the
# raw dump. Companion to the /handoff-recover skill; NOT a hook (no settings.json
# wiring — the skill invokes it directly).
#
# Why this exists
# ---------------
# The raw dump (`handoff_raw_<id>.md`) is built incrementally by the Stop hook
# (`handoff_turn_append.sh`), which fires *after* each assistant turn. A session
# killed abruptly — OOM, SIGKILL, power loss, terminal closed mid-turn — skips
# its final Stop, so the last exchange is written to the transcript JSONL by
# Claude Code but never folded into the dump. /handoff-recover reads only the
# dump, so without this helper it silently loses that final turn — precisely the
# turn most likely to hold "what I was about to do next."
#
# The gap is exactly recoverable: the Stop hook leaves a cursor file
# (`.handoff_raw_<id>.cursor`) recording how many JSONL lines it folded in, and
# the transcript JSONL is the complete, authoritative record. Everything past the
# cursor is the un-captured tail. This script formats those lines into the same
# readable turn blocks the dump uses and prints them to stdout, so the skill can
# fold them into the recovered Notes.
#
# Usage:
#   handoff_recover_tail.sh <session_id>
#
# Prints the recovered tail to stdout (empty if the dump is already complete).
# Exits 0 in all non-usage cases — a missing transcript or an up-to-date dump is
# a normal "nothing to recover," not an error.
#
# Test/override env vars:
#   HANDOFF_BACKUP_DIR          override the backup dir (default <repo>/.claude/handoff_backups)
#   HANDOFF_RECOVER_TRANSCRIPT  use this exact JSONL path (skip the projects-dir search)
#   HANDOFF_PROJECTS_DIR        projects root to search (default $HOME/.claude/projects)

set -euo pipefail

session_id="${1:-}"
if [[ -z "$session_id" ]]; then
  echo "usage: handoff_recover_tail.sh <session_id>" >&2
  exit 2
fi

# session_id is interpolated into a glob and file paths; accept only the UUID
# charset (same guard as handoff_turn_append.sh) so a crafted value can't escape
# the projects dir or inject glob metacharacters.
if [[ ! "$session_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "handoff_recover_tail.sh: invalid session id" >&2
  exit 2
fi

# --- Locate the backup dir (for the cursor file) ---
if [[ -n "${HANDOFF_BACKUP_DIR:-}" ]]; then
  backup_dir="$HANDOFF_BACKUP_DIR"
else
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  # Off-git, fall back to the Claude Code project dir / cwd, matching the writer
  # hooks so the backup dir resolves to the same place they wrote it.
  [[ -n "$repo_root" ]] || repo_root="${CLAUDE_PROJECT_DIR:-$PWD}"
  [[ -z "$repo_root" ]] && { echo "handoff_recover_tail.sh: cannot resolve project dir and HANDOFF_BACKUP_DIR unset" >&2; exit 0; }
  backup_dir="$repo_root/.claude/handoff_backups"
fi
cursor_file="$backup_dir/.handoff_raw_${session_id}.cursor"

# --- Locate the transcript JSONL ---
# Session ids are globally-unique UUIDs, so glob the projects tree for
# <id>.jsonl rather than reconstructing Claude Code's cwd->slug path encoding
# (which we'd risk getting subtly wrong). An explicit override wins (tests).
if [[ -n "${HANDOFF_RECOVER_TRANSCRIPT:-}" ]]; then
  transcript="$HANDOFF_RECOVER_TRANSCRIPT"
else
  projects_dir="${HANDOFF_PROJECTS_DIR:-$HOME/.claude/projects}"
  transcript=""
  # Nullglob so a no-match leaves the array empty instead of a literal pattern.
  shopt -s nullglob
  for cand in "$projects_dir"/*/"${session_id}.jsonl"; do
    transcript="$cand"; break
  done
  shopt -u nullglob
fi

if [[ -z "$transcript" || ! -f "$transcript" ]]; then
  echo "handoff_recover_tail.sh: no transcript JSONL for session $session_id (nothing to recover)" >&2
  exit 0
fi

# --- Cursor: how many JSONL lines the Stop hook already folded into the dump ---
cursor=0
if [[ -f "$cursor_file" ]]; then
  cursor="$(cat "$cursor_file" 2>/dev/null || echo 0)"
  [[ "$cursor" =~ ^[0-9]+$ ]] || cursor=0
fi

# Count transcript lines. `awk 'END{print NR}'` counts a final line even when it
# lacks a trailing newline — unlike `wc -l`. That matters here precisely because
# a crash-truncated transcript's last line (the turn we most want) often has no
# newline; wc would undercount it and we'd drop it. The Stop hook writes the
# cursor with wc semantics, but cursor <= awk-count always holds, so extracting
# (cursor+1 .. awk-count) is correct and rescues the unterminated final line.
curr="$(awk 'END{print NR}' "$transcript" 2>/dev/null || echo 0)"
[[ "$curr" =~ ^[0-9]+$ ]] || curr=0

# Dump already covers everything (the normal clean-exit case) — nothing to do.
if (( curr <= cursor )); then
  echo "handoff_recover_tail.sh: dump is complete (cursor=$cursor, transcript lines=$curr); no tail to recover" >&2
  exit 0
fi

missing=$(( curr - cursor ))

# --- Noise stripping: mirror handoff_turn_append.sh (perl, cat fallback) ---
if command -v perl >/dev/null 2>&1; then
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
else
  strip_noise() { cat; }
fi

# --- Header ---
printf '## Recovered tail — %d JSONL line(s) past the raw dump cursor\n\n' "$missing"
# shellcheck disable=SC2016  # backticks are literal markdown code spans in the output
printf '_These turns were in the transcript JSONL (`%s`)\n' "$transcript"
# shellcheck disable=SC2016  # backticks are literal markdown code spans in the output
printf 'but were never folded into `handoff_raw_%s.md`: the session ended\n' "$session_id"
printf 'before its final Stop hook fired (crash / SIGKILL / OOM / closed terminal).\n'
printf 'Fold anything load-bearing here into the recovered Notes._\n\n'
printf -- '---\n'

# --- Format the missing lines (cursor+1 .. curr) — same shape as the dump ---
# This jq formatting deliberately mirrors handoff_turn_append.sh's turn block so
# recovered tail reads identically to the rest of the dump. Keep the two in sync.
# `|| [[ -n "$line" ]]` keeps the loop's final iteration when the last line has
# no trailing newline — the crash-truncated tail we count with awk NR above but
# sed emits unterminated. (handoff_turn_append.sh needs no such guard: its wc -l
# cursor never includes that line, so its sed range never reaches it.)
sed -n "$((cursor + 1)),${curr}p" "$transcript" \
| while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    entry_type="$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)"
    case "$entry_type" in
      user)
        content_kind="$(jq -r '.message.content | type' <<<"$line" 2>/dev/null || echo null)"
        if [[ "$content_kind" == "string" ]]; then
          text="$(jq -r '.message.content' <<<"$line" | strip_noise || true)"
          if [[ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ]]; then
            printf '**User:**\n\n%s\n\n' "$text"
          fi
        elif [[ "$content_kind" == "array" ]]; then
          user_text="$(jq -r '.message.content[]? | select(.type == "text") | .text' <<<"$line" 2>/dev/null | strip_noise || true)"
          if [[ -n "$(printf '%s' "$user_text" | tr -d '[:space:]')" ]]; then
            printf '**User:**\n\n%s\n\n' "$user_text"
          fi
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
          if [[ -n "$tool_results" ]]; then printf '%s\n' "$tool_results"; fi
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

exit 0
