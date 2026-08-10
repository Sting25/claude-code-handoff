#!/usr/bin/env bash
# Coverage for the rules re-injection in handoff_ctx_check.sh (issue #42):
# past the SessionStart load, the handoff's provenance-verified rules block is
# periodically re-emitted (against attention decay / compaction loss) on the
# UserPromptSubmit hook, cooldown-gated by transcript growth via the
# .fences_<session_id> flag file. Negative controls: the FIRST sighting seeds
# the flag WITHOUT emitting (SessionStart just delivered the rules), growth
# below the cooldown stays silent, an unverified doc never re-injects, and
# HANDOFF_FENCES_REINJECT_KB=0 disables the feature. The pre-existing ctx
# nudge must keep working around all of it.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CTX="$REPO_ROOT/bin/handoff_ctx_check.sh"
WH="$REPO_ROOT/bin/write_handoff.sh"

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

echo "handoff_ctx_check.sh — provenance-gated rules re-injection (cooldown)"

# ctx_check needs jq for payload parsing; signing needs openssl.
if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — ctx_check exits before the re-injection path"
  finish
  exit
fi
if ! command -v openssl >/dev/null 2>&1; then
  skip "openssl not installed — cannot build a signed handoff"
  finish
  exit
fi

SID="fences-test-session"
REINJECT_HDR="Re-injecting the standing rules"

# Fixture: a repo with a signed handoff carrying a pinned rule, plus the
# Stop-hook measurement files ctx_check keys off. Tokens are kept far below
# the nudge threshold so re-injection is observable in isolation.
proj="$(mk_repo)" || exit 1
must mkdir -p "$proj/.claude/handoff_backups"
printf -- '- Never force-push. PIN_MARKER\n' > "$proj/.claude/handoff_pinned.md"
# </dev/null: write_handoff cats stdin when it's a non-tty (hook-payload
# read); without the redirect this hangs whenever run.sh's stdin is open
# but silent (observed under agent harnesses).
must env HANDOFF_SECRET_FILE="$proj/.secret" bash -c "cd '$proj' && bash '$WH' >/dev/null 2>&1 </dev/null"

set_bytes() { printf '%s\n' "$1" > "$proj/.claude/handoff_backups/.ctx_${SID}"; }
must set_bytes 100000
printf '1000\n' > "$proj/.claude/handoff_backups/.ctx_tokens_${SID}"

run_ctx() {  # [ENV=VAL ...] -> stdout
  ( cd "$proj" && printf '{"session_id":"%s"}' "$SID" \
      | env CLAUDE_PROJECT_DIR="$proj" HANDOFF_SECRET_FILE="$proj/.secret" "$@" \
          bash "$CTX" 2>/dev/null )
}

flag="$proj/.claude/handoff_backups/.fences_${SID}"

# --- First sighting: seed the flag, do NOT emit ------------------------------
out="$(run_ctx)"; rc=$?
check "first pass -> exit 0"            0      "$rc"
check "first pass -> no re-injection"   no     "$(has "$out" "$REINJECT_HDR")"
check "first pass -> flag seeded"       100000 "$(cat "$flag" 2>/dev/null)"

# --- Cooldown honored: same size, then sub-cooldown growth -> silent ---------
out="$(run_ctx)"
check "same size -> silent"             no     "$(has "$out" "$REINJECT_HDR")"
must set_bytes 150000   # +50KB < default 200KB cooldown
out="$(run_ctx)"
check "sub-cooldown growth -> silent"   no     "$(has "$out" "$REINJECT_HDR")"
check "sub-cooldown -> flag unchanged"  100000 "$(cat "$flag" 2>/dev/null)"

# --- Past the cooldown: re-inject and advance the flag -----------------------
must set_bytes 350000   # +250KB > 200KB
out="$(run_ctx)"
check "grown -> re-injection fires"     yes    "$(has "$out" "$REINJECT_HDR")"
check "grown -> rules content included" yes    "$(has "$out" PIN_MARKER)"
check "grown -> wrapped in reminder"    yes    "$(has "$out" "</system-reminder>")"
check "grown -> flag advanced"          350000 "$(cat "$flag" 2>/dev/null)"
out="$(run_ctx)"
check "immediately after -> silent again" no   "$(has "$out" "$REINJECT_HDR")"

# --- Custom cooldown honored -------------------------------------------------
must set_bytes 400000   # +50KB
out="$(run_ctx HANDOFF_FENCES_REINJECT_KB=40)"
check "custom 40KB cooldown -> fires"   yes    "$(has "$out" "$REINJECT_HDR")"

# --- Disabled: HANDOFF_FENCES_REINJECT_KB=0 ----------------------------------
must set_bytes 900000
out="$(run_ctx HANDOFF_FENCES_REINJECT_KB=0)"
check "disabled -> silent"              no     "$(has "$out" "$REINJECT_HDR")"

# --- Unverified doc: tamper -> stale MAC -> never re-inject ------------------
printf 'tamper\n' >> "$proj/.claude/handoff_current.md"
out="$(run_ctx)"; rc=$?
check "tampered -> exit 0"              0      "$rc"
check "tampered -> no re-injection"     no     "$(has "$out" "$REINJECT_HDR")"

# --- A read-only backup dir makes the flag write impossible (mktemp fails):
#     the hook must survive under set -e (rc=0) and leave no temp behind, so
#     the ctx nudge is never taken down by fence-state bookkeeping. Reading the
#     .ctx_ files still works (dir is r-x); only writes fail.
( cd "$proj" && env HANDOFF_SECRET_FILE="$proj/.secret" bash "$WH" --restamp >/dev/null 2>&1 )
rm -f "$flag"
must set_bytes 500000
bdir="$proj/.claude/handoff_backups"
chmod 500 "$bdir"
out="$(run_ctx)"; rc=$?
chmod 700 "$bdir"
check "unwritable dir -> hook exits 0"    0   "$rc"
check "failed flag write leaves no temp"  0   "$(find "$bdir" -name '.fences.??????' 2>/dev/null | grep -c . | tr -d ' ')"
check "flag not created when unwritable"  no  "$([ -e "$flag" ] && echo yes || echo no)"

# --- The ctx nudge still works alongside (and independently of) the fences ---
( cd "$proj" && env HANDOFF_SECRET_FILE="$proj/.secret" bash "$WH" --restamp >/dev/null 2>&1 )
# Re-seed the fence flag (the unwritable-dir test above removed it) at low token
# usage so the SINGLE-SHOT ctx nudge is NOT consumed by the seeding run — only
# the fence flag seeds. Then raise tokens past the threshold and bytes past the
# fence cooldown so both fire together on the assertion pass.
printf '1000\n' > "$proj/.claude/handoff_backups/.ctx_tokens_${SID}"    # 0.5%, no nudge
must set_bytes 1000000
run_ctx HANDOFF_CTX_WINDOW_TOKENS=200000 >/dev/null                     # seeds fence flag
printf '90000\n' > "$proj/.claude/handoff_backups/.ctx_tokens_${SID}"   # 45% of 200k
must set_bytes 1300000                                                  # +300KB > cooldown
out="$(run_ctx HANDOFF_CTX_WINDOW_TOKENS=200000)"
check "nudge + fences both fire"        yes    "$(has "$out" "/handoff window")"
check "fences fire in same pass"        yes    "$(has "$out" "$REINJECT_HDR")"

rm -rf "$proj"
finish
