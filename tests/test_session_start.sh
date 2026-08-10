#!/usr/bin/env bash
# Behavioral coverage for handoff_session_start.sh (the SessionStart hook).
# This script had no tests: it decides what the next session sees on startup —
# the current handoff, plus (only when the current one is an uncurated
# placeholder) a fallback to the newest history entry and a /handoff-recover
# action banner. Pure bash + grep, so no jq/perl gate is needed.
#
# Observable: stdout. We assert on which sections appear / are absent.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SS="$REPO_ROOT/bin/handoff_session_start.sh"
SENTINEL="<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->"
LEGACY="The /handoff skill should append decisions"

# Run the hook against a project dir, capture stdout. Extra args are env=val.
run_ss() {  # <project_dir> [ENV=VAL ...]
  # </dev/null: the hook reads its JSON payload from stdin now (compact
  # detection); inheriting the test runner's stdin would be nondeterministic.
  local dir="$1"; shift
  ( cd "$dir" && env CLAUDE_PROJECT_DIR="$dir" "$@" bash "$SS" </dev/null 2>/dev/null )
}

# has <haystack> <needle> -> yes|no
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

mk_project() {  # echoes a fresh project dir with a .claude/
  local d; d="$(mktemp -d)"; mkdir -p "$d/.claude"; printf '%s\n' "$d"
}

echo "handoff_session_start.sh — load + placeholder fallback + recover banner"

# --- No current handoff: silent, exit 0, no output --------------------------
proj="$(mk_project)"
out="$(run_ss "$proj")"; rc=$?
check "no current -> exit 0"      0   "$rc"
check "no current -> no output"   ""  "$out"
rm -rf "$proj"

# --- Curated current: cat it, NO fallback, NO recover banner ----------------
proj="$(mk_project)"
cat > "$proj/.claude/handoff_current.md" <<EOF
# handoff

## Notes from this session

Curated prose. MARKER_CUR lives here.
EOF
out="$(run_ss "$proj")"
check "curated -> header emitted"      yes "$(has "$out" "Auto-loaded handoff from previous session")"
check "curated -> content emitted"     yes "$(has "$out" "MARKER_CUR")"
check "curated -> no recover banner"   no  "$(has "$out" "ACTION: RUN /handoff-recover")"
check "curated -> no history fallback" no  "$(has "$out" "Also loaded")"
rm -rf "$proj"

# --- Placeholder current + history: cat current + newest history + banner ---
proj="$(mk_project)"
cat > "$proj/.claude/handoff_current.md" <<EOF
# handoff

## Notes from this session

$SENTINEL
EOF
mkdir -p "$proj/.claude/handoff_history"
printf 'older curated. MARKER_OLD1\n'  > "$proj/.claude/handoff_history/handoff_2026-01-01_000000.md"
printf 'newest curated. MARKER_OLD2\n' > "$proj/.claude/handoff_history/handoff_2026-02-02_000000.md"
out="$(run_ss "$proj")"
check "placeholder -> recover banner"        yes "$(has "$out" "ACTION: RUN /handoff-recover")"
check "placeholder -> history fallback hdr"  yes "$(has "$out" "Also loaded")"
check "placeholder -> NEWEST history catted" yes "$(has "$out" "MARKER_OLD2")"
check "placeholder -> older history skipped" no  "$(has "$out" "MARKER_OLD1")"
check "placeholder -> history pointer count" yes "$(has "$out" "2 older handoff(s)")"
rm -rf "$proj"

# --- Legacy placeholder marker triggers the same placeholder path -----------
proj="$(mk_project)"
cat > "$proj/.claude/handoff_current.md" <<EOF
# handoff

## Notes from this session

$LEGACY to this block.
EOF
out="$(run_ss "$proj")"
check "legacy marker -> recover banner" yes "$(has "$out" "ACTION: RUN /handoff-recover")"
rm -rf "$proj"

# --- DISABLE_FALLBACK: placeholder but no history cat -----------------------
proj="$(mk_project)"
cat > "$proj/.claude/handoff_current.md" <<EOF
# handoff

## Notes from this session

$SENTINEL
EOF
mkdir -p "$proj/.claude/handoff_history"
printf 'hist MARKER_OLD3\n' > "$proj/.claude/handoff_history/handoff_2026-02-02_000000.md"
out="$(run_ss "$proj" HANDOFF_SS_DISABLE_FALLBACK=1)"
check "DISABLE_FALLBACK -> no history cat"     no  "$(has "$out" "MARKER_OLD3")"
check "DISABLE_FALLBACK -> banner still fires" yes "$(has "$out" "ACTION: RUN /handoff-recover")"
rm -rf "$proj"

# --- DISABLE_RECOVER: placeholder but no action banner ----------------------
proj="$(mk_project)"
cat > "$proj/.claude/handoff_current.md" <<EOF
# handoff

## Notes from this session

$SENTINEL
EOF
out="$(run_ss "$proj" HANDOFF_SS_DISABLE_RECOVER=1)"
check "DISABLE_RECOVER -> no banner" no "$(has "$out" "ACTION: RUN /handoff-recover")"
rm -rf "$proj"

# --- Placeholder, NO history: banner uses the "no previous handoff" wording --
proj="$(mk_project)"
cat > "$proj/.claude/handoff_current.md" <<EOF
# handoff

## Notes from this session

$SENTINEL
EOF
out="$(run_ss "$proj")"
check "no-history -> banner present"      yes "$(has "$out" "ACTION: RUN /handoff-recover")"
check "no-history -> 'no previous' copy"  yes "$(has "$out" "no previous handoff")"
check "no-history -> no fallback header"  no  "$(has "$out" "Also loaded")"
rm -rf "$proj"

# --- pipefail + present-but-empty history dir: must not abort -----------------
# Regression guard for `set -euo pipefail`: when handoff_history/ exists but
# holds no handoff_*.md, the `ls ... | wc -l` pointer pipeline has `ls` fail on
# the non-matching glob. Under pipefail that makes the whole pipeline non-zero,
# which `set -e` would treat as fatal — aborting before the current handoff is
# even fully emitted. The `|| true` keeps it clean: current content still
# emitted, exit 0, and the "older handoff(s)" pointer is correctly absent.
proj="$(mk_project)"
cat > "$proj/.claude/handoff_current.md" <<EOF
# handoff

## Notes from this session

Curated prose. MARKER_EMPTYHIST lives here.
EOF
mkdir -p "$proj/.claude/handoff_history"   # exists, but no handoff_*.md inside
out="$(run_ss "$proj")"; rc=$?
check "empty history dir -> exit 0"          0   "$rc"
check "empty history dir -> content emitted" yes "$(has "$out" "MARKER_EMPTYHIST")"
check "empty history dir -> no pointer"      no  "$(has "$out" "older handoff(s)")"
rm -rf "$proj"

# --- DATA-3: dot-prefixed backup sidecars must NOT trigger the miss-        --
#     visibility warning (false positive on a legitimately fresh project) ---
# handoff_ctx_check.sh and handoff_statusline.sh drop bookkeeping sidecars
# (.ctx_<sid>, .ctx_sl_<sid>, ...) under handoff_backups/ starting on a
# project's FIRST session — .ctx_sl_<sid> in particular is written by the
# statusline renderer on every prompt, independent of any Stop-hook fire —
# well before any handoff_raw_*.md dump exists. A whole-directory
# `find -type f` treated those sidecars alone as "prior handoff artifacts" and
# fired the warning (and its /handoff-more /handoff-recover instruction) on a
# project that has never actually had a handoff written.
proj="$(mk_project)"
mkdir -p "$proj/.claude/handoff_backups"
: > "$proj/.claude/handoff_backups/.ctx_abc123"
: > "$proj/.claude/handoff_backups/.ctx_sl_abc123"
out="$(run_ss "$proj")"; rc=$?
check "sidecars only -> exit 0"       0  "$rc"
check "sidecars only -> no miss warn" no "$(has "$out" "prior handoff artifacts")"
rm -rf "$proj"

# --- DATA-3 (positive control): a real handoff_raw_*.md dump still counts ---
# Confirms the fix narrowed the probe rather than breaking it: a genuine dump
# file (what the Stop hook actually writes on its first real fire) must still
# trip the warning.
proj="$(mk_project)"
mkdir -p "$proj/.claude/handoff_backups"
: > "$proj/.claude/handoff_backups/handoff_raw_abc123.md"
out="$(run_ss "$proj")"; rc=$?
check "real dump -> exit 0"       0   "$rc"
check "real dump -> miss warning" yes "$(has "$out" "prior handoff artifacts")"
rm -rf "$proj"

finish
