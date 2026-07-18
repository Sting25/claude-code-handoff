#!/usr/bin/env bash
# Core behavioral coverage for write_handoff.sh beyond the two existing tests
# (--if-curated sentinel scoping, and rotation-timestamp portability). Covers
# the happy-path document shape, argument parsing, the --if-stale-by
# deprecation alias, history pruning + HANDOFF_HISTORY_KEEP=0, the .gitignore
# bootstrap toggle, pinned-context injection, in-flight .md listing, and the
# substrate snapshot. Pure git + coreutils, so no jq/perl gate.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
SENTINEL="<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->"
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# A repo that already ignores .claude/ (committed), so a default run leaves a
# clean working tree (no .gitignore churn, no untracked .claude artifacts).
mk_repo_gitignored() {
  local d; d="$(mk_repo)"
  printf '.claude/\n' > "$d/.gitignore"
  git -C "$d" add .gitignore
  git -C "$d" commit -qm "ignore .claude"
  printf '%s\n' "$d"
}

echo "write_handoff.sh — happy path / args / rotation / bootstrap / pinned / in-flight / substrate"

# --- Happy path: stdout is the path, document has all sections --------------
repo="$(mk_repo_gitignored)"
path="$( cd "$repo" && bash "$WH" 2>/dev/null )"
doc="$(cat "$path" 2>/dev/null)"
check "stdout is handoff_current.md path" "$repo/.claude/handoff_current.md" "$path"
check "doc: title"          yes "$(has "$doc" "session handoff (auto-generated)")"
check "doc: HEAD line"       yes "$(has "$doc" "**HEAD:**")"
check "doc: Branch line"     yes "$(has "$doc" "**Branch:**")"
check "doc: Recent commits"  yes "$(has "$doc" "### Recent commits")"
check "doc: Working tree"    yes "$(has "$doc" "### Working tree")"
check "doc: Notes header"    yes "$(has "$doc" "## Notes from this session")"
check "doc: placeholder sentinel" yes "$(has "$doc" "$SENTINEL")"
check "clean tree -> _clean_"     yes "$(has "$doc" "_clean_")"
rm -rf "$repo"

# --- Dirty working tree is reflected ----------------------------------------
repo="$(mk_repo_gitignored)"
echo x > "$repo/dirty.txt"            # untracked, not ignored
doc="$( cd "$repo" && bash "$WH" >/dev/null 2>&1; cat "$repo/.claude/handoff_current.md" )"
check "dirty tree -> not _clean_"     no  "$(has "$doc" "_clean_")"
check "dirty tree -> lists the file"  yes "$(has "$doc" "dirty.txt")"
rm -rf "$repo"

# --- Not a git repo -> git-optional: writes a handoff anchored on cwd, with a
#     "not a git repository" snapshot note instead of erroring out ------------
notrepo="$(mktemp -d)"
rc=0
out="$( cd "$notrepo" && env -u CLAUDE_PROJECT_DIR bash "$WH" 2>/dev/null )" || rc=$?
doc="$(cat "$notrepo/.claude/handoff_current.md" 2>/dev/null)"
check "non-repo -> exit 0"                  0   "$rc"
check "non-repo -> handoff path printed"    yes "$(has "$out" ".claude/handoff_current.md")"
check "non-repo -> 'not a git repo' note"   yes "$(has "$doc" "Not a git repository")"
check "non-repo -> verify block uses ls"    yes "$(has "$doc" "ls -la")"
check "non-repo -> no git in verify block"  no  "$(has "$doc" "git -C")"
rm -rf "$notrepo"

# --- Unknown argument -> exit 2 ---------------------------------------------
repo="$(mk_repo)"
err="$( cd "$repo" && bash "$WH" --bogus 2>&1 >/dev/null )"; rc=$?
check "unknown arg -> exit 2"           2   "$rc"
check "unknown arg -> error message"    yes "$(has "$err" "unknown argument")"
rm -rf "$repo"

# --- --if-stale-by deprecation alias: warns, tolerates numeric, exit 0 ------
repo="$(mk_repo_gitignored)"
err="$( cd "$repo" && bash "$WH" --if-stale-by 300 2>&1 >/dev/null )"; rc=$?
check "--if-stale-by -> exit 0"             0   "$rc"
check "--if-stale-by -> deprecation warn"   yes "$(has "$err" "deprecated")"
check "--if-stale-by -> numeric not 'unknown'" no "$(has "$err" "unknown argument")"
# The =VALUE spelling is tolerated too.
err="$( cd "$repo" && bash "$WH" --if-stale-by=300 2>&1 >/dev/null )"; rc=$?
check "--if-stale-by=VALUE -> exit 0"       0   "$rc"
check "--if-stale-by=VALUE -> deprecation"  yes "$(has "$err" "deprecated")"
rm -rf "$repo"

# --- History pruning to HANDOFF_HISTORY_KEEP --------------------------------
repo="$(mk_repo_gitignored)"
hist="$repo/.claude/handoff_history"; mkdir -p "$hist"
echo cur > "$repo/.claude/handoff_current.md"
touch -d "2020-06-06T00:00:00Z" "$repo/.claude/handoff_current.md"   # newest after rotation (ISO T/Z form: GNU + BSD)
for ts in 2020-01-01_000000 2020-01-02_000000 2020-01-03_000000; do
  echo old > "$hist/handoff_$ts.md"
done
( cd "$repo" && HANDOFF_HISTORY_KEEP=2 bash "$WH" >/dev/null 2>&1 )
kept="$(find "$hist" -maxdepth 1 -name 'handoff_*.md' 2>/dev/null | wc -l | tr -d ' ')"
check "prune keeps exactly KEEP(2)"          2   "$kept"
check "rotated current survives (newest)"    yes "$([[ -f "$hist/handoff_2020-06-06_000000.md" ]] && echo yes || echo no)"
check "oldest history pruned"                no  "$([[ -f "$hist/handoff_2020-01-01_000000.md" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- Invalid HANDOFF_HISTORY_KEEP falls back to 5 (no history wipe) ----------
# Regression: KEEP=-1 made prune run `tail -n +0`, which on GNU deletes EVERY
# history file (silent data loss). A negative/garbage value must clamp to the
# default 5 and preserve existing history, not erase it.
for bad in -1 abc; do
  repo="$(mk_repo_gitignored)"
  hist="$repo/.claude/handoff_history"; mkdir -p "$hist"
  echo cur > "$repo/.claude/handoff_current.md"
  for ts in 2020-01-01_000000 2020-01-02_000000 2020-01-03_000000; do
    echo old > "$hist/handoff_$ts.md"
  done
  err="$( cd "$repo" && HANDOFF_HISTORY_KEEP="$bad" bash "$WH" 2>&1 >/dev/null )"; rc=$?
  kept="$(find "$hist" -maxdepth 1 -name 'handoff_*.md' 2>/dev/null | wc -l | tr -d ' ')"
  check "KEEP=$bad -> exit 0"               0   "$rc"
  check "KEEP=$bad -> warns + clamps"       yes "$(has "$err" "not a non-negative integer")"
  check "KEEP=$bad -> history NOT wiped"    yes "$([[ "$kept" -ge 3 ]] && echo yes || echo no)"
  rm -rf "$repo"
done

# --- HANDOFF_HISTORY_KEEP=0 disables rotation/retention ---------------------
repo="$(mk_repo_gitignored)"
mkdir -p "$repo/.claude"
echo "old current MARKER_OLDCUR" > "$repo/.claude/handoff_current.md"
( cd "$repo" && HANDOFF_HISTORY_KEEP=0 bash "$WH" >/dev/null 2>&1 )
check "KEEP=0 -> no history dir"        no  "$([[ -d "$repo/.claude/handoff_history" ]] && echo yes || echo no)"
check "KEEP=0 -> old current overwritten" no "$(has "$(cat "$repo/.claude/handoff_current.md")" "MARKER_OLDCUR")"
rm -rf "$repo"

# --- .gitignore bootstrap: on by default, off via env -----------------------
repo="$(mk_repo)"                       # no .gitignore present
( cd "$repo" && HANDOFF_HISTORY_KEEP=0 bash "$WH" >/dev/null 2>&1 )
check "bootstrap on -> .gitignore created" yes "$([[ -f "$repo/.gitignore" ]] && echo yes || echo no)"
check "bootstrap on -> ignores current"    yes "$(has "$(cat "$repo/.gitignore" 2>/dev/null)" ".claude/handoff_current.md")"
rm -rf "$repo"

repo="$(mk_repo)"
( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 HANDOFF_HISTORY_KEEP=0 bash "$WH" >/dev/null 2>&1 )
check "bootstrap off -> no .gitignore" no "$([[ -f "$repo/.gitignore" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- Pinned-context injection -----------------------------------------------
repo="$(mk_repo_gitignored)"
mkdir -p "$repo/.claude"
printf 'Durable pinned line MARKER_PIN\n' > "$repo/.claude/handoff_pinned.md"
doc="$( cd "$repo" && HANDOFF_HISTORY_KEEP=0 bash "$WH" >/dev/null 2>&1; cat "$repo/.claude/handoff_current.md" )"
check "pinned present -> 📌 section" yes "$(has "$doc" "Pinned — carried forward")"
check "pinned present -> content injected" yes "$(has "$doc" "MARKER_PIN")"
rm -rf "$repo"

repo="$(mk_repo_gitignored)"           # no pinned file
doc="$( cd "$repo" && HANDOFF_HISTORY_KEEP=0 bash "$WH" >/dev/null 2>&1; cat "$repo/.claude/handoff_current.md" )"
check "no pinned -> no 📌 section" no "$(has "$doc" "Pinned — carried forward")"
rm -rf "$repo"

# --- In-flight .md listing under docs/ --------------------------------------
# docs/ must already be tracked, else git collapses the whole untracked dir to
# "?? docs/" and the individual .md is never surfaced (real script behavior).
repo="$(mk_repo_gitignored)"
mkdir -p "$repo/docs"
printf 'placeholder\n' > "$repo/docs/.keep"
git -C "$repo" add docs/.keep && git -C "$repo" commit -qm "track docs/"
printf '# draft\n' > "$repo/docs/draft.md"          # untracked, in a tracked dir
doc="$( cd "$repo" && HANDOFF_HISTORY_KEEP=0 bash "$WH" >/dev/null 2>&1; cat "$repo/.claude/handoff_current.md" )"
check "in-flight section present"   yes "$(has "$doc" "In-flight (untracked or modified .md under")"
check "in-flight lists docs/draft"  yes "$(has "$doc" "docs/draft.md")"
rm -rf "$repo"

repo="$(mk_repo_gitignored)"
mkdir -p "$repo/docs"                                # docs exists but has no .md
doc="$( cd "$repo" && HANDOFF_HISTORY_KEEP=0 bash "$WH" >/dev/null 2>&1; cat "$repo/.claude/handoff_current.md" )"
check "in-flight empty -> _none_"   yes "$(has "$doc" "_none_")"
rm -rf "$repo"

# --- Substrate snapshot (sibling repo) --------------------------------------
parent="$(mktemp -d)"
main="$parent/main"; sub="$parent/_shared"
for d in "$main" "$sub"; do
  mkdir -p "$d"; git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  echo seed > "$d/seed.txt"; git -C "$d" add seed.txt; git -C "$d" commit -qm seed
done
printf '.claude/\n' > "$main/.gitignore"; git -C "$main" add .gitignore; git -C "$main" commit -qm gi
doc="$( cd "$main" && HANDOFF_HISTORY_KEEP=0 HANDOFF_SUBSTRATE_NAME=_shared bash "$WH" >/dev/null 2>&1; cat "$main/.claude/handoff_current.md" )"
check "substrate snapshot present" yes "$(has "$doc" "## Substrate: _shared")"
rm -rf "$parent"

finish
