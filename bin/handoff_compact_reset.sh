#!/usr/bin/env bash
# handoff_compact_reset.sh — PostCompact hook companion to the ctx sidecars.
#
# Compaction frees the context window, but the per-session sidecars under
# .claude/handoff_backups/ still describe the PRE-compact world: the next
# prompt would nudge off stale-high numbers, and (worse) the MAX_FLAGS=1
# ledger would forever suppress a legitimately-needed re-nudge in the freed
# window. Simplest correct behavior: treat post-compact as session-start
# fresh — delete the session's measurement + flag sidecars and let the next
# Stop fire repopulate real post-compact numbers.
#
# What is deleted, and why each one:
#   .ctx_<sid>             — byte size. LOAD-BEARING delete: ctx-check gates
#                            on this file ("nothing recorded yet" -> exit 0),
#                            so removing it guarantees NO nudge can fire in
#                            the gap between compaction and the next Stop
#                            fire — not even off a stale estimate.
#   .ctx_tokens_<sid>      — pre-compact usage; wrong by definition now.
#   .ctx_flagged_<sid>     — the byte-ledger nudge cap/cooldown; clearing it
#                            re-arms one nudge for the freed window (the
#                            point of this).
#   .ctx_flagged_tok_<sid> — the TOKEN ledger's nudge cap/cooldown (issue
#                            #69's fallback path, used when the Stop hook's
#                            byte sidecar above is absent). Same re-arm
#                            reasoning as .ctx_flagged_<sid>: without this
#                            clear, the default suggest-mode MAX_FLAGS=1 nudge
#                            on the token ledger fires exactly once per
#                            session ever, never again after a compaction.
#   .ctx_sl_<sid>          — statusline cache; also pre-compact (the
#                            statusline will overwrite it within a second
#                            anyway).
# KEPT: .ctx_model_<sid> — the model didn't change across compaction, and
# keeping it preserves window auto-detection until the next Stop fire. This
# KEEP is also load-bearing for Stop-hook health detector A
# (handoff_ctx_check.sh, issue #71): that detector warns only when BOTH
# .ctx_<sid> AND .ctx_model_<sid> are absent, specifically BECAUSE this script
# deletes .ctx_<sid> on every PostCompact fire while keeping .ctx_model_<sid>.
# A detector gated on .ctx_<sid> alone would false-positive on a perfectly
# healthy session immediately after an auto-compaction: the byte file is gone
# (deleted above), the carried-over prompt count from before the compaction
# may already be past threshold, and nothing would distinguish that from the
# Stop hook actually being dead. .ctx_model_<sid> surviving here is what makes
# it durable evidence the Stop hook has run this session at all.
# KEPT: .fences_<sid> and .fences_tok_<sid> — the rules re-injection cooldown
# (handoff_ctx_check.sh writes these, one per ledger). Deliberate, and stated
# here because this header's job is to account for EVERY sidecar and it
# previously omitted these entirely. Their state is a transcript-byte (or
# token) watermark, and the underlying progress keeps growing across
# compaction, so the delta comparison still advances correctly;
# handoff_session_start.sh also re-injects on source=compact, which would
# make a reset here a double injection.
# KEPT: .ctx_prompts_<sid> (issue #71, Stop-hook health detector A) — the
# per-session UserPromptSubmit fire count. Compaction does not reset which
# prompt number the session is on, so clearing it would let a session that
# already proved the Stop hook dead (crossed HANDOFF_HEALTH_PROMPTS) start
# re-counting from zero and silently re-arm a "maybe it's just early" state
# that was already disproven.
# KEPT: .ctx_health_<sid> — the once-per-session throttle for that same
# warning. Same reasoning: compaction is mid-session, not a new session: if
# the warning already fired, it must not fire again just because the
# transcript was compacted.
#
# Degradation: PostCompact only exists on CC >= 2.1.76 (older builds simply
# never fire this). jq missing -> exit 0; the sidecars then age out via the
# next Stop overwrite — degraded but harmless, since the flag file only ever
# OVER-suppresses (a stale nudge ledger nags less, never corrupts anything).
# Silent-exit-0 hook discipline throughout.

set -euo pipefail

# --- Read hook payload ---
payload="$(cat 2>/dev/null || true)"
[[ -z "$payload" ]] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

session_id="$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)"
[[ -z "$session_id" ]] && exit 0
# session_id is interpolated into the sidecar paths below; same charset guard
# (and reasoning) as the sibling hooks — a slash/newline/".." could otherwise
# make the rm targets escape backup_dir.
[[ "$session_id" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0

# Payload `cwd`: second-rung anchor for the shared root resolver below.
payload_cwd="$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null || true)"
[[ -n "$payload_cwd" && -d "$payload_cwd" ]] || payload_cwd=""

# --- Project scope: shared resolver (CLAUDE_PROJECT_DIR -> payload cwd ->
#     $PWD, then git -C toplevel of that anchor), matching the sibling hooks.
#     The old bare `git rev-parse` anchored on the hook process's cwd, so with
#     cwd != CLAUDE_PROJECT_DIR this hook reset sidecars in a .claude/ other
#     than the one the Stop hook wrote — the stale pre-compact ledger
#     survived. Lib absent -> inline the same precedence (standalone). ---
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
# Refuse symlinked parents before any rm, matching handoff_turn_append.sh and
# handoff_statusline.sh. Near-unreachable in practice (turn_append bails on the
# same components, so the sidecars this deletes never get created through a
# link) — but this was the one hook in the sweep with no guard at all, and a
# script whose only job is deleting files should not be the exception.
[[ -L "$repo_root/.claude" || -L "$backup_dir" ]] && exit 0
[[ -d "$backup_dir" ]] || exit 0

rm -f -- "$backup_dir/.ctx_${session_id}" \
         "$backup_dir/.ctx_tokens_${session_id}" \
         "$backup_dir/.ctx_flagged_${session_id}" \
         "$backup_dir/.ctx_flagged_tok_${session_id}" \
         "$backup_dir/.ctx_sl_${session_id}"

exit 0
