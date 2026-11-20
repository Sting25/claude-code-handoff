# claude-code-handoff

Claude Code sessions run out of context. When that happens you either
start over from a blank slate or trust an auto-compacted digest you
never read.

This tool gives you a third option. At the end of a session it writes a
short handoff file you can actually read, and the next session in the
same project loads it automatically. You pick up where you left off.

- **Works in:** the Claude Code CLI and the desktop app, in git and
  non-git projects.
- **Installs with:** one shell script. No package manager, no plugin.
- **Full reference:** [docs/reference.md](docs/reference.md)

## Quick start

Install it for one project:

```bash
git clone https://github.com/Sting25/claude-code-handoff.git ~/code/claude-code-handoff
cd ~/code/claude-code-handoff
./install.sh --scope project --project ~/code/myapp
```

Then, in that project:

| Command | When to use it |
|---|---|
| `/handoff` | At the end of a working session. Writes the snapshot and your notes. |
| `/handoff-recover` | When a new session shows an `ACTION: RUN /handoff-recover` banner. |
| `/handoff-more` | When you want older handoffs, not just the latest one. |

Start a new session and the handoff is already there. Loading,
per-turn backups, and the context nudge all run through hooks, so
there is nothing else to remember.

**A tip on timing:** run `/handoff` while there is still room to think,
with 30 to 50% of the context left. At 5% the summary will be poor.

## What you get

**Picking up where you left off**

- A snapshot of where things stand: git state plus a written summary
  of decisions, open questions, and next steps.
- That snapshot loads into your next session in the same project. No
  copy-paste, no kickoff prompt.
- A history of past handoffs (the last 5 by default) that you can pull
  back in with `/handoff-more`.

**Not losing work**

- Your written notes stay put. If a later session ends without running
  `/handoff`, the handoff you wrote is kept as it is, and one line is
  added under its notes saying a later session ran and where its raw
  turn log is.
- If you never ran `/handoff` at all, a session ending or a compaction
  still leaves a mechanical git-state snapshot behind.
- Every turn is appended to a backup, so a crashed or killed session
  can be reconstructed afterwards with `/handoff-recover`.
- If the handoff file is missing, empty, or damaged, the next session
  builds a stand-in from your history and backups. It is labeled
  `AUTO-REBUILT`, never written to disk, and never signed.
- An older session that you resume cannot overwrite a newer session's
  handoff. The write is refused instead. See the
  [cross-session overwrite guard](docs/reference.md#cross-session-overwrite-guard).

**Staying ahead of a full context**

- A nudge appears when context reaches 30% of the window, then again
  every 5 points. If the window size is unknown, it appears at 100k
  tokens instead.
- The point is to hand off while Claude is still sharp enough to write
  a good summary. That also means less re-processing and fewer wasted
  tokens.

**Worktrees**

- A session in a linked git worktree that has no handoff of its own
  loads the main checkout's handoff, standing rules included.
- It is never asked to recover a session that did not run there.

**Trust**

- Each handoff is signed with a key that stays on your machine.
- Only rules with a valid signature load as binding. A cloned repo
  cannot plant standing rules for your next session; anything unsigned
  loads as plain reference text.

## Install

### One project (recommended)

```bash
./install.sh --scope project --project ~/code/myapp
```

What that does:

- Links the scripts into `~/.claude/bin` and the skills into
  `~/.claude/skills`.
- Writes seven hooks, a status line, and seven permission entries into
  `~/code/myapp/.claude/settings.json`.
- Backs that file up first, and leaves your own settings alone.
- Does not touch `~/.claude/settings.json`.

It is safe to run again. Repeat it for each project that should have
the handoff; they all share the same scripts.

Good to know:

- **Run it from inside the project** and you can drop `--project`.
- **Only wired projects run the hooks.** The three slash commands are
  installed for your user, but they do nothing useful in a project
  that is not wired.
- **Git worktrees of the project are covered** when the hooks live in
  `.claude/settings.json`.
- **Collaborators install it themselves.** If you commit
  `.claude/settings.json`, it is harmless on a machine without the
  install: every hook command discards its output and ends in
  `|| true`, so it does nothing there.

### Keeping it out of git: `--local`

The project's `settings.json` ends up with your home directory path in
its permission entries. If you would rather not commit that:

```bash
./install.sh --scope project --project ~/code/myapp --local
```

This writes to `.claude/settings.local.json`, which is per machine and
not committed. The trade-off: that file does not reach the project's
git worktrees, so the hooks will not run there.

### Every project on the machine

```bash
./install.sh
```

With no scope flag, the hooks go into `~/.claude/settings.json` and run
in every project. Skip this if you want the tool in one project only.
The doctor warns you when both your user file and a project file carry
the hooks.

### Check, update, uninstall

- **Check:** `./install.sh --doctor` confirms every installed hook
  still resolves. Add `--scope project --project <dir>` to check one
  project.
- **Update:** `git pull` in the clone. The install is a set of
  symlinks, so the new scripts are live in your next session. Re-run
  `./install.sh` only when [CHANGELOG.md](CHANGELOG.md) says a hook
  changed.
- **Uninstall one project:**
  `./install.sh --uninstall --scope project --project ~/code/myapp`.
  This strips only that project's settings file. The shared scripts,
  skills, and signing key stay for your other projects.
- **Uninstall everything:** `./install.sh --uninstall`. This removes
  the links, strips only the entries it can prove are its own (after a
  backup), and deletes the signing key. Details are in
  [the reference](docs/reference.md#uninstall-details).

A few install options you will rarely need:

- Installing from a temporary path (`/tmp`, a CI scratch directory)
  switches to copying the files, since links would dangle. Copies do
  not update on `git pull`, so re-run the installer after pulling.
- `--copy` and `--link` force one mode or the other.
- `--model 'opus[1m]'` pins the model on a new machine.

More in [install internals](docs/reference.md#install-internals).

<a id="keeping-signed-handoffs-across-a-reinstall"></a>

<details>
<summary><strong>Reinstalling without losing your signed handoffs</strong></summary>

A full `./install.sh --uninstall` deletes the signing key at
`~/.claude/handoff_secret`, so that no key material is left behind by a
tool you removed.

- If a registered project is still wired, the key is kept, because
  that project signs with it. The uninstall tells you so.
  `--remove-secret` deletes it anyway.
- If you are uninstalling only to reinstall (for example, to move from
  every-project to one-project wiring), use
  `./install.sh --uninstall --keep-secret`. Your existing handoffs keep
  verifying.
- Without `--keep-secret`, existing signed handoffs still load. Their
  rules just load as reference text instead of binding rules, and
  `/handoff` signs new ones with a fresh key.
- A project-scope uninstall never removes the key.

</details>

<details>
<summary><strong>Verifying <code>install.sh</code> if you download it on its own</strong></summary>

`install.sh` is generated from the files in `install.d/` by
`tools/build-install.sh`. CI rebuilds it and compares on every change,
and it ships with a checksum.

In a full clone, git already guarantees integrity. If you fetch
`install.sh` by itself, fetch `install.sh.sha256` from the same tag and
check it before running:

```bash
shasum -a 256 -c install.sh.sha256
```

A mismatch means a corrupted or tampered download, so do not run it.
Both files travel the same channel, which means this catches
corruption and casual tampering, not a fully compromised host.

</details>

### Migrating from the plugin (0.19 and earlier)

Versions up to 0.19 were also published as a Claude Code plugin. That
is gone. `install.sh` is the only way to install now. To move over:

1. Remove the plugin at the scope you installed it with.
   `claude plugin list` shows the scope. For a global install:

   ```bash
   claude plugin uninstall claude-code-handoff@claude-code-handoff --scope user
   ```

   For a per-project install, run it from inside the project (use
   `--scope local` if that is how you installed it):

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

The signing key is the same file the plugin used, so handoffs it
signed keep verifying after the switch. Until the plugin is removed,
the installer and `./install.sh --doctor` remind you, because both
sets of hooks would otherwise run on every event.

## What it needs

- **`bash` and `jq`.** The installer refuses to run without `jq`.
- **Linux or macOS.** CI runs the tests on Linux (bash 5) and macOS
  (bash 3.2 with the BSD tools), and both must pass. Windows through
  Git Bash or WSL is untested.

Three more tools are used when they are present:

- **`git`:** outside a git repository the snapshot leaves out the git
  sections and treats the project directory as the root.
- **`openssl`:** without it handoffs are not signed, so standing rules
  load as reference text instead of binding rules.
- **`perl`:** without it the per-turn backups keep some transcript
  noise that would otherwise be stripped.

## How it works

The installer wires seven hooks into the project's settings file:

| Hook | What it does |
|---|---|
| `SessionStart` | Loads the latest handoff into the new session. |
| `Stop` | Appends the finished turn to a backup and records context usage. |
| `UserPromptSubmit` | Shows the nudge toward `/handoff` as context fills. |
| `SessionEnd` | Safety net. Keeps a handoff you wrote, or writes a git-state snapshot if you never wrote one. |
| `PreCompact` | The same safety net, just before a compaction. |
| `PostCompact` | Resets the context measurements so the freed window counts as fresh. |
| `WorktreeRemove` | Saves a removed worktree's handoff and turn backups into the main checkout. |

The handoff itself is a Markdown file at
`.claude/handoff_current.md` in your project. When a new handoff
replaces one you wrote, the old one is archived in
`.claude/handoff_history/`.

## Configuration

The defaults suit a normal single-repo project. Everything else is set
through `HANDOFF_*` environment variables in your shell rc file
(`~/.bashrc`, `~/.zshrc`), for example:

- how many old handoffs to keep,
- the context-window size the nudge assumes,
- how eagerly the nudge fires,
- whether trusted rules are enabled.

The variables are documented in
[docs/reference.md](docs/reference.md) and in
[skills/handoff/README.md](skills/handoff/README.md).

## Going deeper

- [docs/reference.md](docs/reference.md): the full reference. Each
  path in detail, context tracking, the status line, retention,
  pinned context, the signing design, and install internals.
- [docs/handoff-pattern.md](docs/handoff-pattern.md): the thinking
  behind it. Why state lives on the filesystem and the handoff carries
  only what the filesystem cannot.
- [skills/handoff/README.md](skills/handoff/README.md): the skill
  itself, its environment variables, and its limits. The main one:
  Claude Code cannot force a session restart at a context threshold,
  so starting the new session is still up to you.
- [PRIVACY.md](PRIVACY.md): what the tool reads and writes, and where.

## Developing

- A symlink install means your edits are live right away.
- Run the tests with `./tests/run.sh`. They need only bash and git;
  tests that need `jq` or `openssl` skip themselves when the tool is
  missing.
- Each test file is a standalone `tests/test_*.sh`. New changes ship
  with a test.
- If you change a hook command or add a hook or permission entry, say
  so in `CHANGELOG.md`, so people know to re-run `./install.sh` after
  pulling.
- Before a release, run `tools/e2e_multi_session.sh` on the release
  tree. See [the reference](docs/reference.md) for what it checks.

## License

[MIT](LICENSE).
