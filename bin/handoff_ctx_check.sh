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
#                               signal the Stop hook alone can offer)
# Additionally, when the handoff statusLine is wired, handoff_statusline.sh
# caches Claude Code's OWN numbers to:
#   .ctx_sl_<session_id>      — key=value lines: window= (CC's authoritative
#                               context_window_size), tokens= (current_usage
#                               sum), pct=, model=. Preferred over the files
#                               above because it removes the model-id-regex
#                               window guesswork that broke once already
#                               (c0faf38: 5x over-report on 1M-native ids).
# This script itself writes the sidecars below, one pair per ledger (see
# "Progress ledger", issue #69) so a byte count and a token count are never
# compared as if they were the same quantity:
#   .ctx_flagged_<session_id>     : byte-ledger nudge cap/cadence state, one
#                                    line per nudge, "<progress>" or
#                                    "<progress> <pct step>" (issue #173).
#   .ctx_flagged_tok_<session_id> : token-ledger nudge cap/cadence state.
#   .fences_<session_id>          — byte-ledger rules re-injection cooldown
#                                    (issue #42).
#   .fences_tok_<session_id>      — token-ledger rules re-injection cooldown.
#   .ctx_nojq_<session_id>        — once-per-session jq-missing warning marker
#                                    (issue #68), shared with
#                                    handoff_turn_append.sh.
#   .ctx_prompts_<session_id>     — per-session UserPromptSubmit fire counter
#                                    (issue #71, Stop-hook health detector A).
#                                    Incremented on every fire that reaches it;
#                                    once it passes HANDOFF_HEALTH_PROMPTS
#                                    fires with .ctx_<session_id> still absent,
#                                    the Stop hook is provably not running.
#                                    Survives compaction untouched (see
#                                    handoff_compact_reset.sh: prompt count is
#                                    not invalidated by a compaction event).
#   .ctx_health_<session_id>      — once-per-session marker for the warning
#                                    above, same flag-file throttle idiom as
#                                    .ctx_flagged_/.ctx_nojq_.
# This script runs on the next user prompt and, if usage has crossed a
# configurable threshold, emits a <system-reminder> instructing the assistant
# to passively flag a /handoff moment.
#
# Configurable via env (set in ~/.bashrc or ~/.zshrc):
#   HANDOFF_CTX_WINDOW_TOKENS   total context budget in tokens. Wins over
#                               every other window source. When unset, the
#                               window comes from the status line's
#                               context_window_size while that cache is live,
#                               else from the session's own model id (a
#                               "[1m]" suffix, HANDOFF_CTX_1M_MODEL_REGEX, or
#                               the model table in the "Window" section,
#                               checked against the model docs). When none
#                               applies the window is UNKNOWN: the reminder
#                               says so and prints no percentage (issue #173;
#                               the old chain guessed 200k or 1M and printed
#                               the guess as a reading).
#   HANDOFF_CTX_1M_MODEL_REGEX  optional POSIX ERE of model ids you know run
#                               a 1M window, for ids the table does not list
#                               yet. Unset by default (the table decides).
#   HANDOFF_CTX_THRESHOLD_PCT   percent of a known window at which the first
#                               nudge fires (default: 30).
#   HANDOFF_CTX_STEP_PCT        after the first nudge, one more fires each
#                               time usage reaches the next step of this many
#                               percentage points (default: 5, i.e. 30, 35,
#                               40, ...). 0 means no step re-flags.
#   HANDOFF_CTX_THRESHOLD_TOKENS absolute token count that triggers when the
#                               window is UNKNOWN (default: 100000). Ignored
#                               whenever the window is known (issue #173: on
#                               a 1M window issue #119's "first gate wins"
#                               rule nudged at 10%). Set 0 to disable it; an
#                               unknown window then never nudges.
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
#                               Since issue #173 this spaces re-flags only
#                               when the window is unknown (no percentage to
#                               step on); a known window uses STEP_PCT.
#   HANDOFF_CTX_COOLDOWN_TOKENS same, for the token-denominated ledger used
#                               when the Stop hook has recorded nothing and the
#                               nudge is running off the statusline cache alone
#                               (see "Progress ledger" below). Defaults to
#                               HANDOFF_CTX_COOLDOWN_KB converted at the same
#                               4:1 bytes-per-token ratio this script already
#                               uses for its estimate fallback, so one knob
#                               governs both ledgers unless you split them.
#   HANDOFF_CTX_SL_MAX_AGE_SECS how recent .ctx_sl_<sid> must be for any of
#                               its numbers (tokens, pct, window) to count as
#                               live (default: 900). Past it, usage is
#                               measured from the transcript instead. A
#                               statusLine that stops rendering leaves a frozen
#                               cache behind; without an age horizon the hook
#                               would keep nudging off a number that can no
#                               longer change. 0 disables the token ledger
#                               entirely, restoring the pre-#69 behavior of
#                               exiting whenever .ctx_<sid> is absent.
#   HANDOFF_FENCES_REINJECT_KB  transcript growth (KB) between re-injections
#                               of the handoff's provenance-verified rules
#                               block (default: 200; 0 disables). See the
#                               "Rules re-injection" section below.
#   HANDOFF_CTX_MAX_FLAGS       hard cap on how many times a single session
#                               flags. Default 0 (uncapped) in both modes
#                               since issue #173: the STEP_PCT cadence (or the
#                               cooldown, window unknown) spaces the nudges.
#                               Set 1 for the old one-nudge-per-session
#                               behavior, N>1 for up to N nudges.
#   HANDOFF_CTX_NO_STATUSLINE   set to 1 to ignore the .ctx_sl_* statusline
#                               cache entirely, restoring the pre-statusline
#                               detection chain exactly. Debugging / regression
#                               escape hatch; default unset (cache honored).
#   HANDOFF_CTX_NO_DESKTOP_MODE set to 1 to disable desktop mode (issue #144).
#                               In the Claude desktop app the hook environment
#                               carries CLAUDE_CODE_ENTRYPOINT=claude-desktop
#                               and the app shows the real context figure in
#                               its own meter, while the status line (the only
#                               source of used_percentage for hooks) does not
#                               run there. So when that variable is set, no
#                               fresh statusline pct exists, and the window was
#                               not pinned by HANDOFF_CTX_WINDOW_TOKENS, the
#                               reminder reports the token estimate only,
#                               points the model at the app's meter as the
#                               authoritative figure, and omits the inferred
#                               percentage and its window NOTE. Threshold,
#                               cooldown and cap logic are unchanged. Set 1 to
#                               print the inferred percentage anyway. Terminal
#                               sessions (variable unset or any other value)
#                               are unaffected either way.
#   HANDOFF_HEALTH_PROMPTS      Stop-hook health detector A (issue #71):
#                               number of COMPLETED turns (issue #159: main-
#                               chain assistant transcript lines with
#                               stop_reason end_turn, not prompts), with
#                               .ctx_<session_id> still absent, before this
#                               hook warns that the Stop hook appears dead
#                               (default: 3). A Stop hook should write that
#                               file on every turn, so surviving this many
#                               turns with no such file is strong evidence
#                               it never ran this session, rather than just
#                               "no Stop has fired yet" (the first-prompt
#                               case). Warns once per session; see
#                               HANDOFF_NO_HEALTH_WARN to disable outright.
#   HANDOFF_NO_HEALTH_WARN      set to 1 to disable BOTH Stop-hook health
#                               detectors (this hook's detector A above, and
#                               handoff_session_start.sh's retrospective
#                               detector B) — for a project that deliberately
#                               runs without a per-turn safety net. Default
#                               unset (detectors active).
#
# Token count, in order: the live status line cache; the transcript's last
# usage record for this session (the same number Claude Code's /context
# shows); the Stop hook's record of it; and only as the last fallback a 4:1
# bytes-per-token estimate against the transcript JSONL size, labeled as an
# estimate in the output.

set -euo pipefail

# Context check output and state files carry session metadata that may include
# model information and token counts. umask 077 makes all of it owner-only at
# creation time, protecting against unintended disclosure.
umask 077

THRESHOLD_PCT="${HANDOFF_CTX_THRESHOLD_PCT:-30}"
STEP_PCT="${HANDOFF_CTX_STEP_PCT:-5}"
THRESHOLD_TOKENS="${HANDOFF_CTX_THRESHOLD_TOKENS:-100000}"
COOLDOWN_KB="${HANDOFF_CTX_COOLDOWN_KB:-100}"
# Validate numerically, mirroring the MAX_FLAGS guard below. A slightly-
# wrong override ("40%", "100KB", a negative) previously reached the $((...))
# arithmetic raw: bash errored, set -e killed the hook before the emit, and the
# `2>/dev/null || true` hook wiring made the nudge silently disappear for every
# session. Fall back to the defaults instead (a negative THRESHOLD_PCT would
# otherwise also pass and make the threshold always-fire).
[[ "$THRESHOLD_PCT" =~ ^[0-9]+$ ]] || THRESHOLD_PCT=30
[[ "$STEP_PCT" =~ ^[0-9]+$ ]] || STEP_PCT=5
[[ "$THRESHOLD_TOKENS" =~ ^[0-9]+$ ]] || THRESHOLD_TOKENS=100000
[[ "$COOLDOWN_KB"   =~ ^[0-9]+$ ]] || COOLDOWN_KB=100
REMINDER_MODE="${HANDOFF_CTX_REMINDER_MODE:-suggest}"
# Per-session flag cap. Default 0 (uncapped) in both modes since issue #173:
# when the window is known the 5-point step (STEP_PCT) is what spaces the
# nudges, so a cap would only hide the later, more urgent ones. Set
# HANDOFF_CTX_MAX_FLAGS=1 for the old once-per-session behavior.
MAX_FLAGS="${HANDOFF_CTX_MAX_FLAGS:-0}"
# Non-numeric override -> treat as the safe "uncapped" sentinel rather than abort.
[[ "$MAX_FLAGS" =~ ^[0-9]+$ ]] || MAX_FLAGS=0
# How recent the statusline cache must be to count as live (see the
# statusline block below); defined here because both that block and the
# progress ledger read it.
SL_MAX_AGE="${HANDOFF_CTX_SL_MAX_AGE_SECS:-900}"
[[ "$SL_MAX_AGE" =~ ^[0-9]+$ ]] || SL_MAX_AGE=900

# --- Bounded stdin read (issue #160). Canonical copy: read_hook_payload() in
# bin/write_handoff.sh (rationale there); tests/test_stdin_readers_bounded.sh
# diffs this copy against it. Duplicated, not sourced, because the plugin
# (${CLAUDE_PLUGIN_ROOT}/bin) and install.sh ($HOME/.claude/bin) layouts differ
# and this hook must stay dependency-light. Waits HANDOFF_STDIN_TIMEOUT whole
# seconds (default 2, min 1) for a first line, then drains to EOF; a closed
# pipe returns EOF at once.
read_hook_payload() {
  local first="" timeout="${HANDOFF_STDIN_TIMEOUT:-2}"
  # 1 to 4 digits: a longer number passes a bare digit test but `read -t`
  # rejects it ("invalid timeout specification") and the payload would be lost.
  [[ "$timeout" =~ ^[0-9]{1,4}$ ]] || timeout=2
  (( timeout < 1 )) && timeout=1
  if IFS= read -r -t "$timeout" first; then
    # A newline-terminated first line arrived: the rest ends at EOF.
    printf '%s\n%s' "$first" "$(cat 2>/dev/null || true)"
  else
    # EOF, or timeout (first stays empty). bash 4+ keeps an unterminated
    # last line in first (a payload printed without a trailing newline). On
    # bash 3.2 a timeout that fires before any newline discards the partial
    # data, so only a complete first line or an EOF-terminated one survives
    # there (see the issue filed from #158/#160). Nothing more is read.
    printf '%s' "$first"
  fi
}
# --- Read hook payload ---
payload=""
[[ -t 0 ]] || payload="$(read_hook_payload)"
[[ -z "$payload" ]] && exit 0

# >>> AGENT_ID_GUARD (keep identical in all six hook scripts; tests/test_agent_id_guard.sh diffs them)
# --- Subagent guard (issue #145). Hook payloads from inside a subagent carry a
# non-empty "agent_id"; the handoff state belongs to the main session, so do
# nothing (no writes, no stdout) there. Guard on agent_id ONLY: "agent_type"
# is also set for main sessions started with `--agent`. No jq (extraction is
# the same fixed-shape sed used elsewhere in this script). Opt back in with
# HANDOFF_HOOKS_ALLOW_AGENTS=1.
if [ "${HANDOFF_HOOKS_ALLOW_AGENTS:-}" != "1" ]; then
  hook_agent_id="$(printf '%s' "$payload" \
    | LC_ALL=C sed -nE 's/.*"agent_id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
    | head -n 1 || true)"
  [ -z "$hook_agent_id" ] || exit 0
fi
# <<< AGENT_ID_GUARD

# --- jq preflight (issue #68) -----------------------------------------------
# Every jq call below is wired `2>/dev/null || true`, so a missing jq does not
# error here — it yields an empty session_id and this hook exits 0 having done
# nothing, for every prompt of every session, forever. install.sh refuses to
# install without jq (install.d/40-main.sh) and --doctor reports it BROKEN, but
# a PLUGIN install runs neither: `/plugin install` wires hooks/hooks.json and
# never executes the installer, so nothing on that path has ever checked.
# handoff_session_start.sh and handoff_recover_tail.sh already say so out loud;
# this hook and the Stop hook were the two holdouts.
#
# UserPromptSubmit stdout is injected into the session, so this is the one
# place the user reliably reads. Say it ONCE per session (a per-prompt repeat
# of an install-level problem is nagging, not information) and exit clean —
# never break the prompt.
if ! command -v jq >/dev/null 2>&1; then
  # session_id/cwd without jq, the handoff_session_start.sh way: a fixed-shape
  # JSON string field is exactly extractable with sed, and the capture cannot
  # run past the value's closing quote. Only used to key the once-per-session
  # marker and locate the backup dir; anything unparseable degrades to "warn
  # every time", which is the safe direction for a broken install.
  nojq_sid="$(printf '%s' "$payload" \
    | LC_ALL=C sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' \
    | head -n 1 || true)"
  [[ "$nojq_sid" =~ ^[A-Za-z0-9_-]+$ ]] || nojq_sid=""
  nojq_cwd="$(printf '%s' "$payload" \
    | LC_ALL=C sed -nE 's/.*"cwd"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' \
    | head -n 1 || true)"
  [[ -n "$nojq_cwd" && -d "$nojq_cwd" ]] || nojq_cwd=""
  # Same anchor precedence as the shared resolver below, inlined: the lib is
  # sourced further down and this block must stay ahead of every jq consumer.
  nojq_anchor="${CLAUDE_PROJECT_DIR:-${nojq_cwd:-$PWD}}"
  [[ -d "$nojq_anchor" ]] || nojq_anchor="$PWD"
  nojq_root="$(git -C "$nojq_anchor" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$nojq_root" ]] || nojq_root="$nojq_anchor"
  # An empty/invalid session id (unparseable payload, or a value that fails
  # the charset guard above) used to leave nojq_flag empty, which the check
  # below treats as "warn every time", the same branch meant for a directory
  # too unsafe to write a marker into at all. But UserPromptSubmit stdout is
  # injected into context every turn, so that degraded this ~330-char warning
  # from once-per-session to once-per-PROMPT for the (also degraded, jq-less)
  # sessions least able to afford the noise. Fall back to a fixed marker name
  # so throttling still applies; only the genuinely-unwritable-directory case
  # (symlinked .claude or handoff_backups) keeps the warn-anyway behavior.
  nojq_flag=""
  if [[ ! -L "$nojq_root/.claude" && ! -L "$nojq_root/.claude/handoff_backups" ]]; then
    if [[ -n "$nojq_sid" ]]; then
      nojq_flag="$nojq_root/.claude/handoff_backups/.ctx_nojq_${nojq_sid}"
    else
      nojq_flag="$nojq_root/.claude/handoff_backups/.ctx_nojq_unknown"
    fi
  fi
  if [[ -z "$nojq_flag" || ! -f "$nojq_flag" ]]; then
    echo "⚠️  handoff: jq not found on PATH — the per-turn backup (Stop hook) and the context nudge are disabled for this session. Nothing is being recorded, so /handoff will have no raw dump to fall back on. Install jq (brew install jq / apt install jq), then start a new session."
    # Not `mkdir && : > f || true`: that is A && B || C, where C also runs
    # when A succeeds and B fails — shellcheck SC2015, and here it would mean
    # a failed marker write looked identical to a successful one.
    if [[ -n "$nojq_flag" && ! -L "$nojq_flag" ]]; then
      if mkdir -p "$(dirname "$nojq_flag")" 2>/dev/null; then
        : > "$nojq_flag" 2>/dev/null || true
      fi
    fi
  fi
  exit 0
fi

session_id="$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)"
[[ -z "$session_id" ]] && exit 0
# session_id is interpolated into the .ctx_/.ctx_tokens_/.ctx_model_/
# .ctx_flagged_/.ctx_flagged_tok_/.fences_/.fences_tok_/.ctx_nojq_ paths
# below, so a value carrying a slash, newline, or ".." could escape backup_dir.
# Mirror handoff_turn_append.sh's guard (its comment, and the CHANGELOG, describe
# this validation — but it had only ever been applied to the Stop hook, not to
# this companion that interpolates the same value into the same path family).
# Real Claude Code session IDs are UUIDs; accept only [A-Za-z0-9_-] and exit
# clean otherwise.
[[ "$session_id" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0

# Payload `cwd`: second-rung anchor for the shared root resolver below.
# Directory-validated.
payload_cwd="$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null || true)"
[[ -n "$payload_cwd" && -d "$payload_cwd" ]] || payload_cwd=""

# --- Project scope: shared resolver (CLAUDE_PROJECT_DIR -> payload cwd ->
#     $PWD, then git -C toplevel of that anchor). The old bare `git rev-parse`
#     anchored on the hook process's cwd, so with cwd != CLAUDE_PROJECT_DIR
#     (worktrees, submodules, mid-session `cd`) this hook read its ctx
#     sidecars from a .claude/ different from the one the writers used and the
#     nudge silently never fired. Lib absent -> inline the same precedence so
#     the hook stays standalone. (prov_dir is also reused by the fences
#     re-injection block further down.) ---
prov_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || prov_dir=""
if [[ -n "$prov_dir" && -f "$prov_dir/handoff_provenance.sh" ]]; then
  # shellcheck source=bin/handoff_provenance.sh
  . "$prov_dir/handoff_provenance.sh"
fi
if type handoff_resolve_root >/dev/null 2>&1; then
  handoff_resolve_root "$payload_cwd"
  repo_root="$HANDOFF_ROOT"
else
  anchor="${CLAUDE_PROJECT_DIR:-$PWD}"
  [[ -d "$anchor" ]] || anchor="$PWD"
  repo_root="$(git -C "$anchor" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$repo_root" ]] || repo_root="$anchor"
fi
[[ -z "$repo_root" ]] && exit 0

backup_dir="$repo_root/.claude/handoff_backups"
# Refuse symlinked parents, matching handoff_turn_append.sh and
# handoff_statusline.sh. The per-file guards further down cover the individual
# flag/fences writes; this covers the components above them, so the sweep is
# systematic rather than nearly-systematic.
[[ -L "$repo_root/.claude" || -L "$backup_dir" ]] && exit 0
size_file="$backup_dir/.ctx_${session_id}"
tokens_file="$backup_dir/.ctx_tokens_${session_id}"
model_file="$backup_dir/.ctx_model_${session_id}"
flag_file="$backup_dir/.ctx_flagged_${session_id}"
sl_file="$backup_dir/.ctx_sl_${session_id}"

# --- Stop-hook health, detector A (issue #71) --------------------------------
# The Stop hook writes size_file ($backup_dir/.ctx_<session_id>) on every turn.
# Its absence is normally just "no Stop has fired yet" (the first prompt of a
# fresh session) — the pre-existing "nothing recorded" gate a few sections down
# treats it that way and exits quiet. But if size_file is STILL absent after
# several prompts have gone by, that read stops being ambiguous: a working
# Stop hook would have written it long ago. Track how many prompts this
# session has seen (.ctx_prompts_<session_id>, incremented below on every fire
# that reaches this point) and warn ONCE if the threshold is crossed with
# size_file still missing.
#
# Placement: this MUST sit above the ledger-selection block below (which is
# what exits early on "nothing recorded yet" — the exact condition being
# detected here), and it must NOT exit, reorder, or otherwise disturb that
# block: when the statusline cache lets the token ledger take over (Stop hook
# dead, statusLine wired), the nudge below still legitimately fires, and the
# health warning is equally legitimate (the per-turn backup really is dead) —
# both may share one fire. Emitting the health warning first, before the
# ledger logic runs, keeps that order deterministic rather than incidental.
#
# The warn condition checks BOTH size_file AND model_file absent, not size_file
# alone. handoff_compact_reset.sh deletes .ctx_<sid> on every PostCompact fire
# but deliberately KEEPS .ctx_model_<sid> (the model didn't change across
# compaction). A healthy session that auto-compacts therefore has its very next
# prompt see size_file absent with a high prompt_count carried over from before
# the compaction — a false "Stop hook is dead" read on an install that is
# working fine. model_file is Stop-hook-written and survives compaction, so its
# presence is durable evidence the Stop hook has run this session at all; this
# also matches detector B's evidence set in handoff_session_start.sh, which
# treats .ctx_model_ as one of the files ONLY the Stop hook writes.
if [[ "${HANDOFF_NO_HEALTH_WARN:-0}" != "1" ]]; then
  prompts_file="$backup_dir/.ctx_prompts_${session_id}"
  health_flag="$backup_dir/.ctx_health_${session_id}"
  HEALTH_PROMPTS="${HANDOFF_HEALTH_PROMPTS:-3}"
  [[ "$HEALTH_PROMPTS" =~ ^[0-9]+$ ]] || HEALTH_PROMPTS=3
  # Clamp to a minimum of 2: at 0 or 1 the FIRST prompt of every session (Stop
  # has not had a chance to fire yet, healthy or not) would already meet the
  # threshold and warn on every fresh session.
  (( HEALTH_PROMPTS < 2 )) && HEALTH_PROMPTS=2
  if [[ ! -L "$prompts_file" ]]; then
    # Must exist before the mktemp write below. backup_dir's non-symlink-ness
    # was already verified above (the `-L` guard a few lines up); on a project
    # where the Stop hook has never run and no statusLine is wired,
    # handoff_backups/ itself may not exist yet, and without this the mktemp
    # below fails every single fire, the counter never persists, and this
    # detector is inert in exactly the scenario it exists to catch.
    mkdir -p "$backup_dir" 2>/dev/null || true
    prompt_count=0
    if [[ -f "$prompts_file" ]]; then
      prompt_count="$(cat "$prompts_file" 2>/dev/null || echo 0)"
      [[ "$prompt_count" =~ ^[0-9]+$ ]] || prompt_count=0
    fi
    prompt_count=$((prompt_count + 1))
    # tmp+mv, matching the fences-flag write further down: never leave a
    # half-written counter for the next fire to misread.
    if health_tmp="$(mktemp "$backup_dir/.ctx_prompts.XXXXXX" 2>/dev/null)"; then
      { printf '%s\n' "$prompt_count" > "$health_tmp" \
          && mv -f "$health_tmp" "$prompts_file"; } 2>/dev/null \
        || rm -f "$health_tmp" 2>/dev/null || true
    fi
    # Issue #159: warn on COMPLETED turns, not prompts. A prompt can arrive
    # with no turn ever ending (API error: Stop does not fire; user interrupt;
    # queued prompts; background-subagent or cross-session messages), so the
    # prompt counter alone gave false positives. A completed turn is a
    # main-chain assistant transcript line with stop_reason end_turn. Counted
    # in one jq pass, and only once every cheaper marker check has passed.
    # Missing or unreadable transcript_path means 0 turns, so no warning.
    done_turns=0
    if (( prompt_count >= HEALTH_PROMPTS )) && [[ ! -f "$size_file" ]] \
       && [[ ! -f "$model_file" ]] \
       && [[ ! -f "$health_flag" ]] && [[ ! -L "$health_flag" ]]; then
      health_tp="$(jq -r '.transcript_path // empty' <<<"$payload" 2>/dev/null || true)"
      if [[ -n "$health_tp" && -f "$health_tp" && -r "$health_tp" ]]; then
        # Measured stop_reason shapes in real transcripts: tool_use (turn
        # continues), end_turn (turn complete), null (streaming snapshot), and
        # stop_sequence on model "<synthetic>" (API-error placeholder; no
        # Stop fires for it). A turn with thinking is written as TWO assistant
        # lines sharing one message.id, both end_turn, so count DISTINCT ids
        # (uuid as fallback), never lines. A resumed or forked session's
        # transcript also carries earlier sessions' lines with their own
        # sessionId; only this session's lines count (absent sessionId counts).
        done_turns="$(grep -F '"end_turn"' "$health_tp" 2>/dev/null \
          | jq -R --arg sid "$session_id" 'fromjson?
                   | select(.type == "assistant" and .isSidechain != true
                                      and (.sessionId // $sid) == $sid
                                      and .message.stop_reason == "end_turn"
                                      and .message.model != "<synthetic>")
                   | (.message.id // .uuid // empty)' 2>/dev/null \
          | sort -u | grep -c . || true)"
        [[ "$done_turns" =~ ^[0-9]+$ ]] || done_turns=0
      fi
    fi
    if (( done_turns >= HEALTH_PROMPTS )); then
      echo "⚠️  handoff: the Stop hook does not appear to be running this session: no per-turn backup has been recorded after ${done_turns} completed turns. /handoff will have no incremental dump to fall back on if invoked under context pressure. Likely causes, in order: hooks not registered or not dispatching, a symlinked .claude or handoff_backups directory, or a transcript_path the hook could not read. Run the doctor to check: ./install.sh --doctor from a clone, or the plugin's doctor command if you installed via /plugin install."
      if mkdir -p "$backup_dir" 2>/dev/null; then
        : > "$health_flag" 2>/dev/null || true
      fi
    fi
  fi
fi

# --- Statusline cache (written by handoff_statusline.sh when the statusLine
#     is wired). Pure-bash key=value parse — no jq dependency added to the
#     read path. Each value is numeric-validated; anything malformed degrades
#     to "not recorded" and the pre-statusline chain below takes over.
sl_window=""
sl_tokens=""
# sl_pct: Claude Code's own context_window.used_percentage. When present (and
# fresh) it is the number reported to the user, not our tokens/window math.
sl_pct=""
if [[ "${HANDOFF_CTX_NO_STATUSLINE:-0}" != "1" && -f "$sl_file" ]]; then
  while IFS='=' read -r sl_k sl_v; do
    case "$sl_k" in
      window) [[ "$sl_v" =~ ^[0-9]+$ ]] && sl_window="$sl_v" ;;
      tokens) [[ "$sl_v" =~ ^[0-9]+$ ]] && sl_tokens="$sl_v" ;;
      # A used_percentage above 100 is not a real reading (the cache can carry
      # a stale or malformed value, e.g. pct=150.9) and must be treated as
      # absent so the computed fallback below takes over instead of reporting
      # an impossible ~150%.
      pct)
        if [[ "$sl_v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
          sl_p_whole="${sl_v%%.*}"
          sl_p_frac="${sl_v#*.}"
          [[ "$sl_p_frac" == "$sl_v" ]] && sl_p_frac=""
          if (( sl_p_whole < 100 )) || { (( sl_p_whole == 100 )) && [[ -z "${sl_p_frac//0/}" ]]; }; then
            sl_pct="$sl_v"
          fi
        fi
        ;;
    esac
  done < "$sl_file" 2>/dev/null || true
  # Freshness guard: adopt the statusline TOKEN count only while the sl cache
  # is at least as new as the Stop hook's tokens file. Covers the user who
  # unwires the statusLine mid-session — a stale cache would otherwise report
  # a frozen count forever while the Stop hook keeps measuring. If the tokens
  # file is absent, the sl cache wins outright. (Portable mtime: GNU stat -c
  # with BSD stat -f fallback, same idiom as handoff_turn_append.sh.) The
  # cached pct is from the same payload snapshot, so it goes stale with it,
  # and so does its window (PR #177 review: a kept window paired with a newer
  # count from elsewhere printed 125%). The status line supplies both or
  # neither.
  if [[ ( -n "$sl_tokens" || -n "$sl_pct" ) && -f "$tokens_file" ]]; then
    sl_mtime="$(stat -c %Y "$sl_file" 2>/dev/null || stat -f %m "$sl_file" 2>/dev/null || echo 0)"
    tk_mtime="$(stat -c %Y "$tokens_file" 2>/dev/null || stat -f %m "$tokens_file" 2>/dev/null || echo 0)"
    if [[ "$sl_mtime" =~ ^[0-9]+$ && "$tk_mtime" =~ ^[0-9]+$ ]] && (( sl_mtime < tk_mtime )); then
      sl_tokens=""
      sl_pct=""
      sl_window=""
    fi
  fi
  # Age horizon (issue #173): a statusLine that stopped rendering, or the
  # desktop app (which never runs it) after a terminal session, leaves a
  # frozen cache behind. Past HANDOFF_CTX_SL_MAX_AGE_SECS none of its numbers
  # (tokens, pct, window) is treated as live, and the transcript measurement
  # below takes over. 0 skips this check here (it then only disables the
  # tokens ledger, as documented).
  if [[ -n "$sl_tokens$sl_pct$sl_window" ]] && (( SL_MAX_AGE > 0 )); then
    sl_age_mtime="$(stat -c %Y "$sl_file" 2>/dev/null || stat -f %m "$sl_file" 2>/dev/null || echo 0)"
    sl_now="$(date +%s 2>/dev/null || echo 0)"
    [[ "$sl_age_mtime" =~ ^[0-9]+$ ]] || sl_age_mtime=0
    [[ "$sl_now" =~ ^[0-9]+$ ]] || sl_now=0
    # An unreadable mtime (0) is treated as stale: fail quiet, not fail loud.
    if ! (( sl_age_mtime > 0 && sl_now > 0 && sl_now-sl_age_mtime <= SL_MAX_AGE )); then
      sl_tokens=""
      sl_pct=""
      sl_window=""
    fi
  fi
fi

# --- Transcript usage (issue #173) -------------------------------------------
# With no live statusline number, measure the context straight from the
# transcript instead of trusting a byte-size guess: the last main-chain
# assistant line carrying message.usage gives input_tokens +
# cache_read_input_tokens + cache_creation_input_tokens, which is the context
# occupied at that turn (output_tokens is not part of it). Measured
# 2026-11-09 on a real Claude Code transcript (5,054,004 bytes, 229 assistant
# lines, one sessionId, no sidechain lines): last usage 32 + 181548 + 3063 =
# 184,643 tokens, while bytes/4 would have said 1,263,501. Scoping rules, each
# seen in real transcripts: a resumed transcript carries the earlier session's
# lines under its own sessionId (only this session counts; an absent sessionId
# counts as ours); "<synthetic>" API-error placeholders carry all-zero usage
# and would read as an empty context; isSidechain lines are a subagent's own
# context.
#
# Compaction (PR #177 review): Claude Code appends a "compact_boundary"
# system line (it carries sessionId and isSidechain like any other line) and
# writes no assistant usage until the next turn, so the last usage record is
# the PRE-compact size. A usage line older than this session's last boundary
# is therefore not a measurement. When the boundary is the newest relevant
# line, nothing in the transcript measures the post-compact context, and
# the byte size and the Stop hook's record are pre-compact too: tx_compacted
# makes the hook stay silent until the next assistant turn, exactly as main
# does once handoff_compact_reset.sh has cleared the ledger.
#
# Cost (PR #177 review: every usage line was parsed, 580 ms per prompt on a
# 50 MB transcript): only the last 64 lines are read (`tail -n` seeks from
# the end). Measured on macOS, 10 prompts each: 5 MB transcripts 64-67 ms per
# prompt (main 58-63 ms), a 50 MB one with 40 KB lines 91 ms (main 62 ms).
# Byte-bounded tails were slower: `tail -c 2097152` alone cost about 56 ms
# per call, and 400 lines of 40 KB cost 209 ms. The whole file is scanned only
# when those 64 lines hold no line of this session at all (a resumed
# transcript whose current session ended earlier, a long sidechain run). The
# model id on the measured line is the session's own model for the window
# table further down.
tx_tokens=""
tx_model=""
tx_compacted=0
tx_scan() {  # <max lines> ; stdin: transcript. Prints the last "B" or "U<TAB>tokens<TAB>model".
  LC_ALL=C grep -F -e '"usage"' -e 'compact_boundary' 2>/dev/null | tail -n "$1" \
    | jq -rR --arg sid "$session_id" 'fromjson?
        | select(.isSidechain != true and (.sessionId // $sid) == $sid)
        | if (.type == "system" and .subtype == "compact_boundary") then "B"
          elif (.type == "assistant" and .message.usage != null
                and (.message.model // "") != "<synthetic>") then
            [ "U",
              ( (.message.usage.input_tokens // 0)
                + (.message.usage.cache_read_input_tokens // 0)
                + (.message.usage.cache_creation_input_tokens // 0) ),
              (.message.model // "") ] | @tsv
          else empty end' 2>/dev/null \
    | grep -E $'^(B$|U\t[0-9]+\t)' | tail -n 1 || true
}
if [[ -z "$sl_tokens" ]]; then
  tx_path="$(jq -r '.transcript_path // empty' <<<"$payload" 2>/dev/null || true)"
  if [[ -n "$tx_path" && -f "$tx_path" && -r "$tx_path" ]]; then
    tx_row="$(tail -n 64 "$tx_path" 2>/dev/null | tx_scan 64)"
    # Nothing of this session in the last 64 candidate lines of the tail:
    # widen to the whole file (resumed transcript, long sidechain run).
    [[ -n "$tx_row" ]] || tx_row="$(tx_scan 1000000 < "$tx_path")"
    if [[ "$tx_row" == "B" ]]; then
      tx_compacted=1
    elif [[ "$tx_row" == U$'\t'* ]]; then
      tx_row="${tx_row#U$'\t'}"
      tx_t="${tx_row%%$'\t'*}"
      if [[ "$tx_t" =~ ^[0-9]+$ ]] && (( tx_t > 0 )); then
        tx_tokens="$tx_t"
        tx_model="${tx_row#*$'\t'}"
      fi
    fi
  fi
fi
# Compacted with no post-compact measurement yet: every remaining number
# (bytes, Stop-hook tokens) describes the pre-compact context. Silent.
(( tx_compacted )) && exit 0

# --- Progress ledger (issue #69) --------------------------------------------
# Everything below — the nudge cooldown, the flag file, and the fences
# re-injection cadence — needs a monotonically growing "how far has this
# session come" number. Historically that was ONLY the Stop hook's transcript
# byte count (.ctx_<sid>), and its absence exited the hook outright:
#
#     [[ -f "$size_file" ]] || exit 0
#
# The reasoning was sound (a byte-denominated ledger cannot be fed by the
# statusline cache, which carries no byte count) but the consequence was that a
# dead Stop hook did not degrade context watching, it deleted it — silently, at
# any context level, even with Claude Code's own numbers sitting unread in
# .ctx_sl_<sid>. That matters most exactly where the Stop hook is most likely
# to be missing: a plugin install, where the statusline is the only accurate
# context signal there is.
#
# So the ledger is now chosen rather than assumed:
#
#   bytes  — .ctx_<sid> present. IDENTICAL to the previous behavior in every
#            respect: same numbers, same flag files, same cooldown semantics.
#   tokens — .ctx_<sid> absent, but the statusline cache carries a usable token
#            count AND is recent enough to still be live, or (issue #173) the
#            transcript's own usage record measured one. Cooldowns are then
#            denominated in tokens, and the flag/fences ledgers use SEPARATE
#            paths (.ctx_flagged_tok_/.fences_tok_) so a byte count and a token
#            count can never be compared as if they were the same quantity.
#   neither — exit 0, as before.
#
# The token cooldown derives from HANDOFF_CTX_COOLDOWN_KB at the same 4:1
# bytes-per-token ratio this script already uses for its estimate fallback, so
# one knob keeps governing re-flag spacing in both ledgers; override it
# directly with HANDOFF_CTX_COOLDOWN_TOKENS.
#
# Freshness matters more here than on the preferred-tokens path above. That one
# compares the sl cache against the Stop hook's tokens file; with no Stop hook
# there is nothing to compare against, so a statusline that stopped rendering
# would otherwise freeze a count and keep nudging off it forever. Hence an
# absolute age horizon.
ledger="bytes"
current_bytes=0
if [[ -f "$size_file" ]]; then
  current_bytes="$(cat "$size_file" 2>/dev/null || echo 0)"
  [[ "$current_bytes" =~ ^[0-9]+$ ]] || exit 0
elif (( SL_MAX_AGE > 0 )) && [[ -n "$sl_tokens" ]] && (( sl_tokens > 0 )); then
  # sl_tokens survived the age horizon above, so it is live.
  ledger="tokens"
elif (( SL_MAX_AGE > 0 )) && [[ -n "$tx_tokens" ]]; then
  # No Stop-hook byte count and no statusline, but the transcript itself
  # says how full the context is (issue #173): a measurement, so it may
  # drive the token ledger exactly like a statusline count.
  ledger="tokens"
else
  exit 0
fi

# Ledger-specific units. `progress` is what the cooldown/fences arithmetic
# below measures growth in; the flag paths are disjoint per ledger so the two
# numbering systems never meet in one file.
if [[ "$ledger" == "tokens" ]]; then
  progress="${sl_tokens:-$tx_tokens}"
  cooldown_units="${HANDOFF_CTX_COOLDOWN_TOKENS:-$((COOLDOWN_KB * 1024 / 4))}"
  [[ "$cooldown_units" =~ ^[0-9]+$ ]] || cooldown_units=$((COOLDOWN_KB * 1024 / 4))
  flag_file="$backup_dir/.ctx_flagged_tok_${session_id}"
  # Token occupancy is NOT monotonic like transcript bytes: it DROPS on
  # compaction/eviction. The cap+cooldown block below assumes growth-only
  # progress: after a drop, `progress < last_flagged + cooldown_units` stays
  # true forever and the ledger stalls (no further nudge ever, even well past
  # the threshold again). If the current count is lower than the value
  # recorded at the last flag, the drop itself proves the ledger is stale:
  # clear it and let the next crossing be treated as unflagged. Byte path is
  # untouched: transcript bytes only grow, so this can't fire there.
  if [[ -f "$flag_file" ]]; then
    # First field only: since issue #173 a line may carry "<progress> <step>".
    # A line that carries a step is handled by the step cadence further down,
    # which re-arms only after a full-step drop (PR #177 review: clearing the
    # file here on any drop made 35, 34, 35, 34 fire every time).
    last_flagged_tok="$(tail -n 1 "$flag_file" 2>/dev/null || echo 0)"
    tok_has_step=0
    [[ "$last_flagged_tok" == *" "* ]] && tok_has_step=1
    last_flagged_tok="${last_flagged_tok%% *}"
    [[ "$last_flagged_tok" =~ ^[0-9]+$ ]] || last_flagged_tok=0
    if (( ! tok_has_step && progress < last_flagged_tok )); then
      rm -f -- "$flag_file" 2>/dev/null || true
    fi
  fi
else
  progress="$current_bytes"
  cooldown_units=$((COOLDOWN_KB * 1024))
fi

# --- Rules re-injection against decay (issue #42) ----------------------------
# SessionStart loads the handoff's BIND-marked rules with binding framing (see
# handoff_session_start.sh), but that injection ages: as the transcript grows
# it drifts out of attention, and compaction can summarize it away entirely.
# Periodically re-emit JUST the small rules block, gated the same way
# (provenance must verify — untracked + valid HMAC) and cooldown-limited via
# the flag-file pattern the ctx nudge below already uses.
#
#   HANDOFF_FENCES_REINJECT_KB   transcript growth (KB) between re-injections
#                                (default: 200). 0 disables re-injection.
#
# The flag file (.fences_<session_id>) holds the transcript byte size at the
# last (re-)injection. On the first pass of a session it is seeded WITHOUT
# emitting — SessionStart just delivered the rules — so re-injection only
# starts after real growth. This block must never break the ctx nudge below:
# every failure path just skips it.
FENCES_KB="${HANDOFF_FENCES_REINJECT_KB:-200}"
[[ "$FENCES_KB" =~ ^[0-9]+$ ]] || FENCES_KB=200
handoff_doc="$repo_root/.claude/handoff_current.md"
prov_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || prov_dir=""
# Symlink read guard — same refusal as handoff_session_start.sh (read-side twin
# of write_handoff.sh's write guard): handoff_provenance_ok and
# handoff_bind_content below READ the doc (even the HMAC computation cats it),
# and a malicious cloned repo can COMMIT .claude/handoff_current.md as a
# symlink to a file outside the repo. Refuse the read, warn (one visible line
# in the injected hook output), and skip re-injection; the ctx nudge below
# still runs — never crash the hook.
if [[ -L "$handoff_doc" ]]; then
  echo "⚠️  handoff: $handoff_doc is a symlink — refusing to read through it; rules re-injection skipped. Replace the symlink with a regular file to restore it."
elif (( FENCES_KB > 0 )) && [[ -f "$handoff_doc" ]] \
   && [[ -n "$prov_dir" && -f "$prov_dir/handoff_provenance.sh" ]]; then
  # shellcheck source=bin/handoff_provenance.sh
  . "$prov_dir/handoff_provenance.sh"
  if handoff_provenance_ok "$handoff_doc" "$repo_root" ".claude/handoff_current.md" \
     && handoff_bind_has_content "$handoff_doc"; then
    if [[ "$ledger" == "tokens" ]]; then
      fences_flag="$backup_dir/.fences_tok_${session_id}"
      fences_units=$((FENCES_KB * 1024 / 4))
    else
      fences_flag="$backup_dir/.fences_${session_id}"
      fences_units=$((FENCES_KB * 1024))
    fi
    emit_fences=0
    if [[ -f "$fences_flag" ]]; then
      last_fences="$(cat "$fences_flag" 2>/dev/null || echo 0)"
      [[ "$last_fences" =~ ^[0-9]+$ ]] || last_fences=0
      if [[ "$ledger" == "tokens" ]] && (( progress < last_fences )); then
        # Same non-monotonic-drop staleness as the nudge flag above: clear
        # and let the seed-without-emit branch below re-seed from here.
        rm -f -- "$fences_flag" 2>/dev/null || true
      elif (( progress >= last_fences + fences_units )); then
        emit_fences=1
      fi
    fi
    # Seed (first sight) or advance (just emitted) the flag file. mktemp+mv
    # keeps the write atomic; refuse a planted symlink at the flag path,
    # matching the nudge flag guard below.
    if [[ ! -f "$fences_flag" || "$emit_fences" == "1" ]] && [[ ! -L "$fences_flag" ]]; then
      if fences_tmp="$(mktemp "$backup_dir/.fences.XXXXXX" 2>/dev/null)"; then
        # Guard the write+rename so a full disk / unwritable dir can't abort the
        # hook under set -e (the ctx nudge below must still run). Clean up the
        # temp on any failure so we don't leak .fences.XXXXXX orphans.
        { printf '%s\n' "$progress" > "$fences_tmp" \
            && mv -f "$fences_tmp" "$fences_flag"; } 2>/dev/null \
          || rm -f "$fences_tmp" 2>/dev/null || true
      fi
    fi
    if (( emit_fences )); then
      echo "<system-reminder>"
      echo "Re-injecting the standing rules from the session handoff (provenance"
      echo "verified: written locally by write_handoff.sh, untracked in git, valid"
      echo "HMAC). Earlier copies may have drifted out of attention or been"
      echo "compacted away. These bind until the user lifts them:"
      echo
      handoff_bind_content "$handoff_doc" | handoff_defang
      echo "</system-reminder>"
    fi
  fi
fi

# --- Tokens: what is in context right now, and where that number came from.
#     Order (issue #173): the live statusline cache (Claude Code's own
#     current_usage, updated mid-turn), then the transcript's last usage
#     record (measured above), then the Stop hook's record of the same sum
#     (.ctx_tokens_, written at turn end), and only then the bytes/4 guess,
#     which is the LAST fallback and is labeled as such in the output: bytes
#     include tool results, thinking blocks and reminder injections, so it
#     runs high (the "reports ~40% when /context shows ~9%" surprise).
est_tokens=0
token_source=""
if [[ -n "$sl_tokens" ]] && (( sl_tokens > 0 )); then
  est_tokens="$sl_tokens"
  token_source="statusline"
elif [[ -n "$tx_tokens" ]]; then
  est_tokens="$tx_tokens"
  token_source="transcript"
elif [[ -f "$tokens_file" ]]; then
  est_tokens="$(cat "$tokens_file" 2>/dev/null || echo 0)"
  [[ "$est_tokens" =~ ^[0-9]+$ ]] || est_tokens=0
  token_source="stophook"
fi
# The bytes/4 estimate exists only on the bytes ledger; on the tokens ledger
# a real count is what selected the ledger, so there is no byte count to
# estimate from.
if (( est_tokens == 0 )) && [[ "$ledger" == "bytes" ]]; then
  est_tokens=$((current_bytes / 4))
  token_source="estimated"
fi
# Tokens-ledger only: unreachable in practice (a positive count selected the
# ledger), but it keeps that path from ever emitting on a zero measurement.
# The byte path has no such guard and must not gain one: a tiny (even
# zero-byte) .ctx_<sid> with THRESHOLD_PCT=0 still emits, exactly as before #69.
[[ "$ledger" == "tokens" ]] && (( est_tokens == 0 )) && exit 0

# --- Window: how big the context is, and where that number came from.
#
#     Order (issue #173). A percentage is only ever computed against one of
#     these; when none applies the window is UNKNOWN, the reminder says so
#     and prints no percentage, and the absolute HANDOFF_CTX_THRESHOLD_TOKENS
#     gate drives the nudge instead. The old chain guessed (a 200k default,
#     another project's lastModelUsage in ~/.claude.json, a broad model-id
#     regex, a >200k "ratchet" to 1M) and printed the result as if it were a
#     reading: with Opus it "looks wrong all the time".
#       1. HANDOFF_CTX_WINDOW_TOKENS (positive integer): the user's own
#          number, so it wins, as documented since the knob existed (a user
#          may pin a sub-1M budget on purpose).
#       2. The statusline cache's window= (Claude Code's own
#          context_window_size), while the cache is live.
#       3. The session's own model id (the transcript line measured above,
#          else the Stop hook's .ctx_model_): a "[1m]" suffix means 1M; a
#          match for HANDOFF_CTX_1M_MODEL_REGEX (only when the user set it)
#          means 1M; otherwise the table below.
#       4. Otherwise: unknown.
window_tokens=""
window_source="unknown"
window_unknown_why=""
session_model=""
# ':' and '@' are in the charset for provider id shapes (Bedrock
# "anthropic.claude-opus-4-8-v1:0", Vertex "claude-opus-4-8@20260101").
model_charset_re='^[]A-Za-z0-9._:@[-]+$'
model_present=0
env_window="${HANDOFF_CTX_WINDOW_TOKENS:-}"
# A non-positive-integer override (0, negative, or garbage) would make the
# pct arithmetic below divide by zero, fatal under `set -e`. Treat any such
# value as unset. The regex test short-circuits the `(( ))` so a non-numeric
# value never reaches arithmetic.
if [[ "$env_window" =~ ^[0-9]+$ ]] && (( env_window > 0 )); then
  window_tokens="$env_window"
  window_source="env"
elif [[ -n "$sl_window" ]] && (( sl_window > 0 )); then
  window_tokens="$sl_window"
  window_source="statusline"
else
  # Charset-validated (ids can carry "[1m]"), so a tampered value is never
  # printed or trusted. An id that is present but fails the charset is still
  # reported as present (PR #177 review: it used to say "no model id
  # recorded").
  if [[ -n "$tx_model" ]]; then
    model_present=1
    [[ "$tx_model" =~ $model_charset_re ]] && session_model="$tx_model"
  elif [[ -f "$model_file" ]]; then
    session_model="$(cat "$model_file" 2>/dev/null || true)"
    [[ -n "$session_model" ]] && model_present=1
    [[ "$session_model" =~ $model_charset_re ]] || session_model=""
  fi
  if [[ -z "$session_model" ]] && (( model_present )); then
    window_unknown_why="the recorded model id is not in this hook's model table (it has characters this hook will not print)"
  elif [[ -z "$session_model" ]]; then
    window_unknown_why="no status line, no HANDOFF_CTX_WINDOW_TOKENS, no model id recorded"
  elif [[ "$session_model" == *"[1m]"* ]]; then
    window_tokens=1000000
    window_source="model_1m"
  elif [[ -n "${HANDOFF_CTX_1M_MODEL_REGEX:-}" ]] \
       && [[ "$session_model" =~ ${HANDOFF_CTX_1M_MODEL_REGEX} ]]; then
    window_tokens=1000000
    window_source="model_regex"
  else
    # Model table, checked 2026-11-09 against:
    #   https://platform.claude.com/docs/en/about-claude/models/overview
    #   https://platform.claude.com/docs/en/build-with-claude/context-windows
    #   https://code.claude.com/docs/en/model-config
    # 1M by default with no suffix (API docs; Claude Code: "Fable 5.1, Fable
    # 5, Sonnet 5 and later, Haiku 5.5, and Opus 4.7 and later run with the
    # 1M window by default"): Fable 5.1/5, Mythos 5.1/5/Preview, Opus 5.5/5/
    # 4.8/4.7, Sonnet 5.5/5, Haiku 5.5. 200k: Opus 4.5, Sonnet 4.5, Haiku
    # 4.5. Opus 4.6 and Sonnet 4.6 are deliberately NOT listed: in Claude
    # Code they run at 200k unless the "[1m]" variant was picked, and the
    # transcript's model id never carries that suffix (measured 2026-11-09:
    # 0 of 53,604 assistant lines across 400 local transcripts), so the id
    # alone cannot tell. CLAUDE_CODE_DISABLE_1M_CONTEXT=1 makes Claude Code
    # treat the 1M-default models as 200k, so the table follows it.
    #
    # Matching is ANCHORED to the listed family and version (PR #177 review:
    # substring globs gave 1M to unlisted ids such as claude-opus-5-1,
    # claude-sonnet-5-9 and claude-opus-50). Accepted around a listed id: a
    # provider prefix ending in "anthropic." ("us.anthropic.", Bedrock), a
    # "-YYYYMMDD" snapshot date, a Bedrock "-vN" or "-vN:M" suffix and a
    # Vertex "@..." suffix. A model not listed is UNKNOWN, never assumed:
    # add it here once the docs list it.
    tbl=""
    model_base="$session_model"
    if [[ "$model_base" =~ ^([a-z0-9-]+\.)*anthropic\.(.+)$ ]]; then
      model_base="${BASH_REMATCH[2]}"
    fi
    model_base="${model_base%%@*}"
    if [[ "$model_base" =~ ^(.+)-v[0-9]+(:[0-9]+)?$ ]]; then
      model_base="${BASH_REMATCH[1]}"
    fi
    if [[ "$model_base" =~ ^(.+)-[0-9]{8}$ ]]; then
      model_base="${BASH_REMATCH[1]}"
    fi
    case "$model_base" in
      claude-fable-5-1|claude-fable-5|claude-mythos-5-1|claude-mythos-5|claude-mythos-preview|\
      claude-opus-5-5|claude-opus-5|claude-opus-4-8|claude-opus-4-7|\
      claude-sonnet-5-5|claude-sonnet-5|claude-haiku-5-5)
        tbl=1000000
        [[ "${CLAUDE_CODE_DISABLE_1M_CONTEXT:-}" == "1" ]] && tbl=200000
        ;;
      claude-opus-4-6|claude-sonnet-4-6)
        window_unknown_why="model id ${session_model} runs at 200k or 1M depending on whether its [1m] variant was picked, which the id does not record" ;;
      claude-opus-4-5|claude-sonnet-4-5|claude-haiku-4-5)
        tbl=200000 ;;
      *)
        window_unknown_why="model id ${session_model} is not in this hook's model table" ;;
    esac
    if [[ -n "$tbl" ]]; then
      window_tokens="$tbl"
      window_source="model_table"
    fi
  fi
fi
# A MEASURED count above an inferred window proves the inference wrong (the
# old code "ratcheted" to 1M here, which was just another guess). Say unknown.
# Never second-guess the env pin or Claude Code's own window, and never act
# on the bytes/4 estimate, which routinely overshoots.
if [[ "$window_source" == model_* && "$token_source" != "estimated" ]] \
   && (( est_tokens > window_tokens )); then
  window_unknown_why="measured ${est_tokens} tokens exceed the ${window_tokens}-token window listed for ${session_model}"
  window_tokens=""
  window_source="unknown"
fi

# --- Gate and cadence (issue #173) -------------------------------------------
# Window known: the first nudge comes at THRESHOLD_PCT (default 30) and then
# one more each time usage reaches the next STEP_PCT (default 5) step above
# it: 30, 35, 40, ... The absolute THRESHOLD_TOKENS gate does NOT apply, so a
# 1M window no longer nudges at 10% (issue #119's 100k gate fired first
# there). Window unknown: no percentage exists, so THRESHOLD_TOKENS (default
# 100000) is the gate and the KB/token cooldown spaces the re-flags, as
# before. Claude Code's own used_percentage is the figure whenever it is live
# and the window was not pinned by the user (a pin is a different budget, so
# CC's pct would contradict it).
pct=""
pct_from_sl=0
if [[ "$window_source" != "env" && -n "$sl_pct" ]]; then
  # A live used_percentage is a reading even when the cache carried no
  # window= (the size is then unreported, but the fraction is not a guess).
  pct="${sl_pct%%.*}"
  pct_from_sl=1
elif [[ -n "$window_tokens" ]]; then
  pct=$((est_tokens * 100 / window_tokens))
fi
# Never print a percentage above 100 (PR #177 review: bytes/4 printed 126%
# and 631%, an env pin 125%). A count above the window is reported as such
# with no percentage; internally it gates and steps as 100.
pct_over=0
if [[ -n "$pct" ]] && (( pct > 100 )); then
  pct_over=1
  pct=100
fi
if [[ -n "$pct" ]]; then
  (( pct < THRESHOLD_PCT )) && exit 0
  # The step this reading sits on: THRESHOLD_PCT + k * STEP_PCT.
  if (( STEP_PCT > 0 )); then
    cur_step=$(( THRESHOLD_PCT + (pct-THRESHOLD_PCT) / STEP_PCT * STEP_PCT ))
  else
    cur_step="$THRESHOLD_PCT"
  fi
else
  (( THRESHOLD_TOKENS == 0 )) && exit 0
  (( est_tokens < THRESHOLD_TOKENS )) && exit 0
  cur_step=""
fi

# --- Per-session cap + cadence.
#     flag_file holds one line per flag emitted this session: its line count is
#     how many times we've flagged. Each line is "<progress>" (window unknown)
#     or "<progress> <step>" (window known), so the step ledger lives in the
#     same per-session file as the cooldown ledger, never a second one. The
#     first crossing always fires (no prior flag); later ones are gated by the
#     MAX_FLAGS cap and then by the step (window known) or the cooldown growth
#     (window unknown, or a prior line with no step to compare against).
flag_count=0
if [[ -f "$flag_file" ]]; then
  flag_count="$(grep -c '' "$flag_file" 2>/dev/null || echo 0)"
  [[ "$flag_count" =~ ^[0-9]+$ ]] || flag_count=0
  # Cap: 0 means uncapped; otherwise stop once we've flagged MAX_FLAGS times.
  if (( MAX_FLAGS > 0 && flag_count >= MAX_FLAGS )); then
    exit 0
  fi
  last_line="$(tail -n 1 "$flag_file" 2>/dev/null || echo 0)"
  last_flagged="${last_line%% *}"
  last_step=""
  [[ "$last_line" == *" "* ]] && last_step="${last_line##* }"
  [[ "$last_flagged" =~ ^[0-9]+$ ]] || last_flagged=0
  [[ "$last_step" =~ ^[0-9]+$ ]] || last_step=""
  if [[ -n "$cur_step" && -n "$last_step" ]]; then
    # Same step as the last nudge: wait for the next one. A lower reading
    # re-arms only once it is a full STEP_PCT below the last flagged step (a
    # compaction drop qualifies): PR #177 review, 35, 34, 35, 34, 35 fired
    # five times when any drop re-armed.
    (( cur_step == last_step )) && exit 0
    if (( cur_step < last_step )); then
      rearm_step="$STEP_PCT"
      (( rearm_step > 0 )) || rearm_step=1
      rearm_floor=$(( last_step-rearm_step ))
      (( pct > rearm_floor )) && exit 0
    fi
  elif [[ "$ledger" == "tokens" ]] && (( progress < last_flagged )); then
    # Token occupancy dropped below the last flag (compaction): the cooldown
    # ledger is stale, so this crossing counts as fresh (see the tokens-ledger
    # note above; there the file is cleared for step-less lines only).
    :
  elif (( progress < last_flagged + cooldown_units )); then
    exit 0
  fi
fi

# --- Compose and emit the system-reminder ---
# One line that says what was measured, against what window, and where each
# number came from (the owner's complaint in #173 was a percentage that
# "looks wrong all the time" with no way to tell why).
case "$token_source" in
  statusline) tok_src="status line" ;;
  transcript) tok_src="measured from the transcript's last usage record" ;;
  stophook)   tok_src="measured by the Stop hook at the end of the last turn" ;;
  *)          tok_src="ESTIMATED from transcript byte size (bytes/4), the last fallback when no usage record exists; it runs high, treat it as a rough upper bound" ;;
esac
case "$window_source" in
  env)         win_src="from HANDOFF_CTX_WINDOW_TOKENS" ;;
  statusline)  win_src="from the status line's context_window_size" ;;
  model_1m)    win_src="from the [1m] suffix of model id ${session_model}" ;;
  model_regex) win_src="model id ${session_model} matches HANDOFF_CTX_1M_MODEL_REGEX" ;;
  model_table) win_src="from this hook's model table for ${session_model}" ;;
  *)           win_src="" ;;
esac
if (( pct_from_sl )); then
  pct_src="Claude Code's own used_percentage"
else
  pct_src="tokens / window"
fi

# The re-fire wording must match what will actually happen. With a finite cap
# about to be reached, promising a repeat would be false: a user who ignored
# the last nudge would wait for one that never comes. (audit 2026-07-17)
if (( MAX_FLAGS > 0 && flag_count + 1 >= MAX_FLAGS )); then
  repeat_note="Automatic-nudge cap reached (HANDOFF_CTX_MAX_FLAGS=${MAX_FLAGS}): this reminder will not re-fire this session."
elif (( pct_over )); then
  repeat_note="This reminder re-fires only after usage drops and crosses a step again."
elif [[ -n "$cur_step" ]] && (( STEP_PCT > 0 )); then
  repeat_note="Next reminder at ${cur_step}% + ${STEP_PCT} = $((cur_step + STEP_PCT))%."
elif [[ -n "$cur_step" ]]; then
  repeat_note="This reminder will not re-fire unless usage drops and crosses ${THRESHOLD_PCT}% again (HANDOFF_CTX_STEP_PCT=0)."
elif [[ "$ledger" == "tokens" ]]; then
  repeat_note="This reminder will not re-fire for at least another ${cooldown_units} tokens of context growth."
else
  repeat_note="This reminder will not re-fire for at least another ${COOLDOWN_KB}KB of transcript growth."
fi

# --- Desktop mode (issue #144) ---
# In the Claude desktop app the hook environment carries
# CLAUDE_CODE_ENTRYPOINT=claude-desktop, and the app displays the real context
# figure in its own meter. The status line does not run there, so a window
# this hook could use is at best read off the model id, which the app's meter
# already contradicts or confirms on screen. So in that situation the
# reminder carries the token count only and points the model at the meter.
# Conditions, each of which keeps the percentage path when it fails:
#   * entrypoint is the desktop app (a terminal session never changes);
#   * no live statusline pct (CC's own used_percentage is authoritative);
#   * the window was neither pinned by HANDOFF_CTX_WINDOW_TOKENS nor read
#     from a statusline cache: only a model-id window, or an unknown one,
#     qualifies;
#   * HANDOFF_CTX_NO_DESKTOP_MODE is not 1 (the escape hatch).
# Gate, cadence, cap and flag recording above are untouched: only the
# wording of the emitted reminder differs.
desktop_mode=0
if [[ "${CLAUDE_CODE_ENTRYPOINT:-}" == "claude-desktop" ]] \
   && [[ -z "$sl_pct" && "$window_source" != "env" && "$window_source" != "statusline" ]] \
   && [[ "${HANDOFF_CTX_NO_DESKTOP_MODE:-0}" != "1" ]]; then
  desktop_mode=1
fi
if (( desktop_mode )); then
  # Shorter estimate wording here: the app meter shows the real figure.
  [[ "$token_source" == "estimated" ]] \
    && tok_src="ESTIMATED from transcript byte size (bytes/4), the last fallback; it typically runs high"
  # No percentage in this mode, the step promise included.
  [[ "$repeat_note" == "Next reminder at "* ]] \
    && repeat_note="This reminder re-fires after usage grows by another ${STEP_PCT}-point step."
  ctx_head="Context at ~${est_tokens} tokens (${tok_src}). The desktop app's own context meter is the authoritative figure for how full the window is: refer to it rather than inferring a percentage."
  flag_example="about ${est_tokens} tokens of context used (see the app's context meter)"
elif (( pct_over )) && [[ "$token_source" == "estimated" ]]; then
  ctx_head="Context at ~${est_tokens} tokens (${tok_src}), at or above the ${window_tokens}-token window (${win_src}), so no percentage is given."
  flag_example="about ${est_tokens} tokens of context used (an estimate), at or above the ${window_tokens}-token window"
elif (( pct_over )); then
  if [[ "$window_source" == "env" ]]; then
    over_what="the ${window_tokens}-token window pinned by HANDOFF_CTX_WINDOW_TOKENS"
  else
    over_what="the ${window_tokens}-token window (${win_src})"
  fi
  ctx_head="Context at ~${est_tokens} tokens (${tok_src}): the measured count exceeds ${over_what}, so no percentage is given."
  flag_example="about ${est_tokens} tokens of context used, more than ${over_what}"
elif [[ -n "$pct" && -n "$window_tokens" ]]; then
  ctx_head="Context at ~${est_tokens} tokens (${tok_src}), ~${pct}% of a ${window_tokens}-token window (${win_src}; percentage is ${pct_src})."
  flag_example="~${pct}% of context used (${window_tokens}-token window ${win_src})"
elif [[ -n "$pct" ]]; then
  ctx_head="Context at ~${est_tokens} tokens (${tok_src}), ~${pct}% used (${pct_src}; the window size was not reported)."
  flag_example="~${pct}% of context used (Claude Code's own figure)"
else
  ctx_head="Context at ~${est_tokens} tokens (${tok_src}); window unknown (${window_unknown_why}), so no percentage is given."
  flag_example="about ${est_tokens} tokens of context used, window unknown"
fi

case "$REMINDER_MODE" in
  act)
    cat <<EOT
<system-reminder>
${ctx_head} This is your /handoff window. Action: finish the current logical step (in-flight edit, tool sequence, pending commit) and then invoke /handoff yourself; do not ask the user "want me to?" and do not pause to discuss. If you are already at a clean boundary, /handoff now. If the user's most recent prompt is genuinely a new track that needs an answer first, answer it briefly and then /handoff at the next boundary. ${repeat_note}
</system-reminder>
EOT
    ;;
  *)
    cat <<EOT
<system-reminder>
${ctx_head} This is the /handoff window: flag it to the user as a passive mention: no question mark, no "want me to?". One line, e.g. "Flagging: ${flag_example}: natural /handoff moment." ${repeat_note}
</system-reminder>
EOT
    ;;
esac

# --- Record this flag (append one line) so the cap + cadence see it next
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
  if [[ -n "$cur_step" ]]; then
    printf '%s %s\n' "$progress" "$cur_step" >> "$flag_file"
  else
    printf '%s\n' "$progress" >> "$flag_file"
  fi
fi

exit 0
