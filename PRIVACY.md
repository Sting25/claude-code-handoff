# Privacy

claude-code-handoff runs entirely on your machine. There is no server
component, no telemetry, no analytics, and no network access of any
kind — the shipped scripts contain no `curl`, `wget`, or socket calls.

## What it reads

- The JSON payloads Claude Code passes to its hooks (session id,
  working directory, transcript path) and the session transcript at
  that path.
- Your project's git state (via local `git` commands), when in a git repo.

## What it writes, and where

- Handoff artifacts — the current handoff, rotated history, and
  per-turn backups — under the project's own `.claude/` directory.
- Installed scripts and configuration under `~/.claude/` (bare-scripts
  install) or Claude Code's plugin cache (plugin install).
- The per-machine signing secret at `~/.claude/handoff_secret`
  (file mode 600). It is generated locally, never transmitted, and
  never written into any repository.
- Short-lived temporary files during atomic writes, created alongside
  their target files in the directories above (with a rare fallback to
  the system temp dir if a target directory isn't writable).

## What leaves your machine

Nothing — unless you yourself commit and push a `.claude/` handoff
file. Handoff files can contain session notes (summaries of your work,
file paths, decisions), so treat them like any other working notes.
The plugin automatically adds its artifact paths to the project's
`.gitignore` (skippable with `HANDOFF_NO_GITIGNORE_BOOTSTRAP=1`), and
pushing them is never done by the plugin itself.

## Data retention and deletion

Handoff history keeps the last 5 snapshots by default (configurable
via `HANDOFF_HISTORY_KEEP`). Deleting a project's `.claude/` handoff
files and, if desired, `~/.claude/handoff_secret` removes everything
the plugin has stored. `./install.sh --uninstall` removes the
installed scripts.

Questions: open an issue at
<https://github.com/Sting25/claude-code-handoff/issues>.
