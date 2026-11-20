# Privacy

claude-code-handoff runs entirely on your machine. There is no server
component, no telemetry, no analytics, and no network access of any
kind — the shipped scripts contain no `curl`, `wget`, or socket calls.

## What it reads

- The JSON payloads Claude Code passes to its hooks (session id,
  working directory, transcript path) and the session transcript at
  that path.
- Your project's git state (via local `git` commands), when in a git repo.
  If you set `HANDOFF_SUBSTRATE_NAME`, the git state of that sibling
  repo too.
- The pinned-context file (`.claude/handoff_pinned.md` by default),
  when it exists.
- For `/handoff-recover`, the lost session's transcript, looked up by
  session id under `~/.claude/projects/`.
- The installer reads the settings file it patches and, to report a
  leftover install of the retired packaged distribution, Claude Code's
  `plugins/installed_plugins.json` when that file exists.

## What it writes, and where

- Handoff artifacts — the current handoff, rotated history, and
  per-turn backups — under the project's own `.claude/` directory.
- Installed scripts and skills under `~/.claude/`, and the hook
  configuration in the project's `.claude/settings.json` (or
  `.claude/settings.local.json` with `--local`, or `~/.claude/settings.json`
  for a user-scope install).
- The per-machine signing secret at `~/.claude/handoff_secret`
  (file mode 600). It is generated locally, never transmitted, and
  never written into any repository.
- Installer bookkeeping under `~/.claude/`: `handoff_projects` (the
  paths of the projects you wired), `handoff_settings_backups/`
  (backups of project settings files, made before each patch),
  `<settings file>.bak.<timestamp>` backups for a user-scope install,
  `handoff-model-pin*` (only with `--model`), and `handoff-install.log`
  (only when the installer replaced a symlink that was already there).
- Short-lived temporary files during atomic writes, created alongside
  their target files in the directories above (with a rare fallback to
  the system temp dir if a target directory isn't writable). At each
  session start the loader also buffers its output (the handoff text
  it is about to load) in a temporary file in the system temp dir
  (`$TMPDIR`, else `/tmp`) and deletes it when it exits.

## What leaves your machine

Nothing — unless you yourself commit and push a `.claude/` handoff
file. Handoff files can contain session notes (summaries of your work,
file paths, decisions), so treat them like any other working notes.
The tool automatically adds its artifact paths to the project's
`.gitignore` (skippable with `HANDOFF_NO_GITIGNORE_BOOTSTRAP=1`), and
never pushes them itself.

## Data retention and deletion

Handoff history keeps the last 5 snapshots by default (configurable
via `HANDOFF_HISTORY_KEEP`). Deleting a project's `.claude/` handoff
files and, if desired, `~/.claude/handoff_secret` removes the handoff
content and the signing key. `./install.sh --uninstall` removes the
installed scripts. Settings backups and `handoff-install.log` can
remain under `~/.claude/` afterwards; delete them by hand if you want
nothing left.

Questions: open an issue at
<https://github.com/Sting25/claude-code-handoff/issues>.
