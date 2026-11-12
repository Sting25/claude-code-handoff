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
# SOURCE-SHA256: a5b8bccb5b29a8d136cc3d3434b3007a7d6b93214b2344ff9a9bc4222ebcc57f
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
  2. Patches one settings file to add seven hooks (SessionStart / SessionEnd /
     PreCompact / PostCompact / WorktreeRemove / Stop / UserPromptSubmit),
     seven permission entries, and (only when you don't already have one) a
     statusLine command (never overwrites an existing statusLine; prints the
     manual step instead). Which file: ~/.claude/settings.json by default,
     or with --scope project the project's .claude/settings.json or
     .claude/settings.local.json (see "Scope" below).
     Requires jq. Without it, install refuses (exit 1); --uninstall removes the
     scripts but cannot unpatch the settings file and prints the entries to
     remove by hand; --doctor reports jq as BROKEN.

Idempotent. Existing files at symlink targets are backed up to
<path>.bak.<timestamp> before being replaced. An existing settings file is
backed up before any patch: <path>.bak.<timestamp> next to it in user scope, or
~/.claude/handoff_settings_backups/<cksum of project path>/<name>.bak.<timestamp>
in project scope (never inside the project). Re-runs are safe and only
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
  Without --project, inside a git repo the project is its toplevel.

  While any project-scope install is still wired, a user-scope --uninstall
  keeps the shared HMAC secret (those projects sign with it); add
  --remove-secret to delete it anyway.

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

# Under `curl ... | bash -s -- --help`, BASH_SOURCE[0] has no element to read,
# which trips `set -u` as "unbound variable". The error is raised while the
# command substitution's own words expand, so a `2>/dev/null` on the `cd`
# inside it cannot hide it (issue #178). Read the element with a `:-` default
# first, and only resolve a path when there is one. `--help`/`-h` (parsed
# further below) exits via usage() before repo_root is ever used, so an empty
# value is safe for that path; every other invocation shape still resolves a
# real BASH_SOURCE[0]. (An empty value must stay empty: `dirname ""` is "."
# and would silently turn the caller's cwd into the repo root.)
_self_src="${BASH_SOURCE[0]:-}"
repo_root=""
repo_root_err=""   # why repo_root is empty: "" (no source path, piped) or "cannot cd to <dir>"
if [[ -n "$_self_src" ]]; then
  repo_root="$(cd "$(dirname "$_self_src")" 2>/dev/null && pwd)" || repo_root=""
  if [[ -z "$repo_root" ]]; then
    repo_root_err="cannot cd to $(dirname "$_self_src")"
  fi
fi
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
settings_name="settings.json"
project_backup_dir=""
# Registry of project-scope installs (issue #171): one line per wired
# project file, "<absolute project dir><TAB><settings file name>". Lets a
# user-scope --uninstall warn about projects whose hooks it is about to
# orphan, and lets the user-scope doctor name stale entries.
project_registry="$claude_home/handoff_projects"
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
# --remove-secret (issue #171): a user-scope --uninstall keeps the secret
# automatically while any registered project-scope install is still wired
# (they sign with it); this flag deletes it anyway.
remove_secret=0
# Set when a project-scope --uninstall names a directory that is gone (a
# removed worktree): only its registry line is cleared.
project_gone=0

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
# A settings file this run seeded as {} (issue #171; both scopes since
# issue #178) gets no backup (there was nothing to keep), so an abort puts back what
# was there before instead: "absent" removes the file, "empty" truncates it.
settings_seed_state=""
cleanup() {
  local rc=$?
  rm -f "$settings.tmp" 2>/dev/null || true
  if (( patch_in_progress )) && (( rc != 0 )) \
     && [[ -n "$settings_backup" && -f "$settings_backup" ]]; then
    cp -f "$settings_backup" "$settings" 2>/dev/null || true
    echo "  restore $settings from $settings_backup (aborted mid-patch, rc=$rc)" >&2
  elif (( patch_in_progress )) && (( rc != 0 )) && [[ -n "$settings_seed_state" ]]; then
    if [[ "$settings_seed_state" == absent ]]; then
      rm -f "$settings" 2>/dev/null || true
      echo "  restore $settings removed again; this run created it (aborted mid-patch, rc=$rc)" >&2
    else
      : > "$settings" 2>/dev/null || true
      echo "  restore $settings emptied again, as it was before this run (aborted mid-patch, rc=$rc)" >&2
    fi
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
    --remove-secret) remove_secret=1 ;;
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
if (( keep_secret && remove_secret )); then
  echo "ERROR: --keep-secret and --remove-secret contradict each other; pass one." >&2
  exit 2
fi
if (( remove_secret )) && [[ "$mode" != uninstall ]]; then
  echo "warning: --remove-secret has no effect in $mode mode; it only changes what --uninstall does." >&2
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
  # No --project: the project containing the current directory, the natural
  # shape for `cd ~/code/myapp && ~/src/claude-code-handoff/install.sh
  # --scope project`. Inside a git repo that is its toplevel (Claude Code
  # reads .claude/ at the project root, not in a subdirectory); outside
  # one, the current directory itself. Said out loud either way.
  if [[ -z "$project_dir" ]]; then
    _top=""
    if command -v git >/dev/null 2>&1; then
      _top="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
    fi
    if [[ -n "$_top" ]]; then
      project_dir="$_top"
      echo "note: no --project given; using $project_dir (the git toplevel of the current directory)." >&2
    else
      project_dir="$PWD"
      echo "note: no --project given; using $project_dir (the current directory)." >&2
    fi
  fi
  if [[ ! -d "$project_dir" && "$mode" == uninstall ]]; then
    # A project-scope uninstall of a directory that is gone (typically a
    # removed worktree the doctor listed as stale) only clears its registry
    # line; there is no file left to unpatch. Made absolute the only way a
    # missing path allows, so it matches the registry's absolute entries.
    case "$project_dir" in
      /*) : ;;
      *) project_dir="$PWD/$project_dir" ;;
    esac
    while [[ "$project_dir" == */ && "$project_dir" != / ]]; do project_dir="${project_dir%/}"; done
    # The install recorded the PHYSICAL path (registry line, backup key). A
    # path reached through a symlink (a dangling link to the removed project,
    # or a link above it) must be made physical the same way a missing path
    # allows: follow a dangling final link, then resolve the parent (#194).
    project_dir="$(resolve_symlink "$project_dir")"
    # Walk up to the nearest existing ancestor, make THAT physical, and put the
    # missing tail back: a removed worktree whose parent is gone too (under a
    # symlinked ancestor such as macOS /tmp -> /private/tmp) must still match
    # the physical path the install registered.
    _gone_tail=""
    _gone_head="$project_dir"
    while [[ ! -d "$_gone_head" && "$_gone_head" != / && -n "$_gone_head" ]]; do
      _gone_tail="/$(basename "$_gone_head")$_gone_tail"
      _gone_head="$(dirname "$_gone_head")"
    done
    # An ancestor that cannot be entered (mode 000) has no knowable physical
    # path: say so and leave the registry line, rather than dying on a raw
    # `cd: Permission denied` under set -e or clearing a line that may not match.
    if ! _gone_phys="$(cd "$_gone_head" 2>/dev/null && pwd -P)"; then
      echo "  WARN    cannot enter $_gone_head (the nearest existing parent of $project_dir)," >&2
      echo "          so its physical path is unknown; the registry line and markers were left in place." >&2
      echo "          Make it enterable and re-run the --uninstall." >&2
      exit 1
    fi
    _gone_head="$_gone_phys"
    [[ "$_gone_head" == / ]] && _gone_head=""
    project_dir="$_gone_head$_gone_tail"
    project_gone=1
  elif [[ ! -d "$project_dir" ]]; then
    echo "ERROR: project directory '$project_dir' does not exist or is not a directory; refusing." >&2
    exit 2
  fi
fi
if [[ "$scope" == project ]] && (( ! project_gone )); then
  # Absolute and physical, so the comparisons below and the paths printed
  # (and the backup location) never depend on how the flag was spelled.
  project_dir="$(cd "$project_dir" && pwd -P)"
  # Wiring the handoff clone, or any directory inside it, is almost
  # certainly a mistake: the usual cause is running `./install.sh --scope
  # project` from inside the clone without --project. Refuse instead of
  # patching a .claude/ under the clone. Prefix test with a trailing slash on
  # both sides, so /src/handoff-other is not mistaken for /src/handoff.
  if [[ -n "$repo_root" ]]; then
    _src_phys="$(cd "$repo_root" && pwd -P)"
    case "$project_dir/" in
      "$_src_phys"/*)
        echo "ERROR: project directory '$project_dir' is the handoff clone '$_src_phys' or inside it (the install source); refusing." >&2
        echo "       Pass --project <dir> for the project you want to wire, or run install.sh from inside that project." >&2
        exit 2 ;;
    esac
  fi
  # A project whose .claude/ IS $claude_home (a project rooted at $HOME)
  # would make the "project" file the user-scope file under another name.
  _proj_claude="$project_dir/.claude"
  # (Plain string compare too, for a fresh machine where neither exists yet.)
  if [[ "$_proj_claude" == "$claude_home" ]] \
     || { [[ -d "$_proj_claude" && -d "$claude_home" ]] \
          && [[ "$(cd "$_proj_claude" && pwd -P)" == "$(cd "$claude_home" && pwd -P)" ]]; }; then
    echo "ERROR: project '$project_dir' has $claude_home as its .claude directory, which is the user-scope config; refusing." >&2
    echo "       Use --scope user to patch $user_settings, or pass --project <dir> to wire one project" >&2
    echo "       (for example: ./install.sh --scope project --project ~/code/myapp)." >&2
    exit 2
  fi
fi
if [[ "$scope" == project ]]; then
  _proj_claude="$project_dir/.claude"
  if (( use_local )); then
    settings_name="settings.local.json"
  else
    settings_name="settings.json"
  fi
  settings="$_proj_claude/$settings_name"
  # Project-scope backups live OUTSIDE the project (a .bak next to a tracked
  # settings.json is one `git add .` from being committed), one directory
  # per project keyed by a cksum of its physical path.
  # A vanished project (--uninstall of a removed worktree) cannot be
  # resolved with pwd -P, so its parent is: the key must match the one the
  # install used (issue #178), or the created-file marker would be orphaned.
  _key_dir="$project_dir"   # already physical on both paths (a gone one was resolved above)
  project_backup_dir="$claude_home/handoff_settings_backups/$(printf '%s' "$_key_dir" | cksum | awk '{print $1}')"
  # A project-scope --uninstall never touches the secret (see 40-main.sh),
  # so --keep-secret is a no-op there too; say so, same as issue #82.
  if (( keep_secret || remove_secret )) && [[ "$mode" == uninstall ]]; then
    echo "warning: --keep-secret/--remove-secret have no effect with --scope project; a project-scope --uninstall never removes the secret." >&2
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
# settings_link keeps the path the user named, so a refusal can name the link.
settings_link=""
if [[ -L "$settings" ]]; then
  settings_link="$settings"
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
  # nudge cadence starts over). Only fires on CC >= 2.1.76.
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
      # Only an install creates links, so only an install has anything to
      # warn about; --doctor and --uninstall install nothing (#205).
      if [[ "$mode" == install ]]; then
        echo "warning: installing from a volatile path ($repo_root)." >&2
        echo "         Symlinks would dangle when it's cleaned up and the hooks would" >&2
        echo "         then fail silently, so using COPY mode instead (the copies survive)." >&2
        echo "         Re-run from a persistent clone for auto-updating symlinks, or pass" >&2
        echo "         --link / HANDOFF_FORCE_SYMLINK=1 to force symlinks anyway." >&2
      fi
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

# Total jq probes (#174, #187). A probe is a `jq -e`: exit 0 = true, 1 =
# false/null (a real answer). Reading "not 0" as "absent" turned a jq failure
# into a quiet wrong answer (a second healthy install appended every hook and
# permission again; --uninstall left a dangling statusLine). So every probe
# filter is TOTAL (`?` and type guards: a shape it does not expect, a
# non-object root included, evaluates to a plain false, never a runtime error, and it always emits exactly one
# value, since no output makes `jq -e` exit 4), and for valid settings JSON an
# exit of 2 or more can only mean jq itself failed. Keep the filters total if
# you edit them.
# probe_hook / probe_perm are the shared filters; the installer and uninstaller
# run them through jq_probe (a failure aborts, the EXIT trap restores the
# settings file), doctor through its own WARN-only handling.
# shellcheck disable=SC2016  # $e/$m/$p are jq variables, bound by --arg at the call
probe_hook='[(.hooks? | objects | .[$e]?) // empty | .. | (.command? // "")
            | select(type == "string" and contains($m))] | length > 0'
# shellcheck disable=SC2016  # jq variable, see probe_hook
probe_perm='((.permissions? | objects | .allow?) // []) | (if type == "array" then index($p) else null end)'
# Statusline "ours" filter, total on every root shape: `.statusLine? | objects`
# turns a non-object root or a non-object statusLine into no value, which the
# `// ""` turns into "" (a plain false). Shared by install, uninstall and doctor.
# shellcheck disable=SC2016  # jq variable, see probe_hook
probe_sl_ours='((.statusLine? | objects | .command?) // "") | (type == "string" and contains($m))'
# shellcheck disable=SC2016  # jq filter text, no shell variables
probe_sl_present='(.statusLine? // null) != null'
probe_model_read='(.model? // "")'

# jq_abort <rc> <what>: the one abort path for a failed probe or read. The
# EXIT trap restores the settings file; the text names the mode, because the
# recovery differs (install keeps the bin/ links it already made, uninstall
# unpatches settings BEFORE removing any file, so nothing was removed).
jq_abort() {
  echo "  ERROR   jq failed (exit $1) while probing $2 in $settings; aborting." >&2
  if [[ "${mode:-install}" == uninstall ]]; then
    echo "          $settings was restored and no bin/ or skills files were removed;" >&2
    echo "          fix jq and re-run ./install.sh --uninstall." >&2
  else
    echo "          $settings was restored to its state before this run;" >&2
    echo "          fix jq and re-run ./install.sh." >&2
  fi
  exit 1
}
# jq_probe <what> <jq args...>: 0 = true, 1 = false, abort on a jq failure.
jq_probe() {
  local what="$1" rc=0
  shift
  jq -e "$@" >/dev/null 2>&1 || rc=$?
  if [[ $rc -gt 1 ]]; then jq_abort "$rc" "$what"; fi
  return "$rc"
}
# jq_read <what> <jq args...>: runs `jq -r`, leaves the output in JQ_OUT (no
# command substitution, so the abort exits the script, not a subshell). Any
# nonzero jq exit aborts: an empty read must mean empty, never "jq failed".
JQ_OUT=""
jq_read() {
  local what="$1" rc=0
  shift
  JQ_OUT="$(jq -r "$@" 2>/dev/null)" || rc=$?
  if [[ $rc -ne 0 ]]; then jq_abort "$rc" "$what"; fi
  return 0
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
  if jq_probe "hook $event" --arg e "$event" --arg m "$marker" "$probe_hook" "$settings"; then
    local stale
    # shellcheck disable=SC2016  # jq variables, bound by --arg
    jq_read "stale command of hook $event" --arg e "$event" --arg m "$marker" --arg c "$cmd" \
      '((.hooks? | objects | .[$e]?) // []) | [.. | (.command? // "") | select(type == "string" and contains($m) and . != $c)] | .[]' \
      "$settings"
    stale="$JQ_OUT"
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
  if jq_probe "permission $perm" --arg p "$perm" "$probe_perm" "$settings"; then
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
  jq_read model "$probe_model_read" "$settings"
  cur="$JQ_OUT"
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
  jq_read model "$probe_model_read" "$settings"
  cur="$JQ_OUT"
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
#
# Each probe is a `jq -e` through jq_probe (exit 0 = true, 1 = false/null, a
# real answer; 2 or more = jq itself failed, fatal like commit_settings_tmp).
# The filters are TOTAL on every root shape (probe_sl_ours / probe_sl_present
# above), so treating "not 0" as "a foreign statusLine exists" can no longer
# print `skip` and exit 0 with nothing wired (#174). Keep them total.
maybe_install_statusline() {
  if ! jq_probe statusLine "$probe_sl_present" "$settings"; then
    jq --arg c "$sl_cmd" '.statusLine = {"type": "command", "command": $c}' \
      "$settings" > "$settings.tmp"
    commit_settings_tmp
    echo "  add     statusLine"
    return
  fi
  if jq_probe statusLine --arg m "$sl_marker" "$probe_sl_ours" "$settings"; then
    local cur_sl
    jq_read statusLine '.statusLine.command // ""' "$settings"
    cur_sl="$JQ_OUT"
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
  if jq_probe statusLine --arg m "$sl_marker" "$probe_sl_ours" "$settings"; then
    jq 'del(.statusLine)' "$settings" > "$settings.tmp"
    commit_settings_tmp
    echo "  remove  statusLine"
  elif jq_probe statusLine "$probe_sl_present" "$settings"; then
    echo "  ok      statusLine (not ours; leaving alone)"
  else
    echo "  ok      statusLine (not present)"
  fi
}

maybe_uninstall_hook() {
  local event="$1" marker="$2"
  if ! jq_probe "hook $event" --arg e "$event" --arg m "$marker" "$probe_hook" "$settings"; then
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
  if ! jq_probe "permission $perm" --arg p "$perm" "$probe_perm" "$settings"; then
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
  if ! jq_probe "hook SessionStart" --arg e SessionStart --arg m "$marker" "$probe_hook" "$settings"; then
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
    settings_seed_state=absent
    echo "  new     $settings (created with {})"
    return 0
  fi
  if [[ ! -s "$settings" ]]; then
    echo '{}' > "$settings"
    settings_seed_state=empty
    echo "  init    $settings was empty; set to {}"
    return 0
  fi
  # Say which of the failures it is (settings_usable, #187/#213): an
  # unreadable file, jq itself failing, and unparseable content are three
  # different causes, and a `null` root is valid JSON that is not an object.
  local usable_rc=0
  settings_usable "$settings" || usable_rc=$?
  if [[ $usable_rc -eq 2 ]]; then
    echo
    echo "  ERROR   jq failed (exit $settings_usable_rc) while reading $settings; refusing to auto-patch (left untouched)."
    echo "          Fix jq and re-run, or patch settings.json by hand:"
    print_manual_snippet
    return 1
  fi
  if [[ $usable_rc -eq 1 && ! -r "$settings" ]]; then
    echo
    echo "  ERROR   $settings cannot be read (check its permissions); refusing to auto-patch (left untouched)."
    echo "          Fix the file's permissions and re-run, or patch settings.json by hand:"
    print_manual_snippet
    return 1
  fi
  if ! jq empty "$settings" >/dev/null 2>&1; then
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
  if [[ $usable_rc -ne 0 ]]; then
    echo
    echo "  ERROR   $settings is valid JSON but not a JSON object (got: $(jq -rs 'if length == 1 then (.[0] | type) else "\(length) documents" end' "$settings" 2>/dev/null))."
    echo "          settings.json must be an object — refusing to auto-patch (left untouched)."
    echo "          Fix or remove it and re-run, or patch settings.json by hand:"
    print_manual_snippet
    return 1
  fi
  return 0
}

# Back up $settings before the first edit and arm the path cleanup()
# restores from. User scope keeps the historical <file>.bak.<ts> next to the
# file. Project scope (issue #171) writes it under $project_backup_dir in
# $claude_home instead, so a backup never sits inside the project where a
# `git add .` would commit it.
take_settings_backup() {
  if [[ "$scope" == project ]]; then
    mkdir -p "$project_backup_dir"
    [[ "$mode" == install ]] && { project_key_claim || true; }
    settings_backup="$project_backup_dir/$settings_name.bak.$ts"
  else
    settings_backup="$settings.bak.$ts"
  fi
  cp "$settings" "$settings_backup"
  echo "  backup  $settings -> $settings_backup"
}

# Project scope (issue #178): remember that THIS installer created the
# project settings file, so a later --uninstall can remove it again once
# nothing but our own empty residue is left in it. The marker holds a
# fingerprint (cksum) of the file as the install left it, so it is bound to
# that file: a file the user deleted and rewrote, or a new project at the
# same path, never matches. Only a file that did not exist is recorded; a
# reinstall over an existing file keeps the marker only while the file is
# still byte-identical to what the marker was written for, and otherwise
# drops it. Writing the marker is best effort: failing to write it must not
# fail an install whose wiring is already in place.
# The backup directory is keyed by a cksum of the project path, and CRC
# collisions are constructible (two paths, one key). So the install writes the
# project's physical path into a `path` file there, and every marker is
# trusted only when that file names THIS project (#194). project_key_check
# sets project_key_state: own (path matches), foreign (another project's),
# legacy (directory exists without a path file: an install from before this
# check; trusted for the created-file marker it could have written), or none.
project_key_state=""
project_key_warned=0
project_key_check() {
  local f="$project_backup_dir/path"
  if [[ -L "$f" ]]; then
    project_key_state=foreign
  elif [[ -f "$f" ]]; then
    if printf '%s\n' "$project_dir" | cmp -s - "$f"; then
      project_key_state=own
    else
      project_key_state=foreign
    fi
  elif [[ -d "$project_backup_dir" ]]; then
    project_key_state=legacy
  else
    project_key_state=none
  fi
}
project_key_warn_foreign() {
  (( project_key_warned )) && return 0
  project_key_warned=1
  echo "  WARN    $project_backup_dir is keyed to another project"
  echo "          ($(head -n 1 "$project_backup_dir/path" 2>/dev/null || true)); its markers are left alone and none are"
  echo "          recorded for $project_dir, so --uninstall will leave what this install created."
}
# Install only: make the key directory this project's. 0 = ours, 1 = another
# project's (WARN printed once), 2 = the path file could not be written (the
# caller's own marker write fails the same way and says so).
project_key_claim() {
  project_key_check
  case "$project_key_state" in
    own) return 0 ;;
    foreign) project_key_warn_foreign; return 1 ;;
  esac
  if ( mkdir -p "$project_backup_dir" && printf '%s\n' "$project_dir" > "$project_backup_dir/path" ) 2>/dev/null; then
    project_key_state=own
    return 0
  fi
  return 2
}
# Uninstall only (#212): drop this project's `path` record once nothing it
# guards is left. The record keeps one project's markers from acting on
# another's (two paths can share a cksum key); with no marker in the
# directory and no other settings file of this project still registered,
# it guards nothing. Backups (*.bak.*) and any file of the user's stay: they
# do not depend on it. A record naming another project is never touched.
project_key_release() {
  project_key_check
  [[ "$project_key_state" == own ]] || return 0
  local other
  for other in settings.json settings.local.json; do
    [[ "$other" == "$settings_name" ]] && continue
    registry_has "$project_dir" "$other" && return 0
  done
  [[ -z "$(find "$project_backup_dir" -maxdepth 1 -name '*.created' 2>/dev/null | head -n 1)" ]] || return 0
  rm -f "$project_backup_dir/path" 2>/dev/null || true
  rmdir "$project_backup_dir" 2>/dev/null || true
}
created_marker() { printf '%s\n' "$project_backup_dir/$settings_name.created"; }
settings_fp() {  # <file>: "<cksum> <bytes>" of the file, empty when unreadable
  # -r first: a failed `<` redirect is reported before 2>/dev/null applies
  # and, under pipefail, used to abort the run with a bare "Permission
  # denied" on a mode-000 file (#187).
  [[ -f "$1" && ! -L "$1" && -r "$1" ]] || return 0
  { cksum < "$1"; } 2>/dev/null | awk '{print $1 " " $2}'
}
# Fingerprint of the settings file before this run's patch touches it.
pre_patch_fp=""
record_created_settings() {
  [[ "$scope" == project ]] || return 0
  local m stored krc=0
  m="$(created_marker)"
  project_key_claim || krc=$?
  (( krc == 1 )) && return 0
  if [[ "$settings_seed_state" == absent ]]; then
    if ! ( mkdir -p "$project_backup_dir" && settings_fp "$settings" > "$m" ) 2>/dev/null; then
      echo "  WARN    cannot record the created-file marker in $project_backup_dir;"
      echo "          --uninstall will leave $settings as an empty skeleton"
    fi
    return 0
  fi
  [[ -f "$m" && ! -L "$m" ]] || return 0
  stored="$(cat "$m" 2>/dev/null || true)"
  if [[ -n "$pre_patch_fp" && "$pre_patch_fp" == "$stored" ]]; then
    settings_fp "$settings" > "$m" 2>/dev/null || true
  else
    rm -f "$m" 2>/dev/null || true
  fi
}

# jq test: the file holds nothing but the empty hooks/permissions skeleton
# (exact: $1 = exact) or that skeleton plus nothing (loose, after a strip).
# Returns jq's own status: 0 skeleton, 1 not, 2 or more = jq failed.
settings_is_skeleton() {  # <file> <exact|loose>
  [[ -f "$1" && ! -L "$1" ]] && command -v jq >/dev/null 2>&1 || return 1
  if [[ "$2" == exact ]]; then
    jq -e '. == {"hooks":{},"permissions":{"allow":[]}}' "$1" >/dev/null 2>&1
  else
    jq -e '
      (if (.hooks // {}) == {} then del(.hooks) else . end)
      | (if (.permissions.allow // []) == [] then del(.permissions.allow) else . end)
      | (if (.permissions // {}) == {} then del(.permissions) else . end)
      | . == {}' "$1" >/dev/null 2>&1
  fi
}

# Project-scope --uninstall, step 1 (before the strip): decide whether this
# file is the one the marker was written for: byte-identical to what this
# installer last wrote. Nothing else qualifies (a hand-written skeleton does
# not). Sets created_pre_ok.
created_pre_ok=0
check_created_settings() {
  local m stored cur
  m="$(created_marker)"
  [[ -f "$m" && ! -L "$m" ]] || return 0
  project_key_check
  [[ "$project_key_state" == foreign ]] && return 0
  stored="$(cat "$m" 2>/dev/null || true)"
  cur="$(settings_fp "$settings")"
  if [[ -n "$cur" && "$cur" == "$stored" ]]; then
    created_pre_ok=1
  fi
}

# True when git tracks <file> in whatever repository holds it. Asked from the
# file's own directory (not the project's), so a .claude/ symlinked into a
# dotfiles repo, or a monorepo above the project, is seen too. A symlinked
# file is checked at its resolved target as well.
git_tracks_file() {
  local f="$1" t
  command -v git >/dev/null 2>&1 || return 1
  git -C "$(dirname "$f")" ls-files --error-unmatch -- "$(basename "$f")" >/dev/null 2>&1 && return 0
  if [[ -L "$f" ]]; then
    t="$(readlink "$f" 2>/dev/null || true)"
    case "$t" in /*) ;; *) t="$(dirname "$f")/$t" ;; esac
    [[ -n "$t" && -d "$(dirname "$t")" ]] \
      && git -C "$(dirname "$t")" ls-files --error-unmatch -- "$(basename "$t")" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# Step 2 (after the strip): delete the file only when the marker matched, the
# strip left nothing but the empty skeleton, and no git repository tracks it
# (a tracked file would show up as a deletion). The marker is consumed either way.
# A jq failure in the skeleton test is not "not a skeleton": the marker stays
# and uninstall_incomplete is set, so the caller keeps the registry line and
# exits non-zero, and a re-run can finish.
remove_created_settings_if_empty() {
  local m src=0
  m="$(created_marker)"
  [[ -f "$m" && ! -L "$m" ]] || return 0
  project_key_check
  if [[ "$project_key_state" == foreign ]]; then
    project_key_warn_foreign
    return 0
  fi
  if (( created_pre_ok )); then
    settings_is_skeleton "$settings" loose || src=$?
    if (( src > 1 )); then
      echo "  ERROR   jq failed (exit $src) while checking whether $settings is the empty skeleton;"
      echo "          $settings and its created-file marker were left in place."
      # The strip above was ours, so re-bind the marker to the stripped file:
      # a re-run then finds it unchanged and can finish the removal.
      settings_fp "$settings" > "$m" 2>/dev/null || true
      uninstall_incomplete=1
      return 0
    fi
    if (( src == 0 )); then
      if git_tracks_file "$settings"; then
        echo "  keep    $settings (tracked by git; left as the empty skeleton)"
      else
        rm -f "$settings"
        echo "  remove  $settings (this installer created it; nothing else was ever written to it)"
      fi
    fi
  fi
  rm -f "$m"
}

patch_settings() {
  if ! command -v jq >/dev/null 2>&1; then
    echo
    echo "jq not found — can't auto-patch $settings."
    print_manual_snippet
    return
  fi
  pre_patch_fp="$(settings_fp "$settings")"
  ensure_settings_json || return
  if [[ -n "$settings_seed_state" ]]; then
    # Neither scope backs up a file this run just seeded as {}: there is
    # nothing to keep, and cleanup() undoes the seed itself on abort.
    settings_backup=""
    if [[ "$settings_seed_state" == absent ]]; then
      echo "  ok      no backup needed ($settings was just created; an abort undoes that)"
    else
      echo "  ok      no backup needed ($settings was empty; an abort empties it again)"
    fi
  else
    take_settings_backup
  fi
  # Arm restore-on-abort: from here until the sequence completes, any abort
  # rolls settings.json back to this backup (see cleanup() / the EXIT trap).
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
  record_created_settings
  # If no change vs backup, drop the redundant backup.
  if [[ -n "$settings_backup" ]] && cmp -s "$settings" "$settings_backup"; then
    rm "$settings_backup"
    echo "  ok      no settings.json changes (backup removed)"
  fi
}

# Set when unpatch_settings (or a step after it) returned without finishing:
# the project-scope uninstall then keeps the markers and the registry line and
# exits non-zero, so a re-run can still clean up.
uninstall_incomplete=0
unpatch_settings() {
  if [[ ! -f "$settings" ]]; then
    echo "  ok      $settings does not exist; nothing to strip"
    return
  fi
  if [[ ! -s "$settings" ]]; then
    echo "  ok      $settings is empty; nothing to strip"
    return
  fi
  # jq is needed only from here on: a file that is absent or empty has nothing
  # to strip, so a machine without jq still completes that uninstall.
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
    uninstall_incomplete=1
    return
  fi
  local usable_rc=0
  settings_usable "$settings" || usable_rc=$?
  if [[ $usable_rc -eq 2 ]]; then
    # jq failed before anything is known about the file (#187): not "nothing
    # to strip", which would exit 0 with the hooks still wired. Nothing has
    # been edited yet, so stop here; the bin/ links are still in place for
    # the re-run (settings are unpatched before the links are removed).
    echo "  ERROR   jq failed (exit $settings_usable_rc) while reading $settings; refusing to edit (left untouched)." >&2
    echo "          Fix jq and re-run the same --uninstall command." >&2
    exit 1
  fi
  if [[ $usable_rc -ne 0 ]]; then
    if [[ ! -r "$settings" ]]; then
      # Unknown content, so the hooks may still be wired: stop before the
      # bin/ links go, as for a jq failure (an ERROR followed by exit 0 and
      # removed links would leave every hook dangling).
      echo "  ERROR   $settings cannot be read (check its permissions); refusing to edit (left untouched)." >&2
      echo "          Fix the file and re-run the same --uninstall command." >&2
      exit 1
    elif jq empty "$settings" >/dev/null 2>&1; then
      # Whitespace only, a non-object root, or several documents: there is
      # no hooks object for this installer to have written, so nothing to strip.
      echo "  ok      $settings is empty or not a JSON object; nothing to strip"
    else
      echo "  ERROR   $settings is not valid JSON; refusing to edit (left untouched)."
      uninstall_incomplete=1
    fi
    return
  fi
  take_settings_backup
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
  if cmp -s "$settings" "$settings_backup"; then
    rm "$settings_backup"
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
# In user scope it consults the wiring: when the user file is unwired but
# the project (or, failing that, a registered project) carries our hooks, a
# bare ./install.sh would wire the wrong scope, so it prints that project's
# command instead (the new-machine or teammate-clone case, where a tracked
# project settings.json arrives without the scripts).
rerun_cmd() {
  local proj first rp rn
  if [[ "$scope" == project ]]; then
    if (( use_local )); then
      printf '%s\n' "./install.sh --scope project --project $(shq "$project_dir") --local"
    else
      printf '%s\n' "./install.sh --scope project --project $(shq "$project_dir")"
    fi
    return 0
  fi
  if ! settings_has_our_hooks "$user_settings"; then
    proj="$(wiring_project_root)"
    if settings_has_our_hooks "$proj/.claude/settings.json"; then
      printf '%s\n' "./install.sh --scope project --project $(shq "$proj")"
      return 0
    fi
    if settings_has_our_hooks "$proj/.claude/settings.local.json"; then
      printf '%s\n' "./install.sh --scope project --project $(shq "$proj") --local"
      return 0
    fi
    registry_collect wired
    first="${REGISTRY_OUT%%$'\n'*}"
    if [[ -n "$first" ]]; then
      rp="${first%%$'\t'*}"; rn="${first#*$'\t'}"
      if [[ "$rn" == settings.local.json ]]; then
        printf '%s\n' "./install.sh --scope project --project $(shq "$rp") --local"
      else
        printf '%s\n' "./install.sh --scope project --project $(shq "$rp")"
      fi
      return 0
    fi
  fi
  printf '%s\n' "./install.sh"
}

# The doctor's closing remedy. When the user file is unwired and the only
# wiring is in several registered projects it names one command (any of them
# restores the shared scripts) and lists the projects it repairs (#178, #194).
# Every other case keeps the one-line form.
rerun_remedy() {
  local list plist n rp rn flag proj tab nl line
  list=""
  if [[ "$scope" != project ]] && ! settings_has_our_hooks "$user_settings"; then
    proj="$(wiring_project_root)"
    registry_collect wired
    list="$REGISTRY_OUT"
    # The project the doctor runs in counts even when it is not registered.
    tab=$'\t'; nl=$'\n'
    for rn in settings.json settings.local.json; do
      line="$proj$tab$rn"
      if settings_has_our_hooks "$proj/.claude/$rn"; then
        if ! printf '%s\n' "$list" | grep -Fxq -- "$line"; then
          if [[ -n "$list" ]]; then list="$line$nl$list"; else list="$line"; fi
        fi
      fi
    done
  fi
  # One entry per project path: a project wired in both settings.json and
  # settings.local.json is still one project to repair.
  plist=""
  if [[ -n "$list" ]]; then
    plist="$(printf '%s\n' "$list" | awk -F'\t' '!seen[$1]++')"
  fi
  n=0
  if [[ -n "$plist" ]]; then n="$(printf '%s\n' "$plist" | wc -l | tr -d ' ')"; fi
  if (( n > 1 )); then
    # The scripts are shared under $claude_home/bin, so one re-run restores
    # them for every wired project: print one command, then list all n
    # projects (the first one is the one in the command) (#194).
    IFS=$'\t' read -r rp rn <<< "$(printf '%s\n' "$plist" | head -n 1)"
    flag=""; [[ "$rn" == settings.local.json ]] && flag=" --local"
    echo "        Re-run ./install.sh --scope project --project $(shq "$rp")$flag from a persistent clone (not a /tmp checkout)."
    echo "        The scripts are shared by every wired project, so that one run repairs all $n:"
    while IFS=$'\t' read -r rp rn; do
      [[ -n "$rp" ]] || continue
      echo "          $rp"
    done <<< "$plist"
  else
    echo "        Re-run $(rerun_cmd) from a persistent clone (not a /tmp checkout)."
  fi
}

# other_project_settings: leave in OTHER_SETTINGS / OTHER_SETTINGS_NAME the
# project settings file the flags did NOT name (settings.json under --local,
# settings.local.json without it). One definition for the doctor's switch
# (#190) and the uninstall refusal below (#209), so both look at the same file.
OTHER_SETTINGS=""; OTHER_SETTINGS_NAME=""
other_project_settings() {
  if (( use_local )); then
    OTHER_SETTINGS_NAME="settings.json"
  else
    OTHER_SETTINGS_NAME="settings.local.json"
  fi
  OTHER_SETTINGS="$project_dir/.claude/$OTHER_SETTINGS_NAME"
}

# The doctor's "statusLine unset" line. In user scope, when the user file
# carries no hooks and rerun_cmd points at a project install (the hooks are
# wired in a project file), re-running that command never writes the user
# file's statusLine, so the old "re-run <cmd> to wire it" remedy changed
# nothing and the next doctor run said the same (#209). Name the file that
# was read instead and point at the doctor that checks the wired file.
sl_unset_line() {
  local cmd
  cmd="$(rerun_cmd)"
  if [[ "$scope" != project && "$cmd" != "./install.sh" ]]; then
    echo "  info    statusLine unset in $settings (the user file). The hooks are"
    echo "          wired in project scope, which writes its statusLine to the project"
    echo "          file instead; to check that one run: ./install.sh --doctor ${cmd#./install.sh }"
  else
    echo "  info    statusLine unset (re-run $cmd to wire it)"
  fi
}

# Project-scope --uninstall whose flags name the project file that holds
# nothing of this installer's while the other project file carries the hooks
# (a --local install uninstalled without --local, or the reverse). Unpatching
# the named file printed "nothing to strip" and exited 0 with the hooks still
# wired (#209). In that case it refuses (exit 2, nothing changed) and prints
# the command for the wired file rather than switching to it: an uninstall
# edits a file the user may also edit by hand, so it edits only the file the
# user named. Detection of the wired file is the doctor's (#190,
# settings_has_our_hooks).
# "Nothing of this installer's" means nothing the uninstall would clean up:
# no matching hook (the legacy SessionStart form included), no statusLine or
# permission of ours, no registry line, no created-file marker, no model-pin
# record for the named file. When any of those is left (hooks deleted by
# hand, or the file deleted with its registry line and marker kept), the
# normal strip runs and other_wired_note names the other file at the end, so
# the doctor's stale-registry remedy still works. A named file that is
# unreadable, not valid JSON, or hits a jq failure is left to
# unpatch_settings, which refuses it as before. When the other file's wiring
# cannot be read (mode 000, a jq failure) and the named file holds nothing,
# it stops with exit 1 instead of "nothing to strip".
# shellcheck disable=SC2016  # jq variables, bound by --arg
probe_any_ours='
  [(.hooks? | objects | .[]?) // empty | .. | objects | .command? | strings] as $c
  | [$ss, $ssl, $se, $post, $wr, $st, $up] as $ms
  | [$p1, $p2, $p3, $p4, $p5, $p6, $p7] as $ps
  | (((.permissions? | objects | .allow?) // []) | if type == "array" then . else [] end) as $al
  | any($c[]; . as $x | any($ms[]; . as $m | $x | contains($m)))
    or (((.statusLine? | objects | .command?) // "") | type == "string" and contains($sl))
    or any($al[]; . as $a | any($ps[]; . == $a))'
other_wired_note=""
refuse_uninstall_if_other_file_wired() {
  local named="$settings" shown="$project_dir/.claude/$settings_name" why rc=0 flag cmd
  local leftovers=0 other_state
  if [[ -L "$shown" && ! -e "$shown" ]]; then
    why="is a dangling symlink"
  elif [[ ! -e "$named" ]]; then
    why="does not exist"
  elif [[ ! -f "$named" ]]; then
    why="is not a regular file"
  elif [[ ! -s "$named" ]]; then
    why="is empty"
  else
    [[ -r "$named" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    settings_usable "$named" || rc=$?
    if (( rc == 1 )); then
      jq empty "$named" >/dev/null 2>&1 || return 0   # invalid JSON: unpatch_settings refuses it
      why="is empty or not a JSON object"
    elif (( rc != 0 )); then
      return 0
    else
      rc=0
      jq -e --arg ss "$ss_marker" --arg ssl "$ss_legacy_marker" --arg se "$se_marker" \
        --arg post "$post_marker" --arg wr "$wr_marker" --arg st "$st_marker" --arg up "$up_marker" \
        --arg sl "$sl_marker" --arg p1 "$perm_write" --arg p2 "$perm_stop" --arg p3 "$perm_ctx" \
        --arg p4 "$perm_ss" --arg p5 "$perm_sl" --arg p6 "$perm_reset" --arg p7 "$perm_wr" \
        "$probe_any_ours" "$named" >/dev/null 2>&1 || rc=$?
      (( rc <= 1 )) || return 0   # jq failure: unpatch_settings reports it
      (( rc == 0 )) && leftovers=1
      why="carries no handoff hooks"
    fi
  fi
  if registry_has "$project_dir" "$settings_name" || [[ -e "$(created_marker)" || -f "$model_pin_record" ]]; then
    leftovers=1
  fi
  other_project_settings
  sh_jq_failed_file=""
  if settings_has_our_hooks "$OTHER_SETTINGS"; then
    other_state=wired
  elif [[ "$sh_jq_failed_file" == "$OTHER_SETTINGS" ]]; then
    other_state=unknown
  else
    return 0
  fi
  if [[ "$OTHER_SETTINGS_NAME" == settings.local.json ]]; then flag=" --local"; else flag=""; fi
  cmd="./install.sh --uninstall --scope project --project $(shq "$project_dir")$flag"
  if (( leftovers )); then
    # Strip what is left of the named file's install as usual; say at the end
    # that the other file is still wired and how to remove it.
    if [[ "$other_state" == wired ]]; then
      other_wired_note="note: $OTHER_SETTINGS still carries the handoff hooks (this uninstall
      stripped $settings_name only). To remove them from $OTHER_SETTINGS_NAME too run:
        $cmd"
    fi
    return 0
  fi
  if [[ "$other_state" == unknown ]]; then
    echo "  ERROR   $shown $why, and whether $OTHER_SETTINGS" >&2
    echo "          carries the handoff hooks is unknown (see the WARN above). Nothing was changed." >&2
    echo "          Fix that file and re-run; if it is the wired one, the command for it is:" >&2
    echo "            $cmd" >&2
    exit 1
  fi
  echo "  ERROR   $shown $why;" >&2
  echo "          $OTHER_SETTINGS carries the handoff hooks." >&2
  echo "          Nothing was changed. To remove them from $OTHER_SETTINGS_NAME run:" >&2
  echo "            $cmd" >&2
  exit 2
}

# Single-quote a path for a printed, copy-pasteable command (a project path
# with a space must survive the paste). Embedded single quotes become '\''.
shq() {
  local q
  q="$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
  printf "'%s'" "$q"
}

# settings_usable <file>: 0 when <file> holds exactly one JSON document and
# that document is an object; 1 when it does not (0 bytes, whitespace only,
# invalid JSON, a non-object root such as [] 42 "x" null, two documents, a
# file this process cannot read); 2 when jq itself failed, so nothing is
# known about the file (settings_usable_rc then holds jq's exit code). Every
# outcome is an answer, so callers never read an unusable file as a jq
# failure, and never read a jq failure as an unusable file (#187). The
# filter cannot fail on the file's content: the file is read raw (-R -s, one
# string, so 0 bytes and whitespace are strings too, never "no valid
# result") and parsed inside try/catch, so a parse error is the answer
# `false` (exit 1), not an exit 2 that would look like a jq usage or system
# error. With content ruled out as a cause, any exit above 1 is jq's own
# failure, with no second probe needed to guess whose fault it was. The
# readability check runs first in bash so a mode-000 file is a plain "not
# usable" its callers can name, not a jq failure. Shared by
# settings_has_our_hooks, unpatch_settings and the doctor's settings gate.
settings_usable_rc=0
settings_usable() {
  local rc=0
  settings_usable_rc=0
  [[ -r "$1" ]] || return 1
  jq -Rse 'try (fromjson | type == "object") catch false' "$1" >/dev/null 2>&1 || rc=$?
  if [[ $rc -le 1 ]]; then return "$rc"; fi
  settings_usable_rc=$rc
  return 2
}

# settings_has_our_hooks <file>: 0 when <file> exists, parses, and wires at
# least one of this installer's hook commands (the markers the patcher
# writes). 1 otherwise, including when jq is missing.
# Set to 1 by settings_has_our_hooks (and doctor's own reads) on a jq failure;
# sh_jq_failed_file names the last file settings_has_our_hooks could not read.
# wired() is total like probe_hook: every level is guarded (`objects`,
# `strings`, `// empty`), so a string, number, boolean, null or array at
# .hooks, .hooks.<event> or deeper is a plain "no", never a jq error that
# would read as a jq failure (tests/test_install_jq_probes_187.sh, matrix).
sh_jq_failed=0
sh_jq_failed_file=""
sh_jq_failed_why=""   # "jq failed" or "permission denied": what the WARN said
# sh_warn_once <file> <why> <line1> <line2>: print the two-line WARN to
# stderr unless this run already printed it for <file> with the same <why>
# (#214): one unreadable file is read by several checks (the doctor's
# pre-check, the wired-files listing) and must not be reported by each.
# sh_jq_failed is set by the callers either way, so the exit code is
# unchanged. Must run in the caller's shell, not a command substitution.
sh_warned=""
sh_warn_once() {
  local key="$2|$1"$'\n'
  case "$sh_warned" in *"$key"*) return 0 ;; esac
  sh_warned="$sh_warned$key"
  echo "$3" >&2
  echo "$4" >&2
}
settings_has_our_hooks() {
  local f="$1" rc=0
  command -v jq >/dev/null 2>&1 || return 1
  # A directory this process cannot search hides the file: `-f` is false for
  # it exactly as for an absent file. Unknown, not "does not exist" (#213);
  # same report as the unreadable file below.
  local d
  d="$(dirname "$f")"
  # Walk up to the nearest ancestor that can be stat'ed: when the project
  # directory, or any directory above it, cannot be searched, everything
  # below it is hidden and the first stat-able one is the unsearchable one.
  while [[ ! -e "$d" && "$d" != "/" && "$d" != "." ]]; do d="$(dirname "$d")"; done
  if [[ -d "$d" && ! -x "$d" ]]; then
    sh_warn_once "$f" "permission denied" "  WARN    $f cannot be read (check its permissions);" \
      "          treating its wiring as unknown. Fix the file and re-run."
    sh_jq_failed=1
    sh_jq_failed_file="$f"
    sh_jq_failed_why="permission denied"
    return 1
  fi
  [[ -f "$f" ]] || return 1
  # A file this process cannot read is unknown, not "not wired": this is the
  # read the user-scope --uninstall registry scan relies on before it deletes
  # the shared secret, and a mode-000 project file may well still be wired.
  # Reported through sh_jq_failed like a jq failure, so every caller that
  # acts on "not wired" stops the same way (the WARN names the real cause).
  if [[ ! -r "$f" ]]; then
    sh_warn_once "$f" "permission denied" "  WARN    $f cannot be read (check its permissions);" \
      "          treating its wiring as unknown. Fix the file and re-run."
    sh_jq_failed=1
    sh_jq_failed_file="$f"
    sh_jq_failed_why="permission denied"
    return 1
  fi
  # An unusable file (empty, unparseable, not an object) is a real "no"
  # (settings_usable), not a jq failure. jq failing inside that check (2) is
  # one, reported like a failure of the wiring read below, for the same
  # reason: "unknown" must never collapse into "not wired".
  settings_usable "$f" || rc=$?
  if [[ $rc -eq 2 ]]; then
    sh_warn_once "$f" "jq failed" "  WARN    jq failed (exit $settings_usable_rc) while checking whether $f is a JSON object;" \
      "          treating its wiring as unknown. Fix jq and re-run."
    sh_jq_failed=1
    sh_jq_failed_file="$f"
    sh_jq_failed_why="jq failed"
    return 1
  fi
  [[ $rc -eq 0 ]] || return 1
  # shellcheck disable=SC2016  # jq variables, bound by --arg
  jq -e --arg ss "$ss_marker" --arg se "$se_marker" --arg post "$post_marker" \
        --arg wr "$wr_marker" --arg st "$st_marker" --arg up "$up_marker" '
      def wired($k; $m): [(.hooks? | objects | .[$k]?) // empty | ..
        | objects | .command? | strings | select(contains($m))] | length > 0;
      type == "object" and (
        wired("SessionStart"; $ss) or wired("SessionEnd"; $se)
        or wired("PreCompact"; $se) or wired("PostCompact"; $post)
        or wired("WorktreeRemove"; $wr) or wired("Stop"; $st)
        or wired("UserPromptSubmit"; $up) )
    ' "$f" >/dev/null 2>&1 || rc=$?
  if [[ $rc -gt 1 ]]; then
    # A jq failure on parseable JSON is not "not wired" (#187). The callers
    # take 0/1, so say it loudly here and record it: doctor exits non-zero,
    # install aborts before registering.
    sh_warn_once "$f" "jq failed" "  WARN    jq failed (exit $rc) while checking whether $f wires handoff hooks;" \
      "          treating it as unknown. Fix jq and re-run."
    sh_jq_failed=1
    sh_jq_failed_file="$f"
    sh_jq_failed_why="jq failed"
    return 1
  fi
  return "$rc"
}

# Physical path of a settings file (symlinks resolved, directory made
# physical), so the wiring check below never counts one file twice: a
# project rooted at $HOME, or a dotfiles link, can make two spellings name
# the same file. Prints nothing when the directory does not exist.
settings_phys_path() {
  local f d
  f="$(resolve_symlink "$1")"
  d="$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)" || return 0
  printf '%s/%s\n' "$d" "$(basename "$f")"
}

# Project root the wiring checks look at: --project in project scope; in
# user scope the git toplevel of $PWD (so a doctor run from a subdirectory
# still finds the project's .claude/), else $PWD itself.
wiring_project_root() {
  local top=""
  if [[ "$scope" == project ]]; then
    printf '%s\n' "$project_dir"
    return 0
  fi
  if command -v git >/dev/null 2>&1; then
    top="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  # Physical, like every project path this installer records or prints.
  [[ -n "$top" ]] || top="$(pwd -P)"
  printf '%s\n' "$top"
}

# Wiring layout check (issue #171). Claude Code runs an identical handler
# defined in more than one settings file once, so several wired files do
# not double fire. What this reports instead:
#   (a) user-scope wiring present alongside a project-scope layout (or at all,
#     in project scope): the hooks then fire in EVERY project on the
#     machine, which the project-only layout exists to avoid;
#   (b) both project files wired: redundant, one can go.
# Lists exactly which of the three files carry our hooks and the uninstall
# command for each extra one. <label> is WARN (doctor) or NOTE (install).
# Advisory only, never counts toward `broken`.
report_wiring() {
  local label="$1" proj pu ps pl u=0 sw=0 lw=0 user_issue=0 dup_issue=0 p1 pc
  proj="$(wiring_project_root)"
  pu="$(settings_phys_path "$user_settings")"
  ps="$(settings_phys_path "$proj/.claude/settings.json")"
  pl="$(settings_phys_path "$proj/.claude/settings.local.json")"
  if [[ -n "$pu" ]] && settings_has_our_hooks "$pu"; then u=1; fi
  if [[ -n "$ps" && "$ps" != "$pu" ]] && settings_has_our_hooks "$ps"; then sw=1; fi
  if [[ -n "$pl" && "$pl" != "$pu" && "$pl" != "$ps" ]] && settings_has_our_hooks "$pl"; then lw=1; fi
  if (( u )) && { [[ "$scope" == project ]] || (( sw || lw )); }; then user_issue=1; fi
  if (( sw && lw )); then dup_issue=1; fi
  if [[ "$label" == NOTE ]]; then p1="NOTE: "; pc="      "; else p1="  WARN    "; pc="          "; fi
  if (( ! user_issue && ! dup_issue )); then
    # A clean layout. The install-time note stays quiet; --doctor still says
    # which file carries the hooks (#190), so a --local install is not left
    # looking like the settings.json it checked first.
    [[ "$label" == WARN ]] && (( u + sw + lw )) || return 0
    p1="  ok      "
  fi
  echo "${p1}this installer's hooks are wired in these settings files for $proj:"
  if (( u ));  then echo "${pc}  $user_settings (user scope)"; fi
  if (( sw )); then echo "${pc}  $proj/.claude/settings.json (project)"; fi
  if (( lw )); then echo "${pc}  $proj/.claude/settings.local.json (project, local)"; fi
  if (( user_issue )); then
    echo "${pc}User-scope wiring present: these hooks fire in every project on this"
    echo "${pc}machine, which the project-only layout exists to avoid. To remove it run"
    echo "${pc}'./install.sh --uninstall --keep-secret'. Keep the secret: the per-machine"
    echo "${pc}HMAC secret is shared by project-scope installs, and dropping it would"
    echo "${pc}invalidate the signed handoffs in every wired project. A user-scope"
    echo "${pc}uninstall also removes the shared scripts in $claude_home/bin, so re-run"
    echo "${pc}the project install afterwards:"
    if (( sw )); then echo "${pc}  ./install.sh --scope project --project $(shq "$proj")"; fi
    if (( lw )); then echo "${pc}  ./install.sh --scope project --project $(shq "$proj") --local"; fi
    if (( ! sw && ! lw )); then echo "${pc}  $(rerun_cmd)"; fi
  fi
  if (( dup_issue )); then
    echo "${pc}Both project files carry the hooks. Claude Code runs them once, so this"
    echo "${pc}is redundant rather than broken; keep one. To remove the extra one run:"
    if [[ "$scope" == project ]] && (( use_local )); then
      echo "${pc}  ./install.sh --uninstall --scope project --project $(shq "$proj")"
    else
      echo "${pc}  ./install.sh --uninstall --scope project --project $(shq "$proj") --local"
    fi
    if [[ "$scope" != project ]]; then
      echo "${pc}  (or drop settings.json instead: the same command without --local)"
    fi
  fi
  echo
}

# --- project registry (issue #171) -------------------------------------------
# $project_registry holds one "<project dir><TAB><file name>" line per
# project-scope install. Never written through a symlink, like the other
# per-user state under $claude_home.
registry_add() {  # <project dir> <settings file name>
  local line="$1"$'\t'"$2"
  if [[ -L "$project_registry" ]]; then
    echo "  skip    registry ($project_registry is a symlink; not writing through it)"
    return 0
  fi
  if [[ -f "$project_registry" ]] && grep -Fxq -- "$line" "$project_registry"; then
    echo "  ok      registry entry present: $1 ($2)"
    return 0
  fi
  mkdir -p "$claude_home"
  printf '%s\n' "$line" >> "$project_registry"
  echo "  add     registry: $1 ($2) in $project_registry"
}

registry_has() {  # <project dir> <settings file name>: 0 when that line is registered
  [[ -f "$project_registry" && ! -L "$project_registry" ]] || return 1
  grep -Fxq -- "$1"$'\t'"$2" "$project_registry"
}

registry_has_dir() {  # <project dir>: 0 when any line registers that directory
  [[ -f "$project_registry" && ! -L "$project_registry" ]] || return 1
  D="$1" awk -F'\t' '$1 == ENVIRON["D"] { found = 1 } END { exit !found }' "$project_registry"
}

registry_remove() {  # <project dir> <settings file name>
  local line="$1"$'\t'"$2"
  [[ -f "$project_registry" && ! -L "$project_registry" ]] || return 0
  grep -Fxq -- "$line" "$project_registry" || return 0
  # grep -v exits 1 when no line survives; that is the empty-registry case.
  grep -Fxv -- "$line" "$project_registry" > "$project_registry.tmp" || true
  mv "$project_registry.tmp" "$project_registry"
  [[ -s "$project_registry" ]] || rm -f "$project_registry"
  echo "  remove  registry: $1 ($2)"
}

# registry_collect <wired|stale>: leave in REGISTRY_OUT one "<dir><TAB><name>"
# line per registered project whose file does (wired) or does not (stale)
# carry our hooks. Callers run it in their own shell, never in a command
# substitution, so a jq failure it hits stays visible in sh_jq_failed (the
# doctor then exits non-zero); a caller that acts on the result (user-scope
# --uninstall deleting the shared secret) must check that. A file whose
# wiring read failed (jq failed, or the file cannot be read) is neither
# wired nor stale: it is left out of both lists, so the doctor never offers
# a removal command for a project it just called unknown. An empty or
# non-object file is a plain stale entry (settings_usable), not a failure.
REGISTRY_OUT=""
# Opt-in (#208): the user-scope --uninstall sets it, because it deletes the
# shared secret on the strength of this scan. With it set, a non-empty file
# that is not valid JSON counts as unknown (sh_jq_failed, like a jq failure),
# not stale: its wiring cannot be read, and it may well still be wired once
# the user fixes it. Left 0 for the doctor, which reports such a file stale.
registry_unparseable_unknown=0
registry_collect() {
  local want="$1" rp rn has nl=$'\n' before failed=0 uf urc
  REGISTRY_OUT=""
  [[ -f "$project_registry" && ! -L "$project_registry" ]] || return 0
  # The flag is cleared per entry and folded back after the loop, so a
  # second failing file after a first one is skipped too (a snapshot taken
  # once would read as "already failed" for every later entry).
  before=$sh_jq_failed
  while IFS=$'\t' read -r rp rn || [[ -n "$rp" ]]; do
    [[ -n "$rp" ]] || continue
    case "$rn" in settings.json|settings.local.json) ;; *) continue ;; esac
    has=stale
    sh_jq_failed=0
    if settings_has_our_hooks "$rp/.claude/$rn"; then has=wired; fi
    uf="$rp/.claude/$rn"
    if (( registry_unparseable_unknown && ! sh_jq_failed )) && [[ -s "$uf" && -r "$uf" ]] \
       && command -v jq >/dev/null 2>&1; then
      urc=0
      settings_usable "$uf" || urc=$?
      if [[ $urc -eq 1 ]] && ! jq empty "$uf" >/dev/null 2>&1; then
        echo "  WARN    $uf is not valid JSON;" >&2
        echo "          treating its wiring as unknown. Fix the file and re-run." >&2
        sh_jq_failed=1
        sh_jq_failed_file="$uf"
        sh_jq_failed_why="not valid JSON"
      fi
    fi
    if (( sh_jq_failed )); then failed=1; continue; fi
    if [[ "$has" == "$want" ]]; then
      REGISTRY_OUT="${REGISTRY_OUT:+$REGISTRY_OUT$nl}$rp"$'\t'"$rn"
    fi
  done < "$project_registry"
  sh_jq_failed=$(( before || failed ))
  return 0
}

# registry_list_cmds <list>: one indented line per "<dir><TAB><name>" entry,
# the entry itself and the copy-pasteable project uninstall for it.
registry_list_cmds() {
  local rp rn flag
  while IFS=$'\t' read -r rp rn; do
    [[ -n "$rp" ]] || continue
    flag=""; [[ "$rn" == settings.local.json ]] && flag=" --local"
    echo "            $rp ($rn)"
    echo "              ./install.sh --uninstall --scope project --project $(shq "$rp")$flag"
  done <<< "$1"
}

# User-scope --uninstall: warn about every registered project still wired,
# since their hooks call the scripts this uninstall removes. <secret_note>
# says what happened to the shared HMAC secret.
report_registry_orphans() {
  local list="$1" secret_note="$2"
  [[ -n "$list" ]] || return 0
  echo "  WARN    project-scope installs still wired (from $project_registry):"
  registry_list_cmds "$list"
  echo "          Their hooks call the scripts this uninstall removes from"
  echo "          $claude_home/bin, so they will silently no-op until each project is"
  echo "          re-wired with ./install.sh --scope project --project <dir>, or"
  echo "          uninstalled with the command listed under it."
  echo "          $secret_note"
}

# User-scope doctor: name registered projects whose file no longer carries
# our hooks. Informational only.
report_registry_stale() {
  local list
  registry_collect stale
  list="$REGISTRY_OUT"
  [[ -n "$list" ]] || return 0
  echo "  note    stale project registry entries (the file no longer carries this"
  echo "          installer's hooks), from $project_registry; clear each with the"
  echo "          command under it (works for a directory that is gone, too):"
  registry_list_cmds "$list"
  echo
}

# >>> PLUGIN_LEFTOVER_CHECK (the one place the shipped tree may name the
# retired plugin layout; tests/test_no_plugin_remnants.sh skips this region)
# A plugin install of this tool left behind after the #171 migration runs its
# own hook commands (under the plugin's root) next to these scripts. Those
# commands differ from ours, so Claude Code's identical-handler dedupe does
# not apply and every hook runs twice. Read-only, jq optional.
#
# Signal: Claude Code's installed_plugins.json registry when it exists (a
# cache directory can outlive an uninstall, so a cache alone would be a
# false positive forever once the registry has dropped the entry); the cache
# glob alone only when there is no registry file at all.
# report_plugin_leftover <NOTE|WARN>: prints the message, or nothing.
report_plugin_leftover() {
  local tag="$1" base pd cache="" reg where scopes=""
  base="${CLAUDE_CONFIG_DIR:-$claude_home}"
  for pd in "$base"/plugins/cache/*/claude-code-handoff; do
    if [[ -d "$pd" ]]; then cache="$pd"; break; fi
  done
  reg="$base/plugins/installed_plugins.json"
  if [[ -f "$reg" ]]; then
    LC_ALL=C grep -q 'claude-code-handoff' "$reg" 2>/dev/null || return 0
    where="${cache:-$reg}"
    if command -v jq >/dev/null 2>&1; then
      scopes="$(jq -r '(.plugins // {}) | to_entries[]
                 | select(.key | startswith("claude-code-handoff@"))
                 | .value | if type == "array" then .[] else . end
                 | .scope? // empty' "$reg" 2>/dev/null | sort -u | tr '\n' '|' | sed 's/|$//' || true)"
    fi
  elif [[ -n "$cache" ]]; then
    where="$cache"
  else
    return 0
  fi
  [[ -n "$scopes" ]] || scopes="project|user"
  case "$scopes" in *"|"*) scopes="<$scopes>" ;; esac
  printf '%-8s%s\n' "$tag" "A plugin install of this tool is still present at $where;"
  echo "        its hooks run alongside these scripts. Finish the migration:"
  echo "        'claude plugin uninstall claude-code-handoff@claude-code-handoff --scope $scopes'"
  echo "        then 'claude plugin marketplace remove claude-code-handoff'."
  echo
}
# <<< PLUGIN_LEFTOVER_CHECK

# Self-check: verify each installed hook script under $claude_home/bin actually
# resolves. A dangling symlink (e.g. installed from a temp checkout that was
# later cleaned up) makes the corresponding hook no-op silently, so surface it
# loudly here. Exit non-zero if anything is broken so CI / a wrapper can detect
# it. (issue #21)

doctor() {
  local broken=0 dst tgt name mdl mdl_rc sl_rc secret smode sign_reason other hint parse_rc why usable_pre
  local flag_settings="" proj f pf pu ps sib_rc sib_check

  if [[ "$scope" == project ]]; then
    echo "doctor: project scope, checking $settings"
    sh_jq_failed_file=""   # set by the read below when it cannot know the answer
    if ! settings_has_our_hooks "$settings"; then
      # settings_has_our_hooks answers 1 for "no hooks" and for a file it
      # cannot use alike. Tell them apart before concluding the flag-named
      # file is merely unwired (#190), with the same total check as every
      # other read (settings_usable, #187):
      # - unknown (unreadable, or jq failed in any of its reads): already
      #   reported there (WARN, sh_jq_failed, non-zero exit), so only the
      #   note below names the cause; never "carries no handoff hooks";
      # - unusable (invalid JSON, empty, not an object, several documents):
      #   named and counted here only when the doctor switches away from it
      #   below; otherwise the statusLine check names it as BROKEN and counts
      #   it, so it is counted exactly once either way.
      parse_rc=0; usable_pre=0; why="carries no handoff hooks"
      if [[ -e "$settings" && ! -f "$settings" ]]; then
        # A directory (or other non-regular file) at the settings path is
        # not "absent" (#216): Claude Code cannot read settings from it, so
        # it is a fault, counted here once, switch or no switch.
        why="is not a regular file"
        echo "  BROKEN  $settings is not a regular file (a directory or special file);"
        echo "          Claude Code cannot read settings from it. Remove it and re-run the installer."
        broken=$((broken + 1))
      elif [[ ! -f "$settings" ]]; then
        why="does not exist"
      elif [[ "$sh_jq_failed_file" == "$settings" ]]; then
        if [[ "$sh_jq_failed_why" == "permission denied" ]]; then
          why="cannot be read"
        else
          why="could not be checked (jq failed)"
        fi
      elif command -v jq >/dev/null 2>&1; then
        settings_usable "$settings" || usable_pre=$?
        if (( usable_pre == 1 )); then
          jq empty "$settings" >/dev/null 2>&1 || parse_rc=$?
          if (( parse_rc )); then why="could not be parsed"; else why="is empty or not a JSON object"; fi
        fi
      fi
      # The other project file may be the one that carries the wiring (a
      # --local install checked without --local, or the reverse): say so
      # instead of leaving the line above as the only file named (#190).
      other_project_settings
      other="$OTHER_SETTINGS"; hint="$OTHER_SETTINGS_NAME"
      if settings_has_our_hooks "$other"; then
        # Switch to the detected file BEFORE the statusLine, model and remedy
        # checks run, so they read it and rerun_cmd carries --local exactly
        # when the wired file is settings.local.json (D1/D2 of the #190 review).
        if (( parse_rc )); then
          echo "  WARN    $settings could not be parsed (jq exit $parse_rc)"
          broken=$((broken + 1))
        elif (( usable_pre == 1 )); then
          echo "  WARN    $settings is empty or not a JSON object"
          broken=$((broken + 1))
        fi
        echo "  note    $settings $why; $other carries the handoff hooks,"
        echo "          so this doctor run checks $hint instead (the flag named the other file)."
        flag_settings="$settings"
        settings="$other"; settings_name="$hint"
        if [[ "$hint" == settings.local.json ]]; then use_local=1; else use_local=0; fi
      fi
    fi
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
  local usable_rc=0
  if command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]]; then
    settings_usable "$settings" || usable_rc=$?
  fi
  if command -v jq >/dev/null 2>&1 && [[ ! -f "$settings" ]]; then
    sl_unset_line
    echo
  elif command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]] && [[ $usable_rc -eq 2 ]]; then
    # jq failed in the usability check itself (#187): nothing is known about
    # the file, which is a jq failure (WARN, exit non-zero below), not a
    # BROKEN file (re-running the installer cannot fix jq).
    echo "  WARN    jq failed (exit $settings_usable_rc) while reading $settings;"
    echo "          its state is unknown. Fix jq and re-run ./install.sh --doctor."
    sh_jq_failed=1
    echo
  elif command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]] && [[ $usable_rc -ne 0 ]]; then
    # Unusable file: the reads below would only report jq failures, and
    # re-running doctor cannot fix the file, so name it once as broken,
    # saying which of the three it is (settings_usable).
    if [[ ! -r "$settings" ]]; then
      echo "  BROKEN  $settings cannot be read (check its permissions)"
    elif jq empty "$settings" >/dev/null 2>&1; then
      echo "  BROKEN  $settings is empty or not a JSON object"
    else
      echo "  BROKEN  $settings is not valid JSON"
    fi
    broken=$((broken + 1))
    echo
  elif command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]]; then
    # Read-only, so a jq failure (exit 2 or more, #187) is a WARN naming the
    # unknown state rather than an abort, and not counted toward `broken`
    # (re-running the installer cannot fix jq). Never a quiet "user's own".
    sl_rc=0
    jq -e --arg m "$sl_marker" "$probe_sl_ours" "$settings" >/dev/null 2>&1 || sl_rc=$?
    if [[ $sl_rc -eq 0 ]]; then
      echo "  ok      statusLine wired (ours)"
    elif [[ $sl_rc -eq 1 ]]; then
      sl_rc=0
      jq -e "$probe_sl_present" "$settings" >/dev/null 2>&1 || sl_rc=$?
      if [[ $sl_rc -eq 1 ]]; then
        sl_unset_line
      elif [[ $sl_rc -eq 0 ]]; then
        echo "  info    statusLine present (user's own; manual wiring documented in README)"
      fi
    fi
    if [[ $sl_rc -gt 1 ]]; then
      echo "  WARN    jq failed (exit $sl_rc) while probing statusLine in $settings;"
      echo "          its state is unknown. Fix jq and re-run ./install.sh --doctor."
      sh_jq_failed=1
    fi
    # Model context-window check: advisory only, never counts toward broken.
    # Only an id whose window depends on the variant picked is worth a WARN:
    # Opus 4.6 and Sonnet 4.6 run at 200k unless the [1m] variant is chosen,
    # which the bare id does not record. Only these two ids are detected.
    # Opus 4.7 and later default to 1M (bin/handoff_ctx_check.sh's model
    # table), so those ids stay quiet. A bare alias (`opus`, `sonnet`) is not
    # detected: on some providers it resolves to a 4.6 model (Microsoft
    # Foundry for `opus`, the Claude Platform on AWS for `sonnet`), which this
    # check cannot see. Any other value (including absent) is a legitimate
    # choice we stay quiet about.
    mdl=""
    mdl_rc=0
    mdl="$(jq -r "$probe_model_read" "$settings" 2>/dev/null)" || mdl_rc=$?
    if [[ $mdl_rc -ne 0 ]]; then
      mdl=""
      echo "  WARN    jq failed (exit $mdl_rc) while reading model from $settings;"
      echo "          its state is unknown. Fix jq and re-run ./install.sh --doctor."
      sh_jq_failed=1
    fi
    case "$mdl" in
      claude-opus-4-6|claude-sonnet-4-6)
        echo "  WARN    model '$mdl' in $settings_name may run at a 200k context window"
        echo "          (the id does not say which variant is picked); for the 1M window"
        echo "          set \"model\": \"${mdl}[1m]\" (edit $settings_name or run"
        echo "          /model ${mdl}[1m] in a session)."
        ;;
    esac
    echo
  fi
  # A project settings file the checks above did not probe is otherwise
  # never parsed by the doctor: report_wiring's read treats unparseable as
  # "not wired", so a corrupt settings.json beside a --local install (or
  # either project file under a user-scope doctor) was silent (#209). Skipped:
  # the file probed above (the statusLine check names it), the flag-named
  # file the doctor switched away from (named before the switch), and the
  # user file. Counted like the flag-named case (#190 H), so the same files
  # give the same exit code whichever flag the doctor was run with.
  # A user-scope doctor checks only a project with a handoff install (a
  # registry line, or a project file carrying the hooks): run from any other
  # directory, a broken settings file there is not this installer's concern
  # and must not fail the doctor.
  sib_check=0
  if command -v jq >/dev/null 2>&1; then
    proj="$(wiring_project_root)"
    if [[ "$scope" == project ]] || registry_has_dir "$proj" \
       || settings_has_our_hooks "$proj/.claude/settings.json" \
       || settings_has_our_hooks "$proj/.claude/settings.local.json"; then
      sib_check=1
    fi
  fi
  if (( sib_check )); then
    pu="$(settings_phys_path "$user_settings")"
    ps="$(settings_phys_path "$settings")"
    for f in "$proj/.claude/settings.json" "$proj/.claude/settings.local.json"; do
      pf="$(settings_phys_path "$f")"
      [[ -n "$pf" && "$pf" != "$pu" && "$pf" != "$ps" ]] || continue
      [[ -n "$flag_settings" && "$pf" == "$(settings_phys_path "$flag_settings")" ]] && continue
      # Only a parse failure is new here: an unreadable file is already
      # reported by report_wiring's read, and an empty file is not an error.
      [[ -f "$pf" && -r "$pf" && -s "$pf" ]] || continue
      sib_rc=0
      settings_usable "$pf" || sib_rc=$?
      (( sib_rc == 1 )) || continue
      sib_rc=0
      jq empty "$pf" >/dev/null 2>&1 || sib_rc=$?
      (( sib_rc )) || continue
      echo "  WARN    $f could not be parsed (jq exit $sib_rc); whether it carries"
      echo "          handoff hooks is unknown. Fix or remove the file, then re-run this doctor."
      broken=$((broken + 1))
      echo
    done
  fi
  report_wiring WARN
  if [[ "$scope" == user ]]; then
    report_registry_stale
  fi
  report_plugin_leftover "  WARN"
  if (( broken )); then
    echo "doctor: $broken issue(s) found." >&2
    rerun_remedy >&2
    return 1
  fi
  if (( sh_jq_failed )); then
    # Exits non-zero (owner decision, see the PR for #187): a jq failure means
    # some state above is unknown, which a clean exit would hide from CI.
    echo "doctor: ${sh_jq_failed_why:-jq failed} while reading settings (see WARN above); fix it and re-run ./install.sh --doctor." >&2
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
  # No usable clone: piped (`curl ... | bash`, no source path), a source path
  # that cannot be entered, or a path that is not a checkout (`bash <(cat
  # install.sh)` gives /dev/fd, which used to install dangling links). An empty
  # root used to surface as `cp: /bin/write_handoff.sh` (#194).
  if [[ -z "$repo_root" ]]; then
    if [[ -n "$repo_root_err" ]]; then
      echo "ERROR: install.sh $repo_root_err, so there is no clone to install from." >&2
    else
      echo "ERROR: install.sh was read from a pipe, so there is no clone to install from." >&2
    fi
    echo "       Clone the repo and run ./install.sh from inside it (see the README)." >&2
    exit 2
  fi
  _rr_phys="$(cd "$repo_root" && pwd -P)"
  case "$_rr_phys/" in
    /dev/*|/proc/*)
      echo "ERROR: install.sh was read from $repo_root (a process-substitution or device path), so there is no clone to install from." >&2
      echo "       Clone the repo and run ./install.sh from inside it (see the README)." >&2
      exit 2 ;;
  esac
  # install.sh itself is self-contained (install.d/ is only its build input),
  # so the checkout test is the file the install links first, bin/write_handoff.sh.
  if [[ ! -f "$repo_root/bin/write_handoff.sh" ]]; then
    echo "ERROR: $repo_root is not a handoff checkout (no bin/write_handoff.sh), so there is no clone to install from." >&2
    echo "       Clone the repo and run ./install.sh from inside it (see the README)." >&2
    exit 2
  fi
  if [[ "$scope" == project ]]; then
    # Refuse a .claude/ or settings link that points nowhere BEFORE anything
    # is copied: creating the missing target directory would put a directory
    # the user never asked for inside their dotfiles, and a marker naming
    # <project>/.claude for it would let a later --uninstall remove the
    # user's pre-existing .claude/ (#194).
    _pc="$project_dir/.claude"
    if [[ -L "$_pc" && ! -d "$_pc" ]]; then
      echo "ERROR: $_pc is a dangling symlink (-> $(readlink "$_pc" 2>/dev/null || true)); refusing to create its target." >&2
      echo "       Create the directory it points to, or remove the link, and re-run." >&2
      exit 2
    elif [[ -e "$_pc" && ! -d "$_pc" ]]; then
      echo "ERROR: $_pc exists but is not a directory; refusing." >&2
      exit 2
    elif [[ -n "$settings_link" && ! -d "$(dirname "$settings")" ]]; then
      echo "ERROR: $settings_link is a dangling symlink (-> $settings, whose directory does not exist); refusing to create it." >&2
      echo "       Create $(dirname "$settings")/, or remove the link, and re-run." >&2
      exit 2
    fi
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
    # Only <project>/.claude itself is ever created (the refusals above rule
    # out a dangling link). It is never removed again, not even by
    # --uninstall: a directory identity check (inode, birth time) cannot be
    # trusted on every filesystem (FAT32), so a recreated .claude/ could be
    # mistaken for ours.
    if [[ ! -e "$project_dir/.claude" && ! -L "$project_dir/.claude" ]]; then
      mkdir "$project_dir/.claude"
      echo "  new     $project_dir/.claude/"
    fi
  else
    echo "settings.json:"
  fi
  patch_settings
  # Record the project once its file actually carries our hooks (a refused
  # patch, e.g. invalid JSON, wires nothing and registers nothing).
  if [[ "$scope" == project ]] && settings_has_our_hooks "$settings"; then
    registry_add "$project_dir" "$settings_name"
  fi
  if (( sh_jq_failed )); then
    echo "  ERROR   jq failed while checking $settings for our hooks; the project was NOT registered." >&2
    echo "          fix jq and re-run $(rerun_cmd)." >&2
    exit 1
  fi
  echo
  if [[ -z "$model_pin" ]] && command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]] \
     && jq -e 'type == "object" and ((.model // null) == null)' "$settings" >/dev/null 2>&1; then
    echo "NOTE: no model pinned in $settings."
    echo "      To pin one there, re-run  $(rerun_cmd) --model '<model>'  (for example 'opus[1m]')."
    echo
  fi
  if [[ "$scope" == project ]]; then
    # Checks all three files (user, project settings.json, project
    # settings.local.json): an extra wired file is reported with the
    # uninstall command that removes it.
    report_wiring NOTE
  fi
  report_plugin_leftover "NOTE:"
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
  if (( project_gone )); then
    # The directory is gone (a removed worktree, usually): nothing left to
    # unpatch, so clear its registry line and stop cleanly.
    echo "project settings ($project_dir):"
    echo "  ok      $project_dir no longer exists; nothing to unpatch"
    if ! registry_has "$project_dir" "$settings_name"; then
      echo "  WARN    no registry line '$project_dir<TAB>$settings_name' in $project_registry;"
      echo "          nothing was cleared there (was the project installed under another path?)"
    fi
    registry_remove "$project_dir" "$settings_name"
    # No file left for the markers to describe. Only this project's: a key
    # directory naming another project is left alone.
    project_key_check
    case "$project_key_state" in
      own|legacy) rm -f "$(created_marker)" 2>/dev/null || true ;;
      foreign) project_key_warn_foreign ;;
    esac
    project_key_release
    echo
    echo "done. the repo at $repo_root is untouched."
    exit 0
  fi
  echo "project settings ($project_dir):"
  # Before anything is read for editing: a refusal changes nothing (#209).
  refuse_uninstall_if_other_file_wired
  check_created_settings
  unpatch_settings
  # A refused or unfinished strip (invalid JSON, no jq, a failed skeleton
  # check) consumes nothing: markers and the registry line stay, so the
  # hooks still wired there are still listed, and a re-run can finish.
  (( uninstall_incomplete )) || remove_created_settings_if_empty
  if (( uninstall_incomplete )); then
    echo
    echo "NOT done: $settings was not fully unpatched (see above). The registry"
    echo "      line and markers were kept; fix it and re-run $(rerun_cmd) --uninstall."
    exit 1
  fi
  registry_remove "$project_dir" "$settings_name"
  project_key_release
  if [[ -n "$other_wired_note" ]]; then
    echo
    printf '%s\n' "$other_wired_note"
  fi
  echo
  echo "kept (project scope): $claude_home/bin scripts, $claude_home/skills, and the"
  echo "      HMAC secret are shared by every project on this machine and were not"
  echo "      removed. Run ./install.sh --uninstall (user scope) to remove them."
  echo
  echo "done. the repo at $repo_root is untouched."
else
  echo "uninstalling handoff skill from $claude_home"
  echo
  # Settings first, then files: a jq-probe abort inside unpatch_settings (#187)
  # restores settings.json and must leave the bin/ scripts the hooks call in
  # place, so a re-run of --uninstall finds everything it needs.
  echo "settings.json:"
  unpatch_settings
  # A refused or unfinished strip (invalid JSON, no jq, #215/#208) leaves the
  # hooks wired. Removing the bin/ links now would leave every one of them
  # dangling and the exit code would call that success: stop before anything
  # is removed, so a re-run after the fix can finish.
  if (( uninstall_incomplete )); then
    echo
    command -v jq >/dev/null 2>&1 || echo "jq is required to strip $settings and was not found on PATH."
    echo "NOT done: $settings was not fully unpatched (see above). The bin/ links,"
    echo "      skills and HMAC secret were kept so the hooks still wired there keep"
    echo "      working; fix it and re-run ./install.sh --uninstall."
    exit 1
  fi
  echo
  echo "symlinks:"
  uninstall_symlinks
  echo
  echo "local state:"
  # Registry first (issue #171 review): projects still wired sign their
  # handoffs with the same per-machine secret, so deleting it here would
  # silently downgrade every one of them. Keep it automatically while any
  # registered project is wired; --remove-secret deletes it anyway.
  # The scan runs in this shell (registry_collect), not a command
  # substitution, so a jq failure on a registered file is seen here. Every
  # unreadable file would read as stale, which would delete the secret those
  # projects still sign with: stop instead, before anything that depends on
  # the scan.
  scan_prev_failed=$sh_jq_failed
  sh_jq_failed=0
  registry_unparseable_unknown=1
  registry_collect wired
  registry_unparseable_unknown=0
  orphan_list="$REGISTRY_OUT"
  if (( sh_jq_failed )); then
    # The re-run repeats the secret flag the user passed, so it does the
    # same thing once jq (or the file) is fixed.
    rerun_flags=""
    if (( remove_secret )); then rerun_flags=" --remove-secret"; fi
    if (( keep_secret )); then rerun_flags=" --keep-secret"; fi
    echo "  ERROR   ${sh_jq_failed_why:-jq failed} while reading $sh_jq_failed_file from the project registry" >&2
    echo "          ($project_registry), so it is unknown which projects still sign" >&2
    echo "          with the HMAC secret; ${HANDOFF_SECRET_FILE:-$claude_home/handoff_secret}" >&2
    echo "          was kept and the registry left as it was. Settings and bin/ links" >&2
    echo "          were already removed above. Fix jq, or fix the file named above," >&2
    echo "          and re-run ./install.sh --uninstall$rerun_flags." >&2
    exit 1
  fi
  sh_jq_failed=$scan_prev_failed
  secret_path="${HANDOFF_SECRET_FILE:-$claude_home/handoff_secret}"
  if [[ -n "$orphan_list" ]] && (( ! remove_secret && ! keep_secret )); then
    orphan_n="$(printf '%s\n' "$orphan_list" | wc -l | tr -d ' ')"
    echo "  keep    $secret_path (kept: $orphan_n project-scope install(s) still sign with"
    echo "          it; pass --remove-secret to delete it anyway)"
    secret_note="The HMAC secret $secret_path was kept for them."
  else
    remove_secret_if_ours
    if [[ -e "$secret_path" ]]; then
      secret_note="The HMAC secret $secret_path is still in place."
    else
      secret_note="The HMAC secret $secret_path is gone, so their signed handoffs no longer verify as binding."
    fi
  fi
  report_registry_orphans "$orphan_list" "$secret_note"
  echo
  echo "done. the repo at $repo_root is untouched."
fi
}
