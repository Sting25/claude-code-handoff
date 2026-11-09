# claude-code-handoff

Claude Code sessions run out of context. This tool writes a short,
human-readable handoff file at the end of a session and loads it
automatically when the next session starts — so you pick up where you
left off instead of starting from a blank slate or an auto-compacted
digest you never read.

**Technical reference:** [docs/reference.md](docs/reference.md)

## What it does

- **Snapshots where you left off** — git state plus a written summary of decisions, open questions, and next steps.
- **Auto-loads that snapshot into your next session** in the same repo — no copy-paste, no kickoff prompt.
- **Follows you into linked git worktrees**: a session in a worktree that has no handoff of its own loads the main checkout's handoff as inherited context (standing rules included), and never asks you to recover a session that never ran there.
- **Keeps a per-turn backup**, so a crashed or killed session can be reconstructed afterwards.
- **Saves a mechanical git-state snapshot on every clean exit**, even if you forget to hand off.
- **Nudges you when context is filling** (about 100k tokens in, or 40% of the window on smaller models), while Claude is still sharp enough to write a good summary, so you hand off confidently instead of riding a bloated session, which also means less context re-processing and fewer wasted tokens.
- **Signs each handoff with a per-machine key**, so a cloned repo can't inject fake standing rules.
- **Keeps a history of past handoffs** (last 5 by default) that you can pull back into context on demand.
- **Auto-rebuilds a missing or corrupted handoff on load**: if `handoff_current.md` is missing, empty, unreadable, or fails an integrity check, the next session start composes a best-effort stand-in from your history and per-turn backups instead of loading nothing, clearly labeled `AUTO-REBUILT` and never written to disk or signed.
- **Guards against a stale resumed session clobbering a fresher one's handoff** — refuses (exit 3) rather than silently rotating a newer session's curated work under an older one's; see [Cross-session overwrite guard](docs/reference.md#cross-session-overwrite-guard).
- **Works in git and non-git projects**, in both the Claude Code CLI and the desktop app.

## Installation

One install path: clone the repo and run `install.sh`. The recommended
layout wires the hooks into one project only, so the tool runs where you
opted in and nowhere else:

```bash
git clone https://github.com/Sting25/claude-code-handoff.git ~/code/claude-code-handoff
cd ~/code/claude-code-handoff
./install.sh --scope project --project ~/code/myapp
```

The installer symlinks the scripts into `~/.claude/bin` and the skills
into `~/.claude/skills`, then writes the seven hooks, the status line,
and the permission entries into `~/code/myapp/.claude/settings.json`
(backed up first; idempotent; your own settings are left untouched).
`~/.claude/settings.json` is not touched. Add `--local` to target
`.claude/settings.local.json` instead (that file is per machine and not
committed, so its hooks do not reach the project's git worktrees). Run
`--scope project` from inside the project to skip `--project`. Repeat
the command for each project that should have the handoff; every wired
project shares the same scripts in `~/.claude/bin`.

What to expect:

- Only wired projects run the hooks. The skills (`/handoff`,
  `/handoff-more`, `/handoff-recover`) are installed for your user, but
  they need the hooks and do nothing useful in a project that is not
  wired.
- Project scope in `.claude/settings.json` also covers that repo's git
  worktrees.
- Collaborators run the installer themselves. A committed
  `.claude/settings.json` that names `~/.claude/bin` scripts is harmless
  on a machine without the install: every hook command ends in
  `2>/dev/null || true`, so it does nothing there.

Plain `./install.sh` (no scope flag) still wires the hooks into
`~/.claude/settings.json`, which makes them run in every project on the
machine. Avoid that wiring if you want the tool in one project only; the
doctor warns when the user file and a project file both carry the hooks.

Uninstall a project with the same flags:
`./install.sh --uninstall --scope project --project ~/code/myapp`. That
strips only that project's settings file and keeps the shared scripts,
skills, and HMAC secret for your other projects.

The tracked `settings.json` carries this machine's absolute home path in
its `permissions.allow` entries. `--local` keeps that out of git, at the
cost of not applying inside worktrees (`settings.local.json` is
gitignored and per checkout).

`install.sh` is a generated artifact (concatenated from `install.d/`
by `tools/build-install.sh`; CI rebuilds and diffs it on every change)
and ships with a checksum. Inside a full clone, git already guarantees
integrity, but if you ever fetch `install.sh` on its own instead of
cloning, fetch `install.sh.sha256` from the same tag and verify before
running:

```bash
shasum -a 256 -c install.sh.sha256
```

A mismatch means a corrupted or tampered download: don't run it. (Both
files travel the same channel, so this catches corruption and casual
tampering, not a fully compromised host.)

### Using it

Once installed, in a wired project:

- **`/handoff`**: run at the end of a working session; writes the snapshot and fills in the "Notes from this session" prose block. Invoke at 30-50% context remaining, not at 5%.
- **`/handoff-recover`**: run when a new session shows an `ACTION: RUN /handoff-recover` banner; reconstructs the notes a crashed or un-handed-off session never wrote.
- **`/handoff-more`**: run in a fresh session to pull older handoffs into context, beyond the most recent one that auto-loads.

Everything else (loading, per-turn backups, the context nudge) runs
through hooks without you thinking about it.

### Keeping signed handoffs across a reinstall

A user-scope `./install.sh --uninstall` deletes the per-machine HMAC
secret at `~/.claude/handoff_secret` by default (see [Uninstall
details](docs/reference.md#uninstall-details)) so no key material is
left behind by a tool you removed. If you are uninstalling only to
reinstall (for example to move from user scope to `--scope project`)
and have already-signed `handoff_current.md` files (or entries in
`handoff_history/`) you want to keep verifying as binding rules, run
`./install.sh --uninstall --keep-secret` instead: it skips that
deletion. Without `--keep-secret`, existing signed handoffs still load
fine, just as reference data instead of binding rules, and `/handoff`
re-signs new ones under a fresh secret. A project-scope uninstall never
removes the secret.

### Migrating from the plugin (0.19 and earlier)

Versions up to 0.19 also shipped as a Claude Code plugin, and 0.19.0 is
the last version published as a plugin. That distribution is gone;
`install.sh` is the only install path. To move a plugin install over:

1. Remove the plugin at the scope you installed it with (`--scope
   project` for a per-project install, `--scope user` for a global one,
   `--scope local` if you used that; the default is `user`). Project and
   local scope act on the `.claude/` settings of the directory you run the
   command in, so run it from inside the project directory:

   ```bash
   cd <dir>
   claude plugin uninstall claude-code-handoff@claude-code-handoff --scope project
   ```

2. Remove the marketplace entry:

   ```bash
   claude plugin marketplace remove claude-code-handoff
   ```

3. Install the scripts and wire the project:

   ```bash
   ./install.sh --scope project --project <dir>
   ```

The HMAC secret is per machine (`~/.claude/handoff_secret`), and the
plugin read the same file, so handoffs it signed keep verifying as
binding rules after the switch. Until the plugin is gone, the installer
and `./install.sh --doctor` say so: its hook commands differ from the
installer's, so both sets would run on every event.

## Requirements

- `bash` and `jq`. If `jq` is not on PATH, the installer refuses to
  install (`exit 1`) because the Stop hook, context nudge, and
  `/handoff-recover` all depend on it at runtime. (`--uninstall` and
  `--doctor` still work without `jq`.)
- `git` — optional since 0.8.4. Outside a git worktree the snapshot
  simply omits the git sections and the project directory becomes the
  root; the installer runs no git at all.
- `perl` — optional. The Stop hook and `/handoff-recover` use it to
  strip transcript noise and fall back to `cat` when it is absent, so
  the dumps are just noisier without it.
- `openssl` — optional. Without it, handoffs aren't HMAC-signed and
  the rules layer loads as reference data instead of binding; nothing
  errors.
- Tested on Linux — that CI job blocks. The macOS CI job (bash 3.2 /
  BSD userland) is advisory, non-blocking; the scripts handle BSD
  differences like `flock` and `date`. Windows (Git Bash / WSL) is
  untested in CI.

## How it works

Seven hooks drive it, written by the installer into the project's
`.claude/settings.json` (or `~/.claude/settings.json` for a user-scope
install):
`SessionStart` loads the latest handoff into a new session,
`SessionEnd` and `PreCompact` write a mechanical git-state safety net
before an ending or a compaction, `Stop` appends each turn to a
backup and records context usage, `UserPromptSubmit` nudges you
toward `/handoff` once usage crosses about 100k tokens (or 40% of the
window, whichever comes first), and
`PostCompact` resets those measurements so the freed window is
treated as fresh, and `WorktreeRemove` salvages a removed git
worktree's handoff and raw dumps into the main checkout (see
"Worktree sessions" in the reference). Handoffs are signed with a per-machine HMAC key, so
a cloned repo can't inject fake standing rules: only rules with a
valid signature load as binding, everything else loads as inert
reference text.

See [docs/reference.md](docs/reference.md) for the full technical
reference: hook internals, file formats, the signing design, and the
optional status line.

## Configuration

Configuration is entirely through `HANDOFF_*` environment variables
set in your shell rc file (`~/.bashrc`, `~/.zshrc`): how many old
handoffs to keep, the context-window size the nudge uses, whether
trusted rules are enabled, and more. Defaults work for a normal
single-repo project; you only need to touch these for non-default
setups (a shared substrate repo, a custom pinned-context path, tuning
how aggressively the nudge fires).

See [docs/reference.md](docs/reference.md) for the full technical
reference (hook internals, file formats, signing design, every
environment variable) and
[skills/handoff/README.md](skills/handoff/README.md) for the complete
`/handoff` env-var list.

## Updating, doctor, uninstall

Symlink install means updating is just `git pull` in the clone (live next session, no
re-install (re-run `./install.sh` only when
[`CHANGELOG.md`](CHANGELOG.md) says a hook changed). Run
`./install.sh --doctor` anytime to confirm every installed hook still
resolves (add `--scope project --project <dir>` to check a project's
wiring; it also warns when the user file and a project file both carry
the hooks). `./install.sh --uninstall`
removes the symlinks, strips only the entries it can prove are its own
from settings.json (backup first), and deletes the per-machine HMAC
secret — details in
[docs/reference.md](docs/reference.md#uninstall-details).

Installing from a volatile path (`/tmp`, CI scratch) auto-switches to
copy mode; `--copy` / `--link` force it, and `--model 'opus[1m]'` pins
the model on a new machine. See
[docs/reference.md](docs/reference.md#install-internals).

## Going deeper

- [docs/reference.md](docs/reference.md) — full reference: the four
  paths in detail, context tracking, status line internals, retention
  edge cases, pinned context, trusted-rules design, install internals.
- [docs/handoff-pattern.md](docs/handoff-pattern.md) — design
  philosophy: why state lives on the filesystem and the handoff
  carries only what it can't; the WRITE/READ discipline.
- [skills/handoff/README.md](skills/handoff/README.md) — skill spec,
  env vars, and limitations worth knowing — notably that Claude Code
  can't force a session restart at a context threshold, so the human
  keystroke is still required.

## Develop

Edits land live (symlink install). Run the test suite with
`./tests/run.sh` — dependency-free bash + git (tests needing
`jq`/`perl` self-skip when absent). Each suite file is a standalone
`tests/test_*.sh`. New changes ship with a test. If you change a hook
command string or add a new hook/permission, update `CHANGELOG.md` so
users know to re-run `./install.sh` after pulling.

## License

[MIT](LICENSE).
