#!/usr/bin/env bash
# Coverage for the Stop-hook health warnings (issue #71): the Stop hook can
# die silently, and the first thing that used to notice was /handoff itself —
# the worst possible moment, since that's exactly when context is saturated.
#
# Detector A (handoff_ctx_check.sh, UserPromptSubmit, same session): a
# per-session prompt counter (.ctx_prompts_<sid>) that, once it crosses
# HANDOFF_HEALTH_PROMPTS fires with .ctx_<sid> still absent, warns once that
# the Stop hook appears dead.
#
# Detector B (handoff_session_start.sh, SessionStart, retrospective): if the
# most recent previous session represented in handoff_backups/ has no
# Stop-hook-written evidence (.ctx_tokens_/.ctx_model_/.ctx_/handoff_raw_),
# warns that the Stop hook didn't run last session. Catches the #67 shape
# (both per-turn hooks dead) that detector A can never see.
#
# Both: silent when healthy, once-per-session throttled, and disabled
# entirely by HANDOFF_NO_HEALTH_WARN=1.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CC="$REPO_ROOT/bin/handoff_ctx_check.sh"
SS="$REPO_ROOT/bin/handoff_session_start.sh"
command -v jq >/dev/null 2>&1 || { echo "handoff health warnings"; skip "jq missing — handoff_ctx_check.sh parses payload with jq"; finish; exit; }

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
exists() { [[ -e "$1" ]] && echo yes || echo no; }

# --- Detector A: handoff_ctx_check.sh ---------------------------------------
echo "handoff_ctx_check.sh — Stop-hook health detector A"

fire_a() {  # <repo> <sid> [ENV=VAL ...]
  local repo="$1" sid="$2"; shift 2
  ( cd "$repo" && env "$@" bash "$CC" <<<"{\"session_id\":\"$sid\"}" 2>/dev/null )
}

# F1 regression: handoff_backups/ does NOT pre-exist (the flagship scenario —
# Stop hook never ran, no statusLine wired, so nothing has ever created the
# dir). The counter write must create it, not silently fail to persist.
repo="$(mk_repo)"; cleanup_on_exit "$repo"
check "F1: handoff_backups/ absent before first fire" no "$(exists "$repo/.claude/handoff_backups")"
out=""
for _ in 1 2 3; do out="$(fire_a "$repo" NODIR)"; done
check "F1: warns at threshold with no pre-existing backups dir" yes "$(has "$out" "does not appear to be running")"
check "F1: prompt counter persisted across fires" yes "$(exists "$repo/.claude/handoff_backups/.ctx_prompts_NODIR")"
rm -rf "$repo"

# Below threshold (default 3): two fires with no .ctx_<sid> -> silent.
repo="$(mk_repo)"; cleanup_on_exit "$repo"; must mkdir -p "$repo/.claude/handoff_backups"
out1="$(fire_a "$repo" BELOW)"
out2="$(fire_a "$repo" BELOW)"
check "below threshold, fire 1 -> silent" no "$(has "$out1" "does not appear to be running")"
check "below threshold, fire 2 -> silent" no "$(has "$out2" "does not appear to be running")"
check "prompt counter incremented"        yes "$(exists "$repo/.claude/handoff_backups/.ctx_prompts_BELOW")"

# At threshold (3rd fire), .ctx_<sid> absent -> warns.
out3="$(fire_a "$repo" BELOW)"
check "at threshold, .ctx_ absent -> warns"       yes "$(has "$out3" "does not appear to be running")"
check "warning names likely causes (jq)"          yes "$(has "$out3" "jq not on PATH")"
check "warning points to doctor"                  yes "$(has "$out3" "--doctor")"
check "warn flag recorded"                        yes "$(exists "$repo/.claude/handoff_backups/.ctx_health_BELOW")"

# Once-per-session throttle: a 4th fire, still no .ctx_, stays silent.
out4="$(fire_a "$repo" BELOW)"
check "throttle: 4th fire -> silent" no "$(has "$out4" "does not appear to be running")"
rm -rf "$repo"

# No warn when .ctx_<sid> IS present, even past the prompt threshold.
repo="$(mk_repo)"; cleanup_on_exit "$repo"
bd="$repo/.claude/handoff_backups"; must mkdir -p "$bd"
must printf '4000' > "$bd/.ctx_HEALTHY"
out=""
for _ in 1 2 3 4; do out="$(fire_a "$repo" HEALTHY HANDOFF_CTX_WINDOW_TOKENS=1000000)"; done
check "healthy (.ctx_ present) -> never warns" no "$(has "$out" "does not appear to be running")"
rm -rf "$repo"

# HANDOFF_NO_HEALTH_WARN=1 silences detector A entirely, no sidecars written.
repo="$(mk_repo)"; cleanup_on_exit "$repo"; must mkdir -p "$repo/.claude/handoff_backups"
out=""
for _ in 1 2 3 4; do out="$(fire_a "$repo" OPTOUT HANDOFF_NO_HEALTH_WARN=1)"; done
check "opt-out -> silent even past threshold" no  "$(has "$out" "does not appear to be running")"
check "opt-out -> no prompt counter written"  no  "$(exists "$repo/.claude/handoff_backups/.ctx_prompts_OPTOUT")"
rm -rf "$repo"

# Threshold is tunable, but clamped to a minimum of 2 (F4): a healthy
# session's first prompt must never warn, so HANDOFF_HEALTH_PROMPTS=1 (and =0)
# behave as 2 — silent on fire 1, warns on fire 2.
repo="$(mk_repo)"; cleanup_on_exit "$repo"; must mkdir -p "$repo/.claude/handoff_backups"
out="$(fire_a "$repo" TUNED HANDOFF_HEALTH_PROMPTS=1)"
check "F4: threshold=1 clamped -> silent on 1st fire" no "$(has "$out" "does not appear to be running")"
out2="$(fire_a "$repo" TUNED HANDOFF_HEALTH_PROMPTS=1)"
check "F4: threshold=1 clamped -> warns on 2nd fire" yes "$(has "$out2" "does not appear to be running")"
rm -rf "$repo"

repo="$(mk_repo)"; cleanup_on_exit "$repo"; must mkdir -p "$repo/.claude/handoff_backups"
out="$(fire_a "$repo" TUNED0 HANDOFF_HEALTH_PROMPTS=0)"
check "F4: threshold=0 clamped -> silent on 1st fire" no "$(has "$out" "does not appear to be running")"
rm -rf "$repo"

# F2 regression: post-compaction false positive. handoff_compact_reset.sh
# deletes .ctx_<sid> on every PostCompact fire but KEEPS .ctx_model_<sid> and
# .ctx_prompts_<sid>. A healthy session that just auto-compacted therefore has
# its next prompt see a high carried-over prompt count with .ctx_<sid> absent
# — must stay silent because .ctx_model_<sid> (Stop-hook-written, survives
# compaction) proves the Stop hook has actually run this session.
repo="$(mk_repo)"; cleanup_on_exit "$repo"
bd="$repo/.claude/handoff_backups"; must mkdir -p "$bd"
must printf '5\n' > "$bd/.ctx_prompts_POSTCOMPACT"   # already past threshold, carried over
must printf 'claude-x' > "$bd/.ctx_model_POSTCOMPACT" # kept across compaction
out="$(fire_a "$repo" POSTCOMPACT)"
check "F2: post-compaction (.ctx_ absent, .ctx_model_ present) -> silent" no \
  "$(has "$out" "does not appear to be running")"
rm -rf "$repo"

# Detector A must not break the token-ledger nudge it coexists with: Stop hook
# dead (.ctx_ absent) but a fresh statusline cache is present -> the nudge
# still fires (issue #71's explicit coexistence requirement), and the health
# warning appears first if both fire in the same run. Pre-seed the prompt
# counter at (threshold - 1) so this single fire is BOTH the prompt that
# crosses the health threshold AND the token ledger's first (uncapped)
# crossing — looping fires here would let the default suggest-mode
# MAX_FLAGS=1 cap suppress the nudge on fire 2/3, which is a real behavior of
# the ledger, not a coexistence failure, and would make this assertion flaky
# for the wrong reason.
repo="$(mk_repo)"; cleanup_on_exit "$repo"
bd="$repo/.claude/handoff_backups"; must mkdir -p "$bd"
must printf 'window=1000\ntokens=600\n' > "$bd/.ctx_sl_LEDGER"
must printf '2\n' > "$bd/.ctx_prompts_LEDGER"
out="$(fire_a "$repo" LEDGER HANDOFF_CTX_WINDOW_TOKENS=1000)"
check "coexistence: health warning present"   yes "$(has "$out" "does not appear to be running")"
check "coexistence: token-ledger nudge present too" yes "$(has "$out" "<system-reminder>")"
health_pos=$(printf '%s' "$out" | grep -bo "does not appear to be running" | head -1 | cut -d: -f1)
nudge_pos=$(printf '%s' "$out" | grep -bo "<system-reminder>" | head -1 | cut -d: -f1)
check "coexistence: warning precedes the nudge" yes "$([[ "$health_pos" -lt "$nudge_pos" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- Detector B: handoff_session_start.sh -----------------------------------
echo "handoff_session_start.sh — Stop-hook health detector B (retrospective)"

fire_b() {  # <repo> <new-sid> [ENV=VAL ...]
  local repo="$1" sid="$2"; shift 2
  ( cd "$repo" && env CLAUDE_PROJECT_DIR="$repo" "$@" \
      bash "$SS" <<<"{\"session_id\":\"$sid\"}" 2>&1 )
}

# Dead previous session: only ctx_check/statusline sidecars (no Stop-hook
# evidence) for the most recent session -> warns.
repo="$(mktemp -d)"; cleanup_on_exit "$repo"
must mkdir -p "$repo/.claude/handoff_backups"
must printf '# handoff\n\nCurated. MARKER\n' > "$repo/.claude/handoff_current.md"
must touch "$repo/.claude/handoff_backups/.ctx_sl_DEADPREV"
out="$(fire_b "$repo" NEWSESSION)"
check "detector B: dead previous session -> warns" yes "$(has "$out" "does not appear to have run")"
check "detector B: names likely causes (jq)"        yes "$(has "$out" "jq not on PATH")"
check "detector B: points to doctor"                yes "$(has "$out" "--doctor")"
check "detector B: handoff still emitted"            yes "$(has "$out" "MARKER")"
check "detector B: throttle flag recorded"           yes "$(exists "$repo/.claude/handoff_backups/.ss_health_NEWSESSION")"

# Throttle: a second SessionStart fire in the SAME new session (e.g. /clear)
# stays silent.
out2="$(fire_b "$repo" NEWSESSION)"
check "detector B: throttled on repeat fire (same new session)" no "$(has "$out2" "does not appear to have run")"
rm -rf "$repo"

# Healthy previous session: Stop-hook evidence exists for the most recent
# session (even though a LATER-mtime ctx_check-only file also exists for it,
# proving the check follows the SESSION, not "whichever file is newest").
repo="$(mktemp -d)"; cleanup_on_exit "$repo"
bd="$repo/.claude/handoff_backups"; must mkdir -p "$bd"
must printf '# handoff\n\nCurated. MARKER\n' > "$repo/.claude/handoff_current.md"
must printf '4000' > "$bd/.ctx_OKPREV"
must printf '600'  > "$bd/.ctx_tokens_OKPREV"
must printf 'model' > "$bd/.ctx_model_OKPREV"
sleep 1
must touch "$bd/.ctx_sl_OKPREV"   # newest by mtime, but same session as the Stop evidence above
out="$(fire_b "$repo" NEWSESSION)"
check "detector B: healthy previous session -> silent" no "$(has "$out" "does not appear to have run")"
rm -rf "$repo"

# F3 regression: a statusLine render racing SessionStart writes a fresh
# .ctx_sl_<CURRENT session id> — newer by mtime than everything else in the
# directory. Complete Stop-hook evidence exists for the actual previous
# session (OLDPREV). Without excluding the current session's own candidate,
# the newest-mtime pick lands on the brand-new session (which naturally has
# no Stop-hook evidence yet) and false-positives on a healthy project.
repo="$(mktemp -d)"; cleanup_on_exit "$repo"
bd="$repo/.claude/handoff_backups"; must mkdir -p "$bd"
must printf '# handoff\n\nCurated. MARKER\n' > "$repo/.claude/handoff_current.md"
must printf '4000' > "$bd/.ctx_OLDPREV"
must printf '600'  > "$bd/.ctx_tokens_OLDPREV"
must printf 'model' > "$bd/.ctx_model_OLDPREV"
sleep 1
must touch "$bd/.ctx_sl_NEWSESSION"   # the racing statusline write for the NEW session
out="$(fire_b "$repo" NEWSESSION)"
check "F3: statusline race for current session -> silent" no "$(has "$out" "does not appear to have run")"
rm -rf "$repo"

# First session: no handoff_current.md at all -> silent (nothing expected).
repo="$(mktemp -d)"; cleanup_on_exit "$repo"
must mkdir -p "$repo/.claude"
out="$(fire_b "$repo" FIRSTEVER)"
check "detector B: first session -> silent" no "$(has "$out" "does not appear to have run")"
rm -rf "$repo"

# HANDOFF_NO_HEALTH_WARN=1 silences detector B too.
repo="$(mktemp -d)"; cleanup_on_exit "$repo"
must mkdir -p "$repo/.claude/handoff_backups"
must printf '# handoff\n\nCurated. MARKER\n' > "$repo/.claude/handoff_current.md"
must touch "$repo/.claude/handoff_backups/.ctx_sl_DEADPREV"
out="$(fire_b "$repo" NEWSESSION HANDOFF_NO_HEALTH_WARN=1)"
check "detector B: opt-out -> silent" no "$(has "$out" "does not appear to have run")"
rm -rf "$repo"

# jq-free property (session_start.sh is jq-free by contract): detector B's
# code must not add a jq INVOCATION. Static check on the source, not runtime
# (must hold even where jq IS installed). The file legitimately MENTIONS "jq"
# in prose (warning text, comments) and probes for it with `command -v jq`
# (present since before #71, to warn that OTHER hooks need it) — neither is an
# invocation. What must never appear is jq actually being run: piped into,
# called with flags, or command-substituted.
jq_invocations="$(grep -nE '(\| *jq\b|\bjq[[:space:]]+-|\$\(jq\b)' "$SS" | grep -vc 'command -v jq' || true)"
check "session_start.sh stays jq-free (no jq invocation added)" 0 "${jq_invocations:-0}"

finish
