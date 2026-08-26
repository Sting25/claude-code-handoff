#!/usr/bin/env bash
# install.sh plugin/script coexistence detection (v0.14.0+ ships a plugin
# form of this tool; plugin hooks and these script-install hooks COEXIST —
# Claude Code fires both, no dedup):
#   A. --doctor: plugin cache present + script hooks wired -> double-fire WARN
#   B. --doctor: plugin cache present, no script hooks -> informational note
#   C. --doctor: no plugin cache -> no plugin mention at all (negative control)
#   D. plain install: plugin cache present -> a heads-up note before "done."
#   F. find_plugin_cache_dir honors CLAUDE_CONFIG_DIR (falls back to
#      $HOME/.claude when unset; a cache under the old default location is
#      NOT found once CLAUDE_CONFIG_DIR points elsewhere — negative control)
#   G-N (issues #64, #70): a GENUINELY plugin-only machine (no bare install
#      ever run, unlike B/D above whose "plugin only" is really a full bare
#      install with one hook marker stripped) used to report the eight
#      bare-scripts as MISSING and exit 1, advising "re-run ./install.sh":
#      the one action that creates the dual-mode state this file's other
#      tests warn about. G-J cover the healthy cases (exit 0, no MISSING
#      lines, no ./install.sh advice); K-N cover the plugin's own real
#      failure modes (a corrupted/partial cache), which SHOULD still exit
#      nonzero, just without ever pointing at ./install.sh.
#
# Plugin installs live under $CLAUDE_CONFIG_DIR/plugins/cache/<marketplace>/
# claude-code-handoff/<version>/, falling back to $HOME/.claude/plugins/cache
# when CLAUDE_CONFIG_DIR is unset — that's Claude Code's OWN env var for
# where it keeps its config/cache, unrelated to this installer's CLAUDE_HOME
# convention (find_plugin_cache_dir never looks under a CLAUDE_HOME
# override — the plugin loader has no concept of it). So unlike most
# install.sh tests, which only sandbox CLAUDE_HOME, tests A-D here sandbox
# HOME too and let CLAUDE_HOME default from it ($HOME/.claude) — never
# touching the real $HOME. Test F additionally sandboxes CLAUDE_CONFIG_DIR.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh plugin/script coexistence detection"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — install.sh settings patching is a no-op without it"
  finish
  exit
fi

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# mk_sandbox: fresh install.sh + bin/skills copy under a throwaway $HOME.
# Echoes "<src_dir> <home_dir>".
mk_sandbox() {
  local src home
  src="$(mktemp -d)"; home="$(mktemp -d)"
  cp "$REPO_ROOT/install.sh" "$src/"
  cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/"
  printf '%s %s\n' "$src" "$home"
}

# A healthy-looking plugin cache: hooks/hooks.json (copied from the repo, so
# it genuinely has all six events) plus stub bin/ scripts for all eight
# names. Needed since #70 added structural checks (hooks.json present and
# parseable, bin/ has all eight scripts) that a bare empty version directory
# would now fail, which would make every test below that just wants a
# plugin present (not specifically testing those structural checks) fail for
# an unrelated reason. See mk_broken_plugin_cache below for the deliberately
# broken fixtures those structural checks are tested against.
mk_plugin_cache() {  # <home_dir>
  local vdir="$1/.claude/plugins/cache/somemkt/claude-code-handoff/0.14.0"
  must mkdir -p "$vdir/bin" "$vdir/hooks"
  must cp "$REPO_ROOT/hooks/hooks.json" "$vdir/hooks/hooks.json"
  local n
  for n in write_handoff handoff_turn_append handoff_ctx_check handoff_session_start handoff_recover_tail handoff_statusline handoff_compact_reset handoff_provenance; do
    must touch "$vdir/bin/$n.sh"
  done
}

# --- A. plugin present + script hooks wired -> double-fire WARN -------------
read -r src home <<<"$(mk_sandbox)"
HOME="$home" bash "$src/install.sh" >/dev/null 2>&1   # wires script hooks first
mk_plugin_cache "$home"
dout="$(HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "both installed: doctor exit 0"             0   "$drc"
check "both installed: double-fire warning"       yes "$(has "$dout" "fires TWICE")"
check "both installed: names plugin uninstall"    yes "$(has "$dout" "/plugin uninstall")"
check "both installed: names --uninstall"         yes "$(has "$dout" "install.sh --uninstall")"
rm -rf "$src" "$home"

# "no script hooks" for the plugin-note check below still means the script's
# OWN hook scripts/settings entries are installed (so doctor's unrelated
# hook-resolution check reports healthy) but with settings.json's
# SessionStart hook stripped back out — that's what "script hooks NOT wired"
# means for the coexistence check (see find_plugin_cache_dir's caller in
# install.sh, which keys off the SessionStart marker).
strip_session_start_hook() {  # <home_dir>
  local s="$1/.claude/settings.json"
  jq 'del(.hooks.SessionStart)' "$s" > "$s.tmp" && mv "$s.tmp" "$s"
}

# --- B. plugin present, no script hooks -> informational note only ---------
read -r src home <<<"$(mk_sandbox)"
HOME="$home" bash "$src/install.sh" >/dev/null 2>&1
strip_session_start_hook "$home"
mk_plugin_cache "$home"
dout="$(HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "plugin only: doctor exit 0"                0   "$drc"
check "plugin only: informational note"           yes "$(has "$dout" "plugin install detected")"
check "plugin only: does not manage plugin note"  yes "$(has "$dout" "does not manage plugin installs")"
check "plugin only: no double-fire warning"       no  "$(has "$dout" "fires TWICE")"
rm -rf "$src" "$home"

# --- C. no plugin cache -> no plugin mention at all (negative control) -----
read -r src home <<<"$(mk_sandbox)"
HOME="$home" bash "$src/install.sh" >/dev/null 2>&1
dout="$(HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "no plugin: doctor exit 0"                  0   "$drc"
check "no plugin: no plugin mention"              no  "$(has "$dout" "plugin install")"
rm -rf "$src" "$home"

# --- D. plain install prints a heads-up when a plugin cache is present -----
read -r src home <<<"$(mk_sandbox)"
mk_plugin_cache "$home"
iout="$(HOME="$home" bash "$src/install.sh" 2>&1)"; irc=$?
check "install: exit 0"                           0   "$irc"
check "install: plugin coexistence note"          yes "$(has "$iout" "plugin install of this tool was detected")"
check "install: double-fire mention"              yes "$(has "$iout" "double-fire")"
check "install: still completes"                  yes "$(has "$iout" "done. start a new Claude Code session")"
rm -rf "$src" "$home"

# --- E. plain install, no plugin cache -> no note (negative control) -------
read -r src home <<<"$(mk_sandbox)"
iout="$(HOME="$home" bash "$src/install.sh" 2>&1)"; irc=$?
check "install no plugin: exit 0"                 0   "$irc"
check "install no plugin: no plugin note"         no  "$(has "$iout" "plugin install")"
rm -rf "$src" "$home"

# --- F. find_plugin_cache_dir honors CLAUDE_CONFIG_DIR -----------------------
# CLAUDE_CONFIG_DIR is Claude Code's OWN env var for where it keeps its
# config/cache (unrelated to this installer's CLAUDE_HOME convention); the
# real plugin cache moves with it. mk_plugin_cache_at takes the CONFIG dir
# itself (no "/.claude" suffix — that suffix is only the $HOME fallback's).
mk_plugin_cache_at() {  # <config_dir>
  local vdir="$1/plugins/cache/somemkt/claude-code-handoff/0.14.0"
  must mkdir -p "$vdir/bin" "$vdir/hooks"
  must cp "$REPO_ROOT/hooks/hooks.json" "$vdir/hooks/hooks.json"
  local n
  for n in write_handoff handoff_turn_append handoff_ctx_check handoff_session_start handoff_recover_tail handoff_statusline handoff_compact_reset handoff_provenance; do
    must touch "$vdir/bin/$n.sh"
  done
}

# F1: cache under a CLAUDE_CONFIG_DIR override (nowhere near $HOME) -> found.
read -r src home <<<"$(mk_sandbox)"
cfg="$(mktemp -d)"
HOME="$home" bash "$src/install.sh" >/dev/null 2>&1
mk_plugin_cache_at "$cfg"
dout="$(HOME="$home" CLAUDE_CONFIG_DIR="$cfg" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "CLAUDE_CONFIG_DIR cache: doctor exit 0"        0   "$drc"
check "CLAUDE_CONFIG_DIR cache: plugin detected"      yes "$(has "$dout" "plugin install detected ($cfg/plugins/cache/somemkt/claude-code-handoff)")"
rm -rf "$src" "$home" "$cfg"

# F2: a cache at the OLD default ($HOME/.claude) is NOT found once
# CLAUDE_CONFIG_DIR points elsewhere — proves the override wins outright
# rather than the doctor checking both locations.
read -r src home <<<"$(mk_sandbox)"
cfg="$(mktemp -d)"
HOME="$home" bash "$src/install.sh" >/dev/null 2>&1
mk_plugin_cache "$home"
dout="$(HOME="$home" CLAUDE_CONFIG_DIR="$cfg" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "CLAUDE_CONFIG_DIR set, old-location cache: doctor exit 0" 0  "$drc"
check "CLAUDE_CONFIG_DIR set, old-location cache: not detected"  no "$(has "$dout" "plugin install")"
rm -rf "$src" "$home" "$cfg"

# --- G. genuinely plugin-only: doctor healthy, exit 0, no phantom MISSING ---
# (issue #64's exact repro: a plugin cache with NO ./install.sh ever run,
# no bin/ scripts, no settings.json hooks at all, not even one stripped.)
read -r src home <<<"$(mk_sandbox)"
mk_plugin_cache "$home"
dout="$(HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "genuine plugin-only: doctor exit 0"        0   "$drc"
check "genuine plugin-only: no MISSING lines"     no  "$(has "$dout" "MISSING")"
check "genuine plugin-only: skip-loop note"       yes "$(has "$dout" "no bare-scripts install found")"
check "genuine plugin-only: plugin hooks.json ok" yes "$(has "$dout" "has all six hook events")"
check "genuine plugin-only: plugin bin ok"        yes "$(has "$dout" "has all eight scripts")"
check "genuine plugin-only: no ./install.sh advice" no "$(has "$dout" "Re-run ./install.sh")"
rm -rf "$src" "$home"

# --- H. genuinely plugin-only + jq missing: BROKEN, but never blames ./install.sh
nojq="$(path_without jq)"
read -r src home <<<"$(mk_sandbox)"
mk_plugin_cache "$home"
dout="$(PATH="$nojq" HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "plugin-only, no jq: nonzero exit"          nonzero "$([[ $drc -ne 0 ]] && echo nonzero || echo zero)"
check "plugin-only, no jq: reports jq BROKEN"     yes "$(has "$dout" "jq not found")"
check "plugin-only, no jq: no MISSING lines"      no  "$(has "$dout" "MISSING")"
check "plugin-only, no jq: names /plugin reinstall" yes "$(has "$dout" "/plugin install claude-code-handoff")"
check "plugin-only, no jq: no ./install.sh advice"  no "$(has "$dout" "Re-run ./install.sh")"
rm -rf "$src" "$home"

# --- I. genuinely plugin-only, statusLine unset -> optional info, not broken
read -r src home <<<"$(mk_sandbox)"
mk_plugin_cache "$home"
dout="$(HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "plugin-only statusLine unset: exit 0"      0   "$drc"
check "plugin-only statusLine unset: info, optional" yes "$(has "$dout" "statusLine unset (optional")"
rm -rf "$src" "$home"

# --- J. genuinely plugin-only, statusLine wired to the PLUGIN's own script --
read -r src home <<<"$(mk_sandbox)"
mk_plugin_cache "$home"
vdir="$home/.claude/plugins/cache/somemkt/claude-code-handoff/0.14.0"
must mkdir -p "$home/.claude"
must cat > "$home/.claude/settings.json" <<EOF
{"statusLine": {"type": "command", "command": "bash \"$vdir/bin/handoff_statusline.sh\""}}
EOF
dout="$(HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "plugin statusLine wired: exit 0"           0   "$drc"
check "plugin statusLine wired: ok (ours, plugin)" yes "$(has "$dout" "statusLine wired (ours, plugin)")"
rm -rf "$src" "$home"

# --- K. broken plugin cache: hooks.json missing -> BROKEN, exit nonzero -----
read -r src home <<<"$(mk_sandbox)"
vdir="$home/.claude/plugins/cache/somemkt/claude-code-handoff/0.14.0"
must mkdir -p "$vdir/bin"
for n in write_handoff handoff_turn_append handoff_ctx_check handoff_session_start handoff_recover_tail handoff_statusline handoff_compact_reset handoff_provenance; do
  must touch "$vdir/bin/$n.sh"
done
dout="$(HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "broken cache, no hooks.json: nonzero exit" nonzero "$([[ $drc -ne 0 ]] && echo nonzero || echo zero)"
check "broken cache, no hooks.json: BROKEN line"  yes "$(has "$dout" "BROKEN  $vdir/hooks/hooks.json missing")"
check "broken cache, no hooks.json: no ./install.sh advice" no "$(has "$dout" "Re-run ./install.sh")"
rm -rf "$src" "$home"

# --- L. broken plugin cache: a bin/ script missing -> BROKEN, exit nonzero --
read -r src home <<<"$(mk_sandbox)"
vdir="$home/.claude/plugins/cache/somemkt/claude-code-handoff/0.14.0"
must mkdir -p "$vdir/bin" "$vdir/hooks"
must cp "$REPO_ROOT/hooks/hooks.json" "$vdir/hooks/hooks.json"
for n in write_handoff handoff_turn_append handoff_ctx_check handoff_session_start handoff_recover_tail handoff_compact_reset handoff_provenance; do
  must touch "$vdir/bin/$n.sh"
done   # handoff_statusline.sh deliberately omitted
dout="$(HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "broken cache, missing bin script: nonzero exit" nonzero "$([[ $drc -ne 0 ]] && echo nonzero || echo zero)"
check "broken cache, missing bin script: BROKEN line"  yes \
  "$(has "$dout" "BROKEN  $vdir/bin is missing: handoff_statusline.sh")"
rm -rf "$src" "$home"

# --- M. broken plugin cache: hooks.json missing an event -> BROKEN ----------
read -r src home <<<"$(mk_sandbox)"
vdir="$home/.claude/plugins/cache/somemkt/claude-code-handoff/0.14.0"
must mkdir -p "$vdir/bin" "$vdir/hooks"
must jq 'del(.hooks.Stop)' "$REPO_ROOT/hooks/hooks.json" > "$vdir/hooks/hooks.json"
for n in write_handoff handoff_turn_append handoff_ctx_check handoff_session_start handoff_recover_tail handoff_statusline handoff_compact_reset handoff_provenance; do
  must touch "$vdir/bin/$n.sh"
done
dout="$(HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "broken cache, missing event: nonzero exit" nonzero "$([[ $drc -ne 0 ]] && echo nonzero || echo zero)"
check "broken cache, missing event: BROKEN line"  yes "$(has "$dout" "missing hook event(s)")"
rm -rf "$src" "$home"

# --- N. dual mode still runs the plugin structural checks too ---------------
# (issue #70's "both -> today's dual-mode WARN, plus both check sets")
read -r src home <<<"$(mk_sandbox)"
HOME="$home" bash "$src/install.sh" >/dev/null 2>&1
mk_plugin_cache "$home"
dout="$(HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "dual mode: doctor exit 0"                  0   "$drc"
check "dual mode: still runs bare-script loop"    yes "$(has "$dout" "checking installed handoff hooks under")"
check "dual mode: still runs plugin checks"       yes "$(has "$dout" "checking plugin cache at")"
check "dual mode: plugin hooks.json ok"           yes "$(has "$dout" "has all six hook events")"
rm -rf "$src" "$home"

# --- O. F1 regression: plugin dir with NO version subdirectory at all -------
# (a bare `mkdir -p .../claude-code-handoff` with nothing inside, unlike K-M
# above which all have at least a version dir). Before the fix, `ls -td
# .../*/ | head -1` failed under set -e when the glob matched nothing, and
# that failure inside a bare assignment killed doctor before the intended
# "no version subdirectory" BROKEN line ever printed: measured RC=1 with NO
# output at all beforehand. The fix is `|| true` on that substitution; this
# pins that the BROKEN line prints and RC stays 1 (for the right reason: the
# empty cache is genuinely broken, not a crash).
read -r src home <<<"$(mk_sandbox)"
must mkdir -p "$home/.claude/plugins/cache/somemkt/claude-code-handoff"
dout="$(HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "F1 empty plugin dir: nonzero exit" nonzero "$([[ $drc -ne 0 ]] && echo nonzero || echo zero)"
check "F1 empty plugin dir: BROKEN, no version subdir" yes \
  "$(has "$dout" "has no version subdirectory")"
rm -rf "$src" "$home"

# --- P. F2 regression: hooks.json is valid JSON but has no "hooks" key ------
# ({}  parses fine, so it reaches the events check; `.hooks` on {} is null,
# and `keys` on null used to be a jq runtime error (exit 5) that killed
# doctor under set -e before the missing-events BROKEN line ever printed.
# The fix is `.hooks // {}` plus `|| true` on the substitution; this pins
# that the BROKEN line prints (all six events reported missing) and RC
# stays 1, for the right reason.
read -r src home <<<"$(mk_sandbox)"
vdir="$home/.claude/plugins/cache/somemkt/claude-code-handoff/0.14.0"
must mkdir -p "$vdir/bin" "$vdir/hooks"
must bash -c "printf '%s' '{}' > '$vdir/hooks/hooks.json'"
for n in write_handoff handoff_turn_append handoff_ctx_check handoff_session_start handoff_recover_tail handoff_statusline handoff_compact_reset handoff_provenance; do
  must touch "$vdir/bin/$n.sh"
done
dout="$(HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "F2 hooks.json {}: nonzero exit" nonzero "$([[ $drc -ne 0 ]] && echo nonzero || echo zero)"
check "F2 hooks.json {}: BROKEN, missing hook events" yes \
  "$(has "$dout" "missing hook event(s)")"
rm -rf "$src" "$home"

# --- Q. F3 regression: hooks.json has all six PLUS an extra event ----------
# Exact-string equality used to report this as "missing hook event(s)" even
# though nothing is actually missing, just because the sorted comma-joined
# list no longer matched the expected string verbatim once a 7th name (e.g.
# a future Claude Code hook) was added. Now a subset check: all six present
# is healthy (RC 0), extras get a harmless note, not BROKEN.
read -r src home <<<"$(mk_sandbox)"
vdir="$home/.claude/plugins/cache/somemkt/claude-code-handoff/0.14.0"
must mkdir -p "$vdir/bin" "$vdir/hooks"
must jq '.hooks.Notification = [{"hooks":[{"type":"command","command":"echo hi"}]}]' \
  "$REPO_ROOT/hooks/hooks.json" > "$vdir/hooks/hooks.json"
for n in write_handoff handoff_turn_append handoff_ctx_check handoff_session_start handoff_recover_tail handoff_statusline handoff_compact_reset handoff_provenance; do
  must touch "$vdir/bin/$n.sh"
done
dout="$(HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "F3 extra event: exit 0"                  0   "$drc"
check "F3 extra event: still all six ok"        yes "$(has "$dout" "has all six hook events")"
check "F3 extra event: not reported as missing" no  "$(has "$dout" "missing hook event(s)")"
check "F3 extra event: harmless-extra note"     yes "$(has "$dout" "extra hook event(s), harmless: Notification")"
rm -rf "$src" "$home"

# --- R. F4 regression: plugin-only machine with ONE dangling bin/ leftover --
# A single stale dangling symlink under $claude_home/bin (e.g. left behind by
# a hand-removed bare-scripts install, never through --uninstall) used to be
# enough to flip the old bare_present check true and drag this genuinely
# plugin-only machine into the eight-script loop, reporting the other seven
# as MISSING and restoring issue #64's exact bug. Now: a lone dangling
# symlink does not count as a wired bare-scripts install (bare_wired only
# counts a script that actually resolves, or a settings.json hook), so the
# machine stays in plugin-only mode; the dangling path is instead named in
# one WARN, not fed through the per-script loop.
read -r src home <<<"$(mk_sandbox)"
mk_plugin_cache "$home"
must mkdir -p "$home/.claude/bin"
must ln -s "/nonexistent/write_handoff.sh" "$home/.claude/bin/write_handoff.sh"
dout="$(HOME="$home" bash "$src/install.sh" --doctor 2>&1)"; drc=$?
check "F4 dangling-only leftover: exit 0"       0   "$drc"
check "F4 dangling-only leftover: no MISSING"   no  "$(has "$dout" "MISSING")"
check "F4 dangling-only leftover: still plugin-only" yes \
  "$(has "$dout" "no bare-scripts install found")"
check "F4 dangling-only leftover: WARN names stale artifact" yes \
  "$(has "$dout" "stale bare-scripts artifact")"
check "F4 dangling-only leftover: WARN names the path" yes \
  "$(has "$dout" "$home/.claude/bin/write_handoff.sh")"
rm -rf "$src" "$home"

finish
