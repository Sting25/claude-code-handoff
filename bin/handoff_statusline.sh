#!/usr/bin/env bash
# handoff_statusline.sh — statusLine command for Claude Code.
#
# Prints one short status line (model | ctx % | handoff state) AND sideband-
# caches Claude Code's OWN context numbers for the ctx-check hook.
#
# Why this script exists: the statusLine payload is the only place Claude Code
# hands us its authoritative `context_window.context_window_size` and
# `used_percentage`. Every other window signal we have is inference — the Stop
# hook can only guess the window from model-id regexes, and that guessing broke
# once already (commit c0faf38: 1M-native Claude 5 ids carry no `[1m]` suffix,
# so detection resolved 200k and sessions were told they'd used 5x more context
# than they had). Caching CC's own numbers here lets handoff_ctx_check.sh skip
# the regex guesswork entirely whenever the statusline is wired.
#
# Cache: <repo>/.claude/handoff_backups/.ctx_sl_<session_id>, key=value lines
# (window= / tokens= / pct= / model=). One file rather than one-per-value so a
# single atomic mv guarantees all values come from the same payload snapshot
# (no torn reads across sidecars).
#
# Token derivation order (deliberate):
#   1. context_window.current_usage sum (input + cache_read + cache_creation —
#      the same sum /context shows and the Stop hook records)
#   2. used_percentage x context_window_size / 100 (used_percentage has existed
#      since CC 2.1.6 and always had current-usage semantics)
#   3. omit tokens entirely.
# `total_input_tokens` / `total_output_tokens` are NEVER read: their semantics
# flipped at CC 2.1.132 (cumulative -> current), so on older CC they'd be a
# confidently-wrong "measured" number. The order above sidesteps that hazard.
#
# Degradation contract: every parsed field is optional. No jq -> static minimal
# line, no cache. No context_window (pre-2.1.6 CC) -> model-only line. Display
# is printed BEFORE the cache write and the write is failure-guarded — the
# status line must never die to a cache problem.

set -euo pipefail
# The cache sidecar lives next to the secret-bearing raw dumps; keep everything
# we create owner-only, matching the other hooks.
umask 077

# --- Read the statusLine payload ---
payload="$(cat 2>/dev/null || true)"
[[ -z "$payload" ]] && exit 0

# No jq: we can't parse anything. Print a minimal static line (so the user sees
# the statusline is alive but degraded, not silently broken) and write no cache.
if ! command -v jq >/dev/null 2>&1; then
  printf 'handoff (ctx n/a - jq missing)\n'
  exit 0
fi

# --- Parse (every field optional; `// empty` + numeric validation throughout,
#     so an absent/renamed field on any CC version degrades a segment rather
#     than killing the line) ---
session_id="$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)"
model="$(jq -r '.model.display_name // .model.id // empty' <<<"$payload" 2>/dev/null || true)"
# Model text is display-bound; strip control chars so a weird payload can't
# smuggle a newline into the one-line output or the cache file.
model="$(printf '%s' "$model" | LC_ALL=C tr -d '\000-\037')"
window="$(jq -r '.context_window.context_window_size // empty' <<<"$payload" 2>/dev/null || true)"
[[ "$window" =~ ^[0-9]+$ ]] || window=""
pct_raw="$(jq -r '.context_window.used_percentage // empty' <<<"$payload" 2>/dev/null || true)"
[[ "$pct_raw" =~ ^[0-9]+(\.[0-9]+)?$ ]] || pct_raw=""
# current_usage may be null (pre-first-API-call, or just-compacted); a numeric
# form is accepted too in case the field's shape ever simplifies.
usage_sum="$(jq -r '
  .context_window.current_usage
  | if type == "object" then
      ((.input_tokens // 0) + (.cache_read_input_tokens // 0)
        + (.cache_creation_input_tokens // 0)) | tostring
    elif type == "number" then tostring
    else empty end
' <<<"$payload" 2>/dev/null || true)"
[[ "$usage_sum" =~ ^[0-9]+$ ]] || usage_sum=""

# --- Project scope. workspace/cwd come from the payload (docs claim the
#     statusline runs in the project dir, but that claim is unverified — trust
#     the payload first, fall back to $PWD), then the same git-top/-project-dir
#     chain the other hooks use. ---
dir="$(jq -r '.workspace.project_dir // .cwd // empty' <<<"$payload" 2>/dev/null || true)"
[[ -n "$dir" && -d "$dir" ]] || dir="$PWD"
repo_root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || repo_root="${CLAUDE_PROJECT_DIR:-$dir}"

# --- Token derivation (see header for why total_* are never read) ---
tokens=""
if [[ -n "$usage_sum" ]] && (( usage_sum > 0 )); then
  tokens="$usage_sum"
elif [[ -n "$pct_raw" && -n "$window" ]]; then
  # Integer-truncate the percentage; statusline precision doesn't warrant
  # float math (and bash arithmetic can't do it portably anyway).
  tokens=$(( window * ${pct_raw%%.*} / 100 ))
fi

# --- Handoff state for the display segment.
#     curated = handoff_current.md exists without the placeholder sentinel,
#     auto    = sentinel present (safety-net write, no /handoff curation yet),
#     none    = no handoff written.
#     A cheap whole-file grep is acceptable HERE because this is display-only;
#     write_handoff.sh keeps its position-scoped check for the clobber-gating
#     decision (a curated file quoting the sentinel shows "auto" for a moment
#     in the statusline — cosmetic — but is never overwritten).
HANDOFF_PLACEHOLDER_SENTINEL="<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->"
handoff_state="none"
handoff_doc="$repo_root/.claude/handoff_current.md"
if [[ -f "$handoff_doc" ]]; then
  if grep -qF "$HANDOFF_PLACEHOLDER_SENTINEL" "$handoff_doc" 2>/dev/null; then
    handoff_state="auto"
  else
    handoff_state="curated"
  fi
fi

# --- Compose and print the line. Plain ASCII, no ANSI color (statusline
#     renderers vary; a broken escape is worse than a plain line). Segments
#     degrade independently: no context_window -> model-only line. ---
line=""
[[ -n "$model" ]] && line="$model"
if [[ -n "$tokens" && -n "$window" ]] && (( window > 0 )); then
  seg="$(printf 'ctx %s%% (%sk/%sk)' "$(( tokens * 100 / window ))" \
         "$(( tokens / 1000 ))" "$(( window / 1000 ))")"
  line="${line:+$line | }$seg"
fi
line="${line:+$line | }handoff: $handoff_state"
printf '%s\n' "$line"

# --- Cache write (best-effort; the line above is already out) ---
write_cache() {
  # session_id is interpolated into the cache path; same charset guard (and
  # same reasoning) as handoff_ctx_check.sh / handoff_turn_append.sh — a value
  # carrying a slash, newline, or ".." could escape backup_dir.
  [[ "$session_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 0
  local bd="$repo_root/.claude/handoff_backups"
  # Refuse symlinked parents (malicious-repo guard, mirroring the Stop hook):
  # mkdir -p / mv would traverse them. The cache FILE itself needs no guard —
  # mv replaces a planted link name rather than following it.
  [[ -L "$repo_root/.claude" || -L "$bd" ]] && return 0
  local content=""
  [[ -n "$window"  ]] && content+="window=$window"$'\n'
  [[ -n "$tokens"  ]] && content+="tokens=$tokens"$'\n'
  [[ -n "$pct_raw" ]] && content+="pct=$pct_raw"$'\n'
  # Same model-id charset family the Stop hook enforces, plus space/parens for
  # display names ("Fable 4.5 (new)"). Consumers never interpolate this value.
  local model_charset_re='^[]A-Za-z0-9._ ()[-]+$'
  if [[ -n "$model" ]] && [[ "$model" =~ $model_charset_re ]]; then
    content+="model=$model"$'\n'
  fi
  [[ -z "$content" ]] && return 0
  local sl_file="$bd/.ctx_sl_${session_id}"
  # The statusline refreshes ~every 300ms; skip the write when nothing changed
  # so we don't churn a mktemp+mv (and the file's mtime, which ctx-check uses
  # as a freshness signal) three times a second.
  if [[ -f "$sl_file" && ! -L "$sl_file" ]]; then
    local existing
    existing="$(cat "$sl_file" 2>/dev/null || true)"
    # $(cat) strips the trailing newline; compare against content sans-newline.
    [[ "$existing" == "${content%$'\n'}" ]] && return 0
  fi
  mkdir -p "$bd" 2>/dev/null || return 0
  local tmp
  tmp="$(mktemp "${sl_file}.XXXXXX" 2>/dev/null)" || return 0
  printf '%s' "$content" > "$tmp"
  mv -f "$tmp" "$sl_file"
}
# `|| true`: display already succeeded; a cache failure must never surface as
# a nonzero exit (which would blank the status line on some CC versions).
write_cache || true

exit 0
