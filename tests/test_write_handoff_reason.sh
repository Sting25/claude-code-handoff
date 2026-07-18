#!/usr/bin/env bash
# Reason-aware safety net in write_handoff.sh: an --if-curated (SessionEnd /
# PreCompact hook) run reads an optional `reason` from the stdin JSON payload
# and SKIPS the write when it matches HANDOFF_SESSIONEND_SKIP_REASONS
# (default "resume" — a /resume session-switch is a pause, not an ending).
# The failure asymmetry is the design: an absent/renamed field, empty stdin,
# or missing jq must always DEGRADE TO WRITING (the guessed field name can
# only ever add the skip, never subtract the safety net).
#
# Observable: a MARKER in the seeded placeholder's snapshot region. A write
# regenerates the doc (MARKER gone); a skip leaves the file byte-identical.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
SENTINEL="<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->"
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# Seed an UNEDITED-placeholder handoff_current.md carrying MARKER_<name> in
# the snapshot region (so any real write drops it).
seed_placeholder() {  # <repo> <name>
  mkdir -p "$1/.claude"
  cat > "$1/.claude/handoff_current.md" <<EOF
# handoff
MARKER_$2

## Notes from this session

$SENTINEL

_auto placeholder prose_
EOF
}

# run_wh <repo> <payload|__NONE__> [args/env...] -> sets RC; wrote=yes|no via
# marker_gone. Trailing args go to env before bash.
outcome() {  # <repo> <name> -> write|skip
  if grep -qF "MARKER_$2" "$1/.claude/handoff_current.md" 2>/dev/null; then
    echo skip
  else
    echo write
  fi
}

echo "write_handoff.sh — reason-aware SessionEnd skip (D1)"

# --- reason=resume + placeholder + --if-curated -> SKIP ----------------------
repo="$(mk_repo)"; seed_placeholder "$repo" RES
out="$( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 \
    bash "$WH" --if-curated <<<'{"reason":"resume"}' 2>/dev/null )"; rc=$?
check "resume: exit 0"                    0     "$rc"
check "resume: skipped (marker kept)"     skip  "$(outcome "$repo" RES)"
check "resume: prints handoff path"       yes   "$(has "$out" ".claude/handoff_current.md")"
check "resume: no history rotation"       no    "$([[ -d "$repo/.claude/handoff_history" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- reason=clear (a genuine ending) -> WRITES -------------------------------
repo="$(mk_repo)"; seed_placeholder "$repo" CLR
( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 \
    bash "$WH" --if-curated <<<'{"reason":"clear"}' >/dev/null 2>&1 )
check "clear: writes (marker gone)"       write "$(outcome "$repo" CLR)"
rm -rf "$repo"

# --- DEGRADATION CONTROLS: every parse failure mode -> WRITES ----------------
# empty stdin (</dev/null): must return promptly AND write.
repo="$(mk_repo)"; seed_placeholder "$repo" EMPTY
( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 \
    bash "$WH" --if-curated </dev/null >/dev/null 2>&1 ); rc=$?
check "empty stdin: exit 0 (no hang)"     0     "$rc"
check "empty stdin: writes"               write "$(outcome "$repo" EMPTY)"
rm -rf "$repo"

# reason field absent / differently named.
repo="$(mk_repo)"; seed_placeholder "$repo" NOFIELD
( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 \
    bash "$WH" --if-curated <<<'{"session_id":"x","exit_reason":"resume"}' >/dev/null 2>&1 )
check "field absent/renamed: writes"      write "$(outcome "$repo" NOFIELD)"
rm -rf "$repo"

# jq absent: same payload that WOULD skip must write instead.
if command -v jq >/dev/null 2>&1; then
  nojq="$(mktemp -d)"
  for d in ${PATH//:/ }; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
      b="$(basename "$f")"
      [[ "$b" == "jq" ]] && continue
      [[ -e "$nojq/$b" ]] || ln -s "$f" "$nojq/$b" 2>/dev/null || true
    done
  done
  repo="$(mk_repo)"; seed_placeholder "$repo" NOJQ
  ( cd "$repo" && PATH="$nojq" HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 \
      bash "$WH" --if-curated <<<'{"reason":"resume"}' >/dev/null 2>&1 ); rc=$?
  check "jq absent: exit 0"               0     "$rc"
  check "jq absent: writes"               write "$(outcome "$repo" NOJQ)"
  rm -rf "$repo" "$nojq"
else
  skip "jq missing on host — jq-absent control is the ambient state"
fi

# --- Curated file + resume -> preserved (the curation guard's path) ----------
repo="$(mk_repo)"; mkdir -p "$repo/.claude"
cat > "$repo/.claude/handoff_current.md" <<'EOF'
# handoff

## Notes from this session

Real curated notes. MARKER_CUR lives here.
EOF
( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 \
    bash "$WH" --if-curated <<<'{"reason":"resume"}' >/dev/null 2>&1 )
check "curated + resume: preserved"       yes "$(has "$(cat "$repo/.claude/handoff_current.md")" "MARKER_CUR")"
rm -rf "$repo"

# --- HANDOFF_SESSIONEND_SKIP_REASONS overrides -------------------------------
# Explicit empty list -> resume writes (the pure opt-out).
repo="$(mk_repo)"; seed_placeholder "$repo" NOSKIP
( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 HANDOFF_SESSIONEND_SKIP_REASONS='' \
    bash "$WH" --if-curated <<<'{"reason":"resume"}' >/dev/null 2>&1 )
check "SKIP_REASONS='': resume writes"    write "$(outcome "$repo" NOSKIP)"
rm -rf "$repo"

# Custom list (comma-separated) skips clear; and resume — NOT in the custom
# list — now writes (the default is fully replaced, not merged).
repo="$(mk_repo)"; seed_placeholder "$repo" CUSTA
( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 HANDOFF_SESSIONEND_SKIP_REASONS="clear,logout" \
    bash "$WH" --if-curated <<<'{"reason":"clear"}' >/dev/null 2>&1 )
check "custom list: clear skipped"        skip  "$(outcome "$repo" CUSTA)"
rm -rf "$repo"
repo="$(mk_repo)"; seed_placeholder "$repo" CUSTB
( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 HANDOFF_SESSIONEND_SKIP_REASONS="clear,logout" \
    bash "$WH" --if-curated <<<'{"reason":"resume"}' >/dev/null 2>&1 )
check "custom list: resume now writes"    write "$(outcome "$repo" CUSTB)"
rm -rf "$repo"

# --- Skip list governs the SAFETY NET only: no --if-curated -> always write --
repo="$(mk_repo)"; seed_placeholder "$repo" MANUAL
( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 \
    bash "$WH" <<<'{"reason":"resume"}' >/dev/null 2>&1 )
check "no --if-curated + resume: writes"  write "$(outcome "$repo" MANUAL)"
rm -rf "$repo"

finish
