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
- **Keeps a per-turn backup**, so a crashed or killed session can be reconstructed afterwards.
- **Saves a mechanical git-state snapshot on every clean exit**, even if you forget to hand off.
- **Nudges you when context is filling** (~40% used), while Claude is still sharp enough to write a good summary — so you hand off confidently instead of riding a bloated session, which also means less context re-processing and fewer wasted tokens.
- **Signs each handoff with a per-machine key**, so a cloned repo can't inject fake standing rules.
- **Keeps a history of past handoffs** (last 5 by default) that you can pull back into context on demand.
- **Auto-rebuilds a missing or corrupted handoff on load**: if `handoff_current.md` is missing, empty, unreadable, or fails an integrity check, the next session start composes a best-effort stand-in from your history and per-turn backups instead of loading nothing, clearly labeled `AUTO-REBUILT` and never written to disk or signed.
- **Guards against a stale resumed session clobbering a fresher one's handoff** — refuses (exit 3) rather than silently rotating a newer session's curated work under an older one's; see [Cross-session overwrite guard](docs/reference.md#cross-session-overwrite-guard).
- **Works in git and non-git projects**, in both the Claude Code CLI and the desktop app.

## Installation

Two supported install modes, both fully maintained: install as a
**plugin** (recommended — hooks and skills come with it automatically,
no manual patching) or install the **bare scripts** (legacy, still
fully supported) into `~/.claude/`. Pick one — see
[Dual-mode warning](#dual-mode-warning) below before running both.

### Plugin install (recommended)

Inside Claude Code:

```
/plugin marketplace add Sting25/claude-code-handoff
/plugin install claude-code-handoff@claude-code-handoff
```

This adds the `claude-code-handoff` marketplace — self-hosted in this
repo at [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json)
— and installs the `claude-code-handoff` plugin from it. Hooks
([`hooks/hooks.json`](hooks/hooks.json)) and skills (`skills/`) come
with the plugin and are picked up automatically — no
`~/.claude/settings.json` patching, no symlinking. Scripts run from
the plugin's own `bin/`, wherever Claude Code checks the plugin out
(cache path pattern
`${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/cache/<marketplace>/claude-code-handoff/<version>/bin/`).

The one thing a plugin install can't wire up for you is the optional
status line: see [docs/reference.md](docs/reference.md#status-line)
for how to wire it in by hand.

### Bare-scripts install (legacy / alternative)

Still fully supported — dual-mode is a deliberate design choice, not a
deprecated path.

```bash
git clone https://github.com/Sting25/claude-code-handoff.git ~/code/claude-code-handoff
cd ~/code/claude-code-handoff
./install.sh
```

The installer symlinks the scripts and skills into `~/.claude/` and
patches `~/.claude/settings.json` (backed up first; idempotent; your
own settings are left untouched).

`install.sh` is a generated artifact (concatenated from `install.d/`
by `tools/build-install.sh`; CI rebuilds and diffs it on every change)
and ships with a checksum. Inside a full clone, git already guarantees
integrity — but if you ever fetch `install.sh` on its own instead of
cloning, fetch `install.sh.sha256` from the same tag and verify before
running:

```bash
shasum -a 256 -c install.sh.sha256
```

A mismatch means a corrupted or tampered download — don't run it. (Both
files travel the same channel, so this catches corruption and casual
tampering, not a fully compromised host.)

### Either way

Once installed (either mode), in any project:

- **`/handoff`** — run at the end of a working session; writes the snapshot and fills in the "Notes from this session" prose block. Invoke at 30-50% context remaining, not at 5%.
- **`/handoff-recover`** — run when a new session shows an `ACTION: RUN /handoff-recover` banner; reconstructs the notes a crashed or un-handed-off session never wrote.
- **`/handoff-more`** — run in a fresh session to pull older handoffs into context, beyond the most recent one that auto-loads.

Everything else — loading, per-turn backups, the context nudge — runs
through hooks without you thinking about it.

### Dual-mode warning

Claude Code does not dedupe hooks across install modes. If you install
the plugin *and* leave a bare-scripts install wired into
`~/.claude/settings.json`, both sets of hooks fire on every event —
every `SessionStart`/`Stop`/`SessionEnd`/etc. runs twice, doubling
writes and raw-dump appends. Pick one mode per machine. The doctor
(`./install.sh --doctor`) warns when it detects both installed at
once — run it if you're unsure which mode you're in.

### Switching install modes

Leaving bare-scripts mode means running `./install.sh --uninstall`
first, and by default that deletes the per-machine HMAC secret at
`~/.claude/handoff_secret` (see [Uninstall
details](docs/reference.md#uninstall-details)) so no key material is
left behind by a tool you removed. If you have any already-signed
`handoff_current.md` (or entries in `handoff_history/`) you want to
keep verifying as binding rules after switching to the plugin, run
`./install.sh --uninstall --keep-secret` instead: it skips that
deletion. Both install modes read the secret from the same default
path, so nothing needs to be copied. Without `--keep-secret`, existing
signed handoffs still load fine, just as reference data instead of
binding rules, and `/handoff` re-signs new ones under the plugin's
fresh secret.

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

Six hooks drive it, wired up by either install mode (the plugin ships
them in `hooks/hooks.json`; the bare-scripts installer patches them
into `~/.claude/settings.json`):
`SessionStart` loads the latest handoff into a new session,
`SessionEnd` and `PreCompact` write a mechanical git-state safety net
before an ending or a compaction, `Stop` appends each turn to a
backup and records context usage, `UserPromptSubmit` nudges you
toward `/handoff` once usage crosses roughly 40% of the window, and
`PostCompact` resets those measurements so the freed window is
treated as fresh. Handoffs are signed with a per-machine HMAC key, so
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

This section covers the **bare-scripts install**. Symlink install
means updating is just `git pull` in the clone — live next session, no
re-install (re-run `./install.sh` only when
[`CHANGELOG.md`](CHANGELOG.md) says a hook changed). Run
`./install.sh --doctor` anytime to confirm every installed hook still
resolves (and to check for a plugin install running alongside it — see
[Dual-mode warning](#dual-mode-warning)). `./install.sh --uninstall`
removes the symlinks, strips only the entries it can prove are its own
from settings.json (backup first), and deletes the per-machine HMAC
secret — details in
[docs/reference.md](docs/reference.md#uninstall-details).

Plugin installs update and uninstall through Claude Code's own plugin
management (`/plugin` in-session) instead — there's no `git pull` or
`install.sh` step for that mode.

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
