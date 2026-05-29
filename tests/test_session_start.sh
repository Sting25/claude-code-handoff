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
  local dir="$1"; shift
  ( cd "$dir" && env CLAUDE_PROJECT_DIR="$dir" "$@" bash "$SS" 2>/dev/null )
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

finish
