#!/usr/bin/env bash
# Security regression guard for symlink-following in the READ paths — the
# read-side companion of test_symlink_safety.sh (which covers the write paths).
#
# A malicious cloned repo can COMMIT .claude/handoff_current.md as a symlink to
# a victim file outside the repo (~/.ssh/id_rsa, ~/.claude/settings.json). The
# write side has refused planted symlinks since the paths#1/#4 fix, but every
# reader followed them:
#
#   handoff_session_start.sh — cats the doc verbatim into MODEL CONTEXT, so the
#     first SessionStart in the clone would load the victim's content.
#   handoff_ctx_check.sh — the rules re-injection reads the doc (the HMAC
#     computation cats it), so a symlink to a locally-signed file would verify
#     and re-inject content read through the link.
#   handoff_statusline.sh — the curated/auto/none sentinel grep reads the doc;
#     display-only, but a read is a read.
#
# Each test plants the symlink, runs the reader, and asserts the target's
# content never appears in the output, the hook stays exit-0, and the
# treat-as-absent fallback behavior still works.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SS="$REPO_ROOT/bin/handoff_session_start.sh"
CTX="$REPO_ROOT/bin/handoff_ctx_check.sh"
SL="$REPO_ROOT/bin/handoff_statusline.sh"
WH="$REPO_ROOT/bin/write_handoff.sh"

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

SECRET="SSH_KEY_MATERIAL_MUST_NOT_LOAD_77c1"

# ===========================================================================
echo "handoff_session_start.sh — symlink refusal on handoff_current.md"

run_ss() {  # <project_dir> [ENV=VAL ...]
  local dir="$1"; shift
  ( cd "$dir" && env CLAUDE_PROJECT_DIR="$dir" "$@" bash "$SS" </dev/null 2>/dev/null )
}

# --- Planted symlink -> refused: victim content NOT loaded, warning printed,
#     exit 0, and the hook proceeds exactly as if no handoff exists.
proj="$(mktemp -d)"; must mkdir -p "$proj/.claude"
victim="$(mktemp)"; printf '%s\n' "$SECRET" > "$victim"
must ln -s "$victim" "$proj/.claude/handoff_current.md"
out="$(run_ss "$proj")"; rc=$?
check "symlink: exit 0"                       0   "$rc"
check "symlink: victim content NOT in output" no  "$(has "$out" "$SECRET")"
check "symlink: visible warning names path"   yes "$(has "$out" "handoff_current.md is a symlink")"
check "symlink: no handoff header emitted"    no  "$(has "$out" "Auto-loaded handoff from previous session")"
rm -rf "$proj"; rm -f "$victim"

# --- Same, with prior handoff artifacts present: the treat-as-absent fallback
#     still works — the miss-visibility warning fires (as it would for a
#     genuinely absent doc) and history is never cat'd through the link.
proj="$(mktemp -d)"; must mkdir -p "$proj/.claude/handoff_history"
victim="$(mktemp)"; printf '%s\n' "$SECRET" > "$victim"
must ln -s "$victim" "$proj/.claude/handoff_current.md"
printf 'older curated prose. MARKER_HIST\n' > "$proj/.claude/handoff_history/handoff_2026-01-01_000000.md"
out="$(run_ss "$proj")"; rc=$?
check "symlink+history: exit 0"               0   "$rc"
check "symlink+history: victim NOT in output" no  "$(has "$out" "$SECRET")"
check "symlink+history: warning printed"      yes "$(has "$out" "refusing to read")"
check "symlink+history: absent-doc miss warning still fires" yes "$(has "$out" "no handoff to load")"
rm -rf "$proj"; rm -f "$victim"

# --- Sanity: a regular file still loads (guard has no false positive).
proj="$(mktemp -d)"; must mkdir -p "$proj/.claude"
printf '# handoff\n\n## Notes from this session\n\nreal prose MARKER_REG\n' \
  > "$proj/.claude/handoff_current.md"
out="$(run_ss "$proj")"
check "regular file: still loaded"            yes "$(has "$out" "MARKER_REG")"
check "regular file: no symlink warning"      no  "$(has "$out" "is a symlink")"
rm -rf "$proj"

# ===========================================================================
echo "handoff_ctx_check.sh — symlink refusal on the rules re-inject read"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — ctx_check exits before the re-injection path"
  finish; exit
fi
if ! command -v openssl >/dev/null 2>&1; then
  skip "openssl not installed — cannot build a signed handoff"
  finish; exit
fi

SID="readguard-test-session"
REINJECT_HDR="Re-injecting the standing rules"

# Fixture: a signed handoff whose BIND block carries PIN_MARKER, then the doc
# is MOVED outside the repo and a symlink planted in its place. The moved file
# still verifies (same content, same secret; the symlinked relpath is
# untracked) — so pre-guard, re-injection would happily read through the link.
proj="$(mk_repo)" || exit 1
must mkdir -p "$proj/.claude/handoff_backups"
printf -- '- Never force-push. PIN_MARKER\n' > "$proj/.claude/handoff_pinned.md"
must env HANDOFF_SECRET_FILE="$proj/.secret" bash -c "cd '$proj' && bash '$WH' >/dev/null 2>&1"

set_bytes() { printf '%s\n' "$1" > "$proj/.claude/handoff_backups/.ctx_${SID}"; }
must set_bytes 100000
printf '1000\n' > "$proj/.claude/handoff_backups/.ctx_tokens_${SID}"

run_ctx() {  # [ENV=VAL ...] -> stdout
  ( cd "$proj" && printf '{"session_id":"%s"}' "$SID" \
      | env CLAUDE_PROJECT_DIR="$proj" HANDOFF_SECRET_FILE="$proj/.secret" "$@" \
          bash "$CTX" 2>/dev/null )
}

run_ctx >/dev/null   # seed the fences flag (regular file still in place)
outside="$(mktemp -d)"
must mv "$proj/.claude/handoff_current.md" "$outside/stolen_handoff.md"
must ln -s "$outside/stolen_handoff.md" "$proj/.claude/handoff_current.md"
must set_bytes 400000   # +300KB > 200KB cooldown: re-injection would fire
out="$(run_ctx)"; rc=$?
check "ctx symlink: exit 0"                  0   "$rc"
check "ctx symlink: no re-injection"         no  "$(has "$out" "$REINJECT_HDR")"
check "ctx symlink: bind content NOT leaked" no  "$(has "$out" "PIN_MARKER")"
check "ctx symlink: visible warning"         yes "$(has "$out" "is a symlink")"

# --- The ctx nudge must survive the refusal (guard never crashes the hook) ---
printf '90000\n' > "$proj/.claude/handoff_backups/.ctx_tokens_${SID}"   # 45% of 200k
out="$(run_ctx HANDOFF_CTX_WINDOW_TOKENS=200000)"
check "ctx symlink: nudge still fires"       yes "$(has "$out" "/handoff window")"
rm -rf "$proj" "$outside"

# ===========================================================================
echo "handoff_statusline.sh — symlink refusal on the sentinel grep"

proj="$(mk_repo)"; must mkdir -p "$proj/.claude"
victim="$(mktemp)"; printf 'curated prose, no sentinel\n' > "$victim"
must ln -s "$victim" "$proj/.claude/handoff_current.md"
payload='{"session_id":"SLRG","context_window":{"context_window_size":200000,"used_percentage":10}}'
out="$( cd "$proj" && env CLAUDE_PROJECT_DIR="$proj" bash "$SL" <<<"$payload" 2>/dev/null )"; rc=$?
check "sl symlink: exit 0"                   0   "$rc"
check "sl symlink: state shows none"         yes "$(has "$out" "handoff: none")"
check "sl symlink: not read as curated"      no  "$(has "$out" "handoff: curated")"
rm -rf "$proj"; rm -f "$victim"

finish
