# claude-code-handoff

Claude Code sessions run out of context. This tool writes a short,
human-readable handoff file at the end of a session and loads it
automatically when the next session starts — so you pick up where you
left off instead of starting from a blank slate or an auto-compacted
digest you never read.

## What it does

- **Snapshots where you left off** — git state plus a written summary of decisions, open questions, and next steps.
- **Auto-loads that snapshot into your next session** in the same repo — no copy-paste, no kickoff prompt.
- **Keeps a per-turn backup**, so a crashed or killed session can be reconstructed afterwards.
- **Saves a mechanical git-state snapshot on every clean exit**, even if you forget to hand off.
- **Nudges you when context is filling** (~40% used), while Claude is still sharp enough to write a good summary.
- **Signs each handoff with a per-machine key**, so a cloned repo can't inject fake standing rules.
- **Keeps a history of past handoffs** (last 5 by default) that you can pull back into context on demand.
- **Works in git and non-git projects**, in both the Claude Code CLI and the desktop app.

## Quick start

```bash
git clone https://github.com/Sting25/claude-code-handoff.git ~/code/claude-code-handoff
cd ~/code/claude-code-handoff
./install.sh
```

The installer symlinks the scripts and skills into `~/.claude/` and
patches `~/.claude/settings.json` (backed up first; idempotent; your
own settings are left untouched). Then, in any project:

- **`/handoff`** — run at the end of a working session; writes the snapshot and fills in the "Notes from this session" prose block. Invoke at 30-50% context remaining, not at 5%.
- **`/handoff-recover`** — run when a new session shows an `ACTION: RUN /handoff-recover` banner; reconstructs the notes a crashed or un-handed-off session never wrote.
- **`/handoff-more`** — run in a fresh session to pull older handoffs into context, beyond the most recent one that auto-loads.

Everything else — loading, per-turn backups, the context nudge — runs
through hooks without you thinking about it.

## Requirements

- `bash`, `git`, and `jq`. If `jq` is not on PATH, the installer
  refuses to install (`exit 1`) because the Stop hook, context nudge,
  and `/handoff-recover` all depend on it at runtime. (`--uninstall`
  and `--doctor` still work without `jq`.)
- `perl` — used by the Stop hook to strip transcript noise.
- `openssl` — optional. Without it, handoffs aren't HMAC-signed and
  the rules layer loads as reference data instead of binding; nothing
  errors.
- Tested on Linux — that CI job blocks. The macOS CI job (bash 3.2 /
  BSD userland) is advisory, non-blocking; the scripts handle BSD
  differences like `flock`/`tac`/`date`. Windows (Git Bash / WSL) is
  untested in CI.

## How it works

Six hooks, installed into `~/.claude/settings.json`:

| Hook | Job |
| --- | --- |
| `SessionStart` | Loads the latest handoff into the new session; prints an `ACTION: RUN /handoff-recover` banner if the last session ended without curated notes. |
| `SessionEnd` | Safety-net git-state snapshot on clean exit. No-op if you already ran `/handoff`; skipped on `/resume` session-switches. |
| `Stop` | After each assistant turn: appends the turn to a raw-dump backup and records context measurements. |
| `UserPromptSubmit` | Injects an advisory `/handoff` nudge once usage crosses ~40% of the window; periodically re-injects verified rules so they don't decay. |
| `PreCompact` | Same safety-net snapshot before compaction destroys the conversation. |
| `PostCompact` | Resets context measurements so the freed window is treated as fresh. |

**Files.** The latest snapshot lives at
`<repo>/.claude/handoff_current.md`; each new write rotates the old one
into `.claude/handoff_history/` (last 5 kept; `HANDOFF_HISTORY_KEEP=N`
to change, `0` disables pruning entirely). Per-turn raw dumps and
context measurements live under `.claude/handoff_backups/`. Both dirs
are gitignored on first write — handoffs are per-developer, not
checked-in artifacts. Retention only ever deletes files this tool
generated; anything you drop into those directories yourself is left
alone.

**The handoff doc.** Above the fold: mechanical git state (HEAD,
branch, recent commits, working tree, in-flight docs). Below: the
"Notes from this session" block — decisions, open questions, next
steps — which only `/handoff` fills in (the automatic safety net
leaves it as a placeholder). An HMAC trailer proves the doc was
written locally. Full example in
[docs/reference.md](docs/reference.md#what-the-handoff-actually-looks-like).

**Trusted rules.** A handoff can carry standing rules (a pinned file at
`.claude/handoff_pinned.md` plus a `## Rules` section) meant to bind the
next session. They load as binding only when provenance is proven: the
file is untracked in git AND carries a valid HMAC-SHA256 signature made
with a per-machine secret (`~/.claude/handoff_secret`, never in any
repo) — so a cloned repo can't inject fake rules. Anything less (no
`openssl`, tracked file, bad signature, `HANDOFF_TRUST_DISABLE=1`)
loads the whole file as defanged reference data. Model-authored notes
never bind. Verified rules are re-injected as the transcript grows so
they don't decay. Full design:
[docs/reference.md](docs/reference.md#trusted-rules-when-the-fences-actually-bind).

**Status line (optional).** `bin/handoff_statusline.sh` renders
`Fable | ctx 34% (340k/1000k) | handoff: curated` and caches Claude
Code's own context numbers (`.ctx_sl_<session_id>`) so the nudge uses
real usage instead of model-id guessing. The installer wires it only
if you don't already have a statusLine. Details:
[docs/reference.md](docs/reference.md#status-line).

## Configuration

Common env vars (set in `~/.bashrc` / `~/.zshrc`):

- `HANDOFF_HISTORY_KEEP` — snapshots kept in history (default 5; `0` disables pruning entirely).
- `HANDOFF_CTX_WINDOW_TOKENS` — pin the context-window size the nudge assumes; overrides all auto-detection.
- `HANDOFF_PINNED_FILE` — alternate path for the pinned-context file.
- `HANDOFF_TRUST_DISABLE=1` — disable binding rules; everything loads as reference data.
- `HANDOFF_FENCES_REINJECT_KB` — transcript growth between rule re-injections (default ~200KB; `0` disables).
- `HANDOFF_SESSIONEND_SKIP_REASONS` — SessionEnd reasons treated as a pause, not an ending (default: `resume`).

Full list in [skills/handoff/README.md](skills/handoff/README.md).
Test/debug overrides:

```bash
# Override the per-repo backup directory where raw-dump transcripts and
# context measurements live. Default: <repo>/.claude/handoff_backups.
export HANDOFF_BACKUP_DIR=/custom/path

# Override the projects root searched by /handoff-recover to find the
# current session's transcript. Default: $HOME/.claude/projects.
export HANDOFF_PROJECTS_DIR=/custom/projects/path

# Use this exact JSONL path as the transcript, skipping the projects-dir
# search. Useful for testing or when the transcript lives outside the
# normal Claude Code structure.
export HANDOFF_RECOVER_TRANSCRIPT=/path/to/transcript.jsonl

# Lock timeout (seconds) for the handoff_turn_append.sh Stop hook when
# acquiring the write lock on per-turn dumps. Default: 300.
export HANDOFF_LOCK_STALE_SECS=600
```

## Updating, doctor, uninstall

Symlink install means updating is just `git pull` in the clone — live
next session, no re-install (re-run `./install.sh` only when
[`CHANGELOG.md`](CHANGELOG.md) says a hook changed). Run
`./install.sh --doctor` anytime to confirm every installed hook still
resolves. `./install.sh --uninstall` removes the symlinks, strips only
the entries it can prove are its own from settings.json (backup
first), and deletes the per-machine HMAC secret — details in
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
