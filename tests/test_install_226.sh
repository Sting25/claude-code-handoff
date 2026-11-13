#!/usr/bin/env bash
# Follow-ups from the #209/#210 reviews (#226 items 1, 2, 7):
#   1. settings.json linked to settings.local.json (or the reverse) is one
#      file: the project-scope uninstall strips it through the link and must
#      not then say the other name "still carries the handoff hooks" (the
#      note was computed before the strip). Two real wired files still get it.
#   2. a --local install whose settings.local.json is not valid JSON,
#      uninstalled without --local: its wiring is unknown, like a mode-000
#      file (WARN, ERROR, exit 1, nothing changed), not "settings.json does
#      not exist; nothing to strip" with exit 0. A valid unwired other file
#      still gives "nothing to strip".
#   7. a piped user-scope --uninstall (no clone, empty repo_root) removes the
#      links into the clone the install used, and still leaves a link of the
#      user's that points elsewhere.
# Every run sandboxes HOME and CLAUDE_HOME, so nothing touches ~/.claude.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh #226 follow-ups (symlinked project file, invalid other file, piped uninstall)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed; install.sh refuses to install without it"
  finish
  exit
fi

unset CLAUDE_CONFIG_DIR
SRC="$(mktemp -d)"; cleanup_on_exit "$SRC"; SRC="$(cd "$SRC" && pwd -P)"
must cp "$REPO_ROOT/install.sh" "$SRC/"
must cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$SRC/"

H=""; P=""
fresh_sandbox() {
  H="$(mktemp -d)"; P="$(mktemp -d)"
  cleanup_on_exit "$H" "$P"
  P="$(cd "$P" && pwd -P)"
  must mkdir -p "$H/.claude" "$P/.claude"
}
# Symlinks forced: the clone sits under the temp dir, which install.sh
# otherwise treats as volatile and copies from.
inst() {
  OUT="$(cd "$P" && HANDOFF_FORCE_SYMLINK=1 HOME="$H" CLAUDE_HOME="$H/.claude" \
    bash "$SRC/install.sh" "$@" 2>&1 </dev/null)"
  RC=$?
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
count() { printf '%s\n' "$1" | grep -c -- "$2" || true; }
nhooks() { jq '.hooks | length' "$1"; }
REG() { cat "$H/.claude/handoff_projects" 2>/dev/null; }

# 1a. settings.json -> settings.local.json, --local install, uninstall without --local.
fresh_sandbox
inst --scope project --project "$P" --local
must ln -s settings.local.json "$P/.claude/settings.json"
inst --uninstall --scope project --project "$P"
check "1a: uninstall exits 0"                      0   "$RC"
check "1a: the hooks were stripped through the link" 0 "$(nhooks "$P/.claude/settings.local.json")"
check "1a: no false 'still carries' note"          no  "$(has "$OUT" "still carries the handoff hooks")"

# 1b. the reverse: settings.local.json -> settings.json, uninstall with --local.
fresh_sandbox
inst --scope project --project "$P"
must ln -s settings.json "$P/.claude/settings.local.json"
inst --uninstall --scope project --project "$P" --local
check "1b: uninstall exits 0"                      0   "$RC"
check "1b: the hooks were stripped through the link" 0 "$(nhooks "$P/.claude/settings.json")"
check "1b: no false 'still carries' note"          no  "$(has "$OUT" "still carries the handoff hooks")"

# 1c. control: two separate wired files keep the note.
fresh_sandbox
inst --scope project --project "$P"
inst --scope project --project "$P" --local
inst --uninstall --scope project --project "$P"
check "1c: uninstall exits 0"                      0   "$RC"
check "1c: the note names the still-wired file"    yes "$(has "$OUT" "note: $P/.claude/settings.local.json still carries the handoff hooks")"
check "1c: that file really is still wired"        7   "$(nhooks "$P/.claude/settings.local.json")"

# 2a. --local install, settings.local.json made invalid, uninstall without --local.
fresh_sandbox
inst --scope project --project "$P" --local
printf '{bad' > "$P/.claude/settings.local.json"
REG_BEFORE="$(REG)"
inst --uninstall --scope project --project "$P"
check "2a: uninstall exits 1"                      1   "$RC"
check "2a: one WARN names the invalid file"        1   "$(count "$OUT" "WARN    $P/.claude/settings.local.json is not valid JSON;")"
check "2a: ERROR says its wiring is unknown"       yes "$(has "$OUT" "carries the handoff hooks is unknown")"
check "2a: not 'nothing to strip'"                 no  "$(has "$OUT" "nothing to strip")"
check "2a: registry left as it was"                "$REG_BEFORE" "$(REG)"
check "2a: the invalid file is untouched"          '{bad' "$(cat "$P/.claude/settings.local.json")"

# 2b. control: a valid, unwired other file is still "nothing to strip".
fresh_sandbox
echo '{}' > "$P/.claude/settings.local.json"
inst --uninstall --scope project --project "$P"
check "2b: uninstall exits 0"                      0   "$RC"
check "2b: nothing to strip"                       yes "$(has "$OUT" "settings.json does not exist; nothing to strip")"
check "2b: no WARN"                                no  "$(has "$OUT" "WARN")"


# 7. piped user-scope --uninstall (no clone: repo_root is empty).
piped_uninstall() {
  OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash -s -- --uninstall < "$SRC/install.sh" 2>&1)"
  RC=$?
}
nlinks() { find "$H/.claude/bin" "$H/.claude/skills" -type l 2>/dev/null | wc -l | tr -d ' '; }
# 7a. symlink install: every link into the clone goes.
fresh_sandbox
inst
check "7a: install made 13 links"                  13  "$(nlinks)"
piped_uninstall
check "7a: piped uninstall exits 0"                0   "$RC"
check "7a: names the clone it matched against"     yes "$(has "$OUT" "no clone was used; matching against $SRC,")"
check "7a: no link left"                           0   "$(nlinks)"
check "7a: nothing skipped as 'not ours'"          no  "$(has "$OUT" "not ours")"
check "7a: settings stripped"                      0   "$(nhooks "$H/.claude/settings.json")"
# 7b. a link of the user's that points elsewhere stays.
fresh_sandbox
inst
USERF="$(mktemp)"; cleanup_on_exit "$USERF"
must rm "$H/.claude/skills/handoff/README.md"
must ln -s "$USERF" "$H/.claude/skills/handoff/README.md"
piped_uninstall
check "7b: piped uninstall exits 0"                0   "$RC"
check "7b: the user's link is skipped"             yes "$(has "$OUT" "skip    $H/.claude/skills/handoff/README.md (not ours")"
check "7b: only the user's link is left"           1   "$(nlinks)"
# 7c. copy install: no link to match, said so; the copies stay.
fresh_sandbox
inst --copy
piped_uninstall
check "7c: piped uninstall exits 0"                0   "$RC"
check "7c: says copies cannot be matched"          yes "$(has "$OUT" "copies cannot be matched and are left in place")"
check "7c: copies left in place"                   yes "$([[ -f "$H/.claude/bin/write_handoff.sh" ]] && echo yes || echo no)"

finish
