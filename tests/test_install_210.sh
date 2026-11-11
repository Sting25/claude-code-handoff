#!/usr/bin/env bash
# Installer defects from #210:
#   A. a project path with a control character is refused (exit 2) before
#      anything is copied. Every `$(...)` that resolves the path strips a
#      trailing newline, so `my proj<LF>` used to resolve to a SIBLING `my
#      proj`: the sibling was wired and registered, or, with no sibling, the
#      install copied every script and then died on a raw mkdir error. The
#      refusal covers each way the path arrives: --project, --project=, the
#      current directory, the git toplevel, a symlink to such a directory,
#      and a project-scope --uninstall of a gone path (which used to clear
#      the SIBLING's registry line). A non-ASCII name still installs.
#   B. a dangling <project>/.claude link is refused before anything is
#      copied into CLAUDE_HOME (already true on main when #210 was fixed;
#      pinned here because the issue reported a copy-then-die)
#   C. `bash -s -- --uninstall < install.sh` (no clone) closes with a line
#      that names no empty repo path, also for a gone project
#   D. (review of the first fix) a project-scope --uninstall that reaches a
#      control character through a symlink is refused too: a dangling link
#      (absolute or relative) to `my proj<LF>`, a dangling link to a gone
#      child of `x<LF>`, a live link to `my proj<LF>`, and a gone child under
#      a link to an existing `my proj<LF>`. Each used to exit 0 or clear a
#      sibling's registry line. Also: --doctor refuses, DEL (0x7f) is a
#      control character, and under a UTF-8 locale a name with U+0085 or
#      U+009F (not ASCII controls) still installs.
# Every run sandboxes HOME and CLAUDE_HOME, so nothing touches ~/.claude.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh control-character paths, dangling .claude, piped uninstall (#210)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed; install.sh refuses to install without it"
  finish
  exit
fi

unset CLAUDE_CONFIG_DIR

SRC="$(mktemp -d)"
cleanup_on_exit "$SRC"
must cp "$REPO_ROOT/install.sh" "$SRC/"
must cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$SRC/"

NL=$'\n'
H=""; P=""
fresh_sandbox() {
  H="$(mktemp -d)"; P="$(mktemp -d)"
  cleanup_on_exit "$H" "$P"
  P="$(cd "$P" && pwd -P)"
  must mkdir -p "$H/.claude"
}
# inst <cwd> <args...>
inst() {
  local cwd="$1"; shift
  OUT="$(cd "$cwd" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" "$@" 2>&1 </dev/null)"
  RC=$?
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
exists() { [[ -e "$1" ]] && echo yes || echo no; }
ncopied() { find "$H/.claude" -mindepth 1 | wc -l | tr -d ' '; }
CTRL_ERR="contains a control character (newline, tab, ...); refusing."

# --- A. control characters in the project path -------------------------------------------------
# A1: --project 'my proj<LF>' next to an existing sibling 'my proj'.
fresh_sandbox
must mkdir "$P/my proj$NL" "$P/my proj"
inst "$P" --project "$P/my proj$NL"
check "A1: refused (exit 2)" 2 "$RC"
check "A1: ERROR names the control character" yes "$(has "$OUT" "ERROR: project directory $(printf '%q' "$P/my proj$NL") $CTRL_ERR")"
check "A1: the sibling is not wired" no "$(exists "$P/my proj/.claude")"
check "A1: the real directory is not wired" no "$(exists "$P/my proj$NL/.claude")"
check "A1: nothing copied into the jailed home" 0 "$(ncopied)"

# A2: --project=<path> form, no sibling (used to copy every script, then die on a raw mkdir).
fresh_sandbox
must mkdir "$P/my proj$NL"
inst "$P" "--project=$P/my proj$NL"
check "A2: --project= refused (exit 2)" 2 "$RC"
check "A2: ERROR line" yes "$(has "$OUT" "$CTRL_ERR")"
check "A2: no raw mkdir error" no "$(has "$OUT" "mkdir:")"
check "A2: nothing copied into the jailed home" 0 "$(ncopied)"

# A3: a tab in the middle of the name.
fresh_sandbox
TABP="$P/my"$'\t'"proj"; must mkdir -p "$TABP"
inst "$P" --project "$TABP"
check "A3: tab refused (exit 2)" 2 "$RC"
check "A3: nothing copied" 0 "$(ncopied)"
check "A3: not wired" no "$(exists "$TABP/.claude")"

# A4: no --project, the current directory (not a git repo) ends in a newline.
fresh_sandbox
must mkdir "$P/my proj$NL" "$P/my proj"
inst "$P/my proj$NL" --scope project
check "A4: cwd with a newline refused (exit 2)" 2 "$RC"
check "A4: ERROR line" yes "$(has "$OUT" "$CTRL_ERR")"
check "A4: the sibling is not wired" no "$(exists "$P/my proj/.claude")"
check "A4: nothing copied" 0 "$(ncopied)"

# A5: no --project, run from a subdirectory of a git repo whose toplevel ends in a newline.
if command -v git >/dev/null 2>&1; then
  fresh_sandbox
  must mkdir -p "$P/my proj$NL/sub" "$P/my proj"
  must git -C "$P/my proj$NL" init -q
  inst "$P/my proj$NL/sub" --scope project
  check "A5: git toplevel with a newline refused (exit 2)" 2 "$RC"
  check "A5: ERROR line" yes "$(has "$OUT" "$CTRL_ERR")"
  check "A5: the sibling is not wired" no "$(exists "$P/my proj/.claude")"
  check "A5: nothing copied" 0 "$(ncopied)"
else
  skip "A5: git not installed"
fi

# A6: a clean --project that is a symlink to a directory whose name ends in a newline.
fresh_sandbox
must mkdir "$P/my proj$NL" "$P/my proj"
must ln -s "$P/my proj$NL" "$P/link"
inst "$P" --project "$P/link"
check "A6: symlink to a newline path refused (exit 2)" 2 "$RC"
check "A6: ERROR names the resolved path" yes "$(has "$OUT" "ERROR: project directory (resolved) $(printf '%q' "$P/my proj$NL") $CTRL_ERR")"
check "A6: the sibling is not wired" no "$(exists "$P/my proj/.claude")"
check "A6: nothing copied" 0 "$(ncopied)"

# A7: a project-scope --uninstall of a gone 'my proj<LF>' must not clear the
# registry line of the installed sibling 'my proj'.
fresh_sandbox
must mkdir "$P/my proj"
inst "$P" --project "$P/my proj"
check "A7: the sibling installs (exit 0)" 0 "$RC"
REG_BEFORE="$(cat "$H/.claude/handoff_projects" 2>/dev/null)"
check "A7: the sibling is registered" yes "$(has "$REG_BEFORE" "$P/my proj")"
inst "$P" --uninstall --project "$P/my proj$NL"
check "A7: gone newline path refused (exit 2)" 2 "$RC"
check "A7: ERROR line" yes "$(has "$OUT" "$CTRL_ERR")"
check "A7: the sibling's registry line is kept" "$REG_BEFORE" "$(cat "$H/.claude/handoff_projects" 2>/dev/null)"
check "A7: the sibling's wiring is kept" yes "$(exists "$P/my proj/.claude/settings.json")"

# A8: a non-ASCII name is not a control character and still installs.
fresh_sandbox
must mkdir "$P/café proj"
inst "$P" --project "$P/café proj"
check "A8: non-ASCII name installs (exit 0)" 0 "$RC"
check "A8: wired" yes "$(exists "$P/café proj/.claude/settings.json")"

# --- B. dangling <project>/.claude: refused before anything is copied ---------------------------
fresh_sandbox
NOWHERE="$(mktemp -d)"; cleanup_on_exit "$NOWHERE"; must rmdir "$NOWHERE"
must ln -s "$NOWHERE" "$P/.claude"
inst "$P" --project "$P"
check "B: dangling .claude refused (exit 2)" 2 "$RC"
check "B: ERROR names the link" yes "$(has "$OUT" "ERROR: $P/.claude is a dangling symlink (-> $NOWHERE)")"
check "B: nothing copied into the jailed home" 0 "$(ncopied)"
check "B: link target not created" no "$(exists "$NOWHERE")"

# --- C. piped --uninstall names no empty repo path ------------------------------------------------
fresh_sandbox
OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash -s -- --uninstall < "$SRC/install.sh" 2>&1)"
RC=$?
check "C1: piped user-scope uninstall exits 0" 0 "$RC"
check "C1: no empty repo path" no "$(has "$OUT" "the repo at  is")"
check "C1: says no clone was used" yes "$(has "$OUT" "done. no clone was used (install.sh was read from a pipe).")"
fresh_sandbox
OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash -s -- --uninstall --project "$P" < "$SRC/install.sh" 2>&1)"
RC=$?
check "C2: piped project-scope uninstall exits 0" 0 "$RC"
check "C2: no empty repo path" no "$(has "$OUT" "the repo at  is")"
check "C2: says no clone was used" yes "$(has "$OUT" "done. no clone was used (install.sh was read from a pipe).")"
# A clone run still names its repo.
inst "$P" --uninstall
check "C3: clone uninstall still names the repo" yes "$(has "$OUT" "done. the repo at $SRC is untouched.")"
# C4: a piped project-scope uninstall of a GONE project (the early-exit branch).
fresh_sandbox
OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash -s -- --uninstall --project "$P/gone" < "$SRC/install.sh" 2>&1)"
RC=$?
check "C4: piped gone-project uninstall exits 0" 0 "$RC"
check "C4: no empty repo path" no "$(has "$OUT" "the repo at  is")"
check "C4: says no clone was used" yes "$(has "$OUT" "done. no clone was used (install.sh was read from a pipe).")"

# --- D. control characters reached through a symlink on --uninstall, and the class itself -------
REG=""
# Two installed projects, 'my proj' and 'other'; REG is the registry before the case runs.
setup_two() {
  fresh_sandbox
  must mkdir "$P/my proj" "$P/other"
  inst "$P" --project "$P/my proj"
  inst "$P" --project "$P/other"
  REG="$(cat "$H/.claude/handoff_projects" 2>/dev/null)"
}
reg_now() { cat "$H/.claude/handoff_projects" 2>/dev/null; }
wired() { [[ -f "$1/.claude/settings.json" ]] && grep -q handoff "$1/.claude/settings.json" && echo yes || echo no; }
# d_case <label>: asserts the refusal left both projects as they were.
d_case() {
  check "$1: refused (exit 2)" 2 "$RC"
  check "$1: ERROR line" yes "$(has "$OUT" "$CTRL_ERR")"
  check "$1: registry unchanged" "$REG" "$(reg_now)"
  check "$1: 'my proj' still wired" yes "$(wired "$P/my proj")"
}
setup_two
check "D0: both projects registered" 2 "$(printf '%s\n' "$REG" | grep -c .)"
# D1: dangling absolute link to 'my proj<LF>' (the target does not exist).
must ln -s "$P/my proj$NL" "$P/dl"
inst "$P" --uninstall --project "$P/dl"
d_case "D1 (dangling link -> 'my proj<LF>')"
# D2: the same with a relative link target.
setup_two
must ln -s "my proj$NL" "$P/dl"
inst "$P" --uninstall --project "$P/dl"
d_case "D2 (dangling relative link -> 'my proj<LF>')"
# D3: a registered project 'x/wt' that is gone, and a dangling link to 'x<LF>/wt'.
fresh_sandbox
must mkdir -p "$P/x/wt"
inst "$P" --project "$P/x/wt"
must rm -r "$P/x/wt"
REG="$(reg_now)"
check "D3: gone child registered" yes "$(has "$REG" "$P/x/wt")"
must ln -s "$P/x$NL/wt" "$P/dl"
inst "$P" --uninstall --project "$P/dl"
check "D3 (dangling link -> 'x<LF>/wt'): refused (exit 2)" 2 "$RC"
check "D3: ERROR line" yes "$(has "$OUT" "$CTRL_ERR")"
check "D3: registry unchanged" "$REG" "$(reg_now)"
# D4: a live link to an existing 'my proj<LF>', on --uninstall.
setup_two
must mkdir "$P/my proj$NL"
must ln -s "$P/my proj$NL" "$P/l"
inst "$P" --uninstall --project "$P/l"
d_case "D4 (uninstall through a live link -> 'my proj<LF>')"
# D5: a gone child under a live link to an existing 'my proj<LF>'.
setup_two
must mkdir "$P/my proj$NL"
must ln -s "$P/my proj$NL" "$P/l"
inst "$P" --uninstall --project "$P/l/gone"
d_case "D5 (gone child under a link -> 'my proj<LF>')"
# D6: --doctor refuses the same path.
fresh_sandbox
must mkdir "$P/my proj$NL"
inst "$P" --doctor --project "$P/my proj$NL"
check "D6: --doctor refused (exit 2)" 2 "$RC"
check "D6: ERROR line" yes "$(has "$OUT" "$CTRL_ERR")"
# D7: DEL (0x7f) is a control character.
fresh_sandbox
DELP="$P/my"$'\x7f'"proj"; must mkdir "$DELP"
inst "$P" --project "$DELP"
check "D7: DEL refused (exit 2)" 2 "$RC"
check "D7: ERROR line" yes "$(has "$OUT" "$CTRL_ERR")"
check "D7: not wired" no "$(exists "$DELP/.claude")"
# D8: under a UTF-8 locale, bash classes U+0085 and U+009F as cntrl; they are
# not ASCII controls, so names holding them still install.
UTF8_LC=""
for _lc in en_US.UTF-8 en_US.utf8 C.UTF-8 C.utf8; do
  if LC_ALL="$_lc" bash -c '[[ $'"'"'\xc2\x85'"'"' == *[[:cntrl:]]* ]]' 2>/dev/null; then UTF8_LC="$_lc"; break; fi
done
if [[ -n "$UTF8_LC" ]]; then
  for _cp in 85 9F; do
    fresh_sandbox
    C1P="$P/my"$(printf "\\xc2\\x$_cp")"proj"; must mkdir "$C1P"
    OUT="$(cd "$P" && LC_ALL="$UTF8_LC" HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --project "$C1P" 2>&1 </dev/null)"
    RC=$?
    check "D8 (U+00$_cp under $UTF8_LC): installs (exit 0)" 0 "$RC"
    check "D8 (U+00$_cp): wired" yes "$(wired "$C1P")"
  done
else
  skip "D8: no UTF-8 locale that classes U+0085 as cntrl"
fi

finish
