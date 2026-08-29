#!/usr/bin/env bash
# Behavioral coverage for bin/handoff_cache_prune.sh, the SessionStart-invoked
# self-prune of stale cached versions of THIS plugin under
# .../plugins/cache/<marketplace>/claude-code-handoff/<version>/.
#
# Real incident (2026-08-28): Claude Code's plugin updater never removes an
# old cached version once a newer one is installed, so a machine can end up
# with 0.14.1, 0.16.0, and 0.17.0 all cached at once, and a session loading
# the SKILL from the oldest while hook scripts resolve the newest. This
# script prunes every cached version except the newest-by-mtime and the
# version dir the running script itself lives in, and does nothing at all
# unless its own resolved path proves the plugin-cache shape exactly.
#
# Observable: which version directories under a constructed
# plugins/cache/<marketplace>/claude-code-handoff/ tree survive invoking the
# copy of the script planted inside one of those version dirs (mirroring how
# handoff_session_start.sh invokes its own sibling in a real install).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PRUNE_SRC="$REPO_ROOT/bin/handoff_cache_prune.sh"

# mk_cache <sandbox_root> <marketplace> <plugin_name> <version...>
# Creates plugins/cache/<marketplace>/<plugin_name>/<version>/bin for each
# version given, oldest-argument-first, each stamped one minute apart so
# mtime order is deterministic and matches argument order (last arg =
# newest). Also writes an installed_plugins.json manifest (F3) naming the
# LAST version argument as installed/current, matching the "newest wins"
# expectation the pre-F3 cases below assert on -- the F3-specific cases
# further down build a manifest that deliberately DISAGREES with mtime
# order instead, via mk_manifest directly. Echoes the plugin dir path.
mk_cache() {
  local root="$1" mkt="$2" plugin="$3"; shift 3
  local plugin_dir="$root/plugins/cache/$mkt/$plugin"
  local i=0 v vdir stamp last=""
  for v in "$@"; do
    vdir="$plugin_dir/$v"
    must mkdir -p "$vdir/bin"
    i=$((i + 1))
    # 2026-01-0<i> 00:00, so later args land later in time.
    stamp="$(printf '202601%02d0000' "$i")"
    must touch -t "$stamp" "$vdir"
    last="$v"
  done
  [[ -n "$last" ]] && mk_manifest "$root" "$mkt" "$plugin" "$last"
  printf '%s\n' "$plugin_dir"
}

# mk_manifest <sandbox_root> <marketplace> <plugin_name> <version>
# Writes plugins/installed_plugins.json naming "<plugin>@<marketplace>" as
# installed at <version> for the "user" scope, matching the real schema
# (.plugins["<plugin>@<marketplace>"][] with installPath/version per scope)
# measured against a real ~/.claude/plugins/installed_plugins.json
# (2026-08). Overwrites any manifest already at that path, so a test can
# call this again after mk_cache to plant a DIFFERENT current than the
# mtime-newest dir (the whole point of the F3 discrimination cases below).
mk_manifest() {
  local root="$1" mkt="$2" plugin="$3" version="$4"
  local manifest="$root/plugins/installed_plugins.json"
  must mkdir -p "$root/plugins"
  must cat > "$manifest" <<EOF
{
  "version": 1,
  "plugins": {
    "$plugin@$mkt": [
      {
        "scope": "user",
        "installPath": "$root/plugins/cache/$mkt/$plugin/$version",
        "version": "$version"
      }
    ]
  }
}
EOF
}

# run_prune_from <version_dir>: copies the real script into
# <version_dir>/bin and runs it from there (its BASH_SOURCE-resolved self_dir
# is then genuinely <version_dir>/bin, matching how handoff_session_start.sh
# invokes its own sibling copy in a real cache install). Echoes exit code.
run_prune_from() {
  local vdir="$1" rc=0
  must mkdir -p "$vdir/bin"
  must cp "$PRUNE_SRC" "$vdir/bin/handoff_cache_prune.sh"
  bash "$vdir/bin/handoff_cache_prune.sh" >/dev/null 2>&1 || rc=$?
  return "$rc"
}

echo "handoff_cache_prune.sh: self-prune stale cached plugin versions"

# --- 1: stale versions removed, newest kept, running version (older) kept ---
sandbox="$(mktemp -d)"; cleanup_on_exit "$sandbox"
plugin_dir="$(mk_cache "$sandbox" mymkt claude-code-handoff 0.9.0 0.14.1 0.16.0 0.17.0)"
run_prune_from "$plugin_dir/0.14.1"; rc=$?
check "case1: exit 0"                    0   "$rc"
check "case1: 0.9.0 (stale) removed"     no  "$([[ -d "$plugin_dir/0.9.0"  ]] && echo yes || echo no)"
check "case1: 0.16.0 (stale) removed"    no  "$([[ -d "$plugin_dir/0.16.0" ]] && echo yes || echo no)"
check "case1: 0.17.0 (newest) kept"      yes "$([[ -d "$plugin_dir/0.17.0" ]] && echo yes || echo no)"
check "case1: 0.14.1 (running, older) kept" yes "$([[ -d "$plugin_dir/0.14.1" ]] && echo yes || echo no)"

# --- 2: running script IS the newest -> only itself survives ----------------
sandbox="$(mktemp -d)"; cleanup_on_exit "$sandbox"
plugin_dir="$(mk_cache "$sandbox" mymkt claude-code-handoff 0.16.0 0.17.0)"
run_prune_from "$plugin_dir/0.17.0"; rc=$?
check "case2: exit 0"                 0   "$rc"
check "case2: 0.16.0 removed"         no  "$([[ -d "$plugin_dir/0.16.0" ]] && echo yes || echo no)"
check "case2: 0.17.0 (running+newest) kept" yes "$([[ -d "$plugin_dir/0.17.0" ]] && echo yes || echo no)"

# --- 3: single-version cache -> untouched, no error --------------------------
sandbox="$(mktemp -d)"; cleanup_on_exit "$sandbox"
plugin_dir="$(mk_cache "$sandbox" mymkt claude-code-handoff 0.17.0)"
run_prune_from "$plugin_dir/0.17.0"; rc=$?
check "case3: exit 0"            0   "$rc"
check "case3: only version kept" yes "$([[ -d "$plugin_dir/0.17.0" ]] && echo yes || echo no)"

# --- 4: non-matching path shapes -> silent no-op, nothing deleted -----------

# 4a: not under plugins/cache at all.
sandbox="$(mktemp -d)"; cleanup_on_exit "$sandbox"
odd_root="$sandbox/somewhere/else/claude-code-handoff"
must mkdir -p "$odd_root/0.9.0/bin" "$odd_root/0.17.0/bin"
must touch -t 202601010000 "$odd_root/0.9.0"
must touch -t 202601020000 "$odd_root/0.17.0"
must cp "$PRUNE_SRC" "$odd_root/0.9.0/bin/handoff_cache_prune.sh"
rc=0; bash "$odd_root/0.9.0/bin/handoff_cache_prune.sh" >/dev/null 2>&1 || rc=$?
check "case4a: exit 0 (guard exits clean, not error)" 0 "$rc"
check "case4a: 0.9.0 untouched (not plugins/cache shape)" yes \
  "$([[ -d "$odd_root/0.9.0" ]] && echo yes || echo no)"
check "case4a: 0.17.0 untouched" yes "$([[ -d "$odd_root/0.17.0" ]] && echo yes || echo no)"

# 4b: under plugins/cache but a DIFFERENT plugin name: must never touch
# another plugin's cache, even one sitting right next to this one.
sandbox="$(mktemp -d)"; cleanup_on_exit "$sandbox"
other_dir="$(mk_cache "$sandbox" mymkt some-other-plugin 0.9.0 0.17.0)"
must cp "$PRUNE_SRC" "$other_dir/0.9.0/bin/handoff_cache_prune.sh"
rc=0; bash "$other_dir/0.9.0/bin/handoff_cache_prune.sh" >/dev/null 2>&1 || rc=$?
check "case4b: exit 0" 0 "$rc"
check "case4b: sibling plugin's stale version untouched" yes \
  "$([[ -d "$other_dir/0.9.0" ]] && echo yes || echo no)"
check "case4b: sibling plugin's newest version untouched" yes \
  "$([[ -d "$other_dir/0.17.0" ]] && echo yes || echo no)"

# 4c: version dir name doesn't look like a version (e.g. hand-run from a git
# clone, or a future non-semver channel name): whole tree left alone.
sandbox="$(mktemp -d)"; cleanup_on_exit "$sandbox"
plugin_dir="$(mk_cache "$sandbox" mymkt claude-code-handoff 0.9.0)"
must mkdir -p "$plugin_dir/dev/bin"
must touch -t 202601050000 "$plugin_dir/dev"
must cp "$PRUNE_SRC" "$plugin_dir/dev/bin/handoff_cache_prune.sh"
rc=0; bash "$plugin_dir/dev/bin/handoff_cache_prune.sh" >/dev/null 2>&1 || rc=$?
check "case4c: exit 0" 0 "$rc"
check "case4c: non-version running dir untouched" yes \
  "$([[ -d "$plugin_dir/dev" ]] && echo yes || echo no)"
check "case4c: real stale version untouched (no proven newest)" yes \
  "$([[ -d "$plugin_dir/0.9.0" ]] && echo yes || echo no)"

# 4d: plugin dir is a symlink: refuse to walk through it.
sandbox="$(mktemp -d)"; cleanup_on_exit "$sandbox"
real_dir="$(mk_cache "$sandbox" mymkt real-target 0.9.0 0.17.0)"
must mkdir -p "$sandbox/plugins/cache/mymkt"
must ln -s "$real_dir" "$sandbox/plugins/cache/mymkt/claude-code-handoff"
must cp "$PRUNE_SRC" "$real_dir/0.9.0/bin/handoff_cache_prune.sh"
rc=0
bash "$sandbox/plugins/cache/mymkt/claude-code-handoff/0.9.0/bin/handoff_cache_prune.sh" \
  >/dev/null 2>&1 || rc=$?
check "case4d: exit 0" 0 "$rc"
check "case4d: version under symlinked plugin dir untouched" yes \
  "$([[ -d "$real_dir/0.9.0" ]] && echo yes || echo no)"

# --- 5: a foreign, non-version-shaped directory is never a delete candidate -
sandbox="$(mktemp -d)"; cleanup_on_exit "$sandbox"
plugin_dir="$(mk_cache "$sandbox" mymkt claude-code-handoff 0.9.0 0.17.0)"
must mkdir -p "$plugin_dir/my-notes"
must touch -t 202601060000 "$plugin_dir/my-notes"
run_prune_from "$plugin_dir/0.9.0"; rc=$?
check "case5: exit 0"                       0   "$rc"
check "case5: foreign dir survives"         yes "$([[ -d "$plugin_dir/my-notes" ]] && echo yes || echo no)"
check "case5: real stale version 0.9.0 (running) kept" yes \
  "$([[ -d "$plugin_dir/0.9.0" ]] && echo yes || echo no)"
check "case5: real newest 0.17.0 kept" yes "$([[ -d "$plugin_dir/0.17.0" ]] && echo yes || echo no)"

# --- 6: idempotent / concurrency-safe: a second run after everything is ---
# already pruned (nothing left to delete but the two survivors) must not
# error, the same shape `rm -rf` on an already-vanished directory from a
# second concurrent session would hit.
sandbox="$(mktemp -d)"; cleanup_on_exit "$sandbox"
plugin_dir="$(mk_cache "$sandbox" mymkt claude-code-handoff 0.9.0 0.14.1 0.17.0)"
must mkdir -p "$plugin_dir/0.14.1/bin"
must cp "$PRUNE_SRC" "$plugin_dir/0.14.1/bin/handoff_cache_prune.sh"
bash "$plugin_dir/0.14.1/bin/handoff_cache_prune.sh" >/dev/null 2>&1
rc=0; bash "$plugin_dir/0.14.1/bin/handoff_cache_prune.sh" >/dev/null 2>&1 || rc=$?
check "case6: second run still exit 0" 0 "$rc"
check "case6: survivors unchanged after second run" yes \
  "$([[ -d "$plugin_dir/0.14.1" && -d "$plugin_dir/0.17.0" && ! -d "$plugin_dir/0.9.0" ]] && echo yes || echo no)"

# --- 7: SessionStart integration: invoking handoff_session_start.sh from a
# relocated plugin-cache-shaped bin/ also prunes its cache siblings, proving
# the wiring (not just the standalone script) actually fires it. Mirrors
# tests/test_plugin_layout.sh's relocation-safety pattern.
sandbox="$(mktemp -d)"; cleanup_on_exit "$sandbox"
plugin_dir="$(mk_cache "$sandbox" mymkt claude-code-handoff 0.16.0 0.17.0)"
must cp "$REPO_ROOT"/bin/*.sh "$plugin_dir/0.17.0/bin/"
sandbox_home="$(mktemp -d)"; cleanup_on_exit "$sandbox_home"
sandbox_project="$(mk_repo)"; cleanup_on_exit "$sandbox_project"
ss_rc=0
( cd "$sandbox_project" \
  && HOME="$sandbox_home" CLAUDE_HOME="$sandbox_home/.claude" \
     CLAUDE_PROJECT_DIR="$sandbox_project" \
     bash "$plugin_dir/0.17.0/bin/handoff_session_start.sh" </dev/null >/dev/null 2>&1 ) || ss_rc=$?
check "case7: session_start from plugin-cache bin -> exit 0" 0 "$ss_rc"
check "case7: stale sibling version pruned via SessionStart" no \
  "$([[ -d "$plugin_dir/0.16.0" ]] && echo yes || echo no)"
check "case7: running (also newest) version kept" yes \
  "$([[ -d "$plugin_dir/0.17.0" ]] && echo yes || echo no)"

# --- 8 (issue #102 F1): newline-named decoy dir with the newest mtime -------
# The old `ls -td ... | head -1` idiom line-splits a directory NAME
# containing a literal newline; against pre-fix code this decoy truncates to
# a phantom version-shaped path that matches no real directory, so nothing
# is protected as "newest" and the genuine newest gets deleted. Against the
# fixed script the decoy cannot even be reached this way (current comes from
# the manifest, not mtime), and its glob-based basename never matches
# $version_re as a WHOLE string (the embedded newline plus trailing text
# fails the anchored regex), so it is never a delete candidate either.
sandbox="$(mktemp -d)"; cleanup_on_exit "$sandbox"
plugin_dir="$(mk_cache "$sandbox" mymkt claude-code-handoff 0.14.1 0.17.0)"
decoy_name=$'0.99.0\nx'
must mkdir -p -- "$plugin_dir/$decoy_name/bin"
must touch -t 202601090000 -- "$plugin_dir/$decoy_name"
run_prune_from "$plugin_dir/0.14.1"; rc=$?
check "case8: exit 0"                          0   "$rc"
check "case8: genuine current 0.17.0 survives" yes \
  "$([[ -d "$plugin_dir/0.17.0" ]] && echo yes || echo no)"
check "case8: running (self) 0.14.1 survives"  yes \
  "$([[ -d "$plugin_dir/0.14.1" ]] && echo yes || echo no)"
check "case8: newline-named decoy itself survives (never a valid candidate)" yes \
  "$([[ -d "$plugin_dir/$decoy_name" ]] && echo yes || echo no)"

# --- 9 (issue #102 F1): version-shaped SYMLINK decoy with the newest target
# mtime. The old newest-pick regex-checked the basename but never checked
# `-L`/`-d`, so a version-shaped symlink with the newest mtime got trusted as
# "newest" against pre-fix code, and the genuine newest (excluded because it
# no longer equals that pointer) got deleted. The fixed script never treats
# mtime as authoritative for "current" at all, and its own newest-scan (kept
# only as diagnostic data) explicitly requires `! -L`.
sandbox="$(mktemp -d)"; cleanup_on_exit "$sandbox"
plugin_dir="$(mk_cache "$sandbox" mymkt claude-code-handoff 0.14.1 0.17.0)"
symlink_target="$(mktemp -d)"; cleanup_on_exit "$symlink_target"
must touch -t 202601090000 "$symlink_target"
must ln -s "$symlink_target" "$plugin_dir/0.99.0"
run_prune_from "$plugin_dir/0.14.1"; rc=$?
check "case9: exit 0"                          0   "$rc"
check "case9: genuine current 0.17.0 survives" yes \
  "$([[ -d "$plugin_dir/0.17.0" ]] && echo yes || echo no)"
check "case9: running (self) 0.14.1 survives"  yes \
  "$([[ -d "$plugin_dir/0.14.1" ]] && echo yes || echo no)"
check "case9: symlink decoy never followed/deleted, still a symlink" yes \
  "$([[ -L "$plugin_dir/0.99.0" ]] && echo yes || echo no)"

# --- 10 (issue #102 F2): a version dir carrying .in_use/<pid> survives -----
# pruning even though it is neither current nor the running script's own
# dir; a stale dir with NO marker alongside it is still pruned, proving the
# marker (not some blanket "prune nothing" regression) is what's protecting
# it. Pre-fix code never looks at .in_use at all, so 0.16.0 is deleted there.
sandbox="$(mktemp -d)"; cleanup_on_exit "$sandbox"
plugin_dir="$(mk_cache "$sandbox" mymkt claude-code-handoff 0.9.0 0.14.1 0.16.0 0.17.0)"
must mkdir -p "$plugin_dir/0.16.0/.in_use"
must touch "$plugin_dir/0.16.0/.in_use/12345"
run_prune_from "$plugin_dir/0.14.1"; rc=$?
check "case10: exit 0"                              0   "$rc"
check "case10: 0.9.0 (stale, no marker) removed"    no  "$([[ -d "$plugin_dir/0.9.0"  ]] && echo yes || echo no)"
check "case10: 0.16.0 (stale, .in_use marker) kept" yes "$([[ -d "$plugin_dir/0.16.0" ]] && echo yes || echo no)"
check "case10: 0.17.0 (current) kept"               yes "$([[ -d "$plugin_dir/0.17.0" ]] && echo yes || echo no)"
check "case10: 0.14.1 (running) kept"                yes "$([[ -d "$plugin_dir/0.14.1" ]] && echo yes || echo no)"

# --- 11 (issue #102 F3): .in_use churn made a STALE dir mtime-newest; the ---
# manifest still names the true current. This is the feature finally working
# as stated: 0.14.1 is touched AFTER 0.17.0 (simulating .in_use churn
# bumping its mtime with no .in_use markers left behind by the time we
# prune), so mtime alone would say 0.14.1 is "current" -- but the manifest
# says 0.17.0 is installed, and this run happens FROM 0.17.0 (mirroring the
# issue's own measured scenario: "pruning from installed 0.17.0"). Pre-fix
# code trusts mtime, so it keeps 0.14.1 (the exact skill-mixing culprit this
# whole feature exists to remove) instead of pruning it.
sandbox="$(mktemp -d)"; cleanup_on_exit "$sandbox"
plugin_dir="$(mk_cache "$sandbox" mymkt claude-code-handoff 0.14.1 0.17.0)"
must touch -t 202601090000 "$plugin_dir/0.14.1"   # churn: now mtime-newest, but NOT current
run_prune_from "$plugin_dir/0.17.0"; rc=$?
check "case11: exit 0"                                     0   "$rc"
check "case11: stale mtime-newest 0.14.1 IS pruned"        no  "$([[ -d "$plugin_dir/0.14.1" ]] && echo yes || echo no)"
check "case11: manifest-installed 0.17.0 (running) survives" yes \
  "$([[ -d "$plugin_dir/0.17.0" ]] && echo yes || echo no)"

# --- 12 (issue #102 F3): current can't be determined -> prune NOTHING ------

# 12a: manifest missing entirely. A stale 0.9.0 sits alongside the
# mtime-newest 0.17.0; pre-fix code needs no manifest at all and prunes
# 0.9.0 regardless, so this is discriminating on its own.
sandbox="$(mktemp -d)"; cleanup_on_exit "$sandbox"
plugin_dir="$sandbox/plugins/cache/mymkt/claude-code-handoff"
must mkdir -p "$plugin_dir/0.9.0/bin" "$plugin_dir/0.17.0/bin"
must touch -t 202601010000 "$plugin_dir/0.9.0"
must touch -t 202601020000 "$plugin_dir/0.17.0"
stderr_file="$(mktemp)"; cleanup_on_exit "$stderr_file"
must mkdir -p "$plugin_dir/0.9.0/bin"
must cp "$PRUNE_SRC" "$plugin_dir/0.9.0/bin/handoff_cache_prune.sh"
rc=0; bash "$plugin_dir/0.9.0/bin/handoff_cache_prune.sh" >/dev/null 2>"$stderr_file" || rc=$?
check "case12a: exit 0 (fail-open, not error)"     0   "$rc"
check "case12a: stale 0.9.0 (running) untouched"   yes "$([[ -d "$plugin_dir/0.9.0"  ]] && echo yes || echo no)"
check "case12a: mtime-newest 0.17.0 ALSO untouched (no manifest to trust)" yes \
  "$([[ -d "$plugin_dir/0.17.0" ]] && echo yes || echo no)"
check "case12a: WARN emitted on stderr when current can't be determined" yes \
  "$(LC_ALL=C grep -q 'WARN' "$stderr_file" && echo yes || echo no)"

# 12b: manifest present but unreadable (mode 000). A genuine stale dir
# (0.14.1, neither newest nor self) sits alongside 0.9.0 (running) and
# 0.17.0 (mtime-newest) so this is discriminating: pre-fix code still
# deletes 0.14.1 on mtime alone, unreadable manifest or not.
sandbox="$(mktemp -d)"; cleanup_on_exit "$sandbox"
plugin_dir="$(mk_cache "$sandbox" mymkt claude-code-handoff 0.9.0 0.14.1 0.17.0)"
must chmod 000 "$sandbox/plugins/installed_plugins.json"
if [[ -r "$sandbox/plugins/installed_plugins.json" ]]; then
  skip "case12b: unreadable-manifest cases (running as a user that ignores chmod 000, e.g. root)"
else
  run_prune_from "$plugin_dir/0.9.0"; rc=$?
  check "case12b: exit 0"                        0   "$rc"
  check "case12b: 0.9.0 (running) untouched"     yes "$([[ -d "$plugin_dir/0.9.0"  ]] && echo yes || echo no)"
  check "case12b: 0.14.1 (stale, would-be-pruned) untouched (manifest unreadable)" yes \
    "$([[ -d "$plugin_dir/0.14.1" ]] && echo yes || echo no)"
  check "case12b: 0.17.0 ALSO untouched (manifest unreadable)" yes \
    "$([[ -d "$plugin_dir/0.17.0" ]] && echo yes || echo no)"
fi
must chmod 700 "$sandbox/plugins/installed_plugins.json"

# 12c: manifest present and readable but AMBIGUOUS -- two scope entries name
# two DIFFERENT versions for this same plugin (a real, legitimate shape: a
# project-scope pin can differ from the user-scope install). Neither is
# authoritative on its own, so nothing is pruned.
sandbox="$(mktemp -d)"; cleanup_on_exit "$sandbox"
plugin_dir="$(mk_cache "$sandbox" mymkt claude-code-handoff 0.9.0 0.16.0 0.17.0)"
must cat > "$sandbox/plugins/installed_plugins.json" <<EOF
{
  "version": 1,
  "plugins": {
    "claude-code-handoff@mymkt": [
      { "scope": "user",    "installPath": "$plugin_dir/0.17.0", "version": "0.17.0" },
      { "scope": "project", "installPath": "$plugin_dir/0.16.0", "version": "0.16.0" }
    ]
  }
}
EOF
run_prune_from "$plugin_dir/0.9.0"; rc=$?
check "case12c: exit 0"                                  0   "$rc"
check "case12c: 0.9.0 (running) untouched"               yes "$([[ -d "$plugin_dir/0.9.0"  ]] && echo yes || echo no)"
check "case12c: 0.16.0 (ambiguous candidate) untouched"  yes "$([[ -d "$plugin_dir/0.16.0" ]] && echo yes || echo no)"
check "case12c: 0.17.0 (ambiguous candidate) untouched"  yes "$([[ -d "$plugin_dir/0.17.0" ]] && echo yes || echo no)"

# --- 13 (issue #102 P2 follow-up): the key text must never anchor an -------
# array slice merely by APPEARING somewhere; it must be the actual "<key>":
# declaration. The real "claude-code-handoff@mymkt" key is ABSENT from this
# manifest; the exact quoted key text appears only as a plain string VALUE
# inside a DIFFERENT plugin's entry, followed later in the file by yet
# another plugin's own internally self-consistent array (real key, version,
# and a matching installPath basename). An unanchored "find the key text
# anywhere, then the first '[' anywhere after it" walks straight past the
# decoy value and lands on that unrelated array, wrongly resolving current
# to its version -- and the installPath/version cross-check cannot catch
# it, because that check only verifies the picked array is internally
# consistent, never that it actually belongs to this key. Anchored on
# "<key><ws>:<ws>[", the real key is correctly absent, so this must resolve
# to prune-nothing.
sandbox="$(mktemp -d)"; cleanup_on_exit "$sandbox"
plugin_dir="$(mk_cache "$sandbox" mymkt claude-code-handoff 0.16.0 0.17.0)"
must mkdir -p "$sandbox/plugins"
must cat > "$sandbox/plugins/installed_plugins.json" <<EOF
{
  "version": 1,
  "plugins": {
    "unrelated-plugin@mymkt": [
      {
        "scope": "user",
        "migratedFrom": "claude-code-handoff@mymkt",
        "installPath": "$sandbox/plugins/cache/mymkt/unrelated-plugin/9.9.9",
        "version": "9.9.9"
      }
    ],
    "some-other-plugin@mymkt": [
      {
        "scope": "user",
        "installPath": "$sandbox/plugins/cache/mymkt/some-other-plugin/0.16.0",
        "version": "0.16.0"
      }
    ]
  }
}
EOF
run_prune_from "$plugin_dir/0.16.0"; rc=$?
check "case13: exit 0"                                        0   "$rc"
check "case13: genuinely current 0.17.0 survives (real key absent -> fail-safe)" yes \
  "$([[ -d "$plugin_dir/0.17.0" ]] && echo yes || echo no)"
check "case13: running dir 0.16.0 survives"                   yes \
  "$([[ -d "$plugin_dir/0.16.0" ]] && echo yes || echo no)"

finish
