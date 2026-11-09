#!/usr/bin/env bash
# GENERATED FILE — do not edit directly.
#
# This is the concatenation of install.d/*.sh, produced by
# tools/build-install.sh. To change installer behavior, edit the relevant
# module under install.d/, then regenerate with:
#
#   bash tools/build-install.sh
#
# CI's install-drift job rebuilds this file into a temp path and diffs it
# against the committed copy below; a stale install.sh fails that gate.
# SOURCE-SHA256: e039bab80097539c3b198a0ed70a24715796adeeb2523e9f941ad74472250326
# install.sh — wire this repo's handoff skill into ~/.claude/.
#
# Full behavior/usage summary lives in usage() below — that heredoc is the
# single source of truth for `install.sh --help`, so it stays in sync with
# reality by construction instead of by discipline. Read it there, or just
# run `./install.sh --help`.

set -euo pipefail

# Usage text for --help / -h. A heredoc (not a self-read of this file's
# comments) so it works no matter how the script's bytes arrived: piped in
# via `curl ... | bash -s -- --help`
# — BASH_SOURCE[0] is "bash" (there is no real path to sed), so a self-read
# prints nothing. A heredoc is parsed out of the script text itself and
# needs no path or working stdin.
usage() {
  cat <<'USAGE'
install.sh — wire this repo's handoff skill into ~/.claude/.

What it does:
  1. Symlinks (or copies, where symlinks aren't available — e.g. Git
     Bash on Windows) bin/ scripts + skills/* into ~/.claude/.
  2. Patches ~/.claude/settings.json to add six hooks
     (SessionStart / SessionEnd / PreCompact / PostCompact / WorktreeRemove / Stop /
     UserPromptSubmit), six permission entries, and — only when you
     don't already have one — a statusLine command (never overwrites
     an existing statusLine; prints the manual step instead).
     Requires jq; falls back to printing the snippet if jq is missing.

Idempotent. Existing files at symlink targets are backed up to
<path>.bak.<timestamp> before being replaced. Existing settings.json
is backed up the same way before any patch. Re-runs are safe and only
touch what's actually missing.

Installing from a volatile path (a /tmp worktree, git-archive extract, CI
scratch) auto-switches to copy mode, since symlinks into it would dangle once
it's cleaned up and the hooks would then fail silently. Override with --link.

Usage:
  ./install.sh              # install (symlink from a persistent clone, else copy)
  ./install.sh --copy       # force copy mode (good for ephemeral sources)
  ./install.sh --link       # force symlinks even from a volatile path
  ./install.sh --model 'opus[1m]'  # also pin "model" in settings.json (env: HANDOFF_MODEL)
  ./install.sh --doctor     # report any dangling/missing installed hooks
  ./install.sh --uninstall  # remove symlinks + strip patched entries
  ./install.sh --uninstall --keep-secret  # same, but keep the per-machine HMAC secret
  ./install.sh --help

Scope (where the hooks are wired):
  --scope user       patch ~/.claude/settings.json (the default; every project)
  --scope project    patch <project>/.claude/settings.json (one project only);
                     the project is --project <dir>, else the current directory
  --project <dir>    the project to wire; implies --scope project
  --local            with project scope, patch .claude/settings.local.json
                     instead of .claude/settings.json

  Recommended (one project only):
    ./install.sh --scope project --project ~/code/myapp

  Project scope still installs the scripts and skills into ~/.claude, since
  every project shares them. --uninstall and --doctor take the same scope
  flags: a project-scope --uninstall strips only that project's settings
  file and leaves ~/.claude/bin, the skills, and the HMAC secret in place.
  The project must be an existing directory, and may not be this clone.

--keep-secret only changes what --uninstall does. It is still accepted
without --uninstall (plain install, --doctor) so a script that always
passes it doesn't have to branch on mode, but it has no effect there and
prints a one-line warning saying so.
USAGE
}

# Everything this installer creates under $claude_home — settings.json and its
# backups, the bin/skills copies (copy-mode installs), and the dirs themselves —
# is per-user state that can carry secrets (settings.json may hold env tokens).
# umask 077 makes all of it owner-only at creation; symlink *targets* are
# unaffected, and hooks run via `bash <path>` so the copies need no exec bit.
umask 077

# `2>/dev/null` + `|| repo_root=""` fallback: same guard bin/*.sh already uses
# around every other BASH_SOURCE[0] resolution in this repo. Needed here too —
# under `curl ... | bash -s -- --help`, BASH_SOURCE[0] has no element to read,
# which trips `set -u` as "unbound variable" and prints it to stderr before
# this line's own fallback is reached. `--help`/`-h` (parsed further below)
# exits via usage() before repo_root is ever used, so an empty fallback here
# is safe for that path; every other invocation shape still resolves a real
# BASH_SOURCE[0] and this fallback never engages.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || repo_root=""
claude_home="${CLAUDE_HOME:-$HOME/.claude}"
settings="$claude_home/settings.json"
# The user-scope file, kept separately because project scope (issue #171)
# repoints $settings at a project file while doctor still needs this one for
# its double-fire check.
user_settings="$settings"

# Install scope (issue #171). "user" patches $claude_home/settings.json, the
# behaviour every release before this one had, and stays the default so an
# existing install never changes under anyone's feet. "project" patches
# <project>/.claude/settings.json (or settings.local.json with --local)
# instead; the scripts and skills still go into $claude_home either way,
# because the hook commands point at $HOME/.claude/bin. scope_flag records
# an explicit --scope so a contradiction with --project/--local is refused
# rather than guessed at.
scope=user
scope_flag=""
project_dir=""
use_local=0
# Include the PID so two installs in the same clock second don't collide on the
# same .bak.<ts> name — without it, the second run's `cp` would overwrite the
# first run's pre-patch settings.json backup, destroying the only safe copy.
ts="$(date +%Y%m%d_%H%M%S)_$$"
mode=install

# Optional model pin (--model / HANDOFF_MODEL, flag wins). Opaque string,
# passed through verbatim — never validated against a model list, and never
# defaulted: this repo is installed by other people too, so the pin is always
# explicit user input. Empty means "no pin requested".
model_pin=""

# Link strategy. "auto" symlinks from a persistent source and copies from a
# volatile one (see is_volatile_path below); --copy / --link force the choice,
# and HANDOFF_FORCE_SYMLINK=1 is an escape hatch for the volatile auto-copy.
link_mode="auto"

# --uninstall --keep-secret (issue #65): preserve the per-machine HMAC secret
# instead of deleting it. Only consulted by remove_secret_if_ours() in
# install mode "uninstall" (harmless, and unused, with any other mode). The
# secret is per-machine identity, not per-install state: a user who runs a
# user-scope --uninstall before reinstalling (for example to move the
# wiring from user scope to --scope project) would, without this flag,
# silently invalidate every already-signed handoff_current.md: the
# HANDOFF_BIND_BEGIN/END rules block stops verifying and downgrades to
# reference data with no error, no prompt, nothing in the diff. Default stays
# "delete" (unchanged, opt-in only) because the secret is also genuinely
# uninstall-scoped key material for someone leaving the tool entirely.
keep_secret=0

# Validate $claude_home before creating or patching anything under it: an empty,
# root, or relative value would scatter symlinks and a patched settings.json
# into unintended places. Require an absolute path other than '/'. A path
# outside $HOME is permitted (the test suite and some shared setups point it at
# a temp dir) but warned about, since it's unusual and easy to mistype.
case "$claude_home" in
  "" | "/")
    echo "ERROR: CLAUDE_HOME='$claude_home' is empty or root — refusing to operate there." >&2
    exit 2 ;;
  /*) : ;;
  *)
    echo "ERROR: CLAUDE_HOME='$claude_home' is not an absolute path — refusing." >&2
    exit 2 ;;
esac
if [[ -n "${HOME:-}" && "$claude_home" != "$HOME" && "$claude_home" != "$HOME"/* ]]; then
  echo "warning: CLAUDE_HOME='$claude_home' is outside \$HOME ($HOME); proceeding." >&2
fi

# If settings.json is a symlink (a common dotfiles pattern — stow/chezmoi/etc.
# point ~/.claude/settings.json at a tracked file), operate on its TARGET. The
# patch writes via tmp+mv, and `mv` onto a symlink replaces the LINK with a plain
# file — silently disconnecting the user's source-of-truth. Resolving to the real
# path keeps tmp+mv atomic AND leaves the symlink intact (Claude Code follows it
# to read). Portable manual resolve (readlink -f is GNU-only), capped against
# loops, falling back to the link path itself.
resolve_symlink() {  # <path> -> physical path on stdout
  local p="$1" n=0 t
  while [[ -L "$p" ]] && (( n++ < 40 )); do
    t="$(readlink "$p")" || break
    case "$t" in
      /*) p="$t" ;;
      *)  p="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)/$t" ;;
    esac
  done
  printf '%s\n' "$p"
}
# (The symlink check itself runs after argument parsing, below, because
# --scope project repoints $settings at a project file first.)

# Recovery state for the settings.json patch/unpatch sequence. The edits are a
# series of separate jq writes; if the script aborts (set -e) partway through,
# the EXIT trap both removes any half-written temp AND restores settings.json
# from the backup taken before the first edit — so a mid-sequence failure can't
# leave a half-patched (or corrupted) settings.json behind. patch_in_progress is
# armed only between the backup and the successful end of the sequence.
settings_backup=""
patch_in_progress=0
cleanup() {
  local rc=$?
  rm -f "$settings.tmp" 2>/dev/null || true
  if (( patch_in_progress )) && (( rc != 0 )) \
     && [[ -n "$settings_backup" && -f "$settings_backup" ]]; then
    cp -f "$settings_backup" "$settings" 2>/dev/null || true
    echo "  restore $settings from $settings_backup (aborted mid-patch, rc=$rc)" >&2
  fi
}
# NOT armed here. A piped `curl | bash` executes top-level statements as they
# parse, and on bash 3.2 a stream that truncates AFTER `trap ... EXIT` is
# armed exits 0 on the resulting syntax error (set -e + EXIT trap swallow the
# parse-error status; the trap sees $? = 0, so re-raising doesn't help).
# Arming instead as the first statement of the dispatch group in 40-main.sh
# means the trap only takes effect once that whole compound has parsed —
# truncation anywhere inside it dies with bash's own rc=2, and no work
# (so nothing needing cleanup) can have run before the trap is live.

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall)   mode=uninstall ;;
    --doctor)      mode=doctor ;;
    --copy)        link_mode=copy ;;
    --link)        link_mode='link' ;;
    --keep-secret) keep_secret=1 ;;
    --model)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "ERROR: --model requires a value (e.g. --model 'opus[1m]')" >&2
        exit 2
      fi
      model_pin="$2"; shift ;;
    --model=*)   model_pin="${1#--model=}" ;;
    --scope)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "ERROR: --scope requires a value: user or project" >&2
        exit 2
      fi
      scope_flag="$2"; shift ;;
    --scope=*)   scope_flag="${1#--scope=}" ;;
    --project)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "ERROR: --project requires a directory (e.g. --project ~/code/myapp)" >&2
        exit 2
      fi
      project_dir="$2"; shift ;;
    --project=*)
      project_dir="${1#--project=}"
      if [[ -z "$project_dir" ]]; then
        echo "ERROR: --project requires a directory (e.g. --project ~/code/myapp)" >&2
        exit 2
      fi
      ;;
    --local)     use_local=1 ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# --keep-secret only does anything in remove_secret_if_ours(), which only
# runs in uninstall mode (see the flag's own comment above). Accepted in
# every mode regardless (a script that always passes it shouldn't have to
# branch on which mode it's calling), but silently ignoring it in the other
# two modes would let a user believe a plain install or --doctor run had
# preserved something it never touched (issue #82): warn instead.
if (( keep_secret )) && [[ "$mode" != uninstall ]]; then
  echo "warning: --keep-secret has no effect in $mode mode; it only changes what --uninstall does." >&2
fi

# Resolve the install scope (issue #171). Every refusal here exits before
# anything is created or patched.
case "$scope_flag" in
  "" | user | project) : ;;
  *)
    echo "ERROR: --scope must be 'user' or 'project' (got '$scope_flag')." >&2
    exit 2 ;;
esac
if [[ -n "$project_dir" ]]; then
  if [[ "$scope_flag" == user ]]; then
    echo "ERROR: --project implies --scope project; it cannot be combined with --scope user." >&2
    exit 2
  fi
  scope=project
elif [[ "$scope_flag" == project ]]; then
  scope=project
fi
if (( use_local )) && [[ "$scope" != project ]]; then
  echo "ERROR: --local only applies to project scope; add --scope project or --project <dir>." >&2
  exit 2
fi
if [[ "$scope" == project ]]; then
  # No --project: the current directory, the natural shape for
  # `cd ~/code/myapp && ~/src/claude-code-handoff/install.sh --scope project`.
  [[ -n "$project_dir" ]] || project_dir="$PWD"
  if [[ ! -d "$project_dir" ]]; then
    echo "ERROR: project directory '$project_dir' does not exist or is not a directory; refusing." >&2
    exit 2
  fi
  # Absolute and physical, so the comparisons below and the paths printed
  # (and the backup location) never depend on how the flag was spelled.
  project_dir="$(cd "$project_dir" && pwd -P)"
  # Wiring the handoff clone itself is almost certainly a mistake: the usual
  # cause is running `./install.sh --scope project` from inside the clone
  # without --project. Refuse instead of patching the clone's own .claude/.
  if [[ -n "$repo_root" ]] && [[ "$project_dir" == "$(cd "$repo_root" && pwd -P)" ]]; then
    echo "ERROR: project directory '$project_dir' is this handoff clone (the install source); refusing." >&2
    echo "       Pass --project <dir> for the project you want to wire, or run install.sh from inside that project." >&2
    exit 2
  fi
  # A project whose .claude/ IS $claude_home (a project rooted at $HOME)
  # would make the "project" file the user-scope file under another name.
  _proj_claude="$project_dir/.claude"
  # (Plain string compare too, for a fresh machine where neither exists yet.)
  if [[ "$_proj_claude" == "$claude_home" ]] \
     || { [[ -d "$_proj_claude" && -d "$claude_home" ]] \
          && [[ "$(cd "$_proj_claude" && pwd -P)" == "$(cd "$claude_home" && pwd -P)" ]]; }; then
    echo "ERROR: project '$project_dir' has $claude_home as its .claude directory, which is the user-scope config; refusing." >&2
    echo "       Use --scope user to patch $user_settings." >&2
    exit 2
  fi
  if (( use_local )); then
    settings="$_proj_claude/settings.local.json"
  else
    settings="$_proj_claude/settings.json"
  fi
  # A project-scope --uninstall never touches the secret (see 40-main.sh),
  # so --keep-secret is a no-op there too; say so, same as issue #82.
  if (( keep_secret )) && [[ "$mode" == uninstall ]]; then
    echo "warning: --keep-secret has no effect with --scope project; a project-scope --uninstall never removes the secret." >&2
  fi
fi

# Env fallback for the model pin; an explicit --model flag wins.
if [[ -z "$model_pin" && -n "${HANDOFF_MODEL:-}" ]]; then
  model_pin="$HANDOFF_MODEL"
fi

# Where a model pin WE wrote is recorded, so --uninstall can be an exact
# inverse: the key is removed only when this installer set it AND the value
# is still exactly what it set — a user's later edit always wins.
model_pin_record="$claude_home/handoff-model-pin"
# Project scope keeps one record per project settings file (keyed by a cksum
# of its path), so a project's --uninstall can never consume the user-scope
# record or another project's. Computed before the symlink resolution below
# so the key is the path the user named, not wherever a dotfiles link points.
if [[ "$scope" == project ]]; then
  model_pin_record="$claude_home/handoff-model-pin.project.$(printf '%s' "$settings" | cksum | awk '{print $1}')"
fi

# If the settings file is a symlink (a common dotfiles pattern; stow, chezmoi
# and friends point ~/.claude/settings.json at a tracked file), operate on its
# TARGET. The patch writes via tmp+mv, and `mv` onto a symlink replaces the
# LINK with a plain file, silently disconnecting the user's source of truth.
# Resolving to the real path keeps tmp+mv atomic AND leaves the symlink intact
# (Claude Code follows it to read). Applies to a project file the same way.
if [[ -L "$settings" ]]; then
  settings_resolved="$(resolve_symlink "$settings")"
  echo "note: $settings is a symlink -> $settings_resolved; patching the target (symlink left intact)." >&2
  settings="$settings_resolved"
fi

# Canonical hook commands and permissions. Edit these together with
# CHANGELOG.md if you ever change the snippet shape.
# shellcheck disable=SC2016  # $HOME is intentionally literal: the string is stored verbatim in settings.json and expanded when the hook fires, not at install time
{
  ss_cmd='bash $HOME/.claude/bin/handoff_session_start.sh 2>/dev/null || true'
  se_cmd='bash $HOME/.claude/bin/write_handoff.sh --if-curated >/dev/null 2>&1 || true'
  st_cmd='bash $HOME/.claude/bin/handoff_turn_append.sh 2>/dev/null || true'
  up_cmd='bash $HOME/.claude/bin/handoff_ctx_check.sh 2>/dev/null || true'
  # PreCompact reuses the SessionEnd command verbatim (same safety net, same
  # marker for detection/removal): compaction destroys conversational context
  # just like a session ending does — and SessionEnd hooks are skipped on a
  # crash, so the pre-compact checkpoint matters. Installed with NO matcher so
  # it fires on both auto and manual compaction: the matcher field's payload
  # semantics on older CC builds are unverified, and an entry without one is
  # the only shape guaranteed to behave identically everywhere (worst case is
  # firing on both — which is what we want anyway; --if-curated makes it a
  # no-op when curated content exists).
  pc_cmd="$se_cmd"
  # PostCompact: clear the per-session ctx sidecars so the freed window is
  # treated as session-start fresh (stale-high numbers can't nudge, and the
  # once-per-session nudge cap re-arms). Only fires on CC >= 2.1.76.
  post_cmd='bash $HOME/.claude/bin/handoff_compact_reset.sh 2>/dev/null || true'
  # WorktreeRemove (#142): salvage a removed worktree's handoff and raw dumps
  # into the main checkout. Fires on CC >= 2.1.300, only for worktrees Claude
  # Code created; older builds simply never fire it.
  wr_cmd='bash $HOME/.claude/bin/handoff_worktree_remove.sh 2>/dev/null || true'
  # statusLine command. No `|| true` here, unlike the hooks: stdout IS the
  # product (the rendered line), and a nonzero exit just blanks the line — there
  # is no hook pipeline to poison.
  sl_cmd='bash $HOME/.claude/bin/handoff_statusline.sh 2>/dev/null'
}
perm_write="Bash(bash $HOME/.claude/bin/write_handoff.sh)"
perm_stop="Bash(bash $HOME/.claude/bin/handoff_turn_append.sh)"
perm_ctx="Bash(bash $HOME/.claude/bin/handoff_ctx_check.sh)"
perm_ss="Bash(bash $HOME/.claude/bin/handoff_session_start.sh)"
# Consistency with the four above (handoff_session_start already set the
# precedent of allowlisting a hook-only script): harmless if never used.
perm_sl="Bash(bash $HOME/.claude/bin/handoff_statusline.sh)"
perm_reset="Bash(bash $HOME/.claude/bin/handoff_compact_reset.sh)"
perm_wr="Bash(bash $HOME/.claude/bin/handoff_worktree_remove.sh)"

# Marker substrings used to detect prior installs (and to remove on uninstall).
# These are the full installed command path (literal $HOME, exactly as stored in
# the command string) — NOT the bare filename — so detection and removal can't
# false-match a user's own unrelated hook that merely mentions the script name
# (e.g. a wrapper called "my_handoff_turn_append.sh"). Every version of this
# installer wrote the command with this path, so the match stays backward-
# compatible. The permission entries already match by exact string.
# shellcheck disable=SC2016  # $HOME / $f are intentionally literal: markers must match the exact stored hook strings, no expansion wanted
{
  ss_marker='$HOME/.claude/bin/handoff_session_start.sh'
  # Legacy marker — pre-0.3.0 SessionStart was an inline bash one-liner that
  # cat'd handoff_current.md directly. We detect it (substring unique to the
  # inline form, not present in the new script-call form) and migrate it out
  # on re-install so users don't end up with both hooks firing.
  ss_legacy_marker='if [ -f "$f" ]; then echo'
  se_marker='$HOME/.claude/bin/write_handoff.sh'
  st_marker='$HOME/.claude/bin/handoff_turn_append.sh'
  up_marker='$HOME/.claude/bin/handoff_ctx_check.sh'
  sl_marker='$HOME/.claude/bin/handoff_statusline.sh'
  post_marker='$HOME/.claude/bin/handoff_compact_reset.sh'
  wr_marker='$HOME/.claude/bin/handoff_worktree_remove.sh'
}

# -------------------------------------------------------------------- symlinks

# Set when symlinks aren't available and we fall back to copying, so the
# installer can remind the user that copies don't auto-update on git pull.
COPIED_ANY=0

# A "volatile" repo_root is one likely to be deleted out from under us — a
# /tmp worktree, a `git archive` extract, a CI scratch dir. Symlinking from
# there leaves every ~/.claude/bin/*.sh dangling once it's cleaned up, and the
# hooks then no-op silently (issue #21). Heuristics: under /tmp, /var/tmp,
# /dev/shm, or $TMPDIR; or any path component that looks like an mktemp dir
# (tmp.XXXX). A persistent clone like /mnt/ddrive/handoff matches none of these.
#
# Both the LOGICAL path and its physical (`pwd -P`) form are matched: on macOS
# /tmp and /var are symlinks to /private/tmp and /private/var, so an installer
# invoked via the canonical path (`bash /private/tmp/handoff/install.sh`, or
# any caller that ran the path through realpath) used to sail past the literal
# patterns and get symlink mode — reintroducing the dangling-link failure this
# guard exists to prevent. The /private/* and /var/folders/* spellings (macOS
# per-user temp, i.e. $TMPDIR's real location) are also matched explicitly so
# detection works even when TMPDIR is unset (launchd/cron/CI contexts), and
# TMPDIR itself is compared in both its logical and physical forms.
is_volatile_path() {
  local p="$1" phys cand
  phys="$(cd "$p" 2>/dev/null && pwd -P)" || phys=""
  for cand in "$p" "$phys"; do
    [[ -n "$cand" ]] || continue
    case "$cand" in
      /tmp|/tmp/*|/var/tmp|/var/tmp/*|/dev/shm/*) return 0 ;;
      /private/tmp|/private/tmp/*|/private/var/tmp|/private/var/tmp/*) return 0 ;;
      /var/folders/*|/private/var/folders/*) return 0 ;;
      */tmp.*) return 0 ;;
    esac
  done
  if [[ -n "${TMPDIR:-}" ]]; then
    local t="${TMPDIR%/}" tphys
    tphys="$(cd "$t" 2>/dev/null && pwd -P)" || tphys=""
    for cand in "$t" "$tphys"; do
      [[ -n "$cand" ]] || continue
      if [[ "$p" == "$cand" || "$p" == "$cand"/* \
            || ( -n "$phys" && ( "$phys" == "$cand" || "$phys" == "$cand"/* ) ) ]]; then
        return 0
      fi
    done
  fi
  return 1
}

# Decide symlink vs copy. --copy/--link are explicit; "auto" copies from a
# volatile source (copies survive its cleanup) and symlinks otherwise. The
# volatile auto-copy can be overridden with HANDOFF_FORCE_SYMLINK=1 (or --link).
force_copy=0
case "$link_mode" in
  copy) force_copy=1 ;;
  link) force_copy=0 ;;
  auto)
    if is_volatile_path "$repo_root" && [[ "${HANDOFF_FORCE_SYMLINK:-0}" != "1" ]]; then
      force_copy=1
      echo "warning: installing from a volatile path ($repo_root)." >&2
      echo "         Symlinks would dangle when it's cleaned up and the hooks would" >&2
      echo "         then fail silently — using COPY mode instead (the copies survive)." >&2
      echo "         Re-run from a persistent clone for auto-updating symlinks, or pass" >&2
      echo "         --link / HANDOFF_FORCE_SYMLINK=1 to force symlinks anyway." >&2
    fi
    ;;
esac

# Append a durable record of a symlink we replaced that pointed somewhere the
# user chose, so their original wiring can always be recovered. (#45)
#
# Append-only by contract: if the log already exists we ADD a line and never
# rewrite or truncate it — the file may hold records from earlier installs the
# user still needs, and it is not ours to prune. A fresh file is created 0600
# (it records paths from the user's home). Best-effort throughout: a failure to
# write the log must never abort an install, so every step is guarded and the
# old target is still echoed to stdout as before.
record_replaced_link() {  # <dst> <old_target>
  local dst="$1" old="$2" log="$claude_home/handoff-install.log" existed=1
  [[ -e "$log" ]] || existed=0
  # Never write through a symlinked log (it could point at a file of theirs).
  if [[ -L "$log" ]]; then
    echo "          (note: $log is a symlink; not recording the old target there)"
    return 0
  fi
  if printf '%s\treplaced symlink %s\n\t\twas -> %s\n' \
       "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$dst" "$old" >> "$log" 2>/dev/null; then
    (( existed )) || chmod 600 "$log" 2>/dev/null || true
    echo "          recorded old target in $log"
  else
    echo "          (note: could not write $log; old target above is the only record)"
  fi
  return 0
}

link() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [[ -L "$dst" ]]; then
    local current
    current="$(readlink "$dst")"
    if [[ "$current" == "$src" ]] && (( ! force_copy )); then
      echo "  ok      $dst -> $src"
      return
    fi
    # In copy mode, an existing symlink (even one pointing at src) must be
    # replaced by a real copy, so don't early-return above.
    echo "  relink  $dst (was -> $current)"
    # A symlink pointing SOMEWHERE ELSE is the user's own wiring (a customized
    # fork, a second clone, a dotfiles manager). A regular file in that position
    # gets a .bak.<ts>; a symlink used to be removed with the old target
    # recorded only on stdout — gone the moment that scrolled past, or
    # immediately if the installer ran with output redirected. Append a durable
    # note first so the wiring is always recoverable. Same-target relinks (the
    # ordinary copy-mode case) record nothing. (#45)
    if [[ "$current" != "$src" ]]; then
      record_replaced_link "$dst" "$current"
    fi
    rm "$dst"
  elif [[ -e "$dst" ]]; then
    # A regular file identical to src is our own copy-mode install from a
    # prior run — treat as up to date rather than backing it up each time.
    if [[ -f "$dst" && ! -L "$dst" ]] && cmp -s "$src" "$dst"; then
      echo "  ok      $dst (copy)"
      return
    fi
    echo "  backup  $dst -> $dst.bak.$ts"
    mv "$dst" "$dst.bak.$ts"
  else
    echo "  new     $dst"
  fi
  # Prefer a real symlink unless copy mode was chosen (volatile source or
  # --copy). Otherwise fall back to copying when the platform can't make one:
  # Git Bash on Windows without Developer Mode either errors on ln -s or
  # silently copies — the -L check catches the silent-copy case too.
  if (( ! force_copy )) && ln -s "$src" "$dst" 2>/dev/null && [[ -L "$dst" ]]; then
    return
  fi
  rm -f "$dst"
  cp "$src" "$dst"
  COPIED_ANY=1
  if (( force_copy )); then
    echo "  copy    $dst (copy mode — re-run install.sh after updates)"
  else
    echo "  copy    $dst (symlinks unavailable — re-run install.sh after updates)"
  fi
}

unlink_if_ours() {
  local dst="$1" src="$2"
  if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then
    rm "$dst"
    echo "  remove  $dst"
  elif [[ -L "$dst" && ! -e "$dst" ]]; then
    # Dangling symlink at our canonical install path — a stale install from a
    # clone that was moved/removed, so its target no longer exists (and may point
    # at a DIFFERENT path than this run's $src, which is why the exact-match
    # branch above misses it). Safe to remove: nothing live sits behind a broken
    # link, and a user would not place their own link here. Without this it was
    # reported "already absent" and left behind. (install#1)
    echo "  remove  $dst (stale dangling link -> $(readlink "$dst"))"
    rm "$dst"
  elif [[ -f "$dst" && ! -L "$dst" ]] && cmp -s "$src" "$dst"; then
    # Copy-mode install (identical content) — ours to remove.
    rm "$dst"
    echo "  remove  $dst (copy)"
  elif [[ -e "$dst" ]]; then
    echo "  skip    $dst (not ours; leaving alone)"
  else
    echo "  ok      $dst (already absent)"
  fi
}

install_symlinks() {
  link "$repo_root/bin/write_handoff.sh"          "$claude_home/bin/write_handoff.sh"
  link "$repo_root/bin/handoff_turn_append.sh"    "$claude_home/bin/handoff_turn_append.sh"
  link "$repo_root/bin/handoff_ctx_check.sh"      "$claude_home/bin/handoff_ctx_check.sh"
  link "$repo_root/bin/handoff_session_start.sh"  "$claude_home/bin/handoff_session_start.sh"
  link "$repo_root/bin/handoff_recover_tail.sh"   "$claude_home/bin/handoff_recover_tail.sh"
  link "$repo_root/bin/handoff_statusline.sh"     "$claude_home/bin/handoff_statusline.sh"
  link "$repo_root/bin/handoff_compact_reset.sh"  "$claude_home/bin/handoff_compact_reset.sh"
  link "$repo_root/bin/handoff_worktree_remove.sh" "$claude_home/bin/handoff_worktree_remove.sh"
  link "$repo_root/bin/handoff_provenance.sh"     "$claude_home/bin/handoff_provenance.sh"
  link "$repo_root/skills/handoff/SKILL.md"          "$claude_home/skills/handoff/SKILL.md"
  link "$repo_root/skills/handoff/README.md"         "$claude_home/skills/handoff/README.md"
  link "$repo_root/skills/handoff-more/SKILL.md"     "$claude_home/skills/handoff-more/SKILL.md"
  link "$repo_root/skills/handoff-recover/SKILL.md"  "$claude_home/skills/handoff-recover/SKILL.md"
  # Best-effort: the scripts are committed mode 0755, so a normal checkout is
  # already executable. This rescues filesystems that don't preserve the exec
  # bit (e.g. NTFS). It must never abort the install — under set -e a chmod on
  # source files the running user doesn't own (e.g. a forge user installing
  # from chris-owned files) would otherwise fail and skip patch_settings.
  # (handoff_provenance.sh is deliberately NOT in this list: it is a sourced
  # library, never executed, so it needs no exec bit.)
  chmod +x "$repo_root/bin/write_handoff.sh" \
           "$repo_root/bin/handoff_turn_append.sh" \
           "$repo_root/bin/handoff_ctx_check.sh" \
           "$repo_root/bin/handoff_session_start.sh" \
           "$repo_root/bin/handoff_recover_tail.sh" \
           "$repo_root/bin/handoff_statusline.sh" \
           "$repo_root/bin/handoff_compact_reset.sh" \
           "$repo_root/bin/handoff_worktree_remove.sh" 2>/dev/null || true
}

uninstall_symlinks() {
  unlink_if_ours "$claude_home/bin/write_handoff.sh"          "$repo_root/bin/write_handoff.sh"
  unlink_if_ours "$claude_home/bin/handoff_turn_append.sh"    "$repo_root/bin/handoff_turn_append.sh"
  unlink_if_ours "$claude_home/bin/handoff_ctx_check.sh"      "$repo_root/bin/handoff_ctx_check.sh"
  unlink_if_ours "$claude_home/bin/handoff_session_start.sh"  "$repo_root/bin/handoff_session_start.sh"
  unlink_if_ours "$claude_home/bin/handoff_recover_tail.sh"   "$repo_root/bin/handoff_recover_tail.sh"
  unlink_if_ours "$claude_home/bin/handoff_statusline.sh"     "$repo_root/bin/handoff_statusline.sh"
  unlink_if_ours "$claude_home/bin/handoff_compact_reset.sh"  "$repo_root/bin/handoff_compact_reset.sh"
  unlink_if_ours "$claude_home/bin/handoff_worktree_remove.sh" "$repo_root/bin/handoff_worktree_remove.sh"
  unlink_if_ours "$claude_home/bin/handoff_provenance.sh"     "$repo_root/bin/handoff_provenance.sh"
  unlink_if_ours "$claude_home/skills/handoff/SKILL.md"          "$repo_root/skills/handoff/SKILL.md"
  unlink_if_ours "$claude_home/skills/handoff/README.md"         "$repo_root/skills/handoff/README.md"
  unlink_if_ours "$claude_home/skills/handoff-more/SKILL.md"     "$repo_root/skills/handoff-more/SKILL.md"
  unlink_if_ours "$claude_home/skills/handoff-recover/SKILL.md"  "$repo_root/skills/handoff-recover/SKILL.md"
  # Tidy up now-empty leaf dirs we created. `rmdir` only removes a directory
  # that is ALREADY empty (fails harmlessly otherwise) — never `rm -r` — so
  # this can never touch a dir the user left files in (their own script
  # dropped alongside ours, a co-located skill, etc.). Order matters: each
  # skills/<name>/ dir first, then skills/ itself (which only empties out
  # once its subdirs are gone), then bin/. Best-effort and silent: rmdir's
  # own semantics ("empty or untouched") already say everything worth saying.
  local d
  for d in "$claude_home/skills/handoff" "$claude_home/skills/handoff-more" \
           "$claude_home/skills/handoff-recover" "$claude_home/skills" \
           "$claude_home/bin"; do
    rmdir "$d" 2>/dev/null || true
  done
}

# Remove the per-machine HMAC secret that write_handoff.sh generates on first
# signed write (issue #42), so --uninstall is a true inverse and no key
# material is left behind by a tool the user believes they removed.
#
# Deliberately conservative — this is the ONE path where uninstall deletes a
# file the installer never created itself, so it must prove the file is ours
# before touching it. Any doubt => leave it and say so:
#   - only the DEFAULT path under $claude_home. A HANDOFF_SECRET_FILE override
#     may point at a shared/managed location that is not ours to delete.
#   - never a symlink (don't follow it, don't remove it — the target could be
#     anything the user cares about).
#   - only a regular file whose entire content is the exact 64-hex digest we
#     generate. Anything else is someone else's file that happens to sit at
#     that name, and it survives untouched.
# The content is shape-checked, never printed (it is secret material).
remove_secret_if_ours() {
  local secret="$claude_home/handoff_secret" body
  # The path this run actually reads/writes: HANDOFF_SECRET_FILE if set,
  # otherwise the default. The --keep-secret messages below name THIS path,
  # not the bare default, so a HANDOFF_SECRET_FILE override is reported
  # accurately instead of pointing at a file that was never in play (#82).
  local effective="${HANDOFF_SECRET_FILE:-$secret}"
  # --keep-secret (issue #65): skip the deletion entirely and say so. The
  # secret is per-machine identity, not per-install state, so a user who
  # uninstalls before a reinstall (for example moving from user scope to
  # --scope project) can carry it forward and keep every
  # already-signed handoff_current.md verifying instead of it silently
  # downgrading to reference data. Checked before every other guard below:
  # keeping the file needs none of the shape/ownership proof that deleting
  # it does.
  if (( keep_secret )); then
    # Nothing to keep: don't claim to have preserved a secret that was
    # never generated (#82): a fresh machine or a --keep-secret run before
    # any signed write would otherwise print a misleading "preserving" line
    # for a file that doesn't exist.
    if [[ ! -e "$effective" ]]; then
      echo "  ok      $effective (--keep-secret; no secret file there; nothing to keep)"
      return 0
    fi
    echo "  skip    $effective (--keep-secret; preserving the per-machine HMAC secret)"
    if [[ -n "${HANDOFF_SECRET_FILE:-}" ]]; then
      echo "          Existing signed handoffs keep verifying. HANDOFF_SECRET_FILE points"
      echo "          here, so a reinstall will keep reading it from this path."
    else
      echo "          Existing signed handoffs keep verifying. A reinstall reads"
      echo "          this same default path, so it needs no copying: it's already"
      echo "          where the next install will find it."
    fi
    return 0
  fi
  if [[ -n "${HANDOFF_SECRET_FILE:-}" ]]; then
    echo "  skip    handoff secret (HANDOFF_SECRET_FILE override set; leaving '$HANDOFF_SECRET_FILE' alone)"
    return 0
  fi
  if [[ -L "$secret" ]]; then
    echo "  skip    $secret (symlink — not ours to remove; leaving it and its target alone)"
    return 0
  fi
  if [[ ! -e "$secret" ]]; then
    echo "  ok      $secret (already absent)"
    return 0
  fi
  if [[ ! -f "$secret" ]]; then
    echo "  skip    $secret (not a regular file; leaving alone)"
    return 0
  fi
  # Shape check only — 64 lowercase hex, optional trailing newline. Read with
  # tr -d to tolerate the newline our two generators differ on.
  body="$(tr -d '[:space:]' < "$secret" 2>/dev/null || true)"
  if [[ ! "$body" =~ ^[0-9a-f]{64}$ ]]; then
    echo "  skip    $secret (not the shape this tool generates; leaving alone)"
    return 0
  fi
  rm -f "$secret"
  echo "  remove  $secret (per-machine HMAC secret)"
  echo "          Any existing signed handoffs now load as reference data"
  echo "          instead of binding rules — nothing breaks; re-installing"
  echo "          and running /handoff re-signs them with a fresh secret."
}

# ------------------------------------------------------------------ settings.json

print_manual_snippet() {
  cat <<EOF

Paste this into $settings under "hooks" and "permissions":

{
  "hooks": {
    "SessionStart":      [{ "hooks": [{ "type": "command", "command": "$ss_cmd" }] }],
    "SessionEnd":        [{ "hooks": [{ "type": "command", "command": "$se_cmd" }] }],
    "PreCompact":        [{ "hooks": [{ "type": "command", "command": "$pc_cmd" }] }],
    "PostCompact":       [{ "hooks": [{ "type": "command", "command": "$post_cmd" }] }],
    "WorktreeRemove":    [{ "hooks": [{ "type": "command", "command": "$wr_cmd" }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "$st_cmd" }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "$up_cmd" }] }]
  },
  "permissions": {
    "allow": [
      "$perm_write",
      "$perm_stop",
      "$perm_ctx",
      "$perm_ss",
      "$perm_sl",
      "$perm_reset",
      "$perm_wr"
    ]
  },
  "statusLine": { "type": "command", "command": "$sl_cmd" }
}

NOTE: only add the "statusLine" key if you don't already have a statusLine
set — it is a single slot (not a list like hooks), so pasting it would
replace your existing status line. To keep yours AND get handoff's context
numbers, call our script from your existing statusline command instead.
EOF
}

# Install $settings.tmp over $settings — the ONE place every maybe_install_*/
# maybe_uninstall_*/migrate_* function below lands its jq output, instead of
# each calling `mv` directly. ensure_settings_json validates $settings once,
# up front, but every one of these functions re-reads whatever the PREVIOUS
# step's `mv` just installed — so that one up-front check does not cover the
# rest of the chain. jq on empty/unreadable input still exits 0 and prints
# nothing (a crashed jq, a disk full mid-write, anything that truncates the
# pipe): a bare `mv` of that nothing would blank settings.json with a
# false-success exit code, and because rc==0 the EXIT trap's rollback (see
# cleanup() near the top of the file) would never fire — the script would
# print "done" over a wiped config. handoff_statusline.sh's write_cache
# already guards precisely this pattern ("never install the tmp unless printf
# succeeded") for a far less valuable file; this is the same discipline
# applied to the one file every hook depends on.
#
# Every call site here runs inside patch_settings() or unpatch_settings(),
# which arm patch_in_progress and take the pre-patch backup BEFORE calling
# any of these — so `exit 1` on a bad tmp both aborts the run AND is the
# rollback: cleanup() sees patch_in_progress=1 and a non-zero rc and restores
# $settings from $settings_backup. No caller needs to check a return value.
commit_settings_tmp() {
  if [[ ! -s "$settings.tmp" ]] || ! jq -e . "$settings.tmp" >/dev/null 2>&1; then
    echo "  ERROR   jq produced empty or invalid JSON while patching $settings — aborting." >&2
    echo "          $settings is unmodified; restoring from the pre-patch backup." >&2
    exit 1
  fi
  mv "$settings.tmp" "$settings"
}

# Install-or-reconcile one hook. Three cases per event:
#   - marker absent            -> append the canonical command (fresh install)
#   - marker present, current  -> ok (idempotent re-run)
#   - marker present, STALE    -> rewrite it in place to the canonical command,
#     printing the old form loudly. The marker matches any release's variant of
#     our command (it is just the script path), so when a release changes the
#     arguments/redirects around that path, the old wiring would otherwise pass
#     the "already present" check forever. Rewriting here makes the install
#     self-healing — no bespoke migrate_* function per argument change (this
#     subsumed the former migrate_legacy_se_hook; migrate_legacy_ss_hook must
#     stay because the pre-0.3.0 inline form does not contain the script path).
#     Never a silent skip and never a silent clobber: the old form is printed
#     and lives in the settings.json backup made at the top of patch_settings.
#     Comparison is against THIS event's canonical $cmd — events may share a
#     marker (SessionEnd/PreCompact both use write_handoff.sh) but each call
#     reconciles only its own event's list against its own command.
maybe_install_hook() {
  local event="$1" marker="$2" cmd="$3"
  if jq -e --arg e "$event" --arg m "$marker" \
       '(.hooks[$e] // []) | any(.. | .command? // "" | contains($m))' \
       "$settings" >/dev/null 2>&1; then
    local stale
    stale="$(jq -r --arg e "$event" --arg m "$marker" --arg c "$cmd" \
      '(.hooks[$e] // []) | [.. | .command? // "" | select(contains($m) and . != $c)] | .[]' \
      "$settings" 2>/dev/null)"
    if [[ -z "$stale" ]]; then
      echo "  ok      hook $event (already present)"
      return
    fi
    # Rewrite every stale marker-match to the canonical command, then drop
    # exact duplicates of the canonical beyond the first (covers a config that
    # somehow held both a stale AND a current entry — rewriting alone would
    # leave two identical hooks firing twice). Groups that empty out are
    # removed; a user's own co-located command in the same group is untouched.
    jq --arg e "$event" --arg m "$marker" --arg c "$cmd" '
      .hooks[$e] |= (
          map(.hooks |= ((. // []) | map(
            if ((.command // "") | contains($m)) then .command = $c else . end)))
        | delpaths([paths(objects and ((.command? // "") == $c))][1:])
        | map(select((.hooks // []) | length > 0))
      )
    ' "$settings" > "$settings.tmp"
    commit_settings_tmp
    echo "  UPDATE  hook $event — stale command from an older install rewritten:"
    while IFS= read -r _old; do
      echo "          old: $_old"
    done <<< "$stale"
    echo "          new: $cmd"
    echo "          (old form also preserved in the settings.json backup above)"
    return
  fi
  jq --arg e "$event" --arg c "$cmd" '
    .hooks //= {}
    | .hooks[$e] = ((.hooks[$e] // []) + [{"hooks": [{"type": "command", "command": $c}]}])
  ' "$settings" > "$settings.tmp"
  commit_settings_tmp
  echo "  add     hook $event"
}

maybe_install_perm() {
  local perm="$1"
  if jq -e --arg p "$perm" '(.permissions.allow // []) | index($p)' \
       "$settings" >/dev/null 2>&1; then
    echo "  ok      permission already present: $perm"
    return
  fi
  jq --arg p "$perm" '
    .permissions //= {}
    | .permissions.allow = ((.permissions.allow // []) + [$p])
  ' "$settings" > "$settings.tmp"
  commit_settings_tmp
  echo "  add     permission: $perm"
}

# Optional model pin. Never overwrites an existing "model" key: a machine
# where the user already chose a model keeps that choice, and the differing
# request is reported instead of applied. A write is recorded in
# $model_pin_record (0600 via umask) so --uninstall can undo exactly ours.
maybe_install_model() {
  [[ -n "$model_pin" ]] || return 0
  local cur
  cur="$(jq -r '.model // ""' "$settings" 2>/dev/null)"
  if [[ -z "$cur" ]]; then
    jq --arg m "$model_pin" '.model = $m' "$settings" > "$settings.tmp"
    commit_settings_tmp
    printf '%s\n' "$model_pin" > "$model_pin_record"
    echo "  add     model: $model_pin (recorded for uninstall)"
  elif [[ "$cur" == "$model_pin" ]]; then
    echo "  ok      model already set: $cur"
  else
    echo "  keep    model '$cur' (your existing choice preserved — NOT overwriting"
    echo "          with requested '$model_pin'; edit settings.json yourself to change it)"
  fi
}

maybe_uninstall_model() {
  if [[ ! -f "$model_pin_record" || -L "$model_pin_record" ]]; then
    echo "  ok      model (not pinned by this installer)"
    return 0
  fi
  local rec cur
  rec="$(tr -d '[:space:]' < "$model_pin_record" 2>/dev/null || true)"
  cur="$(jq -r '.model // ""' "$settings" 2>/dev/null)"
  if [[ -n "$rec" && "$cur" == "$rec" ]]; then
    jq 'del(.model)' "$settings" > "$settings.tmp"
    commit_settings_tmp
    echo "  remove  model: $rec (this installer set it, unchanged since)"
  else
    echo "  keep    model '$cur' (differs from the recorded pin '$rec' — you changed"
    echo "          it since install; leaving your value alone)"
  fi
  rm -f "$model_pin_record"
}

# statusLine is a single settings.json slot (unlike hooks, which are lists we
# can append to), so wiring it must never clobber a user's own setting:
#   - absent/null            -> set ours
#   - present, ours, current -> ok (idempotent re-run)
#   - present, ours, STALE   -> rewrite the command to canonical, printing the
#     old form (same self-healing rule as maybe_install_hook: the marker only
#     proves it is our script, not that the args/redirects are this release's).
#     Only .command is replaced so any sibling keys the user added (e.g.
#     "padding") survive.
#   - present and NOT ours   -> untouched; print the documented manual step.
maybe_install_statusline() {
  if jq -e '(.statusLine // null) == null' "$settings" >/dev/null 2>&1; then
    jq --arg c "$sl_cmd" '.statusLine = {"type": "command", "command": $c}' \
      "$settings" > "$settings.tmp"
    commit_settings_tmp
    echo "  add     statusLine"
    return
  fi
  if jq -e --arg m "$sl_marker" '(.statusLine.command // "") | contains($m)' \
       "$settings" >/dev/null 2>&1; then
    local cur_sl
    cur_sl="$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null)"
    if [[ "$cur_sl" == "$sl_cmd" ]]; then
      echo "  ok      statusLine (already ours)"
      return
    fi
    jq --arg c "$sl_cmd" '.statusLine.command = $c' "$settings" > "$settings.tmp"
    commit_settings_tmp
    echo "  UPDATE  statusLine — stale command from an older install rewritten:"
    echo "          old: $cur_sl"
    echo "          new: $sl_cmd"
    echo "          (old form also preserved in the settings.json backup above)"
    return
  fi
  echo "  skip    statusLine (you already have one — to use handoff's instead, set"
  echo "          \"statusLine\": {\"type\": \"command\", \"command\": \"$sl_cmd\"}"
  echo "          yourself, or call our script from your existing statusline command)"
}

maybe_uninstall_statusline() {
  if jq -e --arg m "$sl_marker" '(.statusLine.command // "") | contains($m)' \
       "$settings" >/dev/null 2>&1; then
    jq 'del(.statusLine)' "$settings" > "$settings.tmp"
    commit_settings_tmp
    echo "  remove  statusLine"
  elif jq -e '(.statusLine // null) != null' "$settings" >/dev/null 2>&1; then
    echo "  ok      statusLine (not ours; leaving alone)"
  else
    echo "  ok      statusLine (not present)"
  fi
}

maybe_uninstall_hook() {
  local event="$1" marker="$2"
  if ! jq -e --arg e "$event" --arg m "$marker" \
         '(.hooks[$e] // []) | any(.. | .command? // "" | contains($m))' \
         "$settings" >/dev/null 2>&1; then
    echo "  ok      hook $event (not present)"
    return
  fi
  # Remove only the matching command(s), not the whole hook group: a group may
  # hold a user's own co-located command alongside ours. Strip matching commands
  # from each group's inner list, then drop groups that became empty, then drop
  # the event if no groups remain.
  jq --arg e "$event" --arg m "$marker" '
    .hooks[$e] |= (
        map(.hooks |= ((. // []) | map(select(((.command // "") | contains($m)) | not))))
      | map(select((.hooks // []) | length > 0))
    )
    | if ((.hooks[$e] // []) | length) == 0 then del(.hooks[$e]) else . end
  ' "$settings" > "$settings.tmp"
  commit_settings_tmp
  echo "  remove  hook $event"
}

maybe_uninstall_perm() {
  local perm="$1"
  if ! jq -e --arg p "$perm" '(.permissions.allow // []) | index($p)' \
         "$settings" >/dev/null 2>&1; then
    echo "  ok      permission not present: $perm"
    return
  fi
  jq --arg p "$perm" '
    .permissions.allow |= (map(select(. != $p)))
  ' "$settings" > "$settings.tmp"
  commit_settings_tmp
  echo "  remove  permission: $perm"
}

# Migration: pre-0.3.0 SessionStart was an inline bash one-liner that
# cat'd handoff_current.md directly. We detect that legacy form (by a
# substring unique to the inline command, not present in the new
# script-call form) and remove it so re-install replaces — not duplicates —
# the hook.
migrate_legacy_ss_hook() {
  local marker="$ss_legacy_marker"
  if ! jq -e --arg m "$marker" \
         '(.hooks.SessionStart // []) | any(.. | .command? // "" | contains($m))' \
         "$settings" >/dev/null 2>&1; then
    return
  fi
  jq --arg m "$marker" '
    .hooks.SessionStart |= (
        map(.hooks |= ((. // []) | map(select(((.command // "") | contains($m)) | not))))
      | map(select((.hooks // []) | length > 0))
    )
    | if ((.hooks.SessionStart // []) | length) == 0 then del(.hooks.SessionStart) else . end
  ' "$settings" > "$settings.tmp"
  commit_settings_tmp
  echo "  migrate legacy SessionStart inline command removed (pre-0.3.0)"
}

# (The former migrate_legacy_se_hook — pre-0.5.0 SessionEnd forms missing
# --if-curated — is gone: those commands contain the script-path marker, so
# maybe_install_hook's stale-command reconcile now rewrites them generically.
# migrate_legacy_ss_hook above must stay: the pre-0.3.0 inline form has no
# script path in it, so the marker can't find it.)

# Make settings.json safe to patch. Absent or empty -> seed `{}` (jq on empty
# input silently emits nothing, which would blank the file with a false-success
# exit 0). Non-empty but invalid JSON -> refuse to touch it rather than abort
# mid-run or clobber recoverable user config; print the manual snippet instead.
# Returns 0 when the file is valid JSON and safe to patch, 1 to skip patching.
ensure_settings_json() {
  if [[ ! -f "$settings" ]]; then
    echo '{}' > "$settings"
    echo "  new     $settings (created with {})"
    return 0
  fi
  if [[ ! -s "$settings" ]]; then
    echo '{}' > "$settings"
    echo "  init    $settings was empty; set to {}"
    return 0
  fi
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    echo
    echo "  ERROR   $settings is not valid JSON — refusing to auto-patch (left untouched)."
    echo "          Fix or remove it and re-run, or patch settings.json by hand:"
    print_manual_snippet
    return 1
  fi
  # Valid JSON, but the patch jq programs index it as an object (.hooks //= {},
  # .permissions.allow, …). A valid non-object root ([], 42, "x", true) would
  # otherwise sail past the check above and hit a raw jq runtime error mid-patch
  # (caught by the rollback trap, but ugly and confusing). Refuse it cleanly up
  # front instead. (settings#3)
  if ! jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then
    echo
    echo "  ERROR   $settings is valid JSON but not a JSON object (got: $(jq -r 'type' "$settings" 2>/dev/null))."
    echo "          settings.json must be an object — refusing to auto-patch (left untouched)."
    echo "          Fix or remove it and re-run, or patch settings.json by hand:"
    print_manual_snippet
    return 1
  fi
  return 0
}

patch_settings() {
  if ! command -v jq >/dev/null 2>&1; then
    echo
    echo "jq not found — can't auto-patch $settings."
    print_manual_snippet
    return
  fi
  ensure_settings_json || return
  cp "$settings" "$settings.bak.$ts"
  echo "  backup  $settings -> $settings.bak.$ts"
  # Arm restore-on-abort: from here until the sequence completes, any abort
  # rolls settings.json back to this backup (see cleanup() / the EXIT trap).
  settings_backup="$settings.bak.$ts"
  patch_in_progress=1
  migrate_legacy_ss_hook
  maybe_install_hook SessionStart     "$ss_marker" "$ss_cmd"
  maybe_install_hook SessionEnd       "$se_marker" "$se_cmd"
  # Marker detection is event-scoped, so PreCompact can safely reuse the
  # SessionEnd marker: each event's hook list is checked independently.
  maybe_install_hook PreCompact       "$se_marker" "$pc_cmd"
  maybe_install_hook PostCompact      "$post_marker" "$post_cmd"
  maybe_install_hook WorktreeRemove   "$wr_marker" "$wr_cmd"
  maybe_install_hook Stop             "$st_marker" "$st_cmd"
  maybe_install_hook UserPromptSubmit "$up_marker" "$up_cmd"
  maybe_install_statusline
  maybe_install_perm "$perm_write"
  maybe_install_perm "$perm_stop"
  maybe_install_perm "$perm_ctx"
  maybe_install_perm "$perm_ss"
  maybe_install_perm "$perm_sl"
  maybe_install_perm "$perm_reset"
  maybe_install_perm "$perm_wr"
  maybe_install_model
  patch_in_progress=0   # full sequence succeeded; disarm restore-on-abort
  # If no change vs backup, drop the redundant backup.
  if cmp -s "$settings" "$settings.bak.$ts"; then
    rm "$settings.bak.$ts"
    echo "  ok      no settings.json changes (backup removed)"
  fi
}

unpatch_settings() {
  if ! command -v jq >/dev/null 2>&1; then
    echo
    echo "jq not found — can't auto-strip entries from $settings."
    echo "Manually remove any hook commands containing:"
    echo "  - $ss_marker"
    echo "  - $se_marker  (both the SessionEnd and PreCompact entries)"
    echo "  - $post_marker"
    echo "  - $wr_marker"
    echo "  - $st_marker"
    echo "  - $up_marker"
    echo "the \"statusLine\" entry if its command contains:"
    echo "  - $sl_marker"
    echo "and the permission entries:"
    echo "  - $perm_write"
    echo "  - $perm_stop"
    echo "  - $perm_ctx"
    echo "  - $perm_ss"
    echo "  - $perm_sl"
    echo "  - $perm_reset"
    echo "  - $perm_wr"
    echo "and, if you used --model, the top-level \"model\" key (the value this"
    echo "installer wrote, if any, is recorded in $model_pin_record)."
    return
  fi
  if [[ ! -f "$settings" ]]; then
    echo "  ok      $settings does not exist; nothing to strip"
    return
  fi
  if [[ ! -s "$settings" ]]; then
    echo "  ok      $settings is empty; nothing to strip"
    return
  fi
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    echo "  ERROR   $settings is not valid JSON — refusing to edit (left untouched)."
    return
  fi
  cp "$settings" "$settings.bak.$ts"
  echo "  backup  $settings -> $settings.bak.$ts"
  settings_backup="$settings.bak.$ts"
  patch_in_progress=1
  maybe_uninstall_hook SessionStart     "$ss_marker"
  maybe_uninstall_hook SessionStart     "$ss_legacy_marker"
  maybe_uninstall_hook SessionEnd       "$se_marker"
  maybe_uninstall_hook PreCompact       "$se_marker"
  maybe_uninstall_hook PostCompact      "$post_marker"
  maybe_uninstall_hook WorktreeRemove   "$wr_marker"
  maybe_uninstall_hook Stop             "$st_marker"
  maybe_uninstall_hook UserPromptSubmit "$up_marker"
  maybe_uninstall_statusline
  maybe_uninstall_perm "$perm_write"
  maybe_uninstall_perm "$perm_stop"
  maybe_uninstall_perm "$perm_ctx"
  maybe_uninstall_perm "$perm_ss"
  maybe_uninstall_perm "$perm_sl"
  maybe_uninstall_perm "$perm_reset"
  maybe_uninstall_perm "$perm_wr"
  maybe_uninstall_model
  patch_in_progress=0   # full sequence succeeded; disarm restore-on-abort
  if cmp -s "$settings" "$settings.bak.$ts"; then
    rm "$settings.bak.$ts"
    echo "  ok      no settings.json changes (backup removed)"
  fi
}

# Single source of truth for "will the next handoff be HMAC-signed" — reused
# by doctor() (detailed per-item report, below) and the installer's
# first-run summary (install.d/40-main.sh). Mirrors the EXACT preconditions
# bin/handoff_provenance.sh's handoff_mac_compute checks, in the same order
# it checks them:
#   1. openssl on PATH — handoff_mac_compute's very first line
#      (`command -v openssl >/dev/null 2>&1 || return 1`); required for every
#      call regardless of secret state, since HMAC-SHA256 is built from two
#      openssl digest passes. No openssl => degraded, full stop.
#   2. the secret file (handoff_secret_path: $HANDOFF_SECRET_FILE, else
#      $claude_home/handoff_secret) must be usable: not a symlink (the
#      signer refuses one outright — handoff_ensure_secret/handoff_mac_compute
#      both `return 1`), and — for an EXISTING path — a regular, non-empty
#      file (handoff_mac_compute's verify branch requires `-f` AND `-s`;
#      `key="$(cat "$sf")"` then `[ -n "$key" ]` guards the empty case again).
#      A path that exists but isn't a regular file can't be read as a key.
#   3. absent entirely is NOT degraded: handoff_ensure_secret mints one
#      lazily on the first signed write (openssl rand, or /dev/urandom via od
#      as fallback) — reported as its own distinct state, not lumped with
#      "active" or "degraded", since nothing has actually signed yet.
# Echoes one of: "active", "degraded: <reason>", or
# "pending: <reason>" (not yet signed, but will self-heal on first write).
# Never touches `broken` — callers decide what (if anything) that means.
signing_status_reason() {
  local secret="${HANDOFF_SECRET_FILE:-$claude_home/handoff_secret}"
  if ! command -v openssl >/dev/null 2>&1; then
    echo "degraded: openssl not found on PATH"
  elif [[ -L "$secret" ]]; then
    echo "degraded: secret file ($secret) is a symlink — the signer refuses it"
  elif [[ -f "$secret" ]]; then
    # Probe with the signer's own load, not -s: handoff_mac_compute requires
    # `cat` to succeed AND the key to be non-empty after $() strips trailing
    # newlines, so an unreadable or newline-only secret passed -f/-s here
    # ("active") while every write silently degraded to unsigned. The probe
    # runs in a subshell and prints nothing — key bytes never reach output
    # or this shell's state.
    if ( k="$(cat "$secret" 2>/dev/null)" && [ -n "$k" ] ); then
      echo "active"
    elif [[ ! -r "$secret" ]]; then
      echo "degraded: secret file ($secret) is not readable by this user"
    else
      echo "degraded: secret file ($secret) is empty"
    fi
  elif [[ -e "$secret" ]]; then
    echo "degraded: secret path ($secret) exists but is not a regular file"
  else
    echo "pending: no secret yet — one is generated on the first signed write"
  fi
}

# The install command that re-creates THIS run's wiring, for remedies doctor
# prints: a project-scope doctor must not tell the user to run a bare
# ./install.sh, which would wire the user-scope file instead (issue #171).
rerun_cmd() {
  if [[ "$scope" == project ]]; then
    if (( use_local )); then
      printf '%s\n' "./install.sh --scope project --project $project_dir --local"
    else
      printf '%s\n' "./install.sh --scope project --project $project_dir"
    fi
  else
    printf '%s\n' "./install.sh"
  fi
}

# settings_has_our_hooks <file>: 0 when <file> exists, parses, and wires at
# least one of this installer's hook commands (the markers the patcher
# writes). 1 otherwise, including when jq is missing.
settings_has_our_hooks() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e --arg ss "$ss_marker" --arg se "$se_marker" --arg post "$post_marker" \
        --arg wr "$wr_marker" --arg st "$st_marker" --arg up "$up_marker" '
      type == "object" and (
      ( (.hooks.SessionStart // [])     | any(.. | .command? // "" | contains($ss)) ) or
      ( (.hooks.SessionEnd // [])       | any(.. | .command? // "" | contains($se)) ) or
      ( (.hooks.PreCompact // [])       | any(.. | .command? // "" | contains($se)) ) or
      ( (.hooks.PostCompact // [])      | any(.. | .command? // "" | contains($post)) ) or
      ( (.hooks.WorktreeRemove // [])   | any(.. | .command? // "" | contains($wr)) ) or
      ( (.hooks.Stop // [])             | any(.. | .command? // "" | contains($st)) ) or
      ( (.hooks.UserPromptSubmit // []) | any(.. | .command? // "" | contains($up)) ) )
    ' "$f" >/dev/null 2>&1
}

# Physical path of a settings file (symlinks resolved, directory made
# physical), so the double-fire check below never counts one file twice: a
# project rooted at $HOME, or a dotfiles link, can make two spellings name
# the same file. Prints nothing when the directory does not exist.
settings_phys_path() {
  local f d
  f="$(resolve_symlink "$1")"
  d="$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)" || return 0
  printf '%s/%s\n' "$d" "$(basename "$f")"
}

# Double-fire check (issue #171): Claude Code merges the user file and the
# project's settings.json and settings.local.json, so this installer's hooks
# wired into more than one of them fire once per file. The project checked
# is --project (project scope) or the current directory (user scope).
# Advisory only, never counts toward `broken`: each file is valid on its
# own. Prints the WARN, or nothing when at most one file is wired.
report_double_fire() {
  local proj f p seen="" wired="" n=0
  if [[ "$scope" == project ]]; then proj="$project_dir"; else proj="$PWD"; fi
  for f in "$user_settings" "$proj/.claude/settings.json" "$proj/.claude/settings.local.json"; do
    p="$(settings_phys_path "$f")"
    [[ -n "$p" ]] || continue
    case "$seen" in *"|$p|"*) continue ;; esac
    seen="$seen|$p|"
    if settings_has_our_hooks "$p"; then
      wired="$wired
            $f"
      n=$((n + 1))
    fi
  done
  (( n > 1 )) || return 0
  echo "  WARN    this installer's hooks are wired in $n settings files that Claude"
  echo "          Code loads for $proj, so every hook fires once per file:$wired"
  echo "          Fix: keep one. To drop the user-scope wiring run"
  echo "          './install.sh --uninstall', then re-run"
  echo "          './install.sh --scope project --project $proj' (a user-scope"
  echo "          uninstall also removes the shared scripts). To drop a project"
  echo "          file run './install.sh --uninstall --scope project --project $proj'"
  echo "          (add --local for settings.local.json)."
  echo
}

# Self-check: verify each installed hook script under $claude_home/bin actually
# resolves. A dangling symlink (e.g. installed from a temp checkout that was
# later cleaned up) makes the corresponding hook no-op silently, so surface it
# loudly here. Exit non-zero if anything is broken so CI / a wrapper can detect
# it. (issue #21)

doctor() {
  local broken=0 dst tgt name mdl secret smode sign_reason

  if [[ "$scope" == project ]]; then
    echo "doctor: project scope, checking $settings"
    echo
  fi
  echo "doctor: checking runtime dependencies"
  # jq is a RUNTIME dependency of the Stop hook (payload parsing), the ctx
  # nudge, and the /handoff-recover tail rescue — a resolving script link is
  # not enough if the tool it needs is missing (they all no-op silently).
  if ! command -v jq >/dev/null 2>&1; then
    echo "  BROKEN  jq not found on PATH (Stop hook, ctx nudge, and /handoff-recover tail rescue are silently disabled)"
    broken=$((broken + 1))
  fi
  # openssl is an OPTIONAL runtime dependency (HMAC-signing the handoff so its
  # rules layer can load as binding — issue #42). Its absence is a designed
  # degradation, not breakage: everything still works, the rules just load as
  # reference data. Advisory note only; never counts toward broken.
  if ! command -v openssl >/dev/null 2>&1; then
    echo "  note    openssl not found on PATH (optional): handoffs won't be"
    echo "          HMAC-signed, so the rules/pinned layer loads as reference"
    echo "          data instead of binding rules. Install openssl to enable."
  fi
  echo

  echo "doctor: checking installed handoff hooks under $claude_home/bin"
  for name in write_handoff handoff_turn_append handoff_ctx_check handoff_session_start handoff_recover_tail handoff_statusline handoff_compact_reset handoff_worktree_remove handoff_provenance; do
    dst="$claude_home/bin/$name.sh"
    if [[ -e "$dst" ]]; then
      if [[ -L "$dst" ]]; then
        echo "  ok      $dst -> $(readlink "$dst")"
      else
        echo "  ok      $dst (copy)"
      fi
    elif [[ -L "$dst" ]]; then
      tgt="$(readlink "$dst" 2>/dev/null || true)"
      echo "  BROKEN  $dst -> $tgt (dangling symlink: hook is silently disabled)"
      broken=$((broken + 1))
    else
      echo "  MISSING $dst (not installed)"
      broken=$((broken + 1))
    fi
  done
  echo
  # Secret-file hygiene. The per-machine HMAC secret is what makes a
  # handoff's rules layer load as BINDING (issue #42): group/other-readable,
  # any local reader can forge the trailer; a symlink at the path could be
  # planted to point key generation somewhere attacker-readable (the signer
  # refuses it, silently degrading to unsigned). Same effective path as the
  # runtime and remove_secret_if_ours: the HANDOFF_SECRET_FILE override wins
  # over the default under $claude_home — doctor is read-only, so unlike
  # uninstall it can safely inspect an overridden location. Absent is NOT an
  # error: the secret is minted lazily on the first signed write.
  secret="${HANDOFF_SECRET_FILE:-$claude_home/handoff_secret}"
  if [[ -L "$secret" ]]; then
    echo "  BROKEN  $secret is a symlink (possibly planted) — the signer refuses it;"
    echo "          remove the link: rm '$secret' (a fresh secret is generated on the next signed write)"
    broken=$((broken + 1))
  elif [[ -f "$secret" ]]; then
    # Portable mode read: GNU stat -c %a with BSD stat -f %Lp fallback.
    smode="$(stat -c %a "$secret" 2>/dev/null || stat -f %Lp "$secret" 2>/dev/null)" || smode=""
    if [[ "$smode" =~ ^[0-7]+$ ]] && (( 8#$smode & 8#77 )); then
      echo "  BROKEN  $secret is group/other-readable (mode $smode) — the HMAC key is"
      echo "          exposed to other local users; run: chmod 600 '$secret'"
      broken=$((broken + 1))
    else
      echo "  ok      $secret (regular file, mode ${smode:-unreadable}, no group/other access)"
    fi
  elif [[ -e "$secret" ]]; then
    # Exists but is not a regular file (directory, fifo, ...): the signer
    # can't use it, so signing is silently disabled — that's breakage.
    echo "  BROKEN  $secret exists but is not a regular file — signing is silently disabled"
    broken=$((broken + 1))
  else
    echo "  note    $secret absent — generated on first signed write (not an error)"
  fi
  # Signing status — one-line summary answering "will the next handoff be
  # HMAC-signed", consolidating the openssl/secret checks above (which say
  # WHY per-artifact) into the single yes/no-and-why question a user actually
  # asks. Never counts toward `broken` itself — the checks above already
  # flip that for cases the signer can't recover from (a symlinked or
  # non-regular secret); this line would just double-count them.
  sign_reason="$(signing_status_reason)"
  case "$sign_reason" in
    active)
      echo "  ok      handoff signing: active"
      ;;
    degraded:*)
      echo "  note    handoff signing: ${sign_reason#degraded: }"
      ;;
    pending:*)
      echo "  note    handoff signing: ${sign_reason#pending: }"
      ;;
  esac
  echo
  # statusLine wiring report — informational only, never counts toward
  # `broken`: an unwired or user-owned statusLine is a legitimate state (we
  # never overwrite a user's own setting), not a fault. Only a dangling
  # SCRIPT (reported by the loop above) is real breakage.
  #
  # A missing settings file still gets a line rather than silence: the
  # status line is the context nudge's most accurate signal, so its absence
  # is worth naming even when there is no file to inspect.
  if command -v jq >/dev/null 2>&1 && [[ ! -f "$settings" ]]; then
    echo "  info    statusLine unset (re-run $(rerun_cmd) to wire it)"
    echo
  elif command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]]; then
    if jq -e --arg m "$sl_marker" '(.statusLine.command // "") | contains($m)' \
         "$settings" >/dev/null 2>&1; then
      echo "  ok      statusLine wired (ours)"
    elif jq -e '(.statusLine // null) != null' "$settings" >/dev/null 2>&1; then
      echo "  info    statusLine present (user's own — manual wiring documented in README)"
    else
      echo "  info    statusLine unset (re-run $(rerun_cmd) to wire it)"
    fi
    # Model context-window check — advisory only, never counts toward broken:
    # a bare 'opus'/'claude-opus-4-8' pin silently runs at a 200k context
    # window; the 1M variant needs the [1m] suffix. Any other value (including
    # absent) is a legitimate choice we stay quiet about.
    mdl="$(jq -r '.model // ""' "$settings" 2>/dev/null)"
    case "$mdl" in
      opus|claude-opus-4-8)
        echo "  WARN    model '$mdl' in settings.json is the 200k-context variant —"
        echo "          for the 1M window set \"model\": \"${mdl}[1m]\" (edit settings.json"
        echo "          or run /model ${mdl}[1m] in a session)."
        ;;
    esac
    echo
  fi
  report_double_fire
  if (( broken )); then
    echo "doctor: $broken issue(s) found." >&2
    echo "        Re-run $(rerun_cmd) from a persistent clone (not a /tmp checkout)." >&2
    return 1
  fi
  echo "doctor: all hooks resolve."
}

# ------------------------------------------------------------------------ main

# The dispatch lives in one brace group with the cleanup trap as its first
# statement. Bash must parse the entire group before executing any of it, so
# on a truncated `curl | bash` stream the trap is never armed and the parse
# error keeps its nonzero exit (armed earlier, bash 3.2 reports rc=0 — see
# the note above cleanup() in 00-preamble.sh). Residual gap, accepted: a
# stream that truncates exactly at a statement boundary before this group
# still exits 0 having installed nothing — no trap arrangement can catch
# that; only checksum verification of the fetched script would.
{
trap cleanup EXIT

if [[ "$mode" == doctor ]]; then
  doctor
elif [[ "$mode" == install ]]; then
  # jq is a hard RUNTIME dependency, not just an install-time convenience:
  # without it the Stop hook exits before writing anything (no raw dumps, no
  # ctx measurements), the ctx nudge never fires, and /handoff-recover's tail
  # rescue can't parse the transcript — all silently, because the hooks are
  # wired '... || true'. Installing anyway would print "done" and ship a
  # system that never runs. Refuse up front instead. (--uninstall and --doctor
  # still work without jq.)
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq not found on PATH — refusing to install." >&2
    echo "  jq is required at runtime by the Stop hook (raw per-turn dumps)," >&2
    echo "  the context nudge, and /handoff-recover; without it they all no-op" >&2
    echo "  silently. Install jq (e.g. 'apt install jq' / 'brew install jq')" >&2
    echo "  and re-run ./install.sh." >&2
    exit 1
  fi
  echo "installing handoff skill from $repo_root into $claude_home"
  echo
  echo "symlinks:"
  install_symlinks
  echo
  if [[ "$scope" == project ]]; then
    # Project scope (issue #171): the scripts above are shared from
    # $claude_home; only the wiring goes into the project. Create the
    # project's .claude/ on demand (install mode only: --doctor and
    # --uninstall never create anything).
    echo "project settings ($project_dir):"
    if [[ ! -d "$(dirname "$settings")" ]]; then
      mkdir -p "$(dirname "$settings")"
      echo "  new     $(dirname "$settings")/"
    fi
  else
    echo "settings.json:"
  fi
  patch_settings
  echo
  if [[ -z "$model_pin" ]] && command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]] \
     && jq -e 'type == "object" and ((.model // null) == null)' "$settings" >/dev/null 2>&1; then
    echo "NOTE: no model pinned in settings.json — a bare 'opus' selection runs at a"
    echo "      200k context window. Re-run  ./install.sh --model 'opus[1m]'  to pin one."
    echo
  fi
  if [[ "$scope" == project ]] && settings_has_our_hooks "$user_settings"; then
    echo "NOTE: $user_settings also wires this installer's hooks, so in"
    echo "      $project_dir every hook fires twice. Run ./install.sh --doctor"
    echo "      --scope project --project $project_dir for the remedy."
    echo
  fi
  if [[ "$scope" == project ]]; then
    echo "note: hooks are wired for $project_dir only ($settings)."
  fi
  echo "done. start a new Claude Code session — /handoff is available now."
  # First-run signing note — one line pointing at --doctor for the detailed
  # per-item report (secret-file hygiene, openssl presence). Uses the same
  # signing_status_reason() doctor() reports from, so the two can never drift.
  sign_reason="$(signing_status_reason)"
  case "$sign_reason" in
    active)
      echo "note: handoff signing is active — new handoffs are HMAC-signed (./install.sh --doctor for detail)."
      ;;
    pending:*)
      echo "note: handoff signing ${sign_reason#pending: } (./install.sh --doctor for detail)."
      ;;
    degraded:*)
      echo "note: handoff signing degraded (${sign_reason#degraded: }) (./install.sh --doctor for detail)."
      ;;
  esac
  if [[ "$COPIED_ANY" == "1" ]]; then
    echo
    echo "note: files were COPIED into $claude_home (copy mode or symlinks"
    echo "      unavailable). After a future 'git pull' in this repo, re-run"
    echo "      ./install.sh to refresh the copies — symlinked installs update"
    echo "      automatically, copies do not."
  fi
elif [[ "$scope" == project ]]; then
  # Project-scope uninstall (issue #171) strips only this project's wiring.
  # The scripts, skills, and HMAC secret under $claude_home are shared by
  # every project on this machine, so they stay; a user-scope --uninstall is
  # the way to remove them.
  echo "uninstalling handoff wiring from $project_dir (project scope)"
  echo
  echo "project settings ($project_dir):"
  unpatch_settings
  echo
  echo "kept (project scope): $claude_home/bin scripts, $claude_home/skills, and the"
  echo "      HMAC secret are shared by every project on this machine and were not"
  echo "      removed. Run ./install.sh --uninstall (user scope) to remove them."
  echo
  echo "done. the repo at $repo_root is untouched."
else
  echo "uninstalling handoff skill from $claude_home"
  echo
  echo "symlinks:"
  uninstall_symlinks
  echo
  echo "settings.json:"
  unpatch_settings
  echo
  echo "local state:"
  remove_secret_if_ours
  echo
  echo "done. the repo at $repo_root is untouched."
fi
}
