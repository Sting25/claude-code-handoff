#!/usr/bin/env bash
# The skills' script-resolution snippets (#171) actually run. Every ```bash
# block in the three SKILL.md files that sets `hb=` is extracted and run
# under /bin/bash with a scrubbed environment (env -i plus HOME, CLAUDE_HOME
# and PATH):
#   * scripts present: prints "handoff-bin: <dir>/bin", exits 0, and a
#     follow-up block runs its script;
#   * scripts absent: prints the MISSING line and never tries to run
#     "/write_handoff.sh" (measured before the fix: rc=127, "No such file
#     or directory");
#   * CLAUDE_HOME unset: falls back to $HOME/.claude/bin; CLAUDE_HOME set:
#     wins over $HOME/.claude.
# The /handoff run block (no `hb=` of its own, meant to share a Bash call
# with the resolution block) is checked both joined to it and alone.
# Stub scripts stand in for the real ones: this tests the snippets, not the
# scripts.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "skill snippets: hb resolution and empty-hb bail (#171)"

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# blocks <file>: each ```bash block's body, NUL-terminated.
blocks() {
  awk '
    /^[[:space:]]*```bash[[:space:]]*$/ { inb = 1; buf = ""; next }
    inb && /^[[:space:]]*```[[:space:]]*$/ { inb = 0; printf "%s%c", buf, 0; next }
    inb { buf = buf $0 "\n" }
  ' "$1"
}

T="$(mktemp -d)"; cleanup_on_exit "$T"
mk_bin() {  # <dir>: stub scripts
  must mkdir -p "$1"
  printf '#!/bin/bash\necho "stub-ran write_handoff $*"\n' > "$1/write_handoff.sh"
  printf '#!/bin/bash\necho "stub-ran recover_tail $*"\n' > "$1/handoff_recover_tail.sh"
}
PRESENT_H="$T/present_home"; PRESENT_CH="$T/present_ch"
must mkdir -p "$PRESENT_H"; mk_bin "$PRESENT_CH/bin"
ABSENT_H="$T/absent_home"; ABSENT_CH="$T/absent_ch"
must mkdir -p "$ABSENT_H" "$ABSENT_CH"
FALLBACK_H="$T/fallback_home"; mk_bin "$FALLBACK_H/.claude/bin"

# run_block <code> <HOME> [CLAUDE_HOME]: sets OUT (stdout+stderr) and RC.
run_block() {
  local code="$1" h="$2"
  code="${code//<previous_session_id>/sid-test}"
  if [[ $# -ge 3 ]]; then
    OUT="$(env -i HOME="$h" CLAUDE_HOME="$3" PATH=/usr/bin:/bin /bin/bash -c "$code" </dev/null 2>&1)"
  else
    OUT="$(env -i HOME="$h" PATH=/usr/bin:/bin /bin/bash -c "$code" </dev/null 2>&1)"
  fi
  RC=$?
}

# Literal "$hb" for pattern matching (double-quoted escape, not a single
# quoted string, so shellcheck does not read it as an unexpanded variable).
HB="\$hb"
total=0
resolve_block=""
for skill in handoff handoff-more handoff-recover; do
  f="$REPO_ROOT/skills/$skill/SKILL.md"
  n=0
  while IFS= read -r -d '' b; do
    case "$b" in *'hb='*) ;; *)
      # the /handoff run block: uses $hb without setting it
      case "$skill:$b" in handoff:*"\"$HB/write_handoff.sh\" --session-id"*) run_block_code="$b" ;; esac
      continue ;;
    esac
    n=$((n + 1)); total=$((total + 1))
    id="$skill block $n"
    [[ "$skill" == handoff && $n -eq 1 ]] && resolve_block="$b"

    run_block "$b" "$PRESENT_H" "$PRESENT_CH"
    check "$id: present -> exit 0" 0 "$RC"
    check "$id: present -> handoff-bin line" yes "$(has "$OUT" "handoff-bin: $PRESENT_CH/bin")"
    check "$id: present -> no MISSING" no "$(has "$OUT" "MISSING")"
    case "$b" in *"bash \"$HB/"*)
      check "$id: present -> script ran" yes "$(has "$OUT" "stub-ran")" ;;
    esac

    run_block "$b" "$ABSENT_H" "$ABSENT_CH"
    check "$id: absent -> MISSING line" yes "$(has "$OUT" "MISSING: handoff scripts not installed (no write_handoff.sh in $ABSENT_CH/bin)")"
    check "$id: absent -> no 'No such file'" no "$(has "$OUT" "No such file")"
    check "$id: absent -> no script run" no "$(has "$OUT" "stub-ran")"

    run_block "$b" "$FALLBACK_H"
    check "$id: CLAUDE_HOME unset -> \$HOME/.claude/bin" yes "$(has "$OUT" "handoff-bin: $FALLBACK_H/.claude/bin")"
  done < <(blocks "$f")
  check "$skill: has hb blocks" yes "$([[ $n -gt 0 ]] && echo yes || echo no)"
done
check "hb blocks found across the three skills" 6 "$total"

# /handoff step 1: resolution block + run block in one Bash call, and the
# run block alone (hb unset).
check "handoff run block found" yes "$([[ -n "${run_block_code:-}" ]] && echo yes || echo no)"
run_block "$resolve_block$run_block_code" "$PRESENT_H" "$PRESENT_CH"
check "handoff resolve+run: present -> exit 0" 0 "$RC"
check "handoff resolve+run: present -> script ran" yes "$(has "$OUT" "stub-ran write_handoff")"
run_block "$resolve_block$run_block_code" "$ABSENT_H" "$ABSENT_CH"
check "handoff resolve+run: absent -> MISSING" yes "$(has "$OUT" "MISSING")"
check "handoff resolve+run: absent -> no 'No such file'" no "$(has "$OUT" "No such file")"
run_block "${run_block_code:-}" "$PRESENT_H" "$PRESENT_CH"
check "handoff run block alone: hb unset -> MISSING" yes "$(has "$OUT" "MISSING: \$hb is empty")"
check "handoff run block alone: no 'No such file'" no "$(has "$OUT" "No such file")"

finish
