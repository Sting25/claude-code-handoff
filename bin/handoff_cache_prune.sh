#!/usr/bin/env bash
# handoff_cache_prune.sh: self-prune stale cached versions of THIS plugin.
#
# The problem (real incident, 2026-08-28): Claude Code's plugin updater
# leaves every old cached version of a plugin sitting under
# .../plugins/cache/<marketplace>/claude-code-handoff/<version>/ forever,
# because nothing in the CLI itself ever removes a version once a newer one
# is installed. A stale cache entry is not just wasted disk: install.d's own
# doctor check and the skills' cache-fallback loop each independently pick
# "the" cached version by newest mtime (see
# install.d/30-settings-unpatch-doctor.sh's find_plugin_cache_dir /
# newest-vdir logic, and ad203db's skill fix), so a session can end up
# loading this plugin's SKILL from an OLD cached version while its hook
# scripts resolve a NEWER one, mixing two versions inside one session.
# Observed on this machine with 0.14.1, 0.16.0, and 0.17.0 all cached at
# once, a session loading the 0.14.1 skill while 0.17.0 was the version
# actually installed. There is no `claude` CLI command that prunes this.
#
# Called (best-effort, `|| true`) from handoff_session_start.sh, the one
# hook this project has already established fires on every session,
# including the "still fires when every other hook is dead" case
# (issues #67/#71's detector B). A standalone script rather than an inline
# block: it needs its own `set -euo pipefail` and must never be able to
# change the calling hook's shell options if something here goes sideways,
# the same reasoning handoff_provenance.sh's header gives for staying
# SOURCED-only, mirrored here for the opposite choice. The extra fork is
# the same cost every other bin/*.sh already pays when hooks.json invokes
# it directly.
#
# Safety model: every one of these must hold before ANYTHING is deleted;
# anything unexpected is a silent no-op, never a guess.
#   1. This script's own resolved path matches the plugin-cache shape
#      EXACTLY: .../plugins/cache/<marketplace>/claude-code-handoff/<version>/bin,
#      both "plugins" and "cache" segments present at the right depth, and
#      the plugin segment is literally this plugin's own name, never a
#      pattern that could match a sibling plugin's cache.
#   2. The running script's own version directory name looks like a
#      version (X.Y.Z, matching every tag this repo has ever cut).
#   3. Each CANDIDATE for deletion also has to look like a version
#      directory: matches the same X.Y.Z shape, a real directory, never a
#      symlink, the same "only delete what we can prove is ours"
#      discipline as handoff_turn_append.sh's dump prune and
#      handoff_session_start.sh's own orphan-marker sweep.
#
# Keeps: the newest-by-mtime version dir, the same `ls -td .../*/ | head -1`
# idiom install.d/30-settings-unpatch-doctor.sh already uses to pick the
# plugin's active cache dir, reused rather than reinvented (NOT lexical:
# 0.9.0 sorts after 0.14.0, exactly the digit-count-boundary bug ad203db
# fixed for the skills' own cache-fallback loop), AND the version dir this
# running script itself lives in (normally the same dir; if a session is
# mid-flight on an OLDER cached version when a newer one lands, this keeps
# that live session's own directory from being deleted out from under it,
# the one real harm to avoid here). Every other version-shaped sibling
# under the plugin's cache parent is removed.
#
# Concurrency: two sessions can fire this at once (two Claude Code windows
# starting together). `rm -rf` on a directory another instance already
# removed is not an error here: `-f` swallows the already-gone case, and
# the whole delete is additionally wrapped in `|| true`, the same fail-open
# posture as every other maintenance sweep in this project.
set -euo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || self_dir=""
[[ -n "$self_dir" ]] || exit 0

version_dir="$(dirname -- "$self_dir")"
plugin_dir="$(dirname -- "$version_dir")"
marketplace_dir="$(dirname -- "$plugin_dir")"
cache_dir="$(dirname -- "$marketplace_dir")"
plugins_dir="$(dirname -- "$cache_dir")"

# X.Y.Z only, matching every tag v0.1.0..v0.17.0 this repo has cut. A
# version dir named anything else (a future pre-release suffix, hand-edited
# cache litter) fails this and the whole script backs off rather than guess.
version_re='^[0-9]+\.[0-9]+\.[0-9]+$'

# --- Shape guard (see header safety model #1-2) -----------------------------
[[ "$(basename -- "$self_dir")" = "bin" ]] || exit 0
[[ "$(basename -- "$plugin_dir")" = "claude-code-handoff" ]] || exit 0
[[ "$(basename -- "$cache_dir")" = "cache" ]] || exit 0
[[ "$(basename -- "$plugins_dir")" = "plugins" ]] || exit 0
this_version="$(basename -- "$version_dir")"
[[ "$this_version" =~ $version_re ]] || exit 0
# Refuse to walk a symlinked plugin dir, same posture as
# handoff_session_start.sh's `.claude`/backup-dir symlink guards elsewhere
# in this project: a symlink here means the resolved layout is not what it
# claims to be, so treat it as unexpected shape rather than follow it.
[[ -d "$plugin_dir" && ! -L "$plugin_dir" ]] || exit 0

# --- Newest-by-mtime version dir --------------------------------------------
# shellcheck disable=SC2012  # ls -t is deliberate: mtime ordering, matching install.d/30-settings-unpatch-doctor.sh's own plugin-cache "pick newest" idiom
newest_dir="$(ls -td "$plugin_dir"/*/ 2>/dev/null | head -1 || true)"
newest_dir="${newest_dir%/}"
newest_base=""
[[ -n "$newest_dir" ]] && newest_base="$(basename -- "$newest_dir")"
# The newest-mtime pick itself has to look like a version dir too. If it
# doesn't, the layout is not what this script expects, so back off entirely
# rather than delete against an unproven "newest".
[[ -n "$newest_dir" && "$newest_base" =~ $version_re ]] || exit 0

# --- Delete every OTHER version-shaped sibling ------------------------------
# (safety model #3) Never the newest, never the one this running script
# lives in.
for vdir in "$plugin_dir"/*/; do
  [[ -d "$vdir" ]] || continue
  vdir="${vdir%/}"
  [[ -L "$vdir" ]] && continue
  vbase="$(basename -- "$vdir")"
  [[ "$vbase" =~ $version_re ]] || continue
  [[ "$vdir" = "$newest_dir" ]] && continue
  [[ "$vdir" = "$version_dir" ]] && continue
  rm -rf -- "$vdir" 2>/dev/null || true
done

exit 0
