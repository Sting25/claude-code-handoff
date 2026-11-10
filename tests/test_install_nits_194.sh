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
#   H. an install aborted after creating .claude/ removes it (while empty) and
#      always drops its marker
#   I. (second review of PR 202) a dangling settings.json link or a dangling
#      .claude link is refused before anything is copied; no marker ever
#      describes a pre-existing .claude, also after an aborted install
#   J. two project paths with the same cksum key: the `path` file keeps one
#      project's markers from acting on the other
#   K. the directory marker is bound to the directory's identity: a .claude
#      the user removed and recreated is never removed
#   L. a refused or unfinished project uninstall (invalid JSON, a failed
#      skeleton check) keeps the markers and registry line and exits non-zero
#   M. a gone project whose nearest existing parent cannot be entered: WARN,
#      registry line kept
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
OUT="$(cd "$P" && FAIL_JQ_MATCH='.hooks //= {}' PATH="$SHIM:$PATH" HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --scope project --project "$P" 2>&1 </dev/null)"
RC=$?
check "H: the forced abort exits nonzero" yes "$([[ $RC -ne 0 ]] && echo yes || echo no)"
check "H: it got past the mkdir" yes "$(has "$OUT" "new     $P/.claude/")"
check "H: .claude removed again" no "$(exists "$P/.claude")"
check "H: no marker left behind" 0 "$(nmarkers)"
check "H: no registry line" "" "$(cat "$H/.claude/handoff_projects" 2>/dev/null)"
fresh_sandbox
mkdir -p "$P/.claude"                                   # pre-existing: never ours to remove
OUT="$(cd "$P" && FAIL_JQ_MATCH='.hooks //= {}' PATH="$SHIM:$PATH" HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --scope project --project "$P" 2>&1 </dev/null)"
check "H: a pre-existing .claude survives the abort" yes "$(exists "$P/.claude")"

# --- I. dangling links are refused; no marker for a pre-existing .claude ----------------------------
# I1: a pre-existing .claude holding a settings.json link into a missing dotfiles directory.
fresh_sandbox
DOT="$(mktemp -d)"; cleanup_on_exit "$DOT"; DOT="$(cd "$DOT" && pwd -P)"
mkdir -p "$P/.claude"; ln -s "$DOT/claude/settings.json" "$P/.claude/settings.json"
inst --scope project --project "$P"
check "I1: install refuses (exit 2)" 2 "$RC"
check "I1: ERROR names the dangling link" yes "$(has "$OUT" "ERROR: $P/.claude/settings.json is a dangling symlink (-> $DOT/claude/settings.json, whose directory does not exist)")"
check "I1: dotfiles directory not created" no "$(exists "$DOT/claude")"
check "I1: nothing copied into the jailed home" 0 "$(find "$H/.claude" -mindepth 1 | wc -l | tr -d ' ')"
check "I1: no marker" 0 "$(nmarkers)"
rm "$P/.claude/settings.json"                      # the user drops the link
inst --uninstall --scope project --project "$P"
check "I1: later uninstall keeps the pre-existing .claude" yes "$(exists "$P/.claude")"
# I2: the same layout under the abort shim: still refused before any jq runs, so no marker.
fresh_sandbox
DOT="$(mktemp -d)"; cleanup_on_exit "$DOT"; DOT="$(cd "$DOT" && pwd -P)"
mkdir -p "$P/.claude"; ln -s "$DOT/claude/settings.json" "$P/.claude/settings.json"
OUT="$(cd "$P" && FAIL_JQ_MATCH='.hooks //= {}' PATH="$SHIM:$PATH" HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --scope project --project "$P" 2>&1 </dev/null)"
RC=$?
check "I2: refused (exit 2)" 2 "$RC"
check "I2: no marker" 0 "$(nmarkers)"
rm "$P/.claude/settings.json"
inst --uninstall --scope project --project "$P"
check "I2: later uninstall keeps the pre-existing .claude" yes "$(exists "$P/.claude")"
# I3: <project>/.claude itself is a dangling link.
fresh_sandbox
NOWHERE="$(mktemp -d)"; cleanup_on_exit "$NOWHERE"; rmdir "$NOWHERE"
ln -s "$NOWHERE" "$P/.claude"
inst --scope project --project "$P"
check "I3: dangling .claude link refused (exit 2)" 2 "$RC"
check "I3: ERROR names it" yes "$(has "$OUT" "ERROR: $P/.claude is a dangling symlink")"
check "I3: link target not created" no "$(exists "$NOWHERE")"
check "I3: link left intact" yes "$([[ -L "$P/.claude" ]] && echo yes || echo no)"
# I4: an abort after a marker was written drops the marker even when the rmdir cannot run
# (here: the user's file landed in the new .claude mid-run, simulated by a pre-seeded abort
# point after the directory gained a file).
fresh_sandbox
cat > "$SHIM/jq-i4" <<SH
#!/usr/bin/env bash
if [[ "\$*" == *'.hooks //= {}'* ]]; then : > "$P/.claude/user-note"; exit 5; fi
exec "$REAL_JQ" "\$@"
SH
mkdir -p "$SHIM/i4"; mv "$SHIM/jq-i4" "$SHIM/i4/jq"; chmod +x "$SHIM/i4/jq"
OUT="$(cd "$P" && PATH="$SHIM/i4:$PATH" HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --scope project --project "$P" 2>&1 </dev/null)"
RC=$?
check "I4: aborted" yes "$([[ $RC -ne 0 ]] && echo yes || echo no)"
check "I4: non-empty .claude kept" yes "$(exists "$P/.claude/user-note")"
check "I4: no 'removed again' for the directory" no "$(has "$OUT" ".claude/ removed again")"
check "I4: marker dropped anyway" 0 "$(nmarkers)"

# --- J. cksum collision ------------------------------------------------------------------------------
# These two names give the same CRC (cksum) for any common prefix of equal length.
fresh_sandbox
COLL="$(mktemp -d)"; cleanup_on_exit "$COLL"; COLL="$(cd "$COLL" && pwd -P)"
PA="$COLL/proj-!!!!!"; PB="$COLL/proj-&?fq\$"
mkdir -p "$PA" "$PB/.claude"
check "J: the two paths share a cksum key" "$(printf '%s' "$PA" | cksum | awk '{print $1}')" "$(printf '%s' "$PB" | cksum | awk '{print $1}')"
OUT="$(cd "$PA" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --scope project --project "$PA" 2>&1 </dev/null)"
check "J: A installed with both markers" 2 "$(nmarkers)"
OUT="$(cd "$PB" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --uninstall --scope project --project "$PB" 2>&1 </dev/null)"
RC=$?
check "J: uninstall of never-installed B exits 0" 0 "$RC"
check "J: B's own .claude survives" yes "$(exists "$PB/.claude")"
check "J: WARN names the foreign key" yes "$(has "$OUT" "is keyed to another project")"
check "J: A's markers untouched" 2 "$(nmarkers)"
OUT="$(cd "$PB" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --scope project --project "$PB" 2>&1 </dev/null)"
check "J: install of B records no marker in A's key" 2 "$(nmarkers)"
check "J: install of B warns" yes "$(has "$OUT" "is keyed to another project")"
OUT="$(cd "$PB" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --uninstall --scope project --project "$PB" 2>&1 </dev/null)"
check "J: B's .claude still survives its own uninstall" yes "$(exists "$PB/.claude")"
OUT="$(cd "$PA" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --uninstall --scope project --project "$PA" 2>&1 </dev/null)"
check "J: A's uninstall still removes A's created .claude" no "$(exists "$PA/.claude")"
check "J: no marker left" 0 "$(nmarkers)"
# A key directory from an older install (no path file) is never trusted for the directory marker.
fresh_sandbox
inst --scope project --project "$P"
rm -f "$H/.claude/handoff_settings_backups"/*/path
inst --uninstall --scope project --project "$P"
check "J legacy: created settings file still removed" no "$(exists "$P/.claude/settings.json")"
check "J legacy: .claude kept (directory marker not trusted)" yes "$(exists "$P/.claude")"

# --- K. the directory marker is bound to the directory -------------------------------------------------
fresh_sandbox
inst --scope project --project "$P"
rm -rf "$P/.claude"; mkdir "$P/.claude"             # the user's own directory now
inst --uninstall --scope project --project "$P"
check "K: uninstall exit 0" 0 "$RC"
check "K: the user's recreated .claude survives" yes "$(exists "$P/.claude")"
check "K: no 'installer created it; it is empty'" no "$(has "$OUT" "it is empty")"
check "K: marker consumed" 0 "$(nmarkers)"

# --- L. a refused or unfinished project uninstall --------------------------------------------------------
fresh_sandbox
inst --scope project --project "$P"
cp "$P/.claude/settings.json" "$H/settings.good"
printf '\n// oops\n' >> "$P/.claude/settings.json"
inst --uninstall --scope project --project "$P"
check "L1: invalid JSON: exit non-zero" 1 "$RC"
check "L1: ERROR printed" yes "$(has "$OUT" "is not valid JSON")"
check "L1: says NOT done" yes "$(has "$OUT" "NOT done:")"
check "L1: markers kept" 2 "$(nmarkers)"
check "L1: registry line kept" yes "$(has "$(cat "$H/.claude/handoff_projects" 2>/dev/null)" "$P")"
check "L1: no 'done.' line" no "$(has "$OUT" "done. the repo")"
cp "$H/settings.good" "$P/.claude/settings.json"   # the user fixes the file
inst --uninstall --scope project --project "$P"
check "L1: after the fix, uninstall exit 0" 0 "$RC"
check "L1: after the fix, .claude removed" no "$(exists "$P/.claude")"
check "L1: after the fix, registry line cleared" "" "$(cat "$H/.claude/handoff_projects" 2>/dev/null)"
check "L1: after the fix, no marker" 0 "$(nmarkers)"
# L2: the skeleton check's jq fails after a good strip.
fresh_sandbox
inst --scope project --project "$P"
OUT="$(cd "$P" && FAIL_JQ_MATCH='del(.permissions.allow)' PATH="$SHIM:$PATH" HOME="$H" CLAUDE_HOME="$H/.claude" bash "$SRC/install.sh" --uninstall --scope project --project "$P" 2>&1 </dev/null)"
RC=$?
check "L2: skeleton jq failure: exit non-zero" 1 "$RC"
check "L2: ERROR names the skeleton check" yes "$(has "$OUT" "while checking whether $P/.claude/settings.json is the empty skeleton")"
check "L2: markers kept" 2 "$(nmarkers)"
check "L2: registry line kept" yes "$(has "$(cat "$H/.claude/handoff_projects" 2>/dev/null)" "$P")"
inst --uninstall --scope project --project "$P"
check "L2: re-run finishes: exit 0" 0 "$RC"
check "L2: re-run removes .claude" no "$(exists "$P/.claude")"
check "L2: re-run leaves no marker" 0 "$(nmarkers)"

# --- M. gone project, nearest existing parent not enterable ------------------------------------------------
fresh_sandbox
mkdir -p "$P/locked/proj"
inst --scope project --project "$P/locked/proj"
rm -rf "$P/locked/proj"; chmod 000 "$P/locked"
if ( cd "$P/locked" ) 2>/dev/null; then
  skip "M: directory permissions are not enforced here (running as root?)"
else
  inst --uninstall --scope project --project "$P/locked/proj"
  check "M: exit 1" 1 "$RC"
  check "M: WARN names the parent" yes "$(has "$OUT" "WARN    cannot enter $P/locked (the nearest existing parent of $P/locked/proj)")"
  check "M: no raw cd error" no "$(has "$OUT" "Permission denied")"
  check "M: registry line kept" yes "$(has "$(cat "$H/.claude/handoff_projects" 2>/dev/null)" "$P/locked/proj")"
fi
chmod 755 "$P/locked"

finish
