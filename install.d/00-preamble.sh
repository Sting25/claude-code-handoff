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
  2. Patches ~/.claude/settings.json to add seven hooks
     (SessionStart / SessionEnd / PreCompact / PostCompact / WorktreeRemove / Stop /
     UserPromptSubmit), seven permission entries, and (only when you
     don't already have one) a statusLine command (never overwrites
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
# Project scope only (issue #171): a settings file this run seeded as {}
# gets no backup (there was nothing to keep), so an abort puts back what
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
    echo "       Use --scope user to patch $user_settings." >&2
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
  project_backup_dir="$claude_home/handoff_settings_backups/$(printf '%s' "$project_dir" | cksum | awk '{print $1}')"
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

