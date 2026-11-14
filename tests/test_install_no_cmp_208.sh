#!/usr/bin/env bash
# Copy-mode installs without cmp on PATH (#208 item 3). link() and
# unlink_if_ours ran an unguarded `cmp -s`: with cmp missing it printed
# "command not found" once per file and read as "different", so a --copy
# re-install backed up every one of its own copies and --uninstall left all
# of them behind as "not ours", exit 0. Now:
#   A. no cmp: a re-install says "ok (copy)" and makes no backups;
#   B. no cmp: --uninstall removes the copies, and still keeps a copy the
#      user changed (the od comparison is exact, not "always equal");
#   C. neither cmp nor od: one WARN, every copy treated as not ours (backed
#      up on install, left on uninstall), never removed;
#   D. no cmp: the other cmp callers work too. A re-install drops its
#      redundant settings backup, and a project-scope uninstall reads the
#      project's backup key as its own (it used to WARN "keyed to another
#      project" and leave the settings file this installer created).
# Every run sandboxes HOME and CLAUDE_HOME.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh copy mode without cmp (#208)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed; install.sh refuses to install without it"
  finish
  exit
fi

unset CLAUDE_CONFIG_DIR
NOCMP="$(path_without cmp)"
NOCMPOD="$(path_without cmp)"
rm -f "$NOCMPOD/od"
cleanup_on_exit "$NOCMP" "$NOCMPOD"
check "cmp absent on the shim PATH" absent \
  "$(PATH="$NOCMP" command -v cmp >/dev/null 2>&1 && echo present || echo absent)"
check "od present on the first shim PATH" present \
  "$(PATH="$NOCMP" command -v od >/dev/null 2>&1 && echo present || echo absent)"
check "od absent on the second shim PATH" absent \
  "$(PATH="$NOCMPOD" command -v od >/dev/null 2>&1 && echo present || echo absent)"

H=""
fresh_home() { H="$(mktemp -d)"; cleanup_on_exit "$H"; mkdir -p "$H/.claude"; }
inst() {  # <PATH> <args...>
  local p="$1"; shift
  OUT="$(cd "$H" && PATH="$p" HOME="$H" CLAUDE_HOME="$H/.claude" \
    bash "$REPO_ROOT/install.sh" "$@" 2>&1 </dev/null)"
  RC=$?
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
count() { printf '%s\n' "$1" | grep -c -- "$2" || true; }
nbak() { find "$H/.claude" -name '*.bak.*' ! -name 'settings.json.bak.*' | wc -l | tr -d ' '; }
ncopies() { find "$H/.claude/bin" "$H/.claude/skills" -type f ! -name '*.bak.*' 2>/dev/null | wc -l | tr -d ' '; }

# A. re-install in copy mode without cmp.
fresh_home
inst "$NOCMP" --copy
check "A: first copy install exits 0"           0   "$RC"
inst "$NOCMP" --copy
check "A: re-install exits 0"                   0   "$RC"
check "A: no 'command not found'"               no  "$(has "$OUT" "command not found")"
check "A: every copy reported up to date"       13  "$(count "$OUT" '^  ok      .* (copy)$')"
check "A: no backups of our own copies"         0   "$(nbak)"

# B. uninstall without cmp removes our copies, keeps a changed one.
printf '\n# changed by the user\n' >> "$H/.claude/skills/handoff/README.md"
inst "$NOCMP" --uninstall
check "B: uninstall exits 0"                    0   "$RC"
check "B: no 'command not found'"               no  "$(has "$OUT" "command not found")"
check "B: twelve copies removed"                12  "$(count "$OUT" '^  remove  .* (copy)$')"
check "B: the changed copy is skipped"          yes "$(has "$OUT" "skip    $H/.claude/skills/handoff/README.md (not ours")"
check "B: only the changed copy is left"        1   "$(ncopies)"

# C. neither cmp nor od: one WARN, never removed.
fresh_home
inst "$NOCMP" --copy
inst "$NOCMPOD" --copy
check "C: re-install exits 0"                   0   "$RC"
check "C: no 'command not found'"               no  "$(has "$OUT" "command not found")"
check "C: one WARN"                             1   "$(count "$OUT" 'neither cmp nor od is on PATH')"
check "C: each copy backed up, not clobbered"   13  "$(nbak)"
inst "$NOCMPOD" --uninstall
check "C: uninstall exits 0"                    0   "$RC"
check "C: one WARN on uninstall"                1   "$(count "$OUT" 'neither cmp nor od is on PATH')"
check "C: no copy removed"                      13  "$(ncopies)"


# D. the settings-backup and project-key comparisons without cmp.
fresh_home
inst "$NOCMP"
inst "$NOCMP"
check "D: re-install drops the redundant backup" yes "$(has "$OUT" "no settings.json changes (backup removed)")"
check "D: no settings backup left"         0   "$(find "$H/.claude" -name 'settings.json.bak.*' | wc -l | tr -d ' ')"
PR="$(mktemp -d)"; cleanup_on_exit "$PR"; PR="$(cd "$PR" && pwd -P)"
inst "$NOCMP" --scope project --project "$PR"
check "D: project install exits 0"         0   "$RC"
inst "$NOCMP" --uninstall --scope project --project "$PR"
check "D: project uninstall exits 0"       0   "$RC"
check "D: no 'command not found'"          no  "$(has "$OUT" "command not found")"
check "D: key not read as another project's" no "$(has "$OUT" "keyed to another project")"
check "D: created settings file removed"   no  "$([[ -e "$PR/.claude/settings.json" ]] && echo yes || echo no)"

finish
