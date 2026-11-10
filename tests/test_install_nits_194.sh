#!/usr/bin/env bash
# Installer nits from the review of PR 192 (#194):
#   A. a project --uninstall removes the empty .claude/ the install created,
#      and only that one (a pre-existing dir, or one with other files, stays)
#   B. a piped no-arg install says why it cannot run (exit 2, nothing written)
#   C. the "no backup needed" line says what an abort does for the seed state
#      (absent: removed; empty: emptied again)
#   D. a gone-project uninstall reached through a symlink (a dangling link to
#      the project, or a link above it) clears the registry line and markers
#   E. (review of PR 202) a settings.json symlinked into a dotfiles directory:
#      uninstall never removes the dotfiles directory; a stale claude_dir
#      marker never removes a directory the user recreated; both files wired
#      are cleaned in order and the marker waits for the last one
#   F. a gone project whose parent is gone too, under a symlinked ancestor,
#      still clears the registry line and markers; no match prints a WARN
#   G. `bash <(cat install.sh)` and `bash -s < install.sh` refuse (exit 2) and
#      write nothing
#   H. an install aborted after creating .claude/ removes it and its marker
# Every run sandboxes HOME and CLAUDE_HOME, so nothing touches ~/.claude.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh nits (#194)"

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

H=""; P=""
fresh_sandbox() {
  H="$(mktemp -d)"; P="$(mktemp -d)"
  cleanup_on_exit "$H" "$P"
  P="$(cd "$P" && pwd -P)"
  mkdir -p "$H/.claude"
}
inst() {
  OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" "$@" 2>&1 </dev/null)"
  RC=$?
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
exists() { [[ -e "$1" ]] && echo yes || echo no; }
nmarkers() { find "$H/.claude/handoff_settings_backups" -type f \( -name '*.created' -o -name '*.mkdir' \) 2>/dev/null | wc -l | tr -d ' '; }

# --- A. the empty .claude/ ---------------------------------------------------------------
fresh_sandbox
rmdir "$P" 2>/dev/null; mkdir -p "$P"            # P exists, has no .claude
inst --scope project --project "$P"
check "A1: install created .claude" yes "$(exists "$P/.claude")"
inst --uninstall --scope project --project "$P"
check "A1: uninstall exit 0" 0 "$RC"
check "A1: settings file gone" no "$(exists "$P/.claude/settings.json")"
check "A1: empty .claude removed" no "$(exists "$P/.claude")"
check "A1: output says so" yes "$(has "$OUT" "this installer created it; it is empty")"
check "A1: no marker left behind" 0 "$(nmarkers)"

fresh_sandbox
inst --scope project --project "$P" --local
inst --uninstall --scope project --project "$P" --local
check "A2 (--local): empty .claude removed" no "$(exists "$P/.claude")"

fresh_sandbox
mkdir -p "$P/.claude"                              # pre-existing, empty
inst --scope project --project "$P"
inst --uninstall --scope project --project "$P"
check "A3: pre-existing .claude kept" yes "$(exists "$P/.claude")"
check "A3: settings file still removed" no "$(exists "$P/.claude/settings.json")"

fresh_sandbox
inst --scope project --project "$P"
printf 'mine\n' > "$P/.claude/notes.txt"
inst --uninstall --scope project --project "$P"
check "A4: .claude with a user file kept" yes "$(exists "$P/.claude/notes.txt")"
check "A4: no rmdir message" no "$(has "$OUT" "it is empty")"
check "A4: marker consumed even though the dir stayed" 0 "$(nmarkers)"

# --- B. piped no-arg install -----------------------------------------------------------------
fresh_sandbox
OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash -s < "$SRC/install.sh" 2>&1)"
RC=$?
check "B: piped no-arg install exits 2" 2 "$RC"
check "B: says there is no clone" yes "$(has "$OUT" "ERROR: install.sh was read from a pipe, so there is no clone to install from.")"
check "B: no 'installing ... from  into'" no "$(has "$OUT" "installing handoff skill from")"
check "B: no cp error" no "$(has "$OUT" "cp:")"
check "B: nothing written to claude home" 0 "$(find "$H/.claude" -type f | wc -l | tr -d ' ')"

# --- C. seed-state wording -----------------------------------------------------------------------
fresh_sandbox
inst
check "C: absent seed: 'just created'" yes "$(has "$OUT" "was just created; an abort undoes that")"
fresh_sandbox
: > "$H/.claude/settings.json"
inst
check "C: empty seed: no 'just created'" no "$(has "$OUT" "was just created")"
check "C: empty seed: says an abort empties it" yes "$(has "$OUT" "was empty; an abort empties it again")"

# --- D. gone project reached through a symlink ----------------------------------------------------
# D1: a dangling link to the removed project.
fresh_sandbox
LNK_DIR="$(mktemp -d)"; cleanup_on_exit "$LNK_DIR"
ln -s "$P" "$LNK_DIR/p"
inst --scope project --project "$LNK_DIR/p"
check "D1: install registered the project" yes "$(has "$(cat "$H/.claude/handoff_projects" 2>/dev/null)" "$P")"
rm -rf "$P"
OUT="$(cd "$LNK_DIR" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --uninstall --scope project --project "$LNK_DIR/p" 2>&1 </dev/null)"
RC=$?
check "D1: gone uninstall exit 0" 0 "$RC"
check "D1: registry line cleared" "" "$(cat "$H/.claude/handoff_projects" 2>/dev/null)"
check "D1: no marker left behind" 0 "$(nmarkers)"

# D2: a link above the removed project.
fresh_sandbox
LNK_DIR="$(mktemp -d)"; cleanup_on_exit "$LNK_DIR"
mkdir -p "$P/work/proj"
ln -s "$P/work" "$LNK_DIR/w"
inst --scope project --project "$LNK_DIR/w/proj"
check "D2: install registered the project" yes "$(has "$(cat "$H/.claude/handoff_projects" 2>/dev/null)" "$P/work/proj")"
rm -rf "$P/work/proj"
OUT="$(cd "$LNK_DIR" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --uninstall --scope project --project "$LNK_DIR/w/proj" 2>&1 </dev/null)"
RC=$?
check "D2: gone uninstall exit 0" 0 "$RC"
check "D2: registry line cleared" "" "$(cat "$H/.claude/handoff_projects" 2>/dev/null)"
check "D2: no marker left behind" 0 "$(nmarkers)"

# --- E. symlinked settings, stale marker, both files -------------------------------------------
# E1: settings.json is a symlink into a dotfiles directory.
fresh_sandbox
DOT="$(mktemp -d)"; cleanup_on_exit "$DOT"; DOT="$(cd "$DOT" && pwd -P)"
rmdir "$P"; mkdir -p "$P"
inst --scope project --project "$P"
mkdir -p "$DOT/claude"
mv "$P/.claude/settings.json" "$DOT/claude/settings.json"
ln -s "$DOT/claude/settings.json" "$P/.claude/settings.json"
inst --uninstall --scope project --project "$P"
check "E1: uninstall exit 0" 0 "$RC"
check "E1: dotfiles directory survives" yes "$(exists "$DOT/claude")"
check "E1: no 'installer created it' for the dotfiles dir" no "$(has "$OUT" "remove  $DOT/claude/ (this installer created it")"
check "E1: no 'this installer created it; it is empty' line" no "$(has "$OUT" "it is empty")"
check "E1: no marker left behind" 0 "$(nmarkers)"

# E2: the marker must not outlive the directory.
fresh_sandbox
inst --scope project --project "$P"
printf 'mine\n' > "$P/.claude/notes.txt"
inst --uninstall --scope project --project "$P"
check "E2: dir kept (user file)" yes "$(exists "$P/.claude/notes.txt")"
rm -rf "$P/.claude"; mkdir "$P/.claude"            # the user's own directory now
inst --scope project --project "$P"
inst --uninstall --scope project --project "$P"
check "E2: the user's recreated .claude survives" yes "$(exists "$P/.claude")"
check "E2: no 'installer created it; it is empty'" no "$(has "$OUT" "it is empty")"

# E3: both files wired, uninstalled in order; the marker waits for the last one.
fresh_sandbox
inst --scope project --project "$P"
inst --scope project --project "$P" --local
check "E3: both settings files are wired" yes "$(exists "$P/.claude/settings.local.json")"
inst --uninstall --scope project --project "$P"
check "E3: first uninstall keeps .claude (local still wired)" yes "$(exists "$P/.claude")"
check "E3: first uninstall keeps the dir marker" 1 "$(find "$H/.claude/handoff_settings_backups" -type f -name claude_dir.mkdir | wc -l | tr -d ' ')"
inst --uninstall --scope project --project "$P" --local
check "E3: second uninstall removes .claude" no "$(exists "$P/.claude")"
check "E3: no marker left behind" 0 "$(nmarkers)"

# --- F. gone project, parent gone, symlinked ancestor ----------------------------------------------
fresh_sandbox
REAL="$(mktemp -d)"; cleanup_on_exit "$REAL"; REAL="$(cd "$REAL" && pwd -P)"
LINKS="$(mktemp -d)"; cleanup_on_exit "$LINKS"
ln -s "$REAL" "$LINKS/tmp-link"
mkdir -p "$LINKS/tmp-link/a/b/proj"
inst --scope project --project "$LINKS/tmp-link/a/b/proj"
check "F1: install registered the physical path" yes "$(has "$(cat "$H/.claude/handoff_projects" 2>/dev/null)" "$REAL/a/b/proj")"
rm -rf "$REAL/a"
OUT="$(cd "$LINKS" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --uninstall --scope project --project "$LINKS/tmp-link/a/b/proj" 2>&1 </dev/null)"
RC=$?
check "F1: exit 0" 0 "$RC"
check "F1: registry line cleared" "" "$(cat "$H/.claude/handoff_projects" 2>/dev/null)"
check "F1: no marker left behind" 0 "$(nmarkers)"
check "F1: no WARN when the line matched" no "$(has "$OUT" "WARN")"
# F2: nothing matches: say so, naming the registry path and the line.
fresh_sandbox
OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --uninstall --scope project --project "$P/never/was" 2>&1 </dev/null)"
RC=$?
check "F2: exit 0" 0 "$RC"
check "F2: WARN printed" yes "$(has "$OUT" "WARN    no registry line '$P/never/was<TAB>settings.json' in $H/.claude/handoff_projects")"

# --- G. no usable source tree --------------------------------------------------------------------------
fresh_sandbox
OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash <(cat "$SRC/install.sh") 2>&1 </dev/null)"
RC=$?
check "G1: process-substitution install exits 2" 2 "$RC"
check "G1: says there is no clone" yes "$(has "$OUT" "so there is no clone to install from")"
check "G1: nothing written into the jailed home" 0 "$(find "$H/.claude" -mindepth 1 | wc -l | tr -d ' ')"
check "G1: no dangling link" no "$(has "$OUT" "-> /dev/fd")"
fresh_sandbox
OUT="$(cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" bash -s < "$SRC/install.sh" 2>&1)"
RC=$?
check "G2: bash -s exits 2" 2 "$RC"
check "G2: says read from a pipe" yes "$(has "$OUT" "was read from a pipe")"
check "G2: nothing written into the jailed home" 0 "$(find "$H/.claude" -mindepth 1 | wc -l | tr -d ' ')"

# --- H. abort after creating .claude/ --------------------------------------------------------------------
REAL_JQ="$(command -v jq)"
SHIM="$(mktemp -d)"; cleanup_on_exit "$SHIM"
cat > "$SHIM/jq" <<SH
#!/usr/bin/env bash
if [[ -n "\${FAIL_JQ_MATCH:-}" && "\$*" == *"\$FAIL_JQ_MATCH"* ]]; then exit 5; fi
exec "$REAL_JQ" "\$@"
SH
chmod +x "$SHIM/jq"
fresh_sandbox
OUT="$(cd "$P" && FAIL_JQ_MATCH='(.statusLine? // null) == null' PATH="$SHIM:$PATH" HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --scope project --project "$P" 2>&1 </dev/null)"
RC=$?
check "H: the forced abort exits nonzero" yes "$([[ $RC -ne 0 ]] && echo yes || echo no)"
check "H: it got past the mkdir" yes "$(has "$OUT" "new     $P/.claude/")"
check "H: .claude removed again" no "$(exists "$P/.claude")"
check "H: no marker left behind" 0 "$(nmarkers)"
fresh_sandbox
mkdir -p "$P/.claude"                                   # pre-existing: never ours to remove
OUT="$(cd "$P" && FAIL_JQ_MATCH='(.statusLine? // null) == null' PATH="$SHIM:$PATH" HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --scope project --project "$P" 2>&1 </dev/null)"
check "H: a pre-existing .claude survives the abort" yes "$(exists "$P/.claude")"

finish
