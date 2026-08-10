#!/usr/bin/env bash
# write_handoff.sh — snapshot the current repo's session state into a handoff doc
# Writes <repo>/.claude/handoff_current.md (overwriting in place, with the
# previous one rotated to .claude/handoff_history/handoff_<ts>.md first;
# last HANDOFF_HISTORY_KEEP retained — default 5, override via env).
# Prints the absolute path of the written handoff to stdout.
#
# Triggers: /handoff skill, SessionEnd hook, or manual invocation.
# Auto-loaded by the next session via the SessionStart hook in
# ~/.claude/settings.json.
#
# Flags:
#   --if-curated           Skip (no rotation, no write) if handoff_current.md
#                          already contains curated Notes content (i.e. the
#                          /handoff skill ran and replaced the placeholder
#                          block). The SessionEnd hook passes this so the
#                          safety-net write only fires when there's no real
#                          curated content to preserve. Detection is by the
#                          presence/absence of the HANDOFF_PLACEHOLDER
#                          sentinel; an unedited handoff carries the
#                          sentinel, a curated one does not.
#   --if-stale-by SECONDS  DEPRECATED (since v0.5.0). The numeric argument
#                          is ignored; this is now treated as an alias for
#                          --if-curated. Slated for removal in a future
#                          release (the original v0.6.0 target slipped).
#   --restamp              Re-sign the EXISTING handoff_current.md in place
#                          (no rotation, no rebuild): strip any HMAC trailer
#                          and append a fresh one over the current content.
#                          The /handoff skill runs this after editing the
#                          Notes/Rules blocks — the edit invalidates the
#                          write-time stamp, and without a restamp the next
#                          session loads the rules as data, not binding.
#                          Degrades to a no-op warning when signing is
#                          unavailable (no openssl / no provenance lib).
#
# Reason-aware safety net (hook invocations only): when invoked as a hook,
# stdin carries a JSON payload that MAY include a `reason` field (e.g.
# SessionEnd fires with reason "resume" on every /resume session-switch since
# CC 2.1.79). Under --if-curated ONLY, a reason listed in
# HANDOFF_SESSIONEND_SKIP_REASONS (space/comma-separated; default "resume")
# skips the write entirely — a /resume switch is a pause, not an ending, and
# each safety-net fire on an uncurated session would otherwise rotate churn
# into history. The field name is a best guess with an asymmetric-safe
# fallback: if the field is absent, named differently, or jq is missing, the
# parse yields empty and the write fires exactly as before — the guess can
# only ever ADD the skip, never subtract the safety net. Curated /handoff and
# manual runs never consult the skip list.

set -euo pipefail

# The handoff document and its rotated history capture verbatim session prose,
# which can include anything sensitive surfaced during the session — so every
# file this script writes under .claude/ should be owner-only. umask 077 makes
# the handoff doc, history snapshots, and history dir 0600/0700 at creation
# time (matching the Stop hook's handling of the raw dumps). The defensive
# chmod after the final write also tightens a doc left readable by a pre-0.8.2
# version on upgrade.
umask 077

# --- Hook payload (optional). The `-t 0` tty guard prevents a hang when the
# script is run by hand in a terminal (stdin open, nothing coming); hook
# invocations pipe JSON, and /handoff-skill Bash invocations see /dev/null ->
# instant empty read. Everything about this payload is optional: no payload,
# no jq, or no parseable reason all degrade to today's always-write behavior.
hook_payload=""
[[ -t 0 ]] || hook_payload="$(cat 2>/dev/null || true)"
session_end_reason=""
payload_cwd=""
if [[ -n "$hook_payload" ]] && command -v jq >/dev/null 2>&1; then
  session_end_reason="$(jq -r '.reason // empty' <<<"$hook_payload" 2>/dev/null || true)"
  # Charset guard: known reasons are lowercase words ("clear", "logout",
  # "prompt_input_exit", "resume", "other"); anything else is treated as
  # unrecognized -> empty -> the write proceeds.
  [[ "$session_end_reason" =~ ^[a-z_]+$ ]] || session_end_reason=""
  # Payload `cwd`: fed to handoff_resolve_root below as the second-rung
  # anchor. Guarded the same way as `.reason` (jq optional, parse failure ->
  # empty) and validated as an existing directory before use.
  payload_cwd="$(jq -r '.cwd // empty' <<<"$hook_payload" 2>/dev/null || true)"
  [[ -n "$payload_cwd" && -d "$payload_cwd" ]] || payload_cwd=""
fi

# Shared provenance helpers (issue #42): HMAC signing so the next session's
# loader can prove the handoff was written locally (not clone-delivered) and
# load the explicit rules layer as binding. OPTIONAL — an install predating
# bin/handoff_provenance.sh (e.g. a stale copy-mode ~/.claude/bin) simply
# writes an unsigned handoff, which the loader keeps on today's data framing.
self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || self_dir=""
if [[ -n "$self_dir" && -f "$self_dir/handoff_provenance.sh" ]]; then
  # shellcheck source=bin/handoff_provenance.sh
  . "$self_dir/handoff_provenance.sh"
fi
# Fallback marker/prefix definitions keep `set -u` happy when the lib is
# absent (the markers are inert scaffolding without a valid MAC anyway).
HANDOFF_BIND_BEGIN="${HANDOFF_BIND_BEGIN:-<!-- HANDOFF_BIND_BEGIN -->}"
HANDOFF_BIND_END="${HANDOFF_BIND_END:-<!-- HANDOFF_BIND_END -->}"
HANDOFF_MAC_PREFIX="${HANDOFF_MAC_PREFIX:-<!-- HANDOFF_HMAC: }"

# Can this run sign at all? Gates every signing call site below.
can_sign() {
  [[ "${HANDOFF_TRUST_DISABLE:-0}" != "1" ]] \
    && type handoff_mac_compute >/dev/null 2>&1
}

IF_CURATED=0
RESTAMP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --if-curated)
      IF_CURATED=1
      shift
      ;;
    --restamp)
      RESTAMP=1
      shift
      ;;
    --if-stale-by)
      echo "write_handoff.sh: --if-stale-by is deprecated since v0.5.0; behaving as --if-curated. Update your settings.json to use --if-curated; --if-stale-by will be removed in a future release." >&2
      IF_CURATED=1
      # Tolerate (and ignore) the now-meaningless numeric arg if present.
      if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        shift 2
      else
        shift
      fi
      ;;
    --if-stale-by=*)
      echo "write_handoff.sh: --if-stale-by is deprecated since v0.5.0; behaving as --if-curated. Update your settings.json to use --if-curated; --if-stale-by will be removed in a future release." >&2
      IF_CURATED=1
      shift
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Sentinel embedded in the auto-generated placeholder block; presence means
# the placeholder is still in place, absence means the /handoff skill (or a
# human editor) has replaced the placeholder with curated Notes.
HANDOFF_PLACEHOLDER_SENTINEL="<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->"

# Is handoff_current.md still the *unedited* placeholder?
#
# The placeholder builder (see the end of this file) writes the sentinel as the
# first non-blank line of the "## Notes from this session" section. We scope the
# check to exactly that position rather than grepping the whole file, because the
# sentinel string can legitimately appear ELSEWHERE in a curated file:
#   - the snapshot embeds verbatim commit subjects (a commit whose subject
#     contains the sentinel would match a whole-file grep), and
#   - curated Notes may quote the sentinel in prose (as this very change does).
# A whole-file match would let the SessionEnd safety-net mistake a curated file
# for a placeholder and clobber it — silent loss of the session's notes.
#
# Returns 0 (true) only when the first non-blank line under the Notes header is
# exactly the sentinel. Anything else — curated content, a malformed/headerless
# file, or a missing file — returns non-zero, i.e. "preserve, don't clobber."
handoff_is_unedited_placeholder() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  # LC_ALL=C: BSD awk under a UTF-8 locale can choke on invalid byte sequences
  # in the file; the sentinel comparison is byte-exact ASCII, so C is equivalent.
  LC_ALL=C awk -v sentinel="$HANDOFF_PLACEHOLDER_SENTINEL" '
    # Skip everything until the Notes header (the snapshot lives above it).
    !seen { if ($0 == "## Notes from this session") seen = 1; next }
    /^[[:space:]]*$/ { next }                     # skip blank lines after header
    { result = ($0 == sentinel) ? 0 : 1; found = 1; exit }  # first content line decides
    # exit jumps here; END owns the final status so the rule-level exit code
    # is not clobbered. No content line (header-only or no header) => not placeholder.
    END { exit found ? result : 1 }
  ' "$path"
}

# ----- Config (override via env in your shell rc) -----
#
# HANDOFF_INFLIGHT_DIRS — space-separated subdirs to scan for untracked /
#   modified .md files. Default: "docs". Add e.g. "docs design rfcs proposals".
# HANDOFF_SUBSTRATE_NAME — name of a sibling git repo to also snapshot
#   (e.g. a shared decisions / configs repo). Default: empty (skip substrate).
# HANDOFF_SUBSTRATE_INFLIGHT_DIRS — space-separated subdirs in the substrate
#   to scan. Default: empty. Only used if HANDOFF_SUBSTRATE_NAME is set.
# HANDOFF_HISTORY_KEEP — number of older handoffs to retain under
#   .claude/handoff_history/ (rotated in before each new write). Default: 5.
#   Set to 0 to disable retention entirely.
# HANDOFF_NO_GITIGNORE_BOOTSTRAP — set to 1 to skip the auto-add of
#   .claude/handoff_current.md and .claude/handoff_history/ into the project
#   .gitignore.
# HANDOFF_PINNED_FILE — path to a pinned-context file injected verbatim into
#   every handoff (read-only; survives rotation). Default:
#   .claude/handoff_pinned.md. Inert when the file is absent.
# HANDOFF_SYSTEMLOG_FILE — path to a system log the handoff-time nudge
#   watches; flags system-level sessions that didn't touch it. Default:
#   SYSTEM_LOG.md at repo root. Inert when the file is absent.
# HANDOFF_SESSIONEND_SKIP_REASONS — space/comma-separated hook payload
#   `reason` values that make an --if-curated (safety-net) run skip the
#   write. Default: "resume". Set to "" to always write; see the
#   reason-aware note in the header.
#
# Example for someone with a `_shared/` sibling that holds RFCs + ASKs:
#   export HANDOFF_INFLIGHT_DIRS="docs design"
#   export HANDOFF_SUBSTRATE_NAME="_shared"
#   export HANDOFF_SUBSTRATE_INFLIGHT_DIRS="rfcs ASKS"
INFLIGHT_DIRS="${HANDOFF_INFLIGHT_DIRS:-docs}"
SUBSTRATE_NAME="${HANDOFF_SUBSTRATE_NAME:-}"
SUBSTRATE_INFLIGHT_DIRS="${HANDOFF_SUBSTRATE_INFLIGHT_DIRS:-}"
HISTORY_KEEP="${HANDOFF_HISTORY_KEEP:-5}"
# Guard against a negative or non-numeric value. The rotation guard skips on
# KEEP<=0, but prune_history would still run `tail -n +$((KEEP+1))`: with KEEP=-1
# that is `tail -n +0`, which on GNU means "from the start" — i.e. it lists and
# deletes EVERY history file (silent data loss), and on BSD it errors. Anything
# that isn't a non-negative integer falls back to the default 5.
if ! [[ "$HISTORY_KEEP" =~ ^[0-9]+$ ]]; then
  echo "write_handoff.sh: HANDOFF_HISTORY_KEEP='$HISTORY_KEEP' is not a non-negative integer; using default 5." >&2
  HISTORY_KEEP=5
fi

# Project scope: shared resolver (handoff_resolve_root, sourced above) —
# anchor on CLAUDE_PROJECT_DIR first, then the hook payload's cwd, then $PWD,
# and take the git toplevel of THAT anchor. The old bare `git rev-parse
# --show-toplevel` anchored on the hook process's cwd while the SessionStart
# loader anchored on CLAUDE_PROJECT_DIR — so with cwd != project dir
# (worktrees, submodules, a `cd` during the session) this writer put the
# handoff under a root the loader never looked at. Skill-invoked runs (no
# CLAUDE_PROJECT_DIR in the Bash-tool env, no payload) still anchor on $PWD,
# unchanged. `in_git` gates the git-only pieces below (commit snapshot,
# .gitignore bootstrap, the verify-state command block).
if type handoff_resolve_root >/dev/null 2>&1; then
  handoff_resolve_root "$payload_cwd"
  repo_root="$HANDOFF_ROOT"
  in_git="$HANDOFF_ROOT_IN_GIT"
else
  # Lib absent (stale copy-mode install): inline the same precedence so this
  # script stays standalone. No payload rung here — the lib carries it.
  anchor="${CLAUDE_PROJECT_DIR:-$PWD}"
  [[ -d "$anchor" ]] || anchor="$PWD"
  repo_root="$(git -C "$anchor" rev-parse --show-toplevel 2>/dev/null || true)"
  in_git=1
  if [[ -z "$repo_root" ]]; then
    in_git=0
    repo_root="$anchor"
  fi
fi
if [[ -z "$repo_root" ]]; then
  echo "ERROR: cannot resolve a project directory (no git worktree, CLAUDE_PROJECT_DIR, or PWD)" >&2
  exit 1
fi

repo_name="$(basename "$repo_root")"
handoff_dir="$repo_root/.claude"
handoff_path="$handoff_dir/handoff_current.md"
handoff_relpath=".claude/handoff_current.md"
history_dir="$handoff_dir/handoff_history"
history_relpath=".claude/handoff_history/"

# Pinned-context file: read verbatim into every handoff and never written
# by this script, so it survives rotation untouched (edit it to change what
# carries forward). System-log file: watched by the handoff-time nudge.
# Both default to per-repo paths and are INERT when the file is absent —
# repos without them are entirely unaffected. Override via
# HANDOFF_PINNED_FILE / HANDOFF_SYSTEMLOG_FILE.
pinned_file="${HANDOFF_PINNED_FILE:-$handoff_dir/handoff_pinned.md}"
pinned_relpath="${pinned_file#"$repo_root"/}"
systemlog_file="${HANDOFF_SYSTEMLOG_FILE:-$repo_root/SYSTEM_LOG.md}"
systemlog_relpath="${systemlog_file#"$repo_root"/}"

# Pin bindability (issue #42): the pinned file is meant to be USER-authored
# and gitignored — but a cloned repo can COMMIT its own .claude/handoff_pinned.md,
# and embedding that into a signed doc would launder clone-delivered content
# into the binding tier. So: a pin that is TRACKED in git stays on the data
# tier (emitted without BIND markers, with a note saying why). An out-of-tree
# pin (absolute HANDOFF_PINNED_FILE override) is the user's own file and is
# always bindable. Without the provenance lib the point is moot — nothing gets
# signed, so markers never bind — but stay conservative anyway.
# Resolve the pin to a path we can run the untracked check against. Compute an
# in-repo relative path whether the pin is the default, a RELATIVE override
# (e.g. a committed .claude/settings.json sets HANDOFF_PINNED_FILE=.claude/x.md
# — clone-deliverable, so it must be checked), or an absolute path inside the
# repo. Only a genuinely out-of-tree absolute path skips the check (the user's
# own file to manage). The earlier `pinned_relpath` used raw prefix-stripping,
# which left a relative override unresolved and let a tracked clone-delivered
# pin sail through as bindable.
pin_check_rel=""
case "$pinned_file" in
  /*)
    # Absolute: in-repo → strip the root prefix; out-of-tree → no check.
    if [[ "$pinned_file" == "$repo_root/"* ]]; then
      pin_check_rel="${pinned_file#"$repo_root"/}"
    fi
    ;;
  *)
    # Relative: interpret against the repo root (matches how git resolves it).
    pin_check_rel="${pinned_file#./}"
    ;;
esac
pin_bindable=1
if type handoff_is_untracked >/dev/null 2>&1 && [[ -n "$pin_check_rel" ]]; then
  if ! handoff_is_untracked "$pin_check_rel" "$repo_root"; then
    pin_bindable=0
  fi
fi

# Symlink-safety. The final document write is a `>` redirect (and rotation does
# `mv "$handoff_path" -> history`); `>` FOLLOWS a symlink and truncates its
# target. A malicious repo can ship `.claude/handoff_current.md` (or `.claude`
# itself) as a symlink to a victim file (~/.bashrc, ~/.claude/settings.json, a CI
# key). On the default path rotation moves the link out of the way first, but
# that is gated on HISTORY_KEEP>0 — so HANDOFF_HISTORY_KEEP=0 (a supported
# setting, and what the test suite uses) would write straight through and destroy
# the target. Refuse a symlinked .claude, and drop any symlink planted at the
# handoff path so we always create a fresh real file in this repo and never write
# through to the link target (this also stops rotation from relocating a planted
# symlink into handoff_history/, where SessionStart would later cat through it).
if [[ -L "$handoff_dir" ]]; then
  echo "write_handoff.sh: $handoff_dir is a symlink; refusing to operate through it." >&2
  exit 1
fi
mkdir -p "$handoff_dir"
if [[ -L "$handoff_path" ]]; then
  echo "write_handoff.sh: dropping planted symlink at $handoff_relpath (refusing to write through it)." >&2
  rm -f "$handoff_path"
fi

# ----- mkdir-based mutual-exclusion locks ------------------------------------
# Shared idiom with handoff_turn_append.sh's flock-less fallback (keep the two
# in sync): mkdir(2) is the one atomic test-and-create primitive available
# everywhere this script runs (flock ships on Linux and Git Bash but not
# macOS), so a lock is "held" while the lock DIRECTORY exists. A hard kill
# (SIGKILL, OOM, power loss) skips EXIT traps and would leave the dir behind
# forever, so acquisition includes the same mtime-based staleness reclaim as
# the turn-append hook: a lock older than HANDOFF_LOCK_STALE_SECS (default
# 300s — comfortably above Claude Code's 60s hook timeout, so a slow-but-alive
# holder can't have its lock stolen) is presumed orphaned and reclaimed.
# Returns 0 with the lock held, 1 otherwise; each call site documents how it
# degrades on a miss. The lock paths live under .claude/, whose non-symlink
# status is enforced above.
try_mkdir_lock() {  # <lock_dir>
  local lock_dir="$1" stale_secs lock_mtime now
  # A symlink planted at the lock path (a malicious repo could ship one) makes
  # mkdir fail with EEXIST forever and rmdir can't reclaim through it — i.e. a
  # permanently wedged lock. Refuse it, mirroring this script's other symlink
  # guards; the caller degrades exactly as for a held lock.
  if [[ -L "$lock_dir" ]]; then
    echo "write_handoff.sh: $lock_dir is a symlink; refusing to use it as a lock." >&2
    return 1
  fi
  mkdir "$lock_dir" 2>/dev/null && return 0
  # Held (or leftover). Reclaim only when older than the staleness window.
  # Age via GNU `stat -c` with a BSD `stat -f` fallback, like turn_append.
  stale_secs="${HANDOFF_LOCK_STALE_SECS:-300}"
  # Numeric guard before the (( )) below: bash arithmetic recursively
  # expands its operand, so a non-numeric payload (e.g. an array subscript
  # with command substitution) delivered via a clone's .claude/settings.json
  # env would execute. Fall back to the default on anything non-numeric,
  # matching every other arithmetic env var in this script.
  [[ "$stale_secs" =~ ^[0-9]+$ ]] || stale_secs=300
  lock_mtime="$(stat -c %Y "$lock_dir" 2>/dev/null \
                || stat -f %m "$lock_dir" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  if [[ "$lock_mtime" =~ ^[0-9]+$ ]] \
     && (( now - lock_mtime >= stale_secs )) \
     && rmdir "$lock_dir" 2>/dev/null \
     && mkdir "$lock_dir" 2>/dev/null; then
    return 0   # reclaimed a stale lock
  fi
  return 1
}

# One EXIT trap owns ALL cleanup from here on (traps replace each other, so
# scattering per-resource traps would silently drop earlier ones): the build
# tmp file, and any lock still held when the script exits — normal release is
# explicit at the end of each critical section; this is the abort backstop.
# Every variable is read with a :- default because the trap can fire before
# any of them is set.
write_lock_dir=""
write_lock_held=0
gitignore_lock=""
gitignore_lock_held=0
handoff_tmp=""
cleanup() {
  if [[ -n "${handoff_tmp:-}" ]]; then rm -f "$handoff_tmp" 2>/dev/null || true; fi
  if (( ${write_lock_held:-0} )); then rmdir "$write_lock_dir" 2>/dev/null || true; fi
  if (( ${gitignore_lock_held:-0} )); then rmdir "$gitignore_lock" 2>/dev/null || true; fi
  return 0
}
trap cleanup EXIT

# --restamp: re-sign the existing document in place and exit. Runs after the
# symlink guards above (so it can't stamp through a planted link) and before
# everything else — no rotation, no rebuild, no .gitignore bootstrap. The
# rewrite is mktemp+mv atomic like the main publish. Every degraded path
# (missing file, no signing capability) warns and exits 0: the /handoff skill
# calls this best-effort, and an unsigned file just keeps data framing.
if (( RESTAMP )); then
  if [[ ! -f "$handoff_path" ]]; then
    echo "write_handoff.sh: --restamp: no $handoff_relpath to stamp; nothing done." >&2
    exit 0
  fi
  if ! can_sign; then
    echo "write_handoff.sh: --restamp: signing unavailable (provenance lib missing, or HANDOFF_TRUST_DISABLE=1); leaving the file as is." >&2
    echo "$handoff_path"
    exit 0
  fi
  if mac="$(handoff_mac_compute "$handoff_path" ensure)"; then
    restamp_tmp="$(mktemp "$handoff_dir/.handoff_current.XXXXXX")"
    trap 'rm -f "$restamp_tmp"' EXIT
    {
      # Strip only a well-formed trailer (matching handoff_mac_compute), so a
      # prose line that merely starts with the prefix is preserved and stays
      # covered by the digest. `|| true`: grep -v exits 1 on an all-stripped
      # (empty) doc, which under set -e/pipefail would abort the restamp.
      LC_ALL=C grep -Ev '^<!-- HANDOFF_HMAC: [0-9a-f]{64} -->[[:space:]]*$' "$handoff_path" || true
      printf '%s%s -->\n' "$HANDOFF_MAC_PREFIX" "$mac"
    } > "$restamp_tmp"
    chmod 600 "$restamp_tmp" 2>/dev/null || true
    mv -f "$restamp_tmp" "$handoff_path"
  else
    echo "write_handoff.sh: --restamp: cannot sign (openssl or the per-machine secret unavailable); the rules layer will load as reference data, not binding." >&2
  fi
  echo "$handoff_path"
  exit 0
fi

# --if-curated guard: when the SessionEnd safety-net fires after a curated
# /handoff write, we want to preserve the curated content rather than
# clobber it with a mechanical snapshot. The check is by content (placeholder
# presence) rather than by mtime, so post-/handoff work in the same
# session doesn't trigger a false skip: any session that didn't replace
# the placeholder is still considered "no curated content to preserve."
# Rules-block curation sentinel: present while the `## Rules` fences region is
# unedited; the /handoff skill replaces it with explicit fences. Used so a
# session that curated ONLY the Rules block (leaving the Notes placeholder) is
# still treated as curated — otherwise the safety-net rebuild would silently
# clobber the fences. Matched anywhere (a curated file simply won't contain the
# token; the worst case is a false "not curated" that the Notes check covers).
HANDOFF_RULES_PLACEHOLDER_TOKEN="HANDOFF_RULES_PLACEHOLDER"
if (( IF_CURATED )); then
  # Reason-aware skip (safety net only — never on curated /handoff or manual
  # runs, which don't pass --if-curated). A reason in the skip list means
  # "this isn't really an ending" (default: "resume" — /resume switches fire
  # SessionEnd per switch, and each one would rotate churn through history).
  # Same exit shape as the curated skip below: no rotation, no write.
  # ${VAR-default} (not :-) so an explicitly-empty override disables the list.
  skip_reasons="${HANDOFF_SESSIONEND_SKIP_REASONS-resume}"
  if [[ -n "$session_end_reason" && -n "$skip_reasons" ]]; then
    for skip_r in $(printf '%s' "$skip_reasons" | tr ',' ' '); do
      if [[ "$skip_r" == "$session_end_reason" ]]; then
        echo "$handoff_path"
        exit 0
      fi
    done
  fi
  if [[ -f "$handoff_path" ]]; then
    # Rules were curated iff the doc HAS a bind region (new-format write) AND
    # the rules-placeholder token is gone. Requiring the marker avoids a false
    # "curated" on old-format docs (no Rules section) and on raw safety-net
    # writes, which contain neither the marker nor the token — those must still
    # fall through to the Notes-placeholder check and be overwritten.
    rules_curated=0
    if grep -qF "$HANDOFF_BIND_BEGIN" "$handoff_path" 2>/dev/null \
       && ! grep -qF "$HANDOFF_RULES_PLACEHOLDER_TOKEN" "$handoff_path" 2>/dev/null; then
      rules_curated=1
    fi
    if ! handoff_is_unedited_placeholder "$handoff_path" || (( rules_curated )); then
      # Notes OR Rules were curated (or the file is otherwise non-placeholder).
      # Preserve it rather than clobber with a fresh mechanical snapshot.
      echo "$handoff_path"
      exit 0
    fi
  fi
fi

# Self-bootstrap: ensure the handoff artifacts are git-ignored so they don't
# pollute `git status`. Skip if HANDOFF_NO_GITIGNORE_BOOTSTRAP=1.
bootstrap_gitignore() {
  local entry="$1"
  # Nothing to ignore when this project isn't under git. (return 0 — a bare
  # `return` would propagate the failed `(( in_git ))` status and, since this
  # function is called as a bare statement, trip `set -e`.)
  (( in_git )) || return 0
  if git -C "$repo_root" check-ignore -q "$entry" 2>/dev/null; then
    return
  fi
  local gi="$repo_root/.gitignore"
  # Don't append through a symlinked .gitignore (a malicious repo could point it
  # at a victim file). Skip the bootstrap for this entry if it's a symlink.
  if [[ -L "$gi" ]]; then
    echo "write_handoff.sh: $gi is a symlink; skipping .gitignore bootstrap for '$entry'." >&2
    return
  fi
  local existed=1; [[ -e "$gi" ]] || existed=0
  # Best-effort append. An UNWRITABLE .gitignore used to abort the entire
  # handoff write here under set -e (the SessionEnd safety net died silently
  # on every fire, '>/dev/null 2>&1 || true' wiring). Warn and continue
  # instead, mirroring the symlink skip above — the doc write itself does not
  # depend on the bootstrap. Commands in an `if` condition are exempt from
  # set -e, so the group can fail without killing the script.
  if ! {
       if [[ -s "$gi" ]] && [[ "$(tail -c1 "$gi" | wc -l)" -eq 0 ]]; then
         printf '\n' >> "$gi"
       fi
       echo "$entry" >> "$gi"
     } 2>/dev/null; then
    echo "write_handoff.sh: cannot append to $gi; skipping .gitignore bootstrap for '$entry'." >&2
    return 0
  fi
  # A .gitignore is not secret and is normally world-readable + committed; the
  # script-wide `umask 077` (which protects the handoff docs/dumps) would
  # otherwise leave a freshly-created one 0600 — surprising for a shared project
  # file. Normalize only a file WE just created; never touch one the user had.
  (( existed )) || chmod 644 "$gi" 2>/dev/null || true
  echo "write_handoff.sh: added '$entry' to $gi (set HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 to skip)" >&2
}
if [[ "${HANDOFF_NO_GITIGNORE_BOOTSTRAP:-0}" != "1" ]]; then
  # The check-ignore→append sequence in bootstrap_gitignore races the
  # IDENTICAL bootstrap in handoff_turn_append.sh (Stop hook): both can pass
  # check-ignore before either appends, and the .gitignore ends up with
  # duplicated entries. Both scripts therefore take the SAME dedicated lock —
  # <root>/.claude/.handoff_gitignore.lock, name and idiom shared with
  # turn_append — around the whole sequence so they actually exclude each
  # other. On a miss, skip silently: the holder is appending the very same
  # entries, and check-ignore makes the next fire's retry idempotent.
  gitignore_lock="$handoff_dir/.handoff_gitignore.lock"
  if try_mkdir_lock "$gitignore_lock"; then
    gitignore_lock_held=1
    bootstrap_gitignore "$handoff_relpath"
    bootstrap_gitignore "$history_relpath"
    # Raw per-turn transcript dumps (written by the Stop hook) contain
    # verbatim session content — including anything sensitive surfaced in
    # tool output — so they must never be committable.
    bootstrap_gitignore ".claude/handoff_backups/"
    # The pin is local operational state, same class as the handoff itself.
    # Only auto-ignore when it sits inside the repo (the default and the
    # common override); an out-of-tree override is the user's to manage.
    if [[ "$pinned_relpath" != /* && "$pinned_relpath" != "$pinned_file" ]]; then
      bootstrap_gitignore "$pinned_relpath"
    fi
    # Release promptly (the doc build below is slow); the cleanup trap is
    # only the abort backstop.
    rmdir "$gitignore_lock" 2>/dev/null || true
    gitignore_lock_held=0
  fi
fi

# Rotate the existing handoff (if any) into handoff_history/ before we
# overwrite it. The rotated file's name reflects its original generation
# time (file mtime), not the rotation time, so the history reads as a
# chronological log of session endings. Then prune to HISTORY_KEEP newest.
# Portable file-mtime as YYYY-mm-dd_HHMMSS in UTC. GNU and BSD/macOS differ on
# both halves: `stat -c %Y` (GNU) vs `stat -f %m` (BSD) for the mtime epoch, and
# `date -d @EPOCH` (GNU) vs `date -r EPOCH` (BSD) to format it. (The old
# `date -u -r FILE` worked on GNU only; on BSD `-r` takes an epoch, not a path,
# so it silently fell back to the current time and mis-stamped the rotation.)
file_mtime_stamp() {
  local f="$1" epoch
  epoch="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || true)"
  if [[ "$epoch" =~ ^[0-9]+$ ]]; then
    date -u -d "@$epoch" +'%Y-%m-%d_%H%M%S' 2>/dev/null \
      || date -u -r "$epoch" +'%Y-%m-%d_%H%M%S' 2>/dev/null \
      || date -u +'%Y-%m-%d_%H%M%S'
  else
    date -u +'%Y-%m-%d_%H%M%S'
  fi
}

rotate_existing_handoff() {
  [[ -f "$handoff_path" ]] || return 0
  # An outgoing UNEDITED placeholder is deleted, not archived: it carries no
  # curated prose (only mechanical git state the incoming write regenerates),
  # and with the PreCompact safety net a session can now produce several
  # placeholder writes — archiving each one would churn a keep-N history and
  # evict the curated snapshots that are the whole point of retention. Not
  # archiving placeholders also means handoff_session_start's history
  # fallback lands on CURATED files more often. Detection reuses the same
  # position-scoped check as --if-curated, so a curated file that merely
  # quotes the sentinel is still archived normally.
  if handoff_is_unedited_placeholder "$handoff_path"; then
    rm -f "$handoff_path"
    return 0
  fi
  [[ "$HISTORY_KEEP" -gt 0 ]] || return 0
  mkdir -p "$history_dir"
  local ts archived
  ts="$(file_mtime_stamp "$handoff_path")"
  archived="$history_dir/handoff_${ts}.md"
  # If a file with the same timestamp already exists, append a counter so we
  # don't clobber. The claim must be ATOMIC, not probe-then-mv: the old
  # `[[ -e ]]` probe followed by a plain `mv` was a TOCTOU — two concurrent
  # runs could both probe the same name clear, and the second `mv` silently
  # clobbered the first run's archive. `mv -n` ("never overwrite an existing
  # destination") folds the existence check and the rename into one operation.
  # Portability, verified: BSD/macOS mv supports -n (on a skip it leaves the
  # source in place and exits 0), and GNU coreutils mv supports -n too — but
  # GNU's exit status ON SKIP changed across versions (nonzero since
  # coreutils 9.2), so the exit code is NOT a portable skip signal. The one
  # invariant both implementations share: a skipped move leaves the SOURCE
  # file in place. So the loop attempts a candidate name and keys on "did the
  # source disappear" to know it won; source-still-there means the name was
  # taken — bump the counter and try the next. Chosen over the ln-then-rm
  # hard-link idiom because mv preserves the single-rename atomicity the
  # publish path already relies on and needs no link-count cleanup.
  # Bounded: 50 same-second collisions is not a real scenario, so after 50
  # attempts the failure is something else (EPERM, ENOSPC — where mv also
  # leaves the source, for a different reason); fall through to a plain loud
  # mv so the real error surfaces under set -e instead of spinning forever.
  local n=1 attempts=0 candidate="$archived"
  while :; do
    mv -n "$handoff_path" "$candidate" 2>/dev/null || true
    [[ -e "$handoff_path" ]] || break        # source gone -> claim succeeded
    attempts=$((attempts + 1))
    if (( attempts >= 50 )); then
      mv "$handoff_path" "$candidate"        # loud; aborts under set -e on a real error
      break
    fi
    n=$((n + 1))
    candidate="${archived%.md}_${n}.md"
  done
  archived="$candidate"
  # Tighten a doc written 0644 by a pre-0.8.2 version: `mv` preserves the source
  # mode, so without this a world-readable handoff stays world-readable once
  # rotated into history (the prose can hold secrets). New docs are already 0600.
  chmod 600 "$archived" 2>/dev/null || true
}
prune_history() {
  # KEEP=0 means "retention disabled" — documented in the README as "existing
  # snapshots are never touched", and the rotation guard above already skips
  # archiving on KEEP<=0. But this prune used to run unconditionally: with
  # KEEP=0 the `tail -n +$((KEEP+1))` below is `tail -n +1`, which lists EVERY
  # history file for deletion — so a one-off `HANDOFF_HISTORY_KEEP=0` run
  # destroyed all prior curated snapshots (the exact opposite of "disabled").
  # Skip pruning entirely; existing history is left untouched. The non-numeric/
  # negative fallback above guarantees HISTORY_KEEP is a non-negative integer
  # by the time we get here.
  [[ "$HISTORY_KEEP" -gt 0 ]] || return 0
  [[ -d "$history_dir" ]] || return 0
  # Delete all but the HISTORY_KEEP newest. Use a `while IFS= read -r` loop with
  # `rm -f --` (mirroring handoff_turn_append.sh) rather than a bare `xargs -r
  # rm -f`: history files live in a repo the user may have cloned, and a crafted
  # filename containing whitespace or a quote would make xargs mis-split it or
  # abort with a parse error — and under set -e that abort would take the whole
  # handoff write down with it. read -r preserves the line verbatim and `--`
  # stops a leading dash from being read as an rm option.
  #
  # ONLY DELETE FILES WE GENERATED. The `-name 'handoff_*.md'` glob is far
  # broader than what rotate_existing_handoff writes, so a file the USER put
  # here — hand-preserving a snapshot as e.g. `handoff_2026-01-05_IMPORTANT.md`
  # is a natural thing to do — used to match, sort into the tail, and get
  # deleted with no warning and no backup. Filter to the exact shape we emit:
  # `handoff_<YYYY-MM-DD>_<HHMMSS>.md`, plus the `_<N>` same-second collision
  # suffix. Anything else is someone else's file and is left untouched. (#46)
  # LC_ALL=C on the sort: same-second collision names (handoff_<stamp>_2.md)
  # must rank as NEWER than their base (handoff_<stamp>.md), which holds under
  # byte collation (`_` 0x5F > `.` 0x2E) but flips under UTF-8 locale
  # collation (measured on macOS en_US.UTF-8) — an at-the-retention-boundary
  # prune would then delete the newer sibling and keep the older one. Same
  # fix as handoff_session_start.sh's newest-first pick; keep them in sync.
  local f
  find "$history_dir" -maxdepth 1 -name 'handoff_*.md' -type f 2>/dev/null \
    | LC_ALL=C grep -E '/handoff_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}(_[0-9]+)?\.md$' \
    | LC_ALL=C sort -r \
    | tail -n +$((HISTORY_KEEP + 1)) \
    | while IFS= read -r f; do
        [[ -n "$f" ]] && rm -f -- "$f"
      done
  # `grep` exiting 1 (nothing ours to consider) must not fail the pipeline under
  # pipefail — the caller already guards with `|| true`, but be explicit.
  return 0
}
# Capture the HEAD recorded in the previous handoff BEFORE rotation moves
# it away. The rotation boundary is a usable proxy for "since last session,"
# letting the system-log nudge diff this session's commits. Empty (→ nudge
# skipped) on first run or if the prior handoff had no parseable HEAD.
prev_head=""
if [[ -f "$handoff_path" ]]; then
  # shellcheck disable=SC2016  # backticks are literal chars in the markdown HEAD line, not command substitution
  prev_head="$(grep -m1 '^\*\*HEAD:\*\*' "$handoff_path" 2>/dev/null \
    | sed -E 's/.*`([0-9a-fA-F]+)`.*/\1/' | grep -Ei '^[0-9a-f]+$' || true)"
fi

# NB: rotation is deferred until the replacement document is fully built (see
# just above the publish mv at the bottom). Rotating here — before the build —
# meant any abort in between (ENOSPC, a git failure under pipefail) consumed
# the previous handoff_current.md and published nothing: the next SessionStart
# then loaded no context at all, silently.

# Optional substrate detection — sibling repo at $HANDOFF_SUBSTRATE_NAME
substrate_root=""
if [[ -n "$SUBSTRATE_NAME" ]]; then
  candidate="$(cd "$repo_root/.." && pwd)/$SUBSTRATE_NAME"
  if [[ -d "$candidate/.git" ]]; then
    substrate_root="$candidate"
  else
    # Configured but not found / not a git repo. Silently skipping hid typos in
    # HANDOFF_SUBSTRATE_NAME and renamed/missing siblings; surface it so the
    # user knows the substrate snapshot was intentionally omitted, not lost.
    echo "write_handoff.sh: substrate '$SUBSTRATE_NAME' not found as a git repo at '$candidate'; skipping substrate snapshot." >&2
  fi
fi

ts_utc="$(date -u +'%Y-%m-%d %H:%M UTC')"

git_short() { git -C "$1" rev-parse --short HEAD 2>/dev/null || echo "?"; }
git_subj()  { git -C "$1" log -1 --pretty=%s 2>/dev/null || echo "?"; }
git_branch() { git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?"; }

snapshot_repo() {
  local root="$1"
  local label="$2"
  local upstream

  printf '## %s\n\n' "$label"

  # Off-git: no commit/branch/working-tree state to report. Emit a clear note
  # instead of a wall of "?" placeholders, and skip the git commands entirely.
  if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '_Not a git repository — no commit, branch, or working-tree state to snapshot._\n\n'
    return
  fi

  # `head -1` closes the pipe after one line; on a big dirty tree (thousands of
  # untracked paths, ~64KB+ of status output) git then dies of SIGPIPE, and
  # under pipefail that aborted the whole write — after the old handoff had
  # already been rotated away, leaving no handoff_current.md at all. The branch
  # line is emitted before head exits, so `|| true` loses nothing.
  upstream="$(git -C "$root" status -sb 2>/dev/null | head -1 | sed 's/^## //' || true)"
  # shellcheck disable=SC2016  # backticks are literal markdown code spans in the output
  printf '**HEAD:** `%s` — %s\n\n' "$(git_short "$root")" "$(git_subj "$root")"
  # shellcheck disable=SC2016  # backticks are literal markdown code spans in the output
  printf '**Branch:** `%s` (%s)\n\n' "$(git_branch "$root")" "$upstream"

  printf '### Recent commits\n\n'
  printf '```\n'
  git -C "$root" log --oneline -10 2>/dev/null || echo "(no log)"
  printf '```\n\n'

  printf '### Working tree\n\n'
  if [[ -z "$(git -C "$root" status --porcelain 2>/dev/null)" ]]; then
    printf '_clean_\n\n'
  else
    printf '```\n'
    # Unguarded, this bare statement would abort the write under set -e if git
    # failed here — in the same rotated-but-not-yet-published window as above.
    git -C "$root" status -s 2>/dev/null || true
    printf '```\n\n'
  fi
}

list_inflight_md() {
  # Untracked OR modified .md files under a given subdir of a given repo.
  #
  # Uses --porcelain -z: NUL-terminated records with paths emitted VERBATIM.
  # Plain --porcelain splits status from path on a single space and C-quotes
  # any path containing spaces (e.g. `"docs/my notes.md"`), so the old
  # `awk '{print $2}'` truncated such a path at the first space and the `.md`
  # filter then dropped it entirely — spaced filenames silently vanished.
  local root="$1"
  local subdir="$2"
  local xy path
  # "In-flight .md" is a git concept (untracked/modified). Off-git there's
  # nothing to list — and the git pipeline below would fail under `pipefail`
  # and could abort the caller's `found=$(...)` under `set -e`. Return empty.
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "$root" status --porcelain -z "$subdir" 2>/dev/null \
    | while IFS= read -r -d '' entry; do
        xy="${entry:0:2}"      # two-char status field
        path="${entry:3}"      # path begins after "XY " (status + one space)
        # Rename/copy entries are followed by a second NUL-terminated field
        # (the source path); consume it into _ so it isn't read as the next
        # entry — the value itself is deliberately unused.
        case "$xy" in
          R*|C*) IFS= read -r -d '' _ || true ;;
        esac
        case "$xy" in
          '??'|' M'|'M '|'MM'|'AM') ;;   # untracked or modified (staged/unstaged)
          *) continue ;;
        esac
        [[ "$path" == *.md ]] && printf '%s\n' "$path"
      done || true
}

# Build the document in a temp file in $handoff_dir (same filesystem → the mv
# below is an atomic rename). umask 077 makes it 0600 at creation; the cleanup
# EXIT trap (installed above, alongside the lock helpers) removes it if
# anything aborts before the final publish — do NOT set a new trap here, that
# would silently replace the shared one and leak any held lock on abort.
handoff_tmp="$(mktemp "$handoff_dir/.handoff_current.XXXXXX")"

{
  printf '# %s — session handoff (auto-generated)\n\n' "$repo_name"
  printf '**Generated:** %s\n\n' "$ts_utc"
  # Machine-readable resolution record: which root this doc was written for,
  # and whether that root was a git worktree at write time. The SessionStart
  # loader compares these against ITS resolution and warns on a mismatch
  # (moved/renamed project) or a non-git -> git flip (the snapshot predates
  # `git init` / arrived with a clone), instead of silently loading a doc
  # that describes some other tree. An inert HTML comment, covered by the
  # HMAC like every other line.
  printf '<!-- HANDOFF_ROOT: %s in_git=%s -->\n\n' "$repo_root" "$in_git"

  cat <<EOF
Auto-written by \`~/.claude/bin/write_handoff.sh\` (called from the
\`/handoff\` skill + the \`SessionEnd\` hook in \`~/.claude/settings.json\`).
Auto-loaded into the next session by the \`SessionStart\` hook in the
same settings file. Lives at \`<root>/.claude/handoff_current.md\`, where
\`<root>\` is resolved from the Claude Code project dir (falling back to
the hook payload's cwd, then the process cwd) and then anchored on that
dir's git toplevel — the same resolution the loader uses, recorded in the
\`HANDOFF_ROOT\` comment above. The previous handoff is rotated to
\`.claude/handoff_history/\` before
overwrite (last $HISTORY_KEEP retained; override via \`HANDOFF_HISTORY_KEEP\`).
Run \`/handoff-more\` in a fresh session to pull older handoffs into context.

EOF

  echo '---'
  echo

  # Pinned context — read verbatim from $pinned_file if present. Never
  # regenerated; edit that file to change what carries forward. Placed
  # first so durable context + guardrails are the first thing the next
  # session reads, before the git snapshot.
  if [[ -s "$pinned_file" ]]; then
    # BIND markers scope the rules tier: the SessionStart loader extracts only
    # marker-wrapped regions for binding (directive) framing, and only when the
    # whole document's provenance verifies (untracked + valid HMAC trailer). A
    # TRACKED pin is potentially clone-delivered, so it is emitted WITHOUT
    # markers and stays on the data tier — see pin_bindable above.
    if (( pin_bindable )); then
      printf '%s\n' "$HANDOFF_BIND_BEGIN"
    fi
    printf '## 📌 Pinned — carried forward every handoff\n\n'
    if (( ! pin_bindable )); then
      printf '_Note: the pin file is TRACKED in git, so it may have arrived with a\n'
      printf 'clone — it loads as reference data, not binding rules. Untrack it\n'
      # shellcheck disable=SC2016  # backticks are literal markdown code spans in the output
      printf '(`git rm --cached %s` + gitignore) to restore binding._\n\n' "$pinned_relpath"
    fi
    # shellcheck disable=SC2016  # backticks are literal markdown code spans in the output
    printf '_Source: `%s` — edit that file to change this; `write_handoff.sh`\n' "$pinned_relpath"
    printf 'only reads it, so it survives rotation. This is the durable-but-\n'
    printf 'temporary layer: context + guardrails that outlive a session but\n'
    printf 'expire when the underlying state resolves. Permanent rules go in\n'
    printf 'AGENTS.md; this-session intent goes in Notes below._\n\n'
    # Sanitize marker-shaped lines in the pin body BEFORE it lands between our
    # own BIND markers: only the writer may open/close a bind region. Without
    # this, a clone-delivered pin embedding its own `<!-- HANDOFF_BIND_BEGIN
    # -->` would surface its content in the binding tier even when pin_bindable
    # is 0 (the loader scans marker lines file-wide, not just our pair), and an
    # embedded END could prematurely close our region. Applied unconditionally.
    #
    # The `pin_body="$(cat ...)"` capture is deliberate (not a direct
    # `sanitize < file`): an assignment's command-substitution failure honors
    # `set -e`, so an unreadable pin (e.g. a directory planted at the path)
    # still aborts the build here — preserving the deferred-rotation guarantee
    # that a mid-build failure never consumes the previous handoff. Piping the
    # file straight into the sanitize filter would let its internal `|| echo`
    # fallback swallow the read error and publish a corrupt handoff instead.
    if type handoff_sanitize_markers >/dev/null 2>&1; then
      pin_body="$(cat "$pinned_file")"
      printf '%s\n' "$pin_body" | handoff_sanitize_markers
    else
      cat "$pinned_file"
    fi
    printf '\n'
    if (( pin_bindable )); then
      printf '%s\n' "$HANDOFF_BIND_END"
    fi
    printf '\n'
    echo '---'
    echo
  fi

  snapshot_repo "$repo_root" "Repo: $repo_name"

  if [[ -n "$substrate_root" ]]; then
    snapshot_repo "$substrate_root" "Substrate: $SUBSTRATE_NAME"
  fi

  # In-flight markdown across configured paths in the main repo
  for d in $INFLIGHT_DIRS; do
    [[ -d "$repo_root/$d" ]] || continue
    # shellcheck disable=SC2016  # backticks are literal markdown code spans in the output
    printf '## In-flight (untracked or modified .md under `%s/`)\n\n' "$d"
    found="$(list_inflight_md "$repo_root" "$d/")"
    if [[ -z "$found" ]]; then
      printf '_none_\n\n'
    else
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        echo "- \`$f\`"
      done <<< "$found"
      printf '\n'
    fi
  done

  # Same for the substrate, if configured
  if [[ -n "$substrate_root" ]]; then
    for d in $SUBSTRATE_INFLIGHT_DIRS; do
      [[ -d "$substrate_root/$d" ]] || continue
      # shellcheck disable=SC2016  # backticks are literal markdown code spans in the output
      printf '## In-flight (untracked or modified .md under `%s/%s/`)\n\n' "$SUBSTRATE_NAME" "$d"
      found="$(list_inflight_md "$substrate_root" "$d/")"
      if [[ -z "$found" ]]; then
        printf '_none_\n\n'
      else
        while IFS= read -r f; do
          [[ -z "$f" ]] && continue
          echo "- \`$SUBSTRATE_NAME/$f\`"
        done <<< "$found"
        printf '\n'
      fi
    done
  fi

  printf '## Verify state matches reality\n\n'
  printf '```bash\n'
  if (( in_git )); then
    printf 'git -C %s status && git -C %s log --oneline -5\n' "$repo_root" "$repo_root"
    if [[ -n "$substrate_root" ]]; then
      printf 'git -C %s log --oneline -5\n' "$substrate_root"
    fi
  else
    # Non-git project: no commit/branch state to verify against. Point at the
    # handoff artifacts instead so the next session can confirm they exist.
    printf 'ls -la %s/.claude/\n' "$repo_root"
  fi
  printf '```\n\n'

  # System-log nudge (handoff-time only). Fires only when this session's
  # commits look system-level (changed shape) AND none of them touched the
  # system log. A nudge, not a gate — false positives just prompt a second
  # look. Inert when the log file is absent or there's no prior HEAD.
  # Tune the path / subject heuristics below per project if it over-fires.
  if [[ -f "$systemlog_file" && -n "$prev_head" ]]; then
    range_commits="$(git -C "$repo_root" log --oneline "${prev_head}..HEAD" 2>/dev/null || true)"
    if [[ -n "$range_commits" ]]; then
      changed_files="$(git -C "$repo_root" log --name-only --pretty=format: "${prev_head}..HEAD" 2>/dev/null || true)"
      subjects="$(git -C "$repo_root" log --pretty=%s "${prev_head}..HEAD" 2>/dev/null || true)"
      touched_log="$(printf '%s\n' "$changed_files" | grep -Fx "$systemlog_relpath" || true)"
      sys_paths="$(printf '%s\n' "$changed_files" | grep -E '(^|/)(AGENTS\.md|.*-rules\.md|db-bootstrap\.sh|install\.sh)$|^\.github/workflows/' || true)"
      sys_subj="$(printf '%s\n' "$subjects" | grep -iE 'secur|migrat|scaffold|topolog|isolat|\brole\b|\bauth\b|\bdb\b' || true)"
      if [[ -z "$touched_log" && ( -n "$sys_paths" || -n "$sys_subj" ) ]]; then
        printf '## ⚠️ System-log nudge\n\n'
        printf 'This session has commits that look **system-level** (security, '
        # shellcheck disable=SC2016  # backticks are literal markdown code spans in the output
        printf 'scaffold, topology, migration, roles) but `%s` was **not touched**.\n' "$systemlog_relpath"
        printf 'If any of these changed the system'\''s shape, add a What/Why/Fix/Where '
        printf 'entry before handing off:\n\n'
        # shellcheck disable=SC2016  # backticks are a literal markdown code fence in the output
        printf '```\n%s\n```\n\n' "$range_commits"
      fi
    fi
  fi

  # Rules / fences section (issue #42). The /handoff skill may replace the
  # placeholder comment with explicit, deliberate scope fences ("do NOT begin
  # X without a fresh decision"). ONLY content inside the BIND markers ever
  # loads with binding framing — model-authored Notes below never do, so a
  # stray "next session should..." sentence can't become law — and even
  # marked content binds only when the document's provenance verifies.
  printf '%s\n' "$HANDOFF_BIND_BEGIN"
  printf '## Rules (fences — carried into the next session)\n\n'
  printf '<!-- HANDOFF_RULES_PLACEHOLDER: /handoff may replace this comment with explicit scope fences. Only content inside the BIND markers loads as binding (and only when provenance verifies); leave this comment in place for none. -->\n'
  printf '%s\n' "$HANDOFF_BIND_END"
  printf '\n'
  echo '---'
  echo
  printf '## Notes from this session\n\n'
  printf '%s\n' "$HANDOFF_PLACEHOLDER_SENTINEL"
  printf '\n'
  printf '_The /handoff skill should replace this entire block (sentinel\n'
  printf 'comment included) with curated decisions, in-flight tracks, open\n'
  printf 'questions, and "next session should start with X" notes. The auto-\n'
  printf 'snapshot above captures git state; the prose below captures intent\n'
  printf 'that only the conversation knows. The sentinel above is how the\n'
  printf 'SessionEnd safety-net detects whether curation has happened._\n'
} > "$handoff_tmp"

# Provenance stamp (issue #42): HMAC-SHA256 the fully-built document with the
# per-machine secret (auto-generated on first use, 0600, never in any repo)
# and embed the digest as a trailer line. The next session's loader recomputes
# it over content-minus-trailer; a match plus the untracked check proves the
# file was written HERE, not delivered by a clone, and unlocks binding framing
# for the BIND-marked rules regions. Degrades silently-to-stderr when signing
# isn't possible — an unsigned handoff loads exactly as today (data framing);
# this must NEVER abort the write.
if can_sign; then
  if mac="$(handoff_mac_compute "$handoff_tmp" ensure)"; then
    printf '%s%s -->\n' "$HANDOFF_MAC_PREFIX" "$mac" >> "$handoff_tmp"
  else
    echo "write_handoff.sh: openssl or the per-machine secret unavailable — handoff not signed; the rules layer will load as reference data, not binding." >&2
  fi
fi

# Tighten before publishing (umask already makes it 0600 at creation; this also
# covers a tmp produced under an unusual umask). The prose may include secrets.
chmod 600 "$handoff_tmp" 2>/dev/null || true

# ----- Whole-run write lock: rotation through publish ------------------------
# Two concurrent runs (SessionEnd + PreCompact firing together, or two
# sessions open in one repo) interleave rotation and publish: each individual
# mv is atomic, but the rotate→prune→publish SEQUENCE is not — writer B can
# rotate away the document writer A published a moment earlier, silently
# losing a snapshot. Serialize the whole destructive window behind
# <root>/.claude/.handoff_write.lock. The doc build above deliberately runs
# UNLOCKED: it only reads, and holding the lock through slow git commands
# would starve the other writer's brief wait below.
write_lock_dir="$handoff_dir/.handoff_write.lock"
if try_mkdir_lock "$write_lock_dir"; then
  write_lock_held=1
elif (( IF_CURATED )); then
  # Hook (safety-net) run: another writer is mid-write, and its snapshot of
  # this same repo state does the job — a second mechanical snapshot adds
  # nothing worth contending for. Exit 0 like the other safety-net skips
  # (the built tmp is discarded by the cleanup trap).
  echo "$handoff_path"
  exit 0
else
  # Explicit (/handoff or manual) run: the user asked for THIS write, so
  # never deadlock it. Wait briefly — a competing hook fire finishes in well
  # under a second — then proceed unlocked with a warning: a possibly-racy
  # write beats silently dropping the write the user is about to curate.
  # `sleep 0.2` works on GNU and BSD/macOS sleep; the `|| sleep 1` fallback
  # covers a strictly-integer POSIX sleep.
  for _ in 1 2 3 4 5; do
    sleep 0.2 2>/dev/null || sleep 1
    if try_mkdir_lock "$write_lock_dir"; then
      write_lock_held=1
      break
    fi
  done
  if (( ! write_lock_held )); then
    echo "write_handoff.sh: write lock $write_lock_dir still held after ~1s; proceeding without it (an explicit run must not deadlock)." >&2
  fi
fi

# Rotate the previous handoff only NOW that its replacement is fully built.
# Any failure during the doc build above leaves handoff_current.md untouched
# (the EXIT trap just removes the tmp); the destructive window is reduced to
# the two renames here and below — and is serialized by the write lock.
rotate_existing_handoff
prune_history || true   # a prune failure must never abort the handoff write

# Atomic, symlink-safe publish: mv replaces the destination NAME, so it can't be
# made to write through a symlink that reappears after the guard above (TOCTOU),
# and a crash mid-write can't leave a half-written handoff_current.md.
mv -f "$handoff_tmp" "$handoff_path"

# Normal-path lock release; the cleanup trap is only the abort backstop.
if (( write_lock_held )); then
  rmdir "$write_lock_dir" 2>/dev/null || true
  write_lock_held=0
fi

echo "$handoff_path"
