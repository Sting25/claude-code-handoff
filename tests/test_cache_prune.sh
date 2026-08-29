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
# newest). Echoes the plugin dir path.
mk_cache() {
  local root="$1" mkt="$2" plugin="$3"; shift 3
  local plugin_dir="$root/plugins/cache/$mkt/$plugin"
  local i=0 v vdir stamp
  for v in "$@"; do
    vdir="$plugin_dir/$v"
    must mkdir -p "$vdir/bin"
    i=$((i + 1))
    # 2026-01-0<i> 00:00, so later args land later in time.
    stamp="$(printf '202601%02d0000' "$i")"
    must touch -t "$stamp" "$vdir"
  done
  printf '%s\n' "$plugin_dir"
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

finish
