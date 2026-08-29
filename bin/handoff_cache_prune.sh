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
#   3. CURRENT is resolved from installed_plugins.json (issue #102's F3),
#      never from mtime: the manifest's ".plugins[\"<plugin>@<marketplace>\"]"
#      array is the CLI's own record of what is actually installed, and an
#      old cached version dir's mtime can be NEWER than the real current
#      version simply because the CLI stamps .in_use/<pid> markers inside a
#      version dir on every use, touching its mtime with no relationship to
#      which version is installed (measured: churn made a stale dir
#      mtime-newest while the manifest still correctly named an older,
#      still-installed version as current). If the manifest is missing,
#      unreadable, or does not name this plugin unambiguously (not found,
#      named twice, or naming two DIFFERENT versions, e.g. a per-project
#      install pinned older than the user-scope install), current is
#      UNKNOWN and nothing is pruned this run. mtime is never used to guess
#      it, only (see the F1 scan below) to name a candidate in the
#      diagnostic emitted when we back off this way.
#   4. Each CANDIDATE for deletion also has to look like a version
#      directory: matches the same X.Y.Z shape, a real directory, never a
#      symlink, the same "only delete what we can prove is ours" discipline
#      as handoff_turn_append.sh's dump prune and handoff_session_start.sh's
#      own orphan-marker sweep.
#   5. A candidate carrying anything under its own .in_use/ subdirectory is
#      skipped outright (issue #102's F2): the CLI stamps .in_use/<pid> in a
#      version dir for as long as some session is resolving that version,
#      and a session mid-flight on an older cached version when a newer one
#      lands must not have its tree deleted out from under it. PROPOSED but
#      NOT implemented here: refine to delete a marked dir once every
#      recorded pid in .in_use/ is confirmed dead via `kill -0`, rather than
#      skipping on ANY marker regardless of liveness. The safe default kept
#      here is keep-on-any-marker: a dead pid's leftover marker only costs
#      disk, while a live pid's deleted tree breaks that session outright,
#      and a liveness check can itself be wrong (pid reuse, a permission
#      error from `kill -0` reading as "dead" on some platforms) in a
#      fail-open hook that would rather under-prune than over-delete.
#
# Keeps: the manifest-current version dir (safety model #3) AND the version
# dir this running script itself lives in (normally the same dir; if a
# session is mid-flight on an OLDER cached version when a newer one lands,
# this keeps that live session's own directory from being deleted out from
# under it, the one real harm to avoid here) AND any candidate carrying an
# .in_use marker (safety model #5). Every other version-shaped sibling under
# the plugin's cache parent is removed.
#
# Concurrency: two sessions can fire this at once (two Claude Code windows
# starting together). `rm -rf` on a directory another instance already
# removed is not an error here: `-f` swallows the already-gone case, and
# the whole delete is additionally wrapped in `|| true`, the same fail-open
# posture as every other maintenance sweep in this project.
#
# Fail-open posture, and the one WARN line (issue #102's Low observation): a
# maintenance sweep that fails closed with zero signal, forever, is itself a
# failure mode worth a line for, even though handoff_session_start.sh's own
# invocation of this script (`bash ... 2>/dev/null || true`) discards that
# stderr today and is intentionally left unchanged here (session start must
# never break on this, and per-session stderr noise would defeat the
# `2>/dev/null`). The WARN below is for a direct run or a future consumer of
# this script's own stderr (a --doctor check, say), not for the hook.
set -euo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || self_dir=""
[[ -n "$self_dir" ]] || exit 0

version_dir="$(dirname -- "$self_dir")"
plugin_dir="$(dirname -- "$version_dir")"
marketplace_dir="$(dirname -- "$plugin_dir")"
cache_dir="$(dirname -- "$marketplace_dir")"
plugins_dir="$(dirname -- "$cache_dir")"

# X.Y.Z only, matching every tag v0.1.0..v0.18.0 this repo has cut. A
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

# --- F1: NUL-safe, decoy-proof mtime-newest scan ----------------------------
# Diagnostic use ONLY (safety model #3): this never decides what is kept or
# deleted. It exists so (a) the mechanism itself, not just its old role, is
# proven safe, and (b) the "current could not be determined" WARN below can
# name a candidate. The quoted glob (matching the candidate loop's own idiom
# further down) hands each directory entry to the loop as one atomic argv
# word regardless of embedded characters, unlike the old `ls -td ... | head
# -1`, which is line-oriented: a directory NAME containing a literal newline
# gets split across `ls`'s output lines, and `head -1` can hand back a
# truncated, version-shaped path that never existed on disk (issue #102 F1,
# measured: a "0.99.0<newline>x" decoy truncated to a phantom "0.99.0" that
# then matched no real directory, so the real newest was never protected).
# `-nt` is a bash builtin mtime comparison, no external `stat`/`ls` parsing
# involved. Every candidate must be a real, existing, non-symlink directory
# whose FULL basename matches $version_re before it is even compared, so a
# version-shaped symlink whose target has the newest mtime is never trusted
# either (the old code's newest-pick checked the regex but not `-d`/`! -L`).
newest_version_dir=""
for cand in "$plugin_dir"/*/; do
  [[ -d "$cand" ]] || continue
  cand="${cand%/}"
  [[ -L "$cand" ]] && continue
  cand_base="$(basename -- "$cand")"
  [[ "$cand_base" =~ $version_re ]] || continue
  if [[ -z "$newest_version_dir" ]] || [[ "$cand" -nt "$newest_version_dir" ]]; then
    newest_version_dir="$cand"
  fi
done

# --- F2 helper: does a candidate carry a live-session marker? ---------------
# `.in_use/<pid>` holds one entry per session using this version (see safety
# model #5). Existence of ANY entry is enough to skip the dir outright;
# entry contents/names are never inspected further (keep-on-any-marker is
# the safe default, see header for the liveness-refinement alternative
# considered and deliberately not taken here).
has_in_use_marker() {
  local vdir="$1" entry
  [[ -d "$vdir/.in_use" ]] || return 1
  for entry in "$vdir/.in_use"/*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    return 0
  done
  return 1
}

# --- F3: resolve CURRENT from installed_plugins.json, never from mtime -----
# Schema (measured against a real ~/.claude/plugins/installed_plugins.json,
# 2026-08): a top-level "plugins" object keyed "<plugin>@<marketplace>",
# each value an array of per-scope entries carrying at least "version" and
# "installPath" per scope. jq-free by design, mirroring
# bin/handoff_turn_append.sh's own no-jq sed-extraction fallback (issue
# #68's precedent): a maintenance sweep this small should not gain a hard
# jq dependency the rest of the script doesn't already have, and jq's
# absence is a supported, tested state elsewhere in this project.
#
# Literal (non-regex) matching throughout: $plugin_name and $marketplace_name
# are directory basenames this script does not control the contents of, so
# building them into an ERE would let an unusual marketplace directory name
# inject regex metacharacters into the match. `grep -F` and awk's `index()`
# are both plain substring search, never pattern interpretation, so no
# escaping is needed and none can be missed. The two hardcoded field names
# ("version", "installPath") ARE matched with an ERE below; that is safe
# because they are literal constants this script wrote, not derived from
# any path on disk.
resolve_current_version() {
  local manifest="$1" plugin_name="$2" marketplace_name="$3"
  local key="${plugin_name}@${marketplace_name}"
  [[ -n "$marketplace_name" ]] || return 1
  [[ -f "$manifest" && ! -L "$manifest" && -r "$manifest" ]] || return 1

  local content
  content="$(cat -- "$manifest" 2>/dev/null)" || return 1
  [[ -n "$content" ]] || return 1
  # Collapse to one line so a pretty-printed manifest's key and array are
  # not split across lines the extraction below would have to stitch back
  # together.
  local flat
  flat="$(printf '%s' "$content" | LC_ALL=C tr '\n' ' ')"

  # Anchored match required: the key must be immediately followed (after
  # optional whitespace) by ":" and then, after optional whitespace, by
  # "[" -- a bare occurrence of the key text as some OTHER field's STRING
  # VALUE (not a genuine "<key>": [ ... ] declaration) must never count
  # toward the ambiguity check and must never be used to locate an array.
  # An earlier version of this fix counted any occurrence of the quoted key
  # ANYWHERE in the file and then hopped to the first "[" anywhere after
  # it; that let a decoy occurrence of the key text used as some OTHER
  # entry's plain string value walk clean past itself and land on a
  # different, unrelated plugin's array (measured: the real key absent, the
  # exact key text present only as a foreign entry's string value, followed
  # by a different plugin's internally self-consistent array; the
  # installPath/version cross-check further below cannot catch this either,
  # since it only verifies INTERNAL consistency of whatever array was
  # picked, not that the array actually belongs to this key). Anchoring on
  # "<key><ws>:<ws>[" closes that: the decoy is never followed by ":" so it
  # is never even a candidate.
  local awk_out anchored_count array_body
  awk_out="$(LC_ALL=C awk -v k="\"$key\"" '
    function skip_ws(s, i,    n) {
      n = length(s)
      while (i <= n) {
        c = substr(s, i, 1)
        if (c != " " && c != "\t") break
        i++
      }
      return i
    }
    {
      s = $0
      n = length(s)
      start = 1
      count = 0
      body = ""
      while (1) {
        p = index(substr(s, start), k)
        if (p == 0) break
        pos = start + p - 1
        i = skip_ws(s, pos + length(k))
        if (i <= n && substr(s, i, 1) == ":") {
          i = skip_ws(s, i + 1)
          if (i <= n && substr(s, i, 1) == "[") {
            count++
            bstart = i + 1
            e = index(substr(s, bstart), "]")
            if (e > 0) body = substr(s, bstart, e - 1)
          }
        }
        start = pos + 1
      }
      print count
      print body
    }
  ' <<<"$flat")"
  anchored_count="$(printf '%s\n' "$awk_out" | sed -n '1p')"
  array_body="$(printf '%s\n' "$awk_out" | sed -n '2p')"
  [[ "$anchored_count" =~ ^[0-9]+$ ]] || return 1
  [[ "$anchored_count" -eq 1 ]] || return 1
  [[ -n "$array_body" ]] || return 1

  local versions install_paths
  versions="$(printf '%s' "$array_body" \
    | LC_ALL=C grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | LC_ALL=C sed -E 's/.*"([^"]*)"$/\1/' || true)"
  install_paths="$(printf '%s' "$array_body" \
    | LC_ALL=C grep -oE '"installPath"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | LC_ALL=C sed -E 's/.*"([^"]*)"$/\1/' || true)"
  [[ -n "$versions" ]] || return 1

  # Every scope entry must agree on ONE version. Two scopes can legitimately
  # install different versions (e.g. a project pin older than the
  # user-scope install); that is exactly the "not unambiguous" case safety
  # model #3 backs off on, not a tie for mtime to break.
  local uniq_versions uniq_count
  uniq_versions="$(printf '%s\n' "$versions" | sort -u)"
  uniq_count="$(printf '%s\n' "$uniq_versions" | LC_ALL=C grep -c . || true)"
  [[ "$uniq_count" =~ ^[0-9]+$ ]] || return 1
  [[ "$uniq_count" -eq 1 ]] || return 1

  local resolved
  read -r resolved <<<"$uniq_versions"
  [[ "$resolved" =~ $version_re ]] || return 1

  # Cross-check: every installPath's basename must agree with the version
  # field. A manifest whose own fields disagree with each other is corrupt,
  # not authoritative.
  local ip
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    [[ "$(basename -- "$ip")" = "$resolved" ]] || return 1
  done <<<"$install_paths"

  printf '%s' "$resolved"
}

plugin_name="$(basename -- "$plugin_dir")"
marketplace_name="$(basename -- "$marketplace_dir")"
manifest="$plugins_dir/installed_plugins.json"
current_version=""
if resolved_version="$(resolve_current_version "$manifest" "$plugin_name" "$marketplace_name")"; then
  current_dir="$plugin_dir/$resolved_version"
  if [[ -d "$current_dir" && ! -L "$current_dir" ]]; then
    current_base="$(basename -- "$current_dir")"
    if [[ "$current_base" =~ $version_re && "$current_base" = "$resolved_version" ]]; then
      current_version="$resolved_version"
    fi
  fi
fi

if [[ -z "$current_version" ]]; then
  hint="$newest_version_dir"
  [[ -n "$hint" ]] || hint="(no version-shaped candidate found either)"
  echo "handoff_cache_prune.sh: WARN: could not determine the current installed version from $manifest; pruning nothing this run. mtime-newest candidate seen: $hint (not used to decide anything)." >&2
  exit 0
fi

# --- Delete every OTHER version-shaped sibling ------------------------------
# (safety model #4) Never current, never the one this running script lives
# in, never one carrying an .in_use marker (safety model #5).
for vdir in "$plugin_dir"/*/; do
  [[ -d "$vdir" ]] || continue
  vdir="${vdir%/}"
  [[ -L "$vdir" ]] && continue
  vbase="$(basename -- "$vdir")"
  [[ "$vbase" =~ $version_re ]] || continue
  [[ "$vbase" = "$current_version" ]] && continue
  [[ "$vdir" = "$version_dir" ]] && continue
  if has_in_use_marker "$vdir"; then
    continue
  fi
  rm -rf -- "$vdir" 2>/dev/null || true
done

exit 0
