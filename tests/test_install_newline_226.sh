#!/usr/bin/env bash
# Trailing newlines the installer still stripped after #210 (#226 items 5, 6).
# Each `$(cd ... && pwd)`, `$(readlink ...)` or `$(resolve_symlink ...)`
# drops trailing newlines, so a path or link target `x<LF>` read as the
# sibling `x`:
#   A. a clone at `c<LF>` next to a clone `c`: the install linked `c`'s
#      scripts; a project inside `c` was refused as "inside the clone";
#   B. link(): a user's link to `<clone>/bin/write_handoff.sh<LF>` read as
#      already ours ("ok") and was left in place;
#   C. unlink_if_ours: the same link was removed on --uninstall;
#   D. a settings.json linked to `real.json<LF>`: the install created and
#      patched `real.json` instead;
#   E. the doctor's wiring report read settings.json -> `a<LF>` and
#      settings.local.json -> `a` as one file and missed the duplicate;
#   F. messages showed a stripped link target; they now show it in $'...'
#      form (the doctor's link report, a dangling .claude link) and a
#      settings link into a missing `d<LF>` is refused, not patched into `d`.
# Every run sandboxes HOME and CLAUDE_HOME, so nothing touches ~/.claude.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh trailing newlines in clone paths and link targets (#226)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed; install.sh refuses to install without it"
  finish
  exit
fi

unset CLAUDE_CONFIG_DIR
NL=$'\n'
T="$(mktemp -d)"; cleanup_on_exit "$T"; T="$(cd "$T" && pwd -P)"
mkclone() { must mkdir -p "$1"; must cp "$REPO_ROOT/install.sh" "$1/"; must cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$1/"; }
SRC="$T/src"; mkclone "$SRC"

H=""; P=""
fresh_sandbox() {
  H="$(mktemp -d)"; P="$(mktemp -d)"
  cleanup_on_exit "$H" "$P"
  P="$(cd "$P" && pwd -P)"
  must mkdir -p "$H/.claude"
}
# Symlinks forced: the clones sit under the temp dir, which install.sh
# otherwise treats as volatile and copies from.
inst() {  # <install.sh> <args...>
  local s="$1"; shift
  OUT="$(cd "$P" && HANDOFF_FORCE_SYMLINK=1 HOME="$H" CLAUDE_HOME="$H/.claude" bash "$s" "$@" 2>&1 </dev/null)"
  RC=$?
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
# Compare paths in %q form: a bare `$(...)` of a path would strip the very
# newline under test, on both sides of the comparison. rlq prints a link's
# target already quoted, for the same reason.
q() { printf '%q' "$1"; }
rlq() { local t; t="$(readlink -n "$1"; printf x)"; printf '%q' "${t%x}"; }
yn() { if "$@"; then echo yes; else echo no; fi; }

# A. clone path with a trailing newline, next to a sibling clone without it.
CNL="$T/c$NL"; CSIB="$T/c"
mkclone "$CNL"; mkclone "$CSIB"
fresh_sandbox
inst "$CNL/install.sh"
check "A1: install from c<LF> exits 0" 0 "$RC"
check "A1: link points into c<LF>, not the sibling" "$(q "$CNL/bin/write_handoff.sh")" "$(rlq "$H/.claude/bin/write_handoff.sh")"
fresh_sandbox
must mkdir -p "$CSIB/proj"
inst "$CNL/install.sh" --scope project --project "$CSIB/proj"
check "A2: project in sibling c is not 'inside the clone'" no "$(has "$OUT" "is the handoff clone")"
check "A2: project install exits 0" 0 "$RC"

# B. link(): an existing link to <clone>/bin/write_handoff.sh<LF> is not ours.
fresh_sandbox
printf 'echo user\n' > "$SRC/bin/write_handoff.sh$NL"
must mkdir -p "$H/.claude/bin"
must ln -s "$SRC/bin/write_handoff.sh$NL" "$H/.claude/bin/write_handoff.sh"
inst "$SRC/install.sh"
check "B: exits 0" 0 "$RC"
check "B: relinked, not 'ok'" yes "$(has "$OUT" "relink  $H/.claude/bin/write_handoff.sh (was -> $(q "$SRC/bin/write_handoff.sh$NL")")"
check "B: now points at the clone's script" "$(q "$SRC/bin/write_handoff.sh")" "$(rlq "$H/.claude/bin/write_handoff.sh")"

# C. unlink_if_ours: the user's <LF> link survives --uninstall.
must rm "$H/.claude/bin/write_handoff.sh"
must ln -s "$SRC/bin/write_handoff.sh$NL" "$H/.claude/bin/write_handoff.sh"
inst "$SRC/install.sh" --uninstall
check "C: uninstall exits 0" 0 "$RC"
check "C: the <LF> link is skipped" yes "$(has "$OUT" "skip    $H/.claude/bin/write_handoff.sh (not ours")"
check "C: the <LF> link is still there" yes "$(yn test -L "$H/.claude/bin/write_handoff.sh")"
must rm -f "$SRC/bin/write_handoff.sh$NL"

# D. settings.json -> real.json<LF>: the target is patched, no sibling made.
fresh_sandbox
D="$(mktemp -d)"; cleanup_on_exit "$D"; D="$(cd "$D" && pwd -P)"
echo '{}' > "$D/real.json$NL"
must ln -s "$D/real.json$NL" "$H/.claude/settings.json"
inst "$SRC/install.sh"
check "D: install exits 0" 0 "$RC"
check "D: the <LF> target carries the hooks" 7 "$(jq '.hooks | length' "$D/real.json$NL")"
check "D: no sibling real.json created" no "$(yn test -e "$D/real.json")"
check "D: the note shows the <LF> target" yes "$(has "$OUT" "is a symlink -> $(q "$D/real.json$NL"); patching")"
check "D: the link itself is intact" yes "$(yn test -L "$H/.claude/settings.json")"

# E. doctor: settings.json -> a<LF> and settings.local.json -> a are two files.
fresh_sandbox
inst "$SRC/install.sh" --scope project --project "$P"
must mv "$P/.claude/settings.json" "$P/.claude/a$NL"
must cp "$P/.claude/a$NL" "$P/.claude/a"
must ln -s "a$NL" "$P/.claude/settings.json"
must ln -s a "$P/.claude/settings.local.json"
inst "$SRC/install.sh" --doctor --scope project --project "$P"
check "E: doctor sees both project files wired" yes "$(has "$OUT" "Both project files carry the hooks")"

# F1. the doctor's link report shows a <LF> target visibly.
fresh_sandbox
inst "$SRC/install.sh"
printf '# user\n' > "$SRC/bin/handoff_provenance.sh$NL"
must rm "$H/.claude/bin/handoff_provenance.sh"
must ln -s "$SRC/bin/handoff_provenance.sh$NL" "$H/.claude/bin/handoff_provenance.sh"
inst "$SRC/install.sh" --doctor
check "F1: link report shows the <LF> target" yes "$(has "$OUT" "ok      $H/.claude/bin/handoff_provenance.sh -> $(q "$SRC/bin/handoff_provenance.sh$NL")")"
must rm -f "$SRC/bin/handoff_provenance.sh$NL"

# F2. a dangling .claude link to nowhere<LF> is named in $'...' form.
fresh_sandbox
must rmdir "$P"; must mkdir "$P"
must ln -s "$T/nowhere$NL" "$P/.claude"
inst "$SRC/install.sh" --scope project --project "$P"
check "F2: refused (exit 2)" 2 "$RC"
check "F2: names the <LF> target" yes "$(has "$OUT" "dangling symlink (-> $(q "$T/nowhere$NL"))")"

# F3. a project settings link into a missing d<LF> is refused even though a
#     sibling d exists; the sibling is not written.
fresh_sandbox
must mkdir -p "$P/.claude" "$T/d"
must ln -s "$T/d$NL/settings.json" "$P/.claude/settings.json"
inst "$SRC/install.sh" --scope project --project "$P"
check "F3: refused (exit 2)" 2 "$RC"
check "F3: says the directory does not exist" yes "$(has "$OUT" "whose directory does not exist")"
check "F3: nothing written into the sibling d" no "$(yn test -e "$T/d/settings.json")"

finish
