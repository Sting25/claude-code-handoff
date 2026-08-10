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
# Payload `cwd`: second-rung anchor for the shared root resolver below.
# Validated as an existing directory before use.
payload_cwd="$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null || true)"
[[ -n "$payload_cwd" && -d "$payload_cwd" ]] || payload_cwd=""

[[ -z "$session_id"        ]] && exit 0
[[ -z "$transcript_path"   ]] && exit 0
# DEFERRED(D2): the Stop payload also carries `last_assistant_message`, which
# could in principle rescue a turn when the transcript is missing/unreadable
# (today: silently lost at this guard). Deliberately NOT implemented: (a) it
# can't replace the transcript read — it holds only the final assistant text,
# not user text / tool calls / tool results / earlier assistant messages, and
# the Stop payload carries no usage or model fields, so the transcript scan
# below stays mandatory regardless; (b) appending a payload-derived block here
# creates a dual-source duplication hazard — if the transcript reappears next
# fire, the cursor (which never advanced) re-captures the same assistant text,
# violating this script's core no-duplication guarantee, and deduping that
# costs more machinery than the rarely-rescued content is worth.
[[ ! -f "$transcript_path" ]] && exit 0

# session_id is interpolated into filesystem paths (dump/cursor/lock/ctx files
# below), so a value carrying a newline, slash, or ".." could break path
# construction or escape the backup dir. Real Claude Code session IDs are UUIDs
# (hex + dashes); accept only [A-Za-z0-9_-] and exit clean on anything else.
[[ "$session_id" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0

# --- Project scope: shared resolver (CLAUDE_PROJECT_DIR -> payload cwd ->
#     $PWD, then git -C toplevel of that anchor). The old bare `git rev-parse`
#     anchored on the hook process's cwd, so when cwd != CLAUDE_PROJECT_DIR
#     (worktrees, submodules, mid-session `cd`) this hook dumped turns under a
#     .claude/ the SessionStart loader (project-dir-anchored) never read.
#     `in_git` gates the git-only .gitignore bootstrap below. Lib absent ->
#     inline the same precedence so the hook stays standalone. ---
prov_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || prov_dir=""
if [[ -n "$prov_dir" && -f "$prov_dir/handoff_provenance.sh" ]]; then
  # shellcheck source=bin/handoff_provenance.sh
  . "$prov_dir/handoff_provenance.sh"
fi
if type handoff_resolve_root >/dev/null 2>&1; then
  handoff_resolve_root "$payload_cwd"
  repo_root="$HANDOFF_ROOT"
  in_git="$HANDOFF_ROOT_IN_GIT"
else
  anchor="${CLAUDE_PROJECT_DIR:-$PWD}"
  [[ -d "$anchor" ]] || anchor="$PWD"
  repo_root="$(git -C "$anchor" rev-parse --show-toplevel 2>/dev/null || true)"
  in_git=1
  if [[ -z "$repo_root" ]]; then
    in_git=0
    repo_root="$anchor"
  fi
fi
[[ -z "$repo_root" ]] && exit 0

backup_dir="$repo_root/.claude/handoff_backups"

# Symlink-safety. The dump is a plain `>>` append (further down), which FOLLOWS a
# symlink at the destination, and it carries verbatim, secret-bearing transcript
# content. A malicious repo can ship `.claude`, `.claude/handoff_backups`, or the
# dump file itself as a symlink pointing outside the repo; on the very first Stop
# fire the session's secrets would be written straight through it to an attacker-
# chosen path (the directory variant needs no session-id knowledge). Refuse to
# write through any symlinked component. The cursor/ctx/flag writes already dodge
# this via mktemp+mv (which replaces the link name rather than following it) —
# only the dump append is exposed. Silent exit (this is a hook); the message is
# visible when the script is run by hand or under the test suite.
refuse_symlink() {  # <path> <label>; warns and returns 1 if <path> is a symlink
  if [[ -L "$1" ]]; then
    echo "handoff_turn_append.sh: $2 ($1) is a symlink; refusing to write through it." >&2
    return 1
  fi
}
refuse_symlink "$repo_root/.claude" ".claude dir" || exit 0
refuse_symlink "$backup_dir"        "backup dir"  || exit 0
mkdir -p "$backup_dir"

# Ensure the backup dir is git-ignored BEFORE we write any dump into it. The
# dumps can carry secrets, and this Stop hook fires on the first prompt — long
# before write_handoff.sh (SessionEnd) bootstraps the .gitignore — so without
# this there is a window where a `git add` could stage a dump into history.
# Mirrors write_handoff.sh's bootstrap and honors the same opt-out env var.
if (( in_git )) \
   && [[ "${HANDOFF_NO_GITIGNORE_BOOTSTRAP:-0}" != "1" ]] \
   && ! git -C "$repo_root" check-ignore -q ".claude/handoff_backups/" 2>/dev/null; then
  gi="$repo_root/.gitignore"
  # Don't append through a symlinked .gitignore (a malicious repo could point it
  # at a victim file). If it's a symlink, skip the bootstrap — the dump is still
  # protected by the backup-dir symlink guard above, and worst case it shows up
  # in `git status` rather than leaking.
  if [[ ! -L "$gi" ]]; then
    existed=1; [[ -e "$gi" ]] || existed=0
    # Best-effort append. An UNWRITABLE .gitignore (root-owned, chmod a-w, a
    # shared checkout) used to abort the whole hook right here under set -e —
    # before the lock, the dump write, and the ctx sidecars — on EVERY Stop
    # fire, silently ('2>/dev/null || true' wiring). The bootstrap is a
    # nicety, not a dependency of the dump: on failure warn and continue,
    # accepting the same degraded outcome as the symlink skip above (the
    # backup dir shows in `git status`). Commands in an `if` condition are
    # exempt from set -e, so the group can fail without killing the script.
    if {
         if [[ -s "$gi" ]] && [[ "$(tail -c1 "$gi" | wc -l)" -eq 0 ]]; then
           printf '\n' >> "$gi"
         fi
         echo ".claude/handoff_backups/" >> "$gi"
       } 2>/dev/null; then
      # A .gitignore is not secret; don't let the script-wide `umask 077` leave a
      # freshly-created one 0600 (see write_handoff.sh). Only normalize a file WE
      # just created; never touch one the user already had.
      (( existed )) || chmod 644 "$gi" 2>/dev/null || true
    else
      echo "handoff_turn_append.sh: cannot append to $gi; skipping .gitignore bootstrap (the backup dir may show in git status)." >&2
    fi
  fi
fi

dump_file="$backup_dir/handoff_raw_${session_id}.md"
cursor_file="$backup_dir/.handoff_raw_${session_id}.cursor"
lock_file="$backup_dir/.handoff_raw_${session_id}.lock"

# backup_dir is confirmed a real dir above; these catch a per-file symlink
# planted at the exact dump or lock name. The dump is the secret-bearing sink,
# but the LOCK file is a truncation primitive of its own: the flock branch
# below opens it with `exec 9>`, and `>` FOLLOWS a symlink at that path —
# there is no mktemp-style safety here (the name is predictable from the
# session id), so a planted link would truncate an attacker-chosen victim
# file. Guard both before anything is opened. (The mkdir-lock fallback needs
# no guard: mkdir/rmdir never follow a symlink.)
refuse_symlink "$dump_file" "dump file" || exit 0
refuse_symlink "$lock_file" "lock file" || exit 0

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
    # reclaim it and retry once. A live Stop hook normally finishes in well
    # under a second, but a FIRST fire over a long backlog (session resume
    # with a new id, cursor evicted by the prune) forks several jq per
    # transcript line and can run for minutes — so the holder re-touches the
    # lock dir at acquisition, between phases, and periodically during the
    # append loop (refresh_lock below), keeping a live lock's mtime fresh,
    # and the default window is 300s: comfortably
    # above both the touch interval and Claude Code's 60s hook timeout, so a
    # slow-but-alive run can't have its lock stolen (which interleaved dump
    # content and clobbered the cursor). Age via GNU `stat -c` with a BSD
    # `stat -f` fallback (this branch only runs where flock is absent —
    # typically macOS/BSD).
    stale_secs="${HANDOFF_LOCK_STALE_SECS:-300}"
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

# Keep the mkdir-lock fresh OUTSIDE the append loop too. The stale reclaim
# above is purely mtime-based, and the loop's periodic touch only starts once
# lines are flowing — a holder stalled BEFORE the loop (a slow `wc -l` over a
# huge transcript, an fs stall) or AFTER it (the whole-transcript usage scan
# below) would look dead past the stale window while still alive, and a
# concurrent Stop fire would steal its lock mid-write. Called immediately
# after acquisition and again before each potentially-slow phase, so no
# refresh-to-refresh gap spans more than one slow operation. Cheap: a single
# `touch -c` (never creates; a vanished dir is a no-op), and a no-op entirely
# under flock, where the OS keeps the lock live for the process lifetime.
refresh_lock() {
  if [[ -n "${lock_mkdir:-}" ]]; then
    touch -c "$lock_mkdir" 2>/dev/null || true
  fi
}
refresh_lock   # stamp explicitly at acquisition; covers the cursor read + wc

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
# perl is the one transcript-processing tool with no POSIX guarantee — it is
# absent from Alpine, minimal containers, and some CI images. Without a fallback,
# the bare `perl` call below exited 127, and under `set -euo pipefail` that
# aborted the hook BEFORE the cursor update — so every turn re-scanned the
# transcript from line 1 and the dump accumulated empty `## Turn` headers,
# capturing nothing (a silent failure of the whole raw-dump safety net, since the
# hook is wired as `... 2>/dev/null || true`). When perl is missing, fall back to
# a passthrough: capturing the turn VERBATIM (noise tags un-stripped) is far
# better than capturing nothing.
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

# --- Initialize dump file on first append ---
if [[ ! -f "$dump_file" ]]; then
  # shellcheck disable=SC2016  # backticks are literal markdown code spans in the output
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

refresh_lock   # entering the append loop; its own periodic touch takes over

# --- Append new turn block ---
{
  printf '\n## Turn at %s\n\n' "$(date -u +'%Y-%m-%d %H:%M:%S UTC')"

  # Process only the new JSONL lines (prev_count+1 .. curr_count)
  lines_since_touch=0
  sed -n "$((prev_count + 1)),${curr_count}p" "$transcript_path" \
  | while IFS= read -r line; do
      # Keep the mkdir-lock fresh during a long backlog append: the stale
      # reclaim above is purely mtime-based, so without this a live holder
      # running past the staleness window would get its lock stolen by a
      # concurrent Stop fire. Every 200 lines (~a couple of seconds of jq
      # forks) is far inside the 300s default window. flock holders don't
      # need it — the OS releases their lock on process exit.
      if [[ -n "${lock_mkdir:-}" ]]; then
        lines_since_touch=$((lines_since_touch + 1))
        if (( lines_since_touch >= 200 )); then
          refresh_lock
          lines_since_touch=0
        fi
      fi
      [[ -z "$line" ]] && continue

      entry_type="$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)"

      case "$entry_type" in
        user)
          content_kind="$(jq -r '.message.content | type' <<<"$line" 2>/dev/null || echo null)"
          if [[ "$content_kind" == "string" ]]; then
            text="$(jq -r '.message.content' <<<"$line" | strip_noise || true)"
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
            # NB: keep this as if/fi, not `[[ ]] && printf`. When tool_results is
            # empty this is the LAST command in the loop body; a bare `&&` would
            # return 1, pipefail would propagate it, and set -e would abort the
            # whole append block before the cursor update — so the cursor never
            # advanced and the next fire re-appended the same turn (duplicate
            # dumps, stale ctx, prune skipped). Reachable whenever the last new
            # transcript line is a user array-message with no tool_result.
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
} >> "$dump_file"

# --- Update cursor atomically (tmp + mv) ---
tmp_cursor="$(mktemp "${cursor_file}.XXXXXX")"
echo "$curr_count" > "$tmp_cursor"
mv -f "$tmp_cursor" "$cursor_file"

refresh_lock   # the usage scan below re-reads the whole transcript (wc + jq)

# --- Record context measurements for the ctx-check UserPromptSubmit hook.
#     Companion script handoff_ctx_check.sh reads these on the next prompt
#     and decides whether to flag a /handoff moment to the model.
#
#     Byte size is the legacy/fallback signal. Token count (sum of input +
#     cache_read + cache_creation from the latest assistant turn's usage)
#     is the real measurement Claude Code's /context uses, and is far more
#     accurate than the 4-bytes-per-token estimate. The model id from the
#     same line goes to .ctx_model_<session_id> so ctx-check can size the
#     context window from the session's OWN model rather than guessing from
#     ~/.claude.json (whose lastModelUsage can be stale or from another
#     session — the source of a 5x over-report on 1M-native models).
#
#     We scan for the LAST assistant line that (a) is on the main chain
#     (not an isSidechain sub-agent turn) and (b) actually carries a usage
#     block, rather than blindly taking the final assistant line. Two real
#     transcripts break the naive `tail -n 1`: a turn whose last assistant
#     line has no usage (sum 0 -> tokens file never written -> the ctx-check
#     hook silently falls back to bytes/4 and over-reports), and a turn ending
#     in a Task sub-agent whose isSidechain usage reflects the sub-agent's
#     small context, not the main thread's. Selecting the last main-chain,
#     usage-bearing line fixes both, so ctx-check's fallback never runs
#     whenever any real usage exists in the transcript.
ctx_file="$backup_dir/.ctx_${session_id}"
tmp_ctx="$(mktemp "${ctx_file}.XXXXXX")"
wc -c < "$transcript_path" | tr -d ' ' > "$tmp_ctx"
mv -f "$tmp_ctx" "$ctx_file"

# One jq pass yields "tokens<TAB>model" per candidate line; the grep keeps
# only well-formed rows (numeric tokens + tab) so a malformed line can't
# poison the tail -n 1 selection, mirroring the old numeric-only filter.
last_usage="$(
  grep '"type":"assistant"' "$transcript_path" 2>/dev/null \
    | jq -r '
        select(.isSidechain != true)
        | select(.message.usage != null)
        | [ ( (.message.usage.input_tokens // 0)
              + (.message.usage.cache_read_input_tokens // 0)
              + (.message.usage.cache_creation_input_tokens // 0) ),
            (.message.model // "") ]
        | @tsv
      ' 2>/dev/null \
    | grep -E $'^[0-9]+\t' \
    | tail -n 1 \
    || true
)"
last_tokens="${last_usage%%$'\t'*}"
last_model="${last_usage#*$'\t'}"
if [[ "$last_tokens" =~ ^[0-9]+$ ]] && (( last_tokens > 0 )); then
  tokens_file="$backup_dir/.ctx_tokens_${session_id}"
  tmp_tokens="$(mktemp "${tokens_file}.XXXXXX")"
  echo "$last_tokens" > "$tmp_tokens"
  mv -f "$tmp_tokens" "$tokens_file"
fi
# Model id charset guard: real ids are like "claude-fable-5" or
# "claude-opus-4-7[1m]" — letters, digits, dot, underscore, dash, brackets.
# Anything else (or empty) is skipped rather than written, since ctx-check
# interpolates nothing from this file but must never trust junk content.
model_re='^[]A-Za-z0-9._[-]+$'
if [[ -n "$last_model" ]] && [[ "$last_model" =~ $model_re ]]; then
  model_file="$backup_dir/.ctx_model_${session_id}"
  tmp_model="$(mktemp "${model_file}.XXXXXX")"
  printf '%s\n' "$last_model" > "$tmp_model"
  mv -f "$tmp_model" "$model_file"
fi

# --- Prune to 3 newest dump files (plus their cursor / ctx / flag files) ---
# `mapfile` is a bash 4 builtin (absent from macOS's stock bash 3.2); read the
# list with a while loop over a process substitution instead. The process-sub
# exit status isn't checked, so a failing glob won't trip `set -e` (same safety
# the mapfile form had).
#
# ONLY DELETE FILES WE GENERATED. The `handoff_raw_*.md` glob is broader than
# what this hook writes, and the filename alone cannot prove ownership: a user's
# hand-dropped `handoff_raw_my_own_archive.md` has an "id" that satisfies the
# same [A-Za-z0-9_-]+ charset real session ids do. Previously such a file
# matched, fell outside the 3 newest by mtime, and was deleted with no warning.
#
# The reliable ownership proof is the COMPANION CURSOR: every dump this hook
# writes gets `.handoff_raw_<id>.cursor` written next to it (tmp+mv, just after
# the append). A file the user placed here has no cursor, so it is never a
# prune candidate. Filtering happens BEFORE the keep-3 cut, so foreign files
# don't consume retention slots and push our real dumps out early.
#
# Safe-direction trade-off: a dump of ours whose cursor was manually removed is
# no longer pruned (it lingers) rather than risking someone else's file. (#46)
list_our_dumps() {
  local f base id
  # shellcheck disable=SC2012  # ls -t is deliberate: prune needs mtime ordering and BSD find has no -printf
  ls -t "$backup_dir"/handoff_raw_*.md 2>/dev/null | while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    base="$(basename "$f" .md)"       # handoff_raw_<id>
    id="${base#handoff_raw_}"
    [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || continue
    [[ -f "$backup_dir/.handoff_raw_${id}.cursor" ]] || continue
    printf '%s\n' "$f"
  done
}
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
  rm -f  -- "$backup_dir/.ctx_model_${id}"
  rm -f  -- "$backup_dir/.ctx_flagged_${id}"
  rm -f  -- "$backup_dir/.ctx_sl_${id}"        # statusline cache sidecar
  rm -f  -- "$backup_dir/.fences_${id}"        # rules re-injection cooldown state (issue #42)
done < <(list_our_dumps | tail -n +4)

exit 0
