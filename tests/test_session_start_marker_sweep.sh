#!/usr/bin/env bash
# Behavioral coverage for handoff_session_start.sh's orphaned dead-Stop-hook
# marker sweep (issue #76).
#
# handoff_turn_append.sh's (the Stop hook's) own prune loop only reaps
# .ctx_nojq_<id>, .ctx_prompts_<id>, .ctx_health_<id>, and .ss_health_<id> as
# a side effect of rotating a handoff_raw_<id>.md dump out of its keep-3
# window. A session whose Stop hook never ran (issue #68, #71's failure
# shapes) writes no such dump, so those four markers are never keyed for that
# eviction and leak forever. SessionStart is jq-free and, per detector B a
# little further down in that same script, is the one hook confirmed to
# still fire even when both per-turn hooks are dead — so it hosts an
# age-based sweep instead (mirroring handoff_statusline.sh's own .ctx_sl_
# janitor, which has the identical orphan shape).
#
# Observable: which files under .claude/handoff_backups/ survive a
# handoff_session_start.sh invocation.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SS="$REPO_ROOT/bin/handoff_session_start.sh"

# Run the hook against a project dir, discarding stdout (this suite only
# cares about the filesystem side effect here). Extra args are env=val.
run_ss() {  # <project_dir> [ENV=VAL ...]
  local dir="$1"; shift
  ( cd "$dir" && env CLAUDE_PROJECT_DIR="$dir" "$@" bash "$SS" </dev/null >/dev/null 2>&1 )
}

mk_project() {  # echoes a fresh project dir with a .claude/handoff_backups/
  local d; d="$(mktemp -d)"; mkdir -p "$d/.claude/handoff_backups"; printf '%s\n' "$d"
}

echo "handoff_session_start.sh — orphaned dead-Stop-hook marker sweep (#76)"

# --- Orphaned markers >7d old, all four kinds, all provably ours -> reaped --
proj="$(mk_project)"; bd="$proj/.claude/handoff_backups"
: > "$bd/.ctx_nojq_DEAD1"
: > "$bd/.ctx_health_DEAD2"
: > "$bd/.ss_health_DEAD3"
must printf '3\n' > "$bd/.ctx_prompts_DEAD4"
must touch -t 202001010000 \
  "$bd/.ctx_nojq_DEAD1" "$bd/.ctx_health_DEAD2" "$bd/.ss_health_DEAD3" "$bd/.ctx_prompts_DEAD4"
run_ss "$proj"; rc=$?
check "sweep: exit 0"                    0  "$rc"
check "sweep: stale .ctx_nojq_ reaped"   no "$([[ -e "$bd/.ctx_nojq_DEAD1"   ]] && echo yes || echo no)"
check "sweep: stale .ctx_health_ reaped" no "$([[ -e "$bd/.ctx_health_DEAD2" ]] && echo yes || echo no)"
check "sweep: stale .ss_health_ reaped"  no "$([[ -e "$bd/.ss_health_DEAD3" ]] && echo yes || echo no)"
check "sweep: stale .ctx_prompts_ reaped" no "$([[ -e "$bd/.ctx_prompts_DEAD4" ]] && echo yes || echo no)"
rm -rf "$proj"

# --- Same four kinds, but fresh (not yet 7 days old) -> survive -------------
proj="$(mk_project)"; bd="$proj/.claude/handoff_backups"
: > "$bd/.ctx_nojq_FRESH1"
: > "$bd/.ctx_health_FRESH2"
: > "$bd/.ss_health_FRESH3"
must printf '1\n' > "$bd/.ctx_prompts_FRESH4"
run_ss "$proj"
check "fresh: .ctx_nojq_ survives"   yes "$([[ -e "$bd/.ctx_nojq_FRESH1"   ]] && echo yes || echo no)"
check "fresh: .ctx_health_ survives" yes "$([[ -e "$bd/.ctx_health_FRESH2" ]] && echo yes || echo no)"
check "fresh: .ss_health_ survives"  yes "$([[ -e "$bd/.ss_health_FRESH3" ]] && echo yes || echo no)"
check "fresh: .ctx_prompts_ survives" yes "$([[ -e "$bd/.ctx_prompts_FRESH4" ]] && echo yes || echo no)"
rm -rf "$proj"

# --- NEGATIVE CONTROLS, all aged >7d, all must SURVIVE the sweep ------------
#     (name-collision with unproven content, and files outside this sweep's
#     four known prefixes) — the retention rule this codebase applies
#     everywhere: never delete by glob+mtime alone, only what is provably ours.
proj="$(mk_project)"; bd="$proj/.claude/handoff_backups"
# name matches, but content is not the expected empty shape:
must printf 'not empty, not ours\n' > "$bd/.ctx_health_USERDATA"
# name matches .ctx_prompts_, but content is not a bare decimal counter:
must printf 'not-a-number\n' > "$bd/.ctx_prompts_USERDATA"
# a sidecar this sweep must never touch: turn_append's own retention owns it
# (keyed to dump eviction, not age) and deleting it here would be scope creep.
: > "$bd/.ctx_flagged_UNRELATED"
# a live dump + its cursor: outside this sweep's four prefixes entirely.
must printf 'dump\n' > "$bd/handoff_raw_LIVE.md"
: > "$bd/.handoff_raw_LIVE.cursor"
must touch -t 202001010000 "$bd/.ctx_health_USERDATA" "$bd/.ctx_prompts_USERDATA" \
  "$bd/.ctx_flagged_UNRELATED" "$bd/handoff_raw_LIVE.md" "$bd/.handoff_raw_LIVE.cursor"
run_ss "$proj"
check "ctrl: wrong-content .ctx_health_ survives"  yes "$([[ -f "$bd/.ctx_health_USERDATA"  ]] && echo yes || echo no)"
check "ctrl: wrong-content .ctx_prompts_ survives" yes "$([[ -f "$bd/.ctx_prompts_USERDATA" ]] && echo yes || echo no)"
check "ctrl: unrelated sidecar untouched"          yes "$([[ -f "$bd/.ctx_flagged_UNRELATED" ]] && echo yes || echo no)"
check "ctrl: live dump untouched"                  yes "$([[ -f "$bd/handoff_raw_LIVE.md" ]] && echo yes || echo no)"
check "ctrl: live dump cursor untouched"           yes "$([[ -f "$bd/.handoff_raw_LIVE.cursor" ]] && echo yes || echo no)"
rm -rf "$proj"

# --- Planted symlink at a marker path -> survives as a link, target intact --
proj="$(mk_project)"; bd="$proj/.claude/handoff_backups"
victim="$proj/victim.txt"
must cat > "$victim" <<'EOF'
PRISTINE
EOF
must ln -s "$victim" "$bd/.ctx_health_SYMOLD"
touch -h -t 202001010000 "$bd/.ctx_health_SYMOLD" 2>/dev/null || true
run_ss "$proj"
check "symlink: survives as a link"  yes "$([[ -L "$bd/.ctx_health_SYMOLD" ]] && echo yes || echo no)"
check "symlink: victim untouched"    "PRISTINE" "$(cat "$victim")"
rm -rf "$proj"

# --- Symlinked handoff_backups/ -> sweep refuses to run at all -------------
proj="$(mk_project)"
must rm -rf "$proj/.claude/handoff_backups"
outside="$(mktemp -d)"
must mkdir -p "$outside/handoff_backups"
: > "$outside/handoff_backups/.ctx_nojq_ESCAPE"
must touch -t 202001010000 "$outside/handoff_backups/.ctx_nojq_ESCAPE"
must ln -s "$outside/handoff_backups" "$proj/.claude/handoff_backups"
run_ss "$proj"; rc=$?
check "symlinked backups dir: exit 0 (no crash)" 0   "$rc"
check "symlinked backups dir: outside file untouched" yes "$([[ -e "$outside/handoff_backups/.ctx_nojq_ESCAPE" ]] && echo yes || echo no)"
rm -rf "$proj" "$outside"

# --- No handoff_current.md at all (the hook's earliest exit path) -> the
#     sweep still runs, because it is placed ahead of that exit. --------------
proj="$(mk_project)"; bd="$proj/.claude/handoff_backups"
: > "$bd/.ctx_nojq_NOCUR"
must touch -t 202001010000 "$bd/.ctx_nojq_NOCUR"
run_ss "$proj"; rc=$?
check "no current: still exit 0"          0  "$rc"
check "no current: stale marker reaped anyway" no "$([[ -e "$bd/.ctx_nojq_NOCUR" ]] && echo yes || echo no)"
rm -rf "$proj"

finish
